local core = require "core"
local config = require "core.config"
local View = require "core.view"
local RootView = require "core.rootview"
local test = require "core.test"
local CommandView = require "core.commandview"
local Doc = require "core.doc"
local DocView = require "core.docview"
local command = require "core.command"
local style = require "core.style"
local scale = require "plugins.scale"
local TreeView = getmetatable(require "plugins.treeview")
local ToolbarView = require "plugins.toolbarview"
local common = require "core.common"
local ContextMenu = require "core.contextmenu"

---Save exact metrics so scaling tests do not leave rounding changes behind.
---@param context table Test fixture restored by after_each
local function save_scale_metrics(context)
  context.scale_values = { { config, "mouse_wheel_scroll", config.mouse_wheel_scroll } }
  for _, values in ipairs { style, style.padding, style.margin.tab } do
    for key, value in pairs(values) do
      if type(value) == "number" then
        table.insert(context.scale_values, { values, key, value })
      end
    end
  end
  context.font_sizes = {}
  for _, name in ipairs { "font", "big_font", "icon_font", "icon_big_font" } do
    context.font_sizes[style[name]] = style[name]:get_size()
  end
end

---Capture the actual row backgrounds, text, hints and scrollbars through RootView.
---@return canvas frame Rendered editor frame
local function capture_palette()
  local width, height = core.window:get_size()
  core.clip_rect_stack = { { 0, 0, width, height } }
  renderer.begin_frame(core.window)
  renderer.set_clip_rect(0, 0, width, height)
  core.root_view:draw()
  renderer.end_frame()
  return renderer.to_canvas(core.window, 0, 0, width, height)
end

test.describe("commandview floating suggestions", function()
  test.before_each(function(context)
    context.cwd = system.getcwd()
    context.root, context.active, context.last, context.next, context.command = core.root_view, core.active_view, core.last_active_view, core.next_active_view, core.command_view
    context.transitions = config.transitions
    context.fps, context.config_fps, context.animation_type = core.fps, config.fps, config.animation_type
    context.command_transition, context.scroll_transition = config.disabled_transitions.commandview, config.disabled_transitions.scroll
    context.position = config.commandview_position
    context.title, context.menu, context.nag, context.status = core.title_view, core.menu_view, core.nag_view, core.status_view
    context.scale, context.scale_env = scale.get(), os.getenv("PRAGTICAL_SCALE")
    context.clip_rect_stack = core.clip_rect_stack
    context.toolbar_position = config.plugins.treeview.toolbar_position
    context.path_suggest = common.path_suggest
    context.font_get_width = renderer.font.get_width
    context.floating_views, context.docs, context.paths = {}, {}, {}
    config.transitions = false
    config.commandview_position = "bottom"
    core.root_view = RootView(); core.root_view.root_node.is_primary_node = true
    core.root_view.size.x, core.root_view.size.y = 700, 500
    core.command_view = CommandView()
    core.title_view, core.menu_view, core.nag_view, core.status_view = View(), View(), View(), View()
    core.title_view.size.y, core.menu_view.size.y, core.status_view.size.y = 20, 25, 18
    local node = core.root_view.root_node
    node:split("up", core.title_view, { y = true })
    node = node.b
    node:split("up", core.menu_view, { y = true })
    node = node.b
    node:split("up", core.nag_view, { y = true })
    node = node.b:split("down", core.command_view, { y = true })
    node:split("down", core.status_view, { y = true })
    context.view = View()
    core.root_view:get_primary_node():add_view(context.view)
    core.root_view:update(); core.root_view:update()
  end)
  test.after_each(function(context)
    renderer.font.get_width = context.font_get_width
    core.command_view:exit()
    core.command_view:hide_floating()
    core.command_view.suggestions_view:hide_floating()
    if context.tree then context.tree:hide_tooltip() end
    for _, view in ipairs(context.floating_views) do view:hide_floating() end
    for _, doc in ipairs(context.docs) do doc:on_close() end
    for _, path in ipairs(context.paths) do os.remove(path) end
    scale.set(context.scale)
    if context.scale_values then
      for _, saved in ipairs(context.scale_values) do saved[1][saved[2]] = saved[3] end
      for font, size in pairs(context.font_sizes) do font:set_size(size) end
    end
    system.setenv("PRAGTICAL_SCALE", context.scale_env)
    core.root_view, core.active_view, core.last_active_view, core.next_active_view, core.command_view = context.root, context.active, context.last, context.next, context.command
    core.title_view, core.menu_view, core.nag_view, core.status_view = context.title, context.menu, context.nag, context.status
    config.commandview_position = context.position
    config.plugins.treeview.toolbar_position = context.toolbar_position
    core.clip_rect_stack = context.clip_rect_stack
    common.path_suggest = context.path_suggest
    config.transitions = context.transitions
    core.fps, config.fps, config.animation_type = context.fps, context.config_fps, context.animation_type
    config.disabled_transitions.commandview, config.disabled_transitions.scroll = context.command_transition, context.scroll_transition
    system.chdir(context.cwd)
  end)

  test.test("suggestions receive pointer events without replacing prompt focus", function(context)
    local selected
    core.command_view:enter("Pick", {
      suggest = function() return { "first", "second" } end,
      submit = function(text) selected = text end
    })
    core.root_view:update(); core.root_view:update()
    local popup = core.command_view.suggestions_view
    test.ok(popup.floating_visible)
    local x, y, w, h = popup:get_floating_bounds()
    core.on_event("mousemoved", x + w / 2, y + h / 4, 0, 0)
    test.equal(core.active_view, core.command_view)
    core.on_event("mousepressed", "left", x + w / 2, y + h / 4, 1)
    core.on_event("mousereleased", "left", x + w / 2, y + h / 4)
    test.not_nil(selected)
    test.equal(core.active_view, context.view)
    core.root_view:update()
    test.not_ok(popup.floating_visible)
  end)

  for _, name in ipairs { "root:close", "file:delete" } do
    test.test("Escape cancels " .. name .. " for a dirty floating document", function(context)
      local path = core.temp_filename(".txt")
      context.paths[#context.paths + 1] = path
      local file = assert(io.open(path, "wb"))
      file:write("original\n")
      file:close()
      local doc = Doc(path, path)
      context.docs[#context.docs + 1] = doc
      local view = DocView(doc)
      context.floating_views[#context.floating_views + 1] = view
      view:set_floating_bounds(40, 40, 250, 180)
      view:set_floating(true, { focus = "show" })
      view:show_floating()
      doc:insert(1, 1, "edited ")
      test.ok(command.perform(name))
      test.equal(core.active_view, core.command_view)
      test.ok(view.floating_visible)
      test.ok(system.get_file_info(path))
      test.ok(command.perform("command:escape"))
      test.equal(core.active_view, view)
      test.ok(view.floating_visible)
      test.ok(system.get_file_info(path))
    end)
  end
  test.test("scrollbar dragging and wheel scrolling preserve prompt focus", function(context)
    local items = {}
    for i = 1, 80 do items[i] = string.format("entry %02d", i) end
    local submitted = 0
    core.command_view:enter("Pick", {
      suggest = function() return items end,
      submit = function() submitted = submitted + 1 end
    })
    core.root_view:update(); core.root_view:update()
    local popup = core.command_view.suggestions_view
    local old_scroll = popup.scroll.y
    core.on_event("mousemoved", popup.position.x + 10, popup.position.y + 10, 0, 0)
    core.on_event("mousewheel", 2, 0)
    core.root_view:update()
    test.ok(popup.scroll.y < old_scroll)
    local x, y, w, h = popup.v_scrollbar:get_thumb_rect()
    core.on_event("mousemoved", x + w / 2, y + h / 2, 0, 0)
    core.on_event("mousepressed", "left", x + w / 2, y + h / 2, 1)
    test.ok(popup.v_scrollbar.dragging)
    core.on_event("mousemoved", x + w / 2, popup.position.y - 50, 0, -1000)
    core.root_view:update()
    core.on_event("mousereleased", "left", x + w / 2, popup.position.y - 50)
    test.not_ok(popup.v_scrollbar.dragging)
    test.is_nil(core.root_view.grab)
    test.equal(submitted, 0)
    test.equal(core.active_view, core.command_view)
    test.equal(popup.scroll.y, 0)
    core.command_view.suggestion_idx = 1
    core.command_view:move_suggestion_idx(1)
    core.root_view:update()
    local top = (#items - core.command_view.suggestion_idx) * core.command_view:get_suggestion_line_height()
    test.ok(top >= popup.scroll.y and top < popup.scroll.y + popup.size.y)
  end)

  for _, animation in ipairs { "linear", "constant" } do
    test.test("keeps first suggestions anchored during " .. animation .. " opening", function()
      config.transitions, config.animation_type = true, animation
      config.disabled_transitions.commandview, config.disabled_transitions.scroll = false, false
      core.fps, config.fps = 60, 60
      local items = {}
      for i = 1, 80 do items[i] = string.format("entry %02d", i) end
      core.command_view:enter("Pick", { suggest = function() return items end })
      local popup = core.command_view.suggestions_view
      local previous_height, grew = 0, false
      for _ = 1, 45 do
        core.root_view:update()
        if popup.size.y > 0 then
          grew = grew or (previous_height > 0 and popup.size.y > previous_height)
          previous_height = popup.size.y
          test.near(popup.scroll.y, math.max(0, popup:get_scrollable_size() - popup.size.y), 0.001)
          test.near(core.command_view.suggestions_offset, 0, 0.001)
          test.equal(core.command_view.suggestions_first, 1)
          test.equal(core.command_view.suggestion_idx, 1)
        end
      end
      test.ok(grew)
    end)
  end

  for _, position in ipairs { "bottom", "top", "center" } do
    test.test(position .. " places the prompt and results without replacing editor nodes", function(context)
      local root, view = core.root_view, core.command_view
      local editor_node = root.root_node:get_node_for_view(context.view)
      local original_y, original_height = context.view.position.y, context.view.size.y
      config.commandview_position = position
      view:enter("Pick", { suggest = function() return { "first", "second", "third" } end })
      root:update(); root:update()
      test.equal(view.display_position, position)
      test.equal(core.active_view, view)
      test.equal(core.last_active_view, context.view)
      test.equal(root.root_node:get_node_for_view(context.view), editor_node)
      local popup = view.suggestions_view
      if position == "center" then
        test.is_nil(root.root_node:get_node_for_view(view))
        test.ok(view.floating_visible)
        test.equal(context.view.position.y, original_y)
        test.equal(context.view.size.y, original_height)
        local x, y, w, h = view:get_floating_bounds()
        test.near(x + w / 2, root.position.x + root.size.x / 2, 0.01)
        test.near(y + h / 2, root.position.y + root.size.y / 2, 0.01)
      elseif position == "top" then
        test.ok(root.root_node:get_node_for_view(view).locked.y)
        test.near(view.position.y, core.menu_view.position.y + core.menu_view.size.y + style.divider_size, 0.01)
        test.ok(context.view.position.y > original_y)
      else
        test.near(view.position.y + view.size.y + style.divider_size, core.status_view.position.y, 0.01)
      end
      if position == "bottom" then
        test.ok(popup.position.y + popup.size.y <= view.position.y)
        test.ok(view:get_suggestion_row(1) > view:get_suggestion_row(2))
      else
        test.ok(popup.position.y >= view.position.y + view.size.y)
        test.ok(view:get_suggestion_row(1) < view:get_suggestion_row(2))
      end
      core.on_event("keypressed", position == "bottom" and "up" or "down")
      root:update()
      test.equal(view.suggestion_idx, 2)
      test.equal(view:get_text(), "second")
      local y = popup.position.y + view:get_suggestion_row(3) - popup.scroll.y + view:get_suggestion_line_height() / 2
      core.on_event("mousemoved", popup.position.x + 20, y, 0, 0)
      test.equal(view.suggestion_idx, 3)
      test.equal(view:get_text(), "third")
      test.equal(core.active_view, view)
      view:exit()
      root:update(); root:update()
      test.equal(core.active_view, context.view)
      test.not_ok(view.floating_visible)
      test.not_ok(popup.floating_visible)
      test.equal(context.view.position.y, original_y)
      test.equal(context.view.size.y, original_height)
    end)

    test.test(position .. " clicks submit the displayed result exactly once", function(context)
      config.commandview_position = position
      local view, submitted, selected = core.command_view, 0
      view:enter("Pick", {
        suggest = function() return { "first", "second" } end,
        submit = function(text) submitted, selected = submitted + 1, text end
      })
      core.root_view:update(); core.root_view:update()
      local popup = view.suggestions_view
      local x = popup.position.x + popup.size.x / 2
      local y = popup.position.y + view:get_suggestion_row(2) - popup.scroll.y + view:get_suggestion_line_height() / 2
      core.on_event("mousepressed", "left", x, y, 1)
      core.on_event("mousereleased", "left", x, y)
      core.root_view:update()
      test.equal(submitted, 1)
      test.equal(selected, "second")
      test.equal(core.active_view, context.view)
      test.not_ok(popup.floating_visible)
      test.is_nil(core.root_view.grab)
    end)

    test.test(position .. " scrolling and scrollbar capture do not submit or lose focus", function()
      config.commandview_position = position
      local view, items, submitted = core.command_view, {}, 0
      for i = 1, 80 do items[i] = string.format("entry %02d", i) end
      view:enter("Pick", {
        suggest = function() return items end,
        submit = function() submitted = submitted + 1 end
      })
      core.root_view:update(); core.root_view:update()
      local popup = view.suggestions_view
      local old_scroll = popup.scroll.y
      core.on_event("mousemoved", popup.position.x + 10, popup.position.y + 10, 0, 0)
      core.on_event("mousewheel", position == "bottom" and 2 or -2, 0)
      core.root_view:update()
      if position == "bottom" then test.ok(popup.scroll.y < old_scroll)
      else test.ok(popup.scroll.y > old_scroll) end
      local x, y, w, h = popup.v_scrollbar:get_thumb_rect()
      core.on_event("mousemoved", x + w / 2, y + h / 2, 0, 0)
      core.on_event("mousepressed", "left", x + w / 2, y + h / 2, 1)
      test.ok(popup.v_scrollbar.dragging)
      local target = position == "bottom" and popup.position.y - 50 or popup.position.y + popup.size.y + 50
      core.on_event("mousemoved", x + w / 2, target, 0, 1000)
      core.root_view:update()
      core.on_event("mousereleased", "left", x + w / 2, target)
      test.not_ok(popup.v_scrollbar.dragging)
      test.is_nil(core.root_view.grab)
      test.equal(submitted, 0)
      test.equal(core.active_view, view)
      view.suggestion_idx = 1
      core.on_event("keypressed", position == "bottom" and "up" or "down")
      core.root_view:update()
      local top = view:get_suggestion_row(2)
      test.ok(top >= popup.scroll.y and top < popup.scroll.y + popup.size.y)
    end)

    test.test(position .. " preserves hidden-suggestion history navigation", function()
      config.commandview_position = position
      local view = core.command_view
      view:enter("History", {
        text = "original",
        show_suggestions = false,
        suggest = function() return { "first", "second" } end
      })
      core.root_view:update(); core.root_view:update()
      test.not_ok(view.suggestions_view.floating_visible)
      core.on_event("keypressed", "up")
      test.equal(view:get_text(), "first")
      core.on_event("keypressed", "up")
      test.equal(view:get_text(), "second")
      core.on_event("keypressed", "down")
      test.equal(view:get_text(), "first")
      core.on_event("keypressed", "down")
      test.equal(view:get_text(), "original")
    end)

    test.test(position .. " handles empty results, typing, Escape and focus loss", function(context)
      config.commandview_position = position
      local view, cancelled = core.command_view, {}
      local options = {
        suggest = function() return {} end,
        cancel = function(explicit) cancelled[#cancelled + 1] = explicit end
      }
      view:enter("Empty", options)
      core.root_view:update(); core.root_view:update()
      core.on_event("textinput", "text")
      test.equal(view:get_text(), "text")
      test.not_ok(view.suggestions_view.floating_visible)
      core.on_event("keypressed", "escape")
      core.root_view:update()
      test.equal(cancelled[1], true)
      test.equal(core.active_view, context.view)
      test.equal(view:get_text(), "")
      view:enter("Again", options)
      core.root_view:update()
      core.set_active_view(context.view)
      core.root_view:update()
      test.equal(cancelled[2], false)
      test.not_ok(view.floating_visible)
      test.not_ok(view.suggestions_view.floating_visible)
    end)

    test.test(position .. " clips long lists in a small resized window", function()
      config.commandview_position = position
      local view, items = core.command_view, {}
      for i = 1, 80 do items[i] = "entry " .. i end
      view:enter("Pick", { suggest = function() return items end })
      core.root_view:update(); core.root_view:update()
      core.root_view.size.x, core.root_view.size.y = 260, 150
      core.root_view:update(); core.root_view:update()
      local x, y, w, h = view.suggestions_view:get_floating_bounds()
      test.ok(x >= 0 and y >= 0)
      test.ok(x + w <= 260 and y + h <= 150)
      test.ok(h < view.suggestions_view:get_scrollable_size())
      if position == "center" then
        x, y, w, h = view:get_floating_bounds()
        test.ok(x >= style.padding.x and y >= style.padding.y)
        test.ok(x + w <= 260 - style.padding.x)
        test.ok(y + h <= 150 - style.padding.y)
      end
    end)

    for _, animation in ipairs { "linear", "constant" } do
      test.test(position .. " keeps first results anchored during " .. animation .. " opening", function()
        config.commandview_position = position
        config.transitions, config.animation_type = true, animation
        config.disabled_transitions.commandview, config.disabled_transitions.scroll = false, false
        core.fps, config.fps = 60, 60
        local view, items = core.command_view, {}
        for i = 1, 80 do items[i] = "entry " .. i end
        view:enter("Pick", { suggest = function() return items end })
        local popup, previous_height, grew, anchor = view.suggestions_view, 0, false
        for _ = 1, 45 do
          core.root_view:update()
          if popup.size.y > 0 then
            grew = grew or (previous_height > 0 and popup.size.y > previous_height)
            previous_height = popup.size.y
            local scroll = position == "bottom" and math.max(0, popup:get_scrollable_size() - popup.size.y) or 0
            test.near(popup.scroll.y, scroll, 0.001)
            test.equal(view.suggestions_first, 1)
            test.equal(view.suggestion_idx, 1)
            if position == "center" then
              anchor = anchor or view.position.y
              test.near(view.position.y, anchor, 0.001)
            end
          end
        end
        test.ok(grew)
      end)
    end
  end

  test.test("position changes apply to the next prompt and preserve document splits", function(context)
    local root, view = core.root_view, core.command_view
    local node = root:get_primary_node()
    local other = View()
    node:split("right", other)
    node.divider = 0.37
    local first, second = node.a, node.b
    core.set_active_view(context.view)
    for _, position in ipairs { "top", "center", "bottom", "center", "top", "bottom" } do
      config.commandview_position = position
      view:enter("Pick", {})
      root:update(); root:update()
      config.commandview_position = position == "center" and "bottom" or "center"
      root:update()
      test.equal(view.display_position, position)
      test.equal(node.a, first)
      test.equal(node.b, second)
      test.equal(node.divider, 0.37)
      view:exit()
      root:update(); root:update()
      test.equal(core.active_view, context.view)
    end
  end)

  test.test("submission and cancellation callbacks can immediately open another prompt", function(context)
    local view = core.command_view
    config.commandview_position = "center"
    view:enter("First", {
      text = "first",
      submit = function()
        config.commandview_position = "top"
        view:enter("Second", { text = "second" })
      end
    })
    core.root_view:update()
    view:submit()
    core.root_view:update(); core.root_view:update()
    test.equal(view.label, "Second: ")
    test.equal(view:get_text(), "second")
    test.equal(view.display_position, "top")
    test.equal(core.active_view, view)
    view:exit()
    config.commandview_position = "center"
    view:enter("Third", {
      cancel = function()
        view:enter("Fourth", { text = "fourth" })
      end
    })
    core.root_view:update()
    view:exit()
    core.root_view:update(); core.root_view:update()
    test.equal(view:get_text(), "fourth")
    test.equal(view.display_position, "center")
    test.ok(view.floating_visible)
    test.equal(core.active_view, view)
    view:exit()
    test.equal(core.active_view, context.view)
  end)

  for _, toolbar_position in ipairs { "left", "right", "top", "bottom" } do
    test.test("switching prompt placement preserves the " .. toolbar_position .. " tree toolbar layout", function(context)
      local root, view = core.root_view, core.command_view
      local tree, toolbar = TreeView(), ToolbarView()
      context.tree = tree
      -- Layout tests need no project traversal or filesystem watchers.
      tree.each_item = function() return function() end end
      tree.node = root:get_primary_node():split("left", tree, { x = true }, true)
      tree:attach_toolbar(toolbar)
      tree:set_toolbar_position(toolbar_position)
      core.set_active_view(context.view)
      root:update(); root:update()
      local layout, group, tree_node, documents, toolbar_node = tree.toolbar_layout.node,
        tree.toolbar_layout.group, tree.node, tree.toolbar_layout.documents, tree.toolbar_layout.toolbar_node
      local divider = layout.divider
      for _, position in ipairs { "top", "center", "bottom", "top", "bottom" } do
        config.commandview_position = position
        view:enter("Pick", {})
        root:update(); root:update()
        test.equal(tree.toolbar_layout.node, layout)
        test.equal(tree.toolbar_layout.group, group)
        test.equal(tree.toolbar_layout.documents, documents)
        test.equal(tree.toolbar_layout.toolbar_node, toolbar_node)
        test.equal(root.root_node:get_node_for_view(tree), tree_node)
        test.equal(root.root_node:get_node_for_view(toolbar), toolbar_node)
        test.equal(layout.divider, divider)
        test.equal(tree.toolbar_position, toolbar_position)
        if toolbar_position == "right" then
          test.near(toolbar.position.x + toolbar.size.x, root.size.x, 0.01)
        elseif toolbar_position == "left" then
          test.near(toolbar.position.x + toolbar.size.x + style.divider_size, tree.position.x, 0.01)
        elseif toolbar_position == "top" then
          test.near(toolbar.position.y + toolbar.size.y + style.divider_size, tree.position.y, 0.01)
        else
          test.near(tree.position.y + tree.size.y + style.divider_size, toolbar.position.y, 0.01)
        end
        view:exit()
        root:update(); root:update()
        test.equal(core.active_view, context.view)
      end
    end)
  end

  test.test("centered prompts resize and reposition while the UI scale changes", function(context)
    save_scale_metrics(context)
    local root, view = core.root_view, core.command_view
    root.size.x, root.size.y = 1600, 1200
    config.commandview_position = "center"
    view:enter("Pick", { suggest = function() return { "first", "second" } end })
    for _, factor in ipairs { 1, 1.3, 1.5, 1 } do
      scale.set(factor)
      root:update(); root:update()
      local x, y, w, h = view:get_floating_bounds()
      test.near(w, 800 * factor, 0.01)
      test.near(x + w / 2, root.size.x / 2, 0.01)
      test.near(y + h / 2, root.size.y / 2, 0.01)
      test.equal(core.active_view, view)
      test.equal(#root.floating_views, 2)
    end
    root.size.x, root.size.y = 350, 200
    root:update(); root:update()
    local x, y, w, h = view:get_floating_bounds()
    test.near(w, root.size.x - 2 * style.padding.x, 0.01)
    test.near(x + w / 2, root.size.x / 2, 0.01)
    test.near(y + h / 2, root.size.y / 2, 0.01)
  end)

  test.test("centered palette renders a border around both input and results", function()
    config.commandview_position = "center"
    local view = core.command_view
    view:enter("Pick", { suggest = function() return { "first", "second", "third" } end })
    core.root_view:update(); core.root_view:update()
    local width, height = core.window:get_size()
    core.clip_rect_stack = { { 0, 0, width, height } }
    renderer.begin_frame(core.window)
    renderer.set_clip_rect(0, 0, width, height)
    core.root_view:draw()
    renderer.end_frame()
    local frame = renderer.to_canvas(core.window, 0, 0, width, height)
    local x, y, w, h = view:get_floating_bounds()
    local points = {
      { x + w / 2, y }, { x + w / 2, y + h - 1 },
      { x, y + view.size.y / 2 }, { x + w - 1, y + view.size.y / 2 },
      { x, y + h * 0.8 }, { x + w - 1, y + h * 0.8 }
    }
    for _, point in ipairs(points) do
      test.same({ frame:get_pixels(math.floor(point[1]), math.floor(point[2]), 1, 1):byte(1, 3) },
        { style.dim[1], style.dim[2], style.dim[3] })
    end
  end)

  test.test("closing a centered prompt cancels its input without an unsaved-document dialog", function(context)
    config.commandview_position = "center"
    local cancelled
    core.command_view:enter("Pick", {
      text = "temporary input",
      cancel = function(explicit) cancelled = explicit end
    })
    core.root_view:update()
    test.ok(command.perform("root:close"))
    test.equal(cancelled, true)
    test.equal(core.active_view, context.view)
    test.not_ok(core.command_view.floating_visible)
  end)

  test.test("floating removal restores the originating floating editor before cancellation", function(context)
    local editor = DocView(Doc())
    context.docs[#context.docs + 1] = editor.doc
    context.floating_views[#context.floating_views + 1] = editor
    editor:set_floating_bounds(40, 40, 250, 180)
    editor:set_floating(true, { focus = "show" })
    editor:show_floating()
    config.commandview_position = "center"
    local cancelled, view = 0, core.command_view
    view:enter("Pick", {
      cancel = function(explicit)
        cancelled = cancelled + 1
        test.equal(explicit, false)
        test.equal(core.active_view, editor)
      end
    })
    core.root_view:update()
    view:hide_floating()
    test.equal(cancelled, 1)
    test.equal(core.active_view, editor)
    test.not_ok(view.suggestions_view.floating_visible)
    view:enter("Again", {})
    core.root_view:update()
    test.equal(core.active_view, view)
  end)

  test.test("floating close preserves a replacement prompt opened by cancellation", function()
    config.commandview_position = "center"
    local view = core.command_view
    view:enter("First", {
      cancel = function(explicit)
        test.equal(explicit, true)
        view:enter("Second", { text = "replacement" })
      end
    })
    core.root_view:update()
    command.perform("root:close")
    core.root_view:update()
    test.equal(view:get_text(), "replacement")
    test.equal(core.active_view, view)
    test.ok(view.floating_visible)
  end)

  for _, position in ipairs { "bottom", "top", "center" } do
    for _, source in ipairs { "palette", "context menu" } do
      test.test(position .. " draws Rename from the " .. source .. " immediately after a longer list", function(context)
        config.commandview_position = position
        local root, view = core.root_view, core.command_view
        local doc = Doc()
        doc.filename = "original-name.txt"
        context.docs[#context.docs + 1] = doc
        local editor = DocView(doc)
        root:get_primary_node():add_view(editor)
        common.path_suggest = function() return { "renamed.txt", "other.txt" } end
        command.perform("core:find-command")
        root:update(); root:update()
        test.ok(view.suggestions_last > 2)
        if source == "palette" then
          for i, item in ipairs(view.suggestions) do
            if item.command == "file:rename" then view.suggestion_idx = i; break end
          end
          test.equal(view.suggestions[view.suggestion_idx].command, "file:rename")
          view:submit()
        else
          view:exit()
          local menu = ContextMenu()
          context.floating_views[#context.floating_views + 1] = menu
          menu:register("core.docview", { { text = "Rename", command = "file:rename" } })
          menu:show(20, 20)
          menu:call_selected_item(menu.items[1])
        end
        test.equal(view.label, "Rename: ")
        test.equal(#view.suggestions, 2)
        -- A floating owner can show a reused companion after RootView snapshots
        -- its update list, so drawing precedes the companion's next update.
        view:update()
        local width, height = core.window:get_size()
        core.clip_rect_stack = { { 0, 0, width, height } }
        renderer.begin_frame(core.window)
        renderer.set_clip_rect(0, 0, width, height)
        local ok, err = pcall(root.draw, root)
        renderer.end_frame()
        test.ok(ok, err)
        local x, y, w, h = view:get_suggestions_bounds()
        local row = position == "bottom" and h - view:get_suggestion_line_height() / 2 or view:get_suggestion_line_height() / 2
        core.on_event("mousemoved", x + w / 2, y + row, 0, 0)
        test.equal(view.suggestion_idx, 1)
        test.equal(view:get_text(), "renamed.txt")
        view:exit()
        test.equal(core.active_view, editor)
      end)
    end
  end

  for _, position in ipairs { "bottom", "top", "center" } do
    for _, mode in ipairs { "plain", "syntax" } do
      test.test(position .. " clips long " .. mode .. " results before info on selected and unselected rows", function(context)
        save_scale_metrics(context)
        config.commandview_position = position
        local root, view = core.root_view, core.command_view
        if mode == "plain" then
          local items = {}
          for i = 1, 14 do
            items[i] = { text = string.rep("verylong-directory/", 40) .. "commandview.lua", info = "recent file" }
          end
          view:enter("Open File From Project", { suggest = function() return items end })
        else
          local doc = Doc()
          context.docs[#context.docs + 1] = doc
          doc:set_filename("clipping.lua")
          doc:insert(1, 1, string.rep("-- verylong " .. string.rep("W", 200) .. "\n", 14))
          root:get_primary_node():add_view(DocView(doc))
          test.ok(command.perform("doc:go-to-line"))
          view:set_text("verylong")
        end
        for _, factor in ipairs { 1, 1.3 } do
          scale.set(factor)
          root:update(); root:update()
          local rx, ry, rw, rh = view:get_suggestions_bounds()
          local font, lh = view:get_font(), view:get_suggestion_line_height()
          -- Scaling can change the visible range; sample a complete visible row.
          local index = view.suggestions_first + 1
          local x = view:get_line_screen_position()
          local right = rx + rw - style.padding.x - style.expanded_scrollbar_size - SCALE
          local hint_width = font:get_width(view.suggestions[index].info)
          local info_x = math.ceil(right - hint_width - style.padding.x / 2)
          local info_w = math.floor(right) - info_x
          local text_x = math.ceil(x)
          local text_w = math.floor(right - hint_width - style.padding.x) - text_x
          local y = math.ceil(ry + view:get_suggestion_row(index) - view.suggestions_view.scroll.y)
          local height = math.floor(lh) - 1
          test.ok(text_w > 0 and info_w > 0)
          test.ok(view.suggestions_view:get_scrollable_size() > rh)
          for _, selected in ipairs { index, index + 1 } do
            view.suggestion_idx = selected
            local draw_text = view.state.draw_text
            view.state.draw_text = function() end
            local reference = capture_palette()
            view.state.draw_text = draw_text
            local actual = capture_palette()
            test.equal(actual:get_pixels(info_x, y, info_w, height),
              reference:get_pixels(info_x, y, info_w, height), "result text must not paint over the hint or gap")
            test.ok(actual:get_pixels(text_x, y, text_w, height) ~=
              reference:get_pixels(text_x, y, text_w, height), "result text should remain visible before the hint")
          end
        end
      end)
    end
  end

  test.test("custom renderers receive usable text widths and oversized info stays inside its row", function()
    config.commandview_position = "center"
    local root, view = core.root_view, core.command_view
    root.size.x = 330
    local widths = {}
    local items = {
      { text = "with hint", info = "hint" },
      { text = "without hint" },
      { text = "oversized hint", info = string.rep("W", 200) },
      { text = "empty hint", info = "" }
    }
    view:enter("Pick", {
      suggest = function() return items end,
      draw_text = function(item, font, color, x, y, w, h)
        widths[item.text] = w
        -- Even a renderer that ignores w must stay inside its result column.
        renderer.draw_rect(x, y, w + 1000, h, color)
      end
    })
    root:update(); root:update()
    local rx, ry, rw = view:get_suggestions_bounds()
    local x = view:get_line_screen_position()
    local available = rx + rw - style.padding.x - x
    local actual = capture_palette()
    test.near(widths["without hint"], available, 0.01)
    test.near(widths["empty hint"], available, 0.01)
    test.near(widths["with hint"], available - view:get_font():get_width("hint") - style.padding.x, 0.01)
    test.is_nil(widths["oversized hint"])
    local lh = view:get_suggestion_line_height()
    local hint_x = math.ceil(x + widths["with hint"] + style.padding.x / 2)
    local hint_w = math.floor(rx + rw - style.padding.x) - hint_x
    local row_y = math.ceil(ry + view:get_suggestion_row(1))
    view.state.draw_text = function() end
    local reference = capture_palette()
    test.equal(actual:get_pixels(hint_x, row_y, hint_w, math.floor(lh) - 1),
      reference:get_pixels(hint_x, row_y, hint_w, math.floor(lh) - 1))
    local y = math.floor(ry + view:get_suggestion_row(3) + lh / 2)
    test.same({ actual:get_pixels(math.floor(rx + 2), y, 1, 1):byte(1, 3) },
      { style.background3[1], style.background3[2], style.background3[3] })
  end)

  test.test("Go To Line measures each info label once while rendering multiple syntax tokens", function(context)
    local doc = Doc()
    context.docs[#context.docs + 1] = doc
    doc:set_filename("clipping.lua")
    doc:insert(1, 1, "local verylong = 1 + 2 + 3 + 4 + 5 + 6\nlocal verylong_next = true and false\n")
    core.root_view:get_primary_node():add_view(DocView(doc))
    command.perform("doc:go-to-line")
    local view = core.command_view
    view:set_text("verylong")
    core.root_view:update(); core.root_view:update()
    local measured = {}
    for _, item in ipairs(view.suggestions) do measured[item.info] = 0 end
    renderer.font.get_width = function(font, text, ...)
      if measured[text] ~= nil then measured[text] = measured[text] + 1 end
      return context.font_get_width(font, text, ...)
    end
    local suggestions = 0
    local suggest = view.state.suggest
    view.state.suggest = function(...)
      suggestions = suggestions + 1
      return suggest(...)
    end
    capture_palette()
    for _, count in pairs(measured) do test.equal(count, 1) end
    test.equal(suggestions, 0)
  end)

end)
