/*
 * Port of https://github.com/Tangent128/luasdl2 thread.c
 *
 * Copyright (c) 2013, 2014 David Demelier <markand@malikania.fr>
 * Copyright (c) 2014 Joseph Wallace <tangent128@gmail.com>
 *
 * Permission to use, copy, modify, and/or distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

#include "channel.h"

#include <errno.h>
#include <string.h>
#include <stdbool.h>

typedef struct thread {
  lua_State *L;
  SDL_Thread *ptr;
  SDL_AtomicInt ref;
  ThreadSession *session;
  struct thread *next;
  char *name;
  SDL_ThreadID id;
  int status;
  bool joined;
  bool waited;
} LuaThread;

typedef struct thread_container {
  LuaThread *thread;
} ThreadContainer;

typedef struct session_owner {
  ThreadSession *session;
  bool root;
} SessionOwner;

static char session_key;
static char shutdown_error;

static SessionOwner *get_session_owner(lua_State *L)
{
  lua_rawgetp(L, LUA_REGISTRYINDEX, &session_key);
  SessionOwner *owner = lua_touserdata(L, -1);
  lua_pop(L, 1);
  return owner;
}

ThreadSession *thread_get_session(lua_State *L)
{
  SessionOwner *owner = get_session_owner(L);
  return owner ? owner->session : NULL;
}

void thread_session_retain(ThreadSession *session)
{
  SDL_AtomicIncRef(&session->ref);
}

void thread_session_release(ThreadSession *session)
{
  if (SDL_AtomicDecRef(&session->ref)) {
    SDL_assert(!session->workers && !session->channels);
    SDL_DestroyCondition(session->changed);
    SDL_DestroyMutex(session->mutex);
    SDL_free(session);
  }
}

int thread_shutdown_error(lua_State *L)
{
  lua_pushlightuserdata(L, &shutdown_error);
  return lua_error(L);
}

static int session_gc(lua_State *L)
{
  SessionOwner *owner = lua_touserdata(L, 1);
  if (!owner->session) return 0;
  if (owner->root) {
    api_thread_shutdown(L);
    /* Normal editor shutdown drains asynchronously before lua_close. This
     * fallback also covers direct state closure (for example CLI os.exit). */
    while (!api_thread_poll(L)) SDL_Delay(1);
  }
  ThreadSession *session = owner->session;
  owner->session = NULL;
  thread_session_release(session);
  return 0;
}

static void register_session(lua_State *L, ThreadSession *session, bool root)
{
  SessionOwner *owner = lua_newuserdata(L, sizeof(*owner));
  owner->session = NULL;
  owner->root = root;
  if (luaL_newmetatable(L, "thread_session_gc")) {
    lua_pushcfunction(L, session_gc);
    lua_setfield(L, -2, "__gc");
  }
  lua_setmetatable(L, -2);
  thread_session_retain(session);
  owner->session = session;
  lua_rawsetp(L, LUA_REGISTRYINDEX, &session_key);
}

typedef struct loadstate {
  struct {
    char* data;
    size_t size;
    ptrdiff_t last_written;
  } buffer;
  bool given;
} LoadState;

/* --------------------------------------------------------
 * Thread private functions
 * -------------------------------------------------------- */

static int writer(lua_State *L, const char *data, size_t sz, LoadState *state)
{
  size_t i;

  for (i = 0; i < sz; ++i) {
    if (state->buffer.last_written + 1 >= state->buffer.size) {
      if (!(state->buffer.data = SDL_realloc(state->buffer.data, state->buffer.size + 32))) {
        lua_pushstring(L, strerror(errno));
        return -1;
      } else {
        state->buffer.size += 32;
      }
    }
    state->buffer.last_written++;
    state->buffer.data[state->buffer.last_written] = data[i];
  }

  return 0;
}

static const char* reader(lua_State *L, LoadState *state, size_t *size)
{
  (void)L;

  if (state->given) {
    *size = 0;
    return NULL;
  }

  state->given = true;

  *size = state->buffer.last_written + 1;

  return state->buffer.data;
}

static void destroy(LuaThread *t)
{
  if (SDL_AtomicDecRef(&t->ref)) {
    /* L is non-NULL only when creation failed before starting the worker. */
    if (t->L) lua_close(t->L);
    thread_session_release(t->session);
    SDL_free(t->name);
    SDL_free(t);
  }
}

void api_thread_shutdown(lua_State *L)
{
  ThreadSession *session = thread_get_session(L);
  if (!session) return;
  SDL_LockMutex(session->mutex);
  bool shutdown = !session->closing;
  if (shutdown) {
    session->closing = true;
    session->shutdown_time = SDL_GetTicks();
    SDL_BroadcastCondition(session->changed);
  }
  SDL_UnlockMutex(session->mutex);
  if (shutdown) thread_channels_shutdown(session);
}

/* All joins are serialized by the session mutex. COMPLETE means that Lua
 * finalizers have finished too, so joining here cannot wait for Lua work. */
static void collect_workers(ThreadSession *session)
{
  LuaThread **entry = &session->workers;
  while (*entry) {
    LuaThread *worker = *entry;
    if (SDL_GetThreadState(worker->ptr) == SDL_THREAD_COMPLETE) {
      SDL_WaitThread(worker->ptr, &worker->status);
      worker->ptr = NULL;
      worker->joined = true;
      *entry = worker->next;
      destroy(worker);
      SDL_BroadcastCondition(session->changed);
    } else {
      entry = &worker->next;
    }
  }
}

bool api_thread_poll(lua_State *L)
{
  ThreadSession *session = thread_get_session(L);
  if (!session) return true;
  SDL_LockMutex(session->mutex);
  collect_workers(session);
  bool finished = session->workers == NULL;
  if (!finished && session->closing && !session->warned
      && SDL_GetTicks() - session->shutdown_time >= 5000) {
    session->warned = true;
    for (LuaThread *worker = session->workers; worker; worker = worker->next)
      SDL_LogWarn(SDL_LOG_CATEGORY_SYSTEM,
                  "Waiting for worker '%s' before closing the editor session",
                  worker->name);
  }
  SDL_UnlockMutex(session->mutex);
  return finished;
}

static int SDLCALL callback(void *data)
{
  LuaThread *t = data;
  int ret = -1;
  SDL_LockMutex(t->session->mutex);
  bool closing = t->session->closing;
  SDL_UnlockMutex(t->session->mutex);

  if (!closing && lua_pcall(t->L, lua_gettop(t->L) - 1, 1, 0) != LUA_OK) {
    if (lua_touserdata(t->L, -1) != &shutdown_error) {
      const char *message = lua_tostring(t->L, -1);
      SDL_LogCritical(SDL_LOG_CATEGORY_SYSTEM, "%s",
                      message ? message : "worker raised a non-string error");
    }
  } else if (!closing) {
    ret = lua_tointeger(t->L, -1);
  }

  lua_close(t->L);
  t->L = NULL;
  SDL_LockMutex(t->session->mutex);
  SDL_BroadcastCondition(t->session->changed);
  SDL_UnlockMutex(t->session->mutex);
  return ret;
}

static int loadfunction(lua_State *owner, lua_State *thread, int index)
{
  LoadState state = {0};
  int ret = 0;

  if (!(state.buffer.data = SDL_malloc(32))) {
    lua_pushnil(owner);
    lua_pushstring(owner, strerror(errno));
    ret = 2;
    goto cleanup;
  } else {
    state.buffer.last_written = -1;
    state.buffer.size = 32;
  }

  /* Copy the function at the top of the stack */
  lua_pushvalue(owner, index);

  if (lua_dump(owner, (lua_Writer)writer, &state, 0) != LUA_OK) {
    lua_pushnil(owner);
    lua_pushstring(owner, "failed to dump function");
    ret = 2;
    goto cleanup;
  }

  /*
   * If it fails, it pushes the error into the new state, move it to our
   * state.
   */
  if (lua_load(thread, (lua_Reader)reader, &state, "self", NULL) != LUA_OK) {
    lua_pushnil(owner);
    lua_pushstring(owner, lua_tostring(thread, -1));
    ret = 2;
    goto cleanup;
  }

cleanup:
  if (state.buffer.data) {
    SDL_free(state.buffer.data);
  }

  return ret;
}

static int loadfile(lua_State *owner, lua_State *thread, const char *path)
{
  if (luaL_loadfile(thread, path) != LUA_OK){
    lua_pushnil(owner);
    lua_pushstring(owner, lua_tostring(thread, -1));
    return 2;
  }

  return 0;
}

static int threadDump(lua_State *L, lua_State *th, int index)
{
  int ret;

  if (lua_type(L, index) == LUA_TSTRING)
    ret = loadfile(L, th, lua_tostring(L, index));
  else if (lua_type(L, index) == LUA_TFUNCTION)
    ret = loadfunction(L, th, index);
  else
    return luaL_error(L, "expected a file path or a function");

  return ret;
}

static void push_from_state(lua_State* from, lua_State* to, int index)
{
  switch (lua_type(from, index)) {
    case LUA_TNUMBER:
    {
      lua_pushnumber(to, lua_tonumber(from, index));
      break;
    }
    case LUA_TSTRING:
    {
      const char *str;
      size_t length;
      str = lua_tolstring(from, index, &length);
      lua_pushlstring(to, str, length);
      break;
    }
    case LUA_TBOOLEAN:
    {
      lua_pushboolean(to, lua_toboolean(from, index));
      break;
    }
    case LUA_TTABLE:
    {
      if (index < 0)
        -- index;

      lua_pushnil(from);

      bool table_created = false;

      while (lua_next(from, index)) {
        int key_type = lua_type(from, -2);

        if (key_type == LUA_TNIL) {
          lua_pop(from, 1);
          break;
        } else if (!table_created) {
          lua_createtable(to, 0, 0);
          table_created = true;
        }

        push_from_state(from, to, -2);
        push_from_state(from, to, -1);

        lua_settable(to, -3);

        lua_pop(from, 1);
      }
      break;
    }
  }
}

static void copy_global(const char* global, lua_State* from, lua_State* to)
{
  int index = -1;
  lua_getglobal(from, global);

  switch (lua_type(from, index)) {
    case LUA_TNUMBER:
    {
      lua_pushnumber(to, lua_tonumber(from, index));
      lua_setglobal(to, global);
      break;
    }
    case LUA_TSTRING:
    {
      const char *str;
      size_t length;
      str = lua_tolstring(from, index, &length);
      lua_pushlstring(to, str, length);
      lua_setglobal(to, global);
      break;
    }
    case LUA_TBOOLEAN:
    {
      lua_pushboolean(to, lua_toboolean(from, index));
      lua_setglobal(to, global);
      break;
    }
    case LUA_TTABLE:
    {
      if (index < 0)
        -- index;

      lua_pushnil(from);

      bool table_created = false;

      while (lua_next(from, index)) {
        int key_type = lua_type(from, -2);

        if (key_type == LUA_TNIL) {
          lua_pop(from, 1);
          break;
        } else if (!table_created) {
          lua_createtable(to, 0, 0);
          table_created = true;
        }

        push_from_state(from, to, -2);
        push_from_state(from, to, -1);

        lua_settable(to, -3);

        lua_pop(from, 1);
      }

      if (table_created)
        lua_setglobal(to, global);

      break;
    }

  }

  lua_pop(from, 1);
}

#ifdef _WIN32
#define PRAGTICAL_PATHSEP_PATTERN "\\\\"
#define PRAGTICAL_NONPATHSEP_PATTERN "[^\\\\]+"
#else
#define PRAGTICAL_PATHSEP_PATTERN "/"
#define PRAGTICAL_NONPATHSEP_PATTERN "[^/]+"
#endif

static void init_start(lua_State* L)
{
  /* partial code taken from main.c */
  const char *lua_code = \
    "local match = require('utf8extra').match\n"
    "local exedir = match(EXEFILE, '^(.*)" PRAGTICAL_PATHSEP_PATTERN PRAGTICAL_NONPATHSEP_PATTERN "$')\n"
    "local prefix = os.getenv('PRAGTICAL_PREFIX') or match(exedir, '^(.*)" PRAGTICAL_PATHSEP_PATTERN "bin$')\n"
    "dofile((MACOS_RESOURCES or (prefix and prefix .. '/share/pragtical' or exedir .. '/data')) .. '/core/start.lua')\n"
  ;

  if (luaL_loadstring(L, lua_code)) {
    return;
  }

  lua_pcall(L, 0, 0, 0);
}

/* --------------------------------------------------------
 * Thread functions
 * -------------------------------------------------------- */

/*
 * thread.create(name, source, ...)
 *
 * Create a separate thread of execution. It creates a new Lua state that
 * does not share any data frmo the parent process.
 *
 * Arguments:
 *  name, the thread name
 *  source, a path to a Lua file or a function to call
 *  ..., optional arguments passed to the thread function
 *
 * Returns:
 *  The thread object or nil
 *  The error message
 */
static int f_thread_create(lua_State *L)
{
  const char *name = luaL_checkstring(L, 1);
  int optargc = lua_gettop(L);
  ThreadSession *session = thread_get_session(L);
  int ret, iv;
  if (!session) return thread_shutdown_error(L);
  SDL_LockMutex(session->mutex);
  bool closing = session->closing;
  SDL_UnlockMutex(session->mutex);
  if (closing) return thread_shutdown_error(L);

  ThreadContainer *self = lua_newuserdata(L, sizeof(*self));
  self->thread = NULL;
  luaL_setmetatable(L, API_TYPE_THREAD);
  LuaThread *thread = SDL_calloc(1, sizeof(*thread));
  if (!thread) return luaL_error(L, "could not allocate a new thread");
  thread->session = session;
  thread_session_retain(session);
  SDL_SetAtomicInt(&thread->ref, 1); /* Lua handle */
  self->thread = thread;
  thread->name = SDL_strdup(name);
  thread->L = luaL_newstate();
  if (!thread->name || !thread->L) {
    lua_pushnil(L);
    lua_pushliteral(L, "could not allocate worker state");
    goto failure;
  }
  register_session(thread->L, session, false);
  luaL_openlibs(thread->L);

  ret = threadDump(L, thread->L, 2);

  /* If return number is 2, it is nil and the error */
  if (ret == 2) goto failure;

  /* Iterate over the optional arguments to pass to the callback */
  for (iv = 3; iv <= optargc; ++iv) {
    push_from_state(L, thread->L, iv);
  }

  /* loading pragtical api before threadDump and arguments causes issues */
  api_load_libs(thread->L);

  /* Copy globals from main state to properly set the packages path */
  copy_global("ARGS", L, thread->L);
  copy_global("PLATFORM", L, thread->L);
  copy_global("ARCH", L, thread->L);
  copy_global("EXEFILE", L, thread->L);
  copy_global("HOME", L, thread->L);
  copy_global("LUAJIT", L, thread->L);

#ifdef MACOS_USE_BUNDLE
  copy_global("MACOS_RESOURCES", L, thread->L);
#endif

  /* run core.start to initialize package path and cpath */
  init_start(thread->L);

  /* Reserve session ownership before execution can start, including when
   * the caller drops the Lua handle before the worker gets scheduled. */
  SDL_LockMutex(session->mutex);
  if (session->closing) {
    SDL_UnlockMutex(session->mutex);
    self->thread = NULL;
    destroy(thread);
    return thread_shutdown_error(L);
  }
  SDL_AtomicIncRef(&thread->ref);
  thread->ptr = SDL_CreateThread(callback, name, thread);
  if (thread->ptr == NULL) {
    (void)SDL_AtomicDecRef(&thread->ref);
    SDL_UnlockMutex(session->mutex);
    lua_pushnil(L);
    lua_pushstring(L, SDL_GetError());
    goto failure;
  }
  thread->id = SDL_GetThreadID(thread->ptr);
  thread->next = session->workers;
  session->workers = thread;
  SDL_UnlockMutex(session->mutex);

  lua_settop(L, optargc + 1);
  return 1;

failure:
  self->thread = NULL;
  destroy(thread);

  return 2;
}

/*
 * thread.get_cpu_count()
 *
 * Get the number of CPU cores available.
 *
 * Returns:
 *  The total number of logical CPU cores
 */
static int f_thread_get_cpu_count(lua_State *L)
{
  lua_pushinteger(L, SDL_GetNumLogicalCPUCores());
  return 1;
}

/* --------------------------------------------------------
 * Thread object methods
 * -------------------------------------------------------- */

/*
 * Thread:get_id()
 *
 * Returns:
 *  The thread id
 */
static int m_thread_get_id(lua_State *L)
{
  LuaThread* self = ((ThreadContainer*)luaL_checkudata(
    L, 1, API_TYPE_THREAD
  ))->thread;

  if (self->waited) {
    lua_pushnil(L);
    return 1;
  }

  lua_pushinteger(L, self->id);

  return 1;
}

/*
 * Thread:get_name()
 *
 * Returns:
 *  The thread name
 */
static int m_thread_get_name(lua_State *L)
{
  LuaThread* self = ((ThreadContainer*)luaL_checkudata(
    L, 1, API_TYPE_THREAD
  ))->thread;

  if (self->waited) {
    lua_pushnil(L);
    return 1;
  }

  lua_pushstring(L, self->name);

  return 1;
}

/*
 * Thread:wait()
 *
 * Returns:
 *  The return code from the thread
 */
static int m_thread_wait(lua_State *L)
{
  LuaThread* self = ((ThreadContainer*)luaL_checkudata(
    L, 1, API_TYPE_THREAD
  ))->thread;
  ThreadSession *session = self->session;
  SDL_LockMutex(session->mutex);
  while (!self->joined) {
    collect_workers(session);
    if (!self->joined)
      SDL_WaitConditionTimeout(session->changed, session->mutex, 10);
  }
  SDL_UnlockMutex(session->mutex);
  self->waited = true;
  lua_pushinteger(L, self->status);

  return 1;
}

/* --------------------------------------------------------
 * Thread object metamethods
 * -------------------------------------------------------- */

/*
 * Thread:__eq()
 */
static int mm_thread_eq(lua_State *L)
{
  LuaThread* t1 = ((ThreadContainer*)luaL_checkudata(
    L, 1, API_TYPE_THREAD
  ))->thread;

  LuaThread* t2 = ((ThreadContainer*)luaL_checkudata(
    L, 2, API_TYPE_THREAD
  ))->thread;

  lua_pushboolean(L, t1 == t2);

  return 1;
}

/*
 * Thread:__gc()
 */
static int mm_thread_gc(lua_State *L)
{
  ThreadContainer* self = luaL_checkudata(
    L, 1, API_TYPE_THREAD
  );
  if (self->thread) {
    LuaThread *worker = self->thread;
    self->thread = NULL;
    destroy(worker);
  }

  return 0;
}

/*
 * Thread:__tostring()
 */
static int mm_thread_tostring(lua_State *L)
{
  LuaThread* self = ((ThreadContainer*)luaL_checkudata(
    L, 1, API_TYPE_THREAD
  ))->thread;

  if (self->waited)
    lua_pushstring(L, "thread <finished>");
  else
    lua_pushfstring(L, "thread %d", self->id);

  return 1;
}

/* --------------------------------------------------------
 * Thread object definition
 * -------------------------------------------------------- */

static const struct luaL_Reg thread_lib[] = {
  {"create", f_thread_create},
  {"get_channel", f_channel_get},
  {"get_cpu_count", f_thread_get_cpu_count},
  {NULL, NULL}
};

static const struct luaL_Reg thread_object[] = {
  {"get_id", m_thread_get_id},
  {"get_name", m_thread_get_name},
  {"wait", m_thread_wait},
  {"__eq", mm_thread_eq},
  {"__gc", mm_thread_gc},
  {"__tostring", mm_thread_tostring},
  {NULL, NULL}
};

/* --------------------------------------------------------
 * Channel object definition
 * -------------------------------------------------------- */

static const struct luaL_Reg channel_object[] = {
  {"first", m_channel_first},
  {"last", m_channel_last},
  {"push", m_channel_push},
  {"clear", m_channel_clear},
  {"pop", m_channel_pop},
  {"supply", m_channel_supply},
  {"wait", m_channel_wait},
  {"__gc", mm_channel_gc},
  {"__tostring", mm_channel_tostring},
  {NULL, NULL}
};


int luaopen_thread(lua_State *L) {
  SessionOwner *owner = get_session_owner(L);
  if (owner && !owner->session) return thread_shutdown_error(L);
  if (!thread_get_session(L)) {
    ThreadSession *session = SDL_calloc(1, sizeof(*session));
    if (!session) return luaL_error(L, "could not allocate thread session");
    session->mutex = SDL_CreateMutex();
    session->changed = SDL_CreateCondition();
    if (!session->mutex || !session->changed) {
      SDL_DestroyMutex(session->mutex);
      SDL_DestroyCondition(session->changed);
      SDL_free(session);
      return luaL_error(L, "could not initialize thread session");
    }
    register_session(L, session, true);
  }

  luaL_newmetatable(L, API_TYPE_THREAD);
  luaL_setfuncs(L, thread_object, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");

  luaL_newmetatable(L, API_TYPE_CHANNEL);
  luaL_setfuncs(L, channel_object, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");

  luaL_newlib(L, thread_lib);

  return 1;
}
