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
  (`liw_wheels\cache`, a sibling of the repository, mapped read-write).
  It holds portable toolchain
  downloads (PortableGit, cmake, ninja, nasm, python.org NuGet packages,
  the VS Build Tools bootstrapper) so a run does not re-download
  multi-GB toolchains.  The cache must never contain build outputs,
  stamps, or anything that could make one run's result depend on a
  previous run; it is the analog of docker layer cache, not of a base
  image.  Verification policy, as on macos: full builds from a fresh
  sandbox; the cache is only ever a source of upstream artifacts.
- Every build starts from a pristine sandbox: the sandbox's own installed
  software is by construction empty (Windows Sandbox is a disposable VM),
  and nothing from the host is visible except the four mapped folders
  (repo read-only; cache, wheels, run read-write).

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
two roles: this agent session runs inside one sandbox (the agent safety
boundary), and a second, fresh sandbox does the build (the library
isolation boundary).  Because Windows Sandbox cannot be nested, the
agent cannot start the build sandbox itself; a human starts it from the
host.  The checked-in `windows\build.wsb` is data, not code: four folder
mappings and one LogonCommand line, meant to be read once by a human,
adjusted for host paths, and then opened directly.  The human's entire
host workflow is reading the build log and the exit-code file, which
needs only their own commands.  `sandbox_build.ps1` is an optional
convenience launcher, not a requirement; treat it as frozen
infrastructure -- audited once, changed only with care, since running it
executes it on the host.

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

- VS Build Tools cannot be installed into the cache (it installs into
  `C:\Program Files`), so every build run pays the install time.  The
  payload is cached as a pinned offline `--layout`
  (`liw_wheels\cache\downloads\vs_layout`, built once by
  `-Command cache`), so later runs install offline from the cache and
  stay pinned to the VS version the layout was built with; without a
  layout, runs fall back to the bootstrapper-from-net (which pins
  nothing).
- NASM (libjpeg-turbo/libwebp SIMD) and perl (openssl/curl TLS, later
  GDAL work) must be provided separately; both are portable and live in
  the cache.

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
openslide_python, pyvips, GDAL, mapnik, and javabridge/bioformats.
pylibmc goes last deliberately: it is the least important wheel, and
libmemcached has no MSVC support story, so it will need real patching
work.  javabridge needs a JVM strategy on Windows; the linux build's
java packaging is the reference, and a portable JDK zip staged in the
cache is the likely starting point.

## Files

- `build.wsb` -- the sandbox configuration, checked in as data: the four
  mapped folders (repo read-only at `C:\mnt\repo`; cache, wheels, and the
  per-run exchange at `C:\mnt\cache`, `C:\mnt\wheels`, `C:\mnt\run`
  read-write, all from a `liw_wheels` sibling of the repository) and the
  LogonCommand that runs `windows\build_wheels.ps1`.  The `HostFolder`
  paths are host-specific; adjust them once, then open the file to start
  a build.  Only one sandbox may run at a time.
- `sandbox_build.ps1` -- optional host-side convenience launcher
  (agent-authored; audit before trusting).  It performs the same checks
  and uses the same folder layout as `build.wsb`, generates an equivalent
  `.wsb`, starts the sandbox, streams the in-sandbox build log, waits for
  the exit marker, validates that every requested package produced a
  wheel for every requested python, and reports.  Commands:
  - `sandbox_build.ps1` -- full build (default; `pylibtiff` only so far).
  - `sandbox_build.ps1 -Command cache` -- pre-warm the download cache in
    a throwaway sandbox (toolchains, pythons, and the pinned VS offline
    layout).
- `build_wheels.ps1` -- the in-sandbox monolithic build, the counterpart
  of the monolithic Dockerfile (and of `macos/build_wheels.sh`).  Run by
  the `.wsb` LogonCommand as the elevated sandbox account; it can also be
  run directly inside an open sandbox for debugging.  It takes its
  parameters from `C:\mnt\run\args.json` when the launcher wrote one and
  from built-in defaults otherwise (the source is logged), writes its log
  to `C:\mnt\run\build.log`, and its exit code to `C:\mnt\run\exit_code`.
  It clears both markers at startup, so a persistent run folder works
  across runs.
- `macos/README.md` -- the macos branch's notes; its process lessons
  (verify edits before committing, stage work behind checkpoint runs,
  assert every optional dependency, full fresh builds for verification)
  apply here unchanged.

## Usage

The human-only host workflow (no agent-authored code runs on the host);
Windows 10/11 with the Windows Sandbox feature enabled:

```
# once: create the three writable folders the .wsb maps (the paths must
# match build.wsb; a liw_wheels sibling of the repository by convention)
mkdir C:\misc\liw_wheels\cache C:\misc\liw_wheels\run C:\misc\liw_wheels\wheels

# once: check the four HostFolder paths in windows\build.wsb

# every build: start the sandbox and watch the log with your own console
start windows\build.wsb
powershell -Command "Get-Content C:\misc\liw_wheels\run\build.log -Wait"

# when C:\misc\liw_wheels\run\exit_code appears (0 or 1), the sandbox
# shuts itself down shortly after; the wheels are in
# C:\misc\liw_wheels\wheels
```

Remember that only one sandbox instance may run at a time -- the agent
session is itself a sandbox, so it must be closed before a build run --
that closing the watching console does not stop the build, and that a
run interrupted at the host leaves its sandbox running until it is
closed.

The convenience launcher automates the same steps (it is agent-authored
code, so audit it before trusting it):

```
# pre-warm the download cache (optional; happens on demand otherwise)
powershell -File windows\sandbox_build.ps1 -Command cache

# full isolated build (sandbox, toolchain, build, wheels in liw_wheels\wheels)
powershell -File windows\sandbox_build.ps1

# build a single package
powershell -File windows\sandbox_build.ps1 -Packages pylibtiff

# choose pythons and memory
powershell -File windows\sandbox_build.ps1 -Pythons 3.12,3.13 -MemoryMB 8192
```

The sandbox shuts itself down at the end of every run, success or
failure, as on macos: the log is already out (streamed to the watching
console and saved in the run folder), so there is no virtue in keeping
the build environment alive -- and it holds the single-instance slot.
If a guest-initiated shutdown is ever refused (a first-run property to
verify), close the window by hand; never taskkill, which is
indiscriminate and could hit the agent sandbox.

## Iteration protocol

The development loop, as practiced on the macos branch and adapted here
for the single-instance limit:

1. The agent (inside the agent sandbox) makes a change, verifies what it
   can locally (syntax parses, desk checks against the linux Dockerfile
   and the macos builders), and commits.
2. The human transfers the commit out of the agent sandbox and applies it
   to the host checkout.
3. The human ends the agent sandbox (only one Windows Sandbox instance
   is allowed, and the agent session is one), then runs the build by
   opening `windows\build.wsb`.
4. The human copies the build log (`liw_wheels\run\build.log`) into the
   agent sandbox and restarts the agent session.
5. The agent diagnoses from the log, fixes, commits; repeat until the
   build passes, then the same loop with test failure logs until the
   tests pass.

Consequences to design around:

- The agent never sees a build run.  The log is the only feedback
  channel, so `build_wheels.ps1` must stay self-diagnosing: name the
  failing step, log the failing command and its exit code, and fail at
  the first problem instead of continuing past it.
- A restarted agent session may be a fresh context with none of the
  previous session's temp files.  All durable knowledge lives in
  committed files only -- this README (status and hard-won list), the
  scripts, and the build log the human passes in.  Never rely on session
  scratch state surviving a restart.
- Each iteration costs a full sandbox run (toolchain install included),
  so batch fixes: verify everything verifiable before ending the
  session.

## Resuming with no prior context

If you are a fresh agent instance resuming this work:

1. Read this file top to bottom.
2. Read `git log --oneline -20` on the windows branch to see what changed
   since the state the status section describes.
3. Get the latest build log from the human (it lives at
   `liw_wheels\run\build.log` on the host; the transfer is a copy into
   one of the agent sandbox's mapped folders).  Errors are logged as
   `error: ...` with the failing script line, and the failing step is
   named in the preceding `=== <step>` line.
4. Diagnose against the log, fix, commit, and hand the commit back for
   the next transfer.

## Status

Work in progress (2026-10-19).  No build sandbox has run yet: the early
host attempts were blocked by the single-instance rule while the agent
session was running (see the hard-won list).  Next step: the first real
build run -- transfer the current tip to the host checkout, end the
agent session, open `windows\build.wsb`, and watch
`liw_wheels\run\build.log`; the first run is expected to surface the
risks listed below.  The scripts were
written against the dockerfile recipes, the macos builders, and the
platform properties documented in the agent sandbox code; host runs must
be done by hand with the agent session closed, and the findings belong
in the hard-won list below.

Expected first-run risks, in rough order:

- libtiff's cmake jbig detection on Windows (the explicit
  `-DJBIG_LIBRARY`/`-DJBIG_INCLUDE_DIR` cache variables and the
  tiffconf.h feature assertion exist for this; verify the variable names
  against the checked-out libtiff's CMakeLists if configure ignores them).
- jbigkit has no MSVC build system; `build_jbigkit` compiles its two
  translation units with `cl` directly.  Any header errors surface here.
- DLL output names produced by each project's cmake on Windows (zlib1.dll,
  libzstd.dll, jpeg62.dll, libwebp*.dll, libdeflate.dll, tiff.dll vs
  libtiff.dll) are asserted but were written from knowledge, not from a
  run; fix the assertions to reality and record the names below.
- delvewheel's repaired-wheel layout (`.libs` directory name, its
  `_delvewheel_patch` insertion point in `libtiff/__init__.py`) must be
  confirmed against the version pinned in the cache.
- Free-threaded python availability as NuGet packages is unverified; the
  default pythons are 3.11-3.15 without free-threaded variants until
  checked.
- Wheel timestamp reproducibility (linux uses strip-nondeterminism +
  advzip; macos accepts delocate's output): not yet implemented.
- The guest-initiated shutdown (`shutdown /s /t 5` issued by the
  in-sandbox script after the exit code) is desk-checked only; if a
  sandbox does not close itself when the run ends, close the window by
  hand and record the finding here.

## Hard-won details (do not lose these)

- The `.wsb` LogonCommand runs as the **elevated** WDAGUtilityAccount
  (confirmed from the agent sandbox code's file-backend path), so
  installers and machine-wide changes need no UAC handling.  Verify on
  the first run.
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
