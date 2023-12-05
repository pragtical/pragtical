#ifndef PRAGTICAL_RENCACHE_H
#define PRAGTICAL_RENCACHE_H

#include <stdbool.h>
#include <lua.h>
#include "renderer.h"

PAPI_BEGIN_EXTERN

PAPI void PAPICALL rencache_show_debug(bool enable);
PAPI void PAPICALL rencache_set_clip_rect(RenWindow *window_renderer, RenRect rect);
PAPI void PAPICALL rencache_draw_rect(RenWindow *window_renderer, RenRect rect, RenColor color);
PAPI double PAPICALL rencache_draw_text(RenWindow *window_renderer, RenFont **font, const char *text, size_t len, double x, double y, RenColor color);
PAPI void PAPICALL rencache_invalidate(void);
PAPI void PAPICALL rencache_begin_frame(RenWindow *window_renderer);
PAPI void PAPICALL rencache_end_frame(RenWindow *window_renderer);

PAPI_END_EXTERN

#endif /* PRAGTICAL_RENCACHE_H */
