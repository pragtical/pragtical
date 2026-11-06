local renderer = require "renderer"
local renwindow = require "renwindow"
local canvas = require "canvas"
local test = require "core.test"

local background = { 20, 25, 30, 255 }
local red, green = { 220, 40, 50, 255 }, { 30, 210, 70, 255 }

---Draw a complete frame, keeping the target's previous cache contents.
---@param window renwindow
---@param scene fun()
local function frame(window, scene)
  local w, h = window:get_size()
  renderer.begin_frame(window)
  renderer.set_clip_rect(0, 0, w, h)
  renderer.draw_rect(0, 0, w, h, background)
  scene()
  renderer.end_frame()
end

---Capture rendered pixels, including GPU readback when applicable.
---@param window renwindow
---@return string
local function pixels(window)
  local w, h = window:get_size()
  return renderer.to_canvas(window, 0, 0, w, h):get_pixels(0, 0, w, h)
end

test.describe("render cache", function()
  test.after_each(function() renderer.show_debug(false) end)

  test.test("keeps clip-only changes out of dirty regions", function()
    local window = renwindow.create("Clip-only damage", 300, 240)
    local inset = 10
    local function scene()
      renderer.set_clip_rect(inset, 10, 100, 100)
      renderer.set_clip_rect(0, 0, 300, 240)
    end
    frame(window, scene); frame(window, scene)
    renderer.show_debug(true)
    local before = pixels(window)
    inset = 11
    frame(window, scene)
    test.equal(pixels(window), before)
  end)

  test.test("tracks clip changes inside one cell", function()
    local window = renwindow.create("Effective clipping", 120, 80)
    local width = 20
    local function scene()
      renderer.set_clip_rect(10, 10, width, 30)
      renderer.draw_rect(10, 10, 60, 30, red)
    end
    frame(window, scene); frame(window, scene)
    width = 21
    frame(window, scene)
    local expected = renwindow.create("Clipping reference", 120, 80)
    frame(expected, scene)
    test.equal(pixels(window), pixels(expected))
  end)

  test.test("keeps large identical command lists cached", function()
    local window = renwindow.create("Static command list", 900, 650)
    local font = renderer.font.load(DATADIR .. "/fonts/JetBrainsMono-Regular.ttf", 14)
    local function scene()
      for i = 0, 1799 do
        renderer.draw_text(font, "word", i % 30 * 25, math.floor(i % 900 / 30) * 18, red)
      end
    end
    frame(window, scene); frame(window, scene)
    renderer.show_debug(true)
    frame(window, scene)
    local before = pixels(window)
    frame(window, scene)
    test.equal(pixels(window), before)
  end)

  test.test("ignores transparent fills while retaining transparent replacement", function()
    local window = renwindow.create("Transparent damage", 120, 80)
    local color = {200, 0, 0, 0}
    local function scene() renderer.draw_rect(10, 10, 30, 30, color) end
    frame(window, scene); frame(window, scene)
    renderer.show_debug(true)
    local before = pixels(window)
    color = {0, 200, 0, 0}
    frame(window, scene)
    test.equal(pixels(window), before)
    renderer.show_debug(false)
    local target = canvas.new(4, 4, red)
    target:draw_rect(0, 0, 4, 4, color, true)
    target:render()
    test.equal(target:get_pixels(0, 0, 1, 1):byte(4), 0)
  end)

  test.test("restores partial replay after a dense frame", function()
    local window = renwindow.create("Dense-to-sparse replay", 900, 650)
    local font = renderer.font.load(DATADIR .. "/fonts/JetBrainsMono-Regular.ttf", 14)
    local phase = 1
    local function scene()
      for i = 0, 1799 do
        renderer.draw_text(font, "word", i % 30 * 25, math.floor(i % 900 / 30) * 18,
          phase == 1 and red or green)
      end
      renderer.draw_rect(50 + math.min(phase, 4), 55, 1, 12, red)
    end
    for i = 1, 5 do
      phase = i
      frame(window, scene)
      local reference = renwindow.create("Dense-to-sparse reference", 900, 650)
      frame(reference, scene)
      test.equal(pixels(window), pixels(reference), "incorrect transition at phase " .. phase)
    end
  end)

  for _, shape in ipairs { "aligned", "L" } do
    test.test("does not absorb clean cells around " .. shape .. " damage", function()
      local window = renwindow.create("Dirty cells " .. shape, 600, 600)
      local color = red
      local function scene()
        if shape == "aligned" then
          renderer.draw_rect(120, 120, 60, 60, color)
        else
          for i = 0, 9 do
            renderer.draw_rect(i * 60 + 10, 10, 1, 1, color)
            renderer.draw_rect(10, i * 60 + 10, 1, 1, color)
          end
        end
      end
      frame(window, scene); frame(window, scene)
      color = green
      renderer.show_debug(true)
      frame(window, scene)
      local x, y = shape == "aligned" and 200 or 300, shape == "aligned" and 140 or 300
      local sample = renderer.to_canvas(window, x, y, 1, 1):get_pixels(0, 0, 1, 1)
      test.same({sample:byte(1, 4)}, background)
    end)
  end

  test.test("finishes pending canvas draws before checking parent damage", function()
    local window = renwindow.create("Deferred canvas", 120, 80)
    local source = canvas.new(30, 30, red)
    local function scene() renderer.draw_canvas(source, 10, 10) end
    frame(window, scene); frame(window, scene)
    source:draw_rect(0, 0, 30, 30, green, true)
    frame(window, scene)
    local value = renderer.to_canvas(window, 15, 15, 1, 1):get_pixels(0, 0, 1, 1)
    test.same({value:byte(1, 4)}, green)
  end)

  test.test("preserves text, decorations and transparency during partial replay", function()
    local font = renderer.font.load(DATADIR .. "/fonts/JetBrainsMono-Regular.ttf", 24,
      {italic = true, underline = true, strikethrough = true, ligatures = true})
    local fallback = renderer.font.load(DATADIR .. "/fonts/FiraSans-Regular.ttf", 48)
    local group = renderer.font.group({font, fallback})
    local window = renwindow.create("Partial text replay", 480, 300)
    local phase = 0
    local function scene()
      renderer.set_clip_rect(15, 12, 440, 270)
      for row = 0, 5 do
        renderer.draw_text(group, "jffi -> == Αβγ", 40.25, row * 42 + 14.5, red)
      end
      renderer.draw_poly({{80, 20}, {160, 80}, {70, 130}}, {20, 90, 180, 100})
      renderer.draw_rect(phase * 55 + 60, 55, 2, 20, green)
    end
    for i = 0, 5 do
      phase = i
      frame(window, scene)
      local reference = renwindow.create("Text replay reference", 480, 300)
      frame(reference, scene)
      test.equal(pixels(window), pixels(reference), "partial replay differs at phase " .. i)
    end
  end)

  for _, size in ipairs { {7680, 2}, {7681, 2}, {2, 4320}, {2, 4321} } do
    test.test("renders the target edge at " .. size[1] .. "x" .. size[2], function()
      local w, h = size[1], size[2]
      local target = canvas.new(w, h, background)
      for _, color in ipairs {red, green} do
        target:draw_rect(w - 1, h - 1, 1, 1, color, true)
        target:render()
        test.same({target:get_pixels(w - 1, h - 1, 1, 1):byte(1, 4)}, color)
      end
    end)
  end
end)
