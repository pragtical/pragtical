#
# LUAJIT_FOUND
# LUAJIT_INCLUDE_DIRS
# LUAJIT_LIBRARIES

if (LUAJIT_FOUND)
  return()
endif()

if (NOT FORCE_FALLBACK)
  find_package(PkgConfig QUIET)
  if (PKG_CONFIG_FOUND)
      pkg_check_modules(_LUAJIT luajit QUIET)
  endif()

  find_path(LUAJIT_INC
      NAMES luajit.h
      HINTS
          ${_LUAJIT_INCLUDE_DIRS}
  )

  find_library(LUAJIT_LIB
      NAMES ${_LUAJIT_LIBRARIES} luajit
      HINTS
          ${_LUAJIT_LIBRARY_DIRS}
          ${_LUAJIT_STATIC_LIBRARY_DIRS}
  )

  include(FindPackageHandleStandardArgs)
  find_package_handle_standard_args(luajit DEFAULT_MSG LUAJIT_LIB LUAJIT_INC)
  mark_as_advanced(LUAJIT_INC LUAJIT_LIB)

  if(LUAJIT_FOUND)
      set(LUAJIT_INCLUDE_DIRS ${LUAJIT_INC})
      set(LUAJIT_LIBRARIES ${LUAJIT_LIB})
      return()
  endif()
endif()

if (NOT OFFLINE)
  find_program(MAKE_EXE "make" REQUIRED)

  set(BUILD_COMMAND
    "${MAKE_EXE}"
    "CFLAGS=-fPIC"
    "XCFLAGS=-DLUAJIT_ENABLE_LUA52COMPAT"
    "BUILDMODE=static"
  )

  set(luajit_PREFIX "${CMAKE_BINARY_DIR}/_deps/luajit")
  include(ExternalProject)
  ExternalProject_Add(luajit_src
      GIT_REPOSITORY https://github.com/LuaJIT/LuaJIT
      GIT_TAG 224129a8e64bfa219d35cd03055bf03952f167f6
      UPDATE_COMMAND ""
      PREFIX ${luajit_PREFIX}
      BUILD_IN_SOURCE 1
      CONFIGURE_COMMAND ""
      BUILD_COMMAND ${BUILD_COMMAND}
      INSTALL_COMMAND ""
  )

  ExternalProject_Get_property(luajit_src SOURCE_DIR)

  add_library(luajit STATIC IMPORTED GLOBAL)
  set_property(TARGET luajit
      PROPERTY IMPORTED_LOCATION
      "${SOURCE_DIR}/src/libluajit.a"
  )

  set(LUAJIT_INCLUDE_DIRS "${SOURCE_DIR}/src/")
  set(LUAJIT_LIBRARIES luajit)
  add_dependencies(luajit luajit_src)

  set(LUAJIT_FOUND 1)
  return()
endif()

if(NOT LUAJIT_FOUND)
  message(SEND_ERROR "Failed to find LuaJIT")
endif()
