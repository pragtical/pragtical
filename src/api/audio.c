#include "api.h"
#include "custom_events.h"

#include <SDL3/SDL.h>
#include <SDL3_mixer/SDL_mixer.h>
#include <float.h>
#include <limits.h>
#include <math.h>
#include <string.h>

#define AUDIO_ALLOCATION "AudioAllocation"
#define AUDIO_MIXERS "audio.mixers"
#define AUDIO_EVENT "audio.complete"
#define AUDIO_TRACK_ERROR "Pragtical.audio.error"
#define AUDIO_SAMPLE_FRAMES 65536

typedef struct AudioMixer AudioMixer;
typedef struct AudioGroup AudioGroup;
typedef struct AudioVoice AudioVoice;
typedef struct AudioStream AudioStream;

typedef struct {
  MIX_Audio *audio;
  SDL_AudioSpec spec;
  void *data;
  size_t size;
  unsigned refs;
  bool pcm;
} AudioSound;

struct AudioGroup {
  AudioMixer *mixer;
  AudioGroup *next;
  float gain;
  bool paused;
};

typedef enum { VOICE_ACTIVE, VOICE_FINISHED, VOICE_STOPPED } VoiceState;
struct AudioVoice {
  AudioMixer *mixer;
  AudioGroup *group;
  AudioVoice *next;
  MIX_Track *track;
  SDL_AudioStream *stream;
  SDL_AudioSpec spec;
  Sint64 position, duration, end, fade_in;
  unsigned refs;
  float gain, rate, pan;
  bool panning, paused, writable, sealed, stopping, notify;
  VoiceState state;
  SDL_AtomicInt done;
  char error[256];
};

struct AudioMixer {
  MIX_Mixer *mixer;
  AudioMixer *next;
  AudioGroup *groups;
  AudioVoice *voices;
  SDL_AudioDeviceID device;
  SDL_AudioSpec spec;
  unsigned refs;
  int max_voices, voice_count;
  float gain, rate;
  bool offline, follows_default, paused, main_thread, dispatching;
  SDL_AtomicInt pending;
  float *samples;
  SDL_AudioSpec sample_spec;
  int sample_capacity, sample_count, sample_write;
};

struct AudioStream {
  SDL_AudioStream *stream;
  SDL_AudioDeviceID device;
  AudioStream *next;
  bool recording, follows_default;
};

/* Lua allocation and callbacks must never happen under this ownership lock.
 * Lock order is ownership -> MIX mixer -> SDL stream. Audio callbacks only use
 * their existing MIX lock and atomics; the reaper destroys tracks afterwards. */
static SDL_Mutex *audio_mutex;
static SDL_SpinLock mutex_init;
static SDL_Semaphore *audio_wake;
static SDL_Thread *audio_reaper;
static AudioMixer *mixers;
static AudioStream *recordings;
static unsigned sound_count;
static bool hardware_initialized, mixer_initialized, audio_stopping;
static SDL_AtomicInt main_pending;

static const struct { const char *name; SDL_AudioFormat value; } formats[] = {
  { "u8", SDL_AUDIO_U8 }, { "s8", SDL_AUDIO_S8 },
  { "s16le", SDL_AUDIO_S16LE }, { "s16be", SDL_AUDIO_S16BE },
  { "s32le", SDL_AUDIO_S32LE }, { "s32be", SDL_AUDIO_S32BE },
  { "f32le", SDL_AUDIO_F32LE }, { "f32be", SDL_AUDIO_F32BE },
  { "s16", SDL_AUDIO_S16 }, { "s32", SDL_AUDIO_S32 }, { "f32", SDL_AUDIO_F32 }
};

static int audio_error(lua_State *L) {
  char error[1024];
  SDL_strlcpy(error, SDL_GetError(), sizeof(error));
  lua_pushnil(L); lua_pushstring(L, error);
  return 2;
}

static int audio_result(lua_State *L, bool ok) {
  SDL_UnlockMutex(audio_mutex);
  if (!ok) return audio_error(L);
  lua_pushboolean(L, true);
  return 1;
}

static void *new_object(lua_State *L, size_t size, const char *type) {
  void *object = lua_newuserdata(L, size);
  SDL_memset(object, 0, size);
  luaL_setmetatable(L, type);
  return object;
}

static int allocation_gc(lua_State *L) {
  void **data = luaL_checkudata(L, 1, AUDIO_ALLOCATION);
  SDL_free(*data); *data = NULL;
  return 0;
}

static int check_integer(lua_State *L, int index, int min, int max) {
  luaL_checktype(L, index, LUA_TNUMBER);
  lua_Number value = lua_tonumber(L, index);
  luaL_argcheck(L, isfinite(value) && value >= min && value <= max
    && floor(value) == value, index, "integer out of range");
  return (int) value;
}

static double check_number(lua_State *L, int index, double min, double max) {
  luaL_checktype(L, index, LUA_TNUMBER);
  double value = lua_tonumber(L, index);
  luaL_argcheck(L, isfinite(value) && value >= min && value <= max, index, "number out of range");
  return value;
}

static float check_multiplier(lua_State *L, int index, bool rate) {
  return (float) check_number(L, index, rate ? 0.01 : 0, rate ? 100 : FLT_MAX);
}

static bool option_bool(lua_State *L, int table, const char *key, bool fallback) {
  lua_getfield(L, table, key);
  if (!lua_isnil(L, -1)) {
    luaL_checktype(L, -1, LUA_TBOOLEAN);
    fallback = lua_toboolean(L, -1);
  }
  lua_pop(L, 1);
  return fallback;
}

static double option_number(lua_State *L, int table, const char *key, double fallback, double min, double max) {
  lua_getfield(L, table, key);
  if (!lua_isnil(L, -1)) fallback = check_number(L, -1, min, max);
  lua_pop(L, 1);
  return fallback;
}

static SDL_AudioSpec check_spec(lua_State *L, int index) {
  SDL_AudioSpec spec = {0};
  index = lua_absindex(L, index);
  luaL_checktype(L, index, LUA_TTABLE);
  lua_getfield(L, index, "format");
  luaL_checktype(L, -1, LUA_TSTRING);
  size_t size;
  const char *name = lua_tolstring(L, -1, &size);
  for (size_t i = 0; i < SDL_arraysize(formats); i++) {
    if (strlen(formats[i].name) == size && memcmp(name, formats[i].name, size) == 0) {
      spec.format = formats[i].value; break;
    }
  }
  luaL_argcheck(L, spec.format != SDL_AUDIO_UNKNOWN, index, "unsupported PCM format");
  lua_pop(L, 1);
  lua_getfield(L, index, "channels"); spec.channels = check_integer(L, -1, 1, 8); lua_pop(L, 1);
  lua_getfield(L, index, "sample_rate"); spec.freq = check_integer(L, -1, 1, INT_MAX); lua_pop(L, 1);
  return spec;
}

static bool valid_frequency(const SDL_AudioSpec *spec, float rate) {
  float frequency = (float) spec->freq * rate;
  return (frequency >= 1 && frequency < (float) INT_MAX)
    || SDL_SetError("sample rate and playback rate exceed SDL's conversion range");
}

static void push_spec(lua_State *L, const SDL_AudioSpec *spec) {
  lua_createtable(L, 0, 3);
  for (size_t i = 0; i < SDL_arraysize(formats); i++) {
    if (formats[i].value == spec->format) {
      lua_pushstring(L, formats[i].name); lua_setfield(L, -2, "format"); break;
    }
  }
  lua_pushinteger(L, spec->channels); lua_setfield(L, -2, "channels");
  lua_pushinteger(L, spec->freq); lua_setfield(L, -2, "sample_rate");
}

static const char *check_pcm(lua_State *L, int index, const SDL_AudioSpec *spec, int *size, bool empty) {
  size_t bytes;
  luaL_checktype(L, index, LUA_TSTRING);
  const char *data = lua_tolstring(L, index, &bytes);
  luaL_argcheck(L, bytes <= INT_MAX && (empty || bytes > 0)
    && bytes % SDL_AUDIO_FRAMESIZE(*spec) == 0, index, "expected complete PCM frames within INT_MAX bytes");
  *size = (int) bytes;
  return data;
}

static const char *check_path(lua_State *L, int index) {
  size_t size;
  luaL_checktype(L, index, LUA_TSTRING);
  const char *path = lua_tolstring(L, index, &size);
  luaL_argcheck(L, size == strlen(path), index, "path contains NUL");
  return path;
}

static SDL_AudioDeviceID check_device(lua_State *L, int options, bool recording, bool *follows_default) {
  SDL_AudioDeviceID id = recording ? SDL_AUDIO_DEVICE_DEFAULT_RECORDING : SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK;
  *follows_default = true;
  if (!lua_isnoneornil(L, options)) {
    lua_getfield(L, options, "id");
    if (!lua_isnil(L, -1)) {
      double value = check_number(L, -1, 1, SDL_AUDIO_DEVICE_DEFAULT_RECORDING - 1.0);
      luaL_argcheck(L, value == floor(value), options, "invalid device ID");
      id = (SDL_AudioDeviceID) value;
      *follows_default = false;
    }
    lua_pop(L, 1);
  }
  return id;
}

static bool init_locked(bool hardware) {
  if (audio_stopping) return SDL_SetError("audio is shutting down");
  if (hardware && !SDL_IsMainThread()) return SDL_SetError("audio devices require the main thread");
  if (hardware && !hardware_initialized) {
    if (!SDL_InitSubSystem(SDL_INIT_AUDIO)) return false;
    hardware_initialized = true;
  }
  if (!mixer_initialized) {
    if (!MIX_Init()) return false;
    mixer_initialized = true;
  }
  return true;
}

static void maybe_quit(void) {
  if (audio_stopping && mixer_initialized && !mixers && !sound_count) {
    MIX_Quit(); mixer_initialized = false;
  }
}

static bool mixer_open(AudioMixer *mixer) {
  return (mixer && mixer->mixer) || SDL_SetError("audio mixer is closed");
}

static void mixer_unref(AudioMixer *mixer) {
  if (mixer && --mixer->refs == 0) {
    while (mixer->groups) {
      AudioGroup *next = mixer->groups->next;
      SDL_free(mixer->groups); mixer->groups = next;
    }
    SDL_free(mixer);
  }
}

static void voice_unref(AudioVoice *voice) {
  if (voice && --voice->refs == 0) {
    mixer_unref(voice->mixer);
    SDL_free(voice);
  }
}

static bool voice_paused(AudioVoice *voice) {
  return voice->paused || voice->mixer->paused || (voice->group && voice->group->paused);
}

static void SDLCALL voice_stopped(void *userdata, MIX_Track *track) {
  AudioVoice *voice = userdata;
  voice->position = MIX_GetTrackPlaybackPosition(track);
  SDL_strlcpy(voice->error, SDL_GetStringProperty(MIX_GetTrackProperties(track), AUDIO_TRACK_ERROR, ""), sizeof(voice->error));
  SDL_SetAtomicInt(&voice->done, 1);
  if (voice->notify) {
    SDL_SetAtomicInt(&voice->mixer->pending, 1);
    if (voice->mixer->main_thread && !SDL_SetAtomicInt(&main_pending, 1)) {
      CustomEvent event = {0};
      push_custom_event(AUDIO_EVENT, &event);
    }
  }
  SDL_SignalSemaphore(audio_wake);
}

static void collect_voices(AudioMixer *mixer) {
  AudioVoice **link = &mixer->voices;
  while (*link) {
    AudioVoice *voice = *link;
    if (!SDL_GetAtomicInt(&voice->done)) { link = &voice->next; continue; }
    MIX_DestroyTrack(voice->track); voice->track = NULL;
    SDL_DestroyAudioStream(voice->stream); voice->stream = NULL;
    voice->state = voice->stopping || *voice->error ? VOICE_STOPPED : VOICE_FINISHED;
    *link = voice->next; voice->next = NULL;
    mixer->voice_count--;
    voice_unref(voice);
  }
}

/* MIX holds its mixer lock here. Never call Lua, allocate, or acquire the
 * ownership mutex from the audio thread. Keep only the newest complete frames. */
static void SDLCALL mixer_samples(void *userdata, MIX_Mixer *native,
    const SDL_AudioSpec *spec, float *pcm, int samples) {
  (void) native;
  AudioMixer *mixer = userdata;
  int channels = spec->channels;
  if (channels < 1 || channels > 8 || samples <= 0) return;
  if (mixer->sample_spec.channels != channels || mixer->sample_spec.freq != spec->freq) {
    mixer->sample_count = mixer->sample_write = 0;
    mixer->sample_spec = *spec;
  }
  int frames = samples / channels;
  if (frames > mixer->sample_capacity) {
    pcm += (frames - mixer->sample_capacity) * channels;
    frames = mixer->sample_capacity;
  }
  int first = SDL_min(frames, mixer->sample_capacity - mixer->sample_write);
  SDL_memcpy(mixer->samples + mixer->sample_write * channels, pcm,
    first * channels * sizeof(float));
  SDL_memcpy(mixer->samples, pcm + first * channels,
    (frames - first) * channels * sizeof(float));
  mixer->sample_write = (mixer->sample_write + frames) % mixer->sample_capacity;
  mixer->sample_count = SDL_min(mixer->sample_count + frames, mixer->sample_capacity);
}

static void mixer_close(AudioMixer *mixer) {
  if (!mixer || !mixer->mixer) return;
  MIX_LockMixer(mixer->mixer);
  for (AudioVoice *voice = mixer->voices; voice; voice = voice->next) {
    MIX_SetTrackStoppedCallback(voice->track, NULL, NULL);
    if (!SDL_GetAtomicInt(&voice->done)) {
      voice->position = MIX_GetTrackPlaybackPosition(voice->track);
      voice->stopping = true;
      SDL_SetAtomicInt(&voice->done, 1);
    }
  }
  MIX_UnlockMixer(mixer->mixer);
  collect_voices(mixer);
  MIX_DestroyMixer(mixer->mixer); mixer->mixer = NULL;
  SDL_free(mixer->samples); mixer->samples = NULL;
  mixer->sample_capacity = mixer->sample_count = mixer->sample_write = 0;
  mixer->device = 0;
  AudioMixer **link = &mixers;
  while (*link != mixer) link = &(*link)->next;
  *link = mixer->next; mixer->next = NULL;
  maybe_quit();
}

static int SDLCALL reap_voices(void *unused) {
  (void) unused;
  for (;;) {
    SDL_WaitSemaphore(audio_wake);
    SDL_LockMutex(audio_mutex);
    if (audio_stopping) { SDL_UnlockMutex(audio_mutex); return 0; }
    for (AudioMixer *mixer = mixers; mixer; mixer = mixer->next) collect_voices(mixer);
    SDL_UnlockMutex(audio_mutex);
  }
}

static bool start_reaper(void) {
  if (audio_reaper) return true;
  audio_wake = SDL_CreateSemaphore(0);
  if (!audio_wake) return false;
  audio_reaper = SDL_CreateThread(reap_voices, "audio-voices", NULL);
  if (!audio_reaper) { SDL_DestroySemaphore(audio_wake); audio_wake = NULL; return false; }
  return true;
}

static void sound_unref(AudioSound *sound) {
  if (sound && --sound->refs == 0) {
    MIX_DestroyAudio(sound->audio);
    SDL_free(sound);
    sound_count--;
    maybe_quit();
  }
}

static bool stream_open(AudioStream *stream) {
  return stream->stream || SDL_SetError("audio stream is closed");
}

static void stream_close(AudioStream *stream) {
  if (!stream->stream) return;
  SDL_DestroyAudioStream(stream->stream); stream->stream = NULL;
  if (stream->device) {
    SDL_CloseAudioDevice(stream->device); stream->device = 0;
    AudioStream **link = &recordings;
    while (*link != stream) link = &(*link)->next;
    *link = stream->next; stream->next = NULL;
  }
}

void api_audio_shutdown(void) {
  if (!audio_mutex) return;
  SDL_LockMutex(audio_mutex);
  audio_stopping = true;
  SDL_Thread *reaper = audio_reaper;
  if (audio_wake) SDL_SignalSemaphore(audio_wake);
  SDL_UnlockMutex(audio_mutex);
  if (reaper) SDL_WaitThread(reaper, NULL);
  SDL_LockMutex(audio_mutex);
  while (mixers) mixer_close(mixers);
  while (recordings) stream_close(recordings);
  SDL_DestroySemaphore(audio_wake); audio_wake = NULL; audio_reaper = NULL;
  maybe_quit();
  if (hardware_initialized) SDL_QuitSubSystem(SDL_INIT_AUDIO);
  hardware_initialized = false;
  SDL_UnlockMutex(audio_mutex);
}

static int f_get_drivers(lua_State *L) {
  int count = SDL_GetNumAudioDrivers();
  lua_createtable(L, count, 0);
  for (int i = 0; i < count; i++) {
    lua_pushstring(L, SDL_GetAudioDriver(i)); lua_rawseti(L, -2, i + 1);
  }
  return 1;
}

static int f_get_driver(lua_State *L) {
  char name[128] = "";
  SDL_LockMutex(audio_mutex);
  const char *driver = hardware_initialized ? SDL_GetCurrentAudioDriver() : NULL;
  if (driver) SDL_strlcpy(name, driver, sizeof(name));
  SDL_UnlockMutex(audio_mutex);
  if (*name) lua_pushstring(L, name); else lua_pushnil(L);
  return 1;
}

static int f_get_decoders(lua_State *L) {
  SDL_LockMutex(audio_mutex);
  bool ok = init_locked(false);
  int count = ok ? MIX_GetNumAudioDecoders() : -1;
  SDL_UnlockMutex(audio_mutex);
  if (count < 0) return audio_error(L);
  lua_createtable(L, count, 0);
  for (int i = 0; i < count; i++) {
    lua_pushstring(L, MIX_GetAudioDecoder(i)); lua_rawseti(L, -2, i + 1);
  }
  return 1;
}

static int f_get_devices(lua_State *L) {
  static const char *const kinds[] = { "playback", "recording", NULL };
  bool recording = luaL_checkoption(L, 1, "playback", kinds) == 1;
  void **allocation = new_object(L, sizeof(void *), AUDIO_ALLOCATION);
  SDL_LockMutex(audio_mutex);
  if (!init_locked(true)) { SDL_UnlockMutex(audio_mutex); return audio_error(L); }
  int count = 0;
  SDL_AudioDeviceID *ids = recording ? SDL_GetAudioRecordingDevices(&count) : SDL_GetAudioPlaybackDevices(&count);
  *allocation = ids;
  SDL_UnlockMutex(audio_mutex);
  if (!ids) return audio_error(L);
  lua_createtable(L, count, 0);
  for (int i = 0; i < count; i++) {
    const char *name = SDL_GetAudioDeviceName(ids[i]);
    lua_createtable(L, 0, 3);
    lua_pushnumber(L, ids[i]); lua_setfield(L, -2, "id");
    lua_pushstring(L, name ? name : ""); lua_setfield(L, -2, "name");
    lua_pushstring(L, kinds[recording]); lua_setfield(L, -2, "kind");
    lua_rawseti(L, -2, i + 1);
  }
  SDL_free(ids); *allocation = NULL;
  return 1;
}

static bool validate_device(SDL_AudioDeviceID id, bool follows_default, bool recording) {
  return follows_default || (SDL_IsAudioDevicePhysical(id) && SDL_IsAudioDevicePlayback(id) != recording)
    || SDL_SetError("audio device ID is not a physical device of the requested kind");
}

static int f_create_mixer(lua_State *L) {
  lua_settop(L, 1);
  bool offline = false, has_spec = false, follows_default;
  SDL_AudioSpec spec = {0};
  int max_voices = 64;
  if (!lua_isnil(L, 1)) {
    luaL_checktype(L, 1, LUA_TTABLE);
    offline = option_bool(L, 1, "offline", false);
    lua_getfield(L, 1, "spec");
    if (!lua_isnil(L, -1)) { spec = check_spec(L, -1); has_spec = true; }
    lua_pop(L, 1);
    lua_getfield(L, 1, "max_voices");
    if (!lua_isnil(L, -1)) max_voices = check_integer(L, -1, 1, INT_MAX);
    lua_pop(L, 1);
  }
  SDL_AudioDeviceID id = check_device(L, 1, false, &follows_default);
  luaL_argcheck(L, !offline || (has_spec && follows_default), 1, "offline mixers require spec and cannot select a device");
  AudioMixer **ud = new_object(L, sizeof(*ud), API_TYPE_AUDIO_MIXER);
  int object = lua_gettop(L);
  lua_newtable(L);
  lua_newtable(L); lua_setfield(L, -2, "groups");
  lua_newtable(L); lua_setfield(L, -2, "callbacks");
  lua_setuservalue(L, object);
  if (has_spec && !valid_frequency(&spec, 1)) return audio_error(L);
  SDL_LockMutex(audio_mutex);
  if (!init_locked(!offline) || (!offline && !validate_device(id, follows_default, false)) || !start_reaper()) {
    SDL_UnlockMutex(audio_mutex); return audio_error(L);
  }
  AudioMixer *mixer = SDL_calloc(1, sizeof(*mixer));
  if (!mixer) { SDL_OutOfMemory(); SDL_UnlockMutex(audio_mutex); return audio_error(L); }
  mixer->mixer = offline ? MIX_CreateMixer(&spec) : MIX_CreateMixerDevice(id, has_spec ? &spec : NULL);
  if (!mixer->mixer) { SDL_free(mixer); SDL_UnlockMutex(audio_mutex); return audio_error(L); }
  mixer->refs = 1;
  mixer->offline = offline;
  mixer->main_thread = SDL_IsMainThread();
  mixer->follows_default = follows_default;
  mixer->gain = mixer->rate = 1;
  mixer->max_voices = max_voices;
  MIX_GetMixerFormat(mixer->mixer, &mixer->spec);
  mixer->device = (SDL_AudioDeviceID) SDL_GetNumberProperty(MIX_GetMixerProperties(mixer->mixer), MIX_PROP_MIXER_DEVICE_NUMBER, 0);
  mixer->next = mixers; mixers = mixer;
  *ud = mixer;
  SDL_UnlockMutex(audio_mutex);
  lua_getfield(L, LUA_REGISTRYINDEX, AUDIO_MIXERS);
  lua_pushlightuserdata(L, mixer); lua_pushvalue(L, object); lua_rawset(L, -3);
  lua_settop(L, object);
  return 1;
}

/* The returned allocation is owned by the caller, even on failure. */
static bool decode_pcm(const void *data, size_t size, SDL_AudioSpec *spec, void **pcm, size_t *bytes, SDL_PropertiesID metadata) {
  SDL_IOStream *io = SDL_IOFromConstMem(data, size);
  if (!io) return false;
  MIX_AudioDecoder *decoder = MIX_CreateAudioDecoder_IO(io, false, 0);
  if (!decoder) { SDL_CloseIO(io); return false; }
  bool ok = MIX_GetAudioDecoderFormat(decoder, spec) && valid_frequency(spec, 1);
  SDL_PropertiesID props = MIX_GetAudioDecoderProperties(decoder);
  if (ok && SDL_GetBooleanProperty(props, MIX_PROP_METADATA_DURATION_INFINITE_BOOLEAN, false))
    ok = SDL_SetError("cannot extract infinite audio into a PCM buffer");
  if (ok && metadata) ok = SDL_CopyProperties(props, metadata);
  size_t capacity = 0;
  *bytes = 0;
  while (ok) {
    size_t frame = SDL_AUDIO_FRAMESIZE(*spec);
    size_t limit = INT_MAX / frame * frame;
    if (capacity - *bytes < 65536) {
      size_t next = SDL_min(limit, capacity ? capacity * 2 : 65536);
      if (next == capacity) { ok = SDL_SetError("decoded PCM exceeds INT_MAX bytes"); break; }
      void *buffer = SDL_realloc(*pcm, next);
      if (!buffer) { ok = false; break; }
      *pcm = buffer; capacity = next;
    }
    int chunk = (int) (SDL_min(capacity - *bytes, 65536) / frame * frame);
    int read = MIX_DecodeAudio(decoder, (char *) *pcm + *bytes, chunk, spec);
    if (read < 0) { ok = false; break; }
    *bytes += (size_t) read;
    if (!read) break;
  }
  MIX_DestroyAudioDecoder(decoder);
  SDL_CloseIO(io);
  return ok;
}

static int f_load(lua_State *L) {
  bool memory = lua_toboolean(L, lua_upvalueindex(1));
  lua_settop(L, 2);
  size_t size = 0;
  luaL_checktype(L, 1, LUA_TSTRING);
  const char *input = memory ? lua_tolstring(L, 1, &size) : check_path(L, 1);
  bool predecode = false;
  if (!lua_isnil(L, 2)) {
    luaL_checktype(L, 2, LUA_TTABLE);
    predecode = option_bool(L, 2, "predecode", false);
  }
  void **buffer = new_object(L, sizeof(*buffer), AUDIO_ALLOCATION);
  void **decoded = new_object(L, sizeof(*decoded), AUDIO_ALLOCATION);
  AudioSound **ud = new_object(L, sizeof(*ud), API_TYPE_AUDIO_SOUND);
  SDL_LockMutex(audio_mutex);
  if (!init_locked(false)) { SDL_UnlockMutex(audio_mutex); return audio_error(L); }
  *buffer = memory ? SDL_malloc(size ? size : 1) : SDL_LoadFile(input, &size);
  if (*buffer && memory) SDL_memcpy(*buffer, input, size);
  AudioSound *sound = *buffer ? SDL_calloc(1, sizeof(*sound)) : NULL;
  if (!sound) { SDL_UnlockMutex(audio_mutex); return audio_error(L); }
  sound->refs = 1;
  sound_count++;
  *ud = sound;
  bool ok = true;
  SDL_PropertiesID metadata = predecode ? SDL_CreateProperties() : 0;
  if (predecode) {
    ok = metadata && decode_pcm(*buffer, size, &sound->spec, decoded, &sound->size, metadata);
    if (ok) sound->audio = MIX_LoadRawAudioNoCopy(NULL, *decoded, sound->size, &sound->spec, true);
    if (sound->audio) {
      sound->data = *decoded; *decoded = NULL; sound->pcm = true;
      ok = SDL_CopyProperties(metadata, MIX_GetAudioProperties(sound->audio));
    }
  } else {
    sound->audio = MIX_LoadAudioNoCopy(NULL, *buffer, size, true);
    if (sound->audio) {
      sound->data = *buffer; *buffer = NULL; sound->size = size;
      ok = MIX_GetAudioFormat(sound->audio, &sound->spec);
    }
  }
  SDL_DestroyProperties(metadata);
  ok = ok && sound->audio && valid_frequency(&sound->spec, 1);
  SDL_free(*buffer); *buffer = NULL;
  SDL_free(*decoded); *decoded = NULL;
  if (!ok) { sound_unref(sound); *ud = NULL; }
  SDL_UnlockMutex(audio_mutex);
  if (!ok) return audio_error(L);
  return 1;
}

static int f_new_sound(lua_State *L) {
  SDL_AudioSpec spec = check_spec(L, 2);
  int size;
  const char *data = check_pcm(L, 1, &spec, &size, false);
  AudioSound **ud = new_object(L, sizeof(*ud), API_TYPE_AUDIO_SOUND);
  SDL_LockMutex(audio_mutex);
  if (!init_locked(false) || !valid_frequency(&spec, 1)) { SDL_UnlockMutex(audio_mutex); return audio_error(L); }
  AudioSound *sound = SDL_calloc(1, sizeof(*sound));
  if (!sound) { SDL_UnlockMutex(audio_mutex); return audio_error(L); }
  sound->data = SDL_malloc((size_t) size);
  if (sound->data) {
    SDL_memcpy(sound->data, data, size);
    sound->audio = MIX_LoadRawAudioNoCopy(NULL, sound->data, size, &spec, true);
  }
  if (!sound->audio) {
    SDL_free(sound->data); SDL_free(sound);
    SDL_UnlockMutex(audio_mutex); return audio_error(L);
  }
  sound->refs = 1; sound->pcm = true; sound->size = size; sound->spec = spec;
  sound_count++; *ud = sound;
  SDL_UnlockMutex(audio_mutex);
  return 1;
}

static int f_sound_close(lua_State *L) {
  AudioSound **ud = luaL_checkudata(L, 1, API_TYPE_AUDIO_SOUND);
  SDL_LockMutex(audio_mutex); sound_unref(*ud); *ud = NULL; SDL_UnlockMutex(audio_mutex);
  return 0;
}

static AudioSound *check_sound(lua_State *L) {
  AudioSound *sound = *(AudioSound **) luaL_checkudata(L, 1, API_TYPE_AUDIO_SOUND);
  if (!sound) SDL_SetError("audio sound is closed");
  return sound;
}

static int f_sound_get_spec(lua_State *L) {
  AudioSound *sound = check_sound(L);
  if (!sound) return audio_error(L);
  SDL_AudioSpec spec = sound->spec;
  push_spec(L, &spec);
  return 1;
}

static int f_sound_get_size(lua_State *L) {
  AudioSound *sound = check_sound(L);
  if (!sound) return audio_error(L);
  lua_pushinteger(L, (lua_Integer) sound->size);
  return 1;
}

static int f_sound_get_duration(lua_State *L) {
  AudioSound *sound = check_sound(L);
  if (!sound) return audio_error(L);
  Sint64 frames = MIX_GetAudioDuration(sound->audio);
  if (frames == MIX_DURATION_UNKNOWN) lua_pushnil(L);
  else lua_pushnumber(L, frames == MIX_DURATION_INFINITE ? HUGE_VAL : (double) frames / sound->spec.freq);
  return 1;
}

static AudioSound *guard_sound(lua_State *L) {
  AudioSound **owner = luaL_checkudata(L, 1, API_TYPE_AUDIO_SOUND);
  AudioSound **guard = new_object(L, sizeof(*guard), API_TYPE_AUDIO_SOUND);
  AudioSound *sound = *owner;
  if (sound) {
    SDL_LockMutex(audio_mutex); sound->refs++; *guard = sound; SDL_UnlockMutex(audio_mutex);
  } else SDL_SetError("audio sound is closed");
  return sound;
}

static int f_sound_get_data(lua_State *L) {
  AudioSound *sound = guard_sound(L);
  if (!sound) return audio_error(L);
  if (sound->pcm) { lua_pushlstring(L, sound->data, sound->size); return 1; }
  void **buffer = new_object(L, sizeof(*buffer), AUDIO_ALLOCATION);
  size_t bytes;
  SDL_AudioSpec spec;
  SDL_LockMutex(audio_mutex);
  bool ok = decode_pcm(sound->data, sound->size, &spec, buffer, &bytes, 0);
  SDL_UnlockMutex(audio_mutex);
  if (!ok) return audio_error(L);
  lua_pushlstring(L, *buffer, bytes);
  SDL_free(*buffer); *buffer = NULL;
  return 1;
}

static int f_sound_get_metadata(lua_State *L) {
  AudioSound *sound = guard_sound(L);
  if (!sound) return audio_error(L);
  SDL_PropertiesID props = MIX_GetAudioProperties(sound->audio);
  if (!props) return audio_error(L);
  static const char *const names[] = { "title", "artist", "album", "copyright", "track", "total_tracks", "year" };
  static const char *const keys[] = { MIX_PROP_METADATA_TITLE_STRING, MIX_PROP_METADATA_ARTIST_STRING,
    MIX_PROP_METADATA_ALBUM_STRING, MIX_PROP_METADATA_COPYRIGHT_STRING, MIX_PROP_METADATA_TRACK_NUMBER,
    MIX_PROP_METADATA_TOTAL_TRACKS_NUMBER, MIX_PROP_METADATA_YEAR_NUMBER };
  lua_newtable(L);
  for (int i = 0; i < 7; i++) {
    if (!SDL_HasProperty(props, keys[i])) continue;
    if (i < 4) lua_pushstring(L, SDL_GetStringProperty(props, keys[i], ""));
    else lua_pushinteger(L, (lua_Integer) SDL_GetNumberProperty(props, keys[i], 0));
    lua_setfield(L, -2, names[i]);
  }
  return 1;
}

static AudioMixer *check_owner(lua_State *L, AudioGroup **group) {
  AudioGroup **ud = luaL_testudata(L, 1, API_TYPE_AUDIO_GROUP);
  *group = ud ? *ud : NULL;
  if (ud) return *ud ? (*ud)->mixer : NULL;
  return *(AudioMixer **) luaL_checkudata(L, 1, API_TYPE_AUDIO_MIXER);
}

static int f_mixer_group(lua_State *L) {
  AudioMixer **owner = luaL_checkudata(L, 1, API_TYPE_AUDIO_MIXER);
  size_t length;
  luaL_checktype(L, 2, LUA_TSTRING);
  lua_tolstring(L, 2, &length);
  luaL_argcheck(L, length > 0, 2, "group name cannot be empty");
  lua_getuservalue(L, 1);
  lua_getfield(L, -1, "groups");
  lua_pushvalue(L, 2); lua_rawget(L, -2);
  if (!mixer_open(*owner)) return audio_error(L);
  if (!lua_isnil(L, -1)) return 1;
  lua_pop(L, 1);
  AudioGroup **ud = new_object(L, sizeof(*ud), API_TYPE_AUDIO_GROUP);
  SDL_LockMutex(audio_mutex);
  AudioMixer *mixer = *owner;
  if (!mixer_open(mixer)) { SDL_UnlockMutex(audio_mutex); return audio_error(L); }
  AudioGroup *group = SDL_calloc(1, sizeof(*group));
  if (!group) { SDL_UnlockMutex(audio_mutex); return audio_error(L); }
  group->mixer = mixer; mixer->refs++;
  group->gain = 1;
  group->next = mixer->groups; mixer->groups = group;
  *ud = group;
  SDL_UnlockMutex(audio_mutex);
  lua_pushvalue(L, 2); lua_pushvalue(L, -2); lua_rawset(L, -4);
  return 1;
}

static int f_group_gc(lua_State *L) {
  AudioGroup **ud = luaL_checkudata(L, 1, API_TYPE_AUDIO_GROUP);
  SDL_LockMutex(audio_mutex);
  if (*ud) mixer_unref((*ud)->mixer);
  *ud = NULL;
  SDL_UnlockMutex(audio_mutex);
  return 0;
}

static bool time_frames(double seconds, int frequency, Sint64 *frames) {
  double count = floor(seconds * frequency);
  if (!isfinite(count) || count >= 9223372036854775808.0)
    return SDL_SetError("audio time exceeds the sample-frame range");
  *frames = (Sint64) count;
  return true;
}

static bool sync_pause(AudioVoice *voice) {
  return voice_paused(voice) ? MIX_PauseTrack(voice->track) : MIX_ResumeTrack(voice->track);
}

static bool sync_gain(AudioVoice *voice) {
  double gain = (double) voice->gain * (voice->group ? voice->group->gain : 1);
  return (gain <= FLT_MAX || SDL_SetError("combined group/voice gain exceeds float range"))
    && MIX_SetTrackGain(voice->track, (float) gain);
}

static bool sync_pan(AudioVoice *voice) {
  MIX_StereoGains gains = { 1 - SDL_max(voice->pan, 0), 1 + SDL_min(voice->pan, 0) };
  return MIX_SetTrackStereo(voice->track, voice->panning ? &gains : NULL);
}

static int f_play(lua_State *L) {
  int kind = (int) lua_tointeger(L, lua_upvalueindex(1));
  lua_settop(L, 3);
  AudioGroup *group;
  AudioMixer *mixer = check_owner(L, &group);
  AudioSound **sample = kind == 0 ? luaL_checkudata(L, 2, API_TYPE_AUDIO_SOUND) : NULL;
  const char *path = kind == 1 ? check_path(L, 2) : NULL;
  SDL_AudioSpec spec = {0};
  if (kind == 2) spec = check_spec(L, 2);
  bool paused = false, panning = false;
  float gain = 1, rate = 1, pan = 0;
  double start = 0, loop_start = 0, end = -1, fade = 0;
  int loops = 0;
  if (!lua_isnil(L, 3)) {
    luaL_checktype(L, 3, LUA_TTABLE);
    paused = option_bool(L, 3, "paused", false);
    gain = (float) option_number(L, 3, "gain", 1, 0, FLT_MAX);
    rate = (float) option_number(L, 3, "rate", 1, 0.01, 100);
    fade = option_number(L, 3, "fade_in", 0, 0, DBL_MAX);
    lua_getfield(L, 3, "pan");
    if (!lua_isnil(L, -1)) { pan = (float) check_number(L, -1, -1, 1); panning = true; }
    lua_pop(L, 1);
    const char *seek_options[] = { "loops", "start", "loop_start", "loop_end" };
    if (kind == 2) for (int i = 0; i < 4; i++) {
      lua_getfield(L, 3, seek_options[i]);
      luaL_argcheck(L, lua_isnil(L, -1), 3, "writable PCM cannot loop or seek"); lua_pop(L, 1);
    }
    lua_getfield(L, 3, "loop");
    luaL_argcheck(L, lua_isnil(L, -1), 3, "use numeric loops, not loop"); lua_pop(L, 1);
    lua_getfield(L, 3, "loops");
    if (!lua_isnil(L, -1)) loops = check_integer(L, -1, -1, INT_MAX);
    lua_pop(L, 1);
    start = option_number(L, 3, "start", 0, 0, DBL_MAX);
    loop_start = option_number(L, 3, "loop_start", 0, 0, DBL_MAX);
    end = option_number(L, 3, "loop_end", -1, 0, DBL_MAX);
    lua_getfield(L, 3, "on_complete");
    if (!lua_isnil(L, -1)) luaL_checktype(L, -1, LUA_TFUNCTION);
  } else lua_pushnil(L);
  int callback = lua_gettop(L);
  /* Retrieve the weak owner before allocating the voice: children must not keep
   * the mixer open, but it must remain reachable during this operation. */
  mixer = check_owner(L, &group);
  lua_getfield(L, LUA_REGISTRYINDEX, AUDIO_MIXERS);
  lua_pushlightuserdata(L, mixer); lua_rawget(L, -2);
  int owner_index = lua_gettop(L);
  if (lua_isnil(L, owner_index)) { SDL_SetError("audio mixer is closed"); return audio_error(L); }
  lua_getuservalue(L, owner_index); lua_getfield(L, -1, "callbacks");
  int callbacks = lua_gettop(L);
  bool notify = !lua_isnil(L, callback);
  AudioVoice **ud = new_object(L, sizeof(*ud), API_TYPE_AUDIO_VOICE);
  int object = lua_gettop(L);
  SDL_LockMutex(audio_mutex);
  if (!mixer_open(mixer)) { SDL_UnlockMutex(audio_mutex); return audio_error(L); }
  collect_voices(mixer);
  if (mixer->voice_count >= mixer->max_voices) {
    SDL_SetError("audio voice limit reached"); SDL_UnlockMutex(audio_mutex); return audio_error(L);
  }
  AudioSound *sound = sample ? *sample : NULL;
  if (sample && !sound) { SDL_SetError("audio sound is closed"); SDL_UnlockMutex(audio_mutex); return audio_error(L); }
  AudioVoice *voice = SDL_calloc(1, sizeof(*voice));
  if (!voice) { SDL_UnlockMutex(audio_mutex); return audio_error(L); }
  *ud = voice;
  voice->refs = 1; voice->mixer = mixer; mixer->refs++;
  voice->group = group; voice->gain = gain; voice->rate = rate;
  voice->paused = paused; voice->panning = panning; voice->pan = pan;
  voice->state = VOICE_STOPPED; voice->writable = kind == 2;
  voice->notify = notify;
  voice->duration = -1; voice->end = -1;
  voice->track = MIX_CreateTrack(mixer->mixer);
  bool ok = voice->track != NULL;
  if (ok && sound) {
    voice->spec = sound->spec;
    voice->duration = MIX_GetAudioDuration(sound->audio);
    ok = MIX_SetTrackAudio(voice->track, sound->audio);
  } else if (ok && path) {
    SDL_IOStream *io = SDL_IOFromFile(path, "rb");
    MIX_AudioDecoder *probe = io ? MIX_CreateAudioDecoder_IO(io, false, 0) : NULL;
    ok = probe && MIX_GetAudioDecoderFormat(probe, &voice->spec);
    if (ok) {
      SDL_PropertiesID props = MIX_GetAudioDecoderProperties(probe);
      voice->duration = SDL_GetBooleanProperty(props, MIX_PROP_METADATA_DURATION_INFINITE_BOOLEAN, false)
        ? MIX_DURATION_INFINITE : SDL_GetNumberProperty(props, MIX_PROP_METADATA_DURATION_FRAMES_NUMBER, MIX_DURATION_UNKNOWN);
    }
    MIX_DestroyAudioDecoder(probe);
    if (ok) ok = SDL_SeekIO(io, 0, SDL_IO_SEEK_SET) >= 0;
    if (ok) ok = MIX_SetTrackIOStream(voice->track, io, true);
    else if (io) SDL_CloseIO(io);
  } else if (ok) {
    voice->spec = spec;
    voice->stream = SDL_CreateAudioStream(&spec, &spec);
    ok = voice->stream && MIX_SetTrackAudioStream(voice->track, voice->stream);
  }
  Sint64 start_frame = 0, loop_frame = 0;
  if (ok) ok = valid_frequency(&voice->spec, rate)
    && time_frames(start, voice->spec.freq, &start_frame)
    && time_frames(loop_start, voice->spec.freq, &loop_frame)
    && time_frames(fade, voice->spec.freq, &voice->fade_in)
    && (end < 0 || time_frames(end, voice->spec.freq, &voice->end));
  if (ok && (loop_frame > INT_MAX || voice->fade_in > INT_MAX))
    ok = SDL_SetError("loop start or fade exceeds SDL_mixer's frame range");
  Sint64 last = voice->end >= 0 ? voice->end : voice->duration;
  if (ok && ((last >= 0 && (start_frame >= last || (loops && loop_frame >= last)))
      || (voice->duration >= 0 && voice->end > voice->duration)))
    ok = SDL_SetError("start/loop boundaries must form nonempty ranges within the source");
  if (ok && loops) ok = MIX_SetTrackPlaybackPosition(voice->track, loop_frame);
  SDL_PropertiesID options = ok ? SDL_CreateProperties() : 0;
  if (ok) ok = options && SDL_SetNumberProperty(options, MIX_PROP_PLAY_LOOPS_NUMBER, loops)
    && SDL_SetNumberProperty(options, MIX_PROP_PLAY_START_FRAME_NUMBER, start_frame)
    && SDL_SetNumberProperty(options, MIX_PROP_PLAY_LOOP_START_FRAME_NUMBER, loop_frame)
    && SDL_SetNumberProperty(options, MIX_PROP_PLAY_MAX_FRAME_NUMBER, voice->end)
    && SDL_SetNumberProperty(options, MIX_PROP_PLAY_FADE_IN_FRAMES_NUMBER, voice->fade_in)
    && SDL_SetBooleanProperty(options, MIX_PROP_PLAY_HALT_WHEN_EXHAUSTED_BOOLEAN, kind != 2);
  if (ok) {
    MIX_LockMixer(mixer->mixer);
    ok = sync_gain(voice) && sync_pan(voice) && MIX_SetTrackFrequencyRatio(voice->track, rate)
      && MIX_SetTrackStoppedCallback(voice->track, voice_stopped, voice)
      && MIX_PlayTrack(voice->track, options) && sync_pause(voice);
    if (ok) {
      voice->state = VOICE_ACTIVE; voice->refs++;
      voice->next = mixer->voices; mixer->voices = voice; mixer->voice_count++;
    } else MIX_SetTrackStoppedCallback(voice->track, NULL, NULL);
    MIX_UnlockMixer(mixer->mixer);
  }
  SDL_DestroyProperties(options);
  if (!ok) {
    MIX_DestroyTrack(voice->track); voice->track = NULL;
    SDL_DestroyAudioStream(voice->stream); voice->stream = NULL;
  }
  SDL_UnlockMutex(audio_mutex);
  if (!ok) return audio_error(L);
  if (voice->notify) {
    lua_pushlightuserdata(L, voice);
    lua_createtable(L, 2, 0);
    lua_pushvalue(L, object); lua_rawseti(L, -2, 1);
    lua_pushvalue(L, callback); lua_rawseti(L, -2, 2);
    lua_rawset(L, callbacks);
  }
  lua_settop(L, object);
  return 1;
}

typedef enum {
  PAUSE, RESUME, IS_PAUSED, GET_GAIN, SET_GAIN, GET_RATE, SET_RATE,
  QUEUED, AVAILABLE, CLEAR, FLUSH
} Control;

static int push_control(lua_State *L, Control control, bool ok, double value) {
  SDL_UnlockMutex(audio_mutex);
  if (!ok) return audio_error(L);
  if (control == GET_GAIN || control == GET_RATE) lua_pushnumber(L, value);
  else if (control == QUEUED || control == AVAILABLE) lua_pushinteger(L, (lua_Integer) value);
  else lua_pushboolean(L, control == IS_PAUSED ? value != 0 : true);
  return 1;
}

static int owner_control(lua_State *L) {
  Control control = (Control) lua_tointeger(L, lua_upvalueindex(1));
  double value = control == SET_GAIN || control == SET_RATE ? check_multiplier(L, 2, control == SET_RATE) : 0;
  AudioGroup *group;
  AudioMixer *mixer = check_owner(L, &group);
  SDL_LockMutex(audio_mutex);
  if (!mixer_open(mixer)) return push_control(L, control, false, 0);
  collect_voices(mixer);
  bool ok = true;
  MIX_LockMixer(mixer->mixer);
  switch (control) {
    case GET_GAIN: value = group ? group->gain : mixer->gain; break;
    case GET_RATE: value = mixer->rate; break;
    case IS_PAUSED: value = group ? group->paused : mixer->paused; break;
    case SET_RATE:
      ok = valid_frequency(&mixer->spec, (float) value) && MIX_SetMixerFrequencyRatio(mixer->mixer, (float) value);
      if (ok) mixer->rate = (float) value;
      break;
    case SET_GAIN:
      if (group) {
        for (AudioVoice *v = mixer->voices; v; v = v->next)
          if (v->group == group && (double) v->gain * value > FLT_MAX) ok = false;
        if (!ok) SDL_SetError("combined group/voice gain exceeds float range");
        else {
          group->gain = (float) value;
          for (AudioVoice *v = mixer->voices; v; v = v->next)
            if (v->group == group && !SDL_GetAtomicInt(&v->done)) ok = sync_gain(v) && ok;
        }
      } else {
        ok = MIX_SetMixerGain(mixer->mixer, (float) value);
        if (ok) mixer->gain = (float) value;
      }
      break;
    case PAUSE: case RESUME:
      if (group) group->paused = control == PAUSE; else mixer->paused = control == PAUSE;
      for (AudioVoice *v = mixer->voices; v; v = v->next)
        if ((!group || v->group == group) && !SDL_GetAtomicInt(&v->done)) ok = sync_pause(v) && ok;
      break;
    default: break;
  }
  MIX_UnlockMixer(mixer->mixer);
  return push_control(L, control, ok, value);
}

static double check_fade_out(lua_State *L) {
  if (lua_isnoneornil(L, 2)) return 0;
  luaL_checktype(L, 2, LUA_TTABLE);
  return option_number(L, 2, "fade_out", 0, 0, DBL_MAX);
}

static bool stop_voice(AudioVoice *voice, double fade) {
  if (voice->state != VOICE_ACTIVE || SDL_GetAtomicInt(&voice->done)) return true;
  Sint64 frames;
  if (!time_frames(fade, voice->spec.freq, &frames)) return false;
  if (frames > INT_MAX) return SDL_SetError("fade exceeds SDL_mixer's frame range");
  if (voice_paused(voice)) frames = 0;
  if (voice->stopping && frames) return true;
  voice->stopping = true;
  MIX_SetTrackLoops(voice->track, 0);
  return MIX_StopTrack(voice->track, frames);
}

static int f_owner_stop(lua_State *L) {
  double fade = check_fade_out(L);
  AudioGroup *group;
  AudioMixer *mixer = check_owner(L, &group);
  SDL_LockMutex(audio_mutex);
  if (!mixer_open(mixer)) return audio_result(L, false);
  bool ok = true;
  MIX_LockMixer(mixer->mixer);
  for (AudioVoice *v = mixer->voices; v; v = v->next)
    if (!group || v->group == group) ok = stop_voice(v, fade) && ok;
  MIX_UnlockMixer(mixer->mixer);
  collect_voices(mixer);
  return audio_result(L, ok);
}

static int f_mixer_close(lua_State *L) {
  AudioMixer **ud = luaL_checkudata(L, 1, API_TYPE_AUDIO_MIXER);
  SDL_LockMutex(audio_mutex); mixer_close(*ud); SDL_UnlockMutex(audio_mutex);
  lua_getuservalue(L, 1);
  if (lua_istable(L, -1)) { lua_newtable(L); lua_setfield(L, -2, "callbacks"); }
  return 0;
}

static int f_mixer_gc(lua_State *L) {
  AudioMixer **ud = luaL_checkudata(L, 1, API_TYPE_AUDIO_MIXER);
  SDL_LockMutex(audio_mutex);
  mixer_close(*ud); mixer_unref(*ud); *ud = NULL;
  SDL_UnlockMutex(audio_mutex);
  return 0;
}

static int f_mixer_resume_together(lua_State *L) {
  AudioMixer **owner = luaL_checkudata(L, 1, API_TYPE_AUDIO_MIXER);
  luaL_checktype(L, 2, LUA_TTABLE);
  size_t count = lua_rawlen(L, 2);
  luaL_argcheck(L, count > 0 && count <= INT_MAX / sizeof(AudioVoice *), 2, "expected a nonempty voice array");
  AudioVoice **voices = lua_newuserdata(L, count * sizeof(*voices));
  for (size_t i = 0; i < count; i++) {
    lua_rawgeti(L, 2, (lua_Integer) i + 1);
    voices[i] = *(AudioVoice **) luaL_checkudata(L, -1, API_TYPE_AUDIO_VOICE);
    lua_pop(L, 1);
    for (size_t j = 0; j < i; j++) luaL_argcheck(L, voices[i] != voices[j], 2, "duplicate voice");
  }
  AudioMixer *mixer = *owner;
  SDL_LockMutex(audio_mutex);
  if (!mixer_open(mixer)) return audio_result(L, false);
  MIX_LockMixer(mixer->mixer);
  bool ok = !mixer->paused;
  for (size_t i = 0; i < count; i++) {
    AudioVoice *v = voices[i];
    ok = ok && v && v->mixer == mixer && v->state == VOICE_ACTIVE && !SDL_GetAtomicInt(&v->done)
      && v->paused && (!v->group || !v->group->paused);
  }
  if (!ok) SDL_SetError("voices must be individually paused on this mixer with unpaused parents");
  else {
    for (size_t i = 0; i < count && ok; i++) ok = MIX_ResumeTrack(voices[i]->track);
    for (size_t i = 0; i < count; i++) {
      if (ok) voices[i]->paused = false;
      else MIX_PauseTrack(voices[i]->track);
    }
  }
  MIX_UnlockMixer(mixer->mixer);
  return audio_result(L, ok);
}

static int f_mixer_render(lua_State *L) {
  AudioMixer **owner = luaL_checkudata(L, 1, API_TYPE_AUDIO_MIXER);
  int frames = check_integer(L, 2, 1, INT_MAX);
  AudioMixer *mixer = *owner;
  if (!mixer_open(mixer) || (!mixer->offline && !SDL_SetError("render requires an offline mixer"))) {
    lua_pushnil(L); audio_error(L); return 3;
  }
  int frame = SDL_AUDIO_FRAMESIZE(mixer->spec);
  luaL_argcheck(L, frames <= INT_MAX / frame, 2, "render size exceeds INT_MAX bytes");
  if ((double) frames * mixer->spec.channels * sizeof(float) * SDL_max(mixer->rate, 1) > INT_MAX / 3 - 512) {
    SDL_SetError("render request exceeds the mixer working-buffer limit");
    lua_pushnil(L); audio_error(L); return 3;
  }
  int size = frames * frame;
  void *buffer = lua_newuserdata(L, (size_t) size);
  // Upstream MIX_Generate can leave a resampled short read partially unwritten.
  SDL_memset(buffer, SDL_GetSilenceValueForFormat(mixer->spec.format), size);
  SDL_LockMutex(audio_mutex);
  int bytes = -1;
  if (mixer_open(mixer)) {
    if (mixer->paused) bytes = 0;
    else bytes = MIX_Generate(mixer->mixer, buffer, size);
    collect_voices(mixer);
  }
  SDL_UnlockMutex(audio_mutex);
  if (bytes < 0) { lua_pushnil(L); audio_error(L); return 3; }
  lua_pushlstring(L, buffer, size); lua_pushinteger(L, bytes / frame);
  return 2;
}

static int f_mixer_set_sample_buffer(lua_State *L) {
  AudioMixer **owner = luaL_checkudata(L, 1, API_TYPE_AUDIO_MIXER);
  int frames = check_integer(L, 2, 0, AUDIO_SAMPLE_FRAMES);
  float *buffer = frames ? SDL_malloc((size_t) frames * 8 * sizeof(float)) : NULL;
  if (frames && !buffer) return audio_error(L);
  AudioMixer *mixer = *owner;
  SDL_LockMutex(audio_mutex);
  bool ok = mixer_open(mixer);
  if (ok) {
    MIX_LockMixer(mixer->mixer);
    ok = MIX_SetPostMixCallback(mixer->mixer, frames ? mixer_samples : NULL, mixer);
    if (ok) {
      SDL_free(mixer->samples);
      mixer->samples = buffer;
      buffer = NULL;
      mixer->sample_capacity = frames;
      mixer->sample_count = mixer->sample_write = 0;
      mixer->sample_spec = mixer->spec;
      mixer->sample_spec.format = SDL_AUDIO_F32;
    }
    MIX_UnlockMixer(mixer->mixer);
  }
  SDL_free(buffer);
  return audio_result(L, ok);
}

static int f_mixer_get_samples(lua_State *L) {
  AudioMixer **owner = luaL_checkudata(L, 1, API_TYPE_AUDIO_MIXER);
  int frames = lua_isnoneornil(L, 2) ? 1024 : check_integer(L, 2, 1, AUDIO_SAMPLE_FRAMES);
  float *buffer = lua_newuserdata(L, (size_t) frames * 8 * sizeof(float));
  AudioMixer *mixer = *owner;
  SDL_AudioSpec spec = {0};
  SDL_LockMutex(audio_mutex);
  bool ok = mixer_open(mixer);
  if (ok && !mixer->samples) ok = SDL_SetError("sample buffer is disabled");
  if (ok) {
    MIX_LockMixer(mixer->mixer);
    spec = mixer->sample_spec;
    frames = SDL_min(frames, mixer->sample_count);
    int start = (mixer->sample_write - frames + mixer->sample_capacity) % mixer->sample_capacity;
    int first = SDL_min(frames, mixer->sample_capacity - start);
    SDL_memcpy(buffer, mixer->samples + start * spec.channels, first * spec.channels * sizeof(float));
    SDL_memcpy(buffer + first * spec.channels, mixer->samples, (frames - first) * spec.channels * sizeof(float));
    MIX_UnlockMixer(mixer->mixer);
  }
  SDL_UnlockMutex(audio_mutex);
  if (!ok) { lua_pushnil(L); audio_error(L); return 3; }
  lua_createtable(L, frames * spec.channels, 0);
  for (int i = 0; i < frames * spec.channels; i++) {
    lua_pushnumber(L, buffer[i]); lua_rawseti(L, -2, i + 1);
  }
  push_spec(L, &spec);
  return 2;
}

static int f_voice_gc(lua_State *L) {
  AudioVoice **ud = luaL_checkudata(L, 1, API_TYPE_AUDIO_VOICE);
  SDL_LockMutex(audio_mutex); voice_unref(*ud); *ud = NULL; SDL_UnlockMutex(audio_mutex);
  return 0;
}

static int f_voice_get_state(lua_State *L) {
  AudioVoice *voice = *(AudioVoice **) luaL_checkudata(L, 1, API_TYPE_AUDIO_VOICE);
  const char *state = "stopped";
  char error[256] = "";
  SDL_LockMutex(audio_mutex);
  if (voice) {
    collect_voices(voice->mixer);
    state = voice->state == VOICE_FINISHED ? "finished" : voice->state == VOICE_STOPPED ? "stopped"
      : voice_paused(voice) ? "paused" : "playing";
    SDL_strlcpy(error, voice->error, sizeof(error));
  }
  SDL_UnlockMutex(audio_mutex);
  lua_pushstring(L, state);
  if (*error) { lua_pushstring(L, error); return 2; }
  return 1;
}

static int voice_control(lua_State *L) {
  Control control = (Control) lua_tointeger(L, lua_upvalueindex(1));
  double value = control == SET_GAIN || control == SET_RATE ? check_multiplier(L, 2, control == SET_RATE) : 0;
  AudioVoice *voice = *(AudioVoice **) luaL_checkudata(L, 1, API_TYPE_AUDIO_VOICE);
  SDL_LockMutex(audio_mutex);
  if (!voice) { SDL_SetError("voice is closed"); return push_control(L, control, false, 0); }
  collect_voices(voice->mixer);
  if (control == GET_GAIN || control == GET_RATE)
    return push_control(L, control, true, control == GET_GAIN ? voice->gain : voice->rate);
  if (voice->state != VOICE_ACTIVE) {
    SDL_SetError("voice has finished or stopped"); return push_control(L, control, false, 0);
  }
  MIX_LockMixer(voice->mixer->mixer);
  bool ok = true;
  switch (control) {
    case PAUSE: case RESUME:
      voice->paused = control == PAUSE;
      ok = sync_pause(voice);
      break;
    case SET_GAIN: {
      float old = voice->gain;
      voice->gain = (float) value;
      ok = sync_gain(voice);
      if (!ok) voice->gain = old;
      break;
    }
    case SET_RATE:
      ok = valid_frequency(&voice->spec, (float) value) && MIX_SetTrackFrequencyRatio(voice->track, (float) value);
      if (ok) voice->rate = (float) value;
      break;
    default: break;
  }
  MIX_UnlockMixer(voice->mixer->mixer);
  return push_control(L, control, ok, value);
}

static int f_voice_stop(lua_State *L) {
  double fade = check_fade_out(L);
  AudioVoice *voice = *(AudioVoice **) luaL_checkudata(L, 1, API_TYPE_AUDIO_VOICE);
  SDL_LockMutex(audio_mutex);
  bool ok = true;
  if (voice && voice->mixer->mixer) {
    MIX_LockMixer(voice->mixer->mixer);
    ok = stop_voice(voice, fade);
    MIX_UnlockMixer(voice->mixer->mixer);
    collect_voices(voice->mixer);
  }
  return audio_result(L, ok);
}

static int f_voice_get_pan(lua_State *L) {
  AudioVoice *voice = *(AudioVoice **) luaL_checkudata(L, 1, API_TYPE_AUDIO_VOICE);
  if (voice && voice->panning) lua_pushnumber(L, voice->pan); else lua_pushnil(L);
  return 1;
}

static int f_voice_set_pan(lua_State *L) {
  bool panning = !lua_isnoneornil(L, 2);
  float pan = panning ? (float) check_number(L, 2, -1, 1) : 0;
  AudioVoice *voice = *(AudioVoice **) luaL_checkudata(L, 1, API_TYPE_AUDIO_VOICE);
  SDL_LockMutex(audio_mutex);
  if (voice) collect_voices(voice->mixer);
  if (!voice || voice->state != VOICE_ACTIVE) {
    SDL_SetError("voice has finished or stopped"); return audio_result(L, false);
  }
  MIX_LockMixer(voice->mixer->mixer);
  bool old_panning = voice->panning;
  float old_pan = voice->pan;
  voice->panning = panning; voice->pan = pan;
  bool ok = sync_pan(voice);
  if (!ok) { voice->panning = old_panning; voice->pan = old_pan; }
  MIX_UnlockMixer(voice->mixer->mixer);
  return audio_result(L, ok);
}

static int f_voice_get_position(lua_State *L) {
  AudioVoice *voice = *(AudioVoice **) luaL_checkudata(L, 1, API_TYPE_AUDIO_VOICE);
  SDL_LockMutex(audio_mutex);
  if (!voice || voice->writable) {
    SDL_SetError("source position is unavailable for this voice"); SDL_UnlockMutex(audio_mutex); return audio_error(L);
  }
  collect_voices(voice->mixer);
  Sint64 position = voice->track ? MIX_GetTrackPlaybackPosition(voice->track) : voice->position;
  double seconds = (double) position / voice->spec.freq;
  SDL_UnlockMutex(audio_mutex);
  if (position < 0) return audio_error(L);
  lua_pushnumber(L, seconds);
  return 1;
}

static int f_voice_seek(lua_State *L) {
  double seconds = check_number(L, 2, 0, DBL_MAX);
  AudioVoice *voice = *(AudioVoice **) luaL_checkudata(L, 1, API_TYPE_AUDIO_VOICE);
  SDL_LockMutex(audio_mutex);
  if (voice) collect_voices(voice->mixer);
  if (!voice || voice->writable || voice->state != VOICE_ACTIVE) {
    SDL_SetError("cannot seek this voice"); return audio_result(L, false);
  }
  Sint64 frames;
  bool ok = time_frames(seconds, voice->spec.freq, &frames);
  if (ok && ((voice->end >= 0 && frames >= voice->end) || (voice->duration >= 0 && frames >= voice->duration)))
    ok = SDL_SetError("seek position is outside the source range");
  if (ok) ok = MIX_SetTrackPlaybackPosition(voice->track, frames);
  return audio_result(L, ok);
}

static int f_voice_get_duration(lua_State *L) {
  AudioVoice *voice = *(AudioVoice **) luaL_checkudata(L, 1, API_TYPE_AUDIO_VOICE);
  if (!voice) { SDL_SetError("audio voice is closed"); return audio_error(L); }
  if (voice->duration == MIX_DURATION_UNKNOWN) lua_pushnil(L);
  else lua_pushnumber(L, voice->duration == MIX_DURATION_INFINITE ? HUGE_VAL
    : (double) voice->duration / voice->spec.freq);
  return 1;
}

static bool writable_voice(AudioVoice *voice, bool active) {
  if (!voice || !voice->writable) return SDL_SetError("operation requires a writable PCM voice");
  collect_voices(voice->mixer);
  if (active && (voice->state != VOICE_ACTIVE || voice->sealed))
    return SDL_SetError("PCM voice is finished, stopped, or sealed");
  return true;
}

static int f_voice_write(lua_State *L) {
  AudioVoice *voice = *(AudioVoice **) luaL_checkudata(L, 1, API_TYPE_AUDIO_VOICE);
  SDL_LockMutex(audio_mutex);
  bool ok = writable_voice(voice, true);
  SDL_UnlockMutex(audio_mutex);
  if (!ok) return audio_error(L);
  int size;
  const char *data = check_pcm(L, 2, &voice->spec, &size, true);
  SDL_LockMutex(audio_mutex);
  ok = writable_voice(voice, true) && (!size || SDL_PutAudioStreamData(voice->stream, data, size));
  SDL_UnlockMutex(audio_mutex);
  if (!ok) return audio_error(L);
  lua_pushinteger(L, size);
  return 1;
}

static int f_voice_queued(lua_State *L) {
  AudioVoice *voice = *(AudioVoice **) luaL_checkudata(L, 1, API_TYPE_AUDIO_VOICE);
  SDL_LockMutex(audio_mutex);
  int bytes = !writable_voice(voice, false) ? -1
    : voice->stream ? SDL_GetAudioStreamQueued(voice->stream) : 0;
  return push_control(L, QUEUED, bytes >= 0, bytes);
}

static int f_voice_clear(lua_State *L) {
  AudioVoice *voice = *(AudioVoice **) luaL_checkudata(L, 1, API_TYPE_AUDIO_VOICE);
  SDL_LockMutex(audio_mutex);
  return audio_result(L, writable_voice(voice, true) && SDL_ClearAudioStream(voice->stream));
}

static int f_voice_finish(lua_State *L) {
  AudioVoice *voice = *(AudioVoice **) luaL_checkudata(L, 1, API_TYPE_AUDIO_VOICE);
  SDL_LockMutex(audio_mutex);
  if (!writable_voice(voice, false)) return audio_result(L, false);
  if (voice->sealed || voice->state != VOICE_ACTIVE) return audio_result(L, true);
  MIX_LockMixer(voice->mixer->mixer);
  bool ok = SDL_FlushAudioStream(voice->stream);
  /* Replaying an external PCM stream preserves its queue and resampler. Only
   * change its exhaustion policy; preserve any fade-in and independent pauses.
   * A pending stop already guarantees termination and keeps its fade intact. */
  if (ok && !voice->stopping) {
    Sint64 fade = MIX_GetTrackFadeFrames(voice->track);
    SDL_PropertiesID options = SDL_CreateProperties();
    ok = options && SDL_SetBooleanProperty(options, MIX_PROP_PLAY_HALT_WHEN_EXHAUSTED_BOOLEAN, true);
    if (ok && fade > 0) {
      float gain = 1 - (float) fade / (float) voice->fade_in;
      ok = SDL_SetNumberProperty(options, MIX_PROP_PLAY_FADE_IN_FRAMES_NUMBER, fade)
        && SDL_SetFloatProperty(options, MIX_PROP_PLAY_FADE_IN_START_GAIN_FLOAT, gain);
    }
    if (ok) ok = MIX_PlayTrack(voice->track, options) && sync_pause(voice);
    SDL_DestroyProperties(options);
  }
  if (ok) voice->sealed = true;
  MIX_UnlockMixer(voice->mixer->mixer);
  return audio_result(L, ok);
}

static int f_create_stream(lua_State *L) {
  SDL_AudioSpec input = check_spec(L, 1), output = check_spec(L, 2);
  AudioStream *stream = new_object(L, sizeof(*stream), API_TYPE_AUDIO_STREAM);
  if (!valid_frequency(&input, 1)) return audio_error(L);
  stream->stream = SDL_CreateAudioStream(&input, &output);
  if (!stream->stream) return audio_error(L);
  return 1;
}

static int f_open_recording(lua_State *L) {
  SDL_AudioSpec output = check_spec(L, 1), input;
  bool follows_default, paused = true;
  if (!lua_isnoneornil(L, 2)) {
    luaL_checktype(L, 2, LUA_TTABLE);
    paused = option_bool(L, 2, "paused", true);
  }
  SDL_AudioDeviceID id = check_device(L, 2, true, &follows_default);
  AudioStream *stream = new_object(L, sizeof(*stream), API_TYPE_AUDIO_STREAM);
  SDL_LockMutex(audio_mutex);
  bool ok = init_locked(true) && validate_device(id, follows_default, true);
  if (ok) {
    stream->device = SDL_OpenAudioDevice(id, NULL);
    ok = stream->device && SDL_PauseAudioDevice(stream->device)
      && SDL_GetAudioDeviceFormat(stream->device, &input, NULL);
  }
  if (ok) {
    stream->stream = SDL_CreateAudioStream(&input, &output);
    ok = stream->stream && SDL_BindAudioStream(stream->device, stream->stream)
      && (paused || SDL_ResumeAudioDevice(stream->device));
  }
  if (ok) {
    stream->recording = true; stream->follows_default = follows_default;
    stream->next = recordings; recordings = stream;
  } else {
    SDL_DestroyAudioStream(stream->stream); stream->stream = NULL;
    if (stream->device) SDL_CloseAudioDevice(stream->device);
    stream->device = 0;
  }
  SDL_UnlockMutex(audio_mutex);
  if (!ok) return audio_error(L);
  return 1;
}

static int f_convert(lua_State *L) {
  SDL_AudioSpec input = check_spec(L, 2), output = check_spec(L, 3);
  int size, converted_size;
  const char *data = check_pcm(L, 1, &input, &size, true);
  if (!size) { lua_pushliteral(L, ""); return 1; }
  if (!valid_frequency(&input, 1)) return audio_error(L);
  Uint8 **converted = new_object(L, sizeof(*converted), AUDIO_ALLOCATION);
  if (!SDL_ConvertAudioSamples(&input, (const Uint8 *) data, size, &output, converted, &converted_size))
    return audio_error(L);
  lua_pushlstring(L, (const char *) *converted, (size_t) converted_size);
  SDL_free(*converted); *converted = NULL;
  return 1;
}

static int f_stream_write(lua_State *L) {
  AudioStream *stream = luaL_checkudata(L, 1, API_TYPE_AUDIO_STREAM);
  SDL_AudioSpec input;
  SDL_LockMutex(audio_mutex);
  bool ok = stream_open(stream);
  if (ok && stream->recording) ok = SDL_SetError("cannot write to a recording stream");
  if (ok) ok = SDL_GetAudioStreamFormat(stream->stream, &input, NULL);
  SDL_UnlockMutex(audio_mutex);
  if (!ok) return audio_error(L);
  int size;
  const char *data = check_pcm(L, 2, &input, &size, true);
  SDL_LockMutex(audio_mutex);
  ok = stream_open(stream) && (!size || SDL_PutAudioStreamData(stream->stream, data, size));
  SDL_UnlockMutex(audio_mutex);
  if (!ok) return audio_error(L);
  lua_pushinteger(L, size);
  return 1;
}

static int f_stream_read(lua_State *L) {
  AudioStream *stream = luaL_checkudata(L, 1, API_TYPE_AUDIO_STREAM);
  int requested = lua_isnoneornil(L, 2) ? 4096 : check_integer(L, 2, 1, INT_MAX);
  SDL_AudioSpec output;
  SDL_LockMutex(audio_mutex);
  bool ok = stream_open(stream) && SDL_GetAudioStreamFormat(stream->stream, NULL, &output);
  int available = ok ? SDL_GetAudioStreamAvailable(stream->stream) : -1;
  SDL_UnlockMutex(audio_mutex);
  if (available < 0) return audio_error(L);
  int frame = SDL_AUDIO_FRAMESIZE(output);
  luaL_argcheck(L, requested >= frame, 2, "read size is smaller than one PCM frame");
  int size = SDL_min(requested, available) / frame * frame;
  if (!size) { lua_pushliteral(L, ""); return 1; }
  char *buffer = lua_newuserdata(L, (size_t) size);
  SDL_LockMutex(audio_mutex);
  int count = stream_open(stream) ? SDL_GetAudioStreamData(stream->stream, buffer, size) : -1;
  SDL_UnlockMutex(audio_mutex);
  if (count < 0) return audio_error(L);
  lua_pushlstring(L, buffer, (size_t) count);
  return 1;
}

static int f_stream_get_formats(lua_State *L) {
  AudioStream *stream = luaL_checkudata(L, 1, API_TYPE_AUDIO_STREAM);
  SDL_AudioSpec input, output;
  SDL_LockMutex(audio_mutex);
  bool ok = stream_open(stream) && SDL_GetAudioStreamFormat(stream->stream, &input, &output);
  SDL_UnlockMutex(audio_mutex);
  if (!ok) { lua_pushnil(L); audio_error(L); return 3; }
  push_spec(L, &input); push_spec(L, &output);
  return 2;
}

static int stream_control(lua_State *L) {
  Control control = (Control) lua_tointeger(L, lua_upvalueindex(1));
  AudioStream *stream = luaL_checkudata(L, 1, API_TYPE_AUDIO_STREAM);
  double value = control == SET_GAIN || control == SET_RATE ? check_multiplier(L, 2, control == SET_RATE) : 0;
  SDL_LockMutex(audio_mutex);
  if (!stream_open(stream)) return push_control(L, control, false, 0);
  if ((control == PAUSE || control == RESUME || control == IS_PAUSED) && !stream->device) {
    SDL_SetError("offline conversion streams cannot be paused"); return push_control(L, control, false, 0);
  }
  bool ok = true;
  switch (control) {
    case PAUSE: ok = SDL_PauseAudioDevice(stream->device); break;
    case RESUME: ok = SDL_ResumeAudioDevice(stream->device); break;
    case IS_PAUSED: value = SDL_AudioDevicePaused(stream->device); break;
    case GET_GAIN: value = SDL_GetAudioStreamGain(stream->stream); ok = value >= 0; break;
    case SET_GAIN: ok = SDL_SetAudioStreamGain(stream->stream, (float) value); break;
    case GET_RATE: value = SDL_GetAudioStreamFrequencyRatio(stream->stream); ok = value > 0; break;
    case SET_RATE: {
      SDL_AudioSpec input;
      ok = SDL_GetAudioStreamFormat(stream->stream, &input, NULL)
        && valid_frequency(&input, (float) value)
        && SDL_SetAudioStreamFrequencyRatio(stream->stream, (float) value);
      break;
    }
    case QUEUED: value = SDL_GetAudioStreamQueued(stream->stream); ok = value >= 0; break;
    case AVAILABLE: value = SDL_GetAudioStreamAvailable(stream->stream); ok = value >= 0; break;
    case CLEAR: ok = SDL_ClearAudioStream(stream->stream); break;
    case FLUSH: ok = SDL_FlushAudioStream(stream->stream); break;
  }
  return push_control(L, control, ok, value);
}

static int f_stream_close(lua_State *L) {
  AudioStream *stream = luaL_checkudata(L, 1, API_TYPE_AUDIO_STREAM);
  SDL_LockMutex(audio_mutex); stream_close(stream); SDL_UnlockMutex(audio_mutex);
  return 0;
}

typedef struct {
  SDL_AudioDeviceID id;
  SDL_AudioSpec spec;
  char name[1024];
  int frames;
  float gain;
  bool recording, follows_default, paused;
} DeviceInfo;

static bool device_info(DeviceInfo *info, SDL_AudioDeviceID id, bool recording, bool follows_default) {
  info->id = id; info->recording = recording; info->follows_default = follows_default;
  if (!SDL_GetAudioDeviceFormat(id, &info->spec, &info->frames)) return false;
  const char *name = SDL_GetAudioDeviceName(id);
  if (!name) return false;
  SDL_strlcpy(info->name, name, sizeof(info->name));
  info->paused = SDL_AudioDevicePaused(id);
  info->gain = SDL_GetAudioDeviceGain(id);
  return info->gain >= 0;
}

static void push_device_info(lua_State *L, const DeviceInfo *info) {
  lua_createtable(L, 0, 8);
  lua_pushnumber(L, info->id); lua_setfield(L, -2, "id");
  lua_pushstring(L, info->name); lua_setfield(L, -2, "name");
  lua_pushstring(L, info->recording ? "recording" : "playback"); lua_setfield(L, -2, "kind");
  push_spec(L, &info->spec); lua_setfield(L, -2, "spec");
  lua_pushinteger(L, info->frames); lua_setfield(L, -2, "buffer_frames");
  lua_pushboolean(L, info->paused); lua_setfield(L, -2, "paused");
  lua_pushnumber(L, info->gain); lua_setfield(L, -2, "gain");
  lua_pushboolean(L, info->follows_default); lua_setfield(L, -2, "follows_default");
}

static int f_stream_device_info(lua_State *L) {
  AudioStream *stream = luaL_checkudata(L, 1, API_TYPE_AUDIO_STREAM);
  DeviceInfo info;
  SDL_LockMutex(audio_mutex);
  bool ok = stream_open(stream);
  if (ok && !stream->recording) ok = SDL_SetError("converter has no audio device");
  if (ok) ok = device_info(&info, stream->device, true, stream->follows_default);
  SDL_UnlockMutex(audio_mutex);
  if (!ok) return audio_error(L);
  push_device_info(L, &info);
  return 1;
}

static int f_mixer_get_info(lua_State *L) {
  AudioMixer *mixer = *(AudioMixer **) luaL_checkudata(L, 1, API_TYPE_AUDIO_MIXER);
  DeviceInfo device;
  SDL_AudioSpec spec;
  SDL_LockMutex(audio_mutex);
  bool ok = mixer_open(mixer) && MIX_GetMixerFormat(mixer->mixer, &spec);
  if (ok && !mixer->offline) ok = device_info(&device, mixer->device, false, mixer->follows_default);
  SDL_UnlockMutex(audio_mutex);
  if (!ok) return audio_error(L);
  lua_createtable(L, 0, 7);
  lua_pushboolean(L, mixer->offline); lua_setfield(L, -2, "offline");
  push_spec(L, &spec); lua_setfield(L, -2, "spec");
  lua_pushinteger(L, mixer->max_voices); lua_setfield(L, -2, "max_voices");
  lua_pushboolean(L, mixer->paused); lua_setfield(L, -2, "paused");
  lua_pushnumber(L, mixer->gain); lua_setfield(L, -2, "gain");
  lua_pushnumber(L, mixer->rate); lua_setfield(L, -2, "rate");
  if (!mixer->offline) { push_device_info(L, &device); lua_setfield(L, -2, "device"); }
  return 1;
}

static int dispatch_callbacks(lua_State *L) {
  AudioMixer *mixer = *(AudioMixer **) lua_touserdata(L, 1);
  lua_getuservalue(L, 1); lua_getfield(L, -1, "callbacks");
  int callbacks = lua_gettop(L);
  lua_newtable(L);
  int snapshot = lua_gettop(L), count = 0, delivered = 0;
  lua_pushnil(L);
  while (lua_next(L, callbacks)) {
    AudioVoice *voice = lua_touserdata(L, -2);
    SDL_LockMutex(audio_mutex);
    collect_voices(mixer);
    bool terminal = voice->state != VOICE_ACTIVE;
    SDL_UnlockMutex(audio_mutex);
    if (terminal) {
      lua_pushvalue(L, -1); lua_rawseti(L, snapshot, ++count);
      lua_pushvalue(L, -2); lua_pushnil(L); lua_rawset(L, callbacks);
    }
    lua_pop(L, 1);
  }
  lua_pushnil(L);
  int first_error = lua_gettop(L);
  for (int i = 1; i <= count && mixer->mixer; i++) {
    lua_rawgeti(L, snapshot, i);
    lua_rawgeti(L, -1, 1);
    AudioVoice *voice = *(AudioVoice **) lua_touserdata(L, -1);
    lua_pop(L, 1);
    lua_rawgeti(L, -1, 2);
    lua_rawgeti(L, -2, 1);
    lua_pushstring(L, *voice->error ? "error" : voice->state == VOICE_FINISHED ? "finished" : "stopped");
    if (*voice->error) lua_pushstring(L, voice->error); else lua_pushnil(L);
    delivered++;
    if (lua_pcall(L, 3, 0, 0) != LUA_OK) {
      if (lua_isnil(L, first_error)) {
        if (!lua_isstring(L, -1)) { lua_pop(L, 1); lua_pushliteral(L, "audio completion callback failed"); }
        lua_replace(L, first_error);
      } else lua_pop(L, 1);
    }
    lua_pop(L, 1);
  }
  lua_pushinteger(L, delivered); lua_pushvalue(L, first_error);
  return 2;
}

static int f_mixer_dispatch_events(lua_State *L) {
  AudioMixer *mixer = *(AudioMixer **) luaL_checkudata(L, 1, API_TYPE_AUDIO_MIXER);
  if (!mixer_open(mixer)) return audio_error(L);
  if (mixer->dispatching) { SDL_SetError("recursive audio callback dispatch is not allowed"); return audio_error(L); }
  lua_pushcfunction(L, dispatch_callbacks); lua_pushvalue(L, 1);
  mixer->dispatching = true;
  SDL_SetAtomicInt(&mixer->pending, 0);
  int status = lua_pcall(L, 1, 2, 0);
  mixer->dispatching = false;
  if (status != LUA_OK) return lua_error(L);
  return 2;
}

void api_audio_dispatch(lua_State *L) {
  if (!SDL_SetAtomicInt(&main_pending, 0)) return;
  int top = lua_gettop(L);
  lua_getfield(L, LUA_REGISTRYINDEX, AUDIO_MIXERS);
  if (!lua_istable(L, -1)) { lua_settop(L, top); return; }
  lua_newtable(L);
  int snapshot = lua_gettop(L), count = 0;
  lua_pushnil(L);
  while (lua_next(L, snapshot - 1)) {
    AudioMixer *mixer = *(AudioMixer **) lua_touserdata(L, -1);
    if (mixer && mixer->mixer && SDL_GetAtomicInt(&mixer->pending)) {
      lua_pushvalue(L, -1); lua_rawseti(L, snapshot, ++count);
    }
    lua_pop(L, 1);
  }
  for (int i = 1; i <= count; i++) {
    lua_pushcfunction(L, f_mixer_dispatch_events); lua_rawgeti(L, snapshot, i);
    int status = lua_pcall(L, 1, 2, 0);
    if (status != LUA_OK || !lua_isnil(L, -1)) {
      const char *message = lua_tostring(L, -1);
      SDL_LogError(SDL_LOG_CATEGORY_AUDIO, "Audio callback: %s", message ? message : "unknown error");
    }
    lua_settop(L, snapshot);
  }
  lua_settop(L, top);
}

static const luaL_Reg mixer_methods[] = {
  { "group", f_mixer_group }, { "get_info", f_mixer_get_info },
  { "stop", f_owner_stop }, { "render", f_mixer_render },
  { "set_sample_buffer", f_mixer_set_sample_buffer }, { "get_samples", f_mixer_get_samples },
  { "resume_together", f_mixer_resume_together }, { "dispatch_events", f_mixer_dispatch_events },
  { "close", f_mixer_close }, { "__gc", f_mixer_gc }, { NULL, NULL }
};

static const luaL_Reg group_methods[] = {
  { "stop", f_owner_stop }, { "__gc", f_group_gc }, { NULL, NULL }
};

static const luaL_Reg voice_methods[] = {
  { "get_state", f_voice_get_state }, { "stop", f_voice_stop },
  { "get_position", f_voice_get_position }, { "seek", f_voice_seek },
  { "get_duration", f_voice_get_duration },
  { "get_pan", f_voice_get_pan }, { "set_pan", f_voice_set_pan },
  { "write", f_voice_write }, { "get_queued_bytes", f_voice_queued },
  { "clear", f_voice_clear }, { "finish", f_voice_finish }, { "__gc", f_voice_gc }, { NULL, NULL }
};

static const luaL_Reg sound_methods[] = {
  { "get_spec", f_sound_get_spec }, { "get_size", f_sound_get_size },
  { "get_duration", f_sound_get_duration }, { "get_data", f_sound_get_data },
  { "get_metadata", f_sound_get_metadata }, { "close", f_sound_close },
  { "__gc", f_sound_close }, { NULL, NULL }
};

static const luaL_Reg stream_methods[] = {
  { "write", f_stream_write }, { "read", f_stream_read }, { "get_formats", f_stream_get_formats },
  { "get_device_info", f_stream_device_info }, { "close", f_stream_close },
  { "__gc", f_stream_close }, { NULL, NULL }
};

static const luaL_Reg module_functions[] = {
  { "get_drivers", f_get_drivers }, { "get_driver", f_get_driver },
  { "get_devices", f_get_devices }, { "get_decoders", f_get_decoders },
  { "create_mixer", f_create_mixer }, { "open_recording", f_open_recording },
  { "new_sound", f_new_sound }, { "create_stream", f_create_stream },
  { "convert", f_convert }, { NULL, NULL }
};

static void register_type(lua_State *L, const char *type, const luaL_Reg *methods, lua_CFunction control) {
  static const char *const controls[] = {
    "pause", "resume", "is_paused", "get_gain", "set_gain", "get_rate", "set_rate",
    "get_queued_bytes", "get_available_bytes", "clear", "flush"
  };
  luaL_newmetatable(L, type);
  luaL_setfuncs(L, methods, 0);
  lua_pushvalue(L, -1); lua_setfield(L, -2, "__index");
  if (control) {
    for (int i = PAUSE; i <= (control == stream_control ? FLUSH : SET_RATE); i++) {
      if ((control == voice_control && i == IS_PAUSED)
          || (methods == group_methods && (i == GET_RATE || i == SET_RATE))) continue;
      lua_pushinteger(L, i); lua_pushcclosure(L, control, 1); lua_setfield(L, -2, controls[i]);
    }
  }
  if (control == owner_control) {
    static const char *const names[] = { "play", "play_file", "play_stream" };
    for (int i = 0; i < 3; i++) {
      lua_pushinteger(L, i); lua_pushcclosure(L, f_play, 1); lua_setfield(L, -2, names[i]);
    }
  }
  lua_pop(L, 1);
}

int luaopen_audio(lua_State *L) {
  SDL_LockSpinlock(&mutex_init);
  if (!audio_mutex) audio_mutex = SDL_CreateMutex();
  SDL_UnlockSpinlock(&mutex_init);
  if (!audio_mutex) return luaL_error(L, "%s", SDL_GetError());
  if (SDL_IsMainThread() && !register_custom_event(AUDIO_EVENT, NULL))
    return luaL_error(L, "cannot register audio completion event: %s", SDL_GetError());
  register_type(L, API_TYPE_AUDIO_MIXER, mixer_methods, owner_control);
  register_type(L, API_TYPE_AUDIO_GROUP, group_methods, owner_control);
  register_type(L, API_TYPE_AUDIO_VOICE, voice_methods, voice_control);
  register_type(L, API_TYPE_AUDIO_SOUND, sound_methods, NULL);
  register_type(L, API_TYPE_AUDIO_STREAM, stream_methods, stream_control);
  luaL_newmetatable(L, AUDIO_ALLOCATION);
  lua_pushcfunction(L, allocation_gc); lua_setfield(L, -2, "__gc"); lua_pop(L, 1);
  lua_getfield(L, LUA_REGISTRYINDEX, AUDIO_MIXERS);
  if (lua_isnil(L, -1)) {
    lua_newtable(L); lua_newtable(L);
    lua_pushliteral(L, "v"); lua_setfield(L, -2, "__mode"); lua_setmetatable(L, -2);
    lua_setfield(L, LUA_REGISTRYINDEX, AUDIO_MIXERS);
  }
  lua_pop(L, 1);
  luaL_newlib(L, module_functions);
  lua_pushboolean(L, false); lua_pushcclosure(L, f_load, 1); lua_setfield(L, -2, "load");
  lua_pushboolean(L, true); lua_pushcclosure(L, f_load, 1); lua_setfield(L, -2, "load_memory");
  return 1;
}
