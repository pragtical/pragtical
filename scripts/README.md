# Scripts

Various scripts and configurations used to configure, build, and package Pragtical.

### Build

- **build.sh**
- **build-windows.ps1**: Native x64 MSVC build, tests, ZIP, and Inno Setup installer.
- **build-packages.sh**: In root directory, as all in one script; relies to the
  ones in this directory.

For a native Windows build, use PowerShell 7.3 or newer in an x64 MSVC developer
environment (VS 2022). Install Git, Python, CMake, and Inno Setup 6, then run
from the repository root:

```powershell
python -m pip install 'meson>=1.12' ninja
meson setup build --wrap-mode=forcefallback -Dppm=false -Db_vscrt=mt
meson compile -C build
```

Meson requires libiconv for MSVC and builds the bundled GNU implementation
when fallbacks are enabled and needed. `--wrap-mode=forcefallback` selects
the subproject even if a system copy is available. For native MSVC builds,
keep `-Dppm=false`: PPM's sources require POSIX headers. To compile PPM
with `-Dppm=true` on Windows, use an MSYS2 environment such as UCRT64
with the MinGW-w64 toolchain.

To also test and package the editor, run
`./scripts/build-windows.ps1 -Configuration pr -Version dev`. Use
`-Configuration rolling` or `release` for LTO and PGO builds. The script
runs the Lua suite and native plugin checks, bundles the pinned PPM executable,
and writes a portable ZIP and installer to `artifacts/windows/`. Add
`-TestInstaller` to also install, check, and uninstall a temporary copy.
MSYS2 and the Visual C++ redistributable are not needed for these packages;
the editor and its compiled dependencies use the static MSVC runtime.

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
- **fontello-config.json**:    [Fontello][4] project for `data/fonts/icons.ttf`.
- **generate_header.sh**: Generates a header file for native plugin API
- **keymap-generator**: Generates a JSON file containing the keymap

To update the icon font, import `fontello-config.json` into Fontello, add the
required icons without changing existing character codes, and download the
font archive. Save its `font/icons.ttf` to `data/fonts/icons.ttf` and keep the
updated `config.json` as `scripts/fontello-config.json`.

[1]: https://github.com/LinusU/node-appdmg
[2]: https://docs.appimage.org/
[3]: https://jrsoftware.org/isinfo.php
[4]: https://fontello.com/
