#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Copyright 2010 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
"""
This module provides basic encode and decode functionality to the flashrom
memory map (FMAP) structure.

WARNING: This module has been copied from third_party/flashmap/fmap.py (see
crbug/726356 for background). Please make modifications to this file there
first and then copy changes to this file.

Usage:
  (decode)
  obj = fmap_decode(blob)
  print obj

  (encode)
  blob = fmap_encode(obj)
  open('output.bin', 'w').write(blob)

  The object returned by fmap_decode is a dictionary with names defined in
  fmap.h. A special property 'FLAGS' is provided as a readable and read-only
  tuple of decoded area flags.
"""

import argparse
import copy
import logging
import pprint
import struct
import sys


# constants imported from lib/fmap.h
FMAP_SIGNATURE = b'__FMAP__'
FMAP_VER_MAJOR = 1
FMAP_VER_MINOR_MIN = 0
FMAP_VER_MINOR_MAX = 1
FMAP_STRLEN = 32
FMAP_SEARCH_STRIDE = 4

FMAP_FLAGS = {
    'FMAP_AREA_STATIC': 1 << 0,
    'FMAP_AREA_COMPRESSED': 1 << 1,
    'FMAP_AREA_RO': 1 << 2,
    'FMAP_AREA_PRESERVE': 1 << 3,
}

FMAP_HEADER_NAMES = (
    'signature',
    'ver_major',
    'ver_minor',
    'base',
    'size',
    'name',
    'nareas',
)

FMAP_AREA_NAMES = (
    'offset',
    'size',
    'name',
    'flags',
)


# format string
FMAP_HEADER_FORMAT = f'<8sBBQI{int(FMAP_STRLEN)}sH'
FMAP_AREA_FORMAT = f'<II{int(FMAP_STRLEN)}sH'


def _fmap_decode_header(blob, offset):
  """(internal) Decodes a FMAP header from blob by offset"""
  header = {}
  for (name, value) in zip(FMAP_HEADER_NAMES,
                           struct.unpack_from(FMAP_HEADER_FORMAT,
                                              blob,
                                              offset)):
    header[name] = value

  if header['signature'] != FMAP_SIGNATURE:
    raise struct.error('Invalid signature')
  if (header['ver_major'] != FMAP_VER_MAJOR or
      header['ver_minor'] < FMAP_VER_MINOR_MIN or
      header['ver_minor'] > FMAP_VER_MINOR_MAX):
    raise struct.error('Incompatible version')

  # convert null-terminated names
  header['name'] = header['name'].strip(b'\x00')

  # In Python 2, binary==string, so we don't need to convert.
  if sys.version_info.major >= 3:
    # Do the decode after verifying it to avoid decode errors due to corruption.
    for name in FMAP_HEADER_NAMES:
      if hasattr(header[name], 'decode'):
        header[name] = header[name].decode('utf-8')

  return (header, struct.calcsize(FMAP_HEADER_FORMAT))


def _fmap_decode_area(blob, offset):
  """(internal) Decodes a FMAP area record from blob by offset"""
  area = {}
  for (name, value) in zip(FMAP_AREA_NAMES,
                           struct.unpack_from(FMAP_AREA_FORMAT, blob, offset)):
    area[name] = value
  # convert null-terminated names
  area['name'] = area['name'].strip(b'\x00')
  # add a (readonly) readable FLAGS
  area['FLAGS'] = _fmap_decode_area_flags(area['flags'])

  # In Python 2, binary==string, so we don't need to convert.
  if sys.version_info.major >= 3:
    for name in FMAP_AREA_NAMES:
      if hasattr(area[name], 'decode'):
        area[name] = area[name].decode('utf-8')

  return (area, struct.calcsize(FMAP_AREA_FORMAT))


def _fmap_decode_area_flags(area_flags):
  """(internal) Decodes a FMAP flags property"""
  # Since FMAP_FLAGS is a dict with arbitrary ordering, sort the list so the
  # output is stable.  Also sorting is nicer for humans.
  return tuple(sorted(x for x, flag in FMAP_FLAGS.items() if area_flags & flag))


def _fmap_check_name(fmap, name):
  """Checks if the FMAP structure has correct name.

  Args:
    fmap: A decoded FMAP structure.
    name: A string to specify expected FMAP name.

  Raises:
    struct.error if the name does not match.
  """
  if fmap['name'] != name:
    raise struct.error(
        f"Incorrect FMAP (found: \"{fmap['name']}\", expected: \"{name}\")")


def _fmap_search_header(blob, fmap_name=None):
  """Searches FMAP headers in given blob.

  Uses same logic from vboot_reference/host/lib/fmap.c.

  Args:
    blob: A string containing FMAP data.
    fmap_name: A string to specify target FMAP name.

  Returns:
    A tuple of (fmap, size, offset).
  """
  lim = len(blob) - struct.calcsize(FMAP_HEADER_FORMAT)
  align = FMAP_SEARCH_STRIDE

  # Search large alignments before small ones to find "right" FMAP.
  while align <= lim:
    align *= 2

  while align >= FMAP_SEARCH_STRIDE:
    for offset in range(align, lim + 1, align * 2):
      if not blob.startswith(FMAP_SIGNATURE, offset):
        continue
      try:
        (fmap, size) = _fmap_decode_header(blob, offset)
        if fmap_name is not None:
          _fmap_check_name(fmap, fmap_name)
        return (fmap, size, offset)
      except struct.error as e:
        # Search for next FMAP candidate.
        logging.debug('Continue searching FMAP due to exception %r', e)
    align //= 2
  raise struct.error('No valid FMAP signatures.')


def fmap_decode(blob, offset=None, fmap_name=None):
  """Decodes a blob to FMAP dictionary object.

  Args:
    blob: a binary data containing FMAP structure.
    offset: starting offset of FMAP. When omitted, fmap_decode will search in
            the blob.
    fmap_name: A string to specify target FMAP name.
  """
  fmap = {}

  if offset is None:
    (fmap, size, offset) = _fmap_search_header(blob, fmap_name)
  else:
    (fmap, size) = _fmap_decode_header(blob, offset)
    if fmap_name is not None:
      _fmap_check_name(fmap, fmap_name)
  fmap['areas'] = []
  offset = offset + size
  for _ in range(fmap['nareas']):
    (area, size) = _fmap_decode_area(blob, offset)
    offset = offset + size
    fmap['areas'].append(area)
  return fmap


def _fmap_encode_header(obj):
  """(internal) Encodes a FMAP header"""
  # Convert strings to bytes.
  obj = copy.deepcopy(obj)
  for name in FMAP_HEADER_NAMES:
    if hasattr(obj[name], 'encode'):
      obj[name] = obj[name].encode('utf-8')

  values = [obj[name] for name in FMAP_HEADER_NAMES]
  return struct.pack(FMAP_HEADER_FORMAT, *values)


def _fmap_encode_area(obj):
  """(internal) Encodes a FMAP area entry"""
  # Convert strings to bytes.
  obj = copy.deepcopy(obj)
  for name in FMAP_AREA_NAMES:
    if hasattr(obj[name], 'encode'):
      obj[name] = obj[name].encode('utf-8')

  values = [obj[name] for name in FMAP_AREA_NAMES]
  return struct.pack(FMAP_AREA_FORMAT, *values)


def fmap_encode(obj):
  """Encodes a FMAP dictionary object to blob.

  Args
    obj: a FMAP dictionary object.
  """
  # fix up values
  obj['nareas'] = len(obj['areas'])
  # TODO(hungte) re-assign signature / version?
  blob = _fmap_encode_header(obj)
  for area in obj['areas']:
    blob = blob + _fmap_encode_area(area)
  return blob


class FirmwareImage:
  """Provides access to firmware image via FMAP sections."""

  def __init__(self, image_source):
    self._image = image_source
    self._fmap = fmap_decode(self._image)
    self._areas = dict(
        (entry['name'], [entry['offset'], entry['size']])
        for entry in self._fmap['areas'])

  def get_blob(self):
    """Returns the raw firmware blob."""
    return self._image

  def get_size(self):
    """Returns the size of associate firmware image."""
    return len(self._image)

  def has_section(self, name):
    """Returns if specified section is available in image."""
    return name in self._areas

  def get_section_area(self, name):
    """Returns the area (offset, size) information of given section."""
    if not self.has_section(name):
      raise ValueError(f'get_section_area: invalid section: {name}')
    return self._areas[name]

  def get_section(self, name):
    """Returns the content of specified section."""
    area = self.get_section_area(name)
    return self._image[area[0]:(area[0] + area[1])]

  def get_section_offset(self, name):
    area = self.get_section_area(name)
    return self._image[area[0]:(area[0] + area[1])]

  def put_section(self, name, value):
    """Updates content of specified section in image."""
    area = self.get_section_area(name)
    if len(value) != area[1]:
      raise ValueError(
          f'Value size ({len(value)}) does not fit into section ({name}, '
          f'{int(area[1])})')
    self._image = (self._image[0:area[0]] +
                   value +
                   self._image[(area[0] + area[1]):])
    return True

  def get_fmap_blob(self):
    """Returns the re-encoded fmap blob from firmware image."""
    return fmap_encode(self._fmap)


def get_parser():
  """Return a command line parser."""
  parser = argparse.ArgumentParser(
      description=__doc__,
      formatter_class=argparse.RawTextHelpFormatter)
  parser.add_argument('file', help='The file to decode & print.')
  parser.add_argument('--raw', action='store_true',
                      help='Dump the object output for scripts.')
  return parser


def main(argv):
  """Decode FMAP from supplied file and print."""
  parser = get_parser()
  opts = parser.parse_args(argv)

  if not opts.raw:
    print(f'Decoding FMAP from: {opts.file}')
  with open(opts.file, 'rb', encoding=None) as f:
    blob = f.read()
  obj = fmap_decode(blob)
  if opts.raw:
    print(obj)
  else:
    pp = pprint.PrettyPrinter(indent=2)
    pp.pprint(obj)


if __name__ == '__main__':
  sys.exit(main(sys.argv[1:]))
