local common = require "core.common"
local config = require "core.config"
local core = require "core"
local test = require "core.test"
local projectsearch = require "plugins.projectsearch"
local SearchReplaceList = require "widget.searchreplacelist"

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

test.describe("projectsearch", function()
  test.before_each(function(context)
    context.old_projects = core.projects
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
    core.projects = {
      { path = context.project_a, name = "alpha" },
      { path = context.project_b, name = "beta" }
    }
  end)

  test.after_each(function(context)
    core.projects = context.old_projects
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
end)
