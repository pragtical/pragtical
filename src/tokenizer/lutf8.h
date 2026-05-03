#include <stdlib.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#ifndef utfint
  #define utfint utfint
  typedef uint32_t utfint;
#endif

typedef struct {
  const char* string;
  int64_t len;
} utf8_string_ref_t;

typedef struct {
  char* buffer;
  size_t size;
} string_buffer_t;

typedef struct {
  bool err;
  const char* errmsg;
  string_buffer_t val;
} string_buffer_result_t;

typedef struct {
  utfint* codepoints;
  size_t size;
} utfint_list_t;

typedef struct {
  bool err;
  const char* errmsg;
  utfint_list_t val;
} utfint_list_result_t;

typedef struct {
  bool err;
  const char* errmsg;
  int64_t val;
} int64_result_t;

typedef struct {
  size_t pos;
  utfint codepoint;
  size_t size;
} utf8_offset_t;

typedef struct {
  bool err;
  const char* errmsg;
  utf8_offset_t val;
} utf8_offset_result_t;

typedef struct {
  bool is_string;
  union {
    int64_t offset;
    utf8_string_ref_t string;
  } val;
} utf8_pattern_value_t;

typedef struct {
  utf8_pattern_value_t* values;
  size_t size;
} utf8_pattern_result_t;

typedef struct {
  bool err;
  const char* errmsg;
  utf8_pattern_result_t val;
} utf8_pattern_result_result_t;

typedef bool (*utf8_pattern_offset_writer_t)(void* ctx, int64_t offset);

// String buffer functions
string_buffer_t string_buffer_init();
void string_buffer_uninit(string_buffer_t* self);
void string_buffer_add(string_buffer_t* self, const char* s, size_t len);
void string_buffer_add_utf8char(string_buffer_t* self, utfint ch);

// utfint list functions
utfint_list_t utfint_list_init();
void utfint_list_uninit(utfint_list_t* self);
void utfint_list_add(utfint_list_t* self, utfint value);

// Lutf8 functions
int64_result_t Lutf8_len(const char* s, size_t len, int64_t start, int64_t end, bool lax);
string_buffer_t Lutf8_sub(const char* s, size_t len, int64_t start, int64_t end);
string_buffer_result_t Lutf8_reverse(const char* s, size_t len, bool lax);
utfint_list_t Lutf8_byte(const char* s, size_t len, int64_t start, int64_t end);
utfint_list_result_t Lutf8_codepoint(const char* s, size_t len, int64_t start, int64_t end, bool lax);
string_buffer_result_t Lutf8_char(utfint_list_t list);

utfint Lutf8_cp_lower(utfint codepoint);
utfint Lutf8_cp_upper(utfint codepoint);
utfint Lutf8_cp_title(utfint codepoint);
utfint Lutf8_cp_fold(utfint codepoint);

string_buffer_t Lutf8_str_lower(const char* s, size_t len);
string_buffer_t Lutf8_str_upper(const char* s, size_t len);
string_buffer_t Lutf8_str_title(const char* s, size_t len);
string_buffer_t Lutf8_str_fold(const char* s, size_t len);

string_buffer_result_t Lutf8_escape(const char* s, size_t len);
string_buffer_result_t Lutf8_insert(const char* s, size_t len, int64_t idx, const char* subs, size_t sublen);
string_buffer_t Lutf8_remove(const char* s, size_t len, size_t start, size_t end);
utf8_offset_t Lutf8_charpos(const char* s, size_t len, int64_t charpos, int64_t idx);
int64_result_t Lutf8_offset(const char* s, size_t len, int64_t n, int64_t idx);
utf8_offset_t Lutf8_next(const char* s, size_t len, int64_t offset, int64_t idx);
utf8_offset_result_t Lutf8_codes(const char* s, size_t len, size_t n, int strict);

int Lutf8_width_cp(utfint code, bool ambi_is_double, int default_width);
size_t Lutf8_width(const char* s, size_t len, bool ambi_is_double, int default_width);
utf8_offset_t Lutf8_widthindex(const char* s, size_t len, size_t location, int ambi_is_double, int default_width);
int Lutf8_ncasecmp(const char* s1, size_t len1, const char* s2, size_t len2);

void Lutf8_pattern_result_uninit(utf8_pattern_result_t* self);
utf8_pattern_result_result_t Lutf8_find(
  const char* s, size_t len,
  const char* pattern, size_t pattern_len,
  int64_t offset, bool plain, bool find
);
bool Lutf8_find_noalloc(
  const char* s, size_t len,
  const char* pattern, size_t pattern_len,
  int64_t offset, bool plain, bool find,
  utf8_pattern_offset_writer_t writer, void* writer_ctx,
  const char** errmsg
);
utf8_pattern_result_result_t Lutf8_match(
  const char* s, size_t len,
  const char* pattern, size_t pattern_len,
  int64_t offset
);
