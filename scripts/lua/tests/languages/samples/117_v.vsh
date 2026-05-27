module main

import os

@[heap]
struct Widget {
mut:
  name string
}

interface Renderer {
  render([]string) []string
}

fn (w &Widget) render(items []string) []string {
  mut out := []string{}
  for item in items {
    match item {
      '' { continue }
      else {
        assert item.len > 0
      }
    }
    if item.len > 0 && item !in ['skip'] {
      out << '${w.name}:$item'
    }
  }
  return out
}

#flag linux -I/usr/include
#pkgconfig --libs sqlite3
#include <stdio.h>

fn main() {
  mut widget := Widget{name: os.getenv('WIDGET_NAME')}
  if widget.name == '' {
    widget.name = 'demo'
  }
  spawn widget.render(['alpha', r'raw\ntext', c"c-string"])
  println(@FILE_LINE)
}
