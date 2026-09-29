project('sdl3_net', 'c', version: '3.2.0')

cc = meson.get_compiler('c')

sdl_dep = dependency('sdl3', version: '>=3.2.4')
net_dependencies = [sdl_dep]
net_c_args = []
host = host_machine.system()

if host == 'windows'
  net_dependencies += cc.find_library('iphlpapi')
  net_dependencies += cc.find_library('ws2_32')
  if cc.get_define('__MINGW32__') != ''
    # MinGW headers can expose CRT read/write aliases that conflict with
    # SDL_net's Windows socket helpers. Disable them only for this target.
    net_c_args += '-DNO_OLDNAMES'
  endif
elif host == 'haiku'
  net_dependencies += cc.find_library('network')
endif

net_src = files(
  'src/SDL_net.c'
)

net_lib = library('sdl3_image',
  net_src,
  include_directories: 'include',
  c_args: net_c_args,
  dependencies: net_dependencies
)

sdl3_net_dep = declare_dependency(
  include_directories: 'include',
  link_with: net_lib
)
