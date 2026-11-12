local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local core = require "core"
local Doc = require "core.doc"
local DocView = require "core.docview"
local translate = require "core.doc.translate"
local test = require "core.test"

require "plugins.language_lua"

local function check_grapheme_bounds(doc)
  for line = 1, #doc.lines do
    local text = doc:get_utf8_line(line)
    for first, last in utf8extra.grapheme_indices(text) do
      for col = first, last do
        test.same({ doc:get_grapheme_bounds(line, col) }, { first, last + 1 })
      end
    end
  end
end

test.describe("document grapheme positions", function()
  test.test("navigation and deletion keep displayed characters intact", function()
    local clusters = { "☺️", " ", "☹️", " ", "☠️", "e\204\129", "🚀‍🚀", "🇺🇸", "1️⃣" }
    local text = table.concat(clusters)
    local doc = Doc()
    doc:insert(1, 1, text .. "\nend")
    local col = 1
    for _, cluster in ipairs(clusters) do
      local line, next_col = translate.next_char(doc, 1, col)
      test.equal(line, 1)
      test.equal(next_col, col + #cluster)
      local previous_line, previous_col = translate.previous_char(doc, line, next_col)
      test.equal(previous_line, 1)
      test.equal(previous_col, col)
      col = next_col
    end
    test.same({ translate.next_char(doc, 1, col) }, { 2, 1 })
    test.same({ translate.previous_char(doc, 2, 1) }, { 1, col })
    test.same({ translate.previous_char(doc, 1, 1) }, { 1, 1 })
    doc:set_selection(1, col)
    for i = #clusters, 1, -1 do
      doc:delete_to(translate.previous_char)
      test.equal(doc.lines[1], table.concat(clusters, "", 1, i - 1) .. "\n")
    end
    doc:on_close()
  end)

  test.test("cached boundaries agree with the native iterator after edits", function()
    local doc = Doc()
    local text = "ascii ☺️ ☹️  ☠️e\204\129x\204\129  "
      .. string.uchar(0x600) .. "a  क्‍ष각 🇺🇸🇨🇦🇫 z\r\n"
    doc:insert(1, 1, text)
    check_grapheme_bounds(doc)
    doc:insert(1, 1, "x\nchanged ")
    check_grapheme_bounds(doc)
    doc:remove(1, 1, 2, 3)
    check_grapheme_bounds(doc)
    doc:undo()
    check_grapheme_bounds(doc)
    doc:on_close()
  end)

  test.test("updates cached spans when edits join or split neighboring characters", function()
    for _, case in ipairs {
      { "☺ ☠️", 4, "️" },
      { "ab ☺️", 2, "\204\129" },
      { "🚀🚀 ☺️", 5, "‍" },
      { "🚀 ☺️", 5, "🏽" },
      { string.rep("🇺", 24) .. " ☺️", 1, "🇸" },
      { "कष ☺️", 4, "्‍" },
      { "ᄀᆨ ☺️", 4, "ᅡ" },
      { "a ☺️", 1, string.uchar(0x600) },
      { "end\r\n", 5, "x" }
    } do
      local doc = Doc()
      doc:insert(1, 1, case[1])
      doc:clear_undo_redo()
      check_grapheme_bounds(doc)
      local cached = doc.cache.graphemes[1]
      doc:insert(1, case[2], case[3])
      test.equal(doc.cache.graphemes[1], cached)
      test.equal(cached.text, doc.lines[1])
      check_grapheme_bounds(doc)
      doc:remove(1, case[2], 1, case[2] + #case[3])
      test.equal(doc.cache.graphemes[1], cached)
      check_grapheme_bounds(doc)
      doc:undo()
      check_grapheme_bounds(doc)
      doc:redo()
      check_grapheme_bounds(doc)
      doc:on_close()
    end
  end)

  test.test("keeps grapheme caches through tokenization and clears them explicitly", function()
    local doc = Doc()
    doc:insert(1, 1, "☺️ end")
    doc:get_grapheme_bounds(1, 1)
    local cached = doc.cache.graphemes[1]
    doc.cache.col_x, doc.cache.ulen = { [1] = {} }, { [1] = 4 }
    doc.highlighter:get_line(1)
    test.equal(doc.cache.graphemes[1], cached)
    test.is_nil(doc.cache.col_x[1])
    test.is_nil(doc.cache.ulen[1])
    doc:insert(1, 1, "x")
    doc.highlighter:get_line(1)
    test.equal(doc.cache.graphemes[1], cached)
    doc:clear_cache(1, 0)
    test.is_nil(doc.cache.graphemes[1])
    check_grapheme_bounds(doc)
    doc.lines[1] = "☹️ changed\n"
    doc.highlighter:get_line(1)
    test.is_nil(doc.cache.graphemes[1])
    check_grapheme_bounds(doc)
    doc:reset()
    test.is_nil(next(doc.cache.graphemes))
    doc:on_close()
  end)

  test.test("line splits and joins preserve caches for untouched lines", function()
    local doc = Doc()
    doc:insert(1, 1, "☺️ one\n☹️ two\n☠️ three\n⚙️ four")
    check_grapheme_bounds(doc)
    local first, third, fourth = doc.cache.graphemes[1], doc.cache.graphemes[3], doc.cache.graphemes[4]
    doc:insert(2, 7, "\nnew\n")
    test.equal(doc.cache.graphemes[1], first)
    test.equal(doc.cache.graphemes[5], third)
    test.equal(doc.cache.graphemes[6], fourth)
    for line = 2, 4 do test.is_nil(doc.cache.graphemes[line]) end
    check_grapheme_bounds(doc)
    doc:remove(2, 1, 5, 1)
    test.equal(doc.cache.graphemes[1], first)
    test.equal(doc.cache.graphemes[3], fourth)
    test.is_nil(doc.cache.graphemes[2])
    check_grapheme_bounds(doc)
    doc:on_close()
  end)

  test.test("edits on cached long lines segment only the nearby text", function()
    local doc = Doc()
    doc:insert(1, 1, string.rep("x", 100000) .. " ☺️ " .. string.rep("中文", 20000))
    doc:get_grapheme_bounds(1, 100002)
    local cached = doc.cache.graphemes[1]
    local original, walked = utf8extra.grapheme_indices, 0
    utf8extra.grapheme_indices = function(...)
      local iter = original(...)
      return function()
        local first, last = iter()
        if first then walked = walked + last - first + 1 end
        return first, last
      end
    end
    local ok, err = pcall(function()
      for _, col in ipairs { 2, 50000, 100020 } do
        col = doc:get_grapheme_bounds(1, col)
        doc:insert(1, col, "a")
        doc.highlighter:get_line(1)
        doc:get_grapheme_bounds(1, 100002)
        doc:remove(1, col, 1, col + 1)
        test.equal(doc.cache.graphemes[1], cached)
        test.equal(cached.text, doc.lines[1])
      end
      test.ok(walked < 64, "unchanged text was segmented again: " .. walked .. " bytes")
    end)
    utf8extra.grapheme_indices = original
    doc:on_close()
    if not ok then error(err, 0) end
  end)

  test.test("edits to binary documents invalidate the cleaned line cache", function()
    local doc = Doc()
    doc:insert(1, 1, "☺️ text")
    doc.binary, doc.clean_lines = true, {}
    doc:get_grapheme_bounds(1, 1)
    doc:insert(1, 1, "\255")
    test.is_nil(doc.cache.graphemes[1])
    check_grapheme_bounds(doc)
    doc:on_close()
  end)

  test.test("multiple cursors keep the same cache through typing and undo", function()
    local doc = Doc()
    doc:insert(1, 1, "☺️ x ☹️ y")
    doc:clear_undo_redo()
    doc:set_selection(1, 1)
    doc:add_selection(1, 10)
    check_grapheme_bounds(doc)
    local cached = doc.cache.graphemes[1]
    doc:text_input("a")
    test.equal(doc.cache.graphemes[1], cached)
    check_grapheme_bounds(doc)
    doc:undo()
    test.equal(doc.lines[1], "☺️ x ☹️ y\n")
    check_grapheme_bounds(doc)
    doc:redo()
    check_grapheme_bounds(doc)
    doc:on_close()
  end)

  test.test("mixed edits match full native segmentation at every byte", function()
    local pieces = { "a", " ", "\204\129", "☺", "️", "🚀", "‍", "🏽", "🇺", "🇸",
      "क", "्", "ष", "ᄀ", "ᅡ", "ᆨ", string.uchar(0x600), "\r", "\n" }
    local seed = 721
    local function random(n)
      seed = seed * 16807 % 2147483647
      return seed % n + 1
    end
    local function columns(text)
      local cols = {}
      for col in utf8extra.codes(text) do cols[#cols + 1] = col end
      return cols
    end
    local doc = Doc()
    doc:insert(1, 1, table.concat(pieces, "") .. " ☺️")
    doc:clear_undo_redo()
    check_grapheme_bounds(doc)
    for step = 1, 160 do
      local line = random(#doc.lines)
      local cols = columns(doc.lines[line])
      local idx = random(#cols)
      if random(3) == 1 then
        local last_line = math.min(line + random(2) - 1, #doc.lines)
        local last_cols = columns(doc.lines[last_line])
        local last_idx = last_line == line and random(#cols - idx + 1) + idx - 1
          or random(#last_cols)
        doc:remove(line, cols[idx], last_line, last_cols[last_idx])
      else
        doc:insert(line, cols[idx], pieces[random(#pieces)])
      end
      check_grapheme_bounds(doc)
      if step % 13 == 0 then
        doc:undo()
        check_grapheme_bounds(doc)
        doc:redo()
        check_grapheme_bounds(doc)
      end
    end
    doc:on_close()
  end)

  test.test("ASCII navigation does not allocate a grapheme cache", function()
    local doc = Doc()
    doc:insert(1, 1, string.rep("a", 100000))
    test.same({ translate.previous_char(doc, 1, 50000) }, { 1, 49999 })
    test.same({ translate.next_char(doc, 1, 50000) }, { 1, 50001 })
    test.is_nil(doc.cache.graphemes)
    doc:on_close()
  end)
end)

local function track_doc(context, doc)
  context.docs[#context.docs + 1] = doc
  return doc
end

local function perform_new_doc(context)
  test.ok(command.perform("core:new-doc"))
  return context.opened_docs[#context.opened_docs]
end

test.describe("core.doc", function()
  test.before_each(function(context)
    context.old_extension = config.new_file_extension
    context.old_mode = config.new_file_extension_mode
    context.old_active_view = core.active_view
    context.old_last_active_view = core.last_active_view
    context.old_open_doc = core.root_view.open_doc
    context.old_command_enter = core.command_view.enter
    context.docs = {}
    context.opened_docs = {}

    core.root_view.open_doc = function(_, doc)
      context.opened_docs[#context.opened_docs + 1] = track_doc(context, doc)
    end
  end)

  test.after_each(function(context)
    config.new_file_extension = context.old_extension
    config.new_file_extension_mode = context.old_mode
    core.active_view = context.old_active_view
    core.last_active_view = context.old_last_active_view
    core.root_view.open_doc = context.old_open_doc
    core.command_view.enter = context.old_command_enter

    for _, doc in ipairs(context.docs) do
      for i = #core.docs, 1, -1 do
        if core.docs[i] == doc then
          table.remove(core.docs, i)
        end
      end
      doc:on_close()
    end
  end)

  test.test("uses a custom extension without naming the document", function(context)
    config.new_file_extension = ".lua"
    config.new_file_extension_mode = "configured"

    local doc = perform_new_doc(context)

    test.not_nil(doc)
    test.is_nil(doc.filename)
    test.is_nil(doc.abs_filename)
    test.equal(doc.suggested_extension, "lua")
    test.equal(doc:get_name(), "unsaved.lua")
    test.equal(doc.syntax.name, "Lua")
  end)

  test.test("follows the current extension without a configured fallback", function(context)
    local source = Doc(nil, nil, true)
    source:set_filename("source.py", "/source.py")
    core.active_view = { doc = source }
    config.new_file_extension = ""
    config.new_file_extension_mode = "current"

    local doc = perform_new_doc(context)

    test.equal(doc.suggested_extension, "py")
    test.equal(doc:get_name(), "unsaved.py")
  end)

  test.test("leaves new documents unhinted without a usable extension", function(context)
    config.new_file_extension = ""

    config.new_file_extension_mode = "configured"
    test.is_nil(perform_new_doc(context).suggested_extension)

    config.new_file_extension_mode = "current"
    core.active_view = {}
    local doc = perform_new_doc(context)
    test.is_nil(doc.suggested_extension)
    test.equal(doc:get_name(), "unsaved")
  end)

  test.test("follows current extensions and uses the configured fallback", function(context)
    config.new_file_extension = "lua"
    config.new_file_extension_mode = "current"

    local source = Doc(nil, nil, true)
    source:set_filename("src/module.py", "/src/module.py")
    core.active_view = { doc = source }
    test.equal(perform_new_doc(context).suggested_extension, "py")

    local hinted = Doc(nil, nil, true)
    hinted:set_suggested_extension("d.ts")
    core.active_view = { doc = hinted }
    test.equal(perform_new_doc(context).suggested_extension, "d.ts")

    core.active_view = {}
    test.equal(perform_new_doc(context).suggested_extension, "lua")

    local extensionless = Doc(nil, nil, true)
    extensionless:set_filename("Makefile", "/Makefile")
    core.active_view = { doc = extensionless }
    test.equal(perform_new_doc(context).suggested_extension, "lua")
  end)

  test.test("normalizes and rejects suggested extensions", function()
    local doc = Doc(nil, nil, true)

    doc:set_suggested_extension("  .tar.gz  ")
    test.equal(doc.suggested_extension, "tar.gz")
    test.equal(doc:get_name(), "unsaved.tar.gz")

    doc:set_suggested_extension("folder/lua")
    test.is_nil(doc.suggested_extension)
    test.equal(doc:get_name(), "unsaved")

    doc:set_suggested_extension(".")
    test.is_nil(doc.suggested_extension)
  end)

  test.test("suggests the hinted name through Save As", function(context)
    local doc = Doc(nil, nil, true)
    doc:set_suggested_extension("lua")
    local view = DocView(doc)
    local previous = Doc(nil, nil, true)
    previous:set_filename(
      "sub" .. PATHSEP .. "source.txt",
      core.root_project().path .. PATHSEP .. "sub" .. PATHSEP .. "source.txt"
    )
    core.active_view = view
    core.last_active_view = DocView(previous)

    local prompt, options
    core.command_view.enter = function(_, label, opts)
      prompt, options = label, opts
    end

    test.ok(command.perform("doc:save"))
    test.equal(prompt, "Save As")
    test.equal(
      options.text,
      "sub" .. PATHSEP .. "unsaved.lua"
    )
    test.is_nil(doc.filename)
  end)

  test.test("clears the hint when a real filename is assigned", function()
    local doc = Doc(nil, nil, true)
    doc:set_suggested_extension("lua")
    test.equal(doc.syntax.name, "Lua")

    doc:set_filename("notes.txt", "/notes.txt")

    test.is_nil(doc.suggested_extension)
    test.equal(doc:get_name(), "notes.txt")
    test.not_equal(doc.syntax.name, "Lua")
  end)

  test.test("restores extension hints with untitled document state", function(context)
    local doc = Doc(nil, nil, true)
    doc:set_suggested_extension("lua")
    doc:insert(1, 1, "local answer = 42")
    doc:set_selection(1, 7)
    local view = DocView(doc)
    view.scroll.to.x = 12
    view.scroll.to.y = 24

    local state = view:get_state()
    local restored = DocView.from_state(state)
    track_doc(context, restored.doc)

    test.equal(state.suggested_extension, "lua")
    test.equal(restored.doc.suggested_extension, "lua")
    test.equal(restored.doc:get_name(), "unsaved.lua")
    test.equal(restored.doc.syntax.name, "Lua")
    test.equal(restored.doc:get_text(1, 1, math.huge, math.huge), "local answer = 42")
    test.same({ restored.doc:get_selection() }, { 1, 7, 1, 7 })
    test.equal(restored.scroll.to.x, 12)
    test.equal(restored.scroll.to.y, 24)
  end)

  test.test("keeps legacy untitled state unhinted", function(context)
    local restored = DocView.from_state {
      selection = { 1, 1, 1, 1 },
      scroll = { x = 0, y = 0 },
      crlf = false,
      text = "legacy"
    }
    track_doc(context, restored.doc)

    test.is_nil(restored.doc.suggested_extension)
    test.equal(restored.doc:get_name(), "unsaved")
  end)

  test.test("pastes cleaned text/uri-list clipboard data", function(context)
    local doc = track_doc(context, Doc(nil, nil, true))
    local view = DocView(doc)
    core.active_view = view
    core.cursor_clipboard = {}
    core.cursor_clipboard_whole_line = {}

    local uri_list, expected
    if PATHSEP == "\\" then
      uri_list = "file:///C:/tmp/a%20b.txt\r\nfile:///C:/tmp/c.txt\r\n"
      expected = { "C:\\tmp\\a b.txt\n", "C:\\tmp\\c.txt\n" }
    else
      uri_list = "file:///tmp/a%20b.txt\r\nfile:///tmp/c.txt\r\n"
      expected = { "/tmp/a b.txt\n", "/tmp/c.txt\n" }
    end

    system.set_clipboard(uri_list, "text/uri-list")
    test.ok(command.perform("doc:paste"))
    test.equal(doc.lines[1], expected[1])
    test.equal(doc.lines[2], expected[2])
    system.set_clipboard("")
  end)
end)

test.describe("document saving", function()
  test.before_each(function(context)
    context.active_view = core.active_view
    context.last_active_view = core.last_active_view
    context.next_active_view = core.next_active_view
    context.enter = core.command_view.enter
    context.get_views = core.get_views_referencing_doc
    context.path = core.temp_filename(".txt")
    context.save_as_path = core.temp_filename(".txt")
    local file = assert(io.open(context.path, "wb"))
    file:write("original\n")
    file:close()
    context.doc = Doc(context.path, context.path)
    context.doc:insert(1, 1, "edited ")
    core.command_view.enter = function(_, label, options)
      context.prompt, context.options = label, options
    end
  end)

  test.after_each(function(context)
    core.command_view.enter = context.enter
    core.get_views_referencing_doc = context.get_views
    core.active_view = context.active_view
    core.last_active_view = context.last_active_view
    core.next_active_view = context.next_active_view
    context.doc:on_close()
    os.remove(context.path)
    os.remove(context.save_as_path)
  end)

  local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local text = file:read("*a")
    file:close()
    return text
  end

  for _, class in ipairs { DocView, DocView:extend() } do
    for _, option in ipairs {
      { label = "unset" },
      { label = "false", value = false },
      { label = "true", value = true }
    } do
      local name = class == DocView and "DocView" or "derived DocView"
      test.test(name .. " saving with disable_save " .. option.label, function(context)
        local view = class(context.doc)
        view.disable_save = option.value
        core.active_view = view

        if option.value then
          for _, named in ipairs { true, false } do
            if not named then context.doc:set_filename(nil, nil) end
            for _, cmd in ipairs { "doc:save", "doc:save-as" } do
              test.not_ok(command.is_valid(cmd))
              test.not_ok(command.perform(cmd))
              test.is_nil(context.prompt)
              test.equal(core.active_view, view)
              test.equal(read_file(context.path), "original\n")
              test.ok(context.doc:is_dirty())
            end
          end
        else
          test.ok(command.perform("doc:save"))
          test.is_nil(context.prompt)
          test.equal(read_file(context.path), "edited original\n")
          test.not_ok(context.doc:is_dirty())

          test.ok(command.perform("doc:save-as"))
          test.equal(context.prompt, "Save As")
          context.options.submit(context.save_as_path)
          test.equal(read_file(context.save_as_path), "edited original\n")
          test.equal(
            common.normalize_path(context.doc.abs_filename),
            common.normalize_path(context.save_as_path)
          )
        end
      end)
    end
  end

  test.test("disable_save leaves direct document saving available", function(context)
    local view = DocView(context.doc)
    view.disable_save = true
    core.active_view = view
    context.doc:save()
    test.equal(read_file(context.path), "edited original\n")
    test.not_ok(context.doc:is_dirty())
  end)

  test.test("disable_save leaves Save And Close available", function(context)
    local view = DocView(context.doc)
    view.disable_save = true
    core.active_view = view
    core.get_views_referencing_doc = function() return { view } end
    local closed = false
    view:try_close(function() closed = true end)
    test.equal(context.prompt, "Unsaved Changes; Confirm Close")
    test.not_ok(closed)
    context.options.submit("", { text = "Save And Close" })
    test.ok(closed)
    test.equal(read_file(context.path), "edited original\n")
    test.not_ok(context.doc:is_dirty())
  end)
end)
