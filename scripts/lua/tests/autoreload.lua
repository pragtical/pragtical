local test = require "core.test"

-- Drive the real plugin's polling loop without filesystem timing or native
-- watcher events making the prompt tests platform-dependent.
local function setup()
  local state = { modified = 1, size = 8, prompts = {}, threads = {} }
  local Doc = {
    load = function(self) self.text = "original" end,
    save = function() end,
    on_close = function() end,
    is_dirty = function(self) return self.dirty or false end,
    reload = function(self) self.text, self.dirty = "reloaded", false end
  }
  local doc = setmetatable({ filename = "test.txt", abs_filename = "/test.txt" }, { __index = Doc })
  local view = { doc = doc }
  local core = { docs = { doc }, active_view = view, log_quiet = function() end }
  core.set_active_view = function(active) core.active_view = active end
  core.get_views_referencing_doc = function() return { view } end
  core.add_thread = function(fn)
    local thread = coroutine.create(fn)
    state.threads[#state.threads + 1] = thread
    return thread
  end
  core.nag_view = { show = function(_, _, _, options, callback)
    state.prompts[#state.prompts + 1] = { options = options, callback = callback }
    core.set_active_view(core.nag_view)
  end }
  local config = { plugins = {} }
  local modules = {
    core = core, ["core.doc"] = Doc, ["core.config"] = config,
    ["core.dirwatch"] = function()
      return {
        watch = function() end,
        unwatch = function() end,
        check = function(_, callback)
          if state.notify then callback(doc.abs_filename) end
        end
      }
    end
  }
  local env = setmetatable({
    require = function(name) return modules[name] or require(name) end,
    system = { get_file_info = function()
      return { type = "file", modified = state.modified, size = state.size }
    end }
  }, { __index = _G })
  local chunk = assert(loadfile(DATADIR .. "/plugins/autoreload.lua", "t", env))
  if setfenv then setfenv(chunk, env) end
  chunk()
  local function resume(thread)
    local ok, err = coroutine.resume(thread)
    assert(ok, err)
  end
  doc:load()
  resume(state.threads[2])
  state.poll = function() resume(state.threads[1]) end
  state.answer = function(text)
    local prompt = state.prompts[#state.prompts]
    for _, option in ipairs(prompt.options) do
      if option.text == text then prompt.callback(option) end
    end
    core.set_active_view(view)
  end
  state.doc, state.config = doc, config.plugins.autoreload
  return state
end

test.describe("autoreload", function()
  for _, dirty in ipairs { false, true } do
    test.test("declining reload acknowledges the disk change, dirty=" .. tostring(dirty), function()
      local state = setup()
      state.doc.dirty = dirty
      if dirty then state.doc.text = "local edits" end
      local text = state.doc.text
      state.modified = 2
      state.poll()
      test.equal(#state.prompts, 1)
      state.poll()
      test.equal(#state.prompts, 1)

      state.answer("No")
      for _ = 1, 3 do state.poll() end
      state.notify = true
      state.poll()
      test.equal(#state.prompts, 1)
      test.equal(state.doc.text, text)
      test.equal(state.doc:is_dirty(), dirty)
      test.equal(state.doc.deferred_reload, false)

      -- Both timestamp-only and size-only changes must still be detected.
      state.modified = 3
      state.poll()
      test.equal(#state.prompts, 2)
      state.answer("No")
      state.size = 16
      state.poll()
      test.equal(#state.prompts, 3)
    end)
  end

  test.test("accepting reload updates the buffer and acknowledges the change", function()
    local state = setup()
    state.doc.dirty = true
    state.modified = 2
    state.poll()
    state.answer("Yes")
    state.poll()
    test.equal(#state.prompts, 1)
    test.equal(state.doc.text, "reloaded")
    test.equal(state.doc:is_dirty(), false)
  end)

  test.test("clean documents can still reload without prompting", function()
    local state = setup()
    state.config.always_show_nagview = false
    state.modified = 2
    state.poll()
    state.poll()
    test.equal(#state.prompts, 0)
    test.equal(state.doc.text, "reloaded")
  end)
end)
