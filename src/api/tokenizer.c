#include "api.h"
#include "../arena_allocator.h"
#include "../tokenizer/lutf8.h"
#include "../tokenizer/regex.h"

#include <SDL3/SDL.h>

#include <ctype.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define API_TYPE_TOKENIZER_SYNTAX "TokenizerSyntax"
#define TOKENIZER_SYNTAX_CACHE_FIELD "_tokenizer_native_cache"

static char tokenizer_syntax_map_key;
static char tokenizer_syntax_get_key;

typedef struct {
  char *data;
  size_t len;
} TokenizerString;

typedef struct {
  size_t count;
  TokenizerString *items;
} TokenizerTypeList;

typedef struct {
  TokenizerString key;
  TokenizerString value;
} TokenizerSymbol;

typedef struct {
  size_t count;
  TokenizerSymbol *items;
} TokenizerSymbolTable;

struct TokenizerSyntax;

typedef struct {
  bool disabled;
  bool is_regex;
  bool has_pair;
  bool has_subsyntax;
  bool reported_bad_pattern;
  bool whole_line[2];
  regex_pattern regex[2];
  bool regex_ready[2];
  TokenizerString code[2];
  TokenizerString anchored_code[2];
  TokenizerString escape;
  TokenizerString display_pattern;
  TokenizerTypeList types;
  struct TokenizerSyntax *subsyntax;
} TokenizerPattern;

typedef struct TokenizerSyntax {
  bool importing;
  bool imported;
  TokenizerString name;
  size_t pattern_count;
  TokenizerPattern *patterns;
  TokenizerSymbolTable symbols;
} TokenizerSyntax;

typedef struct {
  TokenizerSyntax syntax;
} TokenizerSyntaxUserdata;

typedef struct {
  const char *text;
  size_t byte_len;
  size_t char_len;
  size_t *char_offsets;
  bool is_ascii;
} TokenizerText;

typedef struct {
  unsigned char *data;
  size_t len;
  size_t cap;
} TokenizerState;

typedef struct {
  TokenizerSyntax *current_syntax;
  TokenizerPattern *subsyntax_info;
  int current_pattern_idx;
  int current_level;
} TokenizerCursor;

typedef struct {
  lua_Integer *values;
  int count;
  int cap;
} TokenizerFindResults;

typedef struct {
  const char *type;
  lua_Integer start;
  lua_Integer end;
  bool is_space;
} TokenizerTokenSpan;

typedef struct {
  lxl_arena *arena;
  TokenizerTokenSpan *items;
  size_t count;
  size_t cap;
} TokenizerTokenBuffer;

static bool tokenizer_text_is_space(const char *text, size_t len);
static const char *tokenizer_symbol_or_type(
  const TokenizerSyntax *syntax,
  const char *default_type,
  const char *text,
  size_t len
);
static const char *tokenizer_pattern_type(const TokenizerPattern *pattern, int idx);

static TokenizerString tokenizer_string_dup(const char *data, size_t len) {
  TokenizerString out = {NULL, 0};
  out.data = (char *) malloc(len + 1);
  if (!out.data) return out;
  if (len > 0) memcpy(out.data, data, len);
  out.data[len] = '\0';
  out.len = len;
  return out;
}

static TokenizerString tokenizer_string_dup_lua(lua_State *L, int idx) {
  size_t len = 0;
  const char *data = lua_tolstring(L, idx, &len);
  if (!data) {
    TokenizerString out = {NULL, 0};
    return out;
  }
  return tokenizer_string_dup(data, len);
}

static TokenizerString tokenizer_string_dup_anchored(const char *data, size_t len) {
  TokenizerString out = {NULL, 0};
  out.data = (char *) malloc(len + 2);
  if (!out.data) return out;
  out.data[0] = '^';
  if (len > 0) memcpy(out.data + 1, data, len);
  out.data[len + 1] = '\0';
  out.len = len + 1;
  return out;
}

static void tokenizer_string_free(TokenizerString *self) {
  free(self->data);
  self->data = NULL;
  self->len = 0;
}

static int tokenizer_string_compare(
  const char *left,
  size_t left_len,
  const char *right,
  size_t right_len
) {
  size_t common = left_len < right_len ? left_len : right_len;
  int cmp = common > 0 ? memcmp(left, right, common) : 0;
  if (cmp != 0) return cmp;
  if (left_len < right_len) return -1;
  if (left_len > right_len) return 1;
  return 0;
}

static void tokenizer_types_free(TokenizerTypeList *self) {
  for (size_t i = 0; i < self->count; i++) {
    tokenizer_string_free(&self->items[i]);
  }
  free(self->items);
  self->items = NULL;
  self->count = 0;
}

static void tokenizer_symbols_free(TokenizerSymbolTable *self) {
  for (size_t i = 0; i < self->count; i++) {
    tokenizer_string_free(&self->items[i].key);
    tokenizer_string_free(&self->items[i].value);
  }
  free(self->items);
  self->items = NULL;
  self->count = 0;
}

static void tokenizer_pattern_free(TokenizerPattern *self) {
  for (int i = 0; i < 2; i++) {
    tokenizer_string_free(&self->code[i]);
    tokenizer_string_free(&self->anchored_code[i]);
    if (self->regex_ready[i]) {
      regex_pattern_uninit(&self->regex[i]);
      self->regex_ready[i] = false;
    }
  }
  tokenizer_string_free(&self->escape);
  tokenizer_string_free(&self->display_pattern);
  tokenizer_types_free(&self->types);
  self->subsyntax = NULL;
}

static void tokenizer_syntax_free(TokenizerSyntax *self) {
  tokenizer_string_free(&self->name);
  for (size_t i = 0; i < self->pattern_count; i++) {
    tokenizer_pattern_free(&self->patterns[i]);
  }
  free(self->patterns);
  self->patterns = NULL;
  self->pattern_count = 0;
  tokenizer_symbols_free(&self->symbols);
  self->importing = false;
  self->imported = false;
}

static int tokenizer_syntax_gc(lua_State *L) {
  TokenizerSyntaxUserdata *ud =
    (TokenizerSyntaxUserdata *) luaL_checkudata(L, 1, API_TYPE_TOKENIZER_SYNTAX);
  tokenizer_syntax_free(&ud->syntax);
  return 0;
}

static size_t utf8_char_size(unsigned char c) {
  if (c < 0x80) return 1;
  if ((c & 0xE0) == 0xC0) return 2;
  if ((c & 0xF0) == 0xE0) return 3;
  if ((c & 0xF8) == 0xF0) return 4;
  return 1;
}

static void tokenizer_text_uninit(TokenizerText *self) {
  free(self->char_offsets);
  self->char_offsets = NULL;
  self->char_len = 0;
  self->is_ascii = false;
}

static void tokenizer_text_init(TokenizerText *self, const char *text, size_t byte_len) {
  self->text = text;
  self->byte_len = byte_len;
  self->char_offsets = NULL;
  self->char_len = 0;
  self->is_ascii = true;

  size_t byte_pos = 1;
  while (byte_pos <= byte_len) {
    if (((unsigned char) text[byte_pos - 1]) & 0x80) {
      self->is_ascii = false;
      break;
    }
    byte_pos++;
  }

  if (self->is_ascii) {
    self->char_len = byte_len;
    return;
  }

  self->char_offsets = (size_t *) malloc(sizeof(size_t) * (byte_len + 2));
  byte_pos = 1;
  while (byte_pos <= byte_len) {
    self->char_offsets[++self->char_len] = byte_pos;
    byte_pos += utf8_char_size((unsigned char) text[byte_pos - 1]);
  }
  self->char_offsets[self->char_len + 1] = byte_len + 1;
}

static size_t tokenizer_text_byte_at(const TokenizerText *self, lua_Integer char_index) {
  if (char_index <= 1) return 1;
  if ((size_t) char_index > self->char_len) return self->byte_len + 1;
  if (self->is_ascii) return (size_t) char_index;
  return self->char_offsets[char_index];
}

static size_t tokenizer_text_char_from_byte(const TokenizerText *self, size_t byte_pos) {
  if (self->char_len == 0) return 0;
  if (byte_pos <= 1) return 1;
  if (byte_pos > self->byte_len) return self->char_len;
  if (self->is_ascii) return byte_pos;

  size_t lo = 1;
  size_t hi = self->char_len;
  size_t ans = 1;
  while (lo <= hi) {
    size_t mid = lo + (hi - lo) / 2;
    if (self->char_offsets[mid] <= byte_pos) {
      ans = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return ans;
}

static size_t tokenizer_text_char_from_boundary(const TokenizerText *self, size_t byte_pos) {
  if (self->is_ascii) {
    if (byte_pos <= 1) return 1;
    if (byte_pos > self->byte_len + 1) return self->char_len + 1;
    return byte_pos;
  }
  size_t lo = 1;
  size_t hi = self->char_len + 1;
  size_t ans = self->char_len + 1;
  while (lo <= hi) {
    size_t mid = lo + (hi - lo) / 2;
    size_t offset = mid <= self->char_len ? self->char_offsets[mid] : self->byte_len + 1;
    if (offset >= byte_pos) {
      ans = mid;
      if (mid == 0) break;
      hi = mid - 1;
    } else {
      lo = mid + 1;
    }
  }
  return ans;
}

static void tokenizer_text_slice(
  const TokenizerText *self,
  lua_Integer start,
  lua_Integer finish,
  const char **text,
  size_t *len
  ) {
  if (start < 1) start = 1;
  if (finish < start || (size_t) start > self->char_len) {
    *text = self->text;
    *len = 0;
    return;
  }
  if ((size_t) finish > self->char_len) finish = (lua_Integer) self->char_len;
  size_t byte_start = self->is_ascii ? (size_t) start : self->char_offsets[start];
  size_t byte_end = self->is_ascii
    ? (size_t) finish
    : self->char_offsets[finish + 1] - 1;
  *text = self->text + byte_start - 1;
  *len = byte_end >= byte_start ? byte_end - byte_start + 1 : 0;
}

static size_t tokenizer_text_count_chars(const char *text, size_t byte_len) {
  size_t char_len = 0;
  size_t byte_pos = 0;
  while (byte_pos < byte_len) {
    char_len++;
    byte_pos += utf8_char_size((unsigned char) text[byte_pos]);
  }
  return char_len;
}

static void tokenizer_state_uninit(TokenizerState *self) {
  free(self->data);
  self->data = NULL;
  self->len = 0;
  self->cap = 0;
}

static void tokenizer_state_reserve(TokenizerState *self, size_t cap) {
  if (cap <= self->cap) return;
  unsigned char *data = (unsigned char *) realloc(self->data, cap);
  if (!data) return;
  self->data = data;
  self->cap = cap;
}

static void tokenizer_state_init_from_lua(
  lua_State *L,
  int idx,
  TokenizerState *self,
  bool default_zero
) {
  size_t len = 0;
  const char *state = NULL;
  self->data = NULL;
  self->len = 0;
  self->cap = 0;

  if (!lua_isnoneornil(L, idx) && !lua_isboolean(L, idx)) {
    state = luaL_checklstring(L, idx, &len);
  } else if (default_zero) {
    len = 1;
    state = "\0";
  }

  tokenizer_state_reserve(self, len > 0 ? len : 1);
  if (state && len > 0) memcpy(self->data, state, len);
  self->len = len;
}

static void tokenizer_state_push(lua_State *L, const TokenizerState *self) {
  lua_pushlstring(L, (const char *) self->data, self->len);
}

static void tokenizer_state_set_pattern_idx(
  TokenizerState *self,
  int current_level,
  int pattern_idx
) {
  size_t level = (size_t) current_level;
  if (level > self->len) {
    tokenizer_state_reserve(self, level);
    self->data[self->len++] = (unsigned char) pattern_idx;
  } else if (self->len == 1) {
    self->data[0] = (unsigned char) pattern_idx;
  } else {
    self->data[level - 1] = (unsigned char) pattern_idx;
  }
}

static void tokenizer_cursor_init(TokenizerCursor *self) {
  self->current_syntax = NULL;
  self->subsyntax_info = NULL;
  self->current_pattern_idx = 0;
  self->current_level = 1;
}

static void tokenizer_find_results_uninit(TokenizerFindResults *self) {
  free(self->values);
  self->values = NULL;
  self->count = 0;
  self->cap = 0;
}

static void tokenizer_find_results_reset(TokenizerFindResults *self) {
  self->count = 0;
}

static bool tokenizer_find_results_push(TokenizerFindResults *self, lua_Integer value) {
  if (self->count == self->cap) {
    int next_cap = self->cap == 0 ? 8 : self->cap * 2;
    lua_Integer *values = (lua_Integer *) realloc(self->values, sizeof(lua_Integer) * next_cap);
    if (!values) return false;
    self->values = values;
    self->cap = next_cap;
  }
  self->values[self->count++] = value;
  return true;
}

static bool tokenizer_find_results_push_int64(void *ctx, int64_t value) {
  return tokenizer_find_results_push((TokenizerFindResults *) ctx, (lua_Integer) value);
}

static bool tokenizer_find_results_push_size(void *ctx, size_t value) {
  return tokenizer_find_results_push((TokenizerFindResults *) ctx, (lua_Integer) value);
}

static void tokenizer_token_buffer_init(lua_State *L, TokenizerTokenBuffer *self) {
  self->arena = lxl_arena_init(L);
  self->items = NULL;
  self->count = 0;
  self->cap = 0;
}

static bool tokenizer_token_buffer_reserve(TokenizerTokenBuffer *self, size_t cap) {
  if (cap <= self->cap) return true;
  TokenizerTokenSpan *items = lxl_arena_malloc(self->arena, sizeof(TokenizerTokenSpan) * cap);
  if (!items) return false;
  if (self->items && self->count > 0) {
    memcpy(items, self->items, sizeof(TokenizerTokenSpan) * self->count);
  }
  self->items = items;
  self->cap = cap;
  return true;
}

static bool tokenizer_token_buffer_append(
  TokenizerTokenBuffer *self,
  const char *type,
  lua_Integer start,
  lua_Integer end,
  bool is_space
) {
  if (start > end) return true;
  if (self->count == self->cap) {
    size_t next_cap = self->cap == 0 ? 16 : self->cap * 2;
    if (!tokenizer_token_buffer_reserve(self, next_cap)) return false;
  }
  self->items[self->count].type = type;
  self->items[self->count].start = start;
  self->items[self->count].end = end;
  self->items[self->count].is_space = is_space;
  self->count++;
  return true;
}

static bool tokenizer_token_buffer_push_slice(
  TokenizerTokenBuffer *self,
  const char *type,
  lua_Integer start,
  lua_Integer end,
  size_t segment_len,
  bool is_space
) {
  if (start > end) return true;
  if (!type) type = "normal";
  if (segment_len == 0) return true;

  if (self->count > 0) {
    TokenizerTokenSpan *prev = &self->items[self->count - 1];
    if (
      strcmp(prev->type, type) == 0 ||
      (strcmp(type, "incomplete") != 0 && prev->is_space)
    ) {
      prev->type = type;
      prev->end = end;
      prev->is_space = prev->is_space && is_space;
      return true;
    }
  }

  return tokenizer_token_buffer_append(self, type, start, end, is_space);
}

static bool tokenizer_token_buffer_push(
  TokenizerTokenBuffer *self,
  const TokenizerText *text,
  const char *type,
  lua_Integer start,
  lua_Integer end
) {
  const char *segment = NULL;
  size_t segment_len = 0;
  tokenizer_text_slice(text, start, end, &segment, &segment_len);
  bool is_space = strcmp(type ? type : "normal", "incomplete") != 0 &&
    tokenizer_text_is_space(segment, segment_len);
  return tokenizer_token_buffer_push_slice(self, type, start, end, segment_len, is_space);
}

static void tokenizer_token_buffer_push_tokens(
  TokenizerTokenBuffer *buffer,
  const TokenizerSyntax *syntax,
  const TokenizerPattern *pattern,
  const TokenizerText *text,
  const TokenizerFindResults *results
) {
  if (results->count > 2) {
    lua_Integer current = results->values[0];
    for (int segment_idx = 1; segment_idx < results->count; segment_idx++) {
      lua_Integer next = segment_idx < (results->count - 1)
        ? results->values[segment_idx + 1]
        : results->values[1] + 1;
      lua_Integer finish = next - 1;
      if (finish >= current) {
        const char *segment = NULL;
        size_t segment_len = 0;
        tokenizer_text_slice(text, current, finish, &segment, &segment_len);
        const char *type = tokenizer_pattern_type(pattern, segment_idx);
        type = tokenizer_symbol_or_type(syntax, type, segment, segment_len);
        tokenizer_token_buffer_push_slice(
          buffer,
          type,
          current,
          finish,
          segment_len,
          tokenizer_text_is_space(segment, segment_len)
        );
      }
      current = next;
    }
  } else if (results->count >= 2) {
    const char *segment = NULL;
    size_t segment_len = 0;
    tokenizer_text_slice(text, results->values[0], results->values[1], &segment, &segment_len);
    const char *type = tokenizer_pattern_type(pattern, 1);
    type = tokenizer_symbol_or_type(syntax, type, segment, segment_len);
    tokenizer_token_buffer_push_slice(
      buffer,
      type,
      results->values[0],
      results->values[1],
      segment_len,
      tokenizer_text_is_space(segment, segment_len)
    );
  }
}

static int tokenizer_token_buffer_to_lua(
  lua_State *L,
  const TokenizerTokenBuffer *buffer,
  const TokenizerText *text
) {
  lua_newtable(L);
  int table_idx = lua_gettop(L);
  for (size_t i = 0; i < buffer->count; i++) {
    const TokenizerTokenSpan *span = &buffer->items[i];
    const char *segment = NULL;
    size_t segment_len = 0;
    tokenizer_text_slice(text, span->start, span->end, &segment, &segment_len);
    lua_pushstring(L, span->type);
    lua_rawseti(L, table_idx, (int) (i * 2) + 1);
    lua_pushlstring(L, segment, segment_len);
    lua_rawseti(L, table_idx, (int) (i * 2) + 2);
  }
  return table_idx;
}

static void tokenizer_token_buffer_init_from_resume(
  lua_State *L,
  TokenizerTokenBuffer *buffer,
  const TokenizerText *text,
  int res_idx
) {
  res_idx = lua_absindex(L, res_idx);
  size_t count = lua_rawlen(L, res_idx);
  while (count >= 2) {
    lua_rawgeti(L, res_idx, count - 1);
    bool incomplete = lua_isstring(L, -1) && strcmp(lua_tostring(L, -1), "incomplete") == 0;
    lua_pop(L, 1);
    if (!incomplete) break;
    count -= 2;
  }

  lua_Integer cursor = 1;
  for (size_t idx = 1; idx + 1 <= count; idx += 2) {
    lua_rawgeti(L, res_idx, (int) idx);
    const char *type = lua_tostring(L, -1);
    lua_pop(L, 1);
    lua_rawgeti(L, res_idx, (int) idx + 1);
    size_t segment_len = 0;
    const char *segment = lua_tolstring(L, -1, &segment_len);
    size_t char_len = text->is_ascii ? segment_len : tokenizer_text_count_chars(segment, segment_len);
    lua_pop(L, 1);
    tokenizer_token_buffer_append(
      buffer,
      type,
      cursor,
      cursor + (lua_Integer) char_len - 1,
      tokenizer_text_is_space(segment, segment_len)
    );
    cursor += (lua_Integer) char_len;
  }
}

static void tokenizer_push_syntax_map(lua_State *L) {
  lua_pushlightuserdata(L, (void *) &tokenizer_syntax_map_key);
  lua_rawget(L, LUA_REGISTRYINDEX);
  if (lua_istable(L, -1)) return;
  lua_pop(L, 1);
  lua_newtable(L);
  lua_newtable(L);
  lua_pushliteral(L, "v");
  lua_setfield(L, -2, "__mode");
  lua_setmetatable(L, -2);
  lua_pushlightuserdata(L, (void *) &tokenizer_syntax_map_key);
  lua_pushvalue(L, -2);
  lua_rawset(L, LUA_REGISTRYINDEX);
}

static void tokenizer_syntax_map_set(lua_State *L, TokenizerSyntax *syntax, int syntax_idx) {
  syntax_idx = lua_absindex(L, syntax_idx);
  tokenizer_push_syntax_map(L);
  lua_pushlightuserdata(L, syntax);
  lua_pushvalue(L, syntax_idx);
  lua_rawset(L, -3);
  lua_pop(L, 1);
}

static bool tokenizer_push_lua_syntax(lua_State *L, TokenizerSyntax *syntax) {
  tokenizer_push_syntax_map(L);
  lua_pushlightuserdata(L, syntax);
  lua_rawget(L, -2);
  lua_remove(L, -2);
  return !lua_isnil(L, -1);
}

static void tokenizer_push_syntax_get(lua_State *L) {
  lua_pushlightuserdata(L, (void *) &tokenizer_syntax_get_key);
  lua_rawget(L, LUA_REGISTRYINDEX);
  if (lua_isfunction(L, -1)) return;
  lua_pop(L, 1);
  lua_getglobal(L, "require");
  lua_pushliteral(L, "core.syntax");
  lua_call(L, 1, 1);
  lua_getfield(L, -1, "get");
  lua_remove(L, -2);
  lua_pushlightuserdata(L, (void *) &tokenizer_syntax_get_key);
  lua_pushvalue(L, -2);
  lua_rawset(L, LUA_REGISTRYINDEX);
}

static int tokenizer_call_log(lua_State *L, const char *field, const char *message) {
  lua_getglobal(L, "core");
  lua_getfield(L, -1, field);
  lua_remove(L, -2);
  lua_pushstring(L, message);
  lua_call(L, 1, 0);
  return 0;
}

static double tokenizer_get_time(void) {
  return SDL_GetPerformanceCounter() / (double) SDL_GetPerformanceFrequency();
}

static double tokenizer_get_max_time(lua_State *L) {
  lua_getglobal(L, "core");
  lua_getfield(L, -1, "co_max_time");
  double value = lua_tonumber(L, -1) / 2.0;
  lua_pop(L, 2);
  return floor(10000.0 * value) / 10000.0;
}

static bool tokenizer_text_is_space(const char *text, size_t len) {
  if (len == 0) return true;
  for (size_t i = 0; i < len; i++) {
    if (!isspace((unsigned char) text[i])) return false;
  }
  return true;
}

static int tokenizer_symbol_compare_item(const void *left, const void *right) {
  const TokenizerSymbol *a = (const TokenizerSymbol *) left;
  const TokenizerSymbol *b = (const TokenizerSymbol *) right;
  return tokenizer_string_compare(a->key.data, a->key.len, b->key.data, b->key.len);
}

static const char *tokenizer_lookup_symbol(
  const TokenizerSymbolTable *table,
  const char *text,
  size_t len
) {
  size_t lo = 0;
  size_t hi = table->count;
  while (lo < hi) {
    size_t mid = lo + (hi - lo) / 2;
    int cmp = tokenizer_string_compare(
      table->items[mid].key.data,
      table->items[mid].key.len,
      text,
      len
    );
    if (cmp == 0) return table->items[mid].value.data;
    if (cmp < 0) lo = mid + 1;
    else hi = mid;
  }
  return NULL;
}

static const char *tokenizer_symbol_or_type(
  const TokenizerSyntax *syntax,
  const char *default_type,
  const char *text,
  size_t len
) {
  const char *symbol = tokenizer_lookup_symbol(&syntax->symbols, text, len);
  return symbol ? symbol : default_type;
}

static const char *tokenizer_pattern_type(const TokenizerPattern *pattern, int idx) {
  if ((size_t) idx == 0 || (size_t) idx > pattern->types.count) return NULL;
  return pattern->types.items[idx - 1].data;
}

static void tokenizer_report_bad_pattern(
  lua_State *L,
  const TokenizerSyntax *syntax,
  TokenizerPattern *pattern,
  int pattern_idx,
  const char *log_field,
  const char *fmt,
  ...
) {
  if (pattern->reported_bad_pattern) return;
  pattern->reported_bad_pattern = true;

  char detail[512];
  va_list args;
  va_start(args, fmt);
  vsnprintf(detail, sizeof(detail), fmt, args);
  va_end(args);

  const char *pattern_text = pattern->display_pattern.data ? pattern->display_pattern.data : "<table>";
  const char *syntax_name = syntax->name.data ? syntax->name.data : "unnamed";

  char message[1024];
  snprintf(
    message,
    sizeof(message),
    "Malformed pattern #%d <%s> in %s language plugin.\n%s",
    pattern_idx,
    pattern_text,
    syntax_name,
    detail
  );
  tokenizer_call_log(L, log_field, message);
}

static TokenizerSyntax *tokenizer_get_syntax_cache(lua_State *L, int syntax_idx);

static void tokenizer_import_types(lua_State *L, int pattern_idx, TokenizerPattern *pattern) {
  pattern_idx = lua_absindex(L, pattern_idx);
  lua_getfield(L, pattern_idx, "type");
  if (lua_istable(L, -1)) {
    size_t count = lua_rawlen(L, -1);
    pattern->types.items = (TokenizerString *) calloc(count, sizeof(TokenizerString));
    pattern->types.count = count;
    for (size_t i = 0; i < count; i++) {
      lua_rawgeti(L, -1, (int) i + 1);
      pattern->types.items[i] = tokenizer_string_dup_lua(L, -1);
      lua_pop(L, 1);
    }
  } else if (lua_isstring(L, -1)) {
    pattern->types.items = (TokenizerString *) calloc(1, sizeof(TokenizerString));
    pattern->types.count = 1;
    pattern->types.items[0] = tokenizer_string_dup_lua(L, -1);
  }
  lua_pop(L, 1);
}

static void tokenizer_import_symbols(lua_State *L, int syntax_idx, TokenizerSyntax *syntax) {
  syntax_idx = lua_absindex(L, syntax_idx);
  lua_getfield(L, syntax_idx, "symbols");
  if (!lua_istable(L, -1)) {
    lua_pop(L, 1);
    return;
  }

  lua_pushnil(L);
  while (lua_next(L, -2) != 0) {
    if (lua_isstring(L, -2) && lua_isstring(L, -1)) {
      size_t next_count = syntax->symbols.count + 1;
      TokenizerSymbol *items = (TokenizerSymbol *) realloc(
        syntax->symbols.items,
        sizeof(TokenizerSymbol) * next_count
      );
      if (items) {
        syntax->symbols.items = items;
        TokenizerSymbol *symbol = &syntax->symbols.items[syntax->symbols.count];
        memset(symbol, 0, sizeof(*symbol));
        symbol->key = tokenizer_string_dup_lua(L, -2);
        symbol->value = tokenizer_string_dup_lua(L, -1);
        syntax->symbols.count = next_count;
      }
    }
    lua_pop(L, 1);
  }
  lua_pop(L, 1);

  if (syntax->symbols.count > 1) {
    qsort(
      syntax->symbols.items,
      syntax->symbols.count,
      sizeof(TokenizerSymbol),
      tokenizer_symbol_compare_item
    );
  }
}

static void tokenizer_import_code_part(
  lua_State *L,
  TokenizerPattern *pattern,
  int part,
  const char *raw,
  size_t raw_len
) {
  bool whole_line = raw_len > 0 && raw[0] == '^';
  pattern->whole_line[part] = whole_line;

  const char *code = whole_line ? raw + 1 : raw;
  size_t code_len = whole_line ? raw_len - 1 : raw_len;
  pattern->code[part] = tokenizer_string_dup(code, code_len);
  pattern->anchored_code[part] = tokenizer_string_dup_anchored(code, code_len);

  if (pattern->is_regex) {
    regex_pattern_result result = regex_pattern_init(code, code_len);
    if (!result.err) {
      pattern->regex[part] = result.val;
      pattern->regex_ready[part] = true;
    } else {
      pattern->disabled = true;
    }
  }
}

static TokenizerSyntax *tokenizer_resolve_subsyntax(lua_State *L, int syntax_field_idx) {
  syntax_field_idx = lua_absindex(L, syntax_field_idx);
  if (lua_istable(L, syntax_field_idx)) {
    return tokenizer_get_syntax_cache(L, syntax_field_idx);
  }
  if (!lua_isstring(L, syntax_field_idx)) {
    return NULL;
  }

  tokenizer_push_syntax_get(L);
  lua_pushvalue(L, syntax_field_idx);
  lua_call(L, 1, 1);
  TokenizerSyntax *syntax = lua_istable(L, -1) ? tokenizer_get_syntax_cache(L, -1) : NULL;
  lua_pop(L, 1);
  return syntax;
}

static void tokenizer_import_pattern(lua_State *L, int pattern_idx, TokenizerPattern *pattern) {
  pattern_idx = lua_absindex(L, pattern_idx);

  lua_getfield(L, pattern_idx, "disabled");
  pattern->disabled = lua_toboolean(L, -1);
  lua_pop(L, 1);

  lua_getfield(L, pattern_idx, "pattern");
  if (!lua_isnil(L, -1)) {
    pattern->is_regex = false;
  } else {
    lua_pop(L, 1);
    lua_getfield(L, pattern_idx, "regex");
    if (lua_isnil(L, -1)) {
      lua_pop(L, 1);
      pattern->disabled = true;
      return;
    }
    pattern->is_regex = true;
  }

  int target_idx = lua_gettop(L);
  pattern->has_pair = lua_istable(L, target_idx);
  pattern->display_pattern = pattern->has_pair
    ? tokenizer_string_dup("<table>", sizeof("<table>") - 1)
    : tokenizer_string_dup_lua(L, target_idx);

  int parts = pattern->has_pair ? 2 : 1;
  for (int part = 0; part < parts; part++) {
    if (pattern->has_pair) lua_rawgeti(L, target_idx, part + 1);
    else lua_pushvalue(L, target_idx);
    if (lua_isstring(L, -1)) {
      size_t raw_len = 0;
      const char *raw = lua_tolstring(L, -1, &raw_len);
      tokenizer_import_code_part(L, pattern, part, raw, raw_len);
    } else {
      pattern->disabled = true;
    }
    lua_pop(L, 1);
  }

  if (pattern->has_pair) {
    lua_rawgeti(L, target_idx, 3);
    if (lua_isstring(L, -1)) {
      pattern->escape = tokenizer_string_dup_lua(L, -1);
    }
    lua_pop(L, 1);
  }
  lua_pop(L, 1);

  tokenizer_import_types(L, pattern_idx, pattern);

  lua_getfield(L, pattern_idx, "syntax");
  if (!lua_isnil(L, -1)) {
    pattern->has_subsyntax = true;
    pattern->subsyntax = tokenizer_resolve_subsyntax(L, -1);
  }
  lua_pop(L, 1);
}

static TokenizerSyntax *tokenizer_get_syntax_cache(lua_State *L, int syntax_idx) {
  syntax_idx = lua_absindex(L, syntax_idx);

  lua_getfield(L, syntax_idx, TOKENIZER_SYNTAX_CACHE_FIELD);
  if (luaL_testudata(L, -1, API_TYPE_TOKENIZER_SYNTAX)) {
    TokenizerSyntaxUserdata *ud = (TokenizerSyntaxUserdata *) lua_touserdata(L, -1);
    lua_pop(L, 1);
    return &ud->syntax;
  }
  lua_pop(L, 1);

  TokenizerSyntaxUserdata *ud =
    (TokenizerSyntaxUserdata *) lua_newuserdata(L, sizeof(TokenizerSyntaxUserdata));
  memset(ud, 0, sizeof(*ud));
  luaL_setmetatable(L, API_TYPE_TOKENIZER_SYNTAX);
  lua_pushvalue(L, -1);
  lua_setfield(L, syntax_idx, TOKENIZER_SYNTAX_CACHE_FIELD);
  tokenizer_syntax_map_set(L, &ud->syntax, syntax_idx);

  TokenizerSyntax *syntax = &ud->syntax;
  syntax->importing = true;

  lua_getfield(L, syntax_idx, "name");
  if (lua_isstring(L, -1)) syntax->name = tokenizer_string_dup_lua(L, -1);
  lua_pop(L, 1);

  lua_getfield(L, syntax_idx, "patterns");
  if (lua_istable(L, -1)) {
    syntax->pattern_count = lua_rawlen(L, -1);
    syntax->patterns = (TokenizerPattern *) calloc(syntax->pattern_count, sizeof(TokenizerPattern));
    for (size_t i = 0; i < syntax->pattern_count; i++) {
      lua_rawgeti(L, -1, (int) i + 1);
      if (lua_istable(L, -1)) {
        tokenizer_import_pattern(L, -1, &syntax->patterns[i]);
      } else {
        syntax->patterns[i].disabled = true;
      }
      lua_pop(L, 1);
    }
  }
  lua_pop(L, 1);

  tokenizer_import_symbols(L, syntax_idx, syntax);

  syntax->importing = false;
  syntax->imported = true;
  lua_pop(L, 1);
  return syntax;
}

static void tokenizer_retrieve_syntax_state(
  TokenizerSyntax *incoming_syntax,
  const TokenizerState *state,
  TokenizerCursor *cursor
) {
  tokenizer_cursor_init(cursor);
  cursor->current_syntax = incoming_syntax;
  cursor->current_pattern_idx = state->len > 0 ? state->data[0] : 0;
  if (cursor->current_pattern_idx <= 0) return;
  if ((size_t) cursor->current_pattern_idx > cursor->current_syntax->pattern_count) {
    cursor->current_pattern_idx = 0;
    return;
  }

  for (size_t i = 0; i < state->len; i++) {
    int target = state->data[i];
    if (target == 0) break;
    if ((size_t) target > cursor->current_syntax->pattern_count) break;
    TokenizerPattern *pattern = &cursor->current_syntax->patterns[target - 1];
    if (pattern->subsyntax) {
      cursor->subsyntax_info = pattern;
      cursor->current_syntax = pattern->subsyntax;
      cursor->current_pattern_idx = 0;
      cursor->current_level = (int) i + 2;
    } else {
      cursor->current_pattern_idx = target;
      break;
    }
  }
}

static bool tokenizer_match_is_escaped(
  const TokenizerText *text,
  lua_Integer start,
  const TokenizerString *escape
) {
  if (!escape->data || escape->len == 0) return false;

  int count = 0;
  for (lua_Integer i = start - 1; i >= 1; i--) {
    const char *segment = NULL;
    size_t segment_len = 0;
    tokenizer_text_slice(text, i, i, &segment, &segment_len);
    if (segment_len != escape->len || memcmp(segment, escape->data, escape->len) != 0) break;
    count++;
  }
  return (count % 2) != 0;
}

static bool tokenizer_find_text(
  lua_State *L,
  const TokenizerText *text,
  const TokenizerPattern *pattern,
  lua_Integer offset,
  bool at_start,
  bool close,
  TokenizerFindResults *out,
  TokenizerFindResults *scratch
) {
  if (pattern->disabled) return false;

  int part = close && pattern->has_pair ? 1 : 0;
  lua_Integer current_end = offset - 1;
  for (;;) {
    lua_Integer next = current_end + 1;
    if (pattern->whole_line[part] && next > 1) {
      tokenizer_find_results_reset(out);
      return false;
    }

    bool anchored = at_start || pattern->whole_line[part];
    tokenizer_find_results_reset(out);

    if (!pattern->is_regex) {
      const TokenizerString *code = anchored ? &pattern->anchored_code[part] : &pattern->code[part];
      bool found = Lutf8_find_noalloc(
        text->text,
        text->byte_len,
        code->data,
        code->len,
        next,
        false,
        true,
        tokenizer_find_results_push_int64,
        out,
        NULL
      );
      if (!found || out->count == 0) {
        return false;
      }
    } else {
      tokenizer_find_results_reset(scratch);
      bool found = regex_pattern_find_noalloc(
        (regex_pattern *) &pattern->regex[part],
        text->text,
        text->byte_len,
        (int64_t) tokenizer_text_byte_at(text, next),
        anchored ? REGEX_OPTION_ANCHORED : 0,
        tokenizer_find_results_push_size,
        scratch,
        NULL
      );
      if (!found || scratch->count < 2) {
        return false;
      }

      lua_Integer start_char =
        (lua_Integer) tokenizer_text_char_from_byte(text, scratch->values[0]);
      lua_Integer end_char = scratch->values[1] < scratch->values[0]
        ? start_char - 1
        : (lua_Integer) tokenizer_text_char_from_byte(text, scratch->values[1]);

      tokenizer_find_results_push(out, start_char);
      tokenizer_find_results_push(out, end_char);
      for (int i = 2; i < scratch->count; i++) {
        tokenizer_find_results_push(
          out,
          (lua_Integer) tokenizer_text_char_from_boundary(text, (size_t) scratch->values[i])
        );
      }
    }

    if (out->count < 2) return false;
    current_end = out->values[1];
    if (!close) return true;
    if (!tokenizer_match_is_escaped(text, out->values[0], &pattern->escape)) {
      return true;
    }
    if (at_start) {
      tokenizer_find_results_reset(out);
      return false;
    }
  }
}

static void tokenizer_push_subsyntax(
  TokenizerState *state,
  TokenizerCursor *cursor,
  TokenizerPattern *pattern,
  int pattern_idx
) {
  tokenizer_state_set_pattern_idx(state, cursor->current_level, pattern_idx);
  cursor->current_level++;
  cursor->subsyntax_info = pattern;
  cursor->current_syntax = pattern->subsyntax;
  cursor->current_pattern_idx = 0;
}

static void tokenizer_pop_subsyntax(
  TokenizerSyntax *incoming_syntax,
  TokenizerState *state,
  TokenizerCursor *cursor
) {
  cursor->current_level--;
  if ((size_t) cursor->current_level < state->len) {
    state->len = cursor->current_level;
  }
  tokenizer_state_set_pattern_idx(state, cursor->current_level, 0);
  tokenizer_retrieve_syntax_state(incoming_syntax, state, cursor);
}

static int f_tokenizer_extract_subsyntaxes(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  TokenizerSyntax *incoming_syntax = tokenizer_get_syntax_cache(L, 1);
  TokenizerState state;
  tokenizer_state_init_from_lua(L, 2, &state, false);

  lua_newtable(L);
  int out_idx = lua_gettop(L);
  int n = 0;

  do {
    TokenizerCursor cursor;
    tokenizer_retrieve_syntax_state(incoming_syntax, &state, &cursor);
    if (cursor.current_syntax && tokenizer_push_lua_syntax(L, cursor.current_syntax)) {
      lua_rawseti(L, out_idx, ++n);
    } else {
      lua_pop(L, 1);
    }

    if (state.len > 0) {
      memmove(state.data, state.data + 1, state.len - 1);
      state.len--;
    }
  } while (state.len > 0);

  tokenizer_state_uninit(&state);
  return 1;
}

static int f_tokenizer_tokenize(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  TokenizerSyntax *incoming_syntax = tokenizer_get_syntax_cache(L, 1);

  size_t text_len_bytes = 0;
  const char *text_value = luaL_checklstring(L, 2, &text_len_bytes);
  TokenizerText text;
  tokenizer_text_init(&text, text_value, text_len_bytes);

  TokenizerState state;
  tokenizer_state_init_from_lua(L, 3, &state, true);

  TokenizerTokenBuffer tokens;

  if (incoming_syntax->pattern_count == 0) {
    tokenizer_token_buffer_init(L, &tokens);
    tokenizer_token_buffer_append(
      &tokens,
      "normal",
      1,
      (lua_Integer) text.char_len,
      tokenizer_text_is_space(text.text, text.byte_len)
    );
    tokenizer_token_buffer_to_lua(L, &tokens, &text);
    tokenizer_state_push(L, &state);
    tokenizer_state_uninit(&state);
    tokenizer_text_uninit(&text);
    return 2;
  }

  lua_Integer i = 1;
  if (lua_istable(L, 4)) {
    lua_getfield(L, 4, "res");
    int res_idx = lua_gettop(L);
    lua_getfield(L, 4, "i");
    i = luaL_checkinteger(L, -1);
    lua_pop(L, 1);
    lua_getfield(L, 4, "state");
    tokenizer_state_uninit(&state);
    tokenizer_state_init_from_lua(L, -1, &state, true);
    lua_pop(L, 1);
    tokenizer_token_buffer_init(L, &tokens);
    tokenizer_token_buffer_init_from_resume(L, &tokens, &text, res_idx);
  } else {
    tokenizer_token_buffer_init(L, &tokens);
  }

  TokenizerCursor cursor;
  tokenizer_retrieve_syntax_state(incoming_syntax, &state, &cursor);

  TokenizerFindResults find_results = {0};
  TokenizerFindResults raw_find_results = {0};
  double start_time = tokenizer_get_time();
  lua_Integer starting_i = i;
  double max_time = tokenizer_get_max_time(L);

  while ((size_t) i <= text.char_len) {
    if (text.char_len > 200 || i - starting_i > 200) {
      starting_i = i;
      if (tokenizer_get_time() - start_time > max_time) {
        tokenizer_token_buffer_push(&tokens, &text, "incomplete", i, (lua_Integer) text.char_len);
        tokenizer_token_buffer_to_lua(L, &tokens, &text);
        lua_pushliteral(L, "\0");
        lua_newtable(L);
        lua_pushvalue(L, -3);
        lua_setfield(L, -2, "res");
        lua_pushinteger(L, i);
        lua_setfield(L, -2, "i");
        tokenizer_state_push(L, &state);
        lua_setfield(L, -2, "state");
        tokenizer_find_results_uninit(&find_results);
        tokenizer_find_results_uninit(&raw_find_results);
        tokenizer_state_uninit(&state);
        tokenizer_text_uninit(&text);
        return 3;
      }
    }

    if (cursor.current_pattern_idx > 0 &&
        (size_t) cursor.current_pattern_idx <= cursor.current_syntax->pattern_count) {
      TokenizerPattern *pattern = &cursor.current_syntax->patterns[cursor.current_pattern_idx - 1];
      bool found = tokenizer_find_text(
        L, &text, pattern, i, false, true, &find_results, &raw_find_results
      );
      const char *token_type = tokenizer_pattern_type(pattern, 1);
      bool cont = true;

      if (cursor.subsyntax_info && !found) {
        TokenizerFindResults subsyntax_results = {0};
        bool sub_found = tokenizer_find_text(
          L,
          &text,
          cursor.subsyntax_info,
          i,
          false,
          true,
          &subsyntax_results,
          &raw_find_results
        );
        if (sub_found) {
          tokenizer_token_buffer_push(
            &tokens, &text, token_type, i, subsyntax_results.values[0] - 1
          );
          i = subsyntax_results.values[0];
          cont = false;
        }
        tokenizer_find_results_uninit(&subsyntax_results);
      }

      if (cont) {
        if (found) {
          if (find_results.values[0] > i) {
            tokenizer_token_buffer_push(
              &tokens, &text, token_type, i, find_results.values[0] - 1
            );
          }
          tokenizer_token_buffer_push_tokens(
            &tokens, cursor.current_syntax, pattern, &text, &find_results
          );
          cursor.current_pattern_idx = 0;
          tokenizer_state_set_pattern_idx(&state, cursor.current_level, 0);
          i = find_results.values[1] + 1;
        } else {
          tokenizer_token_buffer_push(
            &tokens, &text, token_type, i, (lua_Integer) text.char_len
          );
          break;
        }
      }
    }

    while (cursor.subsyntax_info) {
      bool found = tokenizer_find_text(
        L, &text, cursor.subsyntax_info, i, true, true, &find_results, &raw_find_results
      );
      if (!found) break;
      tokenizer_token_buffer_push_tokens(
        &tokens, cursor.current_syntax, cursor.subsyntax_info, &text, &find_results
      );
      tokenizer_pop_subsyntax(incoming_syntax, &state, &cursor);
      i = find_results.values[1] + 1;
    }

    bool matched = false;
    for (size_t n = 0; n < cursor.current_syntax->pattern_count; n++) {
      TokenizerPattern *pattern = &cursor.current_syntax->patterns[n];
      bool found = tokenizer_find_text(
        L, &text, pattern, i, true, false, &find_results, &raw_find_results
      );
      if (!found) continue;

      if (find_results.values[0] > find_results.values[1] && !pattern->has_subsyntax) {
        tokenizer_report_bad_pattern(
          L,
          cursor.current_syntax,
          pattern,
          (int) n + 1,
          "warn",
          "Pattern successfully matched, but nothing was captured."
        );
        continue;
      }

      int n_types = (int) pattern->types.count;
      if (find_results.count == 2 && n_types > 1) {
        tokenizer_report_bad_pattern(
          L,
          cursor.current_syntax,
          pattern,
          (int) n + 1,
          "warn",
          "Token type is a table, but a string was expected."
        );
      } else if (find_results.count - 1 > n_types) {
        tokenizer_report_bad_pattern(
          L,
          cursor.current_syntax,
          pattern,
          (int) n + 1,
          "error",
          "Not enough token types: got %d needed %d.",
          n_types,
          find_results.count - 1
        );
      } else if (find_results.count - 1 < n_types) {
        tokenizer_report_bad_pattern(
          L,
          cursor.current_syntax,
          pattern,
          (int) n + 1,
          "warn",
          "Too many token types: got %d needed %d.",
          n_types,
          find_results.count - 1
        );
      }

      tokenizer_token_buffer_push_tokens(
        &tokens, cursor.current_syntax, pattern, &text, &find_results
      );
      if (pattern->has_pair) {
        if (pattern->has_subsyntax && pattern->subsyntax) {
          tokenizer_push_subsyntax(&state, &cursor, pattern, (int) n + 1);
        } else {
          cursor.current_pattern_idx = (int) n + 1;
          tokenizer_state_set_pattern_idx(&state, cursor.current_level, (int) n + 1);
        }
      }
      i = find_results.values[1] + 1;
      matched = true;
      break;
    }

    if (!matched) {
      tokenizer_token_buffer_push(&tokens, &text, "normal", i, i);
      i++;
    }
  }

  tokenizer_token_buffer_to_lua(L, &tokens, &text);
  tokenizer_state_push(L, &state);
  tokenizer_find_results_uninit(&find_results);
  tokenizer_find_results_uninit(&raw_find_results);
  tokenizer_state_uninit(&state);
  tokenizer_text_uninit(&text);
  return 2;
}

int luaopen_tokenizer(lua_State *L) {
  luaL_newmetatable(L, API_TYPE_TOKENIZER_SYNTAX);
  lua_pushcfunction(L, tokenizer_syntax_gc);
  lua_setfield(L, -2, "__gc");
  lua_pop(L, 1);

  static const luaL_Reg lib[] = {
    {"tokenize", f_tokenizer_tokenize},
    {"extract_subsyntaxes", f_tokenizer_extract_subsyntaxes},
    {NULL, NULL}
  };

  luaL_newlib(L, lib);
  return 1;
}
