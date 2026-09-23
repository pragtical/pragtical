# Pragtical SDL3_mixer Build

This Meson overlay builds SDL3_mixer 3.2.4 with WAV, AIFF, AU, VOC, FLAC,
MP3, Vorbis, and Opus decoding. The first seven use SDL_mixer's included
decoders; Opus uses static opusfile, Opus, and Ogg dependencies. HTTP input,
MIDI, tracker modules, and compressed encoding are not enabled.

The parent build accepts system SDL3_mixer 3.2.4 or newer, using the SDL3_mixer
or sdl3-mixer dependency name. Standard Meson wrap options control the fallback,
as with SDL_image. To test the installed library with the system SDL3:

```sh
meson setup build-system-mixer --wrap-mode=default -Dppm=false
meson compile -C build-system-mixer
./scripts/run-local -global build-system-mixer
```

Use `--wrap-mode=nofallback` to require system dependencies where fallbacks are
available, or `--wrap-mode=forcefallback` to build the bundled static dependencies.
To force only this mixer subproject while keeping system SDL3 and other libraries,
use `--wrap-mode=default --force-fallback-for=sdl3_mixer`.

The default fallback uses unmodified upstream SDL_mixer sources plus this Meson
build overlay. System builds also use the installed library without applying our
patch; decoder availability depends on that library's configuration.

## Optional Playback Patch

`sdl3_mixer-playback.patch` is retained but disabled by default to follow upstream.
For the pinned 3.2.4 release it is needed for the stricter offline-generation
behavior checked by the exact/stress suites. It includes these changes:

- Use input-frame alignment when supplying tracks, avoiding an endless
  one-frame mono loop on a stereo mixer.
- Supply resampler lookahead for small pulls, flush final output, and defer
  completion until that output drains. Paused tracks retain buffered output.
- Clear converted output when seeking, so playback does not reuse old samples.
- Track offline output progress across buffers and rate changes, instead of
  reporting the last callback's pre-resampling byte count.
- Preserve reported decoder failures in a private track property for deferred
  Lua notifications, and guard working-buffer multiplication overflow.

Without the patch, ordinary file playback and game audio work in the tested
workloads, but the following limitations remain:

- Resampled offline output counts can be inaccurate or exceed the requested
  frame count when changing mixer rate. Do not use those counts to trim output.
- Small requests can fail, converted tails can differ, and changing chunk size
  need not produce identical output. These are not just rounding differences.
- A one-frame mono sound looped into a stereo mixer can hang the native mixer.
- Mid-stream decoder errors may be reported as normal completion.

The Pragtical wrapper initializes offline output to format-correct silence before
mixing so upstream short writes cannot expose uninitialized memory to Lua. This
does not repair the upstream count or resampling behavior.

To opt in, uncomment `diff_files = sdl3_mixer-playback.patch` in
`subprojects/sdl3_mixer.wrap`, then configure a fallback build. If the source is
already extracted, first preserve any local changes and move
`subprojects/SDL3_mixer-3.2.4` out of the source tree so Meson can extract it again.
Reconfigure and rebuild after either enabling or disabling the patch: editing
the wrap alone does not undo changes in an already extracted source directory.
This has no effect when linking a system SDL_mixer library.

The patch's 16-frame lookahead depends on SDL3's resampling window. Recheck the
patch when upgrading either library. A build with the patch enabled is an altered
SDL_mixer build; license notices are included in licenses/licenses.md.

## Tests

The normal audio suite uses 512, 1024, and 4096-frame render chunks and a 100 ms
sound for device cleanup/looping. It retains count, padding, and signal checks
without rate conversion, plus approximate signal duration with combined rate
controls. Generated resampling comparisons allow up to 0.5 ms at the signal
boundaries. The normal suite does not require accurate rate-scaled mixer counts
or equivalence between differently chunked resampled output.

```sh
SDL_VIDEO_DRIVER=dummy SDL_AUDIO_DRIVER=dummy \
  ./scripts/run-local build test scripts/lua/tests/audio.lua
```

Set `PRAGTICAL_AUDIO_EXACT=1` for the stricter rate-scaled frame-count and
resampled chunk-equivalence checks. Set `PRAGTICAL_AUDIO_STRESS=1` for four-frame
rendering and one-frame mono-to-stereo looping. Each opt-in suite is reported as
skipped unless enabled. They are intended for the optional patched build or for
checking future upstream fixes, not for gating default upstream-based builds.

Use an external timeout for stress tests on unpatched libraries, because a native
mixing loop cannot be interrupted by Lua. For example, on systems with GNU
timeout, after building with the optional patch:

```sh
timeout --kill-after=3 60 env PRAGTICAL_AUDIO_EXACT=1 PRAGTICAL_AUDIO_STRESS=1 \
  SDL_VIDEO_DRIVER=dummy SDL_AUDIO_DRIVER=dummy \
  ./scripts/run-local build test scripts/lua/tests/audio.lua
```

Replace `build` with `build-system-mixer` to test the installed library. A passing
default run establishes compatibility with the ordinary tested workloads, not
sample-exact offline generation or absence of upstream edge-case bugs.
