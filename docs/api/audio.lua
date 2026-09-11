---@meta

---
---Provides independent playback/recording devices, PCM streams, reusable sounds,
---and overlapping playback voices. SDL handles stream conversion and mixing;
---sound ownership, voice limits, looping, and individual pause are wrapper features.
---Only WAV decoding and uncompressed PCM are included. Compressed music decoders,
---spatial audio, seeking, independent pitch shifting, and DSP callbacks are not.
---
---Operational failures return nil, errmsg. Invalid argument types, formats, ranges,
---or PCM frame alignment raise Lua errors. close() and stop() are idempotent.
---Rate/spec combinations outside SDL's conversion range return nil, errmsg.
---Device opening and WAV loading can block; stream I/O never waits for hardware,
---but can still spend CPU time allocating, copying, locking, or converting data.
---
---Initialization occurs once on the main thread through init(), get_devices(),
---or open_device(). A worker must wait for main-thread initialization before using
---devices. Objects belong to their creating Lua state and cannot be passed through
---thread channels; exchange PCM strings and specification tables instead. Loading
---sounds and offline conversion do not require a device or audio initialization.
---No Lua callbacks run on SDL's audio thread. Native sound playback and looping
---continue without a Lua update pump; user-fed streams need regular servicing.
---
---Keep a device reference while it is needed. Explicit close or device garbage
---collection stops its voices and closes its streams, not another plugin's audio.
---Child handles do not keep the device open. Collecting a stream closes it, but
---collecting a voice handle does not stop playback while its device remains alive.
---Active voices retain native sample storage even if the sound is closed or
---collected. State shutdown releases its audio resources before SDL shuts down.
---
---Controls affect future processing; samples already submitted to hardware cannot
---be recalled. A drained stream or finished voice is not a speaker-latency clock.
---There is no plugin-facing global quit function that could stop other plugins.
---
---SDL reference: https://wiki.libsdl.org/SDL3/CategoryAudio
---@class audio
audio = {}

---@alias audio.device_kind "playback" | "recording"
---@alias audio.voice_state "playing" | "paused" | "finished" | "stopped"

---Native-endian aliases are s16, s32, and f32. Explicit byte-order suffixes are
---recommended for PCM exchanged with files, subprocesses, or network services.
---@alias audio.format
---| "u8"
---| "s8"
---| "s16"
---| "s16le"
---| "s16be"
---| "s32"
---| "s32le"
---| "s32be"
---| "f32"
---| "f32le"
---| "f32be"

---
---Uncompressed interleaved PCM specification. All fields are required.
---A frame contains one sample for each channel; stereo s16 uses four bytes/frame.
---Channel order follows SDL (mono, left/right for stereo, SDL order for surround).
---Floating-point samples normally range from -1 to 1; u8 silence is 128, while
---signed integer and floating-point silence is zero. Returned specs are copies.
---@class audio.spec
---@field format audio.format
---@field channels integer From 1 through 8; normally 1 (mono) or 2 (stereo).
---@field sample_rate integer Positive sample frames per second, for example 48000.

---
---A currently enumerated physical device, not an opened device handle.
---IDs are session-local and can become invalid after disconnection. Do not persist
---them in settings; omitting device_options.id selects the system default.
---@class audio.device_descriptor
---@field id integer Physical device ID accepted by open_device().
---@field name string Display name; not necessarily unique.
---@field kind audio.device_kind

---@class audio.device_options
---@field id? integer Physical ID from get_devices(); omitted selects the default.
---@field spec? audio.spec Hardware format hint, not a guarantee; omitted lets SDL choose.
---@field max_voices? integer Positive simultaneous voice limit for playback; default 64.

---
---A snapshot of an opened logical device. Hardware format and buffer size can
---change, particularly when following the default device. buffer_frames describes
---SDL's device buffer, not total end-to-end latency or a requested buffer setting.
---@class audio.device_info
---@field id integer Logical device ID, distinct from an enumerated physical ID.
---@field name string Current device display name.
---@field kind audio.device_kind
---@field spec audio.spec Current device format, not an application's stream format.
---@field buffer_frames integer Number of sample frames in the device buffer.
---@field paused boolean
---@field gain number
---@field follows_default boolean Whether opened without an explicit physical ID.
---@field max_voices? integer Configured limit; present only for playback devices.

---@class audio.play_options
---@field gain? number Finite nonnegative multiplier; default 1. Values above 1 can clip.
---@field rate? number Speed and pitch ratio from 0.01 through 100; default 1.
---@field loop? boolean Repeat the entire sound natively until stopped; default false.
---@field paused? boolean Create an individually paused voice; default false.

---
---An independently controlled logical audio device. Newly opened devices are
---paused, including playback devices. resume() starts processing bound streams.
---@class audio.device
audio.device = {}

---
---A device-bound PCM stream or an unbound offline converter. Application-facing
---formats remain fixed for the stream's lifetime; create another stream to change
---them. SDL may change the hardware-facing format of a device-bound stream.
---
---Queues have no implicit size cap. Feeding playback faster than it drains, or
---neglecting recording reads, grows memory use. Use queue measurements to bound
---playback input and regularly drain, pause, or close recording streams.
---@class audio.stream
audio.stream = {}

---
---Immutable PCM sample storage reusable across voices and devices in this Lua
---state. Loading is separate from playback and never opens an audio device.
---@class audio.sound
audio.sound = {}

---
---One playback instance of a sound. Multiple voices can share the same sound
---without sharing volume, rate, pause, or playback position. Retain this handle
---only when control or status is needed; dropping it is not a stop request.
---@class audio.voice
audio.voice = {}

-- Module functions -----------------------------------------------------------

---
---Initialize SDL audio on the main thread without opening a playback or recording
---device. Repeated calls succeed without accumulating SDL initialization refs.
---An uninitialized worker gets nil, errmsg rather than initializing SDL itself.
---Initialization failure must not prevent the editor or a muted game from running.
---The backend is selected by SDL/platform configuration, not switched at runtime.
---@return boolean? initialized True on success.
---@return string? errmsg
function audio.init() end

---
---List audio backend driver names compiled into SDL. Does not initialize audio;
---presence in this list does not mean a driver is usable on the current system.
---@return string[] drivers
function audio.get_drivers() end

---
---Get the active backend driver name, or nil if audio has not been initialized.
---This query does not initialize audio and nil here is not an error.
---@return string? driver
function audio.get_driver() end

---
---Enumerate the requested physical devices. Initializes audio if necessary, on
---the main thread only. An empty table is a successful enumeration with no devices;
---nil, errmsg signals failure. Refresh this list after device changes.
---@param kind? audio.device_kind Defaults to "playback".
---@return audio.device_descriptor[]? devices
---@return string? errmsg
function audio.get_devices(kind) end

---
---Open an independent logical device in the paused state. Initializes audio if
---necessary, on the main thread only. Omit options.id to follow SDL's default
---device migration when the OS default changes; explicit IDs may become unavailable.
---An explicit device that fails to open is not silently replaced with the default.
---Device failure is returned to the caller, never replaced with a dummy backend.
---
---Opening "recording" is the explicit microphone-access operation and may prompt
---for OS permission even while paused. Pausing is not a promise that the OS's
---microphone indicator turns off; close the device when recording is no longer needed.
---max_voices applies only to playback; passing it for recording is an argument error.
---SDL reference: https://wiki.libsdl.org/SDL3/SDL_OpenAudioDevice
---@param kind? audio.device_kind Defaults to "playback".
---@param options? audio.device_options
---@return audio.device? device
---@return string? errmsg
function audio.open_device(kind, options) end

---
---Synchronously decode a WAV file into reusable sample storage. Retains the decoded
---format and does not open a device. Missing, corrupt, unsupported, or empty files
---return nil, errmsg. The whole decoded sound is resident in memory, not file-streamed.
---SDL reference: https://wiki.libsdl.org/SDL3/SDL_LoadWAV
---@param path string
---@return audio.sound? sound
---@return string? errmsg
function audio.load_wav(path) end

---
---Decode a complete WAV file already held in a binary string. The string contains
---the WAV container, not raw PCM. Has the same decoding/lifetime rules as load_wav().
---@param data string
---@return audio.sound? sound
---@return string? errmsg
function audio.decode_wav(data) end

---
---Copy raw PCM into immutable sound storage. Require at least one complete frame;
---the byte length must be a multiple of the frame size. No conversion is performed.
---The caller can release the original string after this call returns.
---@param data string Interleaved PCM bytes, not a Lua sample array or encoded file.
---@param spec audio.spec
---@return audio.sound? sound
---@return string? errmsg
function audio.new_sound(data, spec) end

---
---Create an unbound converter. Write input PCM and read converted output without
---opening a device. For segmented input, keep this stream across chunks to preserve
---resampling continuity. Flush once at the end to expose the remaining output.
---@param input_spec audio.spec
---@param output_spec audio.spec
---@return audio.stream? stream
---@return string? errmsg
function audio.create_stream(input_spec, output_spec) end

---
---Convert a complete PCM buffer in one synchronous operation, returning new bytes.
---Input must contain whole frames; empty input returns "". For continuous chunks
---use create_stream() instead, since separate conversions reset the resampler.
---SDL reference: https://wiki.libsdl.org/SDL3/SDL_ConvertAudioSamples
---@param data string
---@param input_spec audio.spec
---@param output_spec audio.spec
---@return string? data Converted, interleaved PCM in output_spec.
---@return string? errmsg
function audio.convert(data, input_spec, output_spec) end

-- Logical devices ------------------------------------------------------------

---
---Get a fresh device snapshot. Returns nil, errmsg if closed or querying fails.
---@return audio.device_info? info
---@return string? errmsg
function audio.device:get_info() end

---
---Create and bind a stream to this device. For playback, spec is the PCM written
---by the caller; for recording, it is the PCM returned by read(). SDL converts
---between this application format and the device's current hardware format.
---The stream is individually unpaused, but does not progress while the device is
---paused. Recording begins flowing when the device is resumed. Keep the stream
---handle alive and close it when done. Closing the device also closes this stream.
---@param spec audio.spec
---@return audio.stream? stream
---@return string? errmsg
function audio.device:create_stream(spec) end

---
---Start a separate voice on a playback device. The entire sound is played once
---unless loop is true. Device pause still applies even if options.paused is false.
---Different sound formats are converted and mixed by SDL, without changing the
---shared sound. Samples and native looping remain independent of the Lua frame rate.
---
---Playing or individually paused voices occupy a slot; finished/stopped voices
---release it. Raw streams do not count toward max_voices. Exhaustion returns
---nil, errmsg, never steals a voice. No voice is created on failure. Recording
---devices and closed devices/sounds also return nil, errmsg.
---@param sound audio.sound
---@param options? audio.play_options
---@return audio.voice? voice
---@return string? errmsg
function audio.device:play(sound, options) end

---Pause this logical device and all its streams/voices, retaining queued audio.
---Does not change their individual pause flags or affect other logical devices.
---@return boolean? success
---@return string? errmsg
function audio.device:pause() end

---Resume this logical device. Individually paused streams/voices remain paused.
---@return boolean? success
---@return string? errmsg
function audio.device:resume() end

---Get this device's pause flag; false means unpaused, nil means failure.
---@return boolean? paused
---@return string? errmsg
function audio.device:is_paused() end

---Get this logical device's gain multiplier, initially 1.
---@return number? gain
---@return string? errmsg
function audio.device:get_gain() end

---Set this logical device's gain, not the OS master volume. Multiplies individual
---stream/voice gains. Use 0 to mute without pausing; values above 1 may clip.
---@param gain number Finite, nonnegative multiplier.
---@return boolean? success
---@return string? errmsg
function audio.device:set_gain(gain) end

---Stop owned voices, close owned streams, and release this device. Pending audio
---in software queues is discarded, not drained. Closing may block briefly while
---hardware finishes already submitted audio. Child handles are safe to inspect or close;
---other operations return nil, errmsg. Voice get_state() reports "stopped" for
---voices terminated by device closure. Repeated close calls have no effect.
function audio.device:close() end

-- PCM streams ----------------------------------------------------------------

---
---Copy PCM into a playback stream or unbound converter. The input must contain
---whole frames. Success accepts all bytes and returns #data (0 for empty input);
---there is no partial-write/backpressure return. Recording streams reject writes.
---No hardware wait, decoding, or Lua callback occurs. Monitor get_queued_bytes()
---before writing to avoid feeding an unbounded queue faster than it is consumed.
---@param data string PCM in the stream's input format.
---@return integer? bytes_written
---@return string? errmsg
function audio.stream:write(data) end

---
---Read up to max_bytes of converted PCM from a recording stream or converter.
---max_bytes must be positive and is rounded down to a whole output-frame boundary;
---a value smaller than one frame is an argument error. Returns "" if no complete
---output frames are available, not EOF; nil, errmsg signals failure. Playback
---streams reject reads so callers cannot steal audio intended for the device.
---@param max_bytes? integer Defaults to 4096 bytes, rounded down to whole frames.
---@return string? data PCM in the stream's output format.
---@return string? errmsg
function audio.stream:read(max_bytes) end

---Get snapshots of both conversion formats. Playback has application input and
---hardware output; recording reverses that relationship. Hardware-facing formats
---can change with device migration, while the application-facing format stays fixed.
---@return audio.spec? input_spec
---@return audio.spec? output_spec
---@return string? errmsg Present on failure, when both specifications are nil.
function audio.stream:get_formats() end

---Get unconsumed input bytes, not converted output bytes or exact hardware latency.
---For recording these are hardware-format bytes, not bytes in the requested format.
---SDL may clamp very large counts to its native integer maximum. Use a small queue.
---@return integer? bytes
---@return string? errmsg
function audio.stream:get_queued_bytes() end

---Get converted output bytes available now. Resampling may withhold a partial tail
---until more input is written or flush() is called. For playback this describes
---hardware-format output, not permission to read it or an exact audible playhead.
---@return integer? bytes
---@return string? errmsg
function audio.stream:get_available_bytes() end

---Finish the current input segment so the resampler's buffered tail becomes
---available. Does not wait for playback or close the stream. Further writes are
---legal but may introduce a gap; do not flush after every chunk. For recording,
---pause the stream/device before flushing the final captured segment.
---@return boolean? success
---@return string? errmsg
function audio.stream:flush() end

---Discard buffered input and output, retaining formats, gain, rate, and pause state.
---Does not cancel samples already submitted to hardware or stop future recording.
---@return boolean? success
---@return string? errmsg
function audio.stream:clear() end

---Pause only this device-bound stream, preserving queued data. Other streams keep
---running. Recording samples during the pause are not captured for this stream.
---Unbound converters return nil, errmsg; simply stop reading/writing to pause one.
---This is a wrapper operation, not SDL_PauseAudioStreamDevice(), which pauses the
---whole logical device: https://wiki.libsdl.org/SDL3/SDL_PauseAudioStreamDevice
---@return boolean? success
---@return string? errmsg
function audio.stream:pause() end

---Clear this stream's individual pause flag. Does not resume a paused device.
---Unbound converters return nil, errmsg.
---@return boolean? success
---@return string? errmsg
function audio.stream:resume() end

---Report whether this bound stream is paused individually or by its device.
---Unbound converters return nil, errmsg.
---@return boolean? paused
---@return string? errmsg
function audio.stream:is_paused() end

---Get this stream's gain, initially 1; excludes any device gain.
---@return number? gain
---@return string? errmsg
function audio.stream:get_gain() end

---Set this stream's gain during conversion. Applies to playback, recording, and
---offline conversion. Muting with 0 still consumes input; it does not pause it.
---@param gain number Finite, nonnegative multiplier; values above 1 may clip.
---@return boolean? success
---@return string? errmsg
function audio.stream:set_gain(gain) end

---Get this stream's speed/pitch ratio, initially 1.
---@return number? rate
---@return string? errmsg
function audio.stream:get_rate() end

---Set the frequency ratio: greater than 1 consumes source frames faster and raises
---pitch; less than 1 slows and lowers pitch. Does not independently shift pitch.
---Applies to subsequent conversion, not audio already submitted to hardware.
---SDL reference: https://wiki.libsdl.org/SDL3/SDL_SetAudioStreamFrequencyRatio
---@param rate number Finite ratio in the inclusive range 0.01 to 100.
---@return boolean? success
---@return string? errmsg
function audio.stream:set_rate(rate) end

---Discard pending data and destroy this stream without closing its parent device.
---Further operations return nil, errmsg; repeated close calls have no effect.
function audio.stream:close() end

-- Reusable sounds ------------------------------------------------------------

---Get a copy of the sound's decoded or supplied PCM specification.
---@return audio.spec? spec
---@return string? errmsg
function audio.sound:get_spec() end

---Get the size of the decoded PCM, not the WAV container or native object overhead.
---@return integer? bytes
---@return string? errmsg
function audio.sound:get_size() end

---Get duration in seconds at the original sample rate. Does not include looping
---or a voice's speed changes. Equal to PCM frames divided by sample_rate.
---@return number? seconds
---@return string? errmsg
function audio.sound:get_duration() end

---Return a copy of the PCM bytes in get_spec() format, not a WAV-encoded file.
---Copying large sounds allocates additional memory; play() needs no such Lua copy.
---@return string? data
---@return string? errmsg
function audio.sound:get_data() end

---Release this handle's sample ownership and prevent new play/read operations.
---Existing voices retain the native storage they need until finished or stopped;
---closing a sound does not stop them. Repeated close calls have no effect.
function audio.sound:close() end

-- Playback instances ---------------------------------------------------------

---Get the playback state. "paused" includes a paused parent device. "playing"
---means eligible to progress, not a guarantee that the speaker is audible.
---"finished" means source playback and stream draining completed; hardware may
---still have pending samples. "stopped" means explicitly stopped, device-closed,
---or a native playback failure (reported in the optional second return value).
---Terminal states remain queryable. Replay by calling device:play() for a new voice.
---@return audio.voice_state state
---@return string? errmsg Native playback error, if any.
function audio.voice:get_state() end

---Pause only this voice without rewinding; sibling voices/streams are unaffected.
---Terminal voices return nil, errmsg.
---@return boolean? success
---@return string? errmsg
function audio.voice:pause() end

---Resume an individually paused voice without resuming its parent device.
---Terminal voices return nil, errmsg; a stopped/finished voice cannot restart.
---@return boolean? success
---@return string? errmsg
function audio.voice:resume() end

---Stop this voice and discard pending samples, releasing its active-voice slot.
---Cannot retract samples already in hardware. Stopped or finished voices are
---unchanged, making repeated stop calls harmless.
function audio.voice:stop() end

---Get this voice's gain, excluding device gain. Remains available after completion.
---@return number gain
function audio.voice:get_gain() end

---Set only this voice's gain. Terminal voices return nil, errmsg.
---@param gain number Finite, nonnegative multiplier; values above 1 may clip.
---@return boolean? success
---@return string? errmsg
function audio.voice:set_gain(gain) end

---Get this voice's speed/pitch ratio. Remains available after completion.
---@return number rate
function audio.voice:get_rate() end

---Change this voice's speed and pitch together. Terminal voices return nil, errmsg.
---@param rate number Finite ratio in the inclusive range 0.01 to 100.
---@return boolean? success
---@return string? errmsg
function audio.voice:set_rate(rate) end

-- Usage examples -------------------------------------------------------------

--[[
Overlapping game effects, looping ambience, pause, and cleanup:

```lua
local audio = require "audio"
local output, err = audio.open_device("playback")
if not output then
  -- The game can continue muted. Do not assert audio availability in production.
  return nil, err
end
local shot = assert(audio.load_wav("shot.wav"))
local engine = assert(audio.load_wav("engine.wav"))
assert(output:resume())

local first = assert(output:play(shot, { gain = 0.4 }))
local second = assert(output:play(shot, { gain = 0.3, rate = 1.1 }))
local hum = assert(output:play(engine, { loop = true, gain = 0.2 }))
first:pause()                     -- Only the first effect pauses.
assert(hum:set_rate(1.1))
output:pause()                    -- Pause this game's device, not other plugins.
output:resume()                   -- first remains individually paused.
first:resume()

-- Keep output and reusable sounds in the view; close them when the view closes.
-- These lifecycle calls are shown together for reference, not timed playback.
hum:stop()
output:close()
shot:close()
engine:close()
```
]]

--[[
Generate a short tone once, then reuse it as a sound effect (no audio-thread Lua):

```lua
local audio = require "audio"
local spec = { format = "f32le", channels = 1, sample_rate = 48000 }
local samples = {}
local frames = 4800
for i = 0, frames - 1 do
  local time = i / spec.sample_rate
  local envelope = math.sin(math.pi * i / (frames - 1)) ^ 2
  local sample = 0.15 * envelope * math.sin(2 * math.pi * 440 * time)
  samples[#samples + 1] = string.pack("<f", sample)
end
local tone = assert(audio.new_sound(table.concat(samples), spec))
local output = assert(audio.open_device())
assert(output:resume())
assert(output:play(tone))
-- Store output and tone on the view until playback is no longer needed.
```
]]

--[[
Bounded streaming of raw PCM from a file; not an MP3/OGG/WAV decoder:

```lua
local audio = require "audio"
local core = require "core"
local spec = { format = "s16le", channels = 2, sample_rate = 48000 }
local frame_bytes = 4
local chunk_bytes = 480 * frame_bytes       -- 10 ms of input.
local queue_limit = 4800 * frame_bytes      -- At most about 100 ms queued input.
local output = assert(audio.open_device())
local stream = assert(output:create_stream(spec))
local file = assert(io.open("music.s16le", "rb"))

-- Use a background coroutine so editor focus loss does not stop servicing audio.
core.add_background_thread(function()
  local ok, err = pcall(function()
    while true do
      if assert(stream:get_queued_bytes()) + chunk_bytes <= queue_limit then
        local chunk = file:read(chunk_bytes)
        if not chunk then break end
        assert(#chunk % frame_bytes == 0, "truncated PCM frame")
        assert(stream:write(chunk))
        assert(output:resume())
      end
      coroutine.yield(0.005)
    end
    assert(stream:flush())
    while assert(stream:get_queued_bytes()) > 0
       or assert(stream:get_available_bytes()) > 0 do
      coroutine.yield(0.01)
    end
    -- Queue exhaustion is not an exact hardware drain indication. This grace
    -- period is illustrative, not a guaranteed end-to-end latency bound.
    coroutine.yield(0.25)
  end)
  file:close()
  stream:close()
  output:close()
  if not ok then core.error("Audio stream: %s", err) end
end)
-- UI stalls longer than the buffered audio can cause underruns; native voice
-- playback avoids this Lua producer dependency for fully loaded sounds.
```
]]

--[[
Explicit, short microphone recording into a raw PCM file, with regular draining:

```lua
local audio = require "audio"
local core = require "core"
local spec = { format = "s16le", channels = 1, sample_rate = 16000 }
-- Run only in response to the user's recording action; opening may prompt.
local input = assert(audio.open_device("recording"))
local stream = assert(input:create_stream(spec))
local file = assert(io.open("recording.s16le", "wb"))
core.add_background_thread(function()
  local ok, err = pcall(function()
    assert(input:resume())
    local deadline = system.get_time() + 5
    while system.get_time() < deadline do
      assert(file:write(assert(stream:read(4096))))
      coroutine.yield(0.01)
    end
    assert(input:pause())
    assert(stream:flush())
    while true do
      local chunk = assert(stream:read(4096))
      if chunk == "" then break end
      assert(file:write(chunk))
    end
  end)
  stream:close()
  input:close() -- Release microphone access, even if reading/writing failed.
  file:close()
  if not ok then core.error("Audio recording: %s", err) end
end)
-- No implicit recording queue cap: a stalled consumer must catch up, clear,
-- pause, or close. A persistent recorder should not retain all PCM in Lua RAM.
```
]]

--[[
Offline conversion and loading a WAV container from memory:

```lua
local audio = require "audio"
local file = assert(io.open("effect.wav", "rb"))
local wav = assert(file:read("*a"))
file:close()
local sound = assert(audio.decode_wav(wav))
local source = assert(sound:get_spec())
local target = { format = "s16le", channels = 1, sample_rate = 16000 }
local pcm = assert(sound:get_data())
local converted = assert(audio.convert(pcm, source, target))
local reusable = assert(audio.new_sound(converted, target))

-- For successive input chunks, retain one converter instead of calling convert
-- separately for each chunk. Feed whole source frames and drain between writes.
local converter = assert(audio.create_stream(source, target))
assert(converter:write(pcm))
assert(converter:flush())
local chunks = {}
while true do
  local chunk = assert(converter:read(4096))
  if chunk == "" then break end
  chunks[#chunks + 1] = chunk
end
converter:close()
sound:close()
reusable:close()
```
]]

-- Runtime tests: scripts/lua/tests/audio.lua. Set SDL_AUDIO_DRIVER=dummy to test
-- device operations without accessing physical speakers or microphones. These
-- tests cannot establish audible quality, real latency, OS permission handling,
-- or default-device migration; those require platform/hardware verification.

return audio
