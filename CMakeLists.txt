# Top-level build for the Browser M0 spike. Mirrors the structure of the CEF
# binary distribution's own root CMakeLists.txt ("Example 2": CEF distribution
# in a separate directory from the project), see
# third_party/cef/*/CMakeLists.txt for the upstream original this is adapted
# from.
cmake_minimum_required(VERSION 3.21)

set(CMAKE_CONFIGURATION_TYPES Debug Release)

# Swift is required alongside C/C++ for the mixed Swift/Objective-C++ app
# target in Sources/App. Deliberately NOT enabling OBJCXX as a distinct
# CMake language: left implicit, CMake compiles .mm files as C++ (with
# -x objective-c++) and reports their COMPILE_LANGUAGE as CXX, which is what
# lets CEF's own cef_macros.cmake (its $<COMPILE_LANGUAGE:CXX> generator
# expressions) apply correctly to .mm sources both here and inside
# libcef_dll_wrapper. Enabling OBJCXX explicitly would split .mm files into a
# separate language CMake's own macros don't expect, silently dropping CEF's
# required compiler flags (-std=c++20 among them) from every .mm file.
project(browser LANGUAGES C CXX Swift)

set_property(GLOBAL PROPERTY USE_FOLDERS ON)

# Locate the fetched CEF distribution. Versioned by directory name so this
# file doesn't need editing when scripts/fetch-cef.sh bumps the pin.
file(GLOB CEF_ROOT_CANDIDATES "${CMAKE_CURRENT_SOURCE_DIR}/third_party/cef/cef_binary_*")
list(LENGTH CEF_ROOT_CANDIDATES CEF_ROOT_CANDIDATES_COUNT)
if(CEF_ROOT_CANDIDATES_COUNT EQUAL 0)
  message(FATAL_ERROR "No CEF distribution found under third_party/cef/. Run scripts/fetch-cef.sh first.")
endif()
list(GET CEF_ROOT_CANDIDATES 0 CEF_ROOT)
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} "${CEF_ROOT}/cmake")

# Disable CEF's own (Chromium-internal) process sandbox. Unrelated to macOS
# App Sandbox, which this project must never enable (see AGENTS.md).
set(USE_SANDBOX OFF CACHE BOOL "" FORCE)

find_package(CEF REQUIRED)

# Defines the libcef_dll_wrapper target from the CEF distribution.
add_subdirectory(${CEF_LIBCEF_DLL_WRAPPER_PATH} libcef_dll_wrapper)

add_subdirectory(Sources/App)

PRINT_CEF_CONFIG()
