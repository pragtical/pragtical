#include <stddef.h>

typedef struct ArenaChunk ArenaChunk;

typedef struct Arena {
  size_t initial_capacity;
  ArenaChunk *head;
  ArenaChunk *current;
} Arena;

/* Initialize arena */
int arena_init(Arena *arena, size_t capacity);

/* Free arena memory */
void arena_free(Arena *arena);

/* Reset arena allocations */
void arena_reset(Arena *arena);

/* Allocate memory with alignment */
void *arena_alloc_aligned(Arena *arena, size_t size, size_t align);

/* Default allocation */
void *arena_alloc(Arena *arena, size_t size);

/* Zeroed allocation */
void *arena_calloc(Arena *arena, size_t count, size_t size);

/* Copy bytes into arena */
void *arena_copy(Arena *arena, const void *ptr, size_t len);

/* Duplicate string into arena */
char *arena_strdup(Arena *arena, const char *str);
