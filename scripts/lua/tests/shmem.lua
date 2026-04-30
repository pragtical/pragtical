local test = require "core.test"

local function unique_namespace(suffix)
  return table.concat({
    "shmem-tests",
    system.get_process_id(),
    math.floor(system.get_time() * 1000000),
    suffix
  }, "-")
end

test.describe("shmem", function()
  test.test("exports the documented functions", function()
    test.type(shmem.open, "function")
  end)

  test.test("stores and enumerates values", function()
    local namespace = unique_namespace("enumerate")
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

  test.test("returns nil for out of range numeric lookup", function()
    local memory, err = shmem.open(unique_namespace("bounds"), 4)
    test.not_nil(memory, err)

    memory:clear()
    test.ok(memory:set("alpha", "one"))
    test["nil"](memory:get(0))
    test["nil"](memory:get(-1))
    test["nil"](memory:get(2))
    memory:clear()
  end)

  test.test("rejects reopening a namespace with a different capacity", function()
    local namespace = unique_namespace("capacity")
    local memory, err = shmem.open(namespace, 2)
    test.not_nil(memory, err)

    local other, other_err = shmem.open(namespace, 4)
    test["nil"](other)
    test.match(other_err, "capacity", nil, true)
    memory:clear()
  end)
end)
