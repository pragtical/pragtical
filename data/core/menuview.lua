local core = require "core"
local config = require "core.config"
local style = require "core.style"
local common = require "core.common"
local View = require "core.view"
local ContextMenu = require "core.contextmenu"

---Handle for the exact entries contributed by an application-menu registration.
---@class core.menuview.registration
---@field target core.contextmenu.item[] Parent array receiving the entries
---@field entries core.contextmenu.item[] Inserted entries, including owned divider objects
---@field name? string Plugin name used to replace a previous contribution
---@field removed? boolean Whether unregister() has already removed the entries

---Responsive application menu bar with an instance-owned plugin registry.
---@class core.menuview : core.view
---@overload fun():core.menuview
---@field items core.contextmenu.item[] Application menu registrations
---@field revision integer Registration revision for cache invalidation
---@field registrations table<string, core.menuview.registration> Named plugin registrations
---@field defaults? core.menuview.registration Core command registration
---@field menu core.contextmenu Popup used to display the active menu group
---@field visible boolean Requested bar visibility, synchronized with config.show_menubar
---@field compact? boolean Whether the bar uses one Menu label because groups do not fit
---@field active_menu? integer Open top-level group index, or 0 for the combined menu
---@field hovered? integer Hovered label index, or 0 for the compact label
---@field menu_entries? core.contextmenu.item[] Cached visible top-level entries
---@field entries_revision? integer Registry revision used by the visibility cache
---@field registry_revision? integer Registry revision last applied to the bar layout
local MenuView = View:extend()

---Separator sentinel shared with ContextMenu for plugin registrations.
MenuView.DIVIDER = ContextMenu.DIVIDER

---Initialize this bar's registry, default commands, popup, and configured visibility.
function MenuView:new()
  MenuView.super.new(self)
  self.items = {}
  self.registrations = {}
  self.revision = 0
  self:add_defaults()
  self.visible = config.show_menubar
  self.menu = ContextMenu()
end

---Resolve a registration path of stable IDs to the destination child array.
---Raises an error if any component does not name an existing submenu.
---@param items core.contextmenu.item[] Top-level registry
---@param path string[] Submenu IDs; an empty path targets the top level
---@return core.contextmenu.item[] target Destination entries
local function find(items, path)
  assert(type(path) == "table", "Application menu path must be an array of IDs")
  for _, id in ipairs(path) do
    assert(
      type(id) == "string" and id ~= "",
      "Application menu path IDs must be nonempty strings"
    )
    local found
    for _, item in ipairs(items) do
      if item.id == id then found = item; break end
    end
    assert(found and found.items, "Unknown application menu: " .. id)
    assert(type(found.items) == "table", "Cannot register inside a dynamic application menu: " .. id)
    items = found.items
  end
  return items
end

---Reject malformed fields, cyclic submenus, duplicate IDs, and conflicting actions.
---@param items core.contextmenu.item[] Entries to validate
---@param seen table<table, boolean> Arrays on the current recursion path
---@param path string Registration path used to identify invalid entries
local function validate(items, seen, path)
  assert(type(items) == "table", path .. ": submenu items must be an array")
  assert(not seen[items], path .. ": Application menus cannot contain cycles")
  seen[items] = true
  local ids = {}
  for i, item in ipairs(items) do
    assert(
      type(item) == "table",
      path .. "[" .. i .. "]: menu entry must be a table"
    )
    if item ~= MenuView.DIVIDER then
      local label = path .. "/" .. (
        type(item.id) == "string" and item.id or tostring(i)
      )
      assert(
        type(item.id) == "string" and item.id ~= "",
        label .. ": id must be a nonempty string"
      )
      assert(type(item.text) == "string", label .. ": text must be a string")
      assert(
        not ids[item.id],
        label .. ": Duplicate menu entry: " .. item.id
      )
      ids[item.id] = true
      assert(
        item.command == nil or type(item.command) == "string" or type(item.command) == "function",
        label .. ": command must be a command name or function"
      )
      assert(
        item.info == nil or type(item.info) == "string",
        label .. ": info must be a string"
      )
      for _, field in ipairs { "checked", "visible" } do
        assert(
          item[field] == nil or type(item[field]) == "boolean" or type(item[field]) == "function",
          label .. ": " .. field .. " must be a boolean or function"
        )
      end
      assert(
        not (item.items ~= nil and item.command ~= nil),
        label .. ": A menu entry cannot have both items and command"
      )
      if item.items ~= nil then
        if type(item.items) ~= "function" then validate(item.items, seen, label) end
      end
    end
  end
  seen[items] = nil
end

---Register application entries under stable IDs, independent of display labels.
---Validates before replacing a named contribution and preserves its position on reload.
---A submenu's items may be a function returning a fresh snapshot on opening.
---@param path string[] Empty to register top-level menus.
---@param entries core.contextmenu.item[]
---@param name? string Replace this plugin's previous registration when reloading.
---@return core.menuview.registration handle Pass to unregister to remove these entries
function MenuView:register(path, entries, name)
  assert(
    name == nil or type(name) == "string",
    "Registration names must be strings"
  )
  local target = find(self.items, path)
  validate(
    entries,
    {},
    #path > 0 and table.concat(path, "/") or "application menu"
  )
  local previous = name and self.registrations[name]
  local replacing = {}
  for _, entry in ipairs(previous and previous.entries or {}) do
    replacing[entry] = true
  end
  local position
  if previous and previous.target == target then
    for i, entry in ipairs(target) do
      if replacing[entry] then position = i; break end
    end
  end
  for _, entry in ipairs(entries) do
    for _, existing in ipairs(target) do
      assert(
        replacing[existing] or entry == MenuView.DIVIDER or entry.id ~= existing.id,
        "Duplicate menu entry: " .. tostring(entry.id)
      )
    end
  end
  if previous then self:unregister(previous) end
  local handle = { target = target, entries = {}, name = name }
  for _, entry in ipairs(entries) do
    if entry == MenuView.DIVIDER then
      entry = { divider = true }
    end
    table.insert(target, position or #target + 1, entry)
    if position then
      position = position + 1
    end
    table.insert(handle.entries, entry)
  end
  if name then
    self.registrations[name] = handle
  end
  self.revision = self.revision + 1
  return handle
end

---Remove the entries contributed by a registration.
---Repeated removal is harmless; invalidates the top-level visibility cache.
---@param handle core.menuview.registration? Handle returned by register()
function MenuView:unregister(handle)
  if not handle or handle.removed then return end
  for _, entry in ipairs(handle.entries) do
    for i, existing in ipairs(handle.target) do
      if existing == entry then table.remove(handle.target, i); break end
    end
  end
  if handle.name then self.registrations[handle.name] = nil end
  handle.removed = true
  self.revision = self.revision + 1
end

---Create a submenu group containing command entries or further submenus.
---@param id string Stable group ID
---@param text string Display label
---@param items core.contextmenu.source Child entries or a provider evaluated when opened
---@return core.contextmenu.item item Group definition
function MenuView:group(id, text, items)
  return { id = id, text = text, items = items }
end

---Create a command or direct action entry with an optional dynamic checkmark.
---@param id string Stable entry ID
---@param text string Display label
---@param name string|fun() Command name or direct action
---@param checked? boolean|fun():boolean Checked state evaluated by ContextMenu
---@return core.contextmenu.item item Entry definition
function MenuView:entry(id, text, name, checked)
  return { id = id, text = text, command = name, checked = checked }
end

---Install core-owned application entries once for this menu instance.
---Bundled and external plugins register their own entries after their commands load.
function MenuView:add_defaults()
  if self.defaults then return end
  local DIVIDER = MenuView.DIVIDER
  self.defaults = self:register({}, {
    self:group("file", "File", {
      self:entry("new", "New", "core:new-doc"),
      self:entry("new-named", "New Named File…", "core:new-named-doc"),
      self:entry("open", "Open File…", "core:open-file"),
      DIVIDER,
      self:entry("save", "Save", "doc:save"),
      self:entry("save-as", "Save As…", "doc:save-as"),
      DIVIDER,
      self:entry("reload", "Reload File", "doc:reload"),
      self:entry("rename", "Rename File…", "file:rename"),
      DIVIDER,
      self:entry("close", "Close", "root:close"),
      self:entry("close-others", "Close Others", "root:close-all-others"),
      self:entry("close-all", "Close All", "root:close-all"),
      DIVIDER,
      self:group("project", "Project", {
        self:entry("open", "Open Project…", "core:open-project-folder"),
        self:entry("change", "Change Project…", "core:change-project-folder"),
        self:entry("add", "Add Folder…", "core:add-directory"),
        self:entry("remove", "Remove Folder…", "core:remove-directory")
      }),
      DIVIDER,
      self:entry("quit", "Quit", "core:quit")
    }),
    self:group("edit", "Edit", {
      self:entry("undo", "Undo", "doc:undo"),
      self:entry("redo", "Redo", "doc:redo"),
      DIVIDER,
      self:entry("cut", "Cut", "doc:cut"),
      self:entry("copy", "Copy", "doc:copy"),
      self:entry("paste", "Paste", "doc:paste"),
      self:entry("select-all", "Select All", "doc:select-all"),
      DIVIDER,
      self:group("lines", "Lines", {
        self:entry("duplicate", "Duplicate Lines", "doc:duplicate-lines"),
        self:entry("delete", "Delete Lines", "doc:delete-lines"),
        self:entry("move-up", "Move Lines Up", "doc:move-lines-up"),
        self:entry("move-down", "Move Lines Down", "doc:move-lines-down"),
        self:entry("join", "Join Lines", "doc:join-lines"),
        DIVIDER,
        self:entry("indent", "Indent", "doc:indent"),
        self:entry("unindent", "Unindent", "doc:unindent")
      }),
      self:group("selection", "Selection", {
        self:entry("word", "Select Word", "doc:select-word"),
        self:entry("lines", "Select Lines", "doc:select-lines"),
        DIVIDER,
        self:entry("next", "Next Occurrence", "find-replace:select-next"),
        self:entry("previous", "Previous Occurrence", "find-replace:select-previous"),
        self:entry("add-next", "Add Next Occurrence", "find-replace:select-add-next"),
        self:entry("all", "Select All Occurrences", "find-replace:select-add-all")
      }),
      self:group("convert", "Convert", {
        self:entry("uppercase", "Uppercase", "doc:upper-case"),
        self:entry("lowercase", "Lowercase", "doc:lower-case"),
        DIVIDER,
        self:entry("line-endings", "Windows Line Endings (CRLF)", "doc:toggle-line-ending",
          function()
            return core.active_view.doc and core.active_view.doc.crlf or false
          end
        ),
        self:group("encoding", "Encoding", {
          self:entry("change", "Change Encoding…", "doc:change-encoding"),
          self:entry("reload", "Reload With Encoding…", "doc:reload-with-encoding")
        })
      }),
      DIVIDER,
      self:entry("comment", "Toggle Line Comment", "doc:toggle-line-comments"),
      self:entry("block-comment", "Toggle Block Comment", "doc:toggle-block-comments")
    }),
    self:group("search", "Search", {
      self:entry("find", "Find…", "find-replace:find"),
      self:entry("replace", "Replace…", "find-replace:replace"),
      self:entry("replace-selection", "Replace in Selection…", "find-replace:replace-in-selection"),
      self:entry("replace-symbol", "Replace Symbol…", "find-replace:replace-symbol"),
      DIVIDER,
      self:entry("next", "Next Match", "find-replace:repeat-find"),
      self:entry("previous", "Previous Match", "find-replace:previous-find"),
      DIVIDER,
      self:entry("line", "Go to Line…", "doc:go-to-line") }),
    self:group("view", "View", {
      self:group("split", "Split", {
        self:entry("left", "Left", "root:split-left"),
        self:entry("right", "Right", "root:split-right"),
        self:entry("up", "Up", "root:split-up"),
        self:entry("down", "Down", "root:split-down")
      }),
      self:group("focus", "Focus Pane", {
        self:entry("left", "Left", "root:switch-to-left"),
        self:entry("right", "Right", "root:switch-to-right"),
        self:entry("up", "Up", "root:switch-to-up"),
        self:entry("down", "Down", "root:switch-to-down")
      }),
      self:group("switch-tab", "Switch Tab", {
        self:entry("next", "Next Tab", "root:switch-to-next-tab"),
        self:entry("previous", "Previous Tab", "root:switch-to-previous-tab")
      }),
      DIVIDER,
      self:entry("statusbar", "Status Bar", "status-bar:toggle", function()
        return core.status_view.visible
      end),
      self:entry("menubar", "Menu Bar", "menu-bar:toggle", function()
        return config.show_menubar
      end),
      self:entry("tabs", "Tabs", "core:toggle-tabs", function()
        return not config.hide_tabs
      end),
      self:entry("line-numbers", "Line Numbers", "core:toggle-line-numbers", function()
        return config.show_line_numbers
      end),
      self:entry("fullscreen", "Fullscreen", "core:toggle-fullscreen", function()
        return core.window_mode == "fullscreen"
      end),
      DIVIDER,
      self:entry("markdown-preview", "Preview Markdown", "markdown-view:preview"),
      self:entry("markdown-raw", "View Markdown Source", "markdown-view:view-raw")
    }),
    self:group("tools", "Tools", {
      self:entry("commands", "Command Palette…", "core:find-command"),
      DIVIDER,
      self:entry("audio-player", "Open Audio Player", "audio-player:open"),
      self:entry("log", "Log", "core:open-log"),
      self:entry("user-config", "User Configuration", "core:open-user-module"),
      self:entry("project-config", "Project Configuration", "core:open-project-module"),
      DIVIDER,
      self:entry("restart", "Restart", "core:restart")
    }),
    self:group("help", "Help", {
      self:entry("docs", "Documentation", "core:view-documentation-help"),
      self:entry("website", "Website", "core:view-website"),
      self:entry("discord", "Discord", function()
        common.open_in_system("https://discord.gg/8V2yJtn3Fc")
      end),
      self:entry("github", "GitHub", function()
        common.open_in_system("https://github.com/pragtical")
      end),
      DIVIDER,
      self:entry("about", "About", "core:view-about")
    })
  })
end

---Keep the editor's keyboard focus when clicking the application menu bar.
---@return nil target The bar never takes focus
function MenuView:get_focus_target()
  return nil
end

---Show the bar using its slide animation and enable its visibility setting.
function MenuView:show()
  self.visible = true
  config.show_menubar = true
end

---Close the popup and slide the bar away, disabling its visibility setting.
function MenuView:hide()
  self.menu:hide()
  self.hovered = nil
  self.visible, config.show_menubar = false, false
end

---Toggle the bar's requested visibility and its corresponding config setting.
function MenuView:toggle()
  if self.visible then
    self:hide()
  else
    self:show()
  end
end

---Get visible top-level groups, cached until registration changes or opening refreshes.
---Dynamic visibility callbacks are evaluated only when refreshing this cache.
---@param refresh? boolean Force reevaluation for a new menu opening
---@return core.contextmenu.item[] entries Visible groups in registry order
function MenuView:entries(refresh)
  if not refresh and self.entries_revision == self.revision then
    return self.menu_entries
  end
  local items = {}
  for _, item in ipairs(self.items) do
    local visible = item.visible == nil or item.visible
    if type(visible) == "function" then
      local ok, result = core.try(visible)
      visible = ok and result
    end
    if item ~= MenuView.DIVIDER and not item.divider and visible then
      table.insert(items, item)
    end
  end
  self.entries_revision, self.menu_entries = self.revision, items
  return items
end

---Iterate bar labels with their screen x coordinates and padded widths.
---@return fun():integer, string, number, number iterator Yields index, label, x, width; compact index is 0
function MenuView:each_label()
  local x = self.position.x
  return coroutine.wrap(function()
    if self.compact then
      coroutine.yield(
        0, "Menu", x,
        style.font:get_width("Menu") + style.padding.x * 2
      )
    else
      for i, item in ipairs(self:entries()) do
        local width = style.font:get_width(item.text) + style.padding.x * 2
        coroutine.yield(i, item.text, x, width)
        x = x + width
      end
    end
  end)
end

---Find the visible bar label under a screen point.
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@return integer? index Label index, 0 for the compact label, or nil outside the bar
function MenuView:label_at(x, y)
  if not self.visible then
    return
  end
  if y < self.position.y or y >= self.position.y + self.size.y then
    return
  end
  for i, _, bx, width in self:each_label() do
    if x >= bx and x < bx + width then return i end
  end
end

---Open a group with no selected row, preserving editor focus and refreshing visibility.
---The hidden or compact bar defaults to a combined popup containing every group.
---@param index? integer Visible group index, or 0 for the combined menu
function MenuView:open(index)
  local entries = self:entries(true)
  if #entries == 0 then return end
  if self.menu.show_context_menu then self.menu:hide() end
  index = index or ((self.compact or not self.visible) and 0 or 1)
  local item = entries[index]
  local x = self.position.x
  for i, _, bx in self:each_label() do if i == index then x = bx end end
  self.active_menu = index
  self.menu:show_items(
    index == 0 and entries or item.items or { item },
    x, self.position.y + self.size.y,
    {
      disabled = true,
      owner = self,
      anchor = {
        target = function()
          return { x = x, y = self.position.y, w = 0, h = self.size.y }
        end,
        side = "bottom"
      }
  })
  ---Switch visible top-level groups for Left/Right navigation, wrapping at the ends.
  ---@param step integer Direction: -1 for previous, 1 for next
  self.menu.switch_top_menu = function(step)
    if index ~= 0 then
      self:open((self.active_menu - 1 + step) % #entries + 1)
    end
  end
end

---Keep keyboard-opened application popups available while the bar itself is hidden.
---@return boolean visible Always true
function MenuView:is_floating_owner_visible()
  return true
end

---Open a clicked label, or close its popup when clicking the same label again.
---@param button core.view.mousebutton Pressed button
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@return boolean consumed Always true for input routed to the bar
function MenuView:on_mouse_pressed(button, x, y)
  local index = self:label_at(x, y)
  if button == "left" and index ~= nil then
    if self.menu.show_context_menu and index == self.active_menu then
      self.menu:hide()
    else
      self:open(index)
    end
  end
  return true
end

---Update label hover and switch groups while an application popup is already open.
---@param x number Screen x coordinate
---@param y number Screen y coordinate
function MenuView:on_mouse_moved(x, y)
  local index = self:label_at(x, y)
  if self.hovered ~= index then
    self.hovered = index
    if
      self.menu.show_context_menu
      and index ~= nil
      and index ~= self.active_menu
    then
      self:open(index)
    end
    core.redraw = true
  end
end

---Clear the hovered label while retaining the active popup.
function MenuView:on_mouse_left()
  self.hovered = nil
end

---Animate visibility and select compact layout when groups exceed available width.
---Closes stale popups after registry or layout changes without rebuilding rows.
function MenuView:update()
  self.visible = config.show_menubar
  -- update only if size needs changing
  if not self.visible and self.size.y <= 0 then return end
  local height = self.visible
    and style.font:get_height() + style.padding.y * 2
    or 0
  if self.visible and self.size.y == height then
    if
      self.prev_size
      and self.prev_size.x == self.size.x
      and self.prev_size.y == self.size.y
      and self.prev_size.scale == SCALE
      and self.registry_revision == self.revision
    then
      return
    end
  end
  -- regular update routine
  self:move_towards(self.size, "y", height, nil, "menubar")
  local width = 0
  for _, item in ipairs(self:entries()) do
    width = width + style.font:get_width(item.text) + style.padding.x * 2
  end
  local compact = width > self.size.x
  if compact ~= self.compact or self.registry_revision ~= self.revision then
    self.menu:hide()
  end
  self.compact, self.registry_revision = compact, self.revision
  self.prev_size = {x = self.size.x, y = self.size.y, scale = SCALE}
end

---Draw the bar and label highlights while its animated height remains positive.
function MenuView:draw()
  if self.size.y <= 0 then return end
  self:draw_background(style.background2)
  for i, text, x, width in self:each_label() do
    if
      i == self.hovered
      or self.menu.show_context_menu
      and i == self.active_menu
    then
      renderer.draw_rect(
        x, self.position.y,
        width, self.size.y,
        style.selection
      )
    end
    common.draw_text(
      style.font, style.text,
      text, "center",
      x, self.position.y,
      width, self.size.y
    )
  end
end

return MenuView
