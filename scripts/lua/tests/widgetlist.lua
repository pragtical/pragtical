local core = require "core"
local test = require "core.test"
local config = require "core.config"
local style = require "core.style"
local Widget = require "widget"
local WidgetList = require "widget.widgetlist"
local Label = require "widget.label"
local Toggle = require "widget.toggle"
local Button = require "widget.button"

local function make_list(context, count, builder)
  local root = Widget(nil, false)
  root.border.width = 0
  root:show()
  root:set_position(40, 60)
  root:set_size(600, 400)
  context.roots[#context.roots + 1] = root
  local list = WidgetList(root)
  list:set_position(10, 20)
  list:set_size(320, 100)
  for index = 1, count do
    list:add_item(index, builder or function(row)
      local label = Label(row, "Plugin " .. index)
      row:set_child_properties(label, { stretch = 1 })
      row.toggle = Toggle(row, "", true)
    end, "plugin " .. index)
  end
  for _ = 1, 4 do root:update() end
  return list, root
end

local function check_gutter(list)
  local x, _, width = list.v_scrollbar:get_track_rect()
  test.ok(width > 0)
  for _, entry in ipairs(list.items) do
    if entry.row.visible then
      local toggle = entry.row.toggle
      local right = toggle.position.x + toggle:get_width()
      test.ok(right < x)
      local y = toggle.position.y + toggle:get_height() / 2
      test.is_nil(list.v_scrollbar:overlaps(right - 1, y))
    end
  end
end

test.describe("WidgetList layout", function()
  test.before_each(function(context)
    context.roots = {}
    context.transitions = config.transitions
    context.grab = core.root_view.grab
    context.active_view = core.active_view
    context.last_active_view = core.last_active_view
    context.next_active_view = core.next_active_view
    context.clip_rect_stack = core.clip_rect_stack
    context.scale = SCALE
    context.style = {}
    for _, name in ipairs {
      "padding", "font", "scrollbar_size", "expanded_scrollbar_size",
      "contracted_scrollbar_margin", "expanded_scrollbar_margin"
    } do
      context.style[name] = style[name]
    end
    config.transitions = false
    core.root_view.grab = nil
  end)

  test.after_each(function(context)
    for _, root in ipairs(context.roots) do root:destroy() end
    SCALE = context.scale
    for name, value in pairs(context.style) do style[name] = value end
    config.transitions = context.transitions
    core.root_view.grab = context.grab
    core.active_view = context.active_view
    core.last_active_view = context.last_active_view
    core.next_active_view = context.next_active_view
    core.clip_rect_stack = context.clip_rect_stack
  end)

  for _, status in ipairs { "automatic", "expanded", "contracted" } do
    test.it("keeps controls clear of " .. status .. " scrollbars", function(context)
      local list, root = make_list(context, 12)
      list.v_scrollbar:set_forced_status(status ~= "automatic" and status or false)
      root:update()
      local row = list.items[1].row
      local width, toggle_x = row:get_width(), row.toggle.position.x
      check_gutter(list)
      local x, y, w, h = list.v_scrollbar:get_track_rect()
      list.v_scrollbar:on_mouse_moved(x + w / 2, y + h / 2, 0, 0)
      root:update()
      check_gutter(list)
      test.equal(row:get_width(), width)
      test.equal(row.toggle.position.x, toggle_x)

      local changes = 0
      row.toggle.on_change = function() changes = changes + 1 end
      x = row.toggle.position.x + row.toggle:get_width() - 1
      y = row.toggle.position.y + row.toggle:get_height() / 2
      root:on_mouse_pressed("left", x, y, 1)
      root:on_mouse_released("left", x, y)
      test.equal(changes, 1)
      test.equal(row.toggle.enabled, false)
      test.not_ok(list.v_scrollbar.dragging)
    end)
  end

  for _, alignment in ipairs { "s", "e" } do
    for _, status in ipairs { "contracted", "expanded" } do
      test.it("highlights the gutter beside a " .. status .. " " .. alignment
        .. " scrollbar", function(context)
        local list, root = make_list(context, 12)
        list.v_scrollbar.alignment = alignment
        list.v_scrollbar:set_forced_status(status)
        root:update()
        local row = list.items[1].row
        row.hovered = true
        local gutter_x = alignment == "s" and row.position.x - 1
          or row.position.x + row.size.x
        local window = renwindow.create("WidgetList highlight", 640, 480)
        core.clip_rect_stack = { { 0, 0, 640, 480 } }
        renderer.begin_frame(window)
        renderer.set_clip_rect(0, 0, 640, 480)
        root:draw()
        renderer.end_frame()
        local capture = renderer.to_canvas(window, 0, 0, 640, 480)
        local function pixel(x, y)
          return { capture:get_pixels(math.floor(x), math.floor(y), 1, 1):byte(1, 3) }
        end
        local function rgb(color) return { color[1], color[2], color[3] } end
        test.same(pixel(gutter_x, row.position.y + row.size.y / 2),
          rgb(style.line_highlight))
        local x, y, w, h = list.v_scrollbar:get_thumb_rect()
        test.same(pixel(x + w / 2, y + h / 2), rgb(style.scrollbar))
        test.same(pixel(list.position.x + list.size.x + 2, row.position.y + 5),
          rgb(style.background2))
        test.is_nil(list.v_scrollbar:overlaps(
          row.toggle.position.x + row.toggle:get_width() - 1,
          row.toggle.position.y + row.toggle:get_height() / 2
        ))
      end)
    end
  end

  test.it("uses the full width when content fits or is filtered out", function(context)
    local list, root = make_list(context, 12)
    test.ok(list.items[1].row:get_width() < list.size.x)
    list:filter(function(_, index) return index == 1 end)
    root:update()
    test.equal(list.items[1].row:get_width(), list.size.x)
    test.equal(select(3, list.v_scrollbar:get_track_rect()), 0)
    list:filter(function() return false end)
    root:update()
    test.equal(list:get_scrollable_size(), list.size.y)
    for _, entry in ipairs(list.items) do test.not_ok(entry.row.visible) end
    list:filter()
    root:update()
    check_gutter(list)
    list:clear()
    root:update()
    test.equal(list:get_scrollable_size(), list.size.y)
  end)

  test.it("recalculates the gutter when only the viewport height changes", function(context)
    local list, root = make_list(context, 2)
    local full_width = list.size.x
    test.equal(list.items[1].row:get_width(), full_width)
    list:set_size(nil, 20)
    root:update()
    test.ok(list.items[1].row:get_width() < full_width)
    check_gutter(list)
    list:set_size(nil, 200)
    root:update()
    test.equal(list.items[1].row:get_width(), full_width)
  end)

  test.it("fits exactly the requested number of rows without a scrollbar", function(context)
    local list, root = make_list(context, 2)
    list:set_visible_row_count(2)
    root:update()
    test.equal(list.content_height, list.size.y)
    test.equal(list.items[1].row:get_width(), list.size.x)
    test.equal(select(3, list.v_scrollbar:get_track_rect()), 0)
  end)

  test.it("honors scrollbar overrides and changes in style dimensions", function(context)
    local list, root = make_list(context, 12)
    list.v_scrollbar.expanded_size = 30
    list.v_scrollbar.expanded_margin = 20
    list.v_scrollbar.contracted_size = 40
    list.v_scrollbar.contracted_margin = 15
    root:update()
    test.equal(list.items[1].row:get_width(), list.size.x - 40 - SCALE)
    list.v_scrollbar.expanded_size = nil
    list.v_scrollbar.expanded_margin = nil
    list.v_scrollbar.contracted_size = nil
    list.v_scrollbar.contracted_margin = nil
    style.expanded_scrollbar_size = 32
    style.expanded_scrollbar_margin = 18
    root:update()
    test.equal(list.items[1].row:get_width(), list.size.x - 32 - SCALE)
    list:set_size(450)
    root:update()
    test.equal(list.items[1].row:get_width(), list.size.x - 32 - SCALE)
  end)

  test.it("reserves a gutter on the scrollbar's alignment side", function(context)
    local list, root = make_list(context, 12)
    list.v_scrollbar.alignment = "s"
    list.v_scrollbar:set_forced_status("expanded")
    root:update()
    local x, _, w = list.v_scrollbar:get_track_rect()
    local row = list.items[1].row
    test.equal(row.position.x, x + w + SCALE)
    test.is_nil(list.v_scrollbar:overlaps(row.position.x + 1, row.position.y + 10))
    test.equal(row.position.x + row:get_width(), list.position.x + list.size.x)
  end)

  test.it("measures mixed controls and keeps them inside the row clip", function(context)
    local list, root = make_list(context, 12, function(row)
      row.label = Label(row, "Plugin")
      row:set_child_properties(row.label, { stretch = 1 })
      row.button = Button(row, "Action")
      row.toggle = Toggle(row, "", true)
    end)
    local row = list.items[1].row
    test.ok(row.label.position.x + row.label:get_width() < row.button.position.x)
    test.ok(row.button.position.x + row.button:get_width() < row.toggle.position.x)
    check_gutter(list)
    list:set_size(40)
    root:update()
    test.ok(row:get_width() >= 0)
    test.equal(row.label:get_width(), 0)

    local push = core.push_clip_rect
    local clipped = false
    core.push_clip_rect = function(x, y, w, h)
      if x == row.position.x and y == row.position.y and w == row.size.x
        and h == row.size.y then clipped = true end
      return push(x, y, w, h)
    end
    local ok, err = pcall(function()
      renderer.begin_frame(core.window)
      root:draw()
      renderer.end_frame()
    end)
    core.push_clip_rect = push
    assert(ok, err)
    test.ok(clipped)
  end)

  test.it("refreshes offsets and visible-row height when a control grows", function(context)
    local list, root = make_list(context, 3, function(row)
      row.control = Widget(row)
      row.control.border.width = 0
      row.control:set_size(40, 20)
    end)
    list:set_visible_row_count(2)
    root:update()
    local first = list.items[1].row
    local height = first:get_height()
    first.control:set_size(nil, 45)
    root:update()
    test.equal(first:get_height(), height + 25)
    test.equal(list.items[2].y, first:get_height())
    test.equal(list.size.y, first:get_height() + list.items[2].row:get_height())
    test.equal(list.content_height, list.size.y + list.items[3].row:get_height())
  end)

  test.it("reserves the gutter after measuring width-dependent heights", function(context)
    local Responsive = Widget:extend()
    function Responsive:set_size(width, height)
      Responsive.super.set_size(self, width, height)
      if width then self.size.y = width < 200 and 60 or 20 end
    end
    local list, root = make_list(context, 3, function(row)
      local child = Responsive(row)
      child.border.width = 0
      row:set_child_properties(child, { stretch = 1 })
    end)
    test.equal(list.items[1].row:get_width(), list.size.x)
    list:set_size(210)
    root:update()
    test.ok(list.content_height > list.size.y)
    test.equal(list.items[2].y, list.items[1].row:get_height())
    test.ok(list.items[1].row:get_width() < list.size.x)
  end)

  test.it("updates scaled offscreen geometry without disabling virtualization", function(context)
    local list, root = make_list(context, 60)
    local offscreen = list.items[#list.items].row
    test.not_ok(offscreen.visible)
    local updates = 0
    local update = offscreen.toggle.update
    offscreen.toggle.update = function(self)
      updates = updates + 1
      return update(self)
    end
    root:update()
    test.equal(updates, 0)

    local factor = 1.5
    SCALE = SCALE * factor
    style.font = style.font:copy(style.font:get_size() * factor)
    style.padding = { x = style.padding.x * factor, y = style.padding.y * factor }
    for _, name in ipairs {
      "scrollbar_size", "expanded_scrollbar_size",
      "contracted_scrollbar_margin", "expanded_scrollbar_margin"
    } do style[name] = style[name] * factor end
    root:update()
    test.equal(list.items[1].row:get_width(), list.size.x
      - style.expanded_scrollbar_size - SCALE)
    test.equal(offscreen:get_width(), list.items[1].row:get_width())
    local scaled_updates = updates
    root:update()
    test.equal(updates, scaled_updates)
    list.scroll.y = list.content_height - list.size.y
    list.scroll.to.y = list.scroll.y
    root:update()
    test.ok(offscreen.visible)
    test.ok(updates > scaled_updates)
    check_gutter(list)
  end)

  test.it("keeps oversized click margins within a compact scrollbar gutter", function(context)
    local list, root = make_list(context, 12)
    list.v_scrollbar.contracted_margin = 100
    list.v_scrollbar.expanded_margin = 100
    root:update()
    local row = list.items[1].row
    test.equal(row:get_width(), list.size.x - style.expanded_scrollbar_size - SCALE)
    local edge = row.position.x + row:get_width()
    local y = row.toggle.position.y + row.toggle:get_height() / 2
    test.is_nil(list.v_scrollbar:overlaps(edge - 1, y))
    test.not_nil(list.v_scrollbar:overlaps(edge + 1, y))
    list.v_scrollbar:on_mouse_moved(edge + 1, y, 0, 0)
    root:update()
    test.equal(list.v_scrollbar.expand_percent, 1)
    test.equal(row.position.x + row:get_width(), edge)
    test.is_nil(list.v_scrollbar:overlaps(edge - 1, y))
    test.not_nil(list.v_scrollbar:overlaps(edge + 1, y))
    check_gutter(list)
  end)
end)
