
if platform_is_unixlike_or_apple
    subdir('unix')

    if cdata.get('HAVE_DBUS_DBUS_H', 0) == 1
        c_sources += files(
            'linux/SDL_dbus.c'
        )
    endif

    if cdata.get('SDL_USE_IME', 0) == 1
        c_sources += files(
            'linux/SDL_ime.c'
        )
    endif

    if cdata.get('HAVE_IBUS_IBUS_H', 0) == 1
        c_sources += files(
            'linux/SDL_ibus.c'
        )
    endif

    if cdata.get('HAVE_FCITX', 0) == 1
        c_sources += files(
            'linux/SDL_fcitx.c'
        )
    endif

    if cdata.get('HAVE_LIBUDEV_H', 0) == 1
        c_sources += files(
            'linux/SDL_udev.c'
        )
    endif

    if cdata.get('SDL_INPUT_LINUXEV', 0) == 1
        c_sources += files(
            'linux/SDL_evdev.c',
            'linux/SDL_evdev_kbd.c',
        )
    endif

    if cdata.get('SDL_INPUT_FBSDKBIO', 0) == 1
        c_sources += files(
            'freebsd/SDL_evdev_kbd_freebsd.c',
        )
    endif

    c_sources += files(
        'linux/SDL_evdev_capabilities.c',
        'linux/SDL_sandbox.c',
        'linux/SDL_threadprio.c',
    )
endif

if platform_is_android
    subdir('android')
elif platform_is_openbsd
    subdir('openbsd')
elif platform_is_windows
    subdir('windows')
    if platform_is_winrt
        subdir('winrt')
    endif
elif platform_is_os2
    subdir('os2')
endif

