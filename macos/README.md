# macOS arm64 wheels

This directory builds native macOS arm64 wheels (for Apple Silicon, M1 and
newer) for the same packages as the repository's linux Dockerfile, using a
tart macOS VM as the isolation boundary.  This file is written to be
self-sufficient: read it top to bottom before changing anything.

The pipeline is standalone and manages its own VM lifecycle the way
`docker build` manages images: `macos/tart_build.sh` provisions a base
VM from a published macOS image once, and every build clones a fresh VM
from that base.  There is no dependency on any other provisioning; the
`agent_*` VMs of manthey/utils are unrelated to this pipeline.

## Design

macOS cannot run macOS inside Docker-style containers (Apple's container
framework runs Linux guests), so a tart VM plays the role that the
manylinux container plays for the linux builds:

- Every build starts from a **fresh clone of a pristine base VM**
  (`liw_wheels_base`), provisioned by `macos/tart_build.sh provision`
  from a published macOS image and never modified by builds; like a
  docker image, delete it and the next build re-provisions it.  Build
  VMs are deleted when the run finishes (stopped and kept on failure).
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
  `macosx_11_0_arm64`.
- `delocate` bundles the built dylibs into each wheel and rewrites dylib
  references to `@loader_path`-relative paths (the `auditwheel repair`
  analogue).  Bundled dylibs land in `<package>/.dylibs/` inside the wheel.
- The linux build salts auditwheel's grafted-library hash per build
  (`auditwheel_build_id_patch.py`) so wheels from different builds never
  share grafted-library names.  There is deliberately NO macos analogue:
  delocate does not rename what it bundles and rewrites every reference
  to a per-package `@loader_path` path, so dyld never dedupes same-soname
  copies the way the ELF loader does on linux (the linux salt exists for
  exactly that hazard).  Two copies with the same basename simply load as
  separate images; the one visible symptom is the benign objc
  duplicate-class warning when pyvips and openslide both load their
  libgio copies.  A stale copy cannot survive a package upgrade either:
  pip replaces the whole package directory, `.dylibs` included.
  Wheelhouse differentiation comes from the same version-suffix scheme
  as linux (package version + bundled library versions).
- Bundled executables work as on linux: e.g. the libtiff command line
  tools go into `libtiff/bin` inside the wheel and are exposed as console
  scripts through a `libtiff.bin:program` wrapper that `os.execv`s the
  binary.

## Files

- `build_wheels.sh` -- the in-VM monolithic build, organized like the
  Dockerfile: environment setup and helpers at the top, then one
  `build_<dep>` function per library (installed into `$LIW_PREFIX`),
  then one `build_<package>` function per wheel (each runs
  `sanitize_prefix_dylibs` after its dependencies are built), then the
  main `case` mapping package names to builders (`dep:<name>` builds a
  single dependency for debugging; hyphenated names such as
  `dep:jpeg-xl` map to their underscored builders).  Completed steps are
  stamped under `~/liw_macos_build/stamps`, so re-running only redoes
  unfinished work.
- `tart_build.sh` -- host-side orchestrator: provisions the base VM if
  missing, clones a fresh VM, copies the repo in, runs `build_wheels.sh`
  (nohup + polling via `~/liw_macos_build/exit_code`) while streaming
  the in-VM build log to the terminal, clears this run's stale wheels
  out of `./wheels/` before the copy-out (only the requested packages'
  macosx wheels plus, for python_bioformats, its shared py3-none-any
  wheel -- other packages' wheels, including linux builds', are left
  untouched), retrieves the wheels, validates that every requested
  package produced a wheel for every requested python (dying on a
  missing one), and deletes the VM.  The build log is always copied to
  `/tmp/macos_build.log` when the build finishes, success or failure.
  Default package set includes `gdal`; timeout default 43200 s (the
  gdal tree pushes a full run past 6 hours).
- `test_via_tart.sh` -- host-side isolation test: clone another fresh VM
  and run an embedded in-VM test script (phase 0: install/rebuild missing
  or Homebrew-linked pythons; phase 1: install the wheels into a venv per
  python and verify pip picks our wheel; phase 2: hide `/opt/homebrew`,
  audit every Mach-O with `otool`, run the macos-specific checks, and
  run the shared `test/test_script.sh` per python).  Writes
  `macos_test_report.txt` and `macos_test_log.txt` to `/tmp` when the
  in-VM test completes; stops (but keeps) the VM on failure.
  In-VM timeout: `LIW_TEST_TIMEOUT` (seconds; default 14400).

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
`liw_wheels_base`), `--cpus N` and `--mem MB` (overriding the host-sized
defaults: one fewer vCPU than the host's processor count, and
max(4096 MB, one third of the host's memory)), and `--keep`.
`tart_build.sh` also takes `--packages`, `--pythons`,
`--disk` (base disk size when provisioning), and `--image`; 
`test_via_tart.sh` takes `--wheels DIR` and `--keep-homebrew` (to skip
the Homebrew-hiding step).

VM namespace (distinct from the manthey/utils `agent_*` sandboxes):
`liw_wheels_base` (pristine base, the manylinux-image analogue),
`liw_wheels_build`, `liw_wheels_test`.  `provision` always rebuilds the
base from the pristine image; there is no in-place update mode.  The
test script never provisions; it fails with instructions if the base is
missing.

Inside a VM, for quick iteration, `build_wheels.sh` runs directly:

```
LIW_PYTHONS="3.13" bash macos/build_wheels.sh pylibtiff
LIW_DRYRUN=1 bash macos/build_wheels.sh       # verify env/tools/pythons only
LIW_FORCE=1 bash macos/build_wheels.sh        # ignore completed-step stamps
bash macos/build_wheels.sh dep:zlib           # build one dependency only
```

## Status

All packages in the default set are verified end to end in VM runs (a
fresh-VM full build, then `test_via_tart.sh` on a second fresh VM):
pylibtiff, Glymur, openslide-python, pylibmc, pyvips, gdal, mapnik, and
python_javabridge/python_bioformats.  The run-by-run history of how each
package reached that state is in this branch's commit messages.

Wheels are built for 3.11, 3.12, 3.13, 3.14, 3.15, 3.14t, and 3.15t:

- Glymur: one wheel per architecture (py3-none-macosx, `packaging`
  declared).
- openslide-python: one cp311-abi3 wheel for the stable pythons; the
  free-threaded pythons build their own tagged wheels, and 3.15t gets
  the upstream Stable-ABI tag `cp315-abi3.abi3t`.
- pylibtiff, pylibmc, pyvips, gdal, mapnik: one cp3XX-cp3XX wheel per
  python.
- python_bioformats: one py3-none-any wheel, shared across all pythons.

Known benign observation: when pyvips and openslide are loaded in one
process, each loads its own libgio copy and macOS prints an objc
duplicate-class warning; the linux wheels ship their own `.libs` copies
the same way, so this is parity, not a defect.

Maintenance watch items:

- All macos-only build inputs (bison, swig and its pcre2, the Zulu JDK 8
  via `zulu8`, resolved through the Azul metadata API's latest-GA query)
  are tracked entries in `check_versions.py`/`versions.txt` read through
  `v()`.  The swig 4.5.1 and pcre2 10.49 bumps have not yet been
  exercised in a VM run; the next swig-touching build (a GDAL wheel
  rebuild) should watch the generated-bindings step.
- Deliberate pins that override `versions.txt`'s latest check: openssl
  3.6.2 (the linux pin; versions.txt's 4.0.3 is ignored, like on linux)
  and libopendrive 0.6.0-gdal (upstream's `<version>-gdal` branch tag is
  tracked; 0.6.1-gdal requires external pugixml and other work).

## Hard-won details (do not lose these)

Durable traps from building this pipeline.  Most fixes are also recorded
as comments in `build_wheels.sh` at the point of use.

- When editing these scripts, **verify the edit is in the file before
  committing** (grep for the new content); an atomic multi-part edit
  that partially matches silently applies nothing.
- CMake projects can silently override `CMAKE_INSTALL_NAME_DIR` (hdf5
  hardcodes `@rpath` on Apple via HDFMacros.cmake); consumers then
  record the @rpath name and nothing resolves it once prefix rpaths are
  stripped, so delocate fails long after the offending build.  The
  `build_pyvips` catch-all audit (every prefix dylib must have an
  absolute install name) is the backstop; meson and libtool installs
  mangle install names to absolute paths themselves.
- Python cffi extensions are linked with `-undefined dynamic_lookup`:
  otool -L shows no load command for libraries their symbols bind to at
  import time (pyvips's `_libvips.abi3.so` shows no libvips at all --
  the patched `__init__.py` ctypes preload provides it).  Verify such a
  preload with `DYLD_PRINT_LIBRARIES=1` in a fresh interpreter.
- A build failing with `retrying git clone: <url> (v)` (the tag is
  literally `v`) means the version lookup returned nothing: check
  `versions.txt` first.  Gating a malformed `versions.txt` belongs in
  the version-update script, not in `v()`.
- tart refuses to start a VM at the host's VM/memory limit.  The host
  scripts stop their VM on every exit path, stop leftover
  `liw_wheels_*` VMs first, verify `stop_vm` worked, and clone with
  `tart clone --overwrite`.  `build_wheels.sh`'s LIW_JOBS follows the
  VM's vCPU count, so a high `--cpus` with a low `--mem` can starve
  parallel compiles.
- `getver.py` resolves `versions.txt` relative to the current directory;
  the `v()` helper cds to the repo root in a subshell.
- The VM's `/bin/bash` is bash **3.2**: guard empty arrays under
  `set -u` with `${var[@]+"${var[@]}"}` and avoid bash-4+ features.
- The base VM's profiles export `CFLAGS` with `-march=native`; the
  build script always overwrites CFLAGS/CXXFLAGS (native flags must not
  leak into wheels).
- The base VM's pyenv pythons have Homebrew linker flags and
  `-march=native` baked into their sysconfig data.
  `scrub_python_sysconfig` rewrites each python's
  `_sysconfigdata__darwin_darwin.py` to strip those tokens; without it
  extension builds silently link Homebrew.  The scrub must only touch
  multi-token values: emptying a single-token value (`LIBDIR`, `LIBPL`,
  `prefix`) makes distutils emit a bare `-L` that breaks every extension
  link.  It also drops `-Wl,-rpath,~/.pyenv/...` tokens (they would be
  baked into extension `.so` files as absolute RPATHs).
- pyenv free-threaded installs live in directories like `3.14.8t`
  (full version + `t`); free-threaded wheel tags are `cp314-cp314t`.
- python-build (pyenv) supplies its own OpenSSL for the pythons it
  builds; do not inject Homebrew's OpenSSL into those builds (mixing
  OpenSSL 4 headers with OpenSSL 3 libs broke `_ssl`).
- `delocate` bundles dylibs into `<package>/.dylibs` and keeps original
  file names (`libtiff.6.dylib`; auditwheel hashes them) -- code that
  looks bundled libraries up by name must handle both.  Copied dylibs'
  install IDs are `/DLC/...` markers (never used for loading; allow
  them in otool audits).  `delocate-wheel` rewrites the wheel in place
  with no output dir.  Its rpath sanitizer only processes files that
  require other libraries, so dependency-free dylibs keep build-tree
  RPATHs -- `sanitize_prefix_dylibs` strips and re-signs the prefix
  dylibs before wheel building (codesign is required on arm64 after
  install_name_tool), and bundled executables get the same treatment
  (e.g. `build_glymur` strips every non-@ RPATH from `glymur/bin`).
- The `tiff_h_<version>.py` header companion is generated by running
  `libtiff/libtiff_ctypes.py` as a script; it needs numpy and
  DYLD_LIBRARY_PATH pointed at the prefix (generation run only; wheels
  never rely on DYLD_* paths).
- Extension builds: pass `library_dirs` explicitly in the setup.py patch
  and provide include paths through CFLAGS at wheel-build time (the
  scrubbed sysconfig data makes ours authoritative).
- `cmake_build` passes `-DCMAKE_INSTALL_NAME_DIR="$LIW_PREFIX/lib"`.
  With modern cmake, a dylib's BUILD-TREE install name is
  `@rpath/<soname>` regardless -- the INSTALL_NAME_DIR property only
  rewrites ids at install.  Harmless unless a wheel-shipped dylib links
  a SIBLING dylib of the same build tree; the fix is
  `-DCMAKE_BUILD_WITH_INSTALL_NAME_DIR=ON` (hdf4, geos, openexr, mapnik
  use it).  It is defeated by project macros that set
  CMAKE_INSTALL_NAME_DIR to @rpath (hdf4 needed a sed of its
  HDFMacros.cmake; hdf5 has the first-class option
  -DHDF5_BUILD_WITH_INSTALL_NAME=ON instead).  Project-specific options
  like HDF4_BUILD_WITH_INSTALL_NAME only fix installed ids, not
  build-tree references.  When adding a cmake dependency, check whether
  any target links a sibling dylib and audit installed dylibs for @rpath
  load commands (build_hdf4's audit is the template).
- jbig is built and linked statically into libtiff.  arm64 SIMD needs no
  nasm (NEON is compiled by clang directly).  Mach-O stripping uses
  `strip -x` (the GNU flags do not exist on macOS).
- Some cmake projects default to building a framework instead of a
  dylib on macOS (libpng produces `png.framework/png`); pass
  `-DPNG_FRAMEWORK=OFF` and check that plain dylibs land in the prefix
  when adding a cmake-built dependency.
- libwebp is built before libpng (it is in the `libtiff_deps` chain),
  so its tools get no png support; accepted, no wheel bundles the webp
  tools and the library does not use png.
- ctypes calls variadic C functions differently on darwin/arm64 when
  `argtypes` is unset: with `argtypes = None`,
  `TIFFGetField(tif, tag, byref(data))` segfaults inside libtiff for any
  tag present in the file.  large_image clears
  `libtiff.TIFFGetField.argtypes` at import, so the pylibtiff wheel
  wraps `TIFFGetField` (see `pylibtiff_libtiff_ctypes_getfield.py` in
  `build_pylibtiff`).  Watch for the same pattern with TIFFSetField and
  TIFFGetFieldDefaulted.
- Glymur is pure python (`py3-none-any`, pip may lowercase the filename
  -- renamed to `Glymur-*` before delocate).  delocate never retags an
  `any` wheel but rewrites the WHEEL file's tags to match the filename,
  so the wheel is renamed to `py3-none-macosx_11_0_arm64` *before*
  `delocate-wheel`, which bundles the tools' dylibs and fixes the WHEEL
  file to match.
- Patch scripts written via unquoted heredocs inside a function body
  carry the script's column-0 layout: indentation of *inserted* code
  lives inside the triple-quoted replacement strings.  Do not
  `sed 's/^    //'` an extracted patch when testing it -- verify with
  `python3 -c "import ast; ast.parse(...)"` on the patched file.
- libtiff is built with autotools; Homebrew installs GNU libtool as
  `glibtool`/`glibtoolize`, so `ensure_tools` creates `libtool`/
  `libtoolize` wrappers in the prefix.
- cyrus-sasl: the darwin-default `macos-framework` feature installs
  outside the prefix, so `build_cyrus_sasl` passes
  `--disable-macos-framework`.  Do not blindly mirror the Dockerfile's
  configure options: 2.1.28's configure has no `--enable-plain`, and
  the openssl/openldap-backed mechanisms are explicitly disabled because
  the prefix has no openssl or openldap.
- The VM's Homebrew autoconf 2.73 bakes `-std=gnu23` into `$CC`
  (C23 removed K&R definitions; cyrus-sasl's md5.c died on it).  Fix:
  pass `-std=gnu17` in CFLAGS -- ours land after `$CC`, the later flag
  wins, and the C23 probe then fails, leaving `$CC` clean.  Any future
  autotools build of pre-C23 code may need the same flag.
- `( some steps ) || die ...` disables `set -e` inside the subshell: a
  failed `make -j` keeps going into `make install` and the log shows two
  failure chains.  The cmake/meson helpers use explicit `|| exit 1` per
  step; keep that in mind for autotools builders.
- The scrubbed PATH has /usr/bin ahead of the prefix, so a prefix-built
  tool does not shadow a same-named CLT tool (bison 2.3 vs 3.8.2).  When
  a configure script resolves a tool by name at configure time, pass it
  explicitly by absolute path.
- meson (pip-installed into the patch python by `ensure_meson`; not in
  the base VM's brew set) is a hazard for prefix isolation: when
  pkg-config misses, meson falls back to its own cmake method or
  `cc.find_library`, both of which search /opt/homebrew -- our cmake
  isolation flags do not apply.  Every meson dependency must resolve
  through the prefix's pkg-config files; glib needs
  `--force-fallback-for=libpcre2-8` (its `cc.find_library` fallback
  would link Homebrew's pcre2).  Meson's pc *discovery* also needs
  PKG_CONFIG_LIBDIR (not just PKG_CONFIG_PATH + ALLOW_SYSTEM_LIBS=0,
  which only filter output): discovery scans pkgconf's built-in default
  dirs, which include /opt/homebrew.  glib's pcre2 and libdicom come
  from meson subproject wraps, like on linux.
- The in-VM test script runs under `set -u`, and an unbound variable
  kills it *silently* (stderr goes to liw_test.log, not streamed; the
  host polls until the full timeout -- looks exactly like a hang).
  Defenses: `rundir` defined at the top of the per-venv loop, and an
  EXIT trap recording a failure the moment the script dies unexpectedly.
  bash keeps only ONE EXIT trap -- a second `trap ... EXIT` replaces
  the first.
- openslide-python's bundled-dylib lookup must run BEFORE upstream's
  `import openslide_bin` fast path in `_load_library`: on macos pypi
  publishes openslide-bin wheels and installs them into every venv, and
  pypi's libopenslide is unpatched (no flattened-MIRAX support), which
  failed the shared suite's mrxs test with a bare "Unsupported or
  missing image file".  On linux this never shows (no aarch64
  openslide-bin wheel on pypi).  Consequence of the shadowing: our
  bundled libopenslide always wins over a user-installed openslide-bin,
  matching the linux wheels.  The phase-1 harness check asserts the
  loaded dylib path is in `.dylibs` so a regression fails loudly.
- cairo's meson disables freetype and fontconfig by default on darwin
  (it prefers CoreText; on linux they are required), so `build_cairo`
  passes `-Dfreetype=enabled -Dfontconfig=enabled` and asserts the
  linkage.  fontconfig is built with `-Dnls=disabled` (no foreign
  libintl).  fontconfig needs `gperf` (falls back to its own meson
  subproject).  fontconfig's `cache-build` option runs `fc-cache -s -f
  -v` on install, which floods the log with ~25k "invalid cache file"
  lines on macOS (it caches the system font-asset stores, whose mtimes
  the asset daemons change under it).  Cosmetic only; meson_build
  filters those three fc-cache-verbose patterns; do not chase it.
- The Dockerfile is deliberate about every flag; check each flag against
  the upstream build system at the pinned version instead of assuming a
  generic default, and only drop a flag with a written reason (jpeg-xl's
  vendored static highway, poppler rejecting MinSizeRel, imagemagick's
  linux-only -lrt, cfitsio's CMAKE_POLICY_VERSION_MINIMUM, hdf5's
  ZLIB_DIR).
- The macOS linker rejects undefined symbols in dylibs where the Linux
  linker allows them.  jxrlib's shared-library rules rely on the Linux
  behavior; the build passes `-Wl,-undefined,dynamic_lookup` to those
  two link rules plus `-Wl,-install_name,<absolute path>` so delocate
  can rewrite them.
- openslide is pinned by commit sha (`openslide-sha`), so it needs a
  full clone -- a sha is not in a `--depth=1` clone.
- `fix_dylib_ids` normalizes install ids to absolute prefix paths AND
  rewrites every load command in its group that references a member by
  a non-absolute, non-@loader_path name (stale build-tree references,
  e.g. b2-built boost dylibs).  It parses ids and load commands from
  `otool -l` via the `macho_fields` helper (not `otool -D`/`-L`), logs
  its action count, and dies with the surviving reference named if a
  rewrite fails.  When a rewritten load command would not fit (the new
  linker ignores -headerpad_max_install_names, so b2-built boost dylibs
  have no slack), it falls back to a same-length path: "@rpath/" and
  "/tmp/b/" are the same length, so "/tmp/b/<name>" (a symlink to
  $LIW_PREFIX/lib, created on demand) replaces the @rpath prefix;
  delocate resolves it through the symlink and rewrites to @loader_path
  inside the wheel.  The build_boost audit dies at boost build time if
  any libboost dylib keeps a load command outside the absolute-prefix /
  @loader_path / system set; the audits accept $LIW_SHORT_LIBDIR/*.
- If a guest dies mid-build, its log dies with it (the host-side copy
  comes back empty).  `tart_build.sh`'s `fail()` restarts a dead VM
  just long enough to retrieve the log, but the kept VM is the fastest
  diagnosis path: `tart run --no-graphics liw_wheels_build`, ssh in,
  read ~/macos_build.log, check `df -h` (disk -> re-provision with a
  larger `--disk`; memory -> smaller `--mem`).
- tart has no balloon driver, so guest file-cache pages stay backed on
  the host for the whole run.  The in-VM test script runs `purge`
  before each python's checks so every python recycles the same guest
  pages, and logs the guest's free-memory percentage into the report.
- glib on darwin does not need util-linux's libmount/libblkid (linux
  only), so the macos build has no util-linux counterpart.
- On macOS the linker maps libz to /usr/lib/libz.1.dylib (always
  present; delocate treats /usr/lib as system).

## Adding a package

1. Find the package's section in the Dockerfile and every dependency
   section it pulls in; note the build order and flags.
2. Add a `build_<dep>` function per new dependency, mirroring the
   Dockerfile's flags, using the helpers (`git_retry`/`fetch`,
   `cmake_build`, `meson_build`, or explicit autotools commands), with
   `skip_if_done`/`done_stamp` stamps.  Install everything into
   `$LIW_PREFIX` only.
3. Add a `build_<package>` function following the `build_pylibtiff`
   pattern: clone at the `versions.txt` pin; apply patches (inline
   python heredocs written into `$LIW_PATCHES`, taking `$LIW_PREFIX`
   from the environment); handle header/metadata generation; commit the
   patches and tag with the combined version
   (`$(v <package>).$(v <bundled lib>)`); loop over `${PYBINS[@]}` with
   `pip wheel --no-deps`; run `delocate-wheel`; `done_stamp`.
4. Wire the package into the main `case`.  Two rules:
   - **Completeness on a fresh VM**: the case must build the package's
     *full* dependency tree, in an order that mirrors the Dockerfile's
     final state -- configure-time feature detection silently drops
     optional libraries that are not installed yet (see `build_openjpeg`
     and its feature assertions).
   - **Feature assertions**: after a dependency-sensitive build, grep
     `otool -L` output of the produced binaries for every optional
     library the linux wheel links, and die if one is missing.  A
     missing optional library otherwise only surfaces as a
     reduced-capability wheel the functional tests may never exercise.
5. Build and test: `LIW_PYTHONS="3.13" bash macos/build_wheels.sh
   <package>` inside the VM, then the full host flow (`tart_build.sh` +
   `test_via_tart.sh`).

Per-package quick reference.  Every builder's comment in
`build_wheels.sh` records the full reasoning at the point of use; these
are the headlines and the traps that are not obvious from the code.

- **Glymur** (`build_libtiff_deps`, `build_lcms2`, `build_libpng`,
  `build_openjpeg`, `build_glymur`): lcms2/libpng exist so the bundled
  `opj_*` tools keep their feature set (`build_openjpeg` asserts the
  linkage); openjpeg is built after libtiff, like the linux final
  state.  Tools go to `glymur/bin` with the `glymur.bin:program`
  wrapper; `config.py` finds the bundled openjpeg in `glymur/.dylibs`
  (linux `Glymur.libs` fallback); dependencies patched to declare
  `packaging` (glymur 0.14.8 imports it without declaring it -- the
  linux wheel carries the same latent issue until rebuilt).
- **pylibmc** (`build_zlib`, `build_bison`, `build_cyrus_sasl`,
  `build_libmemcached`, `build_pylibmc`): cyrus-sasl before libmemcached
  (SASL only compiles in when libsasl2 is found; asserted); bison is
  needed (YACC passed by absolute path).  Plugin set is the
  self-contained one (PLAIN, CRAM-MD5, DIGEST-MD5, LOGIN, ANONYMOUS,
  SASLDB/ndbm, GSSAPIv2 vs the system Kerberos framework); NTLM stays
  enabled but silently drops without an OpenSSL in the prefix -- and the
  pyvips/gdal cases DO build one, so a mixed run (`tart_build.sh gdal
  pylibmc`) would light NTLM up while the default package order (pylibmc
  before pyvips) keeps the self-contained set.  The extension is a
  top-level module (audited separately from the package directory).
- **openslide_python** (libtiff chain, openjpeg, then the openslide
  chain `build_libbrotli` ... `build_cairo`, `build_jxrlib`,
  `build_openslide`, `build_openslide_python`): openslide 4.x is a meson
  build; libdicom comes from its own subproject wrap.  The two repo
  patches are applied with `git am` at the sha pin.  `build_openslide`
  asserts the linked feature set.  lowlevel.py loads the bundled dylib
  from `openslide/.dylibs` *before* the `openslide-bin` import (see
  hard-won details).  Only `slidetool` is bundled.  abi3 selection:
  3.11 + the `*t` pythons; 3.15t gets `cp315-abi3.abi3t` (upstream 1.4.7
  targets the Stable ABI on free-threaded 3.15+; needs setuptools 84.2+
  in build isolation); `wheel_for_python` in tart_build.sh accepts that
  tag for 3.15t+ requests and never accepts a plain `abi3` wheel for a
  free-threaded request.  Linux-side note: the Dockerfile's `_abi3` sed
  is now a no-op and the linux 3.15t wheel comes out `abi3.abi3t`-tagged
  anyway (upstream's supported consume path).
- **pyproj**: deliberately not built (pyproj4 publishes arm64 macosx
  wheels).  The `proj4` library is still built for gdal/mapnik.
- **pyvips** (libtiff chain, openssl+curl, the openslide chain, then
  orc, nifti, lz4, fftw3, libhwy, jpegxl, libimagequant, libexif,
  libarchive, libraw, harfbuzz, pango, librsvg, libde265, libheif,
  poppler, fitsio, hdf5, matio, openexr, libzip, imagemagick, libvips,
  pyvips): the case must mirror the Dockerfile's final state before
  libvips configures.  Headlines: harfbuzz `-Dcoretext=enabled` and
  pango/cairo `-Dfontconfig=enabled` (darwin defaults disable them;
  pango's darwin build hard-requires the CoreText shaper, whose linkage
  lands as CoreText/CoreFoundation/CoreGraphics frameworks); pango
  `--force-fallback-for=fribidi`; librsvg `-Dpixbuf=disabled`; poppler
  gets `-DENABLE_BOOST=OFF`, matching the linux build: the boost use is
  header-only splash-backend code that links nothing into the dylibs,
  our consumers render through poppler-glib's cairo backend rather than
  splash, and poppler's cmake FATAL_ERRORs when ENABLE_BOOST is on but
  boost is missing (the pyvips case does not build boost); hdf5 carries
  the MPI options with `build_openmpi` first (parallel hdf5, like linux)
  and presets ZLIB_LIBRARIES/ZLIB_INCLUDE_DIR (its config-mode zlib find
  provides imported targets but not the module variables its filter code
  consumes; the linux linker tolerates the resulting undefined symbols,
  the macOS one does not); imagemagick `--without-modules` -- deliberate
  deviation: neither delocate nor auditwheel ever bundles dlopened coder
  modules, so the linux wheel's coders cannot load at runtime either,
  while --without-modules compiles every coder in (the full delegate set
  is asserted); curl is built so poppler-glib.pc's "Requires.private:
  libcurl" resolves (without it meson silently drops poppler-glib and
  libvips's pdf loader).  orc is deliberately absent: it is libvips's
  FALLBACK SIMD package, used only when libhwy is absent, and the prefix
  always has libhwy (jpeg-xl needs it) -- the linux build behaves the
  same; the assertion checks libhwy.  The wheel preloads the bundled
  libvips from `pyvips/.dylibs` before importing the cffi extension;
  `build_pyvips` runs the catch-all absolute-install-name audit.
- **GDAL** (its case is self-sufficient on a fresh VM: libtiff chain,
  giflib, openssl+curl, json-c, lerc, jpeg-xl, the openjpeg set, expat/
  xml2/lz4/libarchive, sqlite, proj4, freetype+fontconfig, swig, openmpi,
  boost, minizip, fossil, the geos/spatialite/rasterlite2 tree,
  libgeotiff, fyba, hdf4, hdf5, parallel-netcdf, netcdf, mysql,
  postgresql, libgta, xerces-c, armadillo, blosc, highfive+kealib,
  libde265+libheif, poppler, cfitsio, openexr, libopendrive, libavif,
  gdal, gdal_python): the vips-only tree is deliberately NOT in the
  case.  Headlines: swig is built (GDAL's python bindings are a hard
  SWIG consumer; PCRE2 from swig's own Tools/pcre-build.sh, static
  inside the swig tree); mysql gets -DWITH_SSL="$LIW_PREFIX" (its APPLE
  default hints Homebrew; the custom-SSL machinery copies libssl/libcrypto
  and patches the copy's libcrypto to @loader_path); postgresql
  --without-icu --without-readline; armadillo links the Accelerate
  framework (no Fortran compiler in the VM; a Homebrew gfortran would
  drag its libgfortran into the wheels); OpenEXR needs
  CMAKE_C/CXX_STANDARD_INCLUDE_DIRECTORIES="$LIW_PREFIX/include"
  (GDAL's FindOpenEXR omits the parent include dir, which is implicit
  only because linux's prefix is /usr/local); librasterlite2 needs a
  `<time.h>` include sed and LIBS="-lsqlite3" (its configure never links
  sqlite3; the macOS linker rejects the resulting undefined symbols);
  the gaia-gis fossil clones pass `--admin-user root`.  Skipped
  Dockerfile sections, with reasons in the section comments:
  libtirpc/libnsl (GDAL's cmake has no such check), krb5 (system
  Kerberos), libxcrypt (libSystem provides crypt), lapack (see
  armadillo), ogdi (no OGDI check in GDAL 3.13's cmake), mrsid
  (x86_64-only SDK).  The Dockerfile's -Werror USER_DEFS is NOT passed
  (clang warns on unknown -Wno-* options).  build_gdal mirrors the
  master-at-sha flow and asserts libgdal's linkage against every
  external library the linux wheel links (librttopo only transitively,
  via libspatialite; hdf4 not asserted -- static, absorbed).  The
  PublicDecompWT clone needs the provisioned git-lfs with
  GIT_LFS_SKIP_SMUDGE=1.  `build_gdal_python` bundles the proj/gdal data
  trees and tools into osgeo/ (`osgeo.bin:program` wrapper,
  PROJ_DATA/GDAL_DATA, /etc/ssl/cert.pem), patches
  GDAL_LIBRARY_PATH/GEOS_LIBRARY_PATH into osgeo/__init__.py
  (osgeo/.dylibs first, linux GDAL.libs fallback), strips and re-signs
  prefix dylibs before the wheel build, renames gdal->GDAL, and asserts
  the wheel content.  The shared suite's known-formats assertion (>= 98
  formats, all except mrsid on arm64) is the functional gate for the
  driver set.  boost 1.92: Boost::regex resolves to an INTERFACE cmake
  target (nothing links libboost_regex; all usage instantiates from
  headers -- upstream's supported path; the linux wheel's DT_NEEDED is
  dead weight), so assertions use the tiles plugin's libboost_url/
  libboost_context instead.
- **python_javabridge / python_bioformats** (lead the default PACKAGES
  list so a fresh run fails fast at them): the JVM is Azul Zulu JDK 8
  for macOS aarch64 (Temurin publishes none; `zulu8` versions.txt entry
  via the Azul metadata API).  The darwin code paths make the macos
  wheel *simpler*: setup.py's is_mac branch does not link libjvm
  (mac_javabridge_utils.c dlopens libjvm/libjli by absolute path at
  start_vm), so no preload patch; the linux pyx/jutil/setup.py/
  pyproject patches carry over; locate.py gets a macos-shaped variant
  (find_javahome returns the bundled `javabridge/jvm` tree when present
  -- which also serves the build: no JAVA_HOME needed).  pack200 -G
  --repack carries over; strip-nondeterminism is replaced by
  `ensure_zip_normalizer`'s `normalize_zips.py` (runs on the JDK jars
  before the copy and on each wheel AFTER delocate, which preserves zip
  timestamps).  delocate runs with `-e /javabridge/jvm/`: the JDK dylibs
  resolve their siblings through their own `@loader_path/.` and
  `@loader_path/..` RPATHs, which delocate's rpath sanitizer would strip
  (the linux analogue is the post-auditwheel jvm-tree restore).  The
  bioformats wheel is py3-none-any; tart_build.sh accepts that tag for
  it and test_via_tart.sh's collection takes
  `python_bioformats-*py3-none-any.whl` (a plain `*macosx*` glob would
  silently drop it and skip the javabridge steps).  The harness's
  `test_javabridge.py` check: locate.py resolves
  site-packages/javabridge/jvm, libjvm.dylib present, and after
  start_vm the running JVM's java.home is the bundled tree's jre.
- **mapnik** (gdal case verbatim + `build_icu4c` after the libtiff
  chain + the cairo/harfbuzz chain after gdal): libiconv is deliberately
  NOT built (mapnik's cmake has no iconv check; libxml2 resolves the
  system iconv, allowed by the audits).  icu4c drops the Dockerfile's
  UNISTR_*_EXPLICIT=explicit defines (with them, clang fails to compile
  icu 77-1's tools/ctestfw, which `make` builds even with
  --disable-tests; the linux build passes the same defines with gcc and
  compiles that tool fine, so this is a compiler difference, not a
  version issue) and uses -Wl,-dead_strip instead of -Wl,--gc-sections.
  The defines only affect inline-header conversion strictness, not the
  library ABI, and ICU consumers (mapnik) compile without them on both
  platforms.  ICU's libtool installs bare soname ids, so fix_dylib_ids
  runs before consumers link.  build_mapnik keeps the Dockerfile seds
  with BSD-sed adaptations (`sed -i ''`; embedded literal newlines for
  line-inserting seds), adds -DCMAKE_BUILD_WITH_INSTALL_NAME_DIR=ON
  (plugins/utilities link libmapnik in-tree), drops the inert
  -std=c++17, and keeps the inert -DMAPNIK_USE_PKG_CONFIG=ON for
  parity.  The .input plugins are MH_BUNDLE modules (no install id;
  dlopened by path): the audit checks their @rpath load commands and
  LC_RPATH entries instead of ids, and build_mapnik_python strips their
  RPATHs.  delocate bundles them into mapnik/.dylibs because the
  package carries __init__.py (without it delocate falls back to a
  top-level <dist>.dylibs).  python-mapnik: wheel version 4.3.2.2 via
  `pkgconf --modversion libmapnik`; the macos `__init__.py` patch looks
  in mapnik/.dylibs first with mapnik.libs fallback; the harness reads
  the PROJ string through `p.definition()` (the pinned 4.3.2 has no
  `proj4` property) and greps mapnik-render's output (its --version
  prints to std::clog and returns 1 upstream, like --help).

## Test parity with the linux build

The linux wheels are verified by `test/test_script.sh` (driven by
`test_via_docker.py`, one container per python -- see
`test/python.Dockerfile` and `test/li_script.sh`).  The macOS wheels are
verified by the **same script**; a parallel rewrite would drift from the
authoritative suite.

`test_script.sh` extensions that keep this workable on both platforms
(all no-ops for the linux containers):

- Each `TEST_*` flag combines the interpreter-feature conditions with a
  check that the wheel exists in the wheelhouse; on a partial wheelhouse
  the absent packages' tests are skipped instead of failing to install
  or silently installing a pypi wheel.  `tart_build.sh` hard-fails on
  any missing expected wheel before tests run, so a skip means the
  package was not requested, not that a build silently failed.
- `LIW_PYTHON_BIN_DIR` is prepended to PATH after `. /etc/profile` (the
  macOS harness sets it so `python3` and the script's venv are the
  requested version).
- Sample-file downloads go through a `dl` helper caching in
  `LIW_TEST_CACHE` (the macOS harness would otherwise re-download for
  each of the seven pythons).
- The arch gates treat `aarch64` and `arm64` as the same machine.
- The two converter steps `rm -f` their /tmp destinations first (on
  macos all pythons run in ONE VM; also makes the steps re-runnable),
  and the `test GDAL vsicurl` step retries up to three times (the
  suite's only network-dependent assertion).
- The projected-geotiff `getTileSource` test and the
  large_image_converter-importing steps are gated on `TEST_GDAL`
  (without a gdal wheel, getTileSource falls to the vips source, whose
  projected level structure differs; the converter extra needs the gdal
  source; the unprojected geotiff test stays ungated and passes via
  vips).

The macOS harness (`test_via_tart.sh`) keeps only the platform layers
around the shared script: phase 0 python rebuilding, phase 1 venv
installation with wheel-identity checks, Homebrew-hiding, the `otool`
audits -- scoped to the packages our wheels provide, since the venvs
also contain pypi wheels whose build artifacts are not ours to police --
and the macos-specific checks (per package: the bundled dylib is the one
actually loaded, via `@loader_path` verification or
DYLD_PRINT_LIBRARIES; the bundled `tiffinfo`/`slidetool`/`gdalinfo`/
`mapnik-render` tools run; the pylibmc/gdal/mapnik/javabridge
bundled-library checks assert the paths and data trees described in the
per-package notes).  `li_script.sh` (large_image's own tox suite)
remains linux-only; running it in the VM is a possible later extension.

## Notes and differences from the linux build

- `strip-nondeterminism` and `advzip` normalization is not applied to
  most macOS wheels; reproducibility is a possible follow-up (the
  javabridge/bioformats wheels are the exception).
- The Homebrew-hiding test needs passwordless sudo in the VM
  (/etc/sudoers.d/liw-nopasswd); without it the test falls back to the
  otool audit only and says so in the report.
- The base VM's pyenv pythons link Homebrew libraries, so with Homebrew
  hidden the interpreters themselves cannot be trusted; the test VM
  rebuilds them with a scrubbed environment before testing (phase 0,
  parallelized).  A deferred alternative: uv with prebuilt
  python-build-standalone interpreters (considerations: changes the
  rarely-run provisioning; PBS sysconfig data is unverified against the
  scrub; every requested version including free-threaded must be in the
  PBS catalog; the pyenv-layout helpers would need to move to uv's).
- Free-threaded wheels import with a `RuntimeWarning` about re-enabling
  the GIL (the C extension is not annotated for free-threading); matches
  upstream and the linux wheels.
- AppleClang 21's libc++ specializes __make_transparent<_Tp, less<_Tp>>
  to less<>, so std::set/std::map with a value_type key compares the
  VALUES with less<void> and never calls a std::less<T> specialization
  (libstdc++ does, hence linux-only).  Code ordering key types only
  through std::less specializations dies with "no matching function for
  call to object of type 'const std::less<void>'"; the fix is an inline
  operator< per type delegating to the existing specialization
  (libopendrive's RoadMarksLine, RoadMarkGroup, JunctionLaneLink,
  JunctionPriority; hash/equal_to-only types are unaffected).
- fossil's global `--user` only selects a login; `fossil clone` seeds
  the user table from `--admin-user` (falling back to `$USER`).  The
  Dockerfile's `--user=root` works in the container only because $USER
  is root there; the gaia-gis clones pass `--admin-user root` too.
