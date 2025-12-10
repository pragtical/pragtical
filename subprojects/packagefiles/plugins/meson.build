project('plugins', 'c', version: 'GIT', license: 'MIT')

# Check for valid shell
unix_shell = find_program('sh', required: false).found()
is_msvc = meson.get_compiler('c').get_id() == 'msvc'
if (host_machine.system() == 'windows' and not unix_shell) or is_msvc
    unix_shell = false
    shell_command = find_program('cmd', required: false)
endif

# Install applicable language files if shell found
if unix_shell or shell_command.found()
    if unix_shell
        list_command = run_command(
            'sh', '-c', 'ls ' + 'plugins/language_*',
            check: true
        )
    else
        list_command = run_command(
            'cmd', '/C', 'dir /b/s ' + 'plugins\\language_*',
            check: true
        )
    endif

    sources = list_command.stdout().strip().split('\n')

    install_data(sources,
        install_dir: join_paths(get_option('data_dir'), 'plugins')
    )
endif
