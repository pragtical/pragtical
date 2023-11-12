project('sdl2', 'c',
    version : '2.28.1',
    license : 'zlib',
    meson_version : '>=0.60',
    default_options : ['c_std=none'],
)

cc = meson.get_compiler('c')

if get_option('default_library') == 'both' and cc.get_argument_syntax() == 'msvc'
  error('default_library=both not supported when compiling with MSVC')
endif

c_args = cc.get_supported_arguments(
    '-msse3',
    '-Wno-deprecated-declarations',
    '-Wdeclaration-after-statement',
    '-Wshadow',
    '-fno-strict-aliasing',
    '-mpreferred-stack-boundary=2',
)

objc_args = [
    '-fobjc-arc',
    '-fobjc-weak'
]

add_project_arguments(c_args, language : 'c')
add_project_arguments(objc_args, language: 'objc')

# BEGIN platform detection logic

# FIXME: detect this properly
platform_is_linux_desktop = (host_machine.system() == 'linux')
platform_is_android = (host_machine.system() == 'android')
platform_is_linux = platform_is_android or platform_is_linux_desktop

platform_is_darwin = (host_machine.system() == 'darwin')
# FIXME: detect this properly
platform_is_macos = platform_is_darwin
platform_is_ios = false

platform_is_windows = (host_machine.system() == 'windows')
# FIXME: detect this properly
platform_is_win32 = platform_is_windows
platform_is_winrt = false

platform_is_vita = (host_machine.system() == 'vita')
platform_is_os2 = (host_machine.system() == 'os2')

platform_is_dragonflybsd = (host_machine.system() == 'dragonfly')
platform_is_freebsd = (host_machine.system() == 'freebsd')
platform_is_netbsd = (host_machine.system() == 'netbsd')
platform_is_openbsd = (host_machine.system() == 'openbsd')

platform_is_bsd = (
    platform_is_dragonflybsd or
    platform_is_freebsd or
    platform_is_netbsd or
    platform_is_openbsd
)

platform_is_haiku = (host_machine.system() == 'haiku')

platform_is_emscripten = (host_machine.system() == 'emscripten')

platform_is_psp = (host_machine.system() == 'psp')

# FIXME: verify this
platform_is_nacl = (host_machine.system() == 'nacl')

# FIXME: darwin is technically a unix system, but we cannot differenciate between macOS and darwin
platform_is_unixlike = (
    platform_is_bsd or
    platform_is_emscripten or
    platform_is_haiku or
    platform_is_linux
)

platform_is_apple = (
    platform_is_macos or
    platform_is_ios
)

platform_is_unixlike_or_apple = platform_is_unixlike or platform_is_apple

# END platform detection logic

opt_atomic = get_option('use_atomic')
opt_audio = get_option('use_audio')
opt_cpuinfo = get_option('use_cpuinfo')
opt_events = get_option('use_events')
opt_file = get_option('use_file')
opt_filesystem = get_option('use_filesystem')
opt_haptic = get_option('use_haptic')
opt_hidapi = get_option('use_hidapi')
opt_joystick = get_option('use_joystick')
opt_loadso = get_option('use_loadso')
opt_locale= get_option('use_locale')
opt_power = get_option('use_power')
opt_render = get_option('use_render')
opt_sensor = get_option('use_sensor')
opt_system_iconv = get_option('system_iconv')
opt_threads = get_option('use_threads')
opt_timers = get_option('use_timers')
opt_video = get_option('use_video')

opt_video_x11 = get_option('use_video_x11')
opt_video_wayland = get_option('use_video_wayland')
opt_video_wayland_libdecor = get_option('use_video_wayland_libdecor')
opt_video_opengl = get_option('use_video_opengl')
opt_video_openglesv2 = get_option('use_video_openglesv2')
opt_video_vulkan = get_option('use_video_vulkan')
opt_video_offscreen = get_option('use_video_offscreen')

if opt_video.disabled()
    opt_video_x11 = opt_video
    opt_video_wayland = opt_video
    opt_video_opengl = opt_video
    opt_video_openglesv2 = opt_video
    opt_video_vulkan = opt_video
    opt_video_offscreen = opt_video
    opt_render = opt_video
endif

if opt_video_wayland.disabled()
    opt_video_wayland_libdecor = opt_video_wayland
endif

opt_audio_alsa = get_option('use_audio_alsa')
opt_audio_pulseaudio = get_option('use_audio_pulseaudio')
opt_audio_jack = get_option('use_audio_jack')
opt_audio_pipewire = get_option('use_audio_pipewire')

if opt_audio.disabled()
    opt_audio_alsa = opt_audio
    opt_audio_pulseaudio = opt_audio
    opt_audio_jack = opt_audio
    opt_audio_pipewire = opt_audio
endif

if platform_is_android
    opt_haptic = opt_joystick
endif

fake_dep = dependency('', required : false)
assert(not fake_dep.found(), 'checking if fake dependency has been found')

# BEGIN awful GL hacks

khronos_dep = declare_dependency(
    include_directories : include_directories(join_paths('src', 'video', 'khronos'))
)

gl_dep = dependency('gl', required : opt_video_opengl)
if not gl_dep.found()
    gl_dep = dependency('opengl', required : opt_video_opengl)
endif

glesv2_dep = dependency('glesv2', required : opt_video_openglesv2)
if not glesv2_dep.found() and not opt_video_openglesv2.disabled()
    # we have the headers, we'll load the lib dynamically (which might be something like ANGLE)
    glesv2_dep = khronos_dep
    message('Using embedded GLESv2 headers')
endif

egl_dep = dependency('egl', required : opt_video_openglesv2)
if not egl_dep.found()
    egl_dep = dependency('egl', required : opt_video_wayland)
endif
if not egl_dep.found() and not opt_video_openglesv2.disabled()
    # we have the headers, we'll load the lib dynamically (which might be something like ANGLE)
    egl_dep = khronos_dep
    message('Using embedded EGL headers')
endif

if gl_dep.found()
    glx_dep = dependency('glx', required : false)
else
    glx_dep = fake_dep
endif

# we don't want to link against these!
gl_dep = gl_dep.partial_dependency(compile_args : true, includes : true, sources : true)
glesv2_dep = glesv2_dep.partial_dependency(compile_args : true, includes : true, sources : true)
egl_dep = egl_dep.partial_dependency(compile_args : true, includes : true, sources : true)
glx_dep = glx_dep.partial_dependency(compile_args : true, includes : true, sources : true)

gl_deps = [
    gl_dep,
    glesv2_dep,
    egl_dep,
    glx_dep,
]

# END awful GL hacks

cdata = configuration_data()

cdata.set10('SDL_DEFAULT_ASSERT_LEVEL_CONFIGURED', true)
if get_option('assertions') == 'auto'
    # Do nada
    cdata.set10('SDL_DEFAULT_ASSERT_LEVEL_CONFIGURED', false)
elif get_option('assertions') == 'disabled'
    cdata.set('SDL_DEFAULT_ASSERT_LEVEL', 0)
elif get_option('assertions') == 'release'
    cdata.set('SDL_DEFAULT_ASSERT_LEVEL', 1)
elif get_option('assertions') == 'enabled'
    cdata.set('SDL_DEFAULT_ASSERT_LEVEL', 2)
elif get_option('assertions') == 'paranoid'
    cdata.set('SDL_DEFAULT_ASSERT_LEVEL', 3)
endif
cdata.set10('HAVE_ASSERTIONS', true)

alsa_dep = dependency('alsa', required : opt_audio_alsa)
libpulse_simple_dep = dependency('libpulse-simple', required : opt_audio_pulseaudio)
jack_dep = dependency('jack', required : opt_audio_jack)
libpipewire_dep = dependency('libpipewire-0.3', required : opt_audio_jack)
vulkan_dep = dependency('vulkan', required : opt_video_vulkan)

# We don't want to try X11 on non unix systems
if platform_is_unixlike
    x11_dep = dependency('x11', required : opt_video_x11)
    xext_dep = dependency('xext', required : opt_video_x11)
    xi_dep = dependency('xi', required : opt_video_x11)
    xkbcommon_dep = dependency('xkbcommon', required : opt_video_wayland)
    xrandr_dep = dependency('xrandr', required : opt_video_x11)
    xfixes_dep = dependency('xfixes', required : opt_video_x11)
    xcursor_dep = dependency('xcursor', required : opt_video_x11)
else
    x11_dep = fake_dep
    xext_dep = fake_dep
    xi_dep = fake_dep
    xkbcommon_dep = fake_dep
    xrandr_dep = fake_dep
    xfixes_dep = fake_dep
    xcursor_dep = fake_dep
endif

threads_dep = dependency('threads', required : opt_threads)
libusb_dep = dependency('libusb-1.0', required : opt_hidapi)

if platform_is_unixlike
    dbus_dep = dependency('dbus-1', required : false).partial_dependency(
        compile_args : true, includes : true, sources : true
    )
else
    dbus_dep = fake_dep
endif

if dbus_dep.found()
    ibus_dep = dependency('ibus-1.0', required : false).partial_dependency(
        compile_args : true, includes : true, sources : true
    )
else
    ibus_dep = fake_dep
endif

wayland_found = true

wayland_client_dep = dependency('wayland-client', required : opt_video_wayland)
wayland_cursor_dep = dependency('wayland-cursor', required : opt_video_wayland)
wayland_egl_dep = dependency('wayland-egl', required : opt_video_wayland)
wayland_protocols_dep = dependency('wayland-protocols', required : opt_video_wayland)
wayland_scanner_dep = dependency('wayland-scanner', required : opt_video_wayland)
wayland_libdecor_dep = dependency('libdecor-0', required : opt_video_wayland_libdecor)

if wayland_scanner_dep.found()
    wayland_scanner = find_program(
        wayland_scanner_dep.get_variable(pkgconfig : 'wayland_scanner', default_value : 'wayland-scanner'),
        required : opt_video_wayland
    )

    if not wayland_scanner.found()
        wayland_scanner = find_program('wayland-scanner', required : opt_video_wayland)
    endif
else
    wayland_scanner = find_program('wayland-scanner', required : opt_video_wayland)
endif

# SDL currently always loads libudev dynamically,
# it'll just try a hardcoded name if prefer_dlopen is disabled.
# So don't try to link against it.
libudev_dep = dependency('libudev', required : false).partial_dependency(
    compile_args : true, includes : true, sources : true
)

cdata.set10('HAVE_LIBUDEV_H', libudev_dep.found())

dlopen_table = [
    { 'dep_var' : 'alsa_dep',             'lib' : 'asound',         'conf_var' : 'SDL_AUDIO_DRIVER_ALSA_DYNAMIC'              },
    { 'dep_var' : 'jack_dep',             'lib' : 'jack',           'conf_var' : 'SDL_AUDIO_DRIVER_JACK_DYNAMIC'              },
    { 'dep_var' : 'libpipewire_dep',      'lib' : 'pipewire-0.3',   'conf_var' : 'SDL_AUDIO_DRIVER_PIPEWIRE_DYNAMIC'          },
    { 'dep_var' : 'libpulse_simple_dep',  'lib' : 'pulse-simple',   'conf_var' : 'SDL_AUDIO_DRIVER_PULSEAUDIO_DYNAMIC'        },
    { 'dep_var' : 'libusb_dep',           'lib' : 'usb-1.0',        'conf_var' : 'SDL_LIBUSB_DYNAMIC                 '        },
    { 'dep_var' : 'wayland_client_dep',   'lib' : 'wayland-client', 'conf_var' : 'SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC'           },
    { 'dep_var' : 'wayland_cursor_dep',   'lib' : 'wayland-cursor', 'conf_var' : 'SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC_CURSOR'    },
    { 'dep_var' : 'wayland_egl_dep',      'lib' : 'wayland-egl',    'conf_var' : 'SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC_EGL'       },
    { 'dep_var' : 'wayland_libdecor_dep', 'lib' : 'decor-0',        'conf_var' : 'SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC_LIBDECOR'  },
    { 'dep_var' : 'x11_dep',              'lib' : 'X11',            'conf_var' : 'SDL_VIDEO_DRIVER_X11_DYNAMIC'               },
    { 'dep_var' : 'xcursor_dep',          'lib' : 'Xcursor',        'conf_var' : 'SDL_VIDEO_DRIVER_X11_DYNAMIC_XCURSOR'       },
    { 'dep_var' : 'xext_dep',             'lib' : 'Xext',           'conf_var' : 'SDL_VIDEO_DRIVER_X11_DYNAMIC_XEXT'          },
    { 'dep_var' : 'xfixes_dep',           'lib' : 'Xfixes',         'conf_var' : 'SDL_VIDEO_DRIVER_X11_DYNAMIC_XFIXES'        },
    { 'dep_var' : 'xi_dep',               'lib' : 'Xi',             'conf_var' : 'SDL_VIDEO_DRIVER_X11_DYNAMIC_XINPUT2'       },
    { 'dep_var' : 'xkbcommon_dep',        'lib' : 'xkbcommon',      'conf_var' : 'SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC_XKBCOMMON' },
    { 'dep_var' : 'xrandr_dep',           'lib' : 'Xrandr',         'conf_var' : 'SDL_VIDEO_DRIVER_X11_DYNAMIC_XRANDR'        },
    { 'dep_var' : 'libudev_dep',          'lib' : 'udev',           'conf_var' : 'SDL_UDEV_DYNAMIC'                           },
]

if get_option('prefer_dlopen')
    find_dylib_name = find_program('./find-dylib-name.py', required : true)

    foreach dep_entry : dlopen_table
        dep = get_variable(dep_entry['dep_var'])
        if dep.found()
            r = run_command(find_dylib_name, dep_entry['lib'], cc.cmd_array(), check: false)

            if r.returncode() == 0
                lib = r.stdout().strip()
                cdata.set_quoted(dep_entry['conf_var'], lib)
                set_variable(dep_entry['dep_var'], dep.partial_dependency(
                    compile_args : true, includes : true, sources : true
                ))
                message('Configured @0@ for dynamic loading'.format(lib))
            endif
        endif
    endforeach
endif

cdata.set('DYNAPI_NEEDS_DLOPEN', platform_is_unixlike_or_apple)

x11_deps = [
    x11_dep,
    xcursor_dep,
    xext_dep,
    xi_dep,
    xrandr_dep,
    xfixes_dep,
]

if wayland_scanner.found()
    wayland_deps = [
        wayland_client_dep,
        wayland_cursor_dep,
        wayland_egl_dep,
        wayland_protocols_dep,

        egl_dep,
        xkbcommon_dep,
    ]

    foreach wdep : wayland_deps
        if not wdep.found()
            wayland_found = false
        endif
    endforeach

    if not wayland_found
        wayland_deps = []
    endif
else
    wayland_deps = []
    wayland_found = false
endif

if wayland_found and wayland_libdecor_dep.found()
    wayland_deps += wayland_libdecor_dep
    cdata.set('HAVE_LIBDECOR_H', 1)
endif

if dbus_dep.found()
    cdata.set('HAVE_FCITX', 1)
    cdata.set('HAVE_DBUS_DBUS_H', 1)
endif

if ibus_dep.found()
    cdata.set('HAVE_IBUS_IBUS_H', 1)
endif

core_deps = [
    cc.find_library('m', required : false),
    cc.find_library('dl', required : false),
    dbus_dep,
    ibus_dep,
    libudev_dep,
]

if not opt_system_iconv.disabled()
    iconv_dep = cc.find_library('iconv', required : opt_system_iconv)
else
    iconv_dep = fake_dep
endif

if cc.links('#include <iconv.h>\nint main() { iconv_open("", ""); }', name : 'iconv_open test', dependencies : iconv_dep)
    cdata.set10('HAVE_ICONV', true)
    cdata.set10('HAVE_SYSTEM_ICONV', true)
    if iconv_dep.found()
        core_deps += iconv_dep
    endif
endif

extra_deps = []

if meson.get_external_property('threads_dep_is_broken', false)
    if opt_threads.disabled()
        threads_dep = fake_dep
    else
        threads_dep = declare_dependency()
    endif
endif

core_subsystems = {
    'atomic'        : { 'opt' : opt_atomic,     'deps' : [], 'opt_deps' : [] },
    'audio'         : { 'opt' : opt_audio,      'deps' : [], 'opt_deps' : [alsa_dep, libpulse_simple_dep, jack_dep, libpipewire_dep] },
    'cpuinfo'       : { 'opt' : opt_cpuinfo,    'deps' : [], 'opt_deps' : [] },
    'events'        : { 'opt' : opt_events,     'deps' : [], 'opt_deps' : x11_deps + wayland_deps },
    'file'          : { 'opt' : opt_file,       'deps' : [], 'opt_deps' : [] },
    'filesystem'    : { 'opt' : opt_filesystem, 'deps' : [], 'opt_deps' : [] },
    'haptic'        : { 'opt' : opt_haptic,     'deps' : [], 'opt_deps' : [] },
    'hidapi'        : { 'opt' : opt_hidapi,     'deps' : [], 'opt_deps' : [libusb_dep] },
    'joystick'      : { 'opt' : opt_joystick,   'deps' : [], 'opt_deps' : [] },
    'loadso'        : { 'opt' : opt_loadso,     'deps' : [], 'opt_deps' : [] },
    'locale'        : { 'opt' : opt_locale,     'deps' : [], 'opt_deps' : [] },
    'power'         : { 'opt' : opt_power,      'deps' : [], 'opt_deps' : [] },
    'render'        : { 'opt' : opt_render,     'deps' : [], 'opt_deps' : [vulkan_dep] + x11_deps + wayland_deps + gl_deps },
    'sensor'        : { 'opt' : opt_sensor,     'deps' : [], 'opt_deps' : [] },
    'threads'       : { 'opt' : opt_threads,    'deps' : [threads_dep], 'opt_deps' : [] },
    'timers'        : { 'opt' : opt_timers,     'deps' : [], 'opt_deps' : [] },
    'video'         : { 'opt' : opt_video,      'deps' : [], 'opt_deps' : [vulkan_dep] + x11_deps + wayland_deps + gl_deps },
}

enabled_subsystems = []

foreach ss_name, subsystem : core_subsystems
    ss_enabled = true

    if not subsystem['opt'].disabled()
        foreach dep : subsystem['deps']
            if not dep.found()
                warning('Subsystem "@0@" disabled due to missing dependency "@1@"'.format(ss_name, dep.name()))

                if subsystem['opt'].enabled()
                    error('Subsystem @0@ couldn\'t be enabled'.format(ss_name))
                endif

                ss_enabled = false
            endif
        endforeach
    else
        ss_enabled = false
    endif

    if ss_enabled
        foreach dep : subsystem['deps']
            if dep.found() and not extra_deps.contains(dep)
                core_deps += dep
            endif
        endforeach

        foreach dep : subsystem['opt_deps']
            if dep.found() and not extra_deps.contains(dep)
                extra_deps += dep
            endif
        endforeach

        message('Subsystem "@0@" is ENABLED'.format(ss_name))
        enabled_subsystems += ss_name
    else
        cdata.set('SDL_@0@_DISABLED'.format(ss_name.to_upper()), 1)
        message('Subsystem "@0@" is DISABLED'.format(ss_name))
    endif
endforeach

# Lets try to make the superproject std sane for SDL2
# https://github.com/mesonbuild/meson/issues/1889
sane_std = '''
#define _DEFAULT_SOURCE
#define _GNU_SOURCE
#define _ISOC11_SOURCE
#define _ISOC99_SOURCE
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#undef __STRICT_ANSI__
'''

cdata.set('SIZEOF_VOIDP', cc.sizeof('void*'))

check_headers = [
    'alloca.h',
    'altivec.h',
    'audioclient.h',
    'ctype.h',
    'ddraw.h',
    'dinput.h',
    'dsound.h',
    'dxgi.h',
    'endpointvolume.h',
    'fcitx/frontend.h',
    'float.h',
    'iconv.h',
    'immintrin.h',
    'inttypes.h',
    'libsamplerate.h',
    'libunwind.h',
    'limits.h',
    'malloc.h',
    'math.h',
    'memory.h',
    'mmdeviceapi.h',
    'pthread.h',
    'pthread_np.h',
    'semaphore.h',
    'sensorsapi.h',
    'signal.h',
    'stdarg.h',
    'stdint.h',
    'stddef.h',
    'stdio.h',
    'stdlib.h',
    'string.h',
    'strings.h',
    'sys/inotify.h',
    'sys/types.h',
    'wchar.h',

    'linux/input.h',

    'usbhid.h',
    'libusbhid.h',
    'usb.h',
    'libusb.h',

    'd3d.h',
    'd3d11.h',
    'd3d12.h',
    'windows.gaming.input.h',
    'xinput.h',
]

foreach h : check_headers
    if cc.check_header(h, dependencies : core_deps)
        cdata.set('HAVE_@0@'.format(h.to_upper().underscorify()), 1)
    endif
endforeach

if platform_is_emscripten
    # TODO: properly support building with emscripten's SSE emulation
    cdata.set('SDL_DISABLE_IMMINTRIN_H', 1)
endif

check_symbols = [
    ['O_CLOEXEC', 'fcntl.h'],
    ['M_PI', 'math.h'],
]

foreach entry : check_symbols
    symbol = entry[0]
    header = entry[1]
    if cc.has_header_symbol(header, symbol, prefix : sane_std, dependencies : core_deps)
        cdata.set('HAVE_@0@'.format(symbol.underscorify().to_upper()), 1)
    endif
endforeach

if cc.has_header_symbol('pthread.h', 'PTHREAD_MUTEX_RECURSIVE', prefix : sane_std)
    cdata.set('SDL_THREAD_PTHREAD_RECURSIVE_MUTEX', 1)
endif

if cc.has_header_symbol('pthread.h', 'PTHREAD_MUTEX_RECURSIVE_NP', prefix : sane_std)
    cdata.set('SDL_THREAD_PTHREAD_RECURSIVE_MUTEX_NP', 1)
endif

cdata.set('SDL_HAVE_LIBDECOR_GET_MIN_MAX',
    wayland_libdecor_dep.found() and
    cc.has_header_symbol(
        'libdecor.h', 'libdecor_frame_get_max_content_size',
        prefix : sane_std, dependencies : core_deps + wayland_libdecor_dep
    ) and
    cc.has_header_symbol(
        'libdecor.h', 'libdecor_frame_get_min_content_size',
        prefix : sane_std, dependencies : core_deps + wayland_libdecor_dep
    )
)

check_functions = [
    ['_Exit', 'stdlib.h'],
    ['_i64toa', 'stdlib.h'],
    ['_ltoa', 'stlib.h'],
    ['_stricmp', 'string.h'],
    ['_strlwr', 'string.h'],
    ['_strnicmp', 'string.h'],
    ['_strrev', 'string.h'],
    ['_strupr', 'string.h'],
    ['_uit64toa', 'stdlib.h'],
    ['_uitoa', 'stdlib.h'],
    ['_ultoa', 'stdlib.h'],
    ['_wcsdup', 'wchar.h'],
    ['_wcsicmp', 'wchar.h'],
    ['_wcsnicmp', 'wchar.h'],
    ['abs', 'stdlib.h'],
    ['bsearch', 'stdlib.h'],
    ['acos', 'math.h'],
    ['acosf', 'math.h'],
    ['alloca', 'stdlib.h'],
    ['asin', 'math.h'],
    ['asinf', 'math.h'],
    ['atan', 'math.h'],
    ['atan2', 'math.h'],
    ['atan2f', 'math.h'],
    ['atanf', 'math.h'],
    ['atof', 'stdlib.h'],
    ['atoi', 'stdlib.h'],
    ['bcopy', 'strings.h'],
    ['calloc', 'stdlib.h'],
    ['ceil', 'math.h'],
    ['ceilf', 'math.h'],
    ['clock_gettime', 'time.h'],
    ['copysign', 'math.h'],
    ['copysignf', 'math.h'],
    ['cos', 'math.h'],
    ['cosf', 'math.h'],
    ['dlopen', 'dlfcn.h'],
    ['elf_aux_info', 'sys/auxv.h'],
    ['exp', 'math.h'],
    ['expf', 'math.h'],
    ['fabs', 'math.h'],
    ['fabsf', 'math.h'],
    ['floor', 'math.h'],
    ['floorf', 'math.h'],
    ['fmod', 'math.h'],
    ['fmodf', 'math.h'],
    ['fopen64', 'stdio.h'],
    ['free', 'stdlib.h'],
    ['fseeko', 'stdio.h'],
    ['fseeko64', 'stdio.h'],
    ['getauxval', 'sys/auxv.h'],
    ['getenv', 'stdlib.h'],
    ['getpagesize', 'unistd.h'],
    ['index', 'strings.h'],
    ['inotify_init', 'sys/inotify.h'],
    ['inotify_init1', 'sys/inotify.h'],
    ['itoa', 'stdlib.h'],
    ['log', 'math.h'],
    ['log10', 'math.h'],
    ['log10f', 'math.h'],
    ['logf', 'math.h'],
    ['lround', 'math.h'],
    ['lroundf', 'math.h'],
    ['malloc', 'stdlib.h'],
    ['memcmp', 'string.h'],
    ['memcpy', 'string.h'],
    ['memmove', 'string.h'],
    ['memset', 'string.h'],
    ['mprotect', 'sys/mman.h'],
    ['nanosleep', 'time.h'],
    ['poll', 'poll.h'],
    ['pow', 'math.h'],
    ['powf', 'math.h'],
    ['pthread_set_name_np', 'pthread.h'],
    ['pthread_setname_np', 'pthread.h'],
    ['putenv', 'stdlib.h'],
    ['qsort', 'stdlib.h'],
    ['realloc', 'stdlib.h'],
    ['rindex', 'strings.h'],
    ['round', 'math.h'],
    ['roundf', 'math.h'],
    ['scalbn', 'math.h'],
    ['scalbnf', 'math.h'],
    ['sem_timedwait', 'semaphore.h'],
    ['setenv', 'stdlib.h'],
    ['setjmp', 'setjmp.h'],
    ['sigaction', 'signal.h'],
    ['sin', 'math.h'],
    ['sinf', 'math.h'],
    ['snprintf', 'stdio.h'],
    ['sqrt', 'math.h'],
    ['sqrtf', 'math.h'],
    ['sscanf', 'stdio.h'],
    ['strcasecmp', 'strings.h'],
    ['strchr', 'string.h'],
    ['strcmp', 'string.h'],
    ['strdup', 'string.h'],
    ['strlcat', 'string.h'],
    ['strlcpy', 'string.h'],
    ['strlen', 'string.h'],
    ['strncasecmp', 'strings.h'],
    ['strncmp', 'string.h'],
    ['strrchr', 'string.h'],
    ['strstr', 'string.h'],
    ['strtod', 'stdlib.h'],
    ['strtok_r', 'string.h'],
    ['strtol', 'stdlib.h'],
    ['strtoll', 'stdlib.h'],
    ['strtoul', 'stdlib.h'],
    ['strtoull', 'stdlib.h'],
    ['sysconf', 'unistd.h'],
    ['sysctlbyname', 'sys/sysctl.h'],
    ['tan', 'math.h'],
    ['tanf', 'math.h'],
    ['trunc', 'math.h'],
    ['truncf', 'math.h'],
    ['unsetenv', 'stdlib.h'],
    ['vsnprintf', 'stdio.h'],
    ['vsscanf', 'stdio.h'],
    ['wcscmp', 'wchar.h'],
    ['wcsdup', 'wchar.h'],
    ['wcslen', 'wchar.h'],
    ['wcsncmp', 'wchar.h'],
    ['wcsstr', 'wchar.h'],
]

foreach entry : check_functions
    func = entry[0]
    header = entry[1]
    prefix = sane_std + '#include <@0@>'.format(header)
    if cc.has_function(func, prefix : prefix, dependencies : core_deps)
        cdata.set('HAVE_@0@'.format(func.underscorify().to_upper()), 1)
    endif
endforeach

check_types = [
    ['XINPUT_GAMEPAD_EX', 'windows.h'],
    ['XINPUT_STATE_EX', 'windows.h'],
]

foreach entry : check_types
    type = entry[0]
    header = entry[1]
    prefix = sane_std + '#include <@0@>'.format(header)
    if cc.has_type(type, prefix : prefix, dependencies : core_deps)
        cdata.set('HAVE_@0@'.format(type.underscorify().to_upper()), 1)
    endif
endforeach

if cc.has_member('struct sigaction', 'sa_sigaction', prefix : '@0@#include <signal.h>'.format(sane_std))
    cdata.set('HAVE_SA_SIGACTION', 1)
endif

if cdata.get('HAVE_INOTIFY_INIT', 0) == 1
    cdata.set('HAVE_INOTIFY', 1)
endif

cdata.set('HAVE_LIBC', 1)

core_args = ['-DUSING_GENERATED_CONFIG_H']
core_ldflags = []

if platform_is_windows
    core_args += '-DDLL_EXPORT'
endif

cdata.set10('HAVE_GCC_ATOMICS',
    cc.links('int main() { int x; return __atomic_load_n(&x, __ATOMIC_SEQ_CST); }',
        name : '__atomic_load_n test'
    )
)

cdata.set10('HAVE_GCC_SYNC_LOCK_TEST_AND_SET',
    cc.links('int main() { int x; return __sync_lock_test_and_set(&x, 1); }',
        name : '__sync_lock_test_and_set test'
    )
)

cdata.set10('SDL_INPUT_LINUXEV',
    cc.compiles('#include <linux/input.h> #ifndef EVIOCGNAME #error EVIOCGNAME() ioctl not available #endif \ int main(int argc, char** argv) {}',
        name : 'input events test'
    )
)

cdata.set10('SDL_INPUT_LINUXKD',
    platform_is_linux and cc.compiles(
        '#include <linux/kd.h> #include <linux/keyboard.h> int main(int argc, char **argv) { struct kbentry kbe; kbe.kb_table = KG_CTRL; ioctl(0, KDGKBENT, &kbe); }',
        name : 'linuxkd test'
    )
)

cdata.set10('SDL_INPUT_FBSDKBIO',
    platform_is_freebsd and cc.compiles(
        '#include <sys/kbio.h> #include <sys/ioctl.h> int main(int argc, char **argv) { accentmap_t accTable; ioctl(0, KDENABIO, 1); }',
        name : 'kbio test'
    )
)

cdata.set10('SDL_INPUT_WSCONS',
    (platform_is_freebsd or platform_is_openbsd) and cc.compiles('''
        #include <sys/time.h>
        #include <dev/wscons/wsconsio.h>
        #include <dev/wscons/wsksymdef.h>
        #include <dev/wscons/wsksymvar.h>
        #include <sys/ioctl.h>
        int main(int argc, char **argv) {
            struct wskbd_map_data data;
            ioctl(0, WSKBDIO_GETMAP, &data);
            return 0;
        }''',
        name : 'wscons test'
    )
)

if cdata.get('HAVE_FCITX', 0) == 1 or cdata.get('HAVE_IBUS_IBUS_H', 0) == 1
    cdata.set('SDL_USE_IME', 1)
endif

if platform_is_freebsd and cdata.get('HAVE_INOTIFY', 0) != 1
    inotify_dep = dependency('libinotify', required : false)
    if inotify_dep.found()
        cdata.set('HAVE_INOTIFY', 1)
        extra_deps += inotify_dep
    endif
endif

sys_default_audio_driver = ['dummy']
sys_default_filesystem = ['dummy']
sys_default_haptic = ['dummy']
sys_default_input = []
sys_default_joystick = ['dummy']
sys_default_loadso = ['dummy']
sys_default_power = []
sys_default_sensor = ['dummy']
sys_default_thread = []
sys_default_timer = ['dummy']
sys_default_video = []
sys_default_video_driver = ['dummy']
sys_default_video_render = []

sys_audio_driver = sys_default_audio_driver
sys_filesystem = sys_default_filesystem
sys_haptic = sys_default_haptic
sys_input = sys_default_input
sys_joystick = sys_default_joystick
sys_loadso = sys_default_loadso
sys_power = sys_default_power
sys_sensor = sys_default_sensor
sys_thread = sys_default_thread
sys_timer = sys_default_timer
sys_video = sys_default_video
sys_video_driver = sys_default_video_driver
sys_video_render = sys_default_video_render

sys_gl_wsi = []

modular_subsystems = [
    'filesystem',
    'haptic',
    'joystick',
    'loadso',
    'power',
    'sensor',
    'video',
]

fake_subsystems = []
fake_subsystems_map = {
    'events'  : ['input'],
    'audio'   : ['audio_driver'],
    'video'   : ['video_driver'],
    'render'  : ['video_render'],
    'threads' : ['thread'],
    'timers'  : ['timer'],
}

all_modular_subsystems = modular_subsystems

foreach real_ss, fake_ss : fake_subsystems_map
    if enabled_subsystems.contains(real_ss)
        fake_subsystems += fake_ss
    endif
    all_modular_subsystems += fake_ss
endforeach

sys_dynamic_api = true
sys_thread_generic_cond_suffix = false

if platform_is_unixlike_or_apple
    # Some sane defaults
    sys_filesystem = ['unix']
    sys_loadso = ['dlopen']
    sys_timer = ['unix']
    sys_thread = ['pthread']
endif

if platform_is_android
    sys_filesystem = ['android']
    sys_haptic = ['android']
    sys_input = ['android']
    sys_joystick = ['android']
    sys_power = ['android']
    sys_sensor = ['android']
    sys_audio_driver = ['opensles', 'android']
    sys_video_driver = ['android']
    sys_video_render = ['ogl_es2']
    extra_deps += [
        cc.find_library('android'),
        cc.find_library('log'),
    ]
    if not opt_video_openglesv2.disabled()
        extra_deps += cc.find_library('GLESv2', required : opt_video_openglesv2.enabled())
    endif
elif platform_is_linux
    sys_haptic = ['linux']
    sys_input = ['linuxev', 'linuxkd']
    sys_joystick = ['linux']
    sys_power = ['linux']
elif platform_is_windows
    sys_audio_driver = ['wasapi']  # XXX: winmm needed?
    sys_filesystem = ['windows']
    sys_haptic = []
    sys_joystick = []  # XXX: winmm needed?
    sys_loadso = ['windows']
    sys_power = ['windows']
    sys_thread = ['windows']
    sys_thread_generic_cond_suffix = true
    sys_timer = ['windows']
    sys_video_driver = ['windows']
    sys_video_render = ['d3d', 'd3d11', 'd3d12']
    sys_gl_wsi = ['wgl']
    extra_deps += [
        cc.find_library('user32'),
        cc.find_library('gdi32'),
        cc.find_library('winmm'),
        cc.find_library('imm32'),
        cc.find_library('ole32'),
        cc.find_library('oleaut32'),
        cc.find_library('version'),
        cc.find_library('uuid'),
        cc.find_library('advapi32'),
        cc.find_library('setupapi'),
        cc.find_library('shell32')
    ]

    # XInput is loaded dynamically
    if cdata.get('HAVE_XINPUT_H', 0) == 1 and not get_option('use_joystick_xinput').disabled()
        sys_joystick += 'xinput'
        sys_haptic += 'xinput'
    endif

    dinput = cc.find_library('dinput8', required : get_option('use_joystick_dinput'))

    if dinput.found()
        extra_deps += dinput
        sys_joystick += 'dinput'
        sys_haptic += 'dinput'
    endif

    if sys_joystick.contains('xinput') or sys_joystick.contains('dinput')
        sys_joystick += 'rawinput'
    endif

    if sys_joystick.contains('xinput') and cdata.get('HAVE_WINDOWS_GAMING_INPUT_H', 0) == 1
        if not get_option('use_joystick_wgi').disabled()
            sys_joystick += 'wgi'
        endif
    endif
elif platform_is_macos
    sys_audio_driver = ['coreaudio']
    sys_filesystem = ['cocoa']
    sys_gl_wsi = ['cgl']
    sys_haptic = ['iokit']
    sys_joystick = ['iokit']
    sys_power = ['macosx']
    sys_video_driver = ['cocoa']
    extra_deps += dependency('appleframeworks', modules : [
        # TODO: maybe filter this out conditionally...
        'AudioToolbox',
        'AudioUnit',
        'Carbon',
        'Cocoa',
        'CoreAudio',
        'CoreFoundation',
        'CoreGraphics',
        'CoreServices',
        'ForceFeedback',
        'Foundation',
        'IOKit',
        'QuartzCore',
    ])
elif platform_is_emscripten
    sys_audio_driver = ['emscripten']
    sys_filesystem = ['emscripten']
    sys_joystick = ['emscripten']
    sys_power = ['emscripten']
    sys_video_driver = ['emscripten']
    sys_dynamic_api = false
else
    error('Unsupported platform @0@, please add.'.format(host_machine.system()))
endif

if sys_dynamic_api
    cdata.set('SDL_DYNAMIC_API', 1)
endif

cdata.set10('SDL_THREAD_GENERIC_COND_SUFFIX', sys_thread_generic_cond_suffix)

if extra_deps.contains(gl_dep)
    sys_video += 'opengl'
    sys_video_render += 'ogl'
endif

if extra_deps.contains(glesv2_dep)
    sys_video += 'opengl_es2'
    sys_video_render += 'ogl_es2'
endif

if extra_deps.contains(egl_dep)
    sys_video += 'opengl_egl'
endif

if extra_deps.contains(vulkan_dep)
    sys_video += 'vulkan'
endif

if extra_deps.contains(x11_dep)
    sys_video_driver += 'x11'
    if extra_deps.contains(glx_dep)
        sys_gl_wsi += 'glx'
    endif

    # FIXME: test for this?
    sys_video_driver += 'x11_supports_generic_events'

    if extra_deps.contains(xi_dep)
        sys_video_driver += 'x11_xinput2'

        # FIXME: test for this?
        sys_video_driver += 'x11_xinput2_supports_multitouch'
    endif

    if extra_deps.contains(xrandr_dep)
        sys_video_driver += 'x11_xrandr'
    endif

    if extra_deps.contains(xfixes_dep)
        sys_video_driver += 'x11_xfixes'
    endif

    if extra_deps.contains(xcursor_dep)
        sys_video_driver += 'x11_xcursor'
    endif

    if cc.has_header_symbol('X11/XKBlib.h', 'XkbKeycodeToKeysym', dependencies : x11_dep)
        sys_video_driver += 'x11_has_xkbkeycodetokeysym'
    endif
endif

if wayland_found and extra_deps.contains(wayland_client_dep)
    sys_video_driver += 'wayland'
endif

if not opt_video_offscreen.disabled()
    sys_video_driver += 'offscreen'
endif

if extra_deps.contains(gl_dep) or extra_deps.contains(glesv2_dep)
    foreach wsi : sys_gl_wsi
        sys_video += ['opengl_@0@'.format(wsi)]
    endforeach
endif

if extra_deps.contains(alsa_dep)
    cdata.set('SDL_AUDIO_DRIVER_ALSA', 1)
    sys_audio_driver += 'alsa'
endif

if extra_deps.contains(libpulse_simple_dep)
    sys_audio_driver += 'pulseaudio'
endif

if extra_deps.contains(jack_dep)
    sys_audio_driver += 'jack'
endif

if extra_deps.contains(libpipewire_dep)
    sys_audio_driver += 'pipewire'
endif

if not get_option('use_joystick_virtual').disabled()
    sys_joystick += 'virtual'
endif

if enabled_subsystems.contains('hidapi')
    sys_joystick += 'hidapi'
endif

if get_option('use_dummies')
    sys_audio_driver += 'dummy'
    sys_video_driver += 'dummy'
    sys_joystick += 'dummy'
    sys_sensor += 'dummy'
endif

foreach ss : all_modular_subsystems
    var_want = 'sys_@0@'.format(ss)
    var_default = 'sys_default_@0@'.format(ss)

    if not (enabled_subsystems + fake_subsystems).contains(ss)
        set_variable(var_want, get_variable(var_default))
    endif

    dedup_list = []
    foreach backend : get_variable(var_want)
        if not dedup_list.contains(backend)
            dedup_list += backend
        endif
    endforeach

    message('@1@:  @0@'.format(', '.join(dedup_list), ss))

    foreach backend : dedup_list
        cfg_var = 'SDL_@0@_@1@'.format(ss.to_upper(), backend.to_upper())
        cdata.set(cfg_var, 1)
        # message('Setting @0@ to 1'.format(cfg_var))
    endforeach
endforeach

core_inc = [include_directories('include')]
c_sources = []
cxx_sources = []
objc_sources = []
main_sources = []
test_c_sources = []

subdir('include')
subdir('src')
subdir('wayland-protocols')

all_sources = [c_sources]
test_all_source = [test_c_sources]

if platform_is_darwin
    add_languages('objc', native: false)
    all_sources += [objc_sources]
endif

if platform_is_winrt or platform_is_haiku
    add_languages('cpp', native: false)
    all_sources += [cxx_sources]
endif

do_install = get_option('default_library') != 'static' or not meson.is_subproject()

main_link_with = []
main_link_whole = []
main_c_args = ['-Dmain=SDL_main']

sdl2main = static_library('sdl2main',
    main_sources,
    include_directories : core_inc,
    c_args : [core_args, main_c_args],
    install : do_install,
)

if cc.get_argument_syntax() == 'msvc'
    main_link_with += sdl2main
else
    main_link_whole += sdl2main
endif

sdl2main_dep = declare_dependency(
    link_with : main_link_with,
    link_whole : main_link_whole,
    include_directories : core_inc,
    compile_args : main_c_args,
)

deps = [core_deps, extra_deps]

sdl2 = library('sdl2',
    all_sources,
    include_directories : core_inc,
    c_args : core_args,
    link_args : core_ldflags,
    dependencies : deps,
    override_options : ['c_std=none'],
    install : do_install,
    gnu_symbol_visibility: 'hidden',
)

if platform_is_windows and get_option('with_main')
    deps += sdl2main_dep
endif

sdl2_dep = declare_dependency(
    link_with : sdl2,
    dependencies : deps,
    include_directories : core_inc,
    compile_args : c_args,
)

test_deps = []

if cdata.get('HAVE_LIBUNWIND_H', 0) == 1
    test_deps += dependency('libunwind', required : false)
    test_deps += dependency('libunwind-generic', required : false)
endif

# MSVC does not correctly resolve the symbols when linking dynamically
# works fine when linking statically or MinGW
sdl2_test = static_library('sdl2_test',
    test_all_source,
    c_args : core_args,
    link_args : core_ldflags,
    dependencies : [sdl2_dep, test_deps],
    override_options : ['c_std=none'],
    build_by_default : false,
)

sdl2_test_dep = declare_dependency(
    link_with : sdl2_test,
    dependencies : [sdl2_dep],
    include_directories : core_inc,
    compile_args : c_args,
)

meson.override_dependency('sdl2', sdl2_dep)
meson.override_dependency('sdl2main', sdl2main_dep)
meson.override_dependency('sdl2_test', sdl2_test_dep)

if get_option('test')
    subdir('test')
endif
