local core = require "core"
local common = require "core.common"
local style = require "core.style"
local Node = require "core.node"
local View = require "core.view"
local DocView = require "core.docview"

---Top-level view managing the entire UI layout.
---Coordinates the node tree, handles drag & drop, routes events to child views.
---@class core.rootview : core.view
---@field super core.view
---@field root_node core.node
---@field mouse core.view.position
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
---@return core.node Node containing active view or primary node
function RootView:get_active_node()
  local node = self.root_node:get_node_for_view(core.active_view)
  if not node then node = self:get_primary_node() end
  return node
end


---@return core.node
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
---@return core.node Unlocked node suitable for adding views
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
---@return core.node The primary node
function RootView:get_primary_node()
  return get_primary_node(self.root_node)
end


---@param node core.node
---@return core.node
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
---@return core.node Next available unlocked node to be primary
function RootView:select_next_primary_node()
  return select_next_primary_node(self.root_node)
end


---Open a document in the active node.
---If document is already open, switches to that view instead.
---Creates a new DocView and adds it as a tab in the active node.
---@param doc core.doc Document to open
---@return core.docview The view displaying the document
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


---Close all document views in the node tree.
---Used when closing a project or switching workspaces.
---@param keep_active boolean If true, keeps the currently active view open
function RootView:close_all_docviews(keep_active)
  self.root_node:close_all_docviews(keep_active)
end


---Capture mouse input for a specific view.
---All mouse events for the specified button will be routed to this view,
---even when the mouse moves outside the view's bounds.
---Only one grab can be active per button at a time.
---Common use: drag operations, scrollbar dragging, text selection.
---@param button core.view.mousebutton Button to grab ("left" or "right")
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
---@return boolean True if event was handled
function RootView:on_mouse_pressed(button, x, y, clicks)
  -- If there is a grab, release it first
  if self.grab then
    self:on_mouse_released(self.grab.button, x, y)
  end
  local div = self.root_node:get_divider_overlapping_point(x, y)
  local node = self.root_node:get_child_overlapping_point(x, y)
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
    core.set_active_view(node.active_view)
    self:grab_mouse(button, node.active_view)
    return self.on_view_mouse_pressed(button, x, y, clicks) or node.active_view:on_mouse_pressed(button, x, y, clicks)
  end
end


---Get the base color for a drag overlay.
---Internal helper to fetch color from style based on overlay type.
function RootView:get_overlay_base_color(overlay)
  if overlay == self.drag_overlay then
    return style.drag_overlay
  else
    return style.drag_overlay_tab
  end
end


---Show or hide a drag overlay with color reset.
---Internal helper for managing drag visual feedback state.
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
  if self.grab then
    if self.grab.button == button then
      local grabbed_view = self.grab.view
      grabbed_view:on_mouse_released(button, x, y, ...)
      self:ungrab_mouse(button)

      -- If the mouse was released over a different view, send it the mouse position
      local hovered_view = self.root_node:get_child_overlapping_point(x, y)
      if grabbed_view ~= hovered_view then
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
            local tab_index = node:get_drag_overlay_tab_position(self.mouse.x, self.mouse.y, dragged_node, self.dragged_node.idx)
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
    self.grab.view:on_mouse_moved(x, y, dx, dy)
    core.request_cursor(self.grab.view.cursor)
    return
  end

  if core.active_view == core.nag_view then
    core.request_cursor("arrow")
    core.active_view:on_mouse_moved(x, y, dx, dy)
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
  if self.overlapping_view then
    self.overlapping_view:on_mouse_left()
  end
end


---Handle file/folder drop events from OS.
---Supports: opening files, adding projects, showing dialogs.
---Files are deferred if nagview is visible to avoid locked node errors.
---@param filename string Absolute path to dropped file/folder
---@param x number Screen x where dropped
---@param y number Screen y where dropped
---@return boolean True if event was handled
function RootView:on_file_dropped(filename, x, y)
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
    local ok, doc = core.try(core.open_doc, filename)
    if ok then
      local node = core.root_view.root_node:get_child_overlapping_point(x, y)
      node:set_active_view(node.active_view)
      core.root_view:open_doc(doc)
    end
  end
  self.defer_open_docs = {}
end


---Forward mouse wheel events to the view under the mouse.
function RootView:on_mouse_wheel(...)
  local x, y = self.mouse.x, self.mouse.y
  local node = self.root_node:get_child_overlapping_point(x, y)
  return node.active_view:on_mouse_wheel(...)
end


---Forward text input events to the currently active view.
function RootView:on_text_input(...)
  core.active_view:on_text_input(...)
end

---Handle touch press events (touchscreen/trackpad).
---Tracks which view is being touched for subsequent touch events.
function RootView:on_touch_pressed(x, y, ...)
  local touched_node = self.root_node:get_child_overlapping_point(x, y)
  self.touched_view = touched_node and touched_node.active_view
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

---Forward IME text editing events to the active view.
---Called during IME composition for text input.
function RootView:on_ime_text_editing(...)
  core.active_view:on_ime_text_editing(...)
end

---Handle window focus lost events.
---Forces redraw so cursors can be hidden when window is inactive.
function RootView:on_focus_lost(...)
  -- We force a redraw so documents can redraw without the cursor.
  core.redraw = true
end


---Animate drag overlay position and opacity smoothly.
---Internal helper for tab/split drag visual feedback.
function RootView:interpolate_drag_overlay(overlay)
  self:move_towards(overlay, "x", overlay.to.x, nil, "tab_drag")
  self:move_towards(overlay, "y", overlay.to.y, nil, "tab_drag")
  self:move_towards(overlay, "w", overlay.to.w, nil, "tab_drag")
  self:move_towards(overlay, "h", overlay.to.h, nil, "tab_drag")

  self:move_towards(overlay, "opacity", overlay.visible and 100 or 0, nil, "tab_drag")
  overlay.color[4] = overlay.base_color[4] * overlay.opacity / 100
end


---Update the entire UI tree each frame.
---Manages: node layout, drag overlays, deferred file drops.
---Called automatically by core every frame.
function RootView:update()
  Node.copy_position_and_size(self.root_node, self)
  self.root_node:update()
  self.root_node:update_layout()

  self:update_drag_overlay()
  self:interpolate_drag_overlay(self.drag_overlay)
  self:interpolate_drag_overlay(self.drag_overlay_tab)
  self:process_defer_open_docs()
  self.first_update_done = true
end


---Set drag overlay target position and size.
---If immediate is true, jumps to position instantly instead of animating.
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
function RootView:draw_drag_overlay(ov)
  if ov.opacity > 0 then
    renderer.draw_rect(ov.x, ov.y, ov.w, ov.h, ov.color)
  end
end


---Render the entire UI each frame.
---Draw order: 1) node tree, 2) deferred draws, 3) drag overlays, 4) cursor update
function RootView:draw()
  self.root_node:draw()
  while #self.deferred_draws > 0 do
    local t = table.remove(self.deferred_draws)
    t.fn(table.unpack(t))
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
