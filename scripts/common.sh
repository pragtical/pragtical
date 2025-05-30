#!/bin/bash

set -e

addons_download() {
  local build_dir="$1"

  if [[ -d "${build_dir}/third/data/plugins" ]]; then
    echo "Warning: found previous addons installation, skipping."
    echo "  addons path: ${build_dir}/third/data/plugins"
    return 0
  fi

  mkdir -p "${build_dir}/third/data/plugins"

  # Downlaod thirdparty plugins
  curl --insecure \
    -L "https://github.com/pragtical/plugins/archive/master.zip" \
    -o "${build_dir}/plugins.zip"

  unzip "${build_dir}/plugins.zip" -d "${build_dir}"
  mv "${build_dir}/plugins-master/plugins" "${build_dir}/third/data"
  rm -rf "${build_dir}/plugins-master"
}

# Addons installation: some distributions forbid external downloads
# so make it as optional module.
addons_install() {
  local build_dir="$1"
  local data_dir="$2"

  # Disabled since pragtical can load binary files without crashing
  # Plugins
  # mkdir -p "${data_dir}/plugins"

  # for plugin_name in open_ext; do
  #   cp -r "${build_dir}/third/data/plugins/${plugin_name}.lua" \
  #     "${data_dir}/plugins/"
  # done
}

get_platform_name() {
  if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
    echo "windows"
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    echo "macos"
  elif [[ "$OSTYPE" == "linux"* || "$OSTYPE" == "freebsd"* ]]; then
    echo "linux"
  else
    echo "UNSUPPORTED-OS"
  fi
}

get_platform_arch() {
  platform=$(get_platform_name)
  arch=${CROSS_ARCH:-$(uname -m)}
  if [[ $MSYSTEM != "" ]]; then
    case "$MSYSTEM" in
      MINGW64|UCRT64|CLANG64)
      arch=x86_64
      ;;
      MINGW32|CLANG32)
      arch=i686
      ;;
      CLANGARM64)
      arch=aarch64
      ;;
    esac
  fi
  echo "$arch"
}

get_default_build_dir() {
  platform="${1:-$(get_platform_name)}"
  arch="${2:-$(get_platform_arch)}"
  echo "build-$platform-$arch"
}

polyfill_glibc() {
  local platform
  platform=$(get_platform_name)

  if [[ "$platform" != "linux" ]]; then
    return 0
  fi

  local arch
  arch=$(get_platform_arch)

  if [ ! -e "polyfill-glibc" ]; then
    if ! wget -O "polyfill-glibc" "https://github.com/pragtical/polyfill-glibc/releases/download/binaries/polyfill-glibc.${arch}" ; then
      echo "Could not download polyfill-glibc for the arch '${arch}'."
      exit 1
    else
      chmod 0755 "polyfill-glibc"
    fi
  fi

  local rename_symbols=""
  if [[ "$arch" == "aarch64" ]]; then
    local symbols="aarch_symbols_rename.txt"
    echo "__isoc23_strtol@GLIBC_2.38 strtol" > $symbols
    echo "__isoc23_strtoll@GLIBC_2.38 strtoll" >> $symbols
    echo "__isoc23_strtoul@GLIBC_2.38 strtoul" >> $symbols
    echo "__isoc23_strtoull@GLIBC_2.38 strtoull" >> $symbols
    rename_symbols="--rename-dynamic-symbols=${symbols}"
  fi

  local binary_path="$1"
  echo "======================================================================="
  echo "Polyfill GLIBC on: ${binary_path}"
  echo "======================================================================="
  ./polyfill-glibc --target-glibc=2.17 $rename_symbols "$binary_path"
}

if [[ $(get_platform_name) == "UNSUPPORTED-OS" ]]; then
  echo "Error: unknown OS type: \"$OSTYPE\""
  exit 1
fi
