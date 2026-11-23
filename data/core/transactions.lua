local common = require "core.common"
local storage = require "core.storage"

local root = USERDIR .. PATHSEP .. "transactions"

---@class core.transactions
local transactions = {}

---@alias core.transactions.phase
---| "startup" # Before editor initialization on a full launch; skipped on soft restart.

---@class core.transactions.key
---@field phase? core.transactions.phase Defaults to "startup".
---@field id? string Optional qualifier for multiple requests for the same script.

---@alias core.transactions.payload string|number|boolean|table

---@class core.transactions.options : core.transactions.key
---@field title? string
---@field payload? core.transactions.payload Plain serialized data.

---Second return value from a transaction handler when its first return value is nil.
---@class core.transactions.failure
---@field message string Explanation shown to the user.
---@field retry? boolean Try again on the next full launch instead of marking the request failed.
---@field recovery_required? boolean Leave the request in progress for manual recovery, even if retry is set.

---Return `true` on success, or `nil, failure` on failure.
---Return `nil, { message = "...", retry = true }` to retry on the next full startup.
---@alias core.transactions.handler fun(id: string, payload: core.transactions.payload?, ctx: core.transactions.context): true|nil,core.transactions.failure?

---@class core.transactions.record
---@field script string
---@field id? string
---@field phase core.transactions.phase
---@field state "ready"|"in_progress"|"failed"
---@field title string
---@field payload? core.transactions.payload
---@field last_failure? core.transactions.failure

---The runner passes a fresh context to each handler. Plugins do not construct it.
---@class core.transactions.context
---@field phase core.transactions.phase Phase in which this handler is running.
---@field previous_failure? core.transactions.failure Saved reason from the previous attempt, if any.
---@field private log fun(message: string)
---@field private last_message? string
---@field package fraction? number
---@field package detail? string
local Context = {}
Context.__index = Context

---Report an activity and yield so the runner can redraw. Repeating the same
---message updates the progress indicator without adding another log entry.
---@param message string
---@param fraction? number Fraction complete (0 to 1). Omit if the total is unknown.
---@param detail? string Transient status, such as the number of bytes downloaded.
function Context:progress(message, fraction, detail)
  self.fraction = type(fraction) == "number" and math.max(0, math.min(1, fraction)) or nil
  self.detail = detail
  message = tostring(message)
  if message ~= self.last_message then
    self.log(message)
    self.last_message = message
  end
  coroutine.yield()
end

---Give the runner a chance to redraw without changing the current progress.
function Context:yield()
  coroutine.yield()
end

local states = { "ready", "in_progress", "failed" }

---Validate the handler name and optional ID before using them as a filename stem.
local function stem_for(script, id)
  if type(script) ~= "string" or not script:match("^plugins%.[%w_.%-]+$")
    or script:find("..", 1, true) or script:sub(-1) == "." then
    return nil, "invalid transaction handler name"
  end
  if id ~= nil and (type(id) ~= "string" or not id:match("^[%w_%-]+$")) then
    return nil, "invalid transaction ID"
  end
  return id and script .. "." .. id or script
end

---Serialize queue file operations across editor instances, not handler execution.
---Only registration creates a missing phase directory.
local function locked(phase, create, callback)
  if phase ~= "startup" then return nil, "unknown transaction phase" end
  local dir = root .. PATHSEP .. phase
  if create then
    local ok, err = common.mkdirp(dir)
    if not ok and not system.get_file_info(dir) then return nil, err end
  elseif not system.get_file_info(dir) then
    return
  end
  local guard = dir .. PATHSEP .. ".writing"
  local acquired, err = system.mkdir(guard)
  if not acquired then
    return nil, system.get_file_info(guard) and "busy" or err
  end
  local called, result, callback_error = pcall(callback)
  local released, release_error = system.rmdir(guard)
  if not called then return nil, result end
  if not released then return nil, release_error end
  return result, callback_error
end

---Read the one record for a stem and derive its state from the filename.
---When the caller supplies a script and ID, reject collisions with another key.
local function read(phase, stem, script, id)
  local record, filename
  for _, state in ipairs(states) do
    local name = stem .. "." .. state .. ".lua"
    local path = root .. PATHSEP .. phase .. PATHSEP .. name
    if system.get_file_info(path) then
      if record then return nil, "multiple state files for " .. stem end
      local data, err = storage.load(phase, name, root)
      if type(data) ~= "table" or data.schema ~= 1 or stem_for(data.script, data.id) ~= stem
        or type(data.title) ~= "string" then
        return nil, err or "invalid transaction record: " .. name
      end
      if script and (data.script ~= script or data.id ~= id) then
        return nil, "transaction filename collision: " .. stem
      end
      data.phase, data.state = phase, state
      record, filename = data, path
    end
  end
  return record, nil, filename
end

---With the queue guard held, validate a temporary record before making it visible.
local function publish(phase, name, data)
  local dir = root .. PATHSEP .. phase .. PATHSEP
  local called, ok, err = pcall(storage.save, phase, ".tmp", data, root)
  if not called then return nil, ok end
  if ok then ok, err = storage.load(phase, ".tmp", root) end
  if ok then ok, err = os.rename(dir .. ".tmp", dir .. name) end
  if ok then return true end
  os.remove(dir .. ".tmp")
  return nil, err or "could not publish transaction"
end

---Queue an installed handler. Does not overwrite an existing request.
---At execution time, `plugins.my_plugin.apply` resolves to
---`plugins/my_plugin/apply.lua` under `USERDIR` first, then `DATADIR`.
---The file must return a function:
---```lua
--- ---@type core.transactions.handler
---local function apply(id, payload, ctx)
---  if system.get_file_info(payload.busy_marker) then
---    return nil, { message = "Close the app using the file, then relaunch Pragtical.", retry = true }
---  end
---  ctx:progress("Moving staged file")
---  local ok, err = os.rename(payload.staged, payload.destination)
---  if not ok then return nil, { message = err } end
---  return true
---end
---return apply
---```
---`id` is `options.id` or the dotted script name; `payload` is `options.payload`
---or nil. See `core.transactions.context` for progress reporting and retry information.
---
---To retry, the handler must return two values: `nil` (not `false`) and a
---failure table with a `message` and `retry = true`. Do not register it again.
---The runner leaves this request and later requests queued. On the next full
---launch it calls the handler from the beginning with the same payload and
---the failure in `ctx.previous_failure`. Only request a retry if replay is safe.
---Without `retry`, the failure is marked failed; `true` completes the request.
---Use `recovery_required = true` when manual recovery is needed; it overrides retry.
---@param script string Dotted handler path starting with `plugins.`, without the `.lua` extension.
---@param options? core.transactions.options
---@return boolean? ok
---@return string? err
function transactions.register(script, options)
  options = options or {}
  local stem, err = stem_for(script, options.id)
  if not stem then return nil, err end
  if options.title ~= nil and type(options.title) ~= "string" then
    return nil, "transaction title must be a string"
  end
  local phase = options.phase or "startup"
  return locked(phase, true, function()
    local existing, read_error = read(phase, stem, script, options.id)
    if read_error then return nil, read_error end
    if existing then return nil, existing.state == "in_progress" and "busy" or "transaction already exists" end
    return publish(phase, stem .. ".ready.lua", {
      schema = 1,
      script = script,
      id = options.id,
      title = options.title or options.id or script,
      payload = options.payload,
    })
  end)
end

---Return a detached snapshot, including a running or failed request.
---@param script string
---@param key? core.transactions.key
---@return core.transactions.record? record
---@return string? err
function transactions.get(script, key)
  key = key or {}
  local stem, err = stem_for(script, key.id)
  if not stem then return nil, err end
  local phase = key.phase or "startup"
  return locked(phase, false, function()
    local record, read_error = read(phase, stem, script, key.id)
    return record, read_error
  end)
end

---Remove a pending or failed request, but never one claimed by a runner.
---@param script string
---@param key? core.transactions.key
---@return boolean? ok
---@return string? err
function transactions.remove(script, key)
  key = key or {}
  local stem, err = stem_for(script, key.id)
  if not stem then return nil, err end
  local phase = key.phase or "startup"
  local _, remove_error = locked(phase, false, function()
    local record, read_error, path = read(phase, stem, script, key.id)
    if read_error then return nil, read_error end
    if not record then return true end
    if record.state == "in_progress" then return nil, "busy" end
    return os.remove(path)
  end)
  if remove_error then return nil, remove_error end
  return true
end

-- A startup window cannot use editor views, themes, or plugin fonts yet.
local Report = {}
Report.__index = Report

---Open the progress window only when startup can display and drive it.
local function open_report()
  local driver = os.getenv("SDL_VIDEO_DRIVER") or os.getenv("SDL_VIDEODRIVER")
  if os.getenv("PRAGTICAL_RUNTIME") or driver == "dummy" or driver == "offscreen"
    or not coroutine.isyieldable() then return end
  local ok, win = pcall(renwindow.create, "Pragtical startup", 660, 380)
  if not ok then return end
  local loaded, font = pcall(renderer.font.load, DATADIR .. "/fonts/FiraSans-Regular.ttf", 20)
  if not loaded or not font then return end
  local has_icon, icon = pcall(renderer.font.load, DATADIR .. "/fonts/icons.ttf", 32)
  system.set_window_mode(win, "maximized")
  return setmetatable({ window = win, font = font, icon = has_icon and icon,
    lines = {}, rows = {}, laid_out = 0 }, Report)
end

function Report:log(message)
  for line in (message .. "\n"):gmatch("(.-)\n") do self.lines[#self.lines + 1] = line end
end

---Pump one frame, then give SDL control until its next tick. Return false on dismissal.
function Report:frame(title, fraction, finished, detail)
  local w, h = self.window:get_size()
  local top, bottom = 64, h - 76
  local right = w - 20
  local size = math.floor(math.min(204, w / 7, w - 280, (bottom - top - 16) * 0.75))
  local logo_x
  if self.icon and size >= 32 then
    if self.icon:get_size() ~= size then self.icon:set_size(size) end
    logo_x = right - self.icon:get_width("9")
  end
  local scroll_x = (logo_x and logo_x - 16 or right) - 8
  local width = math.max(1, scroll_x - 28)
  local line_h = self.font:get_height() + 3
  local visible = math.max(1, math.floor((bottom - top) / line_h))
  if width ~= self.width then self.rows, self.laid_out, self.width = {}, 0, width end
  for i = self.laid_out + 1, #self.lines do
    local line = self.lines[i]
    if self.font:get_width(line) > width then
      local row = ""
      for ch in common.utf8_chars(line) do
        if row ~= "" and self.font:get_width(row .. ch) > width then
          local head, tail = row:match("^(.*%S)%s+(%S*)$")
          self.rows[#self.rows + 1], row = head or row, tail or ""
        end
        row = row .. ch
      end
      line = row
    end
    self.rows[#self.rows + 1] = line
  end
  self.laid_out = #self.lines
  local last = math.max(1, #self.rows - visible + 1)
  local first = math.min(self.first or last, last)
  local track = visible * line_h
  local thumb = math.max(12, track * visible / math.max(visible, #self.rows))
  local bx, by, bw, bh = right - 116, h - 54, 116, 38
  for event, a, b, c in system.poll_event do
    if event == "quit" then return false end
    if event == "mousewheel" then first = first - a * 3 end
    if event == "keypressed" then
      if finished and (a == "return" or a == "space") then return false end
      if a == "up" then first = first - 1 elseif a == "down" then first = first + 1
      elseif a == "pageup" then first = first - visible elseif a == "pagedown" then first = first + visible
      elseif a == "home" then first = 1 elseif a == "end" then first = last end
    elseif event == "mousepressed" and a == "left" then
      self.pressed = finished and b >= bx and b <= bx + bw and c >= by and c <= by + bh
      if last > 1 and b >= scroll_x - 6 and b <= scroll_x + 14 and c >= top and c < top + track then
        local offset = c - top - (track - thumb) * (first - 1) / (last - 1)
        self.drag = offset >= 0 and offset < thumb and offset or thumb / 2
        first = 1 + (last - 1) * (c - top - self.drag) / (track - thumb)
      end
    elseif event == "mousemoved" and self.drag then
      first = 1 + (last - 1) * (b - top - self.drag) / math.max(1, track - thumb)
    elseif event == "mousereleased" and a == "left" then
      if self.pressed and b >= bx and b <= bx + bw and c >= by and c <= by + bh then return false end
      self.pressed, self.drag = false, nil
    end
    first = math.max(1, math.min(last, first))
  end
  first = math.floor(first + 0.5)
  self.first = first < last and first or nil

  local blue, track_color, ink = {128, 179, 255}, {80, 80, 80}, {33, 37, 43}
  renderer.begin_frame(self.window)
  renderer.set_clip_rect(0, 0, w, h)
  renderer.draw_rect(0, 0, w, h, ink)
  -- Stagger the drops without randomizing their positions between frames.
  local depth, now = h - 53, system.get_time()
  renderer.set_clip_rect(0, 53, w, depth)
  for i = 1, math.min(128, math.ceil(w * depth / 42000)) do
    local length, speed = 2 * (36 + i * 17 % 43), 14 + i * 7 % 11
    local cycle = depth + length
    local fall = (now * speed + (i * 0.618034 % 1) * cycle) % cycle
    local slope = 0.12 + (i % 4) * 0.035
    local drift = length * slope
    local span = w + drift + 2
    local x = ((i * 0.754878 % 1) * span - fall * slope) % span - 2
    local y, tip = 53 + fall - length, x - drift
    renderer.draw_poly({ {x, y}, {x + 2, y}, {tip + 2, y + length}, {tip, y + length} },
      {128, 179, 255, 16 + i * 3 % 10})
  end
  renderer.set_clip_rect(20, 0, w - 40, h)
  renderer.draw_text(self.font, title, 20, 16, {238, 238, 238})
  renderer.draw_rect(20, 52, w - 40, 1, track_color)
  renderer.set_clip_rect(20, top, width, track)
  for i = first, math.min(first + visible - 1, #self.rows) do
    renderer.draw_text(self.font, self.rows[i], 20, top + (i - first) * line_h, {215, 227, 244})
  end
  renderer.set_clip_rect(0, 0, w, h)
  if last > 1 then
    renderer.draw_rect(scroll_x, top, 8, track, track_color)
    renderer.draw_rect(scroll_x, top + (track - thumb) * (first - 1) / (last - 1), 8, thumb, {175, 198, 233})
  end
  if finished then
    renderer.draw_rect(bx, by, bw, bh, blue)
    renderer.draw_text(self.font, "Continue", bx + (bw - self.font:get_width("Continue")) / 2,
      by + (bh - self.font:get_height()) / 2, ink)
  else
    local bar = right - 20
    local fill = fraction and bar * fraction or bar / 4
    local x = fraction and 0 or (bar - fill) * (1 - math.cos(system.get_time() * 4)) / 2
    local status = fraction and string.format("%d%%", math.floor(fraction * 100)) or ""
    if detail then status = status == "" and detail or status .. "   " .. detail end
    renderer.draw_text(self.font, status, 20, h - 44 - self.font:get_height(), {215, 227, 244})
    renderer.draw_rect(20, h - 36, bar, 6, track_color)
    renderer.draw_rect(20 + x, h - 36, fill, 6, blue)
  end
  if logo_x then
    -- Same layered logo glyphs as EmptyView, without loading the theme or widgets.
    local x, y = logo_x, top + math.ceil(size * 0.16)
    renderer.draw_text(self.icon, "5", x, y, track_color)
    renderer.draw_text(self.icon, "6", x, y, {215, 227, 244})
    renderer.draw_text(self.icon, "7", x, y, blue)
    renderer.draw_text(self.icon, "8", x, y, {55, 113, 200})
    renderer.draw_text(self.icon, "9", x, y, {215, 227, 244})
  end
  renderer.end_frame()
  coroutine.yield(true)
  return true
end

---Run pending handlers before editor initialization. A handler may return
---nil, { message = "...", retry = true } when it is safe to start the editor
---and retry on the next launch. This also leaves later requests queued.
---An interrupted claim or recovery_required failure is never silently replayed.
---@param phase? core.transactions.phase
---@return boolean? ok
---@return string? err
function transactions.run(phase)
  phase = phase or "startup"
  local dir = root .. PATHSEP .. phase
  local ready, index = {}, 0
  local active

  ---Claim the next still-ready request from this run's snapshot under the queue guard.
  local function claim_next()
    while index < #ready do
      index = index + 1
      local stem = ready[index]
      local data, err, path = read(phase, stem)
      if err then return nil, err end
      if data and data.state == "ready" then
        active = dir .. PATHSEP .. stem .. ".in_progress.lua"
        local ok, rename_error = os.rename(path, active)
        if not ok then return nil, rename_error end
        return data
      end
    end
  end

  local record, err = locked(phase, false, function()
    local files, list_error = system.list_dir(dir)
    if not files then return nil, list_error end
    for _, file in ipairs(files) do
      if file:match("%.in_progress%.lua$") then
        return nil, "transaction in progress or interrupted: " .. file
      end
      local stem = file:match("^(.+)%.ready%.lua$")
      if stem then ready[#ready + 1] = stem end
    end
    table.sort(ready)
    return claim_next()
  end)
  local report = record and open_report()
  local title, ctx, deferred
  ---Keep the console and the interactive history in the same order.
  local function log(message)
    io.stdout:write(message, "\n")
    if report then report:log(message) end
  end

  ---Closing the reporter never cancels a commit.
  local function redraw(finished)
    if report and not report:frame(title, ctx and ctx.fraction, finished, ctx and ctx.detail) then
      report = nil
      collectgarbage("collect")
    end
  end

  while record do
    local relative = record.script:gsub("%.", PATHSEP) .. ".lua"
    local path = USERDIR .. PATHSEP .. relative
    if not system.get_file_info(path) then path = DATADIR .. PATHSEP .. relative end
    ctx = setmetatable({ phase = phase, previous_failure = record.last_failure, log = log }, Context)
    title = "Executing transaction: " .. record.title
    log(title)
    redraw()
    local worker = coroutine.create(function()
      ---@type core.transactions.handler
      local handler = assert(loadfile(path, "t"))()
      assert(type(handler) == "function", "transaction script must return a function")
      return handler(record.id or record.script, record.payload, ctx)
    end)
    local ran, result, reason
    repeat
      ran, result, reason = coroutine.resume(worker)
      if ran and coroutine.status(worker) ~= "dead" then redraw() end
    until not ran or coroutine.status(worker) == "dead"
    local success = ran and result == true
    local has_reason = type(reason) == "table" and type(reason.message) == "string"
    if not success and (not ran or result ~= nil or not has_reason or reason.recovery_required) then
      local message = not ran and tostring(result) or (has_reason and reason.message)
        or "transaction handler did not report an outcome"
      err = "transaction recovery required: " .. message
      break
    end

    -- Retire this claim and take the next under one guard, so runners cannot interleave.
    record, err = locked(phase, false, function()
      if not success then
        record.phase, record.state, record.last_failure = nil, nil, reason
        local name = ready[index] .. (reason.retry == true and ".ready.lua" or ".failed.lua")
        -- Keep the active marker until the complete failure record is published.
        local saved = publish(phase, name, record)
        if not saved then
          record.last_failure = { message = reason.message }
          local fallback, save_error = publish(phase, name, record)
          if not fallback then return nil, save_error end
        end
      end
      local removed, remove_error = os.remove(active)
      if not removed then return nil, remove_error end
      if not success and reason.retry == true then
        deferred = true
        log("Deferred: " .. record.title .. "\n" .. reason.message)
        return
      end
      if not success then return nil, reason.message end
      log("Completed: " .. record.title)
      return claim_next()
    end)
  end
  if err then log("Stopped: " .. err) end
  title = err and "Startup transactions stopped" or deferred and "Startup transactions deferred"
    or "Startup transactions complete"
  while report do redraw(true) end
  if err then return nil, err end
  return true
end

return transactions
