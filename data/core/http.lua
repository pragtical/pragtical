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

---@alias http.on_header fun(info:{status:integer, headers:table<string,string>})
---@alias http.on_chunk fun(chunk:string)
---@alias http.on_done fun(ok:boolean?, err:string?, result:string|table|nil)
---@alias http.on_done_download fun(ok:boolean?, err:string?, filename:string?)
---@alias http.on_progress fun(downloaded:integer, total:integer?)

---@class http.request.fileparam
---@field filename string
---@field content_type string
---@field data? string
---@field path? string

---@alias http.request.param string | http.request.fileparam

---Maximum amount of redirections allowed.
local MAX_REDIRECTS = 5

---Flag to check if CA bundle is been download before processing a request.
local DOWNLOADING_CACERT_BUNDLE=false

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

---@param params table<string,string>
local function encode_query(params)
  if not params then return "" end
  local t = {}
  for k, v in pairs(params) do
    t[#t+1] = urlencode(k) .. "=" .. urlencode(tostring(v))
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

      parts[#parts+1] =
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
      parts[#parts+1] =
        "--" .. boundary .. "\r\n" ..
        string.format(
          'Content-Disposition: form-data; name="%s"\r\n\r\n',
          name
        ) ..
        tostring(value) .. "\r\n"
    end
  end

  parts[#parts+1] = "--" .. boundary .. "--\r\n"
  return table.concat(parts)
end

---@param submit_type http.request.submittype
---@param params? table<string,string>
---@param body? string
---@param headers? table<string,string>
local function prepare_body_and_headers(submit_type, params, body, headers)
  headers = headers or {}

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
---@param headers table<string,string>?
---@param body string?
---@return string
local function build_request(method, path, host, headers, body)
  headers = headers or {}
  local normalized = {}
  for k, v in pairs(headers) do normalized[k:lower()] = v end
  if not normalized["user-agent"] and http.user_agent then
    normalized["user-agent"] = http.user_agent
  end

  local req = { string.format("%s %s HTTP/1.1", method, path) }
  req[#req+1] = "Host: "..host
  req[#req+1] = "Connection: close"
  if body then req[#req+1] = "Content-Length: "..#body end
  for k, v in pairs(normalized) do
    local header_name = k:gsub(
      "(%a)([%w%-]*)",
      function(first, rest)
        return first:upper() .. rest:lower()
      end
    )
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

---@param content_type string
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
---@field private redirect_count? integer

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

  local want_stream = type(on_chunk) == "function"
  local auto_decode = options.decode_json ~= false

  local response_chunks
  if not want_stream then
    response_chunks = {}
  end

  ---@diagnostic disable-next-line
  local redirect_count = options.redirect_count or 0

  if redirect_count > MAX_REDIRECTS then
    on_done(nil, "too many redirects")
    return
  end

  core.add_background_thread(function()
    local parsed, errurl = parse_url(url)
    if not parsed then on_done(nil, errurl) return end

    local addr, errhost = resolve_host(parsed.host)
    if not addr then on_done(nil, errhost) return end

    while DOWNLOADING_CACERT_BUNDLE and parsed.protocol == "https" do
      coroutine.yield(0.5)
    end

    local conn, errtcp = net.open_tcp(addr, parsed.port, parsed.protocol == "https")
    if not conn then on_done(nil, errtcp) return end

    while true do
      local status, errstatus = conn:get_status()
      if status == "success" then break end
      if status == "failure" then
        conn:close() on_done(nil, errstatus or "failed to connect")
        return
      end
      coroutine.yield(0.05)
    end

    local req_str = build_request(method, parsed.path, parsed.host, headers, body)
    write_all(conn, req_str)

    local header_lines = {}
    while true do
      local line, errread = read_line(conn)
      if errread then conn:close() on_done(nil, errread) return end
      if not line then coroutine.yield(0.01)
      else if line == "" then break end header_lines[#header_lines+1] = line end
    end

    local status_code, response_headers = parse_http_response_headers(header_lines)
    if not status_code then conn:close() on_done(nil, "invalid HTTP response") return end

    if on_redirect then on_redirect({status=status_code, headers=response_headers}) end

    if status_code >= 300 and status_code < 400 and response_headers["location"] then
      conn:close()
      local new_url = response_headers["location"]
      local new_method = method
      if status_code == 303 then new_method = "GET" body = nil end
      ---@diagnostic disable-next-line
      options.redirect_count = redirect_count + 1
      return http.request(new_method, new_url, options)
    end

    if on_header then on_header({status=status_code, headers=response_headers}) end

    local ok, errmsg
    local function internal_chunk_cb(chunk)
      if want_stream and on_chunk then
        on_chunk(chunk)
      else
        response_chunks[#response_chunks + 1] = chunk
      end
      coroutine.yield(0)
    end

    if response_headers["transfer-encoding"] == "chunked" then
      while true do
        local line, err1 = read_line(conn)
        if not line then ok, errmsg = false, err1 break end
        local size = tonumber(line:match("^[0-9A-Fa-f]+"),16)
        if size == 0 then break end
        local data, err2 = read_n(conn, size)
        if not data then ok, errmsg = false, err2 break end
        internal_chunk_cb(data)
        read_line(conn)
      end
    elseif response_headers["content-length"] then
      local remaining = tonumber(response_headers["content-length"])
      while remaining > 0 do
        local to_read = math.min(4096, remaining)
        local data, err = read_n(conn, to_read)
        if not data then ok, errmsg = false, err break end
        remaining = remaining - #data
        internal_chunk_cb(data)
      end
    else
      while true do
        local data, err = conn:read(4096)
        if err then ok, errmsg = false, err break end
        if not data or #data == 0 then
          coroutine.yield(0.01)
        else
          internal_chunk_cb(data)
        end
      end
    end

    conn:close()
    if ok == false then
      on_done(false, errmsg)
      return
    end

    if want_stream then
      on_done(true)
      return
    end

    body = table.concat(response_chunks)
    local result = body

    local ct = response_headers["content-type"]
    if auto_decode and is_json_content_type(ct) then
      local decoded, jerr =json.decode(body)
      if decoded then
        result = decoded
      else
        on_done(false, "json decode error: " .. tostring(jerr))
        return
      end
    end

    on_done(true, nil, result)
  end)
end

---@param method "GET" | "HEAD" | "OPTIONS"
---@param url string
---@param params? table<string,string>
---@param options http.request.options
local function query_request(method, url, params, options)
  assert(type(options) == "table", "provide the options object")
  assert(type(options.on_done) == "function", "provide the on_done callback")

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

  local body
  body, options.headers = prepare_body_and_headers(
    submit_type, params, options.body, options.headers
  )
  options.body = body
  return http.request(method, url, options)
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
    if info.status ~= 200 then return end
    local cd = info.headers["content-disposition"]
    if cd and not filename then
      filename = cd:match('filename="?([^"]+)"?')
    end
    if not filename then
      filename = url:match("/([^/]+)$") or "download"
    end
    if directory then
      common.mkdirp(directory)
      filename = directory:gsub(PATHSEP.."+$","")..PATHSEP..filename
    end
    if info.headers["content-length"] then
      total_size = tonumber(info.headers["content-length"])
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

  local function done_cb_inner(ok, err)
    if f then f:close() end
    on_done(ok, err, filename)
  end

  http.get(url, nil, {
    headers = headers,
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
      on_progress = function ()
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
