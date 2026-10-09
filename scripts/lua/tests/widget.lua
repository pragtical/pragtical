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
    test.ok(root.position.x > 800)
    test.ok(root.position.y > 600)
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
end)
