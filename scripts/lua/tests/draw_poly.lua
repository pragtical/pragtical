-- Exercises every renderer.draw_poly form documented in docs/api/renderer.lua:
--   * renderer.normal_point  -> { x, y }                               (2 numbers)
--   * renderer.conic_bezier  -> { sx, sy, cpx, cpy, ex, ey }           (6 numbers)
--   * renderer.cubic_bezier  -> { sx, sy, c1x, c1y, c2x, c2y, ex, ey } (8 numbers)
-- plus a mixed polygon, a closed ring (last point repeats the first), the
-- control-box return value, and the documented "2, 6 or 8 numbers" constraint.
--
-- Runs under whatever backend PRAGTICAL_RENDERER selects, so it validates the
-- SDLGPU polygon paths as well as the software renderer.
-- Collapsed polygons are checked on both window and offscreen canvas targets.

local test = require "core.test"
local common = require "core.common"
local dir = debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])")
local visualizer = dofile(dir .. "../fixtures/visualizer.lua")

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
local function render_poly(context, name, w, h, poly, offscreen)
  local window = renwindow.create("draw-poly-" .. name, w, h)
  test.not_nil(window)

  renderer.begin_frame(window)
  renderer.set_clip_rect(0, 0, w, h)
  renderer.draw_rect(0, 0, w, h, BG, true)
  local bx, by, bw, bh
  if offscreen then
    local target = canvas.new(w, h, BG, true)
    bx, by, bw, bh = target:draw_poly(poly, FILL)
    target:render()
    renderer.draw_canvas(target, 0, 0)
  else
    bx, by, bw, bh = renderer.draw_poly(poly, FILL)
  end
  renderer.end_frame()

  local capture = renderer.to_canvas(window, 0, 0, w, h)
  test.not_nil(capture)
  if context and context.temp_root then
    capture:save_image(context.temp_root .. PATHSEP .. "draw-poly-" .. name .. ".png")
  end
  return capture:get_pixels(0, 0, w, h), bx, by, bw, bh
end

-- Independent nonzero-winding check. Exclude pixels touching an edge, whose
-- antialiased coverage is deliberately not predicted by this point test.
local function touches_polygon(poly, x, y)
  local winding = 0
  local a = poly[#poly]
  for _, b in ipairs(poly) do
    local dx, dy = b[1] - a[1], b[2] - a[2]
    local length = dx * dx + dy * dy
    local t = length > 0 and math.max(0, math.min(1, ((x - a[1]) * dx + (y - a[2]) * dy) / length)) or 0
    if (x - a[1] - t * dx)^2 + (y - a[2] - t * dy)^2 <= 1 then return true end
    local cross = dx * (y - a[2]) - dy * (x - a[1])
    if a[2] <= y and b[2] > y and cross > 0 then winding = winding + 1 end
    if a[2] > y and b[2] <= y and cross < 0 then winding = winding - 1 end
    a = b
  end
  return winding ~= 0
end

for _, target in ipairs { "window", "canvas" } do
  test.describe(target .. " visualization polygons", function()
    test.before_each(function(context)
      context.temp_root = USERDIR .. PATHSEP .. "draw-poly-" .. system.get_process_id()
        .. "-" .. math.floor(system.get_time() * 1000000)
      test.ok(common.mkdirp(context.temp_root))
    end)

    test.after_each(function(context)
      if os.getenv("PRAGTICAL_KEEP_VISUAL_TEST_OUTPUT") == "1" then
        print("polygon test output: " .. context.temp_root)
      else
        test.ok(common.rm(context.temp_root, true))
      end
    end)

    for _, name in ipairs(visualizer.names) do
      test.test("preserves " .. name .. " strips and unfilled regions", function(context)
        local w, h, bg = visualizer.width, visualizer.height, visualizer.background
        local window = renwindow.create("draw-poly-" .. name, w, h)
        local offscreen = target == "canvas" and canvas.new(w, h, bg)
        for frame = 1, 3 do
          local polygons = {}
          renderer.begin_frame(window)
          renderer.set_clip_rect(0, 0, w, h)
          renderer.draw_rect(0, 0, w, h, bg, true)
          if offscreen then offscreen:draw_rect(0, 0, w, h, bg, true) end
          -- Later frames exercise clipping and retained-frame invalidation.
          local inset = (frame - 1) * 16
          if offscreen then offscreen:set_clip_rect(inset, inset, w - inset * 2, h - inset * 2)
          else renderer.set_clip_rect(inset, inset, w - inset * 2, h - inset * 2) end
          visualizer.draw(name, frame, function(poly, color)
            if offscreen then offscreen:draw_poly(poly, color)
            else renderer.draw_poly(poly, color) end
            local integer_poly = {}
            for i, point in ipairs(poly) do
              integer_poly[i] = {
                point[1] >= 0 and math.floor(point[1]) or math.ceil(point[1]),
                point[2] >= 0 and math.floor(point[2]) or math.ceil(point[2])
              }
            end
            polygons[#polygons + 1] = integer_poly
          end)
          if offscreen then
            offscreen:render()
            renderer.draw_canvas(offscreen, 0, 0)
            offscreen:set_clip_rect(0, 0, w, h)
          end
          renderer.end_frame()
          local capture = renderer.to_canvas(window, 0, 0, w, h)
          test.ok(capture:save_image(context.temp_root .. PATHSEP .. name .. "-" .. frame .. ".png"))
          local pixels = capture:get_pixels(0, 0, w, h)
          local blank, lit = 0, 0
          for y = 0, h - 1, 4 do
            for x = 0, w - 1, 4 do
              local touches = false
              if x >= inset and y >= inset and x < w - inset and y < h - inset then
                for _, poly in ipairs(polygons) do
                  if touches_polygon(poly, x + 0.5, y + 0.5) then touches = true; break end
                end
              end
              local r, g, b = pixels:byte((y * w + x) * 4 + 1, (y * w + x) * 4 + 3)
              if not touches then
                test.ok(math.abs(r - bg[1]) <= 1 and math.abs(g - bg[2]) <= 1 and math.abs(b - bg[3]) <= 1,
                  string.format("%s frame %d filled outside the path at %d,%d: %d,%d,%d", name, frame, x, y, r, g, b))
                blank = blank + 1
              elseif math.max(r, g, b) > 32 then
                lit = lit + 1
              end
            end
          end
          test.ok(blank > 1000, "fixture must exercise unfilled regions")
          test.ok(lit > 100, "fixture must contain visible strips")
        end
      end)
    end

    test.test("keeps a one-pixel strip inside its bounds", function(context)
      local poly = { {16, 20}, {80, 20}, {80, 21}, {16, 21} }
      local pixels = render_poly(context, target .. "-thin-strip", 96, 80, poly, target == "canvas")
      test.equal(count_fill(pixels, 96, 16, 20, 64, 1, FILL, 2), 64)
      test.equal(count_fill(pixels, 96, 0, 19, 96, 1, BG, 0), 96)
      test.equal(count_fill(pixels, 96, 0, 21, 96, 1, BG, 0), 96)
    end)
  end)
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

local collapsed_polygons = {
  { "empty", {} },
  { "single", { {20, 20} } },
  { "two-points", { {20, 20}, {60, 60} } },
  { "coincident", { {20, 20}, {20, 20}, {20, 20} } },
  { "repeated-endpoints", { {20, 20}, {20, 20}, {60, 60}, {60, 60} } },
  { "alternating-endpoints", { {20, 20}, {60, 60}, {20, 20}, {60, 60}, {20, 20} } },
  { "collinear", { {20, 20}, {40, 40}, {60, 60} } },
  -- Frontra's slowing projectile trail, translated into this test window.
  { "fractional-trail", {
    {38.39, 45.363}, {38.59, 45.75}, {42.82, 43.492}, {42.61, 43.105}
  } },
  { "conic-line", { {20, 20, 40, 40, 60, 60}, {20, 20} } },
  { "cubic-line", { {20, 20, 30, 30, 50, 50, 60, 60}, {20, 20} } },
}

for _, target in ipairs({ "window", "canvas" }) do
  test.describe(target .. " polygon degeneracy", function()
    local offscreen = target == "canvas"
    for _, case in ipairs(collapsed_polygons) do
      test.test("ignores " .. case[1] .. " without changing pixels", function(context)
        local w, h = 96, 80
        local pixels = render_poly(context, target .. "-" .. case[1], w, h, case[2], offscreen)
        test.equal(pixels, string.rep(string.char(0, 0, 0, 255), w * h),
          "a collapsed polygon must leave the background unchanged")
      end)
    end

    test.test("keeps nonempty polygons with collinear leading points in both windings", function(context)
      local poly = { {20, 20}, {40, 20}, {60, 20}, {60, 60}, {20, 60} }
      for winding = 1, 2 do
        local pixels = render_poly(context, target .. "-leading-line-" .. winding,
          96, 80, poly, offscreen)
        test.ok(count_fill(pixels, 96, 25, 25, 30, 30, FILL, 24) > 800)
        local reversed = {}
        for i = #poly, 1, -1 do reversed[#reversed + 1] = poly[i] end
        poly = reversed
      end
    end)

    test.test("does not discard a self-intersecting polygon with zero signed area", function(context)
      local poly = { {20, 20}, {70, 60}, {70, 20}, {20, 60} }
      local pixels = render_poly(context, target .. "-zero-signed-area", 96, 80, poly, offscreen)
      test.ok(count_fill(pixels, 96, 20, 20, 50, 40, FILL, 24) > 300)
    end)
  end)
end
