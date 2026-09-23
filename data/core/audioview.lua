local audio = require "audio"
local system = require "system"
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local Widget = require "widget"
local Button = require "widget.button"
local ToggleButton = require "widget.togglebutton"
local FilePicker = require "widget.filepicker"
local ListBox = require "widget.listbox"
local TextBox = require "widget.textbox"

local formats = {
  WAV = "wav wave", AIFF = "aif aiff aifc", FLAC = "flac oga ogg",
  MP3 = "mp3 mp2", VORBIS = "ogg oga", OPUS = "opus ogg oga",
  WAVPACK = "wv", XMP = "mod xm it s3m", MOD = "mod xm it s3m",
  TIMIDITY = "mid midi kar", FLUIDSYNTH = "mid midi kar",
  GME = "ay gbs gym hes kss nsf nsfe sap spc vgm vgz", VOC = "voc",
}
formats.DRFLAC, formats.DRMP3 = formats.FLAC, formats.MP3
formats.MPG123, formats.STBVORBIS = formats.MP3, formats.VORBIS

local candidates, supported = {}, nil
for _, extensions in pairs(formats) do
  for ext in extensions:gmatch("%S+") do candidates[ext] = true end
end

local function get_extensions()
  local decoders, err = audio.get_decoders()
  if not decoders then return nil, err end
  local extensions = {}
  for _, decoder in ipairs(decoders) do
    for ext in (formats[decoder:upper()] or ""):gmatch("%S+") do
      extensions[ext] = true
    end
  end
  return extensions
end

-- Called in a coroutine. Returning false from yield_scan cancels the walk.
-- Do not inspect/decode every candidate file: playback validates its contents.
local function scan_directory(root, extensions, on_track, yield_scan)
  local pending, skipped, count = { root }, 0, 0
  local deadline = system.get_time() + 0.005
  while #pending > 0 do
    local dir = table.remove(pending)
    local names = system.list_dir(dir)
    if not names then skipped = skipped + 1 end
    table.sort(names or {})
    for _, name in ipairs(names or {}) do
      local path = dir .. PATHSEP .. name
      local info = system.get_file_info(path)
      if info and info.type == "dir" and not info.symlink then
        pending[#pending + 1] = path
      elseif info and info.type == "file" then
        local ext = name:match("%.([^%.]+)$")
        if ext and extensions[ext:lower()] then
          on_track({ path = path, name = name, folder = common.relative_path(root, dir),
            format = ext:upper() })
          count = count + 1
        end
      elseif not info then
        skipped = skipped + 1
      end
      if system.get_time() >= deadline then
        if yield_scan() == false then return count, skipped, true end
        deadline = system.get_time() + 0.005
      end
    end
    if yield_scan() == false then return count, skipped, true end
    deadline = system.get_time() + 0.005
  end
  return count, skipped, false
end

local function format_time(seconds)
  if not seconds or seconds == math.huge then return "--:--" end
  seconds = math.max(0, math.floor(seconds))
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- Preserve short peaks when reducing a sample window to screen-sized columns.
local function analyze_samples(samples, channels, columns)
  local frames = math.floor(#samples / channels)
  local result = {}
  for channel = 1, math.min(channels, 2) do
    local bins, peak, sum = {}, 0, 0
    for i = 1, frames do
      local value = samples[(i - 1) * channels + channel]
      if value ~= value or value == math.huge or value == -math.huge then value = 0 end
      local bin = math.min(columns, math.floor((i - 1) * columns / frames) + 1)
      local pair = bins[bin]
      if pair then
        pair[1], pair[2] = math.min(pair[1], value), math.max(pair[2], value)
      else bins[bin] = { math.min(0, value), math.max(0, value) } end
      peak, sum = math.max(peak, math.abs(value)), sum + value * value
    end
    result[channel] = { bins = bins, peak = peak, rms = frames > 0 and math.sqrt(sum / frames) or 0 }
  end
  return result
end

local function column(field, index)
  return function(list, row, x, y, font, color, only_calc)
    local width, height = math.max(0, list.columns[index].width), font:get_height()
    if not only_calc then
      core.push_clip_rect(x, y, width, height)
      renderer.draw_text(font, list.row_data[row][field], x, y, color)
      core.pop_clip_rect()
    end
    return width, height
  end
end

local track_column, folder_column, format_column = column("name", 1), column("folder", 2), column("format", 3)

local shuffle_arrow = {
  { -8, -5 }, { -4, -5 }, { 3, 3 }, { 4, 3 }, { 4, 1 }, { 8, 4 },
  { 4, 7 }, { 4, 5 }, { 2, 5 }, { -5, -3 }, { -8, -3 }
}

local function draw_transport_button(button)
  local active = button.hover_text or button.toggle_hovered or button.enabled
  local color = active and style.accent or style.text
  button.background_color = active and style.line_highlight or style.background
  if not Widget.draw(button) then return false end
  local cx = button.position.x + button.size.x / 2
  local cy = button.position.y + button.size.y / 2
  -- The editor icon font has no pause, stop or shuffle glyphs.
  if button.transport_shape == "pause" then
    renderer.draw_rect(cx - 4 * SCALE, cy - 6 * SCALE, 2 * SCALE, 12 * SCALE, color)
    renderer.draw_rect(cx + 2 * SCALE, cy - 6 * SCALE, 2 * SCALE, 12 * SCALE, color)
  elseif button.transport_shape == "stop" then
    renderer.draw_rect(cx - 4 * SCALE, cy - 4 * SCALE, 8 * SCALE, 8 * SCALE, color)
  elseif button.transport_shape == "shuffle" then
    for _, sign in ipairs({ 1, -1 }) do
      local points = {}
      for i = 1, #shuffle_arrow do
        local p = shuffle_arrow[sign == 1 and i or #shuffle_arrow - i + 1]
        points[i] = { cx + p[1] * SCALE, cy + p[2] * sign * SCALE }
      end
      renderer.draw_poly(points, color)
    end
  elseif button.icon.code then
    local font = style.icon_font
    renderer.draw_text(font, button.icon.code,
      cx - font:get_width(button.icon.code) / 2, cy - font:get_height() / 2, color)
  end
  return true
end

local Slider = Widget:extend()

function Slider:new(parent, tooltip, change)
  Slider.super.new(self, parent)
  self.border.width = 0
  self.value, self.enabled = 0, true
  self:set_tooltip(tooltip)
  self.on_change = change
end

function Slider:set_from_mouse(x)
  self.value = common.clamp((x - self.position.x) / math.max(1, self.size.x), 0, 1)
  self:on_change(self.value)
  core.redraw = true
end

function Slider:on_mouse_pressed(button, x)
  if button ~= "left" or not self.enabled then return false end
  self.dragging = true
  self:capture_mouse()
  self:set_from_mouse(x)
  return true
end

function Slider:on_mouse_moved(x, y, dx, dy)
  if self.dragging then self:set_from_mouse(x)
  else Slider.super.on_mouse_moved(self, x, y, dx, dy) end
end

function Slider:on_mouse_released()
  self.dragging = false
  self:release_mouse()
end

function Slider:draw()
  if not Slider.super.draw(self) then return end
  local x, y, w = self.position.x, self.position.y + self.size.y / 2, self.size.x
  renderer.draw_rect(x, y - SCALE, w, 2 * SCALE, style.line_highlight)
  if self.enabled then
    renderer.draw_rect(x, y - SCALE, w * self.value, 2 * SCALE, style.caret)
    renderer.draw_rect(x + common.clamp(w * self.value - 3 * SCALE, 0, math.max(0, w - 6 * SCALE)),
      y - 5 * SCALE, 6 * SCALE, 10 * SCALE, style.text)
  end
end

---A streaming audio player with a recursive playlist and optional visualization.
---@class core.audioview : widget
---@overload fun():core.audioview
local AudioView = Widget:extend()

function AudioView:__tostring() return "AudioView" end

---Check whether a filename's extension has an available decoder.
---@param path string
---@return boolean supported
---@return string? extension
function AudioView.is_supported(path)
  local ext = path:match("%.([^%./\\]+)$")
  ext = ext and ext:lower()
  -- Ordinary text files should not initialize SDL_mixer or enumerate codecs.
  if not candidates[ext] then return false, ext end
  if not supported then supported = get_extensions() end
  return supported ~= nil and supported[ext] == true, ext
end

function AudioView:new()
  AudioView.super.new(self, nil, false)
  self.name, self.type_name = "Audio Player", "core.audioview"
  self.border.width, self.scrollable = 0, false
  self.tracks, self.generation, self.volume, self.position_seconds = {}, 0, 0.7, 0
  self.tracks_by_path = {}
  self.analysis, self.state, self.scan_skipped = {}, "stopped", 0
  local defaults = config.audio_player
  self.visualization, self.repeat_all, self.shuffle = defaults.visualization, defaults.repeat_all, defaults.shuffle
  self:reset_shuffle()
  self.folder = FilePicker(self)
  self.folder:set_mode(FilePicker.mode.DIRECTORY_EXISTS)
  self.folder:set_tooltip("Music directory", "audio-player:open-directory")
  self.folder.button:set_tooltip("Open music directory", "audio-player:open-directory")
  self.folder.file:set_tooltip("Music directory", "audio-player:open-directory")
  self.folder.on_change = function(_, path) if path then self:scan(path) end end
  self.filter = TextBox(self, "", "Filter tracks...")
  self.filter.on_change = function() self.filter_due = system.get_time() + 0.15 end
  self.list = ListBox(self)
  self.list:add_column("Track", 250, false)
  self.list:add_column("Folder", 200, false)
  self.list:add_column("Format", 80, false)
  self.list.on_row_click = function(_, _, track) self:play(track) end

  local function button(label, icon, tooltip, name, action)
    local b = Button(self, label)
    if icon then b:set_icon(icon) end
    b.draw = draw_transport_button
    b:set_tooltip(tooltip, "audio-player:" .. name)
    b.on_click = function(_, mouse) if mouse == "left" then action() end end
    return b
  end
  self.previous = button("", "<", "Previous track", "previous", function() self:advance(-1) end)
  self.play_button = button("", ">", "Play / pause", "play-pause", function() self:toggle_play() end)
  self.stop_button = button("", nil, "Stop", "stop", function() self:stop() end)
  self.stop_button.transport_shape = "stop"
  self.next = button("", ">", "Next track", "next", function() self:advance(1) end)
  self.repeat_button = ToggleButton(self, self.repeat_all, nil, "s")
  self.repeat_button.draw = draw_transport_button
  self.repeat_button:set_tooltip("Repeat playlist", "audio-player:toggle-repeat")
  self.repeat_button.on_change = function(_, enabled) self.repeat_all = enabled end
  self.shuffle_button = ToggleButton(self, self.shuffle)
  self.shuffle_button.transport_shape = "shuffle"
  self.shuffle_button.draw = draw_transport_button
  self.shuffle_button:set_tooltip("Shuffle playlist", "audio-player:toggle-shuffle")
  self.shuffle_button.on_change = function(_, enabled)
    self.shuffle = enabled
    self:reset_shuffle()
  end
  self.visualization_button = ToggleButton(self, self.visualization, nil, "g")
  self.visualization_button.draw = draw_transport_button
  self.visualization_button:set_tooltip("Show visualization", "audio-player:toggle-visualization")
  self.visualization_button.on_change = function(_, enabled) self:set_visualization(enabled) end
  self.seek = Slider(self, "Seek", function(_, value)
    if self.voice and self.duration then self:seek_to(value * self.duration) end
  end)
  self.volume_slider = Slider(self, "Volume", function(_, value)
    self.volume = value
    if self.mixer then self.mixer:set_gain(value) end
  end)
  self.volume_slider.value = self.volume
  self.controls = {
    self.previous, self.play_button, self.stop_button, self.next,
    self.repeat_button, self.shuffle_button, self.visualization_button
  }

  core.add_thread(function()
    while not self.closed do
      local before = self.state
      self:poll()
      local node = core.root_view.root_node:get_node_for_view(self)
      local visible = node and node.active_view == self
      if visible and (self.state == "playing" or before ~= self.state) then
        if self.visualization and self.state == "playing" then
          local samples, spec = self.mixer:get_samples(2048)
          if samples then self.analysis = analyze_samples(samples, spec.channels, 160) end
        end
        core.redraw = true
      end
      coroutine.yield(visible and self.visualization and self.state == "playing" and 1 / 30 or 0.2)
    end
  end)
end

---Return workspace state without retaining widgets or native audio handles.
---@return table
function AudioView:get_state()
  local tracks = {}
  for i, track in ipairs(self.tracks) do
    tracks[i] = { path = track.path, name = track.name,
      folder = track.folder, format = track.format }
  end
  local selected = self.list.row_data[self.list:get_selected() or 0]
  return {
    tracks = tracks,
    directory = self.folder:get_path(),
    current = self.current and self.current.path,
    selected = selected and selected.path,
    filter = self.filter:get_text(),
    scroll = { x = self.list.scroll.to.x, y = self.list.scroll.to.y },
    position_seconds = self.voice and self.voice:get_position() or self.position_seconds,
    stop_after_track = self.stop_after_track,
    volume = self.volume,
    visualization = self.visualization,
    repeat_all = self.repeat_all,
    shuffle = self.shuffle
  }
end

---Restore a player without scanning directories or starting audio playback.
---@param state table
---@return core.audioview
function AudioView.from_state(state)
  local view = AudioView()
  view.folder:set_path(state.directory)
  view.filter:set_text(state.filter or "")
  view.filter_due = nil
  view.volume = common.clamp(state.volume or view.volume, 0, 1)
  view.volume_slider.value = view.volume
  view.visualization_button:set_toggle(state.visualization == true)
  view.repeat_button:set_toggle(state.repeat_all == true)
  for _, track in ipairs(state.tracks or {}) do
    local info = system.get_file_info(track.path)
    if info and info.type == "file" and AudioView.is_supported(track.path) then
      view:add_track({ path = track.path, name = track.name,
        folder = track.folder, format = track.format })
    end
  end
  view.current = view.tracks_by_path[state.current]
  view.shuffle_button:set_toggle(state.shuffle == true)
  if view.current then
    view.position_seconds = math.max(0, state.position_seconds or 0)
    view.resume_position = view.position_seconds
    view.stop_after_track = state.stop_after_track
  end
  view.list:set_selected(nil)
  for i, track in ipairs(view.list.row_data) do
    if track.path == state.selected then view.list:set_selected(i) break end
  end
  if state.scroll then
    view.list.scroll.x, view.list.scroll.to.x = state.scroll.x, state.scroll.x
    view.list.scroll.y, view.list.scroll.to.y = state.scroll.y, state.scroll.y
  end
  view:show()
  return view
end

function AudioView:report(err)
  self.error = tostring(err)
  core.error("Audio Player: %s", self.error)
  core.redraw = true
end

function AudioView:set_visualization(enabled)
  if self.visualization == enabled then return end
  if self.mixer and self.voice then
    local ok, err = self.mixer:set_sample_buffer(enabled and 2048 or 0)
    if not ok then
      self.visualization_button.enabled = self.visualization
      self:report(err)
      return
    end
  end
  self.visualization, self.visualization_button.enabled = enabled, enabled
  self.analysis = {}
  core.redraw = true
end

function AudioView:add_track(track)
  local existing = self.tracks_by_path[track.path]
  if existing then return existing end
  self.tracks_by_path[track.path] = track
  self.tracks[#self.tracks + 1] = track
  track.index = #self.tracks
  if self.shuffle then self.shuffle_remaining[#self.shuffle_remaining + 1] = track end
  self:add_row(track)
  return track
end

---Play only this file, preserving playback when reopening the current track.
---@param path string
function AudioView:open_file(path)
  local supported, ext = AudioView.is_supported(path)
  if not supported then self:report("Unsupported audio file: " .. path) return end
  local absolute = system.absolute_path(path)
  local info = absolute and system.get_file_info(absolute)
  if not info or info.type ~= "file" then self:report("File not found: " .. path) return end
  local track = self:add_track({ path = absolute, name = common.basename(absolute),
    folder = common.dirname(absolute), format = ext:upper() })
  if self.current ~= track or not self.voice then self:play(track) end
  self.stop_after_track = true
end

function AudioView:reset_shuffle()
  self.shuffle_remaining, self.shuffle_history, self.shuffle_index = {}, {}, 0
  if not self.shuffle then return end
  for _, track in ipairs(self.tracks) do
    if track ~= self.current then
      self.shuffle_remaining[#self.shuffle_remaining + 1] = track
    end
  end
  if self.current then
    self.shuffle_history[1], self.shuffle_index = self.current, 1
  end
end

function AudioView:add_row(track)
  local filter = self.filter:get_text():lower()
  if filter ~= "" and not (track.name .. " " .. track.folder):lower():find(filter, 1, true) then return end
  self.list:add_row({ track_column, ListBox.COLEND, folder_column, ListBox.COLEND, format_column }, track)
  if track == self.current then self.list:set_selected(#self.list.rows) end
end

function AudioView:filter_tracks()
  self.list:clear()
  self.list.scroll.y, self.list.scroll.to.y = 0, 0
  for _, track in ipairs(self.tracks) do self:add_row(track) end
  self.list:set_visible_rows()
end

function AudioView:scan(path)
  local absolute = system.absolute_path(common.home_expand(path))
  local info = absolute and system.get_file_info(absolute)
  if not info or info.type ~= "dir" then self:report("Directory not found: " .. path) return end
  local extensions, err = get_extensions()
  if not extensions then self:report(err) return end
  self:stop()
  self.generation = self.generation + 1
  local generation = self.generation
  self.tracks, self.current, self.error = {}, nil, nil
  self.tracks_by_path = {}
  self:reset_shuffle()
  self.list:clear()
  self.list.scroll.y, self.list.scroll.to.y = 0, 0
  self.folder:set_path(absolute)
  self.scanning, self.scan_skipped = true, 0
  core.add_thread(function()
    if self.closed or generation ~= self.generation then return end
    local _, skipped, cancelled = scan_directory(absolute, extensions,
      function(track) self:add_track(track) end,
      function()
        self.list:set_visible_rows()
        core.redraw = true
        coroutine.yield(0)
        return not self.closed and generation == self.generation
      end)
    if not cancelled and not self.closed and generation == self.generation then
      self.scanning, self.scan_skipped = false, skipped
      core.redraw = true
    end
  end)
end

function AudioView:play(track, history_index)
  if not track then return end
  if not self.mixer then
    local mixer, err = audio.create_mixer({ max_voices = 1 })
    if not mixer then self:report(err) return end
    self.mixer = mixer
    mixer:set_gain(self.volume)
  end
  self:stop()
  if self.visualization then
    local ok, err = self.mixer:set_sample_buffer(2048)
    if not ok then self:report(err) return end
  end
  local voice, err
  voice, err = self.mixer:play_file(track.path)
  if not voice then self:report(track.name .. ": " .. tostring(err)) return end
  self.voice, self.current, self.duration = voice, track, voice:get_duration()
  if self.duration == math.huge then self.duration = nil end
  self.state, self.error = "playing", nil
  self.stop_after_track = false
  if self.shuffle then
    if history_index then
      self.shuffle_index = history_index
    else
      if self.shuffle_history[self.shuffle_index] ~= track then
        for i = #self.shuffle_history, self.shuffle_index + 1, -1 do self.shuffle_history[i] = nil end
        self.shuffle_index = self.shuffle_index + 1
        self.shuffle_history[self.shuffle_index] = track
      end
      for i, pending in ipairs(self.shuffle_remaining) do
        if pending == track then
          self.shuffle_remaining[i] = self.shuffle_remaining[#self.shuffle_remaining]
          self.shuffle_remaining[#self.shuffle_remaining] = nil
          break
        end
      end
    end
  end
  for i, data in ipairs(self.list.row_data) do
    if data == track then self.list:set_selected(i) break end
  end
  core.redraw = true
end

function AudioView:stop()
  if self.voice then self.voice:stop() end
  if self.mixer then self.mixer:set_sample_buffer(0) end
  self.voice, self.duration = nil, nil
  self.resume_position = nil
  self.state, self.position_seconds, self.analysis = "stopped", 0, {}
  self.seek.dragging = false
  self.seek:release_mouse()
  core.redraw = true
end

function AudioView:toggle_play()
  if not self.voice then
    local resume_position, stop_after_track = self.resume_position, self.stop_after_track
    if self.shuffle and not self.current then self:advance(1)
    else self:play(self.current or self.list.row_data[self.list:get_selected() or 1]) end
    if self.voice and resume_position then
      self:seek_to(resume_position)
      self.stop_after_track = stop_after_track
    end
  elseif self.state == "paused" then self.voice:resume() self.state = "playing"
  else self.voice:pause() self.state = "paused" end
  core.redraw = true
end

function AudioView:advance(direction, automatic)
  if automatic and self.stop_after_track then self:stop() return end
  if #self.tracks == 0 then return end
  if self.shuffle then
    local index = self.shuffle_index + direction
    if self.shuffle_history[index] then
      self:play(self.shuffle_history[index], index)
      return
    end
    if direction < 0 then self:play(self.current, self.shuffle_index) return end
    if #self.shuffle_remaining == 0 then
      if automatic and not self.repeat_all then self:stop() return end
      for i, track in ipairs(self.tracks) do self.shuffle_remaining[i] = track end
    end
    local count = #self.shuffle_remaining
    index = math.random(count)
    -- Avoid repeating the last song at the start of a new shuffle cycle.
    if count > 1 and self.shuffle_remaining[index] == self.current then
      index = (index - 1 + math.random(count - 1)) % count + 1
    end
    self:play(self.shuffle_remaining[index])
    return
  end
  local index = self.current and self.current.index or (direction > 0 and 0 or #self.tracks + 1)
  index = index + direction
  if index < 1 or index > #self.tracks then
    if automatic and not self.repeat_all then self:stop() return end
    index = (index - 1) % #self.tracks + 1
  end
  self:play(self.tracks[index])
end

function AudioView:poll()
  if self.voice then
    local state, err = self.voice:get_state()
    if state == "finished" then self:advance(1, true)
    elseif state == "stopped" then
      self:stop()
      if err then self:report(err) end
    else
      self.state = state
      self.position_seconds = self.voice:get_position() or 0
    end
  end
end

function AudioView:seek_to(seconds)
  if not self.voice then return end
  seconds = math.max(0, seconds)
  if self.duration then seconds = math.min(seconds, math.max(0, self.duration - 0.001)) end
  local ok, err = self.voice:seek(seconds)
  if not ok then self:report(err) else self.position_seconds = seconds end
  core.redraw = true
end

function AudioView:seek_by(seconds)
  self:seek_to(self.position_seconds + seconds)
end

function AudioView:select_row(direction)
  if #self.list.rows == 0 then return end
  local index = common.clamp((self.list:get_selected() or 0) + direction, 1, #self.list.rows)
  self.list:set_selected(index)
  local row = self.list.rows[index]
  local height = style.font:get_height() + style.padding.y
  local y = self.list.scroll.to.y
  if row.y < y + height then y = math.max(0, row.y - height)
  elseif row.y + row.h > y + self.list.size.y then y = row.y + row.h - self.list.size.y end
  self.list.scroll.to.y = y
  core.redraw = true
end

function AudioView:play_selected()
  self:play(self.list.row_data[self.list:get_selected() or 1])
end

function AudioView:try_close(do_close)
  self.closed = true
  self.generation = self.generation + 1
  self:stop()
  if self.mixer then self.mixer:close() self.mixer = nil end
  do_close()
end

function AudioView:on_file_dropped(path)
  local info = system.get_file_info(path)
  if info and info.type == "dir" then self:scan(path)
  elseif info and info.type == "file" and AudioView.is_supported(path) then
    self:open_file(path)
  else
    return false
  end
  return true
end

function AudioView:update()
  if not AudioView.super.update(self) then return end
  if self.filter_due and system.get_time() >= self.filter_due then
    self.filter_due = nil
    self:filter_tracks()
  end
  local p, gap, h = style.padding.x, style.padding.y, style.font:get_height()
  local w = math.max(1, self.size.x - 2 * p)
  local row = h + gap * 2
  self.folder:set_position(p, gap)
  self.folder:set_size(w, row)
  self.title_y = self.folder.position.ry + self.folder:get_height() + gap
  self.graph_y = self.title_y + h + gap
  self.graph_h = self.visualization
    and math.max(40 * SCALE, math.min(120 * SCALE, self.size.y - 340 * SCALE)) or 0
  local y = self.graph_y + (self.visualization and self.graph_h + gap or 0)
  self.seek:set_position(p, y)
  self.seek:set_size(w, 20 * SCALE)
  self.seek.enabled = self.voice ~= nil and self.duration ~= nil and self.duration > 0
  if not self.seek.dragging then
    self.seek.value = self.seek.enabled and common.clamp(self.position_seconds / self.duration, 0, 1) or 0
  end
  y = y + 22 * SCALE
  self.time_y = y
  y = y + h + gap
  self.play_button.transport_shape = self.state == "playing" and "pause" or nil
  local button_w = math.min(38 * SCALE, math.max(1, (w - gap - 60 * SCALE) / #self.controls - 4 * SCALE))
  for i, b in ipairs(self.controls) do
    b:set_position(p + (i - 1) * (button_w + 4 * SCALE), y)
    b:set_size(button_w, row)
  end
  local volume_x = p + #self.controls * (button_w + 4 * SCALE) + gap
  self.volume_slider:set_position(volume_x, y)
  self.volume_slider:set_size(math.max(12 * SCALE, w - (volume_x - p)), row)
  y = y + row + gap
  self.filter:set_position(p, y)
  self.filter:set_size(w, row)
  y = y + self.filter:get_height() + gap
  self.list:set_position(p, y)
  self.list:set_size(w, math.max(0, self.size.y - y - h - gap * 2))
  local content_w = math.max(0, self.list.size.x - p * 3 - style.expanded_scrollbar_size)
  local format_w = math.min(content_w, style.font:get_width("Format") + gap)
  self.list.columns[1].width = (content_w - format_w) * 0.65
  self.list.columns[2].width = (content_w - format_w) * 0.35
  self.list.columns[3].width = format_w
  if self.list_width ~= w then
    self.list_width = w
    self.list:recalc_all_rows()
    self.list_height = nil
  end
  if self.list_height ~= self.list.size.y or self.list_row_count ~= #self.list.rows then
    self.list_height, self.list_row_count = self.list.size.y, #self.list.rows
    -- Extend the visible range forward when rows or available space grow.
    self.list.visible_rendered = false
    self.list:set_visible_rows()
  end
end

local function clipped_text(text, x, y, width, color)
  core.push_clip_rect(x, y, math.max(0, width), style.font:get_height())
  renderer.draw_text(style.font, text, x, y, color)
  core.pop_clip_rect()
end

function AudioView:draw()
  if not AudioView.super.draw(self) then return end
  local p, gap, h = style.padding.x, style.padding.y, style.font:get_height()
  local x, y, w = self.position.x + p, self.position.y, self.size.x - 2 * p
  if w <= 0 then return end
  clipped_text(self.current and self.current.name or "No track selected", x,
    y + self.title_y, w, style.text)
  local graph_y, graph_h = y + self.graph_y, self.graph_h
  local channels = self.visualization and math.max(1, #self.analysis) or 0
  for ch = 1, channels do
    local data = self.analysis[ch]
    local color = ch == 1 and style.caret or style.syntax.string
    local center = graph_y + (ch - 0.5) * graph_h / channels
    local amplitude = graph_h / channels * 0.4
    renderer.draw_rect(x, center, w, SCALE, style.line_highlight)
    if data then
      for i, pair in pairs(data.bins) do
        local low, high = common.clamp(pair[1], -1, 1), common.clamp(pair[2], -1, 1)
        renderer.draw_rect(x + (i - 1) * w / 160, center - high * amplitude,
          math.max(SCALE, w / 160 - SCALE), math.max(SCALE, (high - low) * amplitude), color)
      end
      local meter_y = graph_y + ch * graph_h / channels - 2 * SCALE
      renderer.draw_rect(x, meter_y, math.min(1, data.rms) * w, 2 * SCALE, color)
      renderer.draw_rect(x + common.clamp(data.peak, 0, 1) * math.max(0, w - 2 * SCALE),
        meter_y - SCALE, 2 * SCALE, 4 * SCALE, style.text)
    end
  end
  clipped_text(format_time(self.position_seconds) .. " / " .. format_time(self.duration),
    x, y + self.time_y, w * 0.65, style.dim)
  local volume = string.format("%d%%", math.floor(self.volume * 100 + 0.5))
  renderer.draw_text(style.font, volume, x + w - style.font:get_width(volume), y + self.time_y, style.dim)
  local count = #self.tracks == 1 and "1 track" or #self.tracks .. " tracks"
  if #self.list.rows < #self.tracks then count = #self.list.rows .. " of " .. count end
  local status = self.error or string.format("%s%s%s", count,
    self.scanning and " | Scanning..." or "",
    self.scan_skipped > 0 and string.format(" | %d unreadable entries", self.scan_skipped) or "")
  clipped_text(status, x, y + self.size.y - h - gap, w, self.error and style.syntax.keyword or style.dim)
end

return AudioView
