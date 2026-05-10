#include "renatlas.h"

#include <assert.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>

// a bitmap atlas page group with a fixed width, each surface acting as a bump allocator
typedef struct {
  SDL_Surface **surfaces;
  unsigned int width, nsurface;
} SurfaceAtlasPage;

typedef struct {
  SurfaceAtlasPage *pages[EGlyphFormatSize];
  size_t npages[EGlyphFormatSize];
} SurfaceAtlas;

#define check_alloc(P) _check_alloc(P, __FILE__, __LINE__)
static void* _check_alloc(void *ptr, const char *const file, size_t ln) {
  if (!ptr) {
    fprintf(stderr, "%s:%zu: memory allocation failed\n", file, ln);
    exit(EXIT_FAILURE);
  }
  return ptr;
}

static inline SDL_PixelFormat glyphformat_to_pixelformat(ERenGlyphFormat format, int *depth) {
  switch (format) {
    case EGlyphFormatColor:     *depth = 32; return SDL_PIXELFORMAT_BGRA32;
    case EGlyphFormatSubpixel:  *depth = 24; return SDL_PIXELFORMAT_RGB24;
    case EGlyphFormatGrayscale: *depth = 8;  return SDL_PIXELFORMAT_INDEX8;
    default: return SDL_PIXELFORMAT_UNKNOWN;
  }
}

static SurfaceAtlas *surface_atlas_data(RenAtlas *atlas) {
  if (!atlas->data) {
    atlas->data = check_alloc(SDL_calloc(1, sizeof(SurfaceAtlas)));
    atlas->bytesize += sizeof(SurfaceAtlas);
  }
  return atlas->data;
}

static SDL_Surface *surface_atlas_allocate_glyph_surface(RenAtlas *ren_atlas, RenAtlasGlyphRequest request, int bitmap_idx, GlyphMetric *metric) {
  (void) bitmap_idx;
  SurfaceAtlas *surface_atlas = surface_atlas_data(ren_atlas);
  // get an atlas with the correct width
  ERenGlyphFormat glyph_format = metric->format;
  int atlas_idx = -1;
  for (int i = 0; i < surface_atlas->npages[glyph_format]; i++) {
    if (surface_atlas->pages[glyph_format][i].width >= metric->x1) {
      atlas_idx = i;
      break;
    }
  }
  if (atlas_idx < 0) {
    surface_atlas->pages[glyph_format] = check_alloc(
      SDL_realloc(surface_atlas->pages[glyph_format], sizeof(SurfaceAtlasPage) * (surface_atlas->npages[glyph_format] + 1))
    );
    surface_atlas->pages[glyph_format][surface_atlas->npages[glyph_format]] = (SurfaceAtlasPage) {
      .width = metric->x1 + FONT_WIDTH_OVERFLOW_PX, .nsurface = 0,
      .surfaces = NULL,
    };
    ren_atlas->bytesize += sizeof(SurfaceAtlasPage);
    atlas_idx = surface_atlas->npages[glyph_format]++;
  }
  metric->atlas_idx = atlas_idx;
  SurfaceAtlasPage *atlas = &surface_atlas->pages[glyph_format][atlas_idx];
  SDL_PropertiesID userdata;

  // find the surface with the minimum height that can fit the glyph (limited to last 100 surfaces)
  int surface_idx = -1, max_surface_idx = (int) atlas->nsurface - 100, min_waste = INT_MAX;
  for (int i = atlas->nsurface - 1; i >= 0 && i > max_surface_idx; i--) {
    userdata = SDL_GetSurfaceProperties(atlas->surfaces[i]);
    assert(SDL_HasProperty(userdata, "metric"));
    GlyphMetric *m = (GlyphMetric *) SDL_GetPointerProperty(userdata, "metric", NULL);
    int new_min_waste = (int) atlas->surfaces[i]->h - (int) m->y1;
    if (new_min_waste >= metric->y1 && new_min_waste < min_waste) {
      surface_idx = i;
      min_waste = new_min_waste;
    }
  }
  if (surface_idx < 0) {
    // allocate a new surface array, and a surface
    int h = FONT_HEIGHT_OVERFLOW_PX + request.font_height;
    if (h <= FONT_HEIGHT_OVERFLOW_PX) h += request.bitmap_rows;
    if (h <= FONT_HEIGHT_OVERFLOW_PX) h += request.font_size;
    int depth = 0;
    SDL_PixelFormat format = glyphformat_to_pixelformat(glyph_format, &depth);
    atlas->surfaces = check_alloc(SDL_realloc(atlas->surfaces, sizeof(SDL_Surface *) * (atlas->nsurface + 1)));
    atlas->surfaces[atlas->nsurface] = check_alloc(SDL_CreateSurface(atlas->width, GLYPHS_PER_ATLAS * h, format));
    userdata = SDL_GetSurfaceProperties(atlas->surfaces[atlas->nsurface]);
    SDL_SetPointerProperty(userdata, "metric", NULL);
    surface_idx = atlas->nsurface++;
    ren_atlas->bytesize += (sizeof(SDL_Surface *) + sizeof(SDL_Surface) + atlas->width * GLYPHS_PER_ATLAS * h * ren_glyphformat_bytes_per_pixel(glyph_format));
  }
  metric->surface_idx = surface_idx;
  userdata = SDL_GetSurfaceProperties(atlas->surfaces[surface_idx]);
  if (SDL_HasProperty(userdata, "metric")) {
    GlyphMetric *last_metric = (GlyphMetric *) SDL_GetPointerProperty(userdata, "metric", NULL);
    metric->y0 = last_metric->y1; metric->y1 += last_metric->y1;
  }
  SDL_SetPointerProperty(userdata, "metric", (void *) metric);
  return atlas->surfaces[surface_idx];
}

static SDL_Surface *surface_atlas_get_glyph_surface(RenAtlas *ren_atlas, GlyphMetric *metric) {
  SurfaceAtlas *surface_atlas = ren_atlas->data;
  return surface_atlas->pages[metric->format][metric->atlas_idx].surfaces[metric->surface_idx];
}

static void surface_atlas_clear(RenAtlas *ren_atlas) {
  SurfaceAtlas *surface_atlas = ren_atlas->data;
  if (!surface_atlas) {
    ren_atlas->bytesize = 0;
    return;
  }
  for (int glyph_format_idx = 0; glyph_format_idx < EGlyphFormatSize; glyph_format_idx++) {
    for (int atlas_idx = 0; atlas_idx < surface_atlas->npages[glyph_format_idx]; atlas_idx++) {
      SurfaceAtlasPage *atlas = &surface_atlas->pages[glyph_format_idx][atlas_idx];
      for (int surface_idx = 0; surface_idx < atlas->nsurface; surface_idx++) {
        SDL_DestroySurface(atlas->surfaces[surface_idx]);
      }
      SDL_free(atlas->surfaces);
    }
    SDL_free(surface_atlas->pages[glyph_format_idx]);
    surface_atlas->pages[glyph_format_idx] = NULL;
    surface_atlas->npages[glyph_format_idx] = 0;
  }
  ren_atlas->bytesize = sizeof(SurfaceAtlas);
}

#ifdef RENDERER_DEBUG
static void surface_atlas_dump(RenAtlas *ren_atlas, const char *family_name) {
  SurfaceAtlas *surface_atlas = ren_atlas->data;
  if (!surface_atlas) return;
  char filename[1024];
  for (int glyph_format_idx = 0; glyph_format_idx < EGlyphFormatSize; glyph_format_idx++) {
    for (int atlas_idx = 0; atlas_idx < surface_atlas->npages[glyph_format_idx]; atlas_idx++) {
      SurfaceAtlasPage *atlas = &surface_atlas->pages[glyph_format_idx][atlas_idx];
      for (int surface_idx = 0; surface_idx < atlas->nsurface; surface_idx++) {
        snprintf(filename, sizeof(filename), "%s-%d-%d-%d.bmp", family_name, glyph_format_idx, atlas_idx, surface_idx);
        SDL_SaveBMP(atlas->surfaces[surface_idx], filename);
      }
    }
  }
}
#endif

static const RenAtlasOps surface_atlas_ops = {
  .allocate_glyph_surface = surface_atlas_allocate_glyph_surface,
  .get_glyph_surface = surface_atlas_get_glyph_surface,
  .clear = surface_atlas_clear,
#ifdef RENDERER_DEBUG
  .dump = surface_atlas_dump,
#endif
};

void renatlas_surface_init(RenAtlas *atlas) {
  atlas->ops = &surface_atlas_ops;
}
