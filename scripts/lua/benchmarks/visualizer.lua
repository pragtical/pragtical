-- Usage: ./scripts/run-local build run scripts/lua/benchmarks/visualizer.lua [frames]
local dir = debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])")
local fixture = dofile(dir .. "../fixtures/visualizer.lua")
local frames = 120
for i, arg in ipairs(ARGS) do
  if arg:match("benchmarks/visualizer%.lua$") then
    frames = math.max(1, math.floor(tonumber(ARGS[i + 1]) or frames))
    break
  end
end

local width, height = 960, 540
local window = renwindow.create("Polygon Visualizer Benchmark", width, height)
window:set_vsync(false)
local info = window:get_renderer_info()
print(string.format("Backend: %s; frames: %d; window: %dx%d", info.backend, frames, width, height))
local expected = os.getenv("PRAGTICAL_RENDERER")
assert(not expected or info.backend == expected, "requested backend fell back")

for _, target in ipairs { "window", "canvas" } do
  for _, name in ipairs(fixture.names) do
    local image = target == "canvas" and canvas.new(fixture.width, fixture.height, fixture.background)
    local function draw_poly(poly, color)
      if image then image:draw_poly(poly, color) else renderer.draw_poly(poly, color) end
    end
    local function draw(frame)
      renderer.begin_frame(window)
      renderer.set_clip_rect(0, 0, width, height)
      renderer.draw_rect(0, 0, width, height, fixture.background, true)
      if image then image:draw_rect(0, 0, fixture.width, fixture.height, fixture.background, true) end
      fixture.draw(name, frame / 60, draw_poly)
      if image then
        image:render()
        -- audiovisu scales its offscreen visualization before presenting it.
        renderer.draw_canvas(image:scaled(width, height, "linear"), 0, 0)
      end
      renderer.end_frame()
    end

    for frame = 1, 20 do draw(frame) end
    local times, total = {}, 0
    for frame = 1, frames do
      local start = system.get_time()
      draw(frame)
      local elapsed = (system.get_time() - start) * 1000
      times[frame], total = elapsed, total + elapsed
    end
    table.sort(times)
    print(string.format("%-18s avg %.3fms | p50 %.3fms | p95 %.3fms | min %.3fms | max %.3fms",
      target .. " " .. name, total / frames, times[math.ceil(frames * 0.5)],
      times[math.ceil(frames * 0.95)], times[1], times[frames]))
  end
end
os.exit(0)
