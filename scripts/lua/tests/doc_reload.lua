local test = require "core.test"
local core = require "core"
local config = require "core.config"
local Doc = require "core.doc"
local DocView = require "core.docview"
local LineWrapping = require "plugins.linewrapping"
local codefold = require "plugins.codefold"

local function write_file(path, text)
  local file = assert(io.open(path, "wb"))
  assert(file:write(text))
  file:close()
end

local function open_view(context, text)
  write_file(context.path, text)
  local doc = Doc(context.path, context.path)
  context.doc = doc
  local view = DocView(doc)
  view.size.x, view.size.y = 600, 400
  context.views[#context.views + 1] = view
  return view, doc
end

local function finish_scan(view)
  view:update()
  local id = view.cf_thread_id
  test.not_nil(id)
  local thread = core.threads[id]
  while coroutine.status(thread.cr) ~= "dead" do
    local ok, err = coroutine.resume(thread.cr)
    test.ok(ok, err)
  end
  core.threads[id] = nil
end

test.describe("document reload", function()
  test.before_each(function(context)
    context.path = core.temp_filename(".txt")
    context.views = {}
    context.get_views = core.get_views_referencing_doc
    context.threads = {}
    for id in pairs(core.threads) do context.threads[id] = true end
    context.fold_enabled = config.plugins.codefold.enabled
    context.wrap_default = config.plugins.linewrapping.enable_by_default
    config.plugins.codefold.enabled = false
    config.plugins.linewrapping.enable_by_default = false
    core.get_views_referencing_doc = function(doc)
      return doc == context.doc and context.views or context.get_views(doc)
    end
  end)

  test.after_each(function(context)
    if context.doc then
      os.remove(codefold._test.state_path_for_doc(context.doc))
      context.doc:on_close()
    end
    core.get_views_referencing_doc = context.get_views
    config.plugins.codefold.enabled = context.fold_enabled
    config.plugins.linewrapping.enable_by_default = context.wrap_default
    for id in pairs(core.threads) do
      if not context.threads[id] then core.threads[id] = nil end
    end
    os.remove(context.path)
  end)

  test.test("growing and shrinking clean files refresh every view", function(context)
    local view, doc = open_view(context, string.rep("old\n", 143))
    local split = DocView(doc)
    split.size.x, split.size.y = 600, 400
    context.views[#context.views + 1] = split
    doc:set_selection(127, 1)
    view:update()
    split:update()
    test.equal(view:visual_line_count(), 143)
    test.equal(split:visual_line_count(), 143)

    for _, count in ipairs { 200, 130, 180 } do
      write_file(context.path, string.rep("new\n", count))
      doc:reload()
      test.equal(#doc.lines, count)
      test.not_ok(doc:is_dirty())
      for _, current in ipairs(context.views) do
        current:update()
        test.equal(current:visual_line_count(), count)
        test.equal(current:visual_position_from_row(count), count)
        current.scroll.y = (126 * current:get_line_height())
        local _, last = current:get_visible_line_range()
        test.ok(last > 143 or count == 130)
      end
    end
  end)

  test.test("reload gets a fresh change id and clears text metrics", function(context)
    local _, doc = open_view(context, "old\n")
    local old_id = doc:get_change_id()
    doc.cache.col_x[1] = { [2] = 999 }
    doc.cache.ulen[1] = 999
    write_file(context.path, "new\n")
    doc:reload()
    test.not_equal(doc:get_change_id(), old_id)
    test.is_nil(doc.cache.col_x[1])
    test.is_nil(doc.cache.ulen[1])
    test.not_ok(doc:is_dirty())

    doc:insert(1, 1, "edited")
    local edited_id = doc:get_change_id()
    doc:undo()
    doc:reload()
    test.ok(doc:get_change_id() > edited_id)
    test.not_ok(doc:is_dirty())
    doc:clear_undo_redo()
    test.not_ok(doc:is_dirty())
    doc:insert(1, 1, "edit")
    test.ok(doc:is_dirty())
    doc:undo()
    test.not_ok(doc:is_dirty())
    doc:redo()
    test.ok(doc:is_dirty())
  end)

  test.test("load and reset refresh layout even before the next update", function(context)
    local view, doc = open_view(context, "one\ntwo\n")
    test.equal(view:visual_line_count(), 2)
    write_file(context.path, "one\ntwo\nthree\n")
    doc:load(context.path)
    test.equal(view:visual_line_count(), 3)
    doc:reset()
    test.equal(view:visual_line_count(), 1)
  end)

  test.test("reload rebuilds materialized rows above the caret", function(context)
    local view, doc = open_view(context, "wrapped\nsecond\nthird\n")
    view.get_line_wraps = function(_, line)
      return #doc.lines[line] > 5 and { 1, 5 } or nil
    end
    doc:set_selection(3, 1)
    view:update()
    test.equal(view:visual_rows_for_line(2), 3)
    write_file(context.path, "one\ntwo\nthree\n")
    doc:reload()
    view:update()
    test.equal(view:visual_rows_for_line(2), 2)
    test.equal(view:visual_position_from_row(2), 2)
  end)

  test.test("reload refreshes wraps without resizing either split view", function(context)
    local view, doc = open_view(context, "short\nlast\n")
    local split = DocView(doc)
    split.size.x, split.size.y = 300, 400
    context.views[#context.views + 1] = split
    for _, current in ipairs(context.views) do
      current.wrapping_enabled = true
      LineWrapping.update_docview_breaks(current)
      current:get_visual_lines()
    end
    for _, text in ipairs { string.rep("word ", 100) .. "\nlast\n", "a\nb\n" } do
      write_file(context.path, text)
      doc:reload()
      for _, current in ipairs(context.views) do
        local expected = LineWrapping.compute_line_breaks(
          doc, current:get_font(), 1, current.wrapped_settings.width,
          config.plugins.linewrapping.mode
        )
        test.same(current:get_line_wraps(1), expected)
        local _, rows = current:visual_rows_for_line(1)
        test.equal(rows, #expected)
      end
    end
  end)

  test.test("reload discards stale folds before drawing and rescans the whole file", function(context)
    local view, doc = open_view(context, "head\n  child\nend\n")
    config.plugins.codefold.enabled = true
    finish_scan(view)
    view.cf_folded_regions = { 1 }
    view.cf_mapping_dirty = true
    view.cf_state_loaded = true
    -- Materialize the same hidden mapping used by the drawing path.
    view.cf_hidden_lines = { [2] = true }
    view:invalidate_visual_lines()
    test.not_ok(view:is_line_visible(2))

    local id = "reload-stale-fold-scan"
    local stale_ran = false
    core.threads[id] = { cr = coroutine.create(function() stale_ran = true end) }
    view.cf_thread_id = id
    view.cf_invalidated_from = 3
    write_file(context.path, "prefix\nhead\n  child\nend\n")
    doc:reload()
    test.ok(view:is_line_visible(2))
    test.ok(coroutine.resume(core.threads[id].cr))
    test.not_ok(stale_ran)
    finish_scan(view)
    test.equal(view.cf_regions[1].start, 2)
    test.equal(view.cf_regions[1].stop, 3)
    test.same(view.cf_folded_regions, { 1 })
    test.ok(view:is_line_visible(2))
    test.not_ok(view:is_line_visible(3))

    write_file(context.path, "plain\ntext\nonly\n")
    doc:reload()
    test.equal(view:visual_line_count(), 3)
    finish_scan(view)
    test.same(view.cf_regions, {})
    test.same(view.cf_folded_regions, {})
  end)

  test.test("consecutive reloads preserve independent split fold states", function(context)
    local view, doc = open_view(context, "head\n  child\nend\n")
    local split = DocView(doc)
    split.size.x, split.size.y = 300, 400
    context.views[#context.views + 1] = split
    config.plugins.codefold.enabled = true
    finish_scan(view)
    finish_scan(split)
    view.cf_folded_regions = { 1 }
    view:invalidate_visual_lines()
    test.not_ok(view:is_line_visible(2))
    test.ok(split:is_line_visible(2))
    split.wrapping_enabled = true
    LineWrapping.update_docview_breaks(split)

    -- Reload again before the first replacement scan has finished.
    write_file(context.path, "prefix\nhead\n  child\nend\n")
    doc:reload()
    view:update()
    write_file(context.path, "prefix\nmore\nhead\n  child\nend\n")
    doc:reload()
    finish_scan(view)
    finish_scan(split)
    test.equal(view.cf_regions[1].start, 3)
    test.equal(view.cf_regions[1].stop, 4)
    test.same(view.cf_folded_regions, { 1 })
    test.same(split.cf_folded_regions, {})
    test.not_ok(view:is_line_visible(4))
    test.ok(split:is_line_visible(4))
    test.equal(view:visual_line_count(), 4)
    test.equal(split:visual_line_count(), 5)
  end)
end)
