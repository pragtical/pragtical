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
