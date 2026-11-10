project('libiconv', 'c', version: '1.19', license: 'LGPL-2.1-or-later')

if host_machine.system() != 'windows'
    error('This libiconv port is for Windows builds')
endif

# Use the configured sources and definitions from the port's MSVC project.
libiconv = static_library('iconv',
    'source/lib/iconv.c',
    'source/libcharset/lib/localcharset.c',
    'source/lib/compat.c',
    name_prefix: '',
    name_suffix: 'lib',
    include_directories: include_directories('source', 'source/lib', 'source/include'),
    c_args: [
        '-DHAVE_CONFIG_H', '-D_CRT_SECURE_NO_WARNINGS', '-DENABLE_EXTRA=1',
        '-DENABLE_RELOCATABLE=1', '-DIN_LIBRARY', '-DNO_XMALLOC',
        '-DLIBDIR="."', '-DINSTALLPREFIX="."', '-DINSTALLDIR="."',
        '-Dset_relocation_prefix=libiconv_set_relocation_prefix',
        '-Drelocate=libiconv_relocate',
    ],
    install: true,
)

libiconv_dep = declare_dependency(
    link_with: libiconv,
    include_directories: include_directories('source/include'),
    version: meson.project_version(),
    variables: {'includedir': meson.current_source_dir() / 'source/include'},
)
meson.override_dependency('iconv', libiconv_dep)
libiconv_license = files('source/COPYING.LIB')

install_headers('source/include/iconv.h')
install_data(libiconv_license, install_dir: 'share/licenses/libiconv')
