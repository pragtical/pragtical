-- mod-version:3
local core = require "core"
local config = require "core.config"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local StatusView = require "core.statusview"

---Configuration options for `findfile` plugin.
---@class config.plugins.findfile
---Show the latest visited files.
---@field show_recent boolean
---Enable a cache of indexed project files for faster core:find-file invocation.
---@field enable_cache boolean
---Amount of minutes before having to re-index project files.
---@field cache_expiration number
config.plugins.findfile = common.merge({
  show_recent = true,
  enable_cache = false,
  cache_expiration = 60,
  -- The config specification used by gui generators
  config_spec = {
    name = "Find File",
    {
      label = "Show Recent Files",
      description = "Show the latest visited files.",
      path = "show_recent",
      type = "toggle",
      default = true
    },
    {
      label = "Cache",
      description = "Enable a cache of indexed project files for faster core:find-file invocation.",
      path = "enable_cache",
      type = "toggle",
      default = false
    },
    {
      label = "Cache Expiration",
      description = "Amount of minutes before having to re-index project files.",
      path = "cache_expiration",
      type = "number",
      default = 60,
      min = 1
    }
  }
}, config.plugins.findfile)

local project_files = {}
local refresh_files = false
local matching_files = 0
local project_total_files = 0
local multiple_projects = false
local loading_text = ""
local coroutine_running = false
local cache_expiration_time = 0
local last_indexed_projects = ""

local function basedir_files()
  local files_return = {}

  for _, project in ipairs(core.projects) do
    local project_directory = project.path
    local project_name = common.basename(project_directory)
    local files = system.list_dir(project_directory)

    if files then
      for _, file in ipairs(files) do
        local info = system.get_file_info(
          project_directory .. PATHSEP .. file
        )

        if
          info and info.size <= config.file_size_limit * 1e6
          and
          not common.match_ignore_rule(file, info, core.get_ignore_file_rules())
        then
          if info.type ~= "dir" then
            if multiple_projects then
              file = project_name .. PATHSEP .. file
            end
            table.insert(files_return, file)
          end
        end
      end
    end
  end

  if project_total_files == 0 then
    project_total_files = #files_return
  end

  return files_return
end

local function update_suggestions()
  if
    core.active_view == core.command_view
    and
    core.command_view.label == "Open File From Project: "
  then
    core.command_view:update_suggestions()
  end
end

local function update_loading_text(init)
  if init then
    loading_text = "[-]"
    return
  elseif type(init) == "boolean" then
    loading_text = "Matches:"
    return
  end

  if loading_text == "[-]" then
    loading_text = "[\\]"
  elseif loading_text == "[\\]" then
    loading_text = "[|]"
  elseif loading_text == "[|]" then
    loading_text = "[/]"
  elseif loading_text == "[/]" then
    loading_text = "[-]"
  end

  core.redraw = true
end

local function index_files_thread(pathsep, ignore_files, file_size_limit)
  local commons = require "core.common"

  ---@type thread.Channel
  local input = thread.get_channel("findfile_write")
  ---@type thread.Channel
  local output = thread.get_channel("findfile_read")

  local root = input:wait()
  output:push("indexing")

  local count = 0

  while root do
    input:pop()

    local directories = {""}
    local files_found = {}

    while #directories > 0 do
      for didx, directory in ipairs(directories) do
        local dir_path = ""

        if directory ~= "" then
          dir_path = root .. pathsep .. directory
          directory = directory .. pathsep
        else
          dir_path = root
        end

        local files = system.list_dir(dir_path)

        if files then
          for _, file in ipairs(files) do
            local info = system.get_file_info(
              dir_path .. pathsep .. file
            )

            if
              info and info.size <= file_size_limit
              and
              not commons.match_ignore_rule(directory..file, info, ignore_files)
            then
              if info.type == "dir" then
                table.insert(directories, directory .. file)
              else
                table.insert(files_found, directory .. file)
              end
            end
          end
        end
        table.remove(directories, didx)
        break
      end

      count = count + 1
      if count % 500 == 0 then
        output:push(files_found)
        files_found = {}
      end
    end

    if #files_found > 0 then
      output:push(files_found)
    end

    root = input:first()
    if root then
      output:push("next_project")
    end
  end

  output:push("finished")
end

local function index_files_coroutine()
  while true do
    -- Indexing with thread module/plugin
    if refresh_files then
      ---@type thread.Channel
      local input = thread.get_channel("findfile_read")
      ---@type thread.Channel
      local output = thread.get_channel("findfile_write")

      -- The projects to index by the thread
      local project_names = {} -- in case the user changes projects while indexing
      for _, project in ipairs(core.projects) do
        output:push(project.path)
        table.insert(project_names, common.basename(project.path))
      end

      local count = 0

      local indexing_thread = thread.create(
        "findfile", index_files_thread,
        PATHSEP, core.get_ignore_file_rules(), config.file_size_limit * 1e6
      )

      local last_time = system.get_time()

      -- Handle the indexed project files
      for _, project_name in ipairs(project_names) do
        while refresh_files do
          local value = input:first()
          count = count + 1

          if value then
            local next_project = false
            local value_type = type(value)
            if value_type == "string" then
              if value == "indexing" then
                update_loading_text(true)
              elseif value == "next_project" then
                next_project = true
              elseif value == "finished" then
                if config.plugins.findfile.enable_cache then
                  cache_expiration_time = os.time()
                    + config.plugins.findfile.cache_expiration * 60
                end
                refresh_files = false
                update_loading_text(false)
              end
            elseif value_type == "table" then
              for _, file in ipairs(value) do
                if multiple_projects then
                  file = project_name .. PATHSEP .. file
                end
                table.insert(project_files, file)
              end
            end
            input:pop()
            if next_project then break end
          end

          if refresh_files then
            local total_project_files = #project_files
            if total_project_files ~= project_total_files then
              project_total_files = total_project_files
              if project_total_files <= 100000 and count % 10000 == 0 then
                update_suggestions()
              end
            end
          end

          local current_time = system.get_time()
          if current_time - last_time >= 0.2 then
            last_time = current_time
            update_loading_text()
          end

          if count % 100 == 0 then
            coroutine.yield()
          end
        end
      end

      coroutine_running = false
      update_suggestions()

      return
    else
      coroutine.yield(2)
    end
  end
end

local function is_file(file_path)
  local file_info = system.get_file_info(file_path)
  if file_info and file_info.type == "file" then
    return true
  end
  return false
end

local function get_visited_files()
  local files = {}
  for _, file in ipairs(core.visited_files) do
    if is_file(file) then
      local project, is_open, belongs = core.current_project(file)
      if project then
        local entry_name = ""
        if is_open and belongs then
          if multiple_projects then
            entry_name = common.basename(project.path)
              .. PATHSEP
              .. common.relative_path(project.path, file)
          else
            entry_name = common.relative_path(project.path, file)
          end
        else
          entry_name = common.home_encode(file)
        end
        table.insert(files, {text = entry_name, info = "recent file"})
      end
    end
  end
  return files
end

command.add(nil, {
  ["core:find-file"] = function()
    if not coroutine_running then
      if #core.projects > 1 then
        multiple_projects = true
      else
        multiple_projects = false
      end
    end

    local current_projects = ""
    for _, project in ipairs(core.projects) do
      current_projects = current_projects .. project.path .. ":"
    end

    local base_files = basedir_files()
    if #base_files == 0 then
      return
    end

    refresh_files = true
    if
      not coroutine_running
      and
      (
        not config.plugins.findfile.enable_cache
        or
        cache_expiration_time < os.time()
        or
        last_indexed_projects ~= current_projects
      )
    then
      project_files = {}
      coroutine_running = true
      core.add_thread(index_files_coroutine)
      last_indexed_projects = current_projects
    end

    core.command_view:enter("Open File From Project", {
      submit = function(text, suggestion)
        if not suggestion then
          if text == "" then return end
          local filename = core.current_project():absolute_path(
            common.home_expand(text)
          )
          core.root_view:open_doc(core.open_doc(filename))
          return
        end
        text = suggestion.text
        if multiple_projects then
          local project_name, file_path = text:match(
            "^([^"..PATHSEP.."]+)"..PATHSEP.."(.*)"
          )
          if project_name then
            for _, project in ipairs(core.projects) do
              if project_name == common.basename(project.path) then
                local file = project.path .. PATHSEP .. file_path
                if is_file(file) then
                  core.root_view:open_doc(
                    core.open_doc(project.path .. PATHSEP .. file_path)
                  )
                  return
                end
              end
            end
          end
        end
        local file = core.projects[1]:absolute_path(
          common.home_expand(text)
        )
        if is_file(file) then
          core.root_view:open_doc(core.open_doc(file))
        end
      end,
      suggest = function(text)
        local results = {}

        if coroutine_running and #project_files == 0 then
          results = base_files
        elseif text ~= "" then
          results = common.fuzzy_match(
            project_files, text, true
          )
        else
          results = project_files
        end
        if config.plugins.findfile.show_recent then
          results = common.fuzzy_match_with_recents(results, get_visited_files(), text)
        end
        matching_files = #results
        return results
      end
    })
  end
})

command.add(
  function()
    return not coroutine_running
      and config.plugins.findfile.enable_cache
      and #project_files > 0
  end, {
  ["core:find-file-clear-cache"] = function()
    cache_expiration_time = 0
    last_indexed_projects = ""
    project_files = {}
  end
})

keymap.add({
  [PLATFORM == "Mac OS X" and "cmd+p" or "ctrl+p"] = "core:find-file"
})


core.status_view:add_item({
  predicate = function()
    return core.active_view == core.command_view
      and core.command_view.label == "Open File From Project: "
  end,
  name = "command:find-file-matches",
  alignment = StatusView.Item.LEFT,
  get_item = function()
    return {
      style.text, style.font, loading_text
        .. " "
        .. tostring(matching_files)
        .. "/"
        .. tostring(project_total_files)
    }
  end,
  position = 1
})

core.status_view:add_item({
  predicate = function()
    return core.active_view == core.command_view
      and core.command_view.label == "Open File From Project: "
      and not coroutine_running
      and config.plugins.findfile.enable_cache
      and #project_files > 0
  end,
  name = "command:find-file-clear-cache",
  alignment = StatusView.Item.LEFT,
  get_item = function()
    return {
      style.text, style.font, "Refresh Files List"
    }
  end,
  position = 2,
  separator = StatusView.separator2,
  command = function()
    command.perform "core:find-file-clear-cache"
    command.perform "core:find-file"
  end
})
