local test = require "core.test"

local function load_module(path, env)
  local chunk = assert(loadfile(DATADIR .. "/" .. path, "t", env))
  if setfenv then setfenv(chunk, env) end
  return chunk()
end

local function normalize(path) return path:gsub("\\", "/") end

local function setup(platform, path, database, options, defer_load)
  options = options or {}
  local state = {
    db = database or {}, writes = {}, loaded = {}, enumerated = {}, cleared = {},
    queued = {}, errors = {}, warnings = {}, paths = {}, directories = {}, times = {}, clock = 100
  }
  state.fail_rename, state.fail_mkdir = options.fail_rename, options.fail_mkdir
  if not options.migrate then
    state.db.ws = state.db.ws or {}
    state.db.ws[".migrated"] = true
  end
  local methods = {}
  local root = setmetatable({ type = "leaf", views = {} }, { __index = methods })
  function methods:add_view(view) self.views[#self.views + 1] = view end
  function methods:set_active_view(view) self.active_view = view end
  function methods:consume(node)
    for key in pairs(self) do self[key] = nil end
    for key, value in pairs(node) do self[key] = value end
  end
  function methods:update_layout() end
  local function new_node() return setmetatable({ type = "leaf", views = {} }, { __index = methods }) end
  local View = {}
  function View:get_state()
    return { filename = self.state.filename, selection = {table.unpack(self.state.selection or {})},
      scroll = self.state.scroll and {x = self.state.scroll.x, y = self.state.scroll.y} }
  end
  function View:get_module() return "core.docview" end
  function View.from_state(value)
    if state.fail_restore then error("restore failed") end
    return setmetatable({ state = value }, { __index = View })
  end
  local core = {
    docs = options.startup_files and {{}} or {}, projects = {{path = path}}, visited_files = {},
    root_view = {root_node = root}, run = function() end, threads = {}, background_threads = 0,
    exit = function(quit_fn, force) if force then quit_fn() end end
  }
  core.menu_view = {DIVIDER = {}}
  function core.menu_view:register(_, entries) state.menu = entries[1].items end
  core.command_view = {}
  function core.command_view:enter(label, value) state.prompt = {label = label, options = value} end
  core.nag_view = {}
  function core.nag_view:show(_, _, _, callback) state.confirm = callback end
  function core.root_view:get_primary_node() return root end
  function core.root_project() return core.projects[1] end
  function core.set_active_view(view) core.active_view = view end
  function core.log(...) state.log = string.format(...) end
  function core.error(...) state.errors[#state.errors + 1] = string.format(...) end
  function core.warn(...) state.warnings[#state.warnings + 1] = string.format(...) end
  function core.try(fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok then state.errors[#state.errors + 1] = result end
    return ok, result
  end
  function core.add_thread(fn) state.queued[#state.queued + 1] = fn end
  function core.add_background_thread(fn, key)
    core.threads[key] = coroutine.create(fn)
    core.background_threads = core.background_threads + 1
    local ok, delay = coroutine.resume(core.threads[key]); assert(ok, delay); state.delay = delay
  end
  function core.set_project(directory)
    core.projects = {{path = directory}}
    core.visited_files = {}
    root.views, root.active_view, core.active_view = {}, nil, nil
    return core.projects[1]
  end
  function core.add_project(directory)
    for _, project in ipairs(core.projects) do if project.path == directory then return project end end
    core.projects[#core.projects + 1] = {path = directory}
    return core.projects[#core.projects]
  end
  function core.remove_project(project)
    for index, value in ipairs(core.projects) do if value == project then table.remove(core.projects, index); return end end
  end
  local function actual_key(source, key)
    for candidate in pairs(source or {}) do
      if candidate == key or platform == "Windows" and candidate:ulower() == key:ulower() then return candidate end
    end
  end
  local function scope(module)
    module = normalize(module)
    if module:match("^ws/") then state.module = module end
    return module
  end
  local function split_path(filename)
    local relative = normalize(filename):match("^/workspace%-tests/storage/(.*)$")
    if relative then return relative:match("^(.*)/([^/]+)$") end
  end
  local function file_info(filename)
    if state.paths[filename] ~= nil then return state.paths[filename] or nil end
    local module, key = split_path(filename)
    local source = module and state.db[module]
    local actual = actual_key(source, key)
    if actual then
      local value = source[actual]
      return {type = "file", modified = state.times[module .. "/" .. actual]
        or type(value) == "table" and value.saved_at or 1}
    end
    local relative = normalize(filename):match("^/workspace%-tests/storage/(.*)$")
    if state.directories[normalize(filename)] or relative and state.db[relative] then return {type = "dir"} end
  end
  local store = {}
  function store.keys(module)
    module = scope(module)
    state.enumerated[#state.enumerated + 1] = module
    local keys, included = {}, {}
    for key in pairs(state.db[module] or {}) do keys[#keys + 1] = key; included[key] = true end
    for directory in pairs(state.db) do
      local key = directory:match("^" .. module .. "/([^/]+)$")
      if key and not included[key] then keys[#keys + 1] = key; included[key] = true end
    end
    table.sort(keys)
    return keys
  end
  function store.load(module, key)
    module = scope(module)
    state.loaded[#state.loaded + 1] = {module = module, key = key}
    if options.fail_load == key then return nil end
    local source = state.db[module] or {}
    return source[actual_key(source, key)]
  end
  function store.save(module, key, value)
    module = scope(module)
    if state.fail_save or state.fail_save_key == key or state.fail_recovery and key == "recovery" then return false end
    state.db[module] = state.db[module] or {}
    local actual = actual_key(state.db[module], key) or key
    state.db[module][actual] = value
    state.times[module .. "/" .. actual] = state.clock
    state.writes[#state.writes + 1] = {module = module, key = key}
    return true
  end
  function store.clear(module, key)
    module = scope(module)
    if key then
      if state.db[module] then state.db[module][actual_key(state.db[module], key) or key] = nil end
    else state.db[module] = nil end
    state.cleared[#state.cleared + 1] = {module = module, key = key}
  end
  local command = {map = {}}
  function command.add(predicate, entries)
    for name, fn in pairs(entries) do command.map[name] = {predicate = predicate, fn = fn} end
  end
  function command.perform(name, ...)
    local entry = command.map[name]
    if entry and entry.predicate() then entry.fn(...); return true end
    return false
  end
  local modules = {core = core, ["core.config"] = {plugins = {workspace = options}},
    ["core.storage"] = store, ["core.docview"] = View, ["core.command"] = command, ["core.node"] = new_node}
  local env = setmetatable({
    PLATFORM = platform, PATHSEP = platform == "Windows" and "\\" or "/", USERDIR = "/workspace-tests",
    system = setmetatable({absolute_path = function(value) return value end, get_file_info = file_info}, {__index = system}),
    string = setmetatable({format = function(format, ...)
      if format == "%08x%08x" and options.forced_id then return options.forced_id end
      return string.format(format, ...)
    end}, {__index = string}),
    os = setmetatable({rename = function(from, to)
      if state.fail_rename and (state.fail_rename == true or normalize(from):match("/([^/]+)$") == state.fail_rename) then
        return nil, "rename failed"
      end
      local module, key = split_path(from)
      local source = module and state.db[module]
      local actual = actual_key(source, key)
      if not actual then return nil, "source missing" end
      local target, destination = split_path(to)
      state.db[target] = state.db[target] or {}
      if actual_key(state.db[target], destination) then return nil, "destination exists" end
      state.db[target][destination], source[actual] = source[actual], nil
      state.times[target .. "/" .. destination] = state.times[module .. "/" .. actual]
      return true
    end}, {__index = os}),
    require = function(name) return modules[name] or require(name) end
  }, {__index = _G})
  modules["core.common"] = load_module("core/common.lua", env)
  modules["core.common"].mkdirp = function(directory)
    if state.fail_mkdir then return false, "mkdir failed" end
    state.directories[normalize(directory)] = true
    return true
  end
  state.system, state.core, state.root, state.storage, state.command = env.system, core, root, store, command
  state.workspace = load_module("plugins/workspace.lua", env)
  state.config = modules["core.config"].plugins.workspace
  function state.flush()
    local pending = state.queued; state.queued = {}
    for _, fn in ipairs(pending) do fn() end
  end
  function state.open(filename)
    local view = View.from_state {filename = filename, selection = {2, 4, 2, 4}, scroll = {x = 0, y = 30}}
    root:add_view(view); root:set_active_view(view); core.set_active_view(view)
    return view
  end
  function state.tick()
    for _, cr in pairs(core.threads) do local ok, delay = coroutine.resume(cr); assert(ok, delay); state.delay = delay end
  end
  function state.save() core.exit(function() end, true) end
  function state.switch(directory) core.set_project(directory); state.flush() end
  core.run()
  if not defer_load then state.flush() end
  return state
end

local function snapshot(path, filename, saved_at)
  return {path = path, saved_at = saved_at, visited_files = {filename}, directories = {},
    documents = {type = "leaf", active_view = 1,
      views = {{module = "core.docview", active = true, state = {
        filename = filename, selection = {1, 1, 1, 1}, scroll = {x = 0, y = 0}}}}}}
end

local function seed(platform, path)
  local state = setup(platform, path)
  state.open("main.lua"); state.save()
  return state
end

local function write_keys(state)
  local keys = {}
  for _, write in ipairs(state.writes) do keys[#keys + 1] = write.key end
  return keys
end

test.describe("workspace storage directories", function()
  test.test("project directory names include a readable project name and a path hash", function()
    local state = seed("Linux", "/projects/Pragtical")
    test.match(state.module, "^ws/Pragtical%-%x+$")
    test.equal(#state.module:match("%-(%x+)$"), 16)
    test.equal(state.db[state.module].main.path, "/projects/Pragtical")
  end)

  test.test("project name prefixes preserve Unicode and avoid unsafe or oversized filenames", function()
    local state = seed("Linux", "/projects/draft:notes?<>|*")
    test.match(state.module, "^ws/draft_notes_____%-%x+$")
    local name = string.rep("é", 100)
    local unicode = seed("Linux", "/projects/" .. name)
    test.equal(unicode.module:match("^ws/(.-)%-%x+$"), string.rep("é", 40))
    test.ok(#unicode.module:sub(4) < 255)
    test.equal(setup("Linux", "/projects/" .. name, unicode.db).module, unicode.module)
  end)

  test.test("uses one main and one recovery filename without a periodic coroutine by default", function()
    local state = seed("Linux", "/projects/editor")
    test.equal(state.config.autosave, false)
    test.equal(state.config.autosave_interval, 10)
    test.equal(state.core.background_threads, 0)
    test.same(state.core.threads, {})
    test.same(write_keys(state), {"main"})
    test.is_nil(state.db[state.module].recovery)
    local restarted = setup("Linux", "/projects/editor", state.db)
    test.equal(restarted.core.active_view.state.filename, "main.lua")
    restarted.save(); restarted.save()
    test.same(write_keys(restarted), {"main", "main"})
    test.equal(#restarted.workspace.get_sessions(), 1)
  end)

  test.test("different full paths have separate directories even with identical basenames", function()
    local database = {}
    local first = setup("Linux", "/one/editor", database)
    first.open("one.lua"); first.save()
    local second = setup("Linux", "/two/editor", database)
    test.not_equal(first.module, second.module)
    test.is_nil(second.core.active_view)
    second.open("two.lua"); second.save()
    first.workspace.clear_sessions()
    test.not_nil(database[second.module].main)
    test.equal(database[second.module].main.documents.views[1].state.filename, "two.lua")
  end)

  test.test("actual project-ID collisions are separated using the stored full path", function()
    local database = {}
    local first = setup("Linux", "/one/editor", database, {forced_id = "collision"})
    first.open("first.lua"); first.save()
    local first_module = first.module
    local second = setup("Linux", "/two/editor", database, {forced_id = "collision"})
    test.not_equal(second.module, first_module)
    second.open("second.lua"); second.save()
    local second_module = second.module
    test.equal(database[first_module].main.path, "/one/editor")
    test.equal(database[second_module].main.path, "/two/editor")
    local restored = setup("Linux", "/two/editor", database, {forced_id = "collision"})
    test.equal(restored.module, second_module)
    test.equal(restored.core.active_view.state.filename, "second.lua")
    test.equal(database[first_module].main.documents.views[1].state.filename, "first.lua")
  end)

  test.test("Windows normalizes case, Unicode and path separators in directory identities", function()
    for _, paths in ipairs {
      {"C:\\Projects\\Editor", "c:/projects/editor"},
      {"C:\\Projects\\Éditeur", "c:/projects/éditeur"},
      {"C:\\Projects\\ẞource", "c:/projects/ßource"}
    } do
      local first = seed("Windows", paths[1])
      local second = setup("Windows", paths[2], first.db)
      test.equal(second.module, first.module)
      test.equal(second.core.active_view.state.filename, "main.lua")
    end
    local first = seed("Linux", "/Projects/Editor")
    local second = setup("Linux", "/projects/editor", first.db)
    test.not_equal(second.module, first.module)
    test.is_nil(second.core.active_view)
  end)

  test.test("startup reads only fixed filenames even with thousands of unrelated sessions", function()
    local first = seed("Linux", "/projects/editor")
    for index = 1, 1000 do
      first.db["ws/other" .. index] = {main = {}, ["session-Other"] = {}}
      first.db.ws["legacy-" .. index] = {}
    end
    for index = 1, 1000 do first.db[first.module]["session-Snapshot" .. index] = {} end
    local state = setup("Linux", "/projects/editor", first.db)
    test.same(state.enumerated, {})
    test.same(state.loaded, {
      {module = "ws", key = ".migrated"},
      {module = first.module, key = "main"},
      {module = first.module, key = "recovery"}, {module = first.module, key = "main"}
    })
    state.loaded, state.enumerated = {}, {}
    local sessions = state.workspace.get_sessions()
    test.equal(#sessions, 1001)
    test.same(state.loaded, {})
    test.same(state.enumerated, {first.module})
    test.equal(sessions[1].key, "main")
    test.equal(sessions[1].name, "Main Session")
  end)

  test.test("listing, removing inactive sessions and clearing do not deserialize saved buffers", function()
    local state = seed("Linux", "/projects/editor")
    local key = assert(state.workspace.save_session("Before refactoring"))
    test.equal(key, "session-Before%20refactoring")
    test.ok(state.workspace.load_session("main"))
    state.loaded = {}
    local sessions = state.workspace.get_sessions()
    test.equal(sessions[2].name, "Before refactoring")
    test.equal(type(sessions[2].saved_at), "number")
    test.same(state.loaded, {})
    test.ok(state.workspace.remove_session(key))
    test.same(state.loaded, {})
    test.equal(state.workspace.clear_sessions(), 1)
    test.same(state.loaded, {})
  end)

  test.test("named snapshots support Unicode and filesystem-sensitive characters", function()
    local state = seed("Windows", "C:\\projects\\editor")
    local name = "Étape 1 / draft: A\\B?"
    local key = assert(state.workspace.save_session(name))
    test.not_ok(key:find("[/\\:*?]"))
    test.equal(state.workspace.get_sessions()[2].name, name)
    test.ok(state.workspace.load_session(key))
    test.not_nil(state.db[state.module][key])
    for _, invalid in ipairs {"", "  ", "line\nbreak", string.rep("x", 300)} do
      test.is_nil(state.workspace.save_session(invalid))
    end
  end)

  test.test("session operations reject traversal and do not load records from other projects", function()
    local state = seed("Linux", "/projects/editor")
    for _, key in ipairs {"../main", "../other/main", "session-../main", "session-", "unrelated", "recovery"} do
      test.not_ok(state.workspace.remove_session(key))
      if key ~= "recovery" then test.not_ok(state.workspace.load_session(key)) end
    end
    state.db[state.module].recovery = snapshot("/other/editor", "foreign.lua")
    local restarted = setup("Linux", "/projects/editor", state.db)
    test.equal(restarted.core.active_view.state.filename, "main.lua")
  end)

  test.test("save-as and loading activate the session that subsequent saves update", function()
    local state = seed("Linux", "/projects/editor")
    local key = assert(state.workspace.save_session("Original"))
    test.equal(state.db[state.module].main.active_session, key)
    test.ok(state.workspace.get_sessions()[2].active)
    state.core.active_view.state.filename = "new.lua"
    test.ok(state.workspace.load_session("main"))
    test.equal(state.core.active_view.state.filename, "main.lua")
    test.equal(state.db[state.module][key].documents.views[1].state.filename, "new.lua")
    test.equal(state.db[state.module].main.active_session, "main")
    test.ok(state.workspace.get_sessions()[1].active)
    test.ok(state.workspace.load_session(key))
    test.equal(state.core.active_view.state.filename, "new.lua")
    test.equal(state.db[state.module].recovery.session_key, key)
    state.core.active_view.state.filename = "latest.lua"
    state.save()
    test.equal(state.db[state.module][key].documents.views[1].state.filename, "latest.lua")
    test.equal(state.db[state.module].main.documents.views[1].state.filename, "main.lua")
    test.is_nil(state.db[state.module].recovery)
    local restarted = setup("Linux", "/projects/editor", state.db)
    test.equal(restarted.core.active_view.state.filename, "latest.lua")
    test.ok(restarted.workspace.get_sessions()[2].active)
    restarted.core.active_view.state.filename = "after-restart.lua"
    restarted.save()
    test.is_nil(state.db[state.module].recovery)
    test.equal(state.db[state.module][key].documents.views[1].state.filename, "after-restart.lua")
    test.equal(state.db[state.module].main.documents.views[1].state.filename, "main.lua")
  end)

  test.test("File Sessions offers explicit save-as and filtering uses filename metadata", function()
    local state = seed("Linux", "/projects/editor")
    state.command.perform("workspace:save-session-as")
    test.equal(state.prompt.label, "Save Session As")
    test.not_ok(state.prompt.options.validate("  "))
    state.prompt.options.submit("Alternate")
    state.loaded = {}
    state.command.perform("workspace:load-session")
    test.same(state.loaded, {})
    local prompt = state.prompt.options
    test.equal(prompt.suggest("Alternate")[1].text, "Alternate")
    test.ok(prompt.suggest("Alternate")[1].info:match("^Active"))
    test.not_ok(prompt.suggest("Main")[1].info:match("^Active"))
    test.same(state.loaded, {})
    local menu = state.menu()
    local entries = {}
    for _, entry in ipairs(menu) do if entry.checked then entries[entry.id] = entry end end
    test.ok(entries["session-Alternate"].checked())
    test.not_ok(entries.main.checked())
    test.same(state.loaded, {})
    entries.main.command()
    test.ok(entries.main.checked())
    test.not_ok(entries["session-Alternate"].checked())
    state.loaded = {}
    for _ = 1, 10 do entries.main.checked(); entries["session-Alternate"].checked() end
    test.same(state.loaded, {})
  end)

  test.test("Windows keeps the active checkmark when saving the same name with different casing", function()
    local state = seed("Windows", "C:\\projects\\editor")
    state.workspace.save_session("Draft")
    state.core.active_view.state.filename = "updated.lua"
    state.workspace.save_session("draft")
    local sessions = state.workspace.get_sessions()
    test.equal(#sessions, 2)
    test.equal(sessions[2].name, "Draft")
    test.ok(sessions[2].active)
    test.equal(state.db[state.module][sessions[2].key].documents.views[1].state.filename, "updated.lua")
    local restarted = setup("Windows", "C:\\projects\\editor", state.db)
    test.equal(restarted.core.active_view.state.filename, "updated.lua")
    test.ok(restarted.workspace.get_sessions()[2].active)
  end)

  test.test("removing the active named session returns future saves to main", function()
    local state = seed("Linux", "/projects/editor")
    local key = assert(state.workspace.save_session("Alternate"))
    state.core.active_view.state.filename = "current.lua"
    test.ok(state.workspace.remove_session(key))
    test.ok(state.workspace.get_sessions()[1].active)
    state.save()
    test.is_nil(state.db[state.module][key])
    test.equal(state.db[state.module].main.documents.views[1].state.filename, "current.lua")
    test.equal(state.db[state.module].main.active_session, "main")
  end)

  test.test("failed activation leaves the old session selected and its layout visible", function()
    local state = seed("Linux", "/projects/editor")
    local first = assert(state.workspace.save_session("First"))
    state.core.active_view.state.filename = "second.lua"
    local second = assert(state.workspace.save_session("Second"))
    state.fail_save_key = "main"
    test.not_ok(state.workspace.load_session(first))
    test.equal(state.core.active_view.state.filename, "second.lua")
    test.equal(state.db[state.module].main.active_session, second)
    test.is_nil(state.db[state.module].recovery)
    test.is_nil(state.workspace.save_session("Third"))
    test.equal(state.db[state.module].main.active_session, second)
    local active = {}
    for _, session in ipairs(state.workspace.get_sessions()) do
      if session.active then active[#active + 1] = session.key end
    end
    test.same(active, {second})
  end)
end)

test.describe("workspace recovery and lifecycle", function()
  test.test("a damaged main record does not hide a valid recovery file", function()
    local original = seed("Linux", "/projects/editor")
    original.db[original.module].recovery = snapshot("/projects/editor", "recovered.lua")
    original.db[original.module].main = {}
    local state = setup("Linux", "/projects/editor", original.db)
    test.equal(state.module, original.module)
    test.equal(state.core.active_view.state.filename, "recovered.lua")
    state.save()
    test.equal(state.db[state.module].main.documents.views[1].state.filename, "recovered.lua")
    test.is_nil(state.db[state.module].recovery)
  end)

  test.test("periodic saves use the same recovery file, skip unchanged state and clear it after quit", function()
    local state = setup("Linux", "/projects/editor", nil, {autosave = true})
    local view = state.open("edited.lua")
    test.equal(state.core.background_threads, 1)
    test.equal(state.delay, 10)
    state.tick(); state.tick()
    test.same(write_keys(state), {"recovery"})
    view.state.scroll.y = 75
    state.tick()
    test.same(write_keys(state), {"recovery", "recovery"})
    local scope = state.module
    test.equal(state.db[scope].recovery.documents.views[1].state.scroll.y, 75)
    local restarted = setup("Linux", "/projects/editor", state.db)
    test.equal(restarted.core.active_view.state.scroll.y, 75)
    test.is_nil(restarted.prompt)
    restarted.save()
    test.not_nil(state.db[scope].main)
    test.is_nil(state.db[scope].recovery)
    test.equal(#restarted.workspace.get_sessions(), 1)
  end)

  test.test("named session checkpoints recover into the same active session after a crash", function()
    local state = setup("Linux", "/projects/editor", nil, {autosave = true})
    state.open("default.lua"); state.save()
    local key = assert(state.workspace.save_session("Writing"))
    state.core.active_view.state.filename = "unsaved.lua"
    state.tick(); state.tick()
    test.equal(state.db[state.module].recovery.session_key, key)
    test.equal(state.db[state.module][key].documents.views[1].state.filename, "default.lua")
    local restarted = setup("Linux", "/projects/editor", state.db)
    test.equal(restarted.core.active_view.state.filename, "unsaved.lua")
    test.ok(restarted.workspace.get_sessions()[2].active)
    restarted.save()
    test.equal(state.db[state.module][key].documents.views[1].state.filename, "unsaved.lua")
    test.equal(state.db[state.module].main.documents.views[1].state.filename, "default.lua")
    test.is_nil(state.db[state.module].recovery)
  end)

  test.test("removing inactive main preserves named recovery and clearing resets the save target", function()
    local state = setup("Linux", "/projects/editor", nil, {autosave = true})
    state.open("working.lua")
    local key = assert(state.workspace.save_session("Writing"))
    state.tick()
    local recovery = state.db[state.module].recovery
    test.ok(state.workspace.remove_session("main"))
    test.equal(state.db[state.module].recovery, recovery)
    test.ok(state.workspace.get_sessions()[1].active)
    state.save()
    test.equal(state.db[state.module].main.active_session, key)
    test.equal(state.workspace.clear_sessions(), 2)
    test.same(state.db[state.module], {})
    state.save()
    test.equal(#state.workspace.get_sessions(), 1)
    test.equal(state.db[state.module].main.active_session, "main")
    test.is_nil(state.db[state.module][key])
  end)

  test.test("missing or invalid active session pointers fall back to main", function()
    for _, key in ipairs {"session-Missing", "../outside", "recovery"} do
      local state = seed("Linux", "/projects/editor")
      state.db[state.module].main.active_session = key
      local restarted = setup("Linux", "/projects/editor", state.db)
      test.equal(restarted.core.active_view.state.filename, "main.lua")
      test.ok(restarted.workspace.get_sessions()[1].active)
      restarted.save()
      test.equal(state.db[state.module].main.active_session, "main")
    end
  end)

  test.test("project switches retain each project's active named session", function()
    local state = seed("Linux", "/one/project")
    local first = assert(state.workspace.save_session("First"))
    state.core.active_view.state.filename = "one.lua"
    state.switch("/two/project")
    state.open("two.lua")
    local second = assert(state.workspace.save_session("Second"))
    state.switch("/one/project")
    test.equal(state.core.active_view.state.filename, "one.lua")
    test.equal(state.workspace.get_sessions()[2].key, first)
    test.ok(state.workspace.get_sessions()[2].active)
    state.switch("/two/project")
    test.equal(state.core.active_view.state.filename, "two.lua")
    test.equal(state.workspace.get_sessions()[2].key, second)
    test.ok(state.workspace.get_sessions()[2].active)
  end)

  test.test("disabling autosave immediately removes its coroutine and settings reschedule one timer", function()
    local state = setup("Linux", "/projects/editor")
    state.config.autosave = true; state.config.config_spec[1].on_apply()
    test.equal(state.core.background_threads, 1)
    state.config.autosave_interval = 3; state.config.config_spec[2].on_apply()
    test.equal(state.delay, 3)
    test.equal(state.core.background_threads, 1)
    state.config.autosave = false; state.config.config_spec[1].on_apply()
    test.equal(state.core.background_threads, 0)
    test.same(state.core.threads, {})
    state.tick(); test.same(state.writes, {})
    state.config.autosave_interval = 0; state.config.autosave = true; state.config.config_spec[1].on_apply()
    test.equal(state.delay, 1)
  end)

  test.test("failed final saves preserve recovery and successful retry removes it", function()
    local state = setup("Linux", "/projects/editor", nil, {autosave = true})
    state.open("edited.lua"); state.tick()
    local recovered = state.db[state.module].recovery
    state.fail_recovery = true
    state.core.active_view.state.scroll.y = 40; state.tick()
    test.equal(state.db[state.module].recovery, recovered)
    state.fail_save = true; state.save()
    test.equal(state.db[state.module].recovery, recovered)
    state.fail_save = false; state.save()
    test.is_nil(state.db[state.module].recovery)
  end)

  test.test("pending restore guards prevent empty project saves on quit or rapid switches", function()
    local first = seed("Linux", "/one/project")
    local second = seed("Linux", "/two/project")
    first.db[second.module] = second.db[second.module]
    local state = setup("Linux", "/one/project", first.db, nil, true)
    state.core.exit(function() state.core.quit_request = true end, true)
    state.flush()
    test.same(state.writes, {})
    test.not_nil(state.db[first.module].main)
    state = setup("Linux", "/one/project", first.db)
    state.core.set_project("/two/project")
    state.core.set_project("/one/project")
    state.flush()
    test.same(write_keys(state), {"main"})
    test.equal(state.core.active_view.state.filename, "main.lua")
    test.not_nil(state.db[second.module].main)
  end)

  test.test("Windows project-switch restarts preserve both projects across repeated launches", function()
    local first = seed("Windows", "C:\\projects\\Editor")
    local second = seed("Windows", "D:\\projects\\editor")
    first.db[second.module] = second.db[second.module]
    for index = 1, 8 do
      local from = index % 2 == 1 and "C:\\projects\\Editor" or "D:\\projects\\editor"
      local to = index % 2 == 1 and "D:\\projects\\editor" or "C:\\projects\\Editor"
      local state = setup("Windows", from, first.db)
      state.core.set_project(to)
      state.core.exit(function() state.core.restart_request = true end, true)
      state.flush()
      test.same(write_keys(state), {"main"})
    end
    test.not_nil(first.db[first.module].main)
    test.not_nil(first.db[second.module].main)
  end)

  test.test("failed restores and cancelled quit do not disable subsequent saves", function()
    local original = seed("Linux", "/projects/editor")
    local state = setup("Linux", "/projects/editor", original.db, nil, true)
    state.fail_restore = true; state.flush()
    test.equal(#state.errors, 1)
    state.fail_restore = false; state.open("fixed.lua")
    state.core.exit(function() error("cancelled quit must not execute") end, false)
    test.same(state.writes, {})
    state.save()
    test.equal(state.db[state.module].main.documents.views[1].state.filename, "fixed.lua")
  end)

  test.test("explicit startup files skip restoration but can still save recovery", function()
    local original = seed("Linux", "/projects/editor")
    local state = setup("Linux", "/projects/editor", original.db, {startup_files = true, autosave = true})
    test.is_nil(state.core.active_view)
    state.open("explicit.lua"); state.tick()
    test.equal(state.db[state.module].recovery.documents.views[1].state.filename, "explicit.lua")
  end)

  test.test("additional roots are absolute and missing roots warn without blocking restore", function()
    local state = setup("Linux", "/projects/editor")
    state.open("main.lua"); state.core.add_project("../other")
    state.system.absolute_path = function(path) test.equal(path, "../other"); return "/projects/other" end
    state.save()
    test.same(state.db[state.module].main.directories, {"/projects/other"})
    state.db[state.module].main.directories = {"/projects/other", "/missing", "/file"}
    local restarted = setup("Linux", "/projects/editor", state.db, nil, true)
    restarted.paths["/projects/other"], restarted.paths["/file"] = {type = "dir"}, {type = "file"}
    restarted.flush()
    test.equal(#restarted.core.projects, 2)
    test.equal(#restarted.warnings, 2)
    test.match(restarted.warnings[1], "/missing", nil, true)
  end)

  test.test("failed manual loads preserve the active view and named snapshot", function()
    for _, failure in ipairs {"fail_save", "fail_restore", "fail_recovery"} do
      local state = seed("Linux", "/projects/editor")
      local key = state.workspace.save_session("Original")
      local original = state.core.active_view
      state[failure] = true
      test.not_ok(state.workspace.load_session(key))
      test.equal(state.core.active_view, original)
      test.not_nil(state.db[state.module][key])
    end
  end)

  test.test("clearing recovery-only state uses the current project directory without reading buffers", function()
    local state = setup("Linux", "/projects/editor", nil, {autosave = true})
    state.open("main.lua"); state.tick()
    state.loaded = {}
    state.command.perform("workspace:clear-sessions")
    test.not_nil(state.confirm)
    state.confirm({text = "Clear Sessions"})
    test.is_nil(state.db[state.module].recovery)
    test.same(state.loaded, {})
  end)
end)

test.describe("workspace legacy migration", function()
  test.test("converts old sessions once and preserves extra snapshots and recovery", function()
    local path = "/projects/editor"
    local main, older = snapshot(path, "latest.lua", 200), snapshot(path, "older.lua", 100)
    local named, recovery = snapshot(path, "named.lua", 50), snapshot(path, "recovered.lua", 300)
    named.name = "Before refactor"
    local database = {ws = {["editor-1"] = older, ["editor-2"] = main, ["editor-3"] = named},
      ["ws-temp"] = {["editor-2"] = recovery}}
    local state = setup("Linux", path, database, {migrate = true})
    local files = database[state.module]
    test.equal(files.main, main)
    test.equal(files.recovery, recovery)
    test.equal(files["session-Before%20refactor"], named)
    test.equal(files["session-Session%201"], older)
    test.equal(state.core.active_view.state.filename, "recovered.lua")
    test.equal(database.ws[".migrated"], true)
    test.is_nil(database.ws["editor-1"])
    test.is_nil(database["ws-temp"]["editor-2"])
    local restarted = setup("Linux", path, database, {migrate = true})
    test.same(restarted.enumerated, {})
    restarted.save()
    test.not_nil(files.main)
    test.is_nil(files.recovery)
  end)

  test.test("migration separates old same-basename projects using their stored full paths", function()
    local first, second = "C:\\projects\\Editor", "D:\\projects\\editor"
    local database = {ws = {["Editor-1"] = snapshot(first, "one.lua"), ["editor-2"] = snapshot(second, "two.lua")}}
    local a = setup("Windows", first, database, {migrate = true})
    local b = setup("Windows", second, database, {migrate = true})
    test.not_equal(a.module, b.module)
    test.equal(a.core.active_view.state.filename, "one.lua")
    test.equal(b.core.active_view.state.filename, "two.lua")
    test.same(b.enumerated, {})
  end)

  test.test("migration preserves duplicate legacy names and existing scoped sessions", function()
    local state = seed("Linux", "/projects/editor")
    state.db.ws[".migrated"] = nil
    local one, two = snapshot("/projects/editor", "one.lua"), snapshot("/projects/editor", "two.lua")
    one.name, two.name = "Same", "Same"
    state.db.ws["editor-1"], state.db.ws["editor-2"] = one, two
    local previous = state.db[state.module].main
    local migrated = setup("Linux", "/projects/editor", state.db, {migrate = true})
    test.equal(state.db[state.module].main, previous)
    test.equal(state.db[state.module]["session-Same"], one)
    test.equal(state.db[state.module]["session-Same-2"], two)
    test.equal(#migrated.workspace.get_sessions(), 3)
  end)

  test.test("unreadable legacy files are preserved and retried before migration is marked complete", function()
    local path = "/projects/editor"
    local source = snapshot(path, "saved.lua")
    local database = {ws = {["editor-1"] = source}}
    setup("Linux", path, database, {migrate = true, fail_load = "editor-1"})
    test.equal(database.ws["editor-1"], source)
    test.is_nil(database.ws[".migrated"])
    local retried = setup("Linux", path, database, {migrate = true})
    test.equal(database[retried.module].main, source)
    test.equal(database.ws[".migrated"], true)
  end)

  test.test("failed migration moves retain sources and are retried on the next startup", function()
    for _, failure in ipairs {"fail_rename", "fail_mkdir"} do
      local path = "/projects/editor"
      local source = snapshot(path, "saved.lua")
      local database = {ws = {["editor-1"] = source}}
      local state = setup("Linux", path, database, {migrate = true, [failure] = true})
      test.equal(database.ws["editor-1"], source)
      test.is_nil(database.ws[".migrated"])
      test.equal(#state.warnings, 1)
      local restarted = setup("Linux", path, database, {migrate = true})
      test.equal(database[restarted.module].main, source)
      test.is_nil(database.ws["editor-1"])
      test.equal(database.ws[".migrated"], true)
      test.equal(restarted.core.active_view.state.filename, "saved.lua")
    end
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
    context.storage_save = storage.save
    storage.save = function(module, key, ...)
      if module:match("^ws[/\\]") then context.module = module end
      return context.storage_save(module, key, ...)
    end
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
    storage.save = context.storage_save
    if context.module then storage.clear(context.module) end
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
    test.same(storage.load(context.module, key).directories, { system.absolute_path(extra) })
  end)

  test.test("switching restores splits and unsaved file and untitled buffers from its backup", function(context)
    local source = core.open_file(context.filename)
    local baseline = source.doc:get_text(1, 1, math.huge, math.huge)
    source.doc:set_selection(1, 4)
    local original = assert(workspace_plugin.save_session("Original"))
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

    local modified_session = assert(workspace_plugin.save_session("Modified"))

    test.ok(workspace_plugin.load_session(original))
    test.equal(core.root_view.root_node.type, "leaf")
    test.not_equal(core.active_view.doc, source.doc)
    test.equal(core.active_view.doc:get_text(1, 1, math.huge, math.huge), baseline)
    test.not_ok(core.active_view.doc:is_dirty())
    test.equal(select(2, core.active_view.doc:get_selection()), 4)
    test.equal(#core.projects, 1)
    test.not_nil(storage.load(context.module, original))

    local sessions = workspace_plugin.get_sessions()
    test.equal(#sessions, 3)
    test.equal(storage.load(context.module, modified_session).documents.type, "hsplit")
    test.same(storage.load(context.module, modified_session).directories, { extra })
    test.ok(workspace_plugin.load_session(modified_session))
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
    test.not_nil(storage.load(context.module, key))
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
    test.is_nil(storage.load(context.module, key))
    test.equal(core.active_view, source)

    assert(workspace_plugin.save_session("First"))
    assert(workspace_plugin.save_session("Second"))
    test.ok(command.perform("workspace:clear-sessions"))
    core.root_view:update(); core.root_view:update()
    core.on_event("textinput", "n")
    test.equal(#workspace_plugin.get_sessions(), 3)
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
