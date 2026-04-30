local common = require "core.common"
local test = require "core.test"

local temp_root

test.describe("graphics apis", function()
  test.before_each(function(context)
    temp_root = USERDIR
      .. PATHSEP .. "graphics-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    local ok, err = common.mkdirp(temp_root)
    test.ok(ok, err)
    context.temp_root = temp_root
  end)

  test.after_each(function(context)
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  test.test("exports the documented renwindow, renderer and canvas functions", function()
    for _, name in ipairs({"create", "get_size", "get_refresh_rate", "get_color", "_restore"}) do
      test.type(renwindow[name], "function", "missing renwindow." .. name)
    end

    for _, name in ipairs({
      "load", "group", "get_metadata"
    }) do
      test.type(renderer.font[name], "function", "missing renderer.font." .. name)
    end

    for _, name in ipairs({
      "show_debug", "get_size", "begin_frame", "end_frame",
      "set_clip_rect", "draw_rect", "draw_text", "draw_canvas",
      "to_canvas", "draw_poly"
    }) do
      test.type(renderer[name], "function", "missing renderer." .. name)
    end

    for _, name in ipairs({
      "new", "load_image", "load_svg_image"
    }) do
      test.type(canvas[name], "function", "missing canvas." .. name)
    end
  end)

  test.test("loads fonts and exposes font metadata", function()
    local font_path = DATADIR .. PATHSEP .. "fonts" .. PATHSEP .. "FiraSans-Regular.ttf"
    local font = renderer.font.load(font_path, 14 * SCALE)
    test.not_nil(font)
    test.ok(font:get_width("Hello") > 0)
    test.ok(font:get_height() > 0)
    test.ok(font:get_size() > 0)
    test.equal(font:get_path(), font_path)

    font:set_tab_size(2)
    local copy = font:copy(18 * SCALE)
    test.not_nil(copy)
    test.ok(copy:get_size() > font:get_size())

    local metadata, err = renderer.font.get_metadata(font_path)
    test.not_nil(metadata, err)
    test.type(metadata, "table")

    local group = renderer.font.group({font, copy})
    local paths = group:get_path()
    test.type(paths, "table")
    test.equal(paths[1], font_path)

    local group_meta = renderer.font.get_metadata(group)
    test.type(group_meta, "table")
  end)

  test.test("supports canvas pixel, copy and image loading operations", function(context)
    local c = canvas.new(2, 2, {0, 0, 0, 255}, true)
    local width, height = c:get_size()
    test.equal(width, 2)
    test.equal(height, 2)

    local pixels = string.char(
      255, 0, 0, 255,
      0, 255, 0, 255,
      0, 0, 255, 255,
      255, 255, 255, 255
    )
    c:set_pixels(pixels, 0, 0, 2, 2)
    local readback = c:get_pixels(0, 0, 2, 2)
    test.type(readback, "string")
    test.equal(#readback, #pixels)

    local copy = c:copy()
    local copy_width, copy_height = copy:get_size()
    test.equal(copy_width, 2)
    test.equal(copy_height, 2)

    local scaled = c:scaled(4, 4, "nearest")
    local scaled_width, scaled_height = scaled:get_size()
    test.equal(scaled_width, 4)
    test.equal(scaled_height, 4)

    local font = renderer.font.load(
      DATADIR .. PATHSEP .. "fonts" .. PATHSEP .. "FiraSans-Regular.ttf",
      12 * SCALE
    )
    test.type(c:draw_text(font, "A", 0, 0, {255, 255, 255, 255}), "number")
    c:draw_rect(0, 0, 1, 1, {0, 0, 0, 255}, true)
    c:draw_canvas(copy, 0, 0, true)
    local x, y, w, h = c:draw_poly({{0, 0}, {1, 0}, {0, 1}}, {255, 255, 255, 255})
    test.type(x, "number")
    test.type(y, "number")
    test.type(w, "number")
    test.type(h, "number")
    c:render()

    local png_path = context.temp_root .. PATHSEP .. "sample.png"
    local saved, save_err = c:save_image(png_path)
    test.ok(saved, save_err)
    local loaded, load_err = canvas.load_image(png_path)
    test.not_nil(loaded, load_err)
    local loaded_width, loaded_height = loaded:get_size()
    test.equal(loaded_width, 2)
    test.equal(loaded_height, 2)

    local removed, remove_err = os.remove(png_path)
    test.ok(removed, remove_err)

    local svg_path = system.absolute_path("resources/icons/logo.svg")
    local svg_canvas, svg_err = canvas.load_svg_image(svg_path, 32, 32)
    test.not_nil(svg_canvas, svg_err)
    local svg_width, svg_height = svg_canvas:get_size()
    test.equal(svg_width, 32)
    test.equal(svg_height, 32)
  end)

  test.test("renders to a temporary window", function()
    local font = renderer.font.load(
      DATADIR .. PATHSEP .. "fonts" .. PATHSEP .. "FiraSans-Regular.ttf",
      12 * SCALE
    )
    local window = renwindow.create("graphics-test-window", 64, 64)
    test.not_nil(window)

    local width, height = renwindow.get_size(window)
    test.ok(width > 0)
    test.ok(height > 0)

    local refresh_rate = renwindow.get_refresh_rate(window)
    test.ok(refresh_rate == nil or refresh_rate > 0)

    renderer.show_debug(false)
    renderer.begin_frame(window)
    renderer.set_clip_rect(0, 0, width, height)
    renderer.draw_rect(0, 0, width, height, {0, 0, 0, 255})
    test.type(renderer.draw_text(font, "A", 0, 0, {255, 255, 255, 255}), "number")

    local offscreen = canvas.new(4, 4, {0, 0, 0, 255}, true)
    renderer.draw_canvas(offscreen, 0, 0)
    local box_x, box_y, box_w, box_h =
      renderer.draw_poly({{0, 0}, {4, 0}, {0, 4}}, {255, 255, 255, 255})
    test.type(box_x, "number")
    test.type(box_y, "number")
    test.type(box_w, "number")
    test.type(box_h, "number")

    local rendered = renderer.to_canvas(0, 0, 1, 1)
    test.not_nil(rendered)
    local rendered_width, rendered_height = rendered:get_size()
    test.equal(rendered_width, 1)
    test.equal(rendered_height, 1)
    renderer.end_frame()

    local color = renwindow.get_color(window, 0, 0)
    test.type(color, "table")
    test.equal(#color, 4)
  end)
end)
