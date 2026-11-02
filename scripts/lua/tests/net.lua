local net = require "net"
local test = require "core.test"

local function wait_for(callback)
  local deadline = system.get_time() + 5
  repeat
    local value = callback()
    if value then return value end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  test.fail("timed out waiting for loopback traffic")
end

local function receive(connection, size)
  local text = ""
  return wait_for(function()
    local chunk, err = connection:read(size - #text)
    test.is_nil(err)
    test.type(chunk, "string")
    text = text .. chunk
    if #text == size then return text end
  end)
end

test.describe("native net", function()
  test.before_each(function(context)
    context.connections = {}
    context.address = assert(net.resolve_address("127.0.0.1"))
    test.equal(context.address:wait_until_resolved(1000), "success")
    local first_port = 40000 + system.get_process_id() % 20000
    local err
    for offset = 0, 63 do
      local port = first_port + offset
      context.server, err = net.create_server(context.address, port)
      if context.server then
        context.port = port
        return
      end
    end
    test.fail("could not create a loopback listener: " .. tostring(err))
  end)

  test.after_each(function(context)
    for _, connection in ipairs(context.connections) do connection:close() end
    context.connections, context.server, context.address = nil, nil, nil
    collectgarbage("collect")
  end)

  test.test("accept returns one nil without an error when no client is pending", function(context)
    local function check(...)
      test.equal(select("#", ...), 1)
      local connection, err = ...
      test.is_nil(connection)
      test.is_nil(err)
    end
    check(context.server:accept())
    check(context.server:accept())
  end)

  test.test("an idle accept cannot return an ignored argument from the Lua stack", function(context)
    local connection, err = context.server:accept("ignored")
    test.is_nil(connection)
    test.is_nil(err)
  end)

  test.test("accepted plain TCP sockets exchange data and leave the listener empty", function(context)
    local outgoing = assert(net.open_tcp(context.address, context.port))
    context.connections[#context.connections + 1] = outgoing
    test.equal(outgoing:wait_until_connected(1000), "success")
    local incoming = wait_for(function()
      local connection, err = context.server:accept()
      test.is_nil(err)
      return connection
    end)
    test.type(incoming.read, "function")
    test.type(incoming.write, "function")
    context.connections[#context.connections + 1] = incoming
    test.equal(incoming:wait_until_connected(0), "success")
    test.equal(incoming:get_status(), "success")
    local message = "accepted\0socket\n"
    test.equal(incoming:write(message), #message)
    test.equal(incoming:wait_until_drained(1000), 0)
    test.equal(receive(outgoing, #message), message)
    test.equal(outgoing:write("reply"), 5)
    test.equal(outgoing:wait_until_drained(1000), 0)
    test.equal(receive(incoming, 5), "reply")
    test.is_nil(context.server:accept())
    incoming:close()
    incoming:close()
    outgoing:close()
  end)
end)
