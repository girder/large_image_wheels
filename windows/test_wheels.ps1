# test_wheels.ps1 - verify the Windows wheels INSIDE a fresh Windows Sandbox
# (started on the host through windows\test.wsb or test_via_sandbox.ps1);
# the counterpart of the in-VM part of macos/test_via_tart.sh.
#
# A fresh sandbox has nothing installed -- no VC++ redistributable, no
# library of any kind -- so a wheel that works here brings everything it
# needs.  For every requested python this script:
#
#   1. installs the wheels into a clean venv by exact version, with the
#      wheel folder as the only extra source (a pypi fallback would show
#      up as a version mismatch), as test_via_tart.sh does;
#   2. runs windows\check_wheels.py in that venv with a scrubbed PATH (the
#      PE import audit, the loaded-DLL identity, the bundled tools through
#      their wrappers and by path with a bare PATH);
#   3. runs the shared functional suite, test\test_script.sh -- the same
#      script the linux containers and the macos VM run -- under
#      PortableGit's bash with a scrubbed PATH and the python under test,
#      and runs check_wheels.py in the venv that suite created as well.
#
# Mapped folders (test.wsb / test_via_sandbox.ps1):
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
$paramPythons = @($Pythons)
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

# Log, Die, Assert-Exit, V, Fetch, Expand-Zip, Get-Json, Run-Logged,
# Ensure-Pythons, Ensure-PortableGit, To-PosixPath (shared with
# build_wheels.ps1).
. (Join-Path $PSScriptRoot 'liw_common.ps1')

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
# rules as sandbox_build.ps1's validation), or $null.
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
# One python.
# --------------------------------------------------------------------------

function Invoke-CheckWheels([string]$VenvPython, [string]$What) {
    # Scrubbed PATH: the system directories and the venv only, so no other
    # directory can supply a DLL (there is no rpath on Windows).
    $saved = $env:PATH
    $env:PATH = 'C:\Windows\System32;C:\Windows;' + (Split-Path -Parent $VenvPython)
    try {
        $code = Run-Logged $VenvPython @('-I', (Join-Path $RepoDir 'windows\check_wheels.py')) `
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
