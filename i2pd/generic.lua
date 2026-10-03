require("i2pd@source")
require("openssl")
require("zlib")
require("boost")

return recipe({
    build = [[
        cp -r $NESTDIR/source/i2pd/* .

        # The cmake project is the build/ SUBDIRECTORY, not the tree root:
        # build/CMakeLists.txt:1 is the only CMakeLists.txt in the release and
        # there is no configure script and no Makefile.in anywhere. The binary
        # directory is named cmakebuild so it cannot collide with the source
        # directory build/ that -S points at.
        cmake -S build -B cmakebuild $CMAKE_FLAGS \
            -DWITH_UPNP=OFF \
            -DWITH_GIT_VERSION=OFF \
            -DBUILD_TESTING=OFF
        cmake --build cmakebuild --parallel "$CORES"
        # cmake --install lays down bin/i2pd and the three archives and nothing
        # else: build/CMakeLists.txt has exactly four install() rules, at :74,
        # :87, :100 and :411. No headers, no .pc, no CMake package config.
        cmake --install cmakebuild

        # A daemon reads its config, its tunnel definitions and its certificates
        # at RUN time, and none of that is in the cmake install. Upstream's own
        # Unix install rule is Makefile.linux:56-72; it is reproduced here
        # rather than run, because (a) it is a Makefile target in a cmake
        # project, and (b) `install -m 644` is not in the recipe hygiene list.
        mkdir -p $OUT/etc/i2pd/tunnels.conf.d
        cp contrib/i2pd.conf contrib/subscriptions.txt contrib/tunnels.conf $OUT/etc/i2pd/
        mkdir -p $OUT/share/doc/i2pd
        cp ChangeLog LICENSE README.md contrib/i2pd.conf contrib/subscriptions.txt contrib/tunnels.conf $OUT/share/doc/i2pd/
        # 22 .crt files in two subdirectories: contrib/certificates/family (6)
        # and contrib/certificates/reseed (16).
        mkdir -p $OUT/share/i2pd
        cp -r contrib/certificates $OUT/share/i2pd/
        # Shipped uncompressed; upstream gzips it first (Makefile.linux:66) and
        # `gzip` is not in the recipe hygiene list.
        mkdir -p $OUT/share/man/man1
        cp debian/i2pd.1 $OUT/share/man/man1/
        # The three archives libi2pd/libi2pdclient/libi2pdlang are installed
        # with no headers anywhere, which makes them unusable to a consumer;
        # upstream's cmake build does not do this, Arch's package() does. The
        # headers are all at the top level of i18n/, libi2pd/ and
        # libi2pd_client/ and are flattened here: no header uses a "../"
        # include, none includes <libi2pd/...>, and all 68 basenames are
        # distinct, so one directory resolves every quoted include.
        mkdir -p $OUT/include/i2pd
        cp i18n/*.h libi2pd/*.h libi2pd_client/*.h $OUT/include/i2pd/
        # The data directory a daemon is pointed at with --datadir. Upstream
        # Makefile.linux:68-72 fills it with symlinks into ${PREFIX}; they are
        # copies here instead, so the staging dir holds ordinary files and
        # nothing depends on the final prefix name or on symlink survival
        # through the loader's `cp -rf` merge. tunnels.d is an empty directory
        # upstream (Makefile.linux:59 creates etc/i2pd/tunnels.conf.d empty),
        # so it is just created.
        mkdir -p $OUT/var/lib/i2pd/tunnels.d
        cp -r contrib/certificates $OUT/var/lib/i2pd/
        cp contrib/i2pd.conf contrib/subscriptions.txt contrib/tunnels.conf $OUT/var/lib/i2pd/
    ]]
})
