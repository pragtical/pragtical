#ifndef SYSTEM_EVENTS_H
#define SYSTEM_EVENTS_H

#include <SDL3/SDL_events.h>
#include <stdbool.h>
#include <stdint.h>

/* Push an event into the internal event queue.
 * Called from SDL_AppEvent so that system.poll_event can consume events
 * even when using the SDL3 main-callbacks API (SDL_MAIN_USE_CALLBACKS).
 * Motion events (mouse/touch) are coalesced automatically. */
void system_push_event(const SDL_Event *event);

/* Remove all queued events with the given type from the internal queue.
 * Should be called alongside SDL_FlushEvent() for the same type. */
void system_flush_events(uint32_t type);

/* Returns true when the internal event queue has at least one pending event.
 * Used by core.run_step() to detect burst-input mode without blocking. */
bool system_has_pending_events(void);

#endif /* SYSTEM_EVENTS_H */
