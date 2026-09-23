local audio = require "audio"
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local test = require "core.test"
local style = require "core.style"
local Widget = require "widget"
local FilePicker = require "widget.filepicker"
local Player = require "core.audioview"
require "core.commands.audio"

local function get_upvalue(fn, name)
  local index = 1
  while true do
    local key, value = debug.getupvalue(fn, index)
    assert(key, "Missing upvalue: " .. name)
    if key == name then return value end
    index = index + 1
  end
end

local get_extensions = get_upvalue(Player.scan, "get_extensions")
local scan_directory = get_upvalue(Player.scan, "scan_directory")
local analyze_samples = get_upvalue(Player.new, "analyze_samples")
local format_time = get_upvalue(Player.draw, "format_time")

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local fixtures = system.absolute_path(common.dirname(source) .. "/fixtures/audio")

local function resume(co)
  local ok, err = coroutine.resume(co)
  test.ok(ok, err)
  return err
end

test.describe("audio player", function()
  test.before_each(function(c)
    c.add_thread, c.active_view = core.add_thread, core.active_view
    c.player_config = config.audio_player
    config.audio_player = {
      visualization = true, repeat_all = false, shuffle = false, directory = ""
    }
    c.root_view, c.set_active_view = core.root_view, core.set_active_view
    c.open_doc, c.open_file, c.open_image = core.open_doc, core.open_file, core.open_image
    c.create_mixer, c.report = audio.create_mixer, Player.report
    c.cwd = system.getcwd()
    c.keymap, c.reverse_keymap, c.status_view = keymap.map, keymap.reverse_map, core.status_view
    c.scan, c.show_picker = Player.scan, FilePicker.show_picker
    c.list_dir, c.get_file_info, c.get_decoders = system.list_dir, system.get_file_info, audio.get_decoders
    c.widget_draw, c.draw_rect, c.draw_text = Widget.draw, renderer.draw_rect, renderer.draw_text
    c.draw_poly, c.random = renderer.draw_poly, math.random
    c.get_node_for_view = core.root_view.root_node.get_node_for_view
    c.jobs, c.views, c.files = {}, {}, {}
    core.add_thread = function(fn)
      local co = coroutine.create(fn)
      c.jobs[#c.jobs + 1] = co
      return co
    end
  end)

  test.after_each(function(c)
    for _, view in ipairs(c.views) do
      view:try_close(function() end)
      local node = c.get_node_for_view(c.root_view.root_node, view)
      if node then node:remove_view(c.root_view.root_node, view) end
    end
    for _, path in ipairs(c.files) do os.remove(path) end
    core.add_thread, core.active_view = c.add_thread, c.active_view
    config.audio_player = c.player_config
    core.root_view, core.set_active_view = c.root_view, c.set_active_view
    core.open_doc, core.open_file, core.open_image = c.open_doc, c.open_file, c.open_image
    audio.create_mixer, Player.report = c.create_mixer, c.report
    system.chdir(c.cwd)
    keymap.map, keymap.reverse_map, core.status_view = c.keymap, c.reverse_keymap, c.status_view
    Player.scan, FilePicker.show_picker = c.scan, c.show_picker
    system.list_dir, system.get_file_info, audio.get_decoders = c.list_dir, c.get_file_info, c.get_decoders
    Widget.draw, renderer.draw_rect, renderer.draw_text = c.widget_draw, c.draw_rect, c.draw_text
    renderer.draw_poly, math.random = c.draw_poly, c.random
    core.root_view.root_node.get_node_for_view = c.get_node_for_view
  end)

  local function player(c)
    local view = Player()
    c.views[#c.views + 1] = view
    view:show()
    view.size.x, view.size.y = 800, 640
    return view
  end

  local function playlist(c, count)
    local view = player(c)
    view.mixer = {
      set_sample_buffer = function() return true end,
      close = function() end,
      play_file = function(_, path)
        if path == view.failed_path then return nil, "Playback failed" end
        return {
          get_duration = function() return 120 end,
          get_state = function() return "playing" end,
          get_position = function() return 10 end,
          stop = function() end
        }
      end
    }
    view.report = function(self, err) self.error = err end
    for i = 1, count do
      view:add_track({ name = "Track " .. i, folder = "Album", format = "WAV", path = tostring(i) })
    end
    return view
  end

  local function wav_file(c)
    local path = common.normalize_path(core.temp_filename(".WAV"))
    c.files[#c.files + 1] = path
    local pcm = string.pack("<i2", 8000):rep(4800)
    local file = assert(io.open(path, "wb"))
    file:write("RIFF" .. string.pack("<I4", 36 + #pcm) .. "WAVEfmt "
      .. string.pack("<I4I2I2I4I4I2I2", 16, 1, 1, 48000, 96000, 2, 16)
      .. "data" .. string.pack("<I4", #pcm) .. pcm)
    file:close()
    return path
  end

  test.test("associates buttons with valid commands and toggles the same state", function(c)
    local view = player(c)
    core.active_view = view
    local commands = {
      previous = "previous", play_button = "play-pause", stop_button = "stop", next = "next",
      repeat_button = "toggle-repeat", shuffle_button = "toggle-shuffle",
      visualization_button = "toggle-visualization"
    }
    for field, name in pairs(commands) do
      test.equal(view[field].tooltip_command, "audio-player:" .. name)
      test.ok(command.is_valid(view[field].tooltip_command))
    end
    for _, widget in ipairs({ view.folder, view.folder.button, view.folder.file }) do
      test.equal(widget.tooltip_command, "audio-player:open-directory")
      test.ok(command.is_valid(widget.tooltip_command))
    end
    for _, pair in ipairs({ { "repeat_button", "repeat_all" }, { "shuffle_button", "shuffle" },
      { "visualization_button", "visualization" } }) do
      local button, field = view[pair[1]], pair[2]
      local before = view[field]
      test.ok(command.perform(button.tooltip_command))
      test.equal(view[field], not before)
      test.equal(button.enabled, not before)
      button:on_click("left")
      test.equal(view[field], before)
      test.equal(button.enabled, before)
    end
    view.child_active = view.filter
    test.not_ok(command.is_valid(view.shuffle_button.tooltip_command))
  end)

  test.test("shows current command bindings when hovering buttons", function(c)
    local view = player(c)
    view:update()
    view:update()
    local tooltip
    core.status_view = {
      show_tooltip = function(_, value) tooltip = value end,
      remove_tooltip = function() tooltip = nil end
    }
    local function hover(button)
      view:on_mouse_moved(-1000, -1000, 0, 0)
      view:on_mouse_moved(button.position.x + button.size.x / 2,
        button.position.y + button.size.y / 2, 0, 0)
      test.not_nil(tooltip)
      test.equal(tooltip[1], button.tooltip)
    end
    hover(view.play_button)
    test.contains(tooltip, "  " .. keymap.get_binding("audio-player:play-pause"))
    hover(view.previous)
    test.contains(tooltip, "  " .. keymap.get_binding("audio-player:previous"))
    hover(view.next)
    test.contains(tooltip, "  " .. keymap.get_binding("audio-player:next"))

    keymap.map, keymap.reverse_map = {}, {}
    for i, button in ipairs(view.controls) do
      keymap.add { ["f" .. i] = button.tooltip_command }
      hover(button)
      test.contains(tooltip, "  " .. keymap.get_binding(button.tooltip_command))
    end
    keymap.add { ["f8"] = "audio-player:open-directory" }
    for _, widget in ipairs({ view.folder.button, view.folder.file }) do
      hover(widget)
      test.contains(tooltip, "  f8")
    end
    keymap.unbind("f2", "audio-player:play-pause")
    keymap.add { ["f9"] = "audio-player:play-pause" }
    hover(view.play_button)
    test.contains(tooltip, "  f9")
    keymap.unbind("f9", "audio-player:play-pause")
    hover(view.play_button)
    test.same(tooltip, { view.play_button.tooltip })
    view:on_mouse_moved(-1000, -1000, 0, 0)
  end)

  test.test("registers disabled playback defaults and a directory setting", function()
    local settings = require "plugins.settings"
    local spec = settings.core["Audio Player"]
    test.not_nil(spec)
    local options = {}
    for _, option in ipairs(spec) do options[option.path:match("%.(.+)$")] = option end
    for _, path in ipairs({ "visualization", "repeat_all", "shuffle" }) do
      test.equal(options[path].default, false)
    end
    test.equal(options.directory.default, "")
    test.ok(options.directory.exists)
  end)

  test.test("applies configured playback defaults only to new tabs", function(c)
    local defaults = config.audio_player
    defaults.visualization, defaults.repeat_all, defaults.shuffle = false, true, true
    local view = playlist(c, 3)
    test.not_ok(view.visualization)
    test.not_ok(view.visualization_button.enabled)
    test.ok(view.repeat_all)
    test.ok(view.repeat_button.enabled)
    test.ok(view.shuffle)
    test.ok(view.shuffle_button.enabled)
    test.equal(#view.shuffle_remaining, 3)
    local capacities = {}
    view.mixer.set_sample_buffer = function(_, frames)
      capacities[#capacities + 1] = frames
      return true
    end
    math.random = function(count) return count end
    view:toggle_play()
    test.equal(view.current, view.tracks[3])
    test.same(capacities, { 0 })
    view:advance(1, true)
    view:advance(1, true)
    view:advance(1, true)
    test.equal(view.state, "playing")
    view.visualization_button:on_click("left")
    view.repeat_button:on_click("left")
    view.shuffle_button:on_click("left")
    test.not_ok(defaults.visualization)
    test.ok(defaults.repeat_all)
    test.ok(defaults.shuffle)
    local another = player(c)
    test.not_ok(another.visualization)
    test.ok(another.repeat_all)
    test.ok(another.shuffle)
    defaults.visualization, defaults.repeat_all, defaults.shuffle = true, false, false
    another:update()
    test.not_ok(another.visualization)
    test.ok(another.repeat_all)
    test.ok(another.shuffle)
    local latest = player(c)
    test.ok(latest.visualization)
    test.not_ok(latest.repeat_all)
    test.not_ok(latest.shuffle)
  end)

  test.test("uses the default directory once and lets explicit directory choices override it", function(c)
    local node = {
      add_view = function(_, view) c.views[#c.views + 1] = view end,
      set_active_view = function() end
    }
    core.root_view = {
      get_active_node_default = function() return node end,
      root_node = {
        get_node_for_view = function() return node end,
        get_children = function() return {} end,
        update_layout = function() end
      }
    }
    core.set_active_view = function(view) core.active_view = view end
    local paths, picks = {}, 0
    Player.scan = function(self, path)
      paths[#paths + 1] = path
      return c.scan(self, path)
    end
    FilePicker.show_picker = function() picks = picks + 1 end
    local defaults = config.audio_player
    defaults.directory = fixtures
    local view = core.open_audio()
    test.equal(paths[1], fixtures)
    test.equal(view.folder:get_path(), fixtures)
    local scan = c.jobs[#c.jobs]
    while coroutine.status(scan) ~= "dead" do resume(scan) end
    test.equal(#view.tracks, 4)
    test.equal(view.state, "stopped")
    test.is_nil(view.mixer)
    view.shuffle_button:set_toggle(true)
    defaults.directory = common.dirname(fixtures)
    test.equal(core.open_audio(), view)
    test.equal(#paths, 1)
    test.ok(view.shuffle)
    view:try_close(function() end)

    view = core.open_audio(fixtures)
    test.equal(#paths, 2)
    test.equal(paths[2], fixtures)
    test.not_ok(view.shuffle)
    view:try_close(function() end)
    test.ok(command.perform("audio-player:open-directory"))
    test.equal(picks, 1)
    test.equal(#paths, 2)
    view = core.active_view
    test.is_nil(view.folder:get_path())
    view:try_close(function() end)

    defaults.directory = ""
    view = core.open_audio()
    test.equal(#paths, 2)
    test.equal(#view.tracks, 0)
    test.is_nil(view.folder:get_path())
  end)

  test.test("round-trips workspace state without audio handles or automatic playback", function(c)
    local view = playlist(c, 0)
    for i = 1, 3 do
      view:add_track({ path = wav_file(c), name = "Song " .. i, folder = "Album", format = "WAV" })
    end
    view.folder:set_path(fixtures)
    view:play(view.tracks[2])
    view.stop_after_track = true
    view.filter:set_text("song")
    view:filter_tracks()
    view.list:set_selected(3)
    view.list.scroll.to.x, view.list.scroll.to.y = 4, 64
    view.volume, view.volume_slider.value = 0.4, 0.4
    view.visualization_button:set_toggle(false)
    view.repeat_button:set_toggle(true)
    view.shuffle_button:set_toggle(true)
    local state = view:get_state()
    test.equal(state.position_seconds, 10)
    test.equal(view:get_module(), "core.audioview")
    local saved = assert(load("return " .. common.serialize({
      module = view:get_module(), state = state
    })))()
    test.same(saved.state, state)
    config.audio_player.directory = common.dirname(fixtures)
    Player.scan = function() error("Workspace restoration must not rescan") end
    audio.create_mixer = function() error("Workspace restoration must not open audio") end
    local restored = require(saved.module).from_state(saved.state)
    c.views[#c.views + 1] = restored
    test.ok(restored:is_visible())
    test.equal(restored.state, "stopped")
    test.is_nil(restored.mixer)
    test.is_nil(restored.voice)
    test.is_nil(restored.filter_due)
    test.equal(restored.resume_position, 10)
    test.equal(restored.current, restored.tracks[2])
    test.equal(restored.list.row_data[restored.list:get_selected()], restored.tracks[3])
    test.equal(restored.volume_slider.value, 0.4)
    test.not_ok(restored.visualization_button.enabled)
    test.ok(restored.repeat_button.enabled)
    test.ok(restored.shuffle_button.enabled)
    test.same(restored:get_state(), state)
    view.tracks[1].name = "Changed original"
    restored.tracks[2].name = "Changed restored"
    test.equal(state.tracks[1].name, "Song 1")
    test.equal(saved.state.tracks[2].name, "Song 2")
  end)

  test.test("restores remaining tracks when saved files disappear", function(c)
    local view = playlist(c, 0)
    for i = 1, 2 do
      view:add_track({ path = wav_file(c), name = "Song " .. i, folder = "Album", format = "WAV" })
    end
    view:play(view.tracks[1])
    local state = view:get_state()
    test.ok(os.remove(view.tracks[1].path))
    state.tracks[#state.tracks + 1] = state.tracks[2]
    local restored = Player.from_state(state)
    c.views[#c.views + 1] = restored
    test.equal(#restored.tracks, 1)
    test.equal(restored.tracks[1].path, view.tracks[2].path)
    test.equal(restored.tracks[1].index, 1)
    test.is_nil(restored.current)
    test.is_nil(restored.list:get_selected())
    test.is_nil(restored.resume_position)
    test.equal(restored.position_seconds, 0)
    local empty = Player.from_state(player(c):get_state())
    c.views[#c.views + 1] = empty
    test.equal(#empty.tracks, 0)
    test.ok(empty:is_visible())
    test.is_nil(empty.mixer)
  end)

  test.test("resumes a saved track only on Play and preserves single-file playback", function(c)
    local view = player(c)
    view.mixer = assert(audio.create_mixer({ offline = true,
      spec = { format = "f32", channels = 1, sample_rate = 48000 } }))
    local first, second = wav_file(c), wav_file(c)
    view:open_file(second)
    view:open_file(first)
    view.volume_slider:on_change(0.3)
    view:seek_to(0.02)
    view:toggle_play()
    local state = view:get_state()
    local restored = Player.from_state(state)
    c.views[#c.views + 1] = restored
    test.is_nil(restored.voice)
    test.is_nil(restored.mixer)
    test.near(restored.position_seconds, 0.02, 1e-6)
    audio.create_mixer = function(options)
      options.offline = true
      options.spec = { format = "f32", channels = 1, sample_rate = 48000 }
      return c.create_mixer(options)
    end
    restored:toggle_play()
    test.equal(restored.state, "playing")
    test.near(restored.voice:get_position(), 0.02, 1e-6)
    test.near(restored.mixer:get_gain(), 0.3, 1e-6)
    test.is_nil(restored.resume_position)
    test.ok(restored.stop_after_track)
    restored.repeat_all = true
    assert(restored.mixer:render(8192))
    restored:poll()
    test.equal(restored.state, "stopped")

    local stopped = Player.from_state(state)
    c.views[#c.views + 1] = stopped
    stopped:stop()
    stopped:toggle_play()
    test.near(stopped.voice:get_position(), 0, 1e-6)
  end)

  test.test("reuses workspace-restored players when opening audio", function(c)
    local view = player(c)
    view:scan(fixtures)
    local scan = c.jobs[#c.jobs]
    while coroutine.status(scan) ~= "dead" do resume(scan) end
    local restored = Player.from_state(view:get_state())
    c.views[#c.views + 1] = restored
    local node = core.root_view:get_active_node_default()
    node:add_view(restored)
    local count = #node.views
    test.equal(core.open_audio(), restored)
    test.equal(#node.views, count)
    test.is_nil(restored.mixer)
    audio.create_mixer = function(options)
      options.offline = true
      options.spec = { format = "f32", channels = 1, sample_rate = 48000 }
      return c.create_mixer(options)
    end
    local path = wav_file(c)
    test.equal(core.open_file(path), restored)
    test.is_nil(restored.error, restored.error)
    test.equal(restored.current.path, path)
    test.equal(#restored.tracks, #view.tracks + 1)
    test.equal(#node.views, count)
  end)

  test.test("matches extensions from the available decoder backends", function()
    audio.get_decoders = function() return { "WAV", "DRMP3", "DRFLAC", "STBVORBIS", "OPUS" } end
    local extensions = assert(get_extensions())
    for _, ext in ipairs({ "wav", "mp3", "flac", "ogg", "opus" }) do test.ok(extensions[ext]) end
    test.is_nil(extensions.m4a)
    audio.get_decoders = function() return { "MPG123", "FLAC", "VORBIS", "AIFF" } end
    extensions = assert(get_extensions())
    for _, ext in ipairs({ "mp3", "flac", "ogg", "aiff" }) do test.ok(extensions[ext]) end
    test.is_nil(extensions.wav)
  end)

  test.test("rejects non-audio extensions without querying decoders", function()
    audio.get_decoders = function() error("Unexpected decoder initialization") end
    for _, path in ipairs({ "main.lua", "README", "image.png", "folder.wav/file.txt" }) do
      test.not_ok(Player.is_supported(path))
    end
  end)

  test.test("opens project-relative audio without reading a document or scanning defaults", function(c)
    config.audio_player.directory = fixtures
    core.open_doc = function() error("Audio must not enter the text reader") end
    audio.create_mixer = function(options)
      options.offline = true
      options.spec = { format = "f32", channels = 1, sample_rate = 48000 }
      return c.create_mixer(options)
    end
    local path = wav_file(c)
    local relative = common.relative_path(core.root_project().path, path)
    system.chdir(fixtures)
    test.ok(Player.is_supported(path))
    local view = core.open_file(relative)
    c.views[#c.views + 1] = view
    test.ok(view:is(Player))
    test.equal(core.open_file(relative), view)
    test.is_nil(view.error, view.error)
    test.equal(view.current.path, path)
    test.equal(view.state, "playing")
    test.equal(#view.tracks, 1)
    test.is_nil(view.folder:get_path())
    local voice = view.voice
    view:seek_to(0.02)
    test.equal(core.open_file(path), view)
    test.equal(view.voice, voice)
    test.near(voice:get_position(), 0.02, 1e-6)
    view:toggle_play()
    test.equal(core.open_file(path), view)
    test.equal(view.state, "paused")
    test.equal(view.voice, voice)
    test.equal(#view.tracks, 1)
    view:stop()
    core.open_file(path)
    test.equal(view.state, "playing")
    test.equal(#view.tracks, 1)
  end)

  test.test("opens Windows audio paths with forward and mixed separators", function(c)
    test.skip_if(PLATFORM ~= "Windows", "Windows path syntax is required")
    local view = core.open_audio("")
    c.views[#c.views + 1] = view
    view.mixer = assert(audio.create_mixer({ offline = true,
      spec = { format = "f32", channels = 1, sample_rate = 48000 } }))
    local path = wav_file(c)
    for _, variant in ipairs({ path:gsub("\\", "/"), (path:gsub("\\", "/", 1)) }) do
      test.equal(core.open_file(variant), view)
      test.is_nil(view.error, view.error)
      test.equal(view.current.path, path)
      test.equal(#view.tracks, 1)
    end
  end)

  test.test("external file opens stop after that track even with repeat or shuffle", function(c)
    local view = core.open_audio("")
    c.views[#c.views + 1] = view
    view.mixer = assert(audio.create_mixer({ offline = true,
      spec = { format = "f32", channels = 1, sample_rate = 48000 } }))
    local paths = { wav_file(c), wav_file(c), wav_file(c) }
    for _, path in ipairs(paths) do test.equal(core.open_file(path), view) end
    for _, repeat_all in ipairs({ false, true }) do
      for _, shuffle in ipairs({ false, true }) do
        view.repeat_button:set_toggle(repeat_all)
        view.shuffle_button:set_toggle(shuffle)
        for i, path in ipairs(paths) do
          test.equal(core.open_file(path), view)
          test.equal(#view.tracks, 3)
          test.equal(view.current, view.tracks[i])
          test.equal(view.state, "playing")
          assert(view.mixer:render(8192))
          view:poll()
          test.equal(view.state, "stopped")
          test.equal(view.current, view.tracks[i])
          test.is_nil(view.voice)
          test.equal(view.repeat_all, repeat_all)
          test.equal(view.shuffle, shuffle)
        end
      end
    end
  end)

  test.test("reopening the current playlist track limits playback without restarting it", function(c)
    local view = player(c)
    view.mixer = assert(audio.create_mixer({ offline = true,
      spec = { format = "f32", channels = 1, sample_rate = 48000 } }))
    local first, second = wav_file(c), wav_file(c)
    view:open_file(first)
    view:open_file(second)
    view:play(view.tracks[1])
    view:seek_to(0.02)
    view:toggle_play()
    local voice = view.voice
    view:open_file(first)
    test.equal(view.voice, voice)
    test.equal(view.state, "paused")
    test.near(voice:get_position(), 0.02, 1e-6)
    view:toggle_play()
    assert(view.mixer:render(8192))
    view:poll()
    test.equal(view.state, "stopped")
    test.equal(view.current, view.tracks[1])

    local actions = {
      function() view.list:on_row_click(1, view.tracks[1]) end,
      function() view.list:set_selected(1) view:play_selected() end,
      function() view:advance(-1) end
    }
    for _, action in ipairs(actions) do
      view:open_file(second)
      action()
      test.equal(view.current, view.tracks[1])
      assert(view.mixer:render(8192))
      view:poll()
      test.equal(view.state, "playing")
      test.equal(view.current, view.tracks[2])
    end
    view:open_file(first)
    view:advance(1)
    view.repeat_all = true
    assert(view.mixer:render(8192))
    view:poll()
    test.equal(view.state, "playing")
    test.equal(view.current, view.tracks[1])
  end)

  test.test("keeps missing or corrupt audio out of the text reader", function(c)
    local view = core.open_audio("")
    c.views[#c.views + 1] = view
    Player.report = function(self, err) self.error = err end
    core.open_doc = function() error("Audio must not enter the text reader") end
    audio.create_mixer = function(options)
      options.offline = true
      options.spec = { format = "f32", channels = 1, sample_rate = 48000 }
      return c.create_mixer(options)
    end
    test.equal(core.open_file(core.temp_filename(".wav")), view)
    test.contains(view.error, "File not found")
    local path = core.temp_filename(".wav")
    c.files[#c.files + 1] = path
    local file = assert(io.open(path, "wb"))
    file:write("invalid audio")
    file:close()
    test.equal(core.open_file(path), view)
    test.not_nil(view.error)
    test.equal(view.state, "stopped")
    test.is_nil(view.voice)
  end)

  test.test("preserves image and text file dispatch", function(c)
    local image = {}
    local opened
    core.open_image = function(path) opened = path return image end
    test.equal(core.open_file("photo.png"), image)
    test.equal(opened, "photo.png")
    core.open_image = function() end
    local doc, view = {}, {}
    core.open_doc = function(path) opened = path return doc end
    core.root_view = { open_doc = function(_, value) test.equal(value, doc) return view end }
    test.equal(core.open_file("readme.txt"), view)
    test.equal(opened, "readme.txt")
  end)

  test.test("routes TreeView and deferred drops through the common file opener", function(c)
    local treeview = require "plugins.treeview"
    local opened = {}
    core.open_file = function(path) opened[#opened + 1] = path return "media view" end
    test.equal(treeview:open_doc("song.wav"), "media view")
    local node = { active_view = {}, set_active_view = function() end }
    local root = setmetatable({ defer_open_docs = { { "song.wav", 10, 20 } },
      root_node = { get_child_overlapping_point = function(_, x, y)
        test.equal(x, 10)
        test.equal(y, 20)
        return node
      end } }, { __index = require "core.rootview" })
    core.active_view = core.nag_view
    root:process_defer_open_docs()
    test.equal(#root.defer_open_docs, 1)
    test.equal(#opened, 1)
    core.active_view = c.active_view
    root:process_defer_open_docs()
    test.same(opened, { "song.wav", "song.wav" })
    test.equal(#root.defer_open_docs, 0)
  end)

  test.test("deduplicates file drops and passes other files to the editor", function(c)
    local view = playlist(c, 0)
    local path = wav_file(c)
    test.ok(view:on_file_dropped(path))
    test.equal(view.state, "playing")
    local voice = view.voice
    test.ok(view:on_file_dropped(path))
    test.equal(#view.tracks, 1)
    test.equal(view.voice, voice)
    test.not_ok(view:on_file_dropped(fixtures .. PATHSEP .. "README.md"))
    test.equal(view.voice, voice)
    view:scan(fixtures)
    test.is_nil(view.tracks_by_path[path])
  end)

  test.test("walks nested folders, skips directory links and tolerates unreadable entries", function()
    local root = "music"
    local sep = PATHSEP
    local listings = { [root] = { "album", "loop", "gone", "bad", "A.MP3", "notes.txt" },
      [root .. sep .. "album"] = { "b.flac" } }
    system.list_dir = function(path) return listings[path] end
    system.get_file_info = function(path)
      local name = common.basename(path)
      if name == "gone" then return nil end
      return { type = (name == "album" or name == "loop" or name == "bad") and "dir" or "file",
        symlink = name == "loop" }
    end
    local tracks, yields = {}, 0
    local count, skipped, cancelled = scan_directory(root, { mp3 = true, flac = true },
      function(track) tracks[#tracks + 1] = track end,
      function() yields = yields + 1 return true end)
    test.equal(count, 2)
    test.equal(skipped, 2)
    test.not_ok(cancelled)
    test.equal(tracks[1].name, "A.MP3")
    test.equal(tracks[2].folder, "album")
    test.ok(yields >= 3)
    local _, _, stopped = scan_directory(root, {}, function() end, function() return false end)
    test.ok(stopped)
  end)

  test.test("keeps waveform channels separate and preserves peaks", function()
    local result = analyze_samples({ 0, 0.5, -1, 0.5, 1, -0.5, 0, -0.5 }, 2, 2)
    test.equal(#result, 2)
    test.equal(result[1].peak, 1)
    test.equal(result[2].peak, 0.5)
    test.near(result[1].rms, math.sqrt(0.5), 1e-9)
    test.near(result[2].rms, 0.5, 1e-9)
    test.same(result[1].bins, { { -1, 0 }, { 0, 1 } })
    test.equal(analyze_samples({}, 1, 160)[1].rms, 0)
    test.equal(analyze_samples({ 0/0, math.huge }, 1, 160)[1].peak, 0)
    test.equal(format_time(nil), "--:--")
    test.equal(format_time(125.9), "2:05")
  end)

  test.test("filters list rows without changing playlist identity", function(c)
    local view = player(c)
    for i = 1, 3 do view:add_track({ name = "Track " .. i, folder = "Album", format = "WAV", path = "x" .. i }) end
    view.current = view.tracks[2]
    view.filter:set_text("track 2")
    view:filter_tracks()
    test.equal(#view.list.rows, 1)
    test.equal(view.list.row_data[1], view.current)
    test.equal(view.list:get_selected(), 1)
    test.equal(view.current.index, 2)
    view.filter:set_text("")
    view:filter_tracks()
    test.equal(#view.list.rows, 3)
    view:select_row(1)
    test.equal(view.list:get_selected(), 3)
  end)

  test.test("refreshes visible rows when tracks arrive without scrolling", function(c)
    local view = playlist(c, 1)
    view:update()
    view:update()
    test.equal(#view.list.visible_rows, 1)
    for i = 2, 40 do
      view:add_track({ name = "Track " .. i, folder = "Album", format = "WAV", path = tostring(i) })
    end
    view:update()
    test.ok(#view.list.visible_rows > 5)
    local visible = #view.list.visible_rows
    view:set_visualization(false)
    view:update()
    test.ok(#view.list.visible_rows > visible)
  end)

  test.test("discards stale scans and closes during an in-progress scan", function(c)
    local view = player(c)
    view.shuffle_button:set_toggle(true)
    view:scan(fixtures)
    local first = c.jobs[#c.jobs]
    view:scan(fixtures)
    local second = c.jobs[#c.jobs]
    resume(first)
    test.equal(coroutine.status(first), "dead")
    test.equal(#view.tracks, 0)
    while coroutine.status(second) ~= "dead" do resume(second) end
    test.equal(#view.tracks, 4)
    test.equal(#view.shuffle_remaining, 4)
    test.not_ok(view.scanning)
    view:scan(fixtures)
    test.equal(#view.shuffle_remaining, 0)
    test.equal(#view.shuffle_history, 0)
    local third = c.jobs[#c.jobs]
    view:try_close(function() end)
    resume(third)
    test.equal(#view.tracks, 0)
    test.equal(coroutine.status(third), "dead")
  end)

  test.test("shuffles whole playlists without repeats and honors repeat at the end", function(c)
    local view = playlist(c, 5)
    view:play(view.tracks[2])
    local voice = view.voice
    view.shuffle_button:on_click("left")
    test.ok(view.shuffle)
    test.equal(view.voice, voice)
    local seen = { [view.current] = true }
    for _ = 2, #view.tracks do
      view:advance(1, true)
      test.equal(view.state, "playing")
      test.not_ok(seen[view.current])
      seen[view.current] = true
    end
    test.equal(#view.shuffle_remaining, 0)
    view:advance(1, true)
    test.equal(view.state, "stopped")
    local last = view.current
    view.repeat_button:on_click("left")
    view:advance(1, true)
    test.not_equal(view.current, last)
    test.equal(view.state, "playing")
    seen = { [view.current] = true }
    for _ = 2, #view.tracks do
      view:advance(1, true)
      test.not_ok(seen[view.current])
      seen[view.current] = true
    end
    test.equal(#view.shuffle_remaining, 0)
    last = view.current
    view:advance(1, true)
    test.not_equal(view.current, last)
  end)

  test.test("retraces shuffle history and keeps failed playback out of it", function(c)
    local view = playlist(c, 5)
    view.shuffle_button:set_toggle(true)
    view:toggle_play()
    local played = { view.current }
    for i = 2, 3 do view:advance(1) played[i] = view.current end
    for i = 2, 1, -1 do
      view:advance(-1)
      test.equal(view.current, played[i])
    end
    view:advance(-1)
    test.equal(view.current, played[1])
    test.equal(#view.shuffle_remaining, 2)
    for i = 2, 3 do
      view:advance(1)
      test.equal(view.current, played[i])
    end
    test.equal(#view.shuffle_history, 3)
    test.equal(#view.shuffle_remaining, 2)
    view:advance(-1)
    local chosen = view.shuffle_remaining[1]
    view.failed_path = chosen.path
    view:play(chosen)
    test.equal(view.current, played[2])
    test.equal(view.shuffle_index, 2)
    test.equal(#view.shuffle_history, 3)
    test.equal(#view.shuffle_remaining, 2)
    view.failed_path = nil
    view:play(chosen)
    test.equal(view.shuffle_history[3], chosen)
    test.equal(#view.shuffle_remaining, 1)
    view.filter:set_text(chosen.name)
    view:filter_tracks()
    view:advance(1)
    test.not_equal(view.current, chosen)
    test.equal(#view.shuffle_remaining, 0)
    view.shuffle_button:set_toggle(false)
    local next_index = view.current.index % #view.tracks + 1
    view:advance(1)
    test.equal(view.current.index, next_index)
    test.equal(#view.shuffle_history, 0)
  end)

  test.test("handles empty and single-track shuffle and newly added tracks", function(c)
    local view = playlist(c, 0)
    view.shuffle_button:set_toggle(true)
    view:toggle_play()
    view:advance(-1)
    test.equal(view.state, "stopped")
    view:add_track({ name = "One", folder = ".", format = "WAV", path = "1" })
    view:toggle_play()
    test.equal(view.current, view.tracks[1])
    view:advance(1, true)
    test.equal(view.state, "stopped")
    view.repeat_button:set_toggle(true)
    view:advance(1, true)
    test.equal(view.state, "playing")
    test.equal(view.current, view.tracks[1])
    view:add_track({ name = "Two", folder = ".", format = "WAV", path = "2" })
    view:advance(1, true)
    test.equal(view.current, view.tracks[2])
    view:stop()
    view:toggle_play()
    test.equal(view.current, view.tracks[2])
    test.equal(#view.shuffle_history, 2)

    view = playlist(c, 4)
    math.random = function(count) return count end
    view.shuffle_button:set_toggle(true)
    view:toggle_play()
    test.equal(view.current, view.tracks[4])
    view:advance(1)
    test.equal(view.current, view.tracks[3])
  end)

  test.test("streams, seeks, pauses, advances and closes playback", function(c)
    local view = player(c)
    view.mixer = assert(audio.create_mixer({ offline = true,
      spec = { format = "f32", channels = 1, sample_rate = 48000 } }))
    for i = 1, 2 do
      view:add_track({ name = "Track " .. i, folder = ".", format = "WAV", path = wav_file(c) })
    end
    view:play_selected()
    test.equal(view.state, "playing")
    test.near(view.duration, 0.1, 1e-6)
    view:seek_to(0.02)
    test.near(view.voice:get_position(), 0.02, 1e-6)
    local voice = view.voice
    view.visualization_button:on_click("left")
    test.not_ok(view.visualization)
    test.equal(view.voice, voice)
    test.equal(voice:get_state(), "playing")
    test.near(voice:get_position(), 0.02, 1e-6)
    test.is_nil(view.mixer:get_samples())
    view:toggle_play()
    test.equal(view.voice:get_state(), "paused")
    view.visualization_button:on_click("left")
    test.ok(view.visualization)
    test.equal(view.voice, voice)
    test.equal(voice:get_state(), "paused")
    test.equal(#assert(view.mixer:get_samples()), 0)
    view:toggle_play()
    test.equal(view.voice:get_state(), "playing")
    assert(view.mixer:render(512))
    test.ok(#assert(view.mixer:get_samples()) > 0)
    view.volume_slider:on_change(0.3)
    test.near(view.mixer:get_gain(), 0.3, 1e-6)
    assert(view.mixer:render(8192))
    view:poll()
    test.equal(view.current.index, 2)
    test.equal(view.state, "playing")
    view.repeat_all = true
    assert(view.mixer:render(8192))
    view:poll()
    test.equal(view.current.index, 1)
    view:advance(1)
    view.repeat_all = false
    assert(view.mixer:render(8192))
    view:poll()
    test.equal(view.state, "stopped")
    test.is_nil(view.mixer:get_samples())
    view.visualization_button:set_toggle(false)
    view:play(view.tracks[1])
    test.is_nil(view.mixer:get_samples())
    view.shuffle_button:set_toggle(true)
    assert(view.mixer:render(8192))
    view:poll()
    test.equal(view.current, view.tracks[2])
    test.equal(view.state, "playing")
    test.is_nil(view.mixer:get_samples())
    assert(view.mixer:render(8192))
    view:poll()
    test.equal(view.state, "stopped")
    local mixer = view.mixer
    view:try_close(function() end)
    test.is_nil(mixer:get_info())
  end)

  test.test("disables visualization work while keeping playback progress updated", function(c)
    local view = playlist(c, 1)
    local visible, reads, capacities = true, 0, {}
    core.root_view.root_node.get_node_for_view = function()
      return visible and { active_view = view } or nil
    end
    view.mixer.set_sample_buffer = function(_, frames)
      capacities[#capacities + 1] = frames
      return true
    end
    view.mixer.get_samples = function()
      reads = reads + 1
      return { 0.25 }, { channels = 1 }
    end
    view:play_selected()
    test.same(capacities, { 0, 2048 })
    test.near(resume(c.jobs[1]), 1 / 30, 1e-9)
    test.equal(reads, 1)
    test.equal(view.analysis[1].peak, 0.25)
    local voice = view.voice
    view.visualization_button:on_click("left")
    test.equal(capacities[#capacities], 0)
    test.equal(#view.analysis, 0)
    view.position_seconds = 0
    test.equal(resume(c.jobs[1]), 0.2)
    test.equal(view.position_seconds, 10)
    test.equal(view.voice, voice)
    test.equal(reads, 1)
    view.visualization_button:on_click("left")
    test.equal(capacities[#capacities], 2048)
    test.near(resume(c.jobs[1]), 1 / 30, 1e-9)
    test.equal(reads, 2)
    visible = false
    test.equal(resume(c.jobs[1]), 0.2)
    test.equal(reads, 2)
  end)

  test.test("keeps visualization toggles idle until playback and handles capture errors", function(c)
    local view = player(c)
    view.visualization_button:set_toggle(false)
    view.visualization_button:set_toggle(true)
    test.is_nil(view.mixer)
    view = playlist(c, 1)
    view.visualization_button:set_toggle(false)
    view:play_selected()
    local voice = view.voice
    view.mixer.set_sample_buffer = function() return nil, "Capture unavailable" end
    view.visualization_button:on_click("left")
    test.not_ok(view.visualization)
    test.not_ok(view.visualization_button.enabled)
    test.equal(view.error, "Capture unavailable")
    test.equal(view.voice, voice)
    test.equal(view.state, "playing")
  end)

  test.test("gives hidden visualization space back to the playlist", function(c)
    local view = playlist(c, 80)
    view:update()
    view:update()
    local height, rows = view.list.size.y, #view.list.visible_rows
    view.visualization_button:set_toggle(false)
    view:update()
    view:update()
    test.equal(view.graph_h, 0)
    test.ok(view.list.size.y > height)
    test.ok(#view.list.visible_rows > rows)
    view.visualization_button:set_toggle(true)
    view:update()
    view:update()
    test.equal(view.list.size.y, height)
    test.equal(#view.list.visible_rows, rows)
  end)

  test.test("lays out controls without overlap in narrow and wide views", function(c)
    local view = player(c)
    for _, size in ipairs({ { 320, 540, false }, { 360, 540, true }, { 800, 600, false }, { 1280, 720, true } }) do
      view.visualization_button:set_toggle(size[3])
      view.size.x, view.size.y = size[1], size[2]
      view:update()
      view:update()
      for _, child in ipairs({ view.folder, view.filter, view.list, view.seek, view.volume_slider }) do
        test.ok(child.position.x >= view.position.x)
        test.ok(child.position.x + child.size.x <= view.position.x + view.size.x)
        test.ok(child.position.y + child.size.y <= view.position.y + view.size.y)
      end
      test.ok(view.seek.position.y >= view.position.y + view.graph_y + view.graph_h)
      test.ok(view.filter.position.y >= view.previous.position.y + view.previous.size.y)
      test.ok(view.list.position.y >= view.filter.position.y + view.filter.size.y)
      for i, control in ipairs(view.controls) do
        local next_control = view.controls[i + 1] or view.volume_slider
        test.ok(next_control.position.x >= control.position.x + control.size.x)
      end
    end
  end)

  test.test("centers transport symbols independently of widget padding and text baselines", function(c)
    local view = player(c)
    view.state = "playing"
    view:update()
    Widget.draw = function() return true end
    local rectangles, texts, polygons
    renderer.draw_rect = function(x, y, w, h, color)
      rectangles[#rectangles + 1] = { x = x, y = y, w = w, h = h, color = color }
    end
    renderer.draw_text = function(font, text, x, y, color)
      texts[#texts + 1] = { x = x, y = y, w = font:get_width(text), h = font:get_height(), color = color }
      return x + font:get_width(text)
    end
    renderer.draw_poly = function(points, color)
      polygons[#polygons + 1] = { points = points, color = color }
    end
    for _, size in ipairs({ { 36, 30 }, { 60, 54 } }) do
      for _, b in ipairs(view.controls) do
        b.size.x, b.size.y = size[1], size[2]
        rectangles, texts, polygons = {}, {}, {}
        b:draw()
        local cx, cy = b.position.x + b.size.x / 2, b.position.y + b.size.y / 2
        if b == view.play_button then
          test.equal(#texts, 0)
          test.equal(#rectangles, 2)
          local a, z = rectangles[1], rectangles[2]
          test.near((a.x + z.x + z.w) / 2, cx, 1e-9)
          test.near(a.y + a.h / 2, cy, 1e-9)
          test.equal(a.y, z.y)
          test.equal(a.h, z.h)
        elseif b == view.shuffle_button then
          test.equal(#polygons, 2)
          local left, top, right, bottom = math.huge, math.huge, -math.huge, -math.huge
          for _, poly in ipairs(polygons) do
            for _, p in ipairs(poly.points) do
              left, top = math.min(left, p[1]), math.min(top, p[2])
              right, bottom = math.max(right, p[1]), math.max(bottom, p[2])
            end
          end
          test.near((left + right) / 2, cx, 1e-9)
          test.near((top + bottom) / 2, cy, 1e-9)
        else
          local glyph = texts[1] or rectangles[1]
          test.not_nil(glyph)
          test.near(glyph.x + glyph.w / 2, cx, 1e-9)
          test.near(glyph.y + glyph.h / 2, cy, 1e-9)
        end
      end
    end
    view.repeat_button:on_click("left")
    test.ok(view.repeat_all)
    rectangles, texts = {}, {}
    view.repeat_button:draw()
    test.same(texts[1].color, style.accent)
    view.shuffle_button:on_click("left")
    polygons = {}
    view.shuffle_button:draw()
    test.same(polygons[1].color, style.accent)
    view.state = "paused"
    view:update()
    rectangles, texts = {}, {}
    view.play_button:draw()
    test.equal(#rectangles, 0)
    test.equal(#texts, 1)
  end)
end)
