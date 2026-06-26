#include <stdlib.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#ifdef _MSC_VER
  #ifndef alignof
    #define alignof _Alignof
  #endif
  #ifndef __clang__
    /* max_align_t is a compiler defined type, but
    ** MSVC doesn't provide it, so we'll have to improvise */
    typedef long double max_align_t;
  #endif
#else
  #include <stdalign.h>
#endif

#include <lauxlib.h>
#include "renderer/backend.h"
#include "renderer/cache.h"
#include "renderer/window.h"

/* a cache over the software renderer -- all drawing operations are stored as
** commands when issued. At the end of the frame we write the commands to a grid
** of hash values, take the cells that have changed since the previous frame,
** merge them into dirty rectangles and redraw only those regions */

#define CMD_BUF_RESIZE_RATE 1.2
#define CMD_BUF_INIT_SIZE (1024 * 512)
#define CMD_BUF_CANVAS_INIT_SIZE (1024 * 64)
#define COMMAND_BARE_SIZE offsetof(Command, command)

enum CommandType { SET_CLIP, DRAW_TEXT, DRAW_RECT, DRAW_POLY, DRAW_CANVAS, DRAW_PIXELS };

typedef struct {
  enum CommandType type;
  uint32_t size;
  /* Commands *must* always begin with a RenRect
  ** This is done to ensure alignment */
  RenRect command[];
} Command;

typedef struct {
  RenRect rect;
} SetClipCommand;

typedef struct {
  RenRect rect;
  RenColor color;
  RenFont *fonts[FONT_FALLBACK_MAX];
  float text_x;
  size_t len;
  int8_t tab_size;
  RenTab tab;
  char text[];
} DrawTextCommand;

typedef struct {
  RenRect rect;
  RenColor color;
  bool replace;
} DrawRectCommand;

typedef struct {
  RenRect rect;
  RenColor color;
  unsigned short npoints;
  RenPoint points[];
} DrawBezierCommand;

typedef struct {
  RenRect rect;
  RenCache *canvas;
  uint64_t canvas_revision;
} DrawCanvasCommand;

typedef struct {
  RenRect rect;
  size_t len;
  char bytes[];
} DrawPixelsCommand;

static bool show_debug = false;

static inline int rencache_min(int a, int b) { return a < b ? a : b; }
static inline int rencache_max(int a, int b) { return a > b ? a : b; }

/* 32bit fnv-1a hash */
#define HASH_INITIAL 2166136261

static void hash(unsigned *h, const void *data, int size) {
  const unsigned char *p = data;
  while (size--) {
    *h = (*h ^ *p++) * 16777619;
  }
}


static inline int cell_idx(int x, int y) {
  return x + y * RENCACHE_CELLS_X;
}


static inline bool rects_overlap(RenRect a, RenRect b) {
  return b.x + b.width  >= a.x && b.x <= a.x + a.width
      && b.y + b.height >= a.y && b.y <= a.y + a.height;
}


static RenRect intersect_rects(RenRect a, RenRect b) {
  int x1 = rencache_max(a.x, b.x);
  int y1 = rencache_max(a.y, b.y);
  int x2 = rencache_min(a.x + a.width, b.x + b.width);
  int y2 = rencache_min(a.y + a.height, b.y + b.height);
  return (RenRect) { x1, y1, rencache_max(0, x2 - x1), rencache_max(0, y2 - y1) };
}


static RenRect merge_rects(RenRect a, RenRect b) {
  int x1 = rencache_min(a.x, b.x);
  int y1 = rencache_min(a.y, b.y);
  int x2 = rencache_max(a.x + a.width, b.x + b.width);
  int y2 = rencache_max(a.y + a.height, b.y + b.height);
  return (RenRect) { x1, y1, x2 - x1, y2 - y1 };
}

static bool expand_command_buffer(RenCache *ren_cache) {
  size_t new_size = ren_cache->command_buf_size * CMD_BUF_RESIZE_RATE;
  if (new_size == 0) {
    new_size = ren_cache->window_target ? CMD_BUF_INIT_SIZE : CMD_BUF_CANVAS_INIT_SIZE;
  }
  uint8_t *new_command_buf = SDL_realloc(ren_cache->command_buf, new_size);
  if (!new_command_buf) {
    return false;
  }
  ren_cache->command_buf_size = new_size;
  ren_cache->command_buf = new_command_buf;
  return true;
}

static void* push_command(RenCache *ren_cache, enum CommandType type, int size) {
  if (!ren_cache || ren_cache->resize_issue) {
    // Don't push new commands as we had problems resizing the command buffer.
    // Or, we don't have an active buffer.
    // Let's wait for the next frame.
    return NULL;
  }
  size_t alignment = alignof(max_align_t) - 1;
  size += COMMAND_BARE_SIZE;
  size = (size + alignment) & ~alignment;
  int n = ren_cache->command_buf_idx + size;
  while (n > ren_cache->command_buf_size) {
    if (!expand_command_buffer(ren_cache)) {
      fprintf(stderr, "Warning: (" __FILE__ "): unable to resize command buffer (%zu)\n",
              (size_t)(ren_cache->command_buf_size * CMD_BUF_RESIZE_RATE));
      ren_cache->resize_issue = true;
      return NULL;
    }
  }
  Command *cmd = (Command*) (ren_cache->command_buf + ren_cache->command_buf_idx);
  ren_cache->command_buf_idx = n;
  cmd->type = type;
  cmd->size = size;
  return cmd->command;
}


static bool next_command(RenCache *ren_cache, Command **prev) {
  if (*prev == NULL) {
    *prev = (Command*) ren_cache->command_buf;
  } else {
    *prev = (Command*) (((char*) *prev) + (*prev)->size);
  }
  return *prev != ((Command*) (ren_cache->command_buf + ren_cache->command_buf_idx));
}


void rencache_init(RenCache *rc) {
  memset(rc, 0, sizeof(RenCache));
  rc->target = NULL;
  rc->backend_data = NULL;
  rc->window_target = false;
  rc->get_surface = NULL;
  rc->present_rects = NULL;
  rc->backend = renbackend_current();
  rc->rensurface.surface = NULL;
  rc->command_buf = NULL;
  rc->command_buf_idx = 0;
  rc->command_buf_size = 0;
  rc->cells_prev = rc->cells_buf1;
  rc->cells = rc->cells_buf2;
}


void rencache_uninit(RenCache *rc) {
  if (rc) {
    if (rc->command_buf)
      SDL_free(rc->command_buf);
    rencache_init(rc);
  }
}


void rencache_show_debug(bool enable) {
  show_debug = enable;
}


void rencache_set_clip_rect(RenCache *ren_cache, RenRect rect) {
  SetClipCommand *cmd = push_command(ren_cache, SET_CLIP, sizeof(SetClipCommand));
  if (cmd) {
    cmd->rect = intersect_rects(rect, ren_cache->screen_rect);
    ren_cache->last_clip_rect = cmd->rect;
  }
}


void rencache_draw_rect(RenCache *ren_cache, RenRect rect, RenColor color, bool replace) {
  if (rect.width == 0 || rect.height == 0 || !rects_overlap(ren_cache->last_clip_rect, rect)) {
    return;
  }
  DrawRectCommand *cmd = push_command(ren_cache, DRAW_RECT, sizeof(DrawRectCommand));
  if (cmd) {
    cmd->rect = rect;
    cmd->color = color;
    cmd->replace = replace;
  }
}

double rencache_draw_text(RenCache *ren_cache, RenFont **fonts, const char *text, size_t len, double x, double y, RenColor color, RenTab tab)
{
  int x_offset;
  double width = ren_font_group_get_width(fonts, text, len, tab, &x_offset);
  RenRect rect = { x + x_offset, y, (int)(width - x_offset), ren_font_group_get_height(fonts) };
  if (rects_overlap(ren_cache->last_clip_rect, rect)) {
    int sz = len + 1;
    DrawTextCommand *cmd = push_command(ren_cache, DRAW_TEXT, sizeof(DrawTextCommand) + sz);
    if (cmd) {
      memcpy(cmd->text, text, sz);
      cmd->color = color;
      memcpy(cmd->fonts, fonts, sizeof(RenFont*)*FONT_FALLBACK_MAX);
      cmd->rect = rect;
      cmd->text_x = x;
      cmd->len = len;
      cmd->tab_size = ren_font_group_get_tab_size(fonts);
      cmd->tab = tab;
    }
  }
  return x + width;
}

RenRect rencache_draw_poly(RenCache *ren_cache, RenPoint *points, int npoints, RenColor color) {
  RenRect rect;
  if (ren_poly_cbox(points, npoints, &rect) != 0) {
    return (RenRect){-1};
  }
  RenRect draw_rect = { rect.x - 1, rect.y - 1, rect.width + 2, rect.height + 2 };
  if (rects_overlap(ren_cache->last_clip_rect, draw_rect)) {
    size_t size = npoints + npoints * sizeof(RenPoint);
    DrawBezierCommand *cmd = push_command(ren_cache, DRAW_POLY, sizeof(DrawBezierCommand) + size);
    if (cmd) {
      cmd->rect = draw_rect;
      cmd->color = color;
      cmd->npoints = npoints;
      memcpy(cmd->points, points, npoints * sizeof(RenPoint));
    }
  }
  return rect;
}

void rencache_draw_canvas(RenCache *ren_cache, RenRect rect, RenCache *canvas) {
  if (rect.width == 0 || rect.height == 0 || !rects_overlap(ren_cache->last_clip_rect, rect)) {
    return;
  }
  DrawCanvasCommand *cmd = push_command(ren_cache, DRAW_CANVAS, sizeof(DrawCanvasCommand));
  if (cmd) {
    cmd->rect = rect;
    cmd->canvas = canvas;
    cmd->canvas_revision = canvas->revision;
    rencache_begin_frame(canvas);
  }
}

void rencache_draw_pixels(RenCache *ren_cache, RenRect rect, const char* bytes, size_t len) {
  if (rect.width > 0 && rect.height > 0 && rects_overlap(ren_cache->last_clip_rect, rect)) {
    int sz = len + 1;
    DrawPixelsCommand *cmd = push_command(ren_cache, DRAW_PIXELS, sizeof(DrawPixelsCommand) + sz);
    if (cmd) {
      memcpy(cmd->bytes, bytes, sz);
      cmd->len = len;
      cmd->rect = rect;
    }
  }
}

void rencache_invalidate(RenCache *ren_cache) {
  memset(ren_cache->cells_prev, 0xff, sizeof(ren_cache->cells_buf1));
}


void rencache_begin_frame(RenCache *ren_cache) {
  /* reset all cells if the screen width/height has changed */
  int w, h;
  ren_cache->resize_issue = false;
  RenSurface rs = rencache_get_surface(ren_cache);
  ren_get_size(&rs, &w, &h);
  if (ren_cache->screen_rect.width != w || h != ren_cache->screen_rect.height) {
    ren_cache->screen_rect.width = w;
    ren_cache->screen_rect.height = h;
    rencache_invalidate(ren_cache);
  }
  ren_cache->last_clip_rect = ren_cache->screen_rect;
}


static void update_overlapping_cells(RenCache *ren_cache, RenRect r, unsigned h) {
  int x1 = r.x / RENCACHE_CELL_SIZE;
  int y1 = r.y / RENCACHE_CELL_SIZE;
  int x2 = (r.x + r.width) / RENCACHE_CELL_SIZE;
  int y2 = (r.y + r.height) / RENCACHE_CELL_SIZE;

  for (int y = y1; y <= y2; y++) {
    for (int x = x1; x <= x2; x++) {
      int idx = cell_idx(x, y);
      hash(&ren_cache->cells[idx], &h, sizeof(h));
    }
  }
}


static void push_rect(RenCache *ren_cache, RenRect r, int *count) {
  /* try to merge with existing rectangle */
  for (int i = *count - 1; i >= 0; i--) {
    RenRect *rp = &ren_cache->rect_buf[i];
    if (rects_overlap(*rp, r)) {
      *rp = merge_rects(*rp, r);
      return;
    }
  }
  /* couldn't merge with previous rectangle: push */
  ren_cache->rect_buf[(*count)++] = r;
}

static bool command_intersects_region(Command *cmd, RenRect clip, RenRect region) {
  RenRect r = intersect_rects(cmd->command[0], clip);
  r = intersect_rects(r, region);
  return r.width > 0 && r.height > 0;
}

static bool backend_can_replay_region_natively(RenCache *ren_cache, RenSurface *surface, RenRect region) {
  if (!ren_cache->window_target || show_debug)
    return false;
  if (ren_cache->backend->can_native_region &&
      ren_cache->backend->can_native_region(ren_cache, surface, region)) {
    Command *cmd = NULL;
    RenRect cr = ren_cache->screen_rect;
    while (next_command(ren_cache, &cmd)) {
      SetClipCommand *ccmd = (SetClipCommand*)&cmd->command;
      DrawTextCommand *tcmd = (DrawTextCommand*)&cmd->command;

      if (cmd->type == SET_CLIP) {
        cr = ccmd->rect;
        continue;
      }

      if (cmd->type != DRAW_TEXT || !command_intersects_region(cmd, cr, region))
        continue;

      if (!ren_cache->backend->can_native_text)
        return false;
      ren_font_group_set_tab_size(tcmd->fonts, tcmd->tab_size);
      if (!ren_cache->backend->can_native_text(
            ren_cache, surface, tcmd->fonts, tcmd->text, tcmd->len, tcmd->text_x, tcmd->rect.y,
            tcmd->color, tcmd->tab
          ))
        return false;
    }
    return true;
  }

  Command *cmd = NULL;
  RenRect cr = ren_cache->screen_rect;
  while (next_command(ren_cache, &cmd)) {
    SetClipCommand *ccmd = (SetClipCommand*)&cmd->command;
    DrawRectCommand *rcmd = (DrawRectCommand*)&cmd->command;
    DrawTextCommand *tcmd = (DrawTextCommand*)&cmd->command;
    DrawBezierCommand *bcmd = (DrawBezierCommand*)&cmd->command;
    DrawCanvasCommand *cvcmd = (DrawCanvasCommand*)&cmd->command;
    DrawPixelsCommand *pcmd = (DrawPixelsCommand*)&cmd->command;

    if (cmd->type == SET_CLIP) {
      cr = ccmd->rect;
      continue;
    }

    if (!command_intersects_region(cmd, cr, region))
      continue;

    switch (cmd->type) {
      case SET_CLIP:
        break;
      case DRAW_RECT:
        if (!ren_cache->backend->can_native_rect ||
            !ren_cache->backend->can_native_rect(ren_cache, surface, rcmd->rect, rcmd->color, rcmd->replace))
          return false;
        break;
      case DRAW_TEXT:
        if (!ren_cache->backend->can_native_text)
          return false;
        ren_font_group_set_tab_size(tcmd->fonts, tcmd->tab_size);
        if (!ren_cache->backend->can_native_text(
              ren_cache, surface, tcmd->fonts, tcmd->text, tcmd->len, tcmd->text_x, tcmd->rect.y,
              tcmd->color, tcmd->tab
            ))
          return false;
        break;
      case DRAW_POLY:
        if (!ren_cache->backend->can_native_poly ||
            !ren_cache->backend->can_native_poly(ren_cache, surface, bcmd->points, bcmd->npoints, bcmd->color))
          return false;
        break;
      case DRAW_CANVAS:
        if (!ren_cache->backend->can_native_canvas ||
            !ren_cache->backend->can_native_canvas(ren_cache, surface, cvcmd->canvas, cvcmd->rect.x, cvcmd->rect.y))
          return false;
        break;
      case DRAW_PIXELS:
        if (!ren_cache->backend->can_native_pixels ||
            !ren_cache->backend->can_native_pixels(ren_cache, surface, pcmd->rect, pcmd->bytes, pcmd->len))
          return false;
        break;
    }
  }

  return true;
}


void rencache_end_frame(RenCache *ren_cache) {
  if (!ren_cache->window_target && ren_cache->command_buf_idx == 0)
    return;

  Command *cmd = NULL;
  int rect_count = 0;
  bool full_frame_regions = ren_cache->window_target &&
    ren_cache->backend->use_full_frame_regions &&
    ren_cache->backend->use_full_frame_regions(ren_cache);

  if (full_frame_regions) {
    ren_cache->rect_buf[rect_count++] = ren_cache->screen_rect;
    rencache_invalidate(ren_cache);
  } else {
    /* update cells from commands */
    RenRect cr = ren_cache->screen_rect;
    while (next_command(ren_cache, &cmd)) {
      /* cmd->command[0] should always be the Command rect */
      if (cmd->type == SET_CLIP) {
        SetClipCommand *ccmd = (SetClipCommand*)&cmd->command;
        cr = ccmd->rect;
      }
      RenRect r = intersect_rects(cmd->command[0], cr);
      if (r.width == 0 || r.height == 0) { continue; }
      unsigned h = HASH_INITIAL;
      hash(&h, cmd, cmd->size);
      update_overlapping_cells(ren_cache, r, h);
    }

    /* push rects for all cells changed from last frame, reset cells */
    int max_x = ren_cache->screen_rect.width / RENCACHE_CELL_SIZE + 1;
    int max_y = ren_cache->screen_rect.height / RENCACHE_CELL_SIZE + 1;
    for (int y = 0; y < max_y; y++) {
      for (int x = 0; x < max_x; x++) {
        /* compare previous and current cell for change */
        int idx = cell_idx(x, y);
        if (ren_cache->cells[idx] != ren_cache->cells_prev[idx]) {
          push_rect(ren_cache, (RenRect) { x, y, 1, 1 }, &rect_count);
        }
        ren_cache->cells_prev[idx] = HASH_INITIAL;
      }
    }

    /* expand rects from cells to pixels */
    for (int i = 0; i < rect_count; i++) {
      RenRect *r = &ren_cache->rect_buf[i];
      r->x *= RENCACHE_CELL_SIZE;
      r->y *= RENCACHE_CELL_SIZE;
      r->width *= RENCACHE_CELL_SIZE;
      r->height *= RENCACHE_CELL_SIZE;
      *r = intersect_rects(*r, ren_cache->screen_rect);
    }
  }

  if (rect_count > 0) {
    if (ren_cache->backend->begin_frame)
      ren_cache->backend->begin_frame(ren_cache, ren_cache->rect_buf, rect_count);

    RenSurface rs = rencache_get_surface(ren_cache);
    const RenCacheDrawOps *draw_ops = ren_cache->backend->draw_ops;
    /* redraw updated regions */
    for (int i = 0; i < rect_count; i++) {
      /* draw */
      RenRect r = ren_cache->rect_buf[i];
      draw_ops->set_clip_rect(ren_cache, &rs, r);
      bool native_only = backend_can_replay_region_natively(ren_cache, &rs, r);
      if (ren_cache->backend->begin_region)
        ren_cache->backend->begin_region(ren_cache, r, native_only);
      draw_ops->set_clip_rect(ren_cache, &rs, r);

      cmd = NULL;
      while (next_command(ren_cache, &cmd)) {
        SetClipCommand *ccmd = (SetClipCommand*)&cmd->command;
        DrawRectCommand *rcmd = (DrawRectCommand*)&cmd->command;
        DrawTextCommand *tcmd = (DrawTextCommand*)&cmd->command;
        DrawBezierCommand *bcmd = (DrawBezierCommand*)&cmd->command;
        DrawCanvasCommand *cvcmd = (DrawCanvasCommand*)&cmd->command;
        DrawPixelsCommand *pcmd = (DrawPixelsCommand*)&cmd->command;
        switch (cmd->type) {
          case SET_CLIP:
            draw_ops->set_clip_rect(ren_cache, &rs, intersect_rects(ccmd->rect, r));
            break;
          case DRAW_RECT:
            draw_ops->draw_rect(ren_cache, &rs, rcmd->rect, rcmd->color, rcmd->replace);
            break;
          case DRAW_TEXT:
            ren_font_group_set_tab_size(tcmd->fonts, tcmd->tab_size);
            draw_ops->draw_text(ren_cache, &rs, tcmd->fonts, tcmd->text, tcmd->len, tcmd->text_x, tcmd->rect.y, tcmd->color, tcmd->tab);
            break;
          case DRAW_POLY:
            draw_ops->draw_poly(ren_cache, &rs, bcmd->points, bcmd->npoints, bcmd->color);
            break;
          case DRAW_CANVAS:
            rencache_end_frame(cvcmd->canvas);
            draw_ops->draw_canvas(ren_cache, &rs, cvcmd->canvas, cvcmd->rect.x, cvcmd->rect.y);
            break;
          case DRAW_PIXELS:
            draw_ops->draw_pixels(ren_cache, &rs, pcmd->rect, pcmd->bytes, pcmd->len);
            break;
        }
      }

      if (show_debug) {
        RenColor color = { rand(), rand(), rand(), 50 };
        draw_ops->draw_rect(ren_cache, &rs, r, color, false);
      }
      if (ren_cache->backend->end_region)
        ren_cache->backend->end_region(ren_cache, r, native_only);
    }

    if (ren_cache->backend->end_frame)
      ren_cache->backend->end_frame(ren_cache, ren_cache->rect_buf, rect_count);

    if (ren_cache->backend->target_updated)
      ren_cache->backend->target_updated(ren_cache, ren_cache->rect_buf, rect_count);
    if (!ren_cache->window_target)
      ren_cache->revision++;

    /* update dirty rects */
    if (ren_cache->present_rects)
      rencache_update_rects(ren_cache, ren_cache->rect_buf, rect_count);
  }

  /* swap cell buffer and reset */
  unsigned *tmp = ren_cache->cells;
  ren_cache->cells = ren_cache->cells_prev;
  ren_cache->cells_prev = tmp;
  ren_cache->command_buf_idx = 0;
}

RenSurface rencache_get_surface(RenCache *ren_cache) {
  if (ren_cache->get_surface) {
    return ren_cache->get_surface(ren_cache);
  } else if (!ren_cache->rensurface.surface) {
    fprintf(stderr, "RenCache surface not initialized");
    exit(1);
  }
  return ren_cache->rensurface;
}


void rencache_update_rects(RenCache *rc, RenRect *rects, int count) {
  if (rc->present_rects) {
    rc->present_rects(rc, rects, count);
  }
}
