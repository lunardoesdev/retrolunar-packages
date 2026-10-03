require("zlib")
require("binutils@source")

return recipe({
    build = [[
        cp -r $NESTDIR/source/binutils/* .
        # Use the staged Zlib package and build the default BFD linker.
        ./configure $AUTOCONF_CONFIGURE_FLAGS \
            --enable-ld=default \
            --enable-plugins \
            --enable-shared \
            --disable-werror \
            --enable-64-bit-bfd \
            --enable-new-dtags \
            --with-system-zlib \
            --enable-default-hash-style=gnu
        touch aclocal.m4 configure config.h.in
        find . -name 'Makefile.in' | xargs touch
        make -j"$CORES" tooldir="$OUT"
        make -j"$CORES" tooldir="$OUT" install
    ]]
})
