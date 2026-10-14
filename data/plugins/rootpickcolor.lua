-- mod-version:3
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"

local cx, cy, pick_color, mode, color = 0, 0, false, "rgb", {0, 0, 0, 255}

local picker = View()

picker:set_floating(true, { focus = "none", pass_through_unhandled = true })

---Get the editor viewport bounds for a companion that draws outside its owner.
---@return number x Viewport screen x coordinate
---@return number y Viewport screen y coordinate
---@return number w Viewport width
---@return number h Viewport height
picker.get_floating_bounds = function()
  local root = core.root_view
  return root.position.x, root.position.y, root.size.x, root.size.y
end

---Ignore placement writes because the companion computes its bounds from its owner.
picker.set_floating_bounds = function() end

---Track the RootView pointer coordinates used to sample the editor color.
picker.update = function()
  cx, cy = common.round(core.root_view.mouse.x), common.round(core.root_view.mouse.y)
end

---Copy the sampled color on left-click and end picking; other clicks pass through.
---@param _ core.view Color picker companion
---@param button core.view.mousebutton Pressed button
---@return boolean consumed Whether a color was copied
picker.on_mouse_pressed = function(_, button)
  if button ~= "left" then return false end
  pick_color = false
  picker:hide_floating()
  local value = string.format(
    mode == "rgb" and "rgb(%d,%d,%d)" or "#%02x%02x%02x",
    color[1], color[2], color[3]
  )
  core.log("Color %s copied to clipboard", value)
  system.set_clipboard(value)
  return true
end

picker.draw = function()
  local spacing = 30
  local size = spacing * SCALE
  local border = style.divider_size

  color = core.window:get_color(cx, cy)

  -- Default position: right of cursor
  local bx = cx + spacing
  local by = cy

  -- Flip to left of cursor if overflowing right edge
  if bx + size + border * 2 > core.root_view.size.x then
    bx = cx - spacing - size
  end

  -- Keep color preview fully visible when reaching window bottom
  if by + size + border * 2 > core.root_view.size.y then
    by = core.root_view.size.y - size - border
  end

  -- Keep color preview fully visible when reaching window top
  if by <= 1 then by = border end

  -- Draw Border
  renderer.draw_rect(
    bx - border, by - border,
    size + border * 2, size + border * 2,
    style.text
  )

  -- Draw Color Fill
  renderer.draw_rect(bx, by, size, size, color)
end

command.add(nil, {
  ["root:pick-rgb-color"] = function()
    pick_color = true
    picker:show_floating()
    mode = "rgb"
    core.log("RGB Color Picker activated")
  end,
  ["root:pick-hex-color"] = function()
    pick_color = true
    picker:show_floating()
    mode = "hex"
    core.log("HEX Color Picker activated")
  end
})

command.add(function() return pick_color end, {
  ["root:pick-color-cancel"] = function()
    pick_color = false
    picker:hide_floating()
  end
})

keymap.add({
  ["ctrl+1"] = "root:pick-rgb-color",
  ["ctrl+2"] = "root:pick-hex-color",
  ["escape"] = "root:pick-color-cancel",
})

core.menu_view:register({ "tools" }, {
  {
    id = "rootcolorpicker", text = "Root Color Picker",
    items = {
      { id = "rgb", text = "RGB Format", command = "root:pick-rgb-color" },
      { id = "hex", text = "Hexadecimal Format", command = "root:pick-hex-color" }
    }
  }
}, "rootpickcolor")
