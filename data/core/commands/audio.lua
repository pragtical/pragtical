local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local AudioView = require "core.audioview"

command.add(nil, {
  ["audio-player:open"] = function()
    core.open_audio()
  end,
  -- An explicit empty path skips the default scan while choosing a directory.
  ["audio-player:open-directory"] = function()
    core.open_audio("").folder:show_picker()
  end,
})

command.add(
  function()
    return
      core.active_view:is(AudioView) and not core.active_view.child_active,
      core.active_view
  end,
  {
    ["audio-player:play-pause"] = function(av)
      av:toggle_play()
    end,
    ["audio-player:stop"] = function(av)
      av:stop()
    end,
    ["audio-player:next"] = function(av)
      av:advance(1)
    end,
    ["audio-player:previous"] = function(av)
      av:advance(-1)
    end,
    ["audio-player:toggle-repeat"] = function(av)
      av.repeat_button:toggle()
    end,
    ["audio-player:toggle-shuffle"] = function(av)
      av.shuffle_button:toggle()
    end,
    ["audio-player:toggle-visualization"] = function(av)
      av.visualization_button:toggle()
    end,
    ["audio-player:seek-forward"] = function(av)
      av:seek_by(10)
    end,
    ["audio-player:seek-backward"] = function(av)
      av:seek_by(-10)
    end,
    ["audio-player:select-next"] = function(av)
      av:select_row(1)
    end,
    ["audio-player:select-previous"] = function(av)
      av:select_row(-1)
    end,
    ["audio-player:play-selected"] = function(av)
      av:play_selected()
    end,
  }
)

keymap.add {
  ["space"] = "audio-player:play-pause",
  ["return"] = "audio-player:play-selected",
  ["down"] = "audio-player:select-next",
  ["up"] = "audio-player:select-previous",
  ["left"] = "audio-player:seek-backward",
  ["right"] = "audio-player:seek-forward",
  ["ctrl+right"] = "audio-player:next",
  ["ctrl+left"] = "audio-player:previous",
}
