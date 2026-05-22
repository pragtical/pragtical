local test = require "core.test"
local config = require "core.config"
local settings = require "plugins.settings"
local Button = require "widget.button"
local TextBox = require "widget.textbox"
local Toggle = require "widget.toggle"

local function find_child(view, class)
  local childs = view.childs
  if view.sections then
    childs = view.sections.panes[1].container.childs
  end
  for _, child in ipairs(childs) do
    if child:is(class) then return child end
  end
end

test.describe("settings", function()
  local old_test_settings
  local old_settings_config

  test.before_each(function()
    old_test_settings = config.plugins.test_settings
    old_settings_config = settings.config
    config.plugins.test_settings = {}
    settings.config = {}
    os.remove(USERDIR .. "/user_settings.lua")
  end)

  test.after_each(function()
    config.plugins.test_settings = old_test_settings
    settings.config = old_settings_config
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
end)
