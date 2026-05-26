local Doc = require "core.doc"
local DocView = require "core.docview"
local style = require "core.style"
local tokenizer = require "core.tokenizer"

local function find_script_argument()
  if not ARGS then return nil end
  for i = 1, #ARGS do
    local value = ARGS[i]
    if value and value:match("scripts/lua/benchmarks/docview_long_lines%.lua$") then
      return i
    end
  end
end

local function parse_inputs()
  local script_idx = find_script_argument()
  if not script_idx or not ARGS or not ARGS[script_idx + 1] then
    return nil, 20, 100
  end

  local path = ARGS[script_idx + 1]
  local iterations = tonumber(ARGS[script_idx + 2]) or 20
  local draw_iterations = tonumber(ARGS[script_idx + 3]) or 100
  return path, math.max(1, math.floor(iterations)), math.max(1, math.floor(draw_iterations))
end

local function print_usage()
  print("Usage: ./scripts/run-local build run scripts/lua/benchmarks/docview_long_lines.lua /path/to/file [iterations] [draw_iterations]")
end

local function bench(label, iterations, fn)
  collectgarbage("collect")
  collectgarbage("collect")

  local checksum
  local start = system.get_time()
  for _ = 1, iterations do
    checksum = fn()
  end
  local elapsed = (system.get_time() - start) * 1000
  print(string.format("%-28s %9.3f ms total  %8.3f ms/iter  checksum=%s",
    label, elapsed, elapsed / iterations, tostring(checksum)))
  return elapsed
end

local function original_draw_line_text(view, line, x, y)
  local default_font = view:get_font()
  local tx, ty = x, y + view:get_line_text_y_offset()
  local last_token = nil
  local tokens = view.doc.highlighter:get_line(line).tokens
  local tokens_count = #tokens
  if tokens_count > 0 and string.sub(tokens[tokens_count], -1) == "\n" then
    last_token = tokens_count - 1
  end
  local _, indent_size = view.doc:get_indent_info()
  local start_tx = tx

  for tidx, type, text in view.doc.highlighter:each_token(line) do
    local color = style.syntax[type] or style.syntax["normal"]
    local font = style.syntax_fonts[type] or default_font
    if font ~= default_font then font:set_tab_size(indent_size) end
    if tidx == last_token then text = text:sub(1, -2) end
    tx = renderer.draw_text(font, text, tx, ty, color, {tab_offset = tx - start_tx})
    if tx > view.position.x + view.size.x then break end
  end
  return view:get_line_height()
end

local file_arg, iterations, draw_iterations = parse_inputs()
if not file_arg then
  print_usage()
  os.exit(1)
end

local abs_path = system.absolute_path(file_arg)
local info = system.get_file_info(abs_path)
if not info or info.type ~= "file" then
  print(string.format("File not found: %s", tostring(file_arg)))
  print_usage()
  os.exit(1)
end

local doc = Doc(file_arg, abs_path, false)
local view = DocView(doc)
view.position.x = 0
view.position.y = 0
view.size.x = 1200 * SCALE
view.size.y = 800 * SCALE

local longest_line = 1
for i = 2, #doc.lines do
  if #doc.lines[i] > #doc.lines[longest_line] then
    longest_line = i
  end
end

local x, y = view:get_line_screen_position(longest_line)
local line_len = #doc.lines[longest_line]
local draw_bytes = 0
local real_draw_text = renderer.draw_text

doc.highlighter.get_line = function(_, idx)
  return { text = doc.lines[idx], tokens = { "normal", doc.lines[idx] } }
end

doc.highlighter.each_token = function(self, idx, scol)
  return tokenizer.each_token(self:get_line(idx).tokens, scol)
end

renderer.draw_text = function(font, text, tx, ty, color, options)
  draw_bytes = draw_bytes + #text
  return tx + font:get_width(text, options)
end

local function benchmark_draw(label, draw_fn)
  draw_bytes = 0
  local elapsed = bench(label, draw_iterations, function()
    draw_fn(view, longest_line, x, y)
    return draw_bytes
  end)
  return elapsed, draw_bytes
end

print_usage()
print(string.format("File: %s", abs_path))
print(string.format("Longest line: %d (%d bytes)", longest_line, line_len))
print(string.format("Iterations: %d", iterations))
print(string.format("Draw iterations: %d", draw_iterations))
print("Highlighter: plain-token override")
print("")

bench("get_visible_cols_range", iterations, function()
  local col1, col2 = view:get_visible_cols_range(longest_line, 2000)
  return string.format("%d:%d", col1, col2)
end)

bench("get_col_x_offset", iterations, function()
  return math.floor(view:get_col_x_offset(longest_line, math.max(1, math.floor(line_len / 2))))
end)

local half_width = view:get_col_x_offset(longest_line, math.max(1, math.floor(line_len / 2)))
bench("get_x_offset_col", iterations, function()
  return view:get_x_offset_col(longest_line, half_width)
end)

local original_elapsed = benchmark_draw("draw original", original_draw_line_text)
local optimized_elapsed = benchmark_draw("draw optimized", function(v, line, dx, dy)
  return v:draw_line_text(line, dx, dy)
end)

renderer.draw_text = real_draw_text

print("")
print(string.format("draw speedup: %.2fx", original_elapsed / optimized_elapsed))

os.exit(0)
