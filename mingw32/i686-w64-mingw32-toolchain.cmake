# cmake toolchain for i686-w64-mingw32 (Windows XP).
#
# clang and lld only: no GCC, no binutils. The sysroot is the CRT package's
# install prefix, produced by i686-w64-mingw32-mingw-w64.
#
# CMAKE_SYSTEM_NAME stays Windows here, unlike the Android and mingw
# systems in this tree: this toolchain genuinely targets Windows, so cmake
# should know that, and none of the Android-specific workarounds apply.

set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86)

set(MINGW32_SYSROOT "$ENV{NATIVE_PREFIX}/i686-w64-mingw32" CACHE PATH "mingw-w64 CRT prefix")

set(CMAKE_C_COMPILER clang)
set(CMAKE_CXX_COMPILER clang++)
set(CMAKE_C_COMPILER_TARGET i686-w64-windows-gnu)
set(CMAKE_CXX_COMPILER_TARGET i686-w64-windows-gnu)

# --sysroot points at our own CRT; clang then finds the headers and import
# libraries there instead of any mingw installed on the build host.
add_compile_options(--sysroot=${MINGW32_SYSROOT})
add_link_options(--sysroot=${MINGW32_SYSROOT})

# XP is NT 5.1. 0x501 in the preprocessor gates the headers; 5.1 in the PE
# header is what makes the binary loadable on XP at all.
add_compile_definitions(_WIN32_WINNT=0x501 WINVER=0x501)

# lld is the PE linker. The subsystem version is 5.1 because that is XP;
# the separator is a colon, since a comma makes lld read "5.1" as a filename.
set(CMAKE_EXE_LINKER_FLAGS_INIT "-fuse-ld=lld -Wl,-subsystem,windows:5.1")

# Windows is case-insensitive and does not care about extensions.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
