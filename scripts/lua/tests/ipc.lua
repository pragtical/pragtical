local test = require "core.test"
local common = require "core.common"
local Object = require "core.object"

-- Load an isolated IPC session without starting its monitor or writing files.
local function session(token, directory_mode)
  local state = {token = token, env = {}, events = {}, requests = {}}
  local core = {
    window = {}, docs = {}, projects = {}, init_working_dir = "/project",
    root_view = {}, exit = function() end, add_background_thread = function() end,
    log = function() end
  }
  function core.root_view:open_doc(path) state.opened = path end
  function core.open_doc(path) return path end
  function core.add_project(path) state.opened = path end
  function core.root_project() return {path = "/project"} end
  function core.confirm_close_docs(_, callback, path) callback(path) end
  function core.open_project(path) state.opened = path end
  local cli = {last_command = "default", unhandled_arguments = {}}
  local env = setmetatable({
    USERDIR = "/ipc-test", package = {loaded = {}},
    require = function(name)
      return assert(({
        ["core"] = core, ["core.cli"] = cli, ["core.common"] = common,
        ["core.object"] = Object, ["core.command"] = {}, ["core.rootview"] = {},
        ["core.config"] = {plugins = {settings = false, ipc = {dirs_instance = directory_mode}}}
      })[name], name)
    end,
    io = {open = function() return {write = function() end, close = function() end} end},
    os = setmetatable({
      getenv = function(key)
        test.equal(key, "XDG_ACTIVATION_TOKEN")
        return state.token
      end,
      remove = function() end, exit = function() state.exited = true end
    }, {__index = os}),
    system = {
      get_process_id = function() return 123 end,
      get_file_info = function(path)
        if path == "/file" or path == "/other" then return {type = "file"} end
        if path == "/directory" or path == "/ipc-test/ipc" then return {type = "dir"} end
      end,
      list_dir = function() return {} end,
      get_time = function() return 1 end,
      chdir = function() end, absolute_path = function(path) return path end,
      setenv = function(key, value)
        state.events[#state.events + 1] = "env"
        state.env[key] = value
      end,
      get_window_mode = function() return "minimized" end,
      set_window_mode = function(_, mode)
        test.equal(mode, "normal")
        state.events[#state.events + 1] = "restore"
      end,
      raise_window = function(window)
        test.equal(window, core.window)
        state.events[#state.events + 1] = "raise"
        state.raised_env = common.merge({}, state.env)
        state.env.XDG_ACTIVATION_TOKEN = nil
      end
    }
  }, {__index = _G})
  local chunk = assert(loadfile(DATADIR .. "/plugins/ipc.lua", "t", env))
  if setfenv then setfenv(chunk, env) end
  local ipc = chunk().current()
  function ipc:get_primary_instance() return "primary" end
  function ipc:call_async(destination, name, callback, path, options)
    state.requests[#state.requests + 1] = {name, path, options}
  end
  function ipc:wait_for_messages() end
  return ipc, cli, env.system, state
end

test.describe("IPC launch activation", function()
  test.test("forwards the current launch environment with each request", function()
    for _, request in ipairs {
      {"/file", "new", "core.open_file"},
      {"/directory", "add", "core.open_directory"},
      {"/directory", "change", "core.change_directory"}
    } do
      for _, token in ipairs {false, "", "launch-token"} do
        token = token or nil
        local _, cli, system, state = session("initial-token", request[2])
        state.token = token -- Read the environment at handoff, not when loading the plugin.
        cli.unhandled_arguments = {"/missing", request[1], "/other"}
        system.get_time()
        test.same(state.requests, {
          {request[3], request[1], token and {env = {XDG_ACTIVATION_TOKEN = token}}},
          {"core.open_file", "/other", token and {env = {XDG_ACTIVATION_TOKEN = token}}}
        })
        test.ok(state.exited)
      end
    end
  end)

  test.test("applies optional environment before restoring and raising the receiving window", function()
    for _, request in ipairs {
      {"core.open_file", "/file"},
      {"core.open_directory", "/directory"},
      {"core.change_directory", "/directory"}
    } do
      for _, options in ipairs {
        false, {}, {env = {}}, {env = {EXAMPLE = "example"}},
        {env = {XDG_ACTIVATION_TOKEN = "", EXAMPLE = "example"}},
        {env = {XDG_ACTIVATION_TOKEN = "launch-token", EXAMPLE = "example"}}
      } do
        options = options or nil
        local ipc, _, _, state = session()
        local receive = ipc.listeners["method." .. request[1]][1]
        receive({data = table.pack("/missing", options)}, {})
        test.same(state.events, {})
        receive({data = table.pack(request[2], options)}, {})
        test.same(state.raised_env, options and options.env or {})
        test.equal(state.events[#state.events - 1], "restore")
        test.equal(state.events[#state.events], "raise")
        test.equal(state.opened, request[2])
      end
    end
  end)
end)
