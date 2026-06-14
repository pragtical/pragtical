#include <SDL3/SDL.h>
#include <CoreServices/CoreServices.h>
#include <dispatch/dispatch.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>

#include "dirmonitor.h"

struct dirmonitor_internal {
  SDL_Mutex* lock;
  char** changes;
  size_t count;
  FSEventStreamRef stream;
  dispatch_queue_t queue;
  CFStringRef path;
  CFArrayRef paths;
  int fds[2];
};


static struct dirmonitor_internal* init_dirmonitor(void) {
  struct dirmonitor_internal* monitor = SDL_calloc(1, sizeof(struct dirmonitor_internal));
  monitor->stream = NULL;
  monitor->queue = NULL;
  monitor->path = NULL;
  monitor->paths = NULL;
  monitor->changes = NULL;
  monitor->count = 0;
  monitor->fds[0] = -1;
  monitor->fds[1] = -1;
  monitor->lock = SDL_CreateMutex();

  return monitor;
}


static void clear_monitor_changes(struct dirmonitor_internal* monitor) {
  SDL_LockMutex(monitor->lock);
  if (monitor->count > 0) {
    for (size_t i = 0; i < monitor->count; i++) {
      SDL_free(monitor->changes[i]);
    }
    SDL_free(monitor->changes);
    monitor->changes = NULL;
    monitor->count = 0;
  }
  SDL_UnlockMutex(monitor->lock);
}


static void stop_monitor_stream(struct dirmonitor_internal* monitor) {
  if (monitor->stream) {
    FSEventStreamStop(monitor->stream);
    if (monitor->queue) {
      FSEventStreamSetDispatchQueue(monitor->stream, NULL);
    }
    FSEventStreamInvalidate(monitor->stream);
    FSEventStreamRelease(monitor->stream);
    monitor->stream = NULL;
  }

  if (monitor->queue) {
    dispatch_release(monitor->queue);
    monitor->queue = NULL;
  }

  if (monitor->paths) {
    CFRelease(monitor->paths);
    monitor->paths = NULL;
  }

  if (monitor->path) {
    CFRelease(monitor->path);
    monitor->path = NULL;
  }

  if (monitor->fds[1] != -1) {
    write(monitor->fds[1], "", 1);
  }
  if (monitor->fds[0] != -1) {
    close(monitor->fds[0]);
    monitor->fds[0] = -1;
  }
  if (monitor->fds[1] != -1) {
    close(monitor->fds[1]);
    monitor->fds[1] = -1;
  }

  clear_monitor_changes(monitor);
}


static void deinit_dirmonitor(struct dirmonitor_internal* monitor) {
  stop_monitor_stream(monitor);
  SDL_DestroyMutex(monitor->lock);
}


static void stream_callback(
  ConstFSEventStreamRef streamRef,
  void* monitor_ptr,
  size_t numEvents,
  void* eventPaths,
  const FSEventStreamEventFlags eventFlags[],
  const FSEventStreamEventId eventIds[]
)
{
  if (numEvents <= 0) {
    return;
  }

  struct dirmonitor_internal* monitor = monitor_ptr;
  char** path_list = eventPaths;

  SDL_LockMutex(monitor->lock);
  size_t total = 0;
  if (monitor->count == 0) {
    total = numEvents;
    monitor->changes = SDL_calloc(numEvents, sizeof(char*));
  } else {
    total = monitor->count + numEvents;
    monitor->changes = SDL_realloc(
      monitor->changes,
      sizeof(char*) * total
    );
  }
  for (size_t idx = monitor->count; idx < total; idx++) {
    size_t pidx = idx - monitor->count;
    monitor->changes[idx] = SDL_malloc(strlen(path_list[pidx])+1);
    strcpy(monitor->changes[idx], path_list[pidx]);
  }
  monitor->count = total;

  if (total > 0)
    write(monitor->fds[1], "", 1);
  SDL_UnlockMutex(monitor->lock);
}


static int get_changes_dirmonitor(
  struct dirmonitor_internal* monitor,
  char* buffer,
  int buffer_size
) {
  char response[1];
  if (monitor->fds[0] == -1) {
    return 0;
  }

  if (read(monitor->fds[0], response, 1) <= 0 || monitor->fds[0] == -1) {
    return 0;
  }

  size_t results = 0;
  SDL_LockMutex(monitor->lock);
  results = monitor->count;
  SDL_UnlockMutex(monitor->lock);

  return results;
}


static int translate_changes_dirmonitor(
  struct dirmonitor_internal* monitor,
  char* buffer,
  int buffer_size,
  int (*change_callback)(int, const char*, void*),
  void* L
) {
  SDL_LockMutex(monitor->lock);
  if (monitor->count > 0) {
    for (size_t i = 0; i < monitor->count; i++) {
      change_callback(strlen(monitor->changes[i]), monitor->changes[i], L);
      SDL_free(monitor->changes[i]);
    }
    SDL_free(monitor->changes);
    monitor->changes = NULL;
    monitor->count = 0;
  }
  SDL_UnlockMutex(monitor->lock);
  return 0;
}


static int add_dirmonitor(struct dirmonitor_internal* monitor, const char* path) {
  stop_monitor_stream(monitor);

  if (pipe(monitor->fds) != 0) {
    monitor->fds[0] = -1;
    monitor->fds[1] = -1;
    return -1;
  }

  FSEventStreamContext context = {
    .info = monitor,
    .retain = NULL,
    .release = NULL,
    .copyDescription = NULL,
    .version = 0
  };

  monitor->path = CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8);
  if (!monitor->path) {
    stop_monitor_stream(monitor);
    return -1;
  }

  monitor->paths = CFArrayCreate(
    NULL,
    (const void **)&monitor->path,
    1,
    &kCFTypeArrayCallBacks
  );
  if (!monitor->paths) {
    stop_monitor_stream(monitor);
    return -1;
  }

  monitor->stream = FSEventStreamCreate(
    NULL,
    stream_callback,
    &context,
    monitor->paths,
    kFSEventStreamEventIdSinceNow,
    0,
    kFSEventStreamCreateFlagNone
      | kFSEventStreamCreateFlagWatchRoot
      | kFSEventStreamCreateFlagFileEvents
  );

  if (!monitor->stream) {
    stop_monitor_stream(monitor);
    return -1;
  }

  monitor->queue = dispatch_queue_create("pragtical.dirmonitor.fsevents", NULL);
  if (!monitor->queue) {
    stop_monitor_stream(monitor);
    return -1;
  }
  FSEventStreamSetDispatchQueue(monitor->stream, monitor->queue);

  if (!FSEventStreamStart(monitor->stream)) {
    stop_monitor_stream(monitor);
    return -1;
  }

  return 1;
}


static void remove_dirmonitor(struct dirmonitor_internal* monitor, int fd) {
  stop_monitor_stream(monitor);
}


static int get_mode_dirmonitor(void) { return 1; }

struct dirmonitor_backend dirmonitor_fsevents = {
  .name = "fsevents",
  .init = init_dirmonitor,
  .deinit = deinit_dirmonitor,
  .get_changes = get_changes_dirmonitor,
  .translate_changes = translate_changes_dirmonitor,
  .add = add_dirmonitor,
  .remove = remove_dirmonitor,
  .get_mode = get_mode_dirmonitor,
};
