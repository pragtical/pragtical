project('ppm',
    ['c'],
    version : 'GIT',
    license : 'PPM',
    meson_version : '>= 0.60'
)

cc = meson.get_compiler('c')

lua_exe = find_program('lua')

ppm_lua_c = configure_file(
    capture: false,
    command: [lua_exe, '-e', 'f = string.dump(assert(loadfile("@INPUT0@"))) io.open("@OUTPUT0@", "wb"):write("unsigned char ppm_luac[] = \"" .. f:gsub(".", function (c) return string.format("\\\x%02X",string.byte(c)) end) .. "\";unsigned int ppm_luac_len = " .. #f .. ";")'],
    input: files('src/ppm.lua'),
    output: 'ppm.lua.c'
)

# Special checking for lua dependency due to distro differences
lua_names = [
    'lua5.4', # Debian
    'lua-5.4', # FreeBSD
    'lua',    # Fedora
]

foreach lua : lua_names
    last_lua = (lua == lua_names[-1] or get_option('wrap_mode') == 'forcefallback')
    lua_dep = dependency(lua, fallback: last_lua ? ['lua', 'lua_dep'] : [], required : false,
        version: '>= 5.4',
        default_options: ['default_library=static', 'line_editing=disabled', 'interpreter=false']
    )
    if lua_dep.found()
        break
    endif

    if last_lua
        # If we could not find lua on the system and fallbacks are disabled
        # try the compiler as a last ditch effort, since Lua has no official
        # pkg-config support.
        lua_dep = cc.find_library('lua', required : true)
    endif
endforeach

# Search the rest of dependencies
microtar_dep = subproject('microtar').get_variable('microtar_dep')

if get_option('wrap_mode') != 'forcefallback'
    zlib_dep = dependency('zlib')
    mbedtls_dep = dependency('mbedtls', version: '<3', required: false)
    libgit2_dep = dependency('libgit2')
    libzip_dep = dependency('libzip')

    if not mbedtls_dep.found()
        # Using has_headers to distinguish between mbedtls2 and mbedtls3
        _mbedtls_dep = cc.find_library('mbedtls', has_headers: 'mbedtls/net.h', required: false)
        if _mbedtls_dep.found()
            mbedtls_dep = [
                _mbedtls_dep,
                cc.find_library('mbedx509'),
                cc.find_library('mbedcrypto'),
            ]
        else
            # In some cases we need to manually specify where to find mbedtls2
            message('Using fallback mbedtls definition')
            mbedtls_dep = declare_dependency(
                include_directories: ['/usr/include/mbedtls2/'],
                link_args: ['-L/usr/lib/mbedtls2', '-lmbedtls', '-lmbedx509', '-lmbedcrypto']
            )
        endif
    endif

    executable(
        'ppm',
        files('src/ppm.c') + ppm_lua_c,
        dependencies: [
            zlib_dep, mbedtls_dep, libgit2_dep, libzip_dep, lua_dep, microtar_dep
        ],
        c_args: ['-DPPM_STATIC'],
        install: true,
        install_dir: join_paths(get_option('data_dir'), 'plugins/plugin_manager')
    )
else
    cmake = import('cmake')

    build_type = 'Release'
    if get_option('buildtype') == 'debug'
        build_type = 'Debug'
    endif

    if meson.get_compiler('c').get_id() != 'msvc'
        INC='-I'
        LIB='-L'
    else
        INC='/I'
        LIB='/LIBPATH:'
    endif

    build_shared = 'ON'
    if get_option('default_library') == 'static'
        build_shared = 'OFF'
    endif

    # zlib
    zlib_options = cmake.subproject_options()
    zlib_options.add_cmake_defines({
        'CMAKE_BUILD_TYPE': build_type,
        'BUILD_SHARED_LIBS': 'OFF',
    })
    zlib_options.set_install(false)

    zlib_dep = cmake.subproject('zlib', options: zlib_options).dependency('zlibstatic')

    # mbedtls
    mbedtls_options = cmake.subproject_options()
    mbedtls_options.add_cmake_defines({
        'CMAKE_BUILD_TYPE': build_type,
        'BUILD_SHARED_LIBS': 'OFF',
        'ENABLE_TESTING': 'OFF',
        'ENABLE_PROGRAMS': 'OFF',
        'CMAKE_C_FLAGS': '-DMBEDTLS_MD4_C=1 -w',
    })
    mbedtls_options.set_install(false)

    mbedtls = cmake.subproject('mbedtls', options: mbedtls_options)
    mbedtls_dep = mbedtls.dependency('mbedtls')
    mbedx509_dep = mbedtls.dependency('mbedx509')
    mbedcrypto_dep = mbedtls.dependency('mbedcrypto')

    # libzip
    libzip_options = cmake.subproject_options()
    libzip_options.add_cmake_defines({
        'CMAKE_BUILD_TYPE': build_type,
        'BUILD_SHARED_LIBS': 'OFF',
        'BUILD_TOOLS': 'OFF',
        'BUILD_EXAMPLES': 'OFF',
        'BUILD_DOC': 'OFF',
        'ENABLE_COMMONCRYPTO': 'OFF',
        'ENABLE_GNUTLS': 'OFF',
        'ENABLE_OPENSSL': 'OFF',
        'ENABLE_BZIP2': 'OFF',
        'ENABLE_LZMA': 'OFF',
        'ENABLE_ZSTD': 'OFF',
        'CMAKE_C_FLAGS':
            INC + meson.source_root() / 'subprojects' / 'mbedtls' / 'include '
            + LIB + meson.build_root() / 'subprojects' / 'mbedtls' / '__CMake_build'
    })
    libzip_options.set_install(false)

    libzip_dep = cmake.subproject('libzip', options: libzip_options).dependency('zip')

    # libgit2
    libgit2_options = cmake.subproject_options()
    libgit2_options.add_cmake_defines({
        'CMAKE_BUILD_TYPE': build_type,
        'BUILD_SHARED_LIBS': 'OFF',
        'BUILD_TESTS': 'OFF',
        'BUILD_CLI': 'OFF',
        'REGEX_BACKEND': 'builtin',
        'USE_SSH': 'OFF',
        'USE_HTTPS': 'mbedTLS',
        'CMAKE_C_FLAGS':
            INC + meson.source_root() / 'subprojects' / 'mbedtls' / 'include '
            + LIB + meson.build_root() / 'subprojects' / 'mbedtls' / '__CMake_build '
            + LIB + meson.build_root() / 'subprojects' / 'libzip' / '__CMake_build'
    })
    libgit2_options.set_install(false)

    libgit2 = cmake.subproject('libgit2', options: libgit2_options)
    libgit2_dep = libgit2.dependency('libgit2')
    libgit2_ntlmclient_dep = libgit2.dependency('ntlmclient')
    libtgit2_libgit2package_dep = libgit2.dependency('libgit2package')

    executable(
        'ppm',
        files('src/ppm.c') + ppm_lua_c,
        dependencies: [
            zlib_dep, libzip_dep,
            mbedtls_dep, mbedx509_dep, mbedcrypto_dep,
            libgit2_ntlmclient_dep, libtgit2_libgit2package_dep, libgit2_dep,
            lua_dep, microtar_dep
        ],
        c_args: ['-DPPM_STATIC'],
        install: true,
        install_dir: join_paths(get_option('data_dir'), 'plugins/plugin_manager')
    )
endif

install_subdir(
    'plugins/plugin_manager',
    install_dir: join_paths(get_option('data_dir'), 'plugins')
)
