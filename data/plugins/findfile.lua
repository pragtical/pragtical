-- mod-version:3
local core = require "core"
local config = require "core.config"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local StatusView = require "core.statusview"

local project_files = {}
local refresh_files = false
local matching_files = 0
local project_total_files = 0
local loading_text = ""
local project_directory = ""
local coroutine_running = false

local function basedir_files()
  local files = system.list_dir(project_directory)
  local files_return = {}

  if files then
    for _, file in ipairs(files) do
      local info = system.get_file_info(
        project_directory .. PATHSEP .. file
      )

      if
        info and info.size <= config.file_size_limit * 1e6
        and
        not common.match_pattern(file, config.ignore_files)
      then
        if info.type ~= "dir" then
          table.insert(files_return, file)
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
  input:pop()

  output:push("indexing")

  local count = 0
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
            not commons.match_pattern(directory .. file, ignore_files)
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

      -- Tell the thread to start indexing the pushed directory
      output:push(project_directory)
      local count = 0

      local indexing_thread = thread.create(
        "findfile", index_files_thread,
        PATHSEP, config.ignore_files, config.file_size_limit * 1e6
      )

      local last_time = system.get_time()

      while refresh_files do
        local value = input:first()
        count = count + 1

        if value then
          local value_type = type(value)
          if value_type == "string" then
            if value == "indexing" then
              project_files = {}
              update_loading_text(true)
            elseif value == "finished" then
              refresh_files = false
              update_loading_text(false)
            end
          elseif value_type == "table" then
            for _, file in ipairs(value) do
              table.insert(project_files, file)
            end
          end
          input:pop()
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

      coroutine_running = false
      update_suggestions()

      return
    else
      coroutine.yield(2)
    end
  end
end


command.add(nil, {
  ["core:find-file"] = function()
    local root_project_dir = core.root_project().path
    if project_directory ~= root_project_dir then
      project_directory = root_project_dir
    end

    local base_files = basedir_files()
    if #base_files == 0 then
      return
    end

    refresh_files = true
    if not coroutine_running then
      coroutine_running = true
      core.add_thread(index_files_coroutine)
    end

    core.command_view:enter("Open File From Project", {
      submit = function(text)
        core.root_view:open_doc(core.open_doc(common.home_expand(text)))
      end,
      suggest = function(text)
        local results = {}
        if coroutine_running and (text == "" or #project_files == 0) then
          results = common.fuzzy_match_with_recents(
            base_files, core.visited_files, text
          )
        else
          results = common.fuzzy_match(
            project_files, text, true
          )
        end
        matching_files = #results
        return results
      end
    })
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
