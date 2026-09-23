-- mod-version:3
local core = require "core"
local config = require "core.config"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local StatusView = require "core.statusview"
local DocView = require "core.docview"

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
local line_number = nil
local project_total_files = 0
local multiple_projects = false
local loading_text = ""
local coroutine_running = false
local cache_expiration_time = 0
local last_indexed_projects = ""
local active_find_file_label = "Open File From Project"

local function basedir_files()
  local files_return = {}
  local directories = 0

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
          else
            directories = directories + 1
          end
        end
      end
    end
  end

  if project_total_files == 0 then
    project_total_files = #files_return
  end

  return files_return, directories
end

local function update_suggestions()
  if
    core.active_view == core.command_view
    and
    core.command_view.label == active_find_file_label .. ": "
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
  ---@type thread.Channel
  local input = thread.get_channel("findfile_write")
  ---@type thread.Channel
  local output = thread.get_channel("findfile_read")

  local ok, err = pcall(function()
    local commons = require "core.common"
    local root = input:wait()
    output:push("indexing")

    local count = 0

    while root do
      input:pop()

      local directories = {""}
      local directory_index = 1
      local files_found = {}

      while directory_index <= #directories do
        -- Check shutdown in batches without locking a channel per directory.
        if count % 64 == 0 then input:first() end
        local directory = directories[directory_index]
        local dir_path = ""

        if directory ~= "" then
          dir_path = root .. pathsep .. directory
          directory = directory .. pathsep
        else
          dir_path = root
        end

        local files = system.list_dir(dir_path)

        if files then
          for i, file in ipairs(files) do
            if i % 1024 == 0 then input:first() end
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
        -- Release the path without shifting the remaining queue or adding holes.
        directories[directory_index] = false
        directory_index = directory_index + 1

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
  end)

  -- Keep this outside pcall so closed channels propagate shutdown cancellation.
  output:push(ok and "finished" or { error = tostring(err) })
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

      local indexing_error
      if #project_names > 0 then
        local indexing_thread, err = thread.create(
          "findfile", index_files_thread,
          PATHSEP, core.get_ignore_file_rules(), config.file_size_limit * 1e6
        )
        if not indexing_thread then
          indexing_error = err or "could not create indexing worker"
          refresh_files = false
        end
      else
        refresh_files = false
      end

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
            elseif value_type == "table" and value.error then
              indexing_error = value.error
              refresh_files = false
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

          if refresh_files and (not value or count % 100 == 0) then
            coroutine.yield()
          end
        end
      end

      if indexing_error then
        input:clear()
        output:clear()
        project_files = {}
        cache_expiration_time = 0
        last_indexed_projects = ""
        core.error("Could not index project files: %s", indexing_error)
      end
      project_total_files = #project_files
      coroutine_running = false
      update_loading_text(false)
      update_suggestions()
      core.redraw = true

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

local function file_in_project(project, path)
  local filename = project:absolute_path(
    common.home_expand(path)
  )
  if is_file(filename) then
    return filename
  end
end

local function open_file_in_project(project, path, line)
  local filename = file_in_project(project, path)
  if filename then
    local line_num = line or 1
    local view = core.open_file(filename)

    if view:is(DocView) then
      local doc = view.doc
      local line = math.min(line_num, math.max(1, #doc.lines))
      doc:set_selection(line_num, 1, line_num, 1)
      view:scroll_to_line(line_num, true, true)
    end
  end
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

local function parse_line_number(text)
  local path, line = text:match("^(.-):(%d*)$")
  if path then
    return path, tonumber(line)
  end
  return text, nil
end

local function filter_files(files, text, cache)
  if cache.files ~= files then
    cache.files, cache.items = files, {}
    cache.count = nil
  end
  if cache.count == #files and cache.text == text then
    return cache.results
  end

  local candidates = files
  if cache.count == #files and cache.text and text:sub(1, #cache.text) == cache.text then
    candidates = cache.matches
  end
  local results, matches, scores, buckets = {}, {}, {}, {}
  local needle = PLATFORM == "Windows" and text:gsub("/", PATHSEP) or text
  for _, file in ipairs(candidates) do
    local score = text == "" and 0 or system.fuzzy_match(file, needle, true)
    if score then
      matches[#matches + 1] = file
      local item = cache.items[file]
      if not item then
        item = {text = file}
        cache.items[file] = item
      end
      if text == "" then
        results[#results + 1] = item
      else
        local bucket = buckets[score]
        if not bucket then
          bucket = {}
          buckets[score] = bucket
          scores[#scores + 1] = score
        end
        bucket[#bucket + 1] = item
      end
    end
  end
  -- Native fuzzy scores are integers; sort score groups, not every file.
  table.sort(scores)
  for i = #scores, 1, -1 do
    for _, item in ipairs(buckets[scores[i]]) do
      results[#results + 1] = item
    end
  end
  cache.count, cache.text = #files, text
  cache.matches, cache.results = matches, results
  return results
end

local function submit_project_file(text, selection_callback, selected_line)
  local parsed_line
  text, parsed_line = parse_line_number(text)
  selected_line = parsed_line or selected_line
  if multiple_projects then
    local project_name, file_path = text:match(
      "^([^"..PATHSEP.."]+)"..PATHSEP.."(.*)"
    )
    if project_name then
      for _, project in ipairs(core.projects) do
        if project_name == common.basename(project.path) then
          if selection_callback then
            local filename = file_in_project(project, file_path)
            if filename then selection_callback(filename, selected_line) end
            return
          end
          return open_file_in_project(project, file_path, selected_line)
        end
      end
    end
  end

  local project = core.projects[1]
  if selection_callback then
    local filename = file_in_project(project, text)
    if filename then selection_callback(filename, selected_line) end
    return
  end
  open_file_in_project(project, text, selected_line)
end

command.add(nil, {
  ["core:find-file"] = function(label, selection_callback)
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

    local base_files, dirs = basedir_files()
    if #base_files == 0 and dirs == 0 then
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

    local filter_cache = {}
    active_find_file_label = label or "Open File From Project"
    core.command_view:enter(active_find_file_label, {
      submit = function(text, suggestion)
        if not suggestion then
          if text == "" then return end
          return submit_project_file(text, selection_callback)
        end
        submit_project_file(suggestion.text, selection_callback, line_number)
      end,
      suggest = function(text)
        -- Remove line number from path and store for later use (e.g., "filename.lua:42" becomes "filename.lua")
        text, line_number = parse_line_number(text)

        local files = coroutine_running and #project_files == 0 and base_files or project_files
        local results = filter_files(files, text, filter_cache)
        if config.plugins.findfile.show_recent and text == "" then
          local recents = get_visited_files()
          local combined = {}
          for i = 2, #recents do combined[#combined + 1] = recents[i] end
          if recents[1] then combined[#combined + 1] = recents[1] end
          for _, item in ipairs(results) do combined[#combined + 1] = item end
          results = combined
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
      and core.command_view.label == active_find_file_label .. ": "
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
      and core.command_view.label == active_find_file_label .. ": "
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
