-- this file is used by pragtical to setup the Lua environment when starting
VERSION = "@PROJECT_VERSION@"
MOD_VERSION_MAJOR = 3
MOD_VERSION_MINOR = 5
MOD_VERSION_PATCH = 0
MOD_VERSION_STRING = string.format("%d.%d.%d", MOD_VERSION_MAJOR, MOD_VERSION_MINOR, MOD_VERSION_PATCH)

DEFAULT_SCALE = system.get_scale()
SCALE = tonumber(os.getenv("PRAGTICAL_SCALE")) or DEFAULT_SCALE
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

-- load compatibility changes when running in luajit
if LUAJIT then
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
