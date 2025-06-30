c_sources += files(
    'SDL_locale.c',
)

if enabled_subsystems.contains('locale')
    if platform_is_android
        subdir('android')
    elif platform_is_emscripten
        subdir('emscripten')
    elif platform_is_haiku
        subdir('haiku')
    elif platform_is_macos
        subdir('macosx')
    elif platform_is_win32
        subdir('windows')
    elif platform_is_winrt
        subdir('winrt')
    else
        subdir('dummy')
    endif
else
    subdir('dummy')
endif
