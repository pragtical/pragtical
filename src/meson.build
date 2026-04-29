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
    'api/canvas.c',
    'api/utf8.c',
    'api/encoding.c',
    'api/diff.c',
    'api/utils/lxlauxlib.c',
    'arena_allocator.c',
    'custom_events.c',
    'system_events.c',
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
    elif host_machine.system() == 'darwin'
        # macOS export dynamic symbols option slightly different
        pragtical_link_args += '-Wl,-export_dynamic'
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
        dirmonitor_backends += 'kqueue'
    endif

    if cc.has_function('create_inode_watcher', prefix : '#include<fcntl.h>')
        dirmonitor_backends += 'inodewatcher'
    endif

    if dependency('libkqueue', required : false).found()
        dirmonitor_backends += 'kqueue'
    endif

    if host_machine.system() == 'windows'
        dirmonitor_backends += 'win32'
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

    # solve missing symbols when building from sdl3 cmake subproject
    if sdl_dep.type_name() == 'internal'
        pragtical_deps += cc.find_library('winmm', required : true)
        pragtical_deps += cc.find_library('imm32', required: true)
        pragtical_deps += cc.find_library('setupapi', required: true)
        pragtical_deps += cc.find_library('version', required: true)
        pragtical_deps += cc.find_library('iconv', required: false)
    endif
elif host_machine.system() == 'darwin'
    pragtical_sources += 'bundle_open.m'

    # solve missing symbols when building from sdl3 cmake subproject
    if sdl_dep.type_name() == 'internal'
        pragtical_link_args += [
            '-framework', 'Carbon',
            '-framework', 'CoreFoundation',
            '-framework', 'Metal',
            '-framework', 'AppKit',
            '-framework', 'CoreVideo',
            '-framework', 'IOKit',
            '-framework', 'UniformTypeIdentifiers'
        ]
    endif
endif

pragtical_includes += include_directories('.')

# load and configure linenoise
if get_option('repl_history')
    if lua_jit_found
        linenoise_jit = 'jit=true'
    else
        linenoise_jit = 'jit=false'
    endif
    pragtical_deps += subproject('linenoise',
        default_options: default_fallback_options + [
            'default_library=static', linenoise_jit
        ]
    ).get_variable('linenoise_dep')
    pragtical_cargs += '-DPRAGTICAL_REPL_HISTORY'
endif

# enable networking support
if get_option('net')
    pragtical_deps += dependency('SDL3_net', 'sdl3-net', fallback: ['sdl3_net', 'sdl3_net_dep'],
        default_options: default_fallback_options + ['default_library=static']
    )

    use_system_mbedtls = get_option('wrap_mode') != 'forcefallback'

    mbedtls_dep = disabler()
    mbedx509_dep = disabler()
    tfpsacrypto_dep = disabler()
    system_mbedtls_ok = false

    if use_system_mbedtls
        mbedtls_dep = dependency('mbedtls', version: '>=4.0.0', required: false)
        mbedx509_dep = dependency('mbedx509', version: '>=4.0.0', required: false)
        tfpsacrypto_dep = dependency('tfpsacrypto', required: false)
        system_mbedtls_ok = mbedtls_dep.found() and mbedx509_dep.found() and tfpsacrypto_dep.found()
    endif

    if not use_system_mbedtls or not system_mbedtls_ok
        cmake = import('cmake')

        mbedtls_build_type = 'Release'
        if get_option('buildtype') == 'debug'
            mbedtls_build_type = 'Debug'
        endif

        mbedtls_options = cmake.subproject_options()
        mbedtls_options.add_cmake_defines({
            'CMAKE_BUILD_TYPE': mbedtls_build_type,
            'CMAKE_POSITION_INDEPENDENT_CODE': 'ON',
            'DISABLE_PACKAGE_CONFIG_AND_INSTALL': 'ON',
            'ENABLE_PROGRAMS': 'OFF',
            'ENABLE_TESTING': 'OFF',
            'GEN_FILES': 'OFF',
            'USE_SHARED_MBEDTLS_LIBRARY': 'OFF',
            'USE_STATIC_MBEDTLS_LIBRARY': 'ON'
        })

        mbedtls = cmake.subproject('mbedtls', options: mbedtls_options)
        mbedtls_dep = mbedtls.dependency('mbedtls')
        mbedx509_dep = mbedtls.dependency('mbedx509')
        tfpsacrypto_dep = mbedtls.dependency('tfpsacrypto')

        meson.override_dependency('mbedtls', mbedtls_dep)
        meson.override_dependency('mbedx509', mbedx509_dep)
        meson.override_dependency('tfpsacrypto', tfpsacrypto_dep)
    endif

    pragtical_deps += [mbedtls_dep, mbedx509_dep, tfpsacrypto_dep]

    pragtical_sources += 'api/net.c'
    pragtical_cargs += '-DPRAGTICAL_NET'
endif

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
        pragtical_sources + pragtical_rc,
        include_directories: pragtical_includes,
        dependencies: pragtical_deps,
        c_args: pragtical_cargs,
        objc_args: pragtical_cargs,
        link_args: pragtical_link_args,
        name_suffix: 'com',
        install_dir: pragtical_bindir,
        install: true,
        win_subsystem: 'console',
    )
endif
