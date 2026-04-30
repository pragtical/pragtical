local test = require "core.test"

test.describe("shmem", function()
  test.test("exports the documented functions", function()
    test.type(shmem.open, "function")
  end)

  test.test("stores and enumerates values", function()
    local namespace = "shmem-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    local memory, err = shmem.open(namespace, 8)
    test.not_nil(memory, err)

    memory:clear()
    test.ok(memory:set("alpha", "one"))
    test.ok(memory:set("beta", "two"))
    test.equal(memory:get("alpha"), "one")
    test.type(memory:get(1), "string")
    test.equal(memory:size(), 2)
    test.ok(memory:capacity() >= 2)

    local values = {}
    for key, value in pairs(memory) do
      values[key] = value
    end
    test.equal(values.alpha, "one")
    test.equal(values.beta, "two")

    memory:remove("alpha")
    test["nil"](memory:get("alpha"))
    memory:clear()
    test.equal(memory:size(), 0)
  end)
end)
