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
# Usage:
#   sandbox_build.ps1                     build the default packages
#   sandbox_build.ps1 -Packages pylibtiff build specific packages
#   sandbox_build.ps1 -Command cache      pre-warm the download cache
#
# The Windows Sandbox feature must be enabled
# (Enable-WindowsOptionalFeature -Online -FeatureName
# Containers-DisposableClientVM, then reboot).  This script uses the .wsb
# file backend only and does not need the wsb CLI.  It closes a sandbox it
# started by the in-sandbox script itself: after writing its exit code
# and final log line (both already visible on the host through the mapped
# run folder) it shuts the VM down, on success and failure alike, as on
# macos.  The host never taskkills anything.

param(
    [ValidateSet('build', 'cache')]
    [string]$Command = 'build',
    # Default package set; keep in sync with build_wheels.ps1's builders.
    [string[]]$Packages = @('pylibtiff'),
    [string[]]$Pythons = @('3.11', '3.12', '3.13', '3.14', '3.15'),
    [int]$MemoryMB = 8192,
    [int]$TimeoutSec = 14400,
    [string]$RepoDir = '',
    [string]$CacheDir = '',
    [string]$WheelsDir = '',
    [string]$RunDir = ''
)

$ErrorActionPreference = 'Stop'

$script:Self = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $RepoDir) { $RepoDir = Split-Path -Parent $script:Self }
# The writable mapped folders must not nest inside the read-only repo
# mapping (nested mapped folders are unproven on Windows Sandbox), so
# they default to a liw_wheels sibling of the repository; the checked-in
# windows\build.wsb uses the same layout, and both flows share the cache.
$workDir = Join-Path (Split-Path -Parent $RepoDir) 'liw_wheels'
if (-not $CacheDir) { $CacheDir = Join-Path $workDir 'cache' }
if (-not $RunDir) { $RunDir = Join-Path $workDir 'run' }
if (-not $WheelsDir) { $WheelsDir = Join-Path $workDir 'wheels' }

function Die([string]$Message) {
    throw "sandbox_build: $Message"
}

function Info([string]$Message) {
    Write-Host "sandbox_build: $Message"
}

# --- sanity checks -----------------------------------------------------------
# This script must run on the host.  Windows Sandbox cannot be nested: the
# guest gets no virtualization extensions, so a sandbox started from inside
# a sandbox hangs windowless forever.  In-sandbox sessions run as the
# WDAGUtilityAccount, which never happens on the host, so use that to
# refuse here instead of hanging later.
if ([Security.Principal.WindowsIdentity]::GetCurrent().Name `
    -like '*\WDAGUtilityAccount') {
    Die ('this session is itself inside a Windows Sandbox, and Windows ' +
        'Sandbox cannot be nested; run this script on the host machine ' +
        'that launched this sandbox.')
}
# An agent_sandbox.py session runs as its own non-administrator user
# (`agent`), so the account check above does not catch it; the feature
# check below does, because a sandbox guest never has WindowsSandbox.exe.
$sandboxExe = Join-Path $env:SystemRoot 'System32\WindowsSandbox.exe'
if (-not (Test-Path $sandboxExe)) {
    Die ('Windows Sandbox is not installed here.  Inside a sandbox (an ' +
        'agent session, for example) that is expected: run this script ' +
        'on the host.  On a host, enable it with ' +
        "'Enable-WindowsOptionalFeature -Online -FeatureName " +
        "Containers-DisposableClientVM' and reboot.")
}
foreach ($dir in @($RepoDir, (Join-Path $RepoDir 'windows'))) {
    if (-not (Test-Path $dir)) { Die "missing directory: $dir" }
}
if ($Command -eq 'build' -and $Packages.Count -eq 0) {
    Die 'no packages requested'
}
# Only one instance of Windows Sandbox may run at a time ('Only one
# running instance of Windows Sandbox is allowed'), and the agent session
# is itself a sandbox on this host: a build can only start when the agent
# sandbox has been ended.  Do not kill a running sandbox blindly.
if (Get-Process -Name 'WindowsSandbox*' -ErrorAction SilentlyContinue) {
    Die ('a Windows Sandbox is already running; only one instance is ' +
        'allowed.  It may be the agent session itself -- do not kill it ' +
        'blindly; end the agent session deliberately before building.')
}

# --- folder setup ------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $CacheDir, $WheelsDir | Out-Null
New-Item -ItemType Directory -Force `
    -Path (Join-Path $CacheDir 'downloads') | Out-Null
if (Test-Path $RunDir) { Remove-Item -Recurse -Force $RunDir }
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null

$guestRun = 'C:\mnt\run'
$argsPath = Join-Path $RunDir 'args.json'
@{
    packages = @($Packages)
    pythons = @($Pythons)
    command = $Command
} | ConvertTo-Json | Set-Content -Path $argsPath -Encoding ascii

# --- the .wsb configuration ---------------------------------------------------
# Mapped folders: the repository is read-only; cache, wheels and the run
# exchange are read-write.  The LogonCommand runs as the elevated sandbox
# account, so the in-sandbox script can install machine-wide toolchains.
function Escape-Xml([string]$Text) {
    return [System.Security.SecurityElement]::Escape($Text)
}

$repoGuest = 'C:\mnt\repo'
$logon = ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File ' +
          "$repoGuest\windows\build_wheels.ps1")
if ($Command -eq 'cache') { $logon = "$logon -WarmCache" }

$xml = @"
<Configuration>
  <vGPU>Disable</vGPU>
  <Networking>Enable</Networking>
  <AudioInput>Disable</AudioInput>
  <VideoInput>Disable</VideoInput>
  <PrinterRedirection>Disable</PrinterRedirection>
  <ClipboardRedirection>Disable</ClipboardRedirection>
  <MemoryInMB>$MemoryMB</MemoryInMB>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$(Escape-Xml $RepoDir)</HostFolder>
      <SandboxFolder>$repoGuest</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$(Escape-Xml $CacheDir)</HostFolder>
      <SandboxFolder>C:\mnt\cache</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$(Escape-Xml $WheelsDir)</HostFolder>
      <SandboxFolder>C:\mnt\wheels</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$(Escape-Xml $RunDir)</HostFolder>
      <SandboxFolder>$guestRun</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>$(Escape-Xml $logon)</Command>
  </LogonCommand>
</Configuration>
"@

$wsbPath = Join-Path $RunDir 'liw_wheels_build.wsb'
# XML without a declaration defaults to UTF-8; the content is ASCII.
$xml | Set-Content -Path $wsbPath -Encoding ascii

# --- launch and wait ----------------------------------------------------------
# Watch the host side of the run exchange (mapped at C:\mnt\run in the
# guest), not the guest paths.
$logPath = Join-Path $RunDir 'build.log'
$deadline = (Get-Date).AddSeconds($TimeoutSec)

Info "starting the sandbox from $wsbPath (the build log streams here)"
Start-Process -FilePath $wsbPath
Info ("waiting for the in-sandbox script to start writing $logPath " +
    '(the sandbox takes a moment to boot)')

$streamed = 0
$started = $false
$windowSeen = $false
$windowAt = $null
$startTime = Get-Date
$lastBeat = $startTime
while ($true) {
    if (Test-Path $logPath) {
        $started = $true
        try {
            $size = (Get-Item $logPath -ErrorAction Stop).Length
        } catch {
            $size = 0
        }
        if ($size -gt $streamed) {
            $stream = [System.IO.FileStream]::new(
                $logPath, 'Open', 'Read', 'ReadWrite')
            try {
                $stream.Seek($streamed, 'Begin') | Out-Null
                $reader = [System.IO.StreamReader]::new($stream)
                $chunk = $reader.ReadToEnd()
                $reader.Dispose()
            } finally {
                $stream.Dispose()
            }
            $streamed = $size
            Write-Host $chunk
        }
    }
    if (Test-Path (Join-Path $RunDir 'exit_code')) {
        break
    }
    $sandboxes = @(Get-Process -Name 'WindowsSandbox*' `
        -ErrorAction SilentlyContinue)
    if (-not $sandboxes) {
        if ($started) {
            Die ('the sandbox closed before reporting an exit code; see ' +
                "$logPath")
        }
        Die ('the sandbox did not start; is the Windows Sandbox feature ' +
            'enabled and up to date?')
    }
    foreach ($proc in $sandboxes) {
        if ($proc.MainWindowTitle) {
            if (-not $windowSeen) {
                $windowSeen = $true
                $windowAt = Get-Date
            }
        }
    }
    if ((Get-Date) -gt $deadline) {
        Info ('timed out after ' +
            "$TimeoutSec seconds; the in-sandbox build keeps running and " +
            'the sandbox will shut itself down when it finishes; the log ' +
            'stays at ' + "$logPath")
        Die "see $logPath"
    }
    # The build is long and quiet during toolchain install, so keep the
    # host from looking hung: report once a minute until the log appears.
    if (((Get-Date) - $lastBeat).TotalSeconds -ge 60) {
        $elapsed = [int]((Get-Date) - $startTime).TotalSeconds
        $titles = @($sandboxes | ForEach-Object { $_.MainWindowTitle }) `
            -join ', '
        if (-not $titles) { $titles = '(no window)' }
        if (-not $windowSeen) {
            Info ("no build log after $elapsed seconds; sandbox " +
                "processes: $($sandboxes.Count), window titles: " +
                "$titles.  A window titled " +
                '"Windows Sandbox" may be the build desktop or a ' +
                'one-instance error dialog (only one sandbox may run at ' +
                'a time, and the agent session is itself a sandbox); no ' +
                'window means the sandbox VM never started.')
        } else {
            Info ("no build log after $elapsed seconds although the " +
                'sandbox desktop is up; the LogonCommand either did not ' +
                'run or died before its first log write.  On the sandbox ' +
                'desktop, look for a console window with an error, and ' +
                'check that C:\\mnt\\run shows args.json (if it does ' +
                'not, the mapped folders are not working).')
            if (((Get-Date) - $windowAt).TotalSeconds -gt 180) {
                Die ('the sandbox window has been up for over three ' +
                    'minutes without a build log; if it is the build ' +
                    'desktop, investigate as described above; if it is ' +
                    'the one-instance error dialog, a sandbox is already ' +
                    'running (possibly the agent session, which must be ' +
                    'closed deliberately before building).')
            }
        }
        $lastBeat = Get-Date
    }
    # A healthy sandbox shows its window within a couple of minutes.  A
    # windowless process for longer than that means the VM cannot start
    # (hypervisor, feature state, or memory); waiting the full timeout
    # would only hide the problem.
    if (-not $windowSeen -and -not $started -and
        ((Get-Date) - $startTime).TotalSeconds -gt 300) {
        Die ('the sandbox process has run for over five minutes without ' +
            'ever showing a window or writing a log; the sandbox VM is ' +
            'not starting on this host.  Check that no other sandbox is ' +
            'running (only one instance is allowed; the agent session ' +
            'itself counts and must be closed deliberately first), that ' +
            'the Containers-DisposableClientVM optional feature is ' +
            'Enabled, that virtualization is enabled in the firmware (see the ' +
            'Hyper-V Requirements section of systeminfo), that the ' +
            'CmService is not Disabled, and that starting "Windows ' +
            'Sandbox" from the Start menu shows a window; also try ' +
            '-MemoryMB 4096 in case 8192 exceeds what the host can give.')
    }
    Start-Sleep -Seconds 2
}

$result = [int]((Get-Content (Join-Path $RunDir 'exit_code') -Raw).Trim())

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
Info "the full build log is $logPath"
if (Get-Process -Name 'WindowsSandbox*' -ErrorAction SilentlyContinue) {
    Info ('the sandbox has not shut itself down yet (it schedules its ' +
        'own shutdown after writing the exit code); if it is still up ' +
        'in a minute, close the window by hand -- taskkill is ' +
        'indiscriminate and could hit the agent sandbox')
}
exit $result
