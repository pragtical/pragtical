#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "renbackend.h"
#include "renwindow.h"

RenWindow* renwin_create(SDL_Window *win) {
  assert(win);
  RenWindow* window_renderer = SDL_calloc(1, sizeof(RenWindow));

  rencache_init(&window_renderer->cache);
  window_renderer->window = win;
  window_renderer->cache.target = window_renderer;
  window_renderer->cache.window_target = true;
  window_renderer->cache.get_surface = window_renderer->cache.backend->get_window_surface;
  window_renderer->cache.present_rects = window_renderer->cache.backend->present_window_rects;
  if (!window_renderer->cache.backend->init_window(window_renderer)) {
    fprintf(stderr,
      "Renderer backend '%s' failed to initialize window; falling back to 'surface'\n",
      window_renderer->cache.backend->name
    );
    renbackend_select("surface");
    window_renderer->cache.backend = renbackend_current();
    window_renderer->cache.get_surface = window_renderer->cache.backend->get_window_surface;
    window_renderer->cache.present_rects = window_renderer->cache.backend->present_window_rects;
    if (!window_renderer->cache.backend->init_window(window_renderer)) {
      fprintf(stderr, "Renderer backend 'surface' failed to initialize window\n");
      exit(1);
    }
  }
  renwin_clip_to_surface(window_renderer);

  return window_renderer;
}

SDL_Window* renwin_get_sdl_window(RenWindow *ren) {
  return ren->window;
}


void renwin_clip_to_surface(RenWindow *ren) {
  SDL_SetSurfaceClipRect(rencache_get_surface(&ren->cache).surface, NULL);
}


static RenRect scaled_rect(const RenRect rect, const RenSurface *rs) {
  float scale_x = rs->scale_x;
  float scale_y = rs->scale_y;
  return (RenRect) {
    rect.x * scale_x,
    rect.y * scale_y,
    rect.width * scale_x,
    rect.height * scale_y
  };
}

void renwin_set_clip_rect(RenWindow *ren, RenRect rect) {
  RenSurface rs = rencache_get_surface(&ren->cache);
  RenRect sr = scaled_rect(rect, &rs);
  SDL_SetSurfaceClipRect(rs.surface, &(SDL_Rect){.x = sr.x, .y = sr.y, .w = sr.width, .h = sr.height});
}


void renwin_resize_surface(UNUSED RenWindow *ren) {
  ren->cache.backend->resize_window(ren);
}

void renwin_update_scale(RenWindow *ren) {
  if (strcmp(ren->cache.backend->name, "surface") != 0)
    return;
  SDL_Surface *surface = SDL_GetWindowSurface(ren->window);
  int window_w = surface->w, window_h = surface->h;
  SDL_GetWindowSize(ren->window, &window_w, &window_h);
  ren->scale_x = (float)surface->w / window_w;
  ren->scale_y = (float)surface->h / window_h;
}

void renwin_show_window(RenWindow *ren) {
  SDL_ShowWindow(ren->window);
  ren->shown = true;
}

void renwin_free(RenWindow *ren) {
  ren->cache.backend->destroy_window(ren);
  SDL_DestroyWindow(ren->window);
  ren->window = NULL;
  rencache_uninit(&ren->cache);
  SDL_free(ren);
}
