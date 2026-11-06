#include <stdlib.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdbool.h>
#include <string.h>
#include <math.h>

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
enum CommandChanges { COMMANDS_SPARSE, COMMANDS_UNCHANGED, COMMANDS_DENSE };

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
  float text_y;
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
  uint64_t canvas_generation;
  uint64_t canvas_revision;
} DrawCanvasCommand;

typedef struct {
  RenRect rect;
  size_t len;
  char bytes[];
} DrawPixelsCommand;

static bool show_debug = false;

static inline double rencache_min(double a, double b) { return a < b ? a : b; }
static inline double rencache_max(double a, double b) { return a > b ? a : b; }

#define HASH_INITIAL 2166136261

static void hash(unsigned *h, const void *data, size_t size) {
  *h = SDL_murmur3_32(data, size, *h);
}


static inline int cell_idx(int x, int y) {
  return x + y * RENCACHE_CELLS_X;
}


static inline bool rects_overlap(RenRect a, RenRect b) {
  return a.width > 0 && a.height > 0 && b.width > 0 && b.height > 0
      && b.x + b.width > a.x && b.x < a.x + a.width
      && b.y + b.height > a.y && b.y < a.y + a.height;
}

static bool rects_equal(RenRect a, RenRect b) {
  return a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height;
}

static RenRect intersect_rects(RenRect a, RenRect b) {
  double x1 = rencache_max(a.x, b.x), y1 = rencache_max(a.y, b.y);
  double x2 = rencache_min(a.x + a.width, b.x + b.width);
  double y2 = rencache_min(a.y + a.height, b.y + b.height);
  return (RenRect) { x1, y1, rencache_max(0, x2 - x1), rencache_max(0, y2 - y1) };
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

static void* push_command(RenCache *ren_cache, enum CommandType type, int size, int extra) {
  if (!ren_cache || ren_cache->resize_issue) {
    // Don't push new commands as we had problems resizing the command buffer.
    // Or, we don't have an active buffer.
    // Let's wait for the next frame.
    return NULL;
  }
  size_t alignment = alignof(max_align_t) - 1;
  size_t fixed_size = COMMAND_BARE_SIZE + size;
  size_t used_size = fixed_size + extra;
  size = used_size;
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
  /* Define struct and alignment padding, without clearing text/pixel payloads.
   * This permits one fast hash of a complete deterministic command record. */
  memset(cmd, 0, fixed_size);
  memset((char*)cmd + used_size, 0, size - used_size);
  cmd->type = type;
  cmd->size = size;
  return cmd->command;
}


static bool next_command(RenCache *ren_cache, Command **prev) {
  if (ren_cache->command_buf_idx == 0) return false;
  if (*prev == NULL) {
    *prev = (Command*) ren_cache->command_buf;
  } else {
    *prev = (Command*) (((char*) *prev) + (*prev)->size);
  }
  return *prev != ((Command*) (ren_cache->command_buf + ren_cache->command_buf_idx));
}


void rencache_init(RenCache *rc) {
  static uint64_t generation = 0;
  memset(rc, 0, sizeof(RenCache));
  rc->generation = ++generation;
  rc->target = NULL;
  rc->backend_data = NULL;
  rc->window_target = false;
  rc->backend = renbackend_current();
  rc->rensurface.surface = NULL;
  rc->command_buf = NULL;
  rc->command_buf_idx = 0;
  rc->command_buf_size = 0;
  rc->cells_prev = rc->cells_buf1;
  rc->cells = rc->cells_buf2;
  rc->invalidated = true;
}


void rencache_uninit(RenCache *rc) {
  if (rc) {
    if (rc->command_buf)
      SDL_free(rc->command_buf);
    SDL_free(rc->previous_command_buf);
    rencache_init(rc);
  }
}


void rencache_show_debug(bool enable) {
  show_debug = enable;
}


void rencache_set_clip_rect(RenCache *ren_cache, RenRect rect) {
  SetClipCommand *cmd = push_command(ren_cache, SET_CLIP, sizeof(SetClipCommand), 0);
  if (cmd) {
    cmd->rect = intersect_rects(rect, ren_cache->screen_rect);
    ren_cache->last_clip_rect = cmd->rect;
  }
}


void rencache_draw_rect(RenCache *ren_cache, RenRect rect, RenColor color, bool replace) {
  if ((!color.a && !replace) || !rects_overlap(ren_cache->last_clip_rect, rect)) {
    return;
  }
  DrawRectCommand *cmd = push_command(ren_cache, DRAW_RECT, sizeof(DrawRectCommand), 0);
  if (cmd) {
    cmd->rect = rect;
    cmd->color = color;
    cmd->replace = replace;
  }
}

double rencache_draw_text(RenCache *ren_cache, RenFont **fonts, const char *text, size_t len, double x, double y, RenColor color, RenTab tab)
{
  double width = ren_font_group_get_width(fonts, text, len, tab, NULL);
  RenRect rect = ren_font_group_get_text_bounds(fonts, x, y, width);
  if (color.a && len && rects_overlap(ren_cache->last_clip_rect, rect)) {
    int sz = len + 1;
    DrawTextCommand *cmd = push_command(ren_cache, DRAW_TEXT, offsetof(DrawTextCommand, text), sz);
    if (cmd) {
      memcpy(cmd->text, text, sz);
      cmd->color = color;
      memcpy(cmd->fonts, fonts, sizeof(RenFont*)*FONT_FALLBACK_MAX);
      cmd->rect = rect;
      cmd->text_x = x;
      cmd->text_y = y;
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
  if (color.a && rects_overlap(ren_cache->last_clip_rect, draw_rect)) {
    size_t size = npoints * sizeof(RenPoint);
    DrawBezierCommand *cmd = push_command(ren_cache, DRAW_POLY, offsetof(DrawBezierCommand, points), size);
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
  DrawCanvasCommand *cmd = push_command(ren_cache, DRAW_CANVAS, sizeof(DrawCanvasCommand), 0);
  if (cmd) {
    cmd->rect = rect;
    cmd->canvas = canvas;
    // A recycled userdata address must not match a previous canvas's draw hash.
    cmd->canvas_generation = canvas->generation;
    cmd->canvas_revision = canvas->revision;
    rencache_begin_frame(canvas);
  }
}

void rencache_draw_pixels(RenCache *ren_cache, RenRect rect, const char* bytes, size_t len) {
  if (rect.width > 0 && rect.height > 0 && rects_overlap(ren_cache->last_clip_rect, rect)) {
    int sz = len + 1;
    DrawPixelsCommand *cmd = push_command(ren_cache, DRAW_PIXELS, offsetof(DrawPixelsCommand, bytes), sz);
    if (cmd) {
      memcpy(cmd->bytes, bytes, sz);
      cmd->len = len;
      cmd->rect = rect;
    }
  }
}

void rencache_invalidate(RenCache *ren_cache) {
  ren_cache->invalidated = true;
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
  int x2 = ceil((r.x + r.width) / RENCACHE_CELL_SIZE);
  int y2 = ceil((r.y + r.height) / RENCACHE_CELL_SIZE);

  for (int y = y1; y < y2; y++) {
    for (int x = x1; x < x2; x++) {
      int idx = cell_idx(x, y);
      ren_cache->cells[idx] = (ren_cache->cells[idx] ^ h) * 16777619u;
    }
  }
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
            ren_cache, surface, tcmd->fonts, tcmd->text, tcmd->len, tcmd->text_x, tcmd->text_y,
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
              ren_cache, surface, tcmd->fonts, tcmd->text, tcmd->len, tcmd->text_x, tcmd->text_y,
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


/* Records have deterministic padding. Include effective coverage so changes
 * to a clip within a cell invalidate the pixels drawn under that clip. */
static unsigned command_hash(Command *cmd, RenRect visible) {
  unsigned h = HASH_INITIAL;
  hash(&h, cmd, cmd->size);
  hash(&h, &visible, sizeof(visible));
  return h;
}

/* Join horizontal dirty spans only when their full width continues on the
 * next row. Unlike bounding-box unions, this never absorbs clean cells. */
static int collect_dirty_rects(RenCache *rc, int width, int height) {
  int previous[RENCACHE_CELLS_X / 2 + 1];
  int current[RENCACHE_CELLS_X / 2 + 1];
  int previous_count = 0, count = 0;
  for (int y = 0; y < height; y++) {
    int current_count = 0, previous_index = 0;
    for (int x = 0; x < width;) {
      if (rc->cells[cell_idx(x, y)] == rc->cells_prev[cell_idx(x, y)]) {
        x++;
        continue;
      }
      int start = x++;
      while (x < width && rc->cells[cell_idx(x, y)] != rc->cells_prev[cell_idx(x, y)]) x++;
      while (previous_index < previous_count && rc->rect_buf[previous[previous_index]].x < start)
        previous_index++;
      int index;
      if (previous_index < previous_count &&
          rc->rect_buf[previous[previous_index]].x == start &&
          rc->rect_buf[previous[previous_index]].width == x - start) {
        index = previous[previous_index];
        rc->rect_buf[index].height++;
      } else {
        index = count++;
        rc->rect_buf[index] = (RenRect) { start, y, x - start, 1 };
      }
      current[current_count++] = index;
    }
    memcpy(previous, current, current_count * sizeof(*current));
    previous_count = current_count;
  }
  return count;
}

/* Compare deterministic records, stopping once changed draws occupy a quarter
 * of the list. Clip state matters only where it changes a draw's coverage. */
static enum CommandChanges command_changes(RenCache *rc) {
  if (rc->previous_command_size != rc->command_buf_idx) return COMMANDS_SPARSE;
  size_t changed = 0;
  RenRect clip = rc->screen_rect, previous_clip = clip;
  for (size_t offset = 0; offset < rc->command_buf_idx;) {
    Command *cmd = (Command*)(rc->command_buf + offset);
    Command *previous = (Command*)(rc->previous_command_buf + offset);
    if (cmd->size != previous->size || cmd->type != previous->type) return COMMANDS_SPARSE;
    if (cmd->type == SET_CLIP) {
      clip = ((SetClipCommand*)cmd->command)->rect;
      previous_clip = ((SetClipCommand*)previous->command)->rect;
    } else if (memcmp(cmd, previous, cmd->size) ||
               (!rects_equal(clip, previous_clip) &&
                !rects_equal(intersect_rects(cmd->command[0], clip),
                             intersect_rects(previous->command[0], previous_clip)))) {
      changed += cmd->size;
      if (changed > rc->command_buf_idx / 4) return COMMANDS_DENSE;
    }
    offset += cmd->size;
  }
  return changed ? COMMANDS_SPARSE : COMMANDS_UNCHANGED;
}

/* Finalize sources before comparing or hashing their parent's command list. */
static void prepare_canvas(DrawCanvasCommand *cmd) {
  rencache_end_frame(cmd->canvas);
  cmd->canvas_revision = cmd->canvas->revision;
}

void rencache_end_frame(RenCache *ren_cache) {
  if (!ren_cache->window_target && ren_cache->command_buf_idx == 0)
    return;

  Command *cmd = NULL;
  int rect_count = 0;
  int width = ceil(ren_cache->screen_rect.width / RENCACHE_CELL_SIZE);
  int height = ceil(ren_cache->screen_rect.height / RENCACHE_CELL_SIZE);
  bool oversized = width > RENCACHE_CELLS_X || height > RENCACHE_CELLS_Y;
  bool force_full = false;
  bool prefer_full = ren_cache->window_target && ren_cache->backend->use_full_frame_regions &&
    ren_cache->backend->use_full_frame_regions(ren_cache, &force_full);
  enum CommandChanges changes = COMMANDS_SPARSE;
  if (prefer_full || oversized) {
    while (next_command(ren_cache, &cmd))
      if (cmd->type == DRAW_CANVAS) prepare_canvas((DrawCanvasCommand*)cmd->command);
    if (prefer_full && !ren_cache->invalidated) changes = command_changes(ren_cache);
  }
  bool hash_cells = !oversized && changes == COMMANDS_SPARSE;
  if (hash_cells) {
    for (int y = 0; y < height; y++)
      for (int x = 0; x < width; x++) ren_cache->cells[cell_idx(x, y)] = HASH_INITIAL;
  }

  RenRect cr = ren_cache->screen_rect;
  cmd = NULL;
  while (hash_cells && next_command(ren_cache, &cmd)) {
    if (cmd->type == SET_CLIP) {
      cr = ((SetClipCommand*)cmd->command)->rect;
      continue;
    }
    if (cmd->type == DRAW_CANVAS) {
      DrawCanvasCommand *c = (DrawCanvasCommand*)cmd->command;
      /* Finish pending source draws before hashing, even if the parent ends
       * up unchanged or this canvas is outside its dirty regions. */
      if (!prefer_full) prepare_canvas(c);
    }
    RenRect r = intersect_rects(cmd->command[0], cr);
    if (r.width > 0 && r.height > 0)
      update_overlapping_cells(ren_cache, r, command_hash(cmd, r));
  }

  if (changes != COMMANDS_UNCHANGED &&
      (oversized || ren_cache->invalidated || !ren_cache->cells_valid || changes == COMMANDS_DENSE)
      && width > 0 && height > 0) {
    ren_cache->rect_buf[rect_count++] = ren_cache->screen_rect;
  } else if (hash_cells) {
    rect_count = collect_dirty_rects(ren_cache, width, height);
    double dirty_area = 0;
    for (int i = 0; i < rect_count; i++) {
      RenRect *r = &ren_cache->rect_buf[i];
      r->x *= RENCACHE_CELL_SIZE;
      r->y *= RENCACHE_CELL_SIZE;
      r->width *= RENCACHE_CELL_SIZE;
      r->height *= RENCACHE_CELL_SIZE;
      *r = intersect_rects(*r, ren_cache->screen_rect);
      dirty_area += r->width * r->height;
    }
    /* A large command list alone does not justify repainting an unchanged
     * window. Use the backend shortcut only when damage is also substantial. */
    if (rect_count > 128 ||
        (rect_count > 0 && (force_full ||
         (prefer_full && dirty_area >= ren_cache->screen_rect.width * ren_cache->screen_rect.height / 2)))) {
      ren_cache->rect_buf[0] = ren_cache->screen_rect;
      rect_count = 1;
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
      cr = ren_cache->screen_rect;
      RenRect current_clip = r;
      while (next_command(ren_cache, &cmd)) {
        SetClipCommand *ccmd = (SetClipCommand*)&cmd->command;
        DrawRectCommand *rcmd = (DrawRectCommand*)&cmd->command;
        DrawTextCommand *tcmd = (DrawTextCommand*)&cmd->command;
        DrawBezierCommand *bcmd = (DrawBezierCommand*)&cmd->command;
        DrawCanvasCommand *cvcmd = (DrawCanvasCommand*)&cmd->command;
        DrawPixelsCommand *pcmd = (DrawPixelsCommand*)&cmd->command;
        if (cmd->type == SET_CLIP) {
          cr = ccmd->rect;
          RenRect clip = intersect_rects(cr, r);
          if (!rects_equal(clip, current_clip)) {
            draw_ops->set_clip_rect(ren_cache, &rs, clip);
            current_clip = clip;
          }
          continue;
        }
        if (!command_intersects_region(cmd, cr, r)) continue;
        switch (cmd->type) {
          case SET_CLIP:
            break;
          case DRAW_RECT:
            draw_ops->draw_rect(ren_cache, &rs, rcmd->rect, rcmd->color, rcmd->replace);
            break;
          case DRAW_TEXT:
            ren_font_group_set_tab_size(tcmd->fonts, tcmd->tab_size);
            draw_ops->draw_text(ren_cache, &rs, tcmd->fonts, tcmd->text, tcmd->len, tcmd->text_x, tcmd->text_y, tcmd->color, tcmd->tab);
            break;
          case DRAW_POLY:
            draw_ops->draw_poly(ren_cache, &rs, bcmd->points, bcmd->npoints, bcmd->color);
            break;
          case DRAW_CANVAS:
            draw_ops->draw_canvas(ren_cache, &rs, cvcmd->canvas, cvcmd->rect.x, cvcmd->rect.y);
            break;
          case DRAW_PIXELS:
            draw_ops->draw_pixels(ren_cache, &rs, pcmd->rect, pcmd->bytes, pcmd->len);
            break;
        }
      }

      if (show_debug) {
        RenColor color = { rand(), rand(), rand(), 50 };
        draw_ops->set_clip_rect(ren_cache, &rs, r);
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
    if (ren_cache->window_target && ren_cache->backend->present_window_rects)
      ren_cache->backend->present_window_rects(ren_cache, ren_cache->rect_buf, rect_count);
  }

  if (hash_cells) {
    unsigned *tmp = ren_cache->cells;
    ren_cache->cells = ren_cache->cells_prev;
    ren_cache->cells_prev = tmp;
    ren_cache->cells_valid = true;
  } else if (changes != COMMANDS_UNCHANGED) {
    ren_cache->cells_valid = false;
  }
  if (prefer_full) {
    /* Reuse the old snapshot for next frame's recording, without copying a
     * large command list or retaining references to its source objects. */
    uint8_t *tmp = ren_cache->previous_command_buf;
    size_t capacity = ren_cache->previous_command_capacity;
    ren_cache->previous_command_buf = ren_cache->command_buf;
    ren_cache->previous_command_capacity = ren_cache->command_buf_size;
    ren_cache->previous_command_size = ren_cache->command_buf_idx;
    ren_cache->command_buf = tmp;
    ren_cache->command_buf_size = capacity;
  } else {
    ren_cache->previous_command_size = 0;
  }
  ren_cache->command_buf_idx = 0;
  ren_cache->invalidated = false;
}

RenSurface rencache_get_surface(RenCache *ren_cache) {
  if (ren_cache->window_target && ren_cache->backend->get_window_surface) {
    return ren_cache->backend->get_window_surface(ren_cache);
  } else if (!ren_cache->rensurface.surface) {
    fprintf(stderr, "RenCache surface not initialized");
    exit(1);
  }
  return ren_cache->rensurface;
}
