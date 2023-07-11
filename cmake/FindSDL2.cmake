#
# SDL2_FOUND
# SDL2_INCLUDE_DIRS
# SDL2_LIBRARIES
if (SDL2_FOUND)
  return()
endif()

if (NOT FORCE_FALLBACK)
  # SDL2 only ships with a cmake config when its build using cmake
  find_package(SDL2 CONFIG)

  if (SDL2_FOUND)
    # We found the SDL2 config
    set(SDL2_LIBRARIES SDL2::SDL2)
    set(SDL2_INCLUDE_DIRS) # includes are propagated by the SDL2 target
    return()
  endif()


  # Fallback onto pkg-config
  find_package(PkgConfig QUIET)
  if (PKG_CONFIG_FOUND)
      pkg_check_modules(_SDL2 sdl2 QUIET)
  endif()

  find_path(SDL2_INC
      NAMES SDL.h
      HINTS
          ${_SDL2_INCLUDE_DIRS}
      PATH_SUFFIXES
        SDL2
  )

  find_library(SDL2_LIB
      NAMES ${_SDL2_LIBRARIES} SDL2
      HINTS
          ${_SDL2_LIBRARY_DIRS}
          ${_SDL2_STATIC_LIBRARY_DIRS}
  )

  include(FindPackageHandleStandardArgs)
  #find_package_handle_standard_args(SDL2 DEFAULT_MSG SDL2_LIB SDL2_INC)
  mark_as_advanced(SDL2_INC SDL2_LIB)

  if(SDL2_FOUND)
      set(SDL2_INCLUDE_DIRS ${SDL2_INC})
      set(SDL2_LIBRARIES ${SDL2_LIB})
      return()
  endif()
endif()

# Last Restort, download
if (NOT OFFLINE)
  include(FetchContent)

  message(STATUS "Downloading SDL2...")
  FetchContent_Declare(
    sdl2
    GIT_REPOSITORY https://github.com/libsdl-org/SDL
    GIT_TAG        ac13ca9ab691e13e8eebe9684740ddcb0d716203 # 2.26.5
  )

  FetchContent_MakeAvailable(sdl2)

  set(SDL2_LIBRARIES SDL2-static)
  set(SDL2_INCLUDE_DIRS)
  set(SDL2_FOUND 1)
endif()

if(NOT SDL2_FOUND)
  message(SEND_ERROR "Failed to find SDL2")
endif()
