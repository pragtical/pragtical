#include <string.h>
#include <assert.h>
#include <lua.h>

#include "api.h"
#include "../renderer.h"
#include "../rencache.h"
#include "../renwindow.h"
#include "lua.h"
#include "utils/lxlauxlib.h"

// a reference index to a table that stores fonts during a render cycle
static int RENDERER_FONT_REF = LUA_NOREF;
// a reference index to a table that stores canvases during a render cycle
static int RENDERER_CANVAS_REF = LUA_NOREF;

static int font_get_options(
  lua_State *L,
  ERenFontAntialiasing *antialiasing,
  ERenFontHinting *hinting,
  int *style
) {
  if (lua_gettop(L) > 2 && lua_istable(L, 3)) {
    lua_getfield(L, 3, "antialiasing");
    if (lua_isstring(L, -1)) {
      const char *antialiasing_str = lua_tostring(L, -1);
      if (antialiasing_str) {
        if (strcmp(antialiasing_str, "none") == 0) {
          *antialiasing = FONT_ANTIALIASING_NONE;
        } else if (strcmp(antialiasing_str, "grayscale") == 0) {
          *antialiasing = FONT_ANTIALIASING_GRAYSCALE;
        } else if (strcmp(antialiasing_str, "subpixel") == 0) {
          *antialiasing = FONT_ANTIALIASING_SUBPIXEL;
        } else {
          return luaL_error(
            L,
            "error in font options, unknown antialiasing option: \"%s\"",
            antialiasing_str
          );
        }
      }
    }
    lua_getfield(L, 3, "hinting");
    if (lua_isstring(L, -1)) {
      const char *hinting_str = lua_tostring(L, -1);
      if (hinting_str) {
        if (strcmp(hinting_str, "slight") == 0) {
          *hinting = FONT_HINTING_SLIGHT;
        } else if (strcmp(hinting_str, "none") == 0) {
          *hinting = FONT_HINTING_NONE;
        } else if (strcmp(hinting_str, "full") == 0) {
          *hinting = FONT_HINTING_FULL;
        } else {
          return luaL_error(
            L,
            "error in font options, unknown hinting option: \"%s\"",
            hinting
          );
        }
      }
    }
    int style_local = 0;
    lua_getfield(L, 3, "italic");
    if (lua_toboolean(L, -1))
      style_local |= FONT_STYLE_ITALIC;
    lua_getfield(L, 3, "bold");
    if (lua_toboolean(L, -1))
      style_local |= FONT_STYLE_BOLD;
    lua_getfield(L, 3, "underline");
    if (lua_toboolean(L, -1))
      style_local |= FONT_STYLE_UNDERLINE;
    lua_getfield(L, 3, "smoothing");
    if (lua_toboolean(L, -1))
      style_local |= FONT_STYLE_SMOOTH;
    lua_getfield(L, 3, "strikethrough");
    if (lua_toboolean(L, -1))
      style_local |= FONT_STYLE_STRIKETHROUGH;

    lua_pop(L, 5);

    if (style_local != 0)
      *style = style_local;
  }

  return 0;
}

static int f_font_load(lua_State *L) {
  const char *filename  = luaL_checkstring(L, 1);
  float size = luaL_checknumber(L, 2);
  int style = 0;
  ERenFontHinting hinting = FONT_HINTING_SLIGHT;
  ERenFontAntialiasing antialiasing = FONT_ANTIALIASING_SUBPIXEL;

  int ret_code = font_get_options(L, &antialiasing, &hinting, &style);
  if (ret_code > 0)
    return ret_code;

  RenFont** font = lua_newuserdata(L, sizeof(RenFont*));
  *font = ren_font_load(filename, size, antialiasing, hinting, style);
  if (!*font)
    return luaL_error(L, "failed to load font: %s", SDL_GetError());
  luaL_setmetatable(L, API_TYPE_FONT);
  return 1;
}

static int f_font_copy(lua_State *L) {
  RenFont* fonts[FONT_FALLBACK_MAX];
  bool table = font_retrieve(L, fonts, 1);
  float size = lua_gettop(L) >= 2 ? luaL_checknumber(L, 2) : ren_font_group_get_height(fonts);
  int style = -1;
  ERenFontHinting hinting = -1;
  ERenFontAntialiasing antialiasing = -1;

  int ret_code = font_get_options(L, &antialiasing, &hinting, &style);
  if (ret_code > 0)
    return ret_code;

  if (table) {
    lua_newtable(L);
    luaL_setmetatable(L, API_TYPE_FONT);
  }
  for (int i = 0; i < FONT_FALLBACK_MAX && fonts[i]; ++i) {
    RenFont** font = lua_newuserdata(L, sizeof(RenFont*));
    *font = ren_font_copy(fonts[i], size, antialiasing, hinting, style);
    if (!*font)
      return luaL_error(L, "failed to copy font: %s", SDL_GetError());
    luaL_setmetatable(L, API_TYPE_FONT);
    if (table)
      lua_rawseti(L, -2, i+1);
  }
  return 1;
}

static int f_font_group(lua_State* L) {
  int table_size;
  luaL_checktype(L, 1, LUA_TTABLE);

  table_size = lua_rawlen(L, 1);
  if (table_size <= 0)
    return luaL_error(L, "failed to create font group: table is empty");
  if (table_size > FONT_FALLBACK_MAX)
    return luaL_error(L, "failed to create font group: table size too large");

  // we also need to ensure that there are no fontgroups inside it
  for (int i = 1; i <= table_size; i++) {
    if (lua_rawgeti(L, 1, i) != LUA_TUSERDATA)
      return luaL_typeerror(L, -1, API_TYPE_FONT "(userdata)");
    lua_pop(L, 1);
  }

  luaL_setmetatable(L, API_TYPE_FONT);
  return 1;
}

static int f_font_get_path(lua_State *L) {
  RenFont* fonts[FONT_FALLBACK_MAX];
  bool table = font_retrieve(L, fonts, 1);

  if (table) {
    lua_newtable(L);
  }
  for (int i = 0; i < FONT_FALLBACK_MAX && fonts[i]; ++i) {
    const char* path = ren_font_get_path(fonts[i]);
    lua_pushstring(L, path);
    if (table)
      lua_rawseti(L, -2, i+1);
  }
  return 1;
}

static int f_font_set_tab_size(lua_State *L) {
  RenFont* fonts[FONT_FALLBACK_MAX]; font_retrieve(L, fonts, 1);
  int n = luaL_checknumber(L, 2);
  ren_font_group_set_tab_size(fonts, n);
  return 0;
}

static int f_font_gc(lua_State *L) {
  if (lua_istable(L, 1)) return 0; // do not run if its FontGroup
  RenFont** self = luaL_checkudata(L, 1, API_TYPE_FONT);
  ren_font_free(*self);

  return 0;
}

static int f_font_get_width(lua_State *L) {
  RenFont* fonts[FONT_FALLBACK_MAX]; font_retrieve(L, fonts, 1);
  size_t len;
  const char *text = luaL_checklstring(L, 2, &len);
  RenTab tab = luaXL_checktab(L, 3);

  lua_pushnumber(L, ren_font_group_get_width(fonts, text, len, tab, NULL));
  return 1;
}

static int f_font_get_height(lua_State *L) {
  RenFont* fonts[FONT_FALLBACK_MAX]; font_retrieve(L, fonts, 1);
  lua_pushnumber(L, ren_font_group_get_height(fonts));
  return 1;
}

static int f_font_get_size(lua_State *L) {
  RenFont* fonts[FONT_FALLBACK_MAX]; font_retrieve(L, fonts, 1);
  lua_pushnumber(L, ren_font_group_get_size(fonts));
  return 1;
}

static int f_font_set_size(lua_State *L) {
  RenFont* fonts[FONT_FALLBACK_MAX]; font_retrieve(L, fonts, 1);
  float size = luaL_checknumber(L, 2);
  float scale = 1.0;
#ifdef PRAGTICAL_USE_SDL_RENDERER
  RenWindow *window = ren_get_target_window();
  if (window != NULL) {
    scale = rencache_get_surface(&window->cache).scale_x;
  }
#endif
  ren_font_group_set_size(fonts, size, scale);
  return 0;
}

static int f_font_get_metadata(lua_State *L) {
  const char* filenames[FONT_FALLBACK_MAX];
  int fonts_found = 0;
  bool table = false;
  if (lua_type(L, 1) == LUA_TSTRING) {
    fonts_found = 1;
    filenames[0] = luaL_checkstring(L, 1);
  } else {
    RenFont* fonts[FONT_FALLBACK_MAX];
    table = font_retrieve(L, fonts, 1);
    if (table)
      lua_newtable(L);
    for (int i = 0; i < FONT_FALLBACK_MAX && fonts[i]; ++i) {
      filenames[i] = ren_font_get_path(fonts[i]);
      fonts_found++;
    }
  }

  int ret_count = 1;

  for(int f=0; f<fonts_found; f++) {
    int found = 0;
    FontMetaData *data;
    bool monospaced = false;
    int error = ren_font_get_metadata(filenames[f], &data, &found, &monospaced);

    if ((error == 0 && found > 0) || fonts_found > 1) {
      int meta_idx = table ? 3 : 2;
      lua_newtable(L);
      for (int i=0; i<found; i++) {
        switch(data[i].tag) {
          case FONT_FAMILY:
            lua_pushlstring(L, data[i].value, data[i].len);
            lua_setfield(L, meta_idx, "family");
            break;
          case FONT_SUBFAMILY:
            lua_pushlstring(L, data[i].value, data[i].len);
            lua_setfield(L, meta_idx, "subfamily");
            break;
          case FONT_ID:
            lua_pushlstring(L, data[i].value, data[i].len);
            lua_setfield(L, meta_idx, "id");
            break;
          case FONT_FULLNAME:
            lua_pushlstring(L, data[i].value, data[i].len);
            lua_setfield(L, meta_idx, "fullname");
            break;
          case FONT_VERSION:
            lua_pushlstring(L, data[i].value, data[i].len);
            lua_setfield(L, meta_idx, "version");
            break;
          case FONT_PSNAME:
            lua_pushlstring(L, data[i].value, data[i].len);
            lua_setfield(L, meta_idx, "psname");
            break;
          case FONT_TFAMILY:
            lua_pushlstring(L, data[i].value, data[i].len);
            lua_setfield(L, meta_idx, "tfamily");
            break;
          case FONT_TSUBFAMILY:
            lua_pushlstring(L, data[i].value, data[i].len);
            lua_setfield(L, meta_idx, "tsubfamily");
            break;
          case FONT_WWSFAMILY:
            lua_pushlstring(L, data[i].value, data[i].len);
            lua_setfield(L, meta_idx, "wwsfamily");
            break;
          case FONT_WWSSUBFAMILY:
            lua_pushlstring(L, data[i].value, data[i].len);
            lua_setfield(L, meta_idx, "wwssubfamily");
            break;
          case FONT_SAMPLETEXT:
            lua_pushlstring(L, data[i].value, data[i].len);
            lua_setfield(L, meta_idx, "sampletext");
            break;
        }
        free(data[i].value);
      }

      lua_pushboolean(L, monospaced);
      lua_setfield(L, meta_idx, "monospace");
      free(data);

      if (table)
        lua_rawseti(L, 2, f+1);
    } else if (error == 2) {
      lua_pushnil(L);
      lua_pushstring(L, "could not retrieve the font meta data");
      ret_count = 2;
      break;
    } else {
      lua_pushnil(L);
      lua_pushstring(L, "no meta data found");
      ret_count = 2;
      break;
    }
  }

  return ret_count;
}

static int color_value_error(lua_State *L, int idx, int table_idx) {
  const char *type, *msg;
  // generate an appropriate error message
  if (luaL_getmetafield(L, -1, "__name") == LUA_TSTRING) {
    type = lua_tostring(L, -1); // metatable name
  } else if (lua_type(L, -1) == LUA_TLIGHTUSERDATA) {
    type = "light userdata"; // special name for light userdata
  } else {
    type = lua_typename(L, lua_type(L, -1)); // default name
  }
  // the reason it went through so much hoops is to generate the correct error
  // message (with function name and proper index).
  msg = lua_pushfstring(L, "table[%d]: %s expected, got %s", table_idx, lua_typename(L, LUA_TNUMBER), type);
  return luaL_argerror(L, idx, msg);
}

static int get_color_value(lua_State *L, int idx, int table_idx) {
  lua_rawgeti(L, idx, table_idx);
  return lua_isnumber(L, -1) ? lua_tonumber(L, -1) : color_value_error(L, idx, table_idx);
}

static int get_color_value_opt(lua_State *L, int idx, int table_idx, int default_value) {
  lua_rawgeti(L, idx, table_idx);
  if (lua_isnoneornil(L, -1))
    return default_value;
  else if (lua_isnumber(L, -1))
    return lua_tonumber(L, -1);
  else
    return color_value_error(L, idx, table_idx);
}

static RenColor checkcolor(lua_State *L, int idx, int def) {
  RenColor color;
  if (lua_isnoneornil(L, idx)) {
    return (RenColor) { def, def, def, 255 };
  }
  luaL_checktype(L, idx, LUA_TTABLE);
  color.r = get_color_value(L, idx, 1);
  color.g = get_color_value(L, idx, 2);
  color.b = get_color_value(L, idx, 3);
  color.a = get_color_value_opt(L, idx, 4, 255);
  lua_pop(L, 4);
  return color;
}

static int f_show_debug(lua_State *L) {
  luaL_checkany(L, 1);
  rencache_show_debug(lua_toboolean(L, 1));
  return 0;
}


static int f_get_size(lua_State *L) {
  int w = 0, h = 0;
  RenWindow *window = ren_get_target_window();
  RenSurface rs = rencache_get_surface(&window->cache);
  if (window)
    ren_get_size(&rs, &w, &h);
  lua_pushnumber(L, w);
  lua_pushnumber(L, h);
  return 2;
}


static int f_begin_frame(UNUSED lua_State *L) {
  assert(ren_get_target_window() == NULL);
  RenWindow *window = *(RenWindow**)luaL_checkudata(L, 1, API_TYPE_RENWINDOW);
  ren_set_target_window(window);
  rencache_begin_frame(&window->cache);
  return 0;
}


static int f_end_frame(UNUSED lua_State *L) {
  RenWindow *window = ren_get_target_window();
  assert(window != NULL);
  rencache_end_frame(&window->cache);
  ren_set_target_window(NULL);
  // clear the font reference table
  lua_newtable(L);
  lua_rawseti(L, LUA_REGISTRYINDEX, RENDERER_FONT_REF);
  // clear the canvas reference table
  lua_newtable(L);
  lua_rawseti(L, LUA_REGISTRYINDEX, RENDERER_CANVAS_REF);
  return 0;
}


static RenRect rect_to_grid(lua_Number x, lua_Number y, lua_Number w, lua_Number h) {
  int x1 = (int) (x + 0.5), y1 = (int) (y + 0.5);
  int x2 = (int) (x + w + 0.5), y2 = (int) (y + h + 0.5);
  return (RenRect) {x1, y1, x2 - x1, y2 - y1};
}


static int f_set_clip_rect(lua_State *L) {
  lua_Number x = luaL_checknumber(L, 1);
  lua_Number y = luaL_checknumber(L, 2);
  lua_Number w = luaL_checknumber(L, 3);
  lua_Number h = luaL_checknumber(L, 4);
  RenRect rect = rect_to_grid(x, y, w, h);
  rencache_set_clip_rect(&ren_get_target_window()->cache, rect);
  return 0;
}


static int f_draw_rect(lua_State *L) {
  lua_Number x = luaL_checknumber(L, 1);
  lua_Number y = luaL_checknumber(L, 2);
  lua_Number w = luaL_checknumber(L, 3);
  lua_Number h = luaL_checknumber(L, 4);
  RenRect rect = rect_to_grid(x, y, w, h);
  RenColor color = luaXL_checkcolor(L, 5, 255);
  rencache_draw_rect(&ren_get_target_window()->cache, rect, color);
  return 0;
}


static int f_draw_poly(lua_State *L) {
  static const char normal_tag[] = { POLY_NORMAL };
  static const char conic_bezier_tag[] = { POLY_NORMAL, POLY_CONTROL_CONIC, POLY_NORMAL };
  static const char cubic_bezier_tag[] = { POLY_NORMAL, POLY_CONTROL_CUBIC, POLY_CONTROL_CUBIC, POLY_NORMAL };

  RenWindow *window = ren_get_target_window();
  assert(window != NULL);
  luaL_checktype(L, 1, LUA_TTABLE);
  RenColor color = checkcolor(L, 2, 255);
  lua_settop(L, 2);

  int len = luaL_len(L, 1);
  RenPoint *points = NULL; int npoints = 0;
  for (int i = 1; i <= len; i++) {
    lua_rawgeti(L, 1, i); luaL_checktype(L, -1, LUA_TTABLE);
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
  RenRect res = rencache_draw_poly(&window->cache, points, npoints, color);
  if (points) SDL_free(points);
  lua_pushinteger(L, res.x);     lua_pushinteger(L, res.y);
  lua_pushinteger(L, res.width); lua_pushinteger(L, res.height);
  return 4;
}


static int f_draw_text(lua_State *L) {
  RenFont* fonts[FONT_FALLBACK_MAX];
  font_retrieve(L, fonts, 1);

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

  size_t len;
  const char *text = luaL_checklstring(L, 2, &len);
  double x = luaL_checknumber(L, 3);
  double y = luaL_checknumber(L, 4);
  RenColor color = luaXL_checkcolor(L, 5, 255);
  RenTab tab = luaXL_checktab(L, 6);
  x = rencache_draw_text(&ren_get_target_window()->cache, fonts, text, len, x, y, color, tab);
  lua_pushnumber(L, x);
  return 1;
}

static int f_draw_canvas(lua_State *L) {
  RenCanvas* canvas = luaL_checkudata(L, 1, API_TYPE_CANVAS);
  int x = luaL_checkinteger(L, 2);
  int y = luaL_checkinteger(L, 3);

  // Save the CanvasRef to avoid it being GCd while in flight to the renderer
  lua_rawgeti(L, LUA_REGISTRYINDEX, RENDERER_CANVAS_REF);
  if (!lua_istable(L, -1)) {
    return luaL_error(L, "Unable to add reference to Canvas");
  }

  lua_getiuservalue(L, 1, USERDATA_CANVAS_REF);
  RenCanvasRef *ref = lua_touserdata(L, -1); // TODO: do we need to do checkudata?

  lua_pushboolean(L, true);
  lua_rawset(L, -3);

  RenRect rect = { .x = x, .y = y, .width = canvas->w, .height = canvas->h };
  rencache_draw_canvas(ren_get_target_window(), rect, ref, canvas->version);
  return 0;
}

static int f_to_canvas(lua_State *L) {
  lua_Number x = luaL_checkinteger(L, 1);
  lua_Number y = luaL_checkinteger(L, 2);
  lua_Number w = luaL_checkinteger(L, 3);
  lua_Number h = luaL_checkinteger(L, 4);

  // TODO: this is duplicated code from canvas.f_new, maybe add this to the utils?
  SDL_Surface *dst = SDL_CreateSurface(w, h, SDL_PIXELFORMAT_RGBA32);
  RenSurface rs = renwin_get_surface(ren_get_target_window());
  SDL_Rect rect = { .x = x, .y = y, .w = w, .h = h };
  SDL_BlitSurface(rs.surface, &rect, dst, NULL);

  RenCanvas *canvas = lua_newuserdatauv(L, sizeof(RenCanvas), USERDATA_LAST - 1);
  luaL_setmetatable(L, API_TYPE_CANVAS);
  canvas->w = w;
  canvas->h = h;
  canvas->version = 0;

  RenCanvasRef *ref = lua_newuserdata(L, sizeof(RenCanvasRef));
  luaL_setmetatable(L, API_TYPE_CANVAS_REF);
  lua_setiuservalue(L, -2, USERDATA_CANVAS_REF);
  ref->render_ref_count = 0;
  ref->surface = dst;

  return 1;
}

static const luaL_Reg lib[] = {
  { "show_debug",         f_show_debug         },
  { "get_size",           f_get_size           },
  { "begin_frame",        f_begin_frame        },
  { "end_frame",          f_end_frame          },
  { "set_clip_rect",      f_set_clip_rect      },
  { "draw_rect",          f_draw_rect          },
  { "draw_text",          f_draw_text          },
  { "draw_poly",          f_draw_poly          },
  { "draw_canvas",        f_draw_canvas        },
  { "to_canvas",          f_to_canvas          },
  { NULL,                 NULL                 }
};

static const luaL_Reg fontLib[] = {
  { "__gc",               f_font_gc                 },
  { "load",               f_font_load               },
  { "copy",               f_font_copy               },
  { "group",              f_font_group              },
  { "set_tab_size",       f_font_set_tab_size       },
  { "get_width",          f_font_get_width          },
  { "get_height",         f_font_get_height         },
  { "get_size",           f_font_get_size           },
  { "set_size",           f_font_set_size           },
  { "get_path",           f_font_get_path           },
  { "get_metadata",       f_font_get_metadata       },
  { NULL, NULL }
};

int luaopen_renderer(lua_State *L) {
  // gets a reference on the registry to store font data
  lua_newtable(L);
  RENDERER_FONT_REF = luaL_ref(L, LUA_REGISTRYINDEX);

  // gets a reference on the registry to store canvas data
  lua_newtable(L);
  RENDERER_CANVAS_REF = luaL_ref(L, LUA_REGISTRYINDEX);

  luaL_newlib(L, lib);
  luaL_newmetatable(L, API_TYPE_FONT);
  luaL_setfuncs(L, fontLib, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_setfield(L, -2, "font");
  return 1;
}
