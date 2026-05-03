/*
 * Integration of https://github.com/starwing/luautf8
 *
 * MIT License
 *
 * Copyright (c) 2018 Xavier Wang
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

#include "lutf8.h"
#include "unidata.h"

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#include <assert.h>
#include <string.h>

/* UTF-8 string operations */

#define UTF8_BUFFSZ 8
#define UTF8_MAX    0x7FFFFFFFu
#define UTF8_MAXCP  0x10FFFFu
#define iscont(p)   ((*(p) & 0xC0) == 0x80)
#define CAST(tp,expr) ((tp)(expr))

static int utf8_invalid(utfint ch) {
  return (ch > UTF8_MAXCP || (0xD800u <= ch && ch <= 0xDFFFu));
}

static size_t utf8_encode(char *buff, utfint x) {
  int n = 1;  /* number of bytes put in buffer (backwards) */
  assert(x <= UTF8_MAX);
  if (x < 0x80)  /* ascii? */
    buff[UTF8_BUFFSZ - 1] = x & 0x7F;
  else {  /* need continuation bytes */
    utfint mfb = 0x3f;  /* maximum that fits in first byte */
    do {  /* add continuation bytes */
      buff[UTF8_BUFFSZ - (n++)] = 0x80 | (x & 0x3f);
      x >>= 6;  /* remove added bits */
      mfb >>= 1;  /* now there is one less bit available in first byte */
    } while (x > mfb);  /* still needs continuation byte? */
    buff[UTF8_BUFFSZ - n] = ((~mfb << 1) | x) & 0xFF;  /* add first byte */
  }
  return n;
}

static const char *utf8_decode(const char *s, utfint *val, int strict) {
  static const utfint limits[] =
  {~0u, 0x80u, 0x800u, 0x10000u, 0x200000u, 0x4000000u};
  unsigned int c = (unsigned char)s[0];
  utfint res = 0;  /* final result */
  if (c < 0x80)  /* ascii? */
    res = c;
  else {
    int count = 0;  /* to count number of continuation bytes */
    for (; c & 0x40; c <<= 1) {  /* while it needs continuation bytes... */
      unsigned int cc = (unsigned char)s[++count];  /* read next byte */
      if ((cc & 0xC0) != 0x80)  /* not a continuation byte? */
        return NULL;  /* invalid byte sequence */
      res = (res << 6) | (cc & 0x3F);  /* add lower 6 bits from cont. byte */
    }
    res |= ((utfint)(c & 0x7F) << (count * 5));  /* add first byte */
    if (count > 5 || res > UTF8_MAX || res < limits[count])
      return NULL;  /* invalid byte sequence */
    s += count;  /* skip continuation bytes read */
  }
  if (strict) {
    /* check for invalid code points; too large or surrogates */
    if (res > UTF8_MAXCP || (0xD800u <= res && res <= 0xDFFFu))
      return NULL;
  }
  if (val) *val = res;
  return s + 1;  /* +1 to include first byte */
}

static const char *utf8_prev(const char *s, const char *e) {
  while (s < e && iscont(e - 1)) --e;
  return s < e ? e - 1 : s;
}

static const char *utf8_next(const char *s, const char *e) {
  while (s < e && iscont(s + 1)) ++s;
  return s < e ? s + 1 : e;
}

static size_t utf8_length (const char *s, const char *e) {
  size_t i;
  for (i = 0; s < e; ++i)
    s = utf8_next(s, e);
  return i;
}

static const char *utf8_offset(const char *s, const char *e, size_t offset, size_t idx) {
  const char *p = s + offset - 1;
  if (idx >= 0) {
    while (p < e && idx > 0)
      p = utf8_next(p, e), --idx;
    return idx == 0 ? p : NULL;
  } else {
    while (s < p && idx < 0)
      p = utf8_prev(s, p), ++idx;
    return idx == 0 ? p : NULL;
  }
}

static const char *utf8_relat(const char *s, const char *e, int idx) {
  return idx >= 0 ?
    utf8_offset(s, e, 1, idx - 1) :
    utf8_offset(s, e, e-s+1, idx);
}

static int utf8_range(const char *s, const char *e, size_t *i, size_t *j) {
  const char *ps = utf8_relat(s, e, CAST(int, *i));
  const char *pe = utf8_relat(s, e, CAST(int, *j));
  *i = (ps ? ps : (*i > 0 ? e : s)) - s;
  *j = (pe ? utf8_next(pe, e) : (*j > 0 ? e : s)) - s;
  return *i < *j;
}

/* Unicode character categories */

#define table_size(t) (sizeof(t)/sizeof((t)[0]))

#define utf8_categories(X) \
  X('a', alpha) \
  X('c', cntrl) \
  X('d', digit) \
  X('l', lower) \
  X('p', punct) \
  X('s', space) \
  X('t', compose) \
  X('u', upper) \
  X('x', xdigit)

#define utf8_converters(X) \
  X(lower) \
  X(upper) \
  X(title) \
  X(fold)

static int find_in_range (range_table *t, size_t size, utfint ch) {
  size_t begin, end;

  begin = 0;
  end = size;

  while (begin < end) {
    size_t mid = (begin + end) / 2;
    if (t[mid].last < ch)
      begin = mid + 1;
    else if (t[mid].first > ch)
      end = mid;
    else
      return (ch - t[mid].first) % t[mid].step == 0;
  }

  return 0;
}

static int convert_char (conv_table *t, size_t size, utfint ch) {
  size_t begin, end;

  begin = 0;
  end = size;

  while (begin < end) {
    size_t mid = (begin + end) / 2;
    if (t[mid].last < ch)
      begin = mid + 1;
    else if (t[mid].first > ch)
      end = mid;
    else if ((ch - t[mid].first) % t[mid].step == 0)
      return ch + t[mid].offset;
    else
      return ch;
  }

  return ch;
}

#define define_category(cls, name) static int utf8_is##name (utfint ch)\
{ return find_in_range(name##_table, table_size(name##_table), ch); }
#define define_converter(name) static utfint utf8_to##name (utfint ch) \
{ return convert_char(to##name##_table, table_size(to##name##_table), ch); }
utf8_categories(define_category)
utf8_converters(define_converter)
#undef define_category
#undef define_converter

static int utf8_isgraph(utfint ch) {
  if (find_in_range(space_table, table_size(space_table), ch))
    return 0;
  if (find_in_range(graph_table, table_size(graph_table), ch))
    return 1;
  if (find_in_range(compose_table, table_size(compose_table), ch))
    return 1;
  return 0;
}

static int utf8_isalnum(utfint ch) {
  if (find_in_range(alpha_table, table_size(alpha_table), ch))
    return 1;
  if (find_in_range(alnum_extend_table, table_size(alnum_extend_table), ch))
    return 1;
  return 0;
}

static int utf8_width(utfint ch, int ambi_is_single) {
  if (find_in_range(doublewidth_table, table_size(doublewidth_table), ch))
    return 2;
  if (find_in_range(ambiwidth_table, table_size(ambiwidth_table), ch))
    return ambi_is_single ? 1 : 2;
  if (find_in_range(compose_table, table_size(compose_table), ch))
    return 0;
  if (find_in_range(unprintable_table, table_size(unprintable_table), ch))
    return 0;
  return 1;
}

/* string module compatible interface */

static const char *utf8_safe_decode(const char *p, utfint *pval) {
  p = utf8_decode(p, pval, 0);
  if (p == NULL) return 0;
  return p;
}

static size_t byte_relat(int64_t pos, size_t len) {
  if (pos >= 0) return pos;
  else if (0u - (size_t)pos > len) return 0;
  else return len + pos + 1;
}

/* string_buffer methods */
string_buffer_t string_buffer_init() {
  string_buffer_t buffer = {NULL, 0};
  return buffer;
}

void string_buffer_uninit(string_buffer_t* self) {
  if(self->buffer) {
    free(self->buffer);
    self->size = 0;
  }
}

void string_buffer_add(string_buffer_t* self, const char* s, size_t len) {
  if (!self->buffer) {
    self->buffer = malloc(len);
  } else {
    self->buffer = realloc(self->buffer, self->size + len);
  }
  memcpy(self->buffer+self->size, s, len);
  self->size += len;
}

void string_buffer_add_utf8char(string_buffer_t* self, utfint ch) {
  char buff[UTF8_BUFFSZ];
  size_t n = utf8_encode(buff, ch);
  string_buffer_add(self, buff+UTF8_BUFFSZ-n, n);
}

/* utfint_list methods */
utfint_list_t utfint_list_init() {
  utfint_list_t list = {NULL, 0};
  return list;
}

void utfint_list_uninit(utfint_list_t* self) {
  if (self->codepoints) {
    free(self->codepoints);
    self->codepoints = NULL;
  }
  self->size = 0;
}

void utfint_list_add(utfint_list_t* self, utfint value) {
  if (!self->codepoints) {
    self->codepoints = malloc(sizeof(utfint));
  } else {
    self->codepoints = realloc(self->codepoints, sizeof(utfint)*(self->size+1));
  }
  self->codepoints[self->size] = value;
  self->size++;
}

static const char* errinvutf8 = "invalid utf-8 sequence";

#define LUTF8_RETURN_ERROR(result, message) \
  result.err = true; \
  result.errmsg = message; \
  return result

/* Lutf8 functions */
int64_result_t Lutf8_len(const char* s, size_t len, int64_t start, int64_t end, bool lax) {
  size_t n;
  const char *p, *e;
  int64_t posi = byte_relat(start <= 0 ? 1 : start, len);
  int64_t pose = byte_relat(end <= 0 ? -1 : end, len);
  int64_result_t result = {false, NULL, 0};

  if (posi < 1 || posi-- >= len) {
    LUTF8_RETURN_ERROR(result, "initial position out of string");
  }
  if (--pose > len) {
    LUTF8_RETURN_ERROR(result, "final position out of string");
  }

  for (n = 0, p=s+posi, e=s+pose+1; p < e; ++n) {
    if (lax)
      p = utf8_next(p, e);
    else {
      utfint ch;
      const char *np = utf8_decode(p, &ch, !lax);
      if (np == NULL || utf8_invalid(ch)) {
        result.val = p - s + 1;
        LUTF8_RETURN_ERROR(result, errinvutf8);
      }
      p = np;
    }
  }
  result.val = n;
  return result;
}

string_buffer_t Lutf8_sub(const char* s, size_t len, int64_t start, int64_t end) {
  const char *e = s+len;
  size_t posi = start < 0 ? 1 : start;
  size_t pose = end < 0 ? -1 : end;
  string_buffer_t result = string_buffer_init();
  if (utf8_range(s, e, &posi, &pose)) {
    string_buffer_add(&result, s + posi, pose - posi);
  }
  return result;
}

string_buffer_result_t Lutf8_reverse(const char* s, size_t len, bool lax) {
  string_buffer_result_t result = {false, NULL, string_buffer_init()};
  const char *prev, *pprev, *ends, *e = s+len;
  (void) ends;
  if (lax) {
    for (prev = e; s < prev; e = prev) {
      prev = utf8_prev(s, prev);
      string_buffer_add(&result.val, prev, e-prev);
    }
  } else {
    for (prev = e; s < prev; prev = pprev) {
      utfint code = 0;
      ends = utf8_safe_decode(pprev = utf8_prev(s, prev), &code);
      assert(ends == prev);
      if (utf8_invalid(code)) {
        string_buffer_uninit(&result.val);
        LUTF8_RETURN_ERROR(result, errinvutf8);
      }
      if (!utf8_iscompose(code)) {
        string_buffer_add(&result.val, pprev, e-pprev);
        e = pprev;
      }
    }
  }
  return result;
}

utfint_list_t Lutf8_byte(const char* s, size_t len, int64_t start, int64_t end) {
  const char *e = s + len;
  size_t posi = start < 0 ? 1 : start;
  size_t pose = end < 0 ? posi : end;
  utfint_list_t list = utfint_list_init();
  if (utf8_range(s, e, &posi, &pose)) {
    for (e = s + pose, s = s + posi; s < e;) {
      utfint ch = 0;
      s = utf8_safe_decode(s, &ch);
      utfint_list_add(&list, ch);
    }
  }
  return list;
}

utfint_list_result_t Lutf8_codepoint(const char* s, size_t len, int64_t start, int64_t end, bool lax) {
  size_t posi = byte_relat(start < 0 ? 1 : start, len);
  size_t pose = byte_relat(end < 0 ? posi : end, len);

  const char *se;
  utfint_list_result_t result = {false, NULL, utfint_list_init()};

  if(posi < 1 || pose > len) {
    LUTF8_RETURN_ERROR(result, "out of range");
  }
  if (posi > pose) {
    LUTF8_RETURN_ERROR(result, "empty interval");
  }

  se = s + pose;  /* string end */
  for (s += posi - 1; s < se;) {
    utfint code = 0;
    s = utf8_safe_decode(s, &code);
    if (!lax && utf8_invalid(code)) {
      utfint_list_uninit(&result.val);
      LUTF8_RETURN_ERROR(result, errinvutf8);
    }
    utfint_list_add(&result.val, code);
  }

  return result;
}

string_buffer_result_t Lutf8_char(utfint_list_t list) {
  string_buffer_result_t result = {false, NULL, string_buffer_init()};
  for (int i = 0; i < list.size; i++) {
    utfint code = list.codepoints[i];
    if(code > UTF8_MAXCP) {
      string_buffer_uninit(&result.val);
      LUTF8_RETURN_ERROR(result, "value out of range");
    }
    string_buffer_add_utf8char(&result.val, code);
  }
  return result;
}

#define bind_converter(name)                                  \
utfint Lutf8_cp_##name (utfint codepoint) {                   \
  return utf8_to##name(codepoint);                            \
}                                                             \
string_buffer_t Lutf8_str_##name(const char* s, size_t len) { \
    string_buffer_t b = string_buffer_init();                 \
    const char *e = s+len;                                    \
    while (s < e) {                                           \
      utfint ch = 0;                                          \
      s = utf8_safe_decode(s, &ch);                           \
      string_buffer_add_utf8char(&b, utf8_to##name(ch));      \
    }                                                         \
    return b;                                                 \
}
utf8_converters(bind_converter)
#undef bind_converter

// /* unicode extra interface */

static const char *parse_escape(const char *s, const char *e, int hex, utfint *pch) {
  utfint code = 0;
  int in_bracket = 0;
  if (*s == '{') ++s, in_bracket = 1;
  for (; s < e; ++s) {
    utfint ch = (unsigned char)*s;
    if (ch >= '0' && ch <= '9') ch = ch - '0';
    else if (hex && ch >= 'A' && ch <= 'F') ch = 10 + (ch - 'A');
    else if (hex && ch >= 'a' && ch <= 'f') ch = 10 + (ch - 'a');
    else if (!in_bracket) break;
    else if (ch == '}')   { ++s; break; }
    else return NULL; // "invalid escape '%c'", ch
    code *= hex ? 16 : 10;
    code += ch;
  }
  *pch = code;
  return s;
}

string_buffer_result_t Lutf8_escape(const char* s, size_t len) {
  const char *e = s+len;
  string_buffer_result_t result = {false, NULL, string_buffer_init()};
  while (s < e && s != 0) {
    utfint ch = 0;
    s = utf8_safe_decode(s, &ch);
    if (ch == '%') {
      int hex = 0;
      switch (*s) {
      case '0': case '1': case '2': case '3':
      case '4': case '5': case '6': case '7':
      case '8': case '9': case '{':
        break;
      case 'x': case 'X': hex = 1; /* fall through */
      case 'u': case 'U': if (s+1 < e) { ++s; break; }
                            /* fall through */
      default:
        s = utf8_safe_decode(s, &ch);
        goto next;
      }
      s = parse_escape(s, e, hex, &ch);
      if (!s) {
        string_buffer_uninit(&result.val);
        LUTF8_RETURN_ERROR(result, "invalid escape codepoint encountered");
      }
    }
next:
    string_buffer_add_utf8char(&result.val, ch);
  }
  return result;
}

string_buffer_result_t Lutf8_insert(const char* s, size_t len, int64_t idx, const char* subs, size_t sublen) {
  const char *e = s+len;
  string_buffer_result_t result = {false, NULL, string_buffer_init()};
  const char *first = e;
  if (idx > 0) {
    if (idx != 0) first = utf8_relat(s, e, idx);
    if(idx < 1 || idx > len) {
      LUTF8_RETURN_ERROR(result, "invalid index");
    }
  }
  string_buffer_add(&result.val, s, first-s);
  string_buffer_add(&result.val, subs, sublen);
  string_buffer_add(&result.val, first, e-first);
  return result;
}

string_buffer_t Lutf8_remove(const char* s, size_t len, size_t start, size_t end) {
  const char *e = s+len;
  string_buffer_t b = string_buffer_init();
  if (!utf8_range(s, e, &start, &end))
    string_buffer_add(&b, s, len);
  else {
    string_buffer_add(&b, s, start);
    string_buffer_add(&b, s+end, e-s-end);
  }
  return b;
}

static utf8_offset_t push_offset(const char *s, const char *e, lua_Integer offset, lua_Integer idx) {
  utf8_offset_t position = {0, 0};
  utfint ch = 0;
  const char *p;
  if (idx != 0)
    p = utf8_offset(s, e, offset, idx);
  else if (p = s+offset-1, iscont(p))
    p = utf8_prev(s, p);
  if (p == NULL || p == e) return position;
  utf8_decode(p, &ch, 0);
  position.pos = p-s+1;
  position.codepoint = ch;
  return position;
}

utf8_offset_t Lutf8_charpos(const char* s, size_t len, int64_t charpos, int64_t idx) {
  const char *e = s+len;
  size_t offset = 1;
  if (idx < 0) {
      charpos = charpos < 0 ? 0 : charpos;
      if (charpos > 0) --charpos;
      else if (charpos < 0) offset = e-s+1;
      return push_offset(s, e, offset, charpos);
  }
  offset = byte_relat(charpos < 0 ? 1 : charpos, e-s);
  if (offset < 1) offset = 1;
  return push_offset(s, e, offset, idx);
}

int64_result_t Lutf8_offset(const char* s, size_t len, int64_t n, int64_t idx) {
  int64_result_t result = {false, NULL, 0};
  size_t posi = (n >= 0) ? 1 : len + 1;
  posi = byte_relat(idx < 0 ? posi : idx, len);

  if (posi < 1 || --posi > len) {
    LUTF8_RETURN_ERROR(result, "position out of range");
  }

  if (n == 0) {
    /* find beginning of current byte sequence */
    while (posi > 0 && iscont(s + posi)) posi--;
  } else {
    if (iscont(s + posi)) {
      LUTF8_RETURN_ERROR(result, "initial position is a continuation byte");
    }
    if (n < 0) {
       while (n < 0 && posi > 0) {  /* move back */
         do {  /* find beginning of previous character */
           posi--;
         } while (posi > 0 && iscont(s + posi));
         n++;
       }
     } else {
       n--;  /* do not move for 1st character */
       while (n > 0 && posi < len) {
         do {  /* find beginning of next character */
           posi++;
         } while (iscont(s + posi));  /* (cannot pass final '\0') */
         n--;
       }
     }
  }
  if (n == 0) {  /* did it find given character? */
    result.val = posi + 1;
  } else {
    LUTF8_RETURN_ERROR(result, "character not found");
  }
  return result;
}

utf8_offset_t Lutf8_next(const char* s, size_t len, int64_t offset, int64_t idx) {
  const char *e = s+len;
  offset = byte_relat(offset < 0 ? 1 : offset, e-s);
  idx = idx <= 0 ? 0 : idx;
  return push_offset(s, e, offset, idx);
}

utf8_offset_result_t Lutf8_codes(const char* s, size_t len, size_t n, int strict) {
  const char *e = s+len;
  const char *p = n <= 0 ? s : utf8_next(s+n-1, e);
  utf8_offset_result_t result = {0, 0};
  const char *next = 0;
  if (p < e) {
    utfint code = 0;
    next = utf8_safe_decode(p, &code);
    if (strict && utf8_invalid(code)) {
      LUTF8_RETURN_ERROR(result, "invalid UTF-8 code");
    }
    result.val.pos = p-s+1;
    result.val.codepoint = code;
    result.val.size = next - p;

    return result;
  }
  return result;  /* no more codepoints */
}

int Lutf8_width_cp(utfint code, bool ambi_is_double, int default_width) {
  int ambi_is_single = !ambi_is_double;
  default_width = default_width < 0 ? 0 : default_width;
  size_t chwidth = utf8_width(code, ambi_is_single);
  if (chwidth == 0) chwidth = default_width;
  return chwidth;
}

size_t Lutf8_width(const char* s, size_t len, bool ambi_is_double, int default_width) {
  int ambi_is_single = !ambi_is_double;
  default_width = default_width < 0 ? 0 : default_width;
  const char *e = s+len;
  size_t width = 0;
  while (s < e) {
    utfint ch = 0;
    int chwidth;
    s = utf8_safe_decode(s, &ch);
    chwidth = utf8_width(ch, ambi_is_single);
    width += chwidth == 0 ? default_width : chwidth;
  }
  return width;
}

// TODO: create another struct for the return of this function?
utf8_offset_t Lutf8_widthindex(const char* s, size_t len, size_t location, int ambi_is_double, int default_width) {
  const char *e = s+len;
  int width = location;
  int ambi_is_single = !ambi_is_double;
  default_width = default_width < 0 ? 0 : default_width;
  utf8_offset_t offset = {0, 0, 0};
  size_t idx = 1;
  while (s < e) {
    utfint ch = 0;
    size_t chwidth;
    s = utf8_safe_decode(s, &ch);
    chwidth = utf8_width(ch, ambi_is_single);
    if (chwidth == 0) chwidth = default_width;
    width -= CAST(int, chwidth);
    if (width <= 0) {
      offset.pos = idx;
      offset.codepoint = width + chwidth;
      offset.size = chwidth;
      return offset;
    }
    ++idx;
  }
  offset.pos = idx;
  return offset;
}

int Lutf8_ncasecmp(const char* s1, size_t len1, const char* s2, size_t len2) {
  const char *e1 = s1+len1;
  const char *e2 = s2+len2;
  while (s1 < e1 || s2 < e2) {
    utfint ch1 = 0, ch2 = 0;
    if (s1 == e1)
      ch2 = 1;
    else if (s2 == e2)
      ch1 = 1;
    else {
      s1 = utf8_safe_decode(s1, &ch1);
      s2 = utf8_safe_decode(s2, &ch2);
      ch1 = utf8_tofold(ch1);
      ch2 = utf8_tofold(ch2);
    }
    if (ch1 != ch2) {
      return ch1 > ch2 ? 1 : -1;
    }
  }
  return 0;
}

// /* utf8 pattern matching implement */

#ifndef   LUA_MAXCAPTURES
# define  LUA_MAXCAPTURES  32
#endif /* LUA_MAXCAPTURES */

#define CAP_UNFINISHED (-1)
#define CAP_POSITION   (-2)


typedef struct MatchState {
  int matchdepth;  /* control for recursive depth (to avoid C stack overflow) */
  const char *src_init;  /* init of source string */
  const char *src_end;  /* end ('\0') of source string */
  const char *p_end;  /* end ('\0') of pattern */
  utf8_pattern_result_t *result;
  const char *errmsg;
  int level;  /* total number of captures (finished or unfinished) */
  struct {
    const char *init;
    ptrdiff_t len;
  } capture[LUA_MAXCAPTURES];
} MatchState;

/* maximum recursion depth for 'match' */
#if !defined(MAXCCALLS)
#define MAXCCALLS       200
#endif

#define L_ESC           '%'
#define SPECIALS        "^$*+?.([%-"

static int check_capture(MatchState *ms, int l) {
  l -= '1';
  if (l < 0 || l >= ms->level || ms->capture[l].len == CAP_UNFINISHED) {
    ms->errmsg = "invalid capture index";
    return -1;
  }
  return l;
}

static int capture_to_close(MatchState *ms) {
  int level = ms->level;
  while (--level >= 0)
    if (ms->capture[level].len == CAP_UNFINISHED) return level;
  ms->errmsg = "invalid pattern capture";
  return -1;
}

static const char *classend(MatchState *ms, const char *p) {
  utfint ch = 0;
  p = utf8_safe_decode(p, &ch);
  switch (ch) {
    case L_ESC: {
      if (p == ms->p_end) {
        ms->errmsg = "malformed pattern (ends with '%')";
        return NULL;
      }
      return utf8_next(p, ms->p_end);
    }
    case '[': {
      if (*p == '^') p++;
      do {  /* look for a `]' */
        if (p == ms->p_end) {
          ms->errmsg = "malformed pattern (missing ']')";
          return NULL;
        }
        if (*(p++) == L_ESC && p < ms->p_end)
          p++;  /* skip escapes (e.g. `%]') */
      } while (*p != ']');
      return p+1;
    }
    default: {
      return p;
    }
  }
}

static int match_class (utfint c, utfint cl) {
  int res;
  switch (utf8_tolower(cl)) {
#define X(cls, name) case cls: res = utf8_is##name(c); break;
    utf8_categories(X)
#undef  X
    case 'g' : res = utf8_isgraph(c); break;
    case 'w' : res = utf8_isalnum(c); break;
    case 'z' : res = (c == 0); break;  /* deprecated option */
    default: return (cl == c);
  }
  return (utf8_islower(cl) ? res : !res);
}

static bool pattern_result_append_offset(utf8_pattern_result_t *result, int64_t offset) {
  utf8_pattern_value_t *values = realloc(
    result->values, sizeof(utf8_pattern_value_t) * (result->size + 1)
  );
  if (!values) return false;
  result->values = values;
  result->values[result->size].is_string = false;
  result->values[result->size].val.offset = offset;
  result->size++;
  return true;
}

static bool pattern_result_append_string(
  utf8_pattern_result_t *result,
  const char *string,
  size_t len
) {
  utf8_pattern_value_t *values = realloc(
    result->values, sizeof(utf8_pattern_value_t) * (result->size + 1)
  );
  if (!values) return false;
  result->values = values;
  result->values[result->size].is_string = true;
  result->values[result->size].val.string.string = string;
  result->values[result->size].val.string.len = (int64_t) len;
  result->size++;
  return true;
}

void Lutf8_pattern_result_uninit(utf8_pattern_result_t* self) {
  free(self->values);
  self->values = NULL;
  self->size = 0;
}

static int pattern_matchbracketclass(
  MatchState *ms,
  utfint c,
  const char *p,
  const char *ec
) {
  int sig = 1;
  if (*p != '[') return 0;
  if (*++p == '^') {
    sig = 0;
    p++;
  }
  while (p < ec) {
    utfint ch = 0;
    p = utf8_safe_decode(p, &ch);
    if (!p) {
      ms->errmsg = "invalid UTF-8 in pattern";
      return 0;
    }
    if (ch == L_ESC) {
      p = utf8_safe_decode(p, &ch);
      if (!p) {
        ms->errmsg = "invalid UTF-8 in pattern";
        return 0;
      }
      if (match_class(c, ch))
        return sig;
    } else {
      utfint next = 0;
      const char *np = utf8_safe_decode(p, &next);
      if (!np) {
        ms->errmsg = "invalid UTF-8 in pattern";
        return 0;
      }
      if (next == '-' && np < ec) {
        p = utf8_safe_decode(np, &next);
        if (!p) {
          ms->errmsg = "invalid UTF-8 in pattern";
          return 0;
        }
        if (ch <= c && c <= next)
          return sig;
      } else if (ch == c) {
        return sig;
      }
    }
  }
  return !sig;
}

static int pattern_singlematch(
  MatchState *ms,
  const char *s,
  const char *p,
  const char *ep
) {
  if (s >= ms->src_end)
    return 0;

  utfint ch = 0, pch = 0;
  if (!utf8_safe_decode(s, &ch)) {
    ms->errmsg = "invalid UTF-8 in string";
    return 0;
  }
  p = utf8_safe_decode(p, &pch);
  if (!p) {
    ms->errmsg = "invalid UTF-8 in pattern";
    return 0;
  }
  switch (pch) {
    case '.': return 1;
    case L_ESC:
      if (!utf8_safe_decode(p, &pch)) {
        ms->errmsg = "invalid UTF-8 in pattern";
        return 0;
      }
      return match_class(ch, pch);
    case '[': return pattern_matchbracketclass(ms, ch, p - 1, ep - 1);
    default: return pch == ch;
  }
}

static const char *pattern_matchbalance(MatchState *ms, const char *s, const char **p) {
  utfint ch = 0, begin = 0, end = 0;
  *p = utf8_safe_decode(*p, &begin);
  if (!*p || *p >= ms->p_end) {
    ms->errmsg = "malformed pattern (missing arguments to '%b')";
    return NULL;
  }
  *p = utf8_safe_decode(*p, &end);
  if (!*p || !utf8_safe_decode(s, &ch)) {
    ms->errmsg = "invalid UTF-8 in pattern";
    return NULL;
  }
  if (ch != begin) return NULL;

  int cont = 1;
  while (s < ms->src_end) {
    s = utf8_safe_decode(s, &ch);
    if (!s) {
      ms->errmsg = "invalid UTF-8 in string";
      return NULL;
    }
    if (ch == end) {
      if (--cont == 0) return s;
    } else if (ch == begin) {
      cont++;
    }
  }
  return NULL;
}

static const char *pattern_match(MatchState *ms, const char *s, const char *p);

static const char *pattern_max_expand(
  MatchState *ms,
  const char *s,
  const char *p,
  const char *ep
) {
  const char *m = s;
  while (pattern_singlematch(ms, m, p, ep))
    m = utf8_next(m, ms->src_end);
  while (s <= m) {
    const char *res = pattern_match(ms, m, ep + 1);
    if (res) return res;
    if (s == m) break;
    m = utf8_prev(s, m);
  }
  return NULL;
}

static const char *pattern_min_expand(
  MatchState *ms,
  const char *s,
  const char *p,
  const char *ep
) {
  for (;;) {
    const char *res = pattern_match(ms, s, ep + 1);
    if (res) return res;
    if (pattern_singlematch(ms, s, p, ep))
      s = utf8_next(s, ms->src_end);
    else
      return NULL;
  }
}

static const char *pattern_start_capture(
  MatchState *ms,
  const char *s,
  const char *p,
  int what
) {
  int level = ms->level;
  if (level >= LUA_MAXCAPTURES) {
    ms->errmsg = "too many captures";
    return NULL;
  }
  ms->capture[level].init = s;
  ms->capture[level].len = what;
  ms->level = level + 1;
  const char *res = pattern_match(ms, s, p);
  if (!res)
    ms->level--;
  return res;
}

static const char *pattern_end_capture(MatchState *ms, const char *s, const char *p) {
  int l = capture_to_close(ms);
  if (l < 0) return NULL;
  ms->capture[l].len = s - ms->capture[l].init;
  const char *res = pattern_match(ms, s, p);
  if (!res)
    ms->capture[l].len = CAP_UNFINISHED;
  return res;
}

static const char *pattern_match_capture(MatchState *ms, const char *s, int l) {
  l = check_capture(ms, l);
  if (l < 0) return NULL;
  size_t len = ms->capture[l].len;
  if ((size_t) (ms->src_end - s) >= len && memcmp(ms->capture[l].init, s, len) == 0)
    return s + len;
  return NULL;
}

static const char *pattern_match(MatchState *ms, const char *s, const char *p) {
  if (ms->matchdepth-- == 0) {
    ms->errmsg = "pattern too complex";
    return NULL;
  }
init:
  if (p != ms->p_end) {
    utfint ch = 0;
    if (!utf8_safe_decode(p, &ch)) {
      ms->errmsg = "invalid UTF-8 in pattern";
      ms->matchdepth++;
      return NULL;
    }
    switch (ch) {
      case '(':
        if (*(p + 1) == ')')
          s = pattern_start_capture(ms, s, p + 2, CAP_POSITION);
        else
          s = pattern_start_capture(ms, s, p + 1, CAP_UNFINISHED);
        break;
      case ')':
        s = pattern_end_capture(ms, s, p + 1);
        break;
      case '$':
        if ((p + 1) != ms->p_end)
          goto dflt;
        s = (s == ms->src_end) ? s : NULL;
        break;
      case L_ESC: {
        const char *prev_p = p;
        p = utf8_safe_decode(p + 1, &ch);
        if (!p) {
          ms->errmsg = "invalid UTF-8 in pattern";
          s = NULL;
          break;
        }
        switch (ch) {
          case 'b':
            s = pattern_matchbalance(ms, s, &p);
            if (s != NULL) goto init;
            break;
          case 'f': {
            const char *ep;
            utfint previous = 0, current = 0;
            if (*p != '[') {
              ms->errmsg = "missing '[' after '%f' in pattern";
              s = NULL;
              break;
            }
            ep = classend(ms, p);
            if (!ep) {
              s = NULL;
              break;
            }
            if (s != ms->src_init)
              utf8_decode(utf8_prev(ms->src_init, s), &previous, 0);
            if (s != ms->src_end)
              utf8_decode(s, &current, 0);
            if (!pattern_matchbracketclass(ms, previous, p, ep - 1) &&
                pattern_matchbracketclass(ms, current, p, ep - 1)) {
              p = ep;
              goto init;
            }
            s = NULL;
            break;
          }
          case '0': case '1': case '2': case '3': case '4':
          case '5': case '6': case '7': case '8': case '9':
            s = pattern_match_capture(ms, s, ch);
            if (s != NULL) goto init;
            break;
          default:
            p = prev_p;
            goto dflt;
        }
        break;
      }
      default:
dflt: {
        const char *ep = classend(ms, p);
        if (!ep) {
          s = NULL;
          break;
        }
        if (!pattern_singlematch(ms, s, p, ep)) {
          if (*ep == '*' || *ep == '?' || *ep == '-') {
            p = ep + 1;
            goto init;
          } else {
            s = NULL;
          }
        } else {
          const char *next_s = utf8_next(s, ms->src_end);
          switch (*ep) {
            case '?': {
              const char *next_ep = utf8_next(ep, ms->p_end);
              const char *res = pattern_match(ms, next_s, next_ep);
              if (res != NULL)
                s = res;
              else {
                p = next_ep;
                goto init;
              }
              break;
            }
            case '+':
              s = next_s;
            case '*':
              s = pattern_max_expand(ms, s, p, ep);
              break;
            case '-':
              s = pattern_min_expand(ms, s, p, ep);
              break;
            default:
              s = next_s;
              p = ep;
              goto init;
          }
        }
        break;
      }
    }
  }
  ms->matchdepth++;
  return s;
}

static const char *pattern_lmemfind(
  const char *s1,
  size_t l1,
  const char *s2,
  size_t l2
) {
  if (l2 == 0) return s1;
  if (l2 > l1) return NULL;

  l2--;
  l1 -= l2;
  while (l1 > 0) {
    const char *init = (const char *) memchr(s1, *s2, l1);
    if (!init) return NULL;
    init++;
    if (memcmp(init, s2 + 1, l2) == 0)
      return init - 1;
    l1 -= init - s1;
    s1 = init;
  }
  return NULL;
}

static int pattern_get_index(const char *p, const char *s, const char *e) {
  int idx;
  for (idx = 0; s < e && s < p; ++idx)
    s = utf8_next(s, e);
  return s == p ? idx : idx - 1;
}

static bool pattern_write_offset(
  utf8_pattern_result_t *result,
  utf8_pattern_offset_writer_t writer,
  void *writer_ctx,
  int64_t offset,
  const char **errmsg
) {
  if (writer) {
    if (writer(writer_ctx, offset)) return true;
    if (errmsg) *errmsg = "failed to store pattern match result";
    return false;
  }
  if (!pattern_result_append_offset(result, offset)) {
    if (errmsg) *errmsg = "failed to allocate pattern match result";
    return false;
  }
  return true;
}

static bool pattern_write_string(
  utf8_pattern_result_t *result,
  const char *string,
  size_t len,
  const char **errmsg
) {
  if (!pattern_result_append_string(result, string, len)) {
    if (errmsg) *errmsg = "failed to allocate pattern match result";
    return false;
  }
  return true;
}

static bool pattern_push_captures_filtered(
  MatchState *ms,
  const char *s,
  const char *e,
  utf8_pattern_result_t *result,
  utf8_pattern_offset_writer_t writer,
  void *writer_ctx,
  bool offsets_only,
  const char **errmsg
) {
  int nlevels = (ms->level == 0 && s) ? 1 : ms->level;
  for (int i = 0; i < nlevels; i++) {
    if (i >= ms->level) {
      if (i == 0) {
        if (!offsets_only && !pattern_write_string(result, s, e - s, errmsg)) return false;
      } else {
        if (errmsg) *errmsg = "invalid capture index";
        return false;
      }
      continue;
    }

    ptrdiff_t l = ms->capture[i].len;
    if (l == CAP_UNFINISHED) {
      if (errmsg) *errmsg = "unfinished capture";
      return false;
    }
    if (l == CAP_POSITION) {
      int idx = pattern_get_index(ms->capture[i].init, ms->src_init, ms->src_end);
      if (!pattern_write_offset(result, writer, writer_ctx, idx + 1, errmsg)) return false;
    } else if (!offsets_only) {
      if (!pattern_write_string(result, ms->capture[i].init, l, errmsg)) return false;
    }
  }
  return true;
}

static int pattern_nospecials(const char *p, const char *ep) {
  while (p < ep) {
    if (strpbrk(p, SPECIALS))
      return 0;
    p += strlen(p) + 1;
  }
  return 1;
}

static bool Lutf8_find_internal(
  const char* s, size_t len,
  const char* pattern, size_t pattern_len,
  int64_t offset, bool plain, bool find,
  utf8_pattern_result_t *result,
  utf8_pattern_offset_writer_t writer,
  void *writer_ctx,
  const char **errmsg
) {
  const char *es = s + len;
  const char *p = pattern;
  const char *ep = pattern + pattern_len;

  if (errmsg) *errmsg = NULL;
  offset = offset <= 0 ? 1 : offset;
  const char *init = utf8_relat(s, es, (int) offset);
  if (init == NULL) {
    if (offset > 0) return false;
    init = s;
  }

  if (find && (plain || pattern_nospecials(p, ep))) {
    const char *s2 = pattern_lmemfind(init, es - init, p, ep - p);
    if (s2) {
      const char *e2 = s2 + (ep - p);
      if (e2 < es && iscont(e2)) e2 = utf8_next(e2, es);
      offset = pattern_get_index(s2, s, es) + 1;
      if (!pattern_write_offset(result, writer, writer_ctx, offset, errmsg) ||
          !pattern_write_offset(result, writer, writer_ctx,
            offset + pattern_get_index(e2, s2, es) - 1, errmsg)) {
        return false;
      }
      return true;
    }
    return false;
  }

  MatchState ms;
  memset(&ms, 0, sizeof(ms));
  ms.result = result;
  int anchor = (*p == '^');
  if (anchor) p++;
  if (offset < 0) offset += utf8_length(s, es) + 1;
  ms.matchdepth = MAXCCALLS;
  ms.src_init = s;
  ms.src_end = es;
  ms.p_end = ep;

  do {
    const char *res;
    ms.level = 0;
    ms.errmsg = NULL;
    res = pattern_match(&ms, init, p);
    if (ms.errmsg) break;
    if (res != NULL) {
      if (find) {
        if (!pattern_write_offset(result, writer, writer_ctx, offset, errmsg) ||
            !pattern_write_offset(result, writer, writer_ctx,
              offset + utf8_length(init, res) - 1, errmsg) ||
            !pattern_push_captures_filtered(
              &ms, NULL, NULL, result, writer, writer_ctx, true, errmsg
            )) {
          return false;
        }
      } else {
        if (!pattern_push_captures_filtered(
          &ms, init, res, result, writer, writer_ctx, false, errmsg
        )) {
          return false;
        }
      }
      if (ms.errmsg) break;
      return true;
    }
    if (init == es) break;
    offset += 1;
    init = utf8_next(init, es);
  } while (init <= es && !anchor);

  if (ms.errmsg) {
    if (errmsg) *errmsg = ms.errmsg;
  }
  return false;
}

utf8_pattern_result_result_t Lutf8_find(
  const char* s, size_t len,
  const char* pattern, size_t pattern_len,
  int64_t offset, bool plain, bool find
) {
  utf8_pattern_result_result_t result = {false, NULL, {NULL, 0}};
  const char *errmsg = NULL;
  bool matched = Lutf8_find_internal(
    s, len, pattern, pattern_len, offset, plain, find,
    &result.val, NULL, NULL, &errmsg
  );
  if (!matched && errmsg) {
    Lutf8_pattern_result_uninit(&result.val);
    result.err = true;
    result.errmsg = errmsg;
  }
  return result;
}

bool Lutf8_find_noalloc(
  const char* s, size_t len,
  const char* pattern, size_t pattern_len,
  int64_t offset, bool plain, bool find,
  utf8_pattern_offset_writer_t writer, void* writer_ctx,
  const char** errmsg
) {
  return Lutf8_find_internal(
    s, len, pattern, pattern_len, offset, plain, find,
    NULL, writer, writer_ctx, errmsg
  );
}

utf8_pattern_result_result_t Lutf8_match(
  const char* s, size_t len,
  const char* pattern, size_t pattern_len,
  int64_t offset
) {
  return Lutf8_find(s, len, pattern, pattern_len, offset, false, false);
}
