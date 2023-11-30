#include <stdio.h>
#include <stdbool.h>
#include <stdint.h>
#include <assert.h>
#include <math.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_LCD_FILTER_H
#include FT_OUTLINE_H
#include FT_TRUETYPE_IDS_H
#include FT_SFNT_NAMES_H
#include FT_SYSTEM_H

#ifdef _WIN32
#include <windows.h>
#include "utfconv.h"
#endif

#include "renderer.h"
#include "renwindow.h"

#include <hb.h>
#include <hb-ft.h>

#define MAX_UNICODE 0x100000
#define GLYPHSET_SIZE 16
#define MAX_LOADABLE_GLYPHSETS (MAX_UNICODE / GLYPHSET_SIZE)
#define SUBPIXEL_BITMAPS_CACHED 3

RenWindow window_renderer = {0};
static FT_Library library;

// draw_rect_surface is used as a 1x1 surface to simplify ren_draw_rect with blending
static SDL_Surface *draw_rect_surface;

static void* check_alloc(void *ptr) {
  if (!ptr) {
    fprintf(stderr, "Fatal error: memory allocation failed\n");
    exit(EXIT_FAILURE);
  }
  return ptr;
}

/************************* Fonts *************************/

typedef struct {
  unsigned int x0, x1, y0, y1, loaded;
  int bitmap_left, bitmap_top;
  float xadvance;
} GlyphMetric;

typedef struct {
  SDL_Surface* surface;
  GlyphMetric metrics[GLYPHSET_SIZE];
} GlyphSet;

typedef struct RenFont {
  FT_Face face;
  FT_StreamRec stream;
  hb_font_t *font;
  GlyphSet* sets[SUBPIXEL_BITMAPS_CACHED][MAX_LOADABLE_GLYPHSETS];
  float size, space_advance, tab_advance;
  unsigned short max_height, baseline, height;
  ERenFontAntialiasing antialiasing;
  ERenFontHinting hinting;
  unsigned char style;
  unsigned short underline_thickness;
  char path[];
} RenFont;

static int font_set_load_options(RenFont* font) {
  int load_target = font->antialiasing == FONT_ANTIALIASING_NONE ? FT_LOAD_TARGET_MONO
    : (font->hinting == FONT_HINTING_SLIGHT ? FT_LOAD_TARGET_LIGHT : FT_LOAD_TARGET_NORMAL);
  int hinting = font->hinting == FONT_HINTING_NONE ? FT_LOAD_NO_HINTING : FT_LOAD_FORCE_AUTOHINT;
  return load_target | hinting;
}

static int font_set_render_options(RenFont* font) {
  if (font->antialiasing == FONT_ANTIALIASING_NONE)
    return FT_RENDER_MODE_MONO;
  if (font->antialiasing == FONT_ANTIALIASING_SUBPIXEL) {
    unsigned char weights[] = { 0x10, 0x40, 0x70, 0x40, 0x10 } ;
    switch (font->hinting) {
      case FONT_HINTING_NONE:   FT_Library_SetLcdFilter(library, FT_LCD_FILTER_NONE); break;
      case FONT_HINTING_SLIGHT:
      case FONT_HINTING_FULL: FT_Library_SetLcdFilterWeights(library, weights); break;
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

static void font_load_glyphset(RenFont* font, unsigned int idx) {
  unsigned int render_option = font_set_render_options(font), load_option = font_set_load_options(font);
  int bitmaps_cached = font->antialiasing == FONT_ANTIALIASING_SUBPIXEL ? SUBPIXEL_BITMAPS_CACHED : 1;
  unsigned int byte_width = font->antialiasing == FONT_ANTIALIASING_SUBPIXEL ? 3 : 1;
  for (int j = 0, pen_x = 0; j < bitmaps_cached; ++j) {
    GlyphSet* set = check_alloc(calloc(1, sizeof(GlyphSet)));
    font->sets[j][idx] = set;
    for (int i = 0; i < GLYPHSET_SIZE; ++i) {
      int glyph_index = i + idx * GLYPHSET_SIZE;
      if (!glyph_index || FT_Load_Glyph(font->face, glyph_index, load_option | FT_LOAD_BITMAP_METRICS_ONLY)
        || font_set_style(&font->face->glyph->outline, j * (64 / SUBPIXEL_BITMAPS_CACHED), font->style) || FT_Render_Glyph(font->face->glyph, render_option)) {
        continue;
      }
      FT_GlyphSlot slot = font->face->glyph;
      unsigned int glyph_width = slot->bitmap.width / byte_width;
      if (font->antialiasing == FONT_ANTIALIASING_NONE)
        glyph_width *= 8;
      set->metrics[i] = (GlyphMetric){ pen_x, pen_x + glyph_width, 0, slot->bitmap.rows, true, slot->bitmap_left, slot->bitmap_top, (slot->advance.x + slot->lsb_delta - slot->rsb_delta) / 64.0f};
      pen_x += glyph_width;
      font->max_height = slot->bitmap.rows > font->max_height ? slot->bitmap.rows : font->max_height;
      // In order to fix issues with monospacing; we need the unhinted xadvance; as FreeType doesn't correctly report the hinted advance for spaces on monospace fonts (like RobotoMono). See #843.
      if (FT_Load_Glyph(font->face, glyph_index, (load_option | FT_LOAD_BITMAP_METRICS_ONLY | FT_LOAD_NO_HINTING) & ~FT_LOAD_FORCE_AUTOHINT)
        || font_set_style(&font->face->glyph->outline, j * (64 / SUBPIXEL_BITMAPS_CACHED), font->style) || FT_Render_Glyph(font->face->glyph, render_option)) {
        continue;
      }
      slot = font->face->glyph;
      set->metrics[i].xadvance = slot->advance.x / 64.0f;
    }
    if (pen_x == 0)
      continue;
    set->surface = check_alloc(SDL_CreateRGBSurface(0, pen_x, font->max_height, font->antialiasing == FONT_ANTIALIASING_SUBPIXEL ? 24 : 8, 0, 0, 0, 0));
    uint8_t* pixels = set->surface->pixels;
    for (int i = 0; i < GLYPHSET_SIZE; ++i) {
      int glyph_index = i + idx * GLYPHSET_SIZE;
      if (!glyph_index || FT_Load_Glyph(font->face, glyph_index, load_option))
        continue;
      FT_GlyphSlot slot = font->face->glyph;
      font_set_style(&slot->outline, (64 / bitmaps_cached) * j, font->style);
      if (FT_Render_Glyph(slot, render_option))
        continue;
      for (unsigned int line = 0; line < slot->bitmap.rows; ++line) {
        int target_offset = set->surface->pitch * line + set->metrics[i].x0 * byte_width;
        int source_offset = line * slot->bitmap.pitch;
        if (font->antialiasing == FONT_ANTIALIASING_NONE) {
          for (unsigned int column = 0; column < slot->bitmap.width; ++column) {
            int current_source_offset = source_offset + (column / 8);
            int source_pixel = slot->bitmap.buffer[current_source_offset];
            pixels[++target_offset] = ((source_pixel >> (7 - (column % 8))) & 0x1) * 0xFF;
          }
        } else
          memcpy(&pixels[target_offset], &slot->bitmap.buffer[source_offset], slot->bitmap.width);
      }
    }
  }
}

static GlyphSet* font_get_glyphset(RenFont* font, unsigned int codepoint, int subpixel_idx) {
  int idx = (codepoint / GLYPHSET_SIZE) % MAX_LOADABLE_GLYPHSETS;
  if (!font->sets[font->antialiasing == FONT_ANTIALIASING_SUBPIXEL ? subpixel_idx : 0][idx])
    font_load_glyphset(font, idx);
  return font->sets[font->antialiasing == FONT_ANTIALIASING_SUBPIXEL ? subpixel_idx : 0][idx];
}

static RenFont* font_group_get_glyph(GlyphSet** set, GlyphMetric** metric, RenFont** fonts, unsigned int codepoint, unsigned fb_codepoint, int bitmap_index) {
  if (!metric) {
    return NULL;
  }
  bool is_tab = false;
  if (fb_codepoint == '\t') { is_tab = true; fb_codepoint = '\0'; }
  if (bitmap_index < 0)
    bitmap_index += SUBPIXEL_BITMAPS_CACHED;
  for (int i = 0; i < FONT_FALLBACK_MAX && fonts[i]; ++i) {
    unsigned cp = i == 0 ? codepoint : FT_Get_Char_Index(fonts[i]->face, fb_codepoint);
    *set = font_get_glyphset(fonts[i], cp, bitmap_index);
    *metric = &(*set)->metrics[cp % GLYPHSET_SIZE];
    if ((*metric)->loaded || fb_codepoint == 0) {
      if (is_tab) (*metric)->xadvance = fonts[i]->tab_advance;
      return fonts[i];
    }
  }
  if (*metric && !(*metric)->loaded && fb_codepoint > 0xFF && fb_codepoint != 0x25A1)
    return font_group_get_glyph(set, metric, fonts, 0x25A1, 0x25A1, bitmap_index);
  return fonts[0];
}

static void font_clear_glyph_cache(RenFont* font) {
  for (int i = 0; i < SUBPIXEL_BITMAPS_CACHED; ++i) {
    for (int j = 0; j < MAX_LOADABLE_GLYPHSETS; ++j) {
      if (font->sets[i][j]) {
        if (font->sets[i][j]->surface)
          SDL_FreeSurface(font->sets[i][j]->surface);
        free(font->sets[i][j]);
        font->sets[i][j] = NULL;
      }
    }
  }
}

// based on https://github.com/libsdl-org/SDL_ttf/blob/2a094959055fba09f7deed6e1ffeb986188982ae/SDL_ttf.c#L1735
static unsigned long font_file_read(FT_Stream stream, unsigned long offset, unsigned char *buffer, unsigned long count) {
  uint64_t amount;
  SDL_RWops *file = (SDL_RWops *) stream->descriptor.pointer;
  SDL_RWseek(file, (int) offset, RW_SEEK_SET);
  if (count == 0)
    return 0;
  amount = SDL_RWread(file, buffer, sizeof(char), count);
  if (amount <= 0)
    return 0;
  return (unsigned long) amount;
}

static void font_file_close(FT_Stream stream) {
  if (stream && stream->descriptor.pointer) {
    SDL_RWclose((SDL_RWops *) stream->descriptor.pointer);
    stream->descriptor.pointer = NULL;
  }
}

RenFont* ren_font_load(RenWindow *window_renderer, const char* path, float size, ERenFontAntialiasing antialiasing, ERenFontHinting hinting, unsigned char style) {
  RenFont *font = NULL;
  FT_Face face = NULL;

  SDL_RWops *file = SDL_RWFromFile(path, "rb");
  if (!file)
    goto rwops_failure;

  int len = strlen(path);
  font = check_alloc(calloc(1, sizeof(RenFont) + len + 1));
  font->stream.read = font_file_read;
  font->stream.close = font_file_close;
  font->stream.descriptor.pointer = file;
  font->stream.pos = 0;
  font->stream.size = (unsigned long) SDL_RWsize(file);

  if (FT_Open_Face(library, &(FT_Open_Args){ .flags = FT_OPEN_STREAM, .stream = &font->stream }, 0, &face))
    goto failure;
  const double surface_scale = renwin_get_surface(window_renderer).scale_x;
  if (FT_Set_Pixel_Sizes(face, 0, (int)(size*surface_scale)))
    goto failure;

  strcpy(font->path, path);
  font->face = face;
  font->size = size;
  font->height = (short)((face->height / (float)face->units_per_EM) * font->size);
  font->baseline = (short)((face->ascender / (float)face->units_per_EM) * font->size);
  font->antialiasing = antialiasing;
  font->hinting = hinting;
  font->style = style;

  if(FT_IS_SCALABLE(face))
    font->underline_thickness = (unsigned short)((face->underline_thickness / (float)face->units_per_EM) * font->size);
  if(!font->underline_thickness)
    font->underline_thickness = ceil((double) font->height / 14.0);

  if (FT_Load_Char(face, ' ', font_set_load_options(font)))
    goto failure;

  font->font = hb_ft_font_create_referenced(face);
  if (font->font == 0)
    goto failure;
  font->space_advance = face->glyph->advance.x / 64.0f;
  font->tab_advance = font->space_advance * 2;
  return font;

failure:
  if (face)
    FT_Done_Face(face);
  if (font && font->font)
    hb_font_destroy(font->font);
  if (font)
    free(font);
  return NULL;

rwops_failure:
  if (file)
    SDL_RWclose(file);
  return NULL;
}

RenFont* ren_font_copy(RenWindow *window_renderer, RenFont* font, float size, ERenFontAntialiasing antialiasing, ERenFontHinting hinting, int style) {
  antialiasing = antialiasing == -1 ? font->antialiasing : antialiasing;
  hinting = hinting == -1 ? font->hinting : hinting;
  style = style == -1 ? font->style : style;

  return ren_font_load(window_renderer, font->path, size, antialiasing, hinting, style);
}

const char* ren_font_get_path(RenFont *font) {
  return font->path;
}

void ren_font_free(RenFont* font) {
  font_clear_glyph_cache(font);
  FT_Done_Face(font->face);
  hb_font_destroy(font->font);
  free(font);
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

      unsigned char *name = malloc(metaprop.string_len * 2);
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
        }
      }
      if (meta.tag == -1) {
        free(name);
      } else {
        meta.value = (char*) name;
        meta.len = outlen;

        if (meta_count == 0) {
          *data = malloc(sizeof(FontMetaData));
        } else {
          *data = realloc(*data, sizeof(FontMetaData) * (meta_count+1));
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
    fonts[j]->tab_advance = fonts[j]->space_advance * n;
  }
}

int ren_font_group_get_tab_size(RenFont **fonts) {
  if (fonts[0]->space_advance)
    return fonts[0]->tab_advance / fonts[0]->space_advance;
  return fonts[0]->tab_advance;
}

float ren_font_group_get_size(RenFont **fonts) {
  return fonts[0]->size;
}

void ren_font_group_set_size(RenWindow *window_renderer, RenFont **fonts, float size) {
  const double surface_scale = renwin_get_surface(window_renderer).scale_x;
  for (int i = 0; i < FONT_FALLBACK_MAX && fonts[i]; ++i) {
    font_clear_glyph_cache(fonts[i]);
    FT_Face face = fonts[i]->face;
    FT_Set_Pixel_Sizes(face, 0, (int)(size*surface_scale));
    fonts[i]->size = size;
    fonts[i]->height = (short)((face->height / (float)face->units_per_EM) * size);
    fonts[i]->baseline = (short)((face->ascender / (float)face->units_per_EM) * size);
    FT_Load_Char(face, ' ', font_set_load_options(fonts[i]));
    fonts[i]->space_advance = face->glyph->advance.x / 64.0f;
    fonts[i]->tab_advance = fonts[i]->space_advance * 2;
  }
}

int ren_font_group_get_height(RenFont **fonts) {
  return fonts[0]->height;
}

static const unsigned utf8_to_codepoint(const char *p) {
  const unsigned char *up = (unsigned char*)p;
  unsigned res, n;
  switch (*p & 0xf0) {
    case 0xf0 :  res = *up & 0x07;  n = 3;  break;
    case 0xe0 :  res = *up & 0x0f;  n = 2;  break;
    case 0xd0 :
    case 0xc0 :  res = *up & 0x1f;  n = 1;  break;
    default   :  res = *up;         n = 0;  break;
  }
  while (n--) {
    res = (res << 6) | (*(++up) & 0x3f);
  }
  return res;
}

double ren_font_group_get_width(RenWindow *window_renderer, RenFont **fonts, const char *text, size_t len) {
  double width = 0;
  GlyphMetric* metric = NULL; GlyphSet* set = NULL;
  hb_buffer_t *buf;
  buf = hb_buffer_create();
  hb_buffer_set_direction(buf, HB_DIRECTION_LTR);
  hb_buffer_add_utf8(buf, text, -1, 0, -1);
  RenFont * font = fonts[0];
  hb_shape(font->font, buf, NULL, 0);
  unsigned int glyph_count;
  hb_glyph_info_t *glyph_info = hb_buffer_get_glyph_infos(buf, &glyph_count);
  for (unsigned int i = 0; i < glyph_count; i++)  {
    unsigned int codepoint = glyph_info[i].codepoint;
    unsigned fb_codepoint = utf8_to_codepoint(&text[glyph_info[i].cluster]);
    RenFont* font = font_group_get_glyph(&set, &metric, fonts, codepoint, fb_codepoint, 0);
    if (!metric)
      break;
    width += (!font || metric->xadvance) ? metric->xadvance : fonts[0]->space_advance;
  }
  hb_buffer_destroy(buf);
  const double surface_scale = renwin_get_surface(window_renderer).scale_x;
  return width / surface_scale;
}

double ren_draw_text(RenSurface *rs, RenFont **fonts, const char *text, size_t len, float x, float y, RenColor color) {
  SDL_Surface *surface = rs->surface;
  SDL_Rect clip;
  SDL_GetClipRect(surface, &clip);

  const double surface_scale_x = rs->scale_x, surface_scale_y = rs->scale_y;
  double pen_x = x * surface_scale_x;
  y *= surface_scale_y;
  int bytes_per_pixel = surface->format->BytesPerPixel;
  // const char* end = text + len;
  uint8_t* destination_pixels = surface->pixels;
  int clip_end_x = clip.x + clip.w, clip_end_y = clip.y + clip.h;

  RenFont* last = NULL;
  double last_pen_x = x;
  bool underline = fonts[0]->style & FONT_STYLE_UNDERLINE;
  bool strikethrough = fonts[0]->style & FONT_STYLE_STRIKETHROUGH;
  // convert text in glyphs
  hb_buffer_t *buf;
  buf = hb_buffer_create();
  hb_buffer_set_direction(buf, HB_DIRECTION_LTR);
  hb_buffer_add_utf8(buf, text, -1, 0, -1);

  RenFont * font = fonts[0];
  hb_shape(font->font, buf, NULL, 0);
  unsigned int glyph_count;
  hb_glyph_info_t *glyph_info = hb_buffer_get_glyph_infos(buf, &glyph_count);
  for (unsigned int i = 0; i < glyph_count; i++) {
    unsigned int r, g, b;
    unsigned fb_codepoint = utf8_to_codepoint(&text[glyph_info[i].cluster]);
    hb_codepoint_t codepoint = glyph_info[i].codepoint;
    GlyphSet* set = NULL; GlyphMetric* metric = NULL;
    RenFont* font = font_group_get_glyph(&set, &metric, fonts, codepoint, fb_codepoint, (int)(fmod(pen_x, 1.0) * SUBPIXEL_BITMAPS_CACHED));
    if (!metric)
      break;
    int start_x = floor(pen_x) + metric->bitmap_left;
    int end_x = (metric->x1 - metric->x0) + start_x;
    int glyph_end = metric->x1, glyph_start = metric->x0;
    if (!metric->loaded && fb_codepoint > 0xFF)
      ren_draw_rect(rs, (RenRect){ start_x + 1, y, font->space_advance - 1, ren_font_group_get_height(fonts) }, color);

    if (set->surface && color.a > 0 && end_x >= clip.x && start_x < clip_end_x) {
      uint8_t* source_pixels = set->surface->pixels;
      for (int line = metric->y0; line < metric->y1; ++line) {
        int target_y = line + y - metric->bitmap_top + fonts[0]->baseline * surface_scale_y;
        if (target_y < clip.y)
          continue;
        if (target_y >= clip_end_y)
          break;
        if (start_x + (glyph_end - glyph_start) >= clip_end_x)
          glyph_end = glyph_start + (clip_end_x - start_x);
        if (start_x < clip.x) {
          int offset = clip.x - start_x;
          start_x += offset;
          glyph_start += offset;
        }
        uint32_t* destination_pixel = (uint32_t*)&(destination_pixels[surface->pitch * target_y + start_x * bytes_per_pixel]);
        uint8_t* source_pixel = &source_pixels[line * set->surface->pitch + glyph_start * (font->antialiasing == FONT_ANTIALIASING_SUBPIXEL ? 3 : 1)];
        for (int x = glyph_start; x < glyph_end; ++x) {
          uint32_t destination_color = *destination_pixel;
          // the standard way of doing this would be SDL_GetRGBA, but that introduces a performance regression. needs to be investigated
          SDL_Color dst = { (destination_color & surface->format->Rmask) >> surface->format->Rshift, (destination_color & surface->format->Gmask) >> surface->format->Gshift, (destination_color & surface->format->Bmask) >> surface->format->Bshift, (destination_color & surface->format->Amask) >> surface->format->Ashift };
          SDL_Color src;

          if (font->antialiasing == FONT_ANTIALIASING_SUBPIXEL) {
            src.r = *(source_pixel++);
            src.g = *(source_pixel++);
          }
          else  {
            src.r = *(source_pixel);
            src.g = *(source_pixel);
          }

          src.b = *(source_pixel++);
          src.a = 0xFF;

          r = (color.r * src.r * color.a + dst.r * (65025 - src.r * color.a) + 32767) / 65025;
          g = (color.g * src.g * color.a + dst.g * (65025 - src.g * color.a) + 32767) / 65025;
          b = (color.b * src.b * color.a + dst.b * (65025 - src.b * color.a) + 32767) / 65025;
          // the standard way of doing this would be SDL_GetRGBA, but that introduces a performance regression. needs to be investigated
          *destination_pixel++ = dst.a << surface->format->Ashift | r << surface->format->Rshift | g << surface->format->Gshift | b << surface->format->Bshift;
        }
      }
    }

    float adv = metric->xadvance ? metric->xadvance : font->space_advance;

    if(!last) last = font;
    else if(font != last || i == glyph_count - 1)  {
      double local_pen_x = i == glyph_count - 1 ? pen_x + adv : pen_x;
      if (underline)
        ren_draw_rect(rs, (RenRect){last_pen_x, y / surface_scale_y + last->height - 1, (local_pen_x - last_pen_x) / surface_scale_x, last->underline_thickness * surface_scale_x}, color);
      if (strikethrough)
        ren_draw_rect(rs, (RenRect){last_pen_x, y / surface_scale_y + (float)last->height / 2, (local_pen_x - last_pen_x) / surface_scale_x, last->underline_thickness * surface_scale_x}, color);
      last = font;
      last_pen_x = pen_x;
    }

    pen_x += adv;
  }
  hb_buffer_destroy(buf);
  return pen_x / surface_scale_x;
}

/******************* Rectangles **********************/
// static inline RenColor blend_pixel(RenColor dst, RenColor src) {
//   int ia = 0xff - src.a;
//   dst.r = ((src.r * src.a) + (dst.r * ia)) >> 8;
//   dst.g = ((src.g * src.a) + (dst.g * ia)) >> 8;
//   dst.b = ((src.b * src.a) + (dst.b * ia)) >> 8;
//   return dst;
// }

void ren_draw_rect(RenSurface *rs, RenRect rect, RenColor color) {
  if (color.a == 0) { return; }

  SDL_Surface *surface = rs->surface;
  const double surface_scale_x = rs->scale_x;
  const double surface_scale_y = rs->scale_y;

  SDL_Rect dest_rect = { rect.x * surface_scale_x,
                         rect.y * surface_scale_y,
                         rect.width * surface_scale_x,
                         rect.height * surface_scale_y };

  if (color.a == 0xff) {
    uint32_t translated = SDL_MapRGB(surface->format, color.r, color.g, color.b);
    SDL_FillRect(surface, &dest_rect, translated);
  } else {
    // Seems like SDL doesn't handle clipping as we expect when using
    // scaled blitting, so we "clip" manually.
    SDL_Rect clip;
    SDL_GetClipRect(surface, &clip);
    if (!SDL_IntersectRect(&clip, &dest_rect, &dest_rect)) return;

    uint32_t *pixel = (uint32_t *)draw_rect_surface->pixels;
    *pixel = SDL_MapRGBA(draw_rect_surface->format, color.r, color.g, color.b, color.a);
    SDL_BlitScaled(draw_rect_surface, NULL, surface, &dest_rect);
  }
}

/*************** Window Management ****************/
void ren_free_window_resources(RenWindow *window_renderer) {
  renwin_free(window_renderer);
  SDL_FreeSurface(draw_rect_surface);
  free(window_renderer->command_buf);
  window_renderer->command_buf = NULL;
  window_renderer->command_buf_size = 0;
}

// TODO remove global and return RenWindow*
void ren_init(SDL_Window *win) {
  assert(win);
  int error = FT_Init_FreeType( &library );
  if ( error ) {
    fprintf(stderr, "internal font error when starting the application\n");
    return;
  }
  window_renderer.window = win;
  renwin_init_surface(&window_renderer);
  renwin_init_command_buf(&window_renderer);
  renwin_clip_to_surface(&window_renderer);
  draw_rect_surface = SDL_CreateRGBSurface(0, 1, 1, 32,
                       0xFF000000, 0x00FF0000, 0x0000FF00, 0x000000FF);
}


void ren_resize_window(RenWindow *window_renderer) {
  renwin_resize_surface(window_renderer);
}


void ren_update_rects(RenWindow *window_renderer, RenRect *rects, int count) {
  static bool initial_frame = true;
  if (initial_frame) {
    renwin_show_window(window_renderer);
    initial_frame = false;
  }
  renwin_update_rects(window_renderer, rects, count);
}


void ren_set_clip_rect(RenWindow *window_renderer, RenRect rect) {
  renwin_set_clip_rect(window_renderer, rect);
}


void ren_get_size(RenWindow *window_renderer, int *x, int *y) {
  RenSurface rs = renwin_get_surface(window_renderer);
  *x = rs.surface->w / rs.scale_x;
  *y = rs.surface->h / rs.scale_y;
}


float ren_get_scale_factor(SDL_Window *win) {
  int w_pixels, h_pixels;
  int w_points, h_points;
  SDL_GL_GetDrawableSize(win, &w_pixels, &h_pixels);
  SDL_GetWindowSize(win, &w_points, &h_points);
  float scale = (float) w_pixels / (float) w_points;
  return roundf(scale * 100) / 100;
}
