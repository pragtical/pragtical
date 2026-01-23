img_src = files(
  'IMG.c',
  'IMG_ani.c',
  'IMG_anim_decoder.c',
  'IMG_anim_encoder.c',
  'IMG_avif.c',
  'IMG_bmp.c',
  'IMG_gif.c',
  'IMG_gpu.c',
  'IMG_jpg.c',
  'IMG_jxl.c',
  'IMG_lbm.c',
  'IMG_libpng.c',
  'IMG_pcx.c',
  'IMG_png.c',
  'IMG_pnm.c',
  'IMG_qoi.c',
  'IMG_stb.c',
  'IMG_svg.c',
  'IMG_tga.c',
  'IMG_tif.c',
  'IMG_webp.c',
  'IMG_xcf.c',
  'IMG_xpm.c',
  'IMG_xv.c',
  'xmlman.c'
)

# TODO: this requires disabling other decoders so leave it as is for now
# if host_machine.system() == 'windows'
#   img_src += 'IMG_WIC.c'
#   img_dependencies += cc.find_library('WindowsCodecs')
#   img_dependencies += cc.find_library('Ole32')
# elif host_machine.system() == 'darwin'
#   img_src += 'IMG_ImageIO.m'
#   img_dependencies += dependency(
#     'appleframeworks',
#     modules : ['ImageIO', 'CoreFoundation', 'ApplicationServices']
#   )
# endif
