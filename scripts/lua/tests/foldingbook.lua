local test = require "core.test"
local core = require "core"
local config = require "core.config"
local style = require "core.style"
local FoldingBook = require "widget.foldingbook"
local Widget = require "widget"

test.describe("foldingbook rendering", function()
  test.before_each(function(c)
    c.scale, c.transitions, c.clip = SCALE, config.transitions, core.clip_rect_stack
    c.redraw = core.redraw
    c.style = {}
    for _, key in ipairs { "font", "icon_font", "padding", "selection", "scrollbar", "scrollbar_track" } do
      c.style[key] = style[key]
    end
    config.transitions = false
    style.selection = { 220, 40, 70, 255 }
    style.scrollbar = { 40, 130, 220, 255 }
    style.scrollbar_track = { 30, 40, 50, 255 }
  end)

  test.after_each(function(c)
    if c.book then c.book:destroy() end
    SCALE, config.transitions, core.clip_rect_stack = c.scale, c.transitions, c.clip
    for key, value in pairs(c.style) do style[key] = value end
    core.redraw = c.redraw
  end)

  local function book(c, factor)
    SCALE = factor
    for _, key in ipairs { "font", "icon_font" } do
      style[key] = c.style[key]:copy(c.style[key]:get_size() * factor / c.scale)
    end
    style.padding = { x = c.style.padding.x * factor / c.scale, y = c.style.padding.y * factor / c.scale }
    c.book = FoldingBook()
    c.book:set_floating(false)
    c.book:show()
    c.book:set_position(20.6, 20.6)
    c.book:set_size(340 * factor, 180 * factor)
    c.book.border.width = 0
    for i = 1, 8 do c.book:add_pane("section" .. i, "Section " .. i) end
    for _ = 1, 20 do c.book:update() end
    return c.book
  end

  local function capture(view)
    local width, height = math.ceil(view.size.x + 80), math.ceil(view.size.y + 80)
    local window = renwindow.create("FoldingBook rendering", width, height)
    core.clip_rect_stack = { { 0, 0, width, height } }
    renderer.begin_frame(window)
    renderer.set_clip_rect(0, 0, width, height)
    renderer.draw_rect(0, 0, width, height, style.background)
    view:draw()
    renderer.end_frame()
    return renderer.to_canvas(window, 0, 0, width, height)
  end

  for _, factor in ipairs { 1, 1.25, 1.3, 1.5, 1.75, 2, 3 } do
    for _, status in ipairs { "contracted", "expanded" } do
      test.it("keeps separators behind the " .. status .. " scrollbar at scale " .. factor, function(c)
        local view = book(c, factor)
        view.v_scrollbar:set_forced_status(status)
        view:update()
        local thumb_calls = 0
        local draw_thumb = view.v_scrollbar.draw_thumb
        function view.v_scrollbar:draw_thumb()
          thumb_calls = thumb_calls + 1
          return draw_thumb(self)
        end
        local x, top, width, height = view.v_scrollbar:get_thumb_rect()
        test.ok(width > 0 and height > 0)
        local pane = view.panes[1]
        test.near(pane.tab.position.x - view.position.x, style.padding.x, 1e-6)
        test.near(pane.tab:get_width(), view.size.x - style.padding.x * 2, 1e-6)
        local y = math.floor(pane.tab.position.y + pane.tab:get_height() + 0.5)
        test.ok(y > top and y + 1 < top + height)
        local frame = capture(view)
        test.equal(thumb_calls, 1)
        local pixels = { frame:get_pixels(math.floor(x + width / 2), y, 1, 1):byte(1, 3) }
        test.same(pixels, { 40, 130, 220 })
        test.same({ frame:get_pixels(math.floor(view.position.x + view.size.x / 2), y, 1, 1):byte(1, 3) },
          { 220, 40, 70 })
      end)
    end
  end

  for _, alignment in ipairs { "s", "e" } do
    test.it("keeps fixed content bounds independent of the scrollbar on the " .. alignment .. " side", function(c)
      local view = book(c, 1.3)
      view.padding = { left = 7, right = 9 }
      view.v_scrollbar.alignment = alignment
      view.v_scrollbar.contracted_size, view.v_scrollbar.expanded_size = 5.5, 17.5
      local pane = view.panes[1]
      local child = Widget(pane.container)
      child:set_size(100, 70)
      pane.expanded = true
      for _, status in ipairs { "expanded", "contracted", "expanded" } do
        view.v_scrollbar:set_forced_status(status)
        for _ = 1, 20 do view:update() end
        local x = view.position.x + 7 * SCALE
        local width = view.size.x - 16 * SCALE
        test.near(pane.tab.position.x, x, 1e-6)
        test.near(pane.tab:get_width(), width, 1e-6)
        test.near(pane.container.position.x - pane.container.border.width, x, 1e-6)
        test.near(pane.container:get_width(), width, 1e-6)
        test.equal(view:get_h_scrollable_size(), view.size.x)
        core.redraw = false
        for _ = 1, 5 do view:update() end
        test.not_ok(core.redraw)
      end
      view:set_size(nil, 2000)
      for _ = 1, 20 do view:update() end
      test.equal(select(3, view.v_scrollbar:get_track_rect()), 0)
      test.near(pane.tab.position.x, view.position.x + 7 * SCALE, 1e-6)
      test.near(pane.tab:get_width(), view.size.x - 16 * SCALE, 1e-6)
      test.near(pane.container:get_width(), pane.tab:get_width(), 1e-6)
    end)
  end

  test.it("keeps a 100 pixel book at its configured padding when scrolling appears", function(c)
    local view = book(c, 1)
    view.padding = { left = 10, right = 10 }
    for _, height in ipairs { 2000, 120, 2000 } do
      view:set_size(100, height)
      for _ = 1, 20 do view:update() end
      test.equal(view:get_width(), 100)
      test.equal(view.panes[1].tab:get_width(), 80)
      test.near(view.panes[1].tab.position.x, view.position.x + 10, 1e-6)
    end
  end)

  test.it("clips section separators to the viewport even without a scrolling parent", function(c)
    local view = book(c, 1)
    local outside
    for _, pane in ipairs(view.panes) do
      local y = math.floor(pane.tab.position.y + pane.tab:get_height() + 0.5)
      if y > view.position.y + view.size.y + 2 and y < 260 then outside = y; break end
    end
    test.not_nil(outside)
    local frame = capture(view)
    test.same({ frame:get_pixels(100, outside, 1, 1):byte(1, 3) },
      { style.background[1], style.background[2], style.background[3] })
  end)
end)
