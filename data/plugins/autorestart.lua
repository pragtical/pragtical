-- mod-version:3
local core = require "core"
local config = require "core.config"
local command = require "core.command"
local style = require "core.style"
local Doc = require "core.doc"
local common = require "core.common"

---Configuration options for `autorestart` plugin.
---@class config.plugins.autorestart
---The type of reload to perform.
---@field reload_type "ask" | "reload" | "restart"
config.plugins.autorestart = common.merge({
  reload_type = "ask",
  config_spec = {
    name = "Autorestart",
    {
      label = "Reload Type",
      description = "How to apply the changes to user and project modules.",
      path = "reload_type",
      type = "selection",
      default = "ask",
      values = {
        { "Ask", "ask" },
        { "Reload", "reload" },
        { "Restart", "restart" }
      }
    }
  }
}, config.plugins.autorestart)

local save = Doc.save
Doc.save = function(self, ...)
  local res = save(self, ...)
  local user = USERDIR .. PATHSEP .. "init.lua"
  local project = core.root_project().path .. PATHSEP .. ".pragtical_project.lua"
  if self.abs_filename == user or self.abs_filename == project then
    if config.plugins.autorestart.reload_type == "restart" then
      command.perform("core:restart")
    elseif config.plugins.autorestart.reload_type == "reload" then
      core.reload_absolute_module(self.abs_filename)
    elseif config.plugins.autorestart.reload_type == "ask" then
      local title = self.abs_filename == project
        and "Project Configuration Changed"
        or "User Configuration Changed"
      core.add_thread(function()
        core.nag_view:show(
          title,
          "How would you like to apply the changes?",
          {
            { font = style.font, text = "Restart", default_yes = true },
            { font = style.font, text = "Reload",                 },
            { font = style.font, text = "Ignore"                  }
          },
          function(item)
            if item.text == "Restart" then
              command.perform("core:restart")
            elseif item.text == "Reload" then
              core.reload_absolute_module(self.abs_filename)
            end
          end
        )
      end)
    end
  end
  return res
end
