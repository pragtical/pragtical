local renderer = require "renderer"
local renwindow = require "renwindow"
local canvas = require "canvas"
local common = require "core.common"
local test = require "core.test"

local width, height = 600, 240
local background = {17, 23, 31, 255}
local foreground = {230, 180, 95, 255}
local glyphs = "ABCDEFGHabcdefgh01234567"
local pixel = string.rep(string.char(55, 110, 180, 255), 4)
local fixtures = common.dirname(debug.getinfo(1, "S").source:gsub("^@", "")) .. "/fixtures/fonts/"

local function new_font(size, antialiasing)
  return renderer.font.load(DATADIR .. "/fonts/JetBrainsMono-Regular.ttf", size,
    {antialiasing = antialiasing, system_fallback = false})
end

local function grid(font, draw_text, draw_rect, draw_pixels)
  for i = 1, #glyphs do
    local x, y = 8 + (i - 1) % 8 * 72, 4 + math.floor((i - 1) / 8) * 76
    draw_text(font, glyphs:sub(i, i), x + .25, y, foreground)
    -- Force text/texture/pixel ordering barriers while the atlas gains glyphs.
    draw_rect(x + 56, y + 65, 3, 3, {80, 120, 40, 255})
    draw_pixels(pixel, x + 60, y + 65, 2, 2)
  end
end

local function draw_window(window, scene)
  renderer.begin_frame(window)
  renderer.set_clip_rect(0, 0, width, height)
  renderer.draw_rect(0, 0, width, height, background, true)
  scene(renderer.draw_text, renderer.draw_rect, renderer.draw_pixels)
  renderer.end_frame()
end

local function capture(window)
  return renderer.to_canvas(window, 0, 0, width, height):get_pixels(0, 0, width, height)
end

local function canvas_grid(font)
  local image = canvas.new(width, height, background, false)
  grid(font,
    function(...) return image:draw_text(...) end,
    function(...) return image:draw_rect(...) end,
    function(...) return image:set_pixels(...) end)
  image:render()
  return image:get_pixels(0, 0, width, height)
end

local function assert_grid_visible(pixels)
  for i = 1, #glyphs do
    local x, y = 8 + (i - 1) % 8 * 72, 4 + math.floor((i - 1) / 8) * 76
    local visible = 0
    for yy = y, y + 63 do
      for xx = x, x + 55 do
        local r, g = pixels:byte((yy * width + xx) * 4 + 1, (yy * width + xx) * 4 + 2)
        if r > 60 and g > 50 then visible = visible + 1 end
      end
    end
    test.ok(visible > 4, "missing glyph " .. glyphs:sub(i, i))
  end
end

test.describe("renderer glyph atlases", function()
  test.test("preserves new and cached glyphs across upload barriers", function()
    for _, antialiasing in ipairs {"grayscale", "subpixel"} do
      local font = new_font(25, antialiasing)
      local window = renwindow.create("Cold glyph uploads", width, height)
      local reference = renwindow.create("Warm glyph uploads", width, height)
      draw_window(window, function(...) grid(font, ...) end)
      local cold = capture(window)
      assert_grid_visible(cold)
      draw_window(reference, function(...) grid(font, ...) end)
      test.ok(cold == capture(reference), "cold/warm window glyphs differ")

      local canvas_font = new_font(25, antialiasing)
      local cold_canvas = canvas_grid(canvas_font)
      assert_grid_visible(cold_canvas)
      test.ok(cold_canvas == canvas_grid(canvas_font), "cold/warm canvas glyphs differ")
    end
  end)

  test.test("preserves glyphs while atlas sizes and owners change", function()
    local window = renwindow.create("Resized glyph uploads", width, height)
    local reference = renwindow.create("Fresh glyph uploads", width, height)
    for _, antialiasing in ipairs {"grayscale", "subpixel"} do
      local font = new_font(15, antialiasing)
      for _, size in ipairs {15, 29, 48, 18, 56, 23, 36, 15} do
        font:set_size(size)
        local fresh = new_font(size, antialiasing)
        draw_window(window, function(...) grid(font, ...) end)
        local resized = capture(window)
        assert_grid_visible(resized)
        draw_window(reference, function(...) grid(fresh, ...) end)
        test.ok(resized == capture(reference), "resized/fresh window glyphs differ at " .. size)
        local resized_canvas, fresh_canvas = canvas_grid(font), canvas_grid(fresh)
        assert_grid_visible(resized_canvas)
        test.ok(resized_canvas == fresh_canvas, "resized/fresh canvas glyphs differ at " .. size)
      end
    end
  end)

  test.test("keeps clipped atlas misses safe through font collection", function()
    local window = renwindow.create("Discarded glyph uploads", width, height)
    for i = 1, 24 do
      local font = new_font(18 + i % 7, "grayscale")
      draw_window(window, function(text)
        renderer.set_clip_rect(0, 0, 1, 1)
        text(font, "clipped glyphs", .25, 3, foreground)
      end)
      font = nil
      collectgarbage("collect")
    end
    local font = new_font(25, "grayscale")
    draw_window(window, function(...) grid(font, ...) end)
    assert_grid_visible(capture(window))
  end)

  test.test("preserves layered large icons and color glyphs after resizing", function()
    local window = renwindow.create("Large and color glyph uploads", width, height)
    local reference = renwindow.create("Large glyph reference", width, height)
    local icon = renderer.font.load(DATADIR .. "/fonts/icons.ttf", 110,
      {antialiasing = "grayscale", system_fallback = false})
    local color = renderer.font.load(fixtures .. "color.ttf", 64, {system_fallback = false})
    for _, size in ipairs {110, 165, 77, 143, 110} do
      icon:set_size(size)
      color:set_size(size / 2)
      local function scene(text)
        for i = 5, 9 do text(icon, tostring(i), 8, 4, {25 * i, 210 - 12 * i, 20 * i, 255}) end
        for i = 0, 3 do text(color, string.uchar(0xE000 + i), 220 + i * 82, 8, foreground) end
      end
      draw_window(window, scene)
      local cold = capture(window)
      draw_window(reference, scene)
      test.ok(cold == capture(reference), "layered/color cold and warm glyphs differ")
      for i = 0, 3 do
        local visible = 0
        for y = 8, 118 do
          for x = 220 + i * 82, 220 + i * 82 + 70 do
            local r, _, b = cold:byte((y * width + x) * 4 + 1, (y * width + x) * 4 + 3)
            if r > 90 or b > 90 then visible = visible + 1 end
          end
        end
        test.ok(visible > 4, "missing color glyph " .. i)
      end
    end
  end)
end)
