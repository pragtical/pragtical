local core = require "core"
local config = require "core.config"
local View = require "core.view"
local RootView = require "core.rootview"
local test = require "core.test"

local function popup(context, options, x, y, w, h)
  local view = View()
  view:set_floating_bounds(x or 40, y or 40, w or 120, h or 80)
  view:set_floating(true, options)
  context.views[#context.views + 1] = view
  return view
end

test.describe("floating View", function()
  test.before_each(function(context)
    context.root, context.active, context.last, context.next = core.root_view, core.active_view, core.last_active_view, core.next_active_view
    context.transitions, context.fps, context.config_fps = config.transitions, core.fps, config.fps
    core.root_view = RootView()
    core.root_view.root_node.is_primary_node = true
    core.root_view.size.x, core.root_view.size.y = 500, 400
    core.active_view = core.root_view.root_node.active_view
    config.transitions = false
    core.fps, config.fps = 60, 60
    context.views = {}
  end)
  test.after_each(function(context)
    for _, view in ipairs(context.views) do view:hide_floating() end
    core.root_view, core.active_view, core.last_active_view, core.next_active_view = context.root, context.active, context.last, context.next
    config.transitions, core.fps, config.fps = context.transitions, context.fps, context.config_fps
  end)

  test.test("mode is optional and registration is idempotent", function(context)
    test.equal(View().floating, false)
    local view = popup(context)
    test.equal(#core.root_view.floating_views, 0)
    view:show_floating(); view:show_floating()
    test.equal(#core.root_view.floating_views, 1)
    view:set_floating(false)
    test.equal(#core.root_view.floating_views, 0)
    test.equal(view.position.x, 40)
  end)

  test.test("invalid placement options leave a shown popup unchanged", function(context)
    local owner = View:extend()()
    local view = popup(context, { owner = owner, focus = "none" })
    view:show_floating()
    for _, options in ipairs {
      { owner = "wrong" }, { focus = "showw" }, { modal = 1 },
      { min_size = { x = -1, y = 10 } },
      { anchor = { target = owner, side = "center" } },
      { anchor = { target = { x = 0, y = 0 } } },
      { focuss = "show" }
    } do
      test.error(function() view:set_floating(true, options) end, "set_floating")
      test.ok(view.floating_visible)
      test.equal(view.floating_options.owner, owner)
      test.equal(view.floating_options.focus, "none")
      test.equal(#core.root_view.floating_views, 1)
    end
    view:set_floating(true, { owner = false, anchor = false })
    test.equal(view.floating_options.owner, false)
  end)

  test.test("invalid transitions preserve registration, focus and capture", function(context)
    local view = popup(context, { focus = "show" })
    local previous = core.active_view
    test.error(function() view:show_floating { from = "center" } end, "show_floating")
    test.not_ok(view.floating_visible)
    test.equal(core.active_view, previous)
    view:show_floating()
    core.root_view:grab_mouse("left", view)
    for _, options in ipairs { { to = "center" }, { rate = 0 }, { on_complete = true } } do
      test.error(function() view:hide_floating(options) end, "hide_floating")
      test.ok(view.floating_visible)
      test.equal(core.active_view, view)
      test.equal(core.root_view.grab.view, view)
    end
    test.error(function() view:show_floating { owner = previous } end, "set_floating")
  end)

  test.test("passive overlays do not intercept clicks or focus", function(context)
    local lower = popup(context, { focus = "none" })
    local passive = popup(context, { interactive = false, focus = "none" })
    local count, original = 0, core.active_view
    lower.on_mouse_pressed = function() count = count + 1 end
    lower:show_floating(); passive:show_floating()
    core.on_event("mousepressed", "left", 60, 60, 1)
    test.equal(count, 1); test.equal(core.active_view, original)
    core.on_event("mousereleased", "left", 60, 60)
  end)

  test.test("capture beats stacking and unrelated releases", function(context)
    local lower, upper = popup(context), popup(context)
    local moved, released = 0, 0
    lower.on_mouse_moved = function() moved = moved + 1 end
    lower.on_mouse_released = function() released = released + 1 end
    lower:show_floating()
    core.root_view:grab_mouse("left", lower)
    upper:show_floating()
    core.on_event("mousemoved", 300, 300, 1, 1)
    core.on_event("mousereleased", "right", 300, 300)
    test.equal(moved, 1); test.equal(released, 0)
    core.on_event("mousereleased", "left", 300, 300)
    test.equal(released, 1); test.is_nil(core.root_view.grab)
  end)

  test.test("hover changes and window leave notify once", function(context)
    local a, b = popup(context, nil, 0, 0), popup(context, nil, 200, 0)
    local left = 0
    a.on_mouse_left = function() left = left + 1 end
    a:show_floating(); b:show_floating()
    core.on_event("mousemoved", 20, 20, 0, 0)
    core.on_event("mousemoved", 220, 20, 0, 0)
    core.on_event("mouseleft"); core.on_event("mouseleft")
    test.equal(left, 1)
  end)

  test.test("modal guard permits descendants and rejects outside focus", function(context)
    local outside = core.active_view
    local modal = popup(context, { modal = true, focus = "show" })
    modal:show_floating()
    test.equal(core.active_view, modal)
    local descendant = View(); descendant.parent = modal
    core.set_active_view(descendant)
    test.equal(core.active_view, descendant)
    core.set_active_view(outside)
    test.equal(core.active_view, descendant)
    modal:hide_floating()
    test.equal(core.active_view, outside)
  end)

  test.test("can dismiss on owner clicks while other popups keep their owner inside", function(context)
    core.root_view:update()
    local view = popup(context, { owner = core.active_view, focus = "none", dismiss_on_outside_click = true })
    view:show_floating()
    core.on_event("mousepressed", "left", 350, 200, 1)
    core.on_event("mousereleased", "left", 350, 200)
    test.ok(view.floating_visible)
    view:set_floating(true, { dismiss_on_owner_click = true })
    core.on_event("mousepressed", "left", 350, 200, 1)
    core.on_event("mousereleased", "left", 350, 200)
    test.not_ok(view.floating_visible)
  end)

  for _, consume in ipairs { true, false } do
    test.test("outside dismissal " .. (consume and "consumes" or "passes") .. " its click", function(context)
      local view = popup(context, { focus = "none", dismiss_on_outside_click = true, consume_outside_click = consume })
      local clicked = 0
      core.active_view.on_mouse_pressed = function() clicked = clicked + 1; return true end
      view:show_floating()
      core.on_event("mousepressed", "left", 300, 300, 1)
      test.equal(view.floating_visible, false)
      test.equal(clicked, consume and 0 or 1)
      core.root_view:cancel_mouse_capture()
    end)
  end

  test.test("owner hiding removes descendants and cancels capture", function(context)
    local owner = popup(context)
    local child = popup(context, { owner = owner })
    owner:show_floating(); child:show_floating()
    core.root_view:grab_mouse("left", child)
    owner:hide_floating()
    test.equal(#core.root_view.floating_views, 0)
    test.is_nil(core.root_view.grab)
  end)

  test.test("anchoring flips and clamps to the viewport", function(context)
    local anchor = View(); anchor:set_floating_bounds(480, 385, 20, 15)
    local view = popup(context, { anchor = { target = anchor, side = "right" } }, 0, 0, 100, 80)
    view:show_floating()
    test.equal(view.position.x, 380); test.equal(view.position.y, 320)
  end)

  for _, edge in ipairs { "top", "bottom", "left", "right" } do
    test.test("slides from and to " .. edge .. " and preserves settled bounds", function(context)
      config.transitions = true
      local view = popup(context)
      local completed = 0
      view:show_floating { from = edge, rate = 0.5, on_complete = function() completed = completed + 1 end }
      test.not_ok(view:hit_test(60, 60))
      for _ = 1, 120 do core.root_view:update() end
      test.equal(view.position.x, 40); test.equal(view.position.y, 40)
      test.equal(completed, 1)
      view:hide_floating { to = edge, rate = 0.5, on_complete = function() completed = completed + 1 end }
      test.is_nil(core.root_view:get_floating_view_at(60, 60))
      for _ = 1, 120 do core.root_view:update() end
      test.equal(view.floating_visible, false); test.equal(completed, 2)
      test.equal(view.position.x, 40); test.equal(view.position.y, 40)
    end)
  end

  test.test("reopening cancels closing without firing its callback", function(context)
    config.transitions = true
    local view = popup(context)
    view:show_floating()
    local closed = 0
    view:hide_floating { to = "bottom", on_complete = function() closed = closed + 1 end }
    core.root_view:update()
    view:show_floating { from = "bottom" }
    for _ = 1, 60 do core.root_view:update() end
    test.equal(closed, 0); test.equal(view.position.y, 40)
    test.equal(view.floating_visible, true)
  end)

  test.test("dragging and resizing stay within the viewport", function(context)
    local view = popup(context, { draggable = true, resizable = true, min_size = { x = 40, y = 30 } })
    view:show_floating()
    core.on_event("mousepressed", "left", 70, 70, 1)
    core.on_event("mousemoved", 900, 800, 830, 730)
    test.equal(view.position.x + view.size.x, 500)
    test.equal(view.position.y + view.size.y, 400)
    core.on_event("mousereleased", "left", 900, 800)
    core.on_event("mousepressed", "left", 499, 399, 1)
    core.on_event("mousemoved", 395, 335, -104, -64)
    test.ok(view.size.x >= 40); test.ok(view.size.y >= 30)
    core.on_event("focuslost")
    test.is_nil(core.root_view.grab)
  end)
  test.test("floating document references survive detachment and close with the session", function(context)
    local Doc, DocView = require "core.doc", require "core.docview"
    local doc = Doc()
    local view = DocView(doc)
    context.views[#context.views + 1] = view
    core.root_view.root_node:add_view(View())
    core.root_view.root_node:add_view(view)
    test.error(function() view:show_floating() end)
    core.root_view.root_node:remove_view(core.root_view.root_node, view)
    view:set_floating_bounds(20, 20, 200, 160)
    view:show_floating()
    test.equal(core.get_views_referencing_doc(doc)[1], view)
    test.error(function() core.root_view:get_primary_node():add_view(view) end)
    view:set_floating(false)
    core.root_view:get_primary_node():add_view(view)
    test.equal(core.get_views_referencing_doc(doc)[1], view)
    core.root_view:get_primary_node():remove_view(core.root_view.root_node, view)
    view:show_floating()
    core.root_view:close_all_docviews()
    test.not_ok(view.floating_visible)
    test.equal(#core.get_views_referencing_doc(doc), 0)
  end)

  test.test("raising an owner preserves submenu stacking", function(context)
    local owner = popup(context)
    local child = popup(context, { owner = owner })
    local other = popup(context)
    owner:show_floating(); child:show_floating(); other:show_floating()
    owner:bring_to_front()
    test.equal(core.root_view.floating_views[2], owner)
    test.equal(core.root_view.floating_views[3], child)
    test.equal(core.root_view:get_floating_view_at(60, 60), child)
  end)

  test.test("drawing snapshots tolerate removals and clip each overlay", function(context)
    local a, b = popup(context), popup(context)
    a:show_floating(); b:show_floating()
    core.root_view:update()
    local order = {}
    a.draw = function()
      table.insert(order, "a")
      local clip = core.clip_rect_stack[#core.clip_rect_stack]
      test.ok(clip[3] <= core.root_view.size.x and clip[4] <= core.root_view.size.y)
      core.root_view:defer_draw(function() table.insert(order, "deferred") end)
      b:hide_floating()
    end
    b.draw = function() table.insert(order, "b") end
    renderer.begin_frame(core.window)
    core.root_view:draw()
    renderer.end_frame()
    test.equal(table.concat(order, ","), "a,deferred")
  end)

end)
