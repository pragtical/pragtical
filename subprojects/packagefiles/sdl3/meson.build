project('sdl3', 'c', version : '3.0.0')

cc = meson.get_compiler('c')

cmake_command = find_program('cmake', required: true)

# Configure SDL3 project
conf_command = [cmake_command, '-B', 'build', '-G', 'Ninja']

conf_command += [
    '--install-prefix', meson.current_source_dir() + '/output',
    '-DCMAKE_BUILD_TYPE=Release',
    '-DSDL_STATIC=ON',
    '-DSDL_LOADSO=ON',
    '-DSDL_VIDEO=ON',
    '-DSDL_ATOMIC=ON',
    '-DSDL_THREADS=ON',
    '-DSDL_TIMERS=ON',
    '-DSDL_EVENTS=ON',
    '-DSDL_SHARED=OFF',
    '-DSDL_TEST=OFF',
    '-DSDL_SENSOR=OFF',
    '-DSDL_HAPTIC=OFF',
    '-DSDL_AUDIO=OFF',
    '-DSDL_CPUINFO=OFF',
    '-DSDL_JOYSTICK=OFF',
    '-DSDL_VULKAN=OFF',
    '-DSDL_OFFSCREEN=OFF',
    '-DSDL_POWER=OFF'
]

if host_machine.system() == 'darwin'
    conf_command += '-DCMAKE_OSX_DEPLOYMENT_TARGET=10.11'
endif

if host_machine.system() == 'darwin' or host_machine.system() == 'windows'
    conf_command += '-DSDL_X11=OFF'
    conf_command += '-DSDL_WAYLAND=OFF'
endif

if host_machine.system() == 'windows'
    conf_command += '-DSDL_OPENGL=OFF'
    conf_command += '-DSDL_OPENGLES=OFF'
endif

if meson.is_cross_build() and host_machine.system() == 'darwin'
    conf_command += '-DCMAKE_OSX_ARCHITECTURES=arm64'
endif

conf = run_command(conf_command, check: false)

if conf.stdout() != ''
    message('SDL Conf: @0@'.format(conf.stdout()))
endif
if conf.stderr() != ''
    message('SDL Conf Errors: @0@'.format(conf.stderr()))
endif

# Build sdl3 command
build_command = [cmake_command, '--build', 'build']

build = run_command(build_command, check: false)

if build.stdout() != ''
    message('SDL Build: @0@'.format(build.stdout()))
endif
if build.stderr() != ''
    message('SDL Build Errors: @0@'.format(build.stderr()))
endif

# Install Library
run_command([cmake_command, '--install', 'build'])

# List build files
ls_command = find_program('ls', required: false)

if ls_command.found()
    ls = run_command([ls_command, 'build'], check: false)

    if ls.stdout() != ''
        message('Build Files List: @0@'.format(ls.stdout()))
    endif
    if ls.stderr() != ''
        message('Build Files List Errors: @0@'.format(ls.stderr()))
    endif

    install_ls = run_command([ls_command, '-R', 'output'], check: false)

    if install_ls.stdout() != ''
        message('Install Files List: @0@'.format(install_ls.stdout()))
    endif
    if install_ls.stderr() != ''
        message('Install Files List Errors: @0@'.format(install_ls.stderr()))
    endif
endif

# Output package config file
cat_command = find_program('cat', required: false)

if cat_command.found()
    cat = run_command([cat_command, 'build/sdl3.pc'], check: false)
    if cat.stdout() != ''
        message('PKG Config File: @0@'.format(cat.stdout()))
    endif
    if cat.stderr() != ''
        message('PKG Config File Error: @0@'.format(cat.stderr()))
    endif
endif

# Expose library

sdl_compile_args = []
sdl_link_args = []

if host_machine.system() == 'darwin'
    sdl_compile_args += '-D_THREAD_SAFE'
    sdl_link_args += [
        '-framework', 'CoreVideo',
        '-framework', 'Cocoa',
        '-framework', 'Carbon',
        '-framework', 'Foundation',
        '-framework', 'IOKit',
        '-weak_framework', 'Metal',
        '-weak_framework', 'QuartzCore',
        '-lm'
    ]
elif host_machine.system() == 'windows'
    if cc.get_id() != 'msvc'
        sdl_link_args += '-mwindows'
    else
        sdl_compile_args += '-DPRAGTICAL_MVSC_WINMAIN'
    endif

    sdl_link_args += [
        '-luser32', '-lgdi32', '-lwinmm', '-limm32', '-lole32', '-loleaut32',
        '-lversion', '-luuid', '-ladvapi32', '-lsetupapi', '-lshell32'
    ]
else
    sdl_compile_args += '-D_REENTRANT'
    sdl_link_args += ['-pthread', '-lm']
endif

sdl_libname = 'SDL3'
if cc.get_id() == 'msvc'
    sdl_libname = 'SDL3-static'
endif

sdl3 = cc.find_library(sdl_libname,
    dirs : [ meson.current_source_dir() + '/build'],
    required : true,
    static : true
)

sdl3_dep = declare_dependency(
    dependencies: sdl3,
    include_directories: include_directories(
        'output/include', 'output/include/SDL3'
    ),
    compile_args: sdl_compile_args,
    link_args: sdl_link_args
)
