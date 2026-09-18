local test = require "core.test"

-- Run the real startup script without loading editor modules or changing the
-- running process's environment and renderer.
local function startup(options)
  options = options or {}
  local variables = options.env or {}
  local reads, changes = {}, {}
  local env = setmetatable({
    EXEFILE = "/pragtical/bin/pragtical",
    HOME = "/home/test",
    PLATFORM = "Linux",
    ARCH = ARCH,
    RESTARTED = options.restarted or false,
    MACOS_RESOURCES = false,
    package = {config = "/", searchers = {}},
    os = {getenv = function(key) return variables[key] end},
    io = {open = function(path)
      reads[#reads + 1] = path
      if not options.contents then return nil, "unreadable" end
      return {
        read = function()
          if options.read_error then return nil, "read error" end
          return options.contents
        end,
        close = function() return true end
      }
    end},
    system = {
      get_file_info = function(path)
        if options.portable and path == "/pragtical/bin/user" then return {type = "dir"} end
      end,
      setenv = function(key, value)
        variables[key] = value
        changes[#changes + 1] = {key, value}
        return true
      end
    },
    require = function() return {} end
  }, {__index = _G})
  env._G = env
  local path = DATADIR .. "/core/start.lua"
  local chunk = assert(loadfile(path, "t", env))
  if setfenv then setfenv(chunk, env) end
  chunk()
  return variables.PRAGTICAL_RENDERER, reads, changes
end

test.describe("core.start renderer preference", function()
  test.it("applies each saved backend before editor initialization", function()
    for _, name in ipairs({"surface", "sdlgpu", "sdlrenderer"}) do
      local backend, reads, changes = startup({contents = " \t" .. name .. "\r\n"})
      test.equal(backend, name)
      test.equal(reads[1], "/home/test/.config/pragtical/renderer")
      test.equal(#changes, 1)
    end
  end)

  test.it("preserves nonempty environment overrides including invalid ones", function()
    for _, value in ipairs({"surface", "sdlgpu", "invalid"}) do
      local backend, reads = startup({contents = "sdlrenderer", env = {PRAGTICAL_RENDERER = value}})
      test.equal(backend, value)
      test.equal(#reads, 0)
    end
    test.equal(startup({contents = "sdlgpu", env = {PRAGTICAL_RENDERER = ""}}), "sdlgpu")
  end)

  test.it("ignores missing, unreadable and invalid files", function()
    for _, contents in ipairs({false, "", " \r\n", "invalid", "SURFACE", "surface\nsdlgpu"}) do
      local backend, _, changes = startup({contents = contents})
      test.equal(backend, nil)
      test.equal(#changes, 0)
    end
    test.equal(startup({contents = "surface", read_error = true}), nil)
  end)

  test.it("does not reread the preference during an in-process restart", function()
    local backend, reads = startup({contents = "sdlgpu", restarted = true})
    test.equal(backend, nil)
    test.equal(#reads, 0)
  end)

  test.it("uses the resolved portable, overridden or XDG user directory", function()
    for _, options in ipairs({
      {portable = true, env = {PRAGTICAL_USERDIR = "/ignored"}, path = "/pragtical/bin/user"},
      {env = {PRAGTICAL_USERDIR = "/custom"}, path = "/custom"},
      {env = {XDG_CONFIG_HOME = "/xdg"}, path = "/xdg/pragtical"}
    }) do
      options.contents = "surface"
      local _, reads = startup(options)
      test.equal(reads[1], options.path .. "/renderer")
    end
  end)
end)
