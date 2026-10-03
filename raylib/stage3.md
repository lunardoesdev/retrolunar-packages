# raylib 6.0 — stage 3 build record

Systems built: **`aarch64-android21`, `armv7a-android21`, `x86_64-android21`,
`i686-android21`** — the four ABIs, at the lowest API level in the tree, which
is the widest device coverage the tree can express.

## Outcome: **SUCCESS on all four ABIs**, after fixing a real packaging defect

## Command sequence

```sh
cd /home/si/ond/git/retrolunar-packages
export ANDROID_HOME=/home/si/.local/share/mise/installs/android-sdk/23.0
export CORES=8
for s in aarch64-android21 armv7a-android21 x86_64-android21 i686-android21; do
  rm -f nest/$s/.retrolunar-raylib          # invalidate the stamp first
  retrolunar install --nest ./nest --packages . "raylib@$s" > nest/tmp/rl/b-$s.sh
  sh -n nest/tmp/rl/b-$s.sh                 # exit 0
  flock rl-build.lock sh nest/tmp/rl/b-$s.sh
done
```

The stamps were deleted before every build, so no `skip` can be mistaken for
work. `nest/source/raylib` was left in place: the version and URL did not
change between the two rounds, and the first round's `@source` block was the
one that fetched it.

## Real work in the log

The NDK glue is compiled into the library, which is the proof that
`-DANDROID_NDK` reached cmake — without it, `raylib_sources` would name a
nonexistent path and the build would fail:

```
[ 12%] Building C object raylib/CMakeFiles/raylib.dir/raudio.c.o
[ 25%] Building C object raylib/CMakeFiles/raylib.dir/rcore.c.o
[ 37%] Building C object raylib/CMakeFiles/raylib.dir/rmodels.c.o
[ 50%] Building C object raylib/CMakeFiles/raylib.dir/rshapes.c.o
[ 62%] Building C object raylib/CMakeFiles/raylib.dir/rtext.c.o
[ 75%] Building C object raylib/CMakeFiles/raylib.dir/rtextures.c.o
[ 87%] Building C object raylib/CMakeFiles/raylib.dir/home/si/.local/share/mise/installs/android-sdk/23.0/ndk/28.2.13676358/sources/android/native_app_glue/android_native_app_glue.c.o
[100%] Linking C static library libraylib.a
[100%] Built target raylib
```

And the two switches taking effect, from the configure step:

```
-- Using external GLFW
-- Audio Backend: miniaudio
-- Building raylib static library
-- Generated build type: Release
-- Compiling with the flags:
--   PLATFORM=PLATFORM_ANDROID
--   GRAPHICS=GRAPHICS_API_OPENGL_ES2
```

`PLATFORM=PLATFORM_ANDROID` and `GRAPHICS_API_OPENGL_ES2` are set from the
project's own `PLATFORM` option at `cmake/LibraryConfigurations.cmake:78-79`,
so this line is the direct confirmation that `-DPLATFORM=Android` was
honoured and the NDK backend was selected.

No target binary was run. Every step is compile, archive or install. The
examples were not built (`BUILD_EXAMPLES=OFF`), so `bin/` is empty in all four
prefixes — checked with `find nest/<sys>/bin -type f | wc -l`, which is
**0** on all four.

## DEFECT found and fixed: neither consumer channel could link

This is the substantive finding of this wave, and it was invisible to the
build itself — a static archive is not linked, and both `.pc` files and
`raylib-targets.cmake` are text files only a consumer ever reads.

**Root cause, one line:** `src/CMakeLists.txt:99`

```cmake
target_link_libraries(raylib PRIVATE $<BUILD_INTERFACE:${LIBS_PRIVATE}>)
```

`$<BUILD_INTERFACE:...>` is only expanded when the target is consumed *inside*
the same build tree. `cmake/LibraryConfigurations.cmake:94` sets

```cmake
set(LIBS_PRIVATE log android EGL GLESv2 OpenSLES atomic c)
```

and the genex throws it away on install. `LIBS_PUBLIC` (`m`) is the only
thing that survives, because line 100 has no genex.

### Symptom 1 — `raylib.pc` demands glfw3 and names no libraries

The installed `.pc`, before the fix, in full:

```
Libs: -L"${libdir}" -lraylib 
Libs.private: 
Requires.private: glfw3
```

`Requires.private: glfw3` is factually wrong for Android:
`cmake/GlfwImport.cmake:13` compiles `external/glfw` only when the platform
matches `Desktop`, so on Android control reaches line 20-22, which sets
`GLFW_PKG_DEPS glfw3` and links nothing. Measured, not assumed:

```
$ llvm-nm --defined-only nest/aarch64-android21/lib/libraylib.a | grep -c glfw
0
$ llvm-nm --defined-only nest/aarch64-android21/lib/libraylib.a | grep -c ' T '
1994
$ llvm-nm --defined-only nest/aarch64-android21/lib/libraylib.a | grep 'T InitWindow'
                 0000000000000000 T InitWindow
```

1994 defined symbols and zero of them glfw. The archive is the Android
backend, as `src/rcore.c:549-550` says it should be.

And `pkg-config` on the prefix as installed **fails outright**:

```
$ PKG_CONFIG_LIBDIR=nest/aarch64-android21/lib/pkgconfig pkg-config --modversion raylib
Package glfw3 was not found in the pkg-config search path.
Perhaps you should add the directory containing 'glfw3.pc'
to the PKG_CONFIG_PATH environment variable
Package 'glfw3', required by 'raylib', not found
```

exit 1. The package was unusable through pkg-config, not merely incomplete.

### Symptom 2 — a consumer linking only what the `.pc` reports fails

Throwaway consumer, four lines (`nest/tmp/rl/probe/main.c`, deleted after
this record was written): `#include "raylib.h"`, `InitWindow(64,64,"p")`,
`CloseWindow()`, `return 0`. Flags came from `pkg-config --static --cflags
--libs raylib` and nothing was added by hand:

```
$ .../aarch64-linux-android21-clang main.o -L.../lib -lraylib -lm -o app1
undefined symbol: __android_log_vprint
undefined symbol: glActiveTexture
undefined symbol: glBindBuffer
undefined symbol: glBindFramebuffer
undefined symbol: glBindTexture
undefined symbol: glBufferSubData
undefined symbol: glDepthMask
undefined symbol: glDisable
undefined symbol: glDrawArrays
undefined symbol: glDrawElements
undefined symbol: glEnable
undefined symbol: glEnableVertexAttribArray
undefined symbol: glTexParameterf
undefined symbol: glTexParameteri
undefined symbol: glUniform1i
undefined symbol: glUniform4f
undefined symbol: glUniformMatrix4fv
undefined symbol: glUseProgram
undefined symbol: glVertexAttribPointer
undefined symbol: glViewport
```

### Symptom 3 — the same through `find_package`

The exported target carries the identical gap:

```
$ grep INTERFACE_LINK_LIBRARIES nest/aarch64-android21/lib/cmake/raylib/raylib-targets.cmake
  INTERFACE_LINK_LIBRARIES "\$<LINK_ONLY:>;m"
```

The empty slot between `<LINK_ONLY:>` and `;m` is the collapsed genex. A
`find_package(raylib)` consumer (`CMakeLists.txt`: `find_package(raylib
CONFIG REQUIRED)` + `target_link_libraries(app raylib)`):

```
ld.lld: error: undefined symbol: glDepthMask
>>> referenced by rcore.c
>>>               rcore.c.o:(rlDisableBackfaceCulling) in archive .../nest/aarch64-android21/lib/libraylib.a
>>> referenced 4 more times
ld.lld: error: too many errors emitted, stopping now
```

Note `find_package(raylib CONFIG)` is required, not plain `find_package(raylib)`:
the installed file is `raylib-config.cmake` (`cmake/InstallConfigurations.cmake:44-50`),
and cmake's default search looks for `raylibConfig.cmake` first and only then
for the `-config.cmake` spelling in CONFIG mode. Plain module mode does not
find it at all. That is upstream naming, not a recipe defect; recorded so the
next reader does not re-diagnose it.

### The fix, and its scope

`raylib/android.lua` rewrites two files, both **generated artifacts under
`$OUT`**, with `awk` + `cp`:

- `$OUT/lib/pkgconfig/raylib.pc` — `Requires.private: glfw3` becomes an empty
  `Requires.private:`, and `Libs.private:` gets
  `-llog -landroid -lEGL -lGLESv2 -lOpenSLES -latomic -lm -Wl,--wrap=fopen`.
- `$OUT/lib/cmake/raylib/raylib-targets.cmake` — `INTERFACE_LINK_LIBRARIES`
  becomes `"$<LINK_ONLY:log;android;EGL;GLESv2;OpenSLES;atomic>;m"`.

`-Wl,--wrap=fopen` belongs in both: `src/CMakeLists.txt:78-82` adds it for
Android so `__wrap_fopen` can serve APK assets. The cmake channel already had
it (it is a plain PUBLIC link option, so it exports as
`INTERFACE_LINK_OPTIONS "-Wl,--wrap=fopen"`); the pkg-config channel did not,
and without it the link fails on `__wrap_fopen` — confirmed before the fix:

```
>>> referenced by rcore.c
>>>               rcore.c.o:(__wrap_fopen) in archive .../libraylib.a
clang: error: linker command failed with exit code 1
```

This is inside AGENTS.md's permitted scope: a generated file under `$OUT`,
never `$WORK` and never the unpacked upstream tree. There is no `sed`, no
patch, and no edit to anything that came out of upstream. `raylib.pc.in` has
no `@variable@` carrying these libraries, so no cmake option reaches them and
there is no alternative to a post-install rewrite — the same situation, and
the same remedy, as `glog/generic.lua`'s `libglog.pc` `Cflags` line.

## Verification after the fix

### pkg-config, all four ABIs, consumer linked from the `.pc` alone

```
aarch64  pkg-config-only link: OK  AArch64
armv7a   pkg-config-only link: OK  ARM
x86_64   pkg-config-only link: OK  Advanced Micro Devices X86-64
i686     pkg-config-only link: OK  Intel 80386
```

What pkg-config reports, for aarch64:

```
$ PKG_CONFIG_LIBDIR=.../aarch64-android21/lib/pkgconfig pkg-config --static --cflags --libs raylib
-I.../include -L.../lib -lraylib -llog -landroid -lEGL -lGLESv2 -lOpenSLES -latomic -lm -Wl,--wrap=fopen
$ PKG_CONFIG_LIBDIR=.../aarch64-android21/lib/pkgconfig pkg-config --modversion raylib
6.0.0
```

### find_package, aarch64

```
$ cmake --build b --parallel 8
find_package(raylib CONFIG) CONSUMER: BUILD OK
b/app: ELF 64-bit LSB pie executable, ARM aarch64, ... for Android 21, built by NDK r28c
$ llvm-readelf -d b/app | grep NEEDED
  (NEEDED) Shared library: [liblog.so]
  (NEEDED) Shared library: [libandroid.so]
  (NEEDED) Shared library: [libEGL.so]
  (NEEDED) Shared library: [libGLESv2.so]
  (NEEDED) Shared library: [libOpenSLES.so]
  (NEEDED) Shared library: [libm.so]
  (NEEDED) Shared library: [libdl.so]
  (NEEDED) Shared library: [libc.so]
```

Eight NEEDED entries, every one of them an NDK platform library. Nothing from
this prefix leaks into the consumer, which is what a static archive with
correctly-recorded private deps should produce.

### Artifact table — expected values stated so a reader can compare

| expectation | command | aarch64 | armv7a | x86_64 | i686 |
| --- | --- | --- | --- | --- | --- |
| `Machine:` matches the ABI | `llvm-readelf -h lib/libraylib.a` | `AArch64` | `ARM` | `Advanced Micro Devices X86-64` | `Intel 80386` |
| exactly 1 `libraylib*` in `lib/` | `ls lib \| grep -c '^libraylib'` | 1 | 1 | 1 | 1 |
| exactly 4 installed headers | `ls include \| grep -c -E '^(raylib\|rlgl\|raymath\|rcamera)\.h$'` | 4 | 4 | 4 | 4 |
| **0** glfw symbols | `llvm-nm --defined-only lib/libraylib.a \| grep -c glfw` | 0 | 0 | 0 | 0 |
| pkg-config version | `pkg-config --modversion raylib` | 6.0.0 | 6.0.0 | 6.0.0 | 6.0.0 |
| **0** files in `bin/` | `find bin -type f \| wc -l` | 0 | 0 | 0 | 0 |

Header list is `raylib.h rcamera.h rlgl.h raymath.h` — the four of
`raylib_public_headers` at `src/CMakeLists.txt:24-29`. The archive sizes
differ per ABI (2520422 / 2404194 / 2871902 / 2379066 bytes) because the
software rasterizer's tables and the x86 SIMD paths differ; that is expected,
not a defect.

The counts above are scoped to raylib-owned filename prefixes or exact header
names. Nothing here counts a directory several packages share — `include/` and
`lib/pkgconfig` do in this prefix, so a bare `ls | wc -l` on either would be
meaningless.

### Rerun proves the stamps are real

```
aarch64-android21  skip raylib@source (fresh) skip raylib@aarch64-android21 (fresh)
armv7a-android21   skip raylib@source (fresh) skip raylib@armv7a-android21 (fresh)
x86_64-android21   skip raylib@source (fresh) skip raylib@x86_64-android21 (fresh)
i686-android21     skip raylib@source (fresh) skip raylib@i686-android21 (fresh)
```

Read after the stamps were deleted and the packages rebuilt — so the `skip`
means the recipe that produced the current artifacts is the one on disk.

## AGENTS.md's "raylib uses removed NDK APIs" does not reproduce — corrected

AGENTS.md listed this as a known platform wall. The only candidate in the
whole tree is miniaudio's `__system_property_get`
(`src/external/miniaudio.h:12163`, inside `#ifdef MA_ANDROID`), and it is
present at every API level on every ABI. Measured against the sysroot, not
assumed:

```
$ llvm-nm -D --defined-only $NDK/sysroot/usr/lib/<triple>/<api>/libc.so | grep -q '__system_property_get@@'
aarch64-linux-android: 21:yes 24:yes 28:yes 30:yes 35:yes
arm-linux-androideabi: 21:yes 24:yes 28:yes 30:yes 35:yes
x86_64-linux-android:  21:yes 24:yes 28:yes 30:yes 35:yes
i686-linux-android:    21:yes 24:yes 28:yes 30:yes 35:yes
```

`sys/system_properties.h` is in the r28 sysroot as well. A note on method,
because it nearly produced a false negative here: grepping for
`'__system_property_get$'` reports **nothing**, because Bionic's versioned
symbols carry an `@@LIBC` suffix in the stub `.so`. The absence of a match
there is a property of the grep pattern. The archive does reference the
symbol — `llvm-nm -u` shows `U __system_property_get` — and it resolves.

`AGENTS.md` has been updated: the wall entry is replaced with what is actually
true, and the real raylib problem (the packaging defect above) is named there
so the next agent looks for it instead of the API.

## System-level finding (recorded, not worked around)

None. Unlike glog and abseil, raylib's private deps reach consumers correctly
once stated in the `.pc` and the exported target, and the Android systems'
`-llog` in `LDFLAGS` covers the build-system path. No system file needs a
change for this package.

## Not covered by this wave

- **The desktop path (`generic.lua`) is untested.** `clang-native` and
  `x86_64-mingw` were not built. `src/CMakeLists.txt:123` does
  `find_package(X11 REQUIRED)` for a non-Apple `Desktop` build with bundled
  GLFW, so `clang-native` will need X11 headers in the prefix or
  `-DGLFW_BUILD_X11=OFF`; that has not been measured and is not claimed here.
- **API levels above 21 were not built.** The recipe is system-neutral
  between them and the only API-sensitive symbol in the tree is
  API-independent, so the forecast is WILL BUILD, but it is unverified.