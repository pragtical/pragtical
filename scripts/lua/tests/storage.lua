local test = require "core.test"
local common = require "core.common"

---Load storage with controlled filesystem failures, without touching real storage.
---@param failure? "mkdir"|"open"|"write"|"close" Operation that should fail
---@return table state Observed file operations and error messages
local function setup(failure)
  local state = { errors = {} }
  local file = {}
  function file:write(content)
    state.content = content
    if failure == "write" then return nil, "write failed" end
    return self
  end
  function file:close()
    state.closed = true
    if failure == "close" then return nil, "close failed" end
    return true
  end
  local modules = {
    core = { error = function(...) state.errors[#state.errors + 1] = string.format(...) end },
    ["core.common"] = {
      dirname = common.dirname, serialize = common.serialize,
      mkdirp = function() return false, "mkdir failed" end
    }
  }
  local env = setmetatable({
    require = function(name) return assert(modules[name]) end,
    system = { get_file_info = function()
      if failure ~= "mkdir" then return { type = "dir" } end
    end },
    io = { open = function()
      state.opened = true
      if failure == "open" then return nil, "open failed" end
      return file
    end }
  }, { __index = _G })
  local chunk = assert(loadfile(DATADIR .. "/core/storage.lua", "t", env))
  if setfenv then setfenv(chunk, env) end
  state.storage = chunk()
  return state
end

test.describe("storage", function()
  test.test("saving reports success only after closing the file", function()
    local state = setup()
    test.ok(state.storage.save("ws", "project-1", { value = "saved" }))
    test.ok(state.opened)
    test.ok(state.closed)
    test.ok(state.content:find("saved", 1, true))
    test.equal(#state.errors, 0)
  end)

  for _, failure in ipairs { "mkdir", "open", "write", "close" } do
    test.test("saving reports " .. failure .. " failures", function()
      local state = setup(failure)
      test.not_ok(state.storage.save("ws", "project-1", {}))
      test.equal(#state.errors, 1)
      test.ok(state.errors[1]:find(failure .. " failed", 1, true))
      if failure == "write" or failure == "close" then test.ok(state.closed) end
      if failure == "mkdir" then test.not_ok(state.opened) end
    end)
  end
end)

test.describe("storage scopes", function()
  test.before_each(function(ctx)
    ctx.root = os.tmpname()
    os.remove(ctx.root)
    test.ok(common.mkdirp(ctx.root))
    ctx.errors = {}
    local env = setmetatable({ USERDIR = ctx.root .. PATHSEP .. "user",
      require = function(name)
        if name == "core" then return { error = function(...) ctx.errors[#ctx.errors + 1] = string.format(...) end } end
        return require(name)
      end
    }, { __index = _G })
    ctx.storage = assert(loadfile(DATADIR .. "/core/storage.lua", "t", env))()
  end)

  test.after_each(function(ctx)
    if ctx.root then common.rm(ctx.root, true) end
  end)

  test.test("isolates user, project object and explicit directory storage", function(ctx)
    local store = ctx.storage
    local root = ctx.root .. PATHSEP .. "project"
    local explicit = ctx.root .. PATHSEP .. "custom"
    local project = require("core.project")(root)
    test.ok(store.save("assistant", "mcp.lua", { scope = "user" }))
    test.ok(store.save("assistant", "mcp.lua", { scope = "project" }, project))
    test.ok(store.save("assistant", "mcp.lua", { scope = "explicit" }, explicit))
    test.equal(store.load("assistant", "mcp.lua").scope, "user")
    test.equal(store.load("assistant", "mcp.lua", project).scope, "project")
    test.equal(store.load("assistant", "mcp.lua", explicit).scope, "explicit")
    test.ok(system.get_file_info(ctx.root .. PATHSEP .. "user/storage/assistant/mcp.lua"))
    test.ok(system.get_file_info(root .. PATHSEP .. ".pragtical/assistant/mcp.lua"))
    test.ok(system.get_file_info(explicit .. PATHSEP .. "assistant/mcp.lua"))
    test.equal(system.get_file_info(explicit .. PATHSEP .. ".pragtical"), nil)
    test.equal(#ctx.errors, 0)
  end)

  test.test("enumerates and clears only the selected scope and module", function(ctx)
    local store, project = ctx.storage, { path = ctx.root .. PATHSEP .. "project" }
    local explicit = project.path .. PATHSEP .. ".pragtical"
    for _, scope in ipairs({ project, explicit }) do
      test.ok(store.save("assistant", "first", 1, scope))
      test.ok(store.save("assistant", "second", 2, scope))
      test.ok(store.save("other", "keep", true, scope))
      test.equal(#store.keys("assistant", scope), 2)
      store.clear("assistant", "first", scope)
      test.equal(store.load("assistant", "first", scope), nil)
      test.equal(#store.keys("assistant", scope), 1)
      store.clear("assistant", nil, scope)
      test.equal(#store.keys("assistant", scope), 0)
      test.equal(store.load("other", "keep", scope), true)
    end
    test.equal(#store.keys("assistant"), 0)
  end)

  test.test("round-trips serialized strings, booleans, numbers and special numbers", function(ctx)
    local store, base = ctx.storage, ctx.root .. PATHSEP .. "custom"
    local value = { text = "UTF-8: \195\169\nquote \" slash \\ literal return os.execute('never')",
      enabled = false, values = { -123, 1e-50, math.huge, -math.huge, 0/0 } }
    test.ok(store.save("data", "values", value, base))
    local loaded = store.load("data", "values", base)
    test.equal(loaded.text, value.text)
    test.equal(loaded.enabled, false)
    for index = 1, 4 do test.equal(loaded.values[index], value.values[index]) end
    test.ok(loaded.values[5] ~= loaded.values[5])
    test.equal(#ctx.errors, 0)
  end)

  test.test("rejects executable, malformed and binary project files without running them", function(ctx)
    local store, base = ctx.storage, ctx.root .. PATHSEP .. "custom"
    test.ok(store.save("data", "value", {}, base))
    local path = base .. PATHSEP .. "data/value"
    for _, source in ipairs({ "return os.execute('never')", "while true do end",
      "return (function() while true do end end)()", "return { [1] = _G }",
      "return { [nil] = 1 }", "return {", string.dump(function() return {} end),
      "return (0/0) {}", "return (0/0)[1]", "return (0/0) 'argument'" }) do
      local file = assert(io.open(path, "wb")); assert(file:write(source)); file:close()
      test.equal(store.load("data", "value", base), nil)
    end
    test.equal(#ctx.errors, 10)
  end)

  test.test("rejects invalid scopes and traversal outside the selected module", function(ctx)
    for _, scope in ipairs({ false, 42, {}, { path = "" }, "" }) do
      test.equal(pcall(ctx.storage.save, "data", "value", {}, scope), false)
    end
    for _, module in ipairs({ "..", ".", "", "../outside", "a\\b" }) do
      test.equal(pcall(ctx.storage.clear, module, nil, ctx.root), false)
    end
    test.equal(pcall(ctx.storage.clear, nil, nil, ctx.root), false)
    test.equal(pcall(ctx.storage.save, "data", "..", {}, ctx.root), false)
    test.ok(system.get_file_info(ctx.root))
  end)
end)
