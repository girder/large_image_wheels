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
# Containers-DisposableClientVM, then reboot).  This script uses the .wsb
# file backend only and does not need the wsb CLI.  The sandbox is closed
# by the in-sandbox script itself: after writing its exit code and final
# log line (both already visible on the host through the mapped run
# folder) it shuts the VM down, on success and failure alike, as on macos.
# The host never taskkills anything.

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
# The writable mapped folders must not nest inside the read-only repo
# mapping (nested mapped folders are unproven on Windows Sandbox), so
# they default to a liw_wheels sibling of the repository; the checked-in
# windows\build.wsb uses the same layout, and both flows share the cache.
$workDir = Join-Path (Split-Path -Parent $RepoDir) 'liw_wheels'
if (-not $CacheDir) { $CacheDir = Join-Path $workDir 'cache' }
if (-not $RunDir) { $RunDir = Join-Path $workDir 'run' }
if (-not $WheelsDir) { $WheelsDir = Join-Path $workDir 'wheels' }

# --- sanity checks -----------------------------------------------------------
Assert-SandboxHost
foreach ($dir in @($RepoDir, (Join-Path $RepoDir 'windows'))) {
    if (-not (Test-Path $dir)) { Die "missing directory: $dir" }
}
if ($Command -eq 'build' -and $Packages.Count -eq 0) {
    Die 'no packages requested'
}

# --- folder setup ------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $CacheDir, $WheelsDir | Out-Null
New-Item -ItemType Directory -Force `
    -Path (Join-Path $CacheDir 'downloads') | Out-Null
if (Test-Path $RunDir) { Remove-Item -Recurse -Force $RunDir }
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null

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

$result = Invoke-SandboxRun -RunDir $RunDir -LogonCommand $logon `
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
function Wheel-Prefix([string]$Package) {
    switch ($Package) {
        'glymur' { return 'Glymur' }
        'gdal' { return 'GDAL' }
        default { return $Package }
    }
}

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
