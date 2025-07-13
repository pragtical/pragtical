-- mod-version:3

local core = require "core"
local style = require "core.style"
local Doc = require "core.doc"
local DocView = require "core.docview"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"

---Base configuration options.
---@class config.plugins.drawwhitespace.options
---Disable or enable the drawing of white spaces.
---@field enabled boolean
---Show white spaces at the beginning of a line.
---@field show_leading boolean
---Show white spaces at the end of a line.
---@field show_trailing boolean
---Show white spaces between words.
---@field show_middle boolean
---Show white spaces on selected text only.
---@field show_selected_only boolean
---Minimum amount of white spaces between words in order to show them.
---@field show_middle_min integer
---Default color used to render the white spaces.
---@field color renderer.color
---Color for leading white spaces.
---@field leading_color renderer.color
---Color for middle white spaces.
---@field middle_color renderer.color
---Color for trailing white spaces.
---@field trailing_color renderer.color

---Character substitution options.
---@class config.plugins.drawwhitespace.substitutions : config.plugins.drawwhitespace.options
---The character to substitute.
---@field char string
---The substitution character,
---@field sub string

---Configuration options for `drawwhitespace` plugin.
---@class config.plugins.drawwhitespace : config.plugins.drawwhitespace.options
---Character substitutions.
---@field substitutions config.plugins.drawwhitespace.substitutions[]
config.plugins.drawwhitespace = common.merge({
  enabled = false,
  show_leading = true,
  show_trailing = true,
  show_middle = true,
  show_selected_only = false,

  show_middle_min = 1,

  color = style.syntax.whitespace or style.syntax.comment,
  leading_color = nil,
  middle_color = nil,
  trailing_color = nil,

  substitutions = {
    {
      char = " ",
      sub = "·",
      -- You can put any of the previous options here too.
      -- For example:
      -- show_middle_min = 2,
      -- show_leading = false,
    },
    {
      char = "\t",
      sub = "»",
    },
    {
      char = "\26",
      sub = "█",
      show_leading = true,
      show_trailing = true,
      show_middle = true,
      binary_only = true
    },
  },

  config_spec = {
    name = "Draw Whitespace",
    {
      label = "Enabled",
      description = "Disable or enable the drawing of white spaces.",
      path = "enabled",
      type = "toggle",
      default = false
    },
    {
      label = "Show Leading",
      description = "Draw whitespaces starting at the beginning of a line.",
      path = "show_leading",
      type = "toggle",
      default = true,
    },
    {
      label = "Show Middle",
      description = "Draw whitespaces on the middle of a line.",
      path = "show_middle",
      type = "toggle",
      default = true,
    },
    {
      label = "Show Trailing",
      description = "Draw whitespaces on the end of a line.",
      path = "show_trailing",
      type = "toggle",
      default = true,
    },
    {
      label = "Show Selected Only",
      description = "Only draw whitespaces if it is within a selection.",
      path = "show_selected_only",
      type = "toggle",
      default = false,
    },
    {
      label = "Show Trailing as Error",
      description = "Uses an error square to spot them easily, requires 'Show Trailing' enabled.",
      path = "show_trailing_error",
      type = "toggle",
      default = false,
      on_apply = function(enabled)
        local found = nil
        local substitutions = config.plugins.drawwhitespace.substitutions
        for i, sub in ipairs(substitutions) do
          if sub.trailing_error then
            found = i
          end
        end
        if found == nil and enabled then
          table.insert(substitutions, {
            char = " ",
            sub = "█",
            show_leading = false,
            show_middle = false,
            show_trailing = true,
            trailing_color = style.error,
            trailing_error = true
          })
        elseif found ~= nil and not enabled then
          table.remove(substitutions, found)
        end
      end
    }
  }
}, config.plugins.drawwhitespace)


local function get_option(substitution, option)
  if substitution[option] == nil then
    return config.plugins.drawwhitespace[option]
  end
  return substitution[option]
end

local update = DocView.update
function DocView:update()
  update(self)
  if
    config.plugins.drawwhitespace.enabled
    and
    config.plugins.drawwhitespace.show_selected_only
  then
    local selections = {}
    local col1, col2
    local vl1, vl2 = self:get_visible_line_range()
    for _, l1, c1, l2, c2 in self.doc:get_selections(true) do
      -- everything selected treat as not show_selected_only
      if l1 < vl1 and l2 > vl2 then
        selections.all = true
        goto out_of_loop
      end
      -- nothing selected so skip
      if l1 == l2 and c1 == c2 then goto skip end
      -- handle single line selection
      if l1 == l2 and l1 >= vl1 and l1 <= vl2 then
        col1, col2 = self:get_visible_cols_range(l1, 20)
        c1, c2 = math.max(col1, c1), math.min(col2, c2)
        selections[l1] = {c1, c2, self.doc.lines[l1]:sub(c1, c2)}
      -- multiple lines selection
      elseif l1 ~= l2 then
        -- first line
        if l1 >= vl1 and l1 <= vl2 then
          col1, col2 = self:get_visible_cols_range(l1, 20)
          col1 = math.max(c1, col1)
          selections[l1] = {col1, col2, self.doc.lines[l1]:sub(col1, col2)}
        end
        -- lines in between
        if l2 - l1 > 1 then
          for idx=l1+1, l2-1 do
            col1, col2 = self:get_visible_cols_range(idx, 20)
            selections[idx] = {col1, col2, self.doc.lines[idx]:sub(col1, col2)}
          end
        end
        -- last line
        if l2 >= vl1 and l2 <= vl2 then
          col1, col2 = self:get_visible_cols_range(l2, 20)
          col2 = math.min(c2, col2)
          selections[l2] = {col1, col2, self.doc.lines[l2]:sub(col1, col2)}
        end
      end
      ::skip::
    end
    ::out_of_loop::
    self.drawwhitespace_selections = selections
  elseif self.drawwhitespace_selections then
    self.drawwhitespace_selections = nil
  end
end

local draw_line_text = DocView.draw_line_text
function DocView:draw_line_text(idx, x, y)
  if
    not config.plugins.drawwhitespace.enabled
    or
    getmetatable(self) ~= DocView
  then
    return draw_line_text(self, idx, x, y)
  end

  local font = (self:get_font() or style.syntax_fonts["whitespace"] or style.syntax_fonts["comment"])
  local ty = y + self:get_line_text_y_offset()
  local tx
  local col1, col2
  local text, offset
  local s, e
  local line_len = #self.doc.lines[idx]
  local l1, c1, l2, c2
  if
    not config.plugins.drawwhitespace.show_selected_only
    or
    self.drawwhitespace_selections.all
  then
    col1, col2 = self:get_visible_cols_range(idx, 20)
    if col1 == 0 or col2 == 1 then goto not_selected end -- skip empty line
    text = self.doc.lines[idx]:sub(col1, col2)
  else
    if not self.drawwhitespace_selections[idx] then goto not_selected end
    col1, col2, text = table.unpack(self.drawwhitespace_selections[idx])
  end

  for _, substitution in pairs(config.plugins.drawwhitespace.substitutions) do
    local char = substitution.char
    local sub = substitution.sub
    offset = 1

    local show_leading = get_option(substitution, "show_leading")
    local show_middle = get_option(substitution, "show_middle")
    local show_trailing = get_option(substitution, "show_trailing")

    local show_middle_min = get_option(substitution, "show_middle_min")

    local base_color = get_option(substitution, "color")
    local leading_color = get_option(substitution, "leading_color") or base_color
    local middle_color = get_option(substitution, "middle_color") or base_color
    local trailing_color = get_option(substitution, "trailing_color") or base_color

    local pattern = char.."+"
    while true do
      s, e = text:find(pattern, offset)
      if not s then break end

      local as, ae = col1 + s - 1, col1 + e

      tx = self:get_col_x_offset(idx, as) + x

      local color = base_color
      local draw = false

      if ae >= line_len then
        draw = show_trailing
        color = trailing_color
      elseif as == 1 then
        draw = show_leading
        color = leading_color
      else
        draw = show_middle and (ae - as >= show_middle_min)
        color = middle_color
      end

      if draw then
        -- We need to draw tabs one at a time because they might have a
        -- different size than the substituting character.
        -- This also applies to any other char if we use non-monospace fonts
        -- but we ignore this case for now.
        if char == "\t" then
          for i = as,ae-1 do
            tx = self:get_col_x_offset(idx, i) + x
            tx = renderer.draw_text(font, sub, tx, ty, color)
          end
        else
          tx = renderer.draw_text(font, string.rep(sub, ae - as), tx, ty, color)
        end

        end

      offset = e + 1
    end
  end

  ::not_selected::
  return draw_line_text(self, idx, x, y)
end


command.add(nil, {
  ["draw-whitespace:toggle"]  = function()
    config.plugins.drawwhitespace.enabled = not config.plugins.drawwhitespace.enabled
  end,

  ["draw-whitespace:disable"] = function()
    config.plugins.drawwhitespace.enabled = false
  end,

  ["draw-whitespace:enable"]  = function()
    config.plugins.drawwhitespace.enabled = true
  end,
})
