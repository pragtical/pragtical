local core = require "core"
local test = require "core.test"
local config = require "core.config"
local style = require "core.style"
local Widget = require "widget"
local Toggle = require "widget.toggle"

local function draw(context, root)
  local rectangles = {}
  renderer.draw_rect = function(x, y, w, h, color)
    rectangles[#rectangles + 1] = { x = x, y = y, w = w, h = h, color = color }
    return context.draw_rect(x, y, w, h, color)
  end
  renderer.begin_frame(core.window)
  root:draw()
  renderer.end_frame()
  renderer.draw_rect = context.draw_rect
  return rectangles
end

local function thumb(rectangles, toggle)
  for _, rect in ipairs(rectangles) do
    if rect.color == style.line_highlight and rect.w == 15 * SCALE
      and rect.y == toggle.position.y + 3 * SCALE then return rect end
  end
  error("toggle thumb was not drawn")
end

test.describe("Toggle rendering", function()
  test.before_each(function(context)
    context.transitions = config.transitions
    context.draw_rect = renderer.draw_rect
    context.background = style.background
    context.highlight = style.line_highlight
    context.fps = config.fps
    context.core_fps = core.fps
    config.fps, core.fps = 60, 60
    config.transitions = false
    local root = Widget(nil, false)
    root.border.width = 0
    root.background_color = style.line_highlight
    root:show()
    root:set_position(40, 60)
    root:set_size(600, 200)
    context.root = root
    context.toggle = Toggle(root, "", true)
    context.toggle:set_position(20, 20)
    root:update()
  end)

  test.after_each(function(context)
    renderer.draw_rect = context.draw_rect
    context.root:destroy()
    config.transitions = context.transitions
    style.background = context.background
    style.line_highlight = context.highlight
    config.fps, core.fps = context.fps, context.core_fps
  end)

  for _, light in ipairs { false, true } do
    test.it("preserves the parent highlight in a " .. (light and "light" or "dark")
      .. " theme", function(context)
      style.background = light and {251, 251, 251, 255} or {30, 30, 30, 255}
      style.line_highlight = light and {234, 234, 234, 255} or {45, 45, 45, 255}
      local toggle = context.toggle
      for _, rect in ipairs(draw(context, context.root)) do
        test.not_ok(rect.x == toggle.position.x and rect.y == toggle.position.y
          and rect.w == toggle.size.x and rect.h == toggle.size.y
          and rect.color == style.background)
      end
      toggle.render_background = true
      local found = false
      for _, rect in ipairs(draw(context, context.root)) do
        if rect.x == toggle.position.x and rect.y == toggle.position.y
          and rect.color == style.background then found = true end
      end
      test.ok(found)
    end)
  end

  for _, enabled in ipairs { false, true } do
    test.it("moves the " .. (enabled and "enabled" or "disabled")
      .. " thumb with its parent before the next update", function(context)
      local root, toggle = context.root, context.toggle
      toggle:set_toggle(enabled)
      root:update()
      local before = thumb(draw(context, root), toggle)
      root:set_position(root.position.x + 80, root.position.y + 30)
      local after = thumb(draw(context, root), toggle)
      test.equal(after.x, before.x + 80)
      test.equal(after.y, before.y + 30)
      test.equal(after.x, toggle.position.x + toggle.toggle_x
        + (enabled and 22 or 3) * SCALE)
    end)
  end

  test.it("keeps a thumb animation relative to its moving track", function(context)
    local root, toggle = context.root, context.toggle
    config.transitions = true
    toggle:toggle()
    root:update()
    test.ok(toggle.animate_switch)
    local before = thumb(draw(context, root), toggle)
    local offset = before.x - toggle.position.x - toggle.toggle_x
    test.ok(offset > 3 * SCALE and offset < 22 * SCALE)
    root:set_position(root.position.x + 120)
    local after = thumb(draw(context, root), toggle)
    test.equal(after.x, before.x + 120)
    root:update()
    after = thumb(draw(context, root), toggle)
    test.ok(after.x - toggle.position.x - toggle.toggle_x < offset)
    for _ = 1, 100 do root:update() end
    test.not_ok(toggle.animate_switch)
    test.equal(thumb(draw(context, root), toggle).x,
      toggle.position.x + toggle.toggle_x + 3 * SCALE)
  end)
end)
