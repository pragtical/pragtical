local core = require "core"
local config = require "core.config"
local common = require "core.common"
local Object = require "core.object"


---A wrapper around `dirmonitor` for filesystem monitoring that automatically
---takes care of the native backend differences and provides some ease of use.
---
---It can be used to watch changes in files and directories.
---The user repeatedly calls DirWatch:check() with a callback inside a coroutine.
---If a file or directory had changed, the callback is called with the corresponding file.
---@class core.dirwatch
---@overload fun():core.dirwatch
---@field scanned table<string,number> Stores the last modified time of paths.
---@field watched table<string,boolean|number> Stores the paths that are being watched, and their unique fd.
---@field reverse_watched table<number,string> Stores the paths mapped by their unique fd.
---@field monitor dirmonitor The dirmonitor instance associated with this watcher.
---@field single_watch_top string The first file that is being watched.
---@field single_watch_count number Number of files that are being watched.
local DirWatch = Object:extend()


---Constructor.
function DirWatch:new()
  self.scanned = {}
  self.watched = {}
  self.reverse_watched = {}
  self.last_modified = {}
  local ok, monitor = pcall(dirmonitor.new, config.dirmonitor_backend)
  if not ok then
    monitor = dirmonitor.new()
    core.error("Couldn't initialize directory watch with %s backend", config.dirmonitor_backend)
  end
  self.monitor = monitor
  self.single_watch_top = nil
  self.single_watch_count = 0
end


---Similar to `DirWatch:watch` but not using the native `dirmonitor` backends
---and instead relying on continuous file timestamps monitoring which is slower,
---should not be used unless necessary.
---
---Adding a directory using this function will not report child changes.
---@param path string
---@param  watch? boolean If false, remove this directory from the watch list.
function DirWatch:scan(path, watch)
  if watch == false then return self:unwatch(path) end
  self.scanned[path] = system.get_file_info(path).modified
end


---Watches a path.
---
---It is recommended to call this function on every subdirectory if the given path
---points to a directory. This is not required for Windows, but should be done to ensure
---cross-platform compatibility.
---
---Using this function on individual files is possible, but discouraged as it can cause
---system resource exhaustion.
---@param path string The path to watch. This should be an absolute path.
---@param watch? boolean If false, the path is removed from the watch list.
function DirWatch:watch(path, watch)
  if watch == false then return self:unwatch(path) end
  local info = system.get_file_info(path)
  if not info then return end
  if not self.watched[path] and not self.scanned[path] then
    if self.monitor:mode() == "single" then
      if info.type ~= "dir" then return self:scan(path) end
      if not self.single_watch_top or path:find(self.single_watch_top, 1, true) ~= 1 then
        -- Get the highest level of directory that is common to this directory, and the original.
        local target = path
        while self.single_watch_top and self.single_watch_top:find(target, 1, true) ~= 1 do
          target = common.dirname(target)
        end
        if target ~= self.single_watch_top then
          local value = self.monitor:watch(target)
          if value and value < 0 then
            return self:scan(path)
          end
          self.single_watch_top = target
        end
      end
      self.single_watch_count = self.single_watch_count + 1
      self.watched[path] = true
    else
      local value = self.monitor:watch(path)
      -- If for whatever reason, we can't watch this directory, revert back to scanning.
      -- Don't bother trying to find out why, for now.
      if value and value < 0 then
        return self:scan(path)
      end
      self.watched[path] = value
      self.reverse_watched[value] = path
    end
  end
end


---Removes a path from the watch or scan list.
---@param path string The path to remove. This should be an absolute path.
function DirWatch:unwatch(path)
  if self.watched[path] then
    if self.monitor:mode() == "multiple" then
      self.monitor:unwatch(self.watched[path])
      self.reverse_watched[path] = nil
    else
      self.single_watch_count = self.single_watch_count - 1
      if self.single_watch_count == 0 then
        self.single_watch_top = nil
        self.monitor:unwatch(path)
      end
    end
    self.watched[path] = nil
  elseif self.scanned[path] then
    self.scanned[path] = nil
  end
end


---Checks each watched paths for changes.
---This function must be called in a coroutine, e.g. inside a thread created with `core.add_thread()`.
---@param change_callback fun(path: string)
---@param scan_time? number Maximum amount of time, in seconds, before the function yields execution.
---@param wait_time? number The duration to yield execution (in seconds).
---@return boolean # If true, a path had changed.
function DirWatch:check(change_callback, scan_time, wait_time)
  local had_change = false
  local last_error
  self.monitor:check(function(id)
    had_change = true
    if self.monitor:mode() == "single" then
      local path = common.dirname(id)
      if not string.match(id, "^/") and not string.match(id, "^%a:[/\\]") then
        path = common.dirname(self.single_watch_top .. PATHSEP .. id)
      end
      change_callback(path)
    elseif self.reverse_watched[id] then
      local path = self.reverse_watched[id]
      local last_modified = self.last_modified[path]
      local info = system.get_file_info(path)
      if last_modified then
        self.last_modified[path] = nil
        if info and info.modified == last_modified then
          return
        end
      end
      change_callback(path)
      -- The watch may get lost when a file is deleted and re-added, eg:
      -- git checkout <branch>. We register modified timestamp to prevent
      -- sending unnecessary notifications or duplicating them.
      if info and info.type == "file" then
        self:unwatch(path)
        self:watch(path)
        self.last_modified[path] = info.modified
      end
    end
  end, function(err)
    last_error = err
  end)
  if last_error ~= nil then error(last_error) end
  local start_time = system.get_time()
  for directory, old_modified in pairs(self.scanned) do
    if old_modified then
      local info = system.get_file_info(directory)
      local new_modified = info and info.modified
      if old_modified ~= new_modified then
        change_callback(directory)
        had_change = true
        self.scanned[directory] = new_modified
      end
    end
    if system.get_time() - start_time > (scan_time or 0.01) then
      coroutine.yield(wait_time or 0.01)
      start_time = system.get_time()
    end
  end
  return had_change
end


---Unwatch all files/directories that weren't manually unwatch.
function DirWatch:__gc()
  if self.monitor:mode() == "multiple"then
    for path, watched in pairs(self.watched) do
      if watched then self:unwatch(path) end
    end
  end
end


return DirWatch
