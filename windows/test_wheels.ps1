# test_wheels.ps1 - verify the Windows wheels INSIDE a fresh Windows Sandbox
# (started on the host by windows\sandbox_run.ps1 test); the counterpart
# of the in-VM part of macos/test_via_tart.sh.
#
# A fresh sandbox has nothing installed -- no VC++ redistributable, no
# library of any kind -- so a wheel that works here brings everything it
# needs.  For every requested python this script:
#
#   1. installs the wheels into a clean venv by exact version, with the
#      wheel folder as the only extra source (a pypi fallback would show
#      up as a version mismatch), as test_via_tart.sh does;
#   2. runs check_wheels.py (embedded below) in that venv with a scrubbed
#      PATH (the PE import audit, the loaded-DLL identity, the bundled
#      tools through their wrappers and by path with a bare PATH);
#   3. runs the shared functional suite, test\test_script.sh -- the same
#      script the linux containers and the macos VM run -- under
#      PortableGit's bash with a scrubbed PATH and the python under test,
#      and runs check_wheels.py in the venv that suite created as well.
#
# Mapped folders (from sandbox_run.ps1):
#   C:\mnt\repo     the repository (read-only)
#   C:\mnt\wheels   the wheels to test (read-only)
#   C:\mnt\cache    the download cache (read-write; the pythons, PortableGit
#                   and, under test_files, the suite's sample downloads)
#   C:\mnt\run      per-run exchange (read-write; test.log, report.txt,
#                   args.json, exit_code)
#
# Dev mode: without the C:\mnt\repo mapping (the agent sandbox, or any
# checkout) the repository is this script's parent directory, the wheels
# are C:\liw_build\wheels, the run folder is C:\liw_build\test_run, the
# build's pythons and PortableGit under C:\liw_build are reused, and the
# venvs live in C:\liw_build\test.  Dev runs rehearse the harness; the
# verification is always the fresh sandbox.
#
# Parameters / environment (parameters win, then LIW_PYTHONS, then
# C:\mnt\run\args.json, then the default):
#   -Pythons      python versions to test (default 3.11-3.15, 3.14t, 3.15t)
#
# Every check is one "OK:" or "FAIL:" line in <run>\report.txt (and in the
# log); the exit code (0 when every check passed, 1 otherwise) goes to
# <run>\exit_code.  The sandbox shuts itself down afterwards (not in dev
# mode).

param(
    [string[]]$Pythons = @()
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --------------------------------------------------------------------------
# Layout.
# --------------------------------------------------------------------------

$LIW_BUILD = if ($env:LIW_BUILD) { $env:LIW_BUILD } else { 'C:\liw_build' }
$script:DevMode = -not (Test-Path 'C:\mnt\repo\windows\test_wheels.ps1')
if ($script:DevMode) {
    $RepoDir = Split-Path -Parent $PSScriptRoot
    $WheelsDir = Join-Path $LIW_BUILD 'wheels'
    $RunDir = Join-Path $LIW_BUILD 'test_run'
    $CacheDir = Join-Path $LIW_BUILD 'cache'
    $TestRoot = Join-Path $LIW_BUILD 'test'
    $LIW_PY = Join-Path $LIW_BUILD 'python'
    $LIW_TOOLS = Join-Path $LIW_BUILD 'tools'
} else {
    $RepoDir = 'C:\mnt\repo'
    $WheelsDir = 'C:\mnt\wheels'
    $RunDir = 'C:\mnt\run'
    $CacheDir = 'C:\mnt\cache'
    # Sandbox-local disk: mapped folders are slow, and the venvs are large.
    $TestRoot = 'C:\liw_test'
    $LIW_PY = Join-Path $TestRoot 'python'
    $LIW_TOOLS = Join-Path $TestRoot 'tools'
}
$LIW_DL = Join-Path $TestRoot 'dl'
foreach ($dir in @($RunDir, $TestRoot, $LIW_PY, $LIW_TOOLS, $LIW_DL)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}
$LogPath = Join-Path $RunDir 'test.log'
$ExitCodePath = Join-Path $RunDir 'exit_code'
$ReportPath = Join-Path $RunDir 'report.txt'

# Parameter values first (at the top level of a script the parameters are
# script-scope variables, which the defaults below would overwrite).
$paramPythons = @($Pythons | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$script:Pythons = @('3.11', '3.12', '3.13', '3.14', '3.15', '3.14t', '3.15t')
$script:ArgsSource = 'defaults'
$argsFile = Join-Path $RunDir 'args.json'
if (Test-Path $argsFile) {
    $runArgs = Get-Content $argsFile -Raw | ConvertFrom-Json
    if ($runArgs.pythons) { $script:Pythons = @($runArgs.pythons) }
    $script:ArgsSource = 'args.json'
}
if ($env:LIW_PYTHONS) {
    $script:Pythons = $env:LIW_PYTHONS -split '\s+'
    $script:ArgsSource = 'LIW_PYTHONS'
}
if ($paramPythons.Count -gt 0) {
    $script:Pythons = $paramPythons
    $script:ArgsSource = 'parameters'
}
foreach ($name in @('exit_code', 'test.log', 'report.txt')) {
    Remove-Item -Path (Join-Path $RunDir $name) -Force -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------------------
# Logging, downloads, pythons, PortableGit: this script's own copies of
# the helpers build_wheels.ps1 has (the two in-sandbox scripts are
# self-contained, as the macos scripts are; the rationale for each detail
# is in build_wheels.ps1, and a change to one belongs in both).
# --------------------------------------------------------------------------

function Append-Line([string]$Path, [string]$Line) {
    for ($n = 1; $n -le 50; $n++) {
        try {
            [System.IO.File]::AppendAllText($Path, "$Line`r`n", [System.Text.UTF8Encoding]::new($false))
            return
        } catch {
            Start-Sleep -Milliseconds 100
        }
    }
    Write-Host "(could not append to $Path)"
}

function Log([string]$Message) {
    Write-Host $Message
    Append-Line $LogPath $Message
}

function Die([string]$Message) {
    Log "error: $Message"
    throw "liw: $Message"
}

function Assert-Exit([string]$What) {
    if ($LASTEXITCODE -ne 0) {
        Die "$What failed (exit code $LASTEXITCODE)"
    }
}

# A pin from the shared versions.txt through getver.py (run from the
# repository root, with the patch python).
function V([string]$Name, [string[]]$Extra = @()) {
    if (-not $script:PatchPython) {
        Die 'V() called before the pythons were installed'
    }
    Push-Location $RepoDir
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = (& $script:PatchPython (Join-Path $RepoDir 'getver.py') $Name @Extra |
                Out-String).Trim()
    } finally {
        Pop-Location
        $ErrorActionPreference = $prev
    }
    if (-not $out) {
        Die "getver.py returned nothing for $Name (check versions.txt)"
    }
    return $out
}

# A download into the persistent cache (upstream artifacts only), under a
# temporary name until it succeeds, with every curl error retried.
function Fetch([string]$Url, [string]$Name) {
    $downloads = Join-Path $CacheDir 'downloads'
    New-Item -ItemType Directory -Force -Path $downloads | Out-Null
    $dest = Join-Path $downloads $Name
    if (Test-Path $dest) {
        Log "cached: $Name"
        return $dest
    }
    Log "downloading $Url"
    $part = "$dest.part"
    Remove-Item -Path $part -Force -ErrorAction SilentlyContinue
    & curl.exe --retry 8 --retry-delay 5 --retry-all-errors --silent --show-error `
        --location --fail $Url -o $part
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -Path $part -Force -ErrorAction SilentlyContinue
        Die "download failed (curl exit code $LASTEXITCODE): $Url"
    }
    Move-Item -Path $part -Destination $dest -Force
    return $dest
}

function Expand-Zip([string]$Zip, [string]$Dest) {
    # Expand-Archive insists on a .zip extension.
    $zipPath = $Zip
    if (-not $zipPath.EndsWith('.zip')) {
        $zipPath = "$Zip.zip"
        Copy-Item $Zip $zipPath -Force
    }
    if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
    try {
        Expand-Archive -Path $zipPath -DestinationPath $Dest
    } catch {
        # A corrupt download must not stay in the cache.
        Remove-Item -Path $Zip, $zipPath -Force -ErrorAction SilentlyContinue
        Die "cannot expand $Zip (removed from the cache; rerun to download it again): $($_.Exception.Message)"
    }
}

function Get-Json([string]$Url) {
    return Invoke-RestMethod -Uri $Url -Headers @{
        'User-Agent' = 'large_image_wheels'
    }
}

# Run a native command with its output streamed into the log (stderr
# redirection must not be a terminating error, so the preference is
# relaxed).  Returns the exit code with -NoDie instead of dying on a
# nonzero one.
function Run-Logged([string]$Exe, [string[]]$CmdArgs, [string]$What, [switch]$NoDie) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Exe @CmdArgs 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                Log "$($_.Exception.Message)"
            } else {
                Log "$_"
            }
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($NoDie) { return $code }
    if ($code -ne 0) { Die "$What failed (exit code $code)" }
}

# The python.org NuGet pythons, one directory per requested version under
# $LIW_PY (a trailing t selects the python-freethreaded package); the
# newest requested stable one is the patch python that runs getver.py.
function Ensure-Pythons {
    $indexes = @{}
    foreach ($minor in $script:Pythons) {
        $dest = Join-Path $LIW_PY $minor
        if (Test-Path (Join-Path $dest 'python.exe')) { continue }
        $package = if ($minor.EndsWith('t')) { 'python-freethreaded' } else { 'python' }
        $base = $minor.TrimEnd('t')
        if (-not $indexes.ContainsKey($package)) {
            $indexes[$package] = Get-Json "https://api.nuget.org/v3-flatcontainer/$package/index.json"
        }
        $candidates = @($indexes[$package].versions |
            Where-Object { $_ -like "$base.*" -and $_ -notmatch '[a-z-]' })
        if ($candidates.Count -eq 0) {
            Die "no stable python $minor ($package) on nuget.org"
        }
        $full = $candidates | Sort-Object { [version]$_ } | Select-Object -Last 1
        Log "installing python $minor ($package $full)"
        $file = Fetch "https://api.nuget.org/v3-flatcontainer/$package/$full/$package.$full.nupkg" "$package-$full.nupkg.zip"
        Expand-Zip $file (Join-Path $LIW_DL "$package-$full")
        if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
        Move-Item (Join-Path $LIW_DL "$package-$full\tools") $dest
        if (-not (Test-Path (Join-Path $dest 'python.exe'))) {
            # The free-threaded package names its interpreter python3.14t.exe.
            $exe = Get-ChildItem -Path $dest -Filter 'python3*t.exe' -File | Select-Object -First 1
            if (-not $exe) { Die "no python.exe in the $package $full package" }
            Copy-Item $exe.FullName (Join-Path $dest 'python.exe')
        }
        & (Join-Path $dest 'python.exe') -m ensurepip --upgrade | Out-Null
        Assert-Exit "ensurepip failed for python $full"
        & (Join-Path $dest 'python.exe') -m pip install --quiet `
            --no-warn-script-location --upgrade pip setuptools wheel | Out-Null
        Assert-Exit "pip bootstrap failed for python $full"
    }
    $best = $null
    foreach ($minor in $script:Pythons) {
        if ($minor.EndsWith('t')) { continue }
        $candidate = Join-Path $LIW_PY "$minor\python.exe"
        if (Test-Path $candidate) {
            if (-not $best -or
                ([version]($minor) -gt [version]($best))) {
                $best = $minor
            }
        }
    }
    if (-not $best) { Die 'no stable python was installed (the patch python must not be free-threaded)' }
    $script:PatchPython = Join-Path $LIW_PY "$best\python.exe"
    Log "patch python: $script:PatchPython"
}

# PortableGit, for bash (the pin is the release tag without its v; the
# asset name drops a .windows.1 build number).  Returns its directory.
function Ensure-PortableGit {
    $gitVersion = V 'git-for-windows'
    $gitDir = Join-Path $LIW_TOOLS 'git'
    if (-not (Test-Path (Join-Path $gitDir "bin\bash.exe"))) {
        Log "fetching PortableGit $gitVersion"
        $tag = "v$gitVersion"
        $assetVersion = ($gitVersion -replace '\.windows\.1$', '') -replace '\.windows\.', '.'
        $asset = "PortableGit-$assetVersion-64-bit.7z.exe"
        $file = Fetch "https://github.com/git-for-windows/git/releases/download/$tag/$asset" $asset
        if (Test-Path $gitDir) { Remove-Item -Recurse -Force $gitDir }
        $proc = Start-Process -FilePath $file `
            -ArgumentList "-o `"$gitDir`" -y" -Wait -PassThru
        if ($proc.ExitCode -ne 0) { Die 'PortableGit extraction failed' }
        if (-not (Test-Path (Join-Path $gitDir 'bin\bash.exe'))) {
            Die 'bash.exe missing after PortableGit extraction'
        }
    }
    return $gitDir
}

# A Windows path in the POSIX form PortableGit's bash uses (C:\a\b ->
# /c/a/b).
function To-PosixPath([string]$Path) {
    $p = $Path -replace '\\', '/'
    if ($p -match '^([A-Za-z]):(.*)$') {
        return '/' + $Matches[1].ToLower() + $Matches[2]
    }
    return $p
}

# No python environment may leak into the venvs under test.
foreach ($name in @('PYTHONPATH', 'PYTHONHOME', 'PYTHONUSERBASE',
                    'PYTHONSTARTUP', 'PYTHONUTF8', 'VIRTUAL_ENV',
                    'CONDA_PREFIX', 'PIP_CONFIG_FILE')) {
    Remove-Item -Path "env:$name" -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------------------
# Reporting.
# --------------------------------------------------------------------------

$script:Failures = 0

function Note([string]$Message) {
    Log $Message
    Append-Line $ReportPath $Message
}

function Check([bool]$Ok, [string]$Message) {
    if ($Ok) { Note "OK: $Message" } else { Note "FAIL: $Message" }
    if (-not $Ok) { $script:Failures++ }
}

# Output of a native command as one string, stderr included, without the
# redirection becoming a terminating error.
function Capture([string]$Exe, [string[]]$CmdArgs) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        return (& $Exe @CmdArgs 2>&1 | Out-String)
    } finally {
        $ErrorActionPreference = $prev
    }
}

# --------------------------------------------------------------------------
# Wheels.
# --------------------------------------------------------------------------

# Every package the pipeline builds, wheel file prefix -> pip name.  A
# package whose wheel is absent is skipped (the host launcher validated
# that every requested package produced its wheels; an absent one here
# was not requested).  pylibtiff is required: it is in every build.
$script:Dists = [ordered]@{
    'pylibtiff' = 'pylibtiff'
    'Glymur' = 'Glymur'
    'openslide_python' = 'openslide-python'
    'pylibmc' = 'pylibmc'
    'pyvips' = 'pyvips'
    'GDAL' = 'gdal'
    'mapnik' = 'mapnik'
    'python_javabridge' = 'python-javabridge'
    'python_bioformats' = 'python-bioformats'
}

# The wheel of a distribution that the given python installs (same tag
# rules as sandbox_run.ps1's validation), or $null.
function Find-Wheel([string]$Dist, [string]$Req) {
    $base = $Req.TrimEnd('t')
    $num = $base -replace '\.', ''
    $patterns = @("$Dist-*-py3-none-any.whl", "$Dist-*-py3-none-win_amd64.whl")
    if ($Req.EndsWith('t')) {
        $patterns += @("$Dist-*-cp$num-cp${num}t-win_amd64.whl",
                       "$Dist-*-cp$num-abi3.abi3t-win_amd64.whl",
                       "$Dist-*-cp$num-abi3t-win_amd64.whl")
    } else {
        $patterns += "$Dist-*-cp$num-cp$num-win_amd64.whl"
        foreach ($b in @('310', '311', '312', '313', '314', '315')) {
            if ([int]$b -le [int]$num) { $patterns += "$Dist-*-cp$b-abi3-win_amd64.whl" }
        }
    }
    foreach ($pattern in $patterns) {
        $found = @(Get-ChildItem -Path $WheelsDir -Filter $pattern -File `
            -ErrorAction SilentlyContinue)
        if ($found.Count -gt 0) { return $found[0] }
    }
    return $null
}

function Wheel-Version([string]$Name, [string]$Dist) {
    if ($Name -match "^$Dist-([^-]+)-") { return $Matches[1] }
    Die "cannot read the version of $Name"
}

# --------------------------------------------------------------------------
# check_wheels.py: the windows-specific wheel checks, run inside a venv
# that has the wheels installed (the counterpart of the macos harness's
# per-package checks in test_via_tart.sh; the shared test/test_script.sh
# is the functional suite and runs separately).
#
# For each package that is installed, this verifies the isolation
# properties the pipeline exists for:
#
# - every executable file our wheel provides (.pyd, .dll, .exe in the
#   package and in its <dist>.libs directory) imports only DLLs that are
#   in the wheel, python's own DLL, Windows API sets, or DLLs present in
#   the system directory -- the counterpart of the macos otool audit, read
#   from the PE import tables, so even a tool nobody runs is checked;
# - the library the package loads is the copy bundled in the wheel's
#   <dist>.libs directory (resolved through the running process's module
#   list, not through what the package claims);
# - the bundled command line tools run through their console-script
#   wrappers, and run by path (<package>/bin/<tool>.exe, the launcher)
#   with nothing but the system directories on PATH -- so neither
#   python's directory nor anything else installed supplies a DLL to them.
#
# Usage: python -I check_wheels.py [package ...]   (default: every known
# package that is importable).  Exit status is nonzero on any failure;
# every check prints one line, "ok: ..." or "FAIL: ...".
#
# The caller is responsible for the environment: run it with a scrubbed
# PATH (system directories plus the venv only) so a stray directory on
# PATH cannot shadow a bundled DLL -- there is no rpath on Windows, and a
# same-named DLL earlier on PATH is the one way a system library could
# win.  The system-directory allowance in the import audit is what the
# machine running the check has in System32; in a fresh Windows Sandbox
# that is the baseline every Windows has.  This script writes it to the
# test root (C:\liw_build\test\check_wheels.py in dev mode), where it can
# also be run by hand.
# --------------------------------------------------------------------------

$script:CheckWheelsSource = @'
import ctypes
import ctypes.wintypes
import os
import re
import struct
import subprocess
import sys
import tempfile

failures = 0

SYSTEM_DIRS = [os.path.join(os.environ.get('SystemRoot', r'C:\Windows'), 'System32')]


def report(ok, message):
    global failures
    print(('ok: ' if ok else 'FAIL: ') + message, flush=True)
    if not ok:
        failures += 1


def loaded_modules():
    """Paths of every module loaded in this process (EnumProcessModules)."""
    psapi = ctypes.windll.psapi
    kernel32 = ctypes.windll.kernel32
    # Explicit signatures: without them ctypes passes the 64-bit
    # pseudo-handle and module handles as 32-bit ints.
    kernel32.GetCurrentProcess.restype = ctypes.wintypes.HANDLE
    psapi.EnumProcessModules.argtypes = [
        ctypes.wintypes.HANDLE, ctypes.POINTER(ctypes.wintypes.HMODULE),
        ctypes.wintypes.DWORD, ctypes.POINTER(ctypes.wintypes.DWORD)]
    psapi.EnumProcessModules.restype = ctypes.wintypes.BOOL
    psapi.GetModuleFileNameExW.argtypes = [
        ctypes.wintypes.HANDLE, ctypes.wintypes.HMODULE, ctypes.wintypes.LPWSTR,
        ctypes.wintypes.DWORD]
    psapi.GetModuleFileNameExW.restype = ctypes.wintypes.DWORD
    process = kernel32.GetCurrentProcess()
    count = 4096
    while True:
        handles = (ctypes.wintypes.HMODULE * count)()
        needed = ctypes.wintypes.DWORD()
        if not psapi.EnumProcessModules(process, handles, ctypes.sizeof(handles),
                                        ctypes.byref(needed)):
            raise OSError(f'EnumProcessModules failed: {ctypes.GetLastError()}')
        found = needed.value // ctypes.sizeof(ctypes.wintypes.HMODULE)
        if found <= count:
            break
        count = found
    paths = []
    for handle in handles[:found]:
        buffer = ctypes.create_unicode_buffer(32768)
        psapi.GetModuleFileNameExW(process, ctypes.wintypes.HMODULE(handle), buffer,
                                   len(buffer))
        paths.append(buffer.value)
    return paths


def loaded_from_libs(stem, libs_dir_name, libs_path=None):
    """The loaded modules whose basename starts with <stem> (delvewheel
    mangles names to <stem>-<hash>.dll, so a prefix match is the lookup):
    all of them, the ones in the <libs_dir_name> directory, and the ones
    outside any wheel's .libs directory.  Several of our wheels may bundle
    the same library (identical content gets the same mangled name), and
    a full-path load of each is a separate module, so a copy in another
    wheel's .libs directory is legitimate; a copy anywhere else means a
    system or third-party library won the load.  libs_path names the
    library directory by path instead, for a wheel whose bundled DLLs
    are not in a .libs directory (pylibmc's are in site-packages)."""
    # (DLLs only: mapnik's gdal+ogr.input plugin, loaded from the mapnik
    # package directory, would otherwise count as a foreign libgdal.)
    hits = [path for path in loaded_modules()
            if os.path.basename(path).lower().startswith(stem.lower())
            and path.lower().endswith('.dll')]
    if libs_path:
        def in_libs(path):
            return os.path.normcase(os.path.dirname(os.path.abspath(path))) == \
                os.path.normcase(os.path.abspath(libs_path))
    else:
        def in_libs(path):
            return os.path.basename(os.path.dirname(path)).lower() == libs_dir_name.lower()
    bundled = [path for path in hits if in_libs(path)]
    foreign = [path for path in hits
               if not in_libs(path)
               and not os.path.basename(os.path.dirname(path)).lower().endswith('.libs')]
    return hits, bundled, foreign


def pe_imports(path):
    """The DLL names in a PE file's import directory (None if the file is
    not a PE image).  Delay-load imports are not included: delvewheel
    leaves msvcp140's delay-load of concrt140 alone on purpose."""
    with open(path, 'rb') as fptr:
        data = fptr.read()
    if data[:2] != b'MZ':
        return None
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    if data[pe:pe + 4] != b'PE\0\0':
        return None
    coff = pe + 4
    nsections, opt_size = struct.unpack_from('<H', data, coff + 2)[0], \
        struct.unpack_from('<H', data, coff + 16)[0]
    opt = coff + 20
    magic = struct.unpack_from('<H', data, opt)[0]
    if magic == 0x20b:
        datadir = opt + 112
    elif magic == 0x10b:
        datadir = opt + 96
    else:
        raise ValueError('unknown optional header magic 0x%x' % magic)
    import_rva = struct.unpack_from('<I', data, datadir + 8)[0]
    sections = []
    table = opt + opt_size
    for index in range(nsections):
        vsize, vaddr, rawsize, rawptr = struct.unpack_from('<IIII', data, table + 40 * index + 8)
        sections.append((vaddr, max(vsize, rawsize), rawptr))

    def offset(rva):
        for vaddr, size, raw in sections:
            if vaddr <= rva < vaddr + size:
                return rva - vaddr + raw
        raise ValueError('rva 0x%x is in no section' % rva)

    names = []
    if import_rva:
        pos = offset(import_rva)
        while True:
            descriptor = struct.unpack_from('<IIIII', data, pos)
            if not any(descriptor):
                break
            start = offset(descriptor[3])
            names.append(data[start:data.index(b'\0', start)].decode('ascii', 'replace'))
            pos += 20
    return names


def audit_imports(roots, libs_dir, extra_dirs=()):
    """Every PE file under the given roots (directories, or single files)
    may import only: a file in its own directory, a file in libs_dir or
    one of extra_dirs, python's own DLL, a Windows API set, or a DLL in
    the system directory.  Anything else would resolve through PATH at
    best -- a system or third-party library winning the load -- and fail
    at worst."""
    bad = 0
    files = 0
    for root in roots:
        if os.path.isfile(root):
            walk = [(os.path.dirname(root), [], [os.path.basename(root)])]
        else:
            walk = os.walk(root)
        for dirpath, _, filenames in walk:
            for filename in filenames:
                # (.input: mapnik's plugins are DLLs by another name.)
                if not filename.lower().endswith(('.pyd', '.dll', '.exe', '.input')):
                    continue
                path = os.path.join(dirpath, filename)
                try:
                    imports = pe_imports(path)
                except Exception as exc:
                    report(False, f'cannot read the imports of {path}: {exc}')
                    bad += 1
                    continue
                if imports is None:
                    continue
                files += 1
                for name in imports:
                    low = name.lower()
                    if low.startswith(('api-ms-win-', 'ext-ms-')):
                        continue
                    if re.match(r'python3\d*t?\.dll$', low):
                        continue
                    # The VC runtime python ships beside itself (and has
                    # loaded) serves the modules python loads; a tool runs
                    # as its own process, where it does not.
                    if low in ('vcruntime140.dll', 'vcruntime140_1.dll') and \
                            not filename.lower().endswith('.exe') and \
                            os.path.exists(os.path.join(sys.base_prefix, name)):
                        continue
                    if os.path.exists(os.path.join(dirpath, name)):
                        continue
                    if libs_dir and os.path.exists(os.path.join(libs_dir, name)):
                        continue
                    if any(os.path.exists(os.path.join(extra, name)) for extra in extra_dirs):
                        continue
                    if any(os.path.exists(os.path.join(sysdir, name)) for sysdir in SYSTEM_DIRS):
                        continue
                    report(False, f'FORBIDDEN import: {path} -> {name}')
                    bad += 1
    report(bad == 0 and files > 0,
           f'import audit of {files} PE files under {", ".join(roots)}')


def scrubbed_env():
    """An environment whose PATH holds only the system directories: a tool
    run with it can find DLLs only beside itself (or where the launcher
    puts them)."""
    env = dict(os.environ)
    env['PATH'] = os.pathsep.join([SYSTEM_DIRS[0], os.path.dirname(SYSTEM_DIRS[0])])
    return env


def run_tool(name, args, env=None):
    """Run the console script <name> of the venv.  The file must exist
    under exactly that name: CreateProcess would also find a misnamed
    <name>.exe.exe (which a console script named "<tool>.exe" produces)."""
    exe = os.path.join(os.path.dirname(sys.executable), name + '.exe')
    if not os.path.exists(exe):
        return 127, f'no console script {exe}'
    proc = subprocess.run([exe] + args, capture_output=True, text=True, env=env)
    return proc.returncode, proc.stdout + proc.stderr


def run_path(exe, args, env=None):
    proc = subprocess.run([exe] + args, capture_output=True, text=True, env=env)
    return proc.returncode, proc.stdout + proc.stderr


def check_pylibtiff(package_dir, libs_dir):
    from libtiff import TIFF

    hits, bundled, foreign = loaded_from_libs('tiff', os.path.basename(libs_dir))
    report(bool(bundled) and not foreign,
           f'pylibtiff loads its bundled libtiff: {hits}')
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, 'check.tif')
        import numpy
        data = (numpy.arange(64 * 48, dtype=numpy.uint16).reshape(48, 64) * 7) % 65535
        tif = TIFF.open(path, mode='w')
        tif.write_image(data, compression='lzw')
        tif.close()
        tif = TIFF.open(path, mode='r')
        back = tif.read_image()
        tif.close()
        report(numpy.array_equal(data, back), 'pylibtiff lzw round trip')
        code, out = run_tool('tiffinfo', [path])
        report(code == 0 and 'Image Width: 64' in out,
               f'bundled tiffinfo runs as a console script (exit {code}): {out.strip().splitlines()[:1]}')
        # By path, with only the system directories on PATH: the launcher
        # in libtiff/bin must find the real tool and every DLL it needs
        # (libtiff's and the VC runtime) in pylibtiff.libs by itself.
        launcher = os.path.join(package_dir, 'bin', 'tiffinfo.exe')
        code, out = run_path(launcher, [path], env=scrubbed_env())
        report(code == 0 and 'Image Width: 64' in out,
               f'bundled tiffinfo runs by path with a bare PATH (exit {code}): {out.strip().splitlines()[:1]}')
        # Compression support that the feature assertions promised (webp
        # only encodes RGB/RGBA).
        rgb = numpy.dstack([data.astype(numpy.uint8)] * 3)
        for compression in ('zstd', 'webp', 'jpeg', 'deflate'):
            try:
                tif = TIFF.open(os.path.join(tmp, compression + '.tif'), mode='w')
                tif.write_image(rgb, compression=compression, write_rgb=True)
                tif.close()
                report(True, f'pylibtiff writes {compression}')
            except Exception as exc:
                report(False, f'pylibtiff writes {compression}: {exc}')


def check_glymur(package_dir, libs_dir):
    import glymur
    import numpy

    hits, bundled, foreign = loaded_from_libs('openjp2', os.path.basename(libs_dir))
    report(bool(bundled) and not foreign,
           f'glymur loads its bundled openjp2: {hits}')
    version = glymur.version.openjpeg_version
    report(bool(version) and version.startswith('2.'), f'openjpeg version {version}')
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, 'check.jp2')
        data = (numpy.arange(64 * 48 * 3, dtype=numpy.uint32).reshape(48, 64, 3) % 251
                ).astype(numpy.uint8)
        glymur.Jp2k(path, data=data)
        back = glymur.Jp2k(path)[:]
        report(numpy.array_equal(data, back), 'glymur jp2 write/read round trip (lossless)')
        nemo = glymur.Jp2k(glymur.data.nemo())
        report(nemo.shape == (1456, 2592, 3), f'bundled nemo.jp2 reads: shape {nemo.shape}')
        code, out = run_tool('opj_dump', ['-i', path])
        report(code == 0 and 'x1=64' in out.replace(' ', ''),
               f'bundled opj_dump runs as a console script (exit {code})')
        launcher = os.path.join(package_dir, 'bin', 'opj_dump.exe')
        code, out = run_path(launcher, ['-i', path], env=scrubbed_env())
        report(code == 0 and 'x1=64' in out.replace(' ', ''),
               f'bundled opj_dump runs by path with a bare PATH (exit {code})')
        code, out = run_tool('djpeg', ['-version'])
        report(code == 0 and 'libjpeg-turbo' in out,
               f'bundled djpeg runs as a console script (exit {code}): {out.strip().splitlines()[:1]}')


def check_openslide(package_dir, libs_dir):
    import openslide
    from PIL import Image

    hits, bundled, foreign = loaded_from_libs('libopenslide', os.path.basename(libs_dir))
    report(bool(bundled) and not foreign,
           f'openslide loads its bundled libopenslide: {hits}')
    version = openslide.__library_version__
    report(bool(version) and version.startswith('4.'), f'openslide library version {version}')
    # The generic reader path (ImageSlide) exercises the library's region
    # reads without a slide file; the shared suite reads real slides.
    image = Image.new('RGB', (300, 200), (10, 20, 30))
    slide = openslide.ImageSlide(image)
    region = slide.read_region((0, 0), 0, (64, 48))
    report(region.size == (64, 48) and region.getpixel((1, 1))[:3] == (10, 20, 30),
           'openslide ImageSlide region read')
    slide.close()
    code, out = run_tool('slidetool', ['--version'])
    report(code == 0 and 'slidetool' in out.lower() or 'openslide' in out.lower(),
           f'bundled slidetool runs as a console script (exit {code}): {out.strip().splitlines()[:1]}')
    launcher = os.path.join(package_dir, 'bin', 'slidetool.exe')
    code, out = run_path(launcher, ['--version'], env=scrubbed_env())
    report(code == 0, f'bundled slidetool runs by path with a bare PATH (exit {code}): {out.strip().splitlines()[:1]}')


def check_pyvips(package_dir, libs_dir):
    import pyvips

    hits, bundled, foreign = loaded_from_libs('vips-', os.path.basename(libs_dir))
    report(bool(bundled) and not foreign,
           f'pyvips loads its bundled libvips: {hits}')
    report(pyvips.API_mode, 'pyvips runs in API mode (the cffi extension loaded)')
    version = '.'.join(str(pyvips.version(i)) for i in range(3))
    report(pyvips.version(0) >= 8, f'libvips version {version}')
    report(hasattr(pyvips.Image, 'dzsave'), 'pyvips has Image.dzsave')
    # Every loader the linux wheel carries must be compiled in (the build
    # asserted the DLL imports; this checks the operations register).
    for op in ('tiffload', 'jpegload', 'pngload', 'webpload', 'jp2kload', 'openslideload',
               'heifload', 'jxlload', 'svgload', 'pdfload', 'rawload', 'fitsload',
               'matload', 'niftiload', 'openexrload', 'magickload', 'magicksave',
               'dzsave', 'text', 'fwfft'):
        report(pyvips.type_find('VipsOperation', op) != 0, f'libvips has the {op} operation')
    with tempfile.TemporaryDirectory() as tmp:
        image = pyvips.Image.black(64, 48, bands=3) + [10, 20, 30]
        path = os.path.join(tmp, 'check.tif')
        image.tiffsave(path, compression='jpeg', tile=True, pyramid=True)
        back = pyvips.Image.new_from_file(path)
        report(back.width == 64 and back.height == 48 and back.bands == 3,
               'pyvips tiffsave (jpeg, tiled, pyramid) round trip')
        image.webpsave(os.path.join(tmp, 'check.webp'))
        report(os.path.getsize(os.path.join(tmp, 'check.webp')) > 0, 'pyvips webpsave')
        png = image.pngsave_buffer(palette=True)
        report(len(png) > 0, 'pyvips pngsave with palette (libimagequant)')
        svg = pyvips.Image.svgload_buffer(
            b'<svg xmlns="http://www.w3.org/2000/svg" width="32" height="24">'
            b'<rect width="32" height="24" fill="red"/></svg>')
        report(svg.width == 32 and svg.height == 24 and svg.getpoint(1, 1)[0] == 255,
               'pyvips svgload (librsvg)')
        # A format only ImageMagick handles, through the bundled MagickCore.
        # (8-bit: ImageMagick imports float pixels on a 0..1 scale, and
        # the arithmetic above made the image float.)
        bmp = os.path.join(tmp, 'check.bmp')
        image.cast('uchar').magicksave(bmp, format='BMP')
        back = pyvips.Image.magickload(bmp)
        report(back.width == 64 and back.height == 48 and back.getpoint(1, 1)[0] == 10,
               'pyvips magicksave/magickload round trip (ImageMagick)')
        code, out = run_tool('magick', ['--version'])
        report(code == 0 and 'ImageMagick' in out,
               f'bundled magick runs as a console script (exit {code}): {out.strip().splitlines()[:1]}')
        code, out = run_tool('magick', ['-size', '8x8', 'xc:red', os.path.join(tmp, 'magick.png')])
        report(code == 0 and os.path.getsize(os.path.join(tmp, 'magick.png')) > 0,
               f'bundled magick writes a png (exit {code}): {out.strip().splitlines()[:1]}')
        # The bundled configuration files: importing pyvips (above) put them
        # on MAGICK_CONFIGURE_PATH, and the console script must do the same
        # by itself, so it runs without the variable.
        magick_config = os.path.normcase(os.path.realpath(os.path.join(package_dir, 'etc', 'ImageMagick')))
        configure_path = os.environ.get('MAGICK_CONFIGURE_PATH', '')
        report(magick_config in [os.path.normcase(p) for p in configure_path.split(os.pathsep)],
               f'importing pyvips puts the bundled ImageMagick configuration on MAGICK_CONFIGURE_PATH: {configure_path}')
        env = {k: v for k, v in os.environ.items() if k.upper() != 'MAGICK_CONFIGURE_PATH'}
        code, out = run_tool('magick', ['-list', 'policy'], env=env)
        policy = os.path.join(magick_config, 'policy.xml')
        report(code == 0 and policy in os.path.normcase(out),
               f'bundled magick reads the bundled policy.xml (exit {code}): '
               f'{[line.strip() for line in out.splitlines() if "Path:" in line]}')
        code, out = run_tool('magick', ['-size', '8x8', 'xc:red', os.path.join(tmp, 'magick2.png')], env=env)
        report(code == 0 and 'UnableToOpenConfigureFile' not in out,
               f'bundled magick finds every configuration file it asks for (exit {code}): {out.strip().splitlines()[:2]}')
        code, out = run_tool('vips', ['--version'])
        report(code == 0 and 'vips-' in out,
               f'bundled vips runs as a console script (exit {code}): {out.strip().splitlines()[:1]}')
        launcher = os.path.join(package_dir, 'bin', 'vips.exe')
        code, out = run_path(launcher, ['--version'], env=scrubbed_env())
        report(code == 0 and 'vips-' in out,
               f'bundled vips runs by path with a bare PATH (exit {code}): {out.strip().splitlines()[:1]}')
        code, out = run_tool('vipsheader', [path])
        report(code == 0 and '64x48' in out,
               f'bundled vipsheader runs as a console script (exit {code}): {out.strip().splitlines()[:1]}')


def check_gdal(package_dir, libs_dir):
    import numpy
    import osgeo
    from osgeo import gdal, ogr, osr
    gdal.UseExceptions()

    hits, bundled, foreign = loaded_from_libs('gdal', os.path.basename(libs_dir))
    report(bool(bundled) and not foreign,
           f'gdal loads its bundled libgdal: {hits}')
    version = gdal.VersionInfo('RELEASE_NAME')
    report(version.startswith('3.'), f'gdal version {version}')
    # (A DLL, not the relocated gdal.exe beside it: django loads this path
    # with ctypes and looks GDALVersionInfo up in it.)
    report(os.path.isfile(osgeo.GDAL_LIBRARY_PATH) and osgeo.GDAL_LIBRARY_PATH.lower().endswith('.dll'),
           f'osgeo.GDAL_LIBRARY_PATH names a bundled DLL: {osgeo.GDAL_LIBRARY_PATH}')
    report(os.path.isfile(osgeo.GEOS_LIBRARY_PATH) and osgeo.GEOS_LIBRARY_PATH.lower().endswith('.dll'),
           f'osgeo.GEOS_LIBRARY_PATH names a bundled DLL: {osgeo.GEOS_LIBRARY_PATH}')
    # The drivers whose libraries are Windows-only builds here (the shared
    # suite's known-formats check polices the whole set).
    for name in ('GTiff', 'JP2OpenJPEG', 'HDF4', 'HDF5', 'KEA', 'netCDF', 'Zarr', 'PDF', 'EXR', 'FITS',
                 'AVIF', 'HEIF', 'JPEGXL', 'WEBP', 'GTA', 'MrSID', 'MSG', 'PostGISRaster', 'MySQL',
                 'PostgreSQL', 'XLS', 'SOSI', 'XODR', 'GMLAS', 'Interlis 1', 'SQLite', 'GPKG', 'XLSX',
                 'OSM', 'MVT', 'PMTiles', 'WMS', 'OGCAPI', 'GIF', 'PNG', 'JPEG', 'MBTiles'):
        report(gdal.GetDriverByName(name) is not None, f'gdal has the {name} driver')
    # A transform through the bundled proj.db (the osgeo patch's PROJ
    # search path).
    src = osr.SpatialReference()
    src.ImportFromEPSG(4326)
    src.SetAxisMappingStrategy(osr.OAMS_TRADITIONAL_GIS_ORDER)
    dst = osr.SpatialReference()
    dst.ImportFromEPSG(3857)
    dst.SetAxisMappingStrategy(osr.OAMS_TRADITIONAL_GIS_ORDER)
    x, y, _ = osr.CoordinateTransformation(src, dst).TransformPoint(-77.0, 38.9)
    report(abs(x + 8571600) < 2000 and abs(y - 4707359) < 2000,
           f'proj transform EPSG:4326 -> 3857 through the bundled proj.db: {x:.0f}, {y:.0f}')
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, 'check.tif')
        ds = gdal.GetDriverByName('GTiff').Create(path, 64, 48, 3, gdal.GDT_Byte, options=['COMPRESS=DEFLATE'])
        ds.SetProjection(dst.ExportToWkt())
        ds.SetGeoTransform((0, 10, 0, 0, 0, -10))
        ds.GetRasterBand(1).WriteArray(numpy.full((48, 64), 10, dtype=numpy.uint8))
        ds = None
        ds = gdal.Open(path)
        arr = ds.GetRasterBand(1).ReadAsArray()
        report(arr.shape == (48, 64) and int(arr[1, 1]) == 10,
               'gdal GTiff create/read round trip (numpy through _gdal_array)')
        ds = None
        sq = os.path.join(tmp, 'check.sqlite')
        vds = ogr.GetDriverByName('SQLite').CreateDataSource(sq, options=['SPATIALITE=YES'])
        vds.CreateLayer('pts', srs=src, geom_type=ogr.wkbPoint)
        vds = None
        vds = ogr.Open(sq)
        res = vds.ExecuteSQL('SELECT spatialite_version()')
        spatialite = res.GetNextFeature().GetField(0)
        vds.ReleaseResultSet(res)
        vds = None
        report(bool(spatialite), f'spatialite through the SQLite driver: {spatialite}')
        code, out = run_tool('gdalinfo', ['--version'])
        report(code == 0 and 'GDAL' in out,
               f'bundled gdalinfo runs as a console script (exit {code}): {out.strip().splitlines()[:1]}')
        launcher = os.path.join(package_dir, 'bin', 'gdalinfo.exe')
        code, out = run_path(launcher, [path], env=scrubbed_env())
        report(code == 0 and 'Size is 64, 48' in out,
               f'bundled gdalinfo runs by path with a bare PATH (exit {code}): {out.strip().splitlines()[:1]}')
        code, out = run_tool('gdal-config', ['--formats'])
        report(code == 0 and len(out.split()) >= 98,
               f'bundled gdal-config lists the formats (exit {code}, {len(out.split())} formats)')
        code, out = run_tool('listgeo', [path])
        report(code == 0 and 'Geotiff_Information' in out,
               f'bundled listgeo (libgeotiff) runs as a console script (exit {code})')
        code, out = run_tool('projinfo', ['EPSG:4326'])
        report(code == 0 and 'WGS 84' in out,
               f'bundled projinfo (proj) runs as a console script with the bundled proj.db (exit {code})')


def check_mapnik(package_dir, libs_dir):
    import mapnik

    hits, bundled, foreign = loaded_from_libs('libmapnik', os.path.basename(libs_dir))
    report(bool(bundled) and not foreign,
           f'mapnik loads its bundled libmapnik: {hits}')
    # Every plugin the linux wheel carries must register: each is a
    # LoadLibrary of a .input file whose imports resolve from mapnik.libs.
    plugins = set(mapnik.DatasourceCache.plugin_names())
    for name in ('csv', 'gdal', 'ogr', 'geobuf', 'geojson', 'postgis', 'pgraster', 'raster', 'shape',
                 'sqlite', 'tiles', 'topojson'):
        report(name in plugins, f'mapnik registers the {name} input plugin')
    hits, bundled, foreign = loaded_from_libs('gdal-', os.path.basename(libs_dir))
    report(bool(bundled) and not foreign, f'mapnik loads its bundled libgdal: {hits}')
    with tempfile.TemporaryDirectory() as tmp:
        # A reprojected render (EPSG:4326 data on an EPSG:3857 map: mapnik's
        # own proj transform with the bundled proj.db) through the csv
        # plugin and the agg renderer.
        m = mapnik.Map(256, 256, 'epsg:3857')
        m.background = mapnik.Color('white')
        style = mapnik.Style()
        rule = mapnik.Rule()
        rule.symbolizers.append(mapnik.PolygonSymbolizer())
        style.rules.append(rule)
        m.append_style('poly', style)
        layer = mapnik.Layer('poly', 'epsg:4326')
        layer.datasource = mapnik.CSV(inline='wkt\n"POLYGON((-80 30,-70 30,-70 40,-80 40,-80 30))"\n')
        layer.styles.append('poly')
        m.layers.append(layer)
        m.zoom_all()
        report(m.envelope().minx < -8800000 and m.envelope().maxx > -7800000,
               f'mapnik reprojects EPSG:4326 to EPSG:3857: {m.envelope()}')
        image = mapnik.Image(256, 256)
        mapnik.render(m, image)
        png = os.path.join(tmp, 'check.png')
        image.save(png, 'png')
        report(os.path.getsize(png) > 0, 'mapnik renders and writes a png')
        # The gdal plugin reads a tiff mapnik writes.
        tif = os.path.join(tmp, 'check.tif')
        mapnik.Image(64, 48).save(tif, 'tiff')
        envelope = mapnik.Gdal(file=tif).envelope()
        report(envelope.width() == 64 and envelope.height() == 48,
               f'mapnik gdal plugin reads a tiff: {envelope}')
        # (mapnik's tools exit 1 after printing --version, on every
        # platform; a tool that cannot load its DLLs prints nothing.)
        version = 'version ' + mapnik.version_string()
        code, out = run_tool('mapnik-render', ['--version'])
        report(version in out,
               f'bundled mapnik-render runs as a console script (exit {code}): {out.strip().splitlines()[:1]}')
        launcher = os.path.join(package_dir, 'bin', 'shapeindex.exe')
        code, out = run_path(launcher, ['--version'], env=scrubbed_env())
        report(version in out,
               f'bundled shapeindex runs by path with a bare PATH (exit {code}): {out.strip().splitlines()[:1]}')

def under(path, directory):
    return os.path.normcase(os.path.abspath(path)).startswith(
        os.path.normcase(os.path.abspath(directory)) + os.sep)


def check_javabridge(package_dir, libs_dir):
    # The JVM is the bundled JDK tree, started in this process; with
    # python-bioformats installed, the same VM checks the bioformats jar
    # (a JVM can be started only once per process).
    import javabridge
    import javabridge.locate

    jvm_dir = os.path.join(package_dir, 'jvm')
    home = javabridge.locate.find_javahome()
    report(os.path.normcase(os.path.abspath(home)) == os.path.normcase(jvm_dir),
           f'javabridge resolves the bundled jvm tree: {home}')
    try:
        import bioformats
    except ImportError:
        bioformats = None
    javabridge.start_vm(class_path=bioformats.JARS if bioformats else javabridge.JARS,
                        run_headless=True)
    try:
        hits = [path for path in loaded_modules() if os.path.basename(path).lower() == 'jvm.dll']
        report(bool(hits) and all(under(path, jvm_dir) for path in hits),
               f'javabridge loads the bundled jvm.dll: {hits}')

        def prop(name):
            return javabridge.static_call('java/lang/System', 'getProperty',
                                          '(Ljava/lang/String;)Ljava/lang/String;', name)

        java_home = prop('java.home')
        report(under(java_home, jvm_dir), f'java.home is in the bundled tree: {java_home}')
        version = prop('java.version')
        report(version.startswith('1.8.'), f'java.version {version} ({prop("java.vm.vendor")})')
        if bioformats:
            import importlib.metadata

            dist = importlib.metadata.version('python-bioformats')
            jar = javabridge.get_static_field('loci/formats/FormatTools', 'VERSION', 'Ljava/lang/String;')
            report(bool(jar) and ('.' + jar + '.') in dist,
                   f'bioformats jar version {jar} (python-bioformats {dist})')
            try:
                javabridge.class_for_name('com.fasterxml.jackson.databind.ObjectMapper')
                report(False, 'the bioformats jar has no jackson (ObjectMapper loaded)')
            except javabridge.JavaException:
                report(True, 'the bioformats jar has no jackson')
            # Without a logback config bioformats logs at DEBUG, so the
            # first reader lists every optional reader class missing from
            # the jar; large_image lowers the level the same way.
            javabridge.static_call('loci/common/DebugTools', 'setRootLevel',
                                   '(Ljava/lang/String;)V', 'ERROR')
            import numpy
            with tempfile.TemporaryDirectory() as tmp:
                path = os.path.join(tmp, 'check.pgm')
                data = (numpy.arange(64 * 48, dtype=numpy.uint32).reshape(48, 64) % 251
                        ).astype(numpy.uint8)
                with open(path, 'wb') as fptr:
                    fptr.write(b'P5\n64 48\n255\n' + data.tobytes())
                with bioformats.ImageReader(path) as reader:
                    back = reader.read(rescale=False)
                report(back.shape == (48, 64) and numpy.array_equal(back, data),
                       f'bioformats reads a pgm through the bundled JVM: shape {back.shape}')
                bioformats.clear_image_reader_cache()
    finally:
        javabridge.kill_vm()
    code, out = run_tool('java', ['-version'])
    report(code == 0 and 'version "1.8.' in out,
           f'bundled java runs as a console script (exit {code}): {out.strip().splitlines()[:1]}')
    code, out = run_path(os.path.join(jvm_dir, 'bin', 'java.exe'), ['-version'], env=scrubbed_env())
    report(code == 0 and 'version "1.8.' in out,
           f'bundled java runs by path with a bare PATH (exit {code}): {out.strip().splitlines()[:1]}')


class FakeMemcached:
    """A memcached speaking just enough of the text protocol for a
    set/get/delete round trip (there is no memcached for the sandbox to
    run): enough to exercise libmemcached's Windows socket, poll and
    parsing paths through pylibmc."""

    def __init__(self):
        import socketserver
        import threading
        store = {}

        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                while True:
                    line = self.rfile.readline()
                    if not line:
                        return
                    parts = line.split()
                    if not parts:
                        continue
                    cmd = parts[0]
                    if cmd == b'set':
                        size = int(parts[4])
                        data = self.rfile.read(size + 2)[:size]
                        store[parts[1]] = (parts[2], data)
                        if b'noreply' not in parts:
                            self.wfile.write(b'STORED\r\n')
                    elif cmd in (b'get', b'gets'):
                        for key in parts[1:]:
                            if key in store:
                                flags, data = store[key]
                                self.wfile.write(b'VALUE %s %s %d\r\n%s\r\n' % (key, flags, len(data), data))
                        self.wfile.write(b'END\r\n')
                    elif cmd == b'delete':
                        found = store.pop(parts[1], None) is not None
                        self.wfile.write(b'DELETED\r\n' if found else b'NOT_FOUND\r\n')
                    elif cmd == b'version':
                        self.wfile.write(b'VERSION 1.6.0\r\n')
                    elif cmd == b'quit':
                        return
                    else:
                        self.wfile.write(b'ERROR\r\n')
                    self.wfile.flush()

        socketserver.ThreadingTCPServer.daemon_threads = True
        self.server = socketserver.ThreadingTCPServer(('127.0.0.1', 0), Handler)
        self.address = '127.0.0.1:%d' % self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def check_pylibmc(package_dir, libs_dir):
    import pylibmc
    import _pylibmc

    # (The bundled DLLs are in site-packages, libs_dir here; see
    # SITE_PACKAGES_LIBS.)
    hits, bundled, foreign = loaded_from_libs('libmemcached', '', libs_path=libs_dir)
    report(bool(bundled) and not foreign, f'pylibmc loads its bundled libmemcached: {hits}')
    sasl_hits, sasl_bundled, sasl_foreign = loaded_from_libs('sasl2', '', libs_path=libs_dir)
    report(bool(sasl_bundled) and not sasl_foreign, f'pylibmc loads its bundled libsasl2: {sasl_hits}')
    # The plugins' libcrypto: the mangled name this wheel bundles, loaded
    # from here or from another of our wheels (GDAL bundles the identical
    # OpenSSL, so the names match, and when osgeo was imported first the
    # loader resolves the plugins' import to its copy -- the accepted
    # case of loaded_from_libs).  The stem (libcrypto-<n>-x64, read from
    # the bundled file) leaves out python's own libcrypto-<n>.dll (_ssl,
    # _hashlib).
    ours = sorted(name for name in os.listdir(libs_dir)
                  if re.match(r'libcrypto-\d+-x64-[0-9a-f]+\.dll$', name, re.IGNORECASE))
    stem = re.match(r'(libcrypto-\d+-x64)-', ours[0], re.IGNORECASE).group(1) if ours else 'libcrypto-none'
    crypto_hits, crypto_bundled, crypto_foreign = loaded_from_libs(stem, '', libs_path=libs_dir)
    report(bool(ours) and bool(crypto_hits) and not crypto_foreign
           and all(os.path.basename(path).lower() in (name.lower() for name in ours) for path in crypto_hits),
           f'the sasl2 plugins load the bundled libcrypto ({", ".join(ours)}): {crypto_hits}')
    info = pylibmc.build_info()
    report('sasl=True' in info and 'compression=True' in info, f'build info: {info}')
    # The patched __init__.py points SASL_PATH at the bundled plugins (the
    # linux and macos wheels' arrangement; the Windows libsasl2 is patched
    # to honor it).
    sasl_path = os.environ.get('SASL_PATH', '')
    plugins = os.path.join(package_dir, 'sasl2')
    report(os.path.normcase(os.path.abspath(sasl_path)) == os.path.normcase(plugins)
           and any(name.lower().endswith('.dll') for name in os.listdir(plugins)),
           f'SASL_PATH names the bundled plugin directory: {sasl_path}')
    # _pylibmc called sasl_client_init on import, which loads every plugin
    # in SASL_PATH; the mechanisms registered prove that each plugin (and
    # the bundled libcrypto the OpenSSL-backed ones import) loaded.
    if sasl_bundled:
        sasl = ctypes.CDLL(sasl_bundled[0])
        sasl.sasl_global_listmech.restype = ctypes.POINTER(ctypes.c_char_p)
        mechs = set()
        listed = sasl.sasl_global_listmech()
        index = 0
        while listed and listed[index]:
            mechs.add(listed[index].decode())
            index += 1
        for mech in ('ANONYMOUS', 'PLAIN', 'CRAM-MD5', 'DIGEST-MD5', 'LOGIN', 'SCRAM-SHA-1',
                     'SCRAM-SHA-256', 'NTLM', 'OTP', 'SRP', 'PASSDSS-3DES-1'):
            report(mech in mechs, f'libsasl2 has the {mech} mechanism (loaded: {" ".join(sorted(mechs))})')
    server = FakeMemcached()
    try:
        mc = pylibmc.Client([server.address], behaviors={'connect_timeout': 5000})
        report(mc.set('liw', b'value') is True, f'pylibmc set through {server.address}')
        report(mc.get('liw') == b'value', 'pylibmc get round trip')
        big = b'compressible ' * 4096
        mc.set('big', big, min_compress_len=1)
        report(mc.get('big') == big, 'pylibmc zlib-compressed set/get round trip')
        report(mc.get_multi(['liw', 'big', 'none']) == {'liw': b'value', 'big': big},
               'pylibmc get_multi')
        report(mc.delete('liw') is True and mc.get('liw') is None, 'pylibmc delete')
        mc.disconnect_all()
    except Exception as exc:
        report(False, f'pylibmc round trip: {type(exc).__name__}: {exc}')
    finally:
        server.close()
    # A refused connection fails at once, as with poll() on linux (the
    # Windows select() emulation must watch exceptfds for it), not after
    # the connect timeout.
    import socket
    import time
    probe = socket.socket()
    probe.bind(('127.0.0.1', 0))
    closed = '127.0.0.1:%d' % probe.getsockname()[1]
    probe.close()
    mc = pylibmc.Client([closed], behaviors={'connect_timeout': 10000})
    start = time.monotonic()
    try:
        mc.get('liw')
        failed = False
    except pylibmc.Error:
        failed = True
    elapsed = time.monotonic() - start
    report(failed and elapsed < 5, f'pylibmc fails a refused connection in {elapsed:.1f} s (timeout 10 s)')


# package -> (import name, <dist>.libs directory name, package check).
# javabridge has no .libs directory: its only external import is the
# bundled JVM's jvm.dll (see Build-Javabridge).
PACKAGES = {
    'pylibtiff': ('libtiff', 'pylibtiff.libs', check_pylibtiff),
    'glymur': ('glymur', 'glymur.libs', check_glymur),
    'openslide_python': ('openslide', 'openslide_python.libs', check_openslide),
    'pyvips': ('pyvips', 'pyvips.libs', check_pyvips),
    'GDAL': ('osgeo', 'gdal.libs', check_gdal),
    'mapnik': ('mapnik', 'mapnik.libs', check_mapnik),
    'python_javabridge': ('javabridge', None, check_javabridge),
    'pylibmc': ('pylibmc', None, check_pylibmc),
}

# Wheels whose bundled DLLs delvewheel puts into site-packages itself
# rather than a <dist>.libs directory: those with a top-level extension
# module (pylibmc's _pylibmc).  Their audit covers exactly the files the
# distribution installed (its RECORD), with site-packages as the library
# directory.
SITE_PACKAGES_LIBS = {'pylibmc'}

# Directories, relative to the package, whose DLLs the package's binaries
# may import besides their own directory.  The JRE's DLLs import jvm.dll
# and each other across jre\bin and jre\bin\server: the java launcher and
# jutil.py both put those directories on the search path before loading
# the JVM, which then loads its libraries by full path.
AUDIT_DIRS = {
    'python_javabridge': [r'jvm\bin', r'jvm\jre\bin', r'jvm\jre\bin\server'],
}


def check_package(name):
    module_name, libs_name, check = PACKAGES[name]
    try:
        module = __import__(module_name)
    except ImportError as exc:
        report(False, f'{name}: import {module_name} failed: {exc}')
        return
    package_dir = os.path.dirname(os.path.abspath(module.__file__))
    extra_dirs = [os.path.join(package_dir, sub) for sub in AUDIT_DIRS.get(name, [])]
    if name in SITE_PACKAGES_LIBS:
        import importlib.metadata
        libs_dir = os.path.dirname(package_dir)
        roots = [os.path.abspath(str(entry.locate())) for entry in importlib.metadata.files(name)
                 if str(entry).lower().endswith(('.pyd', '.dll', '.exe'))]
        audit_imports(roots, libs_dir, extra_dirs)
    elif libs_name:
        libs_dir = os.path.join(os.path.dirname(package_dir), libs_name)
        report(os.path.isdir(libs_dir), f'{name}: bundled library directory {libs_dir}')
        audit_imports([package_dir, libs_dir], libs_dir, extra_dirs)
    else:
        libs_dir = None
        audit_imports([package_dir], None, extra_dirs)
    check(package_dir, libs_dir)


def main():
    wanted = sys.argv[1:]
    if not wanted:
        # Every known package that is installed.
        for name, (module_name, _, _) in PACKAGES.items():
            try:
                __import__(module_name)
            except ImportError:
                continue
            wanted.append(name)
        if not wanted:
            report(False, 'no known package is installed')
    for name in wanted:
        if name not in PACKAGES:
            report(False, f'no checks for {name}')
            continue
        try:
            check_package(name)
        except Exception as exc:
            report(False, f'{name}: {type(exc).__name__}: {exc}')
    print(f'{failures} failure(s)', flush=True)
    sys.exit(1 if failures else 0)


if __name__ == '__main__':
    main()
'@

# --------------------------------------------------------------------------
# One python.
# --------------------------------------------------------------------------

function Invoke-CheckWheels([string]$VenvPython, [string]$What) {
    # Scrubbed PATH: the system directories and the venv only, so no other
    # directory can supply a DLL (there is no rpath on Windows).
    $saved = $env:PATH
    $env:PATH = 'C:\Windows\System32;C:\Windows;' + (Split-Path -Parent $VenvPython)
    try {
        $code = Run-Logged $VenvPython @('-I', $script:CheckWheelsPath) `
            'check_wheels.py' -NoDie
    } finally {
        $env:PATH = $saved
    }
    Check ($code -eq 0) "$What (exit $code)"
}

function Test-Python([string]$Req) {
    Note ''
    Note "=== python $Req"
    $py = Join-Path $LIW_PY "$Req\python.exe"
    if (-not (Test-Path $py)) {
        Check $false "python ${Req}: not installed"
        return
    }

    # --- install the wheels by exact version
    $venv = Join-Path $TestRoot "venv-$Req"
    if (Test-Path $venv) { Remove-Item -Recurse -Force $venv }
    $code = Run-Logged $py @('-m', 'venv', $venv) "venv for python $Req" -NoDie
    if ($code -ne 0) {
        Check $false "python ${Req}: venv creation failed (exit $code)"
        return
    }
    $vpy = Join-Path $venv 'Scripts\python.exe'
    foreach ($dist in $script:Dists.Keys) {
        $whl = Find-Wheel $dist $Req
        if (-not $whl) {
            if ($dist -eq 'pylibtiff') {
                Check $false "python ${Req}: no pylibtiff wheel in $WheelsDir"
                return
            }
            continue
        }
        $ver = Wheel-Version $whl.Name $dist
        $pipName = $script:Dists[$dist]
        $pipArgs = @('-m', 'pip', 'install', '--quiet', '--no-warn-script-location',
            '--find-links', $WheelsDir)
        # python-bioformats requires python-javabridge.  Without our
        # javabridge wheel, pip would take pypi's (an sdist this sandbox
        # cannot build, and not ours anyway), so bioformats is installed
        # without its dependencies; the shared suite's bioformats tests
        # need javabridge and skip themselves.
        if ($dist -eq 'python_bioformats' -and -not (Find-Wheel 'python_javabridge' $Req)) {
            Note "python ${Req}: no python_javabridge wheel; python-bioformats installed with --no-deps"
            $pipArgs += '--no-deps'
        }
        $code = Run-Logged $vpy @($pipArgs + "$pipName==$ver") "pip install $pipName" -NoDie
        if ($code -ne 0) {
            Check $false "python ${Req}: pip install of $pipName==$ver failed (exit $code)"
            continue
        }
        $out = Capture $vpy @('-m', 'pip', 'show', $pipName)
        $shown = if ($out -match '(?m)^Version:\s*(\S+)') { $Matches[1] } else { '' }
        Check ($shown -eq $ver) ("python ${Req}: installed $pipName $shown from " +
            "$($whl.Name)" + $(if ($shown -ne $ver) { " but expected $ver (pip may have used pypi)" } else { '' }))
    }

    # --- the windows-specific isolation checks
    Log "--- check_wheels.py in the install venv for python $Req"
    Invoke-CheckWheels $vpy "python ${Req}: check_wheels.py in the install venv"

    # --- the shared functional suite
    # bash needs a python3 on PATH that is the python under test; the
    # NuGet pythons have no python3.exe, so a one-line shim provides it
    # (LIW_PYTHON_BIN_DIR is prepended to PATH by the script itself).  The
    # sample file downloads are cached across pythons and runs.
    $rundir = Join-Path $TestRoot "run-$Req"
    if (Test-Path $rundir) { Remove-Item -Recurse -Force $rundir }
    New-Item -ItemType Directory -Force -Path $rundir | Out-Null
    $shim = Join-Path $TestRoot "shim-$Req"
    if (Test-Path $shim) { Remove-Item -Recurse -Force $shim }
    New-Item -ItemType Directory -Force -Path $shim | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $shim 'python3'),
        "#!/bin/sh`nexec '$(To-PosixPath $py)' `"`$@`"`n")
    $testCache = Join-Path $CacheDir 'test_files'
    New-Item -ItemType Directory -Force -Path $testCache | Out-Null
    $bash = Join-Path $script:GitDir 'usr\bin\bash.exe'
    $saved = $env:PATH
    # Scrubbed PATH: the shim, bash's own directory (coreutils, curl comes
    # from System32), and the system directories.
    $env:PATH = "$shim;$(Join-Path $script:GitDir 'usr\bin');C:\Windows\System32;C:\Windows"
    $env:LIW_PYTHON_BIN_DIR = To-PosixPath $shim
    $env:LIW_TEST_CACHE = To-PosixPath $testCache
    Log "--- test_script.sh for python $Req in $rundir (bash $bash, wheels $WheelsDir, PATH $env:PATH)"
    Push-Location $rundir
    try {
        $code = Run-Logged $bash @((To-PosixPath $script:SuiteScript),
            ($WheelsDir -replace '\\', '/')) 'test_script.sh' -NoDie
    } finally {
        Pop-Location
        $env:PATH = $saved
        Remove-Item -Path 'env:LIW_PYTHON_BIN_DIR', 'env:LIW_TEST_CACHE' -ErrorAction SilentlyContinue
    }
    Check ($code -eq 0) "python ${Req}: shared test_script.sh (exit $code)"
    $suitePython = Join-Path $rundir 'venv\Scripts\python.exe'
    if (Test-Path $suitePython) {
        Log "--- check_wheels.py in the test_script.sh venv for python $Req"
        Invoke-CheckWheels $suitePython "python ${Req}: check_wheels.py in the test_script.sh venv"
    } else {
        Check $false "python ${Req}: test_script.sh left no venv to check"
    }
}

# --------------------------------------------------------------------------
# Main.
# --------------------------------------------------------------------------

function Main {
    Log "=== test_wheels.ps1 started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Log "mode: $(if ($script:DevMode) { 'dev (' + $RepoDir + ')' } else { 'test sandbox' })"
    Log "parameters from: $($script:ArgsSource)"
    Note "pythons: $($script:Pythons -join ' ')"
    Note "wheels: $WheelsDir"
    $wheels = @(Get-ChildItem -Path $WheelsDir -Filter '*.whl' -File -ErrorAction SilentlyContinue)
    if ($wheels.Count -eq 0) { Die "no wheels in $WheelsDir" }
    Note 'wheels present:'
    foreach ($whl in $wheels) { Note "  $($whl.Name)" }

    Ensure-Pythons
    $script:GitDir = Ensure-PortableGit

    # A host checkout with core.autocrlf=true has the shared script with
    # CRLF endings, which bash rejects; run a copy with LF endings (the
    # macos harness copies the script into its VM too).
    $script:SuiteScript = Join-Path $TestRoot 'test_script.sh'
    $text = [System.IO.File]::ReadAllText((Join-Path $RepoDir 'test\test_script.sh'))
    [System.IO.File]::WriteAllText($script:SuiteScript, ($text -replace "`r`n", "`n"),
        [System.Text.UTF8Encoding]::new($false))
    # The embedded check_wheels.py, written out the same way.
    $script:CheckWheelsPath = Join-Path $TestRoot 'check_wheels.py'
    [System.IO.File]::WriteAllText($script:CheckWheelsPath,
        (($script:CheckWheelsSource -replace "`r`n", "`n").TrimEnd() + "`n"),
        [System.Text.UTF8Encoding]::new($false))

    foreach ($req in $script:Pythons) {
        Test-Python $req
    }
    Note ''
    if ($script:Failures -eq 0) {
        Note '=== RESULT: all checks passed'
    } else {
        Note "=== RESULT: $($script:Failures) check(s) failed"
    }
    Log "=== test_wheels.ps1 finished $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
}

$exitCode = 0
try {
    Main
    if ($script:Failures -gt 0) { $exitCode = 1 }
} catch {
    Log "error: $($_.Exception.Message)"
    if ($_.InvocationInfo) {
        Log "error: at $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)"
    }
    Add-Content -Path $ReportPath -Value "=== the test script died: $($_.Exception.Message)" -Encoding utf8
    $exitCode = 1
}
Set-Content -Path $ExitCodePath -Value $exitCode -Encoding ascii
Log "=== exit code $exitCode"
# As the build sandbox does: the report and log are out through the mapped
# run folder, so the sandbox shuts itself down (it holds the
# single-instance slot).  Dev mode is left alone.
if (-not $script:DevMode) {
    & shutdown.exe /s /t 5
}
exit $exitCode
