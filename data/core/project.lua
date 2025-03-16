local core = require "core"
local common = require "core.common"
local config = require "core.config"
local Object = require "core.object"

---Core projects class.
---@class core.project : core.object
---@overload fun(path:string):core.project
---@field path string
---@field name string
---@field compiled table
local Project = Object:extend()


---Constructor
function Project:new(path)
  self.path = path
  self.name = common.basename(path)
  self:compile_ignore_files()
end


---Inspect config.ignore_files patterns and prepare ready to use entries.
function Project:compile_ignore_files()
  self.compiled = core.get_ignore_file_rules()
end


---The method works like system.absolute_path except it doesn't fail if the
---file does not exist. We consider that the current dir is core.project_dir
---so relative filename are considered to be in core.project_dir.
---
---Please note that .. or . in the filename are not taken into account.
---This function should get only filenames normalized using
---common.normalize_path function.
---@param filename string
---@return string|nil
function Project:absolute_path(filename)
  if common.is_absolute_path(filename) then
    return common.normalize_path(filename)
  elseif not self or not self.path then
    local cwd = system.absolute_path(".")
    return cwd .. PATHSEP .. common.normalize_path(filename)
  else
    return self.path .. PATHSEP .. filename
  end
end


---Same as common.normalize_path() with the addition of making the filename
---relative when it belongs to the project.
---@param filename string|nil
---@return string|nil
function Project:normalize_path(filename)
  filename = common.normalize_path(filename)
  if common.path_belongs_to(filename or "", self.path) then
    filename = common.relative_path(self.path, filename or "")
  end
  return filename
end


---Checks if the given path belongs to the project.
---@param path string
---@return boolean
function Project:path_belongs_to(path)
  if not common.is_absolute_path(path) then
    path = common.normalize_path(self.path .. PATHSEP .. path)
    if not path or not system.get_file_info(path) then
      return false
    end
    return true
  end
  if common.path_belongs_to(path, self.path) then
    return true
  end
  return false
end


local function fileinfo_pass_filter(info, ignore_compiled)
  if info.size >= config.file_size_limit * 1e6 then return false end
  return not common.match_ignore_rule(info.filename, info, ignore_compiled)
end

---Compute a file's info entry completed with "filename" to be used
---in project scan or false if it shouldn't appear in the list.
---@param path string
---@return system.fileinfo|false
function Project:get_file_info(path)
  local info = system.get_file_info(path)
  -- info can be not nil but info.type may be nil if is neither a file neither
  -- a directory, for example for /dev/* entries on linux.
  if info and info.type then
    info.filename = common.relative_path(self.path, path)
    return fileinfo_pass_filter(info, self.compiled) and info or false
  end
  return false
end

local function get_dir_content(project, path, entries)
  local all = system.list_dir(path) or {}
  for _, file in ipairs(all) do
    file = path .. PATHSEP .. file
    local info = project:get_file_info(file)
    if info then
      info.filename = file
      table.insert(entries, info)
    end
  end
end

local function find_files_rec(project, path)
  local entries = {}
  get_dir_content(project, path, entries)

  for _, info in ipairs(entries) do
    if info.type == "file" then
      coroutine.yield(project, info)
    elseif not common.match_pattern(common.basename(info.filename), config.ignore_files) and info.type then
      get_dir_content(project, info.filename, entries)
    end
  end
end

---Returns iterator of all project files.
---@return fun():core.project,string
function Project:files()
  return coroutine.wrap(function()
    find_files_rec(self, self.path)
  end)
end


return Project
