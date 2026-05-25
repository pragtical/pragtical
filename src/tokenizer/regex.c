#include "regex.h"
#include "pcre2.h"

#include <stdio.h>
#include <string.h>

regex_pattern_result regex_pattern_init(const char* pattern, size_t pattern_len) {
  regex_pattern_result result = {false, NULL, {NULL, NULL, 0, NULL}};
  pcre2_code* re = NULL;

  int errornumber;
  PCRE2_SIZE erroroffset;

  re = pcre2_compile(
    (PCRE2_SPTR)pattern,
    pattern_len, PCRE2_UTF,
    &errornumber, &erroroffset, NULL
  );

  if (re == NULL) {
    result.err = true;
    result.errmsg = "syntax error encountered when compiling the regex";
    result.errornumber = errornumber;
    result.erroroffset = erroroffset;
    return result;
  }

  pcre2_jit_compile(re, PCRE2_JIT_COMPLETE);

  result.val.re = re;
  result.val.pattern = malloc(pattern_len);
  memcpy(result.val.pattern, pattern, pattern_len);
  result.val.pattern_len = pattern_len;
  result.val.match_data = NULL;

  return result;
}

void regex_pattern_uninit(regex_pattern* regex) {
  if(regex->pattern_len > 0) {
    pcre2_code_free(regex->re);
    free(regex->pattern);
    if (regex->match_data) pcre2_match_data_free(regex->match_data);
    regex->re = NULL;
    regex->pattern = NULL;
    regex->pattern_len = 0;
    regex->match_data = NULL;
  }
}

char* regex_result_get_detailed_errormsg(regex_pattern_result result) {
  const char* premsg = "regex pattern error at offset %d: %s";
  PCRE2_UCHAR postmsg[256];
  pcre2_get_error_message(result.errornumber, postmsg, sizeof(postmsg));

  char* msg = malloc(strlen(premsg) + strlen((char*)postmsg));
  sprintf(msg, premsg, (int)result.erroroffset, postmsg);
  return msg;
}

regex_find regex_find_init() {
  regex_find find = {NULL, 0};
  return find;
}

void regex_find_uninit(regex_find* self) {
  if (self->size > 0) {
    free(self->values);
    self->values = NULL;
    self->size = 0;
  }
}

void regex_find_add_offset(regex_find* self, size_t x1, size_t x2) {
  if (self->size == 0) {
    self->values = malloc(sizeof(regex_find_value));
  } else {
    self->values = realloc(self->values, sizeof(regex_find_value)*(self->size+1));
  }
  self->size++;
  size_t idx = self->size-1;
  self->values[idx].is_string = false;
  self->values[idx].offset[0] = x1;
  self->values[idx].offset[1] = x2;
  self->values[idx].string_len = 0;
}

void regex_find_add_string(regex_find* self, const char* s, size_t len) {
  if (!self->values) {
    self->values = malloc(sizeof(regex_find_value));
  } else {
    self->values = realloc(self->values, sizeof(regex_find_value)*(self->size+1));
  }
  self->size++;
  size_t idx = self->size-1;
  self->values[idx].is_string = true;
  self->values[idx].string = s;
  self->values[idx].string_len = len;
}

regex_match regex_match_init() {
  regex_match match = {NULL, 0};
  return match;
}

void regex_match_uninit(regex_match* self) {
  if (self->size > 0) {
    free(self->values);
    self->values = NULL;
    self->size = 0;
  }
}

void regex_match_add_offset(regex_match* self, size_t offset) {
  if (self->size == 0) {
    self->values = malloc(sizeof(regex_match_value));
  } else {
    self->values = realloc(self->values, sizeof(regex_match_value)*(self->size+1));
  }
  self->size++;
  size_t idx = self->size-1;
  self->values[idx].is_string = false;
  self->values[idx].offset = offset;
  self->values[idx].string_len = 0;
}

void regex_match_add_string(regex_match* self, const char* s, size_t len) {
  if (!self->values) {
    self->values = malloc(sizeof(regex_match_value));
  } else {
    self->values = realloc(self->values, sizeof(regex_match_value)*(self->size+1));
  }
  self->size++;
  size_t idx = self->size-1;
  self->values[idx].is_string = true;
  self->values[idx].string = s;
  self->values[idx].string_len = len;
}

regex_gsub regex_gsub_init() {
  regex_gsub gsub = {NULL, 0, 0};
  return gsub;
}

void regex_gsub_uninit(regex_gsub* self) {
  if (self->replacements > 0) {
    free(self->output);
    self->outputlen = 0;
    self->replacements = 0;
  }
}

static size_t regex_offset_relative(int64_t pos, size_t len) {
  if (pos < 0)
    return 1;
  else if (pos > 0)
    return pos;
  else if (pos == 0)
    return 1;
  else if (pos < -(int64_t)len)  /* inverted comparison */
    return 1;  /* clip to 1 */
  else return len + pos + 1;
}

static bool regex_write_offset(
  regex_offset_writer_t writer,
  void* writer_ctx,
  size_t offset,
  const char** errmsg
) {
  if (writer(writer_ctx, offset)) return true;
  if (errmsg) *errmsg = "failed to store regex match result";
  return false;
}

regex_find_result regex_pattern_find(
  regex_pattern* self, const char* subject, size_t subject_len,
  int64_t offset, RegexOption opts
) {
  regex_find_result result = {false, NULL, regex_find_init()};
  size_t base_offset = regex_offset_relative(offset, subject_len) - 1;
  subject_len -= base_offset;
  if (opts < 0) opts = 0;
  pcre2_match_data* md = pcre2_match_data_create_from_pattern(self->re, NULL);
  int rc = pcre2_match(self->re, (PCRE2_SPTR)&subject[base_offset], subject_len, 0, opts, md, NULL);
  if (rc < 0) {
    pcre2_match_data_free(md);
    if (rc != PCRE2_ERROR_NOMATCH) {
      result.err = true;
      result.errmsg = "regex matching error";
      // PCRE2_UCHAR buffer[120];
      // pcre2_get_error_message(rc, buffer, sizeof(buffer));
      // luaL_error(L, "regex matching error %d: %s", rc, buffer);
    }
    return result;
  }
  PCRE2_SIZE* ovector = pcre2_get_ovector_pointer(md);
  if (ovector[0] > ovector[1]) {
    /* We must guard against patterns such as /(?=.\K)/ that use \K in an
    assertion  to set the start of a match later than its end. In the editor,
    we just detect this case and give up. */
    result.err = true;
    result.errmsg = "regex matching error: \\K was used in an assertion to "
      " set the match start after its end"
    ;
    pcre2_match_data_free(md);
    return result;
  }
  int results_count = rc*2;
  if (results_count > 0)
    regex_find_add_offset(&result.val, ovector[0] + base_offset + 1, ovector[1] + base_offset);
  for (int i=2; i < results_count; i+=2) {
    if (ovector[i] == ovector[i+1])
      regex_find_add_offset(&result.val, ovector[i] + base_offset + 1, 0);
    else
      regex_find_add_string(
        &result.val,
        subject + base_offset + ovector[i],
        ovector[i+1] - ovector[i]
      );
  }
  pcre2_match_data_free(md);
  return result;
}

bool regex_pattern_find_noalloc(
  regex_pattern* self, const char* subject, size_t subject_len,
  int64_t offset, RegexOption opts,
  regex_offset_writer_t writer, void* writer_ctx,
  const char** errmsg
) {
  if (errmsg) *errmsg = NULL;
  size_t base_offset = regex_offset_relative(offset, subject_len) - 1;
  subject_len -= base_offset;
  if (opts < 0) opts = 0;
  pcre2_match_data* md = pcre2_match_data_create_from_pattern(self->re, NULL);
  int rc = pcre2_match(self->re, (PCRE2_SPTR)&subject[base_offset], subject_len, 0, opts, md, NULL);
  if (rc < 0) {
    pcre2_match_data_free(md);
    if (rc != PCRE2_ERROR_NOMATCH && errmsg) *errmsg = "regex matching error";
    return false;
  }

  PCRE2_SIZE* ovector = pcre2_get_ovector_pointer(md);
  if (ovector[0] > ovector[1]) {
    if (errmsg) {
      *errmsg = "regex matching error: \\K was used in an assertion to set the match start after its end";
    }
    pcre2_match_data_free(md);
    return false;
  }

  bool ok = regex_write_offset(writer, writer_ctx, ovector[0] + base_offset + 1, errmsg) &&
    regex_write_offset(writer, writer_ctx, ovector[1] + base_offset, errmsg);
  int results_count = rc * 2;
  for (int i = 2; ok && i < results_count; i += 2) {
    if (ovector[i] == ovector[i + 1]) {
      ok = regex_write_offset(writer, writer_ctx, ovector[i] + base_offset + 1, errmsg);
    }
  }

  pcre2_match_data_free(md);
  return ok;
}

regex_match_result regex_pattern_match(
  regex_pattern* self, const char* subject, size_t subject_len,
  int64_t offset, RegexOption opts
) {
  regex_match_result result = {false, NULL, regex_match_init()};
  size_t base_offset = regex_offset_relative(offset, subject_len) - 1;
  subject_len -= base_offset;
  if (opts < 0) opts = 0;
  pcre2_match_data* md = pcre2_match_data_create_from_pattern(self->re, NULL);
  int rc = pcre2_match(self->re, (PCRE2_SPTR)&subject[base_offset], subject_len, 0, opts, md, NULL);
  if (rc < 0) {
    pcre2_match_data_free(md);
    if (rc != PCRE2_ERROR_NOMATCH) {
      result.err = true;
      result.errmsg = "regex matching error";
      // PCRE2_UCHAR buffer[120];
      // pcre2_get_error_message(rc, buffer, sizeof(buffer));
      // luaL_error(L, "regex matching error %d: %s", rc, buffer);
    }
    return result;
  }
  PCRE2_SIZE* ovector = pcre2_get_ovector_pointer(md);
  if (ovector[0] > ovector[1]) {
    /* We must guard against patterns such as /(?=.\K)/ that use \K in an
    assertion  to set the start of a match later than its end. In the editor,
    we just detect this case and give up. */
    result.err = true;
    result.errmsg = "regex matching error: \\K was used in an assertion to "
      " set the match start after its end"
    ;
    pcre2_match_data_free(md);
    return result;
  }
  int results_count = rc*2;
  for (int i = 2; i < results_count; i+=2) {
    if (ovector[i] == ovector[i+1])
      regex_match_add_offset(&result.val, ovector[i] + base_offset + 1);
    else
      regex_match_add_string(
        &result.val,
        subject + base_offset + ovector[i],
        ovector[i+1] - ovector[i]
      );
  }
  pcre2_match_data_free(md);
  return result;
}

regex_match_result regex_pattern_gmatch(
  regex_pattern* self, const char* subject, size_t subject_len, int64_t* offset
) {
  bool found = true;
  regex_match_result result = {false, NULL, regex_match_init()};

  *offset = regex_offset_relative(
    *offset, subject_len
  ) - 1;

  if (!self->match_data) { // start a new match data state
    self->match_data = pcre2_match_data_create_from_pattern(self->re, NULL);
  } else if (offset == 0) { // clear previous state
    pcre2_match_data_free(self->match_data);
    self->match_data = pcre2_match_data_create_from_pattern(self->re, NULL);
  }

  int rc = pcre2_match(
    self->re,
    (PCRE2_SPTR)subject, subject_len,
    *offset, 0, self->match_data, NULL
  );

  if (rc < 0) {
    if (rc != PCRE2_ERROR_NOMATCH) {
      result.err = true;
      result.errmsg = "regex matching error";
      found = false;
      // PCRE2_UCHAR buffer[120];
      // pcre2_get_error_message(rc, buffer, sizeof(buffer));
      // luaL_error(L, "regex matching error %d: %s", rc, buffer);
    }
    goto clean;
  } else {
    size_t ovector_count = pcre2_get_ovector_count(self->match_data);
    if (ovector_count > 0) {
      PCRE2_SIZE* ovector = pcre2_get_ovector_pointer(self->match_data);
      if (ovector[0] > ovector[1]) {
        /* We must guard against patterns such as /(?=.\K)/ that use \K in an
        assertion  to set the start of a match later than its end. In the editor,
        we just detect this case and give up. */
        result.err = true;
        result.errmsg = "regex matching error: \\K was used in an assertion to "
          " set the match start after its end"
        ;
        found = false;
        goto clean;
      }

      int index = 0;
      if (ovector_count > 1) index = 2;

      int total_results = ovector_count * 2;
      size_t last_offset = 0;
      for (int i = index; i < total_results; i+=2) {
        if (ovector[i] == ovector[i+1])
          regex_match_add_offset(&result.val, ovector[i]+1);
        else
          regex_match_add_string(&result.val, subject+ovector[i], ovector[i+1] - ovector[i]);
        last_offset = ovector[i+1];
      }

      *offset = last_offset;

      if (last_offset >= subject_len)
        found = false;
    } else {
      found = false;
    }
  }

clean:
  if (!found) pcre2_match_data_free(self->match_data);

  return result;
}

regex_gsub_result regex_pattern_gsub(
  regex_pattern* self,
  const char* subject, size_t subject_len,
  const char* replacement, size_t replacement_len,
  int64_t limit
) {
  regex_gsub_result result = {false, NULL, {NULL, 0, 0}};

  if (limit < 0 ) limit = 0;

  pcre2_match_data* match_data = pcre2_match_data_create_from_pattern(
    self->re, NULL
  );

  size_t buffer_size = 1024;
  char *output = (char *)malloc(buffer_size);

  int options = PCRE2_SUBSTITUTE_OVERFLOW_LENGTH | PCRE2_SUBSTITUTE_EXTENDED;
  if (limit == 0) options |= PCRE2_SUBSTITUTE_GLOBAL;

  int results_count = 0;
  int limit_count = 0;
  bool done = false;
  size_t offset = 0;
  PCRE2_SIZE outlen = buffer_size;
  while (!done) {
    results_count = pcre2_substitute(
      self->re,
      (PCRE2_SPTR)subject, subject_len,
      offset, options,
      match_data, NULL,
      (PCRE2_SPTR)replacement, replacement_len,
      (PCRE2_UCHAR*)output, &outlen
    );

    if (results_count != PCRE2_ERROR_NOMEMORY || buffer_size >= outlen) {
      /* PCRE2_SUBSTITUTE_GLOBAL code path (fastest) */
      if(limit == 0) {
        done = true;
      /* non PCRE2_SUBSTITUTE_GLOBAL with limit code path (slower) */
      } else {
        size_t ovector_count = pcre2_get_ovector_count(match_data);
        if (results_count > 0 && ovector_count > 0) {
          limit_count++;
          PCRE2_SIZE* ovector = pcre2_get_ovector_pointer(match_data);
          if (outlen > subject_len) {
            offset = ovector[1] + (outlen - subject_len);
          } else {
            offset = ovector[1] - (subject_len - outlen);
          }
          if (limit_count > 1) free((char*)subject);
          if (limit_count == limit || offset-1 == outlen) {
            done = true;
            results_count = limit_count;
          } else {
            subject = output;
            subject_len = outlen;
            output = (char *)malloc(buffer_size);
            outlen = buffer_size;
          }
        } else {
          if (limit_count > 1) {
            free((char *)subject);
          }
          done = true;
          results_count = limit_count;
        }
      }
    } else {
      buffer_size = outlen;
      output = (char *)realloc(output, buffer_size);
    }
  }

  if (results_count > 0) {
    result.val.output = output;
    result.val.outputlen = outlen;
    result.val.replacements = results_count;
  } else if (results_count == 0) {
    result.val.output = (char*) subject;
    result.val.outputlen = subject_len;
    result.val.replacements = 0;
  }

  pcre2_match_data_free(match_data);

  if (results_count < 0) {
    free(output);
    result.err = true;
    result.errmsg = "regex substitute error";
    // PCRE2_UCHAR errmsg[256];
    // pcre2_get_error_message(results_count, errmsg, sizeof(errmsg));
    // return luaL_error(L, "regex substitute error: %s", errmsg);
  }

  return result;
}
