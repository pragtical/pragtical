local test = require "core.test"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local settings = require "plugins.settings"
local Button = require "widget.button"
local TextBox = require "widget.textbox"
local Toggle = require "widget.toggle"
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

  test.before_each(function()
    old_test_settings = config.plugins.test_settings
    old_settings_config = settings.config
    old_settings_plugins = settings.plugins
    old_plugin_sections = settings.plugin_sections
    old_test_settings_module = package.preload["plugins.test_settings"]
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
