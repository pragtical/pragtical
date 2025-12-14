project('ppm',
    ['c'],
    version : 'GIT',
    license : 'PPM',
    meson_version : '>= 0.60',
    default_options : ['c_std=gnu11', 'warning_level=0', 'werror=false']
)

if get_option('arch_tuple') != ''
    arch_tuple = get_option('arch_tuple')
else
    arch_tuple = '@0@-@1@'.format(target_machine.cpu_family(), target_machine.system())
endif

is_msys = false

ccid = meson.get_compiler('c').get_id()
if host_machine.system() == 'windows' and (ccid == 'gcc' or ccid == 'clang')
    gcc_command = [ccid, '-v']
    gcc_command_out = run_command(gcc_command, check: true)
    gcc_out = gcc_command_out.stderr().to_lower()
    gcc_out += ' ' + gcc_command_out.stdout().to_lower()
    if gcc_out.contains('msys')
        is_msys = true
    endif
endif

if meson.get_compiler('c').get_id() == 'msvc'
    message('MSVC compiler not supported, use MSYS to build.')
elif get_option('wrap_mode') != 'forcefallback' and not is_msys
    cc = meson.get_compiler('c')

    lua_exe = find_program('lua')

    ppm_lua_c = configure_file(
        capture: false,
        command: [lua_exe, '-e', 'f = string.dump(assert(load(io.lines("@INPUT0@", "L"), "=ppm.lua"))) io.open("@OUTPUT0@", "wb"):write("unsigned char ppm_luac[] = \"" .. f:gsub(".", function (c) return string.format("\\\x%02X",string.byte(c)) end) .. "\";unsigned int ppm_luac_len = " .. #f .. ";")'],
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
    zlib_dep = dependency('zlib')
    lzma_dep = dependency('liblzma')
    libgit2_dep = dependency('libgit2')
    libzip_dep = dependency('libzip')
    mbedtls_dep = [
        dependency('mbedtls'),
        dependency('mbedx509'),
        dependency('mbedcrypto'),
    ]

    microtar_lib = static_library('microtar', files('lib/microtar/src/microtar.c'))
    microtar_dep = declare_dependency(
        link_whole: [microtar_lib],
        include_directories: ['lib/microtar/src']
    )

    executable(
        'ppm.'+arch_tuple,
        files('src/ppm.c') + ppm_lua_c,
        dependencies: [
            zlib_dep,
            lzma_dep,
            mbedtls_dep,
            libgit2_dep,
            libzip_dep,
            lua_dep,
            microtar_dep
        ],
        c_args: ['-DPPM_STATIC'],
        install: true,
        install_dir: join_paths(get_option('data_dir'), 'plugins/plugin_manager')
    )
else
    # Check dependencies
    bash_exe = find_program('bash')
    cmake_exe = find_program('cmake')
    git_command = find_program('git')

    # Fetch git submodules
    message('Cloning git submodules...')
    run_command(git_command,
        'submodule', 'update', '--init', '--recursive', '--depth', '1',
        check : false
    )

    env = environment()

    bin_ext = ''
    if host_machine.system() == 'windows'
        bin_ext = '.exe'
    endif

    bin = 'ppm.@0@@1@'.format(arch_tuple, bin_ext)

    if host_machine.system() == 'darwin'
        if meson.is_cross_build()
            bin = 'ppm.aarch64-darwin'
            env.set('CC', 'clang')
            env.set('CFLAGS', '-arch arm64')
        endif
    else
        env.set('LDFLAGS', '-lpthread')
        if is_msys
            env.set('CFLAGS', '-Wno-incompatible-pointer-types')
        endif
    endif

    env.set('BIN', bin)

    # enforce cmake version to prevent issues.
    env.set('CMAKE_DEFAULT_FLAGS', '-DCMAKE_POLICY_VERSION_MINIMUM=3.5')

    clean_command = [bash_exe, 'build.sh', 'clean']
    run_command(clean_command, check: false)

    build_command = [bash_exe, 'build.sh', '-DPPM_STATIC']

    message('Building ppm binary')
    build = run_command(build_command, check: false, env: env)

    if build.stdout() != ''
        message('Build output: @0@'.format(build.stdout()))
    endif
    if build.stderr() != ''
        message('Build Errors: @0@'.format(build.stderr()))
    endif

    install_data(
        bin,
        install_dir: join_paths(get_option('data_dir'), 'plugins/plugin_manager')
    )
endif

install_data(
    'libraries/json.lua',
    install_dir: join_paths(get_option('data_dir'), 'libraries')
)

install_subdir(
    'plugins/plugin_manager',
    install_dir: join_paths(get_option('data_dir'), 'plugins')
)
