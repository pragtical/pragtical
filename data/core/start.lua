-- this file is used by pragtical to setup the Lua environment when starting
VERSION = "@PROJECT_VERSION@"
MOD_VERSION_MAJOR = tonumber("@MOD_VERSION_MAJOR@")
MOD_VERSION_MINOR = tonumber("@MOD_VERSION_MINOR@")
MOD_VERSION_PATCH = tonumber("@MOD_VERSION_PATCH@")
MOD_VERSION_STRING = string.format("%d.%d.%d", MOD_VERSION_MAJOR, MOD_VERSION_MINOR, MOD_VERSION_PATCH)
LUA_VERSION = tonumber(_VERSION:sub(-3))

DEFAULT_SCALE = 1.0
SCALE = 1.0
PATHSEP = package.config:sub(1, 1)

EXEDIR = EXEFILE:match("^(.+)[/\\][^/\\]+$")
if MACOS_RESOURCES then
  DATADIR = MACOS_RESOURCES
else
  local prefix = os.getenv('PRAGTICAL_PREFIX') or EXEDIR:match("^(.+)[/\\]bin$")
  DATADIR = prefix and (prefix .. PATHSEP .. 'share' .. PATHSEP .. 'pragtical') or (EXEDIR .. PATHSEP .. 'data')
end
USERDIR = (system.get_file_info(EXEDIR .. PATHSEP .. 'user') and (EXEDIR .. PATHSEP .. 'user'))
       or os.getenv("PRAGTICAL_USERDIR")
       or ((os.getenv("XDG_CONFIG_HOME") and os.getenv("XDG_CONFIG_HOME") .. PATHSEP .. "pragtical"))
       or (HOME and (HOME .. PATHSEP .. '.config' .. PATHSEP .. 'pragtical'))

package.path = DATADIR .. '/?.lua;'
package.path = DATADIR .. '/?/init.lua;' .. package.path
package.path = USERDIR .. '/?.lua;' .. package.path
package.path = USERDIR .. '/?/init.lua;' .. package.path

-- Load compatibility changes when running in LuaJIT or PUC Lua < 5.3
if LUA_VERSION < 5.3 then
  require "core.jitsetup"
  COMPAT_DISABLE_FIX_PATTERN = true
  require "compat"
else
  require "core.bit"
end

local suffix = PLATFORM == "Windows" and 'dll' or 'so'
package.cpath =
  USERDIR .. '/?.' .. ARCH .. "." .. suffix .. ";" ..
  USERDIR .. '/?/init.' .. ARCH .. "." .. suffix .. ";" ..
  USERDIR .. '/?.' .. suffix .. ";" ..
  USERDIR .. '/?/init.' .. suffix .. ";" ..
  DATADIR .. '/?.' .. ARCH .. "." .. suffix .. ";" ..
  DATADIR .. '/?/init.' .. ARCH .. "." .. suffix .. ";" ..
  DATADIR .. '/?.' .. suffix .. ";" ..
  DATADIR .. '/?/init.' .. suffix .. ";"

package.native_plugins = {}
table.insert(package.searchers, 1, function(modname)
  local path, err = package.searchpath(modname, package.cpath)
  if not path then return err end
  if not LUAJIT then
    return system.load_native_plugin, path
  else
    return function() return system.load_native_plugin(modname, path) end
  end
end)

table.pack = table.pack or pack or function(...) return {...} end
table.unpack = table.unpack or unpack

local lua_require = require
local require_stack = { "" }
---Loads the given module, returns any value returned by the searcher (`true` when `nil`).
---Besides that value, also returns as a second result the loader data returned by the searcher,
---which indicates how `require` found the module.
---(For instance, if the module came from a file, this loader data is the file path.)
---
---This is a variant that also supports relative imports.
---
---For example `require ".b"` will require `b` in the same path of the current
---file.
---This also supports multiple levels traversal. For example `require "...b"`
---will require `b` from two levels above the current one.
---This method has a few caveats: it uses the last `require` call to get the
---current "path", so this only works if the relative `require` is called inside
---its parent `require`.
---Calling a relative `require` in a function called outside the parent
---`require`, will result in the wrong "path" being used.
---
---It's possible to save the current "path" with `get_current_require_path`
---called inside the parent `require`, and use its return value to populate
---future requires.
---@see get_current_require_path
---@param modname string
---@return unknown
---@return unknown loaderdata
function require(modname, ...)
  if modname then
    local level, rel_path = string.match(modname, "^(%.*)(.*)")
    level = #(level or "")
    if level > 0 then
      if #require_stack == 0 then
        return error("Require stack underflowed.")
      else
        local base_path = require_stack[#require_stack]
        while level > 1 do
          base_path = string.match(base_path, "^(.*)%.") or ""
          level = level - 1
        end
        modname = base_path
        if #base_path > 0 then
          modname = modname .. "."
        end
        modname = modname .. rel_path
      end
    end
  end

  table.insert(require_stack, modname)
  local ok, result, loaderdata = pcall(lua_require, modname, ...)
  table.remove(require_stack)

  if not ok then
    return error(result)
  end
  return result, loaderdata
end

---Returns the current `require` path.
---@see require for details and caveats
---@return string
function get_current_require_path()
  return require_stack[#require_stack]
end

require "core.encoding"
require "core.utf8string"
require "core.process"

-- Because AppImages change the working directory before running the executable,
-- we need to change it back to the original one.
-- https://github.com/AppImage/AppImageKit/issues/172
-- https://github.com/AppImage/AppImageKit/pull/191
local appimage_owd = os.getenv("OWD")
if os.getenv("APPIMAGE") and appimage_owd then
  system.chdir(appimage_owd)
end

-- Temporary SDL3 compatibility PLATFORM correction on macOS
if PLATFORM == "macOS"  then PLATFORM = "Mac OS X" end

-- Manually add /usr/local/bin to the PATH environment variable if needed.
-- On Mac OS X package managers like brew install binaries into /usr/local/bin
-- but this location is not globally added to the PATH environment variable.
if PLATFORM == "Mac OS X" then
  local path_list = {"/usr/local/sbin", "/usr/local/bin"}
  local system_path = os.getenv("PATH")
  for _, local_bin_path in ipairs(path_list) do
    if system_path and not system_path:match(local_bin_path) then
      local path_info = system.get_file_info(local_bin_path)
      if path_info and path_info.type == "dir" then
        system_path = local_bin_path .. ":" .. system_path
        system.setenv("PATH", system_path)
      end
    end
  end
end
