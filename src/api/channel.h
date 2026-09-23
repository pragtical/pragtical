#ifndef THREAD_CHANNEL_H
#define THREAD_CHANNEL_H

#include <SDL3/SDL.h>

#include "api.h"

typedef struct thread_session {
  SDL_AtomicInt ref;
  SDL_Mutex *mutex;
  SDL_Condition *changed;
  struct thread *workers;
  struct channel *channels;
  bool closing;
  bool warned;
  Uint64 shutdown_time;
} ThreadSession;

ThreadSession *thread_get_session(lua_State *L);
void thread_session_retain(ThreadSession *session);
void thread_session_release(ThreadSession *session);
int thread_shutdown_error(lua_State *L);
void thread_channels_shutdown(ThreadSession *session);

// channel table functions
int f_channel_get(lua_State*);

// Channel object methods
int m_channel_first(lua_State*);
int m_channel_last(lua_State*);
int m_channel_push(lua_State*);
int m_channel_clear(lua_State*);
int m_channel_pop(lua_State*);
int m_channel_supply(lua_State*);
int m_channel_wait(lua_State*);

// Channel object metamethods
int mm_channel_gc(lua_State*);
int mm_channel_tostring(lua_State*);

#endif
