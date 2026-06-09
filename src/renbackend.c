#include "renbackend.h"
#include "renbackend_sdlgpu.h"
#include "renbackend_sdlrenderer.h"
#include "renbackend_surface.h"
#include <stdio.h>

static const RenBackend *current_backend = NULL;

#ifndef PRAGTICAL_DEFAULT_RENDERER_BACKEND
#define PRAGTICAL_DEFAULT_RENDERER_BACKEND "surface"
#endif

const char *renbackend_default_name(void) {
  return PRAGTICAL_DEFAULT_RENDERER_BACKEND;
}

static const RenBackend *renbackend_from_name(const char *name) {
  if (!name || name[0] == '\0')
    return NULL;
  if (SDL_strcmp(name, "surface") == 0)
    return renbackend_surface();
  if (SDL_strcmp(name, "sdlrenderer") == 0)
    return renbackend_sdlrenderer();
  if (SDL_strcmp(name, "sdlgpu") == 0)
    return renbackend_sdlgpu();
  return NULL;
}

bool renbackend_select(const char *name) {
  const RenBackend *backend = renbackend_from_name(name);
  if (!backend)
    return false;
  current_backend = backend;
  return true;
}

const RenBackend *renbackend_current(void) {
  if (!current_backend) {
    const char *name = SDL_getenv("PRAGTICAL_RENDERER");
    if (!name || name[0] == '\0')
      name = renbackend_default_name();
    current_backend = renbackend_from_name(name);
    if (!current_backend) {
      fprintf(stderr,
        "Unknown PRAGTICAL_RENDERER value '%s'; falling back to '%s'\n",
        name,
        renbackend_default_name()
      );
      current_backend = renbackend_from_name(renbackend_default_name());
    }
    /* If the selected backend can't initialize (e.g. no usable GPU device),
    ** fall back to the always-available surface backend instead of aborting
    ** the process. */
    if (current_backend && current_backend->available && !current_backend->available()) {
      fprintf(stderr,
        "Renderer backend '%s' is unavailable; falling back to 'surface'\n",
        current_backend->name
      );
      current_backend = renbackend_surface();
    }
    if (!current_backend)
      current_backend = renbackend_surface();
  }
  return current_backend;
}
