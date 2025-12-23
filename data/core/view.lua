local core = require "core"
local config = require "core.config"
local common = require "core.common"
local Object = require "core.object"
local Scrollbar = require "core.scrollbar"

---@class core.view.position
---@field x number
---@field y number

---@class core.view.scroll
---@field x number
---@field y number
---@field to core.view.position

---@class core.view.thumbtrack
---@field thumb number
---@field track number

---@class core.view.thumbtrackwidth
---@field thumb number
---@field track number
---@field to core.view.thumbtrack

---@class core.view.scrollbar
---@field x core.view.thumbtrack
---@field y core.view.thumbtrack
---@field w core.view.thumbtrackwidth
---@field h core.view.thumbtrack

---@alias core.view.cursor "'arrow'" | "'ibeam'" | "'sizeh'" | "'sizev'" | "'hand'"

---@alias core.view.mousebutton "'left'" | "'right'"

---@alias core.view.context "'application'" | "'session'"

---Base view.
---@class core.view : core.object
---@field context core.view.context
---@field super core.object
---@field position core.view.position
---@field size core.view.position
---@field scroll core.view.scroll
---@field cursor core.view.cursor
---@field scrollable boolean
---@field v_scrollbar core.scrollbar
---@field h_scrollbar core.scrollbar
---@field current_scale number
local View = Object:extend()

function View:__tostring() return "View" end

-- context can be "application" or "session". The instance of objects
-- with context "session" will be closed when a project session is
-- terminated. The context "application" is for functional UI elements.
View.context = "application"

--- Constructor - initializes a new view instance.
--- Override this in subclasses and always call super constructor first:
--- `MyView.super.new(self)`
function View:new()
  self.position = { x = 0, y = 0 }
  self.size = { x = 0, y = 0 }
  self.scroll = { x = 0, y = 0, to = { x = 0, y = 0 } }
  self.cursor = "arrow"
  self.scrollable = false
  self.v_scrollbar = Scrollbar({direction = "v", alignment = "e"})
  self.h_scrollbar = Scrollbar({direction = "h", alignment = "e"})
  self.current_scale = SCALE
end

--- Smoothly animate a value towards a destination.
--- Use this for animations instead of direct assignment.
--- @param t table Table containing the value (or pass value directly as first arg)
--- @param k string|number Key in table, or destination if t is a number
--- @param dest number Target value
--- @param rate? number Animation speed (0-1, default 0.5, higher = faster)
--- @param name? string Transition name (for config.disabled_transitions)
--- Example: `self:move_towards(self.scroll, "y", 100, 0.3, "scroll")`
function View:move_towards(t, k, dest, rate, name)
  if type(t) ~= "table" then
    return self:move_towards(self, t, k, dest, rate, name)
  end
  local val = t[k]
  -- we use epsilon comparison in case dest is inconsistent
  if math.abs(dest - val) < 1e-8 then return end
  if
    not config.transitions
    or math.abs(val - dest) < 0.5
    or config.disabled_transitions[name]
  then
    t[k] = dest
  else
    rate = rate or 0.5
    if core.fps ~= 60 or config.animation_rate ~= 1 then
      local dt = 60 / core.fps
      rate = 1 - common.clamp(1 - rate, 1e-8, 1 - 1e-8)^(config.animation_rate * dt)
    end
    t[k] = common.lerp(val, dest, rate)
  end
  core.redraw = true
end


--- Called when view is requested to close (e.g., tab close button).
--- Override to show confirmation dialogs for unsaved changes.
--- @param do_close function Call this function to actually close the view
--- Example: `core.command_view:enter("Save?", {submit = do_close})`
function View:try_close(do_close)
  do_close()
end


--- Get the name displayed in the view's tab.
--- Override to show document name, file path, etc.
---@return string
function View:get_name()
  return "---"
end


--- Get the total scrollable height of the view's content.
--- Used by scrollbar to calculate thumb size and position.
---@return number Height in pixels (default: infinite)
function View:get_scrollable_size()
  return math.huge
end

--- Get the total scrollable width of the view's content.
--- Used by horizontal scrollbar.
---@return number Width in pixels (default: 0, no horizontal scroll)
function View:get_h_scrollable_size()
  return 0
end


--- Whether this view accepts text input (enables IME).
--- Override and return true for text editors and input fields.
function View:supports_text_input()
  return false
end

--- Check if a screen point overlaps either scrollbar.
--- Useful for determining cursor style or handling clicks.
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@return boolean True if point is over vertical or horizontal scrollbar
function View:scrollbar_overlaps_point(x, y)
  return not (not (self.v_scrollbar:overlaps(x, y) or self.h_scrollbar:overlaps(x, y)))
end


--- Check if user is currently dragging either scrollbar.
---@return boolean True if scrollbar drag is in progress
function View:scrollbar_dragging()
  return self.v_scrollbar.dragging or self.h_scrollbar.dragging
end


--- Check if mouse is hovering over either scrollbar track.
---@return boolean True if mouse is over scrollbar
function View:scrollbar_hovering()
  return self.v_scrollbar.hovering.track or self.h_scrollbar.hovering.track
end


--- Handle mouse button press events.
--- Override to handle clicks. Return true to consume event and prevent propagation.
--- Base implementation handles scrollbar clicks.
---@param button core.view.mousebutton "left" or "right"
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param clicks integer Number of clicks (1=single, 2=double, 3=triple)
---@return boolean|nil True to consume event, false/nil to propagate
function View:on_mouse_pressed(button, x, y, clicks)
  if not self.scrollable then return end
  local result = self.v_scrollbar:on_mouse_pressed(button, x, y, clicks)
  if result then
    if result ~= true then
      self.scroll.to.y = result * (self:get_scrollable_size() - self.size.y)
    end
    return true
  end
  result = self.h_scrollbar:on_mouse_pressed(button, x, y, clicks)
  if result then
    if result ~= true then
      self.scroll.to.x = result * (self:get_h_scrollable_size() - self.size.x)
    end
    return true
  end
end


--- Handle mouse button release events.
--- Override to handle click completion. Base implementation handles scrollbar.
---@param button core.view.mousebutton
---@param x number Screen x coordinate
---@param y number Screen y coordinate
function View:on_mouse_released(button, x, y)
  if not self.scrollable then return end
  self.v_scrollbar:on_mouse_released(button, x, y)
  self.h_scrollbar:on_mouse_released(button, x, y)
end


--- Handle mouse movement events.
--- Override for hover effects, drag operations, etc.
--- Base implementation handles scrollbar dragging.
---@param x number Current screen x coordinate
---@param y number Current screen y coordinate
---@param dx number Delta x since last move
---@param dy number Delta y since last move
function View:on_mouse_moved(x, y, dx, dy)
  if not self.scrollable then return end
  local result
  if self.h_scrollbar.dragging then goto skip_v_scrollbar end
  result = self.v_scrollbar:on_mouse_moved(x, y, dx, dy)
  if result then
    if result ~= true then
      self.scroll.to.y = result * (self:get_scrollable_size() - self.size.y)
      if not config.animate_drag_scroll then
        self:clamp_scroll_position()
        self.scroll.y = self.scroll.to.y
      end
    end
    -- hide horizontal scrollbar
    self.h_scrollbar:on_mouse_left()
    return true
  end
  ::skip_v_scrollbar::
  result = self.h_scrollbar:on_mouse_moved(x, y, dx, dy)
  if result then
    if result ~= true then
      self.scroll.to.x = result * (self:get_h_scrollable_size() - self.size.x)
      if not config.animate_drag_scroll then
        self:clamp_scroll_position()
        self.scroll.x = self.scroll.to.x
      end
    end
    return true
  end
end


--- Called when mouse leaves the view's area.
--- Override to clear hover states. Base implementation notifies scrollbars.
function View:on_mouse_left()
  if not self.scrollable then return end
  self.v_scrollbar:on_mouse_left()
  self.h_scrollbar:on_mouse_left()
end


--- Handle file drop events (drag and drop from OS).
--- Override to handle dropped files. Return true to consume event.
---@param filename string Absolute path to dropped file
---@param x number Screen x where file was dropped
---@param y number Screen y where file was dropped
---@return boolean True to consume event, false to propagate
function View:on_file_dropped(filename, x, y)
  return false
end


--- Handle text input events (typing, IME composition).
--- Override for text editing. Called after IME composition completes.
---@param text string Input text (may be multiple characters)
function View:on_text_input(text)
  -- no-op
end


--- Handle IME (Input Method Editor) text composition events.
--- Override for IME support in text editors. Called during composition.
---@param text string Composition text being edited
---@param start number Start position of selection within composition
---@param length number Length of selection within composition
function View:on_ime_text_editing(text, start, length)
  -- no-op
end


--- Handle mouse wheel scroll events.
--- Override for custom scroll behavior. Base implementation does nothing.
---@param y number Vertical scroll delta; positive is "up"
---@param x number Horizontal scroll delta; positive is "left"
---@return boolean|nil True to capture event
function View:on_mouse_wheel(y, x)
  -- no-op
end

--- Called when DPI scale changes (display moved, zoom changed, etc.).
--- Override to adjust sizes, padding, or other scale-dependent values.
---@param new_scale number New scale factor (e.g., 1.0, 1.5, 2.0)
---@param prev_scale number Previous scale factor
function View:on_scale_change(new_scale, prev_scale) end

--- Get the content bounds in content coordinates (accounting for scroll).
--- @return number x1 Left edge
--- @return number y1 Top edge  
--- @return number x2 Right edge
--- @return number y2 Bottom edge
function View:get_content_bounds()
  local x = self.scroll.x
  local y = self.scroll.y
  return x, y, x + self.size.x, y + self.size.y
end

--- Handle touch move events (touchscreen/trackpad gestures).
--- Override for touch-specific behavior. Base implementation handles scrolling.
---@param x number Current touch x coordinate
---@param y number Current touch y coordinate
---@param dx number Delta x since last position
---@param dy number Delta y since last position
---@param i number Touch finger/pointer index
function View:on_touch_moved(x, y, dx, dy, i)
  if not self.scrollable then return end
  if self.dragging_scrollbar then
    local delta = self:get_scrollable_size() / self.size.y * dy
    self.scroll.to.y = self.scroll.to.y + delta
  end
  self.hovered_scrollbar = self:scrollbar_overlaps_point(x, y)

  self.scroll.to.y = self.scroll.to.y + -dy
  self.scroll.to.x = self.scroll.to.x + -dx
end


--- Get the top-left corner of content area in screen coordinates.
--- Accounts for scroll offset. Use for drawing content at correct position.
---@return number x Screen x coordinate
---@return number y Screen y coordinate
function View:get_content_offset()
  local x = common.round(self.position.x - self.scroll.x)
  local y = common.round(self.position.y - self.scroll.y)
  return x, y
end


--- Clamp scroll position to valid range (0 to max scrollable size).
--- Called automatically by update(). Override get_scrollable_size() to customize.
function View:clamp_scroll_position()
  local max = self:get_scrollable_size() - self.size.y
  self.scroll.to.y = common.clamp(self.scroll.to.y, 0, max)

  max = self:get_h_scrollable_size() - self.size.x
  self.scroll.to.x = common.clamp(self.scroll.to.x, 0, max)
end


--- Update scrollbar positions and sizes.
--- Called automatically by update(). Rarely needs to be called manually.
function View:update_scrollbar()
  local v_scrollable = self:get_scrollable_size()
  self.v_scrollbar:set_size(self.position.x, self.position.y, self.size.x, self.size.y, v_scrollable)
  local v_percent = self.scroll.y/(v_scrollable - self.size.y)
  -- Avoid setting nan percent
  self.v_scrollbar:set_percent(v_percent == v_percent and v_percent or 0)
  self.v_scrollbar:update()

  local h_scrollable = self:get_h_scrollable_size()
  self.h_scrollbar:set_size(self.position.x, self.position.y, self.size.x, self.size.y, h_scrollable)
  local h_percent = self.scroll.x/(h_scrollable - self.size.x)
  -- Avoid setting nan percent
  self.h_scrollbar:set_percent(h_percent == h_percent and h_percent or 0)
  self.h_scrollbar:update()
end


--- Called every frame to update view state.
--- Override to add custom update logic. Always call super.update(self) first.
--- Handles: scale changes, scroll animation, scrollbar updates.
function View:update()
  if self.current_scale ~= SCALE then
    self:on_scale_change(SCALE, self.current_scale)
    self.current_scale = SCALE
  end

  self:clamp_scroll_position()
  self:move_towards(self.scroll, "x", self.scroll.to.x, 0.2, "scroll")
  self:move_towards(self.scroll, "y", self.scroll.to.y, 0.2, "scroll")
  if not self.scrollable then return end
  self:update_scrollbar()
end


--- Draw a solid background color for the entire view.
--- Commonly called at the start of draw() methods.
---@param color renderer.color
function View:draw_background(color)
  local x, y = self.position.x, self.position.y
  local w, h = self.size.x, self.size.y
  renderer.draw_rect(x, y, w, h, color)
end


--- Draw the view's scrollbars.
--- Commonly called at the end of draw() methods.
function View:draw_scrollbar()
  self.v_scrollbar:draw()
  self.h_scrollbar:draw()
end


--- Called every frame to render the view.
--- Override to draw custom content. Typical pattern:
--- 1. Call self:draw_background(color)
--- 2. Draw your content
--- 3. Call self:draw_scrollbar()
function View:draw()
end

return View
