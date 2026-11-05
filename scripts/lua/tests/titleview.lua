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
---@param window? renwindow Optional separate render target
local function draw_frame(window)
  renderer.begin_frame(window or core.window)
  local clip_stack = core.clip_rect_stack
  if window then
    local width, height = window:get_size()
    core.clip_rect_stack = { { 0, 0, width, height } }
    renderer.set_clip_rect(0, 0, width, height)
  end
  core.root_view:draw()
  renderer.end_frame()
  core.clip_rect_stack = clip_stack
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
    context.focus, context.overlay = system.window_has_focus, config.borderless_unfocused_overlay
    context.platform, context.borderless, context.mode = PLATFORM, config.borderless, core.window_mode
    context.outline = config.borderless_outline
    context.focused_outline = config.outline_focused
    context.unfocused_outline = config.outline_unfocused
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
    system.window_has_focus, config.borderless_unfocused_overlay = context.focus, context.overlay
    PLATFORM, config.borderless, core.window_mode = context.platform, context.borderless, context.mode
    config.borderless_outline = context.outline
    config.outline_focused = context.focused_outline
    config.outline_unfocused = context.unfocused_outline
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
      test.equal(call[4], 3 * factor)
      test.ok(call[4] < style.padding.y,
        "resize strip must stay below status bar text")
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

  test.test("focus changes overlay the entire title bar and leave idle updates asleep", function()
    local focused = true
    system.window_has_focus = function() return focused end
    config.borderless_outline = false
    local window = renwindow.create("title-overlay-test", 1100, 700)
    config.borderless_unfocused_overlay = { 10, 20, 30, 128 }
    core.title_view.focused = false
    local baseline
    for _, state in ipairs { true, false, true } do
      focused = state
      core.redraw = false
      core.title_view:update()
      test.ok(core.redraw)
      draw_frame(window)
      local width, height = 1100, math.floor(core.title_view.size.y)
      local pixels = renderer.to_canvas(window, 0, 0, width, height):get_pixels()
      if not baseline then
        baseline = pixels
      elseif focused then
        test.equal(pixels, baseline, "focus gain must restore the complete title bar")
      else
        -- Sample the logo, menus, title, and controls across the entire title bar.
        for y = 0, height - 1, 3 do
          for x = 0, width - 1, 7 do
            local offset = (y * width + x) * 4
            for channel = 1, 3 do
              local expected = baseline:byte(offset + channel) * 127 / 255
                + config.borderless_unfocused_overlay[channel] * 128 / 255
              test.ok(math.abs(pixels:byte(offset + channel) - expected) <= 1,
                "inactive overlay must cover the entire title bar")
            end
          end
        end
      end
      core.redraw = false
      core.title_view:update()
      test.not_ok(core.redraw, "unchanged focus must allow the editor to sleep")
    end
    config.borderless_unfocused_overlay[4], focused = 0, false
    core.title_view:update()
    draw_frame(window)
    local pixels = renderer.to_canvas(window, 0, 0, 1100, math.floor(core.title_view.size.y)):get_pixels()
    test.equal(pixels, baseline, "zero alpha must disable the overlay")
  end)

  test.test("toggles borderless outlines on every platform above floating content", function()
    local focused = true
    system.window_has_focus = function() return focused end
    config.outline_focused = { 20, 170, 255, 255 }
    config.outline_unfocused = { 90, 100, 110, 255 }
    local window = renwindow.create("window-outline-test", 1100, 700)
    local overlay = View()
    overlay:set_floating(true, { interactive = false, focus = "none" })
    overlay:set_floating_bounds(0, 0, 1100, 700)
    local overlay_color = { 1, 2, 3, 255 }
    function overlay:draw()
      renderer.draw_rect(0, 0, 1100, 700, overlay_color)
    end
    overlay:show_floating()
    settle()
    for _, platform in ipairs { "Windows", "Linux", "Mac OS X" } do
      PLATFORM = platform
      for _, case in ipairs {
        { true, true, "normal", true },
        { true, false, "normal", false },
        { true, true, "maximized", false },
        { true, true, "fullscreen", false },
        { false, true, "normal", false },
        { true, true, "normal", true }
      } do
        config.borderless, config.borderless_outline, core.window_mode = table.unpack(case)
        for _, state in ipairs { true, false, true } do
          focused = state
          draw_frame(window)
          local color = focused and config.outline_focused
            or config.outline_unfocused
          local expected = case[4] and color or overlay_color
          for _, point in ipairs { {0, 100}, {1099, 100}, {100, 0}, {100, 699} } do
            test.same(window:get_color(point[1], point[2]), expected)
          end
          test.same(window:get_color(100, 100), overlay_color)
        end
        test.equal(core.root_view.size.x, 1100)
        test.equal(core.root_view.size.y, 700)
      end
    end
    overlay:hide_floating()
  end)

  test.test("uses the current theme for unset outline colors", function()
    config.outline_focused, config.outline_unfocused = nil, nil
    config.borderless, config.borderless_outline, core.window_mode = true, true, "normal"
    local focused = true
    system.window_has_focus = function() return focused end
    local window = renwindow.create("themed-outline-test", 1100, 700)
    local previous_caret, previous_dim = style.caret, style.dim
    local ok, err = pcall(function()
      for _, theme in ipairs {
        { { 15, 30, 45, 255 }, { 20, 40, 60, 255 } },
        { { 120, 130, 140, 255 }, { 150, 160, 170, 255 } }
      } do
        style.caret, style.dim = table.unpack(theme)
        for _, state in ipairs { true, false } do
          focused = state
          draw_frame(window)
          test.same(window:get_color(0, 100), focused and style.caret or style.dim)
        end
      end
    end)
    style.caret, style.dim = previous_caret, previous_dim
    if not ok then error(err) end
  end)
end)
