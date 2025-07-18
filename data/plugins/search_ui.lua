-- mod-version:3
--
-- Replacement for the find/replace CommandView
-- interface using Widgets with some extra features.
-- @copyright Jefferson Gonzalez <jgmdev@gmail.com>
-- @license MIT
--
local core = require "core"
local config = require "core.config"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local search = require "core.doc.search"
local CommandView = require "core.commandview"
local DocView = require "core.docview"
local Widget = require "widget"
local Button = require "widget.button"
local Line = require "widget.line"
local Label = require "widget.label"
local TextBox = require "widget.textbox"
local FilePicker = require "widget.filepicker"
local ToggleButton = require "widget.togglebutton"

---The main user interface container.
---@class plugins.search_ui.ui : widget
local ui = Widget(nil, false)

---Flag that indicates if the main widget is already inside a node.
---@type boolean
local inside_node = false

---Configuration options for `search_ui` plugin.
---@class config.plugins.search_ui
---Replaces the core find view when using the find shortcut.
---@field replace_core_find boolean
---Location of search interface.
---@field position "top" | "right" | "bottom"
config.plugins.search_ui = common.merge({
  replace_core_find = true,
  position = "bottom",
  config_spec = {
    name = "Search User Interface",
    {
      label = "Replace Core Find",
      description = "Replaces the core find view when using the find shortcut.",
      path = "replace_core_find",
      type = "toggle",
      default = true
    },
    {
      label = "Position",
      description = "Location of search interface.",
      path = "position",
      type = "selection",
      default = "bottom",
      values = {
        { "Top", "top" },
        { "Right", "right" },
        { "Bottom", "bottom" },
      },
      set_value = function(value)
        -- we have to show it if already inside a node to prevent issues
        if not ui:is_visible() and inside_node then
          ui:show()
        end
        return value
      end
    }
  }
}, config.plugins.search_ui)

---@type core.docview
local doc_view

ui.name = "Search and Replace"
ui:set_border_width(0)
ui.scrollable = true
ui:hide()
ui.init_size = true

local label = Label(ui, "Find and Replace")

local line_separator = Line(ui)
line_separator.border.color = { common.color "#00000000" }

local close = Button(ui)
close:set_icon("C")
close:set_tooltip(nil, "search-replace:hide")
close.border.width = 0
close.padding.x = close.padding.x / 2
close.padding.y = close.padding.y / 5

local findtext = TextBox(ui, "", "search...")
findtext:set_tooltip("Text to search")

local replacetext = TextBox(ui, "", "replacement...")
replacetext:set_tooltip("Text to replace")

local findprev = Button(ui, "")
findprev:set_icon("<")
findprev:set_tooltip("Find previous", "search-replace:perform-previous")

local findnext = Button(ui, "")
findnext:set_icon(">")
findnext:set_tooltip("Find next", "search-replace:perform")

local replace = Button(ui, "Replace")
replace:set_tooltip("Replace all matching results", "search-replace:perform-replace")

local line_options = Line(ui)

local sensitive = ToggleButton(ui, false, nil, "o")
sensitive:set_tooltip(nil, "search-replace:toggle-case-sensitive")

local wholeword = ToggleButton(ui, false, nil, "O")
wholeword:set_tooltip(nil, "search-replace:toggle-whole-word")

local patterncheck = ToggleButton(ui, false, nil, "R")
patterncheck:set_tooltip(
  "Treat search text as a lua pattern (always case sensitive)",
  "search-replace:toggle-pattern"
)

local regexcheck = ToggleButton(ui, false, nil, "r")
regexcheck:set_tooltip(
  "Treat search text as a regular expression",
  "search-replace:toggle-regex"
)

local replaceinselection = ToggleButton(ui, false, nil, "*")
replaceinselection:set_tooltip(
  "Replace only on selected text",
  "search-replace:toggle-in-selection"
)

local replacetoggle = ToggleButton(ui, false, nil, "s")
replacetoggle:set_tooltip(
  "Toggle between search only or search and replace",
  "find-replace:replace"
)

local filepicker = FilePicker(ui)
filepicker:set_mode(FilePicker.mode.DIRECTORY)
filepicker:set_tooltip("Directory to perform the search")
filepicker:hide()

local statusline = Line(ui)

local status = Label(ui, "")

--------------------------------------------------------------------------------
-- Helper class to keep track on amount of matches and display on status label
--------------------------------------------------------------------------------
---@class plugins.search_ui.result
---@field line integer
---@field col integer

---@class plugins.search_ui.results
---@field text string
---@field matches plugins.search_ui.result[]
---@field doc core.doc?
---@field change_id integer
---@field prev_search_id integer
local Results = {
  text = "",
  matches = {},
  doc = nil,
  change_id = 0,
  prev_search_id = 0
}

local function is_whole_match(line_text, col1, col2)
  if
    (col1 ~= 1 and line_text:sub(col1-1, col1-1):match("[%w_]"))
    or
    (col2 ~= #line_text and line_text:sub(col2+1, col2+1):match("[%w_]"))
  then
    return false
  end
  return true
end

---@param text string
---@param doc core.doc
function Results:find(text, doc, force)
  if
    not force and self.text == text
    and
    self.doc == doc and self.change_id == doc:get_change_id()
  then
    self:set_status()
    return
  end

  -- disable previous search thread
  if self.prev_search_id > 0 and core.threads[self.prev_search_id] then
    core.threads[self.prev_search_id] = {
      cr = coroutine.create(function() end), wake = 0
    }
  end

  self.text = text
  self.doc = doc
  self.change_id = doc:get_change_id()

  local search_func
  local whole = wholeword:is_toggled()

  -- regex search
  if regexcheck:is_toggled() then
    local pattern = regex.compile(
      findtext:get_text(),
      not sensitive:is_toggled() and "i" or ""
    )
    if not pattern then return end
    search_func = function(line_text)
      ---@cast line_text string
      local results = nil
      local offsets = {}
      local index = 1
      repeat
        offsets = { pattern:find_offsets(line_text, index) }
        if offsets[1] then
          if not results then results = {} end
          for i = 1, #offsets, 2 do
            local matches = true
            if whole and not is_whole_match(line_text, offsets[i], offsets[i + 1] - 1) then
              matches = false
            end
            if matches then
              table.insert(results, offsets[i])
            end
            index = offsets[i + 1]
          end
        end
      until not offsets[1] or index >= #line_text
      return results
    end
  -- plain or pattern search
  else
    local no_case = not sensitive:is_toggled()
    local is_plain = not patterncheck:is_toggled()
    if is_plain and no_case then
      text = text:ulower()
    end
    search_func = function(line_text)
      ---@cast line_text string
      if is_plain and no_case then
        line_text = line_text:ulower()
      end
      local line_len = #line_text
      local results = {}
      local col1, col2 = 0, 0
      repeat
        col1, col2 = line_text:find(text, col2+1, is_plain)
        if col1 and col2 and col2 > 0 then
          local matches = true
          if whole and not is_whole_match(line_text, col1, col2) then
            matches = false
          end
          if matches then table.insert(results, col1) end
        end
      until not col1 or not col2 or col2 >= line_len or col1 > col2 or (col2 == 0)
      return #results > 0 and results or nil
    end
  end

  self.prev_search_id = core.add_thread(function()
    self.matches = {}
    local lines_count = #doc.lines
    for i=1, lines_count do
      local line_text = doc.lines[i]
      if #line_text > 1 then -- skip empty lines
        local offsets = search_func(line_text)
        if offsets then
          for _, col in ipairs(offsets) do
            table.insert(self.matches, {line = i, col = col})
          end
        end
      end
      if i % 100 == 0 then
        coroutine.yield()
      end
    end
    self:set_status()
    ui:schedule_update()
  end)
end

function Results:update()
  if #self.matches > 0 then
    self:find(self.text, self.doc, true)
  end
end

---@return integer
function Results:current()
  if not self.doc then return 0 end
  local line1, col1, line2, col2 = self.doc:get_selection()
  if line1 == line2 and col1 == col2 then return 0 end
  local line = math.min(line1, line2)
  local col = math.min(col1, col2)
  if self.matches and #self.matches > 0 then
    for i, result in ipairs(self.matches) do
      if result.line == line and result.col == col then
        return i
      end
    end
  end
  return 0
end

function Results:clear()
  self.text = ""
  self.matches = {}
  self.doc = nil
  status:set_label("")
end

function Results:set_status()
  local current = self:current()
  local total = self.matches and #self.matches or 0
  if total > 0 then
    status:set_label(
      "Result: " .. tostring(current .. " of " .. tostring(total))
    )
  elseif not status.label:match("Total") then
    status:set_label("")
  end
end

--------------------------------------------------------------------------------
-- Helper functions
--------------------------------------------------------------------------------
local function view_is_open(target_view)
  if not target_view then return false end
  local found = false
  for _, view in ipairs(core.root_view.root_node:get_children()) do
    if view == target_view then
      found = true
      break
    end
  end
  return found
end

local find_enabled = true
local function find(reverse, not_scroll, unselect_first, no_wrap)
  if
    not view_is_open(doc_view) or findtext:get_text() == "" or not find_enabled
  then
    Results:clear()
    return
  end

  if core.last_active_view and core.last_active_view:is(DocView) then
    doc_view = core.last_active_view
  end

  local doc = doc_view.doc
  local cline1, ccol1, _, ccol2 = doc:get_selection()
  if unselect_first then
    cline1, ccol1, _, ccol2 = doc:get_selection(true)
    ccol2 = ccol1
    doc:set_selection(cline1, ccol1)
  end
  local line, col = cline1, ccol1
  if (reverse and ccol2 < ccol1) or (not reverse and col < ccol2) then
    col = ccol2
  end

  local opt = {
    wrap = not no_wrap and true or false,
    no_case = not sensitive:is_toggled(),
    whole_word = wholeword:is_toggled(),
    pattern = patterncheck:is_toggled(),
    regex = regexcheck:is_toggled(),
    reverse = reverse
  }

  if opt.regex and not regex.compile(findtext:get_text()) then
    return
  end

  status:set_label("")

  core.try(function()
    local line1, col1, line2, col2 = search.find(
      doc, line, col, findtext:get_text(), opt
    )

    local current_text = doc:get_text(
      table.unpack({ doc:get_selection() })
    )

    if opt.no_case and not opt.regex and not opt.pattern then
      current_text = current_text:ulower()
    end

    if line1 then
      local text = findtext:get_text()
      if opt.no_case and not opt.regex and not opt.pattern then
        text = text:ulower()
      end
      if reverse or (current_text == text or current_text == "") then
        doc:set_selection(line1, col2, line2, col1)
      else
        doc:set_selection(line1, col1, line2, col2)
      end
      if not not_scroll then
        doc_view:scroll_to_make_visible(line1, col1, true)
      end
      Results:find(text, doc)
    end
  end)
end

local function find_replace()
  if core.last_active_view:is(DocView) then
    doc_view = core.last_active_view
  end

  ---@type core.doc
  local doc = doc_view.doc
  local new = replacetext:get_text()
  local in_selection = replaceinselection:is_toggled()
  local selections = {}

  -- allows repeatedly performing a replace
  if in_selection and doc:get_text(doc:get_selection()) == "" then
    find(false)
    return
  end

  local rexpr = regexcheck:is_toggled()
    and regex.compile(
      findtext:get_text(),
      not sensitive:is_toggled() and "i" or ""
    )
    or false

  local pattern = patterncheck:is_toggled()
    and findtext:get_text()
    or false

  if not in_selection then
    table.insert(selections, {1, 1, 1, 1})
  else
    for _, l1, c1, l2, c2 in doc:get_selections(true) do
      table.insert(selections, {l1, c1, l2, c2})
    end
  end

  local n = 0
  for _, s in ipairs(selections) do
    doc:set_selection(s[1], s[2])

    local f1, fc1 -- save position of first replaced result
    local p1, pc1, p2, pc2
    local n1, nc1, n2, nc2
    repeat
      p1, pc1, p2, pc2 = doc:get_selection(true)
      find(false, true, false, true)
      n1, nc1, n2, nc2 = doc:get_selection(true)
      if p1 ~= n1 or pc1 ~= nc1 or p2 ~= n2 or pc2 ~= nc2 then
        if f1 == n1 and fc1 == nc1 then -- prevent recursive replacement
          doc:set_selection(p1, pc1)
          break
        end
        if in_selection then
          if n1 > s[3] or (n1 == s[3] and nc1 > s[4]) then
            doc:set_selection(p1, pc1)
            break
          end
        end
        if not f1 then f1, fc1 = n1, nc1 end
        n = n + 1
        doc:replace_cursor(0, n1, nc1, n2, nc2, function()
          local replacement, subject = new, nil
          if rexpr then
            subject = doc:get_text(n1, nc1, n2, nc2)
            replacement = rexpr:gsub(subject, replacement, 1)
          elseif pattern then
            subject = doc:get_text(n1, nc1, n2, nc2)
            replacement = subject:gsub(pattern, replacement, 1)
          end
          local new_len = #replacement
          local old_len = nc2 - nc1
          if old_len < new_len then
            nc2 = nc2 + (new_len - old_len)
          else
            nc2 = nc2 - (old_len - new_len)
          end
          return replacement or subject
        end)
        doc:set_selection(n2, nc2)
        if in_selection then
          if n2 > s[3] or (n2 == s[3] and nc2 > s[4]) then break end
        end
      end
    until p1 == n1 and pc1 == nc1 and p2 == n2 and pc2 == nc2
  end

  if #selections > 1 then
    doc:set_selection(selections[1][1], selections[1][2])
    for i=2, #selections do
      doc:add_selection(selections[i][1], selections[i][2])
    end
  end

  Results:clear()

  status:set_label(string.format("Total Replaced: %d", n))
end

local current_node = nil
local current_position = ""

local function add_to_node()
  if not inside_node or current_position ~= config.plugins.search_ui.position then
    if
      current_node and current_position ~= ""
      and
      current_position ~= config.plugins.search_ui.position
    then
      ui:hide()
      current_node:remove_view(core.root_view.root_node, ui)
      core.root_view.root_node:update_layout()
      ui:set_size(0, 0)
      ui.init_size = true
    end
    local node = core.root_view:get_primary_node()
    if config.plugins.search_ui.position == "right" then
      current_node = node:split("right", ui, {x=true}, true)
      current_position = "right"
    elseif config.plugins.search_ui.position == "top" then
      current_node = node:split("up", ui, {y=true}, false)
      current_position = "top"
    else
      current_node = node:split("down", ui, {y=true}, false)
      current_position = "bottom"
    end
    ui:show()
    inside_node = true
  end
end

---Show or hide the search pane.
---@param av? core.docview
---@param toggle? boolean
local function show_find(av, toggle)
  ui.prev_view = av
  ui:swap_active_child()

  if inside_node and current_position == config.plugins.search_ui.position then
    if toggle then
      ui:toggle_visible(true, false, true)
    elseif not ui:is_visible() then
      -- keep bottom/top ui properly sized due to replace toggle
      if config.plugins.search_ui.position ~= "right" then
        ui:show()
        ui:update_bottom_positioning()
        ui:update_size()
        ui:hide()
      end
      ui:show_animated(true, false)
    end
  else
    add_to_node()
  end

  if ui:is_visible() then
    ui:swap_active_child(findtext)
    if av then
      doc_view = av
      if view_is_open(doc_view) and doc_view.doc then
        local is_pattern = regexcheck:is_toggled() or patterncheck:is_toggled()
        local doc_text = doc_view.doc:get_text(
          table.unpack({ doc_view.doc:get_selection() })
        )
        if not sensitive:is_toggled() then doc_text = doc_text:ulower() end
        local current_text = findtext:get_text()
        if not sensitive:is_toggled() then current_text = current_text:ulower() end
        if not is_pattern and doc_text and doc_text ~= "" and current_text ~= doc_text then
          local original_text = doc_view.doc:get_text(
            table.unpack({ doc_view.doc:get_selection() })
          )
          find_enabled = false
          findtext:set_text(original_text)
          find_enabled = true
        elseif current_text ~= "" and doc_text == "" then
          find(false)
        end
        if findtext:get_text() ~= "" then
          if not is_pattern then
            findtext.textview.doc:set_selection(1, math.huge, 1, 1)
          end
          Results:find(findtext:get_text(), doc_view.doc)
        else
          Results:clear()
        end
      end
    end
  else
    ui:swap_active_child()
    if view_is_open(doc_view) then
      core.set_active_view(doc_view)
    end
  end
end

local function reset_search()
  Results:clear()
  if not replaceinselection:is_toggled() then
    find(false, false, true)
  end
end

--------------------------------------------------------------------------------
-- Widgets event overrides
--------------------------------------------------------------------------------
function close:on_click(button, x, y)
  command.perform "search-replace:hide"
end

function findtext:on_change(text)
  if not replaceinselection:is_toggled() then
    find(false, false, true)
  end
end

function sensitive:on_change(checked)
  reset_search()
end

function wholeword:on_change(checked)
  reset_search()
end

function patterncheck:on_change(checked)
  if checked then
    regexcheck:set_toggle(false)
  end
  reset_search()
end

function regexcheck:on_change(checked)
  if checked then
    patterncheck:set_toggle(false)
  end
  reset_search()
end

function replacetoggle:on_change()
  if ui:is_visible() and config.plugins.search_ui.position ~= "right" then
    ui:update_bottom_positioning()
    ui:update_size()
    ui:swap_active_child(findtext)
  end
end

function findnext:on_click() find() end

function findprev:on_click() find(true) end

function replace:on_click()
  find_replace()
end

function ui:update_size()
  if config.plugins.search_ui.position == "right" then
    if self.size.x < replace:get_right() + replace:get_width() / 2 then
      self.size.x = replace:get_right() + replace:get_width() / 2
    end
  else
    self:set_size(nil, self:get_real_height() +  (7 * SCALE))
  end
end

function ui:update_right_positioning()
  replacetoggle:hide()
  label:show()
  replacetext:show()
  replace:show()
  status:show()
  line_options:show()
  label:set_label("Find and Replace")

  -- base padding to separate widgets
  local p = 7 * SCALE

  close:set_position(p, p)
  label:set_position(close:get_right() + (p / 2), p)
  line_separator:set_position(0, close:get_bottom() + p)
  findtext:set_position(p, line_separator:get_bottom())
  findtext.size.x = self.size.x - (p * 2)
  replacetext:set_position(p, findtext:get_bottom() + p)
  replacetext.size.x = self.size.x - (p * 2)

  findprev:set_position(p, replacetext:get_bottom() + p)
  findnext:set_position(findprev:get_right() + (p / 2), replacetext:get_bottom() + p)
  replace:set_position(findnext:get_right() + (p / 2), replacetext:get_bottom() + p)
  line_options:set_position(0, replace:get_bottom() + p * 2)

  sensitive:set_position(p, line_options:get_bottom() + p * 2)
  wholeword:set_position(sensitive:get_right() + p, line_options:get_bottom() + p * 2)
  patterncheck:set_position(wholeword:get_right() + p, line_options:get_bottom() + p * 2)
  regexcheck:set_position(patterncheck:get_right() + p, line_options:get_bottom() + p * 2)
  replaceinselection:set_position(regexcheck:get_right() + p, line_options:get_bottom() + p * 2)
  statusline:show()
  statusline:set_position(0, replaceinselection:get_bottom() + (p * 3))

  status:set_position(p, statusline:get_bottom() + p)

  if self.init_size then
    self:update_size()
    self.init_size = false
    self:show_animated(false, true)
  end

  add_to_node()
end

function ui:update_bottom_positioning()
  -- base padding to separate widgets
  local p = 7 * SCALE

  statusline:hide()
  close:set_position(p, p)

  label:hide()
  status:show()
  replacetoggle:show()
  status:set_position(close:get_right() + (p / 2), p)
  replacetoggle:set_position(self.size.x - replacetoggle:get_width() - p, p)
  replaceinselection:set_position(replacetoggle:get_position().x - p - replaceinselection:get_width(), p)
  regexcheck:set_position(replaceinselection:get_position().x - p - regexcheck:get_width(), p)
  patterncheck:set_position(regexcheck:get_position().x - p - patterncheck:get_width(), p)
  wholeword:set_position(patterncheck:get_position().x - p - wholeword:get_width(), p)
  sensitive:set_position(wholeword:get_position().x - p - sensitive:get_width(), p)
  line_separator:set_position(0, close:get_bottom() + p)

  findtext:set_position(p, line_separator:get_bottom())
  findtext.size.x = self.size.x - (p * 4) - findprev:get_width() - findnext:get_width()
  findnext:set_position(self.size.x - p - findnext:get_width(), line_separator:get_bottom())
  findprev:set_position(findnext:get_position().x - p - findprev:get_width(), line_separator:get_bottom())

  if replacetoggle:is_toggled() then
    replacetext:show()
    replace:show()
    replacetext:set_position(p, findtext:get_bottom() + p)
    replacetext.size.x = findtext.size.x
    replace:set_position(findprev:get_position().x, findtext:get_bottom() + p)
    replace.size.x = findprev:get_width() + findnext:get_width() + p
  else
    replacetext:hide()
    replace:hide()
  end

  line_options:hide()

  if self.init_size then
    self:update_size()
    self.init_size = false
    self:show_animated(true, false)
  end

  add_to_node()
end

-- reposition items on scale changes only when needed
local ui_prev_size = { x = ui.size.x, y = ui.size.y }
local ui_prev_position = config.plugins.search_ui.position
function ui:update()
  if Widget.update(self) then
    if
      ui_prev_size.x ~= self.size.x or ui_prev_size.y ~= self.size.y
      or
      ui_prev_position ~= config.plugins.search_ui.position
    then
      if config.plugins.search_ui.position == "right" then
        self:update_right_positioning()
      else
        self:update_bottom_positioning()
      end
      ui_prev_size.x = self.size.x
      ui_prev_size.y = self.size.y
      ui_prev_position = config.plugins.search_ui.position
    end
  end
end

function ui:on_scale_change(...)
  Widget.on_scale_change(self, ...)
  self:update_size()
end

--------------------------------------------------------------------------------
-- Override set_active_view to keep track of currently active docview
--------------------------------------------------------------------------------
local core_set_active_view = core.set_active_view
function core.set_active_view(...)
  core_set_active_view(...)
  local view = core.next_active_view or core.active_view
  if
    view ~= doc_view
    and
    ui:is_visible()
    and
    view:extends(DocView)
    and
    view ~= findtext.textview
    and
    view ~= replacetext.textview
    and
    view.doc.filename
  then
    doc_view = view
    ui.prev_view = doc_view
    local search_text = findtext:get_text()
    if search_text ~= "" then
      Results:find(search_text, doc_view.doc)
    else
      Results:clear()
    end
  end
end

--------------------------------------------------------------------------------
-- Register commands
--------------------------------------------------------------------------------
command.add(
  function()
    if core.active_view:is(DocView) then
      return true, core.active_view
    elseif ui:is_visible() then
      return true, doc_view
    end
    return false
  end,
  {
    ["search-replace:show"] = function(av)
      show_find(av, false)
    end,

    ["search-replace:toggle"] = function(av)
      show_find(av, true)
    end
  }
)

command.add(function() return ui:is_visible() and not core.active_view:is(CommandView) end, {
  ["search-replace:hide"] = function()
    ui:swap_active_child()
    if config.plugins.search_ui.position == "right" then
      ui:hide_animated(false, true)
    else
      ui:hide_animated(true, false)
    end
    if view_is_open(doc_view) then
      core.set_active_view(doc_view)
    end
  end,

  ["search-replace:file-search"] = function()
    command.perform "search-replace:show"
  end,

  ["search-replace:next"] = function()
    find(false)
  end,

  ["search-replace:previous"] = function()
    find(true)
  end,

  ["search-replace:toggle-case-sensitive"] = function()
    sensitive:toggle()
  end,

  ["search-replace:toggle-whole-word"] = function()
    wholeword:toggle()
  end,

  ["search-replace:toggle-pattern"] = function()
    patterncheck:toggle()
  end,

  ["search-replace:toggle-regex"] = function()
    regexcheck:toggle()
  end,

  ["search-replace:toggle-in-selection"] = function()
    replaceinselection:toggle()
  end
})

command.add(
  function()
    local active = ui.child_active == findtext and findtext or replacetext
    return ui:is_visible()
      and
      not core.active_view:is(CommandView)
      and
      (
        ui.child_active == active
        and
        core.active_view == active.textview
      )
  end,
  {
    ["search-replace:perform"] = function()
      ---@type core.doc
      local doc = doc_view.doc
      local line1, col1, line2, col2 = doc:get_selection()
      -- correct cursor position to properly search next result
      if line1 ~= line2 or col1 ~= col2 then
        doc:set_selection(
          line1,
          math.max(col1, col2),
          line2,
          math.min(col1, col2)
        )
      end
      find(false)
    end,
    ["search-replace:perform-previous"] = function()
      find(true)
    end,
    ["search-replace:perform-replace"] = function()
      find_replace()
    end
  }
)

command.add(
  function()
    if
      not ui:is_visible() or (
        config.plugins.search_ui.position ~= "right"
        and
        not replacetoggle:is_toggled()
      )
    then
      return false
    end
    if core.active_view == findtext.textview then
      return true, replacetext
    elseif core.active_view == replacetext.textview then
      return true, findtext
    end
    return false
  end,
  {
    ["search-replace:switch-input"] = function(next)
      ui:swap_active_child(next)
      next.textview.doc:set_selection(1, math.huge, 1, 1)
      ui.prev_view = doc_view
    end
  }
)

--------------------------------------------------------------------------------
-- Override core find/replace commands
--------------------------------------------------------------------------------
local find_replace_find = command.map["find-replace:find"].perform
command.map["find-replace:find"].perform = function(...)
  if config.plugins.search_ui.replace_core_find then
    if config.plugins.search_ui.position ~= "right" then
      if not ui:is_visible() then
        if replacetoggle:is_toggled() then replacetoggle:set_toggle(false) end
      end
    end
    command.perform "search-replace:show"
  else
    find_replace_find(...)
  end
end

local find_replace_replace_predicate = command.map["find-replace:replace"].predicate
command.map["find-replace:replace"].predicate = function(...)
  if config.plugins.search_ui.replace_core_find then
    local valid_view = find_replace_replace_predicate()
    return (valid_view or ui:is_visible()), ...
  end
  return find_replace_replace_predicate(...)
end

local find_replace_replace = command.map["find-replace:replace"].perform
command.map["find-replace:replace"].perform = function(...)
  if config.plugins.search_ui.replace_core_find then
    if config.plugins.search_ui.position ~= "right" then
      if not ui:is_visible() then
        if not replacetoggle:is_toggled() then replacetoggle:set_toggle(true) end
      else
        replacetoggle:toggle()
      end
    end
    command.perform "search-replace:show"
  else
    find_replace_replace(...)
  end
end

local find_replace_repeat = command.map["find-replace:repeat-find"].perform
command.map["find-replace:repeat-find"].perform = function(...)
  if
    ui:is_visible()
    or
    (config.plugins.search_ui.replace_core_find and findtext:get_text() ~= "")
  then
    find(false)
    return
  end
  find_replace_repeat(...)
end

local find_replace_previous = command.map["find-replace:previous-find"].perform
command.map["find-replace:previous-find"].perform = function(...)
  if
    ui:is_visible()
    or
    (config.plugins.search_ui.replace_core_find and findtext:get_text() ~= "")
  then
    find(true)
    return
  end
  find_replace_previous(...)
end

--------------------------------------------------------------------------------
-- Register keymaps
--------------------------------------------------------------------------------
keymap.add {
  ["alt+h"] = "search-replace:toggle",
  ["escape"] = "search-replace:hide",
  ["f3"] = "search-replace:next",
  ["shift+f3"] = "search-replace:previous",
  ["return"] = "search-replace:perform",
  ["shift+return"] = "search-replace:perform-previous",
  ["ctrl+return"] = "search-replace:perform-replace",
  ["ctrl+i"] = "search-replace:toggle-case-sensitive",
  ["ctrl+shift+w"] = "search-replace:toggle-whole-word",
  ["ctrl+alt+w"] = "search-replace:toggle-pattern",
  ["ctrl+shift+i"] = "search-replace:toggle-regex",
  ["ctrl+alt+i"] = "search-replace:toggle-in-selection",
  ["ctrl+f"] = "search-replace:file-search",
  ["tab"] = "search-replace:switch-input",
  ["shift+tab"] = "search-replace:switch-input"
}


return ui
