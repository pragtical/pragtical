-- mod-version:3
local core = require "core"
local config = require "core.config"
local command = require "core.command"
local common = require "core.common"
local keymap = require "core.keymap"
local style = require "core.style"
local DocView = require "core.docview"
local Doc = require "core.doc"
local View = require "core.view"

---@type string?
local element_a = nil
---@type string?
local element_b = nil
---@type string?
local element_a_text = nil
---@type string?
local element_b_text = nil
---@type integer
local diff_updater_idx = 0

---@class plugins.diff.view : core.view
---@field doc_view_a core.docview
---@field doc_view_b core.docview
---@field a_changes diff.changes[]
---@field a_changes diff.changes[]
---@field a_gaps table<integer,table<integer,integer>>
---@field b_gaps table<integer,table<integer,integer>>
---@field compare_type plugins.diff.view.type
---@field hovered_sync? plugins.diff.view.hovered_sync
local DiffView = View:extend()

---@enum plugins.diff.view.type
DiffView.type = {
  STRING_FILE = 1,
  FILE_STRING = 2,
  FILE_FILE = 3,
  STRING_STRING = 4
}

---@class plugins.diff.view.hovered_sync
---@field is_a boolean
---@field line integer
---@field target_line integer

---Constructor
---@param a string
---@param b string
---@param compare_type plugins.diff.view.type
function DiffView:new(a, b, compare_type)
  DiffView.super.new(self)

  self.scrollable = true
  self.compare_type = compare_type
  self.hovered_sync = nil
  self.skip_update_diff = false

  local doc_a, doc_b
  if compare_type == DiffView.type.FILE_FILE then
    doc_a = Doc(common.basename(a), a)
    doc_b = Doc(common.basename(b), b)
  elseif compare_type == DiffView.type.STRING_STRING then
    doc_a = Doc("file_a.txt", "file_a.txt", true)
    doc_a:insert(1, 1, a)
    doc_b = Doc("file_b.txt", "file_b.txt", true)
    doc_b:insert(1, 1, b)
  elseif compare_type == DiffView.type.STRING_FILE then
    doc_a = Doc("file_a.txt", "file_a.txt", true)
    doc_a:insert(1, 1, a)
    doc_b = Doc(common.basename(b), b)
  elseif compare_type == DiffView.type.FILE_STRING then
    doc_a = Doc(common.basename(a), a)
    doc_b = Doc("file_b.txt", "file_b.txt", true)
    doc_b:insert(1, 1, b)
  end

  self.doc_view_a = DocView(doc_a)
  self.doc_view_b = DocView(doc_b)

  self.doc_view_a.diff_view_parent = self
  self.doc_view_b.diff_view_parent = self

  self.a_gaps = {}
  self.b_gaps = {}
  self.a_changes = {}
  self.b_changes = {}
  self.views_patched = false

  self:patch_views()
  self:update_diff()
end

function DiffView:get_name()
  if self.compare_type == DiffView.type.FILE_FILE then
    return "Files Comparison"
  elseif self.compare_type == DiffView.type.STRING_STRING then
    return "Strings Comparison"
  elseif self.compare_type == DiffView.type.FILE_STRING then
    return "File->String Comparison"
  elseif self.compare_type == DiffView.type.STRING_FILE then
    return "String->File Comparison"
  end
  return "Diff Viewer"
end

---Updates the registered differences between current side A and B.
function DiffView:update_diff()
  if self.skip_update_diff then self.skip_update_diff = false return end

  -- stop previous update if still running.
  if self.updater_idx then
    for _, thread in pairs(core.threads) do
      if thread.diff_viewer and thread.diff_viewer == self.updater_idx then
        thread.cr = coroutine.create(function() end)
      end
    end
  end

  local idx = core.add_thread(function()
    local ai, bi = 1, 1
    local a_offset, b_offset = 0, 0
    local a_offset_total, b_offset_total = 0, 0
    local a_len = #self.doc_view_a.doc.lines
    local b_len = #self.doc_view_b.doc.lines

    local a_gaps = #self.a_gaps == 0 and self.a_gaps or {}
    local b_gaps = #self.b_gaps == 0 and self.b_gaps or {}
    local a_changes = #self.a_changes == 0 and self.a_changes or {}
    local b_changes = #self.b_changes == 0 and self.b_changes or {}
    for edit in diff.diff_iter(self.doc_view_a.doc.lines, self.doc_view_b.doc.lines) do
      if edit.tag == "equal" or edit.tag == "modify" then
        -- Assign gaps for this line
        a_gaps[ai] = { a_offset, a_offset_total }
        b_gaps[bi] = { b_offset, b_offset_total }

        -- Insert inline diffs if present
        if edit.a then
          table.insert(a_changes, {
            tag = edit.tag,
            changes = diff.inline_diff(edit.b or "", edit.a)
          })
          ai = ai + 1
          a_offset = 0
        end
        if edit.b then
          table.insert(b_changes, {
            tag = edit.tag,
            changes = diff.inline_diff(edit.a or "", edit.b)
          })
          bi = bi + 1
          b_offset = 0
        end

      elseif edit.tag == "delete" then
        -- Lines only in A (deleted from B)
        if edit.a then
          a_gaps[ai] = { a_offset, a_offset_total }
          table.insert(a_changes, { tag = "delete" })
          ai = ai + 1
          -- Increase gap on B side because these lines are missing in B
          b_offset = b_offset + 1
          b_offset_total = b_offset_total + 1
        end

      elseif edit.tag == "insert" then
        -- Lines only in B (inserted in B)
        if edit.b then
          b_gaps[bi] = { b_offset, b_offset_total }
          table.insert(b_changes, { tag = "insert" })
          bi = bi + 1
          -- Increase gap on A side because these lines are missing in A
          a_offset = a_offset + 1
          a_offset_total = a_offset_total + 1
        end
      end

      coroutine.yield()
    end

    -- Fill trailing lines spaces after diff ends
    while ai <= a_len do
      a_gaps[ai] = a_gaps[ai] or { a_offset, a_offset_total }
      ai = ai + 1
    end
    while bi <= b_len do
      b_gaps[bi] = b_gaps[bi] or { b_offset, b_offset_total }
      bi = bi + 1
    end

    self.a_gaps = a_gaps
    self.b_gaps = b_gaps
    self.a_changes = a_changes
    self.b_changes = b_changes

    self.updater_idx = nil

    self.doc_view_b.scroll.to.y = self.doc_view_a.scroll.y
    self.doc_view_b.scroll.y = self.doc_view_a.scroll.y
  end)

  core.threads[idx].diff_viewer = diff_updater_idx
  self.updater_idx = diff_updater_idx
  diff_updater_idx = diff_updater_idx + 1
end

function DiffView:sync(line, target_line, is_a)
  local changes = is_a and self.a_changes or self.b_changes
  local target_changes = is_a and self.b_changes or self.a_changes
  local target_gaps = is_a and self.b_gaps or self.a_gaps

  ---@type core.docview
  local from = is_a and self.doc_view_a or self.doc_view_b
  ---@type core.docview
  local to = is_a and self.doc_view_b or self.doc_view_a

  local l = line
  local tag = changes[l].tag
  local text = ""
  local total = 0
  while changes[l] and changes[l].tag == tag do
    total = total + 1
    changes[l] = {tag = "equal"}
    text = text .. from.doc.lines[l]
    l = l + 1
  end
  if tag == "modify" then
    to.doc:set_selection(target_line, 1, target_line, math.huge)
    to.doc:replace(function() return text:sub(1, #text-1) end)
    target_changes[target_line] = {tag = "equal"}
  else
    to.doc:insert(target_line, math.huge, "\n" .. text:sub(1, #text - 1))

    -- update target changes and target gaps
    local changes_inserts = {}

    for _=1, total do
      table.insert(changes_inserts, {tag = "equal"})
    end

    common.splice(target_changes, target_line, 0, changes_inserts)

    local gaps_inserts = {}
    local gaps = {0, 0}

    if target_gaps[target_line+1] then
      gaps = {0, target_gaps[target_line+1][2] - total}
      target_gaps[target_line+1] = {table.unpack(gaps)}
      for i=target_line+2, #target_gaps do
        target_gaps[i][2] = target_gaps[i][2] - total
      end
    end

    for _=1, total do
      table.insert(gaps_inserts, {table.unpack(gaps)})
    end

    common.splice(target_gaps, target_line, 0, gaps_inserts)
  end
end

function DiffView:sync_selected()
  local view, changes, to_view, is_a

  if core.active_view == self.doc_view_a then
    view = self.doc_view_a
    to_view = self.doc_view_b
    changes = self.a_changes
    is_a = true
  elseif core.active_view == self.doc_view_b then
    view = self.doc_view_b
    to_view = self.doc_view_a
    changes = self.b_changes
  end

  if not view then return end

  local line = view.doc:get_selection()
  local tag = changes[line].tag
  if tag == "equal" then
    core.error("No valid change selected")
    return
  end

  while changes[line-1] and changes[line-1].tag == tag do
    line = line - 1
  end

  view.doc:set_selection(line, 1, line, 1)

  local _, y = view:get_line_screen_position(line, 1)
  to_view.scroll.to.y =  view.scroll.y
  to_view.scroll.y =  view.scroll.y

  local target_line = to_view:resolve_screen_position(
    to_view.position.x + style.padding.x, y
  )

  self:sync(line, target_line, is_a)
end

function DiffView:on_mouse_pressed(button, x, y, clicks)
  if button == "left" and self.hovered_sync then
    self:sync(
      self.hovered_sync.line,
      self.hovered_sync.target_line,
      self.hovered_sync.is_a
    )
    self.hovered_sync = nil
    return
  end
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

---@param self plugins.diff.view
local function check_hovered_sync(self, x, y)
  local x1 = self.doc_view_a.position.x + self.doc_view_a.size.x
  local x2 = self.doc_view_b.position.x + style.padding.x / 2

  if x >= x1 and x <= x2 then
    ---@type integer
    local line
    ---@type integer
    local target_line
    ---@type diff.changes[]
    local changes
    ---@type boolean
    local is_a = false

    -- hovering side A
    if x <= x1 + ((x2 - x1) / 2) then
      line = self.doc_view_a:resolve_screen_position(x1 - style.padding.x, y)
      target_line = self.doc_view_b:resolve_screen_position(x2 - style.padding.x, y)
      changes = self.a_changes
      is_a = true

    -- hovering side B
    elseif x >= x1 + ((x2 - x1) / 2) + style.padding.x / 2  then
      line = self.doc_view_b:resolve_screen_position(x2 - style.padding.x, y)
      target_line = self.doc_view_a:resolve_screen_position(x1 - style.padding.x, y)
      changes = self.b_changes
    end

    -- check if hovering valid line and save it
    if line and changes[line] and changes[line].tag ~= "equal" then
      if not changes[line-1] or changes[line-1].tag ~= changes[line].tag then
        self.hovered_sync = {
          is_a = is_a,
          line = line,
          target_line = target_line
        }
        return
      end
    end
  end

  self.hovered_sync = nil
end

function DiffView:on_mouse_moved(...)
  if DiffView.super.on_mouse_moved(self, ...) then
    if self.v_scrollbar.dragging then
      self.doc_view_a.scroll.to.y = self.scroll.y
      self.doc_view_b.scroll.to.y = self.scroll.y
      return true
    end
  end
  self.doc_view_a:on_mouse_moved(...)
  if self.doc_view_a:scrollbar_dragging() then
    self.doc_view_b.scroll.y = self.doc_view_a.scroll.y
    self.doc_view_b.scroll.to.y = self.doc_view_a.scroll.y
    return true
  end
  self.doc_view_b:on_mouse_moved(...)
  if self.doc_view_b:scrollbar_dragging() then
    self.doc_view_a.scroll.y = self.doc_view_b.scroll.y
    self.doc_view_a.scroll.to.y = self.doc_view_b.scroll.y
    return true
  end
  check_hovered_sync(self, ...)
end

function DiffView:on_mouse_left(...)
  DiffView.super.on_mouse_left(self, ...)
  self.doc_view_a:on_mouse_left(...)
  self.doc_view_b:on_mouse_left(...)
end

function DiffView:on_mouse_wheel(y, x)
  if keymap.modkeys["shift"] then
    x = y
    y = 0
  end
  if y and y ~= 0 then
    self.doc_view_a.scroll.to.y = self.doc_view_a.scroll.to.y + y * -config.mouse_wheel_scroll
    self.doc_view_b.scroll.to.y = self.doc_view_b.scroll.to.y + y * -config.mouse_wheel_scroll
  end
  if x and x ~= 0 then
    self.doc_view_a.scroll.to.x = self.doc_view_a.scroll.to.x + x * -config.mouse_wheel_scroll
    self.doc_view_b.scroll.to.x = self.doc_view_b.scroll.to.x + x * -config.mouse_wheel_scroll
  end
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
local modify_color = {common.color "rgba(202, 173, 85, 0.15)"}
local delete_inline_color = {common.color "rgba(200, 84, 84, 0.20)"}
local insert_inline_color = {common.color "rgba(121, 199, 114, 0.20)"}
local delete_color_opaque = {common.color "rgba(200, 84, 84, 1)"}
local insert_color_opaque = {common.color "rgba(121, 199, 114, 1)"}
local modify_color_opaque = {common.color "rgba(202, 173, 85, 1)"}

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
  if self.views_patched then return end
  self.views_patched = true

  local parent = self

  local function wrap_draw_line_text(doc_view, is_a)
    local orig = doc_view.draw_line_text
    doc_view.draw_line_text = function(self, line, x, y)
      local changes = is_a and parent.a_changes or parent.b_changes
      draw_line_text_override(parent, self, line, x, y, changes)
      if
        changes[line] and changes[line].tag ~= "equal"
        and
        (not changes[line-1] or changes[line].tag ~= changes[line-1].tag)
      then
        local ax, icon
        local pad = style.padding.x / 2
        if is_a then
          icon = ">"
          ax = self.position.x + self.size.x + pad
        else
          icon = "<"
          ax = self.position.x - pad
        end
        local color = style.text
        if parent.hovered_sync and parent.hovered_sync.is_a == is_a then
          if parent.hovered_sync.line == line then
            color = style.caret
          end
        end
        core.root_view:defer_draw(function()
          core.push_clip_rect(parent.position.x, parent.position.y, parent.size.x, parent.size.y)
          local ay = y + (self:get_line_height() / 2) - (style.icon_font:get_height() / 2)
          renderer.draw_text(style.icon_font, icon, ax, ay, color)
          core.pop_clip_rect()
        end)
      end
      return orig(self, line, x, y)
    end
  end

  local function wrap_get_line_screen_position(doc_view, is_a)
    doc_view.get_line_screen_position = function(self, line, col)
      local x, y = self:get_content_offset()
      local lh = self:get_line_height()
      local gaps = is_a and parent.a_gaps or parent.b_gaps
      local gap_y = (gaps[line] and gaps[line][2] or 0) * lh
      y = y + (line - 1) * lh + gap_y + style.padding.y
      if col then
        return x + self:get_gutter_width() + self:get_col_x_offset(line, col), y
      else
        return x + self:get_gutter_width(), y
      end
    end
  end

  local function wrap_resolve_screen_position(doc_view, is_a)
    doc_view.resolve_screen_position = function(self, x, y)
      local lines = self.doc.lines
      local lh = self:get_line_height()
      local gaps = is_a and parent.a_gaps or parent.b_gaps

      for i = 1, #lines do
        local line_x, line_y = self:get_line_screen_position(i)
        local next_y
        if i < #lines then
          local _
          _, next_y = self:get_line_screen_position(i + 1)
        else
          next_y = line_y + lh + ((gaps[i] and gaps[i][1] or 0) * lh)
        end

        if y >= line_y and y < next_y then
          local col = self:get_x_offset_col(i, x - line_x)
          return i, col
        end
      end

      local last = #lines
      local line_x, _ = self:get_line_screen_position(last)
      return last, self:get_x_offset_col(last, x - line_x)
    end
  end

  local function wrap_get_visible_line_range(doc_view, is_a)
    doc_view.get_visible_line_range = function(self)
      local _, oy, _, y2 = self:get_content_bounds()
      local lh = self:get_line_height()
      local lines = self.doc.lines
      local minline, maxline = 1, #lines
      local gaps = is_a and parent.a_gaps or parent.b_gaps

      local y = style.padding.y
      for i = 1, #lines do
        local gap = (gaps[i] and gaps[i][2] or 0) * lh
        local h = lh
        local total = y + h
        y = total
        if total + gap > oy then
          minline = i
          break
        end
      end

      for i = minline, #lines do
        local gap = (gaps[i] and gaps[i][2] or 0) * lh
        local h = lh
        local total = y + h
        y = total
        if total + gap > y2 then
          maxline = i
          break
        end
      end

      return minline, maxline
    end
  end

  local function wrap_get_scrollable_size(doc_view, is_a)
    doc_view.get_scrollable_size = function(self)
      local gaps = is_a and parent.a_gaps or parent.b_gaps
      local lc = #self.doc.lines
      if not config.scroll_past_end then
        local _, _, _, h_scroll = self.h_scrollbar:get_track_rect()
        return self:get_line_height() * (lc) + style.padding.y * 2 + h_scroll
      end
      return self:get_line_height() * ((lc + (gaps[lc] and gaps[lc][2] or 0)) - 1) + self.size.y
    end
  end

  local function wrap_scroll_to_line(doc_view, is_a)
    local orig = doc_view.scroll_to_line
    doc_view.scroll_to_line = function(self, ...)
      orig(self, ...)
      if is_a then
        parent.doc_view_b.scroll.y = self.scroll.y
        parent.doc_view_b.scroll.to.y = self.scroll.y
      else
        parent.doc_view_a.scroll.y = self.scroll.y
        parent.doc_view_a.scroll.to.y = self.scroll.y
      end
    end
  end

  local function wrap_draw(doc_view)
    doc_view.draw = function(self)
      self:draw_background(style.background)
      local _, indent_size = self.doc:get_indent_info()
      self:get_font():set_tab_size(indent_size)

      local minline, maxline = self:get_visible_line_range()
      local lh = self:get_line_height()

      local gw, gpad = self:get_gutter_width()
      for i = minline, maxline do
        local _, y = self:get_line_screen_position(i)
        self:draw_line_gutter(i, self.position.x, y, gpad and gw - gpad or gw)
      end

      local pos = self.position
      -- the clip below ensure we don't write on the gutter region. On the
      -- right side it is redundant with the Node's clip.
      core.push_clip_rect(pos.x + gw, pos.y, self.size.x - gw, self.size.y)
      for i = minline, maxline do
        local x, y = self:get_line_screen_position(i)
        y = y + (self:draw_line_body(i, x, y) or lh)
      end
      self:draw_overlay()
      core.pop_clip_rect()

      self:draw_scrollbar()
    end
  end

  local function wrap_doc_raw_insert(doc_view)
    local orig = doc_view.doc.raw_insert
    doc_view.doc.raw_insert = function(...)
      parent:update_diff()
      return orig(...)
    end
  end

  local function wrap_doc_raw_remove(doc_view)
    local orig = doc_view.doc.raw_remove
    doc_view.doc.raw_remove = function(...)
      parent:update_diff()
      return orig(...)
    end
  end

  ---@param changes diff.changes[]
  local function has_changes(changes)
    for _, change in ipairs(changes) do
      if change.tag ~= "equal" then
        return true
      end
    end
    return false
  end

  local function wrap_prev_change(doc_view, is_a)
    doc_view.prev_change = function(self)
      local changes = is_a and parent.a_changes or parent.b_changes
      if not has_changes(changes) then return end

      local line = self.doc:get_selection()
      if not changes[line] then return end
      local tag = changes[line].tag
      if line == 1 then
        line = #self.doc.lines
      else
        line = line - 1
      end

      local target = line
      local in_first_block = tag ~= "equal" and true or false
      local in_second_block = tag == "equal" and true or false

      while true do
        if not changes[target] then break end
        if in_first_block then
          if changes[target].tag ~= tag then
            in_first_block = false
            in_second_block = true
          end
        elseif in_second_block and changes[target].tag ~= "equal" then
          if changes[target-1].tag ~= changes[target].tag then
            break
          end
        end
        target = target - 1
        if target == 1 then
          if changes[target].tag == "equal" then
            target = #self.doc.lines
          else
            break
          end
        elseif target < 1 then
          target = #self.doc.lines
        end
      end

      self.doc:set_selection(target, 1, target, 1)
      self:scroll_to_line(target, false, true)
    end
  end

  local function wrap_next_change(doc_view, is_a)
    doc_view.next_change = function(self)
      local changes = is_a and parent.a_changes or parent.b_changes
      if not has_changes(changes) then return end

      local count_lines = #self.doc.lines
      local line = self.doc:get_selection()
      if not changes[line] then return end
      local tag = changes[line].tag
      if line == count_lines then
        line = 1
      else
        line = line + 1
      end

      local target = line
      local in_first_block = tag ~= "equal" and true or false
      local in_second_block = tag == "equal" and true or false

      while true do
        if not changes[target] then break end
        if in_first_block then
          if changes[target].tag ~= tag then
            in_first_block = false
            in_second_block = true
          end
        elseif in_second_block and changes[target].tag ~= "equal" then
          if changes[target-1].tag ~= changes[target].tag then
            break
          end
        end
        target = target + 1
        if target == count_lines then
          if changes[target].tag == "equal" then
            target = 1
          else
            break
          end
        elseif target > count_lines then
          target = 1
        end
      end

      self.doc:set_selection(target, 1, target, 1)
      self:scroll_to_line(target, false, true)
    end
  end

  -- Apply to both views with dynamic referencing
  for _, side in ipairs {
    {view = self.doc_view_a, is_a = true},
    {view = self.doc_view_b, is_a = false}
  } do
    wrap_draw_line_text(side.view, side.is_a)
    wrap_get_line_screen_position(side.view, side.is_a)
    wrap_resolve_screen_position(side.view, side.is_a)
    wrap_get_visible_line_range(side.view, side.is_a)
    wrap_get_scrollable_size(side.view, side.is_a)
    wrap_scroll_to_line(side.view, side.is_a)
    wrap_draw(side.view)
    wrap_doc_raw_insert(side.view)
    wrap_doc_raw_remove(side.view)
    wrap_prev_change(side.view, side.is_a)
    wrap_next_change(side.view, side.is_a)
  end
end

function DiffView:draw_scrollbar()
  DiffView.super.draw_scrollbar(self)

  for _, side in ipairs {
    {view = self.doc_view_a, changes = self.a_changes},
    {view = self.doc_view_b, changes = self.b_changes},
  } do
    local view = side.view
    local changes = side.changes
    local scrollbar = view.v_scrollbar

    local lh = view:get_line_height()
    local full_h = view:get_scrollable_size()
    local visible_h = view.size.y
    local x, y, w, h = scrollbar:get_track_rect()

    local scroll_range = math.max(1, full_h - visible_h)

    -- Step 1: group consecutive lines of same change tag
    local change_lines = {}
    for line, change in pairs(changes) do
      change_lines[#change_lines+1] = { line = line, tag = change.tag }
    end
    table.sort(change_lines, function(a, b) return a.line < b.line end)

    local i = 1
    while i <= #change_lines do
      local tag = change_lines[i].tag
      local start_line = change_lines[i].line
      local end_line = start_line

      -- Group consecutive lines with same tag
      while i + 1 <= #change_lines and
            change_lines[i+1].tag == tag and
            change_lines[i+1].line == end_line + 1 do
        i = i + 1
        end_line = change_lines[i].line
      end

      -- Draw block for [start_line, end_line]
      local color =
        tag == "insert" and insert_color_opaque
        or tag == "delete" and delete_color_opaque
        or tag == "modify" and modify_color_opaque

      if color then
        local scroll_y_start = (start_line - 1) * lh
        local scroll_y_end = (end_line) * lh
        local ratio_start = scroll_y_start / scroll_range
        local ratio_end = scroll_y_end / scroll_range
        local marker_y = y + ratio_start * h
        local marker_h = math.max(2, (ratio_end - ratio_start) * h) * SCALE

        renderer.draw_rect(x, marker_y, w, marker_h, color)

        local sx, _, sw = self.v_scrollbar:get_track_rect()
        renderer.draw_rect(sx, marker_y, sw, marker_h, color)
      end

      i = i + 1
    end
  end
end

function DiffView:update()
  DiffView.super.update(self)
  local _, _, scroll_w, _ = self.v_scrollbar:_get_track_rect_normal()

  self.doc_view_a.position.x = self.position.x
  self.doc_view_a.position.y = self.position.y
  self.doc_view_a.size.x = (self.size.x / 2) - scroll_w - 20 * SCALE
  self.doc_view_a.size.y = self.size.y

  self.doc_view_b.position.x = (self.position.x + self.size.x / 2) - scroll_w + 20 * SCALE
  self.doc_view_b.position.y = self.position.y
  self.doc_view_b.size.x = (self.size.x / 2) - scroll_w - 20 * SCALE
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


-- Helper functions to start file to file or string to string diff viewer.
local function start_compare()
  if not element_a or not element_b then
    core.log("First select something to compare")
    return
  end
  local view = DiffView(element_a, element_b, DiffView.type.FILE_FILE)
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
  local view = DiffView(element_a_text, element_b_text, DiffView.type.STRING_STRING)
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


-- Register changes navigation and sync commands
command.add(
  function()
    return core.active_view
        and core.active_view:is(DocView)
        and core.active_view.diff_view_parent,
      core.active_view
  end, {
  ["diff:prev-change"] = function(dv)
    dv:prev_change()
  end,

  ["diff:next-change"] = function(dv)
    dv:next_change()
  end,

  ["diff:sync-change"] = function(dv)
    dv.diff_view_parent:sync_selected()
  end
})

keymap.add({
  ["ctrl+alt+,"] = "diff:prev-change",
  ["ctrl+alt+."] = "diff:next-change",
  ["ctrl+return"] = "diff:sync-change",
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


---Functionality to view the textual differences of two elements.
---@class plugins.diff
local diff = {
  ---The differences viewer exposed for extensiblity.
  ---@type plugins.diff.view
  Viewer = DiffView
}

---Helper differences view to rootview add.
---@param view plugins.diff.view
local function compare_add_to_root_node(view)
  core.root_view:get_active_node_default():add_view(view)
  core.set_active_view(view)
end

---Helper differences starter.
---@param a string
---@param b string
---@param ct plugins.diff.view.type
---@param noshow boolean
---@return plugins.diff.view
local function compare_start(a, b, ct, noshow)
  local view = DiffView(a, b, ct)
  if not noshow then
    compare_add_to_root_node(view)
  end
  return view
end

---Create a file to file diff viewer.
---@param a string
---@param b string
---@param noshow boolean If true doesn't adds to the rootview
---@return plugins.diff.view
function diff.file_to_file(a, b, noshow)
  return compare_start(a, b, DiffView.type.FILE_FILE, noshow)
end

---Create a string to string diff viewer.
---@param a string
---@param b string
---@param noshow boolean If true doesn't adds to the rootview
---@return plugins.diff.view
function diff.string_to_string(a, b, noshow)
  return compare_start(a, b, DiffView.type.STRING_STRING, noshow)
end

---Create a file to string diff viewer.
---@param a string
---@param b string
---@param noshow boolean If true doesn't adds to the rootview
---@return plugins.diff.view
function diff.file_to_string(a, b, noshow)
  return compare_start(a, b, DiffView.type.FILE_STRING, noshow)
end

---Create a string to file diff viewer.
---@param a string
---@param b string
---@param noshow boolean If true doesn't adds to the rootview
---@return plugins.diff.view
function diff.string_to_file(a, b, noshow)
  return compare_start(a, b, DiffView.type.STRING_FILE, noshow)
end


return diff
