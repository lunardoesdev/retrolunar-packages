require("m4@source")

return recipe({
    build = [[
        cp -r $NESTDIR/source/m4/* .
        ./configure $AUTOCONF_CONFIGURE_FLAGS
        touch aclocal.m4 configure lib/config.hin
        find . -name 'Makefile.in' | xargs touch
        make -j"$CORES" -C lib
        make -j"$CORES" -C src
        make -j"$CORES" .version
        make -j"$CORES" -C doc version.texi
        # Keep the shipped man page; regenerating it would execute the
        # Android m4 binary on the build host.
        touch doc/m4.1
        make -j"$CORES"
        make install
    ]]
})
