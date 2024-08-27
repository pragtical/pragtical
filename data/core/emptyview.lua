local core = require "core"
local command = require "core.command"
local common = require "core.common"
local style = require "core.style"
local keymap = require "core.keymap"
local Widget = require "widget"
local Button = require "widget.button"
local ListBox = require "widget.listbox"

---@class core.emptyview : widget
---@field super widget
local EmptyView = Widget:extend()

---Font used to render the logo
---@type renderer.font
local icon_huge_font

---Prevent the font getting scaled more than once from multiple instances
---@type boolean
local icon_font_scaled = false

local buttons = {
  { name = "new_file", icon = "f", cmd = "core:new-doc",
    label = "New File", tooltip = "Create a new file"
  },
  { name = "open_file", icon = "D", cmd = "core:open-file",
    label = "Open File", tooltip = "Open an existing project file"
  },
  { name = "open_folder", icon = "d", cmd = "core:open-project-folder",
    label = "Open Project", tooltip = "Open a project in another instance"
  },
  { name = "change_folder", icon = "d", cmd = "core:change-project-folder",
    label = "Change Project", tooltip = "Change main project of current instance"
  },
  { name = "find_file", icon = "L", cmd = "core:find-file",
    label = "Find File", tooltip = "Search for a file from current project"
  },
  { name = "run_command", icon = "B", cmd = "core:find-command",
    label = "Run Command", tooltip = "Search for a command and run it"
  },
  { name = "settings", icon = "P", cmd = "ui:settings",
    label = "Settings", tooltip = "Open the settings interface"
  }
}

---Opens web link using the current operating system launcher if possible.
---TODO: We should provide a core function for doing this which command is configurable
---@param link string
local function open_link(link)
  local launcher_command
  if PLATFORM == "Windows" then
    launcher_command = "start"
  elseif PLATFORM == "Mac OS X" then
    launcher_command = "open"
  else
    launcher_command = "xdg-open"
  end
  system.exec(launcher_command .. " " .. link)
end

---Constructor
function EmptyView:new()
  EmptyView.super.new(self, nil, false)

  if not icon_huge_font then
    icon_huge_font = style.icon_big_font:copy(110 * SCALE)
  end

  self.name = "Welcome"
  self.type_name = "core.emptyview"
  self.background_color = style.background
  self.border.width = 0
  self.scrollable = true
  self.first_draw = true

  self.title = "Pragtical"
  self.version = "version " .. VERSION
  self.title_width = style.big_font:get_width(self.title)
  self.version_width = style.font:get_width(self.title)
  self.text_x = 0
  self.text_y = 0

  for _, button in ipairs(buttons) do
    self[button.name] = Button(self, button.label)
    self[button.name]:set_icon(button.icon)
    self[button.name].border.width = 0
    core.add_thread(function()
      self[button.name]:set_tooltip(
        string.format(
          "%s (%s)",
          button.tooltip, keymap.get_binding(button.cmd) or ""
        )
      )
    end)
    self[button.name].on_click = function(_, pressed)
      if pressed == "left" then
        command.perform(button.cmd)
      end
    end
  end

  self.website = Button(self, "Website")
  self.website:set_tooltip("Visit the editor website")
  self.website.on_click = function(_, pressed)
    open_link("https://pragtical.dev")
  end

  self.docs = Button(self, "Documentation")
  self.docs:set_tooltip("Visit the editor documentation")
  self.docs.on_click = function(_, pressed)
    open_link("https://pragtical.dev/docs/intro")
  end

  self.force_update = false
  self.plugin_manager_loaded = false
  core.add_thread(function()
    self.plugin_manager_loaded = package.loaded["plugins.plugin_manager"]
    if self.plugin_manager_loaded then
      self.plugins = Button(self, "Plugins")
      self.plugins:set_icon("B")
      self.plugins:set_tooltip("Open the plugin manager")
      self.plugins.on_click = function(_, pressed)
        command.perform("plugin-manager:show")
      end
      self.force_update = true
    end
  end)

  self.recent_projects = ListBox(self)
  self.recent_projects:add_column("Recent Projects")
  self.recent_projects:hide()
  if core.recent_projects and type(core.recent_projects) == "table" then
    for _, path in ipairs(core.recent_projects) do
      self.recent_projects:add_row({common.home_encode(path)}, {path = path})
    end
  end
  function self.recent_projects:on_mouse_pressed(button, x, y, clicks)
    self.super.on_mouse_pressed(self, button, x, y, clicks)
    local idx = self:get_selected()
    local data = self:get_row_data(idx)
    if clicks == 2 then
      core.open_project(data.path)
    end
  end

  self.prev_size = { x = self.size.x, y = self.size.y }

  self:show()
  self:update()
end

function EmptyView:on_scale_change(new_scale)
  if not icon_font_scaled then
    icon_font_scaled = true
    core.add_thread(function()
      icon_huge_font = style.icon_big_font:copy(110 * new_scale)
      icon_font_scaled = false
    end)
  end
end

local function draw_text(self, x, y, calc_only)
  local th = style.big_font:get_height()
  local dh = 2 * th + style.padding.y * 2
  local x1, y1 = x, y + (dh / 2) - (th - style.padding.y * 2)
  local xv = x1

  if self.version_width > self.title_width then
    self.version = VERSION
    self.version_width = style.font:get_width(self.version)
    xv = x1 - (self.version_width - self.title_width)
  end

  if not calc_only then
    x = renderer.draw_text(style.big_font, self.title, x1, y1, style.dim)
    renderer.draw_text(style.font, self.version, xv, y1 + th, style.dim)
    x = x + style.padding.x
    renderer.draw_rect(x, y, math.ceil(1 * SCALE), dh, style.dim)
    x = x + style.padding.x

    renderer.draw_text(icon_huge_font, "5", x, y, style.background2)
    renderer.draw_text(icon_huge_font, "6", x, y, style.text)
    renderer.draw_text(icon_huge_font, "7", x, y, style.caret)
    renderer.draw_text(icon_huge_font, "8", x, y, common.lighten_color(style.dim, 25))
    x = renderer.draw_text(icon_huge_font, "9", x, y, common.lighten_color(style.dim, 45))
  else
    x, y = 0, 0
    x = style.big_font:get_width(self.title)
      + (style.padding.x * 2)
      + icon_huge_font:get_width("9")
  end

  return x, dh
end

function EmptyView:draw()
  if not self:is_visible() or self.first_draw then
    self.first_draw = false
    return false
  end
  EmptyView.super.draw(self)
  local _, oy = self:get_content_offset()
  draw_text(self, self.text_x, self.text_y + oy)
  return true
end

function EmptyView:update()
  if not EmptyView.super.update(self) then return false end

  self.background_color = style.background

  if
    self.force_update
    or
    self.prev_size.x ~= self.size.x or self.prev_size.y ~= self.size.y
  then
    self.force_update = false
    self.recent_projects:update_position()

    -- calculate all buttons width
    local buttons_w = 0
    for _, button in ipairs(buttons) do
      buttons_w = buttons_w + self[button.name]:get_width()
    end

    -- set the first button position
    local y = style.padding.y
    if buttons_w < self.size.x then
      self[buttons[1].name]:set_position((self.size.x / 2) - buttons_w / 2, y)
    else
      self[buttons[1].name]:set_position(0, y)
    end

    -- reposition remaining buttons
    for i=2, #buttons do
      self[buttons[i].name]:set_position(self[buttons[i-1].name]:get_right(), y)
    end

    self.title = "Pragtical"
    self.version = "version " .. VERSION
    self.title_width = style.big_font:get_width(self.title)
    self.version_width = style.font:get_width(self.version)

    -- calculate logo and version positioning
    local tw, th = draw_text(self, 0, 0, true)

    local tx = self.position.x + math.max(style.padding.x, (self:get_width() - tw) / 2)
    local ty = self.position.y + (self.size.y - th) / 2

    local items_h
    if #self.recent_projects.rows > 0 then
      self.recent_projects:set_size(
        self:get_width() - style.padding.x * 2, 200 * SCALE
      )
      if not self.recent_projects:is_visible() then
        self.recent_projects:show()
      end

      items_h = th + self[buttons[1].name]:get_height()
        + self.website:get_height()
        + self.recent_projects:get_height()
        + style.padding.y * 8

      if items_h < self:get_height() then
        ty = ty - self.recent_projects:get_height() / 2
      else
        ty = common.clamp(ty,
          self[buttons[1].name]:get_bottom() + style.padding.y * 4,
          ty - self.recent_projects:get_height()
        )
      end
    end

    self.text_x = tx
    self.text_y = ty

    -- reposition web buttons and recent projects
    local web_buttons_y = ty + th + style.padding.y * 2

    if not self.plugin_manager_loaded then
      local web_buttons_w = self.website:get_width()
        + self.docs:get_width() + style.padding.x

      self.website:set_position(
        self.size.x / 2 - web_buttons_w / 2, web_buttons_y
      )
      self.docs:set_position(
        self.website:get_right() + style.padding.x, web_buttons_y
      )
    else
      local web_buttons_w = self.website:get_width()
        + self.docs:get_width() + self.plugins:get_width() + style.padding.x * 2

      self.website:set_position(
        self.size.x / 2 - web_buttons_w / 2, web_buttons_y
      )
      self.docs:set_position(
        self.website:get_right() + style.padding.x, web_buttons_y
      )
      self.plugins:set_position(
        self.docs:get_right() + style.padding.x, web_buttons_y
      )
    end

    if #self.recent_projects.rows > 0 then
      if items_h < self:get_height() then
        self.recent_projects:set_size(
          nil,
          self:get_height() - self.website:get_bottom() - style.padding.y * 8
        )
      end
      self.recent_projects:set_position(
        style.padding.x,
        self.website:get_bottom() + style.padding.y * 6
      )
    end

    self.prev_size.x = self.size.x
    self.prev_size.y = self.size.y
  end

  return true
end

---We store the prealloc instance on the main object to allow overwriting.
---@type core.emptyview
EmptyView.prealloc_instance = nil

---Get reference to pre-allocated EmptyView.
---@return core.emptyview
function EmptyView.get_instance()
  if not EmptyView.prealloc_instance  then
    EmptyView.prealloc_instance  = EmptyView()
  end
  return EmptyView.prealloc_instance
end

return EmptyView
