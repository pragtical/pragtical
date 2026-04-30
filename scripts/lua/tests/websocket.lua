local common = require "core.common"
local test = require "core.test"
local websocket = require "core.websocket"

local temp_root

local WEBSOCKET_SERVER_SCRIPT = [=[
import base64
import hashlib
import socket
import sys


GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def recv_exact(conn, size):
    data = b""
    while len(data) < size:
        chunk = conn.recv(size - len(data))
        if not chunk:
            raise ConnectionError("connection closed")
        data += chunk
    return data


def read_frame(conn):
    b1, b2 = recv_exact(conn, 2)
    fin = (b1 & 0x80) != 0
    opcode = b1 & 0x0F
    masked = (b2 & 0x80) != 0
    length = b2 & 0x7F

    if length == 126:
        length = int.from_bytes(recv_exact(conn, 2), "big")
    elif length == 127:
        length = int.from_bytes(recv_exact(conn, 8), "big")

    mask = recv_exact(conn, 4) if masked else b""
    payload = recv_exact(conn, length)
    if masked:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return fin, opcode, payload


def send_frame(conn, opcode, payload=b"", fin=True):
    first = (0x80 if fin else 0) | opcode
    header = bytearray([first])
    length = len(payload)
    if length < 126:
        header.append(length)
    elif length < 65536:
        header.append(126)
        header.extend(length.to_bytes(2, "big"))
    else:
        header.append(127)
        header.extend(length.to_bytes(8, "big"))
    conn.sendall(bytes(header) + payload)


def read_upgrade_request(conn):
    request = b""
    while b"\r\n\r\n" not in request:
        chunk = conn.recv(4096)
        if not chunk:
            raise ConnectionError("handshake closed")
        request += chunk

    headers = {}
    lines = request.decode("utf-8").split("\r\n")
    method, path, _ = lines[0].split(" ", 2)
    for line in lines[1:]:
        if not line:
            break
        key, value = line.split(":", 1)
        headers[key.lower()] = value.strip()
    return method, path, headers


def upgrade(conn, selected_protocol=None, bad_accept=False):
    _, path, headers = read_upgrade_request(conn)
    accept = "invalid"
    if not bad_accept:
        key = headers["sec-websocket-key"]
        accept = base64.b64encode(
            hashlib.sha1((key + GUID).encode("utf-8")).digest()
        ).decode("ascii")

    response = [
        "HTTP/1.1 101 Switching Protocols",
        "Upgrade: websocket",
        "Connection: Upgrade",
        f"Sec-WebSocket-Accept: {accept}",
    ]
    if selected_protocol:
        response.append(f"Sec-WebSocket-Protocol: {selected_protocol}")
    response.append("")
    response.append("")
    conn.sendall("\r\n".join(response).encode("utf-8"))
    return path, headers


def serve_echo(server):
    conn, _ = server.accept()
    with conn:
        _, headers = upgrade(conn, selected_protocol="chat")
        assert "chat" in headers.get("sec-websocket-protocol", ""), headers
        send_frame(conn, 0x9, b"srv-ping")

        while True:
            _, opcode, payload = read_frame(conn)
            if opcode == 0x1:
                send_frame(conn, 0x1, b"echo:" + payload)
            elif opcode == 0x2:
                send_frame(conn, 0x2, b"bin:" + payload)
            elif opcode == 0x9:
                send_frame(conn, 0xA, payload)
            elif opcode == 0x8:
                send_frame(conn, 0x8, payload)
                break


def serve_reconnect(server):
    conn1, _ = server.accept()
    with conn1:
        upgrade(conn1)
        _, opcode, payload = read_frame(conn1)
        assert opcode == 0x1 and payload == b"hello", (opcode, payload)
        conn1.shutdown(socket.SHUT_RDWR)

    conn2, _ = server.accept()
    with conn2:
        upgrade(conn2)
        _, opcode, payload = read_frame(conn2)
        assert opcode == 0x1 and payload == b"restored", (opcode, payload)
        send_frame(conn2, 0x1, b"restored-ok")

        while True:
            _, opcode, payload = read_frame(conn2)
            if opcode == 0x8:
                send_frame(conn2, 0x8, payload)
                break


def serve_badaccept(server):
    conn, _ = server.accept()
    with conn:
        upgrade(conn, bad_accept=True)


server = socket.create_server(("127.0.0.1", 0), reuse_port=False)
print(server.getsockname()[1], flush=True)

mode = sys.argv[1]
with server:
    if mode == "echo":
        serve_echo(server)
    elif mode == "reconnect":
        serve_reconnect(server)
    elif mode == "badaccept":
        serve_badaccept(server)
    else:
        raise RuntimeError(f"unknown mode: {mode}")
]=]

local function write_file(path, content)
  local file, err = io.open(path, "wb")
  test.not_nil(file, err)
  file:write(content)
  file:close()
end

local function python_command(script_path, mode)
  if PLATFORM == "Windows" then
    return { "python", "-u", script_path, mode }
  end
  return { "python3", "-u", script_path, mode }
end

local function wait_until(predicate, timeout, message)
  local deadline = system.get_time() + (timeout or 5)
  while system.get_time() < deadline do
    if predicate() then
      return
    end
    coroutine.yield(0.01)
  end

  test.fail(message or "timed out waiting for async operation", 2)
end

local function start_websocket_server(context, mode)
  local script_path = context.temp_root .. PATHSEP .. "websocket_test_server.py"
  write_file(script_path, WEBSOCKET_SERVER_SCRIPT)
  context.server_script_paths[#context.server_script_paths + 1] = script_path

  local proc = process.start(python_command(script_path, mode), {
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
  })
  test.not_nil(proc)

  context.server_processes[#context.server_processes + 1] = proc

  local line = proc.stdout:read("line", {
    timeout = 5,
    scan = 0.01,
  })
  test.not_nil(line, "WebSocket test server did not report a port")

  local port = tonumber(line)
  test.type(port, "number")
  return "ws://127.0.0.1:" .. port
end

local function has_message(messages, expected, is_binary)
  for _, item in ipairs(messages) do
    if item.message == expected and item.is_binary == is_binary then
      return true
    end
  end
  return false
end

test.describe("websocket", function()
  test.before_each(function(context)
    temp_root = USERDIR
      .. PATHSEP .. "websocket-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    local ok, err = common.mkdirp(temp_root)
    test.ok(ok, err)
    context.temp_root = temp_root
    context.server_processes = {}
    context.server_script_paths = {}
  end)

  test.after_each(function(context)
    for i = #context.server_processes, 1, -1 do
      local proc = context.server_processes[i]
      if proc and proc:running() then
        proc:terminate()
        proc:wait(2, 0.01)
      end
    end

    for i = #context.server_script_paths, 1, -1 do
      local script_path = context.server_script_paths[i]
      if script_path and system.get_file_info(script_path) then
        local ok, err = os.remove(script_path)
        test.ok(ok, err)
      end
    end

    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  test.test("exports the documented functions", function()
    test.type(websocket.connect, "function")
    test.type(websocket.client, "table")

    for _, name in ipairs({
      "new", "get_status", "send", "send_text",
      "send_binary", "ping", "close",
    }) do
      test.type(websocket.client[name], "function", "missing websocket.client:" .. name)
    end
  end)

  test.test("connects, negotiates protocols and exchanges frames", function(context)
    local url = start_websocket_server(context, "echo")

    local connect_info
    local close_info
    local close_requested = false
    local errors = {}
    local messages = {}
    local pings = {}
    local pongs = {}
    local send_results = {}

    local function request_close(client)
      if close_requested then return end
      close_requested = true
      send_results.close = { client:close(1000, "bye") }
    end

    local client = websocket.connect(url, {
      protocols = { "chat", "fallback" },
      timeout = 5,
      on_connect = function(current, info, session)
        connect_info = {
          status = current:get_status(),
          protocol = current.protocol,
          response_protocol = info.protocol,
          attempt = session.attempt,
          is_reconnect = session.is_reconnect,
        }
        send_results.text = { current:send("hello") }
        send_results.binary = { current:send_binary("\0\1") }
        send_results.ping = { current:ping("cli-ping") }
      end,
      on_message = function(current, message, is_binary)
        messages[#messages + 1] = {
          message = message,
          is_binary = is_binary,
        }
        if #messages >= 2 and #pongs >= 1 then
          request_close(current)
        end
      end,
      on_ping = function(_, payload)
        pings[#pings + 1] = payload
      end,
      on_pong = function(current, payload)
        pongs[#pongs + 1] = payload
        if #messages >= 2 then
          request_close(current)
        end
      end,
      on_error = function(_, err)
        errors[#errors + 1] = err
      end,
      on_close = function(_, code, reason, was_clean)
        close_info = {
          code = code,
          reason = reason,
          was_clean = was_clean,
        }
      end,
    })

    wait_until(function() return close_info ~= nil end, 5)

    test.same(errors, {})
    test.not_nil(connect_info)
    test.equal(connect_info.status, "open")
    test.equal(connect_info.protocol, "chat")
    test.equal(connect_info.response_protocol, "chat")
    test.equal(connect_info.attempt, 0)
    test.not_ok(connect_info.is_reconnect)

    test.ok(send_results.text[1], send_results.text[2])
    test.ok(send_results.binary[1], send_results.binary[2])
    test.ok(send_results.ping[1], send_results.ping[2])
    test.ok(send_results.close[1], send_results.close[2])

    if #pings > 0 then
      test.contains(pings, "srv-ping")
    end
    test.contains(pongs, "cli-ping")
    test.ok(has_message(messages, "echo:hello", false))
    test.ok(has_message(messages, "bin:\0\1", true))
    test.equal(select(1, client:get_status()), "closed")
    test.same(close_info, {
      code = 1000,
      reason = "bye",
      was_clean = true,
    })
  end)

  test.test("reconnects and restores the session", function(context)
    local url = start_websocket_server(context, "reconnect")

    local close_info
    local connects = {}
    local errors = {}
    local messages = {}
    local reconnects = {}
    local restore_calls = {}

    websocket.connect(url, {
      timeout = 5,
      reconnect = true,
      reconnect_delay = 0.05,
      reconnect_delay_max = 0.05,
      max_reconnect_attempts = 1,
      on_connect = function(client, _, session)
        connects[#connects + 1] = {
          attempt = session.attempt,
          is_reconnect = session.is_reconnect,
        }
        if not session.is_reconnect then
          client:send("hello")
        end
      end,
      on_reconnect = function(_, info)
        reconnects[#reconnects + 1] = {
          attempt = info.attempt,
          error = info.error,
          opened = info.opened,
        }
      end,
      restore_session = function(client, session)
        restore_calls[#restore_calls + 1] = session.attempt
        client:send("restored")
      end,
      on_message = function(client, message)
        messages[#messages + 1] = message
        client:close()
      end,
      on_error = function(_, err)
        errors[#errors + 1] = err
      end,
      on_close = function(_, code, reason, was_clean)
        close_info = {
          code = code,
          reason = reason,
          was_clean = was_clean,
        }
      end,
    })

    wait_until(function() return close_info ~= nil end, 5)

    test.same(connects, {
      { attempt = 0, is_reconnect = false },
      { attempt = 1, is_reconnect = true },
    })
    test.same(restore_calls, { 1 })
    test.same(messages, { "restored-ok" })
    test.equal(#reconnects, 1)
    test.equal(reconnects[1].attempt, 1)
    test.not_nil(reconnects[1].error)
    test.ok(reconnects[1].opened)
    test.contains(errors, reconnects[1].error)
    test.same(close_info, {
      code = 1000,
      reason = "",
      was_clean = true,
    })
  end)

  test.test("reports handshake validation failures", function(context)
    local url = start_websocket_server(context, "badaccept")

    local close_called = false
    local errors = {}
    local client = websocket.connect(url, {
      timeout = 5,
      on_error = function(_, err)
        errors[#errors + 1] = err
      end,
      on_close = function()
        close_called = true
      end,
    })

    wait_until(function()
      return select(1, client:get_status()) == "closed" and #errors > 0
    end, 5)

    local status, errmsg = client:get_status()
    test.equal(status, "closed")
    test.equal(errmsg, "websocket handshake validation failed")
    test.same(errors, { "websocket handshake validation failed" })
    test.not_ok(close_called)
  end)
end)
