local common = require "core.common"
local test = require "core.test"

local temp_root

test.describe("dirmonitor", function()
  test.before_each(function(context)
    temp_root = USERDIR
      .. PATHSEP .. "dirmonitor-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    local ok, err = common.mkdirp(temp_root)
    test.ok(ok, err)
    context.temp_root = temp_root
  end)

  test.after_each(function(context)
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  test.test("exports the documented functions", function()
    test.type(dirmonitor.new, "function")
    local monitor = dirmonitor.new()
    test.type(monitor.watch, "function")
    test.type(monitor.unwatch, "function")
    test.type(monitor.check, "function")
    test.type(monitor.mode, "function")
    test.type(dirmonitor.backends, "function")
  end)

  test.test("creates monitors and basic watches", function(context)
    local monitor = dirmonitor.new()
    test.not_nil(monitor)

    local mode = monitor:mode()
    test.ok(mode == "single" or mode == "multiple")

    local backends = dirmonitor.backends()
    test.type(backends, "table")
    test.ok(#backends > 0 or next(backends) ~= nil)

    local watch_id = monitor:watch(context.temp_root)
    test.type(watch_id, "number")

    local ok, err = monitor:check(function() end, function(check_err)
      error(check_err)
    end)
    test.ok(ok == nil or type(ok) == "boolean", err)

    if mode == "single" then
      monitor:unwatch(context.temp_root)
    else
      monitor:unwatch(watch_id)
    end
  end)
end)
