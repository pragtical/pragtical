#include <lua.h>
#include <SDL3/SDL.h>
#include "api.h"
#include "renderer/window.h"
#include "renderer/cache.h"
#include "renderer/backend.h"

static RenWindow *persistant_window = NULL;

static void init_window_icon(SDL_Window *window) {
#if !defined(_WIN32) && !defined(__APPLE__)
  #include "../resources/icons/icon.inl"
  (void) icon_rgba_len; /* unused */
  SDL_PixelFormat format = SDL_GetPixelFormatForMasks(32, 0x000000ff, 0x0000ff00, 0x00ff0000, 0xff000000);
  SDL_Surface *surf = SDL_CreateSurfaceFrom(64, 64, format, icon_rgba, 64 * 4);
  SDL_SetWindowIcon(window, surf);
  SDL_DestroySurface(surf);
#endif
}

static int f_renwin_create(lua_State *L) {
  const char *title = luaL_checkstring(L, 1);
  float width = luaL_optnumber(L, 2, 0);
  float height = luaL_optnumber(L, 3, 0);

  if (video_init() != 0)
    return luaL_error(L, "Error creating pragtical window: %s", SDL_GetError());

  if (width < 1 || height < 1) {
    const SDL_DisplayMode* dm = SDL_GetCurrentDisplayMode(SDL_GetPrimaryDisplay());

    if (width < 1) {
      width = dm->w * 0.8;
    }
    if (height < 1) {
      height = dm->h * 0.8;
    }
  }

  SDL_Window *window = SDL_CreateWindow(
    title, width, height,
    SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY | SDL_WINDOW_HIDDEN
  );
  if (!window) {
    return luaL_error(L, "Error creating pragtical window: %s", SDL_GetError());
  }
  init_window_icon(window);

  RenWindow **window_renderer = (RenWindow**)lua_newuserdata(L, sizeof(RenWindow*));
  luaL_setmetatable(L, API_TYPE_RENWINDOW);

  *window_renderer = ren_create(window);

  /* Set a minimum size to prevent too small to see issues on unmaximize.
  ** Needs to be set after renderer to work: libsdl-org/SDL/issues/1408 */
  SDL_SetWindowMinimumSize(window, 240, 180);

  return 1;
}

static int f_renwin_gc(lua_State *L) {
  RenWindow *window_renderer = *(RenWindow**)luaL_checkudata(L, 1, API_TYPE_RENWINDOW);
  if (window_renderer != persistant_window)
    ren_destroy(window_renderer);

  return 0;
}

static int f_renwin_get_size(lua_State *L) {
  RenWindow *window_renderer = *(RenWindow**)luaL_checkudata(L, 1, API_TYPE_RENWINDOW);
  int w, h;
  RenSurface rs = rencache_get_surface(&window_renderer->cache);
  ren_get_size(&rs, &w, &h);
  lua_pushnumber(L, w);
  lua_pushnumber(L, h);
  return 2;
}

static int f_renwin_set_vsync(lua_State *L) {
  RenWindow *window_renderer = *(RenWindow**)luaL_checkudata(L, 1, API_TYPE_RENWINDOW);
  bool enabled = lua_toboolean(L, 2);
  const RenBackend *backend = window_renderer->cache.backend;
  if (backend && backend->set_vsync)
    backend->set_vsync(window_renderer, enabled);
  return 0;
}

static int f_renwin_get_renderer_info(lua_State *L) {
  RenWindow *window_renderer = *(RenWindow**)luaL_checkudata(L, 1, API_TYPE_RENWINDOW);
  const RenBackend *backend = window_renderer->cache.backend;
  RenRendererInfo info = {
    .backend = backend ? backend->name : "",
    .power = NULL,
    .device = NULL,
  };
  if (backend && backend->get_renderer_info)
    backend->get_renderer_info(window_renderer, &info);

  lua_createtable(L, 0, 3);
  lua_pushstring(L, info.backend ? info.backend : "");
  lua_setfield(L, -2, "backend");
  if (info.power) {
    lua_pushstring(L, info.power);
    lua_setfield(L, -2, "power");
  }
  if (info.device) {
    lua_pushstring(L, info.device);
    lua_setfield(L, -2, "device");
  }
  return 1;
}

static int f_renwin_persist(lua_State *L) {
  RenWindow *window_renderer = *(RenWindow**)luaL_checkudata(L, 1, API_TYPE_RENWINDOW);

  persistant_window = window_renderer;
  return 0;
}

static int f_renwin_restore(lua_State *L) {
  if (!persistant_window) {
    lua_pushnil(L);
  }
  else {
    RenWindow **window_renderer = (RenWindow**)lua_newuserdata(L, sizeof(RenWindow*));
    luaL_setmetatable(L, API_TYPE_RENWINDOW);

    *window_renderer = persistant_window;
  }

  return 1;
}

static int f_get_refresh_rate(lua_State *L) {
  RenWindow *window_renderer = *(RenWindow**)luaL_checkudata(L, 1, API_TYPE_RENWINDOW);

  SDL_DisplayID display = SDL_GetDisplayForWindow(renwin_get_sdl_window(window_renderer));
  if (!display) return 0;

  const SDL_DisplayMode *mode;
  if ((mode = SDL_GetCurrentDisplayMode(display)) && mode->refresh_rate > 0)
    lua_pushnumber(L, SDL_round(mode->refresh_rate));
  else if ((mode = SDL_GetDesktopDisplayMode(display)) && mode->refresh_rate > 0)
    lua_pushnumber(L, SDL_round(mode->refresh_rate));
  else
    lua_pushnil(L);

  return 1;
}

static int f_get_color(lua_State *L) {
  RenWindow *window_renderer = *(RenWindow**)luaL_checkudata(L, 1, API_TYPE_RENWINDOW);
  int x = luaL_optinteger(L, 2, 0);
  int y = luaL_optinteger(L, 3, 0);

  SDL_Color color = {0, 0, 0, 255};
  RenSurface rs = rencache_get_surface(&window_renderer->cache);
  int px = x * rs.scale_x;
  int py = y * rs.scale_y;

  if (rs.surface && px >= 0 && py >= 0 && px < rs.surface->w && py < rs.surface->h) {
    SDL_Surface *surface = NULL;
    const RenBackend *backend = window_renderer->cache.backend;
    if (backend && backend->capture_window)
      surface = backend->capture_window(&window_renderer->cache, (RenRect){ px, py, 1, 1 });

    if (surface) {
      SDL_ReadSurfacePixel(surface, 0, 0, &color.r, &color.g, &color.b, &color.a);
      SDL_DestroySurface(surface);
    } else {
      SDL_ReadSurfacePixel(rs.surface, px, py, &color.r, &color.g, &color.b, &color.a);
    }
  }

  lua_createtable(L, 4, 0);
  lua_pushinteger(L, color.r);
  lua_rawseti(L, -2, 1);
  lua_pushinteger(L, color.g);
  lua_rawseti(L, -2, 2);
  lua_pushinteger(L, color.b);
  lua_rawseti(L, -2, 3);
  lua_pushinteger(L, color.a);
  lua_rawseti(L, -2, 4);

  return 1;
}

static const luaL_Reg renwindow_lib[] = {
  { "create",           f_renwin_create     },
  { "__gc",             f_renwin_gc         },
  { "get_size",         f_renwin_get_size   },
  { "get_refresh_rate", f_get_refresh_rate  },
  { "set_vsync",        f_renwin_set_vsync  },
  { "get_renderer_info", f_renwin_get_renderer_info },
  { "get_color",        f_get_color         },
  { "_persist",         f_renwin_persist    },
  { "_restore",         f_renwin_restore    },
  {NULL, NULL}
};

int luaopen_renwindow(lua_State* L) {
  luaL_newmetatable(L, API_TYPE_RENWINDOW);
  luaL_setfuncs(L, renwindow_lib, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  return 1;
}
