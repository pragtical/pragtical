class Widget
  new: (@name = "demo") =>

  render: (items) =>
    for item in *items
      if item.enabled
        "#{@name}:#{item.label}"

widget = Widget "main"
print table.concat widget\render({ enabled: true, label: "alpha" }), ", "
