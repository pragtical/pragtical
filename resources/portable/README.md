# Portable User Directory

This directory holds all your user settings. Since the directory is alongside
the editor's executable, it allows the installation to be truly portable. If
this isn't required or desired you can remove or move this directory to the
global config path of your operating system. The global config directory can be:

* `$XDG_CONFIG_HOME/pragtical` - Linux or any OS that follows the XDG specification
* `$HOME/.config/pragtical` - Any Unix based system (macOS, FreeBSD, etc...)
* `$USERPROFILE/.config/pragtical` - Windows
