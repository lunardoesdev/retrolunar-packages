require("raylib@source")

-- Desktop fallback. The Android systems declare `recipe_fallbacks =
-- {"android"}`, so raylib/android.lua serves every one of them; this file
-- is the system-neutral fallback for the desktop targets and must carry no
-- Android-specific switch.
--
-- The NDK glue in LibraryConfigurations.cmake is keyed on the cmake
-- `ANDROID` variable, which our toolchain files deliberately never set
-- (CMAKE_SYSTEM_NAME stays Linux, see the toolchain .cmake next to each
-- system recipe), so raylib picks its backend from the project's own
-- PLATFORM option instead. Desktop is that option's default.

return recipe({
    build = [[
        cp -r $NESTDIR/source/raylib/* .
        cmake -S . -B build $CMAKE_FLAGS \
            -DCMAKE_BUILD_TYPE=Release \
            -DBUILD_EXAMPLES=OFF
        cmake --build build --parallel "$CORES"
        cmake --install build
    ]]
})