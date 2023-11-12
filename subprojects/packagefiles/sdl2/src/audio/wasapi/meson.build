
if platform_is_windows
    c_sources += files(
        'SDL_wasapi.c',
    )

    if platform_is_win32
        c_sources += files(
            'SDL_wasapi_win32.c',
        )
    elif platform_is_winrt
        cxx_sources += files(
            'SDL_wasapi_winrt.c',
        )
    endif
endif
