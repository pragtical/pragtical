#define SDL_MAIN_USE_CALLBACKS
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include "api/api.h"
#include "api/system_events.h"
#include "renderer.h"
#include "custom_events.h"

#ifdef _WIN32
  #include <windows.h>
#elif defined(__linux__) || defined(__serenity__)
  #include <unistd.h>
#elif defined(SDL_PLATFORM_APPLE)
  #include <mach-o/dyld.h>
#elif defined(__FreeBSD__)
  #include <sys/sysctl.h>
#endif

static void get_exe_filename(char *buf, int sz) {
#if _WIN32
  int len;
  wchar_t *buf_w = SDL_malloc(sizeof(wchar_t) * sz);
  if (buf_w) {
    len = GetModuleFileNameW(NULL, buf_w, sz - 1);
    buf_w[len] = L'\0';
    // if the conversion failed we'll empty the string
    if (!WideCharToMultiByte(CP_UTF8, 0, buf_w, -1, buf, sz, NULL, NULL))
      buf[0] = '\0';
    SDL_free(buf_w);
  } else {
    buf[0] = '\0';
  }
#elif __linux__ || __serenity__
  char path[] = "/proc/self/exe";
  ssize_t len = readlink(path, buf, sz - 1);
  if (len > 0)
    buf[len] = '\0';
#elif SDL_PLATFORM_APPLE
  /* use realpath to resolve a symlink if the process was launched from one.
  ** This happens when Homebrew installs a cack and creates a symlink in
  ** /usr/loca/bin for launching the executable from the command line. */
  unsigned size = sz;
  char exepath[size];
  _NSGetExecutablePath(exepath, &size);
  realpath(exepath, buf);
#elif __FreeBSD__
  size_t len = sz;
  const int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PATHNAME, -1 };
  sysctl(mib, 4, buf, &len, NULL, 0);
#else
  *buf = 0;
#endif
}

#ifdef _WIN32
#define PRAGTICAL_OS_HOME "USERPROFILE"
#define PRAGTICAL_PATHSEP_PATTERN "\\\\"
#define PRAGTICAL_NONPATHSEP_PATTERN "[^\\\\]+"
#else
#define PRAGTICAL_OS_HOME "HOME"
#define PRAGTICAL_PATHSEP_PATTERN "/"
#define PRAGTICAL_NONPATHSEP_PATTERN "[^/]+"
#endif

#ifdef SDL_PLATFORM_APPLE
void enable_momentum_scroll();
#ifdef MACOS_USE_BUNDLE
void set_macos_bundle_resources(lua_State *L);
#endif
#endif

#ifndef PRAGTICAL_ARCH_TUPLE
  // https://learn.microsoft.com/en-us/cpp/preprocessor/predefined-macros?view=msvc-140
  #if defined(__x86_64__) || defined(_M_AMD64) || defined(__MINGW64__)
    #define ARCH_PROCESSOR "x86_64"
  #elif defined(__i386__) || defined(_M_IX86) || defined(__MINGW32__)
    #define ARCH_PROCESSOR "x86"
  #elif defined(__aarch64__) || defined(_M_ARM64) || defined (_M_ARM64EC)
    #define ARCH_PROCESSOR "aarch64"
  #elif defined(__arm__) || defined(_M_ARM)
    #define ARCH_PROCESSOR "arm"
  #endif

  #if _WIN32
    #define ARCH_PLATFORM "windows"
  #elif __linux__
    #define ARCH_PLATFORM "linux"
  #elif __FreeBSD__
    #define ARCH_PLATFORM "freebsd"
  #elif SDL_PLATFORM_APPLE
    #define ARCH_PLATFORM "darwin"
  #elif __serenity__
    #define ARCH_PLATFORM "serenity"
  #else
  #endif

  #if !defined(ARCH_PROCESSOR) || !defined(ARCH_PLATFORM)
    #error "Please define -DPRAGTICAL_ARCH_TUPLE."
  #endif

  #define PRAGTICAL_ARCH_TUPLE ARCH_PROCESSOR "-" ARCH_PLATFORM
#endif

#ifdef LUA_JIT
  #define PRAGTICAL_LUAJIT "true"
#else
  #define PRAGTICAL_LUAJIT "false"
#endif

/* Application state shared across SDL3 callbacks. */
typedef struct {
  lua_State *L;
  int        argc;
  char     **argv;
  int        has_restarted;
} AppState;

/* Lua init-code: loads and starts the core.  core.run() is now non-blocking
 * (it only sets up the run-loop state); SDL_AppIterate drives the loop by
 * calling core.run_step() on every frame. */
static const char *init_code =
  "local core\n"
  "local os_exit = os.exit\n"
  "os.exit = function(code, close)\n"
  "  os_exit(code, close == nil and true or close)\n"
  "end\n"
  "xpcall(function()\n"
  "  local match = require('utf8extra').match\n"
  "  HOME = os.getenv('" PRAGTICAL_OS_HOME "')\n"
  "  LUAJIT = " PRAGTICAL_LUAJIT "\n"
  "  local exedir = match(EXEFILE, '^(.*)" PRAGTICAL_PATHSEP_PATTERN PRAGTICAL_NONPATHSEP_PATTERN "$')\n"
  "  local prefix = os.getenv('PRAGTICAL_PREFIX') or match(exedir, '^(.*)" PRAGTICAL_PATHSEP_PATTERN "bin$')\n"
  "  dofile((MACOS_RESOURCES or (prefix and prefix .. '/share/pragtical' or exedir .. '/data')) .. '/core/start.lua')\n"
  "  core = require(os.getenv('PRAGTICAL_RUNTIME') or 'core')\n"
  "  core.init()\n"
  "  core.run()\n"
  "end, function(err)\n"
  "  local error_path = 'error.txt'\n"
  "  io.stdout:write('Error: '..tostring(err)..'\\n')\n"
  "  io.stdout:write(debug.traceback('', 2)..'\\n')\n"
  "  if core and core.on_error then\n"
  "    error_path = USERDIR .. PATHSEP .. error_path\n"
  "    pcall(core.on_error, err)\n"
  "  else\n"
  "    local fp = io.open(error_path, 'wb')\n"
  "    fp:write('Error: ' .. tostring(err) .. '\\n')\n"
  "    fp:write(debug.traceback('', 2)..'\\n')\n"
  "    fp:close()\n"
  "    error_path = system.absolute_path(error_path)\n"
  "  end\n"
  "  system.show_fatal_error('Pragtical internal error',\n"
  "    'An internal error occurred in a critical part of the application.\\n\\n'..\n"
  "    'Error: '..tostring(err)..'\\n\\n'..\n"
  "    'Details can be found in \\\"'..error_path..'\\\"')\n"
  "  os.exit(1)\n"
  "end)\n";

/* (Re-)create a Lua interpreter and run the init code. */
static bool init_lua_state(AppState *app) {
  app->L = luaL_newstate();
  luaL_openlibs(app->L);
  api_load_libs(app->L);

  lua_newtable(app->L);
  for (int i = 0; i < app->argc; i++) {
    lua_pushstring(app->L, app->argv[i]);
    lua_rawseti(app->L, -2, i + 1);
  }
  lua_setglobal(app->L, "ARGS");

  lua_pushstring(app->L, SDL_GetPlatform());
  lua_setglobal(app->L, "PLATFORM");

  lua_pushstring(app->L, PRAGTICAL_ARCH_TUPLE);
  lua_setglobal(app->L, "ARCH");

  lua_pushboolean(app->L, app->has_restarted);
  lua_setglobal(app->L, "RESTARTED");

  char exename[2048];
  get_exe_filename(exename, sizeof(exename));
  if (*exename) {
    lua_pushstring(app->L, exename);
  } else {
    lua_pushstring(app->L, app->argv[0]);
  }
  lua_setglobal(app->L, "EXEFILE");

#ifdef SDL_PLATFORM_APPLE
  enable_momentum_scroll();
  #ifdef MACOS_USE_BUNDLE
    set_macos_bundle_resources(app->L);
  #endif
#endif

  SDL_SetEventEnabled(SDL_EVENT_TEXT_INPUT, true);
  SDL_SetEventEnabled(SDL_EVENT_TEXT_EDITING, true);

  if (luaL_loadstring(app->L, init_code)) {
    fprintf(stderr, "internal error when starting the application\n");
    return false;
  }
  lua_pcall(app->L, 0, 0, 0);
  return true;
}


SDL_AppResult SDL_AppInit(void **appstate, int argc, char *argv[]) {
#ifndef _WIN32
  signal(SIGPIPE, SIG_IGN);
#else
  /* Allow console output when called from pragtical.com wrapper.
   * See: https://stackoverflow.com/q/73987850
   *      https://stackoverflow.com/q/17111308
  */
  if (getenv("PRAGTICAL_COM_WRAP") && AttachConsole(ATTACH_PARENT_PROCESS)) {
    freopen("CONOUT$", "w", stdout);
    freopen("CONOUT$", "w", stderr);
    freopen("CONIN$", "r", stdin);
  }
#endif

#ifdef __linux__
  /* Use wayland by default if SDL_VIDEODRIVER not set and session type wayland */
  if (getenv("SDL_VIDEODRIVER") == NULL) {
    const char *session_type = getenv("XDG_SESSION_TYPE");
    if (session_type && strcmp(session_type, "wayland") == 0) {
      SDL_SetHint(SDL_HINT_VIDEO_DRIVER, "wayland");
    }
  }
#endif

  SDL_SetAppMetadata("Pragtical", PRAGTICAL_PROJECT_VERSION_STR, "dev.pragtical.Pragtical");
  if (!SDL_Init(SDL_INIT_EVENTS)) {
    fprintf(stderr, "Error initializing sdl: %s", SDL_GetError());
    return SDL_APP_FAILURE;
  }
  SDL_SetEventEnabled(SDL_EVENT_DROP_FILE, true);

  if (ren_init() != 0) {
    fprintf(stderr, "Error initializing renderer: %s\n", SDL_GetError());
    return SDL_APP_FAILURE;
  }

  if (!init_custom_events()) {
    fprintf(stderr, "Error initializing custom events: %s\n", SDL_GetError());
    return SDL_APP_FAILURE;
  }

  AppState *app = SDL_malloc(sizeof(AppState));
  if (!app) {
    fprintf(stderr, "Out of memory\n");
    return SDL_APP_FAILURE;
  }
  app->argc         = argc;
  app->argv         = argv;
  app->has_restarted = 0;
  app->L            = NULL;
  *appstate = app;

  if (!init_lua_state(app))
    return SDL_APP_FAILURE;

  return SDL_APP_CONTINUE;
}


SDL_AppResult SDL_AppEvent(void *appstate, SDL_Event *event) {
  (void)appstate;
  system_push_event(event);
  return SDL_APP_CONTINUE;
}


SDL_AppResult SDL_AppIterate(void *appstate) {
  AppState *app = appstate;

  /* Call core.run_step() — one frame of the main loop.
   * Returns true  → keep running
   * Returns false → quit or restart */
  lua_getglobal(app->L, "core");
  if (!lua_istable(app->L, -1)) {
    lua_pop(app->L, 1);
    return SDL_APP_FAILURE;
  }
  lua_getfield(app->L, -1, "run_step");
  lua_remove(app->L, -2); /* remove 'core' table */

  if (!lua_isfunction(app->L, -1)) {
    lua_pop(app->L, 1);
    return SDL_APP_FAILURE;
  }

  if (lua_pcall(app->L, 0, 1, 0) != LUA_OK) {
    fprintf(stderr, "Error in core.run_step: %s\n", lua_tostring(app->L, -1));
    lua_pop(app->L, 1);
    return SDL_APP_FAILURE;
  }

  bool should_continue = lua_toboolean(app->L, -1);
  lua_pop(app->L, 1);

  if (!should_continue) {
    /* Distinguish between quit and restart. */
    lua_getglobal(app->L, "core");
    lua_getfield(app->L, -1, "restart_request");
    bool restart = lua_toboolean(app->L, -1);
    lua_pop(app->L, 2);

    if (restart) {
      /* Re-initialize the Lua state in place — mirrors the goto in old main(). */
      lua_close(app->L);
      app->L = NULL;
      app->has_restarted = 1;
      if (!init_lua_state(app))
        return SDL_APP_FAILURE;
      return SDL_APP_CONTINUE;
    }

    return SDL_APP_SUCCESS;
  }

  return SDL_APP_CONTINUE;
}


void SDL_AppQuit(void *appstate, SDL_AppResult result) {
  (void)result;
  AppState *app = appstate;
  if (app) {
    if (app->L) lua_close(app->L);
    SDL_free(app);
  }
  free_custom_events();
  ren_free();
}

