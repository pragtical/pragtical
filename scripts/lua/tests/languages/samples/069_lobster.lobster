class Widget:
  name:string

def render(w:Widget, items):
  var out = []
  for item in items:
    if item.enabled:
      out.push(w.name + ":" + item.label)
  return out

print(render(Widget { name: "demo" }, []))
