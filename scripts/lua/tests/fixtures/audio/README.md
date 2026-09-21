# Audio Fixtures

These are generated 440 Hz sine tones, not third-party music. Each contains
0.1 seconds of mono audio at 48 kHz and title/artist metadata.

Generate with FFmpeg (substitute the matching codec and extension):

```sh
ffmpeg -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=0.1' \
  -c:a flac -metadata title='Pragtical audio test' -metadata artist=Pragtical tone.flac
```

The other codec/extension pairs are `libmp3lame`/`mp3`, `libvorbis`/`ogg`,
and `libopus`/`opus`. FFmpeg is not needed to run the tests.
