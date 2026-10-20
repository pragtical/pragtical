-- mod-version:3
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local Object = require "core.object"
local DirWatch = require "core.dirwatch"
local command = require "core.command"
local style = require "core.style"

if config.plugins.treeview == false then return end

---@type plugins.treeview_filecount.treeview
local tree = require "plugins.treeview"
---@type plugins.treeview_filecount.treeview
local TreeView = getmetatable(tree)
local counters = setmetatable({}, { __mode = "k" })

---Cancel stale requests for live trees after changing count visibility.
local function refresh_counts()
  for counter in pairs(counters) do counter:update() end
  core.redraw = true
end

---Configuration options for the directory file-count addon.
---@class config.plugins.treeview_filecount
---@field enabled boolean Whether recursive directory counts are shown
config.plugins.treeview_filecount = common.merge({
  enabled = false,
  config_spec = {
    name = "Treeview File Counts",
    {
      label = "Enabled",
      description = "Show recursive file counts beside directories. Counting runs in the background.",
      path = "enabled",
      type = "toggle",
      default = false,
      on_apply = refresh_counts
    }
  }
}, config.plugins.treeview_filecount)

---Completed directory total and its cached presentation.
---@class plugins.treeview_filecount.entry
---@field count? integer Last completed total; nil before the first scan
---@field valid boolean Whether the total reflects the current directory contents
---@field children table<string, boolean> Direct subdirectories in the last scan
---@field text? string Formatted count
---@field font? renderer.font Font used to measure text
---@field font_size? number Last measured font size
---@field width? number Last measured text width

---Per-project traversal cache; replacing it cancels its outstanding jobs.
---@class plugins.treeview_filecount.project
---@field entries table<string, plugins.treeview_filecount.entry>
---@field pending table<string, table> Deduplicated directory requests
---@field watched table<string, boolean> Watches owned by counting
---@field revision integer Cancellation generation within this cache
---@field rules table Compiled project ignore rules
---@field hidden boolean Hidden-file policy
---@field ignored boolean Ignore-file policy
---@field watch? core.dirwatch Shared TreeView directory watcher

---Internal cooperative directory counter, separate from TreeView rendering.
---@class plugins.treeview_filecount : core.object
---@overload fun(owner:plugins.treeview_filecount.treeview):plugins.treeview_filecount
---@field owner plugins.treeview_filecount.treeview Tree owning the cache and shared watches
---@field projects table<core.project, plugins.treeview_filecount.project>
---@field tasks table[] Pending scans and watch cleanup jobs
---@field running boolean Whether the single worker is active
---@field watchers table<core.dirwatch, boolean> Shared watchers whose count ownership is protected
local FileCounts = Object:extend()

---Initialize an idle counter without starting a thread or accessing the filesystem.
---@param owner plugins.treeview_filecount.treeview
function FileCounts:new(owner)
  self.owner = owner
  self.projects, self.tasks = {}, {}
  self.running = false
  self.watchers = setmetatable({}, { __mode = "k" })
  counters[self] = true
end

---Check whether a scan still belongs to the current settings and revision.
---@param project core.project
---@param state plugins.treeview_filecount.project
---@param revision integer
---@return boolean current
function FileCounts:is_current(project, state, revision)
  return config.plugins.treeview_filecount.enabled
    and self.projects[project] == state and state.revision == revision
    and state.rules == project.compiled
    and state.hidden == self.owner.show_hidden
    and state.ignored == self.owner.show_ignored
end

---Release a count-owned watch unless the active cache or an expanded row needs it.
---@param project core.project
---@param state plugins.treeview_filecount.project
---@param path string
---@param removed? boolean Whether the directory disappeared from its parent
function FileCounts:release_watch(project, state, path, removed)
  state.watched[path] = nil
  local current = self.projects[project]
  local item = self.owner.cache[path]
  if current and current ~= state and current.watch == state.watch and current.watched[path] then return end
  if not removed and self.owner.watches[project] == state.watch
    and ((item and item.project == project and item.expanded)
      or self.owner.expanded[path]
      or (path == project.path and self.owner.expanded[path] ~= false))
  then return end
  if state.watch then state.watch:unwatch(path) end
end

---Share TreeView's watcher without allowing collapse to remove count-owned paths.
---Each watcher is wrapped once; retiring a count releases its ownership first.
---@param project core.project Owning project
---@param state plugins.treeview_filecount.project Active count cache
---@param path string Directory to monitor
function FileCounts:watch_directory(project, state, path)
  local watch = state.watch or self.owner.watches[project] or DirWatch()
  state.watch, self.owner.watches[project] = watch, watch
  if not self.watchers[watch] then
    local counter, unwatch = self, watch.unwatch
    ---Release a directory only after the counter has relinquished it.
    ---@param directory string Absolute directory path
    function watch:unwatch(directory)
      local current = counter.projects[project]
      if current and current.watch == self and current.watched[directory] then return end
      return unwatch(self, directory)
    end
    self.watchers[watch] = true
  end
  watch:watch(path)
  state.watched[path] = true
end

---Queue work and start at most one worker. Cleanup also runs when counts are disabled.
---@param task table Scan request, or a retired project cache to clean up
function FileCounts:enqueue(task)
  self.tasks[#self.tasks + 1] = task
  if self.running then return end
  self.running = true
  core.add_thread(function()
    local steps, started = 0, system.get_time()
    ---Bound each cooperative slice, including directories containing no files.
    local function checkpoint()
      steps = steps + 1
      if steps >= 128 or system.get_time() - started >= 0.002 then
        coroutine.yield()
        steps, started = 0, system.get_time()
      end
    end
    local index = 1
    while index <= #self.tasks do
      local job = self.tasks[index]
      if job.cleanup then
        for path in pairs(job.state.watched) do
          self:release_watch(job.project, job.state, path)
          checkpoint()
        end
      elseif job.state.pending[job.path] == job then
        core.try(self.scan, self, job, checkpoint)
        if job.state.pending[job.path] == job then job.state.pending[job.path] = nil end
      end
      self.tasks[index] = false
      index = index + 1
      checkpoint()
    end
    self.tasks, self.running = {}, false
  end)
end

---Discard project caches and arrange yielding cleanup of count-only watches.
---@param project? core.project Omit to discard all projects
function FileCounts:clear(project)
  for candidate, state in pairs(self.projects) do
    if not project or candidate == project then
      self.projects[candidate] = nil
      self:enqueue { project = candidate, state = state, cleanup = true }
    end
  end
end

---Cancel stale requests after a configuration change, without scanning any files.
function FileCounts:update()
  for project, state in pairs(self.projects) do
    if not self:is_current(project, state, state.revision) then self:clear(project) end
  end
end

---Invalidate a changed directory and its ancestors while keeping completed values.
---@param project core.project
---@param path string Directory reported by DirWatch
function FileCounts:invalidate(project, path)
  local state = self.projects[project]
  if not state then return end
  state.revision = state.revision + 1
  while path and (path == project.path or common.path_belongs_to(path, project.path)) do
    local entry = state.entries[path]
    if entry then entry.valid = false end
    if path == project.path then break end
    path = common.dirname(path)
  end
end

---Read the last completed value, queuing a scan when needed. Never traverse here.
---@param project core.project
---@param path string Absolute directory path
---@return plugins.treeview_filecount.entry? entry
function FileCounts:get(project, path)
  if not config.plugins.treeview_filecount.enabled then return end
  local state = self.projects[project]
  if state and not self:is_current(project, state, state.revision) then
    self:clear(project)
    state = nil
  end
  if not state then
    state = {
      entries = {}, pending = {}, watched = {}, revision = 0,
      rules = project.compiled, hidden = self.owner.show_hidden, ignored = self.owner.show_ignored
    }
    self.projects[project] = state
  end
  local entry = state.entries[path]
  local pending = state.pending[path]
  if not (entry and entry.valid) and (not pending or pending.revision ~= state.revision) then
    local job = { project = project, path = path, state = state, revision = state.revision }
    state.pending[path] = job
    self:enqueue(job)
  end
  return entry
end

---Count a subtree iteratively, publishing only completed directory totals.
---Cached descendants are shared by requests; hidden trees pause between entries.
---@param job table Current scan request
---@param checkpoint fun() Cooperative work-budget checkpoint
function FileCounts:scan(job, checkpoint)
  local project, state = job.project, job.state
  local stack = { { path = job.path } }
  while #stack > 0 do
    while not self.owner.visible and self:is_current(project, state, job.revision) do
      coroutine.yield(0.1)
    end
    if not self:is_current(project, state, job.revision) then return end
    local node = stack[#stack]
    local entry = state.entries[node.path]
    if not node.files and entry and entry.valid then
      table.remove(stack)
      if #stack > 0 then stack[#stack].count = stack[#stack].count + entry.count end
    elseif not node.files then
      self:watch_directory(project, state, node.path)
      node.files = system.list_dir(node.path) or {}
      node.index, node.count, node.children = 1, 0, {}
    elseif node.index <= #node.files then
      local name = node.files[node.index]
      node.index = node.index + 1
      if state.hidden or name:sub(1, 1) ~= "." then
        local path = node.path .. PATHSEP .. name
        local info
        if state.ignored then info = system.get_file_info(path)
        else info = project:get_file_info(path) end
        if info and info.type == "file" then
          node.count = node.count + 1
        elseif info and info.type == "dir" and not info.symlink then
          node.children[path] = true
          stack[#stack + 1] = { path = path }
        end
      end
    else
      -- Prune vanished subtrees and their watches without rescanning surviving siblings.
      local removed = {}
      for path in pairs(entry and entry.children or {}) do
        if not node.children[path] then removed[#removed + 1] = path end
        checkpoint()
        if not self:is_current(project, state, job.revision) then return end
      end
      while #removed > 0 do
        local path = table.remove(removed)
        local old = state.entries[path]
        for child in pairs(old and old.children or {}) do
          removed[#removed + 1] = child
          checkpoint()
          if not self:is_current(project, state, job.revision) then return end
        end
        state.entries[path] = nil
        self:release_watch(project, state, path, true)
        checkpoint()
        if not self:is_current(project, state, job.revision) then return end
      end
      entry = entry or { children = {} }
      if entry.count ~= node.count then
        entry.count, entry.text, entry.font = node.count, tostring(node.count), nil
        if state.pending[node.path] then core.redraw = true end
      end
      entry.children, entry.valid = node.children, true
      state.entries[node.path] = entry
      table.remove(stack)
      if #stack > 0 then stack[#stack].count = stack[#stack].count + node.count end
    end
    checkpoint()
  end
end

---@class plugins.treeview_filecount.treeview : plugins.treeview
---@field file_counts plugins.treeview_filecount Counter installed by the file-count addon

---@class plugins.treeview_filecount.item : plugins.treeview.item
---@field has_subdirs? boolean Cached presence of visible directory children

local treeview_new = TreeView.new
---Initialize addon state for subsequently created tree views.
function TreeView:new()
  treeview_new(self)
  self.file_counts = FileCounts(self)
end

tree.file_counts = FileCounts(tree)

local treeview_update = TreeView.update
---Cancel stale count requests before updating the tree's normal layout.
function TreeView:update()
  self.file_counts:update()
  return treeview_update(self)
end

local treeview_invalidate_cache = TreeView.invalidate_cache
---Propagate directory invalidation to count ancestors while preserving sibling totals.
---@param project? core.project Project owning the changed directory
---@param path? string Changed directory; omit for a full cache reset
function TreeView:invalidate_cache(project, path)
  treeview_invalidate_cache(self, project, path)
  if project and path then
    self.file_counts:invalidate(project, path)
  else
    self.file_counts:clear(project)
  end
end

local treeview_draw_item_info = TreeView.draw_item_info
---Draw completed counts to the left of any information supplied by another addon.
---Missing counts only queue work; drawing never traverses the filesystem.
---@param item plugins.treeview_filecount.item Directory or file row
---@param active boolean Whether this row is selected
---@param hovered boolean Whether the pointer is over this row
---@param x number Available information area's left edge
---@param y number Row top in screen coordinates
---@param w number Available information width
---@param h number Row height
---@return number width Total occupied width, including preceding addon information
function TreeView:draw_item_info(item, active, hovered, x, y, w, h)
  local used = treeview_draw_item_info(self, item, active, hovered, x, y, w, h)
  if not config.plugins.treeview_filecount.enabled or item.type ~= "dir" or item.symlink then
    return used
  end
  if item.expanded then
    if item.has_subdirs == nil and item.files then
      item.has_subdirs = false
      for _, file in ipairs(item.files) do
        if file.type == "dir" and (self.show_hidden or file.name:sub(1, 1) ~= ".") then
          item.has_subdirs = true
          break
        end
      end
    end
    if item.has_subdirs then return used end
  end
  local entry = self.file_counts:get(item.project, item.abs_filename)
  if not entry or not entry.count or entry.count == 0 then return used end
  local font = style.font
  if entry.font ~= font or entry.font_size ~= font:get_size() then
    entry.font, entry.font_size = font, font:get_size()
    entry.width = font:get_width(entry.text)
  end
  local preceding = used > 0 and used + style.padding.x or 0
  if preceding > 0 then core.push_clip_rect(x, y, math.max(0, w - preceding), h) end
  renderer.draw_text(font, entry.text, x + w - preceding - entry.width,
    common.round(y + (h - font:get_height()) / 2), style.dim)
  if preceding > 0 then core.pop_clip_rect() end
  return preceding + entry.width
end

local remove_project = core.remove_project
---Retire counts and count-owned watches when a project is actually removed.
---@param project core.project Project to remove
---@param force? boolean Whether removal may close the last project
---@return core.project? removed Removed project, if removal succeeded
function core.remove_project(project, force)
  local removed = remove_project(project, force)
  if removed then
    for counter in pairs(counters) do counter:clear(removed) end
  end
  return removed
end

command.add(nil, {
  ---Toggle count visibility and cancel work belonging to the previous setting.
  ["treeview:toggle-file-counts"] = function()
    config.plugins.treeview_filecount.enabled = not config.plugins.treeview_filecount.enabled
    refresh_counts()
  end
})

core.menu_view:register({ "view", "treeview-options" }, {
  {
    id = "file-counts", text = "Show File Counts", command = "treeview:toggle-file-counts",
    ---Reflect the addon setting when opening or visiting the entry.
    ---@return boolean checked Whether directory file counts are shown
    checked = function() return config.plugins.treeview_filecount.enabled end
  }
}, "treeview_filecount")

return FileCounts
