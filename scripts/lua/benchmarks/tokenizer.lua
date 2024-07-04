local Doc = require "core.doc"

local function copy_table(source)
  local copy = {}
  for key, value in pairs(source) do
    copy[key] = value
  end
  return copy
end

local function load_lua_tokenizer()
  local chunk = assert(loadfile("data/core/tokenizer.lua"))
  local env = setmetatable({}, { __index = _G })
  env.require = function(name)
    if name == "tokenizer" then
      return {}
    end
    if name == "core.config" then
      local config = copy_table(require(name))
      config.enable_native_tokenizer = false
      return config
    end
    return require(name)
  end
  setfenv(chunk, env)
  return chunk()
end

local native_tokenizer = require "tokenizer"
local lua_tokenizer = load_lua_tokenizer()

local function find_script_argument()
  if not ARGS then return nil end
  for i = 1, #ARGS do
    local value = ARGS[i]
    if value and value:match("scripts/lua/benchmarks/tokenizer%.lua$") then
      return i
    end
  end
end

local function parse_inputs()
  local script_idx = find_script_argument()
  if not script_idx or not ARGS or not ARGS[script_idx + 1] then
    return nil, 3
  end

  local path = ARGS[script_idx + 1]
  local iterations = tonumber(ARGS[script_idx + 2])
  if iterations and iterations >= 1 then
    return path, math.floor(iterations)
  end

  return path, 3
end

local function print_usage()
  print("Usage: ./scripts/run-local build run scripts/lua/benchmarks/tokenizer.lua /path/to/file [iterations]")
end

local file_arg, iterations = parse_inputs()
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

local function tokenize_line(tokenizer, state, text)
  local resume
  local out
  local next_state = state
  local total_resumes = 0

  repeat
    local tokens
    tokens, next_state, resume = tokenizer.tokenize(doc.syntax, text, next_state, resume)
    out = tokens
    if resume then
      total_resumes = total_resumes + 1
    end
  until not resume

  return out or {}, next_state, total_resumes
end

local function verify_parity()
  local lua_state = string.char(0)
  local native_state = string.char(0)
  local total_tokens = 0
  local lua_resumes = 0
  local native_resumes = 0

  for i = 1, #doc.lines do
    local text = doc:get_utf8_line(i)
    local lua_tokens
    local native_tokens
    local line_lua_resumes
    local line_native_resumes

    lua_tokens, lua_state, line_lua_resumes = tokenize_line(lua_tokenizer, lua_state, text)
    native_tokens, native_state, line_native_resumes = tokenize_line(native_tokenizer, native_state, text)

    lua_resumes = lua_resumes + line_lua_resumes
    native_resumes = native_resumes + line_native_resumes

    if #lua_tokens ~= #native_tokens then
      return false, string.format("token count mismatch on line %d", i)
    end

    for idx = 1, #lua_tokens do
      if lua_tokens[idx] ~= native_tokens[idx] then
        return false, string.format("first mismatch on line %d token %d", i, idx)
      end
    end

    if lua_state ~= native_state then
      return false, string.format("state mismatch on line %d", i)
    end

    total_tokens = total_tokens + (#lua_tokens / 2)
  end

  return true, {
    tokens = total_tokens,
    state = lua_state,
    lua_resumes = lua_resumes,
    native_resumes = native_resumes
  }
end

local function benchmark_once(tokenizer)
  collectgarbage("collect")
  local state = string.char(0)
  local total_resumes = 0
  local start = system.get_time()

  for i = 1, #doc.lines do
    local text = doc:get_utf8_line(i)
    local _, next_state, line_resumes = tokenize_line(tokenizer, state, text)
    state = next_state
    total_resumes = total_resumes + line_resumes
  end

  return (system.get_time() - start) * 1000, total_resumes
end

local function benchmark(tokenizer)
  local times = {}
  local resumes = 0

  for _ = 1, iterations do
    local elapsed
    elapsed, resumes = benchmark_once(tokenizer)
    times[#times + 1] = elapsed
  end

  local total = 0
  local min = times[1]
  local max = times[1]
  for _, t in ipairs(times) do
    total = total + t
    if t < min then min = t end
    if t > max then max = t end
  end

  return {
    avg = total / #times,
    min = min,
    max = max,
    resumes = resumes
  }
end

local parity_ok, parity = verify_parity()

print(string.format("File: %s", abs_path))
print(string.format("Syntax: %s", doc.syntax.name or "unknown"))
print(string.format("Lines: %d", #doc.lines))
print(string.format("Iterations: %d", iterations))

if parity_ok then
  print(string.format("Parity: matched (%d tokens, final state %q)", parity.tokens, parity.state))
  print(string.format("Lua resumes: %d", parity.lua_resumes))
  print(string.format("Native resumes: %d", parity.native_resumes))
else
  print(string.format("Parity: %s", parity))
end

local lua_summary = benchmark(lua_tokenizer)
local native_summary = benchmark(native_tokenizer)

print(string.format(
  "Lua fallback: avg %.3fms | min %.3fms | max %.3fms",
  lua_summary.avg,
  lua_summary.min,
  lua_summary.max
))
print(string.format(
  "Native: avg %.3fms | min %.3fms | max %.3fms",
  native_summary.avg,
  native_summary.min,
  native_summary.max
))

if parity_ok then
  local speedup = lua_summary.avg / native_summary.avg
  local reduction = (1 - (native_summary.avg / lua_summary.avg)) * 100
  print(string.format("Speedup: %.2fx", speedup))
  print(string.format("Time reduction: %.2f%%", reduction))
else
  print("Warning: Lua and native results differ.")
end

os.exit(0)
