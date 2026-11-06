local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local Object = require "core.object"
local EmptyView = require "core.emptyview"
local View = require "core.view"

---@class core.node.lock
---@field x boolean
---@field y boolean

---@alias core.node.type "leaf" | "hsplit" | "vsplit"
---@alias core.node.dock_side "top" | "right" | "bottom" | "left"

---Cached dock header labels and geometry; menu entries are built only on opening.
---@class core.node.dock_header
---@field labels string[] View titles in registration order
---@field views core.view[] View identities corresponding to the cached titles
---@field widths number[] Natural tab widths in pixels
---@field font renderer.font Measured title font
---@field font_size number Font size at measurement time
---@field scale number Interface scale at measurement time
---@field padding number Horizontal title padding
---@field padding_y number Vertical title padding
---@field width number Available dock width
---@field height number Header height
---@field button number Hide button width
---@field compact boolean Use an active title and selector instead of tabs

---Represents a container in the UI layout tree.
---Nodes can be either "leaf" (contains views/tabs) or split (contains two child nodes).
---The root node forms a binary tree structure that defines the editor's layout.
---@class core.node : core.object
---@overload fun(type?: string, empty?: boolean):core.node
---@field type core.node.type
---@field position core.view.position
---@field size core.view.position
---@field views core.view[]
---@field divider number
---@field active_view core.view
---@field hovered_close integer
---@field hovered_tab integer?
---@field hovered_scroll_button integer
---@field tab_shift number
---@field tab_offset integer
---@field tab_width number
---@field a core.node?
---@field b core.node?
---@field locked core.node.lock?
---@field resizable boolean?
---@field is_primary_node boolean?
---@field move_towards function
---@field dock_side? core.node.dock_side Predefined workspace dock, never a document pane
---@field dock_visible? boolean Requested area visibility
---@field dock_extent? number Initial thickness for views without a requested size, in scale-independent units
---@field dock_limit? number Thickness available in the current layout, in pixels
---@field dock_structure? boolean Preserve this workspace branch during document closure
---@field dock_workspace? boolean Fit dock requests before laying out this workspace branch
---@field dock_header? core.node.dock_header Cached dock labels, widths, and header geometry
---@field dock_menu? core.contextmenu Header selector or movement menu
---@field dock_layouts? table<core.view, core.node> Independent split tree for each registered view
---@field dock_content? boolean Node inside a dock view layout
local Node = Object:extend()

function Node:__tostring() return "Node" end

---Constructor - creates a new node.
---@param type? string Node type: "leaf" (contains views), "hsplit", or "vsplit"
---@param empty? boolean Leave a leaf empty when constructing a managed dock
function Node:new(type, empty)
  self.type = type or "leaf"
  self.position = { x = 0, y = 0 }
  self.size = { x = 0, y = 0 }
  self.views = {}
  self.divider = 0.5
  if self.type == "leaf" and not empty then
    self:add_view(EmptyView())
  end
  self.hovered_close = 0
  self.tab_shift = 0
  self.tab_offset = 1
  self.tab_width = style.tab_width
  self.move_towards = View.move_towards
  self.hovered_scroll_button = 0
end


---Call a method on both child nodes (for split nodes only).
---@param fn string Method name to call on children
---@param ... any Arguments to pass to the method
function Node:propagate(fn, ...)
  self.a[fn](self.a, ...)
  self.b[fn](self.b, ...)
end


---@deprecated
function Node:on_mouse_moved(x, y, ...)
  core.deprecation_log("Node:on_mouse_moved")
  if self.type == "leaf" then
    self.active_view:on_mouse_moved(x, y, ...)
  else
    self:propagate("on_mouse_moved", x, y, ...)
  end
end


---@deprecated
function Node:on_mouse_released(...)
  core.deprecation_log("Node:on_mouse_released")
  if self.type == "leaf" then
    self.active_view:on_mouse_released(...)
  else
    self:propagate("on_mouse_released", ...)
  end
end


---@deprecated
function Node:on_mouse_left()
  core.deprecation_log("Node:on_mouse_left")
  if self.type == "leaf" then
    self.active_view:on_mouse_left()
  else
    self:propagate("on_mouse_left")
  end
end


---@deprecated
function Node:on_touch_moved(...)
  core.deprecation_log("Node:on_touch_moved")
  if self.type == "leaf" then
    self.active_view:on_touch_moved(...)
  else
    self:propagate("on_touch_moved", ...)
  end
end


---Replace this node's contents with another node's contents.
---Transfers all properties from source node to this node.
---Used during split/merge operations to restructure the tree.
---@param node core.node Source node to consume
function Node:consume(node)
  for k, _ in pairs(self) do self[k] = nil end
  for k, v in pairs(node) do self[k] = v   end
end


local type_map = { up="vsplit", down="vsplit", left="hsplit", right="hsplit" }

---Split this leaf node in a direction, creating two child nodes.
---Converts this node from "leaf" to "hsplit" or "vsplit" containing two children.
---The original content stays in one child, new view (if provided) goes in the other.
---On a dock, splits its active registered view's layout instead of the shared area.
---@param dir string Direction to split: "up", "down", "left", or "right"
---@param view? core.view Optional view to add to the new split
---@param locked? table Optional {x=boolean, y=boolean} to lock the new node's size
---@param resizable? boolean If true, locked node can be resized by user (needs set_target_size)
---@return core.node new_node The newly created child node
function Node:split(dir, view, locked, resizable)
  if self.dock_side then
    assert(self.active_view, "Cannot split an empty dock")
    return self.dock_layouts[self.active_view]:get_node_for_view(self.active_view)
      :split(dir, view, locked, resizable)
  end
  local dock_content = self.dock_content
  assert(self.type == "leaf", "Tried to split non-leaf node")
  local node_type = assert(type_map[dir], "Invalid direction")
  local last_active = core.active_view
  local child = Node("leaf", true)
  child:consume(self)
  self:consume(Node(node_type))
  self.a = child
  self.b = Node()
  if dock_content then self.dock_content, self.a.dock_content, self.b.dock_content = true, true, true end
  if view then self.b:add_view(view) end
  if locked then
    assert(type(locked) == 'table')
    self.b.locked = locked
    self.b.resizable = resizable or false
    core.set_active_view(last_active)
  end
  if dir == "up" or dir == "left" then
    self.a, self.b = self.b, self.a
    return self.a
  end
  return self.b
end


---Remove a view from this node.
---If this is the last view, may collapse the node or replace with EmptyView.
---Handles primary node logic and tree restructuring.
---@param root core.node The root node of the tree
---@param view core.view View to remove
function Node:remove_view(root, view)
  local dock = core.root_view:get_dock_for_view(view)
  if dock and dock:get_view_idx(view) then return core.root_view:remove_dock_view(view) end
  if #self.views > 1 then
    local idx = self:get_view_idx(view)
    if idx < self.tab_offset then
      self.tab_offset = self.tab_offset - 1
    end
    table.remove(self.views, idx)
    if self.active_view == view then
      self:set_active_view(self.views[idx] or self.views[#self.views])
    end
  else
    local parent = self:get_parent_node(root)
    local is_a = (parent.a == self)
    local other = parent[is_a and "b" or "a"]
    local locked_size_x, locked_size_y = other:get_locked_size()
    local locked_size
    if parent.type == "hsplit" then
      locked_size = locked_size_x
    else
      locked_size = locked_size_y
    end
    local next_primary
    if self.is_primary_node then
      next_primary = core.root_view:select_next_primary_node()
    end
    if locked_size or (self.is_primary_node and not next_primary) then
      self.views = {}
      self:add_view(EmptyView())
    else
      if other == next_primary then
        next_primary = parent
      end
      parent:consume(other)
      local p = parent
      while p.type ~= "leaf" do
        p = p[is_a and "a" or "b"]
      end
      p:set_active_view(p.active_view)
      if self.is_primary_node then
        next_primary.is_primary_node = true
      end
    end
  end
  core.last_active_view = nil
  core.redraw = true
end


---Close a view with confirmation.
---Calls view:try_close() which may show save dialogs before removing.
---@param root core.node The root node of the tree
---@param view core.view View to close
function Node:close_view(root, view)
  local do_close = function()
    self:remove_view(root, view)
  end
  view:try_close(do_close)
end


---Close the currently active view in this node.
---@param root core.node The root node of the tree
function Node:close_active_view(root)
  self:close_view(root, self.active_view)
end


---Add a view to this leaf node as a new tab.
---Automatically removes EmptyView if present.
---Sets the new view as active.
---@param view core.view View to add
---@param idx? integer Optional position to insert (default: end)
function Node:add_view(view, idx)
  assert(
    not view.floating_visible,
    "Hide the floating view before adding it to a node"
  )
  if view.floating then view:set_floating(false) end
  assert(self.type == "leaf", "Tried to add view to non-leaf node")
  assert(not self.locked, "Use RootView:add_dock_view() for docks and locked panels")
  if self.views[1] and self.views[1]:is(EmptyView) then
    table.remove(self.views)
    if idx and idx > 1 then
      idx = idx - 1
    end
  end
  idx = common.clamp(idx or (#self.views + 1), 1, (#self.views + 1))
  table.insert(self.views, idx, view)
  self:set_active_view(view)
end


---Set the active view in this leaf node.
---Updates global active view and notifies the previously active view.
---@param view core.view View to make active
function Node:set_active_view(view)
  if self.dock_side then return core.root_view:activate_dock_view(view) end
  assert(self.type == "leaf", "Tried to set active view on non-leaf node")
  local last_active_view = self.active_view
  self.active_view = view
  core.set_active_view(view)
  if last_active_view and last_active_view ~= view then
    last_active_view:on_mouse_left()
  end
end


---Get the index of a view in this node's view list.
---@param view core.view View to find
---@return integer? idx Index of the view, or nil if not found
function Node:get_view_idx(view)
  for i, v in ipairs(self.views) do
    if v == view then return i end
  end
end


---Find the node containing a specific view.
---Recursively searches this node and its children.
---@param view core.view View to search for
---@return core.node? node The node containing the view, or nil if not found
function Node:get_node_for_view(view)
  if self.dock_side then
    for _, registered in ipairs(self.views) do
      local node = self.dock_layouts[registered]:get_node_for_view(view)
      if node then return node end
    end
    return
  end
  for _, v in ipairs(self.views) do
    if v == view then return self end
  end
  if self.type ~= "leaf" then
    return self.a:get_node_for_view(view) or self.b:get_node_for_view(view)
  end
end

---Find a leaf containing a view or its container descendant without building a view list.
---@param target core.view Focus target to locate
---@return core.node? node Containing leaf, or nil when absent
function Node:get_node_for_owned_view(target)
  if self.dock_side then
    for _, view in ipairs(self.views) do
      local node = self.dock_layouts[view]:get_node_for_owned_view(target)
      if node then return node end
    end
  else
    for _, view in ipairs(self.views) do
      if view == target or view:owns_view(target) then return self end
    end
    if self.type ~= "leaf" then
      return self.a:get_node_for_owned_view(target) or self.b:get_node_for_owned_view(target)
    end
  end
end


---Find the parent node of this node in the tree.
---@param root core.node Root node to search from
---@return core.node? parent The parent node, or nil if this is root or not found
function Node:get_parent_node(root)
  if root.dock_side then
    for _, view in ipairs(root.views) do
      local layout = root.dock_layouts[view]
      if layout == self then return root end
      local parent = self:get_parent_node(layout)
      if parent then return parent end
    end
    return
  end
  if root.a == self or root.b == self then
    return root
  elseif root.type ~= "leaf" then
    return self:get_parent_node(root.a) or self:get_parent_node(root.b)
  end
end


---Collect all views from this node and its children.
---Recursively gathers views from the entire subtree.
---@param t? table Optional table to append results to
---@return table views List of all views in this subtree
function Node:get_children(t)
  t = t or {}
  if self.dock_side then
    for _, view in ipairs(self.views) do self.dock_layouts[view]:get_children(t) end
    return t
  end
  for _, view in ipairs(self.views) do
    table.insert(t, view)
  end
  if self.a then self.a:get_children(t) end
  if self.b then self.b:get_children(t) end
  return t
end


---Calculate scroll button width and padding.
---@return number width Total button width including padding
---@return number pad Padding amount
local function get_scroll_button_width()
  local w = style.icon_font:get_width(">")
  local pad = w
  return w + 2 * pad, pad
end


---Check if a point overlaps any resizable divider in the tree.
---Recursively searches for dividers that can be dragged.
---Collapsed branches cannot receive divider hits.
---@param px number Screen x coordinate
---@param py number Screen y coordinate
---@return core.node? node The node whose divider is under the point, or nil
function Node:get_divider_overlapping_point(px, py)
  if self.size.x <= 0 or self.size.y <= 0 then return end
  if self.dock_side then
    local layout = self.dock_visible and self.active_view and self.dock_layouts[self.active_view]
    return layout and layout:get_divider_overlapping_point(px, py)
  end
  if self.type ~= "leaf" then
    local axis = self.type == "hsplit" and "x" or "y"
    if self.a:is_resizable(axis) and self.b:is_resizable(axis) then
      local p = 6
      local x, y, w, h = self:get_divider_rect()
      if w > 0 and h > 0 then
        x, y = x - p, y - p
        w, h = w + p * 2, h + p * 2
        if px > x and py > y and px < x + w and py < y + h then
          return self
        end
      end
    end
    return self.a:get_divider_overlapping_point(px, py)
        or self.b:get_divider_overlapping_point(px, py)
  end
end


---Get the number of tabs currently visible (not scrolled out of view).
---@return integer count Number of visible tabs
function Node:get_visible_tabs_number()
  return math.min(#self.views - self.tab_offset + 1, config.max_tabs)
end


---Get the index of the tab under a screen point.
---@param px number Screen x coordinate
---@param py number Screen y coordinate
---@return integer? idx Tab index, or nil if not over any tab
function Node:get_tab_overlapping_point(px, py)
  if self.dock_side then
    local header = self.dock_header
    if not self:should_show_tabs() or not header or header.compact then return end
    if py < self.position.y or py >= self.position.y + header.height then return end
    local x = self.position.x
    for i, width in ipairs(header.widths) do
      if px >= x and px < x + width then return i end
      x = x + width
    end
    return
  end
  if not self:should_show_tabs() then return nil end
  local tabs_number = self:get_visible_tabs_number()
  local x1, y1, w, h = self:get_tab_rect(self.tab_offset)
  local x2, y2 = self:get_tab_rect(self.tab_offset + tabs_number)
  if px >= x1 and py >= y1 and px < x2 and py < y1 + h then
    return math.floor((px - x1) / w) + self.tab_offset
  end
end


---Determine if tabs should be shown for this node.
---Based on config settings, number of views, and drag state.
---@return boolean show True if tabs should be displayed
function Node:should_show_tabs()
  if self.dock_side then return self.dock_visible and #self.views > 1 end
  if self.dock_content then return #self.views > 1 end
  if self.locked then return false end
  local dn = core.root_view.dragged_node
  if config.hide_tabs then
    return false
  elseif #self.views > 1
     or (dn and dn.dragging) then -- show tabs while dragging
    return true
  elseif config.always_show_tabs then
    return not self.views[1]:is(EmptyView)
  end
  return false
end


---Calculate the position of a tab's close button.
---@param x number Tab x position
---@param w number Tab width
---@return number cx Close button x position
---@return number cw Close button width
---@return number pad Padding amount
local function close_button_location(x, w)
  local cw = style.icon_font:get_width("C")
  local pad = style.padding.x / 2
  return x + w - cw - pad, cw, pad
end


---Get which scroll button (left/right) is under a point.
---@param px number Screen x coordinate
---@param py number Screen y coordinate
---@return integer? idx Button index (1=left, 2=right), or nil
function Node:get_scroll_button_index(px, py)
  if self.dock_side then return end
  if #self.views == 1 then return end
  for i = 1, 2 do
    local x, y, w, h = self:get_scroll_button_rect(i)
    if px >= x and px < x + w and py >= y and py < y + h then
      return i
    end
  end
end


---Update hover state for tabs, close buttons, and scroll buttons.
---Sets hovered_tab, hovered_close, and hovered_scroll_button fields.
---@param px number Screen x coordinate
---@param py number Screen y coordinate
function Node:tab_hovered_update(px, py)
  self.hovered_close = 0
  self.hovered_scroll_button = 0
  if not self:should_show_tabs() then self.hovered_tab = nil return end
  local tab_index = self:get_tab_overlapping_point(px, py)
  self.hovered_tab = tab_index
  if self.dock_side then return end
  if tab_index then
    local x, y, w, h = self:get_tab_rect(tab_index)
    local cx, cw = close_button_location(x, w)
    if px >= cx and px < cx + cw and py >= y and py < y + h and config.tab_close_button then
      self.hovered_close = tab_index
    end
  elseif #self.views > self:get_visible_tabs_number() then
    self.hovered_scroll_button = self:get_scroll_button_index(px, py) or 0
  end
end


---Find the deepest leaf node at a screen point.
---Recursively traverses split nodes to find the leaf under the point.
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@return core.node node The leaf node at this point
function Node:get_child_overlapping_point(x, y)
  if (self.dock_side or self.dock_structure or self.dock_content)
    and (self.size.x <= 0 or self.size.y <= 0) then return end
  local child
  if self.type == "leaf" then
    if self.dock_side then
      if not self.active_view or not self.dock_visible then return end
      if self:is_in_tab_area(x, y) then return self end
      return self.dock_layouts[self.active_view]:get_child_overlapping_point(x, y)
    end
    return self
  elseif self.type == "hsplit" then
    child = (x < self.b.position.x) and self.a or self.b
  elseif self.type == "vsplit" then
    child = (y < self.b.position.y) and self.a or self.b
  end
  return child:get_child_overlapping_point(x, y)
end


---Calculate tab bar vertical dimensions.
---@return number height Total tab height
---@return number padding Vertical padding
---@return number margin Top margin
local function get_tab_y_sizes()
  local height = style.font:get_height()
  local padding = style.padding.y
  local margin = style.margin.tab.top
  return height + (padding * 2) + margin, padding, margin
end


---Get the rectangle for a scroll button.
---@param index integer Button index (1=left, 2=right)
---@return number x Screen x coordinate
---@return number y Screen y coordinate
---@return number w Width
---@return number h Height
---@return number pad Padding amount
function Node:get_scroll_button_rect(index)
  local w, pad = get_scroll_button_width()
  local h = get_tab_y_sizes()
  local x = self.position.x + (index == 1 and self.size.x - w * 2 or self.size.x - w)
  return x, self.position.y, w, h, pad
end


---Get the rectangle for a tab.
---@param idx integer Tab index
---@return number x Screen x coordinate
---@return number y Screen y coordinate
---@return number w Width
---@return number h Height
---@return number margin_y Top margin
function Node:get_tab_rect(idx)
  local maxw = self.size.x
  local x0 = self.position.x
  local x1 = x0 + common.clamp(self.tab_width * (idx - 1) - self.tab_shift, 0, maxw)
  local x2 = x0 + common.clamp(self.tab_width * idx - self.tab_shift, 0, maxw)
  local h, pad_y, margin_y = get_tab_y_sizes()
  return x1, self.position.y, x2 - x1, h, margin_y
end


---Get the rectangle for this node's divider (for split nodes).
---Use the allocated gap so collapsed panes do not paint into neighboring nodes.
---@return number? x Screen x coordinate, or nil for leaf nodes
---@return number? y Screen y coordinate, or nil for leaf nodes
---@return number? w Width, or nil for leaf nodes
---@return number? h Height, or nil for leaf nodes
function Node:get_divider_rect()
  local x, y = self.position.x, self.position.y
  if self.type == "hsplit" then
    x = self.a.position.x + self.a.size.x
    return x, y, math.max(0, self.b.position.x - x), self.size.y
  elseif self.type == "vsplit" then
    y = self.a.position.y + self.a.size.y
    return x, y, self.size.x, math.max(0, self.b.position.y - y)
  end
end


---Get the locked size of this node.
---Returns fixed sizes for locked nodes, nil for proportionally-sized nodes.
---For split nodes, combines child locked sizes.
---@return number? sx Locked width, or nil if not locked on x-axis
---@return number? sy Locked height, or nil if not locked on y-axis
function Node:get_locked_size()
  if self.dock_side then
    local axis = self.locked.x and "x" or "y"
    local extent = self.dock_visible and self.active_view
      and (self.dock_limit or self.active_view.dock_size[axis] * SCALE) or 0
    if self.dock_side == "left" or self.dock_side == "right" then return extent end
    return nil, extent
  end
  if self.type == "leaf" then
    if self.locked then
      local size = self.active_view.size
      -- The values below should be either a falsy value or a number
      local sx = (self.locked and self.locked.x) and size.x
      local sy = (self.locked and self.locked.y) and size.y
      return sx, sy
    end
  else
    local x1, y1 = self.a:get_locked_size()
    local x2, y2 = self.b:get_locked_size()
    -- The values below should be either a falsy value or a number
    local sx, sy
    if self.type == 'hsplit' then
      if x1 and x2 then
        local dsx = (x1 < 1 or x2 < 1) and 0 or style.divider_size
        sx = x1 + x2 + dsx
      end
      sy = y1 or y2
    else
      if y1 and y2 then
        local dsy = (y1 < 1 or y2 < 1) and 0 or style.divider_size
        sy = y1 + y2 + dsy
      end
      sx = x1 or x2
    end
    return sx, sy
  end
end

---Find the visible view that would replace a departing registered owner.
---Prefer the next entry, then preceding entries, without revealing hidden views.
---@private
---@param view core.view Departing registered owner
---@return core.view? replacement Next eligible view, or nil when the dock will close
function Node:get_dock_replacement(view)
  local index = self:get_view_idx(view)
  if not index then return end
  local axis = self.locked.x and "x" or "y"
  for i = index + 1, #self.views do
    local candidate = self.views[i]
    self:sync_dock_size(candidate)
    if candidate.visible ~= false and candidate.dock_size[axis] > 0 then return candidate end
  end
  for i = index - 1, 1, -1 do
    local candidate = self.views[i]
    self:sync_dock_size(candidate)
    if candidate.visible ~= false and candidate.dock_size[axis] > 0 then return candidate end
  end
end

---Resolve a dock's current request, keeping a closing handoff within its replacement's size.
---The outgoing view continues its own animation; only the allocated dock thickness is bounded.
---@private
---@return number extent Requested outer thickness in pixels
function Node:get_dock_request()
  local view = self.active_view
  if not view then return 0 end
  self:sync_dock_size(view)
  if not self.dock_visible then return 0 end
  local layout = view.dock_layout
  local replacement = layout.destination == 0 and self:get_dock_replacement(view)
  if replacement and view.size[layout.axis] == 0 then
    core.root_view:activate_dock_view(replacement, false)
    view = replacement
  end
  local visible = not view.is_visible or view:is_visible()
  local extent = visible and view.dock_size[layout.axis] * SCALE or 0
  if replacement then extent = math.max(extent, replacement.dock_size[layout.axis] * SCALE) end
  return extent
end

---Remember explicit or animated size changes without mistaking layout constraints for requests.
---@private
---@param view core.view Registered owner whose size may have changed since layout
function Node:sync_dock_size(view)
  local layout = view.dock_layout
  if not layout then return end
  local size = view.size[layout.axis]
  if size ~= layout.size then
    local _, _, width, height = view:get_floating_bounds()
    local outer_size = layout.axis == "x" and width or height
    local extent = math.max(0, layout.extent + outer_size - layout.outer_size)
    view.dock_size[layout.axis] = extent / SCALE
    layout.size, layout.outer_size, layout.extent = size, outer_size, extent
  end
end


---Copy position and size from one node to another.
---@param dst core.node Destination node
---@param src core.node Source node
function Node.copy_position_and_size(dst, src)
  dst.position.x, dst.position.y = src.position.x, src.position.y
  dst.size.x, dst.size.y = src.size.x, src.size.y
end


---Calculate child node sizes for a split.
---Handles both hsplit and vsplit by swapping x/y axes.
---Keep the divider and both children within the available extent.
---@param self core.node The split node
---@param x string Axis being split ("x" or "y")
---@param y string Perpendicular axis ("y" or "x")
---@param x1 number? Locked size of first child on split axis
---@param x2 number? Locked size of second child on split axis
---@param y1? number Locked size of first child on perpendicular axis (unused)
---@param y2? number Locked size of second child on perpendicular axis (unused)
local function calc_split_sizes(self, x, y, x1, x2, y1, y2)
  local ds = ((x1 and x1 < 1) or (x2 and x2 < 1)) and 0 or style.divider_size
  ds = math.min(ds, self.size[x])
  local n = x1 and x1 + ds or (x2 and self.size[x] - x2 or math.floor(self.size[x] * self.divider))
  n = common.clamp(n, ds, self.size[x])
  self.a.position[x] = self.position[x]
  self.a.position[y] = self.position[y]
  self.a.size[x] = n - ds
  self.a.size[y] = self.size[y]
  self.b.position[x] = self.position[x] + n
  self.b.position[y] = self.position[y]
  self.b.size[x] = self.size[x] - n
  self.b.size[y] = self.size[y]
end


---Update position and size of this node and its children.
---Recursively calculates layout for the entire subtree.
---Accounts for tabs, locked sizes, and divider positions.
function Node:update_layout()
  if self.dock_workspace then core.root_view:fit_docks(self.size.x, self.size.y) end
  if self.type == "leaf" then
    local av = self.active_view
    if self.dock_side then
      self:update_dock_header()
      if not av or not self.dock_visible then return end
      if self.size[self.locked.x and "x" or "y"] <= 0 then return end
      local header = self:should_show_tabs() and self.dock_header.height or 0
      local layout = self.dock_layouts[av]
      layout.position.x, layout.position.y = self.position.x, self.position.y + header
      layout.size.x, layout.size.y = self.size.x, math.max(0, self.size.y - header)
      layout:update_layout()
      local _, _, width, height = av:get_floating_bounds()
      av.dock_layout.size = av.size[av.dock_layout.axis]
      av.dock_layout.outer_size = av.dock_layout.axis == "x" and width or height
      av.dock_layout.extent = self.size[av.dock_layout.axis]
      return
    end
    if not av then return end
    if self.dock_content then
      local header = self:should_show_tabs() and select(4, self:get_tab_rect(1)) or 0
      local x, y, w, h = self.position.x, self.position.y + header,
        self.size.x, math.max(0, self.size.y - header)
      local bx, by, bw, bh = av:get_floating_bounds()
      if x ~= bx or y ~= by or w ~= bw or h ~= bh then av:set_floating_bounds(x, y, w, h) end
    elseif self:should_show_tabs() then
      local _, _, _, th = self:get_tab_rect(1)
      th = math.min(th, self.size.y)
      av.position.x, av.position.y = self.position.x, self.position.y + th
      av.size.x, av.size.y = self.size.x, self.size.y - th
    else
      Node.copy_position_and_size(av, self)
    end
  else
    local x1, y1 = self.a:get_locked_size()
    local x2, y2 = self.b:get_locked_size()
    if self.type == "hsplit" then
      calc_split_sizes(self, "x", "y", x1, x2)
    elseif self.type == "vsplit" then
      calc_split_sizes(self, "y", "x", y1, y2)
    end
    self.a:update_layout()
    self.b:update_layout()
  end
end


---Ensure the active view's tab is visible (not scrolled out of view).
---Adjusts tab_offset if needed to bring active tab into view.
function Node:scroll_tabs_to_visible()
  local index = self:get_view_idx(self.active_view)
  if index then
    local tabs_number = self:get_visible_tabs_number()
    if self.tab_offset > index then
      self.tab_offset = index
    elseif self.tab_offset + tabs_number - 1 < index then
      self.tab_offset = index - tabs_number + 1
    elseif tabs_number < config.max_tabs and self.tab_offset > 1 then
      self.tab_offset = #self.views - config.max_tabs + 1
    end
  end
end


---Scroll the tab bar left or right.
---Used when clicking scroll buttons.
---@param dir integer Direction: 1=left, 2=right
function Node:scroll_tabs(dir)
  local view_index = self:get_view_idx(self.active_view)
  if dir == 1 then
    if self.tab_offset > 1 then
      self.tab_offset = self.tab_offset - 1
      local last_index = self.tab_offset + self:get_visible_tabs_number() - 1
      if view_index > last_index then
        self:set_active_view(self.views[last_index])
      end
    end
  elseif dir == 2 then
    local tabs_number = self:get_visible_tabs_number()
    if self.tab_offset + tabs_number - 1 < #self.views then
      self.tab_offset = self.tab_offset + 1
      local view_index = self:get_view_idx(self.active_view)
      if view_index < self.tab_offset then
        self:set_active_view(self.views[self.tab_offset])
      end
    end
  end
end


---Calculate the target width for tabs.
---Adjusts based on number of visible tabs and available space.
---@return number width Target tab width in pixels
function Node:target_tab_width()
  local n = self:get_visible_tabs_number()
  local w = self.size.x
  if #self.views > n then
    w = self.size.x - get_scroll_button_width() * 2
  end
  return common.clamp(style.tab_width, w / config.max_tabs, w / n)
end


---Update this node and its children.
---For leaf nodes: updates active view, tab hover state, and tab animations.
---For split nodes: recursively updates both children.
function Node:update()
  if self.type == "leaf" then
    if self.dock_side then
      if not self.dock_visible or not self.active_view then return end
      -- Only an animation run during this update may constrain a closing handoff.
      self.active_view.dock_layout.destination = nil
      self.dock_layouts[self.active_view]:update()
      self:tab_hovered_update(core.root_view.mouse.x, core.root_view.mouse.y)
      return
    end
    self:scroll_tabs_to_visible()
    local view = self.active_view
    view:update()
    if not view._core_step_first_update then
      view._core_step_first_update = true
      core.redraw = true
    end
    self:tab_hovered_update(core.root_view.mouse.x, core.root_view.mouse.y)
    local tab_width = self:target_tab_width()
    self:move_towards("tab_shift", tab_width * (self.tab_offset - 1), nil, "tabs")
    self:move_towards("tab_width", tab_width, nil, "tabs")
  else
    self.a:update()
    self.b:update()
  end
end


---Draw a tab's title text with ellipsis if needed.
---@param view core.view View whose name to display
---@param font renderer.font Font to use
---@param is_active boolean Whether this is the active tab
---@param is_hovered boolean Whether mouse is over this tab
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param w number Width
---@param h number Height
function Node:draw_tab_title(view, font, is_active, is_hovered, x, y, w, h)
  local text = view and view:get_name() or ""
  local dots_width = font:get_width("…")
  local align = "center"
  if font:get_width(text) > w then
    align = "left"
    local text_len = text:ulen()
    for i = 1, text_len do
      local reduced_text = text:usub(1, text_len - i)
      if font:get_width(reduced_text) + dots_width <= w then
        text = reduced_text .. "…"
        break
      end
    end
  end
  local color = style.dim
  if is_active then color = style.text end
  if is_hovered then color = style.text end
  common.draw_text(font, color, text, align, x, y, w, h)
end


---Draw tab borders and background.
---@param view core.view View for this tab
---@param is_active boolean Whether this is the active tab
---@param is_hovered boolean Whether mouse is over this tab
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param w number Width
---@param h number Height
---@param standalone boolean If true, draw standalone tab (during drag)
---@return number x Adjusted x for content area
---@return number y Adjusted y for content area
---@return number w Adjusted width for content area
---@return number h Adjusted height for content area
function Node:draw_tab_borders(view, is_active, is_hovered, x, y, w, h, standalone)
  -- Tabs deviders
  local ds = style.divider_size
  local color = style.dim
  local padding_y = style.padding.y
  renderer.draw_rect(x + w, y + padding_y, ds, h - padding_y*2, style.dim)
  if standalone then
    renderer.draw_rect(x-1, y-1, w+2, h+2, style.background2)
  end
  -- Full border
  if is_active then
    color = style.text
    renderer.draw_rect(x, y, w, h, style.background)
    renderer.draw_rect(x, y, w, ds, style.divider)
    renderer.draw_rect(x + w, y, ds, h, style.divider)
    renderer.draw_rect(x - ds, y, ds, h, style.divider)
  end
  return x + ds, y, w - ds*2, h
end


---Draw a complete tab (borders, title, close button).
---@param view core.view View for this tab
---@param is_active boolean Whether this is the active tab
---@param is_hovered boolean Whether mouse is over this tab
---@param is_close_hovered boolean Whether mouse is over close button
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param w number Width
---@param h number Height
---@param standalone boolean If true, draw standalone tab (during drag)
function Node:draw_tab(view, is_active, is_hovered, is_close_hovered, x, y, w, h, standalone)
  local _, padding_y, margin_y = get_tab_y_sizes()
  x, y, w, h = self:draw_tab_borders(view, is_active, is_hovered, x, y + margin_y, w, h - margin_y, standalone)
  -- Close button
  local cx, cw, cpad = close_button_location(x, w)
  local show_close_button = ((is_active or is_hovered) and not standalone and config.tab_close_button)
  if show_close_button then
    local close_style = is_close_hovered and style.text or style.dim
    common.draw_text(style.icon_font, close_style, "C", nil, cx, y, cw, h)
  end
  -- Title
  x = x + cpad
  w = cx - x
  core.push_clip_rect(x, y, w, h)
  self:draw_tab_title(view, style.font, is_active, is_hovered, x, y, w, h)
  core.pop_clip_rect()
end


---Draw the entire tab bar including all visible tabs and scroll buttons.
function Node:draw_tabs()
  local _, y, w, h, scroll_padding = self:get_scroll_button_rect(1)
  local x = self.position.x
  local ds = style.divider_size
  local dots_width = style.font:get_width("…")
  core.push_clip_rect(x, y, self.size.x, h)
  renderer.draw_rect(x, y, self.size.x, h, style.background2)
  renderer.draw_rect(x, y + h - ds, self.size.x, ds, style.divider)
  local tabs_number = self:get_visible_tabs_number()

  for i = self.tab_offset, self.tab_offset + tabs_number - 1 do
    local view = self.views[i]
    local x, y, w, h = self:get_tab_rect(i)
    self:draw_tab(view, view == self.active_view,
                  i == self.hovered_tab, i == self.hovered_close,
                  x, y, w, h)
  end

  if #self.views > tabs_number then
    local _, pad = get_scroll_button_width()
    local xrb, yrb, wrb, hrb = self:get_scroll_button_rect(1)
    renderer.draw_rect(xrb + pad, yrb, wrb * 2, hrb, style.background2)
    local left_button_style = (self.hovered_scroll_button == 1 and self.tab_offset > 1) and style.text or style.dim
    common.draw_text(style.icon_font, left_button_style, "<", nil, xrb + scroll_padding, yrb, 0, h)

    xrb, yrb, wrb = self:get_scroll_button_rect(2)
    local right_button_style = (self.hovered_scroll_button == 2 and #self.views > self.tab_offset + tabs_number - 1) and style.text or style.dim
    common.draw_text(style.icon_font, right_button_style, ">", nil, xrb + scroll_padding, yrb, 0, h)
  end

  core.pop_clip_rect()
end


---Draw this node and its children.
---For leaf nodes: draws tabs (if shown) and active view.
---For split nodes: draws divider and recursively draws children.
---Skip collapsed branches, including their nested dividers.
function Node:draw()
  if self.size.x <= 0 or self.size.y <= 0 then return end
  if self.type == "leaf" then
    if self.dock_side and (not self.dock_visible or not self.active_view) then return end
    if self:should_show_tabs() then
      if self.dock_side then self:draw_dock_header() else self:draw_tabs() end
    end
    if self.dock_side then
      self.dock_layouts[self.active_view]:draw()
      return
    end
    local view = self.active_view
    local pos, size = view.position, view.size
    if view._core_step_first_update and size.x > 0 and size.y > 0 then
      if self.dock_content then core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
      else core.push_clip_rect(pos.x, pos.y, size.x, size.y) end
      view:draw()
      core.pop_clip_rect()
    end
  else
    local x, y, w, h = self:get_divider_rect()
    renderer.draw_rect(x, y, w, h, style.divider)
    self:propagate("draw")
  end
end


---Check if this node is empty (no views or only EmptyView).
---@return boolean empty True if node contains no real content
function Node:is_empty()
  if self.type == "leaf" then
    return #self.views == 0 or (#self.views == 1 and self.views[1]:is(EmptyView))
  else
    return self.a:is_empty() and self.b:is_empty()
  end
end


---Check if a point is in the tab bar area.
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@return boolean in_tabs True if point is over the tab bar
function Node:is_in_tab_area(x, y)
  if self.dock_side then
    return self:should_show_tabs() and self.dock_header
      and x >= self.position.x and x < self.position.x + self.size.x
      and y >= self.position.y and y < self.position.y + self.dock_header.height
  end
  if not self:should_show_tabs() then return false end
  local _, ty, _, th = self:get_scroll_button_rect(1)
  return y >= ty and y < ty + th
end


---Close all document views (views with context="session").
---Used when closing a project. May collapse empty nodes.
---@param keep_active boolean If true, keep the active view open
function Node:close_all_docviews(keep_active)
  if self.dock_side then
    for i = #self.views, 1, -1 do
      local view = self.views[i]
      if view.context == "session" and (not keep_active or not view:owns_view(core.active_view)) then
        core.root_view:remove_dock_view(view)
      elseif view.context ~= "session" then
        self.dock_layouts[view]:close_all_docviews(keep_active)
      end
    end
    return
  end
  local node_active_view = self.active_view
  local lost_active_view = false
  if self.type == "leaf" then
    local i = 1
    while i <= #self.views do
      local view = self.views[i]
      if view.context == "session" and (not keep_active or view ~= self.active_view) then
        table.remove(self.views, i)
        if view == node_active_view then
          lost_active_view = true
        end
      else
        i = i + 1
      end
    end
    self.tab_offset = 1
    if #self.views == 0 and self.is_primary_node then
      -- if we are not the primary view and we had the active view it doesn't
      -- matter to reattribute the active view because, within the close_all_docviews
      -- top call, the primary node will take the active view anyway.
      -- Set the empty view and takes the active view.
      self:add_view(EmptyView())
    elseif #self.views > 0 and lost_active_view then
      -- In practice we never get there but if a view remain we need
      -- to reset the Node's active view.
      self:set_active_view(self.views[1])
    end
  else
    self.a:close_all_docviews(keep_active)
    self.b:close_all_docviews(keep_active)
    if self.a:is_empty() and not self.a.is_primary_node and not self.dock_structure then
      self:consume(self.b)
    elseif self.b:is_empty() and not self.b.is_primary_node and not self.dock_structure then
      self:consume(self.a)
    end
  end
end


---Check if this node can be resized along an axis.
---Returns true for proportional nodes or locked resizable nodes.
---@param axis string Axis to check: "x" or "y"
---@return boolean resizable True if node accepts resize on this axis
function Node:is_resizable(axis)
  if self.type == 'leaf' then
    return not self.locked or not self.locked[axis] or self.resizable
  else
    local a_resizable = self.a:is_resizable(axis)
    local b_resizable = self.b:is_resizable(axis)
    return a_resizable and b_resizable
  end
end


---Check if this is a locked node that can be resized by the user.
---@param axis string Axis to check: "x" or "y"
---@return boolean resizable True if locked and resizable on this axis
function Node:is_locked_resizable(axis)
  return self.locked and self.locked[axis] and self.resizable
end


---Resize this node to a target size.
---For locked nodes, calls view:set_target_size().
---For proportional nodes, adjusts divider position.
---@param axis string Axis to resize: "x" or "y"
---@param value number Target size in pixels
function Node:resize(axis, value)
  -- the application works fine with non-integer values but to have pixel-perfect
  -- placements of view elements, like the scrollbar, we round the value to be
  -- an integer.
  value = math.floor(value)
  if self.dock_side then
    if self.locked[axis] then
      core.root_view:set_dock_size(self.dock_side, math.max(1, value))
      return true
    end
    return
  end
  if self.type == 'leaf' then
    -- If it is not locked we don't accept the
    -- resize operation here because for proportional panes the resize is
    -- done using the "divider" value of the parent node.
    if self:is_locked_resizable(axis) then
      return self.active_view:set_target_size(axis, value)
    end
  else
    if self.type == (axis == "x" and "hsplit" or "vsplit") then
      -- we are resizing a node that is splitted along the resize axis
      if self.a:is_locked_resizable(axis) and self.b:is_locked_resizable(axis) then
        local rem_value = value - self.a.size[axis]
        if rem_value >= 0 then
          if self.b.active_view.size[axis] <= 0 then
            -- if 'b' not visible resize 'a' instead
            return self.a.active_view:set_target_size(axis, value)
          end
          return self.b.active_view:set_target_size(axis, rem_value)
        else
          self.b.active_view:set_target_size(axis, 0)
          return self.a.active_view:set_target_size(axis, value)
        end
      end
    else
      -- we are resizing a node that is splitted along the axis perpendicular
      -- to the resize axis
      local a_resizable = self.a:is_resizable(axis)
      local b_resizable = self.b:is_resizable(axis)
      if a_resizable and b_resizable then
        self.a:resize(axis, value)
        self.b:resize(axis, value)
      end
    end
  end
end


---Determine where a point falls for drag-to-split operations.
---Divides the node into regions: tab, left, right, up, down, middle.
---@param mouse_x number Screen x coordinate
---@param mouse_y number Screen y coordinate
---@return string split_type One of: "tab", "left", "right", "up", "down", "middle"
function Node:get_split_type(mouse_x, mouse_y)
  local x, y = self.position.x, self.position.y
  local w, h = self.size.x, self.size.y
  local _, _, _, tab_h = self:get_scroll_button_rect(1)
  y = y + tab_h
  h = h - tab_h

  local local_mouse_x = mouse_x - x
  local local_mouse_y = mouse_y - y

  if local_mouse_y < 0 then
    return "tab"
  else
    local left_pct = local_mouse_x * 100 / w
    local top_pct = local_mouse_y * 100 / h
    if left_pct <= 30 then
      return "left"
    elseif left_pct >= 70 then
      return "right"
    elseif top_pct <= 30 then
      return "up"
    elseif top_pct >= 70 then
      return "down"
    end
    return "middle"
  end
end


---Calculate where a dragged tab would be inserted.
---Returns the tab index and overlay position for visual feedback.
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param dragged_node core.node Node being dragged from
---@param dragged_index integer Index of tab being dragged
---@return integer tab_index Index where tab would be inserted
---@return number tab_x Overlay x position
---@return number tab_y Overlay y position
---@return number tab_w Overlay width
---@return number tab_h Overlay height
function Node:get_drag_overlay_tab_position(x, y, dragged_node, dragged_index)
  local tab_index = self:get_tab_overlapping_point(x, y)
  if not tab_index then
    local first_tab_x = self:get_tab_rect(1)
    if x < first_tab_x then
      -- mouse before first visible tab
      tab_index = self.tab_offset or 1
    else
      -- mouse after last visible tab
      tab_index = self:get_visible_tabs_number() + (self.tab_offset - 1 or 0)
    end
  end
  local tab_x, tab_y, tab_w, tab_h, margin_y = self:get_tab_rect(tab_index)
  if x > tab_x + tab_w / 2 and tab_index <= #self.views then
    -- use next tab
    tab_x = tab_x + tab_w
    tab_index = tab_index + 1
  end
  if self == dragged_node and dragged_index and tab_index > dragged_index then
    -- the tab we are moving is counted in tab_index
    tab_index = tab_index - 1
    tab_x = tab_x - tab_w
  end
  return tab_index, tab_x, tab_y + margin_y, tab_w, tab_h - margin_y
end

---Refresh dock title measurements only when labels, font metrics, or width change.
---Opening menus uses a snapshot; this cache never evaluates command predicates.
function Node:update_dock_header()
  if not self.dock_side then return end
  local header = self.dock_header or { labels = {}, widths = {}, views = {} }
  local changed = header.font ~= style.font or header.font_size ~= style.font:get_size()
    or header.scale ~= SCALE or header.padding ~= style.padding.x
    or header.padding_y ~= style.padding.y
    or #header.labels ~= #self.views or header.width ~= self.size.x
  for i, view in ipairs(self.views) do
    local label = view:get_name() or "View"
    if header.labels[i] ~= label or header.views[i] ~= view then changed = true end
    header.labels[i], header.views[i] = label, view
  end
  for i = #header.labels, #self.views + 1, -1 do header.labels[i], header.views[i] = nil, nil end
  if changed then
    header.font, header.font_size = style.font, style.font:get_size()
    header.scale, header.padding, header.width = SCALE, style.padding.x, self.size.x
    header.padding_y = style.padding.y
    header.height = style.font:get_height() + style.padding.y * 2
    header.button = header.height
    header.widths = {}
    local total = 0
    for i, label in ipairs(header.labels) do
      local width = style.font:get_width(label) + style.padding.x * 2
      header.widths[i], total = width, total + width
    end
    header.compact = total > math.max(0, self.size.x - header.button)
    if self.dock_menu then self.dock_menu:hide() end
    core.redraw = true
  end
  self.dock_header = header
end

---Open a snapshot of the dock's view selector or movement actions.
---@param movement? boolean Show placement actions instead of registered views
function Node:show_dock_menu(movement)
  local ContextMenu = require "core.contextmenu"
  if not self.dock_menu then self.dock_menu = ContextMenu() end
  local root, items, active = core.root_view, {}, self.active_view
  if not active then return end
  if movement then
    local positions = {}
    for _, side in ipairs { "top", "right", "bottom", "left" } do
      local target = side
      positions[#positions + 1] = {
        text = side:gsub("^%l", string.upper), checked = side == self.dock_side,
        command = function() root:move_dock_view(active, target) end
      }
    end
    items = {
      { text = "Move Active View", items = positions },
      { text = "Hide Dock", command = function() root:set_dock_visible(self.dock_side, false) end }
    }
  else
    for i, view in ipairs(self.views) do
      local target = view
      items[#items + 1] = {
        text = self.dock_header.labels[i], checked = view == active,
        command = function() root:activate_dock_view(target) end
      }
    end
  end
  self.dock_menu:show_items(items, self.position.x, self.position.y + self.dock_header.height, {
    owner = active, disabled = true
  })
end

---Consume header clicks without forwarding them to the view or tab dragging.
---@param button core.view.mousebutton Pressed mouse button
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@return boolean handled Whether the point belongs to this dock's header
function Node:on_dock_header_pressed(button, x, y)
  if not self:is_in_tab_area(x, y) then return false end
  if button == "right" then
    self:show_dock_menu(true)
  elseif button == "left" then
    if x >= self.position.x + self.size.x - self.dock_header.button then
      core.root_view:set_dock_visible(self.dock_side, false)
    elseif self.dock_header.compact then
      self:show_dock_menu()
    else
      local idx = self:get_tab_overlapping_point(x, y)
      if idx then core.root_view:activate_dock_view(self.views[idx]) end
    end
  end
  return true
end

---Draw title tabs or a compact selector, with one button to hide the area.
function Node:draw_dock_header()
  local header, x, y = self.dock_header, self.position.x, self.position.y
  local width, height = self.size.x, self.dock_header.height
  core.push_clip_rect(x, y, width, math.min(height, self.size.y))
  renderer.draw_rect(x, y, width, height, style.background2)
  renderer.draw_rect(x, y + height - style.divider_size, width, style.divider_size, style.divider)
  local content_width = math.max(0, width - header.button)
  core.push_clip_rect(x, y, content_width, height)
  if header.compact then
    local label = header.labels[self:get_view_idx(self.active_view)] or ""
    core.push_clip_rect(x, y, math.max(0, content_width - header.button), height)
    common.draw_text(style.font, style.text, label, nil,
      x + style.padding.x, y, math.max(0, content_width - header.button - style.padding.x), height)
    core.pop_clip_rect()
    renderer.draw_poly({
      { x + content_width - header.button * .7, y + height * .45 },
      { x + content_width - header.button * .3, y + height * .45 },
      { x + content_width - header.button * .5, y + height * .65 }
    }, style.text)
  else
    for i, tab_width in ipairs(header.widths) do
      if self.views[i] == self.active_view then
        renderer.draw_rect(x, y, tab_width, height, style.background)
      end
      common.draw_text(style.font, (self.views[i] == self.active_view or i == self.hovered_tab)
        and style.text or style.dim, header.labels[i], nil,
        x + style.padding.x, y, tab_width - style.padding.x * 2, height)
      x = x + tab_width
    end
  end
  core.pop_clip_rect()
  common.draw_text(style.icon_font, style.dim, "C", "center",
    self.position.x + content_width, y, header.button, height)
  core.pop_clip_rect()
end

return Node
