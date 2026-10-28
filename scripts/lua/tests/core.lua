local test = require "core.test"
local core = require "core"
local Node = require "core.node"
local RootView = require "core.rootview"
local command = require "core.command"
local config = require "core.config"
local common = require "core.common"

local function add_doc(name, dirty, context)
  local doc = {
    name = name, dirty = dirty, closed = 0,
    is_dirty = function(self) return self.dirty end,
    get_name = function(self) return self.name end,
    on_close = function(self)
      test.equal(#core.get_views_referencing_doc(self), 0)
      self.closed = self.closed + 1
    end
  }
  core.docs[#core.docs + 1] = doc
  local views = core.root_view.root_node.views
  views[#views + 1] = { doc = doc, context = context or "session" }
  return doc
end

test.describe("core project switching", function()
  local fields = {
    "docs", "projects", "recent_projects", "nag_view", "root_view",
    "set_project", "exit", "collect_garbage"
  }

  test.before_each(function(c)
    c.saved = {}
    for _, key in ipairs(fields) do c.saved[key] = core[key] end
    c.chdir = system.chdir
    c.prompts, c.switches, c.exits = {}, 0, 0
    core.docs, core.recent_projects = {}, {}
    core.projects = { { path = USERDIR } }
    core.collect_garbage = false
    local permanent_view = { context = "application" }
    core.root_view = setmetatable({
      floating_views = {},
      root_node = setmetatable({
        type = "leaf", views = { permanent_view }, active_view = permanent_view
      }, Node)
    }, RootView)
    core.set_project = function(path)
      c.switches = c.switches + 1
      core.projects = { { path = path } }
      return core.projects[1]
    end
    core.nag_view = { show = function(_, _, message, options, callback)
      c.prompts[#c.prompts + 1] = { message = message, callback = callback }
    end }
    -- Exercise restart's real confirmation path without exiting the test process
    -- or writing its session once confirmation succeeds.
    core.exit = function(quit_fn, force)
      if force then
        c.exits = c.exits + 1
      else
        c.saved.exit(quit_fn, force)
      end
    end
    system.chdir = function(path) c.directory = path end
  end)

  test.after_each(function(c)
    for _, key in ipairs(fields) do core[key] = c.saved[key] end
    system.chdir = c.chdir
  end)

  test.test("accepting a project switch prompts only once", function(c)
    local edited = add_doc("edited.txt", true)
    local other = add_doc("other.txt", true)
    local clean = add_doc("clean.txt", false)
    core.confirm_close_docs(core.docs, core.open_project, USERDIR)
    test.equal(#c.prompts, 1)
    c.prompts[1].callback({ text = "Yes" })

    test.equal(#c.prompts, 1)
    test.equal(c.switches, 1)
    test.equal(c.exits, 1)
    test.equal(#core.docs, 0)
    test.equal(c.directory, USERDIR)
    test.equal(core.collect_garbage, true)
    for _, doc in ipairs { edited, other, clean } do
      test.equal(doc.closed, 1)
    end
    test.equal(edited:is_dirty(), true)
  end)

  test.test("declining leaves the project and dirty documents intact", function(c)
    local doc = add_doc("edited.txt", true)
    core.confirm_close_docs(core.docs, core.open_project, USERDIR)
    c.prompts[1].callback({ text = "No" })

    test.equal(#c.prompts, 1)
    test.equal(c.switches, 0)
    test.equal(c.exits, 0)
    test.equal(doc.closed, 0)
    test.equal(doc:is_dirty(), true)
    test.equal(#core.docs, 1)
    test.equal(#core.get_views_referencing_doc(doc), 1)
    core.confirm_close_docs(core.docs, core.open_project, USERDIR)
    test.equal(#c.prompts, 2)
  end)

  test.test("clean documents are closed before restarting without a prompt", function(c)
    local doc = add_doc("clean.txt", false)
    core.confirm_close_docs(core.docs, core.open_project, USERDIR)
    test.equal(#c.prompts, 0)
    test.equal(c.switches, 1)
    test.equal(c.exits, 1)
    test.equal(#core.docs, 0)
    test.equal(doc.closed, 1)
  end)

  test.test("restart still warns about dirty documents with surviving views", function(c)
    local closed = add_doc("closed.txt", true)
    local retained = add_doc("retained.txt", true, "application")
    core.confirm_close_docs(core.docs, core.open_project, USERDIR)
    c.prompts[1].callback({ text = "Yes" })

    test.equal(#c.prompts, 2)
    test.match(c.prompts[2].message, '"retained.txt"', nil, true)
    test.equal(c.exits, 0)
    test.equal(#core.docs, 1)
    test.equal(core.docs[1], retained)
    test.equal(closed.closed, 1)
    test.equal(retained.closed, 0)
    test.equal(retained:is_dirty(), true)
  end)
end)

test.describe("core startup decorations", function()
  test.before_each(function(c)
    c.directory = core.temp_filename()
    test.ok(common.mkdirp(c.directory .. PATHSEP .. "a"))
    test.ok(common.mkdirp(c.directory .. PATHSEP .. "b"))
    local file = assert(io.open(c.directory .. PATHSEP .. "init.lua", "w"))
    file:write([[
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local bordered = not dofile(USERDIR .. PATHSEP .. "user_settings.lua").config.borderless
-- Saved settings must override an opposite value from the user module,
-- including an explicitly saved false value.
config.borderless = bordered
local requests = {}
local set_window_bordered = system.set_window_bordered
system.set_window_bordered = function(window, enabled)
  requests[#requests + 1] = enabled
  return set_window_bordered(window, enabled)
end
core.add_thread(function()
  local ok, err = xpcall(function()
    assert(config.borderless == not bordered, "saved borderless setting was not applied")
    assert(core.title_view.visible == not bordered, "title visibility disagrees with settings")
    assert(#requests > 0, "window decorations were not configured")
    for _, enabled in ipairs(requests) do
      assert(enabled == bordered, "startup reapplied default window decorations")
    end
    local path = USERDIR .. PATHSEP .. "generation"
    local input = io.open(path, "r")
    local generation = input and tonumber(input:read("*a")) or 0
    if input then input:close() end
    assert(RESTARTED == (generation > 0), "expected a retained window after changing projects")
    local project = USERDIR .. PATHSEP .. (generation % 2 == 0 and "a" or "b")
    assert(common.normalize_path(core.root_project().path) == common.normalize_path(project),
      "Change Project did not select the expected directory")
    if generation == 2 then core.quit(true); return end
    local output = assert(io.open(path, "w"))
    output:write(generation + 1)
    output:close()
    assert(command.perform("core:change-project-folder-commandview"))
    core.command_view:set_text(USERDIR .. PATHSEP .. (generation % 2 == 0 and "b" or "a"))
    core.command_view:submit()
    assert(core.restart_request, "Change Project did not restart the runtime")
  end, debug.traceback)
  if not ok then
    io.stdout:write(err, "\n")
    core.quit(true, 1)
  end
end)
]])
    file:close()
  end)

  test.after_each(function(c)
    if c.process and c.process:running() then
      c.process:kill()
      c.process:wait(1000, 0.01)
    end
    if c.directory then common.rm(c.directory, true) end
  end)

  for _, borderless in ipairs { true, false } do
    test.test("preserves saved borderless=" .. tostring(borderless) .. " across project changes", function(c)
      local file = assert(io.open(c.directory .. PATHSEP .. "user_settings.lua", "w"))
      file:write("return { config = { borderless = ", tostring(borderless),
        ", auto_fps = false, fps = 60 } }")
      file:close()
      c.process = assert(process.start({ EXEFILE, c.directory .. PATHSEP .. "a" }, {
        stdout = process.REDIRECT_PIPE,
        stderr = process.REDIRECT_STDOUT,
        env = {
          PRAGTICAL_USERDIR = c.directory, PRAGTICAL_SCALE = "1",
          PRAGTICAL_RENDERER = "surface",
          SDL_VIDEO_DRIVER = "dummy", SDL_AUDIO_DRIVER = "dummy"
        }
      }))
      local status = c.process:wait(15000, 0.01)
      local output = c.process:read_stdout() or ""
      test.equal(status, 0, "project-change subprocess failed: " .. output)
    end)
  end
end)

test.describe("core window state", function()
  local fields = {
    "window", "window_mode", "prev_window_mode", "window_size", "title_view",
    "projects", "delete_temp_files"
  }
  local system_functions = {
    "get_window_mode", "get_window_size", "set_window_mode", "set_window_size",
    "set_window_bordered"
  }
  local normal_geometry = table.pack(800, 600, 100, 120)
  local fullscreen_geometry = table.pack(1920, 1080, 0, 0)

  local function toggle()
    command.map["core:toggle-fullscreen"].perform()
  end

  local function save(c)
    local exited = false
    core.exit(function() exited = true end, true)
    test.ok(exited)
    return assert(load(c.session, "session"))()
  end

  test.before_each(function(c)
    c.core, c.system = {}, {}
    for _, key in ipairs(fields) do c.core[key] = core[key] end
    for _, key in ipairs(system_functions) do c.system[key] = system[key] end
    c.open, c.borderless = io.open, config.borderless
    c.mode, c.geometry = "normal", normal_geometry
    c.border_changes, c.size_changes = 0, 0
    core.window = {}
    core.window_mode, core.prev_window_mode = "normal", "normal"
    core.window_size = normal_geometry
    core.projects = {}
    core.delete_temp_files = function() end
    core.title_view = {
      visible = false,
      configure_hit_test = function(_, enabled) c.hit_test = enabled end
    }
    config.borderless = false
    system.get_window_mode = function() return c.mode end
    system.get_window_size = function() return table.unpack(c.geometry) end
    system.set_window_mode = function(_, mode)
      c.requested_mode = mode
      if not c.deferred then
        c.mode = mode
        c.geometry = mode == "normal" and normal_geometry or fullscreen_geometry
      end
    end
    system.set_window_size = function(_, ...)
      c.size_changes = c.size_changes + 1
      c.restored_geometry = table.pack(...)
      if c.mode == "normal" then c.geometry = c.restored_geometry end
    end
    system.set_window_bordered = function(_, bordered)
      c.border_changes = c.border_changes + 1
      c.bordered = bordered
    end
    io.open = function(path, mode)
      test.equal(path, USERDIR .. PATHSEP .. "session.lua")
      test.equal(mode, "w")
      return {
        write = function(_, text) c.session = text end,
        close = function() end
      }
    end
  end)

  test.after_each(function(c)
    for _, key in ipairs(fields) do core[key] = c.core[key] end
    for _, key in ipairs(system_functions) do system[key] = c.system[key] end
    io.open, config.borderless = c.open, c.borderless
  end)

  test.test("tracks normal geometry and preserves it across maximize and minimize", function(c)
    c.geometry = table.pack(900, 650, 200, 220)
    core.on_event("resized")
    test.same(core.window_size, c.geometry)
    local geometry = core.window_size
    c.mode, c.geometry = "maximized", fullscreen_geometry
    core.on_event("maximized")
    test.equal(core.prev_window_mode, "maximized")
    test.same(core.window_size, geometry)
    c.mode = "minimized"
    core.on_event("minimized")
    test.equal(core.window_mode, "minimized")
    test.equal(core.prev_window_mode, "maximized")
    test.same(core.window_size, geometry)
    local session = save(c)
    test.equal(session.window_mode, "maximized")
    test.same(session.window, geometry)
  end)

  test.test("does not trust stale window events while native mode is fullscreen", function(c)
    config.borderless = true
    c.mode, c.geometry = "fullscreen", fullscreen_geometry
    for _, event in ipairs {
      "restored", "resized", "maximized", "minimized", "enterfullscreen",
      "resized", "restored", "enterfullscreen"
    } do
      core.on_event(event)
      test.equal(core.window_mode, "fullscreen")
      test.equal(core.prev_window_mode, "normal")
      test.same(core.window_size, normal_geometry)
    end
    test.equal(core.title_view.visible, false)
    test.equal(c.hit_test, false)
    test.equal(c.border_changes, 0)
    local session = save(c)
    test.equal(session.window_mode, "normal")
    test.same(session.window, normal_geometry)
  end)

  test.test("saves native fullscreen correctly before queued events are consumed", function(c)
    c.mode, c.geometry = "fullscreen", fullscreen_geometry
    test.equal(core.window_mode, "normal")
    local session = save(c)
    test.equal(session.window_mode, "normal")
    test.same(session.window, normal_geometry)
  end)

  test.test("captures normal geometry immediately before toggling fullscreen", function(c)
    c.geometry = table.pack(1000, 700, 40, 50)
    toggle()
    test.equal(c.mode, "fullscreen")
    test.same(core.window_size, table.pack(1000, 700, 40, 50))
    test.same(save(c).window, core.window_size)
    toggle()
    test.equal(c.mode, "normal")
    test.same(c.restored_geometry, table.pack(1000, 700, 40, 50))
  end)

  test.test("returns fullscreen to maximized without replacing normal geometry", function(c)
    c.mode, c.geometry = "maximized", fullscreen_geometry
    toggle()
    test.equal(c.mode, "fullscreen")
    test.equal(core.prev_window_mode, "maximized")
    local session = save(c)
    test.equal(session.window_mode, "maximized")
    test.same(session.window, normal_geometry)
    toggle()
    test.equal(c.mode, "maximized")
    test.equal(c.size_changes, 0)
  end)

  test.test("exits fullscreen using restored state without an earlier toggle", function(c)
    -- A restarted Lua runtime has no command-local record of entering fullscreen.
    c.mode, c.geometry = "fullscreen", fullscreen_geometry
    core.prev_window_mode = "maximized"
    config.borderless = true
    core.update_window_state()
    core.configure_borderless_window()
    test.equal(core.title_view.visible, false)
    toggle()
    core.on_event("leavefullscreen")
    test.equal(c.mode, "maximized")
    test.equal(core.title_view.visible, true)
    test.equal(c.hit_test, true)
    test.equal(c.bordered, false)
  end)

  test.test("uses current decoration settings when leaving fullscreen", function(c)
    toggle()
    config.borderless = true
    core.configure_borderless_window()
    test.equal(core.title_view.visible, false)
    test.equal(c.border_changes, 0)
    toggle()
    core.on_event("leavefullscreen")
    test.equal(core.title_view.visible, true)
    test.equal(c.hit_test, true)
    test.equal(c.bordered, false)

    toggle()
    config.borderless = false
    toggle()
    core.on_event("leavefullscreen")
    test.equal(core.title_view.visible, false)
    test.equal(c.hit_test, false)
    test.equal(c.bordered, true)
  end)

  test.test("keeps geometry through asynchronous fullscreen transitions", function(c)
    c.deferred = true
    toggle()
    test.equal(c.requested_mode, "fullscreen")
    test.equal(c.mode, "normal")
    c.mode, c.geometry = "fullscreen", fullscreen_geometry
    core.on_event("enterfullscreen")
    toggle()
    test.equal(c.requested_mode, "normal")
    test.same(c.restored_geometry, normal_geometry)
    test.same(save(c).window, normal_geometry)
    c.mode, c.geometry = "normal", c.restored_geometry
    core.on_event("leavefullscreen")
    test.equal(core.window_mode, "normal")
    test.same(core.window_size, normal_geometry)
  end)
end)

test.describe("core idle scheduling", function()
  test.after_each(function(c)
    if c.child and c.child:running() then
      c.child:kill()
      c.child:wait(1000, 0.01)
    end
    if c.directory then common.rm(c.directory, true) end
  end)

  local function run_child(c, source, callback_rate)
    c.directory = core.temp_filename()
    test.ok(common.mkdirp(c.directory))
    local script = c.directory .. PATHSEP .. "idle.lua"
    local file = assert(io.open(script, "w"))
    -- SDL's dummy display reports zero refresh; set FPS before core.run().
    file:write('local config = require "core.config"\nconfig.fps, config.auto_fps = 60, false\n', source)
    file:close()
    c.child = assert(process.start({ EXEFILE, "run", "-n", script }, {
      stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_STDOUT,
      env = {
        PRAGTICAL_USERDIR = c.directory .. PATHSEP .. "user",
        PRAGTICAL_RENDERER = "surface",
        SDL_VIDEO_DRIVER = "dummy", SDL_AUDIO_DRIVER = "dummy",
        SDL_MAIN_CALLBACK_RATE = callback_rate
      }
    }))
    local status = c.child:wait(10000, 0.01)
    test.equal(status, 0, "idle subprocess failed: " .. (c.child:read_stdout() or ""))
  end

  test.test("idle deadlines do not renew the unfocused grace period", function(c)
    run_child(c, [=[
local core = require "core"
local config = require "core.config"
local run = core.run
core.run = function()
  run()
  local ok, err = xpcall(function()
    local now = system.get_time()
    local focused, pending = true, false
    local steps, foreground, background = 0, 0, 0
    system.get_time = function() return now end
    system.window_has_focus = function() return focused end
    system.has_pending_events = function() return pending end
    config.fps, core.fps, core.co_max_time = 60, 60, 0.012
    core.threads, core.background_threads, core.redraw = {}, 0, false
    core.step = function()
      steps = steps + 1
      core.redraw, pending = false, false
      return false
    end
    local function iterate()
      for _ = 1, 20 do
        local running, wait = core.run_step()
        assert(running and wait >= 0, "invalid scheduler result")
        if wait > 0 then return wait end
        now = now + 0.000001
      end
      error("scheduler kept returning an immediate deadline")
    end
    iterate()
    focused, now = false, now + 6
    core.add_thread(function()
      while true do foreground = foreground + 1; coroutine.yield(0.1) end
    end)
    core.add_background_thread(function()
      while true do background = background + 1; coroutine.yield(0.25) end
    end)
    assert(iterate() > 0.2, "idle wait was capped to a frame")
    assert(background > 0 and foreground == 0, "wrong tasks ran while idle")
    local previous_steps = steps
    now = now + 1
    iterate()
    assert(steps == previous_steps and foreground == 0, "timer renewed the grace period")
    pending = true
    now = now + 1
    iterate()
    assert(steps > previous_steps and foreground > 0, "input did not resume foreground work")
    now = now + 6
    iterate()
    previous_steps = steps
    focused = true
    iterate()
    assert(steps > previous_steps, "focus gain did not resume updates immediately")
    focused, now, core.redraw = false, now + 6, true
    previous_steps = steps
    iterate()
    assert(steps > previous_steps, "redraw request was ignored while unfocused")
    core.quit_request = true
    assert(core.run_step() == false, "idle quit request was ignored")
    core.quit_request = false
    core.threads, core.background_threads = {}, 0
    now = now + 6
    assert(iterate() == math.huge, "empty idle loop did not wait for input")
    now = now + 1
    assert(iterate() == math.huge, "empty idle loop renewed its grace period")
  end, debug.traceback)
  if not ok then print(err) end
  core.quit(true, ok and 0 or 1)
  core.run_step = function() return false end
end
]=])
  end)

  test.test("focused idle waits for view deadlines and keeps animations responsive", function(c)
    run_child(c, [=[
local core = require "core"
local config = require "core.config"
local run = core.run
core.run = function()
  run()
  local ok, err = xpcall(function()
    local now = system.get_time() + 1
    local focused, pending = true, false
    local updates, draws, events, progress = 0, 0, 0, 0
    system.get_time = function() return now end
    system.window_has_focus = function() return focused end
    system.has_pending_events = function() return pending end
    system.poll_event = function()
      if pending then pending = false; return "textinput", "x" end
    end
    core.on_event = function() events = events + 1 end
    config.fps, core.fps, core.co_max_time = 60, 60, 0.012
    config.draw_stats = false
    core.threads, core.background_threads, core.redraw = {}, 0, false
    local animating = false
    local on_update
    core.root_view.update = function()
      updates = updates + 1
      if on_update then local fn = on_update; on_update = nil; fn() end
      if animating and progress < 5 then
        progress = progress + 1
        core.redraw = true
      end
    end
    core.root_view.draw = function() draws = draws + 1 end
    renderer.begin_frame, renderer.end_frame = function() end, function() end
    renderer.set_clip_rect = function() end
    local function iterate()
      for _ = 1, 20 do
        local running, wait = core.run_step()
        assert(running and wait >= 0, "invalid scheduler result")
        if wait > 0 then return wait end
        now = now + 0.000001
      end
      error("scheduler kept returning an immediate deadline")
    end
    assert(iterate() == math.huge, "focused idle still wakes for empty frames")
    local count = updates
    now = now + 0.1
    assert(iterate() == math.huge and updates == count, "focus alone updates views")
    core.request_update(0.4)
    core.request_update(1)
    local deadline_wait = iterate()
    assert(math.abs(deadline_wait - 0.4) < 0.00001,
      "view deadlines did not coalesce: " .. tostring(deadline_wait))
    now = now + 0.400001
    assert(iterate() == math.huge and updates == count + 1, "view deadline was not consumed")
    local launched = 0
    on_update = function()
      core.add_background_thread(function() launched = launched + 1 end)
    end
    core.request_update()
    iterate()
    assert(launched == 1, "task created during update was left asleep")
    count = updates
    local jobs = 0
    core.add_background_thread(function()
      jobs = jobs + 1
      coroutine.yield(0.25)
      jobs = jobs + 1
    end)
    assert(iterate() > 0.24 and updates == count, "background work updates idle views")
    now = now + 0.250001
    iterate()
    assert(jobs == 2 and updates == count, "coroutine deadline did not run independently")
    pending = true
    iterate()
    assert(events == 1 and draws == 1 and updates > count, "input did not resume immediately")
    now = now + 1
    iterate()
    count = updates
    focused = false
    iterate()
    focused = true
    iterate()
    assert(updates == count + 2, "focus changes did not update views")
    animating, core.redraw = true, true
    core.add_background_thread(function()
      for _ = 1, 50 do coroutine.yield(0.001) end
    end)
    local started, previous_draws = now, draws
    for _ = 1, 150 do
      local wait = iterate()
      if progress == 5 and wait == math.huge then break end
      assert(wait < math.huge, "animation went to sleep before settling")
      now = now + wait + 0.000001
    end
    assert(progress == 5 and draws - previous_draws == 5, "coroutine wakeups lost an animation frame")
    assert(now - started >= 4 / 60, "animation ignored the frame limit")
    assert(iterate() == math.huge, "settled animation kept waking the editor")
  end, debug.traceback)
  if not ok then print(err) end
  core.quit(true, ok and 0 or 1)
  core.run_step = function() return false end
end
]=])
  end)

  test.test("coroutine batches keep visualizer frames responsive after slow work", function(c)
    run_child(c, [=[
local core = require "core"
local config = require "core.config"
local run = core.run
function core.run()
  run()
  local ok, err = xpcall(function()
    local now = system.get_time() + 1
    system.get_time = function() return now end
    system.window_has_focus = function() return true end
    system.has_pending_events = function() return false end
    system.poll_event = function() end
    renderer.begin_frame, renderer.end_frame = function() end, function() end
    renderer.set_clip_rect = function() end
    core.root_view.update = function() end
    core.root_view.draw = function() now = now + .008 end
    config.fps, core.fps, core.co_max_time = 75, 75, .005
    core.threads, core.background_threads, core.redraw = {}, 0, false
    local next_visual, frames = now, 0
    for index = 1, 8 do
      core.add_thread(function()
        for iteration = 1, 100 do
          now = now + (index == 1 and iteration % 3 == 1 and .012 or .0001)
          coroutine.yield(index % 2 == 0 and .1 or .2)
        end
      end)
    end
    local owner = {}
    core.add_thread(function()
      for _ = 1, 300 do
        frames = frames + 1
        now = now + .0001
        core.redraw = true
        next_visual = now + 1 / 60
        coroutine.yield(1 / 60)
      end
    end, owner)
    for iteration = 1, 1500 do
      local running, wait = core.run_step()
      assert(running)
      -- Execution budgets may defer work briefly, but not past a whole frame.
      local allowed = math.max(1 / config.fps, next_visual - now)
      assert(wait <= allowed + .000001,
        string.format("visualizer due in %.6fs but scheduler waits %.6fs", allowed, wait))
      now = now + wait + .000001
      if frames >= 100 then break end
    end
    assert(frames >= 100, "visualizer did not keep progressing")
    core.threads = {}
    local wait
    for _ = 1, 30 do
      _, wait = core.run_step()
      if wait == math.huge then break end
      now = now + wait + .000001
    end
    assert(wait == math.huge, "finished coroutine batches kept idle awake")
  end, debug.traceback)
  if not ok then print(err) end
  core.quit(true, ok and 0 or 1)
  core.run_step = function() return false end
end
]=])
  end)

  for _, callback_rate in ipairs { "0", "waitevent" } do
    test.test("background jobs wake and restart with callback rate " .. callback_rate, function(c)
      run_child(c, [=[
local core = require "core"
local config = require "core.config"
config.fps, config.auto_fps = 60, false
local clock = system.get_time
local offset, calls, jobs = 0, 0, 0
local start = clock()
system.get_time = function() return clock() + offset end
system.window_has_focus = function() return false end
core.threads, core.background_threads, core.redraw = {}, 0, false
core.step = function()
  for _ in system.poll_event do end
  core.redraw = false
  return false
end
local ready = thread.get_channel("idle-worker")
thread.create("idle-worker", function()
  local started = system.get_time()
  for _ = 1, 4 do system.sleep(0.0005) end
  thread.get_channel("idle-worker"):push(system.get_time() - started >= 0.002)
end)
core.add_background_thread(function()
  while true do
    jobs = jobs + 1
    if jobs == 8 then
      assert(clock() - start >= 0.2, "coroutine deadlines ran too early")
      assert(calls < 200, "SDL spun instead of waiting for deadlines")
      assert(ready:first() == true, "native worker sleep lost sub-millisecond precision")
      if RESTARTED then core.quit(true) else core.restart_request = true end
      return
    end
    coroutine.yield(0.04)
  end
end)
local run_step = core.run_step
core.run_step = function()
  calls = calls + 1
  assert(clock() - start < 5, "background jobs did not wake")
  local running, wait = run_step()
  offset = 6 -- expire the unfocused grace period without delaying the test
  return running, wait
end
]=], callback_rate)
    end)
  end
end)
