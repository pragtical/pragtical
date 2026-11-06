local core = require "core"
local config = require "core.config"
local command = require "core.command"
local ime = require "core.ime"
local View = require "core.view"
local Doc = require "core.doc"
local DocView = require "core.docview"
local RootView = require "core.rootview"
local ContextMenu = require "core.contextmenu"
local test = require "core.test"
local style = require "core.style"

local function document(context, named)
  local doc
  if named then
    context.path = core.temp_filename(".txt")
    local file = assert(io.open(context.path, "wb"))
    file:write("original\n")
    file:close()
    doc = Doc(context.path, context.path)
  else
    doc = Doc()
  end
  core.docs[#core.docs + 1] = doc
  local view = DocView(doc)
  context.views[#context.views + 1] = view
  view:set_floating_bounds(40, 40, 250, 180)
  view:set_floating(true, { focus = "show" })
  view:show_floating()
  return view
end

test.describe("floating document routing", function()
  test.before_each(function(context)
    context.cwd = system.getcwd()
    context.root, context.active, context.last, context.next = core.root_view, core.active_view, core.last_active_view, core.next_active_view
    context.docs, context.transitions = core.docs, config.transitions
    context.enter, context.quit = core.command_view.enter, core.quit
    context.ime_editing, context.ime_location = ime.editing, ime.last_location
    context.clip, context.redraw = core.clip_rect_stack, core.redraw
    core.docs, context.views = {}, {}
    config.transitions = false
    core.root_view = RootView()
    core.root_view.root_node.is_primary_node = true
    core.root_view.size.x, core.root_view.size.y = 500, 400
    context.node = core.root_view.root_node
    context.node:add_view(View())
    context.docked = View()
    context.node:add_view(context.docked)
    core.command_view.enter = function(_, label, options)
      context.prompt, context.options = label, options
    end
    context.quits = 0
    core.quit = function() context.quits = context.quits + 1 end
    ime.reset()
  end)

  test.after_each(function(context)
    for _, view in ipairs(context.views) do view:hide_floating() end
    for _, doc in ipairs(core.docs) do doc:on_close() end
    if context.path then os.remove(context.path) end
    core.root_view, core.active_view, core.last_active_view, core.next_active_view = context.root, context.active, context.last, context.next
    core.docs, config.transitions = context.docs, context.transitions
    core.command_view.enter, core.quit = context.enter, context.quit
    ime.editing, ime.last_location = context.ime_editing, context.ime_location
    system.chdir(context.cwd)
    core.clip_rect_stack, core.redraw = context.clip, context.redraw
  end)

  test.test("typed text reaches a focused floating DocView once", function(context)
    local view = document(context)
    core.on_event("textinput", "x")
    test.equal(view.doc:get_text(1, 1, 1, math.huge), "x")
  end)

  test.test("focused descendants receive text without container forwarding", function(context)
    local container = View()
    context.views[#context.views + 1] = container
    container:set_floating_bounds(40, 40, 250, 180)
    container:set_floating(true, { focus = "show" })
    container.capture_text_input = true
    container:show_floating()
    local view = DocView(Doc())
    core.docs[#core.docs + 1] = view.doc
    view.parent = container
    local forwarded = 0
    container.on_text_input = function(_, text)
      forwarded = forwarded + 1
      view:on_text_input(text)
    end
    core.set_active_view(view)
    core.on_event("textinput", "x")
    test.equal(view.doc:get_text(1, 1, 1, math.huge), "x")
    test.equal(forwarded, 0)
    test.ok(command.perform("root:close"))
    test.not_ok(container.floating_visible)
    test.equal(core.active_view, context.docked)
  end)

  test.test("context menus capture text without editing the document", function(context)
    local view = document(context)
    local menu = ContextMenu()
    context.views[#context.views + 1] = menu
    menu:show_items({ { text = "Action", command = function() end } }, 40, 40)
    core.on_event("textinput", "x")
    test.equal(view.doc:get_text(1, 1, 1, math.huge), "")
    menu:hide()
    core.on_event("textinput", "x")
    test.equal(view.doc:get_text(1, 1, 1, math.huge), "x")
  end)

  test.test("unhandled popup capture falls through once", function(context)
    local view = document(context)
    local overlay = View()
    context.views[#context.views + 1] = overlay
    overlay:set_floating_bounds(0, 0, 100, 100)
    overlay:set_floating(true, { focus = "none" })
    overlay.capture_text_input = true
    local calls = 0
    overlay.on_text_input = function() calls = calls + 1; return false end
    overlay:show_floating()
    core.on_event("textinput", "x")
    test.equal(calls, 1)
    test.equal(view.doc:get_text(1, 1, 1, math.huge), "x")
  end)

  test.test("IME reaches focused floating descendants and ignores passive captures", function(context)
    local view = document(context)
    local calls = {}
    view.capture_text_input = true
    view.on_ime_text_editing = function(_, text)
      calls[#calls + 1] = text
    end
    local overlay = View()
    context.views[#context.views + 1] = overlay
    overlay:set_floating(true, { interactive = false, focus = "none" })
    overlay.capture_text_input = true
    overlay:show_floating()
    core.on_event("textediting", "é", 0, 0)
    test.equal(#calls, 1)
    test.equal(calls[1], "é")
    core.on_event("textinput", "é")
    test.equal(view.doc:get_text(1, 1, 1, math.huge), "é")
  end)

  for _, name in ipairs { "root:close", "root:close-or-quit" } do
    test.test(name .. " targets the focused floating document", function(context)
      local view = document(context)
      test.ok(command.perform(name))
      test.not_ok(view.floating_visible)
      test.not_nil(context.node:get_view_idx(context.docked))
      test.equal(core.active_view, context.docked)
      test.equal(context.quits, 0)
    end)
  end

  test.test("dirty floating documents can cancel or confirm Close", function(context)
    local view = document(context)
    view.doc:insert(1, 1, "edited")
    test.ok(command.perform("root:close"))
    test.equal(context.prompt, "Unsaved Changes; Confirm Close")
    test.ok(view.floating_visible)
    if context.options.cancel then context.options.cancel() end
    test.ok(view.floating_visible)
    test.not_nil(context.node:get_view_idx(context.docked))
    context.options.submit("", { text = "Close Without Saving" })
    test.not_ok(view.floating_visible)
  end)

  test.test("tab and pane commands require a docked focus target", function(context)
    local view = document(context)
    for _, name in ipairs {
      "root:move-tab-left", "root:move-tab-right", "root:switch-to-next-tab",
      "root:switch-to-previous-tab", "root:switch-to-tab-1", "root:split-right",
      "root:switch-to-left", "root:grow", "root:shrink"
    } do
      test.not_ok(command.is_valid(name), name)
      test.not_ok(command.perform(name), name)
      test.equal(core.active_view, view)
    end
    -- Explicit tab targets from pointer commands remain valid.
    test.ok(command.is_valid("root:switch-to-next-tab", context.node))
    view:hide_floating()
    test.ok(command.perform("root:move-tab-left"))
    test.equal(context.node.views[1], context.docked)
  end)

  test.test("confirmation closes the view at its current placement", function(context)
    local view = document(context)
    local confirm, calls
    view.try_close = function(_, callback) confirm = callback end
    test.ok(core.root_view:close_view(view, function() calls = (calls or 0) + 1 end))
    view:set_floating(false)
    context.node:add_view(view)
    confirm()
    test.is_nil(context.node:get_view_idx(view))
    test.equal(calls, 1)
    test.not_nil(context.node:get_view_idx(context.docked))
  end)

  test.test("Delete File closes docked and floating references", function(context)
    local view = document(context, true)
    local docked = DocView(view.doc)
    context.node:add_view(docked)
    core.set_active_view(view)
    test.ok(command.perform("file:delete"))
    test.not_ok(view.floating_visible)
    test.is_nil(context.node:get_view_idx(docked))
    test.is_nil(system.get_file_info(context.path))
    test.not_nil(context.node:get_view_idx(context.docked))
  end)

  for _, action in ipairs { "Cancel", "Close Without Saving", "Save And Close" } do
    test.test("Delete File waits for " .. action, function(context)
      local view = document(context, true)
      context.node:add_view(DocView(view.doc))
      core.set_active_view(view)
      view.doc:insert(1, 1, "edited ")
      test.ok(command.perform("file:delete"))
      test.equal(context.prompt, "Unsaved Changes; Confirm Close")
      test.ok(system.get_file_info(context.path))
      test.ok(view.floating_visible)
      if action == "Cancel" then
        if context.options.cancel then context.options.cancel() end
        test.ok(view.floating_visible)
        test.ok(system.get_file_info(context.path))
      else
        context.options.submit("", { text = action })
        test.not_ok(view.floating_visible)
        test.is_nil(system.get_file_info(context.path))
      end
      test.not_nil(context.node:get_view_idx(context.docked))
    end)
  end
  test.test("a popup created during update requests its first drawable frame", function(context)
    local root = core.root_view
    root:update(); root:update()
    local parent = View()
    context.views[#context.views + 1] = parent
    parent:set_floating(true, { focus = "none" })
    parent:set_floating_bounds(10, 10, 100, 100)
    parent:show_floating()
    root:update()
    local child, draws
    parent.update = function()
      if child then return end
      child, draws = View(), 0
      context.views[#context.views + 1] = child
      child.update = function() end
      child.draw = function() draws = draws + 1 end
      child:set_floating(true, { owner = parent, focus = "none" })
      child:set_floating_bounds(20, 20, 80, 80)
      child:show_floating()
    end
    local function paint()
      renderer.begin_frame(core.window)
      core.clip_rect_stack = {{0, 0, 500, 400}}
      renderer.set_clip_rect(0, 0, 500, 400)
      core.redraw = false
      root:draw()
      renderer.end_frame()
    end
    root:update()
    paint()
    test.equal(draws, 0, "a popup must update before drawing")
    root:update()
    test.ok(core.redraw, "its first update must request the skipped draw")
    paint()
    test.equal(draws, 1)
    root:update()
    test.not_ok(core.redraw, "a settled popup must not keep drawing")
  end)

end)

test.describe("workspace docks", function()
  test.before_each(function(context)
    context.root, context.active, context.last, context.next = core.root_view, core.active_view, core.last_active_view, core.next_active_view
    context.transitions, context.redraw = config.transitions, core.redraw
    context.animation_type, context.animation_rate = config.animation_type, config.animation_rate
    context.fps, context.core_fps = config.fps, core.fps
    config.transitions = false
    core.root_view = RootView()
    local root = core.root_view
    root.root_node.is_primary_node = true
    root.size.x, root.size.y = 1000, 700
    context.document = View()
    root.root_node:add_view(context.document)
    root:initialize_docks()
    root:update()
  end)

  test.after_each(function(context)
    core.root_view:cancel_mouse_capture()
    for _, popup in ipairs(core.root_view:floating_snapshot()) do popup:hide_floating() end
    core.root_view, core.active_view, core.last_active_view, core.next_active_view = context.root, context.active, context.last, context.next
    config.transitions, core.redraw = context.transitions, context.redraw
    config.animation_type, config.animation_rate = context.animation_type, context.animation_rate
    config.fps, core.fps = context.fps, context.core_fps
  end)

  local function panel(name)
    local view = View()
    function view:get_name() return name end
    return view
  end

  test.test("empty docks reserve no space and ordinary additions preserve focus", function(context)
    local root = core.root_view
    for _, side in ipairs { "top", "right", "bottom", "left" } do
      local dock = root:get_dock(side)
      test.equal(#dock.views, 0)
      test.not_ok(dock:should_show_tabs())
    end
    test.equal(context.document.size.x, root.size.x)
    test.equal(root:get_document_node().size.y, root.size.y)
    local view = panel("Files")
    local dock = root:add_dock_view(view, "left")
    root:add_dock_view(view, "left")
    root:update()
    test.equal(#dock.views, 1)
    test.equal(core.active_view, context.document)
    test.not_ok(dock:should_show_tabs())
    test.equal(view.size.x, 250 * SCALE)
    test.equal(root:get_document_node(), root:get_primary_node())
  end)

  for _, animation_type in ipairs { "linear", "constant" } do
    for _, side in ipairs { "left", "right", "top", "bottom" } do
      test.test(animation_type .. " " .. side .. " dock follows an ordinary view's size animation", function()
        local root, view = core.root_view, panel("Animated")
        local axis = (side == "left" or side == "right") and "x" or "y"
        view.size.x, view.size.y = 200, 120
        local target = view.size[axis]
        function view:update()
          View.update(self)
          self:move_towards(self.size, axis, target)
        end
        local dock = root:add_dock_view(view, side)
        root:update()
        config.transitions, config.animation_type, config.animation_rate = true, animation_type, 1
        config.fps, core.fps = 60, 60
        local original = target
        target = 0
        root:update()
        test.ok(dock.size[axis] > 0 and dock.size[axis] < original)
        target = original
        local previous = dock.size[axis]
        root:update()
        test.ok(dock.size[axis] > previous and dock.size[axis] < original)
        for _ = 1, 80 do root:update() end
        test.near(dock.size[axis], original, 0.01)
        root.size[axis] = 150
        target = original * 2
        for _ = 1, 80 do root:update() end
        test.ok(dock.size[axis] < target)
        test.near(view.dock_size[axis] * SCALE, target, 0.01)
        core.redraw = false
        root:update()
        test.not_ok(core.redraw)
        root.size[axis] = 1000
        root:update()
        test.near(dock.size[axis], target, 0.01)
      end)

      test.test(animation_type .. " " .. side .. " dock follows unchanged Widget show and hide animations", function()
        local Widget = require "widget"
        local root, view = core.root_view, Widget(nil, false)
        local axis = (side == "left" or side == "right") and "x" or "y"
        view:set_size(200, 120)
        view:show()
        local dock = root:add_dock_view(view, side)
        root:update()
        local original = dock.size[axis]
        config.transitions, config.animation_type, config.animation_rate = true, animation_type, 1
        config.fps, core.fps = 60, 60
        view:hide_animated(axis ~= "x", axis ~= "y")
        root:update()
        test.ok(dock.size[axis] > 0 and dock.size[axis] < original)
        for _ = 1, 80 do root:update() end
        test.not_ok(view:is_visible())
        test.equal(dock.size[axis], 0)
        view:show_animated(axis ~= "x", axis ~= "y")
        root:update()
        test.ok(dock.size[axis] > 0 and dock.size[axis] < original)
        for _ = 1, 80 do root:update() end
        test.near(dock.size[axis], original, 0.01)
        test.equal(#view.animations, 0)
      end)

      test.test(animation_type .. " " .. side .. " closing dock stops at its replacement's size", function(context)
        local Widget = require "widget"
        local root = core.root_view
        local axis = (side == "left" or side == "right") and "x" or "y"
        config.transitions, config.animation_type, config.animation_rate = true, animation_type, 1
        config.fps, core.fps = 60, 60
        for _, replacement_size in ipairs { 160 * SCALE, 500 * SCALE } do
          local replacement, outgoing = panel("Replacement"), Widget(nil, false)
          replacement.size[axis] = replacement_size
          local dock = root:add_dock_view(replacement, side)
          outgoing:set_size(400 * SCALE, 300 * SCALE)
          outgoing:show()
          root:add_dock_view(outgoing, side)
          root:update()
          local original = dock.size[axis]
          local previous = math.max(original, replacement_size)
          outgoing:hide_animated(axis ~= "x", axis ~= "y")
          for _ = 1, 80 do
            root:update()
            test.ok(dock.size[axis] >= replacement_size - 0.01)
            test.ok(dock.size[axis] <= previous + 0.01)
            previous = dock.size[axis]
          end
          test.equal(dock.active_view, replacement)
          test.near(dock.size[axis], replacement_size, 0.01)
          test.near(outgoing.dock_size[axis] * SCALE, original, 0.01)
          test.not_ok(outgoing:is_visible())
          test.equal(#outgoing.animations, 0)
          test.equal(core.active_view, context.document)
          core.redraw = false
          root:update()
          test.not_ok(core.redraw)
          root:remove_dock_view(outgoing)
          root:remove_dock_view(replacement)
          root:update()
        end
      end)
    end
  end

  test.test("nonzero resizing remains independent of other views and old closing targets", function()
    local root, replacement, view = core.root_view, panel("Wide"), panel("Resizing")
    replacement.size.x, view.size.x = 500 * SCALE, 400 * SCALE
    local target = view.size.x
    function view:update()
      View.update(self)
      if target then self:move_towards(self.size, "x", target) end
    end
    local dock = root:add_dock_view(replacement, "left")
    root:add_dock_view(view, "left")
    root:update()
    config.transitions, config.animation_type, config.animation_rate = true, "linear", 1
    config.fps, core.fps = 60, 60
    target = 120 * SCALE
    for _ = 1, 80 do root:update() end
    test.equal(dock.active_view, view)
    test.near(dock.size.x, target, 0.01)
    target = 0
    root:update()
    test.near(dock.size.x, 500 * SCALE, 0.01)
    target = nil
    root:set_dock_size("left", 140 * SCALE)
    root:update()
    test.equal(dock.active_view, view)
    test.near(dock.size.x, 140 * SCALE, 0.01)
    test.equal(replacement.dock_size.x, 500)
  end)

  test.test("closing skips hidden replacements and detachment selects the same successor", function()
    local Widget = require "widget"
    local root, replacement, hidden, outgoing = core.root_view, panel("Visible"), panel("Hidden"), Widget(nil, false)
    replacement.size.x, hidden.size.x, hidden.visible = 180 * SCALE, 500 * SCALE, false
    local dock = root:add_dock_view(replacement, "left")
    root:add_dock_view(hidden, "left", { activate = false })
    outgoing:set_size(400 * SCALE, 300 * SCALE)
    outgoing:show()
    root:add_dock_view(outgoing, "left")
    root:update()
    local original_hide = outgoing.hide
    function outgoing:hide()
      root:remove_dock_view(self)
      original_hide(self)
    end
    config.transitions, config.animation_type, config.animation_rate = true, "linear", 1
    config.fps, core.fps = 60, 60
    outgoing:hide_animated(false, true)
    for _ = 1, 80 do
      root:update()
      test.ok(dock.size.x >= 180 * SCALE - 0.01)
    end
    test.equal(dock.active_view, replacement)
    test.equal(hidden.visible, false)
    test.is_nil(root:get_dock_for_view(outgoing))
    test.near(dock.size.x, 180 * SCALE, 0.01)
  end)

  for _, side in ipairs { "left", "top" } do
    test.test(side .. " closing handoff honors viewport limits without losing saved sizes", function()
      local Widget = require "widget"
      local root, replacement, outgoing = core.root_view, panel("Replacement"), Widget(nil, false)
      local axis = side == "left" and "x" or "y"
      local opposite = side == "left" and "right" or "bottom"
      root.size[axis] = 350 * SCALE
      replacement.size[axis] = 180 * SCALE
      local dock = root:add_dock_view(replacement, side)
      local other = panel("Opposite")
      other.size[axis] = 150 * SCALE
      root:add_dock_view(other, opposite)
      root:update()
      local final_size = dock.size[axis]
      test.ok(final_size < 180 * SCALE)
      outgoing:set_size(400 * SCALE, 400 * SCALE)
      outgoing:show()
      root:add_dock_view(outgoing, side)
      root:update()
      config.transitions, config.animation_type, config.animation_rate = true, "linear", 1
      config.fps, core.fps = 60, 60
      local previous = dock.size[axis]
      outgoing:hide_animated(axis ~= "x", axis ~= "y")
      for _ = 1, 80 do
        root:update()
        test.ok(dock.size[axis] >= final_size - 0.01)
        test.ok(dock.size[axis] <= previous + 0.01)
        previous = dock.size[axis]
      end
      test.equal(dock.active_view, replacement)
      test.near(dock.size[axis], final_size, 0.01)
      test.equal(#outgoing.animations, 0)
      test.equal(replacement.dock_size[axis], 180)
      root.size[axis] = 1000 * SCALE
      for _ = 1, 80 do root:update() end
      test.near(dock.size[axis], 180 * SCALE, 0.01)
      core.redraw = false
      root:update()
      test.not_ok(core.redraw)
    end)
  end

  test.test("sides span the workspace while top and bottom fit between them", function()
    local root = core.root_view
    for _, side in ipairs { "left", "right", "top", "bottom" } do
      root:add_dock_view(panel(side), side)
      root:set_dock_size(side, 120)
    end
    root:update()
    local left, right = root:get_dock("left"), root:get_dock("right")
    local top, bottom = root:get_dock("top"), root:get_dock("bottom")
    test.equal(left.size.y, root.size.y)
    test.equal(right.size.y, root.size.y)
    test.equal(top.position.x, left.size.x + style.divider_size)
    test.equal(bottom.position.x, top.position.x)
    test.equal(top.size.x, bottom.size.x)
    test.equal(right.position.x + right.size.x, root.size.x)
    test.ok(bottom.position.y > top.position.y)
  end)

  test.test("selection restores independent sizes and hiding preserves views and stable nodes", function(context)
    local root, a, b = core.root_view, panel("Files"), panel("Search")
    local dock = root:add_dock_view(a, "left")
    root:set_dock_size("left", 180)
    root:add_dock_view(b, "left", { activate = false })
    test.equal(dock.active_view, a)
    root:activate_dock_view(b)
    root:update()
    test.equal(core.active_view, b)
    test.equal(b.size.x, 250 * SCALE)
    root:set_dock_size("left", 210)
    root:activate_dock_view(a, false)
    root:update()
    test.equal(a.size.x, 180)
    root:activate_dock_view(b)
    root:update()
    test.equal(b.size.x, 210)
    root:set_dock_visible("left", false)
    root:update()
    test.equal(core.active_view, context.document)
    test.equal(dock.size.x, 0)
    test.equal(#dock.views, 2)
    test.equal(dock.active_view, b)
    root:set_dock_visible("left", true)
    root:update()
    test.equal(dock.size.x, 210)
    test.equal(root:get_dock("left"), dock)
    root:remove_dock_view(a)
    root:remove_dock_view(b)
    root:update()
    test.equal(root:get_dock("left"), dock)
    test.equal(#dock.views, 0)
    test.equal(dock.size.x, 0)
    test.not_ok(root:remove_dock_view(b))
  end)

  test.test("each registered view keeps its own splits when selected or moved", function()
    local root, tree, search, toolbar = core.root_view, panel("Files"), panel("Search"), panel("Toolbar")
    toolbar.size.y = 30
    local dock = root:add_dock_view(tree, "left")
    local toolbar_node = dock:split("up", toolbar, { y = true })
    local layout = dock.dock_layouts[tree]
    local tree_node = root.root_node:get_node_for_view(tree)
    root:add_dock_view(search, "left")
    root:update()
    test.equal(search.position.y, dock.position.y + dock.dock_header.height)
    test.equal(root.root_node:get_child_overlapping_point(search.position.x + 5, search.position.y + 5).active_view, search)
    root:activate_dock_view(tree)
    root:update()
    test.equal(root.root_node:get_child_overlapping_point(toolbar.position.x + 5, toolbar.position.y + 5), toolbar_node)
    test.equal(tree.position.y, toolbar.position.y + toolbar.size.y + style.divider_size)
    root:move_dock_view(tree, "bottom")
    root:update()
    test.equal(root:get_dock("bottom").dock_layouts[tree], layout)
    test.equal(root.root_node:get_node_for_view(tree), tree_node)
    test.equal(root:get_dock_for_view(toolbar), root:get_dock("bottom"))
    test.equal(root:get_dock("left").active_view, search)
    test.equal(root.root_node:get_node_for_view(toolbar), toolbar_node)
  end)

  test.test("hiding clears descendant focus, capture, and popups in per-view splits", function(context)
    local root, owner, auxiliary = core.root_view, panel("Owner"), panel("Auxiliary")
    local dock = root:add_dock_view(owner, "right")
    dock:split("down", auxiliary)
    local child = View(); child.parent = auxiliary
    local popup = View()
    popup:set_floating(true, { owner = auxiliary, focus = "none" })
    root:update()
    popup:show_floating()
    core.set_active_view(child)
    root:grab_mouse("left", auxiliary)
    root:set_dock_visible("right", false)
    test.is_nil(root.grab)
    test.not_ok(popup.floating_visible)
    test.equal(core.active_view, context.document)
  end)

  test.test("dock headers switch between tabs and dropdown without repeated measurement", function()
    local root, a, b = core.root_view, panel("Files"), panel("Project Search")
    local dock = root:add_dock_view(a, "top")
    root:add_dock_view(b, "top")
    root:update()
    test.not_ok(dock.dock_header.compact)
    local widths = dock.dock_header.widths
    core.redraw = false
    root.root_node:update_layout()
    test.equal(dock.dock_header.widths, widths)
    test.not_ok(core.redraw)
    root.size.x = 120
    root:update()
    test.ok(dock.dock_header.compact)
    local x, y = dock.position.x + 4, dock.position.y + dock.dock_header.height / 2
    root:on_mouse_pressed("left", x, y, 1)
    test.ok(dock.dock_menu.show_context_menu)
    test.equal(#dock.dock_menu.items, 2)
    dock.dock_menu:hide()
    root:on_mouse_pressed("left", dock.position.x + dock.size.x - 2, y, 1)
    test.not_ok(dock.dock_visible)
    test.equal(#dock.views, 2)
  end)

  test.test("document commands avoid dock subviews and document closure retains all docks", function(context)
    local root, view = core.root_view, panel("Tool")
    local dock = root:add_dock_view(view, "left")
    local documents = root:get_document_node()
    core.set_active_view(view)
    test.equal(root:get_active_node_default(), root:get_primary_node())
    test.equal(core.active_view, context.document)
    root:close_all_docviews(false)
    test.equal(root:get_document_node(), documents)
    test.equal(root:get_dock("left"), dock)
    test.equal(dock.active_view, view)
    test.equal(root:get_primary_node().active_view, context.document)
  end)

  test.test("small viewports constrain docks without overwriting requested sizes", function()
    local root = core.root_view
    for _, side in ipairs { "left", "right", "top", "bottom" } do
      root:add_dock_view(panel(side), side)
      root:set_dock_size(side, 400)
    end
    root.size.x, root.size.y = 140, 120
    root:update()
    for _, side in ipairs { "left", "right", "top", "bottom" } do
      local dock = root:get_dock(side)
      test.equal(dock.active_view.dock_size[dock.locked.x and "x" or "y"], 400 / SCALE)
      test.ok(dock.size.x >= 0 and dock.size.y >= 0)
      test.ok(dock.active_view.size.x >= 0 and dock.active_view.size.y >= 0)
    end
    root.size.x, root.size.y = 1400, 1100
    root:update()
    test.equal(root:get_dock("left").size.x, 400)
    test.equal(root:get_dock("bottom").size.y, 400)
  end)

  test.test("view widths and heights remain independent across selection and moves", function()
    local root, narrow, wide = core.root_view, panel("Files"), panel("Search")
    narrow.size.x, narrow.size.y = 180 * SCALE, 120 * SCALE
    wide.size.x, wide.size.y = 400 * SCALE, 300 * SCALE
    local dock = root:add_dock_view(narrow, "left")
    root:add_dock_view(wide, "left")
    root:update()
    test.equal(dock.size.x, 400 * SCALE)
    root:activate_dock_view(narrow, false)
    root:update()
    test.equal(dock.size.x, 180 * SCALE)
    root:activate_dock_view(wide, false)
    root:set_dock_size("left", 500 * SCALE)
    root:update()
    test.equal(dock.size.x, 500 * SCALE)
    root:activate_dock_view(narrow, false)
    root:update()
    test.equal(dock.size.x, 180 * SCALE)
    root:move_dock_view(wide, "bottom")
    root:update()
    test.equal(root:get_dock("bottom").size.y, 300 * SCALE)
    root:set_dock_size("bottom", 120 * SCALE)
    root:update()
    test.equal(wide.dock_size.y, 120)
    root.size.x, root.size.y = 160, 150
    root:update()
    test.ok(root:get_dock("bottom").size.y < 120 * SCALE)
    test.equal(wide.dock_size.y, 120)
  end)

  test.test("ownership checks reject attached and floating views without changing registration", function(context)
    local root, view = core.root_view, panel("Floating")
    test.error(function() root:add_dock_view(context.document, "right") end)
    view:set_floating(true)
    view:show_floating()
    test.error(function() root:add_dock_view(view, "right") end)
    view:hide_floating()
    root:add_dock_view(view, "right")
    test.error(function() root:add_dock_view(view, "left") end)
    test.equal(#root:get_dock("left").views, 0)
    test.equal(#root:get_dock("right").views, 1)
  end)
end)

test.describe("dock document safeguards", function()
  test.test("closing a registered layout confirms duplicated dirty document references once", function()
    local previous_root, active, last, next_view = core.root_view, core.active_view, core.last_active_view, core.next_active_view
    local enter = core.command_view.enter
    local ok, err = pcall(function()
      local root = RootView()
      core.root_view = root
      root.root_node.is_primary_node = true
      root.size.x, root.size.y = 800, 600
      local owner, doc = View(), Doc()
      doc:insert(1, 1, "unsaved")
      local dock = root:add_dock_view(owner, "bottom")
      dock:split("right", DocView(doc))
      dock:split("down", DocView(doc))
      local prompts, submit = 0
      core.command_view.enter = function(_, _, options)
        prompts, submit = prompts + 1, options.submit
      end
      root:close_view(owner)
      test.equal(prompts, 1)
      test.equal(root:get_dock_for_view(owner), dock)
      submit("", { text = "Close Without Saving" })
      test.equal(prompts, 1)
      test.equal(#dock.views, 0)
      test.equal(#core.get_views_referencing_doc(doc), 0)
    end)
    core.command_view.enter = enter
    core.root_view, core.active_view, core.last_active_view, core.next_active_view = previous_root, active, last, next_view
    test.ok(ok, err)
  end)
end)

test.describe("dock rendering and scale", function()
  test.before_each(function(context)
    context.root, context.active, context.last, context.next = core.root_view, core.active_view, core.last_active_view, core.next_active_view
    context.transitions, context.redraw = config.transitions, core.redraw
    local scale = require "plugins.scale"
    context.scale = scale.get()
    context.style = {}
    for _, name in ipairs { "divider_size", "scrollbar_size", "expanded_scrollbar_size",
      "minimum_thumb_size", "contracted_scrollbar_margin", "expanded_scrollbar_margin", "caret_width", "tab_width" } do
      context.style[name] = style[name]
    end
    context.padding = { x = style.padding.x, y = style.padding.y }
    context.margin, context.wheel = style.margin.tab.top, config.mouse_wheel_scroll
    context.fonts = {}
    for _, name in ipairs { "font", "big_font", "icon_font", "icon_big_font" } do
      context.fonts[name] = style[name]:get_size()
    end
    config.transitions = false
    core.root_view = RootView()
    core.root_view.size.x, core.root_view.size.y = 1200, 900
    core.root_view:initialize_docks()
  end)

  test.after_each(function(context)
    local scale = require "plugins.scale"
    scale.set(context.scale)
    for key, value in pairs(context.style) do style[key] = value end
    style.padding.x, style.padding.y = context.padding.x, context.padding.y
    style.margin.tab.top, config.mouse_wheel_scroll = context.margin, context.wheel
    for name, size in pairs(context.fonts) do style[name]:set_size(size) end
    core.root_view:cancel_mouse_capture()
    for _, popup in ipairs(core.root_view:floating_snapshot()) do popup:hide_floating() end
    core.root_view, core.active_view, core.last_active_view, core.next_active_view = context.root, context.active, context.last, context.next
    config.transitions, core.redraw = context.transitions, context.redraw
  end)

  for _, factor in ipairs { 1, 1.25, 1.5, 2 } do
    test.test("fits widget borders and rescales both directions at " .. factor, function(context)
      local scale = require "plugins.scale"
      local Widget = require "widget"
      local TextBox = require "widget.textbox"
      local root, widget = core.root_view, Widget(nil, false)
      local input = TextBox(widget, "editable", "Type here")
      input:set_size(140, 28)
      input:set_position(10, 10)
      widget:show()
      function widget:get_name() return "Controls" end
      local dock = root:add_dock_view(widget, "left")
      root:add_dock_view(View(), "left", { activate = false })
      root:set_dock_size("left", 250 * context.scale)
      root:update(); root:update()
      local base_height = dock.dock_header.height
      scale.set(context.scale * factor)
      root:update(); root:update()
      local x, y, width, height = widget:get_floating_bounds()
      test.near(dock.size.x, 250 * context.scale * factor, 0.01)
      test.near(x, dock.position.x, 0.01)
      test.near(y, dock.position.y + dock.dock_header.height, 0.01)
      test.near(width, dock.size.x, 0.01)
      test.near(height + dock.dock_header.height, dock.size.y, 0.01)
      local px, py = input.position.x + 8, input.position.y + input.size.y / 2
      root:on_mouse_moved(px, py, 0, 0)
      root:on_mouse_pressed("left", px, py, 1)
      root:on_mouse_released("left", px, py)
      test.equal(core.active_view, input.textview)
      local window = renwindow.create("Dock borders", 1200, 900)
      local clips = core.clip_rect_stack
      core.clip_rect_stack = { { 0, 0, 1200, 900 } }
      renderer.begin_frame(window)
      renderer.set_clip_rect(0, 0, 1200, 900)
      root:draw()
      renderer.end_frame()
      local capture = renderer.to_canvas(window, 0, 0, 1200, 900)
      local pixel = { capture:get_pixels(math.floor(x + width / 2), 899, 1, 1):byte(1, 3) }
      core.clip_rect_stack = clips
      test.same(pixel, { style.text[1], style.text[2], style.text[3] })
      scale.set(context.scale)
      root:update(); root:update()
      test.near(dock.size.x, 250 * context.scale, 0.01)
      test.equal(dock.dock_header.height, base_height)
    end)
  end
end)
