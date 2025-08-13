#!/bin/bash
set -ex

if [ ! -e "src/api/api.h" ]; then
  echo "Please run this script from the root directory of Pragtical."; exit 1
fi

show_help() {
  echo
  echo "Pragtical dependecies installer. Mainly used for CI but can also work on users systems."
  echo "USE IT AT YOUR OWN RISK!"
  echo
  echo "Usage: $0 <OPTIONS>"
  echo
  echo "Available options:"
  echo
  echo "   --debug                Debug this script."
  echo
}

main() {
  for i in "$@"; do
    case $i in
      --debug)
        set -x
        shift
        ;;
      *)
        # unknown option
        ;;
    esac
  done

  if [[ -n $1 ]]; then
    show_help
    exit 1
  fi

  if [[ "$OSTYPE" == "linux"* ]]; then
    sudo apt-get install -qq libfuse2 ninja-build wayland-protocols libsdl2-dev libfreetype6 llvm-14
    pip3 install meson
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    brew install bash ninja sdl2 coreutils # coreutils for grealpath
    pip3 install meson
    cd ~; npm install appdmg; cd -
    ~/node_modules/appdmg/bin/appdmg.js --version
  elif [[ "$OSTYPE" == "msys" ]]; then
    pacman --noconfirm -S \
      ${MINGW_PACKAGE_PREFIX}-{ca-certificates,gcc,python-pip,ninja,cmake,ntldd,pkg-config,mesa,freetype,pcre2,sdl3} unzip
    python -m ensurepip
    pip3 install meson
  fi
}

main "$@"
