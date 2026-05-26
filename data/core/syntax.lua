local common = require "core.common"
local core   = require "core"

---Functions to add and get syntax definitions.
---@class core.syntax
local syntax = {}

---@alias core.syntax.matcher string|string[]
---@alias core.syntax.token_type string|string[]

---A single tokenization rule in a syntax definition.
---
---Exactly one of `pattern` or `regex` should be set. A string matcher is used
---for a single token; a table matcher is used as `{ opener, closer, escape? }`
---for a multi-token region that may optionally enter a nested syntax.
---@class core.syntax.pattern
---@field pattern? core.syntax.matcher Lua pattern matcher.
---@field regex? core.syntax.matcher Regex matcher.
---@field type? core.syntax.token_type Token type, or capture token types.
---@field syntax? core.syntax.syntax|string Nested syntax table or syntax lookup key.
---@field disabled? boolean True when the rule should be ignored by tokenizers.

---A language syntax definition used by syntax plugins and tokenizers.
---@class core.syntax.syntax
---@field name? string Display name of the syntax.
---@field files? string|string[] Lua patterns matched against file paths.
---@field headers? string|string[] Lua patterns matched against file headers.
---@field comment? string Single-line comment marker.
---@field block_comment? string[] Pair of block comment delimiters.
---@field symbol_pattern? string Lua pattern used for document symbols.
---@field space_handling? boolean Whether `syntax.add` should append whitespace optimization rules.
---@field patterns core.syntax.pattern[] Tokenization rules.
---@field symbols table<string,string> Token type overrides for exact symbol text.

---@type core.syntax.syntax[]
syntax.items = {}

---@type core.syntax.syntax
syntax.plain_text_syntax = { name = "Plain Text", patterns = {}, symbols = {} }


---Checks whether the pattern / regex compiles correctly and matches something.
---A pattern / regex must not match an empty string.
---@param pattern_type "regex"|"pattern"
---@param pattern string
---@return boolean ok
---@return string? error
local function check_pattern(pattern_type, pattern)
  local ok, err, mstart, mend
  if pattern_type == "regex" then
    ok, err = regex.compile(pattern)
    if ok then
      mstart, mend = regex.find_offsets(ok, "")
      if mstart and mstart > mend then
        ok, err = false, "Regex matches an empty string"
      end
    end
  else
    ok, mstart, mend = pcall(string.ufind, "", pattern)
    if ok and mstart and mstart > mend then
      ok, err = false, "Pattern matches an empty string"
    elseif not ok then
      err = mstart --[[@as string]]
    end
  end
  return ok --[[@as boolean]], err
end

---Register a syntax definition.
---
---The syntax is appended to the syntax registry and later entries take
---precedence when file or header patterns have the same match length. Syntax
---patterns are validated before registration; malformed token patterns are
---disabled and reported with `core.warn`.
---
---@param t core.syntax.syntax Syntax definition to register.
function syntax.add(t)
  if type(t.space_handling) ~= "boolean" then t.space_handling = true end

  if t.patterns then
    -- do a sanity check on the patterns / regex to make sure they are actually correct
    for i, pattern in ipairs(t.patterns) do
      local p, ok, err, name = pattern.pattern or pattern.regex, nil, nil, nil
      if type(p) == "table" then
        for j = 1, 2 do
          ok, err = check_pattern(pattern.pattern and "pattern" or "regex", p[j])
          if not ok then name = string.format("#%d:%d <%s>", i, j, p[j]) end
        end
      elseif type(p) == "string" then
        ok, err = check_pattern(pattern.pattern and "pattern" or "regex", p)
        if not ok then name = string.format("#%d <%s>", i, p) end
      else
        ok, err, name = false, "Missing pattern or regex", "#"..i
      end
      if not ok then
        pattern.disabled = true
        core.warn("Malformed pattern %s in %s language plugin: %s", name, t.name, err)
      end
    end

    -- the rule %s+ gives us a performance gain for the tokenizer in lines with
    -- long amounts of consecutive spaces, can be disabled by plugins where it
    -- causes conflicts by declaring the table property: space_handling = false
    if t.space_handling then
      table.insert(t.patterns, { pattern = "%s+", type = "normal" })
    end

    -- this rule gives us additional performance gain by matching every word
    -- that was not matched by the syntax patterns as a single token, preventing
    -- the tokenizer from iterating over each character individually which is a
    -- lot slower since iteration occurs in lua instead of C and adding to that
    -- it will also try to match every pattern to a single char (same as spaces)
    table.insert(t.patterns, { pattern = "%w+%f[%s]", type = "normal" })
  end

  table.insert(syntax.items, t)
end


local function find(string, field)
  local best_match = 0
  local best_syntax
  for i = #syntax.items, 1, -1 do
    local t = syntax.items[i]
    local s, e = common.match_pattern(string, t[field] or {})
    if s and e - s > best_match then
      best_match = e - s
      best_syntax = t
    end
  end
  return best_syntax
end

---Return the best syntax for a file path or header.
---
---File path patterns are checked first, followed by header patterns. When no
---registered syntax matches, this returns `syntax.plain_text_syntax`.
---
---@param filename? string File path or name used for `files` pattern matching.
---@param header? string Initial file contents used for `headers` pattern matching.
---@return core.syntax.syntax syntax Best matching syntax, or plain text.
function syntax.get(filename, header)
  return (filename and find(filename, "files"))
      or (header and find(header, "headers"))
      or syntax.plain_text_syntax
end


return syntax
