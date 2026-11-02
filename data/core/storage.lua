local core = require "core"
local common = require "core.common"

local function module_key_to_path(module, key, project)
  local base = USERDIR .. PATHSEP .. "storage"
  if project ~= nil then
    if type(project) == "string" then
      base = project
    else
      assert(type(project) == "table" and type(project.path) == "string",
        "expected a project object or storage directory")
      assert(project.path ~= "", "invalid project directory")
      base = project.path .. PATHSEP .. ".pragtical"
    end
    assert(base ~= "" and not base:find("%z"), "invalid storage directory")
    for _, name in pairs({ module = module, key = key and key:gsub("[\\/]", "-") }) do
      assert(type(name) == "string" and name ~= "" and name ~= "." and name ~= ".."
        and not name:find("[\\/%z]"), "invalid storage module or key")
    end
  end
  return base .. (module and (PATHSEP .. module .. (key and (PATHSEP .. key:gsub("[\\/]", "-")) or "")) or "")
end


-- Project files are untrusted. Admit only the literals common.serialize emits
-- before passing them to Lua's parser; no names, calls, statements or bytecode.
local function load_project(path)
  local file, err = io.open(path, "rb")
  if not file then return nil, err end
  local text = file:read(16777217)
  file:close()
  if not text or #text > 16777216 then return nil, "storage exceeds 16 MB" end
  local position, depth, count, previous = 1, 0, 0, nil
  local function value_position()
    return previous == "return" or previous == "=" or previous == "["
      or previous == "," or previous == "{"
  end
  while position <= #text do
    local char = text:sub(position, position)
    if char:match("%s") then position = position + 1
    else
      count = count + 1
      if count > 1000000 then return nil, "storage exceeds its literal limit" end
      if char == '"' or char == "'" then
        if not value_position() then return nil, "invalid storage literal position" end
        local quote = char
        position = position + 1
        while true do
          local ending = text:find("[" .. quote .. "\\]", position)
          if not ending then return nil, "unterminated storage string" end
          if text:sub(ending, ending) == quote then position = ending + 1; break end
          position = ending + 2
        end
        previous = "literal"
      elseif char:match("[{}%[%],=]") then
        if char == "{" and not value_position() or char == "[" and previous ~= "{" and previous ~= "," then
          return nil, "invalid storage constructor"
        end
        if char == "{" or char == "[" then depth = depth + 1
        elseif char == "}" or char == "]" then depth = depth - 1 end
        if depth < 0 or depth > 128 then return nil, "invalid storage nesting" end
        previous, position = char, position + 1
      else
        local _, ending, word
        if char:match("[%d%-%(]") then
          if not value_position() then
            return nil, "storage must contain serialized literals only"
          end
          -- Infinity and NaN use fixed arithmetic literals in common.serialize.
          for _, literal in ipairs({ "-(0/0)", "(0/0)", "-1/0", "1/0", "0/0" }) do
            if text:sub(position, position + #literal - 1) == literal then ending = position + #literal - 1; break end
          end
          if not ending then _, ending = text:find("^%-?%d+%.?%d*[eE][+-]?%d+", position) end
          if not ending then _, ending = text:find("^%-?%d+%.?%d*", position) end
        else
          _, ending, word = text:find("^(%a+)", position)
          if not ((word == "true" or word == "false" or word == "nil") and value_position()
            or word == "return" and previous == nil) then ending = nil end
        end
        if not ending then return nil, "storage must contain serialized literals only" end
        previous, position = word or "literal", ending + 1
      end
    end
  end
  if depth ~= 0 then return nil, "invalid storage nesting" end
  return load(text, "@" .. path, "t", {})
end


---Provides persistent storage between restarts of the application.
---Without a project, files live in USERDIR/storage/module/key. A project
---object uses project.path/.pragtical/module/key; a string is the storage
---base directory itself. Project/explicit-directory files contain serialized
---data only, not executable Lua. Keys are filenames; extensions are not added.
---Project loads are bounded to 16 MB, one million literals and nesting of 128.
---@class storage
local storage = {}


---Loads data from a persistent storage file.
---
---@param module string The module under which the data is stored.
---@param key string The key under which the data is stored.
---@param project? core.project|string Project object, or an explicit storage directory.
---@return string|table|number|boolean|nil data The stored data present for this module, at this key.
---@return string? error An error loading an existing file; nil when no file exists.
function storage.load(module, key, project)
  local path = module_key_to_path(module, key, project)
  if system.get_file_info(path) then
    local func, err
    if project ~= nil then func, err = load_project(path) else func, err = loadfile(path) end
    if func then
      if project == nil then return func() end
      local ok, value = pcall(func)
      if ok then return value end
      err = value
    end
    core.error("error loading storage file for %s[%s]: %s", module, key, err)
    return nil, err
  end
  return nil
end


---Saves data to a persistent storage file.
---
---@param module string The module under which the data is stored.
---@param key string The key under which the data is stored.
---@param value table|string|number|boolean|nil The value to store.
---@param project? core.project|string Project object, or an explicit storage directory.
---@return boolean saved Whether the file was written and closed successfully.
function storage.save(module, key, value, project)
  local path = module_key_to_path(module, key, project)
  local dir = common.dirname(path)
  if not system.get_file_info(dir) then
    local status, err = common.mkdirp(dir)
    if not status then
      core.error("error creating storage directory for %s at %s: %s", module, dir, err)
      return false
    end
  end
  local content = "return " .. common.serialize(value, {pretty = true})
  local f, err = io.open(path, "wb")
  if f then
    local written, write_error = f:write(content)
    local closed, close_error = f:close()
    if not written or not closed then
      core.error("error writing storage file %s: %s", path, write_error or close_error)
      return false
    end
    return true
  else
    core.error("error opening storage file %s for writing: %s", path, err)
    return false
  end
end


---Gets the list of keys saved under a module.
---
---@param module string The module under which the data is stored.
---@param project? core.project|string Project object, or an explicit storage directory.
---@return table A table of keys under which data is stored for this module.
function storage.keys(module, project)
  return system.list_dir(module_key_to_path(module, nil, project)) or {}
end


---Clears data for a particular module and optionally key.
---
---@param module string The module under which the data is stored.
---@param key? string The key under which the data is stored. If omitted, will clear the entire store for this module.
---@param project? core.project|string Project object, or an explicit storage directory.
function storage.clear(module, key, project)
  assert(project == nil or module ~= nil, "clearing project storage requires a module")
  local path = module_key_to_path(module, key, project)
  if system.get_file_info(path) then
    common.rm(path, true)
  end
end


return storage
