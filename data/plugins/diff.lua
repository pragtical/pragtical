-- mod-version:3
local core = require "core"
local config = require "core.config"
local command = require "core.command"
local common = require "core.common"
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

  self.a_changes = {}
  self.b_changes = {}

  core.add_thread(function()
    for edit in diff.diff_iter(self.doc_view_a.doc.lines, self.doc_view_b.doc.lines) do
      if edit.tag ~= "modify" then
        if edit.a then
          table.insert(self.a_changes, {tag = edit.tag})
        end
        if edit.b then
          table.insert(self.b_changes, {tag = edit.tag})
        end
      else
        if edit.a then
          table.insert(self.a_changes, {
            tag = edit.tag,
            changes = diff.inline_diff(edit.b, edit.a)
          })
        end
        if edit.b then
          table.insert(self.b_changes, {
            tag = edit.tag,
            changes = diff.inline_diff(edit.a, edit.b)
          })
        end
      end
      coroutine.yield()
    end
  end)

  self:patch_views()
end

function DiffView:get_name()
  return not self.is_string and "Files Comparison" or "Strings Comparison"
end

function DiffView:on_mouse_pressed(...)
  DiffView.super.on_mouse_pressed(self, ...)
  self.doc_view_a:on_mouse_pressed(...)
  self.doc_view_b:on_mouse_pressed(...)
end

function DiffView:on_mouse_released(...)
  DiffView.super.on_mouse_released(self, ...)
  self.doc_view_a:on_mouse_released(...)
  self.doc_view_b:on_mouse_released(...)
end

function DiffView:on_mouse_moved(...)
  DiffView.super.on_mouse_moved(self, ...)
  self.doc_view_a:on_mouse_moved(...)
  self.doc_view_b:on_mouse_moved(...)
end

function DiffView:on_mouse_left(...)
  DiffView.super.on_mouse_left(self, ...)
  self.doc_view_a:on_mouse_left(...)
  self.doc_view_b:on_mouse_left(...)
end

function DiffView:on_mouse_wheel(...)
  DiffView.super.on_mouse_wheel(self, ...)
  if self.doc_view_a:on_mouse_wheel(...) then return true end
  if self.doc_view_b:on_mouse_wheel(...) then return true end
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
            local tx = self:get_col_x_offset(line, i)
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
end

function DiffView:update()
  DiffView.super.update(self)
  self.doc_view_a.position.x = self.position.x
  self.doc_view_a.position.y = self.position.y
  self.doc_view_a.size.x = self.size.x / 2
  self.doc_view_a.size.y = self.size.y

  self.doc_view_b.position.x = self.position.x + self.size.x / 2
  self.doc_view_b.position.y = self.position.y
  self.doc_view_b.size.x = self.size.x / 2
  self.doc_view_b.size.y = self.size.y

  self.doc_view_a:update()
  self.doc_view_b:update()
end

function DiffView:draw()
  DiffView.super.draw(self)
  self.doc_view_a:draw()
  self.doc_view_b:draw()
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
