# Pragtical

The practical and pragmatic code editor.

[website] | [documentation] | [download]

[![Build Rolling]](https://github.com/pragtical/pragtical/actions/workflows/rolling.yml)
[![Discord]](https://discord.gg/jAAqT7eYEN)

![screenshot](https://pragtical.github.io/assets/img/editor.png)

## Download

* **[Get Pragtical]** — Download Pre-built releases for Windows, Linux and Mac OS.
* **[Get Plugins]** — Add additional functionality.
* **[Get Color Themes]** — Additional color themes (bundled with all releases
of Pragtical by default).

A list of changes is registered on the [changelog] file. Please refer to our
[website] for the user and developer [documentation], including more detailed
[build] instructions.

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

Pull requests to improve or modify the editor itself are welcome.

Additional functionality can be added through a plugin by sending a
pull request to the [plugins repository]. If you think the functionality should
be added to the core editor open an issue so we can discuss it.

## Licenses

This project is free software; you can redistribute it and/or modify it under
the terms of the MIT license. See [LICENSE] for details.

See the [licenses] directory for details on licenses used by the required dependencies.


[Build Rolling]:      https://github.com/pragtical/pragtical/actions/workflows/rolling.yml/badge.svg
[Discord]:            https://discord.com/api/guilds/1285023036071743542/widget.png?style=shield
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
