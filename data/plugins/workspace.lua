-- mod-version:3
local core = require "core"
local common = require "core.common"
local storage = require "core.storage"

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
    return View and View.from_state(t.state)
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


---Collects additional project directories relative to the root project.
---@return string[] directories
local function save_directories()
  local project_dir = core.root_project().path
  local dir_list = {}
  for i = 2, #core.projects do
    dir_list[#dir_list + 1] = common.relative_path(project_dir, core.projects[i].path)
  end
  return dir_list
end


---Saves the current layout, project directories, and visited files to a free key.
---Does nothing while restoration is pending, before the layout is ready to save.
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
  storage.save(STORAGE_MODULE, project_dir .. "-" .. id, {
    path = core.root_project().path,
    documents = save_node(root),
    directories = save_directories(),
    visited_files = core.visited_files
  })
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
        for _, dir_name in ipairs(workspace.directories) do
          core.add_project(system.absolute_path(dir_name))
        end
      end
    end)
    if pending_project == project then
      pending_project = nil
    end
  end)
end


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
