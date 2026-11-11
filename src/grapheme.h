#ifndef GRAPHEME_H
#define GRAPHEME_H

#include <stdbool.h>
#include <stdint.h>

/** Return the end of the next extended grapheme in [text,end), or NULL on
 * invalid/truncated UTF-8. An empty span returns end without reading it.
 */
const char *Lutf8_grapheme_next(const char *text, const char *end);
/** Whether a character may be omitted by a font without a missing glyph. */
bool Lutf8_isdefaultignorable(uint32_t codepoint);

#endif
