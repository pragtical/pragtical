# Resources

This folder contains resources that is used for building or packaging the project.

### Build

- `cross/*.txt`: Meson [cross files][1] for cross-compiling pragtical on other platforms.

### Packaging

- `icons/icon.{icns,ico,inl,rc,svg}`: pragtical icon in various formats.
- `linux/dev.pragtical.Pragtical.appdata.xml`: AppStream metadata.
- `linux/dev.pragtical.Pragtical.desktop`: Desktop file for Linux desktops.
- `macos/appdmg.png`: Background image for packaging MacOS DMGs.
- `macos/Info.plist.in`: Template for generating `info.plist` on MacOS. See `macos/macos-retina-display.md` for details.
- `windows/001-lua-unicode.diff`: Patch for allowing Lua to load files with UTF-8 filenames on Windows.
- `portable/README.md`: Copied to the `user` directory of portable builds.

### Development

- `include/pragtical_plugin_api.h`: Native plugin API header. See the contents
of `pragtical_plugin_api.h` for more details. (TODO: to be dropped in favor of
dynamic linking)

### Other Files

- `shell.html`: A shell file for use with WASM builds.


[1]: https://mesonbuild.com/Cross-compilation.html
