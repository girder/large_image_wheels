# test_via_sandbox.ps1 - run on the HOST (outside the Windows Sandbox) to
# verify that the Windows wheels were built with proper isolation; the
# counterpart of macos/test_via_tart.sh and of test_via_docker.py.
#
# It starts a fresh Windows Sandbox -- a machine with nothing installed,
# not even the VC++ redistributable -- maps the repository and the wheels
# read-only plus the download cache and a per-run exchange folder
# read-write, and lets the .wsb LogonCommand run windows\test_wheels.ps1
# inside it: for every python, install the wheels by exact version into a
# clean venv, run windows\check_wheels.py (the PE import audit and the
# loaded-DLL identity checks), and run the shared test\test_script.sh (the
# same functional suite the linux containers and the macos VM run).  The
# host streams the in-sandbox log, waits for the exit marker, prints the
# report, and exits with the result.
#
# Usage (test_via_sandbox.bat runs this with no options from a command
# prompt; run sandbox_build first):
#   test_via_sandbox.ps1                       test every wheel for every python
#   test_via_sandbox.ps1 -Pythons 3.12,3.13    test a subset of pythons
#
# The same host conditions and backends as sandbox_build.ps1 apply (see
# sandbox_common.ps1).  The sandbox is stopped afterwards by the in-sandbox
# script itself and by wsb stop; the host never taskkills anything.

param(
    [string[]]$Pythons = @('3.11', '3.12', '3.13', '3.14', '3.15', '3.14t', '3.15t'),
    [int]$MemoryMB = 8192,
    [int]$TimeoutSec = 14400,
    [string]$RepoDir = '',
    [string]$CacheDir = '',
    [string]$WheelsDir = '',
    [string]$RunDir = ''
)

$ErrorActionPreference = 'Stop'
$script:Tool = 'test_via_sandbox'
$script:Self = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $script:Self 'sandbox_common.ps1')

if (-not $RepoDir) { $RepoDir = Split-Path -Parent $script:Self }
$RepoDir = (Get-Item $RepoDir).FullName
# The same layout as sandbox_build.ps1 and the checked-in windows\test.wsb
# (wheels in <repo>\wheels, the rest under <repo>\windows); the run
# exchange is separate (test_run) so a test does not disturb the build's
# log.
$workDir = Join-Path $RepoDir 'windows'
if (-not $CacheDir) { $CacheDir = Join-Path $workDir 'cache' }
if (-not $RunDir) { $RunDir = Join-Path $workDir 'test_run' }
if (-not $WheelsDir) { $WheelsDir = Join-Path $RepoDir 'wheels' }

# --- sanity checks -----------------------------------------------------------
Assert-SandboxHost
foreach ($dir in @($RepoDir, (Join-Path $RepoDir 'windows'), (Join-Path $RepoDir 'test'))) {
    if (-not (Test-Path $dir)) { Die "missing directory: $dir" }
}
$wheels = @(Get-ChildItem -Path $WheelsDir -Filter '*.whl' -File -ErrorAction SilentlyContinue)
if ($wheels.Count -eq 0) {
    Die "no wheels in $WheelsDir; run sandbox_build first"
}
# A build that failed leaves its exit code behind (and no wheels of the
# packages it built); refuse rather than test leftovers.
$buildExit = Join-Path (Join-Path $workDir 'run') 'exit_code'
if ((Test-Path $buildExit) -and ((Get-Content $buildExit -Raw).Trim() -ne '0')) {
    Die "the last build failed (see $(Join-Path $workDir 'run\build.log')); not testing its leftovers"
}
if ($Pythons.Count -eq 0) { Die 'no pythons requested' }

# --- folder setup ------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
if (Test-Path $RunDir) { Remove-Item -Recurse -Force $RunDir }
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
@{ pythons = @($Pythons) } | ConvertTo-Json |
    Set-Content -Path (Join-Path $RunDir 'args.json') -Encoding ascii

# --- launch and wait ----------------------------------------------------------
$repoGuest = 'C:\mnt\repo'
$logon = ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File ' +
          "$repoGuest\windows\test_wheels.ps1")
Info "wheels under test: $($wheels.Count) in $WheelsDir"
$result = Invoke-SandboxRun -RunDir $RunDir -Command $logon `
    -LogName 'test.log' -MemoryMB $MemoryMB -TimeoutSec $TimeoutSec `
    -WsbName 'liw_wheels_test.wsb' -MappedFolders @(
        @{ Host = $RepoDir; Guest = $repoGuest; ReadOnly = $true },
        @{ Host = $WheelsDir; Guest = 'C:\mnt\wheels'; ReadOnly = $true },
        @{ Host = $CacheDir; Guest = 'C:\mnt\cache'; ReadOnly = $false },
        @{ Host = $RunDir; Guest = 'C:\mnt\run'; ReadOnly = $false })

# --- report -------------------------------------------------------------------
$reportPath = Join-Path $RunDir 'report.txt'
if (Test-Path $reportPath) {
    Write-Host ''
    Write-Host "--- $reportPath"
    Get-Content $reportPath | Write-Host
} else {
    Info 'no report.txt was written'
    if ($result -eq 0) { $result = 1 }
}
if ($result -eq 0) {
    Info 'the wheel tests passed'
} else {
    Info "the wheel tests failed with exit code $result"
}
Info "the full in-sandbox log is $(Join-Path $RunDir 'test.log')"
Report-SandboxShutdown
exit $result
