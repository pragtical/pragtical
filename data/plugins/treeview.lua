-- mod-version:3
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local Node = require "core.node"
local ContextMenu = require "core.contextmenu"
local RootView = require "core.rootview"
local CommandView = require "core.commandview"
local DocView = require "core.docview"
local ImageView = require "core.imageview"
local MarkdownView = require "core.markdownview"
local DirWatch = require "core.dirwatch"

---Configuration options for `treeview` plugin.
---@class config.plugins.treeview
---Default treeview width.
---@field size number
---Placement of the treeview toolbar; defaults to right at the editor's far-right edge.
---@field toolbar_position "left"|"bottom"|"top"|"right"
---Selects the file you are editing on the treeview.
---@field highlight_focused_file boolean
---Automatically expands directories to select focused file.
---@field expand_dirs_to_focused_file boolean
---Automatically scrolls the treeview to focused file.
---@field scroll_to_focused_file boolean
---Smoothly scroll to focused file.
---@field animate_scroll_to_focused_file boolean
---Show hidden files and directories.
---@field show_hidden boolean
---Show ignored files and directories.
---@field show_ignored boolean
config.plugins.treeview = common.merge({
  -- Default treeview width
  size = 200 * SCALE,
  toolbar_position = "left",
  highlight_focused_file = true,
  expand_dirs_to_focused_file = false,
  scroll_to_focused_file = false,
  animate_scroll_to_focused_file = true,
  show_hidden = false,
  show_ignored = false
}, config.plugins.treeview)

local tooltip_offset = style.font:get_height()
local tooltip_border = 1
local tooltip_delay = 0.5
local tooltip_alpha = 255
local tooltip_alpha_rate = 1


local function get_depth(filename)
  if filename == "" then return 0 end
  local n = 1
  for sep in filename:gmatch("\\*" .. PATHSEP) do
    if #sep % 2 == 1 then
      n = n + 1
    end
  end
  return n
end


local function replace_alpha(color, alpha)
  local r, g, b = table.unpack(color)
  return { r, g, b, alpha }
end

---File or directory cached by TreeView and retained as a context-command target.
---@class plugins.treeview.item
---@field filename string File or directory basename
---@field abs_filename string Absolute path
---@field name string Display name
---@field type "file"|"dir" Entry kind
---@field project core.project Owning project
---@field depth integer Path depth relative to the project
---@field expanded boolean Whether children are expanded
---@field files? system.fileinfo[] Cached directory children
---@field symlink? boolean Whether this is a directory symlink

---Nodes owned by TreeView for placing its toolbar around the tree/document split.
---@class plugins.treeview.toolbar_layout
---@field root core.rootview Root that owns these layout nodes
---@field node core.node Outer split retained across docking changes
---@field documents core.node Document branch retained when its child splits collapse
---@field toolbar_node core.node Leaf containing the toolbar
---@field group? core.node Intermediate split rebuilt for the current docking position

---@class plugins.treeview : core.view
---@overload fun():plugins.treeview
---@field default_size number Scaled configured width used to detect manual resizing
---@field scroll_width number Width of the currently drawn rows in content coordinates
---@field toolbar? plugins.toolbarview Attached toolbar
---@field toolbar_position "left"|"bottom"|"top"|"right" Docking position owned by TreeView
---@field toolbar_layout? plugins.treeview.toolbar_layout Nodes created when attaching a toolbar
---@field contextmenu? core.contextmenu Tree context menu
---@field context_item? plugins.treeview.item Clicked target while its context menu is open
---@field context_command_item? plugins.treeview.item Target retained through command dispatch
---@field tooltip_view? core.view Floating path-tooltip companion
local TreeView = View:extend()

function TreeView:__tostring() return "TreeView" end

function TreeView:new()
  TreeView.super.new(self)
  self.scrollable = true
  self.visible = true
  self.init_size = true
  self.scroll_width = 0
  self.target_size = config.plugins.treeview.size
  self.default_size = self.target_size
  self.toolbar_position = config.plugins.treeview.toolbar_position
  self.show_hidden = config.plugins.treeview.show_hidden
  self.show_ignored = config.plugins.treeview.show_ignored
  self.cache = {}
  self.expanded = {}
  self.tooltip = { x = 0, y = 0, begin = 0, alpha = 0 }
  self.last_scroll_y = 0

  self.item_icon_width = 0
  self.item_text_spacing = 0
  self.watches = { }
end


function TreeView:set_target_size(axis, value)
  if axis == "x" then
    self.target_size = value
    return true
  end
end


function TreeView:on_scale_change(new_scale, prev_scale)
  self.target_size = self.target_size / prev_scale
  self.target_size = self.target_size * new_scale
  self.default_size = self.default_size / prev_scale * new_scale
end


function TreeView:get_cached(project, path)
  local t = self.cache[path]
  if not t then
    if not self.watches[project] then self.watches[project] = DirWatch() end
    local truncated = path:sub(#project.path + 2)
    local basename = common.basename(path)
    local info
    if self.show_ignored then
      info = system.get_file_info(path)
    else
      info = project:get_file_info(path)
    end
    if not info then return nil end
    t = {
      filename = basename,
      depth = get_depth(truncated),
      abs_filename = path,
      project = project,
      name = basename,
      type = info.type,
      symlink = info.symlink
    }
    if self.expanded[path] ~= nil then
      t.expanded = self.expanded[path]
    else
      t.expanded = (info.type == "dir" and #truncated <= 1)
    end
    if t.expanded then self.watches[project]:watch(path) end
    self.cache[path] = t
  end
  if t.expanded and t.type == "dir" and not t.files then
    t.files = {}
    for i, file in ipairs(system.list_dir(path) or {}) do
      local l = path .. PATHSEP .. file
      local f
      if self.show_ignored then
        f = system.get_file_info(l)
      else
        f = project:get_file_info(l)
      end
      if f and f.type then
        f.name = file
        f.abs_filename = l
        table.insert(t.files, f)
      end
      self.cache[l] = nil
    end
    table.sort(
      t.files,
      function(a, b)
        return system.path_compare(a.name, a.type, b.name, b.type)
      end
    )
  end

  return t
end


function TreeView:get_name()
  return nil
end


function TreeView:get_item_height()
  return style.font:get_height() + style.padding.y
end


function TreeView:get_items(project, path, x, y, w, h)
  local dir = self:get_cached(project, path)
  coroutine.yield(dir, x, y, w, h)
  local count_lines = 1
  if dir and dir.files and dir.expanded then
    for i, file in ipairs(dir.files) do
      if self.show_hidden or not file.name:find("^%.") then
        count_lines = count_lines + self:get_items(
          project,
          path .. PATHSEP .. file.name,
          x, y + count_lines * h,
          w, h
        )
      end
    end
  end
  return count_lines
end


function TreeView:each_item()
  return coroutine.wrap(function()
    local count_lines = 0
    local ox, oy = self:get_content_offset()
    local h = self:get_item_height()
    for k, project in ipairs(core.projects) do
      count_lines = count_lines + self:get_items(
        project, project.path,
        ox, oy + style.padding.y + h * count_lines,
        self.size.x, h
      )
    end
    self.count_lines = count_lines
  end)
end


function TreeView:set_selection(selection, selection_y, center, instant)
  self.selected_item = selection
  if selection and selection_y
      and (selection_y <= 0 or selection_y >= self.size.y) then
    local lh = self:get_item_height()
    if not center and selection_y >= self.size.y - lh then
      selection_y = selection_y - self.size.y + lh
    end
    if center then
      selection_y = selection_y - (self.size.y - lh) / 2
    end
    local _, y = self:get_content_offset()
    self.scroll.to.y = selection_y - y
    self.scroll.to.y = common.clamp(
      self.scroll.to.y,
      0,
      self:get_scrollable_size() - self.size.y
    )
    if instant then
      self.scroll.y = self.scroll.to.y
    end
  end
end

---Sets the selection to the file with the specified path.
---
---@param path string #Absolute path of item to select
---@param expand boolean #Expand dirs leading to the item
---@param scroll_to boolean #Scroll to make the item visible
---@param instant boolean #Don't animate the scroll
---@return table? #The selected item
function TreeView:set_selection_to_path(path, expand, scroll_to, instant)
  local to_select, to_select_y
  local let_it_finish, done
  ::restart::
  for item, x,y,w,h in self:each_item() do
    if not done then
      if item.type == "dir" then
        local _, to = string.find(path, item.abs_filename..PATHSEP, 1, true)
        if to and to == #item.abs_filename + #PATHSEP then
          to_select, to_select_y = item, y
          if expand and not item.expanded then
            -- Use TreeView:toggle_expand to update the directory structure.
            -- Directly using item.expanded doesn't update the cached tree.
            self:toggle_expand(true, item)
            -- Because we altered the size of the TreeView
            -- and because TreeView:get_scrollable_size uses self.count_lines
            -- which gets updated only when TreeView:each_item finishes,
            -- we can't stop here or we risk that the scroll
            -- gets clamped by View:clamp_scroll_position.
            let_it_finish = true
            -- We need to restart the process because if TreeView:toggle_expand
            -- altered the cache, TreeView:each_item risks looping indefinitely.
            goto restart
          end
        end
      else
        if item.abs_filename == path then
          to_select, to_select_y = item, y
          done = true
          if not let_it_finish then break end
        end
      end
    end
  end
  if to_select then
    self:set_selection(to_select, scroll_to and to_select_y, true, instant)
  end
  return to_select
end


function TreeView:get_text_bounding_box(item, x, y, w, h)
  local icon_width = style.icon_font:get_width("D")
  local xoffset = item.depth * style.padding.x + self:get_gutter_width() + icon_width
  x = x + xoffset
  w = style.font:get_width(item.name) + 2 * style.padding.x
  return x, y, w, h
end



function TreeView:on_mouse_moved(px, py, ...)
  if not self.visible then return end
  -- Existing menu extensions use hovered_item as their command target.
  if self.contextmenu and self.contextmenu.show_context_menu then return end
  if TreeView.super.on_mouse_moved(self, px, py, ...) then
    -- mouse movement handled by the View (scrollbar)
    self.hovered_item = nil
    return
  end

  local item_changed, tooltip_changed
  for item, x,y,w,h in self:each_item() do
    if px > x and py > y and px <= self.position.x + self.size.x and py <= y + h then
      item_changed = true
      self.hovered_item = item

      x = math.max(x, self.position.x)
      if px > x and py > y and px <= x + w and py <= y + h then
        tooltip_changed = true
        self.tooltip.x, self.tooltip.y = px, py
        self.tooltip.begin = system.get_time()
      end
      break
    end
  end
  if not item_changed then self.hovered_item = nil end
  if not tooltip_changed then self.tooltip.x, self.tooltip.y = nil, nil end
end


function TreeView:on_mouse_left()
  TreeView.super.on_mouse_left(self)
  self:hide_tooltip()
  if not (self.contextmenu and self.contextmenu.show_context_menu) then
    self.hovered_item = nil
  end
end

---Invalidate one directory after a filesystem change, or reset all cached rows.
---@param project? core.project Project owning the changed directory
---@param path? string Absolute changed directory; omit both arguments for a full reset
function TreeView:invalidate_cache(project, path)
  if project and path then
    self.cache[path] = nil
  else
    self.cache = {}
  end
  core.redraw = true
end

---Cancel pending or shown path tooltips and hide their floating companion.
function TreeView:hide_tooltip()
  self.tooltip.alpha = 0
  self.tooltip.x, self.tooltip.y = nil, nil
  if self.tooltip_view then self.tooltip_view:hide_floating() end
end


---Get the clicked menu target while opening or dispatching a contextual action.
---Otherwise falls back to the hovered or selected item.
---@return plugins.treeview.item? item File or directory targeted by the action
function TreeView:get_context_item()
  return self.context_command_item
    or (self.contextmenu and self.contextmenu.show_context_menu and self.context_item)
    or self.hovered_item or self.selected_item
end


function TreeView:update()
  -- update width
  local width = self.target_size
  if width == self.default_size and self.toolbar
    and self.toolbar.orientation == "horizontal" and self.toolbar:is_visible()
  then
    width = math.max(width, self.toolbar:get_min_width())
  end
  local dest = self.visible and common.round(width) or 0
  if self.init_size then
    self.size.x = dest
    self.init_size = false
  elseif self.size.x ~= dest then
    self:move_towards(self.size, "x", dest, nil, "treeview")
    -- round to allow constant positioning of slibing elements on resize
    self.size.x = common.round(self.size.x)
    if math.abs(dest - self.size.x) <= 2 then self.size.x = dest end
  end

  if self.size.x == 0 or self.size.y == 0 or not self.visible then return end

  local duration = system.get_time() - self.tooltip.begin
  if self.hovered_item and self.tooltip.x and duration >= tooltip_delay then
    self:move_towards(self.tooltip, "alpha", tooltip_alpha, tooltip_alpha_rate, "treeview")
  else
    self.tooltip.alpha = 0
    if self.hovered_item and self.tooltip.x then
      core.request_update(tooltip_delay - duration)
    end
  end

  self.item_icon_width = style.icon_font:get_width("D")
  self.item_text_spacing = style.icon_font:get_width("f") / 2

  -- this will make sure hovered_item is updated
  local dy = math.abs(self.last_scroll_y - self.scroll.y)
  if dy > 0 then
    self:on_mouse_moved(core.root_view.mouse.x, core.root_view.mouse.y, 0, 0)
    self.last_scroll_y = self.scroll.y
  end

  local config = config.plugins.treeview
  if config.highlight_focused_file then
    -- Try to only highlight when we actually change tabs
    local current_node = core.root_view:get_active_node()
    local current_active_view = core.active_view
    if current_node and not current_node.locked
     and current_active_view ~= self and current_active_view ~= self.last_active_view then
      self.selected_item = nil
      self.last_active_view = current_active_view
      if DocView:is_extended_by(current_active_view) then
        local abs_filename = current_active_view.doc
          and current_active_view.doc.abs_filename
          or ""
        self:set_selection_to_path(
          abs_filename,
          config.expand_dirs_to_focused_file,
          config.scroll_to_focused_file,
          not config.animate_scroll_to_focused_file
        )
      end
    end
  end

  TreeView.super.update(self)
end


function TreeView:get_scrollable_size()
  return self.count_lines
    and self:get_item_height() * (self.count_lines + 1)
    or math.huge
end


function TreeView:get_h_scrollable_size()
  return self.scroll_width
end


function TreeView:draw_tooltip()
  local text = common.home_encode(self.hovered_item.abs_filename)
  local w, h = style.font:get_width(text), style.font:get_height(text)

  local x, y = self.tooltip.x + tooltip_offset, self.tooltip.y + tooltip_offset
  w, h = w + style.padding.x, h + style.padding.y

  if x + w > core.root_view.root_node.size.x then -- check if we can span right
    x = x - w -- span left instead
  end

  local bx, by = x - tooltip_border, y - tooltip_border
  local bw, bh = w + 2 * tooltip_border, h + 2 * tooltip_border
  renderer.draw_rect(
    bx, by, bw, bh, replace_alpha(style.text, self.tooltip.alpha)
  )
  renderer.draw_rect(
    x, y, w, h, replace_alpha(style.background2, self.tooltip.alpha)
  )
  common.draw_text(
    style.font,
    replace_alpha(style.text, self.tooltip.alpha),
    text, "center",
    x, y, w, h
  )
end


function TreeView:get_item_icon(item, active, hovered)
  local character = "f"
  if item.type == "dir" then
    character = item.expanded and "D" or "d"
  end
  local font = style.icon_font
  local color = style.text
  if active or hovered then
    color = style.accent
  end
  return character, font, color
end

function TreeView:get_item_text(item, active, hovered)
  local text = item.name
  local font = style.font
  local color = style.text
  if active or hovered then
    color = style.accent
  end
  return text, font, color
end


function TreeView:draw_item_text(item, active, hovered, x, y, w, h)
  local item_text, item_font, item_color = self:get_item_text(item, active, hovered)
  return common.draw_text(item_font, item_color, item_text, nil, x, y, 0, h)
end


function TreeView:draw_item_icon(item, active, hovered, x, y, w, h)
  local icon_char, icon_font, icon_color = self:get_item_icon(item, active, hovered)
  common.draw_text(icon_font, icon_color, icon_char, nil, x, y, 0, h)
  return self.item_icon_width + self.item_text_spacing
end


---Draw the scrollable icon and name, preserving get_item_icon/get_item_text hooks.
---Return the intrinsic text endpoint even when the supplied viewport clips it.
---@param item plugins.treeview.item
---@param active boolean
---@param hovered boolean
---@param x number Scrolled content x coordinate after indentation and chevron
---@param y number Row top in screen coordinates
---@param w number Available body width
---@param h number Row height
---@return number endpoint Unclipped screen x coordinate after the text
function TreeView:draw_item_body(item, active, hovered, x, y, w, h)
  x = x + self:draw_item_icon(item, active, hovered, x, y, w, h)
  return self:draw_item_text(item, active, hovered, x, y, w, h)
end

---Get the fixed left gutter width, shared by every row and unaffected by scrolling.
---Override alongside draw_item_gutter() when markers need more room.
---@return number width Gutter width in screen pixels, including its spacing
function TreeView:get_gutter_width()
  return style.padding.x
end

---Draw optional markers inside the fixed left gutter. Empty by default.
---Example: override get_gutter_width() to return 20 * SCALE, then draw an icon
---here using common.draw_text(style.icon_font, style.dim, "!", "center", x, y, w, h).
---@param item plugins.treeview.item
---@param active boolean
---@param hovered boolean
---@param x number Fixed gutter left edge in screen coordinates
---@param y number Row top in screen coordinates
---@param w number Clipped gutter width
---@param h number Row height
function TreeView:draw_item_gutter(item, active, hovered, x, y, w, h)
end

---Draw right-aligned row information once and return the horizontal space it used.
---TreeView clips this hook to the available row area, then clips the body before
---the returned width. Return zero when empty; include all drawn content in the width.
---The default does not draw any information.
---Example: draw a cached label at x + w - label_width, then return label_width.
---@param item plugins.treeview.item
---@param active boolean
---@param hovered boolean
---@param x number Available area left edge in screen coordinates
---@param y number Row top in screen coordinates
---@param w number Available width, ending before the scrollbar and right padding
---@param h number Row height
---@return number width Occupied width, anchored at x + w
function TreeView:draw_item_info(item, active, hovered, x, y, w, h)
  return 0
end

function TreeView:draw_item_chevron(item, active, hovered, x, y, w, h)
  if item.type == "dir" then
    local chevron_icon = item.expanded and "-" or "+"
    local chevron_color = hovered and style.accent or style.text
    common.draw_text(style.icon_font, chevron_color, chevron_icon, nil, x, y, 0, h)
  end
  return style.padding.x
end


function TreeView:draw_item_background(item, active, hovered, x, y, w, h)
  if hovered then
    local hover_color = { table.unpack(style.line_highlight) }
    hover_color[4] = 160
    renderer.draw_rect(self.position.x, y, self.size.x, h, hover_color)
  elseif active then
    renderer.draw_rect(self.position.x, y, self.size.x, h, style.line_highlight)
  end
end


function TreeView:draw_item(item, active, hovered, x, y, w, h)
  self:draw_item_background(item, active, hovered, x, y, w, h)
  local left, right = self.position.x, self.position.x + self.size.x
  local gutter = math.min(math.max(0, self:get_gutter_width()), self.size.x)
  local inset = style.padding.x
  local scrollable = self:get_scrollable_size()
  if scrollable ~= math.huge and scrollable > self.size.y then
    inset = math.max(inset, (self.v_scrollbar.expanded_size or style.expanded_scrollbar_size) + SCALE)
  end
  right = math.max(left + gutter, right - inset)
  core.push_clip_rect(left, y, gutter, h)
  self:draw_item_gutter(item, active, hovered, left, y, gutter, h)
  core.pop_clip_rect()
  core.push_clip_rect(left + gutter, y, right - left - gutter, h)
  local info = self:draw_item_info(item, active, hovered, left + gutter, y, right - left - gutter, h)
  core.pop_clip_rect()
  info = math.max(0, info)
  local reserve = info > 0 and info + style.padding.x or 0
  local body_right = math.max(left + gutter, right - reserve)
  core.push_clip_rect(left + gutter, y, body_right - left - gutter, h)
  x = x + item.depth * style.padding.x + gutter
  x = x + self:draw_item_chevron(item, active, hovered, x, y, math.max(0, body_right - x), h)
  local endpoint = self:draw_item_body(item, active, hovered, x, y, math.max(0, body_right - x), h)
  core.pop_clip_rect()
  return endpoint + reserve + inset
end


function TreeView:draw()
  if not self.visible then return end
  self:draw_background(style.background2)
  local _y, _h = self.position.y, self.size.y

  local sw, ox = 0, self:get_content_offset()
  for item, x,y,w,h in self:each_item() do
    if y + h >= _y and y < _y + _h then
      local w = self:draw_item(
        item,
        item == self.selected_item,
        item == self.hovered_item,
        x, y, w, h
      ) - ox
      sw = math.max(w, sw)
    end
  end
  if self.scroll_width ~= sw then
    self.scroll_width = sw
    core.redraw = true
  end

  self:draw_scrollbar()
  if self.hovered_item and self.tooltip.x and self.tooltip.alpha > 0 then
    if not self.tooltip_view then
      local tooltip = View()
      self.tooltip_view = tooltip
      tooltip:set_floating(true, { owner = self, interactive = false, focus = "none" })
      ---Get the editor viewport bounds for a companion that draws outside its owner.
      ---@return number x Viewport screen x coordinate
      ---@return number y Viewport screen y coordinate
      ---@return number w Viewport width
      ---@return number h Viewport height
      tooltip.get_floating_bounds = function()
        local root = core.root_view
        return root.position.x, root.position.y, root.size.x, root.size.y
      end
      ---Ignore placement writes because the companion computes its bounds from its owner.
      tooltip.set_floating_bounds = function() end
      ---Draw the tree owner's current path tooltip in the floating layer.
      tooltip.draw = function() self:draw_tooltip() end
      ---Remove the tooltip companion once its owner no longer has a visible path tooltip.
      tooltip.update = function()
        if
          not (
            self.hovered_item
            and self.tooltip.x
            and self.tooltip.alpha > 0
          )
        then
          tooltip:hide_floating()
        end
      end
    end
    if not self.tooltip_view.floating_visible then
      self.tooltip_view:show_floating()
    end
  end
end


function TreeView:get_parent(item)
  local parent_path = common.dirname(item.abs_filename)
  if not parent_path then return end
  for it, _, y in self:each_item() do
    if it.abs_filename == parent_path then
      return it, y
    end
  end
end


function TreeView:get_item(item, where)
  local last_item, last_x, last_y, last_w, last_h
  local stop = false

  for it, x, y, w, h in self:each_item() do
    if not item and where >= 0 then
      return it, x, y, w, h
    end
    if item == it then
      if where < 0 and last_item then
        break
      elseif where == 0 or (where < 0 and not last_item) then
        return it, x, y, w, h
      end
      stop = true
    elseif stop then
      item = it
      return it, x, y, w, h
    end
    last_item, last_x, last_y, last_w, last_h = it, x, y, w, h
  end
  return last_item, last_x, last_y, last_w, last_h
end

function TreeView:get_next(item)
  return self:get_item(item, 1)
end

function TreeView:get_previous(item)
  return self:get_item(item, -1)
end


function TreeView:toggle_expand(toggle, item)
  item = item or self.selected_item

  if not item then return end

  if item.type == "dir" then
    if type(toggle) == "boolean" then
      item.expanded = toggle
    else
      item.expanded = not item.expanded
    end
    self.expanded[item.abs_filename] = item.expanded
    if self.watches[item.project] then
      self.watches[item.project]:watch(item.abs_filename, item.expanded)
    end
  end
end

function TreeView:open_doc(filename)
  return core.open_file(filename)
end


---Apply TreeView's docking position while preserving the tree and document branches.
---Cancel gestures and hover on moved panes, then set toolbar orientation and node locks.
---@param tree plugins.treeview Owner whose toolbar layout is rebuilt, if attached
local function update_toolbar_layout(tree)
  local docking, toolbar = tree.toolbar_layout, tree.toolbar
  if not docking then return end
  local root, layout, group = docking.root, docking.node, docking.group
  if
    (
      root.grab and (root.grab.view == toolbar or root.grab.view == tree)
    )
    or (
      root.dragged_divider
      and (
        root.dragged_divider == layout or root.dragged_divider == group
      )
    )
  then
    root:cancel_mouse_capture()
  end
  if tree.contextmenu then tree.contextmenu:hide() end
  if root.overlapping_view == toolbar or root.overlapping_view == tree then
    root:set_hovered_view(nil)
  end
  tree:hide_tooltip()
  toolbar:on_mouse_left()
  toolbar.scroll.x, toolbar.scroll.y = 0, 0
  toolbar.scroll.to.x, toolbar.scroll.to.y = 0, 0

  local toolbar_node = docking.toolbar_node
  if tree.toolbar_position == "left" or tree.toolbar_position == "right" then
    group = Node("hsplit")
    group.a, group.b = tree.node, docking.documents
    if tree.toolbar_position == "left" then
      layout.a, layout.b = toolbar_node, group
    else
      layout.a, layout.b = group, toolbar_node
    end
    toolbar_node.locked = { x = true }
    toolbar:set_orientation("vertical")
  else
    group = Node("vsplit")
    if tree.toolbar_position == "top" then
      group.a, group.b = toolbar_node, tree.node
    else
      group.a, group.b = tree.node, toolbar_node
    end
    layout.a, layout.b = group, docking.documents
    toolbar_node.locked = { y = true }
    toolbar:set_orientation("horizontal")
  end
  docking.group = group
  toolbar.init_size = true
  toolbar:update()
  root.root_node:update_layout()
  core.redraw = true
end


---Set toolbar docking and update TreeView's placement setting.
---Left and right use vertical icons; right places the toolbar beyond all document panes.
---Top and bottom use horizontal icons above or below the tree.
---May be called before attachment; changing placement preserves document and tree state.
---Settings saves this preference to disk when its position selector is used.
---@param position "left"|"bottom"|"top"|"right" Tree docking or the editor's far-right edge
function TreeView:set_toolbar_position(position)
  assert(
    position == "left"
      or position == "bottom"
      or position == "top"
      or position == "right",
    "Invalid toolbar position"
  )
  config.plugins.treeview.toolbar_position = position
  if self.toolbar_position == position then return end
  self.toolbar_position = position
  update_toolbar_layout(self)
end


---Attach a toolbar to this docked tree and apply its current placement preference.
---Owns toolbar docking and effective visibility while preserving requested visibility.
---@param toolbar plugins.toolbarview Toolbar to place and orient around the tree
function TreeView:attach_toolbar(toolbar)
  local root = core.root_view
  local layout = self.node:get_parent_node(root.root_node)
  local group = self.node
  self.toolbar_layout = {
    root = root, node = layout, documents = layout.b,
    toolbar_node = group:split("down", toolbar, { y = true })
  }
  self.node, self.toolbar = group.a, toolbar
  local tree = self
  ---Check TreeView's docking visibility without changing the requested toolbar flag.
  ---@return boolean visible Left and right docking stay visible when the tree is hidden
  function toolbar:is_visible()
    return self.visible and (
      tree.toolbar_position == "left"
      or tree.toolbar_position == "right"
      or tree.visible
    )
  end
  update_toolbar_layout(self)
end

-- init
local view = TreeView()
local node = core.root_view:get_active_node()
view.node = node:split("left", view, {x = true}, true)

-- The toolbarview plugin is special because it is plugged inside
-- a treeview pane which is itelf provided in a plugin.
-- We therefore break the usual plugin's logic that would require each
-- plugin to be independent of each other. In addition it is not the
-- plugin module that plug itself in the active node but it is plugged here
-- in the treeview node.
local toolbar_view = nil
if config.plugins.toolbarview ~= false then
  local ToolbarView = require "plugins.toolbarview"
  toolbar_view = ToolbarView()
  toolbar_view.visible = config.plugins.treeview.show_toolbar ~= false
  view:attach_toolbar(toolbar_view)
  command.add(nil, {
    ["toolbar:toggle"] = function()
      toolbar_view:toggle_visible()
    end,
  })
end


local old_remove_project = core.remove_project
function core.remove_project(project, force)
  local project = old_remove_project(project, force)
  if project then
    view.cache = {}
    view.watches[project] = nil
  end
  return project
end

core.add_thread(function()
  while true do
    for project, watch in pairs(view.watches) do
      local changed = {}
      watch:check(function(directory)
        changed[directory] = true
      end)
      for directory in pairs(changed) do view:invalidate_cache(project, directory) end
    end
    coroutine.yield(0.1)
  end
end)


-- Add a context menu to the treeview
local menu = ContextMenu()

---Restore physical tree hover after menu dismissal without retaining its clicked target.
local function restore_hover()
  view.hovered_item = nil
  local root = core.root_view
  local x, y = root.mouse.x, root.mouse.y
  local node = root.root_node:get_child_overlapping_point(x, y)
  if node and node.active_view == view and not root:get_floating_view_at(x, y) then
    view:on_mouse_moved(x, y, 0, 0)
  end
end

---Capture the clicked tree item before snapshotting contextual command predicates.
---@param x number Opening screen x coordinate
---@param y number Opening screen y coordinate
---@return boolean shown Whether the active tree supplied a nonempty menu
function menu:show(x, y)
  if core.active_view ~= view then return false end
  if not self.show_context_menu then view:on_mouse_moved(x, y, 0, 0) end
  local hovered = view.hovered_item
  view.context_item = view.hovered_item or view.selected_item
  view.hovered_item = view.context_item
  local shown = ContextMenu.show(self, x, y)
  if not shown then view.context_item, view.hovered_item = nil, hovered end
  return shown
end

---Hide tree tooltips while the menu is open and restore hover after dismissal.
---@param visible boolean Whether the menu remains shown
function menu:on_floating_visibility_changed(visible)
  ContextMenu.on_floating_visibility_changed(self, visible)
  if visible then
    view:hide_tooltip()
  else
    view.context_item = nil
    if not view.context_command_item then restore_hover() end
  end
end

---Retain the clicked tree item through hide-before-dispatch and restore hover afterward.
---@param selected? core.contextmenu.item Submenu leaf to dispatch through this root
function menu:call_selected_item(selected)
  -- ContextMenu hides before dispatch; keep its target through that command.
  local previous = view.context_command_item
  view.context_command_item = view.context_item
  ContextMenu.call_selected_item(self, selected)
  view.context_command_item = previous
  if not self.show_context_menu then restore_hover() end
end


local on_view_mouse_pressed = RootView.on_view_mouse_pressed
function RootView.on_view_mouse_pressed(button, x, y, clicks)
  -- We give the priority to the menu to process mouse pressed events.
  if button == "right" then
    view:hide_tooltip()
  end
  local handled = menu:on_mouse_pressed(button, x, y, clicks)
  return handled or on_view_mouse_pressed(button, x, y, clicks)
end

local on_quit_project = core.on_quit_project
function core.on_quit_project()
  view:invalidate_cache()
  on_quit_project()
end


local function is_project_folder(item)
  return item.abs_filename == item.project.path
end

local function is_primary_project_folder(path)
  return core.root_project().path == path
end

local function treeitem() return view:get_context_item() end


menu:register(function() return core.active_view:is(TreeView) and treeitem() end, {
  { text = "Open in System", command = "treeview:open-in-system" },
  { text = "Open in Editor", command = "treeview:open-in-editor" },
  ContextMenu.DIVIDER
})

menu:register(
  function()
    local item = treeitem()
    return core.active_view:is(TreeView)
      and item
      and item.type == "file"
      and MarkdownView.is_supported(item.abs_filename)
  end,
  {
    { text = "Preview Markdown", command = "treeview:preview-markdown" }
  }
)

menu:register(
  function()
    local item = treeitem()
    return core.active_view:is(TreeView) and item and not is_project_folder(item)
  end,
  {
    { text = "Rename", command = "treeview:rename" },
    { text = "Delete", command = "treeview:delete" },
  }
)

menu:register(
  function()
    local item = treeitem()
    return core.active_view:is(TreeView) and item and item.type == "dir"
  end,
  {
    { text = "New File", command = "treeview:new-file" },
    { text = "New Folder", command = "treeview:new-folder" },
  }
)

menu:register(
  function()
    local item = treeitem()
    return core.active_view:is(TreeView) and item
      and not is_primary_project_folder(item.abs_filename)
      and is_project_folder(item)
  end,
  {
    { text = "Remove directory", command = "treeview:remove-project-directory" },
  }
)

local previous_view = nil

-- Register the TreeView commands and keymap
command.add(nil, {
  ["treeview:toggle"] = function()
    view.visible = not view.visible
  end,

  ["treeview:toggle-hidden"] = function()
    view.show_hidden = not view.show_hidden
    view:invalidate_cache()
  end,

  ["treeview:toggle-ignored"] = function()
    view.show_ignored = not view.show_ignored
    view:invalidate_cache()
  end,

  ["treeview:toggle-focus"] = function()
    if not core.active_view:is(TreeView) then
      if core.active_view:is(CommandView) then
        previous_view = core.last_active_view
      else
        previous_view = core.active_view
      end
      if not previous_view then
        previous_view = core.root_view:get_primary_node().active_view
      end
      core.set_active_view(view)
      if not view.selected_item then
        for it, _, y in view:each_item() do
          view:set_selection(it, y)
          break
        end
      end

    else
      core.set_active_view(
        previous_view or core.root_view:get_primary_node().active_view
      )
    end
  end
})

command.add(
  function()
    return not menu.show_context_menu and core.active_view:extends(TreeView), TreeView
  end, {
  ["treeview:next"] = function()
    local item, _, item_y = view:get_next(view.selected_item)
    view:set_selection(item, item_y)
  end,

  ["treeview:previous"] = function()
    local item, _, item_y = view:get_previous(view.selected_item)
    view:set_selection(item, item_y)
  end,

  ["treeview:open"] = function()
    local item = view.selected_item
    if not item then return end
    if item.type == "dir" then
      view:toggle_expand()
    else
      core.try(function()
        if core.last_active_view and core.active_view == view then
          core.set_active_view(core.last_active_view)
        end
        view:open_doc(core.normalize_to_project_dir(item.abs_filename))
      end)
    end
  end,

  ["treeview:deselect"] = function()
    view.selected_item = nil
  end,

  ["treeview:select"] = function()
    view:set_selection(view.hovered_item)
  end,

  ["treeview:select-and-open"] = function()
    if view.hovered_item then
      view:set_selection(view.hovered_item)
      command.perform "treeview:open"
    end
  end,

  ["treeview:collapse"] = function()
    if view.selected_item then
      if view.selected_item.type == "dir" and view.selected_item.expanded then
        view:toggle_expand(false)
      else
        local parent_item, y = view:get_parent(view.selected_item)
        if parent_item then
          view:set_selection(parent_item, y)
        end
      end
    end
  end,

  ["treeview:expand"] = function()
    local item = view.selected_item
    if not item or item.type ~= "dir" then return end

    if item.expanded then
      local next_item, _, next_y = view:get_next(item)
      if next_item.depth > item.depth then
        view:set_selection(next_item, next_y)
      end
    else
      view:toggle_expand(true)
    end
  end,

  ["treeview-context:show"] = function()
    if view.hovered_item then
      menu:show(core.root_view.mouse.x, core.root_view.mouse.y)
      return
    end

    local item = view.selected_item
    if not item then return end

    local x, y
    for _i, _x, _y, _w, _h in view:each_item() do
      if _i == item then
        x = _x + _w / 2
        y = _y + _h / 2
        break
      end
    end
    menu:show(x, y)
  end
})


command.add(
  function()
    local item = treeitem()
    return item ~= nil and (core.active_view == view or menu.show_context_menu), item
  end, {
  ["treeview:delete"] = function(item)
    local filename = item.abs_filename
    local relfilename = item.filename
    if item.project ~= core.root_project() then
      -- add secondary project dirs names to the file path to show
      relfilename = common.basename(item.abs_filename) .. PATHSEP .. relfilename
    end
    local file_info = system.get_file_info(filename)
    local file_type = file_info.type == "dir" and "Directory" or "File"
    -- Ask before deleting
    local opt = {
      { text = "Yes", default_yes = true },
      { text = "No", default_no = true }
    }
    core.nag_view:show(
      string.format("Delete %s", file_type),
      string.format(
        "Are you sure you want to delete the %s?\n%s: %s",
        file_type:lower(), file_type, relfilename
      ),
      opt,
      function(item)
        if item.text == "Yes" then
          if file_info.type == "dir" then
            local deleted, error, path = common.rm(filename, true)
            if not deleted then
              core.error("Error: %s - \"%s\" ", error, path)
              return
            end
          else
            local removed, error = os.remove(filename)
            if not removed then
              core.error("Error: %s - \"%s\"", error, filename)
              return
            end
          end
          core.log("Deleted \"%s\"", filename)
        end
      end
    )
  end,

  ["treeview:rename"] = function(item)
    local old_filename = core.normalize_to_project_dir(item.abs_filename)
    local old_abs_filename = item.abs_filename
    core.command_view:enter("Rename", {
      text = old_filename,
      submit = function(filename)
        local abs_filename = filename
        if not common.is_absolute_path(filename) then
          abs_filename = item.project.path .. PATHSEP .. filename
        end
        local res, err = os.rename(old_abs_filename, abs_filename)
        if res then -- successfully renamed
          for _, doc in ipairs(core.docs) do
            if doc.abs_filename and old_abs_filename == doc.abs_filename then
              doc:set_filename(filename, abs_filename) -- make doc point to the new filename
              doc:reset_syntax()
              break -- only first needed
            end
          end
          core.log("Renamed \"%s\" to \"%s\"", old_filename, filename)
        else
          core.error("Error while renaming \"%s\" to \"%s\": %s", old_abs_filename, abs_filename, err)
        end
      end,
      suggest = function(text)
        return common.path_suggest(text)
      end
    })
  end,

  ["treeview:new-file"] = function(item)
    local text, path
    if not is_project_folder(item) then
      path = common.dirname(item.abs_filename)
      if item.type == "dir" then
        text = item.filename .. PATHSEP
      elseif item.type == "file" then
        local parent_dir = common.dirname(
          item.project:normalize_path(item.abs_filename)
        )
        text = parent_dir and parent_dir .. PATHSEP
        path = common.dirname(path)
      end
    else
      path = item.project.path
    end
    core.command_view:enter("Filename", {
      text = text,
      submit = function(filename)
        local doc_filename = path .. PATHSEP .. filename
        local file, err = io.open(doc_filename, "a+")
        if not file then
          core.error("Error: unable to create a new file in \"%s\": %s", doc_filename, err)
          return
        end
        file:close()
        view:open_doc(doc_filename)
        core.log("Created %s", doc_filename)
      end,
      suggest = function(text)
        return common.path_suggest(text, path)
      end
    })
  end,

  ["treeview:new-folder"] = function(item)
    local text, path
    if not is_project_folder(item) then
      path = common.dirname(item.abs_filename)
      if item.type == "dir" then
        text = item.filename .. PATHSEP
      elseif item.type == "file" then
        local parent_dir = common.dirname(
          item.project:normalize_path(item.abs_filename)
        )
        text = parent_dir and parent_dir .. PATHSEP
        path = common.dirname(path)
      end
    else
      path = item.project.path
    end
    core.command_view:enter("Folder Name", {
      text = text,
      submit = function(filename)
        local dir_path = path .. PATHSEP .. filename
        common.mkdirp(dir_path)
        core.log("Created %s", dir_path)
      end,
      suggest = function(text)
        return common.path_suggest(text, path)
      end
    })
  end,

  ["treeview:open-in-system"] = function(item)
    common.open_in_system(item.abs_filename)
  end
})

command.add(
  function()
    local item = treeitem()
    if item then
      local is_image, ext = ImageView.is_supported(item.abs_filename)
      if is_image and (ext == "svg" or ext == "xpm") then
        return (core.active_view == view or menu.show_context_menu), item
      end
    end
    return false
  end, {
  ["treeview:open-in-editor"] = function(item)
    core.root_view:open_doc(core.open_doc(item.abs_filename))
  end
})

command.add(
  function()
    local item = treeitem()
    if item and item.type == "file" and MarkdownView.is_supported(item.abs_filename) then
      return (core.active_view == view or menu.show_context_menu), item
    end
    return false
  end, {
  ["treeview:preview-markdown"] = function(item)
    core.open_markdown(item.abs_filename)
  end
})

if config.plugins.projectsearch ~= false then
  require "plugins.projectsearch"
  menu:register(function()
    local item = treeitem()
    return item and item.type == "dir"
  end, {
    { text = "Find in directory", command = "treeview:search-in-directory" }
  })
  command.add(function()
    local item = treeitem()
    return item and item.type == "dir", item
  end, {
    ["treeview:search-in-directory"] = function(item)
      command.perform("project-search:find", item.abs_filename)
    end
  })
end

command.add(
  function()
    local item = treeitem()
    return item
      and not is_primary_project_folder(item.abs_filename)
      and is_project_folder(item), item
  end,
  {
    ["treeview:remove-project-directory"] = function(item)
      core.remove_project(item.project)
    end,
  }
)


command.add(
  function()
    return menu.show_context_menu == true and core.active_view:is(TreeView)
  end,
  {
    ["treeview-context:focus-previous"] = function()
      menu:focus_previous()
    end,
    ["treeview-context:focus-next"] = function()
      menu:focus_next()
    end,
    ["treeview-context:hide"] = function()
      menu:hide()
    end,
    ["treeview-context:on-selected"] = function()
      menu:call_selected_item()
    end,
  }
)


keymap.add {
  ["ctrl+\\"]     = "treeview:toggle",
  ["ctrl+h"]      = "treeview:toggle-hidden",
  ["ctrl+i"]      = "treeview:toggle-ignored",
  ["up"]          = "treeview:previous",
  ["down"]        = "treeview:next",
  ["left"]        = "treeview:collapse",
  ["right"]       = "treeview:expand",
  ["return"]      = "treeview:open",
  ["escape"]      = "treeview:deselect",
  ["delete"]      = "treeview:delete",
  ["ctrl+return"] = "treeview:new-folder",
  ["lclick"]      = "treeview:select-and-open",
  ["mclick"]      = "treeview:select",
  ["ctrl+lclick"] = "treeview:new-folder"
}

keymap.add {
  ["menu"]   = "treeview-context:show",
  ["return"] = "treeview-context:on-selected",
  ["up"]     = "treeview-context:focus-previous",
  ["down"]   = "treeview-context:focus-next",
  ["escape"] = "treeview-context:hide"
}


-- The config specification used by gui generators
config.plugins.treeview.config_spec = {
  name = "Treeview",
  {
    label = "Size",
    description = "Default treeview width.",
    path = "size",
    type = "number",
    default = 200,
    min = 200,
    get_value = function(value)
      return value / SCALE
    end,
    set_value = function(value)
      return value * SCALE
    end,
    on_apply = function(value)
      -- prevent on_scale_change if applied on non default scale
      if view.current_scale ~= SCALE then view.current_scale = SCALE end
      view.default_size = value
      view:set_target_size("x", value)
    end
  },
  {
    label = "Hide on Startup",
    description = "Show or hide the treeview on startup.",
    path = "visible",
    type = "toggle",
    default = false,
    on_apply = function(value)
      view.visible = not value
    end
  },
  {
    label = "Show Toolbar",
    description = "Show or hide the treeview toolbar.",
    path = "show_toolbar",
    type = "toggle",
    default = true,
    on_apply = function(value)
      if toolbar_view and toolbar_view.visible ~= value then
        toolbar_view:toggle_visible()
      end
    end
  },
  {
    label = "Toolbar Position",
    description = "Dock beside, above or below the treeview, or at the editor's right edge.",
    path = "toolbar_position",
    type = "selection",
    default = "left",
    values = {
      { "Left", "left" },
      { "Bottom", "bottom" },
      { "Top", "top" },
      { "Right", "right" }
    },
    ---Apply saved or edited docking to each attached tree toolbar in the current layout.
    ---@param position "left"|"bottom"|"top"|"right" Toolbar docking position
    on_apply = function(position)
      for _, view in ipairs(core.root_view.root_node:get_children()) do
        if view:extends(TreeView) and view.toolbar then view:set_toolbar_position(position) end
      end
    end
  },
  {
    label = "Show Hidden",
    description = "Show hidden files and directories.",
    path = "show_hidden",
    type = "toggle",
    default = false,
    on_apply = function(value)
      view.show_hidden = value
      view:invalidate_cache()
    end
  },
  {
    label = "Show Ignored",
    description = "Show ignored files and directories.",
    path = "show_ignored",
    type = "toggle",
    default = false,
    on_apply = function(value)
      view.show_ignored = value
      view:invalidate_cache()
    end
  },
  {
    label = "Highlight Focused File",
    description = "Selects the file you are editing on the treeview.",
    path = "highlight_focused_file",
    type = "toggle",
    default = true
  },
  {
    label = "Expand Directories To Focused File",
    description = "Automatically expands directories to select focused file.",
    path = "expand_dirs_to_focused_file",
    type = "toggle",
    default = false
  },
  {
    label = "Scroll To Focused File",
    description = "Automatically scrolls the treeview to focused file.",
    path = "scroll_to_focused_file",
    type = "toggle",
    default = false
  },
  {
    label = "Animate Scroll To Focused File",
    description = "Smoothly scroll to focused file.",
    path = "animate_scroll_to_focused_file",
    type = "toggle",
    default = true
   }
}

-- Return the treeview with toolbar and contextmenu to allow
-- user or plugin modifications
view.toolbar = toolbar_view
view.contextmenu = menu

local entries = {{
  id = "treeview", text = "Treeview", command = "treeview:toggle",
  ---Reflect the tree's requested visibility when opening or visiting this entry.
  ---@return boolean checked Whether TreeView is shown
  checked = function() return view.visible end
}}
if toolbar_view then
  entries[#entries + 1] = {
    id = "toolbar", text = "Toolbar", command = "toolbar:toggle",
    ---Reflect requested toolbar visibility, independent of hidden horizontal docking.
    ---@return boolean checked Whether the user has enabled the toolbar
    checked = function() return toolbar_view.visible end
  }
end
entries[#entries + 1] = {
  id = "treeview-options", text = "Treeview Options", items = {
    {
      id = "hidden", text = "Show Hidden Files", command = "treeview:toggle-hidden",
      ---Reflect the tree's hidden-file filter when opening or visiting the entry.
      ---@return boolean checked Whether hidden files are shown
      checked = function() return view.show_hidden end
    },
    {
      id = "ignored", text = "Show Ignored Files", command = "treeview:toggle-ignored",
      ---Reflect the tree's ignored-file filter when opening or visiting the entry.
      ---@return boolean checked Whether ignored files are shown
      checked = function() return view.show_ignored end
    }
  }
}
core.menu_view:register({ "view" }, entries, "treeview")
core.menu_view:register({ "view", "focus" }, {
  { id = "treeview", text = "Focus Treeview", command = "treeview:toggle-focus" }
}, "treeview-focus")

return view
