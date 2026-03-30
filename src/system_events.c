#include <SDL3/SDL.h>
#include "system_events.h"

/* ---------------------------------------------------------------------------
 * Internal event queue for SDL3 main-callback mode.
 *
 * When SDL_MAIN_USE_CALLBACKS is active the SDL event loop calls
 * SDL_AppEvent() for every pending event *before* calling SDL_AppIterate().
 * By the time our Lua code runs there are no more events left in SDL's own
 * queue, so SDL_PollEvent() would always return 0.
 *
 * To preserve the existing poll_event / wait_event Lua API we maintain our
 * own ring buffer.  SDL_AppEvent() pushes events here; f_poll_event() pops
 * from here instead of calling SDL_PollEvent().  Mouse-motion and
 * finger-motion events are coalesced on the way in, mirroring what the old
 * SDL_PeepEvents() loop used to do in f_poll_event().
 * ------------------------------------------------------------------------- */

/* 256 slots give plenty of headroom for a full key-repeat burst plus several
 * pending mouse-motion and touch events without allocating heap memory. */
#define SYSTEM_EVENT_QUEUE_SIZE 256

static SDL_Event system_event_queue[SYSTEM_EVENT_QUEUE_SIZE];
static int       system_event_queue_read  = 0;
static int       system_event_queue_count = 0;

void system_push_event(const SDL_Event *event) {
  /* Coalesce consecutive mouse-motion events for the same window */
  if (event->type == SDL_EVENT_MOUSE_MOTION) {
    for (int i = system_event_queue_count - 1; i >= 0; i--) {
      int idx = (system_event_queue_read + i) % SYSTEM_EVENT_QUEUE_SIZE;
      if (system_event_queue[idx].type == SDL_EVENT_MOUSE_MOTION &&
          system_event_queue[idx].motion.windowID == event->motion.windowID) {
        system_event_queue[idx].motion.x    = event->motion.x;
        system_event_queue[idx].motion.y    = event->motion.y;
        system_event_queue[idx].motion.xrel += event->motion.xrel;
        system_event_queue[idx].motion.yrel += event->motion.yrel;
        return;
      }
    }
  /* Coalesce consecutive finger-motion events for the same finger */
  } else if (event->type == SDL_EVENT_FINGER_MOTION) {
    for (int i = system_event_queue_count - 1; i >= 0; i--) {
      int idx = (system_event_queue_read + i) % SYSTEM_EVENT_QUEUE_SIZE;
      if (system_event_queue[idx].type == SDL_EVENT_FINGER_MOTION &&
          system_event_queue[idx].tfinger.fingerID == event->tfinger.fingerID) {
        system_event_queue[idx].tfinger.x  = event->tfinger.x;
        system_event_queue[idx].tfinger.y  = event->tfinger.y;
        system_event_queue[idx].tfinger.dx += event->tfinger.dx;
        system_event_queue[idx].tfinger.dy += event->tfinger.dy;
        return;
      }
    }
  }

  if (system_event_queue_count < SYSTEM_EVENT_QUEUE_SIZE) {
    int write_idx = (system_event_queue_read + system_event_queue_count)
                    % SYSTEM_EVENT_QUEUE_SIZE;
    system_event_queue[write_idx] = *event;
    system_event_queue_count++;
  } else {
    SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                "system event queue full; dropping event type 0x%x", event->type);
  }
}

void system_flush_events(uint32_t type) {
  int new_read  = system_event_queue_read;
  int new_count = 0;
  for (int i = 0; i < system_event_queue_count; i++) {
    int src = (system_event_queue_read + i) % SYSTEM_EVENT_QUEUE_SIZE;
    if (system_event_queue[src].type != type) {
      int dst = (new_read + new_count) % SYSTEM_EVENT_QUEUE_SIZE;
      if (src != dst)
        system_event_queue[dst] = system_event_queue[src];
      new_count++;
    }
  }
  system_event_queue_read  = new_read;
  system_event_queue_count = new_count;
}

bool system_has_pending_events(void) {
  return system_event_queue_count > 0;
}

bool system_event_pop(SDL_Event *event) {
  if (system_event_queue_count == 0) return false;
  *event = system_event_queue[system_event_queue_read];
  system_event_queue_read  = (system_event_queue_read + 1) % SYSTEM_EVENT_QUEUE_SIZE;
  system_event_queue_count--;
  return true;
}
