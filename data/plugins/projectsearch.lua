-- mod-version:3
local core = require "core"
local common = require "core.common"
local keymap = require "core.keymap"
local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local DocView = require "core.docview"
local Widget = require "widget"
local Button = require "widget.button"
local FilePicker = require "widget.filepicker"
local MessageBox = require "widget.messagebox"
local SearchReplaceList = require "widget.searchreplacelist"
local TextBox = require "widget.textbox"
local ToggleButton = require "widget.togglebutton"

local treeview
core.add_thread(function()
  if config.plugins.treeview ~= false then
    treeview = require "plugins.treeview"
  end
end)

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

function ResultsView:__tostring() return "ResultsView" end

---Show a currently searching or replacing warning
---@param status "Search" | "Replace"
local function report_status(status)
  MessageBox.warning(
    string.format("%s in progress...", status),
    string.format(
      "A %s is still running, please wait for it to finish.",
      status:lower()
    )
  )
end

---Constructor
---@param path? string
---@param text string
---@param search_type? "plain"|"regex"
---@param insensitive? boolean
---@param whole_word? boolean
---@param replacement? string
function ResultsView:new(path, text, search_type, insensitive, whole_word, replacement)
  ResultsView.super.new(self, nil, false)
  self.type_name = "plugins.projectsearch.resultsview"
  self.is_global = false
  self.defer_draw = false
  self.scrollable = true
  self.brightness = 0
  self.searching = false
  self.replacing = false
  self.path = path
  self.query = text
  self.search_type = search_type or "plain"
  self.insensitive = insensitive or true
  self.whole_word = whole_word or false
  self.replacement = replacement

  self.close_button = Button(self)
  self.close_button:set_icon("C")
  self.close_button:set_tooltip("Close project search", "project-search:find")
  self.close_button.border.width = 0
  self.close_button.padding.x = self.close_button.padding.x / 2
  self.close_button.padding.y = self.close_button.padding.y / 5
  self.close_button:hide()

  self.find_text = TextBox(self, text, "search...")
  self.find_button = Button(self, "Find")
  self.find_button:set_tooltip(nil, "project-search:refresh")

  self.replace_text = TextBox(self, replacement or "", "replacement...")
  self.replace_button = Button(self, "Replace")
  self.replace_button:set_tooltip(nil, "project-search:replace")

  self.includes_text = TextBox(self, "", "Include: src/**.ext, *.ext")
  self.excludes_text = TextBox(self, "", "Exclude: vendor, src/extras")

  self.file_picker = FilePicker(self, path)
  self.file_picker:set_mode(FilePicker.mode.DIRECTORY)

  self.sensitive_toggle = ToggleButton(self, not self.insensitive, nil, "o")
  self.sensitive_toggle:set_tooltip(nil, "project-search:toggle-case-sensitive")

  self.wholeword_toggle = ToggleButton(self, self.whole_word, nil, "O")
  self.wholeword_toggle:set_tooltip(nil, "project-search:toggle-whole-words")

  self.regex_toggle = ToggleButton(self, self.search_type == "regex", nil, "r")
  self.regex_toggle:set_tooltip(nil, "project-search:toggle-regex")

  self.replace_toggle = ToggleButton(self, type(replacement) == "string", nil, "s")
  self.replace_toggle:set_tooltip(nil, "project-search:toggle-replace-mode")

  self.filters_toggle = ToggleButton(self, false, nil, "&")
  self.filters_toggle:set_tooltip(nil, "project-search:toggle-file-filters")

  self.results_list = SearchReplaceList(
    self,
    self.replacement,
    (self.replacement and self.regex_toggle:is_toggled())
      and self.find_text:get_text()
      or nil,
    self.sensitive_toggle:is_toggled()
  )
  self.results_list.border.width = 0
  self.results_list.on_item_click = function(this, item, clicks)
    self:open_selected_result()
  end

  local function toggle_filters(enabled)
    if enabled then
      self.includes_text:show()
      self.excludes_text:show()
    else
      self.includes_text:hide()
      self.excludes_text:hide()
    end
    self:update_replacement()
  end

  local function toggle_replace(enabled)
    if enabled then
      self.replace_text:show()
      self.replace_button:show()
    else
      self.replace_text:hide()
      self.replace_button:hide()
    end
    self:update_replacement()
  end

  local function update_replacement() self:update_replacement() end
  self.sensitive_toggle.on_change = update_replacement
  self.regex_toggle.on_change = update_replacement
  self.replace_text.on_change = update_replacement

  self.close_button.on_click = function()
    command.perform "project-search:find"
  end

  self.find_button.on_click = function()
    if self.find_button.label == "" then
      if not self.searching or self.replacing then
        self.replaced = true
        self.results_list:clear()
        self.total_files_processed = nil
        self.find_button:set_label("Find")
        self.find_button:set_icon()
        self.find_button:set_tooltip(nil, "project-search:refresh")
      else
        report_status(self.searching and "Search" or "Replace")
      end
    else
      self:refresh()
    end
    self:swap_active_child(self.find_text)
  end

  self.filters_toggle.on_change = function(_, enabled)
    toggle_filters(enabled)
  end

  self.replace_toggle.on_change = function(_, enabled)
    toggle_replace(enabled)
  end

  self.replace_button.on_click = function()
    if not self.replace_toggle:is_toggled() then return end
    if self.replaced or self.results_list.total_results == 0 then
      MessageBox.info(
        "No Valid Search",
        "Perform a search before trying a replace operation."
      )
      return
    end
    if not self.searching and not self.replacing then
      update_replacement()
      MessageBox.alert(
        "Confirm Replacement",
        "Do you want to perform the previewed replacement?",
        "?", style.text,
        function(_, button_id)
          if button_id == 1 then
            self:begin_replace()
          end
        end,
        MessageBox.BUTTONS_YES_NO
      )
    else
      report_status(self.searching and "Search" or "Replace")
    end
  end

  self.file_picker.on_change = function(_, value)
    self.path = value
  end

  toggle_filters(false)
  toggle_replace(type(replacement) == "string")

  if text and text ~= "" then
    self:begin_search(
      path, text, self.search_type, self.insensitive, self.whole_word
    )
  end
end


---Sets the replacement text depending on currently toggled options
function ResultsView:update_replacement()
  if not self.searching and not self.replacing then
    self.replaced = false
    local replace = self.replace_toggle:is_toggled()
    local regex = self.regex_toggle:is_toggled()
    self.replacement = replace
      and self.replace_text:get_text()
      or nil
    self.results_list.replacement = self.replacement
    -- we also check for #self.replacement > 0 because an empty string
    -- on a regex will replace by the same value of find text
    self.results_list:set_search_regex(
      (replace and regex and #self.replacement > 0)
        and self.find_text:get_text()
        or nil,
      self.sensitive_toggle:is_toggled()
    )
  end
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
  local includes = options.includes
  local excludes = options.excludes

  ---Check if the given file path matches against the given list of patterns.
  ---@param file_path string
  ---@param patterns? table<integer,string>
  ---@param info system.fileinfo
  ---@param negate? boolean
  ---@return boolean matches
  local function path_match(file_path, patterns, info, negate)
    if not patterns then return false end
    for _, pattern in ipairs(patterns) do
      if file_path:find(pattern, 1, false) then
        return true
      elseif info.type == "dir" then
        if pattern:find("^%.%*", 2, false) then
          return true
        elseif not negate then
          local paths = {}
          for p in file_path:gmatch("[^"..PATHSEP.."]+") do
            table.insert(paths, p)
          end
          for i, _ in ipairs(paths) do
            local pre_path = table.concat(paths, PATHSEP, 1, i)
            if
              pattern:find(
                "^"..pre_path..PATHSEP,
                2,
                false
              )
              or
              pattern:find(
                "^"..pre_path.."%$",
                2,
                false
              )
            then
              return true
            end
          end
        end
      end
    end
    return false
  end

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
            local success = pcall(function()
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
            end)
            -- skip lines where regex.cmatch failed
            if not success then positions = {} end
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
            ) and (
              not includes or path_match(directory..file, includes, info)
            ) and (
              not excludes or not path_match(directory..file, excludes, info, true)
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


---Convert a filter into a table of lua patterns.
---@param self plugins.projectsearch.resultsview
---@param filters string
---@return table? lua_patterns
local function parse_filters(self, filters)
  if not self.filters_toggle:is_toggled() then return nil end
  filters = filters:match("^%s*(.-)%s*$")
  if filters == "" then return nil end
  local list = {}
  for filter in filters:gmatch("[^,]+") do
    filter = filter:match("^%s*(.-)%s*$") -- trim
    filter = filter:gsub("[/\\]", PATHSEP) -- use proper path separator
    filter = filter:match("^["..PATHSEP.."]*(.-)["..PATHSEP.."]*$") -- trim path separator
      :gsub("%.", "%%.") -- escape dots
      :gsub("%?", ".") -- replace question marks to any char
    if filter ~= "" then
      filter = filter:gsub("%*", "[^"..PATHSEP.."]*") -- single glob
        :gsub("%[%^"..PATHSEP.."%]%*%[%^"..PATHSEP.."%]%*", ".*") -- double glob
        :gsub(PATHSEP.."%.%*", PATHSEP.."?.*")
        :gsub("%.%*"..PATHSEP, ".*"..PATHSEP.."?")
      -- treat non glob filter as a directory match pattern
      if filter:umatch("^[%w"..PATHSEP.."]+$") then
        filter = filter .. "/[^"..PATHSEP.."]+"
      end
      filter = "^" .. filter .. "$"
      if pcall(string.match, "a", filter) then
        table.insert(list, filter)
      end
    end
  end
  return list
end

---Start the search procedure and worker threads.
---@param path? string
---@param text string
---@param search_type "plain" | "regex"
---@param insensitive? boolean
---@param whole_word? boolean
function ResultsView:begin_search(path, text, search_type, insensitive, whole_word)
  if search_type == "regex" then
    local rerr
    local compiled = pcall(function()
      local r, rerr = regex.compile(text, insensitive and "i" or "")
    end)
    if not compiled then
      MessageBox.error(
        "Syntax error on regular expression",
        rerr
      )
      return
    end
  end
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
        file_size_limit = config.file_size_limit * 1e6,
        includes = parse_filters(self, self.includes_text:get_text()),
        excludes = parse_filters(self, self.excludes_text:get_text())
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
local function files_replace_thread(tid, id, replacement, search_regex, case_sensitive)
  local replace_channel = thread.get_channel("projectsearch_replace"..tid..id)
  local status_channel = thread.get_channel("projectsearch_replace_status"..tid..id)
  local replacement_len = #replacement

  if not replace_channel or not status_channel then
    error("could not retrieve channels for files replace thread")
    return
  end

  local regex_replace
  pcall(function()
    regex_replace = search_regex and regex.compile(
      search_regex, case_sensitive and "" or "i"
    )
  end)

  local replace_substring = function(str, s, e, rep)
    local head = s <= 1 and "" or string.sub(str, 1, s - 1)
    local tail = e >= #str and "" or string.sub(str, e + 1)
    if regex_replace then
      local target = string.sub(str, s, e)
      rep = regex_replace:gsub(target, replacement, 1)
      replacement_len = #rep
    end
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
        "psrpool"..tid..id, files_replace_thread,
        tid, id,
        self.replace_text:get_text(),
        self.regex_toggle:is_toggled() and self.find_text:get_text(),
        self.sensitive_toggle:is_toggled()
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
  local text = self.find_text:get_text()
  if #text > 0 and not self.replacing and not self.searching then
    self.replaced = false
    self.path = self.file_picker:get_path()
    self.query = self.find_text:get_text()
    self.search_type = self.regex_toggle:is_toggled() and "regex" or "plain"
    self.insensitive = not self.sensitive_toggle:is_toggled()
    self.whole_word = self.wholeword_toggle:is_toggled()
    self:update_replacement()
    self:begin_search(
      self.path, self.query, self.search_type, self.insensitive, self.whole_word
    )
  elseif self.searching or self.replacing then
    report_status(self.searching and "Search" or "Replace")
  end
end


---@type core.view?
local previous_view

---Opens a DocView of the user selected match.
function ResultsView:open_selected_result()
  local item = self.results_list:get_selected()
  if not item or not item.position then return end
  core.try(function()
    local dv = core.root_view:open_doc(core.open_doc(item.parent.file.path))
    previous_view = dv
    core.root_view.root_node:update_layout()
    local l, c1, c2 = item.line.line, item.position.col1, item.position.col2+1
    dv.doc:set_selection(l, c2, l, c1)
    dv:scroll_to_line(l, false, true)
    if self.is_global then core.set_active_view(self) end
  end)
  return true
end


function ResultsView:update()
  if not ResultsView.super.update(self) then return false end
  self:move_towards("brightness", 0, 0.1)

  local px = style.padding.x
  local py = style.padding.y

  if self.is_global then
    self.close_button:show()
    self.close_button:set_position(px, py)
  end

  self.replace_toggle:set_position(self.size.x - self.replace_toggle:get_width() - px, py)
  self.filters_toggle:set_position(self.replace_toggle:get_position().x - (px / 2) - self.filters_toggle:get_width(), py)
  self.regex_toggle:set_position(self.filters_toggle:get_position().x - (px / 2) - self.regex_toggle:get_width(), py)
  self.wholeword_toggle:set_position(self.regex_toggle:get_position().x - (px / 2) - self.wholeword_toggle:get_width(), py)
  self.sensitive_toggle:set_position(self.wholeword_toggle:get_position().x - (px / 2) - self.sensitive_toggle:get_width(), py)

  self.find_text:set_position(px, self.regex_toggle:get_bottom() + py)
  self.find_text:set_size(self:get_width() - self.find_button:get_size().x - px * 3)
  if
    (
      self.find_text:get_text() == self.query
      and
      self.results_list.total_results > 0
    )
    or
    (
      self.find_text:get_text() == ""
      and
      self.results_list.total_results > 0
    )
  then
    self.find_button:set_label("")
    self.find_button:set_icon("T")
    self.find_button:set_tooltip("Clear results")
  else
    self.find_button:set_label("Find")
    self.find_button:set_icon()
    self.find_button:set_tooltip(nil, "project-search:refresh")
  end
  self.find_button:set_position(self.find_text:get_size().x + px * 2, self.regex_toggle:get_bottom() + py)

  if self.replace_text:is_visible() then
    self.replace_text:set_position(px, self.find_text:get_bottom() + py)
    self.replace_text:set_size(self:get_width() - self.replace_button:get_size().x - px * 3)
    self.replace_button:set_position(self.replace_text:get_size().x + px * 2, self.find_button:get_bottom() + py)
  end

  self.file_picker:set_size(self:get_width() - px * 2)
  if self.filters_toggle:is_toggled() then
    if self.replace_text:is_visible() then
      self.includes_text:set_position(px, self.replace_text:get_bottom() + py)
    else
      self.includes_text:set_position(px, self.find_text:get_bottom() + py)
    end
    if (self.size.x) > (650 * SCALE) then
      self.includes_text:set_size((self:get_width() / 2) - (px * 2 / 1.5))
      self.excludes_text:set_position(
        self.includes_text:get_right() + px / 2, self.includes_text:get_position().y
      )
      self.excludes_text:set_size((self:get_width() / 2) - (px * 2 / 1.5))
      self.file_picker:set_position(px, self.excludes_text:get_bottom() + py)
    else
      self.includes_text:set_size(self:get_width() - px * 2)
      self.excludes_text:set_position(px, self.includes_text:get_bottom() + py)
      self.excludes_text:set_size(self:get_width() - px * 2)
      self.file_picker:set_position(px, self.excludes_text:get_bottom() + py)
    end
  elseif self.replace_text:is_visible() then
    self.file_picker:set_position(px, self.replace_text:get_bottom() + py)
  else
    self.file_picker:set_position(px, self.find_text:get_bottom() + py)
  end

  -- results
  if self.total_files_processed then
    self.results_list:show()
    local yoffset = self.file_picker:get_bottom()
      + style.font:get_height()
      + py * 3
    self.results_list:set_position(0, yoffset)
    self.results_list:set_size(self.size.x, self.size.y - yoffset)
  else
    self.results_list:hide()
  end
end


function ResultsView:draw()
  if not ResultsView.super.draw(self) then return false end
  if not self.total_files_processed then return true end

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
  renderer.draw_text(style.font, text, x, self.file_picker:get_bottom() + y, color)

  -- horizontal line
  local yoffset = self.file_picker:get_bottom() + style.font:get_height() + style.padding.y * 3
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
  core.add_thread(function() core.set_active_view(rv) end)
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

---@type plugins.projectsearch.resultsview?
local global_project_search

---@type boolean?
local previous_treeview_hidden

---@param path? string
---@param has_focus? boolean
function projectsearch.toggle(path, has_focus)
  local visible = true
  local toggle = true

  ---@type core.docview?
  local doc_view = (core.active_view and core.active_view:is(DocView))
    and core.active_view

  local selection = ""
  if doc_view then
    local doc = doc_view.doc
    selection = doc:get_text(
      table.unpack({ doc:get_selection() })
    )
  end

  if not has_focus and not previous_view then
    previous_view = core.active_view
  end

  if not global_project_search then
    global_project_search = ResultsView(path, "", "plain")
    global_project_search.is_global = true
    global_project_search:set_size(400 * SCALE)
    global_project_search:show()
    local node, split_direction = nil, "left"
    if treeview then
      -- when treeview enabled split to the right of it for consistent position
      node = core.root_view.root_node:get_node_for_view(treeview)
      if not node then node = core.root_view:get_primary_node() end
      split_direction = "right"
    else
      node = core.root_view:get_active_node()
    end
    global_project_search.node = node:split(
      split_direction, global_project_search, {x = true}, true
    )
  else
    local gvisible = global_project_search:is_visible()
    if path then global_project_search.file_picker:set_path(path) end
    if selection ~= "" then
      if not gvisible then
        global_project_search:toggle_visible(true, false, true)
      else
        toggle = false
      end
    elseif not has_focus and gvisible then
      toggle = false
    elseif not path or not gvisible then
      visible = not gvisible
      global_project_search:toggle_visible(true, false, true)
    else
      toggle = false
    end
  end

  if treeview and toggle then
    if type(previous_treeview_hidden) ~= "boolean" then
      previous_treeview_hidden = treeview.visible
    end

    if visible then
      previous_treeview_hidden = not treeview.visible
    else
      if previous_treeview_hidden then visible = true end
    end
    treeview.visible = not visible
  end

  core.add_thread(function()
    if visible then
      core.set_active_view(global_project_search)
      global_project_search:swap_active_child()
      global_project_search:swap_active_child(global_project_search.find_text)
      if selection ~= "" then
        global_project_search.find_text:set_text(selection)
        global_project_search.find_text.textview.doc:set_selection(
          1, 1, 1, #selection + 1
        )
      end
    elseif previous_view then
      core.set_active_view(previous_view)
      previous_view = nil
    end
  end)
end

---@return boolean is_project_search
---@return plugins.projectsearch.resultsview? view
local function active_view_is_project_search()
  local is_results_view = false
  local view
  if
    core.active_view
    and
    core.active_view:get_name() == "Project Search and Replace"
    and
    core.active_view.type_name ~= "widget.filepicker"
  then
    local element = core.active_view
    while element.parent do
      element = core.active_view.parent
    end
    if element:is_visible() then
      is_results_view = true
      view = element
    end
  end
  return is_results_view, view
end

command.add(nil, {
  ["project-search:find"] = function(path)
    local has_focus = active_view_is_project_search()
    projectsearch.toggle(path, has_focus)
  end,

  ["project-search:open-tab"] = function(path)
    local rv = ResultsView(path, "", "plain")
    rv:show()
    core.root_view:get_active_node_default():add_view(rv)
    core.add_thread(function()
      core.set_active_view(rv)
      rv:swap_active_child(rv.find_text)
    end)
  end,

  ["project-search:find-plain"] = function(path)
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

command.add(
  function()
    local is_project_search, view = active_view_is_project_search()
    if is_project_search and view.child_active and view.child_active.textview then
      return true, view
    end
    return false
  end,
  {
    ["project-search:refresh"] = function(view)
      view:refresh()
    end,
  }
)

---Focus the next or previous input text
---@param view plugins.projectsearch.resultsview
---@param reverse? boolean
local function cycle_input_text(view, reverse)
  if not view.child_active then
    view:swap_active_child(view.find_text)
  else
    local current_active = view.child_active
    local active_pos = nil
    local first_textbox = nil
    local start = reverse and 1 or #view.childs
    local ending = reverse and #view.childs or 1
    local increment = reverse and 1 or -1
    for i=start, ending, increment do
      local child = view.childs[i]
      if child == current_active then
        active_pos = i
      elseif child.type_name == "widget.textbox" and child:is_visible() then
        if not first_textbox then first_textbox = child end
        if
          (not reverse and active_pos and i < active_pos)
          or
          (reverse and active_pos and i > active_pos)
        then
          view:swap_active_child(child)
          core.last_active_view = view
          return
        end
      end
    end
    view:swap_active_child(first_textbox or current_active)
    core.last_active_view = view
  end
end

command.add(
  function()
    return active_view_is_project_search()
  end,
  {
    ["project-search:replace"] = function(view)
      view.replace_button:on_click()
    end,

    ["project-search:toggle-regex"] = function(view)
      view.regex_toggle:toggle()
    end,

    ["project-search:toggle-case-sensitive"] = function(view)
      view.sensitive_toggle:toggle()
    end,

    ["project-search:toggle-whole-words"] = function(view)
      view.wholeword_toggle:toggle()
    end,

    ["project-search:toggle-file-filters"] = function(view)
      view.filters_toggle:toggle()
    end,

    ["project-search:toggle-replace-mode"] = function(view)
      view.replace_toggle:toggle()
    end,

    ["project-search:focus-next-input"] = function(view)
      cycle_input_text(view)
    end,

    ["project-search:focus-previous-input"] = function(view)
      cycle_input_text(view, true)
    end,

    ["project-search:unfocus-input"] = function(view)
      view:swap_active_child()
    end
  }
)

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
  ["ctrl+shift+f"]       = "project-search:find",
  ["ctrl+shift+alt+f"]   = "project-search:open-tab",
  ["return"]             = "project-search:refresh",
  ["f5"]                 = "project-search:refresh",
  ["ctrl+return"]        = "project-search:replace",
  ["tab"]                = "project-search:focus-next-input",
  ["shift+tab"]          = "project-search:focus-previous-input",
  ["escape"]             = "project-search:unfocus-input",
  ["alt+r"]              = "project-search:toggle-regex",
  ["alt+c"]              = "project-search:toggle-case-sensitive",
  ["alt+w"]              = "project-search:toggle-whole-words",
  ["alt+f"]              = "project-search:toggle-file-filters",
  ["ctrl+r"]             = "project-search:toggle-replace-mode",
  ["up"]                 = "project-search:select-previous",
  ["down"]               = "project-search:select-next",
  ["left"]               = "project-search:toggle-expand",
  ["right"]              = "project-search:toggle-expand",
  ["space"]              = "project-search:toggle-checkbox",
  ["pageup"]             = "project-search:move-to-previous-page",
  ["pagedown"]           = "project-search:move-to-next-page",
  ["ctrl+home"]          = "project-search:move-to-start-of-doc",
  ["ctrl+end"]           = "project-search:move-to-end-of-doc",
  ["home"]               = "project-search:move-to-start-of-doc",
  ["end"]                = "project-search:move-to-end-of-doc"
}

keymap.add {
  ["return"]             = "project-search:open-selected"
}

return projectsearch
