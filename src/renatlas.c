#include "renatlas.h"
#include "renbackend.h"

int ren_glyphformat_bytes_per_pixel(ERenGlyphFormat format) {
  switch (format) {
    case EGlyphFormatColor:     return 4;
    case EGlyphFormatSubpixel:  return 3;
    case EGlyphFormatGrayscale: return 1;
    default: return 0;
  }
}

SDL_Surface *ren_atlas_allocate_glyph_surface(RenAtlas *atlas, RenAtlasGlyphRequest request, int bitmap_idx, GlyphMetric *metric) {
  if (!atlas->ops)
    renbackend_current()->init_atlas(atlas);
  return atlas->ops->allocate_glyph_surface(atlas, request, bitmap_idx, metric);
}

SDL_Surface *ren_atlas_get_glyph_surface(RenAtlas *atlas, GlyphMetric *metric) {
  return atlas->ops->get_glyph_surface(atlas, metric);
}

void ren_atlas_glyph_updated(RenAtlas *atlas, GlyphMetric *metric) {
  if (atlas->ops && atlas->ops->glyph_updated)
    atlas->ops->glyph_updated(atlas, metric);
}

void ren_atlas_clear(RenAtlas *atlas) {
  if (atlas->ops)
    atlas->ops->clear(atlas);
}

void ren_atlas_free(RenAtlas *atlas) {
  ren_atlas_clear(atlas);
  SDL_free(atlas->data);
  atlas->data = NULL;
  atlas->bytesize = 0;
}

#ifdef RENDERER_DEBUG
void ren_atlas_dump(RenAtlas *atlas, const char *family_name) {
  if (atlas->ops && atlas->ops->dump)
    atlas->ops->dump(atlas, family_name);
}
#endif
