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
      "get_driver", "get_drivers", "get_devices", "get_decoders", "create_mixer",
      "load", "load_memory", "open_recording", "new_sound", "create_stream", "convert"
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

  test.test("rejects worker devices while allowing worker offline audio", function()
    test.skip_if(audio.get_driver() ~= nil, "audio already initialized")
    local worker = assert(thread.create("audio-uninitialized", function()
      local audio = require "audio"
      assert(audio.get_driver() == nil)
      local ok, err = audio.get_devices()
      assert(ok == nil and err:find("main thread", 1, true))
      local device, open_err = audio.create_mixer()
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
    local sound = keep(audio.load_memory(data))
    test.same(sound:get_spec(), mono)
    test.equal(sound:get_data(), pcm)
    local path = core.temp_filename(".wav")
    local file = assert(io.open(path, "wb"))
    file:write(data)
    file:close()
    local loaded, err = audio.load(path)
    os.remove(path)
    test.equal(keep(loaded, err):get_data(), pcm)
    failure(audio.load(path))
    failure(audio.load_memory("not a WAV file"))
    failure(audio.load_memory("not a WAV file", { predecode = true }))
    failure(audio.load_memory(""))
    test.error(function() audio.load("file\0.wav") end, "NUL")
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
    test.error(function() audio.create_mixer("microphone") end)
    test.error(function() audio.create_mixer({ offline = true }) end)
    for _, id in ipairs({ 0, -1, 1.5, math.huge, 4294967294 }) do
      test.error(function() audio.create_mixer({ id = id }) end)
    end
    test.error(function() audio.create_mixer({ max_voices = 0 }) end)
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
    failure(audio.create_mixer({ spec = huge }))
  end)


  local float = { format = "f32le", channels = 1, sample_rate = 48000 }
  local function mixer(options)
    options = options or {}
    options.offline = true
    options.spec = options.spec or float
    return keep(audio.create_mixer(options))
  end

  local function tone(frames, value)
    return keep(audio.new_sound(string.pack("<f", value or 0.5):rep(frames or 4800), float))
  end

  local function sample(data, index)
    return (string.unpack("<f", data, (index or 0) * 4 + 1))
  end

  local function render_float(mix, frames, spec)
    spec = spec or float
    local data, count, err = mix:render(frames)
    test.type(data, "string", err)
    test.type(count, "number", err)
    test.ok(count >= 0 and count <= frames,
      string.format("render(%d) reported %s mixed frames", frames, tostring(count)))
    test.equal(count, math.floor(count))
    local frame_size = 4 * spec.channels
    test.equal(#data, frames * frame_size)
    -- Allow at most 0.5 ms of filter ringing at the resampled audio boundary.
    local tolerance = math.ceil(spec.sample_rate * 0.0005)
    local padding_start = math.min(count + tolerance, frames)
    test.ok(data:sub(padding_start * frame_size + 1)
        == string.rep("\0", (frames - padding_start) * frame_size),
      string.format("render(%d) returned non-silent padding beyond frame %d", frames, padding_start))
    return data, count, tolerance
  end

  test.test("enumerates bundled decoders and removes the old API", function()
    local names = table.concat(assert(audio.get_decoders()), " "):lower()
    for _, name in ipairs({ "wav", "flac", "mp3", "vorbis", "opus" }) do
      test.ok(names:find(name, 1, true), names)
    end
    for _, name in ipairs({ "init", "open_device", "load_wav", "decode_wav" }) do
      test.is_nil(audio[name])
    end
  end)

  test.test("renders offline with exact padding and natural completion", function()
    local mix = mixer()
    test.same(mix:get_info().spec, float)
    test.is_nil(mix:get_info().device)
    local v = keep(mix:play(tone(4)))
    local data, frames = assert(mix:render(16))
    test.equal(#data, 64)
    test.equal(frames, 4)
    for i = 0, 3 do test.near(sample(data, i), 0.5, 1e-6) end
    test.equal(data:sub(17), string.rep("\0", 48))
    test.equal(v:get_state(), "finished")
    local empty, count = mix:render(16)
    test.equal(count, 0)
    test.equal(empty, string.rep("\0", 64))
    local u8 = mixer({ spec = { format = "u8", channels = 1, sample_rate = 8000 } })
    test.equal(u8:render(16), string.rep(string.char(128), 16))
    test.error(function() mix:render(0) end)
  end)

  test.test("retains closed sounds and reclaims finished voice slots", function()
    local mix = mixer({ max_voices = 1 })
    local sound = tone(100)
    local v = keep(mix:play(sound, { loops = -1 }))
    sound:close()
    collectgarbage("collect")
    failure(mix:play(tone()))
    assert(mix:render(500))
    test.equal(v:get_state(), "playing")
    v:stop()
    local finished = keep(mix:play(tone(2)))
    mix:render(8)
    test.equal(finished:get_state(), "finished")
    assert(finished:stop())
    test.equal(finished:get_state(), "finished")
    keep(mix:play(tone()))
    mix:close()
    failure(mix:play(tone()))
    failure(mix:get_info())
  end)

  test.test("combines persistent group controls and independent pause flags", function()
    local mix = mixer()
    local group = assert(mix:group("music"))
    test.equal(mix:group("music"), group)
    assert(group:set_gain(0.5))
    assert(mix:set_gain(0.5))
    assert(group:pause())
    local v = keep(group:play(tone(), { gain = 0.5, paused = true }))
    test.equal(v:get_state(), "paused")
    test.equal(select(2, mix:render(8)), 0)
    assert(group:resume())
    test.equal(v:get_state(), "paused")
    assert(v:resume())
    test.near(sample((assert(mix:render(8)))), 0.0625, 1e-6)
    assert(group:pause())
    assert(mix:pause())
    assert(group:resume())
    test.equal(v:get_state(), "paused")
    assert(mix:resume())
    test.equal(v:get_state(), "playing")
    assert(group:stop())
    test.equal(v:get_state(), "stopped")
    local next_voice = keep(group:play(tone(), { gain = 0.5 }))
    test.equal(group:get_gain(), 0.5)
    test.equal(next_voice:get_gain(), 0.5)
    mix:close()
    failure(group:play(tone()))
    failure(group:resume())
  end)

  test.test("uses absolute loop boundaries and exact repeat counts", function()
    local mix = mixer()
    local sound = keep(audio.new_sound(string.pack("<ffffff", 0.1, 0.2, 0.3, 0.4, 0.5, 0.6), float))
    local v = keep(mix:play(sound, {
      start = 1 / 48000, loop_start = 2 / 48000, loop_end = 5 / 48000, loops = 2
    }))
    local result, count = mix:render(32)
    test.equal(count, 10)
    for i, expected in ipairs({ 0.2, 0.3, 0.4, 0.5, 0.3, 0.4, 0.5, 0.3, 0.4, 0.5 }) do
      test.near(sample(result, i - 1), expected, 1e-6)
    end
    test.equal(v:get_state(), "finished")
    failure(mix:play(sound, { loop_end = 1 / 48000, start = 2 / 48000 }))
    failure(mix:play(sound, { loops = 1, loop_start = 6 / 48000 }))
    failure(mix:play(sound, { start = 100 }))
    failure(mix:play(sound, { loop_end = 100 }))
  end)

  test.test("seeks paused sources and applies stereo balance", function()
    local spec = { format = "f32le", channels = 2, sample_rate = 48000 }
    local mix = mixer({ spec = spec })
    local sound = keep(audio.new_sound(string.pack("<ff", 0.2, 0.6):rep(4096), spec))
    local v = keep(mix:play(sound, { paused = true, pan = -1 }))
    test.equal(v:get_pan(), -1)
    assert(v:seek(0.01))
    test.near(v:get_position(), 0.01, 1e-6)
    assert(v:resume())
    local data = assert(mix:render(64))
    test.near(sample(data, 0), 0.2, 1e-6)
    test.near(sample(data, 1), 0, 1e-6)
    assert(v:set_pan(1))
    data = assert(mix:render(64))
    test.near(sample(data, 0), 0, 1e-6)
    test.near(sample(data, 1), 0.6, 1e-6)
    assert(v:set_pan(nil))
    test.is_nil(v:get_pan())
    failure(v:seek(100))
  end)

  test.test("validates synchronized starts before changing any voice", function()
    local mix = mixer()
    local a = keep(mix:play(tone(), { paused = true }))
    local b = keep(mix:play(tone(), { paused = true }))
    local foreign = keep(mixer():play(tone(), { paused = true }))
    failure(mix:resume_together({ a, foreign }))
    test.equal(a:get_state(), "paused")
    test.error(function() mix:resume_together({ a, a }) end, "duplicate")
    assert(mix:pause())
    failure(mix:resume_together({ a, b }))
    assert(mix:resume())
    assert(mix:resume_together({ a, b }))
    test.near(sample((assert(mix:render(16)))), 1, 1e-6)
    failure(mix:resume_together({ a, b }))
  end)

  test.test("handles generated underruns, pause, clear, finish and sealed writes", function()
    local mix = mixer()
    local v = keep(mix:play_stream(float))
    failure(v:seek(0))
    failure(v:get_position())
    mix:render(128)
    test.equal(v:get_state(), "playing")
    local data = string.pack("<f", 0.25):rep(128)
    test.equal(v:write(data), #data)
    test.equal(v:get_queued_bytes(), #data)
    assert(v:clear())
    test.equal(v:get_queued_bytes(), 0)
    assert(v:write(data))
    assert(v:pause())
    assert(v:finish())
    assert(v:finish())
    test.equal(v:get_state(), "paused")
    failure(v:write(data))
    failure(v:clear())
    assert(v:resume())
    local result, count = mix:render(256)
    test.equal(count, 128)
    test.near(sample(result), 0.25, 1e-6)
    test.equal(v:get_state(), "finished")
    test.equal(v:get_queued_bytes(), 0)
    assert(v:finish())
    local empty = keep(mix:play_stream(float))
    assert(empty:finish())
    mix:render(256)
    test.equal(empty:get_state(), "finished")
  end)

  test.test("preserves generated resampling across finish", function()
    local out = { format = "f32le", channels = 2, sample_rate = 44100 }
    local mix = mixer({ spec = out })
    local data = pcm:rep(2000)
    local voice = keep(mix:play_stream(mono))
    for i = 1, #data, 2048 do assert(voice:write(data:sub(i, i + 2047))) end
    assert(voice:finish())
    local expected = assert(audio.convert(data, mono, out))
    local rendered, count, tolerance = render_float(mix, 10000, out)
    local expected_frames = #expected / 8
    test.near(count, expected_frames, tolerance)
    for i = tolerance * 2, (math.min(count, expected_frames) - tolerance) * 2 - 1 do
      test.near(sample(rendered, i), math.max(-1, math.min(1, sample(expected, i))), 1e-5)
    end
    test.equal(voice:get_state(), "finished")
  end)

  test.test("applies voice and mixer rate to the rendered signal", function()
    local mix = mixer()
    assert(mix:set_rate(2))
    local v = keep(mix:play(tone(4800), { rate = 2 }))
    local rendered, frames = assert(mix:render(6000))
    test.equal(#rendered, 6000 * 4)
    test.type(frames, "number")
    test.ok(frames >= 0)
    test.equal(frames, math.floor(frames))
    local audible_frames = 0
    for i = 0, #rendered / 4 - 1 do
      local value = sample(rendered, i)
      test.ok(math.abs(value) <= 1, "invalid output sample")
      if math.abs(value) > 1e-5 then audible_frames = i + 1 end
    end
    -- Upstream reports pre-resampling counts; measure the signal instead.
    test.near(audible_frames, 4800 / (2 * 2), math.ceil(float.sample_rate * 0.0005))
    test.equal(v:get_state(), "finished")
    test.equal(v:get_rate(), 2)
    test.equal(mix:get_rate(), 2)
  end)

  test.test("fades in and stops without restarting a pending fade", function()
    local mix = mixer()
    local voice = keep(mix:play(tone(48000), { fade_in = 0.01 }))
    local result = assert(mix:render(480))
    test.ok(sample(result, 0) < 0.01)
    test.ok(sample(result, 479) > 0.45)
    assert(voice:stop({ fade_out = 0.01 }))
    mix:render(240)
    assert(voice:stop({ fade_out = 0.1 }))
    mix:render(481)
    test.equal(voice:get_state(), "stopped")
    local paused = keep(mix:play(tone(), { paused = true }))
    assert(paused:stop({ fade_out = 10 }))
    test.equal(paused:get_state(), "stopped")
  end)

  test.test("queues protected callbacks outside mixing", function()
    local mix = mixer()
    local calls, reasons = 0, {}
    local function completed(voice, reason, err)
      calls = calls + 1
      reasons[reason] = true
      test.is_nil(err)
      test.contains({ "finished", "stopped" }, voice:get_state())
      failure(mix:dispatch_events())
      error("expected callback error")
    end
    local done = keep(mix:play(tone(4), { on_complete = completed }))
    local stopped = keep(mix:play(tone(), { paused = true, on_complete = completed }))
    assert(stopped:stop())
    mix:render(16)
    test.equal(done:get_state(), "finished")
    test.equal(calls, 0)
    local count, err = mix:dispatch_events()
    test.equal(count, 2)
    test.ok(err:find("expected callback error", 1, true))
    test.equal(calls, 2)
    test.ok(reasons.finished and reasons.stopped)
    test.equal(mix:dispatch_events(), 0)
  end)

  test.test("defers new completions and cancels pending callbacks on close", function()
    local mix = mixer()
    local calls = 0
    keep(mix:play(tone(1), { on_complete = function()
      calls = calls + 1
      local new = assert(mix:play_stream(float, { on_complete = function() calls = calls + 1 end }))
      new:stop()
    end }))
    mix:render(16)
    test.equal(mix:dispatch_events(), 1)
    test.equal(calls, 1)
    test.equal(mix:dispatch_events(), 1)
    test.equal(calls, 2)
    for _ = 1, 3 do
      keep(mix:play(tone(1), { on_complete = function() calls = calls + 1; mix:close() end }))
    end
    mix:render(16)
    test.equal(mix:dispatch_events(), 1)
    test.equal(calls, 3)
    failure(mix:dispatch_events())
  end)

  test.test("automatically dispatches main-thread completions through event polling", function()
    local mix = mixer()
    local completed = false
    keep(mix:play(tone(1), { on_complete = function() completed = true end }))
    mix:render(16)
    test.not_ok(completed)
    system.poll_event()
    test.ok(completed)
  end)

  test.test("closes children through mixer GC despite retained groups and voices", function()
    local mix = assert(audio.create_mixer({ offline = true, spec = float }))
    local group = assert(mix:group("effects"))
    local voice = keep(group:play(tone(), { loops = -1 }))
    mix = nil
    collectgarbage("collect")
    test.equal(voice:get_state(), "stopped")
    failure(group:resume())
    test.ok(voice:stop())
  end)

  test.test("keeps discarded handles playing and callback cycles collectible", function()
    local mix = mixer({ max_voices = 1 })
    assert(mix:play(tone(), { loops = -1 }))
    collectgarbage("collect")
    failure(mix:play(tone()))
    test.near(sample((assert(mix:render(16)))), 0.5, 1e-6)
    for _ = 1, 50 do
      local owner = assert(audio.create_mixer({ offline = true, spec = float }))
      local holder = { owner }
      assert(owner:play_stream(float, { on_complete = function() holder[1]:stop() end }))
    end
    collectgarbage("collect")
    collectgarbage("collect")
  end)

  test.test("rechecks owners closed by option table metamethods", function()
    local mix, sound = mixer(), tone()
    failure(mix:play(sound, setmetatable({}, { __index = function() sound:close() end })))
    local spec = setmetatable({}, { __index = function(_, key)
      mix:close()
      return float[key]
    end })
    failure(mix:play_stream(spec))
  end)

  test.test("streams files and predecodes reusable assets", function()
    local path = core.temp_filename(".wav")
    local file = assert(io.open(path, "wb"))
    file:write(wav(pcm:rep(200)))
    file:close()
    local mix = mixer({ spec = mono })
    local sound = keep(audio.load(path, { predecode = true }))
    test.equal(sound:get_data(), pcm:rep(200))
    test.equal(sound:get_size(), #pcm * 200)
    test.same(sound:get_metadata(), {})
    local voice = keep(mix:play_file(path, { paused = true, loops = 1 }))
    assert(voice:seek(0.001))
    assert(voice:resume())
    assert(mix:render(4096))
    test.equal(voice:get_state(), "finished")
    os.remove(path)
    failure(mix:play_file(path))
    local from_memory = keep(audio.load_memory(wav(pcm), { predecode = true }))
    test.equal(from_memory:get_data(), pcm)
    test.equal(from_memory:get_size(), #pcm)
  end)

  test.test("rejects invalid options and inappropriate voice operations", function()
    local mix, sound = mixer(), tone()
    for _, options in ipairs({
      { loop = true }, { loops = 1.5 }, { loops = -2 }, { rate = 0 },
      { gain = -1 }, { pan = 2 }, { on_complete = true }, { paused = 1 }
    }) do test.error(function() mix:play(sound, options) end) end
    test.error(function() mix:play_stream(float, { loops = 1 }) end)
    test.error(function() mix:play_stream(float, { start = 0.5 }) end)
    local voice = keep(mix:play(sound))
    failure(voice:write(pcm))
    failure(voice:clear())
    failure(voice:finish())
    failure(voice:get_queued_bytes())
    test.error(function() voice:set_rate(101) end)
    test.error(function() mix:set_gain(math.huge) end)
    mix:close()
    failure(voice:seek(0))
    failure(voice:resume())
    failure(voice:set_gain(1))
  end)

  test.test("decodes compressed fixtures from memory and seekable files", function()
    local dir = debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])")
    for _, ext in ipairs({ "flac", "mp3", "ogg", "opus" }) do
      local path = dir .. "fixtures/audio/tone." .. ext
      local file = assert(io.open(path, "rb"))
      local data = file:read("*a")
      file:close()
      local encoded = keep(audio.load_memory(data))
      local decoded = keep(audio.load(path, { predecode = true }))
      test.equal(encoded:get_size(), #data)
      test.ok(decoded:get_size() > 0)
      test.equal(encoded:get_data(), decoded:get_data())
      test.near(encoded:get_duration(), 0.1, 0.06)
      test.equal(encoded:get_metadata().title, "Pragtical audio test")
      test.equal(decoded:get_metadata().title, "Pragtical audio test")
      local mix = mixer({ spec = encoded:get_spec() })
      local voice = keep(mix:play_file(path, { start = 0.02, loops = 1, loop_start = 0.02, loop_end = 0.08 }))
      local result, count = mix:render(20000)
      test.ok(count > 0 and count < 20000)
      test.ok(#result > 0)
      test.equal(voice:get_state(), "finished")
    end
  end)

  test.test("renders audio across playback-sized chunks without resampling", function()
    local source = tone(4800)
    for _, size in ipairs({ 512, 1024, 4096 }) do
      local mix = mixer()
      local voice = keep(mix:play(source))
      local offset, sum = 0, 0
      for _ = 1, math.ceil(4800 / size) + 1 do
        local data, frames = render_float(mix, size)
        for i = 0, size - 1 do
          test.near(sample(data, i), offset + i < 4800 and 0.5 or 0, 1e-6)
        end
        offset = offset + size
        sum = sum + frames
      end
      test.equal(sum, 4800)
      test.equal(voice:get_state(), "finished")
    end
  end)

  test.test("finish preserves an in-progress fade and does not resume parents", function()
    local mix = mixer()
    local group = assert(mix:group("synth"))
    local voice = keep(group:play_stream(float, { fade_in = 0.01 }))
    assert(voice:write(string.pack("<f", 0.5):rep(1000)))
    mix:render(240)
    assert(group:pause())
    assert(voice:finish())
    test.equal(voice:get_state(), "paused")
    assert(group:resume())
    local tail = assert(mix:render(1024))
    test.near(sample(tail), 0.25, 0.01)
    test.equal(voice:get_state(), "finished")
  end)

  test.test("creates and tears down offline audio on worker states", function()
    local worker = assert(thread.create("audio-offline", function()
      local audio = require "audio"
      local spec = { format = "s16le", channels = 1, sample_rate = 48000 }
      local mix = assert(audio.create_mixer({ offline = true, spec = spec }))
      local sound = assert(audio.new_sound("\0\0", spec))
      local done = false
      assert(mix:play(sound, { on_complete = function() done = true end }))
      sound:close()
      local data, count = mix:render(64)
      assert(#data == 128 and count == 1)
      assert(mix:dispatch_events() == 1 and done)
      local device, err = audio.create_mixer()
      assert(not device and err:find("main thread", 1, true))
      assert(mix:play_stream(spec))
      return 0
    end))
    test.equal(worker:wait(), 0)
  end)

  test.describe("exact mixer generation", function()
    test.before_each(function()
      test.skip_if(os.getenv("PRAGTICAL_AUDIO_EXACT") ~= "1",
        "requires PRAGTICAL_AUDIO_EXACT=1 and the optional SDL_mixer patch")
    end)

    test.test("reports output frame counts after combined rate changes", function()
      local mix = mixer()
      assert(mix:set_rate(2))
      local voice = keep(mix:play(tone(4800), { rate = 2 }))
      local _, frames, tolerance = render_float(mix, 6000)
      test.near(frames, 4800 / (2 * 2), tolerance)
      test.equal(voice:get_state(), "finished")
    end)

    test.test("preserves resampling across playback-sized render chunks", function()
      for _, rate in ipairs({ 0.5, 1, 2 }) do
        local source = tone(4800)
        local whole = mixer()
        assert(whole:set_rate(rate))
        local first = keep(whole:play(source, { rate = 1.5 }))
        local expected, count, tolerance = render_float(whole, 16384)
        test.equal(first:get_state(), "finished")
        for _, size in ipairs({ 512, 1024, 4096 }) do
          local chunked = mixer()
          assert(chunked:set_rate(rate))
          local second = keep(chunked:play(source, { rate = 1.5 }))
          local chunks, sum = {}, 0
          for i = 1, 16384 / size do
            local data, frames = render_float(chunked, size)
            chunks[i] = data
            sum = sum + frames
          end
          local actual = table.concat(chunks)
          test.near(sum, count, tolerance)
          for i = tolerance, math.min(sum, count) - tolerance - 1 do
            test.near(sample(actual, i), sample(expected, i), 1e-5)
          end
          test.equal(second:get_state(), "finished")
        end
      end
    end)
  end)

  test.describe("stress", function()
    test.before_each(function()
      test.skip_if(os.getenv("PRAGTICAL_AUDIO_STRESS") ~= "1",
        "requires PRAGTICAL_AUDIO_STRESS=1; use an external timeout")
    end)

    test.test("preserves resampler tails and counts across four-frame render chunks", function()
      for _, rate in ipairs({ 0.5, 1, 2 }) do
        local source = tone(400)
        local whole, chunked = mixer(), mixer()
        assert(whole:set_rate(rate))
        assert(chunked:set_rate(rate))
        local first = keep(whole:play(source, { rate = 1.5 }))
        local second = keep(chunked:play(source, { rate = 1.5 }))
        local expected, count = render_float(whole, 2048)
        local chunks, sum = {}, 0
        for i = 1, 512 do
          local data, frames = render_float(chunked, 4)
          chunks[i] = data
          sum = sum + frames
        end
        local actual = table.concat(chunks)
        test.equal(sum, count)
        for i = 0, 2047 do test.near(sample(actual, i), sample(expected, i), 1e-5) end
        test.equal(first:get_state(), "finished")
        test.equal(second:get_state(), "finished")
      end
    end)

    test.test("loops one mono frame into stereo output", function()
      local spec = { format = "f32le", channels = 2, sample_rate = 48000 }
      local mix = mixer({ spec = spec })
      local voice = keep(mix:play(tone(1), { loops = -1 }))
      local data, count = render_float(mix, 64, spec)
      test.equal(count, 64)
      for i = 0, 127 do test.near(sample(data, i), 0.5, 1e-6) end
      test.equal(voice:get_state(), "playing")
      assert(voice:stop())
      mix:close()
    end)
  end)

  test.describe("dummy devices", function()
    test.before_each(function()
      test.skip_if(os.getenv("SDL_AUDIO_DRIVER") ~= "dummy", "requires SDL_AUDIO_DRIVER=dummy")
      test.ok(#assert(audio.get_devices()) > 0)
      test.equal(audio.get_driver(), "dummy")
    end)

    test.test("independently controls logical playback devices", function()
      local devices = assert(audio.get_devices())
      local first = keep(audio.create_mixer())
      local second = keep(audio.create_mixer({ id = devices[1].id, spec = mono }))
      local info = assert(first:get_info())
      test.equal(info.device.kind, "playback")
      test.ok(info.device.follows_default)
      test.ok(info.device.buffer_frames > 0)
      test.not_equal(info.device.id, devices[1].id)
      test.not_ok(second:get_info().device.follows_default)
      assert(first:pause())
      test.ok(first:is_paused())
      test.not_ok(second:is_paused())
      assert(first:set_gain(0.5))
      test.equal(first:get_gain(), 0.5)
      test.equal(second:get_gain(), 1)
      failure(audio.create_mixer({ id = info.device.id }))
      local a, b, err = first:render(16)
      test.is_nil(a)
      failure(b, err)
      first:close()
      test.ok(second:resume())
    end)

    test.test("records dummy PCM without opening a real microphone", function()
      local devices = assert(audio.get_devices("recording"))
      test.ok(#devices > 0)
      local stream = keep(audio.open_recording(mono, { id = devices[1].id }))
      test.ok(stream:is_paused())
      test.equal(stream:get_device_info().kind, "recording")
      local _, output = stream:get_formats()
      test.same(output, mono)
      failure(stream:write(pcm))
      test.equal(stream:read(), "")
      assert(stream:resume())
      wait_until(function() return stream:get_available_bytes() > 0 end)
      assert(stream:pause())
      assert(stream:flush())
      test.ok(#drain(stream) > 0)
      assert(stream:clear())
      system.sleep(0.05)
      test.equal(stream:read(), "")
      stream:close()
      failure(stream:get_device_info())
      failure(stream:resume())
      failure(audio.open_recording(mono, { id = audio.get_devices()[1].id }))
    end)

    test.test("reclaims finished tracks without a Lua render or event pump", function()
      local mix = keep(audio.create_mixer({ max_voices = 1 }))
      local sound = tone(4800)
      for _ = 1, 5 do
        wait_until(function() return mix:play(sound) ~= nil end)
        collectgarbage("collect")
        system.sleep(0.1)
      end
      local looped
      wait_until(function()
        looped = mix:play(sound, { loops = -1 })
        return looped ~= nil
      end)
      keep(looped)
      system.sleep(0.1)
      failure(mix:play(sound))
      mix:close()
    end)
  end)
end)
