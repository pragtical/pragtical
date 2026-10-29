local core = require "core"
local common = require "core.common"
local style = require "core.style"
local Node = require "core.node"
local View = require "core.view"
local DocView = require "core.docview"

---@class core.rootview.overlay.to
---@field x number
---@field y number
---@field w number
---@field h number

---@class core.rootview.overlay
---@field x number
---@field y number
---@field w number
---@field h number
---@field visible boolean
---@field opacity number
---@field base_color renderer.color
---@field color renderer.color
---@field to core.rootview.overlay.to

---@class core.rootview.mousegrab
---@field view core.view
---@field button core.view.mousebutton

---Top-level view managing the entire UI layout.
---Coordinates the node tree, handles drag & drop, routes events to child views.
---@class core.rootview : core.view
---@overload fun():core.rootview
---@field super core.view
---@field root_node core.node
---@field mouse core.view.position
---@field drag_overlay core.rootview.overlay
---@field drag_overlay_tab core.rootview.overlay
---@field grab core.rootview.mousegrab?
---@field deferred_draws table[]
---@field overlapping_view core.view?
---@field touched_view core.view?
---@field defer_open_docs table[]
---@field first_dnd_processed boolean
---@field first_update_done boolean
---@field floating_views core.view[] Shown views in drawing order
local RootView = View:extend()

function RootView:__tostring() return "RootView" end

---Constructor - initializes the root node tree and UI state.
---Called automatically by core at startup.
function RootView:new()
  RootView.super.new(self)
  self.root_node = Node()
  self.deferred_draws = {}
  self.mouse = { x = 0, y = 0 }
  self.drag_overlay = { x = 0, y = 0, w = 0, h = 0, visible = false, opacity = 0,
                        base_color = style.drag_overlay,
                        color = { table.unpack(style.drag_overlay) } }
  self.drag_overlay.to = { x = 0, y = 0, w = 0, h = 0 }
  self.drag_overlay_tab = { x = 0, y = 0, w = 0, h = 0, visible = false, opacity = 0,
                            base_color = style.drag_overlay_tab,
                            color = { table.unpack(style.drag_overlay_tab) } }
  self.drag_overlay_tab.to = { x = 0, y = 0, w = 0, h = 0 }
  self.grab = nil -- = {view = nil, button = nil}
  self.overlapping_view = nil
  self.touched_view = nil
  self.defer_open_docs = {}
  self.first_dnd_processed = false
  self.first_update_done = false
  self.floating_views = {}
end

---Register or raise a shown floating view in drawing order.
---Its owned popups remain above it and retain their relative order.
---Use View:show_floating() to also initialize visibility, placement, and focus.
---@param view core.view Floating view to register or raise
function RootView:add_floating_view(view)
  local children = {}
  for i = #self.floating_views, 1, -1 do
    local other = self.floating_views[i]
    if view:owns_view(other) then
      table.remove(self.floating_views, i)
      if other ~= view then table.insert(children, 1, other) end
    end
  end
  table.insert(self.floating_views, view)
  for _, child in ipairs(children) do table.insert(self.floating_views, child) end
end

---Copy the floating registry so callbacks can safely show or hide views while iterating.
---@return core.view[] views Shown views in drawing order, including closing views
function RootView:floating_snapshot()
  return { table.unpack(self.floating_views) }
end

---Cancel mouse capture, divider dragging, and tab dragging without emitting a click.
---Notifies the captured view through on_mouse_capture_lost() and clears drag overlays.
function RootView:cancel_mouse_capture()
  local grab = self.grab
  self.grab = nil
  self.dragged_divider, self.dragged_node, self.touched_view = nil, nil, nil
  self:set_show_overlay(self.drag_overlay, false)
  self:set_show_overlay(self.drag_overlay_tab, false)
  if grab then
    if self.overlapping_view == grab.view then self.overlapping_view = nil end
    grab.view:on_mouse_capture_lost()
  end
end

---Stop a popup's input, close its descendants, and restore focus when it owns focus.
---Called when hiding starts, including before a closing slide finishes.
---@param view core.view Floating view whose input and owned popups should be cleared
function RootView:cancel_floating_input(view)
  if self.grab and view:owns_view(self.grab.view) then self:cancel_mouse_capture() end
  if self.overlapping_view and view:owns_view(self.overlapping_view) then
    local hovered = self.overlapping_view
    self.overlapping_view = nil
    hovered:on_mouse_left()
  end
  for _, child in ipairs(self:floating_snapshot()) do
    if child ~= view and view:owns_view(child) then child:hide_floating() end
  end
  if view:owns_view(core.active_view) then
    local target = core.next_active_view or view.floating_previous_focus
    local node = target and self.root_node:get_node_for_view(target)
    if not target or not node and not target.floating_visible then
      target = self:get_primary_node().active_view
    end
    local closing = view.floating_closing
    view.floating_closing = true
    if target then core.set_active_view(target) end
    view.floating_closing = closing
  end
end

---Remove a view from the floating registry without changing its visibility or focus.
---Use View:hide_floating() to perform the complete closing lifecycle.
---@param view core.view Floating view to remove
function RootView:remove_floating_view(view)
  for i, other in ipairs(self.floating_views) do
    if other == view then table.remove(self.floating_views, i); break end
  end
end

---Fit an outer popup rectangle inside the editor viewport, reducing its size if needed.
---Returns the supplied rectangle unchanged while the viewport has no positive size.
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param w number Outer width in pixels
---@param h number Outer height in pixels
---@return number x Clamped screen x coordinate
---@return number y Clamped screen y coordinate
---@return number w Width limited to the viewport
---@return number h Height limited to the viewport
function RootView:clamp_floating_bounds(x, y, w, h)
  if self.size.x <= 0 or self.size.y <= 0 then return x, y, w, h end
  w, h = math.min(w, self.size.x), math.min(h, self.size.y)
  return common.clamp(x, self.position.x, self.position.x + self.size.x - w),
    common.clamp(y, self.position.y, self.position.y + self.size.y - h), w, h
end

---Apply a popup's anchor and clamp its outer bounds to the viewport.
---Flips the anchor side when necessary; leaves active slides and pointer gestures alone.
---@param view core.view Floating view to position
function RootView:place_floating_view(view)
  if view.floating_transition or view.floating_gesture then return end
  local x, y, w, h = view:get_floating_bounds()
  local anchor = view.floating_options.anchor
  if anchor then
    local rect = anchor.target
    if type(rect) == "function" then rect = rect() end
    if rect and rect.get_floating_bounds then
      local ax, ay, aw, ah = rect:get_floating_bounds()
      rect = { x = ax, y = ay, w = aw, h = ah }
    end
    if rect then
      local side, gap, align = anchor.side or "bottom", anchor.gap or 0, anchor.align or "start"
      local vertical = side == "bottom" or side == "top"
      if vertical then
        x = rect.x + (align == "end" and rect.w - w or align == "center" and (rect.w - w) / 2 or 0)
        y = side == "bottom" and rect.y + rect.h + gap or rect.y - h - gap
        if y + h > self.position.y + self.size.y then y = rect.y - h - gap
        elseif y < self.position.y then y = rect.y + rect.h + gap end
      else
        y = rect.y + (align == "end" and rect.h - h or align == "center" and (rect.h - h) / 2 or 0)
        x = side == "right" and rect.x + rect.w + gap or rect.x - w - gap
        if x + w > self.position.x + self.size.x then x = rect.x - w - gap
        elseif x < self.position.x then x = rect.x + rect.w + gap end
      end
    end
  end
  x, y, w, h = self:clamp_floating_bounds(x, y, math.max(w, 0), math.max(h, 0))
  view:set_floating_bounds(x, y, w, h)
end

---Find the topmost shown modal popup that is not closing.
---@return core.view? view Modal popup, or nil when input is unrestricted
function RootView:get_modal_view()
  for i = #self.floating_views, 1, -1 do
    local view = self.floating_views[i]
    if view.floating_visible and not view.floating_closing and view.floating_options.modal then return view end
  end
end

---Check whether the current modal popup permits a focus change.
---Only the modal view, its descendants, and its direct owner may receive focus.
---@param view core.view Proposed focus target
---@return boolean allowed Whether the view may receive focus
function RootView:can_focus_view(view)
  local modal = self:get_modal_view()
  return not modal or modal:owns_view(view)
    or modal.floating_options.owner == view
end

---Find the topmost interactive popup at a screen point, respecting modal ownership.
---A modal popup receives points outside its bounds; points outside RootView return nil.
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@return core.view? view Input target, or nil when no floating view receives the point
function RootView:get_floating_view_at(x, y)
  if x < self.position.x or y < self.position.y
    or x >= self.position.x + self.size.x or y >= self.position.y + self.size.y then return end
  local modal = self:get_modal_view()
  for i = #self.floating_views, 1, -1 do
    local view = self.floating_views[i]
    if view.floating_visible and not view.floating_closing
      and view.floating_options.interactive
      and (not modal or modal:owns_view(view)) and view:hit_test(x, y) then return view end
  end
  return modal
end

---Find the topmost shown floating view containing a keyboard focus target.
---Includes container descendants; excludes popups whose closing slide has started.
---@param target core.view? Focused view or one of its container descendants
---@return core.view? view Floating container, or nil for a docked target
function RootView:get_floating_view_for_view(target)
  for i = #self.floating_views, 1, -1 do
    local view = self.floating_views[i]
    if not view.floating_closing and view:owns_view(target) then return view end
  end
end

---Close a docked or shown floating view through its unsaved-changes guard.
---Rechecks placement after confirmation, since the view may have moved meanwhile.
---@param view core.view View to close
---@param on_close? fun(view:core.view) Called only after the view has closed
---@return boolean requested Whether the view had a placement to close
function RootView:close_view(view, on_close)
  if not self.root_node:get_node_for_view(view) and not view.floating_visible then return false end
  view:try_close(function()
    local node = self.root_node:get_node_for_view(view)
    if node then node:remove_view(self.root_node, view)
    else view:hide_floating() end
    if on_close then on_close(view) end
  end)
  return true
end

---Change the hovered view and notify the previous view when the pointer leaves it.
---@param view core.view? New hover target, or nil to clear hover
function RootView:set_hovered_view(view)
  local previous = self.overlapping_view
  self.overlapping_view = view
  if previous and previous ~= view then previous:on_mouse_left() end
end

---Dismiss the topmost popup configured for this outside-click event.
---Owned popups count as inside; the owner does too unless dismiss_on_owner_click is set.
---@param event "press"|"release" Mouse event phase
---@param button core.view.mousebutton Mouse button; only left and right dismiss
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@return boolean? consumed Whether the outside click should stop propagating
function RootView:dismiss_floating_outside(event, button, x, y)
  if button ~= "left" and button ~= "right" then return false end
  local views = self:floating_snapshot()
  for i = #views, 1, -1 do
    local view = views[i]
    local opts = view.floating_options
    if view.floating_visible and not view.floating_closing and opts.dismiss_on_outside_click
      and opts.outside_click_event == event then
      local inside = view:hit_test(x, y)
      local owner = opts.owner
      if owner and not opts.dismiss_on_owner_click and owner:hit_test(x, y) then inside = true end
      for _, other in ipairs(views) do
        if view:owns_view(other) and other:hit_test(x, y) then inside = true end
      end
      if not inside then
        view:on_floating_dismiss("outside")
        return opts.consume_outside_click
      end
      return false
    end
  end
  return false
end

---Route a normalized key binding to interactive floating views before commands run.
---Tries views from top to bottom, restricts modal input, and handles Escape dismissal.
---@param stroke string Normalized binding, such as "ctrl+return"
---@param ... any Additional keyboard event arguments
---@return boolean consumed Whether a popup handled the binding or was dismissed
function RootView:on_key_pressed(stroke, ...)
  local modal = self:get_modal_view()
  local views = self:floating_snapshot()
  for i = #views, 1, -1 do
    local view = views[i]
    if view.floating_visible and not view.floating_closing and view.floating_options.interactive
      and (not modal or modal:owns_view(view)) then
      if view:on_key_pressed(stroke, ...) then return true end
      if stroke == "escape" and view.floating_options.dismiss_on_escape then
        view:on_floating_dismiss("escape")
        return true
      end
    end
  end
  return false
end

---Identify resize edges within four scaled pixels of a popup's outer bounds.
---@param view core.view Floating view whose resizable option is checked
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@return core.view.floating_resize_edges edges Empty when resizing is disabled
local function floating_resize_edges(view, x, y)
  local bx, by, w, h = view:get_floating_bounds()
  local margin = 4 * SCALE
  return view.floating_options and view.floating_options.resizable and {
    left = x < bx + margin, right = x >= bx + w - margin,
    top = y < by + margin, bottom = y >= by + h - margin
  } or {}
end

---Get a resize cursor for a popup edge or use the view's ordinary cursor.
---During a gesture, keeps the cursor associated with the originally grabbed edges.
---@param view core.view Floating pointer target
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@return core.view.cursor cursor Cursor to display
function RootView:get_floating_cursor(view, x, y)
  local edges = view.floating_gesture and view.floating_gesture.edges or floating_resize_edges(view, x, y)
  if edges.left and edges.top or edges.right and edges.bottom then return "sizenwse" end
  if edges.left and edges.bottom or edges.right and edges.top then return "sizenesw" end
  if edges.left or edges.right then return "sizeh" end
  if edges.top or edges.bottom then return "sizev" end
  return view.cursor
end

---Start dragging or resizing a floating view and capture its left-button input.
---Resizing takes precedence over dragging; a successful gesture clears the anchor.
---@param view core.view Floating pointer target
---@param button core.view.mousebutton Pressed button
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param resize_only? boolean Only start a resize, allowing content to handle other presses
---@return boolean started Whether a gesture started and the mouse was captured
function RootView:begin_floating_gesture(view, button, x, y, resize_only)
  if button ~= "left" then return false end
  local opts = view.floating_options
  local bx, by, w, h = view:get_floating_bounds()
  local edges = floating_resize_edges(view, x, y)
  local resize = edges.left or edges.right or edges.top or edges.bottom
  if resize_only and not resize then return false end
  local dx, dy, dw, dh = view:get_floating_drag_region()
  if not resize and not (opts.draggable and dx and x >= dx and y >= dy and x < dx + dw and y < dy + dh) then return false end
  view.floating_gesture = { x = x, y = y, bx = bx, by = by, w = w, h = h, edges = edges, resize = resize }
  opts.anchor = nil
  self:grab_mouse(button, view)
  return true
end

---Advance a captured floating drag or resize using its initial bounds and pointer offset.
---Resizing honors min_size; the resulting bounds are clamped to the viewport.
---@param view core.view Floating view with an active gesture
---@param x number Current screen x coordinate
---@param y number Current screen y coordinate
---@return boolean handled Whether the view had a gesture to update
function RootView:move_floating_gesture(view, x, y)
  local gesture = view.floating_gesture
  if not gesture then return false end
  local dx, dy = x - gesture.x, y - gesture.y
  local bx, by, w, h = gesture.bx, gesture.by, gesture.w, gesture.h
  local edges, minimum = gesture.edges, view.floating_options.min_size
  if gesture.resize then
    if edges.right then w = math.max(minimum.x, w + dx) end
    if edges.bottom then h = math.max(minimum.y, h + dy) end
    if edges.left then w = math.max(minimum.x, w - dx); bx = gesture.bx + gesture.w - w end
    if edges.top then h = math.max(minimum.y, h - dy); by = gesture.by + gesture.h - h end
  else bx, by = bx + dx, by + dy end
  view:set_floating_bounds(self:clamp_floating_bounds(bx, by, w, h))
  core.redraw = true
  return true
end


---Queue a drawing operation to execute after main scene is rendered.
---Useful for overlays, tooltips, or drag indicators that should draw on top.
---@param fn function Function to call for drawing
---@param ... any Arguments to pass to the function
function RootView:defer_draw(fn, ...)
  table.insert(self.deferred_draws, 1, { fn = fn, ... })
end


---Get the node containing the currently active view.
---Falls back to primary node if active view not found.
---@return core.node node Node containing active view or primary node
function RootView:get_active_node()
  local node = self.root_node:get_node_for_view(core.active_view)
  if not node then node = self:get_primary_node() end
  return node
end


---Find the primary node in the tree recursively.
---@param node core.node Node to search from
---@return core.node node The primary node
local function get_primary_node(node)
  if node.is_primary_node then
    return node
  end
  if node.type ~= "leaf" then
    return get_primary_node(node.a) or get_primary_node(node.b)
  end
end


---Get the active node, ensuring it's not locked.
---If active node is locked, switches to primary node instead.
---Use this when adding new views to ensure they go to an editable node.
---@return core.node node Unlocked node suitable for adding views
function RootView:get_active_node_default()
  local node = self.root_node:get_node_for_view(core.active_view)
  if not node then node = self:get_primary_node() end
  if node.locked then
    local default_view = self:get_primary_node().views[1]
    assert(default_view, "internal error: cannot find original document node.")
    core.set_active_view(default_view)
    node = self:get_active_node()
  end
  return node
end


---Get the primary node (main document editing area).
---Primary node is where documents are opened by default.
---@return core.node node The primary node
function RootView:get_primary_node()
  return get_primary_node(self.root_node)
end


---Find next available unlocked node to become primary.
---Searches recursively through the tree for unlocked leaf nodes.
---@param node core.node Node to search from
---@return core.node? node Next unlocked leaf node, or nil if none found
local function select_next_primary_node(node)
  if node.is_primary_node then return end
  if node.type ~= "leaf" then
    return select_next_primary_node(node.a) or select_next_primary_node(node.b)
  else
    local lx, ly = node:get_locked_size()
    if not lx and not ly then
      return node
    end
  end
end


---Select a new primary node from available unlocked nodes.
---Used when closing the current primary node.
---@return core.node node Next available unlocked node to be primary
function RootView:select_next_primary_node()
  return select_next_primary_node(self.root_node)
end


---Open a document in the active node.
---If document is already open, switches to that view instead.
---Creates a new DocView and adds it as a tab in the active node.
---@param doc core.doc Document to open
---@return core.docview view The view displaying the document
function RootView:open_doc(doc)
  local node = self:get_active_node_default()
  for i, view in ipairs(node.views) do
    if view.doc == doc then
      node:set_active_view(node.views[i])
      return view
    end
  end
  local view = DocView(doc)
  node:add_view(view)
  self.root_node:update_layout()
  view:scroll_to_line(view.doc:get_selection(), true, true)
  return view
end


---Close docked document views and remove session-scoped floating views.
---Used when closing a project or switching workspaces.
---@param keep_active boolean Keep the currently active view open
function RootView:close_all_docviews(keep_active)
  local active = core.active_view
  self.root_node:close_all_docviews(keep_active)
  for _, view in ipairs(self:floating_snapshot()) do
    if view.context == "session" and (not keep_active or view ~= active) then view:hide_floating() end
  end
end


---Capture mouse input for a specific view.
---All mouse events for the specified button will be routed to this view,
---even when the mouse moves outside the view's bounds.
---Only one grab can be active per button at a time.
---Common use: drag operations, scrollbar dragging, text selection.
---@param button core.view.mousebutton Button to grab
---@param view core.view View that should receive mouse events
function RootView:grab_mouse(button, view)
  assert(self.grab == nil)
  self.grab = {view = view, button = button}
end


---Release mouse grab for the specified button.
---Button must match the button that was grabbed.
---After release, normal mouse event routing resumes.
---@param button core.view.mousebutton Button to release (must match grabbed button)
function RootView:ungrab_mouse(button)
  assert(self.grab and self.grab.button == button)
  self.grab = nil
end


---Hook function called before mouse pressed events reach the active view.
---Override this to intercept or modify mouse press behavior globally.
---Default implementation does nothing.
---@param button core.view.mousebutton
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param clicks integer Number of clicks
function RootView.on_view_mouse_pressed(button, x, y, clicks)
end


---Handle mouse press events and route to appropriate targets.
---Manages: divider dragging, tab clicking/dragging, view activation, event routing.
---Overrides base View implementation to handle complex UI interactions.
---@param button core.view.mousebutton
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param clicks integer Number of clicks
---@return boolean handled True if event was handled
function RootView:on_mouse_pressed(button, x, y, clicks)
  -- If there is a grab, release it first
  if self.grab then
    self:on_mouse_released(self.grab.button, x, y)
  end
  self.mouse.x, self.mouse.y = x, y
  if self:dismiss_floating_outside("press", button, x, y) then return true end
  local floating = self:get_floating_view_at(x, y)
  if floating then
    self:set_hovered_view(floating)
    floating:bring_to_front()
    local opts = floating.floating_options
    if opts.focus == "click" then
      local target = floating:get_focus_target()
      if target and target ~= core.active_view then
        floating.floating_previous_focus = core.active_view
        core.set_active_view(target)
      end
    end
    if opts.resizable and self:begin_floating_gesture(floating, button, x, y, true) then return true end
    local handled = floating:on_mouse_pressed(button, x, y, clicks)
    if not handled and opts.draggable and self:begin_floating_gesture(floating, button, x, y) then return true end
    if handled or not opts.pass_through_unhandled then
      if not self.grab and floating.floating_visible then self:grab_mouse(button, floating) end
      return true
    end
  end
  local div = self.root_node:get_divider_overlapping_point(x, y)
  local node = self.root_node:get_child_overlapping_point(x, y)
  if not node then return false end
  if div and (node and not node.active_view:scrollbar_overlaps_point(x, y)) then
    self.dragged_divider = div
    return true
  end
  if node.hovered_scroll_button > 0 then
    node:scroll_tabs(node.hovered_scroll_button)
    return true
  end
  local idx = node:get_tab_overlapping_point(x, y)
  if idx then
    if button == "middle" or node.hovered_close == idx then
      node:close_view(self.root_node, node.views[idx])
      return true
    else
      if button == "left" then
        self.dragged_node = { node = node, idx = idx, dragging = false, drag_start_x = x, drag_start_y = y}
      end
      node:set_active_view(node.views[idx])
      return true
    end
  elseif not self.dragged_node then -- avoid sending on_mouse_pressed events when dragging tabs
    local target = node.active_view:get_focus_target()
    if target then core.set_active_view(target) end
    self:grab_mouse(button, node.active_view)
    return self.on_view_mouse_pressed(button, x, y, clicks) or node.active_view:on_mouse_pressed(button, x, y, clicks)
  end
end


---Get the base color for a drag overlay.
---Internal helper to fetch color from style based on overlay type.
---@param overlay core.rootview.overlay The overlay to get color for
---@return renderer.color color The base color from style
function RootView:get_overlay_base_color(overlay)
  if overlay == self.drag_overlay then
    return style.drag_overlay
  else
    return style.drag_overlay_tab
  end
end


---Show or hide a drag overlay with color reset.
---Internal helper for managing drag visual feedback state.
---@param overlay core.rootview.overlay The overlay to show/hide
---@param status boolean True to show, false to hide
function RootView:set_show_overlay(overlay, status)
  overlay.visible = status
  if status then -- reset colors
    -- reload base_color
    overlay.base_color = self:get_overlay_base_color(overlay)
    overlay.color[1] = overlay.base_color[1]
    overlay.color[2] = overlay.base_color[2]
    overlay.color[3] = overlay.base_color[3]
    overlay.color[4] = overlay.base_color[4]
    overlay.opacity = 0
  end
end


---Handle mouse button release events.
---Manages: mouse grab release, divider drag completion, tab drop/rearrange.
---Handles complex tab drag-and-drop logic (split, move, reorder).
---@param button core.view.mousebutton
---@param x number Screen x coordinate
---@param y number Screen y coordinate
function RootView:on_mouse_released(button, x, y, ...)
  self:dismiss_floating_outside("release", button, x, y)
  if self.grab then
    if self.grab.button == button then
      local grab = self.grab
      local grabbed_view = grab.view
      if grabbed_view.floating_gesture then
        grabbed_view.floating_gesture = nil
      else
        grabbed_view:on_mouse_released(button, x, y, ...)
      end
      -- The release callback may clear or replace this grab.
      if self.grab == grab then self:ungrab_mouse(button) end

      -- If the mouse was released over a different view, send it the mouse position
      local node = self.root_node:get_child_overlapping_point(x, y)
      local hovered_view = self:get_floating_view_at(x, y) or node and node.active_view
      if not self.grab and grabbed_view ~= hovered_view then
        self:on_mouse_moved(x, y, 0, 0)
      end
    end
    return
  end

  if self.dragged_divider then
    self.dragged_divider = nil
  end
  if self.dragged_node then
    if button == "left" then
      if self.dragged_node.dragging then
        local node = self.root_node:get_child_overlapping_point(self.mouse.x, self.mouse.y)
        local dragged_node = self.dragged_node.node

        if node and not node.locked
           -- don't do anything if dragging onto own node, with only one view
           and (node ~= dragged_node or #node.views > 1) then
          local split_type = node:get_split_type(self.mouse.x, self.mouse.y)
          local view = dragged_node.views[self.dragged_node.idx]

          if split_type ~= "middle" and split_type ~= "tab" then -- needs splitting
            local new_node = node:split(split_type)
            self.root_node:get_node_for_view(view):remove_view(self.root_node, view)
            new_node:add_view(view)
          elseif split_type == "middle" and node ~= dragged_node then -- move to other node
            dragged_node:remove_view(self.root_node, view)
            node:add_view(view)
            self.root_node:get_node_for_view(view):set_active_view(view)
          elseif split_type == "tab" then -- move besides other tabs
            local tab_index = node:get_drag_overlay_tab_position(
              self.mouse.x, self.mouse.y, dragged_node, self.dragged_node.idx
            )
            dragged_node:remove_view(self.root_node, view)
            node:add_view(view, tab_index)
            self.root_node:get_node_for_view(view):set_active_view(view)
          end
          self.root_node:update_layout()
          core.redraw = true
        end
      end
      self:set_show_overlay(self.drag_overlay, false)
      self:set_show_overlay(self.drag_overlay_tab, false)
      if self.dragged_node and self.dragged_node.dragging then
        core.request_cursor("arrow")
      end
      self.dragged_node = nil
    end
  end
end


---Resize split node children when dragging divider.
---Tries resizing locked nodes first, falls back to proportional divider adjustment.
---@param node core.node The split node being resized
---@param axis string "x" or "y"
---@param value number New size value for the split
---@param delta number Mouse movement delta
local function resize_child_node(node, axis, value, delta)
  local accept_resize = node.a:resize(axis, value)
  if not accept_resize then
    accept_resize = node.b:resize(axis, node.size[axis] - value)
  end
  if not accept_resize then
    node.divider = node.divider + delta / node.size[axis]
  end
end


---Handle mouse movement events and route appropriately.
---Manages: grabbed view routing, divider dragging, tab drag start, cursor changes.
---Updates overlapping_view for hover state tracking.
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param dx number Delta x since last move
---@param dy number Delta y since last move
function RootView:on_mouse_moved(x, y, dx, dy)
  self.mouse.x, self.mouse.y = x, y

  if self.grab then
    if not self:move_floating_gesture(self.grab.view, x, y) then
      self.grab.view:on_mouse_moved(x, y, dx, dy)
      if self.grab and self.grab.view.floating_visible then
        self:place_floating_view(self.grab.view)
      end
    end
    if self.grab then core.request_cursor(self:get_floating_cursor(self.grab.view, x, y)) end
    return
  end

  local floating = self:get_floating_view_at(x, y)
  if floating then
    self:set_hovered_view(floating)
    local handled = floating:on_mouse_moved(x, y, dx, dy)
    if handled or not floating.floating_options.pass_through_unhandled then
      core.request_cursor(self:get_floating_cursor(floating, x, y))
      return true
    end
  end

  if self.dragged_divider then
    local node = self.dragged_divider
    if node.type == "hsplit" then
      x = common.clamp(x - node.position.x, 0, self.root_node.size.x * 0.95)
      resize_child_node(node, "x", x, dx)
    elseif node.type == "vsplit" then
      y = common.clamp(y - node.position.y, 0, self.root_node.size.y * 0.95)
      resize_child_node(node, "y", y, dy)
    end
    node.divider = common.clamp(node.divider, 0.01, 0.99)
    return
  end

  local dn = self.dragged_node
  if dn and not dn.dragging then
    -- start dragging only after enough movement
    dn.dragging = common.distance(x, y, dn.drag_start_x, dn.drag_start_y) > style.tab_width * .05
    if dn.dragging then
      core.request_cursor("hand")
    end
  end

  -- avoid sending on_mouse_moved events when dragging tabs
  if dn then return end

  local last_overlapping_view = self.overlapping_view
  local overlapping_node = self.root_node:get_child_overlapping_point(x, y)
  self.overlapping_view = overlapping_node and overlapping_node.active_view

  if last_overlapping_view and last_overlapping_view ~= self.overlapping_view then
    last_overlapping_view:on_mouse_left()
  end

  if not self.overlapping_view then return end

  self.overlapping_view:on_mouse_moved(x, y, dx, dy)
  core.request_cursor(self.overlapping_view.cursor)

  if not overlapping_node then return end

  local div = self.root_node:get_divider_overlapping_point(x, y)
  if overlapping_node:get_scroll_button_index(x, y) or overlapping_node:is_in_tab_area(x, y) then
    core.request_cursor("arrow")
  elseif div and not self.overlapping_view:scrollbar_overlaps_point(x, y) then
    core.request_cursor(div.type == "hsplit" and "sizeh" or "sizev")
  end
end


---Called when mouse leaves the root view area.
---Notifies the currently overlapping view to clear hover states.
function RootView:on_mouse_left()
  self:set_hovered_view(nil)
end


---Handle file/folder drop events from OS.
---Supports: opening files, adding projects, showing dialogs.
---Files are deferred if nagview is visible to avoid locked node errors.
---@param filename string Absolute path to dropped file/folder
---@param x number Screen x where dropped
---@param y number Screen y where dropped
---@return boolean handled True if event was handled
function RootView:on_file_dropped(filename, x, y)
  local floating = self:get_floating_view_at(x, y)
  if floating then
    local result = floating:on_file_dropped(filename, x, y)
    if result or self:get_modal_view() then return true end
  end
  local node = self.root_node:get_child_overlapping_point(x, y)
  local result = node and node.active_view:on_file_dropped(filename, x, y)
  if result then return result end
  local info = system.get_file_info(filename)
  if info and info.type == "dir" then
    local abspath = system.absolute_path(filename) --[[@as string]]
    if self.first_update_done then
      -- ask the user if they want to open it here or somewhere else
      core.nag_view:show(
        "Open directory",
        string.format('You are trying to open "%s"\n', common.home_encode(abspath))
        .. "Do you want to open this directory here, or in a new window?",
        {
          { text = "Current window", default_yes = true },
          { text = "New window", default_no = true },
          { text = "Cancel" }
        },
        function(opt)
          if opt.text == "Current window" then
            core.add_project(abspath)
          elseif opt.text == "New window" then
            system.exec(string.format("%q %q", EXEFILE, filename))
          end
        end
      )
      return true
    end
    -- in macOS, when dropping folders into Pragtical in the dock,
    -- the OS tries to start an instance of Pragtical with each folder as a DND request.
    -- When this happens, the DND request always arrive before the first update() call.
    -- We need to change the current project folder for the first request, and start
    -- new instances for the rest to emulate existing behavior.
    if self.first_dnd_processed then
      -- FIXME: port to process API
      system.exec(string.format("%q %q", EXEFILE, filename))
    else
      -- change project directory
      core.confirm_close_docs(core.docs, function(dirpath)
        core.open_folder_project(dirpath)
      end, system.absolute_path(filename))
      self.first_dnd_processed = true
    end
    return true
  end
  -- defer opening docs in case nagview is visible (which will cause a locked node error)
  table.insert(self.defer_open_docs, { filename, x, y })
  return true
end


---Process deferred file drops (files dropped while nagview was active).
---Called during update() to safely open files when nagview is dismissed.
function RootView:process_defer_open_docs()
  if core.active_view == core.nag_view then return end
  for _, drop in ipairs(self.defer_open_docs) do
    -- file dragged into editor, try to open it
    local filename, x, y = table.unpack(drop)
    local node = self.root_node:get_child_overlapping_point(x, y)
    if node then node:set_active_view(node.active_view) end
    core.try(core.open_file, filename)
  end
  self.defer_open_docs = {}
end


---Forward mouse wheel events to the view under the mouse.
function RootView:on_mouse_wheel(...)
  local x, y = self.mouse.x, self.mouse.y
  local node = self.root_node:get_child_overlapping_point(x, y)
  local floating = self:get_floating_view_at(x, y)
  if floating then
    local handled = floating:on_mouse_wheel(...)
    if handled or not floating.floating_options.pass_through_unhandled then
      return true
    end
  end
  return node and node.active_view:on_mouse_wheel(...)
end


---Offer typed text to an explicit popup capture, then the active view exactly once.
---Focused popup descendants receive text directly, without container forwarding.
---@param ... string Typed text forwarded to the target handler
---@return boolean? consumed True when a floating handler consumes the text
function RootView:on_text_input(...)
  for i = #self.floating_views, 1, -1 do
    local view = self.floating_views[i]
    if
      not view.floating_closing and view.floating_options.interactive
      and view.capture_text_input and not view:owns_view(core.active_view)
    then
      if view:on_text_input(...) then
        return true
      end
      break
    end
  end
  return core.active_view:on_text_input(...)
end


---Handle touch press events (touchscreen/trackpad).
---Tracks which view is being touched for subsequent touch events.
function RootView:on_touch_pressed(x, y, ...)
  local touched_node = self.root_node:get_child_overlapping_point(x, y)
  self.touched_view = self:get_floating_view_at(x, y)
    or touched_node and touched_node.active_view
end


---Handle touch release events.
---Clears the touched view tracking.
function RootView:on_touch_released(x, y, ...)
  self.touched_view = nil
end


---Handle touch movement events (swipe gestures, etc.).
---Routes to touched view or handles divider/tab dragging.
function RootView:on_touch_moved(x, y, dx, dy, ...)
  if not self.touched_view then return end
  if core.active_view == core.nag_view then
    core.active_view:on_touch_moved(x, y, dx, dy, ...)
    return
  end

  if self.dragged_divider then
    local node = self.dragged_divider
    if node.type == "hsplit" then
      x = common.clamp(x - node.position.x, 0, self.root_node.size.x * 0.95)
      resize_child_node(node, "x", x, dx)
    elseif node.type == "vsplit" then
      y = common.clamp(y - node.position.y, 0, self.root_node.size.y * 0.95)
      resize_child_node(node, "y", y, dy)
    end
    node.divider = common.clamp(node.divider, 0.01, 0.99)
    return
  end

  local dn = self.dragged_node
  if dn and not dn.dragging then
    -- start dragging only after enough movement
    dn.dragging = common.distance(x, y, dn.drag_start_x, dn.drag_start_y) > style.tab_width * .05
    if dn.dragging then
      core.request_cursor("hand")
    end
  end

  -- avoid sending on_touch_moved events when dragging tabs
  if dn then return end

  self.touched_view:on_touch_moved(x, y, dx, dy, ...)
end


---Forward IME composition to the active view unless an open popup captures text.
---@param ... any Composition text, start offset, and selection length
---@return boolean? consumed True when a popup blocks composition beneath it
function RootView:on_ime_text_editing(...)
  for i = #self.floating_views, 1, -1 do
    local view = self.floating_views[i]
    if
      not view.floating_closing and view.floating_options.interactive
      and view.capture_text_input and not view:owns_view(core.active_view)
    then
      return true
    end
  end
  core.active_view:on_ime_text_editing(...)
end


---Cancel capture and hover, then dismiss popups configured for outside-click dismissal.
---Requests a redraw so document cursors disappear while the window is inactive.
---@param ... any Window focus event arguments, unused
function RootView:on_focus_lost(...)
  self:cancel_mouse_capture()
  self:on_mouse_left()
  for _, view in ipairs(self:floating_snapshot()) do
    if view.floating_options.dismiss_on_outside_click then
      view:on_floating_dismiss("focuslost")
    end
  end
  -- We force a redraw so documents can redraw without the cursor.
  core.redraw = true
end


---Animate drag overlay position and opacity smoothly.
---Internal helper for tab/split drag visual feedback.
---@param overlay core.rootview.overlay The overlay to animate
function RootView:interpolate_drag_overlay(overlay)
  self:move_towards(overlay, "x", overlay.to.x, nil, "tab_drag")
  self:move_towards(overlay, "y", overlay.to.y, nil, "tab_drag")
  self:move_towards(overlay, "w", overlay.to.w, nil, "tab_drag")
  self:move_towards(overlay, "h", overlay.to.h, nil, "tab_drag")

  self:move_towards(overlay, "opacity", overlay.visible and 100 or 0, nil, "tab_drag")
  overlay.color[4] = overlay.base_color[4] * overlay.opacity / 100
end


---Update node layout, drag overlays, deferred file drops, and floating views.
---Hides popups with unavailable owners, then places and updates the remaining popups.
function RootView:update()
  Node.copy_position_and_size(self.root_node, self)
  self.root_node:update()
  self.root_node:update_layout()

  self:update_drag_overlay()
  self:interpolate_drag_overlay(self.drag_overlay)
  self:interpolate_drag_overlay(self.drag_overlay_tab)
  self:process_defer_open_docs()
  for _, view in ipairs(self:floating_snapshot()) do
    if view.floating_visible then
      local owner = view.floating_options.owner
      if
        owner and not owner:is_floating_owner_visible()
        and not view.floating_closing
      then
        view:hide_floating()
      else
        view:update_floating()
        if view.floating_visible then
          view:update()
          if not view._core_step_first_update then
            view._core_step_first_update = true
            core.redraw = true
          end
        end
      end
    end
  end
  self.first_update_done = true
end


---Set drag overlay target position and size.
---If immediate is true, jumps to position instantly instead of animating.
---@param overlay core.rootview.overlay The overlay to position
---@param x number Target x coordinate
---@param y number Target y coordinate
---@param w number Target width
---@param h number Target height
---@param immediate boolean? If true, jump to position without animation
function RootView:set_drag_overlay(overlay, x, y, w, h, immediate)
  overlay.to.x = x
  overlay.to.y = y
  overlay.to.w = w
  overlay.to.h = h
  if immediate then
    overlay.x = x
    overlay.y = y
    overlay.w = w
    overlay.h = h
  end
  if not overlay.visible then
    self:set_show_overlay(overlay, true)
  end
end


---Calculate overlay rectangle for a split type.
---Returns modified x, y, w, h for showing where split will occur.
---@param split_type string "left", "right", "up", or "down"
---@param x number Original x coordinate
---@param y number Original y coordinate
---@param w number Original width
---@param h number Original height
---@return number x Modified x coordinate
---@return number y Modified y coordinate
---@return number w Modified width
---@return number h Modified height
local function get_split_sizes(split_type, x, y, w, h)
  if split_type == "left" then
    w = w * .5
  elseif split_type == "right" then
    x = x + w * .5
    w = w * .5
  elseif split_type == "up" then
    h = h * .5
  elseif split_type == "down" then
    y = y + h * .5
    h = h * .5
  end
  return x, y, w, h
end


---Update drag overlay position during tab drag.
---Shows visual feedback for where tab will land (split or reorder).
---Called during update() when dragging tabs.
function RootView:update_drag_overlay()
  if not (self.dragged_node and self.dragged_node.dragging) then return end
  local over = self.root_node:get_child_overlapping_point(self.mouse.x, self.mouse.y)
  if over and not over.locked then
    local _, _, _, tab_h = over:get_scroll_button_rect(1)
    local x, y = over.position.x, over.position.y
    local w, h = over.size.x, over.size.y
    local split_type = over:get_split_type(self.mouse.x, self.mouse.y)

    if split_type == "tab" and (over ~= self.dragged_node.node or #over.views > 1) then
      local tab_index, tab_x, tab_y, tab_w, tab_h = over:get_drag_overlay_tab_position(self.mouse.x, self.mouse.y)
      self:set_drag_overlay(self.drag_overlay_tab,
        tab_x + (tab_index and 0 or tab_w), tab_y,
        style.caret_width, tab_h,
        -- avoid showing tab overlay moving between nodes
        over ~= self.drag_overlay_tab.last_over)
      self:set_show_overlay(self.drag_overlay, false)
      self.drag_overlay_tab.last_over = over
    else
      if (over ~= self.dragged_node.node or #over.views > 1) then
        y = y + tab_h
        h = h - tab_h
        x, y, w, h = get_split_sizes(split_type, x, y, w, h)
      end
      self:set_drag_overlay(self.drag_overlay, x, y, w, h)
      self:set_show_overlay(self.drag_overlay_tab, false)
    end
  else
    self:set_show_overlay(self.drag_overlay, false)
    self:set_show_overlay(self.drag_overlay_tab, false)
  end
end


---Draw the currently dragged tab floating under the cursor.
---Visual feedback during tab drag operations.
function RootView:draw_grabbed_tab()
  local dn = self.dragged_node
  local _,_, w, h = dn.node:get_tab_rect(dn.idx)
  local x = self.mouse.x - w / 2
  local y = self.mouse.y - h / 2
  local view = dn.node.views[dn.idx]
  self.root_node:draw_tab(view, true, true, false, x, y, w, h, true)
end


---Draw a drag overlay rectangle with current opacity.
---Shows where tab/split will land when dropped.
---@param ov core.rootview.overlay The overlay to draw
function RootView:draw_drag_overlay(ov)
  if ov.opacity > 0 then
    renderer.draw_rect(ov.x, ov.y, ov.w, ov.h, ov.color)
  end
end


---Render the entire UI each frame.
---Draw the node tree, deferred content, floating views, and drag overlays.
function RootView:draw()
  self.root_node:draw()
  while #self.deferred_draws > 0 do
    local t = table.remove(self.deferred_draws)
    t.fn(table.unpack(t))
  end

  for _, view in ipairs(self:floating_snapshot()) do
    if view.floating_visible and view._core_step_first_update then
      core.push_clip_rect(
        self.position.x, self.position.y,
        self.size.x, self.size.y
      )
      view:draw()
      while #self.deferred_draws > 0 do
        local draw = table.remove(self.deferred_draws)
        draw.fn(table.unpack(draw))
      end
      core.pop_clip_rect()
    end
  end
  self:draw_drag_overlay(self.drag_overlay)
  self:draw_drag_overlay(self.drag_overlay_tab)
  if self.dragged_node and self.dragged_node.dragging then
    self:draw_grabbed_tab()
  end
  if core.cursor_change_req then
    system.set_cursor(core.cursor_change_req)
    core.cursor_change_req = nil
  end
end

return RootView
