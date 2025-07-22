local core = require "core"
local config = require "core.config"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local LogView = require "core.logview"


local previous_win_mode = "normal"
local previous_win_pos = table.pack(system.get_window_size(core.window))
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
        local text = item and item.text or text
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
        local res = common.fuzzy_match(commands, text)
        for i, name in ipairs(res) do
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

  ["core:open-file"] = function()
    local view = core.active_view
    local text, root_dir, filename = "", core.root_project().path, ""
    if view.doc and view.doc.abs_filename then
      local dirname = common.dirname(view.doc.abs_filename)
      if dirname and common.path_belongs_to(dirname, root_dir) then
        local dirname = core.normalize_to_project_dir(dirname)
        text = dirname == root_dir and "" or common.home_encode(dirname) .. PATHSEP
      elseif dirname then
        root_dir = dirname
      end
    end
    core.command_view:enter("Open File", {
      text = text,
      submit = function(text)
        core.root_view:open_doc(core.open_doc(filename))
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
        elseif path_stat.type == 'dir' then
          core.error("Cannot open %s, is a folder", text)
        else
          return true
        end
      end,
    })
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
    doc:save()
  end,

  ["core:change-project-folder"] = function()
    local dirname = common.dirname(core.root_project().path)
    local text
    if dirname then
      text = common.home_encode(dirname) .. PATHSEP
    end
    core.command_view:enter("Change Project Folder", {
      text = text,
      submit = function(text)
        local path = common.home_expand(text)
        local abs_path = check_directory_path(path)
        if not abs_path then
          core.error("Cannot open directory %q", path)
          return
        end
        if abs_path == core.root_project().path then return end
        core.confirm_close_docs(core.docs, function(dirpath)
          core.open_project(dirpath)
        end, abs_path)
      end,
      suggest = suggest_directory
    })
  end,

  ["core:open-project-folder"] = function()
    local dirname = common.dirname(core.root_project().path)
    local text
    if dirname then
      text = common.home_encode(dirname) .. PATHSEP
    end
    core.command_view:enter("Open Project", {
      text = text,
      submit = function(text)
        local path = common.home_expand(text)
        local abs_path = check_directory_path(path)
        if not abs_path then
          core.error("Cannot open directory %q", path)
          return
        end
        if abs_path == core.root_project().path then
          core.error("Directory %q is currently opened", abs_path)
          return
        end
        system.exec(string.format("%q %q", EXEFILE, abs_path))
      end,
      suggest = suggest_directory
    })
  end,

  ["core:add-directory"] = function()
    core.command_view:enter("Add Directory", {
      submit = function(text)
        text = common.home_expand(text)
        local path_stat, err = system.get_file_info(text)
        if not path_stat then
          core.error("cannot open %q: %s", text, err)
          return
        elseif path_stat.type ~= 'dir' then
          core.error("%q is not a directory", text)
          return
        end
        core.add_project(system.absolute_path(text))
      end,
      suggest = suggest_directory
    })
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
