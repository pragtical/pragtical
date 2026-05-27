Widget = {}
Widget.name = "demo"
Widget.render = function(items)
  output = []
  for item in items
    if item.enabled then output.push Widget.name + ":" + item.label
  end for
  return output
end function

print Widget.render([{"enabled": true, "label": "alpha"}])
