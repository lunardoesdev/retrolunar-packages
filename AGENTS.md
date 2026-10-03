# AGENTS.md — retrolunar packages

This file is for coding agents working in this repo. This repo holds only the
package and system recipes: one directory per package or system, at the repo
root, with no `packages/` prefix. The `retrolunar` tool itself (loader, C
binary, Lua interpreter) lives outside this repo; use the system-installed
`retrolunar` binary and point it at this tree with `--packages .`.

## What this is

`retrolunar` is a tiny C binary with an embedded Lua 5.5 interpreter. At
startup it runs its Lua loader, which overrides global `require`. The
`install` subcommand prints a POSIX shell script that builds everything, and
`--packages` selects the recipe tree — this repo.

Typical flow, run from this repo:

```sh
retrolunar install --nest ./nest --packages . 'pngprobe@aarch64-android24' > build.sh
sh -n build.sh
ANDROID_HOME=/path/to/sdk sh build.sh
```

If `retrolunar` is not on `PATH`, ask the user where the binary is rather
than searching the filesystem or building one. Nothing in this repo
compiles the tool itself.

## Design principle

Keep recipes, system definitions, and generated build scripts clear,
explicit, and easy to audit. Prefer ordinary upstream build steps and the
smallest necessary, understandable set of flags. Explain non-obvious flags
and recipe-local workarounds. Avoid cryptic flags, shell tricks, hidden
behavior, and vendored or locally applied patches; recipes must not patch
upstream sources.

## Repository boundary

Never read from or write to anything outside this repository. No scratch
files, probes, downloads, logs, workspaces, lock files or build output in
`/tmp`, `~`, or any sibling directory — a sibling checkout of retrolunar is
not an exception and is not a source of truth about recipes. Everything a
task produces lives inside the repo — use `./nest/tmp/` for scratch and
delete it when you are done.

## Layout

- `<name>/source.lua` — fetch recipe: downloads and unpacks
  upstream sources, copies the tree to `$OUT/<name>/`. Runs under the
  `source` pseudo-system, lands in `$NESTDIR/source/<name>/`.
- `<name>/generic.lua` — fallback build recipe when the package has
  no recipe for the requested system. It runs for that requested system; it
  is not a separate target system.
- `<sys>/generic.lua` — system description: a `system({setup=...})`
  call whose `setup` shell fragment defines the whole toolchain
  environment. Systems live in the same tree as packages, as a top-level
  directory too.
- `<sys>/*.cmake`, `*.ini` — cmake toolchain / meson cross files
  shipped next to the system recipe, referenced via `$SYSDIR`.
- `<name>/stage1.md`, `stage2.md`, `stage3.md` — pipeline hand-off files
  (see 'The package pipeline').
- `./nest` — build output (gitignored, local to this repo). `$NESTDIR/<sys>/`
  is the install prefix per system, `$NESTDIR/source/<name>/` holds unpacked
  sources, `$NESTDIR/tmp/` holds per-package `WORK`/`OUT` stage dirs.

- Before writing a recipe, check that `<name>/` does not already exist. A
  directory is the inventory: check with `ls <name>` before creating
  anything. Adding a package means creating new files, never rewriting an
  existing recipe.

## The loader (the `retrolunar` tool's Lua loader)

Three `require` forms:

- `require("pack@sys")` — searches `<pack>/sys.lua`, then the
  requested system's `recipe_fallbacks` entries in order, then
  `<pack>/generic.lua`, else errors. The selected recipe runs with
  `SYSTEM=sys`, so a fallback recipe still targets the requested system.
  `require("pack@native")` resolves `sys` to the compile-time
  `DEFAULT_SYSTEM` (`clang-native` by default, overridable with
  `-DRETROLUNAR_DEFAULT_SYSTEM=...`); it is an alias, not a separate target
  system. Its cache and recipe identity are the same as the resolved
  `pack@<DEFAULT_SYSTEM>` identity.
- `require("pack")` — bare: inherits the requiring module's system from an
  explicit stack (`sys_stack`); at top level uses the C default
  (`DEFAULT_SYSTEM`). Inside a system file (stack top is `generic`) bare
  requires also fall back to the C default. Explicit `pack@sys` never
  consults the stack.
- `require("./x")`, `require("../x")` — relative to the requiring file's
  directory, then `RETROLUNAR_LIB` (default `.`). `a.b` maps to `a/b`.

`recipe(t)` attaches `file`, `dir`, `sys`, and the real `system` table
(loaded on demand as `sys@generic`), then appends `t` to the build queue.
Queue order is dependency order for free: `require` calls run before the
trailing `recipe()` call, so leaves land first; duplicates by canonical
key (`pack@sys`) are an error. `require_queue()` returns a snapshot,
`require_script(nestdir, pkgdir)` emits the install script,
`require_system()` returns the current system. `system(t)` attaches
`file`/`dir` and returns the table.

Recipe fields (`version`, `git`, `tag`, plain strings) become shell
variables in the generated block, so `$version` etc. work in build bodies.
Reserved keys (`build`, `file`, `dir`, `sys`, `system`, `name`) are skipped.

## The generated script

Per queued package, one `if fresh ... else ... fi` block:

- Before freshness checks or package work, create the NESTDIR and take a
  nonblocking `flock` on persistent `$NESTDIR/.retrolunar.lock` (FD 9).
  `flock` from util-linux is a prerequisite; a concurrent script using the
  same NESTDIR fails fast. Keep the file (normally empty) after unlocking:
  kernel-managed advisory locking releases on exit, failure, or power loss,
  so there is no trap-based stale-lock cleanup.
- Freshness: stamp `$NESTDIR/<sys>/.retrolunar-<name>` newer than the
  recipe file, the system file, and the system dir. Stale by any single
  `-nt` comparison means rebuild; missing stamp means build.
- Block prologue: `WORK=$(mktemp -d ...)` + `OUT=$(mktemp -d ...)` under
  `$NESTDIR/tmp`, `trap 'rm -rf "$WORK" "$OUT"' EXIT`, `cd "$WORK"`,
  `PREFIX="$NESTDIR/<sys>"`, `RECIPEDIR="$PACKAGEDIR/<name>"`,
  `SYSDIR` pointing at the system dir, all exported with
  `PACKAGEDIR NESTDIR RECIPEDIR OUT PREFIX SYSDIR`.
- Then the system `setup` fragment runs. After setup, every block derives
  `NATIVE_PREFIX="$NESTDIR/<DEFAULT_SYSTEM>"`, exports it, prepends
  `$NATIVE_PREFIX/bin` to PATH, and prepends `$NATIVE_PREFIX/lib` and
  `$NATIVE_PREFIX/lib64` to `LD_LIBRARY_PATH`, preserving existing values.
  This exposes native helper executables/shared libraries without changing
  `PKG_CONFIG_*` or any system setup.
- Build body verbatim (heredoc `EOF` terminators normalized to column 0).
- Staged `.pc` files get `$OUT` paths rewritten to `$PREFIX` via
  `while read` + `awk` (no `sed -i`).
- Publish only on success: `cp -rf "$OUT"/. "$NESTDIR/<sys>/"`, then
  `touch` the stamp, `rm -rf` the stage dirs, `trap - EXIT`.

`PREFIX` is the search path (earlier packages), `OUT` the install target:
recipes pass `-DCMAKE_INSTALL_PREFIX=$OUT` / `--prefix=$OUT` and read
deps from `$PREFIX`. These plus `RECIPEDIR`/`PACKAGEDIR`/`NESTDIR` are
exported shell vars, never baked absolute paths (except the script header,
which absolutizes `--nest`/`--packages` so the script is cwd-independent).

## Writing a source recipe (`source.lua`)

Fetch-only. Pattern:

```lua
return recipe({
    version = "1.3.1",
    build = [[
        mkdir -p dl
        if [ ! -f dl/zlib.tar.gz ]; then
          curl -fSL -C - -o dl/zlib.tar.gz "https://host/zlib-1.3.1.tar.gz"
        fi
        rm -rf src
        mkdir -p src
        tar -xzf dl/zlib.tar.gz -C src --strip-components=1
        mkdir -p $OUT/zlib
        cp -r src/* $OUT/zlib/
    ]]
})
```

- Tarball in `dl/`, skip re-download with `if [ ! -f ... ]`. Resume with
  `curl -C -`. Mirrors: `|| curl ... mirror` on the same line.
- Unpack to `src/`, then `mkdir -p $OUT/<name>` + `cp -r src/* $OUT/<name>/`.
  `@source` never compiles — it only stages sources.
- No checksums (project decision).
- Tarballs are preferred, but `git clone` is a first-class source too —
  use it whenever upstream has no usable tarball (only git tags) or the
  tarball is known-incomplete (missing git submodules, like protobuf or
  onnx historically were). Pattern (fields `git`/`tag` become shell vars
  via the emitter, see `python/source.lua` which was fetch-by-git
  from the start):
  ```lua
  return recipe({
      version = "3.14.7",
      git = "https://github.com/python/cpython",
      tag = "v3.14.7",
      build = [[
          if [ ! -d src ]; then
            git clone --depth=1 --branch "$tag" "$git" src
          fi
          mkdir -p $OUT/python
          cp -r src/* $OUT/python/
      ]]
  })
  ```
  Add `--recursive` when the build needs submodule content
  (`git clone --depth=1 --recursive --branch "$tag" "$git" src`).
  Guard with `if [ ! -d src ]` so re-runs are idempotent (same role as
  the `if [ ! -f dl/... ]` tarball guard). Shallow (`--depth=1`) always —
  full history is never needed for a build.

## Writing a build recipe (`generic.lua`)

Requires first, one `recipe()` at the end:

```lua
require("zlib")
require("libpng@source")

return recipe({
    build = [[
        cp -r $NESTDIR/source/libpng/* .
        ./configure $AUTOCONF_CONFIGURE_FLAGS --with-zlib-prefix="$PREFIX"
        make
        make install
    ]]
})
```

Rules:

- `require("dep")` inherits your system; `require("dep@sys")` pins one
  (explicit always wins). `require("ownname@source")` pulls your sources,
  copied from `$NESTDIR/source/<name>/` (not `$OUT`).
- Keep `generic.lua` system-neutral. Any flag, cache answer, or workaround
  that is only correct for one target belongs in `<name>/<sys>.lua`,
  never in the generic fallback. Ship ONE file per *family*, not per target:
  every Android system lists `android` in its `recipe_fallbacks`, so
  `<name>/android.lua` is found for all of them, and a recipe for
  one system is just `<name>/<sys>.lua`. Never add a per-target
  copy of an Android recipe — the fallback already covers it.
- When a rule describes the target system rather than one package (a libc
  fact, an Autoconf cache answer, a toolchain quirk), put it in
  `<sys>/generic.lua` next to the other environment variables, so
  every package inherits it. Keep such lines commented with the reason.
  Examples: Android systems export `ac_cv_func_ffsl=yes` because Bionic
  defines `ffsl` inline and Autoconf's link probe cannot see it.
- Build-system flags come from the system, never hardcoded:
  `$CMAKE_FLAGS`, `$AUTOCONF_CONFIGURE_FLAGS`, `$MESON_FLAGS`. Hand-written
  (FFmpeg-family) `configure` scripts are not autoconf and reject
  `--host`/`--build`, so they read the machine facts (`$HOST_ARCH`,
  `$HOST_OS`) and spell them their own way, e.g. libvpx's `--target=` and
  ffmpeg's `--arch=`. Nothing autoconf-incompatible ever goes into
  `$AUTOCONF_CONFIGURE_FLAGS`.
  Search flags (`CPPFLAGS`, `LDFLAGS`, `PKG_CONFIG_*`) also come from the
  system — never `export` them in a recipe. Exception: recipe-local
  workarounds with a comment explaining why (e.g. readline needs
  `CFLAGS="$CFLAGS -fPIC"` because python links it into a shared module;
  termcap needs `CC="$CC -std=gnu89"` because it predates prototypes).
- Build-body hygiene (hard rules): only `cp`, `./configure`, `cmake`,
  `make`, `make install`, `ninja`, `touch`, `find`, `mkdir`,
  `cat`-heredocs. NEVER `sed`, patches or `/dev/null`.
  Job count is never hardcoded: every build tool takes `$CORES`, which each
  system exports (`CORES="${CORES:-1}"`, `MAKEFLAGS="-j$CORES"`), so a build
  is serial unless the caller asked for more. Write
  `make -j"$CORES"`, `cmake --build build --parallel "$CORES"`,
  `ninja -C build -j "$CORES"`, `meson compile -C build --jobs "$CORES"`,
  `cargo build -j "$CORES"`.
  A recipe that writes a literal `-j1`, `--parallel 1`, `--jobs 1` or
  `-j$(nproc)` is the defect — the count is a system fact, not a recipe one.
  A bare `make` needs no flag of its own: `$MAKEFLAGS` carries `-j"$CORES"`
  into it and into its submakes, which is also how a hand-written makefile
  that invokes sub-makes recursively stays consistent. (`opencv/generic.lua`
  was the last recipe still using `-j$(nproc ...)`; the tree-wide pass
  replaced every literal job count with `$CORES`.)
  Rewriting a *generated* artifact the build itself just produced, under
  `$OUT`, is not patching an upstream source and is allowed: use `awk`
  plus `cp`, never `sed -i`. That line is where upstream inputs end and
  our own build output begins — a `.pc` written by `cmake --install` into
  `$OUT` is an artifact we made, and the loader already rewrites that
  same file for `$OUT`→`$PREFIX` (the loader does this in `require_script`), so a recipe
  correcting a field in it is doing by hand what the loader does
  mechanically. What the no-patch rule forbids is editing a file that came
  *out of* the upstream tree — a source, a template, a `CMakeLists.txt` —
  because then the recipe no longer builds upstream, it builds a fork.
  **Scope it tightly: `awk` is permitted only on a generated file under
  `$OUT`, never in `$WORK` and never in the unpacked upstream tree.** A
  bare "awk is allowed" would make text-hacking upstream the path of
  least resistance. `glog/generic.lua` is the worked example:
  `libglog.pc.in:11` is a literal `Cflags: -I${includedir}` with no
  `@variable@`, so no cmake option reaches it, and the recipe rewrites the
  *generated* `libglog.pc` in `$OUT` to add `-DGLOG_USE_GLOG_EXPORT`.
- A cmake project whose platform logic is gated on a variable our
  toolchain files suppress must have that variable set by the recipe. Our
  toolchain files deliberately set `CMAKE_SYSTEM_NAME` to `Linux` to keep
  cmake out of its own NDK integration, so the `ANDROID` variable cmake
  derives from it is never set and an `if (ANDROID)` branch in the
  project's own `CMakeLists.txt` never fires. Set it explicitly in
  `<name>/<sys>.lua` — it is a platform fact, so it cannot live
  in the system-neutral fallback (`-DANDROID=ON` in
  `glog/android.lua`). Then prove it is link-metadata-only:
  build twice, with and without the flag, and `cmp` the archives. glog's
  are byte-identical, which is what licenses keeping the flag out of
  `generic.lua`. `glog/stage3.md` records the full evidence,
  including the archive sizes and the one cmake-internal side effect
  (`Compiler/Clang.cmake:84`), so a reader does not have to reproduce it.
- Autotools timestamp guard after every `./configure` (tarball mtimes
  trigger `aclocal-1.17` re-runs we don't have):
  `touch aclocal.m4 configure <the package's own config template>` +
  `find . -name 'Makefile.in' | xargs touch`
  (also `Makefile.pre.in` for python). **Check the real name in the
  unpacked tree** (`nest/source/<name>`), do not assume `config.h.in`.
  Spellings that occur here:
  - `config.h.in` — most packages
  - `config.hin` — coreutils, diffutils, grep, gzip, groff
  - `ac_config.h.in` — libconfig
  - `configure.h.in` — libseccomp
  - `config_h.in` — sed (underscore between `config` and `h`, not a dot)
  - `config-h.in` — libtool (hyphen between `config` and `h`)
  - `defines.h.in` — less (no `config` in the name, at the top level)
  - sub-configured — two or more templates, one per sub-`configure`:
    c-ares (`src/lib/ares_config.h.in` AND `include/ares_build.h.in`),
    gawk (`configh.in` AND `extension/configh.in`),
    gperf (`src/config.h.in` AND `lib/config.h.in`)
  - none at top level — gmp generates `config.in`, gettext has no top-level
    template; guard the files it does have
  - none anywhere — intltool 0.51.0 has no `AC_CONFIG_HEADERS` at all:
    drop the template from the touch list rather than relocating it,
    since naming a file that does not exist is the same inert guard as
    naming the wrong one

  A sub-configured project ships its own `configure`, `aclocal.m4`,
  template and `Makefile.in` per subdirectory (`AC_CONFIG_SUBDIRS`;
  gawk's `extension/`, gperf's `lib src tests doc`), so a guard that
  sweeps only the top level leaves the sub-configure's autoheader target
  live — the same silent failure. Guard every sub-configure.

  Every entry above was found by a recipe guessing wrong, not by anyone
  reading the tarball first, so this list is evidence, not a lookup table:
  it will be incomplete again for the next package. Checking the unpacked
  tree is what makes the guard safe, not the list.

  Getting the name wrong fails silently: `touch` on a missing FILE in an
  existing DIRECTORY succeeds and creates it, so the wrong template name
  raises nothing under `set -eu` and the autoheader re-run the guard exists
  to prevent stays live. Correct examples: libnl-3, libunwind, oniguruma,
  libseccomp.
- Old C code (termcap 1.3.1): `export CC="$CC -std=gnu89"`.
  Old `bool`-typedef code: `-std=gnu17` (NDK clang defaults to C23).
- `make install` installs straight into `$OUT` (`--prefix=$OUT` /
  `-DCMAKE_INSTALL_PREFIX=$OUT`); the emitter merges `$OUT` verbatim.
- Per-buildsystem notes: cmake needs
  `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` for old projects under cmake 4.x;
  meson cross files live in `$SYSDIR`; cargo needs
  `PKG_CONFIG_ALLOW_CROSS=1` + `RUSTFLAGS="-L $PREFIX/lib"`;
  libvpx configure wants `--extra-cflags="--sysroot=$SYSROOT"`, not
  `-isystem` (breaks libc++ include order) — that line lives in
  `libvpx/android.lua`; ffmpeg ignores `$CFLAGS`/`$LDFLAGS`, so
  `ffmpeg/android.lua` passes them as `--extra-cflags`/
  `--extra-ldflags`.
- Meson recipes: pass `-Ddefault_library=static` (meson builds shared by
  default, and a target prefix has no loader path for a versioned object),
  and do **not** add `DESTDIR` to the install step — `$MESON_FLAGS` already
  carries `--prefix=$OUT`, so `DESTDIR=$OUT ninja install` writes to
  `$OUT$OUT`. `fribidi/generic.lua` is the worked example.
- On Android the *compiler* is the source of truth, not the build system:
  the NDK's API-level wrappers predefine `__ANDROID__` and
  `__ANDROID_MIN_SDK_VERSION__` (the API level itself). A project that
  branches on `__ANDROID__` may still expect its build system to set a
  matching variable, and ours deliberately does not (`CMAKE_SYSTEM_NAME`
  stays `Linux`). Expect to add the project's own private include paths by
  hand — libarchive needs `contrib/android/include` on `CPPFLAGS` for
  exactly this reason. Note also that cmake's `CPPFLAGS` environment
  initialisation is policy-gated (CMP0126) while Autotools always reads it,
  so an appended include path is more reliably delivered to `./configure`.
- Name-mismatch traps: mingw zlib installs as `libzlib`, but libpng
  `configure` hardcodes `-lz` — the libpng recipe symlinks
  `libz.* → libzlib.*` in `$PREFIX` first (commented, additive).

## Naming a cross toolchain package

A package that builds a compiler, assembler, linker or C runtime for a
*different* machine is named for its **target**, never for its host:
`i686-w64-mingw32-binutils`, `i686-w64-mingw32-gcc`,
`i686-w64-mingw32-mingw-w64`. The target goes in the name because it is the
fixed, load-bearing half of the package's identity: it decides the
`--target=` passed to `configure`, the prefix of every installed executable
(`i686-w64-mingw32-ld`), and the directory the artifacts belong under. The
host is dynamic — it is whatever system happens to build the package — so it
cannot appear in the name, and a recipe reads it from the system:
`--host=$BUILD_TRIPLET --build=$BUILD_TRIPLET`, never a literal
`x86_64-pc-linux-gnu`.

The one thing that may be spelled out literally is the *target*, and only
because it is this package's reason to exist. Getting it backwards is the
real hazard: `binutils` as a bare name means "binutils for whatever system is
building it", which is what the plain `binutils/` package is, and a
cross-target binutils must never collide with it — the two install
`ld`, `as` and `ar` under different names, and a system that requires the
wrong one gets a linker for the wrong architecture with no error.

Such a package is built for the **native** system, not for the system that
consumes it: the compiler is a host program that runs on the build machine.
A system file requires it with `require("i686-w64-mingw32-gcc@native")`,
which lands the binaries in `$NESTDIR/<DEFAULT_SYSTEM>/bin` — the prefix the
emitter already puts first on `PATH` for every package block.

### The two MinGW systems

`mingw32` (i686) and `x86_64-mingw` (x86_64) are the same recipe with
different tool names, and that is the point: a third one would be a copy
again. Both take their tools from `PATH` — the host's mingw-w64 — with no
sysroot and no NDK discovery, and both ship a cmake toolchain file and a
meson crossfile next to `generic.lua`. What differs between them is the
triplet, `HOST_ARCH`, and the `i686-*` / `x86_64-*` prefix on every tool.

That "tools come from PATH" is a deliberate simplification, not an
oversight: the alternative is packaging a mingw-w64 CRT, and that is a
large amount of build time and a standing compatibility burden for output
the host toolchain already provides correctly. Reach for a packaged
toolchain only when the host genuinely cannot supply the target.

### `.exe` on both MinGW systems

The mingw driver appends `.exe` to whatever `-o` names, so `-o bzip2`
produces `bzip2.exe`. This is true of `x86_64-w64-mingw32-gcc` and
`i686-w64-mingw32-gcc` alike — it is a property of the driver, not of any
one system, so the same trap waits on both.

A hand-written Makefile whose install rule hardcodes the bare name then
dies with `cannot stat 'bzip2'`, which reads like a missing build output
rather than a filename mismatch. There is often no `EXEEXT` to set:
`bzip2/Makefile` has none and ships no configure to inject one. Copy the
file onto the name the rule wants rather than reimplementing the install
target in the recipe — `bzip2/generic.lua` is the worked example, and it is
what made bzip2 build on `x86_64-mingw` at all; it had never built there.

## Writing a system (`<sys>/generic.lua`)

Single `system({ recipe_fallbacks = {"family"}, setup = [[...]] })` with
`VAR="value"` + grouped `export` lines. `recipe_fallbacks` is optional; it
lists package-recipe system names in lookup order, after the exact target
system and before each package's `generic.lua`. Sections with `# ---`
comments:

```sh
# --- toolchain: NDK clang wrappers + llvm binutils ---
CC="aarch64-linux-android24-clang"
...
export CC CXX AR ...
# --- search paths: our prefix first, NDK sysroot second ---
CPPFLAGS="-I$PREFIX/include"
...
# --- build-system defaults: install into $OUT, find in $PREFIX ---
AUTOCONF_CONFIGURE_FLAGS="--host=aarch64-linux-android --build=x86_64-pc-linux-gnu"
...
```

Rules:

- Every system exports the three machine identities in autotools' terms and
  in that order: `BUILD_TRIPLET` (the machine that runs the build),
  `HOST_TRIPLET` (the machine the artifacts run on; autoconf's `--host`) and
  `TARGET_TRIPLET` (the machine a compiler would target; equal to host
  here, because nothing here builds a compiler for a further machine), plus
  `HOST_ARCH` and `HOST_OS`, the two halves of the host triplet. Never call
  the host machine "target": in a cross build *this* system is the host.
- Every cross system sets `AUTOCONF_CONFIGURE_FLAGS` with **both**
  `--host=$HOST_TRIPLET` and `--build=$BUILD_TRIPLET` (python's configure
  errors out without an explicit `--build`; others guess fine but
  uniformity wins).
- `--prefix=$OUT` / `-DCMAKE_INSTALL_PREFIX=$OUT` (install target),
  search flags point at `$PREFIX` (where deps landed).
- Every system exports `CORES="${CORES:-1}"` and `MAKEFLAGS="-j$CORES"`.
  The default keeps a build serial when nobody asked otherwise, and taking
  the value from the environment with `${CORES:-1}` means retrolunar can
  start exporting `CORES` itself with no change here. `MAKEFLAGS` is what
  makes a bare `make` — and any recursive sub-make it spawns — honour the
  same count as the recipe line that invoked it.
- Keep values short: build long ones by appending
  (`FOO="$FOO more"`), one `export A B C` per section, comments
  explaining non-obvious choices (why `-isystem` is C-only, why `LDFLAGS`
  is empty for cargo, why the NDK glob avoids `ls`).
- Android systems carry `-lm` and `-llog` in `LDFLAGS` because Bionic splits
  both out of libc. `-llog` is the non-obvious one: abseil's `AndroidLogSink`
  (compiled whenever `__ANDROID__` is defined) and glog's `AlsoErrorWrite` both
  call `__android_log_write`, which is in Bionic's liblog. Both packages are
  static-only with testing off, so neither has a link step and both BUILD fine
  with an undefined reference in the archive; the failure only appears when a
  *consumer* links them, and `libglog.pc` ships no `-llog`. Upstream already
  tries to handle this — glog's `CMakeLists.txt` does
  `target_link_libraries(glog PRIVATE log)` inside `if (ANDROID)` — but that
  never fires here, because cmake only sets `ANDROID` when
  `CMAKE_SYSTEM_NAME` is `Android` and our toolchain files deliberately
  `set(CMAKE_SYSTEM_NAME Linux)`. Hence the explicit `-llog`. liblog.so is in
  every NDK sysroot and the symbol is declared from API 21, so it costs
  nothing. `x86_64-mingw` and `clang-native` are not Android and have no
  liblog.
- cmake toolchain + meson crossfile go next to `generic.lua`, referenced
  as `$SYSDIR/<file>` (never generated heredocs in the script).
- Cross systems add `-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY` and
  `-DCMAKE_MAKE_PROGRAM=$(command -v make)` to `$CMAKE_FLAGS`. cmake's
  compiler check links a test program and runs it, which a cross target
  binary cannot do here (and running one would be emulation, which we never
  do); and cmake picks the make program out of `$PREFIX`, where
  `bin/make` is a target binary that would need an emulator too.
- A meson crossfile names no cross tools: meson takes them from the
  environment, so the system must export `$CC`, `$CXX`, `$AR`, `$STRIP`
  and `$LD` as full paths. Only host programs (pkg-config) are listed. The
  rest of the file is `[host_machine]` in *meson's* names, which need not
  match `$HOST_ARCH`/`$HOST_OS` (meson says `arm` and `x86` where the
  systems say `armv7a` and `i686`).
- A non-native system NEVER prepends its toolchain to `PATH`. The cross
  tools are named explicitly (`$CC`, `$CXX`, `$AR`, `$STRIP`, ...), and a
  cross bin dir at the front of `PATH` makes host tools (cmake, make, and
  anything they spawn) run cross binaries. The emitter's `$NATIVE_PREFIX`
  entry stays first, so host helpers come from the native prefix.
- New API level = copy the whole `<arch>-androidNN/` dir, rename every
  `NN` in wrapper names, `--host`, file names, error strings. Existing
  `android21` dirs stay untouched.

## The package pipeline

Bulk package work runs as a three-role pipeline with a written hand-off at
every transition. The hand-off artefacts are Markdown files inside the
package directory: `stage1.md` (build forecast), `stage2.md` (review
verdict), `stage3.md` (build record). Read all three in order before
touching a package.

### Why the stage files exist

The builder trusts the forecast. A forecast that is wrong is worse than no
forecast, because a green "WILL BUILD" in `stage1.md` turns a known red
build into a surprise, and a surprise is what gets worked around instead of
reported.

The review gate's real output is therefore the rejection list. In the run
that produced this pipeline, a 44-package forecast wave returned 16 ACCEPT
and 28 REJECT, and a 10-package wave returned 8 ACCEPT and 2 REJECT. The
rejects were not style complaints. They found real defects with nothing to
do with the package under review:

- The autotools timestamp guard was applied as a blanket
  `touch config.h.in`, but no such fixed name exists in this tree — each
  package has its own, and the rule that spells them out now lives in
  'Writing a build recipe'. Roughly 18 recipes carried an inert guard
  touching a file their package does not have.
- Two Python packages installed into different `site-packages` versions
  under the same prefix, so one of them was invisible to the other.
- A `case $HOST_ARCH` with no `*)` arm silently sent mingw and native down
  the Android branch.

The first of those deserves the extra note, because it does not fail:
`touch` on a missing FILE inside an existing DIRECTORY succeeds and
creates the file. An inert guard therefore raises nothing under `set -eu`,
and the autoheader re-run it was meant to suppress stays live. Those
packages were marked done and had been surviving on lucky mtimes.

### Role 1 — adder

Picks packages off the backlog the user names (the LFS checklist plus the
curated C/C++ candidate lists per platform) and writes, for each:

- `<name>/source.lua`
- `<name>/generic.lua`
- `<name>/android.lua` only when an Android-only switch is
  genuinely needed. Android systems declare `recipe_fallbacks =
  {"android"}`, so one `android.lua` covers every Android target; never
  write a per-target copy.
- `<name>/stage1.md` — the build forecast.

`stage1.md` carries one verdict row per system family: `aarch64-android21`,
`aarch64-android24`, `aarch64-android35`, `x86_64-android35`,
`x86_64-mingw`, `clang-native`. Each row is WILL BUILD, WILL NOT BUILD or
UNCERTAIN, and every non-trivial claim cites a file and a line in the
upstream tree. UNCERTAIN is a legitimate answer. "Looks fine" is not an
answer.

The adder researches by downloading tarballs and reading the real build
files: does the release ship a generated `configure`, what is the config
template actually called, which subdirectories hold host programs, which
options really exist. The adder does not build, compile, configure or test
anything.

### Role 2 — reviewer

Reads the recipes plus `stage1.md` and writes `<name>/stage2.md`.
The first line is exactly `ACCEPT` or `REJECT`.

Two questions decide it:

1. **Is the recipe using the SYSTEM?** Every build-system flag comes from
   `$CMAKE_FLAGS`, `$MESON_FLAGS`, `$AUTOCONF_CONFIGURE_FLAGS`, `$CC`,
   `$CXX`, `$CFLAGS`, `$CXXFLAGS`, `$PREFIX`, `$OUT`, `$SYSDIR`. No
   hardcoded target facts. No `export` of search flags in a recipe; a
   package-local flag is acceptable only with a comment saying why. See
   'Writing a build recipe' for the rules themselves.
2. **Is the recipe doing what the package actually needs?** The real config
   template name, a correct autotools timestamp guard, no host programs
   compiled on a cross build, no target binary ever executed, a job count
   that comes from `$CORES` rather than a literal (`-j1`, `--parallel 1`,
   `--jobs 1`, `-j$(nproc)` — see 'Writing a build recipe'), dependencies
   that actually exist, `require()` spelled the way the loader resolves it.

A REJECT has to be precise enough that the adder can fix it without asking
a question. A vague REJECT is useless. A reviewer may also reject a recipe
whose flags are all correct but whose stated reason is false: a wrong
justification is a real defect, because it is what makes the next person
"fix" a correct flag.

A required change must never rest on an observation you could only make
through clipped output. Long table cells and long comment blocks get
truncated in tool displays, and the ellipsis you see may be the display's,
not the file's. Before asking anyone to complete a sentence, confirm it is
really incomplete — `grep -c` for the ellipsis character, or `od` on the
tail of the line — and quote the byte evidence in the `stage2.md`.

An adder that believes a required change is wrong says so and shows the
evidence rather than making a plausible edit. A fabricated completion is
worse than the original defect: it looks like the review was satisfied.

Seen here: a `stage2.md` asked an adder to finish a sentence truncated
mid-cell in a `stage1.md` table row. The cell was ~950 characters and
complete — the reader clipped it at 768 with an ellipsis the file does not
contain. The adder proved that byte-level and declined to edit; the
director confirmed it by reading the same line and seeing its own reader
clip it identically.

A claim that a file is ABSENT needs the same evidence as a claim that it
is present. Three separate reviews here asserted "this package ships no
config header template" and in all three cases the package did ship one —
nobody had read the tree. Grep `AC_CONFIG_HEADERS` in `configure.ac` and
list the file before writing down that it is not there. An absence claim
with no command behind it is the weakest thing a `stage2.md` can say, and
it is how a correct recipe loses a correct guard.

Reviewers rule on the forecast too. `stage1.md` claiming WILL BUILD with no
citation is a finding. A forecast that contradicts the recipe is a REJECT.

### Role 3 — builder

Builds only what reviewers accepted, on the system where it will most
certainly build, writes `<name>/stage3.md` with the real build log
and any errors, and commits — one commit per package, with the stage1/2/3
files included, following the commit rules in 'Workflow'. A failed build is
still committed: the failure text is the deliverable.

A platform fact discovered during a build (a missing Bionic symbol, a
system-level flag absent from every system file) is recorded as a
system-level blocker in `stage3.md` and is NOT worked around in the recipe.
The builder is the only role that commits. The adder and the reviewer leave
their work uncommitted for the builder to pick up.

A check written in `stage3.md` is re-run by a builder who did not write it
and who cannot tell a false failure from a real one, so a check must have
been run: paste the output of every command against the real prefix. A
count carried over from a forecast is not evidence. Four ways these have
been wrong on correct builds, all seen in this tree: a glob that cannot
match what it counts (`libnl-*-3.a` does not match `libnl-3.a`); a count
scoped to a directory several packages share (`share/man/man3` holds
man-pages, systemd-man-pages, tcl and libseccomp, so
`ls share/man/man3 | wc -l` measures the prefix). Scope every count to
something the package owns — a filename prefix, or a path containing the
package's own name — before counting: `grep -c '^libnl'` and
`find $PREFIX/include/glm` are safe, while `ls $PREFIX/lib/pkgconfig`,
`ls $PREFIX/share/man*` and `ls $PREFIX/include` never are, since those
hold every package's output in the prefix, so such a check passes in an
empty prefix and fails the moment a second package installs. Scoping is
only the first half; the filter itself still has to be checked against the
real file list. And an expected value taken from the review rather than the
tree (stb, 19 against upstream's 20).
State the expected value in the document so a reader can compare it
against reality instead of inferring intent, and make sure the assertion
is not inverted — `[ count -gt 1 ]` fails the correct single-file install.
The fourth failure arrives through the fix for the second: a scoped
filter that matches only what you expect — verify it against the actual
file list, not against the name you expect, because a filter that misses
one file turns a correct count into a phantom defect. `grep -c '^nl-'`
looks correctly scoped and returns 5 for libnl's 6 man pages, the sixth
being `genl-ctrl-list.8`.
Five such checks sat in this tree until one `grep` across
`*/stage*.md` for globs feeding `wc -l` and for count expectations
found them all; that audit takes minutes, so run it after every build wave
rather than once.

### Hand-offs

A REJECT goes back to the adder that wrote the recipe, who fixes it and
does not commit. Rework is not optional and not a formality — see the
accept/reject counts above. An accepted package goes to the builder.

### Sharding

~150 packages is too much for one pass. Split by first letter into disjoint
shards so two or three adders never write the same file, and skip any
directory that already has a stage file so nobody duplicates themselves.

A system directory is not a package. Names matching `*-android<number>`,
plus `x86_64-mingw`, `mingw32` and `clang-native`, are systems and get no
stage files.

Do not use "has a source.lua" as a membership test: a package may have only
a `generic.lua` (pngprobe does).

### Checking a claim is not building the package

The reviewer may compile a throwaway probe against the NDK compilers in a
scratch directory inside this repository to settle a factual claim about a
header or a macro — is
`<asm/unistd.h>` really unavailable, is `PTRACE_POKEUSR` a real macro. That
is checking a fact, not building the package, and it is how claims get
overturned: a forecast that merely repeats the adder's unverified assertion
is worth nothing, because the builder has no way to tell which parts were
checked and which were copied.

### Freshness before build

The builder must invalidate the freshness stamp before building:

- delete `nest/<sys>/.retrolunar-<name>`
- delete `nest/source/<name>` as well when the source recipe's version, URL
  or layout changed

Otherwise a stamp left by an earlier build makes the emitted script print
`skip <name> (fresh)`, the new recipe is never executed at all, and stage3.md
records a green skip as if it were a build. A build counts as a build only
if the log shows real work.

After a successful build, rerun and confirm it prints `skip ... (fresh)` —
that is the only way to prove the new stamp is real.

### Parallel agents on one nest

Several agents can share `./nest`, but the nest's `flock` is fail-fast (see
'Workflow'), and a mutex wrapped around a whole batch makes the batch queue
instead of interleave: one slow build blocks the rest. Take the lock per
package rather than per batch.

The repo's own "no emulation" rule is load-bearing here. A build that wants
to RUN a target binary — expect's `tclsh` generating `pkgIndex.tcl`, groff
rendering its own examples, `file` generating `magic.mgc`, tzdata running
its own `zic` — is a blocker: record it in `stage3.md` and stop. Never
install an emulator to get past it.

## Workflow

For bulk package work — a backlog sweep, or anything with more than a
handful of packages — follow 'The package pipeline' above. It is the same
set of rules below, split across an adder, a reviewer and a builder with a
forecast and a review at each hand-off. The rest of this section describes
the plain single-agent path, which is what an update or a fix needs.

```sh
retrolunar install --nest ./nest --packages . 'pkg@sys' > build.sh
sh -n build.sh                        # syntax gate, always
ANDROID_HOME=/path/to/sdk sh build.sh # NDK systems need this
```

- When asked to add package(s), implement them and run their build on one
  suitable provided system. For more than a handful, use 'The package
  pipeline' above instead of this path. Preserve `./nest` and reuse its
  successful outputs; do not delete it or force dependency rebuilds unless
  necessary.
- Several package additions may run at once against one `./nest`. The
  nest's own lock is fail-fast, so a second build would abort rather than
  queue: take a shared mutex around each package's generate-and-run
  sequence, `flock ./rl-build.lock sh -c '...'` (the lock file lives in the
  repo root, next to the shared `./nest` it guards). Take it per
  package, not per batch: a batch-wide lock makes the whole batch queue
  behind one slow build instead of interleaving. See 'The package pipeline'
  for the shared-nest rules. Agents editing packages need separate jj
  working copies (`jj workspace add` into a directory inside this repo, e.g.
  `work/w1`), so their
  commits never race.
- When asked to update package(s), update exactly the requested scope. Check
  each package's latest stable upstream release, then update its version,
  source URL or git tag, and any build recipe details that changed. Preserve
  existing system support; change system-specific recipes only when needed,
  and leave unrelated packages and systems untouched. If an upstream release
  cannot be used on the supported systems, report the concrete blocker.
  Build each updated package on one suitable provided system, serially,
  reusing `./nest` and avoiding dependency rebuilds unless necessary.
- Use `jj` (not `git`) for repository commits. Commit each completed logical
  change promptly; package work gets one commit per package
  (`jj commit -m 'name version (what it is)'`). Keep `./nest` between builds
  so fresh deps aren't rebuilt; record failures as `'<name> version attempt
  (blocked: reason)'` commits only if sources were added, otherwise just
  drop the files.
- Verify per package: artifact exists (`lib/libfoo.a`,
  `bin/tool`, `include/foo.h`), `pkg-config --modversion foo` if a `.pc`
  ships, rerun prints `skip ... (fresh)`. That last check only means
  something after you have invalidated the stamp: delete
  `nest/<sys>/.retrolunar-<name>` (and `nest/source/<name>` when the
  source recipe's version, URL or layout changed) before building, or the
  rerun skips the new recipe and the skip gets recorded as a build. See
  'The package pipeline' → 'Freshness before build'.
- Known platform walls (don't re-investigate, work around or drop):
  API 21 lacks `stderr` as a real symbol, `POSIX_MADV_*`,
  `process_vm_readv`, `posix_spawn`, `mblen`/`getpass`, `O_BINARY` —
  anything needing them wants API 24+ or gets dropped (wget, bash, ninja,
  llama.cpp). `sfml` is X11-only, `raylib` uses removed NDK APIs.
- No `jj`/`git` commands inside recipes; no network access at build time
  except `curl` in `source.lua` fetch blocks.
- No emulation, ever: never run or test a target binary under QEMU (any
  `qemu-user`/`qemu-aarch64`/`qemu-aarch64-static`), any other emulator,
  VM or binary translator, or a `binfmt_misc` registration of one, and
  never install QEMU to do it. This includes re-executing a build under
  an emulator and letting a build shell out to the tools it just
  cross-compiled (groff rendering its own doc examples is the case that
  bites).
- Verify cross-built artifacts statically, host-side: `file`, `readelf`,
  `llvm-nm`, `llvm-objdump`, ELF machine and API-level checks, symbol
  presence, headers and `.pc` files, `pkg-config --modversion`. When an
  upstream test suite would only run on the target, skip it and say so
  in the report instead of emulating it.
