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

---@alias core.view.cursor "'arrow'" | "'ibeam'" | "'sizeh'" | "'sizev'" | "'sizenwse'" | "'sizenesw'" | "'hand'"

---@alias core.view.mousebutton "'left'" | "'right'"

---@alias core.view.context "'application'" | "'session'"

---Placement ownership and input policy for a floating view.
---@class core.view.floating_options
---@field owner? core.view|false Hides the popup with its owner; false clears ownership
---@field focus? "click"|"show"|"none" When to focus get_focus_target(); defaults to click
---@field interactive? boolean Receive pointer and keyboard events; defaults to true
---@field modal? boolean Restrict input and focus to this popup and its descendants
---@field dismiss_on_escape? boolean Request dismissal when Escape is unhandled
---@field dismiss_on_outside_click? boolean Request dismissal for clicks outside the popup
---@field dismiss_on_owner_click? boolean Treat clicks on the owner as outside the popup
---@field outside_click_event? "press"|"release" Dismissal phase; defaults to press
---@field consume_outside_click? boolean Consume dismissal clicks; defaults to true
---@field pass_through_unhandled? boolean Forward unhandled pointer events to docked views
---@field draggable? boolean Enable dragging within get_floating_drag_region()
---@field resizable? boolean Enable dragging the outer edges to resize
---@field min_size? core.view.position Minimum resize width (x) and height (y); defaults to 1
---@field anchor? core.view.floating_anchor|false Follow an anchor, or false to clear one

---Rectangle or view followed during floating placement.
---@class core.view.floating_anchor
---@field target core.view|core.view.floating_rectangle|fun():core.view.floating_rectangle? Anchor bounds or callback evaluated during placement
---@field side? "top"|"bottom"|"left"|"right" Preferred side; defaults to bottom, flips to fit
---@field align? "start"|"center"|"end" Alignment on the other axis; defaults to start
---@field gap? number Distance from the anchor in pixels; defaults to 0

---Outer popup or anchor bounds in screen coordinates.
---@class core.view.floating_rectangle
---@field x number
---@field y number
---@field w number
---@field h number

---Optional slide and completion callback passed to show_floating() or hide_floating().
---@class core.view.floating_transition
---@field from? "top"|"bottom"|"left"|"right" Opening slide's starting viewport edge
---@field to? "top"|"bottom"|"left"|"right" Closing slide's destination viewport edge
---@field rate? number Animation rate passed to move_towards(); greater than 0 and at most 1
---@field name? string disabled_transitions setting to honor; defaults to floating
---@field on_complete? fun(view: core.view) Called after showing or removing the popup

---Edges grabbed during a floating resize; absent fields mean the edge is inactive.
---@class core.view.floating_resize_edges
---@field left? boolean
---@field right? boolean
---@field top? boolean
---@field bottom? boolean

---Initial pointer and bounds retained during a floating drag or resize.
---@class core.view.floating_gesture
---@field x number Initial pointer x coordinate
---@field y number Initial pointer y coordinate
---@field bx number Initial outer x coordinate
---@field by number Initial outer y coordinate
---@field w number Initial outer width
---@field h number Initial outer height
---@field edges core.view.floating_resize_edges Grabbed resize edges
---@field resize? boolean Whether the gesture resizes instead of moving

---Base view.
---@class core.view : core.object
---@overload fun():core.view
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
---@field floating boolean Whether the view uses floating placement
---@field floating_options? core.view.floating_options Placement ownership and input policy
---@field floating_visible? boolean Whether the view is registered, including closing slides
---@field floating_closing? boolean Whether input is disabled while a closing slide runs
---@field floating_previous_focus? core.view Focus target to restore when hiding
---@field floating_transition? core.view.floating_transition Active slide and callback
---@field floating_destination? core.view.position Settled position retained during a slide
---@field floating_position? core.view.position Persistent interpolation state for a slide
---@field floating_gesture? core.view.floating_gesture Active pointer drag or resize
---@field capture_text_input? boolean Receive text input while floating without taking focus
local View = Object:extend()

function View:__tostring() return "View" end

-- context can be "application" or "session". The instance of objects
-- with context "session" will be closed when a project session is
-- terminated. The context "application" is for functional UI elements.
View.context = "application"
View.floating = false

---Constructor - initializes a new view instance.
---Override this in subclasses and always call super constructor first:
---`MyView.super.new(self)`
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


---Serialize this view into a persistable state table.
---
---This method is called when the editor is saving workspace/session state.
---The returned table must contain only plain Lua data (no functions,
---userdata, metatables, or cyclic references).
---
---Returning `nil` indicates that this view should NOT be restored when
---reloading the workspace.
---
---@return table? state
function View:get_state()
  return nil
end


---Create and initialize a new view instance from a previously saved state.
---
---This function is called when restoring workspace/session state.
---Implementations are responsible for:
---  * creating the view instance
---  * applying any persisted state
---
---If loading the instance failed nil will be returned.
---
---@param state table
---@return core.view? view
function View.from_state(state)
  return nil
end


---Returns the module path of this view.
---
---This method resolves the Lua module name that loaded the concrete view
---class (for example `"core.view"`).
---
---If the view class cannot be associated with any loaded module, `nil`
---is returned.
---
---@return string? path
function View:get_module()
  local cls = getmetatable(self)

  -- cache module name on the class, not the instance
  if not cls._module_name then
    for name, mod in pairs(package.loaded) do
      if mod == cls then
        cls._module_name = name
        break
      end
    end
  end

  return cls._module_name
end


local function move_constant(val, dest, duration, start_value, acceleration)
  local distance = math.abs(dest - start_value)
  local speed = distance / (core.fps * duration) -- px per second
  speed = acceleration * speed
  if val < dest then
    val = math.min(val + speed, dest)
  elseif val > dest then
    val = math.max(val - speed, dest)
  end
  return val
end

---Estimate conversion from lerp rate to duration in seconds.
local function lerp_duration(rate)
  if rate < 0.1 or rate > 1 then return rate end --already in seconds?
  local threshold = 0.01 -- 99% from destination
  local frames = math.log(threshold) / math.log(1 - rate)
  return frames / config.fps
end

---Smoothly animate a value towards a destination.
---Use this for animations instead of direct assignment.
---@param t table Table containing the value
---@param k string|number Key in table
---@param dest number Target value
---@param rate? number Animation speed (0-1, default 0.5, higher = faster)
---@param name? string Transition name (for config.disabled_transitions)
---@overload fun(self: core.view, k: string|number, dest: number, rate?: number, name?: string)
---Example: `self:move_towards(self.scroll, "y", 100, 0.3, "scroll")` or `self:move_towards("gutter_width", 100)`
function View:move_towards(t, k, dest, rate, name)
  if type(t) ~= "table" then
    return self:move_towards(self, t, k, dest, rate, name)
  end
  local val = t[k]
  -- we use epsilon comparison in case dest is inconsistent
  if math.abs(dest - val) < 1e-8 then return end
  if not config.transitions or config.disabled_transitions[name] or config.fps < 30 then
    t[k] = dest
  else
    local constant_scroll = name == "scroll"
      and self.doc
      and config.scroll_animation_type == "constant"
    local constant_general = name ~= "scroll"
      and config.animation_type == "constant"
    -- Timed Constant Velocity with Acceleration
    if constant_scroll or constant_general then
      local mk = "move_data_"..k
      if not t[mk] or t[mk][2] ~= (dest > val and "f" or "b") then
        t[mk] = {
          val,                                 -- starting position
          dest > val and "f" or "b",           -- direction
          dest,                                -- final destination
          1,                                   -- acceleration
          rate and lerp_duration(rate) or 0.15 -- rate
        }
      elseif math.abs(t[mk][3] - dest) >= 1 then
        t[mk][1] = val
        t[mk][3] = dest
        t[mk][4] = math.min(t[mk][4] + 0.5, 4)  -- increase acceleration
      else
        t[mk][4] = math.max(t[mk][4] - 0.125, 1) -- decrease acceleration
      end
      rate = constant_scroll and 0.5 or t[mk][5]
      if config.animation_rate ~= 1 then
        rate = common.clamp(rate, 1e-8, 1 - 1e-8) ^ config.animation_rate
      end
      val = move_constant(val, dest, rate, t[mk][1], t[mk][4])
      t[k] = val
      if math.abs(dest - val) < 1e-8 then t[mk] = nil end
    -- Classic Linear Interpolation
    else
      rate = rate or 0.2
      if core.fps ~= 60 or config.animation_rate ~= 1 then
        local dt = 60 / core.fps
        rate = 1 - common.clamp(1 - rate, 1e-8, 1 - 1e-8)^(config.animation_rate * dt)
      end
      val = common.lerp(val, dest, rate)
      t[k] = math.abs(val - dest) < 0.5 and dest or val
    end
  end
  core.redraw = true
end


---Called when view is requested to close (e.g., tab close button).
---Override to show confirmation dialogs for unsaved changes.
---Example: `core.command_view:enter("Save?", {submit = do_close})`
---@param do_close function Call this function to actually close the view
function View:try_close(do_close)
  do_close()
end


---Get the name displayed in the view's tab.
---Override to show document name, file path, etc.
---@return string name
function View:get_name()
  return "---"
end


---Get the total scrollable height of the view's content.
---Used by scrollbar to calculate thumb size and position.
---@return number height Height in pixels (default: infinite)
function View:get_scrollable_size()
  return math.huge
end

---Get the total scrollable width of the view's content.
---Used by horizontal scrollbar.
---@return number width Width in pixels (default: 0, no horizontal scroll)
function View:get_h_scrollable_size()
  return 0
end


---Whether this view accepts text input (enables IME).
---Override and return true for text editors and input fields.
function View:supports_text_input()
  return false
end

---Check if a screen point overlaps either scrollbar.
---Useful for determining cursor style or handling clicks.
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@return boolean overlaps True if point is over vertical or horizontal scrollbar
function View:scrollbar_overlaps_point(x, y)
  return not (not (self.v_scrollbar:overlaps(x, y) or self.h_scrollbar:overlaps(x, y)))
end


---Check if user is currently dragging either scrollbar.
---@return boolean dragging True if scrollbar drag is in progress
function View:scrollbar_dragging()
  return self.v_scrollbar.dragging or self.h_scrollbar.dragging
end


---Check if mouse is hovering over either scrollbar track.
---@return boolean hovering True if mouse is over scrollbar
function View:scrollbar_hovering()
  return self.v_scrollbar.hovering.track or self.h_scrollbar.hovering.track
end

---Check a user-supplied coordinate, size, or animation rate for a finite number.
---@param value any Value to check
---@return boolean finite Whether arithmetic on the value is safe
local function finite_number(value)
  return type(value) == "number"
    and value == value
    and math.abs(value) < math.huge
end

---Validate a position/size table or anchor rectangle before changing popup state.
---@param value table Coordinates supplied by a plugin
---@param fields string[] Required numeric fields
---@param label string Field path used in validation errors
local function validate_coordinates(value, fields, label)
  assert(type(value) == "table", label .. " must be a table")
  for _, field in ipairs(fields) do
    assert(
      finite_number(value[field]),
      label .. "." .. field .. " must be a finite number"
    )
  end
end

---Reject mistyped placement options before merging them into a view.
---@param options? core.view.floating_options User-supplied options
local function validate_floating_options(options)
  if options == nil then return end
  assert(type(options) == "table", "set_floating: options must be a table")
  local booleans = {
    interactive = true, modal = true, dismiss_on_escape = true,
    dismiss_on_outside_click = true, dismiss_on_owner_click = true,
    consume_outside_click = true, pass_through_unhandled = true,
    draggable = true, resizable = true
  }
  for key, value in pairs(options) do
    local label = "set_floating: " .. tostring(key)
    if booleans[key] then
      assert(type(value) == "boolean", label .. " must be a boolean")
    elseif key == "focus" then
      assert(
        value == "click" or value == "show" or value == "none",
        label .. " must be click, show or none"
      )
    elseif key == "outside_click_event" then
      assert(
        value == "press" or value == "release",
        label .. " must be press or release"
      )
    elseif key == "owner" then
      assert(
        value == false or type(value) == "table"
          and type(value.extends) == "function"
          and value:extends(View),
        label .. " must be a View or false"
      )
    elseif key == "min_size" then
      validate_coordinates(value, { "x", "y" }, label)
      assert(
        value.x > 0 and value.y > 0,
        label .. " dimensions must be positive"
      )
    elseif key == "anchor" and value ~= false then
      assert(
        type(value) == "table",
        label .. " must be an anchor table or false"
      )
      local target = value.target
      if
        type(target) ~= "function"
        and not (type(target) == "table"
        and type(target.extends) == "function"
        and target:extends(View))
      then
        validate_coordinates(target, { "x", "y", "w", "h" }, label .. ".target")
        assert(
          target.w >= 0 and target.h >= 0,
          label .. ".target dimensions must be nonnegative"
        )
      end
      assert(
        value.side == nil or value.side == "top"
          or value.side == "bottom"
          or value.side == "left" or value.side == "right",
        label .. ".side must be top, bottom, left or right"
      )
      assert(
        value.align == nil or value.align == "start"
          or value.align == "center"
          or value.align == "end",
        label .. ".align must be start, center or end"
      )
      assert(
        value.gap == nil or finite_number(value.gap),
        label .. ".gap must be a finite number"
      )
    else
      assert(
        key == "anchor" and value == false,
        "Unknown set_floating option: " .. tostring(key)
      )
    end
  end
end

---Validate a show/hide transition before registration, focus, or capture changes.
---@param options? core.view.floating_transition User-supplied transition
---@param method string Method name used in errors
---@param edge_key "from"|"to" Edge option accepted by this method
local function validate_floating_transition(options, method, edge_key)
  if options == nil then return end
  assert(type(options) == "table", method .. ": options must be a table")
  for key, value in pairs(options) do
    local label = method .. ": " .. tostring(key)
    if key == edge_key then
      assert(
        value == "top" or value == "bottom" or value == "left" or value == "right",
        label .. " must be top, bottom, left or right"
      )
    elseif key == "rate" then
      assert(
        finite_number(value) and value > 0 and value <= 1,
        label .. " must be greater than 0 and at most 1"
      )
    elseif key == "name" then
      assert(type(value) == "string", label .. " must be a string")
    elseif key == "on_complete" then
      assert(type(value) == "function", label .. " must be a function")
    else
      error(
        "Unknown " .. method .. " option: " .. tostring(key)
          .. "; configure placement with set_floating", 3
      )
    end
  end
end


---Enable or disable floating placement and configure popup input and ownership.
---Call show_floating() to show the view after enabling this mode.
---Detach it from its node or parent container before showing. Disabling hides it.
---@param enabled boolean Whether the view should use floating placement
---@param options? core.view.floating_options Options merged with existing ones when enabling
---@return core.view view This view, for chaining
function View:set_floating(enabled, options)
  assert(type(enabled) == "boolean", "set_floating: enabled must be a boolean")
  if not enabled then
    self:hide_floating()
    self.floating = false
    return self
  end
  validate_floating_options(options)
  self.floating = true
  self.floating_options = self.floating_options or {
    focus = "click",
    interactive = true,
    consume_outside_click = true,
    outside_click_event = "press",
    min_size = { x = 1, y = 1 }
  }
  for k, v in pairs(options or {}) do
    self.floating_options[k] = v
  end
  return self
end


---Get the popup's outer rectangle in screen coordinates, including borders.
---Override together with set_floating_bounds() for composite views.
---@return number x Screen x coordinate
---@return number y Screen y coordinate
---@return number w Outer width in pixels
---@return number h Outer height in pixels
function View:get_floating_bounds()
  return self.position.x, self.position.y, self.size.x, self.size.y
end


---Set the popup's outer rectangle when RootView places, drags, or resizes it.
---Override for composites that need to update child layout or account for borders.
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param w number Outer width in pixels
---@param h number Outer height in pixels
function View:set_floating_bounds(x, y, w, h)
  self.position.x, self.position.y = x, y
  self.size.x, self.size.y = w, h
end


---Check whether a screen point lies inside the view's outer rectangle.
---Override for custom shapes or composites with additional hit regions.
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@return boolean inside Whether the view contains the point
function View:hit_test(x, y)
  local bx, by, w, h = self:get_floating_bounds()
  return x >= bx and y >= by and x < bx + w and y < by + h
end


---Get the view that should receive focus when this view is shown or clicked.
---Override for composites whose keyboard focus belongs to a descendant.
---@return core.view? target View to focus, or nil to preserve the current focus
function View:get_focus_target()
  return self
end


---Check whether a view is this view or belongs to it through a container or owner.
---Follows parent, subparent, and floating owner links while guarding against cycles.
---@param view core.view? Candidate view
---@return boolean owned Whether the candidate belongs to this view
function View:owns_view(view)
  local seen = {}
  while view and not seen[view] do
    if view == self then return true end
    seen[view] = true
    view = view.parent or view.subparent
      or view.floating_options and view.floating_options.owner
  end
  return false
end


---Check whether floating popups owned by this view should remain visible.
---Docked owners must be active in their node; container children follow their parent.
---Override for composites with their own visibility rules.
---@return boolean? visible Falsy when the owner is hidden or its tab is inactive
function View:is_floating_owner_visible()
  if self.floating then
    return self.floating_visible
  end
  if self.visible == false then
    return false
  end
  local root = core.root_view
  local node = root and root.root_node:get_node_for_view(self)
  if node then
    return node.active_view == self
  end
  if self.parent then
    return self.parent:is_floating_owner_visible()
  end
  return true
end


---Called when showing a floating view or completing its removal.
---Override to synchronize widget visibility or clear popup controller state.
---@param visible boolean True on show, false when removal completes
function View:on_floating_visibility_changed(visible)
end


---Handle a dismissal requested by Escape, an outside click, or window focus loss.
---The default implementation hides the view immediately; override for custom handling.
---@param reason "escape"|"outside"|"focuslost" Event that requested dismissal
function View:on_floating_dismiss(reason)
  self:hide_floating()
end


---Handle a floating view's keyboard input before command dispatch.
---Override and return true to consume the normalized key binding.
---@param stroke string Normalized key binding, such as "ctrl+return"
---@param ... any Additional arguments forwarded by the keyboard handler
---@return boolean? consumed Whether the event was handled
function View:on_key_pressed(stroke, ...)
  return false
end


---Cancel pointer gestures when RootView releases mouse capture without a click.
---Clears floating dragging, text selection, scrollbar dragging, and hover state.
---Override to clear any additional subclass gesture state.
function View:on_mouse_capture_lost()
  self.floating_gesture = nil
  self.mouse_selecting = nil
  self.v_scrollbar:on_mouse_released("left", -math.huge, -math.huge)
  self.h_scrollbar:on_mouse_released("left", -math.huge, -math.huge)
  self:on_mouse_left()
end


---Raise a shown floating view and its owned popups above the other floating views.
---@return core.view view This view, for chaining
function View:bring_to_front()
  if self.floating_visible and core.root_view then
    core.root_view:add_floating_view(self)
  end
  return self
end


---Get a popup position just beyond the requested edge of the editor viewport.
---@param root core.rootview Editor viewport
---@param edge "left"|"right"|"top"|"bottom" Edge to slide from or to
---@param x number Current screen x coordinate
---@param y number Current screen y coordinate
---@param w number Outer popup width
---@param h number Outer popup height
---@return number x Slide endpoint x coordinate
---@return number y Slide endpoint y coordinate
local function slide_position(root, edge, x, y, w, h)
  if edge == "left" then
    x = root.position.x - w
  elseif edge == "right" then
    x = root.position.x + root.size.x
  elseif edge == "top" then
    y = root.position.y - h
  elseif edge == "bottom" then
    y = root.position.y + root.size.y
  else
    error("Invalid floating slide edge: " .. tostring(edge))
  end
  return x, y
end

---Show or raise the view in RootView's floating layer and apply its focus policy.
---Requires a view detached from its node and parent container.
---Reopening cancels a pending close and its completion callback.
---@param options? core.view.floating_transition Optional opening slide (from) and callback
---@return core.view view This view, for chaining
function View:show_floating(options)
  validate_floating_transition(options, "show_floating", "from")
  if not self.floating then
    self:set_floating(true)
  end
  local root = assert(core.root_view, "Floating views require RootView")
  assert(
    not root.root_node:get_node_for_view(self),
    "Detach the view from its node before enabling floating placement"
  )
  assert(
    not self.parent,
    "Detach the view from its parent before showing it as floating"
  )
  options = options or {}
  local reopening = self.floating_visible
  local destination = self.floating_destination
  self.floating_transition, self.floating_position = nil, nil
  self.floating_visible, self.floating_closing = true, false
  self:on_floating_visibility_changed(true)
  root:add_floating_view(self)
  if destination then
    local _, _, w, h = self:get_floating_bounds()
    self:set_floating_bounds(destination.x, destination.y, w, h)
  end
  root:place_floating_view(self)
  local sx, sy = self:get_floating_bounds()
  self.floating_destination = nil
  if options.from and not reopening then
    local x, y, w, h = self:get_floating_bounds()
    self.floating_destination = { x = x, y = y }
    x, y = slide_position(root, options.from, x, y, w, h)
    self:set_floating_bounds(x, y, w, h)
  end
  if options.from then
    self.floating_destination = { x = sx, y = sy }
    self.floating_transition = options
  elseif options.on_complete then
    core.try(options.on_complete, self)
  end
  if self.floating_options.modal then root:cancel_mouse_capture() end
  if self.floating_options.focus == "show" then
    local target = self:get_focus_target()
    if target then
      if target ~= core.active_view then
        self.floating_previous_focus = core.active_view
      end
      core.set_active_view(target)
    end
  end
  core.redraw = true
  return self
end


---Hide the floating view, close owned popups, cancel input, and restore focus.
---A closing slide delays removal while the view immediately stops receiving input.
---@param options? core.view.floating_transition Optional closing slide (to) and callback
---@return core.view view This view, for chaining
function View:hide_floating(options)
  validate_floating_transition(options, "hide_floating", "to")
  if not self.floating_visible then return self end
  options = options or {}
  local root = core.root_view
  if root then root:cancel_floating_input(self) end
  if options.to and not self.floating_closing then
    local x, y = self:get_floating_bounds()
    self.floating_destination = self.floating_destination or { x = x, y = y }
    self.floating_closing = true
    self.floating_transition = options
    self.floating_position = nil
  else
    if self.floating_destination then
      local _, _, w, h = self:get_floating_bounds()
      self:set_floating_bounds(
        self.floating_destination.x,
        self.floating_destination.y,
        w, h
      )
    end
    self.floating_visible = false
    self.floating_closing = false
    self.floating_transition = nil
    self.floating_destination = nil
    self.floating_position = nil
    if root then root:remove_floating_view(self) end
    self:on_floating_visibility_changed(false)
    if options.on_complete then
      core.try(options.on_complete, self)
    end
  end
  core.redraw = true
  return self
end


---Get the screen rectangle where a floating view can be dragged.
---Override to restrict dragging to a header; defaults to the full popup bounds.
---@return number? x Screen x coordinate, or nil to disable dragging
---@return number? y Screen y coordinate
---@return number? w Region width
---@return number? h Region height
function View:get_floating_drag_region()
  return self:get_floating_bounds()
end


---Update anchor placement or advance an opening or closing slide.
---RootView calls this before update() for each shown floating view.
---Completes removal and invokes the transition callback when a slide finishes.
function View:update_floating()
  local root = core.root_view
  local transition = self.floating_transition
  if not transition then root:place_floating_view(self); return end
  local x, y, w, h = self:get_floating_bounds()
  local tx, ty
  if self.floating_closing then
    tx, ty = slide_position(root, transition.to, x, y, w, h)
  else
    local dest = self.floating_destination or { x = x, y = y }
    tx, ty = root:clamp_floating_bounds(dest.x, dest.y, w, h)
  end
  local position = self.floating_position or { x = x, y = y }
  self.floating_position = position
  self:move_towards(
    position, "x", tx, transition.rate, transition.name or "floating"
  )
  self:move_towards(
    position, "y", ty, transition.rate, transition.name or "floating"
  )
  self:set_floating_bounds(position.x, position.y, w, h)
  if position.x == tx and position.y == ty then
    if self.floating_closing then
      self:hide_floating()
    else
      self.floating_transition = nil
      self.floating_destination = nil
      self.floating_position = nil
    end
    if transition.on_complete then
      core.try(transition.on_complete, self)
    end
  end
end


---Handle mouse button press events.
---Override to handle clicks. Return true to consume event and prevent propagation.
---Base implementation handles scrollbar clicks.
---@param button core.view.mousebutton
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param clicks integer Number of consecutive clicks (configurable with config.max_clicks)
---@return boolean? consumed True to consume event, false/nil to propagate
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


---Handle mouse button release events.
---Override to handle click completion. Base implementation handles scrollbar.
---@param button core.view.mousebutton
---@param x number Screen x coordinate
---@param y number Screen y coordinate
function View:on_mouse_released(button, x, y)
  if not self.scrollable then return end
  self.v_scrollbar:on_mouse_released(button, x, y)
  self.h_scrollbar:on_mouse_released(button, x, y)
end


---Handle mouse movement events.
---Override for hover effects, drag operations, etc.
---Base implementation handles scrollbar dragging.
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


---Called when mouse leaves the view's area.
---Override to clear hover states. Base implementation notifies scrollbars.
function View:on_mouse_left()
  if not self.scrollable then return end
  self.v_scrollbar:on_mouse_left()
  self.h_scrollbar:on_mouse_left()
end


---Handle file drop events (drag and drop from OS).
---Override to handle dropped files. Return true to consume event.
---@param filename string Absolute path to dropped file
---@param x number Screen x where file was dropped
---@param y number Screen y where file was dropped
---@return boolean consumed True to consume event, false to propagate
function View:on_file_dropped(filename, x, y)
  return false
end


---Handle text input events (typing, IME composition).
---Override for text editing. Called after IME composition completes.
---@param text string Input text (may be multiple characters)
function View:on_text_input(text)
  -- no-op
end


---Handle IME (Input Method Editor) text composition events.
---Override for IME support in text editors. Called during composition.
---@param text string Composition text being edited
---@param start number Start position of selection within composition
---@param length number Length of selection within composition
function View:on_ime_text_editing(text, start, length)
  -- no-op
end


---Handle mouse wheel scroll events.
---Override for custom scroll behavior. Base implementation does nothing.
---@param y number Vertical scroll delta; positive is "up"
---@param x number Horizontal scroll delta; positive is "left"
---@return boolean? consumed True to consume event
function View:on_mouse_wheel(y, x)
  -- no-op
end


---Called when DPI scale changes (display moved, zoom changed, etc.).
---Override to adjust sizes, padding, or other scale-dependent values.
---@param new_scale number New scale factor (e.g., 1.0, 1.5, 2.0)
---@param prev_scale number Previous scale factor
function View:on_scale_change(new_scale, prev_scale) end


---Get the content bounds in content coordinates (accounting for scroll).
---@return number x1 Left edge
---@return number y1 Top edge
---@return number x2 Right edge
---@return number y2 Bottom edge
function View:get_content_bounds()
  local x = self.scroll.x
  local y = self.scroll.y
  return x, y, x + self.size.x, y + self.size.y
end


---Handle touch move events (touchscreen/trackpad gestures).
---Override for touch-specific behavior. Base implementation handles scrolling.
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


---Get the top-left corner of content area in screen coordinates.
---Accounts for scroll offset. Use for drawing content at correct position.
---@return number x Screen x coordinate
---@return number y Screen y coordinate
function View:get_content_offset()
  local x = common.round(self.position.x - self.scroll.x)
  local y = common.round(self.position.y - self.scroll.y)
  return x, y
end


---Clamp scroll position to valid range (0 to max scrollable size).
---Called automatically by update(). Override get_scrollable_size() to customize.
function View:clamp_scroll_position()
  local max = self:get_scrollable_size() - self.size.y
  self.scroll.to.y = common.clamp(self.scroll.to.y, 0, max)

  max = self:get_h_scrollable_size() - self.size.x
  self.scroll.to.x = common.clamp(self.scroll.to.x, 0, max)
end


---Update scrollbar positions and sizes.
---Called automatically by update(). Rarely needs to be called manually.
function View:update_scrollbar()
  local v_scrollable = self:get_scrollable_size()
  self.v_scrollbar:set_size(
    self.position.x, self.position.y,
    self.size.x, self.size.y,
    v_scrollable
  )
  local v_percent = self.scroll.y/(v_scrollable - self.size.y)
  -- Avoid setting nan percent
  self.v_scrollbar:set_percent(v_percent == v_percent and v_percent or 0)
  self.v_scrollbar:update()

  local h_scrollable = self:get_h_scrollable_size()
  self.h_scrollbar:set_size(
    self.position.x, self.position.y,
    self.size.x, self.size.y,
    h_scrollable
  )
  local h_percent = self.scroll.x/(h_scrollable - self.size.x)
  -- Avoid setting nan percent
  self.h_scrollbar:set_percent(h_percent == h_percent and h_percent or 0)
  self.h_scrollbar:update()
end


---Called every frame to update view state.
---Override to add custom update logic. Always call super.update(self) first.
---Handles: scale changes, scroll animation, scrollbar updates.
function View:update()
  if self.current_scale ~= SCALE then
    self:on_scale_change(SCALE, self.current_scale)
    self.current_scale = SCALE
  end
  if
    not self.scrollable
    and self.scroll.x == self.scroll.to.x
    and self.scroll.y == self.scroll.to.y
  then
    return
  end
  self:clamp_scroll_position()
  if self.scroll.x ~= self.scroll.to.x then
    self:move_towards(self.scroll, "x", self.scroll.to.x, 0.2, "scroll")
  end
  if self.scroll.y ~= self.scroll.to.y then
    self:move_towards(self.scroll, "y", self.scroll.to.y, 0.2, "scroll")
  end
  self:update_scrollbar()
end


---Draw a solid background color for the entire view.
---Commonly called at the start of draw() methods.
---@param color renderer.color
function View:draw_background(color)
  local x, y = self.position.x, self.position.y
  local w, h = self.size.x, self.size.y
  renderer.draw_rect(x, y, w, h, color)
end


---Draw the view's scrollbars.
---Commonly called at the end of draw() methods.
function View:draw_scrollbar()
  self.v_scrollbar:draw()
  self.h_scrollbar:draw()
end


---Called every frame to render the view.
---Override to draw custom content. Typical pattern:
---1. Call self:draw_background(color)
---2. Draw your content
---3. Call self:draw_scrollbar()
function View:draw()
end

return View
