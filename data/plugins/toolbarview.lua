-- mod-version:3
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local keymap = require "core.keymap"
local View = require "core.view"

---Last drawn toolbar geometry, retained to refresh hover after layout or scrolling changes.
---@class plugins.toolbarview.layout
---@field x number Screen x coordinate
---@field y number Screen y coordinate
---@field w number Viewport width
---@field h number Viewport height
---@field icon_w number Maximum icon width
---@field icon_h number Maximum icon height

---@class plugins.toolbarview : core.view
---@overload fun():plugins.toolbarview
---@field orientation "vertical"|"horizontal" Direction used for icon layout and scrolling
---@field last_layout? plugins.toolbarview.layout Geometry used by the previous update
local ToolbarView = View:extend()

function ToolbarView:__tostring() return "ToolbarView" end

---Initialize a visible vertical toolbar and its default command icons.
---The owner supplies its position and length; update() calculates its thickness.
function ToolbarView:new()
  ToolbarView.super.new(self)
  self.visible = true
  self.init_size = true
  self.tooltip = false
  self.toolbar_font = style.icon_big_font
  self.orientation = "vertical"
  self.toolbar_commands = {
    {symbol = "M", command = "menu-bar:toggle"},
    {symbol = "f", command = "core:new-doc"},
    {symbol = "D", command = "core:open-file"},
    {symbol = "S", command = "doc:save"},
    {symbol = "L", command = "core:find-file"},
    {symbol = "B", command = "core:find-command"},
  }

  if command.is_valid("plugin-manager:show") then
    table.insert(self.toolbar_commands, {symbol = "p", command = "plugin-manager:show"})
  end

  table.insert(self.toolbar_commands, {symbol = "P", command = "core:open-user-module"})
end


---Set the icon layout and scrolling direction without moving or docking the toolbar.
---Clears pointer capture, hover and scrolling; update() fits the new thickness.
---The owner must supply the length and update any node locks for the new orientation.
---@param orientation "vertical"|"horizontal" Direction in which icons are arranged
function ToolbarView:set_orientation(orientation)
  assert(
    orientation == "vertical" or orientation == "horizontal",
    "Invalid toolbar orientation"
  )
  if self.orientation == orientation then return end
  local root = core.root_view
  if root.grab and root.grab.view == self then root:cancel_mouse_capture() end
  self:on_mouse_left()
  self.orientation = orientation
  self.scroll.x, self.scroll.y = 0, 0
  self.scroll.to.x, self.scroll.to.y = 0, 0
  self.init_size = true
  core.redraw = true
end


---Check requested visibility; an owner may override this to follow its own visibility.
---@return boolean visible Whether the toolbar should occupy layout space and receive input
function ToolbarView:is_visible()
  return self.visible
end


---Animate effective visibility, clamp scrolling, and refresh hover after layout changes.
---Keeps the toolbar thickness on the axis perpendicular to its icon layout.
function ToolbarView:update()
  local icon_w, icon_h = self:get_icon_size()
  local vertical = self.orientation == "vertical"
  local axis = vertical and "x" or "y"
  local thickness = vertical and icon_w + style.padding.x * 2
    or icon_h + style.padding.y * 2
  local dest_size = self:is_visible() and common.round(thickness) or 0
  if self.init_size then
    self.size[axis] = dest_size
    self.init_size = nil
  else
    self:move_towards(self.size, axis, dest_size)
  end

  local sx, sy = self.scroll.x, self.scroll.y
  self:clamp_scroll_position()
  ToolbarView.super.update(self)
  local layout = self.last_layout or {}
  if not self:is_visible() then
    self:on_mouse_left()
  elseif
    core.root_view.overlapping_view == self and (
      sx ~= self.scroll.x or sy ~= self.scroll.y
      or layout.x ~= self.position.x or layout.y ~= self.position.y
      or layout.w ~= self.size.x or layout.h ~= self.size.y
      or layout.icon_w ~= icon_w or layout.icon_h ~= icon_h
    )
  then
    self:on_mouse_moved(core.root_view.mouse.x, core.root_view.mouse.y, 0, 0)
  end
  layout.x, layout.y = self.position.x, self.position.y
  layout.w, layout.h = self.size.x, self.size.y
  layout.icon_w, layout.icon_h = icon_w, icon_h
  self.last_layout = layout
end


---Toggle requested visibility and clear any icon hover or tooltip.
function ToolbarView:toggle_visible()
  self.visible = not self.visible
  self:on_mouse_left()
end

---Measure the largest icon using each command's font or the toolbar's default font.
---@return number width Maximum icon width
---@return number height Maximum icon height
function ToolbarView:get_icon_size()
  local width, height = 0, 0
  for _, item in ipairs(self.toolbar_commands) do
    local font = item.font or self.toolbar_font
    width = math.max(width, font:get_width(item.symbol))
    height = math.max(height, font:get_height())
  end
  return width, height
end


---Get the largest icon width used by the toolbar layout.
---@return number width Maximum icon width
function ToolbarView:get_icon_width()
  local width = self:get_icon_size()
  return width
end

---Iterate icons intersecting the viewport in the current orientation.
---@return fun():table, number, number, number, number iterator Yields command entry, x, y, width, height
function ToolbarView:each_item()
  local icon_w, icon_h = self:get_icon_size()
  local vertical = self.orientation == "vertical"
  local step = vertical and icon_h * 1.5 or icon_w * 1.5
  local ox, oy = self:get_content_offset()
  local index = 0
  return function()
    while index < #self.toolbar_commands do
      index = index + 1
      local x = ox + style.padding.x + (vertical and 0 or step * (index - 1))
      local y = oy + style.padding.y + (vertical and step * (index - 1) or 0)
      if
        x >= self.position.x + self.size.x
        or y >= self.position.y + self.size.y
      then
        return
      end
      if x + icon_w > self.position.x and y + icon_h > self.position.y then
        return self.toolbar_commands[index], x, y, icon_w, icon_h
      end
    end
  end
end


---Get the width of one vertical icon column or the complete horizontal toolbar.
---Used to fit a tree pane that is still at its default width.
---@return number width Width including horizontal padding
function ToolbarView:get_min_width()
  local icon_w = self:get_icon_width()
  local count = self.orientation == "vertical" and 1 or #self.toolbar_commands
  return 2 * style.padding.x + icon_w * math.max(0, 1.5 * count - 0.5)
end


---Get the full icon column height for vertical mode or one row's height otherwise.
---@return number height Icon extent including vertical padding
function ToolbarView:get_scrollable_size()
  local _, icon_h = self:get_icon_size()
  local count = self.orientation == "vertical" and #self.toolbar_commands or 1
  return 2 * style.padding.y + icon_h * math.max(0, 1.5 * count - 0.5)
end


---Get the full horizontal icon extent, including padding.
---@return number width Width required to show the toolbar without horizontal scrolling
function ToolbarView:get_h_scrollable_size()
  return self:get_min_width()
end


---Clamp current and target scrolling on the active orientation's axis.
---Resets the other axis so orientation changes cannot retain an obsolete scroll offset.
function ToolbarView:clamp_scroll_position()
  local axis = self.orientation == "vertical" and "y" or "x"
  local extent = axis == "y"
    and self:get_scrollable_size()
    or self:get_h_scrollable_size()
  local maximum = math.max(0, extent - self.size[axis])
  self.scroll[axis] = common.clamp(self.scroll[axis], 0, maximum)
  self.scroll.to[axis] = common.clamp(self.scroll.to[axis], 0, maximum)
  local other = axis == "y" and "x" or "y"
  self.scroll[other], self.scroll.to[other] = 0, 0
end


---Scroll icons vertically or horizontally according to the toolbar orientation.
---Leaves Ctrl, Cmd, and Alt wheel input available for command bindings.
---@param y number Vertical wheel delta, used for either orientation
---@param x? number Horizontal wheel delta, preferred in horizontal mode when nonzero
---@return boolean consumed Whether toolbar scrolling handled the wheel event
function ToolbarView:on_mouse_wheel(y, x)
  if not self:is_visible() then return false end
  if keymap.modkeys.ctrl or keymap.modkeys.cmd or keymap.modkeys.alt then
    return false
  end
  local axis = self.orientation == "vertical" and "y" or "x"
  local delta = axis == "x" and x and x ~= 0 and x or y or 0
  self.scroll.to[axis] = self.scroll.to[axis] - delta * config.mouse_wheel_scroll
  self:clamp_scroll_position()
  core.redraw = true
  return true
end


---Draw effectively visible command icons using the current orientation and scroll offset.
function ToolbarView:draw()
  if not self:is_visible() then return end
  self:draw_background(style.background2)

  for item, x, y, w, h in self:each_item() do
    local color = item == self.hovered_item
      and command.is_valid(item.command)
      and style.text
      or style.dim
    common.draw_text(
      item.font or self.toolbar_font,
      color,
      item.symbol,
      "center",
      x, y, w, h
    )
  end
end


---Refresh icon hit testing and perform its command in the previous editor focus.
---@param button core.view.mousebutton Pressed button
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param clicks integer Consecutive click count
---@return boolean? consumed True when the visible toolbar handles the press
function ToolbarView:on_mouse_pressed(button, x, y, clicks)
  if not self:is_visible() then return end
  local caught = ToolbarView.super.on_mouse_pressed(self, button, x, y, clicks)
  if caught then return caught end
  core.set_active_view(core.last_active_view)
  self:on_mouse_moved(x, y, 0, 0)
  if self.hovered_item and command.is_valid(self.hovered_item.command) then
    command.perform(self.hovered_item.command)
  end
  return true
end


---Clear icon hover, remove its status tooltip, and reset inherited scrollbar hover.
function ToolbarView:on_mouse_left()
  ToolbarView.super.on_mouse_left(self)
  if self.tooltip then
    core.status_view:remove_tooltip()
    self.tooltip = false
  end
  self.hovered_item = nil
end


---Hit-test scrolled icons and show the hovered command's label and current binding.
---@param px number Screen x coordinate
---@param py number Screen y coordinate
---@param ... number Pointer movement deltas
function ToolbarView:on_mouse_moved(px, py, ...)
  if not self:is_visible() then return end
  ToolbarView.super.on_mouse_moved(self, px, py, ...)
  local hovered
  if self:hit_test(px, py) then
    for item, x, y, w, h in self:each_item() do
      if px > x and py > y and px <= x + w and py <= y + h then
        hovered = item
        break
      end
    end
  end
  if hovered == self.hovered_item then return end
  self:on_mouse_left()
  self.hovered_item = hovered
  if hovered then
    local binding = keymap.get_binding(hovered.command)
    local name = command.prettify_name(hovered.command)
    core.status_view:show_tooltip(
      binding and { name, style.dim, "  ", binding } or { name }
    )
    self.tooltip = true
  end
end

-- The toolbarview pane is not plugged here but it is added in the
-- treeview plugin.

return ToolbarView
