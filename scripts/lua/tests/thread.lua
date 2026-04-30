local test = require "core.test"

test.describe("thread", function()
  test.test("exports the documented functions", function()
    for _, name in ipairs({"create", "get_channel", "get_cpu_count"}) do
      test.type(thread[name], "function", "missing thread." .. name)
    end
  end)

  test.test("supports channel fifo operations", function()
    local channel = thread.get_channel("thread-tests-basic")
    test.not_nil(channel)
    channel:clear()

    test.ok(channel:push("first"))
    test.ok(channel:push("second"))
    test.equal(channel:first(), "first")
    test.equal(channel:last(), "second")
    channel:pop()
    test.equal(channel:wait(), "second")
    channel:clear()
    test.is_nil(channel:first())
    test.type(tostring(channel), "string")
  end)

  test.test("creates threads and exchanges data", function()
    local suffix = tostring(system.get_process_id()) .. "-" .. math.floor(system.get_time() * 1000000)
    local push_channel_name = "thread-tests-push-" .. suffix
    local push_channel = thread.get_channel(push_channel_name)
    push_channel:clear()

    local worker, err = thread.create("push-worker", function(channel_name)
      local channel = thread.get_channel(channel_name)
      channel:push("ready")
      return 7
    end, push_channel_name)
    test.not_nil(worker, err)
    test.equal(worker:get_name(), "push-worker")
    test.type(worker:get_id(), "number")
    test.equal(push_channel:wait(), "ready")
    test.equal(worker:wait(), 7)
    test.type(tostring(worker), "string")

    local supply_channel_name = "thread-tests-supply-" .. suffix
    local supply_channel = thread.get_channel(supply_channel_name)
    supply_channel:clear()

    local supply_worker = thread.create("supply-worker", function(channel_name)
      local channel = thread.get_channel(channel_name)
      channel:wait()
      return 11
    end, supply_channel_name)
    test.not_nil(supply_worker)
    test.ok(supply_channel:supply("payload"))
    test.equal(supply_channel:first(), "payload")
    test.equal(supply_worker:wait(), 11)
    test.ok(thread.get_cpu_count() > 0)
  end)
end)
