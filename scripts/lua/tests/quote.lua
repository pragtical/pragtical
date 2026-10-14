local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local Doc = require "core.doc"
local DocView = require "core.docview"
local test = require "core.test"

require "plugins.quote"

---Create an unsaved document without a selection and make its view active.
---@param context table Test state holding documents to close afterward
---@param text string Document contents
---@return core.doc doc Document used by the quote command
local function document(context, text)
  local doc = Doc(nil, nil, true)
  context.docs[#context.docs + 1] = doc
  doc:insert(1, 1, text)
  doc:set_selection(1, 1)
  core.active_view = DocView(doc)
  return doc
end

test.describe("quote", function()
  test.before_each(function(context)
    context.active, context.last, context.next = core.active_view, core.last_active_view, core.next_active_view
    context.modkeys = keymap.modkeys
    keymap.modkeys = {}
    context.docs = {}
  end)

  test.after_each(function(context)
    core.active_view, core.last_active_view, core.next_active_view = context.active, context.last, context.next
    keymap.modkeys = context.modkeys
    for _, doc in ipairs(context.docs) do doc:on_close() end
  end)

  for _, mode in ipairs {
    { name = "single", delimiter = "'", command = "quote:quote-single" },
    { name = "double", delimiter = '"', command = "quote:quote" }
  } do
    for _, case in ipairs {
      { name = "plain text", text = "plain text",
        single = "'plain text'", double = '"plain text"' },
      { name = "empty text", text = "", single = "''", double = '""' },
      { name = "both quote types and backslashes", text = [[say "it's" \ path]],
        single = [['say "it\'s" \\ path']], double = [["say \"it's\" \\ path"]] },
      { name = "Unicode and non-control bytes", text = "café λ 😀\127",
        single = "'café λ 😀\127'", double = '"café λ 😀\127"' }
    } do
      test.test("uses " .. mode.name .. " quotes for " .. case.name, function(context)
        local doc = document(context, case.text)
        test.ok(command.perform(mode.command))
        test.equal(doc:get_text(1, 1, math.huge, math.huge), case[mode.name])
      end)
    end

    test.test("escapes NUL and every control byte with " .. mode.name .. " quotes", function(context)
      local text, expected = {}, { mode.delimiter }
      local named = { [8] = "\\b", [9] = "\\t", [10] = "\\n", [13] = "\\r" }
      for byte = 0, 31 do
        text[#text + 1] = string.char(byte)
        expected[#expected + 1] = named[byte] or string.format("\\x%02x", byte)
      end
      expected[#expected + 1] = mode.delimiter
      local doc = document(context, table.concat(text))
      test.ok(command.perform(mode.command))
      test.equal(doc:get_text(1, 1, math.huge, math.huge), table.concat(expected))
    end)

    test.test("uses " .. mode.name .. " quotes only on the selected text", function(context)
      local doc = document(context, "before value after")
      doc:set_selection(1, 13, 1, 8)
      test.ok(command.perform(mode.command))
      test.equal(doc:get_text(1, 1, math.huge, math.huge),
        "before " .. mode.delimiter .. "value" .. mode.delimiter .. " after")
    end)

    test.test("uses " .. mode.name .. " quotes for each selection independently", function(context)
      local doc = document(context, "one two three")
      doc:set_selection(1, 4, 1, 1)
      doc:add_selection(1, 8, 1, 5)
      test.ok(command.perform(mode.command))
      test.equal(doc:get_text(1, 1, math.huge, math.huge),
        mode.delimiter .. "one" .. mode.delimiter .. " " .. mode.delimiter .. "two" .. mode.delimiter .. " three")
    end)

    test.test("dispatches the " .. mode.name .. " quote shortcut", function(context)
      local doc = document(context, "value")
      keymap.modkeys[PLATFORM == "Mac OS X" and "cmd" or "ctrl"] = true
      keymap.modkeys.shift = mode.name == "double"
      test.ok(keymap.on_key_pressed("'"))
      test.equal(doc:get_text(1, 1, math.huge, math.huge), mode.delimiter .. "value" .. mode.delimiter)
    end)
  end
end)
