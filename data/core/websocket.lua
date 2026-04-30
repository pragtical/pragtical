---Coroutine-based WebSocket client for Pragtical Code Editor.
---Supports ws/wss connections, subprotocol negotiation, fragmented messages,
---automatic pong replies, optional keepalive pings, reconnect backoff,
---session restore hooks, and async callbacks.
---@class core.websocket
local websocket = {}

local core = require "core"
local bit = bit
if not bit then
  require "core.bit"
  bit = bit
end

local OPCODE_CONTINUATION = 0x0
local OPCODE_TEXT = 0x1
local OPCODE_BINARY = 0x2
local OPCODE_CLOSE = 0x8
local OPCODE_PING = 0x9
local OPCODE_PONG = 0xA

local CLOSE_NORMAL = 1000
local CLOSE_PROTOCOL_ERROR = 1002
local CLOSE_MESSAGE_TOO_BIG = 1009

local WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
local DEFAULT_READ_SIZE = 4096
local MAX_CONTROL_PAYLOAD = 125

---@alias websocket.status
---| "connecting"
---| "reconnecting"
---| "open"
---| "closing"
---| "closed"

---@alias websocket.header_value string|string[]

---@class websocket.response_info
---@field status integer
---@field headers table<string,websocket.header_value>
---@field url string
---@field protocol? string

---@class websocket.session_info
---@field attempt integer
---@field is_reconnect boolean
---@field previous_error? string
---@field previous_close_code? integer
---@field previous_close_reason? string
---@field previous_was_clean? boolean

---@class websocket.disconnect_info
---@field attempt integer
---@field error? string
---@field close_code? integer
---@field close_reason string
---@field was_clean boolean
---@field opened boolean

---@class websocket.reconnect_info: websocket.session_info
---@field delay number
---@field error? string
---@field close_code? integer
---@field close_reason string
---@field was_clean boolean
---@field opened boolean

---@alias websocket.on_connect fun(client:websocket.client, info:websocket.response_info, session:websocket.session_info)
---@alias websocket.on_message fun(client:websocket.client, message:string, is_binary:boolean)
---@alias websocket.on_close fun(client:websocket.client, code:integer?, reason:string?, was_clean:boolean)
---@alias websocket.on_error fun(client:websocket.client, err:string)
---@alias websocket.on_ping fun(client:websocket.client, payload:string)
---@alias websocket.on_pong fun(client:websocket.client, payload:string)
---@alias websocket.on_reconnect fun(client:websocket.client, info:websocket.reconnect_info)
---@alias websocket.should_reconnect fun(client:websocket.client, info:websocket.disconnect_info):boolean?
---@alias websocket.restore_session fun(client:websocket.client, info:websocket.session_info, response:websocket.response_info)

---@class websocket.connect.options
---@field headers? table<string,string>
---@field protocols? string|string[]
---@field timeout? number Inactivity timeout in seconds.
---@field ping_interval? number Seconds between automatic ping frames.
---@field ping_payload? string Payload used for automatic ping frames.
---@field reconnect? boolean Retry automatically after disconnections.
---@field reconnect_delay? number Initial reconnect delay in seconds. Default: 1
---@field reconnect_delay_max? number Maximum reconnect delay in seconds. Default: 30
---@field reconnect_backoff? number Backoff multiplier. Default: 2
---@field reconnect_jitter? number Random delay jitter in seconds. Default: 0
---@field max_reconnect_attempts? integer Maximum reconnect attempts. Unlimited when nil.
---@field is_cancelled? fun():boolean
---@field should_reconnect? websocket.should_reconnect
---@field on_connect? websocket.on_connect
---@field on_message? websocket.on_message
---@field on_close? websocket.on_close
---@field on_error? websocket.on_error
---@field on_ping? websocket.on_ping
---@field on_pong? websocket.on_pong
---@field on_reconnect? websocket.on_reconnect
---@field restore_session? websocket.restore_session

---@class websocket.client
---@field url string
---@field status websocket.status
---@field error string?
---@field protocol string?
---@field response_info websocket.response_info?
---@field reconnect_attempt integer
websocket.client = {}
websocket.client.__index = websocket.client

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

---@param headers table<string,websocket.header_value>
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

---@param headers table<string,websocket.header_value>?
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

---@param value string
---@return string
local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param headers table<string,websocket.header_value>
---@param key string
---@param token string
---@return boolean
local function header_contains_token(headers, key, token)
  local value = get_header_value(headers, key)
  if not value then return false end

  token = token:lower()
  for part in value:gmatch("[^,]+") do
    if trim(part):lower() == token then
      return true
    end
  end
  return false
end

---@param header_lines string[]
---@return integer? status
---@return table<string,websocket.header_value> headers
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

---@param url string
---@return table? parsed
---@return string? err
local function parse_url(url)
  local protocol, host, port, path = url:match("^(wss?)://([^/:?#]+):?(%d*)(.*)$")
  if not protocol then return nil, "invalid WebSocket URL" end

  port = tonumber(port) or (protocol == "wss" and 443 or 80)
  path = path ~= "" and path or "/"
  path = path:gsub("#.*$", "")
  if path == "" then path = "/" end
  if path:sub(1, 1) ~= "/" then
    path = "/" .. path
  end

  return {
    protocol = protocol,
    host = host,
    port = port,
    path = path
  }
end

---@param protocol string
---@param host string
---@param port integer
---@return string
local function build_host_header(protocol, host, port)
  local default_port = protocol == "wss" and 443 or 80
  if port == default_port then
    return host
  end
  return host .. ":" .. port
end

---@param data string
---@return string
local function base64_encode(data)
  local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local out = {}

  for i = 1, #data, 3 do
    local a = data:byte(i) or 0
    local b = data:byte(i + 1) or 0
    local c = data:byte(i + 2) or 0
    local triple = a * 65536 + b * 256 + c

    out[#out + 1] = alphabet:sub(math.floor(triple / 262144) % 64 + 1, math.floor(triple / 262144) % 64 + 1)
    out[#out + 1] = alphabet:sub(math.floor(triple / 4096) % 64 + 1, math.floor(triple / 4096) % 64 + 1)
    out[#out + 1] = i + 1 <= #data
      and alphabet:sub(math.floor(triple / 64) % 64 + 1, math.floor(triple / 64) % 64 + 1)
      or "="
    out[#out + 1] = i + 2 <= #data
      and alphabet:sub(triple % 64 + 1, triple % 64 + 1)
      or "="
  end

  return table.concat(out)
end

---@param value integer
---@return string
local function pack_u16be(value)
  return string.char(
    bit.band(bit.rshift(value, 8), 0xff),
    bit.band(value, 0xff)
  )
end

---@param value integer
---@return string
local function pack_u32be(value)
  return string.char(
    bit.band(bit.rshift(value, 24), 0xff),
    bit.band(bit.rshift(value, 16), 0xff),
    bit.band(bit.rshift(value, 8), 0xff),
    bit.band(value, 0xff)
  )
end

---@param hi integer
---@param lo integer
---@return string
local function pack_u64be(hi, lo)
  return pack_u32be(hi) .. pack_u32be(lo)
end

---@param data string
---@param index integer
---@return integer
local function read_u16be(data, index)
  local a, b = data:byte(index, index + 1)
  return a * 256 + b
end

---@param data string
---@param index integer
---@return integer
local function read_u32be(data, index)
  local a, b, c, d = data:byte(index, index + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

---@param value integer
---@param bits integer
---@return integer
local function left_rotate(value, bits)
  return bit.tobit(bit.bor(bit.lshift(value, bits), bit.rshift(value, 32 - bits)))
end

---@param data string
---@return string
local function sha1(data)
  local bytes = #data
  local bit_len_hi = math.floor(bytes / 0x20000000)
  local bit_len_lo = bit.band(bytes * 8, 0xffffffff)

  data = data .. "\128"
  while (#data % 64) ~= 56 do
    data = data .. "\0"
  end
  data = data .. pack_u32be(bit_len_hi) .. pack_u32be(bit_len_lo)

  local h0 = 0x67452301
  local h1 = 0xEFCDAB89
  local h2 = 0x98BADCFE
  local h3 = 0x10325476
  local h4 = 0xC3D2E1F0

  local w = {}
  for chunk = 1, #data, 64 do
    for i = 0, 15 do
      w[i] = read_u32be(data, chunk + i * 4)
    end
    for i = 16, 79 do
      w[i] = left_rotate(bit.bxor(bit.bxor(w[i - 3], w[i - 8]), bit.bxor(w[i - 14], w[i - 16])), 1)
    end

    local a, b, c, d, e = h0, h1, h2, h3, h4
    for i = 0, 79 do
      local f, k
      if i < 20 then
        f = bit.bor(bit.band(b, c), bit.band(bit.bnot(b), d))
        k = 0x5A827999
      elseif i < 40 then
        f = bit.bxor(bit.bxor(b, c), d)
        k = 0x6ED9EBA1
      elseif i < 60 then
        f = bit.bor(bit.bor(bit.band(b, c), bit.band(b, d)), bit.band(c, d))
        k = 0x8F1BBCDC
      else
        f = bit.bxor(bit.bxor(b, c), d)
        k = 0xCA62C1D6
      end

      local temp = bit.tobit(left_rotate(a, 5) + f + e + k + w[i])
      e = d
      d = c
      c = left_rotate(b, 30)
      b = a
      a = temp
    end

    h0 = bit.tobit(h0 + a)
    h1 = bit.tobit(h1 + b)
    h2 = bit.tobit(h2 + c)
    h3 = bit.tobit(h3 + d)
    h4 = bit.tobit(h4 + e)
  end

  return pack_u32be(h0) .. pack_u32be(h1) .. pack_u32be(h2) .. pack_u32be(h3) .. pack_u32be(h4)
end

---@return string
local function random_bytes(count)
  local bytes = {}
  for i = 1, count do
    bytes[i] = string.char(math.random(0, 255))
  end
  return table.concat(bytes)
end

---@param delay number
---@param jitter number
---@return number
local function apply_jitter(delay, jitter)
  if jitter <= 0 then
    return delay
  end
  return math.max(0, delay + ((math.random() * 2) - 1) * jitter)
end

---@param payload string
---@param mask_key string
---@return string
local function mask_payload(payload, mask_key)
  local mask1, mask2, mask3, mask4 = mask_key:byte(1, 4)
  local out = {}

  for i = 1, #payload do
    local mask_byte
    local mod = (i - 1) % 4
    if mod == 0 then
      mask_byte = mask1
    elseif mod == 1 then
      mask_byte = mask2
    elseif mod == 2 then
      mask_byte = mask3
    else
      mask_byte = mask4
    end
    out[i] = string.char(bit.bxor(payload:byte(i), mask_byte))
  end

  return table.concat(out)
end

---@param payload string
---@param code? integer
---@return integer? close_code
---@return string? reason
---@return string? err
local function decode_close_payload(payload, code)
  if #payload == 0 then
    return code, "", nil
  end
  if #payload == 1 then
    return nil, nil, "invalid close payload"
  end

  return read_u16be(payload, 1), payload:sub(3), nil
end

---@param code? integer
---@param reason? string
---@return string
local function encode_close_payload(code, reason)
  if code == nil then
    return ""
  end

  reason = reason or ""
  return pack_u16be(code) .. reason
end

---@param protocol string
---@return boolean
local function is_valid_scheme(protocol)
  return protocol == "ws" or protocol == "wss"
end

---@param client websocket.client
---@param opcode integer
---@param payload string
---@param fin? boolean
---@return boolean?, string?
local function enqueue_frame(client, opcode, payload, fin)
  if client.status == "closed" then
    return nil, "websocket is closed"
  end

  if client.status == "closing"
    and opcode ~= OPCODE_CLOSE
    and opcode ~= OPCODE_PONG
  then
    return nil, "websocket is closing"
  end

  client._send_queue[#client._send_queue + 1] = {
    opcode = opcode,
    payload = payload or "",
    fin = fin ~= false
  }
  return true
end

---@param client websocket.client
---@param code integer
---@param reason string
local function request_close(client, code, reason)
  if client._close_sent then return end

  client._close_sent = true
  client._close_request_code = code
  client._close_request_reason = reason
  client.status = "closing"
  enqueue_frame(client, OPCODE_CLOSE, encode_close_payload(code, reason))
end

---@param conn net.tcp
---@param data string
---@param should_abort fun():string?
---@param touch fun()
---@return boolean?, string?
local function write_all(conn, data, should_abort, touch)
  local total_sent = 0
  while total_sent < #data do
    local abort_err = should_abort()
    if abort_err then return nil, abort_err end

    local ok, err = conn:write(data:sub(total_sent + 1))
    if err then return nil, err end
    if not ok then
      coroutine.yield(0.01)
    else
      total_sent = #data
      touch()
    end
  end

  while true do
    local abort_err = should_abort()
    if abort_err then return nil, abort_err end

    local pending, err = conn:wait_until_drained(0)
    if err then return nil, err end
    if pending == 0 then break end
    coroutine.yield(0.01)
  end

  return true
end

---@param conn net.tcp
---@param should_abort fun():string?
---@param touch fun()
---@return fun():string?,string?
local function make_line_reader(conn, should_abort, touch)
  local buffer = ""

  return function()
    while true do
      local idx = buffer:find("\r\n", 1, true)
      if idx then
        local line = buffer:sub(1, idx - 1)
        buffer = buffer:sub(idx + 2)
        return line
      end

      local abort_err = should_abort()
      if abort_err then return nil, abort_err end

      local chunk, err = conn:read(DEFAULT_READ_SIZE)
      if err then return nil, err end
      if chunk == nil then return nil, "connection closed" end

      if #chunk > 0 then
        buffer = buffer .. chunk
        touch()
      else
        coroutine.yield(0.01)
      end
    end
  end
end

---@param payload_len integer
---@return string
local function encode_length(payload_len)
  if payload_len < 126 then
    return string.char(0x80 + payload_len)
  end
  if payload_len < 65536 then
    return string.char(0x80 + 126) .. pack_u16be(payload_len)
  end

  local hi = math.floor(payload_len / 0x100000000)
  local lo = payload_len % 0x100000000
  return string.char(0x80 + 127) .. pack_u64be(hi, lo)
end

---@param opcode integer
---@param payload string
---@param fin boolean
---@return string
local function encode_frame(opcode, payload, fin)
  local first = (fin and 0x80 or 0) + opcode
  local mask_key = random_bytes(4)
  local masked_payload = mask_payload(payload, mask_key)
  return string.char(first) .. encode_length(#payload) .. mask_key .. masked_payload
end

---@param buffer string
---@return table? frame
---@return string? rest
---@return string? err
local function try_extract_frame(buffer)
  if #buffer < 2 then return nil, nil, nil end

  local b1, b2 = buffer:byte(1, 2)
  local fin = bit.band(b1, 0x80) ~= 0
  local rsv = bit.band(b1, 0x70)
  local opcode = bit.band(b1, 0x0f)
  local masked = bit.band(b2, 0x80) ~= 0
  local payload_len = bit.band(b2, 0x7f)
  local index = 3

  if rsv ~= 0 then
    return nil, nil, "RSV bits are not supported"
  end

  if payload_len == 126 then
    if #buffer < index + 1 then return nil, nil, nil end
    payload_len = read_u16be(buffer, index)
    index = index + 2
  elseif payload_len == 127 then
    if #buffer < index + 7 then return nil, nil, nil end
    local hi = read_u32be(buffer, index)
    local lo = read_u32be(buffer, index + 4)
    if hi >= 0x200000 then
      return nil, nil, "frame payload is too large"
    end
    payload_len = hi * 0x100000000 + lo
    index = index + 8
  end

  local mask_key
  if masked then
    if #buffer < index + 3 then return nil, nil, nil end
    mask_key = buffer:sub(index, index + 3)
    index = index + 4
  end

  local payload_end = index + payload_len - 1
  if #buffer < payload_end then
    return nil, nil, nil
  end

  local payload = payload_len > 0 and buffer:sub(index, payload_end) or ""
  local rest = buffer:sub(payload_end + 1)
  if masked then
    payload = mask_payload(payload, mask_key)
  end

  return {
    fin = fin,
    opcode = opcode,
    masked = masked,
    payload = payload
  }, rest, nil
end

---@param client websocket.client
---@param options websocket.connect.options
---@return websocket.client
function websocket.client.new(url, options)
  local self = setmetatable({
    url = url,
    status = "connecting",
    error = nil,
    protocol = nil,
    response_info = nil,
    reconnect_attempt = 0,
    _options = clone_value(options or {}),
    _send_queue = {},
    _recv_buffer = "",
    _conn = nil,
    _did_open = false,
    _manual_close = nil,
    _close_requested = nil,
    _close_sent = false,
    _close_received = false,
    _close_request_code = nil,
    _close_request_reason = nil,
    _remote_close_code = nil,
    _remote_close_reason = nil,
    _message_opcode = nil,
    _message_parts = nil,
    _last_ping_time = nil
  }, websocket.client)

  core.add_background_thread(function()
    self:_run()
  end, self)

  return self
end

---Get the current connection status.
---@return websocket.status status
---@return string? errmsg
function websocket.client:get_status()
  return self.status, self.error
end

---Queue a text message for sending.
---@param data string
---@return boolean?, string?
function websocket.client:send_text(data)
  assert(type(data) == "string", "provide the message string")
  return enqueue_frame(self, OPCODE_TEXT, data)
end

---Queue a text message for sending.
---@param data string
---@return boolean?, string?
function websocket.client:send(data)
  return self:send_text(data)
end

---Queue a binary message for sending.
---@param data string
---@return boolean?, string?
function websocket.client:send_binary(data)
  assert(type(data) == "string", "provide the message bytes")
  return enqueue_frame(self, OPCODE_BINARY, data)
end

---Queue a ping frame for sending.
---@param payload? string
---@return boolean?, string?
function websocket.client:ping(payload)
  payload = payload or ""
  assert(type(payload) == "string", "provide the ping payload string")

  if #payload > MAX_CONTROL_PAYLOAD then
    return nil, "ping payload is too large"
  end
  return enqueue_frame(self, OPCODE_PING, payload)
end

---Close the connection.
---@param code? integer
---@param reason? string
---@return boolean?, string?
function websocket.client:close(code, reason)
  code = code or CLOSE_NORMAL
  reason = reason or ""
  self._manual_close = { code = code, reason = reason }

  if self.status == "closed" then
    return true
  end

  if self.status == "connecting" then
    self.status = "closing"
    self._close_requested = { code = code, reason = reason }
    return true
  end

  request_close(self, code, reason)
  return true
end

---@param self websocket.client
---@param err string
local function emit_error(self, err)
  self.error = err
  if self._options.on_error then
    self._options.on_error(self, err)
  end
end

---@param self websocket.client
---@param code integer?
---@param reason string?
---@param was_clean boolean
local function emit_close(self, code, reason, was_clean)
  if self._options.on_close then
    self._options.on_close(self, code, reason, was_clean)
  end
end

---@param self websocket.client
function websocket.client:_reset_session_state()
  self._recv_buffer = ""
  self._conn = nil
  self._did_open = false
  self._close_sent = false
  self._close_received = false
  self._close_request_code = nil
  self._close_request_reason = nil
  self._remote_close_code = nil
  self._remote_close_reason = nil
  self._message_opcode = nil
  self._message_parts = nil
  self._last_ping_time = nil
end

---@param self websocket.client
function websocket.client:_drop_stale_control_frames()
  if #self._send_queue == 0 then return end

  local filtered = {}
  for _, frame in ipairs(self._send_queue) do
    if frame.opcode ~= OPCODE_CLOSE and frame.opcode ~= OPCODE_PONG then
      filtered[#filtered + 1] = frame
    end
  end
  self._send_queue = filtered
end

---@param self websocket.client
---@param attempt integer
---@param previous_outcome websocket.disconnect_info?
---@return websocket.session_info
function websocket.client:_build_session_info(attempt, previous_outcome)
  return {
    attempt = attempt,
    is_reconnect = attempt > 0,
    previous_error = previous_outcome and previous_outcome.error or nil,
    previous_close_code = previous_outcome and previous_outcome.close_code or nil,
    previous_close_reason = previous_outcome and previous_outcome.close_reason or nil,
    previous_was_clean = previous_outcome and previous_outcome.was_clean or nil
  }
end

---@param self websocket.client
---@param attempt integer
---@return number
function websocket.client:_get_reconnect_delay(attempt)
  local base = self._options.reconnect_delay or 1
  local max_delay = self._options.reconnect_delay_max or 30
  local backoff = self._options.reconnect_backoff or 2
  local jitter = self._options.reconnect_jitter or 0

  local delay = math.min(base * (backoff ^ math.max(attempt - 1, 0)), max_delay)
  return apply_jitter(delay, jitter)
end

---@param self websocket.client
---@param delay number
---@return string?
function websocket.client:_wait_reconnect(delay)
  local start = system.get_time()
  while system.get_time() - start < delay do
    if self._manual_close then
      return "__websocket_close_requested__"
    end
    if type(self._options.is_cancelled) == "function" and self._options.is_cancelled() then
      return "websocket cancelled"
    end
    coroutine.yield(math.min(0.05, delay))
  end
end

---@param self websocket.client
---@param outcome websocket.disconnect_info
---@param attempt integer
---@return boolean
function websocket.client:_should_reconnect(outcome, attempt)
  if not self._options.reconnect then
    return false
  end
  if self._manual_close or self._close_requested then
    return false
  end
  if type(self._options.is_cancelled) == "function" and self._options.is_cancelled() then
    return false
  end
  if self._options.max_reconnect_attempts and attempt > self._options.max_reconnect_attempts then
    return false
  end

  if self._options.should_reconnect then
    local decision = self._options.should_reconnect(self, outcome)
    if decision ~= nil then
      return decision
    end
  end

  return true
end

---@param self websocket.client
---@param touch fun()
---@param should_abort fun():string?
---@return boolean?, string?
function websocket.client:_flush_send_queue(touch, should_abort)
  local did_work = false

  while #self._send_queue > 0 do
    local frame = table.remove(self._send_queue, 1)
    local encoded = encode_frame(frame.opcode, frame.payload, frame.fin)
    local ok, err = write_all(self._conn, encoded, should_abort, touch)
    if not ok then
      return nil, err
    end
    did_work = true
  end

  return did_work
end

---@param self websocket.client
---@param payload string
local function protocol_error(self, payload)
  if not self._close_sent and self.status ~= "closed" then
    request_close(self, CLOSE_PROTOCOL_ERROR, payload)
  end
end

---@param self websocket.client
---@param payload string
local function message_too_big(self, payload)
  if not self._close_sent and self.status ~= "closed" then
    request_close(self, CLOSE_MESSAGE_TOO_BIG, payload)
  end
end

---@param self websocket.client
---@param frame table
---@return boolean did_work
---@return boolean should_stop
---@return string? err
function websocket.client:_handle_frame(frame)
  if frame.masked then
    protocol_error(self, "masked server frame")
    return true, true, "websocket protocol error: masked server frame"
  end

  local opcode = frame.opcode
  local payload = frame.payload

  if opcode >= 0x8 then
    if not frame.fin then
      protocol_error(self, "fragmented control frame")
      return true, true, "websocket protocol error: fragmented control frame"
    end
    if #payload > MAX_CONTROL_PAYLOAD then
      protocol_error(self, "oversized control frame")
      return true, true, "websocket protocol error: oversized control frame"
    end

    if opcode == OPCODE_CLOSE then
      local code, reason, err = decode_close_payload(payload)
      if err then
        protocol_error(self, "invalid close payload")
        return true, true, "websocket protocol error: invalid close payload"
      end

      self._close_received = true
      self._remote_close_code = code
      self._remote_close_reason = reason

      if not self._close_sent then
        request_close(self, code or CLOSE_NORMAL, reason or "")
      end

      return true, true, nil
    elseif opcode == OPCODE_PING then
      enqueue_frame(self, OPCODE_PONG, payload)
      if self._options.on_ping then
        self._options.on_ping(self, payload)
      end
      return true, false, nil
    elseif opcode == OPCODE_PONG then
      if self._options.on_pong then
        self._options.on_pong(self, payload)
      end
      return true, false, nil
    end

    protocol_error(self, "unsupported control opcode")
    return true, true, "websocket protocol error: unsupported control opcode"
  end

  if opcode == OPCODE_CONTINUATION then
    if not self._message_opcode then
      protocol_error(self, "unexpected continuation frame")
      return true, true, "websocket protocol error: unexpected continuation frame"
    end

    self._message_parts[#self._message_parts + 1] = payload
    if frame.fin then
      local message = table.concat(self._message_parts)
      local is_binary = self._message_opcode == OPCODE_BINARY
      self._message_opcode = nil
      self._message_parts = nil

      if self._options.on_message then
        self._options.on_message(self, message, is_binary)
      end
    end
    return true, false, nil
  end

  if opcode ~= OPCODE_TEXT and opcode ~= OPCODE_BINARY then
    protocol_error(self, "unsupported data opcode")
    return true, true, "websocket protocol error: unsupported data opcode"
  end

  if self._message_opcode then
    protocol_error(self, "interleaved fragmented message")
    return true, true, "websocket protocol error: interleaved fragmented message"
  end

  if frame.fin then
    if self._options.on_message then
      self._options.on_message(self, payload, opcode == OPCODE_BINARY)
    end
  else
    self._message_opcode = opcode
    self._message_parts = { payload }
  end

  return true, false, nil
end

---@param self websocket.client
---@param touch fun()
---@return boolean did_work
---@return boolean should_stop
---@return string? err
function websocket.client:_pump_incoming(touch)
  local chunk, err = self._conn:read(DEFAULT_READ_SIZE)
  if err then
    return false, false, err
  end
  if chunk == nil then
    if self._close_received or self.status == "closing" then
      return false, true, nil
    end
    return false, true, "connection closed"
  end

  if #chunk == 0 then
    return false, false, nil
  end

  self._recv_buffer = self._recv_buffer .. chunk
  touch()

  local did_work = true
  while true do
    local frame, rest, frame_err = try_extract_frame(self._recv_buffer)
    if frame_err then
      if frame_err == "frame payload is too large" then
        message_too_big(self, frame_err)
      else
        protocol_error(self, "invalid frame header")
      end
      return true, true, "websocket protocol error: " .. frame_err
    end
    if not frame then
      break
    end

    self._recv_buffer = rest
    local _, should_stop, err2 = self:_handle_frame(frame)
    if err2 or should_stop then
      return did_work, should_stop, err2
    end
  end

  return did_work, false, nil
end

---@param self websocket.client
---@param self websocket.client
---@param parsed table
---@param session_info websocket.session_info
---@return websocket.disconnect_info
function websocket.client:_run_session(parsed, session_info)
  local options = self._options
  local timeout = options.timeout
  local ping_interval = options.ping_interval
  local ping_payload = options.ping_payload or ""
  local is_cancelled = options.is_cancelled
  self:_reset_session_state()
  self:_drop_stale_control_frames()
  self.error = nil
  self.reconnect_attempt = session_info.attempt

  local last_activity = system.get_time()
  local function touch()
    last_activity = system.get_time()
  end

  local function should_abort()
    if self._close_requested and not self._did_open then
      return "__websocket_close_requested__"
    end
    if type(is_cancelled) == "function" and is_cancelled() then
      return "websocket cancelled"
    end
    if timeout and system.get_time() - last_activity >= timeout then
      return "websocket timed out"
    end
  end

  local addr, errhost = net.resolve_address(parsed.host)
  if not addr then
    self.status = "closed"
    return {
      attempt = session_info.attempt,
      error = errhost,
      close_code = nil,
      close_reason = "",
      was_clean = false,
      opened = false
    }
  end

  while true do
    local abort_err = should_abort()
    if abort_err then
      self.status = "closed"
      return {
        attempt = session_info.attempt,
        error = abort_err ~= "__websocket_close_requested__" and abort_err or nil,
        close_code = self._close_requested and self._close_requested.code or nil,
        close_reason = self._close_requested and self._close_requested.reason or "",
        was_clean = false,
        opened = false
      }
    end

    local status, resolve_err = addr:get_status()
    if status == "success" then break end
    if status == "failure" then
      self.status = "closed"
      return {
        attempt = session_info.attempt,
        error = resolve_err or "failed to resolve host",
        close_code = nil,
        close_reason = "",
        was_clean = false,
        opened = false
      }
    end
    coroutine.yield(0.05)
  end

  local conn, errtcp = net.open_tcp(addr, parsed.port, parsed.protocol == "wss")
  if not conn then
    self.status = "closed"
    emit_error(self, errtcp)
    return
  end
  self._conn = conn

  while true do
    local abort_err = should_abort()
    if abort_err then
      conn:close()
      self.status = "closed"
      self._conn = nil
      return {
        attempt = session_info.attempt,
        error = abort_err ~= "__websocket_close_requested__" and abort_err or nil,
        close_code = self._close_requested and self._close_requested.code or nil,
        close_reason = self._close_requested and self._close_requested.reason or "",
        was_clean = false,
        opened = false
      }
    end

    local status, connect_err = conn:get_status()
    if status == "success" then break end
    if status == "failure" then
      conn:close()
      self.status = "closed"
      self._conn = nil
      return {
        attempt = session_info.attempt,
        error = connect_err or "failed to connect",
        close_code = nil,
        close_reason = "",
        was_clean = false,
        opened = false
      }
    end
    coroutine.yield(0.05)
  end

  local websocket_key = base64_encode(random_bytes(16))
  local expected_accept = base64_encode(sha1(websocket_key .. WEBSOCKET_GUID))
  local request_headers = clone_value(options.headers or {})

  if not request_headers["User-Agent"] and not request_headers["user-agent"] and VERSION then
    request_headers["User-Agent"] = "Pragtical/" .. VERSION
  end

  if options.protocols then
    if type(options.protocols) == "table" then
      request_headers["Sec-WebSocket-Protocol"] = table.concat(options.protocols, ", ")
    else
      request_headers["Sec-WebSocket-Protocol"] = tostring(options.protocols)
    end
  end

  local req = {
    string.format("GET %s HTTP/1.1", parsed.path),
    "Host: " .. build_host_header(parsed.protocol, parsed.host, parsed.port),
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Version: 13",
    "Sec-WebSocket-Key: " .. websocket_key,
  }

  for k, v in pairs(request_headers) do
    req[#req + 1] = k .. ": " .. v
  end
  req[#req + 1] = ""
  req[#req + 1] = ""

  local sent, write_err = write_all(conn, table.concat(req, "\r\n"), should_abort, touch)
  if not sent then
    conn:close()
    self.status = "closed"
    self._conn = nil
    return {
      attempt = session_info.attempt,
      error = write_err,
      close_code = nil,
      close_reason = "",
      was_clean = false,
      opened = false
    }
  end

  local read_line = make_line_reader(conn, should_abort, touch)
  local header_lines = {}
  while true do
    local line, line_err = read_line()
    if line_err then
      conn:close()
      self.status = "closed"
      self._conn = nil
      return {
        attempt = session_info.attempt,
        error = line_err ~= "__websocket_close_requested__" and line_err or nil,
        close_code = self._close_requested and self._close_requested.code or nil,
        close_reason = self._close_requested and self._close_requested.reason or "",
        was_clean = false,
        opened = false
      }
    end
    if line == "" then break end
    header_lines[#header_lines + 1] = line
  end

  local status_code, response_headers = parse_http_response_headers(header_lines)
  if status_code ~= 101 then
    conn:close()
    self.status = "closed"
    self._conn = nil
    return {
      attempt = session_info.attempt,
      error = "websocket handshake failed with status " .. tostring(status_code or "unknown"),
      close_code = nil,
      close_reason = "",
      was_clean = false,
      opened = false
    }
  end

  if not header_contains_token(response_headers, "upgrade", "websocket") then
    conn:close()
    self.status = "closed"
    self._conn = nil
    return {
      attempt = session_info.attempt,
      error = "websocket handshake missing Upgrade: websocket",
      close_code = nil,
      close_reason = "",
      was_clean = false,
      opened = false
    }
  end
  if not header_contains_token(response_headers, "connection", "upgrade") then
    conn:close()
    self.status = "closed"
    self._conn = nil
    return {
      attempt = session_info.attempt,
      error = "websocket handshake missing Connection: Upgrade",
      close_code = nil,
      close_reason = "",
      was_clean = false,
      opened = false
    }
  end
  if get_header_value(response_headers, "sec-websocket-accept") ~= expected_accept then
    conn:close()
    self.status = "closed"
    self._conn = nil
    return {
      attempt = session_info.attempt,
      error = "websocket handshake validation failed",
      close_code = nil,
      close_reason = "",
      was_clean = false,
      opened = false
    }
  end

  self._did_open = true
  self.status = "open"
  self.protocol = get_header_value(response_headers, "sec-websocket-protocol")
  self.response_info = {
    status = status_code,
    headers = response_headers,
    url = self.url,
    protocol = self.protocol
  }

  if session_info.is_reconnect and options.restore_session then
    options.restore_session(self, session_info, self.response_info)
  end
  if options.on_connect then
    options.on_connect(self, self.response_info, session_info)
  end

  if self._close_requested then
    request_close(self, self._close_requested.code, self._close_requested.reason)
  end

  local terminal_err
  local stop_after_flush = false

  while true do
    local abort_err = should_abort()
    if abort_err then
      terminal_err = abort_err == "__websocket_close_requested__" and nil or abort_err
      if abort_err == "__websocket_close_requested__" and self._close_requested then
        self._remote_close_code = self._close_requested.code
        self._remote_close_reason = self._close_requested.reason
      end
      break
    end

    if ping_interval and ping_interval > 0 and not self._close_sent then
      local now = system.get_time()
      if not self._last_ping_time or now - self._last_ping_time >= ping_interval then
        enqueue_frame(self, OPCODE_PING, ping_payload)
        self._last_ping_time = now
      end
    end

    local sent_now, send_err = self:_flush_send_queue(touch, should_abort)
    if send_err then
      terminal_err = send_err
      break
    end

    local read_now, should_stop, read_err = self:_pump_incoming(touch)
    if read_err then
      terminal_err = read_err
      stop_after_flush = true
    elseif should_stop then
      stop_after_flush = true
    end

    if stop_after_flush and #self._send_queue == 0 then
      break
    end

    if not sent_now and not read_now then
      coroutine.yield(0.01)
    end
  end

  conn:close()
  self._conn = nil
  self.status = "closed"

  local close_code = self._remote_close_code or self._close_request_code
  local close_reason = self._remote_close_reason or self._close_request_reason or ""
  local was_clean = self._close_received and not terminal_err

  return {
    attempt = session_info.attempt,
    error = terminal_err,
    close_code = close_code,
    close_reason = close_reason,
    was_clean = was_clean,
    opened = true
  }
end

---@param self websocket.client
function websocket.client:_run()
  math.randomseed(math.floor(system.get_time() * 1000000) % 0x7fffffff)

  local parsed, err = parse_url(self.url)
  if not parsed then
    self.status = "closed"
    emit_error(self, err)
    return
  end
  if not is_valid_scheme(parsed.protocol) then
    self.status = "closed"
    emit_error(self, "unsupported WebSocket scheme")
    return
  end

  local previous_outcome
  local attempt = 0

  while true do
    self.status = attempt > 0 and "reconnecting" or "connecting"
    local session_info = self:_build_session_info(attempt, previous_outcome)
    local outcome = self:_run_session(parsed, session_info)

    if outcome.error then
      emit_error(self, outcome.error)
    end

    local next_attempt = attempt + 1
    if not self:_should_reconnect(outcome, next_attempt) then
      self.status = "closed"
      if outcome.opened or self._manual_close or self._close_requested then
        emit_close(self, outcome.close_code, outcome.close_reason, outcome.was_clean)
      end
      return
    end

    local delay = self:_get_reconnect_delay(next_attempt)
    local reconnect_info = {
      attempt = next_attempt,
      is_reconnect = true,
      delay = delay,
      error = outcome.error,
      close_code = outcome.close_code,
      close_reason = outcome.close_reason,
      was_clean = outcome.was_clean,
      opened = outcome.opened,
      previous_error = outcome.error,
      previous_close_code = outcome.close_code,
      previous_close_reason = outcome.close_reason,
      previous_was_clean = outcome.was_clean
    }

    self.status = "reconnecting"
    if self._options.on_reconnect then
      self._options.on_reconnect(self, reconnect_info)
    end

    local wait_err = self:_wait_reconnect(delay)
    if wait_err then
      self.status = "closed"
      if wait_err ~= "__websocket_close_requested__" then
        emit_error(self, wait_err)
      end
      if self._manual_close or self._close_requested or outcome.opened then
        local close_code = (self._manual_close and self._manual_close.code)
          or (self._close_requested and self._close_requested.code)
          or outcome.close_code
        local close_reason = (self._manual_close and self._manual_close.reason)
          or (self._close_requested and self._close_requested.reason)
          or outcome.close_reason
        emit_close(self, close_code, close_reason or "", false)
      end
      return
    end

    previous_outcome = outcome
    attempt = next_attempt
  end
end

---Open a WebSocket connection asynchronously.
---@param url string
---@param options? websocket.connect.options
---@return websocket.client client
function websocket.connect(url, options)
  assert(type(url) == "string", "provide the WebSocket URL")
  assert(options == nil or type(options) == "table", "provide the options table")
  return websocket.client.new(url, options or {})
end

return websocket
