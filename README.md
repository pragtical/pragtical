# Pragtical

The practical and pragmatic code editor.

[![Build Latest]](https://github.com/pragtical/pragtical/actions/workflows/latest.yml)

![screenshot](https://pragtical.github.io/assets/img/editor.png)

Pragtical is a code editor which was forked from [Lite XL] (also a fork of [lite])
written mostly in **Lua** with a focus on been practical rather than minimalist.
The name of the editor is a mixture of the words `pragmatic` and `practical`,
two words that properly define our development approach as follows:

* governed through practice or action, rather than theory, speculation or idealism
* willing to see things as they really are and deal with them sensibly

As a result we belief that new features introduced through pull requests should
be evaluated taking a practical approach, without going into lenghty idealistic
discussions that slowdown progress, merging code when logical.

## Goals

We differentiate from our ancestors by striving to make Pragtical an editor
that has amplified the set of features, to give you and us a better out of the
box experience, while keeping an eye on performance and ease of extensibility.
Also, we are simplifying the release process by reducing the amount of builds
to choose from and trying a release often approach.

### Performance

* **JIT** - Pragtical takes a LuaJIT first approach, meaning that our official
builds use LuaJIT instead of PUC Lua for the performance benefits that come
with it. Also having a LuaJIT first approach gives us FFI for free which allows
easy interfacing with native C libraries for easier plugin development. LuaJIT
has proven to be a mature Lua implementation that will provide a stable
development ecosystem for the foreseeable future.

* **Threading** - a supported feature inside the core on components where it is
practical to use, like file searching and replacing, where performance gains are
evident.

### More Features

* **Widgets** - more tightly integrated as part of the core for easier gui
development and reusability, also ensuring that plugin developers can with
more ease develop user interfaces when in need.

* **Settings UI** - if you are not using a terminal editor like n/vim it means
you are looking for a more point and click approach which is why we include a
graphical interface to adjust your preferences out of the box. But don't
worry, configuring the editor through Lua will keep working because it is also
pragtical 😉

* **Encoding** - while UTF-8 has overtaken as the preferred encoding for text
documents for its convenience, we can sometimes encounter a document in another
encoding. Loading and saving documents with different encodings will be
supported for when the need arrives, a feature that is also commonly found in
other editors because it is pragtical.

* **IPC** - shared memory functionality is part of the core and IPC plugin
shipped by default to allow opening files and tab dragging between currently
opened instances.

## Download

* **[Get Pragtical]** — Download Pre-built releases for Windows, Linux and Mac OS.
* **[Get Plugins]** — Add additional functionality, adapted for Pragtical.
* **[Get Color Themes]** — Additional color themes (bundled with all releases
of Pragtical by default).

The changes and differences between Pragtical and rxi/lite are listed in the
[changelog].

Please refer to our [website] for the user and developer documentation,
including more detailed [build] instructions. A quick build guide is
described below.

## Quick Build Guide

First, clone this repository and initialize the widget submodule:

```sh
git clone https://github.com/pragtical/pragtical
git submodule update --init
```

If you compile Pragtical yourself, it is recommended to use the script
`build-packages.sh`:

```sh
bash build-packages.sh -h
```

The script will run Meson and create a tar compressed archive with the
application or, for Windows, a zip file. Pragtical can be easily installed
by unpacking the archive in any directory of your choice.

Otherwise the following is an example of basic commands if you want to customize
the build:

```sh
meson setup --buildtype=release --prefix <prefix> build
meson compile -C build
DESTDIR="$(pwd)/pragtical" meson install --skip-subprojects -C build
```

where `<prefix>` might be one of `/`, `/usr` or `/opt`, the default is `/`.
To build a bundle application on macOS:

```sh
meson setup --buildtype=release --Dbundle=true --prefix / build
meson compile -C build
DESTDIR="$(pwd)/Pragtical.app" meson install --skip-subprojects -C build
```

Please note that the package is relocatable to any prefix and the option prefix
affects only the place where the application is actually installed.

## Contributing

Feel free to contribute something that would be convenient and "Pragtical" to
include on the core, you are welcome to open a pull request and contribute.

Any additional functionality that can be added through a plugin should be done
as a plugin, after which a pull request to the [plugins repository]
can be made.

Pull requests to improve or modify the editor itself are welcome.

## Licenses

This project is free software; you can redistribute it and/or modify it under
the terms of the MIT license. See [LICENSE] for details.

See the [licenses] directory for details on licenses used by the required dependencies.


[Build Latest]:         https://github.com/pragtical/pragtical/actions/workflows/latest.yml/badge.svg
[Lite XL]:              https://github.com/lite-xl/lite-xl
[screenshot-dark]:      https://user-images.githubusercontent.com/433545/111063905-66943980-84b1-11eb-9040-3876f1133b20.png
[lite]:                 https://github.com/rxi/lite
[website]:              https://pragtical.github.io
[build]:                https://pragtical.github.io/documentation/build
[Get Pragtical]:        https://github.com/pragtical/pragtical/releases/latest
[Get Plugins]:          https://github.com/pragtical/plugins
[Get Color Themes]:     https://github.com/pragtical/colors
[plugins repository]:   https://github.com/pragtical/plugins
[changelog]:            https://github.com/pragtical/pragtical/blob/master/changelog.md
[LICENSE]:              LICENSE
[licenses]:             licenses/licenses.md
