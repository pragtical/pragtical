-- mod-version:3
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local DocView = require "core.docview"
local Doc = require "core.doc"

---@class plugins.compilation.compilationview : core.docview
---@field super core.docview
local CompilationView = DocView:extend()

function CompilationView:__tostring()
  return "CompilationView"
end

function CompilationView:new()
  -- Create a new document for the compilation buffer
  local doc = Doc()
  
  -- Initialize parent DocView with our document
  CompilationView.super.new(self, doc)
  
  -- Make the document read-only by default
  doc.read_only = true
  
  -- Set a custom name for the view
  self.compilation_name = "Compilation"
  
  -- Log to the document when opened
  self:log("Compilation buffer initialized")
  self:log("Ready for compilation output...")
end

function CompilationView:get_name()
  return self.compilation_name
end

function CompilationView:log(message)
  -- Get the document
  local doc = self.doc
  
  -- Temporarily disable read-only to insert text
  local was_read_only = doc.read_only
  doc.read_only = false
  
  -- Add the message to the end of the document
  local line = #doc.lines
  doc:insert(line, math.huge, message .. "\n")
  
  -- Restore read-only state
  doc.read_only = was_read_only
  
  -- Scroll to the bottom to show the new message
  self:scroll_to_line(#doc.lines, false, true)
end

function CompilationView:clear()
  local doc = self.doc
  local was_read_only = doc.read_only
  doc.read_only = false
  
  -- Remove all content
  doc:remove(1, 1, math.huge, math.huge)
  
  doc.read_only = was_read_only
end

-- Helper function to find existing CompilationView
local function get_compilation_view()
  for _, view in ipairs(core.root_view.root_node:get_children()) do
    if view:is(CompilationView) then
      return view
    end
  end
  return nil
end

-- Command to open compilation view
command.add(nil, {
  ["compilation:open"] = function()
    -- Check if a CompilationView already exists
    local existing_view = get_compilation_view()
    
    if existing_view then
      -- Find the node containing the view and set it as active
      local node = core.root_view.root_node:get_node_for_view(existing_view)
      if node then
        node:set_active_view(existing_view)
      end
      core.log("Compilation view focused")
    else
      -- Create a new CompilationView
      local node = core.root_view:get_active_node_default()
      local view = CompilationView()
      node:add_view(view)
      core.log("Compilation view opened")
    end
  end,
  
  ["compilation:clear"] = function()
    local view = core.active_view
    if view:is(CompilationView) then
      view:clear()
      view:log("Compilation buffer cleared")
    end
  end,
  
  ["compilation:test-log"] = function()
    local view = core.active_view
    if view:is(CompilationView) then
      view:log("Test message at " .. os.date("%H:%M:%S"))
    else
      core.error("Active view is not a CompilationView")
    end
  end
})

return CompilationView
