-- mod-version:3
local core = require "core"
local common = require "core.common"
local keymap = require "core.keymap"
local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local Widget = require "widget"
local Button = require "widget.button"
local SearchReplaceList = require "widget.searchreplacelist"

config.plugins.projectsearch = common.merge({
  threading = {
    workers = math.ceil(thread.get_cpu_count() / 2) + 1
  },
  -- The config specification used by gui generators
  config_spec = {
    name = "Project Search",
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

---Unique id used to allow multiple threaded searches to be launched
---@type integer
local threaded_search_id = 0

---Unique id used to allow multiple threaded replaces to be launched
---@type integer
local threaded_replace_id = 0

---@class plugins.projectsearch.resultsview : widget
---@field results_list widget.searchreplacelist
---@overload fun(path?:string,text:string,type:'"plain"'|'"regex"',insensitive?:boolean,whole_word?:boolean,replacement?:string):plugins.projectsearch.resultsview
local ResultsView = Widget:extend()

ResultsView.context = "session"

---Constructor
function ResultsView:new(path, text, type, insensitive, whole_word, replacement)
  ResultsView.super.new(self)
  self.defer_draw = false
  self.scrollable = true
  self.brightness = 0
  self.path = path
  self.query = text
  self.search_type = type
  self.insensitive = insensitive
  self.whole_word = whole_word
  self.replacement = replacement

  self.results_list = SearchReplaceList(self, self.replacement)
  self.results_list.border.width = 0
  self.results_list.on_item_click = function(this, item, clicks)
    self:open_selected_result()
  end

  if replacement then
    self.apply_button = Button(self, "Apply Replacement")
    self.apply_button:hide()
    self.apply_button.on_click = function(this, button, x, y)
      self:begin_replace()
    end
  end

  self:begin_search(path, text, type, insensitive, whole_word)
end


---Text displayed on the application title and view tab.
---@return string
function ResultsView:get_name()
  return "Project Search and Replace"
end


---File searching thread function that uses worker threads to perform
---multi-file searching.
---@param tid integer
---@param options table<string,string>
local function files_search_thread(tid, options)
  local commons = require "core.common"
  tid = math.floor(tid)

  local text = options.text
  local search_type = options.search_type or "plain"
  local insensitive = options.insensitive or false
  local whole = options.whole_word or false
  local path = options.path
  local pathsep = options.pathsep or "/"
  local ignore_files = options.ignore_files or {}
  local workers = options.workers or 2
  local file_size_limit = options.file_size_limit or (10 * 1e6)

  ---A thread that waits for filenames to search the given text. If the given
  ---filename is "{{stop}}" then the thread will finish and exit.
  ---@param tid number The id of the main thread pool
  ---@param id number The id given to the thread
  ---@param text string The text or regex to search
  ---@param search_type '"plain"' | '"regex"'
  ---@param insensitive boolean
  ---@param whole boolean
  ---@return integer status_code
  local function worker_find_in_file(
    tid, id, text, search_type, insensitive, whole
  )
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
    elseif insensitive then
      text = text:lower()
    end

    local function is_whole_match(line_text, col1, col2)
      if
        (col1 ~= 1 and line_text:sub(col1-1, col1-1):match("[%w_]"))
        or
        (col2 ~= #line_text and line_text:sub(col2+1, col2+1):match("[%w_]"))
      then
        return false
      end
      return true
    end

    local filename = filename_channel:wait()
    while filename ~= "{{stop}}" do
      local results = {}
      local found = false
      local fp = io.open(filename)
      if fp then
        local lines = {}
        local n = 1
        for line in fp:lines() do
          local positions = {}
          local s, e = nil, 1
          if search_type == "regex" then
            repeat
              s, e = regex.cmatch(re, line, e)
              local matches = true
              if s and whole and not is_whole_match(line, s, e - 1) then
                matches = false
              end
              if s and matches then
                table.insert(positions, {col1=s, col2=e - 1})
              end
            until not s
          else
            local l = insensitive and line:lower() or line
            repeat
              s, e = l:find(text, e, true)
              local matches = true
              if s and whole and not is_whole_match(l, s, e) then
                matches = false
              end
              if s and matches then
                table.insert(positions, {col1=s, col2=e})
              end
              if e then e = e + 1 end
            until not s
          end
          if #positions > 0 then
            table.insert(lines, {
              line,
              n,
              positions
            })
            found = true
          end
          n = n + 1
        end
        fp:close()
        table.insert(results, {
          filename,
          lines
        })
      end
      if found then
        results_channel:push(results)
      else
        results_channel:push(true)
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
      text,
      search_type,
      insensitive,
      whole
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
            info and not commons.match_ignore_rule(
              directory..file, info, ignore_files
            )
          then
            if info.type == "dir" then
              table.insert(directories, directory .. file)
            elseif info.size <= file_size_limit then
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


---Sync results found on the files_search_thread into the results list.
---@param self plugins.projectsearch.resultsview
---@param result_channels thread.Channel[]
local function worker_threads_add_results(self, result_channels)
  local found = false
  for _, channel_results in ipairs(result_channels) do
    local results = channel_results:first()
    if results then
      self.total_files_processed = self.total_files_processed + 1
      channel_results:pop()
      if type(results) == "table" then
        for _, result in ipairs(results) do
          local lines = {}
          for _, line in ipairs(result[2]) do
            table.insert(lines, {
              text = line[1],
              line = line[2],
              positions = line[3]
            })
          end
          self.results_list:add_file(result[1], lines)
        end
      end
      found = true
    end
  end
  return found
end


---Start the search procedure and worker threads.
---@param path? string
---@param text string
---@param search_type "plain" | "regex"
---@param insensitive? boolean
---@param whole_word? boolean
function ResultsView:begin_search(path, text, search_type, insensitive, whole_word)
  path = path or core.root_project().path

  self.results_list:clear()
  self.total_files_processed = 0
  self.searching = true
  self.total_files = 0
  self.start_time = system.get_time()
  self.end_time = self.start_time
  self.results_list.base_dir = path

  core.add_thread(function()
    threaded_search_id = threaded_search_id + 1
    local tid = threaded_search_id
    local workers = config.plugins.projectsearch.threading.workers
    thread.create(
      "pspool"..tid,
      files_search_thread,
      threaded_search_id,
      {
        text = text,
        search_type = search_type,
        insensitive = insensitive,
        whole_word = whole_word,
        path = path,
        pathsep = PATHSEP,
        ignore_files = core.get_ignore_file_rules(),
        workers = workers,
        file_size_limit = config.file_size_limit * 1e6
      }
    )
    ---@type thread.Channel[]
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
    -- the search was completed
    self.searching = false
    self.brightness = 100
    core.redraw = true
    self.end_time = system.get_time()
  end, self.results_list.items)

  self.scroll.to.y = 0
end


---File text replacing thread function that uses worker threads to perform
---multi-file replacing.
---@param tid integer
---@param id integer
---@param replacement string
local function files_replace_thread(tid, id, replacement)
  local replace_channel = thread.get_channel("projectsearch_replace"..tid..id)
  local status_channel = thread.get_channel("projectsearch_replace_status"..tid..id)
  local replacement_len = #replacement

  if not replace_channel or not status_channel then
    error("could not retrieve channels for files replace thread")
    return
  end

  local replace_substring = function(str, s, e, rep)
    local head = s <= 1 and "" or string.sub(str, 1, s - 1)
    local tail = e >= #str and "" or string.sub(str, e + 1)
    return head .. rep .. tail
  end

  local file_data = replace_channel:wait()

  while file_data ~= "{{stop}}" do
    local file_path = file_data[2].path
    local file = io.open(file_path, "r")

    if file then
      local ln = 0
      local lines = {}

      ---@type widget.searchreplacelist.file
      local results = file_data[2]

      for line in file:lines("L") do
        ln = ln + 1

        if results.lines[1] and results.lines[1].line == ln then
          local offset = 0

          for _, pos in ipairs(results.lines[1].positions) do
            local col1 = pos.col1 + offset
            local col2 = pos.col2 + offset

            if pos.checked or type(pos.checked) == "nil" then
              line = replace_substring(line, col1, col2, replacement)
              local current_len = col2 - col1 + 1
              if current_len > replacement_len then
                offset = offset - (current_len - replacement_len)
              elseif current_len < replacement_len then
                offset = offset + (replacement_len - current_len)
              end
            end
          end

          table.remove(results.lines, 1)
        end

        table.insert(lines, line)
      end

      file:close()

      file = io.open(file_path, "w")
      if file then
        for _, line in ipairs(lines) do
          file:write(line)
        end
        file:close()
      end
    end

    replace_channel:pop()
    status_channel:push(file_data[1])
    file_data = replace_channel:wait()
  end

  replace_channel:clear()
  status_channel:push("{{done}}")
end


---Starts the replacement procedure and worker threads using
---previously matched results.
function ResultsView:begin_replace()
  core.add_thread(function()
    self.brightness = 0
    self.replacing = true
    self.total_files_processed = 0
    self.start_time = system.get_time()
    self.end_time = self.start_time
    threaded_replace_id = threaded_replace_id + 1
    local tid = threaded_replace_id
    local workers = math.min(
      config.plugins.projectsearch.threading.workers,
      self.results_list.total_files
    )

    ---@type thread.Channel[]
    local replace_channels = {}
    ---@type thread.Channel[]
    local status_channels = {}

    -- create all threads and channels
    for id=1, workers, 1 do
      table.insert(
        replace_channels,
        thread.get_channel("projectsearch_replace"..tid..id)
      )
      table.insert(
        status_channels,
        thread.get_channel("projectsearch_replace_status"..tid..id)
      )
      thread.create(
        "psrpool"..tid..id, files_replace_thread, tid, id, self.replacement
      )
    end

    -- populate all replace channels by distributing the load
    local next_replace_channel = 1
    for i, file in self.results_list:each_file() do
      replace_channels[next_replace_channel]:push({i, file})
      next_replace_channel = next_replace_channel + 1
      if next_replace_channel > workers then
        next_replace_channel = 1
      end
      if i % 100 == 0 then
        coroutine.yield()
        core.redraw = true
      end
    end

    -- send stop command to all threads
    for _, chan in ipairs(replace_channels) do
      chan:push("{{stop}}")
    end

    -- wait for all worked threads to finish
    local c = 0
    while #status_channels > 0 do
      for i=1, #status_channels do
        local value
        repeat
          value = status_channels[i]:first()
          if value == "{{done}}" then
            status_channels[i]:clear()
            table.remove(status_channels, i)
            goto outside
          elseif type(value) == "number" then
            self.total_files_processed = self.total_files_processed + 1
            status_channels[i]:pop()
            self.results_list:apply_replacement(value)
            local item = self.results_list.items[value]
            for _, doc in ipairs(core.docs) do
              if doc.abs_filename and item.file.path == doc.abs_filename then
                doc:reload()
              end
            end
            core.redraw = true
          end
          if c % 100 == 0 then coroutine.yield() end
          c = c + 1
        until not value
        core.redraw = true
      end
      ::outside::
      c = c + 1
      core.redraw = true
      if c % 100 == 0 then coroutine.yield() end
    end

    self.results_list.replacement = nil
    self.replacing = false
    self.replaced = true
    self.brightness = 100
    self.end_time = system.get_time()
  end)
end


---Re-perform the search procedure using previous search options.
function ResultsView:refresh()
  self:begin_search(
    self.path, self.query, self.search_type, self.insensitive, self.whole_word
  )
end


---Opens a DocView of the user selected match.
function ResultsView:open_selected_result()
  local item = self.results_list:get_selected()
  if not item or not item.position then return end
  core.try(function()
    local dv = core.root_view:open_doc(core.open_doc(item.parent.file.path))
    core.root_view.root_node:update_layout()
    local l, c1, c2 = item.line.line, item.position.col1, item.position.col2+1
    dv.doc:set_selection(l, c2, l, c1)
    dv:scroll_to_line(l, false, true)
  end)
  return true
end


function ResultsView:update()
  if not ResultsView.super.update(self) then return false end
  self:move_towards("brightness", 0, 0.1)
  -- results
  local yoffset = style.font:get_height() + style.padding.y * 3
  self.results_list:set_position(0, yoffset)
  self.results_list:set_size(self.size.x, self.size.y - yoffset)
  -- apply button
  if self.apply_button and not self.replacing then
    self.apply_button:show()
    self.apply_button:set_position(
      self.results_list:get_right() - self.apply_button:get_width() - style.padding.x,
      self.results_list:get_position().y
    )
  elseif self.apply_button and self.replacing then
    self:remove_child(self.apply_button)
    self.apply_button = nil
  end
end


function ResultsView:draw()
  if not ResultsView.super.draw(self) then return false end

  -- status
  local ox, oy = self:get_content_offset()
  local x, y = ox + style.padding.x, oy + style.padding.y
  local per = common.clamp(self.total_files_processed / self.total_files, 0, 1)
  local text
  if self.searching then
    text = string.format(
      "Searching %.f%% (%d of %d files, %d matches) for %q...",
      per * 100, self.total_files_processed, self.total_files,
      self.results_list.total_files, self.query
    )
  elseif self.replacing then
    text = string.format(
      "Replacing %.f%% (%d of %d files) %q -> %q...",
      per * 100, self.total_files_processed, self.results_list.total_files,
      self.query, self.replacement
    )
  elseif self.replaced then
    text = string.format(
      "Replaced in %d files in %.2fs %q -> %q",
      self.total_files_processed, self.end_time - self.start_time,
      self.query, self.replacement
    )
  else
    text = string.format(
      "Found %d matches in %d files in %.2fs for %q",
      self.results_list.total_results, self.results_list.total_files,
      self.end_time - self.start_time, self.query
    )
  end
  local color = common.lerp(style.text, style.accent, self.brightness / 100)
  renderer.draw_text(style.font, text, x, y, color)

  -- horizontal line
  local yoffset = style.font:get_height() + style.padding.y * 3
  local w = self.size.x - style.padding.x * 2
  local h = style.divider_size
  x = ox + style.padding.x
  color = common.lerp(style.dim, style.text, self.brightness / 100)
  renderer.draw_rect(x, oy + yoffset - style.padding.y, w, h, color)
  if self.searching or self.replacing then
    renderer.draw_rect(x, oy + yoffset - style.padding.y, w * per, h, style.text)
  end

  self:draw_scrollbar()
end


---Helper function to instantiate a new ResultsView and add it to root view.
---@param path? string
---@param text string
---@param search_type "plain" | "regex"
---@param insensitive? boolean
---@param whole_word? boolean
---@param replacement? string
---@return plugins.projectsearch.resultsview?
local function begin_search(path, text, search_type, insensitive, whole_word, replacement)
  if text == "" then core.error("Expected non-empty string") return end
  local rv = ResultsView(
    path, text, search_type, insensitive, whole_word, replacement
  )
  rv:show()
  core.root_view:get_active_node_default():add_view(rv)
  return rv
end


---Helper function to get the current document selected text to use it
---as the query when invoking the search prompt.
---@return string?
local function get_selected_text()
  local view = core.active_view
  local doc = (view and view.doc) and view.doc or nil
  if doc then
    return doc:get_text(table.unpack({ doc:get_selection() }))
  end
end

---@class plugins.projectsearch
local projectsearch = {}

---@type plugins.projectsearch.resultsview
projectsearch.ResultsView = ResultsView

---Start a plain text search.
---@param text string
---@param path? string
---@param insensitive? boolean
---@param whole_word? boolean
---@param replacement? string
---@return plugins.projectsearch.resultsview?
function projectsearch.search_plain(text, path, insensitive, whole_word, replacement)
  if insensitive then text = text:lower() end
  return begin_search(path, text, "plain", insensitive, whole_word, replacement)
end

---Start a regex search.
---@param text string
---@param path? string
---@param insensitive? boolean
---@param whole_word? boolean
---@param replacement? string
---@return plugins.projectsearch.resultsview?
function projectsearch.search_regex(text, path, insensitive, whole_word, replacement)
  local re, errmsg
  if insensitive then
    re, errmsg = regex.compile(text, "i")
  else
    re, errmsg = regex.compile(text)
  end
  if not re then core.log("%s", errmsg) return end
  return begin_search(path, text, "regex", insensitive, whole_word, replacement)
end


command.add(nil, {
  ["project-search:find"] = function(path)
    core.command_view:enter("Find Text In " .. (path or "Project"), {
      text = get_selected_text(),
      select_text = true,
      submit = function(text)
        projectsearch.search_plain(text, path, true)
      end
    })
  end,

  ["project-search:find-regex"] = function(path)
    core.command_view:enter("Find Regex In " .. (path or "Project"), {
      submit = function(text)
        projectsearch.search_regex(text, path, true)
      end
    })
  end,
})


command.add(ResultsView, {
  ["project-search:select-previous"] = function(view)
    view.results_list:select_prev()
  end,

  ["project-search:select-next"] = function(view)
    view.results_list:select_next()
  end,

  ["project-search:toggle-expand"] = function(view)
    view.results_list:toggle_expand(view.results_list.selected)
  end,

  ["project-search:toggle-checkbox"] = function(view)
    view.results_list:toggle_check(view.results_list.selected)
  end,

  ["project-search:open-selected"] = function(view)
    view:open_selected_result()
  end,

  ["project-search:refresh"] = function(view)
    view:refresh()
  end,

  ["project-search:move-to-previous-page"] = function(view)
    view.results_list.scroll.to.y = view.results_list.scroll.to.y - view.results_list.size.y
  end,

  ["project-search:move-to-next-page"] = function(view)
    view.results_list.scroll.to.y = view.results_list.scroll.to.y + view.results_list.size.y
  end,

  ["project-search:move-to-start-of-doc"] = function(view)
    view.results_list.scroll.to.y = 0
  end,

  ["project-search:move-to-end-of-doc"] = function(view)
    view.results_list.scroll.to.y = view.results_list:get_scrollable_size()
  end
})

keymap.add {
  ["f5"]                 = "project-search:refresh",
  ["ctrl+shift+f"]       = "project-search:find",
  ["up"]                 = "project-search:select-previous",
  ["down"]               = "project-search:select-next",
  ["left"]               = "project-search:toggle-expand",
  ["right"]              = "project-search:toggle-expand",
  ["space"]              = "project-search:toggle-checkbox",
  ["return"]             = "project-search:open-selected",
  ["pageup"]             = "project-search:move-to-previous-page",
  ["pagedown"]           = "project-search:move-to-next-page",
  ["ctrl+home"]          = "project-search:move-to-start-of-doc",
  ["ctrl+end"]           = "project-search:move-to-end-of-doc",
  ["home"]               = "project-search:move-to-start-of-doc",
  ["end"]                = "project-search:move-to-end-of-doc"
}


return projectsearch
