require("bzip2@source")

return recipe({
    build = [[
        cp -r $NESTDIR/source/bzip2/* .
        # Build the target utilities directly; the default target runs tests.
        make -j"$CORES" CC="$CC" AR="$AR" RANLIB="$RANLIB" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" bzip2 bzip2recover
        make -j"$CORES" CC="$CC" AR="$AR" RANLIB="$RANLIB" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" PREFIX="$OUT" install
    ]]
})
