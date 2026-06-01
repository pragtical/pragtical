local test = require "core.test"
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local style = require "core.style"
local EmptyView = require "core.emptyview"

test.describe("emptyview", function()
  local old_recent_projects
  local old_active_view
  local old_add_project
  local old_system_exec
  local view
  local project_a
  local project_b

  test.before_each(function()
    old_recent_projects = core.recent_projects
    old_active_view = core.active_view
    old_add_project = core.add_project
    old_system_exec = system.exec

    project_a = common.normalize_volume(system.absolute_path(USERDIR))
    project_b = common.normalize_volume(system.getcwd())
    core.recent_projects = { project_a, project_b }
    view = EmptyView()
    core.active_view = view
  end)

  test.after_each(function()
    if view then
      view:destroy()
      view = nil
    end
    core.recent_projects = old_recent_projects
    core.active_view = old_active_view
    core.add_project = old_add_project
    system.exec = old_system_exec
  end)

  test.it("populates recent projects", function()
    test.equal(#view.recent_projects.rows, 2)
    test.equal(view.recent_projects:get_row_data(1).path, project_a)
    test.equal(view.recent_projects:get_row_data(2).path, project_b)
  end)

  test.it("removes a recent project", function()
    view:remove_recent_project(project_a)

    test.same(core.recent_projects, { project_b })
    test.equal(#view.recent_projects.rows, 1)
    test.equal(view.recent_projects:get_row_data(1).path, project_b)
  end)

  test.it("removes all recent projects", function()
    view:remove_all_recent_projects()

    test.same(core.recent_projects, {})
    test.equal(#view.recent_projects.rows, 0)
    test.not_ok(view.recent_projects:is_visible())
  end)

  test.it("performs recent project context commands", function()
    local added_path
    local exec_command
    core.add_project = function(path)
      added_path = path
    end
    system.exec = function(cmd)
      exec_command = cmd
    end

    view.recent_projects_context_target = { path = project_a }

    command.perform("welcome:add-recent-project-current-instance")
    test.equal(added_path, project_a)

    command.perform("welcome:open-recent-project-new-instance")
    test.match(exec_command, string.format("%q", project_a), nil, true)

    command.perform("welcome:remove-recent-project")
    test.same(core.recent_projects, { project_b })
  end)

  test.it("targets the right-clicked recent project row", function()
    local list = view.recent_projects
    list:show()
    list:set_position(10, 20)
    list:set_size(200, 200)

    local x = list.position.x + list.border.width + 1
    local y = list.position.y
      + list.border.width
      + style.font:get_height()
      + style.padding.y
      + 1

    list:on_mouse_pressed("right", x, y, 1)

    test.equal(view:get_selected_recent_project(), project_a)
  end)
end)
