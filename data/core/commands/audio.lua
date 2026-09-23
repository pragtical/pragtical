local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local AudioView = require "core.audioview"

command.add(nil, {
  ["audio-player:open"] = function() core.open_audio() end,
  -- An explicit empty path skips the default scan while choosing a directory.
  ["audio-player:open-directory"] = function() core.open_audio("").folder:show_picker() end,
})

command.add(function()
  return core.active_view:is(AudioView) and not core.active_view.child_active
end, {
  ["audio-player:play-pause"] = function() core.active_view:toggle_play() end,
  ["audio-player:stop"] = function() core.active_view:stop() end,
  ["audio-player:next"] = function() core.active_view:advance(1) end,
  ["audio-player:previous"] = function() core.active_view:advance(-1) end,
  ["audio-player:toggle-repeat"] = function() core.active_view.repeat_button:toggle() end,
  ["audio-player:toggle-shuffle"] = function() core.active_view.shuffle_button:toggle() end,
  ["audio-player:toggle-visualization"] = function() core.active_view.visualization_button:toggle() end,
  ["audio-player:seek-forward"] = function() core.active_view:seek_by(10) end,
  ["audio-player:seek-backward"] = function() core.active_view:seek_by(-10) end,
  ["audio-player:select-next"] = function() core.active_view:select_row(1) end,
  ["audio-player:select-previous"] = function() core.active_view:select_row(-1) end,
  ["audio-player:play-selected"] = function() core.active_view:play_selected() end,
})

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
