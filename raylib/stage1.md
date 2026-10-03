# raylib 6.0 — stage 1 build forecast

Source: `https://github.com/raysan5/raylib/archive/refs/tags/6.0.tar.gz`
(tag `6.0`, the newest release; `releases/latest` and the tag list agree, and
there is no 6.1 tag.)

## How the recipe splits

- `raylib/generic.lua` — the desktop fallback (`PLATFORM` defaults to
  `Desktop`). No Android switch.
- `raylib/android.lua` — every Android system, via the `recipe_fallbacks =
  {"android"}` all of them declare. Two switches, both platform facts:
  `-DPLATFORM=Android` and `-DANDROID_NDK="$NDK"`.

raylib has no autotools build: no `configure`, no `config.h.in`. It is CMake
only (`CMakeLists.txt`, `src/CMakeLists.txt`, `cmake/*.cmake`), so the
autotools timestamp guard does not apply. The generated `config.h` in `src/`
is a plain shipped file (`ParseConfigHeader.cmake` reads it), not a template.

## The two switches, with the lines that force them

`cmake/LibraryConfigurations.cmake:77-95` is the Android branch, and it is
keyed on raylib's own option, not on cmake's `ANDROID` variable:

- line 77: `elseif (${PLATFORM} STREQUAL "Android")` — so `PLATFORM=Android`
  is mandatory, and it is independent of our toolchain files.
- line 81: `list(APPEND raylib_sources ${ANDROID_NDK}/sources/android/native_app_glue/android_native_app_glue.c)`
- line 82: `include_directories(${ANDROID_NDK}/sources/android/native_app_glue)`
  — `ANDROID_NDK` is normally injected by the NDK's
  `android.toolchain.cmake`, which our toolchain files deliberately do not
  use (`set(CMAKE_SYSTEM_NAME Linux)`, see
  `aarch64-android21/aarch64-linux-android21-toolchain.cmake:3`). Our system
  recipes export `NDK`, so the recipe passes it.

Backend selection: `src/rcore.c:549-550` `#elif defined(PLATFORM_ANDROID)` →
`platforms/rcore_android.c`. `PLATFORM_ANDROID` is set as a PUBLIC compile
definition from `PLATFORM_CPP` (`cmake/LibraryConfigurations.cmake:78`,
`cmake/CompileDefinitions.cmake:3`), and `GRAPHICS` becomes
`GRAPHICS_API_OPENGL_ES2` (line 79).

GLFW: `cmake/GlfwImport.cmake` adds `external/glfw` only when the platform
matches `Desktop` (line 13). On Android it falls to the else branch
(line 20-22), which sets `GLFW_PKG_DEPS glfw3` and links nothing — see
"Predicted packaging defect" below.

## Per-system verdict

| system | verdict | basis |
| --- | --- | --- |
| `aarch64-android21` | WILL BUILD | cmake-only, no host programs, no configure/run step |
| `aarch64-android24` | WILL BUILD | same recipe; nothing API-dependent |
| `aarch64-android35` | WILL BUILD | same |
| `x86_64-android35` | WILL BUILD | same |
| `x86_64-mingw` | UNCERTAIN | desktop path needs `external/glfw`, which needs Win32 GDI headers from the host mingw-w64; not exercised in this wave |
| `clang-native` | WILL NOT BUILD | desktop path does `find_package(X11 REQUIRED)` (`src/CMakeLists.txt:123`) and no X11 dev package is claimed to be in the prefix |

### Android: why no host program ever runs

Every object is C, and `cmake/LibraryConfigurations.cmake:94` links only
NDK platform libraries (`log android EGL GLESv2 OpenSLES atomic c`). Nothing
in `raylib_sources` or the NDK glue spawns a host executable, and the NDK's
`native_app_glue.c` is pure C. `BUILD_EXAMPLES=OFF` is what keeps the
examples out — upstream defaults `BUILD_EXAMPLES` to `${PROJECT_IS_TOP_LEVEL}`
(`CMakeOptions.txt:22`), and every example is a target program that must
never be run.

## The removed-NDK-API claim: it does not hold

AGENTS.md listed "raylib uses removed NDK APIs" as a known wall. The only
candidate in the whole tree is miniaudio's `__system_property_get`
(`src/external/miniaudio.h:12163`, under `#ifdef MA_ANDROID`). Checked
against the sysroot rather than assumed — `sys/system_properties.h` exists in
the NDK r28 sysroot, and the symbol is exported by libc at every API level on
all four ABIs:

```
$ llvm-nm -D --defined-only $NDK/sysroot/usr/lib/<triple>/<api>/libc.so | grep '__system_property_get@@'
aarch64-linux-android: 21:yes 24:yes 28:yes 30:yes 35:yes
arm-linux-androideabi: 21:yes 24:yes 28:yes 30:yes 35:yes
x86_64-linux-android:  21:yes 24:yes 28:yes 30:yes 35:yes
i686-linux-android:    21:yes 24:yes 28:yes 30:yes 35:yes
```

The `@@LIBC` version suffix is why a plain `grep '__system_property_get$'`
reports nothing; that is a property of the grep, not of the sysroot.

## Predicted packaging defect (confirmed in stage 3)

`LIBS_PRIVATE` (line 94: `log android EGL GLESv2 OpenSLES atomic c`) reaches
the target only through `$<BUILD_INTERFACE:${LIBS_PRIVATE}>`
(`src/CMakeLists.txt:99`), so it never reaches either consumer channel:

- `raylib.pc.in:9` gets `Libs.private: @PKG_CONFIG_LIBS_PRIVATE@`, which is
  filled from `GLFW_PKG_LIBS` (`cmake/InstallConfigurations.cmake:6-9`) —
  unset on Android, so the line is empty.
- `raylib.pc.in:10` gets `Requires.private: @GLFW_PKG_DEPS@` = `glfw3`
  (`cmake/GlfwImport.cmake:22`) — a package that is neither in the prefix nor
  compiled in on Android.
- the exported target's `INTERFACE_LINK_LIBRARIES` collapses to
  `"$<LINK_ONLY:>;m"`.

So a static consumer, through either channel, gets undefined
`glActiveTexture`, `__android_log_vprint` and the rest. The recipe repairs
both generated files under `$OUT`.