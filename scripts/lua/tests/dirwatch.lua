local common = require "core.common"
local DirWatch = require "core.dirwatch"
local test = require "core.test"

local temp_root

local function write_file(path, content)
  local file, err = io.open(path, "wb")
  test.not_nil(file, err)
  file:write(content)
  file:close()
end

test.describe("dirwatch", function()
  test.before_each(function(context)
    temp_root = USERDIR
      .. PATHSEP .. "dirwatch-tests-"
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

  test.test("unwatch clears multiple mode reverse watch mapping", function(context)
    local path = context.temp_root .. PATHSEP .. "watched.txt"
    write_file(path, "before\n")

    local watch = DirWatch()
    if watch.monitor:mode() ~= "multiple" then
      return
    end

    watch:watch(path)
    local watch_id = watch.watched[path]
    test.type(watch_id, "number")
    test.equal(watch.reverse_watched[watch_id], path)

    watch:unwatch(path)
    test.equal(watch.watched[path], nil)
    test.equal(watch.reverse_watched[watch_id], nil)
  end)
end)
