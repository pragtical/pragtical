local core = require "core"
local config = require "core.config"
local style = require "core.style"
local renwindow = require "renwindow"
local bench_window

local function find_script_argument()
  if not ARGS then return nil end
  for i = 1, #ARGS do
    local value = ARGS[i]
    if value and value:match("scripts/lua/benchmarks/renderer_backend%.lua$") then
      return i
    end
  end
end

local function parse_inputs()
  local script_idx = find_script_argument()
  local frames = 240
  local text_rows = 90
  local canvas_count = 24

  if script_idx and ARGS then
    local frames_arg = tonumber(ARGS[script_idx + 1])
    local rows_arg = tonumber(ARGS[script_idx + 2])
    local canvases_arg = tonumber(ARGS[script_idx + 3])
    if frames_arg and frames_arg >= 1 then frames = math.floor(frames_arg) end
    if rows_arg and rows_arg >= 1 then text_rows = math.floor(rows_arg) end
    if canvases_arg and canvases_arg >= 0 then canvas_count = math.floor(canvases_arg) end
  end

  return frames, text_rows, canvas_count
end

local function percentile(values, pct)
  local index = math.max(1, math.min(#values, math.ceil(#values * pct)))
  return values[index]
end

local function summarize(times)
  table.sort(times)
  local total = 0
  for _, value in ipairs(times) do total = total + value end
  return {
    avg = total / #times,
    min = times[1],
    p50 = percentile(times, 0.50),
    p95 = percentile(times, 0.95),
    max = times[#times],
  }
end

local function print_summary(label, summary)
  print(string.format(
    "%-18s avg %.3fms | p50 %.3fms | p95 %.3fms | min %.3fms | max %.3fms",
    label,
    summary.avg * 1000,
    summary.p50 * 1000,
    summary.p95 * 1000,
    summary.min * 1000,
    summary.max * 1000
  ))
end

local function make_canvas(size)
  local c = canvas.new(size, size, {0, 0, 0, 0}, true)
  c:draw_rect(0, 0, size, size, {40, 48, 58, 230}, true)
  c:draw_rect(2, 2, size - 4, size - 4, {92, 160, 220, 180}, false)
  c:draw_rect(size / 4, size / 4, size / 2, size / 2, {255, 210, 90, 210}, false)
  c:render()
  return c
end

local function draw_frame(font, image, frame, text_rows, canvas_count)
  local w, h = bench_window:get_size()
  local line_h = font:get_height()
  local bg = style.background or {30, 30, 30, 255}
  local fg = style.text or {230, 230, 230, 255}
  local accent = style.accent or {120, 180, 255, 255}
  local dim = style.dim or {120, 120, 120, 255}
  local selection = style.selection or {70, 80, 90, 255}

  renderer.begin_frame(bench_window)
  renderer.set_clip_rect(0, 0, w, h)
  renderer.draw_rect(0, 0, w, h, bg)
  renderer.draw_rect(0, 0, w, line_h + 12, selection)

  local title = string.format("renderer backend benchmark frame %d", frame)
  renderer.draw_text(font, title, 12, 6, accent)

  local y = line_h + 18
  local sample = "local value = (index ~= nil and index <= limit) and object:method(\"text\") or fallback"
  for i = 1, text_rows do
    local color = (i % 5 == 0) and dim or fg
    renderer.draw_text(font, string.format("%04d  %s  -- %d", i, sample, frame), 12, y, color)
    y = y + line_h
    if y > h - line_h then break end
  end

  for i = 1, canvas_count do
    local x = (w - 96) - ((i - 1) % 6) * 34
    local cy = line_h + 24 + math.floor((i - 1) / 6) * 34
    renderer.draw_canvas(image, x, cy)
  end

  renderer.end_frame()
end

local frames, text_rows, canvas_count = parse_inputs()
config.draw_stats = false
config.fps = 1000
bench_window = core.window or renwindow.create("Renderer Backend Benchmark", 1280, 800)

local font_path = DATADIR .. PATHSEP .. "fonts" .. PATHSEP .. "JetBrainsMono-Regular.ttf"
local font = renderer.font.load(font_path, 15 * SCALE, { antialiasing = "grayscale", ligatures = true })
local image = make_canvas(30 * SCALE)

print("Usage: ./scripts/run-local <build-dir> run scripts/lua/benchmarks/renderer_backend.lua")
print(string.format("Frames: %d", frames))
print(string.format("Text rows: %d", text_rows))
print(string.format("Canvas draws: %d", canvas_count))
print(string.format("Window: %dx%d", bench_window:get_size()))

local warmup = math.min(30, math.max(5, math.floor(frames / 8)))
for i = 1, warmup do
  draw_frame(font, image, i, text_rows, canvas_count)
end

local times = {}
for i = 1, frames do
  local start = system.get_time()
  draw_frame(font, image, i, text_rows, canvas_count)
  times[#times + 1] = system.get_time() - start
end

print_summary("render frame", summarize(times))
os.exit(0)
