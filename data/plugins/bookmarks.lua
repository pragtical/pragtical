-- mod-version:3
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local DocView = require "core.docview"

-- Bookmarks storage
-- Structure: { { abs_filename, filename, line, col }, ... }
local bookmarks = {}

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

-- Helper function to check if a bookmark exists at location
local function find_bookmark_at(location)
  for i, bookmark in ipairs(bookmarks) do
    if bookmark.abs_filename == location.abs_filename and
       bookmark.line == location.line then
      return i
    end
  end
  return nil
end

-- Toggle bookmark at current location
local function toggle_bookmark()
  local location = get_current_location()
  if not location then
    core.error("No document active")
    return
  end

  local existing_idx = find_bookmark_at(location)

  if existing_idx then
    -- Remove existing bookmark
    table.remove(bookmarks, existing_idx)
    core.log(string.format("Removed bookmark at %s:%d", location.filename, location.line))
  else
    -- Add new bookmark
    table.insert(bookmarks, location)
    core.log(string.format("Added bookmark at %s:%d (%d total)", 
                          location.filename, location.line, #bookmarks))
  end
end

-- Jump to a specific bookmark
local function jump_to_bookmark(bookmark)
  if not bookmark then
    return false
  end

  -- Open the file
  local doc = core.open_doc(bookmark.abs_filename)
  if not doc then
    core.error("Could not open file: " .. bookmark.filename)
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
  doc:set_selection(bookmark.line, bookmark.col)

  -- Scroll to make visible
  view:scroll_to_make_visible(bookmark.line, bookmark.col)

  return true
end

-- Jump to next bookmark
local function next_bookmark()
  if #bookmarks == 0 then
    core.log("No bookmarks set")
    return
  end

  local current = get_current_location()
  if not current then
    -- Just jump to first bookmark
    if jump_to_bookmark(bookmarks[1]) then
      core.log(string.format("Jumped to bookmark 1/%d", #bookmarks))
    end
    return
  end

  -- Find next bookmark after current location
  local next_idx = nil

  for i, bookmark in ipairs(bookmarks) do
    if bookmark.abs_filename > current.abs_filename or
       (bookmark.abs_filename == current.abs_filename and bookmark.line > current.line) then
      next_idx = i
      break
    end
  end

  -- If no next bookmark found, wrap to first
  if not next_idx then
    next_idx = 1
  end

  if jump_to_bookmark(bookmarks[next_idx]) then
    core.log(string.format("Jumped to bookmark %d/%d", next_idx, #bookmarks))
  end
end

-- Jump to previous bookmark
local function prev_bookmark()
  if #bookmarks == 0 then
    core.log("No bookmarks set")
    return
  end

  local current = get_current_location()
  if not current then
    -- Just jump to last bookmark
    if jump_to_bookmark(bookmarks[#bookmarks]) then
      core.log(string.format("Jumped to bookmark %d/%d", #bookmarks, #bookmarks))
    end
    return
  end

  -- Find previous bookmark before current location
  local prev_idx = nil

  for i = #bookmarks, 1, -1 do
    local bookmark = bookmarks[i]
    if bookmark.abs_filename < current.abs_filename or
       (bookmark.abs_filename == current.abs_filename and bookmark.line < current.line) then
      prev_idx = i
      break
    end
  end

  -- If no previous bookmark found, wrap to last
  if not prev_idx then
    prev_idx = #bookmarks
  end

  if jump_to_bookmark(bookmarks[prev_idx]) then
    core.log(string.format("Jumped to bookmark %d/%d", prev_idx, #bookmarks))
  end
end

-- Clear all bookmarks
local function clear_all_bookmarks()
  local count = #bookmarks
  bookmarks = {}
  core.log(string.format("Cleared %d bookmark(s)", count))
end

-- List all bookmarks
local function list_bookmarks()
  if #bookmarks == 0 then
    core.log("No bookmarks set")
    return
  end

  core.log(string.format("Bookmarks (%d total):", #bookmarks))
  for i, bookmark in ipairs(bookmarks) do
    core.log(string.format("  %d. %s:%d:%d", i, bookmark.filename, bookmark.line, bookmark.col))
  end
end

-- Commands
command.add("core.docview", {
  ["bookmarks:toggle"] = function()
    toggle_bookmark()
  end,

  ["bookmarks:next"] = function()
    next_bookmark()
  end,

  ["bookmarks:prev"] = function()
    prev_bookmark()
  end,

  ["bookmarks:clear-all"] = function()
    clear_all_bookmarks()
  end,

  ["bookmarks:list"] = function()
    list_bookmarks()
  end,
})

-- Default keybindings
keymap.add {
  ["ctrl+f2"] = "bookmarks:toggle",
  ["f2"] = "bookmarks:next",
  ["shift+f2"] = "bookmarks:prev",
}

core.log_quiet("Bookmarks plugin loaded - Use Ctrl+F2 to toggle, F2 to navigate")
