#ifndef PRAGTICAL_WINDOWS_DARKMODE_H
#define PRAGTICAL_WINDOWS_DARKMODE_H

#ifdef _WIN32
  #include <SDL.h>
  #include <SDL_syswm.h>
  #include <stdbool.h>
  #include <windows.h>
  #include "../papi.h"

  PAPI_BEGIN_EXTERN

  PAPI void PAPICALL windows_darkmode_set_theme(SDL_Window* win, HWND hwnd, bool check_immersive);

  PAPI_END_EXTERN
#endif

#endif /* PRAGTICAL_WINDOWS_DARKMODE_H */
