project('microtar', 'c', version: 'GIT')

microtar_lib = static_library('microtar', files('src/microtar.c'))

microtar_dep = declare_dependency(
    link_whole: [microtar_lib],
    include_directories: ['src']
)
