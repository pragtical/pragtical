-- Polygon-fill benchmark: stresses renderer.draw_poly with many filled
-- circle/ellipse rings per frame, mirroring how plugins draw vector shapes.
-- Each ring is a closed polygon whose last point repeats the first (i = 0..segments
-- inclusive) and radii range from sub-pixel-small (collinear after integer
-- rounding) to large, so it exercises the SDLGPU triangulation paths.
--
-- Usage: ./scripts/run-local <build-dir> run scripts/lua/benchmarks/poly_fill.lua [frames] [polys] [segments]

local core = require "core"
local config = require "core.config"
local style = require "core.style"
local renwindow = require "renwindow"
local bench_window

local function find_script_argument()
  if not ARGS then return nil end
  for i = 1, #ARGS do
    local value = ARGS[i]
    if value and value:match("scripts/lua/benchmarks/poly_fill%.lua$") then
      return i
    end
  end
end

local function parse_inputs()
  local script_idx = find_script_argument()
  local frames = 240
  local polys = 400
  local segments = 32

  if script_idx and ARGS then
    local frames_arg = tonumber(ARGS[script_idx + 1])
    local polys_arg = tonumber(ARGS[script_idx + 2])
    local segments_arg = tonumber(ARGS[script_idx + 3])
    if frames_arg and frames_arg >= 1 then frames = math.floor(frames_arg) end
    if polys_arg and polys_arg >= 1 then polys = math.floor(polys_arg) end
    if segments_arg and segments_arg >= 3 then segments = math.floor(segments_arg) end
  end

  return frames, polys, segments
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

-- Closed ring with a duplicated last vertex (i = 0..segments), matching the
-- common plugin pattern that the triangulator must handle.
local function make_circle_poly(cx, cy, rx, ry, segments)
  local poly = {}
  for i = 0, segments do
    local theta = (2 * math.pi * i) / segments
    poly[#poly + 1] = { cx + rx * math.cos(theta), cy + ry * math.sin(theta) }
  end
  return poly
end

local function draw_frame(frame, polys, segments)
  local w, h = bench_window:get_size()
  local bg = style.background or { 30, 30, 30, 255 }

  renderer.begin_frame(bench_window)
  renderer.set_clip_rect(0, 0, w, h)
  renderer.draw_rect(0, 0, w, h, bg)

  local phase = frame * 0.05
  for i = 1, polys do
    -- deterministic placement so both backends do identical work
    local fx = (i * 73 % 1000) / 1000
    local fy = (i * 149 % 1000) / 1000
    local cx = math.floor(fx * (w - 20)) + 10 + math.sin(phase + i) * 6
    local cy = math.floor(fy * (h - 20)) + 10 + math.cos(phase + i) * 6
    -- mix sub-pixel-small, medium and large radii
    local base = 2 + (i % 30)
    local rx = base
    local ry = base * (0.6 + ((i % 5) * 0.12))
    local seg = segments
    local a = 60 + (i % 7) * 24
    renderer.draw_poly(
      make_circle_poly(cx, cy, rx, ry, seg),
      { 130, 70, 255, a }
    )
  end

  renderer.end_frame(bench_window)
end

local frames, polys, segments = parse_inputs()
config.draw_stats = false
config.fps = 1000
bench_window = core.window or renwindow.create("Polygon Fill Benchmark", 1280, 800)

print("Usage: ./scripts/run-local <build-dir> run scripts/lua/benchmarks/poly_fill.lua [frames] [polys] [segments]")
print(string.format("Frames: %d", frames))
print(string.format("Polygons/frame: %d", polys))
print(string.format("Segments: %d", segments))
print(string.format("Window: %dx%d", bench_window:get_size()))

local warmup = math.min(30, math.max(5, math.floor(frames / 8)))
for i = 1, warmup do
  draw_frame(i, polys, segments)
end

local times = {}
for i = 1, frames do
  local start = system.get_time()
  draw_frame(i, polys, segments)
  times[#times + 1] = system.get_time() - start
end

print_summary("draw polys", summarize(times))
os.exit(0)
