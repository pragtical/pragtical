#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include "renwindow.h"

#ifdef PRAGTICAL_USE_SDL_RENDERER
static void setup_renderer(RenWindow *ren, int w, int h) {
  /* Note that w and h here should always be in pixels and obtained from
     a call to SDL_GL_GetDrawableSize(). */
  if (!ren->renderer) {
    ren->renderer = SDL_CreateRenderer(
      ren->window, NULL, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC
    );
  }
  SDL_RendererInfo info;
  SDL_GetRendererInfo(ren->renderer, &info);
  ren->format = info.texture_formats[0];
  if (ren->rensurface.surface) {
    SDL_DestroySurface(ren->rensurface.surface);
  }
  ren->rensurface.surface = SDL_CreateSurface(w, h, ren->format);
  if (!ren->rensurface.surface) {
    fprintf(stderr, "Error creating surface: %s", SDL_GetError());
    exit(1);
  }
  if (ren->texture) {
    SDL_DestroyTexture(ren->texture);
  }
  ren->texture = SDL_CreateTexture(ren->renderer,  ren->format, SDL_TEXTUREACCESS_STREAMING, w, h);
}
#endif


void renwin_init_surface(UNUSED RenWindow *ren) {
#ifdef PRAGTICAL_USE_SDL_RENDERER
  int w, h;
  SDL_GetWindowSizeInPixels(ren->window, &w, &h);
  setup_renderer(ren, w, h);
#else
  ren->format = SDL_GetWindowSurface(ren->window)->format->format;
#endif
}


void renwin_init_command_buf(RenWindow *ren) {
  ren->command_buf = NULL;
  ren->command_buf_idx = 0;
  ren->command_buf_size = 0;
}


void renwin_clip_to_surface(RenWindow *ren) {
  SDL_SetSurfaceClipRect(renwin_get_surface(ren).surface, NULL);
}


void renwin_set_clip_rect(RenWindow *ren, RenRect rect) {
  RenSurface rs = renwin_get_surface(ren);
  SDL_SetSurfaceClipRect(rs.surface, (SDL_Rect*) &rect);
}


RenSurface renwin_get_surface(RenWindow *ren) {
#ifdef PRAGTICAL_USE_SDL_RENDERER
  return ren->rensurface;
#else
  SDL_Surface *surface = SDL_GetWindowSurface(ren->window);
  if (!surface) {
    fprintf(stderr, "Error getting window surface: %s", SDL_GetError());
    exit(1);
  }
  return (RenSurface){.surface = surface};
#endif
}

void renwin_resize_surface(UNUSED RenWindow *ren) {
#ifdef PRAGTICAL_USE_SDL_RENDERER
  int new_w, new_h;
  SDL_GetWindowSizeInPixels(ren->window, &new_w, &new_h);
  /* Note that (w, h) may differ from (new_w, new_h) on retina displays. */
  if (new_w != ren->rensurface.surface->w || new_h != ren->rensurface.surface->h) {
    renwin_init_surface(ren);
    renwin_clip_to_surface(ren);
    setup_renderer(ren, new_w, new_h);
  }
#endif
}

void renwin_show_window(RenWindow *ren) {
  SDL_ShowWindow(ren->window);
}

void renwin_update_rects(RenWindow *ren, RenRect *rects, int count) {
#ifdef PRAGTICAL_USE_SDL_RENDERER
  for (int i = 0; i < count; i++) {
    const SDL_Rect *r = (SDL_Rect*) &rects[i];
    int32_t *pixels = (
      (int32_t *) ren->rensurface.surface->pixels
    ) + r->x + ren->rensurface.surface->w * r->y;
    SDL_UpdateTexture(ren->texture,  r, pixels, ren->rensurface.surface->pitch);
  }
  SDL_RenderTexture(ren->renderer, ren->texture, NULL, NULL);
  SDL_RenderPresent(ren->renderer);
#else
  SDL_UpdateWindowSurfaceRects(ren->window, (SDL_Rect*) rects, count);
#endif
}

void renwin_free(RenWindow *ren) {
#ifdef PRAGTICAL_USE_SDL_RENDERER
  SDL_DestroyTexture(ren->texture);
  SDL_DestroyRenderer(ren->renderer);
  SDL_DestroySurface(ren->rensurface.surface);
#endif
  SDL_DestroyWindow(ren->window);
  ren->window = NULL;
}
