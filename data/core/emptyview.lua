local core = require "core"
local command = require "core.command"
local common = require "core.common"
local ContextMenu = require "core.contextmenu"
local style = require "core.style"
local Widget = require "widget"
local Button = require "widget.button"
local ListBox = require "widget.listbox"
local Container = require "widget.container"

---@class core.emptyview : widget
---@field super widget
local EmptyView = Widget:extend()

---@type core.contextmenu
EmptyView.recent_projects_menu = ContextMenu()

function EmptyView:__tostring() return "EmptyView" end

---Font used to render the logo
---@type renderer.font
local icon_huge_font

---Prevent the font getting scaled more than once from multiple instances
---@type boolean
local icon_font_scaled = false

---Current font scale in case rescaling is required on EmptyView creation
local icon_font_current_scale = SCALE

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
  { name = "change_folder", icon = "s", cmd = "core:change-project-folder",
    label = "Change Project", tooltip = "Change main project of current instance"
  },
  { name = "find_file", icon = "L", cmd = "core:find-file",
    label = "Find File", tooltip = "Search for a file from current project"
  },
  { name = "run_command", icon = "B", cmd = "core:find-command",
    label = "Run Command", tooltip = "Search for a command to run"
  },
  { name = "settings", icon = "P", cmd = "ui:settings",
    label = "Settings", tooltip = "Open the settings interface"
  }
}

---Constructor
function EmptyView:new()
  EmptyView.super.new(self, nil, false)

  if not icon_huge_font or icon_font_current_scale ~= SCALE then
    icon_huge_font = style.icon_big_font:copy(110 * SCALE)
  end

  self.name = "Welcome"
  self.type_name = "core.emptyview"
  self.background_color = style.background
  self.border.width = 0
  self.scrollable = true

  self.title = "Pragtical"
  self.version = "version " .. VERSION
  self.title_width = style.big_font:get_width(self.title)
  self.version_width = style.font:get_width(self.title)
  self.text_x = 0
  self.text_y = 0
  self.logo_width = 0

  self.top_container = Container(
    self,
    Container.direction.HORIZONTAL,
    Container.alignment.CENTER
  )

  for _, button in ipairs(buttons) do
    self[button.name] = Button(self.top_container, button.label)
    self[button.name]:set_icon(button.icon)
    self[button.name].border.width = 0
    self[button.name]:set_tooltip(button.tooltip, button.cmd)
    self[button.name].on_click = function(_, pressed)
      if pressed == "left" then
        command.perform(button.cmd)
      end
    end
  end

  self.center_container = Container(self)

  self.website = Button(self.center_container, "Website")
  self.website:set_icon("G")
  self.website:set_tooltip("Visit the editor website", "core:view-website")
  self.website.on_click = function(_, pressed)
    command.perform "core:view-website"
  end

  self.docs = Button(self.center_container, "Documentation")
  self.docs:set_icon("?")
  self.docs:set_tooltip("Visit the editor documentation", "core:view-documentation-help")
  self.docs.on_click = function(_, pressed)
    command.perform "core:view-documentation-help"
  end

  self.plugins = Button(self.center_container, "Plugins")
  self.plugins:set_icon("p")
  self.plugins:set_tooltip("Open the plugin manager")
  self.plugins.on_click = function(_, pressed)
    command.perform("plugin-manager:show")
  end
  self.plugins:hide()

  self.recent_projects = ListBox(self)
  self.recent_projects:add_column("Recent Projects")
  self.recent_projects:hide()
  self.recent_projects_context_target = nil
  self.prev_size = { x = self.size.x, y = self.size.y }
  self:refresh_recent_projects()
  function self.recent_projects:on_mouse_pressed(button, x, y, clicks)
    self.super.on_mouse_pressed(self, button, x, y, clicks)
    if button == "right" then
      self:set_selected(self.parent:get_recent_project_row_at(x, y))
    end
    local idx = self:get_selected()
    local data = self:get_row_data(idx)
    if button == "right" then
      self.parent.recent_projects_context_target = data
    elseif button == "left" and clicks == 2 and data then
      core.open_project(data.path)
    end
  end

  self:show()
  self:update()
end

function EmptyView:get_h_scrollable_size()
  return 0
end

---Find the recent-project row under a screen position.
---@param x number
---@param y number
---@return integer? row
function EmptyView:get_recent_project_row_at(x, y)
  if not self.recent_projects:mouse_on_top(x, y) then return nil end

  local list = self.recent_projects
  local header_height = style.font:get_height() + style.padding.y
  local scroll_y = list.scroll and list.scroll.y or 0
  local y_offset = list.position.y + list.border.width - scroll_y

  for idx, row in ipairs(list.rows) do
    local row_y = y_offset + row.y + (style.padding.y / 2)
    if idx == 1 then
      row_y = y_offset + header_height
    end
    if y >= row_y and y <= row_y + row.h then
      return idx
    end
  end

  return nil
end

---Refresh the displayed recent projects from the core session state.
function EmptyView:refresh_recent_projects()
  self.recent_projects:clear()
  self.recent_projects_context_target = nil

  if core.recent_projects and type(core.recent_projects) == "table" then
    for _, path in ipairs(core.recent_projects) do
      self.recent_projects:add_row({common.home_encode(path)}, {path = path})
    end
  end

  if #self.recent_projects.rows == 0 then
    self.recent_projects:hide()
  end
  self.prev_size.x = -1
  core.redraw = true
end

---Get the recent project targeted by the context menu.
---@return string? path
function EmptyView:get_selected_recent_project()
  local data = self.recent_projects_context_target
  return data and data.path or nil
end

---Open a recent project in a separate editor instance.
---@param path string
function EmptyView:open_recent_project_new_instance(path)
  system.exec(string.format("%q %q", EXEFILE, path))
end

---Add a recent project to the current editor instance.
---@param path string
function EmptyView:add_recent_project_current_instance(path)
  local abs_path = system.absolute_path(path)
  if abs_path then
    core.add_project(abs_path)
  else
    core.error("Cannot add project %q", path)
  end
end

---Remove a project from the recent projects list.
---@param path string
function EmptyView:remove_recent_project(path)
  local dirname = common.normalize_volume(path)
  if not dirname or not core.recent_projects then return end

  for i = #core.recent_projects, 1, -1 do
    if core.recent_projects[i] == dirname then
      table.remove(core.recent_projects, i)
    end
  end

  self:refresh_recent_projects()
end

---Remove all projects from the recent projects list.
function EmptyView:remove_all_recent_projects()
  core.recent_projects = {}
  self:refresh_recent_projects()
end

function EmptyView:on_scale_change(new_scale)
  if not icon_font_scaled then
    icon_font_scaled = true
    icon_huge_font = style.icon_big_font:copy(110 * new_scale)
    icon_font_scaled = false
    icon_font_current_scale = new_scale
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
    if self.logo_width < self.size.x then
      x = renderer.draw_text(style.big_font, self.title, x1, y1, style.dim)
      renderer.draw_text(style.font, self.version, xv, y1 + th, style.dim)
      x = x + style.padding.x
      renderer.draw_rect(x, y, math.ceil(1 * SCALE), dh, style.dim)
      x = x + style.padding.x
      renderer.draw_text(icon_huge_font, "5", x, y, style.background2)
    else
      x = x + (self.size.x / 2) - (icon_huge_font:get_width("9") / 2) - style.padding.x
    end

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
  if not EmptyView.super.draw(self) then return end
  local _, oy = self:get_content_offset()
  draw_text(self, self.text_x, self.text_y + oy)
  EmptyView.recent_projects_menu:draw()
  self:draw_scrollbar()
end

function EmptyView:on_mouse_pressed(button, x, y, clicks)
  if EmptyView.recent_projects_menu.show_context_menu then
    return EmptyView.recent_projects_menu:on_mouse_pressed(button, x, y, clicks)
  end
  local processed = EmptyView.super.on_mouse_pressed(self, button, x, y, clicks)
  local handled = false
  if self.recent_projects:mouse_on_top(x, y) then
    handled = EmptyView.recent_projects_menu:on_mouse_pressed(button, x, y, clicks)
  end
  return handled or processed
end

function EmptyView:on_mouse_moved(x, y, dx, dy)
  if EmptyView.recent_projects_menu:on_mouse_moved(x, y) then return true end
  return EmptyView.super.on_mouse_moved(self, x, y, dx, dy)
end

function EmptyView:update()
  if not EmptyView.super.update(self) then return end
  EmptyView.recent_projects_menu:update()

  self.background_color = style.background

  if self.prev_size.x ~= self.size.x or self.prev_size.y ~= self.size.y then
    if not self.plugins:is_visible() and command.is_valid("plugin-manager:show") then
      self.plugins:show()
      self.prev_size.x = -1
      self.center_container.size.x = -1
    end

    self.recent_projects:update_position()

    self.top_container:set_position(0, 0)
    self.top_container:set_size(self:get_width())
    self.top_container:update()

    self.title = "Pragtical"
    self.version = "version " .. VERSION
    self.title_width = style.big_font:get_width(self.title)
    self.version_width = style.font:get_width(self.version)

    -- calculate logo and version positioning
    local tw, th = draw_text(self, 0, 0, true)
    self.logo_width = tw

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

      items_h = th + self.top_container:get_height()
        + self.center_container:get_height()
        + self.recent_projects:get_height()
        + style.padding.y * 8

      if items_h < self:get_height() then
        ty = ty - self.recent_projects:get_height() / 2
      else
        ty = common.clamp(ty,
          self.top_container:get_bottom() + style.padding.y * 4,
          ty - self.recent_projects:get_height()
        )
      end
    end

    if ty < self.top_container:get_bottom() + style.padding.y * 4 then
      ty = self.top_container:get_bottom() + style.padding.y * 4
    end

    self.text_x = tx
    self.text_y = ty

    -- reposition web buttons and recent projects
    local web_buttons_y = ty + th + style.padding.y * 2

    self.center_container:set_position(0, web_buttons_y)
    self.center_container:set_size(self:get_width())
    self.center_container:update()

    if #self.recent_projects.rows > 0 then
      if items_h < self:get_height() then
        self.recent_projects:set_size(
          nil,
          self:get_height() - self.center_container:get_bottom() - style.padding.y * 8
        )
      end
      self.recent_projects:set_position(
        style.padding.x,
        self.center_container:get_bottom() + style.padding.y * 6
      )
    end

    self.prev_size.x = self.size.x
    self.prev_size.y = self.size.y

    EmptyView.super.update(self)
  end
end

local function recent_project_predicate()
  local view = core.active_view
  if view and view:is(EmptyView) then
    local path = view:get_selected_recent_project()
    if path then return true, view, path end
  end
  return false
end

local function recent_projects_predicate()
  local view = core.active_view
  if view and view:is(EmptyView) and #view.recent_projects.rows > 0 then
    return true, view
  end
  return false
end

command.add(recent_project_predicate, {
  ["welcome:open-recent-project-new-instance"] = function(view, path)
    view:open_recent_project_new_instance(path)
  end,
  ["welcome:add-recent-project-current-instance"] = function(view, path)
    view:add_recent_project_current_instance(path)
  end,
  ["welcome:remove-recent-project"] = function(view, path)
    view:remove_recent_project(path)
  end
})

command.add(recent_projects_predicate, {
  ["welcome:remove-all-recent-projects"] = function(view)
    view:remove_all_recent_projects()
  end
})

EmptyView.recent_projects_menu:register(recent_project_predicate, {
  { text = "Open in New Instance", command = "welcome:open-recent-project-new-instance" },
  { text = "Add to Current Instance", command = "welcome:add-recent-project-current-instance" },
  ContextMenu.DIVIDER,
  { text = "Remove", command = "welcome:remove-recent-project" }
})

EmptyView.recent_projects_menu:register(recent_projects_predicate, {
  { text = "Remove All", command = "welcome:remove-all-recent-projects" }
})

return EmptyView
