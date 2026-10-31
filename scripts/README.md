# Scripts

Various scripts and configurations used to configure, build, and package Pragtical.

### Build

- **build.sh**
- **build-packages.sh**: In root directory, as all in one script; relies to the
  ones in this directory.

Windows MinGW builds use the MSYS2 **UCRT64** shell and
`mingw-w64-ucrt-x86_64-*` packages, matching the PR, rolling, and release jobs.
MSYS2 is [deprecating MINGW64][4]. Build from a fresh build directory when
switching toolchains; do not mix MINGW64 libraries with UCRT64 libraries.
`scripts/build.sh` already recreates its build directory. The dependency
installer uses the current shell's `MINGW_PACKAGE_PREFIX` automatically.
MSVC builds and the Linux MinGW cross-toolchain are unchanged.

### Package

- **appdmg.sh**:    Create a macOS DMG image using [AppDMG][1].
- **appimage.sh**:  [AppImage][2] builder.
- **innosetup.sh**: Creates a 32/64 bit [InnoSetup][3] installer package.
- **package.sh**:   Creates all binary / DMG image / installer / source packages.

### Utility

- **common.sh**:               Common functions used by other scripts.
- **install-dependencies.sh**: Installs required applications to build, package
  and run Pragtical, mainly useful for CI and documentation purpose.
  Preferably not to be used in user systems.
- **fontello-config.json**:    Used by the icons generator.
- **generate_header.sh**: Generates a header file for native plugin API
- **keymap-generator**: Generates a JSON file containing the keymap

[1]: https://github.com/LinusU/node-appdmg
[2]: https://docs.appimage.org/
[3]: https://jrsoftware.org/isinfo.php
[4]: https://www.msys2.org/news/#2026-03-15-deprecating-the-mingw64-environment
