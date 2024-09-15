# Pragtical

The practical and pragmatic code editor.

[website] | [documentation] | [download]

[![Build Rolling]](https://github.com/pragtical/pragtical/actions/workflows/rolling.yml)
[![Discord]](https://discord.gg/RC9ZHY8y)

![screenshot](https://pragtical.github.io/assets/img/editor.png)

Pragtical is a code editor which was forked from [Lite XL] (also a fork of [lite])
written mostly in **Lua** with a focus on being practical rather than minimalist.

The name of the editor is a mixture of the words `pragmatic` and `practical`,
two words that properly define our development approach as follows:

* Government through practice and action rather than theory and speculation.
* Willingness to see the context of actual use cases and not only idealistic ideals.

As a result [we believe] that new features introduced through pull requests should
be evaluated by taking a practical approach, without going into lengthy idealistic
discussions that slow down progress, merging code when logical.

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

1. Clone this repository

```sh
git clone https://github.com/pragtical/pragtical
```

2. Setup and compile the project

```sh
meson setup --wrap-mode=forcefallback -Dportable=true build
meson compile -C build
```

> [!NOTE]
> We set `--wrap-mode` to forcefallback to download and build all the dependencies
> which will take longer. If you have all dependencies installed on your system
> you can skip this flag. Also notice we set the `portable` flag to true, this
> way the install process will generate a directory structure that is easily
> relocatable.

3. Install and profit!

```sh
meson install -C build --destdir ../pragtical
```

You will now see a new directory called `pragtical` that will contain the
executable and all the necessary files to run the editor. Feel free to move or
rename this directory however you wish.

For more detailed instructions visit: https://pragtical.dev/docs/setup/building

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


[Build Rolling]:      https://github.com/pragtical/pragtical/actions/workflows/rolling.yml/badge.svg
[Discord]:            https://discord.com/api/guilds/1285023036071743542/widget.png?style=shield
[Lite XL]:            https://github.com/lite-xl/lite-xl
[screenshot-dark]:    https://user-images.githubusercontent.com/433545/111063905-66943980-84b1-11eb-9040-3876f1133b20.png
[lite]:               https://github.com/rxi/lite
[website]:            https://pragtical.dev
[documentation]:      https://pragtical.dev/docs/intro
[download]:           https://github.com/pragtical/pragtical/releases
[build]:              https://pragtical.dev/docs/setup/building
[Get Pragtical]:      https://github.com/pragtical/pragtical/releases
[Get Plugins]:        https://github.com/pragtical/plugins
[Get Color Themes]:   https://github.com/pragtical/colors
[plugins repository]: https://github.com/pragtical/plugins
[changelog]:          https://github.com/pragtical/pragtical/blob/master/changelog.md
[LICENSE]:            LICENSE
[licenses]:           licenses/licenses.md
[we believe]:         https://github.com/pragtical/pragtical/issues/6#issuecomment-1581650875
