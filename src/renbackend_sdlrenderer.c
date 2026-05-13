#include "renbackend_sdlrenderer.h"
#include "renwindow.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

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

static void sdlrenderer_query_surface_scale(RenWindow *ren, float *scale_x, float *scale_y) {
  int w_pixels, h_pixels;
  int w_points, h_points;
  SDL_GetWindowSizeInPixels(ren->window, &w_pixels, &h_pixels);
  SDL_GetWindowSize(ren->window, &w_points, &h_points);
  float scaleX = (float) w_pixels / (float) w_points;
  float scaleY = (float) h_pixels / (float) h_points;
  if (scale_x)
    *scale_x = round(scaleX * 100) / 100;
  if (scale_y)
    *scale_y = round(scaleY * 100) / 100;
}

static void sdlrenderer_destroy_texture(SdlRendererWindowData *data) {
  if (data && data->texture) {
    SDL_DestroyTexture(data->texture);
    data->texture = NULL;
  }
}

static void sdlrenderer_setup_texture(RenWindow *ren, int w, int h) {
  SdlRendererWindowData *data = sdlrenderer_window_data(ren);
  if (!data->renderer)
    data->renderer = SDL_CreateRenderer(ren->window, NULL);
  if (!data->renderer) {
    fprintf(stderr, "Error creating SDL renderer: %s\n", SDL_GetError());
    exit(1);
  }

  sdlrenderer_destroy_texture(data);
  data->texture = SDL_CreateTexture(
    data->renderer,
    ren->cache.rensurface.surface->format,
    SDL_TEXTUREACCESS_STREAMING,
    w,
    h
  );
  if (!data->texture) {
    fprintf(stderr, "Error creating SDL renderer texture: %s\n", SDL_GetError());
    exit(1);
  }
}

static void sdlrenderer_create_surface_and_texture(RenWindow *ren, int w, int h) {
  ren->scale_x = ren->scale_y = 1;
  if (ren->cache.rensurface.surface)
    SDL_DestroySurface(ren->cache.rensurface.surface);

  SDL_PixelFormat format = SDL_GetWindowPixelFormat(ren->window);
  ren->cache.rensurface.surface = SDL_CreateSurface(
    w,
    h,
    format == SDL_PIXELFORMAT_UNKNOWN ? SDL_PIXELFORMAT_BGRA32 : format
  );
  if (!ren->cache.rensurface.surface) {
    fprintf(stderr, "Error creating SDL renderer surface: %s\n", SDL_GetError());
    exit(1);
  }

  sdlrenderer_query_surface_scale(
    ren,
    &ren->cache.rensurface.scale_x,
    &ren->cache.rensurface.scale_y
  );
  sdlrenderer_setup_texture(ren, w, h);
}

static void sdlrenderer_init_window(RenWindow *ren) {
  int w, h;
  SDL_GetWindowSizeInPixels(ren->window, &w, &h);
  sdlrenderer_create_surface_and_texture(ren, w, h);
}

static void sdlrenderer_resize_window(RenWindow *ren) {
  int new_w, new_h;
  float new_scale_x, new_scale_y;
  SDL_GetWindowSizeInPixels(ren->window, &new_w, &new_h);
  sdlrenderer_query_surface_scale(ren, &new_scale_x, &new_scale_y);

  if (new_scale_x != ren->cache.rensurface.scale_x ||
      new_scale_y != ren->cache.rensurface.scale_y ||
      new_w != ren->cache.rensurface.surface->w ||
      new_h != ren->cache.rensurface.surface->h) {
    sdlrenderer_create_surface_and_texture(ren, new_w, new_h);
    renwin_clip_to_surface(ren);
  }
}

static void sdlrenderer_destroy_window(RenWindow *ren) {
  SdlRendererWindowData *data = ren->backend_data;
  if (data) {
    sdlrenderer_destroy_texture(data);
    if (data->renderer)
      SDL_DestroyRenderer(data->renderer);
  }
  SDL_DestroySurface(ren->cache.rensurface.surface);
  ren->cache.rensurface.surface = NULL;
  SDL_free(ren->backend_data);
  ren->backend_data = NULL;
}

static void sdlrenderer_init_canvas(RenCache *canvas, SDL_Surface *surface) {
  canvas->rensurface.surface = surface;
  canvas->rensurface.scale_x = 1;
  canvas->rensurface.scale_y = 1;
}

static void sdlrenderer_destroy_canvas(RenCache *canvas) {
  if (canvas->rensurface.surface)
    SDL_DestroySurface(canvas->rensurface.surface);
  canvas->rensurface.surface = NULL;
}

static SDL_Surface *sdlrenderer_get_canvas_surface(RenCache *canvas) {
  return canvas->rensurface.surface;
}

static void sdlrenderer_get_canvas_size(RenCache *canvas, int *width, int *height) {
  SDL_Surface *surface = sdlrenderer_get_canvas_surface(canvas);
  *width = surface->w;
  *height = surface->h;
}

static void sdlrenderer_copy_canvas(RenCache *dst, RenCache *src, int x, int y, bool blend) {
  SDL_Surface *src_surface = sdlrenderer_get_canvas_surface(src);
  SDL_Surface *dst_surface = sdlrenderer_get_canvas_surface(dst);
  SDL_Rect rect = { .x = x, .y = y, .w = src_surface->w, .h = src_surface->h };
  SDL_BlendMode src_mode;
  SDL_GetSurfaceBlendMode(src_surface, &src_mode);
  SDL_SetSurfaceBlendMode(src_surface, blend ? SDL_BLENDMODE_BLEND : SDL_BLENDMODE_NONE);
  SDL_BlitSurface(src_surface, NULL, dst_surface, &rect);
  SDL_SetSurfaceBlendMode(src_surface, src_mode);
}

static SDL_Surface *sdlrenderer_capture_window(RenCache *cache, RenRect rect) {
  SDL_Surface *src = cache->rensurface.surface;
  SDL_Surface *dst = SDL_CreateSurface(rect.width, rect.height, SDL_PIXELFORMAT_RGBA32);
  if (!dst)
    return NULL;

  SDL_Rect src_rect = { .x = rect.x, .y = rect.y, .w = rect.width, .h = rect.height };
  if (!SDL_BlitSurface(src, &src_rect, dst, NULL)) {
    SDL_DestroySurface(dst);
    return NULL;
  }
  return dst;
}

static RenSurface sdlrenderer_get_window_surface(RenCache *cache) {
  return cache->rensurface;
}

static SDL_Rect sdlrenderer_scale_rect(RenCache *cache, RenRect rect) {
  const float scale_x = cache->rensurface.scale_x;
  const float scale_y = cache->rensurface.scale_y;
  return (SDL_Rect) {
    .x = (int) floorf(scale_x * rect.x),
    .y = (int) floorf(scale_y * rect.y),
    .w = (int) ceilf(scale_x * rect.width),
    .h = (int) ceilf(scale_y * rect.height),
  };
}

static bool sdlrenderer_clip_rect(SDL_Surface *surface, SDL_Rect *rect) {
  SDL_Rect bounds = { .x = 0, .y = 0, .w = surface->w, .h = surface->h };
  SDL_Rect clipped;
  bool intersects = SDL_GetRectIntersection(rect, &bounds, &clipped);
  if (intersects)
    *rect = clipped;
  return intersects;
}

static SDL_Rect sdlrenderer_union_rect(SDL_Rect a, SDL_Rect b) {
  int x1 = SDL_min(a.x, b.x);
  int y1 = SDL_min(a.y, b.y);
  int x2 = SDL_max(a.x + a.w, b.x + b.w);
  int y2 = SDL_max(a.y + a.h, b.y + b.h);
  return (SDL_Rect) { .x = x1, .y = y1, .w = x2 - x1, .h = y2 - y1 };
}

static void sdlrenderer_upload_rect(
  RenCache *cache,
  SdlRendererWindowData *data,
  SDL_Rect rect
) {
  SDL_Surface *surface = cache->rensurface.surface;
  const int bytes_per_pixel = SDL_BYTESPERPIXEL(surface->format);
  uint8_t *pixels = ((uint8_t *) surface->pixels)
    + rect.y * surface->pitch
    + rect.x * bytes_per_pixel;
  SDL_UpdateTexture(data->texture, &rect, pixels, surface->pitch);
}

static void sdlrenderer_present_window_rects(RenCache *cache, RenRect *rects, int count) {
  RenWindow *ren = cache->target;
  SdlRendererWindowData *data = ren->backend_data;
  SDL_Surface *surface = cache->rensurface.surface;
  const Uint64 full_area = (Uint64) surface->w * (Uint64) surface->h;
  Uint64 dirty_area = 0;
  SDL_Rect bounds = { 0 };
  int upload_count = 0;

  for (int i = 0; i < count; i++) {
    SDL_Rect rect = sdlrenderer_scale_rect(cache, rects[i]);
    if (!sdlrenderer_clip_rect(surface, &rect))
      continue;
    dirty_area += (Uint64) rect.w * (Uint64) rect.h;
    bounds = upload_count == 0 ? rect : sdlrenderer_union_rect(bounds, rect);
    upload_count++;
  }

  if (upload_count > 0) {
    Uint64 bounds_area = (Uint64) bounds.w * (Uint64) bounds.h;
    bool full_upload = dirty_area * 10 >= full_area * 9;
    bool bounded_upload = !full_upload &&
      upload_count > 16 &&
      bounds_area <= dirty_area * 2 &&
      bounds_area * 4 <= full_area * 3;

    if (full_upload) {
      SDL_Rect full = { .x = 0, .y = 0, .w = surface->w, .h = surface->h };
      sdlrenderer_upload_rect(cache, data, full);
    } else if (bounded_upload) {
      sdlrenderer_upload_rect(cache, data, bounds);
    } else {
      for (int i = 0; i < count; i++) {
        SDL_Rect rect = sdlrenderer_scale_rect(cache, rects[i]);
        if (!sdlrenderer_clip_rect(surface, &rect))
          continue;
        sdlrenderer_upload_rect(cache, data, rect);
      }
    }
  }

  SDL_RenderTexture(data->renderer, data->texture, NULL, NULL);
  SDL_RenderPresent(data->renderer);
  if (!ren->shown) {
    SDL_ShowWindow(ren->window);
    ren->shown = true;
  }
}

static void sdlrenderer_set_clip_rect(UNUSED RenCache *rc, RenSurface *surface, RenRect rect) {
  ren_set_clip_rect(surface, rect);
}

static void sdlrenderer_draw_rect(UNUSED RenCache *rc, RenSurface *surface, RenRect rect, RenColor color, bool replace) {
  ren_draw_rect(surface, rect, color, replace);
}

static double sdlrenderer_draw_text(UNUSED RenCache *rc, RenSurface *surface, RenFont **fonts, const char *text, size_t len, float x, float y, RenColor color, RenTab tab) {
  return ren_draw_text(surface, fonts, text, len, x, y, color, tab);
}

static void sdlrenderer_draw_poly(UNUSED RenCache *rc, RenSurface *surface, RenPoint *points, unsigned short npoints, RenColor color) {
  ren_draw_poly(surface, points, npoints, color);
}

static void sdlrenderer_draw_canvas(UNUSED RenCache *rc, RenSurface *surface, RenCache *canvas, int x, int y) {
  ren_draw_canvas(surface, canvas->backend->get_canvas_surface(canvas), x, y);
}

static void sdlrenderer_draw_pixels(UNUSED RenCache *rc, RenSurface *surface, RenRect rect, const char *bytes, size_t len) {
  ren_draw_pixels(surface, rect, bytes, len);
}

static const RenCacheDrawOps sdlrenderer_draw_ops = {
  .set_clip_rect = sdlrenderer_set_clip_rect,
  .draw_rect = sdlrenderer_draw_rect,
  .draw_text = sdlrenderer_draw_text,
  .draw_poly = sdlrenderer_draw_poly,
  .draw_canvas = sdlrenderer_draw_canvas,
  .draw_pixels = sdlrenderer_draw_pixels,
};

static const RenBackend sdlrenderer_backend = {
  .name = "sdlrenderer",
  .draw_ops = &sdlrenderer_draw_ops,
  .get_window_surface = sdlrenderer_get_window_surface,
  .present_window_rects = sdlrenderer_present_window_rects,
  .capture_window = sdlrenderer_capture_window,
  .init_window = sdlrenderer_init_window,
  .resize_window = sdlrenderer_resize_window,
  .destroy_window = sdlrenderer_destroy_window,
  .init_canvas = sdlrenderer_init_canvas,
  .destroy_canvas = sdlrenderer_destroy_canvas,
  .get_canvas_surface = sdlrenderer_get_canvas_surface,
  .get_canvas_size = sdlrenderer_get_canvas_size,
  .copy_canvas = sdlrenderer_copy_canvas,
  .init_atlas = renatlas_surface_init,
};

const RenBackend *renbackend_sdlrenderer(void) {
  return &sdlrenderer_backend;
}
