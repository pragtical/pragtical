local test = require "core.test"
local core = require "core"
local Node = require "core.node"
local RootView = require "core.rootview"
local command = require "core.command"
local config = require "core.config"

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
