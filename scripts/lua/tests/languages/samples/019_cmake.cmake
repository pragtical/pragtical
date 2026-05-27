cmake_minimum_required(VERSION 3.20)
project(Fixture LANGUAGES C CXX)

option(FIXTURE_WITH_TESTS "Build tests" ON)

add_library(fixture STATIC src/fixture.cpp)
target_include_directories(fixture PUBLIC include)
target_compile_features(fixture PUBLIC cxx_std_17)

if(FIXTURE_WITH_TESTS)
  add_executable(fixture_test tests/fixture_test.cpp)
  target_link_libraries(fixture_test PRIVATE fixture)
endif()
