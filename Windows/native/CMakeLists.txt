cmake_minimum_required(VERSION 3.24)
project(swcore C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# The same QuickJS-NG sources the Android app builds.
set(QJS ${CMAKE_CURRENT_SOURCE_DIR}/../../Android/core/src/main/cpp/quickjs)

# QuickJS on Windows computes the local-time offset of every date from the
# offset in force today. The copy built here asks swcore instead; the vendored
# source stays as upstream wrote it. The build stops if upstream changes the
# function, so the patch can be revisited.
file(READ ${QJS}/quickjs.c QUICKJS_SOURCE)
set(TZ_BEFORE "static int getTimezoneOffset(int64_t time) {\n#if defined(_WIN32)\n")
set(TZ_AFTER "int sw_timezone_offset(int64_t time);\nstatic int getTimezoneOffset(int64_t time) {\n#if defined(_WIN32)\n    return sw_timezone_offset(time);\n#elif defined(SW_UPSTREAM_WINDOWS_TIMEZONE)\n")
string(FIND "${QUICKJS_SOURCE}" "${TZ_BEFORE}" TZ_POSITION)
if(TZ_POSITION EQUAL -1)
    message(FATAL_ERROR "quickjs.c: getTimezoneOffset no longer matches the Windows time zone patch")
endif()
string(REPLACE "${TZ_BEFORE}" "${TZ_AFTER}" QUICKJS_SOURCE "${QUICKJS_SOURCE}")
file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/quickjs_windows.c "${QUICKJS_SOURCE}")

add_library(swcore SHARED
    swcore.c
    ${CMAKE_CURRENT_BINARY_DIR}/quickjs_windows.c
    ${QJS}/libregexp.c
    ${QJS}/libunicode.c
    ${QJS}/dtoa.c)

target_include_directories(swcore PRIVATE ${QJS})
target_compile_definitions(swcore PRIVATE _CRT_SECURE_NO_WARNINGS)

if(MSVC)
    # QuickJS uses C11 atomics, which MSVC still gates behind a switch.
    target_compile_options(swcore PRIVATE /experimental:c11atomics /W3 /wd4018 /wd4146 /wd4244 /wd4267 /wd4334 /wd4996 /wd4133 /wd4090 /wd4200)
    target_compile_options(swcore PRIVATE $<$<NOT:$<BOOL:${SW_ASAN}>>:/guard:cf>)
    target_link_options(swcore PRIVATE /DYNAMICBASE /NXCOMPAT $<$<NOT:$<BOOL:${SW_ASAN}>>:/guard:cf>)
    # A 64 MB script heap plus deep recursion: QuickJS checks its own stack
    # limit, so the DLL does not need a larger reserve.
    if(SW_ASAN)
        target_compile_options(swcore PRIVATE /fsanitize=address /Zi)
    endif()
endif()

target_link_libraries(swcore PRIVATE icu)

set_target_properties(swcore PROPERTIES PREFIX "" MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
