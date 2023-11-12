#ifndef PRAGTICAL_API_H
#define PRAGTICAL_API_H

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include "papi.h"

/* compatibility layer: https://github.com/keplerproject/lua-compat-5.3 */
#include "compat/compat-5.3.h"

#define API_TYPE_FONT "Font"
#define API_TYPE_THREAD "Thread"
#define API_TYPE_CHANNEL "Channel"
#define API_TYPE_PROCESS "Process"
#define API_TYPE_DIRMONITOR "Dirmonitor"
#define API_TYPE_NATIVE_PLUGIN "NativePlugin"
#define API_TYPE_SHARED_MEMORY "SharedMemory"

#define API_CONSTANT_DEFINE(L, idx, key, n) (lua_pushnumber(L, n), lua_setfield(L, idx - 1, key))

PAPI_BEGIN_EXTERN

PAPI void PAPICALL api_load_libs(lua_State *L);

PAPI_END_EXTERN

#endif /* PRAGTICAL_API_H */
