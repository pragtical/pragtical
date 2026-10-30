local core = require "core"
local config = require "core.config"
local style = require "core.style"
local Node = require "core.node"
local View = require "core.view"
local test = require "core.test"

test.describe("node dividers", function()
  test.before_each(function(context)
    context.active, context.last, context.next = core.active_view, core.last_active_view, core.next_active_view
    context.hide_tabs, context.divider_size = config.hide_tabs, style.divider_size
    context.clip_rect_stack = core.clip_rect_stack
    context.redraw = core.redraw
    config.hide_tabs = true
  end)

  test.after_each(function(context)
    core.active_view, core.last_active_view, core.next_active_view = context.active, context.last, context.next
    config.hide_tabs, style.divider_size = context.hide_tabs, context.divider_size
    core.clip_rect_stack = context.clip_rect_stack
    core.redraw = context.redraw
  end)

  local function layout(direction, panel_size)
    local node = Node()
    local content = View()
    function content:draw() self:draw_background(style.background) end
    content._core_step_first_update = true
    node:add_view(content)
    local panel = View()
    local axis = (direction == "left" or direction == "right") and "x" or "y"
    panel.size[axis] = panel_size
    node:split(direction, panel, { [axis] = true }, true)
    node.position.x, node.position.y = 20.25, 20.25
    node.size.x, node.size.y = 300.5, 200.5
    node:update_layout()
    return node, axis
  end

  local function assert_bounds(node, parent)
    for _, axis in ipairs { "x", "y" } do
      test.ok(node.size[axis] >= 0, "negative " .. axis .. " dimension")
      test.ok(node.position[axis] >= parent.position[axis] - 1e-8)
      test.ok(node.position[axis] + node.size[axis]
        <= parent.position[axis] + parent.size[axis] + 1e-8)
    end
    if node.type == "leaf" then
      assert_bounds(node.active_view, node)
    elseif node.a then
      assert_bounds(node.a, node)
      assert_bounds(node.b, node)
    end
  end

  for _, factor in ipairs { 1, 1.25, 1.5, 1.75, 2, 3 } do
    test.it("fits dividers and locked panes into small splits at scale " .. factor, function()
      style.divider_size = factor
      for _, direction in ipairs { "left", "right", "up", "down" } do
        for _, locks in ipairs { "none", "first", "second", "both" } do
          for _, extent in ipairs { 0, factor / 2, factor, factor + 0.25, 20.5, 100.5 } do
            local node, axis = layout(direction, 40.5)
            node.size[axis] = extent
            node.a.locked = (locks == "first" or locks == "both") and { [axis] = true } or nil
            node.b.locked = (locks == "second" or locks == "both") and { [axis] = true } or nil
            node.a.active_view.size[axis], node.b.active_view.size[axis] = 40.5, 40.5
            node:update_layout()
            assert_bounds(node.a, node)
            assert_bounds(node.b, node)
            local x, y, w, h = node:get_divider_rect()
            local gap = { position = { x = x, y = y }, size = { x = w, y = h } }
            assert_bounds(gap, node)
          end
        end
      end
    end)

    for _, direction in ipairs { "left", "right", "up", "down" } do
      test.it("omits a collapsed " .. direction .. " divider at scale " .. factor, function()
        style.divider_size = factor
        for _, panel_size in ipairs { 0, 0.75 } do
          local node, axis = layout(direction, panel_size)
          local _, _, w, h = node:get_divider_rect()
          test.equal(axis == "x" and w or h, 0)
          local x, y = node:get_divider_rect()
          test.is_nil(node:get_divider_overlapping_point(x + w / 2, y + h / 2))
        end
      end)
    end

    test.it("matches the allocated gap for visible splits at scale " .. factor, function()
      style.divider_size = factor
      for _, direction in ipairs { "left", "right", "up", "down" } do
        local node, axis = layout(direction, 40.5)
        local x, y, w, h = node:get_divider_rect()
        local start, size = axis == "x" and x or y, axis == "x" and w or h
        test.near(size, factor, 1e-8)
        test.near(start, node.a.position[axis] + node.a.size[axis], 1e-8)
        test.near(start + size, node.b.position[axis], 1e-8)
      end
    end)
  end

  test.it("keeps tabbed content inside a node shorter than its tab bar", function()
    config.hide_tabs = false
    local node = Node()
    node:add_view(View())
    node:add_view(View())
    node.position.x, node.position.y, node.size.x = 20.25, 30.5, 300.5
    local _, _, _, tab_height = node:get_tab_rect(1)
    for _, height in ipairs { 0, tab_height / 2, tab_height, tab_height + 3.25 } do
      node.size.y = height
      node:update_layout()
      assert_bounds(node.active_view, node)
      test.near(node.active_view.size.y, math.max(0, height - tab_height), 1e-8)
    end
  end)

  test.it("does not restart a hidden pane's size animation after layout", function()
    local node = layout("down", 0)
    local branch = node.b:split("right", View(), {})
    local pane = View()
    function pane:update() self:move_towards(self.size, "y", 0) end
    branch:split("up", pane, {})
    node:update_layout()
    for _ = 1, 5 do
      core.redraw = false
      pane:update()
      test.not_ok(core.redraw)
      node:update_layout()
      test.equal(pane.size.y, 0)
    end
  end)

  test.it("does not paint a hidden panel's divider beyond its parent", function()
    local background = { 200, 60, 60, 255 }
    for _, direction in ipairs { "right", "down" } do
      local node, axis = layout(direction, 0)
      local window = renwindow.create("Collapsed divider", 400, 280)
      core.clip_rect_stack = { { 0, 0, 400, 280 } }
      renderer.begin_frame(window)
      renderer.set_clip_rect(0, 0, 400, 280)
      renderer.draw_rect(0, 0, 400, 280, background)
      node:draw()
      renderer.end_frame()
      local capture = renderer.to_canvas(window, 0, 0, 400, 280)
      local x = axis == "x" and math.floor(node.position.x + node.size.x + 0.5) or 40
      local y = axis == "y" and math.floor(node.position.y + node.size.y + 0.5) or 40
      test.same({ capture:get_pixels(x, y, 1, 1):byte(1, 3) }, { 200, 60, 60 })
    end
  end)

  for _, factor in ipairs { 1, 1.25, 1.3, 1.55, 2, 3.7 } do
    test.it("keeps nested hidden panes from painting or receiving hits at scale " .. factor, function()
      style.divider_size = factor
      for _, direction in ipairs { "left", "right", "up", "down" } do
        local node, axis = layout(direction, 0)
        local branch = (direction == "left" or direction == "up") and node.a or node.b
        local split = branch:split(axis == "y" and "right" or "down", View(), {}, true)
        split:split(axis == "y" and "up" or "left", View(), {}, true)
        node:update_layout()
        assert_bounds(node.a, node)
        assert_bounds(node.b, node)
        local x, y, w, h = split:get_divider_rect()
        -- A collapsed ancestor must exclude all descendant divider hit regions.
        test.is_nil(node:get_divider_overlapping_point(x + w / 2, y + h / 2))

        local background = { 200, 60, 60, 255 }
        local window = renwindow.create("Nested collapsed dividers", 400, 280)
        core.clip_rect_stack = { { 0, 0, 400, 280 } }
        renderer.begin_frame(window)
        renderer.set_clip_rect(0, 0, 400, 280)
        renderer.draw_rect(0, 0, 400, 280, background)
        node:draw()
        renderer.end_frame()
        local capture = renderer.to_canvas(window, 0, 0, 400, 280)
        local left = math.floor(node.position.x + 0.5)
        local top = math.floor(node.position.y + 0.5)
        local right = math.floor(node.position.x + node.size.x + 0.5)
        local bottom = math.floor(node.position.y + node.size.y + 0.5)
        local color = { style.background[1], style.background[2], style.background[3] }
        -- Every edge of the content remains uniform, without a second divider.
        for column = left, right - 1 do
          test.same({ capture:get_pixels(column, top, 1, 1):byte(1, 3) }, color)
          test.same({ capture:get_pixels(column, bottom - 1, 1, 1):byte(1, 3) }, color)
        end
        for row = top, bottom - 1 do
          test.same({ capture:get_pixels(left, row, 1, 1):byte(1, 3) }, color)
          test.same({ capture:get_pixels(right - 1, row, 1, 1):byte(1, 3) }, color)
        end
      end
    end)
  end
  test.it("a replacement view requests drawing after its first update only", function()
    local node = Node()
    node.size.x, node.size.y = 400, 300
    node.views, node.active_view = {View()}, nil
    node.active_view = node.views[1]
    node:update_layout()
    node:update(); node:update()
    local view = View()
    view.update = function() end
    node.views, node.active_view = {view}, view
    node:update_layout()
    core.redraw = false
    node:update()
    test.ok(core.redraw, "a newly updated view needs its first draw")
    core.redraw = false
    node:update()
    test.not_ok(core.redraw, "a settled view must stop requesting frames")
  end)

  for _, active in ipairs { true, false } do
    test.it("requests drawing when removing an " .. (active and "active" or "inactive") .. " tab", function()
      local node = Node()
      local first, second = View(), View()
      node:add_view(first)
      node:add_view(second)
      node:update_layout()
      node:update(); node:update()
      core.redraw = false
      node:close_view(node, active and second or first)
      test.ok(core.redraw, "removing a tab without an input event must repaint")
      test.equal(node.active_view, active and first or second)
      test.equal(#node.views, 1)
    end)
  end

  for _, direction in ipairs { "right", "down" } do
    test.it("requests drawing when closing a " .. direction .. " split", function()
      local node = Node()
      local content, panel = View(), View()
      node:add_view(content)
      local split = node:split(direction, panel)
      node:update_layout()
      node:update(); node:update()
      core.redraw = false
      split:close_view(node, panel)
      test.ok(core.redraw, "closing a split without an input event must repaint")
      test.equal(node.type, "leaf")
      test.equal(node.active_view, content)
    end)
  end

end)
