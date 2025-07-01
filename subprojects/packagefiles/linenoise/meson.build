project('linenoise',
    'c',
    version: '0.9',
    license: 'MIT',
    default_options : ['warning_level=0', 'werror=false']
)

linenoise_src = files(
    'linenoise.c',
    'linenoiselib.c',
    'encodings/utf8.c'
)

if host_machine.system() == 'windows'
    linenoise_src += 'win32fixes.c'
endif

linenoise_include = include_directories('.')

if get_option('jit')
    lua_dep = dependency('luajit', required : true,
        default_options: ['default_library=static']
    )
else
    lua_dep = dependency('lua', required : true,
        default_options: ['default_library=static']
    )
endif

linenoise_lib = static_library('linenoise',
    linenoise_src,
    dependencies: lua_dep
)

linenoise_dep = declare_dependency(
    link_with: linenoise_lib,
    include_directories: linenoise_include
)
