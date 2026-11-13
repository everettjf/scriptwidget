cmake_minimum_required(VERSION 3.22.1)
project(scriptwidget C)

set(CMAKE_C_STANDARD 11)
set(QJS quickjs)

add_library(scriptwidget SHARED
    scriptwidget_jni.c
    ${QJS}/quickjs.c
    ${QJS}/libregexp.c
    ${QJS}/libunicode.c
    ${QJS}/dtoa.c)

target_compile_definitions(scriptwidget PRIVATE _GNU_SOURCE)
target_compile_options(scriptwidget PRIVATE -O2 -fvisibility=hidden -Wno-unused-parameter -Wno-sign-compare -Wno-implicit-fallthrough)
target_link_options(scriptwidget PRIVATE -Wl,-z,max-page-size=16384)
target_link_libraries(scriptwidget m)
