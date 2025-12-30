#ifndef RENCACHE_H
#define RENCACHE_H

#include <stdbool.h>
#include "renderer.h"

/* These values represent the maximum size that can be tracked by rencache
   7680x4320 = 8k resolution, we use a common divisor for the size of regions
   that will be dirty checked.
*/
#define RENCACHE_CELL_SIZE 60 /* common divisor of width and height */
#define RENCACHE_CELLS_X (7680 / RENCACHE_CELL_SIZE) /* 128 cells */
#define RENCACHE_CELLS_Y (4320 / RENCACHE_CELL_SIZE) /* 72 cells */

typedef struct {
  uint8_t *command_buf;
  size_t command_buf_idx;
  size_t command_buf_size;
  unsigned cells_buf1[RENCACHE_CELLS_X * RENCACHE_CELLS_Y];
  unsigned cells_buf2[RENCACHE_CELLS_X * RENCACHE_CELLS_Y];
  unsigned *cells_prev;
  unsigned *cells;
  RenRect rect_buf[RENCACHE_CELLS_X * RENCACHE_CELLS_Y / 2];
  bool resize_issue;
  RenRect screen_rect;
  RenRect last_clip_rect;
  SDL_Window *window;   /* The cache can be used for both a window or surface */
  RenSurface rensurface;
#ifdef PRAGTICAL_USE_SDL_RENDERER
  SDL_Renderer *renderer;
  SDL_Texture *texture;
#endif
} RenCache;

void rencache_init(RenCache *rc);
void rencache_uninit(RenCache *rc);
void  rencache_show_debug(bool enable);
void  rencache_set_clip_rect(RenCache *rc, RenRect rect);
void  rencache_draw_rect(RenCache *rc, RenRect rect, RenColor color, bool replace);
double rencache_draw_text(RenCache *rc, RenFont **font, const char *text, size_t len, double x, double y, RenColor color, RenTab tab);
RenRect rencache_draw_poly(RenCache *rc, RenPoint *points, int npoints, RenColor color);
void  rencache_draw_canvas(RenCache *ren_cache, RenRect rect, RenCache *canvas);
void  rencache_draw_pixels(RenCache *ren_cache, RenRect rect, const char* bytes, size_t len);
void  rencache_invalidate(RenCache *rc);
void  rencache_begin_frame(RenCache *rc);
void  rencache_end_frame(RenCache *rc);
RenSurface rencache_get_surface(RenCache *rc);
void rencache_update_rects(RenCache *rc, RenRect *rects, int count);

#endif
