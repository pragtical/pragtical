-- mod-version:3
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local storage = require "core.storage"
local Node = require "core.node"
local DocView = require "core.docview"

---@class plugins.workspace
local workspace = {}

local STORAGE_MODULE = "ws"
local pending_project, current_project, current_module, active_key, revision
local project_modules = {}
local reschedule
local scheduler_key = {}
local started = false

config.plugins.workspace = common.merge({
  autosave = false,
  autosave_interval = 10,
  config_spec = {
    name = "Workspace",
    {
      label = "Periodically Save Workspace", path = "autosave", type = "toggle",
      default = false,
      description = "Keep temporary recovery snapshots of open tabs and unsaved text without saving document files.",
      on_apply = function() if reschedule then reschedule() end end
    },
    {
      label = "Save Interval", path = "autosave_interval", type = "number",
      default = 10, min = 1, step = 1,
      description = "Seconds between temporary workspace saves.",
      on_apply = function() if reschedule then reschedule() end end
    }
  }
}, config.plugins.workspace)

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


local function session_path(module, key)
  return USERDIR .. PATHSEP .. "storage" .. PATHSEP .. module .. (key and PATHSEP .. key or "")
end

---Keep directory names readable and IDs stable across Lua and LuaJIT builds.
---Changing these hashes requires migrating existing project directories.
local function project_module(path)
  path = path_for_comparison(path)
  if project_modules[path] then return project_modules[path] end
  local first, second = 5381, 0
  for i = 1, #path do
    local byte = path:byte(i)
    first = (first * 33 + byte) % 4294967296
    second = (second * 65599 + byte) % 4294967296
  end
  local name = common.basename(path):usub(1, 40):gsub('[%c<>:"/\\|?*]', "_")
  local base = STORAGE_MODULE .. PATHSEP .. name .. "-" .. string.format("%08x%08x", first, second)
  local module, suffix = base, 1
  while system.get_file_info(session_path(module)) do
    local owner = storage.load(module, "main")
    if type(owner) ~= "table" or type(owner.path) ~= "string" then owner = storage.load(module, "recovery") end
    if type(owner) ~= "table" or type(owner.path) ~= "string" then
      for _, key in ipairs(storage.keys(module)) do
        if key:match("^session%-") then
          owner = storage.load(module, key)
          if type(owner) == "table" and type(owner.path) == "string" then break end
        end
      end
    end
    if type(owner) == "table" and type(owner.path) == "string" and path_for_comparison(owner.path) == path then break end
    -- Keep existing directories intact, including an unreadable saved session.
    module, suffix = base .. "-" .. suffix, suffix + 1
  end
  project_modules[path] = module
  return module
end

local function session_module()
  local project = core.root_project()
  if current_project ~= project then
    current_project, current_module, active_key, revision = project, project_module(project.path), nil, nil
  end
  return current_module
end

local function named_session_key(name)
  if type(name) ~= "string" or not name:find("%S") or name:find("%c") then return end
  local key = "session-" .. name:gsub("[^%w_%-]", function(char)
    return string.format("%%%02X", char:byte())
  end)
  if #key <= 240 then return key end
end

local function is_session_key(key)
  return type(key) == "string" and (key == "main" or key:match("^session%-[%w_%%%-]+$") ~= nil)
end

local function same_session_key(a, b)
  return a == b or PLATFORM == "Windows" and type(a) == "string" and type(b) == "string"
    and a:ulower() == b:ulower()
end

local function session_name(key)
  if key == "main" then return "Main Session" end
  return key:sub(9):gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
end

---Load only the requested file, never enumerate unrelated projects or snapshots.
local function read_session(key)
  if key ~= "recovery" and not is_session_key(key) then return end
  local ok, session = core.try(storage.load, session_module(), key)
  if ok and type(session) == "table" and type(session.path) == "string"
    and path_for_comparison(session.path) == path_for_comparison(core.root_project().path)
  then
    return session
  end
end

local function active_session_key(main)
  local module = session_module()
  if not active_key then
    main = main or read_session("main")
    local key = main and main.active_session
    local info = is_session_key(key) and system.get_file_info(session_path(module, key))
    active_key = info and info.type == "file" and key or "main"
  end
  return active_key
end

---Keep selection in the existing main file while preserving its saved layout.
local function activate_session(key, fallback)
  local main = read_session("main")
  if main or fallback then
    if not main or not same_session_key(main.active_session, key) then
      main = common.merge({}, main or fallback)
      main.name, main.active_session = nil, key
      if not storage.save(session_module(), "main", main) then return false end
    end
  end
  active_key, revision = key, nil
  return true
end

-- BEGIN LEGACY SESSION MIGRATION
-- Temporary upgrade from flat ws/ and ws-temp/ files. Remove this block and
-- its core.run call after a future release has shipped the directory layout.
local function migrate_sessions()
  if storage.load(STORAGE_MODULE, ".migrated") then return end
  local records, complete = {}, true
  for _, module in ipairs { STORAGE_MODULE, "ws-temp" } do
    for _, key in ipairs(storage.keys(module)) do
      local info = system.get_file_info(session_path(module, key))
      if info and info.type == "file" and key:match("%-%d+$") then
        local ok, session = core.try(storage.load, module, key)
        if ok and type(session) == "table" and type(session.path) == "string" and session.path ~= "" then
          records[#records + 1] = { module = module, key = key, path = session.path, name = session.name,
            saved_at = session.saved_at or info.modified or 0 }
        elseif not ok or session == nil then
          complete = false
        end
      end
    end
  end
  table.sort(records, function(a, b)
    if a.module ~= b.module then return a.module == STORAGE_MODULE end
    if a.saved_at ~= b.saved_at then return a.saved_at > b.saved_at end
    return a.key < b.key
  end)
  for _, record in ipairs(records) do
    local module = project_module(record.path)
    local directory = session_path(module)
    local key = record.module == STORAGE_MODULE and "main" or "recovery"
    if record.module == STORAGE_MODULE and record.name or system.get_file_info(session_path(module, key)) then
      local name = record.name or "Session " .. record.key:match("(%d+)$")
      key = named_session_key(name) or named_session_key("Session " .. record.key:match("(%d+)$"))
      local original, suffix = key, 2
      while system.get_file_info(session_path(module, key)) do
        key, suffix = original .. "-" .. suffix, suffix + 1
      end
    end
    local ok, err = true, nil
    if not system.get_file_info(directory) then ok, err = common.mkdirp(directory) end
    if ok then ok, err = os.rename(session_path(record.module, record.key), session_path(module, key)) end
    if not ok then
      complete = false
      core.warn("Could not migrate workspace session '%s': %s", record.key, err)
    end
  end
  if complete then storage.save(STORAGE_MODULE, ".migrated", true) end
end
-- END LEGACY SESSION MIGRATION

---@class plugins.workspace.session
---@field key string Filename within this project's storage directory
---@field name string Display name derived from the filename
---@field saved_at? integer File modification timestamp
---@field active boolean Whether this is the current session

---List only this project's filenames and timestamps, without loading buffers.
function workspace.get_sessions()
  local module = session_module()
  local active = active_session_key()
  local sessions = {}
  for _, key in ipairs(storage.keys(module)) do
    if is_session_key(key) then
      local info = system.get_file_info(session_path(module, key))
      if info and info.type == "file" then
        sessions[#sessions + 1] = { key = key, name = session_name(key), saved_at = info.modified,
          active = same_session_key(key, active) }
      end
    end
  end
  table.sort(sessions, function(a, b)
    if a.key == "main" then return b.key ~= "main" end
    if b.key == "main" then return false end
    return a.name:ulower() < b.name:ulower()
  end)
  return sessions
end

---Remove one saved session, returning to main if it was active.
function workspace.remove_session(key)
  if pending_project or not is_session_key(key) then return false end
  local module = session_module()
  local info = system.get_file_info(session_path(module, key))
  if not info or info.type ~= "file" then return false end
  local active = same_session_key(key, active_session_key())
  if active and key ~= "main" and not activate_session("main") then return false end
  storage.clear(module, key)
  if active then storage.clear(module, "recovery"); active_key, revision = "main", nil end
  return true
end

---Clear this project's saved sessions and recovery file, preserving open tabs.
function workspace.clear_sessions()
  if pending_project then return 0 end
  local count = 0
  for _, session in ipairs(workspace.get_sessions()) do
    if workspace.remove_session(session.key) then count = count + 1 end
  end
  storage.clear(session_module(), "recovery")
  active_key, revision = "main", nil
  return count
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
local function save_view(view, metadata)
  local state
  -- DocView:get_state copies untitled text. Compare inexpensive metadata first.
  if metadata and view.doc and view.get_state == DocView.get_state then
    local doc = view.doc
    state = {
      filename = doc.filename, abs_filename = doc.abs_filename,
      suggested_extension = doc.suggested_extension,
      selection = { table.unpack(doc.selections) },
      scroll = { x = view.scroll.to.x, y = view.scroll.to.y },
      change_id = doc:get_change_id(), dirty = doc:is_dirty(),
      encoding = doc.encoding, bom = doc.bom, crlf = doc.crlf, new_file = doc.new_file,
      document = doc
    }
  else
    state = view:get_state()
  end
  local module = view:get_module()
  if state and module then
    return {
      module = module,
      active = (core.active_view == view),
      state = state,
      unsaved = not metadata and view.doc and view.doc:is_dirty() and {
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
local function save_node(node, metadata)
  local res = {}
  res.type = node.type
  if node.type == "leaf" then
    res.views = {}
    for _, view in ipairs(node.views) do
      local t = save_view(view, metadata)
      if t then
        table.insert(res.views, t)
        if node.active_view == view then
          res.active_view = #res.views
        end
      end
    end
  else
    res.divider = node.divider
    res.a = save_node(node.a, metadata)
    res.b = save_node(node.b, metadata)
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


local function equal(a, b)
  if a == b then return true end
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  if getmetatable(a) or getmetatable(b) then return false end
  for key, value in pairs(a) do if not equal(value, b[key]) then return false end end
  for key in pairs(b) do if a[key] == nil then return false end end
  return true
end

local function snapshot(metadata)
  local root = get_unlocked_root(core.root_view.root_node)
  if root then
    return {
      path = core.root_project().path, documents = save_node(root, metadata),
      directories = save_directories(), visited_files = { table.unpack(core.visited_files) }
    }
  end
end

---Save to the active session, or save under a new name and activate it.
local function save_workspace(name)
  if pending_project then return end
  local module = session_module()
  local key = name == nil and active_session_key() or named_session_key(name)
  if not key then core.error("Invalid session name or name is too long"); return end
  local value = snapshot()
  if not value then return end
  value.name, value.saved_at = key ~= "main" and session_name(key) or nil, os.time()
  if key == "main" then value.active_session = "main" end
  if storage.save(module, key, value) then
    if key ~= "main" and not activate_session(key, value) then return end
    active_key, revision = key, nil
    storage.clear(module, "recovery")
    return key
  end
end

local function save_temporary()
  if pending_project or core.quit_request or core.restart_request then return end
  local module = session_module()
  local state = snapshot(true)
  if not state or equal(state, revision) then return end
  local value = snapshot()
  value.saved_at, value.session_key = os.time(), active_session_key()
  if storage.save(module, "recovery", value) then revision = state end
end

---No periodic coroutine exists while the opt-in setting is disabled.
reschedule = function()
  if not started then return end
  if core.threads[scheduler_key] then
    core.threads[scheduler_key] = nil
    core.background_threads = core.background_threads - 1
  end
  revision = nil
  if config.plugins.workspace.autosave then
    core.add_background_thread(function()
      while config.plugins.workspace.autosave do
        coroutine.yield(math.max(1, config.plugins.workspace.autosave_interval))
        if config.plugins.workspace.autosave then core.try(save_temporary) end
      end
    end, scheduler_key)
  end
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
      local session, key = read_session("recovery"), nil
      if session then
        key = is_session_key(session.session_key) and session.session_key or active_session_key()
      else
        local main = read_session("main")
        key = active_session_key(main)
        session = key == "main" and main or read_session(key)
        if not session then key, session = "main", main end
      end
      if session then
        if session.visited_files then
          core.visited_files = session.visited_files
        end
        local root = get_unlocked_root(core.root_view.root_node)
        local active_view = load_node(root, session.documents)
        if active_view then
          core.set_active_view(active_view)
        end
        load_directories(session.directories or {})
      end
      active_key = key
    end)
    if pending_project == project then
      pending_project = nil
    end
  end)
end


---Save the current workspace. A name saves and activates an additional session.
---@param name? string Label for a new saved session; omit to update the active session.
---@return string? key Storage key, or nil if saving is pending or failed.
function workspace.save_session(name)
  return save_workspace(name)
end


---Replace the current document layout with a saved session and back up the outgoing one.
---Subsequent saves and checkpoints belong to the selected session.
---A failed backup or restore leaves the current layout and selected session intact.
---@param key string Original key from get_sessions()
---@return boolean loaded Whether the requested session was restored
function workspace.load_session(key)
  if pending_project or core.restart_request or core.quit_request then return false end
  local project = core.root_project()
  local session = read_session(key)
  local root = get_unlocked_root(core.root_view.root_node)
  if not session or not root then return false end
  -- Keep an in-memory copy before saving: the selected key can be the main key.
  session = common.merge({}, session)
  local target = key == "recovery"
    and (is_session_key(session.session_key) and session.session_key or active_session_key()) or key
  session.session_key, session.active_session = target, nil
  if not save_workspace() then return false end

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

  if not storage.save(session_module(), "recovery", session) then
    for _, doc in ipairs(restored_docs) do doc:on_close() end
    return false
  end
  if not activate_session(target, session) then
    storage.clear(session_module(), "recovery")
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
  revision = nil
  core.redraw = true
  return true
end


---Format a session's active status and save time for command suggestions.
---@param session plugins.workspace.session Saved session metadata
---@return string info Description without reading the snapshot again
local function session_info(session)
  local time = session.saved_at and os.date("%Y-%m-%d %H:%M", session.saved_at) or ""
  return session.active and ("Active" .. (time ~= "" and " · " .. time or "")) or time
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
        and read_session(item.key) ~= nil
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
  ["workspace:save-session"] = function() workspace.save_session() end,
  ["workspace:save-session-as"] = function()
    local project = core.root_project()
    core.command_view:enter("Save Session As", {
      validate = function(text) return core.root_project() == project and named_session_key(text) ~= nil end,
      submit = function(text)
        if core.root_project() == project and named_session_key(text) then workspace.save_session(text) end
      end
    })
  end,
  ["workspace:recover-session"] = function() workspace.load_session("recovery") end,
  ["workspace:remove-session"] = function() choose_session(true) end,
  ["workspace:clear-sessions"] = function()
    local project = core.root_project()
    local count = #workspace.get_sessions()
    if count == 0 and not system.get_file_info(session_path(session_module(), "recovery")) then
      core.log("No saved sessions for %s", project.path); return
    end
    core.nag_view:show("Clear Saved Sessions",
      string.format("Remove all saved sessions and recovery data for %s? Open tabs will stay open.", project.path),
      { { text = "Clear Sessions" }, { text = "Cancel", default_no = true } }, function(option)
        if option.text == "Clear Sessions" and core.root_project() == project then workspace.clear_sessions() end
      end)
  end
})

core.menu_view:register({ "file" }, {
  { id = "sessions", text = "Sessions", items = function()
    local items = {
      { id = "save", text = "Save Session", command = "workspace:save-session" },
      { id = "save-as", text = "Save Session As…", command = "workspace:save-session-as" },
      { id = "load", text = "Load Session…", command = "workspace:load-session" },
      { id = "recover", text = "Recover Session", command = "workspace:recover-session" },
      { id = "remove", text = "Remove Session…", command = "workspace:remove-session" },
      { id = "clear", text = "Clear Saved Sessions…", command = "workspace:clear-sessions" }
    }
    local sessions = workspace.get_sessions()
    if #sessions > 0 then items[#items + 1] = core.menu_view.DIVIDER end
    local project = core.root_project()
    for _, session in ipairs(sessions) do
      items[#items + 1] = {
        id = session.key, text = session.name, info = session_info(session),
        checked = function()
          return core.root_project() == project and same_session_key(active_session_key(), session.key)
        end,
        command = function()
          if core.root_project() == project then command.perform("workspace:load-session", session.key) end
        end
      }
    end
    return items
  end }
}, "workspace")


local run = core.run

-- Explicit startup files skip restoration, but can still use periodic recovery.
function core.run(...)
  core.try(migrate_sessions) -- Remove with the temporary legacy migration block.
  core.try(session_module)
  if #core.docs == 0 then core.try(load_workspace) else core.try(active_session_key) end

  local set_project = core.set_project
  function core.set_project(project)
    core.try(save_workspace)
    project = set_project(project)
    core.try(load_workspace)
    return project
  end
  local exit = core.exit
  function core.exit(quit_fn, force)
    if force then core.try(save_workspace) end
    exit(quit_fn, force)
  end

  started = true
  reschedule()
  core.run = run
  return core.run(...)
end

return workspace
