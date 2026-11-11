#ifndef FALLBACKFONT_H
#define FALLBACKFONT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FallbackFontResolver FallbackFontResolver;

/** A native variation axis, expressed in the font's design coordinates. */
typedef struct {
  uint32_t tag;
  double value;
} FallbackFontAxis;

/** Borrowed match data, valid only during the match callback.
 * A negative face index asks the caller to locate the PostScript name in a
 * collection. Native size adjustments multiply the requested pixel size.
 */
typedef struct {
  const char *path;
  const char *postscript_name;
  long face_index;
  float scale;
  const FallbackFontAxis *axes;
  size_t axis_count;
} FallbackFontMatch;

/** Return true after loading and validating a candidate to stop the search. */
typedef bool (*FallbackFontAccept)(void *userdata, const FallbackFontMatch *match);

/** Create a lazy native resolver for a configured font; NULL means unavailable. */
FallbackFontResolver *fallback_font_create(const char *path, const char *family,
  const char *postscript_name, float size, bool bold, bool italic);
/** Offer native candidates for one complete UTF-8 grapheme to the caller. */
bool fallback_font_resolve(FallbackFontResolver *resolver, const char *text,
  size_t len, FallbackFontAccept accept, void *userdata);
/** Release a resolver. Discovered renderer fonts have separate ownership. */
void fallback_font_free(FallbackFontResolver *resolver);
/** Drop temporary discovery catalogues after a frame; loaded faces stay live. */
void fallback_font_trim(void);
/** Release process-wide native services after all resolvers have been freed. */
void fallback_font_shutdown(void);

#ifdef __cplusplus
}
#endif
#endif
