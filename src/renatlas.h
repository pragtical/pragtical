#ifndef RENATLAS_H
#define RENATLAS_H

#include <math.h>
#include <stddef.h>
#include <ft2build.h>
#include FT_FREETYPE_H

#include "renderer.h"

// approximate number of glyphs per atlas surface
#define GLYPHS_PER_ATLAS 96
// some padding to add to atlas surface to store more glyphs
#define FONT_HEIGHT_OVERFLOW_PX 0
#define FONT_WIDTH_OVERFLOW_PX 9

// the maximum number of glyphs for OpenType
#define MAX_GLYPHS 65535
// number of rows and columns in the glyph map
#define GLYPHMAP_ROW 128
#define GLYPHMAP_COL ((unsigned int)ceil((float)MAX_GLYPHS / GLYPHMAP_ROW))

// number of subpixel bitmaps
#define SUBPIXEL_BITMAPS_CACHED 3

// the bitmap format of the glyph
typedef enum {
  EGlyphFormatGrayscale, // 8bit grayscale
  EGlyphFormatSubpixel,  // 24bit subpixel
  EGlyphFormatColor,     // 32bit BGRA color
  EGlyphFormatSize
} ERenGlyphFormat;

// extra flags to store glyph info
typedef enum {
  EGlyphNone = 0,             // glyph is not loaded
  EGlyphXAdvance = (1 << 0L), // xadvance is loaded
  EGlyphBitmap = (1 << 1L)    // bitmap is loaded
} ERenGlyphFlags;

// metrics for a loaded glyph
typedef struct GlyphMetric {
  float xadvance;
  unsigned short atlas_idx, surface_idx;
  int bitmap_left, bitmap_top;
  unsigned int x1, y0, y1;
  unsigned short flags;
  unsigned char format;
} GlyphMetric;

typedef struct RenAtlas RenAtlas;

typedef struct {
  int font_height;
  int bitmap_rows;
  float font_size;
} RenAtlasGlyphRequest;

typedef struct {
  SDL_Surface *(*allocate_glyph_surface)(RenAtlas *atlas, RenAtlasGlyphRequest request, int bitmap_idx, GlyphMetric *metric);
  SDL_Surface *(*get_glyph_surface)(RenAtlas *atlas, GlyphMetric *metric);
  void (*glyph_updated)(RenAtlas *atlas, GlyphMetric *metric);
  void (*clear)(RenAtlas *atlas);
#ifdef RENDERER_DEBUG
  void (*dump)(RenAtlas *atlas, const char *family_name);
#endif
} RenAtlasOps;

struct RenAtlas {
  const RenAtlasOps *ops;
  void *data;
  size_t bytesize;
};

void renatlas_surface_init(RenAtlas *atlas);
int ren_glyphformat_bytes_per_pixel(ERenGlyphFormat format);
SDL_Surface *ren_atlas_allocate_glyph_surface(RenAtlas *atlas, RenAtlasGlyphRequest request, int bitmap_idx, GlyphMetric *metric);
SDL_Surface *ren_atlas_get_glyph_surface(RenAtlas *atlas, GlyphMetric *metric);
void ren_atlas_glyph_updated(RenAtlas *atlas, GlyphMetric *metric);
void ren_atlas_clear(RenAtlas *atlas);
void ren_atlas_free(RenAtlas *atlas);
#ifdef RENDERER_DEBUG
void ren_atlas_dump(RenAtlas *atlas, const char *family_name);
#endif

#endif
