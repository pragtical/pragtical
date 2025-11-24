require "core.strict"
local common = require "core.common"
local config = require "core.config"
local style
local cli
local scale
local command
local keymap
local dirwatch
local ime
local RootView
local StatusView
local TitleView
local CommandView
local NagView
local DocView
local Doc
local Project

---Core functionality.
---@class core
local core = {}

local map_new_syntax_colors

local function load_session()
  local ok, t = pcall(dofile, USERDIR .. PATHSEP .. "session.lua")
  return ok and t or {}
end


local function save_session()
  local fp = io.open(USERDIR .. PATHSEP .. "session.lua", "w")
  if fp then
    local session = {
      recents = core.recent_projects,
      window = core.window_mode ~= "fullscreen"
        and table.pack(system.get_window_size(core.window)) or core.window_size,
      window_mode = core.window_mode ~= "fullscreen"
        and core.window_mode or core.prev_window_mode,
      previous_find = core.previous_find,
      previous_replace = core.previous_replace
    }
    fp:write("return " .. common.serialize(session, {pretty = true}))
    fp:close()
  end
end


local function update_recents_project(action, dir_path_abs)
  local dirname = common.normalize_volume(dir_path_abs)
  if not dirname then return end
  local recents = core.recent_projects
  local n = #recents
  for i = 1, n do
    if dirname == recents[i] then
      table.remove(recents, i)
      break
    end
  end
  if action == "add" then
    table.insert(recents, 1, dirname)
  end
end


local function reload_customizations()
  local user_error = not core.load_user_directory()
  local project_error = not core.load_project_module()
  if user_error or project_error then
    -- Use core.add_thread to delay opening the LogView, as opening
    -- it directly here disturbs the normal save operations.
    core.add_thread(function()
      local LogView = require "core.logview"
      local rn = core.root_view.root_node
      for _,v in pairs(core.root_view.root_node:get_children()) do
        if v:is(LogView) then
          rn:get_node_for_view(v):set_active_view(v)
          return
        end
      end
      command.perform("core:open-log")
    end)
  end
end


function core.add_project(project)
  project = type(project) == "string" and Project(common.normalize_volume(project)) or project
  local duplicate = false
  for _, cproject in ipairs(core.projects) do
    if project.path == cproject.path then
      duplicate = true
      project = cproject
      core.warn("The project '%s' is already loaded.", common.basename(project.path))
      break
    end
  end
  if not duplicate then
    table.insert(core.projects, project)
    core.redraw = true
  end
  return project
end


function core.remove_project(project, force)
  for i = (force and 1 or 2), #core.projects do
    if project == core.projects[i] or project == core.projects[i].path then
      local project = core.projects[i]
      table.remove(core.projects, i)
      if
        core.projects[1]
        and
        common.normalize_volume(system.getcwd()) == project.path
      then
        system.chdir(core.projects[1].path)
      end
      return project
    end
  end
  return false
end


function core.set_project(project)
  core.visited_files = {}
  while #core.projects > 0 do core.remove_project(core.projects[#core.projects], true) end
  local project_object = core.add_project(project)
  system.chdir(project_object.path)
  return project_object
end


function core.open_project(project)
  local project = core.set_project(project)
  core.root_view:close_all_docviews()
  reload_customizations()
  update_recents_project("add", project.path)
end


---Get project for currently opened DocView or given filename path.
---If the given path does not belongs to any of the opened projects a new
---project object will be created and returned using the directory of the
---given filename path.
---@param filename? string
---@return core.project? project
---@return boolean is_open The returned project is open
---@return boolean belongs The file belongs to the returned project
function core.current_project(filename)
  if not filename then
    if
      core.active_view:extends(DocView)
      and
      core.active_view.doc and core.active_view.doc.abs_filename
    then
      filename = core.active_view.doc.abs_filename
    else
      return core.projects[1], true, false
    end
  end
  if #core.projects > 1 then
    for _, project in ipairs(core.projects) do
      if project:path_belongs_to(filename) then
        return project, true, true
      end
    end
  end
  if core.projects[1] and core.projects[1]:path_belongs_to(filename) then
    return core.projects[1], true, true
  end
  if not system.get_file_info(filename) then
    return core.projects[1], true, false
  end
  local dirname = common.dirname(filename)
  if dirname then
    return Project(dirname), false, true
  end
end


local function strip_trailing_slash(filename)
  if filename:match("[^:]["..PATHSEP.."]$") then
    return filename:sub(1, -2)
  end
  return filename
end


-- create a directory using mkdir but may need to create the parent
-- directories as well.
local function create_user_directory()
  local success, err = common.mkdirp(USERDIR)
  if not success then
    error("cannot create directory \"" .. USERDIR .. "\": " .. err)
  end
  for _, modname in ipairs {'plugins', 'colors', 'fonts'} do
    local subdirname = USERDIR .. PATHSEP .. modname
    if not system.mkdir(subdirname) then
      error("cannot create directory: \"" .. subdirname .. "\"")
    end
  end
end


local function write_user_init_file(init_filename)
  local init_file = io.open(init_filename, "w")
  if not init_file then error("cannot create file: \"" .. init_filename .. "\"") end
  init_file:write([[
-- put user settings here
-- this module will be loaded after everything else when the application starts
-- it will be automatically reloaded when saved

local core = require "core"
local keymap = require "core.keymap"
local config = require "core.config"
local style = require "core.style"

------------------------------ Themes ----------------------------------------

-- light theme:
-- core.reload_module("colors.summer")

--------------------------- Key bindings -------------------------------------

-- key binding:
-- keymap.add { ["ctrl+escape"] = "core:quit" }

-- pass 'true' for second parameter to overwrite an existing binding
-- keymap.add({ ["ctrl+pageup"] = "root:switch-to-previous-tab" }, true)
-- keymap.add({ ["ctrl+pagedown"] = "root:switch-to-next-tab" }, true)

------------------------------- Fonts ----------------------------------------

-- customize fonts:
-- style.font = renderer.font.load(DATADIR .. "/fonts/FiraSans-Regular.ttf", 14 * SCALE)
-- style.code_font = renderer.font.load(DATADIR .. "/fonts/JetBrainsMono-Regular.ttf", 14 * SCALE)
--
-- DATADIR is the location of the installed Pragtical Lua code, default color
-- schemes and fonts.
-- USERDIR is the location of the Pragtical configuration directory.
--
-- font names used by pragtical:
-- style.font          : user interface
-- style.big_font      : big text in welcome screen
-- style.icon_font     : icons
-- style.icon_big_font : toolbar icons
-- style.code_font     : code
--
-- the function to load the font accept a 3rd optional argument like:
--
-- {antialiasing="grayscale", hinting="full", bold=true, italic=true, underline=true, smoothing=true, strikethrough=true}
--
-- possible values are:
-- antialiasing: grayscale, subpixel
-- hinting: none, slight, full
-- bold: true, false
-- italic: true, false
-- underline: true, false
-- smoothing: true, false
-- strikethrough: true, false

------------------------------ Plugins ----------------------------------------

-- disable plugin loading setting config entries:

-- disable plugin detectindent, otherwise it is enabled by default:
-- config.plugins.detectindent = false

---------------------------- Miscellaneous -------------------------------------

-- modify list of files to ignore when indexing the project:
-- config.ignore_files = {
--   -- folders
--   "^%.svn/",        "^%.git/",   "^%.hg/",        "^CVS/", "^%.Trash/", "^%.Trash%-.*/",
--   "^node_modules/", "^%.cache/", "^__pycache__/",
--   -- files
--   "%.pyc$",         "%.pyo$",       "%.exe$",        "%.dll$",   "%.obj$", "%.o$",
--   "%.a$",           "%.lib$",       "%.so$",         "%.dylib$", "%.ncb$", "%.sdf$",
--   "%.suo$",         "%.pdb$",       "%.idb$",        "%.class$", "%.psd$", "%.db$",
--   "^desktop%.ini$", "^%.DS_Store$", "^%.directory$",
-- }

]])
  init_file:close()
end


function core.write_init_project_module(init_filename)
  local init_file = io.open(init_filename, "w")
  if not init_file then error("cannot create file: \"" .. init_filename .. "\"") end
  init_file:write([[
-- Put project's module settings here.
-- This module will be loaded when opening a project, after the user module
-- configuration.
-- It will be automatically reloaded when saved.

local config = require "core.config"

-- you can add some patterns to ignore files within the project
-- this will overwrite the default ignored files
-- config.ignore_files = {"^%.", <some-patterns>}

-- this will extend the list of default ignored files
-- for i, v in ipairs({"^%.", <some-patterns>}) do table.insert(config.ignore_files, v) end

-- Patterns are normally applied to the file's or directory's name, without
-- its path. See below about how to apply filters on a path.
--
-- Here some examples:
--
-- "^%." matches any file of directory whose basename begins with a dot.
--
-- When there is an '/' at the end, the pattern will only match directories.
-- When there is an "$" at the end, the pattern will only match files.
--
-- "^%.git/" matches any directory named ".git" anywhere in the project.
-- "somefile$" matches a specific file
-- "%.lua$" matches any lua file
--
-- If a "/" appears anywhere in the pattern (except when it appears at the end or
-- is immediately followed by a '$'), then the pattern will be applied to the full
-- path of the file or directory. An initial "/" will be prepended to the file's
-- or directory's path to indicate the project's root.
--
-- "^/node_modules/" will match a directory named "node_modules" at the project's root.
-- "^/build.*/" will match any top level directory whose name begins with "build".
-- "^/subprojects/.+/" will match any directory inside a top-level folder named "subprojects".

-- You may activate some plugins on a per-project basis to override the user's settings.
-- config.plugins.trimwitespace = true
]])
  init_file:close()
end


function core.load_user_directory()
  return core.try(function()
    local stat_dir = system.get_file_info(USERDIR)
    if not stat_dir then
      create_user_directory()
    end
    local init_filename = USERDIR .. PATHSEP .. "init.lua"
    local stat_file = system.get_file_info(init_filename)
    if not stat_file then
      write_user_init_file(init_filename)
    end
    dofile(init_filename)
  end)
end


function core.configure_borderless_window()
  system.set_window_bordered(core.window, not config.borderless)
  core.title_view:configure_hit_test(config.borderless)
  core.title_view.visible = config.borderless
end


local function add_config_files_hooks()
  -- auto-realod style when user's module is saved by overriding Doc:Save()
  local doc_save = Doc.save
  local user_filename = system.absolute_path(USERDIR .. PATHSEP .. "init.lua")
  function Doc:save(filename, abs_filename)
    local module_filename = core.project_absolute_path(".pragtical_project.lua")
    doc_save(self, filename, abs_filename)
    if self.abs_filename == user_filename or self.abs_filename == module_filename then
      reload_customizations()
      core.configure_borderless_window()
    end
  end
end


function core.init()
  core.log_items = {}
  core.log_quiet("Pragtical version %s - mod-version %s", VERSION, MOD_VERSION_STRING)

  core.window = renwindow._restore()
  if core.window == nil then
    core.window = renwindow.create("")
  end

  DEFAULT_FPS = core.window:get_refresh_rate() or DEFAULT_FPS
  DEFAULT_SCALE = system.get_scale(core.window)
  SCALE = tonumber(os.getenv("PRAGTICAL_SCALE")) or DEFAULT_SCALE

  style = require "colors.default"
  cli = require "core.cli"
  command = require "core.command"
  keymap = require "core.keymap"
  dirwatch = require "core.dirwatch"
  ime = require "core.ime"
  RootView = require "core.rootview"
  StatusView = require "core.statusview"
  TitleView = require "core.titleview"
  CommandView = require "core.commandview"
  NagView = require "core.nagview"
  Project = require "core.project"
  DocView = require "core.docview"
  Doc = require "core.doc"

  -- apply to default color scheme
  map_new_syntax_colors()

  if PATHSEP == '\\' then
    USERDIR = common.normalize_volume(USERDIR)
    DATADIR = common.normalize_volume(DATADIR)
    EXEDIR  = common.normalize_volume(EXEDIR)
  end

  local session = load_session()
  core.recent_projects = session.recents or {}
  core.previous_find = session.previous_find or {}
  core.previous_replace = session.previous_replace or {}
  core.window_mode = session.window_mode or "normal"
  core.prev_window_mode = core.window_mode
  core.window_size = session.window or table.pack(system.get_window_size(core.window))

  -- remove projects that don't exist any longer
  local projects_removed = 0;
  for i, project_dir in ipairs(core.recent_projects) do
    if not system.get_file_info(project_dir) then
      table.remove(core.recent_projects, i - projects_removed)
      projects_removed = projects_removed + 1
    end
  end

  local project_dir = core.recent_projects[1] or "."
  local project_dir_explicit = false
  local files = {}
  if not RESTARTED then
    for i = 2, #ARGS do
      local arg_filename = strip_trailing_slash(ARGS[i])
      local info = system.get_file_info(arg_filename) or {}
      if info.type == "dir" then
        project_dir = arg_filename
        project_dir_explicit = true
      else
        -- on macOS we can get an argument like "-psn_0_52353" that we just ignore.
        if not ARGS[i]:match("^-psn") then
          local filename = common.normalize_path(arg_filename)
          local abs_filename = system.absolute_path(filename or "")
          local file_abs
          if filename == abs_filename then
            file_abs = abs_filename
          else
            file_abs = system.absolute_path(".") .. PATHSEP .. filename
          end
          if file_abs then
            table.insert(files, file_abs)
            project_dir = file_abs:match("^(.+)[/\\].+$")
          end
        end
      end
    end
  end

  --Set the maximum fps from display refresh rate.
  config.fps = DEFAULT_FPS

  ---The actual maximum frames per second that can be rendered.
  ---@type number
  core.fps = config.fps

  ---The maximum time coroutines have to run on a per frame iteration basis.
  ---This value is automatically updated on each core.step().
  ---@type number
  core.co_max_time = 1 / config.fps - 0.004

  core.frame_start = 0
  core.clip_rect_stack = {{ 0,0,0,0 }}
  core.docs = {}
  core.projects = {}
  core.cursor_clipboard = {}
  core.cursor_clipboard_whole_line = {}
  core.threads = setmetatable({}, { __mode = "k" })
  core.background_threads = 0
  core.blink_start = system.get_time()
  core.blink_timer = core.blink_start
  core.redraw = true
  core.visited_files = {}
  core.restart_request = false
  core.quit_request = false
  core.init_working_dir = system.getcwd()
  core.collect_garbage = false

  -- We load core views before plugins that may need them.
  ---@type core.rootview
  core.root_view = RootView()
  ---@type core.commandview
  core.command_view = CommandView()
  ---@type core.statusview
  core.status_view = StatusView()
  ---@type core.nagview
  core.nag_view = NagView()
  ---@type core.titleview
  core.title_view = TitleView()

  -- Some plugins (eg: console) require the nodes to be initialized to defaults
  local cur_node = core.root_view.root_node
  cur_node.is_primary_node = true
  cur_node:split("up", core.title_view, {y = true})
  cur_node = cur_node.b
  cur_node:split("up", core.nag_view, {y = true})
  cur_node = cur_node.b
  cur_node = cur_node:split("down", core.command_view, {y = true})
  cur_node = cur_node:split("down", core.status_view, {y = true})

  -- Load default commands first so plugins can override them
  command.add_defaults()

  -- Load user module, plugins and project module
  local got_user_error, got_project_error = not core.load_user_directory()

  local project_dir_abs = system.absolute_path(project_dir)
  -- We prevent set_project below to effectively add and scan the directory because the
  -- project module and its ignore files is not yet loaded.
  if project_dir_abs and pcall(core.set_project, project_dir_abs) then
    got_project_error = not core.load_project_module()
    if project_dir_explicit then
      update_recents_project("add", project_dir_abs)
    end
  else
    if not project_dir_explicit then
      update_recents_project("remove", project_dir)
    end
    project_dir_abs = system.absolute_path(".")
    local status, err = pcall(core.set_project, project_dir_abs)
    if status then
      got_project_error = not core.load_project_module()
    else
      system.show_fatal_error("Pragtical internal error", "cannot set project directory to cwd")
      os.exit(1)
    end
  end

  -- Load core and user plugins giving preference to user ones with same name.
  local plugins_success, plugins_refuse_list = core.load_plugins()

  -- Parse commandline arguments
  cli.parse(ARGS)

  -- Update the files to open
  if cli.last_command ~= "default" then
    files = {}
    system.chdir(core.init_working_dir)
    for _, argument in ipairs(cli.unhandled_arguments) do
      local arg_filename = strip_trailing_slash(argument)
      local info = system.get_file_info(arg_filename) or {}
      if info.type ~= "dir" then
        local filename = common.normalize_path(arg_filename)
        local abs_filename = system.absolute_path(filename or "")
        local file_abs
        if filename == abs_filename then
          file_abs = abs_filename
        else
          file_abs = system.absolute_path(".") .. PATHSEP .. filename
        end
        if file_abs then
          table.insert(files, file_abs)
        end
      end
    end
  end

  -- Maximizing the window makes it lose the hidden attribute on Windows
  -- so we delay this to keep window hidden until args parsed. Also, on
  -- Wayland we have issues applying the mode before showing the window
  -- so we delay it on all platforms, except macOS. On macOS setting the
  -- mode to maximized seems to cause issues resetting its size so setting
  -- the size is all we need on that platform.
  if session.window then
    system.set_window_size(core.window, table.unpack(session.window))
  end
  if session.window_mode == "maximized" and PLATFORM ~= "Mac OS X" then
    core.add_thread(function()
      system.set_window_mode(core.window, "maximized")
    end)
  end


  do
    local pdir, pname = project_dir_abs:match("(.*)[/\\\\](.*)")
    core.log("Opening project %q from directory %s", pname, pdir)
  end

  for _, filename in ipairs(files) do
    core.root_view:open_doc(core.open_doc(filename))
  end

  if not plugins_success or got_user_error or got_project_error then
    -- defer LogView to after everything is initialized,
    -- so that EmptyView won't be added after LogView.
    core.add_thread(function()
      command.perform("core:open-log")
    end)
  end

  core.configure_borderless_window()

  if #plugins_refuse_list.userdir.plugins > 0 or #plugins_refuse_list.datadir.plugins > 0 then
    local opt = {
      { text = "Exit", default_no = true },
      { text = "Continue", default_yes = true }
    }
    local msg = {}
    for _, entry in pairs(plugins_refuse_list) do
      if #entry.plugins > 0 then
        local msg_list = {}
        for _, p in pairs(entry.plugins) do
          table.insert(msg_list, string.format("%s[%s]", p.file, p.version_string))
        end
        msg[#msg + 1] = string.format("Plugins from directory \"%s\":\n%s", common.home_encode(entry.dir), table.concat(msg_list, "\n"))
      end
    end
    core.nag_view:show(
      "Refused Plugins",
      string.format(
        "Some plugins are not loaded due to version mismatch. Expected version %s.\n\n%s.\n\n" ..
        "Please download a recent version from https://github.com/pragtical/plugins.",
        MOD_VERSION_STRING, table.concat(msg, ".\n\n")),
      opt, function(item)
        if item.text == "Exit" then os.exit(1) end
      end)
  end

  add_config_files_hooks()
end


function core.confirm_close_docs(docs, close_fn, ...)
  local dirty_count = 0
  local dirty_name
  for _, doc in ipairs(docs or core.docs) do
    if doc:is_dirty() then
      dirty_count = dirty_count + 1
      dirty_name = doc:get_name()
    end
  end
  if dirty_count > 0 then
    local text
    if dirty_count == 1 then
      text = string.format("\"%s\" has unsaved changes. Quit anyway?", dirty_name)
    else
      text = string.format("%d docs have unsaved changes. Quit anyway?", dirty_count)
    end
    local args = {...}
    local opt = {
      { text = "Yes", default_yes = true },
      { text = "No", default_no = true }
    }
    core.nag_view:show("Unsaved Changes", text, opt, function(item)
      if item.text == "Yes" then close_fn(table.unpack(args)) end
    end)
  else
    close_fn(...)
  end
end

local temp_uid = math.floor(system.get_time() * 1000) % 0xffffffff
local temp_file_prefix = string.format(".pragtical_temp_%08x", tonumber(temp_uid))
local temp_file_counter = 0

function core.delete_temp_files(dir)
  dir = type(dir) == "string" and common.normalize_path(dir) or USERDIR
  for _, filename in ipairs(system.list_dir(dir) or {}) do
    if filename:find(temp_file_prefix, 1, true) == 1 then
      os.remove(dir .. PATHSEP .. filename)
    end
  end
end

function core.temp_filename(ext, dir)
  dir = type(dir) == "string" and common.normalize_path(dir) or USERDIR
  temp_file_counter = temp_file_counter + 1
  return dir .. PATHSEP .. temp_file_prefix
      .. string.format("%06x", temp_file_counter) .. (ext or "")
end


function core.exit(quit_fn, force)
  if force then
    core.delete_temp_files()
    while #core.projects > 1 do core.remove_project(core.projects[#core.projects]) end
    save_session()
    quit_fn()
  else
    core.confirm_close_docs(core.docs, core.exit, quit_fn, true)
  end
end


function core.quit(force)
  core.exit(function() core.quit_request = true end, force)
end


function core.restart()
  core.exit(function()
    core.restart_request = true
    core.window:_persist()
  end)
end


local mod_version_regex =
  regex.compile([[--.*mod-version:\s*(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:$|\s)]])
local function get_plugin_details(filename)
  local info = system.get_file_info(filename)
  if info ~= nil and info.type == "dir" then
    filename = filename .. PATHSEP .. "init.lua"
    info = system.get_file_info(filename)
  end
  if not info or not filename:match("%.lua$") then return false end
  local f = io.open(filename, "r")
  if not f then return false end
  local priority = false
  local version_match = false
  local major, minor, patch

  for line in f:lines() do
    local header_found = false

    major, minor, patch = mod_version_regex:match(line)
    major = tonumber(major)
    if major then
      minor, patch = tonumber(minor) or 0, tonumber(patch) or 0

      if
        major == MOD_VERSION_MAJOR
        and
        minor <= MOD_VERSION_MINOR
        and
        (minor < MOD_VERSION_MINOR or patch <= MOD_VERSION_PATCH)
      then
        version_match = true
      end

      priority = line:match('%-%-.*%f[%a]priority%s*:%s*(%d+)')
      if priority then priority = tonumber(priority) end

      header_found = true
    end

    if header_found then
      break
    end
  end
  f:close()
  return true, {
    version_match = version_match,
    version = major and {major, minor, patch} or {},
    priority = priority or 100
  }
end


function core.load_plugins()
  local no_errors = true
  local refused_list = {
    userdir = {dir = USERDIR, plugins = {}},
    datadir = {dir = DATADIR, plugins = {}},
  }
  local files, ordered = {}, {}
  for _, root_dir in ipairs {DATADIR, USERDIR} do
    local plugin_dir = root_dir .. PATHSEP .. "plugins"
    for _, filename in ipairs(system.list_dir(plugin_dir) or {}) do
      if not files[filename] then
        table.insert(
          ordered, {file = filename}
        )
      end
      -- user plugins will always replace system plugins
      files[filename] = plugin_dir
    end
  end

  for _, plugin in ipairs(ordered) do
    local dir = files[plugin.file]
    local name = plugin.file:match("(.-)%.lua$") or plugin.file
    local is_lua_file, details = get_plugin_details(dir .. PATHSEP .. plugin.file)

    plugin.valid = is_lua_file
    plugin.name = name
    plugin.dir = dir
    plugin.priority = details and details.priority or 100
    plugin.version_match = details and details.version_match or false
    plugin.version = details and details.version or {}
    plugin.version_string = #plugin.version > 0 and table.concat(plugin.version, ".") or "unknown"
  end

  -- sort by priority or name for plugins that have same priority
  table.sort(ordered, function(a, b)
    if a.priority ~= b.priority then
      return a.priority < b.priority
    end
    return a.name < b.name
  end)

  local load_start = system.get_time()
  for _, plugin in ipairs(ordered) do
    if plugin.valid then
      if not config.skip_plugins_version and not plugin.version_match then
        core.log_quiet(
          "Version mismatch for plugin %q[%s] from %s",
          plugin.name,
          plugin.version_string,
          plugin.dir
        )
        local rlist = plugin.dir:find(USERDIR, 1, true) == 1
          and 'userdir' or 'datadir'
        local list = refused_list[rlist].plugins
        table.insert(list, plugin)
      elseif config.plugins[plugin.name] ~= false then
        local start = system.get_time()
        local ok, loaded_plugin = core.try(require, "plugins." .. plugin.name)
        if ok then
          local plugin_version = ""
          if plugin.version_string ~= MOD_VERSION_STRING then
            plugin_version = "["..plugin.version_string.."]"
          end
          core.log_quiet(
            "Loaded plugin %q%s from %s in %.1fms",
            plugin.name,
            plugin_version,
            plugin.dir,
            (system.get_time() - start) * 1000
          )
        end
        if not ok then
          no_errors = false
        elseif config.plugins[plugin.name].onload then
          core.try(config.plugins[plugin.name].onload, loaded_plugin)
        end
      end
    end
  end
  core.log_quiet(
    "Loaded all plugins in %.1fms",
    (system.get_time() - load_start) * 1000
  )
  return no_errors, refused_list
end


function core.load_project_module()
  local filename = core.project_absolute_path(".pragtical_project.lua")
  if system.get_file_info(filename) then
    return core.try(function()
      local fn, err = loadfile(filename)
      if not fn then error("Error when loading project module:\n\t" .. err) end
      fn()
      core.project_module_loaded = true
      core.log_quiet("Loaded project module")
    end)
  end
  return true
end


---Map newly introduced syntax symbols when missing from current color scheme.
---@param clear_new? boolean Only perform removal of new syntax symbols
map_new_syntax_colors = function(clear_new)
  ---New syntax symbols that may not be defined by all color schemes
  local symbols_map = {
    -- symbols related to doc comments
    ["annotation"]            = { alt = "keyword",  dec=30 },
    ["annotation.string"]     = { alt = "string",   dec=30 },
    ["annotation.param"]      = { alt = "symbol",   dec=30 },
    ["annotation.type"]       = { alt = "keyword2", dec=30 },
    ["annotation.operator"]   = { alt = "operator", dec=30 },
    ["annotation.function"]   = { alt = "function", dec=30 },
    ["annotation.number"]     = { alt = "number",   dec=30 },
    ["annotation.keyword2"]   = { alt = "keyword2", dec=30 },
    ["annotation.literal"]    = { alt = "literal",  dec=30 },
    ["attribute"]             = { alt = "keyword",  dec=30 },
    -- Keywords like: true or false
    ["boolean"]               = { alt = "literal"   },
    -- Single quote sequences like: 'a'
    ["character"]             = { alt = "string"    },
    -- can be escape sequences like: \t, \r, \n
    ["character.special"]     = {                   },
    -- Keywords like: if, else, elseif
    ["conditional" ]          = { alt = "keyword"   },
    -- conditional ternary as: condition ? value1 : value2
    ["conditional.ternary"]   = { alt = "operator"  },
    -- keywords like: nil, null
    ["constant"]              = { alt = "number"    },
    ["constant.builtin"]      = {                   },
    -- a macro constant as in: #define MYVAL 1
    ["constant.macro"]        = {                   },
    -- constructor declarations as in: __constructor() or myclass::myclass()
    ["constructor"]           = { alt = "function"  },
    ["debug"]                 = { alt = "comment"   },
    ["define"]                = { alt = "keyword"   },
    ["error"]                 = { alt = "keyword"   },
    -- keywords like: try, catch, finally
    ["exception"]             = { alt = "keyword"   },
    -- class or table fields
    ["field"]                 = { alt = "normal"    },
    -- a numerical constant that holds a float
    ["float"]                 = { alt = "number"    },
    -- function name in a call
    ["function.call"]         = {                   },
    -- a function call that was declared as a macro like in: #define myfunc()
    ["function.macro"]        = {                   },
    -- keywords like: include, import, require
    ["include"]               = { alt = "keyword"   },
    -- keywords like: return
    ["keyword.return"]        = {                   },
    -- keywords like: func, function
    ["keyword.function"]      = {                   },
    -- keywords like: and, or
    ["keyword.operator"]      = {                   },
    -- a goto label name like in: label: or ::label::
    ["label"]                 = { alt = "function"  },
    -- class method declaration
    ["method"]                = { alt = "function"  },
    -- class method call
    ["method.call"]           = {                   },
    -- namespace name like in namespace::subelement or namespace\subelement
    ["namespace"]             = { alt = "literal"   },
    -- parameters in a function declaration
    ["parameter"]             = { alt = "operator"  },
    -- keywords like: #if, #elif, #endif
    ["preproc"]               = { alt = "keyword"   },
    -- any type of punctuation
    ["punctuation"]           = { alt = "normal"    },
    -- punctuation like: (), {}, []
    ["punctuation.brackets"]  = {                   },
    -- punctuation like: , or :
    ["punctuation.delimiter"] = { alt = "operator"  },
    -- puctuation like: # or @
    ["punctuation.special"]   = { alt = "operator"  },
    -- keywords like: while, for
    ["repeat"]                = { alt = "keyword"   },
    -- keywords like: static, const, constexpr
    ["storageclass"]          = { alt = "keyword"   },
    ["storageclass.lifetime"] = {                   },
    -- tags in HTML and JSX
    ["tag"]                   = { alt = "function"  },
    -- tag delimeters <>
    ["tag.delimiter"]         = { alt = "operator"  },
    -- tag attributes eg: id="id-attr"
    ["tag.attribute"]         = { alt = "keyword"   },
    -- additions on diff or patch
    ["text.diff.add"]         = { alt = style.good  },
    -- deletions on diff or patch
    ["text.diff.delete"]      = { alt = style.error },
    -- a language standard library support types
    ["type"]                  = { alt = "keyword2"  },
    -- a language builtin types like: char, double, int
    ["type.builtin"]          = {                   },
    -- a custom type defininition like ssize_t on typedef long int ssize_t
    ["type.definition"]       = {                   },
    -- keywords like: private, public
    ["type.qualifier"]        = {                   },
    -- any variable defined or accessed on the code
    ["variable"]              = { alt = "normal"    },
    -- keywords like: this, self, parent
    ["variable.builtin"]      = { alt = "keyword2"  },
  }

  if clear_new then
    for symbol_name in pairs(symbols_map) do
      if style.syntax[symbol_name] then
        style.syntax[symbol_name] = nil
      end
    end
    return
  end

  --- map symbols not defined on syntax
  for symbol_name in pairs(symbols_map) do
    if not style.syntax[symbol_name] then
      local sections = {};
      for match in (symbol_name.."."):gmatch("(.-)%.") do
        table.insert(sections, match);
      end
      for i=#sections, 1, -1 do
        local section = table.concat(sections, ".", 1, i)
        local parent = symbols_map[section]
        if parent and parent.alt then
          -- copy the color
          local color = table.pack(
            table.unpack(style.syntax[parent.alt] or parent.alt)
          )
          if parent.dec then
            color = common.darken_color(color, parent.dec)
          elseif parent.inc then
            color = common.lighten_color(color, parent.inc)
          end
          style.syntax[symbol_name] = color
          break
        end
      end
    end
  end

  -- metatable to automatically map custom symbol types to the nearest parent
  setmetatable(style.syntax, {
    __index = function(syntax, type_name)
      if type(type_name) ~= "string" then
        return rawget(syntax, type_name)
      end
      if not rawget(syntax, type_name) and type(type_name) == "string" then
        local sections = {};
        for match in (type_name.."."):gmatch("(.-)%.") do
          table.insert(sections, match);
        end
        if #sections > 1 then
          for i=#sections, 1, -1 do
            local section = table.concat(sections, ".", 1, i)
            local parent = rawget(syntax, section)
            if parent then
              -- copy the color
              local color = table.pack(table.unpack(parent))
              rawset(syntax, type_name, color)
              return color
            end
          end
        end
      end
      return rawget(syntax, type_name)
    end
  })
end


function core.reload_module(name)
  local old = package.loaded[name]
  local is_color_scheme = name:match("^colors%..*")
  package.loaded[name] = nil
  -- clear previous color scheme syntax symbols
  if is_color_scheme then
    setmetatable(style.syntax, nil)
    map_new_syntax_colors(true)
  end
  local new = require(name)
  if type(old) == "table" then
    for k, v in pairs(new) do old[k] = v end
    package.loaded[name] = old
  end
  -- map colors that may be missing on the new color scheme
  if is_color_scheme then
    map_new_syntax_colors()
  end
end


function core.set_visited(filename)
  for i = 1, #core.visited_files do
    if core.visited_files[i] == filename then
      table.remove(core.visited_files, i)
      break
    end
  end
  table.insert(core.visited_files, 1, filename)
  if #core.visited_files > config.max_visited_files then
    local remove = #core.visited_files - config.max_visited_files
    common.splice(core.visited_files, config.max_visited_files, remove)
  end
end


function core.set_active_view(view)
  assert(view, "Tried to set active view to nil")
  -- Reset the IME even if the focus didn't change
  ime.stop()
  if view ~= core.active_view then
    system.text_input(core.window, view:supports_text_input())
    if core.active_view and core.active_view.force_focus then
      core.next_active_view = view
      return
    end
    core.next_active_view = nil
    if view.doc and view.doc.abs_filename then
      core.set_visited(view.doc.abs_filename)
    end
    core.last_active_view = core.active_view
    core.active_view = view
  end
  if
    core.active_view:extends(DocView)
    and
    core.active_view.doc and core.active_view.doc.abs_filename
  then
    local project = core.current_project(
      core.active_view.doc.abs_filename
    )
    if project then system.chdir(project.path) end
  end
end


function core.show_title_bar(show)
  core.title_view.visible = show
end

local function add_thread(f, weak_ref, background, ...)
  local key = weak_ref or #core.threads + 1
  local args = {...}
  local fn = function() return core.try(f, table.unpack(args)) end
  local info = debug.getinfo(2, "Sl")
  local loc = string.format("%s:%d", info.short_src, info.currentline)
  core.threads[key] = {
    cr = coroutine.create(fn), wake = 0, background = background, loc = loc
  }
  if background then
    core.background_threads = core.background_threads + 1
  end
  return key
end

function core.add_thread(f, weak_ref, ...)
  return add_thread(f, weak_ref, nil, ...)
end

function core.add_background_thread(f, weak_ref, ...)
  return add_thread(f, weak_ref, true, ...)
end


function core.push_clip_rect(x, y, w, h)
  local x2, y2, w2, h2 = table.unpack(core.clip_rect_stack[#core.clip_rect_stack])
  local r, b, r2, b2 = x+w, y+h, x2+w2, y2+h2
  x, y = math.max(x, x2), math.max(y, y2)
  b, r = math.min(b, b2), math.min(r, r2)
  w, h = r-x, b-y
  table.insert(core.clip_rect_stack, { x, y, w, h })
  renderer.set_clip_rect(x, y, w, h)
end


function core.pop_clip_rect()
  table.remove(core.clip_rect_stack)
  local x, y, w, h = table.unpack(core.clip_rect_stack[#core.clip_rect_stack])
  renderer.set_clip_rect(x, y, w, h)
end

-- legacy interface
function core.root_project() return core.projects[1] end
function core.normalize_to_project_dir(path) return core.root_project():normalize_path(path) end
function core.project_absolute_path(path) return core.root_project():absolute_path(path) end

local function close_doc_view(doc)
  core.add_thread(function()
    local views = core.root_view.root_node:get_children()
    for _, view in ipairs(views) do
      if view.doc == doc then
        local node = core.root_view.root_node:get_node_for_view(view)
        node:close_view(core.root_view.root_node, view)
      end
    end
  end)
end

function core.open_doc(filename)
  local new_file = true
  local abs_filename
  local close_docview = false
  if filename then
    -- normalize filename and set absolute filename then
    -- try to find existing doc for filename
    filename = core.root_project():normalize_path(filename)
    abs_filename = core.root_project():absolute_path(filename)
    local file_info = system.get_file_info(abs_filename)
    new_file = not file_info
    if file_info and file_info.size > config.file_size_limit * 1e6 then
      local size = file_info.size / 1024 / 1024
      core.error(
        "File '%s' with size %0.2fMB exceeds config.file_size_limit of %sMB",
        filename, size, config.file_size_limit
      )
      close_docview = true
      filename = nil
      abs_filename = nil
      new_file = true
    end
    for _, doc in ipairs(core.docs) do
      if doc.abs_filename and abs_filename == doc.abs_filename then
        if close_docview then close_doc_view(doc) end
        return doc
      end
    end
  end
  -- no existing doc for filename; create new
  local doc = Doc(filename, abs_filename, new_file)
  table.insert(core.docs, doc)
  core.log_quiet(filename and "Opened doc \"%s\"" or "Opened new doc", filename)
  if close_docview then close_doc_view(doc) end
  return doc
end


function core.get_views_referencing_doc(doc)
  local res = {}
  local views = core.root_view.root_node:get_children()
  for _, view in ipairs(views) do
    if view.doc == doc then table.insert(res, view) end
  end
  return res
end


function core.custom_log(level, show, backtrace, fmt, ...)
  local text = string.format(fmt, ...)
  if show then
    local s = style.log[level]
    if core.status_view then
      core.status_view:show_message(s.icon, s.color, text)
    end
  end

  local info = debug.getinfo(2, "Sl")
  local at = string.format("%s:%d", info.short_src, info.currentline)
  local item = {
    level = level,
    text = text,
    time = os.time(),
    at = at,
    info = backtrace and debug.traceback("", 2):gsub("\t", "")
  }
  table.insert(core.log_items, item)
  if #core.log_items > config.max_log_items then
    table.remove(core.log_items, 1)
  end
  return item
end


function core.log(...)
  return core.custom_log("INFO", true, false, ...)
end


function core.log_quiet(...)
  return core.custom_log("INFO", false, false, ...)
end

function core.warn(...)
  return core.custom_log("WARN", true, true, ...)
end

function core.error(...)
  return core.custom_log("ERROR", true, true, ...)
end


function core.get_log(i)
  if i == nil then
    local r = {}
    for _, item in ipairs(core.log_items) do
      table.insert(r, core.get_log(item))
    end
    return table.concat(r, "\n")
  end
  local item = type(i) == "number" and core.log_items[i] or i
  local text = string.format("%s [%s] %s at %s", os.date(nil, item.time), item.level, item.text, item.at)
  if item.info then
    text = string.format("%s\n%s\n", text, item.info)
  end
  return text
end


function core.try(fn, ...)
  local err
  local ok, res = xpcall(fn, function(msg)
    local item = core.error("%s", msg)
    item.info = debug.traceback("", 2):gsub("\t", "")
    err = msg
  end, ...)
  if ok then
    return true, res
  end
  return false, err
end

---This function rescales the interface to the system default scale
---by incrementing or decrementing current user scale.
---@param new_scale number
local function update_scale(new_scale)
  local prev_default = DEFAULT_SCALE
  DEFAULT_SCALE = new_scale
  if SCALE == prev_default or config.plugins.scale.autodetect then
    if new_scale == SCALE then return end
    local target, target_code
    if new_scale > prev_default then
      target = scale.get() + (new_scale - prev_default)
      target_code = scale.get_code() + (new_scale - prev_default)
    else
      target = scale.get() - (prev_default - new_scale)
      target_code = scale.get_code() - (prev_default - new_scale)
    end
    -- do not scale smaller than new_scale
    scale.set(target < new_scale and new_scale or target)
    scale.set_code(target_code < new_scale and new_scale or target_code)
  end
end

function core.on_event(type, ...)
  local did_keymap = false
  if type == "textinput" then
    core.root_view:on_text_input(...)
  elseif type == "textediting" then
    ime.on_text_editing(...)
  elseif type == "keypressed" then
    -- In some cases during IME composition input is still sent to us
    -- so we just ignore it.
    if ime.editing then return false end
    did_keymap = keymap.on_key_pressed(...)
  elseif type == "keyreleased" then
    keymap.on_key_released(...)
  elseif type == "mousemoved" then
    core.root_view:on_mouse_moved(...)
  elseif type == "mousepressed" then
    if not core.root_view:on_mouse_pressed(...) then
      did_keymap = keymap.on_mouse_pressed(...)
    end
  elseif type == "mousereleased" then
    core.root_view:on_mouse_released(...)
  elseif type == "mouseleft" then
    core.root_view:on_mouse_left()
  elseif type == "mousewheel" then
    if not core.root_view:on_mouse_wheel(...) then
      did_keymap = keymap.on_mouse_wheel(...)
    end
  elseif type == "touchpressed" then
    core.root_view:on_touch_pressed(...)
  elseif type == "touchreleased" then
    core.root_view:on_touch_released(...)
  elseif type == "touchmoved" then
    core.root_view:on_touch_moved(...)
  elseif type == "resized" then
    local window_mode = system.get_window_mode(core.window)
    if window_mode ~= "fullscreen" and window_mode ~= "maximized" then
      core.window_size = table.pack(system.get_window_size(core.window))
    -- check needed because fullscreen can be triggered twice
    elseif core.window_mode ~= "fullscreen" then
      core.prev_window_mode = core.window_mode
    end
    core.window_mode = window_mode
  elseif type == "minimized" or type == "maximized" or type == "restored" then
    core.window_mode = type == "restored" and "normal" or type
    if core.window_mode == "normal" then
      core.window_size = table.pack(system.get_window_size(core.window))
    end
  elseif type == "filedropped" then
    core.root_view:on_file_dropped(...)
  elseif type == "focuslost" then
    core.root_view:on_focus_lost(...)
  elseif type == "quit" then
    core.quit()
  end
  return did_keymap
end


function core.get_view_title(view)
  local title = ""
  local project = core.projects[1]
  if view.get_filename and view:get_filename() then
    if view.doc.abs_filename then
      local prj, is_open, belongs = core.current_project(view.doc.abs_filename)
      if prj and is_open and belongs then
        project = prj
        title = common.relative_path(project.path, view.doc.abs_filename)
        if view.doc:is_dirty() then title = title .. "*" end
      else
        title = view:get_filename()
      end
    else
      title = view:get_filename()
    end
  else
    project = {path = ""}
    title = view:get_name()
  end
  if title and title ~= "---" then
    return title .. (
      project.path ~= "" and " - " .. common.basename(project.path) or ""
    )
  end
  return ""
end


function core.compose_window_title(title)
  return (title == "" or title == nil) and "Pragtical" or title .. " - Pragtical"
end

local draw_stats_fps = 0
local draw_stats_avg = "0"
local draw_stats_co_max = "0"
local draw_stats_co_count = 0
local draw_stats_frames = {}
local draw_stats_cotimes = {}
local draw_stats_last_time = system.get_time()
local draw_stats_overlay_width = 0

---Draw some stats useful for troubleshooting.
---Called when config.draw_stats is enabled.
local function draw_stats()
  local x, y = 20 * SCALE, 30 * SCALE
  local font = style.font
  local c1, c2 = style.syntax.keyword, style.syntax.string
  local h = font:get_height()
  local color = {table.unpack(style.background)} color[4] = 200
  renderer.draw_rect(0, y - (10*SCALE), draw_stats_overlay_width, h * 4 + y, color)
  local x2 = renderer.draw_text(font, "FPS: ", x, y, c1)
  renderer.draw_text(font, draw_stats_fps, x2, y, c2)
  y = y + h + 3 * SCALE
  x2 = renderer.draw_text(font, "AVG: ", x, y, c1)
  renderer.draw_text(font, draw_stats_avg, x2, y, c2)
  y = y + h
  x2 = renderer.draw_text(font, "COTIME: ", x, y, c1)
  x2 = renderer.draw_text(font, draw_stats_co_max, x2, y, c2)
  y = y + h + 3 * SCALE
  draw_stats_overlay_width = x2 + x
  x2 = renderer.draw_text(font, "COCOUNT: ", x, y, c1)
  renderer.draw_text(font, draw_stats_co_count, x2, y, c2)
end

---Time it takes to render a single frame (value will be cap to 1000fps).
---@type number
local rendering_speed = 0.004

---Each second there is time assigned to drawing the amount of config.fps
---and for executing the coroutine tasks, this value represents the time
---that coroutines should not exceed for each 1s cycle.
---@type number
local cycle_end_time = 0

---Keep track of frame drops in order to decide if we should adjust the timings.
---@type integer
local fps_drops = 0

---Maximum amount of coroutines to execute on a frame iteration that not exceed
---the maximum allowed time. Value is adjusted on each run_threads as needed.
---@type integer
local max_coroutines = 1000

---Amount of time spent running the main loop without the time it takes to
---run the coroutines. (resets at very cycle end)
---@type number
local main_loop_time = 0

function core.step(next_frame_time)
  -- handle events
  local did_keymap = false

  local event_received = false
  for type, a,b,c,d in system.poll_event do
    if type == "textinput" and did_keymap then
      did_keymap = false
    elseif type == "mousemoved" then
      core.try(core.on_event, type, a, b, c, d)
    elseif type == "enteringforeground" then
      -- to break our frame refresh in two if we get entering/entered at the same time.
      -- required to avoid flashing and refresh issues on mobile
      event_received = type
      break
    elseif type == "displaychanged" then
      DEFAULT_FPS = core.window:get_refresh_rate() or DEFAULT_FPS
      if config.auto_fps then config.fps = DEFAULT_FPS end
    elseif type == "scalechanged" then
      update_scale(a)
    else
      local _, res = core.try(core.on_event, type, a, b, c, d)
      did_keymap = res or did_keymap
    end
    event_received = type
  end

  local width, height = core.window:get_size()

  -- update
  local stats_config = config.draw_stats
  local lower_latency = config.lower_input_latency
  local uncapped = stats_config == "uncapped"
  local force = uncapped or lower_latency
  local priority_event = event_received
    and event_received:match("^[tk][e]") -- key event reduce input latency
    or event_received == "mousewheel"    -- scroll event keep smooth
  core.root_view.size.x, core.root_view.size.y = width, height
  if force or priority_event or next_frame_time < system.get_time() then
      core.root_view:update()
  end

  -- Skip drawing if there is time left before next frame, unless, an event is
  -- received or benchmarking. Skipping helps keep FPS near to the value set on
  ---config.fps when core.redraw is set from a coroutine and not by user
  ---interaction. Otherwise, rendering is prioritized on user events and
  ---config.fps not obeyed.
  if
    not uncapped and ((not event_received and not core.redraw) or (
      -- time left before next frame so we can skip
      next_frame_time > system.get_time()
      and
      -- do not skip if low latency enabled
      not lower_latency
    ))
  then
    return false
  end
  core.redraw = false

  -- close unreferenced docs
  for i = #core.docs, 1, -1 do
    local doc = core.docs[i]
    if #core.get_views_referencing_doc(doc) == 0 then
      table.remove(core.docs, i)
      doc:on_close()
      core.collect_garbage = true
      if #core.docs == 0 then
        system.chdir(core.projects[1].path)
      end
    end
  end

  -- update window title
  local current_title = core.get_view_title(core.active_view)
  if current_title ~= nil and current_title ~= core.window_title then
    system.set_window_title(core.window, core.compose_window_title(current_title))
    core.window_title = current_title
  end

  -- draw
  local start_time = system.get_time()
  renderer.begin_frame(core.window)
  core.clip_rect_stack[1] = { 0, 0, width, height }
  renderer.set_clip_rect(table.unpack(core.clip_rect_stack[1]))
  core.root_view:draw()
  renderer.end_frame()

  local frame_time = system.get_time() - start_time
  rendering_speed = math.max(0.001, frame_time)
  local meets_fps = rendering_speed * config.fps < 1

  if meets_fps or fps_drops < 3 then
    -- Calculate max allowed coroutines run time based on rendering speed.
    -- verbose formula: (1s - (rendering_speed * config.fps)) / config.fps
    core.co_max_time = 1 / config.fps - rendering_speed
    core.fps = config.fps

    if meets_fps then
      fps_drops = math.max(fps_drops - 1, 0)
    else
      fps_drops = fps_drops + 1
      core.co_max_time = rendering_speed / 3
      max_coroutines = 1
    end
  else
    -- If fps rendering dropped from config target we set the max time to
    -- to consume a fourth of the time that would be spent rendering.
    -- For example, if fps dropped from 60 to 25 then we use 1/4 of that time
    -- to run coroutines, which leaves us with a total of 18.75fps and a
    -- maximum time for coroutines of 0.013333333333333 per iteration.
    -- verbose formula: (rendering_speed * (fps / 4)) / (fps - (fps / 4))
    core.co_max_time = rendering_speed / 3
    max_coroutines = 1

    -- current frames per second substracting portion given to coroutines
    core.fps = 1 / (rendering_speed + core.co_max_time)

    -- reset cycle end time
    cycle_end_time = 0
  end

  if stats_config then
    table.insert(draw_stats_frames, frame_time)
    table.insert(draw_stats_cotimes, core.co_max_time)
    if system.get_time() - draw_stats_last_time >= 1 then
      draw_stats_fps = #draw_stats_frames
      local sumftime = 0
      local sumctime = 0
      for i, time in ipairs(draw_stats_frames) do
        sumftime = sumftime + time
        sumctime = sumctime + draw_stats_cotimes[i]
      end
      local average = sumftime / draw_stats_fps
      local average_co = sumctime / draw_stats_fps
      draw_stats_avg = tostring(math.floor(
        (average * 1000) * 100 + 0.5) / 100
      ) .. "ms"
      draw_stats_co_max = tostring(math.floor(
        (average_co * 1000) * 100 + 0.5) / 100
      ) .. "ms"
      draw_stats_co_count = 0
      for _, _ in pairs(core.threads) do
        draw_stats_co_count = draw_stats_co_count + 1
      end
      draw_stats_last_time = system.get_time()
      draw_stats_frames = {}
      draw_stats_cotimes = {}
    end
    core.root_view:defer_draw(draw_stats)
  end

  return true
end

---Flag that indicates which coroutines should be ran by run_threads().
---@type "all" | "background"
local run_threads_mode = "all"

local run_threads = coroutine.wrap(function()
  while true do
    -- Wait time until next run_threads iteration
    local minimal_time_to_wake = math.huge
    -- a count on the amount of threads that ran
    local runs = 0
    -- used to re-adjust the minimal_time_to_wake to prioritize recurrent threads
    local run_start = system.get_time()

    for k, thread in pairs(core.threads) do
      -- run thread
      local end_time = 0
      if run_threads_mode == "all" or thread.background then
        if thread.wake < system.get_time() then
          local start_time = system.get_time()
          -- if the avg time of running the thread exceeds cycle_end_time
          -- execute the thread on next run
          if
            thread.avg_time
            and
            start_time + thread.avg_time > cycle_end_time - main_loop_time
          then
              coroutine.yield(thread.avg_time)
              start_time = system.get_time()
          end
          local _, wait = assert(coroutine.resume(thread.cr))
          end_time = system.get_time() - start_time
          runs = runs + 1
          if coroutine.status(thread.cr) == "dead" then
            if type(k) == "number" then
              table.remove(core.threads, k)
            else
              core.threads[k] = nil
            end
            if thread.background then
              core.background_threads = core.background_threads - 1
            end
          else
            -- store coroutine stats
            if not thread.time then
              thread.time = end_time
              thread.calls = 1
              thread.avg_time = end_time
            else
              -- keep numbers small
              thread.time = thread.calls < 1000
                and thread.time + end_time
                or end_time
              thread.calls = thread.calls < 1000 and thread.calls + 1 or 1
              thread.avg_time = thread.calls > 1
                and thread.time / thread.calls
                or thread.avg_time
            end
            -- penalize slow coroutines by setting their wait time to the
            -- same time it took to execute them.
            if not wait or wait < 0 then
              wait = math.max(end_time, 0.002)
            elseif end_time > wait or end_time > core.co_max_time then
              wait = end_time
            end
            thread.wake = system.get_time() + wait
            minimal_time_to_wake = math.min(minimal_time_to_wake, wait)
            if config.log_slow_threads and end_time > core.co_max_time then
              core.log_quiet(
                "Slow co-routine took %fs of max %fs at: \n%s",
                end_time, core.co_max_time, thread.loc
              )
            end
          end
        else
          minimal_time_to_wake =  math.min(
            minimal_time_to_wake, thread.wake - system.get_time()
          )
        end
      end

      -- stop running threads if we're about to hit the end of frame
      local yield_time = system.get_time()
      if yield_time - core.frame_start > core.co_max_time then
        -- set the maximum amount of coroutines to prevent exceeding max_time
        if max_coroutines > 1 then
          max_coroutines = math.max(runs-1, 1)
        end
        coroutine.yield(0)
      elseif runs >= max_coroutines then
        coroutine.yield(
          yield_time - run_start > minimal_time_to_wake
            and 0
            or (minimal_time_to_wake > yield_time
              and minimal_time_to_wake - yield_time
              or minimal_time_to_wake
            )
        )
      end
    end

    -- if we reached here it means it was able to run coroutines without
    -- slow downs so we reset the maximum coroutines to amount it ran
    max_coroutines = math.max(max_coroutines, runs)

    local yield_time = system.get_time() - run_start
    coroutine.yield(
      yield_time > minimal_time_to_wake
        and 0
        or (minimal_time_to_wake > yield_time
          and minimal_time_to_wake - yield_time
          or minimal_time_to_wake
        )
    )
  end
end)

-- Increase garbage collection frequency to make collections smaller
-- in order to improves editor responsiveness.
if LUA_VERSION < 5.4 then
  collectgarbage("setpause", 150)
  collectgarbage("setstepmul", 150)
end

-- Override default collectgarbage function to prevent users from performing
-- a system stalling garbage collection, instead a new forcecollect option
-- can be used.
local collectgarbage_lua = collectgarbage

---This function is a generic interface to the garbage collector.
---It performs different functions according to its first argument, `opt`.
---@param opt? gcoptions | "forcecollect"
---@param ... any
---@return any
function collectgarbage(opt, ...)
  local ret
  if not opt or opt == "collect" then
    ret = collectgarbage_lua("step", 10*1024)
  elseif opt == "forcecollect" then
    ret = collectgarbage_lua("collect")
  else
    ret = collectgarbage_lua(opt, ...)
  end
  return ret
end

function core.run()
  scale = require "plugins.scale"
  local next_step
  local skip_no_focus = 0
  local burst_events = 0
  local has_focus = true
  local next_frame_time = system.get_time() + 1 / config.fps
  while true do
    local now = system.get_time()
    local uncapped = config.draw_stats == "uncapped"
    core.frame_start = now

    -- start a new 1s cycle
    if core.frame_start >= cycle_end_time then
      cycle_end_time = core.frame_start + (core.co_max_time * core.fps)
      main_loop_time = 0
      has_focus = system.window_has_focus(core.window)
    end

    -- run all coroutine tasks
    local time_to_wake = run_threads()
    local threads_end_time = system.get_time() - now
    now = now + threads_end_time

    -- respect coroutines redraw requests
    if has_focus or core.redraw then
      skip_no_focus = core.frame_start + 5
      next_step = nil
    end

    -- set the run mode
    if
      not has_focus
      and skip_no_focus < core.frame_start
      and core.background_threads > 0
    then
      run_threads_mode = "background"
    else
      run_threads_mode = "all"
    end

    if run_threads_mode == "background" then
      -- run background threads, no drawing or events processing
      next_step = nil
      if system.wait_event(time_to_wake) then
        skip_no_focus = now + 5
      end
    else
      -- run all threads, listen events and perform drawing as needed
      local did_redraw = false
      if not next_step or now >= next_step then
        did_redraw = core.step(next_frame_time)
        now = system.get_time()
        next_step = nil
      end
      if core.restart_request or core.quit_request then break end
      if not did_redraw then
        if has_focus or core.background_threads > 0 or skip_no_focus > now then
          if not next_step then -- compute the time until the next blink
            local t = now - core.blink_start
            local h = config.blink_period / 2
            local dt = math.ceil(t / h) * h - t
            local cursor_time_to_wake = dt + 1 / core.fps
            next_step = now + cursor_time_to_wake
          end
          local nframe = next_frame_time - system.get_time()
          nframe = nframe > 0 and nframe or (1/core.fps)
          local b = (
            (config.lower_input_latency or uncapped)
            and
            burst_events > now
          ) and rendering_speed or nframe
          if system.wait_event(math.min(next_step - now, time_to_wake, b)) then
            next_step = nil
            -- burst event processing speed to reduce input lag
            burst_events = now + 3
          end
        else
          system.wait_event()
          -- allow normal rendering for up to 5 seconds after receiving event
          -- to let any animations render smoothly
          skip_no_focus = system.get_time() + 5
          -- perform a step when we're not in focus in case we get an event
          next_step = nil
        end
      else -- if we redrew, then make sure we only draw at most FPS/sec
        local elapsed = now - core.frame_start
        local next_frame = math.max(0, 1 / core.fps - elapsed)
        next_frame_time = now + next_frame
        next_step = next_step or next_frame_time
        system.sleep(math.min(uncapped and 0 or 1, next_frame, time_to_wake))
      end
    end

    -- run the garbage collector on request
    if core.collect_garbage then
      collectgarbage("collect")
      core.collect_garbage = false
    end

    -- Update the loop run time
    main_loop_time = main_loop_time + (
      (system.get_time() - core.frame_start) - threads_end_time
    )
  end
end


function core.blink_reset()
  core.blink_start = system.get_time()
end


function core.request_cursor(value)
  core.cursor_change_req = value
end


function core.on_error(err)
  -- write error to file
  local fp = io.open(USERDIR .. PATHSEP .. "error.txt", "wb")
  fp:write("Error: " .. tostring(err) .. "\n")
  fp:write(debug.traceback("", 4) .. "\n")
  fp:close()
  -- save copy of all unsaved documents
  for _, doc in ipairs(core.docs) do
    if doc:is_dirty() and doc.filename then
      doc:save(doc.filename .. "~")
    end
  end
end


local alerted_deprecations = {}
---Show deprecation notice once per `kind`.
---
---@param kind string
function core.deprecation_log(kind)
  if alerted_deprecations[kind] then return end
  alerted_deprecations[kind] = true
  core.warn("Used deprecated functionality [%s]. Check if your plugins are up to date.", kind)
end


---A pre-processed config.ignore_files entry.
---@class core.ignore_file_rule
---A lua pattern.
---@field pattern string
---Match a full path including path separators, otherwise match filename only.
---@field use_path boolean
---Match directories only.
---@field match_dir boolean

---Gets a list of pre-processed config.ignore_files patterns for usage in
---combination of common.match_ignore_rule()
---@return core.ignore_file_rule[]
function core.get_ignore_file_rules()
  local ipatterns = config.ignore_files
  local compiled = {}
  -- config.ignore_files could be a simple string...
  if type(ipatterns) ~= "table" then ipatterns = {ipatterns} end
  for _, pattern in ipairs(ipatterns) do
    -- we ignore malformed pattern that raise an error
    if pcall(string.match, "a", pattern) then
      table.insert(compiled, {
        use_path = pattern:match("/[^/$]"), -- contains a slash but not at the end
        -- An '/' or '/$' at the end means we want to match a directory.
        match_dir = pattern:match(".+/%$?$"), -- to be used as a boolen value
        pattern = pattern -- get the actual pattern
      })
    end
  end
  return compiled
end


return core
