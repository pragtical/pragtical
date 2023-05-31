-- mod-version:3
local core = require "core"
local common = require "core.common"
local keymap = require "core.keymap"
local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local View = require "core.view"

config.plugins.projectsearch = common.merge({
  threading = {
    enabled = true,
    workers = math.ceil(thread.get_cpu_count() / 2) + 1
  },
  -- The config specification used by gui generators
  config_spec = {
    name = "Project Search",
    {
      label = "Threading",
      description = "Disable or enable multi-threading for faster searching.",
      path = "threading.enabled",
      type = "toggle",
      default = true
    },
    {
      label = "Workers",
      description = "The maximum amount of threads to create per search.",
      path = "threading.workers",
      type = "number",
      default = math.ceil(thread.get_cpu_count() / 2) + 1,
      min = 1
    }
  }
}, config.plugins.projectsearch)


---@class ResultsView : core.view
local ResultsView = View:extend()

ResultsView.context = "session"

function ResultsView:new(path, text, type, insensitive, fn)
  ResultsView.super.new(self)
  self.scrollable = true
  self.brightness = 0
  self:begin_search(path, text, type, insensitive, fn)
end


function ResultsView:get_name()
  return "Search Results"
end


local function find_all_matches_in_file(t, filename, fn)
  local fp = io.open(filename)
  if not fp then return t end
  local n = 1
  for line in fp:lines() do
    local s = fn(line)
    if s then
      -- Insert maximum 256 characters. If we insert more, for compiled files,
      -- which can have very long lines things tend to get sluggish. If our
      -- line is longer than 80 characters, begin to truncate the thing.
      local start_index = math.max(s - 80, 1)
      table.insert(t, {
        filename,
        (start_index > 1 and "..." or "")
          .. line:sub(start_index, 256 + start_index),
        n,
        s
      })
      core.redraw = true
    end
    if n % 100 == 0 then coroutine.yield() end
    n = n + 1
    core.redraw = true
  end
  fp:close()
end

--unique thread id to allow multiple threaded searches to be launched
local files_search_threaded_id = 0
local function files_search_threaded(
  tid, text, search_type, insensitive, project_dir, path, pathsep, ignore_files, workers
)
  local commons = require "core.common"
  tid = math.floor(tid)

  ---A thread that waits for filenames to search the given text. If the given
  ---filename is "{{stop}}" then the thread will finish and exit.
  ---@param tid number The id of the main thread pool
  ---@param id number The id given to the thread
  ---@param text string The text or regex to search
  ---@param search_type '"plain"' | '"regex"' | '"fuzzy"'
  ---@return integer status_code
  local function worker_find_in_file(tid, id, project_dir, text, search_type, insensitive)
    local core_common = require "core.common"
    tid = math.floor(tid)
    id = math.floor(id)
    local results_channel = thread.get_channel("projectsearch_results"..tid..id)
    local filename_channel = thread.get_channel("projectsearch_fname"..tid..id)

    local re = nil
    if search_type == "regex" then
      if insensitive then
        re = regex.compile(text, "i")
      else
        re = regex.compile(text)
      end
    elseif search_type ~= "fuzzy" and insensitive then
      text = text:lower()
    end

    local filename = filename_channel:wait()
    while filename ~= "{{stop}}" do
      local results = {}
      local found = false
      local fp = io.open(filename)
      if fp then
        local n = 1
        for line in fp:lines() do
          local s = nil
          if search_type == "regex" then
            s = regex.cmatch(re, line)
          elseif search_type == "fuzzy" then
            s = core_common.fuzzy_match(line, text) and 1
          else
            if insensitive then
              s = line:lower():find(text, 1, true)
            else
              s = line:find(text, 1, true)
            end
          end
          if s then
            local start_index = math.max(s - 80, 1)
            table.insert(results, {
              core_common.relative_path(project_dir, filename),
              (start_index > 1 and "..." or "")
                .. line:sub(start_index, 256 + start_index),
              n,
              s
            })
            found = true
          end
          n = n + 1
        end
        fp:close()
      end
      if found then
        results_channel:push(results)
      else
        results_channel:push("")
      end
      filename_channel:pop()
      filename = filename_channel:wait()
      while filename == nil do
        filename = filename_channel:first()
      end
    end
    return 0
  end

  ---Wait for a list of workers to finish
  ---@param list thread.Thread[]
  local function workers_wait(list)
    if #list > 0 then
      list[1]:wait()
      table.remove(list, 1)
      workers_wait(list)
    end
  end

  -- channel used to inform the status of searching to coroutine
  -- the current dir/file index been searched is sent or "finished" on end
  local channel_status = thread.get_channel("projectsearch_status"..tid)

  local root = path
  local count = 0
  local directories = {""}
  ---@type thread.Thread[]
  local workers_list = {}
  ---@type thread.Channel[]
  local result_channels = {}
  ---@type thread.Channel[]
  local filename_channels = {}

  workers = workers or math.ceil(thread.get_cpu_count() / 2) + 1
  for id=1, workers, 1 do
    table.insert(
      filename_channels,
      thread.get_channel("projectsearch_fname"..tid..id)
    )
    table.insert(
      result_channels,
      thread.get_channel("projectsearch_results"..tid..id)
    )
    table.insert(workers_list, thread.create(
      "pswrk"..tid..id, -- projectsearch worker
      worker_find_in_file,
      tid,
      id,
      project_dir,
      text,
      search_type,
      insensitive
    ))
  end

  local current_worker = 1
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
          count = count + 1
          if
            info and not commons.match_pattern(
              directory .. file, ignore_files
            )
          then
            if info.type == "dir" then
              table.insert(directories, directory .. file)
            else
              filename_channels[current_worker]:push(dir_path .. pathsep .. file)
              current_worker = current_worker + 1
              if current_worker > workers then current_worker = 1 end
            end
          end
        end
      end
      table.remove(directories, didx)
      break
    end

    channel_status:clear()
    channel_status:push(count)
  end

  for id=1, workers, 1 do
    filename_channels[id]:push("{{stop}}")
  end

  -- before sending the "finished" status we wait for threads to finish
  workers_wait(workers_list)

  channel_status:clear()
  channel_status:push("finished")
  collectgarbage("collect")
end


---Sync the results found on the threads into the View search results.
---@param self ResultsView
---@param result_channels thread.Channel[]
local function worker_threads_add_results(self, result_channels)
  local found = false
  for _, channel_results in ipairs(result_channels) do
    local results = channel_results:first()
    if results then
      self.last_file_idx = self.last_file_idx + 1
      channel_results:pop()
      if type(results) == "table" then
        for _, result in ipairs(results) do
          table.insert(self.results, result)
        end
      end
      found = true
    end
  end
  return found
end


function ResultsView:begin_search(path, text, search_type, insensitive, fn)
  self.search_args = { path, text, search_type, fn }
  self.results = {}
  self.last_file_idx = 1
  self.query = text
  self.searching = true
  self.selected_idx = 0
  self.total_files = 0
  self.start_time = system.get_time()
  self.end_time = self.start_time

  core.add_thread(function()
    if not config.plugins.projectsearch.threading.enabled then
      local i = 1
      for dir_name, file in core.get_project_files() do
        if file.type == "file" and (not path or (dir_name .. "/" .. file.filename):find(path, 1, true) == 1) then
          local truncated_path = (dir_name == core.project_dir and "" or (dir_name .. PATHSEP))
          find_all_matches_in_file(self.results, truncated_path .. file.filename, fn)
        end
        self.last_file_idx = i
        i = i + 1
      end
    else
      files_search_threaded_id = files_search_threaded_id + 1
      local tid = files_search_threaded_id
      local workers = config.plugins.projectsearch.threading.workers
      thread.create(
        "pspool"..tid,
        files_search_threaded,
        files_search_threaded_id,
        text,
        search_type,
        insensitive,
        core.project_dir,
        path or core.project_dir,
        PATHSEP,
        config.ignore_files,
        workers
      )
      ---@type thread.Channel
      local result_channels = {}
      for id=1, workers, 1 do
        table.insert(
          result_channels,
          thread.get_channel("projectsearch_results"..tid..id)
        )
      end
      local channel_status = thread.get_channel("projectsearch_status"..tid)
      local status = channel_status:first()
      local count = 1
      while type(status) ~= "string" do
        if type(status) == "number" then
          self.total_files = status
        end
        -- add some of the results found
        worker_threads_add_results(self, result_channels)
        count = count + 1
        coroutine.yield()
        core.redraw = true
        status = channel_status:first()
      end
      channel_status:clear()
      -- add any remaining results
      while worker_threads_add_results(self, result_channels) do end
    end
    -- the search was completed
    self.searching = false
    self.brightness = 100
    core.redraw = true
    self.end_time = system.get_time()
  end, self.results)

  self.scroll.to.y = 0
end


function ResultsView:refresh()
  self:begin_search(table.unpack(self.search_args))
end


function ResultsView:on_mouse_moved(mx, my, ...)
  ResultsView.super.on_mouse_moved(self, mx, my, ...)
  self.selected_idx = 0
  for i, item, x,y,w,h in self:each_visible_result() do
    if mx >= x and my >= y and mx < x + w and my < y + h then
      self.selected_idx = i
      break
    end
  end
end


function ResultsView:on_mouse_pressed(...)
  local caught = ResultsView.super.on_mouse_pressed(self, ...)
  if not caught then
    return self:open_selected_result()
  end
end


function ResultsView:open_selected_result()
  local res = self.results[self.selected_idx]
  if not res then
    return
  end
  core.try(function()
    local dv = core.root_view:open_doc(core.open_doc(res[1]))
    core.root_view.root_node:update_layout()
    dv.doc:set_selection(res[3], res[4])
    dv:scroll_to_line(res[3], false, true)
  end)
  return true
end


function ResultsView:update()
  self:move_towards("brightness", 0, 0.1)
  ResultsView.super.update(self)
end


function ResultsView:get_results_yoffset()
  return style.font:get_height() + style.padding.y * 3
end


function ResultsView:get_line_height()
  return style.padding.y + style.font:get_height()
end


function ResultsView:get_scrollable_size()
  return self:get_results_yoffset() + #self.results * self:get_line_height()
end


function ResultsView:get_visible_results_range()
  local lh = self:get_line_height()
  local oy = self:get_results_yoffset()
  local min = math.max(1, math.floor((self.scroll.y - oy) / lh))
  return min, min + math.floor(self.size.y / lh) + 1
end


function ResultsView:each_visible_result()
  return coroutine.wrap(function()
    local lh = self:get_line_height()
    local x, y = self:get_content_offset()
    local min, max = self:get_visible_results_range()
    y = y + self:get_results_yoffset() + lh * (min - 1)
    for i = min, max do
      local item = self.results[i]
      if not item then break end
      coroutine.yield(i, item, x, y, self.size.x, lh)
      y = y + lh
    end
  end)
end


function ResultsView:scroll_to_make_selected_visible()
  local h = self:get_line_height()
  local y = self:get_results_yoffset() + h * (self.selected_idx - 1)
  self.scroll.to.y = math.min(self.scroll.to.y, y)
  self.scroll.to.y = math.max(self.scroll.to.y, y + h - self.size.y)
end


function ResultsView:draw()
  self:draw_background(style.background)

  -- status
  local ox, oy = self:get_content_offset()
  local x, y = ox + style.padding.x, oy + style.padding.y
  local files_number = 0
  if not config.plugins.projectsearch.threading.enabled then
    files_number = core.project_files_number()
  else
    files_number = self.total_files
  end
  local per = common.clamp(files_number and self.last_file_idx / files_number or 1, 0, 1)
  local text
  if self.searching then
    if files_number then
      text = string.format(
        "Searching %.f%% (%d of %d files, %d matches) for %q...",
        per * 100, self.last_file_idx, files_number,
        #self.results, self.query
      )
    else
      text = string.format(
        "Searching (%d files, %d matches) for %q...",
        self.last_file_idx, #self.results, self.query
      )
    end
  else
    text = string.format(
      "Found %d matches in %.2fs for %q",
      #self.results, self.end_time - self.start_time, self.query
    )
  end
  local color = common.lerp(style.text, style.accent, self.brightness / 100)
  renderer.draw_text(style.font, text, x, y, color)

  -- horizontal line
  local yoffset = self:get_results_yoffset()
  local x = ox + style.padding.x
  local w = self.size.x - style.padding.x * 2
  local h = style.divider_size
  local color = common.lerp(style.dim, style.text, self.brightness / 100)
  renderer.draw_rect(x, oy + yoffset - style.padding.y, w, h, color)
  if self.searching then
    renderer.draw_rect(x, oy + yoffset - style.padding.y, w * per, h, style.text)
  end

  -- results
  local y1, y2 = self.position.y, self.position.y + self.size.y
  for i, item, x,y,w,h in self:each_visible_result() do
    local color = style.text
    if i == self.selected_idx then
      color = style.accent
      renderer.draw_rect(x, y, w, h, style.line_highlight)
    end
    x = x + style.padding.x
    local text = string.format("%s at line %d (col %d): ", item[1], item[3], item[4])
    x = common.draw_text(style.font, style.dim, text, "left", x, y, w, h)
    x = common.draw_text(style.code_font, color, item[2], "left", x, y, w, h)
  end

  self:draw_scrollbar()
end


local function begin_search(path, text, search_type, insensitive, fn)
  if text == "" then
    core.error("Expected non-empty string")
    return
  end
  local rv = ResultsView(path, text, search_type, insensitive, fn)
  core.root_view:get_active_node_default():add_view(rv)
  return rv
end


local function get_selected_text()
  local view = core.active_view
  local doc = (view and view.doc) and view.doc or nil
  if doc then
    return doc:get_text(table.unpack({ doc:get_selection() }))
  end
end


local function normalize_path(path)
  if not path then return nil end
  path = common.normalize_path(path)
  for i, project_dir in ipairs(core.project_directories) do
    if common.path_belongs_to(path, project_dir.name) then
      return project_dir.item.filename .. PATHSEP .. common.relative_path(project_dir.name, path)
    end
  end
  return path
end

---@class plugins.projectsearch
local projectsearch = {}

---@type plugins.projectsearch.resultsview
projectsearch.ResultsView = ResultsView

---@param text string
---@param path string
---@param insensitive? boolean
---@return plugins.projectsearch.resultsview?
function projectsearch.search_plain(text, path, insensitive)
  if insensitive then text = text:lower() end
  return begin_search(path, text, "plain", insensitive, function(line_text)
    if insensitive then
      return line_text:lower():find(text, nil, true)
    else
      return line_text:find(text, nil, true)
    end
  end)
end

---@param text string
---@param path string
---@param insensitive? boolean
---@return plugins.projectsearch.resultsview?
function projectsearch.search_regex(text, path, insensitive)
  local re, errmsg
  if insensitive then
    re, errmsg = regex.compile(text, "i")
  else
    re, errmsg = regex.compile(text)
  end
  if not re then core.log("%s", errmsg) return end
  return begin_search(path, text, "regex", insensitive, function(line_text)
    return regex.cmatch(re, line_text)
  end)
end

---@param text string
---@param path string
---@param insensitive? boolean
---@return plugins.projectsearch.resultsview?
function projectsearch.search_fuzzy(text, path, insensitive)
  if insensitive then text = text:lower() end
  return begin_search(path, text, "fuzzy", insensitive, function(line_text)
    if insensitive then
      return common.fuzzy_match(line_text:lower(), text) and 1
    else
      return common.fuzzy_match(line_text, text) and 1
    end
  end)
end


command.add(nil, {
  ["project-search:find"] = function(path)
    core.command_view:enter("Find Text In " .. (normalize_path(path) or "Project"), {
      text = get_selected_text(),
      select_text = true,
      submit = function(text)
        projectsearch.search_plain(text, path, true)
      end
    })
  end,

  ["project-search:find-regex"] = function(path)
    core.command_view:enter("Find Regex In " .. (normalize_path(path) or "Project"), {
      submit = function(text)
        projectsearch.search_regex(text, path, true)
      end
    })
  end,

  ["project-search:fuzzy-find"] = function(path)
    core.command_view:enter("Fuzzy Find Text In " .. (normalize_path(path) or "Project"), {
      text = get_selected_text(),
      select_text = true,
      submit = function(text)
        projectsearch.search_fuzzy(text, path, true)
      end
    })
  end,
})


command.add(ResultsView, {
  ["project-search:select-previous"] = function()
    local view = core.active_view
    view.selected_idx = math.max(view.selected_idx - 1, 1)
    view:scroll_to_make_selected_visible()
  end,

  ["project-search:select-next"] = function()
    local view = core.active_view
    view.selected_idx = math.min(view.selected_idx + 1, #view.results)
    view:scroll_to_make_selected_visible()
  end,

  ["project-search:open-selected"] = function()
    core.active_view:open_selected_result()
  end,

  ["project-search:refresh"] = function()
    core.active_view:refresh()
  end,

  ["project-search:move-to-previous-page"] = function()
    local view = core.active_view
    view.scroll.to.y = view.scroll.to.y - view.size.y
  end,

  ["project-search:move-to-next-page"] = function()
    local view = core.active_view
    view.scroll.to.y = view.scroll.to.y + view.size.y
  end,

  ["project-search:move-to-start-of-doc"] = function()
    local view = core.active_view
    view.scroll.to.y = 0
  end,

  ["project-search:move-to-end-of-doc"] = function()
    local view = core.active_view
    view.scroll.to.y = view:get_scrollable_size()
  end
})

keymap.add {
  ["f5"]                 = "project-search:refresh",
  ["ctrl+shift+f"]       = "project-search:find",
  ["up"]                 = "project-search:select-previous",
  ["down"]               = "project-search:select-next",
  ["return"]             = "project-search:open-selected",
  ["pageup"]             = "project-search:move-to-previous-page",
  ["pagedown"]           = "project-search:move-to-next-page",
  ["ctrl+home"]          = "project-search:move-to-start-of-doc",
  ["ctrl+end"]           = "project-search:move-to-end-of-doc",
  ["home"]               = "project-search:move-to-start-of-doc",
  ["end"]                = "project-search:move-to-end-of-doc"
}


return projectsearch
