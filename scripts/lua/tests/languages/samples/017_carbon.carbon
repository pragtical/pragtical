package Demo api;

class Widget {
  var name: String;

  fn Create(name: String) -> Widget {
    return {.name = name};
  }

  fn Render[self: Self](items: Array(String)) -> String {
    var out: String = "";
    for (item: String in items) {
      out = out + item;
    }
    return out;
  }
}
