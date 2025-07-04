pragtical_sources = [
    'api/api.c',
    'api/dirmonitor.c',
    'api/renderer.c',
    'api/renwindow.c',
    'api/regex.c',
    'api/system.c',
    'api/process.c',
    'api/channel.c',
    'api/thread.c',
    'api/shmem.c',
    'api/utf8.c',
    'api/encoding.c',
    'arena_allocator.c',
    'renderer.c',
    'renwindow.c',
    'rencache.c',
    'main.c',
]

if lua_jit_found
    pragtical_sources += 'ffiexports.c'
    # Export all local symbols for LuaJIT FFI Access
    if host_machine.system() != 'windows' and host_machine.system() != 'darwin'
        # reminder: on mingw the valid flag is -Wl,--export-all-symbols
        pragtical_link_args += '-Wl,--export-dynamic'
    endif
endif

dirmonitor_backends = get_option('dirmonitor_backends')

if dirmonitor_backends.length() == 0
    if cc.has_function('inotify_init', prefix : '#include<sys/inotify.h>')
        dirmonitor_backends += 'inotify'
    endif

    if host_machine.system() == 'darwin' and cc.check_header('CoreServices/CoreServices.h')
        dirmonitor_backends += 'fsevents'
    endif

    if cc.has_function('kqueue', prefix : '#include<sys/event.h>')
        dirmonitor_backend = 'kqueue'
    endif

    if cc.has_function('create_inode_watcher', prefix : '#include<fcntl.h>')
        dirmonitor_backend = 'inodewatcher'
    endif

    if dependency('libkqueue', required : false).found()
        dirmonitor_backend = 'kqueue'
    endif

    if host_machine.system() == 'windows'
        dirmonitor_backend = 'win32'
    endif

    dirmonitor_backends += 'dummy'
endif

foreach backend : dirmonitor_backends
    if backend == 'inotify'
        pragtical_sources += 'api' / 'dirmonitor' / 'inotify.c'
        pragtical_cargs += '-DDIRMONITOR_INOTIFY'
    elif backend == 'fsevents'
        pragtical_sources += 'api' / 'dirmonitor' / 'fsevents.c'
        pragtical_cargs += '-DDIRMONITOR_FSEVENTS'
    elif backend == 'kqueue'
        pragtical_sources += 'api' / 'dirmonitor' / 'kqueue.c'
        libkqueue_dep = dependency('libkqueue', required : false)
        if libkqueue_dep.found()
            pragtical_deps += libkqueue_dep
        endif
        pragtical_cargs += '-DDIRMONITOR_KQUEUE'
    elif backend == 'inodewatcher'
        add_languages('cpp')
        pragtical_sources += 'api' / 'dirmonitor' / 'inodewatcher.cpp'
        pragtical_cargs += '-DDIRMONITOR_INODEWATCHER'
    elif backend == 'win32'
        pragtical_sources += 'api' / 'dirmonitor' / 'win32.c'
        pragtical_cargs += '-DDIRMONITOR_WIN32'
    elif backend == 'dummy'
        pragtical_sources += 'api' / 'dirmonitor' / 'dummy.c'
        pragtical_cargs += '-DDIRMONITOR_DUMMY'
    else
        error('Unknown dirmonitor backend @0@'.format(backend))
    endif
endforeach

summary('dirmonitor backends', dirmonitor_backends)

# luajit compatibility files
if lua_compat_needed
    pragtical_sources += [
        'compat/liolib.c',
        'compat/lstrlib.c',
        'compat/ltablib.c',
        'compat/lutf8lib.c'
    ]

    if not lua_jit_found
        pragtical_sources += 'compat/ljbitlib.c'
    endif
endif

message('lua-compat-5.3 needed: @0@'.format(lua_compat_needed))

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

if host_machine.system() == 'windows'
    executable('pragtical',
        'main_com.c',
        name_suffix: 'com',
        install_dir: pragtical_bindir,
        install: true,
        win_subsystem: 'console'
    )
endif
