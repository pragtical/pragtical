local test = require "core.test"
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local settings = require "plugins.settings"
local Button = require "widget.button"
local Label = require "widget.label"
local SelectBox = require "widget.selectbox"
local TextBox = require "widget.textbox"
local Toggle = require "widget.toggle"
local WidgetList = require "widget.widgetlist"
local SettingsView = getmetatable(settings.ui)

local function find_child(view, class)
  local childs = view.childs
  if view.sections then
    childs = view.sections.panes[1].container.childs
  end
  for _, child in ipairs(childs) do
    if child:is(class) then return child end
  end
end

test.describe("settings renderer preference", function()
  local option
  for _, candidate in ipairs(settings.core.Graphics) do
    if candidate.path == "renderer" then option = candidate end
  end

  test.before_each(function(context)
    context.userdir = USERDIR
    context.renderer = config.renderer
    context.settings_config = settings.config
    context.open, context.remove = io.open, os.remove
    context.error = core.error
    context.backend = core.window:get_renderer_info().backend
    USERDIR = USERDIR .. PATHSEP .. "renderer-settings-" .. system.get_process_id()
    test.ok(common.mkdirp(USERDIR))
    settings.config = {}
    config.renderer = "default"
    core.error = function(fmt, ...)
      context.error_message = string.format(fmt, ...)
    end
  end)

  test.after_each(function(context)
    io.open, os.remove = context.open, context.remove
    core.error = context.error
    local temp = USERDIR
    USERDIR = context.userdir
    config.renderer = context.renderer
    settings.config = context.settings_config
    test.ok(common.rm(temp, true))
    test.equal(core.window:get_renderer_info().backend, context.backend)
  end)

  local function control()
    return find_child(settings.show_config("Renderer Settings", {option}), SelectBox)
  end

  local function read_preference()
    local file = assert(io.open(USERDIR .. PATHSEP .. "renderer", "r"))
    local value = file:read("*a")
    file:close()
    return value
  end

  test.it("persists each backend and removes the preference for Default", function()
    local select = control()
    test.equal(select:get_selected_data(), "default")
    test.equal(system.get_file_info(USERDIR .. PATHSEP .. "renderer"), nil)
    for idx, backend in ipairs({"surface", "sdlgpu", "sdlrenderer", "surface"}) do
      select:set_selected(idx == 4 and 2 or idx + 1)
      test.equal(read_preference(), backend .. "\n")
      test.equal(config.renderer, backend)
      test.equal(dofile(USERDIR .. "/user_settings.lua").config.renderer, backend)
    end
    select:set_selected(1)
    test.equal(config.renderer, "default")
    test.equal(system.get_file_info(USERDIR .. PATHSEP .. "renderer"), nil)
    select:set_selected(1)
    test.equal(config.renderer, "default")
  end)

  test.it("reads the file instead of the mirrored config or active backend", function()
    local file = assert(io.open(USERDIR .. PATHSEP .. "renderer", "w"))
    file:write("  sdlgpu\n")
    file:close()
    config.renderer = "surface"
    test.equal(control():get_selected_data(), "sdlgpu")
    test.equal(read_preference(), "  sdlgpu\n")
  end)

  test.it("shows Default for missing or invalid preferences without rewriting them", function()
    test.equal(option.get_value(), "default")
    local file = assert(io.open(USERDIR .. PATHSEP .. "renderer", "w"))
    file:write("unknown\n")
    file:close()
    test.equal(control():get_selected_data(), "default")
    test.equal(read_preference(), "unknown\n")
  end)

  for _, failure in ipairs({"open", "write", "close", "remove"}) do
    test.it("reports " .. failure .. " failure without updating the setting", function(context)
      local select = control()
      select:set_selected(2)
      local path = USERDIR .. PATHSEP .. "renderer"
      if failure == "open" then
        io.open = function(name, mode)
          if name == path and mode == "w" then return nil, "test failure" end
          return context.open(name, mode)
        end
      elseif failure == "write" or failure == "close" then
        io.open = function(name, mode)
          if name == path and mode == "w" then
            local file = assert(context.open(name, mode))
            return {
              write = function(_, value)
                if failure == "write" then return nil, "test failure" end
                return file:write(value)
              end,
              close = function()
                file:close()
                if failure == "close" then return nil, "test failure" end
                return true
              end
            }
          end
          return context.open(name, mode)
        end
      else
        os.remove = function(name)
          if name == path then return nil, "test failure", 13 end
          return context.remove(name)
        end
      end
      select:set_selected(failure == "remove" and 1 or 3)
      test.equal(select:get_selected_data(), "surface")
      test.equal(config.renderer, "surface")
      test.equal(settings.config.renderer, "surface")
      if failure == "open" or failure == "remove" then
        test.equal(read_preference(), "surface\n")
      end
      test.contains(context.error_message, "test failure")
    end)
  end
end)

local function get_keymap_dialog()
  for index = 1, math.huge do
    local name, value = debug.getupvalue(SettingsView.load_keymap_settings, index)
    if not name then break end
    if name == "keymap_dialog" then
      return value
    end
  end
end

test.describe("settings", function()
  local old_test_settings
  local old_settings_config
  local old_settings_plugins
  local old_plugin_sections
  local old_test_settings_module
  local old_disabled_transitions

  test.before_each(function()
    old_test_settings = config.plugins.test_settings
    old_settings_config = settings.config
    old_settings_plugins = settings.plugins
    old_plugin_sections = settings.plugin_sections
    old_test_settings_module = package.preload["plugins.test_settings"]
    old_disabled_transitions = config.disabled_transitions
    config.plugins.test_settings = {}
    settings.config = {}
    settings.plugins = {}
    settings.plugin_sections = {}
    os.remove(USERDIR .. "/user_settings.lua")
  end)

  test.after_each(function()
    config.plugins.test_settings = old_test_settings
    settings.config = old_settings_config
    settings.plugins = old_settings_plugins
    settings.plugin_sections = old_plugin_sections
    package.preload["plugins.test_settings"] = old_test_settings_module
    config.disabled_transitions = old_disabled_transitions
    os.remove(USERDIR .. "/user_settings.lua")
  end)

  test.it("shows standalone config views and persists prefixed values", function()
    local applied
    local view = settings.show_config("Generated Settings", {
      name = "Generated",
      path_prefix = "plugins.test_settings",
      {
        label = "Model",
        path = "model",
        type = settings.type.STRING,
        default = "default",
        get_value = function(value)
          return value .. "-view"
        end,
        set_value = function(value)
          return value .. "-saved"
        end,
        on_apply = function(value)
          applied = value
        end
      }
    })

    test.equal(view.sections, nil)

    local textbox = find_child(view, TextBox)
    test.not_nil(textbox)
    test.equal(textbox:get_text(), "default-view")

    textbox:on_change("custom")

    test.equal(config.plugins.test_settings.model, "custom-saved")
    test.equal(settings.config.plugins.test_settings.model, "custom-saved")
    test.equal(applied, "custom-saved")

    local saved = dofile(USERDIR .. "/user_settings.lua")
    test.equal(saved.config.plugins.test_settings.model, "custom-saved")
  end)

  test.it("shows standalone config views with named sections", function()
    local view = settings.show_config("Sectioned Settings", {
      path_prefix = "plugins.test_settings",
      sections = {
        General = {
          {
            label = "Enabled",
            path = "enabled",
            type = settings.type.TOGGLE,
            default = false
          }
        }
      }
    })

    test.not_nil(view.sections)

    local toggle = find_child(view, Toggle)
    test.not_nil(toggle)
    toggle:on_change(true)

    test.equal(config.plugins.test_settings.enabled, true)
    test.equal(settings.config.plugins.test_settings.enabled, true)
  end)

  test.it("persists values from filterable custom widget lists", function()
    config.plugins.test_settings.languages = {}
    local view = settings.show_config("Language Settings", {
      path_prefix = "plugins.test_settings",
      {
        label = "Languages",
        path = "languages",
        type = settings.type.LIST_WIDGETS,
        default = {},
        visible_rows = 2,
        items = {
          { name = "Lua" },
          { name = "Python" }
        },
        item_text = function(item)
          return item.name
        end,
        build_item = function(row, item, value, commit)
          local label = Label(row, item.name)
          row:set_child_properties(label, { stretch = 1 })

          local toggle = Toggle(row, "", value[item.name] == true)
          function toggle:on_change(enabled)
            value[item.name] = enabled and true or nil
            commit(value)
          end

          Button(row, "Action")
        end
      }
    })

    local list = find_child(view, WidgetList)
    test.not_nil(list)
    test.equal(#list.items, 2)

    local lua_toggle
    local found_button = false
    for _, child in ipairs(list.items[1].row.childs) do
      if child:is(Toggle) then lua_toggle = child end
      if child:is(Button) then found_button = true end
    end
    test.not_nil(lua_toggle)
    test.ok(found_button)

    lua_toggle:on_change(true)
    test.equal(config.plugins.test_settings.languages.Lua, true)
    test.equal(settings.config.plugins.test_settings.languages.Lua, true)

    list.scroll.y = 10
    list.scroll.to.y = 10
    list:filter("Python")
    list:relayout()
    test.equal(list.scroll.y, 0)
    test.equal(list.scroll.to.y, 0)
    test.equal(list.items[1].matched, false)
    test.equal(list.items[2].matched, true)

    local saved = dofile(USERDIR .. "/user_settings.lua")
    test.equal(saved.config.plugins.test_settings.languages.Lua, true)
  end)

  test.it("groups disabled transitions in a widget list", function()
    local option
    for _, candidate in ipairs(settings.core.Graphics) do
      if candidate.path == "disabled_transitions" then
        option = candidate
        break
      end
    end

    test.not_nil(option)
    test.equal(option.type, settings.type.LIST_WIDGETS)
    test.equal(option.filterable, false)
    test.equal(option.visible_rows, 8)
    test.equal(#option.items, 8)

    config.disabled_transitions = {
      scroll = false,
      commandview = true,
      contextmenu = false,
      logview = false,
      nagbar = false,
      tabs = false,
      tab_drag = false,
      statusbar = false
    }
    local view = settings.show_config("Transition Settings", { option })
    local list = find_child(view, WidgetList)
    test.not_nil(list)
    test.equal(#list.items, 8)

    local scroll_toggle
    for _, entry in ipairs(list.items) do
      if entry.data.key == "scroll" then
        for _, child in ipairs(entry.row.childs) do
          if child:is(Toggle) then
            scroll_toggle = child
            break
          end
        end
      end
    end
    test.not_nil(scroll_toggle)
    scroll_toggle:on_change(true)

    test.equal(config.disabled_transitions.scroll, true)
    test.equal(config.disabled_transitions.commandview, true)
    test.equal(settings.config.disabled_transitions.scroll, true)

    local saved = dofile(USERDIR .. "/user_settings.lua")
    test.equal(saved.config.disabled_transitions.scroll, true)
    test.equal(saved.config.disabled_transitions.commandview, true)
  end)

  test.it("opens sub config views from settings options", function()
    local old_show_config = settings.show_config
    local opened_title
    local opened_view

    settings.show_config = function(title, spec, context)
      opened_title = title
      opened_view = old_show_config(title, spec, context)
      return opened_view
    end

    local view = old_show_config("Parent Settings", {
      path_prefix = "plugins.test_settings",
      {
        label = "Open Preferences",
        title = "Project Preferences",
        type = settings.type.SUBCONFIG,
        spec = {
          path_prefix = "plugins.test_settings.project",
          {
            label = "Project Name",
            path = "name",
            type = settings.type.STRING,
            default = "Demo"
          }
        }
      }
    })

    local button = find_child(view, Button)
    test.not_nil(button)
    test.equal(button.label, "Open Preferences")
    test.equal(button.icon.code, "P")

    button:on_click()
    settings.show_config = old_show_config

    test.equal(opened_title, "Project Preferences")
    test.not_nil(opened_view)

    local textbox = find_child(opened_view, TextBox)
    test.not_nil(textbox)
    test.equal(textbox:get_text(), "Demo")

    textbox:on_change("Website")

    test.equal(config.plugins.test_settings.project.name, "Website")
    test.equal(settings.config.plugins.test_settings.project.name, "Website")

    local saved = dofile(USERDIR .. "/user_settings.lua")
    test.equal(saved.config.plugins.test_settings.project.name, "Website")
  end)

  test.it("resolves sub config prefixes relative to plugin context", function()
    local old_show_config = settings.show_config
    local opened_view

    settings.show_config = function(title, spec, context)
      opened_view = old_show_config(title, spec, context)
      return opened_view
    end

    local view = old_show_config("Parent Settings", {
      {
        label = "Open Preferences",
        title = "Project Preferences",
        type = settings.type.SUBCONFIG,
        spec = {
          path_prefix = "project",
          {
            label = "Project Name",
            path = "name",
            type = settings.type.STRING,
            default = "Demo"
          }
        }
      }
    }, "test_settings")

    local button = find_child(view, Button)
    test.not_nil(button)
    button:on_click()
    settings.show_config = old_show_config

    local textbox = find_child(opened_view, TextBox)
    test.not_nil(textbox)
    textbox:on_change("Website")

    test.equal(config.plugins.test_settings.project.name, "Website")
    test.equal(settings.config.plugins.test_settings.project.name, "Website")
    test.equal(config.project, nil)

    local saved = dofile(USERDIR .. "/user_settings.lua")
    test.equal(saved.config.plugins.test_settings.project.name, "Website")
  end)

  test.it("inherits plugin paths for sub config views without a prefix", function()
    local old_show_config = settings.show_config
    local opened_view

    settings.show_config = function(title, spec, context)
      opened_view = old_show_config(title, spec, context)
      return opened_view
    end

    local view = old_show_config("Parent Settings", {
      {
        label = "Open Preferences",
        title = "Project Preferences",
        type = settings.type.SUBCONFIG,
        spec = {
          {
            label = "Project Name",
            path = "name",
            type = settings.type.STRING,
            default = "Demo"
          }
        }
      }
    }, "test_settings")

    local button = find_child(view, Button)
    test.not_nil(button)
    button:on_click()
    settings.show_config = old_show_config

    local textbox = find_child(opened_view, TextBox)
    test.not_nil(textbox)
    test.equal(textbox:get_text(), "Demo")

    textbox:on_change("Website")

    test.equal(config.plugins.test_settings.name, "Website")
    test.equal(settings.config.plugins.test_settings.name, "Website")
    test.equal(config.name, nil)
  end)

  test.it("resolves sub config prefixes relative to parent prefixes", function()
    local old_show_config = settings.show_config
    local opened_view

    settings.show_config = function(title, spec, context)
      opened_view = old_show_config(title, spec, context)
      return opened_view
    end

    local view = old_show_config("Parent Settings", {
      path_prefix = "plugins.test_settings",
      {
        label = "Open Preferences",
        title = "Project Preferences",
        type = settings.type.SUBCONFIG,
        spec = {
          path_prefix = "project",
          {
            label = "Project Name",
            path = "name",
            type = settings.type.STRING,
            default = "Demo"
          }
        }
      }
    })

    local button = find_child(view, Button)
    test.not_nil(button)
    button:on_click()
    settings.show_config = old_show_config

    local textbox = find_child(opened_view, TextBox)
    test.not_nil(textbox)
    textbox:on_change("Website")

    test.equal(config.plugins.test_settings.project.name, "Website")
    test.equal(settings.config.plugins.test_settings.project.name, "Website")
    test.equal(config.project, nil)

    local saved = dofile(USERDIR .. "/user_settings.lua")
    test.equal(saved.config.plugins.test_settings.project.name, "Website")
    test.equal(saved.config.project, nil)
  end)

  test.it("loads runtime sub config values into generated views", function()
    local old_show_config = settings.show_config
    local opened_view

    config.plugins.test_settings = {
      project = {
        name = "Website"
      }
    }

    settings.show_config = function(title, spec, context)
      opened_view = old_show_config(title, spec, context)
      return opened_view
    end

    local view = old_show_config("Parent Settings", {
      path_prefix = "plugins.test_settings",
      {
        label = "Open Preferences",
        title = "Project Preferences",
        type = settings.type.SUBCONFIG,
        spec = {
          path_prefix = "project",
          {
            label = "Project Name",
            path = "name",
            type = settings.type.STRING,
            default = "Demo"
          }
        }
      }
    })

    local button = find_child(view, Button)
    test.not_nil(button)
    button:on_click()
    settings.show_config = old_show_config

    local textbox = find_child(opened_view, TextBox)
    test.not_nil(textbox)
    test.equal(textbox:get_text(), "Website")
  end)

  test.it("merges saved plugin sub config values into global config", function()
    package.preload["plugins.test_settings"] = function()
      config.plugins.test_settings.config_spec = {
        name = "Test Settings",
        {
          label = "Open Preferences",
          title = "Project Preferences",
          type = settings.type.SUBCONFIG,
          spec = {
            path_prefix = "project",
            sections = {
              General = {
                {
                  label = "Project Name",
                  path = "name",
                  type = settings.type.STRING,
                  default = "Demo"
                }
              }
            }
          }
        }
      }
      return true
    end

    settings.config = {
      plugins = {
        test_settings = {
          project = {
            name = "Website"
          }
        }
      }
    }

    SettingsView.enable_plugin(settings.ui, "test_settings")

    test.equal(config.plugins.test_settings.project.name, "Website")
  end)

  test.it("resets custom keybindings for commands without default bindings", function()
    local command_name = "test-settings:no-default-binding"
    local binding = "ctrl+shift+f12"
    local old_command = command.map[command_name]
    local old_defaults = settings.default_keybindings[command_name]
    local old_bindings = { keymap.get_binding(command_name) }

    command.add(nil, {
      [command_name] = function() end
    })
    settings.default_keybindings[command_name] = nil
    settings.config.custom_keybindings = {
      [command_name] = { binding }
    }
    keymap.add({ [binding] = command_name })

    local keymap_dialog = get_keymap_dialog()
    test.not_nil(keymap_dialog)
    keymap_dialog.command = command_name
    keymap_dialog.row_id = 1
    keymap_dialog.listbox = {
      row = nil,
      set_row = function(self, idx, row)
        self.row = row
      end
    }

    keymap_dialog:on_reset()

    test.same({ keymap.get_binding(command_name) }, {})
    test.equal(settings.config.custom_keybindings[command_name], nil)
    test.not_nil(keymap_dialog.listbox.row)

    keymap.unbind(binding, command_name)
    for _, old_binding in ipairs(old_bindings) do
      keymap.add({ [old_binding] = command_name })
    end
    command.map[command_name] = old_command
    settings.default_keybindings[command_name] = old_defaults
  end)

end)
