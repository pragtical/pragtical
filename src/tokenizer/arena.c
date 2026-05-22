#include "arena.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifdef _MSC_VER
  #ifndef alignof
    #define alignof _Alignof
  #endif
  #ifndef __clang__
    typedef long double max_align_t;
  #endif
#else
  #include <stdalign.h>
#endif

struct ArenaChunk {
  unsigned char *memory;
  size_t capacity;
  size_t offset;
  ArenaChunk *next;
};

static bool arena_size_add(size_t a, size_t b, size_t *result) {
  if (a > SIZE_MAX - b) return false;
  *result = a + b;
  return true;
}

static bool arena_size_mul(size_t a, size_t b, size_t *result) {
  if (a != 0 && b > SIZE_MAX / a) return false;
  *result = a * b;
  return true;
}

static bool arena_is_pow2(size_t value) {
  return value != 0 && (value & (value - 1)) == 0;
}

static size_t arena_align_forward(uintptr_t ptr, size_t align) {
  uintptr_t mask = (uintptr_t) align - 1;
  return (size_t) ((ptr + mask) & ~mask);
}

static bool arena_chunk_can_fit(const ArenaChunk *chunk, size_t size, size_t align) {
  size_t aligned_offset = arena_align_forward((uintptr_t) chunk->memory + chunk->offset, align) -
    (size_t) (uintptr_t) chunk->memory;
  size_t needed = 0;
  return arena_size_add(aligned_offset, size, &needed) && needed <= chunk->capacity;
}

static ArenaChunk *arena_chunk_alloc(size_t capacity) {
  ArenaChunk *chunk = (ArenaChunk *) malloc(sizeof(ArenaChunk));
  if (!chunk) return NULL;

  chunk->memory = (unsigned char *) malloc(capacity);
  if (!chunk->memory) {
    free(chunk);
    return NULL;
  }

  chunk->capacity = capacity;
  chunk->offset = 0;
  chunk->next = NULL;
  return chunk;
}

static ArenaChunk *arena_append_chunk(Arena *arena, size_t min_capacity) {
  size_t capacity = arena->initial_capacity ? arena->initial_capacity : 64;
  while (capacity < min_capacity) {
    if (capacity > SIZE_MAX / 2) {
      capacity = min_capacity;
      break;
    }
    capacity *= 2;
  }

  ArenaChunk *chunk = arena_chunk_alloc(capacity);
  if (!chunk) return NULL;

  if (!arena->head) {
    arena->head = chunk;
  } else {
    ArenaChunk *tail = arena->head;
    while (tail->next) tail = tail->next;
    tail->next = chunk;
  }

  arena->current = chunk;
  return chunk;
}

static ArenaChunk *arena_find_chunk(Arena *arena, size_t size, size_t align) {
  ArenaChunk *chunk = arena->current ? arena->current : arena->head;
  while (chunk) {
    if (arena_chunk_can_fit(chunk, size, align)) return chunk;
    chunk = chunk->next;
  }

  size_t min_capacity = 0;
  if (!arena_size_add(size, align - 1, &min_capacity)) return NULL;
  return arena_append_chunk(arena, min_capacity);
}

int arena_init(Arena *arena, size_t initial_capacity) {
  arena->initial_capacity = initial_capacity ? initial_capacity : 64;
  arena->head = NULL;
  arena->current = NULL;
  return arena_append_chunk(arena, arena->initial_capacity) != NULL;
}

void arena_free(Arena *arena) {
  ArenaChunk *chunk = arena->head;
  while (chunk) {
    ArenaChunk *next = chunk->next;
    free(chunk->memory);
    free(chunk);
    chunk = next;
  }

  arena->head = NULL;
  arena->current = NULL;
}

void arena_reset(Arena *arena) {
  ArenaChunk *chunk = arena->head;
  while (chunk) {
    chunk->offset = 0;
    chunk = chunk->next;
  }
  arena->current = arena->head;
}

void *arena_alloc_aligned(Arena *arena, size_t size, size_t align) {
  if (!arena || !arena_is_pow2(align)) return NULL;

  ArenaChunk *chunk = arena_find_chunk(arena, size, align);
  if (!chunk) return NULL;

  size_t aligned_offset = arena_align_forward((uintptr_t) chunk->memory + chunk->offset, align) -
    (size_t) (uintptr_t) chunk->memory;
  size_t next_offset = 0;
  if (!arena_size_add(aligned_offset, size, &next_offset) || next_offset > chunk->capacity) {
    return NULL;
  }

  void *ptr = chunk->memory + aligned_offset;
  chunk->offset = next_offset;
  arena->current = chunk;
  return ptr;
}

void *arena_alloc(Arena *arena, size_t size) {
  return arena_alloc_aligned(arena, size, alignof(max_align_t));
}

void *arena_calloc(Arena *arena, size_t count, size_t size) {
  size_t total = 0;
  if (!arena_size_mul(count, size, &total)) return NULL;

  void *ptr = arena_alloc(arena, total);
  if (ptr) memset(ptr, 0, total);
  return ptr;
}

void *arena_copy(Arena *arena, const void *ptr, size_t len) {
  if (!ptr) return NULL;
  char *output = arena_alloc(arena, len);
  return output ? memcpy(output, ptr, len) : NULL;
}

char *arena_strdup(Arena *arena, const char *str) {
  size_t len = strlen(str) + 1;
  char *copy = arena_alloc(arena, len);
  if (copy) memcpy(copy, str, len);
  return copy;
}
