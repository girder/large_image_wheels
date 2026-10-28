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

function Log([string]$Message) {
    Write-Host $Message
    Add-Content -Path $LogPath -Value $Message -Encoding utf8
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
    Add-Content -Path $ReportPath -Value $Message -Encoding utf8
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


def loaded_from_libs(stem, libs_dir_name):
    """The loaded modules whose basename starts with <stem> (delvewheel
    mangles names to <stem>-<hash>.dll, so a prefix match is the lookup):
    all of them, the ones in the <libs_dir_name> directory, and the ones
    outside any wheel's .libs directory.  Several of our wheels may bundle
    the same library (identical content gets the same mangled name), and
    a full-path load of each is a separate module, so a copy in another
    wheel's .libs directory is legitimate; a copy anywhere else means a
    system or third-party library won the load."""
    hits = [path for path in loaded_modules()
            if os.path.basename(path).lower().startswith(stem.lower())]
    bundled = [path for path in hits
               if os.path.basename(os.path.dirname(path)).lower() == libs_dir_name.lower()]
    foreign = [path for path in hits
               if not os.path.basename(os.path.dirname(path)).lower().endswith('.libs')]
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


def audit_imports(roots, libs_dir):
    """Every PE file under the given roots may import only: a file in its
    own directory, a file in libs_dir, python's own DLL, a Windows API set,
    or a DLL in the system directory.  Anything else would resolve through
    PATH at best -- a system or third-party library winning the load -- and
    fail at worst."""
    bad = 0
    files = 0
    for root in roots:
        for dirpath, _, filenames in os.walk(root):
            for filename in filenames:
                if not filename.lower().endswith(('.pyd', '.dll', '.exe')):
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
                    if os.path.exists(os.path.join(dirpath, name)):
                        continue
                    if os.path.exists(os.path.join(libs_dir, name)):
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


# package -> (import name, <dist>.libs directory name, package check)
PACKAGES = {
    'pylibtiff': ('libtiff', 'pylibtiff.libs', check_pylibtiff),
    'glymur': ('glymur', 'glymur.libs', check_glymur),
    'openslide_python': ('openslide', 'openslide_python.libs', check_openslide),
}


def check_package(name):
    module_name, libs_name, check = PACKAGES[name]
    try:
        module = __import__(module_name)
    except ImportError as exc:
        report(False, f'{name}: import {module_name} failed: {exc}')
        return
    package_dir = os.path.dirname(os.path.abspath(module.__file__))
    libs_dir = os.path.join(os.path.dirname(package_dir), libs_name)
    report(os.path.isdir(libs_dir), f'{name}: bundled library directory {libs_dir}')
    audit_imports([package_dir, libs_dir], libs_dir)
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
        $code = Run-Logged $vpy @('-m', 'pip', 'install', '--quiet',
            '--no-warn-script-location', '--find-links', $WheelsDir,
            "$pipName==$ver") "pip install $pipName" -NoDie
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
