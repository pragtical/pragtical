local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local DocView = require "core.docview"
local CommandView = require "core.commandview"
local LogView = require "core.logview"
local ImageView = require "core.imageview"
local View = require "core.view"
local Object = require "core.object"


---Styled text array containing fonts, colors, and strings.
---@alias core.statusview.styledtext table<integer, renderer.font|renderer.color|string>

---Left or right alignment identifier.
---@alias core.statusview.position '"left"' | '"right"'


---Status bar with customizable items displaying document info and system status.
---Access the global instance via `core.status_view`.
---@class core.statusview : core.view
---@field super core.view
---@field items core.statusview.item[] All registered items
---@field active_items core.statusview.item[] Currently visible items that pass predicates
---@field hovered_item core.statusview.item Item currently under mouse cursor
---@field message_timeout number Timestamp when current message expires
---@field message core.statusview.styledtext Current temporary message content
---@field tooltip_mode boolean Whether persistent tooltip is active
---@field tooltip core.statusview.styledtext Persistent tooltip content
---@field left_width number Visible width of left panel
---@field right_width number Visible width of right panel
---@field r_left_width number Real (total) width of left panel content
---@field r_right_width number Real (total) width of right panel content
---@field left_xoffset number Horizontal pan offset for left panel
---@field right_xoffset number Horizontal pan offset for right panel
---@field dragged_panel '""'|core.statusview.position Panel being dragged ("left", "right", or "")
---@field hovered_panel '""'|core.statusview.position Panel under cursor ("left", "right", or "")
---@field hide_messages boolean Whether to suppress status messages
local StatusView = View:extend()

function StatusView:__tostring() return "StatusView" end

---Space separator
---@type string
StatusView.separator  = "      "

---Pipe separator
---@type string
StatusView.separator2 = "   |   "

---@alias core.statusview.item.separator
---|>`StatusView.separator`
---| `StatusView.separator2`

---@alias core.statusview.item.predicate fun():boolean
---@alias core.statusview.item.onclick fun(button: string, x: number, y: number)
---@alias core.statusview.item.get_item fun(self: core.statusview.item):core.statusview.styledtext?,core.statusview.styledtext?
---@alias core.statusview.item.ondraw fun(x, y, h, hovered: boolean, calc_only?: boolean):number

---Individual status bar item with custom rendering and interaction.
---@class core.statusview.item : core.object
---@field name string Unique identifier for the item
---@field predicate core.statusview.item.predicate Condition to display item
---@field alignment core.statusview.item.alignment Left or right side placement
---@field tooltip string Text shown on mouse hover
---@field command string|nil Command name to execute on click
---@field on_click core.statusview.item.onclick|nil Click handler function
---@field on_draw core.statusview.item.ondraw|nil Custom drawing function
---@field background_color renderer.color|nil Normal background color
---@field background_color_hover renderer.color|nil Hover background color
---@field visible boolean Whether item is shown
---@field separator core.statusview.item.separator Separator style
---@field active boolean Whether item passes predicate check
---@field x number Horizontal position (calculated)
---@field w number Width in pixels (calculated)
---@field cached_item core.statusview.styledtext Cached rendered content
local StatusViewItem = Object:extend()

function StatusViewItem:__tostring() return "StatusViewItem" end

---Options for creating a status bar item.
---@class core.statusview.item.options : table
---@field predicate string|table|core.statusview.item.predicate Condition for display (string=module, table=class, function=custom, nil=always)
---@field name string Unique identifier for the item
---@field alignment core.statusview.item.alignment Left or right side placement
---@field get_item core.statusview.item.get_item Function returning styled text (can return empty table)
---@field command string|core.statusview.item.onclick|nil Command name or click callback
---@field position? integer Insertion position (-1=end, 1=beginning)
---@field tooltip? string Text displayed on mouse hover
---@field visible? boolean Initial visibility state
---@field separator? core.statusview.item.separator Separator style (space or pipe)

---Align item on left side of status bar.
---@type integer
StatusViewItem.LEFT = 1

---Align item on right side of status bar.
---@type integer
StatusViewItem.RIGHT = 2

---@alias core.statusview.item.alignment
---|>`StatusView.Item.LEFT`
---| `StatusView.Item.RIGHT`

---Create a new status bar item.
---@param options core.statusview.item.options
function StatusViewItem:new(options)
  self:set_predicate(options.predicate)
  self.name = options.name
  self.alignment = options.alignment or StatusView.Item.LEFT
  self.command = type(options.command) == "string" and options.command or nil
  self.tooltip = options.tooltip or ""
  self.on_click = type(options.command) == "function" and options.command or nil
  self.on_draw = nil
  self.background_color = nil
  self.background_color_hover = nil
  self.visible = options.visible == nil and true or options.visible
  self.active = false
  self.x = 0
  self.w = 0
  self.separator = options.separator or StatusView.separator
  self.get_item = options.get_item
end

---Generate the styled text for this item.
---Override this method or pass `get_item` in options.
---Ignored if `on_draw` is set.
---@return core.statusview.styledtext
function StatusViewItem:get_item() return {} end


---Hide the item from the status bar.
function StatusViewItem:hide() self.visible = false end


---Show the item on the status bar.
function StatusViewItem:show() self.visible = true end

---Set the condition to evaluate whether this item should be displayed.
---String: treated as module name (e.g. "core.docview"), checked against active view.
---Table: treated as class, checked against active view with `is()`.
---Function: called each update, should return boolean.
---Nil: always displays the item.
---@param predicate string|table|core.statusview.item.predicate
function StatusViewItem:set_predicate(predicate)
  self.predicate = command.generate_predicate(predicate)
end

---@type core.statusview.item
StatusView.Item = StatusViewItem


---Check if active view is a document view (but not command view).
---@return boolean
local function predicate_docview()
  return  core.active_view:is(DocView)
    and not core.active_view:is(CommandView)
end


---Create a new status bar and register default items.
function StatusView:new()
  StatusView.super.new(self)
  self.message_timeout = 0
  self.message = nil
  self.tooltip_mode = false
  self.tooltip = {}
  self.items = {}
  self.active_items = {}
  self.hovered_item = {}
  self.pointer = {x = 0, y = 0}
  self.left_width = 0
  self.right_width = 0
  self.r_left_width = 0
  self.r_right_width = 0
  self.left_xoffset = 0
  self.right_xoffset = 0
  self.dragged_panel = ""
  self.hovered_panel = ""
  self.hide_messages = false
  self.visible = true

  self:register_docview_items()
  self:register_command_items()
  self:register_imageview_items()
end

local clicks = -1
local gx, gy, dx, dy, gc = 0, 0, 2, -2, { table.unpack(style.text) }


---Register default status bar items for document views.
---Shows file, position, selections, indentation, encoding, line ending, etc.
function StatusView:register_docview_items()
  if self:get_item("doc:file") then return end

  self:add_item({
    predicate = predicate_docview,
    name = "doc:file",
    alignment = StatusView.Item.LEFT,
    get_item = function()
      local dv = core.active_view
      local filename
      if #core.projects > 1 and dv.doc.abs_filename then
        local project, is_open, belongs = core.current_project(
          dv.doc.abs_filename
        )
        if project and is_open and belongs then
          filename = {
            style.accent,
            common.basename(project.path),
            style.text,
            PATHSEP .. common.relative_path(project.path, dv.doc.abs_filename)
          }
        end
      end
      if not filename then
        filename = {
          dv.doc.filename and style.text or style.dim,
          common.home_encode(dv.doc:get_name())
        }
      end
      return {
        dv.doc:is_dirty() and style.accent or style.text, style.icon_font, "f",
        style.dim, style.font, self.separator2, table.unpack(filename)
      }
    end
  })

  self:add_item({
    predicate = predicate_docview,
    name = "doc:position",
    alignment = StatusView.Item.LEFT,
    get_item = function()
      local dv = core.active_view
      local line, col = dv.doc:get_selection()
      local tab_type, indent_size = dv.doc:get_indent_info()
      -- Calculating tabs when the doc is using the "hard" indent type.
      local ntabs = 0
      if tab_type == "hard" then
        local last_idx = 0
        while last_idx < col do
          local s, e = string.find(dv.doc.lines[line], "\t", last_idx, true)
          if s and s < col then
            ntabs = ntabs + 1
            last_idx = e + 1
          else
            break
          end
        end
      end
      col = col + ntabs * (indent_size - 1)
      return {
        style.text, line, ":",
        col > config.line_limit and style.accent or style.text, col,
        style.text
      }
    end,
    command = "doc:go-to-line",
    tooltip = "line : column"
  })

  self:add_item({
    predicate = predicate_docview,
    name = "doc:position-percent",
    alignment = StatusView.Item.LEFT,
    get_item = function()
      local dv = core.active_view
      local line = dv.doc:get_selection()
      return {
        string.format("%.f%%", line / #dv.doc.lines * 100)
      }
    end,
    tooltip = "caret position"
  })

  self:add_item({
    predicate = predicate_docview,
    name = "doc:selections",
    alignment = StatusView.Item.LEFT,
    get_item = function()
      local dv = core.active_view
      local nsel = math.floor(#dv.doc.selections / 4)
      if nsel > 1 then
        return { style.text, nsel, " selections" }
      end

      return {}
    end
  })

  self:add_item({
    predicate = predicate_docview,
    name = "doc:indentation",
    alignment = StatusView.Item.RIGHT,
    get_item = function()
      local dv = core.active_view
      local indent_type, indent_size, indent_confirmed = dv.doc:get_indent_info()
      local indent_label = (indent_type == "hard") and "tabs: " or "spaces: "
      return {
        style.text, indent_label, indent_size,
        indent_confirmed and "" or "*"
      }
    end,
    command = function(button, x, y)
      if button == "left" then
        command.perform "indent:set-file-indent-size"
      elseif button == "right" then
        command.perform "indent:set-file-indent-type"
      end
    end,
    separator = self.separator2
  })

  self:add_item({
    predicate = predicate_docview,
    name = "doc:stats",
    alignment = StatusView.Item.RIGHT,
    get_item = function()
      return config.stonks == nil and {} or {
        style.text,
        type(config.stonks) == "table" and config.stonks.font or style.icon_font,
        type(config.stonks) == "table" and config.stonks.icon or ( config.stonks and "g" or "h" ),
      }
    end,
    separator = self.separator2,
    command = function(button, x, y)
      if button == "left" then
        clicks = clicks + 1
      elseif button == "right" then
        clicks = -1
      end
      gx, gy = x, y
    end
  })

  self:add_item({
    predicate = predicate_docview,
    name = "doc:lines",
    alignment = StatusView.Item.RIGHT,
    get_item = function()
      local dv = core.active_view
      return {
        style.text, #dv.doc.lines, " lines",
      }
    end,
    separator = self.separator2
  })

  self:add_item({
    predicate = predicate_docview,
    name = "doc:encoding",
    alignment = StatusView.Item.RIGHT,
    get_item = function()
      local dv, bom = core.active_view, ""
      if dv.doc.bom then bom = " (BOM)" end
      return {
        style.text, (dv.doc.encoding or "none"), bom
      }
    end,
    command = function(button)
      if button == "left" then
        command.perform "doc:change-encoding"
      elseif button == "right" then
        command.perform "doc:reload-with-encoding"
      end
    end,
    tooltip = "encoding"
  })

  self:add_item({
    predicate = predicate_docview,
    name = "doc:line-ending",
    alignment = StatusView.Item.RIGHT,
    get_item = function()
      local dv = core.active_view
      return {
        style.text, dv.doc.crlf and "CRLF" or "LF"
      }
    end,
    command = "doc:toggle-line-ending"
  })

  self:add_item {
    predicate = predicate_docview,
    name = "doc:overwrite-mode",
    alignment = StatusView.Item.RIGHT,
    get_item = function()
      return {
        style.text, core.active_view.doc.overwrite and "OVR" or "INS"
      }
    end,
    command = "doc:toggle-overwrite",
    separator = StatusView.separator2
  }
end


---Register default status bar items for command views.
---Shows file count icon.
function StatusView:register_command_items()
  if self:get_item("command:files") then return end

  self:add_item({
    predicate = "core.commandview",
    name = "command:files",
    alignment = StatusView.Item.RIGHT,
    get_item = function()
      return {
        style.icon_font, "g",
        style.font, style.dim, self.separator2
      }
    end
  })
end


---Register default status bar items for image views.
---Shows image filename, dimensions, and zoom level.
function StatusView:register_imageview_items()
  self:add_item({
    predicate = ImageView,
    name = "image-view:details",
    alignment = StatusView.Item.LEFT,
    get_item = function()
      if core.active_view.image then
        local file = common.basename(core.active_view.path)
        local w, h = core.active_view.image:get_size()
        local dimensions = string.format("%dx%d", w, h)
        return {
          style.font, style.accent,
          file,
          style.text,
          StatusView.separator,
          dimensions,
          StatusView.separator,
          string.format("Zoom: %sx", core.active_view.zoom_scale),
        }
      else
        return {}
      end
    end,
    position = 1
  })
end


---Normalize item position handling negative indices and alignment.
---@param self core.statusview
---@param position integer Position (negative for reverse order)
---@param alignment core.statusview.item.alignment
---@return integer position Normalized position index
local function normalize_position(self, position, alignment)
  local offset = 0
  local items_count = 0
  local left = self:get_items_list(1)
  local right = self:get_items_list(2)
  if alignment == 2 then
    items_count = #right
    offset = #left
  else
    items_count = #left
  end
  if position == 0 then
    position = offset +  1
  elseif position < 0 then
    position = offset + items_count + (position + 2)
  else
    position = offset + position
  end
  if position < 1 then
    position = offset + 1
  elseif position > #left + #right then
    position = offset + items_count + 1
  end
  return position
end


---Add a new item to the status bar.
---@param options core.statusview.item.options
---@return core.statusview.item item The created item
function StatusView:add_item(options)
  assert(self:get_item(options.name) == nil, "status item already exists: " .. options.name)
  ---@type core.statusview.item
  local item = StatusView.Item(options)
  table.insert(self.items, normalize_position(self, options.position or -1, options.alignment), item)
  return item
end


---Get a status bar item by name.
---@param name string Unique item name
---@return core.statusview.item|nil item The item or nil if not found
function StatusView:get_item(name)
  for _, item in ipairs(self.items) do
    if item.name == name then return item end
  end
  return nil
end


---Get all items or items filtered by alignment.
---@param alignment? core.statusview.item.alignment Filter by left or right alignment
---@return core.statusview.item[] items List of items
function StatusView:get_items_list(alignment)
  if alignment then
    local items = {}
    for _, item in ipairs(self.items) do
      if item.alignment == alignment then
        table.insert(items, item)
      end
    end
    return items
  end
  return self.items
end


---Move an item to a different position.
---@param name string Item name to move
---@param position integer New position (negative for reverse order)
---@param alignment? core.statusview.item.alignment Optional new alignment
---@return boolean moved True if item was found and moved
function StatusView:move_item(name, position, alignment)
  assert(name, "no name provided")
  assert(position, "no position provided")
  local item = nil
  for pos, it in ipairs(self.items) do
    if it.name == name then
      item = table.remove(self.items, pos)
      break
    end
  end
  if item then
    if alignment then
      item.alignment = alignment
    end
    position = normalize_position(self, position, item.alignment)
    table.insert(self.items, position, item)
    return true
  end
  return false
end


---Remove an item from the status bar.
---@param name string Item name to remove
---@return core.statusview.item|nil removed_item The removed item or nil
function StatusView:remove_item(name)
  local item = nil
  for pos, it in ipairs(self.items) do
    if it.name == name then
      item = table.remove(self.items, pos)
      break
    end
  end
  return item
end


---Reorder items by the given name list.
---Items are placed at the beginning in the order specified.
---@param names table<integer, string> List of item names in desired order
function StatusView:order_items(names)
  local removed_items = {}
  for _, name in ipairs(names) do
    local item = self:remove_item(name)
    if item then table.insert(removed_items, item) end
  end

  for i, item in ipairs(removed_items) do
    table.insert(self.items, i, item)
  end
end


---Hide the status bar.
function StatusView:hide()
  self.visible = false
end


---Show the status bar.
function StatusView:show()
  self.visible = true
end


---Toggle status bar visibility.
function StatusView:toggle()
  self.visible = not self.visible
end


---Hide specific items or all items if no names provided.
---@param names? table<integer, string>|string Single name or list of item names
function StatusView:hide_items(names)
  if type(names) == "string" then
    names = {names}
  end
  if not names then
    for _, item in ipairs(self.items) do
      item:hide()
    end
    return
  end
  for _, name in ipairs(names) do
    local item = self:get_item(name)
    if item then item:hide() end
  end
end


---Show specific items or all items if no names provided.
---@param names? table<integer, string>|string Single name or list of item names
function StatusView:show_items(names)
  if type(names) == "string" then
    names = {names}
  end
  if not names then
    for _, item in ipairs(self.items) do
      item:show()
    end
    return
  end
  for _, name in ipairs(names) do
    local item = self:get_item(name)
    if item then item:show() end
  end
end


---Display a temporary message in the status bar.
---Message duration is controlled by `config.message_timeout`.
---@param icon string Icon character to display
---@param icon_color renderer.color Icon color
---@param text string Message text
function StatusView:show_message(icon, icon_color, text)
  if not self.visible or self.hide_messages then return end
  self.message = {
    icon = icon,
    icon_color = icon_color,
    text = text
  }
  self.message_timeout = system.get_time() + config.message_timeout
end


---Enable or disable system messages on the status bar.
---@param enable boolean True to show messages, false to hide them
function StatusView:display_messages(enable)
  self.hide_messages = not enable
end


---Show a persistent tooltip replacing all status bar content.
---Remains visible until `remove_tooltip()` is called.
---@param text string|core.statusview.styledtext Plain text or styled text array
function StatusView:show_tooltip(text)
  self.tooltip = type(text) == "table" and text or { text }
  self.tooltip_mode = true
end


---Hide the persistent tooltip and restore normal status bar items.
function StatusView:remove_tooltip()
  self.tooltip_mode = false
end


---Process styled text array with a drawing function.
---@param self core.statusview
---@param items core.statusview.styledtext Styled text array
---@param x number Starting x coordinate
---@param y number Starting y coordinate
---@param draw_fn fun(font, color, text, align, x, y, w, h):number Drawing or measurement function
local function draw_items(self, items, x, y, draw_fn)
  local font = style.font
  local color = style.text

  for _, item in ipairs(items) do
    if Object.is(item, renderer.font) then
      font = item
    elseif type(item) == "table" then
      color = item
    else
      x = draw_fn(font, color, item, nil, x, y, 0, self.size.y)
    end
  end

  return x
end


---Calculate text width (used as callback for draw_items).
---@param font renderer.font
---@param _ any Unused color parameter
---@param text string Text to measure
---@param _ any Unused align parameter
---@param x number Current x position
---@return number x Updated x position
local function text_width(font, _, text, _, x)
  return x + font:get_width(text)
end


---Draw styled text on the status bar with optional alignment.
---@param items core.statusview.styledtext Styled text to render
---@param right_align? boolean True to right-align, false for left-align
---@param xoffset? number Horizontal offset in pixels
---@param yoffset? number Vertical offset in pixels
function StatusView:draw_items(items, right_align, xoffset, yoffset)
  local x, y = self:get_content_offset()
  x = x + (xoffset or 0)
  y = y + (yoffset or 0)
  if right_align then
    local w = draw_items(self, items, 0, 0, text_width)
    x = x + self.size.x - w - style.padding.x
    draw_items(self, items, x, y, common.draw_text)
  else
    x = x + style.padding.x
    draw_items(self, items, x, y, common.draw_text)
  end
end


---Draw a tooltip box above the status bar for an item.
---@param item core.statusview.item Item with tooltip text
function StatusView:draw_item_tooltip(item)
  core.root_view:defer_draw(function()
    local text = item.tooltip
    local w = style.font:get_width(text)
    local h = style.font:get_height()
    local x = self.pointer.x - (w / 2) - (style.padding.x * 2)

    if x < 0 then x = 0 end
    if (x + w + (style.padding.x * 3)) > self.size.x then
      x = self.size.x - w - (style.padding.x * 3)
    end

    renderer.draw_rect(
      x + style.padding.x,
      self.position.y - h - (style.padding.y * 2),
      w + (style.padding.x * 2),
      h + (style.padding.y * 2),
      style.background3
    )

    renderer.draw_text(
      style.font,
      text,
      -- we round the coords to prevent jumpy text on fractional scales
      common.round(x + (style.padding.x * 2)),
      common.round(self.position.y - h - style.padding.y),
      style.text
    )
  end)
end


---Legacy method for retrieving status bar items.
---@deprecated Use `core.status_view:add_item()` instead
---@param nowarn boolean Suppress deprecation warning if true
---@return table left Left-aligned items
---@return table right Right-aligned items
function StatusView:get_items(nowarn)
  if not nowarn and not self.get_items_warn then
    core.warn(
      "Overriding StatusView:get_items() is deprecated, "
      .. "use core.status_view:add_item() instead."
    )
    self.get_items_warn = true
  end
  return {"{:dummy:}"}, {"{:dummy:}"}
end


---Append all elements from one styled text array to another.
---@param t1 core.statusview.styledtext Destination array
---@param t2 core.statusview.styledtext Source array to append
local function table_add(t1, t2)
  for _, value in ipairs(t2) do
    table.insert(t1, value)
  end
end


---Merge legacy get_items() results into the item list for backwards compatibility.
---@param destination table Item list to merge into
---@param items core.statusview.styledtext Legacy styled text items
---@param alignment core.statusview.item.alignment Item alignment
local function merge_deprecated_items(destination, items, alignment)
  local start = true
  local items_start, items_end = {}, {}
  for i, value in ipairs(items) do
    if value ~= "{:dummy:}" then
      if start then
        table.insert(items_start, i, value)
      else
        table.insert(items_end, value)
      end
    else
      start = false
    end
  end

  local position = alignment == StatusView.Item.LEFT and "left" or "right"

  local item_start = StatusView.Item({
    name = "deprecated:"..position.."-start",
    alignment = alignment,
    get_item = items_start
  })

  local item_end = StatusView.Item({
    name = "deprecated:"..position.."-end",
    alignment = alignment,
    get_item = items_end
  })

  table.insert(destination, 1, item_start)
  table.insert(destination, item_end)
end


---Create and insert a separator item between status bar items.
---@param self core.statusview
---@param destination core.statusview.item[] Active items list
---@param separator string Separator text (space or pipe)
---@param alignment core.statusview.item.alignment Item alignment
---@param x number X position for the separator
---@return core.statusview.item separator The created separator item
local function add_spacing(self, destination, separator, alignment, x)
  ---@type core.statusview.item
  local space = StatusView.Item({name = "space", alignment = alignment})
  space.cached_item = separator == self.separator and {
    style.text, separator
  } or {
    style.dim, separator
  }
  space.x = x
  space.w = draw_items(self, space.cached_item, 0, 0, text_width)

  table.insert(destination, space)

  return space
end


---Strip leading and trailing separators from styled text.
---@param self core.statusview
---@param styled_text core.statusview.styledtext Styled text to modify in-place
local function remove_spacing(self, styled_text)
  if
    not Object.is(styled_text[1], renderer.font)
    and
    type(styled_text[1]) == "table"
    and
    (
      styled_text[2] == self.separator
      or
      styled_text[2] == self.separator2
    )
  then
    table.remove(styled_text, 1)
    table.remove(styled_text, 1)
  end

  if
    not Object.is(styled_text[#styled_text-1], renderer.font)
    and
    type(styled_text[#styled_text-1]) == "table"
    and
    (
      styled_text[#styled_text] == self.separator
      or
      styled_text[#styled_text] == self.separator2
    )
  then
    table.remove(styled_text, #styled_text)
    table.remove(styled_text, #styled_text)
  end
end


---Rebuild the active items list by evaluating predicates and calculating positions.
---Updates item visibility, positions, and handles panel overflow.
function StatusView:update_active_items()
  local x = self:get_content_offset()

  local rx = x + self.size.x
  local lx = x
  local rw, lw = 0, 0

  self.active_items = {}

  ---@type core.statusview.item[]
  local combined_items = {}
  table_add(combined_items, self.items)

  -- load deprecated items for compatibility
  local dleft, dright = self:get_items(true)
  merge_deprecated_items(combined_items, dleft, StatusView.Item.LEFT)
  merge_deprecated_items(combined_items, dright, StatusView.Item.RIGHT)

  local lfirst, rfirst = true, true

  -- calculate left and right width
  for _, item in ipairs(combined_items) do
    item.cached_item = {}
    if item.visible and item:predicate() then
      local styled_text = type(item.get_item) == "function"
        and item.get_item(item) or item.get_item

      if #styled_text > 0 then
        remove_spacing(self, styled_text)
      end

      if #styled_text > 0 or item.on_draw then
        item.active = true
        local hovered = self.hovered_item == item
        if item.alignment == StatusView.Item.LEFT then
          if not lfirst then
            local space = add_spacing(
              self, self.active_items, item.separator, item.alignment, lx
            )
            lw = lw + space.w
            lx = lx + space.w
          else
            lfirst = false
          end
          item.w = item.on_draw and
            item.on_draw(lx, self.position.y, self.size.y, hovered, true)
            or
            draw_items(self, styled_text, 0, 0, text_width)
          item.x = lx
          lw = lw + item.w
          lx = lx + item.w
        else
          if not rfirst then
            local space = add_spacing(
              self, self.active_items, item.separator, item.alignment, rx
            )
            rw = rw + space.w
            rx = rx + space.w
          else
            rfirst = false
          end
          item.w = item.on_draw and
            item.on_draw(rx, self.position.y, self.size.y, hovered, true)
            or
            draw_items(self, styled_text, 0, 0, text_width)
          item.x = rx
          rw = rw + item.w
          rx = rx + item.w
        end
        item.cached_item = styled_text
        table.insert(self.active_items, item)
      else
        item.active = false
      end
    else
      item.active = false
    end
  end

  self.r_left_width, self.r_right_width = lw, rw

  -- try to calc best size for left and right
  if lw + rw + (style.padding.x * 4) > self.size.x then
    if lw + (style.padding.x * 2) < self.size.x / 2 then
      rw = self.size.x - lw  - (style.padding.x * 3)
      if rw > self.r_right_width then
        lw = lw + (rw - self.r_right_width)
        rw = self.r_right_width
      end
    elseif rw + (style.padding.x * 2) < self.size.x / 2 then
      lw = self.size.x - rw  - (style.padding.x * 3)
    else
      lw = self.size.x / 2 - (style.padding.x + style.padding.x / 2)
      rw = self.size.x / 2 - (style.padding.x + style.padding.x / 2)
    end
    -- reposition left and right offsets when window is resized
    if rw >= self.r_right_width then
      self.right_xoffset = 0
    elseif rw > self.right_xoffset + self.r_right_width then
      self.right_xoffset = rw - self.r_right_width
    end
    if lw >= self.r_left_width then
      self.left_xoffset = 0
    elseif lw > self.left_xoffset + self.r_left_width then
      self.left_xoffset = lw - self.r_left_width
    end
  else
    self.left_xoffset = 0
    self.right_xoffset = 0
  end

  self.left_width, self.right_width = lw, rw

  for _, item in ipairs(self.active_items) do
    if item.alignment == StatusView.Item.RIGHT then
      -- re-calculate x position now that we have the total width
      item.x = item.x - rw - (style.padding.x * 2)
    end
  end
end


---Pan a status bar panel horizontally when content overflows.
---@param panel core.statusview.position Panel to drag ("left" or "right")
---@param dx number Horizontal drag distance in pixels
function StatusView:drag_panel(panel, dx)
  if panel == "left" and self.r_left_width > self.left_width then
    local nonvisible_w = self.r_left_width - self.left_width
    local new_offset = self.left_xoffset + dx
    if new_offset >= 0 - nonvisible_w and new_offset <= 0 then
      self.left_xoffset = new_offset
    elseif dx < 0 then
      self.left_xoffset = 0 - nonvisible_w
    else
      self.left_xoffset = 0
    end
  elseif panel == "right" and self.r_right_width > self.right_width then
    local nonvisible_w = self.r_right_width - self.right_width
    local new_offset = self.right_xoffset + dx
    if new_offset >= 0 - nonvisible_w and new_offset <= 0 then
      self.right_xoffset = new_offset
    elseif dx < 0 then
      self.right_xoffset = 0 - nonvisible_w
    else
      self.right_xoffset = 0
    end
  end
end


---Determine which panel (left or right) is under the cursor.
---@param x number Mouse x coordinate
---@param y number Mouse y coordinate
---@return string panel "left", "right", or "" if none
function StatusView:get_hovered_panel(x, y)
  if y >= self.position.y and x <= self.left_width + style.padding.x then
    return "left"
  end
  return "right"
end


---Calculate the visible portion of an item considering panel overflow.
---@param item core.statusview.item Item to check
---@return number x Visible x coordinate (0 if fully clipped)
---@return number w Visible width (0 if fully clipped)
function StatusView:get_item_visible_area(item)
  local item_ox = item.alignment == StatusView.Item.LEFT and
    self.left_xoffset or self.right_xoffset

  local item_x = item_ox + item.x + style.padding.x
  local item_w = item.w

  if item.alignment == StatusView.Item.LEFT then
    if self.left_width - item_x > 0 and self.left_width - item_x < item.w then
      item_w = (self.left_width + style.padding.x) - item_x
    elseif self.left_width - item_x < 0 then
      item_x = 0
      item_w = 0
    end
  else
    local rx = self.size.x - self.right_width - style.padding.x
    if item_x < rx then
      if item_x + item.w > rx then
        item_x = rx
        item_w = (item_x + item.w) - rx
      else
        item_x = 0
        item_w = 0
      end
    end
  end

  return item_x, item_w
end



---Handle mouse button press events.
---Clicking on active message opens log view. Left-click enables panel dragging when content overflows.
---@param button string Mouse button identifier
---@param x number Mouse x coordinate
---@param y number Mouse y coordinate
---@param clicks number Number of clicks
---@return boolean
function StatusView:on_mouse_pressed(button, x, y, clicks)
  if not self.visible then return end
  core.set_active_view(core.last_active_view)
  if
    system.get_time() < self.message_timeout
    and
    not core.active_view:is(LogView)
  then
    command.perform "core:open-log"
  else
    if y >= self.position.y and button == "left" and clicks == 1 then
      self.position.dx = x
      if
        self.r_left_width > self.left_width
        or
        self.r_right_width > self.right_width
      then
        self.dragged_panel = self:get_hovered_panel(x, y)
        self.cursor = "hand"
      end
    end
  end
  return true
end


---Handle mouse leaving the status bar area.
function StatusView:on_mouse_left()
  StatusView.super.on_mouse_left(self)
  self.hovered_item = {}
end


---Handle mouse movement over the status bar.
---Updates hovered item, cursor, and handles panel dragging.
---@param x number Mouse x coordinate
---@param y number Mouse y coordinate
---@param dx number Delta x movement
---@param dy number Delta y movement
function StatusView:on_mouse_moved(x, y, dx, dy)
  if not self.visible then return end
  StatusView.super.on_mouse_moved(self, x, y, dx, dy)

  self.hovered_panel = self:get_hovered_panel(x, y)

  if self.dragged_panel ~= "" then
    self:drag_panel(self.dragged_panel, dx)
    return
  end

  if y < self.position.y or self.message then
    self.cursor = "arrow"
    self.hovered_item = {}
    return
  end

  for _, item in ipairs(self.items) do
    if
      item.visible and item.active
      and
      (item.command or item.on_click or item.tooltip ~= "")
    then
      local item_x, item_w = self:get_item_visible_area(item)

      if x > item_x and (item_x + item_w) > x then
        self.pointer.x = x
        self.pointer.y = y
        if self.hovered_item ~= item then
          self.hovered_item = item
        end
        if item.command or item.on_click then
          self.cursor = "hand"
        end
        return
      end
    end
  end
  self.cursor = "arrow"
  self.hovered_item = {}
end


---Handle mouse button release events.
---Executes item command or callback if clicked on an item.
---@param button string Mouse button identifier
---@param x number Mouse x coordinate
---@param y number Mouse y coordinate
function StatusView:on_mouse_released(button, x, y)
  if not self.visible then return end
  StatusView.super.on_mouse_released(self, button, x, y)

  if self.dragged_panel ~= "" then
    self.dragged_panel = ""
    self.cursor = "arrow"
    if self.position.dx ~= x then
      return
    end
  end

  if y < self.position.y or not self.hovered_item.active then return end

  local item = self.hovered_item
  local item_x, item_w = self:get_item_visible_area(item)

  if x > item_x and (item_x + item_w) > x then
    if item.command then
      command.perform(item.command)
    elseif item.on_click then
      item.on_click(button, x, y)
    end
  end
end


---Handle mouse wheel scrolling to pan overflowing panels.
---@param y number Vertical scroll amount
---@param x number Horizontal scroll amount
function StatusView:on_mouse_wheel(y, x)
  if not self.visible or self.hovered_panel == "" then return end
  if x ~= 0 then
    self:drag_panel(self.hovered_panel, x * self.left_width / 10)
  else
    self:drag_panel(self.hovered_panel, y * self.left_width / 10)
  end
end


---Update status bar height, message scroll, and active items.
function StatusView:update()
  if not self.visible and self.size.y <= 0 then
    return
  elseif not self.visible and self.size.y > 0 then
    self:move_towards(self.size, "y", 0, nil, "statusbar")
    return
  end

  local height = style.font:get_height() + style.padding.y * 2;

  if self.size.y + 1 < height then
    self:move_towards(self.size, "y", height, nil, "statusbar")
  else
    self.size.y = height
  end

  if self.message and system.get_time() < self.message_timeout then
    self.scroll.to.y = self.size.y
  else
    self.scroll.to.y = 0
  end

  StatusView.super.update(self)

  self:update_active_items()
end


---Get item hover state and background color.
---@param self core.statusview
---@param item core.statusview.item Item to check
---@return boolean is_hovered True if item is currently hovered
---@return renderer.color|nil color Background color to use (nil if none)
local function get_item_bg_color(self, item)
  local hovered = self.hovered_item == item

  local item_bg = hovered
    and item.background_color_hover or item.background_color

  return hovered, item_bg
end


---Format the current status message as styled text.
---@param self core.statusview
---@return core.statusview.styledtext message Styled message with icon and text
local function get_rendered_message(self)
  return {
    self.message.icon_color, style.icon_font, self.message.icon,
    style.dim, style.font, StatusView.separator2, style.text, self.message.text
  }
end


---Render the status bar with all active items, messages, and tooltips.
function StatusView:draw()
  if not self.visible and self.size.y <= 0 then return end

  self:draw_background(style.background2)

  if self.message and system.get_time() <= self.message_timeout then
    self:draw_items(get_rendered_message(self), false, 0, self.size.y)
  else
    if self.message then self.message = nil end
    if self.tooltip_mode then
      self:draw_items(self.tooltip)
    end
    if #self.active_items > 0 then
      --- draw left pane
      core.push_clip_rect(
        0, self.position.y,
        self.left_width + style.padding.x, self.size.y
      )
      for _, item in ipairs(self.active_items) do
        local item_x = self.left_xoffset + item.x + style.padding.x
        local hovered, item_bg = get_item_bg_color(self, item)
        if item.alignment == StatusView.Item.LEFT and not self.tooltip_mode then
          if type(item_bg) == "table" then
            renderer.draw_rect(
              item_x, self.position.y,
              item.w, self.size.y, item_bg
            )
          end
          if item.on_draw then
            core.push_clip_rect(item_x, self.position.y, item.w, self.size.y)
            item.on_draw(item_x, self.position.y, self.size.y, hovered)
            core.pop_clip_rect()
          else
            self:draw_items(item.cached_item, false, item_x - style.padding.x)
          end
        end
      end
      core.pop_clip_rect()

      --- draw right pane
      core.push_clip_rect(
        self.size.x - (self.right_width + style.padding.x), self.position.y,
        self.right_width + style.padding.x, self.size.y
      )
      for _, item in ipairs(self.active_items) do
        local item_x = self.right_xoffset + item.x + style.padding.x
        local hovered, item_bg = get_item_bg_color(self, item)
        if item.alignment == StatusView.Item.RIGHT then
          if type(item_bg) == "table" then
            renderer.draw_rect(
              item_x, self.position.y,
              item.w, self.size.y, item_bg
            )
          end
          if item.on_draw then
            core.push_clip_rect(item_x, self.position.y, item.w, self.size.y)
            item.on_draw(item_x, self.position.y, self.size.y, hovered)
            core.pop_clip_rect()
          else
            self:draw_items(item.cached_item, false, item_x - style.padding.x)
          end
        end
      end
      core.pop_clip_rect()

      -- draw tooltip
      if self.hovered_item.tooltip ~= "" and self.hovered_item.active then
        self:draw_item_tooltip(self.hovered_item)
      end
    end
  end

  if clicks > 5 then
    if config.stonks == nil then clicks = -1 end
    core.root_view:defer_draw(function()
      local font = type(config.stonks) == "table" and config.stonks.font or style.icon_font
      local icon = type(config.stonks) == "table" and config.stonks.icon or ( config.stonks and "g" or "h" )
      local xadv = renderer.draw_text(font, icon, gx, gy, gc)
      local x2, y2 = core.root_view.size.x - (xadv - gx), core.root_view.size.y - font:get_height()
      gx, gy = common.clamp(gx + dx, 0, x2), common.clamp(gy + dy, 0, y2)
      local odx, ody = dx, dy
      if gx <= 0 then dx = math.abs(dx) elseif gx >= x2 then dx = -math.abs(dx) end
      if gy <= 0 then dy = math.abs(dy) elseif gy >= y2 then dy = -math.abs(dy) end
      if odx ~= dx or ody ~= dy then
        local major = math.random(1, 3)
        for i = 1, 3 do gc[i] = major == i and math.random(200, 255) or math.random(0, 100) end
      end
      core.redraw = true
    end)
  end
end

return StatusView
