local common = require "core.common"
local core = require "core"
local command = require "core.command"
local config = require "core.config"
local DocView = require "core.docview"
local EmptyView = require "core.emptyview"
local ImageView = require "core.imageview"
local MarkdownView = require "core.markdownview"
local test = require "core.test"

local temp_root
local project_temp_root

test.describe("graphics apis", function()
  test.before_each(function(context)
    temp_root = USERDIR
      .. PATHSEP .. "graphics-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    local ok, err = common.mkdirp(temp_root)
    test.ok(ok, err)
    context.temp_root = temp_root

    project_temp_root = core.root_project().path
      .. PATHSEP .. "graphics-project-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    ok, err = common.mkdirp(project_temp_root)
    test.ok(ok, err)
    context.project_temp_root = project_temp_root
  end)

  test.after_each(function(context)
    if core.command_view then
      core.command_view:exit(false, true)
    end

    local views = core.root_view.root_node:get_children()
    for i = #views, 1, -1 do
      local view = views[i]
      local remove = false
      if view:extends(ImageView)
          and view.path
          and common.path_belongs_to(view.path, context.project_temp_root) then
        remove = true
      elseif view:extends(DocView)
          and view.doc
          and view.doc.filename
          and common.path_belongs_to(view.doc.filename, context.project_temp_root) then
        remove = true
      elseif context.remove_views then
        for _, removable in ipairs(context.remove_views) do
          if view == removable then
            remove = true
            break
          end
        end
      end

      if remove then
        local node = core.root_view.root_node:get_node_for_view(view)
        if node then
          node:remove_view(core.root_view.root_node, view)
        end
      end
    end

    local keep_output = os.getenv("PRAGTICAL_KEEP_VISUAL_TEST_OUTPUT") == "1"
    if keep_output and context.temp_root then
      print("graphics test output: " .. context.temp_root)
    elseif context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
    if context.project_temp_root and system.get_file_info(context.project_temp_root) then
      local ok, err = common.rm(context.project_temp_root, true)
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

  test.test("supports toggling font ligatures", function()
    local font_path = DATADIR .. PATHSEP .. "fonts" .. PATHSEP .. "JetBrainsMono-Regular.ttf"
    local font_plain = renderer.font.load(font_path, 24 * SCALE, { ligatures = false, antialiasing = "grayscale" })
    local font_liga = renderer.font.load(font_path, 24 * SCALE, { ligatures = true, antialiasing = "grayscale" })
    local font_liga_copy = font_liga:copy(24 * SCALE)
    local font_plain_copy = font_liga:copy(24 * SCALE, { ligatures = false, antialiasing = "grayscale" })
    local text = "-> === ffi"

    test.equal(font_plain:get_width(text), font_plain_copy:get_width(text))
    test.equal(font_liga:get_width(text), font_liga_copy:get_width(text))

    local c_plain = canvas.new(180 * SCALE, 48 * SCALE, {0, 0, 0, 255}, true)
    local c_liga = canvas.new(180 * SCALE, 48 * SCALE, {0, 0, 0, 255}, true)
    local plain_x = c_plain:draw_text(font_plain, text, 0, 0, {255, 255, 255, 255})
    local liga_x = c_liga:draw_text(font_liga, text, 0, 0, {255, 255, 255, 255})

    test.equal(plain_x, font_plain:get_width(text))
    test.equal(liga_x, font_liga:get_width(text))

    c_plain:render()
    c_liga:render()
    local pixels_plain = c_plain:get_pixels(0, 0, 180 * SCALE, 48 * SCALE)
    local pixels_liga = c_liga:get_pixels(0, 0, 180 * SCALE, 48 * SCALE)
    test.ok(pixels_plain ~= pixels_liga, "ligature-enabled rendering should differ from plain glyph rendering")
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

    local blend_dst = canvas.new(2, 2, {0, 0, 0, 255}, true)
    blend_dst:render()
    local blend_src = canvas.new(2, 2, {200, 0, 0, 128}, true)
    blend_src:render()
    blend_dst:draw_canvas(blend_src, 0, 0, true)
    local blended = blend_dst:get_pixels(0, 0, 1, 1)
    local br, bg, bb, ba = blended:byte(1, 4)
    test.ok(br > 80 and br < 130 and bg < 30 and bb < 30 and ba == 255,
      string.format("blended canvas-to-canvas copy should blend source over destination, got %d,%d,%d,%d", br, bg, bb, ba))

    local font = renderer.font.load(
      DATADIR .. PATHSEP .. "fonts" .. PATHSEP .. "FiraSans-Regular.ttf",
      12 * SCALE
    )
    local text_canvas = canvas.new(48, 28, {0, 0, 0, 255}, false)
    text_canvas:draw_text(font, "A", 2, 14, {255, 255, 255, 255})
    text_canvas:render()
    local text_pixels = text_canvas:get_pixels(0, 0, 48, 28)
    local text_visible = 0
    for i = 1, #text_pixels - 3, 4 do
      local tr, tg, tb = text_pixels:byte(i, i + 2)
      if tr > 32 or tg > 32 or tb > 32 then
        text_visible = text_visible + 1
      end
    end
    test.ok(text_visible > 8, "offscreen canvas text should render visible glyph pixels")

    local subpixel_font = renderer.font.load(
      DATADIR .. PATHSEP .. "fonts" .. PATHSEP .. "FiraSans-Regular.ttf",
      24 * SCALE,
      { antialiasing = "subpixel" }
    )
    local subpixel_canvas = canvas.new(180, 48, {0, 0, 0, 255}, false)
    subpixel_canvas:draw_text(subpixel_font, "Subpixel", 2, 4, {255, 255, 255, 255})
    subpixel_canvas:render()
    local subpixel_pixels = subpixel_canvas:get_pixels(0, 0, 180, 48)
    local subpixel_visible = 0
    local subpixel_colored = 0
    for i = 1, #subpixel_pixels - 3, 4 do
      local sr, sg, sb = subpixel_pixels:byte(i, i + 2)
      if sr > 16 or sg > 16 or sb > 16 then
        subpixel_visible = subpixel_visible + 1
        if math.abs(sr - sg) > 8 or math.abs(sg - sb) > 8 or math.abs(sr - sb) > 8 then
          subpixel_colored = subpixel_colored + 1
        end
      end
    end
    test.ok(subpixel_visible > 16, "subpixel canvas text should render visible glyph pixels")
    test.ok(subpixel_colored > 0, "subpixel canvas text should preserve RGB coverage masks")

    local poly_canvas = canvas.new(24, 24, {0, 0, 0, 255}, false)
    poly_canvas:draw_poly({{2, 2}, {20, 2}, {2, 20}}, {255, 255, 255, 255})
    poly_canvas:render()
    local poly_pixels = poly_canvas:get_pixels(0, 0, 24, 24)
    local pr, pg, pb = poly_pixels:byte(((6 * 24 + 6) * 4) + 1, ((6 * 24 + 6) * 4) + 3)
    test.ok(pr > 160 and pg > 160 and pb > 160,
      string.format("offscreen canvas polygon should render visible pixels, got %d,%d,%d", pr, pg, pb))

    local curve_canvas = canvas.new(32, 32, {0, 0, 0, 255}, false)
    curve_canvas:draw_poly({{4, 26}, {4, 4, 28, 4, 28, 26}}, {255, 255, 255, 255})
    curve_canvas:render()
    local curve_pixels = curve_canvas:get_pixels(0, 0, 32, 32)
    local cr, cg, cb = curve_pixels:byte(((12 * 32 + 16) * 4) + 1, ((12 * 32 + 16) * 4) + 3)
    test.ok(cr > 120 and cg > 120 and cb > 120,
      string.format("offscreen canvas curved polygon should render visible pixels, got %d,%d,%d", cr, cg, cb))

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

  test.test("opens project-relative images through core.open_file", function(context)
    local c = canvas.new(2, 2, {255, 0, 0, 255}, true)
    local image_path = context.project_temp_root .. PATHSEP .. "treeview-image.png"
    local saved, save_err = c:save_image(image_path)
    test.ok(saved, save_err)

    local relative_path = common.relative_path(core.root_project().path, image_path)
    local cwd = system.getcwd()
    system.chdir(context.temp_root)
    local view = core.open_file(relative_path)
    system.chdir(cwd)

    test.not_nil(view)
    test.ok(view:extends(ImageView))
    test.equal(view.path, image_path)
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

  test.test("captures visual frames for analysis", function(context)
    local width, height = 320, 180
    local window = renwindow.create("graphics-visual-capture", width, height)
    test.not_nil(window)

    local font = renderer.font.load(
      DATADIR .. PATHSEP .. "fonts" .. PATHSEP .. "JetBrainsMono-Regular.ttf",
      15 * SCALE,
      { antialiasing = "grayscale" }
    )
    local icon_font = renderer.font.load(
      DATADIR .. PATHSEP .. "fonts" .. PATHSEP .. "icons.ttf",
      18 * SCALE,
      { antialiasing = "grayscale", hinting = "full" }
    )

    local image = canvas.new(34, 34, {0, 0, 0, 0}, true)
    image:draw_rect(0, 0, 34, 34, {40, 48, 58, 230}, true)
    image:draw_rect(6, 6, 22, 22, {92, 160, 220, 220}, false)
    image:render()

    local function average_region(pixels, image_width, x, y, w, h)
      local r, g, b, a, n = 0, 0, 0, 0, 0
      for yy = y, y + h - 1 do
        for xx = x, x + w - 1 do
          local i = ((yy * image_width + xx) * 4) + 1
          local pr, pg, pb, pa = pixels:byte(i, i + 3)
          r, g, b, a, n = r + pr, g + pg, b + pb, a + pa, n + 1
        end
      end
      return r / n, g / n, b / n, a / n
    end

    local captures = {}
    for frame = 1, 6 do
      renderer.begin_frame(window)
      renderer.set_clip_rect(0, 0, width, height)
      renderer.draw_rect(0, 0, width, height, {8, 10, 14, 255}, true)
      renderer.draw_rect(0, 0, width, 32, {32, 36, 44, 255}, true)
      renderer.draw_text(font, "visual frame " .. frame, 12, 8, {230, 230, 235, 255})
      renderer.draw_text(icon_font, "o", 286, 8, {210, 210, 215, 255})
      renderer.draw_canvas(image, 230, 104)

      if frame < 4 then
        renderer.draw_rect(24, 64, 72, 48, {210, 40, 50, 255}, true)
        renderer.draw_text(font, "RED", 38, 78, {255, 255, 255, 255})
      else
        renderer.draw_rect(24, 64, 72, 48, {30, 170, 90, 255}, true)
        renderer.draw_text(font, "GREEN", 30, 78, {255, 255, 255, 255})
      end

      if frame % 2 == 0 then
        renderer.draw_rect(130, 64, 58, 48, {60, 100, 230, 255}, true)
      else
        renderer.draw_rect(130, 64, 58, 48, {210, 180, 40, 255}, true)
      end
      renderer.end_frame()

      if frame % 2 == 0 then
        local capture = renderer.to_canvas(window, 0, 0, width, height)
        test.not_nil(capture)
        local path = context.temp_root .. PATHSEP .. string.format("visual-frame-%02d.png", frame)
        local saved, err = capture:save_image(path)
        test.ok(saved, err)
        local pixels = capture:get_pixels(0, 0, width, height)
        captures[frame] = pixels
      end
    end

    local r2, g2, b2 = average_region(captures[2], width, 30, 70, 40, 28)
    test.ok(r2 > 160 and g2 < 90 and b2 < 100, "frame 2 marker should be red")

    local r4, g4, b4 = average_region(captures[4], width, 30, 70, 40, 28)
    test.ok(g4 > 130 and r4 < 90 and b4 < 130, "frame 4 marker should be green, not stale red")

    local r6, g6, b6 = average_region(captures[6], width, 30, 70, 40, 28)
    test.ok(g6 > 130 and r6 < 90 and b6 < 130, "frame 6 marker should remain green")

    local br4, bg4, bb4 = average_region(captures[4], width, 12, 140, 120, 20)
    test.ok(br4 < 30 and bg4 < 35 and bb4 < 45, "cleared background should not contain stale text")
  end)

  test.test("renders native canvas blend, replace and clipping semantics", function(context)
    local width, height = 180, 130
    local window = renwindow.create("graphics-canvas-semantics", width, height)
    test.not_nil(window)

    local alpha = canvas.new(36, 36, {0, 0, 0, 0}, true)
    alpha:draw_rect(0, 0, 36, 36, {220, 20, 20, 128}, true)
    alpha:render()

    local opaque = canvas.new(28, 28, {0, 210, 40, 255}, false)
    opaque:render()

    local yellow = canvas.new(30, 30, {245, 210, 20, 255}, false)
    yellow:render()

    local cyan = canvas.new(36, 36, {30, 210, 220, 255}, false)
    cyan:render()

    renderer.begin_frame(window)
    renderer.set_clip_rect(0, 0, width, height)
    renderer.draw_rect(0, 0, width, height, {20, 40, 200, 255}, true)
    renderer.draw_canvas(alpha, 18, 16)
    renderer.draw_rect(68, 16, 32, 32, {210, 20, 20, 255}, true)
    renderer.draw_canvas(opaque, 70, 18)
    renderer.draw_canvas(yellow, -10, 76)
    renderer.set_clip_rect(120, 74, 22, 22)
    renderer.draw_canvas(cyan, 110, 64)
    renderer.set_clip_rect(0, 0, width, height)
    renderer.end_frame()

    local capture = renderer.to_canvas(window, 0, 0, width, height)
    test.not_nil(capture)
    local path = context.temp_root .. PATHSEP .. "canvas-semantics.png"
    local saved, save_err = capture:save_image(path)
    test.ok(saved, save_err)
    local pixels = capture:get_pixels(0, 0, width, height)

    local function average_region(x, y, w, h)
      local r, g, b, a, n = 0, 0, 0, 0, 0
      for yy = y, y + h - 1 do
        for xx = x, x + w - 1 do
          local idx = ((yy * width + xx) * 4) + 1
          local pr, pg, pb, pa = pixels:byte(idx, idx + 3)
          r, g, b, a, n = r + pr, g + pg, b + pb, a + pa, n + 1
        end
      end
      return r / n, g / n, b / n, a / n
    end

    local ar, ag, ab = average_region(28, 26, 12, 12)
    test.ok(ar > 95 and ar < 135 and ag > 25 and ag < 50 and ab > 95 and ab < 130,
      "alpha canvas should blend over the blue background")

    local or_, og, ob = average_region(76, 24, 12, 12)
    test.ok(or_ < 30 and og > 180 and ob < 70,
      "opaque canvas should replace the red destination")

    local yr, yg, yb = average_region(2, 82, 10, 10)
    test.ok(yr > 210 and yg > 180 and yb < 60,
      "negative canvas destination should draw the visible clipped source")

    local br, bg, bb = average_region(28, 82, 10, 10)
    test.ok(br < 35 and bg < 55 and bb > 170,
      "negative canvas destination should not leak outside the source bounds")

    local cr, cg, cb = average_region(123, 77, 10, 10)
    test.ok(cr < 70 and cg > 170 and cb > 180,
      "canvas draw should respect the active clip rect")

    local nr, ng, nb = average_region(111, 65, 6, 6)
    test.ok(nr < 35 and ng < 55 and nb > 170,
      "canvas pixels outside the clip rect should preserve the background")
  end)

  test.test("renders updated canvas textures after previous frame upload", function(context)
    local width, height = 120, 80
    local window = renwindow.create("graphics-canvas-mutation", width, height)
    test.not_nil(window)

    local source = canvas.new(32, 32, {220, 20, 20, 255}, false)
    source:render()

    renderer.begin_frame(window)
    renderer.set_clip_rect(0, 0, width, height)
    renderer.draw_rect(0, 0, width, height, {15, 20, 28, 255}, true)
    renderer.draw_canvas(source, 38, 18)
    renderer.end_frame()
    local source_capture = renderer.to_canvas(window, 0, 0, width, height)
    test.not_nil(source_capture)
    local source_pixels = source_capture:get_pixels(0, 0, width, height)
    local sr, sg, sb = source_pixels:byte(((30 * width + 50) * 4) + 1, ((30 * width + 50) * 4) + 3)
    test.ok(sr > 170 and sg < 70 and sb < 80,
      string.format("source canvas should draw red before offscreen copy, got %d,%d,%d", sr, sg, sb))

    local target = canvas.new(44, 44, {0, 0, 0, 0}, true)
    target:draw_canvas(source, 6, 6, false)
    target:render()
    renderer.begin_frame(window)
    renderer.set_clip_rect(0, 0, width, height)
    renderer.draw_rect(0, 0, width, height, {15, 20, 28, 255}, true)
    renderer.draw_canvas(target, 38, 18)
    renderer.end_frame()
    local target_capture = renderer.to_canvas(window, 0, 0, width, height)
    test.not_nil(target_capture)
    local target_capture_pixels = target_capture:get_pixels(0, 0, width, height)
    local wr, wg, wb = target_capture_pixels:byte(((30 * width + 50) * 4) + 1, ((30 * width + 50) * 4) + 3)
    test.ok(wr > 170 and wg < 70 and wb < 80,
      string.format("target canvas texture should draw red before readback, got %d,%d,%d", wr, wg, wb))
    local target_pixels = target:get_pixels(6, 6, 1, 1)
    local tr, tg, tb = target_pixels:byte(1, 3)
    test.ok(tr > 170 and tg < 70 and tb < 80,
      string.format(
        "canvas-to-canvas copy should update the destination canvas, got %d,%d,%d",
        tr,
        tg,
        tb
      ))

    local function draw_and_capture(label)
      renderer.begin_frame(window)
      renderer.set_clip_rect(0, 0, width, height)
      renderer.draw_rect(0, 0, width, height, {15, 20, 28, 255}, true)
      renderer.draw_canvas(target, 38, 18)
      renderer.end_frame()

      local capture = renderer.to_canvas(window, 0, 0, width, height)
      test.not_nil(capture)
      local path = context.temp_root .. PATHSEP .. label .. ".png"
      local saved, save_err = capture:save_image(path)
      test.ok(saved, save_err)
      return capture:get_pixels(0, 0, width, height)
    end

    local first = draw_and_capture("canvas-mutation-before")

    source:draw_rect(0, 0, 32, 32, {30, 210, 70, 255}, true)
    source:render()
    target:draw_rect(0, 0, 44, 44, {0, 0, 0, 0}, true)
    target:render()
    target:draw_canvas(source, 6, 6, false)
    target:render()

    local second = draw_and_capture("canvas-mutation-after")

    local function average_region(pixels, x, y, w, h)
      local r, g, b, a, n = 0, 0, 0, 0, 0
      for yy = y, y + h - 1 do
        for xx = x, x + w - 1 do
          local idx = ((yy * width + xx) * 4) + 1
          local pr, pg, pb, pa = pixels:byte(idx, idx + 3)
          r, g, b, a, n = r + pr, g + pg, b + pb, a + pa, n + 1
        end
      end
      return r / n, g / n, b / n, a / n
    end

    local r1, g1, b1 = average_region(first, 50, 30, 18, 18)
    test.ok(r1 > 170 and g1 < 70 and b1 < 80,
      "first canvas upload should render the red source")

    local r2, g2, b2 = average_region(second, 50, 30, 18, 18)
    test.ok(g2 > 160 and r2 < 90 and b2 < 100,
      string.format(
        "mutated canvas should render fresh green pixels, not stale pixels, got %.1f,%.1f,%.1f",
        r2,
        g2,
        b2
      ))
  end)

  test.test("captures user-like editor flow frames for analysis", function(context)
    local window = core.window
    test.not_nil(window)
    local repo_root = system.getcwd()

    local width, height = window:get_size()
    test.ok(width >= 320 and height >= 200, "main window should be large enough for visual capture")

    local fixture_path = context.project_temp_root .. PATHSEP .. "visual-user-flow.lua"
    local fp, err = io.open(fixture_path, "w")
    test.not_nil(fp, err)
    for i = 1, 220 do
      fp:write(string.format(
        "local row_%03d = %d -- visual replay line %03d keeps text and gutters moving\n",
        i, i, i
      ))
    end
    fp:close()

    local capture_every = tonumber(os.getenv("PRAGTICAL_VISUAL_CAPTURE_EVERY") or "2") or 2
    capture_every = math.max(1, math.floor(capture_every))

    local frame = 0
    local captures = {}
    local function capture(label)
      local c = renderer.to_canvas(window, 0, 0, width, height)
      test.not_nil(c, "failed to capture " .. label)
      local path = context.temp_root .. PATHSEP
        .. string.format("visual-user-flow-%03d-%s.png", frame, label)
      local saved, save_err = c:save_image(path)
      test.ok(saved, save_err)
      captures[label] = {
        pixels = c:get_pixels(0, 0, width, height),
        path = path
      }
    end

    local function capture_region(label, x, y, w, h)
      local c = renderer.to_canvas(window, x, y, w, h)
      test.not_nil(c, "failed to capture " .. label)
      local path = context.temp_root .. PATHSEP
        .. string.format("visual-user-flow-%03d-%s.png", frame, label)
      local saved, save_err = c:save_image(path)
      test.ok(saved, save_err)
      captures[label] = {
        pixels = c:get_pixels(0, 0, w, h),
        path = path,
        width = w,
        height = h
      }
    end

    local function pump(label, count, force_capture)
      count = count or 1
      for i = 1, count do
        frame = frame + 1
        core.redraw = true
        core.step(1 / 60)
        if force_capture or (force_capture ~= false and frame % capture_every == 0) then
          capture(label .. "-" .. string.format("%02d", i))
        end
        if coroutine.isyieldable() then coroutine.yield(0) end
      end
    end

    local function average_region(pixels, image_width, x, y, w, h)
      local r, g, b, a, n = 0, 0, 0, 0, 0
      x = common.clamp(math.floor(x), 0, image_width - 1)
      y = common.clamp(math.floor(y), 0, height - 1)
      w = math.min(math.floor(w), image_width - x)
      h = math.min(math.floor(h), height - y)
      for yy = y, y + h - 1 do
        for xx = x, x + w - 1 do
          local idx = ((yy * image_width + xx) * 4) + 1
          local pr, pg, pb, pa = pixels:byte(idx, idx + 3)
          r, g, b, a, n = r + pr, g + pg, b + pb, a + pa, n + 1
        end
      end
      return r / n, g / n, b / n, a / n
    end

    local function mean_delta(a, b, step)
      step = step or 64
      local total, n = 0, 0
      for i = 1, math.min(#a, #b) - 3, step * 4 do
        local ar, ag, ab = a:byte(i, i + 2)
        local br, bg, bb = b:byte(i, i + 2)
        total = total + math.abs(ar - br) + math.abs(ag - bg) + math.abs(ab - bb)
        n = n + 3
      end
      return total / math.max(n, 1)
    end

    local function wait_until(predicate, label, limit)
      limit = limit or 60
      for i = 1, limit do
        if predicate() then
          return true
        end
        pump(label, 1, false)
      end
      return predicate()
    end

    local function click_widget(widget)
      test.not_nil(widget, "missing widget to click")
      core.root_view:on_mouse_moved(
        widget.position.x + math.floor(widget:get_width() / 2),
        widget.position.y + math.floor(widget:get_height() / 2),
        0,
        0
      )
      core.root_view:on_mouse_pressed(
        "left",
        widget.position.x + math.floor(widget:get_width() / 2),
        widget.position.y + math.floor(widget:get_height() / 2),
        1
      )
      core.root_view:on_mouse_released(
        "left",
        widget.position.x + math.floor(widget:get_width() / 2),
        widget.position.y + math.floor(widget:get_height() / 2)
      )
    end

    local function assert_not_blank(label)
      local capture_data = captures[label]
      test.not_nil(capture_data, "missing capture " .. label)
      local capture_width = capture_data.width or width
      local capture_height = capture_data.height or height
      local r, g, b = average_region(
        capture_data.pixels,
        capture_width,
        0,
        0,
        capture_width,
        capture_height
      )
      test.ok(r + g + b > 6, label .. " should not be blank")
    end

    local function count_blue_pixels(label)
      local capture_data = captures[label]
      test.not_nil(capture_data, "missing capture " .. label)
      local pixels = capture_data.pixels
      local count = 0
      for i = 1, #pixels - 3, 4 do
        local r, g, b, a = pixels:byte(i, i + 3)
        if a > 128 and b > 150 and b > r + 35 and b > g + 15 then
          count = count + 1
        end
      end
      return count
    end

    local scale = require "plugins.scale"
    local previous_scale = SCALE
    local previous_code_scale = scale.get_code()
    local previous_transitions = config.transitions
    local previous_scroll_transition = config.disabled_transitions.scroll
    config.transitions = true
    config.disabled_transitions.scroll = true

    local image_viewer_labels = {}
    local ok, flow_err = xpcall(function()
      local doc_view = core.open_file(fixture_path)
      test.not_nil(doc_view)
      test.ok(doc_view:extends(DocView))
      pump("file-open", 2, true)

      doc_view:scroll_to_line(120, false, true)
      pump("file-scrolled", 2, true)

      local context_menu = require "plugins.contextmenu"
      test.ok(command.perform("context:show"))
      pump("context-menu", 3, true)
      context_menu:hide()
      pump("context-menu-closed", 2, true)

      test.ok(command.perform("ui:settings"))
      if package.loaded["plugins.settings"] then
        local settings = require "plugins.settings"
        if settings.ui then
          context.remove_views = context.remove_views or {}
          table.insert(context.remove_views, settings.ui)
        end
      end
      pump("settings-open", 2, true)
      capture_region("settings-open-tab-strip", 0, 0, width, math.min(height, 96))

      local function scale_label(value)
        return string.format("%.2f", value):gsub("%.", "_")
      end

      local function exercise_image_viewer_settings(scale_value)
        scale.set(scale_value)
        scale.set_code(scale_value)
        pump("settings-scale-" .. scale_label(scale_value), 2, true)

        local settings = require "plugins.settings"
        local pane = settings.ui.core_sections:get_pane("Image Viewer")
        test.not_nil(pane, "Image Viewer settings pane should exist")

        if pane.container:is_visible() then
          click_widget(pane.tab)
          test.ok(
            wait_until(
              function()
                return not pane.container:is_visible() and not pane.container.animating
              end,
              "settings-image-viewer-collapsing-" .. scale_label(scale_value),
              120
            ),
            "Image Viewer settings pane should finish collapsing"
          )
          pump("settings-image-viewer-collapsed-" .. scale_label(scale_value), 2, true)
        end

        click_widget(pane.tab)
        test.ok(
          wait_until(
            function()
              return pane.container:is_visible() and not pane.container.animating
            end,
            "settings-image-viewer-expanding-" .. scale_label(scale_value),
            120
          ),
          "Image Viewer settings pane should finish expanding"
        )
        local label = "settings-image-viewer-click-" .. scale_label(scale_value)
        pump(label, 3, true)
        table.insert(image_viewer_labels, label .. "-01")
      end

      for _, settings_scale in ipairs({1.00, 1.25, 1.45, 1.50}) do
        exercise_image_viewer_settings(settings_scale)
      end

      test.ok(command.perform("core:find-command"))
      core.command_view:set_text("settings")
      core.command_view:update_suggestions()
      pump("command-prompt", 2, true)
      core.command_view:set_text("set")
      core.command_view:update_suggestions()
      pump("command-suggestions", 4, true)
      core.command_view:move_suggestion_idx(1)
      pump("command-suggestion-next", 3, true)
      core.command_view:exit(false, true)
      pump("command-closed", 2, true)

      test.ok(command.perform("root:close"))
      pump("settings-closed", 2, true)

      core.root_view:get_active_node_default():set_active_view(doc_view)
      doc_view:scroll_to_line(30, false, true)
      pump("file-rescrolled", 2, true)

      test.ok(command.perform("root:split-right"))
      pump("split-right", 3, true)
      test.ok(command.perform("root:switch-to-left"))
      pump("split-left-active", 2, true)

      core.root_view:close_all_docviews()
      core.root_view.root_node:update_layout()
      pump("file-closed-before-image", 2, false)

      local logo_path = repo_root
        .. PATHSEP .. "resources" .. PATHSEP .. "icons" .. PATHSEP .. "logo.svg"
      test.not_nil(system.get_file_info(logo_path), "logo.svg should exist")
      local image_view = ImageView(logo_path)
      test.not_nil(image_view.image, image_view.errmsg)
      core.root_view:get_active_node_default():add_view(image_view)
      core.root_view.root_node:update_layout()
      context.remove_views = context.remove_views or {}
      table.insert(context.remove_views, image_view)
      pump("imageview-logo-svg", 4, true)
      for _ = 1, 3 do
        image_view:zoom_in()
        pump("imageview-logo-zooming", 2, true)
      end
      image_view.scroll.to.x = math.min(
        math.max(image_view:get_h_scrollable_size() - image_view.size.x, 0),
        48 * SCALE
      )
      image_view.scroll.to.y = math.min(
        math.max(image_view:get_scrollable_size() - image_view.size.y, 0),
        48 * SCALE
      )
      image_view.scroll.x = image_view.scroll.to.x
      image_view.scroll.y = image_view.scroll.to.y
      pump("imageview-logo-panned", 3, true)
      image_view:zoom_reset()
      pump("imageview-logo-reset", 2, true)

      test.ok(command.perform("root:close"))
      pump("image-closed-before-markdown", 2, false)

      local logo_source = io.open(logo_path, "rb")
      test.not_nil(logo_source, "failed to open logo.svg")
      local logo_data = logo_source:read("*a")
      logo_source:close()
      local markdown_logo_path = context.project_temp_root .. PATHSEP .. "logo.svg"
      local logo_copy = io.open(markdown_logo_path, "wb")
      test.not_nil(logo_copy, "failed to create markdown logo fixture")
      logo_copy:write(logo_data)
      logo_copy:close()

      local markdown_path = context.project_temp_root .. PATHSEP .. "visual-markdown-image.md"
      local md = io.open(markdown_path, "w")
      test.not_nil(md, "failed to create markdown image fixture")
      md:write("# Markdown Image\n\n![Pragtical logo](logo.svg)\n")
      md:close()
      local markdown_view = MarkdownView(markdown_path)
      test.ok(markdown_view:extends(MarkdownView), "markdown fixture should open in MarkdownView")
      core.root_view:get_active_node_default():add_view(markdown_view)
      core.root_view.root_node:update_layout()
      context.remove_views = context.remove_views or {}
      table.insert(context.remove_views, markdown_view)
      pump("markdown-logo-svg", 6, true)

      test.ok(command.perform("root:close"))
      pump("emptyview-transition", 2, false)
      test.ok(core.active_view:extends(EmptyView), "zoom checkpoints should use EmptyView")
      pump("emptyview", 1, true)

      for _, zoom in ipairs({1.45, 1.50}) do
        scale.set(zoom)
        scale.set_code(zoom)
        pump(string.format("zoom-%.2f", zoom):gsub("%.", "_"), 3, true)
      end
      scale.set(previous_scale)
      scale.set_code(previous_code_scale)
      pump("zoom-restored", 2, true)
    end, debug.traceback)

    scale.set(previous_scale)
    scale.set_code(previous_code_scale)
    config.transitions = previous_transitions
    config.disabled_transitions.scroll = previous_scroll_transition
    test.ok(ok, flow_err)

    assert_not_blank("file-open-01")
    assert_not_blank("settings-open-01")
    assert_not_blank("settings-open-tab-strip")
    for _, label in ipairs(image_viewer_labels) do
      assert_not_blank(label)
    end
    assert_not_blank("command-prompt-01")
    assert_not_blank("command-suggestions-01")
    assert_not_blank("command-suggestion-next-01")
    assert_not_blank("emptyview-01")
    assert_not_blank("zoom-1_45-01")
    assert_not_blank("zoom-1_50-01")
    assert_not_blank("context-menu-01")
    assert_not_blank("file-rescrolled-01")
    assert_not_blank("split-right-01")
    assert_not_blank("split-left-active-01")
    assert_not_blank("imageview-logo-svg-01")
    assert_not_blank("imageview-logo-zooming-01")
    assert_not_blank("imageview-logo-panned-01")
    assert_not_blank("imageview-logo-reset-01")
    assert_not_blank("markdown-logo-svg-01")
    test.ok(
      count_blue_pixels("imageview-logo-svg-01") > 200,
      "logo.svg ImageView capture should preserve the logo's blue channels"
    )
    test.ok(
      count_blue_pixels("imageview-logo-zooming-01") > 200,
      "zoomed logo.svg ImageView capture should preserve the logo's blue channels"
    )
    test.ok(
      count_blue_pixels("markdown-logo-svg-01") > 200,
      "MarkdownView image capture should preserve SVG logo colors"
    )

    test.ok(
      mean_delta(captures["file-open-01"].pixels, captures["file-scrolled-01"].pixels) > 0.25,
      "scrolling should visibly change the captured editor frame"
    )
    test.ok(
      mean_delta(captures["settings-open-01"].pixels, captures["command-prompt-01"].pixels) > 0.25,
      "command prompt should visibly change the captured settings frame"
    )
    test.ok(
      mean_delta(captures["command-prompt-01"].pixels, captures["command-suggestions-01"].pixels) > 0.05,
      "command suggestions should visibly change after typing a different command prefix"
    )
    test.ok(
      mean_delta(captures["command-closed-01"].pixels, captures["settings-closed-01"].pixels) > 0.25,
      "closing settings should visibly restore a different editor frame"
    )
    test.ok(
      mean_delta(captures["file-rescrolled-01"].pixels, captures["split-right-01"].pixels) > 0.05,
      "splitting the editor should visibly change the captured frame"
    )
    test.ok(
      mean_delta(captures["imageview-logo-svg-01"].pixels, captures["imageview-logo-zooming-01"].pixels) > 0.05,
      "zooming ImageView should visibly change the captured frame"
    )
    test.ok(
      mean_delta(captures["emptyview-01"].pixels, captures["zoom-1_45-01"].pixels) > 0.05,
      "zooming EmptyView to 1.45 should visibly change the captured frame"
    )
    test.ok(
      mean_delta(captures["zoom-1_45-01"].pixels, captures["zoom-1_50-01"].pixels) > 0.05,
      "zooming EmptyView from 1.45 to 1.50 should visibly change the captured frame"
    )
  end)
end)
