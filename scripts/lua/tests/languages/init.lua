local test = require "core.test"
local syntax = require "core.syntax"
local tokenizer = require "core.tokenizer"

local fixtures = dofile("scripts/lua/tests/languages/samples/manifest")
local sample_dir = "scripts/lua/tests/languages/samples/"

local function copy_table(source)
  local copy = {}
  for key, value in pairs(source) do
    copy[key] = value
  end
  return copy
end

local function deep_copy(value, seen)
  if type(value) ~= "table" then
    return value
  end

  seen = seen or {}
  if seen[value] then
    return seen[value]
  end

  local copy = {}
  seen[value] = copy
  for key, item in pairs(value) do
    copy[deep_copy(key, seen)] = deep_copy(item, seen)
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
      config.native_tokenizer = false
      return config
    end
    return require(name)
  end
  setfenv(chunk, env)
  return chunk()
end

local function list_dir(path)
  local files = system.list_dir(path) or {}
  table.sort(files)
  return files
end

local function load_language_plugins(path)
  for _, name in ipairs(list_dir(path)) do
    if name:match("^language_.*%.lua$") then
      local file = path .. PATHSEP .. name
      local ok, err = pcall(function()
        assert(loadfile(file))()
      end)
      test.ok(ok, string.format("failed to load %s: %s", file, err))
    end
  end
end

local function files_key(files)
  if type(files) == "table" then
    return table.concat(files, "|")
  end
  return tostring(files or "")
end

local function syntax_key(name, files)
  return tostring(name or "") .. "\0" .. files_key(files)
end

local function read_file(path)
  local file = assert(io.open(path, "rb"))
  local text = file:read("*a")
  file:close()
  return text
end

local function split_lines(text)
  local lines = {}
  local start = 1

  for i = 1, #text do
    if text:byte(i) == 10 then
      lines[#lines + 1] = text:sub(start, i)
      start = i + 1
    end
  end

  if start <= #text then
    lines[#lines + 1] = text:sub(start)
  end

  if #lines == 0 then
    lines[1] = ""
  end

  return lines
end

local function tokenize_line(engine, syn, state, text)
  local resume
  local tokens
  local next_state = state

  repeat
    tokens, next_state, resume = engine.tokenize(syn, text, next_state, resume)
  until not resume

  return tokens or {}, next_state
end

local function format_tokens(tokens)
  local out = {}
  for i = 1, #tokens, 2 do
    out[#out + 1] = string.format("%s:%q", tostring(tokens[i]), tokens[i + 1])
  end
  return table.concat(out, " | ")
end

local function compare_tokens(context, actual, expected)
  test.equal(
    #actual,
    #expected,
    string.format(
      "%s token count: native=%d lua=%d\nnative=%s\nlua=%s",
      context,
      #actual,
      #expected,
      format_tokens(actual),
      format_tokens(expected)
    )
  )
  for i = 1, #expected do
    test.equal(
      actual[i],
      expected[i],
      string.format(
        "%s token %d\nnative=%s\nlua=%s",
        context,
        i,
        tostring(actual[i]),
        tostring(expected[i])
      )
    )
  end
end

test.describe("language tokenizer fixtures", function()
  test.test("native tokenizer matches lua tokenizer", function()
    load_language_plugins("data/plugins")
    load_language_plugins("subprojects/plugins/plugins")

    local syntaxes = {}
    for _, syn in ipairs(syntax.items) do
      if syn.files then
        syntaxes[syntax_key(syn.name, syn.files)] = syn
      end
    end

    local lua_tokenizer = load_lua_tokenizer()
    local using_native = tokenizer.is_using_native()
    local covered = {}

    tokenizer.set_use_native(true)

    for _, fixture in ipairs(fixtures) do
      local key = syntax_key(fixture.name, fixture.files)
      local syn = syntaxes[key]
      test.ok(syn, "missing syntax for fixture " .. fixture.path)
      covered[key] = true

      local lines = split_lines(read_file(sample_dir .. fixture.path))
      local lua_syn = deep_copy(syn)
      local native_syn = deep_copy(syn)
      local lua_state = string.char(0)
      local native_state = string.char(0)

      tokenizer.clear_native_cache(native_syn)

      for line_idx, text in ipairs(lines) do
        local lua_tokens
        local native_tokens
        local context = string.format(
          "%s line %d (%s)",
          fixture.path,
          line_idx,
          fixture.name ~= "" and fixture.name or fixture.files
        )
        local ok, err = pcall(function()
          lua_tokens, lua_state = tokenize_line(lua_tokenizer, lua_syn, lua_state, text)
        end)
        test.ok(ok, context .. " lua tokenizer error: " .. tostring(err))

        ok, err = pcall(function()
          native_tokens, native_state = tokenize_line(
            tokenizer,
            native_syn,
            native_state,
            text
          )
        end)
        test.ok(ok, context .. " native tokenizer error: " .. tostring(err))

        compare_tokens(context, native_tokens, lua_tokens)
        test.equal(native_state, lua_state, context .. " state")
      end
    end

    tokenizer.set_use_native(using_native)

    for _, syn in ipairs(syntax.items) do
      if syn.files then
        local key = syntax_key(syn.name, syn.files)
        test.ok(covered[key], "missing language fixture for " .. files_key(syn.files))
      end
    end
  end)
end)
