package demo

import "core:fmt"

Widget :: struct {
  name: string,
  count: int,
}

Status :: enum {
  Ready,
  Disabled,
}

Value :: union {
  string,
  int,
}

render :: proc(widget: Widget, items: []string) -> string {
  defer fmt.println("rendered", widget.name)
  for item in items {
    switch {
    case item in []string{"skip", ""}:
      continue
    case len(item) > 0:
      fmt.println(widget.name, item)
    }
  }
  return widget.name
}

main :: proc() {
  values := map[string]Value{"name" = "main"}
  when ODIN_OS == .Linux {
    fmt.println(values, size_of(Widget), type_of(Status.Ready))
  }
}
