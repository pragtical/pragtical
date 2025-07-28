local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local keymap = require "core.keymap"
local translate = require "core.doc.translate"
local ime = require "core.ime"
local View = require "core.view"

local CACHE_LINE_LEN = 500

---@class core.docview : core.view
---@field super core.view
local DocView = View:extend()

function DocView:__tostring() return "DocView" end

DocView.context = "session"

local function move_to_line_offset(dv, line, col, offset)
  local xo = dv.last_x_offset
  if xo.line ~= line or xo.col ~= col then
    xo.offset = dv:get_col_x_offset(line, col)
  end
  xo.line = line + offset
  xo.col = dv:get_x_offset_col(line + offset, xo.offset)
  return xo.line, xo.col
end


DocView.translate = {
  ["previous_page"] = function(doc, line, col, dv)
    local min, max = dv:get_visible_line_range()
    return line - (max - min), 1
  end,

  ["next_page"] = function(doc, line, col, dv)
    if line == #doc.lines then
      return #doc.lines, #doc.lines[line]
    end
    local min, max = dv:get_visible_line_range()
    return line + (max - min), 1
  end,

  ["previous_line"] = function(doc, line, col, dv)
    if line == 1 then
      return 1, 1
    end
    return move_to_line_offset(dv, line, col, -1)
  end,

  ["next_line"] = function(doc, line, col, dv)
    if line == #doc.lines then
      return #doc.lines, math.huge
    end
    return move_to_line_offset(dv, line, col, 1)
  end,
}


function DocView:new(doc)
  DocView.super.new(self)
  self.cursor = "ibeam"
  self.scrollable = true
  self.doc = assert(doc)
  self.doc.cache.col_x = {}
  self.doc.cache.ulen = {}
  self.font = "code_font"
  self.last_x_offset = {}
  self.ime_selection = { from = 0, size = 0 }
  self.ime_status = false
  self.hovering_gutter = false
  self.v_scrollbar:set_forced_status(config.force_scrollbar_status)
  self.h_scrollbar:set_forced_status(config.force_scrollbar_status)
  self.cache_font = self:get_font()
  self.cache_font_size = self.cache_font:get_size()
  local _, indent_size = self.doc:get_indent_info()
  self.cache_indent_size = indent_size
end


function DocView:try_close(do_close)
  if self.doc:is_dirty()
  and #core.get_views_referencing_doc(self.doc) == 1 then
    core.command_view:enter("Unsaved Changes; Confirm Close", {
      submit = function(_, item)
        if item.text:match("^[cC]") then
          do_close()
        elseif item.text:match("^[sS]") then
          self.doc:save()
          do_close()
        end
      end,
      suggest = function(text)
        local items = {}
        if not text:find("^[^cC]") then table.insert(items, "Close Without Saving") end
        if not text:find("^[^sS]") then table.insert(items, "Save And Close") end
        return items
      end
    })
  else
    do_close()
  end
end


function DocView:get_name()
  local post = self.doc:is_dirty() and "*" or ""
  local name = self.doc:get_name()
  return name:match("[^/%\\]*$") .. post
end


function DocView:get_filename()
  if self.doc.abs_filename then
    local post = self.doc:is_dirty() and "*" or ""
    return common.home_encode(self.doc.abs_filename) .. post
  end
  return self:get_name()
end


function DocView:get_scrollable_size()
  if not config.scroll_past_end then
    local _, _, _, h_scroll = self.h_scrollbar:get_track_rect()
    return self:get_line_height() * (#self.doc.lines) + style.padding.y * 2 + h_scroll
  end
  return self:get_line_height() * (#self.doc.lines - 1) + self.size.y
end

function DocView:get_h_scrollable_size()
  return math.huge
end


function DocView:get_font()
  return style[self.font]
end


function DocView:get_line_height()
  return math.floor(self:get_font():get_height() * config.line_height)
end


function DocView:get_gutter_width()
  local padding = style.padding.x * 2
  if config.show_line_numbers then
    return self:get_font():get_width(#self.doc.lines) + padding, padding
  end
  return style.padding.x, padding
end


function DocView:get_line_screen_position(line, col)
  local x, y = self:get_content_offset()
  local lh = self:get_line_height()
  local gw = self:get_gutter_width()
  y = y + (line-1) * lh + style.padding.y
  if col then
    return x + gw + self:get_col_x_offset(line, col), y
  else
    return x + gw, y
  end
end

function DocView:get_line_text_y_offset()
  local lh = self:get_line_height()
  local th = self:get_font():get_height()
  return (lh - th) / 2
end


---Get an estimated range of visible columns. It is an estimate because fonts
---and their fallbacks may not be monospaced or may differ in size. This
---function provides a way of optimization on really long lines for plugins
---that perform drawing operations on them.
---
---It is good practice to set the `extra_cols` parameter to a value that leaves
---room for the differences in font sizes.
---@param line integer
---@param extra_cols? integer Amount of columns to deduce on col1 and include on col2 (default: 100)
---@return integer col1
---@return integer col2
---@return integer ucol1
---@return integer ucol2
function DocView:get_visible_cols_range(line, extra_cols)
  extra_cols = extra_cols or 100

  local text = self.doc.lines[line]
  local line_len = #text
  if line_len == 1 then return 1, 1, 1, 1 end

  local gw = self:get_gutter_width()
  local line_x = self.position.x + gw
  local x = -self.scroll.x + self.position.x + gw
  local char_width = self:get_font():get_width("W")
  local non_visible_x = common.clamp(line_x - x, 0, math.huge)

  local non_visible_chars_left = math.floor(non_visible_x / char_width)
  local visible_chars_right = math.floor((self.size.x - gw) / char_width)

  if non_visible_chars_left > line_len then return 0, 0, 0, 0 end

  local col1 = math.max(1, non_visible_chars_left - extra_cols)
  local col2 = math.min(line_len, non_visible_chars_left + (visible_chars_right*2) + extra_cols)
  local ucol1, ucol2 = col1, col2

  -- if line shorter than estimate then handle utf8 stuff
  local cache = self.doc.cache.ulen
  local ulen = cache[line]
  if not ulen then
    ulen = text:ulen(nil, nil, true)
    cache[line] = ulen
  end
  if ulen < line_len then
    ucol1 = text:ulen(1, col1, true)
    ucol2 = text:ulen(1, col2, true)
    col1 = text:ucharpos(ucol1)
    col2 = text:ucharpos(ucol2)
  end

  return col1, col2, ucol1, ucol2
end


function DocView:get_visible_line_range()
  local x, y, x2, y2 = self:get_content_bounds()
  local lh = self:get_line_height()
  local minline = math.max(1, math.floor((y - style.padding.y) / lh) + 1)
  local maxline = math.min(#self.doc.lines, math.floor((y2 - style.padding.y) / lh) + 1)
  return minline, maxline
end


function DocView:get_col_x_offset(line, col)
  local column = 1
  local xoffset = 0
  local cache = self.doc.cache.col_x
  local line_len = #self.doc.lines[line]
  if line_len > CACHE_LINE_LEN then
    if cache[line] and cache[line][col] then
      return cache[line][col]
    elseif not cache[line] then
      cache[line] = {}
    elseif col > 1 then
      for i=col-1, 1, -1 do
        if cache[line][i] then
          column = i
          xoffset = cache[line][i]
          break
        end
      end
    end
  end
  local default_font = self:get_font()
  local _, indent_size = self.doc:get_indent_info()
  default_font:set_tab_size(indent_size)
  local scol = column > 1 and column or nil
  for _, type, text in self.doc.highlighter:each_token(line, scol) do
    local font = style.syntax_fonts[type] or default_font
    if font ~= default_font then font:set_tab_size(indent_size) end
    local length = #text
    if column + length <= col then
      xoffset = xoffset + font:get_width(text, {tab_offset = xoffset})
      column = column + length
      if line_len > CACHE_LINE_LEN and cache[line] then
        cache[line][column] = xoffset
      end
      if column >= col then
        return xoffset
      end
    else
      for char in common.utf8_chars(text) do
        if column >= col then
          return xoffset
        end
        xoffset = xoffset + font:get_width(char, {tab_offset = xoffset})
        column = column + #char
        if line_len > CACHE_LINE_LEN and cache[line] then
          cache[line][column] = xoffset
        end
      end
    end
  end
  if line_len > CACHE_LINE_LEN and cache[line] then
    cache[line][column] = xoffset
  end
  return xoffset
end


function DocView:get_x_offset_col(line, x)
  local line_text = self.doc.lines[line]
  local line_len = #line_text

  -- we leverage the caching already present on col_x, this works on all lines,
  -- but for the moment lets do it only on the cached lines and keep original
  -- code logic intact
  if line_len > CACHE_LINE_LEN then
    local xo, pxo, last_col = 0, 0, 0
    for col, _ in utf8extra.next, line_text do
      pxo = xo
      xo = self:get_col_x_offset(line, col)
      if xo >= x or col >= line_len then
        local w = xo - pxo
        return (xo - x > w / 2) and last_col or col
      end
      last_col = col
    end
  end

  local xoffset, i = 0, 1
  local default_font = self:get_font()
  local _, indent_size = self.doc:get_indent_info()
  default_font:set_tab_size(indent_size)
  for _, type, text in self.doc.highlighter:each_token(line) do
    local font = style.syntax_fonts[type] or default_font
    if font ~= default_font then font:set_tab_size(indent_size) end
    local width = font:get_width(text, {tab_offset = xoffset})
    -- Don't take the shortcut if the width matches x,
    -- because we need last_i which should be calculated using utf-8.
    if xoffset + width < x then
      xoffset = xoffset + width
      i = i + #text
    else
      for char in common.utf8_chars(text) do
        local w = font:get_width(char, {tab_offset = xoffset})
        if xoffset + w >= x then
          return (x <= xoffset + (w / 2)) and i or i + #char
        end
        xoffset = xoffset + w
        i = i + #char
      end
    end
  end

  return line_len
end


function DocView:resolve_screen_position(x, y)
  local ox, oy = self:get_line_screen_position(1)
  local line = math.floor((y - oy) / self:get_line_height()) + 1
  line = common.clamp(line, 1, #self.doc.lines)
  local col = self:get_x_offset_col(line, x - ox)
  return line, col
end


function DocView:scroll_to_line(line, ignore_if_visible, instant)
  local min, max = self:get_visible_line_range()
  if not (ignore_if_visible and line > min and line < max) then
    local x, y = self:get_line_screen_position(line)
    local ox, oy = self:get_content_offset()
    local _, _, _, scroll_h = self.h_scrollbar:get_track_rect()
    self.scroll.to.y = math.max(0, y - oy - (self.size.y - scroll_h) / 2)
    if instant then
      self.scroll.y = self.scroll.to.y
    end
  end
end


function DocView:supports_text_input()
  return true
end


function DocView:scroll_to_make_visible(line, col, instant)
  local _, oy = self:get_content_offset()
  local _, ly = self:get_line_screen_position(line, col)
  local lh = self:get_line_height()
  local _, _, _, scroll_h = self.h_scrollbar:get_track_rect()

  local minline, maxline = self:get_visible_line_range()
  local visible_lines = maxline - minline

  local requested_pad = config.scroll_context_lines
  local max_pad = math.floor(visible_lines / 2)
  local pad = not self.mouse_selecting and math.min(requested_pad, max_pad) or 1
  local above = math.max(0, ly - oy - lh * pad)
  local below = ly - oy - self.size.y + scroll_h + lh * (pad + 1)

  self.scroll.to.y = common.clamp(self.scroll.to.y, below, above)

  local gw = self:get_gutter_width()
  local xoffset = self:get_col_x_offset(line, col)
  local xmargin = 3 * self:get_font():get_width(' ')
  local xsup = xoffset + gw + xmargin
  local xinf = xoffset - xmargin
  local _, _, scroll_w = self.v_scrollbar:get_track_rect()
  local size_x = math.max(0, self.size.x - scroll_w)

  if xsup > self.scroll.x + size_x then
    self.scroll.to.x = xsup - size_x
  elseif xinf < self.scroll.x then
    self.scroll.to.x = math.max(0, xinf)
  end

  if instant then
    self.scroll.y = self.scroll.to.y
    self.scroll.x = self.scroll.to.x
  end
end

function DocView:on_mouse_moved(x, y, ...)
  DocView.super.on_mouse_moved(self, x, y, ...)

  self.hovering_gutter = false
  local gw = self:get_gutter_width()

  if self:scrollbar_hovering() or self:scrollbar_dragging() then
    self.cursor = "arrow"
  elseif gw > 0 and x >= self.position.x and x <= (self.position.x + gw) then
    self.cursor = "arrow"
    self.hovering_gutter = true
  else
    self.cursor = "ibeam"
  end

  if self.mouse_selecting then
    local l1, c1 = self:resolve_screen_position(x, y)
    local l2, c2, snap_type = table.unpack(self.mouse_selecting)
    if keymap.modkeys["ctrl"] then
      if l1 > l2 then l1, l2 = l2, l1 end
      self.doc.selections = { }
      for i = l1, l2 do
        self.doc:set_selections(i - l1 + 1, i, math.min(c1, #self.doc.lines[i]), i, math.min(c2, #self.doc.lines[i]))
      end
    else
      if snap_type then
        l1, c1, l2, c2 = self:mouse_selection(self.doc, snap_type, l1, c1, l2, c2)
      end
      self.doc:set_selection(l1, c1, l2, c2)
    end
  end
end


function DocView:mouse_selection(doc, snap_type, line1, col1, line2, col2)
  local swap = line2 < line1 or line2 == line1 and col2 <= col1
  if swap then
    line1, col1, line2, col2 = line2, col2, line1, col1
  end
  if snap_type == "word" then
    line1, col1 = translate.start_of_word(doc, line1, col1)
    line2, col2 = translate.end_of_word(doc, line2, col2)
  elseif snap_type == "lines" then
    col1, col2, line2 = 1, 1, line2 + 1
  end
  if swap then
    return line2, col2, line1, col1
  end
  return line1, col1, line2, col2
end


function DocView:on_mouse_pressed(button, x, y, clicks)
  if button == "left" then self.doc:clear_search_selections() end
  if button ~= "left" or not self.hovering_gutter then
    return DocView.super.on_mouse_pressed(self, button, x, y, clicks)
  end
  local line = self:resolve_screen_position(x, y)
  if keymap.modkeys["shift"] then
    local sline, scol, sline2, scol2 = self.doc:get_selection(true)
    if line > sline then
      self.doc:set_selection(sline, 1, line,  #self.doc.lines[line])
    else
      self.doc:set_selection(line, 1, sline2, #self.doc.lines[sline2])
    end
  else
    if clicks == 1 then
      self.doc:set_selection(line, 1, line, 1)
    elseif clicks == 2 then
      self.doc:set_selection(line, 1, line, #self.doc.lines[line])
    end
  end
  return true
end


function DocView:on_mouse_released(...)
  DocView.super.on_mouse_released(self, ...)
  self.mouse_selecting = nil
end


function DocView:on_text_input(text)
  self.doc:clear_search_selections()
  self.doc:text_input(text)
end

function DocView:on_ime_text_editing(text, start, length)
  self.doc:clear_search_selections()
  self.doc:ime_text_editing(text, start, length)
  self.ime_status = #text > 0
  self.ime_selection.from = start
  self.ime_selection.size = length

  -- Set the composition bounding box that the system IME
  -- will consider when drawing its interface
  local line1, col1, line2, col2 = self.doc:get_selection(true)
  local col = math.min(col1, col2)
  self:update_ime_location()
  self:scroll_to_make_visible(line1, col + start)
end

---Update the composition bounding box that the system IME
---will consider when drawing its interface
function DocView:update_ime_location()
  if not self.ime_status then return end

  local line1, col1, line2, col2 = self.doc:get_selection(true)
  local x, y = self:get_line_screen_position(line1)
  local h = self:get_line_height()
  local col = math.min(col1, col2)

  local x1, x2 = 0, 0

  if self.ime_selection.size > 0 then
    -- focus on a part of the text
    local from = col + self.ime_selection.from
    local to = from + self.ime_selection.size
    x1 = self:get_col_x_offset(line1, from)
    x2 = self:get_col_x_offset(line1, to)
  else
    -- focus the whole text
    x1 = self:get_col_x_offset(line1, col1)
    x2 = self:get_col_x_offset(line2, col2)
  end

  ime.set_location(x + x1, y, x2 - x1, h)
end

function DocView:update()
  -- clear cache if font or indent size changed
  local font = self:get_font()
  local _, indent_size = self.doc:get_indent_info()
  if
    self.cache_indent_size ~= indent_size
    or
    self.cache_font ~= font or self.cache_font_size ~= font:get_size()
  then
    self.doc.cache.col_x = {}
    self.cache_font = font
    self.cache_font_size = font:get_size()
    self.cache_indent_size = indent_size
  end

  -- scroll to make caret visible and reset blink timer if it moved
  local line1, col1, line2, col2 = self.doc:get_selection()
  if (line1 ~= self.last_line1 or col1 ~= self.last_col1 or
      line2 ~= self.last_line2 or col2 ~= self.last_col2) and self.size.x > 0 then
    if core.active_view == self and not ime.editing then
      self:scroll_to_make_visible(line1, col1)
    end
    core.blink_reset()
    self.last_line1, self.last_col1 = line1, col1
    self.last_line2, self.last_col2 = line2, col2
  end

  -- update blink timer
  if self == core.active_view and not self.mouse_selecting then
    local T, t0 = config.blink_period, core.blink_start
    local ta, tb = core.blink_timer, system.get_time()
    if ((tb - t0) % T < T / 2) ~= ((ta - t0) % T < T / 2) then
      core.redraw = true
    end
    core.blink_timer = tb
  end

  self:update_ime_location()

  DocView.super.update(self)
end


function DocView:draw_line_highlight(x, y)
  local lh = self:get_line_height()
  renderer.draw_rect(x, y, self.size.x, lh, style.line_highlight)
end


function DocView:draw_line_text(line, x, y)
  local default_font = self:get_font()
  local tx, ty = x, y + self:get_line_text_y_offset()
  local last_token = nil
  local tokens = self.doc.highlighter:get_line(line).tokens
  local tokens_count = #tokens
  if tokens_count > 0 and string.sub(tokens[tokens_count], -1) == "\n" then
    last_token = tokens_count - 1
  end
  local _, indent_size = self.doc:get_indent_info()

  local search_selections = {}
  for _, line1, col1, line2, col2 in self.doc:get_selections(true) do
    if line == line1 and line <= line2 then
      if self.doc:is_search_selection(line1, col1, line2, col2) then
        table.insert(search_selections, {start = col1, stop = col2})
      end
    end
  end

  local col = 1
  local start_tx = tx
  for tidx, type, text in self.doc.highlighter:each_token(line) do
    if #search_selections == 0 then
      local color = style.syntax[type] or style.syntax["normal"]
      local font = style.syntax_fonts[type] or default_font
      if font ~= default_font then font:set_tab_size(indent_size) end
      -- do not render newline, fixes issue #1164
      if tidx == last_token then text = text:sub(1, -2) end
      tx = renderer.draw_text(font, text, tx, ty, color, {tab_offset = tx - start_tx})
      if tx > self.position.x + self.size.x then break end
    else
      local font = style.syntax_fonts[type] or default_font
      if font ~= default_font then font:set_tab_size(indent_size) end
      if tidx == last_token then text = text:sub(1, -2) end
      local i = 1
      local len = #text

      local function is_selected(c)
        for _, sel in ipairs(search_selections) do
          if c >= sel.start and c < sel.stop then
            return true
          end
        end
        return false
      end

      while i <= len do
        local chunk_start = i
        local c = col
        local selected = is_selected(c)
        -- advance through contiguous characters with the same selection status
        while i <= len and is_selected(col) == selected do
          i = i + 1
          col = col + 1
        end
        local chunk = text:sub(chunk_start, i - 1)
        local color = selected and (style.search_selection_text or style.background)
          or (style.syntax[type] or style.syntax["normal"])
        tx = renderer.draw_text(font, chunk, tx, ty, color, {tab_offset = tx - start_tx})
        if tx > self.position.x + self.size.x then break end
      end
    end
  end
  return self:get_line_height()
end

function DocView:draw_caret(x, y, line, col)
  local lh = self:get_line_height()
  if self.doc.overwrite then
    local w = self:get_font():get_width(self.doc:get_char(line, col))
    renderer.draw_rect(x, y + lh, w, style.caret_width * 2, style.caret)
  else
    renderer.draw_rect(x, y, style.caret_width, lh, style.caret)
  end
end

function DocView:draw_line_body(line, x, y)
  -- draw highlight if any selection ends on this line
  local draw_highlight = false
  local hcl = config.highlight_current_line
  if hcl ~= false then
    for lidx, line1, col1, line2, col2 in self.doc:get_selections(false) do
      if line1 == line then
        if hcl == "no_selection" then
          if (line1 ~= line2) or (col1 ~= col2) then
            draw_highlight = false
            break
          end
        end
        draw_highlight = true
        break
      end
    end
  end
  if draw_highlight and core.active_view == self then
    self:draw_line_highlight(x + self.scroll.x, y)
  end

  -- draw selection if it overlaps this line
  local lh = self:get_line_height()
  for lidx, line1, col1, line2, col2 in self.doc:get_selections(true) do
    if line >= line1 and line <= line2 then
      local text = self.doc.lines[line]
      if line1 ~= line then col1 = 1 end
      if line2 ~= line then col2 = #text + 1 end
      local x1 = x + self:get_col_x_offset(line, col1)
      local x2 = x + self:get_col_x_offset(line, col2)
      if x1 ~= x2 then
        local selection_color = style.selection
        if self.doc:is_search_selection(line1, col1, line, col2) then
          selection_color = style.search_selection or style.caret
        end
        renderer.draw_rect(x1, y, x2 - x1, lh, selection_color)
      end
    end
  end

  -- draw line's text
  return self:draw_line_text(line, x, y)
end


function DocView:draw_line_gutter(line, x, y, width)
  local lh = self:get_line_height()
  if config.show_line_numbers then
    local color = style.line_number
    for _, line1, _, line2 in self.doc:get_selections(true) do
      if line >= line1 and line <= line2 then
        color = style.line_number2
        break
      end
    end
    x = x + style.padding.x
    common.draw_text(self:get_font(), color, line, "right", x, y, width, lh)
  end
  return lh
end


function DocView:draw_ime_decoration(line1, col1, line2, col2)
  local x, y = self:get_line_screen_position(line1)
  local line_size = math.max(1, SCALE)
  local lh = self:get_line_height()

  -- Draw IME underline
  local x1 = self:get_col_x_offset(line1, col1)
  local x2 = self:get_col_x_offset(line2, col2)
  renderer.draw_rect(x + math.min(x1, x2), y + lh - line_size, math.abs(x1 - x2), line_size, style.text)

  -- Draw IME selection
  local col = math.min(col1, col2)
  local from = col + self.ime_selection.from
  local to = from + self.ime_selection.size
  x1 = self:get_col_x_offset(line1, from)
  if from ~= to then
    x2 = self:get_col_x_offset(line1, to)
    line_size = style.caret_width
    renderer.draw_rect(x + math.min(x1, x2), y + lh - line_size, math.abs(x1 - x2), line_size, style.caret)
  end
  self:draw_caret(x + x1, y, line1, col)
end


function DocView:draw_overlay()
  if core.active_view == self then
    local minline, maxline = self:get_visible_line_range()
    -- draw caret if it overlaps this line
    local T = config.blink_period
    for _, line1, col1, line2, col2 in self.doc:get_selections() do
      if line1 >= minline and line1 <= maxline
      and system.window_has_focus(core.window) then
        if ime.editing then
          self:draw_ime_decoration(line1, col1, line2, col2)
        else
          if config.disable_blink
          or (core.blink_timer - core.blink_start) % T < T / 2 then
            local x, y = self:get_line_screen_position(line1, col1)
            self:draw_caret(x, y, line1, col1)
          end
        end
      end
    end
  end
end

function DocView:draw()
  self:draw_background(style.background)
  local _, indent_size = self.doc:get_indent_info()
  self:get_font():set_tab_size(indent_size)

  local minline, maxline = self:get_visible_line_range()
  local lh = self:get_line_height()

  local x, y = self:get_line_screen_position(minline)
  local gw, gpad = self:get_gutter_width()
  for i = minline, maxline do
    y = y + (self:draw_line_gutter(i, self.position.x, y, gpad and gw - gpad or gw) or lh)
  end

  local pos = self.position
  x, y = self:get_line_screen_position(minline)
  -- the clip below ensure we don't write on the gutter region. On the
  -- right side it is redundant with the Node's clip.
  core.push_clip_rect(pos.x + gw, pos.y, self.size.x - gw, self.size.y)
  for i = minline, maxline do
    y = y + (self:draw_line_body(i, x, y) or lh)
  end
  self:draw_overlay()
  core.pop_clip_rect()

  self:draw_scrollbar()
end

return DocView
