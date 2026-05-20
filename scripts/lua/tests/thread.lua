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

  test.test("supply returns after pop consumes the value", function()
    local suffix = tostring(system.get_process_id()) .. "-" .. math.floor(system.get_time() * 1000000)
    local channel_name = "thread-tests-supply-pop-" .. suffix
    local channel = thread.get_channel(channel_name)
    channel:clear()

    -- Worker uses pop() instead of wait() to consume the value.
    -- Before the fix, supply() would block forever because pop()
    -- did not increment the received counter.
    local worker = thread.create("supply-pop-worker", function(cn)
      local ch = thread.get_channel(cn)
      -- Wait until a value appears, then pop it
      ch:wait()
      ch:pop()
      return 42
    end, channel_name)
    test.not_nil(worker)

    -- supply should return once the worker has consumed the value
    test.ok(channel:supply("item"))
    test.equal(worker:wait(), 42)
  end)

  test.test("wait and pop only acknowledge a supplied value once", function()
    local suffix = tostring(system.get_process_id()) .. "-" .. math.floor(system.get_time() * 1000000)
    local data_name = "thread-tests-supply-ack-data-" .. suffix
    local consumer_status_name = "thread-tests-supply-ack-consumer-" .. suffix
    local supplier_status_name = "thread-tests-supply-ack-supplier-" .. suffix
    local control_name = "thread-tests-supply-ack-control-" .. suffix
    local data = thread.get_channel(data_name)
    local consumer_status = thread.get_channel(consumer_status_name)
    local supplier_status = thread.get_channel(supplier_status_name)
    local control = thread.get_channel(control_name)
    data:clear()
    consumer_status:clear()
    supplier_status:clear()
    control:clear()

    local consumer = thread.create("supply-ack-consumer", function(dn, csn, cn)
      local ch = thread.get_channel(dn)
      local status = thread.get_channel(csn)
      local ctrl = thread.get_channel(cn)

      ch:wait()
      ch:pop()
      status:push("first")

      ctrl:wait()
      ctrl:pop()

      ch:wait()
      ch:pop()
      status:push("second")
      return 0
    end, data_name, consumer_status_name, control_name)
    test.not_nil(consumer)

    test.ok(data:supply("one"))
    test.equal(consumer_status:wait(), "first")
    consumer_status:pop()

    local supplier = thread.create("supply-ack-supplier", function(dn, ssn)
      local ch = thread.get_channel(dn)
      local status = thread.get_channel(ssn)
      status:push("started")
      ch:supply("two")
      status:push("returned")
      return 0
    end, data_name, supplier_status_name)
    test.not_nil(supplier)

    test.equal(supplier_status:wait(), "started")
    supplier_status:pop()

    for _ = 1, 100 do
      if data:first() == "two" or supplier_status:first() == "returned" then
        break
      end
      coroutine.yield()
    end

    test.equal(data:first(), "two")
    for _ = 1, 20 do
      if supplier_status:first() == "returned" then
        break
      end
      coroutine.yield(0.01)
    end
    test.is_nil(supplier_status:first())

    control:push("go")
    test.equal(supplier_status:wait(), "returned")
    supplier_status:pop()
    test.equal(consumer_status:wait(), "second")
    consumer_status:pop()
    test.equal(supplier:wait(), 0)
    test.equal(consumer:wait(), 0)
  end)

  test.test("many producers can push to the same channel", function()
    local suffix = tostring(system.get_process_id()) .. "-" .. math.floor(system.get_time() * 1000000)
    local channel_name = "thread-tests-many-producers-" .. suffix
    local channel = thread.get_channel(channel_name)
    channel:clear()

    local producer_count = 8
    local per_producer = 25
    local total = producer_count * per_producer
    local workers = {}

    for i = 1, producer_count do
      local worker = thread.create("many-push-" .. i, function(cn, idx, count)
        local ch = thread.get_channel(cn)
        idx = math.floor(idx)
        count = math.floor(count)
        for n = 1, count do
          ch:push(idx .. ":" .. n)
        end
        return count
      end, channel_name, i, per_producer)
      test.not_nil(worker)
      workers[i] = worker
    end

    local seen = {}
    local received = 0
    for _ = 1, total do
      local value = channel:wait()
      channel:pop()
      test.type(value, "string")
      test.is_nil(seen[value])
      seen[value] = true
      received = received + 1
    end

    for i = 1, producer_count do
      test.equal(workers[i]:wait(), per_producer)
    end

    test.equal(received, total)
    test.is_nil(channel:first())
  end)

  test.test("many suppliers unblock after one consumer reads their values", function()
    local suffix = tostring(system.get_process_id()) .. "-" .. math.floor(system.get_time() * 1000000)
    local data_name = "thread-tests-many-suppliers-data-" .. suffix
    local data = thread.get_channel(data_name)
    data:clear()

    local supplier_count = 6
    local per_supplier = 12
    local total = supplier_count * per_supplier

    local consumer = thread.create("many-supply-consumer", function(cn, count)
      local ch = thread.get_channel(cn)
      count = math.floor(count)
      for _ = 1, count do
        ch:wait()
        ch:pop()
      end
      return count
    end, data_name, total)
    test.not_nil(consumer)

    local suppliers = {}
    for i = 1, supplier_count do
      local supplier = thread.create("many-supply-" .. i, function(cn, idx, count)
        local ch = thread.get_channel(cn)
        idx = math.floor(idx)
        count = math.floor(count)
        for n = 1, count do
          ch:supply(idx .. ":" .. n)
        end
        return count
      end, data_name, i, per_supplier)
      test.not_nil(supplier)
      suppliers[i] = supplier
    end

    for i = 1, supplier_count do
      test.equal(suppliers[i]:wait(), per_supplier)
    end

    test.equal(consumer:wait(), total)
    test.is_nil(data:first())
  end)

  test.test("thread methods are safe after wait", function()
    local suffix = tostring(system.get_process_id()) .. "-" .. math.floor(system.get_time() * 1000000)
    local channel_name = "thread-tests-post-wait-" .. suffix
    local channel = thread.get_channel(channel_name)
    channel:clear()

    local worker = thread.create("post-wait-worker", function(cn)
      local ch = thread.get_channel(cn)
      ch:push("done")
      return 99
    end, channel_name)
    test.not_nil(worker)

    -- Consume the channel value so the worker can finish
    test.equal(channel:wait(), "done")
    test.equal(worker:wait(), 99)

    -- After wait(), the SDL_Thread pointer is NULLed out.
    -- These should not crash; they return nil or safe values.
    test.is_nil(worker:get_id())
    test.is_nil(worker:get_name())
    test.type(tostring(worker), "string")
  end)

  test.test("concurrent channel access does not crash", function()
    local suffix = tostring(system.get_process_id()) .. "-" .. math.floor(system.get_time() * 1000000)
    local channel_name = "thread-tests-concurrent-" .. suffix
    local channel = thread.get_channel(channel_name)
    channel:clear()

    -- Spawn multiple threads that all push to the same channel
    local count = 4
    local workers = {}
    for i = 1, count do
      local w = thread.create("concurrent-push-" .. i, function(cn, idx)
        local ch = thread.get_channel(cn)
        ch:push("value-" .. idx)
        return idx
      end, channel_name, i)
      test.not_nil(w)
      workers[i] = w
    end

    -- Read all values back via wait (blocks until each is available)
    local values = {}
    for i = 1, count do
      local v = channel:wait()
      table.insert(values, v)
      channel:pop()
    end

    -- All workers should finish cleanly
    for i = 1, count do
      test.type(workers[i]:wait(), "number")
    end

    -- We should have received exactly 'count' values
    test.equal(#values, count)
  end)
end)
