#!/usr/bin/env python3
# Copyright 2018 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# modified for use with sh1mmer (c82de050bcc1e0434c4d90d874473195475df95b)

"""Utility to manipulate Chrome OS disk & firmware images for manufacturing.

Run "image_tool help" for more info and a list of subcommands.

To add a subcommand, just add a new SubCommand subclass to this file.
"""

import argparse
import contextlib
import copy
from distutils import version as version_utils
import errno
import glob
import inspect
import json
import logging
import os
import pipes
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import time
from typing import Any, Dict
import urllib.parse

import yaml


# The edit_lsb command works better if readline enabled, but will still work if
# that is not available.
try:
  import readline  # pylint: disable=unused-import
except ImportError:
  pass

# This file needs to run on various environments, for example a fresh Ubuntu
# that does not have Chromium OS source tree nor chroot. So we do want to
# prevent introducing more cros.factory dependency except very few special
# modules (pygpt, fmap, netboot_firmware_settings).
# Please don't add more cros.factory modules.
# TODO(kerker) Find a way to remove this in future
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.realpath(__file__)))), 'py_pkg'))
import netboot_firmware_settings  # pylint: disable=wrong-import-position
import fmap  # pylint: disable=wrong-import-position
import pygpt  # pylint: disable=wrong-import-position


# Partition index for Chrome OS stateful partition.
PART_CROS_STATEFUL = 1
# Partition index for Chrome OS kernel A.
PART_CROS_KERNEL_A = 2
# Partition index for Chrome OS rootfs A.
PART_CROS_ROOTFS_A = 3
# Partition index for Chrome OS kernel B.
PART_CROS_KERNEL_B = 4
# Partition index for Chrome OS rootfs B.
PART_CROS_ROOTFS_B = 5
# Partition index for ChromeOS MiniOS B.
PART_CROS_MINIOS_B = 10
# Special options to mount Chrome OS rootfs partitions. (-t ext2, -o ro).
FS_TYPE_CROS_ROOTFS = 'ext2'
# Relative path of firmware updater on Chrome OS disk images.
PATH_CROS_FIRMWARE_UPDATER = '/usr/sbin/chromeos-firmwareupdate'
# Relative path of lsb-factory in factory installer.
PATH_LSB_FACTORY = os.path.join('dev_image', 'etc', 'lsb-factory')
# Preflash disk image default board name.
PREFLASH_DEFAULT_BOARD = 'preflash'
# Relative path of payload metadata in a preflash disk image.
PATH_PREFLASH_PAYLOADS_JSON = os.path.join('dev_image', 'etc',
                                           f'{PREFLASH_DEFAULT_BOARD}.json')
# Relative path of RMA image metadata.
CROS_RMA_METADATA = 'rma_metadata.json'
# Mode for new created folder, 0755 = u+rwx, go+rx
MODE_NEW_DIR = 0o755
# Regular expression for parsing LSB value, which should be sh compatible.
RE_LSB = re.compile(r'^ *(.*)="?(.*[^"])"?$', re.MULTILINE)
# Key for Chrome OS board name in /etc/lsb-release.
KEY_LSB_CROS_BOARD = 'CHROMEOS_RELEASE_BOARD'
# Key for Chrome OS build version in /etc/lsb-release.
KEY_LSB_CROS_VERSION = 'CHROMEOS_RELEASE_VERSION'
# Regular expression for reading file system information from dumpe2fs.
RE_BLOCK_COUNT = re.compile(r'^Block count: *(.*)$', re.MULTILINE)
RE_BLOCK_SIZE = re.compile(r'^Block size: *(.*)$', re.MULTILINE)
# Simple constant(s)
MEGABYTE = 1048576
# The storage industry treat "mega" and "giga" differently.
GIGABYTE_STORAGE = 1000000000
# Default size of each disk block (or sector).
DEFAULT_BLOCK_SIZE = pygpt.GPT.DEFAULT_BLOCK_SIZE
# Components for preflash image.
PREFLASH_COMPONENTS = [
    'release_image', 'test_image', 'toolkit', 'hwid', 'project_config']
# Components for cros_payload.
PAYLOAD_COMPONENTS = [
    'release_image', 'test_image',
    'toolkit', 'firmware', 'hwid', 'complete', 'toolkit_config', 'lsb_factory',
    'description', 'project_config']
# Payload types
PAYLOAD_TYPE_TOOLKIT = 'toolkit'
PAYLOAD_TYPE_TOOLKIT_CONFIG = 'toolkit_config'
PAYLOAD_TYPE_LSB_FACTORY = 'lsb_factory'
# Payload subtypes.
PAYLOAD_SUBTYPE_VERSION = 'version'
# Warning message in lsb-factory file.
LSB_FACTORY_WARNING_MESSAGE = (
    '# Please use image_tool to set lsb-factory config.\n'
    '# Manual modifications will be overwritten at runtime!\n')
# Subconfigs in toolkit_config payload.
TOOLKIT_SUBCONFIG_ACTIVE_TEST_LIST = 'active_test_list'
TOOLKIT_SUBCONFIG_TEST_LIST_CONSTANTS = 'test_list_constants'
TOOLKIT_SUBCONFIG_CUTOFF = 'cutoff'
# Split line for separating outputs.
SPLIT_LINE = '=' * 72
# Command line namespaces.
CMD_NAMESPACE_PAYLOAD = 'payload'
CMD_NAMESPACE_RMA = 'rma'


def MakePartition(block_dev, part):
  """Helper function to build Linux device path for storage partition."""
  return f"{block_dev}{'p' if block_dev[-1].isdigit() else ''}{part}"


class ArgTypes:
  """Helper class to collect all argument type checkers."""

  @classmethod
  def ExistsPath(cls, path):
    """An argument with existing path."""
    if not os.path.exists(path):
      raise argparse.ArgumentTypeError(f'Does not exist: {path}')
    return path

  @classmethod
  def GlobPath(cls, pattern):
    """An argument as glob pattern, and solved as single path.

    This is a useful type to specify default values with wildcard.
    If the pattern is prefixed with '-', the value is returned as None without
    raising exceptions.
    If the pattern has '|', split the pattern by '|' and return the first
    matched pattern.
    """
    allow_none = False
    if pattern.startswith('-'):
      # Special trick to allow defaults.
      pattern = pattern[1:]
      allow_none = True
    goals = pattern.split('|')
    for i, goal in enumerate(goals):
      found = glob.glob(goal)
      if len(found) < 1:
        if i + 1 < len(goals):
          continue
        if allow_none:
          return None
        raise argparse.ArgumentTypeError(f'Does not exist: {pattern}')
      if len(found) > 1:
        raise argparse.ArgumentTypeError(
            f'Too many files found for <{pattern}>: {found}')
      return found[0]


class SysUtils:
  """Collection of system utilities."""

  @classmethod
  def Shell(cls, commands, sudo=False, output=False, check=True, silent=False,
            log_stderr_on_error=None, **kargs):
    """Helper to execute 'sudo' command in a shell.

    A simplified implementation. To reduce dependency, we don't want to use
    process_utils.Spawn.

    Args:
      sudo: Execute the command with sudo if needed.
      output: If it is True, returns the output from command. Otherwise, returns
        the returncode.
      check: Throws exception if returncode is not zero.
      silent: Sets stdout and stderr to DEVNULL.
      log_stderr_on_error: Logs stderr only if the command fails. If it is None,
        then it is set to 'check and silent'.
    """
    if log_stderr_on_error is None:
      log_stderr_on_error = check and silent
    if not isinstance(commands, str):
      commands = ' '.join(pipes.quote(arg) for arg in commands)
    kargs['shell'] = True
    kargs['encoding'] = 'utf-8'

    if sudo and os.geteuid() != 0:
      commands = 'sudo -E ' + commands
    if silent:
      kargs['stdout'] = subprocess.DEVNULL
      kargs['stderr'] = subprocess.DEVNULL
    if output:
      kargs['stdout'] = subprocess.PIPE
    if log_stderr_on_error:
      kargs['stderr'] = subprocess.PIPE

    process = subprocess.run(commands, check=False, **kargs)
    if process.returncode != 0 and log_stderr_on_error:
      print(f'command: {commands!r} stdout:\n {process.stdout}\nstderr:\n'
            f'{process.stderr}')
    if check:
      process.check_returncode()
    return process.stdout if output else process.returncode

  @classmethod
  def Sudo(cls, commands, **kargs):
    """Shortcut to Shell(commands, sudo=True)."""
    kargs['sudo'] = True
    return cls.Shell(commands, **kargs)

  @classmethod
  def SudoOutput(cls, commands, **kargs):
    """Shortcut to Sudo(commands, output=True)."""
    kargs['output'] = True
    return cls.Sudo(commands, **kargs)

  @classmethod
  def FindCommand(cls, command):
    """Returns the right path to invoke given command."""
    provided = os.path.join(
        os.path.dirname(os.path.abspath(sys.argv[0])), command)
    if not os.path.exists(provided):
      provided = cls.Shell(['which', command], output=True, check=False).strip()
    if not provided:
      raise RuntimeError(f'Cannot find program: {command}')
    return provided

  @classmethod
  def FindCommands(cls, *commands):
    """Find any of the given commands in order."""
    for cmd in commands:
      try:
        return cls.FindCommand(cmd)
      except Exception:
        pass
    raise RuntimeError(
        f"Cannot find any of the following commands: {', '.join(commands)}")

  @classmethod
  def FindCGPT(cls):
    """Returns the best match of `cgpt` style command.

    The `cgpt` is a native program that is hard to deploy. As an alternative, we
    have the `pygpt` that emulates most of its functions, and that is accessible
    via `image_tool gpt`.
    """
    if os.path.exists(__file__) and os.access(__file__, os.X_OK):
      return f'{__file__} gpt'

    # Are we inside PAR?
    par_path = os.environ.get('PAR_PATH')
    if par_path:
      if os.path.basename(par_path) == 'image_tool':
        return f'{par_path} gpt'
      return f'sh {par_path} image_tool gpt'

    # Nothing more - let's try to find the real programs.
    return cls.FindCommands('pygpt', 'cgpt')

  @classmethod
  def FindBZip2(cls):
    """Returns a path to best working 'bzip2'."""
    return cls.FindCommands('lbzip2', 'pbzip2', 'bzip2')

  @classmethod
  @contextlib.contextmanager
  def TempDirectory(cls, prefix='imgtool_', delete=True):
    """Context manager to allocate and remove temporary folder.

    Args:
      prefix: a string as prefix of the created folder name.
    """
    tmp_folder = None
    try:
      tmp_folder = tempfile.mkdtemp(prefix=prefix)
      yield tmp_folder
    finally:
      if tmp_folder and delete:
        Sudo(['rm', '-rf', tmp_folder], check=False)

  @classmethod
  def PartialCopyFromStream(cls, src_stream, count, dest_path, dest_offset=0,
                            buffer_size=32 * MEGABYTE, sync=False,
                            verbose=None):
    """Copy partial contents from one stream to another file, like 'dd'."""
    if verbose is None:
      verbose = count // buffer_size > 5
    with open(dest_path, 'r+b') as dest:
      fd = dest.fileno()
      dest.seek(dest_offset)
      remains = count
      while remains > 0:
        data = src_stream.read(min(remains, buffer_size))
        dest.write(data)
        remains -= len(data)
        if sync:
          dest.flush()
          os.fdatasync(fd)
        if verbose:
          if sys.stderr.isatty():
            width = 5
            sys.stderr.write(
                '%*.1f%%%s' % (width,
                               (1 - remains / count) * 100, '\b' * (width + 1)))
          else:
            sys.stderr.write('.')
    if verbose:
      sys.stderr.write('\n')

  @classmethod
  def GetDiskUsage(cls, path):
    return int(SudoOutput(['du', '-sk', path]).split()[0]) * 1024

  @classmethod
  def GetRemainingSize(cls, path):
    return int(
        SudoOutput(['df', '-k', '--output=avail', path]).splitlines()[1]) * 1024

  @classmethod
  def WriteFile(cls, f, content):
    """Clears the original content and write new content to a file object."""
    f.seek(0)
    f.truncate()
    f.write(content)
    f.flush()

  @classmethod
  def WriteFileToMountedDir(cls, mounted_dir, file_name, content):
    with tempfile.NamedTemporaryFile('w') as f:
      f.write(content)
      f.flush()
      os.chmod(f.name, 0o644)
      dest = os.path.join(mounted_dir, file_name)
      Sudo(['cp', '-pf', f.name, dest])
      Sudo(['chown', 'root:root', dest])

  @classmethod
  @contextlib.contextmanager
  def SetUmask(cls, mask):
    old_umask = os.umask(mask)
    try:
      yield
    finally:
      os.umask(old_umask)

  @classmethod
  def CreateDirectories(cls, dir_name, mode=MODE_NEW_DIR):
    with SysUtils.SetUmask(0o022):
      try:
        os.makedirs(dir_name, mode)
      except OSError as exc:
        # Need to catch ourself before python 3.2 exist_ok.
        if exc.errno != errno.EEXIST or not os.path.isdir(dir_name):
          raise

# Short cut to SysUtils.
Shell = SysUtils.Shell
Sudo = SysUtils.Sudo
SudoOutput = SysUtils.SudoOutput


class CrosPayloadUtils:
  """Collection of cros_payload utilities."""

  _cros_payload = None
  _cros_payloads_dir = None
  _cros_rma_metadata_path = None

  @classmethod
  def GetProgramPath(cls):
    """Gets the path for `cros_payload` program."""
    if cls._cros_payload:
      return cls._cros_payload
    cls._cros_payload = SysUtils.FindCommand('cros_payload')
    return cls._cros_payload

  @classmethod
  def GetCrosPayloadsDir(cls):
    # The name of folder must match /etc/init/cros-payloads.conf.
    if not cls._cros_payloads_dir:
      cmd = [cls.GetProgramPath(), 'get_cros_payloads_dir']
      result = SudoOutput(cmd)
      if not result:
        raise RuntimeError(f'{cmd} returns empty path {result!r}.')
      cls._cros_payloads_dir = result
    return cls._cros_payloads_dir

  @classmethod
  def GetCrosRMAMetadata(cls):
    if not cls._cros_rma_metadata_path:
      cls._cros_rma_metadata_path = os.path.join(
          cls.GetCrosPayloadsDir(), CROS_RMA_METADATA)
    return cls._cros_rma_metadata_path

  @classmethod
  def GetJSONPath(cls, payloads_dir, board):
    return os.path.join(payloads_dir, f'{board}.json')

  @classmethod
  def InitMetaData(cls, payloads_dir, board, mounted=False):
    json_path = cls.GetJSONPath(payloads_dir, board)
    if mounted:
      SysUtils.WriteFileToMountedDir(
          payloads_dir, os.path.basename(json_path), '{}')
    else:
      with open(json_path, 'w', encoding='utf8') as f:
        f.write('{}')
    return json_path

  @classmethod
  def AddComponent(cls, json_path, component, resource, **kargs):
    if not os.path.exists(json_path):
      logging.warning('Cannot find %s', json_path)
      return
    Shell([cls.GetProgramPath(), 'add', json_path, component, resource],
          **kargs)

  @classmethod
  def InstallComponents(cls, json_path, dest, components, optional=False,
                        **kargs):
    if not os.path.exists(json_path):
      logging.warning('Cannot find %s', json_path)
      return
    if isinstance(components, str):
      components = [components]
    Sudo([cls.GetProgramPath(), 'install_optional' if optional else 'install',
          json_path, dest] + components,
         **kargs)

  @classmethod
  def GetToolkit(cls, json_path, toolkit_path):
    """Extract the toolkit in cros_payload and make it executable."""
    Shell(['touch', toolkit_path])
    cls.InstallComponents(
        json_path, toolkit_path, PAYLOAD_TYPE_TOOLKIT, silent=True)
    os.chmod(toolkit_path, 0o755)

  @classmethod
  def GetComponentVersions(cls, json_path):
    if not os.path.exists(json_path):
      logging.warning('Cannot find %s', json_path)
      return {}
    with open(json_path, encoding='utf8') as f:
      metadata = json.load(f)
      component_versions = {
          component: resource.get(PAYLOAD_SUBTYPE_VERSION, '<unknown>')
          for component, resource in metadata.items()}
      # Make sure that there are no unknown components
      for component in component_versions:
        assert component in PAYLOAD_COMPONENTS, (
            f'Unknown component "{component}"')
      return component_versions

  @classmethod
  def GetComponentFiles(cls, json_path, component):
    """Get a list of payload files for a component.

    If a board metadata JSON file is as follows:

    ```
    {
      "release_image": {
        "part1": "release_image.part1.gz",
        "part2": "release_image.part2.gz"
      }
    }
    ```

    GetComponentFiles(json_path, 'release_image') returns a list
    ['release_image.part1.gz', 'release_image.part2.gz']
    """
    if not os.path.exists(json_path):
      logging.warning('Cannot find %s', json_path)
      return []
    files = Shell([cls.GetProgramPath(), 'get_file', json_path, component],
                  output=True).strip().splitlines()
    return files

  @classmethod
  def GetAllComponentFiles(cls, json_path):
    """Get a list of payload files for all components.

    If a board metadata JSON file is as follows:

    ```
    {
      "release_image": {
        "part1": "release_image.part1.gz",
        "part2": "release_image.part2.gz"
      },
      "hwid": {
        "file": "hwid.gz"
      }
    }
    ```

    GetAllComponentFiles(json_path) returns a list
    ['release_image.part1.gz', 'release_image.part2.gz', 'hwid.gz']
    """
    if not os.path.exists(json_path):
      logging.warning('Cannot find %s', json_path)
      return []
    files = Shell([cls.GetProgramPath(), 'get_all_files', json_path],
                  output=True).strip().splitlines()
    return files

  @classmethod
  def ReplaceComponent(cls, json_path, component, resource):
    """Replace a component in a payload directory with a given file.

    Remove old payload files and add new files for a component. Doesn't check
    if the removed file is used by other boards. This function cannot directly
    replace payload components in a mounted image due to permission issues. To
    do so, we need to create a temporary directory, update the payloads in the
    directory, then use `ReplaceComponentsInImage()` function to replace the
    payload components in the image, e.g.

    ```
    with CrosPayloadUtils.TempPayloadsDir() as temp_dir:
      CrosPayloadUtils.CopyComponentsInImage(image, board, component, temp_dir)
      json_path = CrosPayloadUtils.GetJSONPath(temp_dir, board)
      CrosPayloadUtils.ReplaceComponent(json_path, component, resource)
      CrosPayloadUtils.ReplaceComponentsInImage(image, board, temp_dir)
    ```
    """
    payloads_dir = os.path.dirname(json_path)
    old_files = cls.GetComponentFiles(json_path, component)
    for f in old_files:
      old_file_path = os.path.join(payloads_dir, f)
      if os.path.exists(old_file_path):
        Sudo(['rm', '-f', old_file_path])
    cls.AddComponent(json_path, component, resource)

  @classmethod
  def CopyComponentsInImage(cls, image, board, components, dest_payloads_dir,
                            create_metadata=False):
    """Copy payload metadata json file and component files from an image..

    Args:
      image: path to RMA shim image.
      board: board name.
      components: a list of payload components to copy from the shim image.
      dest_payloads_dir: directory to copy to.
      create_metadata: True to create board metadata file if it doesn't exist
                       in shim image.
    """
    dest_json_path = cls.GetJSONPath(dest_payloads_dir, board)

    # Copy metadata and components to the temp directory.
    with Partition(image, PART_CROS_STATEFUL).Mount() as stateful:
      image_payloads_dir = os.path.join(stateful, cls.GetCrosPayloadsDir())
      image_json_path = cls.GetJSONPath(image_payloads_dir, board)

      if os.path.exists(image_json_path):
        Shell(['cp', '-pf', image_json_path, dest_json_path])
      elif create_metadata:
        cls.InitMetaData(dest_payloads_dir, board)
      else:
        raise RuntimeError(f'Cannot find {image_json_path}.')

      for component in components:
        files = cls.GetComponentFiles(image_json_path, component)
        for f in files:
          f_path = os.path.join(image_payloads_dir, f)
          Shell(['cp', '-pf', f_path, dest_payloads_dir])

  @classmethod
  def ReplaceComponentsInImage(cls, image, boards, new_payloads_dir):
    """Replace payload metada json file and component files in an image.

    Args:
      image: path to RMA shim image.
      boards: board name, or a list of board names.
      new_payloads_dir: directory containing the new payload files.
    """
    if isinstance(boards, str):
      boards = [boards]

    with Partition(image, PART_CROS_STATEFUL).Mount(rw=True) as stateful:
      old_payloads_dir = os.path.join(stateful, cls.GetCrosPayloadsDir())
      try:
        rma_metadata = _ReadRMAMetadata(stateful)
        old_boards = [info.board for info in rma_metadata]
      except Exception:
        # Reset shim doesn't have rma_metadata.json and any payloads.
        # By assigning `old_boards` same as `boards`, we can move everything
        # into the shim.
        old_boards = boards

      old_files = set()
      new_files = set()
      other_files = set()
      for board in old_boards:
        if board in boards:
          old_json_path = cls.GetJSONPath(old_payloads_dir, board)
          old_files.update(cls.GetAllComponentFiles(old_json_path))
          new_json_path = cls.GetJSONPath(new_payloads_dir, board)
          new_files.update(cls.GetAllComponentFiles(new_json_path))
        else:
          other_json_path = cls.GetJSONPath(old_payloads_dir, board)
          other_files.update(cls.GetAllComponentFiles(other_json_path))

      # Remove old files that are not used by any boards.
      for f in old_files - new_files - other_files:
        file_path = os.path.join(old_payloads_dir, f)
        print(f'Remove old payload file {os.path.basename(f)}.')
        Sudo(['rm', '-f', file_path])
      # Don't copy files that already exists.
      for f in new_files & (old_files | other_files):
        file_path = os.path.join(new_payloads_dir, f)
        if os.path.exists(file_path):
          Sudo(['rm', '-f', file_path])

      remain_size = SysUtils.GetRemainingSize(stateful)
      new_payloads_size = SysUtils.GetDiskUsage(new_payloads_dir)

    # When expanding or shrinking a partition, leave an extra 10M margin. 10M
    # is just a size larger than most small payloads, so that we don't need to
    # change the partition size when updating the small payloads.
    margin = 10 * MEGABYTE

    # Expand stateful partition if needed.
    if remain_size < new_payloads_size:
      ExpandPartition(
          image, PART_CROS_STATEFUL, new_payloads_size - remain_size + margin)

    # Move the added payloads to stateful partition.
    print(f'Moving payloads ({int(new_payloads_size // MEGABYTE)}M)...')
    with Partition(image, PART_CROS_STATEFUL).Mount(rw=True) as stateful:
      dest = os.path.join(stateful, cls.GetCrosPayloadsDir())
      dest_dir = os.path.dirname(dest)
      Sudo(['chown', '-R', 'root:root', new_payloads_dir])
      Sudo(['mkdir', '-p', dest_dir, '-m', f'{MODE_NEW_DIR:o}'])
      Sudo(['rsync', '-a', new_payloads_dir, dest_dir])

    # Shrink stateful partition.
    if remain_size > new_payloads_size + 2 * margin:
      ShrinkPartition(
          image, PART_CROS_STATEFUL, remain_size - new_payloads_size - margin)

  @classmethod
  @contextlib.contextmanager
  def TempPayloadsDir(cls):
    with SysUtils.TempDirectory() as temp_dir:
      temp_payloads_dir = os.path.join(temp_dir, cls.GetCrosPayloadsDir())
      SysUtils.CreateDirectories(temp_payloads_dir)
      yield temp_payloads_dir


def Aligned(value, alignment):
  """Helper utility to calculate aligned numbers.

  Args:
    value: an integer as original value.
    alignment: an integer for alignment.
  """
  remains = value % alignment
  return value - remains + (alignment if remains else 0)


class GPT(pygpt.GPT):
  """A special version GPT object with more helper utilities."""

  class CopyablePartitionMixin:
    """A mixin class that supports copying partitions.

    The child class should override `OpenAsStream()` function to return a
    stream-like object that supports `read()` operation.
    """

    @contextlib.contextmanager
    def OpenAsStream(self):

      class Reader:
        """A reader class that supports `read()` operation."""

        @classmethod
        def read(cls, num):
          raise NotImplementedError

      yield Reader()

    def Copy(self, dest, check_equal=True, sync=False, verbose=False):
      """Copies this partition to another partition.

      Args:
        dest: a Partition object as the destination.
        check_equal: True to raise exception if the sizes of partitions are
                     different.
      """
      if self.size != dest.size:
        if check_equal:
          raise RuntimeError(
              f'Partition size is different ({int(self.size)}, {int(dest.size)}'
              ').')
        if self.size > dest.size:
          raise RuntimeError(
              f'Source partition ({self.size}) is larger than destination ('
              f'{dest.size}).')
      if verbose:
        logging.info('Copying partition %s => %s...', self, dest)

      with self.OpenAsStream() as src_stream:
        SysUtils.PartialCopyFromStream(src_stream, self.size, dest.image,
                                       dest.offset, sync=sync)

  class ZeroedPartition(pygpt.GPT.PartitionBase, CopyablePartitionMixin):
    """A partition with a fixed size of zeros."""

    def __str__(self):
      return 'ZeroedPartition'

    @contextlib.contextmanager
    def OpenAsStream(self):
      """CopyablePartitionMixin override."""

      class ZeroReader:
        """A /dev/zero like stream."""

        @classmethod
        def read(cls, num):
          return b'\x00' * num

      yield ZeroReader()

  class Partition(pygpt.GPT.Partition, CopyablePartitionMixin):
    """A special GPT Partition object with mount and copy ability."""

    @classmethod
    @contextlib.contextmanager
    def _Map(cls, image, offset, size, partscan=False, block_size=None):
      """Context manager to map (using losetup) partition(s) from disk image.

      Args:
        image: a path to disk image to map.
        offset: an integer as offset to partition, or None to map whole disk.
        size: an integer as partition size, or None for whole disk.
        partscan: True to scan partition table and create sub device files.
        block_size: specify the size of each logical block.
      """
      loop_dev = None
      args = ['losetup', '--show', '--find']
      if offset is None:
        # Note "losetup -P" needs Ubuntu 15+.
        # TODO(hungte) Use partx if -P is not supported (partx -d then -a).
        if partscan:
          args += ['-P']
      else:
        args += ['-o', str(offset), '--sizelimit', str(size)]
      if block_size is not None and block_size != pygpt.GPT.DEFAULT_BLOCK_SIZE:
        # For Linux kernel without commit "loop: add ioctl for changing logical
        # block size", calling "-b 512" will fail, so we should only add "-b"
        # when needed, so people with standard block size can work happily
        # without upgrading their host kernel.
        args += ['-b', str(block_size)]
      args += [image]

      try:
        loop_dev = SudoOutput(args).strip()
        yield loop_dev
      finally:
        if loop_dev:
          Sudo(['umount', '-R', loop_dev], check=False, silent=True)
          Sudo(['losetup', '-d', loop_dev], check=False, silent=True)
          # `losetup -d` doesn't detach the loop device immediately, which might
          # cause future mount failures. Make sure that the loop device is
          # detached before returning.
          while True:
            output = SudoOutput(['losetup', '-j', image]).strip()
            regex = r'^' + re.escape(loop_dev)
            if not re.search(regex, output, re.MULTILINE):
              break
            time.sleep(0.1)

    def Map(self):
      """Maps given partition to loop block device."""
      logging.debug('Map %s: %s(+%s)', self, self.offset, self.size)
      return self._Map(self.image, self.offset, self.size)

    @classmethod
    def MapAll(cls, image, partscan=True, block_size=None):
      """Maps an image with all partitions to loop block devices.

      Map the image to /dev/loopN, and all partitions will be created as
      /dev/loopNpM, where M stands for partition number.
      This is not supported by older systems.

      Args:
        image: a path to disk image to map.
        partscan: True to scan partition table and create sub device files.
        block_size: specify the size of each logical block.

      Returns:
        The mapped major loop device (/dev/loopN).
      """
      return cls._Map(image, None, None, partscan, block_size)

    @contextlib.contextmanager
    def Mount(self, mount_point=None, rw=False, fs_type=None, options=None,
              auto_umount=True, silent=False):
      """Context manager to mount partition from given disk image.

      Args:
        mount_point: directory to mount, or None to use temporary directory.
        rw: True to mount as read-write, otherwise read-only (-o ro).
        fs_type: string as file system type (-t).
        options: string as extra mount options (-o).
        auto_umount: True to un-mount when leaving context.
        silent: True to hide all warning and error messages.
      """
      if GPT.IsBlockDevice(self.image):
        try:
          mount_dev = MakePartition(self.image, self.number)
          mounted_dir = Shell(['lsblk', '-n', '-o', 'MOUNTPOINT', mount_dev],
                              output=True).strip()
          if mounted_dir:
            logging.debug('Already mounted: %s', self)
            yield mounted_dir
            return
        except Exception:
          pass

      options = options or []
      if isinstance(options, str):
        options = [options]
      options = ['rw' if rw else 'ro'] + options

      options += ['loop', f'offset={self.offset}', f'sizelimit={self.size}']
      args = ['mount', '-o', ','.join(options)]
      if fs_type:
        args += ['-t', fs_type]

      temp_dir = None
      try:
        if not mount_point:
          temp_dir = tempfile.mkdtemp(prefix='imgtool_')
          mount_point = temp_dir

        args += [self.image, mount_point]

        logging.debug('Partition.Mount: %s', ' '.join(args))
        Sudo(args, silent=silent)
        yield mount_point

      finally:
        if auto_umount:
          if mount_point:
            Sudo(['umount', '-R', mount_point], check=False)
          if temp_dir:
            os.rmdir(temp_dir)

    def MountAsCrOSRootfs(self, *args, **kargs):
      """Mounts as Chrome OS root file system with rootfs verification enabled.

      The Chrome OS disk image with rootfs verification turned on will enable
      the RO bit in ext2 attributes and can't be mounted without specifying
      mount arguments "-t ext2 -o ro".
      """
      assert kargs.get(
          'rw', False) is False, (f'Cannot change Chrome OS rootfs {self}.')
      assert kargs.get('fs_type', FS_TYPE_CROS_ROOTFS) == FS_TYPE_CROS_ROOTFS, (
          f'Chrome OS rootfs {self} must be mounted as {FS_TYPE_CROS_ROOTFS}.')
      kargs['rw'] = False
      kargs['fs_type'] = FS_TYPE_CROS_ROOTFS
      return self.Mount(*args, **kargs)

    def CopyFile(self, rel_path, dest, **mount_options):
      """Copies a file inside partition to given destination.

      Args:
        rel_path: relative path to source on disk partition.
        dest: path of destination (file or directory).
        mount_options: anything that must be passed to Partition.Mount.
      """
      with self.Mount(**mount_options) as rootfs:
        # If rel_path is absolute then os.join will discard rootfs.
        if os.path.isabs(rel_path):
          rel_path = '.' + rel_path
        src_path = os.path.join(rootfs, rel_path)
        dest_path = (os.path.join(dest, os.path.basename(rel_path)) if
                     os.path.isdir(dest) else dest)
        logging.debug('Copying %s => %s ...', src_path, dest_path)
        shutil.copy(src_path, dest_path)
        return dest_path

    @classmethod
    def _ParseExtFileSystemSize(cls, block_dev):
      """Helper to parse ext* file system size using dumpe2fs.

      Args:
        raw_part: a path to block device.
      """
      raw_info = SudoOutput(['dumpe2fs', '-h', block_dev])
      # The 'block' in file system may be different from disk/partition logical
      # block size (LBA).
      fs_block_count = int(RE_BLOCK_COUNT.findall(raw_info)[0])
      fs_block_size = int(RE_BLOCK_SIZE.findall(raw_info)[0])
      return fs_block_count * fs_block_size

    def GetFileSystemSize(self):
      """Returns the (ext*) file system size.

      It is possible the real space occupied by file system is smaller than
      partition size, especially in Chrome OS, the extra space is reserved for
      verity data (rootfs verification) or to help quick wiping in factory
      process.
      """
      with self.Map() as raw_part:
        return self._ParseExtFileSystemSize(raw_part)

    def ResizeFileSystem(self, new_size=None):
      """Resizes the file system in given partition.

      resize2fs may not accept size in number > INT32, so we have to specify the
      size in larger units, for example MB; and that implies the result may be
      different from new_size.

      Args:
        new_size: The expected new size. None to use whole partition.

      Returns:
        New size in bytes.
      """
      with self.Map() as raw_part:
        # File system must be clean before we can perform resize2fs.
        # e2fsck may return 1 "errors corrected" or 2 "corrected and need
        # reboot".
        old_size = self._ParseExtFileSystemSize(raw_part)
        result = Sudo(['e2fsck', '-y', '-f', raw_part], check=False)
        if result > 2:
          raise RuntimeError('Failed ensuring file system integrity (e2fsck).')
        args = ['resize2fs', '-f', raw_part]
        if new_size:
          args.append(f'{new_size // MEGABYTE}M')
        Sudo(args)
        real_size = self._ParseExtFileSystemSize(raw_part)
        logging.debug(
            '%s (%s) file system resized from %s (%sM) to %s (%sM), req = %s M',
            self, self.size, old_size, old_size // MEGABYTE,
            real_size, real_size // MEGABYTE,
            new_size // MEGABYTE if new_size else '(ALL)')
      return real_size

    def CloneAsZeroedPartition(self):
      """Clones as a zeroed partition.

      Preserves partition fields and some metadata, but erases the content to
      1 block of zeros.

      Returns:
        A ZeroedPartition object with 1 block.
      """
      p = GPT.ZeroedPartition(*self, block_size=self.block_size)
      p.Update(FirstLBA=0, LastLBA=0)
      return p

    @contextlib.contextmanager
    def OpenAsStream(self):
      """CopyablePartitionMixin override."""
      with open(self.image, 'rb') as src:
        src.seek(self.offset)
        yield src


def Partition(image, number):
  """Returns a GPT object by given parameters."""
  part = GPT.LoadFromFile(image).GetPartition(number)
  if part.IsUnused():
    raise RuntimeError(f'Partition {part} is unused.')
  return part

def ExpandPartition(image, number, size):
  """Expands an image partition for at least `size` bytes.

  By default, ext2/3/4 file system reserves 5% space for root, so we round
  (`size` * 1.05) up to a multiple of block size, and expand that amount
  of space. The partition should be the last partition of the image.

  Args:
    image: a path to an image file.
    number: 1-based partition number.
    size: Amount of space in bytes to expand.
  """
  # For disk_layout_v3, the last partition is MiniOS-B instead of stateful
  # partition. This prevent us from increasing/decreasing the size of the
  # stateful partition. To solve this, we delete `PART_CROS_MINIOS_B` from the
  # partition table.
  gpt = GPT.LoadFromFile(image)
  if gpt.IsLastPartition(PART_CROS_MINIOS_B):
    pygpt.RemovePartition(image, PART_CROS_MINIOS_B)
    # Reload gpt since we've removed the last partition
    gpt = GPT.LoadFromFile(image)
  part = gpt.GetPartition(number)
  # Check that the partition is the last partition.
  if not gpt.IsLastPartition(number):
    raise RuntimeError(
        f'Cannot expand partition {int(number)}; must be the last one in LBA '
        'layout.')

  old_size = gpt.GetSize()
  new_size = Aligned(int((old_size + size) * 1.15), part.block_size)
  print(f'Changing size: {int(old_size // MEGABYTE)} M => '
        f'{int(new_size // MEGABYTE)} M')

  Shell(['truncate', '-s', str(new_size), image])
  gpt.Resize(new_size)
  gpt.ExpandPartition(number)
  gpt.WriteToFile(image)
  gpt.WriteProtectiveMBR(image, create=True)
  part.ResizeFileSystem()

def ShrinkPartition(image, number, size):
  """Shrinks an image partition for at most `size` bytes.

  Round `size` down to a multiple of block size, and reduce that amount of
  space for a partition. The partition should be the last partition of the
  image.

  Args:
    image: a path to an image file.
    number: 1-based partition number.
    size: Amount of space in bytes to reduce.
  """
  gpt = GPT.LoadFromFile(image)
  if gpt.IsLastPartition(PART_CROS_MINIOS_B):
    pygpt.RemovePartition(image, PART_CROS_MINIOS_B)
    gpt = GPT.LoadFromFile(image)
  part = gpt.GetPartition(number)
  reduced_size = (size // part.block_size) * part.block_size
  # Check that the partition is the last partition.
  if not gpt.IsLastPartition(number):
    raise RuntimeError(
        f'Cannot expand partition {int(number)}; must be the last one in LBA '
        'layout.')
  # Check that the partition size is greater than shrink size.
  if part.size <= reduced_size:
    raise RuntimeError(
        f'Cannot shrink partition {int(number)}. Size too small.')

  old_size = gpt.GetSize()
  new_size = old_size - reduced_size
  print(f'Changing size: {int(old_size // MEGABYTE)} M => '
        f'{int(new_size // MEGABYTE)} M')

  part.ResizeFileSystem(part.size - reduced_size)
  Shell(['truncate', '-s', str(new_size), image])
  gpt.Resize(new_size, check_overlap=False)
  gpt.ExpandPartition(number)
  gpt.WriteToFile(image)
  gpt.WriteProtectiveMBR(image, create=True)

class LSBFile:
  """Access /etc/lsb-release file (or files in same format).

  The /etc/lsb-release can be loaded directly by shell ( . /etc/lsb-release ).
  There is no really good and easy way to parse that without sh, but fortunately
  for the fields we care, it's usually A=B or A="B C".

  Also, in Chrome OS, the /etc/lsb-release was implemented without using quotes
  (i,e., A=B C, no matter if the value contains space or not).
  """
  def __init__(self, path=None, is_cros=True):
    self._path = path
    self._raw_data = ''
    self._dict = {}
    self._is_cros = is_cros
    if not path:
      return

    with open(path, encoding='utf8') as f:
      self._raw_data = f.read().strip()  # Remove trailing \n or \r
      self._dict = dict(RE_LSB.findall(self._raw_data))

  def AsRawData(self):
    return self._raw_data

  def AsDict(self):
    return self._dict

  def GetPath(self):
    return self._path

  def FormatKeyValue(self, key, value):
    return ('%s=%s' if self._is_cros or ' ' not in value else '%s="%s"') % (
        key, value)

  def GetValue(self, key, default=None):
    return self._dict.get(key, default)

  def AppendValue(self, key, value):
    self._dict[key] = value
    self._raw_data += '\n' + self.FormatKeyValue(key, value)

  def SetValue(self, key, value):
    if key in self._dict:
      self._dict[key] = value
      self._raw_data = re.sub(
          r'^' + re.escape(key) + r'=.*', self.FormatKeyValue(key, value),
          self._raw_data, flags=re.MULTILINE)
    else:
      self.AppendValue(key, value)

  def DeleteValue(self, key):
    if key not in self._dict:
      return
    self._dict.pop(key)
    self._raw_data = re.sub(r'^' + re.escape(key) + r'=.*\n*', '',
                            self._raw_data, flags=re.MULTILINE)

  def Install(self, destination, backup=False):
    """Installs the contents to the given location as lsb-release style file.

    The file will be owned by root:root, with file mode 0644.
    """
    with tempfile.NamedTemporaryFile('w', prefix='lsb_') as f:
      f.write(self._raw_data + '\n')
      f.flush()
      os.chmod(f.name, 0o644)
      if backup and os.path.exists(destination):
        bak_file = f"{destination}.bak.{time.strftime('%Y%m%d%H%M%S')}"
        Sudo(['cp', '-pf', destination, bak_file])
      Sudo(['cp', '-pf', f.name, destination])
      Sudo(['chown', 'root:root', destination])

  def GetChromeOSBoard(self, remove_signer=True):
    """Returns the Chrome OS board name.

    Gets the value using KEY_LSB_CROS_BOARD. For test or DEV signed images, this
    is exactly the board name we passed to build commands. For PreMP/MP signed
    images, this may have suffix '-signed-KEY', where KEY is the key name like
    'mpv2'.

    Args:
      remove_signer: True to remove '-signed-XX' information.
    """
    board = self.GetValue(KEY_LSB_CROS_BOARD, '')
    if remove_signer:
      # For signed images, the board may come in $BOARD-signed-$KEY.
      signed_index = board.find('-signed-')
      if signed_index > -1:
        board = board[:signed_index]
    return board

  def GetChromeOSVersion(self, remove_timestamp=True, remove_milestone=False):
    """Returns the Chrome OS build version.

    Gets the value using KEY_LSB_CROS_VERSION. For self-built images, this may
    include a time stamp.

    Args:
      remove_timestamp: Remove the timestamp like version info if available.
      remove_milestone: Remove the milestone if available.
    """
    version = self.GetValue('CHROMEOS_RELEASE_VERSION', '')
    if remove_timestamp:
      version = version.split()[0]
    if remove_milestone:
      re_branched_image_version = re.compile(r'R\d+-(\d+\.\d+\.\d+)')
      ver_match = re_branched_image_version.fullmatch(version)
      if ver_match:
        version = ver_match.group(1)
    return version


class RMAImageBoardInfo:
  """Store the RMA image information related to one board."""

  __slots__ = ['board', 'kernel_a', 'rootfs_a', 'kernel_b', 'rootfs_b']
  __legacy_slots__ = ['board', 'kernel', 'rootfs']

  def __init__(self, board, kernel_a=PART_CROS_KERNEL_A,
               rootfs_a=PART_CROS_ROOTFS_A, kernel_b=PART_CROS_KERNEL_B,
               rootfs_b=PART_CROS_ROOTFS_B):
    self.board = board
    self.kernel_a = kernel_a
    self.rootfs_a = rootfs_a
    self.kernel_b = kernel_b
    self.rootfs_b = rootfs_b

  def ToDict(self):
    return {k: getattr(self, k) for k in self.__slots__}

  @classmethod
  def CreateFromDict(cls, d):
    """Creates an RMAImageBoardInfo instance from a dictionary.

    Args:
      d: a dictionary containing keys in cls.__slots__.

    Returns:
      An RMAImageBoardInfo instance.

    Raises:
      RuntimeError if the dictionary doesn't contain the exact same set of keys
      as self.__slots__.
    """
    keys = d.keys()
    if set(keys) == set(cls.__slots__):
      return RMAImageBoardInfo(**d)
    if set(keys) == set(cls.__legacy_slots__):
      # Support backward compatibility.
      logging.warning('Found legacy RMA metadata. Converting to new format.')
      logging.warning('Duplicated UniqueGUID warnings are expected.')
      return RMAImageBoardInfo(board=d["board"], kernel_a=d["kernel"],
                               rootfs_a=d["rootfs"], kernel_b=d["kernel"],
                               rootfs_b=d["rootfs"])
    raise RuntimeError(f'Invalid RMAImageMetadata keys: {keys}')


def _WriteRMAMetadata(stateful, board_list):
  """Write RMA metadata to mounted stateful parititon.

  Args:
    stateful: path of stateful partition mount point.
    board_list: a list of RMAImageBoardInfo object.
  """
  payloads_dir = os.path.join(stateful, CrosPayloadUtils.GetCrosPayloadsDir())
  content = json.dumps([b.ToDict() for b in board_list])
  SysUtils.WriteFileToMountedDir(payloads_dir, CROS_RMA_METADATA, content)


def _ReadRMAMetadata(stateful):
  """Read RMA metadata from mounted stateful partition.

  Args:
    stateful: path of stateful partition mount point.

  Returns:
    RMA metadata, which is a list of RMAImageBoardInfo.

  Raises:
    RuntimeError if the file doesn't exist and cannot auto-generate either.
  """
  DIR_CROS_PAYLOADS = CrosPayloadUtils.GetCrosPayloadsDir()
  PATH_CROS_RMA_METADATA = os.path.join(
      stateful, CrosPayloadUtils.GetCrosRMAMetadata())
  if os.path.exists(PATH_CROS_RMA_METADATA):
    with open(PATH_CROS_RMA_METADATA, encoding='utf8') as f:
      metadata = [RMAImageBoardInfo.CreateFromDict(e) for e in json.load(f)]
      return metadata
  else:
    logging.warning('Cannot find %s.', PATH_CROS_RMA_METADATA)
    # Check if it is a legacy single-board RMA shim.
    found = glob.glob(os.path.join(stateful, DIR_CROS_PAYLOADS, '*.json'))
    if len(found) == 1:
      logging.warning('Found legacy RMA shim. Auto-generating metadata.')
      board = os.path.basename(found[0]).split('.')[0]
      metadata = [
          RMAImageBoardInfo.CreateFromDict({
              'board': board,
              'kernel': PART_CROS_KERNEL_A,
              'rootfs': PART_CROS_ROOTFS_A
          })
      ]
      return metadata
    raise RuntimeError('Cannot get metadata, is this a RMA shim?')


def _GetBoardName(image):
  """Try to Find the board name from a single-board shim image.

  Args:
    image: factory shim image.

  Returns:
    Board name of the shim image.

  Raises:
    RuntimeError if the shim is a multi-board shim.
  """
  try:
    with Partition(image, PART_CROS_STATEFUL).Mount() as stateful:
      metadata = _ReadRMAMetadata(stateful)
  except Exception:
    # Just a reset shim. Read board name from lsb-release.
    with Partition(image, PART_CROS_ROOTFS_A).Mount() as rootfs:
      lsb_path = os.path.join(rootfs, 'etc', 'lsb-release')
      return LSBFile(lsb_path).GetChromeOSBoard()

  # Single-board RMA shim.
  if len(metadata) == 1:
    return metadata[0].board
  # Multi-board shim.
  raise RuntimeError('Cannot get board name in a multi-board shim.')


class RMABoardResourceVersions:
  """Store the RMA resource versions related to one board."""

  __slots__ = ['board', 'install_shim'] + PAYLOAD_COMPONENTS

  def __init__(self, **kargs):
    for component, version in kargs.items():
      assert component in self.__slots__, f'Unknown component "{component}"'
      setattr(self, component, version)

  def __str__(self):
    max_len = max([len(s) for s in self.__slots__])
    return '\n'.join(
        [f'{k:<{max_len}}: {getattr(self, k, "None")}' for k in self.__slots__])


def _ReadBoardResourceVersions(rootfs, stateful, board_info):
  """Read board resource versions from mounted stateful partition.

  Get board resource versions from <board>.json and install shim version.

  Args:
    stateful: path of stateful partition mount point.
    rootfs: path of rootfs mount point.
    board_info: a RMAImageBoardInfo instance.

  Returns:
    A RMABoardResourceVersions instance containing resource versions.
  """

  def _GetInstallShimVersion(rootfs):
    # Version of install shim rootfs.
    lsb_path = os.path.join(rootfs, 'etc', 'lsb-release')
    shim_version = LSBFile(lsb_path).GetChromeOSVersion(remove_timestamp=False)
    return shim_version

  versions = {
      'board': board_info.board,
      'install_shim': _GetInstallShimVersion(rootfs)}
  DIR_CROS_PAYLOADS = CrosPayloadUtils.GetCrosPayloadsDir()
  json_path = CrosPayloadUtils.GetJSONPath(
      os.path.join(stateful, DIR_CROS_PAYLOADS), board_info.board)
  payload_versions = CrosPayloadUtils.GetComponentVersions(json_path)
  versions.update(payload_versions)
  return RMABoardResourceVersions(**versions)


class UserInput:
  """A helper class to manage user inputs."""

  @classmethod
  def Select(cls, title, options_list=None, options_dict=None,
             single_line_option=True, split_line=False, optional=False):
    """Ask user to select an option from the given options.

    Prints the options in `options_list` with their corresponding 1-based index,
    and key-value pairs in `options_dict`. Let the user enter a number or string
    to select an option.

    Args:
      title: question description.
      options_list: list of strings, each representing an option.
      options_dict: dict of (key, option), each representing an option.
      single_line_option: True to print the index and option in the same line.
      split_line: split line between options.
      optional: True to allow the user to input empty string.

    Returns:
      A user selected number in 0-based index, between 0 and
      len(options_list) - 1, or a string that is a key of `options_dict`,
      or None if the user inputs an empty string and `optional` set to True.
    """

    def print_with_split_line(s):
      print(s)
      if split_line:
        print(SPLIT_LINE)

    options_list = options_list or []
    options_dict = options_dict or {}
    list_n = len(options_list)
    dict_n = len(options_dict)
    if list_n + dict_n == 0:
      return None
    print_with_split_line('\n' + title)
    for i, option in enumerate(options_list, 1):
      print_with_split_line(
          '(%d)%s%s' % (i, ' ' if single_line_option else '\n', option))
    for key, option in options_dict.items():
      print_with_split_line(
          '(%s)%s%s' % (key, ' ' if single_line_option else '\n', option))

    while True:
      keys = [] if list_n == 0 else ['1'
                                    ] if list_n == 1 else [f'1-{int(list_n)}']
      keys += list(options_dict)
      prompt = (f"Please select an option [{', '.join(keys)}]"
                f"{' or empty to skip' if optional else ''}: ")
      answer = input(prompt).strip()
      if optional and not answer:
        return None
      try:
        selected = int(answer)
        if not 0 < selected <= list_n:
          print(f'Out of range: {int(selected)}')
          continue
        # Convert to 0-based
        selected -= 1
      except ValueError:
        if answer not in options_dict:
          print(f'Invalid option: {answer}')
          continue
        selected = answer
      break
    return selected

  @classmethod
  def YesNo(cls, title):
    """Ask user to input "y" or "n" for a question.

    Args:
      title: question description.

    Returns:
      True if the user inputs 'y', or False if the user inputs 'n'.
    """
    print('\n' + title)
    while True:
      prompt = 'Please input "y" or "n": '
      answer = input(prompt).strip().lower()
      if answer == 'y':
        return True
      if answer == 'n':
        return False

  @classmethod
  def GetNumber(cls, title, min_value=None, max_value=None, optional=False):
    """Ask user to input a number in the given range.

    Args:
      title: question description.
      min_value: lower bound of the input number.
      max_value: upper bound of the input number.
      optional: True to allow the user to input empty string.

    Returns:
      The user input number, or None if the user inputs an empty string.
    """
    if min_value is not None and max_value is not None:
      assert min_value <= max_value, (
          f'min_value {int(min_value)} is greater than max_value '
          f'{int(max_value)}')

    print('\n' + title)
    while True:
      prompt = ('Enter a number in ['
                f"{str(min_value) if min_value is not None else '-INF'}, "
                f"{str(max_value) if max_value is not None else 'INF'}]"
                f"{' or empty to skip' if optional else ''}: ")
      answer = input(prompt).strip()
      if optional and not answer:
        return None
      try:
        value = int(answer)
        if min_value is not None and value < min_value:
          raise ValueError('out of range')
        if max_value is not None and value > max_value:
          raise ValueError('out of range')
      except ValueError:
        print(f'Invalid option: {answer}')
        continue
      break
    return value

  @classmethod
  def GetString(cls, title, max_length=None, optional=False):
    """Ask user to input a string.

    Args:
      title: question description.
      max_length: Maximum string length allowed.
      optional: True to allow the user to input empty string.

    Returns:
      The user input string, or None if the user inputs an empty string.
    """
    assert max_length is None or max_length > 0, (
        'max_length should be greater than 0')
    print('\n' + title)
    while True:
      prompt = f"Enter a string{' or empty to skip' if optional else ''}: "
      answer = input(prompt).strip()
      if answer:
        if max_length is None or len(answer) <= max_length:
          break
        print(f'Input string too long, max length is {int(max_length)}')
      elif optional:
        return None
      else:
        print('Input string cannot be empty')

    return answer


class ChromeOSFactoryBundle:
  """Utilities to work with factory bundle."""

  # Types of build targets (for DefineBundleArguments to use).
  PREFLASH = 1
  RMA = 2
  BUNDLE = 3
  REPLACEABLE = 4

  def __init__(self, temp_dir, board, release_image, test_image, toolkit,
               factory_shim=None, enable_firmware=True, firmware=None,
               hwid=None, complete=None, netboot=None, toolkit_config=None,
               description=None, project_config=None, setup_dir=None,
               server_url=None, project=None, designs=None):
    self._temp_dir = temp_dir
    # Member data will be looked up by getattr so we don't prefix with '_'.
    self._board = board
    self.project = project
    self.designs = designs
    self.release_image = release_image
    self.test_image = test_image
    self.toolkit = toolkit
    self.factory_shim = factory_shim
    self.enable_firmware = enable_firmware
    self._firmware = firmware
    self.hwid = hwid
    self.complete = complete
    self.netboot = netboot
    self.toolkit_config = toolkit_config
    # Always get lsb_factory from factory shim.
    self._lsb_factory = None
    self.description = description
    self.project_config = project_config
    self.setup_dir = setup_dir
    self.server_url = server_url

  @classmethod
  def DefineBundleArguments(cls, parser, build_type):
    """Define common argparse arguments to work with factory bundle.

    Args:
      parser: An argparse subparser to add argument definitions.
      build_type: Build type to control arguments added to the parser.
    """

    class ParserArgumentWrapper:
      """Helper class for flexible parser arguments."""
      def __init__(self, parser, build_type, remove_default):
        self.parser = parser
        self.build_type = build_type
        self.remove_default = remove_default

      def AddArgument(self, build_types, *args, **kargs):
        if self.build_type in build_types:
          if self.remove_default:
            kargs.pop('default', None)
          self.parser.add_argument(*args, **kargs)

    # Add parser arguments.
    parser = ParserArgumentWrapper(
        parser, build_type, remove_default=(build_type == cls.REPLACEABLE))
    parser.AddArgument(
        (cls.PREFLASH, cls.RMA, cls.BUNDLE, cls.REPLACEABLE),
        '--release_image',
        default='release_image/*.bin',
        type=ArgTypes.GlobPath,
        help=('path to a Chromium OS (release or recovery) image. '
              'default: %(default)s'))
    parser.AddArgument(
        (cls.PREFLASH, cls.RMA, cls.BUNDLE, cls.REPLACEABLE),
        '--test_image',
        default='test_image/*.bin',
        type=ArgTypes.GlobPath,
        help='path to a Chromium OS test image. default: %(default)s')
    # Toolkit is optional in preflash image.
    parser.AddArgument(
        (cls.PREFLASH, ),
        '--toolkit',
        default='-toolkit/*.run',
        type=ArgTypes.GlobPath,
        help='path to a Chromium OS factory toolkit. default: %(default)s')
    # Otherwise, toolkit is required.
    parser.AddArgument(
        (cls.RMA, cls.BUNDLE, cls.REPLACEABLE),
        '--toolkit',
        default='toolkit/*.run',
        type=ArgTypes.GlobPath,
        help='path to a Chromium OS factory toolkit. default: %(default)s')
    parser.AddArgument(
        (cls.PREFLASH, cls.RMA, cls.BUNDLE, cls.REPLACEABLE),
        '--hwid',
        default='-hwid/*.sh',
        type=ArgTypes.GlobPath,
        help='path to a HWID bundle if available. default: %(default)s')
    parser.AddArgument(
        (cls.PREFLASH, cls.RMA, cls.BUNDLE, cls.REPLACEABLE),
        '--project_config',
        default='-project_config/*.tar.gz',
        type=ArgTypes.GlobPath,
        help=('path to a project_config bundle if available. '
              'default: %(default)s'))
    parser.AddArgument(
        (cls.RMA, cls.BUNDLE, cls.REPLACEABLE),
        '--factory_shim',
        default='factory_shim/*.bin',
        type=ArgTypes.GlobPath,
        help=('path to a factory shim (build_image factory_install), '
              'default: %(default)s'))
    parser.AddArgument(
        (cls.RMA, cls.BUNDLE, cls.REPLACEABLE),
        '--board',
        help='board name for dynamic installation')
    parser.AddArgument((
        cls.PREFLASH,
        cls.RMA,
        cls.BUNDLE,
    ), '--project', help='The project used in the bundle.')
    parser.AddArgument((
        cls.PREFLASH,
        cls.RMA,
        cls.BUNDLE,
    ), '--designs', nargs='+', help='The designs used in the bundle.')
    parser.AddArgument((
        cls.PREFLASH,
        cls.RMA,
        cls.BUNDLE,
    ), '--no_verify_cros_config', dest='verify_cros_config',
                       action='store_false', help='Do not verify cros config.')
    parser.AddArgument(
        (cls.RMA, cls.BUNDLE, cls.REPLACEABLE),
        '--firmware',
        default='-firmware/*update*',
        type=ArgTypes.GlobPath,
        help=('optional path to a firmware updater '
              '(chromeos-firmwareupdate); if not specified, extract '
              'firmware from --release_image unless --no-firmware is '
              'specified'))
    parser.AddArgument(
        (cls.RMA, cls.BUNDLE, cls.REPLACEABLE),
        '--complete',
        dest='complete',
        default='-complete/*.sh',
        type=ArgTypes.GlobPath,
        help='path to a script for last-step execution of factory install')
    parser.AddArgument(
        (cls.RMA, cls.BUNDLE, cls.REPLACEABLE),
        '--toolkit_config',
        dest='toolkit_config',
        default='-toolkit/*.json',
        type=ArgTypes.GlobPath,
        help='path to a config file to override test list constants')
    parser.AddArgument(
        (cls.RMA, cls.BUNDLE, cls.REPLACEABLE),
        '--description', dest='description',
        default='-description/*.txt', type=ArgTypes.GlobPath,
        help='path to a plain text description file')
    parser.AddArgument(
        (cls.RMA, cls.BUNDLE),
        '--no-firmware',
        dest='enable_firmware',
        action='store_false',
        default=True,
        help='skip running firmware updater')
    parser.AddArgument(
        (cls.BUNDLE,),
        '--setup_dir',
        default='-setup',
        type=ArgTypes.GlobPath,
        help='path to scripts for setup and deployment from factory zip')
    parser.AddArgument(
        (cls.BUNDLE,),
        '--netboot',
        default='-netboot|factory_shim/netboot',
        type=ArgTypes.GlobPath,
        help=('path to netboot firmware (image.net.bin) and kernel '
              '(vmlinuz)'))
    # TODO(hungte) Support more flexible names like 'evt2'.
    parser.AddArgument(
        (cls.BUNDLE,),
        '-p', '--phase',
        choices=['proto', 'evt', 'dvt', 'pvt', 'mp'],
        default='proto',
        help='build phase (evt, dvt, pvt or mp).')
    parser.AddArgument(
        (cls.BUNDLE,),
        '-s', '--server_url',
        help='URL to factory server. The host part may be used for TFTP.')

  @property
  def board(self):
    """Determines the right 'board' configuration."""
    if self._board:
      return self._board

    part = Partition(self.release_image, PART_CROS_ROOTFS_A)
    with part.MountAsCrOSRootfs() as rootfs:
      self._board = LSBFile(
          os.path.join(rootfs, 'etc', 'lsb-release')).GetChromeOSBoard()
    logging.info('Detected board as %s from %s.', self._board, part)
    return self._board

  @property
  def firmware(self):
    if not self.enable_firmware:
      return None
    if self._firmware is not None:
      return self._firmware

    part = Partition(self.release_image, PART_CROS_ROOTFS_A)
    logging.info('Loaded %s from %s.', PATH_CROS_FIRMWARE_UPDATER, part)
    self._firmware = part.CopyFile(
        PATH_CROS_FIRMWARE_UPDATER, self._temp_dir, fs_type=FS_TYPE_CROS_ROOTFS)
    return self._firmware

  @property
  def lsb_factory(self):
    if not self.factory_shim:
      return None
    if self._lsb_factory is not None:
      return self._lsb_factory

    part = Partition(self.factory_shim, PART_CROS_STATEFUL)
    logging.info('Loaded %s from %s.', PATH_LSB_FACTORY, part)
    self._lsb_factory = part.CopyFile(PATH_LSB_FACTORY, self._temp_dir)
    return self._lsb_factory

  def CreatePayloads(self, target_dir):
    """Builds cros_payload contents into target_dir.

    This is needed to store payloads or install to another system.

    Args:
      target_dir: a path to a folder for generating cros_payload contents.
    """
    logging.debug('Generating cros_payload contents...')
    json_path = CrosPayloadUtils.InitMetaData(target_dir, self.board)

    for component in PAYLOAD_COMPONENTS:
      resource = getattr(self, component)
      if resource:
        logging.debug('Add %s payloads from %s...', component, resource)
        CrosPayloadUtils.AddComponent(json_path, component, resource)
      else:
        print(f'Leaving {component} component payload as empty.')

  @classmethod
  def CopyPayloads(cls, src_dir, target_dir, json_path):
    """Copy cros_payload contents of a board to target_dir.

    Board metadata <board>.json stores the resources in a dictionary.

    {
      "release_image": {
        "version": <version>,
        "crx_cache": "release_image.crx_cache.xxx.gz",
        "part1": "release_image.part1.xxx.gz",
        ...
      },
      "test_image": {
        "version": <version>,
        "crx_cache": "test_image.crx_cache.xxx.gz",
        "part1": "test_image.part1.xxx.gz",
        ...
      },
      ...
    }

    The function copies resources of a board from src_dir to target_dir.

    Args:
      src_dir: path of source directory.
      target_dir: path of target directory.
      json_path: board metadata path <board>.json.
    """
    assert os.path.exists(src_dir), f'Path does not exist: {src_dir}'
    assert os.path.exists(target_dir), f'Path does not exist: {target_dir}'
    assert os.path.isfile(json_path), f'File does not exist: {json_path}'

    Sudo(f'cp -p {json_path} {target_dir}/')
    files = CrosPayloadUtils.GetAllComponentFiles(json_path)
    for f in files:
      path = os.path.join(src_dir, f)
      Sudo(f'cp -p {path} {target_dir}/')

  def GetPMBR(self, image_path):
    """Creates a file containing PMBR contents from given image.

    Chrome OS firmware does not really need PMBR, but many legacy operating
    systems, UEFI BIOS, or particular SOC may need it, so we do want to create
    PMBR using a bootable image (for example release or factory_shim image).

    Args:
      image_path: a path to a Chromium OS disk image to read back PMBR.

    Returns:
      A file (in self._temp_dir) containing PMBR.
    """
    pmbr_path = os.path.join(self._temp_dir, '_pmbr')
    with open(image_path, 'rb') as src:
      with open(pmbr_path, 'wb') as dest:
        # The PMBR is always less than DEFAULT_BLOCK_SIZE, no matter if the
        # disk has larger sector size.
        dest.write(src.read(DEFAULT_BLOCK_SIZE))
    return pmbr_path

  def ExecutePartitionScript(
      self, image_path, block_size, pmbr_path, rootfs, verbose=False):
    """Creates a partition script from write_gpt.sh inside image_path.

    To initialize (create partition table) on a new preflashed disk image for
    Chrome OS, we need to execute the write_gpt.sh included in rootfs of disk
    images.

    Args:
      image_path: the disk image to initialize partition table.
      block_size: the size of each logical block.
      pmbr_path: a path to a file with PMBR code (by self.CreatePMBR).
      rootfs: a directory to root file system containing write_gpt.sh script.
      verbose: True to enable debug out of script execution (-x).
    """
    write_gpt_path = os.path.join(rootfs, 'usr', 'sbin', 'write_gpt.sh')
    chromeos_common_path = os.path.join(rootfs, 'usr', 'share', 'misc',
                                        'chromeos-common.sh')

    if not os.path.exists(write_gpt_path):
      raise RuntimeError('Missing write_gpt.sh.')
    if not os.path.exists(chromeos_common_path):
      raise RuntimeError('Missing chromeos-common.sh.')

    # pygpt is already available, but to allow write_gpt.sh access gpt
    # commands, have to find an externally executable GPT.
    cgpt_command = SysUtils.FindCGPT()

    with GPT.Partition.MapAll(image_path, partscan=False,
                              block_size=block_size) as loop_dev:
      # stateful partitions are enlarged only if the target is a block device
      # (not file), in order to reduce USB image size. As a result, we have to
      # run partition script with disk mapped.
      commands = [
          # Currently write_gpt.sh will load chromeos_common from a fixed path.
          # In future when it supports overriding ROOT, we can invoke prevent
          # sourcing chromeos_common.sh explicitly below.
          f'. "{chromeos_common_path}"',
          f'. "{write_gpt_path}"',
          f'GPT="{cgpt_command}"',
          'set -e',
          f'write_base_table "{loop_dev}" "{pmbr_path}"',
          # write_base_table will set partition #2 to S=0, T=15, P=15.
          # However, if update_engine is disabled (very common in factory) or if
          # the system has to do several quick reboots before reaching
          # chromeos-setgoodkernel, then the device may run out of tries without
          # setting S=1 and will stop booting. So we want to explicitly set S=1.
          f'{cgpt_command} add -i 2 -S 1 "{loop_dev}"'
      ]
      # The commands must be executed in a single invocation for '.' to work.
      command = ' ; '.join(commands)
      Sudo(f"bash {'-x' if verbose else ''} -c '{command}'")

  def InitDiskImage(self, output, sectors, sector_size, verbose=False):
    """Initializes (resize and partition) a new disk image.

    Args:
      output: a path to disk image to initialize.
      sectors: integer for new size in number of sectors.
      sector_size: size of each sector (block) in bytes.
      verbose: provide more details when calling partition execution script.

    Returns:
      An integer as the size (in bytes) of output file.
    """
    new_size = sectors * sector_size
    print(f'Initialize disk image in {sectors}*{sector_size} bytes ['
          f'{new_size // GIGABYTE_STORAGE} G]')
    pmbr_path = self.GetPMBR(self.release_image)

    # TODO(hungte) Support block device as output, and support 'preserve'.
    Shell(['truncate', '-s', '0', output])
    Shell(['truncate', '-s', str(new_size), output])

    part = Partition(self.release_image, PART_CROS_ROOTFS_A)
    with part.MountAsCrOSRootfs() as rootfs:
      self.ExecutePartitionScript(
          output, sector_size, pmbr_path, rootfs, verbose)
    return new_size

  def CreateDiskImage(self, output, sectors, sector_size, stateful_free_space,
                      verbose=False):
    """Creates the installed disk image.

    This creates a complete image that can be pre-flashed to and boot from
    internal storage.

    Args:
      output: a path to disk image to initialize.
      sectors: number of sectors in disk image.
      sector_size: size of each sector in bytes.
      stateful_free_space: extra free space to claim in MB.
      verbose: provide more verbose output when initializing disk image.
    """

    def _CalculateDLCManifestSize(manifests_dir):
      total_size = 0
      for subdir in os.listdir(manifests_dir):
        manifest = os.path.join(manifests_dir, subdir, 'package',
                                'imageloader.json')
        if not os.path.exists(manifest):
          continue
        with open(manifest, encoding='utf8') as f:
          data = json.load(f)
          if data['factory-install']:
            # We need to preserve `2 * preallocated size`.
            # (See b/219670647#comment13)
            total_size = total_size + int(data['pre-allocated-size']) * 2

      return total_size

    def _CalculateDLCRuntimeSize(dev):
      """Calculate the size we need for factory installed DLC in runtime."""
      total_size = 0
      part = Partition(dev, PART_CROS_ROOTFS_A)
      with part.MountAsCrOSRootfs() as rootfs:
        manifests_dir = os.path.join(rootfs, 'opt', 'google', 'dlc')
        if os.path.exists(manifests_dir):
          total_size = _CalculateDLCManifestSize(manifests_dir)

      if not total_size:
        logging.debug('No factory installed DLC found. Do nothing.')
      else:
        logging.debug('Preallocate %d M for factory installed DLC...',
                      (total_size // MEGABYTE))
      return total_size

    new_size = self.InitDiskImage(output, sectors, sector_size, verbose)
    DIR_CROS_PAYLOADS = CrosPayloadUtils.GetCrosPayloadsDir()
    payloads_dir = os.path.join(self._temp_dir, DIR_CROS_PAYLOADS)
    SysUtils.CreateDirectories(payloads_dir)
    self.CreatePayloads(payloads_dir)
    json_path = CrosPayloadUtils.GetJSONPath(payloads_dir, self.board)

    with GPT.Partition.MapAll(output, block_size=sector_size) as output_dev:
      CrosPayloadUtils.InstallComponents(
          json_path, output_dev, ['test_image', 'release_image'])

    # output_dev (via /dev/loopX) needs root permission so we have to leave
    # previous context and resize using the real disk image file.
    part = Partition(output, PART_CROS_STATEFUL)

    # Additional amount of file system size we need to reserve:
    #   1. The free space required by user (stateful_free_space).
    #   2. The preallocated size for factory installed DLC.
    reserve_size = stateful_free_space * MEGABYTE + \
                   _CalculateDLCRuntimeSize(output)
    logging.debug('Will reserve additional space (%d M) for runtime overhead.',
                  (reserve_size // MEGABYTE))
    # Reserve additional 5% for root.
    total_fs_size = int((part.GetFileSystemSize() + reserve_size) * 1.05)
    logging.debug('Total reserved space: %d M', (total_fs_size // MEGABYTE))
    if total_fs_size >= part.size:
      raise RuntimeError(
          'Stateful partition is too small! Please increase the size of '
          f'preflash image! Current: {int(part.size // MEGABYTE)} M')
    part.ResizeFileSystem(total_fs_size)
    with GPT.Partition.MapAll(output, block_size=sector_size) as output_dev:
      targets = [
          'release_image.crx_cache', 'release_image.dlc_factory_cache', 'hwid',
          'project_config', 'toolkit'
      ]
      CrosPayloadUtils.InstallComponents(
          json_path, output_dev, targets, optional=True)

    logging.debug('Add /etc/lsb-factory if not exists.')
    with part.Mount(rw=True) as stateful:
      Sudo(['touch', os.path.join(stateful, PATH_LSB_FACTORY)], check=False)
      Sudo(['cp', '-pf', json_path,
            os.path.join(stateful, PATH_PREFLASH_PAYLOADS_JSON)], check=False)
    return new_size

  @classmethod
  def ShowDiskImage(cls, image):
    """Show the content of a disk image."""
    gpt = GPT.LoadFromFile(image)
    stateful_part = gpt.GetPartition(PART_CROS_STATEFUL)
    with stateful_part.Mount() as stateful:
      json_path = os.path.join(stateful, PATH_PREFLASH_PAYLOADS_JSON)
      if not os.path.exists(json_path):
        raise RuntimeError(f'Cannot find json file {json_path}.')
      versions = CrosPayloadUtils.GetComponentVersions(json_path)

      print(SPLIT_LINE)
      max_len = max([len(c) for c in PREFLASH_COMPONENTS])
      for component in PREFLASH_COMPONENTS:
        print(f'{component:<{max_len}}: {versions.get(component,None)}')
      print(SPLIT_LINE)

  def CreateRMAImage(self, output, src_payloads_dir=None,
                     active_test_list=None):
    """Creates the RMA bootable installation disk image.

    This creates an RMA image that can boot and install all factory software
    resouces to device.

    Args:
      output: a path to disk image to initialize.
      block_size: the size of block (sector) in bytes in output image.
    """
    # It is possible to enlarge the disk by calculating sizes of all input
    # files, create DIR_CROS_PAYLOADS folder in the disk image file, to minimize
    # execution time. However, that implies we have to shrink disk image later
    # (due to gz), and run build_payloads using root, which are all not easy.
    # As a result, here we want to create payloads in temporary folder then copy
    # into disk image.
    DIR_CROS_PAYLOADS = CrosPayloadUtils.GetCrosPayloadsDir()
    payloads_dir = os.path.join(self._temp_dir, DIR_CROS_PAYLOADS)
    SysUtils.CreateDirectories(payloads_dir)
    json_path = CrosPayloadUtils.GetJSONPath(payloads_dir, self.board)
    if src_payloads_dir:
      print('Copying payloads ...')
      src_json_path = CrosPayloadUtils.GetJSONPath(src_payloads_dir, self.board)
      self.CopyPayloads(src_payloads_dir, payloads_dir, src_json_path)
      # Replace `lsb_factory` payload in `src_payloads_dir` (if exists) with
      # `lsb-factory` file in factory_shim.
      CrosPayloadUtils.ReplaceComponent(
          json_path, PAYLOAD_TYPE_LSB_FACTORY, self.lsb_factory)
    else:
      self.CreatePayloads(payloads_dir)

    # Set active test_list
    if active_test_list:
      with SysUtils.TempDirectory() as config_dir:
        config_file_name = os.path.join(config_dir, 'config_file')
        try:
          CrosPayloadUtils.InstallComponents(json_path, config_file_name,
                                             PAYLOAD_TYPE_TOOLKIT_CONFIG,
                                             silent=True)
          with open(config_file_name, 'r', encoding='utf8') as config_file:
            config = json.load(config_file)
        except Exception:
          config = {}
        config.update({'active_test_list': {'id': active_test_list}})
        new_config_file_name = os.path.join(config_dir, 'new_config_file')
        with open(new_config_file_name, 'w', encoding='utf8') as config_file:
          SysUtils.WriteFile(
              config_file, json.dumps(config, indent=2, separators=(',', ': ')))
        CrosPayloadUtils.ReplaceComponent(
            json_path, PAYLOAD_TYPE_TOOLKIT_CONFIG, new_config_file_name)

    # Update lsb_factory payload.
    with SysUtils.TempDirectory() as lsb_dir:
      lsb_file_name = os.path.join(lsb_dir, 'lsb_file')
      CrosPayloadUtils.InstallComponents(json_path, lsb_file_name,
                                         PAYLOAD_TYPE_LSB_FACTORY, silent=True)

      lsb = LSBFile(lsb_file_name)
      lsb.SetValue('FACTORY_INSTALL_FROM_USB', '1')
      lsb.SetValue('FACTORY_INSTALL_ACTION_COUNTDOWN', 'true')
      lsb.SetValue('FACTORY_INSTALL_COMPLETE_PROMPT', 'true')
      lsb.SetValue('RMA_AUTORUN', 'true')

      new_lsb_file_name = os.path.join(lsb_dir, 'new_lsb_file')
      with open(new_lsb_file_name, 'w', encoding='utf8') as lsb_file:
        SysUtils.WriteFile(lsb_file, lsb.AsRawData() + '\n')
      CrosPayloadUtils.ReplaceComponent(json_path, PAYLOAD_TYPE_LSB_FACTORY,
                                        new_lsb_file_name)

    payloads_size = SysUtils.GetDiskUsage(payloads_dir)
    print(f'cros_payloads size: {payloads_size // MEGABYTE} M')

    shutil.copyfile(self.factory_shim, output)
    ExpandPartition(output, PART_CROS_STATEFUL, payloads_size)

    # Clear lsb-factory file in output image.
    with Partition(output, PART_CROS_STATEFUL).Mount(rw=True) as stateful:
      SysUtils.WriteFileToMountedDir(stateful, PATH_LSB_FACTORY,
                                     LSB_FACTORY_WARNING_MESSAGE)

    with Partition(output, PART_CROS_STATEFUL).Mount(rw=True) as stateful:
      print('Moving payload files to disk image...')
      DIR_CROS_PAYLOADS = CrosPayloadUtils.GetCrosPayloadsDir()
      new_name = os.path.join(stateful, DIR_CROS_PAYLOADS)
      new_dir = os.path.dirname(new_name)
      if os.path.exists(new_name):
        raise RuntimeError(
            f'Factory shim already contains {DIR_CROS_PAYLOADS} - already RMA?')
      Sudo(['chown', '-R', 'root:root', payloads_dir])
      Sudo(['mkdir', '-p', new_name, '-m', f'{MODE_NEW_DIR:o}'])
      Sudo(['mv', '-f', payloads_dir, new_dir])
      _WriteRMAMetadata(stateful,
                        board_list=[RMAImageBoardInfo(board=self.board)])

      Sudo(['df', '-h', stateful])

  @classmethod
  def ShowRMAImage(cls, image):
    """Show the content of a RMA image."""
    gpt = GPT.LoadFromFile(image)

    stateful_part = gpt.GetPartition(PART_CROS_STATEFUL)
    with stateful_part.Mount() as stateful:
      DIR_CROS_PAYLOADS = CrosPayloadUtils.GetCrosPayloadsDir()
      payloads_dir = os.path.join(stateful, DIR_CROS_PAYLOADS)
      if not os.path.exists(payloads_dir):
        raise RuntimeError(
            f'Cannot find dir /{DIR_CROS_PAYLOADS}, is this a RMA shim?')

      metadata = _ReadRMAMetadata(stateful)

      print('This RMA shim contains boards: '
            f"{' '.join(board_info.board for board_info in metadata)}")

      print(SPLIT_LINE)
      for board_info in metadata:
        with gpt.GetPartition(
            board_info.rootfs_a).MountAsCrOSRootfs() as rootfs:
          resource_versions = _ReadBoardResourceVersions(
              rootfs, stateful, board_info)
        print(resource_versions)
        print(SPLIT_LINE)

  class RMABoardEntry:
    """An internal class that stores the info of a board.

    The info includes
      board: board name.
      image: The image file that the board belongs to.
      versions: An RMABoardResourceVersions object being the payload versions
                of the board.
      kernel_a: A GPT.Partition object as the kernel A partition of the board.
      rootfs_a: A GPT.Partition object as the rootfs A partition of the board.
      kernel_b: A GPT.Partition object as the kernel B partition of the board.
      rootfs_b: A GPT.Partition object as the rootfs B partition of the board.
    """

    def __init__(self, board, image, versions, kernel_a, rootfs_a, kernel_b,
                 rootfs_b):
      self.board = board
      self.image = image
      self.versions = versions
      self.kernel_a = kernel_a
      self.rootfs_a = rootfs_a
      self.kernel_b = kernel_b
      self.rootfs_b = rootfs_b

    def GetPayloadSizes(self):
      """Returns a list of (resource name, resource size) of the board."""
      resources = []
      with Partition(self.image, PART_CROS_STATEFUL).Mount() as stateful:
        DIR_CROS_PAYLOADS = CrosPayloadUtils.GetCrosPayloadsDir()
        payloads_dir = os.path.join(stateful, DIR_CROS_PAYLOADS)
        json_path = CrosPayloadUtils.GetJSONPath(payloads_dir, self.board)
        json_file = os.path.basename(json_path)
        resources.append((json_file, SysUtils.GetDiskUsage(json_path)))
        with open(json_path, encoding='utf8') as f:
          metadata = json.load(f)
          for resource in metadata.values():
            for subtype, payload in resource.items():
              if subtype == PAYLOAD_SUBTYPE_VERSION:
                continue
              path = os.path.join(payloads_dir, payload)
              resources.append((payload, SysUtils.GetDiskUsage(path)))
      return resources

  @classmethod
  def _RecreateRMAImage(cls, output, images, select_func):
    """Recreate RMA (USB installation) disk images using existing ones.

    A (universal) RMA image should have factory_install kernel_a, rootfs_a
    in partition (2n+2, 2n+3) for n>=0, and
    resources in stateful partition (partition 1) DIR_CROS_PAYLOADS directory.
    This function extracts some stateful partitions using a user defined
    function `select_func` and then generates the output image by merging the
    resource files to partition 1 and cloning kernel_a, rootfs_a
    partitions of each selected boards.

    The layout of the merged output image:
       1 stateful  [sh1mmer, root from rmaimg1]
       2 kernel_a  [install-rmaimg1]
       3 rootfs_a  [install-rmaimg1]
       6 kernel_a  [install-rmaimg2]
       7 rootfs_a  [install-rmaimg2]
      ...

    Args:
      output: a path to output image file.
      images: a list of image files.
      select_func: A function that takes a list of RMABoardEntry, and returns
                   a reduced list with same or less elements. The remaining
                   board entries will be merged into a single RMA shim.
    """
    kern_rootfs_parts = []
    block_size = 0
    # Currently we only support merging images in same block size.
    for image in images:
      gpt = GPT.LoadFromFile(image)
      if block_size == 0:
        block_size = gpt.block_size
      assert gpt.block_size == block_size, (
          f'Cannot merge image {image} due to different block size ('
          f'{block_size}, {gpt.block_size})')
      kern_rootfs_parts.append(gpt.GetPartition(2))
      kern_rootfs_parts.append(gpt.GetPartition(3))

    # Build a new image based on first image's layout.
    gpt = pygpt.GPT.LoadFromFile(images[0])
    part_state = gpt.GetPartition(PART_CROS_STATEFUL)
    pad_blocks = gpt.header.FirstUsableLBA
    data_blocks = part_state.blocks + sum(p.blocks for p in kern_rootfs_parts)
    # pad_blocks hold header and partition tables, in front and end of image.
    new_size = (data_blocks + pad_blocks * 2) * block_size

    logging.info('Creating new image file as %s M...', new_size // MEGABYTE)
    Shell(['truncate', '-s', '0', output])
    Shell(['truncate', '-s', str(new_size), output])

    # Clear existing entries because this GPT was cloned from other image.
    for p in gpt.partitions:
      p.Zero()
    gpt.Resize(new_size)
    assert (gpt.header.LastUsableLBA - gpt.header.FirstUsableLBA + 1 >=
            data_blocks), 'Disk image is too small.'

    used_guids = []
    def AddPartition(number, p, begin):
      next_lba = begin + p.blocks
      guid = p.UniqueGUID
      if guid in used_guids:
        # Ideally we don't need to change UniqueGUID, but if user specified same
        # disk images in images then this may cause problems, for example
        # INVALID_ENTRIES in cgpt.
        logging.warning(
            'Duplicated UniqueGUID found from %s, replace with random.', p)
        guid = pygpt.GUID.Random()
      used_guids.append(guid)
      # The target number location will be different so we have to clone,
      # update and call UpdatePartition with new number explicitly.
      p = p.Clone()
      p.Update(
          UniqueGUID=guid,
          FirstLBA=begin,
          LastLBA=next_lba - 1)
      gpt.UpdatePartition(p, number=number)
      return next_lba

    # Put stateful partition at the end so we can resize it if needed.
    begin = gpt.header.FirstUsableLBA
    for i, p in enumerate(kern_rootfs_parts, 2):
      begin = AddPartition(i, p, begin)
    AddPartition(1, Partition(images[0], PART_CROS_STATEFUL), begin)

    gpt.WriteToFile(output)
    gpt.WriteProtectiveMBR(output, create=True)
    new_state = Partition(output, PART_CROS_STATEFUL)
    old_state = Partition(images[0], PART_CROS_STATEFUL)
    # TODO(chenghan): Find a way to copy stateful without cros_payloads/
    old_state.Copy(new_state, check_equal=False)

    for index, entry in enumerate(kern_rootfs_parts, 2):
      entry.Copy(Partition(output, index), check_equal=False)

    with Partition(output, PART_CROS_STATEFUL).Mount() as stateful:
      Sudo(['df', '-h', stateful])

  @classmethod
  def MergeRMAImage(cls, output, images, auto_select):
    """Merges multiple RMA disk images into a single universal RMA image.

    When there are duplicate boards across different images, it asks user to
    decide which one to use, or auto-select the last one if `auto_select` is
    set.
    """

    def _ResolveDuplicate(entries):
      board_map = {}
      for entry in entries:
        if entry.board not in board_map:
          board_map[entry.board] = []
        board_map[entry.board].append(entry)

      selected_entries = set()
      for board_name, board_entries in board_map.items():
        if len(board_entries) == 1 or auto_select:
          selected = len(board_entries) - 1
        else:
          title = f'Board {board_name} has more than one entry.'
          options = [
              f'From {entry.image}\n{entry.versions}' for entry in board_entries
          ]
          selected = UserInput.Select(title, options, single_line_option=False,
                                      split_line=True)
        selected_entries.add(board_entries[selected])

      resolved_entries = [
          entry for entry in entries if entry in selected_entries]

      return resolved_entries

    ChromeOSFactoryBundle._RecreateRMAImage(output, images, _ResolveDuplicate)

  @classmethod
  def ExtractRMAImage(cls, output, image, select=None):
    """Extract a board image from a universal RMA image."""

    def _SelectBoard(entries):
      if select is not None:
        selected = int(select) - 1
        if not 0 <= selected < len(entries):
          raise ValueError(f'Index {int(selected)} out of range.')
      else:
        title = 'Please select a board to extract.'
        options = [str(entry.versions) for entry in entries]
        selected = UserInput.Select(title,
                                    options,
                                    single_line_option=False,
                                    split_line=True)

      return [entries[selected]]

    ChromeOSFactoryBundle._RecreateRMAImage(output, [image], _SelectBoard)

  @classmethod
  def ReplaceRMAPayload(cls, image, board=None, **kargs):
    """Replace payloads in an RMA shim."""

    replaced_payloads = {
        component: payload for component, payload in kargs.items()
        if payload is not None}
    if not replaced_payloads:
      print('Nothing to replace.')
      return

    for component in replaced_payloads:
      assert component in PAYLOAD_COMPONENTS, (
          'Unknown component "%s"', component)

    if board is None:
      with Partition(image, PART_CROS_STATEFUL).Mount() as stateful:
        rma_metadata = _ReadRMAMetadata(stateful)
      if len(rma_metadata) == 1:
        board = rma_metadata[0].board
      else:
        raise RuntimeError('Board not set.')

    with CrosPayloadUtils.TempPayloadsDir() as temp_dir:
      CrosPayloadUtils.CopyComponentsInImage(image, board, [], temp_dir)
      json_path = CrosPayloadUtils.GetJSONPath(temp_dir, board)
      for component, payload in replaced_payloads.items():
        CrosPayloadUtils.ReplaceComponent(json_path, component, payload)
      CrosPayloadUtils.ReplaceComponentsInImage(image, board, temp_dir)

    with Partition(image, PART_CROS_STATEFUL).Mount() as stateful:
      Sudo(['df', '-h', stateful])

  @classmethod
  def GetKernelVersion(cls, image_path):
    raw_output = Shell(['file', image_path], output=True)
    versions = (line.strip().partition(' ')[2] for line in raw_output.split(',')
                if line.startswith(' version'))
    return next(versions, 'Unknown')

  @classmethod
  def GetFirmwareVersion(cls, image_path):
    with open(image_path, 'rb') as f:
      fw_image = fmap.FirmwareImage(f.read())
      ro = fw_image.get_section('RO_FRID').strip(b'\xff').strip(b'\0')
      for rw_name in ['RW_FWID', 'RW_FWID_A']:
        if fw_image.has_section(rw_name):
          rw = fw_image.get_section(rw_name).strip(b'\xff').strip(b'\0')
          break
      else:
        raise RuntimeError(f'Unknown RW firmware version in {image_path}')
    return {'ro': ro.decode('utf-8'), 'rw': rw.decode('utf-8')}

  @classmethod
  def GetFirmwareUpdaterVersion(cls, updater):
    if not updater:
      return {}

    with SysUtils.TempDirectory() as extract_dir:
      returncode = Shell([updater, '--unpack', extract_dir], silent=True,
                         check=False)
      # TODO(cyueh) Remove sb_extract after we dropping support for legacy
      # firmware updater.
      if returncode != 0:
        Shell([updater, '--sb_extract', extract_dir], silent=True)
      targets = {'main': 'bios.bin', 'ec': 'ec.bin'}
      # TODO(hungte) Read VERSION.signer for signing keys.
      results = {}
      for target, image in targets.items():
        image_path = os.path.join(extract_dir, image)
        if not os.path.exists(image_path):
          continue
        results[target] = ChromeOSFactoryBundle.GetFirmwareVersion(image_path)
    return results

  def GenerateTFTP(self, tftp_root):
    """Generates TFTP data in a given folder."""
    with open(
        os.path.join(tftp_root, '..', 'dnsmasq.conf'), 'w',
        encoding='utf8') as f:
      f.write(
          textwrap.dedent('''\
          # This is a sample config, can be invoked by "dnsmasq -d -C FILE".
          interface=eth2
          tftp-root=/var/tftp
          enable-tftp
          dhcp-leasefile=/tmp/dnsmasq.leases
          dhcp-range=192.168.200.50,192.168.200.150,12h
          port=0'''))

    tftp_server_ip = ''
    if self.server_url:
      tftp_server_ip = urllib.parse.urlparse(self.server_url).hostname
      server_url_config = os.path.join(tftp_root,
                                       f'omahaserver_{self.board}.conf')
      with open(server_url_config, 'w', encoding='utf8') as f:
        f.write(self.server_url)

    cmdline_sample = os.path.join(tftp_root, 'chrome-bot', self.board,
                                  'cmdline.sample')
    with open(cmdline_sample, 'w', encoding='utf8') as f:
      config = ('lsm.module_locking=0 cros_netboot_ramfs cros_factory_install '
                'cros_secure cros_netboot earlyprintk cros_debug loglevel=7 '
                'console=ttyS2,115200n8')
      if tftp_server_ip:
        config += f' tftpserverip={tftp_server_ip}'
      f.write(config)

  def CreateNetbootFirmware(self, src_path, dest_path):
    parser = argparse.ArgumentParser()
    netboot_firmware_settings.DefineCommandLineArgs(parser)
    # This comes from sys-boot/chromeos-bootimage: ${PORTAGE_USER}/${BOARD_USE}
    tftp_board_dir = f'chrome-bot/{self.board}'
    args = [
        '--argsfile',
        os.path.join(tftp_board_dir, 'cmdline'), '--bootfile',
        os.path.join(tftp_board_dir, 'vmlinuz'), '--input', src_path,
        '--output', dest_path
    ]
    if self.server_url:
      args += [
          '--factory-server-url', self.server_url,
          '--tftpserverip', urllib.parse.urlparse(self.server_url).hostname]
    netboot_firmware_settings.NetbootFirmwareSettings(parser.parse_args(args))

  @classmethod
  def GetImageVersion(cls, image):
    if not image:
      return 'N/A'
    part = Partition(image, PART_CROS_ROOTFS_A)
    with part.MountAsCrOSRootfs() as rootfs:
      lsb_path = os.path.join(rootfs, 'etc', 'lsb-release')
      return LSBFile(lsb_path).GetChromeOSVersion(remove_timestamp=False)

  def GetToolkitVersion(self, toolkit=None):
    toolkit = toolkit or self.toolkit
    if not toolkit:
      return 'NO_TOOLKIT'
    return Shell([toolkit, '--lsm'], output=True).strip()

  def CreateBundle(self, output_dir, phase, notes, timestamp=None):
    """Creates a bundle from given resources."""

    def FormatFirmwareVersion(info):
      if not info:
        return 'N/A'
      if info['ro'] == info['rw']:
        return info['ro']
      return f"RO: {info['ro']}, RW: {info['rw']}"

    def AddResource(dir_name, resources_glob, do_copy=False):
      """Adds resources to specified sub directory under bundle_dir.

      Returns the path of last created resource.
      """
      if not resources_glob:
        return None
      resources = glob.glob(resources_glob)
      if not resources:
        raise RuntimeError(f'Cannot find resource: {resources_glob}')
      resource_dir = os.path.join(bundle_dir, dir_name)
      if not os.path.exists(resource_dir):
        os.makedirs(resource_dir)
      dest_path = None
      for resource in resources:
        dest_name = os.path.basename(resource)
        # Many files downloaded from CPFE or GoldenEye may contain '%2F' in its
        # name and we want to remove them.
        strip = dest_name.rfind('%2F')
        if strip >= 0:
          # 3 as len('%2F')
          dest_name = dest_name[strip + 3:]
        dest_path = os.path.join(resource_dir, dest_name)
        if os.path.islink(resource):
          arcname = os.path.join(dir_name, dest_name)
          symlink_resources.append((resource, arcname))
        elif do_copy:
          shutil.copy(resource, dest_path)
        else:
          os.symlink(os.path.abspath(resource), dest_path)
      return dest_path

    if timestamp is None:
      timestamp = time.strftime('%Y%m%d')
    bundle_name = f'{self.board}_{timestamp}_{phase}'
    output_tar_name = f'factory_bundle_{bundle_name}.tar'
    output_tar_path = os.path.join(output_dir, output_tar_name)
    bundle_dir = os.path.join(self._temp_dir, 'bundle')
    SysUtils.CreateDirectories(bundle_dir)
    symlink_resources = []

    try:
      part = Partition(self.release_image, PART_CROS_ROOTFS_A)
      release_firmware_updater = part.CopyFile(
          PATH_CROS_FIRMWARE_UPDATER, self._temp_dir,
          fs_type=FS_TYPE_CROS_ROOTFS)
    except IOError:
      if phase not in {'proto', 'evt', 'dvt'}:
        # chromeos-firmwareupate should always be available since PVT
        # Currently, phase name like 'evt2' is not allowed, allowed phase names
        # are {'proto', 'evt', 'dvt', 'pvt', 'mp'}
        raise
      logging.warning('Failed to get firmware updater from release image',
                      exc_info=1)
      release_firmware_updater = None

    # The 'vmlinuz' may be in netboot/ folder (factory zip style) or
    # netboot/tftp/chrome-bot/$BOARD/vmlinuz (factory bundle style).
    netboot_vmlinuz = None
    has_tftp = False
    if self.netboot:
      netboot_vmlinuz = os.path.join(self.netboot, 'vmlinuz')
      if not os.path.exists(netboot_vmlinuz):
        netboot_vmlinuz = os.path.join(self.netboot, 'tftp', 'chrome-bot',
                                       self.board, 'vmlinuz')
        has_tftp = True

    readme_path = os.path.join(bundle_dir, 'README.md')
    with open(readme_path, 'w', encoding='utf8') as f:
      fw_ver = self.GetFirmwareUpdaterVersion(self.firmware)
      fsi_fw_ver = self.GetFirmwareUpdaterVersion(release_firmware_updater)
      info = [
          ('Board', self.board),
          ('Bundle',
           f"{bundle_name} (created by {os.environ.get('USER', 'unknown')})"),
          ('Factory toolkit', self.GetToolkitVersion()),
          ('Test image', self.GetImageVersion(self.test_image)),
          ('Factory shim', self.GetImageVersion(self.factory_shim)),
          ('AP firmware', FormatFirmwareVersion(fw_ver.get('main'))),
          ('EC firmware', FormatFirmwareVersion(fw_ver.get('ec'))),
          ('Release (FSI)', self.GetImageVersion(self.release_image)),
      ]
      if fsi_fw_ver != fw_ver:
        info += [('FSI AP firmware',
                  FormatFirmwareVersion(fsi_fw_ver.get('main'))),
                 ('FSI EC firmware', FormatFirmwareVersion(
                     fsi_fw_ver.get('ec')))]
      if self.netboot:
        for netboot_firmware_image in glob.glob(
            os.path.join(self.netboot, 'image*.net.bin')):
          key_name = 'Netboot firmware'
          match = re.fullmatch(r'image-(.*)\.net\.bin',
                               os.path.basename(netboot_firmware_image))
          if match:
            key_name += f' ({match.group(1)})'
          info += [(key_name,
                    FormatFirmwareVersion(
                        self.GetFirmwareVersion(netboot_firmware_image)))]
        info += [('Netboot kernel', self.GetKernelVersion(netboot_vmlinuz))]
      info += [('Factory server URL', self.server_url or 'N/A')]
      key_len = max(len(k) for (k, v) in info) + 2

      info_desc = '\n'.join(f'- {k+":":<{key_len}}{v}' for (k, v) in info)
      f.write('# Chrome OS Factory Bundle\n'
              f'{info_desc}\n'
              '## Additional Notes\n'
              f'{notes}\n')
    Shell(['cat', readme_path])

    AddResource('toolkit', self.toolkit)
    AddResource('release_image', self.release_image)
    AddResource('test_image', self.test_image)
    AddResource('firmware', self.firmware)
    AddResource('complete', self.complete)
    AddResource('hwid', self.hwid)
    AddResource('project_config', self.project_config)

    if self.server_url:
      shim_path = AddResource('factory_shim', self.factory_shim, do_copy=True)
      with Partition(shim_path, PART_CROS_STATEFUL).Mount(rw=True) as stateful:
        logging.info('Patching factory_shim lsb-factory file...')
        lsb = LSBFile(os.path.join(stateful, PATH_LSB_FACTORY))
        lsb.SetValue('CHROMEOS_AUSERVER', self.server_url)
        lsb.SetValue('CHROMEOS_DEVSERVER', self.server_url)
        lsb.Install(lsb.GetPath())
    else:
      AddResource('factory_shim', self.factory_shim)

    if self.setup_dir:
      AddResource('setup', os.path.join(self.setup_dir, '*'))
    if self.netboot:
      SysUtils.CreateDirectories(os.path.join(bundle_dir, 'netboot'))
      for netboot_firmware_image in glob.glob(
          os.path.join(self.netboot, 'image*.net.bin')):
        self.CreateNetbootFirmware(
            netboot_firmware_image,
            os.path.join(bundle_dir, 'netboot',
                         os.path.basename(netboot_firmware_image)))
      if has_tftp:
        AddResource('netboot', os.path.join(self.netboot, 'dnsmasq.conf'))
        AddResource('netboot', os.path.join(self.netboot, 'tftp'))
      else:
        AddResource(f'netboot/tftp/chrome-bot/{self.board}', netboot_vmlinuz)
        self.GenerateTFTP(os.path.join(bundle_dir, 'netboot', 'tftp'))

    Shell(['tar', '-chvf', output_tar_path, '-C', bundle_dir, '.'])
    if symlink_resources:
      with tarfile.open(output_tar_path, 'a') as tar:
        for resource, arcname in symlink_resources:
          tar.add(resource, arcname)
    Shell([SysUtils.FindBZip2(), output_tar_path])

    # Print final results again since tar may have flood screen output.
    Shell(['cat', readme_path])
    return output_tar_path + '.bz2'

  @classmethod
  def _ParseCrosConfig(cls, designs, root_path):
    """Parses a config file and selects fields used by factory environment.

    Args:
      designs: the designs we care about in this bundle.
      root_path: the root path.

    Returns:
      The set of the config strings.
    """
    config_path = os.path.join(root_path, 'usr', 'share', 'chromeos-config',
                               'yaml', 'config.yaml')

    if os.path.exists(config_path):
      print(f'{config_path} found.')
      with open(config_path, encoding='utf8') as f:
        obj = yaml.safe_load(f)['chromeos']['configs']
    else:
      print(f'{config_path} not found.')
      return {}

    def _SelectConfig(config: dict, fields: dict) -> dict:
      """Selects required config fields.

      For each key/value pairs in the `fields`, if the value is None, we store
      the corresponding value of the `config`. Moreover, we keep the value as
      None if the key is not presented in the `config`.

      Args:
        config: The original config.
        fields: A dict which each of its values is None or a nested dict.

      Returns:
        A selected config.
      """
      result = {}
      for field, sub_fields in fields.items():
        if sub_fields is None:
          result[field] = config.get(field)
        else:
          result[field] = _SelectConfig(config.get(field, {}), sub_fields)
      return result

    fields = {
        'name': None,
        'identity': None,
        'brand-code': None
    }
    configs_for_designs = [
        _SelectConfig(config, fields)
        for config in obj
        if config['name'] in designs
    ]
    for config in configs_for_designs:
      identity: Dict[str, Any] = config['identity']
      # According to https://crbug.com/1070692, 'platform-name' is not a part of
      # identity info.  We shouldn't check it.
      identity.pop('platform-name', None)
      # The change (https://crrev.com/c/3527015) was landed in 14675.0.0.
      # TODO(cyueh) Drop this after all factory branches before 14675.0.0 are
      # removed.
      non_inclusive_custom_label_tag_key = (
          bytes.fromhex('77686974656c6162656c2d746167').decode('utf-8'))
      label = identity.pop(non_inclusive_custom_label_tag_key, None)
      # The label may be an empty string.
      if label is not None:
        identity['custom-label-tag'] = label

      # According to b/245588383, 'frid' was introduced in recent cros_config
      # change and smbios-name-match/device-tree-compatible-match are removed.
      # In order to create factory bundle with non-frid factory branch
      # test image + frid-ready FSI, removed identity keys smbios-name-match and
      # device-tree-compatible-match have to be transformed into frid.
      smbios_match = identity.pop('smbios-name-match', None)
      if smbios_match:
        # Skolas to Google_Skolas
        config['identity']['frid'] = 'Google_' + smbios_match

      dt_match = identity.pop('device-tree-compatible-match', None)
      if dt_match:
        # google,skolas to Google_Skolas
        frid = '_'.join(dt_match.split(','))
        frid = '_'.join([frid_part.title() for frid_part in frid.split('_')])
        config['identity']['frid'] = frid

    return {
        # set sort_keys=True to make the result stable.
        json.dumps(config, sort_keys=True)
        for config in configs_for_designs
    }

  def VerifyCrosConfig(self):
    """Check if some fields in cros_config on both images are synced.

    Factory may use legacy cros_config values and read wrong config or write
    wrong values. This function checks some fields that must be synced.

    We also verify this in factory finalization but it's usually too late for
    users to find out that the images are not synced.
    """
    if not (self.designs or self.project):
      return
    designs = self.designs or [self.project]
    print(f'Verify cros_config of designs: {designs!r}')

    test_part = Partition(self.test_image, PART_CROS_ROOTFS_A)
    with test_part.MountAsCrOSRootfs() as rootfs:
      test_configs = self._ParseCrosConfig(designs, rootfs)
      if not test_configs:
        lsb_data = LSBFile(os.path.join(rootfs, 'etc', 'lsb-release'))
        version = version_utils.LooseVersion(
            lsb_data.GetChromeOSVersion(remove_milestone=True))
        if version < version_utils.LooseVersion('10212.0.0'):
          print(
              f'Skip cros_config verification for early test image: {version!r}'
          )
          return

    release_part = Partition(self.release_image, PART_CROS_ROOTFS_A)
    with release_part.MountAsCrOSRootfs() as rootfs:
      release_configs = self._ParseCrosConfig(designs, rootfs)

    error = []
    configs_not_in_release_configs = [
        test_config for test_config in test_configs
        if test_config not in release_configs
    ]
    if configs_not_in_release_configs:
      error += ['Identities found in test image could not be found in FSI.']
    if not test_configs:
      error += ['Detect empty chromeos-config for test image.']
    if not release_configs:
      error += ['Detect empty chromeos-config for release image.']
    if error:
      error += ['Configs in test image:']
      error += ['\t' + config for config in sorted(test_configs)]
      error += ['Configs in FSI:']
      error += ['\t' + config for config in sorted(release_configs)]
      error += ['Use --no_verify_cros_config to skip this check.']
      raise RuntimeError('\n'.join(error))
    messages = ['Configs in test image and FSI:']
    messages += ['\t' + config for config in sorted(test_configs)]
    print('\n'.join(messages))


def GetSubparsers(parser):
  """Helper function to get the subparsers of a parser.

  This function assumes that the parser has at most one subparsers.
  """
  # pylint: disable=protected-access
  actions = [action for action in parser._actions
             if isinstance(action, argparse._SubParsersAction)]
  assert len(actions) <= 1, 'The parser has multiple subparsers.'
  return actions[0] if actions else None


# TODO(hungte) Generalize this (copied from py/tools/factory.py) for all
# commands to utilize easily.
class SubCommand:
  """A subcommand.

  Properties:
    name: The name of the command (set by the subclass).
    parser: The ArgumentParser object.
    subparser: The subparser object created with parser.add_subparsers.
    subparsers: A collection of all subparsers.
    args: The parsed arguments.
  """
  namespace = None # Overridden by subclass
  name = None  # Overridden by subclass
  aliases = []  # Overridden by subclass

  parser = None
  args = None
  subparser = None
  subparsers = None

  def __init__(self, parser, subparsers):
    assert self.name
    self.parser = parser
    self.subparsers = subparsers
    subparser = subparsers.add_parser(
        self.name, help=self.__doc__.splitlines()[0],
        description=self.__doc__)
    subparser.set_defaults(subcommand=self)
    self.subparser = subparser

  def Init(self):
    """Initializes the subparser.

    May be implemented the subclass, which may use "self.subparser" to
    refer to the subparser object.
    """

  def Run(self):
    """Runs the command.

    Must be implemented by the subclass.
    """
    raise NotImplementedError


class SubCommandNamespace(SubCommand):
  """A command namespace."""

  def __init__(self, parser, subparsers):
    super().__init__(parser, subparsers)
    title = f'{self.name} subcommands'
    namespace_subparser = self.subparser.add_subparsers(
        title=title, dest='namespace_subcommand')
    namespace_subparser.required = True

  def Run(self):
    raise RuntimeError(
        'Run() function of subcommand namespace should never be called.')


class PayloadNamespace(SubCommandNamespace):
  """Subcommands to manipulate cros_payload components."""
  name = CMD_NAMESPACE_PAYLOAD


class RMANamespace(SubCommandNamespace):
  """Subcommands to create or modify RMA shim."""
  name = CMD_NAMESPACE_RMA


class HelpCommand(SubCommand):
  """Get help on COMMAND"""
  name = 'help'

  def Init(self):
    self.subparser.add_argument('command', metavar='COMMAND', nargs='*')

  def Run(self):
    parser = self.parser
    # When called by "image_tool help rma create", `self.args.command` will be
    # ['rma', 'create'], where 'rma' is a subparser of top layer parser, and
    # 'create' is a subparser of 'rma' parser.
    for v in self.args.command:
      try:
        parser = GetSubparsers(parser).choices[v]
      except Exception:
        sys.exit(f"Unknown subcommand {' '.join(self.args.command)!r}")
    parser.print_help()


class MountPartitionCommand(SubCommand):
  """Mounts a partition from Chromium OS disk image.

  Chrome OS rootfs with rootfs verification turned on will be mounted as
  read-only.  All other file systems will be mounted as read-write."""
  name = 'mount'
  aliases = ['mount_partition']

  def Init(self):
    self.subparser.add_argument(
        '-rw', '--rw', action='store_true',
        help='mount partition read/write')
    self.subparser.add_argument(
        '-ro', '--ro', dest='rw', action='store_false',
        help='mount partition read-only')
    self.subparser.add_argument('image', type=ArgTypes.ExistsPath,
                                help='path to the Chromium OS image')
    self.subparser.add_argument(
        'partition_number', type=int,
        help='which partition (1-based) to mount')
    self.subparser.add_argument(
        'mount_point', type=ArgTypes.ExistsPath,
        help='the path to mount partition')

  def Run(self):
    part = Partition(self.args.image, self.args.partition_number)
    mode = ''
    rw = True
    silent = True
    try_ro = True
    if self.args.rw is not None:
      rw = self.args.rw
      silent = False
      try_ro = False

    try:
      with part.Mount(self.args.mount_point, rw=rw, auto_umount=False,
                      silent=silent):
        mode = 'RW' if rw else 'RO'
    except subprocess.CalledProcessError:
      if not try_ro:
        raise
      logging.debug('Failed mounting %s, try again as ro/ext2...', part)
      with part.MountAsCrOSRootfs(self.args.mount_point, auto_umount=False):
        mode = 'RO'

    print(f'OK: Mounted {part} as {mode} on {self.args.mount_point}.')


class GetFirmwareCommand(SubCommand):
  """Extracts firmware updater from a Chrome OS disk image."""
  # Only Chrome OS disk images should have firmware updater, not Chromium OS.
  name = 'get_firmware'
  aliases = ['extract_firmware_updater']

  def Init(self):
    self.subparser.add_argument('-i', '--image', type=ArgTypes.ExistsPath,
                                required=True,
                                help='path to the Chrome OS (release) image')
    self.subparser.add_argument('-o', '--output_dir', default='.',
                                help='directory to save output file(s)')

  def Run(self):
    part = Partition(self.args.image, PART_CROS_ROOTFS_A)
    output = part.CopyFile(PATH_CROS_FIRMWARE_UPDATER, self.args.output_dir,
                           fs_type=FS_TYPE_CROS_ROOTFS)
    print(f'OK: Extracted {part}:{PATH_CROS_FIRMWARE_UPDATER} to: {output}')


class NetbootFirmwareSettingsCommand(SubCommand):
  """Access Chrome OS netboot firmware (image.net.bin) settings."""
  name = 'netboot'
  aliases = ['netboot_firmware_settings']

  def Init(self):
    netboot_firmware_settings.DefineCommandLineArgs(self.subparser)

  def Run(self):
    netboot_firmware_settings.NetbootFirmwareSettings(self.args)


class GPTCommand(SubCommand):
  """Access GPT (GUID Partition Table) with `cgpt` style commands."""
  name = 'gpt'
  aliases = ['pygpt', 'cgpt']
  gpt = None

  def Init(self):
    self.gpt = pygpt.GPTCommands()
    self.gpt.DefineArgs(self.subparser)

  def Run(self):
    self.gpt.Execute(self.args)


class ResizeFileSystemCommand(SubCommand):
  """Changes file system size from a partition on a Chromium OS disk image."""
  name = 'resize'
  aliases = ['resize_image_fs']

  def Init(self):
    self.subparser.add_argument('-i', '--image', type=ArgTypes.ExistsPath,
                                required=True,
                                help='path to the Chromium OS disk image')
    self.subparser.add_argument(
        '-p', '--partition_number', type=int, default=1,
        help='file system on which partition to resize')
    self.subparser.add_argument(
        '-s', '--size_mb', type=int, default=1024,
        help='file system size to change (set or add, see --append) in MB')
    self.subparser.add_argument(
        '-a', '--append', dest='append', action='store_true', default=True,
        help='append (increase) file system by +size_mb')
    self.subparser.add_argument('--no-append', dest='append',
                                action='store_false',
                                help='set file system to a new size of size_mb')

  def Run(self):
    part = Partition(self.args.image, self.args.partition_number)
    curr_size = part.GetFileSystemSize()

    if self.args.append:
      new_size = curr_size + self.args.size_mb * MEGABYTE
    else:
      new_size = self.args.size_mb * MEGABYTE

    if new_size > part.size:
      raise RuntimeError(
          f'Requested size ({new_size // MEGABYTE} MB) larger than {part} '
          f'partition ({part.size // MEGABYTE} MB).')

    new_size = part.ResizeFileSystem(new_size)
    print(
        f'OK: {part} file system has been resized from {curr_size // MEGABYTE} '
        f'to {new_size // MEGABYTE} MB.')


class CreatePreflashImageCommand(SubCommand):
  """Create a disk image for factory to pre-flash into internal storage.

  The output contains factory toolkit, release and test images.
  The manufacturing line can directly dump this image to device boot media
  (eMMC, SSD, NVMe, ... etc) using 'dd' command or copy machines.
  """
  name = 'preflash'

  def Init(self):
    ChromeOSFactoryBundle.DefineBundleArguments(
        self.subparser, ChromeOSFactoryBundle.PREFLASH)
    self.subparser.add_argument(
        '--sectors', type=int, default=31277232,
        help=('size of image in sectors (see --sector-size). '
              'default: %(default)s'))
    self.subparser.add_argument(
        '--sector-size', type=int, default=DEFAULT_BLOCK_SIZE,
        help='size of each sector. default: %(default)s')
    self.subparser.add_argument(
        # Allocate 1G for toolkit and another 1G for run time overhead.
        # (see b/219670647#comment32)
        '--stateful_free_space',
        type=int,
        default=2048,
        help=('extra space to claim in stateful partition in MB. '
              'default: %(default)s'))
    self.subparser.add_argument('-o', '--output', required=True,
                                help='path to the output disk image file.')

  def Run(self):
    with SysUtils.TempDirectory(prefix='diskimg_') as temp_dir:
      bundle = ChromeOSFactoryBundle(
          temp_dir=temp_dir,
          board=PREFLASH_DEFAULT_BOARD,
          release_image=self.args.release_image,
          test_image=self.args.test_image,
          toolkit=self.args.toolkit,
          factory_shim=None,
          enable_firmware=False,
          hwid=self.args.hwid,
          complete=None,
          project_config=self.args.project_config,
          project=self.args.project,
          designs=self.args.designs,
      )
      if self.args.verify_cros_config:
        bundle.VerifyCrosConfig()
      new_size = bundle.CreateDiskImage(
          self.args.output, self.args.sectors, self.args.sector_size,
          self.args.stateful_free_space, self.args.verbose)
    print(f'OK: Generated pre-flash disk image at {self.args.output} ['
          f'{new_size // GIGABYTE_STORAGE} G]')


class ShowPreflashImageCommand(SubCommand):
  """Show the content of a disk image."""
  name = 'preflash-show'

  def Init(self):
    self.subparser.add_argument('-i', '--image', required=True,
                                type=ArgTypes.ExistsPath,
                                help='Path to input preflash image.')

  def Run(self):
    ChromeOSFactoryBundle.ShowDiskImage(self.args.image)


class CreateRMAImageCommmand(SubCommand):
  """Create an RMA image for factory to boot from USB and repair device.

  The output is a special factory install shim (factory_install) with all
  resources (release, test images and toolkit). The manufacturing line or RMA
  centers can boot it from USB and install all factory software bits into
  a device.
  """
  namespace = CMD_NAMESPACE_RMA
  name = 'create'
  aliases = ['create_rma', 'rma-create']

  def Init(self):
    ChromeOSFactoryBundle.DefineBundleArguments(self.subparser,
                                                ChromeOSFactoryBundle.RMA)
    self.subparser.add_argument('--active_test_list', default=None,
                                help='active test list')
    self.subparser.add_argument('-f', '--force', action='store_true',
                                help='Overwrite existing output image file.')
    self.subparser.add_argument('-o', '--output', required=True,
                                help='path to the output RMA image file')

  def Run(self):
    output = self.args.output
    if os.path.exists(output) and not self.args.force:
      raise RuntimeError(
          f'Output already exists (add -f to overwrite): {output}')

    with SysUtils.TempDirectory(prefix='rma_') as temp_dir:
      bundle = ChromeOSFactoryBundle(
          temp_dir=temp_dir,
          board=self.args.board,
          release_image=self.args.release_image,
          test_image=self.args.test_image,
          toolkit=self.args.toolkit,
          factory_shim=self.args.factory_shim,
          enable_firmware=self.args.enable_firmware,
          firmware=self.args.firmware,
          hwid=self.args.hwid,
          complete=self.args.complete,
          toolkit_config=self.args.toolkit_config,
          description=self.args.description,
          project_config=self.args.project_config,
          project=self.args.project,
          designs=self.args.designs,
      )
      if self.args.verify_cros_config:
        bundle.VerifyCrosConfig()
      bundle.CreateRMAImage(self.args.output,
                            active_test_list=self.args.active_test_list)
      ChromeOSFactoryBundle.ShowRMAImage(output)
      print(f'OK: Generated {bundle.board} RMA image at {self.args.output}')


class MergeRMAImageCommand(SubCommand):
  """Merge multiple RMA images into one single large image."""
  namespace = CMD_NAMESPACE_RMA
  name = 'merge'
  aliases = ['merge_rma', 'rma-merge']

  def Init(self):
    self.subparser.add_argument('-f', '--force', action='store_true',
                                help='Overwrite existing output image file.')
    self.subparser.add_argument('-o', '--output', required=True,
                                help='Path to the merged output image.')
    self.subparser.add_argument('-i', '--images', required=True, nargs='+',
                                type=ArgTypes.ExistsPath,
                                help='Path to input RMA images')
    self.subparser.add_argument(
        '-a', '--auto_select', action='store_true',
        help='Automatically resolve duplicate boards (use the last one).')


  def Run(self):
    """Merge multiple RMA (USB installation) disk images.

    The RMA images should be created by 'image_tool rma' command, with different
    board names.
    """
    output = self.args.output
    if os.path.exists(output) and not self.args.force:
      raise RuntimeError(
          f'Output already exists (add -f to overwrite): {output}')
    if len(self.args.images) < 2:
      raise RuntimeError('Need > 1 input image files to merge.')

    print(f'Scanning {len(self.args.images)} input image files...')
    ChromeOSFactoryBundle.MergeRMAImage(self.args.output, self.args.images,
                                        self.args.auto_select)
    #ChromeOSFactoryBundle.ShowRMAImage(output)
    print(f'OK: Merged successfully in new image: {output}')


class ExtractRMAImageCommand(SubCommand):
  """Extract an RMA image from a universal RMA image."""
  namespace = CMD_NAMESPACE_RMA
  name = 'extract'
  aliases = ['extract_rma', 'rma-extract']

  def Init(self):
    self.subparser.add_argument('-f', '--force', action='store_true',
                                help='Overwrite existing output image file.')
    self.subparser.add_argument('-o', '--output', required=True,
                                help='Path to the merged output image.')
    self.subparser.add_argument('-i', '--image', required=True,
                                type=ArgTypes.ExistsPath,
                                help='Path to input RMA image.')
    self.subparser.add_argument(
        '-s', '--select', default=None,
        help='Select the SELECT-th board in the shim to extract.')

  def Run(self):
    """Extract RMA (USB installation) disk image from a universal RMA image.

    The RMA image should be created by 'image_tool rma create' or
    'image_tool rma merge' command.
    """
    output = self.args.output
    if os.path.exists(output) and not self.args.force:
      raise RuntimeError(
          f'Output already exists (add -f to overwrite): {output}')

    print('Scanning input image file...')
    ChromeOSFactoryBundle.ExtractRMAImage(self.args.output, self.args.image,
                                          self.args.select)
    ChromeOSFactoryBundle.ShowRMAImage(output)
    print(f'OK: Extracted successfully in new image: {output}')


class ShowRMAImageCommand(SubCommand):
  """Show the content of a RMA image."""
  namespace = CMD_NAMESPACE_RMA
  name = 'show'
  aliases = ['show_rma', 'rma-show']

  def Init(self):
    self.subparser.add_argument('-i', '--image', required=True,
                                type=ArgTypes.ExistsPath,
                                help='Path to input RMA image.')

  def Run(self):
    ChromeOSFactoryBundle.ShowRMAImage(self.args.image)


class ReplaceRMAComponentCommand(SubCommand):
  """Replace components in an RMA shim."""
  namespace = CMD_NAMESPACE_RMA
  name = 'replace'
  aliases = ['replace_rma', 'rma-replace']

  def Init(self):
    ChromeOSFactoryBundle.DefineBundleArguments(
        self.subparser, ChromeOSFactoryBundle.REPLACEABLE)
    self.subparser.add_argument(
        '-i', '--image', required=True,
        type=ArgTypes.ExistsPath,
        help='Path to input RMA image.')
    self.subparser.add_argument(
        '--firmware_from_release', action='store_true',
        help='Replace firmware with the one in the provided release image.')

  def Run(self):
    with SysUtils.TempDirectory(prefix='rma_') as temp_dir:
      # Get firmware from release_image.
      if self.args.release_image and self.args.firmware_from_release:
        part = Partition(self.args.release_image, PART_CROS_ROOTFS_A)
        self.args.firmware = part.CopyFile(
            PATH_CROS_FIRMWARE_UPDATER, temp_dir, fs_type=FS_TYPE_CROS_ROOTFS)
      # Replacing factory shim is different from replacing other payloads.
      # Other payloads are stored as compressed files in stateful partition. We
      # only need to replace files and adjust the size of stateful partition,
      # which is easy because stateful partition is the last partition.
      # Replacing factory shim actually replaces kernel and rootfs partition.
      # These partitions are not the last partition and we cannot easily change
      # their sizes, so we can only use the factory shim to create a new RMA
      # shim and overwrite the original image.
      single_board_image = None
      if self.args.factory_shim:
        if self.args.board is None:
          self.args.board = _GetBoardName(self.args.image)
        logging.warning('Replacing factory shim for board %s. '
                        'lsb-factory configs will be cleared.', self.args.board)
        single_board_image = os.path.join(temp_dir, 'single_board.bin')
        bundle = ChromeOSFactoryBundle(
            temp_dir=temp_dir, board=self.args.board, release_image=None,
            test_image=None, toolkit=None, factory_shim=self.args.factory_shim)
        with Partition(self.args.image, PART_CROS_STATEFUL).Mount() as stateful:
          DIR_CROS_PAYLOADS = CrosPayloadUtils.GetCrosPayloadsDir()
          src_payloads_dir = os.path.join(stateful, DIR_CROS_PAYLOADS)
          bundle.CreateRMAImage(
              single_board_image, src_payloads_dir=src_payloads_dir)
          # Also get RMA metadata here.
          rma_metadata = _ReadRMAMetadata(stateful)

      target_image = (
          single_board_image if single_board_image else self.args.image)
      ChromeOSFactoryBundle.ReplaceRMAPayload(
          target_image, board=self.args.board,
          release_image=self.args.release_image,
          test_image=self.args.test_image, toolkit=self.args.toolkit,
          firmware=self.args.firmware, hwid=self.args.hwid,
          complete=self.args.complete, toolkit_config=self.args.toolkit_config,
          project_config=self.args.project_config)

      if self.args.factory_shim:
        if len(rma_metadata) > 1:
          # If the original shim is a multi-board shim, we need to replace the
          # board in the multi-board shim with the new single-board shim.
          multi_board_image = os.path.join(temp_dir, 'multi_board.bin')
          ChromeOSFactoryBundle.MergeRMAImage(
              multi_board_image, [self.args.image, single_board_image],
              auto_select=True)
          Shell(['mv', multi_board_image, self.args.image])
        else:
          Shell(['mv', single_board_image, self.args.image])

    ChromeOSFactoryBundle.ShowRMAImage(self.args.image)
    print(f'OK: Replaced components successfully in image: {self.args.image}')


class ToolkitCommand(SubCommand):
  """Unpack/repack the factory toolkit in an RMA shim."""
  namespace = CMD_NAMESPACE_PAYLOAD
  name = 'toolkit'

  def Init(self):
    self.subparser.add_argument(
        '-i', '--image', required=True,
        type=ArgTypes.ExistsPath,
        help='Path to input RMA image.')
    self.subparser.add_argument('--board', type=str, default=None,
                                help='Board to get toolkit.')
    self.subparser.add_argument('--unpack', type=str, default=None,
                                help='Path to unpack the toolkit.')
    self.subparser.add_argument('--repack', type=str, default=None,
                                help='Path to repack the toolkit.')

  def Run(self):
    # Check that exactly one of --unpack and --repack is specified.
    # When unpacking, check that the unpack directory doesn't exist yet.
    # When repacking, check that the repack directory exists.
    if not bool(self.args.unpack) ^ bool(self.args.repack):
      raise RuntimeError('Please specify exactly one of --unpack and --repack.')
    target_path = self.args.unpack or self.args.repack
    if self.args.unpack:
      if os.path.exists(target_path):
        raise RuntimeError(f'Extract path "{target_path}" already exists.')
    if self.args.repack:
      if not os.path.isdir(target_path):
        raise RuntimeError('PATH should be a directory.')

    with SysUtils.TempDirectory() as temp_dir:
      old_toolkit_path = os.path.join(temp_dir, 'old_toolkit')
      new_toolkit_path = os.path.join(temp_dir, 'new_toolkit')
      # Extract old_toolkit.
      with Partition(self.args.image, PART_CROS_STATEFUL).Mount() as stateful:
        if self.args.board is None:
          rma_metadata = _ReadRMAMetadata(stateful)
          if len(rma_metadata) == 1:
            self.args.board = rma_metadata[0].board
          else:
            raise RuntimeError('Board not set.')
        DIR_CROS_PAYLOADS = CrosPayloadUtils.GetCrosPayloadsDir()
        old_payloads_dir = os.path.join(stateful, DIR_CROS_PAYLOADS)
        old_json_path = CrosPayloadUtils.GetJSONPath(old_payloads_dir,
                                                     self.args.board)
        CrosPayloadUtils.GetToolkit(old_json_path, old_toolkit_path)
      # Unpack toolkit
      if self.args.unpack:
        Shell([old_toolkit_path, '--target', target_path, '--noexec'])
        print(f'OK: Unpacked {self.args.board} toolkit to directory "'
              f'{target_path}".')
      # Repack toolkit.
      if self.args.repack:
        Shell([
            old_toolkit_path, '--', '--repack', target_path, '--pack-into',
            new_toolkit_path
        ])
        # Replace old_toolkit in image with new_toolkit.
        with CrosPayloadUtils.TempPayloadsDir() as new_payloads_dir:
          CrosPayloadUtils.CopyComponentsInImage(
              self.args.image, self.args.board, [], new_payloads_dir)
          new_json_path = CrosPayloadUtils.GetJSONPath(new_payloads_dir,
                                                       self.args.board)
          CrosPayloadUtils.ReplaceComponent(
              new_json_path, PAYLOAD_TYPE_TOOLKIT, new_toolkit_path)
          CrosPayloadUtils.ReplaceComponentsInImage(
              self.args.image, self.args.board, new_payloads_dir)
        print(f'OK: Repacked {self.args.board} toolkit from directory "'
              f'{target_path}".')


class CreateBundleCommand(SubCommand):
  """Creates a factory bundle from given arguments."""
  name = 'bundle'

  def Init(self):
    ChromeOSFactoryBundle.DefineBundleArguments(self.subparser,
                                                ChromeOSFactoryBundle.BUNDLE)
    self.subparser.add_argument(
        '-o', '--output_dir', default='.',
        help='directory for the output factory bundle file')
    self.subparser.add_argument(
        '--timestamp', help='override the timestamp field in output file name')
    self.subparser.add_argument(
        '-n', '--notes', help='additional notes or comments for bundle release')

  def Run(self):
    with SysUtils.TempDirectory(prefix='bundle_') as temp_dir:
      bundle = ChromeOSFactoryBundle(
          temp_dir=temp_dir,
          board=self.args.board,
          release_image=self.args.release_image,
          test_image=self.args.test_image,
          toolkit=self.args.toolkit,
          factory_shim=self.args.factory_shim,
          enable_firmware=self.args.enable_firmware,
          firmware=self.args.firmware,
          hwid=self.args.hwid,
          complete=self.args.complete,
          netboot=self.args.netboot,
          project_config=self.args.project_config,
          setup_dir=self.args.setup_dir,
          server_url=self.args.server_url,
          project=self.args.project,
          designs=self.args.designs,
      )
      if self.args.verify_cros_config:
        bundle.VerifyCrosConfig()
      output_file = bundle.CreateBundle(self.args.output_dir, self.args.phase,
                                        self.args.notes,
                                        timestamp=self.args.timestamp)
      print(f'OK: Created {bundle.board} factory bundle: {output_file}')


class CreateDockerImageCommand(SubCommand):
  """Create a Docker image from existing Chromium OS disk image.

  The architecture of the source Chromium OS disk image should be the same as
  the docker host (basically, amd64).
  """
  name = 'docker'

  def Init(self):
    self.subparser.add_argument('-i', '--image', type=ArgTypes.ExistsPath,
                                required=True,
                                help='path to the Chromium OS image')

  def _CreateDocker(self, image, root):
    """Creates a docker image from prepared rootfs and stateful partition.

    Args:
      image: a path to raw input image.
      root: a path to prepared (mounted) Chromium OS disk image.
    """
    logging.debug('Checking image board and version...')
    lsb_data = LSBFile(os.path.join(root, 'etc', 'lsb-release'))
    board = lsb_data.GetChromeOSBoard()
    version = lsb_data.GetChromeOSVersion()
    if not board or not version:
      raise RuntimeError(
          f'Input image does not have proper Chromium OS board [{board}] or '
          f'version [{version}] info.')
    docker_name = f'cros/{board}_test:{version}'
    docker_tag = f'cros/{board}_test:latest'
    print(f'Creating Docker image as {docker_name} ...')

    # Use pv if possible. It may be hard to estimate the real size of files in
    # mounted folder so we will use 2/3 of raw disk image - which works on most
    # test images.
    try:
      pv = f"{SysUtils.FindCommand('pv')} -s {os.path.getsize(image) // 3 * 2}"
    except Exception:
      pv = 'cat'

    Sudo(f'tar -C "{root}" -c . | {pv} | docker import - "{docker_name}"')
    Sudo(['docker', 'tag', docker_name, docker_tag])
    return docker_name

  def Run(self):
    rootfs_part = Partition(self.args.image, PART_CROS_ROOTFS_A)
    state_part = Partition(self.args.image, PART_CROS_STATEFUL)

    with state_part.Mount() as state:
      with rootfs_part.MountAsCrOSRootfs() as rootfs:
        Sudo([
            'mount', '--bind',
            os.path.join(state, 'var_overlay'),
            os.path.join(rootfs, 'var')
        ])
        Sudo(['mount', '--bind', os.path.join(state, 'dev_image'),
              os.path.join(rootfs, 'usr', 'local')])
        docker_name = self._CreateDocker(self.args.image, rootfs)

    print(f'OK: Successfully built docker image [{docker_name}] from '
          f'{self.args.image}.')


class InstallChromiumOSImageCommand(SubCommand):
  """Installs a Chromium OS disk image into inactive partition.

  This command takes a Chromium OS (USB) disk image, installs into current
  device (should be a Chromium OS device) and switches boot records to try
  the newly installed kernel.
  """
  name = 'install'

  def Init(self):
    self.subparser.add_argument(
        '-i', '--image', type=ArgTypes.ExistsPath, required=True,
        help='path to a Chromium OS disk image or USB stick device')
    self.subparser.add_argument(
        '-o', '--output', type=ArgTypes.ExistsPath, required=False,
        help=('install to given path of a disk image or USB stick device; '
              'default to boot disk'))
    self.subparser.add_argument(
        '-x', '--exclude', type=str, default='dev_image/telemetry/*',
        help='pattern to tar --exclude when copying stateful partition.')
    self.subparser.add_argument(
        '--no-stateful-partition', dest='do_stateful', action='store_false',
        default=True,
        help='skip copying stateful partition')
    self.subparser.add_argument(
        '-p', '--partition_number', type=int, required=False, help=(
            'kernel partition number to install (rootfs will be +1); default '
            f'to {PART_CROS_KERNEL_A} or {PART_CROS_KERNEL_B} if active kernel '
            f'is {PART_CROS_KERNEL_A}.'))

  def Run(self):
    # TODO(hungte) Auto-detect by finding removable and fixed storage for from
    # and to.
    from_image = self.args.image
    to_image = self.args.output
    arg_part = self.args.partition_number
    exclude = self.args.exclude
    to_part = arg_part if arg_part is not None else PART_CROS_KERNEL_A

    if to_image is None:
      to_image = SudoOutput('rootdev -s -d').strip()
    is_block = GPT.IsBlockDevice(to_image)

    if is_block:
      # to_part refers to kernel but rootdev -s refers to rootfs.
      to_rootfs = MakePartition(to_image, to_part + 1)
      if to_rootfs == SudoOutput('rootdev -s').strip():
        if arg_part is not None:
          raise RuntimeError(f'Cannot install to active partition {to_rootfs}')
        known_kernels = [PART_CROS_KERNEL_A, PART_CROS_KERNEL_B]
        if to_part not in known_kernels:
          raise RuntimeError(f'Unsupported kernel destination for {to_rootfs}')
        to_part = known_kernels[1 - known_kernels.index(to_part)]

    # Ready to install!
    gpt_from = GPT.LoadFromFile(from_image)
    gpt_to = GPT.LoadFromFile(to_image)

    # On USB stick images, kernel A is signed by recovery key and B is signed by
    # normal key, so we have to choose B when installed to disk.
    print(f'Installing [{from_image}] to [{to_image}#{to_part}]...')
    gpt_from.GetPartition(PART_CROS_KERNEL_B).Copy(
        gpt_to.GetPartition(to_part), sync=is_block, verbose=True)
    gpt_from.GetPartition(PART_CROS_ROOTFS_A).Copy(
        gpt_to.GetPartition(to_part + 1), check_equal=False, sync=is_block,
        verbose=True)

    # Now, prioritize and make kernel A bootable.
    # TODO(hungte) Check if kernel key is valid.
    pri_cmd = pygpt.GPTCommands.Prioritize()
    pri_cmd.ExecuteCommandLine('-i', str(to_part), to_image)

    # People may try to abort if installing stateful partition takes too much
    # time, so we do want to sync now (for partition changes to commit).
    print('Syncing...')
    Shell('sync')

    # Call 'which' directly to avoid error messages by FindCommand.
    pv = SysUtils.Shell('which pv 2>/dev/null || echo cat', output=True).strip()

    # TODO(hungte) Do partition copy if stateful in to_image is not mounted.
    # Mount and copy files in stateful partition.
    # Note stateful may not support mount with rw=False.
    with gpt_from.GetPartition(PART_CROS_STATEFUL).Mount(rw=True) as from_dir:
      dev_image_from = os.path.join(from_dir, 'dev_image')
      if self.args.do_stateful and os.path.exists(dev_image_from):
        print('Copying stateful partition...')
        with gpt_to.GetPartition(PART_CROS_STATEFUL).Mount(rw=True) as to_dir:
          dev_image_old = os.path.join(to_dir, 'dev_image.old')
          dev_image_to = os.path.join(to_dir, 'dev_image')
          if os.path.exists(dev_image_old):
            logging.warning('Removing %s...', dev_image_old)
            Sudo(['rm', '-rf', dev_image_old])
          if os.path.exists(dev_image_to):
            Sudo(['mv', dev_image_to, dev_image_old])
          # Use sudo instead of shutil.copytree sine people may invoke this
          # command with user permission (which works for copying partitions).
          # SysUtils.Sudo does not support pipe yet so we have to add 'sh -c'.
          Sudo([
              'sh', '-c',
              (f'tar -C {from_dir} -cf - dev_image | {pv} | tar -C {to_dir} '
               f'--warning=none --exclude="{exclude}" -xf -')
          ])

    print(
        f'OK: Successfully installed image from [{from_image}] to [{to_image}].'
    )


class EditLSBCommand(SubCommand):
  """Edit contents of 'lsb-factory' file from a factory_install image."""
  name = 'edit_lsb'

  old_data = ''
  lsb = None

  def Init(self):
    self.subparser.add_argument('-i', '--image', type=ArgTypes.ExistsPath,
                                required=True,
                                help='Path to the factory_install image.')
    self.subparser.add_argument('--board', type=str, default=None,
                                help='Board to edit lsb file.')

  def _DoURL(self, title, keys, default_port=8080, suffix=''):
    host = UserInput.GetString(f'{title} host', optional=True)
    if not host:
      return
    port = UserInput.GetString(f'Enter port (default={default_port})',
                               optional=True)
    if not port:
      port = str(default_port)
    url = f'http://{host}:{port}{suffix}'
    for key in keys:
      self.lsb.SetValue(key, url)

  def _DoOptions(self, title, key, options):
    selected = UserInput.Select(f'{title} ({key})', options)
    value = options[selected]
    self.lsb.SetValue(key, value)
    return value

  def _DoOptionalNumber(self, title, key, min_value, max_value):
    selected = UserInput.GetNumber(f'{title} ({key})', min_value=min_value,
                                   max_value=max_value, optional=True)
    if selected is not None:
      self.lsb.SetValue(key, str(selected))
    else:
      self.lsb.DeleteValue(key)
    return selected

  def EditBoard(self):
    """Modify board to install."""
    board = UserInput.GetString('Enter board name', optional=True)
    if board:
      self.lsb.SetValue('CHROMEOS_RELEASE_BOARD', board)

  def EditServerAddress(self):
    """Modify Chrome OS Factory Server address."""
    self._DoURL('Chrome OS Factory Server',
                ['CHROMEOS_AUSERVER', 'CHROMEOS_DEVSERVER'], suffix='/update')

  def EditDefaultAction(self):
    """Modify default action (will be overridden by RMA autorun)."""
    action = UserInput.GetString(
        'Enter default action (empty to remove)', max_length=1, optional=True)
    key = 'FACTORY_INSTALL_DEFAULT_ACTION'
    if action:
      self.lsb.SetValue(key, action)
    else:
      self.lsb.DeleteValue(key)

  def EditActionCountdown(self):
    """Enable/disable countdown before default action."""
    answer = UserInput.YesNo(
        'Enable (y) or disable (n) default action countdown?')
    self.lsb.SetValue('FACTORY_INSTALL_ACTION_COUNTDOWN',
                      'true' if answer else 'false')

  def EditCompletePrompt(self):
    """Enable/disable complete prompt in RMA shim.

    If complete prompt is set, wait for ENTER after installation is completed.
    """
    answer = UserInput.YesNo(
        'Enable (y) or disable (n) complete prompt in RMA?')
    self.lsb.SetValue('FACTORY_INSTALL_COMPLETE_PROMPT',
                      'true' if answer else 'false')

  def EditRMAAutorun(self):
    """Enable/disable autorun in RMA shim.

    If RMA autorun is set, automatically do RSU (RMA Server Unlock) or install,
    depending on HWWP status.
    """
    answer = UserInput.YesNo('Enable (y) or disable (n) autorun in RMA?')
    self.lsb.SetValue('RMA_AUTORUN', 'true' if answer else 'false')

  def EditCutoff(self):
    """Modify cutoff config in cros payload (only for old devices).

    All options are defined in src/platform/factory/sh/cutoff/options.sh
    """
    self._DoOptions(
        'Select cutoff method', 'CUTOFF_METHOD',
        ['shutdown', 'reboot', 'battery_cutoff', 'ectool_cutoff',
         'ec_hibernate'])
    self._DoOptions(
        'Select cutoff AC state', 'CUTOFF_AC_STATE',
        ['none', 'remove_ac', 'connect_ac'])
    answer = self._DoOptionalNumber(
        'Minimum allowed battery percentage', 'CUTOFF_BATTERY_MIN_PERCENTAGE',
        0, 100)
    self._DoOptionalNumber(
        'Maximum allowed battery percentage', 'CUTOFF_BATTERY_MAX_PERCENTAGE',
        answer or 0, 100)
    answer = self._DoOptionalNumber(
        'Minimum allowed battery voltage (mA)', 'CUTOFF_BATTERY_MIN_VOLTAGE',
        None, None)
    self._DoOptionalNumber('Maximum allowed battery voltage (mA)',
                           'CUTOFF_BATTERY_MAX_VOLTAGE', answer, None)
    self._DoURL(
        'Chrome OS Factory Server or Shopfloor Service for OQC ReFinalize',
        ['SHOPFLOOR_URL'])

  def EditDisplayQrcode(self):
    """Enable or disable qrcode when factory reset.

    Check src/platform/factory_installer/factory_reset.sh for supported fields.
    """
    answer = UserInput.YesNo(
        'Enable (y) or disable (n) qrcode when factory reset?')
    self.lsb.SetValue('DISPLAY_QRCODE', 'true' if answer else 'false')
    if answer:
      display_info = UserInput.GetString(
          'Enter the fields needed to display. The fields separated by space '
          'will be in the same QR code, the fields separated by comma will be '
          'in the different QR code', optional=True)
      self.lsb.SetValue('DISPLAY_INFO', display_info)

  def DoMenu(self, *args, **kargs):
    while True:
      Shell(['clear'])
      title = '\n'.join([
          ('Current LSB config:' if self.old_data == self.lsb.AsRawData() else
           'Current LSB config (modified):'),
          SPLIT_LINE,
          self.lsb.AsRawData(),
          SPLIT_LINE])
      options_list = [arg.__doc__.splitlines()[0] for arg in args]
      options_dict = {
          k: v.__doc__.splitlines()[0] for k, v in kargs.items()}

      selected = UserInput.Select(title, options_list, options_dict)

      if isinstance(selected, int):
        func = args[selected]
      else:
        func = kargs.get(selected)

      if func():
        return

  def Run(self):
    if self.args.board is None:
      self.args.board = _GetBoardName(self.args.image)

    with CrosPayloadUtils.TempPayloadsDir() as temp_dir:
      CrosPayloadUtils.CopyComponentsInImage(
          self.args.image, self.args.board, [PAYLOAD_TYPE_LSB_FACTORY],
          temp_dir, create_metadata=True)
      json_path = CrosPayloadUtils.GetJSONPath(temp_dir, self.args.board)

      with tempfile.NamedTemporaryFile('w') as lsb_file:
        # variables for legacy lsb-factory
        legacy_lsb = False
        stateful_part = Partition(self.args.image, PART_CROS_STATEFUL)

        try:
          CrosPayloadUtils.InstallComponents(
              json_path, lsb_file.name, PAYLOAD_TYPE_LSB_FACTORY,
              silent=True)
        except Exception:
          warning_message = [
              SPLIT_LINE,
              'This is a reset shim, or an old RMA shim without lsb_factory '
              'payload.', f'This command will modify {PATH_LSB_FACTORY} file.',
              SPLIT_LINE, 'Continue?'
          ]
          if not UserInput.YesNo('\n'.join(warning_message)):
            return
          legacy_lsb = True
          with stateful_part.Mount() as stateful:
            lsb_path = os.path.join(stateful, PATH_LSB_FACTORY)
            Shell(['cp', '-pf', lsb_path, lsb_file.name])

        self.lsb = LSBFile(lsb_file.name)
        self.old_data = self.lsb.AsRawData()

        def Write():
          """Apply changes and exit."""
          if self.old_data != self.lsb.AsRawData():
            SysUtils.WriteFile(lsb_file, self.lsb.AsRawData() + '\n')
            if legacy_lsb:
              with stateful_part.Mount(rw=True) as stateful:
                lsb_path = os.path.join(stateful, PATH_LSB_FACTORY)
                Sudo(['cp', '-pf', lsb_file.name, lsb_path])
                Sudo(['chown', 'root:root', lsb_path])
            else:
              CrosPayloadUtils.ReplaceComponent(
                  json_path, PAYLOAD_TYPE_LSB_FACTORY, lsb_file.name)
              CrosPayloadUtils.ReplaceComponentsInImage(
                  self.args.image, self.args.board, temp_dir)
            print('DONE. All changes saved properly.')
          else:
            print('QUIT. No modifications.')
          return True

        def Quit():
          """Quit without saving changes."""
          print('QUIT. No changes were applied.')
          return True

        self.DoMenu(self.EditBoard, self.EditServerAddress,
                    self.EditDefaultAction, self.EditActionCountdown,
                    self.EditCompletePrompt, self.EditRMAAutorun,
                    self.EditCutoff, self.EditDisplayQrcode, w=Write, q=Quit)


class EditToolkitConfigCommand(SubCommand):
  """Edit toolkit config payload for factory_install image or RMA shim."""
  name = 'edit_toolkit_config'

  toolkit_config = None
  old_toolkit_config = None
  config_wip = None

  def Init(self):
    self.subparser.add_argument('-i', '--image', type=ArgTypes.ExistsPath,
                                required=True,
                                help='Path to the factory_install image.')
    self.subparser.add_argument(
        '--board', type=str, default=None,
        help='Board to edit lsb file.')

  def Update(self, key, value):
    self.config_wip.update({key: value})

  def DeleteKey(self, key):
    self.config_wip.pop(key, None)

  def _DoUpdate(self):
    types = ['string', 'integer', 'boolean']
    key = UserInput.GetString('Enter a key to add/update')
    value_type = UserInput.Select(f'Type of value for key "{key}"', types)
    if value_type == 0:
      value = UserInput.GetString(f'Enter a string value for key "{key}"')
    elif value_type == 1:
      value = UserInput.GetNumber(f'Enter an integer value for key "{key}"')
    else:
      value = UserInput.YesNo(f'Select True(y) or False(n) for key "{key}"')
    self.Update(key, value)

  def _DoDeleteKey(self):
    key = UserInput.GetString('Enter a key to delete')
    self.DeleteKey(key)

  def _DoString(self, title, key, optional=False):
    value = UserInput.GetString(title, optional=optional) or ""
    self.Update(key, value)

  def _DoURL(self, title, keys, default_port=8080, suffix=''):
    host = UserInput.GetString(f'{title} host', optional=True)
    if not host:
      return
    port = UserInput.GetString(f'Enter port (default={default_port})',
                               optional=True)
    if not port:
      port = str(default_port)
    url = f'http://{host}:{port}{suffix}'
    for key in keys:
      self.Update(key, url)

  def _DoOptions(self, title, key, options):
    selected = UserInput.Select(f'{title} ({key})', options)
    value = options[selected]
    self.Update(key, value)
    return value

  def _DoOptionalNumber(self, title, key, min_value, max_value):
    selected = UserInput.GetNumber(f'{title} ({key})', min_value=min_value,
                                   max_value=max_value, optional=True)
    if selected is not None:
      self.Update(key, selected)
    else:
      self.DeleteKey(key)
    return selected

  def EditActiveTestList(self):
    """Modify active test list."""
    subconfig_key = TOOLKIT_SUBCONFIG_ACTIVE_TEST_LIST
    self.config_wip = self.toolkit_config.get(subconfig_key, {}).copy()
    self._DoString('Enter active test list id (e.g. main)', 'id', optional=True)
    self.toolkit_config[subconfig_key] = self.config_wip

  def EditTestListConstants(self):
    """Modify test list constants."""
    subconfig_key = TOOLKIT_SUBCONFIG_TEST_LIST_CONSTANTS
    self.config_wip = self.toolkit_config.get(subconfig_key, {}).copy()
    options_list = ['Add/edit key', 'Delete key']
    options_dict = {
        'q': 'Return to menu without saving changes',
        'w': 'Save changes and return to menu'
    }
    while True:
      Shell(['clear'])
      title = '\n'.join([
          'Test list constants:', SPLIT_LINE,
          json.dumps(self.config_wip, indent=2), SPLIT_LINE
      ])
      option = UserInput.Select(title, options_list, options_dict)
      if option == 0:
        self._DoUpdate()
      elif option == 1:
        self._DoDeleteKey()
      elif option == 'q':
        break
      else:
        # option == 'w'.
        self.toolkit_config[subconfig_key] = self.config_wip
        break

  def EditCutoff(self):
    """Modify cutoff config.

    All options are defined in src/platform/factory/sh/cutoff/options.sh
    """
    subconfig_key = TOOLKIT_SUBCONFIG_CUTOFF
    self.config_wip = {}
    self._DoOptions(
        'Select cutoff method', 'CUTOFF_METHOD',
        ['shutdown', 'reboot', 'battery_cutoff', 'ectool_cutoff',
         'ec_hibernate'])
    self._DoOptions(
        'Select cutoff AC state', 'CUTOFF_AC_STATE',
        ['none', 'remove_ac', 'connect_ac'])
    answer = self._DoOptionalNumber(
        'Minimum allowed battery percentage', 'CUTOFF_BATTERY_MIN_PERCENTAGE',
        0, 100)
    self._DoOptionalNumber(
        'Maximum allowed battery percentage', 'CUTOFF_BATTERY_MAX_PERCENTAGE',
        answer or 0, 100)
    answer = self._DoOptionalNumber(
        'Minimum allowed battery voltage (mA)', 'CUTOFF_BATTERY_MIN_VOLTAGE',
        None, None)
    self._DoOptionalNumber(
        'Maximum allowed battery voltage (mA)', 'CUTOFF_BATTERY_MAX_VOLTAGE',
        answer, None)
    self._DoURL(
        'Chrome OS Factory Server or Shopfloor Service for OQC ReFinalize',
        ['SHOPFLOOR_URL'])
    self.toolkit_config[subconfig_key] = self.config_wip

  def EditContinueKey(self):
    """Enable or disable a confirmation before battery cutoff."""
    key = UserInput.GetString(
        'Enter the key needed to be pressed to continue the cutoff process, '
        'the characters should be pressed in order.', optional=True)
    self.toolkit_config[TOOLKIT_SUBCONFIG_CUTOFF]['CONTINUE_KEY'] = key

  def EditQrcodeInfo(self):
    """Enable or disable qrcode right before cutoff.

    This can be used as a confirmation that the whole process has been done.
    Check src/platform/factory_installer/factory_reset.sh for supported fields.
    """
    display_info = UserInput.GetString(
        'Enter the fields needed to display. The fields separated by space '
        'will be in the same QR code, the fields separated by comma will be '
        'in the different QR code', optional=True)
    self.toolkit_config[TOOLKIT_SUBCONFIG_CUTOFF]['QRCODE_INFO'] = display_info

  def DoMenu(self, *args, **kargs):
    while True:
      Shell(['clear'])
      title = '\n'.join([
          ('Toolkit config:' if self.old_toolkit_config == self.toolkit_config
           else 'Toolkit config (modified):'),
          SPLIT_LINE,
          json.dumps(self.toolkit_config, indent=2),
          SPLIT_LINE])

      options_list = [arg.__doc__.splitlines()[0] for arg in args]
      options_dict = {
          k: v.__doc__.splitlines()[0] for k, v in kargs.items()}

      selected = UserInput.Select(title, options_list, options_dict)

      if isinstance(selected, int):
        func = args[selected]
      else:
        func = kargs.get(selected)

      if func():
        return

  def GetRootfsCutoffConfig(self):
    # Get the shim cutoff config in rootfs.
    with Partition(self.args.image, PART_CROS_ROOTFS_A).Mount() as rootfs:
      try:
        cutoff_config_path = os.path.join(
            rootfs, 'usr', 'share', 'cutoff', 'cutoff.json')
        with open(cutoff_config_path, encoding='utf8') as f:
          cutoff_config = json.load(f)
      except Exception:
        cutoff_config = {}
    return cutoff_config

  def Run(self):

    if self.args.board is None:
      self.args.board = _GetBoardName(self.args.image)

    # Modify toolkit config in cros_payload.
    with CrosPayloadUtils.TempPayloadsDir() as temp_dir:
      CrosPayloadUtils.CopyComponentsInImage(
          self.args.image, self.args.board, [PAYLOAD_TYPE_TOOLKIT_CONFIG],
          temp_dir, create_metadata=True)
      json_path = CrosPayloadUtils.GetJSONPath(temp_dir, self.args.board)
      with tempfile.NamedTemporaryFile('r+') as config_file:
        try:
          CrosPayloadUtils.InstallComponents(
              json_path, config_file.name, PAYLOAD_TYPE_TOOLKIT_CONFIG,
              silent=True)
          self.toolkit_config = json.load(config_file)
        except Exception:
          # It is possible that the RMA shim doesn't have this payload.
          self.toolkit_config = {}

        self.old_toolkit_config = copy.deepcopy(self.toolkit_config)
        # If toolkit config doesn't contain cutoff subconfig, copy from
        # cutoff/cutoff.json.
        if TOOLKIT_SUBCONFIG_CUTOFF not in self.toolkit_config:
          cutoff_config = self.GetRootfsCutoffConfig()
          self.toolkit_config[TOOLKIT_SUBCONFIG_CUTOFF] = cutoff_config

        def Write():
          """Apply changes and exit."""
          if self.old_toolkit_config != self.toolkit_config:
            SysUtils.WriteFile(
                config_file,
                json.dumps(self.toolkit_config,
                           indent=2,
                           separators=(',', ': ')))
            CrosPayloadUtils.ReplaceComponent(
                json_path, PAYLOAD_TYPE_TOOLKIT_CONFIG, config_file.name)
            CrosPayloadUtils.ReplaceComponentsInImage(
                self.args.image, self.args.board, temp_dir)
            print('DONE. All changes saved properly.')
          else:
            print('QUIT. No modifications.')
          return True

        def Quit():
          """Quit without saving changes."""
          print('QUIT. No changes were applied.')
          return True

        self.DoMenu(self.EditActiveTestList, self.EditTestListConstants,
                    self.EditCutoff, self.EditContinueKey, self.EditQrcodeInfo,
                    w=Write, q=Quit)


def main():
  # Support `cros_payload` in bin/ folder, so that we can run
  # `py/tools/image_tool.py` directly.
  new_path = os.path.realpath(os.path.join(
      os.path.dirname(os.path.realpath(__file__)), '..', '..', 'bin'))
  os.putenv('PATH', ':'.join(os.getenv('PATH', '').split(':') + [new_path]))
  sys.path.append(new_path)

  parser = argparse.ArgumentParser(
      prog='image_tool',
      description=(
          'Tools to manipulate Chromium OS disk images for factory. '
          'Use "image_tool help COMMAND" for more info on a '
          'subcommand.'))
  parser.add_argument('--verbose', '-v', action='count', default=0,
                      help='Verbose output')
  subparsers = parser.add_subparsers(title='subcommands', dest='subcommand')
  subparsers.required = True

  verb = sys.argv[1] if (len(sys.argv) > 1) else None
  selected_command_args = None

  subcommands = [
      v for unused_key, v in sorted(globals().items()) if inspect.isclass(v) and
      v not in [SubCommand, SubCommandNamespace] and issubclass(v, SubCommand)]
  # Add namespace.
  for v in subcommands:
    if issubclass(v, SubCommandNamespace):
      v(parser, subparsers).Init()
  # Add commands.
  for v in subcommands:
    if not issubclass(v, SubCommandNamespace):
      if v.namespace:
        p = subparsers.choices.get(v.namespace)
        subcommand = v(p, GetSubparsers(p))
        subcommand_args = [v.namespace, subcommand.name]
      else:
        subcommand = v(parser, subparsers)
        subcommand_args = [subcommand.name]
      subcommand.Init()
      if verb in subcommand.aliases:
        selected_command_args = subcommand_args

  if selected_command_args:
    args = parser.parse_args(selected_command_args + sys.argv[2:])
  else:
    args = parser.parse_args()
  logging.basicConfig(level=logging.WARNING - args.verbose * 10)

  args.subcommand.args = args
  args.subcommand.Run()


if __name__ == '__main__':
  main()
