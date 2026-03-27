cmake_minimum_required(VERSION 3.22.1)

project("shelf_stitcher")

# ── C++17 ────────────────────────────────────────────────────────────────────
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# ── Locate OpenCV Android SDK (optional — app still works without it) ─────────
if(DEFINED OPENCV_SDK_PATH AND NOT OPENCV_SDK_PATH STREQUAL "")
    set(OpenCV_DIR "${OPENCV_SDK_PATH}/sdk/native/jni")
    find_package(OpenCV QUIET)
endif()

if(OpenCV_FOUND)
    message(STATUS "OpenCV ${OpenCV_VERSION} found — building native stitcher")
    message(STATUS "OpenCV include dirs: ${OpenCV_INCLUDE_DIRS}")
    message(STATUS "OpenCV libs: ${OpenCV_LIBS}")

    find_library(log-lib log)
    find_library(android-lib android)

    add_library(
        shelf_stitcher
        SHARED
        src/main/cpp/stitcher.cpp
    )

    target_include_directories(
        shelf_stitcher
        PRIVATE
        ${OpenCV_INCLUDE_DIRS}
    )

    target_link_libraries(
        shelf_stitcher
        ${OpenCV_LIBS}
        ${android-lib}
        ${log-lib}
    )
else()
    message(STATUS
        "OpenCV SDK not found — skipping native stitcher.\n"
        "Run setup_opencv_android.bat and rebuild to enable the NDK pipeline.")

    # Provide a stub library so the .so reference in NativeStitcher.kt
    # is simply absent at runtime (triggers the try/catch → isAvailable=false).
    # No sources needed — the library just won't be packaged.
endif()
