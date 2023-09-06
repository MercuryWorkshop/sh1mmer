#!/usr/bin/env python3
# Copyright 2017 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""An utility to manipulate GPT on a disk image.

Chromium OS factory software usually needs to access partitions from disk
images. However, there is no good, lightweight, and portable GPT utility.
Most Chromium OS systems use `cgpt`, but that's not by default installed on
Ubuntu. Most systems have parted (GNU) or partx (util-linux-ng) but they have
their own problems.

For example, when a disk image is resized (usually enlarged for putting more
resources on stateful partition), GPT table must be updated. However,
 - `parted` can't repair partition without interactive console in exception
    handler.
 - `partx` cannot fix headers nor make changes to partition table.
 - `cgpt repair` does not fix `LastUsableLBA` so we cannot enlarge partition.
 - `gdisk` is not installed on most systems.

As a result, we need a dedicated tool to help processing GPT.

This pygpt.py provides a simple and customized implementation for processing
GPT, as a replacement for `cgpt`.
"""

import argparse
import binascii
import codecs
import itertools
import logging
import os
import stat
import struct
import subprocess
import sys
import uuid


class StructError(Exception):
  """Exceptions in packing and unpacking from/to struct fields."""


class StructField:
  """Definition of a field in struct.

  Attributes:
    fmt: a format string for struct.{pack,unpack} to use.
    name: a string for name of processed field.
  """
  __slots__ = ['fmt', 'name']

  def __init__(self, fmt, name):
    self.fmt = fmt
    self.name = name

  def Pack(self, value):
    """"Packs given value from given format."""
    del self  # Unused.
    if isinstance(value, str):
      value = value.encode('utf-8')
    return value

  def Unpack(self, value):
    """Unpacks given value into given format."""
    del self  # Unused.
    return value


class UTF16StructField(StructField):
  """A field in UTF encoded string."""
  __slots__ = ['max_length']
  encoding = 'utf-16-le'

  def __init__(self, max_length, name):
    self.max_length = max_length
    fmt = f'{int(max_length)}s'
    super().__init__(fmt, name)

  def Pack(self, value):
    new_value = value.encode(self.encoding)
    if len(new_value) >= self.max_length:
      raise StructError(
          f'Value "{value}" cannot be packed into field {self.name} (len='
          f'{self.max_length})')
    return new_value

  def Unpack(self, value):
    return value.decode(self.encoding).strip('\x00')


class GUID(uuid.UUID):
  """A special UUID that defaults to upper case in str()."""

  def __str__(self):
    """Returns GUID in upper case."""
    return super().__str__().upper()

  @staticmethod
  def Random():
    return uuid.uuid4()


class GUIDStructField(StructField):
  """A GUID field."""

  def __init__(self, name):
    super().__init__('16s', name)

  def Pack(self, value):
    if value is None:
      return b'\x00' * 16
    if not isinstance(value, uuid.UUID):
      raise StructError(
          f'Field {self.name} needs a GUID value instead of [{value!r}].')
    return value.bytes_le

  def Unpack(self, value):
    return GUID(bytes_le=value)


def BitProperty(getter, setter, shift, mask):
  """A generator for bit-field properties.

  This is used inside a class to manipulate an integer-like variable using
  properties. The getter and setter should be member functions to change the
  underlying member data.

  Args:
    getter: a function to read integer type variable (for all the bits).
    setter: a function to set the new changed integer type variable.
    shift: integer for how many bits should be shifted (right).
    mask: integer for the mask to filter out bit field.
  """
  def _getter(self):
    return (getter(self) >> shift) & mask
  def _setter(self, value):
    assert value & mask == value, (f'Value {value} out of range (mask={mask})')
    setter(self, getter(self) & ~(mask << shift) | value << shift)
  return property(_getter, _setter)


def RemovePartition(image, part):
  """Remove partition `part`.

  Args:
    image: a path to an image file.
    part: the partition number.
  """
  print(f'Removing partition {int(part)}...')
  add_cmd = GPTCommands.Add()
  add_cmd.ExecuteCommandLine('-i', str(part), '-t', 'Unused', image)


class PartitionAttributes:
  """Wrapper for Partition.Attributes.

  This can be created using Partition.attrs, but the changed properties won't
  apply to underlying Partition until an explicit call with
  Partition.Update(Attributes=new_attrs).
  """

  def __init__(self, attrs):
    self._attrs = attrs

  @property
  def raw(self):
    """Returns the raw integer type attributes."""
    return self._Get()

  def _Get(self):
    return self._attrs

  def _Set(self, value):
    self._attrs = value

  successful = BitProperty(_Get, _Set, 56, 1)
  tries = BitProperty(_Get, _Set, 52, 0xf)
  priority = BitProperty(_Get, _Set, 48, 0xf)
  legacy_boot = BitProperty(_Get, _Set, 2, 1)
  required = BitProperty(_Get, _Set, 0, 1)
  raw_16 = BitProperty(_Get, _Set, 48, 0xffff)


class PartitionAttributeStructField(StructField):

  def Pack(self, value):
    if not isinstance(value, PartitionAttributes):
      raise StructError(
          f'Given value {value!r} is not {PartitionAttributes.__name__}.')
    return value.raw

  def Unpack(self, value):
    return PartitionAttributes(value)


# The binascii.crc32 returns unsigned integer in python3, so CRC32 in struct
# must be declared as 'unsigned' (L).
# http://en.wikipedia.org/wiki/GUID_Partition_Table#Partition_table_header_.28LBA_1.29
HEADER_FIELDS = [
    StructField('8s', 'Signature'),
    StructField('4s', 'Revision'),
    StructField('L', 'HeaderSize'),
    StructField('L', 'CRC32'),
    StructField('4s', 'Reserved'),
    StructField('Q', 'CurrentLBA'),
    StructField('Q', 'BackupLBA'),
    StructField('Q', 'FirstUsableLBA'),
    StructField('Q', 'LastUsableLBA'),
    GUIDStructField('DiskGUID'),
    StructField('Q', 'PartitionEntriesStartingLBA'),
    StructField('L', 'PartitionEntriesNumber'),
    StructField('L', 'PartitionEntrySize'),
    StructField('L', 'PartitionArrayCRC32'),
]

# http://en.wikipedia.org/wiki/GUID_Partition_Table#Partition_entries
PARTITION_FIELDS = [
    GUIDStructField('TypeGUID'),
    GUIDStructField('UniqueGUID'),
    StructField('Q', 'FirstLBA'),
    StructField('Q', 'LastLBA'),
    PartitionAttributeStructField('Q', 'Attributes'),
    UTF16StructField(72, 'Names'),
]

# The PMBR has so many variants. The basic format is defined in
# https://en.wikipedia.org/wiki/Master_boot_record#Sector_layout, and our
# implementation, as derived from `cgpt`, is following syslinux as:
# https://chromium.googlesource.com/chromiumos/platform/vboot_reference/+/HEAD/cgpt/cgpt.h#32
PMBR_FIELDS = [
    StructField('424s', 'BootCode'),
    GUIDStructField('BootGUID'),
    StructField('L', 'DiskID'),
    StructField('2s', 'Magic'),
    StructField('16s', 'LegacyPart0'),
    StructField('16s', 'LegacyPart1'),
    StructField('16s', 'LegacyPart2'),
    StructField('16s', 'LegacyPart3'),
    StructField('2s', 'Signature'),
]


class GPTError(Exception):
  """All exceptions by GPT."""


class GPTObject:
  """A base object in GUID Partition Table.

  All objects (for instance, header or partition entries) must inherit this
  class and define the FIELD attribute with a list of field definitions using
  StructField.

  The 'name' in StructField will become the attribute name of GPT objects that
  can be directly packed into / unpacked from. Derived (calculated from existing
  attributes) attributes should be in lower_case.

  It is also possible to attach some additional properties to the object as meta
  data (for example path of the underlying image file). To do that, first
  include it in __slots__ list and specify them as dictionary-type args in
  constructors. These properties will be preserved when you call Clone().

  To create a new object, call the constructor. Field data can be assigned as
  in arguments, or give nothing to initialize as zero (see Zero()). Field data
  and meta values can be also specified in keyword arguments (**kargs) at the
  same time.

  To read a object from file or stream, use class method ReadFrom(source).
  To make changes, modify the field directly or use Update(dict), or create a
  copy by Clone() first then Update.

  To wipe all fields (but not meta), call Zero(). There is currently no way
  to clear meta except setting them to None one by one.
  """
  __slots__ = []

  FIELDS = []
  """A list of StructField definitions."""

  def __init__(self, *args, **kargs):
    if args:
      if len(args) != len(self.FIELDS):
        raise GPTError(
            f'{type(self).__name__} need {len(self.FIELDS)} arguments (found '
            f'{len(args)}).')
      for f, value in zip(self.FIELDS, args):
        setattr(self, f.name, value)
    else:
      self.Zero()

    all_names = list(self.__slots__)
    for name, value in kargs.items():
      if name not in all_names:
        raise GPTError(
            f'{type(self).__name__} does not support keyword arg <{name}>.')
      setattr(self, name, value)

  def __iter__(self):
    """An iterator to return all fields associated in the object."""
    return (getattr(self, f.name) for f in self.FIELDS)

  def __repr__(self):
    repr_desc = ', '.join(f'{f}={getattr(self, f)!r}' for f in self.__slots__)
    return f'({type(self).__name__}: {repr_desc})'

  @classmethod
  def GetStructFormat(cls):
    """Returns a format string for struct to use."""
    return '<' + ''.join(f.fmt for f in cls.FIELDS)

  @classmethod
  def ReadFrom(cls, source, **kargs):
    """Returns an object from given source."""
    obj = cls(**kargs)
    obj.Unpack(source)
    return obj

  @property
  def blob(self):
    """The (packed) blob representation of the object."""
    return self.Pack()

  @property
  def meta(self):
    """Meta values (those not in GPT object fields)."""
    metas = set(self.__slots__) - {f.name for f in self.FIELDS}
    return {name: getattr(self, name) for name in metas}

  def Unpack(self, source):
    """Unpacks values from a given source.

    Args:
      source: a string of bytes or a file-like object to read from.
    """
    fmt = self.GetStructFormat()
    if source is None:
      source = '\x00' * struct.calcsize(fmt)
    if not isinstance(source, (str, bytes)):
      return self.Unpack(source.read(struct.calcsize(fmt)))
    if isinstance(source, str):
      source = source.encode('utf-8')
    for f, value in zip(self.FIELDS, struct.unpack(fmt.encode('utf-8'),
                                                   source)):
      setattr(self, f.name, f.Unpack(value))
    return None

  def Pack(self):
    """Packs values in all fields into a bytes by struct format."""
    return struct.pack(self.GetStructFormat(),
                       *(f.Pack(getattr(self, f.name)) for f in self.FIELDS))

  def Clone(self):
    """Clones a new instance."""
    return type(self)(*self, **self.meta)

  def Update(self, **dargs):
    """Applies multiple values in current object."""
    for name, value in dargs.items():
      setattr(self, name, value)

  def Zero(self):
    """Set all fields to values representing zero or empty.

    Note the meta attributes won't be cleared.
    """
    class ZeroReader:
      """A /dev/zero like stream."""

      @classmethod
      def read(cls, num):
        return '\x00' * num

    self.Unpack(ZeroReader())


class GPT:
  """A GPT helper class.

  To load GPT from an existing disk image file, use `LoadFromFile`.
  After modifications were made, use `WriteToFile` to commit changes.

  Attributes:
    header: a namedtuple of GPT header.
    pmbr: a namedtuple of Protective MBR.
    partitions: a list of GPT partition entry nametuple.
    block_size: integer for size of bytes in one block (sector).
    is_secondary: boolean to indicate if the header is from primary or backup.
  """
  DEFAULT_BLOCK_SIZE = 512
  # Old devices uses 'Basic data' type for stateful partition, and newer devices
  # should use 'Linux (fS) data' type; so we added a 'stateful' suffix for
  # migration.
  # GUID is defined at src/platform/vboot_reference/firmware/include/gpt.h.
  TYPE_GUID_MAP = {
      GUID('00000000-0000-0000-0000-000000000000'): 'Unused',
      GUID('EBD0A0A2-B9E5-4433-87C0-68B6B72699C7'): 'Basic data stateful',
      GUID('0FC63DAF-8483-4772-8E79-3D69D8477DE4'): 'Linux data',
      GUID('FE3A2A5D-4F32-41A7-B725-ACCC3285A309'): 'ChromeOS kernel',
      GUID('3CB8E202-3B7E-47DD-8A3C-7FF2A13CFCEC'): 'ChromeOS rootfs',
      GUID('2E0A753D-9E48-43B0-8337-B15192CB1B5E'): 'ChromeOS reserved',
      GUID('CAB6E88E-ABF3-4102-A07A-D4BB9BE3C1D3'): 'ChromeOS firmware',
      GUID('C12A7328-F81F-11D2-BA4B-00A0C93EC93B'): 'EFI System Partition',
      GUID('09845860-705F-4BB5-B16C-8A8A099CAF52'): 'ChromeOS MINIOS',
      GUID('3F0F8318-F146-4E6B-8222-C28C8F02E0D5'): 'ChromeOS hibernate',
  }
  TYPE_GUID_FROM_NAME = {
      'efi' if v.startswith('EFI') else v.lower().split()[-1]: k
      for k, v in TYPE_GUID_MAP.items()}
  TYPE_GUID_UNUSED = TYPE_GUID_FROM_NAME['unused']
  TYPE_GUID_CHROMEOS_KERNEL = TYPE_GUID_FROM_NAME['kernel']
  TYPE_GUID_LIST_BOOTABLE = [
      TYPE_GUID_CHROMEOS_KERNEL,
      TYPE_GUID_FROM_NAME['efi'],
  ]

  class ProtectiveMBR(GPTObject):
    """Protective MBR (PMBR) in GPT."""
    FIELDS = PMBR_FIELDS
    __slots__ = [f.name for f in FIELDS]

    SIGNATURE = b'\x55\xAA'
    MAGIC = b'\x1d\x9a'

  class Header(GPTObject):
    """Wrapper to Header in GPT."""
    FIELDS = HEADER_FIELDS
    __slots__ = [f.name for f in FIELDS]

    SIGNATURES = [b'EFI PART', b'CHROMEOS']
    SIGNATURE_IGNORE = b'IGNOREME'
    DEFAULT_REVISION = b'\x00\x00\x01\x00'

    DEFAULT_PARTITION_ENTRIES = 128
    DEFAULT_PARTITIONS_LBA = 2  # LBA 0 = MBR, LBA 1 = GPT Header.

    @classmethod
    def Create(cls, size, block_size, pad_blocks=0,
               part_entries=DEFAULT_PARTITION_ENTRIES):
      """Creates a header with default values.

      Args:
        size: integer of expected image size.
        block_size: integer for size of each block (sector).
        pad_blocks: number of preserved sectors between header and partitions.
        part_entries: number of partitions to include in header.
      """
      PART_FORMAT = GPT.Partition.GetStructFormat()
      FORMAT = cls.GetStructFormat()
      part_entry_size = struct.calcsize(PART_FORMAT)
      parts_lba = cls.DEFAULT_PARTITIONS_LBA + pad_blocks
      parts_bytes = part_entries * part_entry_size
      parts_blocks = parts_bytes // block_size
      if parts_bytes % block_size:
        parts_blocks += 1
      # CRC32 and PartitionsCRC32 must be updated later explicitly.
      return cls(
          Signature=cls.SIGNATURES[0],
          Revision=cls.DEFAULT_REVISION,
          HeaderSize=struct.calcsize(FORMAT),
          CurrentLBA=1,
          BackupLBA=size // block_size - 1,
          FirstUsableLBA=parts_lba + parts_blocks,
          LastUsableLBA=size // block_size - parts_blocks - parts_lba,
          DiskGUID=GUID.Random(),
          PartitionEntriesStartingLBA=parts_lba,
          PartitionEntriesNumber=part_entries,
          PartitionEntrySize=part_entry_size)

    def UpdateChecksum(self):
      """Updates the CRC32 field in GPT header.

      Note the PartitionArrayCRC32 is not touched - you have to make sure that
      is correct before calling Header.UpdateChecksum().
      """
      self.Update(CRC32=0)
      self.Update(CRC32=binascii.crc32(self.blob))

  class PartitionBase(GPTObject):
    """The base partition entry in GPT.

    A base class representing a GPT partition that is not tied to an image file.
    `FirstLBA` and `LastLBA` doesn't have actual meanings here. They are just
    used to calculate the size of the partition.

    Please include following properties when creating a PartitionBase object:
    - block_size: an integer for size of each block (LBA, or sector).
    """
    FIELDS = PARTITION_FIELDS
    METADATA = ['block_size']
    __slots__ = [f.name for f in FIELDS] + METADATA

    def IsUnused(self):
      """Returns if the partition is unused and can be allocated."""
      return self.TypeGUID == GPT.TYPE_GUID_UNUSED

    def IsChromeOSKernel(self):
      """Returns if the partition is a Chrome OS kernel partition."""
      return self.TypeGUID == GPT.TYPE_GUID_CHROMEOS_KERNEL

    @property
    def blocks(self):
      """Return size of partition in blocks (see block_size)."""
      return self.LastLBA - self.FirstLBA + 1

    @property
    def offset(self):
      """Returns offset to partition in bytes."""
      return self.FirstLBA * self.block_size

    @property
    def size(self):
      """Returns size of partition in bytes."""
      return self.blocks * self.block_size

  class Partition(PartitionBase):
    """The partition entry in GPT.

    Please include following properties when creating a Partition object:
    - image: a string for path to the image file the partition maps to.
    - number: the 1-based partition number.
    - block_size: an integer for size of each block (LBA, or sector).
    """
    FIELDS = PARTITION_FIELDS
    METADATA = ['image', 'number', 'block_size']
    __slots__ = [f.name for f in FIELDS] + METADATA

    def __str__(self):
      return f'{self.image}#{self.number}'

  def __init__(self):
    """GPT constructor.

    See LoadFromFile for how it's usually used.
    """
    self.pmbr = None
    self.header = None
    self.partitions = None
    self.block_size = self.DEFAULT_BLOCK_SIZE
    self.is_secondary = False

  @classmethod
  def GetTypeGUID(cls, value):
    """The value may be a GUID in string or a short type string."""
    guid = cls.TYPE_GUID_FROM_NAME.get(value.lower())
    return GUID(value) if guid is None else guid

  @classmethod
  def Create(cls, image_name, size, block_size, pad_blocks=0):
    """Creates a new GPT instance from given size and block_size.

    Args:
      image_name: a string of underlying disk image file name.
      size: expected size of disk image.
      block_size: size of each block (sector) in bytes.
      pad_blocks: number of blocks between header and partitions array.
    """
    gpt = cls()
    gpt.block_size = block_size
    gpt.header = cls.Header.Create(size, block_size, pad_blocks)
    gpt.partitions = [
        cls.Partition(block_size=block_size, image=image_name, number=i + 1)
        for i in range(gpt.header.PartitionEntriesNumber)]
    return gpt

  @staticmethod
  def IsBlockDevice(image):
    """Returns if the image is a block device file."""
    return stat.S_ISBLK(os.stat(image).st_mode)

  @classmethod
  def GetImageSize(cls, image):
    """Returns the size of specified image (plain or block device file)."""
    if not cls.IsBlockDevice(image):
      return os.path.getsize(image)

    fd = os.open(image, os.O_RDONLY)
    try:
      return os.lseek(fd, 0, os.SEEK_END)
    finally:
      os.close(fd)

  @classmethod
  def GetLogicalBlockSize(cls, block_dev):
    """Returns the logical block (sector) size from a block device file.

    The underlying call is BLKSSZGET. An alternative command is blockdev,
    but that needs root permission even if we just want to get sector size.
    """
    assert cls.IsBlockDevice(block_dev), f'{block_dev} must be block device.'
    return int(subprocess.check_output(
        ['lsblk', '-d', '-n', '-r', '-o', 'log-sec', block_dev]).strip())

  @classmethod
  def LoadFromFile(cls, image):
    """Loads a GPT table from give disk image file object.

    Args:
      image: a string as file path or a file-like object to read from.
    """
    if isinstance(image, str):
      with open(image, 'rb') as f:
        return cls.LoadFromFile(f)

    gpt = cls()
    image.seek(0)
    pmbr = gpt.ProtectiveMBR.ReadFrom(image)
    if pmbr.Signature == cls.ProtectiveMBR.SIGNATURE:
      logging.debug('Found MBR signature in %s', image.name)
      if pmbr.Magic == cls.ProtectiveMBR.MAGIC:
        logging.debug('Found PMBR in %s', image.name)
        gpt.pmbr = pmbr

    # Try DEFAULT_BLOCK_SIZE, then 4K.
    block_sizes = [cls.DEFAULT_BLOCK_SIZE, 4096]
    if cls.IsBlockDevice(image.name):
      block_sizes = [cls.GetLogicalBlockSize(image.name)]

    for block_size in block_sizes:
      # Note because there are devices setting Primary as ignored and the
      # partition table signature accepts 'CHROMEOS' which is also used by
      # Chrome OS kernel partition, we have to look for Secondary (backup) GPT
      # first before trying other block sizes, otherwise we may incorrectly
      # identify a kernel partition as LBA 1 of larger block size system.
      for i, seek in enumerate([(block_size * 1, os.SEEK_SET),
                                (-block_size, os.SEEK_END)]):
        image.seek(*seek)
        header = gpt.Header.ReadFrom(image)
        if header.Signature in cls.Header.SIGNATURES:
          gpt.block_size = block_size
          if i != 0:
            gpt.is_secondary = True
          break
        # TODO(hungte) Try harder to see if this block is valid.
      else:
        # Nothing found, try next block size.
        continue
      # Found a valid signature.
      break
    else:
      raise GPTError('Invalid signature in GPT header.')

    image.seek(gpt.block_size * header.PartitionEntriesStartingLBA)
    def ReadPartition(image, number):
      p = gpt.Partition.ReadFrom(
          image, image=image.name, number=number, block_size=gpt.block_size)
      return p

    gpt.header = header
    gpt.partitions = [
        ReadPartition(image, i + 1)
        for i in range(header.PartitionEntriesNumber)]
    return gpt

  def GetUsedPartitions(self):
    """Returns a list of partitions with type GUID not set to unused.

    Use 'number' property to find the real location of partition in
    self.partitions.
    """
    return [p for p in self.partitions if not p.IsUnused()]

  def GetMaxUsedLBA(self):
    """Returns the max LastLBA from all used partitions."""
    parts = self.GetUsedPartitions()
    return (max(p.LastLBA for p in parts)
            if parts else self.header.FirstUsableLBA - 1)

  def GetPartitionTableBlocks(self, header=None):
    """Returns the blocks (or LBA) of partition table from given header."""
    if header is None:
      header = self.header
    size = header.PartitionEntrySize * header.PartitionEntriesNumber
    blocks = size // self.block_size
    if size % self.block_size:
      blocks += 1
    return blocks

  def GetPartition(self, number):
    """Gets the Partition by given (1-based) partition number.

    Args:
      number: an integer as 1-based partition number.
    """
    if not 0 < number <= len(self.partitions):
      raise GPTError(f'Invalid partition number {number}.')
    return self.partitions[number - 1]

  def UpdatePartition(self, part, number):
    """Updates the entry in partition table by given Partition object.

    Usually you only need to call this if you want to copy one partition to
    different location (number of image).

    Args:
      part: a Partition GPT object.
      number: an integer as 1-based partition number.
    """
    ref = self.partitions[number - 1]
    self.partitions[number - 1] = self.Partition(
        *part, image=ref.image, number=number, block_size=ref.block_size)

  def GetSize(self):
    return self.block_size * (self.header.BackupLBA + 1)

  def Resize(self, new_size, check_overlap=True):
    """Adjust GPT for a disk image in given size.

    Args:
      new_size: Integer for new size of disk image file.
      check_overlap: Checks if the backup partition table overlaps used
                     partitions.
    """
    old_size = self.GetSize()
    if new_size % self.block_size:
      raise GPTError(
          f'New file size {int(new_size)} is not valid for image files.')
    new_blocks = new_size // self.block_size
    if old_size != new_size:
      logging.warning('Image size (%d, LBA=%d) changed from %d (LBA=%d).',
                      new_size, new_blocks, old_size,
                      old_size // self.block_size)
    else:
      logging.info('Image size (%d, LBA=%d) not changed.',
                   new_size, new_blocks)
      return

    # Expected location
    backup_lba = new_blocks - 1
    last_usable_lba = backup_lba - self.header.FirstUsableLBA

    if check_overlap and last_usable_lba < self.header.LastUsableLBA:
      max_used_lba = self.GetMaxUsedLBA()
      if last_usable_lba < max_used_lba:
        raise GPTError('Backup partition tables will overlap used partitions')

    self.header.Update(BackupLBA=backup_lba, LastUsableLBA=last_usable_lba)

  def GetFreeSpace(self):
    """Returns the free (available) space left according to LastUsableLBA."""
    max_lba = self.GetMaxUsedLBA()
    assert max_lba <= self.header.LastUsableLBA, "Partitions too large."
    return self.block_size * (self.header.LastUsableLBA - max_lba)

  def ExpandPartition(self, number, reserved_blocks=0):
    """Expands a given partition to last usable LBA - reserved blocks.

    The size of the partition can actually be reduced if the last usable LBA
    decreases.

    Args:
      number: an integer to specify partition in 1-based number.

    Returns:
      (old_blocks, new_blocks) for size in blocks.
    """
    # Assume no partitions overlap, we need to make sure partition[i] has
    # largest LBA.
    p = self.GetPartition(number)
    if p.IsUnused():
      raise GPTError(f'Partition {p} is unused.')
    max_used_lba = self.GetMaxUsedLBA()
    # TODO(hungte) We can do more by finding free space after i.
    if max_used_lba > p.LastLBA:
      raise GPTError(f'Cannot expand {p} because it is not allocated at last.')

    old_blocks = p.blocks
    p.Update(LastLBA=self.header.LastUsableLBA - reserved_blocks)
    new_blocks = p.blocks
    logging.warning(
        '%s size changed in LBA: %d -> %d.', p, old_blocks, new_blocks)
    return (old_blocks, new_blocks)

  def CheckIntegrity(self):
    """Checks if the GPT objects all look good."""
    # Check if the header allocation looks good. CurrentLBA and
    # PartitionEntriesStartingLBA should be all outside [FirstUsableLBA,
    # LastUsableLBA].
    header = self.header
    entries_first_lba = header.PartitionEntriesStartingLBA
    entries_last_lba = entries_first_lba + self.GetPartitionTableBlocks() - 1

    def CheckOutsideUsable(name, lba, outside_entries=False):
      if lba < 1:
        raise GPTError(f'{name} should not live in LBA {lba}.')
      if lba > max(header.BackupLBA, header.CurrentLBA):
        # Note this is "in theory" possible, but we want to report this as
        # error as well, since it usually leads to error.
        raise GPTError(f'{name} ({lba}) should not be larger than BackupLBA ('
                       f'{header.BackupLBA}).')
      if header.FirstUsableLBA <= lba <= header.LastUsableLBA:
        raise GPTError(f'{name} ({lba}) should not be included in usable LBAs ['
                       f'{header.FirstUsableLBA},{header.LastUsableLBA}]')
      if outside_entries and entries_first_lba <= lba <= entries_last_lba:
        raise GPTError(f'{name} ({lba}) should be outside partition entries ['
                       f'{entries_first_lba},{entries_last_lba}]')

    CheckOutsideUsable('Header', header.CurrentLBA, True)
    CheckOutsideUsable('Backup header', header.BackupLBA, True)
    CheckOutsideUsable('Partition entries', entries_first_lba)
    CheckOutsideUsable('Partition entries end', entries_last_lba)

    parts = self.GetUsedPartitions()
    # Check if partition entries overlap with each other.
    lba_list = [(p.FirstLBA, p.LastLBA, p) for p in parts]
    lba_list.sort(key=lambda t: t[0])
    for i in range(len(lba_list) - 1):
      if lba_list[i][1] >= lba_list[i + 1][0]:
        raise GPTError(
            'Overlap in partition entries: '
            f'[{lba_list[i][0]},{lba_list[i][1]}]{lba_list[i][2]}, '
            f'[{lba_list[i+1][0]},{lba_list[i+1][1]}]{lba_list[i+1][2]}.')
    # Now, check the first and last partition.
    if lba_list:
      p = lba_list[0][2]
      if p.FirstLBA < header.FirstUsableLBA:
        raise GPTError(f'Partition {p} must not go earlier ({p.FirstLBA}) than '
                       f'FirstUsableLBA={header.FirstLBA}')
      p = lba_list[-1][2]
      if p.LastLBA > header.LastUsableLBA:
        raise GPTError(f'Partition {p} must not go further ({p.LastLBA}) than '
                       f'LastUsableLBA={header.LastLBA}')
    # Check if UniqueGUIDs are not unique.
    if len(set(p.UniqueGUID for p in parts)) != len(parts):
      raise GPTError('Partition UniqueGUIDs are duplicated.')
    # Check if CRCs match.
    if (binascii.crc32(b''.join(p.blob for p in self.partitions)) !=
        header.PartitionArrayCRC32):
      raise GPTError('GPT Header PartitionArrayCRC32 does not match.')
    header_crc = header.Clone()
    header_crc.UpdateChecksum()
    if header_crc.CRC32 != header.CRC32:
      raise GPTError('GPT Header CRC32 does not match.')

  def UpdateChecksum(self):
    """Updates all checksum fields in GPT objects."""
    parts = b''.join(p.blob for p in self.partitions)
    self.header.Update(PartitionArrayCRC32=binascii.crc32(parts))
    self.header.UpdateChecksum()

  def GetBackupHeader(self, header):
    """Returns the backup header according to given header.

    This should be invoked only after GPT.UpdateChecksum() has updated all CRC32
    fields.
    """
    partitions_starting_lba = (
        header.BackupLBA - self.GetPartitionTableBlocks())
    h = header.Clone()
    h.Update(
        BackupLBA=header.CurrentLBA,
        CurrentLBA=header.BackupLBA,
        PartitionEntriesStartingLBA=partitions_starting_lba)
    h.UpdateChecksum()
    return h

  @classmethod
  def WriteProtectiveMBR(cls, image, create, bootcode=None, boot_guid=None):
    """Writes a protective MBR to given file.

    Each MBR is 512 bytes: 424 bytes for bootstrap code, 16 bytes of boot GUID,
    4 bytes of disk id, 2 bytes of bootcode magic, 4*16 for 4 partitions, and 2
    byte as signature. cgpt has hard-coded the CHS and bootstrap magic values so
    we can follow that.

    Args:
      create: True to re-create PMBR structure.
      bootcode: a blob of new boot code.
      boot_guid a blob for new boot GUID.

    Returns:
      The written PMBR structure.
    """
    if isinstance(image, str):
      with open(image, 'rb+') as f:
        return cls.WriteProtectiveMBR(f, create, bootcode, boot_guid)

    image.seek(0)
    pmbr_format = cls.ProtectiveMBR.GetStructFormat()
    assert struct.calcsize(pmbr_format) == cls.DEFAULT_BLOCK_SIZE
    pmbr = cls.ProtectiveMBR.ReadFrom(image)

    if create:
      legacy_sectors = min(
          0x100000000,
          GPT.GetImageSize(image.name) // cls.DEFAULT_BLOCK_SIZE) - 1
      # Partition 0 must have have the fixed CHS with number of sectors
      # (calculated as legacy_sectors later).
      part0 = (codecs.decode('00000200eeffffff01000000', 'hex') +
               struct.pack('<I', legacy_sectors))
      # Partition 1~3 should be all zero.
      part1 = '\x00' * 16
      assert len(part0) == len(part1) == 16, 'MBR entry is wrong.'
      pmbr.Update(
          BootGUID=cls.TYPE_GUID_UNUSED,
          DiskID=0,
          Magic=pmbr.MAGIC,
          LegacyPart0=part0,
          LegacyPart1=part1,
          LegacyPart2=part1,
          LegacyPart3=part1,
          Signature=pmbr.SIGNATURE)

    if bootcode:
      if len(bootcode) > len(pmbr.BootCode):
        logging.info(
            'Bootcode is larger (%d > %d)!', len(bootcode), len(pmbr.BootCode))
        bootcode = bootcode[:len(pmbr.BootCode)]
      pmbr.Update(BootCode=bootcode)
    if boot_guid:
      pmbr.Update(BootGUID=boot_guid)

    blob = pmbr.blob
    assert len(blob) == cls.DEFAULT_BLOCK_SIZE
    image.seek(0)
    image.write(blob)
    return pmbr

  def WriteToFile(self, image):
    """Updates partition table in a disk image file.

    Args:
      image: a string as file path or a file-like object to write into.
    """
    if isinstance(image, str):
      with open(image, 'rb+') as f:
        return self.WriteToFile(f)

    def WriteData(name, blob, lba):
      """Writes a blob into given location."""
      logging.info('Writing %s in LBA %d (offset %d)',
                   name, lba, lba * self.block_size)
      image.seek(lba * self.block_size)
      image.write(blob)

    self.UpdateChecksum()
    self.CheckIntegrity()
    parts_blob = b''.join(p.blob for p in self.partitions)

    header = self.header
    WriteData('GPT Header', header.blob, header.CurrentLBA)
    WriteData('GPT Partitions', parts_blob, header.PartitionEntriesStartingLBA)
    logging.info(
        'Usable LBA: First=%d, Last=%d', header.FirstUsableLBA,
        header.LastUsableLBA)

    if not self.is_secondary:
      # When is_secondary is True, the header we have is actually backup header.
      backup_header = self.GetBackupHeader(self.header)
      WriteData(
          'Backup Partitions', parts_blob,
          backup_header.PartitionEntriesStartingLBA)
      WriteData(
          'Backup Header', backup_header.blob, backup_header.CurrentLBA)
    return None

  def IsLastPartition(self, part):
    """Check partition `part` is the last partition or not.

    Args:
      part: the partition number.

    Returns:
      The partition is the last partition or not.
    """
    part = self.GetPartition(part)

    return not part.IsUnused() and self.GetMaxUsedLBA() == part.LastLBA


class GPTCommands:
  """Collection of GPT sub commands for command line to use.

  The commands are derived from `cgpt`, but not necessary to be 100% compatible
  with cgpt.
  """

  FORMAT_ARGS = [
      ('begin', 'beginning sector'),
      ('size', 'partition size (in sectors)'),
      ('type', 'type guid'),
      ('unique', 'unique guid'),
      ('label', 'label'),
      ('Successful', 'Successful flag'),
      ('Tries', 'Tries flag'),
      ('Priority', 'Priority flag'),
      ('Legacy', 'Legacy Boot flag'),
      ('Attribute', 'raw 16-bit attribute value (bits 48-63)')]

  def __init__(self):
    commands = {
        command.lower(): getattr(self, command)()
        for command in dir(self)
        if (isinstance(getattr(self, command), type) and
            issubclass(getattr(self, command), self.SubCommand) and
            getattr(self, command) is not self.SubCommand)
    }
    self.commands = commands

  def DefineArgs(self, parser):
    """Defines all available commands to an argparser subparsers instance."""
    subparsers = parser.add_subparsers(title='subcommands',
                                       help='Sub-command help.', dest='command')
    subparsers.required = True
    for name, instance in sorted(self.commands.items()):
      parser = subparsers.add_parser(
          name, description=instance.__doc__,
          formatter_class=argparse.RawDescriptionHelpFormatter,
          help=instance.__doc__.splitlines()[0])
      instance.DefineArgs(parser)

  def Execute(self, args):
    """Execute the sub commands by given parsed arguments."""
    return self.commands[args.command].Execute(args)

  class SubCommand:
    """A base class for sub commands to derive from."""

    def DefineArgs(self, parser):
      """Defines command line arguments to argparse parser.

      Args:
        parser: An argparse parser instance.
      """
      del parser  # Unused.
      raise NotImplementedError

    def Execute(self, args):
      """Execute the command with parsed arguments.

      To execute with raw arguments, use ExecuteCommandLine instead.

      Args:
        args: An argparse parsed namespace.
      """
      del args  # Unused.
      raise NotImplementedError

    def ExecuteCommandLine(self, *args):
      """Execute as invoked from command line.

      This provides an easy way to execute particular sub command without
      creating argument parser explicitly.

      Args:
        args: a list of string type command line arguments.
      """
      parser = argparse.ArgumentParser()
      self.DefineArgs(parser)
      return self.Execute(parser.parse_args(args))

  class Create(SubCommand):
    """Create or reset GPT headers and tables.

    Create or reset an empty GPT.
    """

    def DefineArgs(self, parser):
      parser.add_argument(
          '-z', '--zero', action='store_true',
          help='Zero the sectors of the GPT table and entries')
      parser.add_argument(
          '-p', '--pad-blocks', type=int, default=0,
          help=('Size (in blocks) of the disk to pad between the '
                'primary GPT header and its entries, default %(default)s'))
      parser.add_argument(
          '--block_size', type=int,
          help='Size of each block (sector) in bytes.')
      parser.add_argument(
          'image_file', type=argparse.FileType('rb+'),
          help='Disk image file to create.')

    def Execute(self, args):
      block_size = args.block_size
      if block_size is None:
        if GPT.IsBlockDevice(args.image_file.name):
          block_size = GPT.GetLogicalBlockSize(args.image_file.name)
        else:
          block_size = GPT.DEFAULT_BLOCK_SIZE

      if block_size != GPT.DEFAULT_BLOCK_SIZE:
        logging.info('Block (sector) size for %s is set to %s bytes.',
                     args.image_file.name, block_size)

      gpt = GPT.Create(
          args.image_file.name, GPT.GetImageSize(args.image_file.name),
          block_size, args.pad_blocks)
      if args.zero:
        # In theory we only need to clear LBA 1, but to make sure images already
        # initialized with different block size won't have GPT signature in
        # different locations, we should zero until first usable LBA.
        args.image_file.seek(0)
        args.image_file.write(b'\0' * block_size * gpt.header.FirstUsableLBA)
      gpt.WriteToFile(args.image_file)
      args.image_file.close()
      return f'Created GPT for {args.image_file.name}'

  class Boot(SubCommand):
    """Edit the PMBR sector for legacy BIOSes.

    With no options, it will just print the PMBR boot guid.
    """

    def DefineArgs(self, parser):
      parser.add_argument(
          '-i', '--number', type=int,
          help='Set bootable partition')
      parser.add_argument(
          '-b', '--bootloader', type=argparse.FileType('rb'),
          help='Install bootloader code in the PMBR')
      parser.add_argument(
          '-p', '--pmbr', action='store_true',
          help='Create legacy PMBR partition table')
      parser.add_argument(
          'image_file', type=argparse.FileType('rb+'),
          help='Disk image file to change PMBR.')

    def Execute(self, args):
      """Rebuilds the protective MBR."""
      bootcode = args.bootloader.read() if args.bootloader else None
      boot_guid = None
      if args.number is not None:
        gpt = GPT.LoadFromFile(args.image_file)
        boot_guid = gpt.GetPartition(args.number).UniqueGUID
      pmbr = GPT.WriteProtectiveMBR(
          args.image_file, args.pmbr, bootcode=bootcode, boot_guid=boot_guid)

      print(pmbr.BootGUID)
      args.image_file.close()
      return 0

  class Legacy(SubCommand):
    """Switch between GPT and Legacy GPT.

    Switch GPT header signature to "CHROMEOS".
    """

    def DefineArgs(self, parser):
      parser.add_argument(
          '-e', '--efi', action='store_true',
          help='Switch GPT header signature back to "EFI PART"')
      parser.add_argument(
          '-p', '--primary-ignore', action='store_true',
          help='Switch primary GPT header signature to "IGNOREME"')
      parser.add_argument(
          'image_file', type=argparse.FileType('rb+'),
          help='Disk image file to change.')

    def Execute(self, args):
      gpt = GPT.LoadFromFile(args.image_file)
      # cgpt behavior: if -p is specified, -e is ignored.
      if args.primary_ignore:
        if gpt.is_secondary:
          raise GPTError('Sorry, the disk already has primary GPT ignored.')
        args.image_file.seek(gpt.header.CurrentLBA * gpt.block_size)
        args.image_file.write(gpt.header.SIGNATURE_IGNORE)
        gpt.header = gpt.GetBackupHeader(self.header)
        gpt.is_secondary = True
      else:
        new_signature = gpt.Header.SIGNATURES[0 if args.efi else 1]
        gpt.header.Update(Signature=new_signature)
      gpt.WriteToFile(args.image_file)
      args.image_file.close()
      if args.primary_ignore:
        return (f'Set {args.image_file.name} primary GPT header to '
                f'{gpt.header.SIGNATURE_IGNORE}.')
      return (
          f'Changed GPT signature for {args.image_file.name} to {new_signature}'
          '.')

  class Repair(SubCommand):
    """Repair damaged GPT headers and tables."""

    def DefineArgs(self, parser):
      parser.add_argument('image_file', type=argparse.FileType('rb+'),
                          help='Disk image file to repair.')

    def Execute(self, args):
      gpt = GPT.LoadFromFile(args.image_file)
      gpt.Resize(GPT.GetImageSize(args.image_file.name))
      gpt.WriteToFile(args.image_file)
      args.image_file.close()
      return f'Disk image file {args.image_file.name} repaired.'

  class Expand(SubCommand):
    """Expands a GPT partition to all available free space."""

    def DefineArgs(self, parser):
      parser.add_argument('-i', '--number', type=int, required=True,
                          help='The partition to expand.')
      parser.add_argument(
          'image_file', type=argparse.FileType('rb+'),
          help='Disk image file to modify.')

    def Execute(self, args):
      gpt = GPT.LoadFromFile(args.image_file)
      old_blocks, new_blocks = gpt.ExpandPartition(args.number)
      gpt.WriteToFile(args.image_file)
      args.image_file.close()
      if old_blocks < new_blocks:
        return (
            f'Partition {args.number} on disk image file {args.image_file.name}'
            f' has been extended from {old_blocks * gpt.block_size} to '
            f'{new_blocks * gpt.block_size} .')
      return (
          f'Nothing to expand for disk image {args.image_file.name} partition '
          f'{args.number}.')

  class Add(SubCommand):
    """Add, edit, or remove a partition entry.

    Use the -i option to modify an existing partition.
    The -b, -s, and -t options must be given for new partitions.

    The partition type may also be given as one of these aliases:

      firmware    ChromeOS firmware
      kernel      ChromeOS kernel
      rootfs      ChromeOS rootfs
      minios      ChromeOS MINIOS
      hibernate   ChromeOS hibernate
      data        Linux data
      reserved    ChromeOS reserved
      efi         EFI System Partition
      unused      Unused (nonexistent) partition
    """
    def DefineArgs(self, parser):
      parser.add_argument(
          '-i', '--number', type=int,
          help='Specify partition (default is next available)')
      parser.add_argument(
          '-b', '--begin', type=int,
          help='Beginning sector')
      parser.add_argument(
          '-s', '--sectors', type=int,
          help='Size in sectors (logical blocks).')
      parser.add_argument(
          '-t', '--type-guid', type=GPT.GetTypeGUID,
          help='Partition Type GUID')
      parser.add_argument(
          '-u', '--unique-guid', type=GUID,
          help='Partition Unique ID')
      parser.add_argument(
          '-l', '--label',
          help='Label')
      parser.add_argument(
          '-S', '--successful', type=int, choices=list(range(2)),
          help='set Successful flag')
      parser.add_argument(
          '-T', '--tries', type=int,
          help='set Tries flag (0-15)')
      parser.add_argument(
          '-P', '--priority', type=int,
          help='set Priority flag (0-15)')
      parser.add_argument(
          '-R', '--required', type=int, choices=list(range(2)),
          help='set Required flag')
      parser.add_argument(
          '-B', '--boot-legacy', dest='legacy_boot', type=int,
          choices=list(range(2)),
          help='set Legacy Boot flag')
      parser.add_argument(
          '-A', '--attribute', dest='raw_16', type=int,
          help='set raw 16-bit attribute value (bits 48-63)')
      parser.add_argument(
          'image_file', type=argparse.FileType('rb+'),
          help='Disk image file to modify.')

    def Execute(self, args):
      gpt = GPT.LoadFromFile(args.image_file)
      number = args.number
      if number is None:
        number = next(p for p in gpt.partitions if p.IsUnused()).number

      # First and last LBA must be calculated explicitly because the given
      # argument is size.
      part = gpt.GetPartition(number)
      is_new_part = part.IsUnused()

      if is_new_part:
        part.Zero()
        part.Update(
            FirstLBA=gpt.GetMaxUsedLBA() + 1,
            LastLBA=gpt.header.LastUsableLBA,
            UniqueGUID=GUID.Random(),
            TypeGUID=gpt.GetTypeGUID('data'))

      def UpdateAttr(name):
        value = getattr(args, name)
        if value is None:
          return
        setattr(attrs, name, value)

      def GetArg(arg_value, default_value):
        return default_value if arg_value is None else arg_value

      attrs = part.Attributes
      for name in [
          'legacy_boot', 'required', 'priority', 'tries', 'successful', 'raw_16'
      ]:
        UpdateAttr(name)
      first_lba = GetArg(args.begin, part.FirstLBA)
      part.Update(
          Names=GetArg(args.label, part.Names), FirstLBA=first_lba,
          LastLBA=first_lba - 1 + GetArg(args.sectors, part.blocks),
          TypeGUID=GetArg(args.type_guid, part.TypeGUID), UniqueGUID=GetArg(
              args.unique_guid, part.UniqueGUID), Attributes=attrs)

      # Wipe partition again if it should be empty.
      if part.IsUnused():
        part.Zero()

      gpt.WriteToFile(args.image_file)
      args.image_file.close()
      if part.IsUnused():
        # If we do ('%s' % part) there will be TypeError.
        return f'Deleted (zeroed) {part}.'
      return (
          f"{'Added' if is_new_part else 'Modified'} {part} ({part.FirstLBA}+"
          f"{part.blocks}).")

  class Show(SubCommand):
    """Show partition table and entries.

    Display the GPT table.
    """

    def DefineArgs(self, parser):
      parser.add_argument('--numeric', '-n', action='store_true',
                          help='Numeric output only.')
      parser.add_argument(
          '--quick', '-q', action='store_true',
          help='Quick output.')
      parser.add_argument(
          '-i', '--number', type=int,
          help='Show specified partition only, with format args.')
      for name, help_str in GPTCommands.FORMAT_ARGS:
        # TODO(hungte) Alert if multiple args were specified.
        parser.add_argument(f'--{name}', f'-{name[0]}', action='store_true',
                            help=f'[format] {help_str}.')
      parser.add_argument('image_file', type=argparse.FileType('rb'),
                          help='Disk image file to show.')

    def Execute(self, args):
      """Show partition table and entries."""

      def FormatTypeGUID(p):
        guid = p.TypeGUID
        if not args.numeric:
          names = gpt.TYPE_GUID_MAP.get(guid)
          if names:
            return names
        return str(guid)

      def IsBootableType(guid):
        if not guid:
          return False
        return guid in gpt.TYPE_GUID_LIST_BOOTABLE

      def FormatAttribute(attrs, chromeos_kernel=False):
        if args.numeric:
          return f'[{attrs.raw >> 48:x}]'
        results = []
        if chromeos_kernel:
          results += [
              f'priority={int(attrs.priority)}', f'tries={int(attrs.tries)}',
              f'successful={int(attrs.successful)}'
          ]
        if attrs.required:
          results += ['required=1']
        if attrs.legacy_boot:
          results += ['legacy_boot=1']
        return ' '.join(results)

      def ApplyFormatArgs(p):
        if args.begin:
          return p.FirstLBA
        if args.size:
          return p.blocks
        if args.type:
          return FormatTypeGUID(p)
        if args.unique:
          return p.UniqueGUID
        if args.label:
          return p.Names
        if args.Successful:
          return p.Attributes.successful
        if args.Priority:
          return p.Attributes.priority
        if args.Tries:
          return p.Attributes.tries
        if args.Legacy:
          return p.Attributes.legacy_boot
        if args.Attribute:
          return f'[{p.Attributes.raw >> 48:x}]'
        return None

      def IsFormatArgsSpecified():
        return any(getattr(args, arg[0]) for arg in GPTCommands.FORMAT_ARGS)

      gpt = GPT.LoadFromFile(args.image_file)
      logging.debug('%r', gpt.header)
      fmt = '%12s %11s %7s  %s'
      fmt2 = '%32s  %s: %s'
      header = ('start', 'size', 'part', 'contents')

      if IsFormatArgsSpecified() and args.number is None:
        raise GPTError('Format arguments must be used with -i.')

      if not (args.number is None or
              0 < args.number <= gpt.header.PartitionEntriesNumber):
        raise GPTError(f'Invalid partition number: {int(args.number)}')

      partitions = gpt.partitions
      do_print_gpt_blocks = False
      if not (args.quick or IsFormatArgsSpecified()):
        print(fmt % header)
        if args.number is None:
          do_print_gpt_blocks = True

      if do_print_gpt_blocks:
        if gpt.pmbr:
          print(fmt % (0, 1, '', 'PMBR'))
        if gpt.is_secondary:
          print(fmt % (gpt.header.BackupLBA, 1, 'IGNORED', 'Pri GPT header'))
        else:
          print(fmt % (gpt.header.CurrentLBA, 1, '', 'Pri GPT header'))
          print(fmt % (gpt.header.PartitionEntriesStartingLBA,
                       gpt.GetPartitionTableBlocks(), '', 'Pri GPT table'))

      for p in partitions:
        if args.number is None:
          # Skip unused partitions.
          if p.IsUnused():
            continue
        elif p.number != args.number:
          continue

        if IsFormatArgsSpecified():
          print(ApplyFormatArgs(p))
          continue

        print(
            fmt % (p.FirstLBA, p.blocks, p.number,
                   FormatTypeGUID(p) if args.quick else f'Label: "{p.Names}"'))

        if not args.quick:
          print(fmt2 % ('', 'Type', FormatTypeGUID(p)))
          print(fmt2 % ('', 'UUID', p.UniqueGUID))
          if args.numeric or IsBootableType(p.TypeGUID):
            print(fmt2 % ('', 'Attr',
                          FormatAttribute(p.Attributes, p.IsChromeOSKernel())))

      if do_print_gpt_blocks:
        if gpt.is_secondary:
          header = gpt.header
        else:
          f = args.image_file
          f.seek(gpt.header.BackupLBA * gpt.block_size)
          header = gpt.Header.ReadFrom(f)
        print(fmt % (header.PartitionEntriesStartingLBA,
                     gpt.GetPartitionTableBlocks(header), '',
                     'Sec GPT table'))
        print(fmt % (header.CurrentLBA, 1, '', 'Sec GPT header'))

      # Check integrity after showing all fields.
      gpt.CheckIntegrity()

  class Prioritize(SubCommand):
    """Reorder the priority of all kernel partitions.

    Reorder the priority of all active ChromeOS Kernel partitions.

    With no options this will set the lowest active kernel to priority 1 while
    maintaining the original order.
    """

    def DefineArgs(self, parser):
      parser.add_argument(
          '-P', '--priority', type=int,
          help=('Highest priority to use in the new ordering. '
                'The other partitions will be ranked in decreasing '
                'priority while preserving their original order. '
                'If necessary the lowest ranks will be coalesced. '
                'No active kernels will be lowered to priority 0.'))
      parser.add_argument(
          '-i', '--number', type=int,
          help='Specify the partition to make the highest in the new order.')
      parser.add_argument(
          '-f', '--friends', action='store_true',
          help=('Friends of the given partition (those with the same '
                'starting priority) are also updated to the new '
                'highest priority. '))
      parser.add_argument(
          'image_file', type=argparse.FileType('rb+'),
          help='Disk image file to prioritize.')

    def Execute(self, args):
      gpt = GPT.LoadFromFile(args.image_file)
      parts = [p for p in gpt.partitions if p.IsChromeOSKernel()]
      parts.sort(key=lambda p: p.Attributes.priority, reverse=True)
      groups = {k: list(g) for k, g in itertools.groupby(
          parts, lambda p: p.Attributes.priority)}
      if args.number:
        p = gpt.GetPartition(args.number)
        if p not in parts:
          raise GPTError(f'{p} is not a ChromeOS kernel.')
        pri = p.Attributes.priority
        friends = groups.pop(pri)
        new_pri = max(groups) + 1
        if args.friends:
          groups[new_pri] = friends
        else:
          groups[new_pri] = [p]
          friends.remove(p)
          if friends:
            groups[pri] = friends

      if 0 in groups:
        # Do not change any partitions with priority=0
        groups.pop(0)

      prios = list(groups)
      prios.sort(reverse=True)

      # Max priority is 0xf.
      highest = min(args.priority or len(prios), 0xf)
      logging.info('New highest priority: %s', highest)

      for i, pri in enumerate(prios):
        new_priority = max(1, highest - i)
        for p in groups[pri]:
          attrs = p.Attributes
          old_priority = attrs.priority
          if old_priority == new_priority:
            continue
          attrs.priority = new_priority
          if attrs.tries < 1 and not attrs.successful:
            attrs.tries = 15  # Max tries for new active partition.
          p.Update(Attributes=attrs)
          logging.info('%s priority changed from %s to %s.', p, old_priority,
                       new_priority)

      gpt.WriteToFile(args.image_file)
      args.image_file.close()

  class Find(SubCommand):
    """Locate a partition by its GUID.

    Find a partition by its UUID or label. With no specified DRIVE it scans all
    physical drives.

    The partition type may also be given as one of these aliases:

        firmware    ChromeOS firmware
        kernel      ChromeOS kernel
        rootfs      ChromeOS rootfs
        minios      ChromeOS MINIOS
        hibernate   ChromeOS hibernate
        data        Linux data
        reserved    ChromeOS reserved
        efi         EFI System Partition
        unused      Unused (nonexistent) partition
    """
    def DefineArgs(self, parser):
      parser.add_argument(
          '-t', '--type-guid', type=GPT.GetTypeGUID,
          help='Search for Partition Type GUID')
      parser.add_argument(
          '-u', '--unique-guid', type=GUID,
          help='Search for Partition Unique GUID')
      parser.add_argument(
          '-l', '--label',
          help='Search for Label')
      parser.add_argument('-n', '--numeric', action='store_true',
                          help='Numeric output only.')
      parser.add_argument(
          '-1', '--single-match', action='store_true',
          help='Fail if more than one match is found.')
      parser.add_argument(
          '-M', '--match-file', type=str,
          help='Matching partition data must also contain MATCH_FILE content.')
      parser.add_argument(
          '-O', '--offset', type=int, default=0,
          help='Byte offset into partition to match content (default 0).')
      parser.add_argument(
          'drive', type=argparse.FileType('rb+'), nargs='?',
          help='Drive or disk image file to find.')

    def Execute(self, args):
      if not any((args.type_guid, args.unique_guid, args.label)):
        raise GPTError('You must specify at least one of -t, -u, or -l')

      if args.drive:
        drives = [args.drive.name]
        args.drive.close()
      else:
        drives = [
            f'/dev/{name}' for name in subprocess.check_output(
                'lsblk -d -n -r -o name', shell=True, encoding='utf-8').split()
        ]

      match_pattern = None
      if args.match_file:
        with open(args.match_file, encoding='utf8') as f:
          match_pattern = f.read()

      found = 0
      for drive in drives:
        try:
          gpt = GPT.LoadFromFile(drive)
        except GPTError:
          if args.drive:
            raise
          # When scanning all block devices on system, ignore failure.

        def Unmatch(a, b):
          return a is not None and a != b

        for p in gpt.partitions:
          if (p.IsUnused() or
              Unmatch(args.label, p.Names) or
              Unmatch(args.unique_guid, p.UniqueGUID) or
              Unmatch(args.type_guid, p.TypeGUID)):
            continue
          if match_pattern:
            with open(drive, 'rb') as f:
              f.seek(p.offset + args.offset)
              if f.read(len(match_pattern)) != match_pattern:
                continue
          # Found the partition, now print.
          found += 1
          if args.numeric:
            print(p.number)
          else:
            # This is actually more for block devices.
            print(f"{p.image}{'p' if p.image[-1].isdigit() else ''}{p.number}")

      if found < 1 or (args.single_match and found > 1):
        return 1
      return 0


def main():
  commands = GPTCommands()
  parser = argparse.ArgumentParser(description='GPT Utility.')
  parser.add_argument('--verbose', '-v', action='count', default=0,
                      help='increase verbosity.')
  parser.add_argument('--debug', '-d', action='store_true',
                      help='enable debug output.')
  commands.DefineArgs(parser)

  args = parser.parse_args()
  log_level = max(logging.WARNING - args.verbose * 10, logging.DEBUG)
  if args.debug:
    log_level = logging.DEBUG
  logging.basicConfig(format='%(module)s:%(funcName)s %(message)s',
                      level=log_level)
  try:
    code = commands.Execute(args)
    if isinstance(code, int):
      sys.exit(code)
    elif isinstance(code, str):
      print(f'OK: {code}')
  except Exception as e:
    if args.verbose or args.debug:
      logging.exception('Failure in command [%s]', args.command)
    sys.exit(f"ERROR: {args.command}: {str(e) or 'Unknown error.'}")


if __name__ == '__main__':
  main()
