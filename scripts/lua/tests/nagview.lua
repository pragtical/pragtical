local core = require "core"
local config = require "core.config"
local View = require "core.view"
local RootView = require "core.rootview"
local test = require "core.test"
local NagView = require "core.nagview"

test.describe("nagview floating overlay", function()
  test.before_each(function(context)
    context.root, context.active, context.last, context.next, context.nag = core.root_view, core.active_view, core.last_active_view, core.next_active_view, core.nag_view
    context.transitions = config.transitions
    config.transitions = false
    core.root_view = RootView(); core.root_view.root_node.is_primary_node = true
    core.root_view.size.x, core.root_view.size.y = 700, 500
    core.nag_view = NagView()
    core.root_view.root_node:split("up", core.nag_view, { y = true })
    context.view = View()
    core.root_view:get_primary_node():add_view(context.view)
    context.selected = {}
    context.show = function(title)
      core.nag_view:show(title, "Choose an option", {
        { text = "Yes", default_yes = true }, { text = "No", default_no = true }
      }, function(option) table.insert(context.selected, option.text) end)
      core.root_view:update(); core.root_view:update()
    end
  end)
  test.after_each(function(context)
    core.nag_view.force_focus = false
    core.nag_view.overlay:hide_floating()
    core.root_view, core.active_view, core.last_active_view, core.next_active_view, core.nag_view = context.root, context.active, context.last, context.next, context.nag
    config.transitions = context.transitions
  end)

  test.test("overlay blocks outside clicks and preserves Y/N selection", function(context)
    local pressed = 0
    context.view.on_mouse_pressed = function() pressed = pressed + 1 end
    context.show("First")
    core.on_event("mousepressed", "left", 20, 480, 1)
    core.on_event("mousereleased", "left", 20, 480)
    test.equal(pressed, 0)
    test.equal(core.active_view, core.nag_view)
    core.on_event("textinput", "y")
    test.equal(context.selected[1], "Yes")
    test.equal(core.active_view, context.view)
    core.root_view:update()
    test.equal(#core.root_view.floating_views, 0)
  end)

  test.test("dialogs without an affirmative default animate before a button is hovered", function(context)
    core.nag_view:show("Remove Session", "Remove the selected saved session?", {
      { text = "Remove" }, { text = "Cancel", default_no = true }
    }, function(option) table.insert(context.selected, option.text) end)
    test.is_nil(core.nag_view.hovered_item)
    for _ = 1, 5 do core.root_view:update() end
    renderer.begin_frame(core.window)
    core.root_view:draw()
    renderer.end_frame()
    test.equal(type(core.nag_view.underline_progress), "number")
    core.on_event("textinput", "n")
    test.equal(context.selected[1], "Cancel")
    test.equal(core.active_view, context.view)
  end)

  test.test("button presses select the queued dialog and restore focus", function(context)
    context.show("First"); context.show("Second")
    for _, option, x, y, w, h in core.nag_view:each_option() do
      if option.text == "No" then
        core.on_event("mousepressed", "left", x + w / 2, y + h / 2, 1)
        core.on_event("mousereleased", "left", x + w / 2, y + h / 2)
        break
      end
    end
    test.equal(context.selected[1], "No")
    test.equal(core.nag_view.title, "Second")
    test.equal(core.active_view, core.nag_view)
    core.on_event("textinput", "y")
    test.equal(context.selected[2], "Yes")
    test.equal(core.active_view, context.view)
  end)
  test.test("modal scrollbar releases and cancels through the companion", function(context)
    core.nag_view:show("Long dialog", ("A long message\n"):rep(90), {
      { text = "Close", default_yes = true }
    })
    core.root_view:update(); core.root_view:update()
    local x, y, w, h = core.nag_view.v_scrollbar:get_thumb_rect()
    core.on_event("mousepressed", "left", x + w / 2, y + h / 2, 1)
    test.ok(core.nag_view.v_scrollbar.dragging)
    core.on_event("mousereleased", "left", -10, -10)
    test.not_ok(core.nag_view.v_scrollbar.dragging)
    core.on_event("mousepressed", "left", x + w / 2, y + h / 2, 1)
    core.on_event("focuslost")
    test.not_ok(core.nag_view.v_scrollbar.dragging)
    test.is_nil(core.root_view.grab)
    core.on_event("textinput", "y")
    test.equal(core.active_view, context.view)
  end)

end)
