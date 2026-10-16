local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local style = require "core.style"
local View = require "core.view"
local RootView = require "core.rootview"
local AboutView = require "core.aboutview"
local scale = require "plugins.scale"
local test = require "core.test"

test.describe("About dialog", function()
  test.before_each(function(context)
    context.root, context.active = core.root_view, core.active_view
    context.last, context.next = core.last_active_view, core.next_active_view
    context.transitions = config.transitions
    context.animation_type, context.animation_rate = config.animation_type, config.animation_rate
    context.fps, context.core_fps = config.fps, core.fps
    context.floating_transition = config.disabled_transitions.floating
    context.window_size, context.open = system.get_window_size, common.open_in_system
    context.clip_rect_stack = core.clip_rect_stack
    context.scale, context.scale_env = scale.get(), os.getenv("PRAGTICAL_SCALE")
    context.menu_owner = core.menu_view.menu.floating_options
      and core.menu_view.menu.floating_options.owner
    config.transitions = false
    core.root_view = RootView()
    core.root_view.root_node.is_primary_node = true
    core.root_view.size.x, core.root_view.size.y = system.get_window_size(core.window)
    context.editor = View()
    core.root_view.root_node:add_view(context.editor)
  end)

  test.after_each(function(context)
    core.menu_view.menu:hide()
    for _, view in ipairs(core.root_view:floating_snapshot()) do view:hide_floating() end
    scale.set(context.scale)
    if context.scale_values then
      for _, saved in ipairs(context.scale_values) do saved[1][saved[2]] = saved[3] end
      for font, size in pairs(context.font_sizes) do font:set_size(size) end
    end
    system.setenv("PRAGTICAL_SCALE", context.scale_env)
    core.root_view, core.active_view = context.root, context.active
    core.last_active_view, core.next_active_view = context.last, context.next
    config.transitions = context.transitions
    config.animation_type, config.animation_rate = context.animation_type, context.animation_rate
    config.fps, core.fps = context.fps, context.core_fps
    config.disabled_transitions.floating = context.floating_transition
    system.get_window_size, common.open_in_system = context.window_size, context.open
    core.clip_rect_stack = context.clip_rect_stack
    core.menu_view.menu:set_floating(true, { owner = context.menu_owner or false })
  end)

  test.test("Help opens About and Escape restores editor focus", function(context)
    local help
    for index, entry in ipairs(core.menu_view:entries()) do
      if entry.id == "help" then help = index end
    end
    test.not_nil(help)
    core.menu_view:open(help)
    local menu, about = core.menu_view.menu
    for _, entry in ipairs(menu.items) do
      if entry.command == "core:view-about" then about = entry end
    end
    test.not_nil(about)
    menu:call_selected_item(about)
    local dialog = core.root_view:get_modal_view()
    test.not_nil(dialog)
    test.equal(dialog.title.label, "About Pragtical")
    test.equal(core.active_view, dialog)
    test.not_ok(menu.show_context_menu)
    test.ok(core.root_view.root_node:get_view_idx(context.editor))
    core.on_event("keypressed", "escape")
    test.not_ok(dialog.floating_visible)
    test.equal(core.active_view, context.editor)
  end)

  test.test("reuses one dialog and its contributor rows when reopening", function(context)
    local dialog = AboutView.show_dialog()
    local about = dialog:get_panel().childs[1]
    test.ok(about:extends(AboutView))
    local rows = about.contributors.rows
    test.ok(#rows > 0)
    test.equal(about.version.original_label or about.version.label, "version " .. VERSION)
    test.ok(about.renderer_info.label:find(core.window:get_renderer_info().backend, 1, true))
    test.equal(AboutView.show_dialog(), dialog)
    test.equal(#core.root_view.floating_views, 1)
    dialog.close:on_click()
    test.not_ok(dialog.floating_visible)
    test.equal(core.active_view, context.editor)
    test.equal(AboutView.show_dialog(), dialog)
    core.root_view:update()
    test.equal(about.contributors.rows, rows)
    test.equal(#core.root_view.floating_views, 1)
  end)

  for _, animation_type in ipairs { "linear", "constant" } do
    test.test(animation_type .. " slides on opening, Escape and the close button", function(context)
      local root = core.root_view
      local dialog = AboutView.show_dialog()
      local x, y, width, height = dialog:get_floating_bounds()
      local rows = dialog:get_panel().childs[1].contributors.rows
      dialog:hide()
      config.transitions, config.animation_type, config.animation_rate = true, animation_type, 1
      config.fps, core.fps, config.disabled_transitions.floating = 60, 60, false
      test.equal(AboutView.show_dialog(), dialog)
      local _, opening_y = dialog:get_floating_bounds()
      test.ok(opening_y + height <= root.position.y)
      test.equal(core.active_view, dialog)
      root:update()
      local current_x, current_y, current_width, current_height = dialog:get_floating_bounds()
      test.ok(current_y > opening_y and current_y < y)
      test.near(current_x, x, 0.01)
      test.near(current_width, width, 0.01)
      test.near(current_height, height, 0.01)
      for _ = 1, 80 do root:update() end
      test.is_nil(dialog.floating_transition)
      test.near(select(2, dialog:get_floating_bounds()), y, 0.01)
      core.on_event("keypressed", "escape")
      test.ok(dialog.floating_closing)
      test.ok(dialog.floating_visible)
      test.is_nil(root:get_modal_view())
      test.equal(core.active_view, context.editor)
      root:update()
      test.ok(select(2, dialog:get_floating_bounds()) < y)
      for _ = 1, 80 do root:update() end
      test.not_ok(dialog.floating_visible)
      test.not_ok(dialog.visible)
      AboutView.show_dialog()
      for _ = 1, 80 do root:update() end
      dialog.close:on_click()
      test.ok(dialog.floating_closing)
      test.ok(dialog.floating_visible)
      test.equal(core.active_view, context.editor)
      for _ = 1, 80 do root:update() end
      test.not_ok(dialog.floating_visible)
      test.equal(dialog:get_panel().childs[1].contributors.rows, rows)
    end)
  end

  test.test("floating transition setting disables About slides", function(context)
    config.transitions, config.fps, core.fps = true, 60, 60
    config.disabled_transitions.floating = true
    local dialog = AboutView.show_dialog()
    test.is_nil(dialog.floating_transition)
    test.ok(select(2, dialog:get_floating_bounds()) >= core.root_view.position.y)
    dialog.close:on_click()
    test.not_ok(dialog.floating_visible)
    test.equal(core.active_view, context.editor)
  end)

  test.test("fits a small window without shrinking or losing scrollable content", function()
    system.get_window_size = function() return 360, 280 end
    core.root_view.size.x, core.root_view.size.y = 360, 280
    local dialog = AboutView.show_dialog()
    local about = dialog:get_panel().childs[1]
    local x, y, width, height = dialog:get_floating_bounds()
    test.ok(x >= 0 and y >= 0 and x + width <= 360 and y + height <= 280)
    for _ = 1, 20 do core.root_view:update() end
    test.equal(select(3, dialog:get_floating_bounds()), width)
    test.equal(select(4, dialog:get_floating_bounds()), height)
    test.ok(about.contributors.size.x > 0 and about.contributors.size.y > 0)
    test.ok(about.contributors:get_scrollable_size() > about.contributors.size.y)
    renderer.begin_frame(core.window)
    core.root_view:draw()
    renderer.end_frame()
    about.notebook:set_pane("license")
    for _ = 1, 6 do core.root_view:update() end
    test.equal(about.license:get_h_scrollable_size(), about.license.size.x)
    test.ok(about.license:get_scrollable_size() > about.license.size.y)
    for _, label in ipairs(about.license_labels) do
      test.ok(label.size.x <= about.license_content.size.x)
    end
    about.notebook:set_pane("contributors")

    dialog:hide()
    system.get_window_size = function() return 1000, 800 end
    core.root_view.size.x, core.root_view.size.y = 1000, 800
    test.equal(AboutView.show_dialog(), dialog)
    for _ = 1, 6 do core.root_view:update() end
    local _, _, expanded_width, expanded_height = dialog:get_floating_bounds()
    test.ok(expanded_width > width and expanded_height > height)
    test.ok(about.notebook.size.x > 360)
  end)

  test.test("website and contributor links use the existing handlers", function()
    local opened = {}
    common.open_in_system = function(url) opened[#opened + 1] = url end
    local dialog = AboutView.show_dialog()
    local about = dialog:get_panel().childs[1]
    about.website:on_click()
    about.contributors:on_row_click(1, about.contributors.row_data[1])
    test.equal(opened[1], "https://pragtical.dev")
    test.equal(opened[2], about.contributors.row_data[1])
  end)

  test.test("mouse clicks switch between contributors and the full license", function(context)
    local dialog = AboutView.show_dialog()
    local about = dialog:get_panel().childs[1]
    about.notebook:set_pane("contributors")
    for _ = 1, 6 do core.root_view:update() end
    local rows = about.contributors.rows
    local labels = about.license_labels
    local license_pane = about.notebook:get_pane("license")
    local contributors_pane = about.notebook:get_pane("contributors")
    test.ok(about.contributors:is_visible())
    test.not_ok(about.license:is_visible())

    local tab = license_pane.tab
    local x, y = tab.position.x + tab.size.x / 2, tab.position.y + tab.size.y / 2
    core.on_event("mousemoved", x, y, 0, 0)
    core.on_event("mousepressed", "left", x, y, 1)
    core.on_event("mousereleased", "left", x, y)
    for _ = 1, 3 do core.root_view:update() end
    test.equal(about.notebook.active_pane, license_pane)
    test.ok(about.license:is_visible())
    test.not_ok(about.contributors:is_visible())
    local paragraphs = {}
    for _, label in ipairs(labels) do
      table.insert(paragraphs, label.original_label or label.label)
    end
    test.equal(table.concat(paragraphs, " "):gsub("%s+", " "),
      about.license_text:gsub("%s+", " "))
    for _, notice in ipairs {
      "MIT License", "Copyright (c) 2020 rxi", "Copyright (c) 2021 Lite XL Team",
      "Copyright (c) 2023 Pragtical Team", "Permission is hereby granted",
      "copies or substantial portions of the Software.",
      'THE SOFTWARE IS PROVIDED "AS IS"', "SOFTWARE."
    } do
      test.ok(about.license_text:find(notice, 1, true))
    end
    test.ok(about.license:get_scrollable_size() > about.license.size.y)
    x, y = about.license.position.x + 20, about.license.position.y + 20
    core.on_event("mousemoved", x, y, 0, 0)
    core.on_event("mousewheel", -1, 0)
    for _ = 1, 3 do core.root_view:update() end
    test.ok(about.license.scroll.y > 0)
    core.on_event("keypressed", "escape")
    test.equal(core.active_view, context.editor)

    test.equal(AboutView.show_dialog(), dialog)
    test.equal(about.notebook.active_pane, license_pane)
    test.equal(about.license_labels, labels)
    tab = contributors_pane.tab
    x, y = tab.position.x + tab.size.x / 2, tab.position.y + tab.size.y / 2
    core.on_event("mousemoved", x, y, 0, 0)
    core.on_event("mousepressed", "left", x, y, 1)
    core.on_event("mousereleased", "left", x, y)
    for _ = 1, 3 do core.root_view:update() end
    test.equal(about.notebook.active_pane, contributors_pane)
    test.ok(about.contributors:is_visible())
    test.not_ok(about.license:is_visible())
    test.equal(about.contributors.rows, rows)
  end)

  test.test("draws the contributors bottom border inside the tab viewport", function()
    local about = AboutView.show_dialog():get_panel().childs[1]
    about.notebook:set_pane("contributors")
    for _ = 1, 6 do core.root_view:update() end
    local width, height = core.window:get_size()
    core.clip_rect_stack = { { 0, 0, width, height } }
    renderer.begin_frame(core.window)
    renderer.set_clip_rect(0, 0, width, height)
    core.root_view:draw()
    renderer.end_frame()
    local frame = renderer.to_canvas(core.window, 0, 0, width, height)
    local list = about.contributors
    local y = common.round(list.position.y + list.size.y)
    local color = list.border.color or style.text
    for _, fraction in ipairs { 0.25, 0.5, 0.75 } do
      local x = common.round(list.position.x + list.size.x * fraction)
      test.same({ frame:get_pixels(x, y, 1, 1):byte(1, 3) },
        { color[1], color[2], color[3] })
    end
  end)

  test.test("resizes and recenters an open dialog when the scale changes", function(context)
    -- Inverse scaling can leave rounding differences; restore exact style values.
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
    local window_width, window_height = 1600, 1200
    system.get_window_size = function() return window_width, window_height end
    core.root_view.size.x, core.root_view.size.y = window_width, window_height
    local dialog = AboutView.show_dialog()
    local about = dialog:get_panel().childs[1]
    about.notebook:set_pane("license")
    for _ = 1, 6 do core.root_view:update() end
    local rows, labels = about.contributors.rows, about.license_labels
    local active = core.active_view
    dialog:set_position(20, 30)
    for _, factor in ipairs { 1.3, 1.5, 1 } do
      scale.set(factor)
      for _ = 1, 6 do core.root_view:update() end
      local x, y, width, height = dialog:get_floating_bounds()
      test.near(width, 760 * factor, 0.01)
      test.near(height, 560 * factor, 0.01)
      test.near(x, (window_width - width) / 2, 0.01)
      test.near(y, (window_height - height) / 2, 0.01)
      test.equal(core.active_view, active)
      test.equal(#core.root_view.floating_views, 1)
      test.equal(about.notebook.active_pane.name, "license")
      test.equal(about.contributors.rows, rows)
      test.equal(about.license_labels, labels)
      test.ok(about.license.size.x > 0 and about.license.size.y > 0)
    end

    window_width, window_height = 900, 700
    core.root_view.size.x, core.root_view.size.y = window_width, window_height
    scale.set(1.5)
    for _ = 1, 6 do core.root_view:update() end
    local x, y, width, height = dialog:get_floating_bounds()
    test.near(width, window_width - style.padding.x * 4, 0.01)
    test.near(height, window_height - style.padding.y * 4, 0.01)
    test.near(x, (window_width - width) / 2, 0.01)
    test.near(y, (window_height - height) / 2, 0.01)
    test.equal(core.active_view, active)
  end)
end)
