require("gmp")
require("mpfr@source")

return recipe({
    build = [[
        cp -r $NESTDIR/source/mpfr/* .
        ./configure $AUTOCONF_CONFIGURE_FLAGS \
            --disable-static \
            --enable-thread-safe \
            --docdir="$OUT/share/doc/mpfr-4.2.2"
touch aclocal.m4 configure
        find . -name 'Makefile.in' | xargs touch
        make -j"$CORES"
        make -j"$CORES" install
        make -j"$CORES" install-html
    ]]
})
