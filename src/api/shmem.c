/*
 * Cross-platform shared memory key/value store.
 *
 * The Lua API exposes a namespace with a fixed entry capacity. Internally,
 * each namespace is backed by a single shared-memory region plus one
 * cross-process mutex. Keeping all metadata and values in one mapping avoids
 * the per-entry mapping, resize and unlink races from the previous design.
 */

#include "api.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

#include <SDL3/SDL.h>

#ifdef _WIN32
  #include <windows.h>

  typedef HANDLE shmem_handle;
  typedef HANDLE shmem_mutex_handle;
#else
  #include <errno.h>
  #include <fcntl.h>
  #include <signal.h>
  #include <semaphore.h>
  #include <sys/mman.h>
  #include <sys/stat.h>
  #include <unistd.h>

  typedef int shmem_handle;
  typedef sem_t *shmem_mutex_handle;
#endif

#define SHMEM_NAME_LEN 124
#define SHMEM_NS_LEN 251
#define SHMEM_PATH_LEN 1024
#define SHMEM_MAGIC 0x50475348u
#define SHMEM_VERSION 3u
#define SHMEM_INITIAL_DATA_CAPACITY 4096u
#define SHMEM_OWNER_SLOTS 32u

typedef struct {
  char name[SHMEM_NAME_LEN];
  size_t offset;
  size_t size;
} shmem_entry;

typedef struct {
  uint64_t pid;
  uint32_t refs;
  uint32_t reserved;
} shmem_owner;

typedef struct {
  uint32_t magic;
  uint32_t version;
  int32_t refcount;
  uint32_t reserved;
  size_t size;
  size_t capacity;
  size_t data_capacity;
  size_t data_used;
  shmem_owner owners[SHMEM_OWNER_SLOTS];
  shmem_entry entries[];
} shmem_namespace;

typedef struct {
  shmem_handle handle;
  char name[SHMEM_NS_LEN];
#ifdef _WIN32
  HANDLE file_handle;
  char path[SHMEM_PATH_LEN];
#endif
  size_t size;
  void *map;
  bool created;
} shmem_region;

typedef struct {
  shmem_mutex_handle handle;
  char name[SHMEM_NS_LEN];
} shmem_mutex;

typedef struct {
  shmem_region *region;
  shmem_mutex *mutex;
  shmem_namespace *namespace;
} shmem_container;

typedef struct {
  shmem_container *container;
} l_shmem_container;

typedef struct {
  shmem_container *container;
  size_t position;
} l_shmem_state;

#define L_SHMEM_SELF(L, idx) ( \
  (l_shmem_container *) luaL_checkudata(L, idx, API_TYPE_SHARED_MEMORY) \
)->container

static Uint32 shmem_hash_string(const char *value) {
  Uint32 hash = 2166136261u;
  for (const unsigned char *ptr = (const unsigned char *) value; *ptr; ptr++) {
    hash ^= *ptr;
    hash *= 16777619u;
  }
  return hash;
}

static inline void shmem_ns_name(
  char *ns_name,
  size_t ns_name_size,
  const char *name
) {
#ifdef _WIN32
  snprintf(ns_name, ns_name_size, "%s", name);
#else
  snprintf(ns_name, ns_name_size, "/pgshm-%08x", shmem_hash_string(name));
#endif
}

static inline void shmem_mutex_name(char *mutex_name, const char *name) {
#ifdef _WIN32
  snprintf(mutex_name, SHMEM_NS_LEN, "%s_%s", name, "mutex");
#else
  snprintf(mutex_name, SHMEM_NS_LEN, "/pgmtx-%08x", shmem_hash_string(name));
#endif
}

static inline bool shmem_name_valid(const char *name) {
  if (
    strlen(name) >= SHMEM_NAME_LEN
    || strstr(name, "/") != NULL
    || strstr(name, "\\") != NULL
  ) {
    return false;
  }

  return true;
}

static inline size_t shmem_namespace_header_size(size_t capacity) {
  return sizeof(shmem_namespace) + (capacity * sizeof(shmem_entry));
}

static inline char *shmem_namespace_data(shmem_container *container) {
  return ((char *) container->namespace)
    + shmem_namespace_header_size(container->namespace->capacity);
}

static uint64_t shmem_current_pid(void) {
#ifdef _WIN32
  return (uint64_t) GetCurrentProcessId();
#else
  return (uint64_t) getpid();
#endif
}

static bool shmem_process_alive(uint64_t pid) {
#ifdef _WIN32
  HANDLE process = OpenProcess(
    SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION,
    FALSE,
    (DWORD) pid
  );
  if (process == NULL) {
    return GetLastError() != ERROR_INVALID_PARAMETER;
  }

  DWORD status = WaitForSingleObject(process, 0);
  CloseHandle(process);
  return status == WAIT_TIMEOUT;
#else
  if (pid == 0) {
    return false;
  }

  if (kill((pid_t) pid, 0) == 0 || errno == EPERM) {
    return true;
  }

  return errno != ESRCH;
#endif
}

static bool shmem_add_sizes(size_t left, size_t right, size_t *result) {
  if (left > SIZE_MAX - right) {
    SDL_SetError("shared memory region is too large");
    return false;
  }

  *result = left + right;
  return true;
}

static bool shmem_compute_header_size(size_t capacity, size_t *header_size) {
  if (capacity == 0) {
    SDL_SetError("capacity must be a positive integer");
    return false;
  }

  if (capacity > SIZE_MAX / sizeof(shmem_entry)) {
    SDL_SetError("capacity is too large");
    return false;
  }

  *header_size = shmem_namespace_header_size(capacity);
  return true;
}

#ifdef _WIN32
static bool shmem_region_path(char *path, size_t path_size, const char *name) {
  char temp_path[MAX_PATH + 1];
  DWORD temp_len = GetTempPathA(MAX_PATH, temp_path);
  if (temp_len == 0 || temp_len > MAX_PATH) {
    SDL_SetError("GetTempPath failed: %lu", GetLastError());
    return false;
  }

  int written = snprintf(
    path,
    path_size,
    "%spragtical-shmem-%08x.bin",
    temp_path,
    shmem_hash_string(name)
  );
  if (written < 0 || (size_t) written >= path_size) {
    SDL_SetError("shared memory path is too long");
    return false;
  }

  return true;
}
#endif

static bool shmem_region_remap(
  shmem_region *region,
  size_t size,
  bool resize_storage
) {
#ifdef _WIN32
  if (region->map != NULL) {
    UnmapViewOfFile(region->map);
    region->map = NULL;
  }
  if (region->handle != NULL) {
    CloseHandle(region->handle);
    region->handle = NULL;
  }

  if (resize_storage) {
    LARGE_INTEGER target_size;
    target_size.QuadPart = (LONGLONG) size;
    if (!SetFilePointerEx(region->file_handle, target_size, NULL, FILE_BEGIN)
        || !SetEndOfFile(region->file_handle)) {
      SDL_SetError("failed to resize shared memory '%s': %lu", region->name, GetLastError());
      return false;
    }
  }

  region->handle = CreateFileMappingA(
    region->file_handle, NULL, PAGE_READWRITE,
    (DWORD) (size >> 32), (DWORD) size, NULL
  );
  if (region->handle == NULL) {
    SDL_SetError(
      "CreateFileMapping failed for '%s': %lu",
      region->name,
      GetLastError()
    );
    return false;
  }

  region->map = MapViewOfFile(region->handle, FILE_MAP_ALL_ACCESS, 0, 0, size);
  if (region->map == NULL) {
    SDL_SetError("MapViewOfFile failed for '%s': %lu", region->name, GetLastError());
    CloseHandle(region->handle);
    region->handle = NULL;
    return false;
  }
#else
  if (region->map != NULL) {
    munmap(region->map, region->size);
    region->map = NULL;
  }

  if (resize_storage && ftruncate(region->handle, (off_t) size) == -1) {
    SDL_SetError("ftruncate failed for '%s': %s", region->name, strerror(errno));
    return false;
  }

  region->map = mmap(
    NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, region->handle, 0
  );
  if (region->map == MAP_FAILED) {
    region->map = NULL;
    SDL_SetError("mmap failed for '%s': %s", region->name, strerror(errno));
    return false;
  }
#endif

  region->size = size;
  return true;
}

static shmem_region *shmem_region_open(const char *name, size_t minimum_size) {
  shmem_region *region = SDL_calloc(1, sizeof(shmem_region));
  if (!region) {
    SDL_OutOfMemory();
    return NULL;
  }

  snprintf(region->name, sizeof(region->name), "%s", name);

#ifdef _WIN32
  if (!shmem_region_path(region->path, sizeof(region->path), name)) {
    goto shmem_region_open_error;
  }

  region->file_handle = CreateFileA(
    region->path,
    GENERIC_READ | GENERIC_WRITE,
    FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
    NULL,
    OPEN_ALWAYS,
    FILE_ATTRIBUTE_NORMAL,
    NULL
  );
  if (region->file_handle == INVALID_HANDLE_VALUE) {
    SDL_SetError("CreateFile failed for '%s': %lu", region->path, GetLastError());
    goto shmem_region_open_error;
  }

  region->created = GetLastError() != ERROR_ALREADY_EXISTS;

  LARGE_INTEGER file_size;
  if (!GetFileSizeEx(region->file_handle, &file_size)) {
    SDL_SetError("GetFileSizeEx failed for '%s': %lu", region->path, GetLastError());
    CloseHandle(region->file_handle);
    goto shmem_region_open_error;
  }

  if (region->created) {
    region->size = minimum_size;
    if (!shmem_region_remap(region, minimum_size, true)) {
      CloseHandle(region->file_handle);
      goto shmem_region_open_error;
    }
  } else {
    region->size = (size_t) file_size.QuadPart;
    if (region->size < minimum_size) {
      SDL_SetError(
        "shared memory region '%s' has incompatible capacity or layout",
        name
      );
      CloseHandle(region->file_handle);
      goto shmem_region_open_error;
    }
    if (!shmem_region_remap(region, region->size, false)) {
      CloseHandle(region->file_handle);
      goto shmem_region_open_error;
    }
  }
#else
  region->handle = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0666);
  if (region->handle == -1) {
    if (errno != EEXIST) {
      SDL_SetError("shm_open failed for '%s': %s", name, strerror(errno));
      goto shmem_region_open_error;
    }

    region->handle = shm_open(name, O_RDWR, 0666);
    if (region->handle == -1) {
      SDL_SetError("shm_open failed for '%s': %s", name, strerror(errno));
      goto shmem_region_open_error;
    }
  } else {
    region->created = true;
  }

  if (region->created) {
    region->size = minimum_size;
  } else {
    struct stat st;
    if (fstat(region->handle, &st) == -1) {
      SDL_SetError("fstat failed for '%s': %s", name, strerror(errno));
      close(region->handle);
      goto shmem_region_open_error;
    }
    region->size = (size_t) st.st_size;
    if (region->size < minimum_size) {
      SDL_SetError(
        "shared memory region '%s' has incompatible capacity or layout",
        name
      );
      close(region->handle);
      goto shmem_region_open_error;
    }
  }

  if (!shmem_region_remap(region, region->size, region->created)) {
    close(region->handle);
    goto shmem_region_open_error;
  }
#endif

  return region;

shmem_region_open_error:
  SDL_free(region);
  return NULL;
}

static void shmem_region_close(shmem_region *region, bool unregister) {
#ifdef _WIN32
  if (region->map != NULL) {
    UnmapViewOfFile(region->map);
  }
  if (region->handle != NULL) {
    CloseHandle(region->handle);
  }
  CloseHandle(region->file_handle);
  if (unregister) {
    DeleteFileA(region->path);
  }
#else
  if (region->map != NULL) {
    munmap(region->map, region->size);
  }
  close(region->handle);
  if (unregister) {
    shm_unlink(region->name);
  }
#endif

  SDL_free(region);
}

static shmem_mutex *shmem_mutex_open(const char *name) {
  shmem_mutex *mutex = SDL_malloc(sizeof(shmem_mutex));
  if (!mutex) {
    SDL_OutOfMemory();
    return NULL;
  }

  snprintf(mutex->name, sizeof(mutex->name), "%s", name);

#ifdef _WIN32
  mutex->handle = CreateMutexA(NULL, FALSE, name);
  if (mutex->handle == NULL) {
    SDL_SetError("CreateMutex failed for '%s': %lu", name, GetLastError());
    SDL_free(mutex);
    return NULL;
  }
#else
  mutex->handle = sem_open(name, O_CREAT, 0666, 1);
  if (mutex->handle == SEM_FAILED) {
    SDL_SetError("sem_open failed for '%s': %s", name, strerror(errno));
    SDL_free(mutex);
    return NULL;
  }
#endif

  return mutex;
}

static void shmem_mutex_lock(shmem_mutex *mutex) {
#ifdef _WIN32
  WaitForSingleObject(mutex->handle, INFINITE);
#else
  sem_wait(mutex->handle);
#endif
}

static void shmem_mutex_unlock(shmem_mutex *mutex) {
#ifdef _WIN32
  ReleaseMutex(mutex->handle);
#else
  sem_post(mutex->handle);
#endif
}

static void shmem_mutex_close(shmem_mutex *mutex, bool unregister) {
#ifdef _WIN32
  CloseHandle(mutex->handle);
#else
  sem_close(mutex->handle);
  if (unregister) {
    sem_unlink(mutex->name);
  }
#endif
  SDL_free(mutex);
}

static long int shmem_container_find_index(
  shmem_container *container,
  const char *name
) {
  for (size_t i = 0; i < container->namespace->size; i++) {
    if (strcmp(container->namespace->entries[i].name, name) == 0) {
      return (long int) i;
    }
  }
  return -1;
}

static void shmem_container_shift_offsets(
  shmem_container *container,
  size_t start_offset,
  ptrdiff_t delta
) {
  for (size_t i = 0; i < container->namespace->size; i++) {
    shmem_entry *entry = &container->namespace->entries[i];
    if (entry->size > 0 && entry->offset > start_offset) {
      entry->offset = (size_t) ((ptrdiff_t) entry->offset + delta);
    }
  }
}

static void shmem_namespace_sweep_dead_owners_locked(shmem_namespace *ns) {
  int32_t live_refs = 0;

  for (size_t i = 0; i < SHMEM_OWNER_SLOTS; i++) {
    shmem_owner *owner = &ns->owners[i];

    if (owner->pid == 0 || owner->refs == 0) {
      owner->pid = 0;
      owner->refs = 0;
      owner->reserved = 0;
      continue;
    }

    if (!shmem_process_alive(owner->pid)) {
      owner->pid = 0;
      owner->refs = 0;
      owner->reserved = 0;
      continue;
    }

    if ((uint64_t) INT32_MAX - (uint64_t) live_refs < owner->refs) {
      live_refs = INT32_MAX;
    } else {
      live_refs += (int32_t) owner->refs;
    }
  }

  ns->refcount = live_refs;
}

static bool shmem_namespace_register_owner_locked(shmem_namespace *ns) {
  uint64_t pid = shmem_current_pid();
  shmem_owner *empty_slot = NULL;

  shmem_namespace_sweep_dead_owners_locked(ns);

  for (size_t i = 0; i < SHMEM_OWNER_SLOTS; i++) {
    shmem_owner *owner = &ns->owners[i];

    if (owner->pid == pid) {
      if (owner->refs == UINT32_MAX || ns->refcount == INT32_MAX) {
        SDL_SetError("shared memory owner reference count overflow");
        return false;
      }

      owner->refs++;
      ns->refcount++;
      return true;
    }

    if (owner->pid == 0 && empty_slot == NULL) {
      empty_slot = owner;
    }
  }

  if (empty_slot == NULL) {
    SDL_SetError("too many processes are using this shared memory namespace");
    return false;
  }

  empty_slot->pid = pid;
  empty_slot->refs = 1;
  empty_slot->reserved = 0;
  if (ns->refcount < INT32_MAX) {
    ns->refcount++;
  }
  return true;
}

static bool shmem_namespace_unregister_owner_locked(shmem_namespace *ns) {
  uint64_t pid = shmem_current_pid();
  bool has_live_owners = false;

  shmem_namespace_sweep_dead_owners_locked(ns);

  for (size_t i = 0; i < SHMEM_OWNER_SLOTS; i++) {
    shmem_owner *owner = &ns->owners[i];

    if (owner->pid != pid) {
      continue;
    }

    if (owner->refs > 0) {
      owner->refs--;
      if (ns->refcount > 0) {
        ns->refcount--;
      }
    }

    if (owner->refs == 0) {
      owner->pid = 0;
      owner->reserved = 0;
    }
    break;
  }

  for (size_t i = 0; i < SHMEM_OWNER_SLOTS; i++) {
    if (ns->owners[i].pid != 0 && ns->owners[i].refs > 0) {
      has_live_owners = true;
      break;
    }
  }

  return !has_live_owners;
}

static bool shmem_container_sync_region_locked(shmem_container *container) {
  shmem_namespace *ns = container->namespace;
  size_t header_size = shmem_namespace_header_size(ns->capacity);
  size_t expected_size;

  if (!shmem_add_sizes(header_size, ns->data_capacity, &expected_size)) {
    return false;
  }

  if (expected_size != container->region->size) {
    if (!shmem_region_remap(container->region, expected_size, false)) {
      return false;
    }
    container->namespace = (shmem_namespace *) container->region->map;
  }

  return true;
}

static bool shmem_container_reserve_locked(
  shmem_container *container,
  size_t data_capacity
) {
  size_t header_size = shmem_namespace_header_size(container->namespace->capacity);
  size_t next_capacity = container->namespace->data_capacity;
  size_t region_size;

  if (data_capacity <= next_capacity) {
    return true;
  }

  if (next_capacity < SHMEM_INITIAL_DATA_CAPACITY) {
    next_capacity = SHMEM_INITIAL_DATA_CAPACITY;
  }

  while (next_capacity < data_capacity) {
    if (next_capacity > SIZE_MAX / 2) {
      next_capacity = data_capacity;
      break;
    }
    next_capacity *= 2;
  }

  if (!shmem_add_sizes(header_size, next_capacity, &region_size)) {
    return false;
  }

  if (!shmem_region_remap(container->region, region_size, true)) {
    return false;
  }

  container->namespace = (shmem_namespace *) container->region->map;
  container->namespace->data_capacity = next_capacity;
  return true;
}

static bool shmem_container_ns_entries_set(
  shmem_container *container,
  const char *name,
  const char *value,
  size_t value_size
) {
  bool updated = false;
  shmem_namespace *ns;
  char *data;
  size_t required_data_capacity;

  shmem_mutex_lock(container->mutex);
  if (!shmem_container_sync_region_locked(container)) {
    goto shmem_set_end;
  }

  ns = container->namespace;
  data = shmem_namespace_data(container);

  long int pos = shmem_container_find_index(container, name);
  size_t old_size = 0;
  size_t old_offset = ns->data_used;
  bool found = pos != -1;

  if (found) {
    old_size = ns->entries[pos].size;
    old_offset = ns->entries[pos].offset;
  } else {
    pos = (long int) ns->size;
    if ((size_t) pos >= ns->capacity) {
      goto shmem_set_end;
    }
  }

  required_data_capacity = ns->data_used - old_size + value_size;
  if (!shmem_container_reserve_locked(container, required_data_capacity)) {
    goto shmem_set_end;
  }

  ns = container->namespace;
  data = shmem_namespace_data(container);

  if (found) {
    size_t tail_offset = old_offset + old_size;
    size_t tail_size = ns->data_used - tail_offset;

    if (value_size != old_size && tail_size > 0) {
      memmove(
        data + old_offset + value_size,
        data + tail_offset,
        tail_size
      );
    }

    if (value_size != old_size) {
      shmem_container_shift_offsets(
        container,
        old_offset,
        (ptrdiff_t) value_size - (ptrdiff_t) old_size
      );
      ns->data_used = ns->data_used - old_size + value_size;
    }
  } else {
    old_offset = ns->data_used;
    ns->data_used += value_size;
  }

  snprintf(ns->entries[pos].name, sizeof(ns->entries[pos].name), "%s", name);
  ns->entries[pos].offset = old_offset;
  ns->entries[pos].size = value_size;
  if (value_size > 0) {
    memcpy(data + old_offset, value, value_size);
  }

  if (!found) {
    ns->size++;
  }
  updated = true;

shmem_set_end:
  shmem_mutex_unlock(container->mutex);
  return updated;
}

static char *shmem_container_ns_entries_get(
  shmem_container *container,
  const char *name,
  size_t *data_len,
  bool *found
) {
  char *copy = NULL;
  shmem_namespace *ns = container->namespace;
  char *data = shmem_namespace_data(container);
  *data_len = 0;
  *found = false;

  shmem_mutex_lock(container->mutex);
  if (!shmem_container_sync_region_locked(container)) {
    goto shmem_get_end;
  }

  ns = container->namespace;
  data = shmem_namespace_data(container);

  long int pos = shmem_container_find_index(container, name);
  if (pos != -1) {
    shmem_entry *entry = &ns->entries[pos];
    if (entry->size > 0) {
      copy = SDL_malloc(entry->size);
    }
    if (!copy && entry->size > 0) {
      SDL_OutOfMemory();
      goto shmem_get_end;
    }

    if (entry->size > 0) {
      memcpy(copy, data + entry->offset, entry->size);
    }
    *data_len = entry->size;
    *found = true;
  }

shmem_get_end:
  shmem_mutex_unlock(container->mutex);
  return copy;
}

static char *shmem_container_ns_entries_get_by_position(
  shmem_container *container,
  size_t position,
  char *name,
  size_t *data_len,
  bool *found
) {
  char *copy = NULL;
  shmem_namespace *ns = container->namespace;
  char *data = shmem_namespace_data(container);
  *data_len = 0;
  *found = false;

  shmem_mutex_lock(container->mutex);
  if (!shmem_container_sync_region_locked(container)) {
    goto shmem_get_by_position_end;
  }

  ns = container->namespace;
  data = shmem_namespace_data(container);

  if (position < ns->size) {
    shmem_entry *entry = &ns->entries[position];
    snprintf(name, SHMEM_NAME_LEN, "%s", entry->name);

    if (entry->size > 0) {
      copy = SDL_malloc(entry->size);
    }
    if (!copy && entry->size > 0) {
      SDL_OutOfMemory();
      goto shmem_get_by_position_end;
    }

    if (entry->size > 0) {
      memcpy(copy, data + entry->offset, entry->size);
    }
    *data_len = entry->size;
    *found = true;
  }

shmem_get_by_position_end:
  shmem_mutex_unlock(container->mutex);
  return copy;
}

static void shmem_container_ns_entries_remove(
  shmem_container *container,
  const char *name
) {
  shmem_namespace *ns;
  char *data;

  shmem_mutex_lock(container->mutex);
  if (!shmem_container_sync_region_locked(container)) {
    goto shmem_remove_end;
  }

  ns = container->namespace;
  data = shmem_namespace_data(container);

  long int pos = shmem_container_find_index(container, name);
  if (pos != -1) {
    shmem_entry *entry = &ns->entries[pos];
    size_t tail_offset = entry->offset + entry->size;
    size_t tail_size = ns->data_used - tail_offset;

    if (tail_size > 0) {
      memmove(data + entry->offset, data + tail_offset, tail_size);
    }

    if (entry->size > 0) {
      shmem_container_shift_offsets(container, entry->offset, -((ptrdiff_t) entry->size));
      ns->data_used -= entry->size;
    }

    if ((size_t) pos + 1 < ns->size) {
      memmove(
        &ns->entries[pos],
        &ns->entries[pos + 1],
        sizeof(shmem_entry) * (ns->size - ((size_t) pos + 1))
      );
    }

    ns->size--;
    memset(&ns->entries[ns->size], 0, sizeof(shmem_entry));
  }

shmem_remove_end:
  shmem_mutex_unlock(container->mutex);
}

static void shmem_container_ns_entries_clear(
  shmem_container *container
) {
  shmem_namespace *ns;

  shmem_mutex_lock(container->mutex);
  if (!shmem_container_sync_region_locked(container)) {
    goto shmem_clear_end;
  }

  ns = container->namespace;
  memset(ns->entries, 0, ns->capacity * sizeof(shmem_entry));
  ns->size = 0;
  ns->data_used = 0;

shmem_clear_end:
  shmem_mutex_unlock(container->mutex);
}

static size_t shmem_container_ns_get_size(shmem_container *container) {
  size_t size;
  shmem_mutex_lock(container->mutex);
  if (!shmem_container_sync_region_locked(container)) {
    shmem_mutex_unlock(container->mutex);
    return 0;
  }
  size = container->namespace->size;
  shmem_mutex_unlock(container->mutex);
  return size;
}

static size_t shmem_container_ns_get_capacity(shmem_container *container) {
  size_t capacity;
  shmem_mutex_lock(container->mutex);
  if (!shmem_container_sync_region_locked(container)) {
    shmem_mutex_unlock(container->mutex);
    return 0;
  }
  capacity = container->namespace->capacity;
  shmem_mutex_unlock(container->mutex);
  return capacity;
}

static shmem_container *shmem_container_open(
  const char *namespace_name,
  size_t capacity
) {
  size_t header_size;
  if (!shmem_compute_header_size(capacity, &header_size)) {
    return NULL;
  }

  shmem_container *container = SDL_calloc(1, sizeof(shmem_container));
  if (!container) {
    SDL_OutOfMemory();
    return NULL;
  }

  char region_name[SHMEM_NAME_LEN];
  shmem_ns_name(region_name, sizeof(region_name), namespace_name);

  shmem_region *region = shmem_region_open(region_name, header_size);
  if (!region) {
    goto shmem_container_open_error;
  }

  char mutex_name[SHMEM_NS_LEN];
  shmem_mutex_name(mutex_name, namespace_name);

  shmem_mutex *mutex = shmem_mutex_open(mutex_name);
  if (!mutex) {
    shmem_region_close(region, region->created);
    goto shmem_container_open_error;
  }

  container->region = region;
  container->mutex = mutex;
  container->namespace = (shmem_namespace *) region->map;

  shmem_mutex_lock(mutex);
  if (region->created) {
    memset(region->map, 0, region->size);
    container->namespace->magic = SHMEM_MAGIC;
    container->namespace->version = SHMEM_VERSION;
    container->namespace->refcount = 0;
    container->namespace->size = 0;
    container->namespace->capacity = capacity;
    container->namespace->data_capacity = 0;
    container->namespace->data_used = 0;
  } else {
    shmem_namespace *ns = container->namespace;
    size_t expected_size;
    if (
      ns->magic != SHMEM_MAGIC
      || ns->version != SHMEM_VERSION
      || ns->capacity != capacity
    ) {
      shmem_mutex_unlock(mutex);
      shmem_mutex_close(mutex, false);
      shmem_region_close(region, false);
      SDL_SetError(
        "shared memory container '%s' already exists with incompatible layout",
        namespace_name
      );
      goto shmem_container_open_error;
    }
    if (
      !shmem_add_sizes(header_size, ns->data_capacity, &expected_size)
      || expected_size != region->size
    ) {
      shmem_mutex_unlock(mutex);
      shmem_mutex_close(mutex, false);
      shmem_region_close(region, false);
      SDL_SetError(
        "shared memory container '%s' already exists with incompatible layout",
        namespace_name
      );
      goto shmem_container_open_error;
    }
  }
  if (!shmem_namespace_register_owner_locked(container->namespace)) {
    shmem_mutex_unlock(mutex);
    shmem_mutex_close(mutex, region->created);
    shmem_region_close(region, region->created);
    goto shmem_container_open_error;
  }
  shmem_mutex_unlock(mutex);

  return container;

shmem_container_open_error:
  SDL_free(container);
  return NULL;
}

static void shmem_container_close(shmem_container *container) {
  bool unregister = false;

  shmem_mutex_lock(container->mutex);
  unregister = shmem_namespace_unregister_owner_locked(container->namespace);
  shmem_mutex_unlock(container->mutex);

  shmem_mutex_close(container->mutex, unregister);
  shmem_region_close(container->region, unregister);
  SDL_free(container);
}

static int l_shmem_pairs_iterator(lua_State *L) {
  l_shmem_state *state = (l_shmem_state *) lua_touserdata(L, lua_upvalueindex(2));

  while (state->position < shmem_container_ns_get_size(state->container)) {
    char name[SHMEM_NAME_LEN];
    size_t data_len;
    bool found;
    char *data = shmem_container_ns_entries_get_by_position(
      state->container,
      state->position,
      name,
      &data_len,
      &found
    );
    state->position++;

    if (found) {
      lua_pushstring(L, name);
      lua_pushlstring(L, data ? data : "", data_len);
      SDL_free(data);
      return 2;
    }
  }

  return 0;
}

static int f_shmem_open(lua_State *L) {
  const char *namespace_name = luaL_checkstring(L, 1);
  lua_Integer capacity_value = luaL_checkinteger(L, 2);

  if (capacity_value <= 0) {
    return luaL_error(L, "capacity must be a positive integer");
  }

  if (!shmem_name_valid(namespace_name)) {
    return luaL_error(
      L,
      "namespace can not be longer than %d characters or contain any '/' or '\\'",
      SHMEM_NAME_LEN - 1
    );
  }

  shmem_container *container = shmem_container_open(
    namespace_name,
    (size_t) capacity_value
  );
  if (!container) {
    lua_pushnil(L);
    lua_pushstring(L, SDL_GetError());
    return 2;
  }

  l_shmem_container *self = lua_newuserdata(L, sizeof(l_shmem_container));
  self->container = container;
  luaL_setmetatable(L, API_TYPE_SHARED_MEMORY);
  return 1;
}

static int m_shmem_set(lua_State *L) {
  shmem_container *self = L_SHMEM_SELF(L, 1);
  const char *name = luaL_checkstring(L, 2);
  size_t value_len;
  const char *value = luaL_checklstring(L, 3, &value_len);

  if (!shmem_name_valid(name)) {
    return luaL_error(
      L,
      "name can not be longer than %d characters or contain any '/' or '\\'",
      SHMEM_NAME_LEN - 1
    );
  }

  lua_pushboolean(L, shmem_container_ns_entries_set(self, name, value, value_len));
  return 1;
}

static int m_shmem_get(lua_State *L) {
  shmem_container *self = L_SHMEM_SELF(L, 1);
  char *data = NULL;
  size_t data_len = 0;
  bool found = false;

  if (lua_type(L, 2) == LUA_TSTRING) {
    const char *name = luaL_checkstring(L, 2);
    data = shmem_container_ns_entries_get(self, name, &data_len, &found);
  } else if (lua_type(L, 2) == LUA_TNUMBER) {
    lua_Integer position = luaL_checkinteger(L, 2);
    if (position >= 1) {
      char name[SHMEM_NAME_LEN];
      data = shmem_container_ns_entries_get_by_position(
        self,
        (size_t) (position - 1),
        name,
        &data_len,
        &found
      );
    }
  } else {
    return luaL_typeerror(L, 2, "string or integer");
  }

  if (found) {
    lua_pushlstring(L, data ? data : "", data_len);
    SDL_free(data);
  } else {
    lua_pushnil(L);
  }
  return 1;
}

static int m_shmem_remove(lua_State *L) {
  shmem_container *self = L_SHMEM_SELF(L, 1);
  const char *name = luaL_checkstring(L, 2);
  shmem_container_ns_entries_remove(self, name);
  return 0;
}

static int m_shmem_clear(lua_State *L) {
  shmem_container *self = L_SHMEM_SELF(L, 1);
  shmem_container_ns_entries_clear(self);
  return 0;
}

static int m_shmem_size(lua_State *L) {
  lua_pushinteger(L, shmem_container_ns_get_size(L_SHMEM_SELF(L, 1)));
  return 1;
}

static int m_shmem_capacity(lua_State *L) {
  lua_pushinteger(L, shmem_container_ns_get_capacity(L_SHMEM_SELF(L, 1)));
  return 1;
}

static int mm_shmem_pairs(lua_State *L) {
  shmem_container *self = L_SHMEM_SELF(L, 1);

  l_shmem_state *state = lua_newuserdata(L, sizeof(l_shmem_state));
  state->container = self;
  state->position = 0;

  lua_pushcclosure(L, l_shmem_pairs_iterator, 2);
  return 1;
}

static int mm_shmem_gc(lua_State *L) {
  shmem_container_close(L_SHMEM_SELF(L, 1));
  return 0;
}

static const luaL_Reg shmem_lib[] = {
  { "open", f_shmem_open },
  { NULL, NULL }
};

static const luaL_Reg shmem_class[] = {
  { "set", m_shmem_set },
  { "get", m_shmem_get },
  { "remove", m_shmem_remove },
  { "clear", m_shmem_clear },
  { "size", m_shmem_size },
  { "capacity", m_shmem_capacity },
  { "__pairs", mm_shmem_pairs },
  { "__gc", mm_shmem_gc },
  { NULL, NULL }
};

int luaopen_shmem(lua_State *L) {
  luaL_newmetatable(L, API_TYPE_SHARED_MEMORY);
  luaL_setfuncs(L, shmem_class, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");

  luaL_newlib(L, shmem_lib);
  return 1;
}
