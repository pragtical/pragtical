local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local test = require "core.test"
local Project = require "core.project"
local DirWatch = require "core.dirwatch"
local tree = require "plugins.treeview"
require "plugins.treeview_filecount"
local TreeView = getmetatable(tree)

---Advance one cooperative counter slice, leaving other editor work under test control.
---@param c table Counter fixture
local function count_tick(c)
  for i = #c.threads, 1, -1 do
    local ok, err = coroutine.resume(c.threads[i])
    test.ok(ok, err)
    if coroutine.status(c.threads[i]) == "dead" then table.remove(c.threads, i) end
  end
end

---Finish queued counter work with a bounded number of cooperative slices.
---@param c table Counter fixture
local function finish_counts(c)
  for _ = 1, 10000 do
    if #c.threads == 0 then return end
    count_tick(c)
  end
  test.fail("file counter did not finish")
end

---Create a temporary file and any missing parent directories.
---@param c table Counter fixture
---@param name string Relative path within its project
local function count_file(c, name)
  local path = c.directory .. PATHSEP .. name:gsub("/", PATHSEP)
  local parent = common.dirname(path)
  if not system.get_file_info(parent) then test.ok(common.mkdirp(parent)) end
  local file = assert(io.open(path, "w")); file:write("test\n"); file:close()
end

test.describe("treeview file counts", function()
  test.before_each(function(c)
    c.enabled, c.ignore, c.redraw = config.plugins.treeview_filecount.enabled, config.ignore_files, core.redraw
    c.add_thread, c.list_dir, c.get_info = core.add_thread, system.list_dir, system.get_file_info
    c.threads, c.listings = {}, {}
    core.add_thread = function(fn) c.threads[#c.threads + 1] = coroutine.create(fn) end
    system.list_dir = function(path)
      c.listings[path] = (c.listings[path] or 0) + 1
      return c.list_dir(path)
    end
    config.plugins.treeview_filecount.enabled = true
    config.ignore_files = { "^ignored/", "%.tmp$" }
    c.directory = common.normalize_path(core.temp_filename())
    test.ok(common.mkdirp(c.directory))
    c.project, c.view = Project(c.directory), TreeView()
    c.view.expanded[c.directory] = false
    c.counter = c.view.file_counts
    c.watch = { watched = {}, watch = function(self, path, enabled)
      if enabled == false then self:unwatch(path) else self.watched[path] = true end
    end, unwatch = function(self, path) self.watched[path] = nil end }
    c.view.watches[c.project] = c.watch
  end)

  test.after_each(function(c)
    core.add_thread, system.list_dir, system.get_file_info = c.add_thread, c.list_dir, c.get_info
    config.plugins.treeview_filecount.enabled, config.ignore_files, core.redraw = c.enabled, c.ignore, c.redraw
    if c.projects then core.projects = c.projects end
    if c.directory then common.rm(c.directory, true) end
  end)

  test.test("defaults to opt-in in both configuration and Settings", function(c)
    local spec
    for _, option in ipairs(config.plugins.treeview_filecount.config_spec) do
      if option.path == "enabled" then spec = option end
    end
    test.not_nil(spec)
    test.equal(spec.default, false)
    test.equal(c.enabled, false)
  end)

  test.test("queues once without scanning during row drawing and caches text measurements", function(c)
    count_file(c, "one.lua")
    local item = { type = "dir", project = c.project, abs_filename = c.directory }
    local before = c.listings[c.directory]
    test.equal(c.view:draw_item_info(item, false, false, 0, 0, 100, 25), 0)
    test.equal(c.view:draw_item_info(item, false, false, 0, 0, 100, 25), 0)
    test.equal(c.listings[c.directory], before)
    test.equal(#c.threads, 1)
    test.equal(#c.counter.tasks, 1)
    finish_counts(c)
    local entry = c.counter:get(c.project, c.directory)
    test.equal(entry.count, 1)
    local calls, get_width, font = 0, renderer.font.get_width, style.font
    renderer.font.get_width = function(...)
      calls = calls + 1
      return get_width(...)
    end
    renderer.begin_frame(core.window)
    local ok, err = pcall(function()
      local width = c.view:draw_item_info(item, false, false, 0, 0, 100, 25)
      test.ok(width > 0)
      test.equal(c.view:draw_item_info(item, true, true, 0, 0, 100, 25), width)
      test.equal(calls, 1)
      style.font = font:copy(font:get_size() * 1.5)
      test.ok(c.view:draw_item_info(item, false, false, 0, 0, 100, 25) > width)
      test.equal(calls, 2)
    end)
    style.font = font
    renderer.font.get_width = get_width
    renderer.end_frame()
    test.ok(ok, err)
    test.equal(#c.threads, 0)
  end)

  test.test("counts recursively with filters and ignores directory symlinks", function(c)
    for _, name in ipairs { "a/one.lua", "a/two.lua", ".dot", ".hidden/three.lua", "ignored/four.lua", "skip.tmp", "linked/five.lua" } do
      count_file(c, name)
    end
    system.get_file_info = function(path)
      local info = c.get_info(path)
      if info and common.basename(path) == "linked" then info.symlink = true end
      return info
    end
    c.counter:get(c.project, c.directory); finish_counts(c)
    test.equal(c.counter:get(c.project, c.directory).count, 2)
    c.view.show_hidden = true
    c.counter:update()
    c.counter:get(c.project, c.directory); finish_counts(c)
    test.equal(c.counter:get(c.project, c.directory).count, 4)
    c.view.show_ignored = true
    c.counter:update()
    c.counter:get(c.project, c.directory); finish_counts(c)
    test.equal(c.counter:get(c.project, c.directory).count, 6)
  end)

  test.test("yields on wide and file-free trees and pauses while hidden", function(c)
    for i = 1, 300 do count_file(c, "wide/file" .. i) end
    for i = 1, 140 do test.ok(common.mkdirp(c.directory .. PATHSEP .. "empty" .. i)) end
    c.counter:get(c.project, c.directory)
    count_tick(c)
    test.equal(#c.threads, 1)
    test.is_nil(c.counter:get(c.project, c.directory))
    c.view.visible = false
    local calls = 0
    for _, value in pairs(c.listings) do calls = calls + value end
    count_tick(c)
    local paused = 0
    for _, value in pairs(c.listings) do paused = paused + value end
    test.equal(paused, calls)
    c.view.visible = true
    finish_counts(c)
    test.equal(c.counter:get(c.project, c.directory).count, 300)
  end)

  test.test("invalidates ancestors without rescanning siblings and prunes removed watches", function(c)
    count_file(c, "a/one.lua"); count_file(c, "b/two.lua")
    c.counter:get(c.project, c.directory); finish_counts(c)
    local a, b = c.directory .. PATHSEP .. "a", c.directory .. PATHSEP .. "b"
    local sibling_lists = c.listings[b]
    count_file(c, "a/new.lua")
    c.view:invalidate_cache(c.project, a)
    test.equal(c.counter:get(c.project, c.directory).count, 2)
    finish_counts(c)
    test.equal(c.counter:get(c.project, c.directory).count, 3)
    test.equal(c.listings[b], sibling_lists)
    test.ok(c.watch.watched[a])
    test.ok(common.rm(a, true))
    c.view:invalidate_cache(c.project, c.directory)
    c.counter:get(c.project, c.directory); finish_counts(c)
    test.equal(c.counter:get(c.project, c.directory).count, 1)
    test.is_nil(c.watch.watched[a])
  end)

  test.test("yields without any files and suppresses zero counts and expanded-parent info", function(c)
    local path = c.directory
    for _ = 1, 20 do
      path = path .. PATHSEP .. "deep"
      test.ok(system.mkdir(path))
    end
    for i = 1, 100 do test.ok(system.mkdir(c.directory .. PATHSEP .. "empty" .. i)) end
    c.counter:get(c.project, c.directory)
    count_tick(c)
    test.equal(#c.threads, 1)
    test.is_nil(c.counter:get(c.project, c.directory))
    finish_counts(c)
    test.equal(c.counter:get(c.project, c.directory).count, 0)
    local item = { type = "dir", abs_filename = c.directory, project = c.project }
    test.equal(c.view:draw_item_info(item, false, false, 0, 0, 100, 25), 0)
    item.expanded, item.files = true, { { name = "sub", type = "dir" } }
    c.counter:clear(c.project); finish_counts(c)
    test.equal(c.view:draw_item_info(item, false, false, 0, 0, 100, 25), 0)
    test.equal(#c.threads, 0)
  end)

  test.test("collapsing a tree row retains shared watches until counting is disabled", function(c)
    count_file(c, "a/one.lua")
    c.counter:get(c.project, c.directory); finish_counts(c)
    local a = c.directory .. PATHSEP .. "a"
    local item = { type = "dir", abs_filename = a, project = c.project, expanded = true }
    c.view:toggle_expand(false, item)
    test.not_ok(item.expanded)
    test.ok(c.watch.watched[a])
    config.plugins.treeview_filecount.enabled = false
    c.counter:update(); finish_counts(c)
    test.is_nil(c.watch.watched[a])
  end)

  test.test("project removal retires caches and watches for every tree instance", function(c)
    count_file(c, "a/one.lua")
    c.counter:get(c.project, c.directory); finish_counts(c)
    c.projects = core.projects
    core.projects = { table.unpack(c.projects) }
    core.projects[#core.projects + 1] = c.project
    test.equal(core.remove_project(c.project), c.project)
    test.is_nil(c.counter.projects[c.project])
    finish_counts(c)
    test.is_nil(next(c.watch.watched))
  end)

  test.test("cancels old scans on invalidation, policy changes, disablement and project removal", function(c)
    for i = 1, 260 do count_file(c, "file" .. i) end
    c.counter:get(c.project, c.directory); count_tick(c)
    local obsolete = c.counter.projects[c.project]
    count_file(c, "new.lua")
    c.counter:invalidate(c.project, c.directory)
    c.counter:get(c.project, c.directory)
    finish_counts(c)
    test.equal(c.counter:get(c.project, c.directory).count, 261)
    c.project:compile_ignore_files()
    c.counter:update()
    c.counter:get(c.project, c.directory); count_tick(c)
    test.ok(c.counter.projects[c.project] ~= obsolete)
    config.plugins.treeview_filecount.enabled = false
    c.counter:update(); finish_counts(c)
    test.is_nil(c.counter.projects[c.project])
    test.is_nil(next(c.watch.watched))
    test.is_nil(c.counter:get(c.project, c.directory))
    config.plugins.treeview_filecount.enabled = true
    c.counter:get(c.project, c.directory); count_tick(c)
    c.view.watches[c.project] = nil
    c.counter:clear(c.project); finish_counts(c)
    test.is_nil(c.counter.projects[c.project])
    test.is_nil(next(c.watch.watched))
  end)

  test.test("keeps expanded-row watches when counts are disabled", function(c)
    count_file(c, "a/one.lua"); count_file(c, "b/two.lua")
    c.counter:get(c.project, c.directory); finish_counts(c)
    local a, b = c.directory .. PATHSEP .. "a", c.directory .. PATHSEP .. "b"
    c.view.expanded[a] = true
    config.plugins.treeview_filecount.enabled = false
    c.counter:update(); finish_counts(c)
    test.ok(c.watch.watched[a])
    test.is_nil(c.watch.watched[b])
  end)

  test.test("native watches report changes in collapsed counted descendants", function(c)
    count_file(c, "a/one.lua")
    local watch = DirWatch()
    c.view.watches[c.project] = watch
    c.counter:get(c.project, c.directory); finish_counts(c)
    local a = c.directory .. PATHSEP .. "a"
    test.ok(watch.watched[a] or watch.scanned[a])
    -- The native monitor starts asynchronously, as in the dirmonitor tests.
    coroutine.yield(0.1)
    count_file(c, "a/new.lua")
    local changed, deadline = false, system.get_time() + 3
    while not changed and system.get_time() < deadline do
      watch:check(function(path)
        c.view:invalidate_cache(c.project, path)
        -- Parent notifications can precede the descendant's file notification.
        if path == a then changed = true end
      end)
      if not changed then coroutine.yield(0.01) end
    end
    test.ok(changed, "collapsed descendant change was not reported")
    c.counter:get(c.project, c.directory); finish_counts(c)
    test.equal(c.counter:get(c.project, c.directory).count, 2)
    c.view.watches[c.project] = nil
    c.counter:clear(c.project); finish_counts(c)
  end)
end)
