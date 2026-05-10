#ifndef RENCACHE_H
#define RENCACHE_H

#include <stdbool.h>
#include <stdint.h>
#include "renderer.h"

/* These values represent the maximum size that can be tracked by rencache
   7680x4320 = 8k resolution, we use a common divisor for the size of regions
   that will be dirty checked.
*/
#define RENCACHE_CELL_SIZE 60 /* common divisor of width and height */
/* 128 X cells */
#define RENCACHE_CELLS_X (7680 / RENCACHE_CELL_SIZE)
/* 72 Y cells with additional 1 cell padding to prevent hash crash */
#define RENCACHE_CELLS_Y ((4320 + RENCACHE_CELL_SIZE) / RENCACHE_CELL_SIZE)

typedef struct RenCache RenCache;
typedef struct RenBackend RenBackend;
typedef RenSurface (*RenCacheGetSurfaceFn)(RenCache *rc);
typedef void (*RenCachePresentFn)(RenCache *rc, RenRect *rects, int count);

typedef struct {
  void (*set_clip_rect)(RenCache *rc, RenSurface *surface, RenRect rect);
  void (*draw_rect)(RenCache *rc, RenSurface *surface, RenRect rect, RenColor color, bool replace);
  double (*draw_text)(RenCache *rc, RenSurface *surface, RenFont **font, const char *text, size_t len, float x, float y, RenColor color, RenTab tab);
  void (*draw_poly)(RenCache *rc, RenSurface *surface, RenPoint *points, unsigned short npoints, RenColor color);
  void (*draw_canvas)(RenCache *rc, RenSurface *surface, RenCache *canvas, int x, int y);
  void (*draw_pixels)(RenCache *rc, RenSurface *surface, RenRect rect, const char *bytes, size_t len);
} RenCacheDrawOps;

struct RenCache {
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
  void *target;
  void *backend_data;
  bool window_target;
  uint64_t revision;
  RenCacheGetSurfaceFn get_surface;
  RenCachePresentFn present_rects;
  const RenBackend *backend;
  RenSurface rensurface;
};

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
