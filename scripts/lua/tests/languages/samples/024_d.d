module demo.widget;

import std.stdio;
import std.algorithm;
import std.exception;

interface Renderer {
  string render(string[] items);
}

enum Status {
  ready,
  disabled,
}

mixin template Named(string defaultName) {
  private string name = defaultName;
}

class Widget : Renderer {
  mixin Named!"demo";
  private string name;
  this(string name = "demo") { this.name = name; }

  override string render(string[] items) {
    scope(exit) writeln("rendered");
    enforce(items.length > 0);
    return items.filter!(a => a.length > 0)
      .map!(a => name ~ ":" ~ a)
      .joiner(",")
      .text;
  }
}

void main() {
  auto widget = new Widget("main");
  final switch (Status.ready) {
    case Status.ready: writeln(widget.render(["alpha", "beta"])); break;
    case Status.disabled: break;
  }
}
