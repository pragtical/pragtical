local core = require "core"
local config = require "core.config"
local command = require "core.command"
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

---Responsive menu bar with an instance-owned registry and optional explicit bounds.
---@class core.menuview : core.view
---@overload fun(items?:core.contextmenu.item[]):core.menuview
---@field application_menu boolean Whether application defaults and visibility settings are used
---@field items core.contextmenu.item[] Menu registrations
---@field revision integer Registration revision for cache invalidation
---@field registrations table<string, core.menuview.registration> Named plugin registrations
---@field defaults? core.menuview.registration Core command registration
---@field menu core.contextmenu Popup used to display the active menu group
---@field visible boolean Requested bar visibility; application menus synchronize with config.show_menubar
---@field compact? boolean Whether the bar uses one Menu label because groups do not fit
---@field active_menu? integer Open top-level group index, or 0 for the combined menu
---@field hovered? integer Hovered label index, or 0 for the compact label
---@field menu_entries? core.contextmenu.item[] Cached visible top-level entries
---@field entries_revision? integer Registry revision used by the visibility cache
---@field registry_revision? integer Registry revision last applied to the bar layout
---@field bounds? {x:number, y:number, w:number, h:number} Available explicit rectangle; nil uses node layout
---@field inline_width number Animated width occupied inside the explicit rectangle
---@field label_layout? core.menuview.label_layout Cached label measurements
local MenuView = View:extend()

---Measurements shared by layout, drawing, and pointer input.
---@class core.menuview.label_layout
---@field entries core.contextmenu.item[] Measured top-level entries
---@field font renderer.font Measured font
---@field font_size number Measured font size
---@field padding number Horizontal label padding
---@field widths number[] Padded group widths
---@field width number Total group width
---@field compact_width number Padded width of the compact Menu label

---Separator sentinel shared with ContextMenu for plugin registrations.
MenuView.DIVIDER = ContextMenu.DIVIDER

---Create an application menu, or an independent menu when an item array is supplied.
---Independent menus start visible; pass an empty array to register entries later.
---Entries use the same stable IDs and validation as register().
---@param items? core.contextmenu.item[] Independent entries; omit for application defaults and settings
function MenuView:new(items)
  MenuView.super.new(self)
  self.items = {}
  self.registrations = {}
  self.revision = 0
  self.application_menu = items == nil
  if self.application_menu then
    self:add_defaults()
    self.visible = config.show_menubar
  else
    self:register({}, items)
    self.visible = true
  end
  self.menu = ContextMenu()
  self.inline_width = 0
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
        self:entry("insert-above", "Insert Line Above", "doc:newline-above"),
        self:entry("insert-below", "Insert Line Below", "doc:newline-below"),
        DIVIDER,
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
        self:entry("clear", "Clear Selection", "doc:select-none"),
        self:entry("word", "Select Word", "doc:select-word"),
        self:entry("lines", "Select Lines", "doc:select-lines"),
        DIVIDER,
        self:entry("cursor-above", "Add Cursor Above", "doc:create-cursor-previous-line"),
        self:entry("cursor-below", "Add Cursor Below", "doc:create-cursor-next-line"),
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
          self:entry("reload", "Reload With Encoding…", "doc:reload-with-encoding"),
          DIVIDER,
          self:entry("bom", "Byte Order Mark", "doc:toggle-bom",
            ---Reflect the active document's byte order mark.
            ---@return boolean checked Whether a byte order mark is present
            function()
              return core.active_view.doc and core.active_view.doc.bom ~= nil or false
            end
          )
        })
      }),
      DIVIDER,
      self:entry("comment", "Toggle Line Comment", "doc:toggle-line-comments"),
      self:entry("block-comment", "Toggle Block Comment", "doc:toggle-block-comments"),
      DIVIDER,
      self:entry("overwrite", "Overwrite Mode", "doc:toggle-overwrite",
        ---Reflect overwrite mode in the active document.
        ---@return boolean checked Whether typing overwrites existing text
        function()
          return core.active_view.doc and core.active_view.doc.overwrite or false
        end
      )
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
      self:group("resize", "Resize Pane", {
        self:entry("grow", "Grow", "root:grow"),
        self:entry("shrink", "Shrink", "root:shrink")
      }),
      self:group("switch-tab", "Switch Tab", {
        self:entry("next", "Next Tab", "root:switch-to-next-tab"),
        self:entry("previous", "Previous Tab", "root:switch-to-previous-tab"),
        DIVIDER,
        self:entry("move-left", "Move Tab Left", "root:move-tab-left"),
        self:entry("move-right", "Move Tab Right", "root:move-tab-right")
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
      self:entry("markdown-raw", "View Markdown Source", "markdown-view:view-raw"),
      {
        id = "image", text = "Image",
        ---Show image controls only when their command predicate accepts the view.
        ---@return boolean visible Whether an image view is active
        visible = function() return command.is_valid("image-view:auto-fit") end,
        items = {
          self:entry("fit", "Fit Image", "image-view:auto-fit"),
          self:entry("zoom-in", "Zoom In", "image-view:zoom-in"),
          self:entry("zoom-out", "Zoom Out", "image-view:zoom-out"),
          self:entry("actual-size", "Actual Size", "image-view:zoom-reset"),
          DIVIDER,
          self:group("background", "Background", {
            self:entry("solid", "Solid", "image-view:background-mode-solid",
              ---Reflect the solid image background setting.
              ---@return boolean checked Whether a solid background is selected
              function() return config.images_background_mode == "solid" end
            ),
            self:entry("grid", "Checkerboard", "image-view:background-mode-grid",
              ---Reflect the checkerboard image background setting.
              ---@return boolean checked Whether a checkerboard background is selected
              function() return config.images_background_mode == "grid" end
            ),
            self:entry("none", "Transparent", "image-view:background-mode-none",
              ---Reflect the transparent image background setting.
              ---@return boolean checked Whether no image background is drawn
              function() return config.images_background_mode == "none" end
            )
          })
        }
      }
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

---Keep the editor's keyboard focus when clicking the menu bar.
---@return nil target The bar never takes focus
function MenuView:get_focus_target()
  return nil
end

---Show the bar using its slide animation and update application settings if used.
function MenuView:show()
  self.visible = true
  if self.application_menu then config.show_menubar = true end
end

---Close the popup and slide the bar away, updating application settings if used.
function MenuView:hide()
  self.menu:hide()
  self.hovered = nil
  self.visible = false
  if self.application_menu then config.show_menubar = false end
end

---Toggle this bar's visibility.
function MenuView:toggle()
  if self.visible then
    self:hide()
  else
    self:show()
  end
end

---Set the menu's available rectangle in screen coordinates.
---Omit all arguments to resume automatic node layout. Zero sizes retain explicit bounds.
---The host forwards pointer events and hides the menu when hiding or removing it.
---Update the menu once per frame, through its node or the host, and draw it in the
---host. Refresh bounds before drawing if node layout moved or resized the host.
---Bounds changes do not advance animation or refresh menu callbacks.
---Example inside a host view using an independent menu:
---```lua
---function MyView:new()
---  MyView.super.new(self)
---  self.menu = MenuView({ { id = "tools", text = "Tools", items = {} } })
---end
---function MyView:update()
---  self.menu:set_bounds(self.position.x, self.position.y, self.size.x, 30 * SCALE)
---  self.menu:update()
---end
---function MyView:draw()
---  self.menu:set_bounds(self.position.x, self.position.y, self.size.x, 30 * SCALE)
---  self.menu:draw()
---end
---function MyView:on_mouse_pressed(button, x, y, clicks)
---  if self.menu:hit_test(x, y) then return self.menu:on_mouse_pressed(button, x, y, clicks) end
---  return MyView.super.on_mouse_pressed(self, button, x, y, clicks)
---end
---function MyView:on_mouse_moved(...) self.menu:on_mouse_moved(...) end
---function MyView:on_mouse_left() self.menu:on_mouse_left() end
--- -- Call self.menu:hide() when hiding or removing MyView.
---```
---@param x? number Left edge; omit to resume automatic node layout
---@param y? number Top edge, required when x is supplied
---@param width? number Available width, required when x is supplied
---@param height? number Available height, required when x is supplied
function MenuView:set_bounds(x, y, width, height)
  local explicit = x ~= nil
  local bounds = self.bounds
  if explicit then
    width, height = math.max(0, width), math.max(0, height)
    if bounds and bounds.x == x and bounds.y == y
      and bounds.w == width and bounds.h == height
    then return end
  elseif not bounds then
    return
  end
  if explicit ~= (bounds ~= nil) then
    self.menu:hide()
    self.hovered = nil
    self.inline_width, self.size.y = 0, 0
    self.move_data_inline_width, self.size.move_data_y = nil, nil
  end
  if explicit then
    bounds = bounds or {}
    bounds.x, bounds.y, bounds.w, bounds.h = x, y, width, height
    self.bounds = bounds
    -- Reflow cached labels after layout without reevaluating entry callbacks.
    if self.label_layout then
      local compact = self.label_layout.width > width
      if compact ~= self.compact then
        self.menu:hide()
        self.hovered = nil
        self.compact = compact
      end
    end
  else
    self.bounds = nil
  end
  core.redraw = true
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

---Measure labels only when their entries, font, or padding changes.
---@return core.menuview.label_layout layout Cached padded widths
function MenuView:measure_labels()
  local entries = self:entries()
  local layout = self.label_layout
  local font_size = style.font:get_size()
  if not layout or layout.entries ~= entries or layout.font ~= style.font
    or layout.font_size ~= font_size or layout.padding ~= style.padding.x
  then
    layout = {
      entries = entries, font = style.font, font_size = font_size,
      padding = style.padding.x, widths = {}, width = 0,
      compact_width = style.font:get_width("Menu") + style.padding.x * 2
    }
    for i, item in ipairs(entries) do
      local width = style.font:get_width(item.text) + style.padding.x * 2
      layout.widths[i] = width
      layout.width = layout.width + width
    end
    self.label_layout = layout
  end
  return layout
end

---Get the displayed menu rectangle using explicit bounds or node layout.
---Its occupied width may be smaller than set_bounds() allows, including during animation.
---@return number x Screen x coordinate
---@return number y Screen y coordinate
---@return number width Visible width, clipped during a width transition
---@return number height Visible height
function MenuView:get_bounds()
  local bounds = self.bounds
  if bounds then
    return bounds.x, bounds.y, math.min(self.inline_width, bounds.w), bounds.h
  end
  return self.position.x, self.position.y, self.size.x, self.size.y
end

---Test the displayed bar rectangle, including explicit bounds and visibility.
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@return boolean inside Whether the point lies in the visible bar
function MenuView:hit_test(x, y)
  local bx, by, width, height = self:get_bounds()
  return self.visible and x >= bx and y >= by
    and x < bx + width and y < by + height
end

---Iterate bar labels with their screen x coordinates and padded widths.
---@return fun():integer, string, number, number iterator Yields index, label, x, width; compact index is 0
function MenuView:each_label()
  local x = self:get_bounds()
  local layout = self:measure_labels()
  return coroutine.wrap(function()
    if self.compact then
      coroutine.yield(
        0, "Menu", x,
        layout.compact_width
      )
    else
      for i, item in ipairs(layout.entries) do
        local width = layout.widths[i]
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
  if not self:hit_test(x, y) then return end
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
  local x, y, _, height = self:get_bounds()
  for i, _, bx in self:each_label() do if i == index then x = bx end end
  self.active_menu = index
  self.menu:show_items(
    index == 0 and entries or item.items or { item },
    x, y + height,
    {
      disabled = true,
      owner = self,
      anchor = {
        target = function()
          local bx, by, _, bh = self:get_bounds()
          for i, _, label_x in self:each_label() do
            if i == index then bx = label_x; break end
          end
          return { x = bx, y = by, w = 0, h = bh }
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

---Keep explicitly opened popups available while the bar itself is hidden.
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
  if self.application_menu then
    if self.visible and not config.show_menubar then
      self.menu:hide()
      self.hovered = nil
    end
    self.visible = config.show_menubar
  end
  if not self.visible and self.size.y <= 0 and self.inline_width <= 0 then return end
  local layout = self:measure_labels()
  local width = self.bounds and self.bounds.w or self.size.x
  local compact = layout.width > width
  if compact ~= self.compact or self.registry_revision ~= self.revision then self.menu:hide() end
  self.compact, self.registry_revision = compact, self.revision
  if self.bounds then
    self.size.y = 0
    local target = self.visible and math.min(width, compact and layout.compact_width or layout.width) or 0
    self:move_towards("inline_width", target, nil, "menubar")
  else
    local height = self.visible and style.font:get_height() + style.padding.y * 2 or 0
    self:move_towards(self.size, "y", height, nil, "menubar")
  end
end

---Draw labels within the standalone row or the host's animated inline bounds.
function MenuView:draw()
  local bx, by, bw, bh = self:get_bounds()
  if bw <= 0 or bh <= 0 then return end
  core.push_clip_rect(bx, by, bw, bh)
  renderer.draw_rect(bx, by, bw, bh, style.background2)
  for i, text, x, width in self:each_label() do
    if
      i == self.hovered
      or self.menu.show_context_menu
      and i == self.active_menu
    then
      renderer.draw_rect(
        x, by,
        width, bh,
        style.selection
      )
    end
    common.draw_text(
      style.font, style.text,
      text, "center",
      x, by,
      width, bh
    )
  end
  core.pop_clip_rect()
end

return MenuView
