-- Lua script to stress the editor in order to generate profiler data
-- for PGO optimized builds.
--
-- 1. To prepare the build for profile generation you need to pass
--    -Db_pgo=generate to the setup flags, for example:
--
--    meson setup --buildtype=release -Db_lto=true -Db_pgo=generate build
--
-- 2. Then you can install the files in order to be able to properly
--    run the editor:
--
--    meson install -C build --destdir ../install
--
--    or simply use scripts/run-local to let it handle the installation for you
--
-- 3. Run this script to generate the profiling data.
--
--    If using installed files:
--      install/pragtical run -n scripts/lua/pgo.lua
--
--    If using run-local:
--      ./scripts/run-local build run -n scripts/lua/pgo.lua
--
--    If running on a headless environment set environment variable:
--      * SDL2 - SDL_VIDEODRIVER=dummy
--      * SDL3 - SDL_VIDEO_DRIVER=dummy
--
-- 4. Use the generated profile data.
--
--    meson configure -Db_pgo=use build
--
-- 5. Recompile with the profile data
--
--    meson compile -C build
--
-- Install, and you are done!

local core = require "core"
local config = require "core.config"
local command = require "core.command"
local common = require "core.common"
local style = require "core.style"
local scale = require "plugins.scale"
local View = require "core.view"

local CWD = system.getcwd()

print "Starting PGO stress..."

-- Allow printing to terminal when no video
if os.getenv("SDL_VIDEO_DRIVER") == "dummy" then
  local core_log = core.log
  core.log = function(text, ...)
    core_log(text, ...)
    print(string.format(text, ...))
  end
  core.log("Overwritten core.log for cli output.")
end

-- Force redraw on each yield to ensure things keep active
local coroutine_yield = coroutine.yield
function coroutine.yield(...)
  core.redraw = true
  coroutine_yield(...)
end

---Helper for the fetch resource function.
---@param curl process
---@param callback? fun(percent,total,dowloaded,speed,left,elapsed)
---@param yield? boolean
local function download_status(curl, callback, yield)
  local err
  local line = ""
  repeat
    err = curl:read_stderr(1)
    if not err then
      if curl:returncode() ~= 0 then
        return false, line
      else
        return true
      end
    end
    line = line .. err
    if not err then
      if yield then
        coroutine.yield(0.10)
      else
        system.sleep(0.25)
      end
    end
  until line:match("\r%s*%S+" .. string.rep("%s+%S+", 11))
  if line ~= "" then
    -- % Total    % down              speed         left     elapsed
    -- 2 1294M    2 29.6M    0     0  28.3M      0  0:00:01  0:00:44
    local percent, total, dowloaded, speed, left, elapsed = line:match(
      "\r%s*(%S+)%s+(%S+)%s+%S+%s+(%S+)%s+%S+%s+%S+%s+(%S+)%s+%S+%s+(%S+)%s+(%S+)"
    )
    if percent and not elapsed:find("%-%-") then
      if callback then
        callback(percent, total, dowloaded, speed, left, elapsed)
      end
    end
  end
  return true
end

---Download a resource from the web using curl as a backend.
---@param url string
---@param async? boolean
---@param callback? fun(percent,total,dowloaded,speed,left,elapsed)
---@param cwd? string
---@return boolean success
---@return string? errmsg
local function fetch(url, async, callback, cwd)
  async = type(async) == "nil" and true or async
  cwd = cwd or system.getcwd()

  local curl, errmsg = process.start(
    { "curl", "--insecure", "-LO", url },
    { cwd = cwd }
  )

  local success

  if not curl then
    return false, errmsg
  else
    if async then
      core.add_thread(function()
        while curl:running() do
          success, errmsg = download_status(curl, callback, true)
          coroutine.yield()
        end
      end)
    else
      while curl:running() do
        success, errmsg = download_status(curl, callback)
      end
    end
  end
  if not success then
    return false, errmsg
  end
  return true
end

---Opens a file and stress scrolling while waiting for tokenization to finish.
---@param abs_path string
local function file_stress(abs_path)
  ---@type core.docview
  local dv = core.root_view:open_doc(core.open_doc(abs_path))

  coroutine.yield()

  local total_lines = #dv.doc.lines

  dv:scroll_to_make_visible(total_lines, 1)

  coroutine.yield()

  while dv.scroll.y ~= dv.scroll.to.y do
    coroutine.yield()
  end

  dv.doc:set_selection(total_lines, 1)

  while dv.doc.highlighter.running do
    core.log(
      "Parsing Lines: %d%%",
      math.ceil((dv.doc.highlighter.first_invalid_line / total_lines) * 100)
    )

    -- stress scrolling while tokenizing
    if dv.scroll.y == dv.scroll.to.y then
      if dv.doc:get_selection() ~= 1 then
        dv:scroll_to_make_visible(1, 1)
        dv.doc:set_selection(1, 1)
      else
        dv:scroll_to_make_visible(total_lines, 1)
        dv.doc:set_selection(total_lines, 1)
      end
    end
    coroutine.yield()
  end

  command.perform "root:close"
  coroutine.yield()
end

---Helper for input_stress
---@param dv core.docview
---@param text string
local function input_text(dv, text)
  for c=1, #text do
    dv:on_text_input(text:sub(c, c))
    dv:update()
    core.redraw = true
    coroutine.yield()
  end
end

---Perform input text stressing
---@param abs_path string
local function input_stress(abs_path)
  config.scroll_context_lines = 0

   ---@type core.docview
  local dv = core.root_view:open_doc(core.open_doc(abs_path))

  coroutine.yield()

  local total_lines = #dv.doc.lines

  for l=1, total_lines do
    dv:scroll_to_make_visible(total_lines, l)

    coroutine.yield()

    while dv.scroll.y ~= dv.scroll.to.y do
      coroutine.yield()
    end

    dv.doc:set_selection(l, 1)
    input_text(dv, "<a href=\"#\">hello world!</a>")

    dv.doc:set_selection(l, math.floor(#dv.doc.lines[l] / 2))
    input_text(dv, "<style>.hello-world{background-color: #fff}</style>")

    dv.doc:set_selection(l, #dv.doc.lines[l] - 1)
    input_text(dv, "<script>alert('hello world');</script>")

    coroutine.yield()
  end

  dv.doc:clear_undo_redo()
  command.perform "root:close"
end

---Perform serialization stressing
---@param depth? integer
local function serialize_stress(depth)
  for i=1, depth or 5 do
    common.serialize(core, {pretty = true, limit=i})

    coroutine.yield()
  end
end

---Perform scale change stressing
local function scale_stress()
  for i=1, 50 do
    scale.increase()
    core.log("Scale increase stress #%s", i)
    coroutine.yield()
  end

  for i=1, 50 do
    scale.decrease()
    core.log("Scale decrease stress #%s", i)
    coroutine.yield()
  end
end

--- Stress the process API in a platform-independent way.
---@param count? integer Number of subprocesses to launch
---@param duration? number Duration (in seconds) to run the test
local function stress_process_api(count, duration)
  count = count or 50
  duration = duration or 10

  local is_windows = PLATFORM == "Windows"
  local deadline = os.clock() + duration
  local procs = {}

  -- Build platform-safe command
  local command, args
  if is_windows then
    command = "cmd"
    args = { "/C", "for /L %i in (1,1,100) do @echo Line %i" }
  else
    command = "sh"
    args = { "-c", "for i in $(seq 1 100); do echo Line $i; done" }
  end

  -- Spawn subprocesses
  for i = 1, count do
    local proc, errmsg, errcode = process.start({command, table.unpack(args)})
    if not proc then
      core.log("Failed to start process #%d: %s (code %d)", i, errmsg, errcode)
      coroutine.yield()
    else
      table.insert(procs, proc)
    end
  end

  core.log("Launched %s  processes", #procs)
  coroutine.yield()

  -- Main loop: read from stdout/stderr until time runs out
  while os.clock() < deadline and #procs > 0 do
    for i = #procs, 1, -1 do
      local p = procs[i]

      -- Try to read stdout
      local out, err, code = p:read_stdout()
      if out and #out > 0 then
        core.log("process stdout: %s", out)
        coroutine.yield()
      elseif code then
        print("stdout read error:", err)
        p:kill()
        table.remove(procs, i)
      end

      -- Try to read stderr
      local errout, eerr, ecode = p:read_stderr()
      if errout and #errout > 0 then
        core.log("process stdout: %s", errout)
        coroutine.yield()
      elseif ecode then
        print("stderr read error:", eerr)
        p:kill()
        table.remove(procs, i)
      end

      -- Check if process is still alive
      if not p:running() then
        p:wait(0)
        table.remove(procs, i)
      end
    end

    coroutine.yield()
  end

  -- Cleanup
  for i, p in ipairs(procs) do
    print("process kill #%s", i)
    p:kill()
  end
end

---Generate html code to stress the tokenizer
---@param path string
---@param blocks integer
local function generate_html_stress(path, blocks)
  blocks = blocks or 100
  local f = assert(io.open(path, "w"))

  f:write([[
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="UTF-8">
      <title>Tokenizer Stress</title>
    </head>
    <body>
  ]])

  for i = 1, blocks do
    -- Insert a <style> block every N blocks
    f:write(string.format([[
        <style>
          .block%d {
            background-color: #%02x%02x%02x;
            padding: %dpx;
            margin: %dpx;
            border: 1px solid #%02x%02x%02x;
          }
        </style>
      ]], i,
      math.random(0,255), math.random(0,255), math.random(0,255),
      math.random(2,10), math.random(2,10),
      math.random(0,255), math.random(0,255), math.random(0,255)
    ))

    -- Insert an HTML block using the CSS class
    f:write(string.format([[
      <div class="block%d">
        <h2>Block %d</h2>
        <p>This is paragraph number %d in a styled div.</p>
      </div>
    ]], i, i, i))

    -- Insert a <script> block
    f:write(string.format([[
      <script>
        // Script block #%d
        (function() {
          let el = document.querySelector(".block%d");
          if (el) {
            el.innerHTML += "<p>Script-enhanced content #%d</p>";
          }
        })();
      </script>
    ]], i, i, i))

    coroutine.yield()
  end

  f:write("\n</body>\n</html>\n")
  f:close()
end


--------------------------------------------------------------------------------
-- Rotating cube code to stress the drawing of rectangles
--------------------------------------------------------------------------------
local cube = {
  {-1, -1, -1}, { 1, -1, -1}, { 1,  1, -1}, {-1,  1, -1},
  {-1, -1,  1}, { 1, -1,  1}, { 1,  1,  1}, {-1,  1,  1}
}

local edges = {
  {1, 2}, {2, 3}, {3, 4}, {4, 1},
  {5, 6}, {6, 7}, {7, 8}, {8, 5},
  {1, 5}, {2, 6}, {3, 7}, {4, 8}
}

local angle_x, angle_y, angle_z = 0, 0, 0

local function atan2(y, x)
  if x > 0 then
    return math.atan(y / x)
  elseif x < 0 then
    return math.atan(y / x) + (y >= 0 and math.pi or -math.pi)
  elseif y > 0 then
    return math.pi / 2
  elseif y < 0 then
    return -math.pi / 2
  else
    return 0 -- undefined; return 0 by convention
  end
end

local function rotate(x, y, z)
  local sinx, cosx = math.sin(angle_x), math.cos(angle_x)
  y, z = y * cosx - z * sinx, y * sinx + z * cosx

  local siny, cosy = math.sin(angle_y), math.cos(angle_y)
  x, z = x * cosy + z * siny, -x * siny + z * cosy

  local sinz, cosz = math.sin(angle_z), math.cos(angle_z)
  x, y = x * cosz - y * sinz, x * sinz + y * cosz

  return x, y, z
end

local function project(x, y, z, cx, cy, scale)
  local fov = 3
  local depth = fov / (fov + z)
  return cx + x * depth * scale, cy + y * depth * scale
end

-- Better line using thick rectangles
local function draw_line(x1, y1, x2, y2, thickness, color)
  local dx, dy = x2 - x1, y2 - y1
  local length = math.sqrt(dx * dx + dy * dy)
  local angle = math.atan2 and math.atan2(dy, dx) or atan2(dy, dx)

  local cos_a = math.cos(angle)
  local sin_a = math.sin(angle)

  for i = 0, length do
    local px = x1 + cos_a * i
    local py = y1 + sin_a * i

    for t = -math.floor(thickness / 2), math.ceil(thickness / 2) - 1 do
      local offset_x = -sin_a * t
      local offset_y = cos_a * t
      renderer.draw_rect(px + offset_x, py + offset_y, 1, 1, color)
    end
  end
end

local function draw_cube(x, y, w, h, color, thickness)
  color = color or {255, 255, 255, 255}
  thickness = thickness or 1

  local scale = math.min(w, h) / 4
  local points = {}

  for i, v in ipairs(cube) do
    local rx, ry, rz = rotate(v[1], v[2], v[3])
    local sx, sy = project(rx, ry, rz, x, y, scale)
    points[i] = {sx, sy}
  end

  for _, edge in ipairs(edges) do
    local a = points[edge[1]]
    local b = points[edge[2]]
    draw_line(a[1], a[2], b[1], b[2], thickness, color)
  end

  angle_x = angle_x + 0.01
  angle_y = angle_y + 0.015
  angle_z = angle_z + 0.02
end

local Cube = View:extend()

function Cube:new()
  Cube.super.new(self)
end

function Cube:get_name()
  return "Cube"
end

function Cube:update()
  core.redraw = true
end

function Cube:draw()
  self:draw_background(style.background)
  local x, y = self.position.x + self.size.x / 2, self.position.y + self.size.y / 2
  local w, h = self.size.x / 1.5, self.size.y / 1.5
  draw_cube(x, y, w, h, style.syntax["string"], 3 * SCALE)
end
---------------------------End of Rotating Cube Code----------------------------

-- Max execution time check (allow a maximum of 5 minutes to prevent endless CI)
core.redraw = true

local start_time = os.time()
core.add_background_thread(function()
  while true do
    -- allow to keep running even if unfocus
    coroutine.yield(1)
    if os.time() - start_time >= 5 * 60 then
      print "Maximum pgo stress time exceeded, quitting..."
      command.perform "core:force-quit"
      break
    end
  end
end)

-- Main Entry Point
core.add_background_thread(function()
  local start_time = system.get_time()

  local sqlite_path = CWD .. PATHSEP .. "sqlite3.c"

  if not system.get_file_info(sqlite_path) then
    os.remove(sqlite_path)
  end

  coroutine.yield()

  config.draw_stats = "uncapped"

  -- disable this for now
  -- core.log("Downloading sqlite3.c using curl thru process api")
  -- coroutine.yield(1)
  -- if
  --   fetch(
  --     "https://github.com/jeffboody/libsqlite3/raw/refs/heads/master/sqlite3.c",
  --     false,
  --     function(percent, total, dowloaded, speed, left)
  --       core.log(
  --         "percent: %s, total: %s, downloaded: %s, speed: %s, left: %s",
  --         percent, total, dowloaded, speed, left
  --       )
  --       coroutine.yield()
  --     end
  --   )
  -- then
  --   os.remove(sqlite_path)
  -- end

  core.log("Generating stress HTML file...")
  coroutine.yield()

  local html_file = CWD .. PATHSEP .. "stress.html"
  generate_html_stress(html_file, 1000)

  core.log("Scale stress...")
  coroutine.yield()

  for _, file in ipairs({
    "none",
    CWD .. PATHSEP .. "changelog.md",
    html_file
  }) do
    if file ~= "none" then
      core.root_view:open_doc(core.open_doc(file))
      coroutine.yield()
    end
    for _=1, 3 do
      scale_stress()
    end
    command.perform "root:close"
    coroutine.yield()
  end

  core.log("Process API stress...")
  coroutine.yield()

  for _=1, 5 do
    stress_process_api()
  end

  local files = {
    CWD .. PATHSEP .. "README.md",
    CWD .. PATHSEP .. "changelog.md",
    CWD .. PATHSEP .. "data"..PATHSEP.."core"..PATHSEP.."init.lua",
    CWD .. PATHSEP .. "src"..PATHSEP.."api"..PATHSEP.."system.c",
    html_file
  }

  for _, file in ipairs(files) do
    core.log("Highlighter stress %s", common.basename(file))
    coroutine.yield(1)
    file_stress(file)
  end

  for i=1, 5 do
    core.log("Serialize stress run #%s", i)
    coroutine.yield()
    serialize_stress()
  end

  core.log("Input stress")
  coroutine.yield()
  generate_html_stress(html_file, 1)
  input_stress(html_file)

  os.remove(html_file)

  core.log("Draw rect stress")
  coroutine.yield()
  local node = core.root_view:get_active_node()
  local c = Cube()
  node:add_view(c)
  core.set_active_view(c)

  for _=1, 10 do
    coroutine.yield(1)
  end

  print(string.format("Elapsed Time: %.2fs", system.get_time() - start_time))

  command.perform "core:quit"
end)
