-- mod-version:3
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local DocView = require "core.docview"

-- Track the last active document
local last_doc = nil
local current_doc = nil

-- Hook into active view changes to track document switches
local old_set_active_view = core.set_active_view

function core.set_active_view(view)
  old_set_active_view(view)

  -- Only track DocView changes
  if view and view:is(DocView) and view.doc then
    local new_doc = view.doc

    -- If we're switching to a different document, update history
    if new_doc ~= current_doc then
      last_doc = current_doc
      current_doc = new_doc
    end
  end
end

-- Switch to the last document
local function switch_to_last_doc()
  if not last_doc then
    core.log("No previous document to switch to")
    return
  end

  -- Find a view showing the last document
  local views = core.get_views_referencing_doc(last_doc)
  local target_view = nil

  for _, view in ipairs(views) do
    if view:is(DocView) then
      target_view = view
      break
    end
  end

  -- If no view exists, create one
  if not target_view then
    local node = core.root_view:get_active_node_default()
    target_view = DocView(last_doc)
    node:add_view(target_view)
  end

  -- Focus the view
  local node = core.root_view.root_node:get_node_for_view(target_view)
  if node then
    node:set_active_view(target_view)
    core.log("Switched to previous document")
  end
end

-- Commands
command.add("core.docview", {
  ["doc-switcher:switch-to-last-doc"] = function()
    switch_to_last_doc()
  end,
})

-- Default keybinding
keymap.add {
  ["ctrl+tab"] = "doc-switcher:switch-to-last-doc",
}

core.log_quiet("Doc Switcher plugin loaded - Use Ctrl+Tab to switch to last document")
