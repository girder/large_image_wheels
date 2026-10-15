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
  `fetch`, `cmake_build`, `meson_build`/`ensure_meson`, `ensure_rust`,
  `find_version_dir`,
  `ensure_pythons`, `collect_pybins`, `ensure_tools`, `set_patch_python`,
  `scrub_python_sysconfig`, `sanitize_prefix_dylibs`) follow; then
  dependency builders (`build_zlib` ... `build_libtiff`, wrapped by
  `build_libtiff_deps`, plus `build_lcms2`, `build_libpng`,
  `build_openjpeg`, `build_cyrus_sasl`, `build_libmemcached`, the
  openslide chain `build_libbrotli`,
  `build_libexpat`, `build_libffi`, `build_glib`, `build_sqlite`,
  `build_libxml2`, `build_pixman`, `build_freetype`, `build_fontconfig`,
  `build_cairo`, `build_jxrlib`, and the pyvips tree `build_orc`,
  `build_nifti`, `build_lz4`, `build_fftw3`, `build_libhwy`,
  `build_jpegxl`, `build_libimagequant`, `build_libexif`,
  `build_libarchive`, `build_libraw`, `build_harfbuzz`, `build_pango`,
  `build_librsvg`, `build_libde265`, `build_libheif`, `build_poppler`,
  `build_fitsio`, `build_hdf5`, `build_matio`, `build_openexr`,
  `build_imagemagick`), then package builders (`build_pylibtiff`,
  `build_glymur`, `build_openslide`, `build_openslide_python`,
  `build_pylibmc`; each package
  builder calls `sanitize_prefix_dylibs` after its dependencies are built),
  then the main `case` that maps package names to builders
  (`dep:<name>` builds a single dependency for debugging).
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
  run the shared `test/test_script.sh` per python).  The in-VM output
  (report.txt, which holds the full detail) is streamed to the terminal
  while the test runs.  Writes `macos_test_report.txt` and
  `macos_test_log.txt` to `/tmp` (also on timeout); stops (but keeps)
  the VM on failure.  The in-VM timeout is configurable with
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
macos/tart_build.sh openslide_python

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
LIW_PYTHONS="3.13" bash macos/build_wheels.sh openslide_python
LIW_DRYRUN=1 bash macos/build_wheels.sh       # verify env/tools/pythons only
LIW_FORCE=1 bash macos/build_wheels.sh        # ignore completed-step stamps
bash macos/build_wheels.sh dep:zlib           # build one dependency only
```

Completed steps are stamped under `~/liw_macos_build/stamps`, so re-running
only redoes unfinished work.

## Status

Verified end to end as of 2026-10-15 (build VM and test VM runs on the
current code; the list reflects what has actually been observed in VM
runs, not just what the scripts are expected to do):

- All pylibtiff and glymur dependencies build into the private prefix,
  including the openjpeg feature assertions (lcms2, libpng, libtiff
  linkage verified via otool after the libpng framework fix).
- Wheels for 3.11, 3.12, 3.13, 3.14, 3.15, 3.14t, 3.15t: pylibtiff,
  Glymur, openslide_python, and pylibmc built.  Glymur is one wheel per
  architecture (py3-none-macosx, `packaging` declared); openslide_python
  is one cp311-abi3 wheel for the stable pythons plus one wheel per
  free-threaded python; pylibmc is one cp3XX-cp3XX wheel per python.
  Wheel-identity checks pass (pip picks our wheels) for all four;
  otool audits clean with Homebrew hidden;
  bundled dylibs load from `.dylibs`; tiff round trip, bundled
  `tiffinfo`, the openslide bundled-dylib check, and bundled
  `slidetool slide quickhash1` pass on every python.
- The shared `test/test_script.sh` runs inside the test VM per python
  and passes on every requested python.  Its runs exposed four real
  issues, all fixed: glymur 0.14.8 does not declare its `packaging`
  import (fixed in both the macos and linux glymur patches);
  large_image tiff reads segfaulted on darwin/arm64 because large_image
  clears `libtiff.TIFFGetField.argtypes` and ctypes then mishandles the
  variadic call (fixed by wrapping `TIFFGetField` in the pylibtiff
  wheel; the wrapper is in the published wheels and the tiff reads pass
  on every python); openslide-python's bundled-library lookup lost to
  pypi's openslide-bin wheel (see the hard-won details -- the bundled
  lookup now runs first, verified in a VM run); and the harness's own
  `set -u` death (see below).
- Phase 0 python rebuilds are parallelized (up to the VM's cpu count,
  passed from `--cpus`); measured saving of about 5 of the roughly 15
  sequential minutes at concurrency 4.
- Second test run (with the rebuilt openslide_python wheels) hung in
  phase 2: the openslide bundled-dylib check referenced `$rundir` before
  it was defined, and the in-VM script's `set -u` killed the script
  silently (its stderr goes to liw_test.log, not the stream), so the
  host-side loop polled until the full timeout.  Fixed by defining
  `rundir` at the top of the per-venv loop and by adding an EXIT trap
  that records a failure the moment the script dies unexpectedly (bash
  keeps only one EXIT trap, so the Homebrew restore moved into the same
  trap).  The third run passed everything.
- Next up, in rough effort order (see the remaining-packages notes
  below for details): pyvips, then GDAL (the largest), then mapnik
  (which must come after GDAL -- its cmake auto-detects the optional
  GDAL input plugin through pkg-config, and the linux build has gdal
  installed by the time mapnik's configure runs, so the same order is
  required here); last, python-javabridge / python-bioformats, whose
  bundling approach is now decided (see the note) -- its first task is
  the JDK 8 arm64 macOS vendor check.  pyproj stays pypi-sourced.
- pyvips work is staged (2026-10-15), each stage checkpointed with a VM
  run before the next one lands (all reachable as `dep:<name>`;
  `tart_build.sh` skips the expected-wheel validation for those
  pseudo-packages).  Stage 1 -- the leaf dependencies (`build_lz4`,
  `build_orc`, `build_nifti`, `build_fftw3`, `build_libhwy`,
  `build_jpegxl`, `build_libimagequant`, `build_libexif`,
  `build_libarchive`, `build_libraw`) plus the rust toolchain (rustup
  minimal profile installed by provisioning; `ensure_rust` bootstraps
  it on base VMs provisioned before that change) -- passed its
  dependency-only checkpoint VM run.  Stage 2 -- `build_harfbuzz`,
  `build_pango`, `build_librsvg`, `build_libde265`, `build_libheif`,
  `build_poppler`, `build_fitsio`, `build_hdf5`, `build_matio`,
  `build_openexr`, `build_imagemagick` -- is implemented in
  `build_wheels.sh` but has NOT yet been run in a VM; its checkpoint
  run must include every earlier dependency, because each run starts
  from a pristine base VM with empty stamps:
  `macos/tart_build.sh --packages "dep:zlib dep:zstd dep:jbigkit
  dep:libwebp dep:libjpeg-turbo dep:libdeflate dep:xz dep:libtiff
  dep:lcms2 dep:libpng dep:openjpeg dep:libbrotli dep:libexpat
  dep:libffi dep:glib dep:sqlite dep:libxml2 dep:pixman dep:freetype
  dep:fontconfig dep:cairo dep:jxrlib dep:openslide dep:orc dep:nifti
  dep:lz4 dep:fftw3 dep:libhwy dep:jpeg-xl dep:libimagequant
  dep:libexif dep:libarchive dep:libraw dep:harfbuzz dep:pango
  dep:librsvg dep:libde265 dep:libheif dep:poppler dep:fitsio dep:hdf5
  dep:matio dep:openexr dep:imagemagick"` (this is also the order the
  future `pyvips` case will use).  Stage 3 (the `libvips` build and the
  pyvips wheel itself, with the case wiring) follows that run.

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
    `install_name_tool`).  The same applies to bundled *executables*:
    cmake-installed tools carry an RPATH to the prefix lib dir, and the
    dependency-free ones (rdjpgcom, wrjpgcom in glymur/bin) are skipped
    by the sanitizer, so `build_glymur` strips every non-@ RPATH from
    `glymur/bin` and re-signs them.
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
- ctypes calls variadic C functions differently on darwin/arm64 when
  `argtypes` is unset: with `argtypes = None`, a call like
  `TIFFGetField(tif, tag, byref(data))` segfaults inside libtiff for any
  tag actually present in the file, while the identical call with
  `argtypes = [TIFF, c_ttag_t]` works.  large_image clears
  `libtiff.TIFFGetField.argtypes` at import (its patch predates arm64
  macs and is harmless on linux, where the ABIs coincide), which made
  every large_image tiff read segfault with our wheels.  The pylibtiff
  wheel therefore wraps `libtiff.TIFFGetField` (see
  `pylibtiff_libtiff_ctypes_getfield.py` in `build_pylibtiff`) so the
  raw ctypes pointer is always invoked with explicit argtypes while the
  wrapper still accepts `argtypes`/`restype` assignments.  Watch for
  the same pattern with any other variadic libtiff entry point
  (TIFFSetField, TIFFGetFieldDefaulted) if one ever crashes.
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
- cyrus-sasl on darwin: the `macos-framework` feature is enabled by
  default and its install hook creates /Library/Frameworks/SASL2.framework
  symlinks outside the prefix, so `build_cyrus_sasl` passes
  `--disable-macos-framework`.  Do not blindly mirror the Dockerfile's
  configure options: 2.1.28's configure has no `--enable-plain` (the
  plain plugin is always built), and the openssl-backed mechanisms
  (otp, srp, scram, ntlm, passdss) and the openldap-backed ldapdb,
  sql, and auth-sasldb are explicitly disabled or silently dropped
  because the isolated prefix has no openssl or openldap.
- The VM's Homebrew autoconf is 2.73, and autoconf 2.72+ changes how
  `AC_PROG_CC` picks the C standard: it probes for the newest edition
  the compiler supports and **bakes `-std=gnu23` into `$CC`** (it does
  not check what the compiler defaults to).  C23 removed K&R function
  definitions, so cyrus-sasl's md5.c died in the first VM run with
  confusing "unknown type name 'context'" errors (the K&R parameter
  names are parsed as types).  The linux build never sees this because
  the container's autoconf is older.  Fix: pass `-std=gnu17` in CFLAGS
  -- our CFLAGS land after `$CC` in every compile command, so the later
  flag wins, and the C23 probe itself then fails, leaving `$CC` clean.
  Any future autotools build of pre-C23 code in the VM may need the
  same flag.
- `( some steps ) || die ...` disables `set -e` for every command
  inside the subshell: when a compound command's status is checked
  (`||`), bash turns errexit off inside it.  A failed `make -j` in an
  autotools builder therefore keeps going into `make install`, and the
  log shows two failure chains; `die` still fires because the last
  command's status is the subshell's.  The cmake/meson helpers avoid
  this with explicit `|| exit 1` on each step; keep that pattern in
  mind when reading (or writing) autotools builders.
- The scrubbed PATH has /usr/bin ahead of the prefix, so a prefix-built
  tool does not shadow a same-named CLT tool (bison: the CLT's 2.3 vs
  the prefix's 3.8.2 -- the build log's "unrecognized option
  --warnings=all" looks like the prefix bison failed, but it was the
  CLT's).  When a configure script resolves a tool by name at configure
  time, pass it explicitly by absolute path
  (`build_libmemcached` passes YACC="$LIW_PREFIX/bin/bison
  --warnings=all").
- meson is not part of the base VM's Homebrew build-tool set (cmake,
  ninja, pkgconf, autotools are).  `ensure_meson` pip-installs meson
  into the patch python (build tool only; never enters a wheel) and
  `meson_build` runs it.  Beware meson's dependency resolution: when
  pkg-config misses, meson falls back to its own cmake method, which
  searches /opt/homebrew and /usr/local -- our cmake-build isolation
  flags do not apply to meson's internal cmake calls.  Every meson
  dependency must therefore resolve through the prefix's pkg-config
  files (all of openslide's do: zlib, zstd, jpeg, png, tiff, openjpeg,
  glib, gio, gobject, cairo, xml2, sqlite3, and jxrlib via the
  libjxr.pc that jxrlib itself installs).  glib's pcre2 and libdicom are
  fetched and built by meson subproject wraps (meson's default wrap mode
  allows the fallback; the linux build relies on the same wraps).
- glib is a special case for the meson fallback hazard: its meson does
  `dependency('libpcre2-8', required: false)` and then falls back to a
  bare `cc.find_library('pcre2-8')` before reaching its own subproject
  wrap, and find_library searches Homebrew.  On the host shadow run this
  linked Homebrew's pcre2 into libglib (min target 27.0, which delocate
  rejects for an 11.0 wheel).  `build_glib` therefore passes
  `--force-fallback-for=libpcre2-8` so glib builds the wrap's pcre2
  (which carries an apple-platforms fix patch) statically into itself.
  Watch for the same `cc.find_library` pattern in future meson builds:
  pkg-config being prefix-scoped does not make find_library prefix-scoped.
- The in-VM test script runs under `set -u`, and any unbound variable
  kills it *silently*: its stderr goes to liw_test.log (not streamed),
  the failures file is never written, and the host-side loop polls
  "still testing" until the full timeout -- which looks exactly like a
  hang.  This bit us with the openslide check referencing `$rundir`
  before its assignment.  Two defenses now: `rundir` is defined at the
  top of the per-venv loop, and an EXIT trap records a failure the
  moment the script dies unexpectedly, so the host fails fast with
  "the in-VM test script died unexpectedly".  Remember that bash keeps
  only ONE EXIT trap -- a second `trap ... EXIT` replaces the first (the
  Homebrew restore and the failure recorder live in one combined trap).
- openslide-python's bundled-dylib lookup must run BEFORE upstream's
  `import openslide_bin` fast path in `_load_library`.  On macos pypi
  publishes openslide-bin wheels and `large-image[openslide]` installs
  one into every venv, so upstream's fast path wins whenever it runs
  first -- and pypi's libopenslide is unpatched upstream (no
  flattened-MIRAX support), which failed the shared suite's mrxs test
  with a bare "Unsupported or missing image file" (openslide_open
  returned NULL, i.e. no vendor detected -- a vendor *open* failure would
  instead surface as OpenSlideError with a message).  On linux this never
  showed because there is no aarch64 openslide-bin wheel on pypi, so the
  linux venvs fall through to the bundled library.  Consequence of
  shadowing openslide-bin on purpose: our bundled libopenslide always
  wins over a user-installed openslide-bin, matching the linux wheels'
  behavior.  The phase-1 harness check asserts the loaded dylib path is
  in `.dylibs` precisely so this class of regression fails loudly.
- meson's pkg-config isolation needs PKG_CONFIG_LIBDIR, not just
  PKG_CONFIG_PATH + PKG_CONFIG_ALLOW_SYSTEM_LIBS: those only order and
  filter the *output*; pc *discovery* still scans pkgconf's built-in
  default dirs, which for Homebrew's pkgconf include /opt/homebrew.  Any
  meson "auto" feature whose library is installed in Homebrew but not in
  the prefix silently leaks in -- observed on the build host, where a
  `brew install cairo` pulled in X11/lzo/freetype and cairo's auto xlib
  and lzo features lit up mid-build.  PKG_CONFIG_LIBDIR replaces the
  default search entirely, so discovery is prefix-scoped.
- cairo's meson disables freetype and fontconfig by default on darwin
  (it prefers CoreText there; on linux they are required).  The linux
  wheel's cairo has both compiled in, so `build_cairo` passes
  `-Dfreetype=enabled -Dfontconfig=enabled` and asserts the linkage.
  fontconfig is built with `-Dnls=disabled`: NLS only adds translated
  messages, and without it fontconfig's non-pkg-config intl lookup would
  pull a foreign libintl on hosts that have gettext (the VM has none, so
  it lands disabled there anyway).
- fontconfig needs `gperf`, which is neither in the base VM's brew set
  nor in the CLT; fontconfig's meson falls back to its own gperf
  subproject, so nothing extra has to be provisioned.
- The macOS linker rejects undefined symbols in dylibs where the Linux
  linker allows them.  jxrlib's shared-library rules rely on the Linux
  behavior (libjxrglue references symbols that live in libjpegxr); the
  build passes `-Wl,-undefined,dynamic_lookup` to those two link rules
  to restore the Linux semantics.  Verified by an encode/decode round
  trip through both dylibs on the host.  The same rules get
  `-Wl,-install_name,$(DIR_INSTALL)/lib/$(notdir $@)` so the installed
  dylibs have absolute install names (delocate can then rewrite them;
  clang's `-shared` otherwise records the bare output path).
- openslide is pinned by commit sha (`openslide-sha`), so it needs a
  full clone (`git_retry` with an empty tag) -- a sha is not contained in
  a `--depth=1` clone of the branch tip.
- openslide-python's abi3 wheel: upstream master's `_abi3` is
  `version >= (3, 11) and not Py_GIL_DISABLED`, so 3.11+ stable builds
  one cp311-abi3 wheel covering 3.11-3.15 and the free-threaded
  interpreters build their own cp3XX-cp3XXt wheels.  Building for every
  stable python would just produce duplicate abi3 wheels (the linux
  build excludes 3.12-3.15 for the same reason), so
  `build_openslide_python` selects 3.11 and the `*t` pythons from
  `PYBINS`.  `tart_build.sh`'s expected-wheel validation already accepts
  an abi3 wheel for any stable python newer than the abi3 baseline.
- glib on darwin does not need util-linux's libmount/libblkid (the
  Dockerfile builds util-linux only for glib's Linux-side needs), so the
  macos build has no util-linux counterpart.

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
  python 3.10, and the `0.14.8.1` version.  Its dependencies are also
  patched to declare `packaging`: glymur 0.14.8 imports it in
  `version.py` without declaring it (an upstream bug the shared test
  exposed -- `import glymur` fails on a clean install of upstream
  0.14.8, and the linux wheel has the same latent issue until the
  Dockerfile patch is rebuilt).  Verified end to end in the VM: the
  wheel passes the identity, otool, and shared-suite checks on every
  requested python.
- **pyvips**: in progress (2026-10-15), staged (see the Status section
  for which stages are verified).  The linux wheel bundles libvips and
  its whole feature set, so the macos build must mirror the
  Dockerfile's final state before libvips configures: the openslide
  chain (libvips links openslide like any other loader), orc, nifti,
  lz4, fftw3, libhwy, jpeg-xl (which needs libhwy and brotli),
  libimagequant (rust), libexif, libarchive, libraw, harfbuzz, pango,
  librsvg (rust), libde265 + libheif, poppler, cfitsio, hdf5, matio
  (hdf5 first, like the linux build order), openexr, and imagemagick
  (after librsvg, so --with-rsvg finds it).  The rust toolchain mirrors
  the Dockerfile: rustup minimal profile installed at base-VM
  provisioning time, `cargo install cargo-c` for libimagequant,
  `cargo cinstall --prefix=$LIW_PREFIX` for the library itself.
  Stage-2 decisions so far (all to be confirmed by the checkpoint run):
  pango's fribidi is a hard dependency with no prefix copy, so pango is
  configured with `--force-fallback-for=fribidi` to build its own
  subproject wrap statically into libpango (meson's cmake fallback
  method is not prefix-scoped, so a Homebrew fribidi could otherwise
  leak in); librsvg passes `-Dpixbuf=disabled` (gdk-pixbuf is built in
  neither pipeline, and leaving the feature auto could pull librsvg's
  gdk-pixbuf subproject wrap) and appends `lto = true` to Cargo.toml
  like the Dockerfile; poppler passes `-DENABLE_BOOST=OFF` (a
  deviation: boost is not in the prefix yet -- it is a
  splash-performance option that links nothing into the dylibs;
  revisit when boost is built for mapnik/GDAL) while NSS, GPGME, and
  the QT test options mirror the Dockerfile; hdf5 drops the
  Dockerfile's MPI-dependent options (HDF5_ENABLE_PARALLEL and the MPI
  variables -- the prefix has no MPI; parallel netcdf is a GDAL-stage
  concern that will need an MPI built into the prefix) and
  HDF5_ENABLE_DIRECT_VFD (linux-only, O_DIRECT); imagemagick drops
  -lrt from LIBS (linux-only) and is asserted on libMagickCore's own
  delegates (freetype, fontconfig, xml2, zlib) plus a populated coder
  modules directory -- the wheel ships only libMagickCore/MagickWand
  and the `magick` tool, exactly like the linux wheel (the dlopened
  coder modules are not bundled by either delocate or auditwheel);
  matio's hand-written matio.pc points at $LIW_PREFIX (mirroring the
  Dockerfile's overwrite); libvips will need
  `-Dnifti-prefix-dir=$LIW_PREFIX` (the Dockerfile passes /usr/local);
  gobject-introspection is deferred (it produces metadata, not linked
  features, and the macos openslide chain has been fine without it --
  revisit only if libvips's meson requires it).  The `pyvips` module
  needs the same "find the bundled library" patch as pylibtiff,
  adapted to delocate's `pyvips/.dylibs` layout (with the linux
  `pyvips.libs` location as fallback), and the bundled `vips` tools and
  `magick` go into `pyvips/bin` with the `pyvips.bin:program` wrapper
  (the linux wheel does exactly this).
Notes on the remaining packages:

- **openslide_python**: implemented (`openslide_python` case:
  `build_libtiff_deps`, `build_lcms2`, `build_libpng`, `build_openjpeg`,
  then the openslide chain `build_libbrotli`, `build_libexpat`,
  `build_libffi`, `build_glib`, `build_sqlite`, `build_libxml2`,
  `build_pixman`, `build_freetype`, `build_fontconfig`, `build_cairo`,
  `build_jxrlib`, `build_openslide`, `build_openslide_python`).
  openslide 4.x is a meson build and requires (hard deps) glib/gio/gobject,
  cairo, libxml2, sqlite3, zlib, libzstd, libjpeg, libpng, libtiff,
  libopenjp2, and libdicom; libdicom is not built separately -- openslide's
  own `subprojects/libdicom.wrap` fetches and builds it (meson's default
  wrap mode allows the fallback, like the linux build).  The two repo
  patches (`openslide-iewchen-zeiss-czi-jxr.patch`,
  `openslide-vendor-mirax.c.patch`) are applied with `git am` at the
  `openslide-sha` pin (a full clone, since a sha is not in a depth-1
  clone); the zeiss patch adds optional JXR support, so `build_jxrlib`
  runs before openslide and `build_openslide` asserts the linked feature
  set (cairo, glib, gobject, sqlite3, xml2, jxrglue, jpegxr, png, tiff,
  openjpeg, jpeg) via `otool -L`.  util-linux (libmount/libblkid) is a
  Linux-only glib dependency and has no macos counterpart.  meson itself
  is not in the base VM's Homebrew set; `ensure_meson` pip-installs it
  into the patch python and `meson_build` mirrors the Dockerfile's meson
  flags (`--buildtype=release --optimization=3`).  openslide-python is
  cloned from master (the release tag is stale) and patched like the
  linux build: `lowlevel.py` learns to load the bundled libopenslide
  dylib from `openslide/.dylibs` (with the linux `openslide_python.libs`
  fallback) *before* the `openslide-bin` wheel import and the system
  search; the bundled `slidetool` goes into `openslide/bin` with the same
  `openslide.bin:program` wrapper pylibtiff uses (the linux wheels bundle
  only slidetool as well: the `openslide-quickhash1sum`-style names are
  install-time symlinks that do not exist in the meson build directory,
  so the linux find-based copy also produces slidetool only); `setup.py`
  links
  `_convert` against the prefix's libopenslide (`library_dirs`),
  `_version.py` gains the `.1` suffix, and `pyproject.toml` gets the
  package data and console scripts.  Upstream master already carries the
  free-threading `_abi3` guard the linux patch adds.  Because 3.11+ builds
  one abi3 wheel covering 3.11-3.15 (the free-threaded interpreters build
  their own tagged wheels), `build_openslide_python` builds only for 3.11
  and the requested `*t` pythons; `tart_build.sh`'s expected-wheel
  validation already accepts abi3 wheels for the stable pythons, and the
  test harness verifies the version identity per python.  Verified end
  to end in the VM (see the hard-won details for the openslide-bin
  shadowing issue the first VM run exposed and its fix).
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
- **pylibmc**: implemented (`pylibmc` case: `build_zlib`,
  `build_bison`, `build_cyrus_sasl`, `build_libmemcached`,
  `build_pylibmc`) and verified end to end in the VM (build, wheel
  assertions, and the test run pass on every requested python; the
  suite's pylibmc test is currently just `import pylibmc`, which does
  exercise the bundled plugin loading -- pylibmc's module init runs
  `sasl_client_init`, which dlopens every bundled sasl2 plugin and
  aborts the import if one is missing or unparseable).
  The dependency builds were first proven on the host, then observed
  in the VM (two VM rounds: the autoconf C23 issue and the bison
  assertion, both below).  Order
  mirrors the Dockerfile: cyrus-sasl is built before libmemcached
  because libmemcached's configure only compiles its SASL support in
  when libsasl2 is found; `build_libmemcached` asserts the libsasl2
  linkage, since pylibmc's C module keys its SASL paths off
  LIBMEMCACHED_WITH_SASL_SUPPORT and would silently compile them out
  otherwise.  zlib is built first so the extension's `-lz` and
  libmemcached's optional compression resolve to our library.
  libmemcached needs two extra pieces on macOS: `build_bison` (its
  configure hardcodes YACC='bison --warnings=all', the CLT's bison is
  2.3 which predates that option, and the CSL parser the bison rule
  generates is compiled into the library itself), and two clang-compat
  fixes with comments in `build_libmemcached` (the
  `ac_cv_have_htonll=no` cache override so byteorder.cc takes its
  swap64 fallback like on linux, and the `memflush.cc` `== false` sed
  that gcc's -fpermissive hides on linux).  The wheel mirrors the linux
  patches: `libs =
  ["memcached", "sasl2"]`, package_data for the bundled plugins,
  `library_dirs` pointed at the prefix (the linux build relies on
  /usr/local being the default search path; the scrubbed sysconfig data
  makes ours authoritative), the `.1` version suffix, and the
  `__init__.py` patch that sets SASL_PATH to the bundled `pylibmc/sasl2`
  copy before `_pylibmc` is imported.  Plugin delta vs. the linux wheel:
  the linux base image's openssl/krb5/openldap let cyrus-sasl build the
  otp/srp/scram/passdss/ldapdb plugins (auditwheel then bundles
  libcrypto, libkrb5, libldap, and even libpq/libmysqlclient into
  pylibmc.libs); the macos prefix has none of those and system copies
  are forbidden, so those mechanisms are explicitly disabled and the
  bundled set is the self-contained one (PLAIN, CRAM-MD5, DIGEST-MD5,
  LOGIN, ANONYMOUS, SASLDB over ndbm) plus GSSAPIv2 against the macOS
  system Kerberos framework (a /System path the otool audit allows).
  NTLM stays enabled like the Dockerfile but silently drops out
  without an OpenSSL in the prefix, and would light up automatically
  if one is ever added.  Delocate puts
  libmemcached/libsasl2 into `pylibmc/.dylibs` (the pylibmc package is
  the wheel's only directory, and the build asserts the wheel content);
  note the C extension is a *top-level* module (`_pylibmc.cpython-*.so`
  next to the pylibmc package, since its setup.py gives the extension no
  package qualifier), so the test harness audits it separately from the
  package directory.  The expected-wheel validation in tart_build.sh
  needs no per-package change (one cp3XX-cp3XX wheel per python, like
  pylibtiff).
- **python_javabridge / python-bioformats**: decided (2026-10-15): bundle
  the JVM inside the wheel like the linux build does -- the linux wheel
  is fully self-contained (no Java installed on the machine) and the
  macos wheel must behave the same.  The JVM is pinned to Java 1.8 on
  linux (java-1.8.0-openjdk-devel) because bioformats is built for Java
  1.8 and newer JVMs may fail -- the same version constraint applies on
  macOS.  A newer JVM was tried on the linux side at some point (java
  17) and failed in some manner that was not recorded here -- it may be
  diagnosable and solvable, and if it is, a modern JDK (17+) would be
  preferable on macOS: those have official macOS arm64 builds (Temurin,
  Zulu), which removes the vendor-availability problem below.  The
  first feasibility task is therefore twofold: reproduce and diagnose
  the java 17 failure (linux is the easiest place for that), and, if it
  cannot be solved, vendor research on JDK 8: JDK
  8 has no official macOS arm64 builds from most vendors (Temurin has
  none; check Azul Zulu and BellSoft Liberica for an aarch64 macOS 8
  build), and an x86_64 JVM under Rosetta is not an option -- javabridge
  loads libjvm in-process via ctypes, so the JVM's architecture must
  match the wheel's arm64.  If a JDK 8 arm64 macOS build exists, the
  linux bundling flow is the template (pack200 still exists in JDK 8,
  so the jar-repacking/determinism tricks carry over); the macos deltas
  to design: the JDK layout difference (libjvm.dylib under
  Contents/Home/jre/lib/server/ vs. the linux jre/lib/aarch64/libjvm.so
  that the jutil.py/locate.py patches reference), ad-hoc re-signing of
  the bundled JVM binaries and dylibs (arm64 requires valid signatures,
  and JDK dylibs use @rpath heavily), how delocate treats the jvm tree,
  and the otool audit scope for javabridge/jvm.  If neither the java 17
  failure is solvable nor an arm64 Java 8 exists, that fact needs a
  decision before any code is written (the "newer JVM may fail" risk
  would have to be re-tested against current bioformats).
- **mapnik**: needs boost, libicu, and the rest of mapnik's dependency
  set, plus the repo's mapnik patches (mapnik.patch, mapnik_data_path.patch,
  mapnik_tls.patch); check the mapnik sections of the Dockerfile.  It
  must be built AFTER GDAL: mapnik's cmake builds the optional GDAL
  input plugin when it finds libgdal, and the linux Dockerfile installs
  GDAL immediately before mapnik, so doing GDAL first is required for
  feature parity (and, per the case-order rules, the case must build
  the full GDAL dependency tree before mapnik's configure runs).

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
installation with wheel-identity checks (pylibtiff, Glymur,
openslide-python, pylibmc), Homebrew-hiding, the `otool` audits -- scoped to
the packages our wheels provide (libtiff, glymur, openslide, pylibmc),
since the venvs
also contain pypi wheels pulled in as dependencies whose build artifacts
(e.g. Pillow's RPATH to its own build machine, lxml's self-referencing
load commands) are not ours to police -- and the macos-specific checks
(`@loader_path` verification that the bundled dylib is the one loaded,
bundled `tiffinfo`, bundled `slidetool slide quickhash1` against the
suite's downloaded slide, and the pylibmc bundled-library check:
SASL_PATH points into the installed package and the extension's otool
output shows libmemcached loading from `.dylibs`).  The embedded
duplicate functional checks were
removed.  `li_script.sh` (large_image's own tox suite) remains
linux-only; running it in the VM is a possible later extension.

## Notes and differences from the linux build

- `strip-nondeterminism` and `advzip` normalization is not yet applied to
  the macOS wheels; wheel reproducibility is a possible follow-up.
- The Homebrew-hiding test needs passwordless sudo in the VM (our
  provisioning creates it via /etc/sudoers.d/liw-nopasswd); without it,
  the test falls back to the otool audit only and says so in the report.
- The base VM's pyenv pythons all link Homebrew libraries (libintl for
  3.11--3.13; other libraries for the newer ones), so with Homebrew
  hidden the interpreters themselves cannot be trusted.  The test VM
  rebuilds those pythons with a scrubbed environment before testing, so
  the test measures the wheels, not the interpreter's dependencies.
  Since the rebuilds are discarded with the VM, every test run repeats
  them; phase 0 therefore runs the builds concurrently (up to the VM's
  cpu count, passed from `--cpus`).  Measured: about 5 of the roughly
  15 sequential minutes saved at concurrency 4.  An alternative that
  was deferred rather than rejected: using uv to download prebuilt
  interpreters (python-build-standalone) instead of building them with
  pyenv.  Parallelism was tried first and proved sufficient for the
  moment, so uv was not pursued; revisit it if interpreter build time
  becomes a problem again.  If picked up, the known considerations
  are: it changes the rarely-run provisioning (deliberately left
  alone); the PBS interpreters' sysconfig data is unverified against
  the scrub (they are self-contained and should not link Homebrew,
  which could also remove the need for the phase-0 rebuilds);
  availability of every requested version (including free-threaded)
  in the PBS catalog must be checked; and `find_version_dir`/
  `ensure_pythons`/`collect_pybins` match pyenv's directory layout and
  would need to move to uv's.
- Free-threaded wheels import with a `RuntimeWarning` about re-enabling
  the GIL because the C extension is not annotated for free-threading;
  this matches upstream behavior and the linux wheels.
