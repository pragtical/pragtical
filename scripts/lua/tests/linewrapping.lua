local test = require "core.test"
local Doc = require "core.doc"
local DocView = require "core.docview"
local LineWrapping = require "plugins.linewrapping"
local config = require "core.config"
local style = require "core.style"
require "plugins.codefold"
dofile("subprojects/plugins/plugins/indentguide.lua")

local function make_view(text)
  local doc = Doc(nil, nil, true)
  doc.lines = { text }
  doc.cache.col_x = {}
  doc.cache.ulen = {}
  doc.highlighter:reset()

  local view = DocView(doc)
  view.position.x = 0
  view.position.y = 0
  view.size.x = 320
  view.size.y = 200
  view.indentguide_indents = {}
  view.indentguide_indent_active = {}
  return view
end

local function with_draw_text(fn)
  local original = renderer.draw_text
  local calls = {}
  renderer.draw_text = function(font, text, x, y, color, options)
    calls[#calls + 1] = {
      text = text,
      x = x,
      y = y,
      color = color,
      options = options
    }
    return x + font:get_width(text, options)
  end

  local ok, err = pcall(fn, calls)
  renderer.draw_text = original
  if not ok then error(err, 0) end
end

local function with_draw_rect(fn)
  local original = renderer.draw_rect
  local calls = {}
  renderer.draw_rect = function(x, y, w, h, color)
    calls[#calls + 1] = {
      x = x,
      y = y,
      w = w,
      h = h,
      color = color
    }
  end

  local ok, err = pcall(fn, calls)
  renderer.draw_rect = original
  if not ok then error(err, 0) end
end

test.describe("linewrapping", function()
  test.test("draw_line_text keeps final wrapped segment", function()
    local view = make_view("abcdef")
    local font = view:get_font()
    LineWrapping.reconstruct_breaks(view, font, font:get_width("abc"))
    local x, y = view:get_line_screen_position(1)

    with_draw_text(function(calls)
      view:draw_line_text(1, x, y)

      local text = {}
      for _, call in ipairs(calls) do
        text[#text + 1] = call.text
        test.type(call.options, "table")
        test.type(call.options.tab_offset, "number")
      end
      test.equal(table.concat(text), "abcdef")
    end)
  end)

  test.test("position helpers map wrapped rows and document lines", function()
    local view = make_view("abcdef")
    local font = view:get_font()
    LineWrapping.reconstruct_breaks(view, font, font:get_width("ab"))

    local line, col = view:position_from_offset(2)
    test.equal(line, 1)
    test.ok(col > 1)

    local first_offset = view:offset_from_position(1, 1)
    local end_offset = view:offset_from_position(2, 1)
    test.equal(first_offset, 1)
    test.ok(end_offset > first_offset)
  end)

  test.test("screen position resolves columns on wrapped rows", function()
    local view = make_view("abcdef")
    local font = view:get_font()
    LineWrapping.reconstruct_breaks(view, font, font:get_width("ab"))

    local x, y = view:get_content_offset()
    local gw = view:get_gutter_width()
    local lh = view:get_line_height()
    local line, col = view:resolve_screen_position(
      x + gw,
      y + style.padding.y + lh
    )

    test.equal(line, 1)
    test.equal(col, 3)
  end)

  test.test("visible line helpers expose wrapped rows", function()
    local view = make_view("abcdef")
    local font = view:get_font()
    LineWrapping.reconstruct_breaks(view, font, font:get_width("ab"))

    local rows = {}
    for offset, line, col in view:each_visible_line() do
      rows[#rows + 1] = { offset = offset, line = line, col = col }
    end

    test.ok(#rows > 1)
    test.equal(rows[1].offset, 1)
    test.equal(rows[1].line, 1)
    test.equal(rows[1].col, 1)
    test.equal(view:get_line_visual_height(1), #rows * view:get_line_height())
  end)

  test.test("indent guides cover all wrapped visual rows", function()
    local previous = config.plugins.indentguide.enabled
    config.plugins.indentguide.enabled = true

    local view = make_view("  abcdefghij")
    local font = view:get_font()
    LineWrapping.reconstruct_breaks(view, font, font:get_width("  abc"))
    view.indentguide_indents[1] = 2

    local expected_height = (view:offset_from_position(2, 1) - view:offset_from_position(1, 1))
      * view:get_line_height()
    local x, y = view:get_line_screen_position(1)

    with_draw_text(function()
      with_draw_rect(function(calls)
        view:draw_line_text(1, x, y)
        test.ok(#calls > 0)
        test.equal(calls[1].h, expected_height)
      end)
    end)

    config.plugins.indentguide.enabled = previous
  end)

  test.test("color previews use wrapped row coordinates", function()
    dofile("subprojects/plugins/plugins/colorpreview.lua")
    local previous = config.plugins.colorpreview.enabled
    local previous_mode = config.plugins.colorpreview.mode
    config.plugins.colorpreview.enabled = true
    config.plugins.colorpreview.mode = "background"
    config.plugins.indentguide.enabled = false

    local text = "aaaa #ff0000"
    local view = make_view(text)
    local font = view:get_font()
    LineWrapping.reconstruct_breaks(view, font, font:get_width("aaaa "))

    local color_col = text:find("#ff0000", 1, true)
    local _, expected_y = view:get_line_screen_position(1, color_col)
    local x, y = view:get_line_screen_position(1)

    with_draw_text(function()
      with_draw_rect(function(calls)
        view:draw_line_text(1, x, y)

        local found = false
        for _, call in ipairs(calls) do
          if call.y == expected_y and call.h == view:get_line_height() then
            found = true
            break
          end
        end
        test.ok(found)
      end)
    end)

    config.plugins.colorpreview.enabled = previous
    config.plugins.colorpreview.mode = previous_mode
  end)

  test.test("selection highlights use wrapped row coordinates", function()
    dofile("subprojects/plugins/plugins/selectionhighlight.lua")
    if config.plugins.colorpreview then
      config.plugins.colorpreview.enabled = false
    end
    config.plugins.indentguide.enabled = false

    local text = "foo aaaa foo"
    local view = make_view(text)
    view.doc:set_selection(1, 1, 1, 4)

    local font = view:get_font()
    LineWrapping.reconstruct_breaks(view, font, font:get_width("foo aaaa "))

    local match_col = text:find("foo", 5, true)
    local _, expected_y = view:get_line_screen_position(1, match_col)
    local x, y = view:get_line_screen_position(1)

    with_draw_text(function()
      with_draw_rect(function(calls)
        view:draw_line_body(1, x, y)

        local found = false
        for _, call in ipairs(calls) do
          if call.y == expected_y then
            found = true
            break
          end
        end
        test.ok(found)
      end)
    end)
  end)

  test.test("line selections span later wrapped rows", function()
    config.plugins.indentguide.enabled = false

    local view = make_view("abcdefghijkl")
    local font = view:get_font()
    LineWrapping.reconstruct_breaks(view, font, font:get_width("abc"))

    view.doc:set_selection(1, 4, 1, 12)
    local start_row = view:visual_row_from_position(1, 4)
    local end_row = view:visual_row_from_position(1, 12)
    local expected_rows = end_row - start_row + 1
    local x, y = view:get_line_screen_position(1)

    with_draw_text(function()
      with_draw_rect(function(calls)
        view:draw_line_body(1, x, y)

        local selected_rows = {}
        for _, call in ipairs(calls) do
          if call.color == style.selection and call.w > 0 then
            selected_rows[call.y] = true
          end
        end

        local count = 0
        for _ in pairs(selected_rows) do count = count + 1 end
        test.equal(count, expected_rows)
      end)
    end)
  end)

  test.test("search selections keep search colors on wrapped rows", function()
    config.plugins.indentguide.enabled = false

    local text = "aaaa search\n"
    local view = make_view(text)
    local font = view:get_font()
    LineWrapping.reconstruct_breaks(view, font, font:get_width("aaaa "))

    local col1 = text:find("search", 1, true)
    local col2 = col1 + #"search"
    view.doc:set_selection(1, col1, 1, col2)
    view.doc:add_search_selection(1, col1, 1, col2)

    local x, y = view:get_line_screen_position(1)

    with_draw_text(function(text_calls)
      with_draw_rect(function(rect_calls)
        view:draw_line_body(1, x, y)

        local expected_rect_color = style.search_selection or style.caret
        local found_rect = false
        for _, call in ipairs(rect_calls) do
          if call.color == expected_rect_color then
            found_rect = true
            break
          end
        end
        test.ok(found_rect)

        local expected_text_color = style.search_selection_text or style.background
        local found_text = false
        for _, call in ipairs(text_calls) do
          if call.color == expected_text_color then
            found_text = true
            break
          end
        end
        test.ok(found_text)
      end)
    end)
  end)

  test.test("folded hidden lines do not contribute wrapped rows", function()
    local previous_codefold = config.plugins.codefold.enabled
    local previous_hide_tail = config.plugins.codefold.hide_tail_on_fold
    config.plugins.codefold.enabled = true
    config.plugins.codefold.hide_tail_on_fold = false

    local doc = Doc(nil, nil, true)
    doc.lines = {
      "a\n",
      "fold\n",
      "hidden hidden hidden hidden\n",
      "hidden hidden hidden hidden\n",
      "abcdef\n",
    }
    doc.cache.col_x = {}
    doc.cache.ulen = {}
    doc.highlighter:reset()

    local view = DocView(doc)
    view.position.x = 0
    view.position.y = 0
    view.size.x = 320
    view.size.y = 200
    view.cf_regions = { { start = 2, stop = 4 } }
    view.cf_folded_regions = { 1 }
    view.cf_fold_map = { 1, 2, 5 }
    view.cf_unfold_map = { 1, 2, nil, nil, 3 }
    view.cf_first_update = nil
    view.cf_invalidated = nil

    local font = view:get_font()
    LineWrapping.reconstruct_breaks(view, font, font:get_width("ab"))

    local rows = {}
    for offset, line, col in view:each_visible_line() do
      rows[#rows + 1] = { line = line, col = col }
    end

    test.equal(rows[1].line, 1)
    test.equal(rows[2].line, 2)
    local saw_line5 = false
    for _, row in ipairs(rows) do
      test.ok(row.line ~= 3 and row.line ~= 4)
      saw_line5 = saw_line5 or row.line == 5
    end
    test.ok(saw_line5)
    test.ok(view:get_line_visual_height(5) > view:get_line_height())

    config.plugins.codefold.enabled = previous_codefold
    config.plugins.codefold.hide_tail_on_fold = previous_hide_tail
  end)

  test.test("vertical movement uses wrapped rows and skips folded lines", function()
    local previous_codefold = config.plugins.codefold.enabled
    local previous_hide_tail = config.plugins.codefold.hide_tail_on_fold
    config.plugins.codefold.enabled = true
    config.plugins.codefold.hide_tail_on_fold = false

    local doc = Doc(nil, nil, true)
    doc.lines = {
      "f\n",
      "hidden hidden hidden hidden\n",
      "hidden hidden hidden hidden\n",
      "abcdef\n",
      "ghijkl\n",
    }
    doc.cache.col_x = {}
    doc.cache.ulen = {}
    doc.highlighter:reset()

    local view = DocView(doc)
    view.position.x = 0
    view.position.y = 0
    view.size.x = 320
    view.size.y = 200
    view.cf_regions = { { start = 1, stop = 3 } }
    view.cf_folded_regions = { 1 }
    view.cf_fold_map = { 1, 4, 5 }
    view.cf_unfold_map = { 1, nil, nil, 2, 3 }
    view.cf_hidden_lines = { [2] = true, [3] = true }
    view.cf_first_update = nil
    view.cf_invalidated = nil
    view.last_x_offset = { line = 1, col = 1, offset = 0 }

    local font = view:get_font()
    LineWrapping.reconstruct_breaks(view, font, font:get_width("abcd"))

    local translate = require "core.docview".translate
    local line, col = translate.next_line(doc, 1, 1, view)
    test.equal(line, 4)
    test.equal(col, 1)

    line, col = translate.next_line(doc, line, col, view)
    test.equal(line, 4)
    test.ok(col > 1)

    line, col = translate.previous_line(doc, line, col, view)
    test.equal(line, 4)
    test.equal(col, 1)

    line, col = translate.previous_line(doc, line, col, view)
    test.equal(line, 1)
    test.equal(col, 1)

    config.plugins.codefold.enabled = previous_codefold
    config.plugins.codefold.hide_tail_on_fold = previous_hide_tail
  end)
end)
