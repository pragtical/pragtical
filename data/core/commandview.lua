local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local Doc = require "core.doc"
local DocView = require "core.docview"
local View = require "core.view"
local Node = require "core.node"

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
---@field suggestions_query string Query used to generate the current results
---@field suggestions_change_id integer Input revision represented by the results or completion
---@field suggestions_view core.view Floating companion for suggestion input and scrolling
---@field restore_suggestion_scroll? { offset: number, target_offset: number } Pending restoration in logical rows
---@field reset_suggestion_scroll? boolean Reset scrolling to the first result after new results
---@field reveal_suggestion? boolean Reveal keyboard selection on the next companion update
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
---@field display_position "bottom"|"top"|"center" Placement retained for the current prompt
---@field dock_node? core.node Detached input node reused when returning to a bar placement
---@field center_height number Maximum panel height reserved for stable centered placement
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
---@field draw_text? fun(item: table, font: renderer.font, color: renderer.color, x: number, y: number, w: number, h: number) Custom suggestion renderer; w excludes info, spacing and scrollbar, and output is clipped
---@field select_text boolean Whether to select initial text
---@field show_suggestions boolean Whether to show suggestions box
---@field typeahead boolean Whether to enable typeahead completion
---@field wrap boolean Whether suggestion cycling wraps around
---@field restore_state? core.commandview.snapshot Snapshot to restore with this prompt's callbacks
---@field on_save_state? fun(snapshot: core.commandview.snapshot, submitted: boolean) Called after cleanup and before submit/cancel; submitted means validation passed
---@field get_suggestion_id? fun(item: table): string|number Stable result identity for restoring a selection after reordering
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


---Reusable prompt data, independent of callbacks, results, documents and animation.
---Offsets count rows from the first result, regardless of the prompt's placement.
---@class core.commandview.snapshot
---@field text string Displayed input text
---@field query? string Query used to regenerate results; defaults to text
---@field selections? integer[] Copied flat input selections: line1, col1, line2, col2
---@field last_selection? integer Active input selection index
---@field suggestion_idx? integer Selected result index; defaults to the first result
---@field suggestion_id? string|number Stable identity supplied by get_suggestion_id; missing results restore only the query
---@field last_text? string Previous input used for typeahead; defaults to text
---@field save_suggestion? string Original input retained while browsing hidden history
---@field suggestions_offset? number Current list offset in logical rows; defaults to zero
---@field suggestions_target_offset? number Target list offset in logical rows; defaults to current


---Convert a logical result offset to a clamped pixel scroll in the current placement.
---@param view core.commandview Prompt owning the list
---@param offset number Offset in rows from the first result
---@param height number List viewport height in pixels
---@return number scroll Pixel scroll offset
local function suggestion_scroll_from_offset(view, offset, height)
  local lh = view:get_suggestion_line_height()
  local maximum = math.max(0, #view.suggestions * lh - height)
  local scroll = offset * lh
  return common.clamp(view.display_position == "bottom" and maximum - scroll or scroll, 0, maximum)
end


---Constructor - initializes the command view.
function CommandView:new()
  CommandView.super.new(self, SingleLineDoc())
  self.suggestion_idx = 1
  self.suggestions = {}
  self.suggestions_height = 0
  self.suggestions_offset = 0
  self.suggestions_first = 1
  self.suggestions_last = 0
  self.suggestions_query = ""
  self.suggestions_change_id = 0
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
  self.display_position = "bottom"
  self.center_height = 0
  self.suggestions_view = View()
  local overlay = self.suggestions_view
  overlay:set_floating(true, { owner = self, focus = "none" })
  overlay.scrollable = true
  ---Draw the command owner's suggestions in the floating layer.
  overlay.draw = function()
    local lh = self:get_suggestion_line_height()
    local dh = style.divider_size
    local x, _ = self:get_line_screen_position()
    local rx, ry, rw, rh = self.suggestions_view:get_floating_bounds()

    if #self.suggestions > 0 then
      -- draw suggestions background
      renderer.draw_rect(rx, ry, rw, rh, style.background3)
      renderer.draw_rect(rx, ry - dh, rw, dh, style.divider)

      -- draw suggestion text
      local current = self.suggestion_idx
      local scroll = self:get_suggestion_scroll(rh)
      local first, last = self:get_suggestion_range(scroll, rh)
      core.push_clip_rect(rx, ry, rw, rh)
      local draw_text = self.state.draw_text
      local font = self:get_font()
      local text_height = font:get_height()
      local gutter = #self.suggestions * lh > rh
        and style.expanded_scrollbar_size + SCALE
        or 0
      local w = math.max(0, rx + rw - x - style.padding.x - gutter)
      for i=first, last do
        local item = self.suggestions[i]
        local color = (i == current) and style.accent or style.text
        local y = ry + self:get_suggestion_row(i) - scroll
        if i == current then
          renderer.draw_rect(rx, y, rw, lh, style.line_highlight)
        end
        local info_width = item.info and font:get_width(item.info) or 0
        local text_width = info_width > 0 and math.max(0, w - info_width - style.padding.x) or w
        if text_width > 0 then
          core.push_clip_rect(x, y, text_width, lh)
          if not draw_text then
            common.draw_text(font, color, item.text, nil, x, y, 0, lh)
          else
            draw_text(item, font, color, x, y, text_width, lh)
          end
          core.pop_clip_rect()
        end
        if info_width > 0 and w > 0 then
          local info_x = x + math.max(0, w - info_width)
          core.push_clip_rect(info_x, y, x + w - info_x, lh)
          renderer.draw_text(font, item.info, x + w - info_width,
            common.round(y + (lh - text_height) / 2), style.dim)
          core.pop_clip_rect()
        end
      end
      self.suggestions_view:draw_scrollbar()
      core.pop_clip_rect()
    end
  end
  ---Get the animated suggestions rectangle on the current side of the input.
  ---@return number x Screen x coordinate
  ---@return number y Screen y coordinate
  ---@return number w Suggestions viewport width
  ---@return number h Animated viewport height
  overlay.get_floating_bounds = function()
    return self:get_suggestions_bounds()
  end
  ---Get the full suggestion-list height before clipping to its animated viewport.
  ---@return number height Total suggestion height
  overlay.get_scrollable_size = function()
    return #self.suggestions * self:get_suggestion_line_height()
  end
  ---Disable horizontal scrolling in the suggestions companion.
  ---@return number width Always zero
  overlay.get_h_scrollable_size = function()
    return 0
  end
  local previous_height = 0
  ---Keep the first results anchored during height changes and reveal keyboard selection.
  ---Updates the owner's visible range after applying scrollbar interpolation.
  ---@param view core.view Suggestions companion
  overlay.update = function(view)
    local lh = self:get_suggestion_line_height()
    local bottom = self.display_position == "bottom"
    local restored = self.restore_suggestion_scroll
    if restored then
      view.scroll.y = suggestion_scroll_from_offset(self, restored.offset, view.size.y)
      view.scroll.to.y = suggestion_scroll_from_offset(self, restored.target_offset, view.size.y)
      self.restore_suggestion_scroll = nil
    elseif self.reset_suggestion_scroll then
      view.scroll.to.y = bottom and math.max(
        0, view:get_scrollable_size() - view.size.y
      ) or 0
      view.scroll.y = view.scroll.to.y
      self.reset_suggestion_scroll = false
    elseif bottom and previous_height ~= view.size.y then
      -- Suggestions are ordered from the bottom; resizing must keep that anchor.
      local delta = previous_height - view.size.y
      local max = math.max(0, view:get_scrollable_size() - view.size.y)
      view.scroll.y = common.clamp(view.scroll.y + delta, 0, max)
      view.scroll.to.y = common.clamp(view.scroll.to.y + delta, 0, max)
    end
    previous_height = view.size.y
    if self.reveal_suggestion then
      local top = self:get_suggestion_row(self.suggestion_idx)
      view.scroll.to.y = common.clamp(
        view.scroll.to.y,
        top + lh - view.size.y,
        top
      )
      self.reveal_suggestion = false
    end
    View.update(view)
    self.suggestions_first, self.suggestions_last, self.suggestions_offset =
      self:get_suggestion_range(view.scroll.y, view.size.y)
  end
  ---Handle scrollbar dragging first, then forward hover to suggestion selection.
  ---@param view core.view Suggestions companion
  ---@param x number Screen x coordinate
  ---@param y number Screen y coordinate
  ---@param ... number Pointer movement deltas
  ---@return boolean? consumed Whether scrolling or suggestion hover handled the event
  overlay.on_mouse_moved = function(view, x, y, ...)
    self.mouse_position.x, self.mouse_position.y = x, y
    if View.on_mouse_moved(view, x, y, ...) then
      return true
    end
    return self:on_mouse_moved(x, y, ...)
  end
  ---Give the suggestions scrollbar priority, then submit a clicked suggestion.
  ---@param view core.view Suggestions companion
  ---@param button core.view.mousebutton Pressed button
  ---@param x number Screen x coordinate
  ---@param y number Screen y coordinate
  ---@param clicks integer Consecutive click count
  ---@return boolean? consumed Whether the press was handled
  overlay.on_mouse_pressed = function(view, button, x, y, clicks)
    if View.on_mouse_pressed(view, button, x, y, clicks) then
      return true
    end
    self:on_mouse_moved(x, y, 0, 0)
    return self:on_mouse_pressed(button, x, y, clicks)
  end
  ---Release suggestions scrollbar dragging without forwarding another suggestion action.
  ---@param view core.view Suggestions companion
  ---@param ... any Mouse button and screen coordinates
  ---@return boolean consumed Always true
  overlay.on_mouse_released = function(view, ...)
    View.on_mouse_released(view, ...)
    return true
  end
  ---Scroll suggestions without submitting the current selection.
  ---@param view core.view Suggestions companion
  ---@param y number Vertical wheel delta
  ---@return boolean consumed Always true
  overlay.on_mouse_wheel = function(view, y)
    view.scroll.to.y = view.scroll.to.y - y * config.mouse_wheel_scroll
    core.redraw = true
    return true
  end
end


---Replace a layout branch without consuming nodes retained by plugins.
---@param root core.rootview Root whose layout owns the branch
---@param node core.node Branch to replace
---@param replacement core.node Branch to install in its place
local function replace_node(root, node, replacement)
  local parent = node:get_parent_node(root.root_node)
  if parent then
    parent[parent.a == node and "a" or "b"] = replacement
  else
    root.root_node = replacement
  end
end


---Apply the configured placement once before opening a prompt.
---Reparent only the input node, preserving document panes and their divider state.
function CommandView:apply_position()
  local position = config.commandview_position
  assert(position == "bottom" or position == "top" or position == "center",
    "Invalid commandview position")
  if self.display_position == position then return end
  local root = core.root_view
  root:cancel_floating_input(self)
  self:hide_floating()
  local node = root.root_node:get_node_for_view(self)
  if node then
    local parent = node:get_parent_node(root.root_node)
    self.dock_node = node
    replace_node(root, parent, parent.a == node and parent.b or parent.a)
  end
  self.display_position = position
  self.size.y, self.suggestions_height = 0, 0
  if position == "center" then
    self:set_floating(true, { focus = "show" })
  else
    self:set_floating(false)
    local anchor = position == "top" and core.menu_view or core.status_view
    local target = root.root_node:get_node_for_view(anchor)
    local before = position == "top" or target ~= nil
    if target and position == "top" then
      local parent = target:get_parent_node(root.root_node)
      target = parent.a == target and parent.b or parent.a
    end
    target = target or root.root_node
    local parent = Node("vsplit")
    replace_node(root, target, parent)
    if before then
      parent.a, parent.b = self.dock_node, target
    else
      parent.a, parent.b = target, self.dock_node
    end
  end
  root.root_node:update_layout()
end


---Get the settled suggestions height before clipping to the available viewport.
---@return number height Requested height in pixels
function CommandView:get_suggestions_height()
  return self.state.show_suggestions
    and math.min(#self.suggestions, config.max_visible_commands) * self:get_suggestion_line_height()
    or 0
end


---Get the animated suggestions rectangle, clipped to the editor viewport.
---@return number x Screen x coordinate
---@return number y Screen y coordinate
---@return number w Suggestions viewport width
---@return number h Animated viewport height
function CommandView:get_suggestions_bounds()
  local root = core.root_view
  local dh = style.divider_size
  local bottom = self.display_position == "bottom"
  local y = bottom and self.position.y - dh or self.position.y + self.size.y + dh
  local available = bottom and y - root.position.y or root.position.y + root.size.y - y
  if self.display_position == "center" then
    available = math.min(available, self.center_height - self.size.y - dh * 3)
  end
  local height = #self.suggestions > 0 and self.state.show_suggestions
    and math.min(math.ceil(self.suggestions_height), math.max(0, available)) or 0
  return self.position.x, bottom and y - height or y, self.size.x, height
end


---Get a result's top offset in the scrollable list in its visual ordering.
---@param index integer Suggestion index
---@return number y Top offset in pixels before scrolling
function CommandView:get_suggestion_row(index)
  local row = self.display_position == "bottom"
    and #self.suggestions - index
    or index - 1
  return row * self:get_suggestion_line_height()
end


---Get the current list's scroll offset, including a pending reset for new results.
---Drawing and input may run before a reopened companion receives its next update.
---@param height number Current suggestions viewport height
---@return number scroll Effective vertical scroll offset in pixels
function CommandView:get_suggestion_scroll(height)
  local maximum = math.max(
    0, #self.suggestions * self:get_suggestion_line_height() - height
  )
  if self.restore_suggestion_scroll then
    return suggestion_scroll_from_offset(self, self.restore_suggestion_scroll.offset, height)
  elseif self.reset_suggestion_scroll then
    return self.display_position == "bottom" and maximum or 0
  end
  return common.clamp(self.suggestions_view.scroll.y, 0, maximum)
end


---Find visible indexes from the current results instead of a previous prompt's cache.
---@param scroll number Effective vertical scroll offset in pixels
---@param height number Current suggestions viewport height
---@return integer first First visible suggestion index
---@return integer last Last visible suggestion index, less than first for an empty range
---@return number offset Visible range's fractional starting offset
function CommandView:get_suggestion_range(scroll, height)
  local lh = self:get_suggestion_line_height()
  local offset = scroll / lh
  if self.display_position == "bottom" then
    offset = #self.suggestions - height / lh - offset
  end
  return math.max(1, math.floor(offset) + 1),
    math.min(#self.suggestions, math.ceil(offset + height / lh)), offset
end


---Include suggestions in the centered popup's outer bounds for shared placement.
---@return number x Screen x coordinate
---@return number y Screen y coordinate
---@return number w Panel width
---@return number h Combined input and suggestions height, including the border
function CommandView:get_floating_bounds()
  if self.display_position ~= "center" then
    return CommandView.super.get_floating_bounds(self)
  end
  local _, _, _, height = self:get_suggestions_bounds()
  local border = style.divider_size
  return self.position.x - border,
    self.position.y - border,
    self.size.x + 2 * border,
    self.size.y + 2 * border + (height > 0 and height + border or 0)
end


---Apply composite popup placement without assigning the list's height to the input.
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param w number Outer panel width
---@param h number Outer panel height
function CommandView:set_floating_bounds(x, y, w, h)
  local border = style.divider_size
  self.position.x, self.position.y = x + border, y + border
  self.size.x = math.max(0, w - 2 * border)
  self.size.y = math.min(self.size.y, math.max(0, h - 2 * border))
end


---Center using the maximum visible result count so filtering keeps the top fixed.
---Recompute scale and window limits while retaining the closing panel's anchor.
function CommandView:update_floating()
  local root = core.root_view
  local width = math.max(0, root.size.x - 2 * style.padding.x)
  local height = math.max(0, root.size.y - 2 * style.padding.y)
  local border = style.divider_size
  local input = math.min(self:get_font():get_height() + style.padding.y * 2,
    math.max(0, height - 2 * border))
  if self.state ~= default_state then
    local suggestions = self.state.show_suggestions
      and config.max_visible_commands * self:get_suggestion_line_height() or 0
    self.center_height = math.min(
      height,
      input + 2 * border + (suggestions > 0 and suggestions + border or 0)
    )
  end
  local outer_width = math.min(800 * SCALE, width)
  self.size.x = math.max(0, outer_width - 2 * border)
  self.size.y = math.min(self.size.y, input)
  self.position.x = root.position.x + (root.size.x - outer_width) / 2 + border
  self.position.y = root.position.y
    + (root.size.y - math.min(self.center_height, height)) / 2
    + border
  CommandView.super.update_floating(self)
end


---Cancel a prompt removed through the floating lifecycle, including owner dismissal.
---@param visible boolean Whether the centered prompt is shown
function CommandView:on_floating_visibility_changed(visible)
  if not visible and self.state ~= default_state then
    self:exit(false, true)
  end
end


---Close a prompt without treating its temporary input as an unsaved document.
---Run cancellation after removal so its callback can open a replacement prompt.
---@param do_close fun() Continuation that removes the floating prompt
function CommandView:try_close(do_close)
  self:exit(false, false, do_close)
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
---@param dir integer Direction to move (1 for Up, -1 for Down)
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
    if self.display_position ~= "bottom" then dir = -dir end
    local n = self.suggestion_idx + dir
    self.suggestion_idx = overflow_suggestion_idx(n, #self.suggestions)
    self.reveal_suggestion = true
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
    self.suggestions_change_id = self.doc:get_change_id()
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


---Capture an open prompt without retaining its callbacks, results or input undo history.
---Pending edits are saved as a fresh query without invoking the suggestion provider.
---@return core.commandview.snapshot? snapshot Nil when no prompt is open
function CommandView:save_state()
  if self.state == default_state then return nil end
  local text = self:get_text()
  local change_id = self.doc:get_change_id()
  local pending = self.last_change_id ~= change_id and self.suggestions_change_id ~= change_id
  local _, _, _, height = self:get_suggestions_bounds()
  local scroll = self:get_suggestion_scroll(height)
  local target = self.reset_suggestion_scroll and scroll or self.suggestions_view.scroll.to.y
  if self.restore_suggestion_scroll then
    target = suggestion_scroll_from_offset(self, self.restore_suggestion_scroll.target_offset, height)
  end
  target = common.clamp(target, 0, math.max(0, #self.suggestions * self:get_suggestion_line_height() - height))
  local _, _, offset = self:get_suggestion_range(scroll, height)
  local _, _, target_offset = self:get_suggestion_range(target, height)
  local suggestion = not pending and self.suggestions[self.suggestion_idx]
  local suggestion_id = suggestion and self.state.get_suggestion_id
    and self.state.get_suggestion_id(suggestion) or nil
  assert(suggestion_id == nil or type(suggestion_id) == "string" or type(suggestion_id) == "number",
    "Expected a string or number suggestion ID")
  return {
    text = text,
    query = pending and text or self.suggestions_query,
    selections = { table.unpack(self.doc.selections) },
    last_selection = self.doc.last_selection,
    suggestion_idx = pending and 1 or self.suggestion_idx,
    suggestion_id = suggestion_id,
    last_text = self.last_text,
    save_suggestion = self.save_suggestion,
    suggestions_offset = pending and 0 or math.max(0, offset),
    suggestions_target_offset = pending and 0 or math.max(0, target_offset),
  }
end


---Restore an open prompt using its current provider exactly once, then restore the input.
---Result indexes and row offsets are clamped to the regenerated list and current viewport.
---A snapshot containing only text/query starts with the first result and initial scrolling.
---With get_suggestion_id, reordered results follow their identity and are revealed.
---If that result is gone, only the query is restored, discarding stale completion text.
---@param snapshot core.commandview.snapshot Prompt data, never modified by restoration
---@return boolean restored False when no prompt is open
function CommandView:restore_state(snapshot)
  if self.state == default_state then return false end
  assert(type(snapshot) == "table" and type(snapshot.text) == "string", "Expected a CommandView snapshot with text")
  assert(snapshot.query == nil or type(snapshot.query) == "string", "Expected a string snapshot query")
  self:update_suggestions(snapshot.query or snapshot.text)
  local index = snapshot.suggestion_idx
  local moved = false
  if snapshot.suggestion_id ~= nil and self.state.get_suggestion_id then
    local item = index and self.suggestions[index]
    if not item or self.state.get_suggestion_id(item) ~= snapshot.suggestion_id then
      index = nil
      for i, suggestion in ipairs(self.suggestions) do
        if self.state.get_suggestion_id(suggestion) == snapshot.suggestion_id then
          index = i
          break
        end
      end
    end
    if not index then
      -- A removed result must not leave its completed text or old index selected.
      snapshot = { text = snapshot.query or snapshot.text }
    else
      moved = index ~= snapshot.suggestion_idx
    end
  end
  if self:get_text() ~= snapshot.text then self:set_text(snapshot.text) end
  if snapshot.selections and #snapshot.selections > 0 then
    self.doc.selections = { table.unpack(snapshot.selections) }
    self.doc:sanitize_selection()
    self.doc.last_selection = common.clamp(snapshot.last_selection or 1, 1, #self.doc.selections / 4)
  else
    self.doc:set_selection(1, #self:get_text() + 1)
  end
  self.suggestion_idx = #self.suggestions > 0
    and common.clamp(index or 1, 1, #self.suggestions) or 0
  self.last_text = snapshot.last_text or snapshot.text
  self.save_suggestion = snapshot.save_suggestion
  self.last_change_id = self.doc:get_change_id()
  self.restore_suggestion_scroll = {
    offset = snapshot.suggestions_offset or 0,
    target_offset = snapshot.suggestions_target_offset or snapshot.suggestions_offset or 0,
  }
  self.reset_suggestion_scroll, self.reveal_suggestion = false, moved
  local _, _, _, height = self:get_suggestions_bounds()
  self.suggestions_view.scroll.y = suggestion_scroll_from_offset(self, self.restore_suggestion_scroll.offset, height)
  self.suggestions_view.scroll.to.y = suggestion_scroll_from_offset(self, self.restore_suggestion_scroll.target_offset, height)
  core.redraw = true
  return true
end


---Check whether a prompt is open, including one that has not received focus yet.
---@return boolean open True until the current prompt exits
function CommandView:is_open()
  return self.state ~= default_state
end


---Enter command mode with a prompt.
---Activates the command view with specified label and options.
---Ignored while another prompt is already open.
---State recall is opt-in and session-only; callers own snapshots and their context rules.
---To highlight an initial result without filtering, pass restore_state with empty text
---and its suggestion_id, and provide get_suggestion_id to identify the results.
---@param label string Label text to display (": " will be appended)
---@param options core.commandview.state Configuration options for this command session
---@overload fun(label: string, submit: function, suggest: function, cancel: function, validate: function)
---Example: remember a plugin prompt for this editor session.
---```lua
---local saved
---local function open_picker(items)
---  core.command_view:enter("Pick", {
---    suggest = function(query) return common.fuzzy_match(items, query) end,
---    get_suggestion_id = function(item) return item.text end,
---    restore_state = saved,
---    on_save_state = function(snapshot, submitted)
---      saved = not submitted and snapshot or nil
---    end,
---    submit = function(text, item) --[[ use the selected item ]] end,
---  })
---end
---```
function CommandView:enter(label, ...)
  if self.state ~= default_state then
    return
  end
  self:apply_position()
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

  if self.state.restore_state then
    self:restore_state(self.state.restore_state)
  else
    self:update_suggestions()
  end
  self.gutter_text_brightness = 100
  self.label = label .. ": "
  if self.floating then
    self:update_floating()
    self:show_floating()
  else
    core.set_active_view(self)
  end
end


---Exit command mode.
---Restores previous view and calls cancel callback if not submitted.
---@param submitted boolean? True if command was submitted, false if cancelled
---@param inexplicit boolean? True if exit was automatic (e.g., focus lost)
---@param do_close fun()? Optional placement removal performed before session callbacks
function CommandView:exit(submitted, inexplicit, do_close)
  local state = self.state
  local snapshot = state.on_save_state and self:save_state()
  if core.active_view == self then
    core.set_active_view(core.last_active_view)
  end
  self.state = default_state
  self.doc:reset()
  self.suggestions = {}
  self.save_suggestion = nil
  self.last_text = ""
  self.suggestions_query = ""
  self.restore_suggestion_scroll = nil
  self.suggestions_view:hide_floating()
  if self.floating_visible then
    self.floating_closing = true
    core.root_view:cancel_floating_input(self)
  end
  if do_close then do_close() end
  if snapshot then state.on_save_state(snapshot, not not submitted) end
  if not submitted then state.cancel(not inexplicit) end
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
---@param query string? Query to regenerate instead of the displayed input
function CommandView:update_suggestions(query)
  self.suggestions_query = query or self:get_text()
  local t = self.state.suggest(self.suggestions_query) or {}
  local res = {}
  for i, item in ipairs(t) do
    if type(item) == "string" then
      item = { text = item }
    end
    res[i] = item
  end
  self.suggestions = res
  self.suggestions_change_id = self.doc:get_change_id()
  self.suggestion_idx = 1
  self.reset_suggestion_scroll = true
  self.restore_suggestion_scroll = nil
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
  local dest = self:get_suggestions_height()
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
  if self.floating then
    self:update_floating()
    if self.state == default_state and self.size.y == 0 then
      self:hide_floating()
    end
  end
  if
    self.suggestions_height > 0
    and #self.suggestions > 0
    and self.state.show_suggestions
  then
    if not self.suggestions_view.floating_visible then
      self.suggestions_view:show_floating()
    end
  else
    self.suggestions_view:hide_floating()
  end
end


---Draw the clipped prompt input and a border enclosing the floating palette.
function CommandView:draw()
  if self.floating then
    local x, y, w, h = self:get_floating_bounds()
    local border = style.divider_size
    renderer.draw_rect(x, y, w, border, style.dim)
    renderer.draw_rect(x, y + h - border, w, border, style.dim)
    renderer.draw_rect(x, y, border, h, style.dim)
    renderer.draw_rect(x + w - border, y, border, h, style.dim)
  end
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  CommandView.super.draw(self)
  core.pop_clip_rect()
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
    local x, y, w, h = self.suggestions_view:get_floating_bounds()
    if mx >= x and mx <= x+w and my >= y and my <= y+h then
      return true
    end
  end
  return false
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
    local _, top, _, height = self:get_suggestions_bounds()
    local row = math.floor((y - top + self:get_suggestion_scroll(height)) / lh)
    local index = self.display_position == "bottom" and #self.suggestions - row or row + 1
    if index >= 1 and index <= #self.suggestions then
      self.suggestion_idx = index
      self:complete()
      self.last_change_id = self.doc:get_change_id()
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


return CommandView
