/*
 * This file contains a collection of functions specifically designed for
 * interoperability with LuaJIT's Foreign Function Interface (FFI).
 *
 * What we Gain? An overhead reduction of ~90%!
 *
 * Key Features:
 * - All functions in this file accept only primitive type parameters
 *   (e.g., integers, floats, etc.) to ensure efficient data handling
 *   and minimize overhead during function calls.
 * - No structures are passed by value, as this would introduce
 *   unnecessary copying and degrade performance. Also, the generation and
 *   conversion of structs using LuaJIT ffi introduces overhead.
 *
 * Performance Considerations:
 * - The idea of these functions is to prioritizes low call overhead,
 * - The original function:
 *     rencache_draw_rect(RenWindow *window_renderer, RenRect rect, RenColor color);
 *   has a specialized FFI version:
 *     rencache_draw_rect_ffi(RenWindow *window_renderer, float x, float y, float w, float h, unsigned char r, unsigned char g, unsigned char b, unsigned char a)
 *   Instead of calling `rencache_draw_rect` from within `rencache_draw_rect_ffi`,
 *   the same rendering logic could be re-implemented directly in
 *   `rencache_draw_rect_ffi`. This approach eliminates a bit more of overhead
 *   that comes from the additional function call, but for now we just call
 *   the original.
 *
 * Reminder:
 * - The function exports (eg: ren_get_target_window) could be directly
 *   done on the targeted functions (less over head) but, to keep things
 *   separate we do it this way (for now).
 */

#include "renderer.h"
#include "rencache.h"

#if defined(_WIN32)
  #define EXPORT __declspec(dllexport)
#elif defined(__GNUC__) || defined(__clang__)
  #define EXPORT __attribute__((visibility("default")))
#else
  #define EXPORT
#endif

static inline RenRect rect_to_grid(float x, float y, float w, float h) {
  int x1 = (int) (x + 0.5), y1 = (int) (y + 0.5);
  int x2 = (int) (x + w + 0.5), y2 = (int) (y + h + 0.5);
  return (RenRect) {x1, y1, x2 - x1, y2 - y1};
}

EXPORT RenWindow* ren_get_target_window_ffi(void)
{
  return ren_get_target_window();
}

EXPORT void rencache_set_clip_rect_ffi(RenWindow *window_renderer, float x, float y, float w, float h) {
  RenRect rect = rect_to_grid(x, y, w, h);
  rencache_set_clip_rect(window_renderer, rect);
}

EXPORT void rencache_draw_rect_ffi(RenWindow *window_renderer, float x, float y, float w, float h, unsigned char r, unsigned char g, unsigned char b, unsigned char a)
{
  RenRect rect = rect_to_grid(x, y, w, h);
  RenColor color = {.r = r, .g = g, .b = b, .a = a};
  rencache_draw_rect(window_renderer, rect, color);
}

EXPORT double rencache_draw_text_ffi(RenWindow *window_renderer, RenFont **fonts, const char *text, size_t len, double x, double y, unsigned char r, unsigned char g, unsigned char b, unsigned char a, double tab_offset)
{
  RenColor color = {.r = r, .g = g, .b = b, .a = a};
  RenTab tab = {.offset = tab_offset};
  return rencache_draw_text(window_renderer, fonts, text, len, x, y, color, tab);
}

EXPORT void rencache_begin_frame_ffi(RenWindow *window_renderer)
{
  ren_set_target_window(window_renderer);
  rencache_begin_frame(window_renderer);
}

EXPORT void rencache_end_frame_ffi()
{
  RenWindow *window = ren_get_target_window();
  rencache_end_frame(window);
  ren_set_target_window(NULL);
}

EXPORT double system_get_time_ffi()
{
  return SDL_GetPerformanceCounter() / (double) SDL_GetPerformanceFrequency();
}

EXPORT void system_sleep_ffi(unsigned int ms)
{
  SDL_Delay(ms * 1000);
}

EXPORT bool system_wait_event_ffi(double n) {
  if (n != -1)
    return SDL_WaitEventTimeout(NULL, (n < 0 ? 0 : n) * 1000);
  return SDL_WaitEvent(NULL);
}
