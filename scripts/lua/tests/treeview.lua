local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local RootView = require "core.rootview"
local style = require "core.style"
local test = require "core.test"
local tree = require "plugins.treeview"
local ToolbarView = require "plugins.toolbarview"
local TreeView = getmetatable(tree)
local menu = tree.contextmenu

local function replace_fields(target, source)
  for key in pairs(target) do target[key] = nil end
  for key, value in pairs(source) do target[key] = value end
end

local function right_click(context)
  local x, y = tree.position.x + 25, tree.position.y + style.padding.y + tree:get_item_height() / 2
  core.on_event("mousemoved", x, y, 0, 0)
  test.equal(tree.hovered_item, context.items[1])
  core.on_event("mousepressed", "right", x, y, 1)
  test.ok(menu.show_context_menu)
  core.root_view:update()
  core.on_event("mousereleased", "right", x, y)
  test.equal(tree.hovered_item, context.items[1])
  core.root_view:update()
end

local function click_command(name)
  for _, item, x, y, w, h in menu:each_item() do
    if item.command == name then
      x, y = x + w / 2, y + h / 2
      core.on_event("mousemoved", x, y, 0, 0)
      core.on_event("mousepressed", "left", x, y, 1)
      core.on_event("mousereleased", "left", x, y)
      return
    end
  end
  test.fail("Missing menu command: " .. name)
end

---Render the tree through its normal text and scrollbar drawing paths.
local function draw_tree()
  renderer.begin_frame(core.window)
  local ok, err = pcall(tree.draw, tree)
  renderer.end_frame()
  test.ok(ok, err)
end

---Allow drawing-derived extents to reach the next scrollbar update.
local function settle_tree()
  for _ = 1, 3 do
    core.root_view:update()
    draw_tree()
  end
end

test.describe("treeview context menu", function()
  test.before_each(function(context)
    context.root, context.active, context.last, context.next = core.root_view, core.active_view, core.last_active_view, core.next_active_view
    context.transitions, context.highlight = config.transitions, config.plugins.treeview.highlight_focused_file
    context.redraw = core.redraw
    context.toolbar_position = config.plugins.treeview.toolbar_position
    context.tree = {}
    for key, value in pairs(tree) do context.tree[key] = value end
    context.open_in_system = common.open_in_system
    context.find = command.map["project-search:find"]
    context.compare = command.map["treeview:select-for-compare"]
    context.menu_sets = #menu.itemset
    context.hovered_command = command.map["treeview-test:hovered"]
    replace_fields(tree, TreeView())
    tree.contextmenu = menu
    config.transitions, config.plugins.treeview.highlight_focused_file = false, false
    core.root_view = RootView()
    core.root_view.root_node.is_primary_node = true
    core.root_view.size.x, core.root_view.size.y = 900, 600
    core.active_view = core.root_view.root_node.active_view
    tree.node = core.root_view.root_node:split("left", tree, { x = true }, true)
    local project = core.root_project()
    context.items = {
      { name = "view.lua", filename = "data/core/view.lua", type = "file", depth = 1,
        abs_filename = DATADIR .. PATHSEP .. "core" .. PATHSEP .. "view.lua", project = project },
      { name = "rootview.lua", filename = "data/core/rootview.lua", type = "file", depth = 1,
        abs_filename = DATADIR .. PATHSEP .. "core" .. PATHSEP .. "rootview.lua", project = project }
    }
    tree.each_item = function(self)
      local i, h = 0, self:get_item_height()
      local x, y = self:get_content_offset()
      self.count_lines = #context.items
      return function()
        i = i + 1
        if context.items[i] then
          return context.items[i], x, y + style.padding.y + (i - 1) * h, self.size.x, h
        end
      end
    end
    core.root_view:update()
    core.root_view:update()
  end)

  test.after_each(function(context)
    menu:hide()
    if tree.tooltip_view then tree.tooltip_view:hide_floating() end
    replace_fields(tree, context.tree)
    core.root_view, core.active_view, core.last_active_view, core.next_active_view = context.root, context.active, context.last, context.next
    config.transitions, config.plugins.treeview.highlight_focused_file = context.transitions, context.highlight
    core.redraw = context.redraw
    config.plugins.treeview.toolbar_position = context.toolbar_position
    common.open_in_system = context.open_in_system
    command.map["project-search:find"] = context.find
    command.map["treeview:select-for-compare"] = context.compare
    command.map["treeview-test:hovered"] = context.hovered_command
    while #menu.itemset > context.menu_sets do table.remove(menu.itemset) end
  end)

  for _, position in ipairs { "left", "top", "bottom", "right" } do
    test.test("hovers and clicks the full tree width with the toolbar on the " .. position, function(context)
      tree:set_toolbar_position(position)
      tree:attach_toolbar(ToolbarView())
      core.root_view:update()
      core.root_view:update()
      local item = context.items[1]
      local opened
      tree.open_doc = function(_, path) opened = path end
      local y = tree.position.y + style.padding.y + tree:get_item_height() / 2
      local right = tree.position.x + tree.size.x - style.expanded_scrollbar_size - 8
      if position == "left" then test.ok(right > tree.size.x) end
      for x = right, tree.position.x + 8, -8 do
        core.on_event("mousemoved", x, y, -8, 0)
        test.equal(core.root_view.overlapping_view, tree)
        test.equal(core.root_view.root_node:get_child_overlapping_point(x, y), tree.node)
        test.equal(tree.hovered_item, item)
        tree.selected_item, opened = nil, nil
        core.on_event("mousepressed", "left", x, y, 1)
        core.on_event("mousereleased", "left", x, y)
        test.equal(tree.selected_item, item)
        test.equal(opened, core.normalize_to_project_dir(item.abs_filename))
        test.is_nil(core.root_view.dragged_divider)
      end
      local x = tree.position.x + tree.size.x + style.divider_size + 8
      core.on_event("mousemoved", x, y, 8, 0)
      test.is_nil(tree.hovered_item)
      test.ok(core.root_view.overlapping_view ~= tree)
    end)

    test.test("hides horizontal overflow when resizing the tree with the toolbar on the " .. position, function(context)
      tree:set_toolbar_position(position)
      tree:attach_toolbar(ToolbarView())
      context.items[1].name = "a moderately long file name.lua"
      tree:set_target_size("x", 100)
      settle_tree()
      test.equal(tree.position.x > 0, position == "left")
      local width = tree.scroll_width
      test.ok(width > tree.size.x)
      local _, _, _, height = tree.h_scrollbar:get_thumb_rect()
      test.ok(height > 0)

      tree.scroll.to.x = 20
      settle_tree()
      test.equal(tree.scroll.x, 20)
      test.equal(tree.scroll_width, width)
      tree:set_target_size("x", width + style.padding.x + 1)
      settle_tree()
      test.equal(tree.scroll.x, 0)
      test.equal(tree.scroll.to.x, 0)
      test.equal(tree.scroll_width, width)
      _, _, _, height = tree.h_scrollbar:get_thumb_rect()
      test.equal(height, 0)

      tree:set_target_size("x", 100)
      settle_tree()
      _, _, _, height = tree.h_scrollbar:get_thumb_rect()
      test.ok(height > 0)
    end)

    test.test("remeasures shorter item names with the toolbar on the " .. position, function(context)
      tree:set_toolbar_position(position)
      tree:attach_toolbar(ToolbarView())
      context.items[1].name = "a very long file name that extends well beyond the treeview width.lua"
      settle_tree()
      local _, _, _, height = tree.h_scrollbar:get_thumb_rect()
      test.ok(height > 0)
      tree.scroll.to.x = 40
      settle_tree()
      test.equal(tree.scroll.x, 40)
      context.items[1].name = "a.lua"
      core.redraw = false
      draw_tree()
      test.ok(core.redraw, "A changed extent must schedule the scrollbar's next frame")
      settle_tree()
      test.ok(tree.scroll_width < tree.size.x)
      test.equal(tree.scroll.x, 0)
      test.equal(tree.scroll.to.x, 0)
      _, _, _, height = tree.h_scrollbar:get_thumb_rect()
      test.equal(height, 0)
      core.redraw = false
      draw_tree()
      test.not_ok(core.redraw, "A settled extent must not keep requesting frames")
    end)
  end

  test.test("keeps the context after right release transfers hover to the menu", function(context)
    right_click(context)
    for _ = 1, 3 do core.root_view:update() end
    test.ok(menu.show_context_menu)
    test.equal(core.active_view, tree)
    core.on_event("keypressed", "escape")
    test.not_ok(menu.show_context_menu)
    test.not_ok(menu.floating_visible)
  end)

  for _, visible in ipairs { false, true } do
    test.test("hides a " .. (visible and "visible" or "pending") .. " path tooltip while the menu is open", function(context)
      local x, y = tree.position.x + 25, tree.position.y + style.padding.y + tree:get_item_height() / 2
      core.on_event("mousemoved", x, y, 0, 0)
      local function draw()
        renderer.begin_frame(core.window)
        local ok, err = pcall(core.root_view.draw, core.root_view)
        renderer.end_frame()
        test.ok(ok, err)
      end
      if visible then
        tree.tooltip.begin = system.get_time() - 1
        core.root_view:update()
        draw()
        test.ok(tree.tooltip_view.floating_visible)
      end
      core.on_event("mousepressed", "right", x, y, 1)
      test.ok(menu.show_context_menu)
      test.equal(tree.tooltip.alpha, 0)
      test.is_nil(tree.tooltip.x)
      test.not_ok(tree.tooltip_view and tree.tooltip_view.floating_visible)
      core.on_event("mousereleased", "right", x, y)
      for _ = 1, 3 do
        tree.tooltip.begin = system.get_time() - 1
        core.root_view:update()
        draw()
        test.equal(tree.tooltip.alpha, 0)
        test.not_ok(tree.tooltip_view and tree.tooltip_view.floating_visible)
        test.equal(tree.hovered_item, context.items[1])
      end
      core.on_event("keypressed", "escape")
      core.root_view:update()
      test.equal(tree.tooltip.alpha, 0)
      test.ok(tree.tooltip.x)
      tree.tooltip.begin = system.get_time() - 1
      core.root_view:update()
      draw()
      test.ok(tree.tooltip.alpha > 0)
      test.ok(tree.tooltip_view.floating_visible)
    end)
  end

  test.test("uses the clicked file rather than a different selected file", function(context)
    tree.selected_item = context.items[2]
    local opened
    common.open_in_system = function(path) opened = path end
    right_click(context)
    test.ok(menu.show_context_menu)
    click_command("treeview:open-in-system")
    test.equal(opened, context.items[1].abs_filename)
    test.equal(tree.selected_item, context.items[2])
    test.not_ok(menu.show_context_menu)
  end)

  test.test("searches the clicked directory after the pointer enters the menu", function(context)
    context.items[1].type = "dir"
    context.items[1].abs_filename = DATADIR .. PATHSEP .. "core"
    local path
    command.add(nil, { ["project-search:find"] = function(value) path = value end })
    right_click(context)
    click_command("treeview:search-in-directory")
    test.equal(path, context.items[1].abs_filename)
    test.not_ok(menu.show_context_menu)
  end)

  test.test("outside dismissal releases the target for ordinary commands", function(context)
    tree.selected_item = context.items[2]
    local opened
    common.open_in_system = function(path) opened = path end
    right_click(context)
    core.on_event("mousepressed", "left", 800, 500, 1)
    core.on_event("mousereleased", "left", 800, 500)
    test.not_ok(menu.show_context_menu)
    core.set_active_view(tree)
    command.perform("treeview:open-in-system")
    test.equal(opened, context.items[2].abs_filename)
  end)

  test.test("keeps the clicked file available to DiffView's menu extension", function(context)
    tree.selected_item = context.items[2]
    local selected
    command.map["treeview:select-for-compare"] = {
      predicate = context.compare.predicate,
      perform = function(path) selected = path end
    }
    right_click(context)
    click_command("treeview:select-for-compare")
    test.equal(selected, context.items[1].abs_filename)
    test.is_nil(tree.context_item)
    test.is_nil(tree.context_command_item)
  end)

  test.test("preserves legacy hover predicates and handlers as the mouse moves", function(context)
    tree.selected_item = context.items[2]
    local opened
    command.add(function() return tree.hovered_item ~= nil end, {
      ["treeview-test:hovered"] = function() opened = tree.hovered_item.abs_filename end
    })
    menu:register(function() return tree.hovered_item ~= nil end, {
      { text = "Plugin action", command = "treeview-test:hovered" }
    })
    right_click(context)
    local count = #menu.items
    local x, y = tree.position.x + 5, tree.position.y + style.padding.y + tree:get_item_height() * 1.5
    core.on_event("mousemoved", x, y, 0, 0)
    core.root_view:update()
    test.equal(tree.hovered_item, context.items[1])
    test.equal(#menu.items, count)
    click_command("treeview-test:hovered")
    test.equal(opened, context.items[1].abs_filename)
    test.is_nil(tree.hovered_item)
  end)

  test.test("preserves a legacy plugin's target through submenu dispatch", function(context)
    local opened
    command.add(function() return tree.hovered_item ~= nil end, {
      ["treeview-test:hovered"] = function() opened = tree.hovered_item.abs_filename end
    })
    menu:register(function() return tree.hovered_item ~= nil end, {
      { text = "Plugin submenu", items = {
        { text = "Action", command = "treeview-test:hovered" }
      } }
    })
    right_click(context)
    for i, item in ipairs(menu.items) do
      if item.text == "Plugin submenu" then menu.selected = i end
    end
    core.on_event("keypressed", "right")
    test.ok(menu.child_menu.show_context_menu)
    core.root_view:update()
    core.on_event("keypressed", "return")
    test.equal(opened, context.items[1].abs_filename)
    test.not_ok(menu.show_context_menu)
    test.equal(tree.hovered_item, context.items[1])
    test.is_nil(tree.context_item)
  end)

  test.test("dismisses on a left click elsewhere in the tree", function(context)
    right_click(context)
    local x, y = tree.position.x + 5, tree.position.y + tree.size.y - 20
    core.on_event("mousepressed", "left", x, y, 1)
    core.on_event("mousereleased", "left", x, y)
    test.not_ok(menu.show_context_menu)
    test.is_nil(tree.context_item)
    test.is_nil(tree.hovered_item)
  end)

  test.test("reopens at a new right-click position with that item's commands", function(context)
    context.items[2].type = "dir"
    context.items[2].abs_filename = DATADIR .. PATHSEP .. "core"
    right_click(context)
    -- The menu freezes hover while open, so reopening must hit-test the new press.
    local x, y = tree.position.x + 5, tree.position.y + style.padding.y + tree:get_item_height() * 1.5
    core.on_event("mousemoved", x, y, 0, 0)
    test.equal(tree.hovered_item, context.items[1])
    core.on_event("mousepressed", "right", x, y, 1)
    core.on_event("mousereleased", "right", x, y)
    core.root_view:update()
    test.ok(menu.show_context_menu)
    test.equal(tree:get_context_item(), context.items[2])
    test.equal(menu.position.x, x)
    test.equal(menu.position.y, y)
    local path
    command.add(nil, { ["project-search:find"] = function(value) path = value end })
    click_command("treeview:search-in-directory")
    test.equal(path, context.items[2].abs_filename)
  end)
end)
