local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local style = require "core.style"
local test = require "core.test"
local View = require "core.view"
local RootView = require "core.rootview"
local MenuView = require "core.menuview"
local TitleView = require "core.titleview"

---Allow locked node sizes to reach their updated view geometry.
---@param frames? integer Number of update passes
local function settle(frames)
  for _ = 1, frames or 3 do core.root_view:update() end
end

---Draw final node geometry so TitleView can synchronize its native hit regions.
local function draw_frame()
  renderer.begin_frame(core.window)
  core.root_view:draw()
  renderer.end_frame()
end

test.describe("borderless application menu", function()
  test.before_each(function(context)
    context.root, context.active, context.last, context.next = core.root_view, core.active_view, core.last_active_view, core.next_active_view
    context.title, context.menu = core.title_view, core.menu_view
    context.transitions, context.shown = config.transitions, config.show_menubar
    context.animation, context.rate = config.animation_type, config.animation_rate
    context.fps, context.config_fps = core.fps, config.fps
    context.menu_transition = config.disabled_transitions.menubar
    context.redraw = core.redraw
    context.scale, context.font, context.icons, context.padding = SCALE, style.font, style.icon_font, style.padding
    context.native, context.draw_text = system.set_window_hit_test, common.draw_text
    context.push_clip = core.push_clip_rect
    context.calls = {}
    system.set_window_hit_test = function(...)
      context.calls[#context.calls + 1] = table.pack(...)
    end
    config.transitions, config.show_menubar = false, true
    core.root_view = RootView()
    core.root_view.root_node.is_primary_node = true
    core.root_view.size.x, core.root_view.size.y = 1100, 700
    core.title_view, core.menu_view = TitleView(), MenuView()
    core.root_view.root_node:split("up", core.title_view, { y = true })
    core.root_view.root_node.b:split("up", core.menu_view, { y = true })
    context.view = View()
    core.root_view:get_primary_node():add_view(context.view)
    settle()
    draw_frame()
  end)

  test.after_each(function(context)
    core.menu_view.menu:hide()
    core.root_view:cancel_mouse_capture()
    core.root_view, core.active_view, core.last_active_view, core.next_active_view = context.root, context.active, context.last, context.next
    core.title_view, core.menu_view = context.title, context.menu
    config.transitions, config.show_menubar = context.transitions, context.shown
    config.animation_type, config.animation_rate = context.animation, context.rate
    config.disabled_transitions.menubar = context.menu_transition
    core.fps, config.fps = context.fps, context.config_fps
    SCALE, style.font, style.icon_font, style.padding = context.scale, context.font, context.icons, context.padding
    system.set_window_hit_test, common.draw_text = context.native, context.draw_text
    core.push_clip_rect = context.push_clip
    core.redraw = context.redraw
  end)

  test.test("shares one title row and returns hidden menu space to the title", function(context)
    local title, bar = core.title_view, core.menu_view
    local document_y, document_height = context.view.position.y, context.view.size.y
    local x, y, width, height = bar:get_bounds()
    test.ok(bar.bounds)
    test.equal(bar.size.y, 0)
    test.equal(title.size.y, height)
    test.ok(x > title.position.x)
    test.ok(width > 0)
    local call = context.calls[#context.calls]
    test.equal(call[5].x, x)
    test.equal(call[5].y, y)
    test.equal(call[5].w, width)
    test.equal(call[5].h, height)

    local title_x, title_clip, last_clip
    core.push_clip_rect = function(...)
      last_clip = { ... }
      return context.push_clip(...)
    end
    common.draw_text = function(font, color, text, align, bx, by, w, h)
      if text == core.compose_window_title(core.window_title) then
        title_x, title_clip = bx, last_clip
      end
      return context.draw_text(font, color, text, align, bx, by, w, h)
    end
    renderer.begin_frame(core.window); core.root_view:draw(); renderer.end_frame()
    local spacing = style.padding.x * 2 + style.divider_size
    test.equal(title_x, x + width + spacing)
    local _, _, available = title:get_menu_bounds()
    test.equal(title_clip[3], available - width - spacing)

    command.perform("menu-bar:toggle"); settle()
    test.equal(bar.inline_width, 0)
    renderer.begin_frame(core.window); core.root_view:draw(); renderer.end_frame()
    test.is_nil(context.calls[#context.calls][5])
    test.equal(title_x, x)
    test.equal(title_clip[3], available)
    test.equal(context.view.position.y, document_y)
    test.equal(context.view.size.y, document_height)
  end)

  test.test("label clicks and switching preserve document focus and popup ownership", function(context)
    local bar = core.menu_view
    local x, y, _, height = bar:get_bounds()
    local next_x
    for index, _, bx in bar:each_label() do if index == 2 then next_x = bx end end
    core.root_view:on_mouse_moved(x + 1, y + height / 2, 0, 0)
    core.root_view:on_mouse_pressed("left", x + 1, y + height / 2, 1)
    core.root_view:on_mouse_released("left", x + 1, y + height / 2)
    test.equal(core.active_view, context.view)
    test.ok(bar.menu.show_context_menu)
    test.equal(bar.active_menu, 1)
    test.equal(bar.menu.floating_options.owner, bar)
    local anchor = bar.menu.floating_options.anchor.target()
    test.equal(anchor.x, x)
    test.equal(anchor.y + anchor.h, y + height)
    core.root_view:on_mouse_moved(next_x + 1, y + height / 2, next_x - x, 0)
    test.equal(bar.active_menu, 2)
    core.root_view:on_mouse_pressed("left", next_x + 1, y + height / 2, 1)
    core.root_view:on_mouse_released("left", next_x + 1, y + height / 2)
    test.not_ok(bar.menu.show_context_menu)
    test.equal(core.active_view, context.view)
  end)

  test.test("title and document clicks dismiss popups without taking title focus", function(context)
    core.menu_view:open(1)
    local x, y, width, height = core.menu_view:get_bounds()
    core.root_view:on_mouse_pressed("left", x + width + 1, y + height / 2, 1)
    core.root_view:on_mouse_released("left", x + width + 1, y + height / 2)
    test.not_ok(core.menu_view.menu.show_context_menu)
    test.equal(core.active_view, context.view)
    core.menu_view:open(1)
    core.root_view:on_mouse_pressed("left", 1000, 650, 1)
    core.root_view:on_mouse_released("left", 1000, 650)
    test.not_ok(core.menu_view.menu.show_context_menu)
  end)

  test.test("hidden menus remain keyboard-accessible below the title bar", function(context)
    core.menu_view:hide(); settle()
    test.ok(command.perform("menu-bar:open"))
    local bar = core.menu_view
    test.ok(bar.menu.show_context_menu)
    test.equal(bar.active_menu, 0)
    local anchor = bar.menu.floating_options.anchor.target()
    test.equal(anchor.y + anchor.h, core.title_view.size.y)
    test.equal(core.active_view, context.view)
    test.not_ok(config.show_menubar)
  end)

  test.test("switches hosts without retaining a popup or an extra row", function()
    local bar = core.menu_view
    local entries = bar.items
    bar:open(1)
    core.title_view.visible = false; settle()
    test.not_ok(bar.bounds)
    test.not_ok(bar.menu.show_context_menu)
    test.equal(core.title_view.size.y, 0)
    test.equal(bar.size.y, style.font:get_height() + style.padding.y * 2)
    test.equal(bar.items, entries)
    bar:open(1)
    core.title_view.visible = true; settle()
    test.ok(bar.bounds)
    test.not_ok(bar.menu.show_context_menu)
    test.equal(bar.size.y, 0)
    test.equal(bar.items, entries)
  end)

  test.test("keeps labels and hit regions within narrow window controls", function()
    for _, width in ipairs { 1100, 250, 100, 600, 1100 } do
      core.root_view.size.x = width; settle()
      local bar = core.menu_view
      local x, y, available = core.title_view:get_menu_bounds()
      local _, _, occupied, height = bar:get_bounds()
      test.ok(occupied <= available)
      test.equal(bar.compact, bar:measure_labels().width > available)
      test.not_ok(bar:hit_test(x + occupied, y + height / 2))
      if occupied > 0 then test.not_nil(bar:label_at(x + 1, y + height / 2)) end
    end
  end)

  test.test("rescales embedded geometry up and down at fractional scales", function(context)
    for _, factor in ipairs { 1, 1.25, 1.5, 2, 1.25, 1 } do
      local ratio = factor / context.scale
      SCALE = factor
      style.font = context.font:copy(context.font:get_size() * ratio)
      style.icon_font = context.icons:copy(context.icons:get_size() * ratio)
      style.padding = { x = context.padding.x * ratio, y = context.padding.y * ratio }
      settle()
      draw_frame()
      local x, y, width, height = core.menu_view:get_bounds()
      test.equal(core.title_view.size.y, style.font:get_height() + style.padding.y * 2)
      test.equal(core.menu_view.size.y, 0)
      local call = context.calls[#context.calls]
      test.equal(call[2], height)
      test.equal(call[5].x, x)
      test.equal(call[5].y, y)
      test.equal(call[5].w, width)
    end
  end)

  test.test("slides horizontally while keeping document layout fixed", function(context)
    local bar = core.menu_view
    local width, document_y = bar.inline_width, context.view.position.y
    config.transitions, config.animation_type = true, "lerp"
    core.fps, config.fps, config.animation_rate = 60, 60, 1
    config.disabled_transitions.menubar = false
    bar:hide(); settle(1)
    test.ok(bar.inline_width > 0 and bar.inline_width < width)
    test.equal(bar.size.y, 0)
    test.equal(context.view.position.y, document_y)
    local x, y = bar:get_bounds()
    test.is_nil(bar:label_at(x + 1, y + 1))
    settle(60)
    test.equal(bar.inline_width, 0)
    draw_frame()
    test.is_nil(context.calls[#context.calls][5])
    bar:show(); settle(1)
    test.ok(bar.inline_width > 0 and bar.inline_width < width)
    test.equal(context.view.position.y, document_y)
    config.disabled_transitions.menubar = true; settle(1)
    test.equal(bar.inline_width, width)
    bar:hide(); settle(1)
    test.equal(bar.inline_width, 0)
  end)

  test.test("idle layout and drawing reuse measurements and native hit regions", function(context)
    local visible_calls = 0
    core.menu_view:register({}, {
      { id = "title-test", text = "Test", items = {}, visible = function()
        visible_calls = visible_calls + 1
        return true
      end }
    })
    settle()
    draw_frame()
    local layout = core.menu_view.label_layout
    local calls = #context.calls
    for _ = 1, 5 do
      settle(1)
      renderer.begin_frame(core.window); core.root_view:draw(); renderer.end_frame()
    end
    test.equal(core.menu_view.label_layout, layout)
    test.equal(visible_calls, 1)
    test.equal(#context.calls, calls)
    core.redraw = false
    core.menu_view:update()
    core.title_view:update()
    test.not_ok(core.redraw)
  end)
end)
