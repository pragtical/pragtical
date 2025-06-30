c_sources += files(
    'SDL_url.c',
)

if platform_is_android
    subdir('android')
elif platform_is_haiku
    subdir('haiku')
elif platform_is_ios
    subdir('ios')
elif platform_is_macos
    subdir('macosx')
elif platform_is_win32
    subdir('windows')
elif platform_is_winrt
    subdir('winrt')
elif platform_is_unixlike_or_apple and not platform_is_emscripten
    subdir('unix')
elif platform_is_vita
    subdir('vita')
else
    subdir('dummy')
endif
