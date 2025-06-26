-- mod-version:3
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local Doc = require "core.doc"
local DocView = require "core.docview"
local RootView = require "core.rootview"

---@class plugins.autocomplete.symbolinfo
---Text value of the symbol displayed on the autocomplete box.
---@field text string
---Additional information displayed on autocomplete box, eg: item type.
---@field info? string
---Name of a registered icon.
---@field icon? string
---Description shown when the symbol is hovered on the autocomplete box.
---@field desc? string
---An optional callback called once when the symbol is hovered.
---@field onhover? fun(idx:integer,item:plugins.autocomplete.symbolinfo)
---An optional callback called when the symbol is selected.
---@field onselect? fun(idx:integer,item:plugins.autocomplete.symbolinfo):boolean
---Optional data that can be used for onhover and onselect callbacks.
---@field data? any

---@class plugins.autocomplete.symbols
---Name of the symbols table.
---@field name string
---Lua patterns which match the files where the symbols are valid.
---@field files string | table<integer,string>
---List of symbols that belong to this symbols table.
---@field items table<string,plugins.autocomplete.symbolinfo|string|false|nil>

---@class plugins.autocomplete.map
---Lua patterns which match the files where the symbols are valid.
---@field files string | table<integer,string>
---List of symbols that belong to this symbols table.
---@field items table<string,plugins.autocomplete.symbolinfo>

---@class plugins.autocomplete.icon
---@field char string
---@field font renderer.font
---@field color string | renderer.color

---@alias plugins.autocomplete.onclose fun(doc:core.doc,item:plugins.autocomplete.symbolinfo)

---@class plugins.autocomplete.cachedata
---@field last_change_id number
---@field symbols table<string,boolean>

---Symbols cache of all open documents
---@type table<core.doc,plugins.autocomplete.cachedata>
local cache = setmetatable({}, { __mode = "k" })

---Configuration options for `autocomplete` plugin.
---@class config.plugins.autocomplete
---Amount of characters that need to be written for autocomplete
---@field min_len integer
---The max amount of visible items
---@field max_height integer
---The max amount of scrollable items
---@field max_suggestions integer
---Maximum amount of symbols to cache per document
---@field max_symbols integer
---Which symbols to show on the suggestions list: global, local, related, none
---@field suggestions_scope "global" | "local" | "related" | "none"
---Font size of the description box
---@field desc_font_size number
---Do not show the icons associated to the suggestions
---@field hide_icons boolean
---Position where icons will be displayed on the suggestions list
---@field icon_position "left" | "right"
---Do not show the additional information related to a suggestion
---@field hide_info boolean
config.plugins.autocomplete = common.merge({
  -- Amount of characters that need to be written for autocomplete
  min_len = 3,
  -- The max amount of visible items
  max_height = 6,
  -- The max amount of scrollable items
  max_suggestions = 100,
  -- Maximum amount of symbols to cache per document
  max_symbols = 4000,
  -- Which symbols to show on the suggestions list: global, local, related, none
  suggestions_scope = "global",
  -- Font size of the description box
  desc_font_size = 12,
  -- Do not show the icons associated to the suggestions
  hide_icons = false,
  -- Position where icons will be displayed on the suggestions list
  icon_position = "left",
  -- Do not show the additional information related to a suggestion
  hide_info = false,
  -- The config specification used by gui generators
  config_spec = {
    name = "Autocomplete",
    {
      label = "Minimum Length",
      description = "Amount of characters that need to be written for autocomplete to popup.",
      path = "min_len",
      type = "number",
      default = 3,
      min = 1,
      max = 5
    },
    {
      label = "Maximum Height",
      description = "The maximum amount of visible items.",
      path = "max_height",
      type = "number",
      default = 6,
      min = 1,
      max = 20
    },
    {
      label = "Maximum Suggestions",
      description = "The maximum amount of scrollable items.",
      path = "max_suggestions",
      type = "number",
      default = 100,
      min = 10,
      max = 10000
    },
    {
      label = "Maximum Symbols",
      description = "Maximum amount of symbols to cache per document.",
      path = "max_symbols",
      type = "number",
      default = 4000,
      min = 1000,
      max = 10000
    },
    {
      label = "Suggestions Scope",
      description = "Which symbols to show on the suggestions list.",
      path = "suggestions_scope",
      type = "selection",
      default = "global",
      values = {
        {"All Documents", "global"},
        {"Current Document", "local"},
        {"Related Documents", "related"},
        {"Known Symbols", "none"}
      },
      on_apply = function(value)
        if value == "global" then
          for _, doc in ipairs(core.docs) do
            if cache[doc] then cache[doc] = nil end
          end
        end
      end
    },
    {
      label = "Description Font Size",
      description = "Font size of the description box.",
      path = "desc_font_size",
      type = "number",
      default = 12,
      min = 8
    },
    {
      label = "Hide Icons",
      description = "Do not show icons on the suggestions list.",
      path = "hide_icons",
      type = "toggle",
      default = false
    },
    {
      label = "Icons Position",
      description = "Position to display icons on the suggestions list.",
      path = "icon_position",
      type = "selection",
      default = "left",
      values = {
        {"Left", "left"},
        {"Right", "Right"}
      }
    },
    {
      label = "Hide Items Info",
      description = "Do not show the additional info related to each suggestion.",
      path = "hide_info",
      type = "toggle",
      default = false
    }
  }
}, config.plugins.autocomplete)

---@class plugins.autocomplete
local autocomplete = {}

---@type table<string,plugins.autocomplete.map>
autocomplete.map = {}
---@type table<string,plugins.autocomplete.map>
autocomplete.map_manually = {}
---@type nil | plugins.autocomplete.onclose
autocomplete.on_close = nil
---@type table<string,plugins.autocomplete.icon>
autocomplete.icons = {}

-- Flag that indicates if the autocomplete box was manually triggered
-- with the autocomplete.complete() function to prevent the suggestions
-- from getting cluttered with arbitrary document symbols by using the
-- autocomplete.map_manually table.
local triggered_manually = false

local mt = { __tostring = function(t) return t.text end }

---Register a symbols table used for autocompletion.
---@param t plugins.autocomplete.symbols
---@param manually_triggered? boolean
function autocomplete.add(t, manually_triggered)
  local items = {}
  for text, info in pairs(t.items) do
    if type(info) == "table" then
      table.insert(
        items,
        setmetatable(
          {
            text = text,
            info = info.info,
            icon = info.icon,
            desc = info.desc,
            onhover = info.onhover,
            onselect = info.onselect,
            data = info.data
          },
          mt
        )
      )
    else
      info = (type(info) == "string") and info
      table.insert(items, setmetatable({ text = text, info = info }, mt))
    end
  end

  if not manually_triggered then
    autocomplete.map[t.name] =  { files = t.files or ".*", items = items }
  else
    autocomplete.map_manually[t.name] =  { files = t.files or ".*", items = items }
  end
end

---Same as translate.start_of_word but uses `symbol_non_word_chars` instead.
---@param doc core.doc
---@param line integer
---@param col integer
---@return integer line
---@return integer col
local function translate_start_of_word(doc, line, col)
  while true do
    local line2, col2 = doc:position_offset(line, col, -1)
    local char = doc:get_char(line2, col2)
    if doc:get_non_word_chars(true):find(char, nil, true)
    or line == line2 and col == col2 then
      break
    end
    line, col = line2, col2
  end
  return line, col
end

---Retrieve the current document partial symbol.
---@return string partial
---@return integer line1
---@return integer col1
---@return integer line2
---@return integer col2
function autocomplete.get_partial_symbol()
  local doc = core.active_view.doc
  local line2, col2 = doc:get_selection()
  local line1, col1 = doc:position_offset(line2, col2, translate_start_of_word)
  return doc:get_text(line1, col1, line2, col2), line1, col1, line2, col2
end

--
-- Thread that scans open document symbols and cache them
--
local global_symbols = {}

core.add_thread(function()
  ---@param doc core.doc
  ---@return table<string,string>
  local function load_syntax_symbols(doc)
    if doc.syntax and not autocomplete.map["language_"..doc.syntax.name] then
      local symbols = {
        name = "language_"..doc.syntax.name,
        files = doc.syntax.files,
        items = {}
      }
      for name, type in pairs(doc.syntax.symbols) do
        symbols.items[name] = type
      end
      autocomplete.add(symbols)
      return symbols.items
    end
    return {}
  end

  ---@param doc core.doc
  ---@return table<string,boolean>
  local function get_symbols(doc)
    local s = {}
    local syntax_symbols = load_syntax_symbols(doc)
    local max_symbols = config.plugins.autocomplete.max_symbols
    if doc.disable_symbols then return s end
    local i = 1
    local symbols_count = 0
    local symbol_pattern = doc:get_symbol_pattern()
    while i <= #doc.lines do
      for sym in doc.lines[i]:gmatch(symbol_pattern) do
        if not s[sym] and not syntax_symbols[sym] then
          symbols_count = symbols_count + 1
          if symbols_count > max_symbols then
            s = nil
            doc.disable_symbols = true
            local filename_message
            if doc.filename then
              filename_message = doc.filename
            else
              filename_message = "unnamed"
            end
            core.warn(
              "Too many symbols in '%s': stopping auto-complete for this document "
                .. "according to config.plugins.autocomplete.max_symbols.",
              filename_message
            )
            collectgarbage('collect')
            return {}
          end
          s[sym] = true
        end
      end
      i = i + 1
      if i % 100 == 0 then coroutine.yield() end
    end
    return s
  end

  ---@param doc core.doc
  ---@return boolean
  local function cache_is_valid(doc)
    local c = cache[doc]
    return c and c.last_change_id == doc:get_change_id()
  end

  while true do
    local symbols = {}

    -- lift all symbols from all docs
    for _, doc in ipairs(core.docs) do
      -- update the cache if the doc has changed since the last iteration
      if not cache_is_valid(doc) then
        cache[doc] = {
          last_change_id = doc:get_change_id(),
          symbols = get_symbols(doc)
        }
      end
      -- update symbol set with doc's symbol set
      if config.plugins.autocomplete.suggestions_scope == "global" then
        for sym in pairs(cache[doc].symbols) do
          symbols[sym] = true
        end
      end
      coroutine.yield()
    end

    -- update global symbols list
    if config.plugins.autocomplete.suggestions_scope == "global" then
      global_symbols = symbols
    end

    -- wait for next scan
    local valid = true
    while valid do
      coroutine.yield(1)
      for _, doc in ipairs(core.docs) do
        if not cache_is_valid(doc) then
          valid = false
          break
        end
      end
    end

  end
end)


local partial = ""
local suggestions_offset = 1
local suggestions_idx = 1
local suggestions = {}
local last_line, last_col


local function reset_suggestions()
  suggestions_offset = 1
  suggestions_idx = 1
  suggestions = {}

  triggered_manually = false

  local doc = core.active_view.doc
  if autocomplete.on_close then
    autocomplete.on_close(doc, suggestions[suggestions_idx])
    autocomplete.on_close = nil
  end
end

local function update_suggestions()
  local doc = core.active_view.doc
  local filename = doc and doc.filename or ""

  local map = autocomplete.map

  if triggered_manually then
    map = autocomplete.map_manually
  end

  local assigned_sym = {}

  -- get all relevant suggestions for given filename
  local items = {}
  for _, v in pairs(map) do
    if common.match_pattern(filename, v.files) then
      for _, item in pairs(v.items) do
        table.insert(items, item)
        assigned_sym[item.text] = true
      end
    end
  end

  -- Append the global, local or related text symbols if applicable
  local scope = config.plugins.autocomplete.suggestions_scope

  if not triggered_manually then
    local text_symbols = nil

    if scope == "global" then
      text_symbols = global_symbols
    elseif scope == "local" and cache[doc] and cache[doc].symbols then
      text_symbols = cache[doc].symbols
    elseif scope == "related" then
      for _, d in ipairs(core.docs) do
        if doc.syntax == d.syntax then
          if cache[d] and cache[d].symbols then
            for name in pairs(cache[d].symbols) do
              if not assigned_sym[name] then
                table.insert(items, setmetatable(
                  {text = name, info = "normal"}, mt
                ))
              end
            end
          end
        end
      end
    end

    if text_symbols then
      for name in pairs(text_symbols) do
        if not assigned_sym[name] then
          table.insert(items, setmetatable({text = name, info = "normal"}, mt))
        end
      end
    end
  end

  -- when triggered manually and first character is a punctuation, it causes
  -- none of the items to match if they don't also start with the punctuation,
  -- we remove the punctuations to ensure results with plugins like lsp
  if triggered_manually then partial = partial:gsub("^%p+", "") end

  -- fuzzy match, remove duplicates and store
  items = common.fuzzy_match(items, partial, false)
  local j = 1
  for i = 1, config.plugins.autocomplete.max_suggestions do
    suggestions[i] = items[j]
    while items[j] and items[i].text == items[j].text do
      items[i].info = items[i].info or items[j].info
      j = j + 1
    end
  end
  suggestions_idx = 1
  suggestions_offset = 1
end

local function get_active_view()
  if core.active_view:is(DocView) then
    return core.active_view
  end
end

local function get_suggestions_rect(av)
  if #suggestions == 0 then
    return 0, 0, 0, 0
  end

  local line, col = av.doc:get_selection()
  local x, y = av:get_line_screen_position(line, col - #partial)
  y = y + av:get_line_height() + style.padding.y
  local font = av:get_font()
  local th = font:get_height()
  local has_icons = false
  local hide_info = config.plugins.autocomplete.hide_info
  local hide_icons = config.plugins.autocomplete.hide_icons

  local max_width = 0
  local width_exceeds = false
  local win_width = system.get_window_size(core.window) - style.padding.x  * 2
  for i, s in ipairs(suggestions) do
    local w = font:get_width(s.text)
    if s.info and not hide_info then
      w = w + style.font:get_width(s.info) + style.padding.x
    end
    local icon = s.icon or s.info
    if not hide_icons and icon and autocomplete.icons[icon] then
      w = w + autocomplete.icons[icon].font:get_width(
        autocomplete.icons[icon].char
      ) + (style.padding.x / 2)
      has_icons = true
    end
    max_width = math.max(max_width, w)
    if max_width > win_width then
      width_exceeds = true
      if i > 1 then break end
    end
  end

  local ah = config.plugins.autocomplete.max_height

  local max_items = #suggestions
  if max_items > ah then
    max_items = ah
  end

  -- additional line to display total items
  max_items = max_items + 1

  if max_width < 150 then
    max_width = 150
  end

  if not width_exceeds then
    -- if portion not visiable to right, reposition to DocView right margin
    if max_width + style.padding.x * 2 >= av.size.x then
      x = win_width / 2 - max_width / 2
    elseif (x - av.position.x) + max_width > av.size.x then
      x = (av.size.x + av.position.x) - max_width - (style.padding.x * 2)
    end
  else
    max_width = win_width - style.padding.x * 2
    x = style.padding.x * 2
  end

  return
    x - style.padding.x,
    y - style.padding.y,
    max_width + style.padding.x * 2,
    max_items * (th + style.padding.y) + style.padding.y,
    has_icons
end

local function wrap_line(line, max_chars)
  if #line > max_chars then
    local lines = {}
    local line_len = #line
    local new_line = ""
    local prev_char = ""
    local position = 0
    local indent = line:match("^%s+")
    for char in line:gmatch(".") do
      position = position + 1
      if #new_line < max_chars then
        new_line = new_line .. char
        prev_char = char
        if position >= line_len then
          table.insert(lines, new_line)
        end
      else
        if
          not prev_char:match("%s")
          and
          not string.sub(line, position+1, 1):match("%s")
          and
          position < line_len
        then
          new_line = new_line .. "-"
        end
        table.insert(lines, new_line)
        if indent then
          new_line = indent .. char
        else
          new_line = char
        end
      end
    end
    return lines
  end
  return line
end

local previous_scale = SCALE
local desc_font = style.code_font:copy(
  config.plugins.autocomplete.desc_font_size * SCALE
)
local function draw_description_box(text, sx, sy, sw, sh)
  if previous_scale ~= SCALE then
    desc_font = style.code_font:copy(
      config.plugins.autocomplete.desc_font_size * SCALE
    )
    previous_scale = SCALE
  end

  local ww = system.get_window_size(core.window)

  local font = desc_font
  local lh = font:get_height()
  local y = sy + style.padding.y
  local x = sx + sw + style.padding.x / 4
  local width = 0
  local char_width = font:get_width(" ")
  local draw_left = false;

  local max_chars = 0
  if sw > (ww - style.padding.x * 2) * 0.5 then
    sy = sy + sh + style.padding.x / 4
    y = sy + style.padding.y
    x = sx
    max_chars = ((ww - x - style.padding.x * 4) / char_width)
  elseif sx < ww - sx - sw then
    max_chars = (((ww) - x) / char_width) - 5
  else
    draw_left = true;
    max_chars = (
      (sx - (style.padding.x / 4) - style.scrollbar_size)
      / char_width
    ) - 5
  end

  local lines = {}
  for line in string.gmatch(text.."\n", "(.-)\n") do
    local wrapper_lines = wrap_line(line, max_chars)
    if type(wrapper_lines) == "table" then
      for _, wrapped_line in pairs(wrapper_lines) do
        width = math.max(width, font:get_width(wrapped_line))
        table.insert(lines, wrapped_line)
      end
    else
      width = math.max(width, font:get_width(line))
      table.insert(lines, line)
    end
  end

  if draw_left then
    x = sx - (style.padding.x / 4) - width - (style.padding.x * 2)
  end

  local height = #lines * font:get_height()

  -- draw background rect
  renderer.draw_rect(
    x,
    sy,
    width + style.padding.x * 2,
    height + style.padding.y * 2,
    style.background3
  )

  -- draw text
  for _, line in pairs(lines) do
    common.draw_text(
      font, style.text, line, "left",
      x + style.padding.x, y, width, lh
    )
    y = y + lh
  end
end

local function draw_suggestions_box(av)
  if #suggestions <= 0 then
    return
  end

  local ah = config.plugins.autocomplete.max_height

  -- draw background rect
  local rx, ry, rw, rh, has_icons = get_suggestions_rect(av)
  renderer.draw_rect(rx, ry, rw, rh, style.background3)

  -- draw text
  local font = av:get_font()
  local lh = font:get_height() + style.padding.y
  local y = ry + style.padding.y / 2
  local show_count = math.min(#suggestions, ah)
  local start_index = suggestions_offset
  local hide_info = config.plugins.autocomplete.hide_info
  local dots_width = font:get_width("...")

  for i=start_index, start_index+show_count-1, 1 do
    if not suggestions[i] then
      break
    end
    local s = suggestions[i]

    local icon_l_padding, icon_r_padding = 0, 0

    if has_icons then
      local icon = s.icon or s.info
      if icon and autocomplete.icons[icon] then
        local ifont = autocomplete.icons[icon].font
        local itext = autocomplete.icons[icon].char
        local icolor = autocomplete.icons[icon].color
        if i == suggestions_idx then
          icolor = style.accent
        elseif type(icolor) == "string" then
          icolor = style.syntax[icolor]
        end
        if config.plugins.autocomplete.icon_position == "left" then
          common.draw_text(
            ifont, icolor, itext, "left", rx + style.padding.x, y, rw, lh
          )
          icon_l_padding = ifont:get_width(itext) + (style.padding.x / 2)
        else
          common.draw_text(
            ifont, icolor, itext, "right", rx, y, rw - style.padding.x, lh
          )
          icon_r_padding = ifont:get_width(itext) + (style.padding.x / 2)
        end
      end
    end

    local color = (i == suggestions_idx) and style.text or style.dim

    local iw = 0
    if s.info and not hide_info then
      local ix2, _, ix1, _ = common.draw_text(
        style.font, color, s.info, "right",
        rx, y, rw - icon_r_padding - style.padding.x, lh
      )
      iw = ix2 - ix1 + style.padding.x
    end
    color = (i == suggestions_idx) and style.accent or style.text
    local icon_padding = icon_l_padding > 0 and icon_l_padding or icon_r_padding
    local text_width = rw - icon_padding - style.padding.x - iw
    local text_padding = rx + icon_l_padding + style.padding.x
    core.push_clip_rect(text_padding, y, text_width, lh)
    local tx2, _, tx1, _ = common.draw_text(
      font, color, s.text, "left",
      text_padding, y, text_width, lh
    )
    if tx2 - tx1 > text_width then
      renderer.draw_rect(
        text_padding + text_width - dots_width, y,
        dots_width, lh,
        style.background3
      )
      common.draw_text(
        font, color, "...", "right",
        text_padding, y, text_width, lh
      )
    end
    core.pop_clip_rect()
    y = y + lh
    if suggestions_idx == i then
      if s.onhover then
        s.onhover(suggestions_idx, s)
        s.onhover = nil
      end
      if s.desc and #s.desc > 0 then
        draw_description_box(s.desc, rx, ry, rw, rh)
      end
    end
  end

  renderer.draw_rect(rx, y, rw, 2, style.caret)
  renderer.draw_rect(rx, y+2, rw, lh, style.background)
  common.draw_text(
    style.font,
    style.accent,
    "Items",
    "left",
    rx + style.padding.x, y, rw, lh
  )
  common.draw_text(
    style.font,
    style.accent,
    tostring(suggestions_idx) .. "/" .. tostring(#suggestions),
    "right",
    rx, y, rw - style.padding.x, lh
  )
end

local function show_autocomplete()
  local av = get_active_view()
  if av then
    -- update partial symbol and suggestions
    partial = autocomplete.get_partial_symbol()

    if #partial >= config.plugins.autocomplete.min_len or triggered_manually then
      update_suggestions()

      if not triggered_manually then
        last_line, last_col = av.doc:get_selection()
      else
        local line, col = av.doc:get_selection()
        local char = av.doc:get_char(line, col-1, line, col-1)

        if char:match("%s") or (char:match("%p") and col ~= last_col) then
          reset_suggestions()
        end
      end
    else
      reset_suggestions()
    end

    -- scroll if rect is out of bounds of view
    local _, y, _, h = get_suggestions_rect(av)
    local limit = av.position.y + av.size.y
    if y + h > limit then
      av.scroll.to.y = av.scroll.y + y + h - limit
    end
  end
end

--
-- Patch event logic into RootView and Doc
--
local on_text_input = RootView.on_text_input
local on_text_remove = Doc.remove
local on_doc_close = Doc.on_close
local update = RootView.update
local draw = RootView.draw

RootView.on_text_input = function(...)
  on_text_input(...)
  show_autocomplete()
end

Doc.remove = function(self, line1, col1, line2, col2)
  on_text_remove(self, line1, col1, line2, col2)

  if triggered_manually and line1 == line2 then
    if last_col >= col1 then
      reset_suggestions()
    else
      show_autocomplete()
    end
  end
end

Doc.on_close = function(self)
  on_doc_close(self)
  if cache[self] then cache[self] = nil end
end

RootView.update = function(...)
  update(...)

  local av = get_active_view()
  if av then
    -- reset suggestions if caret was moved
    local line, col = av.doc:get_selection()

    if not triggered_manually then
      if line ~= last_line or col ~= last_col then
        reset_suggestions()
      end
    else
      if line ~= last_line or col < last_col then
        reset_suggestions()
      end
    end
  end
end

RootView.draw = function(...)
  draw(...)

  local av = get_active_view()
  if av then
    -- draw suggestions box after everything else
    core.root_view:defer_draw(draw_suggestions_box, av)
  end
end

--
-- Public functions
--

---Manually invoke the completion list using already registered symbols.
---@param on_close? plugins.autocomplete.onclose
function autocomplete.open(on_close)
  triggered_manually = true

  if on_close then
    autocomplete.on_close = on_close
  end

  local av = get_active_view()
  if av then
    partial = autocomplete.get_partial_symbol()
    last_line, last_col = av.doc:get_selection()
    update_suggestions()
  end
end

---Manually close the completions list.
function autocomplete.close()
  reset_suggestions()
end

---Check if the completion lists is visible.
---@return boolean
function autocomplete.is_open()
  return #suggestions > 0
end

---Manually invoke the completion list using the provided symbols.
---@param completions plugins.autocomplete.symbols
---@param on_close? plugins.autocomplete.onclose
function autocomplete.complete(completions, on_close)
  reset_suggestions()

  autocomplete.map_manually = {}
  autocomplete.add(completions, true)

  autocomplete.open(on_close)
end

---Check if autocomplete can be triggered by checking if current
---partial symbol meets the required minimum autocompletion len.
---@return boolean
function autocomplete.can_complete()
  if #partial >= config.plugins.autocomplete.min_len then
    return true
  end
  return false
end

---Register a font icon that can be assigned to completion items.
---@param name string
---@param character string
---@param font? renderer.font
---@param color? string | renderer.color A style.syntax[] name or specific color
function autocomplete.add_icon(name, character, font, color)
  local color_type = type(color)
  assert(
    not color or color_type == "table"
      or (color_type == "string" and style.syntax[color]),
    "invalid icon color given"
  )
  autocomplete.icons[name] = {
    char = character,
    font = font or style.code_font,
    color = color or "keyword"
  }
end

--
-- Register built-in syntax symbol types icon
--
for name, _ in pairs(style.syntax) do
  autocomplete.add_icon(name, "M", style.icon_font, name)
end

--
-- Commands
--
local function predicate()
  local active_docview = get_active_view()
  return active_docview and #suggestions > 0, active_docview
end

command.add(predicate, {
  ["autocomplete:complete"] = function(dv)
    local doc = dv.doc
    local item = suggestions[suggestions_idx]
    local inserted = false
    if item.onselect then
      inserted = item.onselect(suggestions_idx, item)
    end
    if not inserted then
      local current_partial = autocomplete.get_partial_symbol()
      local sz = #current_partial

      for _, line1, col1, line2, _ in doc:get_selections(true) do
        local n = col1 - 1
        local line = doc.lines[line1]
        for i = 1, sz + 1 do
          local j = sz - i
          local subline = line:sub(n - j, n)
          local subpartial = current_partial:sub(i, -1)
          if subpartial == subline then
            doc:remove(line1, col1, line2, n - j)
            break
          end
        end
      end

      doc:text_input(item.text)
    end
    reset_suggestions()
  end,

  ["autocomplete:previous"] = function()
    suggestions_idx = (suggestions_idx - 2) % #suggestions + 1

    local ah = math.min(config.plugins.autocomplete.max_height, #suggestions)
    if suggestions_offset > suggestions_idx then
      suggestions_offset = suggestions_idx
    elseif suggestions_offset + ah < suggestions_idx + 1 then
      suggestions_offset = suggestions_idx - ah + 1
    end
  end,

  ["autocomplete:next"] = function()
    suggestions_idx = (suggestions_idx % #suggestions) + 1

    local ah = math.min(config.plugins.autocomplete.max_height, #suggestions)
    if suggestions_offset + ah < suggestions_idx + 1 then
      suggestions_offset = suggestions_idx - ah + 1
    elseif suggestions_offset > suggestions_idx then
      suggestions_offset = suggestions_idx
    end
  end,

  ["autocomplete:cycle"] = function()
    local newidx = suggestions_idx + 1
    suggestions_idx = newidx > #suggestions and 1 or newidx
  end,

  ["autocomplete:cancel"] = function()
    reset_suggestions()
  end,
})

--
-- Keymaps
--
keymap.add {
  ["tab"]    = "autocomplete:complete",
  ["up"]     = "autocomplete:previous",
  ["down"]   = "autocomplete:next",
  ["escape"] = "autocomplete:cancel",
}


return autocomplete
