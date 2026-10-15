local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local core = require "core"
local keymap = require "core.keymap"
local test = require "core.test"
local DocView = require "core.docview"
local Project = require "core.project"
local projectsearch = require "plugins.projectsearch"
local SearchReplaceList = require "widget.searchreplacelist"
local Doc = require "core.doc"
local treeview = require "plugins.treeview"
local scale = require "plugins.scale"
local style = require "core.style"

---Wait for global search's deferred focus and settle its widget layout.
---@param view plugins.projectsearch.resultsview Shown global search
---@param target core.view Expected keyboard target
local function settle_focus(view, target)
  for _ = 1, 20 do
    core.root_view:update()
    if core.active_view == target then return end
    coroutine.yield(0)
  end
  test.equal(core.active_view, target)
end

local split_click_modifier = PLATFORM == "Mac OS X" and "cmd" or "ctrl"

local function join_path(...)
  return table.concat({...}, PATHSEP)
end

local function write_file(path, content)
  local file, err = io.open(path, "wb")
  test.not_nil(file, err)
  file:write(content)
  file:close()
end

local function collect_worker_results(tid, workers)
  local files = {}
  for id = 1, workers do
    local channel = thread.get_channel("projectsearch_results"..tid..":"..id)
    local value = channel:first()
    while value ~= nil do
      if type(value) == "table" then
        for _, result in ipairs(value) do
          files[#files + 1] = {
            path = result[1],
            display_path = result[3],
            lines = result[2]
          }
        end
      end
      channel:pop()
      value = channel:first()
    end
  end
  return files
end

local function path_is_in_test_root(context, path)
  if not path then return false end
  path = common.normalize_path(path)
  local root = common.normalize_path(context.temp_root)
  return path == root or common.path_belongs_to(path, root)
end

local function close_test_views_and_docs(context)
  local views = core.root_view.root_node:get_children()
  for i = #views, 1, -1 do
    local view = views[i]
    local path = view.path or (view.doc and view.doc.abs_filename)
    if path_is_in_test_root(context, path) then
      local node = core.root_view.root_node:get_node_for_view(view)
      if node and not node.locked then
        if view:extends(DocView) and view.doc:is_dirty() then
          view.doc:clean()
        end
        node:remove_view(core.root_view.root_node, view)
      end
    end
  end

  for i = #core.docs, 1, -1 do
    local doc = core.docs[i]
    if path_is_in_test_root(context, doc.abs_filename) then
      table.remove(core.docs, i)
      doc:on_close()
    end
  end
end


local function add_result(view, path, text, col1, col2)
  view.results_list:add_file(path, {
    {
      line = 1,
      text = text,
      positions = {{ col1 = col1, col2 = col2 }}
    }
  }, true)
  view.results_list.selected = #view.results_list.items
  return view.results_list:get_selected()
end


local function create_results_view(context)
  local source = core.open_file(join_path(context.project_a, "main.txt"))
  local node = core.root_view.root_node:get_node_for_view(source)
  local view = projectsearch.ResultsView(context.project_a, "needle", "plain")
  view.source_view = source
  view:show()
  node:add_view(view)
  return view, source
end

local function get_open_doc_view(path)
  path = common.normalize_path(path)
  for _, view in ipairs(core.root_view.root_node:get_children()) do
    if
      view:extends(DocView) and view.doc.abs_filename
      and common.normalize_path(view.doc.abs_filename) == path
    then
      return view
    end
  end
end

test.describe("projectsearch saving", function()
  test.before_each(function(context)
    context.active_view = core.active_view
    context.last_active_view = core.last_active_view
    context.next_active_view = core.next_active_view
    context.enter = core.command_view.enter
    context.modkeys = keymap.modkeys
    context.path = core.temp_filename(".txt")
    write_file(context.path, "original\n")
    context.doc = Doc(context.path, context.path)
    context.doc:insert(1, 1, "edited ")
    core.set_active_view(DocView(context.doc))
    context.view = projectsearch.ResultsView(nil, "needle", "plain", nil, nil, "replacement")
    context.view.filters_toggle:set_toggle(true)
    context.view:show()
    core.command_view.enter = function() context.prompted = true end
    keymap.modkeys = { [PLATFORM == "Mac OS X" and "cmd" or "ctrl"] = true }
  end)

  test.after_each(function(context)
    if context.view then
      context.view:swap_active_child()
      context.view:hide()
    end
    core.command_view.enter = context.enter
    keymap.modkeys = context.modkeys
    core.active_view = context.active_view
    core.last_active_view = context.last_active_view
    core.next_active_view = context.next_active_view
    context.doc:on_close()
    os.remove(context.path)
  end)

  for _, field in ipairs { "find_text", "replace_text", "includes_text", "excludes_text" } do
    test.test("Save and Save As ignore " .. field, function(context)
      local input = context.view[field]
      input:set_text("needle")
      context.view:swap_active_child(input)
      test.equal(core.active_view, input.textview)

      for _, save_as in ipairs { false, true } do
        keymap.modkeys.shift = save_as
        test.not_ok(keymap.on_key_pressed("s"))
        test.not_ok(command.perform(save_as and "doc:save-as" or "doc:save"))
        test.is_nil(context.prompted)
        test.equal(core.active_view, input.textview)
        test.is_nil(input.textview.doc.filename)
        test.equal(input:get_text(), "needle")
        test.ok(context.doc:is_dirty())
        local file = assert(io.open(context.path, "rb"))
        local text = file:read("*a")
        file:close()
        test.equal(text, "original\n")
      end
    end)
  end
end)

test.describe("projectsearch mouse selection", function()
  test.before_each(function(context)
    context.active_view = core.active_view
    context.last_active_view = core.last_active_view
    context.next_active_view = core.next_active_view
    context.modkeys = keymap.modkeys
    context.transitions = config.transitions
    keymap.modkeys = {}
    config.transitions = false
    context.view = projectsearch.ResultsView(nil, "", "plain", nil, nil, "")
    context.view.filters_toggle:set_toggle(true)
    context.view:show()
    context.node = core.root_view:get_primary_node()
    context.node:add_view(context.view)
    for _ = 1, 3 do core.root_view:update() end
  end)

  test.after_each(function(context)
    context.view:hide()
    context.view:destroy_childs()
    context.node:remove_view(core.root_view.root_node, context.view)
    keymap.modkeys = context.modkeys
    config.transitions = context.transitions
    core.active_view = context.active_view
    core.last_active_view = context.last_active_view
    core.next_active_view = context.next_active_view
  end)

  for _, field in ipairs { "find_text", "replace_text", "includes_text", "excludes_text" } do
    test.test(field .. " retains captured edge selection through root events", function(context)
      local input = context.view[field]
      local view = input.textview
      test.ok(input:is_visible())
      input:set_text(string.rep("aé界 long input ", 80))
      view.doc:set_selection(1, 1)
      view.scroll.x, view.scroll.to.x = 0, 0
      input:update()
      local x, y = view:get_line_screen_position(1, 2)
      y = y + view:get_line_height() / 2
      core.on_event("mousepressed", "left", x, y, 1)
      test.equal(core.active_view, view)
      local right = input.position.x + input.size.x + 40
      core.on_event("mousemoved", right, y, right - x, 0)
      for _ = 1, 8 do input:update() end
      local _, col, _, anchor = view.doc:get_selection()
      test.ok(col > 2)
      test.equal(anchor, 2)
      test.ok(view.scroll.x > 0)
      core.on_event("mousereleased", "left", right, y)
      test.is_nil(core.root_view.grab)
      test.is_nil(context.view.captured_widget)
      test.not_ok(context.view.mouse_is_pressed)
      test.equal(core.active_view, view)
      test.not_ok(command.perform("doc:save"))
      test.not_ok(command.perform("doc:save-as"))
    end)
  end
end)

test.describe("projectsearch", function()
  test.before_each(function(context)
    context.old_position = config.plugins.projectsearch.position
    context.old_live_search = config.plugins.projectsearch.live_search
    context.old_workers = config.plugins.projectsearch.threading.workers
    context.old_transitions = config.transitions
    context.old_tree_visible = treeview.visible
    context.old_toolbar_position = treeview.toolbar_position
    context.root_size = { x = core.root_view.size.x, y = core.root_view.size.y }
    context.old_active = core.active_view
    config.transitions = false
    context.old_projects = core.projects
    context.old_cwd = system.getcwd() or core.root_project().path
    context.temp_root = join_path(
      USERDIR,
      "projectsearch-tests-" .. system.get_process_id()
        .. "-" .. math.floor(system.get_time() * 1000000)
    )
    context.project_a = join_path(context.temp_root, "alpha")
    context.project_b = join_path(context.temp_root, "beta")
    test.ok(common.mkdirp(join_path(context.project_a, "src")))
    test.ok(common.mkdirp(join_path(context.project_b, "lib")))
    write_file(join_path(context.project_a, "src", "one.txt"), "needle one\n")
    write_file(join_path(context.project_b, "lib", "two.txt"), "needle two\n")
    write_file(join_path(context.project_b, "lib", "skip.txt"), "other\n")
    write_file(join_path(context.project_a, "main.txt"), "main document\n")
    local project_a = Project(context.project_a)
    local project_b = Project(context.project_b)
    project_a.name = "alpha"
    project_b.name = "beta"
    core.projects = { project_a, project_b }
    context.old_split_direction = config.plugins.projectsearch.split_direction
    context.modkeys = keymap.modkeys
    keymap.modkeys = {}
    context.locked_nodes = {}
    context.old_thread_create = thread.create
  end)

  test.after_each(function(context)
    local global = projectsearch._test.get_global_project_search()
    if global then
      if global.searching then
        global:stop_search()
        for _ = 1, 200 do
          if not global.searching then break end
          coroutine.yield(0.01)
        end
      end
      if context.old_begin_search then global.begin_search = context.old_begin_search end
      projectsearch.hide()
    end
    config.plugins.projectsearch.live_search = context.old_live_search
    config.plugins.projectsearch.threading.workers = context.old_workers
    if context.old_scale then
      scale.set(context.old_scale)
      for _, saved in ipairs(context.scale_values) do saved[1][saved[2]] = saved[3] end
      for font, size in pairs(context.font_sizes) do font:set_size(size) end
      system.setenv("PRAGTICAL_SCALE", context.scale_env)
    end
    projectsearch.set_position(context.old_position)
    treeview:set_toolbar_position(context.old_toolbar_position)
    treeview.visible = context.old_tree_visible
    core.root_view.size.x, core.root_view.size.y = context.root_size.x, context.root_size.y
    config.transitions = context.old_transitions
    thread.create = context.old_thread_create
    keymap.modkeys = context.modkeys
    config.plugins.projectsearch.split_direction = context.old_split_direction
    for _, node in ipairs(context.locked_nodes) do
      node.locked = nil
    end
    close_test_views_and_docs(context)
    if context.old_active and core.root_view.root_node:get_node_for_view(context.old_active) then
      core.set_active_view(context.old_active)
    end
    core.projects = context.old_projects
    system.chdir(context.old_cwd)
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  test.test("uses all open projects when no path is provided", function(context)
    local roots, multiple, base_dir = projectsearch._test.get_search_roots()

    test.equal(#roots, 2)
    test.equal(multiple, true)
    test.equal(base_dir, context.project_a)
    test.equal(roots[1].path, context.project_a)
    test.equal(roots[1].display_prefix, "alpha")
    test.equal(roots[2].path, context.project_b)
    test.equal(roots[2].display_prefix, "beta")
  end)

  test.test("uses one root when an explicit path is provided", function(context)
    local roots, multiple, base_dir = projectsearch._test.get_search_roots(
      context.project_b
    )

    test.equal(#roots, 1)
    test.equal(multiple, false)
    test.equal(base_dir, context.project_b)
    test.equal(roots[1].path, context.project_b)
    test.equal(roots[1].display_prefix, nil)
  end)

  test.test("single project default keeps root-project behavior", function(context)
    core.projects = {{ path = context.project_a, name = "alpha" }}

    local roots, multiple, base_dir = projectsearch._test.get_search_roots()

    test.equal(#roots, 1)
    test.equal(multiple, false)
    test.equal(base_dir, context.project_a)
    test.equal(roots[1].path, context.project_a)
    test.equal(roots[1].display_prefix, nil)
  end)

  test.test("worker searches multiple project roots", function(context)
    local tid = 500000 + system.get_process_id()
    local workers = 1
    local roots = projectsearch._test.get_search_roots()

    projectsearch._test.files_search_thread(tid, {
      text = "needle",
      search_type = "plain",
      insensitive = false,
      whole_word = false,
      pathsep = PATHSEP,
      ignore_files = {},
      workers = workers,
      file_size_limit = config.file_size_limit * 1e6,
      roots = roots
    })

    local files = collect_worker_results(tid, workers)
    table.sort(files, function(a, b) return a.display_path < b.display_path end)

    test.equal(#files, 2)
    test.equal(files[1].display_path, "alpha" .. PATHSEP .. "src" .. PATHSEP .. "one.txt")
    test.equal(files[2].display_path, "beta" .. PATHSEP .. "lib" .. PATHSEP .. "two.txt")
    test.equal(files[1].lines[1][2], 1)
    test.equal(files[1].lines[1][3][1].col1, 1)
    test.equal(files[1].lines[1][3][1].col2, 6)
  end)

  test.test("cancelled searches wake and join idle workers", function(context)
    for iteration = 1, 5 do
      local tid = 600000 + iteration
      local stop = thread.get_channel("projectsearch_stop" .. tid)
      local status = thread.get_channel("projectsearch_status" .. tid)
      stop:push("stop")
      local created = {}
      thread.create = function(...)
        local worker = assert(context.old_thread_create(...))
        created[#created + 1] = worker
        return worker
      end
      projectsearch._test.files_search_thread(tid, {
        text = "needle", search_type = "plain", pathsep = PATHSEP,
        ignore_files = {}, workers = 6, file_size_limit = 1e6,
        roots = {{path = context.project_b}}
      })
      test.equal(status:first(), "cancelled")
      test.equal(#created, 6)
      for _, worker in ipairs(created) do
        test.is_nil(worker:get_id(), "worker was not joined before completion")
      end
    end
  end)

  test.test("worker creation failure cleans up previously started workers", function(context)
    local tid = 700000
    local status = thread.get_channel("projectsearch_status" .. tid)
    local first
    thread.create = function(...)
      if first then return nil, "injected creation failure" end
      first = assert(context.old_thread_create(...))
      return first
    end
    projectsearch._test.files_search_thread(tid, {
      text = "needle", search_type = "plain", pathsep = PATHSEP,
      ignore_files = {}, workers = 3, file_size_limit = 1e6,
      roots = {{path = context.project_b}}
    })
    test.equal(status:first().error, "injected creation failure")
    test.is_nil(first:get_id())
  end)

  test.test("result list keeps absolute path and display path", function(context)
    local list = SearchReplaceList(nil)
    local absolute_path = join_path(context.project_a, "src", "one.txt")
    local display_path = "alpha" .. PATHSEP .. "src" .. PATHSEP .. "one.txt"

    list:add_file(absolute_path, {}, true, display_path)

    test.equal(list.items[1].file.path, absolute_path)
    test.equal(list.items[1].file.display_path, display_path)
  end)

  test.test("opens split results in every configured direction", function(context)
    local view = create_results_view(context)
    add_result(
      view,
      join_path(context.project_a, "src", "one.txt"),
      "needle one", 1, 6
    )

    local modes = {
      { value = "right", direction = "right" },
      { value = "left", direction = "left" },
      { value = "up", direction = "up" },
      { value = "down", direction = "down" },
      { value = "invalid", direction = "right" }
    }
    for _, mode in ipairs(modes) do
      config.plugins.projectsearch.split_direction = mode.value
      view:open_selected_result(true)

      local result = view.result_split_views[#view.result_split_views]
      local result_node = core.root_view.root_node:get_node_for_view(result)
      local parent = result_node:get_parent_node(core.root_view.root_node)
      local horizontal = mode.direction == "left" or mode.direction == "right"
      local expected_child = (mode.direction == "left" or mode.direction == "up")
        and parent.a or parent.b
      test.equal(parent.type, horizontal and "hsplit" or "vsplit", mode.value)
      test.equal(expected_child, result_node, mode.value)

      local line1, col1, line2, col2 = result.doc:get_selection(true)
      test.equal(line1, 1)
      test.equal(col1, 1)
      test.equal(line2, 1)
      test.equal(col2, 7)
      test.ok(result.doc:is_search_selection(1, 1, 1, 7))

      result_node:remove_view(core.root_view.root_node, result)
      view.result_split_node = nil
      view.result_split_views = {}
    end
  end)

  test.test("reuses and recreates each search result split", function(context)
    local view = create_results_view(context)
    local first_item = add_result(
      view,
      join_path(context.project_a, "src", "one.txt"),
      "needle one", 1, 6
    )
    local second_item = add_result(
      view,
      join_path(context.project_b, "lib", "two.txt"),
      "needle two", 1, 6
    )

    view.results_list.selected = 2
    view:open_selected_result(true)
    local first_view = view.result_split_views[#view.result_split_views]
    local first_node = core.root_view.root_node:get_node_for_view(first_view)

    view.results_list.selected = 4
    test.equal(view.results_list:get_selected(), second_item)
    view:open_selected_result(true)
    local second_view = view.result_split_views[#view.result_split_views]
    local second_node = core.root_view.root_node:get_node_for_view(second_view)
    test.equal(second_node, first_node)
    test.equal(#second_node.views, 2)

    view.results_list.selected = 2
    test.equal(view.results_list:get_selected(), first_item)
    view:open_selected_result(true)
    test.equal(view.result_split_views[#view.result_split_views], first_view)
    test.equal(#first_node.views, 2)
    test.equal(core.active_view, first_view)

    first_node:remove_view(core.root_view.root_node, first_view)
    local remaining_node = core.root_view.root_node:get_node_for_view(second_view)
    remaining_node:remove_view(core.root_view.root_node, second_view)

    view:open_selected_result(true)
    local recreated_view = view.result_split_views[#view.result_split_views]
    local recreated_node = core.root_view.root_node:get_node_for_view(recreated_view)
    test.not_equal(recreated_node, first_node)
  end)

  test.test("recreates a split after its source pane collapses", function(context)
    local root = core.root_view.root_node
    local view, source = create_results_view(context)
    local source_node = root:get_node_for_view(source)
    source_node:remove_view(root, view)
    local search_node = source_node:split(
      "left", view, { x = true }, true
    )
    table.insert(context.locked_nodes, search_node)

    add_result(
      view,
      join_path(context.project_a, "src", "one.txt"),
      "needle one", 1, 6
    )
    add_result(
      view,
      join_path(context.project_b, "lib", "two.txt"),
      "needle two", 1, 6
    )

    config.plugins.projectsearch.split_direction = "right"
    view.results_list.selected = 2
    view:open_selected_result(true)
    local first_result = view.result_split_views[#view.result_split_views]
    local original_result_node = root:get_node_for_view(first_result)

    local current_source_node = root:get_node_for_view(source)
    current_source_node:remove_view(root, source)
    local surviving_node = root:get_node_for_view(first_result)
    test.not_equal(surviving_node, original_result_node)
    test.equal(surviving_node.is_primary_node, true)

    core.set_active_view(view)
    view.results_list.selected = 4
    view:open_selected_result(true)
    local second_result = view.result_split_views[#view.result_split_views]
    local new_result_node = root:get_node_for_view(second_result)
    local old_result_node = root:get_node_for_view(first_result)
    local split_parent = new_result_node:get_parent_node(root)

    test.not_equal(new_result_node, old_result_node)
    test.equal(split_parent.type, "hsplit")
    test.equal(split_parent.a, old_result_node)
    test.equal(split_parent.b, new_result_node)
    test.equal(view.result_split_node, new_result_node)

    view.results_list.selected = 2
    view:open_selected_result(true)
    local reused_result = view.result_split_views[#view.result_split_views]
    test.equal(root:get_node_for_view(reused_result), new_result_node)
    test.not_equal(reused_result, first_result)
  end)

  test.test("routes modifier-left-click through the split command", function(context)
    local view = create_results_view(context)
    add_result(
      view,
      join_path(context.project_a, "src", "one.txt"),
      "needle one", 1, 6
    )
    local list = view.results_list
    list:set_position(0, 0)
    list:set_size(500, 500)

    keymap.modkeys[split_click_modifier] = false
    list.hovered = 2
    test.ok(view:on_mouse_pressed("left", 10, 10, 1))
    test.is_nil(view.result_split_node)
    local normal_view = core.active_view
    test.ok(normal_view:extends(DocView))
    test.equal(
      core.root_view.root_node:get_node_for_view(normal_view),
      core.root_view.root_node:get_node_for_view(view)
    )

    core.set_active_view(view)
    keymap.modkeys[split_click_modifier] = true
    list.hovered = 1
    test.ok(view:on_mouse_pressed("left", 10, 10, 1))
    test.is_nil(view.result_split_node)

    list.hovered = 2
    test.not_ok(view:on_mouse_pressed("left", 10, 10, 1))
    test.ok(command.is_valid("project-search:open-selected-split"))
    keymap.on_mouse_pressed("left", 10, 10, 1)
    test.not_nil(view.result_split_node)
    test.not_equal(
      core.root_view.root_node:get_node_for_view(core.active_view),
      core.root_view.root_node:get_node_for_view(view)
    )
  end)

  test.test("shows match actions in a right-click context menu", function(context)
    local view = create_results_view(context)
    local path = join_path(context.project_a, "src", "one.txt")
    add_result(view, path, "needle one", 1, 6)
    local list = view.results_list
    local menu = view.context_menu
    list:set_position(0, 0)
    list:set_size(500, 500)
    keymap.modkeys["ctrl"] = false

    list.hovered = 1
    test.ok(view:on_mouse_pressed("right", 10, 10, 1))
    test.equal(menu.show_context_menu, false)

    list.hovered = 0
    test.ok(view:on_mouse_pressed("right", 10, 10, 1))
    test.equal(menu.show_context_menu, false)

    list.hovered = 2
    test.ok(view:on_mouse_pressed("right", 10, 10, 1))
    test.equal(menu.show_context_menu, true)
    test.equal(list.selected, 2)
    test.equal(#menu.items, 2)
    test.equal(menu.items[1].text, "Open")
    test.equal(menu.items[1].command, "project-search:open-selected")
    test.equal(menu.items[2].text, "Open in Split")
    test.equal(
      menu.items[2].command, "project-search:open-selected-split"
    )
    test.is_nil(get_open_doc_view(path))

    core.on_event("mousemoved", menu.position.x + 1, menu.position.y + 1, 0, 0)
    test.equal(menu.selected, 1)
    core.on_event("mousemoved", -1, -1, 0, 0)
    core.on_event("mousepressed", "left", -1, -1, 1)
    test.equal(menu.show_context_menu, false)
    test.is_nil(get_open_doc_view(path))
  end)

  test.test("opens matches from the result context menu", function(context)
    local view = create_results_view(context)
    local path = join_path(context.project_a, "src", "one.txt")
    add_result(view, path, "needle one", 1, 6)
    local list = view.results_list
    local menu = view.context_menu
    list:set_position(0, 0)
    list:set_size(500, 500)
    list.hovered = 2
    keymap.modkeys["ctrl"] = false

    test.ok(view:on_mouse_pressed("right", 10, 10, 1))
    menu.selected = 1
    menu:call_selected_item()

    local normal_view = get_open_doc_view(path)
    test.not_nil(normal_view)
    test.equal(core.active_view, normal_view)
    test.equal(
      core.root_view.root_node:get_node_for_view(normal_view),
      core.root_view.root_node:get_node_for_view(view)
    )
    test.is_nil(view.result_split_node)

    core.set_active_view(view)
    list.hovered = 2
    test.ok(view:on_mouse_pressed("right", 10, 10, 1))
    menu.selected = 2
    menu:call_selected_item()

    local split_view = view.result_split_views[#view.result_split_views]
    test.not_nil(split_view)
    test.equal(core.active_view, split_view)
    test.not_equal(
      core.root_view.root_node:get_node_for_view(split_view),
      core.root_view.root_node:get_node_for_view(view)
    )
  end)

  test.test("preserves docked and tabbed search focus behavior", function(context)
    local view = create_results_view(context)
    add_result(
      view,
      join_path(context.project_a, "src", "one.txt"),
      "needle one", 1, 6
    )

    view:open_selected_result(true)
    test.ok(core.active_view:extends(DocView))

    view.is_global = true
    view:open_selected_result(true)
    test.equal(core.active_view, view)
    view.is_global = false
  end)

  test.test("global helpers return the global results view", function(context)
    local view = projectsearch.toggle({
      path = context.project_a,
      has_focus = false
    })

    test.not_nil(view)
    test.equal(view, projectsearch._test.get_global_project_search())
    test.equal(view:is_visible(), true)

    local hidden_view = projectsearch.hide({
      text = "hidden",
      path = context.project_b,
      run = true
    })

    test.equal(hidden_view, view)
    test.equal(view:is_visible(), false)
    test.equal(view.find_text:get_text(), "hidden")
    test.equal(view.file_picker:get_path(), context.project_b)
    test.equal(view.searching, false)

    local shown_view = projectsearch.show({
      path = context.project_b,
      text = "needle"
    })

    test.equal(shown_view, view)
    test.equal(shown_view:is_visible(), true)
    test.equal(shown_view.file_picker:get_path(), context.project_b)
    test.equal(shown_view.find_text:get_text(), "needle")
    test.equal(shown_view.searching, false)
  end)

  test.test("show applies search options", function(context)
    local view = projectsearch.show({
      text = "needle",
      path = context.project_a,
      insensitive = false,
      whole_word = true,
      replacement = "thread",
      search_type = "regex",
      filters = {
        includes = "src/**.txt",
        excludes = "vendor"
      }
    })

    test.equal(view.find_text:get_text(), "needle")
    test.equal(view.file_picker:get_path(), context.project_a)
    test.equal(view.sensitive_toggle:is_toggled(), true)
    test.equal(view.wholeword_toggle:is_toggled(), true)
    test.equal(view.replace_toggle:is_toggled(), true)
    test.equal(view.replace_text:get_text(), "thread")
    test.equal(view.regex_toggle:is_toggled(), true)
    test.equal(view.filters_toggle:is_toggled(), true)
    test.equal(view.includes_text:get_text(), "src/**.txt")
    test.equal(view.excludes_text:get_text(), "vendor")
  end)

  test.test("show defaults invalid search type to plain", function(context)
    local view = projectsearch.show({
      text = "needle",
      path = context.project_a,
      search_type = "pattern"
    })

    test.equal(view.regex_toggle:is_toggled(), false)
  end)

  test.test("show runs search only when requested", function(context)
    local view = projectsearch.show({
      text = "needle",
      path = context.project_a,
      run = true
    })

    test.equal(view.searching, true)
    view:stop_search()
  end)
  ---Prepare a global search without launching workers and optionally populate matches.
  ---@param context table Temporary project fixture
  ---@param position "left"|"right"|"center" Requested placement
  ---@param results? boolean Populate two files with one match each
  ---@return plugins.projectsearch.resultsview view Shown global search
  ---@return core.docview source Original document view
  local function global_search(context, position, results)
    local source = core.open_file(join_path(context.project_a, "main.txt"))
    source.doc:set_selection(1, 1)
    projectsearch.hide()
    projectsearch.set_position(position)
    local view = projectsearch.show({ text = "needle", path = context.project_a })
    view.results_list:clear()
    view.query = "needle"
    view.replaced = false
    view.replace_toggle:set_toggle(false)
    view.filters_toggle:set_toggle(false)
    view.total_files_processed = nil
    if results then
      add_result(view, join_path(context.project_a, "src", "one.txt"), "needle one", 1, 6)
      add_result(view, join_path(context.project_b, "lib", "two.txt"), "needle two", 1, 6)
      view.results_list.selected = 2
      view.total_files, view.total_files_processed = 2, 2
      view.start_time, view.end_time = 0, 0
    end
    settle_focus(view, view.find_text.textview)
    core.root_view:update()
    return view, source
  end

  test.test("centered live search keeps its surface and border visible between results", function(context)
    local view = global_search(context, "center", true)
    view.regex_toggle:set_toggle(false)
    view.wholeword_toggle:set_toggle(false)
    view.find_text:set_text("nee")
    view.find_text.textview.doc:set_selection(1, 4)
    config.plugins.projectsearch.live_search = true
    config.plugins.projectsearch.threading.workers = 1
    local frames = {}
    context.old_begin_search = view.begin_search
    view.begin_search = function(self, ...)
      context.old_begin_search(self, ...)
      -- Capture after old results are cleared, before any worker can deliver new ones.
      core.root_view:update()
      local width, height = core.window:get_size()
      core.clip_rect_stack = { { 0, 0, width, height } }
      renderer.begin_frame(core.window)
      renderer.set_clip_rect(0, 0, width, height)
      core.root_view:draw()
      renderer.end_frame()
      local frame = renderer.to_canvas(core.window, 0, 0, width, height)
      local x, y, _, h = self:get_floating_bounds()
      frames[#frames + 1] = {
        surface = { frame:get_pixels(math.floor(self.position.x + 1),
          math.floor(self.position.y + 1), 1, 1):byte(1, 3) },
        border = { frame:get_pixels(math.floor(x), math.floor(y + h / 2),
          1, 1):byte(1, 3) }
      }
    end
    for i, char in ipairs { "d", "l", "e", "x" } do
      core.on_event("textinput", char)
      for _ = 1, 200 do
        if #frames == i and not view.searching and not view.queue_search then break end
        coroutine.yield(0.01)
      end
      test.equal(#frames, i, "each keystroke must refresh the live search")
      test.not_ok(view.searching)
      test.not_ok(view.queue_search)
      test.same(frames[i].surface, { style.background2[1], style.background2[2], style.background2[3] })
      test.same(frames[i].border, { style.text[1], style.text[2], style.text[3] })
      test.equal(view.results_list.total_results, i == 4 and 0 or 1)
      test.equal(core.active_view, view.find_text.textview)
      test.ok(view.floating_visible)
    end
  end)

  for _, position in ipairs { "left", "right", "center" } do
    test.test(position .. " search cycles fields and results with Tab and Shift+Tab", function(context)
      local view = global_search(context, position, true)
      for _, mode in ipairs {
        { replace = false, filters = false },
        { replace = true, filters = false },
        { replace = false, filters = true },
        { replace = true, filters = true }
      } do
        view.replace_toggle:set_toggle(mode.replace)
        view.filters_toggle:set_toggle(mode.filters)
        core.root_view:update()
        local targets = { view.find_text }
        if mode.replace then targets[#targets + 1] = view.replace_text end
        if mode.filters then
          targets[#targets + 1] = view.includes_text
          targets[#targets + 1] = view.excludes_text
        end
        targets[#targets + 1] = view.results_list
        view:swap_active_child(view.find_text)
        local selected = view.results_list.selected
        for i = 2, #targets + 1 do
          core.on_event("keypressed", "tab")
          local target = targets[(i - 1) % #targets + 1]
          test.equal(view.child_active, target)
          test.equal(core.active_view, target.textview or target)
        end
        keymap.modkeys.shift = true
        for i = #targets, 1, -1 do
          core.on_event("keypressed", "tab")
          test.equal(view.child_active, targets[i])
          test.equal(core.active_view, targets[i].textview or targets[i])
        end
        keymap.modkeys.shift = nil
        test.equal(view.results_list.selected, selected)
      end
    end)

    test.test(position .. " search arrows focus results before moving the selection", function(context)
      local view = global_search(context, position, true)
      view.replace_toggle:set_toggle(true)
      view.filters_toggle:set_toggle(true)
      core.root_view:update()
      for _, input in ipairs {
        view.find_text, view.replace_text, view.includes_text, view.excludes_text
      } do
        input:set_text("unchanged")
        for _, key in ipairs { "up", "down" } do
          view:swap_active_child(input)
          input.textview.doc:set_selection(1, 4)
          view.results_list.selected = 2
          core.on_event("keypressed", key)
          test.equal(core.active_view, view.results_list)
          test.equal(view.results_list.selected, 2)
          test.equal(input:get_text(), "unchanged")
          test.equal(select(2, input.textview.doc:get_selection()), 4)
          core.on_event("keypressed", key)
          test.equal(view.results_list.selected, key == "up" and 1 or 3)
        end
      end
    end)
  end

  test.test("empty search skips results when tabbing and retains input focus on arrows", function(context)
    local view = global_search(context, "center")
    for _, key in ipairs { "up", "down", "tab" } do
      core.on_event("keypressed", key)
      test.equal(core.active_view, view.find_text.textview)
    end
    view.total_files, view.total_files_processed = 0, 0
    view.start_time, view.end_time = 0, 0
    core.root_view:update()
    test.ok(view.results_list:is_visible())
    keymap.modkeys.shift = true
    core.on_event("keypressed", "tab")
    test.equal(core.active_view, view.find_text.textview)
    keymap.modkeys.shift = nil
    for _, key in ipairs { "up", "down" } do
      core.on_event("keypressed", key)
      test.equal(core.active_view, view.find_text.textview)
    end
  end)

  test.test("tabbed search also cycles from its inputs to results", function(context)
    local view = create_results_view(context)
    add_result(view, join_path(context.project_a, "src", "one.txt"), "needle one", 1, 6)
    view.total_files, view.total_files_processed = 1, 1
    view.start_time, view.end_time = 0, 0
    core.root_view:update()
    view:swap_active_child(view.find_text)
    core.on_event("keypressed", "tab")
    test.equal(core.active_view, view.results_list)
    core.on_event("keypressed", "tab")
    test.equal(core.active_view, view.find_text.textview)
    core.on_event("keypressed", "down")
    test.equal(core.active_view, view.results_list)
  end)

  test.test("Escape from another prompt leaves centered search open", function(context)
    local view = global_search(context, "center", true)
    core.command_view:enter("Test", { text = "another prompt" })
    core.on_event("keypressed", "escape")
    test.not_ok(core.command_view:is_open())
    test.ok(view:is_visible())
    test.equal(core.active_view, view.find_text.textview)
    core.on_event("keypressed", "escape")
    test.not_ok(view:is_visible())
  end)

  test.test("position selector moves a shown search without replacing its state", function(context)
    local view, source = global_search(context, "left", true)
    view:set_target_size("x", 420 * SCALE)
    local sidebar_width = view:get_width()
    local editor_node = core.root_view.root_node:get_node_for_view(source)
    local items, input = view.results_list.items, view.find_text
    view.filters_toggle:set_toggle(true)
    view.includes_text:set_text("src/**")
    treeview.visible = true
    projectsearch.hide()
    projectsearch.show({ text = "needle" })
    settle_focus(view, input.textview)
    test.not_ok(treeview.visible)
    for _, position in ipairs { "right", "center", "left", "center", "right", "left" } do
      projectsearch.set_position(position)
      core.root_view:update(); core.root_view:update()
      test.equal(view.display_position, position)
      test.equal(view.find_text, input)
      test.equal(view.find_text:get_text(), "needle")
      test.equal(view.includes_text:get_text(), "src/**")
      test.equal(view.results_list.items, items)
      test.equal(view.results_list.selected, 2)
      test.equal(core.root_view.root_node:get_node_for_view(source), editor_node)
      test.equal(not not view.floating_visible, position == "center")
      test.equal(treeview.visible, position ~= "left")
      local node = core.root_view.root_node:get_node_for_view(view)
      if position == "center" then
        test.is_nil(node)
      else
        test.not_nil(node)
        test.near(view:get_width(), sidebar_width, 0.01)
        local parent = node:get_parent_node(core.root_view.root_node)
        test.equal(position == "left" and parent.a or parent.b, node)
      end
    end
    local selector
    for _, item in ipairs(config.plugins.projectsearch.config_spec) do
      if item.path == "position" then selector = item end
    end
    test.not_nil(selector)
    test.equal(selector.set_value("center"), "center")
    test.equal(view.display_position, "center")
    test.ok(view.floating_visible)
    local ok = pcall(projectsearch.set_position, "invalid")
    test.not_ok(ok)
    test.equal(config.plugins.projectsearch.position, "center")
  end)

  test.test("side placement survives toolbar docking changes", function(context)
    local view, source = global_search(context, "left", true)
    local editor = core.root_view.root_node:get_node_for_view(source)
    for _, side in ipairs { "left", "right" } do
      projectsearch.set_position(side)
      for _, position in ipairs { "left", "top", "bottom", "right" } do
        treeview:set_toolbar_position(position)
        core.root_view:update(); core.root_view:update()
        test.equal(core.root_view.root_node:get_node_for_view(source), editor)
        test.not_nil(core.root_view.root_node:get_node_for_view(view))
        test.not_nil(core.root_view.root_node:get_node_for_view(treeview))
        test.not_nil(core.root_view.root_node:get_node_for_view(treeview.toolbar))
      end
    end
  end)

  test.test("centered search focuses input when empty and results when reopening", function(context)
    local view = global_search(context, "center")
    test.equal(core.active_view, view.find_text.textview)
    add_result(view, join_path(context.project_a, "src", "one.txt"), "needle one", 1, 6)
    view.total_files, view.total_files_processed = 1, 1
    view.start_time, view.end_time = 0, 0
    projectsearch.hide()
    view.results_list.selected = 0
    projectsearch.show()
    settle_focus(view, view.results_list)
    test.equal(view.child_active, view.results_list)
    test.ok(view.results_list:get_selected().position)
  end)

  test.test("centered result focus supports navigation, expansion and Enter", function(context)
    local view = global_search(context, "center", true)
    projectsearch.hide(); projectsearch.show()
    settle_focus(view, view.results_list)
    keymap.modkeys = {}
    local list, selected = view.results_list, view.results_list.selected
    core.on_event("keypressed", "down")
    test.equal(list.selected, selected + 1)
    local count = #list.items
    core.on_event("keypressed", "right")
    test.ok(#list.items < count)
    core.on_event("keypressed", "left")
    test.equal(#list.items, count)
    core.on_event("keypressed", "up")
    test.equal(list.selected, selected)
    core.on_event("keypressed", "pagedown")
    test.ok(list.scroll.to.y > 0)
    core.on_event("keypressed", "home")
    test.equal(list.scroll.to.y, 0)
    core.on_event("keypressed", "return")
    test.not_ok(view:is_visible())
    test.not_ok(view.floating_visible)
    test.ok(core.active_view:extends(DocView))
    test.equal(common.normalize_path(core.active_view.doc.abs_filename),
      common.normalize_path(join_path(context.project_a, "src", "one.txt")))
    projectsearch.show()
    settle_focus(view, view.results_list)
  end)

  test.test("new selected text focuses the centered search input", function(context)
    local view, source = global_search(context, "center", true)
    projectsearch.hide()
    core.set_active_view(source)
    source.doc:set_selection(1, 1, 1, 5)
    projectsearch.show()
    settle_focus(view, view.find_text.textview)
    test.equal(view.find_text:get_text(), "main")
    test.ok(view.find_text.textview.doc:has_selection())
    test.equal(view.results_list.total_results, 2)
  end)

  test.test("reopening a selected regex result preserves the query and result focus", function(context)
    local view = global_search(context, "center", true)
    view.find_text:set_text("nee[a-z]+")
    view.regex_toggle:set_toggle(true)
    view:open_selected_result()
    test.not_ok(view:is_visible())
    projectsearch.show()
    settle_focus(view, view.results_list)
    test.equal(view.find_text:get_text(), "nee[a-z]+")
    test.ok(view.regex_toggle:is_toggled())
    test.equal(view.results_list.selected, 2)
  end)

  test.test("centered Escape and close button restore the source view", function(context)
    local view, source = global_search(context, "center", true)
    keymap.modkeys = {}
    core.on_event("keypressed", "escape")
    test.not_ok(view:is_visible())
    test.equal(core.active_view, source)
    projectsearch.show(); settle_focus(view, view.results_list)
    view.close_button:on_click()
    test.not_ok(view:is_visible())
    test.equal(core.active_view, source)
  end)

  test.test("outside clicks dismiss the popup and retain the clicked editor focus", function(context)
    local view, source = global_search(context, "center", true)
    local root = core.root_view
    root.size.x, root.size.y = 1400, 900
    root:update(); root:update()
    local node = root.root_node:get_node_for_view(source)
    local x, y = node.position.x + node.size.x - 10, node.position.y + node.size.y - 20
    test.not_ok(view:hit_test(x, y))
    core.on_event("mousepressed", "left", x, y, 1)
    core.on_event("mousereleased", "left", x, y)
    test.not_ok(view:is_visible())
    test.equal(core.active_view, source)
    coroutine.yield(0)
    test.equal(core.active_view, source)
  end)

  test.test("hiding before queued focus runs leaves editor focus intact", function(context)
    local view, source = global_search(context, "center", true)
    projectsearch.hide()
    projectsearch.show()
    projectsearch.hide()
    coroutine.yield(0)
    core.root_view:update()
    test.not_ok(view:is_visible())
    test.equal(core.active_view, source)
  end)

  test.test("centered bounds fit resizing without shrinking on repeated updates", function(context)
    local view = global_search(context, "center", true)
    local root = core.root_view
    for _, size in ipairs { { 1200, 900 }, { 650, 460 }, { 1600, 1000 } } do
      root.size.x, root.size.y = size[1], size[2]
      root:update(); root:update()
      local x, y, width, height = view:get_floating_bounds()
      test.ok(x >= root.position.x and y >= root.position.y)
      test.ok(x + width <= root.position.x + root.size.x)
      test.ok(y + height <= root.position.y + root.size.y)
      test.near(x + width / 2, root.position.x + root.size.x / 2, 0.01)
      test.near(y + height / 2, root.position.y + root.size.y / 2, 0.01)
      for _ = 1, 10 do root:update() end
      test.near(select(3, view:get_floating_bounds()), width, 0.01)
      test.near(select(4, view:get_floating_bounds()), height, 0.01)
      test.equal(view.results_list.selected, 2)
      test.equal(view.results_list.total_results, 2)
    end
  end)

  test.test("centered search resizes with scale while keeping results and focus", function(context)
    local view = global_search(context, "center", true)
    projectsearch.hide(); projectsearch.show()
    settle_focus(view, view.results_list)
    core.root_view.size.x, core.root_view.size.y = 1800, 1300
    core.root_view:update(); core.root_view:update()
    local _, _, width, height = view:get_floating_bounds()
    context.old_scale, context.scale_env = scale.get(), os.getenv("PRAGTICAL_SCALE")
    context.scale_values = { { config, "mouse_wheel_scroll", config.mouse_wheel_scroll } }
    for _, values in ipairs { style, style.padding, style.margin.tab } do
      for key, value in pairs(values) do
        if type(value) == "number" then context.scale_values[#context.scale_values + 1] = { values, key, value } end
      end
    end
    context.font_sizes = {}
    for _, name in ipairs { "font", "big_font", "icon_font", "icon_big_font" } do
      context.font_sizes[style[name]] = style[name]:get_size()
    end
    scale.set(context.old_scale * 1.25)
    for _ = 1, 5 do core.root_view:update() end
    test.ok(select(3, view:get_floating_bounds()) > width)
    test.ok(select(4, view:get_floating_bounds()) > height)
    test.equal(view.results_list.selected, 2)
    test.equal(core.active_view, view.results_list)
  end)

end)
