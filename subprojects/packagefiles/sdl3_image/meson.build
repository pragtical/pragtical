project('sdl3_image', 'c', version: '3.4.0')

sdl_dep = dependency('sdl3', version: '>=3.4.0')

img_args = []
img_dependencies = [sdl_dep]

if host_machine.system() == 'windows'
  libprefix = ''
  libext = '.dll'
elif host_machine.system() == 'darwin'
  libprefix = 'lib'
  libext = '.dylib'
else
  libprefix = 'lib'
  libext = '.so'
endif

# Enable stb for jpg and png support
img_args += '-DUSE_STBIMAGE'

# Enable common backend on macOS (for now)
img_args += '-DSDL_IMAGE_USE_COMMON_BACKEND'

# AVIF
avif_dep = dependency('libavif', required: false)
if avif_dep.found()
  img_args += '-DLOAD_AVIF'
  img_args += '-DLOAD_AVIF_DYNAMIC="@0@avif@1@"'.format(libprefix, libext)
endif

# BMP
img_args += '-DLOAD_BMP'

# GIF
img_args += '-DLOAD_GIF'

# JPEG
img_args += '-DLOAD_JPG'

# JXL
jxl_dep = dependency('libjxl', required: false)
if jxl_dep.found()
  img_args += '-DLOAD_JXL'
  img_args += '-DLOAD_JXL_DYNAMIC="@0@jxl@1@"'.format(libprefix, libext)
endif

# LBM
img_args += '-DLOAD_LBM'

# PCX
img_args += '-DLOAD_PCX'

# PNG
img_args += '-DLOAD_PNG'

# PNM
img_args += '-DLOAD_PNM'

# QOI
img_args += '-DLOAD_QOI'

# SVG
img_args += '-DLOAD_SVG'

# TGA
img_args += '-DLOAD_TGA'

# TIFF
if host_machine.system() != 'darwin'
  tiff_dep = dependency('libtiff', 'libtiff-4', required: false)
  if tiff_dep.found()
    img_args += '-DLOAD_TIF'
    img_args += '-DLOAD_TIF_DYNAMIC="@0@tiff@1@"'.format(libprefix, libext)
  endif
endif

# WEBP - seems to require more effort since it is not working :-(
webp_dep = dependency('libwebp', required: false)
webpmux_dep = dependency('libwebpmux', required: false)
webpdemux_dep = dependency('libwebpdemux', required: false)
if webp_dep.found() and webpdemux_dep.found() and webpmux_dep.found()
  img_args += '-DLOAD_WEBP'
  img_args += '-DLOAD_WEBP_DYNAMIC="@0@webp@1@"'.format(libprefix, libext)
  img_args += '-DLOAD_WEBPMUX_DYNAMIC="@0@webpmux@1@"'.format(libprefix, libext)
  img_args += '-DLOAD_WEBPDEMUX_DYNAMIC="@0@webpdemux@1@"'.format(libprefix, libext)
endif

# XCF
img_args += '-DLOAD_XCF'

# XPM
img_args += '-DLOAD_XPM'

# XV
img_args += '-DLOAD_XV'


subdir('src')

img_lib = library('sdl3_image',
  img_src,
  c_args: img_args,
  include_directories: 'include',
  dependencies: img_dependencies
)

sdl3_image_dep = declare_dependency(
  include_directories: 'include',
  link_with: img_lib
)
