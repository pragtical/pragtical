-- mod-version:3
local core = require "core"
local command = require "core.command"
local translate = require "core.doc.translate"


local function gmatch_to_array(text, ptn)
  local res = {}
  for x in text:gmatch(ptn) do
    table.insert(res, x)
  end
  return res
end


---Split a line on a literal separator, retaining empty non-whitespace fields.
---@param line string Line contents without the newline
---@param separator string Single-byte column separator
---@return string[] columns Fields in their original order
local function split_columns(line, separator)
  local columns = {}
  local keep_empty = not separator:match("%s")
  local start = 1
  repeat
    local stop = line:find(separator, start, true)
    local column = line:sub(start, stop and stop - 1 or #line)
    if column ~= "" or keep_empty then
      columns[#columns + 1] = column
    end
    start = stop and stop + 1
  until not start
  return columns
end


---Align delimited lines while preserving their newlines and empty columns.
---@param lines string[] Lines to update in place, including any newline suffix
---@param delim string First byte separates columns; the full string rejoins them
local function tabularize_lines(lines, delim)
  local rows = {}
  local cols = {}
  local endings = {}
  local separator = delim:sub(1, 1)

  -- split lines at delimiters and get maximum width of columns
  for i, line in ipairs(lines) do
    local body, ending = line:match("^(.-)(\n?)$")
    if body:find(separator, 1, true) then
      rows[i] = split_columns(body, separator)
      endings[i] = ending
      for j, col in ipairs(rows[i]) do
        cols[j] = math.max(#col, cols[j] or 0)
      end
    end
  end

  -- pad columns and reattach line endings; leave non-delimited lines unchanged
  for i in ipairs(lines) do
    local row = rows[i]
    if row then
      for j = 1, #row - 1 do
        row[j] = row[j] .. string.rep(" ", cols[j] - #row[j])
      end
      lines[i] = table.concat(row, delim) .. endings[i]
    end
  end
end


command.add("core.docview", {
  ["tabularize:tabularize"] = function(dv)
    core.command_view:enter("Tabularize On Delimiter", {
      submit = function(delim)
        if delim == "" then delim = " " end

        local doc = dv.doc
        local line1, col1, line2, col2, swap = doc:get_selection(true)
        line1, col1 = doc:position_offset(line1, col1, translate.start_of_line)
        line2, col2 = doc:position_offset(line2, col2, translate.end_of_line)
        doc:set_selection(line1, col1, line2, col2, swap)

        doc:replace(function(text)
          local lines = gmatch_to_array(text, "[^\n]*\n?")
          tabularize_lines(lines, delim)
          return table.concat(lines)
        end)
      end
    })
  end,
})


core.menu_view:register({ "edit" }, {
  core.menu_view.DIVIDER,
  {
    id = "tabularize",
    text = "Tabularize…",
    command = "tabularize:tabularize"
  }
}, "tabularize")
