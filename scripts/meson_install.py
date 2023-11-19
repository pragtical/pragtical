#
# Script for meson.add_install_script() to clean and place installed
# subproject files into non-conflicting directories.
#
# Note: I have never done any python so this script may suck :P
#

import os
import shutil
import platform

DESTDIR = os.getenv("DESTDIR")
MESON_INSTALL_PREFIX = os.getenv("MESON_INSTALL_PREFIX")
MESON_INSTALL_DESTDIR_PREFIX = os.getenv("MESON_INSTALL_DESTDIR_PREFIX")
MESON_SOURCE_ROOT = os.getenv("MESON_SOURCE_ROOT")
LUA_SUBPROJECT = MESON_SOURCE_ROOT + "/subprojects/lua-5.4.6"
UCHARDET_SUBPROJECT = MESON_SOURCE_ROOT + "/subprojects/uchardet-0.0.8"

pragtical_bin = 'pragtical'
if platform.system() == "Windows":
  pragtical_bin = 'pragtical.exe'
  if os.getenv("MSYSTEM") == None:
    DESTDIR = DESTDIR.replace("/", "\\")
    MESON_INSTALL_PREFIX = MESON_INSTALL_PREFIX.replace("/", "\\")

def move_files(src_dir, dest_dir, exclude_list):
  for item in os.listdir(src_dir):
    src_item = os.path.join(src_dir, item)
    # Skip items in the exclude list
    if item in exclude_list:
      continue
    dest_item = os.path.join(dest_dir, item)
    if os.path.isdir(src_item):
      # Recursively move directories
      if os.path.exists(dest_item):
        shutil.rmtree(dest_item)
      shutil.move(src_item, dest_item)
    else:
      # Move files
      if os.path.exists(dest_dir + "/" + os.path.basename(src_item)):
        os.remove(dest_dir + "/" + os.path.basename(src_item))
      shutil.move(src_item, dest_dir)

def move_subprojects(strategy, headers_path, clean_prefix):
  print("STRATEGY: " + strategy)
  if os.path.exists(MESON_INSTALL_DESTDIR_PREFIX + '/include'):
    if not os.path.exists(headers_path):
      os.mkdir(headers_path)
    move_files(
      MESON_INSTALL_DESTDIR_PREFIX + "/include",
      headers_path,
      []
    )
  if os.path.exists(MESON_INSTALL_DESTDIR_PREFIX + "/include"):
    shutil.rmtree(MESON_INSTALL_DESTDIR_PREFIX + "/include")
  if os.path.exists(MESON_INSTALL_DESTDIR_PREFIX + "/lib"):
    shutil.rmtree(MESON_INSTALL_DESTDIR_PREFIX + "/lib")
  if clean_prefix:
    prefix = MESON_INSTALL_PREFIX
    if os.getenv('MSYSTEM') != None:
      prefix = MESON_INSTALL_DESTDIR_PREFIX.replace(DESTDIR, "")
    for path in prefix.lstrip(os.path.sep).split(os.path.sep):
      shutil.rmtree(DESTDIR + "/" + path)
      break

headers_path = ""

if DESTDIR and DESTDIR != "":
  print("")
  print("====================================================")
  print("Executing Custom Install Script")
  print("====================================================")
  print("DESTDIR: " + DESTDIR)
  print("MESON_INSTALL_PREFIX: " + MESON_INSTALL_PREFIX)
  print("MESON_INSTALL_DESTDIR_PREFIX: " + MESON_INSTALL_DESTDIR_PREFIX)
  print("MESON_SOURCE_ROOT: ", MESON_SOURCE_ROOT)
  print("PRAGTICAL_BIN: " + pragtical_bin)

  # Portable installs where prefix not /
  if (
    os.path.exists(DESTDIR + "/" + pragtical_bin)
    and
    DESTDIR != MESON_INSTALL_DESTDIR_PREFIX
  ):
    headers_path = DESTDIR + '/include/pragtical/third_party'
    move_subprojects("portable", headers_path, True)

  # MacOS bundle
  elif os.path.exists(MESON_INSTALL_DESTDIR_PREFIX + '/Contents/MacOS'):
    headers_path = DESTDIR + '/Contents/Resources/include/pragtical/third_party'
    move_subprojects("bundle", headers_path, False)

  # Posix installs?
  else:
    print("STRATEGY: posix")

    headers_path = MESON_INSTALL_DESTDIR_PREFIX + '/include/pragtical/third_party'

    if os.path.exists(MESON_INSTALL_DESTDIR_PREFIX + '/include/pragtical'):
      if not os.path.exists(headers_path):
        os.mkdir(headers_path)

      move_files(
        MESON_INSTALL_DESTDIR_PREFIX + '/include',
        headers_path,
        ['pragtical']
      )

    if os.path.exists(MESON_INSTALL_DESTDIR_PREFIX + '/lib'):
      os.mkdir(MESON_INSTALL_DESTDIR_PREFIX + '/libs_to_remove')

      move_files(
        MESON_INSTALL_DESTDIR_PREFIX + '/lib',
        MESON_INSTALL_DESTDIR_PREFIX + '/libs_to_remove',
        ['libpragtical.so', 'libpragtical.dll', 'libpragtical.dylib', 'pkgconfig']
      )

      if os.path.exists(MESON_INSTALL_DESTDIR_PREFIX + '/lib/pkgconfig'):
        move_files(
          MESON_INSTALL_DESTDIR_PREFIX + '/lib/pkgconfig',
          MESON_INSTALL_DESTDIR_PREFIX + '/libs_to_remove',
          ['pragtical.pc']
        )

      shutil.rmtree(MESON_INSTALL_DESTDIR_PREFIX + '/libs_to_remove')

      lib_exists = False
      for lib in ['libpragtical.so', 'libpragtical.dll', 'libpragtical.dylib']:
        if os.path.exists(MESON_INSTALL_DESTDIR_PREFIX + '/lib/' + lib):
          lib_exists = True
          break

      if not lib_exists:
        shutil.rmtree(MESON_INSTALL_DESTDIR_PREFIX + '/lib')

  # Install uchardet header file
  if os.path.exists(UCHARDET_SUBPROJECT):
    if not os.path.exists(headers_path):
      os.makedirs(headers_path)
    shutil.copy(UCHARDET_SUBPROJECT + "/src/uchardet.h", headers_path)

  # Install PUA Lua heders if no Lua headers found
  if (
    os.path.exists(LUA_SUBPROJECT)
    and
    not os.path.exists(headers_path + "/lua.h")
  ):
    shutil.copy(LUA_SUBPROJECT + "/src/lauxlib.h", headers_path)
    shutil.copy(LUA_SUBPROJECT + "/src/lua.h", headers_path)
    shutil.copy(LUA_SUBPROJECT + "/src/lua.hpp", headers_path)
    shutil.copy(LUA_SUBPROJECT + "/src/luaconf.h", headers_path)
    shutil.copy(LUA_SUBPROJECT + "/src/lualib.h", headers_path)

  # Move windows console executable since meson name_suffix doesn't works
  # because of supposedly duplicated exeuctable targets...
  if os.path.exists(DESTDIR + "/pragtical-cli.exe"):
    shutil.move(DESTDIR + "/pragtical-cli.exe", DESTDIR + "/pragtical.com")
  elif os.path.exists(MESON_INSTALL_DESTDIR_PREFIX + "/pragtical-cli.exe"):
    shutil.move(
      MESON_INSTALL_DESTDIR_PREFIX + "/pragtical-cli.exe",
      MESON_INSTALL_DESTDIR_PREFIX + "/pragtical.com"
    )

  # Adjust rpath for macOS
  if platform.system() == "Darwin":
    if os.path.exists(MESON_INSTALL_DESTDIR_PREFIX + '/Contents/MacOS'):
      os.system(
        "install_name_tool "
        + '"-change" '
        + '"/Contents/Frameworks/libpragtical.dylib" '
        + '"@executable_path/../Frameworks/libpragtical.dylib" '
        + '"' + MESON_INSTALL_DESTDIR_PREFIX + '/Contents/MacOS/pragtical"'
      )

    elif os.path.exists(MESON_INSTALL_DESTDIR_PREFIX + '/pragtical'):
      os.system(
        "install_name_tool "
        + '"-change" '
        + '"/libpragtical.dylib" '
        + '"@executable_path/libpragtical.dylib" '
        + '"' + MESON_INSTALL_DESTDIR_PREFIX + '/pragtical"'
      )

  print("====================================================")
