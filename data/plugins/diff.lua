-- mod-version:3
local core = require "core"
local config = require "core.config"
local command = require "core.command"
local common = require "core.common"
local style = require "core.style"
local DocView = require "core.docview"
local Doc = require "core.doc"
local View = require "core.view"

local element_a = nil
local element_b = nil
local element_a_text = nil
local element_b_text = nil

---@class core.diffview : core.view
---@field doc_view_a core.docview
---@field doc_view_b core.docview
---@field a_changes diff.changes[]
---@field b_changes diff.changes[]
---@field is_string boolean
local DiffView = View:extend()

function DiffView:new(a, b, is_string)
  DiffView.super.new(self)

  self.scrollable = true
  self.is_string = is_string or false

  local doc_a, doc_b
  if not is_string then
    doc_a = Doc(common.basename(a), a)
    doc_b = Doc(common.basename(b), b)
  else
    doc_a = Doc("file_a.txt", "file_a.txt", true)
    doc_a:insert(1, 1, a)
    doc_b = Doc("file_b.txt", "file_b.txt", true)
    doc_b:insert(1, 1, b)
  end

  self.doc_view_a = DocView(doc_a)
  self.doc_view_b = DocView(doc_b)

  self.a_spaces = {}
  self.b_spaces = {}
  self.a_changes = {}
  self.b_changes = {}

  core.add_thread(function()
    local ai, bi = 1, 1
    local a_offset, b_offset = 0, 0
    local a_offset_total, b_offset_total = 0, 0
    local a_len = #self.doc_view_a.doc.lines
    local b_len = #self.doc_view_b.doc.lines

    for edit in diff.diff_iter(self.doc_view_a.doc.lines, self.doc_view_b.doc.lines) do
      if edit.tag == "equal" or edit.tag == "modify" then
        -- Assign gaps for this line
        self.a_spaces[ai] = { a_offset, a_offset_total }
        self.b_spaces[bi] = { b_offset, b_offset_total }

        -- Insert inline diffs if present
        if edit.a then
          table.insert(self.a_changes, {
            tag = edit.tag,
            changes = diff.inline_diff(edit.b or "", edit.a)
          })
          ai = ai + 1
          a_offset = 0
        end
        if edit.b then
          table.insert(self.b_changes, {
            tag = edit.tag,
            changes = diff.inline_diff(edit.a or "", edit.b)
          })
          bi = bi + 1
          b_offset = 0
        end

      elseif edit.tag == "delete" then
        -- Lines only in A (deleted from B)
        if edit.a then
          self.a_spaces[ai] = { a_offset, a_offset_total }
          table.insert(self.a_changes, { tag = "delete" })
          ai = ai + 1
          -- Increase gap on B side because these lines are missing in B
          b_offset = b_offset + 1
          b_offset_total = b_offset_total + 1
        end

      elseif edit.tag == "insert" then
        -- Lines only in B (inserted in B)
        if edit.b then
          self.b_spaces[bi] = { b_offset, b_offset_total }
          table.insert(self.b_changes, { tag = "insert" })
          bi = bi + 1
          -- Increase gap on A side because these lines are missing in A
          a_offset = a_offset + 1
          a_offset_total = a_offset_total + 1
        end

      elseif edit.tag == "replace" then
        -- Replace: treat as delete + insert
        if edit.a then
          self.a_spaces[ai] = { a_offset, a_offset_total }
          table.insert(self.a_changes, { tag = "replace" })
          ai = ai + 1
        end
        if edit.b then
          self.b_spaces[bi] = { b_offset, b_offset_total }
          table.insert(self.b_changes, { tag = "replace" })
          bi = bi + 1
        end
        -- Increase offsets for gaps on both sides
        a_offset = a_offset + (edit.b and 1 or 0)
        a_offset_total = a_offset_total + (edit.b and 1 or 0)
        b_offset = b_offset + (edit.a and 1 or 0)
        b_offset_total = b_offset_total + (edit.a and 1 or 0)
      end

      coroutine.yield()
    end

    -- Fill trailing lines spaces after diff ends
    while ai <= a_len do
      self.a_spaces[ai] = self.a_spaces[ai] or { a_offset, a_offset_total }
      ai = ai + 1
    end
    while bi <= b_len do
      self.b_spaces[bi] = self.b_spaces[bi] or { b_offset, b_offset_total }
      bi = bi + 1
    end
  end)

  self:patch_views()
end

function DiffView:get_name()
  return not self.is_string and "Files Comparison" or "Strings Comparison"
end

function DiffView:on_mouse_pressed(button, x, y, clicks)
  if
    DiffView.super.on_mouse_pressed(self, button, x, y, clicks)
    or
    self.doc_view_a:on_mouse_pressed(button, x, y, clicks)
    or
    self.doc_view_b:on_mouse_pressed(button, x, y, clicks)
  then
    return true
  end
  for _, view in ipairs({self.doc_view_a, self.doc_view_b}) do
    if
      x >= view.position.x
      and
      x <= view.position.x + view.size.x
    then
      core.set_active_view(view)
      break
    end
  end
end

function DiffView:on_mouse_released(...)
  DiffView.super.on_mouse_released(self, ...)
  self.doc_view_a:on_mouse_released(...)
  self.doc_view_b:on_mouse_released(...)
end

function DiffView:on_mouse_moved(...)
  if DiffView.super.on_mouse_moved(self, ...) then
    if self.v_scrollbar.dragging then
      self.doc_view_a.scroll.to.y = self.scroll.y
      self.doc_view_b.scroll.to.y = self.scroll.y
    end
    return true
  end
  self.doc_view_a:on_mouse_moved(...)
  self.doc_view_b:on_mouse_moved(...)
end

function DiffView:on_mouse_left(...)
  DiffView.super.on_mouse_left(self, ...)
  self.doc_view_a:on_mouse_left(...)
  self.doc_view_b:on_mouse_left(...)
end

function DiffView:on_mouse_wheel(y, x)
  self.doc_view_a.scroll.to.y = self.doc_view_a.scroll.to.y + y * -config.mouse_wheel_scroll
  self.doc_view_b.scroll.to.y = self.doc_view_b.scroll.to.y + y * -config.mouse_wheel_scroll
end

function DiffView:on_scale_change(...)
  DiffView.super.on_scale_change(self, ...)
  self.doc_view_a:on_scale_change(...)
  self.doc_view_b:on_scale_change(...)
end

function DiffView:on_touch_moved(...)
  DiffView.super.on_touch_moved(self, ...)
  self.doc_view_a:on_touch_moved(...)
  self.doc_view_b:on_touch_moved(...)
end

function DiffView:get_scrollable_size()
  local lc = math.max(#self.doc_view_a.doc.lines, #self.doc_view_b.doc.lines)
  if not config.scroll_past_end then
    local _, _, _, h_scroll = self.h_scrollbar:get_track_rect()
    return self.doc_view_a:get_line_height() * (lc) + style.padding.y * 2 + h_scroll
  end
  return self.doc_view_a:get_line_height() * (lc - 1) + self.size.y
end

local delete_color = {common.color "rgba(200, 84, 84, 0.15)"}
local insert_color = {common.color "rgba(121, 199, 114, 0.15)"}
local delete_inline_color = {common.color "rgba(200, 84, 84, 0.20)"}
local insert_inline_color = {common.color "rgba(121, 199, 114, 0.20)"}

---@param parent core.diffview
---@param self core.docview
---@param line integer
---@param x number
---@param y number
---@param changes diff.changes[]
local function draw_line_text_override(parent, self, line, x, y, changes)
  y = y + self:get_line_text_y_offset()
  local h = self:get_line_height()
  local change = changes[line]
  if change and change.tag ~= "equal" then
    if change.tag == "delete" then
      renderer.draw_rect(self.position.x, y, self.size.x, h, delete_color)
    elseif change.tag == "insert" then
      renderer.draw_rect(self.position.x, y, self.size.x, h, insert_color)
    else
      if change.changes then
        if changes == parent.a_changes then
          renderer.draw_rect(self.position.x, y, self.size.x, h, delete_color)
        else
          renderer.draw_rect(self.position.x, y, self.size.x, h, insert_color)
        end
        ---@type diff.changes[]
        local mods = change.changes
        local text = ""
        for i, edit in ipairs(mods) do
          if edit.tag == "insert" then
            text = text .. edit.val
            local tx = self:get_col_x_offset(
              line, i - (changes == parent.b_changes and 1 or 0)
            )
            local w = self:get_font():get_width(edit.val);
            renderer.draw_rect(
              x + tx, y, w, h,
              changes == parent.a_changes
                and delete_inline_color
                or insert_inline_color
            )
          end
        end
      end
    end
  end
end

function DiffView:patch_views()
  local parent = self

  local a_draw_line_text = self.doc_view_a.draw_line_text
  function parent.doc_view_a:draw_line_text(line, x, y)
    draw_line_text_override(parent, self, line, x, y, parent.a_changes)
    local lh = a_draw_line_text(self, line, x, y)
    return lh
  end

  local b_draw_line_text = self.doc_view_b.draw_line_text
  function parent.doc_view_b:draw_line_text(line, x, y)
    draw_line_text_override(parent, self, line, x, y, parent.b_changes)
    local lh = b_draw_line_text(self, line, x, y)
    return lh
  end

  local a_draw_line_gutter = self.doc_view_a.draw_line_gutter
  function parent.doc_view_a:draw_line_gutter(line, x, y, width)
    local gaps = parent.a_spaces
    local offset = (gaps[line] and gaps[line][2] or 0) * self:get_line_height()
    local lh = a_draw_line_gutter(self, line, x, y + offset, width)
    return lh
  end

  local b_draw_line_gutter = self.doc_view_b.draw_line_gutter
  function parent.doc_view_b:draw_line_gutter(line, x, y, width)
    local gaps = parent.b_spaces
    local offset = (gaps[line] and gaps[line][2] or 0) * self:get_line_height()
    local lh = b_draw_line_gutter(self, line, x, y + offset, width)
    return lh
  end

  local a_draw_line_body = self.doc_view_a.draw_line_body
  function parent.doc_view_a:draw_line_body(line, x, y)
    local gaps = parent.a_spaces
    local gaps_h = 0
    if gaps[line] then
      gaps_h = self:get_line_height() * (gaps[line][2] or 0)
    end
    local lh = a_draw_line_body(self, line, x, y + gaps_h)
    return lh
  end

  local b_draw_line_body = self.doc_view_b.draw_line_body
  function parent.doc_view_b:draw_line_body(line, x, y)
    local gaps = parent.b_spaces
    local gaps_h = 0
    if gaps[line] then
      gaps_h = self:get_line_height() * (gaps[line][2] or 0)
    end
    local lh = b_draw_line_body(self, line, x, y + gaps_h)
    return lh
  end

  function parent.doc_view_a:get_visible_line_range()
    local _, oy, _, y2 = self:get_content_bounds()
    local lh = self:get_line_height()
    local lines = self.doc.lines
    local minline, maxline = 1, #lines
    local a_spaces = parent.a_spaces

    local y = style.padding.y
    for i = 1, #lines do
      local gap = (a_spaces[i] and a_spaces[i][1] or 0) * lh
      local h = lh
      local total = y + gap + h
      if total > oy then
        minline = i
        break
      end
      y = total
    end

    y = style.padding.y
    for i = 1, #lines do
      local gap = (a_spaces[i] and a_spaces[i][1] or 0) * lh
      local h = lh
      local total = y + gap + h
      if total > y2 then
        maxline = i
        break
      end
      y = total
    end

    return minline, maxline
  end

  function parent.doc_view_b:get_visible_line_range()
    local _, oy, _, y2 = self:get_content_bounds()
    local lh = self:get_line_height()
    local lines = self.doc.lines
    local minline, maxline = 1, #lines
    local b_spaces = parent.b_spaces

    local y = style.padding.y
    for i = 1, #lines do
      local gap = (b_spaces[i] and b_spaces[i][1] or 0) * lh
      local h = lh
      local total = y + gap + h
      if total > oy then
        minline = i
        break
      end
      y = total
    end

    y = style.padding.y
    for i = 1, #lines do
      local gap = (b_spaces[i] and b_spaces[i][1] or 0) * lh
      local h = lh
      local total = y + gap + h
      if total > y2 then
        maxline = i
        break
      end
      y = total
    end

    return minline, maxline
  end

end

function DiffView:update()
  DiffView.super.update(self)
  local _, _, scroll_w, _ = self.v_scrollbar:_get_track_rect_normal()

  self.doc_view_a.position.x = self.position.x
  self.doc_view_a.position.y = self.position.y
  self.doc_view_a.size.x = (self.size.x / 2) - scroll_w
  self.doc_view_a.size.y = self.size.y

  self.doc_view_b.position.x = (self.position.x + self.size.x / 2) - scroll_w
  self.doc_view_b.position.y = self.position.y
  self.doc_view_b.size.x = (self.size.x / 2) - scroll_w
  self.doc_view_b.size.y = self.size.y

  self.doc_view_a:update()
  self.doc_view_b:update()
end

function DiffView:draw()
  DiffView.super.draw(self)
  self:draw_background(style.background)
  self.doc_view_a:draw()
  self.doc_view_b:draw()
  self:draw_scrollbar()
end


local function start_compare()
  if not element_a or not element_b then
    core.log("First select something to compare")
    return
  end
  local view = DiffView(element_a, element_b)
  core.root_view:get_active_node_default():add_view(view)
  core.set_active_view(view)
  element_a = nil
  element_b = nil
end

local function start_compare_string()
  if not element_a_text or not element_b_text then
    core.log("First select something to compare")
    return
  end
  local view = DiffView(element_a_text, element_b_text, true)
  core.root_view:get_active_node_default():add_view(view)
  core.set_active_view(view)
  element_a_text = nil
  element_b_text = nil
end


-- Register file compare commands
command.add("core.docview", {
  ["diff:select-file-for-compare"] = function(dv)
    if dv.doc and dv.doc.abs_filename then
      element_a = dv.doc.abs_filename
    end
  end
})

command.add(
  function()
    return element_a and core.active_view and core.active_view:is(DocView),
    core.active_view
  end, {
  ["diff:compare-file-with-selected"] = function(dv)
    if dv.doc and dv.doc.abs_filename then
      element_b = dv.doc.abs_filename
    end
    start_compare()
  end
})


-- Register text compare commands
local function text_select_compare_predicate()
  local is_docview = core.active_view
    and core.active_view:is(DocView)
    and core.active_view.doc
  local has_selection = is_docview and core.active_view.doc:has_any_selection()
  return has_selection, has_selection and core.active_view.doc
end

local function text_compare_with_predicate()
  local is_docview = (element_a_text and core.active_view)
    and (core.active_view:is(DocView) and core.active_view.doc)
  local has_selection = is_docview and core.active_view.doc:has_any_selection()
  return has_selection, has_selection and core.active_view.doc
end

command.add(text_select_compare_predicate, {
  ["diff:select-text-for-compare"] = function(doc)
    element_a_text = doc:get_selection_text()
  end
})

command.add(text_compare_with_predicate, {
  ["diff:compare-text-with-selected"] = function(doc)
    element_b_text = doc:get_selection_text()
    start_compare_string()
  end
})


-- Register context menu items
core.add_thread(function()
  if config.plugins.cotextmenu then
    local contextmenu = require "plugins.contextmenu"

    contextmenu:register(text_select_compare_predicate, {
      contextmenu.DIVIDER,
      {
        text = "Select Text for Compare",
        command = "diff:select-text-for-compare"
      }
    })

    contextmenu:register(text_compare_with_predicate, {
      {
        text = "Compare Text with Selected",
        command = "diff:compare-text-with-selected"
      }
    })
  end
end)


-- Register treeview context menu items
core.add_thread(function()
  if not config.plugins.treeview then return end

  ---@module 'plugins.treeview'
  local TreeView = require "plugins.treeview"
  ---@module 'core.contextmenu'
  local TreeViewMenu = TreeView.contextmenu

  TreeViewMenu:register(
    function()
      return TreeView.hovered_item
        and system.get_file_info(TreeView.hovered_item.abs_filename).type == "file"
    end,
    {
      TreeViewMenu.DIVIDER,
      { text = "Select for Compare", command = "treeview:select-for-compare" }
    }
  )

  TreeViewMenu:register(
    function()
      return element_a and TreeView.hovered_item
        and system.get_file_info(TreeView.hovered_item.abs_filename).type == "file"
    end,
    {
      TreeViewMenu.DIVIDER,
      { text = "Compare with Selected", command = "treeview:compare-with-selected" }
    }
  )

  command.add(
    function()
      if
        TreeView.hovered_item
        and system.get_file_info(
          TreeView.hovered_item.abs_filename
        ).type == "file"
      then
        return true, TreeView.hovered_item.abs_filename
      end
      return false
    end, {
    ["treeview:select-for-compare"] = function(file)
      element_a = file
    end
  })

  command.add(
    function()
      if
        element_a and TreeView.hovered_item
        and system.get_file_info(
          TreeView.hovered_item.abs_filename
        ).type == "file"
      then
        return true, TreeView.hovered_item.abs_filename
      end
      return false
    end, {
    ["treeview:compare-with-selected"] = function(file)
      element_b = file
      start_compare()
    end
  })

end)


return DiffView
