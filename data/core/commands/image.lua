local config = require "core.config"
local command = require "core.command"
local ImageView = require "core.imageview"

command.add(ImageView, {
  ["image-view:auto-fit"] = function(av)
    ---@cast av core.imageview
    av.zoom_mode = "fit"
  end,
  ["image-view:zoom-out"] = function(av)
    ---@cast av core.imageview
    av:zoom_out()
  end,
  ["image-view:zoom-in"] = function(av)
    ---@cast av core.imageview
    av:zoom_in()
  end,
  ["image-view:zoom-reset"] = function(av)
    ---@cast av core.imageview
    av:zoom_reset()
  end,
  ["image-view:background-mode-solid"] = function()
    config.images_background_mode = "solid"
  end,
  ["image-view:background-mode-grid"] = function()
    config.images_background_mode = "grid"
  end,
  ["image-view:background-mode-none"] = function()
    config.images_background_mode = "none"
  end,
})
