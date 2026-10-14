-- mod-version:3
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"


local escapes = {
  ["\\"] = "\\\\",
  ["\""] = "\\\"",
  ["'"] = "\\'",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
  ["\b"] = "\\b",
}

local function replace(chr)
  return escapes[chr] or string.format("\\x%02x", chr:byte())
end


---Quote each selection, or the entire document when no text is selected.
---Escape the chosen delimiter, backslashes and control bytes while preserving other text.
---@param doc core.doc Document to quote
---@param delimiter string Single or double quote used to wrap the text
local function quote(doc, delimiter)
  -- LuaJIT patterns require %z for NUL; keep the other control bytes in a range.
  local pattern = "[%z\1-\31\\" .. delimiter .. "]"
  doc:replace(function(text)
    return delimiter .. text:gsub(pattern, replace) .. delimiter
  end)
end


command.add("core.docview", {
  ["quote:quote"] = function(dv)
    quote(dv.doc, '"')
  end,

  ["quote:quote-single"] = function(dv)
    quote(dv.doc, "'")
  end,
})

-- Remove the former default when this plugin is reloaded.
keymap.unbind(PLATFORM == "Mac OS X" and "cmd+'" or "ctrl+'", "quote:quote")
keymap.add {
  ["ctrl+'"] = "quote:quote-single",
  ["ctrl+shift+'"] = "quote:quote",
}

-- Expose both quoting styles with their document predicates and current bindings.
core.menu_view:register({ "edit" }, {
  core.menu_view.DIVIDER,
  {
    id = "quote-single",
    text = "Quote with Single Quotes",
    command = "quote:quote-single"
  },
  {
    id = "quote-double",
    text = "Quote with Double Quotes",
    command = "quote:quote"
  }
}, "quote")
