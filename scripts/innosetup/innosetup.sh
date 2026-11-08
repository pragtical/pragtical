#!/bin/bash
set -e

if [ ! -e "src/api/api.h" ]; then
  echo "Please run this script from the root directory of Pragtical."; exit 1
fi

source scripts/common.sh

show_help() {
  echo
  echo "Usage: $0 <OPTIONS>"
  echo
  echo "Available options:"
  echo
  echo "-b --builddir DIRNAME     Sets the name of the build directory (not path)."
  echo "                          Default: '$(get_default_build_dir)'."
  echo "-d --destdir DIRNAME      Sets the staged package directory. Default: 'pragtical'."
  echo "-v --version VERSION      Sets the version on the package name."
  echo "   --debug                Debug this script."
  echo
}

main() {
  local build_dir=$(get_default_build_dir)
  local dest_dir=pragtical
  local package_dir
  local output_dir
  local arch
  local arch_file
  local version
  local output

  case "$MSYSTEM" in
    MINGW64|UCRT64|CLANG64)
    arch=x64
    arch_file=x86_64
    ;;
    MINGW32|CLANG32)
    arch=x86
    arch_file=i686
    ;;
    CLANGARM64)
    arch=arm64
    arch_file=aarch64
    ;;
    *)
    echo "error: unsupported MSYSTEM type: $MSYSTEM"
    exit 1
    ;;
  esac

  initial_arg_count=$#

  for i in "$@"; do
    case $i in
      -h|--help)
        show_help
        exit 0
        ;;
      -b|--builddir)
        build_dir="$2"
        shift
        shift
        ;;
      -v|--version)
        if [[ -n $2 ]]; then version="-$2"; fi
        shift
        shift
        ;;
      -d|--destdir)
        dest_dir="$2"
        shift
        shift
        ;;
      --debug)
        set -x
        shift
        ;;
      *)
        # unknown option
        ;;
    esac
  done

  # show help if no valid argument was found
  if [ $initial_arg_count -eq $# ]; then
    show_help
    exit 1
  fi

  # The installer excludes staged user settings without altering the package.
  package_dir=$(cygpath -aw "$dest_dir")
  output_dir=$(cygpath -aw .)
  output="Pragtical${version}-${arch_file}-setup"
  "/c/Program Files (x86)/Inno Setup 6/ISCC.exe" \
    "-dArch=$arch" "-dPackageDir=$package_dir" "-O$output_dir" \
    "-F$output" "${build_dir}/scripts/innosetup.iss"
}

main "$@"
