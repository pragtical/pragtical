local core = require "core"
local test = require "core.test"
local Widget = require "widget"
local Button = require "widget.button"
local TextBox = require "widget.textbox"
local ColorPicker = require "widget.colorpicker"
local NumberBox = require "widget.numberbox"
local SelectBox = require "widget.selectbox"
local ListBox = require "widget.listbox"
local TreeList = require "widget.treelist"
local config = require "core.config"
local command = require "core.command"
local RootView = require "core.rootview"
local Label = require "widget.label"
local NoteBook = require "widget.notebook"
local Container = require "widget.container"
local style = require "core.style"
local EmptyView = require "core.emptyview"
local Dialog = require "widget.dialog"

local function root_widget(context, floating)
  local root = Widget(nil, floating or false)
  root:show()
  root:set_position(40, 60)
  root:set_size(600, 400)
  context.roots[#context.roots + 1] = root
  return root
end

local function child_widget(parent, x)
  local child = Widget(parent)
  child:set_position(x or 20, 20)
  child:set_size(100, 60)
  return child
end

local function draw(root)
  renderer.begin_frame(core.window)
  root:draw()
  renderer.end_frame()
end

test.describe("widget mouse events", function()
  test.before_each(function(context)
    context.active_view = core.active_view
    context.last_active_view = core.last_active_view
    context.next_active_view = core.next_active_view
    context.grab = core.root_view.grab
    context.transitions = config.transitions
    config.transitions = false
    core.root_view.grab = nil
    context.roots = {}
  end)

  test.after_each(function(context)
    for _, root in ipairs(context.roots) do root:destroy() end
    config.transitions = context.transitions
    core.root_view.grab = context.grab
    core.active_view = context.active_view
    core.last_active_view = context.last_active_view
    core.next_active_view = context.next_active_view
  end)

  for _, nested in ipairs { false, true } do
    test.test("motion reaches an active hovered input once" .. (nested and " through a container" or ""), function(context)
      local root = root_widget(context)
      local parent = nested and child_widget(root) or root
      if nested then parent:set_size(300, 180) end
      local input = TextBox(parent, "text")
      input:set_position(10, 10)
      root:update()
      root:swap_active_child(input)
      local calls = 0
      local moved = input.on_mouse_moved
      input.on_mouse_moved = function(self, ...)
        calls = calls + 1
        return moved(self, ...)
      end
      root:on_mouse_moved(input.position.x + 20, input.position.y + 10, 0, 0)
      test.equal(calls, 1)
    end)
  end

  test.test("leave reaches nested controls once when switching containers or leaving the view", function(context)
    local root = root_widget(context)
    local first_container = child_widget(root)
    first_container:set_size(250, 180)
    local second_container = child_widget(root, 320)
    second_container:set_size(250, 180)
    local buttons = { Button(first_container, "First"), Button(second_container, "Second") }
    local leaves = { 0, 0 }
    for index, button in ipairs(buttons) do
      button:set_position(10, 10)
      button.on_mouse_leave = function(self, ...)
        leaves[index] = leaves[index] + 1
        Button.on_mouse_leave(self, ...)
      end
    end
    root:update()
    root:on_mouse_moved(buttons[1].position.x + 5, buttons[1].position.y + 5, 0, 0)
    test.ok(buttons[1].mouse_is_hovering)
    root:on_mouse_moved(buttons[2].position.x + 5, buttons[2].position.y + 5, 0, 0)
    test.equal(leaves[1], 1)
    test.not_ok(buttons[1].mouse_is_hovering)
    test.ok(buttons[2].mouse_is_hovering)
    root:on_mouse_left()
    test.equal(leaves[1], 1)
    test.equal(leaves[2], 1)
    test.not_ok(buttons[2].mouse_is_hovering)
    root:on_mouse_left()
    test.equal(leaves[2], 1)
  end)

  test.test("a pressed nested button leaves once across an outside release", function(context)
    local root = root_widget(context, true)
    local container = child_widget(root)
    container:set_size(250, 180)
    local button = Button(container, "Click")
    local leaves = 0
    button.on_mouse_leave = function(self, ...)
      leaves = leaves + 1
      Button.on_mouse_leave(self, ...)
    end
    root:update()
    local x, y = button.position.x + 5, button.position.y + 5
    core.on_event("mousemoved", x, y, 0, 0)
    core.on_event("mousepressed", "left", x, y, 1)
    core.on_event("mousemoved", 900, 700, 0, 0)
    test.equal(leaves, 1)
    core.on_event("mousereleased", "left", 900, 700)
    test.equal(leaves, 1)
    test.not_ok(button.mouse_is_hovering)
    test.is_nil(core.root_view.grab)
  end)

  test.test("release goes to the pressed button outside its bounds and clears the chain", function(context)
    local root = root_widget(context)
    local container = child_widget(root)
    container:set_size(400, 180)
    local first, second = Button(container, "First"), Button(container, "Second")
    first:set_position(20, 20)
    second:set_position(160, 20)
    root:update()
    local first_clicks, second_clicks = 0, 0
    first.on_click = function() first_clicks = first_clicks + 1 end
    second.on_click = function() second_clicks = second_clicks + 1 end
    local x, y = first.position.x + 5, first.position.y + 5
    root:on_mouse_pressed("left", x, y, 1)
    test.not_ok(root:on_mouse_released("right", x, y))
    test.ok(first.mouse_is_pressed)
    x = second.position.x + 5
    root:on_mouse_released("left", x, y)
    test.equal(first_clicks, 0)
    test.equal(second_clicks, 0)
    for _, widget in ipairs { root, container, first, second } do
      test.not_ok(widget.mouse_is_pressed)
      test.is_nil(widget.mouse_press)
    end
    root:on_mouse_pressed("left", x, y, 1)
    root:on_mouse_released("left", x, y)
    test.equal(second_clicks, 1)
  end)

  test.test("capture takes priority over floating hover targets and ignores other releases", function(context)
    local root = root_widget(context)
    local owner = child_widget(root)
    local overlay = root_widget(context, true)
    local moves, releases, overlay_moves = 0, 0, 0
    owner.on_mouse_moved = function() moves = moves + 1; return true end
    owner.on_mouse_released = function() releases = releases + 1; return true end
    overlay.on_mouse_moved = function() overlay_moves = overlay_moves + 1; return true end
    owner:capture_mouse()
    core.on_event("mousemoved", 80, 90, 0, 0)
    core.on_event("mousereleased", "right", 80, 90)
    test.equal(moves, 1)
    test.equal(releases, 0)
    test.equal(overlay_moves, 0)
    test.equal(root.captured_widget, owner)
    core.on_event("mousereleased", "left", 900, 700)
    test.equal(releases, 1)
    test.is_nil(root.captured_widget)
    test.is_nil(core.root_view.grab)
  end)

  test.test("a release callback can replace capture without losing the new grab", function(context)
    local root = root_widget(context)
    local first, second = child_widget(root), child_widget(root, 160)
    first.on_mouse_released = function()
      first:release_mouse()
      second:capture_mouse()
      return true
    end
    first:capture_mouse()
    core.on_event("mousereleased", "left", 80, 90)
    test.equal(root.captured_widget, second)
    test.not_nil(core.root_view.grab)
    first:release_mouse()
    test.equal(root.captured_widget, second)
    core.on_event("mousereleased", "left", 80, 90)
    test.is_nil(root.captured_widget)
    test.is_nil(core.root_view.grab)
  end)

  test.test("floating buttons keep their pressed target until release outside", function(context)
    local root = root_widget(context, true)
    local button = Button(root, "Click")
    button:set_position(20, 20)
    root:update()
    local clicks = 0
    button.on_click = function() clicks = clicks + 1 end
    core.on_event("mousepressed", "left", button.position.x + 5, button.position.y + 5, 1)
    test.equal(core.root_view.grab.view, root)
    core.on_event("mousemoved", 900, 700, 500, 500)
    core.on_event("mousereleased", "left", 900, 700)
    test.equal(clicks, 0)
    test.not_ok(button.mouse_is_pressed)
    test.not_ok(root.mouse_is_pressed)
    test.is_nil(core.root_view.grab)
  end)

  test.test("a standalone floating TextBox retains document focus after release", function(context)
    local input = TextBox(nil, "one two three")
    context.roots[#context.roots + 1] = input
    input:show()
    input:set_position(40, 60)
    input:update()
    local x, y = input.position.x + 20, input.position.y + 10
    core.on_event("mousepressed", "left", x, y, 1)
    core.on_event("mousereleased", "left", x, y)
    test.ok(core.active_view == input.textview)
    test.ok(command.perform("doc:move-to-end-of-line"))
    core.on_event("textinput", "!")
    test.equal(input:get_text(), "one two three!")
    test.is_nil(core.root_view.grab)
    input:hide()
    test.not_ok(input.active)
    test.not_equal(core.active_view, input.textview)
  end)

  test.test("hiding a pressed button cancels its ancestors and root grab", function(context)
    local root = root_widget(context, true)
    local button = Button(root, "Click")
    root:update()
    local clicks = 0
    button.on_click = function() clicks = clicks + 1 end
    local x, y = button.position.x + 5, button.position.y + 5
    core.on_event("mousepressed", "left", x, y, 1)
    button:hide()
    test.not_ok(root.mouse_is_pressed)
    test.not_ok(button.mouse_is_pressed)
    test.is_nil(core.root_view.grab)
    core.on_event("mousereleased", "left", x, y)
    test.equal(clicks, 0)
  end)

  test.test("removing a captured child cancels the gesture", function(context)
    local root = root_widget(context)
    local input = TextBox(root, "text")
    root:update()
    root:on_mouse_pressed("left", input.position.x + 5, input.position.y + 5, 1)
    root:remove_child(input)
    test.is_nil(input.textview.mouse_selecting)
    test.is_nil(root.child_active)
    test.is_nil(root.captured_widget)
    test.is_nil(core.root_view.grab)
  end)

  test.test("capture replaces a different root grab without clicking its pressed button", function(context)
    local first_root = root_widget(context, true)
    local button = Button(first_root, "Click")
    first_root:update()
    local clicks = 0
    button.on_click = function() clicks = clicks + 1 end
    core.on_event("mousepressed", "left", button.position.x + 5, button.position.y + 5, 1)
    local second_root = root_widget(context)
    local owner = child_widget(second_root)
    owner:capture_mouse(false, "right")
    test.equal(core.root_view.grab.view, second_root)
    test.equal(core.root_view.grab.button, "right")
    test.not_ok(first_root.mouse_is_pressed)
    test.not_ok(button.mouse_is_pressed)
    test.equal(clicks, 0)
    core.on_event("mousereleased", "left", 80, 90)
    test.equal(second_root.captured_widget, owner)
    core.on_event("mousereleased", "right", 80, 90)
    test.is_nil(second_root.captured_widget)
    test.is_nil(core.root_view.grab)
  end)

  test.test("floating window dragging captures motion and suppresses clicks", function(context)
    local root = root_widget(context, true)
    root.draggable = true
    local clicks = 0
    root.on_click = function() clicks = clicks + 1 end
    core.on_event("mousepressed", "left", 70, 90, 1)
    core.on_event("mousemoved", 850, 650, 780, 560)
    local bx, by, w, h = root:get_floating_bounds()
    test.ok(bx >= 0 and bx + w <= core.root_view.size.x)
    test.ok(by >= 0 and by + h <= core.root_view.size.y)
    core.on_event("mousereleased", "left", 850, 650)
    test.equal(clicks, 0)
    test.not_ok(root.mouse_is_pressed)
    test.is_nil(core.root_view.grab)
  end)

  for _, cancel in ipairs { "hide", "focuslost" } do
    test.test(cancel .. " cancels capture without clicking", function(context)
      local root = root_widget(context)
      local owner = child_widget(root)
      local clicks, cancelled = 0, 0
      owner.on_click = function() clicks = clicks + 1 end
      owner.on_mouse_capture_lost = function(self)
        cancelled = cancelled + 1
        Widget.on_mouse_capture_lost(self)
      end
      root:on_mouse_pressed("left", owner.position.x + 10, owner.position.y + 10, 1)
      owner:capture_mouse()
      if cancel == "hide" then root:hide() else core.on_event("focuslost") end
      test.equal(clicks, 0)
      test.equal(cancelled, 1)
      test.is_nil(root.captured_widget)
      test.is_nil(core.root_view.grab)
      test.not_ok(root.mouse_is_pressed)
      test.not_ok(owner.mouse_is_pressed)
    end)
  end

  test.test("scrollbar dragging captures motion and ends outside the widget", function(context)
    local root = root_widget(context)
    local list = child_widget(root)
    list.scrollable = true
    list.get_scrollable_size = function() return 600 end
    list.v_scrollbar:set_forced_status("expanded")
    root:update()
    local x, y, w, h = list.v_scrollbar:get_thumb_rect()
    root:on_mouse_pressed("left", x + w / 2, y + h / 2, 1)
    test.equal(root.captured_widget, list)
    core.on_event("mousemoved", x + w / 2, y + 160, 0, 160)
    test.ok(list.scroll.to.y > 0)
    core.on_event("mousereleased", "left", 900, 700)
    test.not_ok(list.v_scrollbar.dragging)
    test.is_nil(root.captured_widget)
  end)

  for _, direction in ipairs { "v", "h" } do
    for _, alignment in ipairs { "s", "e" } do
      test.test(direction .. " " .. alignment .. " child scrollbar takes over after hovering its parent", function(context)
        local root = root_widget(context)
        root.scrollable = true
        local container = child_widget(root)
        container:set_size(560, 360)
        local child = Widget(container)
        child:set_size(560, 360)
        child.scrollable = true
        local size_method = direction == "v" and "get_scrollable_size" or "get_h_scrollable_size"
        root[size_method] = function() return 1200 end
        child[size_method] = function() return 1200 end
        local parent_bar = direction == "v" and root.v_scrollbar or root.h_scrollbar
        local child_bar = direction == "v" and child.v_scrollbar or child.h_scrollbar
        for _, bar in ipairs { parent_bar, child_bar } do
          bar.alignment = alignment
          bar.contracted_size, bar.expanded_size = 4, 12
          bar.contracted_margin, bar.expanded_margin = 8, 12
        end
        root:update()
        local px, py, pw, ph = parent_bar:get_thumb_rect()
        root:on_mouse_moved(px + pw / 2, py + ph / 2, 0, 0)
        root:update()
        test.ok(parent_bar.hovering.thumb)
        test.equal(parent_bar.expand_percent, 1)
        local x, y, w, h = child_bar:get_thumb_rect()
        x, y = x + w / 2, y + h / 2
        root:on_mouse_moved(x, y, 0, 0)
        test.not_ok(parent_bar.hovering.track)
        test.ok(child_bar.hovering.thumb)
        root:on_mouse_pressed("left", x, y, 1)
        test.ok(child_bar.dragging)
        test.not_ok(parent_bar.dragging)
        test.equal(root.captured_widget, child)
        local dx, dy = direction == "h" and 80 or 0, direction == "v" and 80 or 0
        root:on_mouse_moved(x + dx, y + dy, dx, dy)
        test.ok(child.scroll.to[direction == "v" and "y" or "x"] > 0)
        test.equal(root.scroll.to.x, 0)
        test.equal(root.scroll.to.y, 0)
        root:on_mouse_released("left", 900, 700)
        test.not_ok(child_bar.dragging)
        test.is_nil(root.captured_widget)
      end)
    end
  end

  test.test("a parent's visible scrollbar stays clickable over child bounds", function(context)
    local root = root_widget(context)
    root.scrollable = true
    root.get_scrollable_size = function() return 1200 end
    local child = Widget(root)
    child:set_size(600, 400)
    root.v_scrollbar:set_forced_status("expanded")
    root:update()
    local x, y, w, h = root.v_scrollbar:get_thumb_rect()
    x, y = x + w / 2, y + h / 2
    test.ok(child:mouse_on_top(x, y))
    root:on_mouse_pressed("left", x, y, 1)
    test.ok(root.v_scrollbar.dragging)
    test.equal(core.root_view.grab.view, root)
    test.equal(root.captured_button, "left")
    root:on_mouse_released("left", 900, 700)
    test.not_ok(root.v_scrollbar.dragging)
    test.is_nil(root.captured_widget)
  end)

  test.test("ColorPicker clears its drag state when its container is hidden", function(context)
    local root = root_widget(context)
    local picker = ColorPicker(root)
    root:update()
    draw(root)
    local selector = picker.selector
    root:on_mouse_pressed("left", selector.x + selector.w / 2, selector.y + selector.h / 2, 1)
    test.ok(picker.hue_mouse_down)
    test.equal(root.captured_widget, picker)
    root:hide()
    test.not_ok(picker.hue_mouse_down)
    test.is_nil(core.root_view.grab)
  end)

  test.test("NumberBox stops repeating after release outside its buttons", function(context)
    local root = root_widget(context)
    local number = NumberBox(root, 10, 0, 20)
    root:update()
    local button = number.increase_button
    root:on_mouse_pressed("left", button.position.x + 5, button.position.y + 5, 1)
    test.equal(number:get_value(), 11)
    test.ok(number.mouse_is_pressed)
    root:on_mouse_released("left", 900, 700)
    test.not_ok(number.mouse_is_pressed)
    test.not_ok(button.mouse_is_pressed)
    test.not_ok(root.mouse_is_pressed)
  end)

  test.test("SelectBox opens once, selects a row, and dismisses on an outside click", function(context)
    local root = root_widget(context, true)
    local box = SelectBox(root, "Choose")
    box:add_option("First", 1)
    box:add_option("Second", 2)
    root:update()
    local x, y = box.position.x + 10, box.position.y + 10
    local function click(px, py)
      core.on_event("mousepressed", "left", px, py, 1)
      core.on_event("mousereleased", "left", px, py)
    end
    click(x, y)
    test.ok(box.list_container.visible)
    box.list_container:update()
    draw(box.list_container)
    local row = box.list.rows[2]
    local rx, ry = box.list.position.x + 20, box.list.position.y + row.y + row.h / 2
    test.equal(box.list:get_row_at_position(rx, ry), 2)
    click(rx, ry)
    test.equal(box:get_selected_data(), 1)
    box.list_container:update()
    test.not_ok(box.list_container.visible)
    click(x, y)
    test.ok(box.list_container.visible)
    click(900, 700)
    test.not_ok(box.list_container.visible)
  end)

  test.test("ListBox row clicks are emitted once per matching release", function(context)
    local root = root_widget(context)
    local list = ListBox(root)
    list:add_row({ "First" }, 1)
    list:add_row({ "Second" }, 2)
    root:update()
    draw(root)
    local clicks = 0
    list.on_row_click = function() clicks = clicks + 1 end
    local row = list.rows[1]
    local x, y = list.position.x + 20, list.position.y + row.y + row.h / 2
    test.equal(list:get_row_at_position(x, y), 1)
    root:on_mouse_pressed("left", x, y, 1)
    root:on_mouse_released("left", x, y)
    test.equal(clicks, 1)
    test.equal(list:get_selected(), 1)
    test.not_ok(root.mouse_is_pressed)
  end)

  test.test("TreeList keeps its press-time selection and emits one item click", function(context)
    local root = root_widget(context)
    local tree = TreeList(root)
    tree:set_size(300, 200)
    local item = { text = "First" }
    tree:add_item(item)
    root:update()
    local clicks = 0
    tree.on_item_click = function() clicks = clicks + 1 end
    local _, x, y, _, h = tree:each_item()()
    root:on_mouse_pressed("left", x + 80, y + h / 2, 1)
    test.equal(tree.selected_item, item)
    root:on_mouse_released("left", 900, 700)
    test.equal(clicks, 1)
    test.not_ok(tree.mouse_is_pressed)
    test.not_ok(root.mouse_is_pressed)
  end)
  for _, class in ipairs { "widget.colorpickerdialog", "widget.fontdialog" } do
    test.test(class .. " keeps its bordered bounds across floating updates", function(context)
      local dialog = require(class)()
      context.roots[#context.roots + 1] = dialog
      dialog:show()
      core.root_view:update(); core.root_view:update()
      local x, y, w, h = dialog:get_floating_bounds()
      for _ = 1, 30 do core.root_view:update() end
      local bx, by, bw, bh = dialog:get_floating_bounds()
      test.equal(bx, x); test.equal(by, y)
      test.equal(bw, w); test.equal(bh, h)
      test.ok(dialog.floating_visible)
    end)
  end

end)

test.describe("widget positioning", function()
  test.before_each(function(context)
    context.roots = {}
    context.transitions = config.transitions
    config.transitions = false
    context.root = root_widget(context)
    context.root.scrollable = true
    context.nodes = { context.root }
    local parent = context.root
    for index = 1, 3 do
      local child = Widget(parent)
      child.scrollable = true
      child:set_position(10.2, 15.6)
      child:set_size(400 - index * 20, 320 - index * 20)
      context.nodes[#context.nodes + 1] = child
      parent = child
    end
    for _ = 1, 5 do context.root:update() end
  end)

  test.after_each(function(context)
    for _, root in ipairs(context.roots) do root:destroy() end
    config.transitions = context.transitions
  end)

  local function check_positions(context, scrollbars)
    for index = 2, #context.nodes do
      local node = context.nodes[index]
      local ox, oy = node.parent:get_content_offset()
      test.near(node.position.x, ox + node.position.rx + node.border.width, 1e-8)
      test.near(node.position.y, oy + node.position.ry + node.border.width, 1e-8)
      if scrollbars then
        test.equal(node.v_scrollbar.rect.x, node.position.x)
        test.equal(node.v_scrollbar.rect.y, node.position.y)
      end
    end
  end

  test.it("updates nested positions and scrollbars in the frame their parent moves", function(context)
    context.root.position.x = 90.25
    context.root.position.y = 60.85
    context.root.get_scrollable_size = function() return 1000 end
    context.root.scroll.y, context.root.scroll.to.y = 0.4, 0.4
    local child = context.nodes[2]
    child.get_scrollable_size = function() return 1000 end
    child.scroll.y, child.scroll.to.y = 0.6, 0.6
    context.root:update()
    check_positions(context, true)
  end)

  test.it("positions a hidden branch before updating it after showing", function(context)
    local branch = context.nodes[2]
    branch:hide()
    context.root.position.y = 140.2
    context.root:update()
    branch:show()
    context.root:update()
    check_positions(context, true)
  end)

  test.it("keeps explicit position updates recursive by default", function(context)
    context.root.position.x = 90.25
    context.nodes[3].position.ry = 45.6
    context.root:update_position()
    check_positions(context)
  end)
end)

test.describe("widget rendering", function()
  test.before_each(function(context)
    context.roots = {}
    context.scale = SCALE
    context.clip_rect_stack = core.clip_rect_stack
    context.recent_projects = core.recent_projects
    context.root_view = core.root_view
    context.active_view = core.active_view
    context.last_active_view = core.last_active_view
    context.next_active_view = core.next_active_view
    context.style = {}
    for _, name in ipairs { "font", "big_font", "icon_font", "icon_big_font", "padding" } do
      context.style[name] = style[name]
    end
  end)

  test.after_each(function(context)
    for _, root in ipairs(context.roots) do root:destroy() end
    SCALE = context.scale
    for name, value in pairs(context.style) do style[name] = value end
    core.clip_rect_stack = context.clip_rect_stack
    core.recent_projects = context.recent_projects
    core.root_view = context.root_view
    core.active_view = context.active_view
    core.last_active_view = context.last_active_view
    core.next_active_view = context.next_active_view
  end)

  local function set_scale(context, factor)
    SCALE = factor
    local ratio = factor / context.scale
    for _, name in ipairs { "font", "big_font", "icon_font", "icon_big_font" } do
      style[name] = context.style[name]:copy(context.style[name]:get_size() * ratio)
    end
    style.padding = { x = context.style.padding.x * ratio, y = context.style.padding.y * ratio }
  end

  for _, factor in ipairs { 1, 1.25, 1.5, 1.75, 2, 3 } do
    test.it("draws complete borders within their bounds at scale " .. factor, function(context)
      set_scale(context, factor)
      local root = root_widget(context)
      root.border.width = factor
      root.border.color = { 220, 120, 30, 128 }
      root:set_position(20.6 * factor, 20.6 * factor)
      root:set_size(100.6 * factor, 70.6 * factor)
      local background = { 30, 40, 50, 255 }
      root.background_color = background
      root:update()
      local window = renwindow.create("Widget borders", 640, 480)
      core.clip_rect_stack = { { 0, 0, 640, 480 } }
      renderer.begin_frame(window)
      renderer.set_clip_rect(0, 0, 640, 480)
      renderer.draw_rect(0, 0, 640, 480, background)
      root:draw()
      renderer.end_frame()
      local capture = renderer.to_canvas(window, 0, 0, 640, 480)
      local function pixel(x, y) return { capture:get_pixels(x, y, 1, 1):byte(1, 3) } end
      local function round(value) return math.floor(value + 0.5) end
      local x, y, w, h = root:get_floating_bounds()
      local left, top = round(x), round(y)
      local right, bottom = round(x + w), round(y + h)
      local color = pixel(round(x + w / 2), top)
      for column = left, right - 1 do
        test.same(pixel(column, top), color)
        test.same(pixel(column, bottom - 1), color)
        test.same(pixel(column, bottom), { 30, 40, 50 })
      end
      for row = top, bottom - 1 do
        test.same(pixel(left, row), color)
        test.same(pixel(right - 1, row), color)
        test.same(pixel(right, row), { 30, 40, 50 })
      end
    end)

    test.it("keeps a child border inside a fractional viewport at scale " .. factor, function(context)
      set_scale(context, factor)
      local root = root_widget(context)
      root.border.width = 0
      root:set_position(20.6 * factor, 20.6 * factor)
      root:set_size(100.6 * factor, 70.6 * factor)
      local child = Widget(root)
      child:set_position(0, 0)
      child:set_size(root.size.x, root.size.y)
      root:update()
      local x, y, w, h = child:get_floating_bounds()
      test.near(x, root.position.x, 1e-8)
      test.near(y, root.position.y, 1e-8)
      test.near(x + w, root.position.x + root.size.x, 1e-8)
      test.near(y + h, root.position.y + root.size.y, 1e-8)
    end)

    test.it("scrolls nested controls together at scale " .. factor, function(context)
      set_scale(context, factor)
      local root = root_widget(context)
      root.scrollable = true
      root.get_scrollable_size = function() return 2400 end
      root:set_position(20.6 * factor, 20.6 * factor)
      local parent = Widget(root)
      parent:set_position(10.3 * factor, 10.3 * factor)
      parent:set_size(400, 1600)
      local label = Label(parent, "A scrolling label")
      label:set_position(12.2 * factor, 80.7 * factor)
      local input = NumberBox(parent, 10, 0, 100)
      input:set_position(12.2 * factor, 120.3 * factor)
      for _ = 1, 4 do root:update() end
      local controls = { parent, label, input, input.textbox, input.decrease_button,
        input.increase_button, input.textbox.textview }
      local origins = {}
      for index, control in ipairs(controls) do origins[index] = control.position.y end
      for step = 1, 80 do
        local offset = step * 0.3
        root.scroll.y, root.scroll.to.y = offset, offset
        root:update()
        local pixels = math.floor(offset + 0.5)
        for index, control in ipairs(controls) do
          test.near(control.position.y + pixels, origins[index], 1e-8)
        end
      end
    end)

    test.it("fits notebook panes to the content viewport at scale " .. factor, function(context)
      set_scale(context, factor)
      local root = root_widget(context)
      local book = NoteBook(root)
      book:set_position(10.6 * factor, 10.6 * factor)
      book:set_size(250.6 * factor, 150.6 * factor)
      local pane = book:add_pane("first", "First")
      book:add_pane("second", "Second")
      for _ = 1, 4 do root:update() end
      local x, y, w, h = pane:get_floating_bounds()
      test.near(x, book.position.x, 1e-8)
      test.near(x + w, book.position.x + book.size.x, 1e-8)
      test.near(y + h, book.position.y + book.size.y, 1e-8)
      test.ok(y > book.active_pane.tab.position.y)
    end)
  end

  for _, nested in ipairs { false, true } do
    test.it("keeps ListBox drawing and row clicks aligned while its "
      .. (nested and "ancestor" or "parent") .. " scrolls", function(context)
      local root = root_widget(context)
      root.scrollable = true
      root.get_scrollable_size = function() return 2000 end
      root:set_position(20.65, 20.65)
      local parent = root
      if nested then
        parent = Widget(root)
        parent:set_position(10.3, 10.3)
        parent:set_size(450, 1800)
      end
      local list = ListBox(parent)
      list:set_position(20.7, 70.7)
      list:set_size(320, 140)
      list:add_column("Rows")
      for index = 1, 30 do list:add_row({ "Row " .. index }, index) end
      for _ = 1, 4 do root:update() end
      local painted = {}
      local draw_row = list.draw_row
      function list:draw_row(index, x, y, only_calc)
        if not only_calc then painted[index] = { x, y } end
        return draw_row(self, index, x, y, only_calc)
      end
      local original_y = list.position.y
      for _, offsets in ipairs { { 30.1, 11.1 }, { 30.4, 11.4 }, { 30.6, 11.6 }, { 60.7, 35.8 } } do
        root.scroll.y, root.scroll.to.y = offsets[1], offsets[1]
        list.scroll.y, list.scroll.to.y = offsets[2], offsets[2]
        root:update()
        painted = {}
        draw(root)
        local first = list.visible_rows[1]
        local row = list.rows[first]
        local x, y = unpack(painted[first])
        test.near(y, original_y - math.floor(offsets[1] + 0.5)
          - math.floor(offsets[2] + 0.5) + list.border.width + row.y, 1e-8)
        -- Pick a row below the fixed column heading.
        for _, index in ipairs(list.visible_rows) do
          local position = painted[index]
          local middle = position[2] + list.rows[index].h / 2
          if middle > list.position.y + list:get_font():get_height() + style.padding.y
            and middle < list.position.y + list.size.y then
            test.equal(list:get_row_at_position(position[1] + 20, middle), index)
            break
          end
        end
      end
    end)
  end

  test.it("reuses visible rows while scrolling within the same pixel", function(context)
    local root = root_widget(context)
    local list = ListBox(root)
    list:set_size(300, 140)
    for index = 1, 30 do list:add_row({ "Row " .. index }) end
    root:update()
    list.scroll.y, list.scroll.to.y = 20.1, 20.1
    root:update()
    local visible_rows = list.visible_rows
    list.scroll.y, list.scroll.to.y = 20.4, 20.4
    root:update()
    test.equal(list.visible_rows, visible_rows)
    list.scroll.y, list.scroll.to.y = 20.6, 20.6
    root:update()
    test.ok(list.visible_rows ~= visible_rows)
  end)

  test.it("reflows container children after a scale change without resizing the viewport", function(context)
    set_scale(context, 1)
    local root = root_widget(context)
    local container = Container(root)
    container:set_size(400, 100)
    local first, second = Button(container, "First action"), Button(container, "Second action")
    for _ = 1, 4 do root:update() end
    test.equal(first:get_position().y, second:get_position().y)
    set_scale(context, 2)
    for _ = 1, 6 do root:update() end
    test.ok(second:get_position().y >= first:get_bottom())
    test.ok(container:get_height() >= second:get_bottom())
  end)

  test.it("keeps the Welcome list border visible across live scale changes", function(context)
    set_scale(context, 1)
    core.recent_projects = { "/projects/first", "/projects/second" }
    local view = EmptyView()
    context.roots[#context.roots + 1] = view
    view:set_position(0, 0)
    view:set_size(1440, 900)
    for _, factor in ipairs { 1, 1.25, 1.5, 1.75, 2, 3, 1 } do
      set_scale(context, factor)
      for _ = 1, 6 do view:update() end
      local list = view.recent_projects
      test.near(list:get_width(), view.size.x - style.padding.x * 2, 1e-8)
      view.scroll.to.y = view:get_scrollable_size() - view.size.y
      for _ = 1, 6 do view:update() end
      local bottom = list.position.y + list.size.y + list.border.width
      test.ok(bottom <= view.position.y + view.size.y - style.padding.y + 1e-8)
    end
  end)

  test.it("draws dialog children once", function(context)
    local dialog = Dialog("Rendering")
    context.roots[#context.roots + 1] = dialog
    dialog.defer_draw = false
    dialog:set_floating(false)
    dialog:show()
    dialog:set_position(20, 20)
    local child = Widget(dialog:get_panel())
    child:set_size(30, 30)
    local draws = 0
    function child:draw()
      draws = draws + 1
      return Widget.draw(self)
    end
    dialog:update()
    draw(dialog)
    test.equal(draws, 1)
  end)

  test.it("keeps oversized dialog chrome inside the floating viewport", function(context)
    set_scale(context, 3)
    core.root_view = RootView()
    core.root_view.size.x, core.root_view.size.y = 640, 480
    local dialog = Dialog("Large dialog")
    context.roots[#context.roots + 1] = dialog
    dialog:show()
    local content = Widget(dialog:get_panel())
    content:set_size(1200, 800)
    dialog:set_floating_bounds(10.25, 20.5, 600.5, 400.5)
    dialog:update()
    local x, y, w, h = dialog:get_floating_bounds()
    test.ok(dialog.close.position.x >= x)
    test.ok(dialog.close.position.x + dialog.close:get_width() <= x + w)
    test.ok(dialog.panel:get_right() <= dialog.size.x)
    test.ok(dialog.panel:get_bottom() <= dialog.size.y)
    test.ok(dialog.panel:get_h_scrollable_size() > dialog.panel.size.x)
    test.ok(dialog.panel:get_scrollable_size() > dialog.panel.size.y)
    test.ok(y + h <= core.root_view.size.y)
  end)
end)

test.describe("TextBox cursor", function()
  test.before_each(function(context)
    context.root_view = core.root_view
    context.active_view = core.active_view
    context.last_active_view = core.last_active_view
    context.next_active_view = core.next_active_view
    context.cursor_change_req = core.cursor_change_req
    context.transitions = config.transitions
    config.transitions = false
    core.root_view = RootView()
    core.root_view.size.x, core.root_view.size.y = 900, 650
    core.root_view.root_node.is_primary_node = true
    context.roots = {}
  end)

  test.after_each(function(context)
    for _, root in ipairs(context.roots) do root:destroy() end
    core.root_view = context.root_view
    core.active_view = context.active_view
    core.last_active_view = context.last_active_view
    core.next_active_view = context.next_active_view
    core.cursor_change_req = context.cursor_change_req
    config.transitions = context.transitions
  end)

  local function controls(context, floating)
    local root = root_widget(context, floating)
    if not floating then core.root_view.root_node:add_view(root) end
    local pane = child_widget(root)
    pane:set_size(400, 250)
    local number = NumberBox(pane, 10, 0, 20)
    number:set_position(20, 20)
    local button = Button(pane, "Other control")
    button:set_position(20, 100)
    local label = Label(pane, "Description")
    label:set_position(20, 160)
    for _ = 1, 3 do core.root_view:update() end
    return root, number.textbox, { number.decrease_button, number.increase_button, button, label, pane }
  end

  local function move(x, y)
    core.on_event("mousemoved", x, y, 0, 0)
    core.root_view:update()
  end

  local function focus(input)
    local x, y = input.position.x + 10, input.position.y + input.size.y / 2
    move(x, y)
    core.on_event("mousepressed", "left", x, y, 1)
    core.on_event("mousereleased", "left", x, y)
    core.root_view:update()
    test.equal(core.active_view, input.textview)
    test.equal(core.cursor_change_req, "ibeam")
  end

  for _, floating in ipairs { false, true } do
    local mode = floating and "floating" or "docked"
    test.it("synchronizes " .. mode .. " input activation without clearing the remembered field", function(context)
      local root, input, targets = controls(context, floating)
      focus(input)
      local activations, deactivations = 0, 0
      local activate, deactivate = input.activate, input.deactivate
      function input:activate()
        activations = activations + 1
        activate(self)
      end
      function input:deactivate()
        deactivations = deactivations + 1
        deactivate(self)
      end
      local text = input:get_text()
      core.set_active_view(targets[3])
      core.root_view:update()
      test.not_ok(input.active)
      test.equal(input.border.color, style.text)
      test.equal(root.child_active, input)
      test.not_ok(input:on_mouse_wheel(-1))
      test.equal(input:get_text(), text)
      test.equal(deactivations, 1)
      for _ = 1, 5 do core.root_view:update() end
      test.equal(deactivations, 1)

      core.set_active_view(root:get_focus_target())
      core.root_view:update()
      test.ok(input.active)
      test.equal(input.border.color, style.caret)
      test.equal(activations, 1)
      for _ = 1, 5 do core.root_view:update() end
      test.equal(activations, 1)
      test.equal(deactivations, 1)
    end)

    test.it("follows hover outside a focused nested " .. mode .. " input", function(context)
      local root, input, targets = controls(context, floating)
      root.scrollable = true
      root.get_scrollable_size = function() return 1200 end
      core.root_view:update()
      for _, target in ipairs(targets) do
        focus(input)
        local x, y = target.position.x + target.size.x - 5, target.position.y + target.size.y - 5
        move(x, y)
        test.not_ok(input.mouse_is_hovering)
        test.is_nil(input.textview.mouse_selecting)
        test.equal(core.active_view, input.textview)
        test.equal(core.cursor_change_req, "arrow")
        for _ = 1, 3 do
          core.cursor_change_req = nil
          core.root_view:update()
          test.not_equal(core.cursor_change_req, "ibeam")
        end
      end
      focus(input)
      local x, y, w, h = root.v_scrollbar:get_thumb_rect()
      test.ok(w > 0 and h > 0)
      move(x + w / 2, y + h / 2)
      test.not_ok(input.mouse_is_hovering)
      test.equal(core.cursor_change_req, "arrow")
    end)

    test.it("keeps keyboard focus independent of the " .. mode .. " input cursor", function(context)
      local root, input, targets = controls(context, floating)
      local button = targets[3]
      move(button.position.x + 5, button.position.y + 5)
      core.cursor_change_req = nil
      root:swap_active_child(input)
      test.is_nil(core.cursor_change_req)
      core.root_view:update()
      test.is_nil(core.cursor_change_req)
      test.equal(core.active_view, input.textview)
      core.cursor_change_req = "hand"
      root:swap_active_child()
      test.equal(core.cursor_change_req, "hand")
      move(input.position.x + 10, input.position.y + input.size.y / 2)
      test.not_ok(input.active)
      test.ok(input.mouse_is_hovering)
      test.equal(core.cursor_change_req, "ibeam")
    end)

    test.it("keeps the text cursor only during a captured " .. mode .. " selection", function(context)
      local _, input = controls(context, floating)
      focus(input)
      local x, y = input.position.x + 10, input.position.y + input.size.y / 2
      core.on_event("mousepressed", "left", x, y, 1)
      move(800, 600)
      test.not_ok(input.mouse_is_hovering)
      test.not_nil(input.textview.mouse_selecting)
      test.equal(input.captured_button, "left")
      test.equal(core.cursor_change_req, "ibeam")
      core.on_event("mousereleased", "left", 800, 600)
      core.root_view:update()
      test.is_nil(input.textview.mouse_selecting)
      test.is_nil(core.root_view.grab)
      test.equal(core.active_view, input.textview)
      move(800, 600)
      test.equal(core.cursor_change_req, "arrow")
    end)
  end
end)
