# This file is a part of media_kit (https://github.com/media-kit/media-kit).
#
# Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
# All rights reserved.
# Use of this source code is governed by MIT license that can be found in the LICENSE file.

cmake_minimum_required(VERSION 3.14)

# This option is read by the other packages which are part of package:media_kit.
option(MEDIA_KIT_LIBS_AVAILABLE "package:media_kit libraries are available." ON)

set(PROJECT_NAME "media_kit_libs_windows_video")
project(${PROJECT_NAME} LANGUAGES CXX)

# Deal with MSVC incompatiblity
add_compile_definitions(_DISABLE_CONSTEXPR_MUTEX_CONSTRUCTOR)

# ------------------------------------------------------------------------------
function(download_and_verify url sha256 fallback_url fallback_sha256 locationForArchive)
  set(_source "")
  set(_primary_configured TRUE)
  # A placeholder hash means the custom archive has not been published yet: skip the primary
  # download entirely (a guaranteed-failing network round trip) and use the fallback directly.
  if(sha256 MATCHES "^REPLACE_WITH_")
    set(_primary_configured FALSE)
    message(STATUS "Primary archive not configured yet (placeholder SHA256); using fallback archive directly.")
  endif()

  # Reuse an already downloaded archive when its SHA256 matches either candidate.
  if(EXISTS "${locationForArchive}")
    file(SHA256 "${locationForArchive}" ARCHIVE_SHA256)
    if(_primary_configured AND sha256 STREQUAL ARCHIVE_SHA256)
      set(_source "primary")
    elseif(fallback_sha256 STREQUAL ARCHIVE_SHA256)
      set(_source "fallback")
    else()
      file(REMOVE "${locationForArchive}")
      message(STATUS "SHA256 mismatch. File deleted.")
    endif()
  endif()

  # Attempt the primary (custom) archive first.
  if(_source STREQUAL "" AND _primary_configured)
    message(STATUS "Downloading archive from ${url}...")
    file(DOWNLOAD "${url}" "${locationForArchive}" STATUS _download_status)
    if(EXISTS "${locationForArchive}")
      file(SHA256 "${locationForArchive}" ARCHIVE_SHA256)
    else()
      set(ARCHIVE_SHA256 "")
    endif()
    if(sha256 STREQUAL ARCHIVE_SHA256)
      set(_source "primary")
      message(STATUS "${locationForArchive} Verification successful.")
    else()
      message(STATUS "Primary archive unavailable or failed verification (${_download_status}); trying fallback.")
      file(REMOVE "${locationForArchive}")
    endif()
  endif()

  # Fall back to the upstream archive; identical structure, just without the extra filters.
  if(_source STREQUAL "")
    message(STATUS "Downloading fallback archive from ${fallback_url}...")
    file(DOWNLOAD "${fallback_url}" "${locationForArchive}" STATUS _download_status)
    if(EXISTS "${locationForArchive}")
      file(SHA256 "${locationForArchive}" ARCHIVE_SHA256)
    else()
      set(ARCHIVE_SHA256 "")
    endif()
    if(fallback_sha256 STREQUAL ARCHIVE_SHA256)
      set(_source "fallback")
      message(STATUS "${locationForArchive} Verification successful (fallback).")
    else()
      message(FATAL_ERROR "Failed to obtain a valid libmpv archive (primary: ${url}; fallback: ${fallback_url}).")
    endif()
  endif()

  message(STATUS "libmpv archive resolved from: ${_source}")
endfunction()

function(check_directory_exists_and_not_empty dir result_var)
  # Check if the directory exists
  if(EXISTS "${dir}")
    # Check if the directory is not empty
    file(GLOB dir_contents "${dir}/*")

    if(dir_contents)
      set(${result_var} TRUE PARENT_SCOPE)
    else()
      set(${result_var} FALSE PARENT_SCOPE)
      message(STATUS "Directory ${dir} exists but is empty!")
    endif()
  else()
    set(${result_var} FALSE PARENT_SCOPE)
    message(STATUS "Directory ${dir} does not exist!")
  endif()
endfunction()

# libmpv archive containing the pre-built shared libraries & headers.
string(TOLOWER "${CMAKE_SYSTEM_PROCESSOR}" LIBMPV_TARGET_PROCESSOR)
string(TOLOWER "${CMAKE_GENERATOR_PLATFORM}" LIBMPV_GENERATOR_PLATFORM)

if(LIBMPV_TARGET_PROCESSOR MATCHES "^(arm64|aarch64)$" OR LIBMPV_GENERATOR_PLATFORM MATCHES "^(arm64|aarch64)$")
  set(LIBMPV "mpv-dev-aarch64-20260915-git-0b7ed67.zip")
  set(LIBMPV_SHA256 "2adb3eb11a7985699203ee94b6182088e0e0bc8be492cd4adf184411dbf6a31d")
  set(LIBMPV_URL "https://github.com/Predidit/libmpv-win32-video-cmake/releases/download/202609151348/${LIBMPV}")
  # arm64 keeps the upstream archive only; volume normalization is unavailable there and
  # the app probes libmpv capability at runtime, greying the switch out automatically.
  set(LIBMPV_FALLBACK_URL "${LIBMPV_URL}")
  set(LIBMPV_FALLBACK_SHA256 "${LIBMPV_SHA256}")
else()
  # x86_64: custom libmpv built from Predidit/libmpv-win32-video-cmake@fdf75129 with
  # loudnorm/dynaudnorm/speechnorm enabled (see .github/workflows/build-libmpv-custom.yml).
  # NOTE: LIBMPV_SHA256 must be backfilled with the hash printed by that workflow's Summary
  # after the first successful build; until then the fallback archive is used automatically.
  set(LIBMPV "mpv-dev-x86_64-slive-custom.7z")
  set(LIBMPV_SHA256 "47514de4cc6a3bf875370fe044920a85c25edf225d5bb535d928814e75b929e8")
  set(LIBMPV_URL "https://github.com/Howezzzzz/dart_simple_live/releases/download/libmpv-custom-v1/${LIBMPV}")
  set(LIBMPV_FALLBACK_URL "https://github.com/Predidit/libmpv-win32-video-cmake/releases/download/202609151348/mpv-dev-x86_64-20260915-git-0b7ed67.7z")
  set(LIBMPV_FALLBACK_SHA256 "8adceab30b6bcc5503fa9d3823b68f4acd15ee1c41d6dc2492826f373531c10a")
endif()

# Download location of the libmpv archive.
set(LIBMPV_ARCHIVE "${CMAKE_BINARY_DIR}/${LIBMPV}")
set(LIBMPV_SRC "${CMAKE_BINARY_DIR}/libmpv")

download_and_verify(
  ${LIBMPV_URL}
  ${LIBMPV_SHA256}
  ${LIBMPV_FALLBACK_URL}
  ${LIBMPV_FALLBACK_SHA256}
  ${LIBMPV_ARCHIVE}
)

check_directory_exists_and_not_empty(${LIBMPV_SRC} LIBMPV_SRC_VALID)

# Extract the libmpv archive.
if(NOT LIBMPV_SRC_VALID)
  message(STATUS "Extracting ${LIBMPV}...")
  make_directory("${LIBMPV_SRC}")
  add_custom_target("${PROJECT_NAME}_LIBMPV_EXTRACT" ALL)
  add_custom_command(
    TARGET "${PROJECT_NAME}_LIBMPV_EXTRACT"
    COMMAND "${CMAKE_COMMAND}" -E tar xzf "\"${LIBMPV_ARCHIVE}\""
    COMMAND xcopy "\"${LIBMPV_SRC}/include/mpv\"" "\"${LIBMPV_SRC}/mpv\"" /E /H /C /I
    COMMAND rmdir "\"${LIBMPV_SRC}/include\"" /S /Q
    COMMAND ren "\"${LIBMPV_SRC}/mpv\"" "\"include\""
    WORKING_DIRECTORY "${LIBMPV_SRC}"
  )
endif()

# ------------------------------------------------------------------------------
set(PLUGIN_NAME "media_kit_libs_windows_video_plugin")

add_library(
  ${PLUGIN_NAME} SHARED
  "include/media_kit_libs_windows_video/media_kit_libs_windows_video_plugin_c_api.h"
  "media_kit_libs_windows_video_plugin_c_api.cpp"
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(
  ${PLUGIN_NAME}
  PROPERTIES
  CXX_VISIBILITY_PRESET
  hidden
)
target_compile_definitions(
  ${PLUGIN_NAME}
  PRIVATE
  FLUTTER_PLUGIN_IMPL
)

target_include_directories(
  ${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)
target_link_libraries(
  ${PLUGIN_NAME}
  PRIVATE
  flutter
  flutter_wrapper_plugin
)

set(
  media_kit_libs_windows_video_bundled_libraries
  "${LIBMPV_SRC}/libmpv-2.dll"
  PARENT_SCOPE
)
