return recipe({
    version = "14.0.0",
    git = "https://github.com/mingw-w64/mingw-w64",
    tag = "v14.0.0",
    build = [[
        # git, not a tarball: the v14.0.0 release publishes no source
        # archive. The GitHub releases API for this tag carries an empty
        # asset list and
        #   .../releases/download/v14.0.0/mingw-w64-v14.0.0.tar.xz
        # answers 404, so a tarball recipe would fail on a URL that looks
        # right. The tree we need is small at this depth and the build never
        # reads history.
        if [ ! -d src ]; then
          git clone --depth=1 --branch "$tag" "$git" src
        fi
        mkdir -p $OUT/i686-w64-mingw32-mingw-w64
        cp -r src/* $OUT/i686-w64-mingw32-mingw-w64/
    ]]
})
