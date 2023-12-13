local search = {}

local default_opt = {}


local function pattern_lower(str)
  if str:sub(1, 1) == "%" then
    return str
  end
  return str:lower()
end


local function init_args(doc, line, col, text, opt)
  opt = opt or default_opt
  line, col = doc:sanitize_position(line, col)

  if opt.no_case and not opt.regex then
    text = text:lower()
  end

  return doc, line, col, text, opt
end

-- This function is needed to uniform the behavior of
-- `regex:cmatch` and `string.find`.
local function regex_func(text, re, index, _)
  local s, e = re:cmatch(text, index)
  return s, e and e - 1
end

local function rfind(func, text, pattern, index, plain)
  local s, e = func(text, pattern, 1, plain)
  local last_s, last_e
  if index < 0 then index = #text - index + 1 end
  while e and e <= index do
    last_s, last_e = s, e
    s, e = func(text, pattern, s + 1, plain)
  end
  return last_s, last_e
end


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
    if opt.no_case and not opt.regex then
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
          (e ~= #line_text and line_text:sub(e + 1, e + 1):match("[%w_]"))
        then
          matches = false
          if opt.reverse then e = e - 1 else e = e + 1 end
          if e == #line_text then s = nil e = nil break end
        end
      end
    until matches == true or not e or e >= #line_text
    if s then
      local line2 = line
      -- If we've matched the newline too,
      -- return until the initial character of the next line.
      if e >= #doc.lines[line] then
        line2 = line + 1
        e = 0
      end
      -- Avoid returning matches that go beyond the last line.
      -- This is needed to avoid selecting the "last" newline.
      if line2 <= #doc.lines then
        return line, s, line2, e + 1
      end
    end
    col = opt.reverse and -1 or 1
  end

  if opt.wrap then
    opt = { no_case = opt.no_case, regex = opt.regex, reverse = opt.reverse }
    if opt.reverse then
      return search.find(doc, #doc.lines, #doc.lines[#doc.lines], text, opt)
    else
      return search.find(doc, 1, 1, text, opt)
    end
  end
end


return search
