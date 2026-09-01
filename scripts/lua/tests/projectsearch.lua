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
    local channel = thread.get_channel("projectsearch_results"..tid..id)
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

test.describe("projectsearch", function()
  test.before_each(function(context)
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
    context.old_ctrl = keymap.modkeys["ctrl"]
    context.old_split_click_modifier = keymap.modkeys[split_click_modifier]
    context.locked_nodes = {}
  end)

  test.after_each(function(context)
    keymap.modkeys["ctrl"] = context.old_ctrl
    keymap.modkeys[split_click_modifier] = context.old_split_click_modifier
    config.plugins.projectsearch.split_direction = context.old_split_direction
    for _, node in ipairs(context.locked_nodes) do
      node.locked = nil
    end
    close_test_views_and_docs(context)
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

    test.ok(view:on_mouse_moved(
      menu.position.x + 1, menu.position.y + 1, 0, 0
    ))
    test.equal(menu.selected, 1)
    test.ok(view:on_mouse_moved(-1, -1, 0, 0))
    test.ok(view:on_mouse_pressed("left", -1, -1, 1))
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
end)
