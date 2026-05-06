local core = require "core"
local common = require "core.common"
local config = require "core.config"
local ImageView = require "core.imageview"
local style = require "core.style"
local syntax = require "core.syntax"
local tokenizer = require "core.tokenizer"
local View = require "core.view"
local http

local INLINE_CODE_PADDING_X = common.round(4 * SCALE)
local INLINE_CODE_PADDING_Y = common.round(1 * SCALE)
local BLOCK_PADDING_X = style.padding.x
local BLOCK_PADDING_Y = style.padding.y
local LIST_INDENT = common.round(18 * SCALE)
local QUOTE_BAR_WIDTH = math.max(style.divider_size * 2, common.round(4 * SCALE))
local QUOTE_GAP = style.padding.x
local RULE_HEIGHT = math.max(style.divider_size, 1)
local RULE_GAP = common.round(10 * SCALE)
local BLOCK_SPACING = style.padding.y
local PARAGRAPH_SPACING = BLOCK_SPACING * 2
local CHECKBOX_SIZE_RATIO = 0.75
local IMAGE_ROW_PADDING_Y = style.padding.y
local IMAGE_CACHE_DIR = USERDIR .. PATHSEP .. "cache"
local TABLE_BORDER = math.max(style.divider_size, 1)
local TABLE_CELL_PADDING_X = style.padding.x
local TABLE_CELL_PADDING_Y = math.max(common.round(style.padding.y / 2), 1)
local CODE_FENCE_ALIASES = {
  bash = "sh",
  caddyfile = "caddyfile",
  c = "c",
  ["c#"] = "cs",
  cc = "cpp",
  cmake = "cmake",
  cpp = "cpp",
  ["c++"] = "cpp",
  cxx = "cpp",
  css = "css",
  d = "d",
  dart = "dart",
  go = "go",
  glsl = "glsl",
  h = "cpp",
  hpp = "cpp",
  html = "html",
  ini = "ini",
  java = "java",
  javascript = "js",
  js = "js",
  json = "json",
  julia = "jl",
  liquid = "liquid",
  lua = "lua",
  markdown = "md",
  md = "md",
  mjs = "js",
  moon = "moon",
  nim = "nim",
  nix = "nix",
  perl = "pl",
  php = "php",
  py = "py",
  python = "py",
  rescript = "res",
  ruby = "rb",
  rust = "rs",
  sh = "sh",
  toml = "toml",
  typescript = "ts",
  v = "v",
  xml = "xml",
  yaml = "yaml"
}
local CODE_FENCE_SYNTAX_CACHE = {}
local parse_inline
local parse_inline_lines
local extract_single_image

local function make_style_color(key, fallback)
  return {
    __markdown_style_color = true,
    kind = "style",
    key = key,
    fallback = fallback
  }
end

local function make_syntax_color(key, fallback)
  return {
    __markdown_style_color = true,
    kind = "syntax",
    key = key,
    fallback = fallback
  }
end

local COLOR_TEXT = make_style_color("text")
local COLOR_ACCENT = make_style_color("accent", COLOR_TEXT)
local COLOR_DIM = make_style_color("dim", COLOR_TEXT)
local COLOR_BACKGROUND = make_style_color("background")
local COLOR_BACKGROUND2 = make_style_color("background2", COLOR_BACKGROUND)
local COLOR_DIVIDER = make_style_color("divider")
local COLOR_LINK = make_syntax_color("function", COLOR_ACCENT)

local function resolve_color(color)
  if not color or not color.__markdown_style_color then
    return color
  end

  local resolved
  if color.kind == "style" then
    resolved = style[color.key]
  else
    resolved = style.syntax and style.syntax[color.key]
  end

  if resolved then
    return resolved
  end

  return resolve_color(color.fallback)
end

---@class core.markdownview.state
---@field path string
---@field scroll { x:number, y:number }

---@class core.markdownview.source
---@field doc core.doc?
---@field path string?
---@field text string?
---@field title string?
---@field name string?

---@class core.markdownview : core.view
---@overload fun(source?: string|table, title?: string):core.markdownview
---@field super core.view
---@field doc core.doc?
---@field image_cache table<string,table>
---@field path string?
---@field title string?
---@field text string
---@field blocks table[]
---@field references table<string,string>
---@field footnotes table
---@field layout table?
---@field font_cache table?
---@field last_doc_change_id integer?
---@field hovered_link_url string?
local MarkdownView = View:extend()

function MarkdownView:__tostring() return "MarkdownView" end

MarkdownView.resolve_color = resolve_color

MarkdownView.context = "session"

local function trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function ltrim(text)
  return (text:gsub("^%s+", ""))
end

local function rtrim(text)
  return (text:gsub("%s+$", ""))
end

local function split_lines(text)
  local lines = {}
  text = (text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  for line in (text .. "\n"):gmatch("(.-)\n") do
    table.insert(lines, line)
  end
  if #lines == 0 then
    lines[1] = ""
  end
  return lines
end

local function is_blank(line)
  return line:match("^%s*$") ~= nil
end

local function is_rule(line)
  local compact = line:gsub("%s+", "")
  local char = compact:sub(1, 1)
  if #compact < 3 or not (char == "-" or char == "*" or char == "_") then
    return false
  end
  for i = 2, #compact do
    if compact:sub(i, i) ~= char then
      return false
    end
  end
  return true
end

local function get_heading(line)
  local marks, text = line:match("^%s*(#+)%s+(.-)%s*$")
  if marks and #marks <= 6 then
    return #marks, trim(text)
  end
end

local function get_setext_heading_level(line)
  local compact = trim(line):gsub("%s+", "")
  local char = compact:sub(1, 1)
  if #compact < 3 or not (char == "=" or char == "-") then
    return nil
  end
  for i = 2, #compact do
    if compact:sub(i, i) ~= char then
      return nil
    end
  end
  return char == "=" and 1 or 2
end

local function get_fence(line)
  local marks, info = line:match("^%s*([`~][`~][`~]+)%s*(.-)%s*$")
  if marks then
    return marks:sub(1, 1), #marks, trim(info)
  end
end

local function get_indentation_width(line)
  local indent = line:match("^(%s*)") or ""
  local width = 0
  for i = 1, #indent do
    local char = indent:sub(i, i)
    if char == "\t" then
      width = width + config.indent_size
    else
      width = width + 1
    end
  end
  return width
end

local function get_visual_width(text)
  local width = 0
  for i = 1, #text do
    local char = text:sub(i, i)
    if char == "\t" then
      width = width + (config.indent_size - (width % config.indent_size))
    else
      width = width + 1
    end
  end
  return width
end

local function strip_indentation(line, width)
  local i = 1
  local consumed = 0
  while i <= #line and consumed < width do
    local char = line:sub(i, i)
    if char == " " then
      consumed = consumed + 1
      i = i + 1
    elseif char == "\t" then
      local tab_width = config.indent_size - (consumed % config.indent_size)
      if consumed + tab_width > width then
        break
      end
      consumed = consumed + tab_width
      i = i + 1
    else
      break
    end
  end
  return line:sub(i)
end

local function strip_blockquote_prefix(line)
  local stripped = line:gsub("^%s*>%s?", "", 1)
  return stripped == line and nil or stripped
end

local function is_indented_code_line(line)
  return not is_blank(line) and get_indentation_width(line) >= 4
end

local function get_definition_item(line)
  local prefix, text = line:match("^(%s*:%s+)(.-)%s*$")
  if prefix and text ~= "" then
    return trim(text), get_indentation_width(prefix)
  end
end

local function get_footnote_definition(line)
  local prefix, id, text = line:match("^(%s*%[%^([^%]]+)%]:%s+)(.-)%s*$")
  if prefix then
    return trim(id), text, get_indentation_width(prefix)
  end
end

local function get_list_item(line)
  local indent = get_indentation_width(line)
  local prefix, checked, text = line:match("^(%s*[-+*]%s+)%[([ xX])%]%s+(.-)%s*$")
  if prefix and text then
    return {
      type = "unordered_list",
      text = trim(text),
      checked = checked ~= " ",
      raw_indent = indent,
      content_indent = get_visual_width(prefix .. "[ ] ")
    }
  end

  prefix, text = line:match("^(%s*[-+*]%s+)(.-)%s*$")
  if prefix and text then
    return {
      type = "unordered_list",
      text = trim(text),
      raw_indent = indent,
      content_indent = get_visual_width(prefix)
    }
  end

  prefix, text = line:match("^(%s*%d+[.)]%s+)(.-)%s*$")
  local index = line:match("^%s*(%d+)[.)]%s+")
  if prefix and text and index then
    return {
      type = "ordered_list",
      index = tonumber(index),
      text = trim(text),
      raw_indent = indent,
      content_indent = get_visual_width(prefix)
    }
  end
end

local function get_unordered_item(line)
  local item = get_list_item(line)
  if item and item.type == "unordered_list" then
    return item.text, item.checked, item.raw_indent
  end
end

local function get_ordered_item(line)
  local item = get_list_item(line)
  if item and item.type == "ordered_list" then
    return item.index, item.text, item.raw_indent
  end
end

local function is_blockquote(line)
  return line:match("^%s*>") ~= nil
end

local function is_html_comment_start(line)
  return trim(line):match("^<!%-%-") ~= nil
end

local function is_html_comment_end(line)
  return line:find("-->", 1, true) ~= nil
end

local function is_block_start(line)
  return get_fence(line)
    or get_heading(line)
    or is_rule(line)
    or get_list_item(line)
    or is_blockquote(line)
    or get_definition_item(line)
    or get_footnote_definition(line)
    or is_html_comment_start(line)
end

local function append_wrapped_line(target, text)
  if text ~= "" then
    target[#target + 1] = trim(text)
  end
end

local function normalize_link_label(label)
  return trim(label or ""):lower():gsub("%s+", " ")
end

local function normalize_link_url(url)
  url = trim(url or "")
  return url:match("^<(.+)>$") or url
end

local function find_matching(text, start_index, open_char, close_char)
  local depth = 0
  local i = start_index
  while i <= #text do
    local char = text:sub(i, i)
    if char == "\\" and i < #text then
      i = i + 2
    else
      if char == open_char then
        depth = depth + 1
      elseif char == close_char then
        depth = depth - 1
        if depth == 0 then
          return i
        end
      end
      i = i + 1
    end
  end
end

local function skip_spaces(text, index)
  while index <= #text and text:sub(index, index):match("%s") do
    index = index + 1
  end
  return index
end

local function parse_quoted_title(text, index)
  local opener = text:sub(index, index)
  local closer = opener == "(" and ")" or opener
  if opener == "" or (opener ~= '"' and opener ~= "'" and opener ~= "(") then
    return nil
  end

  local i = index + 1
  local start = i
  while i <= #text do
    local char = text:sub(i, i)
    if char == "\\" and i < #text then
      i = i + 2
    elseif char == closer then
      return text:sub(start, i - 1), i + 1
    else
      i = i + 1
    end
  end
end

local function parse_link_destination(text, index)
  index = skip_spaces(text, index)
  if index > #text then
    return nil
  end

  if text:sub(index, index) == "<" then
    local close = text:find(">", index + 1, true)
    if not close then
      return nil
    end
    return normalize_link_url(text:sub(index + 1, close - 1)), close + 1
  end

  local start = index
  local depth = 0
  while index <= #text do
    local char = text:sub(index, index)
    if char == "\\" and index < #text then
      index = index + 2
    elseif char == "(" then
      depth = depth + 1
      index = index + 1
    elseif char == ")" then
      if depth == 0 then
        break
      end
      depth = depth - 1
      index = index + 1
    elseif char:match("%s") and depth == 0 then
      break
    else
      index = index + 1
    end
  end

  if index == start then
    return nil
  end

  return normalize_link_url(text:sub(start, index - 1)), index
end

local function parse_parenthesized_target(text, open_index)
  local url, index = parse_link_destination(text, open_index + 1)
  if not url then
    return nil
  end

  index = skip_spaces(text, index)
  local title
  if index <= #text then
    local char = text:sub(index, index)
    if char == '"' or char == "'" or char == "(" then
      title, index = parse_quoted_title(text, index)
      if not title then
        return nil
      end
      index = skip_spaces(text, index)
    end
  end

  if text:sub(index, index) ~= ")" then
    return nil
  end

  return url, title, index
end

local function parse_reference_target(text)
  local url, index = parse_link_destination(text, 1)
  if not url then
    return nil
  end

  index = skip_spaces(text, index)
  local title
  if index <= #text then
    title, index = parse_quoted_title(text, index)
    if not title then
      return nil
    end
    index = skip_spaces(text, index)
  end

  if index <= #text then
    return nil
  end
  return url, title
end

local function parse_image_reference(text, references)
  if text:sub(1, 2) ~= "![" then
    return nil
  end

  local close = find_matching(text, 2, "[", "]")
  if not close then
    return nil
  end

  local alt = text:sub(3, close - 1)
  local next_char = text:sub(close + 1, close + 1)
  if next_char == "(" then
    local parsed_url, _, finish = parse_parenthesized_target(text, close + 1)
    if parsed_url and finish == #text then
      return alt, parsed_url
    end
  elseif next_char == "[" then
    local ref_close = find_matching(text, close + 1, "[", "]")
    if ref_close == #text then
      local ref = text:sub(close + 2, ref_close - 1)
      local url = references[normalize_link_label(ref ~= "" and ref or alt)]
      if url then
        return alt, url
      end
    end
  elseif close == #text then
    local url = references[normalize_link_label(alt)]
    if url then
      return alt, url
    end
  end
end

local function parse_link_reference(text, references)
  if text:sub(1, 1) ~= "[" then
    return nil
  end

  local close = find_matching(text, 1, "[", "]")
  if not close then
    return nil
  end

  local label = text:sub(2, close - 1)
  local next_char = text:sub(close + 1, close + 1)
  if next_char == "(" then
    local url, _, finish = parse_parenthesized_target(text, close + 1)
    if url and finish == #text then
      return label, url
    end
  elseif next_char == "[" then
    local ref_close = find_matching(text, close + 1, "[", "]")
    if ref_close == #text then
      local ref = text:sub(close + 2, ref_close - 1)
      local url = references[normalize_link_label(ref ~= "" and ref or label)]
      if url then
        return label, url
      end
    end
  elseif close == #text then
    local url = references[normalize_link_label(label)]
    if url then
      return label, url
    end
  end
end

local function parse_linked_image_reference(text, references)
  local inner, link_url = parse_link_reference(text, references)
  if not inner or not link_url then
    return
  end

  local alt, image_url = parse_image_reference(inner, references)
  if alt and image_url then
    return alt, image_url, link_url
  end
end

local function parse_image_row(lines, references)
  if #lines <= 1 then
    return nil
  end

  local images = {}
  for _, line in ipairs(lines) do
    local alt, url, link_url = parse_linked_image_reference(line, references)
    if url then
      images[#images + 1] = {
        alt = alt,
        url = url,
        link_url = link_url,
        alignment = "left"
      }
    else
      alt, url = parse_image_reference(line, references)
      if not url then
        return nil
      end
      images[#images + 1] = {
        alt = alt,
        url = url,
        alignment = "left"
      }
    end
  end

  return images
end

local function split_table_row(line)
  if not line or not line:find("|", 1, true) then
    return nil
  end

  local text = trim(line)
  if text == "" then
    return nil
  end

  if text:sub(1, 1) == "|" then
    text = text:sub(2)
  end
  if text:sub(-1) == "|" then
    text = text:sub(1, -2)
  end

  local cells = {}
  local current = {}
  local i = 1
  while i <= #text do
    local char = text:sub(i, i)
    if char == "\\" and text:sub(i + 1, i + 1) == "|" then
      current[#current + 1] = "|"
      i = i + 2
    elseif char == "|" then
      cells[#cells + 1] = trim(table.concat(current))
      current = {}
      i = i + 1
    else
      current[#current + 1] = char
      i = i + 1
    end
  end

  cells[#cells + 1] = trim(table.concat(current))
  if #cells < 2 then
    return nil
  end
  return cells
end

local function parse_table_alignments(line, columns)
  local cells = split_table_row(line)
  if not cells or #cells ~= columns then
    return nil
  end

  local alignments = {}
  for i, cell in ipairs(cells) do
    local compact = trim(cell):gsub("%s+", "")
    if not compact:match("^:?-+:?$") then
      return nil
    end
    if compact:sub(1, 1) == ":" and compact:sub(-1) == ":" then
      alignments[i] = "center"
    elseif compact:sub(-1) == ":" then
      alignments[i] = "right"
    else
      alignments[i] = "left"
    end
  end

  return alignments
end

local function parse_table_block(lines, index)
  local headers = split_table_row(lines[index])
  if not headers then
    return nil
  end

  local alignments = parse_table_alignments(lines[index + 1], #headers)
  if not alignments then
    return nil
  end

  local rows = {}
  local i = index + 2
  while i <= #lines do
    if is_blank(lines[i]) then
      break
    end
    local cells = split_table_row(lines[i])
    if not cells or #cells ~= #headers then
      break
    end
    rows[#rows + 1] = cells
    i = i + 1
  end

  return {
    type = "table",
    headers = headers,
    alignments = alignments,
    rows = rows
  }, i
end

local function parse_cell_content(text, references, footnotes)
  local segments = parse_inline_lines({ text }, references, footnotes)
  local image = extract_single_image(segments)
  if image then
    return {
      type = "image",
      text = text,
      alt = image.alt,
      url = image.url,
      link_url = image.link_url
    }
  end

  return {
    type = "text",
    text = text,
    segments = segments
  }
end

local function normalize_list_nesting(items)
  local stack = {}

  for _, item in ipairs(items) do
    local indent = item.raw_indent or 0
    while #stack > 0 and indent < stack[#stack] do
      table.remove(stack)
    end
    if #stack == 0 or indent > stack[#stack] then
      stack[#stack + 1] = indent
    end
    item.nesting = #stack - 1
  end
end

local function hash_text(text)
  local hash = 2166136261
  for i = 1, #text do
    hash = (hash * 16777619 + text:byte(i)) % 4294967296
  end
  return string.format("%08x", hash)
end

local function get_image_cache_path(url)
  local normalized = url:match("^[^?#]+") or url
  local ext = normalized:match("%.([%w]+)$")
  if ext then
    ext = ext:lower()
  else
    ext = "img"
  end
  return IMAGE_CACHE_DIR .. PATHSEP .. "markdown-image-" .. hash_text(url) .. "." .. ext
end

local function get_reference_definition(line)
  local label, target = line:match("^%s*%[([^%]]+)%]:%s*(.-)%s*$")
  if label and target then
    local url = parse_reference_target(target)
    if url then
      return normalize_link_label(label), url
    end
  end
end

local function normalize_syntax_name(name)
  return name:lower():gsub("[%W_]+", "")
end

local function get_code_fence_language(info)
  local language = trim(info or ""):match("^[^%s]+")
  if not language or language == "" then
    return nil
  end
  language = language:lower()
    :gsub("^language%-", "")
    :gsub("^lang%-", "")
  return CODE_FENCE_ALIASES[language] or language
end

local function resolve_code_fence_syntax(info)
  local language = get_code_fence_language(info)
  if not language then
    return syntax.plain_text_syntax
  end

  local cached = CODE_FENCE_SYNTAX_CACHE[language]
  if cached then
    return cached
  end

  local resolved = syntax.get("codeblock." .. language)
  if resolved == syntax.plain_text_syntax then
    local normalized = normalize_syntax_name(language)
    for _, item in ipairs(syntax.items) do
      if normalize_syntax_name(item.name or "") == normalized then
        resolved = item
        break
      end
    end
  end

  CODE_FENCE_SYNTAX_CACHE[language] = resolved
  return resolved
end

local function find_next_inline_marker(text, start_index)
  for i = start_index, #text do
    local char = text:sub(i, i)
    if char == "\0" or char == "\\" or char == "!" or char == "*" or char == "_" or char == "~" or char == "`" or char == "[" or char == "<" then
      return i
    end
  end
end

local function find_next_plain_url(text, start_index)
  local http_start = text:find("http://", start_index, true)
  local https_start = text:find("https://", start_index, true)
  if http_start and https_start then
    return math.min(http_start, https_start)
  end
  return http_start or https_start
end

local function trim_plain_url(url)
  while url:match("[.,!?:;]$") do
    url = url:sub(1, -2)
  end
  return url
end

local function style_kind(opts)
  if opts.bold and opts.italic then
    return "bold_italic"
  elseif opts.bold then
    return "bold"
  elseif opts.italic then
    return "italic"
  end
  return "text"
end

local function is_word_char(char)
  return char ~= "" and char:match("[%w]") ~= nil
end

local function is_intraword_underscore(text, index)
  if text:sub(index, index) ~= "_" then
    return false
  end
  return is_word_char(text:sub(index - 1, index - 1))
    and is_word_char(text:sub(index + 1, index + 1))
end

local function copy_style(opts, updates)
  local res = {
    bold = opts.bold,
    italic = opts.italic,
    strikethrough = opts.strikethrough
  }
  if updates then
    for k, v in pairs(updates) do
      res[k] = v
    end
  end
  return res
end

local function append_segments(segments, incoming)
  for _, segment in ipairs(incoming) do
    local last = segments[#segments]
    if last
      and not last.image_url
      and not segment.image_url
      and last.kind ~= "linebreak"
      and segment.kind ~= "linebreak"
      and last.kind == segment.kind
      and last.url == segment.url
      and last.strikethrough == segment.strikethrough
    then
      last.text = last.text .. segment.text
    else
      segments[#segments + 1] = segment
    end
  end
end

local function register_footnote_reference(footnotes, id)
  if not (footnotes and footnotes.definitions[id]) then
    return nil
  end
  if not footnotes.numbers[id] then
    footnotes.order[#footnotes.order + 1] = id
    footnotes.numbers[id] = #footnotes.order
  end
  return footnotes.numbers[id]
end

parse_inline = function(text, references, opts, footnotes)
  local segments = {}
  opts = opts or {}

  local function push_segment(kind, value, url, extra)
    if value == "" and kind ~= "linebreak" and not (extra and extra.image_url) then
      return
    end
    local segment = {
      kind = kind,
      text = value,
      url = url,
      strikethrough = opts.strikethrough
    }
    if extra then
      for k, v in pairs(extra) do
        segment[k] = v
      end
    end
    append_segments(segments, { segment })
  end

  local i = 1
  while i <= #text do
    local triple = text:sub(i, i + 2)
    local double = text:sub(i, i + 1)
    local char = text:sub(i, i)

    if char == "\0" then
      push_segment("linebreak", "")
      i = i + 1
    elseif char == "\\" then
      if i < #text then
        push_segment(style_kind(opts), text:sub(i + 1, i + 1))
        i = i + 2
      else
        push_segment(style_kind(opts), char)
        i = i + 1
      end
    elseif double == "~~" then
      local j = text:find("~~", i + 2, true)
      if j and j > i + 2 then
        append_segments(
          segments,
          parse_inline(
            text:sub(i + 2, j - 1),
            references,
            copy_style(opts, { strikethrough = true }),
            footnotes
          )
        )
        i = j + 2
      else
        push_segment(style_kind(opts), char)
        i = i + 1
      end
    elseif char == "!" and text:sub(i + 1, i + 1) == "[" then
      local close = find_matching(text, i + 1, "[", "]")
      if close then
        local alt = text:sub(i + 2, close - 1)
        local next_char = text:sub(close + 1, close + 1)
        local url
        local title
        local finish
        if next_char == "(" then
          url, title, finish = parse_parenthesized_target(text, close + 1)
        elseif next_char == "[" then
          local ref_close = find_matching(text, close + 1, "[", "]")
          if ref_close then
            local ref = text:sub(close + 2, ref_close - 1)
            url = references[normalize_link_label(ref ~= "" and ref or alt)]
            finish = ref_close
          end
        else
          url = references[normalize_link_label(alt)]
          finish = close
        end
        if url and finish then
          push_segment("image", alt, nil, {
            alt = alt,
            image_url = url
          })
          i = finish + 1
        else
          push_segment(style_kind(opts), char)
          i = i + 1
        end
      else
        push_segment(style_kind(opts), char)
        i = i + 1
      end
    elseif char == "!" then
      push_segment(style_kind(opts), char)
      i = i + 1
    elseif is_intraword_underscore(text, i) then
      push_segment(style_kind(opts), char)
      i = i + 1
    elseif char == "~" then
      push_segment(style_kind(opts), char)
      i = i + 1
    elseif triple == "***" or triple == "___" then
      local j = text:find(triple, i + 3, true)
      if j and j > i + 3 then
        append_segments(
          segments,
          parse_inline(
            text:sub(i + 3, j - 1),
            references,
            copy_style(opts, { bold = true, italic = true }),
            footnotes
          )
        )
        i = j + 3
      else
        push_segment(style_kind(opts), char)
        i = i + 1
      end
    elseif double == "**" or double == "__" then
      local j = text:find(double, i + 2, true)
      if j and j > i + 2 then
        append_segments(
          segments,
          parse_inline(
            text:sub(i + 2, j - 1),
            references,
            copy_style(opts, { bold = true }),
            footnotes
          )
        )
        i = j + 2
      else
        push_segment(style_kind(opts), char)
        i = i + 1
      end
    elseif char == "*" or char == "_" then
      local j = text:find(char, i + 1, true)
      if j and j > i + 1 then
        append_segments(
          segments,
          parse_inline(
            text:sub(i + 1, j - 1),
            references,
            copy_style(opts, { italic = true }),
            footnotes
          )
        )
        i = j + 1
      else
        push_segment(style_kind(opts), char)
        i = i + 1
      end
    elseif char == "`" then
      local tick_count = 1
      while text:sub(i + tick_count, i + tick_count) == "`" do
        tick_count = tick_count + 1
      end
      local fence = string.rep("`", tick_count)
      local j = text:find(fence, i + tick_count, true)
      if j and j > i + tick_count - 1 then
        local code = text:sub(i + tick_count, j - 1)
        if code:match("^ .- $") and code:match("%S") then
          code = code:sub(2, -2)
        end
        push_segment("code", code)
        i = j + tick_count
      else
        push_segment("text", char)
        i = i + 1
      end
    elseif char == "[" then
      local close = find_matching(text, i, "[", "]")
      local label = close and text:sub(i + 1, close - 1)
      if close and text:sub(close + 1, close + 1) == "(" then
        local url, title, finish = parse_parenthesized_target(text, close + 1)
        if finish then
          local label_segments = parse_inline(label, references, opts, footnotes)
          for _, segment in ipairs(label_segments) do
            segment.url = url
          end
          append_segments(segments, label_segments)
          i = finish + 1
        else
          push_segment(style_kind(opts), char)
          i = i + 1
        end
      elseif close and text:sub(close + 1, close + 1) == "[" then
        local finish = find_matching(text, close + 1, "[", "]")
        if finish then
          local ref = text:sub(close + 2, finish - 1)
          local url = references[normalize_link_label(ref ~= "" and ref or label)]
          if url then
            local label_segments = parse_inline(label, references, opts, footnotes)
            for _, segment in ipairs(label_segments) do
              segment.url = url
            end
            append_segments(segments, label_segments)
            i = finish + 1
          else
            push_segment(style_kind(opts), char)
            i = i + 1
          end
        else
          push_segment(style_kind(opts), char)
          i = i + 1
        end
      elseif close then
        if label:sub(1, 1) == "^" then
          local footnote_id = trim(label:sub(2))
          local number = register_footnote_reference(footnotes, footnote_id)
          if number then
            push_segment(style_kind(opts), string.format("[%d]", number), "#footnote-" .. footnote_id, {
              footnote_id = footnote_id,
              footnote_number = number
            })
          else
            push_segment(style_kind(opts), char)
          end
          i = close + 1
        else
          local url = references[normalize_link_label(label)]
          if url then
            local label_segments = parse_inline(label, references, opts, footnotes)
            for _, segment in ipairs(label_segments) do
              segment.url = url
            end
            append_segments(segments, label_segments)
            i = close + 1
          else
            push_segment(style_kind(opts), char)
            i = i + 1
          end
        end
      else
        push_segment(style_kind(opts), char)
        i = i + 1
      end
    elseif char == "<" then
      local close = text:find(">", i + 1, true)
      if close then
        local resource = text:sub(i + 1, close - 1)
        local url = resource:match("^https?://%S+$")
        if not url and resource:match("^[^%s@]+@[^%s@]+%.[^%s@]+$") then
          url = "mailto:" .. resource
        end
        if url then
          push_segment(style_kind(opts), resource, url)
          i = close + 1
        else
          push_segment(style_kind(opts), char)
          i = i + 1
        end
      else
        push_segment(style_kind(opts), char)
        i = i + 1
      end
    elseif text:sub(i):match("^https?://%S+") then
      local url = trim_plain_url(text:sub(i):match("^(https?://%S+)"))
      push_segment(style_kind(opts), url, url)
      i = i + #url
    else
      local marker_index = find_next_inline_marker(text, i)
      local url_index = find_next_plain_url(text, i)
      local j
      if marker_index and url_index then
        j = math.min(marker_index, url_index)
      else
        j = marker_index or url_index
      end

      if j then
        push_segment(style_kind(opts), text:sub(i, j - 1))
        i = j
      else
        push_segment(style_kind(opts), text:sub(i))
        break
      end
    end
  end

  return segments
end

parse_inline_lines = function(lines, references, footnotes, opts)
  local combined = {}
  for i, line in ipairs(lines) do
    local text = ltrim(line)
    local hard_break = false
    if i < #lines and text:sub(-1) == "\\" then
      hard_break = true
      text = text:sub(1, -2)
    elseif i < #lines and text:match("  +$") then
      hard_break = true
      text = rtrim(text)
    end

    combined[#combined + 1] = text
    if i < #lines then
      if hard_break then
        combined[#combined + 1] = "\0"
      else
        combined[#combined + 1] = "\n"
      end
    end
  end
  return parse_inline(table.concat(combined), references, opts, footnotes)
end

local function get_first_text(blocks)
  for _, block in ipairs(blocks or {}) do
    if block.text and block.text ~= "" then
      return block.text
    elseif block.type == "quote" then
      local nested = get_first_text(block.blocks)
      if nested then
        return nested
      end
    end
  end
end

extract_single_image = function(segments)
  if #segments == 1 and segments[1].kind == "image" then
    return {
      alt = segments[1].alt,
      url = segments[1].image_url,
      link_url = segments[1].url
    }
  end
end

local function parse_blocks_from_lines(lines, state)
  local blocks = {}
  local i = 1

  local function parse_nested_lines(nested_lines)
    if #nested_lines == 0 then
      return {}
    end
    return parse_blocks_from_lines(nested_lines, state)
  end

  while i <= #lines do
    local line = lines[i]

    if is_blank(line) then
      i = i + 1
      goto continue
    end

    if is_html_comment_start(line) then
      while i <= #lines do
        if is_html_comment_end(lines[i]) then
          i = i + 1
          break
        end
        i = i + 1
      end
      goto continue
    end

    local footnote_id, footnote_text, footnote_indent = get_footnote_definition(line)
    if footnote_id then
      local definition_lines = { footnote_text }
      local blank_pending = false
      i = i + 1
      while i <= #lines do
        if is_blank(lines[i]) then
          definition_lines[#definition_lines + 1] = ""
          blank_pending = true
          i = i + 1
        else
          local indent = get_indentation_width(lines[i])
          local next_footnote = get_footnote_definition(lines[i])
          if next_footnote and indent <= footnote_indent then
            break
          end
          if indent < footnote_indent and (blank_pending or is_block_start(lines[i])) then
            break
          end
          definition_lines[#definition_lines + 1] = strip_indentation(lines[i], math.min(indent, footnote_indent))
          blank_pending = false
          i = i + 1
        end
      end
      state.footnote_definitions[footnote_id] = {
        blocks = parse_nested_lines(definition_lines)
      }
      goto continue
    end

    local ref_label, ref_url = get_reference_definition(line)
    if ref_label then
      state.references[ref_label] = ref_url
      i = i + 1
      goto continue
    end

    local fence_char, fence_len, info = get_fence(line)
    if fence_char then
      local code_lines = {}
      i = i + 1
      while i <= #lines do
        local close_char, close_len = get_fence(lines[i])
        if close_char == fence_char and close_len >= fence_len then
          break
        end
        code_lines[#code_lines + 1] = lines[i]
        i = i + 1
      end
      blocks[#blocks + 1] = {
        type = "code",
        info = info,
        lines = code_lines
      }
      i = i + 1
      goto continue
    end

    if is_indented_code_line(line) then
      local code_lines = {}
      while i <= #lines do
        if is_blank(lines[i]) then
          code_lines[#code_lines + 1] = ""
          i = i + 1
        elseif is_indented_code_line(lines[i]) then
          code_lines[#code_lines + 1] = strip_indentation(lines[i], 4)
          i = i + 1
        else
          break
        end
      end
      blocks[#blocks + 1] = {
        type = "code",
        lines = code_lines
      }
      goto continue
    end

    local table_block, next_index = parse_table_block(lines, i)
    if table_block then
      blocks[#blocks + 1] = table_block
      i = next_index
      goto continue
    end

    local level, heading = get_heading(line)
    if level then
      blocks[#blocks + 1] = {
        type = "heading",
        level = level,
        text = heading,
        lines = { heading }
      }
      i = i + 1
      goto continue
    end

    if is_rule(line) then
      blocks[#blocks + 1] = { type = "rule" }
      i = i + 1
      goto continue
    end

    if is_blockquote(line) then
      local quote_lines = {}
      while i <= #lines and is_blockquote(lines[i]) do
        quote_lines[#quote_lines + 1] = strip_blockquote_prefix(lines[i]) or ""
        i = i + 1
      end
      local nested_blocks = parse_nested_lines(quote_lines)
      blocks[#blocks + 1] = {
        type = "quote",
        blocks = nested_blocks,
        text = get_first_text(nested_blocks)
      }
      goto continue
    end

    local list_item = get_list_item(line)
    if list_item then
      local list_type = list_item.type
      local start_index = list_item.index or 1
      local items = {}
      while i <= #lines do
        local marker = get_list_item(lines[i])
        if not marker or marker.raw_indent ~= list_item.raw_indent then
          break
        end
        if marker.type ~= list_type then
          break
        end

        local item_lines = { marker.text }
        local item_i = i + 1
        local blank_pending = false
        while item_i <= #lines do
          if is_blank(lines[item_i]) then
            item_lines[#item_lines + 1] = ""
            blank_pending = true
            item_i = item_i + 1
          else
            local next_marker = get_list_item(lines[item_i])
            local indent = get_indentation_width(lines[item_i])
            if next_marker and next_marker.raw_indent == marker.raw_indent then
              break
            end
            if indent <= marker.raw_indent and (blank_pending or is_block_start(lines[item_i])) then
              break
            end
            if indent > 0 then
              local strip_width = math.min(indent, marker.content_indent)
              if next_marker then
                strip_width = math.min(indent, marker.raw_indent + 2)
              end
              item_lines[#item_lines + 1] = strip_indentation(lines[item_i], strip_width)
            else
              item_lines[#item_lines + 1] = ltrim(lines[item_i])
            end
            blank_pending = false
            item_i = item_i + 1
          end
        end

        local nested_blocks = parse_nested_lines(item_lines)
        items[#items + 1] = {
          index = marker.index or (start_index + #items),
          text = get_first_text(nested_blocks) or marker.text,
          checked = marker.checked,
          raw_indent = marker.raw_indent or 0,
          blocks = nested_blocks
        }
        i = item_i
      end
      normalize_list_nesting(items)
      blocks[#blocks + 1] = {
        type = list_type,
        items = items
      }
      goto continue
    end

    if not is_block_start(line) and get_definition_item(lines[i + 1] or "") then
      local items = {}
      while i <= #lines and not is_block_start(lines[i]) and get_definition_item(lines[i + 1] or "") do
        local term = trim(lines[i])
        i = i + 1
        local definitions = {}
        while i <= #lines do
          local def_text, def_indent = get_definition_item(lines[i])
          if not def_text then
            break
          end
          local def_lines = { def_text }
          local def_i = i + 1
          local blank_pending = false
          while def_i <= #lines do
            if is_blank(lines[def_i]) then
              def_lines[#def_lines + 1] = ""
              blank_pending = true
              def_i = def_i + 1
            else
              local next_def = get_definition_item(lines[def_i])
              local indent = get_indentation_width(lines[def_i])
              if next_def and indent <= def_indent then
                break
              end
              if indent < def_indent and (blank_pending or is_block_start(lines[def_i])) then
                break
              end
              def_lines[#def_lines + 1] = strip_indentation(lines[def_i], math.min(indent, def_indent))
              blank_pending = false
              def_i = def_i + 1
            end
          end
          definitions[#definitions + 1] = {
            blocks = parse_nested_lines(def_lines)
          }
          i = def_i
        end
        items[#items + 1] = {
          term = term,
          definitions = definitions
        }
      end
      blocks[#blocks + 1] = {
        type = "definition_list",
        items = items
      }
      goto continue
    end

    local paragraph = {}
    local setext_level
    while i <= #lines and not is_blank(lines[i]) do
      if #paragraph == 0 and get_setext_heading_level(lines[i + 1] or "") then
        paragraph[#paragraph + 1] = trim(lines[i])
        setext_level = get_setext_heading_level(lines[i + 1] or "")
        i = i + 2
        break
      end
      if #paragraph > 0 and is_block_start(lines[i]) then
        break
      end
      paragraph[#paragraph + 1] = ltrim(lines[i])
      i = i + 1
      if is_block_start(lines[i] or "") then
        break
      end
    end
    local text = trim(table.concat(paragraph, " "))
    if setext_level then
      blocks[#blocks + 1] = {
        type = "heading",
        level = setext_level,
        text = text,
        lines = { text }
      }
    else
      blocks[#blocks + 1] = {
        type = "paragraph",
        text = text,
        lines = paragraph
      }
    end

    ::continue::
  end

  return blocks
end

local function prepare_blocks(blocks, references, footnotes)
  for _, block in ipairs(blocks) do
    if block.type == "paragraph" then
      local trimmed_lines = {}
      for i, line in ipairs(block.lines or { block.text }) do
        trimmed_lines[i] = trim(line)
      end

      local image_row = parse_image_row(trimmed_lines, references)
      if image_row then
        block.type = "image_row"
        block.images = image_row
      else
        local paragraph_segments = parse_inline_lines(block.lines or { block.text }, references, footnotes)
        local image = extract_single_image(paragraph_segments)
        if image then
          block.type = "image"
          block.alt = image.alt
          block.url = image.url
          block.link_url = image.link_url
          block.alignment = "left"
        else
          block.segments = paragraph_segments
        end
      end
    elseif block.type == "heading" then
      block.segments = parse_inline_lines(block.lines or { block.text }, references, footnotes)
    elseif block.type == "quote" then
      prepare_blocks(block.blocks or {}, references, footnotes)
    elseif block.type == "table" then
      for i, cell in ipairs(block.headers) do
        block.headers[i] = parse_cell_content(cell, references, footnotes)
      end
      for row_index, row in ipairs(block.rows) do
        for cell_index, cell in ipairs(row) do
          row[cell_index] = parse_cell_content(cell, references, footnotes)
        end
        block.rows[row_index] = row
      end
    elseif block.type == "definition_list" then
      for _, item in ipairs(block.items) do
        item.term_segments = parse_inline_lines({ item.term }, references, footnotes)
        for _, definition in ipairs(item.definitions) do
          prepare_blocks(definition.blocks or {}, references, footnotes)
        end
      end
    elseif block.items then
      for _, item in ipairs(block.items) do
        if item.blocks then
          prepare_blocks(item.blocks, references, footnotes)
        else
          item.segments = parse_inline_lines({ item.text }, references, footnotes)
        end
      end
    end
  end
end

local function build_footnotes_block(footnotes)
  if #footnotes.order == 0 then
    return nil
  end

  local items = {}
  for number, id in ipairs(footnotes.order) do
    local definition = footnotes.definitions[id]
    items[#items + 1] = {
      id = id,
      index = number,
      text = get_first_text(definition.blocks) or id,
      blocks = definition.blocks,
      raw_indent = 0
    }
  end
  return {
    type = "footnotes",
    items = items
  }
end

local function parse_document(text)
  local state = {
    references = {},
    footnote_definitions = {}
  }
  local blocks = parse_blocks_from_lines(split_lines(text), state)
  local footnotes = {
    definitions = state.footnote_definitions,
    numbers = {},
    order = {}
  }
  prepare_blocks(blocks, state.references, footnotes)
  local footnotes_block = build_footnotes_block(footnotes)
  if footnotes_block then
    prepare_blocks({ footnotes_block }, state.references, footnotes)
    blocks[#blocks + 1] = footnotes_block
  end
  return blocks, state.references, footnotes
end

---Parses markdown text into the intermediate block structure used by the view.
---@param text string
---@return table[]
function MarkdownView.parse_blocks(text)
  local blocks = parse_document(text)
  return blocks
end

local function get_inline_image(entry, max_height)
  if entry.status ~= "ready" or not entry.image then
    return nil
  end

  local width, height = entry.image:get_size()
  local scale = height > max_height and (max_height / height) or 1
  local scaled_width = math.max(math.floor(width * scale), 1)
  local scaled_height = math.max(math.floor(height * scale), 1)
  entry.inline_cache = entry.inline_cache or {}
  local cache_key = string.format("%dx%d", scaled_width, scaled_height)
  if entry.inline_cache[cache_key] then
    return entry.inline_cache[cache_key], scaled_width, scaled_height
  end

  local image
  if scale == 1 then
    image = entry.image
  elseif entry.type == "svg" then
    image = canvas.load_svg_image(entry.path, scaled_width, scaled_height)
  else
    image = entry.image:scaled(scaled_width, scaled_height, "nearest")
  end
  entry.inline_cache[cache_key] = image
  return image, scaled_width, scaled_height
end

local function tokenize_segments(self, segments, fontset, base_color, accent_color)
  local tokens = {}

  local function add_token(segment, text, is_space)
    if text == "" and segment.kind ~= "linebreak" and segment.kind ~= "image" then
      return
    end

    local font = fontset.normal
    local color = base_color
    local background

    if segment.kind == "bold" then
      font = segment.strikethrough and fontset.bold_strikethrough or fontset.bold
    elseif segment.kind == "italic" then
      font = segment.strikethrough and fontset.italic_strikethrough or fontset.italic
    elseif segment.kind == "bold_italic" then
      font = segment.strikethrough and fontset.bold_italic_strikethrough or fontset.bold_italic
    elseif segment.kind == "code" then
      font = segment.strikethrough and fontset.code_strikethrough or fontset.code
      background = COLOR_BACKGROUND2
    elseif segment.strikethrough then
      font = fontset.strikethrough
    end

    if segment.kind == "linebreak" then
      tokens[#tokens + 1] = { type = "linebreak" }
      return
    end

    if segment.kind == "image" and segment.image_url then
      local entry = self:ensure_image_entry({
        alt = segment.alt,
        url = segment.image_url
      })
      if entry.status == "ready" then
        local max_height = math.max(common.round(font:get_height() * config.line_height), font:get_height())
        local image, width, height = get_inline_image(entry, max_height)
        if image then
          tokens[#tokens + 1] = {
            type = "image",
            image = image,
            width = width,
            height = height,
            url = segment.url,
            is_space = false
          }
          return
        end
      end
      text = segment.alt ~= "" and segment.alt or segment.image_url
      font = fontset.italic or font
      color = COLOR_DIM
      is_space = false
    end

    if segment.url then
      color = COLOR_LINK
    end

    tokens[#tokens + 1] = {
      text = text,
      font = font,
      color = color,
      background = background,
      url = segment.url,
      is_space = is_space
    }
  end

  for _, segment in ipairs(segments) do
    if segment.kind == "linebreak" then
      add_token(segment, "", false)
      goto continue
    elseif segment.kind == "image" then
      add_token(segment, segment.alt, false)
      goto continue
    elseif segment.kind == "code" then
      add_token(segment, segment.text, false)
      goto continue
    end
    local text = segment.text
    local pos = 1
    while pos <= #text do
      local s, e = text:find("%s+", pos)
      if s == pos then
        add_token(segment, text:sub(s, e), true)
        pos = e + 1
      elseif s then
        add_token(segment, text:sub(pos, s - 1), false)
        pos = s
      else
        add_token(segment, text:sub(pos), false)
        break
      end
    end
    ::continue::
  end

  return tokens
end

local function append_line(lines, line, max_width)
  while line.fragments[#line.fragments] and line.fragments[#line.fragments].is_space do
    line.width = line.width - line.fragments[#line.fragments].width
    table.remove(line.fragments)
  end

  if #line.fragments == 0 then
    line.width = line.indent
  end

  local height = math.max(common.round(line.font_height * config.line_height), line.font_height)
  lines[#lines + 1] = {
    indent = line.indent,
    width = math.max(line.width - line.indent, 0),
    height = height,
    fragments = line.fragments
  }

  return {
    indent = line.next_indent,
    width = line.next_indent,
    font_height = line.default_font_height,
    default_font_height = line.default_font_height,
    next_indent = line.next_indent,
    fragments = {}
  }, math.max(max_width, line.width)
end

local function layout_text_lines(self, segments, fontset, base_color, accent_color, max_width, first_indent, next_indent)
  local tokens = tokenize_segments(self, segments, fontset, base_color, accent_color)
  local lines = {}
  local used_width = 0
  local line = {
    indent = first_indent,
    width = first_indent,
    font_height = fontset.normal:get_height(),
    default_font_height = fontset.normal:get_height(),
    next_indent = next_indent,
    fragments = {}
  }

  for _, token in ipairs(tokens) do
    if token.type == "linebreak" then
      line, used_width = append_line(lines, line, used_width)
      goto continue
    elseif token.type ~= "image" then
      token.width = token.font:get_width(token.text)
    end
    if token.is_space and #line.fragments == 0 then
      goto continue
    end

    if not token.is_space and #line.fragments > 0 and line.width + token.width > max_width then
      line, used_width = append_line(lines, line, used_width)
    elseif token.is_space and line.width + token.width > max_width then
      line, used_width = append_line(lines, line, used_width)
      goto continue
    end

    line.fragments[#line.fragments + 1] = token
    line.width = line.width + token.width
    if token.type == "image" then
      line.font_height = math.max(line.font_height, token.height)
    else
      line.font_height = math.max(line.font_height, token.font:get_height())
    end

    ::continue::
  end

  if #line.fragments > 0 or #lines == 0 then
    line, used_width = append_line(lines, line, used_width)
  end

  return lines, math.max(used_width, next_indent)
end

local function add_text_line(commands, x, y, line)
  local links
  local offset_x = 0
  for _, fragment in ipairs(line.fragments) do
    if fragment.url then
      links = links or {}
      links[#links + 1] = {
        x = x + line.indent + offset_x,
        y = y,
        width = fragment.width,
        height = line.height,
        url = fragment.url
      }
    end
    offset_x = offset_x + fragment.width
  end
  commands[#commands + 1] = {
    type = "text",
    x = x + line.indent,
    y = y,
    height = line.height,
    links = links,
    fragments = line.fragments
  }
end

local function add_paragraph(commands, y, block, fontset, color, accent_color, max_width, first_indent, next_indent, spacing)
  local lines, used_width = layout_text_lines(
    block.view,
    block.segments,
    fontset,
    color,
    accent_color,
    max_width,
    first_indent,
    next_indent
  )

  local block_height = 0
  for _, line in ipairs(lines) do
    add_text_line(commands, block.x or 0, y + block_height, line)
    block_height = block_height + line.height
  end
  
  return y + block_height + (spacing or BLOCK_SPACING), used_width
end

local function get_code_fragments(line, code_font, code_syntax, state)
  local tokens
  tokens, state = tokenizer.tokenize(code_syntax, line .. "\n", state)

  local fragments = {}
  local line_width = 0
  local last_token = nil
  local tokens_count = #tokens
  if tokens_count > 0 and string.sub(tokens[tokens_count], -1) == "\n" then
    last_token = tokens_count - 1
  end

  code_font:set_tab_size(config.indent_size)
  for tidx, type, text in tokenizer.each_token(tokens) do
    if tidx == last_token then
      text = text:sub(1, -2)
    end
    if text ~= "" then
      local font = style.syntax_fonts[type] or code_font
      if font ~= code_font then
        font:set_tab_size(config.indent_size)
      end
      local width = font:get_width(text, { tab_offset = line_width })
      fragments[#fragments + 1] = {
        text = text,
        font = font,
        color = make_syntax_color(type, make_syntax_color("normal")),
        width = width
      }
      line_width = line_width + width
    end
  end

  return fragments, line_width, state
end

local function add_code_block(commands, y, lines, font, info, max_width, x_offset)
  x_offset = x_offset or 0
  local code_width = 0
  local line_height = math.max(common.round(font:get_height() * config.line_height), font:get_height())
  local block_height = math.max(#lines, 1) * line_height + BLOCK_PADDING_Y * 2
  local code_syntax = resolve_code_fence_syntax(info)
  local tokenized_lines = {}
  local state

  if #lines == 0 then
    lines = { "" }
  end

  for i, line in ipairs(lines) do
    local fragments, line_width
    fragments, line_width, state = get_code_fragments(line, font, code_syntax, state)
    tokenized_lines[i] = fragments
    code_width = math.max(code_width, line_width)
  end

  commands[#commands + 1] = {
    type = "rect",
    x = x_offset,
    y = y,
    width = math.max(code_width + BLOCK_PADDING_X * 2, max_width),
    height = block_height,
    color = COLOR_BACKGROUND2
  }

  local offset_y = y + BLOCK_PADDING_Y
  for _, fragments in ipairs(tokenized_lines) do
    commands[#commands + 1] = {
      type = "text",
      x = x_offset + BLOCK_PADDING_X,
      y = offset_y,
      height = line_height,
      tabbed = true,
      fragments = fragments
    }
    offset_y = offset_y + line_height
  end

  return y + block_height + BLOCK_SPACING, math.max(code_width + BLOCK_PADDING_X * 2, max_width)
end

local function measure_segments(self, segments, fontset, base_color, accent_color)
  local tokens = tokenize_segments(self, segments, fontset, base_color, accent_color)
  local min_width = 0
  local preferred_width = 0

  for _, token in ipairs(tokens) do
    local width = token.type == "image" and token.width or token.font:get_width(token.text)
    preferred_width = preferred_width + width
    if token.type ~= "linebreak" and not token.is_space then
      min_width = math.max(min_width, width)
    end
  end

  return min_width, preferred_width
end

local function measure_table_cell(self, cell, fontset, base_color, accent_color)
  if cell.type == "image" then
    local entry = self:ensure_image_entry(cell)
    if entry.status == "ready" and entry.image then
      local width = entry.image:get_size()
      return width, width
    end

    local label = cell.alt ~= "" and cell.alt or cell.url
    local message = entry.status == "loading"
      and ("Loading image: " .. label)
      or ("Image unavailable: " .. label)
    local fallback_width = fontset.normal:get_width(message)
    return fallback_width, fallback_width
  end

  return measure_segments(self, cell.segments, fontset, base_color, accent_color)
end

local function compute_table_column_widths(self, block, body_fontset, header_fontset, accent_color, max_width)
  local columns = #block.headers
  local widths = {}
  local minimums = {}
  local preferreds = {}
  local available = max_width - TABLE_BORDER * (columns + 1) - TABLE_CELL_PADDING_X * 2 * columns
  available = math.max(available, columns)

  for col = 1, columns do
    local min_width, preferred_width = measure_table_cell(
      self,
      block.headers[col],
      header_fontset,
      COLOR_TEXT,
      accent_color
    )
    for _, row in ipairs(block.rows) do
      local cell_min, cell_preferred = measure_table_cell(
        self,
        row[col],
        body_fontset,
        COLOR_TEXT,
        accent_color
      )
      min_width = math.max(min_width, cell_min)
      preferred_width = math.max(preferred_width, cell_preferred)
    end
    minimums[col] = min_width
    preferreds[col] = math.max(preferred_width, min_width)
  end

  local minimum_total = 0
  local preferred_total = 0
  for col = 1, columns do
    minimum_total = minimum_total + minimums[col]
    preferred_total = preferred_total + preferreds[col]
  end

  if minimum_total >= available then
    local remaining = available
    for col = 1, columns do
      widths[col] = math.max(1, math.floor(available * (minimums[col] / minimum_total)))
      remaining = remaining - widths[col]
    end
    local col = 1
    while remaining > 0 do
      widths[col] = widths[col] + 1
      remaining = remaining - 1
      col = col % columns + 1
    end
    return widths
  end

  for col = 1, columns do
    widths[col] = minimums[col]
  end

  local extra = available - minimum_total
  local desired_extra_total = math.max(preferred_total - minimum_total, 0)
  if desired_extra_total == 0 then
    desired_extra_total = columns
    for col = 1, columns do
      preferreds[col] = minimums[col] + 1
    end
  end

  for col = 1, columns do
    local desired_extra = preferreds[col] - minimums[col]
    if desired_extra_total == columns and desired_extra == 0 then
      desired_extra = 1
    end
    local add = math.floor(extra * (desired_extra / desired_extra_total))
    widths[col] = widths[col] + add
  end

  local used = 0
  for col = 1, columns do
    used = used + widths[col]
  end

  local remaining = available - used
  local col = 1
  while remaining > 0 do
    widths[col] = widths[col] + 1
    remaining = remaining - 1
    col = col % columns + 1
  end

  return widths
end

local function add_table_block(self, commands, y, block, body_fontset, accent_color, max_width, x_offset)
  x_offset = x_offset or 0
  local header_fontset = {
    normal = body_fontset.bold,
    bold = body_fontset.bold,
    italic = body_fontset.bold_italic,
    bold_italic = body_fontset.bold_italic,
    code = body_fontset.code
  }
  local column_widths = compute_table_column_widths(
    self,
    block,
    body_fontset,
    header_fontset,
    accent_color,
    max_width
  )
  local column_offsets = {}
  local total_width = TABLE_BORDER

  for col = 1, #column_widths do
    column_offsets[col] = total_width
    total_width = total_width + column_widths[col] + TABLE_CELL_PADDING_X * 2 + TABLE_BORDER
  end

  local rows = {}
  rows[1] = {
    header = true,
    cells = block.headers
  }
  for _, row in ipairs(block.rows) do
    rows[#rows + 1] = {
      header = false,
      cells = row
    }
  end

  local laid_out_rows = {}
  local table_height = TABLE_BORDER
  for row_index, row in ipairs(rows) do
    local row_height = 0
    local cell_layouts = {}
    for col = 1, #column_widths do
      local fontset = row.header and header_fontset or body_fontset
      local cell = row.cells[col]
      if cell.type == "image" then
        local entry = self:ensure_image_entry(cell)
        if entry.status == "ready" then
          local image, image_width, image_height = self:get_scaled_image(entry, math.max(column_widths[col], 1))
          if image then
            row_height = math.max(row_height, image_height)
            cell_layouts[col] = {
              type = "image",
              image = image,
              width = image_width,
              height = image_height,
              link_url = cell.link_url
            }
          end
        end

        if not cell_layouts[col] then
          local label = cell.alt ~= "" and cell.alt or cell.url
          local message = entry.status == "loading"
            and ("Loading image: " .. label)
            or ("Image unavailable: " .. label)
          local lines = layout_text_lines(
            self,
            {
              { kind = "italic", text = message }
            },
            fontset,
            COLOR_DIM,
            accent_color,
            math.max(column_widths[col], 1),
            0,
            0
          )
          local content_height = 0
          for _, line in ipairs(lines) do
            content_height = content_height + line.height
          end
          row_height = math.max(row_height, content_height)
          cell_layouts[col] = {
            type = "text",
            lines = lines
          }
        end
      else
          local lines = layout_text_lines(
            self,
            cell.segments,
            fontset,
            COLOR_TEXT,
            accent_color,
          math.max(column_widths[col], 1),
          0,
          0
        )
        local content_height = 0
        for _, line in ipairs(lines) do
          content_height = content_height + line.height
        end
        row_height = math.max(row_height, content_height)
        cell_layouts[col] = {
          type = "text",
          lines = lines
        }
      end
    end
    row_height = row_height + TABLE_CELL_PADDING_Y * 2
    laid_out_rows[row_index] = {
      header = row.header,
      height = row_height,
      cells = cell_layouts
    }
    table_height = table_height + row_height + TABLE_BORDER
  end

  local current_y = y + TABLE_BORDER
  for row_index, row in ipairs(laid_out_rows) do
    if row.header then
      commands[#commands + 1] = {
        type = "rect",
        x = x_offset + TABLE_BORDER,
        y = current_y,
        width = total_width - TABLE_BORDER * 2,
        height = row.height,
        color = COLOR_BACKGROUND2
      }
    end

    for col = 1, #column_widths do
      local content_y = current_y + TABLE_CELL_PADDING_Y
      local cell = row.cells[col]
      local inner_width = column_widths[col]
      local alignment = block.alignments[col] or "left"
      if cell.type == "image" then
        local image_x = x_offset + column_offsets[col] + TABLE_CELL_PADDING_X
        if alignment == "center" then
          image_x = image_x + math.max(math.floor((inner_width - cell.width) / 2), 0)
        elseif alignment == "right" then
          image_x = image_x + math.max(inner_width - cell.width, 0)
        end
        commands[#commands + 1] = {
          type = "image",
          x = image_x,
          y = current_y + TABLE_CELL_PADDING_Y + math.max(math.floor((row.height - TABLE_CELL_PADDING_Y * 2 - cell.height) / 2), 0),
          width = cell.width,
          height = cell.height,
          image = cell.image,
          link_url = cell.link_url
        }
      else
        for _, line in ipairs(cell.lines) do
          local line_x = x_offset + column_offsets[col] + TABLE_CELL_PADDING_X
          if alignment == "center" then
            line_x = line_x + math.max(math.floor((inner_width - line.width) / 2), 0)
          elseif alignment == "right" then
            line_x = line_x + math.max(inner_width - line.width, 0)
          end
          add_text_line(
            commands,
            line_x,
            content_y,
            line
          )
          content_y = content_y + line.height
        end
      end
    end

    current_y = current_y + row.height + TABLE_BORDER
  end

  local line_y = y
  commands[#commands + 1] = {
    type = "rect",
    x = x_offset,
    y = line_y,
    width = total_width,
    height = TABLE_BORDER,
    color = COLOR_DIVIDER
  }
  for _, row in ipairs(laid_out_rows) do
    line_y = line_y + row.height + TABLE_BORDER
    commands[#commands + 1] = {
      type = "rect",
      x = x_offset,
      y = line_y,
      width = total_width,
      height = TABLE_BORDER,
      color = COLOR_DIVIDER
    }
  end

  local line_x = 0
  for _ = 0, #column_widths do
    commands[#commands + 1] = {
      type = "rect",
      x = x_offset + line_x,
      y = y,
      width = TABLE_BORDER,
      height = table_height,
      color = COLOR_DIVIDER
    }
    if column_offsets[_ + 1] then
      line_x = column_offsets[_ + 1] + column_widths[_ + 1] + TABLE_CELL_PADDING_X * 2
    end
  end

  return y + table_height + BLOCK_SPACING, total_width
end

local function render_blocks(self, commands, y, blocks, width, x_offset, fonts, accent_color, anchors)
  local content_width = 0
  x_offset = x_offset or 0

  for _, block in ipairs(blocks) do
    local available_width = math.max(width - x_offset, 1)
    if block.type == "heading" then
      local fontset = fonts.heading[block.level]
      local used_width
      y, used_width = add_paragraph(
        commands,
        y,
        {
          view = self,
          x = x_offset,
          segments = block.segments
        },
        fontset,
        accent_color,
        accent_color,
        available_width,
        0,
        0
      )
      content_width = math.max(content_width, x_offset + used_width)
      if block.level <= 2 then
        commands[#commands + 1] = {
          type = "rect",
          x = x_offset,
          y = y - BLOCK_SPACING + RULE_GAP / 2,
          width = available_width,
          height = RULE_HEIGHT,
          color = COLOR_DIVIDER
        }
        y = y + RULE_GAP
      end
    elseif block.type == "paragraph" then
      local used_width
      y, used_width = add_paragraph(
        commands,
        y,
        {
          view = self,
          x = x_offset,
          segments = block.segments
        },
        fonts.body,
        COLOR_TEXT,
        accent_color,
        available_width,
        0,
        0,
        PARAGRAPH_SPACING
      )
      content_width = math.max(content_width, x_offset + used_width)
    elseif block.type == "quote" then
      local quote_start = y
      local nested_width
      y, nested_width = render_blocks(
        self,
        commands,
        y,
        block.blocks or {},
        width,
        x_offset + QUOTE_BAR_WIDTH + QUOTE_GAP,
        fonts,
        accent_color,
        anchors
      )
      commands[#commands + 1] = {
        type = "rect",
        x = x_offset,
        y = quote_start,
        width = QUOTE_BAR_WIDTH,
        height = math.max(y - quote_start - BLOCK_SPACING, RULE_HEIGHT),
        color = COLOR_DIVIDER
      }
      content_width = math.max(content_width, nested_width, x_offset + QUOTE_BAR_WIDTH)
    elseif block.type == "unordered_list" or block.type == "ordered_list" or block.type == "footnotes" then
      if block.type == "footnotes" then
        commands[#commands + 1] = {
          type = "rect",
          x = x_offset,
          y = y + RULE_GAP,
          width = available_width,
          height = RULE_HEIGHT,
          color = COLOR_DIVIDER
        }
        y = y + RULE_GAP * 2 + RULE_HEIGHT
      end

      for _, item in ipairs(block.items) do
        local nested_offset = block.type == "footnotes" and 0 or LIST_INDENT * (item.nesting or 0)
        local marker
        local marker_size
        if block.type == "ordered_list" or block.type == "footnotes" then
          marker = string.format("%d.", item.index)
        elseif item.checked ~= nil then
          marker_size = math.max(common.round(fonts.body.normal:get_height() * CHECKBOX_SIZE_RATIO), 1)
        else
          marker = "\226\128\162"
        end

        local marker_width = (marker_size or fonts.body.normal:get_width(marker)) + style.padding.x
        local marker_x = x_offset + nested_offset + LIST_INDENT
        local content_x = marker_x + marker_width
        local item_start_y = y
        if block.type == "footnotes" and item.id then
          anchors["footnote-" .. item.id] = item_start_y
        end

        local item_blocks = item.blocks
        if not item_blocks or #item_blocks == 0 then
          item_blocks = {
            {
              type = "paragraph",
              segments = item.segments or parse_inline_lines({ item.text or "" }, self.references, self.footnotes),
              lines = { item.text or "" }
            }
          }
        end

        local item_width
        y, item_width = render_blocks(
          self,
          commands,
          y,
          item_blocks,
          width,
          content_x,
          fonts,
          accent_color,
          anchors
        )
        content_width = math.max(content_width, item_width, content_x)

        if item.checked ~= nil then
          commands[#commands + 1] = {
            type = "checkbox",
            x = marker_x,
            y = item_start_y,
            width = marker_size,
            height = math.max(common.round(fonts.body.normal:get_height() * config.line_height), fonts.body.normal:get_height()),
            checked = item.checked,
            color = accent_color
          }
        else
          commands[#commands + 1] = {
            type = "text",
            x = marker_x,
            y = item_start_y,
            height = math.max(common.round(fonts.body.normal:get_height() * config.line_height), fonts.body.normal:get_height()),
            fragments = {
              {
                text = marker,
                font = fonts.body.normal,
                color = accent_color,
                width = fonts.body.normal:get_width(marker)
              }
            }
          }
        end

        y = y - BLOCK_SPACING + common.round(style.padding.y / 2)
      end
      y = y + BLOCK_SPACING
    elseif block.type == "definition_list" then
      for _, item in ipairs(block.items) do
        local term_width
        y, term_width = add_paragraph(
          commands,
          y,
          {
            view = self,
            x = x_offset,
            segments = item.term_segments
          },
          {
            normal = fonts.body.bold,
            bold = fonts.body.bold,
            italic = fonts.body.bold_italic,
            bold_italic = fonts.body.bold_italic,
            code = fonts.body.code,
            strikethrough = fonts.body.bold_strikethrough,
            bold_strikethrough = fonts.body.bold_strikethrough,
            italic_strikethrough = fonts.body.bold_italic_strikethrough,
            bold_italic_strikethrough = fonts.body.bold_italic_strikethrough,
            code_strikethrough = fonts.body.code_strikethrough
          },
          COLOR_TEXT,
          accent_color,
          available_width,
          0,
          0,
          common.round(style.padding.y / 2)
        )
        content_width = math.max(content_width, x_offset + term_width)
        for _, definition in ipairs(item.definitions) do
          local definition_width
          y, definition_width = render_blocks(
            self,
            commands,
            y,
            definition.blocks or {},
            width,
            x_offset + LIST_INDENT,
            fonts,
            accent_color,
            anchors
          )
          content_width = math.max(content_width, definition_width)
        end
      end
    elseif block.type == "code" then
      local used_width
      y, used_width = add_code_block(commands, y, block.lines, fonts.code, block.info, available_width, x_offset)
      content_width = math.max(content_width, x_offset + used_width)
    elseif block.type == "table" then
      local used_width
      y, used_width = add_table_block(self, commands, y, block, fonts.body, accent_color, available_width, x_offset)
      content_width = math.max(content_width, x_offset + used_width)
    elseif block.type == "image" then
      local entry = self:ensure_image_entry(block)
      if entry.status == "ready" then
        local image, image_width, image_height = self:get_scaled_image(entry, available_width)
        if image then
          commands[#commands + 1] = {
            type = "image",
            x = x_offset + (block.alignment == "left" and 0 or math.max(math.floor((available_width - image_width) / 2), 0)),
            y = y,
            width = image_width,
            height = image_height,
            image = image,
            link_url = block.link_url
          }
          y = y + image_height + BLOCK_SPACING
          content_width = math.max(content_width, x_offset + image_width)
        end
      else
        local label = block.alt ~= "" and block.alt or block.url
        local message = entry.status == "loading"
          and ("Loading image: " .. label)
          or ("Image unavailable: " .. label)
        local used_width
        y, used_width = add_paragraph(
          commands,
          y,
          {
            view = self,
            x = x_offset,
            segments = { { kind = "italic", text = message } }
          },
          fonts.body,
          COLOR_DIM,
          accent_color,
          available_width,
          0,
          0
        )
        content_width = math.max(content_width, x_offset + used_width)
      end
    elseif block.type == "image_row" then
      local row_x = x_offset
      local row_y = y + IMAGE_ROW_PADDING_Y
      local row_height = 0
      local row_width = 0
      local label_font = fonts.body.italic
      local label_height = math.max(common.round(label_font:get_height() * config.line_height), label_font:get_height())

      for _, image_block in ipairs(block.images) do
        local entry = self:ensure_image_entry(image_block)
        local item_width, item_height, image
        if entry.status == "ready" then
          image, item_width, item_height = self:get_scaled_image(entry, available_width)
        else
          local label = image_block.alt ~= "" and image_block.alt or image_block.url
          local message = entry.status == "loading"
            and ("Loading image: " .. label)
            or ("Image unavailable: " .. label)
          item_width = label_font:get_width(message)
          item_height = label_height
          image = {
            message = message,
            font = label_font,
            color = COLOR_DIM
          }
        end

        if item_width and item_height then
          if row_x > x_offset and row_x + item_width > width then
            row_y = row_y + row_height + IMAGE_ROW_PADDING_Y
            row_x = x_offset
            row_height = 0
          end

          if entry.status == "ready" and image then
            commands[#commands + 1] = {
              type = "image",
              x = row_x,
              y = row_y,
              width = item_width,
              height = item_height,
              image = image,
              link_url = image_block.link_url
            }
          else
            commands[#commands + 1] = {
              type = "text",
              x = row_x,
              y = row_y,
              height = item_height,
              fragments = {
                {
                  text = image.message,
                  font = image.font,
                  color = image.color,
                  width = item_width
                }
              }
            }
          end

          row_x = row_x + item_width + style.padding.x
          row_height = math.max(row_height, item_height)
          row_width = math.max(row_width, row_x - style.padding.x)
        end
      end

      y = row_y + row_height + IMAGE_ROW_PADDING_Y + BLOCK_SPACING
      content_width = math.max(content_width, row_width)
    elseif block.type == "rule" then
      commands[#commands + 1] = {
        type = "rect",
        x = x_offset,
        y = y + RULE_GAP,
        width = available_width,
        height = RULE_HEIGHT,
        color = COLOR_DIVIDER
      }
      y = y + RULE_GAP * 2 + RULE_HEIGHT + BLOCK_SPACING
      content_width = math.max(content_width, x_offset + available_width)
    end
  end

  return y, content_width
end

local function make_fontset(font)
  local size = font:get_size()
  return {
    normal = font,
    bold = font:copy(size, { bold = true }),
    italic = font:copy(size, { italic = true }),
    bold_italic = font:copy(size, { bold = true, italic = true }),
    code = style.code_font:copy(size),
    strikethrough = font:copy(size, { strikethrough = true }),
    bold_strikethrough = font:copy(size, { bold = true, strikethrough = true }),
    italic_strikethrough = font:copy(size, { italic = true, strikethrough = true }),
    bold_italic_strikethrough = font:copy(size, { bold = true, italic = true, strikethrough = true }),
    code_strikethrough = style.code_font:copy(size, { strikethrough = true })
  }
end

---Constructor.
---@param source? string|core.markdownview.source
---@param title? string
function MarkdownView:new(source, title)
  MarkdownView.super.new(self)
  self.scrollable = true
  self.doc = nil
  self.image_cache = {}
  self.path = nil
  self.title = title
  self.text = ""
  self.blocks = {}
  self.references = {}
  self.footnotes = {
    definitions = {},
    numbers = {},
    order = {}
  }
  self.layout = nil
  self.font_cache = nil
  self.last_doc_change_id = nil

  if type(source) == "table" then
    self.doc = source.doc
    self.path = source.path
    self.title = source.title or source.name or title
    if self.doc then
      self:refresh_from_doc()
    elseif source.path then
      self:load(source.path)
    else
      self:set_text(source.text or "")
    end
  elseif type(source) == "string" and system.get_file_info(source) then
    self:load(source)
  else
    self:set_text(source or "")
  end
end

---Returns the persisted view state for file-backed previews.
---@return core.markdownview.state?
function MarkdownView:get_state()
  if self.doc or not self.path then
    return nil
  end
  return {
    path = self.path,
    scroll = {
      x = self.scroll.to.x,
      y = self.scroll.to.y
    }
  }
end

---Restores a file-backed markdown preview from saved state.
---@param state core.markdownview.state
---@return core.markdownview?
function MarkdownView.from_state(state)
  if state.path and system.get_file_info(state.path) then
    local view = MarkdownView(state.path)
    view.scroll.x, view.scroll.to.x = state.scroll.x, state.scroll.x
    view.scroll.y, view.scroll.to.y = state.scroll.y, state.scroll.y
    return view
  end
  return nil
end

---Checks whether a file path should be opened by the markdown preview.
---@param path string
---@return boolean
function MarkdownView.is_supported(path)
  local ext = path:match("%.([^.]+)$")
  if not ext then
    return false
  end
  ext = ext:lower()
  return ext == "md" or ext == "markdown"
end

---Invalidates the cached layout so it will be rebuilt on the next draw.
function MarkdownView:invalidate_layout()
  self.layout = nil
end

---Replaces the preview text and reparses the markdown document.
---@param text string?
function MarkdownView:set_text(text)
  self.text = (text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  self.blocks, self.references, self.footnotes = parse_document(self.text)
  self:invalidate_layout()
end

---Refreshes preview contents from the bound document.
function MarkdownView:refresh_from_doc()
  if not self.doc then
    return
  end

  self.path = self.doc.abs_filename
  self.title = common.basename(self.doc:get_name())
  self.last_doc_change_id = self.doc:get_change_id()
  self:set_text(self.doc:get_text(1, 1, math.huge, math.huge))
end

---Loads markdown contents from disk into the view.
---@param path string
---@return boolean loaded
---@return string? errmsg
function MarkdownView:load(path)
  local file, err = io.open(path, "rb")
  if not file then
    return false, err
  end
  local text = file:read("*a") or ""
  file:close()
  self.path = path
  self.title = self.title or common.basename(path)
  self:set_text(text)
  return true
end

---@return string
function MarkdownView:get_name()
  if self.path then
    return common.basename(self.path) .. " Preview"
  end
  return (self.title or "Markdown") .. " Preview"
end

---Builds and caches the fonts used by the markdown renderer.
---@return table
function MarkdownView:get_font_cache()
  if not self.font_cache then
    local sizes = {
      30 * SCALE,
      24 * SCALE,
      20 * SCALE,
      18 * SCALE,
      16 * SCALE,
      15 * SCALE
    }
    self.font_cache = {
      body = make_fontset(style.font),
      quote = make_fontset(style.font),
      code = style.code_font,
      heading = {}
    }
    for i, size in ipairs(sizes) do
      self.font_cache.heading[i] = make_fontset(style.font:copy(size, { bold = true }))
    end
  end
  return self.font_cache
end

---Loads an image entry from a local file path.
---@param entry table
---@param path string
function MarkdownView:load_image_from_path(entry, path)
  local image, errmsg = canvas.load_image(path)
  if not image then
    entry.status = "error"
    entry.errmsg = errmsg or "image could not be loaded"
    return
  end

  local _, image_type = ImageView.is_supported(path)
  entry.status = "ready"
  entry.path = path
  entry.type = image_type
  entry.errmsg = nil
  entry.image = image
  entry.image_scaled = nil
  entry.scaled_width = nil
  entry.scaled_height = nil
end

---Starts downloading a remote image used by the markdown document.
---@param entry table
function MarkdownView:start_remote_image_download(entry)
  http = http or require "core.http"
  local cache_path = get_image_cache_path(entry.url)
  entry.status = "loading"
  entry.path = cache_path

  http.download(entry.url, {
    directory = IMAGE_CACHE_DIR,
    filename = common.basename(cache_path),
    on_done = function(ok, err, filename)
      if ok and filename then
        self:load_image_from_path(entry, filename)
      else
        entry.status = "error"
        entry.errmsg = err or "image download failed"
      end
      self:invalidate_layout()
    end
  })
end

---Returns an image cache entry for the given markdown image block.
---@param block table
---@return table
function MarkdownView:ensure_image_entry(block)
  local entry = self.image_cache[block.url]
  if entry then
    return entry
  end

  entry = {
    alt = block.alt,
    url = block.url,
    status = "idle"
  }
  self.image_cache[block.url] = entry

  local project_target = self:resolve_project_link(block.url)
  if project_target then
    self:load_image_from_path(entry, project_target)
    return entry
  end

  if block.url:match("^https?://") then
    local cache_path = get_image_cache_path(block.url)
    if system.get_file_info(cache_path) then
      self:load_image_from_path(entry, cache_path)
    else
      self:start_remote_image_download(entry)
    end
    return entry
  end

  entry.status = "error"
  entry.errmsg = "unsupported image source"
  return entry
end

---Returns a scaled canvas for an image entry constrained to the given width.
---@param entry table
---@param max_width number
---@return canvas? image
---@return number? width
---@return number? height
function MarkdownView:get_scaled_image(entry, max_width)
  if entry.status ~= "ready" or not entry.image then
    return nil
  end

  local image_width, image_height = entry.image:get_size()
  local scale = image_width > max_width and (max_width / image_width) or 1
  local scaled_width = math.max(math.floor(image_width * scale), 1)
  local scaled_height = math.max(math.floor(image_height * scale), 1)

  if
    entry.image_scaled
    and entry.scaled_width == scaled_width
    and entry.scaled_height == scaled_height
  then
    return entry.image_scaled, scaled_width, scaled_height
  end

  if scale == 1 then
    entry.image_scaled = entry.image
  elseif entry.type == "svg" then
    entry.image_scaled = canvas.load_svg_image(entry.path, scaled_width, scaled_height)
  else
    entry.image_scaled = entry.image:scaled(scaled_width, scaled_height, "nearest")
  end

  entry.scaled_width = scaled_width
  entry.scaled_height = scaled_height
  return entry.image_scaled, scaled_width, scaled_height
end

---Builds the render command list for the current view width.
---@return table
function MarkdownView:ensure_layout()
  local width = math.max(self.size.x - style.padding.x * 2, 1)
  if self.layout and self.layout.width == width then
    return self.layout
  end

  local fonts = self:get_font_cache()
  local accent_color = COLOR_ACCENT
  local commands = {}
  local anchors = {}
  local y, content_width = render_blocks(self, commands, 0, self.blocks, width, 0, fonts, accent_color, anchors)

  self.layout = {
    width = width,
    height = y > 0 and (y - BLOCK_SPACING) or 0,
    content_width = content_width,
    commands = commands,
    anchors = anchors
  }

  return self.layout
end

---@return number
function MarkdownView:get_scrollable_size()
  local layout = self:ensure_layout()
  return layout.height + style.padding.y * 2
end

---@return number
function MarkdownView:get_h_scrollable_size()
  local layout = self:ensure_layout()
  return layout.content_width + style.padding.x * 2
end

---Clears cached font and layout data after a scale change.
function MarkdownView:on_scale_change()
  self.font_cache = nil
  self:invalidate_layout()
end

---Returns the URL under the given mouse position, if any.
---@param x number
---@param y number
---@return string?
function MarkdownView:get_link_at(x, y)
  local layout = self:ensure_layout()
  local ox, oy = self:get_content_offset()
  local start_x = ox + style.padding.x
  local start_y = oy + style.padding.y

  for _, command in ipairs(layout.commands) do
    if command.type == "image" and command.link_url then
      local rx = start_x + command.x
      local ry = start_y + command.y
      if x >= rx and y >= ry and x < rx + command.width and y < ry + command.height then
        return command.link_url
      end
    end
    if command.links then
      for _, link in ipairs(command.links) do
        local rx = start_x + link.x
        local ry = start_y + link.y
        if x >= rx and y >= ry and x < rx + link.width and y < ry + link.height then
          return link.url
        end
      end
    end
  end
end

---Resolves a markdown link to a project-local absolute path when possible.
---@param url string
---@return string?
function MarkdownView:resolve_project_link(url)
  local target = url:match("^[^#?]+")
  if not target or target == "" then
    return nil
  end

  if not common.is_absolute_path(target) and target:match("^[%a][%w+.-]*:") then
    return nil
  end

  local abs_target
  if common.is_absolute_path(target) then
    abs_target = common.normalize_path(target)
  else
    local base_dir = self.path and common.dirname(self.path)
    if not base_dir then
      local project = core.current_project(self.path)
      base_dir = project and project.path or system.absolute_path(".")
    end
    abs_target = system.absolute_path(base_dir .. PATHSEP .. target)
      or common.normalize_path(base_dir .. PATHSEP .. target)
  end

  if not abs_target then
    return nil
  end

  local project = core.current_project(self.path or abs_target)
  if not (project and project.path) then
    return nil
  end

  if not common.path_belongs_to(abs_target, project.path) then
    return nil
  end

  local file_info = system.get_file_info(abs_target)
  if not file_info or file_info.type ~= "file" then
    return nil
  end

  return abs_target
end

---Opens a markdown link target, handling anchors, local files and external URLs.
---@param url string
function MarkdownView:open_link(url)
  if url:sub(1, 1) == "#" then
    local layout = self:ensure_layout()
    local anchor = layout.anchors and layout.anchors[url:sub(2)]
    if anchor then
      self.scroll.to.y = anchor
      self.scroll.y = anchor
    end
    return
  end

  local project_target = self:resolve_project_link(url)
  if project_target then
    if MarkdownView.is_supported(project_target) then
      core.open_markdown(project_target)
    else
      core.open_file(project_target)
    end
  else
    common.open_in_system(url)
  end
end

---Updates hover state and status-bar tooltip for links.
---@param url string?
function MarkdownView:set_hovered_link(url)
  if self.hovered_link_url == url then
    return
  end

  self.hovered_link_url = url
  if url then
    core.status_view:show_tooltip("Open " .. url)
  else
    core.status_view:remove_tooltip()
  end
end

---@param button string
---@param x number
---@param y number
---@param clicks integer
---@return boolean?
function MarkdownView:on_mouse_pressed(button, x, y, clicks)
  if MarkdownView.super.on_mouse_pressed(self, button, x, y, clicks) then
    return true
  end

  if button == "left" then
    local url = self:get_link_at(x, y)
    if url then
      self:open_link(url)
      return true
    end
  end
end

---@param x number
---@param y number
---@param dx number
---@param dy number
---@return boolean?
function MarkdownView:on_mouse_moved(x, y, dx, dy)
  if MarkdownView.super.on_mouse_moved(self, x, y, dx, dy) then
    return true
  end
  local url = self:get_link_at(x, y)
  self:set_hovered_link(url)
  self.cursor = url and "hand" or "arrow"
end

---Clears hover state when the mouse leaves the preview.
function MarkdownView:on_mouse_left()
  MarkdownView.super.on_mouse_left(self)
  self:set_hovered_link(nil)
  self.cursor = "arrow"
end

---Refreshes the preview when the bound document changes.
function MarkdownView:update()
  if self.doc and self.doc:get_change_id() ~= self.last_doc_change_id then
    self:refresh_from_doc()
  end
  MarkdownView.super.update(self)
end

---Draws the markdown preview contents and scrollbars.
function MarkdownView:draw()
  self:draw_background(style.background)

  local layout = self:ensure_layout()
  local ox, oy = self:get_content_offset()
  local clip_x, clip_y = self.position.x, self.position.y
  local clip_w, clip_h = self.size.x, self.size.y
  local start_x = ox + style.padding.x
  local start_y = oy + style.padding.y

  core.push_clip_rect(clip_x, clip_y, clip_w, clip_h)

  for _, command in ipairs(layout.commands) do
    local x = start_x + command.x
    local y = start_y + command.y
    if y + command.height >= clip_y and y <= clip_y + clip_h then
      if command.type == "rect" then
        renderer.draw_rect(x, y, command.width, command.height, resolve_color(command.color))
      elseif command.type == "checkbox" then
        local box_size = command.width
        local box_x = x
        local box_y = y + math.max(math.floor((command.height - box_size) / 2), 0)
        local checkbox_color = resolve_color(command.color)
        renderer.draw_rect(box_x, box_y, box_size, 1, checkbox_color)
        renderer.draw_rect(box_x, box_y + box_size - 1, box_size, 1, checkbox_color)
        renderer.draw_rect(box_x, box_y, 1, box_size, checkbox_color)
        renderer.draw_rect(box_x + box_size - 1, box_y, 1, box_size, checkbox_color)
        if command.checked then
          local fill = math.max(box_size - 4, 1)
          renderer.draw_rect(box_x + 2, box_y + 2, fill, fill, checkbox_color)
        end
      elseif command.type == "image" then
        renderer.draw_canvas(command.image, x, y)
      elseif command.type == "text" then
        local cursor_x = x
        local tab_offset = 0
        for _, fragment in ipairs(command.fragments) do
          if fragment.type == "image" then
            local draw_y = y + math.max(math.floor((command.height - fragment.height) / 2), 0)
            renderer.draw_canvas(fragment.image, cursor_x, draw_y)
            cursor_x = cursor_x + fragment.width
          else
            local font_height = fragment.font:get_height()
            local draw_y = y + (command.height - font_height) / 2
            if fragment.background then
              renderer.draw_rect(
                cursor_x - INLINE_CODE_PADDING_X,
                draw_y - INLINE_CODE_PADDING_Y,
                fragment.width + INLINE_CODE_PADDING_X * 2,
                font_height + INLINE_CODE_PADDING_Y * 2,
                resolve_color(fragment.background)
              )
            end
            cursor_x = renderer.draw_text(
              fragment.font,
              fragment.text,
              cursor_x,
              draw_y,
              resolve_color(fragment.color),
              command.tabbed and { tab_offset = tab_offset } or nil
            )
          end
          if command.tabbed then
            tab_offset = cursor_x - x
          end
        end
      end
    end
  end

  core.pop_clip_rect()
  self:draw_scrollbar()
end

return MarkdownView
