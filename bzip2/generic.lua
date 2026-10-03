require("bzip2@source")

return recipe({
    build = [[
        cp -r $NESTDIR/source/bzip2/* .
        # Build the target utilities directly; the default target runs tests.
        make -j"$CORES" CC="$CC" AR="$AR" RANLIB="$RANLIB" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" bzip2 bzip2recover

        # The Windows driver appends .exe to whatever -o names (upstream
        # Makefile:41 and :44 say `-o bzip2`), so the two link steps above
        # produce bzip2.exe and bzip2recover.exe. The install target then
        # hardcodes the bare names — `cp -f bzip2 $(PREFIX)/bin/bzip2` at
        # :77-80 — and this Makefile has no EXEEXT variable at all, so there
        # is nothing to set: the install dies with "cannot stat 'bzip2'".
        #
        # Upstream ships no configure here either, so EXEEXT cannot be
        # injected the way it normally would be. Copying the two files onto
        # the names the install rule looks for keeps `make install` as the
        # single source of truth for what gets installed; reimplementing its
        # ~30 lines in the recipe would let the two drift apart.
        cp bzip2.exe bzip2
        cp bzip2recover.exe bzip2recover

        make -j"$CORES" CC="$CC" AR="$AR" RANLIB="$RANLIB" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" PREFIX="$OUT" install
    ]]
})
