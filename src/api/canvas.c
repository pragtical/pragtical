#include <lauxlib.h>
#include <lua.h>
#include <string.h>
#include <SDL3/SDL.h>
#include <SDL3_image/SDL_image.h>
#include <assert.h>

#include "api.h"
#include "utils/lxlauxlib.h"
#include "../renderer.h"
#include "../rencache.h"

extern int RENDERER_FONT_REF;
extern int RENDERER_CANVAS_REF;

static int f_new(lua_State *L) {
  lua_Number w = luaL_checknumber(L, 1);
  lua_Number h = luaL_checknumber(L, 2);
  RenColor color = luaXL_checkcolor(L, 3, 0);
  bool transparency = luaXL_optboolean(L, 4, true);

  SDL_Surface *surface = SDL_CreateSurface(
    w, h, transparency ? SDL_PIXELFORMAT_RGBA32 : SDL_PIXELFORMAT_RGB24
  );
  SDL_FillSurfaceRect(
    surface,
    NULL,
    SDL_MapSurfaceRGBA(surface, color.r, color.g, color.b, color.a)
  );

  RenCache *canvas = lua_newuserdata(L, sizeof(RenCache));
  luaL_setmetatable(L, API_TYPE_CANVAS);
  rencache_init(canvas);
  canvas->rensurface.surface = surface;
  canvas->rensurface.scale_x = 1;
  canvas->rensurface.scale_y = 1;
  rencache_begin_frame(canvas);

  return 1;
}


static int f_load_image(lua_State *L) {
  size_t len;
  const char *file = luaL_checklstring(L, 1, &len);

  SDL_Surface *surface = IMG_Load(file);
  if (!surface) goto error;

  if (surface->format != SDL_PIXELFORMAT_RGBA32) {
    SDL_Surface *new = SDL_ConvertSurface(surface, SDL_PIXELFORMAT_RGBA32);
    SDL_DestroySurface(surface);
    if (!new) goto error;
    surface = new;
  }

  RenCache *canvas = lua_newuserdata(L, sizeof(RenCache));
  luaL_setmetatable(L, API_TYPE_CANVAS);
  rencache_init(canvas);
  canvas->rensurface.surface = surface;
  canvas->rensurface.scale_x = 1;
  canvas->rensurface.scale_y = 1;
  rencache_begin_frame(canvas);
  return 1;

error:
  lua_pushnil(L);
  lua_pushstring(L, SDL_GetError());
  return 2;
}


static int f_get_size(lua_State *L) {
  RenCache *canvas = luaL_checkudata(L, 1, API_TYPE_CANVAS);
  lua_pushinteger(L, canvas->rensurface.surface->w);
  lua_pushinteger(L, canvas->rensurface.surface->h);
  return 2;
}


static int f_get_pixels(lua_State *L) {
  RenCache *canvas = luaL_checkudata(L, 1, API_TYPE_CANVAS);

  lua_Integer x = luaL_optinteger(L, 2, 0);
  lua_Integer y = luaL_optinteger(L, 3, 0);
  lua_Integer w = luaL_optinteger(L, 4, canvas->rensurface.surface->w);
  lua_Integer h = luaL_optinteger(L, 5, canvas->rensurface.surface->h);

  SDL_Surface *dst = SDL_CreateSurface(w, h, SDL_PIXELFORMAT_RGBA32);
  SDL_Rect rect = { .x = x, .y = y, .w = w, .h = h };
  SDL_BlitSurface(canvas->rensurface.surface, &rect, dst, NULL);

  const SDL_PixelFormatDetails *details = SDL_GetPixelFormatDetails(SDL_PIXELFORMAT_RGBA32);
  lua_pushlstring(L, dst->pixels, details->bytes_per_pixel * w * h);

  SDL_DestroySurface(dst);
  return 1;
}


static int f_set_pixels(lua_State *L) {
  RenCache *canvas = luaL_checkudata(L, 1, API_TYPE_CANVAS);

  size_t len;
  const char *bytes = luaL_checklstring(L, 2, &len);

  lua_Integer x = luaL_checkinteger(L, 3);
  lua_Integer y = luaL_checkinteger(L, 4);
  lua_Integer w = luaL_checkinteger(L, 5);
  lua_Integer h = luaL_checkinteger(L, 6);
  luaL_argcheck(L, w > 0, 5, "must be a positive non-zero integer");
  luaL_argcheck(L, h > 0, 6, "must be a positive non-zero integer");
  RenRect rect = { .x = x, .y = y, .width = w, .height = h };

  rencache_draw_pixels(canvas, rect, bytes, len);
  return 0;
}


static int f_copy(lua_State *L) {
  // TODO: should we make this COW, so when the copy or the original get changed, we make the actual copy
  RenCache *canvas = luaL_checkudata(L, 1, API_TYPE_CANVAS);
  lua_Number x = luaL_optnumber(L, 2, 0);
  lua_Number y = luaL_optnumber(L, 3, 0);
  lua_Number w = luaL_optnumber(L, 4, canvas->rensurface.surface->w);
  lua_Number h = luaL_optnumber(L, 5, canvas->rensurface.surface->h);
  lua_Number new_w = luaL_optnumber(L, 6, w);
  lua_Number new_h = luaL_optnumber(L, 7, h);
  const char *mode_str = luaL_optstring(L, 8, "linear");
  SDL_ScaleMode mode = SDL_SCALEMODE_INVALID;
  if (strcmp(mode_str, "nearest") == 0) {
    mode = SDL_SCALEMODE_NEAREST;
  } else if (strcmp(mode_str, "linear") == 0) {
    mode = SDL_SCALEMODE_LINEAR;
  }
  #if 0 // SDL_SCALEMODE_PIXELART doesn't seem to be actually available (as of SDL 3.2.20)
  else if (strcmp(mode_str, "pixelart") == 0) {
    mode = SDL_SCALEMODE_PIXELART;
  }
  #endif

  RenCache *new_canvas = lua_newuserdata(L, sizeof(RenCache));
  luaL_setmetatable(L, API_TYPE_CANVAS);
  rencache_init(new_canvas);

  bool full_surface = (
    x == 0 && y == 0
    &&
    w == canvas->rensurface.surface->w
    &&
    h == canvas->rensurface.surface->h
  );
  bool scaled = (new_w != w || new_h != h);
  SDL_Surface *surface_copy;
  if (full_surface && !scaled) {
    surface_copy = SDL_DuplicateSurface(canvas->rensurface.surface);
    // DuplicateSurface copies the clip rect, so we reset it
    SDL_SetSurfaceClipRect(surface_copy, NULL);
  } else if (full_surface) {
    surface_copy = SDL_ScaleSurface(canvas->rensurface.surface, new_w, new_h, mode);
  } else {
    surface_copy = SDL_CreateSurface(new_w, new_h, canvas->rensurface.surface->format);
    SDL_Rect src_rect = {.x = x, .y = y, .w = w, .h = h};
    SDL_BlitSurfaceScaled(canvas->rensurface.surface, &src_rect, surface_copy, NULL, mode);
  }

  if(!surface_copy) {
    lua_pushnil(L);
    lua_pushfstring(L, "Error creating new canvas: %s", SDL_GetError());
    return 2;
  }

  new_canvas->rensurface.surface = surface_copy;
  new_canvas->rensurface.scale_x = 1;
  new_canvas->rensurface.scale_y = 1;
  rencache_begin_frame(new_canvas);

  return 1;
}


static int f_scaled(lua_State *L) {
  RenCache *canvas = luaL_checkudata(L, 1, API_TYPE_CANVAS);
  lua_Number new_w = luaL_checknumber(L, 2);
  lua_Number new_h = luaL_checknumber(L, 3);
  const char *mode = luaL_optstring(L, 4, "linear");

  lua_settop(L, 1); // keep only the canvas

  lua_pushnumber(L, 0); // x
  lua_pushnumber(L, 0); // y
  lua_pushnumber(L, canvas->rensurface.surface->w); // w
  lua_pushnumber(L, canvas->rensurface.surface->h); // h
  lua_pushnumber(L, new_w);
  lua_pushnumber(L, new_h);
  lua_pushstring(L, mode);

  return f_copy(L);
}


static int f_clear(lua_State *L) {
  RenCache *canvas = luaL_checkudata(L, 1, API_TYPE_CANVAS);

  RenColor color;
  if (lua_isnoneornil(L, 2))
    color = (RenColor) { .r = 0, .g = 0, .b = 0, .a = 0 };
  else
    color = luaXL_checkcolor(L, 6, 255);

  RECT_TYPE w, h;
  ren_get_size(&canvas->rensurface, &w, &h);
  RenRect rect = { .x = 0, .y = 0, .width = w, .height = h };

  rencache_draw_rect(canvas, rect, color, true);

  return 0;
}


static int f_set_clip_rect(lua_State *L) {
  RenCache *canvas = luaL_checkudata(L, 1, API_TYPE_CANVAS);
  lua_Number x = luaL_checknumber(L, 2);
  lua_Number y = luaL_checknumber(L, 3);
  lua_Number w = luaL_checknumber(L, 4);
  lua_Number h = luaL_checknumber(L, 5);

  RenRect rect = { .x = x, .y = y, .width = w, .height = h };
  rencache_set_clip_rect(canvas, rect);

  return 0;
}


static int f_draw_rect(lua_State *L) {
  RenCache *canvas = luaL_checkudata(L, 1, API_TYPE_CANVAS);
  lua_Number x = luaL_checknumber(L, 2);
  lua_Number y = luaL_checknumber(L, 3);
  lua_Number w = luaL_checknumber(L, 4);
  lua_Number h = luaL_checknumber(L, 5);
  RenColor color = luaXL_checkcolor(L, 6, 255);
  bool replace = luaXL_optboolean(L, 7, false);

  RenRect rect = { .x = x, .y = y, .width = w, .height = h };
  rencache_draw_rect(canvas, rect, color, replace);

  return 0;
}


static int f_draw_poly(lua_State *L) {
  RenCache *canvas = luaL_checkudata(L, 1, API_TYPE_CANVAS);

  static const char normal_tag[] = { POLY_NORMAL };
  static const char conic_bezier_tag[] = { POLY_NORMAL, POLY_CONTROL_CONIC, POLY_NORMAL };
  static const char cubic_bezier_tag[] = { POLY_NORMAL, POLY_CONTROL_CUBIC, POLY_CONTROL_CUBIC, POLY_NORMAL };

  luaL_checktype(L, 2, LUA_TTABLE);
  RenColor color = luaXL_checkcolor(L, 3, 255);
  lua_settop(L, 3);

  int len = luaL_len(L, 2);
  RenPoint *points = NULL; int npoints = 0;
  for (int i = 1; i <= len; i++) {
    lua_rawgeti(L, 2, i); luaL_checktype(L, -1, LUA_TTABLE);
    const char *current_tag = NULL; int coord_len = luaL_len(L, -1);
    switch (coord_len) {
      case 2: current_tag = normal_tag;       break; // 1 curve point
      case 6: current_tag = conic_bezier_tag; break; // a conic bezier with 2 curve points and 1 control point
      case 8: current_tag = cubic_bezier_tag; break; // a cubic bezier with 2 curve points and 2 control points
      default: return luaL_error(L, "invalid number of points, expected 2, 6 and 8, got %d", coord_len);
    }
    if (npoints + coord_len / 2 > MAX_POLY_POINTS) return luaL_error(L, "too many points");
    points = SDL_realloc(points, (npoints + coord_len / 2) * sizeof(RenPoint));
    for (int lidx = 1; lidx <= coord_len; lidx += 2) {
      points[npoints].x = (lua_rawgeti(L, -1, lidx),   luaL_checknumber(L, -1));
      points[npoints].y = (lua_rawgeti(L, -2, lidx+1), luaL_checknumber(L, -1));
      points[npoints++].tag = current_tag[(lidx-1)/2];
      lua_pop(L, 2);
    }
  }
  RenRect res = rencache_draw_poly(canvas, points, npoints, color);
  if (points) SDL_free(points);
  lua_pushinteger(L, res.x);     lua_pushinteger(L, res.y);
  lua_pushinteger(L, res.width); lua_pushinteger(L, res.height);
  return 4;
}


static int f_draw_text(lua_State *L) {
  RenCache *canvas = luaL_checkudata(L, 1, API_TYPE_CANVAS);
  RenFont* fonts[FONT_FALLBACK_MAX];
  font_retrieve(L, fonts, 2);

#ifndef LUA_JITLIBNAME
  // stores a reference to this font to the reference table
  lua_rawgeti(L, LUA_REGISTRYINDEX, RENDERER_FONT_REF);
  if (lua_istable(L, -1))
  {
    lua_pushvalue(L, 1);
    lua_pushboolean(L, 1);
    lua_rawset(L, -3);
  } else {
    fprintf(stderr, "warning: failed to reference count fonts\n");
  }
  lua_pop(L, 1);
#endif

  size_t len;
  const char *text = luaL_checklstring(L, 3, &len);
  double x = luaL_checknumber(L, 4);
  int y = luaL_checkinteger(L, 5);
  RenColor color = luaXL_checkcolor(L, 6, 255);
  RenTab tab = luaXL_checktab(L, 7);

  double end_x = rencache_draw_text(canvas, fonts, text, len, x, y, color, tab);
  lua_pushnumber(L, end_x);

  return 1;
}


static int f_draw_canvas(lua_State *L) {
  RenCache *canvas_dst = luaL_checkudata(L, 1, API_TYPE_CANVAS);
  RenCache *canvas_src = luaL_checkudata(L, 2, API_TYPE_CANVAS);

  lua_Number x = luaL_checknumber(L, 3);
  lua_Number y = luaL_checknumber(L, 4);
  bool blend = luaXL_optboolean(L, 5, true);

  SDL_Rect rect = { .x = x, .y = y, .w = canvas_src->rensurface.surface->w, .h = canvas_src->rensurface.surface->h };
  SDL_BlendMode src_mode;
  SDL_GetSurfaceBlendMode(canvas_src->rensurface.surface, &src_mode);
  SDL_SetSurfaceBlendMode(canvas_src->rensurface.surface, blend ? SDL_BLENDMODE_BLEND : SDL_BLENDMODE_NONE);

  SDL_BlitSurface(canvas_src->rensurface.surface, NULL, canvas_dst->rensurface.surface, &rect);

  SDL_SetSurfaceBlendMode(canvas_src->rensurface.surface, src_mode);

  return 0;
}


static int f_render(lua_State *L) {
  RenCache* canvas = luaL_checkudata(L, 1, API_TYPE_CANVAS);
  rencache_end_frame(canvas);
  return 0;
}


static int f_save_image(lua_State *L) {
  RenCache* canvas = luaL_checkudata(L, 1, API_TYPE_CANVAS);
  const char *file = luaL_checkstring(L, 2);
  const char *type = luaL_optstring(L, 3, "png");
  int quality = luaL_optinteger(L, 3, 100);

  bool saved = false;
  if (strcmp(type, "png") == 0) {
    saved = IMG_SavePNG(canvas->rensurface.surface, file);
  } else if (strcmp(type, "jpg") == 0) {
    saved = IMG_SaveJPG(canvas->rensurface.surface, file, quality);
  } else if (strcmp(type, "avif") == 0) {
    saved = IMG_SaveAVIF(canvas->rensurface.surface, file, quality);
  }

  if (saved) {
    lua_pushboolean(L, true);
    return 1;
  }

  lua_pushboolean(L, false);
  lua_pushstring(L, SDL_GetError());
  return 2;
}


static int f_gc(lua_State *L) {
  RenCache* canvas = luaL_checkudata(L, 1, API_TYPE_CANVAS);
  if (canvas->rensurface.surface)
    SDL_DestroySurface(canvas->rensurface.surface);
  rencache_uninit(canvas);
  return 0;
}


static const luaL_Reg canvasLib[] = {
  { "get_pixels",    f_get_pixels    },
  { "set_pixels",    f_set_pixels    },
  { "get_size",      f_get_size      },
  { "copy",          f_copy          },
  { "scaled",        f_scaled        },
  { "clear",         f_clear         },
  { "set_clip_rect", f_set_clip_rect },
  { "draw_rect",     f_draw_rect     },
  { "draw_text",     f_draw_text     },
  { "draw_poly",     f_draw_poly     },
  { "draw_canvas",   f_draw_canvas   },
  { "render",        f_render        },
  { "save_image",    f_save_image    },
  { "__gc",          f_gc            },
  { NULL,            NULL            }
};

static const luaL_Reg lib[] = {
  { "new",        f_new        },
  { "load_image", f_load_image },
  { NULL,         NULL         }
};

int luaopen_canvas(lua_State *L) {
  luaL_newlib(L, lib);

  luaL_newmetatable(L, API_TYPE_CANVAS);
  luaL_setfuncs(L, canvasLib, 0);
  lua_setfield(L, -1, "__index");

  return 1;
}
