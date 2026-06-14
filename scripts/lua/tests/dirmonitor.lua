local common = require "core.common"
local test = require "core.test"

local temp_root
local temp_index = 0

local function write_file(path, content)
  local file, err = io.open(path, "wb")
  test.not_nil(file, err)
  file:write(content)
  file:close()
end

local function wait(wait_time)
  if coroutine.isyieldable() then
    coroutine.yield(wait_time)
  else
    system.sleep(wait_time)
  end
end

local function wait_for_changes(monitor, callback, timeout)
  local deadline = system.get_time() + (timeout or 2)
  local changed = false
  while system.get_time() < deadline do
    local ok, err = monitor:check(function(value)
      changed = true
      if callback then callback(value) end
    end, function(check_err)
      error(check_err)
    end)
    test.ok(ok == nil or type(ok) == "boolean", err)
    if changed then return true end
    wait(0.01)
  end
  return false
end

local function wait_for_watch()
  local deadline = system.get_time() + 0.1
  repeat wait(0.01) until system.get_time() >= deadline
end

test.describe("dirmonitor", function()
  test.before_each(function(context)
    temp_index = temp_index + 1
    temp_root = USERDIR
      .. PATHSEP .. "dirmonitor-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000) .. "-"
      .. temp_index
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

  test.test("detects watched file replacement", function(context)
    local path = context.temp_root .. PATHSEP .. "watched.txt"
    local temp_path = context.temp_root .. PATHSEP .. "watched.tmp"
    write_file(path, "before\n")

    local monitor = dirmonitor.new()
    local watch_path = monitor:mode() == "single" and context.temp_root or path
    local watch_id = monitor:watch(watch_path)
    test.type(watch_id, "number")
    test.ok(watch_id >= 0)
    wait_for_watch()

    write_file(temp_path, "after\n")
    if PLATFORM == "Windows" then os.remove(path) end
    local ok, err = os.rename(temp_path, path)
    test.ok(ok, err)

    test.ok(wait_for_changes(monitor, nil, 2), "expected file replacement change")

    if monitor:mode() == "single" then
      monitor:unwatch(watch_path)
    else
      monitor:unwatch(watch_id)
    end
  end)

  test.test("reports changes from separate watched directories", function(context)
    local one = context.temp_root .. PATHSEP .. "one"
    local two = context.temp_root .. PATHSEP .. "two"
    test.ok(common.mkdirp(one))
    test.ok(common.mkdirp(two))

    local monitor = dirmonitor.new()
    local watch_one = monitor:watch(monitor:mode() == "single" and context.temp_root or one)
    local watch_two = monitor:mode() == "single" and watch_one or monitor:watch(two)
    test.type(watch_one, "number")
    test.type(watch_two, "number")
    test.ok(watch_one >= 0)
    test.ok(watch_two >= 0)
    wait_for_watch()

    if monitor:mode() == "multiple" then
      write_file(one .. PATHSEP .. "first-file-with-a-long-name.txt", "one\n")
      write_file(two .. PATHSEP .. "second-file-with-a-long-name.txt", "two\n")
    else
      write_file(context.temp_root .. PATHSEP .. "first-file-with-a-long-name.txt", "one\n")
      write_file(context.temp_root .. PATHSEP .. "second-file-with-a-long-name.txt", "two\n")
    end

    local seen = {}
    local deadline = system.get_time() + 2
    while system.get_time() < deadline and not (seen[watch_one] and seen[watch_two]) do
      wait_for_changes(monitor, function(value)
        seen[value] = true
      end, 0.1)
    end

    if monitor:mode() == "multiple" then
      test.ok(seen[watch_one], "expected first directory change")
      test.ok(seen[watch_two], "expected second directory change")
      monitor:unwatch(watch_one)
      monitor:unwatch(watch_two)
    else
      test.ok(next(seen) ~= nil, "expected directory change")
      monitor:unwatch(context.temp_root)
    end
  end)
end)
