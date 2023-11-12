c_sources += files(
    'SDL_gamecontroller.c',
    'SDL_joystick.c',
    'controller_type.c'
)

subdir('dummy')
subdir('hidapi')
subdir('steam')
subdir('virtual')

if platform_is_android
    subdir('android')
elif platform_is_ios
    subdir('iphoneos')
elif platform_is_darwin
    subdir('darwin')
    subdir('iphoneos')
elif platform_is_linux
    subdir('linux')
elif platform_is_bsd
    subdir('bsd')
elif platform_is_emscripten
    subdir('emscripten')
elif platform_is_psp
    subdir('psp')
elif platform_is_windows
    subdir('windows')
elif platform_is_vita
    subdir('vita')
elif platform_is_os2
    subdir('os2')
endif
