---Coroutine-based HTTP client for Pragtical Code Editor.
---Supports streaming responses line-by-line or binary, chunked transfer encoding,
---Content-Length, connection-close streams, automatic redirects,
---proper port handling, global user agent, and file downloads.
---@class core.http
local http = {}

local core = require "core"
local common = require "core.common"

---@alias http.method
---| '"GET"'
---| '"POST"'
---| '"PUT"'
---| '"DELETE"'
---| '"PATCH"'
---| '"HEAD"'
---| '"OPTIONS"'

---@alias http.header_callback fun(info:{status:integer, headers:table<string,string>})
---@alias http.chunk_callback fun(chunk:string)
---@alias http.done_callback fun(ok:boolean?, err:string?, filename:string?)
---@alias http.progress_callback fun(downloaded:integer, total:integer?)

---Maximum amount of redirections allowed.
local MAX_REDIRECTS = 5

---Default user agent used on all requests.
http.user_agent = "Pragtical/"..VERSION

-- URL encode
---@param str string
---@return string
local function urlencode(str)
  if not str then return "" end
  return (str:gsub("([^%w%-._~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

-- Parse URL
---@param url string
---@return table|nil parsed
---@return string? err
local function parse_url(url)
  local protocol, host, port, path = url:match("^(https?)://([^/:?#]+):?(%d*)(.*)$")
  if not protocol then return nil, "invalid URL" end
  port = tonumber(port) or (protocol == "https" and 443 or 80)
  path = path ~= "" and path or "/"
  return { protocol = protocol, host = host, port = port, path = path }
end

-- Resolve hostname
---@param hostname string
---@return net.address? addr
---@return string? err
local function resolve_host(hostname)
  local addr, err = net.resolve_address(hostname)
  if not addr then return nil, err end
  while true do
    local status, err = addr:get_status()
    if status == "success" then return addr end
    if status == "failure" then return nil, err or "failed to resolve host" end
    coroutine.yield(0.05)
  end
end

-- Build HTTP request string
---@param method http.method
---@param path string
---@param host string
---@param headers table<string,string>?
---@param body string?
---@return string
local function build_request(method, path, host, headers, body)
  headers = headers or {}
  local normalized = {}
  for k, v in pairs(headers) do normalized[k:lower()] = v end
  if not normalized["user-agent"] and http.user_agent then normalized["user-agent"] = http.user_agent end

  local req = { string.format("%s %s HTTP/1.1", method, path) }
  req[#req+1] = "Host: "..host
  req[#req+1] = "Connection: close"
  if body then req[#req+1] = "Content-Length: "..#body end
  for k, v in pairs(normalized) do
    local header_name = k:gsub("(%a)([%w%-]*)", function(first, rest) return first:upper() .. rest:lower() end)
    req[#req+1] = header_name..": "..v
  end
  req[#req+1] = ""
  req[#req+1] = body or ""
  return table.concat(req, "\r\n")
end

-- Write all data
---@param conn net.tcp
---@param data string
local function write_all(conn, data)
  local total_sent = 0
  while total_sent < #data do
    local ok, _ = conn:write(data:sub(total_sent+1))
    if not ok then coroutine.yield(0.05) else total_sent = #data end
  end
  while true do
    local pending = conn:wait_until_drained(0)
    if pending == 0 then break end
    coroutine.yield(0.05)
  end
end

-- Read exactly n bytes
---@param conn net.tcp
---@param n integer
---@return string? data
---@return string? err
local function read_n(conn, n)
  local buf, read_bytes = {}, 0
  while read_bytes < n do
    local chunk, err = conn:read(n - read_bytes)
    if err then return nil, err end
    if chunk and #chunk > 0 then
      buf[#buf+1] = chunk
      read_bytes = read_bytes + #chunk
    else
      coroutine.yield(0.01)
    end
  end
  return table.concat(buf)
end

-- Read a line (CRLF)
---@param conn net.tcp
---@return string? line
---@return string? err
local function read_line(conn)
  local line = {}
  while true do
    local c, err = conn:read(1)
    if err then return nil, err end
    if c and #c > 0 then
      line[#line+1] = c
      if #line >= 2 and line[#line-1] == "\r" and line[#line] == "\n" then
        return table.concat(line, "", 1, #line-2)
      end
    else
      coroutine.yield(0.01)
    end
  end
end

-- Parse HTTP response headers
---@param header_lines string[]
---@return integer? status
---@return table<string,string> headers
local function parse_http_response_headers(header_lines)
  if #header_lines == 0 then return nil, {} end
  local status_line = header_lines[1]
  local _, _, status = status_line:find("HTTP/%d+%.%d+ (%d%d%d)")
  local headers = {}
  for i = 2, #header_lines do
    local k, v = header_lines[i]:match("^([%w%-]+):%s*(.+)$")
    if k and v then headers[k:lower()] = v end
  end
  return tonumber(status), headers
end

---Perform an HTTP request asynchronously.
---@param method http.method
---@param url string
---@param headers table<string,string>?
---@param body string?
---@param header_callback http.header_callback?
---@param chunk_callback http.chunk_callback
---@param done_callback http.done_callback
---@param redirect_count integer? Internal
function http.request(method, url, headers, body, header_callback, chunk_callback, done_callback, redirect_count)
  redirect_count = redirect_count or 0
  if redirect_count > MAX_REDIRECTS then done_callback(nil, "too many redirects") return end

  core.add_thread(function()
    local parsed, err = parse_url(url)
    if not parsed then done_callback(nil, err) return end

    local addr, err = resolve_host(parsed.host)
    if not addr then done_callback(nil, err) return end

    local conn, err = net.open_tcp(addr, parsed.port, parsed.protocol == "https")
    if not conn then done_callback(nil, err) return end

    while true do
      local status, err = conn:get_status()
      if status == "success" then break end
      if status == "failure" then conn:close() done_callback(nil, err or "failed to connect") return end
      coroutine.yield(0.05)
    end

    local req_str = build_request(method, parsed.path, parsed.host, headers, body)
    write_all(conn, req_str)

    local header_lines = {}
    while true do
      local line, err = read_line(conn)
      if err then conn:close() done_callback(nil, err) return end
      if not line then coroutine.yield(0.01)
      else if line == "" then break end header_lines[#header_lines+1] = line end
    end

    local status_code, response_headers = parse_http_response_headers(header_lines)
    if not status_code then conn:close() done_callback(nil, "invalid HTTP response") return end
    if header_callback then header_callback({status=status_code, headers=response_headers}) end

    if status_code >= 300 and status_code < 400 and response_headers["location"] then
      conn:close()
      local new_url = response_headers["location"]
      local new_method = method
      if status_code == 303 then new_method = "GET" body = nil end
      return http.request(new_method, new_url, headers, body, header_callback, chunk_callback, done_callback, redirect_count + 1)
    end

    local ok, err
    local function internal_chunk_cb(chunk)
      chunk_callback(chunk)
      coroutine.yield(0)
    end

    if response_headers["transfer-encoding"] == "chunked" then
      while true do
        local line, err = read_line(conn)
        if not line then ok, err = false, err break end
        local size = tonumber(line:match("^[0-9A-Fa-f]+"),16)
        if size == 0 then break end
        local data, err = read_n(conn, size)
        if not data then ok, err = false, err break end
        internal_chunk_cb(data)
        read_line(conn)
      end
    elseif response_headers["content-length"] then
      local remaining = tonumber(response_headers["content-length"])
      while remaining > 0 do
        local to_read = math.min(4096, remaining)
        local data, err = read_n(conn, to_read)
        if not data then ok, err = false, err break end
        remaining = remaining - #data
        internal_chunk_cb(data)
      end
    else
      while true do
        local data, err = conn:read(4096)
        if err then ok, err = false, err break end
        if not data or #data == 0 then coroutine.yield(0.01) else internal_chunk_cb(data) end
      end
    end

    conn:close()
    done_callback(ok ~= false, err)
  end)
end

---HTTP GET convenience
---@param url string
---@param headers table<string,string>?
---@param header_callback http.header_callback?
---@param chunk_callback http.chunk_callback
---@param done_callback http.done_callback
function http.get(url, headers, header_callback, chunk_callback, done_callback)
  return http.request("GET", url, headers, nil, header_callback, chunk_callback, done_callback)
end

---HTTP POST convenience
---@param url string
---@param body string?
---@param headers table<string,string>?
---@param header_callback http.header_callback?
---@param chunk_callback http.chunk_callback
---@param done_callback http.done_callback
function http.post(url, body, headers, header_callback, chunk_callback, done_callback)
  return http.request("POST", url, headers, body, header_callback, chunk_callback, done_callback)
end

---HTTP PUT convenience
---@param url string
---@param body string?
---@param headers table<string,string>?
---@param header_callback http.header_callback?
---@param chunk_callback http.chunk_callback
---@param done_callback http.done_callback
function http.put(url, body, headers, header_callback, chunk_callback, done_callback)
  return http.request("PUT", url, headers, body, header_callback, chunk_callback, done_callback)
end

---HTTP DELETE convenience
---@param url string
---@param body string?
---@param headers table<string,string>?
---@param header_callback http.header_callback?
---@param chunk_callback http.chunk_callback
---@param done_callback http.done_callback
function http.delete(url, body, headers, header_callback, chunk_callback, done_callback)
  return http.request("DELETE", url, headers, body, header_callback, chunk_callback, done_callback)
end

---HTTP PATCH convenience
---@param url string
---@param body string?
---@param headers table<string,string>?
---@param header_callback http.header_callback?
---@param chunk_callback http.chunk_callback
---@param done_callback http.done_callback
function http.patch(url, body, headers, header_callback, chunk_callback, done_callback)
  return http.request("PATCH", url, headers, body, header_callback, chunk_callback, done_callback)
end

---HTTP HEAD convenience
---@param url string
---@param headers table<string,string>?
---@param header_callback http.header_callback?
---@param chunk_callback http.chunk_callback
---@param done_callback http.done_callback
function http.head(url, headers, header_callback, chunk_callback, done_callback)
  return http.request("HEAD", url, headers, nil, header_callback, chunk_callback, done_callback)
end

---HTTP OPTIONS convenience
---@param url string
---@param headers table<string,string>?
---@param header_callback http.header_callback?
---@param chunk_callback http.chunk_callback
---@param done_callback http.done_callback
function http.options(url, headers, header_callback, chunk_callback, done_callback)
  return http.request("OPTIONS", url, headers, nil, header_callback, chunk_callback, done_callback)
end

---Download a file asynchronously with optional progress tracking.
---@param url string File URL
---@param headers table<string,string>?
---@param done_callback http.done_callback
---@param dir string? Optional directory
---@param filename string? Optional filename
---@param progress_callback http.progress_callback? Optional progress callback
function http.download(url, headers, done_callback, dir, filename, progress_callback)
  local f, total_downloaded, total_size = nil, 0, nil

  local function header_cb(info)
    local cd = info.headers["content-disposition"]
    if cd and not filename then
      filename = cd:match('filename="?([^"]+)"?')
    end
    if not filename then
      filename = url:match("/([^/]+)$") or "download"
    end
    if dir then
      common.mkdirp(dir)
      filename = dir:gsub("/+$","").."/"..filename
    end
    if info.headers["content-length"] then
      total_size = tonumber(info.headers["content-length"])
    end
  end

  local function chunk_cb(chunk)
    if not f then f = assert(io.open(filename, "wb")) end
    f:write(chunk)
    total_downloaded = total_downloaded + #chunk
    if progress_callback then
      progress_callback(total_downloaded, total_size)
    end
  end

  local function done_cb_inner(ok, err)
    if f then f:close() end
    done_callback(ok, err, filename)
  end

  http.get(url, headers, header_cb, chunk_cb, done_cb_inner)
end

-- Fetch or update ca bundle if no system provided one (windows, macOS)
-- TODO: move this logic directly to http.request, also make most http.request
-- params an object of options.
local capath = net.get_cacert_path()
if capath == nil then
  local userca = USERDIR .. PATHSEP .. "cacert.pem"
  local userca_info = system.get_file_info(userca)
  local two_weeks = 86400 * 14
  if not userca_info or userca_info.modified + two_weeks < os.time() then
    http.download(
      "https://curl.se/ca/cacert.pem",
      nil,
      function(ok, errmsg)
        if ok then net.set_cacert_path(userca) end
        if errmsg then core.error("Could not obtain CA bundle: %s", errmsg) end
      end,
      USERDIR
    )
  else
    net.set_cacert_path(userca)
  end
end

return http
