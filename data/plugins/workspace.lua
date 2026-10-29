-- mod-version:3
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local storage = require "core.storage"
local Node = require "core.node"

---@class plugins.workspace
local workspace = {}

local STORAGE_MODULE = "ws"
local pending_project

---Normalizes separators and lowercases paths on Windows for comparison.
---Preserves paths on other platforms and accepts missing stored paths.
---@param path string?
---@return string? path
local function path_for_comparison(path)
  if PLATFORM == "Windows" and path then
    return common.normalize_path(path):ulower()
  end
  return path
end


---Iterates session keys whose project basename matches the given directory.
---Yields original key spellings and numeric suffixes, not full-path matches.
---@param project_dir string Project path or basename.
---@return fun(): string?, integer? iterator
local function workspace_keys_for(project_dir)
  local basename = common.basename(path_for_comparison(project_dir))
  return coroutine.wrap(function()
    for _, key in ipairs(storage.keys(STORAGE_MODULE) or {}) do
      local name, id = key:match("^(.*)%-(%d+)$")
      if id and path_for_comparison(name) == basename then
        coroutine.yield(key, tonumber(id))
      end
    end
  end)
end


---Load a session only when its key and stored full path belong to the project.
---@param key string Original storage key
---@param project_dir string Project's absolute directory
---@return table? session Stored workspace, or nil for an unrelated or invalid key
local function read_session(key, project_dir)
  for candidate in workspace_keys_for(project_dir) do
    if candidate == key then
      local ok, session = core.try(storage.load, STORAGE_MODULE, key)
      if ok and type(session) == "table"
        and path_for_comparison(session.path) == path_for_comparison(project_dir)
      then
        return session
      end
      break
    end
  end
end


---Count restorable tabs in a saved document layout.
---@param node table? Saved layout subtree
---@return integer count Number of saved views
local function count_views(node)
  if type(node) ~= "table" then return 0 end
  if node.type == "leaf" then return #(node.views or {}) end
  return count_views(node.a) + count_views(node.b)
end


---@class plugins.workspace.session
---@field key string Original storage key, used to load or remove the session
---@field id integer Numeric suffix shared by projects with the same basename
---@field name string User name or automatically assigned session label
---@field count integer Number of saved tabs
---@field saved_at? integer Unix time at which the snapshot was saved

---List saved sessions for the current root project's full path.
---Read storage once per request; callers can filter the returned metadata in memory.
---@return plugins.workspace.session[] sessions In numeric session order
function workspace.get_sessions()
  local sessions = {}
  local project_dir = core.root_project().path
  for key, id in workspace_keys_for(project_dir) do
    local ok, session = core.try(storage.load, STORAGE_MODULE, key)
    if ok and type(session) == "table"
      and path_for_comparison(session.path) == path_for_comparison(project_dir)
    then
      sessions[#sessions + 1] = {
        key = key, id = id, name = session.name or ("Session " .. id),
        count = count_views(session.documents), saved_at = session.saved_at
      }
    end
  end
  table.sort(sessions, function(a, b)
    return a.id < b.id
  end)
  return sessions
end


---Remove one saved session belonging to the current project.
---This does not close any tabs or modify sessions belonging to another project.
---@param key string Original key from get_sessions()
---@return boolean removed Whether a matching session was found and removed
function workspace.remove_session(key)
  if pending_project or not read_session(key, core.root_project().path) then return false end
  storage.clear(STORAGE_MODULE, key)
  return true
end


---Remove every saved session for the current project, preserving other projects.
---The active workspace remains open and is still saved normally on exit.
---@return integer count Number of saved sessions removed
function workspace.clear_sessions()
  if pending_project then return 0 end
  local count = 0
  for _, session in ipairs(workspace.get_sessions()) do
    storage.clear(STORAGE_MODULE, session.key)
    count = count + 1
  end
  return count
end


---Loads and removes the first session whose stored full project path matches.
---Storage enumeration order determines which matching session is consumed.
---@param project_dir string Full project path.
---@return table? workspace
local function consume_workspace(project_dir)
  local path = path_for_comparison(project_dir)
  for key, id in workspace_keys_for(project_dir) do
    local workspace = storage.load(STORAGE_MODULE, key)
    if workspace and path_for_comparison(workspace.path) == path then
      storage.clear(STORAGE_MODULE, key)
      return workspace
    end
  end
end


---Checks whether a node and all of its descendants are unlocked.
---@param node core.node
---@return boolean unlocked
local function has_no_locked_children(node)
  if node.locked then return false end
  if node.type == "leaf" then return true end
  return has_no_locked_children(node.a) and has_no_locked_children(node.b)
end


---Finds the first wholly unlocked subtree to save or restore as the workspace.
---@param node core.node
---@return core.node|false root False when no unlocked subtree exists.
local function get_unlocked_root(node)
  if node.type == "leaf" then
    return not node.locked and node
  end
  if has_no_locked_children(node) then
    return node
  end
  return get_unlocked_root(node.a) or get_unlocked_root(node.b)
end


---Captures a restorable view's module, state, and global focus status.
---@param view core.view
---@return table? state Nil when the view has no saved state or module.
local function save_view(view)
  local state = view:get_state()
  local module = view:get_module()
  if state and module then
    return {
      module = module,
      active = (core.active_view == view),
      state = state,
      unsaved = view.doc and view.doc:is_dirty() and {
        text = view.doc:get_text(1, 1, math.huge, math.huge),
        encoding = view.doc.encoding, bom = view.doc.bom, crlf = view.doc.crlf
      } or nil,
    }
  end
end


---Recreates a saved view, converting legacy document records when needed.
---@param t table Saved view record, updated in place for legacy formats.
---@return core.view? view
local function load_view(t)
  t.module = t.module or (t.type == "doc" and "core.docview")
  if t.module then
    local View = require(t.module)
    -- compatibility with old state data
    if t.scroll then
      t.state = {
        scroll = t.scroll,
        filename = t.filename,
        selection = t.selection,
        crlf = t.crlf,
        text = t.text
      }
    end
    local view = View and View.from_state(t.state)
    if view and view.doc and t.unsaved then
      local doc = view.doc
      if doc:get_text(1, 1, math.huge, math.huge) ~= t.unsaved.text then
        doc:remove(1, 1, math.huge, math.huge)
        doc:insert(1, 1, t.unsaved.text)
      end
      doc.encoding, doc.bom, doc.crlf = t.unsaved.encoding, t.unsaved.bom, t.unsaved.crlf
      doc:set_selection(table.unpack(t.state.selection))
    end
    return view
  end
end


---Serializes a layout subtree, including splits, restorable tabs, and active tabs.
---@param node core.node
---@return table state
local function save_node(node)
  local res = {}
  res.type = node.type
  if node.type == "leaf" then
    res.views = {}
    for _, view in ipairs(node.views) do
      local t = save_view(view)
      if t then
        table.insert(res.views, t)
        if node.active_view == view then
          res.active_view = #res.views
        end
      end
    end
  else
    res.divider = node.divider
    res.a = save_node(node.a)
    res.b = save_node(node.b)
  end
  return res
end


---Restores a saved layout into a node and returns its globally focused view.
---@param node core.node Target node for the restored subtree.
---@param t table Saved layout subtree.
---@return core.view? active_view
local function load_node(node, t)
  if t.type == "leaf" then
    local res
    local active_view
    for i, v in ipairs(t.views) do
      local view = load_view(v)
      if view then
        if v.active then res = view end
        node:add_view(view)
        if t.active_view == i then
          active_view = view
        end
      end
    end
    if active_view then
      node:set_active_view(active_view)
    end
    return res
  else
    node:split(t.type == "hsplit" and "right" or "down")
    node.divider = t.divider
    local res1 = load_node(node.a, t.a)
    local res2 = load_node(node.b, t.b)
    return res1 or res2
  end
end


---Collects the absolute paths of additional project directories.
---@return string[] directories
local function save_directories()
  local dir_list = {}
  for i = 2, #core.projects do
    dir_list[#dir_list + 1] = system.absolute_path(core.projects[i].path)
  end
  return dir_list
end


---Restore added directories, warning about saved paths that are no longer directories.
---@param directories string[] Saved absolute project directory paths
local function load_directories(directories)
  for _, directory in ipairs(directories) do
    local info = system.get_file_info(directory)
    if info and info.type == "dir" then
      core.add_project(directory)
    else
      core.warn("Workspace directory '%s' no longer exists; skipping it.", directory)
    end
  end
end


---Saves the current layout, project directories, and visited files to a free key.
---Does nothing while restoration is pending, before the layout is ready to save.
---@return string? key Storage key of the saved workspace
local function save_workspace()
  -- Project switches restart before the destination's queued restore can run.
  if pending_project then return end
  local project_dir = common.basename(core.root_project().path)
  local id_list = {}
  for filename, id in workspace_keys_for(project_dir) do
    id_list[id] = true
  end
  local id = 1
  while id_list[id] do
    id = id + 1
  end
  local root = get_unlocked_root(core.root_view.root_node)
  if not root then return end
  local key = project_dir .. "-" .. id
  local saved = storage.save(STORAGE_MODULE, key, {
    path = core.root_project().path,
    documents = save_node(root),
    directories = save_directories(),
    visited_files = core.visited_files,
    saved_at = os.time()
  })
  if saved then return key end
end


---Queues restoration for the current project and blocks saving until it finishes.
---Skips stale requests and requests interrupted by shutdown or restart.
local function load_workspace()
  local project = core.root_project()
  pending_project = project
  core.add_thread(function()
    if pending_project ~= project or core.root_project() ~= project
      or core.restart_request or core.quit_request
    then
      return
    end
    core.try(function()
      local workspace = consume_workspace(project.path)
      if workspace then
        if workspace.visited_files then
          core.visited_files = workspace.visited_files
        end
        local root = get_unlocked_root(core.root_view.root_node)
        local active_view = load_node(root, workspace.documents)
        if active_view then
          core.set_active_view(active_view)
        end
        load_directories(workspace.directories)
      end
    end)
    if pending_project == project then
      pending_project = nil
    end
  end)
end


---Save the current workspace, including unsaved buffers, to a new session file.
---@return string? key New storage key, or nil if saving is pending or failed
function workspace.save_session()
  return save_workspace()
end


---Replace the current document layout with a saved session and back up the outgoing one.
---Consume the selected file only after restoration succeeds, as automatic restore does.
---A failed backup or restore leaves the current layout and selected session intact.
---@param key string Original key from get_sessions()
---@return boolean loaded Whether the requested session was restored
function workspace.load_session(key)
  if pending_project or core.restart_request or core.quit_request then return false end
  local project = core.root_project()
  local session = read_session(key, project.path)
  local root = get_unlocked_root(core.root_view.root_node)
  if not session or not root or not save_workspace() then return false end

  local documents, visited = core.docs, core.visited_files
  local active, last, next_view = core.active_view, core.last_active_view, core.next_active_view
  -- Prepare independently so existing buffers cannot override saved session contents.
  core.docs, core.visited_files = {}, {}
  local replacement = Node()
  replacement.is_primary_node = true
  local ok, focus = core.try(load_node, replacement, session.documents)
  local restored_docs = core.docs
  core.docs, core.visited_files = documents, visited
  core.set_active_view(active)
  core.last_active_view, core.next_active_view = last, next_view
  if not ok then
    for _, doc in ipairs(restored_docs) do doc:on_close() end
    return false
  end

  root:consume(replacement)
  for _, doc in ipairs(restored_docs) do documents[#documents + 1] = doc end
  core.visited_files = common.merge({}, session.visited_files or {})
  while #core.projects > 1 do core.remove_project(core.projects[#core.projects]) end
  load_directories(session.directories or {})
  core.root_view.root_node:update_layout()
  core.set_active_view(focus or core.root_view:get_primary_node().active_view)
  storage.clear(STORAGE_MODULE, key)
  core.redraw = true
  return true
end


---Format a session's tab count and save time for menus and command suggestions.
---@param session plugins.workspace.session Saved session metadata
---@return string info Description without reading the snapshot again
local function session_info(session)
  local text = session.count .. (session.count == 1 and " tab" or " tabs")
  if session.saved_at then text = text .. " · " .. os.date("%Y-%m-%d %H:%M", session.saved_at) end
  return text
end


---Offer a snapshot of this project's sessions without storage reads while filtering.
---@param remove boolean Whether selection removes rather than loads a session
local function choose_session(remove)
  local project = core.root_project()
  local sessions = workspace.get_sessions()
  if #sessions == 0 then
    core.log("No saved sessions for %s", project.path)
    return
  end
  core.command_view:enter(remove and "Remove Session" or "Load Session", {
    suggest = function(text)
      local items = {}
      for _, session in ipairs(sessions) do
        local score = text == "" and 0 or common.fuzzy_match(session.name, text)
        if score then
          items[#items + 1] = {
            text = session.name, info = session_info(session),
            key = session.key, score = score
          }
        end
      end
      if text ~= "" then table.sort(items, function(a, b) return a.score > b.score end) end
      return items
    end,
    validate = function(_, item)
      return core.root_project() == project and item ~= nil
        and read_session(item.key, project.path) ~= nil
    end,
    submit = function(_, item)
      if core.root_project() ~= project then return end
      if remove then
        core.nag_view:show("Remove Session",
          string.format("Remove %s for %s? Open tabs will stay open.", item.text, project.path),
          { { text = "Remove" }, { text = "Cancel", default_no = true } }, function(option)
            if option.text == "Remove" and core.root_project() == project then
              workspace.remove_session(item.key)
            end
          end)
      else
        workspace.load_session(item.key)
      end
    end
  })
end


command.add(function() return not pending_project end, {
  ["workspace:load-session"] = function(key)
    if key then workspace.load_session(key) else choose_session(false) end
  end,
  ["workspace:remove-session"] = function() choose_session(true) end,
  ["workspace:clear-sessions"] = function()
    local project = core.root_project()
    local count = #workspace.get_sessions()
    if count == 0 then core.log("No saved sessions for %s", project.path); return end
    core.nag_view:show("Clear Saved Sessions",
      string.format("Remove all %d saved sessions for %s? Open tabs will stay open.", count, project.path),
      { { text = "Clear Sessions" }, { text = "Cancel", default_no = true } }, function(option)
        if option.text == "Clear Sessions" and core.root_project() == project then workspace.clear_sessions() end
      end)
  end
})

core.menu_view:register({ "file" }, {
  { id = "sessions", text = "Sessions", items = function()
    local items = {
      { id = "load", text = "Load Session…", command = "workspace:load-session" },
      { id = "remove", text = "Remove Session…", command = "workspace:remove-session" },
      { id = "clear", text = "Clear Saved Sessions…", command = "workspace:clear-sessions" }
    }
    local sessions = workspace.get_sessions()
    if #sessions > 0 then items[#items + 1] = core.menu_view.DIVIDER end
    local project = core.root_project()
    for _, session in ipairs(sessions) do
      items[#items + 1] = {
        id = session.key, text = session.name, info = session_info(session),
        command = function()
          if core.root_project() == project then command.perform("workspace:load-session", session.key) end
        end
      }
    end
    return items
  end }
}, "workspace")


local run = core.run

--Installs workspace lifecycle hooks when startup has no documents open.
--Restores the original entry point before delegating to core's run setup.
function core.run(...)
  if #core.docs == 0 then
    core.try(load_workspace)

    local set_project = core.set_project
    --Saves the outgoing workspace and queues restoration for the new project.
    function core.set_project(project)
      core.try(save_workspace)
      project = set_project(project)
      core.try(load_workspace)
      return project
    end
    local exit = core.exit
    --Saves the workspace once exit is confirmed, then delegates to core.
    function core.exit(quit_fn, force)
      if force then core.try(save_workspace) end
      exit(quit_fn, force)
    end

  end

  core.run = run
  return core.run(...)
end

return workspace
