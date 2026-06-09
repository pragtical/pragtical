local core = require "core"
local config = require "core.config"
local renwindow = require "renwindow"

local text = "if a == b and c !== d then return x => y -> z <= w >= q ffi === != end"
local font_path = DATADIR .. PATHSEP .. "fonts" .. PATHSEP .. "JetBrainsMono-Regular.ttf"
local size = 15 * SCALE

local function find_script_argument()
  if not ARGS then return nil end
  for i = 1, #ARGS do
    local value = ARGS[i]
    if value and value:match("scripts/lua/benchmarks/ligatures%.lua$") then
      return i
    end
  end
end

local function parse_inputs()
  local script_idx = find_script_argument()
  local width_iterations = 200000
  local draw_iterations = 5000

  if script_idx and ARGS then
    local width_arg = tonumber(ARGS[script_idx + 1])
    local draw_arg = tonumber(ARGS[script_idx + 2])
    if width_arg and width_arg >= 1 then
      width_iterations = math.floor(width_arg)
    end
    if draw_arg and draw_arg >= 1 then
      draw_iterations = math.floor(draw_arg)
    end
  end

  return width_iterations, draw_iterations
end

local function bench(label, fn)
  collectgarbage("collect")
  collectgarbage("collect")
  local start = system.get_time()
  local result = fn()
  local elapsed = system.get_time() - start
  print(string.format("%-28s %.6f s%s", label, elapsed, result and ("  " .. result) or ""))
  return elapsed
end

local width_iterations, draw_iterations = parse_inputs()
config.draw_stats = false
config.fps = 1000
local bench_window = core.window or renwindow.create("Ligature Benchmark", 1200, 800)
local font_off = renderer.font.load(font_path, size, { ligatures = false, antialiasing = "grayscale" })
local font_on = renderer.font.load(font_path, size, { ligatures = true, antialiasing = "grayscale" })
local canvas_width = 1200 * SCALE
local canvas_height = 800 * SCALE
local preview_canvas

local function present_preview(label)
  local width, height = bench_window:get_size()
  renderer.begin_frame(bench_window)
  renderer.set_clip_rect(0, 0, width, height)
  renderer.draw_rect(0, 0, width, height, {18, 20, 24, 255}, true)
  renderer.draw_text(font_off, "Ligature benchmark: " .. label, 14, 12, {230, 230, 235, 255})
  if preview_canvas then
    renderer.draw_canvas(preview_canvas, 0, font_off:get_height() + 24)
  end
  renderer.end_frame()
end

print("Usage: ./scripts/run-local build run scripts/lua/benchmarks/ligatures.lua [width_iterations] [draw_iterations]")
print(string.format("Font: %s", font_path))
print(string.format("Text: %s", text))
print(string.format("Width iterations: %d", width_iterations))
print(string.format("Draw iterations: %d", draw_iterations))
print(string.format("Window: %dx%d", bench_window:get_size()))
print("")

present_preview("starting")
system.sleep(0.1)

local width_off = bench("width ligatures off", function()
  local x = 0
  for _ = 1, width_iterations do
    x = x + font_off:get_width(text)
  end
  return string.format("checksum=%.2f", x)
end)

local width_on = bench("width ligatures on", function()
  local x = 0
  for _ = 1, width_iterations do
    x = x + font_on:get_width(text)
  end
  return string.format("checksum=%.2f", x)
end)

local draw_off = bench("draw ligatures off", function()
  local c = canvas.new(canvas_width, canvas_height, {0, 0, 0, 255}, true)
  local y = 0
  for _ = 1, draw_iterations do
    c:draw_text(font_off, text, 0, y, {255, 255, 255, 255})
    y = (y + font_off:get_height()) % (canvas_height - font_off:get_height())
  end
  c:render()
  preview_canvas = c
  return string.format("bytes=%d", #c:get_pixels(0, 0, 1, 1))
end)
present_preview("draw ligatures off")

local draw_on = bench("draw ligatures on", function()
  local c = canvas.new(canvas_width, canvas_height, {0, 0, 0, 255}, true)
  local y = 0
  for _ = 1, draw_iterations do
    c:draw_text(font_on, text, 0, y, {255, 255, 255, 255})
    y = (y + font_on:get_height()) % (canvas_height - font_on:get_height())
  end
  c:render()
  preview_canvas = c
  return string.format("bytes=%d", #c:get_pixels(0, 0, 1, 1))
end)
present_preview("draw ligatures on")
system.sleep(0.1)

print("")
print(string.format("width on/off ratio: %.2fx", width_on / width_off))
print(string.format("draw on/off ratio:  %.2fx", draw_on / draw_off))

os.exit(0)
