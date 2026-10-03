require("raylib@source")

-- Android backend, for every Android system in the tree: they all declare
-- `recipe_fallbacks = {"android"}`, so one file covers aarch64/armv7a/i686/
-- x86_64 at any API level.
--
-- Two switches are genuinely platform facts and cannot live in the
-- system-neutral generic.lua:
--
-- -DPLATFORM=Android
--   raylib selects its platform backend from its own PLATFORM option, not
--   from cmake's ANDROID variable (cmake/LibraryConfigurations.cmake:77
--   keys the whole Android branch on `${PLATFORM} STREQUAL "Android"`).
--   That variable is independent of our toolchain files, so this is a
--   package-side choice, not a cmake-integration fix.
--
-- -DANDROID_NDK=$NDK
--   cmake/LibraryConfigurations.cmake:81 compiles the NDK's own
--   `$ANDROID_NDK/sources/android/native_app_glue/android_native_app_glue.c`
--   into the library, and line 82 adds that directory to the include path.
--   ANDROID_NDK is normally injected by the NDK's android.toolchain.cmake,
--   which our toolchain files deliberately do not use (CMAKE_SYSTEM_NAME
--   stays Linux to keep cmake out of its NDK integration). The system
--   recipes export NDK, so hand it the value cmake would have had.

return recipe({
    build = [[
        cp -r $NESTDIR/source/raylib/* .
        cmake -S . -B build $CMAKE_FLAGS \
            -DCMAKE_BUILD_TYPE=Release \
            -DPLATFORM=Android \
            -DANDROID_NDK="$NDK" \
            -DBUILD_EXAMPLES=OFF
        cmake --build build --parallel "$CORES"
        cmake --install build

        # raylib.pc's dependency lines are wrong for the Android backend on
        # every system, not an artifact of any one of them.
        # Requires.private: glfw3 comes from cmake/GlfwImport.cmake:20-22,
        # the branch reached when the platform is not Desktop/DRM: it sets
        # GLFW_PKG_DEPS "glfw3" while linking nothing. The Android build
        # compiles none of external/glfw (libraylib.a here defines 0 glfw
        # symbols) — rcore.c:549 selects rcore_android.c instead — so a
        # pkg-config consumer asks for a package that is not in the prefix
        # and not needed.
        # Libs.private is empty because LibraryConfigurations.cmake:94 puts
        # log android EGL GLESv2 OpenSLES atomic in LIBS_PRIVATE, which only
        # reaches target_link_libraries via $<BUILD_INTERFACE:...>
        # (src/CMakeLists.txt:99) and therefore never reaches the installed
        # .pc. A static consumer linking only what pkg-config reports gets
        # undefined glActiveTexture, __android_log_vprint and the rest.
        # LIBS_PUBLIC is m, which is already in $LDFLAGS on every Android
        # system, but the .pc is the consumer's own channel, so state it.
        # -Wl,--wrap=fopen is the third half: src/CMakeLists.txt:81 adds it
        # for Android so __wrap_fopen can serve APK assets, and it is a
        # PUBLIC link option of the target, so a CMake consumer inherits it
        # but a pkg-config consumer does not.
        # Verified link line (see stage3.md): aarch64-linux-android21-clang
        # main.o -lraylib -lm -llog -landroid -lEGL -lGLESv2 -lOpenSLES
        # -latomic -Wl,--wrap=fopen.
        #
        # This rewrites the .pc under $OUT, an artifact this build just
        # produced, not a file that came out of the upstream tree —
        # raylib.pc.in has no @variable@ carrying these libs, so cmake has
        # nothing to configure. Same rule, and the same reasoning, as the
        # loader's own $OUT to $PREFIX rewrite of .pc files.
        awk '
            /^Requires\.private: glfw3/ { print "Requires.private:"; next }
            /^Libs\.private:/ { print "Libs.private: -llog -landroid -lEGL -lGLESv2 -lOpenSLES -latomic -lm -Wl,--wrap=fopen"; next }
            { print }
        ' "$OUT/lib/pkgconfig/raylib.pc" > "$WORK/raylib.pc"
        cp "$WORK/raylib.pc" "$OUT/lib/pkgconfig/raylib.pc"

        # raylib-targets.cmake carries the same defect through the cmake
        # channel, from the same $<BUILD_INTERFACE:...> wrapper
        # (src/CMakeLists.txt:99): the imported target exports
        # INTERFACE_LINK_LIBRARIES "\$<LINK_ONLY:>;m" — the genex collapses
        # to nothing, so log/EGL/GLESv2/OpenSLES/android/atomic are dropped
        # and a find_package(raylib) consumer gets the same undefined
        # glDepthMask and __android_log_vprint as a pkg-config one.
        # INTERFACE_LINK_OPTIONS already carries -Wl,--wrap=fopen correctly
        # (it is a plain PUBLIC link option), so only the libraries need
        # adding, and they go inside the same $<LINK_ONLY:> the file already
        # uses for a static archive's private deps.
        # Measured before this fix, with the stock export:
        #   ld.lld: error: undefined symbol: glDepthMask
        #   >>> referenced by rcore.c
        #   >>>   rcore.c.o:(rlDisableBackfaceCulling) in archive .../libraylib.a
        awk '
            /^  INTERFACE_LINK_LIBRARIES / { print "  INTERFACE_LINK_LIBRARIES \"$<LINK_ONLY:log;android;EGL;GLESv2;OpenSLES;atomic>;m\""; next }
            { print }
        ' "$OUT/lib/cmake/raylib/raylib-targets.cmake" > "$WORK/raylib-targets.cmake"
        cp "$WORK/raylib-targets.cmake" "$OUT/lib/cmake/raylib/raylib-targets.cmake"
    ]]
})