-- Compare cache work with static, sparse and fully changing frames.
-- Run against each binary/backend with an isolated profile and identical fonts.
local core = require "core"
local renderer = require "renderer"
local renwindow = require "renwindow"
local json = require "core.json"

local frames = tonumber(os.getenv("PRAGTICAL_CACHE_BENCH_FRAMES")) or 180
local output = os.getenv("PRAGTICAL_CACHE_BENCH_OUTPUT")
local capture_dir = os.getenv("PRAGTICAL_CACHE_BENCH_CAPTURE_DIR")
local width, height = 1600, 1000
local font = renderer.font.load(DATADIR .. "/fonts/JetBrainsMono-Regular.ttf", 14,
  {antialiasing = "grayscale", ligatures = true})
local background = {25, 25, 25, 255}
local foreground = {190, 190, 190, 255}
local accent = {100, 170, 240, 255}

---Draw the same dense text scene with the selected kind of damage.
---@param window renwindow
---@param mode string
---@param iteration integer
local function draw(window, mode, iteration)
  renderer.begin_frame(window)
  renderer.set_clip_rect(0, 0, width, height)
  renderer.draw_rect(0, 0, width, height, background)
  local scrolling = mode == "scroll"
  local color = mode == "changing" and {180 + iteration % 2 * 10, 190, 190, 255} or foreground
  for row = 0, 44 do
    for col = 0, 39 do
      renderer.draw_text(font, "word", col * 39 + 2,
        row * 21 + 2 - (scrolling and iteration % 21 or 0), color)
    end
  end
  if mode == "caret" then
    renderer.draw_rect(10, 28, 1, 10, iteration % 2 == 0 and accent or background)
  elseif mode == "L_damage" then
    local shade = iteration % 2 == 0 and accent or foreground
    for x = 10, width - 1, 60 do renderer.draw_rect(x, 10, 1, 1, shade) end
    for y = 70, height - 1, 60 do renderer.draw_rect(10, y, 1, 1, shade) end
  elseif mode == "clip_only" then
    renderer.set_clip_rect(60 + iteration % 2, 60, 300, 300)
    renderer.set_clip_rect(0, 0, width, height)
  end
  renderer.end_frame()
end

---Measure one warmed workload using total frame wall time.
---@param mode string
---@return table
local function measure(mode)
  local window = renwindow.create("Rendering cache benchmark", width, height)
  window:set_vsync(false)
  for i = 1, 20 do draw(window, mode, i) end
  local times, total = {}, 0
  for i = 1, frames do
    local start = system.get_time()
    draw(window, mode, i)
    local elapsed = (system.get_time() - start) * 1000
    times[#times + 1], total = elapsed, total + elapsed
  end
  table.sort(times)
  -- Capture a separate deterministic sequence after timing. This checks
  -- retained-frame correctness without adding readback cost to samples.
  if capture_dir then
    for i = 1, 22 do
      draw(window, mode, i)
      if i == 1 or i == 2 or i == 11 or i == 22 then
        local capture = renderer.to_canvas(window, 0, 0, width, height)
        assert(capture:save_image(string.format("%s/%s-%02d.png", capture_dir, mode, i)))
      end
    end
  end
  return {name = mode, frames = frames, avg_ms = total / frames,
    p50_ms = times[math.ceil(frames * .5)], p95_ms = times[math.ceil(frames * .95)]}
end

core.add_thread(function()
  local ok, err = xpcall(function()
    renderer.show_debug(false)
    local info = core.window:get_renderer_info()
    local result = {backend = info.backend, device = info.device,
      width = width, height = height, workloads = {}}
    for _, mode in ipairs {"static", "caret", "clip_only", "L_damage", "scroll", "changing"} do
      local row = measure(mode)
      result.workloads[#result.workloads + 1] = row
      print(string.format("%-12s avg %.3f ms | p50 %.3f ms | p95 %.3f ms",
        row.name, row.avg_ms, row.p50_ms, row.p95_ms))
    end
    if output then
      local file = assert(io.open(output, "w"))
      file:write(json.encode(result)); file:close()
    end
  end, debug.traceback)
  if not ok then print(err) end
  core.quit(true, ok and 0 or 1)
end)
