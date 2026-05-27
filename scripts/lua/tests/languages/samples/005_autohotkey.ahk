#Requires AutoHotkey v2.0
class Widget {
  __New(name := "demo") {
    this.name := name
  }
  Render(items) {
    for index, item in items {
      if item.Enabled
        MsgBox this.name ":" item.Label
    }
  }
}
Hotkey "^!r", (*) => Widget("main").Render([{Enabled: true, Label: "alpha"}])
