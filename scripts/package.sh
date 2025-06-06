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
  echo "-b --builddir DIRNAME         Sets the name of the build directory (not path)."
  echo "                              Default: '$(get_default_build_dir)'."
  echo "-d --destdir DIRNAME          Set the name of the package directory (not path)."
  echo "                              Default: 'pragtical'."
  echo "-h --help                     Show this help and exit."
  echo "-p --prefix PREFIX            Install directory prefix. Default: '/'."
  echo "-v --version VERSION          Sets the version on the package name."
  echo "-a --addons                   Install 3rd party addons."
  echo "   --debug                    Debug this script."
  echo "-A --appimage                 Create an AppImage (Linux only)."
  echo "-B --binary                   Create a normal / portable package or macOS bundle,"
  echo "                              depending on how the build was configured. (Default.)"
  echo "-D --dmg                      Create a DMG disk image with AppDMG (macOS only)."
  echo "-I --innosetup                Create a InnoSetup package (Windows only)."
  echo "-r --release                  Strip debugging symbols."
  echo "-S --source                   Create a source code package,"
  echo "                              including subprojects dependencies."
  echo "   --cross-platform PLATFORM  The platform to package for."
  echo "   --cross-arch ARCH          The architecture to package for."
  echo
}

source_package() {
  local build_dir=build-src
  local package_name=$1

  rm -rf ${build_dir}
  rm -rf ${package_name}
  rm -f ${package_name}.tar.gz

  meson subprojects download
  meson setup ${build_dir} -Dsource-only=true

  # Note: not using git-archive(-all) because it can't include subprojects ignored by git
  rsync -arv \
    --exclude /*build*/ \
    --exclude *.git* \
    --exclude pragtical* \
    --exclude submodules \
    . ${package_name}

  cp "${build_dir}/start.lua" "${package_name}/data/core"

  tar rf ${package_name}.tar ${package_name}
  gzip -9 ${package_name}.tar
}

package_plugin_manager() {
  if [[ -d "${data_dir}/plugins/plugin_manager" ]]; then
    return
  fi
  local platform=$1
  local arch=$2
  local data_dir=$3
  local file="ppm.${arch}-${platform}"
  if [[ $platform == "windows" ]]; then
    file="$file.exe"
  fi
  if [ ! -e "$file" ]; then
    if ! wget -O "$file" "https://github.com/pragtical/plugin-manager/releases/download/continuous/${file}" ; then
      echo "Could not download PPM for the arch '${arch}'."
      return
    else
      chmod 0755 "$file"
    fi
  fi
  cp -av "subprojects/ppm/libraries" "${data_dir}/"
  cp -av "subprojects/ppm/plugins/plugin_manager" "${data_dir}/plugins/"
  cp "$file" "${data_dir}/plugins/plugin_manager/"
}

main() {
  local arch="$(get_platform_arch)"
  local platform="$(get_platform_name)"
  local build_dir="$(get_default_build_dir)"
  local dest_dir=pragtical
  local prefix=/
  local version
  local addons=false
  local appimage=false
  local binary=false
  local dmg=false
  local innosetup=false
  local release=false
  local source=false
  local cross
  local cross_arch
  local cross_platform

  # store the current flags to easily pass them to appimage script
  local flags="$@"

  for i in "$@"; do
    case $i in
      -b|--builddir)
        build_dir="$2"
        shift
        shift
        ;;
      -d|--destdir)
        dest_dir="$2"
        shift
        shift
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      -p|--prefix)
        prefix="$2"
        shift
        shift
        ;;
      -v|--version)
        if [[ -n $2 ]]; then version="-$2"; fi
        shift
        shift
        ;;
      -A|--appimage)
        if [[ "$platform" != "linux" ]]; then
          echo "Warning: ignoring --appimage option, works only under Linux."
        else
          appimage=true
        fi
        shift
        ;;
      -B|--binary)
        binary=true
        shift
        ;;
      -D|--dmg)
        if [[ "$platform" != "macos" ]]; then
          echo "Warning: ignoring --dmg option, works only under macOS."
        else
          dmg=true
        fi
        shift
        ;;
      -I|--innosetup)
        if [[ "$platform" != "windows" ]]; then
          echo "Warning: ignoring --innosetup option, works only under Windows."
        else
          innosetup=true
        fi
        shift
        ;;
      -r|--release)
        release=true
        shift
        ;;
      -S|--source)
        source=true
        shift
        ;;
      -a|--addons)
        addons=true
        shift
        ;;
      --cross-platform)
        cross=true
        cross_platform="$2"
        shift
        shift
        ;;
      --cross-arch)
        cross=true
        cross_arch="$2"
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

  if [[ -n $1 ]]; then show_help; exit 1; fi

  if [[ -n "$cross" ]]; then
    platform="${cross_platform:-$platform}"
    arch="${cross_arch:-$arch}"
    build_dir="$(get_default_build_dir "$platform" "$arch")"
  fi

  # The source package doesn't require a previous build,
  # nor the following install step, so run it now.
  if [[ $source == true ]]; then source_package "pragtical$version-src"; fi

  # No packages request
  if [[ $appimage == false && $binary == false && $dmg == false && $innosetup == false ]]; then
    # Source only, return.
    if [[ $source == true ]]; then return 0; fi
    # Build the binary package as default instead doing nothing.
    binary=true
  fi

  rm -rf "${dest_dir}"

  local strip_flag=""
  if [[ $release == true ]]; then
    strip_flag="--strip"
  fi

  DESTDIR="$(pwd)/${dest_dir}" meson install $strip_flag \
    --skip-subprojects="freetype2,pcre2" \
    -C "${build_dir}"

  local data_dir="$(pwd)/${dest_dir}/data"
  local exe_file="$(pwd)/${dest_dir}/pragtical"

  local package_name=pragtical$version-$platform-$arch
  local bundle=false
  local portable=false

  if [[ -d "${data_dir}" ]]; then
    echo "Creating a portable, compressed archive..."
    portable=true
    exe_file="$(pwd)/${dest_dir}/pragtical"
    if [[ $platform == "windows" ]]; then
      exe_file="${exe_file}.exe"
      if command -v ntldd >/dev/null 2>&1; then
        # Copy MinGW libraries dependencies.
        # MSYS2 ldd command seems to be only 64bit, so use ntldd
        # see https://github.com/msys2/MINGW-packages/issues/4164
        ntldd -R "${exe_file}" \
          | grep mingw \
          | awk '{print $3}' \
          | sed 's#\\#/#g' \
          | xargs -I '{}' cp -v '{}' "$(pwd)/${dest_dir}/"
        # Copy ppm dependencies too
        if [[ -d "${data_dir}/plugins/plugin_manager" ]]; then
          ntldd -R "${data_dir}/plugins/plugin_manager"/ppm.* \
            | grep mingw \
            | awk '{print $3}' \
            | sed 's#\\#/#g' \
            | xargs -I '{}' cp -v '{}' "${data_dir}/plugins/plugin_manager/"
        fi
      else
        echo "WARNING: ntldd not found; assuming program is static"
      fi
    else
      # Windows archive is always portable
      package_name+="-portable"
    fi
  elif [[ $platform == "macos" && ! -d "${data_dir}" ]]; then
    data_dir="$(pwd)/${dest_dir}/Contents/Resources"
    if [[ -d "${data_dir}" ]]; then
      echo "Creating a macOS bundle application..."
      bundle=true
      # Specify "bundle" on compressed archive only, implicit on images
      if [[ $dmg == false ]]; then package_name+="-bundle"; fi
      rm -rf "Pragtical.app"; mv "${dest_dir}" "Pragtical.app"
      dest_dir="Pragtical.app"
      exe_file="$(pwd)/${dest_dir}/Contents/MacOS/pragtical"
      data_dir="$(pwd)/${dest_dir}/Contents/Resources"
    fi
  fi

  if [[ $bundle == false && $portable == false ]]; then
    data_dir="$(pwd)/${dest_dir}/$prefix/share/pragtical"
    exe_file="$(pwd)/${dest_dir}/$prefix/bin/pragtical"
  fi

  if [[ -z "$cross" ]]; then
    polyfill_glibc "${exe_file}"
  fi

  mkdir -p "${data_dir}"

  if [[ $addons == true ]]; then
    addons_download "${build_dir}"
    addons_install "${build_dir}" "${data_dir}"
  fi

  package_plugin_manager "$platform" "$arch" "$data_dir"

  # TODO: use --skip-subprojects when 0.58.0 will be available on supported
  # distributions to avoid subprojects' include and lib directories to be copied.
  # Install Meson with PIP to get the latest version is not always possible.
  pushd "${dest_dir}"
  find . -type d -name 'include' -prune -exec rm -rf {} \;
  find . -type d -name 'lib' -prune -exec rm -rf {} \;
  find . -type d -empty -delete
  popd

  echo "Creating a compressed archive ${package_name}"
  if [[ $binary == true ]]; then
    rm -f "${package_name}".tar.gz
    rm -f "${package_name}".zip

    if [[ $platform == "windows" ]]; then
      zip -9rv ${package_name}.zip ${dest_dir}/*
    else
      tar czvf "${package_name}".tar.gz "${dest_dir}"
    fi
  fi

  if [[ $appimage == true ]]; then
    source scripts/appimage.sh $flags --static
  fi
  if [[ $bundle == true && $dmg == true ]]; then
    source scripts/appdmg.sh "${package_name}"
  fi
  if [[ $innosetup == true ]]; then
    source scripts/innosetup/innosetup.sh $flags
  fi
}

main "$@"
