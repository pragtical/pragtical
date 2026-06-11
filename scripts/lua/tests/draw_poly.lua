-- Exercises every renderer.draw_poly form documented in docs/api/renderer.lua:
--   * renderer.normal_point  -> { x, y }                               (2 numbers)
--   * renderer.conic_bezier  -> { sx, sy, cpx, cpy, ex, ey }           (6 numbers)
--   * renderer.cubic_bezier  -> { sx, sy, c1x, c1y, c2x, c2y, ex, ey } (8 numbers)
-- plus a mixed polygon, a closed ring (last point repeats the first), the
-- control-box return value, and the documented "2, 6 or 8 numbers" constraint.
--
-- Runs under whatever backend PRAGTICAL_RENDERER selects, so it validates the
-- SDLGPU triangulation paths as well as the software renderer.

local test = require "core.test"

local BG   = { 0, 0, 0, 255 }
local FILL = { 255, 90, 40, 255 }

local function count_fill(pixels, width, x, y, w, h, target, tol)
  local n = 0
  for yy = y, y + h - 1 do
    for xx = x, x + w - 1 do
      local idx = ((yy * width + xx) * 4) + 1
      local r, g, b = pixels:byte(idx, idx + 2)
      if math.abs(r - target[1]) <= tol
        and math.abs(g - target[2]) <= tol
        and math.abs(b - target[3]) <= tol
      then
        n = n + 1
      end
    end
  end
  return n
end

-- Render a single polygon onto a fresh window and return its captured pixels
-- plus the draw_poly control-box return value.
local function render_poly(context, name, w, h, poly)
  local window = renwindow.create("draw-poly-" .. name, w, h)
  test.not_nil(window)

  renderer.begin_frame(window)
  renderer.set_clip_rect(0, 0, w, h)
  renderer.draw_rect(0, 0, w, h, BG, true)
  local bx, by, bw, bh = renderer.draw_poly(poly, FILL)
  renderer.end_frame()

  local capture = renderer.to_canvas(window, 0, 0, w, h)
  test.not_nil(capture)
  if context and context.temp_root then
    capture:save_image(context.temp_root .. PATHSEP .. "draw-poly-" .. name .. ".png")
  end
  return capture:get_pixels(0, 0, w, h), bx, by, bw, bh
end

local function circle_ring(cx, cy, rx, ry, segments)
  local poly = {}
  for i = 0, segments do -- inclusive: last point repeats the first
    local theta = (2 * math.pi * i) / segments
    poly[#poly + 1] = { cx + rx * math.cos(theta), cy + ry * math.sin(theta) }
  end
  return poly
end

test.describe("renderer.draw_poly forms", function()

  test.test("fills a polygon made of normal points and returns its control box", function(context)
    local w, h = 160, 120
    local poly = { {30, 30}, {120, 30}, {120, 90}, {30, 90} }
    local pixels, bx, by, bw, bh = render_poly(context, "normal", w, h, poly)

    -- documented return: control box (x, y, w, h) >= rendered dimensions
    test.type(bx, "number"); test.type(by, "number")
    test.type(bw, "number"); test.type(bh, "number")
    test.ok(bx <= 30 and by <= 30, "control box origin should bound the points")
    test.ok(bw >= 90 and bh >= 60, "control box should cover the polygon span")

    -- interior is filled, a corner is still background
    local inside = count_fill(pixels, w, 40, 40, 60, 40, FILL, 24)
    test.ok(inside > 2000, "polygon interior should be filled, got " .. inside)
    test.equal(count_fill(pixels, w, 0, 0, 8, 8, FILL, 24), 0,
      "background corner should not be filled")
  end)

  test.test("fills a polygon with a conic (quadratic) bezier edge", function(context)
    local w, h = 160, 120
    -- straight bottom edge, top edge is a single conic curve back to the start
    local poly = { {20, 100}, {140, 100}, {140, 100, 80, 5, 20, 100} }
    local pixels, _, _, bw, bh = render_poly(context, "conic", w, h, poly)

    test.ok(bw > 0 and bh > 0, "conic control box should be non-empty")
    local inside = count_fill(pixels, w, 30, 50, 100, 45, FILL, 24)
    test.ok(inside > 400, "conic-edged polygon should fill area, got " .. inside)
  end)

  test.test("fills a polygon with a cubic bezier edge", function(context)
    local w, h = 160, 120
    local poly = { {20, 100}, {140, 100}, {140, 100, 110, 5, 50, 5, 20, 100} }
    local pixels, _, _, bw, bh = render_poly(context, "cubic", w, h, poly)

    test.ok(bw > 0 and bh > 0, "cubic control box should be non-empty")
    local inside = count_fill(pixels, w, 30, 50, 100, 45, FILL, 24)
    test.ok(inside > 400, "cubic-edged polygon should fill area, got " .. inside)
  end)

  test.test("fills a polygon mixing points, conic and cubic segments", function(context)
    local w, h = 160, 120
    local poly = {
      {20, 100},                       -- normal point
      {140, 100, 150, 40, 90, 20},     -- conic: -> ctrl(150,40) -> (90,20)
      {90, 20, 60, 5, 30, 5, 20, 100}, -- cubic: -> c1 -> c2 -> back to start
    }
    local pixels, _, _, bw, bh = render_poly(context, "mixed", w, h, poly)

    test.ok(bw > 0 and bh > 0, "mixed control box should be non-empty")
    local inside = count_fill(pixels, w, 30, 30, 100, 65, FILL, 24)
    test.ok(inside > 400, "mixed polygon should fill area, got " .. inside)
  end)

  test.test("fills a closed ring whose last point repeats the first", function(context)
    local w, h = 160, 120
    local poly = circle_ring(80, 60, 40, 36, 32)
    local pixels = render_poly(context, "ring", w, h, poly)

    local center = count_fill(pixels, w, 70, 50, 20, 20, FILL, 24)
    test.ok(center > 300, "ring interior should be filled, got " .. center)
    test.equal(count_fill(pixels, w, 0, 0, 6, 6, FILL, 24), 0,
      "outside the ring should be background")
  end)

  test.test("rejects sub-tables that are not 2, 6 or 8 numbers", function()
    local window = renwindow.create("draw-poly-invalid", 64, 48)
    renderer.begin_frame(window)
    renderer.set_clip_rect(0, 0, 64, 48)
    test.error(function()
      renderer.draw_poly({ {1, 2, 3} }, FILL)
    end, "invalid number of points")
    renderer.end_frame()
  end)

end)
