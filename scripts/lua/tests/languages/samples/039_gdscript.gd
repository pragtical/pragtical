extends Node
class_name Widget

signal rendered(label: String)

@export var title := "demo"
@onready var labels: Array[String] = []

enum State { READY, DISABLED }

class Item:
  var enabled := true
  var label := "alpha"

  func _init(value: String) -> void:
    label = value

func _ready() -> void:
  var state := State.READY
  match state:
    State.READY:
      for item in [Item.new("alpha")]:
        if item.enabled:
          labels.append("%s:%s" % [title, item.label])
    _:
      push_warning("disabled")
  await get_tree().process_frame
  emit_signal("rendered", ", ".join(labels))
