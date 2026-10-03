-- i686-w64-mingw32: 32-bit Windows, via the host's mingw-w64 i686 tools.
--
-- The 64-bit sibling is x86_64-mingw, and this is the same recipe with the
-- i686-* tool names: tools come from PATH, there is no sysroot and no NDK
-- discovery, and cmake/meson files live next to this recipe.
--
-- What differs from x86_64-mingw is only the architecture: the triplet, the
-- host arch, and the prefix on every tool name. The PE subsystem version is
-- left at the linker's default rather than pinned — this system targets
-- 32-bit Windows, not a particular version of it.
return system({
    setup = [[
        # --- toolchain: mingw-w64 i686 gcc + binutils ---
        CC="i686-w64-mingw32-gcc"
        CXX="i686-w64-mingw32-g++"
        AR="i686-w64-mingw32-ar"
        RANLIB="i686-w64-mingw32-ranlib"
        LD="i686-w64-mingw32-ld"
        STRIP="i686-w64-mingw32-strip"
        OBJCOPY="i686-w64-mingw32-objcopy"
        READELF="i686-w64-mingw32-readelf"
        NM="i686-w64-mingw32-nm"
        OBJDUMP="i686-w64-mingw32-objdump"
        WINDRES="i686-w64-mingw32-windres"
        export CC CXX AR RANLIB LD STRIP OBJCOPY READELF NM OBJDUMP WINDRES

        # --- search paths: our prefix only, no sysroot ---
        # CPPFLAGS covers the autoconf probes ($CC -E without $CFLAGS).
        CPPFLAGS="-I$PREFIX/include"
        export CPPFLAGS
        CFLAGS="-O2"
        CFLAGS="$CFLAGS -I$PREFIX/include"
        CXXFLAGS="$CFLAGS"
        export CFLAGS CXXFLAGS
        LDFLAGS="-L$PREFIX/lib"
        export LDFLAGS
        # Look up .pc files in our prefix, ignore host ones.
        PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
        PKG_CONFIG_LIBDIR="$PKG_CONFIG_LIBDIR:$PREFIX/share/pkgconfig"
        PKG_CONFIG_PATH=""
        export PKG_CONFIG_LIBDIR PKG_CONFIG_PATH

        # --- machine identities: build, host, target ---
        # build = the machine that runs the build; host = the machine the
        # artifacts run on (autoconf's --host). FFmpeg-family configure
        # scripts are not autoconf and reject --host/--build, so they read
        # $HOST_ARCH/$HOST_OS and spell them their own way. Nothing here
        # builds a compiler for a further machine: target == host.
        BUILD_TRIPLET="x86_64-pc-linux-gnu"
        HOST_TRIPLET="i686-w64-mingw32"
        TARGET_TRIPLET="$HOST_TRIPLET"
        HOST_ARCH="i686"
        HOST_OS="mingw32"
        export BUILD_TRIPLET HOST_TRIPLET TARGET_TRIPLET HOST_ARCH HOST_OS

        # --- build-system defaults: install into $OUT, find in $PREFIX ---
        AUTOCONF_CONFIGURE_FLAGS="--host=$HOST_TRIPLET --build=$BUILD_TRIPLET"
        AUTOCONF_CONFIGURE_FLAGS="$AUTOCONF_CONFIGURE_FLAGS --prefix=$OUT"
        export AUTOCONF_CONFIGURE_FLAGS
        CMAKE_TOOLCHAIN_FILE="$SYSDIR/i686-w64-mingw32-toolchain.cmake"
        CMAKE_PREFIX_PATH="$PREFIX"
        CMAKE_FLAGS="-DCMAKE_TOOLCHAIN_FILE=$CMAKE_TOOLCHAIN_FILE"
        CMAKE_FLAGS="$CMAKE_FLAGS -DCMAKE_INSTALL_PREFIX=$OUT"
        CMAKE_FLAGS="$CMAKE_FLAGS -DCMAKE_PREFIX_PATH=$PREFIX"
        # cmake's compiler check links a test program and then runs it. A
        # cross target binary cannot run here, and running one would be
        # emulation, which we never do: link a static library instead.
        CMAKE_FLAGS="$CMAKE_FLAGS -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY"
        # cmake 4.x refuses any project whose minimum policy is below 3.5,
        # and most of these projects are older than cmake itself.
        CMAKE_FLAGS="$CMAKE_FLAGS -DCMAKE_POLICY_VERSION_MINIMUM=3.5"
        # cmake picks the make program out of $PREFIX, where bin/make is a
        # target binary that would need an emulator to run. Pin the host's.
        CMAKE_MAKE_PROGRAM="$(command -v make)"
        CMAKE_FLAGS="$CMAKE_FLAGS -DCMAKE_MAKE_PROGRAM=$CMAKE_MAKE_PROGRAM"
        # FindZLIB.cmake searches this first, and projects read it directly.
        # Left unset it expands to the literal /lib, the HOST's library
        # directory, which silently resolves target -l flags to host
        # archives.
        CMAKE_FLAGS="$CMAKE_FLAGS -DZLIB_ROOT=$PREFIX"
        export CMAKE_TOOLCHAIN_FILE CMAKE_PREFIX_PATH CMAKE_FLAGS
        MESON_CROSS_FILE="$SYSDIR/crossfile-i686-w64-mingw32.ini"
        MESON_FLAGS="--prefix=$OUT"
        MESON_FLAGS="$MESON_FLAGS --cross-file $MESON_CROSS_FILE"
        export MESON_CROSS_FILE MESON_FLAGS

        # --- build parallelism ---
        # How many jobs a build may use. Takes the value from the
        # environment so retrolunar can export CORES itself; falls back to 1.
        # MAKEFLAGS is what carries the count into a bare `make` and into its
        # recursive submakes.
        CORES="${CORES:-1}"
        MAKEFLAGS="-j$CORES"
        export CORES MAKEFLAGS
    ]],
})
