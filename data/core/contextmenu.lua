local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"

---@alias core.contextmenu.source core.contextmenu.item[]|fun():core.contextmenu.item[]

---Menu entry or submenu definition; use ContextMenu.DIVIDER for separators.
---@class core.contextmenu.item
---@field id? string Stable application-menu registration ID, independent of text
---@field text string Display label
---@field info? string Right-aligned hint; a command's assigned binding takes precedence
---@field command? string|fun() Command name or action to run when selected
---@field items? core.contextmenu.source Submenu entries or a provider called once on opening, mutually exclusive with command
---@field checked? boolean|fun():boolean Checked state evaluated when opening or navigating
---@field visible? boolean|fun():boolean Visibility evaluated when the menu opens
---@field divider? boolean Separator stored by application-menu registrations
---@field enabled? boolean Command availability cached on an opened entry
---@field checked_value? boolean Checked state cached on an opened entry

---Measured snapshot of entries for a single menu opening.
---@class core.contextmenu.items : table<integer, core.contextmenu.item>
---@field width number Measured width including horizontal padding
---@field height number Total row height before viewport clipping

---Input policy and placement supplied when opening an explicit menu tree.
---@class core.contextmenu.show_options
---@field disabled? boolean Keep unavailable entries disabled instead of filtering them
---@field owner? core.view Popup lifetime owner; defaults to the active view
---@field anchor? core.view.floating_anchor Position to follow while open
---@field child? boolean Submenu whose outside-click dismissal belongs to its root

---Floating command menu with predicate filtering, scrolling, and nested submenus.
---@class core.contextmenu : core.view
---@overload fun():core.contextmenu
---@field show_context_menu boolean Whether a menu opening is active
---@field selected integer Selected row index, or -1 when no row is selected
---@field items? core.contextmenu.items Measured snapshot of the current opening
---@field source_items? core.contextmenu.source Original entry definitions or provider
---@field application_menu? boolean Keep unavailable entries and refresh visited rows
---@field source_view? core.view Active view when the menu opened
---@field items_font? renderer.font Font used to measure the current snapshot
---@field child_menu? core.contextmenu Open submenu
---@field child_item? core.contextmenu.source Definitions used by the open submenu
---@field parent_menu? core.contextmenu Immediate parent when this is a submenu
---@field root_menu? core.contextmenu Menu that dispatches submenu leaf actions
---@field pressed_row? integer Application-menu row pressed for release validation
---@field hover_since? number Time when hover changed, for delayed submenu opening
---@field switch_top_menu? fun(step: integer) Application-bar navigation callback
local ContextMenu = View:extend()

---Separator sentinel accepted in registration and explicit menu item arrays.
ContextMenu.DIVIDER = {}

function ContextMenu:__tostring() return "ContextMenu" end

---Initialize a hidden, scrollable floating menu that preserves the editor's focus.
function ContextMenu:new()
  ContextMenu.super.new(self)
  self.itemset = {}
  self.show_context_menu = false
  self.selected = -1
  self.height = 0
  self.scrollable = true
  self.capture_text_input = true
  self:set_floating(true, {
    focus = "none",
    dismiss_on_escape = true,
    dismiss_on_outside_click = true
  })
end

---Evaluate a dynamic menu value safely, treating a failed callback as false.
---@param value any Static value or callback without arguments
---@return any value Resolved value, or false on callback failure
local function resolve(value)
  if type(value) == "function" then
    local ok, result = core.try(value)
    return ok and result
  end
  return value
end

---Compute the checkmark size from the current menu font.
---@return integer size Checkmark size in pixels
local function checkmark_size()
  return common.round(style.font:get_height() * 0.65)
end

---Draw a checkmark as a polygon without relying on font glyph availability.
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param size number Checkmark size in pixels
---@param color renderer.color Checkmark color
local function draw_checkmark(x, y, size, color)
  renderer.draw_poly({
    { x, y + size * 0.45 },
    { x + size * 0.16, y + size * 0.30 },
    { x + size * 0.40, y + size * 0.56 },
    { x + size * 0.84, y },
    { x + size, y + size * 0.14 },
    { x + size * 0.40, y + size * 0.88 }
  }, color)
end

---Measure a row's text, hint, submenu arrow, and optional checkmark space.
---@param item core.contextmenu.item Menu entry or divider sentinel
---@return number width Row width before outer horizontal padding
---@return number height Row height in pixels
local function item_size(item)
  if item == ContextMenu.DIVIDER then
    return 0, common.round(SCALE) + 10 * SCALE
  end
  local width = style.font:get_width(item.text)
  if item.info then
    width = width + style.padding.x + style.font:get_width(item.info)
  end
  if item.items then
    width = width + style.padding.x + style.font:get_width(">")
  end
  if item.checked ~= nil then
    width = width + style.padding.x + checkmark_size()
  end
  return width, style.font:get_height() + style.padding.y
end

---Store the current font's total menu width and row height on an item array.
---@param items core.contextmenu.items Entries to measure
local function measure(items)
  local width, height = 0, 0
  for _, item in ipairs(items) do
    local w, h = item_size(item)
    width, height = math.max(width, w), height + h
  end
  items.width, items.height = width + style.padding.x * 2, height
end

---Register contextual entries selected by a command-style predicate when opening.
---@param predicate core.command.predicate|nil Predicate receiving the opening coordinates
---@param items core.contextmenu.item[] Entries to contribute when the predicate succeeds
function ContextMenu:register(predicate, items)
  measure(items)
  table.insert(self.itemset, {
    predicate = command.generate_predicate(predicate),
    items = items
  })
end

---Check command availability, allowing submenus and direct callback actions.
---@param item core.contextmenu.item Entry to check
---@return boolean? enabled Whether the entry's command is available
local function item_enabled(item)
  return item.command == nil or type(item.command) == "function"
    or command.is_valid(item.command)
end

---Snapshot visible entries, availability, checked states, and current command bindings.
---Evaluates callbacks once for this opening and removes redundant separators.
---@param source core.contextmenu.source Entry definitions or an opening-time provider
---@param disabled? boolean Keep unavailable commands as disabled rows
---@return core.contextmenu.items items Measured entries for the opening
function ContextMenu:build_items(source, disabled)
  source = resolve(source)
  if type(source) ~= "table" then source = {} end
  local items = {}
  for _, original in ipairs(source) do
    if original == self.DIVIDER or original.divider then
      if #items > 0 and items[#items] ~= self.DIVIDER then
        table.insert(items, self.DIVIDER)
      end
    elseif original.visible == nil or resolve(original.visible) then
      local enabled = item_enabled(original)
      if disabled or enabled then
        local item = common.merge({}, original)
        item.enabled = not not enabled
        if item.checked ~= nil then
          item.checked_value = not not resolve(item.checked)
        end
        if type(item.command) == "string" then
          item.info = keymap.get_binding(item.command) or original.info
        end
        table.insert(items, item)
      end
    end
  end
  if items[#items] == self.DIVIDER then
    table.remove(items)
  end
  measure(items)
  return items
end

---Refresh a visited application-menu row's availability and checked state.
---Context menus keep their opening snapshot; this does not reevaluate visibility.
---@param item core.contextmenu.item? Entry to refresh
function ContextMenu:refresh_item(item)
  if self.application_menu and item and item ~= self.DIVIDER then
    item.enabled = not not item_enabled(item)
    if item.checked ~= nil then
      item.checked_value = not not resolve(item.checked)
    end
  end
end

---Show an explicit menu tree. Context registrations retain predicate filtering.
---Builds a new snapshot for this opening and leaves the rows unselected.
---@param source core.contextmenu.source Entry definitions or an opening-time provider
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param options? core.contextmenu.show_options Placement and unavailable-entry policy
---@return boolean shown Whether at least one entry was available to show
function ContextMenu:show_items(source, x, y, options)
  options = options or {}
  self.application_menu = options.disabled or false
  self.source_items = source
  self.items = self:build_items(source, self.application_menu)
  if #self.items == 0 then return false end
  self.items_font = style.font
  self.selected = -1
  self.scroll.x, self.scroll.y, self.scroll.to.x, self.scroll.to.y = 0, 0, 0, 0
  self.size.x, self.size.y = self.items.width, self.items.height
  self.position.x, self.position.y = x, y
  self.height = 0
  self.source_view = core.active_view
  self.show_context_menu = true
  self:set_floating(true, {
    owner = options.owner or self.source_view,
    anchor = options.anchor or false,
    dismiss_on_outside_click = not options.child,
    dismiss_on_owner_click = not self.application_menu,
    consume_outside_click = self.application_menu
  })
  self:show_floating()
  core.request_cursor("arrow")
  return true
end

---Open registered contextual entries whose predicates match the current target.
---@param x number Screen x coordinate, also passed to registration predicates
---@param y number Screen y coordinate, also passed to registration predicates
---@return boolean shown Whether a nonempty menu was opened
function ContextMenu:show(x, y)
  local source = {}
  for _, set in ipairs(self.itemset) do
    if set.predicate(x, y) then
      for _, item in ipairs(set.items) do
        table.insert(source, item)
      end
    end
  end
  return self:show_items(source, x, y)
end

---Hide this menu and its submenus, clearing the snapshot and selection.
function ContextMenu:hide()
  if self.child_menu then
    self.child_menu:hide()
    self.child_menu = nil
  end
  self.show_context_menu = false
  self:hide_floating()
  self.items, self.source_items = nil, nil
  self.selected, self.height = -1, 0
  if core.active_view then
    core.request_cursor(core.active_view.cursor)
  end
end

---Dismiss the whole menu tree when RootView requests dismissal of a popup.
---@param reason "escape"|"outside"|"focuslost" Dismissal event
function ContextMenu:on_floating_dismiss(reason)
  local root = self.root_menu or self
  root:hide()
end

---Clear menu state when RootView removes the popup, including owner-driven removal.
---@param visible boolean Whether the popup remains shown
function ContextMenu:on_floating_visibility_changed(visible)
  if not visible then
    self.show_context_menu = false
    self.items, self.source_items = nil, nil
    self.selected, self.height, self.pressed_row = -1, 0, nil
    self.child_menu, self.child_item = nil, nil
  end
end

---Get outer screen bounds including the menu border.
---@return number x Outer screen x coordinate
---@return number y Outer screen y coordinate
---@return number w Outer width
---@return number h Outer height
function ContextMenu:get_floating_bounds()
  local border = common.round(SCALE)
  return self.position.x - border, self.position.y - border,
    self.size.x + border * 2, self.size.y + border * 2
end

---Apply outer bounds, keeping the content inset by the menu border.
---@param x number Outer screen x coordinate
---@param y number Outer screen y coordinate
---@param w number Outer width
---@param h number Outer height
function ContextMenu:set_floating_bounds(x, y, w, h)
  local border = common.round(SCALE)
  self.position.x, self.position.y = x + border, y + border
  self.size.x = math.max(0, w - border * 2)
  self.size.y = math.max(0, h - border * 2)
end

---Get the full height of the current opening before viewport clipping.
---@return number height Total row height, or zero when closed
function ContextMenu:get_scrollable_size()
  return self.items and self.items.height or 0
end

---Iterate rows in display order with their scrolled screen rectangles.
---@return fun():integer, core.contextmenu.item, number, number, number, number iterator Yields index, entry, x, y, width, height
function ContextMenu:each_item()
  local y = self.position.y - self.scroll.y
  return coroutine.wrap(function()
    for i, item in ipairs(self.items or {}) do
      local _, height = item_size(item)
      coroutine.yield(i, item, self.position.x, y, self.size.x, height)
      y = y + height
    end
  end)
end

---Find the displayed row under a point within the popup bounds.
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@return integer index Row index, or -1 outside a row
function ContextMenu:row_at(x, y)
  if not self:hit_test(x, y) then return -1 end
  for i, _, bx, by, w, h in self:each_item() do
    if x >= bx and x < bx + w and y >= by and y < by + h then
      return i
    end
  end
  return -1
end

---Update scrollbar dragging and row hover, starting the submenu delay on row changes.
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param dx number Pointer x movement
---@param dy number Pointer y movement
---@return boolean handled Whether the pointer is within the shown menu
function ContextMenu:on_mouse_moved(x, y, dx, dy)
  if not self.show_context_menu then return false end
  ContextMenu.super.on_mouse_moved(self, x, y, dx, dy)
  local selected = self:row_at(x, y)
  if selected ~= self.selected then
    self.selected, self.hover_since = selected, system.get_time()
    self:refresh_item(self:get_item_selected())
    core.redraw = true
  end
  return self:hit_test(x, y)
end

---Clear scrollbar hover and cancel pending hover-driven submenu opening.
function ContextMenu:on_mouse_left()
  ContextMenu.super.on_mouse_left(self)
  self.hover_since = nil
end

---Open the selected enabled submenu, anchored to its parent row.
---Reuses an already open matching submenu and dispatches its leaves through the root.
function ContextMenu:open_submenu()
  local item = self:get_item_selected()
  if not item or not item.items or not item.enabled then return end
  if
    self.child_item == item.items
    and self.child_menu
    and self.child_menu.show_context_menu
  then
    return
  end
  if self.child_menu then self.child_menu:hide() end
  local rect
  for i, _, x, y, w, h in self:each_item() do
    if i == self.selected then
      rect = { x = x, y = y, w = w, h = h }
      break
    end
  end
  if not rect then return end
  local row_index = self.selected
  local child = ContextMenu()
  child.root_menu, child.parent_menu = self.root_menu or self, self
  child:show_items(item.items, rect.x + rect.w, rect.y, {
    disabled = self.application_menu, owner = self, child = true,
    anchor = { target = function()
      for i, _, x, y, w, h in self:each_item() do
        if i == row_index then return { x = x, y = y, w = w, h = h } end
      end
    end, side = "right" }
  })
  self.child_menu, self.child_item = child, item.items
end

---Get the current row, which may be a divider or unavailable application entry.
---@return core.contextmenu.item? item Selected entry, or nil when unselected
function ContextMenu:get_item_selected()
  return (self.items or {})[self.selected]
end

---Move selection with wrapping, skipping dividers and unavailable commands.
---Rechecks visited application entries and scrolls the selected row into view.
---@param step integer Direction: -1 for previous, 1 for next
function ContextMenu:focus_step(step)
  if not self.items then return end
  for _ = 1, #self.items do
    self.selected = (
        (self.selected < 1 and (step > 0 and 0 or 1) or self.selected)
        - 1 + step
      )
      % #self.items + 1
    local item = self:get_item_selected()
    self:refresh_item(item)
    if item ~= self.DIVIDER and item.enabled then
      for i, _, _, y, _, h in self:each_item() do
        if i == self.selected then
          self.scroll.to.y = math.max(
            0,
            self.scroll.to.y + math.min(0, y - self.position.y)
            + math.max(0, y + h - self.position.y - self.size.y)
          )
        end
      end
      core.redraw = true
      return
    end
  end
  self.selected = -1
end

---Select the previous enabled row, wrapping at the start.
function ContextMenu:focus_previous()
  self:focus_step(-1)
end

---Select the next enabled row, wrapping at the end.
function ContextMenu:focus_next()
  self:focus_step(1)
end

---Run an enabled entry's command or protected callback after menu dismissal.
---Override to customize action dispatch while retaining call_selected_item() behavior.
---@param item core.contextmenu.item Selected leaf entry
function ContextMenu:on_selected(item)
  if item == self.DIVIDER or not item.enabled then
    return
  end
  if type(item.command) == "string" then
    command.perform(item.command)
  elseif type(item.command) == "function" then
    core.try(item.command)
  end
end

---Activate a selected entry, opening its submenu or hiding the root before dispatch.
---Rechecks application-entry availability immediately before activation.
---@param selected? core.contextmenu.item Submenu leaf to dispatch through its root
function ContextMenu:call_selected_item(selected)
  selected = selected or self:get_item_selected()
  if not selected or selected == self.DIVIDER then
    return
  end
  self:refresh_item(selected)
  if not selected.enabled then
    return
  end
  if selected.items then
    self:open_submenu()
    return
  end
  if self.root_menu then
    self.root_menu:call_selected_item(selected)
    return
  end
  self:hide()
  self:on_selected(selected)
end

---Navigate rows, submenus, and application-menu groups without moving editor focus.
---The configured application-menu opener closes a shown menu without reopening it.
---Unrecognized modified bindings close the menu and continue to command dispatch.
---@param stroke string Normalized key binding
---@return boolean consumed Whether menu navigation consumed the binding
function ContextMenu:on_key_pressed(stroke)
  if not self.show_context_menu then return false end
  if self.application_menu then
    for _, binding in ipairs(keymap.get_bindings("menu-bar:open") or {}) do
      if stroke == binding then
        (self.root_menu or self):hide()
        return true
      end
    end
  end
  if stroke == "up" then
    self:focus_previous()
  elseif stroke == "down" then
    self:focus_next()
  elseif stroke == "return" or stroke == "keypad enter" then
    self:call_selected_item()
  elseif stroke == "right" then
    if self:get_item_selected() and self:get_item_selected().items then
      self:open_submenu()
      if self.child_menu then self.child_menu:focus_next() end
    elseif self.switch_top_menu then
      self.switch_top_menu(1)
    end
  elseif stroke == "left" then
    if self.parent_menu then
      self:hide(); self.parent_menu.child_menu = nil
    elseif self.switch_top_menu then
      self.switch_top_menu(-1)
    end
  elseif stroke == "escape" then
    if self.parent_menu then
      self:hide(); self.parent_menu.child_menu = nil
    else
      self:hide()
    end
  else
    if
      stroke:find("ctrl+", 1, true) or stroke:find("cmd+", 1, true)
      or stroke:find("alt+", 1, true) or stroke:find("option+", 1, true)
    then
      (self.root_menu or self):hide()
      return false
    end
    return true
  end
  return true
end

---Consume typed text so an open menu cannot edit the underlying document.
---@return boolean consumed Always true
function ContextMenu:on_text_input()
  return true
end

---Open on an unmodified right-click, or handle scrollbar and row presses when shown.
---Context actions run on press; application actions wait for a matching release.
---@param button core.view.mousebutton Pressed button
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param clicks integer Consecutive click count
---@return boolean consumed Whether the menu handled the press
function ContextMenu:on_mouse_pressed(button, x, y, clicks)
  if not self.show_context_menu then
    for _, pressed in pairs(keymap.modkeys) do
      if pressed then
        return false
      end
    end
    return button == "right" and self:show(x, y) or false
  end
  if ContextMenu.super.on_mouse_pressed(self, button, x, y, clicks) then
    return true
  end
  self.selected = self:row_at(x, y)
  if button == "left" then
    if self.application_menu then
      self.pressed_row = self.selected
    else
      self:call_selected_item()
    end
  end
  return true
end

---Release scrollbar dragging and activate an application row matching the pressed row.
---@param button core.view.mousebutton Released button
---@param x number Screen x coordinate
---@param y number Screen y coordinate
function ContextMenu:on_mouse_released(button, x, y)
  ContextMenu.super.on_mouse_released(self, button, x, y)
  if
    button == "left"
    and self.pressed_row
    and self.pressed_row == self:row_at(x, y)
  then
    self:call_selected_item()
  end
  self.pressed_row = nil
end

---Scroll the menu vertically without activating a row.
---@param y number Vertical wheel delta
---@param x number Horizontal wheel delta, unused
---@return boolean consumed Always true
function ContextMenu:on_mouse_wheel(y, x)
  self.scroll.to.y = self.scroll.to.y - y * config.mouse_wheel_scroll
  core.redraw = true
  return true
end

---Update scrolling, opening animation, and delayed submenu navigation.
---Font or scale changes remeasure the snapshot without rebuilding entries or predicates.
function ContextMenu:update()
  if not self.show_context_menu then
    return
  end
  local items = self.items
  if self.items_font ~= style.font or self.current_scale ~= SCALE then
    measure(items)
    self.items_font = style.font
  end
  self.size.x = math.min(
    items.width,
    math.max(0, core.root_view.size.x - 2 * SCALE)
  )
  self.size.y = math.min(
    items.height,
    math.max(0, core.root_view.size.y - 2 * SCALE)
  )
  ContextMenu.super.update(self)
  self:move_towards("height", self.size.y, nil, "contextmenu")
  if self.hover_since and system.get_time() - self.hover_since >= 0.2 then
    self.hover_since = nil
    local item = self:get_item_selected()
    if item and item ~= self.DIVIDER and item.items then
      self:open_submenu()
    elseif self.child_menu then
      self.child_menu:hide(); self.child_menu = nil
    end
  end
  if self.hover_since then
    core.request_update(self.hover_since + 0.2 - system.get_time())
  end
end

---Draw the animated menu viewport, cached row states, checkmarks, and scrollbar.
function ContextMenu:draw_context_menu()
  if not self.items then return end
  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.height
  local border = common.round(SCALE)
  renderer.draw_rect(
    x - border, y - border,
    w + border * 2, h + border * 2,
    style.divider
  )
  renderer.draw_rect(x, y, w, h, style.background3)
  core.push_clip_rect(x, y, w, h)
  for i, item, bx, by, bw, bh in self:each_item() do
    if item == self.DIVIDER then
      renderer.draw_rect(bx, by + 5 * SCALE, bw, border, style.divider)
    else
      local color = item.enabled and style.text or style.dim
      if i == self.selected and item.enabled then
        renderer.draw_rect(bx, by, bw, bh, style.selection)
      end
      local left = bx + style.padding.x
      if item.checked ~= nil then
        local size = checkmark_size()
        if item.checked_value then
          draw_checkmark(left, common.round(by + (bh - size) / 2), size, color)
        end
        left = left + size + style.padding.x
      end
      common.draw_text(style.font, color, item.text, "left", left, by, bw, bh)
      if item.info or item.items then
        common.draw_text(
          style.font, style.dim,
          item.items and ">" or item.info,
          "right", bx, by,
          bw - style.padding.x, bh
        )
      end
    end
  end
  self:draw_scrollbar()
  core.pop_clip_rect()
end

---Draw the menu through RootView's floating layer.
function ContextMenu:draw()
  self:draw_context_menu()
end

return ContextMenu
