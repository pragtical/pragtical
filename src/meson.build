pragtical_sources = [
    'api/api.c',
    'api/renderer.c',
    'api/regex.c',
    'api/system.c',
    'api/process.c',
    'api/channel.c',
    'api/thread.c',
    'api/shmem.c',
    'api/utf8.c',
    'api/encoding.c',
    'renderer.c',
    'renwindow.c',
    'rencache.c'
]

# dirmonitor backend
if get_option('dirmonitor_backend') == ''
    if cc.has_function('inotify_init', prefix : '#include<sys/inotify.h>')
        dirmonitor_backend = 'inotify'
    elif host_machine.system() == 'darwin' and cc.check_header('CoreServices/CoreServices.h')
        dirmonitor_backend = 'fsevents'
    elif cc.has_function('kqueue', prefix : '#include<sys/event.h>')
        dirmonitor_backend = 'kqueue'
    elif dependency('libkqueue', required : false).found()
        dirmonitor_backend = 'kqueue'
    elif host_machine.system() == 'windows'
        dirmonitor_backend = 'win32'
    else
        dirmonitor_backend = 'dummy'
        warning('no suitable backend found, defaulting to dummy backend')
    endif
else
    dirmonitor_backend = get_option('dirmonitor_backend')
endif

message('dirmonitor_backend: @0@'.format(dirmonitor_backend))

if dirmonitor_backend == 'kqueue'
    libkqueue_dep = dependency('libkqueue', required : false)
    if libkqueue_dep.found()
        pragtical_deps += libkqueue_dep
    endif
endif

pragtical_sources += [
    'api/dirmonitor.c',
    'api/dirmonitor/' + dirmonitor_backend + '.c',
]

# luajit compatibility files
if lua_jit_found
    pragtical_sources += [
        'compat/lbitlib.c',
        'compat/lstrlib.c',
        'compat/ltablib.c',
        'compat/lutf8lib.c'
    ]
else
    pragtical_sources += 'compat/ljbitlib.c'
endif

pragtical_rc = []
if host_machine.system() == 'windows'
    windows = import('windows')
    pragtical_rc += windows.compile_resources('../resources/icons/icon.rc')
    pragtical_rc += windows.compile_resources('../resources/windows/manifest.rc')

    pragtical_sources += 'windows/darkmode.c'
    pragtical_deps += cc.find_library('dwmapi', required : true)
elif host_machine.system() == 'darwin'
    pragtical_sources += 'bundle_open.m'
endif

pragtical_runpath = ''
if host_machine.system() == 'darwin'
    # @executable_path: always the directory relative to executable
    # @loader_path: directory relative to executable or invoked shared library
    if get_option('bundle')
        pragtical_runpath = '@executable_path/../Frameworks/'
    elif get_option('portable')
        pragtical_runpath = '@executable_path/'
    endif
else
    # $ORIGIN: directory containing the executable or shared library
    # $LIB: directory containing the dynamic linker (usually /lib or /lib64)
    pragtical_runpath += '$ORIGIN'
    pragtical_runpath += ':$ORIGIN/../$LIB'
endif

pragtical_includes += include_directories('.')

compiler_id = meson.get_compiler('c').get_id()
pragtical_deps_whole = []
pragtical_deps_inc = []
foreach dep : pragtical_deps
    if dep.type_name() == 'internal' and compiler_id != 'msvc'
        pragtical_deps_whole += dep.as_link_whole()
        pragtical_deps_inc += dep.partial_dependency(includes: true)
    else
        pragtical_deps_whole += dep
        pragtical_deps_inc += dep
    endif
endforeach

pragtical_lib = shared_library('libpragtical',
    pragtical_sources,
    include_directories: pragtical_includes,
    dependencies: pragtical_deps_whole,
    c_args: pragtical_cargs + '-DPRAGTICAL_LIB',
    objc_args: pragtical_cargs,
    link_args: pragtical_link_args,
    install_dir: pragtical_libdir,
    install: true,
    build_rpath: pragtical_runpath,
    install_rpath: pragtical_runpath,
    name_prefix: ''
)

pragtical_dep = declare_dependency(
    link_with: pragtical_lib,
    include_directories: pragtical_includes,
    compile_args: pragtical_cargs,
    link_args: pragtical_link_args,
    dependencies: pragtical_deps_inc
)

executable('pragtical',
    pragtical_rc + 'main.c',
    dependencies: [pragtical_dep, sdlmain_dep],
    c_args: ['-DSDL_MAIN_HANDLED', '-DPRAGTICAL_CONSOLE_REDIRECT'],
    install: true,
    install_dir: pragtical_bindir,
    build_rpath: pragtical_runpath,
    install_rpath: pragtical_runpath,
    win_subsystem: 'windows'
)

if host_machine.system() == 'windows'
    executable('pragtical-cli',
        pragtical_rc + 'main.c',
        dependencies: [pragtical_dep, sdlmain_dep],
        c_args: ['-DSDL_MAIN_HANDLED'],
        install: true,
        install_dir: pragtical_bindir,
        build_rpath: pragtical_runpath,
        install_rpath: pragtical_runpath,
        win_subsystem: 'console'
    )
endif

pkgconfig = import('pkgconfig')

if pkgconfig.found() and meson.get_compiler('c').get_id() != 'msvc'
  pkgconfig.generate(pragtical_lib,
    filebase: 'pragtical',
    name: 'Pragtical',
    description: 'The practical and pragmatic code editor.',
    url: 'https://pragtical.dev',
    subdirs: ['pragtical', 'pragtical/third_party', 'pragtical/SDL2'],
  )
endif

install_headers(
  'papi.h',
  'api/api.h',
  'rencache.h',
  'renderer.h',
  'renwindow.h',
  'unidata.h',
  'utfconv.h',
  install_dir: pragtical_includedir / 'pragtical'
)

install_headers(
  'compat/compat-5.3.h',
  'compat/compat-5.3.c',
  install_dir: pragtical_includedir / 'pragtical' / 'compat'
)
