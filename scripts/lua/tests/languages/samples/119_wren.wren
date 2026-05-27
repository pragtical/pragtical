class Widget {
  construct new(name) {
    _name = name
  }

  render(items) {
    var out = []
    for (item in items) {
      if (item.enabled) out.add("%(_name):%(item.label)")
    }
    return out.join(", ")
  }
}
