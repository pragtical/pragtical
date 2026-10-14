local core = require "core"
local config = require "core.config"
local command = require "core.command"
local ime = require "core.ime"
local View = require "core.view"
local Doc = require "core.doc"
local DocView = require "core.docview"
local RootView = require "core.rootview"
local ContextMenu = require "core.contextmenu"
local test = require "core.test"

local function document(context, named)
  local doc
  if named then
    context.path = core.temp_filename(".txt")
    local file = assert(io.open(context.path, "wb"))
    file:write("original\n")
    file:close()
    doc = Doc(context.path, context.path)
  else
    doc = Doc()
  end
  core.docs[#core.docs + 1] = doc
  local view = DocView(doc)
  context.views[#context.views + 1] = view
  view:set_floating_bounds(40, 40, 250, 180)
  view:set_floating(true, { focus = "show" })
  view:show_floating()
  return view
end

test.describe("floating document routing", function()
  test.before_each(function(context)
    context.cwd = system.getcwd()
    context.root, context.active, context.last, context.next = core.root_view, core.active_view, core.last_active_view, core.next_active_view
    context.docs, context.transitions = core.docs, config.transitions
    context.enter, context.quit = core.command_view.enter, core.quit
    context.ime_editing, context.ime_location = ime.editing, ime.last_location
    core.docs, context.views = {}, {}
    config.transitions = false
    core.root_view = RootView()
    core.root_view.root_node.is_primary_node = true
    core.root_view.size.x, core.root_view.size.y = 500, 400
    context.node = core.root_view.root_node
    context.node:add_view(View())
    context.docked = View()
    context.node:add_view(context.docked)
    core.command_view.enter = function(_, label, options)
      context.prompt, context.options = label, options
    end
    context.quits = 0
    core.quit = function() context.quits = context.quits + 1 end
    ime.reset()
  end)

  test.after_each(function(context)
    for _, view in ipairs(context.views) do view:hide_floating() end
    for _, doc in ipairs(core.docs) do doc:on_close() end
    if context.path then os.remove(context.path) end
    core.root_view, core.active_view, core.last_active_view, core.next_active_view = context.root, context.active, context.last, context.next
    core.docs, config.transitions = context.docs, context.transitions
    core.command_view.enter, core.quit = context.enter, context.quit
    ime.editing, ime.last_location = context.ime_editing, context.ime_location
    system.chdir(context.cwd)
  end)

  test.test("typed text reaches a focused floating DocView once", function(context)
    local view = document(context)
    core.on_event("textinput", "x")
    test.equal(view.doc:get_text(1, 1, 1, math.huge), "x")
  end)

  test.test("focused descendants receive text without container forwarding", function(context)
    local container = View()
    context.views[#context.views + 1] = container
    container:set_floating_bounds(40, 40, 250, 180)
    container:set_floating(true, { focus = "show" })
    container.capture_text_input = true
    container:show_floating()
    local view = DocView(Doc())
    core.docs[#core.docs + 1] = view.doc
    view.parent = container
    local forwarded = 0
    container.on_text_input = function(_, text)
      forwarded = forwarded + 1
      view:on_text_input(text)
    end
    core.set_active_view(view)
    core.on_event("textinput", "x")
    test.equal(view.doc:get_text(1, 1, 1, math.huge), "x")
    test.equal(forwarded, 0)
    test.ok(command.perform("root:close"))
    test.not_ok(container.floating_visible)
    test.equal(core.active_view, context.docked)
  end)

  test.test("context menus capture text without editing the document", function(context)
    local view = document(context)
    local menu = ContextMenu()
    context.views[#context.views + 1] = menu
    menu:show_items({ { text = "Action", command = function() end } }, 40, 40)
    core.on_event("textinput", "x")
    test.equal(view.doc:get_text(1, 1, 1, math.huge), "")
    menu:hide()
    core.on_event("textinput", "x")
    test.equal(view.doc:get_text(1, 1, 1, math.huge), "x")
  end)

  test.test("unhandled popup capture falls through once", function(context)
    local view = document(context)
    local overlay = View()
    context.views[#context.views + 1] = overlay
    overlay:set_floating_bounds(0, 0, 100, 100)
    overlay:set_floating(true, { focus = "none" })
    overlay.capture_text_input = true
    local calls = 0
    overlay.on_text_input = function() calls = calls + 1; return false end
    overlay:show_floating()
    core.on_event("textinput", "x")
    test.equal(calls, 1)
    test.equal(view.doc:get_text(1, 1, 1, math.huge), "x")
  end)

  test.test("IME reaches focused floating descendants and ignores passive captures", function(context)
    local view = document(context)
    local calls = {}
    view.capture_text_input = true
    view.on_ime_text_editing = function(_, text)
      calls[#calls + 1] = text
    end
    local overlay = View()
    context.views[#context.views + 1] = overlay
    overlay:set_floating(true, { interactive = false, focus = "none" })
    overlay.capture_text_input = true
    overlay:show_floating()
    core.on_event("textediting", "é", 0, 0)
    test.equal(#calls, 1)
    test.equal(calls[1], "é")
    core.on_event("textinput", "é")
    test.equal(view.doc:get_text(1, 1, 1, math.huge), "é")
  end)

  for _, name in ipairs { "root:close", "root:close-or-quit" } do
    test.test(name .. " targets the focused floating document", function(context)
      local view = document(context)
      test.ok(command.perform(name))
      test.not_ok(view.floating_visible)
      test.not_nil(context.node:get_view_idx(context.docked))
      test.equal(core.active_view, context.docked)
      test.equal(context.quits, 0)
    end)
  end

  test.test("dirty floating documents can cancel or confirm Close", function(context)
    local view = document(context)
    view.doc:insert(1, 1, "edited")
    test.ok(command.perform("root:close"))
    test.equal(context.prompt, "Unsaved Changes; Confirm Close")
    test.ok(view.floating_visible)
    if context.options.cancel then context.options.cancel() end
    test.ok(view.floating_visible)
    test.not_nil(context.node:get_view_idx(context.docked))
    context.options.submit("", { text = "Close Without Saving" })
    test.not_ok(view.floating_visible)
  end)

  test.test("tab and pane commands require a docked focus target", function(context)
    local view = document(context)
    for _, name in ipairs {
      "root:move-tab-left", "root:move-tab-right", "root:switch-to-next-tab",
      "root:switch-to-previous-tab", "root:switch-to-tab-1", "root:split-right",
      "root:switch-to-left", "root:grow", "root:shrink"
    } do
      test.not_ok(command.is_valid(name), name)
      test.not_ok(command.perform(name), name)
      test.equal(core.active_view, view)
    end
    -- Explicit tab targets from pointer commands remain valid.
    test.ok(command.is_valid("root:switch-to-next-tab", context.node))
    view:hide_floating()
    test.ok(command.perform("root:move-tab-left"))
    test.equal(context.node.views[1], context.docked)
  end)

  test.test("confirmation closes the view at its current placement", function(context)
    local view = document(context)
    local confirm, calls
    view.try_close = function(_, callback) confirm = callback end
    test.ok(core.root_view:close_view(view, function() calls = (calls or 0) + 1 end))
    view:set_floating(false)
    context.node:add_view(view)
    confirm()
    test.is_nil(context.node:get_view_idx(view))
    test.equal(calls, 1)
    test.not_nil(context.node:get_view_idx(context.docked))
  end)

  test.test("Delete File closes docked and floating references", function(context)
    local view = document(context, true)
    local docked = DocView(view.doc)
    context.node:add_view(docked)
    core.set_active_view(view)
    test.ok(command.perform("file:delete"))
    test.not_ok(view.floating_visible)
    test.is_nil(context.node:get_view_idx(docked))
    test.is_nil(system.get_file_info(context.path))
    test.not_nil(context.node:get_view_idx(context.docked))
  end)

  for _, action in ipairs { "Cancel", "Close Without Saving", "Save And Close" } do
    test.test("Delete File waits for " .. action, function(context)
      local view = document(context, true)
      context.node:add_view(DocView(view.doc))
      core.set_active_view(view)
      view.doc:insert(1, 1, "edited ")
      test.ok(command.perform("file:delete"))
      test.equal(context.prompt, "Unsaved Changes; Confirm Close")
      test.ok(system.get_file_info(context.path))
      test.ok(view.floating_visible)
      if action == "Cancel" then
        if context.options.cancel then context.options.cancel() end
        test.ok(view.floating_visible)
        test.ok(system.get_file_info(context.path))
      else
        context.options.submit("", { text = action })
        test.not_ok(view.floating_visible)
        test.is_nil(system.get_file_info(context.path))
      end
      test.not_nil(context.node:get_view_idx(context.docked))
    end)
  end
end)
