#include "api.h"

#include <SDL3/SDL.h>
#include <float.h>
#include <limits.h>
#include <math.h>
#include <string.h>

#define AUDIO_ALLOCATION "AudioAllocation"

typedef struct AudioDevice AudioDevice;
typedef struct AudioStream AudioStream;
typedef struct AudioVoice AudioVoice;

typedef struct {
  SDL_AudioSpec spec;
  Uint8 *data;
  int size;
  unsigned refs;
} AudioSound;

struct AudioStream {
  SDL_AudioStream *stream;
  AudioDevice *device;
  AudioStream *next;
  bool paused;
};

typedef enum { VOICE_ACTIVE, VOICE_FINISHED, VOICE_STOPPED } VoiceState;

struct AudioVoice {
  AudioDevice *device;
  AudioVoice *next;
  AudioSound *sound;
  SDL_AudioStream *stream;
  Uint8 *loop_data;
  int size, offset;
  unsigned refs;
  float gain, rate;
  bool loop, paused, eof, failed;
  VoiceState state;
  char error[256];
};

struct AudioDevice {
  SDL_AudioDeviceID id;
  AudioDevice *next;
  AudioStream *streams;
  AudioVoice *voices;
  unsigned refs;
  int max_voices, voice_count;
  bool recording, follows_default;
};

/* Protect ownership across Lua states and the reaper. Never call Lua while this
 * mutex is held. SDL callbacks take only their stream lock, never this mutex. */
static SDL_Mutex *audio_mutex;
static SDL_SpinLock audio_mutex_init;
static SDL_Semaphore *audio_wake;
static SDL_Thread *audio_reaper;
static AudioDevice *audio_devices;
static bool audio_initialized, audio_stopping;

static const struct { const char *name; SDL_AudioFormat value; } formats[] = {
  { "u8", SDL_AUDIO_U8 }, { "s8", SDL_AUDIO_S8 },
  { "s16le", SDL_AUDIO_S16LE }, { "s16be", SDL_AUDIO_S16BE },
  { "s32le", SDL_AUDIO_S32LE }, { "s32be", SDL_AUDIO_S32BE },
  { "f32le", SDL_AUDIO_F32LE }, { "f32be", SDL_AUDIO_F32BE },
  { "s16", SDL_AUDIO_S16 }, { "s32", SDL_AUDIO_S32 },
  { "f32", SDL_AUDIO_F32 }
};

static int audio_error(lua_State *L) {
  char error[1024];
  SDL_strlcpy(error, SDL_GetError(), sizeof(error));
  lua_pushnil(L);
  lua_pushstring(L, error);
  return 2;
}

static int audio_result(lua_State *L, bool success) {
  SDL_UnlockMutex(audio_mutex);
  if (!success) return audio_error(L);
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
  SDL_free(*data);
  *data = NULL;
  return 0;
}

static int check_integer(lua_State *L, int index, int min, int max) {
  luaL_checktype(L, index, LUA_TNUMBER);
  lua_Number value = lua_tonumber(L, index);
  luaL_argcheck(L, isfinite(value) && value >= min && value <= max
    && floor(value) == value, index, "integer out of range");
  return (int) value;
}

static float check_multiplier(lua_State *L, int index, bool rate) {
  luaL_checktype(L, index, LUA_TNUMBER);
  lua_Number value = lua_tonumber(L, index);
  luaL_argcheck(L, isfinite(value) && value >= (rate ? 0.01 : 0)
    && value <= (rate ? 100 : FLT_MAX), index, "multiplier out of range");
  return (float) value;
}

static bool option_bool(lua_State *L, int table, const char *key) {
  lua_getfield(L, table, key);
  if (!lua_isnil(L, -1)) luaL_checktype(L, -1, LUA_TBOOLEAN);
  bool value = lua_toboolean(L, -1);
  lua_pop(L, 1);
  return value;
}

static SDL_AudioSpec check_spec(lua_State *L, int index) {
  SDL_AudioSpec spec = {0};
  index = lua_absindex(L, index);
  luaL_checktype(L, index, LUA_TTABLE);
  lua_getfield(L, index, "format");
  luaL_checktype(L, -1, LUA_TSTRING);
  size_t name_size;
  const char *name = lua_tolstring(L, -1, &name_size);
  for (size_t i = 0; i < SDL_arraysize(formats); i++) {
    if (strlen(formats[i].name) == name_size && memcmp(name, formats[i].name, name_size) == 0) {
      spec.format = formats[i].value;
      break;
    }
  }
  luaL_argcheck(L, spec.format != SDL_AUDIO_UNKNOWN, index, "unsupported PCM format");
  lua_pop(L, 1);
  lua_getfield(L, index, "channels");
  spec.channels = check_integer(L, -1, 1, 8);
  lua_pop(L, 1);
  lua_getfield(L, index, "sample_rate");
  spec.freq = check_integer(L, -1, 1, INT_MAX);
  lua_pop(L, 1);
  return spec;
}

static bool valid_frequency(const SDL_AudioSpec *spec, float rate) {
  /* SDL scales the source frequency in float, then converts it to signed int. */
  float frequency = (float) spec->freq * rate;
  return (frequency >= 1 && frequency < (float) INT_MAX)
    || SDL_SetError("sample rate and playback rate exceed SDL's conversion range");
}

static void push_spec(lua_State *L, const SDL_AudioSpec *spec) {
  lua_createtable(L, 0, 3);
  for (size_t i = 0; i < SDL_arraysize(formats); i++) {
    if (formats[i].value == spec->format) {
      lua_pushstring(L, formats[i].name);
      lua_setfield(L, -2, "format");
      break;
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

static bool init_locked(void) {
  if (audio_stopping) return SDL_SetError("audio is shutting down");
  if (audio_initialized) return true;
  if (!SDL_IsMainThread()) return SDL_SetError("initialize audio on the main thread before using devices in a worker");
  if (!SDL_InitSubSystem(SDL_INIT_AUDIO)) return false;
  audio_initialized = true;
  return true;
}

static bool device_open(AudioDevice *device) {
  return device && device->id ? true : SDL_SetError("audio device is closed");
}

static bool stream_open(AudioStream *stream) {
  return stream->stream ? true : SDL_SetError("audio stream is closed");
}

static void sound_unref(AudioSound *sound) {
  if (sound && --sound->refs == 0) {
    SDL_free(sound->data);
    SDL_free(sound);
  }
}

static void device_unref(AudioDevice *device) {
  if (device && --device->refs == 0) SDL_free(device);
}

static void voice_unref(AudioVoice *voice) {
  if (voice && --voice->refs == 0) {
    device_unref(voice->device);
    SDL_free(voice);
  }
}

static void stream_close(AudioStream *stream) {
  if (!stream->stream) return;
  SDL_DestroyAudioStream(stream->stream);
  stream->stream = NULL;
  if (stream->device) {
    AudioStream **link = &stream->device->streams;
    while (*link && *link != stream) link = &(*link)->next;
    if (*link) *link = stream->next;
    stream->next = NULL;
  }
}

static void voice_finish(AudioVoice *voice, VoiceState state) {
  if (voice->state != VOICE_ACTIVE) return;
  /* Destroy waits for an in-flight SDL callback before releasing its userdata. */
  SDL_DestroyAudioStream(voice->stream);
  voice->stream = NULL;
  sound_unref(voice->sound);
  voice->sound = NULL;
  SDL_free(voice->loop_data);
  voice->loop_data = NULL;
  voice->state = state;
  AudioVoice **link = &voice->device->voices;
  while (*link != voice) link = &(*link)->next;
  *link = voice->next;
  voice->next = NULL;
  voice->device->voice_count--;
  voice_unref(voice); /* Release the device's active-voice reference. */
}

static void collect_voices(AudioDevice *device) {
  AudioVoice *voice = device->voices;
  while (voice) {
    AudioVoice *next = voice->next;
    SDL_LockAudioStream(voice->stream);
    bool failed = voice->failed;
    bool finished = voice->eof && SDL_GetAudioStreamQueued(voice->stream) == 0
      && SDL_GetAudioStreamAvailable(voice->stream) == 0;
    SDL_UnlockAudioStream(voice->stream);
    if (failed || finished) voice_finish(voice, failed ? VOICE_STOPPED : VOICE_FINISHED);
    voice = next;
  }
}

static void device_close(AudioDevice *device) {
  if (!device || !device->id) return;
  while (device->voices) voice_finish(device->voices, VOICE_STOPPED);
  while (device->streams) stream_close(device->streams);
  SDL_CloseAudioDevice(device->id);
  device->id = 0;
  AudioDevice **link = &audio_devices;
  while (*link != device) link = &(*link)->next;
  *link = device->next;
  device->next = NULL;
}

static int SDLCALL reap_voices(void *unused) {
  (void) unused;
  bool active = false;
  for (;;) {
    if (active) SDL_WaitSemaphoreTimeout(audio_wake, 10);
    else SDL_WaitSemaphore(audio_wake);
    SDL_LockMutex(audio_mutex);
    if (audio_stopping) { SDL_UnlockMutex(audio_mutex); return 0; }
    active = false;
    for (AudioDevice *device = audio_devices; device; device = device->next) {
      collect_voices(device);
      active |= device->voices != NULL;
    }
    SDL_UnlockMutex(audio_mutex);
  }
}

static bool start_reaper(void) {
  if (audio_reaper) return true;
  audio_wake = SDL_CreateSemaphore(0);
  if (!audio_wake) return false;
  audio_reaper = SDL_CreateThread(reap_voices, "audio-voices", NULL);
  if (!audio_reaper) {
    SDL_DestroySemaphore(audio_wake);
    audio_wake = NULL;
    return false;
  }
  return true;
}

/* This runs with SDL's stream lock, not on the Lua thread. It never accesses Lua,
 * takes our ownership lock, or destroys a stream. Reclamation is left to reaper. */
static void SDLCALL feed_voice(void *userdata, SDL_AudioStream *stream, int additional, int total) {
  (void) total;
  AudioVoice *voice = userdata;
  if (additional <= 0 || voice->eof || voice->failed) return;
  int frame = (int) SDL_AUDIO_FRAMESIZE(voice->sound->spec);
  Sint64 needed = ((Sint64) additional + frame - 1) / frame * frame;
  const Uint8 *data = voice->loop_data ? voice->loop_data : voice->sound->data;
  while (needed > 0) {
    int count = (int) SDL_min(needed, voice->size - voice->offset);
    if (!SDL_PutAudioStreamData(stream, data + voice->offset, count)) {
      voice->failed = true;
      break;
    }
    voice->offset += count;
    needed -= count;
    if (voice->offset == voice->size) {
      if (voice->loop) voice->offset = 0;
      else {
        voice->eof = true;
        if (!SDL_FlushAudioStream(stream)) voice->failed = true;
        break;
      }
    }
  }
  if (voice->failed) SDL_strlcpy(voice->error, SDL_GetError(), sizeof(voice->error));
  if (voice->eof || voice->failed) SDL_SignalSemaphore(audio_wake);
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
  while (audio_devices) device_close(audio_devices);
  SDL_DestroySemaphore(audio_wake);
  audio_wake = NULL;
  audio_reaper = NULL;
  if (audio_initialized) SDL_QuitSubSystem(SDL_INIT_AUDIO);
  audio_initialized = false;
  SDL_UnlockMutex(audio_mutex);
  /* Keep the ownership mutex valid for late finalizers in worker Lua states. */
}

static int f_init(lua_State *L) {
  SDL_LockMutex(audio_mutex);
  return audio_result(L, init_locked());
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
  if (audio_initialized) {
    const char *driver = SDL_GetCurrentAudioDriver();
    if (driver) SDL_strlcpy(name, driver, sizeof(name));
  }
  SDL_UnlockMutex(audio_mutex);
  if (*name) lua_pushstring(L, name); else lua_pushnil(L);
  return 1;
}

static bool check_kind(lua_State *L, int index) {
  static const char *const kinds[] = { "playback", "recording", NULL };
  return luaL_checkoption(L, index, "playback", kinds) == 1;
}

static int f_get_devices(lua_State *L) {
  bool recording = check_kind(L, 1);
  void **allocation = new_object(L, sizeof(void *), AUDIO_ALLOCATION);
  SDL_LockMutex(audio_mutex);
  if (!init_locked()) { SDL_UnlockMutex(audio_mutex); return audio_error(L); }
  int count = 0;
  SDL_AudioDeviceID *ids = recording ? SDL_GetAudioRecordingDevices(&count) : SDL_GetAudioPlaybackDevices(&count);
  *allocation = ids;
  SDL_UnlockMutex(audio_mutex);
  if (!ids) return audio_error(L);
  lua_createtable(L, count, 0);
  for (int i = 0; i < count; i++) {
    char name[1024];
    SDL_LockMutex(audio_mutex);
    const char *s = !audio_stopping ? SDL_GetAudioDeviceName(ids[i]) : NULL;
    SDL_strlcpy(name, s ? s : "", sizeof(name));
    SDL_UnlockMutex(audio_mutex);
    lua_createtable(L, 0, 3);
    lua_pushnumber(L, ids[i]); lua_setfield(L, -2, "id");
    lua_pushstring(L, name); lua_setfield(L, -2, "name");
    lua_pushstring(L, recording ? "recording" : "playback"); lua_setfield(L, -2, "kind");
    lua_rawseti(L, -2, i + 1);
  }
  SDL_free(ids); *allocation = NULL;
  return 1;
}

static int f_open_device(lua_State *L) {
  bool recording = check_kind(L, 1), follows_default = true, has_spec = false;
  SDL_AudioDeviceID requested = recording ? SDL_AUDIO_DEVICE_DEFAULT_RECORDING : SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK;
  SDL_AudioSpec spec;
  int max_voices = 64;
  if (!lua_isnoneornil(L, 2)) {
    luaL_checktype(L, 2, LUA_TTABLE);
    lua_getfield(L, 2, "id");
    if (!lua_isnil(L, -1)) {
      luaL_checktype(L, -1, LUA_TNUMBER);
      lua_Number id = lua_tonumber(L, -1);
      luaL_argcheck(L, isfinite(id) && id > 0 && id < SDL_AUDIO_DEVICE_DEFAULT_RECORDING && floor(id) == id, 2, "invalid device ID");
      requested = (SDL_AudioDeviceID) id;
      follows_default = false;
    }
    lua_pop(L, 1);
    lua_getfield(L, 2, "spec");
    if (!lua_isnil(L, -1)) { spec = check_spec(L, -1); has_spec = true; }
    lua_pop(L, 1);
    lua_getfield(L, 2, "max_voices");
    if (!lua_isnil(L, -1)) {
      luaL_argcheck(L, !recording, 2, "max_voices is only valid for playback");
      max_voices = check_integer(L, -1, 1, INT_MAX);
    }
    lua_pop(L, 1);
  }
  AudioDevice **ud = new_object(L, sizeof(*ud), API_TYPE_AUDIO_DEVICE);
  if (has_spec && !valid_frequency(&spec, 1)) return audio_error(L);
  SDL_LockMutex(audio_mutex);
  if (!init_locked()) { SDL_UnlockMutex(audio_mutex); return audio_error(L); }
  if (!follows_default && (!SDL_IsAudioDevicePhysical(requested)
      || SDL_IsAudioDevicePlayback(requested) == recording)) {
    SDL_SetError("audio device ID is not a physical device of the requested kind");
    SDL_UnlockMutex(audio_mutex); return audio_error(L);
  }
  AudioDevice *device = SDL_calloc(1, sizeof(*device));
  if (!device) { SDL_OutOfMemory(); SDL_UnlockMutex(audio_mutex); return audio_error(L); }
  device->id = SDL_OpenAudioDevice(requested, has_spec ? &spec : NULL);
  if (!device->id) { SDL_free(device); SDL_UnlockMutex(audio_mutex); return audio_error(L); }
  device->refs = 1;
  device->max_voices = max_voices;
  device->recording = recording;
  device->follows_default = follows_default;
  device->next = audio_devices;
  audio_devices = device;
  *ud = device;
  bool ok = SDL_PauseAudioDevice(device->id);
  if (!ok) device_close(device);
  SDL_UnlockMutex(audio_mutex);
  if (!ok) return audio_error(L);
  return 1;
}

static int f_load_wav(lua_State *L) {
  size_t size;
  luaL_checktype(L, 1, LUA_TSTRING);
  const char *data = lua_tolstring(L, 1, &size);
  bool memory = lua_toboolean(L, lua_upvalueindex(1));
  if (!memory) luaL_argcheck(L, strlen(data) == size, 1, "path contains NUL");
  AudioSound **ud = new_object(L, sizeof(*ud), API_TYPE_AUDIO_SOUND);
  AudioSound *sound = SDL_calloc(1, sizeof(*sound));
  if (!sound) { SDL_OutOfMemory(); return audio_error(L); }
  sound->refs = 1;
  *ud = sound;
  Uint32 bytes = 0;
  bool ok = memory
    ? SDL_LoadWAV_IO(SDL_IOFromConstMem(data, size), true, &sound->spec, &sound->data, &bytes)
    : SDL_LoadWAV(data, &sound->spec, &sound->data, &bytes);
  if (ok && (bytes == 0 || bytes > INT_MAX || bytes % SDL_AUDIO_FRAMESIZE(sound->spec)))
    ok = SDL_SetError("WAV must contain complete PCM frames within INT_MAX bytes");
  if (!ok) { sound_unref(sound); *ud = NULL; return audio_error(L); }
  sound->size = (int) bytes;
  return 1;
}

static int f_new_sound(lua_State *L) {
  SDL_AudioSpec spec = check_spec(L, 2);
  int size;
  const char *data = check_pcm(L, 1, &spec, &size, false);
  AudioSound **ud = new_object(L, sizeof(*ud), API_TYPE_AUDIO_SOUND);
  AudioSound *sound = SDL_calloc(1, sizeof(*sound));
  if (!sound) { SDL_OutOfMemory(); return audio_error(L); }
  sound->refs = 1;
  *ud = sound;
  sound->data = SDL_malloc((size_t) size);
  if (!sound->data) { SDL_OutOfMemory(); sound_unref(sound); *ud = NULL; return audio_error(L); }
  SDL_memcpy(sound->data, data, size);
  sound->spec = spec;
  sound->size = size;
  return 1;
}

static int f_create_stream(lua_State *L) {
  SDL_AudioSpec input = check_spec(L, 1), output = check_spec(L, 2);
  if (!valid_frequency(&input, 1)) return audio_error(L);
  AudioStream *stream = new_object(L, sizeof(*stream), API_TYPE_AUDIO_STREAM);
  stream->stream = SDL_CreateAudioStream(&input, &output);
  if (!stream->stream) return audio_error(L);
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

static int f_device_get_info(lua_State *L) {
  AudioDevice *device = *(AudioDevice **) luaL_checkudata(L, 1, API_TYPE_AUDIO_DEVICE);
  SDL_AudioSpec spec;
  int frames;
  char name[1024];
  SDL_LockMutex(audio_mutex);
  if (!device_open(device) || !SDL_GetAudioDeviceFormat(device->id, &spec, &frames)) {
    SDL_UnlockMutex(audio_mutex); return audio_error(L);
  }
  const char *s = SDL_GetAudioDeviceName(device->id);
  if (!s) { SDL_UnlockMutex(audio_mutex); return audio_error(L); }
  SDL_strlcpy(name, s, sizeof(name));
  SDL_AudioDeviceID id = device->id;
  bool paused = SDL_AudioDevicePaused(id);
  bool recording = device->recording, follows_default = device->follows_default;
  int max_voices = device->max_voices;
  float gain = SDL_GetAudioDeviceGain(id);
  SDL_UnlockMutex(audio_mutex);
  if (gain < 0) return audio_error(L);
  lua_createtable(L, 0, 9);
  lua_pushnumber(L, id); lua_setfield(L, -2, "id");
  lua_pushstring(L, name); lua_setfield(L, -2, "name");
  lua_pushstring(L, recording ? "recording" : "playback"); lua_setfield(L, -2, "kind");
  push_spec(L, &spec); lua_setfield(L, -2, "spec");
  lua_pushinteger(L, frames); lua_setfield(L, -2, "buffer_frames");
  lua_pushboolean(L, paused); lua_setfield(L, -2, "paused");
  lua_pushnumber(L, gain); lua_setfield(L, -2, "gain");
  lua_pushboolean(L, follows_default); lua_setfield(L, -2, "follows_default");
  if (!recording) { lua_pushinteger(L, max_voices); lua_setfield(L, -2, "max_voices"); }
  return 1;
}

static int f_device_create_stream(lua_State *L) {
  AudioDevice **owner = luaL_checkudata(L, 1, API_TYPE_AUDIO_DEVICE);
  SDL_AudioSpec app = check_spec(L, 2), hardware;
  AudioStream *stream = new_object(L, sizeof(*stream), API_TYPE_AUDIO_STREAM);
  AudioDevice *device = *owner;
  SDL_LockMutex(audio_mutex);
  if (!device_open(device) || !SDL_GetAudioDeviceFormat(device->id, &hardware, NULL)) {
    SDL_UnlockMutex(audio_mutex); return audio_error(L);
  }
  if (!valid_frequency(device->recording ? &hardware : &app, 1)) {
    SDL_UnlockMutex(audio_mutex); return audio_error(L);
  }
  stream->stream = SDL_CreateAudioStream(device->recording ? &hardware : &app, device->recording ? &app : &hardware);
  if (!stream->stream) { SDL_UnlockMutex(audio_mutex); return audio_error(L); }
  if (!SDL_BindAudioStream(device->id, stream->stream)) {
    SDL_DestroyAudioStream(stream->stream); stream->stream = NULL;
    SDL_UnlockMutex(audio_mutex); return audio_error(L);
  }
  stream->device = device;
  device->refs++;
  stream->next = device->streams;
  device->streams = stream;
  SDL_UnlockMutex(audio_mutex);
  return 1;
}

static int f_device_play(lua_State *L) {
  AudioDevice **owner = luaL_checkudata(L, 1, API_TYPE_AUDIO_DEVICE);
  AudioSound **sample = luaL_checkudata(L, 2, API_TYPE_AUDIO_SOUND);
  float gain = 1, rate = 1;
  bool loop = false, paused = false;
  if (!lua_isnoneornil(L, 3)) {
    luaL_checktype(L, 3, LUA_TTABLE);
    loop = option_bool(L, 3, "loop"); paused = option_bool(L, 3, "paused");
    lua_getfield(L, 3, "gain");
    if (!lua_isnil(L, -1)) gain = check_multiplier(L, -1, false);
    lua_pop(L, 1);
    lua_getfield(L, 3, "rate");
    if (!lua_isnil(L, -1)) rate = check_multiplier(L, -1, true);
    lua_pop(L, 1);
  }
  AudioVoice **ud = new_object(L, sizeof(*ud), API_TYPE_AUDIO_VOICE);
  /* Option-table metamethods can close a handle while arguments are parsed. */
  AudioDevice *device = *owner;
  AudioSound *sound = *sample;
  SDL_LockMutex(audio_mutex);
  if (!device_open(device)) { SDL_UnlockMutex(audio_mutex); return audio_error(L); }
  if (device->recording || !sound) {
    SDL_SetError(device->recording ? "cannot play on a recording device" : "audio sound is closed");
    SDL_UnlockMutex(audio_mutex); return audio_error(L);
  }
  if (!valid_frequency(&sound->spec, rate)) {
    SDL_UnlockMutex(audio_mutex); return audio_error(L);
  }
  collect_voices(device);
  if (device->voice_count >= device->max_voices) {
    SDL_SetError("audio voice limit reached"); SDL_UnlockMutex(audio_mutex); return audio_error(L);
  }
  SDL_AudioSpec hardware;
  if (!SDL_GetAudioDeviceFormat(device->id, &hardware, NULL) || !start_reaper()) {
    SDL_UnlockMutex(audio_mutex); return audio_error(L);
  }
  AudioVoice *voice = SDL_calloc(1, sizeof(*voice));
  if (!voice) { SDL_OutOfMemory(); SDL_UnlockMutex(audio_mutex); return audio_error(L); }
  voice->refs = 1;
  voice->device = device; device->refs++;
  voice->state = VOICE_STOPPED;
  voice->gain = gain; voice->rate = rate;
  voice->loop = loop; voice->paused = paused;
  voice->size = sound->size;
  *ud = voice;
  /* Expand very short loops once, avoiding thousands of tiny queue allocations
   * inside each SDL callback. Longer samples continue sharing their PCM storage. */
  if (loop && sound->size < 4096) {
    voice->size = 4096 / sound->size * sound->size;
    voice->loop_data = SDL_malloc((size_t) voice->size);
    if (!voice->loop_data) { SDL_OutOfMemory(); SDL_UnlockMutex(audio_mutex); return audio_error(L); }
    SDL_memcpy(voice->loop_data, sound->data, sound->size);
    for (int n = sound->size; n < voice->size;) {
      int count = SDL_min(n, voice->size - n);
      SDL_memcpy(voice->loop_data + n, voice->loop_data, count); n += count;
    }
  }
  voice->stream = SDL_CreateAudioStream(&sound->spec, &hardware);
  bool ok = voice->stream && SDL_SetAudioStreamGain(voice->stream, gain)
    && SDL_SetAudioStreamFrequencyRatio(voice->stream, rate);
  voice->sound = sound; sound->refs++;
  if (ok) ok = SDL_SetAudioStreamGetCallback(voice->stream, feed_voice, voice);
  if (ok && !paused) ok = SDL_BindAudioStream(device->id, voice->stream);
  if (!ok) {
    SDL_DestroyAudioStream(voice->stream); voice->stream = NULL;
    sound_unref(voice->sound); voice->sound = NULL;
    SDL_free(voice->loop_data); voice->loop_data = NULL;
    SDL_UnlockMutex(audio_mutex); return audio_error(L);
  }
  voice->state = VOICE_ACTIVE;
  voice->refs++;
  voice->next = device->voices; device->voices = voice;
  device->voice_count++;
  SDL_SignalSemaphore(audio_wake);
  SDL_UnlockMutex(audio_mutex);
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

static int device_control(lua_State *L, Control control) {
  AudioDevice *device = *(AudioDevice **) luaL_checkudata(L, 1, API_TYPE_AUDIO_DEVICE);
  double value = control == SET_GAIN ? check_multiplier(L, 2, false) : 0;
  SDL_LockMutex(audio_mutex);
  if (!device_open(device)) return push_control(L, control, false, 0);
  bool ok = true;
  switch (control) {
    case PAUSE: ok = SDL_PauseAudioDevice(device->id); break;
    case RESUME: ok = SDL_ResumeAudioDevice(device->id); break;
    case IS_PAUSED: value = SDL_AudioDevicePaused(device->id); break;
    case GET_GAIN: value = SDL_GetAudioDeviceGain(device->id); ok = value >= 0; break;
    case SET_GAIN: ok = SDL_SetAudioDeviceGain(device->id, (float) value); break;
    default: break;
  }
  return push_control(L, control, ok, value);
}

static int f_device_pause(lua_State *L) { return device_control(L, PAUSE); }
static int f_device_resume(lua_State *L) { return device_control(L, RESUME); }
static int f_device_is_paused(lua_State *L) { return device_control(L, IS_PAUSED); }
static int f_device_get_gain(lua_State *L) { return device_control(L, GET_GAIN); }
static int f_device_set_gain(lua_State *L) { return device_control(L, SET_GAIN); }

static int f_device_close(lua_State *L) {
  AudioDevice *device = *(AudioDevice **) luaL_checkudata(L, 1, API_TYPE_AUDIO_DEVICE);
  SDL_LockMutex(audio_mutex); device_close(device); SDL_UnlockMutex(audio_mutex);
  return 0;
}

static int f_device_gc(lua_State *L) {
  AudioDevice **ud = luaL_checkudata(L, 1, API_TYPE_AUDIO_DEVICE);
  SDL_LockMutex(audio_mutex);
  device_close(*ud); device_unref(*ud); *ud = NULL;
  SDL_UnlockMutex(audio_mutex);
  return 0;
}

static int f_stream_write(lua_State *L) {
  AudioStream *stream = luaL_checkudata(L, 1, API_TYPE_AUDIO_STREAM);
  SDL_AudioSpec input;
  SDL_LockMutex(audio_mutex);
  bool ok = stream_open(stream);
  if (ok && stream->device && stream->device->recording) ok = SDL_SetError("cannot write to a recording stream");
  if (ok) ok = SDL_GetAudioStreamFormat(stream->stream, &input, NULL);
  SDL_UnlockMutex(audio_mutex);
  if (!ok) return audio_error(L);
  int size;
  const char *data = check_pcm(L, 2, &input, &size, true);
  SDL_LockMutex(audio_mutex);
  ok = stream_open(stream) && (size == 0 || SDL_PutAudioStreamData(stream->stream, data, size));
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
  bool ok = stream_open(stream);
  if (ok && stream->device && !stream->device->recording) ok = SDL_SetError("cannot read a playback stream");
  if (ok) ok = SDL_GetAudioStreamFormat(stream->stream, NULL, &output);
  int available = ok ? SDL_GetAudioStreamAvailable(stream->stream) : -1;
  SDL_UnlockMutex(audio_mutex);
  if (available < 0) return audio_error(L);
  int frame = (int) SDL_AUDIO_FRAMESIZE(output);
  luaL_argcheck(L, requested >= frame, 2, "read size is smaller than one PCM frame");
  int size = SDL_min(requested, available) / frame * frame;
  if (size == 0) { lua_pushliteral(L, ""); return 1; }
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

static int stream_control(lua_State *L, Control control) {
  AudioStream *stream = luaL_checkudata(L, 1, API_TYPE_AUDIO_STREAM);
  double value = (control == SET_GAIN || control == SET_RATE) ? check_multiplier(L, 2, control == SET_RATE) : 0;
  SDL_LockMutex(audio_mutex);
  if (!stream_open(stream)) return push_control(L, control, false, 0);
  if ((control == PAUSE || control == RESUME || control == IS_PAUSED) && !stream->device) {
    SDL_SetError("offline conversion streams cannot be paused"); return push_control(L, control, false, 0);
  }
  bool ok = true;
  switch (control) {
    case PAUSE: SDL_UnbindAudioStream(stream->stream); stream->paused = true; break;
    case RESUME:
      if (stream->paused) { ok = SDL_BindAudioStream(stream->device->id, stream->stream); if (ok) stream->paused = false; }
      break;
    case IS_PAUSED: value = stream->paused || SDL_AudioDevicePaused(stream->device->id); break;
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

static int f_stream_pause(lua_State *L) { return stream_control(L, PAUSE); }
static int f_stream_resume(lua_State *L) { return stream_control(L, RESUME); }
static int f_stream_is_paused(lua_State *L) { return stream_control(L, IS_PAUSED); }
static int f_stream_get_gain(lua_State *L) { return stream_control(L, GET_GAIN); }
static int f_stream_set_gain(lua_State *L) { return stream_control(L, SET_GAIN); }
static int f_stream_get_rate(lua_State *L) { return stream_control(L, GET_RATE); }
static int f_stream_set_rate(lua_State *L) { return stream_control(L, SET_RATE); }
static int f_stream_queued(lua_State *L) { return stream_control(L, QUEUED); }
static int f_stream_available(lua_State *L) { return stream_control(L, AVAILABLE); }
static int f_stream_clear(lua_State *L) { return stream_control(L, CLEAR); }
static int f_stream_flush(lua_State *L) { return stream_control(L, FLUSH); }

static int f_stream_close(lua_State *L) {
  AudioStream *stream = luaL_checkudata(L, 1, API_TYPE_AUDIO_STREAM);
  SDL_LockMutex(audio_mutex); stream_close(stream); SDL_UnlockMutex(audio_mutex);
  return 0;
}

static int f_stream_gc(lua_State *L) {
  AudioStream *stream = luaL_checkudata(L, 1, API_TYPE_AUDIO_STREAM);
  SDL_LockMutex(audio_mutex);
  stream_close(stream); device_unref(stream->device); stream->device = NULL;
  SDL_UnlockMutex(audio_mutex);
  return 0;
}

static int f_sound_get_spec(lua_State *L) {
  AudioSound *sound = *(AudioSound **) luaL_checkudata(L, 1, API_TYPE_AUDIO_SOUND);
  if (!sound) { SDL_SetError("audio sound is closed"); return audio_error(L); }
  SDL_AudioSpec spec = sound->spec;
  push_spec(L, &spec);
  return 1;
}

static int f_sound_get_size(lua_State *L) {
  AudioSound *sound = *(AudioSound **) luaL_checkudata(L, 1, API_TYPE_AUDIO_SOUND);
  if (!sound) { SDL_SetError("audio sound is closed"); return audio_error(L); }
  lua_pushinteger(L, sound->size);
  return 1;
}

static int f_sound_get_duration(lua_State *L) {
  AudioSound *sound = *(AudioSound **) luaL_checkudata(L, 1, API_TYPE_AUDIO_SOUND);
  if (!sound) { SDL_SetError("audio sound is closed"); return audio_error(L); }
  lua_pushnumber(L, (double) (sound->size / (int) SDL_AUDIO_FRAMESIZE(sound->spec)) / sound->spec.freq);
  return 1;
}

static int f_sound_get_data(lua_State *L) {
  AudioSound **owner = luaL_checkudata(L, 1, API_TYPE_AUDIO_SOUND);
  /* Lua string allocation can run a finalizer which closes the original handle.
   * A temporary owner also releases the reference if allocation raises an error. */
  AudioSound **guard = new_object(L, sizeof(*guard), API_TYPE_AUDIO_SOUND);
  AudioSound *sound = *owner;
  if (!sound) { SDL_SetError("audio sound is closed"); return audio_error(L); }
  SDL_LockMutex(audio_mutex);
  sound->refs++;
  *guard = sound;
  SDL_UnlockMutex(audio_mutex);
  lua_pushlstring(L, (const char *) sound->data, (size_t) sound->size);
  SDL_LockMutex(audio_mutex);
  sound_unref(sound);
  *guard = NULL;
  SDL_UnlockMutex(audio_mutex);
  return 1;
}

static int f_sound_close(lua_State *L) {
  AudioSound **ud = luaL_checkudata(L, 1, API_TYPE_AUDIO_SOUND);
  SDL_LockMutex(audio_mutex); sound_unref(*ud); *ud = NULL; SDL_UnlockMutex(audio_mutex);
  return 0;
}

static int f_voice_get_state(lua_State *L) {
  AudioVoice *voice = *(AudioVoice **) luaL_checkudata(L, 1, API_TYPE_AUDIO_VOICE);
  char error[256] = "";
  const char *state = "stopped";
  SDL_LockMutex(audio_mutex);
  if (voice) {
    if (voice->state == VOICE_ACTIVE) collect_voices(voice->device);
    state = voice->state == VOICE_FINISHED ? "finished" : voice->state == VOICE_STOPPED ? "stopped"
      : voice->paused || SDL_AudioDevicePaused(voice->device->id) ? "paused" : "playing";
    if (voice->state != VOICE_ACTIVE) SDL_strlcpy(error, voice->error, sizeof(error));
  }
  SDL_UnlockMutex(audio_mutex);
  lua_pushstring(L, state);
  if (*error) { lua_pushstring(L, error); return 2; }
  return 1;
}

static int voice_control(lua_State *L, Control control) {
  AudioVoice *voice = *(AudioVoice **) luaL_checkudata(L, 1, API_TYPE_AUDIO_VOICE);
  double value = (control == SET_GAIN || control == SET_RATE) ? check_multiplier(L, 2, control == SET_RATE) : 0;
  SDL_LockMutex(audio_mutex);
  if (!voice) { SDL_SetError("audio voice is closed"); return push_control(L, control, false, 0); }
  if (control == GET_GAIN || control == GET_RATE)
    return push_control(L, control, true, control == GET_GAIN ? voice->gain : voice->rate);
  if (voice->state == VOICE_ACTIVE) collect_voices(voice->device);
  if (voice->state != VOICE_ACTIVE) {
    SDL_SetError("audio voice has finished or stopped"); return push_control(L, control, false, 0);
  }
  bool ok = true;
  switch (control) {
    case PAUSE: SDL_UnbindAudioStream(voice->stream); voice->paused = true; break;
    case RESUME:
      if (voice->paused) { ok = SDL_BindAudioStream(voice->device->id, voice->stream); if (ok) voice->paused = false; }
      break;
    case SET_GAIN: ok = SDL_SetAudioStreamGain(voice->stream, (float) value); if (ok) voice->gain = (float) value; break;
    case SET_RATE:
      ok = valid_frequency(&voice->sound->spec, (float) value)
        && SDL_SetAudioStreamFrequencyRatio(voice->stream, (float) value);
      if (ok) voice->rate = (float) value;
      break;
    default: break;
  }
  return push_control(L, control, ok, value);
}

static int f_voice_pause(lua_State *L) { return voice_control(L, PAUSE); }
static int f_voice_resume(lua_State *L) { return voice_control(L, RESUME); }
static int f_voice_get_gain(lua_State *L) { return voice_control(L, GET_GAIN); }
static int f_voice_set_gain(lua_State *L) { return voice_control(L, SET_GAIN); }
static int f_voice_get_rate(lua_State *L) { return voice_control(L, GET_RATE); }
static int f_voice_set_rate(lua_State *L) { return voice_control(L, SET_RATE); }

static int f_voice_stop(lua_State *L) {
  AudioVoice *voice = *(AudioVoice **) luaL_checkudata(L, 1, API_TYPE_AUDIO_VOICE);
  SDL_LockMutex(audio_mutex);
  if (voice) voice_finish(voice, VOICE_STOPPED);
  SDL_UnlockMutex(audio_mutex);
  return 0;
}

static int f_voice_gc(lua_State *L) {
  AudioVoice **ud = luaL_checkudata(L, 1, API_TYPE_AUDIO_VOICE);
  SDL_LockMutex(audio_mutex); voice_unref(*ud); *ud = NULL; SDL_UnlockMutex(audio_mutex);
  return 0;
}

static const luaL_Reg device_methods[] = {
  { "get_info", f_device_get_info }, { "create_stream", f_device_create_stream },
  { "play", f_device_play }, { "pause", f_device_pause }, { "resume", f_device_resume },
  { "is_paused", f_device_is_paused }, { "get_gain", f_device_get_gain },
  { "set_gain", f_device_set_gain }, { "close", f_device_close }, { "__gc", f_device_gc }, { NULL, NULL }
};
static const luaL_Reg stream_methods[] = {
  { "write", f_stream_write }, { "read", f_stream_read }, { "get_formats", f_stream_get_formats },
  { "get_queued_bytes", f_stream_queued }, { "get_available_bytes", f_stream_available },
  { "flush", f_stream_flush }, { "clear", f_stream_clear }, { "pause", f_stream_pause },
  { "resume", f_stream_resume }, { "is_paused", f_stream_is_paused },
  { "get_gain", f_stream_get_gain }, { "set_gain", f_stream_set_gain },
  { "get_rate", f_stream_get_rate }, { "set_rate", f_stream_set_rate },
  { "close", f_stream_close }, { "__gc", f_stream_gc }, { NULL, NULL }
};
static const luaL_Reg sound_methods[] = {
  { "get_spec", f_sound_get_spec }, { "get_size", f_sound_get_size },
  { "get_duration", f_sound_get_duration }, { "get_data", f_sound_get_data },
  { "close", f_sound_close }, { "__gc", f_sound_close }, { NULL, NULL }
};
static const luaL_Reg voice_methods[] = {
  { "get_state", f_voice_get_state }, { "pause", f_voice_pause }, { "resume", f_voice_resume },
  { "stop", f_voice_stop }, { "get_gain", f_voice_get_gain }, { "set_gain", f_voice_set_gain },
  { "get_rate", f_voice_get_rate }, { "set_rate", f_voice_set_rate }, { "__gc", f_voice_gc }, { NULL, NULL }
};
static const luaL_Reg module_functions[] = {
  { "init", f_init }, { "get_drivers", f_get_drivers }, { "get_driver", f_get_driver },
  { "get_devices", f_get_devices }, { "open_device", f_open_device },
  { "new_sound", f_new_sound }, { "create_stream", f_create_stream }, { "convert", f_convert }, { NULL, NULL }
};

static void register_type(lua_State *L, const char *name, const luaL_Reg *methods) {
  luaL_newmetatable(L, name);
  luaL_setfuncs(L, methods, 0);
  lua_pushvalue(L, -1); lua_setfield(L, -2, "__index");
  lua_pop(L, 1);
}

int luaopen_audio(lua_State *L) {
  SDL_LockSpinlock(&audio_mutex_init);
  if (!audio_mutex) audio_mutex = SDL_CreateMutex();
  SDL_UnlockSpinlock(&audio_mutex_init);
  if (!audio_mutex) return luaL_error(L, "%s", SDL_GetError());
  register_type(L, API_TYPE_AUDIO_DEVICE, device_methods);
  register_type(L, API_TYPE_AUDIO_STREAM, stream_methods);
  register_type(L, API_TYPE_AUDIO_SOUND, sound_methods);
  register_type(L, API_TYPE_AUDIO_VOICE, voice_methods);
  luaL_newmetatable(L, AUDIO_ALLOCATION);
  lua_pushcfunction(L, allocation_gc); lua_setfield(L, -2, "__gc");
  lua_pop(L, 1);
  luaL_newlib(L, module_functions);
  lua_pushboolean(L, false); lua_pushcclosure(L, f_load_wav, 1); lua_setfield(L, -2, "load_wav");
  lua_pushboolean(L, true); lua_pushcclosure(L, f_load_wav, 1); lua_setfield(L, -2, "decode_wav");
  return 1;
}
