# raylib 6.0 — stage 2 review

ACCEPT

Reviewed: `raylib/source.lua`, `raylib/generic.lua`, `raylib/android.lua`,
and the forecast in `stage1.md`.

## 1. Is the recipe using the SYSTEM?

Yes. Every build-system flag comes from the system:

- `$CMAKE_FLAGS` carries the toolchain file, `$OUT`, `$PREFIX`,
  `CMAKE_POLICY_VERSION_MINIMUM`, the try-compile workaround and the make
  program; the recipe never names a target fact.
- Job count is `"$CORES"`, on `cmake --build build --parallel` — no literal.
- The recipe `export`s nothing.
- `require("raylib@source")` is spelled the way the loader resolves it, and
  the build copies from `$NESTDIR/source/raylib/` — the `$OUT` of the source
  pseudo-system, which is where `@source` lands its tree.

The two switches the recipe *does* pass are the ones the system cannot
supply, and `stage1.md` cites the line for each:

- `-DPLATFORM=Android`. This is raylib's own option
  (`CMakeOptions.txt:9`, consumed at `cmake/LibraryConfigurations.cmake:77`),
  not a machine fact. cmake's `ANDROID` variable — the one our toolchain
  files suppress — is never consulted on this path, so nothing here is a
  duplicate of a system-provided setting. It is in `android.lua` and not in
  `generic.lua`, which is right: it is the platform backend choice, so it is
  exactly the kind of thing that must not be in the system-neutral fallback.
- `-DANDROID_NDK="$NDK"`. The system files export `NDK` (every Android
  `generic.lua`, the NDK-discovery section) and nothing exports
  `ANDROID_NDK`; the value cmake would normally have received from the NDK's
  own `android.toolchain.cmake`, which we deliberately do not use. It reads
  the system fact and passes it through, rather than hardcoding a path.

`BUILD_EXAMPLES=OFF` is correct and necessary: upstream defaults it to
`${PROJECT_IS_TOP_LEVEL}` (`CMakeOptions.txt:22`), and the examples are
target programs.

One thing `stage1.md` claimed that is worth confirming rather than taking on
trust: it lists `clang-native` as WILL NOT BUILD on the strength of
`src/CMakeLists.txt:123` (`find_package(X11 REQUIRED)`). That is an absence
claim about what is in the prefix, and per AGENTS.md an absence claim needs a
command behind it. It is not load-bearing for this wave — `clang-native` is
not built here and `generic.lua` carries no Android switch — but the honest
statement is that the desktop path is **untested**, not that it is known to
fail. Treat the `x86_64-mingw` UNCERTAIN and the `clang-native` verdict as
open until someone actually runs the desktop build.

## 2. Is the recipe doing what the package needs?

Yes, with one thing the forecast did not predict and the recipe does handle.

**The forecast was right about the split.** One `android.lua` covers all four
ABIs and every API level, because every Android system lists `android` in
`recipe_fallbacks`. No per-target copy exists and none should.

**No host programs, no target binary ever run.** Every object is C; the NDK
glue (`android_native_app_glue.c`) is C and is a source file, not something
to build and invoke. `BUILD_EXAMPLES=OFF` removes the only executables in the
project. Nothing in the build shells out to anything it just cross-compiled.

**No autotools timestamp guard is needed, and correctly absent.** raylib
ships no `configure`, no `aclocal.m4`, no `Makefile.in` and no config
template; the `src/config.h` is a checked-in file, not a `configure`
substitution product. Verified by listing the unpacked tree in
`nest/source/raylib`, not assumed:

```
$ ls nest/source/raylib/configure nest/source/raylib/config.h.in nest/source/raylib/aclocal.m4
(no such file)
$ ls nest/source/raylib/src/config.h
nest/source/raylib/src/config.h
```

So the "naming a template that does not exist" failure mode AGENTS.md warns
about cannot occur — there is nothing to name.

**Dependencies are real.** `LIBS_PRIVATE` at
`cmake/LibraryConfigurations.cmake:94` names `log android EGL GLESv2
OpenSLES atomic c`, all NDK platform libraries present in the sysroot at
every API level; `LIBS_PUBLIC` is `m`, which every Android system also
carries in `LDFLAGS`.

**The packaging defect the forecast predicted is real, and the recipe
repairs it.** `LIBS_PRIVATE` reaches the target only via
`$<BUILD_INTERFACE:...>` (`src/CMakeLists.txt:99`), so it never reaches the
installed `.pc` or the exported target. Both were confirmed on the installed
prefix before the fix — see `stage3.md`, which records the two failing link
tests. The recipe's remedy is an `awk` rewrite of two **generated artifacts
under `$OUT`**, which is the case AGENTS.md explicitly permits and names the
`glog` recipe as the precedent for. It is scoped to `$OUT/lib/...` and
never touches `$WORK` or the unpacked tree; there is no `sed`, no patch, and
no edit to a file that came out of upstream. `raylib.pc.in` has no
`@variable@` carrying these libraries, so there is no cmake option that
reaches them and no recipe-side alternative to a post-install rewrite.

**Not a required change, recorded anyway:** the recipe cannot make the
build's own `--config` output any cleaner, and the `THREADS_PREFER_PTHREAD_FLAG`
cmake warning is a system-wide observation (raylib never calls
`find_package(Threads)`), not a raylib defect. It is left alone.

## Verdict

ACCEPT. One `android.lua` for the whole Android family, no hardcoded target
facts, no job-count literal, no patch to upstream sources, and a generated-artifact
rewrite that the packaging defect makes unavoidable.