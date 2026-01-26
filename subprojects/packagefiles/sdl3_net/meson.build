project('sdl3_net', 'c', version: '3.0.0')

cc = meson.get_compiler('c')

sdl_dep = dependency('sdl3', version: '>=3.2.4')
net_dependencies = [sdl_dep]
host = host_machine.system()

if host == 'windows'
  net_dependencies += cc.find_library('iphlpapi')
  net_dependencies += cc.find_library('ws2_32')
elif host == 'haiku'
  net_dependencies += cc.find_library('network')
endif

net_src = files(
  'src/SDL_net.c'
)

net_lib = library('sdl3_image',
  net_src,
  include_directories: 'include',
  dependencies: net_dependencies
)

sdl3_net_dep = declare_dependency(
  include_directories: 'include',
  link_with: net_lib
)
