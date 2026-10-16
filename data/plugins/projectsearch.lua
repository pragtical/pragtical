-- mod-version:3
local core = require "core"
local common = require "core.common"
local keymap = require "core.keymap"
local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local ContextMenu = require "core.contextmenu"
local DocView = require "core.docview"
local Node = require "core.node"
local Widget = require "widget"
local Button = require "widget.button"
local FilePicker = require "widget.filepicker"
local MessageBox = require "widget.messagebox"
local SearchReplaceList = require "widget.searchreplacelist"
local TextBox = require "widget.textbox"
local ToggleButton = require "widget.togglebutton"

---@class plugins.projectsearch
local projectsearch = {}

local treeview
core.add_thread(function()
  if config.plugins.treeview ~= false then
    treeview = require "plugins.treeview"
  end
end)

---@class config.plugins.projectsearch
---@field position "left"|"right"|"center" Placement of the reusable global search view
config.plugins.projectsearch = common.merge({
  threading = {
    workers = math.ceil(thread.get_cpu_count() / 2) + 1
  },
  live_search = false,
  syntax_highlighting = true,
  split_direction = "right",
  position = "left",
  -- The config specification used by gui generators
  config_spec = {
    name = "Project Search",
    {
      label = "Position",
      description = "Dock global project search on either side or show it as a centered popup.",
      path = "position",
      type = "selection",
      default = "left",
      values = {
        { "Left", "left" },
        { "Right", "right" },
        { "Center", "center" }
      },
      set_value = function(value)
        projectsearch.set_position(value)
        return value
      end
    },
    {
      label = "Workers",
      description = "The maximum amount of threads to create per search.",
      path = "threading.workers",
      type = "number",
      default = math.ceil(thread.get_cpu_count() / 2) + 1,
      min = 1
    },
    {
      label = "Live Search",
      description = "Keep making new searches while typing (experimental).",
      path = "live_search",
      type = "toggle",
      default = false
    },
    {
      label = "Syntax Highlighting",
      description = "Enable highlighting for search results (coloring may not be accurate on partial code).",
      path = "syntax_highlighting",
      type = "toggle",
      default = true
    },
    {
      label = "Split Direction",
      description = "Where to open project search results when control-clicked.",
      path = "split_direction",
      type = "selection",
      default = "right",
      values = {
        { "Right", "right" },
        { "Left", "left" },
        { "Up", "up" },
        { "Down", "down" }
      }
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
---@field context_menu core.contextmenu
---@field source_view core.view?
---@field result_split_node core.node?
---@field result_split_views core.docview[]?
---@field is_global boolean Whether this is the reusable global search panel
---@field display_position? "left"|"right"|"center" Applied global placement
---@field sidebar_width number Remembered docked width in scale-independent units
---@field node? core.node Docked placement, absent in centered mode
---@field focus_generation integer Invalidates queued focus when hiding or reopening
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
  self.stop = false
  self.is_global = false
  self.sidebar_width = 400
  self.focus_generation = 0
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
  self.context_menu = ContextMenu()
  self.context_menu:register(function()
    local item = self.results_list:get_selected()
    return self:owns_view(core.active_view) and item and item.position
  end, {
    { text = "Open", command = "project-search:open-selected" },
    { text = "Open in Split", command = "project-search:open-selected-split" }
  })

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

  self.find_text.on_text_change = function()
    if config.plugins.projectsearch.live_search then
      self:queue_refresh()
    end
  end

  self.close_button.on_click = function()
    command.perform "project-search:find"
  end

  self.find_button.on_click = function()
    if self.find_button.label == "" then
      if self.searching then
        self:stop_search()
      elseif self.find_button.icon.code == "T" and not self.replacing then
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


---@class plugins.projectsearch.resultsview.options
---@field text? string
---@field path? string
---@field has_focus? boolean
---@field insensitive? boolean
---@field whole_word? boolean
---@field replacement? string
---@field search_type? "plain"|"regex"
---@field filters? { includes: string?, excludes: string? }
---@field run? boolean

---@param options plugins.projectsearch.resultsview.options
---@param enable_run? boolean
function ResultsView:apply_options(options, enable_run)
  if type(options.path) == "string" then
    self.file_picker:set_path(options.path)
  end
  if type(options.text) == "string" then
    self.find_text:set_text(options.text)
  end

  if options.search_type ~= nil then
    self.regex_toggle:set_toggle(options.search_type == "regex")
  end

  if type(options.insensitive) == "boolean" then
    self.sensitive_toggle:set_toggle(not options.insensitive)
  end
  if type(options.whole_word) == "boolean" then
    self.wholeword_toggle:set_toggle(options.whole_word)
  end
  if type(options.replacement) == "string" then
    self.replace_text:set_text(options.replacement)
    self.replace_toggle:set_toggle(true)
  end
  if type(options.filters) == "table" then
    self.includes_text:set_text(options.filters.includes or "")
    self.excludes_text:set_text(options.filters.excludes or "")
    self.filters_toggle:set_toggle(
      type(options.filters.includes) == "string"
      or type(options.filters.excludes) == "string"
    )
  end

  self:update_replacement()
  if enable_run and options.run == true and #self.find_text:get_text() > 0 then
    self:refresh()
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
  local roots = options.roots or {
    {
      path = options.path,
      name = commons.basename(options.path or "")
    }
  }

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
    local results_channel = thread.get_channel("projectsearch_results"..tid..":"..id)
    local filename_channel = thread.get_channel("projectsearch_fname"..tid..":"..id)
    local stop_channel = thread.get_channel("projectsearch_stop"..tid..":"..id)

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

    local stop = false
    local file_entry = filename_channel:wait()
    while file_entry ~= "{{stop}}" do
      stop = stop_channel:first() == "stop"
      if stop then break end
      local filename = type(file_entry) == "table" and file_entry.path or file_entry
      local display_path = type(file_entry) == "table" and file_entry.display_path or nil
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
          lines,
          display_path
        })
      end
      stop = stop_channel:first() == "stop"
      if stop then break end
      if found then
        results_channel:push(results)
      else
        results_channel:push(true)
      end
      filename_channel:pop()
      file_entry = filename_channel:wait()
    end
    if stop then
      results_channel:clear()
      filename_channel:clear()
      stop_channel:clear()
    end
    return 0
  end

  ---Wait for a list of workers to finish
  ---@param list thread.Thread[]
  local function workers_wait(list)
    for _, worker in ipairs(list) do worker:wait() end
  end

  -- channel used to inform the status of searching to coroutine
  -- the current dir/file index been searched is sent or "finished" on end
  local channel_status = thread.get_channel("projectsearch_status"..tid)

  -- channel to monitor if the finding of should should be stopped.
  local channel_stop = thread.get_channel("projectsearch_stop"..tid)

  local count = 0
  ---@type thread.Thread[]
  local workers_list = {}
  ---@type thread.Channel[]
  local result_channels = {}
  ---@type thread.Channel[]
  local filename_channels = {}
  local stop_channels = {}

  local function finish_workers(cancelled)
    for id = 1, #workers_list do
      if cancelled then stop_channels[id]:push("stop") end
      filename_channels[id]:push("{{stop}}")
    end
    workers_wait(workers_list)
  end

  workers = workers or math.ceil(thread.get_cpu_count() / 2) + 1
  for id=1, workers, 1 do
    table.insert(
      filename_channels,
      thread.get_channel("projectsearch_fname"..tid..":"..id)
    )
    table.insert(
      result_channels,
      thread.get_channel("projectsearch_results"..tid..":"..id)
    )
    stop_channels[id] = thread.get_channel("projectsearch_stop"..tid..":"..id)
    local worker, err = thread.create(
      "pswrk"..tid..id, -- projectsearch worker
      worker_find_in_file,
      tid,
      id,
      text,
      search_type,
      insensitive,
      whole
    )
    if not worker then
      finish_workers(true)
      channel_status:clear()
      channel_status:push({ error = err or "could not create search worker" })
      return 1
    end
    workers_list[id] = worker
  end

  local stop = false
  local current_worker = 1
  for _, root_data in ipairs(roots) do
    local root = root_data.path
    local directories = {""}
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
                local file_path = dir_path .. pathsep .. file
                local display_path
                if root_data.display_prefix then
                  display_path = root_data.display_prefix
                    .. pathsep
                    .. commons.relative_path(root, file_path)
                end
                filename_channels[current_worker]:push({
                  path = file_path,
                  display_path = display_path
                })
                current_worker = current_worker + 1
                if current_worker > workers then current_worker = 1 end
              end
            end
          end
        end
        table.remove(directories, didx)
        break
      end

      stop = channel_stop:first() == "stop"
      if not stop then
        channel_status:clear()
        channel_status:push(count)
      else
        break
      end
    end
    if stop then break end
  end

  finish_workers(stop)
  channel_status:clear()
  channel_status:push(stop and "cancelled" or "finished")

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
          self.results_list:add_file(result[1], lines, nil, result[3])
        end
      end
      found = true
    end
  end
  return found
end


---Send stop signal to find files thread and find in file workers.
---@param files_stop_channel thread.Channel
---@param workers_stop_channel thread.Channel[]
---@param filename_channels thread.Channel[]
local function worker_threads_stop(files_stop_channel, workers_stop_channel, filename_channels)
  files_stop_channel:push("stop")
  for id, channel_stop in ipairs(workers_stop_channel) do
    channel_stop:push("stop")
    filename_channels[id]:push("{{stop}}")
  end
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

---@param path? string
---@return table[] roots
---@return boolean multiple_projects
---@return string? base_dir
local function get_search_roots(path)
  if path then
    return {{ path = path, name = common.basename(path) }}, false, path
  end

  local roots = {}
  for _, project in ipairs(core.projects) do
    table.insert(roots, {
      path = project.path,
      name = project.name or common.basename(project.path)
    })
  end

  local multiple_projects = #roots > 1
  if multiple_projects then
    for _, root in ipairs(roots) do
      root.display_prefix = root.name
    end
  end

  return roots, multiple_projects, roots[1] and roots[1].path or nil
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
  local roots, multiple_projects, base_dir = get_search_roots(path)
  if #roots == 0 then return end

  self.path = path
  self.stop = false
  self.results_list:clear()
  self.total_files_processed = 0
  self.searching = true
  self.total_files = 0
  self.start_time = system.get_time()
  self.end_time = self.start_time
  self.results_list.base_dir = multiple_projects and "" or base_dir

  threaded_search_id = threaded_search_id + 1
  local tid = threaded_search_id
  core.add_thread(function()
    local workers = config.plugins.projectsearch.threading.workers
    local result_channels, stop_channels, filename_channels = {}, {}, {}
    for id = 1, workers do
      result_channels[id] = thread.get_channel("projectsearch_results"..tid..":"..id)
      stop_channels[id] = thread.get_channel("projectsearch_stop"..tid..":"..id)
      filename_channels[id] = thread.get_channel("projectsearch_fname"..tid..":"..id)
    end
    local channel_status = thread.get_channel("projectsearch_status"..tid)
    local channel_stop = thread.get_channel("projectsearch_stop"..tid)
    local search_thread, err = thread.create(
      "pspool"..tid,
      files_search_thread,
      tid,
      {
        text = text,
        search_type = search_type,
        insensitive = insensitive,
        whole_word = whole_word,
        path = base_dir,
        roots = roots,
        pathsep = PATHSEP,
        ignore_files = core.get_ignore_file_rules(),
        workers = workers,
        file_size_limit = config.file_size_limit * 1e6,
        includes = parse_filters(self, self.includes_text:get_text()),
        excludes = parse_filters(self, self.excludes_text:get_text())
      }
    )
    if not search_thread then
      self.searching = false
      self.end_time = system.get_time()
      core.error("Could not start project search: %s", err)
      return
    end
    local status = channel_status:first()
    local stopping = false
    while type(status) ~= "string" and type(status) ~= "table" do
      if type(status) == "number" then
        self.total_files = status
      end
      -- add some of the results found
      if not self.stop then worker_threads_add_results(self, result_channels) end
      coroutine.yield()
      core.redraw = true
      if not self.stop and not self.is_global then
        local node = core.root_view:get_active_node_default()
        local found = false
        for _, view in ipairs(node.views) do
          if view == self then
            found = true
            break
          end
        end
        if not found then self.stop = true end
      end
      if self.stop and not stopping then
        worker_threads_stop(channel_stop, stop_channels, filename_channels)
        stopping = true
      end
      status = channel_status:first()
    end
    channel_status:clear()
    if type(status) == "table" then
      core.error("Project search failed: %s", status.error)
    elseif not self.stop then
      -- add any remaining results
      while worker_threads_add_results(self, result_channels) do end
    end
    -- The coordinator reports completion only after joining its workers.
    search_thread:wait()
    -- the search was completed
    self.searching = false
    if not self.queue_search then
      self.brightness = 100
      core.redraw = true
    end
    self.end_time = system.get_time()
    self.stop = false
  end, self.results_list.items)

  self.scroll.to.y = 0
end

---Flag that the search threads should be stopped.
function ResultsView:stop_search()
  self.stop = true
end

---File text replacing thread function that uses worker threads to perform
---multi-file replacing.
---@param tid integer
---@param id integer
---@param replacement string
local function files_replace_thread(tid, id, replacement, search_regex, case_sensitive)
  local replace_channel = thread.get_channel("projectsearch_replace"..tid..":"..id)
  local status_channel = thread.get_channel("projectsearch_replace_status"..tid..":"..id)
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
    ---@type thread.Thread[]
    local replace_workers = {}

    -- create all threads and channels
    for id=1, workers, 1 do
      table.insert(
        replace_channels,
        thread.get_channel("projectsearch_replace"..tid..":"..id)
      )
      table.insert(
        status_channels,
        thread.get_channel("projectsearch_replace_status"..tid..":"..id)
      )
      table.insert(replace_workers, thread.create(
        "psrpool"..tid..id, files_replace_thread,
        tid, id,
        self.replace_text:get_text(),
        self.regex_toggle:is_toggled() and self.find_text:get_text(),
        self.sensitive_toggle:is_toggled()
      ))
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

    for _, worker in ipairs(replace_workers) do
      worker:wait()
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
  if #text > 0 and not self.replacing and not self.searching and not self.queue_search then
    self.replaced = false
    self.path = self.file_picker:get_path()
    self.query = text
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


function ResultsView:queue_refresh()
  if self.searching then self:stop_search() end
  if
    not self.replacing
    and #self.find_text:get_text() > 2
    and not self.queue_search
    and self.query ~= self.find_text:get_text()
  then
    core.add_thread(function()
      while true do
        local text = self.find_text:get_text()
        if not self.searching and not self.replacing and #text > 2 then
          self.replaced = false
          self.path = self.file_picker:get_path()
          self.query = text
          self.search_type = self.regex_toggle:is_toggled() and "regex" or "plain"
          self.insensitive = not self.sensitive_toggle:is_toggled()
          self.whole_word = self.wholeword_toggle:is_toggled()
          self:update_replacement()
          self:begin_search(
            self.path, self.query, self.search_type, self.insensitive, self.whole_word
          )
          break
        elseif #text == 0 then
          break
        end
        coroutine.yield()
      end
      self.queue_search = false
    end)
    self.queue_search = true
  elseif self.replacing then
    report_status("Replace")
  elseif #self.find_text:get_text() == 0 then
    self.results_list:clear()
    self.total_files_processed = nil
    self.find_button:set_label("Find")
    self.find_button:set_icon()
    self.find_button:set_tooltip(nil, "project-search:refresh")
  end
end

---@type core.view?
local previous_view

local split_directions = {
  left = true,
  right = true,
  up = true,
  down = true
}
local split_click_modifier = PLATFORM == "Mac OS X" and "cmd" or "ctrl"

local function get_split_direction()
  local direction = config.plugins.projectsearch.split_direction
  return split_directions[direction] and direction or "right"
end

local function node_is_in_tree(root, target)
  if root == target then return true end
  if root.type ~= "leaf" then
    return node_is_in_tree(root.a, target)
      or node_is_in_tree(root.b, target)
  end
  return false
end

local function get_result_split_node(self)
  local root = core.root_view.root_node
  local node = self.result_split_node
  if
    node and node.type == "leaf" and not node.locked
    and node_is_in_tree(root, node)
  then
    return node
  end

  -- A collapsed split can preserve these views in the main pane. Do not
  -- follow them there, since that pane is no longer the result split.
  self.result_split_node = nil
  self.result_split_views = {}
end

local function get_result_split_source_node(self)
  local root = core.root_view.root_node
  local node = self.source_view and root:get_node_for_view(self.source_view)
  if not node then
    node = root:get_node_for_view(self)
  end
  if not node or node.type ~= "leaf" or node.locked then
    node = core.root_view:get_primary_node()
  end
  return node
end

local function remember_result_split_view(self, node, view)
  self.result_split_node = node
  self.result_split_views = self.result_split_views or {}
  for i = #self.result_split_views, 1, -1 do
    if self.result_split_views[i] == view then
      table.remove(self.result_split_views, i)
    end
  end
  table.insert(self.result_split_views, view)
end

local function open_doc_in_result_split(self, doc)
  local node = get_result_split_node(self)
  local view
  if node then
    for _, candidate in ipairs(node.views) do
      if candidate:extends(DocView) and candidate.doc == doc then
        view = candidate
        node:set_active_view(view)
        break
      end
    end
    if not view then
      view = DocView(doc)
      node:add_view(view)
    end
  else
    view = DocView(doc)
    node = get_result_split_source_node(self):split(
      get_split_direction(), view
    )
  end
  remember_result_split_view(self, node, view)
  return view
end

---Opens a DocView of the user selected match.
---@param open_in_split? boolean
function ResultsView:open_selected_result(open_in_split)
  local item = self.results_list:get_selected()
  if not item or not item.position then return end
  core.try(function()
    local doc = core.open_doc(item.parent.file.path)
    local dv = open_in_split
      and open_doc_in_result_split(self, doc)
      or core.root_view:open_doc(doc)
    previous_view = dv
    core.root_view.root_node:update_layout()
    local l, c1, c2 = item.line.line, item.position.col1, item.position.col2+1
    dv:ensure_line_visible(l)
    dv.doc:set_selection(l, c2, l, c1)
    dv.doc:add_search_selection(l, c2, l, c1)
    dv:scroll_to_make_visible(l, c1, true)
    if self.is_global then
      if self.display_position == "center" then
        projectsearch.hide()
      else
        core.set_active_view(self)
      end
    end
  end)
  return true
end

function ResultsView:on_mouse_pressed(button, x, y, clicks)
  local menu = self.context_menu
  if menu.show_context_menu then
    return menu:on_mouse_pressed(button, x, y, clicks)
  end

  local list = self.results_list
  if
    button == "right" and list:mouse_on_top(x, y)
    and not list:scrollbar_overlaps_point(x, y)
  then
    local item = list.items[list.hovered]
    if item and item.position and not list.hovered_checkbox then
      list.selected = list.hovered
      return menu:on_mouse_pressed(button, x, y, clicks)
    end
  end

  if
    button == "left" and keymap.modkeys[split_click_modifier]
    and list:mouse_on_top(x, y)
    and not list:scrollbar_overlaps_point(x, y)
  then
    local item = list.items[list.hovered]
    if item and item.position and not list.hovered_checkbox then
      list.selected = list.hovered
      return false
    end
  end
  return ResultsView.super.on_mouse_pressed(self, button, x, y, clicks)
end

---Scale docked width while centered placement follows the available viewport.
---@param new_scale number Updated interface scale
---@param prev_scale number Previous interface scale
function ResultsView:on_scale_change(new_scale, prev_scale)
  ResultsView.super.on_scale_change(self, new_scale, prev_scale)
  if self.is_global and self.display_position ~= "center" then
    local width = self:get_width() / prev_scale * new_scale
    self:set_size(width)
    self.sidebar_width = width / new_scale
  end
end

---Fit centered global search inside the viewport on scale or window-size changes.
---RootView calls this before updating and drawing a shown floating view.
function ResultsView:update_floating()
  if self.is_global and self.display_position == "center" then
    local root = core.root_view
    local width = math.max(1, math.min(900 * SCALE, root.size.x - style.padding.x * 4))
    local height = math.max(1, math.min(650 * SCALE, root.size.y - style.padding.y * 4))
    local x = root.position.x + (root.size.x - width) / 2
    local y = root.position.y + (root.size.y - height) / 2
    if self.floating_transition then
      self.floating_destination.x, self.floating_destination.y = x, y
      x, y = self:get_floating_bounds()
    end
    self:set_floating_bounds(x, y, width, height)
  end
  ResultsView.super.update_floating(self)
end

---Slide centered global search down from the top using the core floating transition.
---@param options? core.view.floating_transition Explicit transition overriding the default slide
---@return plugins.projectsearch.resultsview view This view
function ResultsView:show_floating(options)
  if not options and self.is_global and self.display_position == "center" then
    options = { from = "top" }
  end
  return ResultsView.super.show_floating(self, options)
end


---Focus the result list and reveal its selection without focusing any text input.
---Choose the first match if no result has been selected yet.
function ResultsView:focus_results()
  self:swap_active_child()
  core.set_active_view(self)
  self:swap_active_child(self.results_list)
  local list = self.results_list
  if not list:get_selected() then
    list.selected = #list.items > 0 and 1 or 0
    for i, item in ipairs(list.items) do
      if item.position then list.selected = i; break end
    end
  end
  list:scroll_to_selected()
end


---Close centered search on Escape only while it owns keyboard focus.
---@param stroke string Normalized key binding
---@return boolean consumed Whether the search popup handled Escape
function ResultsView:on_key_pressed(stroke)
  if self.is_global and self.display_position == "center"
    and stroke == "escape" and self:owns_view(core.active_view) then
    projectsearch.hide()
    return true
  end
  return false
end


---Dismiss centered global search through its normal visibility and focus lifecycle.
---@param reason "escape"|"outside"|"focuslost" Cause supplied by RootView
function ResultsView:on_floating_dismiss(reason)
  if self.is_global then projectsearch.hide() else self:hide() end
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

  self.results_list.syntax_highlighting = config.plugins.projectsearch.syntax_highlighting

  self.replace_toggle:set_position(self.size.x - self.replace_toggle:get_width() - px, py)
  self.filters_toggle:set_position(self.replace_toggle:get_position().x - (px / 2) - self.filters_toggle:get_width(), py)
  self.regex_toggle:set_position(self.filters_toggle:get_position().x - (px / 2) - self.regex_toggle:get_width(), py)
  self.wholeword_toggle:set_position(self.regex_toggle:get_position().x - (px / 2) - self.wholeword_toggle:get_width(), py)
  self.sensitive_toggle:set_position(self.wholeword_toggle:get_position().x - (px / 2) - self.sensitive_toggle:get_width(), py)

  self.find_text:set_position(px, self.regex_toggle:get_bottom() + py)
  if self.searching then
    self.find_button:set_label("")
    self.find_button:set_icon("C")
    self.find_button:set_tooltip("Stop Search")
  elseif
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
  elseif not self.queue_search then
    self.find_button:set_label("Find")
    self.find_button:set_icon()
    self.find_button:set_tooltip(nil, "project-search:refresh")
  end
  self.find_text:set_size(self:get_width() - self.find_button:get_size().x - px * 3)
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
  local per = common.clamp(self.total_files_processed / math.max(self.total_files, 1), 0, 1)
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
  local node = core.root_view:get_active_node_default()
  local rv = ResultsView(
    path, text, search_type, insensitive, whole_word, replacement
  )
  rv.source_view = node.active_view
  rv:show()
  node:add_view(rv)
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

---@type plugins.projectsearch.resultsview
projectsearch.ResultsView = ResultsView

projectsearch._test = {
  files_search_thread = files_search_thread,
  get_search_roots = get_search_roots
}

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

projectsearch._test.get_global_project_search = function()
  return global_project_search
end

---Hide TreeView only while the left search panel occupies its sidebar space.
---Restore the original visibility when hiding or moving to another position.
---@param visible boolean Whether global project search is shown
local function sync_treeview_visibility(visible)
  if not treeview then return end
  local hide = visible and global_project_search.display_position == "left"
  if hide and previous_treeview_hidden == nil then
    previous_treeview_hidden = not treeview.visible
    treeview.visible = false
  elseif not hide and previous_treeview_hidden ~= nil then
    treeview.visible = not previous_treeview_hidden
    previous_treeview_hidden = nil
  end
end

---Replace a layout branch without consuming nodes referenced by other panels.
---@param root core.rootview Layout owner
---@param node core.node Branch to replace
---@param replacement core.node Surviving or newly constructed branch
local function replace_layout_node(root, node, replacement)
  local parent = node:get_parent_node(root.root_node)
  if parent then
    parent[parent.a == node and "a" or "b"] = replacement
  else
    root.root_node = replacement
  end
end

---Check whether a branch contains an ordinary editor pane.
---@param node core.node Branch to inspect
---@return boolean unlocked Whether any leaf is unlocked
local function has_editor_node(node)
  if node.type == "leaf" then return not node.locked end
  return has_editor_node(node.a) or has_editor_node(node.b)
end

---Find the document area while keeping application bars and toolbars at the edges.
---@param root core.rootview Layout owner
---@return core.node target Branch beside which to dock search
---@return table? docking TreeView toolbar layout whose documents branch must be updated
local function get_dock_target(root)
  local docking = treeview and treeview.toolbar_layout
  if docking and node_is_in_tree(root.root_node, docking.documents) then
    return docking.documents, docking
  end
  local target = root:get_primary_node()
  local parent = target:get_parent_node(root.root_node)
  while parent and has_editor_node(parent.a) and has_editor_node(parent.b) do
    target = parent
    parent = target:get_parent_node(root.root_node)
  end
  return target
end

---Move the global view without recreating its inputs, results or document panes.
---@param position "left"|"right"|"center" Requested placement
function ResultsView:apply_position(position)
  assert(position == "left" or position == "right" or position == "center",
    "Invalid projectsearch position")
  if self.display_position == position then return end
  local root = core.root_view
  local visible, active = self:is_visible(), core.active_view
  if self.display_position and self.display_position ~= "center" then
    self.sidebar_width = self:get_width() / SCALE
  end
  self.context_menu:hide()
  root:cancel_floating_input(self)
  self:hide()
  self:set_floating(false)
  local node = root.root_node:get_node_for_view(self)
  if node then
    local parent = node:get_parent_node(root.root_node)
    local sibling = parent.a == node and parent.b or parent.a
    local docking = treeview and treeview.toolbar_layout
    if docking and docking.documents == parent then docking.documents = sibling end
    replace_layout_node(root, parent, sibling)
  end
  self.node = nil
  self.display_position = position
  self.defer_draw = position == "center"
  if self.defer_draw then
    self:set_floating(true, {
      focus = "click",
      dismiss_on_escape = false,
      dismiss_on_outside_click = true,
      consume_outside_click = false
    })
    self:update_floating()
  else
    self:set_size(self.sidebar_width * SCALE)
    local target, docking = get_dock_target(root)
    local panel = Node()
    panel:add_view(self)
    panel.locked, panel.resizable = { x = true }, true
    local split = Node("hsplit")
    replace_layout_node(root, target, split)
    if position == "left" then
      split.a, split.b = panel, target
    else
      split.a, split.b = target, panel
    end
    if docking then docking.documents = split end
    self.node = panel
  end
  if visible then
    self:show()
    if position ~= "center" then self:set_size(self.sidebar_width * SCALE) end
  else
    self:hide()
  end
  root.root_node:update_layout()
  if active then core.set_active_view(active) end
  core.redraw = true
end

---Configure global search placement, moving an existing view immediately.
---The preference is saved by Settings when its position selector is used.
---@param position "left"|"right"|"center" Docking edge or floating popup
function projectsearch.set_position(position)
  assert(position == "left" or position == "right" or position == "center",
    "Invalid projectsearch position")
  config.plugins.projectsearch.position = position
  if global_project_search then
    global_project_search:apply_position(position)
    sync_treeview_visibility(global_project_search:is_visible())
  end
end

---Find the ResultsView containing keyboard focus, including nested widget inputs.
---@return boolean is_project_search Whether the containing view is visible
---@return plugins.projectsearch.resultsview? view Containing search view
local function active_view_is_project_search()
  local view = core.active_view
  while view and not view:extends(ResultsView) do view = view.parent end
  return view ~= nil and view:is_visible(), view
end

---Create the reusable global view and apply its configured placement.
---@param path? string Initial search directory
---@return plugins.projectsearch.resultsview view Reused global search
local function ensure_global_project_search(path)
  if not global_project_search then
    global_project_search = ResultsView(path, "", "plain")
    global_project_search.is_global = true
  elseif path then
    global_project_search.file_picker:set_path(path)
  end
  global_project_search:apply_position(config.plugins.projectsearch.position)
  return global_project_search
end

---Recognize the document selection made by opening the currently selected result.
---That selection resumes result navigation rather than replacing a regex query.
---@param view plugins.projectsearch.resultsview Search containing the result
---@param doc core.doc Document whose current selection may be that result
---@return boolean matches Whether the source selection is the selected search match
local function selection_matches_result(view, doc)
  local item = view.results_list:get_selected()
  if not item or not item.position
    or common.normalize_path(doc.abs_filename) ~= common.normalize_path(item.parent.file.path)
  then
    return false
  end
  local l1, c1, l2, c2 = doc:get_selection(true)
  return l1 == item.line.line and l2 == l1
    and c1 == item.position.col1 and c2 == item.position.col2 + 1
end

---Show global search and queue focus after its controls have been laid out.
---Existing centered results receive navigation focus unless a new query was supplied.
---@param options plugins.projectsearch.resultsview.options Search options
---@return plugins.projectsearch.resultsview view Shown global search
local function show_global_project_search(options)
  local is_search = active_view_is_project_search()
  local selection = ""
  local source_doc
  if not is_search then
    previous_view = core.active_view
    if core.active_view and core.active_view:is(DocView) then
      source_doc = core.active_view.doc
      selection = source_doc:get_text(source_doc:get_selection())
    end
  end
  local view = ensure_global_project_search(options.path)
  if selection == view.find_text:get_text()
    or source_doc and selection_matches_result(view, source_doc)
  then
    selection = ""
  end
  if previous_view then view.source_view = previous_view end
  if view.display_position ~= "center" and not view:is_visible()
    and config.transitions and config.fps >= 30
  then
    view:show_animated(false, true)
  else
    view:show()
  end
  if options.text == nil and selection ~= "" then view.find_text:set_text(selection) end
  view:apply_options(options, true)
  sync_treeview_visibility(true)
  view.focus_generation = view.focus_generation + 1
  local generation = view.focus_generation
  local focus_results = view.display_position == "center"
    and view.results_list.total_results > 0 and selection == ""
    and options.text == nil and options.path == nil and not options.run
  core.add_thread(function()
    if not view:is_visible() or view.focus_generation ~= generation then return end
    if focus_results then
      view:focus_results()
    else
      view:swap_active_child()
      core.set_active_view(view)
      view:swap_active_child(view.find_text)
      if selection ~= "" and options.text == nil then
        view.find_text.textview.doc:set_selection(1, 1, 1, #selection + 1)
      end
    end
  end)
  return view
end

---Toggle the global project search view, or focus it when invoked from the editor.
---@param options? plugins.projectsearch.resultsview.options
---@return plugins.projectsearch.resultsview view Reusable global search
function projectsearch.toggle(options)
  options = options or {}
  local is_search, active = active_view_is_project_search()
  local view = global_project_search
  local has_focus = options.has_focus
  if has_focus == nil then has_focus = is_search and active == view end
  if view and view:is_visible() and has_focus and not options.path then
    return projectsearch.hide(options)
  end
  return show_global_project_search(options)
end

---Show or focus global search, preserving its query and result state.
---@param options? plugins.projectsearch.resultsview.options
---@return plugins.projectsearch.resultsview view Reusable global search
function projectsearch.show(options)
  return show_global_project_search(options or {})
end

---Hide global search and restore focus synchronously before outside clicks continue.
---A queued show must not later focus an input that has already been hidden.
---@param options? plugins.projectsearch.resultsview.options
---@return plugins.projectsearch.resultsview? view Reusable global search, if created
function projectsearch.hide(options)
  local view = global_project_search
  if not view then return end
  view:apply_options(options or {}, false)
  view.focus_generation = view.focus_generation + 1
  local focused = view:owns_view(core.active_view)
  if focused then view:swap_active_child() end
  view.context_menu:hide()
  if view.display_position == "center" then
    view:hide_floating({ to = "top" })
  elseif view:is_visible() and config.transitions and config.fps >= 30 then
    view:hide_animated(false, true)
  else
    view:hide()
  end
  sync_treeview_visibility(false)
  if focused and previous_view then
    local target = previous_view
    while target and not target.floating_visible
      and not core.root_view.root_node:get_node_for_view(target)
    do
      target = target.parent
    end
    if target then core.set_active_view(previous_view) end
  end
  previous_view = nil
  return view
end

local prompt_states = {}

---Open a resumable search prompt, scoped to its mode, project set and search path.
---@param mode "plain"|"regex" Search syntax
---@param path? string Directory to search instead of all project roots
local function enter_search_prompt(mode, path)
  if core.command_view:is_open() then return end
  local roots = {}
  for i, project in ipairs(core.projects) do roots[i] = project.path end
  local context = table.concat(roots, "\0") .. "\0"
    .. (path and core.root_project():absolute_path(path) or "")
  local saved = prompt_states[mode]
  if saved and saved.context ~= context then
    prompt_states[mode], saved = nil, nil
  end
  local text = get_selected_text() or ""
  core.command_view:enter("Find " .. (mode == "plain" and "Text" or "Regex") .. " In " .. (path or "Project"), {
    text = text,
    select_text = true,
    restore_state = text == "" and saved and saved.snapshot or nil,
    on_save_state = function(snapshot, submitted)
      prompt_states[mode] = not submitted and { context = context, snapshot = snapshot } or nil
    end,
    submit = function(query)
      if mode == "plain" then
        projectsearch.search_plain(query, path, true)
      else
        projectsearch.search_regex(query, path, true)
      end
    end,
  })
end

command.add(nil, {
  ["project-search:find"] = function(path)
    local has_focus, view = active_view_is_project_search()
    projectsearch.toggle({ path = path, has_focus = has_focus and view == global_project_search })
  end,

  ["project-search:open-tab"] = function(path)
    local node = core.root_view:get_active_node_default()
    local rv = ResultsView(path, "", "plain")
    rv.source_view = node.active_view
    rv:show()
    node:add_view(rv)
    core.add_thread(function()
      core.set_active_view(rv)
      rv:swap_active_child(rv.find_text)
    end)
  end,

  ["project-search:find-plain"] = function(path)
    enter_search_prompt("plain", path)
  end,

  ["project-search:find-regex"] = function(path)
    enter_search_prompt("regex", path)
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

---Cycle through visible text fields and populated results in both directions.
---@param view plugins.projectsearch.resultsview
---@param reverse? boolean
local function cycle_input_text(view, reverse)
  local targets = {}
  for _, child in ipairs {
    view.find_text, view.replace_text, view.includes_text, view.excludes_text
  } do
    if child:is_visible() then targets[#targets + 1] = child end
  end
  if view.results_list:is_visible() and #view.results_list.items > 0 then
    targets[#targets + 1] = view.results_list
  end
  if #targets == 0 then return end
  local index = reverse and #targets or 1
  for i, child in ipairs(targets) do
    if child == view.child_active then
      index = (i - 1 + (reverse and -1 or 1)) % #targets + 1
      break
    end
  end
  if targets[index] == view.results_list then
    view:focus_results()
  else
    view:swap_active_child(targets[index])
  end
  core.last_active_view = view
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

command.add(function()
  local is_search, view = active_view_is_project_search()
  local child = view and view.child_active
  return is_search and child and child.textview == core.active_view
    and view.results_list:is_visible() and #view.results_list.items > 0, view
end, {
  ["project-search:focus-results"] = function(view)
    view:focus_results()
  end
})

command.add(function()
  local is_search, view = active_view_is_project_search()
  return is_search and (core.active_view == view or core.active_view == view.results_list), view
end, {
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

  ["project-search:open-selected-split"] = function(view)
    view:open_selected_result(true)
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
  ["up"]                 = { "project-search:focus-results", "project-search:select-previous" },
  ["down"]               = { "project-search:focus-results", "project-search:select-next" },
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
  ["return"]             = "project-search:open-selected",
  ["ctrl+lclick"]        = "project-search:open-selected-split"
}

core.menu_view:register({ "search" }, {
  {
    id = "projectsearch",
    text = "Find in Files…",
    command = "project-search:find"
  }
}, "projectsearch")

return projectsearch
