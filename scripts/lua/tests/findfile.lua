local test = require "core.test"
local common = require "core.common"

local function suggestion_texts(items)
  local texts = {}
  for i, item in ipairs(items) do texts[i] = item.text end
  return texts
end

local function setup(native)
  local state = {
    channels = {}, commands = {}, coroutines = {}, workers = {}, errors = {},
    items = {}, directories = {}, stats = 0, listed = 0, shutdown = {},
    fuzzy_calls = 0, ui_stats = 0,
    ignore_rules = {{pattern = "^ignored%.txt$"}}
  }
  local root = "findfile-tests" .. PATHSEP .. "alpha"
  state.directories[root] = { "one.txt", "src" }
  state.directories[root .. PATHSEP .. "src"] = { "two.txt" }
  local config = {
    file_size_limit = 10,
    plugins = { findfile = { show_recent = false, enable_cache = true } }
  }
  local core = {
    projects = {{ path = root }},
    visited_files = {},
    get_ignore_file_rules = function() return state.ignore_rules end,
    error = function(...) state.errors[#state.errors + 1] = string.format(...) end,
    add_thread = function(fn)
      state.coroutines[#state.coroutines + 1] = coroutine.create(fn)
    end,
    status_view = { add_item = function(_, item) state.items[item.name] = item end }
  }
  core.command_view = {
    enter = function(self, label, options)
      self.label = label .. ": "
      state.options = options
      core.active_view = self
    end,
    update_suggestions = function()
      state.suggestions = suggestion_texts(state.options.suggest(""))
    end
  }
  local function check_open()
    if state.closed then error(state.shutdown, 0) end
  end
  local thread_api = {
    get_channel = function(name)
      if state.channels[name] then return state.channels[name] end
      if native then
        local channel = thread.get_channel(name)
        channel:clear()
        state.channels[name] = channel
        return channel
      end
      local queue = { reads = 0 }
      function queue:first()
        check_open()
        self.reads = self.reads + 1
        return self[1]
      end
      function queue:push(value) check_open() self[#self + 1] = value end
      function queue:pop() check_open() table.remove(self, 1) end
      function queue:clear() while #self > 0 do self:pop() end end
      function queue:wait() return assert(self:first(), "empty job queue") end
      state.channels[name] = queue
      return queue
    end,
    create = function(name, fn, ...)
      if state.fail_create then return nil, "injected creation failure" end
      local worker
      if native then
        worker = assert(thread.create(name, fn, ...))
      else
        local args = {...}
        worker = function() return fn(table.unpack(args)) end
      end
      state.workers[#state.workers + 1] = worker
      return worker
    end
  }
  local modules = {
    core = core, ["core.config"] = config,
    ["core.command"] = { add = function(_, commands)
      for name, fn in pairs(commands) do state.commands[name] = fn end
    end },
    ["core.keymap"] = { add = function() end }
  }
  local env = setmetatable({
    require = function(name) return modules[name] or require(name) end,
    thread = thread_api,
    system = native and system or setmetatable({
      fuzzy_match = function(...)
        state.fuzzy_calls = state.fuzzy_calls + 1
        return system.fuzzy_match(...)
      end,
      list_dir = function(path)
        if state.in_worker then state.listed = state.listed + 1 end
        return state.directories[path]
      end,
      get_file_info = function(path)
        if state.in_worker then
          state.stats = state.stats + 1
          if state.on_stat then state.on_stat(path) end
        else
          state.ui_stats = state.ui_stats + 1
        end
        return { type = state.directories[path] and "dir" or "file", size = 1 }
      end
    }, { __index = system })
  }, { __index = _G })
  local chunk = assert(loadfile(DATADIR .. "/plugins/findfile.lua", "t", env))
  if setfenv then setfenv(chunk, env) end
  chunk()
  state.core, state.config = core, config.plugins.findfile
  function state:start() self.commands["core:find-file"]() end
  function state:step()
    local co = self.coroutines[#self.coroutines]
    local ok, err = coroutine.resume(co)
    assert(ok, err)
    return coroutine.status(co)
  end
  function state:run_worker()
    self.in_worker = true
    local ok, err = pcall(self.workers[#self.workers])
    self.in_worker = false
    return ok, err
  end
  function state:finish()
    for _ = 1, 100 do
      if self:step() == "dead" then return end
    end
    error("indexing did not finish")
  end
  return state
end

test.describe("findfile", function()
  test.after_each(function(context)
    if context.state then
      for _, worker in ipairs(context.state.workers) do worker:wait() end
      for _, channel in pairs(context.state.channels) do channel:clear() end
    end
    if context.root then common.rm(context.root, true) end
  end)

  test.test("failed creation clears indexing state and allows a cached retry", function()
    local state = setup()
    state.fail_create = true
    state:start()
    test.equal(state:step(), "dead")
    test.equal(#state.errors, 1)
    test.contains(state.errors[1], "injected creation failure")
    test.equal(#state.suggestions, 0)
    test.equal(#state.channels.findfile_write, 0)
    test.contains(state.items["command:find-file-matches"].get_item()[3], "Matches: 0/0")

    state.fail_create = false
    state:start()
    test.equal(state:step(), "suspended")
    test.ok(state:run_worker())
    state:finish()
    test.same(state.suggestions, {"one.txt", "src" .. PATHSEP .. "two.txt"})
    test.equal(#state.workers, 1)
    state:start()
    test.equal(#state.coroutines, 2, "successful retry should populate the cache")
  end)

  test.test("worker errors discard partial results and pending roots before retry", function()
    local state = setup()
    local beta = "findfile-tests" .. PATHSEP .. "beta"
    local gamma = "findfile-tests" .. PATHSEP .. "gamma"
    state.core.projects[2] = {path = beta}
    state.core.projects[3] = {path = gamma}
    state.directories[beta], state.directories[gamma] = {"three.txt"}, {"four.txt"}
    state.on_stat = function(path)
      if path == beta .. PATHSEP .. "three.txt" then error("injected scan failure") end
    end
    state:start()
    state:step()
    test.ok(state:run_worker(), "worker should report errors through its channel")
    state:finish()
    test.equal(#state.errors, 1)
    test.contains(state.errors[1], "injected scan failure")
    test.equal(#state.suggestions, 0)
    test.equal(#state.channels.findfile_write, 0)
    test.equal(#state.channels.findfile_read, 0)

    state.on_stat = nil
    state:start()
    state:step()
    test.ok(state:run_worker())
    state:finish()
    test.same(state.suggestions, {
      "alpha" .. PATHSEP .. "one.txt",
      "alpha" .. PATHSEP .. "src" .. PATHSEP .. "two.txt",
      "beta" .. PATHSEP .. "three.txt",
      "gamma" .. PATHSEP .. "four.txt"
    })
    test.equal(#state.errors, 1)
    test.equal(#state.workers, 2)
  end)

  test.test("empty result queues yield immediately and reopening reuses the scan", function()
    local state = setup()
    state:start()
    test.equal(state:step(), "suspended")
    local input = state.channels.findfile_read
    test.equal(input.reads, 1)
    test.equal(state:step(), "suspended")
    test.equal(input.reads, 2)
    state:start()
    test.equal(#state.coroutines, 1)
    test.equal(#state.workers, 1)
    test.ok(state:run_worker())
    state:finish()
  end)

  test.test("projects removed before indexing starts do not leave a waiting worker", function()
    local state = setup()
    state:start()
    state.core.projects = {}
    test.equal(state:step(), "dead")
    test.equal(#state.workers, 0)
    test.equal(#state.errors, 0)
  end)

  test.test("directory traversal checks shutdown every 64 directories", function()
    local state = setup()
    local path = state.core.projects[1].path
    for _ = 1, 128 do
      state.directories[path] = {"dir"}
      path = path .. PATHSEP .. "dir"
    end
    state.directories[path] = {"file.txt"}
    state:start()
    state:step()
    state.on_stat = function() state.closed = true end
    local ok, err = state:run_worker()
    test.not_ok(ok)
    test.equal(err, state.shutdown, "shutdown cancellation must not be swallowed")
    test.equal(state.listed, 64)
  end)

  test.test("wide directories check shutdown within 1024 entries", function()
    local state = setup()
    local files = {}
    for i = 1, 2000 do files[i] = "file" .. i end
    state.directories[state.core.projects[1].path] = files
    state:start()
    state:step()
    state.on_stat = function() state.closed = true end
    local ok, err = state:run_worker()
    test.not_ok(ok)
    test.equal(err, state.shutdown)
    test.equal(state.stats, 1023)
  end)

  test.test("large directory queues preserve breadth-first order across batches", function()
    local state = setup()
    local root = state.core.projects[1].path
    local directories = {}
    state.directories[root] = directories
    for i = 1, 600 do
      local name = "dir" .. i
      directories[i] = name
      state.directories[root .. PATHSEP .. name] = {"file.txt", "nested"}
      state.directories[root .. PATHSEP .. name .. PATHSEP .. "nested"] = {"deep.txt"}
    end
    state:start()
    state:step()
    test.ok(state:run_worker())
    state:finish()
    test.equal(#state.errors, 0)
    test.equal(#state.suggestions, 1200)
    for i = 1, 600 do
      test.equal(state.suggestions[i], "dir" .. i .. PATHSEP .. "file.txt")
      test.equal(state.suggestions[600 + i],
        "dir" .. i .. PATHSEP .. "nested" .. PATHSEP .. "deep.txt")
    end
  end)

  test.test("filtering preserves native fuzzy scores and all matching files", function()
    local state = setup()
    local files = {"forms.php", "Forms.php", "alpha.txt", "beta.txt", "my forms.txt", "src"}
    state.directories[state.core.projects[1].path] = files
    state:start()
    state:step()
    test.ok(state:run_worker())
    state:finish()

    for _, query in ipairs({"f", "fo", "form", "forms", "Forms", "s", "php",
      "my f", "not-found", "not-found-either", "a", "", "s", "sr", "src/", "src/two"}) do
      local expected = common.fuzzy_match(state.suggestions, query, true)
      local results = suggestion_texts(state.options.suggest(query))
      test.equal(#results, #expected, query)
      local needle = PLATFORM == "Windows" and query:gsub("/", PATHSEP) or query
      for i, file in ipairs(results) do
        if query ~= "" then
          test.equal(system.fuzzy_match(file, needle, true),
            system.fuzzy_match(expected[i], needle, true), query)
        end
      end
      -- Tied scores may retain scan order rather than table.sort's unstable order.
      table.sort(expected)
      table.sort(results)
      test.same(results, expected, query)
    end
  end)

  test.test("query extensions narrow candidates and line suffixes reuse results", function()
    local state = setup()
    local root = state.core.projects[1].path
    state.directories[root] = {"alpha.lua", "alpha.txt", "beta.txt", "empty.lua"}
    state:start()
    state:step()
    test.ok(state:run_worker())
    state:finish()
    local all = state.options.suggest("")
    local matches = state.options.suggest("alp")
    test.equal(#matches, 2)
    test.equal(state.fuzzy_calls, 4)
    test.equal(matches[1], all[1], "suggestion objects should be reused")
    local narrowed = state.options.suggest("alpha")
    test.equal(#narrowed, 2)
    test.equal(state.fuzzy_calls, 6)
    test.equal(state.options.suggest("alpha:12"), narrowed)
    test.equal(state.options.suggest("alpha:120"), narrowed)
    test.equal(state.fuzzy_calls, 6, "line number edits must not rescore paths")
    test.equal(#state.options.suggest("alphaz"), 0)
    test.equal(state.fuzzy_calls, 8)
    test.equal(#state.options.suggest("alphazy"), 0)
    test.equal(state.fuzzy_calls, 8)
    test.equal(#state.options.suggest("alpha"), 2)
    test.equal(state.fuzzy_calls, 12, "backspace must restore excluded candidates")
    test.same(state.options.suggest(""), all)

    local filename, line
    state.core.projects[1].absolute_path = function(_, path) return root .. PATHSEP .. path end
    state.commands["core:find-file"]("Pick File", function(path, number)
      filename, line = path, number
    end)
    matches = state.options.suggest("alpha.lua:42")
    state.options.submit("alpha.lua:42", matches[1])
    test.equal(filename, root .. PATHSEP .. "alpha.lua")
    test.equal(line, 42)
  end)

  test.test("recent files retain their order without duplicating typed query work", function()
    local state = setup()
    local root = state.core.projects[1].path
    state.config.show_recent = true
    state.core.visited_files = {root .. PATHSEP .. "one.txt", root .. PATHSEP .. "recent.txt"}
    state.core.current_project = function() return state.core.projects[1], true, true end
    state:start()
    state:step()
    test.ok(state:run_worker())
    state:finish()
    local results = state.options.suggest("")
    test.same(suggestion_texts(results), {
      "recent.txt", "one.txt", "one.txt", "src" .. PATHSEP .. "two.txt"
    })
    test.equal(results[1].info, "recent file")
    test.equal(results[2].info, "recent file")
    local stats = state.ui_stats
    results = state.options.suggest("one")
    test.same(suggestion_texts(results), {"one.txt"})
    test.equal(state.ui_stats, stats, "typed queries must not stat recent files")
    test.equal(state.fuzzy_calls, 2, "each candidate must be scored only once")
    test.equal(state.options.suggest("one"), results)
    test.equal(state.fuzzy_calls, 2)
    test.contains(state.items["command:find-file-matches"].get_item()[3], "Matches: 1/2")
  end)

  test.test("filter caches follow new batches and the initial file list replacement", function()
    local state = setup()
    state:start()
    state:step()
    test.same(suggestion_texts(state.options.suggest("one")), {"one.txt"})
    test.equal(#state.options.suggest("other"), 0)
    local output = state.channels.findfile_read
    output:push({"other.txt"})
    test.equal(state:step(), "suspended")
    test.same(suggestion_texts(state.options.suggest("other")), {"other.txt"})
    output:push({"other2.txt"})
    test.equal(state:step(), "suspended")
    test.equal(#state.options.suggest("other"), 2)
    output:push("finished")
    state:finish()
    test.same(state.suggestions, {"other.txt", "other2.txt"})
    state.commands["core:find-file-clear-cache"]()
    state:start()
    test.equal(#state.options.suggest("other"), 0)
  end)

  test.test("native workers finish repeated multi-project scans without losing results", function(context)
    context.root = USERDIR .. PATHSEP .. "findfile-tests-" .. system.get_process_id()
    local alpha = context.root .. PATHSEP .. "alpha"
    local beta = context.root .. PATHSEP .. "beta"
    local src = alpha .. PATHSEP .. "src"
    test.ok(common.mkdirp(src))
    test.ok(common.mkdirp(beta))
    for _, path in ipairs({
      src .. PATHSEP .. "one.txt",
      beta .. PATHSEP .. "two.txt",
      beta .. PATHSEP .. "ignored.txt"
    }) do
      local file = assert(io.open(path, "w"))
      file:write("test\n")
      file:close()
    end
    local state = setup(true)
    context.state = state
    state.core.projects = {{path = alpha}, {path = beta}}
    state.config.enable_cache = false
    for _ = 1, 5 do
      state:start()
      local deadline = system.get_time() + 5
      while state:step() ~= "dead" do
        test.ok(system.get_time() < deadline, "native indexing timed out")
        coroutine.yield(0.001)
      end
      test.equal(#state.errors, 0, table.concat(state.errors, "\n"))
      test.equal(state.workers[#state.workers]:wait(), 0)
      test.same(state.suggestions, {
        "alpha" .. PATHSEP .. "src" .. PATHSEP .. "one.txt",
        "beta" .. PATHSEP .. "two.txt"
      })
    end
    test.equal(#state.errors, 0)
  end)

  test.test("native worker errors reach the UI and allow another scan", function(context)
    context.root = USERDIR .. PATHSEP .. "findfile-error-tests-" .. system.get_process_id()
    test.ok(common.mkdirp(context.root))
    local file = assert(io.open(context.root .. PATHSEP .. "one.txt", "w"))
    file:write("test\n")
    file:close()
    local state = setup(true)
    context.state = state
    state.core.projects = {{path = context.root}}
    state:start()
    state.ignore_rules = {{pattern = "["}}
    local deadline = system.get_time() + 5
    while state:step() ~= "dead" do
      test.ok(system.get_time() < deadline, "worker error was not reported")
      coroutine.yield(0.001)
    end
    test.equal(#state.errors, 1)
    test.equal(#state.suggestions, 0)
    test.contains(state.errors[1], "malformed pattern")
    state.ignore_rules = {{pattern = "^ignored%.txt$"}}
    state:start()
    deadline = system.get_time() + 5
    while state:step() ~= "dead" do
      test.ok(system.get_time() < deadline, "retry timed out")
      coroutine.yield(0.001)
    end
    test.equal(#state.errors, 1)
    test.equal(#state.workers, 2)
    test.same(state.suggestions, {"one.txt"})
  end)
end)
