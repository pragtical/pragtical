project('fixture', 'c', version: '1.0.0')

cc = meson.get_compiler('c')
config = configuration_data()
config.set('HAVE_STDIO', cc.has_header('stdio.h'))

lib = static_library('fixture', 'fixture.c',
  include_directories: include_directories('include'))

executable('fixture-test', 'test.c',
  link_with: lib,
  install: false)
