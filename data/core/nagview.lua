local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local View = require "core.view"
local style = require "core.style"

local BORDER_WIDTH = common.round(1 * SCALE)
local UNDERLINE_WIDTH = common.round(2 * SCALE)
local UNDERLINE_MARGIN = common.round(1 * SCALE)

local noop = function() end

---@class core.nagview.option
---@field text string Button text
---@field default_yes? boolean True if this is the default "yes" option

---@class core.nagview.queue_item
---@field title string Dialog title
---@field message string Dialog message text
---@field options core.nagview.option[] Available button options
---@field on_selected? fun(option: core.nagview.option) Callback when option selected

---Modal dialog view for confirmations and alerts.
---Displays a message with buttons, dims the background, and captures focus.
---Multiple dialogs queue automatically.
---@class core.nagview : core.view
---@overload fun():core.nagview
---@field super core.view
---@field size core.view.position View size
---@field show_height number Animated height for slide-in effect
---@field force_focus boolean Whether to force focus on this view
---@field queue core.nagview.queue_item[] Queued dialogs waiting to show
---@field target_height number Target height for current message
---@field overlay core.view Modal floating companion
---@field dim_alpha number Alpha for background dimming [0-1]
---@field visible boolean Whether dialog is currently visible
---@field title string? Current dialog title
---@field message string? Current dialog message
---@field options core.nagview.option[]? Current dialog options
---@field on_selected function? Current dialog selection callback
---@field hovered_item integer? Index of currently hovered button
---@field underline_progress number Animation progress for hover underline [0-1]
local NagView = View:extend()
local draw_nagview_message

function NagView:__tostring() return "NagView" end

---Constructor - initializes the modal dialog view.
function NagView:new()
  NagView.super.new(self)
  self.size.y = 0
  self.show_height = 0
  self.force_focus = false
  self.overlay = View()
  self.overlay:set_floating(true, {
    owner = self,
    modal = true,
    focus = "none"
  })
  ---Draw the dialog and background dimming above the node tree.
  self.overlay.draw = function() draw_nagview_message(self) end
  ---Get the editor viewport bounds for a companion that draws outside its owner.
  ---@return number x Viewport screen x coordinate
  ---@return number y Viewport screen y coordinate
  ---@return number w Viewport width
  ---@return number h Viewport height
  self.overlay.get_floating_bounds = function()
    local root = core.root_view
    return root.position.x, root.position.y, root.size.x, root.size.y
  end
  ---Ignore placement writes because the companion computes its bounds from its owner.
  self.overlay.set_floating_bounds = function() end
  ---Leave animation and dialog layout updates to the docked NagView owner.
  self.overlay.update = function() end
  ---Forward modal presses to the dialog buttons and message scrollbar.
  ---@param _ core.view Modal companion
  ---@param ... any Mouse button, screen coordinates, and click count
  ---@return boolean consumed Whether NagView handled the press
  self.overlay.on_mouse_pressed = function(_, ...)
    return self:on_mouse_pressed(...)
  end
  ---Forward modal motion to dialog hover and scrollbar dragging.
  ---@param _ core.view Modal companion
  ---@param ... number Screen coordinates and pointer movement deltas
  ---@return boolean? consumed Result of NagView's motion handler
  self.overlay.on_mouse_moved = function(_, ...)
    return self:on_mouse_moved(...)
  end
  ---Release the dialog owner's scrollbar gesture.
  ---@param _ core.view Modal companion
  ---@param ... any Mouse button and screen coordinates
  self.overlay.on_mouse_released = function(_, ...)
    return self:on_mouse_released(...)
  end
  ---Clear the dialog owner's hover and scrollbar state when modal hover ends.
  self.overlay.on_mouse_left = function()
    self:on_mouse_left()
  end
  ---Cancel the dialog owner's scrollbar capture without activating a button.
  self.overlay.on_mouse_capture_lost = function()
    self:on_mouse_capture_lost()
  end
  ---Scroll the dialog message through its owner's scroll state.
  ---@param _ core.view Modal companion
  ---@param y number Vertical wheel delta
  ---@return boolean consumed Always true
  self.overlay.on_mouse_wheel = function(_, y)
    self.scroll.to.y = self.scroll.to.y - y * config.mouse_wheel_scroll
    core.redraw = true
    return true
  end
  ---Forward modal touch scrolling to the dialog owner.
  ---@param _ core.view Modal companion
  ---@param ... number Screen coordinates, movement deltas, and touch index
  self.overlay.on_touch_moved = function(_, ...)
    return self:on_touch_moved(...)
  end
  self.queue = {}
  self.scrollable = true
  self.target_height = 0
  self.dim_alpha = 0
  self.underline_progress = 0
  self.visible = false
end


---Get the current dialog title.
---@return string? title Current title or nil if no dialog active
function NagView:get_title()
  return self.title
end


---Get line height for text rendering.
---Duplicated from DocView for independence.
---@return integer height Line height in pixels
function NagView:get_line_height()
  return math.floor(style.font:get_height() * config.line_height)
end


---Get vertical offset to center text within line height.
---Duplicated from DocView for independence.
---@return number offset Y offset in pixels
function NagView:get_line_text_y_offset()
  local lh = self:get_line_height()
  local th = style.font:get_height()
  return (lh - th) / 2
end


---Get button area height (excluding top/bottom view padding).
---Includes internal button padding and borders.
---@return number height Button height in pixels
function NagView:get_buttons_height()
  local lh = style.font:get_height()
  local bt_padding = lh / 2
  return lh + 2 * BORDER_WIDTH + 2 * bt_padding
end


---Get target height for the nagview content (including top/bottom padding).
---@return number height Total target height in pixels
function NagView:get_target_height()
  return self.target_height + 2 * style.padding.y
end


---Get scrollable size when message is taller than window.
---Adjusts view size and enables scrolling if needed.
---@return number height Scrollable height (0 if not scrollable)
function NagView:get_scrollable_size()
  local w, h = system.get_window_size(core.window)
  if self.visible and self:get_target_height() > h then
    self.size.y = h
    return self:get_target_height()
  end
  return 0
end


---Draw semi-transparent overlay to dim content behind the dialog.
function NagView:dim_window_content()
  local ox, oy = self:get_content_offset()
  oy = oy + self.show_height
  local w, h = core.root_view.size.x, core.root_view.size.y - oy
  local dim_color = { table.unpack(style.nagbar_dim) }
  dim_color[4] = style.nagbar_dim[4] * self.dim_alpha
  renderer.draw_rect(ox, oy, w, h, dim_color)
end


---Change which button is currently hovered.
---Resets underline animation when hover changes.
---@param i integer? Button index to hover (nil to clear)
function NagView:change_hovered(i)
  if i ~= self.hovered_item then
    self.hovered_item = i
    self.underline_progress = 0
    core.redraw = true
  end
end


---Iterate over dialog option buttons with their positions.
---Buttons are yielded right-to-left.
---@return fun():integer,core.nagview.option,number,number,number,number iterator Iterator yielding: index, option, x, y, width, height
function NagView:each_option()
  return coroutine.wrap(function()
    if not self.options then return end
    local opt, bw,bh,ox,oy
    bh = self:get_buttons_height()
    ox,oy = self:get_content_offset()
    ox = ox + self.size.x
    oy = oy + self.show_height - bh - style.padding.y

    for i = #self.options, 1, -1 do
      opt = self.options[i]
      bw = style.font:get_width(opt.text) + 2 * BORDER_WIDTH + style.padding.x

      ox = ox - bw - style.padding.x
      coroutine.yield(i, opt, ox, oy, bw, bh)
    end
  end)
end


---Handle mouse movement to update button hover states.
---@param mx number Screen x coordinate
---@param my number Screen y coordinate
function NagView:on_mouse_moved(mx, my, ...)
  if not self.visible then return end
  core.set_active_view(self)
  NagView.super.on_mouse_moved(self, mx, my, ...)
  for i, _, x,y,w,h in self:each_option() do
    if mx >= x and my >= y and mx < x + w and my < y + h then
      self:change_hovered(i)
      break
    end
  end
end


---Handle modal presses on dialog buttons or the message scrollbar.
---Consumes clicks elsewhere in the modal layer while the dialog is visible.
---@param button core.view.mousebutton Pressed button
---@param mx number Screen x coordinate
---@param my number Screen y coordinate
---@param clicks integer Consecutive click count
---@return boolean consumed Whether the visible dialog handled the press
function NagView:on_mouse_pressed(button, mx, my, clicks)
  if not self.visible then return false end
  if NagView.super.on_mouse_pressed(self, button, mx, my, clicks) then
    return true
  end
  for i, _, x, y, w, h in self:each_option() do
    if mx >= x and my >= y and mx < x + w and my < y + h then
      self:change_hovered(i)
      command.perform "dialog:select"
      break
    end
  end
  return true
end

---Handle the dialog's Y/N shortcuts without editing the underlying document.
---@param text string Typed text
---@return boolean? consumed True while the dialog is visible
function NagView:on_text_input(text)
  if not self.visible then return end
  if text:lower() == "y" then
    command.perform "dialog:select-yes"
  elseif text:lower() == "n" then
    command.perform "dialog:select-no"
  end
  return true
end

---Handles animations for show/hide, dimming, and button hover underline.
function NagView:update()
  if not self.visible and self.show_height <= 0 then return end
  NagView.super.update(self)

  if self.visible and core.active_view == self and self.title then
    if self.size.y == 0 then self.size.y = 0.001 end
    local target_height = self:get_target_height()
    self:move_towards(self, "show_height", target_height, nil, "nagbar")
    self:move_towards(self, "underline_progress", 1, nil, "nagbar")
    self:move_towards(self, "dim_alpha", self.show_height / target_height, nil, "nagbar")
  else
    self:move_towards(self, "show_height", 0, nil, "nagbar")
    self:move_towards(self, "dim_alpha", 0, nil, "nagbar")
    if self.show_height <= 0 then
      self.size.y = 0
      self.overlay:hide_floating()
      self.title = nil
      self.message = nil
      self.options = nil
      self.on_selected = nil
    end
  end
end


---Draw the nagview message, buttons, and background dimming.
---Internal rendering function called by the floating overlay.
---@param self core.nagview
draw_nagview_message = function(self)
  if (not self.visible and self.show_height <= 0) or not self.title then
    return
  end
  self:dim_window_content()

  -- draw message's background
  local ox, oy = self:get_content_offset()
  renderer.draw_rect(ox, oy, self.size.x, self.show_height, style.nagbar)

  ox = ox + style.padding.x

  core.push_clip_rect(ox, oy, self.size.x, self.show_height)

  -- if there are other items, show it
  if #self.queue > 0 then
    local str = string.format("[%d]", #self.queue)
    ox = common.draw_text(
      style.font, style.nagbar_text,
      str, "left",
      ox, oy, self.size.x, self.show_height
    )
    ox = ox + style.padding.x
  end

  -- draw message
  local lh = style.font:get_height() * config.line_height
  oy = oy + style.padding.y + (self.target_height - self:get_message_height()) / 2
  for msg_line in self.message:gmatch("(.-)\n") do
    local ty = oy + self:get_line_text_y_offset()
    renderer.draw_text(style.font, msg_line, ox, ty, style.nagbar_text)
    oy = oy + lh
  end

  -- draw buttons
  for i, opt, bx,by,bw,bh in self:each_option() do
    local fw,fh = bw - 2 * BORDER_WIDTH, bh - 2 * BORDER_WIDTH
    local fx,fy = bx + BORDER_WIDTH, by + BORDER_WIDTH

    -- draw the button
    renderer.draw_rect(bx,by,bw,bh, style.nagbar_text)
    renderer.draw_rect(fx,fy,fw,fh, style.nagbar)

    if i == self.hovered_item then -- draw underline
      local uw = fw - 2 * UNDERLINE_MARGIN
      local halfuw = uw / 2
      local lx = fx + UNDERLINE_MARGIN + halfuw - (halfuw * self.underline_progress)
      local ly = fy + fh - UNDERLINE_MARGIN - UNDERLINE_WIDTH
      uw = uw * self.underline_progress
      renderer.draw_rect(lx,ly,uw,UNDERLINE_WIDTH, style.nagbar_text)
    end

    common.draw_text(
      style.font, style.nagbar_text, opt.text, "center", fx, fy, fw, fh
    )
  end

  self:draw_scrollbar()

  core.pop_clip_rect()
end


---Handle DPI scale changes.
---Updates border widths and recalculates target height.
---@param new_scale number New DPI scale
---@param old_scale number Previous DPI scale
function NagView:on_scale_change(new_scale, old_scale)
  BORDER_WIDTH = common.round(1 * new_scale)
  UNDERLINE_WIDTH = common.round(2 * new_scale)
  UNDERLINE_MARGIN = common.round(1 * new_scale)
  self.target_height = math.max(
    self:get_message_height(),
    self:get_buttons_height()
  )
end


---Calculate height needed to display the message text.
---@return number height Message height in pixels
function NagView:get_message_height()
  local h = 0
  for str in string.gmatch(self.message, "(.-)\n") do
    h = h + style.font:get_height() * config.line_height
  end
  return h
end


---Show the next dialog from the queue.
---Dequeues and displays the next waiting dialog, or hides if queue is empty.
function NagView:next()
  local opts = table.remove(self.queue, 1) or {}
  if opts.title and opts.message and opts.options then
    self.visible = true
    self.title = opts.title
    self.message = opts.message and opts.message .. "\n"
    self.options = opts.options
    self.on_selected = opts.on_selected

    local message_height = self:get_message_height()
    -- self.target_height is the nagview height needed to display the message and
    -- the buttons, excluding the top and bottom padding space.
    self.target_height = math.max(message_height, self:get_buttons_height())
    self:change_hovered(common.find_index(self.options, "default_yes"))

    self.force_focus = true
    self.overlay:show_floating()
    core.set_active_view(self)
  else
    self.force_focus = false
    self.overlay.floating_closing = true
    core.set_active_view(core.next_active_view or core.last_active_view)
    self.visible = false
  end
end


---Queue and optionally show a dialog.
---If no dialog is currently showing, displays immediately. Otherwise queues it.
---@param title string Dialog title
---@param message string Dialog message text
---@param options core.nagview.option[] Button options
---@param on_select? fun(option: core.nagview.option) Callback when button is clicked
function NagView:show(title, message, options, on_select)
  local opts = {}
  opts.title = assert(title, "No title")
  opts.message = assert(message, "No message")
  opts.options = assert(options, "No options")
  opts.on_selected = on_select or noop
  table.insert(self.queue, opts)
  if not self.visible then self:next() end
end


return NagView
