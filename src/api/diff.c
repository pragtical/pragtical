#include <string.h>
#include <stdlib.h>
#include <math.h>
#include "api.h"


typedef struct {
  int i, j;
} Pair;

typedef struct {
  Pair *pairs;
  int npairs;
  int ai, bi, pi;
  int lenA, lenB;
} DiffState;


static double similarity(const char *a, const char *b) {
  if (strcmp(a, b) == 0) return 1.0;
  int m = (int)strlen(a), n = (int)strlen(b);
  if (m == 0 || n == 0) return 0.0;

  int *prev = calloc(n+1, sizeof(int));
  int *curr = calloc(n+1, sizeof(int));

  for (int i = 1; i <= m; i++) {
    for (int j = 1; j <= n; j++) {
      if (a[i-1] == b[j-1])
        curr[j] = prev[j-1] + 1;
      else
        curr[j] = (prev[j] > curr[j-1]) ? prev[j] : curr[j-1];
    }
    int *tmp = prev; prev = curr; curr = tmp;
  }
  int lcs_len = prev[n];
  free(prev);
  free(curr);
  return (double)lcs_len / (m > n ? m : n);
}


static Pair *build_lcs(lua_State *L, int Aidx, int Bidx, int *npairs, double threshold) {
  int n = (int)lua_rawlen(L, Aidx);
  int m = (int)lua_rawlen(L, Bidx);

  double **sim = malloc((n+1) * sizeof(double*));
  double **dp = malloc((n+1) * sizeof(double*));
  for (int i = 0; i <= n; i++) {
    sim[i] = calloc(m+1, sizeof(double));
    dp[i] = calloc(m+1, sizeof(double));
  }

  for (int i = 1; i <= n; i++) {
    lua_rawgeti(L, Aidx, i);
    const char *a = lua_tostring(L, -1);
    for (int j = 1; j <= m; j++) {
      lua_rawgeti(L, Bidx, j);
      const char *b = lua_tostring(L, -1);
      double s = similarity(a, b);
      sim[i][j] = (s >= threshold) ? s : 0.0;
      lua_pop(L, 1);
    }
    lua_pop(L, 1);
  }

  for (int i = 1; i <= n; i++) {
    for (int j = 1; j <= m; j++) {
      if (sim[i][j] > 0)
        dp[i][j] = dp[i-1][j-1] + sim[i][j];
      else
        dp[i][j] = fmax(dp[i-1][j], dp[i][j-1]);
    }
  }

  Pair *pairs = malloc((n + m) * sizeof(Pair));
  int count = 0;
  int i = n, j = m;
  while (i > 0 && j > 0) {
    if (sim[i][j] > 0 && fabs(dp[i][j] - (dp[i-1][j-1] + sim[i][j])) < 1e-9) {
      pairs[count++] = (Pair){i, j};
      i--; j--;
    } else if (dp[i-1][j] >= dp[i][j-1]) {
      i--;
    } else {
      j--;
    }
  }

  // Reverse pairs
  for (int k = 0; k < count / 2; k++) {
    Pair tmp = pairs[k];
    pairs[k] = pairs[count - k - 1];
    pairs[count - k - 1] = tmp;
  }

  for (int i = 0; i <= n; i++) {
    free(sim[i]); free(dp[i]);
  }
  free(sim); free(dp);

  *npairs = count;
  return pairs;
}


static void push_edit(lua_State *L, const char *tag, const char *key, const char *val) {
  lua_newtable(L);
  lua_pushstring(L, tag);
  lua_setfield(L, -2, "tag");
  if (val != NULL && key != NULL) {
    lua_pushstring(L, val);
    lua_setfield(L, -2, key);
  }
}


/*
 * diff.split(str, mode)
 *
 * Arguments:
 *  str the string to split
 *  mode The splitting mode which can be "char" or "line" (defaults to line)
 *
 * Returns:
 *  A table with the splitted values
 */
static int f_split(lua_State *L) {
  const char *str = luaL_checkstring(L, 1);
  const char *mode = luaL_optstring(L, 2, "line");

  lua_newtable(L);
  int idx = 1;

  if (strcmp(mode, "char") == 0) {
    for (const char *p = str; *p; ++p) {
      lua_pushlstring(L, p, 1);
      lua_rawseti(L, -2, idx++);
    }
  } else {
    const char *start = str;
    const char *p = str;
    while (*p) {
      if (*p == '\r' && *(p + 1) == '\n') {
        lua_pushlstring(L, start, p - start);
        lua_rawseti(L, -2, idx++);
        p += 2;
        start = p;
      } else if (*p == '\n') {
        lua_pushlstring(L, start, p - start);
        lua_rawseti(L, -2, idx++);
        p++;
        start = p;
      } else {
        p++;
      }
    }

    // Always push the final segment, even if empty
    lua_pushlstring(L, start, p - start);
    lua_rawseti(L, -2, idx++);
  }

  return 1;
}


/*
 * diff.inline_diff(str_a, str_b)
 *
 * Arguments:
 *  str_a a string to compare against string_b
 *  str_b a string to compare against string_a
 *
 * Returns:
 *  A table with the differences in the two strings
 */
static int f_inline_diff(lua_State *L) {
  const char *a = luaL_checkstring(L, 1);
  const char *b = luaL_checkstring(L, 2);
  if (strcmp(a, b) == 0) {
    lua_newtable(L);
    lua_pushstring(L, "equal");
    lua_setfield(L, -2, "tag");
    lua_pushstring(L, a);
    lua_setfield(L, -2, "val");
    lua_newtable(L);
    lua_rawseti(L, -2, 1); // { {tag="equal", val=a} }
    return 1;
  }

  int m = strlen(a), n = strlen(b);
  int **dp = malloc((m+1) * sizeof(int*));
  for (int i = 0; i <= m; i++) {
    dp[i] = calloc(n+1, sizeof(int));
  }

  for (int i = 1; i <= m; i++) {
    for (int j = 1; j <= n; j++) {
      if (a[i-1] == b[j-1])
        dp[i][j] = dp[i-1][j-1] + 1;
      else
        dp[i][j] = fmax(dp[i-1][j], dp[i][j-1]);
    }
  }

  lua_newtable(L); // result table
  int edit_idx = 1;
  int i = m, j = n;

  while (i > 0 && j > 0) {
    if (a[i-1] == b[j-1]) {
      lua_newtable(L);
      lua_pushstring(L, "equal");
      lua_setfield(L, -2, "tag");
      lua_pushlstring(L, &a[i-1], 1);
      lua_setfield(L, -2, "val");
      lua_rawseti(L, -2, edit_idx++);
      i--; j--;
    } else if (dp[i-1][j] >= dp[i][j-1]) {
      lua_newtable(L);
      lua_pushstring(L, "delete");
      lua_setfield(L, -2, "tag");
      lua_pushlstring(L, &a[i-1], 1);
      lua_setfield(L, -2, "val");
      lua_rawseti(L, -2, edit_idx++);
      i--;
    } else {
      lua_newtable(L);
      lua_pushstring(L, "insert");
      lua_setfield(L, -2, "tag");
      lua_pushlstring(L, &b[j-1], 1);
      lua_setfield(L, -2, "val");
      lua_rawseti(L, -2, edit_idx++);
      j--;
    }
  }

  while (i > 0) {
    lua_newtable(L);
    lua_pushstring(L, "delete");
    lua_setfield(L, -2, "tag");
    lua_pushlstring(L, &a[i-1], 1);
    lua_setfield(L, -2, "val");
    lua_rawseti(L, -2, edit_idx++);
    i--;
  }

  while (j > 0) {
    lua_newtable(L);
    lua_pushstring(L, "insert");
    lua_setfield(L, -2, "tag");
    lua_pushlstring(L, &b[j-1], 1);
    lua_setfield(L, -2, "val");
    lua_rawseti(L, -2, edit_idx++);
    j--;
  }

  // Reverse result table
  lua_newtable(L);
  int total = edit_idx - 1;
  for (int k = 1; k <= total; k++) {
    lua_rawgeti(L, -2, total - k + 1);
    lua_rawseti(L, -2, k);
  }

  lua_remove(L, -2); // remove un-reversed table

  for (int k = 0; k <= m; k++) free(dp[k]);
  free(dp);

  return 1;
}


/*
 * diff.diff(strings_table_a, strings_table_b)
 *
 * Arguments:
 *  strings_table_a a list of strings to compare against strings_table_b
 *  strings_table_b a list of strings to compare against strings_table_a
 *
 * Returns:
 *  A table with the differences per line for a and b.
 */
static int f_diff(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  luaL_checktype(L, 2, LUA_TTABLE);
  double threshold = luaL_optnumber(L, 3, 0.4);

  int Aidx = 1, Bidx = 2;
  int lenA = (int)lua_rawlen(L, Aidx);
  int lenB = (int)lua_rawlen(L, Bidx);

  int npairs;
  Pair *pairs = build_lcs(L, Aidx, Bidx, &npairs, threshold);

  lua_newtable(L);
  int result_idx = lua_gettop(L);
  int out_i = 1;
  int ai = 1, bi = 1, pi = 0;

  while (ai <= lenA || bi <= lenB) {
    int mi = (pi < npairs) ? pairs[pi].i : lenA + 1;
    int mj = (pi < npairs) ? pairs[pi].j : lenB + 1;

    if (ai == mi && bi == mj) {
      lua_rawgeti(L, Aidx, ai);
      const char *a = lua_tostring(L, -1);
      lua_rawgeti(L, Bidx, bi);
      const char *b = lua_tostring(L, -1);

      push_edit(L, strcmp(a, b) == 0 ? "equal" : "modify", "a", a);
      lua_pushstring(L, b);
      lua_setfield(L, -2, "b");
      lua_rawseti(L, result_idx, out_i++);
      lua_pop(L, 2);

      ai++; bi++; pi++;
    }
    else if (mi > ai && mj > bi) {
      // Try fallback similarity on unmatched lines
      lua_rawgeti(L, Aidx, ai);
      const char *a = lua_tostring(L, -1);
      lua_rawgeti(L, Bidx, bi);
      const char *b = lua_tostring(L, -1);
      double sim_val = similarity(a, b);
      lua_pop(L, 2);

      if (sim_val >= 0.4) {
        push_edit(L, "modify", "a", a);
        lua_pushstring(L, b);
        lua_setfield(L, -2, "b");
        lua_rawseti(L, result_idx, out_i++);
        ai++; bi++;
        continue;
      }
    }

    if (mi > ai) {
      lua_rawgeti(L, Aidx, ai);
      const char *a = lua_tostring(L, -1);
      push_edit(L, "delete", "a", a);
      lua_rawseti(L, result_idx, out_i++);
      lua_pop(L, 1);
      ai++;
    } else if (mj > bi) {
      lua_rawgeti(L, Bidx, bi);
      const char *b = lua_tostring(L, -1);
      push_edit(L, "insert", "b", b);
      lua_rawseti(L, result_idx, out_i++);
      lua_pop(L, 1);
      bi++;
    }
  }

  free(pairs);
  return 1;
}


/* Closure for the diff.diff_iter */
static int diff_iterator(lua_State *L) {
  int Aidx = lua_upvalueindex(1);
  int Bidx = lua_upvalueindex(2);
  DiffState *state = (DiffState*)lua_touserdata(L, lua_upvalueindex(3));

  int lenA = state->lenA;
  int lenB = state->lenB;
  Pair *pairs = state->pairs;
  int npairs = state->npairs;

  while (state->ai <= lenA || state->bi <= lenB) {
    int mi = (state->pi < npairs) ? pairs[state->pi].i : lenA + 1;
    int mj = (state->pi < npairs) ? pairs[state->pi].j : lenB + 1;

    if (state->ai == mi && state->bi == mj) {
      lua_rawgeti(L, Aidx, state->ai);
      const char *a = lua_tostring(L, -1);
      lua_pop(L, 1);

      lua_rawgeti(L, Bidx, state->bi);
      const char *b = lua_tostring(L, -1);
      lua_pop(L, 1);

      push_edit(L, strcmp(a, b) == 0 ? "equal" : "modify", "a", a);
      lua_pushstring(L, b);
      lua_setfield(L, -2, "b");

      state->ai++; state->bi++; state->pi++;
      return 1;
    }

    if (state->ai < mi && state->bi < mj) {
      lua_rawgeti(L, Aidx, state->ai);
      const char *a = lua_tostring(L, -1);
      lua_pop(L, 1);

      lua_rawgeti(L, Bidx, state->bi);
      const char *b = lua_tostring(L, -1);
      lua_pop(L, 1);

      double sim_val = similarity(a, b);
      if (sim_val >= 0.4) {
        push_edit(L, "modify", "a", a);
        lua_pushstring(L, b);
        lua_setfield(L, -2, "b");

        state->ai++; state->bi++;
        return 1;
      }
    }

    if (state->ai < mi) {
      lua_rawgeti(L, Aidx, state->ai);
      const char *a = lua_tostring(L, -1);
      lua_pop(L, 1);

      push_edit(L, "delete", "a", a);
      state->ai++;
      return 1;
    }

    if (state->bi < mj) {
      lua_rawgeti(L, Bidx, state->bi);
      const char *b = lua_tostring(L, -1);
      lua_pop(L, 1);

      push_edit(L, "insert", "b", b);
      state->bi++;
      return 1;
    }
  }

  // Free memory when done
  if (state->pairs) {
    free(state->pairs);
    state->pairs = NULL;
  }

  return 0;
}

/*
 * diff.diff_iter(strings_table_a, strings_table_b)
 *
 * Arguments:
 *  strings_table_a a list of strings to compare against strings_table_b
 *  strings_table_b a list of strings to compare against strings_table_a
 *
 * Returns:
 *  An iterator that yields the differences per line for a and b
 */
static int f_diff_iter(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  luaL_checktype(L, 2, LUA_TTABLE);
  double threshold = luaL_optnumber(L, 3, 0.4);

  DiffState *state = malloc(sizeof(DiffState));
  state->lenA = (int)lua_rawlen(L, 1);
  state->lenB = (int)lua_rawlen(L, 2);
  state->ai = 1;
  state->bi = 1;
  state->pi = 0;
  state->pairs = build_lcs(L, 1, 2, &state->npairs, threshold);

  /* Push tables and state to closure */
  lua_pushvalue(L, 1);
  lua_pushvalue(L, 2);
  lua_pushlightuserdata(L, state);

  lua_pushcclosure(L, diff_iterator, 3);
  return 1;
}


static const struct luaL_Reg lib[] = {
  {"split", f_split},
  {"inline_diff", f_inline_diff},
  {"diff", f_diff},
  {"diff_iter", f_diff_iter},
  {NULL, NULL}
};


int luaopen_diff(lua_State *L) {
  luaL_newlib(L, lib);
  return 1;
}
