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
})
