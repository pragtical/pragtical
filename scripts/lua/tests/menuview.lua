local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local keymap = require "core.keymap"
local View = require "core.view"
local RootView = require "core.rootview"
local MenuView = require "core.menuview"
local ContextMenu = require "core.contextmenu"
local test = require "core.test"
local style = require "core.style"

local menu_modifier = PLATFORM == "Mac OS X" and "left option" or "left alt"

---Track an independent menu so its popups are removed before restoring the root.
---@param context table Current test context
---@param items core.contextmenu.item[] Initial independent entries
---@return core.menuview menu Independent menu
local function independent_menu(context, items)
  local menu = MenuView(items)
  context.menus[#context.menus + 1] = menu
  return menu
end

test.describe("application menu", function()
  test.before_each(function(context)
    context.root, context.active, context.last, context.next, context.bar = core.root_view, core.active_view, core.last_active_view, core.next_active_view, core.menu_view
    context.transitions, context.enabled = config.transitions, config.show_menubar
    context.fps, context.config_fps = core.fps, config.fps
    context.animation_type, context.animation_rate = config.animation_type, config.animation_rate
    context.menu_transition = config.disabled_transitions.menubar
    context.draw_text = common.draw_text
    context.open_in_system = common.open_in_system
    context.modkeys = keymap.modkeys
    context.scale, context.font, context.padding = SCALE, style.font, style.padding
    keymap.modkeys = {}
    core.root_view = RootView(); core.root_view.root_node.is_primary_node = true
    core.root_view.size.x, core.root_view.size.y = 900, 600
    config.transitions, config.show_menubar = false, true
    core.menu_view = MenuView()
    core.root_view.root_node:split("up", core.menu_view, { y = true })
    context.view = View()
    core.root_view:get_primary_node():add_view(context.view)
    core.root_view:update()
    core.root_view:update()
    context.handles = {}
    context.commands = {}
    context.menus = {}
  end)
  test.after_each(function(context)
    core.menu_view.menu:hide()
    for _, menu in ipairs(context.menus) do menu:hide() end
    for _, handle in ipairs(context.handles) do core.menu_view:unregister(handle) end
    for _, entry in ipairs(context.commands) do command.map[entry.name] = entry.previous end
    core.root_view, core.active_view, core.last_active_view, core.next_active_view, core.menu_view = context.root, context.active, context.last, context.next, context.bar
    config.transitions, config.show_menubar = context.transitions, context.enabled
    core.fps, config.fps = context.fps, context.config_fps
    config.animation_type, config.animation_rate = context.animation_type, context.animation_rate
    config.disabled_transitions.menubar = context.menu_transition
    common.draw_text = context.draw_text
    common.open_in_system = context.open_in_system
    keymap.modkeys = context.modkeys
    SCALE, style.font, style.padding = context.scale, context.font, context.padding
    if context.opener_binding then
      local binding = context.opener_binding
      keymap.map[binding.stroke] = binding.commands
      keymap.reverse_map["menu-bar:open"] = binding.shortcuts
    end
  end)

  test.test("independent menus keep entries, visibility, and caches separate", function(context)
    local first = independent_menu(context, { { id = "first", text = "First", items = {} } })
    local second = independent_menu(context, {})
    test.not_ok(first.application_menu)
    test.is_nil(first.defaults)
    test.ok(first.visible)
    test.equal(#first.items, 1)
    test.equal(#second.items, 0)
    test.ok(core.menu_view.application_menu)
    local entries = first:entries()
    second:register({}, { { id = "second", text = "Second", items = {} } })
    test.equal(first:entries(), entries)
    test.equal(first.items[1].id, "first")
    test.equal(second.items[1].id, "second")
    first:hide()
    test.not_ok(first.visible)
    test.ok(second.visible)
    test.ok(config.show_menubar)
    config.show_menubar = false
    second:update()
    test.ok(second.visible)
    first:show()
    test.ok(first.visible)
    test.not_ok(config.show_menubar)
    second:toggle()
    test.not_ok(second.visible)
    test.ok(first.visible)
    test.not_ok(config.show_menubar)
  end)

  test.test("explicit bounds drive drawing and popup anchors without refreshing callbacks", function(context)
    local calls = 0
    local menu = independent_menu(context, {
      { id = "local", text = "Local", items = { { id = "run", text = "Run", command = function() end } },
        visible = function() calls = calls + 1; return true end }
    })
    menu.position.x, menu.position.y, menu.size.x = 700, 500, 800
    menu:set_bounds(40.5, 55.25, 300, 32)
    test.equal(calls, 0)
    test.equal(menu.position.x, 700)
    test.equal(menu.position.y, 500)
    menu:update()
    test.equal(calls, 1)
    local x, y, width, height = menu:get_bounds()
    test.equal(x, 40.5)
    test.equal(y, 55.25)
    test.equal(height, 32)
    test.ok(width > 0 and width <= 300)
    test.equal(menu.size.y, 0)
    test.not_ok(menu:hit_test(701, 501))
    test.equal(menu:label_at(x + 1, y + 1), 1)
    local text_x, text_y
    common.draw_text = function(font, color, text, align, bx, by, w, h)
      if text == "Local" then text_x, text_y = bx, by end
      return context.draw_text(font, color, text, align, bx, by, w, h)
    end
    renderer.begin_frame(core.window); menu:draw(); renderer.end_frame()
    test.equal(text_x, x)
    test.equal(text_y, y)
    menu:open(1)
    test.equal(calls, 2)
    local inline_width = menu.inline_width
    menu:set_bounds(130, 160, 300, 32)
    test.equal(calls, 2)
    test.equal(menu.inline_width, inline_width)
    test.ok(menu.menu.show_context_menu)
    local anchor = menu.menu.floating_options.anchor.target()
    test.equal(anchor.x, 130)
    test.equal(anchor.y + anchor.h, 192)
    test.not_ok(menu:hit_test(x + 1, y + 1))
    test.equal(menu:label_at(131, 161), 1)
    menu:hide()
    test.not_ok(menu.menu.show_context_menu)
    test.ok(config.show_menubar)
  end)

  test.test("a plain view can host menus and forward pointer and keyboard navigation", function(context)
    local performed = 0
    local menu = independent_menu(context, {
      { id = "first", text = "First", items = {
        { id = "nested", text = "Nested", items = {
          { id = "run", text = "Run", command = function() performed = performed + 1 end }
        } }
      } },
      { id = "second", text = "Second", items = { { id = "other", text = "Other", command = function() end } } }
    })
    local host = View()
    ---Place and update the independently owned menu once per host update.
    function host:update()
      menu:set_bounds(self.position.x + 35, self.position.y + 15, 300, 30)
      menu:update()
    end
    ---Refresh final geometry before painting the hosted labels.
    function host:draw()
      menu:set_bounds(self.position.x + 35, self.position.y + 15, 300, 30)
      menu:draw()
    end
    ---Forward presses inside the menu while retaining normal host content input.
    function host:on_mouse_pressed(button, x, y, clicks)
      if menu:hit_test(x, y) then return menu:on_mouse_pressed(button, x, y, clicks) end
      return View.on_mouse_pressed(self, button, x, y, clicks)
    end
    ---Forward movement so labels can switch and clear hover.
    function host:on_mouse_moved(...) menu:on_mouse_moved(...) end
    ---Clear label hover when the pointer leaves the host.
    function host:on_mouse_left() menu:on_mouse_left() end
    core.root_view:get_primary_node():add_view(host)
    core.root_view:update(); core.root_view:update()
    renderer.begin_frame(core.window); core.root_view:draw(); renderer.end_frame()
    local x, y = menu:get_bounds()
    core.root_view:on_mouse_moved(x + 1, y + 1, 0, 0)
    core.root_view:on_mouse_pressed("left", x + 1, y + 1, 1)
    core.root_view:on_mouse_released("left", x + 1, y + 1)
    test.ok(menu.menu.show_context_menu)
    test.equal(core.active_view, host)
    core.on_event("keypressed", "down")
    core.on_event("keypressed", "right")
    test.ok(menu.menu.child_menu.show_context_menu)
    core.on_event("keypressed", "return")
    test.equal(performed, 1)
    test.not_ok(menu.menu.show_context_menu)
    test.equal(core.active_view, host)
    menu:open(1)
    for index, _, bx in menu:each_label() do
      if index == 2 then core.root_view:on_mouse_moved(bx + 1, y + 1, 0, 0) end
    end
    test.equal(menu.active_menu, 2)
    core.root_view:on_mouse_pressed("left", 850, 550, 1)
    core.root_view:on_mouse_released("left", 850, 550)
    test.not_ok(menu.menu.show_context_menu)
  end)

  test.test("bounds resizing uses cached compact layout and zero sizes retain explicit bounds", function(context)
    local menu = independent_menu(context, {
      { id = "first", text = "First", items = { { id = "run", text = "Run", command = function() end } } },
      { id = "second", text = "Second", items = {} }
    })
    menu:set_bounds(50, 80, 300, 30); menu:update(); menu:open(1)
    local layout = menu.label_layout
    menu:set_bounds(60, 90, 30, 30)
    test.ok(menu.compact)
    test.not_ok(menu.menu.show_context_menu)
    test.equal(menu.label_layout, layout)
    local _, _, width = menu:get_bounds()
    test.equal(width, 30)
    test.equal(menu:label_at(61, 91), 0)
    for _, size in ipairs { { 0, 30 }, { 30, 0 }, { 0, 0 } } do
      menu:set_bounds(60, 90, size[1], size[2]); menu:update()
      test.ok(menu.bounds)
      test.equal(menu.size.y, 0)
      test.not_ok(menu:hit_test(60, 90))
    end
    menu:set_bounds(60, 90, 300, 30); menu:update(); menu:open(1)
    menu:set_bounds()
    test.is_nil(menu.bounds)
    test.not_ok(menu.menu.show_context_menu)
    menu.size.x = 300; menu:update()
    test.equal(menu.size.y, style.font:get_height() + style.padding.y * 2)
    menu:set_bounds(70, 100, 300, 30); menu:update()
    test.equal(menu.size.y, 0)
    test.ok(menu.inline_width > 0)
  end)

  test.test("width transitions finish before the hidden fast path and idle bounds do not redraw", function(context)
    local calls = 0
    local menu = independent_menu(context, {
      { id = "local", text = "Local", items = {}, visible = function() calls = calls + 1; return true end }
    })
    menu:set_bounds(20, 40, 300, 30); menu:update()
    local width, layout, bounds = menu.inline_width, menu.label_layout, menu.bounds
    local redraw = core.redraw
    core.redraw = false
    menu:set_bounds(20, 40, 300, 30); menu:update()
    test.not_ok(core.redraw)
    core.redraw = redraw
    test.equal(menu.label_layout, layout)
    test.equal(menu.bounds, bounds)
    test.equal(calls, 1)
    config.transitions, config.animation_type = true, "lerp"
    config.disabled_transitions.menubar = false
    core.fps, config.fps, config.animation_rate = 60, 60, 1
    menu:hide(); menu:update()
    test.ok(menu.inline_width > 0 and menu.inline_width < width)
    for _ = 1, 60 do menu:update() end
    test.equal(menu.inline_width, 0)
    local hidden_calls = 0
    menu:register({}, { { id = "hidden", text = "Hidden", items = {},
      visible = function() hidden_calls = hidden_calls + 1; return true end } })
    for _ = 1, 5 do menu:update() end
    test.equal(hidden_calls, 0)
    menu:show(); menu:update()
    test.equal(hidden_calls, 1)
    test.ok(menu.inline_width > 0)
    for _ = 1, 60 do menu:update() end
    menu:hide(); menu:update(); menu:show(); menu:update()
    test.ok(menu.inline_width > 0)
  end)

  for _, transitions in ipairs { false, true } do
    test.test("resizes both ways after scaling with transitions " .. tostring(transitions), function(context)
      config.transitions = transitions
      config.animation_type = "lerp"
      core.fps, config.fps = 60, 60
      for _, factor in ipairs { 1, 2, 1.25, 3, 1.5, 1 } do
        local ratio = factor / context.scale
        SCALE = factor
        style.font = context.font:copy(context.font:get_size() * ratio)
        style.padding = { x = context.padding.x * ratio, y = context.padding.y * ratio }
        for _ = 1, 60 do core.root_view:update() end
        test.equal(core.menu_view.size.y, style.font:get_height() + style.padding.y * 2)
      end
    end)
  end

  test.test("falls back to one button when all labels no longer fit", function()
    test.not_ok(core.menu_view.compact)
    core.root_view.size.x = 80; core.root_view:update(); core.root_view:update()
    test.ok(core.menu_view.compact)
    local count = 0
    for _, text in core.menu_view:each_label() do count = count + 1; test.equal(text, "Menu") end
    test.equal(count, 1)
    core.menu_view:open()
    test.equal(#core.menu_view.menu.items, #core.menu_view.items)
  end)

  test.test("bar clicks keep document command focus", function(context)
    core.on_event("mousepressed", "left", 10, 10, 1)
    core.on_event("mousereleased", "left", 10, 10)
    test.equal(core.active_view, context.view)
    test.equal(core.menu_view.menu.items[1].command, "core:new-doc")
  end)

  test.test("dynamic submenus are populated once per opening and refreshed on reopening", function(context)
    local calls, label = 0, "First session"
    local handle = core.menu_view:register({ "file" }, {
      { id = "dynamic", text = "Sessions", items = function()
        calls = calls + 1
        return { { id = "session", text = label, command = "core:new-doc" } }
      end }
    }, "dynamic-test")
    context.handles[#context.handles + 1] = handle
    core.root_view:update(); core.root_view:update()
    test.equal(calls, 0)
    core.menu_view:open(1)
    local menu = core.menu_view.menu
    for i, item in ipairs(menu.items) do if item.id == "dynamic" then menu.selected = i end end
    test.equal(calls, 0)
    menu:open_submenu()
    test.equal(calls, 1)
    test.equal(menu.child_menu.items[1].text, "First session")
    label = "Second session"
    for _ = 1, 10 do
      core.root_view:update()
      menu:open_submenu()
      renderer.begin_frame(core.window); core.root_view:draw(); renderer.end_frame()
    end
    test.equal(calls, 1)
    test.equal(menu.child_menu.items[1].text, "First session")
    menu.child_menu:hide()
    menu:open_submenu()
    test.equal(calls, 2)
    test.equal(menu.child_menu.items[1].text, "Second session")
  end)

  test.test("top-level arrows leave entries unselected until Down", function(context)
    core.on_event("keypressed", menu_modifier)
    core.on_event("keypressed", "m")
    core.on_event("keyreleased", "m")
    core.on_event("keyreleased", menu_modifier)
    local bar, menu = core.menu_view, core.menu_view.menu
    test.ok(menu.show_context_menu)
    test.equal(bar:entries()[bar.active_menu].id, "file")
    test.equal(menu.selected, -1)
    for _, id in ipairs { "edit", "search", "view", "tools", "help", "file" } do
      core.on_event("keypressed", "right")
      core.root_view:update()
      test.equal(bar:entries()[bar.active_menu].id, id)
      test.equal(menu.selected, -1)
      test.is_nil(menu.child_menu)
    end
    for _, id in ipairs { "help", "tools", "view" } do
      core.on_event("keypressed", "left")
      test.equal(bar:entries()[bar.active_menu].id, id)
      test.equal(menu.selected, -1)
      test.is_nil(menu.child_menu)
    end
    core.on_event("keypressed", "down")
    test.equal(menu:get_item_selected().id, "split")
    core.on_event("keypressed", "right")
    test.equal(bar:entries()[bar.active_menu].id, "view")
    test.ok(menu.child_menu.show_context_menu)
    test.equal(core.active_view, context.view)
  end)

  test.test("the menu shortcut closes a shown application menu", function(context)
    core.on_event("keypressed", menu_modifier)
    core.on_event("keypressed", "m")
    test.ok(core.menu_view.menu.show_context_menu)
    core.on_event("keypressed", "m")
    test.not_ok(core.menu_view.menu.show_context_menu)
    core.on_event("keyreleased", "m")
    core.on_event("keyreleased", menu_modifier)
    test.equal(core.active_view, context.view)
  end)

  test.test("a configured opener closes the application menu", function(context)
    local stroke = "f9"
    context.opener_binding = {
      stroke = stroke,
      commands = keymap.map[stroke],
      shortcuts = keymap.reverse_map["menu-bar:open"]
    }
    keymap.map[stroke] = nil
    keymap.reverse_map["menu-bar:open"] = {
      table.unpack(context.opener_binding.shortcuts or {})
    }
    keymap.add { [stroke] = "menu-bar:open" }
    core.on_event("keypressed", stroke)
    test.ok(core.menu_view.menu.show_context_menu)
    core.on_event("keypressed", stroke)
    test.not_ok(core.menu_view.menu.show_context_menu)
    test.equal(core.active_view, context.view)
  end)

  test.test("Option-modified bindings dismiss menus and continue to command dispatch", function()
    core.menu_view:open()
    test.not_ok(core.menu_view.menu:on_key_pressed("option+shift+m"))
    test.not_ok(core.menu_view.menu.show_context_menu)
  end)

  test.test("uses live command predicates and bindings", function(context)
    local name, stroke = "appmenu-test:run", "ctrl+alt+9"
    local previous, previous_binding = command.map[name], keymap.map[stroke]
    local previous_reverse = keymap.reverse_map[name]
    local enabled, performed = false, 0
    command.add(function() return enabled and core.active_view == context.view end, {
      [name] = function() performed = performed + 1 end
    })
    keymap.add { [stroke] = name }
    local menu = core.menu_view.menu
    menu:show_items({ { id = "run", text = "Run", command = name } }, 0, 30, { disabled = true })
    test.equal(menu.items[1].enabled, false)
    test.equal(menu.items[1].info, keymap.get_binding(name))
    menu:focus_next(); test.equal(menu.selected, -1)
    enabled = true; menu:update(); menu:focus_next()
    test.equal(menu.selected, 1)
    core.on_event("keypressed", "return")
    test.equal(performed, 1); test.equal(core.active_view, context.view)
    command.map[name], keymap.map[stroke], keymap.reverse_map[name] = previous, previous_binding, previous_reverse
  end)

  test.test("registers nested plugin entries and removes only their contribution", function(context)
    local entries = {
      { id = "plugin-test", text = "Plugin Test", items = {
        { id = "deep", text = "Deeper", items = { { id = "action", text = "Action", command = function() end } } }
      } }, MenuView.DIVIDER
    }
    local handle = core.menu_view:register({ "tools" }, entries)
    context.handles[#context.handles + 1] = handle
    local tools = core.menu_view.items[5].items
    test.equal(tools[#tools - 1].id, "plugin-test")
    local length = #tools
    core.menu_view:unregister(handle); core.menu_view:unregister(handle)
    test.equal(#tools, length - 2)
  end)

  test.test("invalid menu fields identify their nested registration path", function()
    for _, entry in ipairs {
      { id = "bad", text = "Bad", command = 42 },
      { id = "bad", text = "Bad", items = true },
      { id = "bad", text = "Bad", checked = "yes" },
      { id = "bad", text = "Bad", visible = 1 },
      { id = "bad", text = false },
      { id = "bad", text = "Bad", command = function() end, items = {} }
    } do
      test.error(function()
        core.menu_view:register({ "tools" }, {
          { id = "plugin", text = "Plugin", items = { entry } }
        })
      end, "tools/plugin/bad")
    end
    test.error(function() core.menu_view:register("tools", {}) end, "path")
    test.error(function() core.menu_view:register({ false }, {}) end, "path IDs")
    test.error(function() core.menu_view:register({ "tools" }, { false }) end, "tools[1]")
  end)

  test.test("invalid named replacements preserve entries and registry revision", function(context)
    local handle = core.menu_view:register({ "tools" }, {
      { id = "replacement", text = "Original", command = function() end }
    }, "validation-test")
    context.handles[#context.handles + 1] = handle
    local revision = core.menu_view.revision
    test.error(function()
      core.menu_view:register({ "tools" }, {
        { id = "replacement", text = "Invalid", items = false }
      }, "validation-test")
    end, "submenu")
    test.equal(core.menu_view.revision, revision)
    test.equal(core.menu_view.registrations["validation-test"], handle)
    test.equal(handle.target[#handle.target], handle.entries[1])
  end)

  test.test("core menus open without plugin registrations", function(context)
    for i, group in ipairs(core.menu_view.items) do
      core.menu_view:open(i)
      test.ok(core.menu_view.menu.show_context_menu)
      local function check(items)
        for _, item in ipairs(items) do
          if item.items then check(item.items) end
          if type(item.command) == "string" then
            test.not_nil(command.map[item.command], "Unknown core command: " .. item.command)
            test.not_ok(item.command == "core:find-file")
            local plugin_commands = {
              treeview = true, toolbar = true, scale = true,
              ["project-search"] = true, ["plugin-manager"] = true, ui = true
            }
            test.not_ok(plugin_commands[item.command:match("^(.-):")])
          end
        end
      end
      check(group.items)
    end
    test.same(core.menu_view.registrations, {})
  end)

  test.test("Help community links dispatch direct actions and preserve editor focus", function(context)
    local opened = {}
    common.open_in_system = function(url) opened[#opened + 1] = url end
    for index, link in ipairs {
      { id = "discord", url = "https://discord.gg/8V2yJtn3Fc" },
      { id = "github", url = "https://github.com/pragtical" }
    } do
      core.menu_view:open(6)
      core.root_view:update()
      local menu, clicked = core.menu_view.menu, false
      for _, item, x, y, w, h in menu:each_item() do
        if item.id == link.id then
          test.type(item.command, "function")
          test.ok(item.enabled)
          core.on_event("mousemoved", x + w / 2, y + h / 2, 0, 0)
          core.on_event("mousepressed", "left", x + w / 2, y + h / 2, 1)
          core.on_event("mousereleased", "left", x + w / 2, y + h / 2)
          clicked = true
          break
        end
      end
      test.ok(clicked, "Missing Help link: " .. link.id)
      test.equal(#opened, index)
      test.equal(opened[index], link.url)
      test.equal(core.active_view, context.view)
      test.not_ok(menu.show_context_menu)
    end
  end)

  test.test("keeps registrations and cached entries local to each view", function(context)
    local bar, other = core.menu_view, MenuView()
    local cached, other_cached = bar:entries(), other:entries()
    local name = "appmenu-instance-test"
    local function entries(text)
      return { { id = name, text = text, items = {} } }
    end
    local handle = bar:register({}, entries("First"), name)
    context.handles[#context.handles + 1] = handle
    test.not_equal(bar:entries(), cached)
    test.equal(other:entries(), other_cached)
    test.equal(#other.items, #bar.items - 1)
    test.is_nil(other.registrations[name])
    local other_handle = other:register({}, entries("Second"), name)
    test.not_equal(other:entries(), other_cached)
    test.equal(bar.registrations[name], handle)
    test.equal(other.registrations[name], other_handle)
    other:unregister(other_handle)
    test.equal(bar.registrations[name], handle)
    test.equal(bar.items[#bar.items].text, "First")
    test.not_equal(bar.items[1].items, other.items[1].items)
  end)

  test.test("loaded plugins register their own commands", function(context)
    for _, name in ipairs {
      "findfile", "projectsearch", "treeview", "scale", "settings",
      "linewrapping", "detectindent", "codefold", "macro",
      "plugin_manager", "trimwhitespace", "quote", "drawwhitespace"
    } do
      local handle = context.bar.registrations[name]
      if package.loaded["plugins." .. name] then
        test.not_nil(handle, "Missing menu registration for " .. name)
        local function check(items)
          for _, item in ipairs(items) do
            if item.items then check(item.items) end
            if item.command then test.not_nil(command.map[item.command]) end
          end
        end
        check(handle.entries)
      else
        test.is_nil(handle, "Unloaded plugin contributed entries: " .. name)
      end
    end
  end)

  test.test("replaces named registrations without disturbing other plugins", function(context)
    local name = "appmenu-reload-test"
    local first = core.menu_view:register({ "tools" }, {
      { id = "reload-test", text = "Original", command = function() end }
    }, name)
    local other = core.menu_view:register({ "tools" }, {
      { id = "other-test", text = "Other Plugin", command = function() end }
    })
    context.handles[#context.handles + 1] = first
    context.handles[#context.handles + 1] = other
    local tools = first.target
    local length, position = #tools, #tools - 1
    test.error(function()
      core.menu_view:register({ "tools" }, {
        { id = "other-test", text = "Conflict", command = function() end }
      }, name)
    end, "Duplicate menu entry")
    test.equal(core.menu_view.registrations[name], first)
    test.equal(tools[position], first.entries[1])
    local replacement = core.menu_view:register({ "tools" }, {
      { id = "reload-test", text = "Reloaded", command = function() end }
    }, name)
    context.handles[#context.handles + 1] = replacement
    test.equal(#tools, length)
    test.equal(tools[position], replacement.entries[1])
    test.equal(tools[position + 1], other.entries[1])
    core.menu_view:unregister(first)
    test.equal(core.menu_view.registrations[name], replacement)
    core.menu_view:unregister(replacement)
    test.is_nil(core.menu_view.registrations[name])
    test.equal(tools[#tools], other.entries[1])
  end)

  test.test("nested keyboard navigation closes one submenu at a time", function(context)
    local menu = core.menu_view.menu
    menu:show_items({ { id = "a", text = "A", items = {
      { id = "b", text = "B", items = { { id = "c", text = "C", command = function() end } } }
    } } }, 0, 30, { disabled = true })
    menu:focus_next(); core.on_event("keypressed", "right")
    local child = menu.child_menu
    test.ok(child.show_context_menu)
    core.on_event("keypressed", "right")
    test.ok(child.child_menu.show_context_menu)
    core.on_event("keypressed", "escape")
    test.is_nil(child.child_menu); test.ok(child.show_context_menu)
    core.on_event("keypressed", "escape")
    test.is_nil(menu.child_menu); test.ok(menu.show_context_menu)
    core.on_event("keypressed", "escape")
    test.not_ok(menu.show_context_menu)
    test.equal(core.active_view, context.view)
  end)

  test.test("Alt+Shift+M toggles layout space and hidden menus remain accessible", function(context)
    local function toggle()
      core.on_event("keypressed", menu_modifier)
      core.on_event("keypressed", "left shift")
      core.on_event("keypressed", "m")
      core.on_event("keyreleased", "m")
      core.on_event("keyreleased", "left shift")
      core.on_event("keyreleased", menu_modifier)
    end
    core.menu_view:open()
    toggle()
    core.root_view:update(); core.root_view:update()
    test.not_ok(config.show_menubar)
    test.equal(core.menu_view.size.y, 0)
    test.not_ok(core.menu_view.menu.show_context_menu)
    command.perform("menu-bar:open")
    test.ok(core.menu_view.menu.show_context_menu)
    test.equal(core.menu_view.active_menu, 0)
    toggle()
    core.root_view:update()
    test.ok(config.show_menubar)
    test.ok(core.menu_view.size.y > 0)
    test.not_ok(core.menu_view.menu.show_context_menu)
    test.equal(core.active_view, context.view)
  end)

  test.test("does not reevaluate plugin callbacks while drawing nested menus", function(context)
    local name = "appmenu-test:cached"
    context.commands[#context.commands + 1] = { name = name, previous = command.map[name] }
    local predicates, visibility, checked, top_visibility = 0, 0, 0, 0
    command.add(function() predicates = predicates + 1; return true end, { [name] = function() end })
    local handle = core.menu_view:register({}, {
      { id = "cached-test", text = "Cached Test",
        visible = function() top_visibility = top_visibility + 1; return true end,
        items = {
          { id = "submenu", text = "Submenu",
            visible = function() visibility = visibility + 1; return true end,
            items = {
              { id = "action", text = "Action", command = name,
                checked = function() checked = checked + 1; return true end }
            } }
        } }
    })
    context.handles[#context.handles + 1] = handle
    core.root_view:update()
    core.menu_view:open(#core.menu_view:entries())
    core.menu_view.menu:focus_next()
    core.on_event("keypressed", "right")
    test.ok(core.menu_view.menu.child_menu.show_context_menu)
    local counts = { predicates, visibility, checked, top_visibility }
    renderer.begin_frame(core.window)
    local ok, err = pcall(function()
      for _ = 1, 30 do core.root_view:update(); core.root_view:draw() end
    end)
    renderer.end_frame()
    test.ok(ok, err)
    test.same({ predicates, visibility, checked, top_visibility }, counts)
  end)

  for _, animation in ipairs { "lerp", "constant" } do
    test.test("slides the bar open and closed with " .. animation .. " transitions", function(context)
      config.transitions, config.animation_type, config.animation_rate = true, animation, 1
      config.disabled_transitions.menubar = false
      core.fps, config.fps = 60, 60
      local bar = core.menu_view
      local height, top = bar.size.y, context.view.position.y
      bar:open()
      bar:hide()
      test.not_ok(bar.menu.show_context_menu)
      core.root_view:update()
      test.ok(bar.size.y > 0 and bar.size.y < height)
      test.ok(context.view.position.y < top)
      test.is_nil(bar:label_at(10, 1))
      local labels = 0
      common.draw_text = function(...)
        labels = labels + 1
        return context.draw_text(...)
      end
      renderer.begin_frame(core.window)
      local ok, err = pcall(core.root_view.draw, core.root_view)
      renderer.end_frame()
      test.ok(ok, err)
      test.ok(labels > 0)
      local shrinking = bar.size.y
      bar:show()
      core.root_view:update()
      test.ok(bar.size.y > shrinking and bar.size.y < height)
      for _ = 1, 60 do core.root_view:update() end
      test.equal(bar.size.y, height)
      test.equal(context.view.position.y, top)
      bar:hide()
      for _ = 1, 60 do core.root_view:update() end
      test.equal(bar.size.y, 0)
      test.equal(core.root_view:get_primary_node().position.y, core.root_view.position.y)
      bar:show()
      core.root_view:update()
      test.ok(bar.size.y > 0 and bar.size.y < height)
      for _ = 1, 60 do core.root_view:update() end
      test.equal(bar.size.y, height)
      test.equal(core.active_view, context.view)
    end)
  end

  test.test("the menu bar transition can be disabled independently", function()
    config.transitions = true
    config.disabled_transitions.menubar = true
    local height = core.menu_view.size.y
    core.menu_view:hide()
    core.root_view:update()
    test.equal(core.menu_view.size.y, 0)
    core.menu_view:show()
    core.root_view:update()
    test.equal(core.menu_view.size.y, height)
  end)
end)
