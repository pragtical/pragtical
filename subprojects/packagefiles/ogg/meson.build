project('ogg', 'c', version: '1.3.6')

subdir('include/ogg')
ogg_includes = include_directories('include')
ogg_lib = library('ogg', ['src/bitwise.c', 'src/framing.c'],
  include_directories: ogg_includes
)
ogg_dep = declare_dependency(link_with: ogg_lib,
  include_directories: ogg_includes
)
meson.override_dependency('ogg', ogg_dep)
