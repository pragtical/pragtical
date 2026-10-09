local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local Doc = require "core.doc"
local DocView = require "core.docview"
local test = require "core.test"
local TextBox = require "widget.textbox"
local Widget = require "widget"
local config = require "core.config"

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

test.describe("widget.textbox mouse selection", function()
  test.before_each(function(context)
    context.active_view = core.active_view
    context.last_active_view = core.last_active_view
    context.next_active_view = core.next_active_view
    context.grab = core.root_view.grab
    context.modkeys = keymap.modkeys
    context.transitions = config.transitions
    core.root_view.grab = nil
    keymap.modkeys = {}
    config.transitions = false
    context.root = Widget(nil, false)
    context.root:show()
    context.root:set_position(40, 60)
    context.root:set_size(500, 150)
    context.input = TextBox(context.root, "")
    context.input:set_position(20, 20)
    context.input:set_size(150)
    context.root:update()
  end)

  test.after_each(function(context)
    context.root:hide()
    context.input.textview.doc:on_close()
    core.root_view.grab = context.grab
    keymap.modkeys = context.modkeys
    config.transitions = context.transitions
    core.active_view = context.active_view
    core.last_active_view = context.last_active_view
    core.next_active_view = context.next_active_view
  end)

  local function set_text(context, text)
    context.input:set_text(text)
    context.input.textview.doc:set_selection(1, 1)
    context.input.textview.scroll.x = 0
    context.input.textview.scroll.to.x = 0
    context.input:update()
  end

  local function point(context, col)
    local view = context.input.textview
    local x, y = view:get_line_screen_position(1, col)
    return x, y + view:get_line_height() / 2
  end

  local function press(context, col, clicks)
    local x, y = point(context, col)
    test.ok(context.root:on_mouse_pressed("left", x, y, clicks or 1))
    return x, y
  end

  test.test("the first press focuses and starts a character selection", function(context)
    set_text(context, "one two three")
    local x, y = press(context, 2)
    test.equal(core.active_view, context.input.textview)
    test.equal(context.root.captured_widget, context.input)
    local to_x = point(context, 7)
    core.on_event("mousemoved", to_x, y, to_x - x, 0)
    test.same({ context.input.textview.doc:get_selection() }, { 1, 7, 1, 2 })
    core.on_event("mousereleased", "left", to_x, y)
    test.is_nil(context.input.textview.mouse_selecting)
    test.is_nil(context.root.captured_widget)
    test.equal(core.active_view, context.input.textview)
  end)

  for _, password in ipairs { false, true } do
    test.test("stationary edge dragging scrolls both directions" .. (password and " in a password field" or ""), function(context)
      context.input:set_password_mode(password)
      set_text(context, string.rep("aé界 ", 60))
      local _, y = press(context, 2)
      local view = context.input.textview
      local right = view.position.x + view.size.x + 50
      core.on_event("mousemoved", right, y, 50, 0)
      context.input:update()
      local _, first_col = view.doc:get_selection()
      local first_scroll = view.scroll.x
      for _ = 1, 5 do context.input:update() end
      local _, next_col, _, anchor = view.doc:get_selection()
      test.ok(next_col > first_col)
      test.ok(view.scroll.x > first_scroll)
      test.equal(anchor, 2)
      for _ = 1, 120 do context.input:update() end
      test.equal(select(2, view.doc:get_selection()), #view.doc.lines[1])
      local max_x = math.max(0, view:get_col_x_offset(1, #view.doc.lines[1])
        + 3 * view:get_font():get_width(" ") - view.size.x)
      test.equal(view.scroll.x, max_x)

      local left = view.position.x - 50
      core.on_event("mousemoved", left, y, left - right, 0)
      for _ = 1, 120 do context.input:update() end
      test.same({ view.doc:get_selection() }, { 1, 1, 1, 2 })
      test.equal(view.scroll.x, 0)
      core.on_event("mousereleased", "left", left, y)
      local selection = { view.doc:get_selection() }
      for _ = 1, 4 do context.input:update() end
      test.same({ view.doc:get_selection() }, selection)
      test.is_nil(core.root_view.grab)
    end)
  end

  test.test("Shift-click extends the existing anchor", function(context)
    set_text(context, "one two three")
    local x, y = press(context, 2)
    core.on_event("mousereleased", "left", x, y)
    keymap.modkeys.shift = true
    x, y = press(context, 7)
    test.same({ context.input.textview.doc:get_selection() }, { 1, 7, 1, 2 })
    core.on_event("mousereleased", "left", x, y)
  end)

  test.test("double-click dragging keeps whole-word selection", function(context)
    set_text(context, "one two three")
    local _, y = press(context, 2, 2)
    test.equal(context.input.textview.doc:get_selection_text(), "one")
    local x = point(context, 6)
    core.on_event("mousemoved", x, y, 0, 0)
    test.equal(context.input.textview.doc:get_selection_text(), "one two")
    core.on_event("mousereleased", "left", x, y)
  end)

  test.test("triple-click selects the whole input", function(context)
    set_text(context, "one two three")
    local x, y = press(context, 2, 3)
    test.equal(context.input.textview.doc:get_selection_text(), "one two three")
    core.on_event("mousereleased", "left", x, y)
  end)

  test.test("empty and short inputs do not scroll past their contents", function(context)
    for _, text in ipairs { "", "short" } do
      set_text(context, text)
      local _, y = press(context, 1)
      local x = context.input.position.x + 1000
      core.on_event("mousemoved", x, y, 1000, 0)
      for _ = 1, 10 do context.input:update() end
      test.equal(context.input.textview.scroll.x, 0)
      test.equal(context.input.textview.scroll.to.x, 0)
      test.equal(select(2, context.input.textview.doc:get_selection()), #text + 1)
      core.on_event("mousereleased", "left", x, y)
    end
  end)

  for _, cancel in ipairs { "hide", "deactivate", "focuslost" } do
    test.test(cancel .. " stops edge selection without a release", function(context)
      set_text(context, string.rep("long text ", 60))
      local _, y = press(context, 2)
      core.on_event("mousemoved", context.input.position.x + 300, y, 300, 0)
      context.input:update()
      if cancel == "hide" then context.root:hide()
      elseif cancel == "deactivate" then context.root:swap_active_child()
      else core.on_event("focuslost") end
      local selection = { context.input.textview.doc:get_selection() }
      context.input:update()
      test.same({ context.input.textview.doc:get_selection() }, selection)
      test.is_nil(context.input.textview.mouse_selecting)
      test.is_nil(core.root_view.grab)
    end)
  end

  test.test("keyboard selection still reveals the caret after mouse release", function(context)
    set_text(context, string.rep("long ", 80))
    local x, y = press(context, 1)
    core.on_event("mousereleased", "left", x, y)
    test.ok(command.perform("doc:move-to-end-of-line"))
    context.input:update()
    test.ok(context.input.textview.scroll.x > 0)
    test.ok(command.perform("doc:select-to-previous-char"))
    test.equal(context.input.textview.doc:get_selection_text(), " ")
    test.not_ok(command.perform("doc:save"))
  end)
end)
