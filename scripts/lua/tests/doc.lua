local command = require "core.command"
local config = require "core.config"
local core = require "core"
local Doc = require "core.doc"
local DocView = require "core.docview"
local test = require "core.test"

require "plugins.language_lua"

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
end)
