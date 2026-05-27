#include <stdio.h>
#define SCALE(value) ((value) * 2)

typedef struct Point {
  int x;
  int y;
} Point;

static int distance(Point point) {
  for (int i = 0; i < 3; ++i) {
    point.x += i;
  }
  return SCALE(point.x) + point.y;
}

int main(void) {
  Point origin = { .x = 1, .y = 2 };
  switch (distance(origin)) {
    case 0: puts("zero"); break;
    default: printf("%d\n", distance(origin));
  }
  return 0;
}

enum Mode { MODE_READ, MODE_WRITE };
union Number { int i; float f; };
static const unsigned long FLAGS = 0x10UL;

#define #elif #else #elseif #endif #error #if #ifdef #ifndef #include #pragma #warning NULL auto bool break case char const continue default do double else elseif enum extern false float for goto if inline int long return short static struct switch then true typedef union unsigned void volatile while ;
