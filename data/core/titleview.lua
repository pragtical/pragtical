local core = require "core"
local common = require "core.common"
local style = require "core.style"
local View = require "core.view"

local icon_colors = {
  bg = { common.color "#21252bff" },
  color6 = { common.color "#ffffffff" },
  color7 = { common.color "#3771c8ff" },
  color8 = { common.color "#87aadeff" },
  color9 = { common.color "#ABC6EDFF" }
};

local restore_command = {
  symbol = "w", action = function() system.set_window_mode(core.window, "normal") end
}

local maximize_command = {
  symbol = "W", action = function() system.set_window_mode(core.window, "maximized") end
}

local title_commands = {
  {symbol = "_", action = function() system.set_window_mode(core.window, "minimized") end},
  maximize_command,
  {symbol = "X", action = function() core.quit() end},
}

---@class core.titleview : core.view
---@overload fun():core.titleview
---@field super core.view
---@field visible boolean Whether built-in window decorations are shown
---@field hit_test_enabled? boolean Whether native window hit testing is installed
---@field hit_test_bounds? table<string, number> Last supplied native geometry, including the interactive rectangle
local TitleView = View:extend()

function TitleView:__tostring() return "TitleView" end

---Get the decoration height for the current UI font and padding.
---@return number height Title bar height
local function title_view_height()
  return style.font:get_height() + style.padding.y * 2
end

---Get the horizontal space reserved for the three window controls.
---@return number width Control area including its spacing
local function controls_width()
  local icon_w = style.icon_font:get_width("_")
  return icon_w * (2 * #title_commands + 1)
end

---Initialize built-in window decorations.
function TitleView:new()
  TitleView.super.new(self)
  self.visible = true
end

---Get the menu/title area between the application logo and window controls.
---@return number x Screen x coordinate after the logo
---@return number y Screen y coordinate at the title bar's top
---@return number width Available width before the controls
---@return number height Title bar height
function TitleView:get_menu_bounds()
  local ox, oy = self:get_content_offset()
  local x = ox + style.padding.x + style.icon_font:get_width("9 ")
  return
    x, oy,
    math.max(0, ox + self.size.x - controls_width() - x),
    title_view_height()
end

---Supply application-menu placement while built-in decorations are visible.
---MenuView's node remains responsible for updating its animation once per frame.
function TitleView:update_menu_bounds()
  if self.visible then
    core.menu_view:set_bounds(self:get_menu_bounds())
  else
    core.menu_view:set_bounds()
  end
end

---Install native drag/resize regions, excluding the embedded menu from dragging.
---Unchanged geometry does not reinstall the native callback.
---@param borderless boolean Whether built-in decorations are active
function TitleView:configure_hit_test(borderless)
  if not borderless then
    if self.hit_test_enabled ~= false then
      system.set_window_hit_test(core.window)
    end
    self.hit_test_enabled, self.hit_test_bounds = false, nil
    return
  end
  local height = title_view_height()
  local controls = controls_width()
  local border = 3 * SCALE
  local x, y, w, h = 0, 0, 0, 0
  if core.menu_view.bounds then
    x, y, w, h = core.menu_view:get_bounds()
  end
  local previous = self.hit_test_bounds
  if previous and previous.height == height and previous.controls == controls
    and previous.border == border and previous.x == x and previous.y == y
    and previous.w == w and previous.h == h
  then return end
  local bounds = {
    height = height,
    controls = controls,
    border = border,
    x = x, y = y,
    w = w, h = h
  }
  self.hit_test_enabled, self.hit_test_bounds = true, bounds
  system.set_window_hit_test(
    core.window, height, controls, border,
    w > 0 and bounds or nil
  )
end

---Refresh the native title geometry after an interface scale change.
function TitleView:on_scale_change()
  self:update_menu_bounds()
  self:configure_hit_test(self.visible)
end

---Keep the title height and maximize/restore button synchronized with the window.
function TitleView:update()
  self.size.y = self.visible and title_view_height() or 0
  title_commands[2] = core.window_mode == "maximized"
    and restore_command
    or maximize_command
  TitleView.super.update(self)
  self:update_menu_bounds()
end

---Preserve document focus when interacting with title controls or embedded menus.
---@return nil target Title chrome never takes keyboard focus
function TitleView:get_focus_target()
  return nil
end

---Draw the logo, separate the embedded menu, and clip the remaining title space.
function TitleView:draw_window_title()
  local h = style.font:get_height()
  local ox, oy = self:get_content_offset()
  local color = style.text
  local x, y = ox + style.padding.x, oy + style.padding.y
  common.draw_text(style.icon_font, icon_colors.bg, "5", nil, x, y, 0, h)
  common.draw_text(style.icon_font, icon_colors.color6, "6", nil, x, y, 0, h)
  common.draw_text(style.icon_font, icon_colors.color7, "7", nil, x, y, 0, h)
  common.draw_text(style.icon_font, icon_colors.color8, "8", nil, x, y, 0, h)
  x = common.draw_text(style.icon_font, icon_colors.color9, "9 ", nil, x, y, 0, h)
  local _, _, available = self:get_menu_bounds()
  local menu_width = 0
  if core.menu_view.bounds then
    local _, _, width = core.menu_view:get_bounds()
    menu_width = width
  end
  x = x + menu_width
  local spacing = math.min(menu_width, style.padding.x * 2 + style.divider_size,
    math.max(0, available - menu_width))
  if spacing > 0 then
    local width = math.min(style.divider_size, spacing)
    -- Balance the title gap against the menu label's trailing padding too.
    local inset = math.min(style.padding.x / 2, (spacing - width) / 2)
    renderer.draw_rect(x + inset, y, width, h, style.dim)
    x = x + spacing
  end
  local title = core.compose_window_title(core.window_title)
  core.push_clip_rect(x, y, math.max(0, available - menu_width - spacing), h)
  common.draw_text(style.font, color, title, nil, x, y, 0, h)
  core.pop_clip_rect()
end

---Iterate window controls with their glyph rectangles in screen coordinates.
---@return fun():table, number, number, number, number iterator Control, x, y, width, height
function TitleView:each_control_item()
  local icon_h, icon_w = style.icon_font:get_height(), style.icon_font:get_width("_")
  local icon_spacing = icon_w
  local ox, oy = self:get_content_offset()
  ox = ox + self.size.x
  local i, n = 0, #title_commands
  local iter = function()
    i = i + 1
    if i <= n then
      local dx = - (icon_w + icon_spacing) * (n - i + 1)
      local dy = style.padding.y
      return title_commands[i], ox + dx, oy + dy, icon_w, icon_h
    end
  end
  return iter
end


---Draw the minimize, maximize/restore, and close controls.
function TitleView:draw_window_controls()
  for item, x, y, w, h in self:each_control_item() do
    local color = item == self.hovered_item and style.text or style.dim
    common.draw_text(style.icon_font, color, item.symbol, nil, x, y, 0, h)
  end
end

---Route clicks on embedded labels to the application menu.
---@param button core.view.mousebutton Pressed button
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param clicks integer Consecutive click count
---@return boolean? consumed Whether an embedded menu consumed the press
function TitleView:on_mouse_pressed(button, x, y, clicks)
  if core.menu_view.bounds and core.menu_view:hit_test(x, y) then
    self.hovered_item = nil
    return core.menu_view:on_mouse_pressed(button, x, y, clicks)
  end
  return TitleView.super.on_mouse_pressed(self, button, x, y, clicks)
end

---Complete a menu interaction or activate the hovered window control.
---@param button core.view.mousebutton Released button
---@param x number Screen x coordinate
---@param y number Screen y coordinate
function TitleView:on_mouse_released(button, x, y)
  TitleView.super.on_mouse_released(self, button, x, y)
  if core.menu_view.bounds and core.menu_view:hit_test(x, y) then
    core.menu_view:on_mouse_released(button, x, y)
  elseif button == "left" and self.hovered_item then
    self.hovered_item.action()
  end
end


---Clear window-control and embedded-menu hover when leaving the title bar.
function TitleView:on_mouse_left()
  TitleView.super.on_mouse_left(self)
  self.hovered_item = nil
  if core.menu_view.bounds then core.menu_view:on_mouse_left() end
end


---Update embedded-menu hover and window-control hover without taking focus.
---@param px number Screen x coordinate
---@param py number Screen y coordinate
---@param ... any Pointer movement deltas
function TitleView:on_mouse_moved(px, py, ...)
  if self.size.y == 0 then return end
  TitleView.super.on_mouse_moved(self, px, py, ...)
  self.hovered_item = nil
  if core.menu_view.bounds then core.menu_view:on_mouse_moved(px, py) end
  for item, x, y, w, h in self:each_control_item() do
    if px > x and py > y and px <= x + w and py <= y + h then
      self.hovered_item = item
      return
    end
  end
end


---Draw the shared title/menu row and synchronize its final laid-out native bounds.
function TitleView:draw()
  self:update_menu_bounds()
  self:configure_hit_test(self.visible)
  self:draw_background(style.background2)
  self:draw_window_title()
  if core.menu_view.bounds then core.menu_view:draw() end
  self:draw_window_controls()
end

return TitleView
