#include "renbackend_surface.h"
#include "renwindow.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static RenSurface surface_get_window_surface(RenCache *cache);

typedef struct {
  SDL_Renderer *renderer;
  SDL_Texture *texture;
} SdlRendererWindowData;

static SdlRendererWindowData *sdlrenderer_window_data(RenWindow *ren) {
  if (!ren->backend_data) {
    ren->backend_data = SDL_calloc(1, sizeof(SdlRendererWindowData));
    if (!ren->backend_data) {
      fprintf(stderr, "Error allocating SDL renderer window data\n");
      exit(1);
    }
  }
  return ren->backend_data;
}

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

static void setup_sdlrenderer(RenWindow *ren, int w, int h) {
  SdlRendererWindowData *data = sdlrenderer_window_data(ren);
  /* Note that w and h here should always be in pixels and obtained from
     a call to SDL_GetWindowSizeInPixels(). */
  if (!data->renderer) {
    data->renderer = SDL_CreateRenderer(ren->window, NULL);
  }
  if (data->texture) {
    SDL_DestroyTexture(data->texture);
  }
  data->texture = SDL_CreateTexture(
    data->renderer, ren->cache.rensurface.surface->format,
    SDL_TEXTUREACCESS_STREAMING, w, h
  );
  query_surface_scale(ren, &ren->cache.rensurface.scale_x, &ren->cache.rensurface.scale_y);
}

static void surface_init_window(RenWindow *ren) {
  ren->scale_x = ren->scale_y = 1;
}

static void sdlrenderer_init_window(RenWindow *ren) {
  ren->scale_x = ren->scale_y = 1;
  if (ren->cache.rensurface.surface) {
    SDL_DestroySurface(ren->cache.rensurface.surface);
  }
  int w, h;
  SDL_GetWindowSizeInPixels(ren->window, &w, &h);
  SDL_PixelFormat format = SDL_GetWindowPixelFormat(ren->window);
  ren->cache.rensurface.surface = SDL_CreateSurface(
    w, h, format == SDL_PIXELFORMAT_UNKNOWN ? SDL_PIXELFORMAT_BGRA32 : format
  );
  if (!ren->cache.rensurface.surface) {
    fprintf(stderr, "Error creating surface: %s", SDL_GetError());
    exit(1);
  }
  setup_sdlrenderer(ren, w, h);
}

static void surface_resize_window(UNUSED RenWindow *ren) {
}

static void sdlrenderer_resize_window(RenWindow *ren) {
  int new_w, new_h;
  float new_scale;
  SDL_GetWindowSizeInPixels(ren->window, &new_w, &new_h);
  query_surface_scale(ren, &new_scale, NULL);
  /* Note that (w, h) may differ from (new_w, new_h) on retina displays. */
  if (new_scale != ren->cache.rensurface.scale_x ||
      new_w != ren->cache.rensurface.surface->w ||
      new_h != ren->cache.rensurface.surface->h) {
    sdlrenderer_init_window(ren);
    renwin_clip_to_surface(ren);
    setup_sdlrenderer(ren, new_w, new_h);
  }
}

static void surface_destroy_window(UNUSED RenWindow *ren) {
  SDL_free(ren->backend_data);
  ren->backend_data = NULL;
}

static void sdlrenderer_destroy_window(RenWindow *ren) {
  SdlRendererWindowData *data = ren->backend_data;
  if (data) {
    SDL_DestroyTexture(data->texture);
    SDL_DestroyRenderer(data->renderer);
  }
  SDL_DestroySurface(ren->cache.rensurface.surface);
  ren->cache.rensurface.surface = NULL;
  SDL_free(ren->backend_data);
  ren->backend_data = NULL;
}

static void surface_init_canvas(RenCache *canvas, SDL_Surface *surface) {
  canvas->rensurface.surface = surface;
  canvas->rensurface.scale_x = 1;
  canvas->rensurface.scale_y = 1;
}

static void surface_destroy_canvas(RenCache *canvas) {
  if (canvas->rensurface.surface)
    SDL_DestroySurface(canvas->rensurface.surface);
  canvas->rensurface.surface = NULL;
}

static SDL_Surface *surface_get_canvas_surface(RenCache *canvas) {
  return canvas->rensurface.surface;
}

static void surface_get_canvas_size(RenCache *canvas, int *width, int *height) {
  SDL_Surface *surface = surface_get_canvas_surface(canvas);
  *width = surface->w;
  *height = surface->h;
}

static void surface_copy_canvas(RenCache *dst, RenCache *src, int x, int y, bool blend) {
  SDL_Surface *src_surface = surface_get_canvas_surface(src);
  SDL_Surface *dst_surface = surface_get_canvas_surface(dst);
  SDL_Rect rect = { .x = x, .y = y, .w = src_surface->w, .h = src_surface->h };
  SDL_BlendMode src_mode;
  SDL_GetSurfaceBlendMode(src_surface, &src_mode);
  SDL_SetSurfaceBlendMode(src_surface, blend ? SDL_BLENDMODE_BLEND : SDL_BLENDMODE_NONE);
  SDL_BlitSurface(src_surface, NULL, dst_surface, &rect);
  SDL_SetSurfaceBlendMode(src_surface, src_mode);
}

static SDL_Surface *surface_capture_window(RenCache *cache, RenRect rect) {
  RenSurface rs = surface_get_window_surface(cache);
  SDL_Surface *dst = SDL_CreateSurface(rect.width, rect.height, SDL_PIXELFORMAT_RGBA32);
  if (!dst)
    return NULL;

  SDL_Rect src_rect = { .x = rect.x, .y = rect.y, .w = rect.width, .h = rect.height };
  if (!SDL_BlitSurface(rs.surface, &src_rect, dst, NULL)) {
    SDL_DestroySurface(dst);
    return NULL;
  }
  return dst;
}

static RenSurface surface_get_window_surface(RenCache *cache) {
  RenWindow *ren = cache->target;
  SDL_Surface *surface = SDL_GetWindowSurface(ren->window);
  if (!surface) {
    fprintf(stderr, "Error getting window surface: %s", SDL_GetError());
    exit(1);
  }
  return (RenSurface){.surface = surface, .scale_x = 1, .scale_y = 1};
}

static RenSurface sdlrenderer_get_window_surface(RenCache *cache) {
  return cache->rensurface;
}

static void surface_present_window_rects(RenCache *cache, RenRect *rects, int count) {
  RenWindow *ren = cache->target;
  SDL_Rect *sdl_rects = NULL;
  if (count > 0) {
    sdl_rects = SDL_malloc(sizeof(SDL_Rect) * (size_t) count);
    if (!sdl_rects) {
      fprintf(stderr, "Error allocating window update rects\n");
      exit(1);
    }
    for (int i = 0; i < count; i++) {
      sdl_rects[i] = (SDL_Rect) {
        .x = (int) rects[i].x,
        .y = (int) rects[i].y,
        .w = (int) rects[i].width,
        .h = (int) rects[i].height
      };
    }
  }
  SDL_UpdateWindowSurfaceRects(ren->window, sdl_rects, count);
  SDL_free(sdl_rects);
  if (!ren->shown) {
    SDL_ShowWindow(ren->window);
    ren->shown = true;
  }
}

static void sdlrenderer_present_window_rects(RenCache *cache, RenRect *rects, int count) {
  RenWindow *ren = cache->target;
  SdlRendererWindowData *data = ren->backend_data;
  const float scale_x = cache->rensurface.scale_x;
  const float scale_y = cache->rensurface.scale_y;
  for (int i = 0; i < count; i++) {
    const RenRect *r = &rects[i];
    const int x = scale_x * r->x, y = scale_y * r->y;
    const int w = scale_x * r->width, h = scale_y * r->height;
    const SDL_Rect sr = {.x = x, .y = y, .w = w, .h = h};
    uint8_t *pixels = ((uint8_t *) cache->rensurface.surface->pixels)
      + y * cache->rensurface.surface->pitch
      + x * SDL_BYTESPERPIXEL(cache->rensurface.surface->format);
    SDL_UpdateTexture(data->texture, &sr, pixels, cache->rensurface.surface->pitch);
  }
  SDL_RenderTexture(data->renderer, data->texture, NULL, NULL);
  SDL_RenderPresent(data->renderer);
  if (!ren->shown) {
    SDL_ShowWindow(ren->window);
    ren->shown = true;
  }
}

static void surface_set_clip_rect(UNUSED RenCache *rc, RenSurface *surface, RenRect rect) {
  ren_set_clip_rect(surface, rect);
}

static void surface_draw_rect(UNUSED RenCache *rc, RenSurface *surface, RenRect rect, RenColor color, bool replace) {
  ren_draw_rect(surface, rect, color, replace);
}

static double surface_draw_text(UNUSED RenCache *rc, RenSurface *surface, RenFont **fonts, const char *text, size_t len, float x, float y, RenColor color, RenTab tab) {
  return ren_draw_text(surface, fonts, text, len, x, y, color, tab);
}

static void surface_draw_poly(UNUSED RenCache *rc, RenSurface *surface, RenPoint *points, unsigned short npoints, RenColor color) {
  ren_draw_poly(surface, points, npoints, color);
}

static void surface_draw_canvas(UNUSED RenCache *rc, RenSurface *surface, RenCache *canvas, int x, int y) {
  ren_draw_canvas(surface, canvas->backend->get_canvas_surface(canvas), x, y);
}

static void surface_draw_pixels(UNUSED RenCache *rc, RenSurface *surface, RenRect rect, const char *bytes, size_t len) {
  ren_draw_pixels(surface, rect, bytes, len);
}

static const RenCacheDrawOps surface_draw_ops = {
  .set_clip_rect = surface_set_clip_rect,
  .draw_rect = surface_draw_rect,
  .draw_text = surface_draw_text,
  .draw_poly = surface_draw_poly,
  .draw_canvas = surface_draw_canvas,
  .draw_pixels = surface_draw_pixels,
};

static const RenBackend surface_backend = {
  .name = "surface",
  .draw_ops = &surface_draw_ops,
  .get_window_surface = surface_get_window_surface,
  .present_window_rects = surface_present_window_rects,
  .capture_window = surface_capture_window,
  .init_window = surface_init_window,
  .resize_window = surface_resize_window,
  .destroy_window = surface_destroy_window,
  .init_canvas = surface_init_canvas,
  .destroy_canvas = surface_destroy_canvas,
  .get_canvas_surface = surface_get_canvas_surface,
  .get_canvas_size = surface_get_canvas_size,
  .copy_canvas = surface_copy_canvas,
  .init_atlas = renatlas_surface_init,
};

static const RenBackend sdlrenderer_backend = {
  .name = "sdlrenderer",
  .draw_ops = &surface_draw_ops,
  .get_window_surface = sdlrenderer_get_window_surface,
  .present_window_rects = sdlrenderer_present_window_rects,
  .capture_window = surface_capture_window,
  .init_window = sdlrenderer_init_window,
  .resize_window = sdlrenderer_resize_window,
  .destroy_window = sdlrenderer_destroy_window,
  .init_canvas = surface_init_canvas,
  .destroy_canvas = surface_destroy_canvas,
  .get_canvas_surface = surface_get_canvas_surface,
  .get_canvas_size = surface_get_canvas_size,
  .copy_canvas = surface_copy_canvas,
  .init_atlas = renatlas_surface_init,
};

const RenBackend *renbackend_surface(void) {
  return &surface_backend;
}

const RenBackend *renbackend_sdlrenderer(void) {
  return &sdlrenderer_backend;
}
