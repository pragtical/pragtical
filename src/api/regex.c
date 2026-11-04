#include "api.h"

#define PCRE2_CODE_UNIT_WIDTH 8

#include <SDL3/SDL.h>
#include <string.h>
#include <pcre2.h>
#include <stdbool.h>

typedef struct RegexContainer {
  pcre2_code* re;
  uint32_t capture_count;
  uint32_t min_length;
} RegexContainer;

/* Temporary PCRE2 allocations are owned by the calling C stack frame. */
typedef struct RegexState {
  pcre2_code* re;
  pcre2_match_data* match_data;
  /* Owned heap buffers only; stack scratch buffers remain local. */
  char *output;
  char *subject_buffer;
  bool regex_compiled;
} RegexState;

SDL_FORCE_INLINE void regex_state_free(RegexState *state) {
  if (state->regex_compiled) pcre2_code_free(state->re);
  pcre2_match_data_free(state->match_data);
  if (state->output) SDL_free(state->output);
  if (state->subject_buffer) SDL_free(state->subject_buffer);
}

typedef struct RegexResults {
  const char *subject;
  PCRE2_SIZE *ovector;
  size_t offset;
  int count;
  bool find;
  bool whole;
  bool empty_positions;
  lua_Integer replacements;
  bool substitution;
} RegexResults;

static int regex_prepare_results(lua_State *L, RegexResults *results) {
  /* LuaJIT can allocate when encoding a new lightuserdata address segment.
   * Prepare this borrowed pointer before acquiring any native resources. */
  lua_pushlightuserdata(L, results);
  return lua_gettop(L);
}

/* String creation can raise an allocation error. Protect only that step so
 * the caller can release native buffers before propagating the Lua error. */
SDL_FORCE_INLINE int regex_push_values(lua_State *L, RegexResults *results) {
  if (results->substitution) {
    lua_pushlstring(L, results->subject, results->offset);
    lua_pushinteger(L, results->replacements);
    return 2;
  }
  if (results->count * 2 > LUA_MINSTACK)
    luaL_checkstack(L, results->count * 2, "too many regex captures");
  int total = 0;
  if (results->find) {
    lua_pushinteger(L, results->ovector[0] + results->offset + 1);
    lua_pushinteger(L, results->ovector[1] + results->offset);
    total = 2;
  }
  int first = results->whole ? 0 : 2;
  for (int i = first; i < results->count * 2; i += 2) {
    PCRE2_SIZE start = results->ovector[i], end = results->ovector[i+1];
    if (start == end && (!results->whole || results->empty_positions))
      lua_pushinteger(L, start + results->offset + 1);
    else
      lua_pushlstring(L, results->subject + start, end - start);
    total++;
  }
  return total;
}

static int regex_push_results(lua_State *L) {
  return regex_push_values(L, lua_touserdata(L, 1));
}

/* Keep the larger scratch frame out of the common numeric/scalar paths. */
static int regex_return_results(lua_State *L, RegexState *state,
  RegexResults *results, int results_idx, int helper
) {
  union {
    PCRE2_SIZE offsets[64];
    char output[1024];
  } scratch;
  /* Small results fit on the native stack. Release PCRE2/output allocations
   * before creating Lua strings, so allocation errors need no GC cleanup. */
  if (results->substitution && results->offset <= sizeof(scratch.output)) {
    memcpy(scratch.output, results->subject, results->offset);
    results->subject = scratch.output;
    regex_state_free(state);
    return regex_push_values(L, results);
  }
  if (!results->substitution && results->count <= 32) {
    memcpy(scratch.offsets, results->ovector, results->count * 2 * sizeof(PCRE2_SIZE));
    results->ovector = scratch.offsets;
    regex_state_free(state);
    return regex_push_values(L, results);
  }

  /* Large results remain native until the protected copy finishes. */
  int top = lua_gettop(L);
  lua_pushvalue(L, helper);
  lua_pushvalue(L, results_idx);
  int status = lua_pcall(L, 1, LUA_MULTRET, 0);
  regex_state_free(state);
  if (status != LUA_OK) return lua_error(L);
  return lua_gettop(L) - top;
}

static pcre2_code* regex_get_pattern(lua_State *L, RegexState *state) {
  pcre2_code* re = NULL;

  if (lua_type(L, 1) == LUA_TUSERDATA) {
    RegexContainer* self = (RegexContainer*)luaL_checkudata(L, 1, API_TYPE_REGEX);
    re = self->re;
    luaL_argcheck(L, re != NULL, 1, "closed regex");
  } else {
    int errornumber;
    PCRE2_SIZE erroroffset;
    size_t pattern_len = 0;
    const char* pattern = luaL_checklstring(L, 1, &pattern_len);

    re = pcre2_compile(
      (PCRE2_SPTR)pattern,
      pattern_len, PCRE2_UTF,
      &errornumber, &erroroffset, NULL
    );

    if (re == NULL) {
      PCRE2_UCHAR errmsg[256];
      pcre2_get_error_message(errornumber, errmsg, sizeof(errmsg));
      luaL_error(
        L, "regex pattern error at offset %d: %s",
        (int)erroroffset, errmsg
      );
      return NULL;
    }

    state->re = re;
    state->regex_compiled = true;
    pcre2_jit_compile(re, PCRE2_JIT_COMPLETE);
  }

  return re;
}

static int regex_gmatch_iterator(lua_State *L) {
#if LUA_VERSION_NUM == 501
  /* This private upvalue is already an integer; bypass the 5.3 conversion shim. */
  lua_Integer position = (lua_tointeger)(L, lua_upvalueindex(3));
#else
  lua_Integer position = lua_tointeger(L, lua_upvalueindex(3));
#endif
  if (position == -1) return 0;
  /* -(offset + 2) records validated UTF-8; -1 marks an exhausted iterator. */
  bool validated = position < -1;
  size_t offset = validated ? -(position + 2) : position;
  RegexContainer *pattern = lua_touserdata(L, lua_upvalueindex(1));
  if (!pattern->re) return luaL_error(L, "closed regex");
  size_t len;
  const char *subject = lua_tolstring(L, lua_upvalueindex(2), &len);
  if (validated && offset < len && ((unsigned char)subject[offset] & 0xc0) == 0x80) {
    lua_pushinteger(L, -1);
    lua_replace(L, lua_upvalueindex(3));
    return luaL_error(L, "regex matching error %d: invalid UTF-8 offset", PCRE2_ERROR_BADUTFOFFSET);
  }
  RegexResults results;
  int results_idx = pattern->capture_count >= 32 ? regex_prepare_results(L, &results) : 0;
  RegexState state = {0};
  state.match_data = pcre2_match_data_create_from_pattern(pattern->re, NULL);
  if (!state.match_data) {
    lua_pushinteger(L, -1);
    lua_replace(L, lua_upvalueindex(3));
    return luaL_error(L, "regex match allocation failed");
  }
  int rc = pcre2_match(pattern->re, (PCRE2_SPTR)subject,
    len, offset, validated ? PCRE2_NO_UTF_CHECK : 0, state.match_data, NULL);
  if (rc < 0) {
    regex_state_free(&state);
    lua_pushinteger(L, -1);
    lua_replace(L, lua_upvalueindex(3));
    if (rc == PCRE2_ERROR_NOMATCH) return 0;
    PCRE2_UCHAR buffer[120];
    pcre2_get_error_message(rc, buffer, sizeof(buffer));
    return luaL_error(L, "regex matching error %d: %s", rc, buffer);
  }
  PCRE2_SIZE *ovector = pcre2_get_ovector_pointer(state.match_data);
  if (ovector[0] > ovector[1]) {
    regex_state_free(&state);
    lua_pushinteger(L, -1);
    lua_replace(L, lua_upvalueindex(3));
    return luaL_error(L, "regex matching error: invalid match bounds");
  }
  size_t next = ovector[1];
  /* A positive minimum length rules out another match at end-of-input. */
  bool finished = next == len && pattern->min_length != 0;
  if (ovector[0] == ovector[1]) {
    if (next == len) finished = true;
    else {
      do { next++; }
      while (next < len && ((unsigned char)subject[next] & 0xc0) == 0x80);
    }
  }
  /* The compiled pattern already records the common small capture count. */
  int count = pattern->capture_count < 32 ? pattern->capture_count + 1
    : pcre2_get_ovector_count(state.match_data);
  /* Update the scalar cursor once, before Lua result creation can fail. */
  if (finished) lua_pushinteger(L, -1);
  else if (next <= INT_MAX - 2) lua_pushinteger(L, -(lua_Integer)next - 2);
  else lua_pushinteger(L, next);
  lua_replace(L, lua_upvalueindex(3));
  if (count <= 2) {
    int first = count == 1 ? 0 : 2;
    size_t start = ovector[first], end = ovector[first + 1];
    regex_state_free(&state);
    if (start == end) lua_pushinteger(L, start + 1);
    else lua_pushlstring(L, subject + start, end - start);
    return 1;
  }
  results = (RegexResults){
    .subject = subject, .ovector = ovector, .count = count,
    .empty_positions = true
  };
  return regex_return_results(L, &state, &results, results_idx, lua_upvalueindex(4));
}

static size_t regex_offset_relative(lua_Integer pos, size_t len) {
  if (pos > 0)
    return (size_t)pos;
  else if (pos == 0)
    return 1;
  else if (pos < -(lua_Integer)len)
    return 1;  /* clip to 1 */
  else return (size_t)((lua_Integer)len + pos + 1);
}

static int f_pcre_gc(lua_State* L) {
  RegexContainer* self = (RegexContainer*)luaL_checkudata(L, 1, API_TYPE_REGEX);
  if (self->re)
    pcre2_code_free(self->re);
  self->re = NULL;
  return 0;
}

static int f_pcre_compile(lua_State *L) {
  size_t len;
  PCRE2_SIZE errorOffset;
  int errorNumber;
  uint32_t pattern = PCRE2_UTF;
  const char* str = luaL_checklstring(L, 1, &len);
  if (lua_gettop(L) > 1) {
    const char* options = luaL_checkstring(L, 2);
    if (strstr(options,"i"))
      pattern |= PCRE2_CASELESS;
    if (strstr(options,"m"))
      pattern |= PCRE2_MULTILINE;
    if (strstr(options,"s"))
      pattern |= PCRE2_DOTALL;
  }
  RegexContainer* self = lua_newuserdata(L, sizeof(*self));
  self->re = NULL;
  luaL_setmetatable(L, API_TYPE_REGEX);
  pcre2_code* re = pcre2_compile(
    (PCRE2_SPTR)str,
    len,
    pattern,
    &errorNumber,
    &errorOffset,
    NULL
  );
  if (re) {
    self->re = re;
    pcre2_pattern_info(re, PCRE2_INFO_CAPTURECOUNT, &self->capture_count);
    pcre2_pattern_info(re, PCRE2_INFO_MINLENGTH, &self->min_length);
    pcre2_jit_compile(re, PCRE2_JIT_COMPLETE);
    return 1;
  }
  PCRE2_UCHAR buffer[256];
  pcre2_get_error_message(errorNumber, buffer, sizeof(buffer));
  lua_pushnil(L);
  char message[1024];
  len = snprintf(message, sizeof(message), "regex compilation failed at offset %d: %s", (int)errorOffset, buffer);
  lua_pushlstring(L, message, len);
  return 2;
}

// Takes string, compiled regex, returns list of indices of matched groups
// (including the whole match), if a match was found.
static int f_pcre_cmatch(lua_State *L) {
  /* subject param */
  size_t subject_len = 0;
  const char* subject = luaL_checklstring(L, 2, &subject_len);
  /* offset param */
  size_t offset = regex_offset_relative(
    luaL_optinteger(L, 3, 1), subject_len
  ) - 1;
  /* options param */
  uint32_t opts = luaL_optinteger(L, 4, 0);
  RegexState storage = {0};
  RegexState *state = &storage;
  pcre2_code *re = regex_get_pattern(L, state);
  int total_results = 0;
  if (offset > subject_len) {
    regex_state_free(state);
    return 0;
  }
  subject_len -= offset;
  pcre2_match_data* md = state->match_data = pcre2_match_data_create_from_pattern(re, NULL);
  if (!md) {
    regex_state_free(state);
    return luaL_error(L, "regex match allocation failed");
  }
  int rc = pcre2_match(re, (PCRE2_SPTR)&subject[offset], subject_len, 0, opts, md, NULL);
  if (rc <= 0) {
    if (rc < 0 && rc != PCRE2_ERROR_NOMATCH) {
      PCRE2_UCHAR buffer[120];
      pcre2_get_error_message(rc, buffer, sizeof(buffer));
      regex_state_free(state);
      return luaL_error(L, "regex matching error %d: %s", rc, buffer);
    }
    goto clean;
  }
  if (rc * 2 > LUA_MINSTACK && !lua_checkstack(L, rc * 2)) {
    regex_state_free(state);
    return luaL_error(L, "too many regex captures");
  }
  PCRE2_SIZE* ovector = pcre2_get_ovector_pointer(md);
  if (ovector[0] > ovector[1]) {
    /* We must guard against patterns such as /(?=.\K)/ that use \K in an
    assertion  to set the start of a match later than its end. In the editor,
    we just detect this case and give up. */
    regex_state_free(state);
    return luaL_error(L, "regex matching error: \\K was used in an assertion to "
    " set the match start after its end");
  }
  total_results = rc*2;
  for (int i = 0; i < total_results; i++)
    lua_pushinteger(L, ovector[i]+offset+1);

clean:
  regex_state_free(state);

  return total_results;
}

static int f_pcre_find(lua_State *L) {
  RegexContainer *compiled = lua_type(L, 1) == LUA_TUSERDATA
    ? luaL_checkudata(L, 1, API_TYPE_REGEX) : NULL;
  /* subject param */
  size_t subject_len = 0;
  const char* subject = luaL_checklstring(L, 2, &subject_len);
  /* offset param */
  size_t offset = regex_offset_relative(
    luaL_optinteger(L, 3, 1), subject_len
  ) - 1;
  /* options param */
  uint32_t opts = luaL_optinteger(L, 4, 0);
  RegexResults results;
  int results_idx = 0;
  RegexState storage = {0};
  RegexState *state = &storage;
  pcre2_code *re;
  if (compiled) {
    luaL_argcheck(L, compiled->re != NULL, 1, "closed regex");
    re = compiled->re;
    if (compiled->capture_count >= 32)
      results_idx = regex_prepare_results(L, &results);
  } else {
    results_idx = regex_prepare_results(L, &results);
    re = regex_get_pattern(L, state);
  }
  int total_results = 0;
  if (offset > subject_len) {
    regex_state_free(state);
    return 0;
  }
  subject_len -= offset;
  pcre2_match_data* md = state->match_data = pcre2_match_data_create_from_pattern(re, NULL);
  if (!md) {
    regex_state_free(state);
    return luaL_error(L, "regex match allocation failed");
  }
  int rc = pcre2_match(re, (PCRE2_SPTR)&subject[offset], subject_len, 0, opts, md, NULL);
  if (rc <= 0) {
    if (rc < 0 && rc != PCRE2_ERROR_NOMATCH) {
      PCRE2_UCHAR buffer[120];
      pcre2_get_error_message(rc, buffer, sizeof(buffer));
      regex_state_free(state);
      return luaL_error(L, "regex matching error %d: %s", rc, buffer);
    }
    goto clean;
  }
  if (rc * 2 > LUA_MINSTACK && !lua_checkstack(L, rc * 2)) {
    regex_state_free(state);
    return luaL_error(L, "too many regex captures");
  }
  PCRE2_SIZE* ovector = pcre2_get_ovector_pointer(md);
  if (ovector[0] > ovector[1]) {
    /* We must guard against patterns such as /(?=.\K)/ that use \K in an
    assertion  to set the start of a match later than its end. In the editor,
    we just detect this case and give up. */
    regex_state_free(state);
    return luaL_error(L, "regex matching error: \\K was used in an assertion to "
    " set the match start after its end");
  }
  if (rc > 1) {
    results = (RegexResults){
      .subject = subject + offset, .ovector = ovector, .offset = offset,
      .count = rc, .find = true
    };
    return regex_return_results(L, state, &results, results_idx, lua_upvalueindex(1));
  }
  lua_pushinteger(L, ovector[0] + offset + 1);
  lua_pushinteger(L, ovector[1] + offset);
  total_results = 2;

clean:
  regex_state_free(state);

  return total_results;
}

static int f_pcre_find_offsets(lua_State *L) {
  /* subject param */
  size_t subject_len = 0;
  const char* subject = luaL_checklstring(L, 2, &subject_len);
  /* offset param */
  size_t offset = regex_offset_relative(
    luaL_optinteger(L, 3, 1), subject_len
  ) - 1;
  /* options param */
  uint32_t opts = luaL_optinteger(L, 4, 0);
  RegexState storage = {0};
  RegexState *state = &storage;
  pcre2_code *re = regex_get_pattern(L, state);
  int total_results = 0;
  if (offset > subject_len) {
    regex_state_free(state);
    return 0;
  }
  subject_len -= offset;
  pcre2_match_data* md = state->match_data = pcre2_match_data_create_from_pattern(re, NULL);
  if (!md) {
    regex_state_free(state);
    return luaL_error(L, "regex match allocation failed");
  }
  int rc = pcre2_match(re, (PCRE2_SPTR)&subject[offset], subject_len, 0, opts, md, NULL);
  if (rc <= 0) {
    if (rc < 0 && rc != PCRE2_ERROR_NOMATCH) {
      PCRE2_UCHAR buffer[120];
      pcre2_get_error_message(rc, buffer, sizeof(buffer));
      regex_state_free(state);
      return luaL_error(L, "regex matching error %d: %s", rc, buffer);
    }
    goto clean;
  }
  if (rc * 2 > LUA_MINSTACK && !lua_checkstack(L, rc * 2)) {
    regex_state_free(state);
    return luaL_error(L, "too many regex captures");
  }
  PCRE2_SIZE* ovector = pcre2_get_ovector_pointer(md);
  if (ovector[0] > ovector[1]) {
    /* We must guard against patterns such as /(?=.\K)/ that use \K in an
    assertion  to set the start of a match later than its end. In the editor,
    we just detect this case and give up. */
    regex_state_free(state);
    return luaL_error(L, "regex matching error: \\K was used in an assertion to "
    " set the match start after its end");
  }
  total_results = rc*2;
  if (total_results > 0) {
    lua_pushinteger(L, ovector[0]+offset+1);
    lua_pushinteger(L, ovector[1]+offset+1);
  }
  for (int i = 2; i < total_results; i+=2) {
    lua_pushinteger(L, ovector[i]+offset+1);
    lua_pushinteger(L, ovector[i+1]+offset);
  }

clean:
  regex_state_free(state);

  return total_results;
}

static int f_pcre_gmatch(lua_State *L) {
  size_t len;
  luaL_checklstring(L, 2, &len);
  size_t offset = regex_offset_relative(luaL_optinteger(L, 3, 1), len) - 1;
  lua_settop(L, 3);
  if (lua_type(L, 1) != LUA_TUSERDATA) {
    luaL_checkstring(L, 1);
    /* Reuse the ordinary compiled-pattern object, not a temporary GC owner. */
    RegexContainer *pattern = lua_newuserdata(L, sizeof(*pattern));
    pattern->re = NULL;
    luaL_setmetatable(L, API_TYPE_REGEX);
    RegexState state = {0};
    pattern->re = regex_get_pattern(L, &state);
    pcre2_pattern_info(pattern->re, PCRE2_INFO_CAPTURECOUNT, &pattern->capture_count);
    pcre2_pattern_info(pattern->re, PCRE2_INFO_MINLENGTH, &pattern->min_length);
    lua_replace(L, 1);
  } else {
    RegexContainer *pattern = luaL_checkudata(L, 1, API_TYPE_REGEX);
    luaL_argcheck(L, pattern->re != NULL, 1, "closed regex");
  }
  if (offset > len) lua_pushinteger(L, -1);
  else lua_pushinteger(L, offset);
  lua_replace(L, 3);
  /* Only the pattern, subject and next offset survive between calls. */
  lua_pushvalue(L, lua_upvalueindex(1));
  lua_pushcclosure(L, regex_gmatch_iterator, 4);
  return 1;
}

static int f_pcre_gsub(lua_State *L) {
  size_t subject_len, replacement_len;
  const char *subject = luaL_checklstring(L, 2, &subject_len);
  const char *replacement = luaL_checklstring(L, 3, &replacement_len);
  lua_Integer limit = luaL_optinteger(L, 4, 0);
  if (limit < 0) limit = 0;
  RegexResults results;
  int results_idx = regex_prepare_results(L, &results);
  RegexState storage = {0};
  RegexState *state = &storage;
  pcre2_code *re = regex_get_pattern(L, state);
  state->match_data = pcre2_match_data_create_from_pattern(re, NULL);
  if (!state->match_data) {
    regex_state_free(state);
    return luaL_error(L, "regex match allocation failed");
  }

  /* Alternate small native buffers; larger results grow on the heap. */
  char buffers[2][256];
  size_t capacity = sizeof(buffers[0]), offset = 0;
  lua_Integer total = 0;
  uint32_t options = PCRE2_SUBSTITUTE_OVERFLOW_LENGTH | PCRE2_SUBSTITUTE_EXTENDED;
  if (limit == 0) options |= PCRE2_SUBSTITUTE_GLOBAL;
  char *output = buffers[0];

  while (true) {
    PCRE2_SIZE outlen = capacity;
    int rc = pcre2_substitute(re, (PCRE2_SPTR)subject, subject_len,
      offset, options, state->match_data, NULL, (PCRE2_SPTR)replacement,
      replacement_len, (PCRE2_UCHAR*)output, &outlen);
    if (rc == PCRE2_ERROR_NOMEMORY && outlen > capacity) {
      char *grown = state->output ? SDL_realloc(state->output, outlen) : SDL_malloc(outlen);
      if (!grown) {
        regex_state_free(state);
        return luaL_error(L, "regex output allocation failed");
      }
      output = state->output = grown;
      capacity = outlen;
      continue;
    }
    if (rc < 0) {
      PCRE2_UCHAR errmsg[256];
      pcre2_get_error_message(rc, errmsg, sizeof(errmsg));
      regex_state_free(state);
      return luaL_error(L, "regex substitute error: %s", errmsg);
    }
    total += rc;
    if (rc == 0 || limit == 0 || total == limit) {
      if (!state->output) {
        regex_state_free(state);
        lua_pushlstring(L, output, outlen);
        lua_pushinteger(L, total);
        return 2;
      }
      results = (RegexResults){
        .subject = state->output, .offset = outlen,
        .replacements = total, .substitution = true
      };
      return regex_return_results(L, state, &results, results_idx, lua_upvalueindex(1));
    }

    PCRE2_SIZE *ovector = pcre2_get_ovector_pointer(state->match_data);
    offset = outlen - (subject_len - ovector[1]);
    if (ovector[0] == ovector[1]) {
      if (offset == outlen) {
        if (!state->output) {
          regex_state_free(state);
          lua_pushlstring(L, output, outlen);
          lua_pushinteger(L, total);
          return 2;
        }
        results = (RegexResults){
          .subject = state->output, .offset = outlen,
          .replacements = total, .substitution = true
        };
        return regex_return_results(L, state, &results, results_idx, lua_upvalueindex(1));
      }
      do { offset++; }
      while (offset < outlen && ((unsigned char)output[offset] & 0xc0) == 0x80);
    }
    SDL_free(state->subject_buffer);
    state->subject_buffer = state->output;
    subject = output;
    subject_len = outlen;
    state->output = NULL;
    output = output == buffers[0] ? buffers[1] : buffers[0];
    capacity = sizeof(buffers[0]);
  }
}

/* Short ASCII subjects are trivially valid UTF-8. Check whole words instead
 * of having PCRE2 validate the same bytes one at a time. */
SDL_FORCE_INLINE uint32_t regex_match_options(const char *subject, size_t len, uint32_t options) {
  if (len > 64 || (options & PCRE2_NO_UTF_CHECK)) return options;
  while (len >= sizeof(Uint64)) {
    Uint64 bytes;
    memcpy(&bytes, subject, sizeof(bytes));
    if (bytes & UINT64_C(0x8080808080808080)) return options;
    subject += sizeof(bytes);
    len -= sizeof(bytes);
  }
  while (len--) if ((unsigned char)*subject++ >= 0x80) return options;
  return options | PCRE2_NO_UTF_CHECK;
}

static int f_pcre_match(lua_State *L) {
  RegexContainer *compiled = lua_type(L, 1) == LUA_TUSERDATA
    ? luaL_checkudata(L, 1, API_TYPE_REGEX) : NULL;
  /* subject param */
  size_t subject_len = 0;
  const char* subject = luaL_checklstring(L, 2, &subject_len);
  /* offset param */
  size_t offset = regex_offset_relative(
    luaL_optinteger(L, 3, 1), subject_len
  ) - 1;
  /* options param */
  uint32_t opts = luaL_optinteger(L, 4, 0);
  RegexResults results;
  int results_idx = 0;
  RegexState storage = {0};
  RegexState *state = &storage;
  pcre2_code *re;
  if (compiled) {
    luaL_argcheck(L, compiled->re != NULL, 1, "closed regex");
    re = compiled->re;
    if (compiled->capture_count >= 32)
      results_idx = regex_prepare_results(L, &results);
  } else {
    results_idx = regex_prepare_results(L, &results);
    re = regex_get_pattern(L, state);
  }
  int total_results = 0;
  if (offset > subject_len) {
    regex_state_free(state);
    return 0;
  }
  subject_len -= offset;
  pcre2_match_data* md = state->match_data = pcre2_match_data_create_from_pattern(re, NULL);
  if (!md) {
    regex_state_free(state);
    return luaL_error(L, "regex match allocation failed");
  }
  opts = regex_match_options(subject + offset, subject_len, opts);
  int rc = pcre2_match(re, (PCRE2_SPTR)&subject[offset], subject_len, 0, opts, md, NULL);
  if (rc <= 0) {
    if (rc < 0 && rc != PCRE2_ERROR_NOMATCH) {
      PCRE2_UCHAR buffer[120];
      pcre2_get_error_message(rc, buffer, sizeof(buffer));
      regex_state_free(state);
      return luaL_error(L, "regex matching error %d: %s", rc, buffer);
    }
    goto clean;
  }
  if (rc * 2 > LUA_MINSTACK && !lua_checkstack(L, rc * 2)) {
    regex_state_free(state);
    return luaL_error(L, "too many regex captures");
  }
  PCRE2_SIZE* ovector = pcre2_get_ovector_pointer(md);
  if (ovector[0] > ovector[1]) {
    /* We must guard against patterns such as /(?=.\K)/ that use \K in an
    assertion  to set the start of a match later than its end. In the editor,
    we just detect this case and give up. */
    regex_state_free(state);
    return luaL_error(L, "regex matching error: \\K was used in an assertion to "
    " set the match start after its end");
  }
  if (rc <= 3) {
    int first = rc == 1 ? 0 : 2;
    size_t start = ovector[first], end = ovector[first + 1];
    size_t second_start = rc == 3 ? ovector[4] : 0;
    size_t second_end = rc == 3 ? ovector[5] : 0;
    regex_state_free(state);
    if (rc == 1 || start != end)
      lua_pushlstring(L, subject + offset + start, end - start);
    else lua_pushinteger(L, start + offset + 1);
    if (rc == 3) {
      if (second_start == second_end) lua_pushinteger(L, second_start + offset + 1);
      else lua_pushlstring(L, subject + offset + second_start, second_end - second_start);
    }
    return rc == 1 ? 1 : rc - 1;
  }
  results = (RegexResults){
    .subject = subject + offset, .ovector = ovector, .offset = offset,
    .count = rc, .whole = rc == 1
  };
  return regex_return_results(L, state, &results, results_idx, lua_upvalueindex(1));

clean:
  regex_state_free(state);

  return total_results;
}

static const struct luaL_Reg regex_lib[] = {
  { "compile",      f_pcre_compile },
  { "cmatch",       f_pcre_cmatch },
  { "find",         f_pcre_find },
  { "find_offsets", f_pcre_find_offsets },
  { "gmatch",       f_pcre_gmatch },
  { "gsub",         f_pcre_gsub },
  { "match",        f_pcre_match },
  {NULL, NULL}
};

static const struct luaL_Reg regex_object[] = {
  { "cmatch",       f_pcre_cmatch },
  { "find",         f_pcre_find },
  { "find_offsets", f_pcre_find_offsets },
  { "gmatch",       f_pcre_gmatch },
  { "gsub",         f_pcre_gsub },
  { "match",        f_pcre_match },
  { "__gc",         f_pcre_gc },
  {NULL, NULL}
};

int luaopen_regex(lua_State *L) {
  luaL_newmetatable(L, API_TYPE_REGEX);
  lua_pushcfunction(L, regex_push_results);
  luaL_setfuncs(L, regex_object, 1);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");

  luaL_newlibtable(L, regex_lib);
  lua_pushcfunction(L, regex_push_results);
  luaL_setfuncs(L, regex_lib, 1);

  lua_pushinteger(L, PCRE2_ANCHORED);
  lua_setfield(L, -2, "ANCHORED");
  lua_pushinteger(L, PCRE2_ENDANCHORED) ;
  lua_setfield(L, -2, "ENDANCHORED");
  lua_pushinteger(L, PCRE2_NOTBOL);
  lua_setfield(L, -2, "NOTBOL");
  lua_pushinteger(L, PCRE2_NOTEOL);
  lua_setfield(L, -2, "NOTEOL");
  lua_pushinteger(L, PCRE2_NOTEMPTY);
  lua_setfield(L, -2, "NOTEMPTY");
  lua_pushinteger(L, PCRE2_NOTEMPTY_ATSTART);
  lua_setfield(L, -2, "NOTEMPTY_ATSTART");
  return 1;
}
