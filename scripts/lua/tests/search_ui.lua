local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local Doc = require "core.doc"
local DocView = require "core.docview"
local test = require "core.test"
local ui = require "plugins.search_ui"
local TextBox = require "widget.textbox"
local config = require "core.config"

local inputs = {}
for _, child in ipairs(ui.childs) do
  if child:is(TextBox) then inputs[#inputs + 1] = child end
end
table.sort(inputs, function(a, b) return a.zindex < b.zindex end)

local function read_file(path)
  local file = assert(io.open(path, "rb"))
  local text = file:read("*a")
  file:close()
  return text
end

test.describe("search_ui saving", function()
  test.before_each(function(context)
    context.active_view = core.active_view
    context.last_active_view = core.last_active_view
    context.next_active_view = core.next_active_view
    context.enter = core.command_view.enter
    context.modkeys = keymap.modkeys
    context.visible = ui:is_visible()
    context.child_active = ui.child_active
    context.prev_view = ui.prev_view
    context.texts = {}
    for i, input in ipairs(inputs) do
      context.texts[i] = input:get_text()
      input:set_text("")
    end

    context.path = core.temp_filename(".txt")
    local file = assert(io.open(context.path, "wb"))
    file:write("original document\n")
    file:close()
    context.doc = Doc(context.path, context.path)
    context.doc:insert(1, 1, "edited ")
    context.view = DocView(context.doc)
    ui:show()
    core.set_active_view(context.view)
    core.command_view.enter = function(_, label, options)
      context.prompt, context.options = label, options
    end
    keymap.modkeys = { [PLATFORM == "Mac OS X" and "cmd" or "ctrl"] = true }
  end)

  test.after_each(function(context)
    ui:swap_active_child()
    ui:hide()
    for i, input in ipairs(inputs) do input:set_text(context.texts[i]) end
    if context.visible then ui:show() end
    ui:swap_active_child(context.child_active)
    ui.prev_view = context.prev_view
    core.command_view.enter = context.enter
    keymap.modkeys = context.modkeys
    core.active_view = context.active_view
    core.last_active_view = context.last_active_view
    core.next_active_view = context.next_active_view
    context.doc:on_close()
    os.remove(context.path)
  end)

  for _, input_index in ipairs {1, 2} do
    for _, save_as in ipairs {false, true} do
      local field = input_index == 1 and "search" or "replacement"
      local name = save_as and "Save As" or "Save"
      test.test(name .. " ignores the focused " .. field .. " input", function(context)
        test.equal(#inputs, 2)
        local input = inputs[input_index]
        input:set_text("needle")
        ui:swap_active_child(input)
        test.equal(core.active_view, input.textview)
        keymap.modkeys.shift = save_as

        test.not_ok(keymap.on_key_pressed("s"))
        test.is_nil(context.prompt)
        test.equal(core.active_view, input.textview)
        test.is_nil(input.textview.doc.filename)
        test.equal(input:get_text(), "needle")
        test.equal(read_file(context.path), "original document\n")
        test.equal(context.doc:get_text(1, 1, math.huge, math.huge, true),
          "edited original document\n")
        test.ok(context.doc:is_dirty())
        test.ok(command.perform("doc:select-all"))
        test.equal(input.textview.doc:get_selection_text(), "needle")
      end)
    end
  end

  test.test("Save writes the focused document while the search pane is open", function(context)
    inputs[1]:set_text("needle")
    test.ok(keymap.on_key_pressed("s"))
    test.is_nil(context.prompt)
    test.equal(read_file(context.path), "edited original document\n")
    test.not_ok(context.doc:is_dirty())
    test.equal(inputs[1]:get_text(), "needle")
  end)

  test.test("Save As writes the focused document while the search pane is open", function(context)
    inputs[2]:set_text("replacement")
    keymap.modkeys.shift = true
    test.ok(keymap.on_key_pressed("s"))
    test.equal(context.prompt, "Save As")
    context.options.submit(context.path)
    test.equal(read_file(context.path), "edited original document\n")
    test.not_ok(context.doc:is_dirty())
    test.equal(inputs[2]:get_text(), "replacement")
  end)
end)

test.describe("search_ui mouse selection", function()
  test.before_each(function(context)
    context.active_view = core.active_view
    context.last_active_view = core.last_active_view
    context.next_active_view = core.next_active_view
    context.modkeys = keymap.modkeys
    context.transitions = config.transitions
    context.clipboard = system.get_clipboard()
    context.texts = { inputs[1]:get_text(), inputs[2]:get_text() }
    keymap.modkeys = {}
    config.transitions = false
    ui:hide()
    context.doc = Doc()
    context.view = DocView(context.doc)
    context.node = core.root_view:get_primary_node()
    context.node:add_view(context.view)
    test.ok(command.perform("find-replace:replace"))
    for _ = 1, 3 do core.root_view:update() end
  end)

  test.after_each(function(context)
    ui:hide()
    for i, input in ipairs(inputs) do input:set_text(context.texts[i]) end
    local node = core.root_view.root_node:get_node_for_view(context.view)
    node:remove_view(core.root_view.root_node, context.view)
    context.doc:on_close()
    keymap.modkeys = context.modkeys
    config.transitions = context.transitions
    system.set_clipboard(context.clipboard or "")
    core.active_view = context.active_view
    core.last_active_view = context.last_active_view
    core.next_active_view = context.next_active_view
  end)

  for i, field in ipairs { "Find", "Replace" } do
    test.test(field .. " supports pasted overflow through real root events", function(context)
      local input = inputs[i]
      local view = input.textview
      test.ok(input:is_visible())
      input:set_text("")
      core.on_event("mousepressed", "left", input.position.x + 10, input.position.y + 10, 1)
      core.on_event("mousereleased", "left", input.position.x + 10, input.position.y + 10)
      test.ok(core.active_view == view, "the input should focus on press")
      local text = string.rep("aé界 long input ", 80)
      system.set_clipboard(text)
      test.ok(command.perform("doc:paste"))
      test.equal(input:get_text(), text)
      view.doc:set_selection(1, 1)
      view.scroll.x, view.scroll.to.x = 0, 0
      input:update()
      local x, y = view:get_line_screen_position(1, 2)
      y = input.position.y + input.size.y / 2
      core.on_event("mousepressed", "left", x, y, 1)
      test.ok(ui.captured_widget == input, "the input should capture the drag")
      local right = input.position.x + input.size.x + 40
      core.on_event("mousemoved", right, y, right - x, 0)
      for _ = 1, 8 do input:update() end
      local _, col, _, anchor = view.doc:get_selection()
      test.ok(col > 2)
      test.equal(anchor, 2)
      test.ok(view.scroll.x > 0)
      test.equal(core.active_view, view)
      core.on_event("mousereleased", "left", right, y)
      test.is_nil(core.root_view.grab)
      test.is_nil(ui.captured_widget)
      test.not_ok(ui.mouse_is_pressed)
      test.not_ok(command.perform("doc:save"))
      test.not_ok(command.perform("doc:save-as"))
      test.equal(context.doc:get_text(1, 1, math.huge, math.huge), "")
    end)
  end
end)
