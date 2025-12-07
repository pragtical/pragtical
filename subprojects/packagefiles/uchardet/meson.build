project(
    'uchardet',
    ['c', 'cpp'],
    version: '0.0.8',
    license: ['MPL-1.1', 'GPL-2.0-or-later', '  LGPL-2.1-or-later'],
    meson_version: '>=0.53.0',
    default_options: ['cpp_std=c++14', 'warning_level=1'],
)

base_cpp_args = []

cxx = meson.get_compiler('cpp')
host_cpu_family = host_machine.cpu_family()

use_sse2 = not get_option('use_sse2').disabled()

if cxx.get_argument_syntax() == 'msvc'
  add_project_arguments('-D_CRT_SECURE_NO_WARNINGS', cxx.get_supported_arguments('-Wno-deprecated-declarations'), language: 'c')
  add_project_arguments('-D_CRT_SECURE_NO_WARNINGS', cxx.get_supported_arguments('-Wno-deprecated-declarations'), language: 'cpp')
endif

# these cppflags only make sense on the x86 architecture
# and are only available on gcc and toolchains that copy gcc's behavior
if host_cpu_family in ['x86_64', 'x86'] and cxx.get_argument_syntax() != 'msvc'
    if use_sse2
        base_cpp_args += cxx.get_supported_arguments('-msse2', '-mfpmath=sse')
    else
        base_cpp_args += cxx.get_supported_arguments('-ffloat-store')
    endif
endif

subdir('src')

if get_option('test')
    subdir('test')
endif
