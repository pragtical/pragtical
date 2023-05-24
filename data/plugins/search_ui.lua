-- mod-version:3
--
-- Replacement for the find/replace and project search CommandView
---interface using Widgets with some extra features.
-- @copyright Jefferson Gonzalez <jgmdev@gmail.com>
-- @license MIT
--
local core = require "core"
local config = require "core.config"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local search = require "core.doc.search"
local projectsearch = require "plugins.projectsearch"
local CommandView = require "core.commandview"
local DocView = require "core.docview"
local Widget = require "widget"
local Button = require "widget.button"
local CheckBox = require "widget.checkbox"
local Line = require "widget.line"
local Label = require "widget.label"
local TextBox = require "widget.textbox"
local SelectBox = require "widget.selectbox"
local FilePicker = require "widget.filepicker"

---The main user interface container.
---@type widget
local widget = Widget(nil, false)

---Flag that indicates if the main widget is already inside a node.
---@type boolean
local inside_node = false

---@class config.plugins.search_ui
---@field replace_core_find boolean
---@field position "right" | "bottom"
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
        -- we have to show it if alreadu inside a node to prevent issues
        if not widget:is_visible() and inside_node then
          widget:show()
        end
        return value
      end
    }
  }
}, config.plugins.search_ui)

---@type core.docview
local doc_view

widget.name = "Search and Replace"
widget:set_border_width(0)
widget.scrollable = true
widget:hide()
widget.init_size = true

---@type widget.label
local label = Label(widget, "Find and Replace")
label:set_position(10, 10)

---@type widget.line
local line = Line(widget)
line:set_position(0, label:get_bottom() + 10)

---@type widget.textbox
local findtext = TextBox(widget, "", "search...")
findtext:set_position(10, line:get_bottom() + 10)
findtext:set_tooltip("Text to search")

---@type widget.textbox
local replacetext = TextBox(widget, "", "replacement...")
replacetext:set_position(10, findtext:get_bottom() + 10)
replacetext:set_tooltip("Text to replace")

---@type widget.button
local findprev = Button(widget, "")
findprev:set_icon("<")
findprev:set_position(10, replacetext:get_bottom() + 10)
findprev:set_tooltip("Find previous")

---@type widget.button
local findnext = Button(widget, "")
findnext:set_icon(">")
findnext:set_position(findprev:get_right() + 5, replacetext:get_bottom() + 10)
findnext:set_tooltip("Find next")

---@type widget.button
local findproject = Button(widget, "Find")
findproject:set_icon("L")
findproject:set_position(findprev:get_right() + 5, replacetext:get_bottom() + 10)
findproject:set_tooltip("Find in project")
findproject:hide()

---@type widget.button
local replace = Button(widget, "Replace")
replace:set_position(10, findnext:get_bottom() + 10)
replace:set_tooltip("Replace all matching results")

---@type widget.line
local line_options = Line(widget)
line_options:set_position(0, replace:get_bottom() + 10)

---@type widget.checkbox
local insensitive = CheckBox(widget, "Insensitive")
insensitive:set_position(10, line_options:get_bottom() + 10)
insensitive:set_tooltip("Case insensitive search")
insensitive:set_checked(true)

---@type widget.checkbox
local patterncheck = CheckBox(widget, "Pattern")
patterncheck:set_position(10, insensitive:get_bottom() + 10)
patterncheck:set_tooltip("Treat search text as a lua pattern")

---@type widget.checkbox
local regexcheck = CheckBox(widget, "Regex")
regexcheck:set_position(10, patterncheck:get_bottom() + 10)
regexcheck:set_tooltip("Treat search text as a regular expression")

---@type widget.checkbox
local replaceinselection = CheckBox(widget, "Replace in Selection")
replaceinselection:set_position(10, regexcheck:get_bottom() + 10)
replaceinselection:set_tooltip("Perform replace only on selected text")

---@type widget.selectbox
local scope = SelectBox(widget, "scope")
scope:set_position(10, regexcheck:get_bottom() + 10)
scope:add_option("current file")
scope:add_option("project files")
scope:set_selected(1)

---@type widget.filepicker
local filepicker = FilePicker(widget)
filepicker:set_mode(FilePicker.mode.DIRECTORY)
filepicker:set_position(10, scope:get_bottom() + 10)
filepicker:set_tooltip("Directory to perform the search")
filepicker:hide()

---@type widget.line
local statusline = Line(widget)
statusline:set_position(0, scope:get_bottom() + 10)

---@type widget.label
local status = Label(widget, "")
status:set_position(10, statusline:get_bottom() + 10)

--------------------------------------------------------------------------------
-- Helper class to keep track of amount of matches and display on status label
--------------------------------------------------------------------------------
---@class plugins.search_ui.result
---@field line integer
---@field col integer

---@class plugins.search_ui.results
---@field text string
---@field matches plugins.search_ui.result[]
---@field doc core.doc?
local Results = {
  text = "",
  matches = {},
  doc = nil,
  prev_search_id = 0
}

---@param text string
---@param doc core.doc
function Results:find(text, doc, force)
  if self.text == text and self.doc == doc and not force then
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

  local search_func

  -- regex search
  if regexcheck:is_checked() then
    local regex_find_offsets = regex.match
    if regex.find_offsets then
      regex_find_offsets = regex.find_offsets
    end
    local pattern = regex.compile(
      findtext:get_text(),
      insensitive:is_checked() and "im" or "m"
    )
    if not pattern then return end
    search_func = function(line_text)
      ---@cast line_text string
      local results = nil
      local offsets = {regex_find_offsets(pattern, line_text)}
      if offsets[1] then
        results = {}
        for i=1, #offsets, 2 do
          table.insert(results, offsets[i])
        end
      end
      return results
    end
  -- plain or pattern search
  else
    local no_case = insensitive:is_checked()
    local is_plain = not patterncheck:is_checked()
    if is_plain and no_case then
      text = text:ulower()
    end
    search_func = function(line_text)
      ---@cast line_text string
      if is_plain and no_case then
        line_text = line_text:ulower()
      end
      local results = nil
      local col1, col2 = line_text:find(text, 1, is_plain)
      if col1 then
        results = {}
        table.insert(results, col1)
        while col1 do
          col1, col2 = line_text:find(text, col2+1, is_plain)
          if col1 then
            table.insert(results, col1)
          end
        end
      end
      return results
    end
  end

  self.prev_search_id = core.add_thread(function()
    self.matches = {}
    local lines_count = #doc.lines
    for i=1, lines_count do
      local offsets = search_func(doc.lines[i])
      if offsets then
        for _, col in ipairs(offsets) do
          table.insert(self.matches, {line = i, col = col})
        end
      end
      if i % 100 == 0 then
        coroutine.yield()
      end
    end
    self:set_status()
  end)
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
  else
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

local function toggle_scope(idx, not_set)
  if not not_set then scope:set_selected(idx) end

  if idx == 1 then
    replacetext:show()
    findnext:show()
    findprev:show()
    replace:show()
    patterncheck:show()
    replaceinselection:show()
    findproject:hide()
    filepicker:hide()

    if view_is_open(doc_view) and findtext:get_text() ~= "" then
      Results:find(findtext:get_text(), doc_view.doc)
    else
      Results:clear()
    end
  else
    replacetext:hide()
    findnext:hide()
    findprev:hide()
    replace:hide()
    patterncheck:hide()
    replaceinselection:hide()
    findproject:show()
    filepicker:show()

    Results:clear()
  end
end

local function project_search()
  if findtext:get_text() == "" then return end
  if not regexcheck:is_checked() then
    projectsearch.search_plain(
      findtext:get_text(), filepicker:get_path(), insensitive:is_checked()
    )
  else
    projectsearch.search_regex(
      findtext:get_text(), filepicker:get_path(), insensitive:is_checked()
    )
  end
  command.perform "search-replace:hide"
end

local find_enabled = true
local function find(reverse)
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
  local cline1, ccol1, cline2, ccol2 = doc:get_selection()
  local line, col = cline1, ccol1
  if reverse and ccol2 < ccol1 then
    col = ccol2
  end

  local opt = {
    wrap = true,
    no_case = insensitive:is_checked(),
    pattern = patterncheck:is_checked(),
    regex = regexcheck:is_checked(),
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
      doc_view:scroll_to_line(line1, true)
      Results:find(text, doc)
    end
  end)
end

local function find_replace()
  if core.last_active_view:is(DocView) then
    doc_view = core.last_active_view
  end
  local doc = doc_view.doc

  if not replaceinselection:is_checked() then
    local line1, col1, line2, col2 = doc:get_selection()
    if line1 ~= line2 or col1 ~= col2 then
      doc:set_selection(line1, col1)
    end
  end

  local old = findtext:get_text()
  local new = replacetext:get_text()

  local results = doc:replace(function(text)
    if not regexcheck:is_checked() then
      if not patterncheck:is_checked() then
        return text:gsub(old:gsub("%W", "%%%1"), new:gsub("%%", "%%%%"), nil)
      else
        return text:gsub(old, new)
      end
    end
    local result, matches = regex.gsub(regex.compile(old, "m"), text, new)
    if type(matches) == "table" then
      return result, #matches
    end
    return result, matches
  end)

  local n = 0
  for _,v in pairs(results) do
    n = n + v
  end

  Results:clear()

  status:set_label(string.format("Total Replaced: %d", n))
end

local current_node = nil
local current_position = ""

local function add_to_node()
  if not inside_node or current_position ~= config.plugins.search_ui.position then
    if
      current_position ~= ""
      and
      current_position ~= config.plugins.search_ui.position
    then
      widget:hide()
      current_node:remove_view(core.root_view.root_node, widget)
      core.root_view.root_node:update_layout()
      widget:set_size(0, 0)
      widget.init_size = true
    end
    local node = core.root_view:get_primary_node()
    if config.plugins.search_ui.position == "right" then
      current_node = node:split("right", widget, {x=true}, true)
      current_position = "right"
    elseif config.plugins.search_ui.position == "top" then
      current_node = node:split("up", widget, {y=true}, false)
      current_position = "top"
    else
      current_node = node:split("down", widget, {y=true}, false)
      current_position = "bottom"
    end
    widget:show()
    inside_node = true
  end
end

---Show or hide the search pane.
---@param av? core.docview
---@param toggle? boolean
local function show_find(av, toggle)
  widget.prev_view = av
  widget:swap_active_child()

  if inside_node and current_position == config.plugins.search_ui.position then
    if toggle then
      widget:toggle_visible(true, false, true)
    elseif not widget:is_visible() then
      widget:show_animated(true, false)
    end
  else
    add_to_node()
  end

  if widget:is_visible() then
    status:set_label("")
    widget:swap_active_child(findtext)
    doc_view = av
    if view_is_open(doc_view) and doc_view.doc then
      local doc_text = doc_view.doc:get_text(
        table.unpack({ doc_view.doc:get_selection() })
      )
      if insensitive:is_checked() then doc_text = doc_text:ulower() end
      local current_text = findtext:get_text()
      if insensitive:is_checked() then current_text = current_text:ulower() end
      if doc_text and doc_text ~= "" and current_text ~= doc_text then
        local original_text = doc_view.doc:get_text(
          table.unpack({ doc_view.doc:get_selection() })
        )
        find_enabled = false
        findtext:set_text(original_text)
        find_enabled = true
      elseif current_text ~= "" and doc_text == "" then
        if scope:get_selected() == 1 then
          find(false)
        end
      end
      if findtext:get_text() ~= "" then
        findtext.textview.doc:set_selection(1, math.huge, 1, 1)
        if scope:get_selected() == 1 then
          Results:find(findtext:get_text(), doc_view.doc)
        else
          Results:clear()
        end
      else
        Results:clear()
      end
    end
  else
    widget:swap_active_child()
    if view_is_open(doc_view) then
      core.set_active_view(doc_view)
    end
  end
end

--------------------------------------------------------------------------------
-- Widgets event overrides
--------------------------------------------------------------------------------
function findtext:on_change(text)
  if scope:get_selected() == 1 and not replaceinselection:is_checked() then
    find(false)
  end
end

function insensitive:on_checked(checked)
  Results:clear()
end

function patterncheck:on_checked(checked)
  if checked then
    regexcheck:set_checked(false)
  end
  Results:clear()
end

function regexcheck:on_checked(checked)
  if checked then
    patterncheck:set_checked(false)
  end
  Results:clear()
end

function scope:on_selected(idx)
  toggle_scope(idx, true)
  if not view_is_open(doc_view) and idx == 1 then
    command.perform "search-replace:hide"
  end
end

function findnext:on_click() find(false) end
function findprev:on_click() find(true) end
function findproject:on_click() project_search() end
function replace:on_click() find_replace() end

---@param self widget
local function update_size(self)
  if config.plugins.search_ui.position == "right" then
    if scope:get_selected() == 1 then
      if self.size.x < replace:get_right() + replace:get_width() / 2 then
        self.size.x = replace:get_right() + replace:get_width() / 2
      end
    else
      if self.size.x < findproject:get_right() + findproject:get_width() * 2 then
        self.size.x = findproject:get_right() + findproject:get_width() * 2
      end
    end
  else
    self:set_size(nil, self:get_real_height() + 10)
  end
end

---@param self widget
local function update_right_positioning(self)
  scope:show()
  label:show()
  status:show()
  line_options:show()
  label:set_label("Find and Replace")

  label:set_position(10, 10)
  line:set_position(0, label:get_bottom() + 10)
  findtext:set_position(10, line:get_bottom() + 10)
  findtext.size.x = self.size.x - 20

  if scope:get_selected() == 1 then
    replacetext:set_position(10, findtext:get_bottom() + 10)
    replacetext.size.x = self.size.x - 20
    findprev:set_position(10, replacetext:get_bottom() + 10)
    findnext:set_position(findprev:get_right() + 5, replacetext:get_bottom() + 10)
    replace:set_position(findnext:get_right() + 5, replacetext:get_bottom() + 10)
    line_options:set_position(0, replace:get_bottom() + 10)
  else
    findproject:set_position(10, findtext:get_bottom() + 10)
    replace:set_position(findproject:get_right() + 5, replacetext:get_bottom() + 10)
    line_options:set_position(0, findproject:get_bottom() + 10)
  end

  insensitive:set_position(10, line_options:get_bottom() + 10)
  if scope:get_selected() == 1 then
    patterncheck:set_position(10, insensitive:get_bottom() + 10)
    regexcheck:set_position(10, patterncheck:get_bottom() + 10)
    replaceinselection:set_position(10, regexcheck:get_bottom() + 10)
    scope:set_position(10, replaceinselection:get_bottom() + 10)
  else
    regexcheck:set_position(10, insensitive:get_bottom() + 10)
    scope:set_position(10, regexcheck:get_bottom() + 10)
  end

  scope:set_size(self.size.x - 20)
  if scope:get_selected() == 1 then
    statusline:set_position(0, scope:get_bottom() + 30)
  else
    filepicker:set_position(10, scope:get_bottom() + 10)
    filepicker:set_size(self.size.x - 20, nil)
    statusline:set_position(0, filepicker:get_bottom() + 30)
  end

  status:set_position(10, statusline:get_bottom() + 10)
  if status.label == "" then
    statusline:hide()
  else
    statusline:show()
  end

  if self.init_size then
    update_size(self)
    self.init_size = false
    self:show_animated(false, true)
  end

  add_to_node()
end

---@param self widget
local function update_bottom_positioning(self)
  scope:hide()
  statusline:hide()

  if scope:get_selected() == 1 then
    label:hide()
    status:show()
    status:set_position(10, 10)
    replaceinselection:set_position(self.size.x - replaceinselection:get_width() - 10, 10)
    regexcheck:set_position(replaceinselection:get_position().x - 10 - regexcheck:get_width(), 10)
    patterncheck:set_position(regexcheck:get_position().x - 10  - patterncheck:get_width(), 10)
    insensitive:set_position(patterncheck:get_position().x - 10 - insensitive:get_width(), 10)
    line:set_position(0, status:get_bottom() + 10)
  else
    label:show()
    status:hide()
    label:set_label("Find in Directory")
    label:set_position(10, 10)
    regexcheck:set_position(self.size.x - regexcheck:get_width() - 10, 10)
    insensitive:set_position(regexcheck:get_position().x - 10 - insensitive:get_width(), 10)
    line:set_position(0, label:get_bottom() + 10)
  end

  if scope:get_selected() == 1 then
    findtext:set_position(10, line:get_bottom() + 10)
    findtext.size.x = self.size.x - 40 - findprev:get_width() - findnext:get_width()
    findnext:set_position(self.size.x - 10 - findnext:get_width(), line:get_bottom() + 10)
    findprev:set_position(findnext:get_position().x - 10 - findprev:get_width(), line:get_bottom() + 10)
    replacetext:set_position(10, findtext:get_bottom() + 10)
    replacetext.size.x = findtext.size.x
    replace:set_position(self.size.x - 15 - replace:get_width(), findtext:get_bottom() + 10)
    replace.size.x = findprev:get_width() + findnext:get_width() + 10
    line_options:hide()
  else
    findtext:set_position(10, line:get_bottom() + 10)
    findtext.size.x = self.size.x - 30 - findproject:get_width()
    findproject:set_position(self.size.x - 10 - findproject:get_width(), line:get_bottom() + 10)
    replace:set_position(findproject:get_right() + 5, replacetext:get_bottom() + 10)
    line_options:show()
    line_options:set_position(0, findproject:get_bottom() + 10)
    filepicker:set_position(10, line_options:get_bottom() + 10)
    filepicker:set_size(self.size.x - 20, nil)
  end

  if self.init_size then
    update_size(self)
    self.init_size = false
    self:show_animated(true, false)
  end

  add_to_node()
end

-- reposition items on scale changes only when needed
local ui_prev_size = { x = widget.size.x, y = widget.size.y }
local ui_prev_position = config.plugins.search_ui.position
local ui_prev_scope = scope:get_selected()
function widget:update()
  if Widget.update(self) then
    if
      ui_prev_scope ~= scope:get_selected()
      or
      ui_prev_size.x ~= widget.size.x or ui_prev_size.y ~= widget.size.y
      or
      ui_prev_position ~= config.plugins.search_ui.position
    then
      if config.plugins.search_ui.position == "right" then
        update_right_positioning(self)
      else
        update_bottom_positioning(self)
      end
      ui_prev_size.x = widget.size.x
      ui_prev_size.y = widget.size.y
      ui_prev_position = config.plugins.search_ui.position
      ui_prev_scope = scope:get_selected()
    end
  end
end

function widget:on_scale_change(...)
  Widget.on_scale_change(self, ...)
  update_size(self)
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
    widget:is_visible()
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
    widget.prev_view = doc_view
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
    elseif widget:is_visible() then
      return true, doc_view
    elseif scope:get_selected() == 2 then
      return true, nil
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

command.add(function() return widget:is_visible() and not core.active_view:is(CommandView) end, {
  ["search-replace:hide"] = function()
    widget:swap_active_child()
    if config.plugins.search_ui.position == "right" then
      widget:hide_animated(false, true)
    else
      widget:hide_animated(true, false)
    end
    if view_is_open(doc_view) then
      core.set_active_view(doc_view)
    end
  end,

  ["search-replace:file-search"] = function()
    toggle_scope(1)
    command.perform "search-replace:show"
  end,

  ["search-replace:next"] = function()
    find(false)
  end,

  ["search-replace:previous"] = function()
    find(true)
  end,

  ["search-replace:toggle-sensitivity"] = function()
    insensitive:set_checked(not insensitive:is_checked())
    Results:clear()
  end,

  ["search-replace:toggle-regex"] = function()
    regexcheck:set_checked(not regexcheck:is_checked())
    Results:clear()
  end,

  ["search-replace:toggle-in-selection"] = function()
    replaceinselection:set_checked(not replaceinselection:is_checked())
  end
})

command.add(
  function()
    local active = widget.child_active == findtext and findtext or replacetext
    return widget:is_visible()
      and
      not core.active_view:is(CommandView)
      and
      (
        widget.child_active == active
        and
        core.active_view == active.textview
      )
  end,
  {
    ["search-replace:perform"] = function()
      if scope:get_selected() == 1 then
        if widget.child_active == findtext then
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
        else
          find_replace()
        end
      else
        project_search()
      end
    end,
    ["search-replace:perform-previous"] = function()
      find(true)
    end
  }
)

command.add(
  function()
    if not widget:is_visible() then return false end
    if core.active_view == findtext.textview then
      return true, replacetext
    elseif core.active_view == replacetext.textview then
      return true, findtext
    end
    return false
  end,
  {
    ["search-replace:switch-input"] = function(next)
        widget:swap_active_child(next)
        next.textview.doc:set_selection(1, math.huge, 1, 1)
        widget.prev_view = doc_view
    end
  }
)

--------------------------------------------------------------------------------
-- Override core find/replace commands
--------------------------------------------------------------------------------
local find_replace_find = command.map["find-replace:find"].perform
command.map["find-replace:find"].perform = function(...)
  if config.plugins.search_ui.replace_core_find then
    toggle_scope(1)
    command.perform "search-replace:show"
  else
    find_replace_find(...)
  end
end

local find_replace_replace = command.map["find-replace:replace"].perform
command.map["find-replace:replace"].perform = function(...)
  if config.plugins.search_ui.replace_core_find then
    toggle_scope(1)
    command.perform "search-replace:show"
  else
    find_replace_replace(...)
  end
end

local find_replace_repeat = command.map["find-replace:repeat-find"].perform
command.map["find-replace:repeat-find"].perform = function(...)
  if
    widget:is_visible()
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
    widget:is_visible()
    or
    (config.plugins.search_ui.replace_core_find and findtext:get_text() ~= "")
  then
    find(true)
    return
  end
  find_replace_previous(...)
end

local project_search_find = command.map["project-search:find"].perform
command.map["project-search:find"].perform = function(path)
  if config.plugins.search_ui.replace_core_find then
    toggle_scope(2)
    if path then
      filepicker:set_path(path)
    end
    local av = doc_view
    if
      core.active_view:extends(DocView)
      and
      core.active_view ~= findtext.textview
      and
      core.active_view ~= replacetext.textview
    then
      av = core.active_view
    end
    show_find(av, false)
    return
  end
  project_search_find(path)
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
  ["ctrl+i"] = "search-replace:toggle-sensitivity",
  ["ctrl+shift+i"] = "search-replace:toggle-regex",
  ["ctrl+alt+i"] = "search-replace:toggle-in-selection",
  ["ctrl+f"] = "search-replace:file-search",
  ["tab"] = "search-replace:switch-input",
  ["shift+tab"] = "search-replace:switch-input"
}


return widget
