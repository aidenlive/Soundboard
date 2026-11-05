cmake_minimum_required(VERSION 3.22.1)
project(soundboard_android CXX)

set(SBE_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(SBE_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
# The shared engine, compiled from the same sources as iOS/macOS.
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../engine ${CMAKE_CURRENT_BINARY_DIR}/sbe)

find_package(oboe REQUIRED CONFIG)

add_library(soundboard SHARED oboe_host.cpp)
target_compile_options(soundboard PRIVATE -O3 -Wall)
target_link_libraries(soundboard PRIVATE sbe oboe::oboe log)
