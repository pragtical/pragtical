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

  # Plugins
  mkdir -p "${data_dir}/plugins"

  for plugin_name in open_ext; do
    cp -r "${build_dir}/third/data/plugins/${plugin_name}.lua" \
      "${data_dir}/plugins/"
  done
}

get_platform_name() {
  if [[ "$OSTYPE" == "msys" ]]; then
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
    if [[ $MSYSTEM == "MINGW64" ]]; then
      arch=x86_64
    else
      arch=i686
    fi
  fi
  echo "$arch"
}

get_default_build_dir() {
  platform="${1:-$(get_platform_name)}"
  arch="${2:-$(get_platform_arch)}"
  echo "build-$platform-$arch"
}

if [[ $(get_platform_name) == "UNSUPPORTED-OS" ]]; then
  echo "Error: unknown OS type: \"$OSTYPE\""
  exit 1
fi
