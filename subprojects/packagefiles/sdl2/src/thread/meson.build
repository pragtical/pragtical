c_sources += files(
    'SDL_thread.c',
)

if sys_thread.length() == 0
    subdir('generic')
else
    foreach backend : sys_thread
        subdir(backend)
    endforeach
endif
