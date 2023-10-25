project('widget', version: 'GIT', license : 'MIT')

install_subdir(
    '.',
    strip_directory: true,
    install_dir: join_paths(get_option('data_dir'), 'widget'),
    exclude_files: ['meson.build', '.meson-subproject-wrap-hash.txt'],
    exclude_directories: ['.git']
)
