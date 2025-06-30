#!/bin/env bash
set -e

if [ ! -e "src/api/api.h" ]; then
  echo "Please run this script from the root directory of Pragtical."
  exit 1
fi

source scripts/common.sh

show_help(){
  echo
  echo "Usage: $0 <OPTIONS>"
  echo
  echo "Available options:"
  echo
  echo "-h --help                Show this help and exits."
  echo "-b --builddir DIRNAME    Sets the name of the build dir (no path)."
  echo "                         Default: '$(get_default_build_dir)'."
  echo "   --debug               Debug this script."
  echo "-n --nobuild             Skips the build step, use existing files."
  echo "-s --static              Specify if building using static libraries."
  echo "-v --version VERSION     Specify a version, non whitespace separated string."
  echo "-a --addons              Install 3rd party addons."
  echo "-r --release             Compile in release mode."
  echo "--cross-arch ARCH        The architecture to package for."
  echo
}

setup_appimagetool() {
  local arch=$1
  if [ ! -e "appimagetool.$arch" ]; then
    if ! wget -O "appimagetool.$arch" "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${arch}.AppImage" ; then
      echo "Could not download the appimagetool for the arch '${arch}'."
      exit 1
    else
      chmod 0755 "appimagetool.$arch"
    fi
  fi
}

download_appimage_apprun() {
  local arch=$1
  if [ ! -e "AppRun.$arch" ]; then
    if ! wget -O "AppRun.$arch" "https://github.com/AppImage/AppImageKit/releases/download/continuous/AppRun-${arch}" ; then
      echo "Could not download AppRun for the arch '${arch}'."
      exit 1
    else
      chmod 0755 "AppRun.$arch"
    fi
  fi
}

download_appimage_runtime() {
  local arch=$1
  local file="runtime-${arch}"
  if [ ! -e "$file" ]; then
    if ! wget -O "$file" "https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-${arch}" ; then
      echo "Could not download AppImage Runtime for the arch '${arch}'."
      exit 1
    else
      chmod 0755 "$file"
    fi
  fi
}

download_plugin_manager() {
  local arch=$1
  local file="ppm.${arch}-linux"
  if [ ! -e "$file" ]; then
    if ! wget -O "$file" "https://github.com/pragtical/plugin-manager/releases/download/continuous/ppm.${arch}-linux" ; then
      echo "Could not download PPM for the arch '${arch}'."
      exit 1
    else
      chmod 0755 "$file"
    fi
  fi
}

main() {
  local arch="$(uname -m)"
  local native_arch=$arch
  local build_dir="$(get_default_build_dir)"
  local run_build=true
  local static_build=false
  local addons=false
  local build_type="debugoptimized"
  local version=""
  local appimagebin="./appimagetool.$arch"
  local ppm_file="ppm.${arch}-linux"
  local cross
  local cross_arch

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
      -a|--addons)
        addons=true
        shift
        ;;
      --debug)
        set -x
        shift
        ;;
      -n|--nobuild)
        run_build=false
        shift
        ;;
      -r|--release)
        build_type="release"
        shift
        ;;
      -s|--static)
        static_build=true
        shift
        ;;
      -v|--version)
        version="-$2"
        shift
        shift
        ;;
      --cross-arch)
        cross=true
        cross_arch="$2"
        shift
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

  # Setup cross build options
  cross="${cross:-$CROSS_ARCH}"
  if [[ -n "$cross" ]]; then
    arch="${cross_arch}"
    cross_file=("--cross-file" "resources/cross/linux-${arch}.txt")
    # check if required cross-compile tools installed
    if ! which "$arch-linux-gnu-gcc" > /dev/null; then
      echo "Cross-compiler for '$arch' not found, please install '$arch-linux-gnu-gcc'"
      exit 1
    fi
    # Instead of doing this we use the native appimage runtime file
    # if ! which "qemu-$arch" > /dev/null; then
    #   echo "QEMU launcher for '$arch' not found, please install 'qemu-$arch'"
    #   exit 1
    # fi
    # appimagebin="qemu-$arch -L /usr/$arch-linux-gnu ./appimagetool.$arch"
    ppm_file="ppm.${arch}-linux"
    # reload build_dir because platform and arch might change
    build_dir="$(get_default_build_dir "linux" "$arch")"
  fi

  # Setup appimage tools
  setup_appimagetool "$native_arch"
  download_appimage_apprun "$arch"
  download_appimage_runtime "$arch"

  # Download pre-compiled ppm binary
  download_plugin_manager "$arch"

  # Build
  if [[ $run_build == true ]]; then
    if [ -e build ]; then
      rm -rf build
    fi

    if [ -e "${build_dir}" ]; then
      rm -rf "${build_dir}"
    fi

    echo "Download meson subprojects..."
    meson subprojects download

    echo "Build pragtical..."
    if [[ $static_build == false ]]; then
      meson setup \
        --buildtype=$build_type \
        --prefix=/usr \
        -Dppm=false \
        "${cross_file[@]}" \
        "${build_dir}"
    else
      meson setup --wrap-mode=forcefallback \
        --buildtype=$build_type \
        --prefix=/usr \
        -Dppm=false \
         "${cross_file[@]}" \
        "${build_dir}"
    fi
    meson compile -C "${build_dir}"
  fi

  # Generate AppImage
  if [ -e Pragtical.AppDir ]; then
    rm -rf Pragtical.AppDir
  fi

  echo "Creating Pragtical.AppDir..."

  strip_flag=""
  if [[ $build_type == "release" ]]; then
    strip_flag="--strip"
  fi

  DESTDIR="$(realpath Pragtical.AppDir)" meson install $strip_flag \
    --skip-subprojects -C "${build_dir}"

  if [[ -z "$cross" ]]; then
    polyfill_glibc Pragtical.AppDir/usr/bin/pragtical
  fi

  cp "AppRun.$arch" Pragtical.AppDir/AppRun
  cp -av "subprojects/ppm/libraries" Pragtical.AppDir/usr/share/pragtical/
  cp -av "subprojects/ppm/plugins/plugin_manager" Pragtical.AppDir/usr/share/pragtical/plugins/
  cp "$ppm_file" Pragtical.AppDir/usr/share/pragtical/plugins/plugin_manager/

  # These could be symlinks but it seems they doesn't work with AppimageLauncher
  cp resources/icons/logo.svg Pragtical.AppDir/pragtical.svg
  cp resources/linux/org.pragtical.pragtical.desktop Pragtical.AppDir/

  if [[ $addons == true ]]; then
    addons_download "${build_dir}"
    addons_install "${build_dir}" "Pragtical.AppDir/usr/share/pragtical"
  fi

  if [[ $static_build == false ]]; then
    echo "Copying libraries..."

    mkdir -p Pragtical.AppDir/usr/lib/

    local allowed_libs=(
      libfreetype
      libpcre2
      libSDL2
      libsndio
      liblua
    )

    while read line; do
      local libname="$(echo $line | cut -d' ' -f1)"
      local libpath="$(echo $line | cut -d' ' -f2)"
      for lib in "${allowed_libs[@]}" ; do
        if echo "$libname" | grep "$lib" > /dev/null ; then
          cp "$libpath" Pragtical.AppDir/usr/lib/
          continue 2
        fi
      done
      echo "  Ignoring: $libname"
    done < <(ldd "${build_dir}/src/pragtical" | awk '{print $1 " " $3}')
  fi

  echo "Generating AppImage..."

  $appimagebin --appimage-extract-and-run --runtime-file "runtime-${arch}" \
    Pragtical.AppDir \
    "Pragtical${version}-${arch}.AppImage"
}

main "$@"
