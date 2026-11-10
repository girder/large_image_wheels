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
`sandbox_run.ps1`, which both call, plus the nightly wrapper
`nightly.ps1`, are the only agent-authored code that runs on the host;
treat them as frozen infrastructure -- audited
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
- javabridge bundles a JVM on Windows as on linux and macos: the
  portable Zulu 8 JDK zip from the cache (see the hard-won entry).
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

Seven files, the same shape as the macos directory (one monolithic build
script, one host orchestrator per role, one in-VM test, the nightly
wrapper, a README).  As
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
- `nightly.ps1` -- the nightly build, the counterpart of
  `macos/nightly.sh` (see "Nightly").
- `sandbox_run.ps1` -- the host launcher (agent-authored; audit before
  trusting): `build`, `test`, or `cache` as its first argument.  It
  checks the host, generates the sandbox configuration with the folder
  layout below, starts the sandbox, streams the in-sandbox log, waits
  for the exit marker, and reports: for `build` it validates that every
  requested package produced a wheel for every requested python
  (`-Packages`, `-Pythons`, `-MemoryMB` -- default half of the host's
  physical memory -- `-TimeoutSec`); for `test` it
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
venv is activated by hand there; pylibmc is installed by name before
`large-image[memcached]`, whose extra leaves pylibmc out on Windows).  The harness supplies `python3` (the
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
windows\sandbox_build.bat -Pythons 3.12,3.13 -MemoryMB 16384
windows\test_via_sandbox.bat -Pythons 3.13
powershell -File windows\sandbox_run.ps1 cache     # pre-warm the download cache
```

Remember that only one sandbox instance may run at a time -- the agent
session is itself a sandbox, so it must be closed before a run -- that
closing the watching console does not stop a run, and that a run
interrupted at the host leaves its sandbox running until it is closed.

### Nightly

`windows\nightly.ps1` is the counterpart of `macos/nightly.sh` and of the
linux crontab line (`rebuild.sh`, `test_via_docker.py`, `wall`):
`check_versions.py` rewrites `versions.txt` (through `uv run` when uv is
on PATH, else `python` with requests and packaging; the diff is logged and
the file is left modified, as `rebuild.sh` leaves it), then
`sandbox_run.ps1 build` and `sandbox_run.ps1 test`.  It does no git
activity beyond `check_versions.py`'s version lookups.  All output goes to
`windows\nightly.log`, overwritten each night (the build and test logs
stay in the run folders); the result -- good with the changed versions,
or ERROR with the last log lines -- is appended to it and written as
text into every console window the user has open, as `wall` does (Windows
has no wall: the script attaches to each of the user's consoles in turn
with `AttachConsole` and writes to it, once per console window, Windows
Terminal tabs included), and the exit code is the task's Last Run Result.

It runs from Task Scheduler, not as a service: Windows Sandbox is a
per-user feature, so the task runs as the logged-in user with the
Interactive logon type (a locked screen is fine).  The task must set
priority 4: Task Scheduler's default of 7 is below normal for CPU and
lowered for I/O and memory, the Windows form of the cron throttling that
broke the macos nightly.  Registration, from a PowerShell prompt in the
repository (the same lines head `nightly.ps1`):

```
$a = New-ScheduledTaskAction -Execute powershell.exe -WorkingDirectory $PWD -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PWD\windows\nightly.ps1`""
$t = New-ScheduledTaskTrigger -Daily -At 3:30am
$s = New-ScheduledTaskSettingsSet -Priority 4 -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 12) -MultipleInstances IgnoreNew
$p = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
Register-ScheduledTask -TaskName large_image_wheels_nightly -Action $a -Trigger $t -Settings $s -Principal $p
```

Each command is one line on purpose: a backtick continuation breaks when
a copy picks up trailing spaces after the backtick.  Then:

```
(Get-ScheduledTask -TaskName large_image_wheels_nightly).Settings.Priority   # must be 4
Start-ScheduledTask -TaskName large_image_wheels_nightly                     # run it now
Unregister-ScheduledTask -TaskName large_image_wheels_nightly -Confirm:$false  # remove it
```

Unregistering does not stop a run in progress (`Stop-ScheduledTask`
does).  `nightly.ps1`'s header also says how to hide the task's console
window.  The
single-sandbox rule applies: with the file backend, or a Windows build
that allows one sandbox, an agent session left open fails the night's
build (`sandbox_run.ps1` refuses or `wsb start` fails, and the ERROR
message says so).

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

Work in progress (2026-11-03).  Eight packages are verified end to end
on the host and the ninth, pylibmc, passes in dev mode; the pipeline is
exercised in dev mode inside the agent sandbox before every host run:

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
  libgeotiff tools bundled (77 DLLs, 42 tools, 45 MB).  Verified on
  the host with the five default packages (2026-10-30); the runs that
  failed on the way were a network error and a build-log append that
  hit the host's streaming read (see the hard-won list).

- **mapnik builds and passes every dev-mode check for python 3.13
  (2026-10-30)**: icu4c (an embedded cmake build) and boost (b2) on top
  of the GDAL tree, then mapnik at the pinned commit with the
  repository's two patches and the Dockerfile's seds, every plugin the
  linux wheel has (csv, gdal+ogr, geobuf, geojson, postgis+pgraster,
  raster, shape, sqlite, tiles with SSL, topojson) and everything
  libmapnik links on linux asserted on the DLL import tables; then the
  python-mapnik wheel with the plugins, fonts, proj and gdal data and
  mapnik-render/mapnik-index/shapeindex bundled (68 MB).  The shared
  suite's mapnik sections pass.  The first host run (2026-10-30) got
  through the other five packages, icu4c and boost, and died compiling
  mapnik with the compiler out of heap space (the 8 GB build sandbox
  ran one Spirit grammar compile per processor); mapnik's compile is
  now limited by memory, and the sandboxes get half of the host's memory by default (see
  the hard-won list).  Verified on the host with the six default
  packages (2026-11-02).
- **python_bioformats** (2026-11-02; `Build-Bioformats`): one
  py3-none-any wheel, as on linux and macos -- python-bioformats at its
  tag with the release's `bioformats_package.jar`, jackson removed as in
  the Dockerfile (the guard fails the build if anything left in the jar
  mentions jackson, or if there is no jackson to remove), version
  suffix `.<jar version>.2`.  No unzip/zip/advzip on Windows: the patch
  python's `zipfile` does the guard and the rewrite, recompressing at
  level 9 in place of advzip.  It cannot be used without javabridge, so
  until the python_javabridge wheel exists `test_wheels.ps1` installs it
  with `--no-deps` (pip would otherwise reach for pypi's javabridge
  sdist) and the shared suite skips its bioformats sections.  The jar
  was checked against the Dockerfile's `zip -d` patterns: the same 1054
  entries removed, every other entry's CRC unchanged.  Verified on the
  host (build and install only; 2026-11-02).
- **python_javabridge builds and passes every dev-mode check for python
  3.13 (2026-11-02; `Build-Javabridge`)**, with python_bioformats now
  tested through it: the Azul Zulu 8 win_x64 JDK at the macos build's
  `zulu8` pin, bundled in `javabridge/jvm` like linux and macos (see the
  hard-won entry), one wheel per python.  `check_wheels.py` checks that
  the bundled tree is the one resolved and the `jvm.dll` loaded,
  `java.home`/`java.version` from inside the started VM, and, with
  bioformats installed, the jar's version, the absence of jackson and a
  pixel read through the VM; `java` runs as a console script and by path
  with a bare PATH.  The shared suite's javabridge sections pass
  (`java -version`, the bioformats version, `sample.svs` through
  bioformats).  The suite's geotiff-through-large_image step was gated
  on the bioformats wheel too, but large_image's bioformats source
  ignores `.tif` files (`source_bioformats_ignored_names`), so a
  wheelhouse without gdal/mapnik/pyvips failed there with "No available
  tilesource"; the bioformats term is gone from that gate.
  Verified on the host with the eight default packages (2026-11-03).
- **pylibmc builds and passes every dev-mode check for python 3.13
  (2026-11-03; `Build-Cyrus-Sasl`, `Build-Libmemcached`,
  `Build-Pylibmc`)**: OpenSSL (the gdal tree's builder), cyrus-sasl and
  libmemcached through embedded cmake files (see the hard-won entry), and
  one pylibmc wheel per python with the Dockerfile's patches: SASL linked,
  the ten plugin DLLs in `pylibmc/sasl2`, `SASL_PATH` pointed at them,
  version `1.6.3.1`.  `check_wheels.py` checks the bundled libmemcached,
  libsasl2 and libcrypto are the ones loaded, `build_info()` reports
  compression and SASL, every mechanism registers through the bundled
  plugins (`sasl_global_listmech`: ANONYMOUS, PLAIN, CRAM-MD5, DIGEST-MD5,
  LOGIN, SCRAM-SHA-*, NTLM, OTP, SRP, PASSDSS-3DES-1), a set/get/
  get_multi/delete round trip with zlib compression against a
  text-protocol fake memcached in the check itself, and that a refused
  connection fails at once rather than after the connect timeout.  That
  round trip found three Windows socket bugs in libmemcached's MinGW port
  (see the hard-won entry); a build-only check would have passed.  The
  wheel step was rehearsed for all seven pythons, and `check_wheels.py`
  passes for 3.11, 3.14t and 3.15t as well; `test_wheels.ps1` (with the
  shared suite) passes for 3.13.  The first host run (2026-11-03) built
  everything and passed every check but one, on every python: "the sasl2
  plugins load the bundled libcrypto" demanded pylibmc's own copy.  The
  GDAL wheel bundles the identical OpenSSL, so both copies get the same
  mangled name, and with osgeo imported first the loader resolved the
  plugins' import to gdal.libs' copy -- the accepted case of the
  two-wheels entry in the hard-won list, which the dev run (pylibmc
  alone) could not show.  The check now requires the plugins' libcrypto
  to be the name pylibmc bundles, loaded from pylibmc's directory or
  another wheel's `.libs`, and from nowhere else.

Next step: the host run of `windows\sandbox_build.bat &&
windows\test_via_sandbox.bat` (nine packages by default now, with
pylibmc).  That completes the package list.

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
- The C++ packages (pyvips, GDAL, mapnik) import
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
  the compiler in a perl launcher) and with its Windows-only OpenSSL DLL
  lookup (`cmake/ssl.cmake`, which knows the naming of 1.1 and 3.x only)
  patched to OpenSSL's `-<major>-x64` scheme, so that it takes
  `versions.txt`'s OpenSSL like the other builds; libgeotiff from its cmake build
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
- **mapnik deviations from the linux wheel**, each marked in
  `build_wheels.ps1` where it happens: icu4c from an embedded cmake file
  over ICU's own `sources.txt` lists, with the release tarball's
  prebuilt `icudt<N>l.dat` as the data (linux builds the same file from
  the same release's data sources); no libiconv (the macos reasoning:
  nothing in mapnik's build uses it); boost from the release's b2
  tarball (the git tag's tree without docs) with `--layout=system`, no
  gcc warning flags and no `using mpi`, plus Boost.JSON (the tiles
  plugin links it on Windows only); only the `deps/mapbox` submodules of
  mapnik are fetched; plugins install to `lib/mapnik/input` (the linux
  layout) and `INSTALL_DEPENDENCIES` is off; harfbuzz is found through
  pkg-config; mapnik's plugin loader tries `LoadLibraryEx` with the
  default DLL directories first (see the hard-won entry); python-mapnik
  gets two MSVC source fixes (`ssize_t`, an ambiguous `to_wkt`
  overload) and its setup.py is pointed at pkgconf's `--msvc-syntax`.
- **pylibmc deviations from the linux wheel**, each marked in
  `build_wheels.ps1` where it happens: the SASL plugin set is linux's
  minus gssapiv2 and gs2 (no Kerberos on Windows) and minus the
  server-side auxprop plugins sasldb, sql and ldapdb (no Berkeley
  DB/LMDB, no openldap; linux's sql plugin comes from the mysql and
  postgresql clients of its base image; macos leaves all five out too),
  so the client mechanisms are all there; the plugins are named as
  upstream's Windows build names them (`saslPLAIN.dll`, ...);
  libmemcached is the library only (no clients, libmemcachedutil or
  libmemcachedprotocol, which the wheel does not carry), without the
  SO_SNDTIMEO/SO_RCVTIMEO paths (winsock takes a DWORD of milliseconds
  where the code passes a timeval) and without UDP (POSIX `sendmsg`,
  absent from the MinGW port too).  The wheel's layout is delvewheel's
  for a top-level extension module: the bundled DLLs are at the top of
  site-packages (`.data/platlib`), not in `pylibmc.libs` (see the
  hard-won entry).
- **ImageMagick's configuration files are bundled (all three platforms,
  2026-11-10).**  No platform builds zero-configuration (it would remove
  the policy override), so ImageMagick looks for `colors.xml`,
  `policy.xml`, `delegates.xml`, `type*.xml`, `english.xml`, ... on its
  search path, and the bundled `magick` warned
  `UnableToOpenConfigureFile 'colors.xml'` on every run.  Each pyvips
  wheel now carries them in `pyvips/etc/ImageMagick` (no version in the
  name, so nothing downstream needs one): on linux and macos the files
  `make install` put in `etc/ImageMagick-<major>`,
  `share/ImageMagick-<major>` and `lib/ImageMagick-*/config-Q16HDRI`; on
  Windows what upstream's Configure puts beside its binaries
  (`Build-Imagemagick`'s cmake file installs them to
  `etc\ImageMagick-<major>`), plus `francais.xml` and
  `quantization-table.xml` as on linux.  The patched `pyvips/__init__.py`
  appends the directory to `MAGICK_CONFIGURE_PATH` (after any the user
  set), which ImageMagick searches first; the console scripts inherit it,
  because `pyvips.bin` imports `pyvips`.  Checked by the shared suite
  (`magick -list policy` names the bundled `policy.xml`, and a conversion
  prints no `UnableToOpenConfigureFile`) and by `check_wheels.py`, with
  the variable removed from the console script's environment.  Departing
  from the earlier plan, Windows does not also put the files beside
  `magick.exe` in `pyvips.libs`: ImageMagick loads every copy it finds,
  so a console-script run would load them twice, and linux and macos
  have nothing equivalent for a by-path run.  What remains, the same on
  all three: a tool run by path (`pyvips/bin/magick`) without python
  does not get the variable and still warns; and because ImageMagick
  loads every copy, the compiled-in prefix paths of linux and macos
  (`/usr/local/etc/ImageMagick-<major>`, ...) are still read after ours,
  so another ImageMagick installed there adds its `policy.xml`.
  Configuring with `--disable-installed` would drop those paths and find
  the files relative to the executable instead (fixing the by-path case
  as well), but the in-process search would then use python's own
  directory (`<sys.prefix>/etc/ImageMagick-<major>`, which is where a
  conda ImageMagick installs); not done.
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
  run.  They now write into a `tempfile.TemporaryDirectory`, which is
  throwaway on every platform as `/tmp` was meant to be.
- No psutil wheel exists for cp315t on pypi, and `large-image[converter]`
  requires psutil; the test sandbox has no compiler (by design), so on
  3.15t that install fails and the suite stops.  This is upstream lag,
  not our build: it resolves itself when psutil publishes the wheel.

## Hard-won details (do not lose these)

- **The linux build is the model for method, not only for content.**
  Where a name can be read from what was built, read it rather than
  writing down what one build happened to produce: an import library
  records the DLL it binds to (`Get-ImportLibDll`), and a library's own
  `.pc` file or install record names its files.  zlib 1.4 renamed
  `z.dll` to `libz.dll`, and the first nightly died on the copies of the
  old name.  Change such places when they are touched or break; do not
  restructure working, verified steps around this.
- **Never hardcode a version, or part of one, that `versions.txt`
  holds** (the maintainer's rule; the Dockerfile follows it).  Use `V
  <name>` and its getver.py component selection (`V imagemagick @('1')`
  is the major), or read the name from what was built; names we create
  carry no version at all (`pyvips/etc/ImageMagick`).  Only a deliberate
  pin is an exception, and then the Dockerfile pins it too, or the reason
  is written down (MrSID).  A sweep on 2026-11-10 found three violations,
  all in this build, two of them under a false "like the linux build":
  OpenSSL cloned at `openssl-3.6.2` (linux and macos build
  `versions.txt`'s 4.x) with `3.6.2` in its `.pc` files and
  `libcrypto-3-x64` in the checks -- the likely but unrecorded reason
  being MySQL's Windows-only DLL lookup, which rejects OpenSSL 4 (now
  patched in `Build-Mysql`; a pin whose reason is not written down is
  indistinguishable from a mistake); libOpenDRIVE at `0.6.0-gdal` (the
  others use `libopendrive`, then `0.6.1-gdal`, whose changed MSVC flags
  line the old patch would have rejected, and which installs the pugixml
  headers only in `include\`, where GDAL's XODR driver does not look --
  linux and macos copy them to `include\pugixml\`, now Windows too); and ImageMagick's major `7` in
  `Build-Imagemagick` and the pyvips wheel checks.  A sweep has to look
  for version-shaped literals of any value, not just the current pins: a
  stale pin matches nothing in `versions.txt`.
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
  the next poll; an uncaught exception there is what stops a run.  The
  converse happens too: the in-sandbox `Add-Content` to the log failed
  while the host held the file for a read, and under
  `$ErrorActionPreference = 'Stop'` that ended a build run.  The
  in-sandbox scripts append through `Append-Line`, which retries for a
  few seconds and then drops the line rather than the run.
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
  binaries to match.  The hash covers the DLL's content and the mangled
  hashes of the bundled DLLs it imports (delvewheel 1.13,
  `_wheel_repair.py`, in dependency order), so a library whose
  dependencies changed gets a new name even when its own bytes did not:
  identical DLLs in two wheels share a name and differing ones never
  do.  That is the case auditwheel gets wrong and the linux BUILD_ID
  salt works around; delvewheel needs no salt.  Keep it that way: the
  Windows loader resolves an import by base name against the modules
  already loaded in the process, so two unmangled `tiff.dll` copies in
  two wheels would silently share whichever loaded first.  Code that looks bundled libraries up by name must match the
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
  (observed), except zlib's, which changed between releases (1.3.2 made
  `z.dll`/`z.lib`, 1.4 makes `libz.dll`/`libz.lib` while its `zlib.pc`
  still says `-lz`; the first nightly died on that): `Get-ZlibImportLib`
  gives the import library under `zlib.pc`'s name (Build-Zlib copies
  the installed one there when they differ) and `Get-ZlibDll` the DLL
  that import library records (`Get-ImportLibDll`, `dumpbin /HEADERS`).
  The static library is turned off so no consumer can pick it.  The
  rest: `zstd.dll`, `jpeg62.dll` + `turbojpeg.dll`, `libwebp.dll` with
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
  Name lookups inside the build sandbox failed several times in a row
  while downloading librsvg's crates ("Could not resolve host:
  static.crates.io" after cargo's default 3 tries), although the same
  name resolved fine outside the build sandbox.  The suspected cause
  (not confirmed) is the Windows Sandbox NAT's DNS proxy under the burst
  of lookups cargo makes when it fetches a lock file's crates in
  parallel (librsvg's 352 at once), not crates.io itself.  The proxy
  forwards to whatever resolvers the host uses, and those may limit a
  burst too (corporate or filtering resolvers often rate-limit per
  client), so the cause can differ from one network to the next.
  `CARGO_NET_RETRY` is 10, the usual CI setting; if that is not enough,
  the next step is caching the crates, not vendoring them.  When a cargo step fails, `Log-DnsDiagnostics` logs
  the sandbox's DNS servers, the Windows DNS client's cache entry for
  each crates.io host (a cached failure would make cargo's quick retries
  pointless), an nslookup straight to the server and a curl.exe lookup
  through the system resolver (the path cargo's libcurl takes): a burst
  problem shows as those all succeeding moments later, a remembered
  failure as a cache entry that is not `Success` while nslookup
  succeeds, and a proxy or upstream outage as nslookup failing too.
  (The cache and server cmdlets need administrator rights, which the
  build sandbox's SYSTEM account has and a dev run's `agent` does not.)
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
  CMakeLists (patched there: `_USE_MATH_DEFINES` for `M_PI` is appended
  to whatever flags that line has).  glib's
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
  `libmysql.dll`, `libpq.dll`, `libcrypto-<n>-x64.dll` + `libssl-<n>-x64.dll`
  (`<n>` is OpenSSL's shared-library major; read from `libcrypto.lib`),
  `gta.dll`, `xerces-c_3_3.dll`, `blosc.dll`, `libkea.dll`, `avif.dll`,
  `lti_dsdk_9.5.dll` (MrSID), `vcomp140.dll` (OpenMP); hdf4, fyba and
  libOpenDRIVE are static and absorbed into `gdal.dll`.
- **The mapnik tree** (`Build-Icu4c` through `Build-MapnikPython`).
  ICU's Windows build is an MSBuild solution and its autotools build
  wants GNU make; the embedded cmake file compiles common and i18n from
  `common/sources.txt` and `i18n/sources.txt` with the defines of their
  `.vcxproj` files, and makes `icudt<N>.dll` the way pkgdata does on
  Windows: one exported, 16-byte-aligned data symbol `icudt<N>_dat`
  (icuuc imports it; `U_DATA_API` is dllimport there), written with
  NASM's `incbin` and linked `/NOENTRY`.  DLLs `icuuc77.dll`,
  `icuin77.dll`, `icudt77.dll`; import libraries without the version,
  which is what CMake's FindICU looks for; the `.pc` files are written.
  boost: `bootstrap.bat msvc` builds b2 with the cl on PATH (the
  bootstrap's batch files call each other by bare name, which cmd does
  not resolve when `NoDefaultCurrentDirectoryInExePath` is set -- the
  agent session sets it -- so it is cleared for the call); the
  bootstrap's `using msvc ;` cannot detect a toolset without a Visual
  Studio installation (it fell back to "msvc-6.0" and hung in its first
  configuration check), and with cl named explicitly b2 still looks for
  `vcvarsall.bat` beside it, so `project-config.jam` names cl, the
  14.3 toolset family, and a no-op `<setup>` script.  b2 1.92 installs
  the DLLs into `bin`.  mapnik's DLL is `libmapnik.dll` with import
  library `libmapnik.lib` (and static `libmapnikwkt.lib`,
  `libmapnikjson.lib`), while its `.pc` files say `-lmapnik`,
  `-lmapnikwkt`, `-lmapnikjson`: copies under those names.  Its plugins
  are DLLs named `.input` that `LoadLibraryA` loads by path; a plugin's
  imports (gdal, libpq, sqlite, boost) are not yet loaded at that point,
  and plain `LoadLibraryA` searches PATH but not the directories python
  added with `os.add_dll_directory` (delvewheel's `mapnik.libs`), so
  the Windows patch tries `LoadLibraryExA` with
  `LOAD_LIBRARY_SEARCH_DEFAULT_DIRS | LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR`
  first and plain `LoadLibraryA` second (the bundled tools' launcher
  puts `mapnik.libs` on PATH instead).  delvewheel only looks at `.pyd`,
  `.dll` and `.exe` files, so the plugins are packaged as `.input.dll`,
  repaired with `--analyze-existing` (which rewrites their imports to
  the mangled names) and renamed back to `.input` after the repair
  (`Rename-Plugins`; mapnik registers only `.input` files);
  `check_wheels.py`'s import audit includes `.input` files.  mapnik's
  tools exit 1 after printing `--version`, on every platform.
- **javabridge and the bundled JVM** (`Build-Javabridge`).  The JDK is
  Azul Zulu 8 (Java 8 because bioformats is built for it; Azul publishes
  every platform's build of a release under one version, so the
  macos-tracked `zulu8` pin serves both).  Its Windows tree is
  self-contained: `bin` and `jre\bin` carry their own VC runtime and
  UCRT forwarders, `jre\bin\server\jvm.dll` is the JVM, `lib\jvm.lib`
  the import library setup.py links against (it finds the JDK through
  `JDK_HOME` on Windows, the registry otherwise).  `_javabridge.pyd`
  imports `jvm.dll`, which must stay inside its JRE (it locates its java
  home from its own path), so the tree is not given to delvewheel -- as
  macos excludes it from delocate -- and, since nothing else is imported
  from outside python and the system (asserted on the import tables),
  delvewheel is not run at all.  macos's `find_javahome` patch makes
  javabridge prefer the bundled tree, and jutil.py's own Windows branch
  then adds `jre\bin\server` and `bin` to the DLL directories before
  importing the extension; the linux-only patches (libjvm preload, the
  `java` argv guard) are not applied.  The JDK's `.exe` tools are the
  console scripts (named without `.exe`), run in place by the usual
  wrapper; they find their DLLs beside themselves.  `check_wheels.py`'s
  import audit lets the JRE's DLLs resolve from `jvm\bin`, `jre\bin` and
  `jre\bin\server`, which is how the launcher and jutil.py set up the
  search.  Not shipped, compared with Zulu's zip: `src.zip`, `demo`,
  `sample` (linux's `java-1.8.0-openjdk-devel` has none of them),
  `classes.jsa` (removed on linux and macos too) and `sawindbg.dll` (the
  serviceability agent's debugger, the counterpart of the `libsaproc.so`
  linux removes).  `pack200 --repack` in place fails on Windows ("Skipping
  unpack because move failed": its final rename onto the existing jar is
  something Java's `renameTo` cannot do there); the jars are repacked
  into a new file that replaces the original.  The jars are not
  timestamp-normalized (the reproducibility gap above).  python-javabridge
  requires nothing at build time but the JDK, Cython and numpy, which
  pip's build isolation fetches.
- **The pylibmc tree** (`Build-Cyrus-Sasl` through `Build-Pylibmc`).
  cyrus-sasl's maintained Windows build is MSBuild projects
  (`win32\*.vcxproj`) and its nmake files are, by its own README, stale;
  the embedded cmake file compiles `sasl2.dll` from `sasl2.vcxproj`'s
  sources with `cyrus-sasl.props`' defines (UNICODE: plugin paths are
  UTF-8 there), each mechanism as its own DLL (`NO_STATIC_PLUGINS`) with
  an init file generated from `win32\init_mechanism.c` as
  `win32\makeinit.ps1` does, and configure's defines for the
  Dockerfile's options (digestmd5 needs `WITH_SSL_DES` as well as
  `WITH_DES` to take OpenSSL's DES).  On Windows libsasl2 does not read
  `SASL_PATH`: the plugin path is the registry's, then the compiled-in
  `PLUGINDIR` (`C:\CMU\bin\sasl2` in upstream's `config.h`, moved to the
  prefix here as linux's is its prefix), so a Windows-only patch makes
  `SASL_PATH` win, which keeps pylibmc's `__init__.py` patch identical
  to linux's; and the plugins are loaded with `LoadLibraryEx` and the
  default DLL directories first (the mapnik plugin-loader lesson: they
  import libcrypto, which a plain `LoadLibrary` would not find in a
  directory added with `os.add_dll_directory`).  libmemcached (autotools,
  with a MinGW port: `win32/wrappers.h`, `libmemcached/windows.hpp`)
  builds from an embedded cmake file over the include.am source lists
  (libhashkit compiled in, as BUILD_WIN32 does), a written
  `mem_config.h`, shims for `sys/time.h`, `strings.h` and `pthread.h`
  (sasl.cc's once-only `sasl_client_init`: `INIT_ONCE` and an SRW lock),
  `/FIiso646.h` for the C++'s `and`/`or` (cl knows them only in its
  strict mode), C++20 for poll.cc's designated initializers, and the CSL
  parser from winflexbison.  DLL `libmemcached.dll`, import library
  `memcached.lib` (pylibmc's `libraries=["memcached"]`).  The MinGW
  port's socket code was broken under MSVC in three ways, all invisible
  to the build and found by the check's round trip: socket errors are
  `WSAGetLastError()` codes compared against errno names, which
  `wrappers.h` defines as the WSA codes only where `errno.h` has none
  (MinGW) -- MSVC's has its own values, so every non-blocking connect
  failed; `windows.hpp`'s unused WSA-to-errno translation is now what
  `get_socket_errno()` returns.  A non-blocking `connect()` then reports
  `WSAEWOULDBLOCK` (EAGAIN) where POSIX says EINPROGRESS, which
  `connect_poll()` does not take for "connected once writable": it
  closed the socket unused, and a set failed with MEMCACHED_ERRNO, "No
  error".  And the `select()` emulation of `poll()` did not watch
  `exceptfds`, where Windows reports a failed connect, so a refused
  connection waited out the connect timeout.  The public `platform.h`
  gets `typedef int pid_t` (python's pyconfig.h has the same typedef),
  and pylibmc's own C uses `ssize_t` (defined as `Py_ssize_t` from
  setup.py).  delvewheel puts a wheel's DLLs in `.data/platlib`, the top
  of site-packages, whenever the wheel has a top-level extension module
  (`_pylibmc`), and adds site-packages to the DLL search path in its
  `pylibmc/__init__.py` patch; that is fixed in delvewheel.  The names
  are mangled as elsewhere, but an unmangled `vcruntime140.dll` there
  could belong to another distribution, so this wheel does not force the
  VC runtime in (it has no tools; python has it loaded) --
  `check_wheels.py` lets in-process modules import python's own
  `vcruntime140*.dll`, and audits this wheel by its RECORD instead of by
  directory (`SITE_PACKAGES_LIBS`).  pylibmc 1.6.3 prints "Exception
  ignored in PyMapping_HasKeyString()" tracebacks on python 3.13+ when a
  client is created without behaviors: its C code probes `None` as a
  mapping once per behavior name, and 3.13 reports the error earlier
  versions swallowed.  That is upstream's, on every platform, and the
  client works.
- The python patch scripts must open source files with
  `encoding="utf-8"`: before python 3.15 the default is the ANSI code
  page (cp1252), and mapnik's headers are UTF-8 (a dev run passed by
  hand, where the session had python's UTF-8 mode on, and failed in the
  build).  `Invoke-Patch` runs them through `Run-Logged`, so a failing
  patch's traceback reaches the log.
- **Parallelism versus memory**: the build sandbox gets as many
  processors as the host but only `-MemoryMB` of memory.  That was
  8 GB, where the agent sandbox has 32 GB, so the dev builds said
  nothing about memory; the default is now half of the host's physical
  memory (only one sandbox runs at a time, so that is affordable; the
  launcher prints the value it chose).  mapnik's Boost.Spirit grammar files need gigabytes per
  compile; with one compile per processor the first host run died with
  `fatal error C1060: compiler is out of heap space`.  `Get-HeavyJobs`
  sizes such a build's parallelism from physical memory (mapnik: 3 GB
  per job: 10 jobs at 32 GB, 2 if a host run passes `-MemoryMB 8192`),
  and `Cmake-Build -Jobs` takes it.  The boost step's
  log has an `error: No best alternative for .../histogram/
  install-libraries-shared` line: b2 continues past it (Boost.Histogram
  is header-only and not one of the libraries built), and every boost
  assertion holds, so it is noise.
- **The bundled magick sometimes exits 0 without output, or hangs at
  exit, while gio's startup job runs (fixed in `Build-Glib`; the cause is
  below the first account, which is kept for the record).**  A host test showed `magick --version` printing nothing
  once in 14 runs.  Run directly, the bundled `magick.exe` did it about
  7 times in 1000 and once never exited: its one remaining thread waited
  in `ExitProcess` -> `LdrShutdownProcess` -> `RtlRunOnceExecuteOnce` for
  a one-time initialization another, killed, thread had started.  Stack
  walks of a live magick showed the other threads: gio's `DllMain` calls
  `gio_win32_appinfo_init (FALSE)`, which queues a GLib thread-pool job
  building the app-association tree (registry scans, packaged apps
  through Windows.ApplicationModel, COM, shell items) in every process
  that loads gio (magick through MagickCore's librsvg/pango, the vips
  tools through poppler-glib, python importing pyvips).  An A/B run of
  the same files with only that call replaced by NOPs: 993/1000 good for
  the original, 1000/1000 for the patched copy, so the job is
  **necessary**.  It is **not sufficient**: `vips --version` (gio
  loaded, as short-lived) was clean in 500 runs, and a python child that
  loads gio and exits after 0-145 ms was clean in 600 runs each with gio
  alone, gio plus gdiplus/urlmon/dwrite/vcomp140, gio plus MagickCore,
  MagickCore's genesis and terminus, and an in-process `magick
  --version` (SetConsoleOutputCP, MagickCore/MagickWand genesis,
  `ListMagickVersion` to the C runtime's stdout, MagickWandTerminus).
  The other ingredient -- whether ImageMagick, our ImageMagick build,
  or Windows -- is not found, so nothing was reported upstream; the next
  step would be native test programs (a toolchain in the agent sandbox:
  `build_wheels.ps1 -DevSetup`).  `Build-Glib` drops the startup call as
  the workaround: every API that needs the tree calls
  `gio_win32_appinfo_init (TRUE)`, which builds it on demand, and nothing
  in the wheels uses GAppInfo.  An intermittent failure here has a
  cause; look for it.

  **The cause (2026-11-10)**: no ImageMagick is needed.  A 30-line test
  program that loads gio, starts one thread calling
  `g_app_info_get_all()` (the startup job's work, done synchronously),
  `printf`s a line and returns from `main` 0-150 ms later lost its output
  with exit 0 in 12 of 300 runs and hung once; with gio loaded and no such
  thread, or with an idle thread instead, all 300 runs were clean.
  `ExitProcess` kills the other threads first and then runs the DLL
  detach handlers, and the scan thread dies inside the shell/COM/WinRT
  DLLs it called, holding their locks.  A detach handler that then
  enters an orphaned **critical section** makes the loader end the process
  on the spot with the exit code already given -- the C runtime's own
  detach, which flushes the buffered stdout, never runs: **exit 0, no
  output**.  An orphaned **one-time initialization** has no such shortcut:
  the **hang**, the `RtlRunOnceExecuteOnce` wait seen in the stack.  A
  detach marker proved the first: a DLL loaded before gio, writing to
  stderr from its `DLL_PROCESS_DETACH`, stayed silent in every lost run
  while the program's `atexit` handler had run.  With `fflush(stdout)`
  before returning, no output was lost (9 of 300 runs still ended early
  in the detach phase, harmlessly).  That is the "other half": every
  process that loads gio is exposed for as long as the job runs, and a
  short-lived one shows it when its output is still in the C runtime's
  buffer at exit.  magick's is (`ListMagickVersion` writes to `stdout`
  and nothing flushes before exit); `vips --version` prints through
  `g_print`, which flushes, and the python reconstructions flush their
  output before the C-level exit -- so none of them could show the lost
  output, and the hang is rare enough (about 1 in 300-1000) to miss in
  a few hundred runs.  The programs (`exit_race.c`, `marker.c`, a runner)
  were scratch files of that session; the description above is enough to
  rewrite them.  This is reportable to GLib (a DllMain-queued job that
  makes every gio process unsafe to exit while it runs); nothing has
  been reported.
