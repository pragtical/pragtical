#ifndef WINDOWS_DARKMODE_H
#define WINDOWS_DARKMODE_H

#ifdef _WIN32
  #include <SDL.h>
  #include <SDL_syswm.h>
  #include <stdbool.h>
  #include <windows.h>

  void windows_darkmode_set_theme(SDL_Window* win, HWND hwnd, bool check_immersive);
#endif

#endif
