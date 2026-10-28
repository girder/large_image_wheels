# sandbox_common.ps1 - host-side functions shared by sandbox_build.ps1 and
# test_via_sandbox.ps1: the host sanity checks, the .wsb generation, the
# sandbox launch, the log streaming, and the wait for the exit marker.
# Dot-sourced by those scripts (which set $script:Tool to their own name
# for messages); nothing here runs on its own.

function Die([string]$Message) {
    throw "$($script:Tool): $Message"
}

function Info([string]$Message) {
    Write-Host "$($script:Tool): $Message"
}

# This script must run on the host.  Windows Sandbox cannot be nested: the
# guest gets no virtualization extensions, so a sandbox started from inside
# a sandbox hangs windowless forever.  In-sandbox sessions run as the
# WDAGUtilityAccount, which never happens on the host, so use that to
# refuse here instead of hanging later.  An agent_sandbox.py session runs
# as its own non-administrator user (`agent`), so the account check does
# not catch it; the feature check does, because a sandbox guest never has
# WindowsSandbox.exe.  Only one instance of Windows Sandbox may run at a
# time ('Only one running instance of Windows Sandbox is allowed'), and
# the agent session is itself a sandbox on this host: a run can only start
# when the agent sandbox has been ended.  Never kill a running sandbox
# blindly.
function Assert-SandboxHost {
    if ([Security.Principal.WindowsIdentity]::GetCurrent().Name `
        -like '*\WDAGUtilityAccount') {
        Die ('this session is itself inside a Windows Sandbox, and Windows ' +
            'Sandbox cannot be nested; run this script on the host machine ' +
            'that launched this sandbox.')
    }
    $sandboxExe = Join-Path $env:SystemRoot 'System32\WindowsSandbox.exe'
    if (-not (Test-Path $sandboxExe)) {
        Die ('Windows Sandbox is not installed here.  Inside a sandbox (an ' +
            'agent session, for example) that is expected: run this script ' +
            'on the host.  On a host, enable it with ' +
            "'Enable-WindowsOptionalFeature -Online -FeatureName " +
            "Containers-DisposableClientVM' and reboot.")
    }
    if (Get-Process -Name 'WindowsSandbox*' -ErrorAction SilentlyContinue) {
        Die ('a Windows Sandbox is already running; only one instance is ' +
            'allowed.  It may be the agent session itself -- do not kill it ' +
            'blindly; end the agent session deliberately before building.')
    }
}

function Escape-Xml([string]$Text) {
    return [System.Security.SecurityElement]::Escape($Text)
}

# Start a fresh sandbox from a generated .wsb and wait for the in-sandbox
# script to finish.  MappedFolders is a list of @{ Host; Guest; ReadOnly }.
# The in-sandbox script writes its log as <RunDir>\<LogName> and its exit
# code to <RunDir>\exit_code; the log is streamed to the console as it
# grows.  Returns the exit code.  The sandbox is closed by the in-sandbox
# script itself (it shuts the VM down after writing the exit code, on
# success and failure alike, as on macos); the host never taskkills
# anything.
function Invoke-SandboxRun {
    param(
        [string]$RunDir,
        [object[]]$MappedFolders,
        [string]$LogonCommand,
        [string]$LogName,
        [int]$MemoryMB,
        [int]$TimeoutSec,
        [string]$WsbName
    )
    $folders = ''
    foreach ($folder in $MappedFolders) {
        $ro = if ($folder.ReadOnly) { 'true' } else { 'false' }
        $folders += @"
    <MappedFolder>
      <HostFolder>$(Escape-Xml $folder.Host)</HostFolder>
      <SandboxFolder>$($folder.Guest)</SandboxFolder>
      <ReadOnly>$ro</ReadOnly>
    </MappedFolder>

"@
    }
    # The LogonCommand runs as the elevated sandbox account; nothing in the
    # pipeline needs that, the toolchain is portable.
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
$folders  </MappedFolders>
  <LogonCommand>
    <Command>$(Escape-Xml $LogonCommand)</Command>
  </LogonCommand>
</Configuration>
"@
    $wsbPath = Join-Path $RunDir $WsbName
    # XML without a declaration defaults to UTF-8; the content is ASCII.
    $xml | Set-Content -Path $wsbPath -Encoding ascii

    # Watch the host side of the run exchange (mapped at C:\mnt\run in the
    # guest), not the guest paths.
    $logPath = Join-Path $RunDir $LogName
    $deadline = (Get-Date).AddSeconds($TimeoutSec)

    Info "starting the sandbox from $wsbPath (the log streams here)"
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
                "$TimeoutSec seconds; the in-sandbox script keeps running and " +
                'the sandbox will shut itself down when it finishes; the log ' +
                'stays at ' + "$logPath")
            Die "see $logPath"
        }
        # The runs are long and quiet during toolchain install, so keep the
        # host from looking hung: report once a minute until the log appears.
        if (((Get-Date) - $lastBeat).TotalSeconds -ge 60) {
            $elapsed = [int]((Get-Date) - $startTime).TotalSeconds
            $titles = @($sandboxes | ForEach-Object { $_.MainWindowTitle }) `
                -join ', '
            if (-not $titles) { $titles = '(no window)' }
            if (-not $windowSeen) {
                Info ("no log after $elapsed seconds; sandbox " +
                    "processes: $($sandboxes.Count), window titles: " +
                    "$titles.  A window titled " +
                    '"Windows Sandbox" may be the sandbox desktop or a ' +
                    'one-instance error dialog (only one sandbox may run at ' +
                    'a time, and the agent session is itself a sandbox); no ' +
                    'window means the sandbox VM never started.')
            } else {
                Info ("no log after $elapsed seconds although the " +
                    'sandbox desktop is up; the LogonCommand either did not ' +
                    'run or died before its first log write.  On the sandbox ' +
                    'desktop, look for a console window with an error, and ' +
                    'check that C:\\mnt\\run shows args.json (if it does ' +
                    'not, the mapped folders are not working).')
                if (((Get-Date) - $windowAt).TotalSeconds -gt 180) {
                    Die ('the sandbox window has been up for over three ' +
                        'minutes without a log; if it is the sandbox ' +
                        'desktop, investigate as described above; if it is ' +
                        'the one-instance error dialog, a sandbox is already ' +
                        'running (possibly the agent session, which must be ' +
                        'closed deliberately before a run).')
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
    return [int]((Get-Content (Join-Path $RunDir 'exit_code') -Raw).Trim())
}

function Report-SandboxShutdown {
    if (Get-Process -Name 'WindowsSandbox*' -ErrorAction SilentlyContinue) {
        Info ('the sandbox has not shut itself down yet (it schedules its ' +
            'own shutdown after writing the exit code); if it is still up ' +
            'in a minute, close the window by hand -- taskkill is ' +
            'indiscriminate and could hit the agent sandbox')
    }
}
