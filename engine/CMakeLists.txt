cmake_minimum_required(VERSION 3.16)
project(SoundboardEngine VERSION 0.2.0 LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(SBE_BUILD_TESTS "Build engine tests" ON)
option(SBE_BUILD_TOOLS "Build the offline routing prototype" ON)

add_library(sbe STATIC
    src/analysis.cpp
    src/capi.cpp
    src/deck.cpp
    src/engine.cpp
    src/wav.cpp
)
target_include_directories(sbe PUBLIC include PRIVATE src)
if(MSVC)
    target_compile_options(sbe PRIVATE /W4)
else()
    target_compile_options(sbe PRIVATE -Wall -Wextra -Wpedantic -Wno-unused-parameter)
endif()
find_package(Threads REQUIRED)
target_link_libraries(sbe PUBLIC Threads::Threads)

if(SBE_BUILD_TESTS)
    enable_testing()
    add_executable(sbe_tests tests/test_main.cpp)
    target_include_directories(sbe_tests PRIVATE src testing)
    target_link_libraries(sbe_tests PRIVATE sbe)
    add_test(NAME sbe_tests COMMAND sbe_tests)
endif()

if(SBE_BUILD_TOOLS)
    add_executable(sbe_routing_demo tools/routing_demo.cpp)
    target_include_directories(sbe_routing_demo PRIVATE src testing)
    target_link_libraries(sbe_routing_demo PRIVATE sbe)
endif()
