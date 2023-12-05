#ifndef PRAGTICAL_RENWINDOW_H
#define PRAGTICAL_RENWINDOW_H

#include <SDL.h>
#include "renderer.h"

struct RenWindow {
  SDL_Window *window;
  uint8_t *command_buf;
  size_t command_buf_idx;
  size_t command_buf_size;
#ifdef PRAGTICAL_USE_SDL_RENDERER
  SDL_Renderer *renderer;
  SDL_Texture *texture;
  RenSurface rensurface;
#endif
};
typedef struct RenWindow RenWindow;

PAPI_BEGIN_EXTERN

PAPI void PAPICALL renwin_init_surface(RenWindow *ren);
PAPI void PAPICALL renwin_init_command_buf(RenWindow *ren);
PAPI void PAPICALL renwin_clip_to_surface(RenWindow *ren);
PAPI void PAPICALL renwin_set_clip_rect(RenWindow *ren, RenRect rect);
PAPI void PAPICALL renwin_resize_surface(RenWindow *ren);
PAPI void PAPICALL renwin_show_window(RenWindow *ren);
PAPI void PAPICALL renwin_update_rects(RenWindow *ren, RenRect *rects, int count);
PAPI void PAPICALL renwin_free(RenWindow *ren);
PAPI RenSurface PAPICALL renwin_get_surface(RenWindow *ren);

PAPI_END_EXTERN

#endif /* PRAGTICAL_RENWINDOW_H */
