local core = require "core"
local config = require "core.config"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local LogView = require "core.logview"


local previous_win_mode = "normal"
local previous_win_pos = core.window_size
local restore_title_view = false

local function suggest_directory(text)
  text = common.home_expand(text)
  local basedir = common.dirname(core.root_project().path)
  return common.home_encode_list((basedir and text == basedir .. PATHSEP or text == "") and
    core.recent_projects or common.dir_path_suggest(text, core.root_project().path))
end

local function check_directory_path(path)
    local abs_path = system.absolute_path(path)
    local info = abs_path and system.get_file_info(abs_path)
    if not info or info.type ~= 'dir' then
      return nil
    end
    return abs_path
end

local function open_file(use_dialog, label, selection_callback)
  local view = core.active_view
  local default_text, root_dir, filename = "", core.root_project().path, ""
  if view.doc and view.doc.abs_filename then
    local dirname = common.dirname(view.doc.abs_filename)
    if dirname and common.path_belongs_to(dirname, root_dir) then
      dirname = core.normalize_to_project_dir(dirname)
      default_text = dirname == root_dir and "" or common.home_encode(dirname) .. PATHSEP
    elseif dirname then
      root_dir = dirname
    end
  end

  if use_dialog then
    core.open_file_dialog(core.window, function(status, result)
      if status == "accept" then
      	for _, filename in ipairs(result --[[ @as string[] ]]) do
          if not selection_callback then
            core.open_file(filename)
          else
            selection_callback(filename)
          end
      	end
      elseif status == "error" then
        core.error("Error while opening dialog: %s", result or "")
      end
    end, {
      default_location = default_text,
      allow_many = true,
    })
  	return
  end

  core.command_view:enter(label or "Open File", {
    text = default_text,
    submit = function(text)
      if not selection_callback then
        core.open_file(filename)
      else
        selection_callback(filename)
      end
    end,
    suggest = function(text)
      return common.home_encode_list(
        common.path_suggest(common.home_expand(text), root_dir)
      )
    end,
    validate = function(text)
      filename = root_dir == core.root_project().path and
        core.root_project():absolute_path(
          common.home_expand(text)
        ) or system.absolute_path(
          common.home_expand(root_dir .. PATHSEP .. text)
        ) or system.absolute_path(
          common.home_expand(text)
        ) or filename
      local path_stat, err = system.get_file_info(filename)
      if err then
        if filename ~= "" and err:find("No such file", 1, true) then
          -- check if the containing directory exists
          local dirname = common.dirname(filename)
          local dir_stat = dirname and system.get_file_info(dirname)
          if not dirname or (dir_stat and dir_stat.type == 'dir') then
            return true
          end
        end
        core.error("Cannot open file %s: %s", text, err)
      elseif --[[@cast path_stat -nil]] path_stat.type == 'dir' then
        -- TODO: remove the above cast once https://github.com/LuaLS/lua-language-server/discussions/3102 is implemented.
        core.error("Cannot open %s, is a folder", text)
      else
        return true
      end
    end,
  })
end

local function open_directory(label, use_dialog, allow_many, callback)
  local dirname = common.dirname(core.root_project().path)
  local text
  if dirname then
    text = use_dialog and dirname or common.home_encode(dirname) .. PATHSEP
  end

  if use_dialog then
    core.open_directory_dialog(core.window, function(status, result)
      if status == "accept" then
        callback(result)
      elseif status == "error" then
        core.error("Error while opening dialog: %s", result or "")
      end
    end, {
      default_location = text,
      allow_many = allow_many,
      title = label,
    })
  	return
  end

  core.command_view:enter(label, {
    text = text,
    submit = function(text)
      local path = common.home_expand(text)
      local abs_path = check_directory_path(path)
      if not abs_path then
        core.error("Cannot open directory %q", path)
        return
      end
      callback({abs_path})
    end,
    suggest = suggest_directory
  })
end

local function change_project_directory(use_dialog)
  open_directory("Change Project Folder", use_dialog, false, function(abs_path)
    if abs_path[1] == core.root_project().path then return end
    core.confirm_close_docs(core.docs, function(dirpath)
      core.open_project(dirpath)
    end, abs_path[1])
  end)
end

local function open_project_directory(use_dialog)
  open_directory("Open Project", use_dialog, false, function(abs_path)
    if abs_path[1] == core.root_project().path then
      core.error("Directory %q is currently opened", abs_path[1])
      return
    end
    system.exec(string.format("%q %q", EXEFILE, abs_path[1]))
  end)
end

local function add_project_directory(use_dialog)
  open_directory("Add Directory", use_dialog, true, function(abs_path)
    for _, dir in ipairs(abs_path) do
      core.add_project(system.absolute_path(dir))
    end
  end)
end

command.add(nil, {
  ["core:quit"] = function()
    core.quit()
  end,

  ["core:restart"] = function()
    core.restart()
  end,

  ["core:force-quit"] = function()
    core.quit(true)
  end,

  ["core:toggle-tabs"] = function()
    config.hide_tabs = not config.hide_tabs
  end,

  ["core:toggle-line-numbers"] = function()
    config.show_line_numbers = not config.show_line_numbers
  end,

  ["core:toggle-fullscreen"] = function()
    local current_mode = system.get_window_mode(core.window)
    local fullscreen = current_mode == "fullscreen"
    if current_mode ~= "fullscreen" then
      previous_win_mode = current_mode
      if current_mode == "normal" then
        previous_win_pos = table.pack(system.get_window_size(core.window))
      end
    end
    if not fullscreen then
      restore_title_view = core.title_view.visible
    end
    system.set_window_mode(core.window, fullscreen and previous_win_mode or "fullscreen")
    core.show_title_bar(fullscreen and restore_title_view)
    core.title_view:configure_hit_test(fullscreen and restore_title_view)
    if fullscreen and previous_win_mode == "normal" then
      system.set_window_size(core.window, table.unpack(previous_win_pos))
    end
  end,

  ["core:reload-module"] = function()
    core.command_view:enter("Reload Module", {
      submit = function(text, item)
        text = item and item.text or text
        core.reload_module(text)
        core.log("Reloaded module %q", text)
      end,
      suggest = function(text)
        local items = {}
        for name in pairs(package.loaded) do
          table.insert(items, name)
        end
        return common.fuzzy_match(items, text)
      end
    })
  end,

  ["core:find-command"] = function()
    local commands = command.get_all_valid()
    core.command_view:enter("Do Command", {
      submit = function(text, item)
        if item then
          command.perform(item.command)
        end
      end,
      suggest = function(text)
        local res = {}
        local matched = common.fuzzy_match(commands, text)
        for i, name in ipairs(matched) do
          res[i] = {
            text = command.prettify_name(name),
            info = keymap.get_binding(name),
            command = name,
          }
        end
        return res
      end
    })
  end,

  ["core:new-doc"] = function()
    core.root_view:open_doc(core.open_doc())
  end,

  ["core:new-named-doc"] = function()
    core.command_view:enter("File name", {
      submit = function(text)
        core.root_view:open_doc(core.open_doc(text))
      end
    })
  end,

  ["core:open-file"] = function(label, selection_callback)
    open_file(config.use_system_file_picker, label, selection_callback)
  end,

  ["core:open-file-picker"] = function()
    open_file(true)
  end,

  ["core:open-file-commandview"] = function()
    open_file(false)
  end,

  ["core:open-log"] = function()
    local node = core.root_view:get_active_node_default()
    node:add_view(LogView())
  end,

  ["core:open-user-module"] = function()
    local user_module_doc = core.open_doc(USERDIR .. "/init.lua")
    if not user_module_doc then return end
    core.root_view:open_doc(user_module_doc)
  end,

  ["core:open-project-module"] = function()
    if not system.get_file_info(".pragtical_project.lua") then
      core.try(core.write_init_project_module, ".pragtical_project.lua")
    end
    local doc = core.open_doc(".pragtical_project.lua")
    core.root_view:open_doc(doc)
  end,

  ["core:change-project-folder"] = function()
    change_project_directory(config.use_system_file_picker)
  end,

  ["core:change-project-folder-picker"] = function()
    change_project_directory(true)
  end,

  ["core:change-project-folder-commandview"] = function()
    change_project_directory(false)
  end,

  ["core:open-project-folder"] = function()
    open_project_directory(config.use_system_file_picker)
  end,

  ["core:open-project-folder-picker"] = function()
    open_project_directory(true)
  end,

  ["core:open-project-folder-commandview"] = function()
    open_project_directory(false)
  end,

  ["core:add-directory"] = function()
    add_project_directory(config.use_system_file_picker)
  end,

  ["core:add-directory-picker"] = function()
    add_project_directory(true)
  end,

  ["core:add-directory-commandview"] = function()
    add_project_directory(false)
  end,

  ["core:remove-directory"] = function()
    local dir_list = {}
    local n = #core.projects
    for i = n, 2, -1 do
      dir_list[n - i + 1] = core.projects[i].name
    end
    core.command_view:enter("Remove Directory", {
      submit = function(text, item)
        text = common.home_expand(item and item.text or text)
        if not core.remove_project(text) then
          core.error("No directory %q to be removed", text)
        end
      end,
      suggest = function(text)
        text = common.home_expand(text)
        return common.home_encode_list(common.dir_list_suggest(text, dir_list))
      end
    })
  end,
})
