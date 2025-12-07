project('pragtical',
    ['c'],
    version : '3.7.1',
    license : 'MIT',
    meson_version : '>= 0.63',
    default_options : [
        'c_std=gnu11',
        'wrap_mode=nofallback'
    ]
)

version = meson.project_version()
mod_version = version.split('.')
cc = meson.get_compiler('c')

#===============================================================================
# Enable static linking on windows
#===============================================================================
if host_machine.system() == 'windows'
    use_forcefallback = get_option('wrap_mode') == 'forcefallback'
    use_static_sys_libs = cc.get_id() == 'gcc' or cc.get_id() == 'clang'
    if use_forcefallback and use_static_sys_libs
        add_global_link_arguments(['-static'], language: ['c', 'cpp'])
    endif
endif

#===============================================================================
# System dependency settings
#===============================================================================
use_system_lua = get_option('use_system_lua')

#===============================================================================
# If jit enabled search for luajit first to properly set project version
#===============================================================================
lua_jit_found = false
if get_option('jit')
    if not use_system_lua
        luajit_dep = subproject(
            'luajit',
            default_options: ['default_library=static']
        ).get_variable('luajit_dep')
    else
        luajit_dep = dependency('luajit', required : false,
            default_options: ['default_library=static']
        )
    endif

    if luajit_dep.found()
        lua_jit_found = true
        version += '-jit'
    endif
endif

#===============================================================================
# Project version including git commit if possible
#===============================================================================
if get_option('buildtype') != 'release'
    git_command = find_program('git', required : false)

    if git_command.found()
        git_commit = run_command(
            [git_command, 'rev-parse', 'HEAD'],
            check : false
        ).stdout().strip()

        if git_commit != ''
            version += ' (git-' + git_commit.substring(0, 8) + ')'
        endif
    endif
endif

#===============================================================================
# Configuration
#===============================================================================
conf_data = configuration_data()
conf_data.set('PROJECT_BUILD_DIR', meson.current_build_dir())
conf_data.set('PROJECT_SOURCE_DIR', meson.current_source_dir())
conf_data.set('PROJECT_VERSION', version)
conf_data.set('PROJECT_ASSEMBLY_VERSION', meson.project_version() + '.0')
conf_data.set('MOD_VERSION_MAJOR', mod_version[0])
conf_data.set('MOD_VERSION_MINOR', mod_version[1])
conf_data.set('MOD_VERSION_PATCH', mod_version[2])

#===============================================================================
# Compiler Settings
#===============================================================================
if host_machine.system() == 'darwin'
    add_languages('objc')
endif

pragtical_includes = []
pragtical_cargs = [
    '-DPCRE2_STATIC',
    '-DPRAGTICAL_PROJECT_VERSION_STR="@0@"'.format(version)
]
if get_option('renderer')
    pragtical_cargs += '-DPRAGTICAL_USE_SDL_RENDERER'
endif
if get_option('arch_tuple') != ''
    arch_tuple = get_option('arch_tuple')
else
    arch_tuple = '@0@-@1@'.format(target_machine.cpu_family(), target_machine.system())
endif
pragtical_cargs += '-DPRAGTICAL_ARCH_TUPLE="@0@"'.format(arch_tuple)

#===============================================================================
# Linker Settings
#===============================================================================
pragtical_link_args = []
if host_machine.system() == 'darwin'
    pragtical_link_args += ['-framework', 'CoreServices', '-framework', 'Foundation']
endif

#===============================================================================
# Dependencies
#===============================================================================
if not get_option('source-only')
    libm = cc.find_library('m', required : false)
    libdl = cc.find_library('dl', required : false)
    librt = cc.find_library('rt', required : false)

    default_fallback_options = ['warning_level=0', 'werror=false']

    if not use_system_lua and not lua_jit_found
        lua_dep = subproject('lua',
        default_options: default_fallback_options + [
                'default_library=static',
                'line_editing=disabled',
                'interpreter=false'
            ]
        ).get_variable('lua_dep')
    elif not lua_jit_found
        # Lua has no official .pc file
        # so distros come up with their own names
        lua_names = [
            'lua5.4', # Debian
            'lua-5.4', # FreeBSD
            'lua',    # Fedora
            'lua5.3', # Debian
            'lua-5.3', # FreeBSD
            'lua5.2', # Debian
            'lua-5.2', # FreeBSD
        ]

        foreach lua : lua_names
            last_lua = (lua == lua_names[-1] or get_option('wrap_mode') == 'forcefallback')
            lua_dep = dependency(lua, fallback: last_lua ? ['lua', 'lua_dep'] : [], required : false,
                version: '>= 5.2',
                default_options: default_fallback_options + ['default_library=static', 'line_editing=false', 'interpreter=false']
            )
            if lua_dep.found()
                break
            endif

            if last_lua
                # If we could not find lua on the system and fallbacks are disabled
                # try the compiler as a last ditch effort, since Lua has no official
                # pkg-config support.
                lua_dep = cc.find_library('lua', required : true)
            endif
        endforeach
    else
        lua_dep = luajit_dep
        pragtical_cargs += '-DLUA_JIT'
    endif

    pcre2_dep = dependency('libpcre2-8', fallback: ['pcre2', 'libpcre2_8'],
        default_options: default_fallback_options + ['default_library=static', 'grep=false', 'test=false']
    )

    freetype_dep = dependency('freetype2', fallback: ['freetype2', 'freetype_dep'],
        default_options: default_fallback_options + ['default_library=static', 'zlib=disabled', 'bzip2=disabled', 'png=disabled', 'harfbuzz=disabled', 'brotli=disabled']
    )

    uchardet_dep = dependency('uchardet', fallback: ['uchardet', 'uchardet_dep'],
        default_options: default_fallback_options + ['default_library=static', 'test=false']
    )

    if get_option('wrap_mode') != 'forcefallback'
        sdl_dep = dependency('sdl3')
        sdl_uclibc_dep = dependency('', required: false)
    else
        cmake = import('cmake')

        sdl_build_type = 'Release'
        if get_option('buildtype') == 'debug'
            sdl_build_type = 'Debug'
        endif

        sdl_x11 = 'ON'
        sdl_wayland = 'ON'
        if host_machine.system() == 'windows' or host_machine.system() == 'darwin'
            sdl_x11 = 'OFF'
            sdl_wayland = 'OFF'
        endif

        sdl_opengl = 'ON'
        sdl_opengles = 'ON'
        if host_machine.system() == 'windows'
            sdl_opengl = 'OFF'
            sdl_opengles = 'OFF'
        endif

        sdl_osx_deploy_target = '10.11'
        if host_machine.system() == 'darwin' and target_machine.cpu_family() == 'aarch64'
            sdl_osx_deploy_target = '11.0'
        endif

        sdl_options = cmake.subproject_options()

        sdl_options.add_cmake_defines({
            'CMAKE_BUILD_TYPE': sdl_build_type,
            'CMAKE_POSITION_INDEPENDENT_CODE': 'ON',
            'CMAKE_OSX_DEPLOYMENT_TARGET': sdl_osx_deploy_target,
            'SDL_DEPS_SHARED': 'ON', 'SDL_SHARED': 'OFF', 'SDL_STATIC': 'ON',
            'SDL_DBUS': 'ON', 'SDL_IBUS': 'ON', 'SDL_AUDIO': 'OFF',
            'SDL_GPU': 'OFF', 'SDL_RPATH': 'OFF', 'SDL_PIPEWIRE': 'OFF',
            'SDL_CAMERA': 'OFF', 'SDL_JOYSTICK': 'OFF', 'SDL_HAPTIC': 'OFF',
            'SDL_HIDAPI': 'OFF', 'SDL_DIALOG': 'ON', 'SDL_POWER': 'OFF',
            'SDL_SENSOR': 'OFF', 'SDL_VULKAN': 'OFF', 'SDL_LIBUDEV': 'ON',
            'SDL_X11': sdl_x11, 'SDL_WAYLAND': sdl_wayland, 'SDL_TESTS': 'OFF',
            'SDL_OPENGL': sdl_opengl, 'SDL_OPENGLES': sdl_opengles,
            'SDL_DIRECTX': 'ON', 'SDL_EXAMPLES': 'OFF',
            'SDL_VENDOR_INFO': 'pragtical'
        })

        sdl = cmake.subproject('sdl3', options: sdl_options)

        sdl_dep = sdl.dependency('SDL3-static')
        sdl_uclibc_dep = sdl.dependency('SDL_uclibc')

        meson.override_dependency('sdl3', sdl_dep)
    endif

    sdl_image = dependency('SDL3_image', fallback: ['sdl3_image', 'sdl3_image_dep'],
        default_options: default_fallback_options + ['default_library=static']
    )

    pragtical_deps = [lua_dep, sdl_dep, sdl_uclibc_dep, sdl_image, freetype_dep, pcre2_dep, uchardet_dep, libm, libdl, librt]
endif

lua_compat_needed = lua_dep.version() < '5.3.0'

#===============================================================================
# Check for X11 existence to detect scale factor when video driver is x11
#===============================================================================
if host_machine.system() != 'darwin' and cc.find_library('X11', required : false).found()
    pragtical_cargs += '-DX11_FOUND'
endif

#===============================================================================
# Install Configuration
#===============================================================================
if get_option('portable') or host_machine.system() == 'windows'
    pragtical_bindir = '/'
    pragtical_docdir = '/doc'
    pragtical_datadir = '/data'
    if host_machine.system() == 'windows'
        configure_file(
            input: 'resources/windows/pragtical.exe.manifest.in',
            output: 'pragtical.exe.manifest',
            configuration: conf_data
        )
    endif
    install_data('resources/portable/README.md',
        install_dir : pragtical_bindir / 'user'
    )
elif get_option('bundle') and host_machine.system() == 'darwin'
    pragtical_cargs += '-DMACOS_USE_BUNDLE'
    pragtical_bindir = 'Contents/MacOS'
    pragtical_docdir = 'Contents/Resources'
    pragtical_datadir = 'Contents/Resources'
    conf_data.set(
        'CURRENT_YEAR',
        run_command('date', '+%Y', capture: true).stdout().strip()
    )
    install_data('resources/icons/icon.icns', install_dir : 'Contents/Resources')
    configure_file(
        input : 'resources/macos/Info.plist.in',
        output : 'Info.plist',
        configuration : conf_data,
        install : true,
        install_dir : 'Contents'
    )
else
    pragtical_bindir = 'bin'
    pragtical_docdir = 'share/doc/pragtical'
    pragtical_datadir = 'share/pragtical'
    if host_machine.system() == 'linux'
        install_data('resources/icons/logo.svg',
            install_dir : 'share/icons/hicolor/scalable/apps',
            rename : 'pragtical.svg'
        )
        install_data('resources/linux/dev.pragtical.Pragtical.desktop',
            install_dir : 'share/applications'
        )
        install_data('resources/linux/dev.pragtical.Pragtical.appdata.xml',
            install_dir : 'share/metainfo'
        )
    endif
endif

install_data('licenses/licenses.md', install_dir : pragtical_docdir)

install_subdir('docs/api' , install_dir : pragtical_datadir, strip_directory: true)
install_subdir('data/core' , install_dir : pragtical_datadir, exclude_files : 'start.lua')

fs = import('fs')

data_dirs = ['fonts', 'plugins', 'colors', 'widget']
if lua_compat_needed
    data_dirs += ['compat']
endif
foreach data_module : data_dirs
    module_path = 'data' / data_module
    if fs.exists(module_path)
        install_subdir(module_path, install_dir : pragtical_datadir)
    else
        install_emptydir(pragtical_datadir / data_module)
    endif
endforeach

# Pull in widgets if necessary
if not fs.exists('data/widget/init.lua')
    subproject('widget', default_options: ['data_dir='+pragtical_datadir])
endif

# Pull extra colors
if get_option('extra_colors')
    subproject('colors', default_options: ['data_dir='+pragtical_datadir])
endif

# Pull extra languages
if get_option('extra_languages')
    subproject('plugins', default_options: ['data_dir='+pragtical_datadir])
endif

# Include the plugin manager
if get_option('ppm')
    default_ppm_options = ['data_dir='+pragtical_datadir, 'arch_tuple='+arch_tuple]
    if get_option('wrap_mode') == 'forcefallback'
        default_ppm_options += 'prefer_static=true'
    endif
    subproject('ppm', default_options: default_ppm_options)
endif

configure_file(
    input : 'data/core/start.lua',
    output : 'start.lua',
    configuration : conf_data,
    install_dir : join_paths(pragtical_datadir, 'core'),
)

if not get_option('source-only')
    subdir('src')
    subdir('scripts')
endif
