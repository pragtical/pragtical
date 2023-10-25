project('ppm',
    version : 'GIT',
    license : 'PPM',
    meson_version : '>= 0.60'
)

if get_option('arch_tuple') != ''
    arch_tuple = get_option('arch_tuple')
else
    arch_tuple = '@0@-@1@'.format(target_machine.cpu_family(), target_machine.system())
endif

if meson.get_compiler('c').get_id() == 'msvc'
    message('MSVC compiler not supported, use MSYS to build.')
else
    # Check dependencies
    bash_exe = find_program('bash')
    cmake_exe = find_program('cmake')

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
    endif

    env.set('BIN', bin)

    clean_command = [bash_exe, 'build.sh', 'clean']
    run_command(clean_command, check: false)

    build_command = [bash_exe, 'build.sh', '-DPPM_STATIC', '-static']

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

    install_subdir(
        'plugins/plugin_manager',
        install_dir: join_paths(get_option('data_dir'), 'plugins')
    )
endif
