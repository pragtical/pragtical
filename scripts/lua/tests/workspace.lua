local test = require "core.test"

local function load_module(path, env)
  local chunk = assert(loadfile(DATADIR .. "/" .. path, "t", env))
  if setfenv then setfenv(chunk, env) end
  return chunk()
end

local function setup(platform, path, saved, defer_load)
  local state = { saved = saved or {}, writes = {}, cleared = {}, threads = {}, errors = {} }
  local root = { type = "leaf", views = {} }
  function root:add_view(view) self.views[#self.views + 1] = view end
  function root:set_active_view(view) self.active_view = view end
  local View = {}
  function View:get_state() return self.state end
  function View:get_module() return "core.docview" end
  function View.from_state(value)
    if state.fail_restore then error("restore failed") end
    return setmetatable({ state = value }, { __index = View })
  end
  local core = {
    docs = {}, projects = {{ path = path }}, visited_files = {},
    root_view = { root_node = root }, run = function() end,
    exit = function(quit_fn, force) if force then quit_fn() end end
  }
  function core.try(fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok then state.errors[#state.errors + 1] = result end
    return ok, result
  end
  function core.root_project() return core.projects[1] end
  function core.set_active_view(view) core.active_view = view end
  function core.add_thread(fn) state.threads[#state.threads + 1] = fn end
  function core.set_project(project)
    core.projects = {{ path = project }}
    core.visited_files = {}
    root.views, root.active_view, core.active_view = {}, nil, nil
    return core.projects[1]
  end

  -- Model case-insensitive storage while retaining each file's original name.
  local function actual_key(key)
    for existing in pairs(state.saved) do
      if existing == key or platform == "Windows" and existing:ulower() == key:ulower() then
        return existing
      end
    end
  end
  local storage = {}
  function storage.keys(module)
    test.equal(module, "ws")
    local keys = {}
    for key in pairs(state.saved) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
  end
  function storage.load(_, key) return state.saved[actual_key(key)] end
  function storage.save(_, key, value)
    state.writes[#state.writes + 1] = key
    state.saved[actual_key(key) or key] = value
  end
  function storage.clear(_, key)
    state.cleared[#state.cleared + 1] = key
    state.saved[assert(actual_key(key))] = nil
  end
  local modules = { core = core, ["core.storage"] = storage, ["core.docview"] = View }
  local env = setmetatable({
    PLATFORM = platform, PATHSEP = platform == "Windows" and "\\" or "/",
    require = function(name) return modules[name] or require(name) end
  }, { __index = _G })
  modules["core.common"] = load_module("core/common.lua", env)
  load_module("plugins/workspace.lua", env)

  function state.flush()
    local threads = state.threads
    state.threads = {}
    for _, fn in ipairs(threads) do fn() end
  end
  function state.open(filename)
    local view = View.from_state {
      filename = filename, selection = {2, 4, 2, 4}, scroll = {x = 0, y = 30}
    }
    root:add_view(view)
    root:set_active_view(view)
    core.set_active_view(view)
    return view
  end
  function state.save() core.exit(function() end, true) end
  function state.switch(project)
    core.set_project(project)
    state.flush()
  end
  state.core, state.root = core, root
  core.run()
  if not defer_load then state.flush() end
  return state
end

local function workspace(path, filename)
  return {
    path = path, directories = {}, visited_files = {filename},
    documents = {
      type = "leaf", active_view = 1,
      views = {{ module = "core.docview", active = true, state = {filename = filename} }}
    }
  }
end

test.describe("workspace", function()
  test.test("project-switch restart does not save or consume the pending destination", function()
    local first, second = "C:\\Pragtical", "D:\\pragtical"
    local destination = workspace(second, "second.lua")
    local state = setup("Windows", first, { ["pragtical-1"] = destination })
    state.open("first.lua")
    state.core.set_project(second)
    test.same(state.writes, {"Pragtical-2"})
    state.core.exit(function() state.core.restart_request = true end, true)
    state.flush()
    test.same(state.writes, {"Pragtical-2"})
    test.same(state.cleared, {})
    test.equal(state.saved["pragtical-1"], destination)
    local restored = setup("Windows", second, state.saved)
    test.equal(restored.core.active_view.state.filename, "second.lua")
  end)

  test.test("repeated project-switch restarts keep only two populated workspaces", function()
    local paths = {"C:\\Pragtical", "D:\\pragtical"}
    local saved = {
      ["Pragtical-1"] = workspace(paths[1], "first.lua"),
      ["pragtical-2"] = workspace(paths[2], "second.lua")
    }
    local current = 1
    for _ = 1, 20 do
      local state = setup("Windows", paths[current], saved)
      test.equal(state.core.active_view.state.filename, current == 1 and "first.lua" or "second.lua")
      current = 3 - current
      state.core.set_project(paths[current])
      state.core.exit(function() state.core.restart_request = true end, true)
      state.flush()
      test.equal(#state.writes, 1)
      local count = 0
      for _, entry in pairs(saved) do
        count = count + 1
        test.equal(#entry.documents.views, 1)
      end
      test.equal(count, 2)
    end
  end)

  test.test("quitting or restarting before startup restoration preserves the saved workspace", function()
    for _, flag in ipairs {"quit_request", "restart_request"} do
      local path = "C:\\Pragtical"
      local previous = workspace(path, "previous.lua")
      local state = setup("Windows", path, { ["Pragtical-1"] = previous }, true)
      state.core.exit(function() state.core[flag] = true end, true)
      state.flush()
      test.same(state.writes, {})
      test.same(state.cleared, {})
      test.equal(state.saved["Pragtical-1"], previous)
    end
  end)

  test.test("rapid switches restore only the latest project and preserve skipped workspaces", function()
    for _, final in ipairs {"C:\\first", "C:\\third"} do
      local second = workspace("C:\\second", "second.lua")
      local state = setup("Windows", "C:\\first", {
        ["second-1"] = second, ["third-1"] = workspace("C:\\third", "third.lua")
      })
      state.open("first.lua")
      state.core.set_project("C:\\second")
      state.core.set_project(final)
      state.flush()
      test.same(state.writes, {"first-1"})
      test.equal(state.saved["second-1"], second)
      test.equal(#state.root.views, 1)
      test.equal(state.core.active_view.state.filename,
        final == "C:\\first" and "first.lua" or "third.lua")
      test.same(state.errors, {})
    end
  end)

  test.test("a cancelled restart still allows pending restoration and later saving", function()
    local path = "C:\\Pragtical"
    local state = setup("Windows", path, { ["Pragtical-1"] = workspace(path, "kept.lua") }, true)
    state.core.exit(function() state.core.restart_request = true end, false)
    state.flush()
    test.equal(state.core.active_view.state.filename, "kept.lua")
    state.save()
    test.same(state.writes, {"Pragtical-1"})
    test.equal(state.saved["Pragtical-1"].documents.views[1].state.filename, "kept.lua")
  end)

  test.test("restoration errors do not leave subsequent saving disabled", function()
    local path = "C:\\Pragtical"
    local state = setup("Windows", path, { ["Pragtical-1"] = workspace(path, "broken.lua") }, true)
    state.fail_restore = true
    state.flush()
    test.equal(#state.errors, 1)
    test.match(state.errors[1], "restore failed", nil, true)
    state.fail_restore = false
    state.open("recovered.lua")
    state.save()
    test.same(state.writes, {"Pragtical-1"})
    test.equal(state.saved["Pragtical-1"].documents.views[1].state.filename, "recovered.lua")
  end)

  test.test("separate editor instances retain separate workspaces for the same project", function()
    local path, saved = "C:\\Pragtical", {}
    local first = setup("Windows", path, saved)
    local second = setup("Windows", path, saved)
    first.open("first.lua")
    second.open("second.lua")
    first.save()
    second.save()
    test.equal(saved["Pragtical-1"].documents.views[1].state.filename, "first.lua")
    test.equal(saved["Pragtical-2"].documents.views[1].state.filename, "second.lua")
    first = setup("Windows", path, saved)
    second = setup("Windows", path, saved)
    test.equal(first.core.active_view.state.filename, "first.lua")
    test.equal(second.core.active_view.state.filename, "second.lua")
  end)

  test.test("Windows projects with differently cased basenames keep separate workspaces", function()
    local install, project = "C:\\Program Files\\Pragtical", "D:\\Projects\\pragtical"
    local state = setup("Windows", install)
    state.open("installed.lua")
    state.switch(project)
    state.open("first.lua")
    local active = state.open("source.lua")
    state.core.visited_files = {"source.lua", "first.lua"}
    state.save()
    test.equal(state.saved["Pragtical-1"].path, install)
    test.equal(state.saved["pragtical-2"].path, project)

    local restored = setup("Windows", install, state.saved)
    test.equal(restored.core.active_view.state.filename, "installed.lua")
    test.equal(restored.saved["pragtical-2"].path, project)
    restored.save()
    restored = setup("Windows", project, restored.saved)
    test.equal(#restored.root.views, 2)
    test.same(restored.core.active_view.state, active.state)
    test.equal(restored.root.active_view, restored.core.active_view)
    test.same(restored.core.visited_files, {"source.lua", "first.lua"})
    test.equal(restored.saved["Pragtical-1"].path, install)
  end)

  test.test("Windows restores and clears a legacy key using its original spelling", function()
    local path = "C:\\Projects\\pragtical"
    local state = setup("Windows", path, { ["Pragtical-1"] = workspace(path, "legacy.lua") })
    test.equal(state.core.active_view.state.filename, "legacy.lua")
    test.same(state.cleared, {"Pragtical-1"})
    test.same(state.saved, {})
    state.save()
    test.same(state.writes, {"pragtical-1"})
    test.equal(state.saved["pragtical-1"].path, path)
  end)

  test.test("Windows compares full paths without case or separator differences", function()
    for _, path in ipairs {"c:\\projects\\pragtical", "c:/projects/pragtical"} do
      local state = setup("Windows", path, {
        ["Pragtical-1"] = workspace("C:\\Other\\Pragtical", "other.lua"),
        ["Pragtical-2"] = workspace("C:\\Projects\\Pragtical", "target.lua")
      })
      test.equal(state.core.active_view.state.filename, "target.lua")
      test.same(state.cleared, {"Pragtical-2"})
      test.equal(state.saved["Pragtical-1"].path, "C:\\Other\\Pragtical")
    end
  end)

  test.test("Windows recognizes Unicode case variants even when byte lengths differ", function()
    for _, names in ipairs {
      {"\195\137diteur", "\195\169diteur"},
      {"\225\186\158ource", "\195\159ource"}
    } do
      local state = setup("Windows", "C:\\Projects\\" .. names[2], {
        [names[1] .. "-1"] = workspace("C:\\Projects\\" .. names[1], "unicode.lua")
      })
      test.equal(state.core.active_view.state.filename, "unicode.lua")
      test.same(state.cleared, {names[1] .. "-1"})
    end
  end)

  test.test("Windows reserves mixed-case IDs and ignores unrelated filename suffixes", function()
    local saved = {
      ["MY-project-1"] = workspace("C:\\Other\\My-Project", "one.lua"),
      ["my-PROJECT-2"] = workspace("D:\\Other\\My-Project", "two.lua"),
      ["My-Project-extra-3"] = workspace("C:\\My-Project-extra", "extra.lua"),
      ["My-Project-3.bak"] = workspace("C:\\Backup\\My-Project", "backup.lua")
    }
    local state = setup("Windows", "C:\\Projects\\My-Project", saved)
    test.equal(#state.root.views, 0)
    state.open("new.lua")
    state.save()
    test.same(state.writes, {"My-Project-3"})
    test.equal(saved["MY-project-1"].path, "C:\\Other\\My-Project")
    test.equal(saved["my-PROJECT-2"].path, "D:\\Other\\My-Project")
  end)

  test.test("non-Windows filename comparisons remain case-sensitive", function()
    local path = "/projects/pragtical"
    local state = setup("Linux", path, { ["Pragtical-1"] = workspace(path, "upper.lua") })
    test.equal(#state.root.views, 0)
    state.open("lower.lua")
    state.save()
    test.same(state.writes, {"pragtical-1"})
    test.equal(state.saved["Pragtical-1"].documents.views[1].state.filename, "upper.lua")
  end)

  test.test("non-Windows project path comparisons remain case-sensitive", function()
    local state = setup("Linux", "/projects/pragtical", {
      ["pragtical-1"] = workspace("/Projects/pragtical", "other.lua")
    })
    test.equal(#state.root.views, 0)
    test.same(state.cleared, {})
    state.save()
    test.same(state.writes, {"pragtical-2"})
  end)
end)
