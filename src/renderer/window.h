#include <SDL3/SDL.h>
#include "renderer/renderer.h"
#include "renderer/cache.h"

struct HitTestInfo {
  /* Renderer coordinates, converted using the current window density at hit time. */
  float title_height;
  float controls_width;
  float resize_border;
  SDL_FRect interactive_rect;
};
typedef struct HitTestInfo HitTestInfo;

struct RenWindow {
  RenCache cache;
  SDL_Window *window;
  void *backend_data;
  float scale_x;
  float scale_y;
  bool shown;
  HitTestInfo hit_test_info;
};
typedef struct RenWindow RenWindow;

RenWindow* renwin_create(SDL_Window *win);
SDL_Window* renwin_get_sdl_window(RenWindow *ren);
void renwin_clip_to_surface(RenWindow *ren);
void renwin_update_scale(RenWindow *ren);
void renwin_convert_coordinates(RenWindow *ren, float *x, float *y, bool to_renderer);
void renwin_show_window(RenWindow *ren);
void renwin_free(RenWindow *ren);
