---Coroutine-based HTTP client for Pragtical Code Editor.
---Supports streaming responses line-by-line or binary, chunked transfer encoding,
---Content-Length, connection-close streams, automatic redirects,
---proper port handling, global user agent, and file downloads.
---@class core.http
local http = {}

local core = require "core"
local json = require "core.json"
local common = require "core.common"

---@alias http.method
---| "GET"
---| "POST"
---| "PUT"
---| "DELETE"
---| "PATCH"
---| "HEAD"
---| "OPTIONS"

---@alias http.request.submittype
---| "application/x-www-form-urlencoded"
---| "multipart/form-data"
---| "application/json"
---| "text/plain"

---@alias http.header_value string|string[]

---@class http.response_info
---@field status integer
---@field headers table<string,http.header_value>
---@field url string

---@alias http.on_header fun(info:http.response_info)
---@alias http.on_chunk fun(chunk:string)
---@alias http.on_done fun(ok:boolean?, err:string?, result:string|table|nil, info:http.response_info?)
---@alias http.on_done_download fun(ok:boolean?, err:string?, filename:string?, info:http.response_info?)
---@alias http.on_progress fun(downloaded:integer, total:integer?)

---@class http.sse.event
---@field event string
---@field data string
---@field id string?
---@field retry integer?

---@alias http.on_sse_event fun(event:http.sse.event, info:http.response_info?)
---@alias http.on_sse_done fun(ok:boolean?, err:string?, info:http.response_info?)

---@class http.request.fileparam
---@field filename string
---@field content_type string
---@field data? string
---@field path? string

---@alias http.request.param string | http.request.fileparam

---Maximum amount of redirections allowed.
local MAX_REDIRECTS = 5

---Flag to check if CA bundle is been download before processing a request.
local DOWNLOADING_CACERT_BUNDLE = false

---Default user agent used on all requests.
http.user_agent = "Pragtical/" .. VERSION

---@param value any
---@return any
local function clone_value(value)
  if type(value) ~= "table" then
    return value
  end

  local copy = {}
  for k, v in pairs(value) do
    copy[k] = clone_value(v)
  end
  return copy
end

---@param options table|nil
---@return table
local function clone_options(options)
  return clone_value(options or {})
end

---@param headers table<string,http.header_value>
---@param key string
---@param value string
local function append_header_value(headers, key, value)
  local existing = headers[key]
  if existing == nil then
    headers[key] = value
  elseif type(existing) == "table" then
    existing[#existing + 1] = value
  else
    headers[key] = { existing, value }
  end
end

---@param headers table<string,http.header_value>?
---@param key string
---@return string?
local function get_header_value(headers, key)
  if not headers then return nil end

  local value = headers[key]
  if type(value) == "table" then
    return value[#value]
  end
  return value
end

-- URL encode
---@param str string
---@return string
local function urlencode(str)
  if not str then return "" end
  return (str:gsub("([^%w%-._~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

---@param params table<string,string>
local function encode_query(params)
  if not params then return "" end
  local t = {}
  for k, v in pairs(params) do
    t[#t + 1] = urlencode(k) .. "=" .. urlencode(tostring(v))
  end
  return table.concat(t, "&")
end

---@param url string
---@param params table<string,string>
local function append_query(url, params)
  if not params then return url end
  local qs = encode_query(params)
  if qs == "" then return url end
  return url .. (url:find("?", 1, true) and "&" or "?") .. qs
end

---@return string
local function random_boundary()
  return "----PragticalFormBoundary" .. tostring(math.random(1e9))
end

---@param params http.request.param[]
---@param boundary string
local function encode_multipart(params, boundary)
  local parts = {}

  for name, value in pairs(params) do
    if type(value) == "table" and (value.data or value.path) then
      local data
      if value.path then
        local f = assert(io.open(value.path, "rb"))
        data = f:read("*a")
        f:close()
      else
        data = value.data
      end

      parts[#parts + 1] =
        "--" .. boundary .. "\r\n" ..
        string.format(
          'Content-Disposition: form-data; name="%s"; filename="%s"\r\n',
          name, value.filename or "file"
        ) ..
        string.format(
          "Content-Type: %s\r\n\r\n",
          value.content_type or "application/octet-stream"
        ) ..
        data .. "\r\n"
    else
      parts[#parts + 1] =
        "--" .. boundary .. "\r\n" ..
        string.format(
          'Content-Disposition: form-data; name="%s"\r\n\r\n',
          name
        ) ..
        tostring(value) .. "\r\n"
    end
  end

  parts[#parts + 1] = "--" .. boundary .. "--\r\n"
  return table.concat(parts)
end

---@param submit_type http.request.submittype
---@param params? table<string,string>
---@param body? string
---@param headers? table<string,string>
local function prepare_body_and_headers(submit_type, params, body, headers)
  headers = clone_options(headers)

  if body then
    return body, headers
  end

  if not params then
    return nil, headers
  end

  if submit_type == "application/x-www-form-urlencoded" then
    headers["Content-Type"] = submit_type
    return encode_query(params), headers
  elseif submit_type == "multipart/form-data" then
    local boundary = random_boundary()
    headers["Content-Type"] = submit_type .. "; boundary=" .. boundary
    return encode_multipart(params, boundary), headers
  elseif submit_type == "application/json" then
    headers["Content-Type"] = submit_type
    return json.encode(params), headers
  elseif submit_type == "text/plain" then
    headers["Content-Type"] = submit_type
    return tostring(params), headers
  end

  error("Unsupported Content-Type: " .. tostring(submit_type))
end

---@param method http.method
---@return boolean
local function is_query_method(method)
  return method == "GET" or method == "HEAD" or method == "OPTIONS"
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

---@param protocol string
---@param host string
---@param port integer
---@return string
local function build_origin(protocol, host, port)
  local default_port = protocol == "https" and 443 or 80
  if port == default_port then
    return protocol .. "://" .. host
  end
  return protocol .. "://" .. host .. ":" .. port
end

---@param base_path string
---@param relative_path string
---@return string
local function resolve_relative_path(base_path, relative_path)
  local dir = base_path:gsub("[^/]*$", "")
  if dir == "" then dir = "/" end

  local path = relative_path:sub(1, 1) == "/" and relative_path or (dir .. relative_path)
  local trailing_slash = path:sub(-1) == "/"
  local segments = {}

  for segment in path:gmatch("[^/]+") do
    if segment == ".." then
      if #segments > 0 then
        table.remove(segments)
      end
    elseif segment ~= "." and segment ~= "" then
      segments[#segments + 1] = segment
    end
  end

  local normalized = "/" .. table.concat(segments, "/")
  if trailing_slash and normalized ~= "/" then
    normalized = normalized .. "/"
  end
  return normalized
end

---@param parsed table
---@param location string
---@return string
local function resolve_redirect_url(parsed, location)
  if location:match("^[%a][%w+%.%-]*://") then
    return location
  end

  if location:sub(1, 2) == "//" then
    return parsed.protocol .. ":" .. location
  end

  local origin = build_origin(parsed.protocol, parsed.host, parsed.port)
  local base_path = parsed.path:match("^[^?#]*") or "/"

  if location:sub(1, 1) == "/" then
    return origin .. location
  end

  if location:sub(1, 1) == "?" or location:sub(1, 1) == "#" then
    return origin .. base_path .. location
  end

  local location_path, location_suffix = location:match("^([^?#]*)(.*)$")
  return origin .. resolve_relative_path(base_path, location_path) .. location_suffix
end

-- Resolve hostname
---@param hostname string
---@param should_abort? fun():string?
---@return net.address? addr
---@return string? err
local function resolve_host(hostname, should_abort)
  local addr, err = net.resolve_address(hostname)
  if not addr then return nil, err end

  while true do
    local abort_err = should_abort and should_abort()
    if abort_err then return nil, abort_err end

    local status, err2 = addr:get_status()
    if status == "success" then return addr end
    if status == "failure" then return nil, err2 or "failed to resolve host" end
    coroutine.yield(0.05)
  end
end

-- Build HTTP request string
---@param method http.method
---@param path string
---@param host string
---@param port integer
---@param protocol string
---@param headers table<string,string>?
---@param body string?
---@return string
local function build_request(method, path, host, port, protocol, headers, body)
  headers = headers or {}
  local normalized = {}
  for k, v in pairs(headers) do
    normalized[k:lower()] = v
  end

  if not normalized["user-agent"] and http.user_agent then
    normalized["user-agent"] = http.user_agent
  end

  local host_header = build_origin(protocol, host, port):gsub("^https?://", "")
  local req = { string.format("%s %s HTTP/1.1", method, path) }
  req[#req + 1] = "Host: " .. host_header
  req[#req + 1] = "Connection: close"
  if body then
    req[#req + 1] = "Content-Length: " .. #body
  end

  for k, v in pairs(normalized) do
    local header_name = k:gsub("(%a)([%w%-]*)", function(first, rest)
      return first:upper() .. rest:lower()
    end)
    req[#req + 1] = header_name .. ": " .. v
  end

  req[#req + 1] = ""
  req[#req + 1] = body or ""
  return table.concat(req, "\r\n")
end

-- Write all data
---@param conn net.tcp
---@param data string
---@param should_abort? fun():string?
---@return boolean?, string?
local function write_all(conn, data, should_abort)
  local total_sent = 0
  while total_sent < #data do
    local abort_err = should_abort and should_abort()
    if abort_err then return nil, abort_err end

    local ok = conn:write(data:sub(total_sent + 1))
    if not ok then
      coroutine.yield(0.05)
    else
      total_sent = #data
    end
  end

  while true do
    local abort_err = should_abort and should_abort()
    if abort_err then return nil, abort_err end

    local pending = conn:wait_until_drained(0)
    if pending == 0 then break end
    coroutine.yield(0.05)
  end

  return true
end

---@param conn net.tcp
---@param should_abort? fun():string?
---@return table
local function make_reader(conn, should_abort)
  local buffer = ""

  local function wait_for_data(size)
    while #buffer < size do
      local abort_err = should_abort and should_abort()
      if abort_err then return nil, abort_err end

      local chunk, err = conn:read(math.max(4096, size - #buffer))
      if err then return nil, err end

      if chunk and #chunk > 0 then
        buffer = buffer .. chunk
      else
        coroutine.yield(0.01)
      end
    end

    return true
  end

  return {
    read_n = function(_, n)
      local ok, err = wait_for_data(n)
      if not ok then return nil, err end

      local data = buffer:sub(1, n)
      buffer = buffer:sub(n + 1)
      return data
    end,

    read_line = function(_)
      while true do
        local idx = buffer:find("\r\n", 1, true)
        if idx then
          local line = buffer:sub(1, idx - 1)
          buffer = buffer:sub(idx + 2)
          return line
        end

        local abort_err = should_abort and should_abort()
        if abort_err then return nil, abort_err end

        local chunk, err = conn:read(4096)
        if err then return nil, err end

        if chunk and #chunk > 0 then
          buffer = buffer .. chunk
        else
          coroutine.yield(0.01)
        end
      end
    end,

    read_chunk = function(_, max_len)
      if #buffer > 0 then
        local data = buffer:sub(1, max_len)
        buffer = buffer:sub(#data + 1)
        return data
      end

      while true do
        local abort_err = should_abort and should_abort()
        if abort_err then return nil, abort_err end

        local chunk, err = conn:read(max_len)
        if err then return nil, err end

        if chunk and #chunk > 0 then
          return chunk
        end

        local status = conn:get_status()
        if status == "failure" then
          return nil
        end
        coroutine.yield(0.01)
      end
    end
  }
end

-- Parse HTTP response headers
---@param header_lines string[]
---@return integer? status
---@return table<string,http.header_value> headers
local function parse_http_response_headers(header_lines)
  if #header_lines == 0 then return nil, {} end

  local status_line = header_lines[1]
  local _, _, status = status_line:find("HTTP/%d+%.%d+ (%d%d%d)")
  local headers = {}

  for i = 2, #header_lines do
    local k, v = header_lines[i]:match("^([%w%-]+):%s*(.+)$")
    if k and v then
      append_header_value(headers, k:lower(), v)
    end
  end

  return tonumber(status), headers
end

---@param content_type string?
local function is_json_content_type(content_type)
  if not content_type then return false end
  return content_type:find("application/json", 1, true)
     or content_type:find("+json", 1, true)
end

---@class http.request.options
---@field headers? table<string,string>
---@field body? string
---@field on_redirect? http.on_header
---@field on_header? http.on_header
---@field on_chunk? http.on_chunk
---@field on_done http.on_done
---@field decode_json? boolean (default: true)
---@field timeout? number
---@field is_cancelled? fun():boolean
---@field private redirect_count? integer

---@class http.sse.options
---@field method? http.method
---@field submit_type? http.request.submittype
---@field params? table<string,http.request.param>
---@field headers? table<string,string>
---@field body? string
---@field on_redirect? http.on_header
---@field on_header? http.on_header
---@field on_event http.on_sse_event
---@field on_done http.on_sse_done
---@field timeout? number
---@field is_cancelled? fun():boolean
---@field last_event_id? string

---Perform an HTTP request asynchronously.
---@param method http.method
---@param url string
---@param options http.request.options
function http.request(method, url, options)
  assert(type(options) == "table", "provide the options object")
  assert(type(options.on_done) == "function", "provide the on_done callback")

  local headers = options.headers
  local body = options.body
  local on_redirect = options.on_redirect
  local on_header = options.on_header
  local on_chunk = options.on_chunk
  local on_done = options.on_done
  local timeout = options.timeout
  local is_cancelled = options.is_cancelled

  local want_stream = type(on_chunk) == "function"
  local auto_decode = options.decode_json ~= false

  local response_chunks
  if not want_stream then
    response_chunks = {}
  end

  ---@diagnostic disable-next-line
  local redirect_count = options.redirect_count or 0

  if redirect_count > MAX_REDIRECTS then
    on_done(false, "too many redirects")
    return
  end

  core.add_background_thread(function()
    local start_time = system.get_time()
    local function should_abort()
      if type(is_cancelled) == "function" and is_cancelled() then
        return "request cancelled"
      end
      if timeout and system.get_time() - start_time >= timeout then
        return "request timed out"
      end
    end

    local parsed, errurl = parse_url(url)
    if not parsed then
      on_done(false, errurl)
      return
    end

    local addr, errhost = resolve_host(parsed.host, should_abort)
    if not addr then
      on_done(false, errhost)
      return
    end

    while DOWNLOADING_CACERT_BUNDLE and parsed.protocol == "https" do
      local abort_err = should_abort()
      if abort_err then
        on_done(false, abort_err)
        return
      end
      coroutine.yield(0.5)
    end

    local conn, errtcp = net.open_tcp(addr, parsed.port, parsed.protocol == "https")
    if not conn then
      on_done(false, errtcp)
      return
    end

    while true do
      local abort_err = should_abort()
      if abort_err then
        conn:close()
        on_done(false, abort_err)
        return
      end

      local status, errstatus = conn:get_status()
      if status == "success" then break end
      if status == "failure" then
        conn:close()
        on_done(false, errstatus or "failed to connect")
        return
      end
      coroutine.yield(0.05)
    end

    local req_str = build_request(
      method, parsed.path, parsed.host, parsed.port, parsed.protocol, headers, body
    )
    local sent, write_err = write_all(conn, req_str, should_abort)
    if not sent then
      conn:close()
      on_done(false, write_err)
      return
    end

    local reader = make_reader(conn, should_abort)
    local header_lines = {}
    while true do
      local line, errread = reader:read_line()
      if errread then
        conn:close()
        on_done(false, errread)
        return
      end
      if line == "" then break end
      header_lines[#header_lines + 1] = line
    end

    local status_code, response_headers = parse_http_response_headers(header_lines)
    if not status_code then
      conn:close()
      on_done(false, "invalid HTTP response")
      return
    end

    local response_info = {
      status = status_code,
      headers = response_headers,
      url = url
    }

    if on_redirect then
      on_redirect(response_info)
    end

    local location = get_header_value(response_headers, "location")
    if status_code >= 300 and status_code < 400 and location then
      conn:close()

      local new_method = method
      local new_options = clone_options(options)
      if status_code == 303 then
        new_method = "GET"
        new_options.body = nil
      end
      new_options.redirect_count = redirect_count + 1
      return http.request(new_method, resolve_redirect_url(parsed, location), new_options)
    end

    if on_header then
      on_header(response_info)
    end

    local ok, errmsg
    local function internal_chunk_cb(chunk)
      if want_stream and on_chunk then
        on_chunk(chunk)
      else
        response_chunks[#response_chunks + 1] = chunk
      end
      coroutine.yield(0)
    end

    if get_header_value(response_headers, "transfer-encoding") == "chunked" then
      while true do
        local line, err1 = reader:read_line()
        if not line then
          ok, errmsg = false, err1
          break
        end

        local size = tonumber(line:match("^[0-9A-Fa-f]+"), 16)
        if not size then
          ok, errmsg = false, "invalid chunk size"
          break
        end

        if size == 0 then
          while true do
            local trailer, trailer_err = reader:read_line()
            if trailer_err then
              ok, errmsg = false, trailer_err
            end
            if trailer_err or trailer == "" then break end
          end
          break
        end

        local data, err2 = reader:read_n(size)
        if not data then
          ok, errmsg = false, err2
          break
        end

        internal_chunk_cb(data)

        local _, line_err = reader:read_line()
        if line_err then
          ok, errmsg = false, line_err
          break
        end
      end
    elseif get_header_value(response_headers, "content-length") then
      local remaining = tonumber(get_header_value(response_headers, "content-length"))
      while remaining > 0 do
        local to_read = math.min(4096, remaining)
        local data, err = reader:read_n(to_read)
        if not data then
          ok, errmsg = false, err
          break
        end
        remaining = remaining - #data
        internal_chunk_cb(data)
      end
    else
      while true do
        local data, err = reader:read_chunk(4096)
        if err then
          ok, errmsg = false, err
          break
        end
        if not data then break end
        internal_chunk_cb(data)
      end
    end

    conn:close()
    if ok == false then
      on_done(false, errmsg, nil, response_info)
      return
    end

    if want_stream then
      on_done(true, nil, nil, response_info)
      return
    end

    body = table.concat(response_chunks)
    local result = body

    local ct = get_header_value(response_headers, "content-type")
    if auto_decode and is_json_content_type(ct) then
      local decoded, jerr = json.decode(body)
      if decoded then
        result = decoded
      else
        on_done(false, "json decode error: " .. tostring(jerr), nil, response_info)
        return
      end
    end

    on_done(true, nil, result, response_info)
  end)
end

---@param method "GET" | "HEAD" | "OPTIONS"
---@param url string
---@param params? table<string,string>
---@param options http.request.options
local function query_request(method, url, params, options)
  assert(type(options) == "table", "provide the options object")
  assert(type(options.on_done) == "function", "provide the on_done callback")

  options = clone_options(options)
  url = append_query(url, params or {})
  return http.request(method, url, options)
end

---@param method "POST" | "PUT" | "DELETE" | "PATCH"
---@param url string
---@param submit_type http.request.submittype
---@param params? table<string,string>
---@param options http.request.options
local function body_request(method, url, submit_type, params, options)
  assert(type(options) == "table", "provide the options object")
  assert(type(options.on_done) == "function", "provide the on_done callback")

  options = clone_options(options)
  local body
  body, options.headers = prepare_body_and_headers(
    submit_type, params, options.body, options.headers
  )
  options.body = body
  return http.request(method, url, options)
end

---Open a Server-Sent Events stream.
---Supports normal SSE GET requests as well as POST-based SSE APIs.
---@param url string
---@param options http.sse.options
function http.sse(url, options)
  assert(type(options) == "table", "provide the options object")
  assert(type(options.on_event) == "function", "provide the on_event callback")
  assert(type(options.on_done) == "function", "provide the on_done callback")

  local method = options.method or "GET"
  local request_options = clone_options(options)
  request_options.method = nil
  request_options.submit_type = nil
  request_options.params = nil
  request_options.last_event_id = nil

  request_options.headers = clone_options(options.headers)
  if not request_options.headers.accept and not request_options.headers.Accept then
    request_options.headers.Accept = "text/event-stream"
  end
  if options.last_event_id and not request_options.headers["Last-Event-ID"] then
    request_options.headers["Last-Event-ID"] = options.last_event_id
  end

  local on_event = request_options.on_event
  local on_done = request_options.on_done
  request_options.on_event = nil

  local pending = ""
  local current_data = {}
  local current_info
  local current_event_name
  local current_event_id = options.last_event_id
  local current_retry

  local function reset_event()
    current_data = {}
    current_event_name = nil
    current_retry = nil
  end

  local function dispatch_event()
    if #current_data == 0 then
      reset_event()
      return
    end

    on_event({
      event = current_event_name or "message",
      data = table.concat(current_data, "\n"),
      id = current_event_id,
      retry = current_retry
    }, current_info)
    reset_event()
  end

  local function process_line(line)
    if line == "" then
      dispatch_event()
      return
    end

    if line:sub(1, 1) == ":" then
      return
    end

    local field, value = line:match("^([^:]+):?(.*)$")
    if not field then
      return
    end
    if value:sub(1, 1) == " " then
      value = value:sub(2)
    end

    if field == "event" then
      current_event_name = value
    elseif field == "data" then
      current_data[#current_data + 1] = value
    elseif field == "id" then
      if not value:find("\0", 1, true) then
        current_event_id = value
      end
    elseif field == "retry" then
      local retry = tonumber(value)
      if retry and retry >= 0 then
        current_retry = retry
      end
    end
  end

  request_options.on_header = function(info)
    current_info = info
    if options.on_header then
      options.on_header(info)
    end
  end

  request_options.on_chunk = function(chunk)
    pending = pending .. chunk

    while true do
      local idx = pending:find("\n", 1, true)
      if not idx then break end

      local line = pending:sub(1, idx - 1)
      pending = pending:sub(idx + 1)
      if line:sub(-1) == "\r" then
        line = line:sub(1, -2)
      end

      process_line(line)
    end
  end

  request_options.on_done = function(ok, err, _, info)
    if ok then
      if #pending > 0 then
        local line = pending
        if line:sub(-1) == "\r" then
          line = line:sub(1, -2)
        end
        process_line(line)
      end
      dispatch_event()
    end
    on_done(ok, err, info)
  end

  if is_query_method(method) then
    return query_request(method, url, options.params, request_options)
  end

  return body_request(
    method,
    url,
    options.submit_type or "application/json",
    options.params,
    request_options
  )
end

---HTTP GET
---@param url string
---@param params? table<string,string>
---@param options http.request.options
function http.get(url, params, options)
  return query_request("GET", url, params, options)
end

---HTTP HEAD
---@param url string
---@param params? table<string,string>
---@param options http.request.options
function http.head(url, params, options)
  return query_request("HEAD", url, params, options)
end

---HTTP OPTIONS
---@param url string
---@param params? table<string,string>
---@param options http.request.options
function http.options(url, params, options)
  return query_request("OPTIONS", url, params, options)
end

---HTTP POST
---@param url string
---@param submit_type http.request.submittype
---@param params? table<string,string>
---@param options http.request.options
function http.post(url, submit_type, params, options)
  return body_request("POST", url, submit_type, params, options)
end

---HTTP PUT
---@param url string
---@param submit_type http.request.submittype
---@param params? table<string,string>
---@param options http.request.options
function http.put(url, submit_type, params, options)
  return body_request("PUT", url, submit_type, params, options)
end

---HTTP DELETE
---@param url string
---@param submit_type http.request.submittype
---@param params? table<string,string>
---@param options http.request.options
function http.delete(url, submit_type, params, options)
  return body_request("DELETE", url, submit_type, params, options)
end

---HTTP PATCH
---@param url string
---@param submit_type http.request.submittype
---@param params? table<string,string>
---@param options http.request.options
function http.patch(url, submit_type, params, options)
  return body_request("PATCH", url, submit_type, params, options)
end

---@class http.download.options
---@field headers? table<string,string>
---@field filename? string
---@field directory? string Path to save the downloaded file
---@field on_done http.on_done_download
---@field on_progress? http.on_progress
---@field timeout? number
---@field is_cancelled? fun():boolean

---Download a file asynchronously with optional progress tracking.
---@param url string File URL
---@param options http.download.options
function http.download(url, options)
  assert(type(options) == "table", "provide the options object")
  assert(type(options.on_done) == "function", "provide the on_done callback")

  local headers = options.headers
  local directory = options.directory
  local filename = options.filename
  local on_done = options.on_done
  local on_progress = options.on_progress

  local f, total_downloaded, total_size = nil, 0, nil

  local function header_cb(info)
    if info.status < 200 or info.status >= 300 then return end

    local cd = get_header_value(info.headers, "content-disposition")
    if cd and not filename then
      filename = cd:match('filename="?([^"]+)"?')
    end
    if not filename then
      filename = url:match("/([^/]+)$") or "download"
    end
    if directory then
      common.mkdirp(directory)
      filename = directory:gsub(PATHSEP .. "+$", "") .. PATHSEP .. filename
    end

    local content_length = get_header_value(info.headers, "content-length")
    if content_length then
      total_size = tonumber(content_length)
    end
    f = assert(io.open(filename, "wb"))
  end

  local function chunk_cb(chunk)
    if not f then return end
    f:write(chunk)
    total_downloaded = total_downloaded + #chunk
    if on_progress then
      on_progress(total_downloaded, total_size)
    end
  end

  local function done_cb_inner(ok, err, _, info)
    if f then
      f:close()
      f = nil
    end

    if ok and info and (info.status < 200 or info.status >= 300) then
      ok = false
      err = "HTTP " .. tostring(info.status)
    end

    if not ok and filename then
      os.remove(filename)
    end

    on_done(ok, err, filename, info)
  end

  http.get(url, nil, {
    headers = headers,
    timeout = options.timeout,
    is_cancelled = options.is_cancelled,
    on_header = header_cb,
    on_chunk = chunk_cb,
    on_done = done_cb_inner
  })
end

-- Fetch or update ca bundle if no system provided one (windows, macOS)
local capath = net.get_cacert_path()
if capath == nil then
  local userca = USERDIR .. PATHSEP .. "cacert.pem"
  local userca_info = system.get_file_info(userca)
  local two_weeks = 86400 * 14
  if not userca_info or userca_info.modified + two_weeks < os.time() then
    http.download("https://curl.se/ca/cacert.pem", {
      directory = USERDIR,
      on_progress = function()
        DOWNLOADING_CACERT_BUNDLE = true
      end,
      on_done = function(ok, errmsg)
        DOWNLOADING_CACERT_BUNDLE = false
        if ok then
          net.set_cacert_path(userca)
        else
          core.error("Could not obtain CA bundle: %s", errmsg or "unknown error")
        end
      end
    })
  else
    net.set_cacert_path(userca)
  end
end

return http
