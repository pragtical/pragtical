project('pragtical',
    ['c'],
    version : '3.2.1',
    license : 'MIT',
    meson_version : '>= 0.56',
    default_options : [
        'c_std=gnu11',
        'wrap_mode=nofallback'
    ]
)

version = meson.project_version()

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

#===============================================================================
# Compiler Settings
#===============================================================================
if host_machine.system() == 'darwin'
    add_languages('objc')
endif

cc = meson.get_compiler('c')

pragtical_includes = []
pragtical_cargs = ['-DSDL_MAIN_HANDLED', '-DPCRE2_STATIC']
# On macos we need to use the SDL renderer to support retina displays
if get_option('renderer') or host_machine.system() == 'darwin'
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
        ]

        foreach lua : lua_names
            last_lua = (lua == lua_names[-1] or get_option('wrap_mode') == 'forcefallback')
            lua_dep = dependency(lua, fallback: last_lua ? ['lua', 'lua_dep'] : [], required : false,
                version: '>= 5.4',
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
        default_options: default_fallback_options + ['default_library=static']
    )

    sdl_options = ['default_library=static']

    # we explicitly need these
    sdl_options += 'use_loadso=enabled'
    sdl_options += 'prefer_dlopen=true'
    sdl_options += 'use_video=enabled'
    sdl_options += 'use_atomic=enabled'
    sdl_options += 'use_threads=enabled'
    sdl_options += 'use_timers=enabled'
    sdl_options += 'with_main=true'
    # investigate if this is truly needed
    # Do not remove before https://github.com/libsdl-org/SDL/issues/5413 is released
    sdl_options += 'use_events=enabled'

    if host_machine.system() == 'darwin' or host_machine.system() == 'windows'
        sdl_options += 'use_video_x11=disabled'
        sdl_options += 'use_video_wayland=disabled'
    else
        sdl_options += 'use_render=enabled'
        sdl_options += 'use_video_x11=auto'
        sdl_options += 'use_video_wayland=auto'
    endif

    # we leave this up to what the host system has except on windows
    if host_machine.system() != 'windows'
        sdl_options += 'use_video_opengl=auto'
        sdl_options += 'use_video_openglesv2=auto'
    else
        sdl_options += 'use_video_opengl=disabled'
        sdl_options += 'use_video_openglesv2=disabled'
    endif

    # we don't need these
    sdl_options += 'test=false'
    sdl_options += 'use_sensor=disabled'
    sdl_options += 'use_haptic=disabled'
    sdl_options += 'use_audio=disabled'
    sdl_options += 'use_cpuinfo=disabled'
    sdl_options += 'use_joystick=disabled'
    sdl_options += 'use_video_vulkan=disabled'
    sdl_options += 'use_video_offscreen=disabled'
    sdl_options += 'use_power=disabled'

    sdl_dep = dependency('sdl2', fallback: ['sdl2', 'sdl2_dep'],
        default_options: default_fallback_options + sdl_options
    )

    if host_machine.system() == 'windows'
        if sdl_dep.type_name() == 'internal'
            sdlmain_dep = dependency('sdl2main', fallback: ['sdl2main_dep'])
        else
            sdlmain_dep = cc.find_library('SDL2main')
        endif
    else
        sdlmain_dep = dependency('', required: false)
    endif

    pragtical_deps = [lua_dep, sdl_dep, sdlmain_dep, freetype_dep, pcre2_dep, uchardet_dep, libm, libdl, librt]
endif

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
    configure_file(
        input: 'resources/windows/pragtical.exe.manifest.in',
        output: 'pragtical.exe.manifest',
        configuration: conf_data
    )
elif get_option('bundle') and host_machine.system() == 'darwin'
    pragtical_cargs += '-DMACOS_USE_BUNDLE'
    pragtical_bindir = 'Contents/MacOS'
    pragtical_docdir = 'Contents/Resources'
    pragtical_datadir = 'Contents/Resources'
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
        install_data('resources/linux/org.pragtical.pragtical.desktop',
            install_dir : 'share/applications'
        )
        install_data('resources/linux/org.pragtical.pragtical.appdata.xml',
            install_dir : 'share/metainfo'
        )
    endif
endif

install_data('licenses/licenses.md', install_dir : pragtical_docdir)

install_subdir('docs/api' , install_dir : pragtical_datadir, strip_directory: true)
install_subdir('data/core' , install_dir : pragtical_datadir, exclude_files : 'start.lua')

data_dirs = ['fonts', 'plugins', 'colors', 'widget']
if lua_jit_found
    data_dirs += ['compat']
endif
foreach data_module : data_dirs
    install_subdir(join_paths('data', data_module), install_dir : pragtical_datadir)
endforeach

# Pull in widgets if necessary
fs = import('fs')
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
