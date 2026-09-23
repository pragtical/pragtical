#ifndef API_H
#define API_H

#include <stdbool.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

/* compatibility layer: https://github.com/lunarmodules/lua-compat-5.3 */
#include "compat/compat-5.3.h"

#define API_TYPE_FONT "Font"
#define API_TYPE_REGEX "Regex"
#define API_TYPE_THREAD "Thread"
#define API_TYPE_CHANNEL "Channel"
#define API_TYPE_CANVAS "Canvas"
#define API_TYPE_PROCESS "Process"
#define API_TYPE_DIRMONITOR "Dirmonitor"
#define API_TYPE_NATIVE_PLUGIN "NativePlugin"
#define API_TYPE_SHARED_MEMORY "SharedMemory"
#define API_TYPE_RENWINDOW "RenWindow"
#define API_TYPE_AUDIO_MIXER "AudioMixer"
#define API_TYPE_AUDIO_GROUP "AudioGroup"
#define API_TYPE_AUDIO_STREAM "AudioStream"
#define API_TYPE_AUDIO_SOUND "AudioSound"
#define API_TYPE_AUDIO_VOICE "AudioVoice"

#define API_CONSTANT_DEFINE(L, idx, key, n) (lua_pushnumber(L, n), lua_setfield(L, idx - 1, key))

void api_load_libs(lua_State *L);
void api_thread_shutdown(lua_State *L);
bool api_thread_poll(lua_State *L);
void api_audio_shutdown(void);
void api_audio_dispatch(lua_State *L);

#endif
