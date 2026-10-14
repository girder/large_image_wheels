# macOS arm64 wheels

This directory builds native macOS arm64 wheels (for Apple Silicon, M1 and
newer) for the same packages as the repository's linux Dockerfile, using a
tart macOS VM as the isolation boundary.  This file is written to be
self-sufficient: if you are resuming work on this with no prior context,
read it top to bottom before changing anything.

The pipeline is standalone and manages its own VM lifecycle the way
`docker build` manages images: `macos/tart_build.sh` provisions a base
VM from a published macOS image once (Xcode Command Line Tools,
Homebrew with build tools, pyenv with the pythons), and every build
clones a fresh VM from that base.  There is no dependency on any other
provisioning; the `agent_*` VMs of manthey/utils are unrelated to this
pipeline.

## Design

macOS cannot run macOS inside Docker-style containers (Apple's container
framework runs Linux guests), so a tart VM plays the role that the
manylinux container plays for the linux builds:

- Every build starts from a **fresh clone of a pristine base VM**
  (`liw_wheels_base`).  The base is provisioned by
  `macos/tart_build.sh provision` from a published macOS image and is
  never modified by builds; like a docker image, delete it and the next
  build re-provisions it.  Nothing from previous builds or from the host
  can influence the wheels.  Build VMs are deleted when the run finishes
  (stopped and kept on failure for debugging).
- Inside the VM, `build_wheels.sh` is the counterpart of the monolithic
  Dockerfile: it builds every library a wheel needs **from source** into a
  private prefix (`~/liw_macos_build/prefix`) with the pinned versions from
  the shared `versions.txt` (read through `getver.py`, exactly like the
  linux build).  Homebrew and macOS system libraries are never used as
  sources of headers or link targets:
  - `PATH` is scrubbed to `/usr/bin:/bin:/usr/sbin:/sbin:$LIW_PREFIX/bin`;
    Homebrew build *tools* (cmake, ninja, autoconf, automake, libtool, m4,
    pkgconf) are exposed through symlinks in the private prefix.
  - `pkgconf` is pointed only at the private prefix with
    `PKG_CONFIG_ALLOW_SYSTEM_LIBS=0`.
  - CMake runs with `-DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local"`.
- Wheels are built for each requested CPython (pyenv pythons in the base
  VM; missing versions are built on demand) with
  `MACOSX_DEPLOYMENT_TARGET=11.0`, so the platform tag is
  `macosx_11_0_arm64` and the wheels run on every Apple Silicon Mac.
- `delocate` bundles the built dylibs into each wheel and rewrites dylib
  references to `@loader_path`-relative paths (the `auditwheel repair`
  analogue).  Bundled dylibs land in `<package>/.dylibs/` inside the wheel.
- Packages keep the same version-suffix scheme as the linux wheels
  (e.g. `pylibtiff-0.7.0.4.7.2` = package version + bundled libtiff
  version), so macOS and linux wheels coexist in one wheelhouse (platform
  tags differ) and flow through the same index-generation steps.
- Bundled executables work as on linux: the libtiff command line tools go
  into `libtiff/bin` inside the wheel and are exposed as console scripts
  through a `libtiff.bin:program` wrapper that `os.execv`s the binary.

## Files

- `build_wheels.sh` -- the in-VM monolithic build.  Environment setup is at
  the top; helpers (`step`, `v`, `skip_if_done`/`done_stamp`, `git_retry`,
  `fetch`, `cmake_build`, `find_version_dir`, `ensure_pythons`,
  `collect_pybins`, `ensure_tools`, `set_patch_python`,
  `scrub_python_sysconfig`, `sanitize_prefix_dylibs`) follow; then
  dependency builders (`build_zlib` ... `build_libtiff`, wrapped by
  `build_libtiff_deps`, plus `build_lcms2`, `build_libpng`, and
  `build_openjpeg`), then package builders
  (`build_pylibtiff`, `build_glymur`; each package builder calls
  `sanitize_prefix_dylibs` after its dependencies are built), then the main
  `case` that maps package names to builders (`dep:<name>` builds a single
  dependency for debugging).
- `tart_build.sh` -- host-side orchestrator: provisions the base VM if
  missing (`provision` command, or automatically), clones a fresh VM,
  copies the repo in, runs `build_wheels.sh` (nohup + polling via
  `~/liw_macos_build/exit_code`) while streaming the in-VM build log
  (`$LIW_GUEST_HOME/macos_build.log` inside the VM) to the terminal,
  retrieves wheels into `./wheels/`,
  validates that every requested package produced a wheel for every
  requested python (dying on a missing one -- the counterpart of
  `build.sh`'s copy-out of the expected wheels), and deletes the VM.
  On failure a copy of the build log is saved to `/tmp/macos_build.log`.
- `test_via_tart.sh` -- host-side isolation test: clone another fresh VM
  and run an embedded in-VM test script (phase 0: install/rebuild missing
  or Homebrew-linked pythons; phase 1: install the wheels into a venv per
  python and verify pip picks our wheel; phase 2: hide `/opt/homebrew`,
  audit every Mach-O with `otool`, run the macos-specific checks, and
  run the shared `test/test_script.sh` per python).  Writes
  `macos_test_report.txt` and `macos_test_log.txt` to `/tmp`; stops (but
  keeps) the VM on failure.  The in-VM timeout is configurable with
  `LIW_TEST_TIMEOUT` (seconds; default 14400).

## Usage

On the host (a macOS machine with tart and a provisioned base VM; also
install `sshpass` for the one-time ssh-key bootstrap into fresh clones):

```
# provision the base VM (also happens automatically on the first build)
macos/tart_build.sh provision

# full isolated build (fresh VM clone, build, wheel retrieval, VM deletion)
macos/tart_build.sh

# build a single package
macos/tart_build.sh pylibtiff

# verify the wheels on a different fresh VM (writes /tmp/macos_test_report.txt
# and /tmp/macos_test_log.txt)
macos/test_via_tart.sh
```

Both host scripts accept `--base NAME` (base VM to clone; default
`liw_wheels_base`) and `--keep`.
`tart_build.sh` also takes `--packages`, `--pythons`, `--cpus`, `--mem`,
`--disk` (base disk size when provisioning), and `--image` (the OS image
the base is provisioned from); `test_via_tart.sh` takes `--wheels DIR`
and `--keep-homebrew` (to skip the Homebrew-hiding step).

### VM naming

The wheel pipeline uses its own VM namespace, distinct from the
manthey/utils agent sandboxes (which are all named `agent_*`):

- `liw_wheels_base` -- the pristine base VM that every build/test VM is
  cloned from.  It is provisioned by `macos/tart_build.sh provision`
  (or automatically by the first build) from a published macOS image and
  is never modified by builds; it plays the role of the manylinux base
  image.
- `liw_wheels_build` -- the fresh clone that runs `build_wheels.sh`.
- `liw_wheels_test` -- the fresh clone that runs the isolation test.

`macos/tart_build.sh provision` always rebuilds the base from the
pristine image (like a docker image build); there is no in-place update
mode.  The test script never provisions; it fails with instructions if
the base is missing.

Inside a VM, for quick iteration, `build_wheels.sh` runs directly:

```
LIW_PYTHONS="3.13" bash macos/build_wheels.sh pylibtiff
LIW_DRYRUN=1 bash macos/build_wheels.sh       # verify env/tools/pythons only
LIW_FORCE=1 bash macos/build_wheels.sh        # ignore completed-step stamps
bash macos/build_wheels.sh dep:zlib           # build one dependency only
```

Completed steps are stamped under `~/liw_macos_build/stamps`, so re-running
only redoes unfinished work.

## Status

End-to-end verified (a standalone-provisioned base VM, a fresh build VM,
and a fresh test VM, all on the current code):

- All pylibtiff dependencies build into the private prefix.
- Wheels for 3.11, 3.12, 3.13, 3.14, 3.15, 3.14t, 3.15t: all built,
  otool audit clean, and the isolation tests pass with Homebrew hidden
  (bundled dylib loaded from `.dylibs`, tiff image round trip, bundled
  `tiffinfo`).
- Glymur: build commands are implemented (`build_libtiff_deps`,
  `build_lcms2`, `build_libpng`, `build_openjpeg`, `build_glymur`, wired
  into the main `case`; both patch scripts verified against the actual
  glymur 0.14.8 sources), but the VM build and the isolation tests have
  not been run yet.

## Hard-won details (do not lose these)

- Process: when editing these scripts, **verify the edit is in the file
  before committing** (grep for the new content); an atomic multi-part
  edit that partially matches silently applies nothing, and a commit
  message that over-claims is worse than no documentation.  This bit us
  once already.
- If a build fails with `retrying git clone: <url> (v)` -- the tag is
  literally `v` -- the version lookup returned nothing: check
  `versions.txt` first (it is shared with the linux build and is updated
  by the version-cron; a mangled file produced exactly this).  Gating a
  malformed `versions.txt` belongs in the version-update script, not in
  `v()`.
- tart refuses to start a VM once the host's VM/memory limit is reached.
  The host scripts therefore stop their VM on every exit path (success,
  failure, timeout, interrupt), stop leftover running `liw_wheels_*` VMs
  before starting one, verify that `stop_vm` really stopped the VM, and
  clone with `tart clone --overwrite` so stale VMs never block a run.
  Only one 8 GB VM fits alongside a running sandbox; pass `--mem 4096`
  for more headroom.
- `getver.py` resolves `versions.txt` relative to the **current
  directory** (the Dockerfile always runs from `/build`).  The `v()`
  helper cds to the repository root in a subshell.
- The VM's default `/bin/bash` is bash **3.2**: guard empty arrays under
  `set -u` with `${var[@]+"${var[@]}"}` (see the main package loop), and
  avoid bash-4+ features.
- The base VM's shell profiles export `CFLAGS` containing
  `-march=native`; the build script always overwrites CFLAGS/CXXFLAGS and
  never inherits them (native arch flags must not leak into wheels).
- The base VM's pyenv pythons have Homebrew linker flags
  (`-L/opt/homebrew/...`, `-Wl,-rpath,...`) **and** `-march=native` baked
  into their sysconfig data.  `scrub_python_sysconfig` rewrites each
  python's `_sysconfigdata__darwin_darwin.py` (note the leading
  underscore; the glob is `*sysconfigdata*.py`) to strip those tokens.
  Without this, extension builds silently link Homebrew libraries.
  The scrub must only touch **multi-token** values (flag lists):
  single-token values are plain paths or program names (`LIBDIR`,
  `LIBPL`, `prefix`); deleting such a value leaves an empty string, and
  distutils feeds an emptied `LIBDIR` back into `library_dirs`, which
  produces a bare `-L` argument that breaks every extension link.
  The scrub also drops `-Wl,-rpath,~/.pyenv/...` tokens (they would be
  baked into extension `.so` files as absolute RPATHs).
- pyenv free-threaded installs land in directories named like `3.14.8t`
  (full version + `t`), not `3.14t`.  Free-threaded wheel tags are
  `cp314-cp314t` (interpreter tag keeps `cp314`; the ABI tag gets the `t`).
- python-build (pyenv) supplies its own OpenSSL for the pythons it builds;
  do **not** inject Homebrew's OpenSSL into those builds (mixing
  python-build's OpenSSL 4 headers with Homebrew's OpenSSL 3 library broke
  `_ssl` with a flat-namespace symbol error).
- `delocate`:
  - bundles dylibs into `<package>/.dylibs` (auditwheel uses
    `<package>.libs`-style names instead);
  - keeps original dylib file names (`libtiff.6.dylib`; auditwheel hashes
    them, `libtiff-<hash>.so.6`) -- any code that looks bundled libraries
    up by name must handle both (see the `libtiff_ctypes.py` patch);
  - sets copied dylibs' install IDs to `/DLC/<wheel path>` markers; those
    are never used for loading (load commands are `@loader_path`-relative)
    and must be allowed in any otool audit;
  - `delocate-wheel` rewrites the wheel in place when given no output
    directory;
  - its rpath sanitizer (`--sanitize-rpaths`, on by default) only
    processes files that *require* other libraries, so dependency-free
    dylibs (e.g. libjpeg) keep build-tree RPATHs; `sanitize_prefix_dylibs`
    strips RPATHs from the prefix dylibs before wheel building instead
    (re-signing with `codesign -f -s -`, required on arm64 after
    `install_name_tool`).
- The `tiff_h_<version>.py` header companion file is generated by running
  `libtiff/libtiff_ctypes.py` as a script; it needs numpy installed and
  `DYLD_LIBRARY_PATH` pointed at the prefix lib dir (this only affects the
  generation run; wheels never rely on `DYLD_*` paths).
- Extension builds: pass `library_dirs` explicitly in the setup.py patch
  and provide include paths through `CFLAGS` at wheel-build time (the
  scrubbed sysconfig data makes ours authoritative).
- CMake on macOS installs dylibs with an `@rpath` install name by default;
  `cmake_build` passes `-DCMAKE_INSTALL_NAME_DIR="$LIW_PREFIX/lib"` so
  installed dylibs have absolute install names that delocate can rewrite.
- jbig is built and linked statically into libtiff (one less dylib to
  bundle; libtiff's configure finds the `.a`).
- arm64 SIMD needs no `nasm` (NEON assembly is compiled by clang directly).
- Mach-O stripping uses `strip -x` (the GNU `--strip-unneeded -p -D`
  flags do not exist on macOS).
- On macOS, some cmake projects default to building a framework instead
  of a dylib: libpng produces `png.framework/png` (its otool path
  contains no "libpng" substring, which tripped the openjpeg feature
  assertion into flagging a missing optional dependency).  Pass
  `-DPNG_FRAMEWORK=OFF` to get the plain `libpng16.dylib` the linux
  build produces; framework install names would also complicate
  delocate bundling.  When adding a cmake-built dependency, check that
  plain dylibs (not frameworks) land in the prefix.
- libwebp is built before libpng (it is part of the `libtiff_deps`
  chain), so its dwebp/cwebp tools get no png support, unlike the linux
  libwebp which was configured after libpng.  This is accepted: no wheel
  bundles the webp tools, and the libwebp library itself does not use
  png.
- glymur is pure python, so `pip wheel` tags its wheels `py3-none-any`.
  pip may also write the wheel filename in lowercase (`glymur-...`)
  although the distribution is named Glymur; the delocate step renames
  `glymur-*` to `Glymur-*` first (the linux build does the same sed
  rename before auditwheel repair).  Because pip's wheel cache serves
  the identical pure-python wheel to every python, the end result is a
  single Glymur wheel per architecture, matching the linux build.
  delocate never retags an `any` wheel, but it rewrites the WHEEL file's
  tags to match the wheel filename, so the wheel is renamed to
  `py3-none-macosx_11_0_arm64` *before* running `delocate-wheel`, which
  then bundles the executables' dylib dependencies and fixes the WHEEL
  file to match.
- Patch scripts written via unquoted heredocs (`<<'EOF'`) inside a
  function body carry the script's own column-0 layout: the indentation
  of *inserted* code lives inside the triple-quoted replacement strings,
  not in the heredoc.  When testing a patch by extracting it with awk,
  do not `sed 's/^    //'` the extracted file -- that strips the
  replacement strings' real indentation and makes a correct patch look
  broken (or a broken one look correct).  Always verify with
  `python3 -c "import ast; ast.parse(...)` on the patched file.
- libtiff is built with autotools (`autogen.sh`); Homebrew installs the
  GNU libtool binaries as `glibtool`/`glibtoolize`, so `ensure_tools`
  creates `libtool`/`libtoolize` wrappers in the private prefix.

## Adding a package

1. Find the package's section in the Dockerfile and every dependency
   section it pulls in; note the build order and flags.
2. Add a `build_<dep>` function for each new dependency to
   `build_wheels.sh`, mirroring the Dockerfile's flags, using the helpers
   (`git_retry`/`fetch`, `cmake_build`, or explicit autotools commands),
   with `skip_if_done`/`done_stamp` stamps.  Install everything into
   `$LIW_PREFIX` only.
3. Add a `build_<package>` function following the `build_pylibtiff`
   pattern:
   - clone the package at the `versions.txt` pin;
   - apply patches (inline python heredocs written into `$LIW_PATCHES`,
     like the Dockerfile's inline patches; take `$LIW_PREFIX` from the
     environment, not hardcoded paths);
   - handle any header/metadata generation steps;
   - commit the patches and tag with the combined version
     (`$(v <package>).$(v <bundled lib>)`);
   - loop over `${PYBINS[@]}` (set by `collect_pybins`) building wheels
     with `pip wheel --no-deps`;
   - run `delocate-wheel` over the results;
   - `done_stamp <package>`.
4. Wire the package into the main `case` (with the dependency builders it
   needs).  Two rules govern that list:
   - **Completeness on a fresh VM**: every build starts from a pristine
     base, so the case must build the package's *full* dependency tree,
     not just what some earlier package's run happened to leave in the
     prefix.  Order matters just as much: configure-time feature
     detection silently drops optional libraries that are not installed
     yet, so every library the linux build makes available to this
     package must be built before the package's configure step (mirror
     the Dockerfile's final state; see `build_openjpeg` and its feature
     assertions for the pattern).
   - **Feature assertions**: after a dependency-sensitive build, assert
     the feature set rather than trusting configure's silence.  Grep
     `otool -L` output of the produced binaries for every optional
     library the linux wheel links, and die if one is missing.  A
     missing optional library would otherwise only surface as a
     reduced-capability wheel that the functional tests may never
     exercise.
5. Build and test: `LIW_PYTHONS="3.13" bash macos/build_wheels.sh
   <package>` inside the VM, then the full host flow (`tart_build.sh` +
   `test_via_tart.sh`).

Notes on the remaining packages:

- **Glymur**: implemented (`glymur` case: `build_libtiff_deps`,
  `build_lcms2`, `build_libpng`, `build_openjpeg`, `build_glymur`).
  lcms2 and libpng are built because the linux openjpeg (rebuilt after
  they existed) links them into the bundled `opj_*` tools; skipping them
  would silently ship feature-reduced tools.  `build_openjpeg` asserts
  the linkage.  Like the linux build, openjpeg is built *after* libtiff
  (the linux Dockerfile builds it twice; one build after libtiff reaches
  the same final state).  The bundled `opj_*` and libjpeg tools go into
  `glymur/bin` with the same `glymur.bin:program` wrapper pylibtiff
  uses; `config.py` is patched to find the bundled openjpeg dylib in
  `glymur/.dylibs` (with the linux `Glymur.libs` location as fallback),
  and `pyproject.toml` is patched for the console scripts, package data,
  python 3.10, and the `0.14.8.1` version.  Still to do: run the VM
  build and the isolation test.
- **pyvips**: needs libvips and its dependency tree (glib, gobject
  introspection, and friends from the Dockerfile); the `pyvips` module
  needs the same "find the bundled library" patch as pylibtiff.
- **openslide_python**: needs openslide (with its own patch set from the
  repo's `.patch` files) and the same bundled-library lookup patch.
- **GDAL**: the largest build; the Dockerfile's full dependency tree
  applies, and the licensing-inclusive feature set should be mirrored.
  The python bindings link libgdal directly and need the bundled-library
  treatment plus the `GDAL_LIBRARY_PATH`/`GEOS_LIBRARY_PATH` exports that
  the linux wheels provide.
- **pyproj**: intentionally not built for macOS.  pyproj4 publishes
  macosx arm64 wheels, so the tests install pyproj from pypi like any
  other dependency; the linux pipeline no longer builds a pyproj wheel
  either (the pyproj4 section's `pip wheel` commands are disabled).  Do
  not confuse this with the `proj4` library section of the Dockerfile
  ("Used by gdal and mapnik"): that library is still required and must
  be built before GDAL or mapnik, mirroring its position in the
  Dockerfile's order.
- **pylibmc**: needs libmemcached (+ cyrus-sasl in the Dockerfile).
- **python_javabridge / python-bioformats**: need a JDK; the linux build
  bundles the JVM inside the wheel.  On macOS, decide whether to bundle
  a macos arm64 JDK the same way or to rely on an installed JVM; the
  `javabridge/jutil.py` and `locate.py` patches reference `.so` paths and
  need macos equivalents (`.dylib`, and `lib/jvm/lib/libjvm.dylib`
  layout).  This is the package most likely to need real design work.
- **mapnik**: needs mapnik + boost etc.; check the mapnik patches.

## Test parity with the linux build

The linux wheels are verified by `test/test_script.sh` (driven by
`test_via_docker.py`, which runs one container per python version --
see also `test/python.Dockerfile` and `test/li_script.sh`).  Decision
(2026-10): the macOS wheels are verified by the **same script**, not by
a separate python check harness; a parallel rewrite would drift from the
authoritative suite.

`test_script.sh` extensions that keep this workable on both platforms
(all no-ops for the linux containers):

- Each `TEST_*` flag combines the interpreter-feature conditions with a
  check that the corresponding wheel exists in the wheelhouse (its first
  argument).  On linux every wheel is present, so the gates reduce to
  the interpreter conditions; on partial wheelhouses (the macOS build
  produces only some packages) the absent packages' tests are skipped
  instead of failing to install -- or worse, silently installing a pypi
  wheel.  `tart_build.sh` hard-fails on any missing expected wheel
  before tests run, so a skip here means the package was not requested,
  not that a build silently failed.
- `LIW_PYTHON_BIN_DIR`, when set, is prepended to PATH after
  `. /etc/profile` (which resets PATH to the stock system value in the
  VM); the macOS harness sets it to the interpreter under test so
  `python3` and the script's venv are the requested version.
- The sample-file downloads go through a `dl` helper that caches in
  `LIW_TEST_CACHE` when set; the macOS harness runs the script once per
  python in one VM and would otherwise re-download everything seven
  times.
- The arch gates treat `aarch64` and `arm64` as the same machine
  (`$(arch)` prints `arm64` on macOS; `platform.machine()` likewise),
  so the czi test and the gdal `mrsid` subtraction behave identically on
  both arm64 platforms.

The macOS harness (`test_via_tart.sh`) keeps only the platform layers
around the shared script: phase 0 python rebuilding, phase 1 venv
installation with wheel-identity checks (pylibtiff and Glymur),
Homebrew-hiding, the `otool` audits (including the venvs
`test_script.sh` creates), and the macos-specific checks (`@loader_path`
verification that the bundled dylib is the one loaded, bundled
`tiffinfo`).  The embedded duplicate functional checks were removed.
`li_script.sh` (large_image's own tox suite) remains linux-only; running
it in the VM is a possible later extension.

## Notes and differences from the linux build

- `strip-nondeterminism` and `advzip` normalization is not yet applied to
  the macOS wheels; wheel reproducibility is a possible follow-up.
- The Homebrew-hiding test needs passwordless sudo in the VM (our
  provisioning creates it via /etc/sudoers.d/liw-nopasswd); without it,
  the test falls back to the otool audit only and says so in the report.
- The base VM's older pyenv pythons (3.11--3.13) link Homebrew's libintl
  directly, so with Homebrew hidden the interpreters themselves cannot
  start.  The test script detects this (`otool -L` on the interpreter)
  and rebuilds those pythons in the test VM with a scrubbed environment
  before testing, so the test measures the wheels, not the interpreter's
  dependencies.
- Free-threaded wheels import with a `RuntimeWarning` about re-enabling
  the GIL because the C extension is not annotated for free-threading;
  this matches upstream behavior and the linux wheels.
