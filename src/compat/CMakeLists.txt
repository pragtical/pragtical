find_package(luajit REQUIRED)

list(APPEND
  COMPAT_SOURCE
  ${CMAKE_CURRENT_SOURCE_DIR}/lbitlib.c
  ${CMAKE_CURRENT_SOURCE_DIR}/lstrlib.c
  ${CMAKE_CURRENT_SOURCE_DIR}/ltablib.c
  ${CMAKE_CURRENT_SOURCE_DIR}/lutf8lib.c
)

add_library(compat OBJECT ${COMPAT_SOURCE})
target_include_directories(compat PUBLIC ${LUAJIT_INCLUDE_DIRS})
target_link_libraries(compat PUBLIC ${LUAJIT_LIBRARIES})
