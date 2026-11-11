#include <stdio.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <assert.h>
#include <math.h>
#include <string.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_LCD_FILTER_H
#include FT_OUTLINE_H
#include FT_COLOR_H
#include FT_TRUETYPE_IDS_H
#include FT_SFNT_NAMES_H
#include FT_SYSTEM_H
#include FT_MULTIPLE_MASTERS_H
#include <hb.h>
#include <hb-ft.h>

// uncomment the line below for more debugging information through printf
// #define RENDERER_DEBUG

#include "renderer/atlas.h"
#include "renderer/backend.h"
#include "renderer/renderer.h"
#include "renderer/window.h"
#include "fallbackfont.h"
#include "grapheme.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static RenWindow **window_list = NULL;
static RenWindow *target_window = NULL;
static size_t window_count = 0;

// draw_rect_surface is used as a 1x1 surface to simplify ren_draw_rect with blending
static SDL_Surface *draw_rect_surface = NULL;
static FT_Library library = NULL;

#define check_alloc(P) _check_alloc(P, __FILE__, __LINE__)
static void* _check_alloc(void *ptr, const char *const file, size_t ln) {
  if (!ptr) {
    fprintf(stderr, "%s:%zu: memory allocation failed\n", file, ln);
    exit(EXIT_FAILURE);
  }
  return ptr;
}

static uint32_t hash_bytes(const void *data, size_t size) {
  const unsigned char *p = data;
  uint32_t h = 2166136261u;
  while (size--) {
    h = (h ^ *p++) * 16777619u;
  }
  return h;
}

// getting freetype error messages (https://freetype.org/freetype2/docs/reference/ft2-error_enumerations.html)
static const char *const get_ft_error(FT_Error err) {
#undef FTERRORS_H_
#define FT_ERROR_START_LIST switch (FT_ERROR_BASE(err)) {
#define FT_ERRORDEF(e, v, s) case v: return s;
#define FT_ERROR_END_LIST }
#include FT_ERRORS_H
  return "unknown error";
}

// the parameters passed into freetype's scanline converter
typedef struct {
  SDL_Surface *surface;
  SDL_Rect clip;
  RenColor color;
  RenPolySpanFn span_fn;
  void *userdata;
} RenPolyParams;

/************************* Fonts *************************/

// maximum unicode codepoint supported (https://stackoverflow.com/a/52203901)
#define MAX_UNICODE 0x10FFFF
// Smaller, lazily allocated pages keep sparse scripts inexpensive to cache.
#define CHARMAP_COL 1024
#define CHARMAP_ROW (MAX_UNICODE / CHARMAP_COL + 1)

// number of shaped width entries cached per font
#define SHAPED_WIDTH_CACHE_MAX 512
// maximum shaped run byte length to copy into the width cache
#define SHAPED_WIDTH_CACHE_MAX_TEXT 256

// number of shaped glyph runs cached per font
#define SHAPED_RUN_CACHE_MAX 512
// maximum shaped run byte length to copy into the run cache
#define SHAPED_RUN_CACHE_MAX_TEXT 256

#define FONT_CLUSTER_CACHE_MAX 512
#define FONT_CLUSTER_CACHE_MAX_TEXT 256

/* Small selected-run cache, separate from glyph/atlas storage. Each record is
 * capped at 1 KiB; ASCII uses the direct path and allocates no layout entries.
 */
#define FONT_LAYOUT_CACHE_MAX 64
#define FONT_LAYOUT_CACHE_MAX_TEXT 512
#define FONT_LAYOUT_CACHE_MAX_BYTES 1024

// maps codepoints -> glyph IDs
typedef struct {
  unsigned int *first;
  unsigned int **rows;
} CharMap;

// maps glyph IDs -> glyph metrics
typedef struct {
  // accessed with metrics[bitmap_idx][glyph_id / GLYPHMAP_COL][glyph_id % GLYPHMAP_COL]
  GlyphMetric **metrics[SUBPIXEL_BITMAPS_CACHED];
  size_t row_count;
  RenAtlas atlas;
  size_t metrics_bytesize;
} GlyphMap;

typedef struct {
  char *text;
  size_t len;
  uint32_t hash;
  uint32_t generation;
  double width;
  int x_offset;
  bool has_x_offset;
  uint64_t age;
} ShapedWidthCacheEntry;

// one shaped glyph from HarfBuzz: glyph id plus raw (font-unit) positions
typedef struct {
  unsigned int codepoint;
  hb_position_t x_offset, y_offset, x_advance;
} ShapedGlyph;

typedef struct {
  char *text;
  size_t len;
  uint32_t hash;
  uint32_t generation;
  ShapedGlyph *glyphs;
  unsigned int glyph_count;
  uint64_t age;
} ShapedRunCacheEntry;

/* Keep each lazy shaping cache's counters beside its entries. */
typedef struct {
  uint64_t age;
  size_t count;
  ShapedWidthCacheEntry entries[SHAPED_WIDTH_CACHE_MAX];
} ShapedWidthCache;

typedef struct {
  uint64_t age;
  size_t count;
  ShapedRunCacheEntry entries[SHAPED_RUN_CACHE_MAX];
} ShapedRunCache;

/* The same bounded cache holds either coverage results or native selections.
 * A matching entry with a NULL font caches a failed lookup as well.
 */
typedef struct {
  char *text;
  size_t len;
  RenFont *font;
} FontClusterCacheEntry;

typedef struct {
  RenFont *font;
  size_t end;
  bool shaped;
} FontTextRun;

typedef struct {
  char *text;
  size_t len, count;
  uint64_t group;
  FontTextRun *runs;
} FontTextLayout;

typedef struct {
  uint64_t role;
  RenFont *font;
} FontFallbackRole;

typedef struct RenFont {
  struct RenFont *next_loaded;
  struct RenFont *prev_loaded;
  FT_Face face;
  hb_font_t *hb_font;
  FT_Color *palette;
  FT_UShort palette_count;
  CharMap charmap;
  GlyphMap glyphs;
  float size, space_advance, color_scale;
  unsigned short baseline, height, tab_size;
  unsigned short underline_thickness;
  RenRect glyph_bounds;
  ERenFontAntialiasing antialiasing;
  ERenFontHinting hinting;
  unsigned char style;
  bool ligatures;
  bool system_fallback;
  bool resolver_initialized;
  FallbackFontResolver *resolver;
  struct RenFont *fallback_fonts, *next_fallback;
  RenFont **fallback_index;
  size_t fallback_count;
  FontFallbackRole *fallback_roles;
  size_t fallback_role_count;
  /* Native scalar selections: 0 unknown, 1 missing, otherwise pool index + 2.
   * Sparse Unicode rows avoid eviction when a document uses many characters.
   */
  CharMap fallback_characters;
  FontTextLayout *layouts;
  uint64_t identity;
  float fallback_scale;
  uint32_t variation_hash;
  FontClusterCacheEntry *coverage_cache, *fallback_cache;
  uint32_t generation;
  ShapedWidthCache *shaped_width_cache;
  ShapedRunCache *shaped_run_cache;
  char path[];
} RenFont;

static RenFont *loaded_fonts = NULL;
static uint64_t next_font_identity;

static void font_link_loaded(RenFont *font) {
  font->identity = ++next_font_identity;
  font->next_loaded = loaded_fonts;
  font->prev_loaded = NULL;
  if (loaded_fonts)
    loaded_fonts->prev_loaded = font;
  loaded_fonts = font;
}

static void font_unlink_loaded(RenFont *font) {
  if (font->prev_loaded)
    font->prev_loaded->next_loaded = font->next_loaded;
  else if (loaded_fonts == font)
    loaded_fonts = font->next_loaded;
  if (font->next_loaded)
    font->next_loaded->prev_loaded = font->prev_loaded;
  font->next_loaded = NULL;
  font->prev_loaded = NULL;
}

static const char* utf8_to_codepoint(const char *p, const char *endp, unsigned *dst) {
  if ((unsigned char)*p < 0x80) {
    *dst = (unsigned char)*p;
    return p + 1;
  }
  size_t remaining = endp - p;
  *dst = SDL_StepUTF8(&p, &remaining);
  return p;
}

static int font_set_load_options(RenFont* font) {
  int load_target = font->antialiasing == FONT_ANTIALIASING_NONE ? FT_LOAD_TARGET_MONO
    : (font->hinting == FONT_HINTING_SLIGHT ? FT_LOAD_TARGET_LIGHT : FT_LOAD_TARGET_NORMAL);
  int hinting = font->hinting == FONT_HINTING_NONE ? FT_LOAD_NO_HINTING : FT_LOAD_FORCE_AUTOHINT;
  int color = FT_HAS_COLOR(font->face) ? FT_LOAD_COLOR : 0;
  return load_target | hinting | color;
}

static int font_set_render_options(RenFont* font) {
  if (FT_HAS_COLOR(font->face))
    return FT_RENDER_MODE_NORMAL;
  if (font->antialiasing == FONT_ANTIALIASING_NONE)
    return FT_RENDER_MODE_MONO;
  if (font->antialiasing == FONT_ANTIALIASING_SUBPIXEL) {
    switch (font->hinting) {
      case FONT_HINTING_NONE: FT_Library_SetLcdFilter(library, FT_LCD_FILTER_DEFAULT); break;
      case FONT_HINTING_SLIGHT: FT_Library_SetLcdFilter(library, FT_LCD_FILTER_LIGHT); break;
      case FONT_HINTING_FULL: FT_Library_SetLcdFilter(library, FT_LCD_FILTER_LEGACY); break;
    }
    return FT_RENDER_MODE_LCD;
  } else {
    switch (font->hinting) {
      case FONT_HINTING_NONE:   return FT_RENDER_MODE_NORMAL; break;
      case FONT_HINTING_SLIGHT: return FT_RENDER_MODE_LIGHT; break;
      case FONT_HINTING_FULL:   return FT_RENDER_MODE_LIGHT; break;
    }
  }
  return 0;
}

static int font_set_style(FT_Outline* outline, int x_translation, unsigned char style) {
  FT_Outline_Translate(outline, x_translation, 0 );
  if (style & FONT_STYLE_SMOOTH)
    FT_Outline_Embolden(outline, 1 << 5);
  if (style & FONT_STYLE_BOLD)
    FT_Outline_EmboldenXY(outline, 1 << 5, 0);
  if (style & FONT_STYLE_ITALIC) {
    FT_Matrix matrix = { 1 << 16, 1 << 14, 0, 1 << 16 };
    FT_Outline_Transform(outline, &matrix);
  }
  return 0;
}

/* Both glyph IDs and native font selections use the same sparse Unicode map. */
static inline unsigned int *font_charmap_entry(CharMap *map, unsigned int codepoint) {
  unsigned int **page;
  if (codepoint < CHARMAP_COL) {
    page = &map->first;
  } else {
    if (!map->rows)
      map->rows = check_alloc(SDL_calloc(CHARMAP_ROW - 1, sizeof(*map->rows)));
    page = &map->rows[codepoint / CHARMAP_COL - 1];
  }
  if (!*page) *page = check_alloc(SDL_calloc(CHARMAP_COL, sizeof(unsigned int)));
  return &(*page)[codepoint % CHARMAP_COL];
}

static void font_clear_charmap(CharMap *map) {
  SDL_free(map->first);
  map->first = NULL;
  if (!map->rows) return;
  for (size_t i = 0; i < CHARMAP_ROW - 1; i++) SDL_free(map->rows[i]);
  SDL_free(map->rows);
  map->rows = NULL;
}

static unsigned int font_get_glyph_id(RenFont *font, unsigned int codepoint) {
  if (codepoint > MAX_UNICODE) return 0;
  unsigned int *entry = font_charmap_entry(&font->charmap, codepoint);
  if (*entry == 0) {
    unsigned int glyph_id = FT_Get_Char_Index(font->face, codepoint);
    // Keep zero for uncached codepoints and use -1 for a cached missing glyph.
    *entry = glyph_id ? glyph_id : (unsigned int) -1;
  }
  return *entry == (unsigned int) -1 ? 0 : *entry;
}

#define FONT_IS_SUBPIXEL(F) ((F)->antialiasing == FONT_ANTIALIASING_SUBPIXEL)
#define FONT_BITMAP_COUNT(F) ((F)->antialiasing == FONT_ANTIALIASING_SUBPIXEL ? SUBPIXEL_BITMAPS_CACHED : 1)

static inline ERenGlyphFormat bitmap_to_glyph_format(FT_Bitmap bitmap) {
  if (bitmap.pixel_mode == FT_PIXEL_MODE_BGRA)
    return EGlyphFormatColor;
  if (bitmap.pixel_mode == FT_PIXEL_MODE_LCD)
    return EGlyphFormatSubpixel;
  return EGlyphFormatGrayscale;
}

static inline unsigned int scale_bitmap_dimension(unsigned int value, float scale) {
  if (scale == 1.0f)
    return value;
  int scaled = lroundf(value * scale);
  return scaled > 0 ? scaled : 1;
}

static inline int scale_bitmap_offset(int value, float scale) {
  if (scale == 1.0f)
    return value;
  return lroundf(value * scale);
}

typedef struct {
  SDL_Surface *surface;
  int x_min, y_max;
  FT_Matrix matrix;
  FT_Vector delta;
} ColrRenderContext;

typedef struct {
  double offset;
  RenColor color;
} ColrStop;

#define COLR_MAX_STOPS 32

static RenAtlasGlyphRequest font_atlas_glyph_request(RenFont *font, FT_GlyphSlot slot) {
  return (RenAtlasGlyphRequest) {
    .font_height = (int) ((double) font->face->size->metrics.height / 64.0f),
    .bitmap_rows = (int) slot->bitmap.rows,
    .font_size = font->size,
  };
}

static inline double colr_fixed_to_pixels(RenFont *font, FT_Fixed value, bool y_axis) {
  FT_Size_Metrics *metrics = &font->face->size->metrics;
  double scale = (y_axis ? metrics->y_ppem : metrics->x_ppem) / (double) font->face->units_per_EM;
  return (value / 65536.0) * scale;
}

static inline FT_Pos colr_fixed_to_26_6(RenFont *font, FT_Fixed value, bool y_axis) {
  return lround(colr_fixed_to_pixels(font, value, y_axis) * 64.0);
}

static ColrRenderContext colr_context_transform(ColrRenderContext *ctx, FT_Matrix matrix, FT_Vector delta) {
  ColrRenderContext next = *ctx;
  next.matrix.xx = FT_MulFix(ctx->matrix.xx, matrix.xx) + FT_MulFix(ctx->matrix.xy, matrix.yx);
  next.matrix.xy = FT_MulFix(ctx->matrix.xx, matrix.xy) + FT_MulFix(ctx->matrix.xy, matrix.yy);
  next.matrix.yx = FT_MulFix(ctx->matrix.yx, matrix.xx) + FT_MulFix(ctx->matrix.yy, matrix.yx);
  next.matrix.yy = FT_MulFix(ctx->matrix.yx, matrix.xy) + FT_MulFix(ctx->matrix.yy, matrix.yy);
  next.delta.x = FT_MulFix(ctx->matrix.xx, delta.x) + FT_MulFix(ctx->matrix.xy, delta.y) + ctx->delta.x;
  next.delta.y = FT_MulFix(ctx->matrix.yx, delta.x) + FT_MulFix(ctx->matrix.yy, delta.y) + ctx->delta.y;
  return next;
}

static ColrRenderContext colr_context_affine_transform(RenFont *font, ColrRenderContext *ctx, FT_Affine23 affine) {
  FT_Matrix matrix = {
    .xx = affine.xx,
    .xy = affine.xy,
    .yx = affine.yx,
    .yy = affine.yy
  };
  FT_Vector delta = {
    .x = colr_fixed_to_26_6(font, affine.dx, false),
    .y = colr_fixed_to_26_6(font, affine.dy, true)
  };
  return colr_context_transform(ctx, matrix, delta);
}

static ColrRenderContext colr_context_translate(RenFont *font, ColrRenderContext *ctx, FT_Fixed dx, FT_Fixed dy) {
  FT_Matrix identity = { 0x10000L, 0, 0, 0x10000L };
  FT_Vector delta = {
    .x = colr_fixed_to_26_6(font, dx, false),
    .y = colr_fixed_to_26_6(font, dy, true)
  };
  return colr_context_transform(ctx, identity, delta);
}

static ColrRenderContext colr_context_scale(RenFont *font, ColrRenderContext *ctx, FT_Fixed scale_x, FT_Fixed scale_y, FT_Fixed center_x, FT_Fixed center_y) {
  FT_Matrix matrix = { scale_x, 0, 0, scale_y };
  FT_Vector center = {
    .x = colr_fixed_to_26_6(font, center_x, false),
    .y = colr_fixed_to_26_6(font, center_y, true)
  };
  FT_Vector delta = {
    .x = center.x - FT_MulFix(scale_x, center.x),
    .y = center.y - FT_MulFix(scale_y, center.y)
  };
  return colr_context_transform(ctx, matrix, delta);
}

static ColrRenderContext colr_context_rotate(RenFont *font, ColrRenderContext *ctx, FT_Fixed angle, FT_Fixed center_x, FT_Fixed center_y) {
  double radians = (angle / 65536.0) * M_PI;
  FT_Fixed cos_value = lround(cos(radians) * 65536.0);
  FT_Fixed sin_value = lround(sin(radians) * 65536.0);
  FT_Matrix matrix = { cos_value, -sin_value, sin_value, cos_value };
  FT_Vector center = {
    .x = colr_fixed_to_26_6(font, center_x, false),
    .y = colr_fixed_to_26_6(font, center_y, true)
  };
  FT_Vector delta = {
    .x = center.x - FT_MulFix(matrix.xx, center.x) - FT_MulFix(matrix.xy, center.y),
    .y = center.y - FT_MulFix(matrix.yx, center.x) - FT_MulFix(matrix.yy, center.y)
  };
  return colr_context_transform(ctx, matrix, delta);
}

static ColrRenderContext colr_context_skew(RenFont *font, ColrRenderContext *ctx, FT_Fixed x_angle, FT_Fixed y_angle, FT_Fixed center_x, FT_Fixed center_y) {
  double x_radians = (x_angle / 65536.0) * M_PI;
  double y_radians = (y_angle / 65536.0) * M_PI;
  FT_Matrix matrix = {
    .xx = 0x10000L,
    .xy = lround(tan(x_radians) * 65536.0),
    .yx = lround(tan(y_radians) * 65536.0),
    .yy = 0x10000L
  };
  FT_Vector center = {
    .x = colr_fixed_to_26_6(font, center_x, false),
    .y = colr_fixed_to_26_6(font, center_y, true)
  };
  FT_Vector delta = {
    .x = center.x - FT_MulFix(matrix.xx, center.x) - FT_MulFix(matrix.xy, center.y),
    .y = center.y - FT_MulFix(matrix.yx, center.x) - FT_MulFix(matrix.yy, center.y)
  };
  return colr_context_transform(ctx, matrix, delta);
}

static RenColor colr_palette_color(RenFont *font, FT_ColorIndex color_index) {
  RenColor color = { 0xff, 0xff, 0xff, 0xff };
  if (color_index.palette_index != 0xffff && color_index.palette_index < font->palette_count && font->palette) {
    FT_Color palette_color = font->palette[color_index.palette_index];
    color = (RenColor) { palette_color.blue, palette_color.green, palette_color.red, palette_color.alpha };
  }
  color.a = (color.a * color_index.alpha + (1 << 13)) >> 14;
  return color;
}

static void colr_blend_pixel(uint8_t *destination, RenColor color, unsigned int coverage) {
  unsigned int src_a = (color.a * coverage + 127) / 255;
  unsigned int inv_a = 255 - src_a;
  unsigned int src_b = (color.b * src_a + 127) / 255;
  unsigned int src_g = (color.g * src_a + 127) / 255;
  unsigned int src_r = (color.r * src_a + 127) / 255;

  destination[0] = src_b + (destination[0] * inv_a + 127) / 255;
  destination[1] = src_g + (destination[1] * inv_a + 127) / 255;
  destination[2] = src_r + (destination[2] * inv_a + 127) / 255;
  destination[3] = src_a + (destination[3] * inv_a + 127) / 255;
}

static void colr_src_over_premul_pixel(uint8_t *destination, const uint8_t *source) {
  unsigned int src_a = source[3];
  unsigned int inv_a = 255 - src_a;
  destination[0] = source[0] + (destination[0] * inv_a + 127) / 255;
  destination[1] = source[1] + (destination[1] * inv_a + 127) / 255;
  destination[2] = source[2] + (destination[2] * inv_a + 127) / 255;
  destination[3] = src_a + (destination[3] * inv_a + 127) / 255;
}

static inline double colr_unpremul_channel(uint8_t channel, uint8_t alpha) {
  return alpha ? fmin(1.0, (double)channel / alpha) : 0.0;
}

static inline double colr_soft_light_channel(double backdrop, double source) {
  if (source <= 0.5)
    return backdrop - (1.0 - 2.0 * source) * backdrop * (1.0 - backdrop);
  double d = backdrop <= 0.25 ? ((16.0 * backdrop - 12.0) * backdrop + 4.0) * backdrop : sqrt(backdrop);
  return backdrop + (2.0 * source - 1.0) * (d - backdrop);
}

static void colr_compose_pixel(uint8_t *destination, const uint8_t *backdrop, const uint8_t *source, FT_Composite_Mode mode) {
  uint8_t result[4] = { 0, 0, 0, 0 };
  unsigned int backdrop_a = backdrop[3];
  unsigned int source_a = source[3];

  switch (mode) {
    case FT_COLR_COMPOSITE_SRC_IN:
      result[0] = (source[0] * backdrop_a + 127) / 255;
      result[1] = (source[1] * backdrop_a + 127) / 255;
      result[2] = (source[2] * backdrop_a + 127) / 255;
      result[3] = (source_a * backdrop_a + 127) / 255;
      break;
    case FT_COLR_COMPOSITE_SOFT_LIGHT:
    {
      double ab = backdrop_a / 255.0;
      double as = source_a / 255.0;
      double alpha = as + ab - as * ab;
      for (int channel = 0; channel < 3; channel++) {
        double cb = colr_unpremul_channel(backdrop[channel], backdrop_a);
        double cs = colr_unpremul_channel(source[channel], source_a);
        double blended = colr_soft_light_channel(cb, cs);
        double premul = (1.0 - as) * backdrop[channel] / 255.0
          + (1.0 - ab) * source[channel] / 255.0
          + as * ab * blended;
        int value = lround(premul * 255.0);
        result[channel] = value < 0 ? 0 : (value > 255 ? 255 : value);
      }
      int value = lround(alpha * 255.0);
      result[3] = value < 0 ? 0 : (value > 255 ? 255 : value);
      break;
    }
    case FT_COLR_COMPOSITE_SRC:
      memcpy(result, source, sizeof(result));
      break;
    case FT_COLR_COMPOSITE_DEST:
      memcpy(result, backdrop, sizeof(result));
      break;
    case FT_COLR_COMPOSITE_SRC_OVER:
    default:
      memcpy(result, backdrop, sizeof(result));
      colr_src_over_premul_pixel(result, source);
      break;
  }

  colr_src_over_premul_pixel(destination, result);
}

static RenColor colr_lerp_color(RenColor a, RenColor b, double t) {
  if (t < 0.0) t = 0.0;
  if (t > 1.0) t = 1.0;
  return (RenColor) {
    a.b + (b.b - a.b) * t,
    a.g + (b.g - a.g) * t,
    a.r + (b.r - a.r) * t,
    a.a + (b.a - a.a) * t
  };
}

static int colr_load_stops(RenFont *font, FT_ColorLine *colorline, ColrStop stops[COLR_MAX_STOPS]) {
  int count = 0;
  FT_ColorStop stop;
  FT_ColorStopIterator iterator = colorline->color_stop_iterator;
  while (count < COLR_MAX_STOPS && FT_Get_Colorline_Stops(font->face, &stop, &iterator)) {
    stops[count++] = (ColrStop) {
      .offset = stop.stop_offset / 65536.0,
      .color = colr_palette_color(font, stop.color)
    };
  }
  return count;
}

static double colr_extend_gradient_t(double t, ColrStop *stops, int count, FT_PaintExtend extend) {
  switch (extend) {
    case FT_COLR_PAINT_EXTEND_REPEAT:
      return t - floor(t);
    case FT_COLR_PAINT_EXTEND_REFLECT:
      t = fabs(fmod(t, 2.0));
      return t > 1.0 ? 2.0 - t : t;
    case FT_COLR_PAINT_EXTEND_PAD:
    default:
      if (t < stops[0].offset) return stops[0].offset;
      if (t > stops[count - 1].offset) return stops[count - 1].offset;
      return t;
  }
}

static RenColor colr_stops_color_at(ColrStop *stops, int count, double t) {
  if (count == 0)
    return (RenColor) { 0, 0, 0, 0 };
  if (count == 1)
    return stops[0].color;

  for (int i = 1; i < count; i++) {
    if (t <= stops[i].offset) {
      double span = stops[i].offset - stops[i - 1].offset;
      return colr_lerp_color(stops[i - 1].color, stops[i].color, span <= 0.0 ? 0.0 : (t - stops[i - 1].offset) / span);
    }
  }
  return stops[count - 1].color;
}

static void colr_device_to_local_pixels(ColrRenderContext *ctx, int x, int y, double *local_x, double *local_y) {
  double device_x = ctx->x_min + x + 0.5;
  double device_y = ctx->y_max - y - 0.5;
  double dx = device_x - ctx->delta.x / 64.0;
  double dy = device_y - ctx->delta.y / 64.0;
  double xx = ctx->matrix.xx / 65536.0;
  double xy = ctx->matrix.xy / 65536.0;
  double yx = ctx->matrix.yx / 65536.0;
  double yy = ctx->matrix.yy / 65536.0;
  double det = xx * yy - xy * yx;
  if (fabs(det) < 0.000001) {
    *local_x = dx;
    *local_y = dy;
    return;
  }
  *local_x = (dx * yy - dy * xy) / det;
  *local_y = (dy * xx - dx * yx) / det;
}

static RenColor colr_solid_pixel(RenFont *font, FT_COLR_Paint *paint, int x, int y, ColrRenderContext *ctx) {
  (void) x; (void) y; (void) ctx;
  return colr_palette_color(font, paint->u.solid.color);
}

static RenColor colr_linear_gradient_pixel(RenFont *font, FT_COLR_Paint *paint, int x, int y, ColrRenderContext *ctx) {
  ColrStop stops[COLR_MAX_STOPS];
  int count = colr_load_stops(font, &paint->u.linear_gradient.colorline, stops);
  if (count < 2)
    return colr_stops_color_at(stops, count, 0.0);

  double local_x, local_y;
  colr_device_to_local_pixels(ctx, x, y, &local_x, &local_y);
  double x0 = colr_fixed_to_pixels(font, paint->u.linear_gradient.p0.x, false);
  double y0 = colr_fixed_to_pixels(font, paint->u.linear_gradient.p0.y, true);
  double x1 = colr_fixed_to_pixels(font, paint->u.linear_gradient.p1.x, false);
  double y1 = colr_fixed_to_pixels(font, paint->u.linear_gradient.p1.y, true);
  double dx = x1 - x0, dy = y1 - y0;
  double denom = dx * dx + dy * dy;
  double t = denom <= 0.0 ? 0.0 : ((local_x - x0) * dx + (local_y - y0) * dy) / denom;
  return colr_stops_color_at(stops, count, colr_extend_gradient_t(t, stops, count, paint->u.linear_gradient.colorline.extend));
}

static RenColor colr_radial_gradient_pixel(RenFont *font, FT_COLR_Paint *paint, int x, int y, ColrRenderContext *ctx) {
  ColrStop stops[COLR_MAX_STOPS];
  int count = colr_load_stops(font, &paint->u.radial_gradient.colorline, stops);
  if (count < 2)
    return colr_stops_color_at(stops, count, 0.0);

  double local_x, local_y;
  colr_device_to_local_pixels(ctx, x, y, &local_x, &local_y);
  double cx = colr_fixed_to_pixels(font, paint->u.radial_gradient.c1.x, false);
  double cy = colr_fixed_to_pixels(font, paint->u.radial_gradient.c1.y, true);
  double r0 = colr_fixed_to_pixels(font, paint->u.radial_gradient.r0, false);
  double r1 = colr_fixed_to_pixels(font, paint->u.radial_gradient.r1, false);
  double radius = r1 - r0;
  double dx = local_x - cx;
  double dy = local_y - cy;
  double t = radius <= 0.0 ? 0.0 : (sqrt(dx * dx + dy * dy) - r0) / radius;
  return colr_stops_color_at(stops, count, colr_extend_gradient_t(t, stops, count, paint->u.radial_gradient.colorline.extend));
}

static RenColor colr_sweep_gradient_pixel(RenFont *font, FT_COLR_Paint *paint, int x, int y, ColrRenderContext *ctx) {
  ColrStop stops[COLR_MAX_STOPS];
  int count = colr_load_stops(font, &paint->u.sweep_gradient.colorline, stops);
  if (count < 2)
    return colr_stops_color_at(stops, count, 0.0);

  double local_x, local_y;
  colr_device_to_local_pixels(ctx, x, y, &local_x, &local_y);
  double cx = colr_fixed_to_pixels(font, paint->u.sweep_gradient.center.x, false);
  double cy = colr_fixed_to_pixels(font, paint->u.sweep_gradient.center.y, true);
  double angle = atan2(-(local_x - cx), local_y - cy) / M_PI;
  if (angle < 0.0)
    angle += 2.0;
  double start = paint->u.sweep_gradient.start_angle / 65536.0;
  double end = paint->u.sweep_gradient.end_angle / 65536.0;
  double span = end - start;
  while (span <= 0.0) span += 2.0;
  double t = (angle - start) / span;
  return colr_stops_color_at(stops, count, colr_extend_gradient_t(t, stops, count, paint->u.sweep_gradient.colorline.extend));
}

static bool colr_paint_to_surface(RenFont *font, FT_OpaquePaint opaque, ColrRenderContext *ctx);

static SDL_Surface *colr_create_temp_surface(ColrRenderContext *ctx) {
  SDL_Surface *surface = SDL_CreateSurface(ctx->surface->w, ctx->surface->h, SDL_PIXELFORMAT_BGRA32);
  if (surface)
    SDL_FillSurfaceRect(surface, NULL, 0);
  return surface;
}

static bool colr_render_opaque_to_temp(RenFont *font, FT_OpaquePaint opaque, ColrRenderContext *ctx, SDL_Surface **surface) {
  *surface = colr_create_temp_surface(ctx);
  if (!*surface)
    return false;
  ColrRenderContext temp_ctx = *ctx;
  temp_ctx.surface = *surface;
  bool ok = colr_paint_to_surface(font, opaque, &temp_ctx);
  if (!ok) {
    SDL_DestroySurface(*surface);
    *surface = NULL;
  }
  return ok;
}

static RenColor colr_paint_pixel(RenFont *font, FT_COLR_Paint *paint, int x, int y, ColrRenderContext *ctx);

static RenColor colr_opaque_paint_pixel(RenFont *font, FT_OpaquePaint opaque, int x, int y, ColrRenderContext *ctx) {
  FT_COLR_Paint paint;
  if (!FT_Get_Paint(font->face, opaque, &paint))
    return (RenColor) { 0, 0, 0, 0 };
  return colr_paint_pixel(font, &paint, x, y, ctx);
}

static RenColor colr_paint_pixel(RenFont *font, FT_COLR_Paint *paint, int x, int y, ColrRenderContext *ctx) {
  switch (paint->format) {
    case FT_COLR_PAINTFORMAT_SOLID:
      return colr_solid_pixel(font, paint, x, y, ctx);
    case FT_COLR_PAINTFORMAT_LINEAR_GRADIENT:
      return colr_linear_gradient_pixel(font, paint, x, y, ctx);
    case FT_COLR_PAINTFORMAT_RADIAL_GRADIENT:
      return colr_radial_gradient_pixel(font, paint, x, y, ctx);
    case FT_COLR_PAINTFORMAT_SWEEP_GRADIENT:
      return colr_sweep_gradient_pixel(font, paint, x, y, ctx);
    case FT_COLR_PAINTFORMAT_TRANSFORM:
    {
      ColrRenderContext transformed = colr_context_affine_transform(font, ctx, paint->u.transform.affine);
      return colr_opaque_paint_pixel(font, paint->u.transform.paint, x, y, &transformed);
    }
    case FT_COLR_PAINTFORMAT_TRANSLATE:
    {
      ColrRenderContext transformed = colr_context_translate(font, ctx, paint->u.translate.dx, paint->u.translate.dy);
      return colr_opaque_paint_pixel(font, paint->u.translate.paint, x, y, &transformed);
    }
    case FT_COLR_PAINTFORMAT_SCALE:
    {
      ColrRenderContext transformed = colr_context_scale(font, ctx, paint->u.scale.scale_x, paint->u.scale.scale_y, paint->u.scale.center_x, paint->u.scale.center_y);
      return colr_opaque_paint_pixel(font, paint->u.scale.paint, x, y, &transformed);
    }
    case FT_COLR_PAINTFORMAT_ROTATE:
    {
      ColrRenderContext transformed = colr_context_rotate(font, ctx, paint->u.rotate.angle, paint->u.rotate.center_x, paint->u.rotate.center_y);
      return colr_opaque_paint_pixel(font, paint->u.rotate.paint, x, y, &transformed);
    }
    case FT_COLR_PAINTFORMAT_SKEW:
    {
      ColrRenderContext transformed = colr_context_skew(font, ctx, paint->u.skew.x_skew_angle, paint->u.skew.y_skew_angle, paint->u.skew.center_x, paint->u.skew.center_y);
      return colr_opaque_paint_pixel(font, paint->u.skew.paint, x, y, &transformed);
    }
    default:
      return (RenColor) { 0, 0, 0, 0 };
  }
}

static bool colr_paint_glyph_to_surface(RenFont *font, FT_PaintGlyph *glyph_paint, ColrRenderContext *ctx) {
  FT_COLR_Paint fill_paint;
  if (!FT_Get_Paint(font->face, glyph_paint->paint, &fill_paint))
    return false;

  int load_options = (font_set_load_options(font) & ~FT_LOAD_COLOR) | FT_LOAD_NO_BITMAP;
  FT_Set_Transform(font->face, &ctx->matrix, &ctx->delta);
  if (FT_Load_Glyph(font->face, glyph_paint->glyphID, load_options) != 0 || FT_Render_Glyph(font->face->glyph, FT_RENDER_MODE_NORMAL) != 0)
    goto failure;
  FT_Set_Transform(font->face, NULL, NULL);

  FT_GlyphSlot slot = font->face->glyph;
  if (!slot->bitmap.width || !slot->bitmap.rows || !slot->bitmap.buffer || slot->bitmap.pixel_mode != FT_PIXEL_MODE_GRAY)
    return false;

  for (unsigned int row = 0; row < slot->bitmap.rows; row++) {
    int target_y = ctx->y_max - slot->bitmap_top + row;
    if (target_y < 0 || target_y >= ctx->surface->h)
      continue;
    for (unsigned int col = 0; col < slot->bitmap.width; col++) {
      int target_x = slot->bitmap_left - ctx->x_min + col;
      if (target_x < 0 || target_x >= ctx->surface->w)
        continue;
      unsigned int coverage = slot->bitmap.buffer[row * slot->bitmap.pitch + col];
      if (!coverage)
        continue;

      RenColor color = colr_paint_pixel(font, &fill_paint, target_x, target_y, ctx);
      if (color.a)
        colr_blend_pixel(&((uint8_t *)ctx->surface->pixels)[target_y * ctx->surface->pitch + target_x * ren_glyphformat_bytes_per_pixel(EGlyphFormatColor)], color, coverage);
    }
  }
  return true;

failure:
  FT_Set_Transform(font->face, NULL, NULL);
  return false;
}

static bool colr_paint_to_surface(RenFont *font, FT_OpaquePaint opaque, ColrRenderContext *ctx) {
  FT_COLR_Paint paint;
  if (!FT_Get_Paint(font->face, opaque, &paint))
    return false;

  switch (paint.format) {
    case FT_COLR_PAINTFORMAT_COLR_LAYERS: {
      bool ok = true;
      FT_OpaquePaint layer = { 0 };
      FT_LayerIterator iterator = paint.u.colr_layers.layer_iterator;
      while (FT_Get_Paint_Layers(font->face, &iterator, &layer)) {
        ok = colr_paint_to_surface(font, layer, ctx) && ok;
      }
      return ok;
    }
    case FT_COLR_PAINTFORMAT_GLYPH:
      return colr_paint_glyph_to_surface(font, &paint.u.glyph, ctx);
    case FT_COLR_PAINTFORMAT_COMPOSITE:
    {
      SDL_Surface *backdrop = NULL;
      SDL_Surface *source = NULL;
      bool ok = colr_render_opaque_to_temp(font, paint.u.composite.backdrop_paint, ctx, &backdrop)
        && colr_render_opaque_to_temp(font, paint.u.composite.source_paint, ctx, &source);
      if (ok) {
        for (int y = 0; y < ctx->surface->h; y++) {
          for (int x = 0; x < ctx->surface->w; x++) {
            uint8_t *destination_pixel = &((uint8_t *)ctx->surface->pixels)[y * ctx->surface->pitch + x * ren_glyphformat_bytes_per_pixel(EGlyphFormatColor)];
            uint8_t *backdrop_pixel = &((uint8_t *)backdrop->pixels)[y * backdrop->pitch + x * ren_glyphformat_bytes_per_pixel(EGlyphFormatColor)];
            uint8_t *source_pixel = &((uint8_t *)source->pixels)[y * source->pitch + x * ren_glyphformat_bytes_per_pixel(EGlyphFormatColor)];
            colr_compose_pixel(destination_pixel, backdrop_pixel, source_pixel, paint.u.composite.composite_mode);
          }
        }
      }
      SDL_DestroySurface(backdrop);
      SDL_DestroySurface(source);
      return ok;
    }
    case FT_COLR_PAINTFORMAT_COLR_GLYPH: {
      FT_OpaquePaint glyph = { 0 };
      if (!FT_Get_Color_Glyph_Paint(font->face, paint.u.colr_glyph.glyphID, FT_COLOR_NO_ROOT_TRANSFORM, &glyph))
        return false;
      return colr_paint_to_surface(font, glyph, ctx);
    }
    case FT_COLR_PAINTFORMAT_TRANSFORM:
    {
      ColrRenderContext transformed = colr_context_affine_transform(font, ctx, paint.u.transform.affine);
      return colr_paint_to_surface(font, paint.u.transform.paint, &transformed);
    }
    case FT_COLR_PAINTFORMAT_TRANSLATE:
    {
      ColrRenderContext transformed = colr_context_translate(font, ctx, paint.u.translate.dx, paint.u.translate.dy);
      return colr_paint_to_surface(font, paint.u.translate.paint, &transformed);
    }
    case FT_COLR_PAINTFORMAT_SCALE:
    {
      ColrRenderContext transformed = colr_context_scale(font, ctx, paint.u.scale.scale_x, paint.u.scale.scale_y, paint.u.scale.center_x, paint.u.scale.center_y);
      return colr_paint_to_surface(font, paint.u.scale.paint, &transformed);
    }
    case FT_COLR_PAINTFORMAT_ROTATE:
    {
      ColrRenderContext transformed = colr_context_rotate(font, ctx, paint.u.rotate.angle, paint.u.rotate.center_x, paint.u.rotate.center_y);
      return colr_paint_to_surface(font, paint.u.rotate.paint, &transformed);
    }
    case FT_COLR_PAINTFORMAT_SKEW:
    {
      ColrRenderContext transformed = colr_context_skew(font, ctx, paint.u.skew.x_skew_angle, paint.u.skew.y_skew_angle, paint.u.skew.center_x, paint.u.skew.center_y);
      return colr_paint_to_surface(font, paint.u.skew.paint, &transformed);
    }
    default:
      return false;
  }
}

static SDL_Surface *font_load_colr_bitmap(RenFont *font, unsigned int glyph_id, unsigned int bitmap_idx, GlyphMetric *metric, FT_OpaquePaint root_paint) {
  FT_ClipBox clip_box;
  if (!FT_Get_Color_Glyph_ClipBox(font->face, glyph_id, &clip_box))
    return NULL;

  FT_Pos x_min_26_6 = clip_box.bottom_left.x;
  FT_Pos x_max_26_6 = clip_box.top_right.x;
  FT_Pos y_min_26_6 = clip_box.bottom_left.y;
  FT_Pos y_max_26_6 = clip_box.top_right.y;
  int x_min = floor(x_min_26_6 / 64.0);
  int x_max = ceil(x_max_26_6 / 64.0);
  int y_min = floor(y_min_26_6 / 64.0);
  int y_max = ceil(y_max_26_6 / 64.0);
  if (x_max <= x_min || y_max <= y_min)
    return NULL;

  unsigned int width = x_max - x_min;
  unsigned int height = y_max - y_min;
  SDL_Surface *temp_surface = SDL_CreateSurface(width, height, SDL_PIXELFORMAT_BGRA32);
  if (!temp_surface)
    return NULL;
  SDL_FillSurfaceRect(temp_surface, NULL, 0);

  ColrRenderContext ctx = {
    .surface = temp_surface,
    .x_min = x_min,
    .y_max = y_max,
    .matrix = { 0x10000L, 0, 0, 0x10000L },
    .delta = { 0, 0 }
  };
  if (!colr_paint_to_surface(font, root_paint, &ctx)) {
    SDL_DestroySurface(temp_surface);
    return NULL;
  }

  metric->x1 = width;
  metric->y1 = height;
  metric->bitmap_left = x_min;
  metric->bitmap_top = y_max;
  metric->flags |= EGlyphBitmap;
  metric->format = EGlyphFormatColor;

  FT_GlyphSlot slot = font->face->glyph;
  SDL_Surface *surface = ren_atlas_allocate_glyph_surface(&font->glyphs.atlas, font_atlas_glyph_request(font, slot), bitmap_idx, metric);
  int pixel_size = ren_glyphformat_bytes_per_pixel(EGlyphFormatColor);
  for (unsigned int row = 0; row < height; row++) {
    memcpy(
      &((uint8_t *)surface->pixels)[surface->pitch * (metric->y0 + row)],
      &((uint8_t *)temp_surface->pixels)[temp_surface->pitch * row],
      width * pixel_size
    );
  }
  ren_atlas_glyph_updated(&font->glyphs.atlas, metric);
  SDL_DestroySurface(temp_surface);
  return surface;
}

static GlyphMetric *font_load_glyph_metric(RenFont *font, unsigned int glyph_id, unsigned int bitmap_idx) {
  if (glyph_id >= (unsigned long)font->face->num_glyphs || bitmap_idx >= FONT_BITMAP_COUNT(font))
    return NULL;
  unsigned int load_option = font_set_load_options(font);
  int row = glyph_id / GLYPHMAP_COL, col = glyph_id - (row * GLYPHMAP_COL);
  int bitmaps = FONT_BITMAP_COUNT(font);

  // we set all 3 subpixel bitmaps at once, so if either of them are missing we should load it with freetype
  if (!font->glyphs.metrics[0][row] || !(font->glyphs.metrics[0][row][col].flags & EGlyphXAdvance)) {
    // load the font without hinting to fix an issue with monospaced fonts,
    // because freetype doesn't report the correct LSB and RSB delta. Transformation & subpixel positioning don't affect
    // the xadvance, so we can save some time by not doing this step multiple times
    if (FT_Load_Glyph(font->face, glyph_id, (load_option | FT_LOAD_BITMAP_METRICS_ONLY | FT_LOAD_NO_HINTING) & ~FT_LOAD_FORCE_AUTOHINT) != 0)
      return NULL;
    for (int i = 0; i < bitmaps; i++) {
      // save the metrics for all subpixel indexes
      if (!font->glyphs.metrics[i][row]) {
        font->glyphs.metrics[i][row] = check_alloc(SDL_calloc(sizeof(GlyphMetric), GLYPHMAP_COL));
        font->glyphs.metrics_bytesize += sizeof(GlyphMetric) * GLYPHMAP_COL;
      }
      GlyphMetric *metric = &font->glyphs.metrics[i][row][col];
      metric->flags |= EGlyphXAdvance;
      metric->xadvance = font->face->glyph->advance.x / 64.0f;
      if (FT_HAS_COLOR(font->face))
        metric->xadvance *= font->color_scale;
    }
  }
  return &font->glyphs.metrics[bitmap_idx][row][col];
}

static SDL_Surface *font_load_glyph_bitmap(RenFont *font, unsigned int glyph_id, unsigned int bitmap_idx, GlyphMetric *metric) {
  if (metric->flags & EGlyphBitmap) return ren_atlas_get_glyph_surface(&font->glyphs.atlas, metric);

  // render the glyph for a bitmap_idx
  unsigned int load_option = font_set_load_options(font), render_option = font_set_render_options(font);
  FT_GlyphSlot slot = font->face->glyph;
  FT_OpaquePaint colr_paint = { 0 };
  if (FT_HAS_COLOR(font->face) && FT_Get_Color_Glyph_Paint(font->face, glyph_id, FT_COLOR_NO_ROOT_TRANSFORM, &colr_paint)) {
    SDL_Surface *colr_surface = font_load_colr_bitmap(font, glyph_id, bitmap_idx, metric, colr_paint);
    if (colr_surface)
      return colr_surface;
  }

  if (FT_Load_Glyph(font->face, glyph_id, load_option) != 0
      || (slot->format == FT_GLYPH_FORMAT_OUTLINE && font_set_style(&slot->outline, bitmap_idx * (64 / SUBPIXEL_BITMAPS_CACHED), font->style) != 0)
      || FT_Render_Glyph(slot, render_option) != 0)
    return NULL;

  // if this bitmap is empty, or has a format we don't support, just store the xadvance
  if (!slot->bitmap.width || !slot->bitmap.rows || !slot->bitmap.buffer ||
      (slot->bitmap.pixel_mode != FT_PIXEL_MODE_MONO
        && slot->bitmap.pixel_mode != FT_PIXEL_MODE_GRAY
        && slot->bitmap.pixel_mode != FT_PIXEL_MODE_LCD
        && slot->bitmap.pixel_mode != FT_PIXEL_MODE_BGRA))
    return NULL;

  float bitmap_scale = slot->bitmap.pixel_mode == FT_PIXEL_MODE_BGRA ? font->color_scale : 1.0f;
  unsigned int glyph_width = slot->bitmap.width;
  if (slot->bitmap.pixel_mode == FT_PIXEL_MODE_LCD)
    glyph_width /= FONT_BITMAP_COUNT(font);
  // FT_PIXEL_MODE_MONO uses 1 bit per pixel packed bitmap
  if (slot->bitmap.pixel_mode == FT_PIXEL_MODE_MONO) glyph_width *= 8;

  metric->x1 = scale_bitmap_dimension(glyph_width, bitmap_scale);
  metric->y1 = scale_bitmap_dimension(slot->bitmap.rows, bitmap_scale);
  metric->bitmap_left = scale_bitmap_offset(slot->bitmap_left, bitmap_scale);
  metric->bitmap_top = scale_bitmap_offset(slot->bitmap_top, bitmap_scale);
  metric->flags |= EGlyphBitmap;
  metric->format = bitmap_to_glyph_format(slot->bitmap);

  if (slot->bitmap.pixel_mode == FT_PIXEL_MODE_BGRA && bitmap_scale != 1.0f) {
    unsigned int target_rows = metric->y1;
    SDL_Surface *source_surface = SDL_CreateSurfaceFrom(
      glyph_width, slot->bitmap.rows, SDL_PIXELFORMAT_BGRA32, slot->bitmap.buffer, slot->bitmap.pitch
    );
    if (!source_surface) {
      metric->flags &= ~EGlyphBitmap;
      return NULL;
    }
    SDL_Surface *scaled_surface = SDL_CreateSurface(metric->x1, metric->y1, SDL_PIXELFORMAT_BGRA32);
    if (!scaled_surface) {
      SDL_DestroySurface(source_surface);
      metric->flags &= ~EGlyphBitmap;
      return NULL;
    }
    SDL_SetSurfaceBlendMode(source_surface, SDL_BLENDMODE_NONE);
    bool scaled = SDL_BlitSurfaceScaled(source_surface, NULL, scaled_surface, NULL, SDL_SCALEMODE_LINEAR);
    SDL_DestroySurface(source_surface);
    if (!scaled) {
      SDL_DestroySurface(scaled_surface);
      metric->flags &= ~EGlyphBitmap;
      return NULL;
    }

    SDL_Surface *surface = ren_atlas_allocate_glyph_surface(&font->glyphs.atlas, font_atlas_glyph_request(font, slot), bitmap_idx, metric);
    int pixel_size = ren_glyphformat_bytes_per_pixel(EGlyphFormatColor);
    for (unsigned int row = 0; row < target_rows; row++) {
      memcpy(
        &((uint8_t *)surface->pixels)[surface->pitch * (metric->y0 + row)],
        &((uint8_t *)scaled_surface->pixels)[scaled_surface->pitch * row],
        metric->x1 * pixel_size
      );
    }
    ren_atlas_glyph_updated(&font->glyphs.atlas, metric);
    SDL_DestroySurface(scaled_surface);
    return surface;
  }

  // find the best surface to copy the glyph over, and copy it
  SDL_Surface *surface = ren_atlas_allocate_glyph_surface(&font->glyphs.atlas, font_atlas_glyph_request(font, slot), bitmap_idx, metric);
  uint8_t* pixels = surface->pixels;
  unsigned int target_rows = metric->y1 - metric->y0;
  for (unsigned int line = 0; line < target_rows; ++line) {
    int target_offset = surface->pitch * (line + metric->y0); // x0 is always assumed to be 0
    if (slot->bitmap.pixel_mode == FT_PIXEL_MODE_MONO) {
      for (unsigned int column = 0; column < slot->bitmap.width; ++column) {
        int source_offset = line * slot->bitmap.pitch;
        int current_source_offset = source_offset + (column / 8);
        int source_pixel = slot->bitmap.buffer[current_source_offset];
        pixels[++target_offset] = ((source_pixel >> (7 - (column % 8))) & 0x1) * 0xFF;
      }
    } else {
      int source_offset = line * slot->bitmap.pitch;
      size_t source_bytes = slot->bitmap.width;
      if (slot->bitmap.pixel_mode == FT_PIXEL_MODE_BGRA)
        source_bytes *= ren_glyphformat_bytes_per_pixel(EGlyphFormatColor);
      memcpy(&pixels[target_offset], &slot->bitmap.buffer[source_offset], source_bytes);
    }
  }
  ren_atlas_glyph_updated(&font->glyphs.atlas, metric);
  return surface;
}

// https://en.wikipedia.org/wiki/Whitespace_character
static inline int is_whitespace(unsigned int codepoint) {
  switch (codepoint) {
    case 0x20: case 0x85: case 0xA0: case 0x1680: case 0x2028: case 0x2029: case 0x202F: case 0x205F: case 0x3000: return 1;
  }
  return (codepoint >= 0x9 && codepoint <= 0xD) || (codepoint >= 0x2000 && codepoint <= 0x200A);
}

static RenFont *font_get_glyph_by_id(RenFont *font, unsigned int glyph_id, int subpixel_idx, SDL_Surface **surface, GlyphMetric **metric) {
  if (subpixel_idx < 0) subpixel_idx += SUBPIXEL_BITMAPS_CACHED;
  subpixel_idx = FONT_IS_SUBPIXEL(font) ? subpixel_idx : 0;
  GlyphMetric *m = font_load_glyph_metric(font, glyph_id, subpixel_idx);
  if (metric && m) *metric = m;
  if (surface && m)
    *surface = font_load_glyph_bitmap(font, glyph_id, subpixel_idx, m);
  return font;
}

static void font_clear_shaped_width_cache(RenFont *font) {
  if (!font->shaped_width_cache) return;
  for (size_t i = 0; i < font->shaped_width_cache->count; i++) {
    SDL_free(font->shaped_width_cache->entries[i].text);
    font->shaped_width_cache->entries[i].text = NULL;
  }
  SDL_free(font->shaped_width_cache);
  font->shaped_width_cache = NULL;
}

static ShapedWidthCacheEntry *font_lookup_shaped_width_cache(RenFont *font, const char *text, size_t len, uint32_t hash_value) {
  if (!font->shaped_width_cache) return NULL;
  for (size_t i = 0; i < font->shaped_width_cache->count; i++) {
    ShapedWidthCacheEntry *entry = &font->shaped_width_cache->entries[i];
    if (entry->generation == font->generation
        && entry->hash == hash_value
        && entry->len == len
        && memcmp(entry->text, text, len) == 0) {
      entry->age = ++font->shaped_width_cache->age;
      return entry;
    }
  }
  return NULL;
}

static void font_store_shaped_width_cache(RenFont *font, const char *text, size_t len, uint32_t hash_value, double width, int x_offset, bool has_x_offset) {
  if (!font->shaped_width_cache)
    font->shaped_width_cache = check_alloc(SDL_calloc(1, sizeof(ShapedWidthCache)));
  size_t idx = font->shaped_width_cache->count;
  if (idx < SHAPED_WIDTH_CACHE_MAX) {
    font->shaped_width_cache->count++;
  } else {
    idx = 0;
    uint64_t oldest = font->shaped_width_cache->entries[0].age;
    for (size_t i = 1; i < SHAPED_WIDTH_CACHE_MAX; i++) {
      if (font->shaped_width_cache->entries[i].age < oldest) {
        oldest = font->shaped_width_cache->entries[i].age;
        idx = i;
      }
    }
    SDL_free(font->shaped_width_cache->entries[idx].text);
  }

  ShapedWidthCacheEntry *entry = &font->shaped_width_cache->entries[idx];
  entry->text = check_alloc(SDL_malloc(len));
  memcpy(entry->text, text, len);
  entry->len = len;
  entry->hash = hash_value;
  entry->generation = font->generation;
  entry->width = width;
  entry->x_offset = x_offset;
  entry->has_x_offset = has_x_offset;
  entry->age = ++font->shaped_width_cache->age;
}

static void font_clear_shaped_run_cache(RenFont *font) {
  if (!font->shaped_run_cache) return;
  for (size_t i = 0; i < font->shaped_run_cache->count; i++) {
    SDL_free(font->shaped_run_cache->entries[i].text);
    font->shaped_run_cache->entries[i].text = NULL;
    SDL_free(font->shaped_run_cache->entries[i].glyphs);
    font->shaped_run_cache->entries[i].glyphs = NULL;
  }
  SDL_free(font->shaped_run_cache);
  font->shaped_run_cache = NULL;
}

static ShapedRunCacheEntry *font_lookup_shaped_run_cache(RenFont *font, const char *text, size_t len, uint32_t hash_value) {
  if (!font->shaped_run_cache) return NULL;
  for (size_t i = 0; i < font->shaped_run_cache->count; i++) {
    ShapedRunCacheEntry *entry = &font->shaped_run_cache->entries[i];
    if (entry->generation == font->generation
        && entry->hash == hash_value
        && entry->len == len
        && memcmp(entry->text, text, len) == 0) {
      entry->age = ++font->shaped_run_cache->age;
      return entry;
    }
  }
  return NULL;
}

static ShapedRunCacheEntry *font_store_shaped_run_cache(RenFont *font, const char *text, size_t len, uint32_t hash_value, hb_glyph_info_t *infos, hb_glyph_position_t *positions, unsigned int glyph_count) {
  if (!font->shaped_run_cache)
    font->shaped_run_cache = check_alloc(SDL_calloc(1, sizeof(ShapedRunCache)));
  size_t idx = font->shaped_run_cache->count;
  if (idx < SHAPED_RUN_CACHE_MAX) {
    font->shaped_run_cache->count++;
  } else {
    idx = 0;
    uint64_t oldest = font->shaped_run_cache->entries[0].age;
    for (size_t i = 1; i < SHAPED_RUN_CACHE_MAX; i++) {
      if (font->shaped_run_cache->entries[i].age < oldest) {
        oldest = font->shaped_run_cache->entries[i].age;
        idx = i;
      }
    }
    SDL_free(font->shaped_run_cache->entries[idx].text);
    SDL_free(font->shaped_run_cache->entries[idx].glyphs);
  }

  ShapedRunCacheEntry *entry = &font->shaped_run_cache->entries[idx];
  entry->text = check_alloc(SDL_malloc(len));
  memcpy(entry->text, text, len);
  entry->len = len;
  entry->hash = hash_value;
  entry->generation = font->generation;
  entry->glyph_count = glyph_count;
  entry->glyphs = glyph_count ? check_alloc(SDL_malloc(glyph_count * sizeof(ShapedGlyph))) : NULL;
  for (unsigned int i = 0; i < glyph_count; i++) {
    entry->glyphs[i].codepoint = infos[i].codepoint;
    entry->glyphs[i].x_offset = positions[i].x_offset;
    entry->glyphs[i].y_offset = positions[i].y_offset;
    entry->glyphs[i].x_advance = positions[i].x_advance;
  }
  entry->age = ++font->shaped_run_cache->age;
  return entry;
}

static void font_clear_glyph_metrics(RenFont *font) {
  for (int subpixel_idx = 0; subpixel_idx < FONT_BITMAP_COUNT(font); subpixel_idx++) {
    for (size_t glyphmap_row = 0; glyphmap_row < font->glyphs.row_count; glyphmap_row++) {
      SDL_free(font->glyphs.metrics[subpixel_idx][glyphmap_row]);
      font->glyphs.metrics[subpixel_idx][glyphmap_row] = NULL;
    }
  }
  font->glyphs.metrics_bytesize = 0;
}

static void font_clear_glyph_cache(RenFont* font) {
  font_clear_shaped_width_cache(font);
  font_clear_shaped_run_cache(font);
  font->generation++;
  ren_atlas_clear(&font->glyphs.atlas);
  font_clear_glyph_metrics(font);
}

/* Cache entries never own fonts; the primary font owns its native instances. */
static void font_clear_cluster_cache(FontClusterCacheEntry **cache) {
  if (!*cache) return;
  for (size_t i = 0; i < FONT_CLUSTER_CACHE_MAX; i++) SDL_free((*cache)[i].text);
  SDL_free(*cache);
  *cache = NULL;
}

static void font_clear_layouts(RenFont *font) {
  if (!font->layouts) return;
  for (size_t i = 0; i < FONT_LAYOUT_CACHE_MAX; i++) {
    SDL_free(font->layouts[i].text);
    SDL_free(font->layouts[i].runs);
  }
  SDL_free(font->layouts);
  font->layouts = NULL;
}

void ren_font_reset_loaded_atlases(void) {
  for (RenFont *font = loaded_fonts; font; font = font->next_loaded) {
    font_clear_shaped_width_cache(font);
    font_clear_shaped_run_cache(font);
    font->generation++;
    ren_atlas_free(&font->glyphs.atlas);
    font_clear_glyph_metrics(font);
    memset(&font->glyphs.atlas, 0, sizeof(font->glyphs.atlas));
    renbackend_current()->init_atlas(&font->glyphs.atlas);
  }
}

// based on https://github.com/libsdl-org/SDL_ttf/blob/2a094959055fba09f7deed6e1ffeb986188982ae/SDL_ttf.c#L1735
static unsigned long font_file_read(FT_Stream stream, unsigned long offset, unsigned char *buffer, unsigned long count) {
  uint64_t amount;
  SDL_IOStream *file = (SDL_IOStream *) stream->descriptor.pointer;
  SDL_SeekIO(file, offset, SDL_IO_SEEK_SET);
  if (count == 0)
    return 0;
  amount = SDL_ReadIO(file, buffer, sizeof(char) * count);
  if (amount <= 0)
    return 0;
  return (unsigned long) amount;
}

static void font_file_close(FT_Stream stream) {
  if (stream && stream->descriptor.pointer)
    SDL_CloseIO((SDL_IOStream *) stream->descriptor.pointer);
  SDL_free(stream);
}

static int font_set_face_metrics(RenFont *font, FT_Face face) {
  FT_Error err;
  float pixel_size = font->size;
  font->color_scale = 1.0f;
  if (FT_HAS_COLOR(face) && FT_HAS_FIXED_SIZES(face) && face->num_fixed_sizes > 0) {
    FT_Pos target = (FT_Pos)(pixel_size * 64.0f);
    int best_match = 0;
    FT_Pos best_delta = labs(face->available_sizes[0].y_ppem - target);
    for (int i = 1; i < face->num_fixed_sizes; i++) {
      FT_Pos delta = labs(face->available_sizes[i].y_ppem - target);
      if (delta < best_delta) {
        best_match = i;
        best_delta = delta;
      }
    }
    err = FT_Select_Size(face, best_match);
    float selected_size = face->available_sizes[best_match].y_ppem / 64.0f;
    if (selected_size > 0.0f)
      font->color_scale = pixel_size / selected_size;
  } else {
    err = FT_Set_Pixel_Sizes(face, 0, (int) pixel_size);
    if (err != 0 && FT_HAS_FIXED_SIZES(face) && face->num_fixed_sizes > 0) {
      FT_Pos target = (FT_Pos)(pixel_size * 64.0f);
      int best_match = 0;
      FT_Pos best_delta = labs(face->available_sizes[0].y_ppem - target);
      for (int i = 1; i < face->num_fixed_sizes; i++) {
        FT_Pos delta = labs(face->available_sizes[i].y_ppem - target);
        if (delta < best_delta) {
          best_match = i;
          best_delta = delta;
        }
      }
      err = FT_Select_Size(face, best_match);
    }
  }
  if (err != 0)
    return err;

  font->face = face;
  font->palette = NULL;
  font->palette_count = 0;
  if (FT_HAS_COLOR(face)) {
    FT_Palette_Data palette_data;
    if (FT_Palette_Data_Get(face, &palette_data) == 0 && palette_data.num_palettes > 0) {
      FT_Color *palette = NULL;
      if (FT_Palette_Select(face, 0, &palette) == 0) {
        font->palette = palette;
        font->palette_count = palette_data.num_palette_entries;
      }
    }
  }
  if(FT_IS_SCALABLE(face)) {
    font->height = (short)((face->height / (float)face->units_per_EM) * font->size);
    font->baseline = (short)((face->ascender / (float)face->units_per_EM) * font->size);
    font->underline_thickness = (unsigned short)((face->underline_thickness / (float)face->units_per_EM) * font->size);
  } else {
    font->height = (short) font->face->size->metrics.height / 64.0f;
    font->baseline = (short) font->face->size->metrics.ascender / 64.0f;
  }
  if(!font->underline_thickness)
    font->underline_thickness = ceil((double) font->height / 14.0);

  /* Account for synthetic slant and leave room for hinting/emboldening. */
  double scale = face->units_per_EM ? font->size / face->units_per_EM : 1.0 / 64.0;
  double slant = font->style & FONT_STYLE_ITALIC ? 0.25 : 0;
  double left = floor((face->bbox.xMin + slant * face->bbox.yMin) * scale) - 2;
  double top = floor(-face->bbox.yMax * scale) - 2;
  font->glyph_bounds = (RenRect) { left, top,
    ceil((face->bbox.xMax + slant * face->bbox.yMax) * scale) + 2 - left,
    ceil(-face->bbox.yMin * scale) + 2 - top
  };
  if (!FT_IS_SCALABLE(face)) {
    font->glyph_bounds = (RenRect) {
      -font->size, -font->baseline - 1,
      fmax(font->size, face->size->metrics.max_advance / 64.0) + font->size + 1,
      font->height + font->baseline + 2
    };
  }

  if ((err = FT_Load_Char(face, ' ', (font_set_load_options(font) | FT_LOAD_BITMAP_METRICS_ONLY | FT_LOAD_NO_HINTING) & ~FT_LOAD_FORCE_AUTOHINT)) != 0)
    return err;
  font->space_advance = face->glyph->advance.x / 64.0f;

  if (font->hb_font)
    hb_font_destroy(font->hb_font);
  font->hb_font = hb_ft_font_create_referenced(face);
  return 0;
}

/* Open through SDL so Unicode paths also work on Windows. */
static FT_Error font_open_face(const char *path, FT_Long index, FT_Face *face) {
  SDL_IOStream *file = SDL_IOFromFile(path, "rb");
  if (!file) return FT_Err_Cannot_Open_Resource;
  FT_Stream stream = check_alloc(SDL_calloc(1, sizeof(FT_StreamRec)));
  stream->read = font_file_read;
  stream->close = font_file_close;
  stream->descriptor.pointer = file;
  stream->size = (unsigned long)SDL_GetIOSize(file);
  FT_Open_Args args = { .flags = FT_OPEN_STREAM, .stream = stream };
  FT_Error err = FT_Open_Face(library, &args, index, face);
  /* FreeType closes the stream on failure as well as on FT_Done_Face. */
  return err;
}

/* Load the exact native face, rather than assuming face zero of a collection. */
static RenFont *font_load_face(const char *path, float size,
  ERenFontAntialiasing antialiasing, ERenFontHinting hinting, unsigned char style,
  bool ligatures, bool system_fallback, const FallbackFontMatch *match) {
  FT_Face face = NULL;
  FT_Error err = font_open_face(path, match && match->face_index >= 0 ? match->face_index : 0, &face);
  if (err) { SDL_SetError("%s", get_ft_error(err)); return NULL; }
  if (match && match->face_index < 0 && match->postscript_name) {
    FT_Long count = face->num_faces;
    FT_Long index = 0;
    while (count > 1 && (!FT_Get_Postscript_Name(face)
        || strcmp(FT_Get_Postscript_Name(face), match->postscript_name))) {
      FT_Done_Face(face);
      face = NULL;
      if (++index >= count || (err = font_open_face(path, index, &face))) {
        if (err) SDL_SetError("%s", get_ft_error(err));
        return NULL;
      }
    }
  }
  if (match && match->axis_count && FT_HAS_MULTIPLE_MASTERS(face)) {
    FT_MM_Var *variation = NULL;
    if (!FT_Get_MM_Var(face, &variation)) {
      FT_Fixed *coords = check_alloc(SDL_malloc(variation->num_axis * sizeof(*coords)));
      for (FT_UInt i = 0; i < variation->num_axis; i++) {
        coords[i] = variation->axis[i].def;
        for (size_t j = 0; j < match->axis_count; j++) {
          if (variation->axis[i].tag == match->axes[j].tag)
            coords[i] = (FT_Fixed)SDL_clamp(match->axes[j].value * 65536.0,
              variation->axis[i].minimum, variation->axis[i].maximum);
        }
      }
      err = FT_Set_Var_Design_Coordinates(face, variation->num_axis, coords);
      SDL_free(coords);
      FT_Done_MM_Var(library, variation);
      if (err) { FT_Done_Face(face); return NULL; }
    }
  }
  RenFont *font = check_alloc(SDL_calloc(1, sizeof(RenFont) + strlen(path) + 1));
  strcpy(font->path, path);
  font->size = size;
  font->antialiasing = antialiasing;
  font->hinting = hinting;
  font->style = style;
  /* Do not synthesize a style already supplied by the native face. */
  if (match && (face->style_flags & FT_STYLE_FLAG_BOLD)) font->style &= ~FONT_STYLE_BOLD;
  if (match && (face->style_flags & FT_STYLE_FLAG_ITALIC)) font->style &= ~FONT_STYLE_ITALIC;
  font->ligatures = ligatures;
  font->system_fallback = system_fallback;
  font->tab_size = 2;
  font->fallback_scale = match ? match->scale : 1;
  if ((err = font_set_face_metrics(font, face))) {
    FT_Done_Face(face);
    SDL_free(font);
    SDL_SetError("%s", get_ft_error(err));
    return NULL;
  }
  font->glyphs.row_count = ((size_t)face->num_glyphs + GLYPHMAP_COL - 1) / GLYPHMAP_COL;
  for (int i = 0; i < FONT_BITMAP_COUNT(font); i++)
    font->glyphs.metrics[i] = check_alloc(SDL_calloc(font->glyphs.row_count, sizeof(GlyphMetric *)));
  renbackend_current()->init_atlas(&font->glyphs.atlas);
  font_link_loaded(font);
  return font;
}

RenFont* ren_font_load(const char* path, float size, ERenFontAntialiasing antialiasing,
  ERenFontHinting hinting, unsigned char style, bool ligatures, bool system_fallback) {
  return font_load_face(path, size, antialiasing, hinting, style, ligatures, system_fallback, NULL);
}

RenFont* ren_font_copy(RenFont* font, float size, ERenFontAntialiasing antialiasing,
  ERenFontHinting hinting, int style, int ligatures, int system_fallback) {
  antialiasing = antialiasing == -1 ? font->antialiasing : antialiasing;
  hinting = hinting == -1 ? font->hinting : hinting;
  style = style == -1 ? font->style : style;
  ligatures = ligatures == -1 ? font->ligatures : ligatures;
  system_fallback = system_fallback == -1 ? font->system_fallback : system_fallback;
  return ren_font_load(font->path, size, antialiasing, hinting, style, ligatures, system_fallback);
}

const char* ren_font_get_path(RenFont *font) {
  return font->path;
}

void ren_font_free(RenFont* font) {
  while (font->fallback_fonts) {
    RenFont *child = font->fallback_fonts;
    font->fallback_fonts = child->next_fallback;
    ren_font_free(child);
  }
  fallback_font_free(font->resolver);
  font_clear_cluster_cache(&font->coverage_cache);
  font_clear_cluster_cache(&font->fallback_cache);
  font_clear_layouts(font);
  SDL_free(font->fallback_index);
  SDL_free(font->fallback_roles);
  font_unlink_loaded(font);
  font_clear_glyph_cache(font);
  ren_atlas_free(&font->glyphs.atlas);
  for (int i = 0; i < SUBPIXEL_BITMAPS_CACHED; i++) SDL_free(font->glyphs.metrics[i]);
  // free codepoint cache as well
  font_clear_charmap(&font->charmap);
  font_clear_charmap(&font->fallback_characters);
  if (font->hb_font)
    hb_font_destroy(font->hb_font);
  FT_Done_Face(font->face);
  SDL_free(font);
}

/**
 * Function adapted from https://github.com/GNOME/libxml2/blob/master/encoding.c
 */
static int UTF16BEToUTF8(
  unsigned char* out, int *outlen, const unsigned char* inb, int *inlenb
) {
  unsigned short int tst = 0x1234;
  unsigned char *ptr = (unsigned char *) &tst;

  bool little_endian = true;
  if (*ptr == 0x12) little_endian = false;
  else if (*ptr == 0x34) little_endian = true;

  unsigned char* outstart = out;
  const unsigned char* processed = inb;
  unsigned char* outend;
  unsigned short* in = (unsigned short*) inb;
  unsigned short* inend;
  unsigned int c, d, inlen;
  unsigned char *tmp;
  int bits;

  if (*outlen == 0) {
    *inlenb = 0;
    return(0);
  }

  outend = out + *outlen;
  if ((*inlenb % 2) == 1)
    (*inlenb)--;
  inlen = *inlenb / 2;
  inend= in + inlen;
  while ((in < inend) && (out - outstart + 5 < *outlen)) {
    if (little_endian) {
      tmp = (unsigned char *) in;
      c = *tmp++;
      c = (c << 8) | (unsigned int) *tmp;
      in++;
    } else {
      c= *in++;
    }
    if ((c & 0xFC00) == 0xD800) {    /* surrogates */
      if (in >= inend) {           /* handle split mutli-byte characters */
        break;
      }
      if (little_endian) {
        tmp = (unsigned char *) in;
        d = *tmp++;
        d = (d << 8) | (unsigned int) *tmp;
        in++;
      } else {
        d = *in++;
      }
      if ((d & 0xFC00) == 0xDC00) {
        c &= 0x03FF;
        c <<= 10;
        c |= d & 0x03FF;
        c += 0x10000;
      }
      else {
        *outlen = out - outstart;
        *inlenb = processed - inb;
        return(-2);
      }
    }

    /* assertion: c is a single UTF-4 value */
    if (out >= outend)
      break;

    if      (c <    0x80) {  *out++=  c;                bits= -6; }
    else if (c <   0x800) {  *out++= ((c >>  6) & 0x1F) | 0xC0;  bits=  0; }
    else if (c < 0x10000) {  *out++= ((c >> 12) & 0x0F) | 0xE0;  bits=  6; }
    else                  {  *out++= ((c >> 18) & 0x07) | 0xF0;  bits= 12; }

    for ( ; bits >= 0; bits-= 6) {
      if (out >= outend)
        break;
      *out++= ((c >> bits) & 0x3F) | 0x80;
    }
    processed = (const unsigned char*) in;
  }
  *outlen = out - outstart;
  *inlenb = processed - inb;
  return(*outlen);
}

int ren_font_get_metadata(
  const char *path, FontMetaData **data, int *count, bool *monospaced
) {
  *data = NULL;
  *count = 0;
  *monospaced = false;

  int found = 0;
  FT_Face face;
  int ret_code = 0;
  int error = FT_New_Face(library, path, 0, &face);

  if (error == 0 )
    found = FT_Get_Sfnt_Name_Count(face);

  if (found > 0) {
    int meta_count = 0;
    for (int i=0; i<found; i++) {
      FT_SfntName metaprop;
      FT_Get_Sfnt_Name(face, i, &metaprop);

      unsigned char *name = SDL_malloc(metaprop.string_len * 2);
      int outlen, inlen;
      outlen = metaprop.string_len * 2;
      inlen = metaprop.string_len;

      if (UTF16BEToUTF8(name, &outlen, metaprop.string, &inlen) == -2) {
        memcpy(name, metaprop.string, metaprop.string_len);
        outlen = metaprop.string_len;
      }

      int lang_id = metaprop.language_id;
      FontMetaData meta = { -1, NULL, 0 };

      if (
        lang_id == TT_MAC_LANGID_ENGLISH
        || lang_id == TT_MS_LANGID_ENGLISH_UNITED_STATES
        || lang_id == TT_MS_LANGID_ENGLISH_UNITED_KINGDOM
        || lang_id == TT_MS_LANGID_ENGLISH_AUSTRALIA
        || lang_id == TT_MS_LANGID_ENGLISH_CANADA
        || lang_id == TT_MS_LANGID_ENGLISH_NEW_ZEALAND
        || lang_id == TT_MS_LANGID_ENGLISH_IRELAND
        || lang_id == TT_MS_LANGID_ENGLISH_SOUTH_AFRICA
        || lang_id == TT_MS_LANGID_ENGLISH_JAMAICA
        || lang_id == TT_MS_LANGID_ENGLISH_CARIBBEAN
        || lang_id == TT_MS_LANGID_ENGLISH_BELIZE
        || lang_id == TT_MS_LANGID_ENGLISH_TRINIDAD
        || lang_id == TT_MS_LANGID_ENGLISH_ZIMBABWE
        || lang_id == TT_MS_LANGID_ENGLISH_PHILIPPINES
        || lang_id == TT_MS_LANGID_ENGLISH_INDIA
        || lang_id == TT_MS_LANGID_ENGLISH_MALAYSIA
        || lang_id == TT_MS_LANGID_ENGLISH_SINGAPORE
      ) {
        switch(metaprop.name_id) {
          case TT_NAME_ID_FONT_FAMILY:
            meta.tag = FONT_FAMILY;
            break;
          case TT_NAME_ID_FONT_SUBFAMILY:
            meta.tag = FONT_SUBFAMILY;
            break;
          case TT_NAME_ID_UNIQUE_ID:
            meta.tag = FONT_ID;
            break;
          case TT_NAME_ID_FULL_NAME:
            meta.tag = FONT_FULLNAME;
            break;
          case TT_NAME_ID_VERSION_STRING:
            meta.tag = FONT_VERSION;
            break;
          case TT_NAME_ID_PS_NAME:
            meta.tag = FONT_PSNAME;
            break;
          case TT_NAME_ID_TYPOGRAPHIC_FAMILY:
            meta.tag = FONT_TFAMILY;
            break;
          case TT_NAME_ID_TYPOGRAPHIC_SUBFAMILY:
            meta.tag = FONT_TSUBFAMILY;
            break;
          case TT_NAME_ID_WWS_FAMILY:
            meta.tag = FONT_WWSFAMILY;
            break;
          case TT_NAME_ID_WWS_SUBFAMILY:
            meta.tag = FONT_WWSSUBFAMILY;
            break;
          case TT_NAME_ID_SAMPLE_TEXT:
            meta.tag = FONT_SAMPLETEXT;
            break;
        }
      }
      if (meta.tag == -1) {
        SDL_free(name);
      } else {
        meta.value = (char*) name;
        meta.len = outlen;

        if (meta_count == 0) {
          *data = SDL_malloc(sizeof(FontMetaData));
        } else {
          *data = SDL_realloc(*data, sizeof(FontMetaData) * (meta_count+1));
        }
        memcpy((*data)+meta_count, &meta, sizeof(FontMetaData));
        meta_count++;
      }
    }
    *monospaced = FT_IS_FIXED_WIDTH(face);
    *count = meta_count;
  } else if (error != 0) {
    ret_code = 2;
  } else {
    ret_code = 1;
  }

  if (error == 0)
    FT_Done_Face(face);

  return ret_code;
}

void ren_font_group_set_tab_size(RenFont **fonts, int n) {
  for (int j = 0; j < FONT_FALLBACK_MAX && fonts[j]; ++j) {
    fonts[j]->tab_size = n;
  }
}

int ren_font_group_get_tab_size(RenFont **fonts) {
  return fonts[0]->tab_size;
}

float ren_font_group_get_size(RenFont **fonts) {
  return fonts[0]->size;
}

void ren_font_group_set_size(RenFont **fonts, float size) {
  for (int i = 0; i < FONT_FALLBACK_MAX && fonts[i]; ++i) {
    font_clear_glyph_cache(fonts[i]);
    fonts[i]->size = size;
    fonts[i]->tab_size = 2;
    font_set_face_metrics(fonts[i], fonts[i]->face);
    font_clear_cluster_cache(&fonts[i]->coverage_cache);
    font_clear_cluster_cache(&fonts[i]->fallback_cache);
    font_clear_layouts(fonts[i]);
    font_clear_charmap(&fonts[i]->fallback_characters);
    fallback_font_free(fonts[i]->resolver);
    fonts[i]->resolver = NULL;
    fonts[i]->resolver_initialized = false;
    for (RenFont *child = fonts[i]->fallback_fonts; child; child = child->next_fallback) {
      font_clear_glyph_cache(child);
      font_clear_cluster_cache(&child->coverage_cache);
      child->size = size * child->fallback_scale;
      font_set_face_metrics(child, child->face);
    }
  }
}

int ren_font_group_get_height(RenFont **fonts) {
  return fonts[0]->height;
}

RenRect ren_font_group_get_text_bounds(RenFont **fonts, double x, double y, double width) {
  double left = 0, top = 0, right = 0;
  double bottom = fonts[0]->height + fonts[0]->underline_thickness;
  for (int i = 0; i < FONT_FALLBACK_MAX && fonts[i]; i++) {
    for (RenFont *font = fonts[i]; font; font = font == fonts[i] ? font->fallback_fonts : font->next_fallback) {
      RenRect bounds = font->glyph_bounds;
      left = SDL_min(left, bounds.x);
      top = SDL_min(top, fonts[0]->baseline + bounds.y);
      right = SDL_max(right, bounds.x + bounds.width);
      bottom = SDL_max(bottom, fonts[0]->baseline + bounds.y + bounds.height);
    }
  }
  return (RenRect) { x + left, y + top, width + right - left, bottom - top };
}

int ren_font_group_get_style(RenFont **fonts) {
  return fonts[0]->style;
}

int ren_font_group_get_underline_thickness(RenFont **fonts) {
  return fonts[0]->underline_thickness;
}

// some fonts provide xadvance for whitespaces (e.g. Unifont), which we need to ignore
float font_get_xadvance(RenFont *font, unsigned int codepoint, GlyphMetric *metric, double curr_x, RenTab tab) {
  if (!is_whitespace(codepoint) && metric && metric->xadvance) {
    return metric->xadvance;
  }
  if (codepoint != '\t') {
    return font->space_advance;
  }
  float tab_size = font->space_advance * font->tab_size;
  if (isnan(tab.offset)) {
    return tab_size;
  }
  double offset = fmodl(curr_x + tab.offset, tab_size);
  float adv = tab_size - offset;
  // If there is not enough space until the next stop, skip it
  if (adv < font->space_advance) {
    adv += tab_size;
  }
  return adv;
}

static double hb_position_to_pixels(hb_position_t value) {
  return value / 64.0;
}

static double hb_position_to_font_pixels(RenFont *font, hb_position_t value) {
  double pixels = hb_position_to_pixels(value);
  if (FT_HAS_COLOR(font->face))
    pixels *= font->color_scale;
  return pixels;
}

static bool text_needs_shaping(const char *text, const char *end) {
  while (text < end) {
    unsigned char c = *(const unsigned char *) text++;
    if (c >= 0x80)
      return true;
    switch (c) {
      case '=': case '-': case '>': case '<': case '!': case '/':
      case '*': case ':': case '.': case '|': case '&': case 'f':
        return true;
    }
  }
  return false;
}

/* Single-byte ASCII has no grapheme work unless followed by a non-ASCII mark. */
static const char *font_cluster_end(const char *text, const char *end) {
  if ((unsigned char)*text < 0x80 && (text + 1 == end || (unsigned char)text[1] < 0x80))
    return text + 1;
  const char *next = Lutf8_grapheme_next(text, end);
  if (next) return next;
  unsigned int cp;
  return utf8_to_codepoint(text, end, &cp);
}

static FontClusterCacheEntry *font_cluster_cache_entry(FontClusterCacheEntry **cache,
                                                       const char *text, size_t len) {
  if (len > FONT_CLUSTER_CACHE_MAX_TEXT) return NULL;
  if (!*cache) *cache = check_alloc(SDL_calloc(FONT_CLUSTER_CACHE_MAX, sizeof(**cache)));
  return &(*cache)[hash_bytes(text, len) % FONT_CLUSTER_CACHE_MAX];
}

static bool font_cluster_cache_matches(FontClusterCacheEntry *entry, const char *text, size_t len) {
  return entry && entry->text && entry->len == len && !memcmp(entry->text, text, len);
}

static void font_cluster_cache_store(FontClusterCacheEntry *entry, const char *text, size_t len, RenFont *font) {
  if (!entry) return;
  SDL_free(entry->text);
  entry->text = check_alloc(SDL_malloc(len));
  memcpy(entry->text, text, len);
  entry->len = len;
  entry->font = font;
}

static bool font_text_is_emoji(const char *text, const char *end) {
  bool emoji = false;
  while (text < end) {
    unsigned int cp;
    text = utf8_to_codepoint(text, end, &cp);
    if (cp == 0xFE0E) return false;
    if (cp == 0xFE0F || cp == 0x20E3 || (cp >= 0x1F000 && cp <= 0x1FAFF)) emoji = true;
  }
  return emoji;
}

/* Required shaping does not depend on the optional programming ligature flag.
 * Keep emoji substitutions and complex-script shaping; suppress optional Latin
 * ligatures/contextual alternates when the user has disabled them.
 */
static void font_shape(hb_buffer_t *buffer, RenFont *font, const char *text, size_t len) {
  hb_buffer_clear_contents(buffer);
  hb_buffer_add_utf8(buffer, text, len, 0, len);
  hb_buffer_guess_segment_properties(buffer);
  hb_feature_t features[] = {
    { HB_TAG('l','i','g','a'), 0, 0, (unsigned)-1 },
    { HB_TAG('c','l','i','g'), 0, 0, (unsigned)-1 },
    { HB_TAG('c','a','l','t'), 0, 0, (unsigned)-1 }
  };
  hb_script_t script = hb_buffer_get_script(buffer);
  bool disable = !font->ligatures && !font_text_is_emoji(text, text + len)
    && (script == HB_SCRIPT_LATIN || script == HB_SCRIPT_GREEK
        || script == HB_SCRIPT_CYRILLIC || script == HB_SCRIPT_COMMON);
  hb_shape(font->hb_font, buffer, disable ? features : NULL, disable ? SDL_arraysize(features) : 0);
}

/* Coverage includes shaping and presentation selectors, not just cmap entries. */
static bool font_supports_cluster(RenFont *font, const char *text, const char *end) {
  unsigned int cp;
  const char *next = utf8_to_codepoint(text, end, &cp);
  if (next == end)
    return Lutf8_isdefaultignorable(cp) || font_get_glyph_id(font, cp) != 0;
  size_t len = end - text;
  FontClusterCacheEntry *entry = font_cluster_cache_entry(&font->coverage_cache, text, len);
  if (font_cluster_cache_matches(entry, text, len)) return entry->font != NULL;
  unsigned int previous = 0;
  bool supported = true, emoji_sequence = false;
  for (const char *p = text; p < end;) {
    p = utf8_to_codepoint(p, end, &cp);
    if (cp == 0xFE0F && previous && !FT_HAS_COLOR(font->face)
        && FT_Face_GetCharVariantIsDefault(font->face, previous, cp) < 0) {
      supported = false;
      break;
    }
    if (cp == 0xFE0E && previous && FT_HAS_COLOR(font->face)
        && FT_Face_GetCharVariantIsDefault(font->face, previous, cp) < 0) {
      supported = false;
      break;
    }
    if (!Lutf8_isdefaultignorable(cp) && !font_get_glyph_id(font, cp)) {
      supported = false;
      break;
    }
    if (cp == 0x200D || (cp >= 0x1F3FB && cp <= 0x1F3FF)
        || (previous >= 0x1F1E6 && previous <= 0x1F1FF && cp >= 0x1F1E6 && cp <= 0x1F1FF))
      emoji_sequence = true;
    previous = cp;
  }
  if (supported) {
    hb_buffer_t *buffer = hb_buffer_create();
    font_shape(buffer, font, text, len);
    unsigned int count;
    hb_glyph_info_t *infos = hb_buffer_get_glyph_infos(buffer, &count);
    for (unsigned int i = 0; i < count; i++) {
      if (!infos[i].codepoint) { supported = false; break; }
    }
    if (emoji_sequence && font_text_is_emoji(text, end) && count != 1) supported = false;
    hb_buffer_destroy(buffer);
  }
  font_cluster_cache_store(entry, text, len, supported ? font : NULL);
  return supported;
}

typedef struct {
  RenFont *primary, *selected;
  const char *text, *end;
} NativeFontSelection;

static bool font_accept_fallback(void *userdata, const FallbackFontMatch *match) {
  NativeFontSelection *selection = userdata;
  RenFont *primary = selection->primary;
  uint32_t variation_hash = 0;
  for (size_t i = 0; i < match->axis_count; i++) {
    variation_hash = (variation_hash ^ hash_bytes(&match->axes[i].tag, sizeof(match->axes[i].tag))) * 16777619u;
    variation_hash = (variation_hash ^ hash_bytes(&match->axes[i].value, sizeof(match->axes[i].value))) * 16777619u;
  }
  for (RenFont *font = primary->fallback_fonts; font; font = font->next_fallback) {
    if (!strcmp(font->path, match->path) && font->variation_hash == variation_hash
        && font->fallback_scale == match->scale
        && (match->face_index >= 0 ? font->face->face_index == match->face_index
          : font->face->num_faces == 1 || (match->postscript_name && FT_Get_Postscript_Name(font->face)
            && !strcmp(FT_Get_Postscript_Name(font->face), match->postscript_name)))) {
      if (font_supports_cluster(font, selection->text, selection->end)) {
        selection->selected = font;
        return true;
      }
      return false;
    }
  }
  RenFont *font = font_load_face(match->path, primary->size * match->scale,
    primary->antialiasing, primary->hinting, primary->style, primary->ligatures, false, match);
  if (!font) return false;
  if (!font_supports_cluster(font, selection->text, selection->end)) {
    ren_font_free(font);
    return false;
  }
  font->variation_hash = variation_hash;
  font->next_fallback = primary->fallback_fonts;
  primary->fallback_fonts = font;
  primary->fallback_index = check_alloc(SDL_realloc(primary->fallback_index,
    (primary->fallback_count + 1) * sizeof(RenFont *)));
  primary->fallback_index[primary->fallback_count++] = font;
  selection->selected = font;
  return true;
}

static hb_script_t font_cluster_script(const char *text, const char *end);

static RenFont *font_select_cluster(RenFont **fonts, const char *text, const char *end) {
  unsigned int cp;
  const char *scalar_end = utf8_to_codepoint(text, end, &cp);
  if (is_whitespace(cp) || (scalar_end == end && Lutf8_isdefaultignorable(cp))) return fonts[0];
  for (int i = 0; i < FONT_FALLBACK_MAX && fonts[i]; i++) {
    if (font_supports_cluster(fonts[i], text, end)) return fonts[i];
  }
  RenFont *primary = fonts[0];
  if (!primary->system_fallback) return NULL;
  size_t len = end - text;
  unsigned int *character = NULL;
  FontClusterCacheEntry *entry = NULL;
  if (scalar_end == end) {
    character = font_charmap_entry(&primary->fallback_characters, cp);
    if (*character) return *character == 1 ? NULL : primary->fallback_index[*character - 2];
  } else {
    entry = font_cluster_cache_entry(&primary->fallback_cache, text, len);
    if (font_cluster_cache_matches(entry, text, len)) return entry->font;
  }
  /* Reuse faces within the script/presentation for which the OS chose them.
   * A text-symbol face must not become the emoji font simply because it was
   * discovered first while opening an unrelated document.
   */
  uint64_t role = (uint32_t)font_cluster_script(text, end)
    | (uint64_t)font_text_is_emoji(text, end) << 32;
  RenFont *selected = NULL;
  for (size_t i = 0; i < primary->fallback_role_count; i++) {
    FontFallbackRole *candidate = &primary->fallback_roles[i];
    if (candidate->role == role && font_supports_cluster(candidate->font, text, end)) {
      selected = candidate->font;
      break;
    }
  }
  if (selected) goto store_selection;
  if (!primary->resolver_initialized) {
    primary->resolver_initialized = true;
    FT_Face face = primary->face;
    primary->resolver = fallback_font_create(primary->path, face->family_name,
      FT_Get_Postscript_Name(face), primary->size,
      (primary->style & FONT_STYLE_BOLD) || (face->style_flags & FT_STYLE_FLAG_BOLD),
      (primary->style & FONT_STYLE_ITALIC) || (face->style_flags & FT_STYLE_FLAG_ITALIC));
  }
  NativeFontSelection selection = {primary, NULL, text, end};
  fallback_font_resolve(primary->resolver, text, len, font_accept_fallback, &selection);
  selected = selection.selected;
  if (selected) {
    primary->fallback_roles = check_alloc(SDL_realloc(primary->fallback_roles,
      (primary->fallback_role_count + 1) * sizeof(FontFallbackRole)));
    primary->fallback_roles[primary->fallback_role_count++] = (FontFallbackRole){role, selected};
  }
store_selection:
  if (character) {
    *character = 1;
    for (size_t i = 0; selected && i < primary->fallback_count; i++) {
      if (primary->fallback_index[i] == selected) { *character = i + 2; break; }
    }
  } else {
    font_cluster_cache_store(entry, text, len, selected);
  }
  return selected;
}

static hb_script_t font_cluster_script(const char *text, const char *end) {
  while (text < end) {
    unsigned int cp;
    text = utf8_to_codepoint(text, end, &cp);
    hb_script_t script = hb_unicode_script(hb_unicode_funcs_get_default(), cp);
    if (script != HB_SCRIPT_COMMON && script != HB_SCRIPT_INHERITED) return script;
  }
  return HB_SCRIPT_COMMON;
}

/* Single glyphs in these scripts do not need shaping when optional ligatures
 * are disabled. Combining sequences and complex scripts still use HarfBuzz.
 */
static bool font_needs_shaping(RenFont *font, unsigned int cp, bool single) {
  if (font->ligatures || !single) return true;
  return !(cp < 0x530 || (cp >= 0x2E80 && cp <= 0xA4CF)
    || (cp >= 0xAC00 && cp <= 0xD7A3) || (cp >= 0xF900 && cp <= 0xFAFF)
    || (cp >= 0x1F000 && cp <= 0x1FAFF) || (cp >= 0x20000 && cp <= 0x323AF));
}

/* Both width measurement and drawing consume precisely the same selected runs. */
static const char *font_next_run(RenFont **fonts, const char *text, const char *end,
                                RenFont **selected, bool *shaped) {
  /* Preserve the ordinary editor path: scan covered ASCII without Unicode
   * classification, native lookup or per-character run construction. Leave
   * ASCII followed by non-ASCII to the grapheme path (it may have a mark).
   */
  if ((unsigned char)*text < 0x80 && (text + 1 == end || (unsigned char)text[1] < 0x80)) {
    RenFont *primary = fonts[0];
    const char *p = text;
    bool whitespace = is_whitespace((unsigned char)*p);
    if (whitespace || font_get_glyph_id(primary, (unsigned char)*p)) {
      *selected = primary;
      *shaped = primary->ligatures && !whitespace;
      if (primary->ligatures && whitespace) return text + 1;
      do {
        p++;
        if (*shaped && (p == end || is_whitespace((unsigned char)*p))) break;
      } while (p < end && (unsigned char)*p < 0x80
        && (p + 1 == end || (unsigned char)p[1] < 0x80)
        && (is_whitespace((unsigned char)*p) || font_get_glyph_id(primary, (unsigned char)*p)));
      return p;
    }
  }
  unsigned int cp;
  const char *scalar_end = utf8_to_codepoint(text, end, &cp);
  const char *next = font_cluster_end(text, end);
  RenFont *font = font_select_cluster(fonts, text, next);
  *shaped = false;
  if (!font) {
    /* No font can cover the whole cluster. Degrade to configured characters
     * without recursively requesting the same impossible native match.
     */
    font = fonts[0];
    for (int i = 0; i < FONT_FALLBACK_MAX && fonts[i]; i++) {
      font = fonts[i];
      if (font_get_glyph_id(font, cp)) break;
    }
    *selected = font;
    return scalar_end;
  }
  *selected = font;
  if (is_whitespace(cp) || (scalar_end == next && Lutf8_isdefaultignorable(cp))) return next;
  if (!font_needs_shaping(font, cp, next == scalar_end)) {
    while (next < end) {
      const char *scalar = utf8_to_codepoint(next, end, &cp);
      const char *cluster = font_cluster_end(next, end);
      if (is_whitespace(cp) || Lutf8_isdefaultignorable(cp)
          || font_needs_shaping(font, cp, cluster == scalar)
          || font_select_cluster(fonts, next, cluster) != font) break;
      next = cluster;
    }
    return next;
  }
  *shaped = true;
  hb_script_t script = font_cluster_script(text, next);
  bool emoji = font_text_is_emoji(text, next);
  while (next < end) {
    const char *cluster_end = font_cluster_end(next, end);
    const char *scalar = utf8_to_codepoint(next, cluster_end, &cp);
    if (is_whitespace(cp) || (scalar == cluster_end && Lutf8_isdefaultignorable(cp))
        || (!font->ligatures && cp < 0x80 && next + 1 == cluster_end)
        || font_text_is_emoji(next, cluster_end) != emoji) break;
    hb_script_t next_script = font_cluster_script(next, cluster_end);
    if (script != HB_SCRIPT_COMMON && next_script != HB_SCRIPT_COMMON && script != next_script) break;
    if (font_select_cluster(fonts, next, cluster_end) != font) break;
    if (script == HB_SCRIPT_COMMON) script = next_script;
    next = cluster_end;
  }
  return next;
}

/* Cache selected runs without retaining user-supplied fallback fonts. Group
 * identities and generations are checked before any stored font is used. */
static FontTextLayout *font_text_layout(RenFont **fonts, const char *text, size_t len) {
  if (!len || (unsigned char)*text < 0x80 || len > FONT_LAYOUT_CACHE_MAX_TEXT) return NULL;
  uint64_t group = 14695981039346656037ull;
  for (size_t i = 0; i < FONT_FALLBACK_MAX && fonts[i]; i++) {
    group = (group ^ fonts[i]->identity) * 1099511628211ull;
    group = (group ^ fonts[i]->generation) * 1099511628211ull;
  }
  RenFont *primary = fonts[0];
  if (!primary->layouts)
    primary->layouts = check_alloc(SDL_calloc(FONT_LAYOUT_CACHE_MAX, sizeof(FontTextLayout)));
  FontTextLayout *layout = &primary->layouts[hash_bytes(text, len) % FONT_LAYOUT_CACHE_MAX];
  if (layout->text && layout->len == len && layout->group == group && !memcmp(layout->text, text, len))
    return layout;
  FontTextRun runs[FONT_LAYOUT_CACHE_MAX_BYTES / sizeof(FontTextRun)];
  size_t count = 0;
  const char *p = text;
  while (p < text + len) {
    if ((count + 1) * sizeof(FontTextRun) + len > FONT_LAYOUT_CACHE_MAX_BYTES) return NULL;
    FontTextRun *run = &runs[count++];
    p = font_next_run(fonts, p, text + len, &run->font, &run->shaped);
    run->end = p - text;
  }
  SDL_free(layout->text);
  SDL_free(layout->runs);
  layout->text = check_alloc(SDL_malloc(len));
  memcpy(layout->text, text, len);
  layout->len = len;
  layout->group = group;
  layout->count = count;
  layout->runs = check_alloc(SDL_malloc(count * sizeof(FontTextRun)));
  memcpy(layout->runs, runs, count * sizeof(FontTextRun));
  return layout;
}

/* Load a nominal glyph only after the common run selector chose its font. */
static RenFont *font_get_character(RenFont *font, unsigned int cp, int subpixel_idx,
                                  SDL_Surface **surface, GlyphMetric **metric) {
  unsigned int glyph = font_get_glyph_id(font, cp);
  font_get_glyph_by_id(font, glyph, subpixel_idx, is_whitespace(cp) ? NULL : surface, metric);
  if (!*metric && cp != 0x25A1)
    font_get_glyph_by_id(font, font_get_glyph_id(font, 0x25A1), subpixel_idx, surface, metric);
  return font;
}

static double unshaped_run_get_width(RenFont **fonts, RenFont *font, const char *text, const char *end, double width, RenTab tab, int *x_offset, bool *set_x_offset) {
  while (text < end) {
    unsigned int codepoint;
    text = utf8_to_codepoint(text, end, &codepoint);
    GlyphMetric *metric = NULL;
    if (codepoint >= 0xAD && Lutf8_isdefaultignorable(codepoint)) continue;
    font_get_character(font, codepoint, 0, NULL, &metric);
    width += font_get_xadvance(fonts[0], codepoint, metric, width, tab);
    if (!*set_x_offset && metric) {
      *set_x_offset = true;
      *x_offset = metric->bitmap_left;
    }
  }
  return width;
}

static double shaped_run_get_width(hb_buffer_t *buffer, RenFont *font, const char *text, size_t len, int *x_offset, bool *set_x_offset) {
  uint32_t hash_value = 0;
  bool cacheable = len <= SHAPED_WIDTH_CACHE_MAX_TEXT;

  if (cacheable) {
    hash_value = hash_bytes(text, len);
    ShapedWidthCacheEntry *cached = font_lookup_shaped_width_cache(font, text, len, hash_value);
    if (cached) {
      if (!*set_x_offset && x_offset && cached->has_x_offset) {
        *x_offset = cached->x_offset;
        *set_x_offset = true;
      }
      return cached->width;
    }
  }

  font_shape(buffer, font, text, len);

  unsigned int glyph_count = 0;
  hb_glyph_info_t *infos = hb_buffer_get_glyph_infos(buffer, &glyph_count);
  hb_glyph_position_t *positions = hb_buffer_get_glyph_positions(buffer, NULL);
  double width = 0;
  int cached_x_offset = 0;
  bool cached_has_x_offset = false;

  for (unsigned int i = 0; i < glyph_count; i++) {
    if (!cached_has_x_offset) {
      GlyphMetric *metric = NULL;
      font_get_glyph_by_id(font, infos[i].codepoint, 0, NULL, &metric);
      if (metric) {
        cached_x_offset = metric->bitmap_left + hb_position_to_font_pixels(font, positions[i].x_offset);
        cached_has_x_offset = true;
        if (!*set_x_offset && x_offset) {
          *x_offset = cached_x_offset;
          *set_x_offset = true;
        }
      }
    }
    width += hb_position_to_font_pixels(font, positions[i].x_advance);
  }

  if (cacheable)
    font_store_shaped_width_cache(font, text, len, hash_value, width, cached_x_offset, cached_has_x_offset);
  return width;
}

double ren_font_group_get_width(RenFont **fonts, const char *text, size_t len, RenTab tab, int *x_offset) {
  double width = 0;
  const char *start = text;
  const char* end = text + len;
  hb_buffer_t *hb_buffer = NULL;
  FontTextLayout *layout = font_text_layout(fonts, text, len);
  size_t run_index = 0;

  bool set_x_offset = x_offset == NULL;
  while (text < end) {
    RenFont *font;
    bool shaped;
    const char *run_end;
    if (layout) {
      FontTextRun *run = &layout->runs[run_index++];
      font = run->font;
      shaped = run->shaped;
      run_end = start + run->end;
    } else {
      run_end = font_next_run(fonts, text, end, &font, &shaped);
    }
    if (shaped && text_needs_shaping(text, run_end)) {
      if (!hb_buffer) hb_buffer = hb_buffer_create();
      width += shaped_run_get_width(hb_buffer, font, text, run_end - text, x_offset, &set_x_offset);
    } else {
      width = unshaped_run_get_width(fonts, font, text, run_end, width, tab, x_offset, &set_x_offset);
    }
    text = run_end;
  }
  if (hb_buffer)
    hb_buffer_destroy(hb_buffer);
  if (!set_x_offset)
    *x_offset = 0;
  return width;
}

typedef struct {
  RenSurface *rs;
  SDL_Surface *surface;
  SDL_Rect clip;
  uint8_t *destination_pixels;
  int clip_end_x, clip_end_y;
  RenColor color;
  RenGlyphDrawFn glyph_fn;
  void *glyph_userdata;
} DrawGlyphContext;

static void draw_glyph_bitmap(DrawGlyphContext *ctx, RenFont **fonts, RenFont *font, SDL_Surface *font_surface, GlyphMetric *metric, double draw_x, double y, double y_offset, bool draw_missing) {
  unsigned int r, g, b;
  int start_x = floor(draw_x) + metric->bitmap_left;
  int end_x = metric->x1 + start_x; // x0 is assumed to be 0
  bool has_bitmap = font_surface && metric->x1 > 0 && metric->y1 > metric->y0;

  if (!has_bitmap && draw_missing) {
    ren_draw_rect(ctx->rs, (RenRect){ start_x + 1, y, font->space_advance - 1, ren_font_group_get_height(fonts) }, ctx->color, false);
    return;
  }
  if (!has_bitmap)
    return;
  if (ctx->color.a == 0 || end_x < ctx->clip.x || start_x >= ctx->clip_end_x)
    return;

  int dst_x = start_x;
  int dst_y = y - y_offset - metric->bitmap_top + fonts[0]->baseline;
  int src_x = 0;
  int src_y = metric->y0;
  int width = metric->x1;
  int height = metric->y1 - metric->y0;
  if (dst_x < ctx->clip.x) {
    int offset = ctx->clip.x - dst_x;
    dst_x += offset;
    src_x += offset;
    width -= offset;
  }
  if (dst_y < ctx->clip.y) {
    int offset = ctx->clip.y - dst_y;
    dst_y += offset;
    src_y += offset;
    height -= offset;
  }
  if (dst_x + width > ctx->clip_end_x)
    width = ctx->clip_end_x - dst_x;
  if (dst_y + height > ctx->clip_end_y)
    height = ctx->clip_end_y - dst_y;
  if (width <= 0 || height <= 0)
    return;
  if (ctx->glyph_fn) {
    RenGlyphDraw glyph = {
      .atlas = &font->glyphs.atlas,
      .surface = font_surface,
      .metric = metric,
      .color = ctx->color,
      .dst_x = dst_x,
      .dst_y = dst_y,
      .src_x = src_x,
      .src_y = src_y,
      .width = width,
      .height = height,
      .format = metric->format,
    };
    if (ctx->glyph_fn(ctx->glyph_userdata, &glyph))
      return;
  }

  uint8_t* source_pixels = font_surface->pixels;
  const SDL_PixelFormatDetails* surface_format = SDL_GetPixelFormatDetails(ctx->surface->format);
  const SDL_PixelFormatDetails* font_surface_format = SDL_GetPixelFormatDetails(font_surface->format);

  for (int line = metric->y0; line < metric->y1; ++line) {
    int line_start_x = start_x;
    int glyph_start = 0;
    int glyph_end = metric->x1;
    int target_y = line - metric->y0 + y - y_offset - metric->bitmap_top + fonts[0]->baseline;
    if (target_y < ctx->clip.y)
      continue;
    if (target_y >= ctx->clip_end_y)
      break;
    if (line_start_x + (glyph_end - glyph_start) >= ctx->clip_end_x)
      glyph_end = glyph_start + (ctx->clip_end_x - line_start_x);
    if (line_start_x < ctx->clip.x) {
      int offset = ctx->clip.x - line_start_x;
      line_start_x += offset;
      glyph_start += offset;
    }

    uint32_t* destination_pixel = (uint32_t*)&(ctx->destination_pixels[ctx->surface->pitch * target_y + line_start_x * surface_format->bytes_per_pixel]);
    uint8_t* source_pixel = &source_pixels[line * font_surface->pitch + glyph_start * font_surface_format->bytes_per_pixel];
    for (int x = glyph_start; x < glyph_end; ++x) {
      uint32_t destination_color = *destination_pixel;
      // the standard way of doing this would be SDL_GetRGBA, but that introduces a performance regression. needs to be investigated
      SDL_Color dst = {
        (destination_color & surface_format->Rmask) >> surface_format->Rshift,
        (destination_color & surface_format->Gmask) >> surface_format->Gshift,
        (destination_color & surface_format->Bmask) >> surface_format->Bshift,
        (destination_color & surface_format->Amask) >> surface_format->Ashift};
      SDL_Color src;

      if (metric->format == EGlyphFormatColor) {
        unsigned int src_a = (source_pixel[3] * ctx->color.a + 127) / 255;
        unsigned int inv_a = 255 - src_a;
        r = (source_pixel[2] * ctx->color.a + 127) / 255 + (dst.r * inv_a + 127) / 255;
        g = (source_pixel[1] * ctx->color.a + 127) / 255 + (dst.g * inv_a + 127) / 255;
        b = (source_pixel[0] * ctx->color.a + 127) / 255 + (dst.b * inv_a + 127) / 255;
        unsigned int a = src_a + (dst.a * inv_a + 127) / 255;
        source_pixel += 4;
        uint32_t packed = ((r << surface_format->Rshift) & surface_format->Rmask)
          | ((g << surface_format->Gshift) & surface_format->Gmask)
          | ((b << surface_format->Bshift) & surface_format->Bmask);
        if (surface_format->Amask)
          packed |= (a << surface_format->Ashift) & surface_format->Amask;
        *destination_pixel++ = packed;
        continue;
      }

      if (metric->format == EGlyphFormatSubpixel) {
        src.r = *(source_pixel++);
        src.g = *(source_pixel++);
      } else {
        src.r = *(source_pixel);
        src.g = *(source_pixel);
      }

      src.b = *(source_pixel++);
      src.a = 0xFF;

      r = (ctx->color.r * src.r * ctx->color.a + dst.r * (65025 - src.r * ctx->color.a) + 32767) / 65025;
      g = (ctx->color.g * src.g * ctx->color.a + dst.g * (65025 - src.g * ctx->color.a) + 32767) / 65025;
      b = (ctx->color.b * src.b * ctx->color.a + dst.b * (65025 - src.b * ctx->color.a) + 32767) / 65025;
      // the standard way of doing this would be SDL_GetRGBA, but that introduces a performance regression. needs to be investigated
      *destination_pixel++ = (unsigned int) dst.a << surface_format->Ashift | r << surface_format->Rshift | g << surface_format->Gshift | b << surface_format->Bshift;
    }
  }
}

static double draw_shaped_glyphs(DrawGlyphContext *ctx, RenFont **fonts, RenFont *font, const ShapedGlyph *glyphs, unsigned int glyph_count, double pen_x, double y) {
  for (unsigned int i = 0; i < glyph_count; i++) {
    double x_offset = hb_position_to_font_pixels(font, glyphs[i].x_offset);
    double y_offset = hb_position_to_font_pixels(font, glyphs[i].y_offset);
    double glyph_x = pen_x + x_offset;
    SDL_Surface *font_surface = NULL;
    GlyphMetric *metric = NULL;
    font_get_glyph_by_id(font, glyphs[i].codepoint, (int)(fmod(glyph_x, 1.0) * SUBPIXEL_BITMAPS_CACHED), &font_surface, &metric);
    if (metric)
      draw_glyph_bitmap(ctx, fonts, font, font_surface, metric, glyph_x, y, y_offset, glyphs[i].codepoint == 0);
    pen_x += hb_position_to_font_pixels(font, glyphs[i].x_advance);
  }
  return pen_x;
}

static double draw_shaped_run(hb_buffer_t *buffer, DrawGlyphContext *ctx, RenFont **fonts, RenFont *font, const char *text, size_t len, double pen_x, double y) {
  uint32_t hash_value = 0;
  bool cacheable = len <= SHAPED_RUN_CACHE_MAX_TEXT;
  if (cacheable) {
    hash_value = hash_bytes(text, len);
    ShapedRunCacheEntry *cached = font_lookup_shaped_run_cache(font, text, len, hash_value);
    if (cached)
      return draw_shaped_glyphs(ctx, fonts, font, cached->glyphs, cached->glyph_count, pen_x, y);
  }

  font_shape(buffer, font, text, len);

  unsigned int glyph_count = 0;
  hb_glyph_info_t *infos = hb_buffer_get_glyph_infos(buffer, &glyph_count);
  hb_glyph_position_t *positions = hb_buffer_get_glyph_positions(buffer, NULL);

  if (cacheable) {
    ShapedRunCacheEntry *entry =
      font_store_shaped_run_cache(font, text, len, hash_value, infos, positions, glyph_count);
    return draw_shaped_glyphs(ctx, fonts, font, entry->glyphs, entry->glyph_count, pen_x, y);
  }

  /* Runs too long to cache are shaped and drawn directly. */
  for (unsigned int i = 0; i < glyph_count; i++) {
    double x_offset = hb_position_to_font_pixels(font, positions[i].x_offset);
    double y_offset = hb_position_to_font_pixels(font, positions[i].y_offset);
    double glyph_x = pen_x + x_offset;
    SDL_Surface *font_surface = NULL;
    GlyphMetric *metric = NULL;
    font_get_glyph_by_id(font, infos[i].codepoint, (int)(fmod(glyph_x, 1.0) * SUBPIXEL_BITMAPS_CACHED), &font_surface, &metric);
    if (metric)
      draw_glyph_bitmap(ctx, fonts, font, font_surface, metric, glyph_x, y, y_offset, infos[i].codepoint == 0);
    pen_x += hb_position_to_font_pixels(font, positions[i].x_advance);
  }

  return pen_x;
}

static double draw_unshaped_run(DrawGlyphContext *ctx, RenFont **fonts, RenFont *font, const char *text, const char *end, double pen_x, double original_pen_x, double y, RenTab tab) {
  while (text < end) {
    unsigned int codepoint;
    text = utf8_to_codepoint(text, end, &codepoint);
    SDL_Surface *font_surface = NULL; GlyphMetric *metric = NULL;
    if (codepoint >= 0xAD && Lutf8_isdefaultignorable(codepoint)) continue;
    font_get_character(font, codepoint, (int)(fmod(pen_x, 1.0) * SUBPIXEL_BITMAPS_CACHED), &font_surface, &metric);
    if (!metric)
      break;
    if (!is_whitespace(codepoint))
      draw_glyph_bitmap(ctx, fonts, font, font_surface, metric, pen_x, y, 0, true);
    pen_x += font_get_xadvance(fonts[0], codepoint, metric, pen_x - original_pen_x, tab);
  }
  return pen_x;
}

static void draw_font_decoration(RenSurface *rs, RenFont *font, double start_x, double end_x, double y, RenColor color, bool underline, bool strikethrough) {
  if (underline)
    ren_draw_rect(rs, (RenRect){start_x, y + font->height - 1, end_x - start_x, font->underline_thickness}, color, false);
  if (strikethrough)
    ren_draw_rect(rs, (RenRect){start_x, y + (float) font->height / 2, end_x - start_x, font->underline_thickness}, color, false);
}

#ifdef RENDERER_DEBUG
// this function can be used to debug font atlases, it is not public
void ren_font_dump(RenFont *font) {
  ren_atlas_dump(&font->glyphs.atlas, font->face->family_name);
  fprintf(stderr, "%s: %zu bytes\n", font->face->family_name, font->glyphs.metrics_bytesize + font->glyphs.atlas.bytesize);
}
#endif

double ren_draw_text_cb_ex(
  RenSurface *rs, RenFont **fonts, const char *text, size_t len, float x, float y,
  RenColor color, RenTab tab, RenGlyphDrawFn glyph_fn, void *userdata, bool draw_decorations
) {
  SDL_Surface *surface = rs->surface;
  SDL_Rect clip;
  SDL_GetSurfaceClipRect(surface, &clip);

  double pen_x = x;
  double original_pen_x = pen_x;
  const char* end = text + len;
  hb_buffer_t *hb_buffer = NULL;
  const char *start = text;
  FontTextLayout *layout = font_text_layout(fonts, text, len);
  size_t run_index = 0;
  DrawGlyphContext draw_context = {
    .rs = rs,
    .surface = surface,
    .clip = clip,
    .destination_pixels = surface->pixels,
    .clip_end_x = clip.x + clip.w,
    .clip_end_y = clip.y + clip.h,
    .color = color,
    .glyph_fn = glyph_fn,
    .glyph_userdata = userdata
  };

  RenFont* last = NULL;
  double last_pen_x = pen_x;
  bool underline = fonts[0]->style & FONT_STYLE_UNDERLINE;
  bool strikethrough = fonts[0]->style & FONT_STYLE_STRIKETHROUGH;

  while (text < end) {
    RenFont *font;
    bool shaped;
    const char *run_end;
    if (layout) {
      FontTextRun *run = &layout->runs[run_index++];
      font = run->font;
      shaped = run->shaped;
      run_end = start + run->end;
    } else {
      run_end = font_next_run(fonts, text, end, &font, &shaped);
    }
    if (!last) last = font;
    else if (font != last) {
      if (draw_decorations)
        draw_font_decoration(rs, fonts[0], last_pen_x, pen_x, y, color, underline, strikethrough);
      last = font;
      last_pen_x = pen_x;
    }
    if (shaped && text_needs_shaping(text, run_end)) {
      if (!hb_buffer) hb_buffer = hb_buffer_create();
      pen_x = draw_shaped_run(hb_buffer, &draw_context, fonts, font, text, run_end - text, pen_x, y);
    } else {
      pen_x = draw_unshaped_run(&draw_context, fonts, font, text, run_end, pen_x, original_pen_x, y, tab);
    }
    text = run_end;
  }
  if (hb_buffer)
    hb_buffer_destroy(hb_buffer);
  if (last)
    if (draw_decorations)
      draw_font_decoration(rs, fonts[0], last_pen_x, pen_x, y, color, underline, strikethrough);
  return pen_x;
}

double ren_draw_text_cb(RenSurface *rs, RenFont **fonts, const char *text, size_t len, float x, float y, RenColor color, RenTab tab, RenGlyphDrawFn glyph_fn, void *userdata) {
  return ren_draw_text_cb_ex(rs, fonts, text, len, x, y, color, tab, glyph_fn, userdata, true);
}

double ren_draw_text(RenSurface *rs, RenFont **fonts, const char *text, size_t len, float x, float y, RenColor color, RenTab tab) {
  return ren_draw_text_cb(rs, fonts, text, len, x, y, color, tab, NULL, NULL);
}

int ren_poly_cbox(RenPoint *points, int npoints, RenRect *cbox) {
  if (npoints > MAX_POLY_POINTS) return -1;
  if (npoints == 0) { memset(cbox, 0, sizeof(RenRect)); return 0; }
  // the control box is just the min and max of all points,
  // because the highest point of a curve can't go higher than the control point
  RenPoint *end = points + npoints;
  int xmin, ymin, xmax, ymax;
  xmin = xmax = points->x; ymin = ymax = points->y;
  points++;
  for (; points < end; points++) {
    if (points->x < xmin) xmin = points->x;
    if (points->x > xmax) xmax = points->x;
    if (points->y < ymin) ymin = points->y;
    if (points->y > ymax) ymax = points->y;
  }
  cbox->x = xmin; cbox->y = ymin;
  cbox->width = xmax - xmin; cbox->height = ymax - ymin;
  return 0;
}

static void raster_span(int y, int count, const FT_Span *spans, void *user) {
  RenPolyParams *param = (RenPolyParams *) user;
  if (y < param->clip.y || y >= param->clip.y + param->clip.h) return;
  for (int i = 0; i < count; i++) {
    SDL_Rect actual, span = { .x = spans[i].x, .y = y, .w = spans[i].len, .h = 1 };
    if (span.x > param->clip.x + param->clip.w) break;
    if (!SDL_GetRectIntersection(&param->clip, &span, &actual)) continue;
    if (param->span_fn) {
      param->span_fn(param->userdata, &actual, spans[i].coverage);
      continue;
    }
    *((uint32_t *) draw_rect_surface->pixels) = SDL_MapRGBA(
      SDL_GetPixelFormatDetails(draw_rect_surface->format),
      SDL_GetSurfacePalette(draw_rect_surface),
      param->color.r, param->color.g, param->color.b,
      (param->color.a * spans[i].coverage) >> 8
    );
    SDL_BlitSurfaceScaled(draw_rect_surface, NULL, param->surface, &actual, SDL_SCALEMODE_LINEAR);
  }
}

bool ren_draw_poly_cb(RenSurface *rs, RenPoint *points, unsigned short npoints, RenColor color,
                      RenPolySpanFn span_fn, void *userdata) {
  FT_Outline outline;
  if (npoints == 0 || color.a == 0) return true;
  if (npoints > MAX_POLY_POINTS) return false;
  if (FT_Outline_New(library, npoints, 1, &outline) != 0) return false;
  for (int i = 0; i < npoints; i++) {
    // this is undocumented, but freetype seems to expect 26.6 fixed point numbers
    outline.points[i].x = points[i].x * 64;
    outline.points[i].y = points[i].y * 64;
    outline.tags[i] = points[i].tag;
  }
  outline.contours[0] = npoints - 1;
  RenPolyParams params = {
    .color = color, .surface = rs->surface, .span_fn = span_fn, .userdata = userdata
  };
  SDL_GetSurfaceClipRect(rs->surface, &params.clip);
  FT_Error error = FT_Outline_Render(library, &outline, &(FT_Raster_Params) {
    .target = NULL,
    .flags = FT_RASTER_FLAG_AA | FT_RASTER_FLAG_DIRECT,
    .gray_spans = &raster_span,
    .user = &params,
  });
  FT_Outline_Done(library, &outline);
  return error == 0;
}

void ren_draw_poly(RenSurface *rs, RenPoint *points, unsigned short npoints, RenColor color) {
  ren_draw_poly_cb(rs, points, npoints, color, NULL, NULL);
}

/******************* Rectangles **********************/
static inline UNUSED RenColor blend_pixel(RenColor dst, RenColor src) {
  int ia = 0xff - src.a;
  dst.r = ((src.r * src.a) + (dst.r * ia)) >> 8;
  dst.g = ((src.g * src.a) + (dst.g * ia)) >> 8;
  dst.b = ((src.b * src.a) + (dst.b * ia)) >> 8;
  return dst;
}

void ren_draw_rect(RenSurface *rs, RenRect rect, RenColor color, bool replace) {
  if (color.a == 0 && !replace) { return; }

  SDL_Surface *surface = rs->surface;
  SDL_Rect dest_rect = { rect.x, rect.y, rect.width, rect.height };

  if (color.a == 0xff || replace) {
    uint32_t translated = SDL_MapSurfaceRGBA(surface, color.r, color.g, color.b, color.a);
    SDL_FillSurfaceRect(surface, &dest_rect, translated);
  } else {
    // Seems like SDL doesn't handle clipping as we expect when using
    // scaled blitting, so we "clip" manually.
    SDL_Rect clip;
    SDL_GetSurfaceClipRect(surface, &clip);
    if (!SDL_GetRectIntersection(&clip, &dest_rect, &dest_rect)) return;

    uint32_t *pixel = (uint32_t *)draw_rect_surface->pixels;
    *pixel = SDL_MapSurfaceRGBA(draw_rect_surface, color.r, color.g, color.b, color.a);
    SDL_BlitSurfaceScaled(draw_rect_surface, NULL, surface, &dest_rect, SDL_SCALEMODE_LINEAR);
  }
}

/******************* Canvases **********************/

void ren_draw_canvas(RenSurface *rs, SDL_Surface *surface, int x, int y) {
  SDL_Rect dst_pos = {.x = x, .y = y, .w = 0, .h = 0};
  SDL_BlitSurface(surface, NULL, rs->surface, &dst_pos);
}

/******************** Pixels ***********************/

void ren_draw_pixels(RenSurface *rs, RenRect rect, const char* bytes, size_t len) {
  SDL_Rect dst_pos = { .x = rect.x, .y = rect.y, .w = 0, .h = 0 };
  const SDL_PixelFormatDetails *details = SDL_GetPixelFormatDetails(SDL_PIXELFORMAT_RGBA32);
  int pitch = ((int)(details->bits_per_pixel+0.5)/8) * rect.width;

  // Dropping const on bytes here is likely fine, as we won't be changing it
  // and the surface will be destroyed by the end of this function
  SDL_Surface *src = SDL_CreateSurfaceFrom(
    rect.width, rect.height, SDL_PIXELFORMAT_RGBA32, (void *) bytes, pitch
  );
  SDL_SetSurfaceBlendMode(src, SDL_BLENDMODE_NONE);
  SDL_BlitSurface(src, NULL, rs->surface, &dst_pos);
  SDL_DestroySurface(src);
}


/*************** Window Management ****************/
static void ren_add_window(RenWindow *window_renderer) {
  window_count += 1;
  window_list = SDL_realloc(window_list, window_count * sizeof(RenWindow*));
  window_list[window_count-1] = window_renderer;
}

static void ren_remove_window(RenWindow *window_renderer) {
  for (size_t i = 0; i < window_count; ++i) {
    if (window_list[i] == window_renderer) {
      window_count -= 1;
      memmove(
        &window_list[i],
        &window_list[i + 1],
        (window_count - i) * sizeof(*window_list)
      );
      return;
    }
  }
}

int video_init(void) {
  static int ren_inited = 0;
  if (!ren_inited) {
    if (!SDL_InitSubSystem(SDL_INIT_VIDEO))
      return -1;
    SDL_EnableScreenSaver();
    SDL_SetHint(SDL_HINT_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR, "0");
    SDL_SetHint(SDL_HINT_MOUSE_FOCUS_CLICKTHROUGH, "1");
    SDL_SetHint(SDL_HINT_IME_IMPLEMENTED_UI, "composition");
    /* This hint tells SDL to respect borderless window as a normal window.
    ** For example, the window will sit right on top of the taskbar instead
    ** of obscuring it. */
    SDL_SetHint("SDL_BORDERLESS_WINDOWED_STYLE", "1");
    /* This hint tells SDL to allow the user to resize a borderless windoow.
    ** It also enables aero-snap on Windows apparently. */
    SDL_SetHint("SDL_BORDERLESS_RESIZABLE_STYLE", "1");
    SDL_SetHint("SDL_MOUSE_DOUBLE_CLICK_RADIUS", "4");
    SDL_SetHint(SDL_HINT_RENDER_DRIVER, "software");
    ren_inited = 1;
  }
  return 0;
}

int ren_init(void) {
  FT_Error err;

  draw_rect_surface = SDL_CreateSurface(1, 1, SDL_PIXELFORMAT_RGBA32);

  if (!draw_rect_surface)
    return -1; // error set by SDL_CreateRGBSurface

  if ((err = FT_Init_FreeType(&library)) != 0)
    return SDL_SetError("%s", get_ft_error(err));

  return 0;
}

void ren_free(void) {
  fallback_font_shutdown();
  SDL_DestroySurface(draw_rect_surface);
  FT_Done_FreeType(library);
}

RenWindow* ren_create(SDL_Window *win) {
  assert(win);
  RenWindow* window_renderer = renwin_create(win);
  ren_add_window(window_renderer);
  return window_renderer;
}

void ren_destroy(RenWindow* window_renderer) {
  assert(window_renderer);
  ren_remove_window(window_renderer);
  renwin_free(window_renderer);
}

void ren_resize_window(RenWindow *window_renderer) {
  if (window_renderer->cache.backend->resize_window)
    window_renderer->cache.backend->resize_window(window_renderer);
  renwin_update_scale(window_renderer);
}


void ren_set_clip_rect(RenSurface *rs, RenRect rect) {
  SDL_SetSurfaceClipRect(rs->surface, &(SDL_Rect){.x = rect.x, .y = rect.y, .w = rect.width, .h = rect.height});
}


void ren_get_size(RenSurface *rs, int *x, int *y) {
  *x = rs->surface->w;
  *y = rs->surface->h;
}

size_t ren_get_window_list(RenWindow ***window_list_dest) {
  *window_list_dest = window_list;
  return window_count;
}

RenWindow* ren_find_window(SDL_Window *window) {
  for (size_t i = 0; i < window_count; ++i) {
    RenWindow* window_renderer = window_list[i];
    if (renwin_get_sdl_window(window_renderer) == window) {
      return window_renderer;
    }
  }

  return NULL;
}

RenWindow* ren_find_window_from_id(uint32_t id) {
  SDL_Window *window = SDL_GetWindowFromID(id);
  return window ? ren_find_window(window) : NULL;
}

RenWindow* ren_get_target_window(void) {
  return target_window;
}

void ren_set_target_window(RenWindow *window) {
  target_window = window;
}
