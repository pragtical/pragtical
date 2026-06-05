#ifndef RENBACKEND_H
#define RENBACKEND_H

#include <stdbool.h>
#include "renatlas.h"
#include "rencache.h"

struct RenBackend {
  const char *name;
  bool (*available)(void); /* NULL = always available */
  const RenCacheDrawOps *draw_ops;
  bool (*use_full_frame_regions)(RenCache *cache);
  void (*begin_frame)(RenCache *cache, RenRect *rects, int count);
  void (*end_frame)(RenCache *cache, RenRect *rects, int count);
  void (*begin_region)(RenCache *cache, RenRect rect, bool native_only);
  void (*end_region)(RenCache *cache, RenRect rect, bool native_only);
  bool (*can_native_region)(RenCache *cache, RenSurface *surface, RenRect region);
  bool (*can_native_rect)(RenCache *cache, RenSurface *surface, RenRect rect, RenColor color, bool replace);
  bool (*can_native_text)(RenCache *cache, RenSurface *surface, RenFont **fonts, const char *text, size_t len, float x, float y, RenColor color, RenTab tab);
  bool (*can_native_canvas)(RenCache *cache, RenSurface *surface, RenCache *canvas, int x, int y);
  bool (*can_native_pixels)(RenCache *cache, RenSurface *surface, RenRect rect, const char *bytes, size_t len);
  bool (*can_native_poly)(RenCache *cache, RenSurface *surface, RenPoint *points, unsigned short npoints, RenColor color);
  RenCacheGetSurfaceFn get_window_surface;
  RenCachePresentFn present_window_rects;
  SDL_Surface *(*capture_window)(RenCache *cache, RenRect rect);
  void (*init_window)(RenWindow *window);
  void (*resize_window)(RenWindow *window);
  void (*destroy_window)(RenWindow *window);
  void (*init_canvas)(RenCache *canvas, SDL_Surface *surface);
  void (*destroy_canvas)(RenCache *canvas);
  SDL_Surface *(*get_canvas_surface)(RenCache *canvas);
  void (*get_canvas_size)(RenCache *canvas, int *width, int *height);
  void (*copy_canvas)(RenCache *dst, RenCache *src, int x, int y, bool blend);
  void (*target_updated)(RenCache *cache, RenRect *rects, int count);
  void (*init_atlas)(RenAtlas *atlas);
};

const RenBackend *renbackend_current(void);
const char *renbackend_default_name(void);
bool renbackend_select(const char *name);

#endif
