local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"

---Application-menu commands: bar visibility is independent of opening its popup.
---Alt+M opens or closes the popup; Alt+Shift+M toggles the bar's visibility.
command.add(nil, {
  ["menu-bar:show"] = function() core.menu_view:show() end,
  ["menu-bar:hide"] = function() core.menu_view:hide() end,
  ["menu-bar:toggle"] = function() core.menu_view:toggle() end,
  ["menu-bar:open"] = function()
    if core.menu_view.menu.show_context_menu then
      core.menu_view.menu:hide()
    else
      core.menu_view:open()
    end
  end
})

keymap.add {
  ["alt+m"] = "menu-bar:open",
  ["alt+shift+m"] = "menu-bar:toggle"
}
