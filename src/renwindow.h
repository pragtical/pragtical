#include <SDL3/SDL.h>
#include "renderer.h"
#include "rencache.h"

struct HitTestInfo {
  int title_height;
  int controls_width;
  int resize_border;
};
typedef struct HitTestInfo HitTestInfo;

struct RenWindow {
  RenCache cache;
  float scale_x;
  float scale_y;
  HitTestInfo hit_test_info;
};
typedef struct RenWindow RenWindow;

RenWindow* renwin_create(SDL_Window *win);
void renwin_clip_to_surface(RenWindow *ren);
void renwin_set_clip_rect(RenWindow *ren, RenRect rect);
void renwin_resize_surface(RenWindow *ren);
void renwin_update_scale(RenWindow *ren);
void renwin_show_window(RenWindow *ren);
void renwin_update_rects(RenWindow *ren, RenRect *rects, int count);
void renwin_free(RenWindow *ren);
