local common = require "core.common"
local core = require "core"
local test = require "core.test"

local function join_path(...)
  return table.concat({...}, PATHSEP)
end

local function write_file(path, content)
  local file, err = io.open(path, "wb")
  test.not_nil(file, err)
  file:write(content or "")
  file:close()
end

local function read_file(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local content = file:read("*a")
  file:close()
  return content
end

test.describe("project trust", function()
  local trusted_projects_file = join_path(USERDIR, "trusted_projects.lua")

  test.before_each(function(context)
    context.old_trusted_projects = core.trusted_projects
    context.old_nag_view = core.nag_view
    context.old_trusted_projects_file = read_file(trusted_projects_file)
    context.temp_root = join_path(
      USERDIR,
      "project-trust-tests-" .. system.get_process_id()
        .. "-" .. math.floor(system.get_time() * 1000000)
    )
    context.project_path = join_path(context.temp_root, "project")
    local ok, err = common.mkdirp(context.project_path)
    test.ok(ok, err)
    write_file(
      join_path(context.project_path, ".pragtical_project.lua"),
      "-- mod-version:3\nreturn true\n"
    )
    core.trusted_projects = {}
    os.remove(trusted_projects_file)
  end)

  test.after_each(function(context)
    core.trusted_projects = context.old_trusted_projects
    core.nag_view = context.old_nag_view
    if context.old_trusted_projects_file then
      write_file(trusted_projects_file, context.old_trusted_projects_file)
    else
      os.remove(trusted_projects_file)
    end
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  test.test("persists trusted project paths", function(context)
    test.equal(core.is_project_trusted(context.project_path), false)

    local trusted_path = core.trust_project(context.project_path)
    test.equal(core.is_project_trusted(context.project_path), true)

    local stored = dofile(trusted_projects_file)
    test.equal(stored[trusted_path], true)
  end)

  test.test("trust prompt records trusted choices", function(context)
    local callback_trusted
    local callback_path
    local prompt
    core.nag_view = {
      show = function(_, title, message, options, callback)
        prompt = {
          title = title,
          message = message,
          options = options,
          callback = callback
        }
      end
    }

    test.ok(core.prompt_project_trust(
      context.project_path,
      { trust_text = "Trust and Open", continue_text = "Open Without Trust" },
      function(trusted, path)
        callback_trusted = trusted
        callback_path = path
      end
    ))
    test.equal(prompt.title, "Trust Project")
    test.not_nil(prompt.message:find(".pragtical_project.lua", 1, true))
    test.equal(#prompt.options, 2)

    prompt.callback(prompt.options[1])

    test.equal(callback_trusted, true)
    test.equal(core.is_project_trusted(context.project_path), true)
    local stored = dofile(trusted_projects_file)
    test.equal(stored[callback_path], true)
  end)

  test.test("trust prompt continues without recording trust", function(context)
    local callback_trusted
    local prompt
    core.nag_view = {
      show = function(_, _, _, options, callback)
        prompt = { options = options, callback = callback }
      end
    }

    core.prompt_project_trust(
      context.project_path,
      { trust_text = "Trust and Open", continue_text = "Open Without Trust" },
      function(trusted)
        callback_trusted = trusted
      end
    )
    prompt.callback(prompt.options[2])

    test.equal(callback_trusted, false)
    test.equal(core.is_project_trusted(context.project_path), false)
  end)
end)
