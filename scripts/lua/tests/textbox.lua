local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local Doc = require "core.doc"
local DocView = require "core.docview"
local test = require "core.test"
local TextBox = require "widget.textbox"
local Widget = require "widget"
local config = require "core.config"
local RootView = require "core.rootview"
local style = require "core.style"

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

test.describe("widget.textbox clear button", function()
  test.before_each(function(c)
    c.root, c.active, c.last, c.next = core.root_view, core.active_view, core.last_active_view, core.next_active_view
    c.transitions, c.modkeys, c.cursor, c.clip = config.transitions, keymap.modkeys, core.cursor_change_req, core.clip_rect_stack
    c.scale, c.padding, c.font, c.icons = SCALE, style.padding, style.font, style.icon_font
    c.draw_text = renderer.draw_text
    config.transitions, keymap.modkeys = false, {}
    core.root_view = RootView()
    core.root_view.root_node.is_primary_node = true
    core.root_view.size.x, core.root_view.size.y = 900, 650
    c.panel = Widget(nil, false)
    c.panel:show()
    core.root_view.root_node:add_view(c.panel)
    c.inputs = {}
    c.input = TextBox(c.panel, "", "search...", { clearable = true })
    c.inputs[#c.inputs + 1] = c.input
    c.input:set_position(20, 20)
    c.input:set_size(180)
    for _ = 1, 5 do core.root_view:update() end
  end)

  test.after_each(function(c)
    c.panel:destroy()
    for _, input in ipairs(c.inputs) do input.textview.doc:on_close() end
    renderer.draw_text = c.draw_text
    SCALE, style.padding, style.font, style.icon_font = c.scale, c.padding, c.font, c.icons
    config.transitions, keymap.modkeys, core.cursor_change_req, core.clip_rect_stack = c.transitions, c.modkeys, c.cursor, c.clip
    core.root_view, core.active_view, core.last_active_view, core.next_active_view = c.root, c.active, c.last, c.next
  end)

  ---Place the pointer at the clear icon's shared drawing and hit-test center.
  local function clear_point(c)
    core.root_view:update()
    local x, y, w, h = c.input:get_clear_button_bounds()
    test.not_nil(x)
    return x + w / 2, y + h / 2
  end

  ---Send real core events so focus and both capture layers participate.
  local function press(c)
    local x, y = clear_point(c)
    core.on_event("mousemoved", x, y, 0, 0)
    core.on_event("mousepressed", "left", x, y, 1)
    return x, y
  end

  test.it("is opt-in and hides on empty input without changing the text viewport", function(c)
    test.ok(c.input.clearable)
    test.is_nil(c.input:get_clear_button_bounds())
    local width = c.input.textview.size.x
    c.input:set_text("filter")
    test.not_nil(c.input:get_clear_button_bounds())
    test.equal(c.input.textview.size.x, width)
    local plain = TextBox(c.panel, "plain")
    c.inputs[#c.inputs + 1] = plain
    test.not_ok(plain.clearable)
    test.is_nil(plain:get_clear_button_bounds())
    plain:set_clearable(true)
    test.not_nil(plain:get_clear_button_bounds())
    plain:set_clearable(false)
    test.is_nil(plain:get_clear_button_bounds())
    test.equal(plain:get_text(), "plain")
  end)

  for _, password in ipairs { false, true } do
    test.it("clears on release with one callback and keeps focus" .. (password and " in password mode" or ""), function(c)
      c.input:set_password_mode(password)
      c.input:set_text("aé界 text")
      local changes = {}
      function c.input:on_change(value) changes[#changes + 1] = value end
      local x, y = press(c)
      test.equal(c.input:get_text(), "aé界 text")
      test.is_nil(c.input.textview.mouse_selecting)
      test.equal(core.root_view.grab.view, c.panel)
      core.on_event("mousereleased", "left", x, y)
      test.equal(c.input:get_text(), "")
      test.same(changes, { "" })
      test.equal(core.active_view, c.input.textview)
      test.is_nil(core.root_view.grab)
      test.is_nil(c.panel.captured_widget)
      test.not_ok(c.input.clear_pressed)
      test.is_nil(c.input:get_clear_button_bounds())
      test.equal(c.input.textview.scroll.x, 0)
      test.equal(c.input.textview.scroll.to.x, 0)
      core.on_event("textinput", "next")
      test.equal(c.input:get_text(), "next")
    end)
  end

  test.it("makes clearing separate from preceding and subsequent typing in undo history", function(c)
    core.set_active_view(c.input.textview)
    c.input:on_text_input("needle")
    local x, y = press(c)
    core.on_event("mousereleased", "left", x, y)
    test.equal(c.input:get_text(), "")
    test.ok(command.perform("doc:undo"))
    test.equal(c.input:get_text(), "needle")
    test.ok(command.perform("doc:redo"))
    test.equal(c.input:get_text(), "")
    c.input:on_text_input("next")
    test.ok(command.perform("doc:undo"))
    test.equal(c.input:get_text(), "")
    test.ok(command.perform("doc:undo"))
    test.equal(c.input:get_text(), "needle")
  end)

  test.it("cancels a clear press released outside the icon", function(c)
    c.input:set_text("keep")
    local _, y = press(c)
    local x = c.input.position.x + 5
    core.on_event("mousemoved", x, y, -100, 0)
    core.on_event("mousereleased", "left", x, y)
    test.equal(c.input:get_text(), "keep")
    test.is_nil(core.root_view.grab)
  end)

  test.it("requires a left press and its matching release", function(c)
    c.input:set_text("keep")
    local x, y = clear_point(c)
    core.on_event("mousepressed", "right", x, y, 1)
    core.on_event("mousereleased", "right", x, y)
    test.equal(c.input:get_text(), "keep")
    x, y = press(c)
    core.on_event("mousereleased", "right", x, y)
    test.equal(c.input:get_text(), "keep")
    test.ok(c.input.clear_pressed)
    core.on_event("mousereleased", "left", x, y)
    test.equal(c.input:get_text(), "")
  end)

  for _, cancel in ipairs { "hide", "disable", "focuslost" } do
    test.it(cancel .. " cancels a pending clear action", function(c)
      c.input:set_text("keep")
      local x, y = press(c)
      if cancel == "hide" then c.input:hide()
      elseif cancel == "disable" then c.input:set_clearable(false)
      else core.on_event("focuslost") end
      core.on_event("mousereleased", "left", x, y)
      test.equal(c.input:get_text(), "keep")
      test.not_ok(c.input.clear_pressed)
      test.is_nil(core.root_view.grab)
    end)
  end

  test.it("does not clear when a text selection is dragged across the icon", function(c)
    c.input:set_text(string.rep("long text ", 30))
    c.input.textview.doc:set_selection(1, 1)
    local x = c.input.textview.position.x + 2
    local _, y = clear_point(c)
    core.on_event("mousepressed", "left", x, y, 1)
    local bx = clear_point(c)
    core.on_event("mousemoved", bx, y, bx - x, 0)
    core.root_view:update()
    test.ok(c.input.textview.mouse_selecting)
    test.not_ok(c.input.clear_pressed)
    test.equal(c.input.cursor, "ibeam")
    core.on_event("mousereleased", "left", bx, y)
    test.equal(c.input:get_text(), string.rep("long text ", 30))
    test.ok(#c.input.textview.doc:get_selection_text() > 0)
  end)

  test.it("uses an arrow over the icon and an I-beam over the text", function(c)
    c.input:set_text("filter")
    local x, y = clear_point(c)
    core.on_event("mousemoved", x, y, 0, 0)
    core.root_view:update()
    test.equal(core.cursor_change_req, "arrow")
    core.on_event("mousemoved", c.input.textview.position.x + 2, y, -100, 0)
    core.root_view:update()
    test.equal(core.cursor_change_req, "ibeam")
  end)

  test.it("honors an on_change callback that hides the textbox", function(c)
    c.input:set_text("filter")
    function c.input:on_change() self:hide() end
    local x, y = press(c)
    core.on_event("mousereleased", "left", x, y)
    test.not_ok(c.input.visible)
    test.not_equal(core.active_view, c.input.textview)
    test.is_nil(core.root_view.grab)
  end)

  test.it("clips long text before the icon and uses the current icon font", function(c)
    local text = string.rep("W", 100)
    c.input:set_text(text)
    c.input.textview.doc:set_selection(1, 1)
    core.root_view:update()
    local clear_x = c.input:get_clear_button_bounds()
    local icon_drawn, text_drawn = false, false
    renderer.draw_text = function(font, value, ...)
      local clip = core.clip_rect_stack[#core.clip_rect_stack]
      if value == "C" and font == style.icon_font then
        icon_drawn = true
        test.ok(clip[1] >= c.input.position.x)
        test.ok(clip[1] + clip[3] <= c.input.position.x + c.input.size.x)
      elseif value == text then
        text_drawn = true
        test.ok(clip[1] + clip[3] <= clear_x)
      end
      return c.draw_text(font, value, ...)
    end
    core.clip_rect_stack = { { 0, 0, 900, 650 } }
    renderer.begin_frame(core.window)
    c.panel:draw()
    renderer.end_frame()
    test.ok(icon_drawn)
    test.ok(text_drawn)
  end)

  test.it("keeps bounds inside narrow inputs while scaling up and back down", function(c)
    c.input:set_text("filter")
    for _, factor in ipairs { 1, 1.25, 2, 1 } do
      SCALE = factor
      local ratio = factor / c.scale
      style.font = c.font:copy(c.font:get_size() * ratio)
      style.icon_font = c.icons:copy(c.icons:get_size() * ratio)
      style.padding = { x = c.padding.x * ratio, y = c.padding.y * ratio }
      for _, width in ipairs { 180, 12 } do
        c.input:set_size(width)
        for _ = 1, 3 do core.root_view:update() end
        local x, y, w, h = c.input:get_clear_button_bounds()
        test.ok(x >= c.input.position.x)
        test.ok(y >= c.input.position.y)
        test.ok(x + w <= c.input.position.x + c.input.size.x)
        test.ok(y + h <= c.input.position.y + c.input.size.y)
        test.ok(c.input.textview.size.x >= 0)
      end
    end
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
