local core = require "core"
local config = require "core.config"
local style = require "core.style"
local renwindow = require "renwindow"

local bench_window

local cube = {
  {-1, -1, -1}, { 1, -1, -1}, { 1,  1, -1}, {-1,  1, -1},
  {-1, -1,  1}, { 1, -1,  1}, { 1,  1,  1}, {-1,  1,  1}
}

local edges = {
  {1, 2}, {2, 3}, {3, 4}, {4, 1},
  {5, 6}, {6, 7}, {7, 8}, {8, 5},
  {1, 5}, {2, 6}, {3, 7}, {4, 8}
}

local function find_script_argument()
  if not ARGS then return nil end
  for i = 1, #ARGS do
    local value = ARGS[i]
    if value and value:match("scripts/lua/benchmarks/rect_cube%.lua$") then
      return i
    end
  end
end

local function parse_inputs()
  local script_idx = find_script_argument()
  local frames = 240
  local cubes = 1
  local thickness = math.max(1, math.floor(3 * SCALE))

  if script_idx and ARGS then
    local frames_arg = tonumber(ARGS[script_idx + 1])
    local cubes_arg = tonumber(ARGS[script_idx + 2])
    local thickness_arg = tonumber(ARGS[script_idx + 3])
    if frames_arg and frames_arg >= 1 then frames = math.floor(frames_arg) end
    if cubes_arg and cubes_arg >= 1 then cubes = math.floor(cubes_arg) end
    if thickness_arg and thickness_arg >= 1 then thickness = math.floor(thickness_arg) end
  end

  return frames, cubes, thickness
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

local function atan2(y, x)
  if x > 0 then
    return math.atan(y / x)
  elseif x < 0 then
    return math.atan(y / x) + (y >= 0 and math.pi or -math.pi)
  elseif y > 0 then
    return math.pi / 2
  elseif y < 0 then
    return -math.pi / 2
  end
  return 0
end

local function rotate(x, y, z, angle_x, angle_y, angle_z)
  local sinx, cosx = math.sin(angle_x), math.cos(angle_x)
  y, z = y * cosx - z * sinx, y * sinx + z * cosx

  local siny, cosy = math.sin(angle_y), math.cos(angle_y)
  x, z = x * cosy + z * siny, -x * siny + z * cosy

  local sinz, cosz = math.sin(angle_z), math.cos(angle_z)
  x, y = x * cosz - y * sinz, x * sinz + y * cosz

  return x, y, z
end

local function project(x, y, z, cx, cy, scale)
  local fov = 3
  local depth = fov / (fov + z)
  return cx + x * depth * scale, cy + y * depth * scale
end

local function draw_line(x1, y1, x2, y2, thickness, color)
  local dx, dy = x2 - x1, y2 - y1
  local length = math.sqrt(dx * dx + dy * dy)
  local angle = math.atan2 and math.atan2(dy, dx) or atan2(dy, dx)
  local cos_a = math.cos(angle)
  local sin_a = math.sin(angle)
  local half = math.floor(thickness / 2)
  local top = math.ceil(thickness / 2) - 1

  for i = 0, length do
    local px = x1 + cos_a * i
    local py = y1 + sin_a * i

    for t = -half, top do
      local offset_x = -sin_a * t
      local offset_y = cos_a * t
      renderer.draw_rect(px + offset_x, py + offset_y, 1, 1, color)
    end
  end
end

local function draw_cube(x, y, w, h, color, thickness, frame, phase)
  local scale = math.min(w, h) / 4
  local angle_x = frame * 0.010 + phase
  local angle_y = frame * 0.015 + phase * 0.5
  local angle_z = frame * 0.020 + phase * 0.25
  local points = {}

  for i, v in ipairs(cube) do
    local rx, ry, rz = rotate(v[1], v[2], v[3], angle_x, angle_y, angle_z)
    local sx, sy = project(rx, ry, rz, x, y, scale)
    points[i] = {sx, sy}
  end

  for _, edge in ipairs(edges) do
    local a = points[edge[1]]
    local b = points[edge[2]]
    draw_line(a[1], a[2], b[1], b[2], thickness, color)
  end
end

local function draw_frame(frame, cube_count, thickness)
  local w, h = bench_window:get_size()
  local bg = style.background or {30, 30, 30, 255}
  local color = style.syntax and style.syntax.string or {180, 220, 120, 255}
  local columns = math.ceil(math.sqrt(cube_count))
  local rows = math.ceil(cube_count / columns)
  local cell_w = w / columns
  local cell_h = h / rows

  renderer.begin_frame(bench_window)
  renderer.set_clip_rect(0, 0, w, h)
  renderer.draw_rect(0, 0, w, h, bg)

  for i = 1, cube_count do
    local col = (i - 1) % columns
    local row = math.floor((i - 1) / columns)
    local x = col * cell_w + cell_w / 2
    local y = row * cell_h + cell_h / 2
    draw_cube(x, y, cell_w * 0.72, cell_h * 0.72, color, thickness, frame, i * 0.37)
  end

  renderer.end_frame()
end

local frames, cube_count, thickness = parse_inputs()
config.draw_stats = false
config.fps = 1000
bench_window = core.window or renwindow.create("Rect Cube Benchmark", 1280, 800)

print("Usage: ./scripts/run-local <build-dir> run scripts/lua/benchmarks/rect_cube.lua")
print("       [frames] [cube_count] [thickness]")
print(string.format("Frames: %d", frames))
print(string.format("Cubes: %d", cube_count))
print(string.format("Thickness: %d", thickness))
print(string.format("Window: %dx%d", bench_window:get_size()))

local warmup = math.min(30, math.max(5, math.floor(frames / 8)))
for i = 1, warmup do
  draw_frame(i, cube_count, thickness)
end

local times = {}
for i = 1, frames do
  local start = system.get_time()
  draw_frame(i, cube_count, thickness)
  times[#times + 1] = system.get_time() - start
end

print_summary("rect cube frame", summarize(times))
os.exit(0)
