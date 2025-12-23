-- mod-version:3
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local keymap = require "core.keymap"
local DocView = require "core.docview"

-- Configuration
config.plugins.navigation = common.merge({
  max_history = 100,              -- Maximum number of positions to remember
  min_distance = 10,              -- Minimum line distance to record a jump
  enabled = true,
  config_spec = {
    name = "Navigation",
    {
      label = "Maximum History",
      description = "Maximum number of cursor positions to remember.",
      path = "max_history",
      type = "number",
      default = 100,
      min = 10,
      max = 1000,
    },
    {
      label = "Minimum Distance",
      description = "Minimum line distance to record a navigation jump.",
      path = "min_distance",
      type = "number",
      default = 10,
      min = 1,
      max = 100,
    },
  }
}, config.plugins.navigation)

-- Navigation history storage
local history = {}
local history_index = 0
local last_location = nil
local is_navigating = false

-- Helper function to get current location
local function get_current_location()
  local view = core.active_view
  if not view or not view:is(DocView) then
    return nil
  end

  local doc = view.doc
  if not doc or not doc.abs_filename then
    return nil
  end

  local line, col = doc:get_selection()

  return {
    abs_filename = doc.abs_filename,
    filename = doc.filename,
    line = line,
    col = col,
  }
end

-- Helper function to compare locations
local function locations_equal(loc1, loc2)
  if not loc1 or not loc2 then return false end
  return loc1.abs_filename == loc2.abs_filename and
         loc1.line == loc2.line and
         loc1.col == loc2.col
end

-- Helper function to check if jump is significant
local function is_significant_jump(from_loc, to_loc)
  if not from_loc or not to_loc then return false end

  -- Different file is always significant
  if from_loc.abs_filename ~= to_loc.abs_filename then
    return true
  end

  -- Same file: check line distance
  local line_distance = math.abs(to_loc.line - from_loc.line)
  return line_distance >= config.plugins.navigation.min_distance
end

-- Add a location to history
local function add_to_history(location)
  if not location or not config.plugins.navigation.enabled then
    return
  end

  -- Don't add if we're currently navigating
  if is_navigating then
    return
  end

  -- Don't add if it's the same as the last location
  if last_location and locations_equal(location, last_location) then
    return
  end

  -- Don't add if it's not a significant jump from last location
  if last_location and not is_significant_jump(last_location, location) then
    last_location = location
    return
  end

  -- If we're in the middle of history, truncate forward history
  if history_index < #history then
    for i = #history, history_index + 1, -1 do
      table.remove(history, i)
    end
  end

  -- Add the new location
  table.insert(history, location)
  history_index = #history

  -- Limit history size
  if #history > config.plugins.navigation.max_history then
    table.remove(history, 1)
    history_index = history_index - 1
  end

  last_location = location
end

-- Jump to a location
local function jump_to_location(location)
  if not location then
    return false
  end

  is_navigating = true

  -- Open the file
  local doc = core.open_doc(location.abs_filename)
  if not doc then
    core.error("Could not open file: " .. location.filename)
    is_navigating = false
    return false
  end

  -- Find or create a view for the document
  local view = nil
  for _, v in ipairs(core.get_views_referencing_doc(doc)) do
    if v:is(DocView) then
      view = v
      break
    end
  end

  if not view then
    -- Create new view
    local node = core.root_view:get_active_node_default()
    view = DocView(doc)
    node:add_view(view)
  end

  -- Focus the view
  local node = core.root_view.root_node:get_node_for_view(view)
  if node then
    node:set_active_view(view)
  end

  -- Set cursor position
  doc:set_selection(location.line, location.col)

  -- Scroll to make visible
  view:scroll_to_make_visible(location.line, location.col)

  -- Update last_location to prevent the background thread from adding this as a new position
  last_location = location

  is_navigating = false
  return true
end

-- Navigate backward
local function navigate_backward()
  if history_index <= 1 then
    core.log("Already at oldest position")
    return
  end

  -- If we're at the end of history, save current position first
  if history_index == #history then
    local current = get_current_location()
    if current and not locations_equal(current, history[history_index]) then
      -- Update the current position in history
      history[history_index] = current
    end
  end

  history_index = history_index - 1
  local location = history[history_index]

  if jump_to_location(location) then
    core.log(string.format("Navigated backward (%d/%d)", history_index, #history))
  end
end

-- Navigate forward
local function navigate_forward()
  if history_index >= #history then
    core.log("Already at newest position")
    return
  end

  history_index = history_index + 1
  local location = history[history_index]

  if jump_to_location(location) then
    core.log(string.format("Navigated forward (%d/%d)", history_index, #history))
  end
end

-- Track cursor position changes
local last_check_time = 0
local check_interval = 0.5  -- Check every 0.5 seconds

core.add_thread(function()
  while true do
    if config.plugins.navigation.enabled and not is_navigating then
      local current = get_current_location()
      if current then
        add_to_history(current)
      end
    end
    coroutine.yield(check_interval)
  end
end)

-- Commands
command.add(nil, {
  ["navigation:navigate-back"] = function()
    navigate_backward()
  end,

  ["navigation:navigate-forward"] = function()
    navigate_forward()
  end,

  ["navigation:clear-history"] = function()
    history = {}
    history_index = 0
    last_location = nil
    core.log("Navigation history cleared")
  end,

  ["navigation:show-history"] = function()
    if #history == 0 then
      core.log("Navigation history is empty")
      return
    end

    core.log(string.format("Navigation history (%d positions, at index %d):",
                          #history, history_index))
    for i, loc in ipairs(history) do
      local marker = (i == history_index) and ">>> " or "    "
      core.log(string.format("%s%d: %s:%d:%d",
                            marker, i, loc.filename, loc.line, loc.col))
    end
  end,
})

-- Default keybindings (like VSCode and many other editors)
keymap.add {
  ["alt+left"] = "navigation:navigate-back",
  ["alt+right"] = "navigation:navigate-forward",
}

core.log_quiet("Navigation plugin loaded - Use Alt+Left/Right to navigate")
