local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local Doc = require "core.doc"
local DocView = require "core.docview"
local test = require "core.test"
local TextBox = require "widget.textbox"

test.describe("widget.textbox saving", function()
  test.before_each(function(context)
    context.active_view = core.active_view
    context.last_active_view = core.last_active_view
    context.next_active_view = core.next_active_view
    context.enter = core.command_view.enter
    context.modkeys = keymap.modkeys
    context.clipboard = system.get_clipboard()
    context.cursor_clipboard = core.cursor_clipboard
    context.cursor_clipboard_whole_line = core.cursor_clipboard_whole_line
    context.path = core.temp_filename(".txt")
    local file = assert(io.open(context.path, "wb"))
    file:write("original\n")
    file:close()
    context.doc = Doc(context.path, context.path)
    context.doc:insert(1, 1, "edited ")
    core.set_active_view(DocView(context.doc))
    core.command_view.enter = function() context.prompted = true end
    keymap.modkeys = { [PLATFORM == "Mac OS X" and "cmd" or "ctrl"] = true }
  end)

  test.after_each(function(context)
    if context.input then
      context.input:hide()
      context.input.textview.doc:on_close()
    end
    core.command_view.enter = context.enter
    keymap.modkeys = context.modkeys
    system.set_clipboard(context.clipboard or "")
    core.cursor_clipboard = context.cursor_clipboard
    core.cursor_clipboard_whole_line = context.cursor_clipboard_whole_line
    core.active_view = context.active_view
    core.last_active_view = context.last_active_view
    core.next_active_view = context.next_active_view
    context.doc:on_close()
    os.remove(context.path)
  end)

  for _, class in ipairs { TextBox, TextBox:extend() } do
    local name = class == TextBox and "standalone TextBox" or "TextBox subclass"
    test.test(name .. " ignores Save and Save As", function(context)
      local input = class(nil, "needle")
      context.input = input
      core.set_active_view(input.textview)
      test.ok(input.textview.disable_save)

      for _, named in ipairs { false, true } do
        if named then input.textview.doc:set_filename(context.path, context.path) end
        for _, save_as in ipairs { false, true } do
          local cmd = save_as and "doc:save-as" or "doc:save"
          keymap.modkeys.shift = save_as
          test.not_ok(keymap.on_key_pressed("s"))
          test.not_ok(command.perform(cmd))
          test.is_nil(context.prompted)
          test.equal(core.active_view, input.textview)
          test.equal(input:get_text(), "needle")
          test.ok(context.doc:is_dirty())
          local file = assert(io.open(context.path, "rb"))
          local text = file:read("*a")
          file:close()
          test.equal(text, "original\n")
        end
      end
    end)
  end

  test.test("protected inputs retain editing, selection, clipboard and undo", function(context)
    local input = TextBox(nil, "")
    context.input = input
    core.set_active_view(input.textview)
    input:on_text_input("needle")
    test.equal(input:get_text(), "needle")
    test.ok(command.perform("doc:undo"))
    test.equal(input:get_text(), "")
    test.ok(command.perform("doc:redo"))
    test.equal(input:get_text(), "needle")
    test.ok(command.perform("doc:select-all"))
    test.equal(input.textview.doc:get_selection_text(), "needle")
    test.ok(command.perform("doc:copy"))
    test.equal(system.get_clipboard(), "needle")
    test.ok(command.perform("doc:cut"))
    test.equal(input:get_text(), "")
    test.ok(command.perform("doc:paste"))
    test.equal(input:get_text(), "needle")
    test.not_ok(command.perform("doc:save"))
    test.not_ok(command.perform("doc:save-as"))
    test.is_nil(context.prompted)
  end)
end)
