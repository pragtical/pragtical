use fmt;
use strings;

type widget = struct {
  name: str,
};

type status = enum {
  ready,
  disabled,
};

fn render(w: *widget, items: []str) void = {
  for (let i = 0z; i < len(items); i += 1) {
    match (strings::compare(items[i], "")) {
    case 0 =>
      continue;
    case =>
      fmt::printfln("{}:{}", w.name, items[i])!;
    };
  };
};

export fn main() void = {
  let w = widget { name = "demo" };
  defer fmt::println("done")!;
  const state = status::ready;
  assert(state == status::ready);
  render(&w, ["alpha", "beta"]);
};
