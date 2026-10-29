local test = require "core.test"

local function load_module(path, env)
  local chunk = assert(loadfile(DATADIR .. "/" .. path, "t", env))
  if setfenv then setfenv(chunk, env) end
  return chunk()
end

local function setup(platform, path, saved, defer_load)
  local state = { saved = saved or {}, writes = {}, cleared = {}, threads = {}, errors = {}, warnings = {} }
  local methods = {}
  local root = setmetatable({ type = "leaf", views = {} }, { __index = methods })
  function methods:add_view(view) self.views[#self.views + 1] = view end
  function methods:set_active_view(view) self.active_view = view end
  function methods:consume(node)
    for k in pairs(self) do self[k] = nil end
    for k, v in pairs(node) do self[k] = v end
  end
  function methods:update_layout() end
  local function new_node()
    return setmetatable({ type = "leaf", views = {} }, { __index = methods })
  end
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
  core.menu_view = { DIVIDER = {} }
  function core.menu_view:register(path, entries, name)
    state.menu_path, state.menu_entries, state.menu_name = path, entries, name
  end
  core.command_view = {}
  function core.command_view:enter(label, options) state.prompt = { label = label, options = options } end
  core.nag_view = {}
  function core.nag_view:show(title, text, options, callback)
    state.confirm = { title = title, text = text, options = options, callback = callback }
  end
  function core.root_view:get_primary_node() return root end
  function core.log(...) state.log = { ... } end
  function core.warn(...) state.warnings[#state.warnings + 1] = string.format(...) end
  function core.try(fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok then state.errors[#state.errors + 1] = result end
    return ok, result
  end
  function core.root_project() return core.projects[1] end
  function core.set_active_view(view) core.active_view = view end
  function core.add_thread(fn) state.threads[#state.threads + 1] = fn end
  function core.add_project(path)
    assert(type(path) == "string", "project path must be a string")
    for _, project in ipairs(core.projects) do
      if project.path == path then return project end
    end
    local project = { path = path }
    core.projects[#core.projects + 1] = project
    return project
  end
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
    if state.fail_save then return false end
    state.writes[#state.writes + 1] = key
    state.saved[actual_key(key) or key] = value
    return true
  end
  function storage.clear(_, key)
    state.cleared[#state.cleared + 1] = key
    state.saved[assert(actual_key(key))] = nil
  end
  local command = { map = {} }
  function command.add(predicate, commands)
    for name, perform in pairs(commands) do command.map[name] = { predicate = predicate, perform = perform } end
  end
  function command.perform(name, ...)
    local entry = command.map[name]
    if entry and entry.predicate(...) then entry.perform(...); return true end
    return false
  end
  local modules = {
    core = core, ["core.storage"] = storage, ["core.docview"] = View,
    ["core.command"] = command, ["core.node"] = new_node
  }
  local env = setmetatable({
    PLATFORM = platform, PATHSEP = platform == "Windows" and "\\" or "/",
    system = setmetatable({ absolute_path = function(path) return path end }, { __index = system }),
    require = function(name) return modules[name] or require(name) end
  }, { __index = _G })
  modules["core.common"] = load_module("core/common.lua", env)
  state.system = env.system
  state.workspace = load_module("plugins/workspace.lua", env)
  state.command = command

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
  for _, platform in ipairs { "Windows", "Linux" } do
    test.test(platform .. " converts relative project paths before saving added directories", function()
      local path = platform == "Windows" and "C:\\projects\\A" or "/projects/A"
      local relative = platform == "Windows" and "..\\B" or "../B"
      local absolute = platform == "Windows" and "C:\\projects\\B" or "/projects/B"
      local state = setup(platform, path)
      state.open("first.lua")
      state.core.add_project(relative)
      state.system.absolute_path = function(directory)
        test.equal(directory, relative)
        return absolute
      end
      state.save()
      test.same(state.saved["A-1"].directories, { absolute })
      test.same(state.errors, {})
    end)

    test.test(platform .. " saves and restores absolute added directories with a file from B active", function()
      local path = platform == "Windows" and "C:\\projects\\A" or "/projects/A"
      local second = platform == "Windows" and "C:\\libraries\\B" or "/libraries/B"
      local third = platform == "Windows" and "D:\\libraries\\C" or "/libraries/C"
      local state = setup(platform, path)
      state.open("first.lua")
      state.core.add_project(second)
      state.core.add_project(third)
      local filename = second .. (platform == "Windows" and "\\io.c3" or "/io.c3")
      state.open(filename)
      state.save()
      test.same(state.saved["A-1"].directories, { second, third })
      test.same(state.errors, {})
      local restored = setup(platform, path, state.saved, true)
      restored.system.get_file_info = function(directory)
        if directory == second or directory == third then return { type = "dir" } end
      end
      restored.flush()
      test.equal(#restored.core.projects, 3)
      test.equal(restored.core.projects[2].path, second)
      test.equal(restored.core.projects[3].path, third)
      test.equal(restored.core.active_view.state.filename, filename)
      test.same(restored.errors, {})
      test.same(restored.warnings, {})
    end)

    test.test(platform .. " skips missing directories with warnings during startup and session loading", function()
      local path = platform == "Windows" and "C:\\projects\\A" or "/projects/A"
      local sep = platform == "Windows" and "\\" or "/"
      local missing = path .. sep .. "missing"
      local file = path .. sep .. "file.txt"
      local directory = path .. sep .. "valid"
      for _, manual in ipairs { false, true } do
        local previous = workspace(path, "selected.lua")
        previous.directories = { missing, file, directory }
        local state = setup(platform, path, manual and {} or { ["A-1"] = previous }, true)
        state.system.get_file_info = function(filename)
          if filename == directory then return { type = "dir" } end
          if filename == file then return { type = "file" } end
        end
        state.flush()
        if manual then
          state.open("current.lua")
          state.saved["A-2"] = previous
          test.ok(state.workspace.load_session("A-2"))
        end
        test.equal(#state.core.projects, 2)
        test.equal(state.core.projects[2].path, directory)
        test.equal(#state.warnings, 2)
        test.match(state.warnings[1], missing, nil, true)
        test.match(state.warnings[1], "no longer exists", nil, true)
        test.match(state.warnings[2], file, nil, true)
        test.same(state.errors, {})
      end
    end)
  end

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

  test.test("lists remaining sessions by numeric ID and full project path", function()
    local path = "C:\\Projects\\Pragtical"
    local state = setup("Windows", path, {
      ["Pragtical-1"] = workspace(path, "auto.lua"),
      ["Pragtical-10"] = workspace(path, "ten.lua"),
      ["pragtical-2"] = workspace("c:/projects/pragtical", "two.lua"),
      ["Pragtical-3"] = workspace("D:\\Other\\Pragtical", "other.lua"),
      ["Pragtical-4.bak"] = workspace(path, "backup.lua")
    })
    local sessions = state.workspace.get_sessions()
    test.equal(#sessions, 2)
    test.equal(sessions[1].key, "pragtical-2")
    test.equal(sessions[2].key, "Pragtical-10")
    test.equal(sessions[1].name, "Session 2")
    test.equal(sessions[1].count, 1)
    test.same(state.writes, {})
    test.same(state.cleared, { "Pragtical-1" })
  end)

  test.test("manual loading backs up the outgoing layout and consumes the selected session", function()
    local path = "/projects/editor"
    local state = setup("Linux", path)
    state.open("current.lua")
    state.saved["editor-2"] = workspace(path, "selected.lua")
    test.ok(state.workspace.load_session("editor-2"))
    test.equal(#state.root.views, 1)
    test.equal(state.core.active_view.state.filename, "selected.lua")
    test.equal(state.saved["editor-1"].documents.views[1].state.filename, "current.lua")
    test.equal(type(state.saved["editor-1"].saved_at), "number")
    test.is_nil(state.saved["editor-2"])
    test.same(state.cleared, { "editor-2" })
  end)

  test.test("failed backups and failed restores preserve the selected and active sessions", function()
    for _, failure in ipairs { "fail_save", "fail_restore" } do
      local path = "/projects/editor"
      local state = setup("Linux", path)
      local active = state.open("current.lua")
      local selected = workspace(path, "selected.lua")
      state.saved["editor-2"] = selected
      state[failure] = true
      test.not_ok(state.workspace.load_session("editor-2"))
      test.equal(state.core.active_view, active)
      test.equal(state.root.views[1], active)
      test.equal(state.saved["editor-2"], selected)
      test.same(state.cleared, {})
    end
  end)

  test.test("manual session operations reject foreign paths and traversal keys", function()
    local path = "/projects/editor"
    local state = setup("Linux", path, {
      ["editor-1"] = workspace("/other/editor", "other.lua")
    })
    state.open("current.lua")
    for _, key in ipairs { "editor-1", "../editor-1", "missing-2" } do
      test.not_ok(state.workspace.load_session(key))
      test.not_ok(state.workspace.remove_session(key))
    end
    test.same(state.writes, {})
    test.same(state.cleared, {})
  end)

  test.test("clearing sessions preserves same-basename projects and the open layout", function()
    local path = "C:\\Projects\\Editor"
    local state = setup("Windows", path, {
      ["Editor-1"] = workspace("D:\\Other\\editor", "other.lua")
    })
    local active = state.open("current.lua")
    state.saved["Editor-2"] = workspace(path, "two.lua")
    state.saved["editor-3"] = workspace("c:/projects/editor", "three.lua")
    test.ok(state.workspace.remove_session("Editor-2"))
    test.equal(state.workspace.clear_sessions(), 1)
    test.equal(state.core.active_view, active)
    test.not_nil(state.saved["Editor-1"])
    test.is_nil(state.saved["Editor-2"])
    test.is_nil(state.saved["editor-3"])
    state.save()
    test.equal(state.saved["Editor-2"].documents.views[1].state.filename, "current.lua")
  end)

  test.test("pickers filter a snapshot without reading storage while typing", function()
    local path = "/projects/editor"
    local state = setup("Linux", path)
    state.saved["editor-2"] = workspace(path, "two.lua")
    state.saved["editor-10"] = workspace(path, "ten.lua")
    state.command.perform("workspace:load-session")
    test.equal(state.prompt.label, "Load Session")
    local options = state.prompt.options
    test.equal(#options.suggest(""), 2)
    local items = options.suggest("10")
    test.equal(#items, 1)
    test.equal(items[1].key, "editor-10")
    test.equal(items[1].info, "1 tab")
    test.not_ok(options.validate("", nil))
    test.ok(options.validate("", items[1]))
    state.core.set_project("/different/editor")
    test.not_ok(options.validate("", items[1]))
    options.submit("", items[1])
    test.same(state.cleared, {})
  end)

  test.test("removal requires confirmation and clearing rechecks the selected project", function()
    local path = "/projects/editor"
    local state = setup("Linux", path)
    local selected = workspace(path, "saved.lua")
    state.saved["editor-2"] = selected
    state.command.perform("workspace:remove-session")
    local options = state.prompt.options
    options.submit("", options.suggest("")[1])
    test.equal(state.confirm.title, "Remove Session")
    state.confirm.callback({ text = "Cancel" })
    test.equal(state.saved["editor-2"], selected)
    state.command.perform("workspace:clear-sessions")
    state.core.set_project("/different/editor")
    state.confirm.callback({ text = "Clear Sessions" })
    test.equal(state.saved["editor-2"], selected)
  end)

  test.test("File Sessions builds current entries when opened", function()
    local path = "/projects/editor"
    local state = setup("Linux", path)
    test.same(state.menu_path, { "file" })
    test.equal(state.menu_name, "workspace")
    local provider = state.menu_entries[1].items
    test.equal(#provider(), 3)
    state.open("current.lua")
    state.saved["editor-2"] = workspace(path, "selected.lua")
    local entries = provider()
    test.equal(#entries, 5)
    test.equal(entries[5].text, "Session 2")
    entries[5].command()
    test.equal(state.core.active_view.state.filename, "selected.lua")
    test.equal(provider()[5].text, "Session 1")
  end)
end)

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local storage = require "core.storage"
local RootView = require "core.rootview"
local View = require "core.view"
local DocView = require "core.docview"
local CommandView = require "core.commandview"
local NagView = require "core.nagview"
local command = require "core.command"
local Project = require "core.project"
local workspace_plugin = require "plugins.workspace"

test.describe("workspace session switching", function()
  test.before_each(function(context)
    context.root, context.docs, context.projects = core.root_view, core.docs, core.projects
    context.active, context.last, context.next = core.active_view, core.last_active_view, core.next_active_view
    context.visited, context.transitions = core.visited_files, config.transitions
    context.command, context.nag = core.command_view, core.nag_view
    context.cwd = system.getcwd() or core.root_project().path
    context.keys = {}
    for _, key in ipairs(storage.keys("ws")) do context.keys[key] = true end
    context.directory = common.normalize_path(core.temp_filename("-workspace-project"))
    test.ok(common.mkdirp(context.directory))
    context.filename = context.directory .. PATHSEP .. "example.txt"
    local file = assert(io.open(context.filename, "wb"))
    file:write("saved on disk\n"); file:close()
    core.projects = { Project(context.directory) }
    core.docs, core.visited_files = {}, {}
    config.transitions = false
    core.root_view = RootView()
    core.root_view.root_node.is_primary_node = true
    core.root_view.size.x, core.root_view.size.y = 1200, 800
    core.set_active_view(core.root_view.root_node.active_view)
  end)

  test.after_each(function(context)
    if core.command_view ~= context.command then core.command_view:exit(false) end
    if core.nag_view ~= context.nag then
      core.nag_view.force_focus = false
      core.nag_view.overlay:hide_floating()
    end
    for _, key in ipairs(storage.keys("ws")) do
      if not context.keys[key] then storage.clear("ws", key) end
    end
    for _, doc in ipairs(core.docs) do doc:on_close() end
    core.root_view, core.docs, core.projects = context.root, context.docs, context.projects
    core.visited_files, config.transitions = context.visited, context.transitions
    core.command_view, core.nag_view = context.command, context.nag
    core.active_view, core.last_active_view, core.next_active_view = context.active, context.last, context.next
    system.chdir(context.cwd)
    test.ok(common.rm(context.directory, true))
  end)

  test.test("saving converts a relative added project path using the native filesystem", function(context)
    local extra = context.directory .. PATHSEP .. "extra"
    test.ok(common.mkdirp(extra))
    system.chdir(context.directory)
    core.open_file(context.filename)
    core.add_project("extra")
    local key = assert(workspace_plugin.save_session())
    test.same(storage.load("ws", key).directories, { system.absolute_path(extra) })
  end)

  test.test("switching restores splits and unsaved file and untitled buffers from its backup", function(context)
    local source = core.open_file(context.filename)
    local baseline = source.doc:get_text(1, 1, math.huge, math.huge)
    source.doc:set_selection(1, 4)
    local original = assert(workspace_plugin.save_session())
    source.doc:insert(1, 1, "unsaved edit: ")
    local modified = source.doc:get_text(1, 1, math.huge, math.huge)
    local untitled = core.open_doc()
    untitled:insert(1, 1, "untitled changes\n")
    untitled:set_suggested_extension("lua")
    core.root_view.root_node:split("right", DocView(untitled))
    core.root_view.root_node.divider = 0.63
    local extra = context.directory .. PATHSEP .. "extra"
    test.ok(common.mkdirp(extra))
    core.add_project(extra)

    test.ok(workspace_plugin.load_session(original))
    test.equal(core.root_view.root_node.type, "leaf")
    test.not_equal(core.active_view.doc, source.doc)
    test.equal(core.active_view.doc:get_text(1, 1, math.huge, math.huge), baseline)
    test.not_ok(core.active_view.doc:is_dirty())
    test.equal(select(2, core.active_view.doc:get_selection()), 4)
    test.equal(#core.projects, 1)
    test.is_nil(storage.load("ws", original))

    local sessions = workspace_plugin.get_sessions()
    test.equal(#sessions, 1)
    test.equal(sessions[1].count, 2)
    test.same(storage.load("ws", sessions[1].key).directories, { extra })
    test.ok(workspace_plugin.load_session(sessions[1].key))
    local root = core.root_view.root_node
    test.equal(root.type, "hsplit")
    test.equal(root.divider, 0.63)
    test.equal(root.a.active_view.doc:get_text(1, 1, math.huge, math.huge), modified)
    test.ok(root.a.active_view.doc:is_dirty())
    test.equal(root.b.active_view.doc:get_text(1, 1, math.huge, math.huge), "untitled changes\n")
    test.equal(root.b.active_view.doc.suggested_extension, "lua")
    test.equal(core.active_view, root.b.active_view)
    test.equal(#core.projects, 2)
    test.equal(core.projects[2].path, common.normalize_volume(extra))
    local file = assert(io.open(context.filename, "rb"))
    test.equal(file:read("*a"), "saved on disk\n"); file:close()
  end)

  test.test("loading leaves locked panels attached and keeps a primary editor pane", function(context)
    local source = core.open_file(context.filename)
    local panel = View()
    core.root_view.root_node:split("left", panel, { x = true })
    local panel_node = core.root_view.root_node:get_node_for_view(panel)
    local original = assert(workspace_plugin.save_session())
    local document_node = core.root_view.root_node:get_node_for_view(source)
    document_node:split("down", DocView(core.open_doc()))
    test.ok(workspace_plugin.load_session(original))
    test.equal(core.root_view.root_node:get_node_for_view(panel), panel_node)
    test.equal(core.root_view:get_primary_node().active_view, core.active_view)
    test.not_nil(core.active_view.doc)
    test.equal(common.normalize_path(core.active_view.doc.abs_filename), context.filename)
  end)

  test.test("session deletion and clearing run through the real picker and confirmation dialog", function(context)
    core.command_view, core.nag_view = CommandView(), NagView()
    core.root_view.root_node:split("down", core.command_view, { y = true })
    core.root_view:get_primary_node():split("up", core.nag_view, { y = true })
    local source = core.open_file(context.filename)
    local key = assert(workspace_plugin.save_session())
    test.ok(command.perform("workspace:remove-session"))
    core.root_view:update(); core.root_view:update()
    core.command_view:submit()
    test.ok(core.nag_view.visible)
    for _ = 1, 5 do core.root_view:update() end
    core.on_event("textinput", "n")
    test.not_nil(storage.load("ws", key))
    test.equal(core.active_view, source)

    test.ok(command.perform("workspace:remove-session"))
    core.root_view:update(); core.root_view:update()
    core.command_view:submit()
    core.root_view:update(); core.root_view:update()
    for _, option, x, y, w, h in core.nag_view:each_option() do
      if option.text == "Remove" then
        core.on_event("mousepressed", "left", x + w / 2, y + h / 2, 1)
        core.on_event("mousereleased", "left", x + w / 2, y + h / 2)
        break
      end
    end
    test.is_nil(storage.load("ws", key))
    test.equal(core.active_view, source)

    assert(workspace_plugin.save_session())
    assert(workspace_plugin.save_session())
    test.ok(command.perform("workspace:clear-sessions"))
    core.root_view:update(); core.root_view:update()
    core.on_event("textinput", "n")
    test.equal(#workspace_plugin.get_sessions(), 2)
    test.ok(command.perform("workspace:clear-sessions"))
    core.root_view:update(); core.root_view:update()
    for _, option, x, y, w, h in core.nag_view:each_option() do
      if option.text == "Clear Sessions" then
        core.on_event("mousepressed", "left", x + w / 2, y + h / 2, 1)
        core.on_event("mousereleased", "left", x + w / 2, y + h / 2)
        break
      end
    end
    test.equal(#workspace_plugin.get_sessions(), 0)
    test.equal(core.active_view, source)
  end)
end)
