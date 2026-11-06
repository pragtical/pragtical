local test = require "core.test"
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local settings = require "plugins.settings"
local tree = require "plugins.treeview"
local Button = require "widget.button"
local Label = require "widget.label"
local SelectBox = require "widget.selectbox"
local TextBox = require "widget.textbox"
local Toggle = require "widget.toggle"
local WidgetList = require "widget.widgetlist"
local NumberBox = require "widget.numberbox"
local ListBox = require "widget.listbox"
local RootView = require "core.rootview"
local ColorPicker = require "widget.colorpicker"
local FilePicker = require "widget.filepicker"
local FontsList = require "widget.fontslist"
local ItemsList = require "widget.itemslist"
local style = require "core.style"
local SettingsView = getmetatable(settings.ui)

local function find_child(view, class)
  local childs = view.childs
  if view.sections then
    childs = view.sections.panes[1].container.childs
  end
  for _, child in ipairs(childs) do
    if child:is(class) then return child end
  end
end

test.describe("setting resets", function()
  test.before_each(function(c)
    c.userdir, c.saved, c.plugin = USERDIR, settings.config, rawget(config.plugins, "settings_reset")
    c.root, c.active, c.last, c.next = core.root_view, core.active_view, core.last_active_view, core.next_active_view
    c.scale, c.error, c.open = SCALE, core.error, io.open
    c.add_thread = core.add_thread
    c.wheel = config.mouse_wheel_scroll
    c.outline_focused, c.outline_unfocused = config.outline_focused, config.outline_unfocused
    c.tree_size, c.tree_target = config.plugins.treeview.size, tree.target_size
    c.tree_default, c.tree_scale = tree.default_size, tree.current_scale
    c.views = {}
    USERDIR = core.temp_filename()
    test.ok(common.mkdirp(USERDIR))
    settings.config = { keep = "untouched" }
    rawset(config.plugins, "settings_reset", {})
    core.root_view = RootView()
    core.root_view.root_node.is_primary_node = true
    core.root_view.size.x, core.root_view.size.y = 900, 650
    core.active_view = core.root_view.root_node.active_view
    core.error = function(fmt, ...) c.message = string.format(fmt, ...) end
  end)

  test.after_each(function(c)
    io.open, core.error, SCALE = c.open, c.error, c.scale
    core.add_thread = c.add_thread
    config.mouse_wheel_scroll = c.wheel
    config.outline_focused, config.outline_unfocused = c.outline_focused, c.outline_unfocused
    config.plugins.treeview.size, tree.target_size = c.tree_size, c.tree_target
    tree.default_size, tree.current_scale = c.tree_default, c.tree_scale
    for _, view in ipairs(c.views) do view:destroy() end
    core.root_view, core.active_view, core.last_active_view, core.next_active_view = c.root, c.active, c.last, c.next
    rawset(config.plugins, "settings_reset", c.plugin)
    settings.config = c.saved
    local directory = USERDIR
    USERDIR = c.userdir
    test.ok(common.rm(directory, true))
  end)

  ---Create an isolated generated control with matching saved and live overrides.
  local function control(c, option, class, value)
    option.label, option.path = option.label or "Example", option.path or "value"
    config.plugins.settings_reset[option.path] = value
    settings.config.plugins = { settings_reset = { [option.path] = value } }
    local file = assert(io.open(USERDIR .. "/user_settings.lua", "w"))
    file:write("return {config=", common.serialize(settings.config), "}")
    file:close()
    local view = settings.show_config("Reset Tests", { option }, "settings_reset")
    c.views[#c.views + 1] = view
    view:set_size(800, 600)
    for _ = 1, 10 do view:update() end
    local widget = find_child(view, class)
    test.not_nil(widget)
    test.not_nil(widget.reset_button)
    return widget, view
  end

  local cases = {
    { "number", NumberBox, 3, 8, function(w) return w:get_value() end },
    { "toggle", Toggle, false, true, function(w) return w:is_toggled() end },
    { "string", TextBox, "original", "custom", function(w) return w:get_text() end },
    { "selection", SelectBox, false, "custom", function(w) return w:get_selected_data() end },
    { "file", FilePicker, nil, DATADIR .. "/example", function(w) return w:get_path() end },
    { "directory", FilePicker, "", DATADIR, function(w) return w:get_path() or "" end },
    { "color", ColorPicker, {32, 64, 96, 128}, {5, 10, 15, 255}, function(w) return w:get_color() end },
    { "list_strings", ItemsList, {"first", "second"}, {"custom"}, function(w) return w:get_items() end }
  }
  for _, entry in ipairs(cases) do
    local case = entry
    test.it("restores " .. case[1] .. " values and removes the saved override", function(c)
      local option = {
        type = case[1], default = case[3],
        values = { {"Default", false}, {"Custom", "custom"} }
      }
      local original = common.serialize(option.default)
      local widget = control(c, option, case[2], case[4])
      test.ok(widget.reset_button.enabled)
      test.ok(widget.reset_button.visible)
      widget.reset_button:on_click()
      test.same(config.plugins.settings_reset.value, case[3])
      if case[1] == "color" then
        local actual = case[5](widget)
        for index = 1, 4 do test.ok(math.abs(actual[index] - case[3][index]) <= 1) end
      else
        test.same(case[5](widget), case[3])
      end
      test.is_nil(settings.config.plugins)
      test.same(dofile(USERDIR .. "/user_settings.lua").config, { keep = "untouched" })
      test.not_ok(widget.reset_button.enabled)
      test.not_ok(widget.reset_button.visible)
      test.equal(common.serialize(option.default), original)
      widget.reset_button:on_click()
      test.equal(common.serialize(option.default), original)
    end)
  end

  test.it("removes saved false defaults and keeps ordinary default-valued edits", function(c)
    local applied = 0
    local widget = control(c, {
      type = "toggle", default = false,
      on_apply = function() applied = applied + 1 end
    }, Toggle, false)
    widget.reset_button:on_click()
    test.equal(applied, 1)
    test.not_ok(widget.reset_button.visible)
    widget.reset_button:on_click()
    test.equal(applied, 1)
    widget:set_toggle(false)
    test.equal(settings.config.plugins.settings_reset.value, false)
    test.ok(widget.reset_button.enabled)
    test.ok(widget.reset_button.visible)
    widget.reset_button:on_click()
    test.is_nil(settings.config.plugins)
    test.equal(applied, 3)
  end)

  test.it("shows Reset only after saving an override", function(c)
    local widget = control(c, {
      type = "string", default = "original"
    }, TextBox, nil)
    test.not_ok(widget.reset_button.visible)
    widget:set_text("custom")
    test.ok(widget.reset_button.visible)
    widget.reset_button:on_click()
    test.equal(widget:get_text(), "original")
    test.not_ok(widget.reset_button.visible)
    test.is_nil(settings.config.plugins)
  end)

  test.it("returns heading space when Reset disappears without rebuilding controls", function(c)
    local widget, view = control(c, {
      label = "An option label with several words", type = "string", default = "original"
    }, TextBox, "custom")
    local reset, heading = widget.reset_button, widget.reset_button.heading
    view:set_size(heading:get_font():get_width(heading.original_label) + 20, 500)
    for _ = 1, 10 do view:update() end
    local height, input_y, input_width = heading:get_height(), widget.position.ry, widget:get_width()
    local children = #view.childs
    test.ok(height > heading:get_font():get_height())
    reset:on_click()
    for _ = 1, 10 do view:update() end
    test.not_ok(reset.visible)
    test.equal(heading:get_height(), heading:get_font():get_height())
    test.ok(widget.position.ry < input_y)
    test.equal(widget:get_width(), input_width)
    widget:set_text("custom again")
    for _ = 1, 10 do view:update() end
    test.ok(reset.visible)
    test.equal(heading:get_height(), height)
    test.equal(widget.position.ry, input_y)
    test.equal(#view.childs, children)
    core.redraw = false
    for _ = 1, 5 do view:update() end
    test.not_ok(core.redraw)
  end)

  test.it("resolves current theme colors on reset without sharing the source", function(c)
    local colors, calls, applied = { dim = { 12, 34, 56, 78 } }, 0, 0
    local widget, view = control(c, {
      type = "color",
      default = function() calls = calls + 1; return colors.dim end,
      on_apply = function() applied = applied + 1 end
    }, ColorPicker, { 90, 100, 110, 255 })
    test.equal(calls, 1)
    colors.dim = { 56, 78, 90, 123 }
    for _ = 1, 5 do view:update() end
    test.equal(calls, 1)
    widget.reset_button:on_click()
    test.equal(calls, 2)
    test.equal(applied, 1)
    test.same(config.plugins.settings_reset.value, colors.dim)
    test.not_equal(config.plugins.settings_reset.value, colors.dim)
    test.is_nil(settings.config.plugins)
    widget.reset_button:on_click()
    test.equal(calls, 2)
    config.plugins.settings_reset.value[1] = 255
    test.equal(colors.dim[1], 56)
    widget:on_change({ 1, 2, 3, 255 })
    colors.dim[1] = 44
    widget.reset_button:on_click()
    test.equal(config.plugins.settings_reset.value[1], 44)
    test.equal(calls, 3)
  end)

  test.it("resolves dynamic fallbacks when constructing controls", function(c)
    local color = { 24, 48, 72, 96 }
    local widget = control(c, {
      type = "color", default = function() return color end
    }, ColorPicker, nil)
    local actual = widget:get_color()
    for index = 1, 4 do test.ok(math.abs(actual[index] - color[index]) <= 1) end
    test.not_ok(widget.reset_button.enabled)
    test.is_nil(config.plugins.settings_reset.value)
    test.same(color, { 24, 48, 72, 96 })
  end)

  test.it("resolves false and nil defaults without retaining the initial value", function(c)
    local value = true
    local widget = control(c, {
      type = "toggle", default = function() return value end
    }, Toggle, true)
    value = false
    widget.reset_button:on_click()
    test.equal(config.plugins.settings_reset.value, false)
    test.not_ok(widget:is_toggled())
    value = DATADIR
    widget = control(c, {
      type = "file", default = function() return value end
    }, FilePicker, DATADIR)
    value = nil
    widget.reset_button:on_click()
    test.is_nil(config.plugins.settings_reset.value)
    test.is_nil(widget:get_path())
  end)

  test.it("preserves an override if resolving its default fails", function(c)
    local fail = false
    local widget = control(c, {
      type = "string", default = function()
        if fail then error("unavailable default") end
        return "original"
      end
    }, TextBox, "custom")
    fail = true
    widget.reset_button:on_click()
    test.equal(widget:get_text(), "custom")
    test.equal(config.plugins.settings_reset.value, "custom")
    test.equal(dofile(USERDIR .. "/user_settings.lua").config.plugins.settings_reset.value, "custom")
    test.ok(widget.reset_button.enabled)
    test.contains(c.message, "unavailable default")
  end)

  test.it("shows effective outline colors while resets restore theme inheritance", function(c)
    for _, option in ipairs(settings.core["User Interface"]) do
      if option.path == "outline_focused" or option.path == "outline_unfocused" then
        local expected = option.path == "outline_focused" and style.caret or style.dim
        test.is_nil(option.default)
        test.equal(option.get_value(nil), expected)
        config[option.path] = { 1, 2, 3, 255 }
        settings.config[option.path] = config[option.path]
        local view = settings.show_config("Outline Color", { option })
        c.views[#c.views + 1] = view
        local widget = find_child(view, ColorPicker)
        widget.reset_button:on_click()
        test.is_nil(config[option.path])
        test.is_nil(settings.config[option.path])
        local actual = widget:get_color()
        for index = 1, 4 do test.ok(math.abs(actual[index] - (expected[index] or 255)) <= 1) end
      end
    end
  end)

  test.it("shows the theme color for an unset Line Guide override", function()
    for _, option in ipairs(config.plugins.lineguide.config_spec) do
      if option.path == "custom_color" then
        test.is_nil(option.default)
        test.equal(option.get_value(nil), style.selection)
      end
    end
  end)

  test.it("restores nested values without removing sibling overrides", function(c)
    local applied
    local widget = control(c, { type = "string", default = "original" }, TextBox, "custom")
    local view = settings.show_config("Nested", {
      path_prefix = "plugins.settings_reset.project",
      { label = "Name", path = "name", type = "string", default = "Demo",
        on_apply = function(value) applied = value end }
    })
    c.views[#c.views + 1] = view
    local nested = find_child(view, TextBox)
    nested:on_change("Website")
    settings.config.plugins.settings_reset.project.sibling = false
    nested.reset_button:on_click()
    test.equal(applied, "Demo")
    test.equal(config.plugins.settings_reset.project.name, "Demo")
    local saved = dofile(USERDIR .. "/user_settings.lua").config.plugins.settings_reset
    test.equal(saved.value, "custom")
    test.same(saved.project, { sibling = false })
    test.ok(widget.reset_button.enabled)
  end)

  test.it("converts defaults once and applies the resulting runtime value", function(c)
    SCALE = 1.25
    local converted, applied = 0, 0
    local widget = control(c, {
      type = "number", default = 200,
      get_value = function(value) return value / SCALE end,
      set_value = function(value) converted = converted + 1; return value * SCALE end,
      on_apply = function(value) applied = applied + 1; test.equal(value, 250) end
    }, NumberBox, 500)
    widget.reset_button:on_click()
    test.equal(converted, 1)
    test.equal(applied, 1)
    test.equal(config.plugins.settings_reset.value, 250)
    test.equal(widget:get_value(), 200)
    test.is_nil(settings.config.plugins)
  end)

  test.it("uses escaped text defaults through the existing conversion hooks", function(c)
    local option
    for _, candidate in ipairs(settings.core.Editor) do
      if candidate.path == "non_word_chars" then option = common.merge({}, candidate) end
    end
    option.path = "value"
    local widget = control(c, option, TextBox, "custom")
    widget.reset_button:on_click()
    test.contains(config.plugins.settings_reset.value, "\t\n")
    test.equal(widget:get_text(), option.default)
    test.is_nil(settings.config.plugins)
  end)

  test.it("resets actual scaled Treeview and mouse-wheel settings", function(c)
    local width_option, wheel_option
    for _, option in ipairs(config.plugins.treeview.config_spec) do
      if option.path == "size" then width_option = option end
    end
    for _, option in ipairs(settings.core["User Interface"]) do
      if option.path == "mouse_wheel_scroll" then wheel_option = option end
    end
    for _, factor in ipairs { 1.25, 2 } do
      SCALE = factor
      config.plugins.treeview.size = 500 * SCALE
      settings.config.plugins = { treeview = { size = 500 } }
      local view = settings.show_config("Tree Size", { width_option }, "treeview")
      c.views[#c.views + 1] = view
      local number = find_child(view, NumberBox)
      number.reset_button:on_click()
      test.equal(config.plugins.treeview.size, 200 * SCALE)
      test.equal(tree.target_size, 200 * SCALE)
      test.equal(number:get_value(), 200)
      test.is_nil(settings.config.plugins)

      config.mouse_wheel_scroll = 210 * SCALE
      settings.config.mouse_wheel_scroll = 210
      view = settings.show_config("Wheel Rate", { wheel_option })
      c.views[#c.views + 1] = view
      number = find_child(view, NumberBox)
      number.reset_button:on_click()
      test.equal(config.mouse_wheel_scroll, 70 * SCALE)
      test.equal(number:get_value(), 70)
      test.is_nil(settings.config.mouse_wheel_scroll)
    end
  end)

  test.it("resets through a real pointer click beside the label", function(c)
    local widget, view = control(c, { type = "toggle", default = false }, Toggle, true)
    for _ = 1, 10 do core.root_view:update() end
    local button = widget.reset_button
    test.equal(button.parent, widget.parent)
    test.ok(button.position.x >= widget.position.x + widget:get_width())
    local x = button.position.x + button:get_width() / 2
    local y = button.position.y + button:get_height() / 2
    core.on_event("mousemoved", x, y, 0, 0)
    core.on_event("mousepressed", "left", x, y, 1)
    core.on_event("mousereleased", "left", x, y)
    test.not_ok(widget:is_toggled())
    test.is_nil(settings.config.plugins)
    test.not_ok(button.enabled)
  end)

  test.it("keeps numeric Reset disabled after deferred input validation", function(c)
    local number = control(c, {
      label = "Maximum Clicks", type = "number", default = 3
    }, NumberBox, 8)
    local pending = {}
    core.add_thread = function(fn) pending[#pending + 1] = fn end
    number.reset_button:on_click()
    test.equal(number:get_value(), 3)
    test.not_ok(number.reset_button.enabled)
    for _, fn in ipairs(pending) do fn() end
    test.equal(number:get_value(), 3)
    test.not_ok(number.reset_button.enabled)
    test.is_nil(settings.config.plugins)
    test.same(dofile(USERDIR .. "/user_settings.lua").config, { keep = "untouched" })
  end)

  test.it("keeps a rejected reset and the current displayed value", function(c)
    local widget = control(c, {
      type = "selection", default = false,
      values = { {"Default", false}, {"Custom", "custom"} },
      set_value = function(value)
        if value == false then return nil, "cannot reset" end
        return value
      end
    }, SelectBox, "custom")
    widget.reset_button:on_click()
    test.equal(widget:get_selected_data(), "custom")
    test.equal(config.plugins.settings_reset.value, "custom")
    test.equal(dofile(USERDIR .. "/user_settings.lua").config.plugins.settings_reset.value, "custom")
    test.ok(widget.reset_button.enabled)
    test.contains(c.message, "cannot reset")
  end)

  test.it("reports save errors without clearing the in-memory override", function(c)
    local widget = control(c, { type = "string", default = "original" }, TextBox, "custom")
    io.open = function(path, mode)
      if path == USERDIR .. "/user_settings.lua" and mode == "w" then return nil, "read-only profile" end
      return c.open(path, mode)
    end
    widget.reset_button:on_click()
    test.equal(config.plugins.settings_reset.value, "custom")
    test.equal(settings.config.plugins.settings_reset.value, "custom")
    test.equal(widget:get_text(), "custom")
    test.ok(widget.reset_button.enabled)
    test.contains(c.message, "read-only profile")
  end)

  for _, valid in ipairs { true, false } do
    test.it(valid and "restores portable font defaults without mutating metadata"
      or "preserves the font override when default fonts cannot load", function(c)
      local target = { font = style.font }
      local original_font = target.font
      local defaults = {
        fonts = { {name = "Default", path = valid and "{datadir}/fonts/FiraSans-Regular.ttf" or "/missing/reset-font.ttf"} },
        options = { size = 15, antialiasing = "grayscale", hinting = "slight" }
      }
      local serialized = common.serialize(defaults)
      local custom = {
        fonts = { {name = "Custom", path = "{datadir}/fonts/JetBrainsMono-Regular.ttf"} },
        options = { size = 19, antialiasing = "grayscale", hinting = "slight" }
      }
      local widget = control(c, {
        type = "font", path = "font", default = defaults, fonts_list = target
      }, FontsList, custom)
      widget.reset_button:on_click()
      test.equal(common.serialize(defaults), serialized)
      test.equal(custom.fonts[1].path, "{datadir}/fonts/JetBrainsMono-Regular.ttf")
      if valid then
        test.equal(target.font:get_size(), 15 * SCALE)
        test.equal(widget:get_fonts()[1].path, DATADIR .. "/fonts/FiraSans-Regular.ttf")
        test.equal(widget:get_options().size, 15)
        test.is_nil(settings.config.plugins)
        test.not_ok(widget.reset_button.enabled)
      else
        test.equal(target.font, original_font)
        test.equal(widget:get_options().size, 19)
        test.equal(settings.config.plugins.settings_reset.font.options.size, 19)
        test.ok(widget.reset_button.enabled)
        test.not_nil(c.message)
      end
    end)
  end

  test.it("refreshes custom list rows while keeping their filter and defaults", function(c)
    local builds = 0
    local defaults = { Alpha = false, Beta = false }
    local widget, view = control(c, {
      type = "list_widgets", default = defaults, visible_rows = 1,
      items = {"Alpha", "Beta"},
      build_item = function(row, item, value, commit)
        builds = builds + 1
        local toggle = Toggle(row, item, value[item])
        function toggle:on_change(enabled) value[item] = enabled; commit(value) end
      end
    }, WidgetList, { Alpha = true, Beta = true })
    local filter = find_child(view, TextBox)
    filter:set_text("Beta")
    widget:filter("Beta")
    widget.reset_button:on_click()
    test.equal(builds, 4)
    test.equal(filter:get_text(), "Beta")
    test.equal(widget.filter_value, "Beta")
    test.not_ok(find_child(widget.items[2].row, Toggle):is_toggled())
    test.same(defaults, { Alpha = false, Beta = false })
    test.is_nil(settings.config.plugins)
    for _ = 1, 10 do view:update() end
    core.redraw = false
    for _ = 1, 5 do view:update() end
    test.equal(builds, 4)
    test.not_ok(core.redraw)
  end)

  test.it("does not add resets to action or subconfiguration buttons", function(c)
    local view = settings.show_config("Actions", {
      { label = "Action", path = "unused", type = "button" },
      { label = "More", type = "subconfig", spec = {} }
    })
    c.views[#c.views + 1] = view
    for _, child in ipairs(view.childs) do test.is_nil(child.reset_button) end
  end)
end)

test.describe("settings search", function()
  test.before_each(function(c)
    c.root, c.active, c.last, c.next = core.root_view, core.active_view, core.last_active_view, core.next_active_view
    c.saved, c.plugins, c.sections = settings.config, settings.plugins, settings.plugin_sections
    c.plugin = rawget(config.plugins, "search_fixture")
    c.preload, c.loaded = package.preload["plugins.search_fixture"], package.loaded["plugins.search_fixture"]
    c.userdir, c.transitions, c.clip = USERDIR, config.transitions, core.clip_rect_stack
    USERDIR = core.temp_filename()
    test.ok(common.mkdirp(USERDIR))
    config.transitions = false
    settings.config, settings.plugins, settings.plugin_sections = {}, {}, {}
    c.defaults = 0
    local spec = {
      name = "Connection Tools",
      { label = "Endpoint Address", description = "Server URL", path = "endpoint", type = "string",
        default = function() c.defaults = c.defaults + 1; return "original" end },
      { label = "Retry Limit", description = "Network connection retry budget", path = "retry_limit",
        type = "number", default = 2 }
    }
    rawset(config.plugins, "search_fixture", { endpoint = "kept", retry_limit = 8, config_spec = spec })
    package.preload["plugins.search_fixture"] = function() return {} end
    settings.add(spec.name, spec, "search_fixture")
    core.root_view = RootView()
    core.root_view.root_node.is_primary_node = true
    core.root_view.size.x, core.root_view.size.y = 900, 650
    core.active_view = core.root_view.root_node.active_view
    c.view = SettingsView()
    c.view:show()
    core.root_view.root_node:add_view(c.view)
    for _ = 1, 20 do core.root_view:update() end
  end)

  test.after_each(function(c)
    c.view:destroy()
    core.root_view, core.active_view, core.last_active_view, core.next_active_view = c.root, c.active, c.last, c.next
    settings.config, settings.plugins, settings.plugin_sections = c.saved, c.plugins, c.sections
    rawset(config.plugins, "search_fixture", c.plugin)
    package.preload["plugins.search_fixture"], package.loaded["plugins.search_fixture"] = c.preload, c.loaded
    config.transitions, core.clip_rect_stack = c.transitions, c.clip
    local directory = USERDIR
    USERDIR = c.userdir
    test.ok(common.rm(directory, true))
  end)

  ---Find an existing option by the label shared with its Reset action.
  local function option(book, section, label)
    for _, child in ipairs(book:get_pane(section).container.childs) do
      local reset = child.reset_button
      if reset and (reset.heading.original_label or reset.heading.label) == label .. ":" then return child end
    end
    test.fail("missing setting: " .. label)
  end

  test.it("matches Core labels, descriptions and paths while restoring collapsed sections", function(c)
    local book = c.view.core_sections
    local clicks = option(book, "General", "Maximum Clicks")
    local size = option(book, "General", "File Size Limit")
    book:toggle_pane("General", true)
    book.search:set_text(" MAX_CLICKS ")
    test.equal(#book.panes, 1)
    test.equal(book.panes[1].name, "General")
    test.ok(clicks.visible)
    test.not_ok(size.visible)
    book.search:set_text("megabytes")
    test.ok(size.visible)
    test.not_ok(clicks.visible)
    book.search:set_text("editor non_word_chars")
    test.equal(#book.panes, 1)
    test.equal(book.panes[1].name, "Editor")
    test.ok(book.panes[1].expanded)
    book.search:set_text("")
    test.equal(#book.panes, #book.all_panes)
    test.ok(book:get_pane("General").expanded)
    test.not_ok(book:get_pane("Editor").expanded)
    test.ok(clicks.visible)
    test.ok(size.visible)
  end)

  test.it("handles literal punctuation, no matches and independent tab queries", function(c)
    local core_book, plugins = c.view.core_sections, c.view.plugin_sections
    core_book.search:set_text("[.*")
    test.equal(#core_book.panes, 0)
    test.ok(core_book.empty.visible)
    c.view.notebook:set_pane("plugins")
    plugins.search:set_text("retry_limit")
    test.equal(#plugins.panes, 1)
    test.equal(plugins.panes[1].name, "Connection Tools")
    test.not_ok(plugins.empty.visible)
    test.equal(core_book.search:get_text(), "[.*")
    core_book.search:set_text("   ")
    test.not_ok(core_book.empty.visible)
    test.equal(#core_book.panes, #core_book.all_panes)
    test.equal(plugins.search:get_text(), "retry_limit")
  end)

  test.it("filters plugin names and option groups without rebuilding or evaluating defaults", function(c)
    local book = c.view.plugin_sections
    c.view.notebook:set_pane("plugins")
    local endpoint = option(book, "Connection Tools", "Endpoint Address")
    local retry = option(book, "Connection Tools", "Retry Limit")
    local count = #book:get_pane("Connection Tools").container.childs
    book.search:set_text("SEARCH_FIXTURE")
    test.ok(endpoint.visible)
    test.ok(retry.visible)
    endpoint:set_text("edited")
    test.ok(endpoint.reset_button.visible)
    book.search:set_text("retry budget")
    test.not_ok(endpoint.visible)
    test.not_ok(endpoint.reset_button.visible)
    test.ok(retry.visible)
    book.search:set_text("connection tools")
    test.ok(endpoint.visible)
    test.ok(endpoint.reset_button.visible)
    test.equal(endpoint:get_text(), "edited")
    test.equal(option(book, "Connection Tools", "Endpoint Address"), endpoint)
    test.equal(#book:get_pane("Connection Tools").container.childs, count)
    test.equal(c.defaults, 1)
    for _ = 1, 20 do core.root_view:update() end
    core.redraw = false
    for _ = 1, 5 do core.root_view:update() end
    test.not_ok(core.redraw)
    test.equal(c.defaults, 1)
  end)

  test.it("filters the Installed rows with the same Plugins search field", function(c)
    local book = c.view.plugin_sections
    c.view.notebook:set_pane("plugins")
    book.search:set_text("lineguide")
    for _ = 1, 20 do core.root_view:update() end
    local list, found = book.installed_list, 0
    for _, item in ipairs(list.items) do
      if item.matched then test.equal(item.data.plugin, "lineguide"); found = found + 1 end
    end
    test.equal(found, 1)
    test.equal(list.visible_row_count, 1)
    test.ok(book:get_pane("enable_disable").tab.visible)
    test.not_ok(book:get_pane("Connection Tools").tab.visible)
    book.search:set_text("")
    test.equal(list.visible_row_count, 10)
  end)

  test.it("reapplies an active search when plugin sections are removed or enabled", function(c)
    local book = c.view.plugin_sections
    book.search:set_text("retry_limit")
    c.view:disable_plugin("search_fixture")
    test.is_nil(book:get_pane("Connection Tools"))
    test.ok(book.empty.visible)
    c.view:enable_plugin("search_fixture")
    test.equal(book.search:get_text(), "retry_limit")
    test.equal(#book.panes, 1)
    test.ok(option(book, "Connection Tools", "Retry Limit").visible)
    test.not_ok(option(book, "Connection Tools", "Endpoint Address").visible)
  end)

  test.it("keeps the Core search field fixed and clean while its sections scroll", function(c)
    local book = c.view.core_sections
    for _, pane in ipairs(book.panes) do pane.expanded = true end
    for _ = 1, 40 do core.root_view:update() end
    test.ok(book:get_scrollable_size() > book.size.y + 80)
    local window = renwindow.create("Settings search", 900, 650)
    local search_y = book.search.position.y
    local function capture()
      core.clip_rect_stack = { { 0, 0, 900, 650 } }
      renderer.begin_frame(window)
      renderer.set_clip_rect(0, 0, 900, 650)
      c.view:draw()
      renderer.end_frame()
      return renderer.to_canvas(window, 0, math.floor(search_y), 900, math.floor(book.search:get_height())):get_pixels()
    end
    capture()
    local header = capture()
    book.scroll.y, book.scroll.to.y = 80, 80
    core.root_view:update()
    test.equal(book.search.position.y, search_y)
    test.equal(capture(), header)
  end)
end)

test.describe("settings scrolling", function()
  test.before_each(function(context)
    context.scale = SCALE
    context.transitions = config.transitions
    context.clip_rect_stack = core.clip_rect_stack
    context.redraw = core.redraw
    context.style = {}
    for _, name in ipairs { "font", "big_font", "icon_font", "icon_big_font", "padding" } do
      context.style[name] = style[name]
    end
    config.transitions = false
  end)

  test.after_each(function(context)
    if context.view then context.view:destroy() end
    SCALE = context.scale
    for name, value in pairs(context.style) do style[name] = value end
    config.transitions = context.transitions
    core.clip_rect_stack = context.clip_rect_stack
    core.redraw = context.redraw
  end)

  for _, factor in ipairs { 1, 1.25, 1.3, 1.5, 1.75, 2, 3 } do
    test.it("keeps Settings content stable between scroll pixels at scale " .. factor, function(context)
      SCALE = factor
      local ratio = factor / context.scale
      for _, name in ipairs { "font", "big_font", "icon_font", "icon_big_font" } do
        style[name] = context.style[name]:copy(context.style[name]:get_size() * ratio)
      end
      style.padding = { x = context.style.padding.x * ratio, y = context.style.padding.y * ratio }
      local view = SettingsView()
      context.view = view
      view:show()
      view:set_position(20.65, 20.65)
      view:set_size(900, 650)
      local window = renwindow.create("Settings scrolling", 960, 720)
      local function capture()
        core.clip_rect_stack = { { 0, 0, 960, 720 } }
        renderer.begin_frame(window)
        renderer.set_clip_rect(0, 0, 960, 720)
        renderer.draw_rect(0, 0, 960, 720, style.background)
        view:draw()
        renderer.end_frame()
        -- Exclude the fixed headings, viewport edges and scrollbar thumbs.
        local frame = renderer.to_canvas(window, 80, 200, 760, 400)
        return frame:get_pixels(0, 0, 760, 400)
      end
      for _, name in ipairs { "colors", "keybindings", "core" } do
        view.notebook:set_pane(name)
        if name == "core" then
          for _, pane in ipairs(view.core_sections.panes) do pane.expanded = true end
        end
        for _ = 1, 40 do view:update() end
        local pane = name == "keybindings" and view.keybinds
          or name == "core" and view.core_sections or view[name]
        local scroller = find_child(pane, ListBox) or pane
        test.ok(scroller:get_scrollable_size() > scroller.size.y + 31)
        capture()
        for _, pair in ipairs { { 30.1, 30.4 }, { 30.6, 30.9 } } do
          scroller.scroll.y, scroller.scroll.to.y = pair[1], pair[1]
          view:update()
          local before = capture()
          scroller.scroll.y, scroller.scroll.to.y = pair[2], pair[2]
          view:update()
          test.ok(capture() == before, name .. " moved within a single scroll pixel")
        end
        core.redraw = false
        for _ = 1, 5 do view:update() end
        test.not_ok(core.redraw)
      end
      for _, width in ipairs { 430, 900 } do
        view:set_size(width, 650)
        for _ = 1, 10 do view:update() end
        for _, section in ipairs(view.core_sections.panes) do
          for _, widget in ipairs(section.container.childs) do
            local reset = widget.reset_button
            if reset and reset.visible then
              local heading = reset.heading
              if reset.position.ry == heading.position.ry then
                test.ok(reset.position.rx >= heading:get_right())
              else
                test.ok(reset.position.ry >= heading:get_bottom())
              end
              test.ok(reset:get_right() <= section.container:get_width() - 10)
              if widget ~= heading then
                test.ok(widget.position.ry >= math.max(heading:get_bottom(), reset:get_bottom()))
              end
            end
          end
        end
        core.redraw = false
        for _ = 1, 5 do view:update() end
        test.not_ok(core.redraw)
      end
    end)
  end
end)

test.describe("installed plugin layout", function()
  test.before_each(function(context)
    context.transitions = config.transitions
    config.transitions = false
    context.view = SettingsView()
    context.view:show()
    context.view:set_position(40, 40)
    context.view:set_size(800, 600)
    context.view.notebook:set_pane("plugins")
    context.view.plugin_sections:toggle_pane("enable_disable", true)
    for _ = 1, 20 do context.view:update() end
  end)

  test.after_each(function(context)
    context.view:destroy()
    config.transitions = context.transitions
  end)

  for _, status in ipairs { "expanded", "automatic" } do
    test.it("clears child hover when moving to the " .. status .. " parent scrollbar", function(context)
      local view = context.view
      local pane = view.plugin_sections:get_pane("enable_disable")
      local list = find_child(pane.container, WidgetList)
      local parent_bar, child_bar = view.plugin_sections.v_scrollbar, list.v_scrollbar
      parent_bar:set_forced_status(status == "expanded" and status or false)
      view:update()
      local x, y, w, h = child_bar:get_thumb_rect()
      view:on_mouse_moved(x + w / 2, y + h / 2, 0, 0)
      view:update()
      test.ok(child_bar.hovering.thumb)
      test.equal(child_bar.expand_percent, 1)
      x, y, w, h = parent_bar:get_thumb_rect()
      view:on_mouse_moved(x + w / 2, y + h / 2, 0, 0)
      test.ok(parent_bar.hovering.thumb)
      test.not_ok(child_bar.hovering.track)
      test.not_ok(child_bar.hovering.thumb)
      test.not_ok(list.mouse_is_hovering)
      view:update()
      test.equal(child_bar.expand_percent, status == "expanded" and 1 or 0)
      x, y, w, h = child_bar:get_thumb_rect()
      view:on_mouse_moved(x + w / 2, y + h / 2, 0, 0)
      view:update()
      test.ok(child_bar.hovering.thumb)
      test.equal(child_bar.expand_percent, 1)
      view:on_mouse_left()
      view:update()
      test.not_ok(child_bar.hovering.track)
      test.equal(child_bar.expand_percent, status == "expanded" and 1 or 0)
    end)

    test.it("keeps Installed toggles clear of " .. status .. " scrollbars", function(context)
      local view = context.view
      local pane = view.plugin_sections:get_pane("enable_disable")
      local list = find_child(pane.container, WidgetList)
      test.not_nil(list)
      test.ok(list.content_height > list.size.y)
      list.v_scrollbar:set_forced_status(status == "expanded" and status or false)
      view:update()
      if status == "automatic" then
        local x, y, w = list.v_scrollbar:get_track_rect()
        list.v_scrollbar:on_mouse_moved(x + w / 2, y + 10, 0, 0)
        view:update()
      end
      local x = list.v_scrollbar:get_track_rect()
      for _, entry in ipairs(list.items) do
        if entry.row.visible then
          local toggle = find_child(entry.row, Toggle)
          test.not_nil(toggle)
          test.ok(toggle.position.x + toggle:get_width() < x)
          test.is_nil(list.v_scrollbar:overlaps(
            toggle.position.x + toggle:get_width() - 1,
            toggle.position.y + toggle:get_height() / 2
          ))
          test.equal(toggle.render_background, false)
        end
      end
      list:filter(function(_, index) return index == 1 end)
      view:update()
      test.equal(list.items[1].row:get_width(), list.size.x)
      test.equal(select(3, list.v_scrollbar:get_track_rect()), 0)
    end)

    test.it("drags the Installed scrollbar after hovering the " .. status .. " parent", function(context)
      local view = context.view
      local pane = view.plugin_sections:get_pane("enable_disable")
      local list = find_child(pane.container, WidgetList)
      local parent_bar, child_bar = view.plugin_sections.v_scrollbar, list.v_scrollbar
      parent_bar:set_forced_status(status == "expanded" and status or false)
      view:update()
      local x, y, w, h = parent_bar:get_thumb_rect()
      test.ok(w > 0 and h > 0)
      view:on_mouse_moved(x + w / 2, y + h / 2, 0, 0)
      view:update()
      test.ok(parent_bar.hovering.thumb)
      test.equal(parent_bar.expand_percent, 1)
      x, y, w, h = child_bar:get_thumb_rect()
      x, y = x + w - 1, y + h / 2
      view:on_mouse_moved(x, y, 0, 0)
      test.not_ok(parent_bar.hovering.track)
      test.ok(child_bar.hovering.thumb)
      local parent_scroll = view.plugin_sections.scroll.to.y
      view:on_mouse_pressed("left", x, y, 1)
      test.equal(view.captured_widget, list)
      test.ok(child_bar.dragging)
      test.not_ok(parent_bar.dragging)
      view:on_mouse_moved(x, y + 60, 0, 60)
      test.ok(list.scroll.to.y > 0)
      test.equal(view.plugin_sections.scroll.to.y, parent_scroll)
      view:on_mouse_released("left", 900, 700)
      test.not_ok(child_bar.dragging)
      test.is_nil(view.captured_widget)
    end)
  end
end)

test.describe("settings input cursor", function()
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
    context.view = SettingsView()
    context.view:show()
    context.view.notebook:set_pane("core")
    context.view.core_sections:toggle_pane("General", true)
    core.root_view.root_node:add_view(context.view)
    for _ = 1, 20 do core.root_view:update() end
  end)

  test.after_each(function(context)
    context.view:destroy()
    core.root_view = context.root_view
    core.active_view = context.active_view
    core.last_active_view = context.last_active_view
    core.next_active_view = context.next_active_view
    core.cursor_change_req = context.cursor_change_req
    config.transitions = context.transitions
  end)

  test.it("uses the arrow over other controls while a NumberBox keeps focus", function(context)
    local view = context.view
    local pane = view.core_sections:get_pane("General")
    local number, label
    for _, child in ipairs(pane.container.childs) do
      if child:is(NumberBox) and (not number or child.position.y < number.position.y) then
        number = child
      elseif child:is(Label) and (child.original_label or child.label) == "File Size Limit:" then
        label = child
      end
    end
    test.not_nil(number)
    test.not_nil(label)
    local input = number.textbox
    local targets = { number.decrease_button, number.increase_button,
      find_child(pane.container, Button), label }
    for _, target in ipairs(targets) do
      local x, y = input.position.x + 10, input.position.y + input.size.y / 2
      test.equal(core.root_view.root_node:get_child_overlapping_point(x, y).active_view, view)
      core.on_event("mousemoved", x, y, 0, 0)
      core.on_event("mousepressed", "left", x, y, 1)
      core.on_event("mousereleased", "left", x, y)
      core.root_view:update()
      test.ok(core.active_view == input.textview)
      test.equal(core.cursor_change_req, "ibeam")
      core.on_event("mousemoved", target.position.x + 5, target.position.y + 5, 0, 0)
      core.root_view:update()
      test.not_ok(input.mouse_is_hovering)
      test.ok(core.active_view == input.textview)
      test.equal(core.cursor_change_req, "arrow")
      for _ = 1, 3 do
        core.cursor_change_req = nil
        core.root_view:update()
        test.not_equal(core.cursor_change_req, "ibeam")
      end
    end
  end)
end)

test.describe("settings renderer preference", function()
  local option
  for _, candidate in ipairs(settings.core.Graphics) do
    if candidate.path == "renderer" then option = candidate end
  end

  test.before_each(function(context)
    context.userdir = USERDIR
    context.renderer = config.renderer
    context.settings_config = settings.config
    context.open, context.remove = io.open, os.remove
    context.error = core.error
    context.backend = core.window:get_renderer_info().backend
    USERDIR = USERDIR .. PATHSEP .. "renderer-settings-" .. system.get_process_id()
    test.ok(common.mkdirp(USERDIR))
    settings.config = {}
    config.renderer = "default"
    core.error = function(fmt, ...)
      context.error_message = string.format(fmt, ...)
    end
  end)

  test.after_each(function(context)
    io.open, os.remove = context.open, context.remove
    core.error = context.error
    local temp = USERDIR
    USERDIR = context.userdir
    config.renderer = context.renderer
    settings.config = context.settings_config
    test.ok(common.rm(temp, true))
    test.equal(core.window:get_renderer_info().backend, context.backend)
  end)

  local function control()
    return find_child(settings.show_config("Renderer Settings", {option}), SelectBox)
  end

  local function read_preference()
    local file = assert(io.open(USERDIR .. PATHSEP .. "renderer", "r"))
    local value = file:read("*a")
    file:close()
    return value
  end

  test.it("persists each backend and removes the preference for Default", function()
    local select = control()
    test.equal(select:get_selected_data(), "default")
    test.equal(system.get_file_info(USERDIR .. PATHSEP .. "renderer"), nil)
    for idx, backend in ipairs({"surface", "sdlgpu", "sdlrenderer", "surface"}) do
      select:set_selected(idx == 4 and 2 or idx + 1)
      test.equal(read_preference(), backend .. "\n")
      test.equal(config.renderer, backend)
      test.equal(dofile(USERDIR .. "/user_settings.lua").config.renderer, backend)
    end
    select:set_selected(1)
    test.equal(config.renderer, "default")
    test.equal(system.get_file_info(USERDIR .. PATHSEP .. "renderer"), nil)
    select:set_selected(1)
    test.equal(config.renderer, "default")
  end)

  test.it("reads the file instead of the mirrored config or active backend", function()
    local file = assert(io.open(USERDIR .. PATHSEP .. "renderer", "w"))
    file:write("  sdlgpu\n")
    file:close()
    config.renderer = "surface"
    test.equal(control():get_selected_data(), "sdlgpu")
    test.equal(read_preference(), "  sdlgpu\n")
  end)

  test.it("Reset removes the renderer preference and its saved GUI override", function(context)
    local select = control()
    select:set_selected(2)
    test.equal(read_preference(), "surface\n")
    local writes = 0
    io.open = function(path, mode)
      if path == USERDIR .. "/user_settings.lua" and mode == "w" then writes = writes + 1 end
      return context.open(path, mode)
    end
    select.reset_button:on_click()
    test.equal(writes, 1)
    test.equal(select:get_selected_data(), "default")
    test.equal(config.renderer, "default")
    test.is_nil(settings.config.renderer)
    test.is_nil(dofile(USERDIR .. "/user_settings.lua").config.renderer)
    test.is_nil(system.get_file_info(USERDIR .. PATHSEP .. "renderer"))
    test.not_ok(select.reset_button.enabled)
  end)

  test.it("shows Default for missing or invalid preferences without rewriting them", function()
    test.equal(option.get_value(), "default")
    local file = assert(io.open(USERDIR .. PATHSEP .. "renderer", "w"))
    file:write("unknown\n")
    file:close()
    test.equal(control():get_selected_data(), "default")
    test.equal(read_preference(), "unknown\n")
  end)

  for _, failure in ipairs({"open", "write", "close", "remove"}) do
    test.it("reports " .. failure .. " failure without updating the setting", function(context)
      local select = control()
      select:set_selected(2)
      local path = USERDIR .. PATHSEP .. "renderer"
      if failure == "open" then
        io.open = function(name, mode)
          if name == path and mode == "w" then return nil, "test failure" end
          return context.open(name, mode)
        end
      elseif failure == "write" or failure == "close" then
        io.open = function(name, mode)
          if name == path and mode == "w" then
            local file = assert(context.open(name, mode))
            return {
              write = function(_, value)
                if failure == "write" then return nil, "test failure" end
                return file:write(value)
              end,
              close = function()
                file:close()
                if failure == "close" then return nil, "test failure" end
                return true
              end
            }
          end
          return context.open(name, mode)
        end
      else
        os.remove = function(name)
          if name == path then return nil, "test failure", 13 end
          return context.remove(name)
        end
      end
      select:set_selected(failure == "remove" and 1 or 3)
      test.equal(select:get_selected_data(), "surface")
      test.equal(config.renderer, "surface")
      test.equal(settings.config.renderer, "surface")
      if failure == "open" or failure == "remove" then
        test.equal(read_preference(), "surface\n")
      end
      test.contains(context.error_message, "test failure")
    end)
  end
end)

local function get_keymap_dialog()
  for index = 1, math.huge do
    local name, value = debug.getupvalue(SettingsView.load_keymap_settings, index)
    if not name then break end
    if name == "keymap_dialog" then
      return value
    end
  end
end

test.describe("settings", function()
  local old_test_settings
  local old_settings_config
  local old_settings_plugins
  local old_plugin_sections
  local old_test_settings_module
  local old_disabled_transitions
  local old_toolbar_position
  local old_commandview_position

  test.before_each(function()
    old_test_settings = config.plugins.test_settings
    old_settings_config = settings.config
    old_settings_plugins = settings.plugins
    old_plugin_sections = settings.plugin_sections
    old_test_settings_module = package.preload["plugins.test_settings"]
    old_disabled_transitions = config.disabled_transitions
    old_toolbar_position = config.plugins.treeview.toolbar_position
    old_commandview_position = config.commandview_position
    config.plugins.test_settings = {}
    settings.config = {}
    settings.plugins = {}
    settings.plugin_sections = {}
    os.remove(USERDIR .. "/user_settings.lua")
  end)

  test.after_each(function()
    config.plugins.test_settings = old_test_settings
    settings.config = old_settings_config
    settings.plugins = old_settings_plugins
    settings.plugin_sections = old_plugin_sections
    package.preload["plugins.test_settings"] = old_test_settings_module
    config.disabled_transitions = old_disabled_transitions
    tree:set_toolbar_position(old_toolbar_position)
    config.commandview_position = old_commandview_position
    os.remove(USERDIR .. "/user_settings.lua")
  end)

  test.it("shows standalone config views and persists prefixed values", function()
    local applied
    local view = settings.show_config("Generated Settings", {
      name = "Generated",
      path_prefix = "plugins.test_settings",
      {
        label = "Model",
        path = "model",
        type = settings.type.STRING,
        default = "default",
        get_value = function(value)
          return value .. "-view"
        end,
        set_value = function(value)
          return value .. "-saved"
        end,
        on_apply = function(value)
          applied = value
        end
      }
    })

    test.equal(view.sections, nil)

    local textbox = find_child(view, TextBox)
    test.not_nil(textbox)
    test.equal(textbox:get_text(), "default-view")

    textbox:on_change("custom")

    test.equal(config.plugins.test_settings.model, "custom-saved")
    test.equal(settings.config.plugins.test_settings.model, "custom-saved")
    test.equal(applied, "custom-saved")

    local saved = dofile(USERDIR .. "/user_settings.lua")
    test.equal(saved.config.plugins.test_settings.model, "custom-saved")
  end)

  test.it("applies and saves toolbar docking from its position selector", function()
    local toolbar = tree.toolbar
    local option
    for _, candidate in ipairs(config.plugins.treeview.config_spec) do
      if candidate.path == "toolbar_position" then option = candidate end
    end
    test.not_nil(option)
    local view = settings.show_config("Treeview Settings", {
      path_prefix = "plugins.treeview",
      option
    })
    local selector = find_child(view, SelectBox)
    test.not_nil(selector)
    for index, position in ipairs { "left", "bottom", "top", "right" } do
      selector:set_selected(index)
      test.equal(tree.toolbar_position, position)
      test.equal(toolbar.orientation, (position == "left" or position == "right") and "vertical" or "horizontal")
      test.equal(core.active_view, view)
      test.equal(config.plugins.treeview.toolbar_position, position)
      test.equal(settings.config.plugins.treeview.toolbar_position, position)
      local saved = dofile(USERDIR .. "/user_settings.lua")
      test.equal(saved.config.plugins.treeview.toolbar_position, position)
    end
  end)

  test.it("saves command palette placement from User Interface", function()
    local option
    for _, candidate in ipairs(settings.core["User Interface"]) do
      if candidate.path == "commandview_position" then option = candidate end
    end
    test.not_nil(option)
    test.equal(option.default, "bottom")
    local view = settings.show_config("Palette Settings", { option })
    local selector = find_child(view, SelectBox)
    test.not_nil(selector)
    for index, position in ipairs { "bottom", "top", "center" } do
      selector:set_selected(index)
      test.equal(config.commandview_position, position)
      test.equal(settings.config.commandview_position, position)
      local saved = dofile(USERDIR .. "/user_settings.lua")
      test.equal(saved.config.commandview_position, position)
    end
  end)

  test.it("shows standalone config views with named sections", function()
    local view = settings.show_config("Sectioned Settings", {
      path_prefix = "plugins.test_settings",
      sections = {
        General = {
          {
            label = "Enabled",
            path = "enabled",
            type = settings.type.TOGGLE,
            default = false
          }
        }
      }
    })

    test.not_nil(view.sections)

    local toggle = find_child(view, Toggle)
    test.not_nil(toggle)
    toggle:on_change(true)

    test.equal(config.plugins.test_settings.enabled, true)
    test.equal(settings.config.plugins.test_settings.enabled, true)
  end)

  test.it("persists values from filterable custom widget lists", function()
    config.plugins.test_settings.languages = {}
    local view = settings.show_config("Language Settings", {
      path_prefix = "plugins.test_settings",
      {
        label = "Languages",
        path = "languages",
        type = settings.type.LIST_WIDGETS,
        default = {},
        visible_rows = 2,
        items = {
          { name = "Lua" },
          { name = "Python" }
        },
        item_text = function(item)
          return item.name
        end,
        build_item = function(row, item, value, commit)
          local label = Label(row, item.name)
          row:set_child_properties(label, { stretch = 1 })

          local toggle = Toggle(row, "", value[item.name] == true)
          function toggle:on_change(enabled)
            value[item.name] = enabled and true or nil
            commit(value)
          end

          Button(row, "Action")
        end
      }
    })

    local list = find_child(view, WidgetList)
    test.not_nil(list)
    test.equal(#list.items, 2)

    local lua_toggle
    local found_button = false
    for _, child in ipairs(list.items[1].row.childs) do
      if child:is(Toggle) then lua_toggle = child end
      if child:is(Button) then found_button = true end
    end
    test.not_nil(lua_toggle)
    test.ok(found_button)

    lua_toggle:on_change(true)
    test.equal(config.plugins.test_settings.languages.Lua, true)
    test.equal(settings.config.plugins.test_settings.languages.Lua, true)

    list.scroll.y = 10
    list.scroll.to.y = 10
    list:filter("Python")
    list:relayout()
    test.equal(list.scroll.y, 0)
    test.equal(list.scroll.to.y, 0)
    test.equal(list.items[1].matched, false)
    test.equal(list.items[2].matched, true)

    local saved = dofile(USERDIR .. "/user_settings.lua")
    test.equal(saved.config.plugins.test_settings.languages.Lua, true)
  end)

  test.it("groups disabled transitions in a widget list", function()
    local option
    for _, candidate in ipairs(settings.core.Graphics) do
      if candidate.path == "disabled_transitions" then
        option = candidate
        break
      end
    end

    test.not_nil(option)
    test.equal(option.type, settings.type.LIST_WIDGETS)
    test.equal(option.filterable, false)
    test.equal(option.visible_rows, 10)
    test.equal(#option.items, 10)
    test.equal(option.default.floating, false)

    config.disabled_transitions = {
      floating = false,
      scroll = false,
      commandview = true,
      contextmenu = false,
      logview = false,
      nagbar = false,
      tabs = false,
      tab_drag = false,
      statusbar = false
    }
    local view = settings.show_config("Transition Settings", { option })
    local list = find_child(view, WidgetList)
    test.not_nil(list)
    test.equal(#list.items, 10)

    local scroll_toggle, floating_toggle
    for _, entry in ipairs(list.items) do
      if entry.data.key == "scroll" or entry.data.key == "floating" then
        for _, child in ipairs(entry.row.childs) do
          if child:is(Toggle) then
            if entry.data.key == "scroll" then scroll_toggle = child
            else floating_toggle = child end
            break
          end
        end
      end
    end
    test.not_nil(scroll_toggle)
    test.not_nil(floating_toggle)
    scroll_toggle:on_change(true)
    floating_toggle:on_change(true)

    test.equal(config.disabled_transitions.floating, true)
    test.equal(config.disabled_transitions.scroll, true)
    test.equal(config.disabled_transitions.commandview, true)
    test.equal(settings.config.disabled_transitions.scroll, true)
    test.equal(settings.config.disabled_transitions.floating, true)

    local saved = dofile(USERDIR .. "/user_settings.lua")
    test.equal(saved.config.disabled_transitions.floating, true)
    test.equal(saved.config.disabled_transitions.scroll, true)
    test.equal(saved.config.disabled_transitions.commandview, true)
  end)

  test.it("opens sub config views from settings options", function()
    local old_show_config = settings.show_config
    local opened_title
    local opened_view

    settings.show_config = function(title, spec, context)
      opened_title = title
      opened_view = old_show_config(title, spec, context)
      return opened_view
    end

    local view = old_show_config("Parent Settings", {
      path_prefix = "plugins.test_settings",
      {
        label = "Open Preferences",
        title = "Project Preferences",
        type = settings.type.SUBCONFIG,
        spec = {
          path_prefix = "plugins.test_settings.project",
          {
            label = "Project Name",
            path = "name",
            type = settings.type.STRING,
            default = "Demo"
          }
        }
      }
    })

    local button = find_child(view, Button)
    test.not_nil(button)
    test.equal(button.label, "Open Preferences")
    test.equal(button.icon.code, "P")

    button:on_click()
    settings.show_config = old_show_config

    test.equal(opened_title, "Project Preferences")
    test.not_nil(opened_view)

    local textbox = find_child(opened_view, TextBox)
    test.not_nil(textbox)
    test.equal(textbox:get_text(), "Demo")

    textbox:on_change("Website")

    test.equal(config.plugins.test_settings.project.name, "Website")
    test.equal(settings.config.plugins.test_settings.project.name, "Website")

    local saved = dofile(USERDIR .. "/user_settings.lua")
    test.equal(saved.config.plugins.test_settings.project.name, "Website")
  end)

  test.it("resolves sub config prefixes relative to plugin context", function()
    local old_show_config = settings.show_config
    local opened_view

    settings.show_config = function(title, spec, context)
      opened_view = old_show_config(title, spec, context)
      return opened_view
    end

    local view = old_show_config("Parent Settings", {
      {
        label = "Open Preferences",
        title = "Project Preferences",
        type = settings.type.SUBCONFIG,
        spec = {
          path_prefix = "project",
          {
            label = "Project Name",
            path = "name",
            type = settings.type.STRING,
            default = "Demo"
          }
        }
      }
    }, "test_settings")

    local button = find_child(view, Button)
    test.not_nil(button)
    button:on_click()
    settings.show_config = old_show_config

    local textbox = find_child(opened_view, TextBox)
    test.not_nil(textbox)
    textbox:on_change("Website")

    test.equal(config.plugins.test_settings.project.name, "Website")
    test.equal(settings.config.plugins.test_settings.project.name, "Website")
    test.equal(config.project, nil)

    local saved = dofile(USERDIR .. "/user_settings.lua")
    test.equal(saved.config.plugins.test_settings.project.name, "Website")
  end)

  test.it("inherits plugin paths for sub config views without a prefix", function()
    local old_show_config = settings.show_config
    local opened_view

    settings.show_config = function(title, spec, context)
      opened_view = old_show_config(title, spec, context)
      return opened_view
    end

    local view = old_show_config("Parent Settings", {
      {
        label = "Open Preferences",
        title = "Project Preferences",
        type = settings.type.SUBCONFIG,
        spec = {
          {
            label = "Project Name",
            path = "name",
            type = settings.type.STRING,
            default = "Demo"
          }
        }
      }
    }, "test_settings")

    local button = find_child(view, Button)
    test.not_nil(button)
    button:on_click()
    settings.show_config = old_show_config

    local textbox = find_child(opened_view, TextBox)
    test.not_nil(textbox)
    test.equal(textbox:get_text(), "Demo")

    textbox:on_change("Website")

    test.equal(config.plugins.test_settings.name, "Website")
    test.equal(settings.config.plugins.test_settings.name, "Website")
    test.equal(config.name, nil)
  end)

  test.it("resolves sub config prefixes relative to parent prefixes", function()
    local old_show_config = settings.show_config
    local opened_view

    settings.show_config = function(title, spec, context)
      opened_view = old_show_config(title, spec, context)
      return opened_view
    end

    local view = old_show_config("Parent Settings", {
      path_prefix = "plugins.test_settings",
      {
        label = "Open Preferences",
        title = "Project Preferences",
        type = settings.type.SUBCONFIG,
        spec = {
          path_prefix = "project",
          {
            label = "Project Name",
            path = "name",
            type = settings.type.STRING,
            default = "Demo"
          }
        }
      }
    })

    local button = find_child(view, Button)
    test.not_nil(button)
    button:on_click()
    settings.show_config = old_show_config

    local textbox = find_child(opened_view, TextBox)
    test.not_nil(textbox)
    textbox:on_change("Website")

    test.equal(config.plugins.test_settings.project.name, "Website")
    test.equal(settings.config.plugins.test_settings.project.name, "Website")
    test.equal(config.project, nil)

    local saved = dofile(USERDIR .. "/user_settings.lua")
    test.equal(saved.config.plugins.test_settings.project.name, "Website")
    test.equal(saved.config.project, nil)
  end)

  test.it("loads runtime sub config values into generated views", function()
    local old_show_config = settings.show_config
    local opened_view

    config.plugins.test_settings = {
      project = {
        name = "Website"
      }
    }

    settings.show_config = function(title, spec, context)
      opened_view = old_show_config(title, spec, context)
      return opened_view
    end

    local view = old_show_config("Parent Settings", {
      path_prefix = "plugins.test_settings",
      {
        label = "Open Preferences",
        title = "Project Preferences",
        type = settings.type.SUBCONFIG,
        spec = {
          path_prefix = "project",
          {
            label = "Project Name",
            path = "name",
            type = settings.type.STRING,
            default = "Demo"
          }
        }
      }
    })

    local button = find_child(view, Button)
    test.not_nil(button)
    button:on_click()
    settings.show_config = old_show_config

    local textbox = find_child(opened_view, TextBox)
    test.not_nil(textbox)
    test.equal(textbox:get_text(), "Website")
  end)

  test.it("merges saved plugin sub config values into global config", function()
    package.preload["plugins.test_settings"] = function()
      config.plugins.test_settings.config_spec = {
        name = "Test Settings",
        {
          label = "Open Preferences",
          title = "Project Preferences",
          type = settings.type.SUBCONFIG,
          spec = {
            path_prefix = "project",
            sections = {
              General = {
                {
                  label = "Project Name",
                  path = "name",
                  type = settings.type.STRING,
                  default = "Demo"
                }
              }
            }
          }
        }
      }
      return true
    end

    settings.config = {
      plugins = {
        test_settings = {
          project = {
            name = "Website"
          }
        }
      }
    }

    SettingsView.enable_plugin(settings.ui, "test_settings")

    test.equal(config.plugins.test_settings.project.name, "Website")
  end)

  test.it("resets custom keybindings for commands without default bindings", function()
    local command_name = "test-settings:no-default-binding"
    local binding = "ctrl+shift+f12"
    local old_command = command.map[command_name]
    local old_defaults = settings.default_keybindings[command_name]
    local old_bindings = { keymap.get_binding(command_name) }

    command.add(nil, {
      [command_name] = function() end
    })
    settings.default_keybindings[command_name] = nil
    settings.config.custom_keybindings = {
      [command_name] = { binding }
    }
    keymap.add({ [binding] = command_name })

    local keymap_dialog = get_keymap_dialog()
    test.not_nil(keymap_dialog)
    keymap_dialog.command = command_name
    keymap_dialog.row_id = 1
    keymap_dialog.listbox = {
      row = nil,
      set_row = function(self, idx, row)
        self.row = row
      end
    }

    keymap_dialog:on_reset()

    test.same({ keymap.get_binding(command_name) }, {})
    test.equal(settings.config.custom_keybindings[command_name], nil)
    test.not_nil(keymap_dialog.listbox.row)

    keymap.unbind(binding, command_name)
    for _, old_binding in ipairs(old_bindings) do
      keymap.add({ [old_binding] = command_name })
    end
    command.map[command_name] = old_command
    settings.default_keybindings[command_name] = old_defaults
  end)

end)
