project('opusfile', 'c', version: '0.12')

cc = meson.get_compiler('c')
ogg_dep = dependency('ogg', static: true,
  fallback: ['ogg', 'ogg_dep'], default_options: ['default_library=static'])
opus_dep = dependency('opus', static: true, fallback: ['opus', 'opus_dep'],
  default_options: ['default_library=static', 'tests=disabled',
                    'docs=disabled', 'extra-programs=disabled'])
libm = cc.find_library('m', required: false)
opusfile_dependencies = [ogg_dep, opus_dep, libm]
opusfile_args = ['-DOP_DISABLE_HTTP']
if cc.has_function('lrintf', prefix: '#include <math.h>', dependencies: libm)
  opusfile_args += '-DOP_HAVE_LRINTF'
endif
if cc.get_argument_syntax() == 'msvc'
  opusfile_args += '-D_CRT_SECURE_NO_WARNINGS'
endif
opusfile_lib = library('opusfile',
  ['src/info.c', 'src/internal.c', 'src/opusfile.c', 'src/stream.c'],
  include_directories: 'include', c_args: opusfile_args,
  dependencies: opusfile_dependencies
)
opusfile_dep = declare_dependency(link_with: opusfile_lib,
  include_directories: 'include', dependencies: opusfile_dependencies)
meson.override_dependency('opusfile', opusfile_dep)
