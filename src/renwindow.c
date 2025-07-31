#include <math.h>
#include <stdlib.h>
#include <assert.h>
#include <stdio.h>
#include "renwindow.h"

#ifdef PRAGTICAL_USE_SDL_RENDERER
static void query_surface_scale(RenWindow *ren, float* scale_x, float* scale_y) {
  int w_pixels, h_pixels;
  int w_points, h_points;
  SDL_GetWindowSizeInPixels(ren->window, &w_pixels, &h_pixels);
  SDL_GetWindowSize(ren->window, &w_points, &h_points);
  float scaleX = (float) w_pixels / (float) w_points;
  float scaleY = (float) h_pixels / (float) h_points;
  if(scale_x)
    *scale_x = round(scaleX * 100) / 100;
  if(scale_y)
    *scale_y = round(scaleY * 100) / 100;
}

static void setup_renderer(RenWindow *ren, int w, int h) {
  /* Note that w and h here should always be in pixels and obtained from
     a call to SDL_GetWindowSizeInPixels(). */
  if (!ren->renderer) {
    ren->renderer = SDL_CreateRenderer(ren->window, NULL);
  }
  if (ren->texture) {
    SDL_DestroyTexture(ren->texture);
  }
  ren->texture = SDL_CreateTexture(ren->renderer, ren->rensurface.surface->format, SDL_TEXTUREACCESS_STREAMING, w, h);
  query_surface_scale(ren, &ren->rensurface.scale_x, &ren->rensurface.scale_y);
}
#endif


void renwin_init_surface(RenWindow *ren) {
  ren->scale_x = ren->scale_y = 1;
#ifdef PRAGTICAL_USE_SDL_RENDERER
  if (ren->rensurface.surface) {
    SDL_DestroySurface(ren->rensurface.surface);
  }
  int w, h;
  SDL_GetWindowSizeInPixels(ren->window, &w, &h);
  SDL_PixelFormat format = SDL_GetWindowPixelFormat(ren->window);
  ren->rensurface.surface = SDL_CreateSurface(w, h, format == SDL_PIXELFORMAT_UNKNOWN ? SDL_PIXELFORMAT_BGRA32 : format);
  if (!ren->rensurface.surface) {
    fprintf(stderr, "Error creating surface: %s", SDL_GetError());
    exit(1);
  }
  setup_renderer(ren, w, h);
#endif
}

void renwin_init_command_buf(RenWindow *ren) {
  ren->command_buf = NULL;
  ren->command_buf_idx = 0;
  ren->command_buf_size = 0;
}


static RenRect scaled_rect(const RenRect rect, const RenSurface *rs) {
#ifdef PRAGTICAL_USE_SDL_RENDERER
  float scale_x = rs->scale_x;
  float scale_y = rs->scale_y;
#else
  int scale_x = 1;
  int scale_y = 1;
#endif
  return (RenRect) {
    rect.x * scale_x,
    rect.y * scale_y,
    rect.width * scale_x,
    rect.height * scale_y
  };
}


void renwin_clip_to_surface(RenWindow *ren) {
  SDL_SetSurfaceClipRect(renwin_get_surface(ren).surface, NULL);
}


void renwin_set_clip_rect(RenWindow *ren, RenRect rect) {
  RenSurface rs = renwin_get_surface(ren);
  RenRect sr = scaled_rect(rect, &rs);
  SDL_SetSurfaceClipRect(rs.surface, &(SDL_Rect){.x = sr.x, .y = sr.y, .w = sr.width, .h = sr.height});
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
  return (RenSurface){.surface = surface, .scale_x = 1, .scale_y = 1};
#endif
}

void renwin_resize_surface(UNUSED RenWindow *ren) {
#ifdef PRAGTICAL_USE_SDL_RENDERER
  int new_w, new_h;
  float new_scale;
  SDL_GetWindowSizeInPixels(ren->window, &new_w, &new_h);
  query_surface_scale(ren, &new_scale, NULL);
  /* Note that (w, h) may differ from (new_w, new_h) on retina displays. */
  if (new_scale != ren->rensurface.scale_x ||
      new_w != ren->rensurface.surface->w ||
      new_h != ren->rensurface.surface->h) {
    renwin_init_surface(ren);
    renwin_clip_to_surface(ren);
    setup_renderer(ren, new_w, new_h);
  }
#endif
}

void renwin_update_scale(RenWindow *ren) {
#ifndef PRAGTICAL_USE_SDL_RENDERER
  SDL_Surface *surface = SDL_GetWindowSurface(ren->window);
  int window_w = surface->w, window_h = surface->h;
  SDL_GetWindowSize(ren->window, &window_w, &window_h);
  ren->scale_x = (float)surface->w / window_w;
  ren->scale_y = (float)surface->h / window_h;
#endif
}

void renwin_show_window(RenWindow *ren) {
  SDL_ShowWindow(ren->window);
}

void renwin_update_rects(RenWindow *ren, RenRect *rects, int count) {
#ifdef PRAGTICAL_USE_SDL_RENDERER
  const float scale_x = ren->rensurface.scale_x;
  const float scale_y = ren->rensurface.scale_y;
  for (int i = 0; i < count; i++) {
    const RenRect *r = &rects[i];
    const int x = scale_x * r->x, y = scale_y * r->y;
    const int w = scale_x * r->width, h = scale_y * r->height;
    const SDL_Rect sr = {.x = x, .y = y, .w = w, .h = h};
    uint8_t *pixels = ((uint8_t *) ren->rensurface.surface->pixels) + y * ren->rensurface.surface->pitch + x * SDL_BYTESPERPIXEL(ren->rensurface.surface->format);
    SDL_UpdateTexture(ren->texture, &sr, pixels, ren->rensurface.surface->pitch);
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
