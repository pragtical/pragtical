find_package(SDL2 REQUIRED)
find_package(Freetype REQUIRED)
if(JIT)
find_package(luajit REQUIRED)
add_subdirectory(compat)
else()
find_package(lua REQUIRED)
endif()

add_subdirectory(api)

list(APPEND
    LITE_SOURCES
    ${CMAKE_CURRENT_SOURCE_DIR}/main.c
    ${CMAKE_CURRENT_SOURCE_DIR}/rencache.c
    ${CMAKE_CURRENT_SOURCE_DIR}/rencache.h
    ${CMAKE_CURRENT_SOURCE_DIR}/renderer.c
    ${CMAKE_CURRENT_SOURCE_DIR}/renderer.h
    ${CMAKE_CURRENT_SOURCE_DIR}/renwindow.c
    ${CMAKE_CURRENT_SOURCE_DIR}/renwindow.h
    ${CMAKE_CURRENT_SOURCE_DIR}/unidata.h
    ${CMAKE_CURRENT_SOURCE_DIR}/utfconv.h
)

if(WIN32)
    list(APPEND
        LITE_SOURCES
        ${CMAKE_SOURCE_DIR}/resources/icons/icon.rc
        ${CMAKE_SOURCE_DIR}/resources/windows/manifest.rc
    )
elseif(APPLE)
    list(APPEND
        LITE_SOURCES
        ${CMAKE_CURRENT_SOURCE_DIR}/bundle_open.m
    )
endif()

add_executable(pragtical WIN32 ${LITE_SOURCES})
target_link_libraries(pragtical PUBLIC api)
target_link_libraries(pragtical PUBLIC dirmonitor)

target_include_directories(pragtical PUBLIC ${SDL2_INCLUDE_DIRS})
target_link_libraries(pragtical PUBLIC ${SDL2_LIBRARIES})
target_include_directories(pragtical PUBLIC ${FREETYPE_INCLUDE_DIRS})
target_link_libraries(pragtical PUBLIC ${FREETYPE_LIBRARIES})
if(JIT)
target_include_directories(pragtical PUBLIC ${LUAJIT_INCLUDE_DIRS})
target_link_libraries(pragtical PUBLIC ${LUAJIT_LIBRARIES})
target_link_libraries(pragtical PUBLIC compat)
else()
target_include_directories(pragtical PUBLIC ${LUA_INCLUDE_DIRS})
target_link_libraries(pragtical PUBLIC ${LUA_LIBRARIES})
endif()
if (APPLE)
  target_link_libraries(pragtical PUBLIC "-framework CoreServices")
  target_link_libraries(pragtical PUBLIC "-framework Foundation")
endif()

target_link_libraries(pragtical PUBLIC m)

install(TARGETS pragtical)
file(CREATE_LINK ${CMAKE_SOURCE_DIR}/data ${CMAKE_BINARY_DIR}/data SYMBOLIC)
