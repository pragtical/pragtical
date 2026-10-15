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
    config.hide_tabs = true
  end)

  test.after_each(function(context)
    core.active_view, core.last_active_view, core.next_active_view = context.active, context.last, context.next
    config.hide_tabs, style.divider_size = context.hide_tabs, context.divider_size
    core.clip_rect_stack = context.clip_rect_stack
  end)

  local function layout(direction, panel_size)
    local node = Node()
    node.position.x, node.position.y = 20.25, 20.25
    node.size.x, node.size.y = 300.5, 200.5
    local content = View()
    function content:draw() self:draw_background(style.background) end
    content._core_step_first_update = true
    node:add_view(content)
    local panel = View()
    local axis = (direction == "left" or direction == "right") and "x" or "y"
    panel.size[axis] = panel_size
    node:split(direction, panel, { [axis] = true }, true)
    node:update_layout()
    return node, axis
  end

  for _, factor in ipairs { 1, 1.25, 1.5, 1.75, 2, 3 } do
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
        local x, y, w, h = split:get_divider_rect()
        -- Splitting an empty region can leave a descendant divider above or
        -- beside it. The collapsed ancestor must exclude the entire branch.
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
        -- Every edge of the content remains uniform, without a second divider.
        for column = left, right - 1 do
          test.same({ capture:get_pixels(column, top, 1, 1):byte(1, 3) }, style.background)
          test.same({ capture:get_pixels(column, bottom - 1, 1, 1):byte(1, 3) }, style.background)
        end
        for row = top, bottom - 1 do
          test.same({ capture:get_pixels(left, row, 1, 1):byte(1, 3) }, style.background)
          test.same({ capture:get_pixels(right - 1, row, 1, 1):byte(1, 3) }, style.background)
        end
      end
    end)
  end
end)
