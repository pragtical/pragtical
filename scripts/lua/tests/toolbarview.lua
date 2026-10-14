local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local test = require "core.test"
local Doc = require "core.doc"
local DocView = require "core.docview"
local MenuView = require "core.menuview"
local RootView = require "core.rootview"
local View = require "core.view"
local ToolbarView = require "plugins.toolbarview"
local TreeView = getmetatable(require "plugins.treeview")
local scale = require "plugins.scale"

local function settle()
  core.root_view:update()
  core.root_view:update()
end

local function point_for_item(toolbar, name)
  for item, x, y, w, h in toolbar:each_item() do
    if item.command == name then
      local x1, y1 = math.max(x, toolbar.position.x), math.max(y, toolbar.position.y)
      local x2 = math.min(x + w, toolbar.position.x + toolbar.size.x)
      local y2 = math.min(y + h, toolbar.position.y + toolbar.size.y)
      return (x1 + x2) / 2, (y1 + y2) / 2, item
    end
  end
  test.fail("Toolbar item is not visible: " .. name)
end

test.describe("toolbar layout", function()
  test.before_each(function(context)
    context.root, context.active, context.last, context.next = core.root_view, core.active_view, core.last_active_view, core.next_active_view
    context.menu, context.menubar = core.menu_view, config.show_menubar
    context.transitions, context.position = config.transitions, config.plugins.treeview.toolbar_position
    context.highlight = config.plugins.treeview.highlight_focused_file
    context.modkeys, context.scale = keymap.modkeys, scale.get()
    context.tooltip, context.tooltip_mode = core.status_view.tooltip, core.status_view.tooltip_mode
    context.commands = {}
    config.transitions, config.show_menubar = false, false
    config.plugins.treeview.toolbar_position = "left"
    config.plugins.treeview.highlight_focused_file = false
    keymap.modkeys = {}
    core.root_view = RootView()
    core.root_view.root_node.is_primary_node = true
    core.root_view.size.x, core.root_view.size.y = 900, 600
    core.active_view = core.root_view.root_node.active_view
    context.document = DocView(Doc())
    core.root_view:get_primary_node():add_view(context.document)
    core.menu_view = MenuView()
    core.root_view.root_node:split("up", core.menu_view, { y = true })
    context.documents = core.root_view:get_primary_node()
    context.tree, context.toolbar = TreeView(), ToolbarView()
    context.tree.target_size = 200
    context.tree.default_size = 200
    context.tree.node = context.documents:split("left", context.tree, { x = true }, true)
    context.documents = context.tree.node:get_parent_node(core.root_view.root_node).b
    context.tree:attach_toolbar(context.toolbar)
    settle()
  end)

  test.after_each(function(context)
    core.menu_view.menu:hide()
    context.tree:hide_tooltip()
    context.toolbar:on_mouse_left()
    if context.standalone then context.standalone:on_mouse_left() end
    core.root_view:cancel_mouse_capture()
    scale.set(context.scale)
    for name, previous in pairs(context.commands) do command.map[name] = previous or nil end
    core.root_view, core.active_view, core.last_active_view, core.next_active_view = context.root, context.active, context.last, context.next
    core.menu_view, config.show_menubar = context.menu, context.menubar
    config.transitions, config.plugins.treeview.toolbar_position = context.transitions, context.position
    config.plugins.treeview.highlight_focused_file = context.highlight
    keymap.modkeys = context.modkeys
    core.status_view.tooltip, core.status_view.tooltip_mode = context.tooltip, context.tooltip_mode
  end)

  test.test("changes standalone orientation without changing its position or tree docking", function(context)
    local toolbar = ToolbarView()
    context.standalone = toolbar
    toolbar.position.x, toolbar.position.y = 123, 65
    local docking = context.tree.toolbar_layout.group
    local icon_w, icon_h = toolbar:get_icon_size()
    for _, orientation in ipairs { "horizontal", "vertical" } do
      toolbar.size.x, toolbar.size.y = 300, 160
      toolbar.scroll.x, toolbar.scroll.y = 5, 5
      toolbar.scroll.to.x, toolbar.scroll.to.y = 5, 5
      core.root_view:grab_mouse("left", toolbar)
      toolbar:set_orientation(orientation)
      test.is_nil(core.root_view.grab)
      test.equal(toolbar.scroll.x, 0)
      test.equal(toolbar.scroll.y, 0)
      toolbar:update()
      test.equal(toolbar.position.x, 123)
      test.equal(toolbar.position.y, 65)
      test.equal(toolbar.orientation, orientation)
      if orientation == "horizontal" then
        test.equal(toolbar.size.x, 300)
        test.equal(toolbar.size.y, common.round(icon_h + style.padding.y * 2))
      else
        test.equal(toolbar.size.x, common.round(icon_w + style.padding.x * 2))
        test.equal(toolbar.size.y, 160)
      end
      test.equal(context.tree.toolbar_position, "left")
      test.equal(config.plugins.treeview.toolbar_position, "left")
      test.equal(context.tree.toolbar_layout.group, docking)
      test.is_nil(core.root_view.root_node:get_node_for_view(toolbar))
    end
  end)

  for _, orientation in ipairs { "vertical", "horizontal" } do
    test.test("scrolls and clicks a standalone " .. orientation .. " toolbar while the tree is hidden", function(context)
      local toolbar = ToolbarView()
      context.standalone = toolbar
      toolbar:set_orientation(orientation)
      context.tree.visible, context.toolbar.visible = false, false
      core.root_view.size.x, core.root_view.size.y = 260, 100
      local vertical = orientation == "vertical"
      local node = context.documents:split(vertical and "left" or "up", toolbar,
        { x = vertical, y = not vertical })
      local selected
      toolbar.toolbar_commands = {}
      for index = 1, 10 do
        local value, name = index, "toolbar-test:standalone-" .. index
        context.commands[name] = command.map[name] or false
        command.add(function() return core.active_view == context.document end, {
          [name] = function() selected = value end
        })
        toolbar.toolbar_commands[index] = { symbol = "M", command = name }
      end
      settle()
      test.ok(toolbar:is_visible())
      test.equal(toolbar.position.x, node.position.x)
      test.equal(toolbar.position.y, node.position.y)
      local iterator = toolbar:each_item()
      local _, x1, y1 = iterator()
      local _, x2, y2 = iterator()
      test.ok(vertical and x1 == x2 and y2 > y1 or y1 == y2 and x2 > x1)
      local x, y = point_for_item(toolbar, "toolbar-test:standalone-1")
      core.on_event("mousemoved", x, y, 0, 0)
      core.on_event("mousewheel", -100, 0)
      settle()
      test.ok(toolbar.scroll[vertical and "y" or "x"] > 0)
      x, y = point_for_item(toolbar, "toolbar-test:standalone-10")
      core.on_event("mousepressed", "left", x, y, 1)
      core.on_event("mousereleased", "left", x, y)
      test.equal(selected, 10)
      test.equal(core.active_view, context.document)
      test.equal(context.tree.toolbar_position, "left")
      test.equal(config.plugins.treeview.toolbar_position, "left")
    end)
  end

  for _, position in ipairs { "left", "top", "bottom", "right" } do
    local vertical = position == "left" or position == "right"
    test.test("docks " .. position .. " and keeps the tree divider resizable", function(context)
      local toolbar, tree = context.toolbar, context.tree
      context.tree:set_toolbar_position(position)
      settle()
      test.equal(tree.toolbar_position, position)
      test.equal(toolbar.orientation, vertical and "vertical" or "horizontal")
      local width = vertical and 200 or common.round(math.max(200, toolbar:get_min_width()))
      test.equal(tree.size.x, width)
      test.equal(tree.target_size, 200)
      if position == "left" then
        test.ok(toolbar.position.x + toolbar.size.x <= tree.position.x)
        test.equal(toolbar.position.y, tree.position.y)
        test.equal(toolbar.size.y, tree.size.y)
      elseif position == "right" then
        test.equal(toolbar.position.x + toolbar.size.x, core.root_view.position.x + core.root_view.size.x)
        test.equal(context.documents.position.x + context.documents.size.x + style.divider_size, toolbar.position.x)
        test.ok(tree.position.x + tree.size.x < toolbar.position.x)
        test.equal(toolbar.position.y, tree.position.y)
        test.equal(toolbar.size.y, tree.size.y)
      elseif position == "top" then
        test.ok(toolbar.position.y + toolbar.size.y <= tree.position.y)
        test.equal(toolbar.position.x, tree.position.x)
        test.equal(toolbar.size.x, tree.size.x)
      else
        test.ok(tree.position.y + tree.size.y <= toolbar.position.y)
        test.equal(toolbar.position.x, tree.position.x)
        test.equal(toolbar.size.x, tree.size.x)
      end
      local iterator = toolbar:each_item()
      local _, x1, y1 = iterator()
      local _, x2, y2 = iterator()
      test.equal(vertical and x1 == x2 or y1 == y2, true)
      test.ok(vertical and y2 > y1 or x2 > x1)

      local thickness = vertical and toolbar.size.x or toolbar.size.y
      local x = tree.position.x + tree.size.x + style.divider_size + 2
      local y = tree.position.y + tree.size.y / 2
      test.not_nil(core.root_view.root_node:get_divider_overlapping_point(x, y))
      core.on_event("mousepressed", "left", x, y, 1)
      test.not_nil(core.root_view.dragged_divider)
      core.on_event("mousemoved", x + 40, y, 40, 0)
      core.on_event("mousereleased", "left", x + 40, y)
      settle()
      test.ok(tree.size.x > width)
      test.equal(vertical and toolbar.size.x or toolbar.size.y, thickness)
      if position == "right" then
        core.root_view.size.x = 760
        settle()
        test.equal(toolbar.position.x + toolbar.size.x, core.root_view.position.x + core.root_view.size.x)
      end
      test.equal(core.active_view, context.document)
    end)

    test.test(position .. " visibility follows the tree only for horizontal layouts", function(context)
      local toolbar, tree = context.toolbar, context.tree
      context.tree:set_toolbar_position(position)
      tree.visible = false
      settle()
      test.equal(tree.size.x, 0)
      test.equal(toolbar:is_visible(), vertical)
      test.equal((vertical and toolbar.size.x or toolbar.size.y) > 0, vertical)
      test.equal(toolbar.visible, true)
      toolbar:toggle_visible()
      tree.visible = true
      settle()
      test.not_ok(toolbar:is_visible())
      test.equal(vertical and toolbar.size.x or toolbar.size.y, 0)
      toolbar:toggle_visible()
      settle()
      test.ok(toolbar:is_visible())
      test.ok((vertical and toolbar.size.x or toolbar.size.y) > 0)
    end)

    test.test("scrolls overflow " .. position .. " and clicks the revealed command", function(context)
      local toolbar, tree = context.toolbar, context.tree
      context.tree:set_toolbar_position(position)
      core.root_view.size.y = 100
      tree:set_target_size("x", 60)
      local selected, enabled
      enabled = true
      toolbar.toolbar_commands = {}
      for index = 1, 10 do
        local value, name = index, "toolbar-test:action-" .. index
        context.commands[name] = command.map[name] or false
        command.add(function() return enabled and core.active_view == context.document end, {
          [name] = function() selected = value end
        })
        toolbar.toolbar_commands[index] = { symbol = "M", command = name }
      end
      settle()
      local x, y = point_for_item(toolbar, "toolbar-test:action-1")
      core.on_event("mousemoved", x, y, 0, 0)
      test.equal(toolbar.hovered_item, toolbar.toolbar_commands[1])
      core.on_event("mousewheel", -100, 0)
      settle()
      local axis = vertical and "y" or "x"
      test.ok(toolbar.scroll[axis] > 0)
      test.ok(toolbar.hovered_item ~= toolbar.toolbar_commands[1])
      x, y = point_for_item(toolbar, "toolbar-test:action-10")
      core.on_event("mousemoved", x, y, 0, 0)
      test.equal(core.status_view.tooltip[1], command.prettify_name("toolbar-test:action-10"))
      enabled = false
      core.on_event("mousepressed", "left", x, y, 1)
      core.on_event("mousereleased", "left", x, y)
      test.is_nil(selected)
      enabled = true
      core.on_event("mousepressed", "left", x, y, 1)
      core.on_event("mousereleased", "left", x, y)
      test.equal(selected, 10)
      test.equal(core.active_view, context.document)
      core.root_view.size.y = 800
      tree:set_target_size("x", 700)
      settle()
      test.equal(toolbar.scroll[axis], 0)
      test.equal(toolbar.scroll.to[axis], 0)
    end)
  end

  test.test("fits horizontal toolbars only while the tree uses its default width", function(context)
    local toolbar, tree = context.toolbar, context.tree
    local default = tree.default_size
    local custom = default - 40
    for _, position in ipairs { "top", "bottom" } do
      context.tree:set_toolbar_position(position)
      settle()
      test.equal(tree.size.x, common.round(math.max(default, toolbar:get_min_width())))
      test.equal(tree.target_size, default)
      toolbar:toggle_visible()
      settle()
      test.equal(tree.size.x, default)
      toolbar:toggle_visible()
      settle()
      test.equal(tree.size.x, common.round(math.max(default, toolbar:get_min_width())))
      tree:set_target_size("x", custom)
      settle()
      test.equal(tree.size.x, custom)
      context.tree:set_toolbar_position("left")
      context.tree:set_toolbar_position(position)
      settle()
      test.equal(tree.size.x, custom)
      tree:set_target_size("x", default)
      settle()
      test.equal(tree.size.x, common.round(math.max(default, toolbar:get_min_width())))
      context.tree:set_toolbar_position("left")
      settle()
      test.equal(tree.size.x, default)
    end
  end)

  test.test("applies the position setting without replacing tree or document state", function(context)
    local toolbar, tree = context.toolbar, context.tree
    context.documents:split("right", View())
    context.documents.divider = 0.37
    core.set_active_view(context.document)
    local doc_node = core.root_view.root_node:get_node_for_view(context.document)
    local selected, expanded = {}, { kept = true }
    tree.selected_item, tree.expanded = selected, expanded
    tree.scroll.y, tree.scroll.to.y, tree.last_scroll_y = 16, 16, 16
    local option
    for _, candidate in ipairs(config.plugins.treeview.config_spec) do
      if candidate.path == "toolbar_position" then option = candidate end
    end
    test.not_nil(option)
    for _, position in ipairs { "bottom", "top", "right", "left", "right", "bottom", "left" } do
      option.on_apply(position)
      settle()
      test.equal(tree.toolbar_position, position)
      test.equal(toolbar.orientation, (position == "left" or position == "right") and "vertical" or "horizontal")
      test.equal(config.plugins.treeview.toolbar_position, position)
      test.equal(core.root_view.root_node:get_node_for_view(context.document), doc_node)
      test.equal(context.documents.divider, 0.37)
      test.equal(tree.selected_item, selected)
      test.equal(tree.expanded, expanded)
      test.equal(tree.scroll.y, 16)
      test.equal(core.active_view, context.document)
      local count = 0
      for _, view in ipairs(core.root_view.root_node:get_children()) do
        if view == toolbar then count = count + 1 end
      end
      test.equal(count, 1)
    end
  end)

  test.test("uses horizontal wheel motion and leaves modified wheel bindings available", function(context)
    local toolbar = context.toolbar
    context.tree:set_toolbar_position("top")
    context.tree:set_target_size("x", 60)
    settle()
    local x, y = point_for_item(toolbar, "menu-bar:toggle")
    core.on_event("mousemoved", x, y, 0, 0)
    core.on_event("mousewheel", 0, -1)
    settle()
    test.ok(toolbar.scroll.x > 0)
    local offset = toolbar.scroll.x
    for _, key in ipairs { "ctrl", "cmd", "alt" } do
      keymap.modkeys[key] = true
      test.not_ok(core.root_view:on_mouse_wheel(-1, 0))
      test.equal(toolbar.scroll.to.x, offset)
      keymap.modkeys[key] = nil
    end
    core.on_event("mousewheel", 100, 0)
    settle()
    test.equal(toolbar.scroll.x, 0)
  end)

  test.test("keeps docking available after closing document splits", function(context)
    local other = DocView(Doc())
    context.documents:split("right", other)
    core.root_view.root_node:close_all_docviews()
    settle()
    local primary = core.root_view:get_primary_node()
    test.equal(primary, context.documents)
    test.equal(primary.type, "leaf")
    local document = DocView(Doc())
    primary:add_view(document)
    for _, position in ipairs { "top", "bottom", "right", "left" } do
      context.tree:set_toolbar_position(position)
      settle()
      test.equal(core.root_view:get_primary_node(), primary)
      test.equal(core.root_view.root_node:get_node_for_view(document), primary)
      test.equal(core.active_view, document)
      test.ok(context.toolbar:is_visible())
    end
  end)

  for _, position in ipairs { "left", "right" } do
    test.test("keeps the " .. position .. " hamburger accessible with the tree and menu hidden", function(context)
      context.tree:set_toolbar_position(position)
      context.tree.visible = false
      settle()
      test.not_ok(core.menu_view.visible)
      test.equal(core.menu_view.size.y, 0)
      for _, visible in ipairs { true, false } do
        local x, y = point_for_item(context.toolbar, "menu-bar:toggle")
        core.on_event("mousemoved", x, y, 0, 0)
        test.equal(core.status_view.tooltip[4], keymap.get_binding("menu-bar:toggle"))
        core.on_event("mousepressed", "left", x, y, 1)
        core.on_event("mousereleased", "left", x, y)
        settle()
        test.equal(config.show_menubar, visible)
        test.equal(core.menu_view.size.y > 0, visible)
        test.equal(core.active_view, context.document)
      end
      command.perform("menu-bar:open")
      test.ok(core.menu_view.menu.show_context_menu)
    end)
  end

  test.test("clears stale toolbar hover and capture when repositioning", function(context)
    local toolbar = context.toolbar
    local x, y = point_for_item(toolbar, "menu-bar:toggle")
    core.on_event("mousemoved", x, y, 0, 0)
    core.root_view:grab_mouse("left", toolbar)
    context.tree:set_toolbar_position("bottom")
    test.is_nil(core.root_view.grab)
    test.is_nil(toolbar.hovered_item)
    test.not_ok(toolbar.tooltip)
    test.equal(core.active_view, context.document)
  end)

  for _, factor in ipairs { 1, 1.5 } do
    test.test("measures custom icon fonts at scale " .. factor, function(context)
      scale.set(context.scale * factor)
      local toolbar = context.toolbar
      local font = style.icon_big_font:copy(style.icon_big_font:get_size() * 1.4)
      toolbar.toolbar_commands[#toolbar.toolbar_commands + 1] = {
        symbol = "MM", font = font, command = "core:new-doc"
      }
      for _, position in ipairs { "left", "top", "bottom", "right" } do
        context.tree:set_toolbar_position(position)
        settle()
        if position == "left" or position == "right" then
          test.ok(toolbar.size.x >= font:get_width("MM") + style.padding.x * 2 - 0.5)
        else
          test.ok(toolbar.size.y >= font:get_height() + style.padding.y * 2 - 0.5)
          test.equal(context.tree.size.x, common.round(math.max(
            context.tree.default_size, toolbar:get_min_width()
          )))
        end
        toolbar:on_mouse_wheel(-100, 0)
        settle()
        local x, y = point_for_item(toolbar, "core:new-doc")
        test.ok(toolbar:hit_test(x, y))
      end
    end)
  end
end)
