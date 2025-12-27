local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local Doc = require "core.doc"
local DocView = require "core.docview"
local View = require "core.view"
local RootView = require "core.rootview"


---Single-line document that prevents newline insertion.
---Used internally by CommandView for single-line input.
---@class core.commandview.input : core.doc
---@overload fun():core.commandview.input
---@field super core.doc
local SingleLineDoc = Doc:extend()

function SingleLineDoc:__tostring() return "SingleLineDoc" end

---Insert text, stripping any newlines to maintain single-line constraint.
---@param line integer Line number
---@param col integer Column number
---@param text string Text to insert (newlines will be removed)
function SingleLineDoc:insert(line, col, text)
  SingleLineDoc.super.insert(self, line, col, text:gsub("\n", ""))
end


---Command palette and input prompt view.
---Provides autocomplete, suggestions, and command execution interface.
---@class core.commandview : core.docview
---@overload fun():core.commandview
---@field super core.docview
---@field suggestion_idx integer Currently selected suggestion index
---@field suggestions table[] List of suggestion items
---@field suggestions_height number Animated height of suggestions box
---@field suggestions_offset number Scroll offset for suggestions list
---@field suggestions_first integer First visible suggestion index
---@field suggestions_last integer Last visible suggestion index
---@field last_change_id integer Last document change ID (for detecting updates)
---@field last_text string Last input text (for typeahead)
---@field gutter_width number Width of label gutter
---@field gutter_text_brightness number Label brightness animation value
---@field selection_offset number Animated cursor position in suggestions
---@field state core.commandview.state Current command state
---@field font string Font name to use
---@field label string Label text displayed in gutter
---@field mouse_position table Mouse coordinates {x, y}
---@field save_suggestion string? Saved suggestion for cycling
local CommandView = DocView:extend()

function CommandView:__tostring() return "CommandView" end

CommandView.context = "application"

local noop = function() end


---Configuration state for a command prompt session.
---@class core.commandview.state
---@field submit fun(text: string, suggestion: table?) Callback when command is submitted
---@field suggest fun(text: string): table[]? Function returning suggestion list
---@field cancel fun(explicit: boolean) Callback when command is cancelled
---@field validate fun(text: string, suggestion: table?): boolean Validate before submission
---@field text string Initial text to display
---@field draw_text? fun(item: table, font: renderer.font, color: renderer.color, x: number, y: number, w: number, h: number) Custom suggestion renderer
---@field select_text boolean Whether to select initial text
---@field show_suggestions boolean Whether to show suggestions box
---@field typeahead boolean Whether to enable typeahead completion
---@field wrap boolean Whether suggestion cycling wraps around
local default_state = {
  submit = noop,
  suggest = noop,
  cancel = noop,
  validate = function() return true end,
  text = "",
  draw_text = nil,
  select_text = false,
  show_suggestions = true,
  typeahead = true,
  wrap = true,
}


---Constructor - initializes the command view.
function CommandView:new()
  CommandView.super.new(self, SingleLineDoc())
  self.suggestion_idx = 1
  self.suggestions = {}
  self.suggestions_height = 0
  self.suggestions_offset = 0
  self.suggestions_first = 1
  self.suggestions_last = 0
  self.last_change_id = 0
  self.last_text = ""
  self.gutter_width = 0
  self.gutter_text_brightness = 0
  self.selection_offset = 0
  self.state = default_state
  self.font = "font"
  self.size.y = 0
  self.label = ""
  self.mouse_position = {x = 0, y = 0}
end


---Hide suggestions box.
---@deprecated Use state.show_suggestions = false instead
function CommandView:set_hidden_suggestions()
  core.warn("Using deprecated function CommandView:set_hidden_suggestions")
  self.state.show_suggestions = false
end


---Get the view name for display.
---@return string name Returns generic View name
function CommandView:get_name()
  return View.get_name(self)
end


---Get screen position of line and column, vertically centered in view.
---@param line integer Line number (always 1 for single-line)
---@param col integer Column number
---@return number x Screen x coordinate
---@return number y Screen y coordinate (vertically centered)
function CommandView:get_line_screen_position(line, col)
  local x = CommandView.super.get_line_screen_position(self, 1, col)
  local _, y = self:get_content_offset()
  local lh = self:get_line_height()
  return x, y + (self.size.y - lh) / 2
end


---Check if this view accepts text input.
---@return boolean accepts Always returns true
function CommandView:supports_text_input()
  return true
end


---Get scrollable size (disabled for command view).
---@return integer size Always returns 0
function CommandView:get_scrollable_size()
  return 0
end


---Get horizontal scrollable size (disabled for command view).
---@return integer size Always returns 0
function CommandView:get_h_scrollable_size()
  return 0
end


---Scroll to make position visible (no-op for command view).
function CommandView:scroll_to_make_visible()
  -- no-op function to disable this functionality
end


---Get the current input text.
---@return string text The entire input text
function CommandView:get_text()
  return self.doc:get_text(1, 1, 1, math.huge)
end


---Set the input text and optionally select it.
---@param text string Text to set
---@param select boolean? If true, select all text
function CommandView:set_text(text, select)
  self.last_text = text
  self.doc:remove(1, 1, math.huge, math.huge)
  self.doc:text_input(text)
  if select then
    self.doc:set_selection(math.huge, math.huge, 1, 1)
  end
end


---Move suggestion selection by offset (for arrow keys/wheel).
---Handles wrapping, history cycling, and updates the input text.
---@param dir integer Direction to move (-1 for up/previous, 1 for down/next)
function CommandView:move_suggestion_idx(dir)
  local function overflow_suggestion_idx(n, count)
    if count == 0 then return 0 end
    if self.state.wrap then
      return (n - 1) % count + 1
    else
      return common.clamp(n, 1, count)
    end
  end

  if self.state.show_suggestions then
    local n = self.suggestion_idx + dir
    self.suggestion_idx = overflow_suggestion_idx(n, #self.suggestions)
    self:complete()
    self.last_change_id = self.doc:get_change_id()
  else
    local current_suggestion = #self.suggestions > 0 and self.suggestions[self.suggestion_idx].text
    local text = self:get_text()
    if text == current_suggestion then
      local n = self.suggestion_idx + dir
      if n == 0 and self.save_suggestion then
        self:set_text(self.save_suggestion)
      else
        self.suggestion_idx = overflow_suggestion_idx(n, #self.suggestions)
        self:complete()
      end
    else
      self.save_suggestion = text
      self:complete()
    end
    self.last_change_id = self.doc:get_change_id()
    self.state.suggest(self:get_text())
  end
end


---Complete input with currently selected suggestion.
---Sets the input text to the selected suggestion's text.
function CommandView:complete()
  if #self.suggestions > 0 and self.suggestions[self.suggestion_idx] then
    self:set_text(self.suggestions[self.suggestion_idx].text)
  end
end


---Submit the current command.
---Validates input, calls submit callback, and exits command view.
function CommandView:submit()
  local suggestion = self.suggestions[self.suggestion_idx]
  local text = self:get_text()
  if self.state.validate(text, suggestion) then
    local submit = self.state.submit
    self:exit(true)
    submit(text, suggestion)
  end
end


---Enter command mode with a prompt.
---Activates the command view with specified label and options.
---@param label string Label text to display (": " will be appended)
---@param options core.commandview.state Configuration options for this command session
---@overload fun(label: string, submit: function, suggest: function, cancel: function, validate: function)
function CommandView:enter(label, ...)
  if self.state ~= default_state then
    return
  end
  local options = select(1, ...)

  if type(options) ~= "table" then
    core.warn("Using CommandView:enter in a deprecated way")
    local submit, suggest, cancel, validate = ...
    options = {
      submit = submit,
      suggest = suggest,
      cancel = cancel,
      validate = validate,
    }
  end

  -- Support deprecated CommandView:set_hidden_suggestions
  -- Remove this when set_hidden_suggestions is not supported anymore
  if options.show_suggestions == nil then
    options.show_suggestions = self.state.show_suggestions
  end

  self.state = common.merge(default_state, options)

  -- Retrieve text added with CommandView:set_text
  -- and use it if options.text is not given
  local set_text = self:get_text()
  if options.text or options.select_text then
    local text = options.text or set_text
    self:set_text(text, self.state.select_text)
  end

  core.set_active_view(self)
  self:update_suggestions()
  self.gutter_text_brightness = 100
  self.label = label .. ": "
end


---Exit command mode.
---Restores previous view and calls cancel callback if not submitted.
---@param submitted boolean? True if command was submitted, false if cancelled
---@param inexplicit boolean? True if exit was automatic (e.g., focus lost)
function CommandView:exit(submitted, inexplicit)
  if core.active_view == self then
    core.set_active_view(core.last_active_view)
  end
  local cancel = self.state.cancel
  self.state = default_state
  self.doc:reset()
  self.suggestions = {}
  if not submitted then cancel(not inexplicit) end
  self.save_suggestion = nil
  self.last_text = ""
end


---Get line height for input text.
---@return integer height Line height in pixels
function CommandView:get_line_height()
  return math.floor(self:get_font():get_height() * 1.2)
end


---Get the width of the label gutter area.
---@return number width Gutter width in pixels
function CommandView:get_gutter_width()
  return self.gutter_width
end


---Get line height for suggestion items.
---@return number height Suggestion line height in pixels
function CommandView:get_suggestion_line_height()
  return self:get_font():get_height() + style.padding.y
end


---Update suggestions list by calling suggest callback.
---Normalizes string suggestions to table format {text = string}.
function CommandView:update_suggestions()
  local t = self.state.suggest(self:get_text()) or {}
  local res = {}
  for i, item in ipairs(t) do
    if type(item) == "string" then
      item = { text = item }
    end
    res[i] = item
  end
  self.suggestions = res
  self.suggestion_idx = 1
end


---Update the command view state each frame.
---Handles typeahead, animations, and auto-exit on focus loss.
function CommandView:update()
  CommandView.super.update(self)

  if core.active_view ~= self and self.state ~= default_state then
    self:exit(false, true)
  end

  -- update suggestions if text has changed
  if self.last_change_id ~= self.doc:get_change_id() then
    self:update_suggestions()
    if self.state.typeahead and self.suggestions[self.suggestion_idx] then
      local current_text = self:get_text()
      local suggested_text = self.suggestions[self.suggestion_idx].text or ""
      if #self.last_text < #current_text and
         string.find(suggested_text, current_text, 1, true) == 1 then
        self:set_text(suggested_text)
        self.doc:set_selection(1, #current_text + 1, 1, math.huge)
      end
      self.last_text = current_text
    end
    self.last_change_id = self.doc:get_change_id()
  end

  -- update gutter text color brightness
  self:move_towards("gutter_text_brightness", 0, 0.1, "commandview")

  -- update gutter width
  local dest = self:get_font():get_width(self.label) + style.padding.x
  if self.size.y <= 0 then
    self.gutter_width = dest
  else
    self:move_towards("gutter_width", dest, nil, "commandview")
  end

  -- update suggestions box height
  local lh = self:get_suggestion_line_height()
  local dest = self.state.show_suggestions and math.min(#self.suggestions, config.max_visible_commands) * lh or 0
  self:move_towards("suggestions_height", dest, nil, "commandview")

  -- update suggestion cursor offset
  local dest = math.min(self.suggestion_idx, config.max_visible_commands) * self:get_suggestion_line_height()
  self:move_towards("selection_offset", dest, nil, "commandview")

  -- update size based on whether this is the active_view
  local dest = 0
  if self == core.active_view then
    dest = style.font:get_height() + style.padding.y * 2
  end
  self:move_towards(self.size, "y", dest, nil, "commandview")
end


---Draw line highlight (disabled for command view).
function CommandView:draw_line_highlight()
  -- no-op function to disable this functionality
end


---Draw the label gutter with animated brightness.
---@param idx integer Line index (unused)
---@param x number Gutter x position
---@param y number Gutter y position
---@return integer height Line height
function CommandView:draw_line_gutter(idx, x, y)
  local yoffset = self:get_line_text_y_offset()
  local pos = self.position
  local color = common.lerp(style.text, style.accent, self.gutter_text_brightness / 100)
  core.push_clip_rect(pos.x, pos.y, self:get_gutter_width(), self.size.y)
  x = x + style.padding.x
  renderer.draw_text(self:get_font(), self.label, x, y + yoffset, color)
  core.pop_clip_rect()
  return self:get_line_height()
end


---Check if the mouse is hovering the suggestions box.
---@return boolean hovering True if mouse is over suggestions box
function CommandView:is_mouse_on_suggestions()
  if self.state.show_suggestions and #self.suggestions > 0 then
    local mx, my = self.mouse_position.x, self.mouse_position.y
    local dh = style.divider_size
    local sh = math.ceil(self.suggestions_height)
    local x, y, w, h = self.position.x, self.position.y - sh - dh, self.size.x, sh
    if mx >= x and mx <= x+w and my >= y and my <= y+h then
      return true
    end
  end
  return false
end


---Draw the suggestions dropdown box.
---Renders background, divider, and suggestion items with highlighting.
---@param self core.commandview
local function draw_suggestions_box(self)
  local lh = self:get_suggestion_line_height()
  local dh = style.divider_size
  local x, _ = self:get_line_screen_position()
  local h = math.ceil(self.suggestions_height)
  local rx, ry, rw, rh = self.position.x, self.position.y - h - dh, self.size.x, h

  if #self.suggestions > 0 then
    -- draw suggestions background
    renderer.draw_rect(rx, ry, rw, rh, style.background3)
    renderer.draw_rect(rx, ry - dh, rw, dh, style.divider)

    -- draw suggestion text
    local current = self.suggestion_idx
    local offset = math.max(current - config.max_visible_commands, 0)
    if self.suggestions_first-1 == current then
      offset = math.max(self.suggestions_first - 2, 0)
    end
    local first = 1 + offset
    local last = math.min(offset + config.max_visible_commands, #self.suggestions)
    if
      current < self.suggestions_first
      or
      current > self.suggestions_last
      or
      self.suggestions_last - self.suggestions_first < last - first
    then
      self.suggestions_first = first
      self.suggestions_last = last
      self.suggestions_offset = offset
    else
      offset = self.suggestions_offset
      first = self.suggestions_first
      last = math.min(self.suggestions_last, #self.suggestions)
    end
    core.push_clip_rect(rx, ry, rw, rh)
    local draw_text = self.state.draw_text
    local font = self:get_font()
    for i=first, last do
      local item = self.suggestions[i]
      local color = (i == current) and style.accent or style.text
      local y = self.position.y - (i - offset) * lh - dh
      if i == current then
        renderer.draw_rect(rx, y, rw, lh, style.line_highlight)
      end
      local w = self.size.x - x - style.padding.x
      if not draw_text then
        common.draw_text(font, color, item.text, nil, x, y, 0, lh)
      else
        draw_text(item, font, color, x, y, w, lh)
      end
      if item.info then
        common.draw_text(self:get_font(), style.dim, item.info, "right", x, y, w, lh)
      end
    end
    core.pop_clip_rect()
  end
end


---Draw the command view.
---Renders input text and defers suggestions box drawing.
function CommandView:draw()
  CommandView.super.draw(self)
  if self.state.show_suggestions then
    core.root_view:defer_draw(draw_suggestions_box, self)
  end
end


---Handle mouse movement over command view and suggestions.
---Updates suggestion selection when hovering suggestions box.
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@return boolean handled True if mouse is over suggestions
function CommandView:on_mouse_moved(x, y, ...)
  self.mouse_position.x = x
  self.mouse_position.y = y
  if self:is_mouse_on_suggestions() then
    core.request_cursor("arrow")

    local lh = self:get_suggestion_line_height()
    local dh = style.divider_size
    local offset = self.suggestions_offset
    local first = self.suggestions_first
    local last = self.suggestions_last

    for i=first, last do
      local sy = self.position.y - (i - offset) * lh - dh
      if y >= sy then
        self.suggestion_idx=i
        self:complete()
        self.last_change_id = self.doc:get_change_id()
        break
      end
    end
    return true
  end
  CommandView.super.on_mouse_moved(self, x, y, ...)
  return false
end


---Handle mouse wheel over suggestions box.
---Scrolls through suggestions when hovering.
---@param y number Scroll delta (negative = down, positive = up)
---@return boolean handled True if event was consumed
function CommandView:on_mouse_wheel(y, ...)
  if self:is_mouse_on_suggestions() then
    if y < 0 then
      self:move_suggestion_idx(-1)
    else
      self:move_suggestion_idx(1)
    end
    return true
  end
  CommandView.super.on_mouse_wheel(self, y, ...)
  return false
end


---Handle mouse press on suggestions box.
---Submits command if clicking a suggestion with left button.
---@param button core.view.mousebutton
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param clicks integer Number of clicks
---@return boolean handled True if event was consumed
function CommandView:on_mouse_pressed(button, x, y, clicks)
  if self:is_mouse_on_suggestions() then
    if button == "left" then
      self:submit()
    end
    return true
  end
  CommandView.super.on_mouse_pressed(self, button, x, y, clicks)
  return false
end


---Handle mouse release on suggestions box.
---Consumes event to prevent propagation.
---@return boolean handled True if mouse is over suggestions
function CommandView:on_mouse_released(...)
  if self:is_mouse_on_suggestions() then
    return true
  end
  CommandView.super.on_mouse_released(self, ...)
  return false
end


--------------------------------------------------------------------------------
-- Transmit mouse events to the suggestions box
-- TODO: Remove these overrides once FloatingView is implemented
--------------------------------------------------------------------------------
-- These monkey-patches intercept RootView mouse events to allow the
-- CommandView suggestions box (which renders outside CommandView bounds)
-- to receive mouse events. This is a temporary solution until FloatingView
-- is implemented to properly handle overlay UI elements.

local root_view_on_mouse_moved = RootView.on_mouse_moved
local root_view_on_mouse_wheel = RootView.on_mouse_wheel
local root_view_on_mouse_pressed = RootView.on_mouse_pressed
local root_view_on_mouse_released = RootView.on_mouse_released


---Intercept mouse movement to check CommandView suggestions first.
function RootView:on_mouse_moved(...)
  if core.active_view:is(CommandView) then
    if core.active_view:on_mouse_moved(...) then return true end
  end
  return root_view_on_mouse_moved(self, ...)
end


---Intercept mouse wheel to check CommandView suggestions first.
function RootView:on_mouse_wheel(...)
  if core.active_view:is(CommandView) then
    if core.active_view:on_mouse_wheel(...) then return true end
  end
  return root_view_on_mouse_wheel(self, ...)
end


---Intercept mouse press to check CommandView suggestions first.
function RootView:on_mouse_pressed(...)
  if core.active_view:is(CommandView) then
    if core.active_view:on_mouse_pressed(...) then return true end
  end
  return root_view_on_mouse_pressed(self, ...)
end


---Intercept mouse release to check CommandView suggestions first.
function RootView:on_mouse_released(...)
  if core.active_view:is(CommandView) then
    if core.active_view:on_mouse_released(...) then return true end
  end
  return root_view_on_mouse_released(self, ...)
end


return CommandView
