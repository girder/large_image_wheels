# Windows x86_64 wheels

This directory builds native Windows win_amd64 wheels for the same packages
as the repository's linux Dockerfile, using a Windows Sandbox as the
isolation boundary.  This file is written to be self-sufficient: if you are
resuming work on this with no prior context, read it top to bottom before
changing anything.

The pipeline is standalone and manages its own sandbox lifecycle the way
`docker build` manages images; it has no dependency on the `agent_*`
sandbox machinery in manthey/utils (that code was only consulted to learn
the platform's properties).  Sandboxes are named `liw_wheels_*`.

## Design

The linux build runs entirely during `docker build`; the later
`docker run` only copies wheels out of the image.  The windows pipeline
keeps exactly that shape:

- **One sandbox run is the image build.**  A single build sandbox installs
  the toolchain, builds every library a wheel needs from source into a
  private prefix, builds and repairs the python wheels, and copies the
  wheels out through a read-write mapped folder.  The sandbox is destroyed
  afterwards; nothing about the build environment persists between runs.
- **The only persistent host-side artifact is a download cache**
  (`<repo>\windows\cache`, gitignored, mapped read-write).
  It holds the toolchain downloads (PortableGit, cmake, ninja, nasm, the
  python.org NuGet packages, the MSVC/Windows SDK payloads from the
  Visual Studio manifest) and source tarballs, so a run does not
  re-download them.  The cache must never contain build outputs,
  stamps, or anything that could make one run's result depend on a
  previous run; it is the analog of docker layer cache, not of a base
  image.  Verification policy, as on macos: full builds from a fresh
  sandbox; the cache is only ever a source of upstream artifacts.
- Every build starts from a pristine sandbox: the sandbox's own installed
  software is by construction empty (Windows Sandbox is a disposable VM),
  and nothing from the host is visible except the four mapped folders
  (repo read-only; cache, wheels, run read-write).
- **Everything is pinned through `versions.txt`**, including the Windows
  toolchain (`msvc`, `winsdk`, `git-for-windows`, `cmake`, `ninja`,
  `nasm`, `delvewheel`, `llvm`, `rust`, `cargo-c`, `swig`, `fossil`,
  `strawberry-perl`, `winflexbison`; tracked by `check_versions.py` like the macos-only
  `bison`/`swig`/`zulu8` entries).  Nothing is fetched as "latest", and
  the GitHub releases API is not used (it rate-limits unauthenticated
  callers, and a NAT'd sandbox shares its address with everything else on
  the host).

### Trust model and the purpose of the isolation

The isolation exists first for **library isolation**, which is what makes
the wheels portable: the build must see only its private prefix and the
pinned sources, exactly like the linux image build and the macos tart
build VM -- anything installed on the build host (conda, vcpkg, another
copy of a library) must be unable to supply headers or link targets.  A
Windows Sandbox gives this for free (its installed software is empty by
construction) and `build_wheels.ps1` enforces the rest: a scrubbed PATH,
private prefix, pinned versions, and bundled DLLs via delvewheel.

The same boundary doubles as the safety story for agent-authored build
code, and it matches the established shape of this repository: on macos
the agent session runs in a tart VM and `tart_build.sh` -- the host-side
orchestrator -- is run by a human on the mac host; on linux the whole
build runs inside `docker build`.  The Windows pipeline has the same
two roles: the agent session runs inside one Windows Sandbox (the agent
safety boundary: a manthey/utils `agent_sandbox.py` sandbox, where the
agent is the non-administrator user `agent` with sshd listening for
the host), and a second, fresh sandbox does the build (the library
isolation boundary).  Because Windows Sandbox cannot be nested, the
agent cannot start the build or test sandbox itself; a human starts
them from the host with `windows\sandbox_build.bat &&
windows\test_via_sandbox.bat`.  Those two entry points and
`sandbox_run.ps1`, which both call, are the only agent-authored code
that runs on the host; treat them as frozen infrastructure -- audited
once, changed only with care.

What the agent sandbox CAN do is compile: `build_wheels.ps1` has a dev
mode (any checkout without the `C:\mnt\repo` mapping) that installs the
same pinned toolchain under `C:\liw_build` without administrator rights
and builds exactly as the build sandbox does.  Dev builds are
rehearsals: they shake out script bugs and build-system surprises before
a host run is spent on them.  They are never the verification -- every
stage is proven by a full build from a fresh sandbox on the host,
followed by the tests, before the next wheel is started (the macos
discipline: one wheel at a time, always building everything).

### The toolchain decision: MSVC

The whole C/C++ dependency chain must use one compiler (C++ ABI is not
mixable across compilers on Windows; mapnik and GDAL have C++ internals).
MSVC was chosen over MSYS2/MinGW-w64 because:

- Official CPython Windows binaries are MSVC-built; extension wheels built
  with MSVC are the canonical, universally-compatible ABI.
- setuptools/pip drive MSVC automatically; no import-library gymnastics.
- The current dependency stack is cmake/meson-dominated, which MSVC
  handles natively.  True autotools projects will need cmake ports or
  small patches, mirroring the kind of patching the linux Dockerfile
  already does.
- MSYS2 would bring its own prebuilt libraries into the sandbox, which is
  exactly the system-library contamination this pipeline exists to
  prevent.

Costs and mitigations of the MSVC choice:

- The compiler is NOT installed with the Visual Studio installer (which
  needs elevation, installs into Program Files, cannot be cached, and
  pins nothing).  The `install_msvc.py` embedded in `build_wheels.ps1`
  (adapted from manthey/utils)
  downloads the MSVC toolset and Windows SDK packages straight from
  Microsoft's VS 2022 manifest at the versions pinned in `versions.txt`
  (`msvc` is the manifest's package version, e.g. `14.44.17.14` = toolset
  14.44 of VS 17.14, which installs as toolset build `14.44.35207`;
  `winsdk` is the SDK build number), checks their hashes, unpacks the
  .vsix zips and the .msi cabinets itself, and writes the compiler
  environment (INCLUDE, LIB, PATH entries) to a JSON file that
  `build_wheels.ps1` loads in place of `vcvars64`.  The ~400 MB of
  payloads live in the cache; a sandbox run only extracts.  Use is
  subject to the VS Build Tools license.
- NASM (libjpeg-turbo/libwebp SIMD) and perl (openssl/curl TLS, later
  GDAL work; PortableGit ships one) must be provided separately; both
  are portable and live in the cache.
- openslide requires the GNU C `cleanup` attribute (its `g_autoptr`
  use), which MSVC lacks, so it alone is compiled with **clang-cl** from
  the pinned LLVM release (`llvm` in `versions.txt`; only `clang-cl.exe`,
  `clang.exe` and the resource headers are extracted from the 900 MB
  tarball, which the cache keeps).  clang-cl is MSVC-ABI compatible: it
  compiles against the same headers and import libraries and links with
  `link.exe`, so the resulting DLL is like every other one in the
  prefix.  The VS manifest's own LLVM component would be the same clang
  at 2.1 GB.
- meson projects (glib, pixman, freetype, fontconfig, cairo, openslide,
  later libvips and more) are built with meson and pkgconf from pypi,
  pinned through `versions.txt` and installed into the patch python
  (`Ensure-Meson`).  pkg-config is scoped to the private prefix
  (`PKG_CONFIG_LIBDIR`), so a dependency is satisfied only by a library
  we built; every cmake and meson install leaves a `.pc` file there, and
  meson maps their `-l` flags to `.lib` files for MSVC.  Projects' own
  subproject wraps are allowed (`--wrap-mode=default`): glib builds
  pcre2, libffi and proxy-libintl into its DLLs, openslide builds
  libdicom into its own, exactly as the linux and macos builds let them.

### Architectures

Only **win_amd64** is built for now.  **win_arm64** (AArch64) is a
deliberate later track, not an omission: Windows Sandbox only runs an
ARM64 guest on an ARM64 host, so it needs ARM64 Windows hardware, and
several build tools are weak or missing on ARM64 (NASM is x86-only; SIMD
paths in libjpeg-turbo/libwebp differ per architecture, as they already do
between linux's x86_64 and aarch64 builds).  When ARM64 hardware is
available, expect `build_wheels.ps1` to grow the same per-architecture
switches the Dockerfile has (`AUDITWHEEL_ARCH` branching).

The legacy `win32` platform tag is deliberately out of scope (modern
python.org pythons are 64-bit only).

### Scope

All packages are in scope, in this order (matching the macos branch):
pylibtiff (first; the pilot for the whole pipeline), Glymur,
openslide_python, pyvips, GDAL, mapnik, javabridge/bioformats, and
pylibmc.  Decisions confirmed with the maintainer:

- GDAL is built here, not taken from pypi (pypi has no GDAL wheels; the
  pypi mapnik wheels carry only a small GDAL subset, so our mapnik build
  is the better one too).
- pyproj is not built (as on linux and macos).
- pylibmc is built: libmemcached talks to a memcached service that need
  not be on the same machine, so the wheel is as useful on Windows as
  elsewhere.  It goes last only because libmemcached has no MSVC support
  story and will need real patching work.
- javabridge needs a JVM strategy on Windows; the linux build's java
  packaging is the reference, and a portable JDK zip staged in the cache
  is the likely starting point.
- The test suite is the shared `test/test_script.sh`, run on Windows under
  PortableGit's bash; it is adapted where Windows needs it rather than
  forked, so that every platform tests the same things.

### Bundled command line tools

The linux and macos wheels ship their tools (`tiffinfo`, `gdalinfo`,
`vips`, ...) as `<package>/bin/<tool>` with an rpath to the wheel's
library directory, and expose each as a console script through a
wrapper module.  Windows has no rpath: an .exe finds its DLLs in its own
directory, the system directories, and PATH, while delvewheel keeps the
bundled (name-mangled) DLLs in the wheel's top-level `<dist>.libs`.  A
fresh Windows also has no `vcruntime140.dll` (python ships one for its
own extensions, in python's directory, which is not on a tool's search
path).  The layout is therefore:

- the real tools live in `<dist>.libs`, next to their DLLs, together with
  an unmangled `vcruntime140.dll` that delvewheel is told to bundle
  (`--include`; delvewheel otherwise leaves it out for cpython wheels);
- `<package>/bin/<tool>.exe` is the **launcher** (a 5 KB C program
  embedded in `build_wheels.ps1`, kernel32 only, no C runtime): it
  locates `<dist>.libs` relative
  to itself, puts it first on PATH, runs the real tool with the unchanged
  command line and the inherited console, and exits with its status.
  `build_wheels.ps1` compiles it once per library directory name
  (`Build-Launcher`) and `Relocate-Tools` rewrites the repaired wheel
  (unpack, move, repack with the `wheel` tool, which regenerates RECORD);
- the console-script wrapper (`<package>/bin/__init__.py`) just runs the
  launcher.

So `<package>/bin/<tool>` works by path from bash (PortableGit's bash
resolves an extensionless path to the `.exe`), from the console script,
and from a bare PATH, exactly as the shared test script expects; nothing
is duplicated.  The VC runtime DLLs that delvewheel leaves out for
cpython wheels (`vcruntime140`, `vcruntime140_1`) are forced in,
unmangled, for the same reason: python ships them beside `python.exe`,
which is not on a tool's search path, and a fresh Windows has no VC++
redistributable.

## Files

Six files, the same shape as the macos directory (one monolithic build
script, one host orchestrator per role, one in-VM test, a README).  As
on linux and macos, everything a component needs -- jxrlib's
`CMakeLists.txt`, the launcher's C source, the MSVC installer, the
per-package python checks, the source patches -- is embedded in the
script that uses it (a PowerShell here-string, the counterpart of the
`cat > file <<'EOF'` blocks in `macos/build_wheels.sh`) and written out
at run time.  Do not add per-component files; they multiply the
maintenance burden and were removed once already.

Host side (run on the host, outside any sandbox):

- `sandbox_build.bat` / `test_via_sandbox.bat` -- the two entry points,
  run from a command prompt with no options, the counterparts of
  `build.sh && test_via_docker.py` and `macos/tart_build.sh &&
  macos/test_via_tart.sh`:
  ```
  windows\sandbox_build.bat && windows\test_via_sandbox.bat
  ```
  Each is one line that runs `sandbox_run.ps1 build` or
  `sandbox_run.ps1 test` and returns its exit code; options are passed
  through.
- `sandbox_run.ps1` -- the host launcher (agent-authored; audit before
  trusting): `build`, `test`, or `cache` as its first argument.  It
  checks the host, generates the sandbox configuration with the folder
  layout below, starts the sandbox, streams the in-sandbox log, waits
  for the exit marker, and reports: for `build` it validates that every
  requested package produced a wheel for every requested python
  (`-Packages`, `-Pythons`, `-MemoryMB`, `-TimeoutSec`); for `test` it
  runs a fresh sandbox with the repository and the wheels mapped
  read-only, prints `report.txt`, and exits with the result (`-Pythons`,
  `-MemoryMB`, `-TimeoutSec`); `cache` pre-warms the download cache in a
  throwaway sandbox (toolchain downloads, the MSVC/SDK payloads, and the
  pythons).  The backends are agent_sandbox.py's: `cli` when `wsb.exe`
  is on PATH (Windows 11 24H2+; headless, `wsb start --config` gives a
  sandbox id, the in-sandbox script runs as SYSTEM through `wsb exec`,
  `wsb stop` tears it down, and several sandboxes can coexist when the
  Windows build allows it, so the agent session can stay up), else
  `file` (the generated `.wsb` is launched like a double-click, the
  script runs from the LogonCommand, one sandbox at a time).  The
  mapped folders: repo read-only at `C:\mnt\repo`; cache at
  `C:\mnt\cache` from `<repo>\windows\cache`; wheels at `C:\mnt\wheels`
  from `<repo>\wheels` -- where build.sh and tart_build.sh put theirs --
  read-write for the build and read-only for the test; the per-run
  exchange at `C:\mnt\run`, from `<repo>\windows\run` for the build and
  `<repo>\windows\test_run` for the test; all gitignored.  The
  configuration it used is saved in the run folder
  (`liw_wheels_build.wsb` / `liw_wheels_test.wsb`).

In-sandbox side (run by the launcher; dev mode in any checkout):

- `build_wheels.ps1` -- the monolithic build, the counterpart of the
  monolithic Dockerfile (and of `macos/build_wheels.sh`).  Parameters:
  `-Packages`, `-Pythons` (a trailing `t` selects the free-threaded NuGet
  python), `-WarmCache` (toolchain and pythons only), `-DevSetup` (dev
  mode only: `-WarmCache` plus the extras development needs that the
  build does not, `requests`/`packaging` for `check_versions.py`; the one
  command that rebuilds a development environment after an agent sandbox
  reset); without parameters it reads `C:\mnt\run\args.json` when the
  launcher wrote one and uses built-in defaults otherwise (the source is
  logged).  It writes its log to `<run>\build.log` and its exit code to
  `<run>\exit_code`, clearing both at startup, so a persistent run folder
  works across runs.  Embedded in it: the logging, `versions.txt`
  lookup, cached-download, NuGet python and PortableGit helpers; the
  launcher's C source (see "Bundled command line tools"); jxrlib's
  `CMakeLists.txt` (same source lists, defines, header layout and
  `libjxr.pc` as its GNU Makefile, so openslide's zeiss-czi-jxr patch
  finds it through pkg-config as on linux); `install_msvc.py`, the
  no-installer MSVC + Windows SDK install (see the toolchain section),
  run with the patch python; and the per-package source patches.
- `test_wheels.ps1` -- the in-sandbox test, the counterpart of the in-VM
  part of `macos/test_via_tart.sh`.  For every python: install the
  wheels by exact version into a clean venv (a pypi fallback would show
  as a version mismatch), run the embedded `check_wheels.py` there with
  a scrubbed PATH, run the shared `test/test_script.sh` under
  PortableGit's bash with a scrubbed PATH and the python under test, and
  run `check_wheels.py` in the venv the suite created.  Every check is
  one `OK:`/`FAIL:` line in `<run>\report.txt`; the log is
  `<run>\test.log`.  It carries its own copies of the helpers it shares
  with the build (as the macos scripts do; a change to one belongs in
  both).  `check_wheels.py` is the windows-specific per-package
  isolation check (the counterpart of the macos harness's otool audit
  and per-package checks), run with a python that has the wheels
  installed and a scrubbed PATH: a PE import audit of every
  `.pyd`/`.dll`/`.exe` our wheel provides (each import must be in the
  wheel, python's DLL, an API set, or in System32 -- the tools nobody
  runs are checked too), the loaded library is the bundled `<dist>.libs`
  copy (through the process's module list), the bundled tools run
  through their wrappers and by path with nothing but the system
  directories on PATH, and the asserted codecs work.  The test writes it
  to the test root, where it can be run by hand after a dev-mode test:
  ```
  C:\liw_build\python\3.13\python.exe -m venv %TEMP%\v313
  set PATH=C:\Windows\System32;C:\Windows;%TEMP%\v313\Scripts
  pip install numpy C:\liw_build\wheels\pylibtiff-*cp313*.whl
  python -I C:\liw_build\test\check_wheels.py pylibtiff
  ```
- `macos/README.md` -- the macos branch's notes; its process lessons
  (verify edits before committing, stage work behind checkpoint runs,
  assert every optional dependency, full fresh builds for verification)
  apply here unchanged.

Shared with the other platforms: `test/test_script.sh` runs on Windows
under PortableGit's bash.  Its Windows accommodations are inline and
small (a venv's `Scripts` directory instead of `bin`; python < 3.12's
`activate` leaves a `C:\` path in PATH that msys cannot split, so the
venv is activated by hand there).  The harness supplies `python3` (the
NuGet pythons have no `python3.exe`) through a one-line shim directory
named by `LIW_PYTHON_BIN_DIR`, the same variable the macos harness uses.

## Usage

On the host (Windows 10/11 with the Windows Sandbox feature enabled),
from a command prompt in the repository (with the `wsb` CLI of Windows
11 24H2+ the agent session can stay up if the Windows build allows more
than one sandbox; without it, end the agent session first):

```
windows\sandbox_build.bat && windows\test_via_sandbox.bat
```

That is the whole workflow: the build in one fresh sandbox (wheels land
in `wheels\`, the log in `windows\run\build.log`), then the tests in
another (the report in `windows\test_run\report.txt`, the log in
`test.log` beside it); all paths relative to the repository.  Each sandbox shuts
itself down at the end of its run, success or failure, as on macos: the
log is already out (streamed to the console and saved in the run
folder), so there is no virtue in keeping it alive -- and it holds the
single-instance slot.  If a guest-initiated shutdown is ever refused (a
first-run property to verify), close the window by hand; never taskkill,
which is indiscriminate and could hit the agent sandbox.

Options when needed (the `.bat` files pass them through):

```
windows\sandbox_build.bat -Packages pylibtiff
windows\sandbox_build.bat -Pythons 3.12,3.13 -MemoryMB 8192
windows\test_via_sandbox.bat -Pythons 3.13
powershell -File windows\sandbox_run.ps1 cache     # pre-warm the download cache
```

Remember that only one sandbox instance may run at a time -- the agent
session is itself a sandbox, so it must be closed before a run -- that
closing the watching console does not stop a run, and that a run
interrupted at the host leaves its sandbox running until it is closed.

### Dev mode (the agent sandbox, or any checkout)

```
# once per sandbox (after a reset): toolchain + pythons under C:\liw_build
powershell -File windows\build_wheels.ps1 -DevSetup

# build one package for one python; log in C:\liw_build\run\build.log,
# wheels in C:\liw_build\wheels
powershell -File windows\build_wheels.ps1 -Packages pylibtiff -Pythons 3.13

# test the wheels in C:\liw_build\wheels; report in
# C:\liw_build\test_run\report.txt, log in test.log beside it, venvs under
# C:\liw_build\test
powershell -File windows\test_wheels.ps1 -Pythons 3.13
```

Dev mode differs from the sandboxes only in where the folders are
(`C:\liw_build\{run,cache,wheels,test_run}` and the checkout instead of
the `C:\mnt` mappings; the test reuses the build's pythons and
PortableGit) and in not shutting the machine down at the end.  Stamps
under `C:\liw_build\stamps` skip finished build steps on reruns
(`LIW_FORCE=1` ignores them); dev builds are for shaking out problems,
and nothing built in dev mode is ever used as a result.  The isolation a
dev test proves is weaker than the sandbox's: the agent sandbox has its
own tools installed, so only the scrubbed PATH keeps them out, whereas
the test sandbox has nothing.

## Iteration protocol

The development loop, as practiced on the macos branch and adapted here
for the single-instance limit:

1. The agent (inside the agent sandbox) makes a change and builds it in
   dev mode until the package builds and its wheel passes the local
   checks; then commits.
2. The human pulls the commit from the agent sandbox into the host
   checkout.  The agent sandbox runs sshd for the host's key, so this is
   a plain fetch (the IP is printed by `agent_sandbox.py` and is in the
   sandbox's run folder):
   `git fetch ssh://agent@<sandbox-ip>/C:/Users/agent/large_image_wheels windows`
   followed by `git merge --ff-only FETCH_HEAD` on the `windows` branch.
3. The human runs `windows\sandbox_build.bat &&
   windows\test_via_sandbox.bat` on the host (with the file backend, or
   a Windows build that allows one sandbox, the agent session has to be
   ended first).
4. The human restarts the agent session and copies the build log
   (`windows\run\build.log`), the test report and log
   (`windows\test_run\report.txt`, `test.log`) into it
   (`agent_sandbox.py cp <file> in:<path>`, or `scp` to the sandbox).
5. The agent diagnoses from the log, fixes, commits; repeat until the
   build passes, then the same loop with test failure logs until the
   tests pass.  Only then is the next wheel started.

With a second Windows machine as the build host, steps 3-4 lose the
stop/restart: the agent sandbox stays up, the build host fetches over
the network (the sandbox's address is on the host's NAT, so the fetch
goes through the agent host or the commit is pushed to a shared remote)
and the log comes back the same way.  Either way the state of the work
is always recoverable from this README plus the repository: nothing
that matters lives only in a session.

Consequences to design around:

- The agent never sees a verification run.  The log is the only feedback
  channel, so `build_wheels.ps1` must stay self-diagnosing: name the
  failing step, log the failing command and its exit code, and fail at
  the first problem instead of continuing past it.
- A restarted agent session may be a fresh context with none of the
  previous session's temp files (and `C:\liw_build` is gone after a
  sandbox reset; `build_wheels.ps1 -DevSetup` brings it back).  All
  durable knowledge
  lives in committed files only -- this README (status and hard-won
  list), the scripts, and the build log the human passes in.  Never rely
  on session scratch state surviving a restart.
- Each host iteration costs a full sandbox run, so batch fixes: a host
  run is only spent on code that already builds in dev mode.

## Resuming with no prior context

If you are a fresh agent instance resuming this work:

1. Read this file top to bottom.
2. Read `git log --oneline -20` on the windows branch to see what changed
   since the state the status section describes.
3. Get the latest build log and test report from the human (they live
   at `windows\run\build.log` and `windows\test_run\report.txt`
   plus `test.log` on the host; the transfer is a copy into one of the
   agent sandbox's mapped folders).  Build errors are logged as
   `error: ...` with the failing script line, and the failing step is
   named in the preceding `=== <step>` line; test failures are the
   `FAIL:` lines of the report, with the detail (pip output, the shared
   suite's output, check_wheels.py's lines) in `test.log` under the
   `=== python <version>` heading.
4. Diagnose against the log, fix, commit, and hand the commit back for
   the next transfer.

## Status

Work in progress (2026-10-28).  Three packages are verified end to end
on the host; the pipeline is exercised in dev mode inside the agent
sandbox before every host run:

- `build_wheels.ps1 -DevSetup` (or `-WarmCache`) installs the pinned
  toolchain (PortableGit 2.56.0.windows.4, cmake 4.4.4, ninja 1.13.2,
  nasm 3.02, MSVC 14.44.17.14 = toolset 14.44.35207, Windows SDK
  10.0.26100.0, the NuGet pythons) without administrator rights.
- `build_wheels.ps1 -Packages pylibtiff` builds the whole libtiff chain
  (zlib, zstd, jbigkit, libwebp, libjpeg-turbo, libdeflate, xz, libtiff
  with every feature asserted through tiffconf.h and the DLL import
  table) and pylibtiff wheels for all seven pythons (3.11-3.15, 3.14t,
  3.15t -- the free-threaded ones from NuGet's `python-freethreaded`),
  each repaired by delvewheel to eight bundled, name-mangled DLLs plus
  `vcruntime140.dll`, with the libtiff tools in `pylibtiff.libs` and the
  launcher in `libtiff/bin` (see "Bundled command line tools").
- **pylibtiff is verified end to end on the host (2026-10-28)**: a
  fresh build sandbox produced the seven wheels and a fresh test sandbox
  passed every check for all seven pythons (the exact-version install,
  `check_wheels.py` -- import audit, bundled DLL identity, tools by
  wrapper and by path with a bare PATH, codec writes -- the shared
  `test/test_script.sh`, and `check_wheels.py` in the suite's venv).
  The free-threaded import carries the GIL re-enable `RuntimeWarning`
  the linux and macos wheels also show.
- **Glymur is verified end to end on the host (2026-10-28)** the same
  way: lcms2, libpng and openjpeg, one py3-none-win_amd64 wheel with the
  bundled openjp2 and the opj/jpeg tools.
- **openslide_python is verified end to end on the host (2026-10-28)**
  the same way: meson/pkgconf and clang-cl as build tools, the glib and
  cairo chains (libbrotli, libexpat, glib, sqlite, libxml2, pixman,
  freetype, fontconfig, cairo), jxrlib through the embedded cmake build,
  openslide with the repository's two patches and libdicom from its
  wrap, and the openslide-python wheels (abi3 from the oldest stable
  python plus the free-threaded ones) with slidetool and the three
  legacy tools bundled -- 31 DLLs in the wheel.
- The windows directory was then consolidated to six files (2026-10-28;
  see "Files"): the per-component files, the shared-function files and
  the checked-in `.wsb` data files were folded into the three scripts.
  The embedded sources are byte-for-byte the former files.  The first
  host run on them (2026-10-28) got through pylibtiff and Glymur and
  failed in glib's pcre2 wrap download with a certificate error that
  had nothing to do with the consolidation (see the hard-won list:
  python's TLS trust in a fresh sandbox); `SSL_CERT_FILE` now points at
  PortableGit's CA bundle.

- The consolidation and the TLS fix were verified together on the host
  (2026-10-28).
- **pyvips builds and passes every dev-mode check for python 3.13
  (2026-10-28)**: the whole libvips tree (lz4, nifti, fftw3, highway,
  openexr, libjxl, libimagequant and librsvg through a pinned rust
  toolchain, libexif through an embedded cmake file, libarchive, LibRaw
  through its nmake makefile, harfbuzz, pango, libde265, libheif, curl
  on Schannel, poppler, cfitsio, hdf5, matio) and libvips with every
  loader the linux wheel has except magick, then one API-mode cffi
  wheel per python with the four vips tools bundled.  The wheel step was
  also rehearsed for all seven pythons (the free-threaded ones
  included).
- **ImageMagick added (2026-10-28)**, closing the one loader gap: bzip2
  and libzip built, ImageMagick compiled from an embedded cmake file
  against the prefix (see the hard-won entry), libvips with
  `-Dmagick=enabled`, `magick` bundled beside the vips tools -- 75 DLLs
  in the wheel.  Dev-mode checks for python 3.13 pass, with the new
  magickload/magicksave round trip and the `magick` tool checks.
  Verified on the host (2026-10-29).
- **GDAL builds and passes every dev-mode check for python 3.13
  (2026-10-29)**: the whole GDAL tree (giflib, OpenSSL, json-c, lerc,
  win-iconv, geos, proj, libgeotiff, minizip, the four gaia-gis
  libraries through embedded cmake files, fyba, hdf4, hdf5, netcdf, the
  MySQL and PostgreSQL clients, libgta, xerces-c, blosc, highfive,
  kealib, libOpenDRIVE, libavif, the MrSID SDK) and GDAL at the master
  commit, with every driver the linux wheel has: the shared suite's
  known-formats check passes, plus the Windows extras (ODBC,
  MSSQLSpatial, PGeo).  One wheel per python with the gdal, proj and
  libgeotiff tools bundled (77 DLLs, 42 tools, 45 MB).  Not yet
  verified on the host.

Next step: the host run of `windows\sandbox_build.bat &&
windows\test_via_sandbox.bat` (five packages by default; the gdal chain
is the long one), then mapnik.

Known gaps, in rough order:

- Wheel timestamp reproducibility (linux uses strip-nondeterminism +
  advzip; macos accepts delocate's output): not yet implemented; the
  macos `normalize_zips.py` approach is the candidate.
- The guest-initiated shutdown (`shutdown /s /t 5` issued by the
  in-sandbox scripts after the exit code) is desk-checked only; if a
  sandbox does not close itself when the run ends, close the window by
  hand and record the finding here.
- CMake's `FindTIFF` (4.4) first tries libtiff's own `tiff-config.cmake`
  and takes the import library from the imported target's
  `IMPORTED_IMPLIB`, `_RELEASE`, `_RELWITHDEBINFO` or `_DEBUG` property;
  our MinSizeRel libtiff exports `_MINSIZEREL`, so `TIFF_LIBRARIES`
  became `bin\tiff.dll` and openjpeg's tools failed to link (LNK1107
  "invalid or corrupt file").  Every cmake build passes
  `-DCMAKE_DISABLE_FIND_PACKAGE_Tiff=ON` (the key is the name as the
  module spells it, `Tiff`), which makes the module find `tiff.lib`.
  Expect the same shape of problem from any Find module that consults a
  config package by property name.
- Pure-python wheels with bundled binaries (Glymur) are built once and
  retagged `py3-none-win_amd64` with the `wheel tags` tool before the
  repair; delvewheel reads the architecture from the platform tag and
  the host validation and the test harness accept that tag for every
  python.  With the `none` ABI tag delvewheel does not know which VC
  runtime the python ships, so `vcruntime140.dll` is a plain dependency
  there: bundled, and kept unmangled with `--no-mangle` to match the
  other wheels.  delvewheel and the `wheel` tool find the dist-info
  through the wheel's file name, and setuptools writes it in lowercase
  (`glymur-0.14.8.1.dist-info`): a wheel renamed to `Glymur-` *before*
  the repair made delvewheel take the dist-info for a package (it
  patched an `__init__.py` into it and left RECORD with a hash of
  itself).  Repair and relocate under the lowercase name (library
  directory `glymur.libs`; the config patch looks for both spellings)
  and rename the finished wheel to `Glymur-` last, which is all the
  linux build's rename does too.
- The C++ packages (pyvips, and GDAL and mapnik to come) import
  `msvcp140.dll`, which delvewheel bundles from the redist directory
  that `--add-path` names (mangled, which is fine for a DLL only other
  DLLs import).  Both `vcruntime140.dll` and `vcruntime140_1.dll` are
  forced into every wheel (cairo was the first to import the `_1`; the
  import audit caught it).
- **pyvips deviations from the linux wheel**, each marked in
  `build_wheels.ps1` where it happens: ImageMagick is compiled from an
  embedded cmake file rather than upstream's MSBuild projects (see the
  hard-won entry; the result links the same delegates as the linux
  build, with every coder inside MagickCore like the macos build, and
  no Magick++); curl on Schannel with no OpenSSL in the tree; hdf5
  without MPI (no OpenMPI on Windows) and without its tools; poppler
  without its C++ wrapper (the one part that hard-requires iconv) and
  with fontconfig font lookup forced (its Windows default is win32);
  libjxl without its tools; orc absent as on macos.  Everything the
  linux wheel's libvips links is required explicitly at configure time
  (`-D<loader>=enabled`) and checked on the DLL's import table.
- **GDAL deviations from the linux wheel**, each marked in
  `build_wheels.ps1` where it happens: no OpenMPI and no parallel-netcdf
  (hdf5 and netcdf are serial); no armadillo (its LAPACK needs a Fortran
  compiler; GDAL's TPS transformer falls back to its own solver);
  xerces-c on its Windows transcoder and libxml2 without iconv, while
  win-iconv (the Windows iconv over the system code pages) serves
  freexl, libspatialite and GDAL's `CPLRecode`; libpq without ICU and
  readline (as on macos) and without lz4/zstd (as the bare linux
  configure); MySQL without `REPRODUCIBLE_BUILD` (on Windows it wraps
  the compiler in a perl launcher); libgeotiff from its cmake build
  (the autotools one's reason, rasterlite2's configure, does not apply);
  rttopo at a pinned master commit (`librttopo-sha`) rather than the
  1.1.0 tag, because spatialite's trunk calls `rtt_tpsnap`, which only
  master has (the linux link tolerates the undefined symbol; MSVC's does
  not); no PCRE2 (the linux base image's would give sqlite a REGEXP
  function; see the glib pcre2 leak below); the MrSID SDK is Extensis'
  win64 vc17 build, its version pinned in `build_wheels.ps1`
  (`$script:MrsidVersion`) the way the Dockerfile pins its rhel tarball,
  since no listing exists for `check_versions.py` to track.  Everything
  else GDAL's cmake can detect is required to resolve from the prefix
  and checked on `gdal.dll`'s import table.
- `check_versions.py` runs on Windows as anywhere else (`uv run
  check_versions.py <names>`: it carries PEP 723 metadata; or a python
  with `requests` and `packaging`).  It used to prefix its `git
  ls-remote` calls with `timeout 15`, which on Windows resolves to
  Windows' timeout.exe no matter what PATH says (CreateProcess searches
  System32 before PATH); it now passes `timeout=15` to subprocess.
- libxml2 is built without iconv (Windows has no system iconv; linux
  and macos use theirs).  libxml2 handles UTF-8/16 and ISO-8859-x on its
  own; if a later consumer needs other encodings through libxml2, build
  libiconv (`versions.txt` has a pin) and turn `LIBXML2_WITH_ICONV` on.
- `test/test_script.sh`'s GDAL+pyvips converter steps wrote to
  `/tmp/outfloat*.tiff`, which python on Windows reads as `C:\tmp\...`
  (absent); every python failed there on the first five-package host
  run.  They now write into the working directory, like the suite's
  other outputs.
- No psutil wheel exists for cp315t on pypi, and `large-image[converter]`
  requires psutil; the test sandbox has no compiler (by design), so on
  3.15t that install fails and the suite stops.  This is upstream lag,
  not our build: it resolves itself when psutil publishes the wheel.

## Hard-won details (do not lose these)

- The generated `.wsb`'s LogonCommand runs as the **elevated**
  WDAGUtilityAccount (file backend); `wsb exec -r System` runs the
  script as SYSTEM (cli
  backend, whose profile is `C:\Windows\system32\config\systemprofile`
  and whose TEMP is `C:\Windows\Temp`).  Nothing in the pipeline needs
  either: the toolchain is portable and the agent sandbox's
  non-administrator `agent` user runs the identical install in dev mode.
- The first host run (2026-10-28) died at once with "the sandbox did not
  start": the file-backend launcher looked for a `WindowsSandbox*`
  process on its first loop iteration, before the shell had spawned
  one.  agent_sandbox.py allows a minute; the launcher now allows 90
  seconds, and on a 24H2 host it uses the `wsb` CLI instead, which
  reports the sandbox id synchronously.
- The first host test run stopped mid-way: the launcher's log streaming
  hit a sharing violation opening `test.log` through the mapped folder
  (the sandbox's `Add-Content` held it), the exception reached the
  cleanup, and the cleanup stopped a healthy sandbox.  Since then the
  streaming retries on the next poll, the launcher trusts only the exit
  marker, tolerates `wsb exec` returning, requires three missed `wsb
  list` polls, gives up only after 30 silent minutes or the timeout, and
  leaves a failed sandbox running for inspection.
- Reading a log through a mapped folder while the sandbox appends to it
  fails intermittently with "being used by another process", even with
  `FileShare.ReadWrite` on the host side.  Anything in the host loop
  that touches the run folder must tolerate a failed read and retry on
  the next poll; an uncaught exception there is what stops a run.
- **A fresh sandbox's certificate store has about sixteen roots**, and
  github.com's is not one of them.  Windows fetches a missing root on
  demand, but only for Schannel clients (curl.exe, Invoke-WebRequest);
  python verifies with OpenSSL against the store as it is, so meson's
  wrap downloads (glib's pcre2, libffi, proxy-libintl; openslide's
  libdicom) and `install_msvc.py` depend on which roots the store
  happens to hold.  The first host runs passed because a curl download
  from github.com (cmake, ninja, the LLVM tarball) had installed the
  root before meson ran; the first run with every download cached
  failed glib's pcre2 wrap with `CERTIFICATE_VERIFY_FAILED`.
  `Ensure-Toolchain` now points `SSL_CERT_FILE` at PortableGit's
  `ca-bundle.crt` (the curl bundle git itself uses, pinned with git),
  which OpenSSL loads in addition to the store.  Any new download path
  that is not curl.exe must verify against that bundle or Schannel.
- Downloads: curl's `--retry` does not retry TLS connection errors
  (exit 35), which the host's sandbox hit on the seventh download in a
  row; `--retry-all-errors` does.  Downloads land under a temporary name
  and are renamed on success, so a failed download is never mistaken for
  a cached file (and an archive that does not expand is removed from the
  cache).
- The first host run put its outputs in a `liw_wheels` *sibling* of the
  repository (reported with the drive letter in the case the command
  line used), which was not where anyone looked for them.  Outputs now
  live under the repository like on linux and macos: the wheels in
  `wheels\`, the windows-specific cache and run exchanges in
  `windows\{cache,run,test_run}` (all gitignored), and the launchers
  take the repository path's on-disk spelling (`Get-Item`).
- `a.bat && b.bat` at an interactive prompt runs `b.bat` even when
  `a.bat` ended with `exit /b 1` (reproduced with cmd reading its
  commands from a file; `cmd /c` does not show it).  Ending the batch
  with `cmd /c exit %ERRORLEVEL%` makes `&&` honor the status.  The
  launchers guard the chain too: the build removes the requested
  packages' old wheels first, and the test refuses when the build's
  `exit_code` is not 0.
- **delvewheel mangles DLL names** (`tiff-<sha256 prefix>.dll` in
  `pylibtiff.libs`) and rewrites the import tables of the wheel's
  binaries to match; the content hash means identical DLLs in two wheels
  share a name and differing ones never do.  Keep it that way: the
  Windows loader resolves an import by base name against the modules
  already loaded in the process, so two unmangled `tiff.dll` copies in
  two wheels would silently share whichever loaded first -- this is the
  hazard the linux BUILD_ID salt exists for, solved here by delvewheel's
  default.  Code that looks bundled libraries up by name must match the
  mangled prefix (`startswith("tiff")`).
- The system `tar` (bsdtar) fails on an archive that contains a symlink
  (libexpat's `README.md -> expat/README.md`): creating a symlink needs
  a privilege the sandbox accounts lack, and the extraction ends with
  "Error exit delayed from previous errors".  Tarballs are extracted
  with PortableGit's msys tar instead, with `MSYS=winsymlinks:lnk` so a
  symlink becomes a `.lnk` shortcut (msys's default copies the target,
  which fails when the target comes later in the archive); it wants
  POSIX paths (`/c/...`; a Windows path makes it try to reach a host
  named `C`) and gzip beside it on PATH (`usr\bin`).
- libpng's and expat's cmake builds install no pkg-config file on
  Windows, so `dependency('libpng')` in cairo found nothing and meson
  silently built cairo's own libpng subproject, whose `png16-16.dll`
  and `libpng.pc` (1.6.47) were then installed over ours (1.6.59) --
  the cairo link assertion caught it.  `Write-PkgConfig` now writes the
  missing `.pc` files, and every meson build runs with
  `--wrap-mode=nofallback`: a dependency pkg-config cannot satisfy fails
  the configure step; only the wraps the linux and macos builds also
  rely on are forced (`--force-fallback-for`: glib's pcre2, libffi and
  proxy-libintl; openslide's libdicom and uthash).  glib's libffi and
  intl wraps build DLLs (`ffi-8.dll`, `intl-8.dll`), pcre2 a static
  library; all of them land in the prefix and get bundled like ours.
- jxrlib under MSVC/clang-cl (the embedded `CMakeLists.txt`): its ANSI
  header sizes
  the pointer-width integers by `__LP64__`, which MSVC never defines
  (define it for 64-bit builds, in the `.pc` Cflags too, since
  consumers compile the same headers); `JXRMeta.h` knows
  `__in_win`/`__out_win` only through its own `wmsal.h`, which
  `wmspecstring.h` skips once MSVC's `specstrings.h` has been included
  (openslide includes `windows.h` first), so the header is patched to
  define them from `__in`/`__out` when missing; and the constants a
  consumer compares against are *data* exports of `jxrglue.dll`, which
  MSVC cannot import without `dllimport` declarations (it thunks
  functions, not data) -- the `DEFINE_GUID` ones get local copies in
  openslide's jxr decoder through `INITGUID` (the usual Windows idiom; a
  Windows-only source patch in `build_wheels.ps1`), and the plain
  `extern const PKIID` ones are exported explicitly (cmake's
  `WINDOWS_EXPORT_ALL_SYMBOLS` skips read-only data) and get a
  `dllimport` declaration in the installed `JXRGlue.h` that only
  `libjxr.pc`'s `-DJXR_DLL_IMPORT` enables.
- meson with clang-cl guesses `lld-link` as the linker and dies with a
  bare `FileNotFoundError` when it is absent; `CC_LD=link` selects
  MSVC's linker for meson's own link steps.  It does not reach the
  checks meson links through the compiler driver (the sanity check,
  `has_function` probes), which use clang-cl's *own* default linker:
  link.exe up to LLVM 21, **lld-link from LLVM 23** ("Compiler clang-cl
  cannot compile programs" was the whole message when the pin moved to
  23.1.4; `clang-cl -v` shows `"lld-link"` and "program not
  executable").  `CFLAGS=-fuse-ld=link` makes the driver use link.exe
  too (with `-Wno-unused-command-line-argument`, since the flag is
  link-time and clang-cl would warn on every compile).  Diagnosed by
  rerunning meson's sanity command by hand with each clang-cl; a sanity
  check run without `--buildtype=release` links `/MDd` and then fails
  for a different reason (no debug CRT in the toolchain), so reproduce
  with the build's flags.
- The pypi `pkgconf` wheels trail pkgconf's own releases (the linux
  build's `pkgconf` pin is an upstream tag); the Windows build pins the
  pypi version separately as `pkgconf-pypi` in `versions.txt`.
- Two wheels that bundle the same library get the same mangled file
  name (the hash is of the content), and when each loads its own copy
  by full path the process holds two modules of that name (the loader
  matches full-path loads by path, name-only loads by base name).  That
  is the intended isolation, not a leak: `check_wheels.py` accepts a
  loaded copy from any wheel's `.libs` directory and fails only on a
  copy from anywhere else.  Its import of every known package before
  the checks is what made glymur's libtiff show up during the pylibtiff
  check.
- **MSVC's linker records no import for a DLL whose symbols are
  unused**, so delvewheel (which only follows import tables) saw no
  dependencies in the pylibtiff wheel: `tif_lzw` links `tiff.lib` but
  imports nothing from it.  On linux the `-ltiff` DT_NEEDED survives and
  auditwheel bundles libtiff through it.  Libraries a package loads with
  ctypes must be forced in with `--include <name>.dll`, and
  `--analyze-existing-exes` vendors the bundled tools' dependencies.
  Assert the wheel's content after repair (`Assert-WheelContains`); the
  unrepaired wheel is a silent isolation failure, not an error.
- Bundled .exe tools resolve their (mangled) DLL imports through the
  normal search order -- the exe's directory, then PATH -- and a child
  process does not inherit `os.add_dll_directory`; a fresh Windows has
  no `vcruntime140.dll` outside python's own directory, and delvewheel
  leaves that DLL out for cpython wheels unless `--include`d (it then
  copies it unmangled, which is what the tools need).  Hence the layout
  in "Bundled command line tools": real tools and `vcruntime140.dll` in
  `<dist>.libs`, the launcher in `<package>/bin`.  A tool that fails to
  load a DLL exits with `STATUS_DLL_NOT_FOUND`, which bash reports as
  status 127 with no message -- indistinguishable from "command not
  found" until the DLL is put on PATH.
- PortableGit's bash resolves an extensionless path (`.../bin/tiffinfo`)
  to the `.exe`, so the shared test script's direct tool invocations
  work unchanged.  Its `/etc/profile` sets `MSYSTEM=UCRT64` and puts
  `/ucrt64/bin` (PortableGit's own DLL collection) on PATH; harmless
  for mangled names, but the sandbox PATH is scrubbed to
  `usr\bin` + System32 before bash starts and nothing else is on it.
- A PowerShell function returns every object its commands emit: `& cl`
  printing the source file name made `Build-Launcher` return an array
  (the first `Relocate-Tools` copied `launcher.c` as the tool).  Native
  commands inside functions go through `Run-Logged` or `| Out-Null`.
- Line endings: a Windows checkout with `core.autocrlf=true` (the agent
  sandbox's setting, probably the host's too) has `test/test_script.sh`
  with CRLF endings, which bash rejects (`$'\r': command not found`);
  `test_wheels.ps1` runs an LF copy from the test root instead of the
  mapped file.  The in-sandbox `.ps1` files are read by PowerShell and
  the `.bat` files by cmd, which accept either.
- The shared script's `pip install --upgrade pip` fails on Windows for
  pythons whose venv pip is older than pypi's (`pip.exe` cannot replace
  itself: "To modify pip, please run python -m pip"); the script uses
  `python -m pip` now, which is the same thing everywhere else.  The
  `sample.czi` read is gated on the libraries that can read a czi
  (openslide, bioformats with javabridge, or vips): it was gated on the
  architecture only, which never mattered with every wheel present.
- Console-script names come from the files in `<package>/bin`, which
  carry `.exe` on Windows: naming an entry point `tiffinfo.exe` makes
  pip generate `tiffinfo.exe.exe`, which CreateProcess still finds for
  `tiffinfo.exe` (so a python-side check passed) while bash's PATH
  lookup for `tiffinfo` does not.  The setup.py patch strips the
  extension, and `check_wheels.py` insists on the exact file name.
- Build stamps: a step's stamp is removed the moment the step starts
  (`Skip-If-Done`), because a forced rebuild that failed in pylibtiff
  left the previous run's stamp behind and the next run skipped the
  step entirely.
- PowerShell: at the top level of a script the parameters are
  script-scope variables, so `$script:Pythons = <default>` silently
  overwrote `-Pythons`; parameter values are copied aside first.
  PowerShell does not expand `$var` inside a bare `-DNAME=$var` token
  (cmake configured zlib into a literal `$LIW_PREFIX` directory); quote
  such arguments.  Paths given to cmake as cache variables must use
  forward slashes: a backslashed `JBIG_LIBRARY` reached libtiff's
  `check_symbol_exists` try_compile as a string with escape sequences.
  Native stderr redirection (`cmd 2>&1`) is a terminating error under
  `$ErrorActionPreference = 'Stop'` in Windows PowerShell 5.1 (so is a
  native command that merely writes to stderr when redirected);
  `Run-Logged` relaxes the preference around such commands.
- DLL names as the chain's cmake builds produce them on Windows
  (observed): `z.dll` (zlib 1.3.2's `OUTPUT_NAME z`; `zlib1.dll` is
  history, and the static `zs.lib` is turned off so no consumer can pick
  it), `zstd.dll`, `jpeg62.dll` + `turbojpeg.dll`, `libwebp.dll` with
  `libwebpmux/decoder/demux.dll` and `libsharpyuv.dll` (libwebp builds
  static libraries unless `BUILD_SHARED_LIBS=ON`), `deflate.dll`,
  `liblzma.dll`, `tiff.dll`, `lcms2.dll` (lcms2's own cmake build,
  `LCMS2_BUILD_SHARED`; the linux build uses autotools), `libpng16.dll`,
  `openjp2.dll` (openjpeg 2.5 names its options
  `BUILD_SHARED_LIBS`/`BUILD_STATIC_LIBS`; the `BUILD_SHARED`/
  `BUILD_STATIC` spellings the linux and macos builds pass are ignored
  there, and `BUILD_THIRDPARTY=OFF` keeps the tools on our libraries).  libtiff's `tiffconf.h` records JBIG as a
  bare `#define JBIG_SUPPORT` (no value) and does not mention ZSTD/WEBP
  at all (they are in the internal `tif_config.h`); the feature
  assertion reads tiffconf.h for ZIP/JPEG/JBIG/LIBDEFLATE and the DLL
  import table for the rest.
- `versions.txt`'s `msvc` entry is the VS manifest's package version
  (`14.44.17.14`), which is what `install_msvc.py` selects by; the
  toolset's own build number (`14.44.35207`) names the install
  directory.  `install_msvc.py` records the pins it was given in its
  `msvc_env.json` so a cached install is reused only at the pinned
  versions.
- The GitHub releases API answers 403 to the sandbox's NAT address
  within minutes of use; every download URL is derived from a
  `versions.txt` pin instead (PortableGit's asset name comes from the
  `git-for-windows` tag: `2.56.0.windows.4` -> `PortableGit-2.56.0.4`,
  `.windows.1` -> no suffix).
- The NuGet `python` package names its interpreter `python.exe`; the
  `python-freethreaded` package names it `python3.14t.exe` (the builder
  copies it to `python.exe` in the version directory).
- Windows Sandbox cannot be nested: the agent session runs inside one
  sandbox and the build runs in a separate sandbox started by a human on
  the host; the agent can write and review the scripts but can never
  start or observe a build itself.  Both failure modes have been seen:
  a WindowsSandbox.exe launched inside the agent sandbox hangs forever
  with no window and no log (the guest has no virtualization to give),
  and a launch from the host while the agent sandbox is running is
  refused at the single-instance gate.  The workflow is therefore
  serial: finish and commit agent-side work, end the agent session, run
  the build on the host, read the log and wheels, then restart the agent
  session.  Plan iterations accordingly -- each build run is a batch.
- Windows Sandbox allows only one running instance at a time ('Only one
  running instance of Windows Sandbox is allowed', seen on the host).
  The running instance may be the agent session itself: never kill
  running sandboxes blindly -- end the agent session deliberately before
  a build run.  sandbox_run.ps1 refuses to start while any sandbox is
  running and says so.
- Mapped folders are slow for I/O-heavy work: the build happens in
  `C:\liw_build` (sandbox-local disk); mapped folders only carry
  downloads in and wheels/logs out.
- The LogonCommand cannot take arguments comfortably; the host passes
  run parameters through `C:\mnt\run\args.json` instead.
- DLL search on Windows has no rpath analog: bundled DLLs are found via
  delvewheel's `_delvewheel_patch` (which adds the `.libs` directory to
  the DLL search path at import time) and via `LoadLibrary` on absolute
  paths in the pylibtiff patch.  Any test-phase audit must scrub PATH
  rather than hide directories, because a stray directory on PATH is the
  one way a system library could shadow a bundled one.
- C++ ABI is not mixable across compilers on Windows: every library and
  every extension in a wheel must be built by the same MSVC toolset.
- **rust** (librsvg, libimagequant) is installed from the pinned
  release's standalone `rustc`, `cargo` and `rust-std` tarballs merged
  into one directory (what rustup's install does; rustup itself is
  unpinned), and cargo-c is the prebuilt MSVC binary of its pinned
  release; both pins come from `check_versions.py` (`rust`, `cargo-c`).
  rustc links with the MSVC `link.exe` from PATH and takes pkg-config's
  `-l` names literally: `-lpng16` means `png16.lib`, where meson would
  also accept `libpng16.lib`, so the libpng and libxml2 builders install
  both spellings of their import libraries (rsvg-convert failed on
  `png16.lib` and `xml2.lib` first).  cargo-c names its MSVC import
  library `<name>.dll.lib`, so `imagequant.lib` is a copy; curl's cmake
  names its `libcurl_imp.lib` unless `IMPORT_LIB_SUFFIX` is emptied, and
  `curl.lib` is a copy for the .pc's `-lcurl`.
- librsvg's meson build wraps the rust static library in a DLL with
  `link_whole`; under MSVC that is `/WHOLEARCHIVE`, which forces in every
  member of the archive, including the raw-dylib import stubs the
  windows crates embed -- two crates carry kernel32's, so link.exe dies
  with LNK2005 on `__IMPORT_DESCRIPTOR_kernel32`.  The exports come from
  a generated `.def`, and a `.def` makes the linker pull each exported
  symbol's object by itself, so the Windows patch changes that one
  `link_whole` to `link_with` and the DLL is the same.
- `PKG_CONFIG` must be the pkgconf binary the pypi package embeds
  (`pkgconf\.bin\pkgconf.exe`), spelled with forward slashes.  The
  `Scripts\pkgconf.exe` launcher runs `python -m pkgconf`, which fails
  inside pip's build isolation (no pkgconf module there), so pyvips's
  pkg-config probe for vips came back empty and its setup.py silently
  fell back to an ABI-mode pure-python wheel (that fallback is now
  patched out: API mode or a failed build).  The `pkgconfig` python
  package then splits its command with shlex in POSIX mode, which eats
  backslashes.
- cmake builds its try_run probes in the Debug configuration unless
  `CMAKE_TRY_COMPILE_CONFIGURATION` says otherwise, and Debug means the
  debug CRT (`-MDd`), whose DLLs no redistributable ships: the probes
  compile and then fail to run.  Every project's probes had been doing
  that silently; hdf5's `InitOnceExecuteOnce` probe was the first whose
  failure was fatal ("thread-safe option requires Win32 threads").
  `Cmake-Build` sets the configuration to MinSizeRel for all of them.
- hdf5's config-mode zlib find (`COMPONENTS static shared`) finds our
  `ZLIBConfig.cmake` and then dies on the static component a shared-only
  zlib never installed; `-DZLIB_PACKAGE_NAME=<nothing matches>` makes
  it fall through to the module find and the preset
  `ZLIB_LIBRARY`/`ZLIB_INCLUDE_DIR`.  poppler rejects MinSizeRel
  (Release, as on linux), runs `glib-mkenums` (a python script from
  glib's install) through `GLIB2_MKENUMS_PYTHON`, which must name the
  patch python, and only its C++ wrapper needs iconv.  libvips's fuzz
  targets (test executables, built unconditionally) do not compile
  under MSVC and are dropped by the Windows patch; libvips asks for
  `libraw_r`, and LibRaw's `Makefile.msvc` DLL (built without
  `LIBRAW_NOTHREADS`) is that flavor, so both .pc names describe it.
  libexif builds from an embedded cmake file (its own build is
  autotools; MSVC lacks `ssize_t`, which the generated config.h
  supplies); LibRaw builds through its own `Makefile.msvc`, which
  installs nothing (its `.pc` must say `-I${includedir}/libraw`, as
  LibRaw's own does: ImageMagick's dng coder includes `<libraw.h>`).
- **ImageMagick** has no cmake or nmake build.  Upstream's Windows route
  (github.com/ImageMagick/Windows) is a project generator,
  `Configure.exe`, that writes MSBuild projects for ImageMagick *and for
  ImageMagick's own forks of every delegate library* (libpng, libtiff,
  libjpeg-turbo, librsvg, ... some forty repositories), all built from
  source in one Visual Studio solution.  That needs MSBuild, which the
  installer-free toolchain does not have, and it would put a second copy
  of each library into the wheel beside the one libvips links -- the
  opposite of parity.  What the generated projects actually do is small:
  compile `MagickCore/*.c` with the coders, `MagickWand/*.c` and
  `utilities/magick.c` **as C++20** (`CompileAsCpp`; the headers use
  `[[fallthrough]]` under `_MSC_VER`, and the ABI stays C through their
  `extern "C"` blocks), with `_MAGICKLIB_` and `_WIN32_WINNT`, a
  generated `magick-baseconfig.h` and `version.h`.  `Build-Imagemagick`
  does that from an embedded cmake file against this prefix's libraries
  (each delegate a required pkg-config module, so a missing one is a
  configure error; jbigkit by `find_library`).  The base config is the
  Configure release's own template (`Configs/MagickCore/
  magick-baseconfig.h.in` from the release the source pins in
  `.github/build/windows/download-configure.sh`, so no extra version
  pin) with its `$$CONFIG$$` marker replaced by the option block
  Configure.exe writes, using the linux configure's defaults: Q16, HDRI,
  32-bit channel masks (upstream's x64 projects use 64, which is why
  they need C++), DPC, deprecated API excluded; `version.h` is
  `version.h.in` filled from `m4/version.m4` the way configure.ac does
  it.  OpenMP is on (`/openmp`, as the linux `-fopenmp`), which makes
  MagickCore import `vcomp140.dll` from the redist's OpenMP directory
  (next to the CRT one; delvewheel bundles it, mangled, like
  `msvcp140.dll`).  Two things upstream's forks carry as patches had to
  be redone: LibRaw's C++ headers against nt-base-private.h's
  `read`/`write`/`tell` macros (undefined before `<libraw.h>` in the dng
  coder, as upstream's LibRaw fork does in `libraw_datastream.h`), and
  bzip2 (upstream vendors it; here it is seven source files through an
  embedded cmake file, exports from the tarball's `libbz2.def` minus its
  `LIBRARY LIBBZ2` line, which would otherwise make the import library
  name `LIBBZ2.dll`; import library `bz2.lib`, the name `FindBZip2`
  wants, so libarchive now links it too).  libzip (ImageMagick's ora
  coder) is a plain cmake build.  The DLLs are `MagickCore-7.Q16HDRI.dll`
  and `MagickWand-7.Q16HDRI.dll`, the import libraries the same stems,
  and the `.pc` files carry the same three `-D` flags as on linux.
  ImageMagick's zstd delegate only names zstd in the version string
  (libtiff does the zstd work), so link.exe records no zstd import where
  autotools' `-lzstd` always shows -- the dependency assertion does not
  ask for it.  MagickCore's emf coder imports `gdiplus.dll`, a Windows
  component that lives in WinSxS rather than System32; delvewheel does
  not know it as a system DLL and copied the sandbox's into the wheel
  until `--exclude gdiplus.dll` was added.
- DLL names in the libvips tree, as the builds produce them: `vips-42.dll`
  (+ `vips-cpp-42.dll`; import library `vips.lib`), `rsvg-2-2.dll`,
  `heif.dll`, `libde265.dll`, `jxl.dll`, `imagequant.dll`, `exif.dll`,
  `archive.dll`, `libraw.dll`, `libmatio.dll`, `hdf5.dll`, `cfitsio.dll`,
  `fftw3.dll`, `hwy.dll`, `OpenEXR-3_5.dll`, `niftiio.dll` + `znz.dll`,
  `poppler.dll` + `poppler-glib.dll`, `libcurl.dll`, `harfbuzz.dll`
  (15.x also installs -subset, -cairo, -gobject, -gpu, -raster and
  -vector DLLs), `pango-1.0-0.dll` + `pangocairo`/`pangoft2`/`pangowin32`,
  `fribidi-0.dll` (pango's wrap), `lz4.dll`, `MagickCore-7.Q16HDRI.dll`
  + `MagickWand-7.Q16HDRI.dll`, `zip.dll`, `bz2.dll`.  The pyvips wheel
  bundles 75 of them plus `msvcp140.dll` and `vcomp140.dll`.
- `Cmake-Build` runs cmake through `Run-Logged` so its stderr ("Could
  NOT find ...", configure errors) reaches the log; it did not at
  first, and poppler's first failure was invisible from the log.
- **The GDAL tree** (`Build-Giflib` through `Build-GdalPython`).  The
  Windows-only build tools, all pinned through `check_versions.py` and
  never bundled: swigwin (`swig`), fossil's prebuilt w64 binary
  (`fossil`; the gaia-gis sources are fossil repositories, cloned with
  `--admin-user root`, and fossil reports progress on stderr, so it runs
  through `Run-Logged`), Strawberry Perl's portable zip
  (`strawberry-perl`, the tag's digit string: OpenSSL's `Configure` and
  PostgreSQL's meson are perl, and both refuse PortableGit's msys perl;
  only its `perl/` tree is extracted), and winflexbison (`winflexbison`,
  for PostgreSQL; mysql's client-only build turned out not to need
  bison).  The source toggle: `$script:GdalFromRelease` is the
  Dockerfile's `if false` (release tag `gdal` vs. master at `gdal-sha`),
  and master is fetched by sha (GitHub serves it; no 1000-deep clone)
  with `core.longpaths` on, since the autotest tree exceeds 260
  characters.  Per library: OpenSSL (`VC-WIN64A`, nmake, single
  threaded, zlib through `--with-zlib-lib`) installs no `.pc` files on
  Windows, and the ones written here must name both libraries in
  `Libs:` (`Write-PkgConfig`'s Requires is the private kind, and
  PostgreSQL's meson link check found nothing to link).  GEOS installs
  only its cmake config on Windows; a `geos.pc` is written for rttopo
  and spatialite.  PROJ's `proj.pc` says `-lproj_9` (the DLL's stem,
  `proj_9.dll`) while the import library is `proj.lib`; a copy under
  the `.pc`'s spelling.  libgeotiff names its import library
  `geotiff_i.lib` (GDAL's FindGeoTIFF knows), copied to `geotiff.lib`
  for rasterlite2; its cmake links jpeg/zlib into the utilities only.
  minizip-ng has no export decorations: `CMAKE_WINDOWS_EXPORT_ALL_SYMBOLS`,
  or the DLL exports nothing and no import library appears.  rttopo
  likewise (and with `/OPT:REF` an export-less DLL loses its whole
  body, which showed as "does not depend on geos_c"); its configure
  outputs (`rttopo_config.h` with `RTGEOM_GEOS_VERSION`,
  `RTGEOM_DEBUG_LEVEL`, and `librttopo_geom.h` from its `.in`) are
  written by the embedded cmake file.  freexl, rttopo and spatialite
  take their source lists from their `makefile.vc` (`gaia.cmake`'s
  parser), and spatialite's list predates two of its libraries
  (`sqlite_bulk_rtree`, `connection_cache`; `src/Makefile.am`'s LIBADD
  is the reference).  rasterlite2 has no MSVC makefile: its sources
  come from `src/Makefile.am` (the tree also holds `rl2legend.c`, which
  refers to undeclared types), its config.h and rl2config.h are
  generated, `unistd.h` is shimmed (one unguarded include), `strcasecmp`
  is mapped to `_stricmp`, and its Visual Studio directory-scan branch
  in `rl2import.c` (which nobody compiles) lacks a closing brace at the
  pinned commit -- patched.  fyba's cmake files predate
  `cmake_minimum_required` (prepended) and add no Windows flags
  (`WIN32` is what its ifdefs test; given through `CMAKE_CXX_FLAGS`);
  its targets are `fyba`, `gm`, `ut`, copied to the `fygm`/`fyut` names
  GDAL's FindFYBA wants.  mysql's full install dies on its Debuginfo
  component (no `.pdb` in a MinSizeRel build): only the Development and
  SharedLibraries components are installed; `libmysql.dll` lands in
  `lib` (copied to `bin`) and the import library is copied over the
  static `mysqlclient.lib` the Development component installs, which
  GDAL's FindMySQL (`NAMES mysqlclient` first) would otherwise link.
  libOpenDRIVE replaces `CMAKE_CXX_FLAGS` for MSVC in its own
  CMakeLists (patched there: `_USE_MATH_DEFINES` for `M_PI`).  glib's
  pcre2 wrap installs `pcre2.h`, static archives and `.pc` files into
  the prefix although glib embeds it statically; GDAL found them and
  its sqlite REGEXP code failed to link (the header declares dllimport
  without `PCRE2_STATIC`).  They cannot be removed: `glib-2.0.pc` names
  `libpcre2-8` as a private requirement, and without that `.pc` every
  pkg-config lookup of glib fails ("Could not generate cflags for
  glib-2.0" -- openslide's meson was the first, on a host run), so GDAL
  gets `-DGDAL_USE_PCRE2=OFF` instead.  curl in the
  gdal chain needs brotli first (it is `CURL_BROTLI=ON`), poppler needs
  harfbuzz: both are ordered accordingly.  The bundled `gdal-config` is
  the configured sh script, kept as a data file; the Windows wrapper
  (`osgeo/bin/__init__.py`) answers its options from the script's
  variables, runs the real tools as children (`os.execve` returns the
  console early on Windows), and points `GDAL_DATA`/`PROJ_DATA` at
  `osgeo/gdal` and `osgeo/proj` (the linux wrapper's `localpath/proj`
  resolves to `osgeo/bin/proj`, which does not exist; possibly a latent
  linux bug).  The osgeo patch finds `gdal.dll`/`geos_c.dll` in
  `gdal.libs` under their Windows names (the wheel is repaired and
  relocated under pip's lowercase name and renamed to `GDAL-` last, the
  Glymur lesson; the library directory therefore differs from linux's
  `GDAL.libs`, which the patch keeps as a fallback).  The osgeo patch also
  registers an atexit hook that restores GDAL's built-in error handler:
  on Windows `gdal.dll` tears itself down at DLL unload, after the
  interpreter is gone, and the shared suite runs with `CPL_DEBUG=ON`, so
  that teardown reports through the handler installed last -- django's
  ctypes callback, a dead pointer by then; the suite's django section
  printed its results and then died with an access violation (exit 139
  under bash) until the hook was added.  A fresh prefix needs its
  `bin`/`lib` directories before `Build-Sqlite` copies into them (a
  `Copy-Item` to a missing directory writes a file of that name, and
  every cmake install after it then fails on "not a directory").
- DLL names in the GDAL tree, as the builds produce them: `gdal.dll`
  (import library `gdal.lib`), `geos.dll` + `geos_c.dll`, `proj_9.dll`,
  `geotiff.dll`, `gif.dll`, `json-c.dll`, `Lerc.dll`, `iconv.dll`,
  `minizip.dll`, `freexl.dll`, `librttopo.dll`, `spatialite.dll`,
  `rasterlite2.dll`, `netcdf.dll`, `hdf5.dll` (+ `_cpp`, `_hl`),
  `libmysql.dll`, `libpq.dll`, `libcrypto-3-x64.dll` + `libssl-3-x64.dll`,
  `gta.dll`, `xerces-c_3_3.dll`, `blosc.dll`, `libkea.dll`, `avif.dll`,
  `lti_dsdk_9.5.dll` (MrSID), `vcomp140.dll` (OpenMP); hdf4, fyba and
  libOpenDRIVE are static and absorbed into `gdal.dll`.
