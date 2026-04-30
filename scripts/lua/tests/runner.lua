local core = require "core"
local common = require "core.common"
local test = require "core.test"

local temp_root

local function write_file(path, content)
  local file, err = io.open(path, "wb")
  test.not_nil(file, err)
  file:write(content)
  file:close()
end

test.describe("test runner", function()
  test.before_each(function(context)
    temp_root = USERDIR
      .. PATHSEP .. "test-runner-tests-"
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

  test.test("captures runtime errors from registered tests", function(context)
    local failing_test = context.temp_root .. PATHSEP .. "runtime_error_test.lua"
    write_file(failing_test, [[
local test = require "core.test"

test.test("raises a runtime error", function()
  local value
  return value.missing_field
end)
]])

    local runner, err = test.run(context.temp_root)
    test.not_nil(runner, err)

    while runner.status == "running" do
      coroutine.yield(0.01)
    end

    test.is_nil(runner.error)
    test.not_nil(runner.results)
    test.equal(runner.status, "failed")
    test.equal(runner.results.total, 1)
    test.equal(runner.results.failed, 1)
    test.equal(runner.results.passed, 0)

    local item = runner.results.items[1]
    test.not_nil(item)
    test.equal(item.status, "failed")
    test.match(item.full_name, "raises a runtime error")
    test.match(item.message, "attempt to index local 'value'")

    local removed, remove_err = os.remove(failing_test)
    test.ok(removed, remove_err)
  end)

  test.test("supports core logging while yielding", function()
    local seen = {}

    for i = 1, 3 do
      core.log("%d", i)
      table.insert(seen, i)
      coroutine.yield(1)
    end

    test.same(seen, { 1, 2, 3 })
  end)

  test.test("reports each result as soon as it completes", function(context)
    local callback_test = context.temp_root .. PATHSEP .. "live_results.lua"
    local seen = {}

    write_file(callback_test, [[
local test = require "core.test"

test.test("passes first", function()
  test.ok(true)
end)

test.test("fails second", function()
  error("boom")
end)
]])

    local runner, err = test.run(context.temp_root, {
      on_result = function(item)
        table.insert(seen, {
          full_name = item.full_name,
          status = item.status
        })
      end
    })
    test.not_nil(runner, err)

    while runner.status == "running" do
      coroutine.yield(0.01)
    end

    test.same(seen, {
      {
        full_name = "live_results.lua > passes first",
        status = "passed"
      },
      {
        full_name = "live_results.lua > fails second",
        status = "failed"
      }
    })

    local removed, remove_err = os.remove(callback_test)
    test.ok(removed, remove_err)
  end)

  test.test("quits on finish and sets failure exit status", function()
    local quit_called = false
    local force_quit
    local exit_code
    local success = test.report({
      total = 1,
      passed = 0,
      failed = 1,
      skipped = 0,
      duration = 0,
      files = {{}},
      items = {}
    }, {
      write = function() end,
      quit_on_finish = true,
      quit = function(force, code)
        quit_called = true
        force_quit = force
        exit_code = code
      end
    })

    test.not_ok(success)
    test.ok(quit_called)
    test.ok(force_quit)
    test.equal(exit_code, 1)
  end)
end)
