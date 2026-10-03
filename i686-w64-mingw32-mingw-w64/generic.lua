require("i686-w64-mingw32-mingw-w64@source")

-- The mingw-w64 headers and C runtime for 32-bit Windows, built with clang
-- and lld instead of a GCC cross-compiler.
--
-- clang needs no binutils and no GCC to produce PE/COFF for
-- i686-w64-windows-gnu: that triple is built in. What it cannot supply is
-- the *runtime* — the CRT startup objects, the import libraries and the two
-- compiler-support objects GCC's toolchain would have provided — so those
-- are what this package builds.
--
-- Built for the native system (clang-native): a cross toolchain is a host
-- program. The mingw32 system requires it with @native, so these artifacts
-- land in $NESTDIR/clang-native/, whose bin/ the emitter puts first on PATH.
return recipe({
    build = [[
        cp -r $NESTDIR/source/i686-w64-mingw32-mingw-w64/* .
        # Timestamp guard: tarball/git mtimes otherwise let autoheader and
        # aclocal re-run against our autoconf, which is newer than the tree.
        # The template is config.h.in here (confirmed in the v14 tree).
        touch aclocal.m4 configure config.h.in
        find . -name 'Makefile.in' | xargs touch

        mkdir -p build
        cd build
        ../configure --host=i686-w64-mingw32 --build=$BUILD_TRIPLET \
            --prefix=$OUT/i686-w64-mingw32 --with-default-msvcrt=msvcrt \
            --without-libraries --without-tools \
            --enable-lib32 --disable-lib64 \
            CC="clang --target=i686-w64-windows-gnu" \
            CXX="clang++ --target=i686-w64-windows-gnu" \
            AR=llvm-ar RANLIB=llvm-ranlib \
            DLLTOOL=llvm-dlltool AS=clang
        make -j"$CORES"
        make -j"$CORES" install
        cd ..

        # Two objects upstream does not build, because upstream assumes GCC.
        #
        # 1. crt/crtbegin.c is an empty file: GCC normally ships crtbegin.o,
        #    which defines the global constructor/destructor lists. The CRT
        #    itself references them (crt/gccmain.c:12-13 declares
        #    __CTOR_LIST__/__DTOR_LIST__ and walks both at startup), so
        #    without this object every link fails on
        #    `undefined symbol: ___CTOR_LIST__`.
        #    Three leading underscores, not two: COFF decorates a leading
        #    underscore, so the C name __CTOR_LIST__ becomes ___CTOR_LIST__.
        cat > crtbegin-clang.c <<'EOF'
        __asm__(".section .ctors,\"aw\"\n"
                ".align 4\n"
                ".globl ___CTOR_LIST__\n"
                "___CTOR_LIST__:\n"
                ".long -1\n"
                ".long 0\n");
        __asm__(".section .dtors,\"aw\"\n"
                ".align 4\n"
                ".globl ___DTOR_LIST__\n"
                "___DTOR_LIST__:\n"
                ".long -1\n"
                ".long 0\n");
        EOF
        clang --target=i686-w64-windows-gnu -c crtbegin-clang.c -o crtbegin-clang.o
        llvm-ar r $OUT/i686-w64-mingw32/lib/libmingw32.a crtbegin-clang.o
        llvm-ranlib $OUT/i686-w64-mingw32/lib/libmingw32.a

        # 2. clang's x86 back end emits a relocation against __alloca for the
        #    stack probe in every function with a dynamic alloca; GCC's
        #    libgcc normally provides it. Confirmed with
        #    `llvm-readobj --relocations`: IMAGE_REL_I386_REL32 __alloca.
        #    Written in assembly so it needs no compiler runtime of its own.
        cat > alloca-clang.c <<'EOF'
        void *__alloca(unsigned size);
        __asm__(".text\n"
                ".globl __alloca\n"
                "__alloca:\n"
                "  movl 4(%esp), %eax\n"
                "  addl $15, %eax\n"
                "  andl $-16, %eax\n"
                "  subl %eax, %esp\n"
                "  movl %esp, %eax\n"
                "  ret\n");
        EOF
        clang --target=i686-w64-windows-gnu -c alloca-clang.c -o alloca-clang.o
        llvm-ar r $OUT/i686-w64-mingw32/lib/libmingwex.a alloca-clang.o
        llvm-ranlib $OUT/i686-w64-mingw32/lib/libmingwex.a

        # clang's mingw driver ends every link with -lgcc -lgcc_eh, the
        # names GCC's runtime libraries carry. It fails the link with
        # `unable to find library -lgcc` when they are absent, before it
        # looks at anything else, so their absence is a hard error rather
        # than something a recipe can work around.
        #
        # The copies carry the two objects compiled above, which is the
        # whole of what our toolchain needs from a libgcc: the constructor
        # and destructor lists, and the stack probe. They are copies rather
        # than empty archives on purpose — an empty -lgcc would satisfy the
        # driver and leave __alloca undefined at link time instead.
        cp $OUT/i686-w64-mingw32/lib/libmingw32.a $OUT/i686-w64-mingw32/lib/libgcc.a
        cp $OUT/i686-w64-mingw32/lib/libmingwex.a $OUT/i686-w64-mingw32/lib/libgcc_eh.a
    ]]
})
