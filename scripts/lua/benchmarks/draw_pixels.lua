-- Compare changing RGBA uploads at 720p and 1080p. Payload preparation is
-- outside timing; full-frame timing includes command queueing and replay.
local core = require "core"
local config = require "core.config"
local json = require "core.json"
local renderer = require "renderer"
local renwindow = require "renwindow"

local frames, warmup = 200, 20
for i, arg in ipairs(ARGS or {}) do
  if arg:gsub("\\", "/"):match("benchmarks/draw_pixels%.lua$") then
    frames = math.max(1, math.floor(tonumber(ARGS[i + 1]) or frames))
    warmup = math.max(1, math.floor(tonumber(ARGS[i + 2]) or warmup))
    break
  end
end

local function color_at(x, y, phase)
  y = y % 32
  return (x * 17 + y * 29 + phase * 53) % 256,
    (x * 7 + y * 13 + phase * 37) % 256,
    (x * 3 + y * 19 + phase * 97) % 256
end

local function make_pixels(width, height, phase)
  local rows = {}
  for y = 0, 31 do
    local pixels = {}
    for x = 0, width - 1 do
      local r, g, b = color_at(x, y, phase)
      pixels[#pixels + 1] = string.char(r, g, b, 255)
    end
    rows[#rows + 1] = table.concat(pixels)
  end
  local tile = table.concat(rows)
  return tile:rep(math.floor(height / 32)) .. tile:sub(1, height % 32 * width * 4)
end

local function summarize(times)
  local sorted, total = {}, 0
  for i, time in ipairs(times) do sorted[i], total = time, total + time end
  table.sort(sorted)
  return {avg_ms = total / #times, p50_ms = sorted[math.ceil(#sorted * .5)],
    p95_ms = sorted[math.ceil(#sorted * .95)], min_ms = sorted[1], max_ms = sorted[#sorted]}
end

local function print_summary(label, summary)
  print(string.format("%-24s avg %.3fms | p50 %.3fms | p95 %.3fms | min %.3fms | max %.3fms",
    label, summary.avg_ms, summary.p50_ms, summary.p95_ms, summary.min_ms, summary.max_ms))
end

local function measure(width, height, name)
  local window = renwindow.create("RGBA Pixel Upload Benchmark", width, height)
  window:set_vsync(false)
  local info = window:get_renderer_info()
  local expected = os.getenv("PRAGTICAL_RENDERER")
  assert(not expected or info.backend == expected, "requested backend fell back")
  local w, h = window:get_size()
  assert(w == width and h == height, "pixel benchmark target size changed")
  print(string.format("%s: %dx%d, backend=%s, frames=%d, warmup=%d",
    name, width, height, info.backend, frames, warmup))

  -- Alternate two prebuilt, nonuniform images so cached frames cannot skip the
  -- upload. Avoid measuring string construction or codec/conversion work.
  local buffers = {make_pixels(width, height, 0), make_pixels(width, height, 1)}
  collectgarbage("collect")
  local function draw(iteration)
    local start = system.get_time()
    renderer.begin_frame(window)
    renderer.set_clip_rect(0, 0, width, height)
    renderer.draw_pixels(buffers[iteration % 2 + 1], 0, 0, width, height)
    local replay_start = system.get_time()
    renderer.end_frame()
    local finish = system.get_time()
    return (finish - start) * 1000, (finish - replay_start) * 1000
  end
  for i = 1, warmup do draw(i - warmup) end
  local full, replay = {}, {}
  for i = 1, frames do full[i], replay[i] = draw(i) end

  -- Validate deterministic RGB samples after timing, including the final row.
  for _, point in ipairs {{0, 0}, {math.floor(width / 2), math.floor(height / 2)}, {width - 1, height - 1}} do
    local x, y = point[1], point[2]
    local capture = renderer.to_canvas(window, x, y, 1, 1)
    local r, g, b, a = capture:get_pixels(0, 0, 1, 1):byte(1, 4)
    local er, eg, eb = color_at(x, y, frames % 2)
    assert(r == er and g == eg and b == eb and a == 255, "draw_pixels readback mismatch")
  end
  local result = {name = name, backend = info.backend, device = info.device,
    width = width, height = height, frames = frames, warmup = warmup,
    replay = summarize(replay), full = summarize(full)}
  print_summary("pixels " .. name .. " replay", result.replay)
  print_summary("pixels " .. name .. " full", result.full)
  return result
end

config.draw_stats = false
config.fps = 1000
print("Usage: pragtical run scripts/lua/benchmarks/draw_pixels.lua [frames] [warmup]")
print("Times are CPU-observed wall times, not GPU timestamps. Full = queue + replay.")
local results = {measure(1280, 720, "720p"), measure(1920, 1080, "1080p")}
local output = os.getenv("PRAGTICAL_PIXEL_BENCH_OUTPUT")
if output then
  local file = assert(io.open(output, "w"))
  file:write(json.encode(results)); file:close()
end
os.exit(0)
