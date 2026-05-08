#include "api.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <SDL3/SDL.h>
#include <SDL3/SDL_iostream.h>
#include <SDL3/SDL_process.h>
#include <SDL3/SDL_properties.h>
#include <SDL3/SDL_stdinc.h>
#include <SDL3/SDL_thread.h>

#if _WIN32
  #include <windows.h>
  #include <shellapi.h>
  #include "../utfconv.h"
#else
  #include <errno.h>
  #include <fcntl.h>
  #include <signal.h>
  #include <sys/types.h>
  #include <sys/wait.h>
  #include <unistd.h>
#endif

#include "../arena_allocator.h"

#define READ_BUF_SIZE 2048
#define PROCESS_TERM_TRIES 3
#define PROCESS_TERM_DELAY 50
#define PROCESS_KILL_LIST_NAME "__process_kill_list__"

typedef enum {
  ERROR_PIPE = -1,
  ERROR_WOULDBLOCK = -2,
  ERROR_TIMEDOUT = -3,
  ERROR_INVAL = -4,
  ERROR_NOMEM = -5
} process_error_t;

typedef enum {
  STDIN_FD = 0,
  STDOUT_FD = 1,
  STDERR_FD = 2
} process_stream_id_t;

typedef enum {
  WAIT_INFINITE = -1,
  WAIT_DEADLINE = -2
} wait_e;

typedef enum {
  REDIRECT_DEFAULT = 0,
  REDIRECT_PIPE = 1,
  REDIRECT_PARENT = 2,
  REDIRECT_DISCARD = 3,
  REDIRECT_STDOUT = 4
} redirect_e;

typedef enum {
  SIGNAL_TERM,
  SIGNAL_KILL,
  SIGNAL_INTERRUPT
} signal_e;

typedef struct process_s {
  SDL_Process *process;
  SDL_IOStream *streams[3];
  char *pending[2];
  size_t pending_len[2];
  size_t pending_cap[2];
  bool pending_eof[3];
  bool native;
  bool running;
  bool detached;
  bool process_group;
  int returncode;
  int deadline;
  long pid;
  struct process_s *prev;
  struct process_s *next;
} process_t;

typedef struct process_kill_s {
  int tries;
  Uint64 start_time;
  SDL_Process *process;
  long pid;
  bool native;
  bool process_group;
  struct process_kill_s *next;
} process_kill_t;

typedef struct {
  bool stop;
  SDL_Mutex *mutex;
  SDL_Condition *has_work;
  SDL_Condition *work_done;
  SDL_Thread *worker_thread;
  process_kill_t *head;
  process_kill_t *tail;
  process_t *processes;
} process_kill_list_t;

static const char *process_error_message(int code) {
  switch (code) {
    case ERROR_PIPE: return "pipe error";
    case ERROR_WOULDBLOCK: return "operation would block";
    case ERROR_TIMEDOUT: return "timed out";
    case ERROR_INVAL: return "invalid argument";
    case ERROR_NOMEM: return "out of memory";
    default: return NULL;
  }
}

static int push_error_string(lua_State *L, int err) {
  const char *message = process_error_message(err);
  if (message) {
    lua_pushstring(L, message);
    return 1;
  }

#ifdef _WIN32
  char *msg = NULL;
  if (err > 0) {
    FormatMessageA(
      FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_IGNORE_INSERTS,
      NULL,
      (DWORD) err,
      MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
      (char *) &msg,
      0,
      NULL
    );
  }
  if (!msg) {
    const char *sdl_error = SDL_GetError();
    if (sdl_error && sdl_error[0]) {
      lua_pushstring(L, sdl_error);
      return 1;
    }
    return 0;
  }

  lua_pushstring(L, msg);
  LocalFree(msg);
#else
  if (err > 0) {
    lua_pushstring(L, strerror(err));
  } else {
    const char *sdl_error = SDL_GetError();
    if (!sdl_error || !sdl_error[0]) return 0;
    lua_pushstring(L, sdl_error);
  }
#endif
  return 1;
}

static int push_error(lua_State *L, const char *extra, int err) {
  const char *message = "unknown error";
  if (push_error_string(L, err))
    message = lua_tostring(L, -1);
  lua_pushnil(L);
  if (extra && extra[0])
    lua_pushfstring(L, "%s: %s", extra, message);
  else
    lua_pushstring(L, message);
  lua_pushinteger(L, err);
  return 3;
}

static void kill_list_push(process_kill_list_t *list, process_kill_t *task) {
  if (!list || !task)
    return;

  task->next = NULL;
  if (list->tail) {
    list->tail->next = task;
    list->tail = task;
  } else {
    list->head = list->tail = task;
  }
}

static process_kill_t *kill_list_pop(process_kill_list_t *list) {
  process_kill_t *head = NULL;
  if (!list || !list->head)
    return NULL;

  head = list->head;
  list->head = head->next;
  if (!list->head)
    list->tail = NULL;
  head->next = NULL;
  return head;
}

static void process_list_add(process_kill_list_t *list, process_t *process) {
  if (!list || !process)
    return;

  process->prev = NULL;
  process->next = list->processes;
  if (list->processes)
    list->processes->prev = process;
  list->processes = process;
}

static void process_list_remove(process_kill_list_t *list, process_t *process) {
  if (!list || !process)
    return;

  if (process->prev)
    process->prev->next = process->next;
  else if (list->processes == process)
    list->processes = process->next;

  if (process->next)
    process->next->prev = process->prev;

  process->prev = NULL;
  process->next = NULL;
}

static bool signal_process_group(long pid, signal_e sig) {
#ifdef _WIN32
  (void) pid;
  (void) sig;
  return false;
#else
  int signo = sig == SIGNAL_KILL ? SIGKILL : sig == SIGNAL_INTERRUPT ? SIGINT : SIGTERM;
  return kill(-(pid_t) pid, signo) == 0;
#endif
}

static bool signal_process_id(long pid, signal_e sig) {
#ifdef _WIN32
  (void) pid;
  (void) sig;
  return false;
#else
  int signo = sig == SIGNAL_KILL ? SIGKILL : sig == SIGNAL_INTERRUPT ? SIGINT : SIGTERM;
  return kill((pid_t) pid, signo) == 0;
#endif
}

#ifndef _WIN32
static bool wait_native_process(long pid, bool block, int *exitcode) {
  int status = 0;
  pid_t ret = 0;

  do {
    ret = waitpid((pid_t) pid, &status, block ? 0 : WNOHANG);
  } while (ret < 0 && errno == EINTR);

  if (ret == 0)
    return false;

  if (ret < 0) {
    if (errno == ECHILD)
      return true;
    return false;
  }

  if (exitcode) {
    if (WIFEXITED(status))
      *exitcode = WEXITSTATUS(status);
    else if (WIFSIGNALED(status))
      *exitcode = -WTERMSIG(status);
    else
      *exitcode = -255;
  }
  return true;
}
#endif

static bool wait_process_handle(SDL_Process *process, bool native, long pid, bool block, int *exitcode) {
#ifdef _WIN32
  (void) native;
  (void) pid;
  return process && SDL_WaitProcess(process, block, exitcode);
#else
  return native ? wait_native_process(pid, block, exitcode) : process && SDL_WaitProcess(process, block, exitcode);
#endif
}

static void kill_task_free(process_kill_t *task) {
  if (!task)
    return;
  if (task->process)
    SDL_DestroyProcess(task->process);
  SDL_free(task);
}

static int kill_list_worker(void *ud) {
  process_kill_list_t *list = (process_kill_list_t *) ud;

  while (true) {
    SDL_LockMutex(list->mutex);

    while (!list->head && !list->stop)
      SDL_WaitCondition(list->has_work, list->mutex);

    if (list->stop) {
      SDL_UnlockMutex(list->mutex);
      return 0;
    }

    while (list->head) {
      process_kill_t *task = list->head;
      Uint64 now = SDL_GetTicks();
      if (now - task->start_time < PROCESS_TERM_DELAY)
        break;

      task = kill_list_pop(list);
      if (wait_process_handle(task->process, task->native, task->pid, false, NULL)) {
        if (task->process_group)
          signal_process_group(task->pid, SIGNAL_KILL);
        SDL_SignalCondition(list->work_done);
        kill_task_free(task);
        continue;
      }

      if (task->tries < PROCESS_TERM_TRIES) {
        if (task->process_group)
          signal_process_group(task->pid, SIGNAL_TERM);
        SDL_KillProcess(task->process, false);
      } else if (task->tries == PROCESS_TERM_TRIES) {
        if (task->process_group)
          signal_process_group(task->pid, SIGNAL_KILL);
        SDL_KillProcess(task->process, true);
      } else {
        SDL_SignalCondition(list->work_done);
        kill_task_free(task);
        continue;
      }

      task->tries++;
      task->start_time = SDL_GetTicks();
      kill_list_push(list, task);
    }

    Uint64 delay = 0;
    if (list->head) {
      Uint64 next = list->head->start_time + PROCESS_TERM_DELAY;
      Uint64 now = SDL_GetTicks();
      delay = next > now ? next - now : 0;
    }
    SDL_UnlockMutex(list->mutex);
    SDL_Delay((Uint32) delay);
  }
}

static void kill_list_wait_all(process_kill_list_t *list) {
  if (!list || !list->mutex)
    return;

  SDL_LockMutex(list->mutex);
  while (list->head)
    SDL_WaitCondition(list->work_done, list->mutex);
  list->stop = true;
  SDL_SignalCondition(list->has_work);
  SDL_UnlockMutex(list->mutex);
}

static void kill_list_free(process_kill_list_t *list) {
  process_kill_t *node = NULL;

  if (!list)
    return;

  if (list->worker_thread)
    SDL_WaitThread(list->worker_thread, NULL);
  if (list->mutex)
    SDL_DestroyMutex(list->mutex);
  if (list->has_work)
    SDL_DestroyCondition(list->has_work);
  if (list->work_done)
    SDL_DestroyCondition(list->work_done);

  node = list->head;
  while (node) {
    process_kill_t *next = node->next;
    kill_task_free(node);
    node = next;
  }
  memset(list, 0, sizeof(process_kill_list_t));
}

static bool kill_list_init(process_kill_list_t *list) {
  if (!list)
    return false;

  memset(list, 0, sizeof(process_kill_list_t));
  list->mutex = SDL_CreateMutex();
  list->has_work = SDL_CreateCondition();
  list->work_done = SDL_CreateCondition();
  if (!list->mutex || !list->has_work || !list->work_done) {
    kill_list_free(list);
    return false;
  }

  list->worker_thread = SDL_CreateThread(kill_list_worker, "process_kill", list);
  if (!list->worker_thread) {
    kill_list_free(list);
    return false;
  }
  return true;
}

static int pending_index(int stream) {
  return stream - 1;
}

static bool append_pending(process_t *self, int stream, const void *data, size_t len) {
  int idx = pending_index(stream);
  size_t required = self->pending_len[idx] + len;
  if (required > self->pending_cap[idx]) {
    size_t cap = self->pending_cap[idx] ? self->pending_cap[idx] : READ_BUF_SIZE;
    while (cap < required) {
      if (cap > (SIZE_MAX / 2)) {
        cap = required;
        break;
      }
      cap *= 2;
    }
    char *buffer = (char *) SDL_realloc(self->pending[idx], cap);
    if (!buffer)
      return false;
    self->pending[idx] = buffer;
    self->pending_cap[idx] = cap;
  }

  memcpy(self->pending[idx] + self->pending_len[idx], data, len);
  self->pending_len[idx] += len;
  return true;
}

static void consume_pending(process_t *self, int stream, size_t len) {
  int idx = pending_index(stream);
  if (len >= self->pending_len[idx]) {
    self->pending_len[idx] = 0;
    return;
  }
  memmove(self->pending[idx], self->pending[idx] + len, self->pending_len[idx] - len);
  self->pending_len[idx] -= len;
}

static void clear_pending(process_t *self, int stream) {
  if (stream == STDOUT_FD || stream == STDERR_FD) {
    int idx = pending_index(stream);
    SDL_free(self->pending[idx]);
    self->pending[idx] = NULL;
    self->pending_len[idx] = 0;
    self->pending_cap[idx] = 0;
  }
}

static const char *stream_property_name(int stream) {
  switch (stream) {
    case STDIN_FD: return SDL_PROP_PROCESS_STDIN_POINTER;
    case STDOUT_FD: return SDL_PROP_PROCESS_STDOUT_POINTER;
    case STDERR_FD: return SDL_PROP_PROCESS_STDERR_POINTER;
  }
  return NULL;
}

static void close_stream_handle(process_t *self, int stream) {
  SDL_IOStream *stream_handle = self->streams[stream];
  const char *prop = stream_property_name(stream);

  self->streams[stream] = NULL;
  self->pending_eof[stream] = true;
  if (stream_handle) {
    if (self->process && prop)
      SDL_ClearProperty(SDL_GetProcessProperties(self->process), prop);
    SDL_CloseIO(stream_handle);
  }
  clear_pending(self, stream);
}

static int get_timeout(process_t *self, int timeout) {
  if (timeout == WAIT_DEADLINE)
    return self->deadline;
  return timeout;
}

static bool drain_stream(process_t *self, int stream, int *error) {
  uint8_t buffer[READ_BUF_SIZE];
  SDL_IOStream *io = self->streams[stream];

  if (error) *error = 0;
  if (!io || self->pending_eof[stream])
    return true;

  while (true) {
    size_t amount = SDL_ReadIO(io, buffer, sizeof(buffer));
    if (amount > 0) {
      if (!append_pending(self, stream, buffer, amount)) {
        if (error) *error = ERROR_NOMEM;
        return false;
      }
      continue;
    }

    switch (SDL_GetIOStatus(io)) {
      case SDL_IO_STATUS_NOT_READY:
        return true;
      case SDL_IO_STATUS_EOF:
        self->pending_eof[stream] = true;
        return true;
      case SDL_IO_STATUS_READY:
        return true;
      default:
        if (error) *error = ERROR_PIPE;
        return false;
    }
  }
}

static bool poll_process(process_t *self, int timeout) {
  Uint64 start = SDL_GetTicks();

  if ((!self->process && !self->native) || !self->running)
    return false;

  timeout = get_timeout(self, timeout);
  do {
    int drain_error = 0;
    if (!drain_stream(self, STDOUT_FD, &drain_error) || !drain_stream(self, STDERR_FD, &drain_error)) {
      self->running = false;
      self->returncode = -255;
      break;
    }

    if (wait_process_handle(self->process, self->native, self->pid, false, &self->returncode)) {
      self->running = false;
      drain_stream(self, STDOUT_FD, NULL);
      drain_stream(self, STDERR_FD, NULL);
      break;
    }

    if (timeout == 0)
      break;

    SDL_Delay((timeout == WAIT_INFINITE || timeout >= 5) ? 5 : 0);
  } while (timeout == WAIT_INFINITE || (int)(SDL_GetTicks() - start) < timeout);

  return self->running;
}

static bool signal_process(process_t *self, signal_e sig) {
  bool force = (sig == SIGNAL_KILL);

  if ((!self->process && !self->native) || !poll_process(self, 0))
    return false;

  if (self->process_group) {
    if (signal_process_group(self->pid, sig)) {
      poll_process(self, 0);
      return true;
    }
  }

  if (self->native) {
    if (!signal_process_id(self->pid, sig))
      return false;
  } else if (!SDL_KillProcess(self->process, force)) {
    return false;
  }

  poll_process(self, 0);
  return true;
}

static bool push_system_environment_table(lua_State *L) {
  char **entries = SDL_GetEnvironmentVariables(SDL_GetEnvironment());
  if (!entries)
    return false;

  lua_newtable(L);
  for (char **entry = entries; *entry; ++entry) {
    const char *equal = strchr(*entry, '=');
    if (!equal)
      continue;
    lua_pushlstring(L, *entry, equal - *entry);
    lua_pushstring(L, equal + 1);
    lua_rawset(L, -3);
  }
  SDL_free(entries);
  return true;
}

static SDL_Environment *create_environment_from_block(const char *env_block, size_t len) {
  SDL_Environment *env = SDL_CreateEnvironment(false);
  const char *cursor = env_block;
  const char *end = env_block + len;

  if (!env)
    return NULL;

  while (cursor < end && *cursor) {
    size_t entry_len = strlen(cursor);
    const char *equal = memchr(cursor, '=', entry_len);
    char *name = NULL;
    if (!equal || equal == cursor) {
      SDL_DestroyEnvironment(env);
      SDL_SetError("Invalid environment variable");
      return NULL;
    }
    name = (char *) SDL_malloc((equal - cursor) + 1);
    if (!name) {
      SDL_DestroyEnvironment(env);
      SDL_SetError("Out of memory");
      return NULL;
    }
    SDL_memcpy(name, cursor, equal - cursor);
    name[equal - cursor] = '\0';
    if (!SDL_SetEnvironmentVariable(env, name, equal + 1, true)) {
      SDL_free(name);
      SDL_DestroyEnvironment(env);
      return NULL;
    }
    SDL_free(name);
    cursor += entry_len + 1;
  }

  return env;
}

static SDL_Environment *build_environment(lua_State *L, int options_idx) {
  SDL_Environment *env = NULL;

  if (lua_getfield(L, options_idx, "env") == LUA_TNIL) {
    lua_pop(L, 1);
    return NULL;
  }

  if (lua_type(L, -1) == LUA_TFUNCTION) {
    if (!push_system_environment_table(L)) {
      lua_pop(L, 1);
      return NULL;
    }
    lua_call(L, 1, 1);
    if (lua_type(L, -1) != LUA_TSTRING) {
      lua_pop(L, 1);
      SDL_SetError("Process env callback must return a NUL-separated string");
      return NULL;
    }
    size_t len = 0;
    const char *env_block = lua_tolstring(L, -1, &len);
    env = create_environment_from_block(env_block, len);
    lua_pop(L, 1);
    return env;
  }

  if (lua_type(L, -1) == LUA_TTABLE) {
    env = SDL_CreateEnvironment(true);
    if (!env) {
      lua_pop(L, 1);
      return NULL;
    }

    lua_pushnil(L);
    while (lua_next(L, -2)) {
      const char *key = luaL_checkstring(L, -2);
      const char *value = luaL_checkstring(L, -1);
      if (!SDL_SetEnvironmentVariable(env, key, value, true)) {
        lua_pop(L, 2);
        SDL_DestroyEnvironment(env);
        lua_pop(L, 1);
        return NULL;
      }
      lua_pop(L, 1);
    }
    lua_pop(L, 1);
    return env;
  }

  lua_pop(L, 1);
  SDL_SetError("Process env must be a function or table");
  return NULL;
}

static const char **build_args_from_table(lua_State *L, lxl_arena *A, int idx) {
  int len = luaL_len(L, idx);
  const char **args = lxl_arena_zero(A, sizeof(char *) * (len + 1));
  if (!args)
    return NULL;

  for (int i = 0; i < len; ++i) {
    lua_rawgeti(L, idx, i + 1);
    args[i] = lxl_arena_strdup(A, luaL_checkstring(L, -1));
    lua_pop(L, 1);
    if (!args[i])
      return NULL;
  }
  args[len] = NULL;
  return args;
}

#ifdef _WIN32
static const char **build_args_from_cmdline(lua_State *L, lxl_arena *A, const char *commandline) {
  int argc = 0;
  LPWSTR wide = utfconv_utf8towc(commandline);
  LPWSTR *argv = NULL;
  const char **args = NULL;

  if (!wide) {
    SDL_SetError("%s", UTFCONV_ERROR_INVALID_CONVERSION);
    return NULL;
  }

  argv = CommandLineToArgvW(wide, &argc);
  SDL_free(wide);
  if (!argv || argc <= 0) {
    if (argv) LocalFree(argv);
    SDL_SetError("Invalid command line");
    return NULL;
  }

  args = lxl_arena_zero(A, sizeof(char *) * (argc + 1));
  if (!args) {
    LocalFree(argv);
    return NULL;
  }

  for (int i = 0; i < argc; ++i) {
    const char *utf8 = utfconv_fromwstr(A, argv[i]);
    if (!utf8) {
      LocalFree(argv);
      SDL_SetError("%s", UTFCONV_ERROR_INVALID_CONVERSION);
      return NULL;
    }
    args[i] = utf8;
  }
  args[argc] = NULL;
  LocalFree(argv);
  return args;
}
#endif

static SDL_ProcessIO map_redirect(lua_State *L, int stream, int redirect, int *error_code) {
  if (error_code) *error_code = 0;
  switch (redirect) {
    case REDIRECT_DEFAULT:
    case REDIRECT_PIPE:
      return SDL_PROCESS_STDIO_APP;
    case REDIRECT_PARENT:
      return SDL_PROCESS_STDIO_INHERITED;
    case REDIRECT_DISCARD:
      return SDL_PROCESS_STDIO_NULL;
    case REDIRECT_STDOUT:
      if (stream == STDERR_FD) {
        return SDL_PROCESS_STDIO_INHERITED;
      }
      if (error_code) *error_code = ERROR_INVAL;
      break;
  }
  if (error_code) *error_code = ERROR_INVAL;
  lua_pushfstring(L, "invalid redirect value for stream %d", stream);
  return SDL_PROCESS_STDIO_NULL;
}

static bool set_property_or_fail(SDL_PropertiesID props, bool ok) {
  return props && ok;
}

#ifndef _WIN32
typedef struct {
  int fd;
} fd_io_t;

static size_t fd_io_read(void *userdata, void *ptr, size_t size, SDL_IOStatus *status) {
  fd_io_t *io = (fd_io_t *) userdata;
  ssize_t amount = 0;

  do {
    amount = read(io->fd, ptr, size);
  } while (amount < 0 && errno == EINTR);

  if (amount > 0)
    return (size_t) amount;
  if (amount == 0) {
    *status = SDL_IO_STATUS_EOF;
    return 0;
  }
  *status = (errno == EAGAIN || errno == EWOULDBLOCK) ? SDL_IO_STATUS_NOT_READY : SDL_IO_STATUS_ERROR;
  return 0;
}

static size_t fd_io_write(void *userdata, const void *ptr, size_t size, SDL_IOStatus *status) {
  fd_io_t *io = (fd_io_t *) userdata;
  ssize_t amount = 0;

  do {
    amount = write(io->fd, ptr, size);
  } while (amount < 0 && errno == EINTR);

  if (amount >= 0)
    return (size_t) amount;
  *status = (errno == EAGAIN || errno == EWOULDBLOCK) ? SDL_IO_STATUS_NOT_READY : SDL_IO_STATUS_ERROR;
  return 0;
}

static bool fd_io_close(void *userdata) {
  fd_io_t *io = (fd_io_t *) userdata;
  bool ok = true;

  if (io->fd >= 0 && close(io->fd) < 0)
    ok = false;
  SDL_free(io);
  return ok;
}

static SDL_IOStream *open_fd_stream(int fd) {
  SDL_IOStreamInterface iface;
  fd_io_t *io = (fd_io_t *) SDL_malloc(sizeof(fd_io_t));

  if (!io) {
    close(fd);
    return NULL;
  }

  SDL_INIT_INTERFACE(&iface);
  iface.read = fd_io_read;
  iface.write = fd_io_write;
  iface.close = fd_io_close;
  io->fd = fd;
  SDL_IOStream *stream = SDL_OpenIO(&iface, io);
  if (!stream) {
    fd_io_close(io);
    return NULL;
  }
  return stream;
}

static void close_fd(int *fd) {
  if (*fd >= 0) {
    close(*fd);
    *fd = -1;
  }
}

static bool set_fd_nonblocking(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0;
}

static bool set_fd_cloexec(int fd) {
  int flags = fcntl(fd, F_GETFD, 0);
  return flags >= 0 && fcntl(fd, F_SETFD, flags | FD_CLOEXEC) >= 0;
}

static bool create_pipe_pair(int pipefd[2]) {
  pipefd[0] = pipefd[1] = -1;
  if (pipe(pipefd) < 0)
    return false;
  return true;
}

static bool apply_child_redirect(int stream, int redirect, int pipefd[3][2]) {
  int fd = -1;

  if (redirect == REDIRECT_PARENT)
    return true;

  if (redirect == REDIRECT_STDOUT && stream == STDERR_FD)
    return dup2(STDOUT_FD, STDERR_FD) >= 0;

  if (redirect == REDIRECT_DISCARD) {
    fd = open("/dev/null", stream == STDIN_FD ? O_RDONLY : O_WRONLY);
    if (fd < 0)
      return false;
  } else if (stream == STDIN_FD) {
    fd = pipefd[stream][0];
  } else {
    fd = pipefd[stream][1];
  }

  if (fd < 0)
    return true;
  if (dup2(fd, stream) < 0) {
    if (redirect == REDIRECT_DISCARD)
      close(fd);
    return false;
  }
  if (redirect == REDIRECT_DISCARD)
    close(fd);
  return true;
}

static void apply_child_environment(char **envp) {
  if (!envp)
    return;

  for (char **entry = envp; *entry; ++entry) {
    char *equal = strchr(*entry, '=');
    if (!equal || equal == *entry)
      continue;
    *equal = '\0';
    setenv(*entry, equal + 1, 1);
    *equal = '=';
  }
}

static void close_all_pipe_fds(int pipefd[3][2], int control_pipe[2]) {
  for (int stream = STDIN_FD; stream <= STDERR_FD; ++stream) {
    close_fd(&pipefd[stream][0]);
    close_fd(&pipefd[stream][1]);
  }
  close_fd(&control_pipe[0]);
  close_fd(&control_pipe[1]);
}

static void close_child_pipe_fds(int pipefd[3][2], int control_pipe[2]) {
  for (int stream = STDIN_FD; stream <= STDERR_FD; ++stream) {
    close_fd(&pipefd[stream][0]);
    close_fd(&pipefd[stream][1]);
  }
  close_fd(&control_pipe[0]);
}

/* SDL3's POSIX process API uses posix_spawn() and does not expose a way to put
   foreground children in a dedicated process group. We keep a local POSIX spawn
   path so closing Pragtical can signal the whole tree, matching the old API. */
static bool process_start_posix(
  const char **args,
  SDL_Environment *env,
  const char *cwd,
  bool detach,
  int redirects[3],
  long *pid,
  SDL_IOStream *streams[3]
) {
  int pipefd[3][2] = { {-1, -1}, {-1, -1}, {-1, -1} };
  int parent_fd[3] = { -1, -1, -1 };
  int control_pipe[2] = { -1, -1 };
  char **envp = env ? SDL_GetEnvironmentVariables(env) : NULL;
  pid_t child = -1;
  int exec_error = 0;
  ssize_t amount = 0;

  if (env && !envp) {
    SDL_SetError("cannot get process environment");
    goto fail;
  }

  for (int stream = STDIN_FD; stream <= STDERR_FD; ++stream) {
    if (redirects[stream] == REDIRECT_DEFAULT || redirects[stream] == REDIRECT_PIPE) {
      if (!create_pipe_pair(pipefd[stream])) {
        SDL_SetError("cannot create pipe: %s", strerror(errno));
        goto fail;
      }
      parent_fd[stream] = pipefd[stream][stream == STDIN_FD ? 1 : 0];
      if (!set_fd_nonblocking(parent_fd[stream])) {
        SDL_SetError("cannot set pipe non-blocking: %s", strerror(errno));
        goto fail;
      }
    }
  }

  if (!create_pipe_pair(control_pipe) || !set_fd_cloexec(control_pipe[1])) {
    SDL_SetError("cannot create control pipe: %s", strerror(errno));
    goto fail;
  }

  child = fork();
  if (child < 0) {
    SDL_SetError("cannot create child process: %s", strerror(errno));
    goto fail;
  }

  if (child == 0) {
    if (!detach) {
      if (setpgid(0, 0) < 0)
        goto child_fail;
    } else if (setsid() < 0) {
      goto child_fail;
    }

    for (int stream = STDIN_FD; stream <= STDERR_FD; ++stream) {
      if (!apply_child_redirect(stream, redirects[stream], pipefd))
        goto child_fail;
    }

    close_child_pipe_fds(pipefd, control_pipe);
    apply_child_environment(envp);
    if (cwd && chdir(cwd) < 0)
      goto child_fail;
    execvp(args[0], (char * const *) args);

child_fail:
    exec_error = errno;
    write(control_pipe[1], &exec_error, sizeof(exec_error));
    _exit(127);
  }

  close_fd(&control_pipe[1]);
  do {
    amount = read(control_pipe[0], &exec_error, sizeof(exec_error));
  } while (amount < 0 && errno == EINTR);

  if (amount < 0) {
    SDL_SetError("cannot read child process status: %s", strerror(errno));
    goto fail;
  }

  if (amount > 0) {
    int status = 0;
    waitpid(child, &status, 0);
    SDL_SetError("cannot create child process: %s", strerror(exec_error));
    goto fail;
  }

  close_fd(&control_pipe[0]);
  for (int stream = STDIN_FD; stream <= STDERR_FD; ++stream) {
    close_fd(&pipefd[stream][stream == STDIN_FD ? 0 : 1]);
    if (parent_fd[stream] >= 0) {
      int parent_index = stream == STDIN_FD ? 1 : 0;
      streams[stream] = open_fd_stream(parent_fd[stream]);
      if (!streams[stream]) {
        parent_fd[stream] = -1;
        pipefd[stream][parent_index] = -1;
        SDL_SetError("cannot create process stream");
        goto fail;
      }
      parent_fd[stream] = -1;
      pipefd[stream][parent_index] = -1;
    }
  }

  close_all_pipe_fds(pipefd, control_pipe);
  if (envp) SDL_free(envp);
  *pid = (long) child;
  return true;

fail:
  for (int stream = STDIN_FD; stream <= STDERR_FD; ++stream) {
    close_fd(&parent_fd[stream]);
    if (streams[stream]) {
      SDL_CloseIO(streams[stream]);
      streams[stream] = NULL;
    }
  }
  close_all_pipe_fds(pipefd, control_pipe);
  if (envp) SDL_free(envp);
  return false;
}
#endif

static int process_start(lua_State *L) {
  process_t *self = NULL;
  SDL_Process *process = NULL;
  SDL_PropertiesID props = 0;
  SDL_Environment *env = NULL;
  const char **args = NULL;
  const char *commandline = NULL;
  const char *cwd = NULL;
  bool detach = false;
#ifdef _WIN32
  bool background = true;
#else
  bool background = false;
#endif
  int deadline = 10;
  int redirects[3] = { REDIRECT_DEFAULT, REDIRECT_DEFAULT, REDIRECT_DEFAULT };
#ifndef _WIN32
  SDL_IOStream *native_streams[3] = { NULL, NULL, NULL };
  long native_pid = 0;
#endif
  lxl_arena *A = lxl_arena_init(L);

  lua_settop(L, 3);
  if (!lua_istable(L, 1) && !lua_isstring(L, 1))
    return push_error(L, "invalid command", ERROR_INVAL);

  if (lua_istable(L, 2)) {
    lua_getfield(L, 2, "detach");  detach = lua_toboolean(L, -1);
    lua_getfield(L, 2, "timeout"); deadline = (int) luaL_optnumber(L, -1, deadline);
    lua_getfield(L, 2, "stdin");   redirects[STDIN_FD] = (int) luaL_optnumber(L, -1, REDIRECT_DEFAULT);
    lua_getfield(L, 2, "stdout");  redirects[STDOUT_FD] = (int) luaL_optnumber(L, -1, REDIRECT_DEFAULT);
    lua_getfield(L, 2, "stderr");  redirects[STDERR_FD] = (int) luaL_optnumber(L, -1, REDIRECT_DEFAULT);
    lua_getfield(L, 2, "cwd");     cwd = luaL_optstring(L, -1, NULL);
    lua_pop(L, 6);
  }

  if (lua_istable(L, 1)) {
    args = build_args_from_table(L, A, 1);
  } else {
    commandline = luaL_checkstring(L, 1);
#ifdef _WIN32
    args = build_args_from_cmdline(L, A, commandline);
#else
    args = lxl_arena_zero(A, sizeof(char *) * 2);
    if (args) {
      args[0] = lxl_arena_strdup(A, commandline);
      args[1] = NULL;
    }
#endif
  }

  if (!args || !args[0])
    return push_error(L, "cannot build process arguments", ERROR_NOMEM);

  props = SDL_CreateProperties();
  if (!props)
    return push_error(L, "cannot create process properties", ERROR_NOMEM);

  env = lua_istable(L, 2) ? build_environment(L, 2) : NULL;
  if (lua_istable(L, 2)) {
    if (lua_getfield(L, 2, "env") != LUA_TNIL && !env) {
      lua_pop(L, 1);
      SDL_DestroyProperties(props);
      return push_error(L, "cannot build process environment", ERROR_INVAL);
    }
    if (lua_getfield(L, 2, "background") == LUA_TBOOLEAN) {
      background = lua_toboolean(L, -1);
    }
    lua_pop(L, 2);
  }

  SDL_SetBooleanProperty(props, SDL_PROP_PROCESS_CREATE_BACKGROUND_BOOLEAN, background);

  if (!set_property_or_fail(props, SDL_SetPointerProperty(props, SDL_PROP_PROCESS_CREATE_ARGS_POINTER, (void *) args)) ||
      (cwd && !SDL_SetStringProperty(props, SDL_PROP_PROCESS_CREATE_WORKING_DIRECTORY_STRING, cwd)) ||
      (env && !SDL_SetPointerProperty(props, SDL_PROP_PROCESS_CREATE_ENVIRONMENT_POINTER, env)) ||
      (detach && !SDL_SetBooleanProperty(props, SDL_PROP_PROCESS_CREATE_BACKGROUND_BOOLEAN, true))) {
    if (env) SDL_DestroyEnvironment(env);
    SDL_DestroyProperties(props);
    return push_error(L, "cannot configure process", ERROR_INVAL);
  }

#ifdef _WIN32
  if (commandline && !SDL_SetStringProperty(props, SDL_PROP_PROCESS_CREATE_CMDLINE_STRING, commandline)) {
    if (env) SDL_DestroyEnvironment(env);
    SDL_DestroyProperties(props);
    return push_error(L, "cannot configure process command line", ERROR_INVAL);
  }
#endif

  for (int stream = STDIN_FD; stream <= STDERR_FD; ++stream) {
    int redirect_error = 0;
    SDL_ProcessIO io = map_redirect(L, stream, redirects[stream], &redirect_error);
    if (redirect_error) {
      if (env) SDL_DestroyEnvironment(env);
      SDL_DestroyProperties(props);
      return push_error(L, lua_tostring(L, -1), redirect_error);
    }

    switch (stream) {
      case STDIN_FD:
        if (!SDL_SetNumberProperty(props, SDL_PROP_PROCESS_CREATE_STDIN_NUMBER, io)) {
          if (env) SDL_DestroyEnvironment(env);
          SDL_DestroyProperties(props);
          return push_error(L, "cannot configure process stdin", ERROR_INVAL);
        }
        break;
      case STDOUT_FD:
        if (!SDL_SetNumberProperty(props, SDL_PROP_PROCESS_CREATE_STDOUT_NUMBER, io)) {
          if (env) SDL_DestroyEnvironment(env);
          SDL_DestroyProperties(props);
          return push_error(L, "cannot configure process stdout", ERROR_INVAL);
        }
        break;
      case STDERR_FD:
        if (redirects[STDERR_FD] == REDIRECT_STDOUT) {
          if (!SDL_SetBooleanProperty(props, SDL_PROP_PROCESS_CREATE_STDERR_TO_STDOUT_BOOLEAN, true)) {
            if (env) SDL_DestroyEnvironment(env);
            SDL_DestroyProperties(props);
            return push_error(L, "cannot redirect stderr to stdout", ERROR_INVAL);
          }
        } else if (!SDL_SetNumberProperty(props, SDL_PROP_PROCESS_CREATE_STDERR_NUMBER, io)) {
          if (env) SDL_DestroyEnvironment(env);
          SDL_DestroyProperties(props);
          return push_error(L, "cannot configure process stderr", ERROR_INVAL);
        }
        break;
    }
  }

#ifdef _WIN32
  /* SDL3 handles Windows-specific process details we need, including
     background console-window suppression through the process properties. */
  process = SDL_CreateProcessWithProperties(props);
  if (env) SDL_DestroyEnvironment(env);
  SDL_DestroyProperties(props);
  if (!process)
    return push_error(L, NULL, ERROR_INVAL);
#else
  /* Use our POSIX path instead of SDL3 here because we need process groups for
     non-blocking cleanup of shell-launched child processes. */
  (void) background;
  if (!process_start_posix(args, env, cwd, detach, redirects, &native_pid, native_streams)) {
    if (env) SDL_DestroyEnvironment(env);
    SDL_DestroyProperties(props);
    return push_error(L, NULL, ERROR_INVAL);
  }
  if (env) SDL_DestroyEnvironment(env);
  SDL_DestroyProperties(props);
#endif

  self = (process_t *) lua_newuserdata(L, sizeof(process_t));
  memset(self, 0, sizeof(process_t));
  luaL_setmetatable(L, API_TYPE_PROCESS);
  self->process = process;
#ifndef _WIN32
  self->native = true;
#endif
  self->running = true;
  self->detached = detach;
  self->deadline = deadline;

#ifdef _WIN32
  self->streams[STDIN_FD] = (redirects[STDIN_FD] == REDIRECT_DEFAULT || redirects[STDIN_FD] == REDIRECT_PIPE)
    ? SDL_GetProcessInput(process)
    : NULL;
  self->streams[STDOUT_FD] = (redirects[STDOUT_FD] == REDIRECT_DEFAULT || redirects[STDOUT_FD] == REDIRECT_PIPE)
    ? SDL_GetProcessOutput(process)
    : NULL;
  self->streams[STDERR_FD] = (redirects[STDERR_FD] == REDIRECT_DEFAULT || redirects[STDERR_FD] == REDIRECT_PIPE)
    ? (SDL_IOStream *) SDL_GetPointerProperty(SDL_GetProcessProperties(process), SDL_PROP_PROCESS_STDERR_POINTER, NULL)
    : NULL;
#else
  self->streams[STDIN_FD] = native_streams[STDIN_FD];
  self->streams[STDOUT_FD] = native_streams[STDOUT_FD];
  self->streams[STDERR_FD] = native_streams[STDERR_FD];
#endif

  self->pending_eof[STDIN_FD] = self->streams[STDIN_FD] == NULL;
  self->pending_eof[STDOUT_FD] = self->streams[STDOUT_FD] == NULL;
  self->pending_eof[STDERR_FD] = self->streams[STDERR_FD] == NULL;
#ifdef _WIN32
  self->pid = (long) SDL_GetNumberProperty(SDL_GetProcessProperties(process), SDL_PROP_PROCESS_PID_NUMBER, 0);
#else
  self->pid = native_pid;
  if (!self->detached && self->pid > 0)
    self->process_group = true;
#endif

  if (lua_getfield(L, LUA_REGISTRYINDEX, PROCESS_KILL_LIST_NAME) == LUA_TUSERDATA)
    process_list_add((process_kill_list_t *) lua_touserdata(L, -1), self);
  lua_pop(L, 1);

  return 1;
}

static int g_read(lua_State *L, int stream, lua_Integer read_size) {
  process_t *self = (process_t *) luaL_checkudata(L, 1, API_TYPE_PROCESS);
  int error = 0;

  if (stream != STDOUT_FD && stream != STDERR_FD)
    return push_error(L, "invalid stream for read", ERROR_INVAL);

  if (!drain_stream(self, stream, &error))
    return push_error(L, "cannot read from child process", error);

  if (self->pending_len[pending_index(stream)] > 0) {
    size_t amount = (size_t) read_size;
    int idx = pending_index(stream);
    if (amount > self->pending_len[idx])
      amount = self->pending_len[idx];
    lua_pushlstring(L, self->pending[idx], amount);
    consume_pending(self, stream, amount);
    return 1;
  }

  if (!poll_process(self, 0) && self->pending_eof[stream])
    return 0;

  lua_pushliteral(L, "");
  return 1;
}

static int f_write(lua_State *L) {
  process_t *self = (process_t *) luaL_checkudata(L, 1, API_TYPE_PROCESS);
  size_t size = 0;
  const char *data = luaL_checklstring(L, 2, &size);
  SDL_IOStream *input = self->streams[STDIN_FD];
  size_t written = 0;

  if (!input)
    return push_error(L, "stdin is not available", ERROR_PIPE);

  written = SDL_WriteIO(input, data, size);
  if (written > 0)
    SDL_FlushIO(input);

  if (written < size) {
    SDL_IOStatus status = SDL_GetIOStatus(input);
    if (status == SDL_IO_STATUS_NOT_READY) {
      lua_pushinteger(L, (lua_Integer) written);
      return 1;
    }
    return push_error(L, "cannot write to child process", ERROR_PIPE);
  }

  lua_pushinteger(L, (lua_Integer) written);
  return 1;
}

static int f_close_stream(lua_State *L) {
  process_t *self = (process_t *) luaL_checkudata(L, 1, API_TYPE_PROCESS);
  int stream = (int) luaL_checknumber(L, 2);

  if (stream < STDIN_FD || stream > STDERR_FD)
    return push_error(L, "invalid stream", ERROR_INVAL);

  close_stream_handle(self, stream);
  lua_pushboolean(L, 1);
  return 1;
}

static int process_strerror(lua_State *L) {
  return push_error_string(L, (int) luaL_checknumber(L, 1));
}

static int f_tostring(lua_State *L) {
  lua_pushliteral(L, API_TYPE_PROCESS);
  return 1;
}

static int f_pid(lua_State *L) {
  process_t *self = (process_t *) luaL_checkudata(L, 1, API_TYPE_PROCESS);
  poll_process(self, 0);
  lua_pushinteger(L, self->running ? self->pid : 0);
  return 1;
}

static int f_returncode(lua_State *L) {
  process_t *self = (process_t *) luaL_checkudata(L, 1, API_TYPE_PROCESS);
  if (poll_process(self, 0))
    return 0;
  lua_pushinteger(L, self->returncode);
  return 1;
}

static int f_read_stdout(lua_State *L) {
  return g_read(L, STDOUT_FD, luaL_optinteger(L, 2, READ_BUF_SIZE));
}

static int f_read_stderr(lua_State *L) {
  return g_read(L, STDERR_FD, luaL_optinteger(L, 2, READ_BUF_SIZE));
}

static int f_read(lua_State *L) {
  return g_read(L, (int) luaL_checknumber(L, 2), luaL_optinteger(L, 3, READ_BUF_SIZE));
}

static int f_wait(lua_State *L) {
  process_t *self = (process_t *) luaL_checkudata(L, 1, API_TYPE_PROCESS);
  int timeout = (int) luaL_optnumber(L, 2, 0);

  if (poll_process(self, timeout))
    return push_error(L, "process wait timed out", ERROR_TIMEDOUT);

  lua_pushinteger(L, self->returncode);
  return 1;
}

static int self_signal(lua_State *L, signal_e sig) {
  process_t *self = (process_t *) luaL_checkudata(L, 1, API_TYPE_PROCESS);

  if (!poll_process(self, 0))
    return push_error(L, "process is not running", ERROR_INVAL);

  if (!signal_process(self, sig))
    return push_error(L, "cannot signal process", ERROR_INVAL);

  lua_pushboolean(L, 1);
  return 1;
}

static int f_terminate(lua_State *L) { return self_signal(L, SIGNAL_TERM); }
static int f_kill(lua_State *L) { return self_signal(L, SIGNAL_KILL); }
static int f_interrupt(lua_State *L) { return self_signal(L, SIGNAL_INTERRUPT); }

static void process_close(process_t *self, process_kill_list_t *list) {
  process_kill_t *task = NULL;

  if ((self->process || self->native) && !self->detached && poll_process(self, 0)) {
    signal_process(self, SIGNAL_TERM);

    if (list && list->worker_thread)
      task = (process_kill_t *) SDL_malloc(sizeof(process_kill_t));

    if (task) {
      close_stream_handle(self, STDIN_FD);
      close_stream_handle(self, STDOUT_FD);
      close_stream_handle(self, STDERR_FD);

      task->process = self->process;
      task->pid = self->pid;
      task->native = self->native;
      task->process_group = self->process_group;
      task->tries = 1;
      task->start_time = SDL_GetTicks();

      SDL_LockMutex(list->mutex);
      kill_list_push(list, task);
      SDL_SignalCondition(list->has_work);
      SDL_UnlockMutex(list->mutex);

      self->process = NULL;
      self->native = false;
      self->running = false;
    } else if (poll_process(self, PROCESS_TERM_TRIES * PROCESS_TERM_DELAY)) {
      signal_process(self, SIGNAL_KILL);
    }
  }

  close_stream_handle(self, STDIN_FD);
  close_stream_handle(self, STDOUT_FD);
  close_stream_handle(self, STDERR_FD);

  if (self->process) {
    SDL_DestroyProcess(self->process);
    self->process = NULL;
  }
  self->native = false;
}

static int f_gc(lua_State *L) {
  process_t *self = (process_t *) luaL_checkudata(L, 1, API_TYPE_PROCESS);
  process_kill_list_t *list = NULL;

  if (lua_getfield(L, LUA_REGISTRYINDEX, PROCESS_KILL_LIST_NAME) == LUA_TUSERDATA)
    list = (process_kill_list_t *) lua_touserdata(L, -1);
  lua_pop(L, 1);

  process_list_remove(list, self);
  process_close(self, list);

  return 0;
}

static int f_running(lua_State *L) {
  process_t *self = (process_t *) luaL_checkudata(L, 1, API_TYPE_PROCESS);
  lua_pushboolean(L, poll_process(self, 0));
  return 1;
}

static int process_gc(lua_State *L) {
  process_kill_list_t *list = NULL;

  if (lua_getfield(L, LUA_REGISTRYINDEX, PROCESS_KILL_LIST_NAME) == LUA_TUSERDATA) {
    list = (process_kill_list_t *) lua_touserdata(L, -1);
    while (list->processes) {
      process_t *process = list->processes;
      process_list_remove(list, process);
      process_close(process, list);
    }
    kill_list_wait_all(list);
    kill_list_free(list);
    lua_pushnil(L);
    lua_setfield(L, LUA_REGISTRYINDEX, PROCESS_KILL_LIST_NAME);
  }
  lua_pop(L, 1);
  return 0;
}

#ifdef LUA_JITLIBNAME
static void luajit_register_process_gc(lua_State *L) {
  lua_newuserdata(L, 1);
  if (luaL_newmetatable(L, "luajit_process_gc_mt")) {
    lua_pushcfunction(L, process_gc);
    lua_setfield(L, -2, "__gc");
  }
  lua_setmetatable(L, -2);
  lua_setfield(L, LUA_REGISTRYINDEX, "luajit_process_gc");
}
#endif

static const struct luaL_Reg process_metatable[] = {
  { "__gc", f_gc },
  { "__tostring", f_tostring },
  { "pid", f_pid },
  { "returncode", f_returncode },
  { "read", f_read },
  { "read_stdout", f_read_stdout },
  { "read_stderr", f_read_stderr },
  { "write", f_write },
  { "close_stream", f_close_stream },
  { "wait", f_wait },
  { "terminate", f_terminate },
  { "kill", f_kill },
  { "interrupt", f_interrupt },
  { "running", f_running },
  { NULL, NULL }
};

static const struct luaL_Reg lib[] = {
  { "start", process_start },
  { "strerror", process_strerror },
  { NULL, NULL }
};

int luaopen_process(lua_State *L) {
  process_kill_list_t *list = NULL;

  if (lua_getfield(L, LUA_REGISTRYINDEX, PROCESS_KILL_LIST_NAME) == LUA_TNIL) {
    lua_pop(L, 1);
    list = (process_kill_list_t *) lua_newuserdata(L, sizeof(process_kill_list_t));
    if (kill_list_init(list))
      lua_setfield(L, LUA_REGISTRYINDEX, PROCESS_KILL_LIST_NAME);
    else
      lua_pop(L, 1);
  } else {
    lua_pop(L, 1);
  }

  luaL_newmetatable(L, API_TYPE_PROCESS);
  luaL_setfuncs(L, process_metatable, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");

  luaL_newlib(L, lib);
  lua_newtable(L);
  lua_pushcfunction(L, process_gc);
  lua_setfield(L, -2, "__gc");
  lua_setmetatable(L, -2);

  API_CONSTANT_DEFINE(L, -1, "ERROR_PIPE", ERROR_PIPE);
  API_CONSTANT_DEFINE(L, -1, "ERROR_WOULDBLOCK", ERROR_WOULDBLOCK);
  API_CONSTANT_DEFINE(L, -1, "ERROR_TIMEDOUT", ERROR_TIMEDOUT);
  API_CONSTANT_DEFINE(L, -1, "ERROR_INVAL", ERROR_INVAL);
  API_CONSTANT_DEFINE(L, -1, "ERROR_NOMEM", ERROR_NOMEM);

  API_CONSTANT_DEFINE(L, -1, "WAIT_INFINITE", WAIT_INFINITE);
  API_CONSTANT_DEFINE(L, -1, "WAIT_DEADLINE", WAIT_DEADLINE);

  API_CONSTANT_DEFINE(L, -1, "STREAM_STDIN", STDIN_FD);
  API_CONSTANT_DEFINE(L, -1, "STREAM_STDOUT", STDOUT_FD);
  API_CONSTANT_DEFINE(L, -1, "STREAM_STDERR", STDERR_FD);

  API_CONSTANT_DEFINE(L, -1, "REDIRECT_DEFAULT", REDIRECT_DEFAULT);
  API_CONSTANT_DEFINE(L, -1, "REDIRECT_PIPE", REDIRECT_PIPE);
  API_CONSTANT_DEFINE(L, -1, "REDIRECT_PARENT", REDIRECT_PARENT);
  API_CONSTANT_DEFINE(L, -1, "REDIRECT_DISCARD", REDIRECT_DISCARD);
  API_CONSTANT_DEFINE(L, -1, "REDIRECT_STDOUT", REDIRECT_STDOUT);

#ifdef LUA_JITLIBNAME
  luajit_register_process_gc(L);
#endif

  return 1;
}
