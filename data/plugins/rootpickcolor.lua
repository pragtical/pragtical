-- mod-version:3
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local RootView = require "core.rootview"

local cx, cy, pick_color, mode, color = 0, 0, false, "rgb", {0, 0, 0, 255}

local rootview_on_mouse_moved = RootView.on_mouse_moved
function RootView:on_mouse_moved(x, y, dx, dy)
  rootview_on_mouse_moved(self, x, y, dx, dy)
  cx, cy = x, y
end

local rootviewon_mouse_pressed = RootView.on_mouse_pressed
function RootView:on_mouse_pressed(button, x, y, clicks)
  rootviewon_mouse_pressed(self, button, x, y, clicks)
  if pick_color and button == "left" then
    pick_color = false
    local c = string.format(
      mode == "rgb" and "rgb(%d,%d,%d)" or "#%02x%02x%02x",
      color[1], color[2], color[3]
    )
    core.log("Color %s copied to clipboard", c)
    system.set_clipboard(c)
  end
end

local function draw_color_box()
  local spacing = 30
  renderer.draw_rect(
    cx + spacing - style.divider_size, cy - style.divider_size,
    (spacing * SCALE) + (style.divider_size * 2),
    (spacing * SCALE) + (style.divider_size * 2),
    style.text
  )

  color = core.window:get_color(cx, cy)

  renderer.draw_rect(
    cx + spacing, cy,
    spacing * SCALE, spacing * SCALE,
    color
  )
end

local rootview_draw = RootView.draw
function RootView:draw()
  rootview_draw(self)
  if pick_color then
    system.set_cursor("arrow")
    core.root_view:defer_draw(draw_color_box)
  end
end

command.add(nil, {
  ["root:pick-rgb-color"] = function()
    pick_color = true
    mode = "rgb"
    core.log("RGB Color Picker activated")
  end,
  ["root:pick-hex-color"] = function()
    pick_color = true
    mode = "hex"
    core.log("HEX Color Picker activated")
  end
})

command.add(function() return pick_color end, {
  ["root:pick-color-cancel"] = function()
    pick_color = false
  end
})

keymap.add_direct({
  ["ctrl+1"] = "root:pick-rgb-color",
  ["ctrl+2"] = "root:pick-hex-color",
  ["escape"] = "root:pick-color-cancel",
})
