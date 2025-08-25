#ifndef RENCACHE_H
#define RENCACHE_H

#include <stdbool.h>
#include "renderer.h"

void rencache_init(RenCache *rc);
void rencache_uninit(RenCache *rc);
void  rencache_show_debug(bool enable);
void  rencache_set_clip_rect(RenCache *rc, RenRect rect);
void  rencache_draw_rect(RenCache *rc, RenRect rect, RenColor color);
double rencache_draw_text(RenCache *rc, RenFont **font, const char *text, size_t len, double x, double y, RenColor color, RenTab tab);
RenRect rencache_draw_poly(RenCache *rc, RenPoint *points, int npoints, RenColor color);
void  rencache_draw_canvas(RenWindow *window_renderer, RenRect rect, RenCanvasRef *canvas_ref, size_t version);
void  rencache_invalidate(RenCache *rc);
void  rencache_begin_frame(RenCache *rc);
void  rencache_end_frame(RenCache *rc);
RenSurface rencache_get_surface(RenCache *rc);
void rencache_update_rects(RenCache *rc, RenRect *rects, int count);

#endif
