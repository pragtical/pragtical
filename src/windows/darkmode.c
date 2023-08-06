#ifdef _WIN32

#include "windows/darkmode.h"
#include <dwmapi.h>

#define WINDOWS_DARK_MODE_BEFORE_20H1 19
#define WINDOWS_DARK_MODE 20

static HWND get_window_handle(SDL_Window* window) {
  SDL_SysWMinfo sysInfo;

  SDL_VERSION(&sysInfo.version);
  SDL_GetWindowWMInfo(window, &sysInfo);
  return sysInfo.info.win.window;
}

static int dark_theme_activated() {
  DWORD type, value, count = 4;

  LSTATUS st = RegGetValue(
    HKEY_CURRENT_USER,
    TEXT("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
    TEXT("AppsUseLightTheme"),
    RRF_RT_REG_DWORD,
    &type,
    &value,
    &count
  );

  if (st == ERROR_SUCCESS && type == REG_DWORD)
    return value == 0 ? 1 : 0;

  return 0;
}

void windows_darkmode_set_theme(SDL_Window* win, HWND hwnd, bool check_immersive) {
  HWND handle = win ? get_window_handle(win) : hwnd;
  int current_immersive_mode = 0;
  int current_mode = dark_theme_activated();

  if (check_immersive)
    if(DwmGetWindowAttribute(handle, WINDOWS_DARK_MODE_BEFORE_20H1, &current_immersive_mode, 4) != FACILITY_NULL)
      DwmGetWindowAttribute(handle, WINDOWS_DARK_MODE, &current_immersive_mode, 4);

  if (current_mode != current_immersive_mode)
    if (DwmSetWindowAttribute(handle, WINDOWS_DARK_MODE_BEFORE_20H1, &current_mode, 4) != 0)
      DwmSetWindowAttribute(handle, WINDOWS_DARK_MODE, &current_mode, 4);
}

#endif
