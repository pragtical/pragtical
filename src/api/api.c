#include "api.h"

int luaopen_system(lua_State *L);
int luaopen_renderer(lua_State *L);
int luaopen_renwindow(lua_State *L);
int luaopen_regex(lua_State *L);
int luaopen_process(lua_State *L);
int luaopen_thread(lua_State* L);
int luaopen_dirmonitor(lua_State* L);
int luaopen_shmem(lua_State* L);
int luaopen_utf8extra(lua_State* L);
int luaopen_encoding(lua_State* L);

#if LUA_VERSION_NUM < 503
  int luaopen_compat53_io(lua_State *L);
  int luaopen_compat53_string(lua_State *L);
  int luaopen_compat53_table(lua_State *L);
  int luaopen_compat53_utf8(lua_State *L);
  #ifndef LUA_JITLIBNAME
    int luaopen_bit(lua_State *L);
    #define LUABIT_COMPATIBILITY { "bit", luaopen_bit },
  #else
    #define LUABIT_COMPATIBILITY
  #endif
  #define LUA53_COMPATIBILITY \
    { "compat53.io", luaopen_compat53_io }, \
    { "compat53.string", luaopen_compat53_string }, \
    { "compat53.table", luaopen_compat53_table }, \
    { "compat53.utf8", luaopen_compat53_utf8 }, \
    LUABIT_COMPATIBILITY
#else
  #define LUA53_COMPATIBILITY
#endif

static const luaL_Reg libs[] = {
  { "system",     luaopen_system     },
  { "renderer",   luaopen_renderer   },
  { "renwindow",  luaopen_renwindow  },
  { "regex",      luaopen_regex      },
  { "process",    luaopen_process    },
  { "thread",     luaopen_thread     },
  { "dirmonitor", luaopen_dirmonitor },
  { "utf8extra",  luaopen_utf8extra  },
  { "encoding",   luaopen_encoding   },
  { "shmem",      luaopen_shmem      },
  LUA53_COMPATIBILITY
  { NULL, NULL }
};

#undef LUA53_COMPATIBILITY
#undef LUABIT_COMPATIBILITY

void api_load_libs(lua_State *L) {
  for (int i = 0; libs[i].name; i++)
    luaL_requiref(L, libs[i].name, libs[i].func, 1);
}
