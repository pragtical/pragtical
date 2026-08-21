#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include "renderer/backend.h"
#include "renderer/window.h"

RenWindow* renwin_create(SDL_Window *win) {
  assert(win);
  RenWindow* window_renderer = SDL_calloc(1, sizeof(RenWindow));

  rencache_init(&window_renderer->cache);
  window_renderer->window = win;
  window_renderer->cache.target = window_renderer;
  window_renderer->cache.window_target = true;
  if (window_renderer->cache.backend->init_window &&
      !window_renderer->cache.backend->init_window(window_renderer)) {
    fprintf(stderr,
      "Renderer backend '%s' failed to initialize window; falling back to 'surface'\n",
      window_renderer->cache.backend->name
    );
    renbackend_select("surface");
    window_renderer->cache.backend = renbackend_current();
    if (window_renderer->cache.backend->init_window &&
        !window_renderer->cache.backend->init_window(window_renderer)) {
      fprintf(stderr, "Renderer backend 'surface' failed to initialize window\n");
      exit(1);
    }
  }
  renwin_update_scale(window_renderer);
  renwin_clip_to_surface(window_renderer);

  return window_renderer;
}

SDL_Window* renwin_get_sdl_window(RenWindow *ren) {
  return ren->window;
}


void renwin_clip_to_surface(RenWindow *ren) {
  SDL_SetSurfaceClipRect(rencache_get_surface(&ren->cache).surface, NULL);
}


void renwin_update_scale(RenWindow *ren) {
  int window_w, window_h;
  if (!SDL_GetWindowSize(ren->window, &window_w, &window_h) ||
      window_w < 1 || window_h < 1) {
    ren->scale_x = ren->scale_y = 1;
    return;
  }

  RenSurface rs = rencache_get_surface(&ren->cache);
  ren->scale_x = (float) rs.surface->w / window_w;
  ren->scale_y = (float) rs.surface->h / window_h;
}

void renwin_convert_coordinates(RenWindow *ren, float *x, float *y, bool to_renderer) {
  if (x)
    *x = to_renderer ? *x * ren->scale_x : *x / ren->scale_x;
  if (y)
    *y = to_renderer ? *y * ren->scale_y : *y / ren->scale_y;
}

void renwin_show_window(RenWindow *ren) {
  if (!ren->shown) {
    SDL_ShowWindow(ren->window);
    ren->shown = true;
  }
}

void renwin_free(RenWindow *ren) {
  if (ren->cache.backend->destroy_window)
    ren->cache.backend->destroy_window(ren);
  SDL_DestroyWindow(ren->window);
  ren->window = NULL;
  rencache_uninit(&ren->cache);
  SDL_free(ren);
}
