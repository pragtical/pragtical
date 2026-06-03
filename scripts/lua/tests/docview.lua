local test = require "core.test"
local core = require "core"
local Doc = require "core.doc"
local DocView = require "core.docview"
local style = require "core.style"

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

local function make_binary_view(raw_text, clean_text)
  local view = make_view(raw_text)
  view.doc.binary = true
  view.doc.clean_lines = { clean_text }
  view.doc.highlighter:reset()
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

local function scan_x_offset_col(view, line, x)
  local line_text = view.doc.lines[line]
  local line_len = #line_text
  local xo, pxo, last_col = 0, 0, 0
  for col in utf8extra.next, line_text do
    pxo = xo
    xo = view:get_col_x_offset(line, col)
    if xo >= x or col >= line_len then
      local w = xo - pxo
      return (xo - x > w / 2) and last_col or col
    end
    last_col = col
  end
  return line_len
end

test.describe("docview", function()
  test.test("ensure_line_visible returns the requested line by default", function()
    local view = make_view("line\n")

    test.equal(view:ensure_line_visible(1), 1)
  end)

  test.test("plain documents use identity visual lines", function()
    local doc = Doc(nil, nil, true)
    doc.lines = {
      "one\n",
      "two\n",
      "three\n"
    }
    doc.cache.col_x = {}
    doc.cache.ulen = {}
    doc.highlighter:reset()

    local view = DocView(doc)
    view:rebuild_visual_lines()

    test.ok(view:get_visual_lines().identity)
    test.equal(view:visual_line_count(), 3)
    test.equal(view:visual_position_from_row(2), 2)
    test.equal(view:visual_row_from_position(3, 1), 3)
    local row, row_count = view:visual_rows_for_line(2)
    test.equal(row, 2)
    test.equal(row_count, 1)
    test.ok(view:is_line_visible(3))
  end)

  test.test("visual line rebuild keeps rows before invalidated line", function()
    local doc = Doc(nil, nil, true)
    doc.lines = {
      "one\n",
      "two\n",
      "three\n",
      "four\n"
    }
    doc.cache.col_x = {}
    doc.cache.ulen = {}
    doc.highlighter:reset()

    local view = DocView(doc)
    view:rebuild_visual_lines()

    local queried = {}
    view.get_line_wraps = function(_, line)
      queried[line] = true
      return nil
    end

    view:invalidate_visual_lines(3)
    view:get_visual_lines()

    test.is_nil(queried[1])
    test.is_nil(queried[2])
    test.ok(queried[3])
    test.ok(queried[4])
  end)

  test.test("vertical movement follows visual rows", function()
    local doc = Doc(nil, nil, true)
    doc.lines = {
      "one\n",
      "two wrapped\n",
      "hidden\n",
      "four\n"
    }
    doc.cache.col_x = {}
    doc.cache.ulen = {}
    doc.highlighter:reset()

    local view = DocView(doc)
    view.position.x = 0
    view.position.y = 0
    view.size.x = 320
    view.size.y = 200
    view.last_x_offset = { line = 1, col = 1, offset = 0 }
    view.get_hidden_lines = function()
      return { [3] = true }
    end
    view.get_line_wraps = function(_, line)
      return line == 2 and { 1, 5 } or nil
    end
    view.get_visual_line_col_from_x = function(_, row)
      local _, col = view:visual_position_from_row(row)
      return col
    end
    view:invalidate_visual_lines()

    local line, col = DocView.translate.next_line(doc, 1, 1, view)
    test.equal(line, 2)
    test.equal(col, 1)

    line, col = DocView.translate.next_line(doc, line, col, view)
    test.equal(line, 2)
    test.equal(col, 5)

    line, col = DocView.translate.next_line(doc, line, col, view)
    test.equal(line, 4)
    test.equal(col, 1)

    line, col = DocView.translate.previous_line(doc, line, col, view)
    test.equal(line, 2)
    test.equal(col, 5)
  end)

  test.test("draw_line_body uses search colors for search selections", function()
    local view = make_view("aaaa search\n")
    local col1 = view.doc.lines[1]:find("search", 1, true)
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

  test.test("draw skips stale visual rows without backing document lines", function()
    local view = make_view("one\n")
    view.size.y = view:get_line_height() * 2
    view.visual_line_count = function() return 2 end
    view.visual_position_from_row = function(_, row)
      return row
    end

    local invalid_gutter = false
    local invalid_body = false
    view.draw_line_gutter = function(_, line)
      if line == 2 then invalid_gutter = true end
    end
    view.draw_line_body = function(_, line)
      if line == 2 then invalid_body = true end
      return view:get_line_height()
    end

    local push_clip_rect = core.push_clip_rect
    local pop_clip_rect = core.pop_clip_rect
    core.push_clip_rect = function() end
    core.pop_clip_rect = function() end

    local ok, err = pcall(function()
      with_draw_rect(function()
        view:draw()
      end)
    end)
    core.push_clip_rect = push_clip_rect
    core.pop_clip_rect = pop_clip_rect
    if not ok then error(err, 0) end

    test.equal(invalid_gutter, false)
    test.equal(invalid_body, false)
  end)

  test.test("draw_line_text slices long lines to the visible range", function()
    local line = string.rep("var a = 1; ", 2000)
    local view = make_view(line)
    local x, y = view:get_line_screen_position(1)

    with_draw_text(function(calls)
      view:draw_line_text(1, x, y)

      local bytes = 0
      for _, call in ipairs(calls) do
        bytes = bytes + #call.text
      end

      test.ok(bytes > 0)
      test.ok(bytes < #line / 2, string.format("drew too many bytes: %d of %d", bytes, #line))
      test.equal(calls[1].options.tab_offset, calls[1].x - x)
    end)
  end)

  test.test("draw_line_text slices from the correct syntax token", function()
    local first = string.rep("a", 2000)
    local second = string.rep("b", 8000)
    local view = make_view(first .. second)
    view.scroll.x = view:get_font():get_width(string.rep("W", 5000))
    view.doc.highlighter.get_line = function()
      return { tokens = { "keyword", first, "normal", second } }
    end
    local x, y = view:get_line_screen_position(1)

    with_draw_text(function(calls)
      view:draw_line_text(1, x, y)
      test.ok(#calls > 0)
      test.equal(calls[1].text:sub(1, 1), "b")
    end)
  end)

  test.test("draw_line_text slices binary lines using cleaned utf8 text", function()
    local clean = string.rep("a", 2500) .. "TAIL\n"
    local raw = string.rep("\255", 100) .. "\n"
    local view = make_binary_view(raw, clean)
    view.size.x = 480
    local end_x = view:get_col_x_offset(1, #clean + 1)
    view.scroll.x = math.max(0, end_x - view.size.x + view:get_gutter_width())
    local x, y = view:get_line_screen_position(1)

    with_draw_text(function(calls)
      view:draw_line_text(1, x, y)

      local rendered = {}
      for _, call in ipairs(calls) do
        rendered[#rendered + 1] = call.text
      end
      test.ok(table.concat(rendered):find("TAIL", 1, true) ~= nil)
    end)
  end)

  test.test("get_col_x_offset resumes cached long lines at token boundaries", function()
    local first = string.rep("a", 600)
    local second = string.rep("b", 600)
    local view = make_view(first .. second)
    view.doc.highlighter.get_line = function()
      return { tokens = { "keyword", first, "normal", second } }
    end

    local font = view:get_font()
    local first_width = font:get_width(first, { tab_offset = 0 })
    local expected = first_width + font:get_width(second:sub(1, 299), { tab_offset = first_width })
    view.doc.cache.col_x[1] = { [601] = first_width }

    test.equal(view:get_col_x_offset(1, 900), expected)
  end)

  test.test("get_x_offset_col keeps long-line scan behavior", function()
    local line = string.rep("abc def ", 100)
    local view = make_view(line)
    local width = view:get_col_x_offset(1, #line)

    for i = 0, 10 do
      local x = width * (i / 10)
      test.equal(view:get_x_offset_col(1, x), scan_x_offset_col(view, 1, x))
    end
  end)
end)
