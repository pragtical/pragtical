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
    'rencache.c',
    'main.c',
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

pragtical_includes += include_directories('.')

executable('pragtical',
    pragtical_sources + pragtical_rc,
    include_directories: pragtical_includes,
    dependencies: pragtical_deps,
    c_args: pragtical_cargs,
    objc_args: pragtical_cargs,
    link_args: pragtical_link_args,
    install_dir: pragtical_bindir,
    install: true,
    win_subsystem: 'windows',
)
