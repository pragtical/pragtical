project('sdl3_mixer', 'c', version: '3.2.4')

sdl_dep = dependency('sdl3', version: '>=3.4.0')
opusfile_dep = dependency('opusfile', static: true,
  fallback: ['opusfile', 'opusfile_dep'],
  default_options: ['default_library=static'])
mix_args = ['-DBUILD_SDL', '-DSDL_BUILD_MAJOR_VERSION=3',
  '-DSDL_BUILD_MINOR_VERSION=2', '-DSDL_BUILD_MICRO_VERSION=4',
  '-DDECODER_WAV', '-DDECODER_AIFF', '-DDECODER_AU', '-DDECODER_VOC',
  '-DDECODER_FLAC_DRFLAC', '-DDECODER_MP3_DRMP3',
  '-DDECODER_OGGVORBIS_STB', '-DDECODER_OPUS']
if get_option('default_library') == 'static'
  mix_args += '-DSDL_MIXER_STATIC_LIB'
endif
mix_lib = library('sdl3_mixer',
  ['src/SDL_mixer.c', 'src/SDL_mixer_metadata_tags.c',
   'src/SDL_mixer_spatialization.c', 'src/decoder_raw.c',
   'src/decoder_sinewave.c', 'src/decoder_wav.c', 'src/decoder_aiff.c',
   'src/decoder_au.c', 'src/decoder_voc.c', 'src/decoder_drflac.c',
   'src/decoder_drmp3.c', 'src/decoder_stb_vorbis.c', 'src/decoder_opus.c'],
  include_directories: ['include', 'src'],
  c_args: mix_args, dependencies: [sdl_dep, opusfile_dep]
)
sdl3_mixer_dep = declare_dependency(link_with: mix_lib,
  include_directories: 'include', dependencies: [sdl_dep, opusfile_dep],
  compile_args: get_option('default_library') == 'static' ? ['-DSDL_MIXER_STATIC_LIB'] : []
)
