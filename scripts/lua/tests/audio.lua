local audio = require "audio"
local core = require "core"
local test = require "core.test"

local mono = { format = "s16le", channels = 1, sample_rate = 48000 }
local stereo = { format = "s16le", channels = 2, sample_rate = 48000 }
local pcm = string.pack("<i2i2i2i2", -32768, -1234, 1234, 32767)
local silence = string.rep("\0", 4800 * 2)
local resources

local function keep(value, err)
  test.not_nil(value, err)
  resources[#resources + 1] = value
  return value
end

local function failure(value, err)
  test.is_nil(value)
  test.type(err, "string")
  test.ok(#err > 0)
end

local function wait_until(fn)
  local deadline = system.get_time() + 5
  repeat
    if fn() then return end
    system.sleep(0.01)
  until system.get_time() >= deadline
  test.fail("audio operation did not complete within five seconds")
end

local function wav(data)
  return "RIFF" .. string.pack("<I4", 36 + #data) .. "WAVEfmt "
    .. string.pack("<I4I2I2I4I4I2I2", 16, 1, 1, 48000, 96000, 2, 16)
    .. "data" .. string.pack("<I4", #data) .. data
end

local function drain(stream)
  local chunks = {}
  while true do
    local chunk = assert(stream:read(4096))
    if chunk == "" then return table.concat(chunks) end
    chunks[#chunks + 1] = chunk
  end
end

test.describe("audio", function()
  test.before_each(function()
    resources = {}
  end)

  test.after_each(function()
    for i = #resources, 1, -1 do
      local object = resources[i]
      if object.close then object:close() else object:stop() end
    end
    resources = nil
    collectgarbage("collect")
  end)

  test.test("exports the documented module functions without initializing devices", function()
    for _, name in ipairs({
      "init", "get_driver", "get_drivers", "get_devices", "open_device",
      "load_wav", "decode_wav", "new_sound", "create_stream", "convert"
    }) do
      test.type(audio[name], "function", "missing audio." .. name)
    end
    test.equal(audio, _G.audio)
    local driver = audio.get_driver()
    test.type(audio.get_drivers(), "table")
    keep(audio.new_sound(pcm, mono))
    keep(audio.create_stream(mono, stereo))
    test.equal(#assert(audio.convert(pcm, mono, stereo)), #pcm * 2)
    test.equal(audio.get_driver(), driver)
  end)

  test.test("requires initialization on the main thread before worker device use", function()
    test.skip_if(audio.get_driver() ~= nil, "audio already initialized")
    local worker = assert(thread.create("audio-uninitialized", function()
      local audio = require "audio"
      assert(audio.get_driver() == nil)
      local ok, err = audio.init()
      assert(ok == nil and err:find("main thread", 1, true))
      local device, open_err = audio.open_device()
      assert(device == nil and open_err:find("main thread", 1, true))
      local spec = { format = "s16le", channels = 1, sample_rate = 48000 }
      assert(audio.convert("\0\0", spec, spec) == "\0\0")
      return 0
    end))
    test.equal(worker:wait(), 0)
    test.is_nil(audio.get_driver())
  end)

  test.test("copies sounds and normalizes all supported sample formats", function()
    for _, format in ipairs({
      "u8", "s8", "s16le", "s16be", "s32le", "s32be", "f32le", "f32be",
      "s16", "s32", "f32"
    }) do
      local spec = { format = format, channels = 2, sample_rate = 8000 }
      local data = string.rep("\0", 32)
      local sound = keep(audio.new_sound(data, spec))
      test.equal(sound:get_data(), data)
      test.equal(sound:get_size(), #data)
      local returned = sound:get_spec()
      test.equal(returned.channels, 2)
      test.equal(returned.sample_rate, 8000)
      test.contains({ format, format .. "le", format .. "be" }, returned.format)
      local bytes = format:find("32") and 4 or format:find("16") and 2 or 1
      test.near(sound:get_duration(), #data / (2 * bytes * 8000), 1e-9)
      returned.channels = 7
      test.equal(sound:get_spec().channels, 2)
      test.equal(audio.convert(data, spec, spec), data)
    end
  end)

  test.test("decodes WAV from memory and disk and rejects invalid WAV", function()
    local data = wav(pcm)
    local sound = keep(audio.decode_wav(data))
    test.same(sound:get_spec(), mono)
    test.equal(sound:get_data(), pcm)
    local path = core.temp_filename(".wav")
    local file = assert(io.open(path, "wb"))
    file:write(data)
    file:close()
    local loaded, err = audio.load_wav(path)
    os.remove(path)
    test.equal(keep(loaded, err):get_data(), pcm)
    failure(audio.load_wav(path))
    failure(audio.decode_wav("not a WAV file"))
    failure(audio.decode_wav(""))
    failure(audio.decode_wav(wav("")))
    test.error(function() audio.load_wav("file\0.wav") end, "NUL")
  end)

  test.test("validates specifications and complete PCM frames", function()
    test.error(function() audio.new_sound("", mono) end, "frames")
    test.error(function() audio.new_sound("\0", mono) end, "frames")
    test.error(function() audio.new_sound({}, mono) end)
    for _, field in ipairs({ "format", "channels", "sample_rate" }) do
      local invalid = { format = "s16le", channels = 1, sample_rate = 48000 }
      invalid[field] = nil
      test.error(function() audio.new_sound(pcm, invalid) end)
    end
    for _, channels in ipairs({ 0, -1, 1.5, 9, math.huge }) do
      test.error(function()
        audio.create_stream({ format = "u8", channels = channels, sample_rate = 8000 }, mono)
      end)
    end
    for _, rate in ipairs({ 0, -1, 0.5, math.huge, 0/0, 2147483648 }) do
      test.error(function()
        audio.new_sound(pcm, { format = "s16", channels = 1, sample_rate = rate })
      end)
    end
    test.error(function()
      audio.new_sound(pcm, { format = "mp3", channels = 1, sample_rate = 48000 })
    end, "format")
    test.error(function()
      audio.new_sound(pcm, { format = "s16le\0mp3", channels = 1, sample_rate = 48000 })
    end, "format")
    test.equal(audio.convert("", mono, stereo), "")
    test.error(function() audio.convert("\0", mono, stereo) end, "frames")
    test.error(function() audio.open_device("microphone") end)
    test.error(function() audio.open_device("recording", { max_voices = 1 }) end)
    for _, id in ipairs({ 0, -1, 1.5, math.huge, 4294967294 }) do
      test.error(function() audio.open_device("playback", { id = id }) end)
    end
    test.error(function() audio.open_device("playback", { max_voices = 0 }) end)
  end)

  test.test("converts endianness and channel counts", function()
    local big = { format = "s16be", channels = 1, sample_rate = 48000 }
    test.equal(audio.convert(pcm, mono, big), string.pack(">i2i2i2i2", -32768, -1234, 1234, 32767))
    local doubled = assert(audio.convert(pcm, mono, stereo))
    test.equal(doubled, string.pack("<i2i2i2i2i2i2i2i2", -32768, -32768, -1234, -1234, 1234, 1234, 32767, 32767))
  end)

  test.test("streams complete frames and distinguishes input and output queues", function()
    local stream = keep(audio.create_stream(mono, stereo))
    local input, output = stream:get_formats()
    test.same(input, mono)
    test.same(output, stereo)
    test.equal(stream:read(), "")
    test.equal(stream:write(""), 0)
    test.equal(stream:write(pcm), #pcm)
    test.equal(stream:get_queued_bytes(), #pcm)
    test.equal(stream:get_available_bytes(), #pcm * 2)
    test.ok(stream:flush())
    test.equal(#stream:read(7), 4)
    test.equal(#drain(stream), #pcm * 2 - 4)
    test.equal(stream:get_queued_bytes(), 0)
    test.equal(stream:get_available_bytes(), 0)
    test.error(function() stream:write("\0") end, "frames")
    for _, size in ipairs({ 0, -1, 1, 3, 4.5, math.huge }) do
      test.error(function() stream:read(size) end)
    end
    failure(stream:pause())
    failure(stream:resume())
    failure(stream:is_paused())
    stream:write(pcm)
    test.ok(stream:clear())
    test.equal(stream:read(), "")
  end)

  test.test("preserves resampling continuity across chunks", function()
    local output = { format = "f32le", channels = 2, sample_rate = 44100 }
    local data = pcm:rep(2000)
    local stream = keep(audio.create_stream(mono, output))
    for i = 1, #data, 200 do
      assert(stream:write(data:sub(i, i + 199)))
    end
    assert(stream:flush())
    test.equal(drain(stream), assert(audio.convert(data, mono, output)))
  end)

  test.test("applies stream gain and rate and retains controls when cleared", function()
    local spec = { format = "f32le", channels = 1, sample_rate = 48000 }
    local stream = keep(audio.create_stream(spec, spec))
    test.equal(stream:get_gain(), 1)
    test.equal(stream:get_rate(), 1)
    test.ok(stream:set_gain(0.5))
    test.equal(stream:write(string.pack("<ff", 0.25, -0.75)), 8)
    stream:flush()
    local a, b = string.unpack("<ff", assert(stream:read()))
    test.near(a, 0.125, 1e-6)
    test.near(b, -0.375, 1e-6)
    test.ok(stream:set_rate(2))
    stream:clear()
    test.equal(stream:get_gain(), 0.5)
    test.equal(stream:get_rate(), 2)
    stream:write(silence)
    stream:flush()
    test.equal(#drain(stream), #silence / 2)
    for _, value in ipairs({ -1, math.huge, 0/0 }) do
      test.error(function() stream:set_gain(value) end)
    end
    for _, value in ipairs({ 0, -1, 0.001, 101, math.huge, 0/0 }) do
      test.error(function() stream:set_rate(value) end)
    end
  end)

  test.test("makes closing offline objects idempotent and rejects later operations", function()
    local sound = keep(audio.new_sound(pcm, mono))
    sound:close()
    sound:close()
    failure(sound:get_spec())
    failure(sound:get_data())
    failure(sound:get_size())
    failure(sound:get_duration())
    local stream = keep(audio.create_stream(mono, stereo))
    stream:close()
    stream:close()
    failure(stream:write(pcm))
    failure(stream:read())
    failure(stream:flush())
    failure(stream:clear())
    failure(stream:get_gain())
    failure(stream:get_rate())
    failure(stream:get_queued_bytes())
    failure(stream:get_available_bytes())
    local input, output, err = stream:get_formats()
    test.is_nil(input)
    failure(output, err)
  end)

  test.test("rejects effective sample rates that overflow or round to zero in SDL", function()
    local slow = { format = "s16le", channels = 1, sample_rate = 1 }
    local huge = { format = "s16le", channels = 1, sample_rate = 2147483647 }
    local stream = keep(audio.create_stream(slow, mono))
    failure(stream:set_rate(0.01))
    test.equal(stream:get_rate(), 1)
    failure(audio.create_stream(huge, mono))
    failure(audio.convert(pcm, huge, mono))
    failure(audio.open_device("playback", { spec = huge }))
  end)

  test.describe("dummy devices", function()
    test.before_each(function()
      -- Never open the user's speakers or microphone as part of the test suite.
      test.skip_if(os.getenv("SDL_AUDIO_DRIVER") ~= "dummy", "requires SDL_AUDIO_DRIVER=dummy")
      test.ok(audio.init())
      test.equal(audio.get_driver(), "dummy")
    end)

    test.test("enumerates and independently controls logical devices", function()
      test.ok(audio.init())
      test.contains(audio.get_drivers(), "dummy")
      local devices = assert(audio.get_devices())
      test.ok(#devices > 0)
      test.type(devices[1].id, "number")
      test.type(devices[1].name, "string")
      test.equal(devices[1].kind, "playback")
      local first = keep(audio.open_device())
      local second = keep(audio.open_device("playback", { id = devices[1].id, max_voices = 2, spec = mono }))
      test.ok(first:is_paused())
      test.ok(second:is_paused())
      local info = first:get_info()
      test.equal(info.kind, "playback")
      test.ok(info.follows_default)
      test.ok(info.buffer_frames > 0)
      test.equal(info.max_voices, 64)
      test.not_equal(info.id, devices[1].id)
      test.not_ok(second:get_info().follows_default)
      test.equal(second:get_info().max_voices, 2)
      test.ok(first:set_gain(0.5))
      test.equal(first:get_gain(), 0.5)
      test.equal(second:get_gain(), 1)
      test.ok(first:resume())
      test.not_ok(first:is_paused())
      test.ok(second:is_paused())
      first:close()
      first:close()
      failure(first:get_info())
      failure(first:resume())
      failure(first:get_gain())
      test.ok(second:resume())
      failure(audio.open_device("recording", { id = devices[1].id }))
      failure(audio.open_device("playback", { id = second:get_info().id }))
    end)

    test.test("pauses streams individually and closes children with their device", function()
      local device = keep(audio.open_device())
      local first = keep(device:create_stream(mono))
      local second = keep(device:create_stream(stereo))
      test.ok(first:is_paused())
      assert(first:write(silence))
      assert(first:pause())
      assert(device:resume())
      test.ok(first:is_paused())
      test.not_ok(second:is_paused())
      system.sleep(0.05)
      test.equal(first:get_queued_bytes(), #silence)
      assert(first:resume())
      assert(first:flush())
      wait_until(function() return first:get_queued_bytes() == 0 end)
      failure(first:read())
      assert(device:pause())
      assert(first:resume())
      test.ok(first:is_paused())
      device:close()
      failure(first:write(pcm))
      failure(second:resume())
      failure(device:create_stream(mono))
    end)

    test.test("records dummy PCM without touching a real microphone", function()
      local devices = assert(audio.get_devices("recording"))
      test.ok(#devices > 0)
      test.equal(devices[1].kind, "recording")
      local device = keep(audio.open_device("recording", { id = devices[1].id }))
      local stream = keep(device:create_stream(mono))
      test.equal(device:get_info().kind, "recording")
      test.is_nil(device:get_info().max_voices)
      local _, output = stream:get_formats()
      test.same(output, mono)
      test.equal(stream:read(), "")
      failure(stream:write(pcm))
      failure(device:play(keep(audio.new_sound(pcm, mono))))
      assert(device:resume())
      wait_until(function() return stream:get_available_bytes() > 0 end)
      assert(stream:pause())
      assert(stream:flush())
      local data = drain(stream)
      test.ok(#data > 0)
      test.equal(#data % 2, 0)
      assert(stream:clear())
      system.sleep(0.05)
      test.equal(stream:read(), "")
      assert(stream:resume())
      wait_until(function() return stream:get_available_bytes() > 0 end)
    end)

    test.test("supports overlapping voices with independent gain rate and pause", function()
      local device = keep(audio.open_device())
      local sound = keep(audio.new_sound(silence, mono))
      local first = keep(device:play(sound, { paused = true, gain = 0.5, rate = 2 }))
      local second = keep(device:play(sound, { loop = true }))
      test.equal(first:get_state(), "paused")
      test.equal(second:get_state(), "paused")
      assert(device:resume())
      test.equal(first:get_state(), "paused")
      test.equal(second:get_state(), "playing")
      test.equal(first:get_gain(), 0.5)
      test.equal(first:get_rate(), 2)
      test.equal(second:get_gain(), 1)
      test.equal(second:get_rate(), 1)
      assert(second:set_gain(0.25))
      assert(second:set_rate(0.5))
      assert(second:pause())
      assert(first:resume())
      wait_until(function() return first:get_state() == "finished" end)
      first:stop()
      test.equal(first:get_state(), "finished")
      failure(first:resume())
      failure(first:set_rate(1))
      test.equal(first:get_gain(), 0.5)
      test.equal(first:get_rate(), 2)
      second:stop()
      second:stop()
      test.equal(second:get_state(), "stopped")
      test.equal(second:get_gain(), 0.25)
      test.equal(second:get_rate(), 0.5)
    end)

    test.test("retains closed sounds and enforces voice limits without stealing", function()
      local device = keep(audio.open_device("playback", { max_voices = 1 }))
      local sound = keep(audio.new_sound("\0\0", mono))
      local voice = keep(device:play(sound, { loop = true, paused = true }))
      failure(device:play(sound))
      sound:close()
      failure(device:play(sound))
      assert(device:resume())
      assert(voice:resume())
      system.sleep(0.15)
      test.equal(voice:get_state(), "playing")
      voice:stop()
      local next_sound = keep(audio.new_sound(silence, mono))
      local next_voice = keep(device:play(next_sound))
      wait_until(function() return next_voice:get_state() == "finished" end)
      keep(device:play(next_sound))
      device:close()
      test.equal(voice:get_state(), "stopped")
    end)

    test.test("continues playback when voice handles are collected", function()
      local device = keep(audio.open_device("playback", { max_voices = 1 }))
      local sound = keep(audio.new_sound(silence, mono))
      assert(device:play(sound, { loop = true }))
      collectgarbage("collect")
      assert(device:resume())
      system.sleep(0.15)
      failure(device:play(sound))
      device:close()
    end)

    test.test("reclaims finished voices without a Lua update pump", function()
      local device = keep(audio.open_device("playback", { max_voices = 1 }))
      local sound = keep(audio.new_sound("\0\0", mono))
      assert(device:resume())
      for _ = 1, 5 do
        wait_until(function() return device:play(sound) ~= nil end)
        collectgarbage("collect")
        system.sleep(0.15)
      end
      local voice
      wait_until(function()
        voice = device:play(sound)
        return voice ~= nil
      end)
      keep(voice)
    end)

    test.test("collecting a device closes its children but not another device", function()
      local other = keep(audio.open_device())
      local device = assert(audio.open_device())
      local sound = keep(audio.new_sound(silence, mono))
      local voice = keep(device:play(sound, { loop = true }))
      local stream = keep(device:create_stream(mono))
      device = nil
      collectgarbage("collect")
      failure(stream:write(pcm))
      test.equal(voice:get_state(), "stopped")
      test.ok(other:resume())
      keep(other:play(sound))
    end)

    test.test("handles objects closed by option table metamethods", function()
      local device = keep(audio.open_device())
      local sound = keep(audio.new_sound(silence, mono))
      failure(device:play(sound, setmetatable({}, { __index = function()
        sound:close()
      end })))
      local spec = setmetatable({}, { __index = function(_, key)
        device:close()
        return mono[key]
      end })
      failure(device:create_stream(spec))
    end)

    test.test("validates playback options and voice controls", function()
      local device = keep(audio.open_device())
      local sound = keep(audio.new_sound(silence, mono))
      for _, options in ipairs({ { loop = 1 }, { paused = 1 }, { gain = -1 }, { rate = 0 } }) do
        test.error(function() device:play(sound, options) end)
      end
      local voice = keep(device:play(sound))
      local slow = keep(audio.new_sound(pcm, { format = "s16le", channels = 1, sample_rate = 1 }))
      failure(device:play(slow, { rate = 0.01 }))
      local slow_voice = keep(device:play(slow, { paused = true }))
      failure(slow_voice:set_rate(0.01))
      test.error(function() voice:set_gain(-1) end)
      test.error(function() device:set_gain(math.huge) end)
      test.error(function() voice:set_rate(101) end)
      test.ok(voice:set_gain(0))
      test.ok(voice:set_rate(0.01))
      test.ok(voice:set_rate(100))
      device:close()
      test.equal(voice:get_state(), "stopped")
    end)

    test.test("supports initialized worker devices and releases them on state exit", function()
      local device = keep(audio.open_device())
      local sound = keep(audio.new_sound(silence, mono))
      local survivor = keep(device:play(sound, { loop = true }))
      assert(device:resume())
      local worker = assert(thread.create("audio-worker", function(data, spec)
        local audio = require "audio"
        assert(audio.init())
        local device = assert(audio.open_device())
        local sound = assert(audio.new_sound(data, spec))
        local stream = assert(device:create_stream(spec))
        assert(stream:write(data))
        assert(device:play(sound, { loop = true }))
        assert(device:resume())
        sound:close()
        -- Lua-state teardown, rather than explicit closes, owns cleanup here.
        return 0
      end, silence, mono))
      test.equal(worker:wait(), 0)
      test.equal(survivor:get_state(), "playing")
    end)
  end)
end)
