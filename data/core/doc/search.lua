---Provides the base in-place search functionality for documents.
---@class core.doc.search
local search = {}

---Options used when performing a search.
---@class core.doc.searchoptions
---If the end of document is reached start again from the start.
---@field wrap? boolean
---Perform case insensitive matches (ignored with lua patterns).
---@field no_case? boolean
---Only match whole words.
---@field whole_word? boolean
---The text to find is a Lua pattern.
---@field pattern? boolean
---The text to find is a Regular expression.
---@field regex? boolean
---Execute the search backward instead of forward.
---@field reverse? boolean

---@type core.doc.searchoptions
local default_opt = {}

---Helper to initialize search.find() parameters to sane defaults.
---@param doc core.doc
---@param line integer
---@param col integer
---@param text string
---@param opt core.doc.searchoptions
---@return core.doc doc
---@return integer line
---@return integer col
---@return string text
---@return core.doc.searchoptions opt
local function init_args(doc, line, col, text, opt)
  opt = opt or default_opt
  line, col = doc:sanitize_position(line, col)

  if opt.no_case and not opt.pattern and not opt.regex then
    text = text:lower()
  end

  return doc, line, col, text, opt
end

---This function is needed to uniform the behavior of
---`regex:cmatch` and `string.find`.
---@param text string
---@param re regex
---@param index integer
---@return integer? s
---@return integer? e
local function regex_func(text, re, index, _)
  local s, e = re:find(text, index)
  return s, e
end

---Perform a reverse/backward search.
---@param func fun(s:string, pattern:string|regex, init:integer, plain:boolean)
---@param text string
---@param pattern string|regex
---@param index integer
---@param plain boolean
local function rfind(func, text, pattern, index, plain)
  if index < 0 then index = #text + index + 1 end
  local s, e = func(text, pattern, 1, plain)
  -- handles lua pattern full line matches
  if e and e == #text and s == 1 and e - 1 <= index then
    return s, e - 1
  end
  local last_s, last_e
  while e and e <= index and e >= s do
    last_s, last_e = s, e
    s, e = func(text, pattern, e + 1, plain)
  end
  return last_s, last_e
end

---Perform a search on a document with the given options.
---@param doc core.doc
---@param line integer
---@param col integer
---@param text string
---@param opt core.doc.searchoptions
function search.find(doc, line, col, text, opt)
  doc, line, col, text, opt = init_args(doc, line, col, text, opt)
  local plain = not opt.pattern
  local pattern = text
  local search_func = string.find
  if opt.regex then
    pattern = regex.compile(text, opt.no_case and "i" or "")
    search_func = regex_func
  end
  local start, finish, step = line, #doc.lines, 1
  if opt.reverse then
    start, finish, step = line, 1, -1
  end
  for line = start, finish, step do
    local line_text = doc.lines[line]
    local line_len = #line_text
    if opt.no_case and not opt.regex and not opt.pattern then
      line_text = line_text:lower()
    end
    local s, e = col, col
    local matches
    repeat
      matches = true
      if opt.reverse then
        s, e = rfind(search_func, line_text, pattern, e - 1, plain)
      else
        s, e = search_func(line_text, pattern, e, plain)
      end
      if opt.whole_word and s and e then
        if
          (s ~= 1 and line_text:sub(s - 1, s - 1):match("[%w_]"))
          or
          (e ~= line_len and line_text:sub(e + 1, e + 1):match("[%w_]"))
        then
          matches = false
          if opt.reverse then e = e - 1 else e = e + 1 end
          if e == line_len then s = nil e = nil break end
        end
      end
    until matches == true or not e or e < s or e >= line_len
    if s then
      if e >= s and (e ~= line_len or s ~= e) then
        return line, s, line, e == line_len and e or e + 1
      end
    end
    col = opt.reverse and -1 or 1
  end

  if opt.wrap then
    opt.wrap = false -- wrap a single time, otherwise this would never end :P
    if opt.reverse then
      return search.find(doc, #doc.lines, #doc.lines[#doc.lines], text, opt)
    else
      return search.find(doc, 1, 1, text, opt)
    end
  end
end


return search
