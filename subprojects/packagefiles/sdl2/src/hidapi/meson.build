c_sources += files(
    'SDL_hidapi.c',
)

if platform_is_android
    cxx_sources += files(
        'android/hid.cpp',
    )
elif platform_is_ios
    objc_sources += files(
        'ios/hid.m'
    )
endif
