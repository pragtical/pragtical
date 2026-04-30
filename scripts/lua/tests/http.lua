local common = require "core.common"
local http = require "core.http"
local test = require "core.test"

local temp_root

local HTTP_SERVER_SCRIPT = [=[
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


PAYLOAD = b"downloaded-data"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args, **kwargs):
        pass

    def _read_body(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        return self.rfile.read(length) if length > 0 else b""

    def _send_json(self, status, payload):
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _parsed_request(self):
        parsed = urlsplit(self.path)
        query = {
            key: values[0] if len(values) == 1 else values
            for key, values in parse_qs(parsed.query, keep_blank_values=True).items()
        }
        return parsed, query

    def do_GET(self):
        parsed, query = self._parsed_request()

        if parsed.path == "/json":
            self._send_json(200, {
                "method": self.command,
                "path": parsed.path,
                "query": query,
                "header": self.headers.get("X-Test"),
            })
            return

        if parsed.path == "/redirect":
            self.send_response(303)
            self.send_header("Location", "/json?from=redirect")
            self.send_header("Content-Length", "0")
            self.send_header("Connection", "close")
            self.end_headers()
            return

        if parsed.path == "/chunked":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Connection", "close")
            self.end_headers()

            for chunk in (b"hello ", b"world"):
                self.wfile.write(("%X\r\n" % len(chunk)).encode("ascii"))
                self.wfile.write(chunk + b"\r\n")
                self.wfile.flush()
                time.sleep(0.01)

            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
            return

        if parsed.path == "/download":
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", 'attachment; filename="payload.txt"')
            self.send_header("Content-Length", str(len(PAYLOAD)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(PAYLOAD)
            return

        if parsed.path == "/sse":
            payload = (
                ": comment\n"
                "id: 42\n"
                "event: notice\n"
                "retry: 1500\n"
                "data: hello\n"
                "data: world\n\n"
                "data: final\n\n"
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(payload)
            self.wfile.flush()
            return

        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()

    def do_HEAD(self):
        parsed, _ = self._parsed_request()
        if parsed.path == "/head":
            self.send_response(204)
            self.send_header("X-Head", "ok")
            self.send_header("Content-Length", "0")
            self.send_header("Connection", "close")
            self.end_headers()
            return
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()

    def do_OPTIONS(self):
        parsed, _ = self._parsed_request()
        if parsed.path == "/options":
            self.send_response(204)
            self.send_header("Allow", "GET, HEAD, OPTIONS, POST, PUT, DELETE, PATCH")
            self.send_header("Content-Length", "0")
            self.send_header("Connection", "close")
            self.end_headers()
            return
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()

    def _handle_body_request(self):
        parsed, _ = self._parsed_request()
        if parsed.path != "/echo-body":
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.send_header("Connection", "close")
            self.end_headers()
            return

        body = self._read_body()
        body_text = body.decode("utf-8")
        content_type = self.headers.get("Content-Type")
        decoded = None
        if content_type and content_type.startswith("application/json"):
            decoded = json.loads(body_text)

        self._send_json(200, {
            "method": self.command,
            "content_type": content_type,
            "body": body_text,
            "json": decoded,
            "request_id": self.headers.get("X-Request-ID"),
        })

    def do_POST(self):
        self._handle_body_request()

    def do_PUT(self):
        self._handle_body_request()

    def do_DELETE(self):
        self._handle_body_request()

    def do_PATCH(self):
        self._handle_body_request()


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)

try:
    server.serve_forever()
except KeyboardInterrupt:
    pass
finally:
    server.server_close()
]=]

local function write_file(path, content)
  local file, err = io.open(path, "wb")
  test.not_nil(file, err)
  file:write(content)
  file:close()
end

local function read_file(path)
  local file, err = io.open(path, "rb")
  test.not_nil(file, err)
  local content = file:read("*a")
  file:close()
  return content
end

local function python_command(script_path)
  if PLATFORM == "Windows" then
    return { "python", "-u", script_path }
  end
  return { "python3", "-u", script_path }
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

local function await_callback(start, timeout)
  local result
  start(function(...)
    result = { n = select("#", ...), ... }
  end)
  wait_until(function() return result ~= nil end, timeout)
  return table.unpack(result, 1, result.n)
end

local function start_http_server(context)
  local script_path = context.temp_root .. PATHSEP .. "http_test_server.py"
  write_file(script_path, HTTP_SERVER_SCRIPT)
  context.server_script_paths[#context.server_script_paths + 1] = script_path

  local proc = process.start(python_command(script_path), {
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
  })
  test.not_nil(proc)

  context.server_processes[#context.server_processes + 1] = proc

  local line = proc.stdout:read("line", {
    timeout = 5,
    scan = 0.01,
  })
  test.not_nil(line, "HTTP test server did not report a port")

  local port = tonumber(line)
  test.type(port, "number")
  return "http://127.0.0.1:" .. port
end

test.describe("http", function()
  test.before_each(function(context)
    temp_root = USERDIR
      .. PATHSEP .. "http-tests-"
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
    for _, name in ipairs({
      "request", "sse", "get", "head", "options",
      "post", "put", "delete", "patch", "download",
    }) do
      test.type(http[name], "function", "missing http." .. name)
    end
    test.type(http.user_agent, "string")
  end)

  test.test("follows redirects and handles request helpers", function(context)
    local base_url = start_http_server(context)

    local redirects = {}
    local ok, err, result, info = await_callback(function(done)
      http.get(base_url .. "/redirect", { q = "hello world" }, {
        headers = {
          ["X-Test"] = "redirected",
        },
        on_redirect = function(redirect_info)
          redirects[#redirects + 1] = redirect_info
        end,
        on_done = done,
      })
    end, 5)

    test.ok(ok, err)
    test.equal(info.status, 200)
    test.equal(result.method, "GET")
    test.equal(result.path, "/json")
    test.equal(result.query.from, "redirect")
    test.equal(result.header, "redirected")
    test.equal(#redirects, 2)
    test.equal(redirects[1].status, 303)
    test.equal(redirects[2].status, 200)
    test.contains(redirects[1].url, "/redirect")
    test.contains(info.url, "/json?from=redirect")

    local post_ok, post_err, post_result, post_info = await_callback(function(done)
      http.post(base_url .. "/echo-body", "application/json", {
        name = "pragtical",
      }, {
        headers = {
          ["X-Request-ID"] = "req-123",
        },
        on_done = done,
      })
    end, 5)

    test.ok(post_ok, post_err)
    test.equal(post_info.status, 200)
    test.equal(post_result.method, "POST")
    test.equal(post_result.request_id, "req-123")
    test.contains(post_result.content_type, "application/json")
    test.equal(post_result.json.name, "pragtical")

    local head_ok, head_err, head_result, head_info = await_callback(function(done)
      http.head(base_url .. "/head", nil, {
        decode_json = false,
        on_done = done,
      })
    end, 5)

    test.ok(head_ok, head_err)
    test.equal(head_info.status, 204)
    test.equal(head_result, "")
    test.equal(head_info.headers["x-head"], "ok")

    local options_ok, options_err, options_result, options_info = await_callback(function(done)
      http.options(base_url .. "/options", nil, {
        decode_json = false,
        on_done = done,
      })
    end, 5)

    test.ok(options_ok, options_err)
    test.equal(options_info.status, 204)
    test.equal(options_result, "")
    test.contains(options_info.headers.allow, "POST")
  end)

  test.test("streams chunked responses and downloads files", function(context)
    local base_url = start_http_server(context)

    local chunks = {}
    local ok, err, result, info = await_callback(function(done)
      http.request("GET", base_url .. "/chunked", {
        on_chunk = function(chunk)
          chunks[#chunks + 1] = chunk
        end,
        on_done = done,
      })
    end, 5)

    test.ok(ok, err)
    test.is_nil(result)
    test.equal(info.status, 200)
    test.same(chunks, { "hello ", "world" })

    local progress = {}
    local download_ok, download_err, filename, download_info = await_callback(function(done)
      http.download(base_url .. "/download", {
        directory = context.temp_root .. PATHSEP .. "downloads",
        on_progress = function(downloaded, total)
          progress[#progress + 1] = { downloaded, total }
        end,
        on_done = done,
      })
    end, 5)

    test.ok(download_ok, download_err)
    test.equal(download_info.status, 200)
    test.not_nil(filename)
    test.contains(filename, "payload.txt")
    test.equal(read_file(filename), "downloaded-data")
    test.ok(#progress >= 1)
    test.same(progress[#progress], { 15, 15 })
  end)

  test.test("parses server-sent events", function(context)
    local base_url = start_http_server(context)

    local header_info
    local events = {}
    local ok, err, info = await_callback(function(done)
      http.sse(base_url .. "/sse", {
        last_event_id = "initial",
        on_header = function(current_info)
          header_info = current_info
        end,
        on_event = function(event, current_info)
          events[#events + 1] = {
            event = event.event,
            data = event.data,
            id = event.id,
            retry = event.retry,
            status = current_info and current_info.status,
          }
        end,
        on_done = done,
      })
    end, 5)

    test.ok(ok, err)
    test.equal(header_info.status, 200)
    test.equal(info.status, 200)
    test.same(events, {
      {
        event = "notice",
        data = "hello\nworld",
        id = "42",
        retry = 1500,
        status = 200,
      },
      {
        event = "message",
        data = "final",
        id = "42",
        retry = nil,
        status = 200,
      },
    })
  end)
end)
