#include <assert.h>
#include "renwindow.h"

#ifdef PRAGTICAL_USE_SDL_RENDERER
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#endif

#ifdef PRAGTICAL_USE_SDL_RENDERER
static void query_surface_scale(RenWindow *ren, float* scale_x, float* scale_y) {
  int w_pixels, h_pixels;
  int w_points, h_points;
  SDL_GetWindowSizeInPixels(ren->cache.window, &w_pixels, &h_pixels);
  SDL_GetWindowSize(ren->cache.window, &w_points, &h_points);
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
  if (!ren->cache.renderer) {
    ren->cache.renderer = SDL_CreateRenderer(ren->cache.window, NULL);
  }
  if (ren->cache.texture) {
    SDL_DestroyTexture(ren->cache.texture);
  }
  ren->cache.texture = SDL_CreateTexture(
    ren->cache.renderer, ren->cache.rensurface.surface->format,
    SDL_TEXTUREACCESS_STREAMING, w, h
  );
  query_surface_scale(ren, &ren->cache.rensurface.scale_x, &ren->cache.rensurface.scale_y);
}
#endif


static void init_surface(RenWindow *ren) {
  ren->scale_x = ren->scale_y = 1;
#ifdef PRAGTICAL_USE_SDL_RENDERER
  if (ren->cache.rensurface.surface) {
    SDL_DestroySurface(ren->cache.rensurface.surface);
  }
  int w, h;
  SDL_GetWindowSizeInPixels(ren->cache.window, &w, &h);
  SDL_PixelFormat format = SDL_GetWindowPixelFormat(ren->cache.window);
  ren->cache.rensurface.surface = SDL_CreateSurface(
    w, h, format == SDL_PIXELFORMAT_UNKNOWN ? SDL_PIXELFORMAT_BGRA32 : format
  );
  if (!ren->cache.rensurface.surface) {
    fprintf(stderr, "Error creating surface: %s", SDL_GetError());
    exit(1);
  }
  setup_renderer(ren, w, h);
#endif
}


RenWindow* renwin_create(SDL_Window *win) {
  assert(win);
  RenWindow* window_renderer = SDL_calloc(1, sizeof(RenWindow));

  rencache_init(&window_renderer->cache);
  window_renderer->cache.window = win;
  init_surface(window_renderer);
  renwin_clip_to_surface(window_renderer);

  return window_renderer;
}


void renwin_clip_to_surface(RenWindow *ren) {
  SDL_SetSurfaceClipRect(rencache_get_surface(&ren->cache).surface, NULL);
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

void renwin_set_clip_rect(RenWindow *ren, RenRect rect) {
  RenSurface rs = rencache_get_surface(&ren->cache);
  RenRect sr = scaled_rect(rect, &rs);
  SDL_SetSurfaceClipRect(rs.surface, &(SDL_Rect){.x = sr.x, .y = sr.y, .w = sr.width, .h = sr.height});
}


void renwin_resize_surface(UNUSED RenWindow *ren) {
#ifdef PRAGTICAL_USE_SDL_RENDERER
  int new_w, new_h;
  float new_scale;
  SDL_GetWindowSizeInPixels(ren->cache.window, &new_w, &new_h);
  query_surface_scale(ren, &new_scale, NULL);
  /* Note that (w, h) may differ from (new_w, new_h) on retina displays. */
  if (new_scale != ren->cache.rensurface.scale_x ||
      new_w != ren->cache.rensurface.surface->w ||
      new_h != ren->cache.rensurface.surface->h) {
    init_surface(ren);
    renwin_clip_to_surface(ren);
    setup_renderer(ren, new_w, new_h);
  }
#endif
}

void renwin_update_scale(RenWindow *ren) {
#ifndef PRAGTICAL_USE_SDL_RENDERER
  SDL_Surface *surface = SDL_GetWindowSurface(ren->cache.window);
  int window_w = surface->w, window_h = surface->h;
  SDL_GetWindowSize(ren->cache.window, &window_w, &window_h);
  ren->scale_x = (float)surface->w / window_w;
  ren->scale_y = (float)surface->h / window_h;
#endif
}

void renwin_show_window(RenWindow *ren) {
  SDL_ShowWindow(ren->cache.window);
}

void renwin_free(RenWindow *ren) {
#ifdef PRAGTICAL_USE_SDL_RENDERER
  SDL_DestroyTexture(ren->cache.texture);
  SDL_DestroyRenderer(ren->cache.renderer);
  SDL_DestroySurface(ren->cache.rensurface.surface);
#endif
  SDL_DestroyWindow(ren->cache.window);
  ren->cache.window = NULL;
  rencache_uninit(&ren->cache);
  SDL_free(ren);
}
