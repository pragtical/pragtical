#include <stddef.h>
#include <stdbool.h>

#define PCRE2_CODE_UNIT_WIDTH 8
#include <pcre2.h>

typedef struct {
  pcre2_code* re;
  char* pattern;
  size_t pattern_len;
  pcre2_match_data* match_data;
} regex_pattern;

typedef struct {
  bool err;
  const char* errmsg;
  regex_pattern val;
  int errornumber;
  PCRE2_SIZE erroroffset;
} regex_pattern_result;

typedef struct {
  size_t offset[2];
  bool is_string;
  const char* string;
  size_t string_len;
} regex_find_value;

typedef struct {
  regex_find_value* values;
  size_t size;
} regex_find;

typedef struct {
  bool err;
  const char* errmsg;
  regex_find val;
} regex_find_result;

typedef bool (*regex_offset_writer_t)(void* ctx, size_t offset);

typedef struct {
  size_t offset;
  bool is_string;
  const char* string;
  size_t string_len;
} regex_match_value;

typedef struct {
  regex_match_value* values;
  size_t size;
} regex_match;

typedef struct {
  bool err;
  const char* errmsg;
  regex_match val;
} regex_match_result;

typedef struct {
  char* output;
  size_t outputlen;
  size_t replacements;
} regex_gsub;

typedef struct {
  bool err;
  const char* errmsg;
  regex_gsub val;
} regex_gsub_result;

typedef enum {
  REGEX_OPTION_ANCHORED = PCRE2_ANCHORED,
  REGEX_OPTION_ENDANCHORED = PCRE2_ENDANCHORED,
  REGEX_OPTION_NOTBOL = PCRE2_NOTBOL,
  REGEX_OPTION_NOTEOL = PCRE2_NOTEOL,
  REGEX_OPTION_NOTEMPTY = PCRE2_NOTEMPTY,
  REGEX_OPTION_NOTEMPTY_ATSTART = PCRE2_NOTEMPTY_ATSTART
} RegexOption;

regex_pattern_result regex_pattern_init(const char* pattern, size_t pattern_len);
void regex_pattern_uninit(regex_pattern* regex);
char* regex_result_get_detailed_errormsg(regex_pattern_result result);

regex_find regex_find_init();
void regex_find_uninit(regex_find* self);
void regex_find_add_offset(regex_find* self, size_t x1, size_t x2);
void regex_find_add_string(regex_find* self, const char* s, size_t len);

regex_match regex_match_init();
void regex_match_uninit(regex_match* self);
void regex_match_add_offset(regex_match* self, size_t offset);
void regex_match_add_string(regex_match* self, const char* s, size_t len);

regex_gsub regex_gsub_init();
void regex_gsub_uninit(regex_gsub* self);

regex_find_result regex_pattern_find(
  regex_pattern* self,
  const char* subject, size_t subject_len,
  int64_t offset, RegexOption opts
);
bool regex_pattern_find_noalloc(
  regex_pattern* self,
  const char* subject, size_t subject_len,
  int64_t offset, RegexOption opts,
  regex_offset_writer_t writer, void* writer_ctx,
  const char** errmsg
);

regex_match_result regex_pattern_match(
  regex_pattern* self,
  const char* subject, size_t subject_len,
  int64_t offset, RegexOption opts
);

regex_match_result regex_pattern_gmatch(
  regex_pattern* self, const char* subject, size_t subject_len, int64_t* offset
);

regex_gsub_result regex_pattern_gsub(
  regex_pattern* self,
  const char* subject, size_t subject_len,
  const char* replacement, size_t replacement_len,
  int64_t limit
);
