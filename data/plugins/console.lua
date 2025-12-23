-- mod-version:3.1
local core = require "core"
local keymap = require "core.keymap"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local View = require "core.view"

local console = {}

-- The main object is used to store the main console view and the function for
-- its activation, start_console.
-- The main console view is the one which is shown at the botton and whose visibility can
-- be toggled with the console:toggle command. It is created and added in the nodes'
-- hierarchy only when it is actually required. In this way we avoid plugging the console
-- view in a random location based on plugin load order.
local main = {}
local views = {}
local pending_threads = {}
local thread_active = false
local output = nil
local output_id = 0
local visible = false

config.plugins.console = common.merge({
  size = 250 * SCALE,
  max_lines = 200,
  autoscroll = true,
  config_spec = {
    name = "Console",
    {
      label = "Size",
      description = "Default height of the console.",
      path = "size",
      type = "number",
      min = 100,
      default = 250,
      get_value = function(value)
        return value / SCALE
      end,
      set_value = function(value)
        return value * SCALE
      end,
      on_apply = function(value)
        if main.view then
          main.view:set_target_size("y", value)
        end
      end
    },
    {
      label = "Maximum Lines",
      description = "The maximum amount of output lines to keep on history.",
      path = "max_lines",
      type = "number",
      min = 100,
      default = 200
    },
    {
      label = "Auto-scroll",
      description = "Automatically scroll down when printing new output.",
      path = "autoscroll",
      type = "toggle",
      default = true,
    }
  }
}, config.plugins.console)

function console.clear()
  output = { { text = "", time = 0 } }
end


local function write_file(filename, text)
  local fp = io.open(filename, "w")
  fp:write(text)
  fp:close()
end


local function lines(text)
  return (text .. "\n"):gmatch("(.-)\n")
end


local function push_output(str, opt)
  local first = true
  for line in lines(str) do
    if first then
      line = table.remove(output).text .. line
    end
    line = line:gsub("\x1b%[[%d;]+m", "") -- strip ANSI colors
    table.insert(output, {
      text = line,
      time = os.time(),
      icon = line:find(opt.error_pattern) and "!"
          or line:find(opt.warning_pattern) and "i",
      file_pattern = opt.file_pattern,
      file_prefix = opt.file_prefix,
    })
    if #output > config.plugins.console.max_lines then
      table.remove(output, 1)
      for view in pairs(views) do
        view:on_line_removed()
      end
    end
    first = false
  end
  output_id = output_id + 1
  core.redraw = true
end

-- A file pattern to identify the line and column can be given like:
--
-- file_pattern = "([^?:%s]+%.[^?:%s]+):(%d+):(%d+):"
--
-- The 2nd and 3rd captures will be considered as line and column of the
-- position within the file.
local function init_opt(opt)
  local res = {
    command = "",
    file_pattern = "([^?:%s]+%.[^?:%s]+):?(%d*):?(%d*)",
    error_pattern = "error",
    warning_pattern = "warning",
    cwd = core.root_project().path,
    on_complete = function() end,
    file_prefix = ".",
  }
  for k, v in pairs(res) do
    res[k] = opt[k] or v
  end
  return res
end


function console.run(opt)
  opt = init_opt(opt)

  local function thread()
    local command
    if PLATFORM == "Windows" then
      command = string.format("cmd /c (%s) 2>&1", opt.command:gsub("/", "\\"))
    else
      command = { "bash", "-c", "--", string.format("(%s) 2>&1", opt.command) }
    end

    local proc, err = process.start(command, { cwd=opt.cwd, stdin = process.REDIRECT_DISCARD })
    if proc then
      local text = proc:read_stdout()
      while text ~= nil do
        push_output(text, opt)
        coroutine.yield(0.1)
        text = proc:read_stdout()

        if text and #text == 0 and not proc:running() then break end
      end
      if output[#output].text ~= "" then
        push_output("\n", opt)
      end
      push_output("!DIVIDER\n", opt)

      opt.on_complete(proc:returncode())
    else
      core.error("Error while executing command: %q", err)
    end

    -- handle pending thread
    local pending = table.remove(pending_threads, 1)
    if pending then
      core.add_thread(pending)
    else
      thread_active = false
    end
  end

  -- push/init thread
  if thread_active then
    table.insert(pending_threads, thread)
  else
    core.add_thread(thread)
    thread_active = true
  end

  -- make sure static console is visible if it's the only ConsoleView
  if not main.view then main.start_console() end
  local count = 0
  for _ in pairs(views) do count = count + 1 end
  if count == 1 then visible = true end
end



local ConsoleView = View:extend()

function ConsoleView:new()
  ConsoleView.super.new(self)
  self.target_size = config.plugins.console.size
  self.scrollable = true
  self.hovered_idx = -1
  views[self] = true
end


function ConsoleView:set_target_size(axis, value)
  if axis == "y" then
    self.target_size = value
    return true
  end
end


function ConsoleView:try_close(...)
  ConsoleView.super.try_close(self, ...)
  views[self] = nil
end


function ConsoleView:get_name()
  return "Console"
end


function ConsoleView:get_line_height()
  return style.code_font:get_height() * config.line_height
end


function ConsoleView:get_line_count()
  return #output - (output[#output].text == "" and 1 or 0)
end


function ConsoleView:get_scrollable_size()
  return self:get_line_count() * self:get_line_height() + style.padding.y * 2
end


function ConsoleView:get_visible_line_range()
  local lh = self:get_line_height()
  local min = math.max(1, math.floor(self.scroll.y / lh))
  return min, min + math.floor(self.size.y / lh) + 1
end


function ConsoleView:on_mouse_moved(mx, my, ...)
  ConsoleView.super.on_mouse_moved(self, mx, my, ...)
  self.hovered_idx = 0
  for i, item, x,y,w,h in self:each_visible_line() do
    if mx >= x and my >= y and mx < x + w and my < y + h then
      if item.text:find(item.file_pattern) then
        self.hovered_idx = i
      end
      break
    end
  end
end


local function resolve_file(file_prefix, name)
  if common.is_absolute_path(name) and system.get_file_info(name) then
    return name
  end
  local rel_name = file_prefix .. PATHSEP .. name
  if system.get_file_info(core.root_project():absolute_path(rel_name)) then
    return rel_name
  end
  local filenames = {}
  local count = 0
  core.log("Searching for %s ...", name)
  for _, f in core.root_project():files() do
    table.insert(filenames, f.filename)
    count = count + 1
    if count % 100 == 0 then coroutine.yield() end
  end
  local t = common.fuzzy_match(filenames, name, true)
  if t and t[1] then return core.root_project():absolute_path(t[1]) end
  return nil
end


function ConsoleView:on_line_removed()
  local diff = self:get_line_height()
  self.scroll.y = self.scroll.y - diff
  self.scroll.to.y = self.scroll.to.y - diff
end


function ConsoleView:on_mouse_pressed(...)
  local caught = ConsoleView.super.on_mouse_pressed(self, ...)
  if caught then
    return
  end
  local item = output[self.hovered_idx]
  if item then
    core.add_thread(function ()
      local file, line, col = item.text:match(item.file_pattern)
      local resolved_file = resolve_file(item.file_prefix, file)
      if not resolved_file then
        -- fixes meson output which adds ../ for build sub directories
        resolved_file = resolve_file(
          item.file_prefix,
          file:gsub("%.%./", ""):gsub("^%./", "")
        )
      end
      if not resolved_file then
        core.error("Couldn't resolve file \"%s\"", file)
        return
      end
      core.try(function()
        core.root_view:open_doc(core.open_doc(resolved_file))
        line = tonumber(line) or 1
        col = tonumber(col) or 1
        core.add_thread(function()
          core.active_view.doc:set_selection(line, col)
        end)
      end)
    end)
  end
end


function ConsoleView:each_visible_line()
  return coroutine.wrap(function()
    local x, y = self:get_content_offset()
    local lh = self:get_line_height()
    local min, max = self:get_visible_line_range()
    y = y + lh * (min - 1) + style.padding.y
    max = math.min(max, self:get_line_count())

    for i = min, max do
      local item = output[i]
      if not item then break end
      coroutine.yield(i, item, x, y, self.size.x, lh)
      y = y + lh
    end
  end)
end


function ConsoleView:update(...)
  if self.last_output_id ~= output_id then
    if config.plugins.console.autoscroll then
      self.scroll.to.y = self:get_scrollable_size()
    end
    self.last_output_id = output_id
  end
  ConsoleView.super.update(self, ...)
end


function ConsoleView:draw()
  self:draw_background(style.background)
  local icon_w = style.icon_font:get_width("!")

  for i, item, x, y, w, h in self:each_visible_line() do
    local tx = x + style.padding.x
    local time = os.date("%H:%M:%S", item.time)
    local color = style.text
    if self.hovered_idx == i then
      color = style.accent
      renderer.draw_rect(x, y, w, h, style.line_highlight)
    end
    if item.text == "!DIVIDER" then
      local w = style.font:get_width(time)
      renderer.draw_rect(tx, y + h / 2, w, math.ceil(SCALE * 1), style.dim)
    else
      tx = common.draw_text(style.font, style.dim, time, "left", tx, y, w, h)
      tx = tx + style.padding.x
      if item.icon then
        common.draw_text(style.icon_font, color, item.icon, "left", tx, y, w, h)
      end
      tx = tx + icon_w + style.padding.x
      common.draw_text(style.code_font, color, item.text, "left", tx, y, w, h)
    end
  end

  self:draw_scrollbar(self)
end

function main.start_console()
  -- init static bottom-of-screen console
  main.view = ConsoleView()
  local node = core.root_view.root_node:get_node_for_view(core.command_view)
  node:split("up", main.view, {y = true}, true)

  function main.view:update(...)
    local dest = visible and self.target_size or 0
    self:move_towards(self.size, "y", dest)
    ConsoleView.update(self, ...)
  end
end


local last_command = ""

command.add(nil, {
  ["console:reset-output"] = function()
    output = { { text = "", time = 0 } }
  end,

  ["console:open-console"] = function()
    local node = core.root_view:get_active_node()
    node:add_view(ConsoleView())
  end,

  ["console:toggle"] = function()
    visible = not visible
    if visible and not main.view then main.start_console() end
  end,

  ["console:run"] = function()
    core.command_view:enter("Run Console Command", {
      submit = function(cmd)
        if cmd == "clear" or cmd == "cls" then
          console.clear()
        else
          console.run { command = cmd }
          last_command = cmd
        end
      end,
      text = last_command,
      select_text = true
    })
  end
})

keymap.add {
  ["ctrl+."] = "console:toggle",
  ["ctrl+shift+."] = "console:run",
}

-- for `workspace` plugin:
package.loaded["plugins.console.view"] = ConsoleView

console.clear()
return console
