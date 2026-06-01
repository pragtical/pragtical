local core = require "core"
local command = require "core.command"
local config = require "core.config"
local scale = require "plugins.scale"

local function find_script_argument()
  if not ARGS then return nil end
  for i = 1, #ARGS do
    local value = ARGS[i]
    if value and value:match("scripts/lua/benchmarks/zoom_stress%.lua$") then
      return i
    end
  end
end

local function parse_inputs()
  local script_idx = find_script_argument()
  local steps = 50
  local repeats = 3
  local path = system.getcwd() .. PATHSEP .. "scripts" .. PATHSEP .. "lua" .. PATHSEP .. "pgo.lua"

  if script_idx and ARGS then
    local steps_arg = tonumber(ARGS[script_idx + 1])
    local repeats_arg = tonumber(ARGS[script_idx + 2])
    local path_arg = ARGS[script_idx + 3]
    if steps_arg and steps_arg >= 1 then steps = math.floor(steps_arg) end
    if repeats_arg and repeats_arg >= 1 then repeats = math.floor(repeats_arg) end
    if path_arg and path_arg ~= "" and path_arg ~= "none" then path = path_arg end
    if path_arg == "none" then path = nil end
  end

  return steps, repeats, path
end

local function percentile(values, pct)
  local index = math.max(1, math.min(#values, math.ceil(#values * pct)))
  return values[index]
end

local function print_summary(label, times)
  table.sort(times)
  local total = 0
  for _, value in ipairs(times) do total = total + value end
  print(string.format(
    "%-18s avg %.3fms | p50 %.3fms | p95 %.3fms | min %.3fms | max %.3fms",
    label,
    (total / #times) * 1000,
    percentile(times, 0.50) * 1000,
    percentile(times, 0.95) * 1000,
    times[1] * 1000,
    times[#times] * 1000
  ))
end

local function wait_frame()
  core.redraw = true
  coroutine.yield()
end

config.draw_stats = false
config.fps = 1000

local steps, repeats, path = parse_inputs()
print("Usage:")
print("  ./scripts/run-local <build-dir> run -n \\")
print("    scripts/lua/benchmarks/zoom_stress.lua [steps] [repeats] [path|none]")
print(string.format("Steps: %d", steps))
print(string.format("Repeats: %d", repeats))
print(string.format("Path: %s", path or "none"))

core.add_thread(function()
  local previous_scale = scale.get()
  local previous_code_scale = scale.get_code()

  local opened_doc = path ~= nil
  if opened_doc then
    core.root_view:open_doc(core.open_doc(path))
  end

  for _ = 1, 20 do
    wait_frame()
  end

  local increase_times = {}
  local decrease_times = {}
  for _ = 1, repeats do
    for _ = 1, steps do
      local start = system.get_time()
      scale.increase()
      wait_frame()
      increase_times[#increase_times + 1] = system.get_time() - start
    end
    for _ = 1, steps do
      local start = system.get_time()
      scale.decrease()
      wait_frame()
      decrease_times[#decrease_times + 1] = system.get_time() - start
    end
  end

  scale.set(previous_scale)
  scale.set_code(previous_code_scale)
  if opened_doc then
    command.perform "root:close"
  end

  print_summary("zoom increase", increase_times)
  print_summary("zoom decrease", decrease_times)

  local combined = {}
  for _, value in ipairs(increase_times) do combined[#combined + 1] = value end
  for _, value in ipairs(decrease_times) do combined[#combined + 1] = value end
  print_summary("zoom combined", combined)

  command.perform "core:quit"
end)
