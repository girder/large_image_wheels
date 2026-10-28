# sandbox_build.ps1 - run on the HOST (outside the Windows Sandbox) to do a
# complete, isolated Windows x86_64 wheel build.
#
# This is standalone: it manages its own sandbox lifecycle the way
# `docker build` manages images.  Every build starts a fresh Windows Sandbox
# (the sandbox's own installed software is empty by construction), maps the
# repository read-only plus a download cache, a wheel output folder, and a
# per-run exchange folder read-write, and lets the .wsb LogonCommand run
# windows\build_wheels.ps1 inside the sandbox.  The host streams the
# in-sandbox log, waits for the exit marker, validates the wheels, and
# reports.  Nothing about the build environment persists between runs; the
# cache only holds upstream downloads (toolchains, pythons, source
# tarballs), never build outputs.
#
# Usage (sandbox_build.bat runs this with no options from a command prompt):
#   sandbox_build.ps1                     build the default packages
#   sandbox_build.ps1 -Packages pylibtiff build specific packages
#   sandbox_build.ps1 -Command cache      pre-warm the download cache
#
# The Windows Sandbox feature must be enabled
# (Enable-WindowsOptionalFeature -Online -FeatureName
# Containers-DisposableClientVM, then reboot).  With wsb.exe on PATH
# (Windows 11 24H2+) the sandbox is headless and the script runs in it
# through wsb exec; otherwise the generated .wsb file is launched and the
# script runs from its LogonCommand (see sandbox_common.ps1).  The sandbox
# is stopped afterwards by the in-sandbox script itself (it shuts the VM
# down after writing its exit code, on success and failure alike, as on
# macos) and by wsb stop.  The host never taskkills anything.

param(
    [ValidateSet('build', 'cache')]
    [string]$Command = 'build',
    # Default package set; keep in sync with build_wheels.ps1's builders.
    [string[]]$Packages = @('pylibtiff'),
    [string[]]$Pythons = @('3.11', '3.12', '3.13', '3.14', '3.15', '3.14t', '3.15t'),
    [int]$MemoryMB = 8192,
    [int]$TimeoutSec = 14400,
    [string]$RepoDir = '',
    [string]$CacheDir = '',
    [string]$WheelsDir = '',
    [string]$RunDir = ''
)

$ErrorActionPreference = 'Stop'
$script:Tool = 'sandbox_build'
$script:Self = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $script:Self 'sandbox_common.ps1')

if (-not $RepoDir) { $RepoDir = Split-Path -Parent $script:Self }
# (Get-Item: the on-disk spelling, so a lowercase drive letter from the
# command line does not show up in the paths reported.)
$RepoDir = (Get-Item $RepoDir).FullName
# Everything lives under the repository, as on linux and macos: the wheels
# in <repo>\wheels (gitignored, where build.sh and tart_build.sh put
# theirs), the windows-specific cache and run exchanges under
# <repo>\windows (cache, run, test_run; gitignored).  The checked-in
# windows\build.wsb uses the same layout.  Those folders are mapped
# read-write at their own guest paths; the repo mapping (read-only)
# merely also shows them, which is harmless.
$workDir = Join-Path $RepoDir 'windows'
if (-not $CacheDir) { $CacheDir = Join-Path $workDir 'cache' }
if (-not $RunDir) { $RunDir = Join-Path $workDir 'run' }
if (-not $WheelsDir) { $WheelsDir = Join-Path $RepoDir 'wheels' }

# --- sanity checks -----------------------------------------------------------
Assert-SandboxHost
foreach ($dir in @($RepoDir, (Join-Path $RepoDir 'windows'))) {
    if (-not (Test-Path $dir)) { Die "missing directory: $dir" }
}
if ($Command -eq 'build' -and $Packages.Count -eq 0) {
    Die 'no packages requested'
}

# The wheel file prefix of a package (as build.sh's copy-out list names
# them).
function Wheel-Prefix([string]$Package) {
    switch ($Package) {
        'glymur' { return 'Glymur' }
        'gdal' { return 'GDAL' }
        default { return $Package }
    }
}

# --- folder setup ------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $CacheDir, $WheelsDir | Out-Null
New-Item -ItemType Directory -Force `
    -Path (Join-Path $CacheDir 'downloads') | Out-Null
if (Test-Path $RunDir) { Remove-Item -Recurse -Force $RunDir }
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
# The previous wheels of the requested packages go first, as build.sh
# removes them before copying the new ones out: a failed build must not
# leave old wheels for the test run to pick up.
if ($Command -eq 'build') {
    foreach ($pkg in $Packages) {
        if ($pkg.StartsWith('dep:')) { continue }
        Remove-Item -Path (Join-Path $WheelsDir "$(Wheel-Prefix $pkg)-*.whl") `
            -Force -ErrorAction SilentlyContinue
    }
}

@{
    packages = @($Packages)
    pythons = @($Pythons)
    command = $Command
} | ConvertTo-Json | Set-Content -Path (Join-Path $RunDir 'args.json') -Encoding ascii

# --- launch and wait ----------------------------------------------------------
$repoGuest = 'C:\mnt\repo'
$logon = ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File ' +
          "$repoGuest\windows\build_wheels.ps1")
if ($Command -eq 'cache') { $logon = "$logon -WarmCache" }

$result = Invoke-SandboxRun -RunDir $RunDir -Command $logon `
    -LogName 'build.log' -MemoryMB $MemoryMB -TimeoutSec $TimeoutSec `
    -WsbName 'liw_wheels_build.wsb' -MappedFolders @(
        @{ Host = $RepoDir; Guest = $repoGuest; ReadOnly = $true },
        @{ Host = $CacheDir; Guest = 'C:\mnt\cache'; ReadOnly = $false },
        @{ Host = $WheelsDir; Guest = 'C:\mnt\wheels'; ReadOnly = $false },
        @{ Host = $RunDir; Guest = 'C:\mnt\run'; ReadOnly = $false })

# --- validate and report ------------------------------------------------------
# Every requested package must have produced a wheel that every requested
# python can install, as tart_build.sh checks on macos (the counterpart of
# build.sh copying the expected wheels out of the docker build): a silently
# missing wheel would otherwise only surface as quietly skipped tests.
function Wheel-ForPython([string]$Prefix, [string]$Req) {
    $base = $Req.TrimEnd('t')
    $num = $base -replace '\.', ''
    $any = @(Get-ChildItem -Path $WheelsDir -Filter "$Prefix-*py3-none-any.whl" `
        -ErrorAction SilentlyContinue)
    if ($any.Count -gt 0) { return $true }
    $plat = @(Get-ChildItem -Path $WheelsDir -Filter "$Prefix-*py3-none-win_amd64.whl" `
        -ErrorAction SilentlyContinue)
    if ($plat.Count -gt 0) { return $true }
    if ($Req.EndsWith('t')) {
        $tags = @("cp$num-cp${num}t", "cp$num-abi3.abi3t", "cp$num-abi3t")
    } else {
        $tags = @("cp$num-cp$num")
        foreach ($b in @('310', '311', '312', '313', '314', '315')) {
            if ([int]$b -le [int]$num) { $tags += "cp$b-abi3" }
        }
    }
    foreach ($tag in $tags) {
        $found = @(Get-ChildItem -Path $WheelsDir -Filter "$Prefix-*-$tag-win_amd64.whl" `
            -ErrorAction SilentlyContinue)
        if ($found.Count -gt 0) { return $true }
    }
    return $false
}

if ($Command -eq 'build' -and $result -eq 0) {
    $missing = @()
    foreach ($pkg in $Packages) {
        if ($pkg.StartsWith('dep:')) { continue }
        $prefix = Wheel-Prefix $pkg
        foreach ($req in $Pythons) {
            if (-not (Wheel-ForPython $prefix $req)) { $missing += "$pkg/$req" }
        }
    }
    if ($missing.Count -gt 0) {
        Info "missing expected wheels: $($missing -join ' ')"
        $result = 1
    } else {
        Get-ChildItem -Path $WheelsDir -Filter '*.whl' | ForEach-Object { Info "wheel: $($_.Name)" }
    }
}

if ($result -eq 0) {
    Info 'build succeeded'
} else {
    Info "the build failed with exit code $result"
}
Info "the full build log is $(Join-Path $RunDir 'build.log')"
Report-SandboxShutdown
exit $result
