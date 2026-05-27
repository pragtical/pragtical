version       = "1.0.0"
author        = "Pragtical"
description   = "Tokenizer fixture"
license       = "MIT"
srcDir        = "src"
bin           = @["fixture"]

requires "nim >= 2.0.0"

type
  Widget = ref object
    name: string
    count: int

proc render(widget: Widget; items: openArray[string]): seq[string] =
  for item in items:
    if item.len > 0:
      result.add fmt"{widget.name}:{item}"

iterator enabled(items: openArray[string]): string =
  for item in items:
    if item != "":
      yield item

template withWidget(name: string; body: untyped) =
  let widget {.inject.} = Widget(name: name)
  body

macro debugTree(body: untyped): untyped =
  result = body

task test, "Run tests":
  withWidget "main":
    echo widget.render(@["alpha", "beta"])
  exec "nim r tests/test_fixture.nim"
