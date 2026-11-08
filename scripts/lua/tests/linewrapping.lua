local test = require "core.test"
local Doc = require "core.doc"
local DocView = require "core.docview"
local LineWrapping = require "plugins.linewrapping"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
require "plugins.codefold"

local source_path = debug.getinfo(1, "S").source:gsub("^@", "")
local source_root = common.dirname(
  common.dirname(common.dirname(common.dirname(source_path)))
)

local function dofile_from_source(relative_path)
  return dofile(source_root .. PATHSEP .. relative_path)
end

dofile_from_source("subprojects/plugins/plugins/indentguide.lua")

local function make_view_lines(lines)
  local doc = Doc(nil, nil, true)
  doc.lines = lines
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

local function make_view(text)
  return make_view_lines({ text })
end

local function wrapped_rows_for_line(view, line)
  local starts = view:get_line_wraps(line)
  return starts and #starts or 0
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

---Create a wide document view for exercising automatic wrapping widths.
---@param context table Test state retaining documents for cleanup
---@return core.docview view
local function make_width_view(context)
  local view = make_view(("n"):rep(201) .. "\n")
  context.docs[#context.docs + 1] = view.doc
  view.size.x = view:get_gutter_width() + style.expanded_scrollbar_size
    + view:get_font():get_width("n") * 160
  view.wrapping_enabled = true
  return view
end

---Apply a width change and finish its existing resize debounce deterministically.
---@param view core.docview
local function settle_wrap_width(view)
  LineWrapping.update_docview_breaks(view)
  if view.wrapped_pending_width then
    view.wrapped_rebuild_at = system.get_time() - 1
    LineWrapping.update_docview_breaks(view)
  end
end

test.describe("linewrapping widths", function()
  test.before_each(function(context)
    local options = config.plugins.linewrapping
    context.line_limit = config.line_limit
    context.wrap_at_line_limit, context.width_override = options.wrap_at_line_limit, options.width_override
    context.mode, context.guide = options.mode, options.guide
    context.require_tokenization = options.require_tokenization
    context.reconstruct_breaks = LineWrapping.reconstruct_breaks
    context.docs = {}
    config.line_limit = 80
    options.wrap_at_line_limit, options.width_override = true, nil
    options.require_tokenization, options.guide = false, true
  end)

  test.after_each(function(context)
    local options = config.plugins.linewrapping
    config.line_limit = context.line_limit
    options.wrap_at_line_limit, options.width_override = context.wrap_at_line_limit, context.width_override
    options.mode, options.guide = context.mode, context.guide
    options.require_tokenization = context.require_tokenization
    LineWrapping.reconstruct_breaks = context.reconstruct_breaks
    for _, doc in ipairs(context.docs) do doc:on_close() end
  end)

  test.test("automatic wrapping uses the configured limit in letter and word modes", function(context)
    for _, mode in ipairs { "letter", "word" } do
      config.plugins.linewrapping.mode = mode
      for _, columns in ipairs { 80, 40 } do
        config.line_limit = columns
        local view = make_width_view(context)
        settle_wrap_width(view)
        test.near(view.wrapped_settings.width, view:get_font():get_width("n") * columns)
        test.equal(view:get_line_wraps(1)[2], columns + 1)
      end
    end
  end)

  test.test("narrow viewports account for the gutter and scrollbar and stay positive", function(context)
    local view = make_width_view(context)
    view.get_gutter_width = function() return 120, 20 end
    view.v_scrollbar.expanded_size = 30
    local available = view:get_font():get_width("n") * 24
    view.size.x = view:get_gutter_width() + view.v_scrollbar.expanded_size + available
    settle_wrap_width(view)
    test.near(view.wrapped_settings.width, available)
    test.equal(view:get_line_wraps(1)[2], 25)
    view.size.x = 0
    settle_wrap_width(view)
    test.equal(view.wrapped_settings.width, 1)
  end)

  test.test("disabling the limit restores viewport wrapping in an existing view", function(context)
    local view = make_width_view(context)
    settle_wrap_width(view)
    test.equal(view:get_line_wraps(1)[2], 81)
    config.plugins.linewrapping.wrap_at_line_limit = false
    settle_wrap_width(view)
    test.near(view.wrapped_settings.width, view.size.x - view:get_gutter_width()
      - style.expanded_scrollbar_size)
    test.equal(view:get_line_wraps(1)[2], 161)
    config.plugins.linewrapping.wrap_at_line_limit = true
    settle_wrap_width(view)
    test.equal(view:get_line_wraps(1)[2], 81)
  end)

  test.test("custom pixel widths and functions take precedence over automatic limits", function(context)
    local options = config.plugins.linewrapping
    local view = make_width_view(context)
    local width = view:get_font():get_width("n") * 200
    for _, limited in ipairs { true, false } do
      options.wrap_at_line_limit = limited
      options.width_override = width
      settle_wrap_width(view)
      test.equal(view.wrapped_settings.width, width)
      local received
      options.width_override = function(docview)
        received = docview
        return width / 2
      end
      settle_wrap_width(view)
      test.equal(received, view)
      test.equal(view.wrapped_settings.width, width / 2)
      options.width_override = math.huge
      settle_wrap_width(view)
      test.is_nil(view.wrapped_settings)
      test.is_nil(view.wrapped_lines)
    end
  end)

  test.test("existing views rewrap when the column limit or font scale changes", function(context)
    local view = make_width_view(context)
    local font = view:get_font():copy(view:get_font():get_size())
    view.get_font = function() return font end
    settle_wrap_width(view)
    config.line_limit = 40
    settle_wrap_width(view)
    test.equal(view:get_line_wraps(1)[2], 41)
    local size = font:get_size()
    for _, scale in ipairs { 1.25, 2, 1 } do
      font:set_size(size * scale)
      settle_wrap_width(view)
      test.near(view.wrapped_settings.width, font:get_width("n") * 40)
      test.equal(view:get_line_wraps(1)[2], 41)
    end
  end)

  test.test("the wrapping guide follows the same column position as Line Guide", function(context)
    local view = make_width_view(context)
    view.position.x, view.position.y = 37, 19
    view.scroll.x = 7.25
    settle_wrap_width(view)
    local expected_x = view:get_line_screen_position(1)
      + config.line_limit * view:get_font():get_width("n")
    with_draw_rect(function(calls)
      LineWrapping.draw_guide(view)
      test.equal(#calls, 1)
      test.near(calls[1].x, expected_x)
    end)
    local rows = view.wrapped_lines
    config.plugins.linewrapping.guide = false
    with_draw_rect(function(calls)
      LineWrapping.draw_guide(view)
      test.equal(#calls, 0)
    end)
    settle_wrap_width(view)
    test.equal(view.wrapped_lines, rows)
  end)

  test.test("unchanged column widths reuse cached rows even as a wide viewport grows", function(context)
    local view = make_width_view(context)
    settle_wrap_width(view)
    local rows, rebuilds = view.wrapped_lines, 0
    LineWrapping.reconstruct_breaks = function(...)
      rebuilds = rebuilds + 1
      return context.reconstruct_breaks(...)
    end
    view.size.x = view.size.x + 100
    for _ = 1, 100 do LineWrapping.update_docview_breaks(view) end
    test.equal(rebuilds, 0)
    test.equal(view.wrapped_lines, rows)
    test.is_nil(view.wrapped_pending_width)
  end)
end)

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
    dofile_from_source("subprojects/plugins/plugins/colorpreview.lua")
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
    dofile_from_source("subprojects/plugins/plugins/selectionhighlight.lua")
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

  test.test("partial rebuild updates only the edited line span", function()
    local view = make_view_lines({
      "aaaaaa\n",
      "bbbbbb\n",
      "cccccc\n",
    })
    local font = view:get_font()
    LineWrapping.reconstruct_breaks(view, font, font:get_width("bb"))

    local line1_rows = wrapped_rows_for_line(view, 1)
    local line3_rows = wrapped_rows_for_line(view, 3)
    local line3_start = view.wrapped_line_to_idx[3]

    view.doc.lines[2] = "bbbbbbbbbb\n"
    LineWrapping.update_breaks(view, 2, 2, 0)

    test.equal(wrapped_rows_for_line(view, 1), line1_rows)
    test.ok(wrapped_rows_for_line(view, 2) > line1_rows)
    test.equal(wrapped_rows_for_line(view, 3), line3_rows)
    test.ok(view.wrapped_line_to_idx[3] > line3_start)

    local rows = {}
    for i = 1, #view.wrapped_lines, 2 do
      rows[#rows + 1] = view.wrapped_lines[i]
    end
    test.equal(rows[1], 1)
    test.equal(rows[#rows], 3)
  end)

  test.test("partial rebuild handles inserted document lines", function()
    local view = make_view_lines({
      "aaaaaa\n",
      "bbbbbb\n",
      "cccccc\n",
    })
    local font = view:get_font()
    LineWrapping.reconstruct_breaks(view, font, font:get_width("bb"))

    view.doc.lines = {
      "aaaaaa\n",
      "bbbbbb\n",
      "dddddddd\n",
      "cccccc\n",
    }
    LineWrapping.update_breaks(view, 2, 2, 1)

    for line = 1, 4 do
      test.type(view.wrapped_line_to_idx[line], "number")
      test.ok(wrapped_rows_for_line(view, line) > 0)
    end
    test.equal(view.wrapped_lines[#view.wrapped_lines - 1], 4)
  end)

  test.test("partial rebuild handles removed document lines", function()
    local view = make_view_lines({
      "aaaaaa\n",
      "bbbbbb\n",
      "dddddddd\n",
      "cccccc\n",
    })
    local font = view:get_font()
    LineWrapping.reconstruct_breaks(view, font, font:get_width("bb"))

    view.doc.lines = {
      "aaaaaa\n",
      "bbbbbb\n",
      "cccccc\n",
    }
    LineWrapping.update_breaks(view, 2, 3, -1)

    for line = 1, 3 do
      test.type(view.wrapped_line_to_idx[line], "number")
      test.ok(wrapped_rows_for_line(view, line) > 0)
    end
    test.equal(view.wrapped_lines[#view.wrapped_lines - 1], 3)
  end)

  test.test("resize rebuild is delayed until debounce expires", function()
    local previous_width_override = config.plugins.linewrapping.width_override
    local view = make_view_lines({
      "aaaaaaaaaa\n",
      "bbbbbbbbbb\n",
    })
    local font = view:get_font()
    local width1 = font:get_width("aa")
    local width2 = font:get_width("aaaa")
    config.plugins.linewrapping.width_override = width1
    LineWrapping.reconstruct_breaks(view, font, width1)
    view.wrapping_enabled = true

    config.plugins.linewrapping.width_override = width2
    LineWrapping.update_docview_breaks(view)

    test.equal(view.wrapped_settings.width, width1)
    test.equal(view.wrapped_pending_width, width2)

    view.wrapped_rebuild_at = system.get_time() - 1
    LineWrapping.update_docview_breaks(view)

    test.equal(view.wrapped_settings.width, width2)
    test.equal(view.wrapped_pending_width, nil)

    config.plugins.linewrapping.width_override = previous_width_override
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

  test.test("vertical movement stays within each target wrapped row", function()
    local previous_mode = config.plugins.linewrapping.mode
    config.plugins.linewrapping.mode = "word"

    local view = make_view(
      "short words followed by substantiallylongerwords and more short words\n"
    )
    local font = view:get_font()
    local width = font:get_width("short words")
    LineWrapping.reconstruct_breaks(view, font, width)

    local count = view:visual_line_count()
    test.ok(count > 2)
    local line = view:visual_position_from_row(1)
    local col = view:get_visual_line_col_from_x(1, width * 2)
    test.equal(view:visual_row_from_position(line, col), 1)

    view.last_x_offset = {}
    for expected_row = 2, count do
      line, col = DocView.translate.next_line(view.doc, line, col, view)
      test.equal(view:visual_row_from_position(line, col), expected_row)
    end

    for expected_row = count - 1, 1, -1 do
      line, col = DocView.translate.previous_line(view.doc, line, col, view)
      test.equal(view:visual_row_from_position(line, col), expected_row)
    end

    config.plugins.linewrapping.mode = previous_mode
  end)
end)

test.describe("word wrapping", function()
  test.before_each(function(c)
    local options = config.plugins.linewrapping
    c.mode, c.indent = options.mode, options.indent
    c.require_tokenization = options.require_tokenization
    c.keyword_font = style.syntax_fonts.keyword
    c.docs = {}
    options.mode = "word"
  end)

  test.after_each(function(c)
    local options = config.plugins.linewrapping
    options.mode, options.indent = c.mode, c.indent
    options.require_tokenization = c.require_tokenization
    style.syntax_fonts.keyword = c.keyword_font
    for _, doc in ipairs(c.docs) do doc:on_close() end
  end)

  test.test("long words do not leave indentation on its own visual row", function(c)
    local options = config.plugins.linewrapping
    for _, tokenized in ipairs { false, true } do
      options.require_tokenization = tokenized
      for _, indent in ipairs { false, true } do
        options.indent = indent
        for _, prefix in ipairs { " ", "  ", "\t", " \t", (" "):rep(16), ("\t"):rep(4) } do
          local text = prefix .. ("longword"):rep(4) .. "\n"
          local view = make_view(text)
          c.docs[#c.docs + 1] = view.doc
          local font = view:get_font()
          LineWrapping.reconstruct_breaks(view, font, font:get_width("longword"))
          local starts = view:get_line_wraps(1)
          test.ok(#starts > 1, "long words still fall back to character wrapping")
          test.equal(starts[1], 1)
          test.ok(text:sub(1, starts[2] - 1):find("%S"),
            string.format("indentation-only row for prefix %q, indent=%s, tokenized=%s",
              prefix, tostring(indent), tostring(tokenized)))
        end
      end
    end
  end)

  test.test("whitespace-only lines stay on one visual row", function(c)
    local options = config.plugins.linewrapping
    for _, tokenized in ipairs { false, true } do
      options.require_tokenization = tokenized
      for _, indent in ipairs { false, true } do
        options.indent = indent
        local view = make_view("\t    \t\n")
        c.docs[#c.docs + 1] = view.doc
        local font = view:get_font()
        LineWrapping.reconstruct_breaks(view, font, font:get_width("xx"))
        test.same(view:get_line_wraps(1), { 1 })
      end
    end
  end)

  test.test("oversized words fill the current row after any prefix", function(c)
    local options = config.plugins.linewrapping
    for _, tokenized in ipairs { false, true } do
      options.require_tokenization = tokenized
      for _, indent in ipairs { false, true } do
        options.indent = indent
        for _, prefix in ipairs { "", "- ", "* ", "> ", "1. ", "label: ", "arbitrary text ", "é ", "  - ", "\t- " } do
          local text = prefix .. ("x"):rep(64) .. "\n"
          local view = make_view(text)
          c.docs[#c.docs + 1] = view.doc
          local font = view:get_font()
          local _, indent_size = view.doc:get_indent_info()
          font:set_tab_size(indent_size)
          local starts = LineWrapping.compute_line_breaks(
            view.doc, font, 1, font:get_width(prefix .. "xxxxx"), "word"
          )
          test.ok(starts[2] > #prefix + 1,
            string.format("prefix-only row for %q, indent=%s, tokenized=%s",
              prefix, tostring(indent), tostring(tokenized)))
          test.equal(view.doc.lines[1], text)
        end
      end
    end
  end)

  test.test("words that fit the next row still wrap after their prefix", function(c)
    local options = config.plugins.linewrapping
    for _, tokenized in ipairs { false, true } do
      options.require_tokenization = tokenized
      for _, prefix in ipairs { "- ", "label: " } do
        local view = make_view(prefix .. "xxxxxxxxx\n")
        c.docs[#c.docs + 1] = view.doc
        local font = view:get_font()
        local starts = LineWrapping.compute_line_breaks(
          view.doc, font, 1, font:get_width("xxxxxxxxxx"), "word"
        )
        test.same(starts, { 1, #prefix + 1 })
      end
    end
  end)

  test.test("oversized word detection includes fonts in subsequent syntax tokens", function(c)
    config.plugins.linewrapping.require_tokenization = true
    local text = "-- xxxxxxxxYY\n"
    local view = make_view(text)
    c.docs[#c.docs + 1] = view.doc
    local font = view:get_font()
    style.syntax_fonts.keyword = font:copy(font:get_size() * 2)
    view.doc.highlighter.lines[1] = {
      first_line = true,
      text = text,
      tokens = { "normal", "-- xxxxxxxx", "keyword", "YY", "normal", "\n" }
    }
    local starts = LineWrapping.compute_line_breaks(
      view.doc, font, 1, font:get_width("xxxxxxxxxx"), "word"
    )
    test.ok(starts[2] > 4, "the entire styled word cannot fit after the prefix")
  end)

  test.test("spaces after words remain valid wrapping boundaries", function(c)
    local options = config.plugins.linewrapping
    options.indent = true
    for _, tokenized in ipairs { false, true } do
      options.require_tokenization = tokenized
      local view = make_view("  one two three\n")
      c.docs[#c.docs + 1] = view.doc
      local font = view:get_font()
      local starts = LineWrapping.compute_line_breaks(
        view.doc, font, 1, font:get_width("  one two "), "word"
      )
      test.same(starts, { 1, 11 })
    end
  end)

  test.test("letter wrapping retains its character boundaries", function(c)
    local options = config.plugins.linewrapping
    options.indent, options.require_tokenization = false, false
    local view = make_view("    abcdef\n")
    c.docs[#c.docs + 1] = view.doc
    local font = view:get_font()
    local starts = LineWrapping.compute_line_breaks(
      view.doc, font, 1, font:get_width("abc"), "letter"
    )
    test.same(starts, { 1, 4, 7, 10 })
  end)
end)
