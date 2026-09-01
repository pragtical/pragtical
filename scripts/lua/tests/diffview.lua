local test = require "core.test"
local core = require "core"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local LineWrapping = require "plugins.linewrapping"
local DiffView = require "plugins.diffview"

local function set_diff(view, a_gaps, b_gaps, a_changes, b_changes)
  view.a_gaps = a_gaps
  view.b_gaps = b_gaps
  view.a_changes = a_changes
  view.b_changes = b_changes
  view.diff_layout_generation = view.diff_layout_generation + 1
  view.aligned_layout = nil
end

local function configure_view(view, width, height)
  view.position.x = 0
  view.position.y = 0
  view.size.x = width or 800
  view.size.y = height or 160

  view.doc_view_a.position.x = 0
  view.doc_view_a.position.y = 0
  view.doc_view_a.size.x = (width or 800) / 2 - 40
  view.doc_view_a.size.y = height or 160

  view.doc_view_b.position.x = (width or 800) / 2 + 40
  view.doc_view_b.position.y = 0
  view.doc_view_b.size.x = (width or 800) / 2 - 40
  view.doc_view_b.size.y = height or 160

  for _, child in ipairs { view.doc_view_a, view.doc_view_b } do
    child.indentguide_indents = {}
    child.indentguide_indent_active = {}
  end

  LineWrapping.set_enabled(view.doc_view_a, false)
  LineWrapping.set_enabled(view.doc_view_b, false)
end

local function make_aligned_diff(height)
  local a = "abcdefghijklmnop\nonly on a\ntail"
  local b = "abcd\ntail"
  local view = DiffView.string_to_string(a, b, "a", "b", true)
  configure_view(view, 800, height)
  set_diff(
    view,
    { {0, 0}, {0, 0}, {0, 0} },
    { {0, 0}, {1, 1} },
    {
      { tag = "modify" },
      { tag = "delete" },
      { tag = "equal" },
    },
    {
      { tag = "modify" },
      { tag = "equal" },
    }
  )
  config.plugins.linewrapping.width_override = view.doc_view_a:get_font():get_width("abcd")
  LineWrapping.set_enabled(view.doc_view_a, true)
  LineWrapping.set_enabled(view.doc_view_b, true)
  return view
end

local function with_renderer_calls(fn)
  local old_rect = renderer.draw_rect
  local old_text = renderer.draw_text
  local old_defer = core.root_view.defer_draw
  local rects, texts = {}, {}
  renderer.draw_rect = function(x, y, w, h, color)
    rects[#rects + 1] = { x = x, y = y, w = w, h = h, color = color }
  end
  renderer.draw_text = function(font, text, x, y, color, options)
    texts[#texts + 1] = {
      font = font, text = text, x = x, y = y, color = color, options = options
    }
    return x + font:get_width(text, options)
  end
  core.root_view.defer_draw = function() end

  local ok, err = pcall(fn, rects, texts)
  renderer.draw_rect = old_rect
  renderer.draw_text = old_text
  core.root_view.defer_draw = old_defer
  if not ok then error(err, 0) end
end

test.describe("diffview line wrapping", function()
  test.before_each(function(context)
    context.previous_active_view = core.active_view
    context.previous_cwd = system.getcwd()
    context.previous_width_override = config.plugins.linewrapping.width_override
    context.previous_scroll_past_end = config.scroll_past_end
    context.previous_plain_text = config.plugins.diffview.plain_text
    config.plugins.diffview.plain_text = false
  end)

  test.after_each(function(context)
    config.plugins.linewrapping.width_override = context.previous_width_override
    config.scroll_past_end = context.previous_scroll_past_end
    config.plugins.diffview.plain_text = context.previous_plain_text
    if context.previous_active_view then
      core.set_active_view(context.previous_active_view)
    end
    system.chdir(context.previous_cwd)
  end)

  test.test("F10 behavior toggles both panes from either side", function()
    local view = make_aligned_diff()
    LineWrapping.set_enabled(view.doc_view_a, false)
    LineWrapping.set_enabled(view.doc_view_b, false)

    core.set_active_view(view.doc_view_a)
    test.ok(keymap.on_key_pressed("f10"))
    test.not_nil(view.doc_view_a.wrapped_settings)
    test.not_nil(view.doc_view_b.wrapped_settings)

    core.set_active_view(view.doc_view_b)
    test.ok(keymap.on_key_pressed("f10"))
    test.is_nil(view.doc_view_a.wrapped_settings)
    test.is_nil(view.doc_view_b.wrapped_settings)

    LineWrapping.set_enabled(view.doc_view_a, true)
    LineWrapping.set_enabled(view.doc_view_b, false)
    core.set_active_view(view.doc_view_a)
    test.ok(keymap.on_key_pressed("f10"))
    test.not_nil(view.doc_view_a.wrapped_settings)
    test.not_nil(view.doc_view_b.wrapped_settings)
  end)

  test.test("aligned slots keep following lines level without overlap", function()
    local view = make_aligned_diff()
    local a, b = view.doc_view_a, view.doc_view_b
    local layout = view:get_aligned_layout()
    test.ok(layout.a.row_counts[1] > layout.b.row_counts[1])

    local _, ay = a:get_line_screen_position(3)
    local _, by = b:get_line_screen_position(2)
    test.equal(ay, by)

    local _, first_y = a:get_line_screen_position(1)
    local _, deleted_y = a:get_line_screen_position(2)
    test.ok(deleted_y >= first_y + a:get_line_visual_height(1))
    test.ok(ay >= deleted_y + a:get_line_visual_height(2))
  end)

  test.test("wrapped-row hit testing and visible ranges use aligned rows", function()
    local view = make_aligned_diff(40)
    local a, b = view.doc_view_a, view.doc_view_b
    local target_col = 7
    local x, y = a:get_line_screen_position(1, target_col)
    local line, col = a:resolve_screen_position(
      x + a:get_font():get_width("a") / 4,
      y + a:get_line_height() / 2
    )
    test.equal(line, 1)
    test.equal(
      a:visual_row_from_position(line, col),
      a:visual_row_from_position(1, target_col)
    )

    local layout = view:get_aligned_layout()
    local tail_row = layout.a.starts[3]
    a.scroll.y = tail_row * layout.line_height + style.padding.y
    b.scroll.y = a.scroll.y
    local a_first = a:get_visible_line_range()
    local b_first = b:get_visible_line_range()
    test.equal(a:visual_position_from_row(a_first), 3)
    test.equal(b:visual_position_from_row(b_first), 2)
  end)

  test.test("all scrollable extents share the aligned visual height", function()
    local view = make_aligned_diff(60)
    for _, scroll_past_end in ipairs { false, true } do
      config.scroll_past_end = scroll_past_end
      local parent_size = view:get_scrollable_size()
      test.equal(view.doc_view_a:get_scrollable_size(), parent_size)
      test.equal(view.doc_view_b:get_scrollable_size(), parent_size)
    end

    core.set_active_view(view.doc_view_a)
    view.doc_view_a.scroll.y = 10
    view.doc_view_a.scroll.to.y = 10
    view.doc_view_b.scroll.y = 0
    view.doc_view_b.scroll.to.y = 0
    view:update()
    test.equal(view.scroll.y, view.doc_view_a.scroll.y)
    test.equal(view.doc_view_b.scroll.y, view.doc_view_a.scroll.y)

    core.set_active_view(view)
    view:on_mouse_wheel(-1, 0)
    view:update()
    test.equal(view.doc_view_a.scroll.y, view.scroll.y)
    test.equal(view.doc_view_b.scroll.y, view.scroll.y)
  end)

  test.test("change bands and inline changes follow wrapped rows", function()
    local view = make_aligned_diff()
    local a = view.doc_view_a
    local changes = {}
    for char in ("abcde"):gmatch(".") do
      changes[#changes + 1] = { tag = "equal", val = char }
    end
    changes[#changes + 1] = { tag = "insert", val = "f" }
    view.a_changes[1] = { tag = "modify", changes = changes }

    local x, y = a:get_line_screen_position(1)
    local _, inline_y = a:get_line_screen_position(1, 6)
    with_renderer_calls(function(rects)
      a:draw_line_text(1, x, y)
      local background, inline
      for _, call in ipairs(rects) do
        if call.color == style.diff_delete_background then background = call end
        if call.color == style.diff_delete_inline then inline = call end
      end
      test.not_nil(background)
      test.equal(background.y, y)
      test.equal(background.h, a:get_line_visual_height(1))
      test.not_nil(inline)
      test.equal(inline.y, inline_y)
      test.equal(inline.h, a:get_line_height())
    end)
  end)

  test.test("sync arrows and scrollbar markers use aligned positions", function()
    local view = make_aligned_diff(60)
    local a = view.doc_view_a
    view.a_changes = {
      { tag = "equal" },
      { tag = "equal" },
      { tag = "modify" },
    }
    view.b_changes = { { tag = "equal" }, { tag = "equal" } }

    local old_defer = core.root_view.defer_draw
    local old_push = core.push_clip_rect
    local old_pop = core.pop_clip_rect
    core.root_view.defer_draw = function(_, fn) fn() end
    core.push_clip_rect = function() end
    core.pop_clip_rect = function() end
    local ok, err = pcall(function()
      local x, y = a:get_line_screen_position(3)
      with_renderer_calls(function(_, texts)
        core.root_view.defer_draw = function(_, fn) fn() end
        a:draw_line_text(3, x, y)
        local arrow
        for _, call in ipairs(texts) do
          if call.text == ">" then arrow = call end
        end
        test.not_nil(arrow)
        local expected_y = y + a:get_line_height() / 2
          - style.icon_font:get_height() / 2
        test.equal(arrow.y, expected_y)
      end)
    end)
    core.root_view.defer_draw = old_defer
    core.push_clip_rect = old_push
    core.pop_clip_rect = old_pop
    if not ok then error(err, 0) end

    view:update_scrollbar()
    a:update_scrollbar()
    view.doc_view_b:update_scrollbar()
    local layout = view:get_aligned_layout()
    local _, track_y, _, track_h = a.v_scrollbar:get_track_rect()
    local scrollable = a:get_scrollable_size()
    local start_y = style.padding.y + layout.a.starts[3] * layout.line_height
    local expected_marker_y = track_y
      + math.min(1, start_y / math.max(1, scrollable)) * track_h
    with_renderer_calls(function(rects)
      view:draw_scrollbar()
      local found = false
      for _, call in ipairs(rects) do
        if call.color == style.diff_modify
          and math.abs(call.y - expected_marker_y) < 0.001
        then
          found = true
          break
        end
      end
      test.ok(found)
    end)
  end)

  test.test("layout cache tracks visual models and gap replacements", function()
    local view = make_aligned_diff()
    local first = view:get_aligned_layout()
    test.equal(view:get_aligned_layout(), first)

    config.plugins.linewrapping.width_override = view.doc_view_a:get_font():get_width("ab")
    LineWrapping.reconstruct_breaks(
      view.doc_view_a,
      view.doc_view_a:get_font(),
      config.plugins.linewrapping.width_override
    )
    local second = view:get_aligned_layout()
    test.ok(second ~= first)
    test.ok(second.total_rows > first.total_rows)

    view.a_gaps = { {0, 0}, {1, 1}, {1, 1} }
    local third = view:get_aligned_layout()
    test.ok(third ~= second)
  end)

  test.test("wrapping is shared by file and mixed comparison modes", function()
    local path = USERDIR .. PATHSEP .. "diffview-wrapping-"
      .. system.get_process_id() .. ".txt"
    local file, err = io.open(path, "wb")
    test.not_nil(file, err)
    local text = "abcdefghijklmnop\ntail"
    file:write(text)
    file:close()

    local ok, run_err = pcall(function()
      local views = {
        DiffView.file_to_file(path, path, true),
        DiffView.file_to_string(path, text, "string", true),
        DiffView.string_to_file(text, path, "string", true),
      }
      for _, view in ipairs(views) do
        configure_view(view, 800, 80)
        config.plugins.linewrapping.width_override =
          view.doc_view_a:get_font():get_width("abcd")
        core.set_active_view(view.doc_view_b)
        command.perform("line-wrapping:enable")
        test.not_nil(view.doc_view_a.wrapped_settings)
        test.not_nil(view.doc_view_b.wrapped_settings)
        test.ok(view:get_aligned_layout().total_rows > 2)
      end
    end)
    os.remove(path)
    if not ok then error(run_err, 0) end
  end)

  test.test("computed diff gaps preserve wrapped alignment", function()
    local view = DiffView.string_to_string(
      "abcdefghijklmnop\nonly on a\ntail",
      "abcd\ntail",
      "a", "b", true
    )
    configure_view(view, 800, 80)
    config.plugins.linewrapping.width_override =
      view.doc_view_a:get_font():get_width("abcd")
    LineWrapping.set_enabled(view.doc_view_a, true)
    LineWrapping.set_enabled(view.doc_view_b, true)

    while view.updater_idx ~= nil do coroutine.yield(0.01) end

    local _, ay = view.doc_view_a:get_line_screen_position(3)
    local _, by = view.doc_view_b:get_line_screen_position(2)
    test.equal(ay, by)
    test.ok(view:get_aligned_layout().total_rows > 3)
  end)
end)
