-- i686-w64-mingw32: 32-bit Windows XP, via clang + lld and a mingw-w64 CRT
-- we build ourselves (i686-w64-mingw32-mingw-w64, required below).
--
-- There is no GCC and no binutils here. clang knows the
-- i686-w64-windows-gnu triple natively, lld-link links PE/COFF, and
-- llvm-dlltool builds the import libraries. What clang cannot supply is the
-- runtime, which is why the system requires the CRT package rather than
-- assuming one on PATH.
--
-- "Windows XP" is the load-bearing constraint, not just "32-bit Windows".
-- XP is NT 5.1 and it constrains four separate things, each of which is a
-- silent failure rather than an error if left alone:
--
--   * The C runtime must be msvcrt. mingw-w64 defaults to UCRT
--     (mingw-w64-crt/configure.ac:256-266), which needs Vista or later. The
--     CRT package passes --with-default-msvcrt=msvcrt, which resolves to
--     the msvcrt-os import library.
--   * _WIN32_WINNT defaults to 0xa00 (Windows 10) in the headers
--     (mingw-w64-headers/configure.ac:127-135). Every gated declaration is
--     therefore visible whether XP has it or not, so a build compiles clean
--     and the binary dies on load with an unresolved import. Pinned to 0x501.
--   * The PE subsystem version must be 5.1. A newer value is a hard load
--     failure on XP, and nothing warns about it at build time.
--   * SafeSEH did not exist on XP. lld refuses to link msvcrt.dll under
--     /safeseh and says so, which is the correct answer for this target.
require("i686-w64-mingw32-mingw-w64@native")

return system({
    setup = [[
        # --- toolchain: clang targeting win32 + lld ---
        # The triple is what makes clang emit PE/COFF; the sysroot points at
        # the CRT package's install prefix, so headers and import libraries
        # come from our own build and never from a host mingw.
        # $NESTDIR, not $NATIVE_PREFIX: the emitter defines NATIVE_PREFIX
        # AFTER this fragment runs, so referencing it here is an unbound
        # variable under `set -u`. $NESTDIR is exported before the setup
        # fragment and holds the same path; the CRT package installs into
        # the default system's prefix, which is the first entry the emitter
        # puts on PATH.
        SYSROOT="$NESTDIR/clang-native/i686-w64-mingw32"
        CLANG_TARGET="--target=i686-w64-windows-gnu --sysroot=$SYSROOT"
        CC="clang $CLANG_TARGET"
        CXX="clang++ $CLANG_TARGET"
        # lld-link is the PE linker. It is named as a full path because the
        # recipes call it directly through $LD, and a bare `lld-link` would
        # be ambiguous with any other lld on PATH.
        LD="lld-link"
        AR="llvm-ar"
        RANLIB="llvm-ranlib"
        STRIP="llvm-strip"
        OBJDUMP="llvm-objdump"
        READELF="llvm-readobj"
        NM="llvm-nm"
        RC="llvm-rc"
        # llvm-rc runs the C preprocessor over the .rc file, and it does not
        # read $CPPFLAGS: it finds headers only through the preprocessor's
        # own search path. Without CPATH, any project with a .rc file that
        # includes <windows.h> dies at the first RC step with
        # `llvm-rc: Preprocessing failed` — after a successful C compile,
        # which makes it look like a resource-compiler problem rather than a
        # missing include path.
        CPATH="$SYSROOT/include"

        export CPATH
        export SYSROOT CLANG_TARGET LD AR RANLIB STRIP OBJDUMP READELF NM RC
        export CC CXX

        # --- XP target version ---
        # 0x501 is Windows XP. Set for the compiler AND the preprocessor,
        # because the headers are gated on the preprocessor macro: with
        # _WIN32_WINNT left at its 0xa00 default the headers declare
        # interfaces XP does not have, and the failure is an unresolved
        # import at load time on the target, not a build error here.
        XP_WINNT="0x501"
        CPPFLAGS="-D_WIN32_WINNT=$XP_WINNT -DWINVER=$XP_WINNT"
        CPPFLAGS="$CPPFLAGS -I$SYSROOT/include"
        export XP_WINNT CPPFLAGS
        # The same version as a major.minor pair for the PE subsystem
        # field, which is a different encoding from _WIN32_WINNT: 0x501 is
        # the preprocessor macro, 5.1 is the PE header. Both mean XP.
        XP_WINNT_MM="5.1"
        export XP_WINNT_MM
        CFLAGS="-O2"
        CFLAGS="$CFLAGS $CPPFLAGS"
        CXXFLAGS="$CFLAGS"
        export CFLAGS CXXFLAGS

        # --- link flags ---
        # The subsystem version is 5.1 because that is XP, and it is not
        # optional: linked without this, lld writes 6.0, and a binary
        # carrying a subsystem version newer than the OS simply fails to
        # load there. Nothing warns at build time.
        #
        # The separator is a COLON: `-subsystem,windows,5.1` is read as
        # three separate arguments and lld tries to open a file named 5.1.
        # `-subsystem,windows:5.1` is the GNU driver's spelling and produces
        # MajorSubsystemVersion 5 / MinorSubsystemVersion 1.
        #
        # There is deliberately no -safeseh flag. SafeSEH postdates XP, but
        # the GNU driver has no spelling lld accepts (`-safeseh:no`,
        # `--safeseh:no`, `-fno-safeseh` are each rejected), and the driver
        # path does not enable SafeSEH on its own — a binary linked this way
        # carries no SafeSEH load config, which is the correct state for XP.
        # Only a direct lld-link invocation needs -safeseh:no, and no recipe
        # in this tree calls $LD directly.
        LDFLAGS="-fuse-ld=lld -Wl,-subsystem,windows:$XP_WINNT_MM"
        LDFLAGS="$LDFLAGS -L$SYSROOT/lib"
        export LDFLAGS

        # --- look up .pc files in our prefix only, ignore host ones ---
        PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
        PKG_CONFIG_LIBDIR="$PKG_CONFIG_LIBDIR:$PREFIX/share/pkgconfig"
        PKG_CONFIG_PATH=""
        export PKG_CONFIG_LIBDIR PKG_CONFIG_PATH

        # --- machine identities: build, host, target ---
        # build = the machine that runs the build; host = the machine the
        # artifacts run on (autoconf's --host). Nothing here builds a
        # compiler for a further machine, so target == host.
        BUILD_TRIPLET="x86_64-pc-linux-gnu"
        HOST_TRIPLET="i686-w64-mingw32"
        TARGET_TRIPLET="$HOST_TRIPLET"
        HOST_ARCH="i686"
        HOST_OS="mingw32"
        export BUILD_TRIPLET HOST_TRIPLET TARGET_TRIPLET HOST_ARCH HOST_OS

        # --- build-system defaults: install into $OUT ---
        AUTOCONF_CONFIGURE_FLAGS="--host=$HOST_TRIPLET --build=$BUILD_TRIPLET"
        AUTOCONF_CONFIGURE_FLAGS="$AUTOCONF_CONFIGURE_FLAGS --prefix=$OUT"
        export AUTOCONF_CONFIGURE_FLAGS
        CMAKE_TOOLCHAIN_FILE="$SYSDIR/i686-w64-mingw32-toolchain.cmake"
        CMAKE_PREFIX_PATH="$PREFIX"
        CMAKE_FLAGS="-DCMAKE_TOOLCHAIN_FILE=$CMAKE_TOOLCHAIN_FILE"
        CMAKE_FLAGS="$CMAKE_FLAGS -DCMAKE_INSTALL_PREFIX=$OUT"
        CMAKE_FLAGS="$CMAKE_FLAGS -DCMAKE_PREFIX_PATH=$PREFIX"
        # cmake's compiler check links a test program and then runs it, which
        # a target binary cannot do here, and running one would be emulation,
        # which we never do. Link a static library instead.
        CMAKE_FLAGS="$CMAKE_FLAGS -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY"
        # cmake 4.x refuses any project whose minimum policy is below 3.5,
        # and most of these projects are older than cmake itself.
        CMAKE_FLAGS="$CMAKE_FLAGS -DCMAKE_POLICY_VERSION_MINIMUM=3.5"
        # cmake would otherwise find $PREFIX/bin/make, a target binary.
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
