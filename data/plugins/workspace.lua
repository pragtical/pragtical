-- mod-version:3
local core = require "core"
local common = require "core.common"
local storage = require "core.storage"

local STORAGE_MODULE = "ws"

local function workspace_keys_for(project_dir)
  local basename = common.basename(project_dir)
  return coroutine.wrap(function()
    for _, key in ipairs(storage.keys(STORAGE_MODULE) or {}) do
      if key:sub(1, #basename) == basename then
        local id = tonumber(key:sub(#basename + 1):match("^-(%d+)$"))
        if id then
          coroutine.yield(key, id)
        end
      end
    end
  end)
end


local function consume_workspace(project_dir)
  for key, id in workspace_keys_for(project_dir) do
    local workspace = storage.load(STORAGE_MODULE, key)
    if workspace and workspace.path == project_dir then
      storage.clear(STORAGE_MODULE, key)
      return workspace
    end
  end
end


local function has_no_locked_children(node)
  if node.locked then return false end
  if node.type == "leaf" then return true end
  return has_no_locked_children(node.a) and has_no_locked_children(node.b)
end


local function get_unlocked_root(node)
  if node.type == "leaf" then
    return not node.locked and node
  end
  if has_no_locked_children(node) then
    return node
  end
  return get_unlocked_root(node.a) or get_unlocked_root(node.b)
end


---@param view core.view
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


local function save_directories()
  local project_dir = core.root_project().path
  local dir_list = {}
  for i = 2, #core.projects do
    dir_list[#dir_list + 1] = common.relative_path(project_dir, core.projects[i].path)
  end
  return dir_list
end


local function save_workspace()
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


local function load_workspace()
  core.add_thread(function()
    local workspace = consume_workspace(core.root_project().path)
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
end


local run = core.run

function core.run(...)
  if #core.docs == 0 then
    core.try(load_workspace)

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

  end

  core.run = run
  return core.run(...)
end
