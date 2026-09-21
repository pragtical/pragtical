---@meta

---
---Independent mixers, persistent playback groups, reusable encoded/PCM sounds,
---file-streamed music, generated PCM voices, recording, and offline mixing/PCM
---conversion. Playback supports loop regions, panning, and synchronized layers.
---SDL3_mixer handles playback/decoding; SDL3 handles capture and PCM conversion.
---Bundled codecs include WAV, AIFF, AU, VOC, Ogg Vorbis, MP3, FLAC, and Opus. get_decoders()
---reports the actual build/runtime capabilities. No audio encoder is exposed.
---
---Builds follow upstream SDL3_mixer by default. The optional, disabled
---subprojects/packagefiles/sdl3_mixer-playback.patch provides stricter offline
---resampling/count behavior and tiny-loop fixes for the pinned library version.
---Without it, use ordinary playback-sized buffers, avoid one-frame loops, and
---do not depend on exact resampled mixer output or counts (see mixer:render()).
---
---Initialization is internal. Device enumeration, device-backed mixers, recording,
---and their handles are main-thread operations. Sound loading, PCM generation,
---extraction, offline mixers, and conversion can run in workers without hardware.
---Each userdata belongs to its creating Lua state; exchange PCM strings and spec
---tables between states, not handles. No Lua function runs on an audio callback.
---
---Operational failures return nil, errmsg unless documented otherwise. Invalid
---arguments raise Lua errors.
---close() and immediate stop() are idempotent. Opening/loading/seeking can block;
---"streaming" does not mean asynchronous opening. PCM I/O never waits for hardware
---but may allocate, copy, lock, or convert. No promise of real-time execution.
---
---Retain a mixer while it is needed. Closing/collecting it stops its voices and
---releases its device, without affecting other mixers. Groups/voices do not keep
---the mixer open. Dropping a voice handle does not stop it; completion is cleaned
---up natively. Playback retains the needed sound data even after sound:close().
---Recording streams own their devices; close/collection releases microphone use.
---
---No update() pump is required for files, loaded sounds, loops, fades, or cleanup.
---Optional completion callbacks are queued, then dispatched by the editor on the
---main thread. Workers using offline mixers call mixer:dispatch_events() instead.
---Offline mixers advance only through render(), never through elapsed wall time.
---Generated streams need a producer; capture streams need a consumer. Ordinary
---Lua coroutine producers can underrun during long editor stalls. Use a worker
---for expensive synthesis, transfer PCM, and keep a measured amount buffered.
---
---Positions/start offsets use seconds on the source timeline. Fades also use
---source-audio seconds: voice AND mixer rates change their wall-clock duration.
---Loop starts and fade durations must fit in 2^31-1 source frames.
---Offsets/boundaries are rounded down to source sample frames. Pauses
---freeze progress. Gain is a finite nonnegative multiplier; rate is a finite
---speed AND pitch ratio in [0.01, 100], not independent pitch shifting.
---Already submitted hardware samples cannot be recalled; "finished", queue sizes,
---and positions are not exact measurements of what the listener currently hears.
---
---Removed: audio.init(), open_device(), audio.device, load_wav(), decode_wav().
---Replacements: create_mixer(), open_recording(), load(), and load_memory().
---There is one audio.sound type, not a separate clip type. Groups are our
---persistent control abstraction, not a direct exposure of SDL_mixer tags.
---Numeric play_options.loops replaces the earlier draft's boolean loop option.
---
---References: https://wiki.libsdl.org/SDL3_mixer/CategoryAPI
---            https://wiki.libsdl.org/SDL3/CategoryAudio
---@class audio
audio = {}

---@alias audio.device_kind "playback" | "recording"
---@alias audio.voice_state "playing" | "paused" | "finished" | "stopped"
---@alias audio.completion_reason "finished" | "stopped" | "error"

---Runs once after terminal playback, outside all native audio callbacks/locks.
---"finished" follows EOF and all requested repeats; "stopped" follows explicit
---stop (including a completed fade); "error" supplies a playback failure message.
---Pauses, loop boundaries, and temporary PCM underruns do not notify. Mixer close,
---collection, and Lua-state shutdown cancel undelivered callbacks, not invoke them.
---Mid-stream decoder failures may appear as "finished" with unpatched SDL_mixer;
---the optional playback patch supplies the additional native error reporting.
---See mixer:dispatch_events() for scheduling, callback errors, and worker use.
---@alias audio.completion_callback fun(voice: audio.voice, reason: audio.completion_reason, errmsg: string?)

---Native-endian aliases are s16, s32, and f32. Prefer explicit byte order for
---files, subprocesses, or network data.
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

---Interleaved PCM; all fields are required. One frame includes all channels.
---Float samples normally use [-1, 1]; u8 silence is 128, other formats use zero.
---PCM strings must contain complete frames and fit in 2^31-1 bytes per operation.
---This is not a file-stream length limit. Returned spec tables are copies.
---@class audio.spec
---@field format audio.format
---@field channels integer From 1 through 8.
---@field sample_rate integer From 1 through 2^31-1 frames/second, normally 48000.

---Physical device IDs are session-local; do not persist them across restarts.
---@class audio.device_descriptor
---@field id integer
---@field name string
---@field kind audio.device_kind

---@class audio.mixer_options
---@field offline? boolean Default false; true opens no device and requires spec.
---@field id? integer Physical playback ID; default follows system. Invalid when offline.
---@field spec? audio.spec Hardware hint when online; required exact output when offline.
---@field max_voices? integer Positive limit, default 64; includes PCM/file voices.

---@class audio.recording_options
---@field id? integer Physical recording ID; omitted follows the system default.
---@field paused? boolean Default true; false starts capturing immediately.

---Hardware information can change with default-device migration. buffer_frames
---is the device buffer size, not total end-to-end latency. Gain is local, not the
---OS master volume. For recording, spec is not necessarily the format read by Lua.
---@class audio.device_info
---@field id integer Logical device ID, not the enumerated physical ID.
---@field name string
---@field kind audio.device_kind
---@field spec audio.spec Current hardware format.
---@field buffer_frames integer
---@field follows_default boolean
---@field paused boolean
---@field gain number

---Mixer controls and output format; device is absent for offline mixers.
---All returned tables are snapshots. Device-backed output may change if the
---default device changes; offline spec stays fixed for the mixer's lifetime.
---@class audio.mixer_info
---@field offline boolean
---@field spec audio.spec Mixer output format, not an input sound's format.
---@field max_voices integer
---@field paused boolean
---@field gain number
---@field rate number
---@field device? audio.device_info Current playback device information.

---Optional decoder-supplied tags, not trusted or normalized application data.
---Missing fields remain nil; generated PCM sounds normally have no tags.
---@class audio.metadata
---@field title? string
---@field artist? string
---@field album? string
---@field copyright? string
---@field track? integer
---@field total_tracks? integer
---@field year? integer

---@class audio.load_options
---@field predecode? boolean Default false: retain encoded data, decode during playback.

---The first pass covers [start, loop_end); subsequent passes cover
---[loop_start, loop_end). loop_end defaults to source EOF. After the last pass,
---playback finishes there; it does not continue into an outro after loop_end.
---Boundaries must form nonempty ranges after rounding to source frames. Offsets
---must be finite, nonnegative, and within the source when its length is known.
---loop_start is only used when loops ~= 0; it defaults to 0, not start.
---Example: start=0, loop_start=4, loop_end=20, loops=2 plays the intro once and
---the [4,20) region three times total. loops=-1 repeats until explicitly stopped.
---These repeats are separate from any looping embedded in a decoder's source;
---loops=0 does not disable those internal loops. Set loop_end to bound such input.
---@class audio.play_options
---@field gain? number Default 1; excludes mixer/group gain and fades.
---@field rate? number Default 1; changes speed and pitch together.
---@field paused? boolean Default false; parent pause still applies.
---@field fade_in? number Nonnegative duration in source seconds, default 0.
---@field loops? integer Additional repeats: 0 (default), positive count, or -1 forever.
---@field start? number Nonnegative source offset in seconds, default 0.
---@field loop_start? number Repeat start in source seconds, default 0.
---@field loop_end? number Exclusive end in source seconds for every pass, default EOF.
---@field pan? number Stereo balance in [-1, 1]; omitted preserves channel layout.
---@field on_complete? audio.completion_callback Optional deferred terminal notification.

---Writable PCM voices have no seekable history; loops/start/loop boundaries are
---not accepted. Panning and completion callbacks work like loaded-sound voices.
---@class audio.stream_play_options
---@field gain? number Default 1.
---@field rate? number Default 1.
---@field paused? boolean Default false.
---@field fade_in? number Nonnegative source seconds, default 0.
---@field pan? number Stereo balance in [-1, 1]; omitted preserves channel layout.
---@field on_complete? audio.completion_callback Optional deferred terminal notification.

---@class audio.stop_options
---@field fade_out? number Nonnegative source seconds, default 0 (immediate).

---Independent device-backed or offline playback owner. Initially unpaused with
---gain 1 and rate 1. Groups and voices use the same operations in either mode.
---@class audio.mixer
audio.mixer = {}

---A named, non-nested playback group owned by one mixer. Group gain/pause persist
---even with no voices and apply to future voices. Effective gain is mixer gain *
---group gain * voice gain * fade envelope. Each voice belongs to at most one group.
---@class audio.group
audio.group = {}

---Immutable reusable audio. load/load_memory may retain encoded bytes; new_sound
---and predecode=true retain PCM. The same sound can play in multiple mixers in
---this Lua state. It does not own or implicitly open a playback device.
---@class audio.sound
audio.sound = {}

---One loaded-sound, file, or generated-stream playback instance. A finished/stopped
---voice cannot restart; request a new voice. Status remains readable after it ends.
---@class audio.voice
audio.voice = {}

---A PCM capture stream owning its recording device, or an unbound converter.
---Playback uses writable audio.voice instead. Formats supplied by the caller are
---fixed for the stream's lifetime; hardware-facing capture formats may change.
---Queues have no implicit cap: drain regularly, pause capture, or clear/close.
---@class audio.stream
audio.stream = {}

-- Module functions -----------------------------------------------------------

---List compiled SDL backend driver names; this does not initialize hardware.
---Listed drivers are not necessarily usable on the current system.
---@return string[] drivers
function audio.get_drivers() end

---Return the current backend, or nil if hardware audio has not been initialized.
---Does not initialize audio; nil is not an error.
---@return string? driver
function audio.get_driver() end

---Enumerate physical devices on the main thread, initializing SDL audio as needed.
---An empty list is successful. No recording device is opened by enumeration.
---@param kind? audio.device_kind Defaults to "playback".
---@return audio.device_descriptor[]? devices
---@return string? errmsg
function audio.get_devices(kind) end

---List available decoder names after internal, serialized mixer initialization.
---Names describe decoders, not an exhaustive extension list. Does not open audio
---hardware. Missing codecs produce an error when loading/playing that format.
---@return string[]? decoders
---@return string? errmsg
function audio.get_decoders() end

---Open an independent playback mixer on the main thread, ready to play. Omit id
---to follow the system default; an unavailable explicit ID never falls back
---silently. Audio failure must not prevent a plugin from continuing without sound.
---With offline=true, require spec, reject id, and open no hardware; this mode can
---be created/used/closed in a worker. render() pulls PCM in the exact spec supplied.
---Device failure never silently switches a mixer to offline mode.
---SDL reference: https://wiki.libsdl.org/SDL3_mixer/MIX_CreateMixerDevice
---               https://wiki.libsdl.org/SDL3_mixer/MIX_CreateMixer
---@param options? audio.mixer_options
---@return audio.mixer? mixer
---@return string? errmsg
function audio.create_mixer(options) end

---Open a capture stream on the main thread; spec is the PCM format read by Lua.
---Opening is explicit microphone access and may prompt even when paused. The
---stream starts paused unless requested otherwise. Pausing does not release
---microphone access: close when done. SDL converts hardware data into spec.
---@param spec audio.spec
---@param options? audio.recording_options
---@return audio.stream? stream
---@return string? errmsg
function audio.open_recording(spec, options) end

---Synchronously load a whole supported file, detecting format from its contents.
---Default: cache encoded data in RAM and decode during each playback.
---predecode=true: decode upfront and cache PCM. Neither mode streams from disk.
---The file is closed before returning; no mixer or playback device is required.
---SDL reference: https://wiki.libsdl.org/SDL3_mixer/MIX_LoadAudio_IO
---@param path string
---@param options? audio.load_options
---@return audio.sound? sound
---@return string? errmsg
function audio.load(path, options) end

---Like load(), but copy a complete encoded file supplied as a binary Lua string.
---Not raw PCM; use new_sound() for that. The caller may release data on return.
---@param data string
---@param options? audio.load_options
---@return audio.sound? sound
---@return string? errmsg
function audio.load_memory(data, options) end

---Copy nonempty, complete interleaved PCM frames into reusable sound storage.
---No conversion or container decoding. Supports synthesized samples/compositions
---and recorded or externally decoded audio without writing a file.
---SDL reference: https://wiki.libsdl.org/SDL3_mixer/MIX_LoadRawAudio
---@param data string
---@param spec audio.spec
---@return audio.sound? sound
---@return string? errmsg
function audio.new_sound(data, spec) end

---Create an offline PCM converter; no hardware is opened. Retain it across input
---chunks to preserve resampling history, draining output regularly. Flush after
---the final input segment, not after every chunk.
---@param input_spec audio.spec
---@param output_spec audio.spec
---@return audio.stream? stream
---@return string? errmsg
function audio.create_stream(input_spec, output_spec) end

---Convert one complete PCM buffer synchronously. Empty input returns "".
---Use create_stream() for successive chunks: separate convert() calls reset the
---resampler. Unsupported/effective-rate combinations return nil, errmsg.
---@param data string
---@param input_spec audio.spec
---@param output_spec audio.spec
---@return string? data Converted PCM in output_spec.
---@return string? errmsg
function audio.convert(data, input_spec, output_spec) end

-- Mixers ---------------------------------------------------------------------

---Return mixer controls/output and, when device-backed, a nested device snapshot.
---Offline mixers have no device IDs or hardware buffer size. Fails after close().
---@return audio.mixer_info? info
---@return string? errmsg
function audio.mixer:get_info() end

---Get or create a named group, initially unpaused with gain 1. Names are nonempty,
---case-sensitive strings scoped to this mixer. Repeating the name returns the
---same group. Groups live until mixer closure, with no separate close operation.
---@param name string
---@return audio.group? group
---@return string? errmsg
function audio.mixer:group(name) end

---Start a new independent voice, not assigned to a named group. Input format is
---converted automatically. Retains sound storage, not its Lua handle.
---All active, paused, fading, and starved voices count toward max_voices. Completed
---voices release slots automatically. At capacity return nil, errmsg; never
---silently steal a voice. No polling by the consumer is needed for cleanup.
---Unsupported looping/start offsets fail before playback, not silently later.
---paused=true prepares the voice without consuming any source frames, including
---before the function returns. Useful for resume_together(). If supplied,
---on_complete is retained until dispatch/cancellation even if the voice handle
---is discarded. Failed play calls do not schedule completion callbacks.
---SDL reference: https://wiki.libsdl.org/SDL3_mixer/MIX_PlayTrack
---@param sound audio.sound
---@param options? audio.play_options
---@return audio.voice? voice
---@return string? errmsg
function audio.mixer:play(sound, options) end

---Play directly from a seekable local file, without caching the whole file in RAM.
---Each call owns a separate file/decoder until completion or stop. Initial opening
---and format inspection are synchronous; later reads/decoding occur as needed.
---Decoder/playback buffers still use memory. Slow storage can cause underruns.
---No stream=true option is needed. Not a URL/network-stream API. Use load()+play()
---for frequently repeated effects, avoiding repeated file opens and inspection.
---SDL reference: https://wiki.libsdl.org/SDL3_mixer/MIX_SetTrackIOStream
---@param path string
---@param options? audio.play_options
---@return audio.voice? voice
---@return string? errmsg
function audio.mixer:play_file(path, options) end

---Create a writable PCM voice in spec. It starts with an empty queue; an underrun
---outputs silence without terminating the voice. Feed chunks using write(), and
---call finish() for end-of-input or stop() to cancel. No Lua producer is called
---by the audio thread; optional on_complete only runs after terminal playback.
---Retain the handle to feed it; discarding an unfinished voice does not stop it
---and it occupies a voice slot until stopped, finished, or its mixer closes.
---SDL reference: https://wiki.libsdl.org/SDL3_mixer/MIX_SetTrackAudioStream
---@param spec audio.spec
---@param options? audio.stream_play_options
---@return audio.voice? voice
---@return string? errmsg
function audio.mixer:play_stream(spec, options) end

---Resume a nonempty array of distinct, individually paused voices together on
---the same mixer sample frame. They may belong to different groups or use loaded,
---file, or writable PCM sources. Create each with paused=true and prefill any PCM
---queues before this call to start layered music without sequential-call drift.
---All voices must belong to this mixer and be nonterminal; the mixer and their
---groups must be unpaused. Validate the whole set before changing anything;
---failure leaves all voice states unchanged. Other voices are unaffected.
---Preserves positions, rates, fades, and loop counts; previously played voices
---resume where paused, not at zero. No beat detection or automatic realignment.
---Matching material/loop lengths and rates are needed for continued alignment.
---This synchronizes mixer processing, not codec priming or hardware latency;
---stream underruns can still create gaps. Offline voices resume at the next render.
---SDL reference: https://wiki.libsdl.org/SDL3_mixer/MIX_LockMixer
---@param voices audio.voice[]
---@return boolean? success
---@return string? errmsg
function audio.mixer:resume_together(voices) end

---Pause all playback, including future voices, without altering group/voice flags.
---@return boolean? success
---@return string? errmsg
function audio.mixer:pause() end

---Resume this mixer; individually paused groups/voices remain paused.
---@return boolean? success
---@return string? errmsg
function audio.mixer:resume() end

---Return this mixer's own pause flag.
---@return boolean? paused
---@return string? errmsg
function audio.mixer:is_paused() end

---Return this mixer's gain, initially 1; not the system master volume.
---@return number? gain
---@return string? errmsg
function audio.mixer:get_gain() end

---Set gain for all current/future voices, retaining their individual/group gains.
---Values above 1 may clip; zero mutes but does not pause.
---@param gain number
---@return boolean? success
---@return string? errmsg
function audio.mixer:set_gain(gain) end

---Return the mixer-wide speed/pitch ratio, initially 1.
---@return number? rate
---@return string? errmsg
function audio.mixer:get_rate() end

---Set speed/pitch for the entire mix, including current and future group voices.
---Effective speed is voice rate * mixer rate; individual rates are preserved.
---Applies after track mixing, including offline output. Does not change the
---declared output spec. Already buffered output is unaffected; unsupported
---effective rates fail without changing the previous setting.
---SDL reference: https://wiki.libsdl.org/SDL3_mixer/MIX_SetMixerFrequencyRatio
---@param rate number Finite ratio in [0.01, 100].
---@return boolean? success
---@return string? errmsg
function audio.mixer:set_rate(rate) end

---Stop all current voices, including group voices; optionally fade them out.
---Does not close the mixer or affect future voices. Uses voice:stop() semantics.
---@param options? audio.stop_options
---@return boolean? success
---@return string? errmsg
function audio.mixer:stop(options) end

---Generate frames of interleaved PCM from an offline mixer in get_info().spec.
---Device-backed mixers reject this operation. Runs synchronously as fast as the
---CPU/storage allows; groups, loops, fades, rate, and panning work as in playback.
---Returns a PCM string sized for exactly the requested frames. The destination
---is initialized to format-correct silence before mixing, including any portion
---left unwritten by an upstream short read or exhausted input.
---mixed_frames is SDL_mixer's reported non-padding count, not a scan for silent
---samples. With unpatched SDL_mixer 3.2.4, mixer rate changes can make this count
---inaccurate or larger than frames; do not use it to trim output or detect EOF.
---Even normally, paused/starved voices can yield zero without reaching EOF.
---Resampling tails and chunk-to-chunk equivalence are not guaranteed with that
---version. The optional playback patch is needed for the stricter count and
---resampling behavior tested by PRAGTICAL_AUDIO_EXACT=1. Prefer 512-4096-frame
---requests; very small resampled requests can fail on the unpatched library.
---A paused mixer produces silence without advancing its voices. Otherwise each
---call continues from the previous mix position, including resampler state.
---Feed writable voices before rendering; no Lua synthesis callback runs mid-mix.
---No container header or encoding is added. Render in bounded chunks; infinite
---loops and generated streams need an explicit output duration or stop condition.
---Completion callbacks are queued, not invoked by render(); dispatch them outside
---mixing. Failure returns nil, nil, errmsg, and may have consumed some input.
---SDL reference: https://wiki.libsdl.org/SDL3_mixer/MIX_Generate
---@param frames integer Positive output frame count; byte size must fit in 2^31-1.
---@return string? data Raw PCM, including any appended silence.
---@return integer? mixed_frames Upstream-reported mixed frames; see accuracy limitations above.
---@return string? errmsg
function audio.mixer:render(frames) end

---Enable a bounded rolling buffer of post-mix samples for visualization.
---Disabled by default. Zero disables capture and frees the buffer; otherwise
---accepts 1-65536 frames. Every call clears the previous snapshot. Storage is
---reserved for up to eight channels, at most 2 MiB. The audio callback only
---copies samples: no Lua callbacks, allocation, or analysis run on that thread.
---Works with device and offline mixers; closing the mixer releases the buffer.
---SDL reference: https://wiki.libsdl.org/SDL3_mixer/MIX_SetPostMixCallback
---@param frames integer
---@return boolean? success
---@return string? errmsg
function audio.mixer:set_sample_buffer(frames) end

---Copy the newest captured frames into an interleaved array of float samples,
---oldest first. Does not consume samples or advance playback. Returns fewer
---frames (or an empty array) until the buffer fills. Format changes clear old
---samples; inspect the returned spec rather than assuming a channel count.
---Values are normally in [-1, 1], but mixing/gain can exceed that range. These
---are mixer samples before final device conversions, not a hardware playback
---clock: audible output can lag the snapshot. Paused mixers may retain their
---last snapshot. Not a lossless recording API; old frames are overwritten.
---Poll only as often as the visualization needs, e.g. 30 times per second.
---Disabled/closed buffers return nil, nil, errmsg.
---@param frames? integer Maximum frames to copy, 1-65536; default 1024.
---@return number[]? samples
---@return audio.spec? spec Native-endian float32 PCM specification.
---@return string? errmsg
function audio.mixer:get_samples(frames) end

---Dispatch a snapshot of pending on_complete callbacks on the creating Lua thread,
---after releasing native mixer locks. The editor does this automatically for
---main-thread mixers; worker/offline scripts without an editor event loop call it
---explicitly. It does not advance playback, render PCM, or perform voice cleanup.
---Each registration not cancelled by close/shutdown is invoked once. It receives
---the terminal voice, reason, and optional playback error. No notifications for
---voices without a handler. The handler/voice remain retained until delivery or
---cancellation, so worker scripts using handlers must drain this queue regularly.
---Callbacks may start/stop voices or close the mixer, but cannot yield or recursively
---dispatch. New completions wait for the next dispatch. Closing cancels the rest
---of the pending callbacks. Ordering between different voices is not guaranteed.
---Callback errors are caught; remaining callbacks still run. Return their invocation
---count and first callback error, if any; automatic editor dispatch logs that error.
---A closed mixer returns nil, errmsg. Callback latency follows Lua/editor
---scheduling, not the sample clock: this is NOT a gapless sequencing mechanism.
---SDL reference: https://wiki.libsdl.org/SDL3_mixer/MIX_SetTrackStoppedCallback
---@return integer? delivered Callback invocation count, including failed callbacks.
---@return string? errmsg First callback error, or dispatch failure when count is nil.
function audio.mixer:dispatch_events() end

---Immediately stop owned voices and close owned files/device, ignoring fades.
---Invalidates groups; surviving voices report "stopped" unless already terminal.
---Cancels pending/future callbacks and releases their Lua references, without
---invoking them. Other mixers and reusable sounds are unaffected. Device-backed
---mixers close on the main thread; offline mixers close on their creating thread.
function audio.mixer:close() end

-- Groups ---------------------------------------------------------------------

---Like mixer:play(), assigning the voice to this group. Group gain/pause applies.
---@param sound audio.sound
---@param options? audio.play_options
---@return audio.voice? voice
---@return string? errmsg
function audio.group:play(sound, options) end

---Like mixer:play_file(), assigning the streamed-file voice to this group.
---@param path string
---@param options? audio.play_options
---@return audio.voice? voice
---@return string? errmsg
function audio.group:play_file(path, options) end

---Like mixer:play_stream(), assigning the writable PCM voice to this group.
---@param spec audio.spec
---@param options? audio.stream_play_options
---@return audio.voice? voice
---@return string? errmsg
function audio.group:play_stream(spec, options) end

---Pause this group's current/future voices, preserving their own pause flags.
---Other groups (for example menu sounds) continue unless the mixer is paused.
---@return boolean? success
---@return string? errmsg
function audio.group:pause() end

---Clear the group's own pause flag; mixer and individual voice pauses still apply.
---@return boolean? success
---@return string? errmsg
function audio.group:resume() end

---Return the group's own pause flag, not the parent mixer's pause flag.
---@return boolean? paused
---@return string? errmsg
function audio.group:is_paused() end

---Return the group's gain, initially 1, excluding mixer/voice gains and fades.
---@return number? gain
---@return string? errmsg
function audio.group:get_gain() end

---Set a persistent multiplier for current AND future voices. Does not overwrite
---their individual gains. This is wrapper behavior, not simply MIX_SetTagGain().
---@param gain number
---@return boolean? success
---@return string? errmsg
function audio.group:set_gain(gain) end

---Stop only this group's current voices. Gain/pause settings and the group remain.
---@param options? audio.stop_options
---@return boolean? success
---@return string? errmsg
function audio.group:stop(options) end

-- Reusable sounds ------------------------------------------------------------

---Return the stable PCM specification used by get_data(), regardless of whether
---this sound stores encoded data or PCM. Does not return a codec/container name.
---@return audio.spec? spec
---@return string? errmsg
function audio.sound:get_spec() end

---Return stored payload bytes: encoded for default loads, PCM for predecoded
---loads/new_sound(). Excludes object overhead and per-voice decoding buffers.
---This changes the old PCM-only meaning; use #get_data() for exact decoded size.
---@return integer? bytes
---@return string? errmsg
function audio.sound:get_size() end

---Return source duration in seconds, excluding playback loops and rate changes.
---An unknown duration returns nil with no error; an infinite source returns
---math.huge. Closed handles return nil, errmsg. Decoder estimates may be inexact.
---SDL reference: https://wiki.libsdl.org/SDL3_mixer/MIX_GetAudioDuration
---@return number? seconds
---@return string? errmsg
function audio.sound:get_duration() end

---Return a fresh table of decoder-supplied tags; missing tags are omitted, not an
---error. new_sound() normally returns an empty table. Changing this table does
---not modify the sound or file. Treat strings as untrusted text when displaying.
---This is loaded-sound metadata, not a reason to load a whole streamed music file
---just to play it. Duration remains available separately through get_duration().
---SDL reference: https://wiki.libsdl.org/SDL3_mixer/MIX_GetAudioProperties
---@return audio.metadata? metadata
---@return string? errmsg
function audio.sound:get_metadata() end

---Return a new string of decoded PCM in get_spec() format, NEVER encoded bytes.
---Encoded sounds are fully decoded synchronously; this may be expensive and does
---not change their storage mode. Already-PCM sounds are copied. Infinite sources
---and results exceeding the supported PCM buffer size return nil, errmsg.
---Useful for synthesis/sample processing and worker PCM transfer, not playback.
---SDL reference: https://wiki.libsdl.org/SDL3_mixer/MIX_DecodeAudio
---@return string? data
---@return string? errmsg
function audio.sound:get_data() end

---Release this handle; further sound operations fail. Active voices retain their
---own native sample references and continue playing. Idempotent.
function audio.sound:close() end

-- Voices ---------------------------------------------------------------------

---Report effective state, including parent pauses. A starved generated voice is
---still "playing", not "finished". "finished" means the source was fully mixed,
---not that hardware has played every sample. "stopped" means explicit stop,
---owner closure, or failure; a failure includes errmsg. Terminal state is retained.
---@return audio.voice_state state
---@return string? errmsg
function audio.voice:get_state() end

---Pause only this voice; queued samples/source position and fade progress remain.
---Mutating playback controls on terminal voices returns nil, errmsg.
---@return boolean? success
---@return string? errmsg
function audio.voice:pause() end

---Clear this voice's own pause flag; group/mixer pauses still apply.
---@return boolean? success
---@return string? errmsg
function audio.voice:resume() end

---Immediately stop by default, or fade then stop. Effective-paused voices stop
---immediately even when a fade is requested. Repeating a pending fade request does
---not restart its countdown; an immediate stop overrides it. Terminal voices
---succeed without changes. A fading voice retains its slot until playback ends.
---SDL reference: https://wiki.libsdl.org/SDL3_mixer/MIX_StopTrack
---@param options? audio.stop_options
---@return boolean? success
---@return string? errmsg
function audio.voice:stop(options) end

---Return the voice's base gain, excluding parents/fades; readable after completion.
---@return number gain
function audio.voice:get_gain() end

---Set base gain; parent gain and fade envelopes continue to multiply it.
---@param gain number
---@return boolean? success
---@return string? errmsg
function audio.voice:set_gain(gain) end

---Return the voice's speed/pitch ratio, excluding mixer rate; readable after completion.
---@return number rate
function audio.voice:get_rate() end

---Set speed/pitch together. Invalid effective sample rates return nil, errmsg.
---Applies to future processing, not samples already submitted to hardware.
---@param rate number
---@return boolean? success
---@return string? errmsg
function audio.voice:set_rate(rate) end

---Return the stereo balance, or nil when disabled; readable after completion.
---@return number? pan
function audio.voice:get_pan() end

---Set stereo balance in [-1, 1]: -1 is left, 0 center, 1 right. Forces a stereo
---downmix onto front left/right; on stereo sources this balances channels, it
---does not relocate all right-channel content into the left channel or vice versa.
---Uses linear attenuation: left gain = 1 - max(pan, 0), right = 1 + min(pan, 0).
---Center leaves both at unity; parent gain and fades still multiply these gains.
---nil disables forced stereo and preserves the normal channel layout. Thus pan=0
---and no pan differ for multichannel material. Final output conversion still applies
---on mono devices. No 3D listener, distance attenuation, or Doppler model is implied.
---SDL reference: https://wiki.libsdl.org/SDL3_mixer/MIX_SetTrackStereo
---@param pan? number Finite value in [-1, 1]; nil disables stereo balance.
---@return boolean? success
---@return string? errmsg
function audio.voice:set_pan(pan) end

---Return source position in seconds, preserving the final value on completion.
---Loops wrap this position; rate changes affect how fast it advances. Unsupported
---source position queries (including writable PCM voices) return nil, errmsg.
---SDL reference: https://wiki.libsdl.org/SDL3_mixer/MIX_GetTrackPlaybackPosition
---@return number? seconds
---@return string? errmsg
function audio.voice:get_position() end

---Return source duration in seconds for a loaded sound or streamed file, without
---loading the whole file. Excludes loops, playback rate, and loop boundaries.
---Returns nil with no error when unknown, including writable PCM sources.
---Infinite sources return math.huge. Decoder estimates may be inexact.
---Remains available after playback ends.
---@return number? seconds
---@return string? errmsg
function audio.voice:get_duration() end

---Seek an active sound/file voice to a nonnegative source offset in seconds.
---Retains pause flags, gain, rate, pan, loop boundaries, and remaining repeat count.
---Targets must be before loop_end when specified. Unsupported/out-of-range seeks
---return nil, errmsg without restarting the voice. Writable PCM voices cannot
---seek. May decode/read synchronously; not all codecs offer identical precision.
---@param seconds number
---@return boolean? success
---@return string? errmsg
function audio.voice:seek(seconds) end

---Write complete PCM frames to a voice created by play_stream(). Copies the data;
---returns its byte count, including zero for "". Other voice kinds, terminal
---voices, and voices whose finish() was called return nil, errmsg.
---No implicit queue cap or partial writes: check get_queued_bytes() before feeding.
---Writing while paused is allowed, but the queue does not drain.
---@param data string
---@return integer? bytes_written
---@return string? errmsg
function audio.voice:write(data) end

---Return unconsumed application-input bytes for a writable PCM voice. Does not
---include all converted/mixed output or hardware buffering. Not a completion
---test: use finish() followed by get_state(). Other voice kinds return nil, errmsg.
---Returns zero after a generated voice has finished/stopped.
---@return integer? bytes
---@return string? errmsg
function audio.voice:get_queued_bytes() end

---Discard buffered PCM on an unfinished writable voice; keep it accepting input.
---Does not retract already mixed/submitted audio or reset producer state.
---Other voice kinds and voices sealed with finish() return nil, errmsg.
---@return boolean? success
---@return string? errmsg
function audio.voice:clear() end

---Signal final input for a writable PCM voice. Flush the conversion tail, reject
---further writes, and finish naturally after queued audio is mixed. Does not
---resume paused parents/voice or wait for hardware. Repeated calls succeed, even
---after completion/stop; non-writable voice kinds return nil, errmsg.
---Unlike a temporarily empty queue, finish() permits natural voice termination.
---@return boolean? success
---@return string? errmsg
function audio.voice:finish() end

-- Recording and offline conversion streams ----------------------------------

---Write complete PCM input frames to an offline converter, returning #data.
---Capture streams reject writes. No implicit queue cap or partial writes.
---@param data string
---@return integer? bytes_written
---@return string? errmsg
function audio.stream:write(data) end

---Read available converted/captured PCM without waiting for hardware. max_bytes
---is positive and rounded down to a whole output frame (must fit at least one).
---Returns "" when no complete frames are ready, not an EOF indication.
---@param max_bytes? integer Default 4096 bytes.
---@return string? data
---@return string? errmsg
function audio.stream:read(max_bytes) end

---Return input/output specs. Capture input is hardware format and may change;
---capture output and both offline converter formats stay as specified by Lua.
---Failure returns nil, nil, errmsg.
---@return audio.spec? input_spec
---@return audio.spec? output_spec
---@return string? errmsg
function audio.stream:get_formats() end

---Return the recording device snapshot. Offline converters return nil, errmsg.
---The requested read format is available through get_formats(), not info.spec.
---@return audio.device_info? info
---@return string? errmsg
function audio.stream:get_device_info() end

---Return unconsumed input bytes. Capture input uses hardware format, not the
---requested read format. Does not include converted output already available.
---@return integer? bytes
---@return string? errmsg
function audio.stream:get_queued_bytes() end

---Return currently available converted output bytes. Conversion may retain a
---partial tail until more input arrives or flush() is called.
---@return integer? bytes
---@return string? errmsg
function audio.stream:get_available_bytes() end

---Make the resampler's remaining tail available; does not close or permanently
---seal the stream. Further writes are allowed but may introduce discontinuities.
---For a capture stream, pause first to flush a completed recording segment.
---@return boolean? success
---@return string? errmsg
function audio.stream:flush() end

---Discard buffered input/output, retaining formats, gain, rate, and pause state.
---Does not stop ongoing capture.
---@return boolean? success
---@return string? errmsg
function audio.stream:clear() end

---Pause capture, retaining queued data. Microphone access is not released.
---Offline converters cannot pause; simply stop feeding/reading them.
---@return boolean? success
---@return string? errmsg
function audio.stream:pause() end

---Resume capture. Audio during the pause was not queued for later capture.
---Offline converters return nil, errmsg.
---@return boolean? success
---@return string? errmsg
function audio.stream:resume() end

---Return capture pause state; offline converters return nil, errmsg.
---@return boolean? paused
---@return string? errmsg
function audio.stream:is_paused() end

---Return the conversion/capture gain, initially 1.
---@return number? gain
---@return string? errmsg
function audio.stream:get_gain() end

---Set gain for future PCM conversion. Zero mutes samples, but does not pause.
---@param gain number
---@return boolean? success
---@return string? errmsg
function audio.stream:set_gain(gain) end

---Return the conversion rate ratio, initially 1.
---@return number? rate
---@return string? errmsg
function audio.stream:get_rate() end

---Set the conversion speed/pitch ratio. Does not change microphone hardware
---capture speed; it changes the resulting PCM duration/pitch. Does not alter
---already converted output. Unsupported effective sample rates return nil, errmsg.
---@param rate number
---@return boolean? success
---@return string? errmsg
function audio.stream:set_rate(rate) end

---Discard queues and close the stream; capture also releases its device.
---Flush/drain first to keep final data. Further operations fail. Idempotent.
function audio.stream:close() end

-- Usage examples -------------------------------------------------------------

--[[
Loaded effects, grouped volume, streamed music, and a native crossfade:

```lua
local audio = require "audio"
local mixer, err = audio.create_mixer({ max_voices = 32 })
if not mixer then return nil, err end -- Continue silently in a real plugin.
local music = assert(mixer:group("music"))
local effects = assert(mixer:group("effects"))
local ui = assert(mixer:group("ui"))
assert(music:set_gain(0.45))
assert(effects:set_gain(0.7))
local shot = assert(audio.load("shot.flac", { predecode = true }))
assert(music:play_file("stage1.ogg", { loops = -1, fade_in = 0.5 }))
assert(effects:play(shot))
assert(effects:play(shot, { gain = 0.5, rate = 1.1, pan = -0.6 }))

-- At a later scene change, fade current music out while the new voice fades in.
assert(music:stop({ fade_out = 0.5 }))
assert(music:play_file("boss.mp3", { loops = -1, fade_in = 0.5 }))
assert(music:pause())
assert(effects:pause()) -- ui remains available for menu feedback.
assert(music:resume())
assert(effects:resume())

-- Store mixer/groups/sounds on the view; do this only when the view closes.
mixer:close()
shot:close()
```
]]

--[[
Generate a reusable tone entirely in Lua, without a file or audio-thread callback:

```lua
local audio = require "audio"
local spec = { format = "f32le", channels = 1, sample_rate = 48000 }
local samples, frames = {}, 4800
for i = 0, frames - 1 do
  local t = i / spec.sample_rate
  local envelope = math.sin(math.pi * i / (frames - 1)) ^ 2
  samples[#samples + 1] = string.pack("<f",
    0.15 * envelope * math.sin(2 * math.pi * 440 * t))
end
local tone = assert(audio.new_sound(table.concat(samples), spec))
local mixer = assert(audio.create_mixer())
assert(mixer:play(tone))
assert(mixer:play(tone, { rate = 1.5, gain = 0.5 }))
-- Retain mixer/tone on the view. Close the mixer when its owner is done.
```
]]

--[[
Incremental synthesis with a bounded input queue and explicit completion:

```lua
local audio = require "audio"
local core = require "core"
local spec = { format = "f32le", channels = 1, sample_rate = 48000 }
local frame_bytes, chunk_frames = 4, 480
local queue_limit = 4800 * frame_bytes
local mixer = assert(audio.create_mixer())
local voice = assert(mixer:play_stream(spec, { paused = true }))
core.add_background_thread(function()
  local ok, err = pcall(function()
    local frame, total = 0, spec.sample_rate * 3
    while frame < total do
      local state, playback_error = voice:get_state()
      if playback_error then error(playback_error) end
      if state == "stopped" then return end
      if assert(voice:get_queued_bytes()) + chunk_frames * frame_bytes <= queue_limit then
        local chunk = {}
        for i = 1, math.min(chunk_frames, total - frame) do
          local value = 0.1 * math.sin(2 * math.pi * 220 * frame / spec.sample_rate)
          chunk[i] = string.pack("<f", value)
          frame = frame + 1
        end
        assert(voice:write(table.concat(chunk)))
        if voice:get_state() == "paused" then assert(voice:resume()) end
      else
        coroutine.yield(0.005)
      end
    end
    assert(voice:finish())
    while true do
      local state, playback_error = voice:get_state()
      if playback_error then error(playback_error) end
      if state == "finished" or state == "stopped" then break end
      coroutine.yield(0.01)
    end
    -- This is a mixer-completion event, not a hardware-latency measurement.
  end)
  if not ok then
    voice:stop()
    core.error("Generated audio: %s", err)
  end
end)
-- This producer is a main-thread coroutine; long UI stalls can still underrun.
-- For expensive synthesis use a worker and transfer PCM chunks, never userdata.
-- Keep mixer on the view; close it when the view closes, not at each chunk/EOF.
```
]]

--[[
Explicit microphone capture into a raw PCM file, not an encoded WAV/Opus file:

```lua
local audio = require "audio"
local core = require "core"
local spec = { format = "s16le", channels = 1, sample_rate = 16000 }
-- Only run after the user requests recording.
local capture = assert(audio.open_recording(spec))
local file, err = io.open("recording.s16le", "wb")
if not file then capture:close(); return nil, err end
core.add_background_thread(function()
  local ok, failure = pcall(function()
    assert(capture:resume())
    local deadline = system.get_time() + 5
    while system.get_time() < deadline do
      assert(file:write(assert(capture:read(4096))))
      coroutine.yield(0.01)
    end
    assert(capture:pause())
    assert(capture:flush())
    while true do
      local chunk = assert(capture:read(4096))
      if chunk == "" then break end
      assert(file:write(chunk))
    end
  end)
  capture:close()
  file:close()
  if not ok then core.error("Audio capture: %s", failure) end
end)
```
]]

--[[
Load encoded bytes, extract PCM, and convert without opening an audio device:

```lua
local audio = require "audio"
local file = assert(io.open("effect.ogg", "rb"))
local data = assert(file:read("*a"))
file:close()
local sound = assert(audio.load_memory(data))
local source = assert(sound:get_spec())
local pcm = assert(sound:get_data()) -- Explicit full decode; can be expensive.
local target = { format = "s16le", channels = 1, sample_rate = 16000 }
local converted = assert(audio.convert(pcm, source, target))
local reusable = assert(audio.new_sound(converted, target))
sound:close()

-- For a sequence of PCM chunks retain ONE converter, not one per chunk.
local converter = assert(audio.create_stream(source, target))
assert(converter:write(pcm))
assert(converter:flush())
while true do
  local chunk = assert(converter:read(4096))
  if chunk == "" then break end
  -- Consume or write each converted chunk here.
end
converter:close()
reusable:close()
```
]]

--[[
Play an intro once, repeat a region twice more, and receive a completion callback:

```lua
local audio = require "audio"
local core = require "core"
local mixer = assert(audio.create_mixer())
local sound = assert(audio.load("mission.ogg")) -- A source at least 20 seconds long.
local metadata = assert(sound:get_metadata())
core.log("Playing %s", metadata.title or "mission.ogg")
local voice = assert(mixer:play(sound, {
  start = 0,
  loop_start = 4,
  loop_end = 20,
  loops = 2, -- 20 + 16 + 16 seconds at rate 1; no outro after the final repeat.
  on_complete = function(completed, reason, err)
    if reason == "error" then
      core.error("Mission audio: %s", err)
    elseif reason == "finished" then
      core.log("Mission audio finished mixing at %.2fs", completed:get_position())
    end
  end
}))
assert(voice:set_pan(-0.5)) -- Can be updated later as an object moves.
assert(voice:set_pan(nil)) -- Restore normal channel layout.
sound:close() -- Playback keeps its own reference to the source.
-- Retain mixer/voice on the view. The editor dispatches the callback automatically.
-- Stopping notifies with "stopped"; closing the mixer instead cancels notifications.
```
]]

--[[
Start streamed music layers together and change intensity without losing alignment:

```lua
local audio = require "audio"
local mixer = assert(audio.create_mixer())
local music = assert(mixer:group("music"))
-- Use stems exported with matching source lengths, loop points, and sample rates.
local drums = assert(music:play_file("drums.ogg", { paused = true, loops = -1 }))
local melody, err = music:play_file("melody.ogg", {
  paused = true, loops = -1, gain = 0
})
if not melody then mixer:close(); return nil, err end
local started, failure = mixer:resume_together({ drums, melody })
if not started then mixer:close(); return nil, failure end

-- At a later event: the muted layer has kept playing, so unmuting stays in phase.
assert(melody:set_gain(0.6))
assert(mixer:set_rate(0.8)) -- Slow both layers; pitch also drops.
-- A prefilled play_stream(spec, { paused = true }) voice can join the same batch.
-- Retain mixer/groups/voices on the view; close the mixer when the view closes.
```
]]

--[[
Render eight seconds of layered audio to raw PCM without a device, also in workers:

```lua
local audio = require "audio"
local spec = { format = "f32le", channels = 2, sample_rate = 48000 }
local mixer = assert(audio.create_mixer({ offline = true, spec = spec }))
local output, err = io.open("mix.f32le", "wb")
if not output then mixer:close(); return nil, err end
local completed = 0
local ok, failure = pcall(function()
  local function on_complete(_, reason, playback_error)
    if reason == "error" then error(playback_error) end
    if reason == "finished" then completed = completed + 1 end
  end
  local bed = assert(mixer:play_file("bed.flac", {
    paused = true, gain = 0.5, on_complete = on_complete
  }))
  local accent = assert(mixer:play_file("accent.ogg", {
    paused = true, pan = 0.4, on_complete = on_complete
  }))
  assert(mixer:resume_together({ bed, accent }))
  local remaining = spec.sample_rate * 8
  while remaining > 0 do
    local frames = math.min(4096, remaining)
    local pcm, mixed_frames, render_error = mixer:render(frames)
    assert(pcm, render_error)
    assert(output:write(pcm)) -- Keep padding for an exact eight-second output.
    -- mixed_frames can be zero even for paused/starved, not yet finished voices.
    local dispatched, callback_error = mixer:dispatch_events()
    assert(dispatched, callback_error)
    assert(not callback_error, callback_error)
    remaining = remaining - frames
  end
end)
output:close()
mixer:close() -- Stops any source longer than the chosen render duration.
if not ok then return nil, failure end
return completed -- Natural completions processed by the owning Lua thread.
```
]]

-- Implementation notes:
-- - Bind each streamed file/PCM queue to one native track, with owned lifetimes.
-- - Empty writable queues must not end playback; finish() seals and flushes them.
-- - Preserve individual pause flags under group/mixer pause, including new voices.
-- - Groups multiply gains; applying MIX_SetTagGain alone would overwrite gains.
-- - Validate unsupported loop/seek requests instead of accepting silent fallback.
-- - Convert loop_end to the absolute MIX_PROP_PLAY_MAX_FRAME_NUMBER limit, not
--   a repeat count or elapsed-playback duration. All boundaries use source frames.
-- - Configure/start paused voices without a mixing window before pause is applied.
--   resume_together validates first and performs resumes under MIX_LockMixer;
--   roll back before unlocking on failure. Do no file loading or Lua work there.
--   MIX_PlayTag alone is not transactional: it may start some tracks on failure.
-- - Native completion callbacks only queue terminal data. Release slots/decoders
--   without waiting for Lua. Dispatch retained Lua handlers on their owning thread
--   outside mixer locks; never run them during mixing, finalization, or shutdown.
-- - Offline rendering uses MIX_CreateMixer/MIX_Generate. Preserve the returned
--   non-padding frame count; do not infer it by scanning for zero-valued samples.
-- - Codec initialization/shutdown and callback cleanup must be native and safe
--   across Lua-state restart. Do not expose MIX_Quit or audio-thread Lua callbacks.
-- - This API does not add compressed encoding, independent pitch shifting,
--   arbitrary Lua DSP callbacks, or a full 3D audio engine.
--
-- scripts/lua/tests/audio.lua covers codecs, streaming, underrun/finish, groups,
-- fades, seeking, lifetime/GC, capture, conversion, loops, stereo balance,
-- synchronized starts, completion callbacks, and offline rendering/rates.
-- PRAGTICAL_AUDIO_EXACT=1 enables stricter resampled output/count checks;
-- PRAGTICAL_AUDIO_STRESS=1 enables tiny requests/loops. These opt-in suites
-- require the optional playback patch with SDL_mixer 3.2.4.
-- Dummy-driver tests cannot verify audible quality, hardware latency, microphone
-- permissions, or device-default migration.

return audio
