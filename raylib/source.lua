return recipe({
    version = "6.0",
    build = [[
        mkdir -p dl
        if [ ! -f dl/raylib-6.0.tar.gz ]; then
          curl -fSL -C - -o dl/raylib-6.0.tar.gz \
            "https://github.com/raysan5/raylib/archive/refs/tags/6.0.tar.gz"
        fi
        rm -rf src
        mkdir -p src
        tar -xzf dl/raylib-6.0.tar.gz -C src --strip-components=1
        mkdir -p $OUT/raylib
        cp -r src/* $OUT/raylib/
    ]]
})