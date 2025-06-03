local style = require "core.style"
local common = require "core.common"

style.background = { common.color "#2c2c2c" }  -- Docview
style.background2 = { common.color "#222222" } -- Treeview
style.background3 = { common.color "#222222" } -- Command view
style.text = { common.color "#C0BFBC" }
style.caret = { common.color "#3771c8" }
style.accent = { common.color "#FCFCFC" }
-- style.dim - text color for nonactive tabs, tabs divider, prefix in log and
-- search result, hotkeys for context menu and command view
style.dim = { common.color "#77767B" }
style.divider = { common.color "#181818" } -- Line between nodes
style.selection = { common.color "#424242" }
style.line_number = { common.color "#525259" }
style.line_number2 = { common.color "#FCFCFC" } -- With cursor
style.line_highlight = { common.color "#3B3A3F" }
style.scrollbar = { common.color "#8d8d8d" }
style.scrollbar2 = { common.color "#adadad" } -- Hovered
style.scrollbar_track = { common.color "#262626" }
style.nagbar = { common.color "#DE374C" }
style.nagbar_text = { common.color "#F6F5F4" }
style.nagbar_dim = { common.color "rgba(0, 0, 0, 0.45)" }
style.drag_overlay = { common.color "rgba(255,255,255,0.1)" }
style.drag_overlay_tab = { common.color "#3771c8" }
style.good = { common.color "#47D35C" }
style.warn = { common.color "#FAA82F" }
style.error = { common.color "#c7162b" }
style.modified = { common.color "#19B6EE" }

style.syntax["normal"] = { common.color "#C0BFBC" }
style.syntax["symbol"] = { common.color "#B0AFAC" }
style.syntax["comment"] = { common.color "#77767B" }
style.syntax["keyword"] = { common.color "#34B948" }  -- local function end if case
style.syntax["keyword2"] = { common.color "#EA485C" } -- self int float
style.syntax["number"] = { common.color "#47c4f1" }
style.syntax["literal"] = { common.color "#F99B11" }  -- true false nil
style.syntax["string"] = { common.color "#FBC16A" }
style.syntax["operator"] = { common.color "#ED764D" } -- = + - / < >
style.syntax["function"] = { common.color "#c590bf" }

style.log["INFO"]  = { icon = "i", color = style.text }
style.log["WARN"]  = { icon = "!", color = style.warn }
style.log["ERROR"] = { icon = "!", color = style.error }

return style
