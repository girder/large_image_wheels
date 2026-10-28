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
  `nasm`, `delvewheel`; tracked by `check_versions.py` like the macos-only
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
windows\test_via_sandbox.bat`.  Those launchers (and the
`sandbox_common.ps1` they share) are the only agent-authored code that
runs on the host; treat them as frozen infrastructure -- audited once,
changed only with care.  The checked-in `windows\build.wsb` and
`windows\test.wsb` are the same two runs as data, not code: folder
mappings and one LogonCommand line each, for a workflow where nothing
agent-authored runs on the host (read once, adjust the host paths, open
the file, read the log and the exit-code file).

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
  pins nothing).  `windows\install_msvc.py` (adapted from manthey/utils)
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
- `<package>/bin/<tool>.exe` is the **launcher** (`windows/launcher.c`,
  5 KB, kernel32 only, no C runtime): it locates `<dist>.libs` relative
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
is duplicated.

## Files

Host side (run on the host, outside any sandbox):

- `sandbox_build.bat` / `test_via_sandbox.bat` -- the two entry points,
  run from a command prompt with no options, the counterparts of
  `build.sh && test_via_docker.py` and `macos/tart_build.sh &&
  macos/test_via_tart.sh`:
  ```
  windows\sandbox_build.bat && windows\test_via_sandbox.bat
  ```
  Each is one line that runs the `.ps1` of the same name and returns its
  exit code; options are passed through.
- `sandbox_build.ps1` -- the build launcher (agent-authored; audit before
  trusting).  It checks the host, generates a `.wsb` with the folder
  layout below, starts the sandbox, streams the in-sandbox build log,
  waits for the exit marker, validates that every requested package
  produced a wheel for every requested python, and reports.
  `-Packages`, `-Pythons`, `-MemoryMB`, `-TimeoutSec`; `-Command cache`
  pre-warms the download cache in a throwaway sandbox (toolchain
  downloads, the MSVC/SDK payloads, and the pythons).
- `test_via_sandbox.ps1` -- the test launcher: a fresh sandbox with the
  repository and the wheels mapped read-only, running `test_wheels.ps1`;
  it streams the log, prints `report.txt`, and exits with the result.
  `-Pythons`, `-MemoryMB`, `-TimeoutSec`.
- `sandbox_common.ps1` -- what the two launchers share: the host sanity
  checks, the two backends, the log streaming, the wait, the stop.  The
  backends are agent_sandbox.py's: `cli` when `wsb.exe` is on PATH
  (Windows 11 24H2+; headless, `wsb start --config` gives a sandbox id,
  the in-sandbox script runs as SYSTEM through `wsb exec`, `wsb stop`
  tears it down, and several sandboxes can coexist when the Windows
  build allows it, so the agent session can stay up), else `file` (the
  generated `.wsb` is launched like a double-click, the script runs from
  the LogonCommand, one sandbox at a time).
- `build.wsb` / `test.wsb` -- the same two sandbox configurations checked
  in as data, for the human-only workflow without the launchers: the
  mapped folders (repo read-only at `C:\mnt\repo`; cache at
  `C:\mnt\cache` from `<repo>\windows\cache`; wheels at `C:\mnt\wheels`
  from `<repo>\wheels` -- where build.sh and tart_build.sh put theirs --
  read-write for the build and read-only for the test; the per-run
  exchange at `C:\mnt\run`, from `<repo>\windows\run` for the build and
  `<repo>\windows\test_run` for the test; all gitignored) and the
  LogonCommand.  The `HostFolder` paths are host-specific; adjust them
  once, then open the file.  Only one sandbox may run at a time.

In-sandbox side (run by the LogonCommand; dev mode in any checkout):

- `build_wheels.ps1` -- the monolithic build, the counterpart of the
  monolithic Dockerfile (and of `macos/build_wheels.sh`).  Parameters:
  `-Packages`, `-Pythons` (a trailing `t` selects the free-threaded NuGet
  python), `-WarmCache` (toolchain and pythons only); without parameters
  it reads `C:\mnt\run\args.json` when the launcher wrote one and uses
  built-in defaults otherwise (the source is logged).  It writes its log
  to `<run>\build.log` and its exit code to `<run>\exit_code`, clearing
  both at startup, so a persistent run folder works across runs.
- `test_wheels.ps1` -- the in-sandbox test, the counterpart of the in-VM
  part of `macos/test_via_tart.sh`.  For every python: install the
  wheels by exact version into a clean venv (a pypi fallback would show
  as a version mismatch), run `check_wheels.py` there with a scrubbed
  PATH, run the shared `test/test_script.sh` under PortableGit's bash
  with a scrubbed PATH and the python under test, and run
  `check_wheels.py` in the venv the suite created.  Every check is one
  `OK:`/`FAIL:` line in `<run>\report.txt`; the log is `<run>\test.log`.
- `liw_common.ps1` -- what the two in-sandbox scripts share: logging,
  `versions.txt` lookups, cached downloads, the NuGet python and
  PortableGit installs.
- `check_wheels.py` -- the windows-specific per-package isolation checks
  (the counterpart of the macos harness's otool audit and per-package
  checks), run with a python that has the wheels installed and a
  scrubbed PATH: a PE import audit of every `.pyd`/`.dll`/`.exe` our
  wheel provides (each import must be in the wheel, python's DLL, an API
  set, or in System32 -- the tools nobody runs are checked too), the
  loaded library is the bundled `<dist>.libs` copy (through the
  process's module list), the bundled tools run through their wrappers
  and by path with nothing but the system directories on PATH, and the
  asserted codecs work.  By hand in dev mode:
  ```
  C:\liw_build\python\3.13\python.exe -m venv %TEMP%\v313
  set PATH=C:\Windows\System32;C:\Windows;%TEMP%\v313\Scripts
  pip install numpy C:\liw_build\wheels\pylibtiff-*cp313*.whl
  python -I windows\check_wheels.py pylibtiff
  ```
- `launcher.c` -- the stand-in for the bundled tools (see the section
  above); compiled by `build_wheels.ps1`.
- `install_msvc.py` -- the no-installer MSVC + Windows SDK install (see
  the toolchain section); run by `build_wheels.ps1` with the patch
  python, never by hand in the normal flow.
- `dev_setup.ps1` -- rebuilds a development environment after an agent
  sandbox reset: `build_wheels.ps1 -WarmCache` in dev mode (the pinned
  toolchain and pythons under `C:\liw_build`) plus the extras the build
  itself does not need (`requests`/`packaging` for `check_versions.py`).
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
powershell -File windows\sandbox_build.ps1 -Command cache     # pre-warm the download cache
powershell -File windows\sandbox_build.ps1 -Packages pylibtiff
powershell -File windows\sandbox_build.ps1 -Pythons 3.12,3.13 -MemoryMB 8192
powershell -File windows\test_via_sandbox.ps1 -Pythons 3.13
```

The same two runs without the launchers (no agent-authored code on the
host; the `.wsb` files are data): create the writable folders, check the
`HostFolder` paths once, open the `.wsb`, and watch the log:

```
mkdir wheels windows\cache windows\run windows\test_run
start windows\build.wsb
powershell -Command "Get-Content windows\run\build.log -Wait"
# when windows\run\exit_code appears (0 or 1), the wheels are in wheels\
# and the sandbox shuts down shortly after; then
start windows\test.wsb
powershell -Command "Get-Content windows\test_run\test.log -Wait"
# the result is windows\test_run\report.txt and exit_code
```

Remember that only one sandbox instance may run at a time -- the agent
session is itself a sandbox, so it must be closed before a run -- that
closing the watching console does not stop a run, and that a run
interrupted at the host leaves its sandbox running until it is closed.

### Dev mode (the agent sandbox, or any checkout)

```
# once per sandbox (after a reset): toolchain + pythons under C:\liw_build
powershell -File windows\dev_setup.ps1

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
  sandbox reset; `dev_setup.ps1` brings it back).  All durable knowledge
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

Work in progress (2026-10-28).  No build or test sandbox has run on a
host yet (the early host attempts were blocked by the single-instance
rule while the agent session was running; see the hard-won list).  The
pipeline has been exercised in dev mode inside the agent sandbox:

- `dev_setup.ps1` / `build_wheels.ps1 -WarmCache` installs the pinned
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
- `test_wheels.ps1` in dev mode passes every check for all seven
  pythons against those wheels (2026-10-28): the exact-version install,
  `check_wheels.py` (import audit, bundled DLL identity, tools by
  wrapper and by path with a bare PATH, codec writes), the shared
  `test/test_script.sh`, and `check_wheels.py` in the suite's venv.  The
  free-threaded import carries the GIL re-enable `RuntimeWarning` the
  linux and macos wheels also show.

Next step: the first host run, `windows\sandbox_build.bat &&
windows\test_via_sandbox.bat` (transfer the tip, end the agent session,
run, send back `windows\run\build.log`, `windows\test_run\
report.txt` and `test.log`).  Only after pylibtiff is verified end to
end does Glymur start.

Known gaps, in rough order:

- Wheel timestamp reproducibility (linux uses strip-nondeterminism +
  advzip; macos accepts delocate's output): not yet implemented; the
  macos `normalize_zips.py` approach is the candidate.
- The guest-initiated shutdown (`shutdown /s /t 5` issued by the
  in-sandbox scripts after the exit code) is desk-checked only; if a
  sandbox does not close itself when the run ends, close the window by
  hand and record the finding here.
- The host build has passed once (2026-10-28, cli backend): a fresh
  sandbox installed the toolchain, built the chain and all seven
  pylibtiff wheels, exit code 0.  The host test run got through python
  3.11's install and `check_wheels.py` (all ok, 47 files audited) and
  then stopped without an exit code where the shared suite starts; the
  launcher's own console output is the missing evidence (it either
  declared the run dead -- `wsb exec` returning early, or a `wsb list`
  hiccup -- and stopped the sandbox, which the launcher no longer does:
  it now trusts only the exit marker, tolerates `wsb exec` returning,
  requires three missed `wsb list` polls, gives up only after 30 silent
  minutes or the timeout, and leaves a failed sandbox running for
  inspection).  `test_wheels.ps1` now logs a line before starting bash.
- The C++ packages to come (pyvips, GDAL, mapnik) will import
  `msvcp140.dll` (delvewheel bundles it from the redist directory that
  `--add-path` names) and `vcruntime140_1.dll` (which delvewheel leaves
  out like `vcruntime140.dll`; add it to `--include` when the import
  audit reports it).
- `test/test_script.sh` still writes `/tmp/outfloat.tiff` in its
  GDAL+pyvips section; python on Windows reads that as `C:\tmp\...`.
  Adjust when that section is reached.
- `check_versions.py` runs the `git` entries through `timeout`, which is
  Windows' timeout.exe here; run it on linux (its normal home), or check
  the windows entries by name (`delvewheel`, `git-for-windows`, `msvc`,
  `nasm`, `winsdk` resolve on Windows).

## Hard-won details (do not lose these)

- The `.wsb` LogonCommand runs as the **elevated** WDAGUtilityAccount
  (file backend); `wsb exec -r System` runs the script as SYSTEM (cli
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
  `liblzma.dll`, `tiff.dll`.  libtiff's `tiffconf.h` records JBIG as a
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
  a build run.  sandbox_build.ps1 refuses to start while any sandbox is
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
