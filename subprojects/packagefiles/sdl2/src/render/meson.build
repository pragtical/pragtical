c_sources += files(
    'SDL_d3dmath.c',
    'SDL_render.c',
    'SDL_yuv_sw.c',
)

subdir('direct3d')
subdir('direct3d11')
subdir('direct3d12')
subdir('opengl')
subdir('opengles')
subdir('opengles2')
subdir('psp')
subdir('software')
subdir('vitagxm')

if platform_is_macos or platform_is_ios
    subdir('metal')
endif
