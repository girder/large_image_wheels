# sandbox_common.ps1 - host-side functions shared by sandbox_build.ps1 and
# test_via_sandbox.ps1: the host sanity checks, the sandbox launch (both
# backends), the log streaming, the wait for the exit marker, and the
# stop.  Dot-sourced by those scripts (which set $script:Tool to their own
# name for messages); nothing here runs on its own.
#
# Backends, as in manthey/utils agent_sandbox.py (the same host runs the
# agent session this way):
#   cli   Windows 11 24H2+ with wsb.exe on PATH: headless.  `wsb start
#         --config <xml>` returns a sandbox id, `wsb list --raw` lists the
#         running ids, `wsb exec --id <id> -r System -c <command>` runs the
#         in-sandbox script as SYSTEM (the LogonCommand is not used), and
#         `wsb stop --id <id>` tears the sandbox down.  Several sandboxes
#         can exist when the Windows build allows it, so the agent session
#         need not be stopped first (if the build allows only one, `wsb
#         start` fails and says so).
#   file  Windows 10 (or no wsb.exe): the generated .wsb file is launched
#         like a double-click, which opens the sandbox window; the
#         in-sandbox script runs from the LogonCommand as the elevated
#         built-in account.  Only one sandbox at a time, and the agent
#         session is one.

function Die([string]$Message) {
    throw "$($script:Tool): $Message"
}

function Info([string]$Message) {
    Write-Host "$($script:Tool): $Message"
}

function Get-SandboxBackend {
    if (Get-Command 'wsb.exe' -ErrorAction SilentlyContinue) { return 'cli' }
    return 'file'
}

# Output of wsb.exe (stdout and stderr) as one string; -Check dies on a
# nonzero exit.
function Invoke-Wsb([string[]]$WsbArgs, [switch]$Check) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = (& wsb.exe @WsbArgs 2>&1 | Out-String)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($Check -and $code -ne 0) {
        Die "wsb $($WsbArgs -join ' ') failed ($code): $($out.Trim())"
    }
    return $out
}

$script:GuidRe = '[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}'

function Get-RunningSandboxIds {
    $out = Invoke-Wsb @('list', '--raw')
    return @([regex]::Matches($out, $script:GuidRe) | ForEach-Object { $_.Value.ToLower() })
}

# This script must run on the host.  Windows Sandbox cannot be nested: the
# guest gets no virtualization extensions, so a sandbox started from inside
# a sandbox hangs windowless forever.  In-sandbox sessions run as the
# WDAGUtilityAccount, which never happens on the host, so use that to
# refuse here instead of hanging later.  An agent_sandbox.py session runs
# as its own non-administrator user (`agent`), so the account check does
# not catch it; the feature check does, because a sandbox guest never has
# WindowsSandbox.exe (nor wsb.exe).  With the file backend only one
# sandbox may run at a time ('Only one running instance of Windows Sandbox
# is allowed'), and the agent session is itself a sandbox on this host.
# Never kill a running sandbox blindly.
function Assert-SandboxHost {
    if ([Security.Principal.WindowsIdentity]::GetCurrent().Name `
        -like '*\WDAGUtilityAccount') {
        Die ('this session is itself inside a Windows Sandbox, and Windows ' +
            'Sandbox cannot be nested; run this script on the host machine ' +
            'that launched this sandbox.')
    }
    $sandboxExe = Join-Path $env:SystemRoot 'System32\WindowsSandbox.exe'
    if (-not (Test-Path $sandboxExe) -and (Get-SandboxBackend) -eq 'file') {
        Die ('Windows Sandbox is not installed here.  Inside a sandbox (an ' +
            'agent session, for example) that is expected: run this script ' +
            'on the host.  On a host, enable it with ' +
            "'Enable-WindowsOptionalFeature -Online -FeatureName " +
            "Containers-DisposableClientVM' and reboot.")
    }
    if ((Get-SandboxBackend) -eq 'cli') {
        $ids = Get-RunningSandboxIds
        if ($ids.Count -gt 0) {
            Info ("sandboxes already running: $($ids -join ', ') (an agent " +
                'session, probably); the run gets its own sandbox if this ' +
                'Windows build allows more than one')
        }
        return
    }
    if (Get-Process -Name 'WindowsSandbox*' -ErrorAction SilentlyContinue) {
        Die ('a Windows Sandbox is already running; only one instance is ' +
            'allowed with the .wsb file backend.  It may be the agent ' +
            'session itself -- do not kill it blindly; end the agent ' +
            'session deliberately before the run.')
    }
}

function Escape-Xml([string]$Text) {
    return [System.Security.SecurityElement]::Escape($Text)
}

function New-SandboxConfig([object[]]$MappedFolders, [string]$LogonCommand, [int]$MemoryMB) {
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
    $logon = ''
    if ($LogonCommand) {
        $logon = @"
  <LogonCommand>
    <Command>$(Escape-Xml $LogonCommand)</Command>
  </LogonCommand>

"@
    }
    return @"
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
$logon</Configuration>
"@
}

# Stream the new part of the log file to the console.  Returns the new
# streamed size.
function Stream-Log([string]$LogPath, [long]$Streamed) {
    try {
        $size = (Get-Item $LogPath -ErrorAction Stop).Length
    } catch {
        return $Streamed
    }
    if ($size -le $Streamed) { return $Streamed }
    $stream = [System.IO.FileStream]::new($LogPath, 'Open', 'Read', 'ReadWrite')
    try {
        $stream.Seek($Streamed, 'Begin') | Out-Null
        $reader = [System.IO.StreamReader]::new($stream)
        $chunk = $reader.ReadToEnd()
        $reader.Dispose()
    } finally {
        $stream.Dispose()
    }
    Write-Host $chunk
    return $size
}

# Start a fresh sandbox and wait for the in-sandbox script to finish.
# MappedFolders is a list of @{ Host; Guest; ReadOnly }; Command is the
# in-sandbox command line (the LogonCommand with the file backend, the
# `wsb exec` command with the cli backend).  The in-sandbox script writes
# its log as <RunDir>\<LogName> and its exit code to <RunDir>\exit_code;
# the log is streamed to the console as it grows.  Returns the exit code.
# The sandbox is stopped afterwards: by the in-sandbox script itself
# (it shuts the VM down after writing the exit code, on success and
# failure alike, as on macos) and, with the cli backend, by `wsb stop` as
# well.  The host never taskkills anything.
function Invoke-SandboxRun {
    param(
        [string]$RunDir,
        [object[]]$MappedFolders,
        [string]$Command,
        [string]$LogName,
        [int]$MemoryMB,
        [int]$TimeoutSec,
        [string]$WsbName
    )
    $backend = Get-SandboxBackend
    $logPath = Join-Path $RunDir $LogName
    $exitPath = Join-Path $RunDir 'exit_code'
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $startTime = Get-Date
    $streamed = 0
    $lastBeat = $startTime

    if ($backend -eq 'cli') {
        # The configuration travels on the command line, as one line.
        $xml = New-SandboxConfig $MappedFolders '' $MemoryMB
        $xml | Set-Content -Path (Join-Path $RunDir $WsbName) -Encoding ascii
        $oneLine = $xml -replace '\r?\n\s*', ''
        Info 'starting a headless sandbox (wsb start)'
        $out = Invoke-Wsb @('start', '--config', $oneLine) -Check
        $match = [regex]::Match($out, $script:GuidRe)
        if (-not $match.Success) {
            Die "wsb start did not report a sandbox id: $($out.Trim())"
        }
        $id = $match.Value.ToLower()
        Set-Content -Path (Join-Path $RunDir 'sandbox_id') -Value $id -Encoding ascii
        Info "sandbox $id started; running the in-sandbox script (wsb exec, as SYSTEM)"
        # wsb exec blocks for the command's duration and can fail while the
        # sandbox is still booting, so it is retried until the log shows
        # the script started (agent_sandbox.py does the same).  Once the
        # log exists, the exit marker is the only authority on whether the
        # script finished: wsb exec returning early, or a transient wsb
        # list hiccup, must not end a run that is still writing its log.
        # The run is given up only when the sandbox is gone for good
        # (three polls in a row), the log has been silent for QuietSec, or
        # the overall timeout passes -- and then the sandbox is left
        # running for inspection, as the macos harness keeps its VM.
        $QuietSec = 1800
        $attempts = 0
        $proc = $null
        $result = $null
        $missing = 0
        $lastGrowth = Get-Date
        $execEnded = $false
        $failed = $true
        try {
            while ($true) {
                if (-not $proc -and -not $execEnded) {
                    $attempts++
                    $proc = Start-Process -FilePath 'wsb.exe' -ArgumentList @(
                        'exec', '--id', $id, '-r', 'System', '-c', "`"$Command`"") `
                        -PassThru -WindowStyle Hidden
                }
                $before = $streamed
                $streamed = Stream-Log $logPath $streamed
                if ($streamed -ne $before) { $lastGrowth = Get-Date }
                if (Test-Path $exitPath) { break }
                if ($proc -and $proc.HasExited) {
                    $code = $proc.ExitCode
                    $proc = $null
                    if ($code -ne 0 -and -not (Test-Path $logPath)) {
                        if ($attempts -ge 20) {
                            Die "wsb exec kept failing ($code) before the script started; giving up"
                        }
                        Start-Sleep -Seconds 5
                        continue
                    }
                    # The script started; the exit marker decides the rest.
                    $execEnded = $true
                    Info "wsb exec returned ($code); waiting for the exit marker"
                    Start-Sleep -Seconds 3
                    continue
                }
                if ((Get-RunningSandboxIds) -notcontains $id) {
                    $missing++
                    if ($missing -ge 3) {
                        Die "sandbox $id is no longer running; see $logPath"
                    }
                } else {
                    $missing = 0
                }
                if ((Get-Date) -gt $deadline) {
                    Die "timed out after $TimeoutSec seconds; the log stays at $logPath"
                }
                if ((Test-Path $logPath) -and ((Get-Date) - $lastGrowth).TotalSeconds -gt $QuietSec) {
                    Die "no log output for $QuietSec seconds; see $logPath"
                }
                if (-not (Test-Path $logPath) -and ((Get-Date) - $lastBeat).TotalSeconds -ge 60) {
                    $elapsed = [int]((Get-Date) - $startTime).TotalSeconds
                    Info "no log after $elapsed seconds (wsb exec attempt $attempts); still waiting"
                    $lastBeat = Get-Date
                }
                Start-Sleep -Seconds 2
            }
            $result = [int]((Get-Content $exitPath -Raw).Trim())
            $failed = $false
        } finally {
            if ($failed) {
                Info ("sandbox $id is left running for inspection (wsb exec --id $id " +
                    "-r System -c <command> runs something inside it); discard it " +
                    "with: wsb stop --id $id")
            } else {
                Info "stopping sandbox $id"
                Invoke-Wsb @('stop', '--id', $id) | Out-Null
                $stopDeadline = (Get-Date).AddSeconds(60)
                while ((Get-Date) -lt $stopDeadline -and ((Get-RunningSandboxIds) -contains $id)) {
                    Start-Sleep -Seconds 2
                }
                if ((Get-RunningSandboxIds) -contains $id) {
                    Info "sandbox $id is still listed after wsb stop; stop it by hand (wsb stop --id $id)"
                }
            }
        }
        return $result
    }

    # --- file backend
    $xml = New-SandboxConfig $MappedFolders $Command $MemoryMB
    $wsbPath = Join-Path $RunDir $WsbName
    # XML without a declaration defaults to UTF-8; the content is ASCII.
    $xml | Set-Content -Path $wsbPath -Encoding ascii
    Info "starting the sandbox from $wsbPath (the log streams here)"
    Start-Process -FilePath $wsbPath
    Info ("waiting for the in-sandbox script to start writing $logPath " +
        '(the sandbox takes a moment to boot)')
    $started = $false
    $windowSeen = $false
    $windowAt = $null
    while ($true) {
        if (Test-Path $logPath) { $started = $true }
        $streamed = Stream-Log $logPath $streamed
        if (Test-Path $exitPath) { break }
        $sandboxes = @(Get-Process -Name 'WindowsSandbox*' -ErrorAction SilentlyContinue)
        # The launch goes through the shell; the sandbox processes take a
        # while to appear (agent_sandbox.py allows a minute).
        if (-not $sandboxes -and ((Get-Date) - $startTime).TotalSeconds -gt 90) {
            if ($started) {
                Die "the sandbox closed before reporting an exit code; see $logPath"
            }
            Die ('the sandbox did not start; is the Windows Sandbox feature ' +
                'enabled and up to date?')
        }
        foreach ($proc in $sandboxes) {
            if ($proc.MainWindowTitle -and -not $windowSeen) {
                $windowSeen = $true
                $windowAt = Get-Date
            }
        }
        if ((Get-Date) -gt $deadline) {
            Info ("timed out after $TimeoutSec seconds; the in-sandbox script " +
                'keeps running and the sandbox will shut itself down when it ' +
                "finishes; the log stays at $logPath")
            Die "see $logPath"
        }
        # The runs are long and quiet during toolchain install, so keep the
        # host from looking hung: report once a minute until the log appears.
        if (-not $started -and ((Get-Date) - $lastBeat).TotalSeconds -ge 60) {
            $elapsed = [int]((Get-Date) - $startTime).TotalSeconds
            $titles = @($sandboxes | ForEach-Object { $_.MainWindowTitle }) -join ', '
            if (-not $titles) { $titles = '(no window)' }
            if (-not $windowSeen) {
                Info ("no log after $elapsed seconds; sandbox processes: " +
                    "$($sandboxes.Count), window titles: $titles.  A window " +
                    'titled "Windows Sandbox" may be the sandbox desktop or a ' +
                    'one-instance error dialog (only one sandbox may run at a ' +
                    'time with this backend, and the agent session is itself ' +
                    'a sandbox); no window means the sandbox VM never started.')
            } else {
                Info ("no log after $elapsed seconds although the sandbox " +
                    'desktop is up; the LogonCommand either did not run or died ' +
                    'before its first log write.  On the sandbox desktop, look ' +
                    'for a console window with an error, and check that ' +
                    'C:\\mnt\\run shows args.json (if it does not, the mapped ' +
                    'folders are not working).')
                if (((Get-Date) - $windowAt).TotalSeconds -gt 180) {
                    Die ('the sandbox window has been up for over three minutes ' +
                        'without a log; if it is the sandbox desktop, investigate ' +
                        'as described above; if it is the one-instance error ' +
                        'dialog, a sandbox is already running (possibly the ' +
                        'agent session, which must be closed deliberately ' +
                        'before a run with this backend).')
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
                'running (only one instance is allowed with this backend; the ' +
                'agent session itself counts and must be closed deliberately ' +
                'first), that the Containers-DisposableClientVM optional ' +
                'feature is Enabled, that virtualization is enabled in the ' +
                'firmware (see the Hyper-V Requirements section of ' +
                'systeminfo), that the CmService is not Disabled, and that ' +
                'starting "Windows Sandbox" from the Start menu shows a ' +
                'window; also try -MemoryMB 4096 in case 8192 exceeds what ' +
                'the host can give.')
        }
        Start-Sleep -Seconds 2
    }
    return [int]((Get-Content $exitPath -Raw).Trim())
}

function Report-SandboxShutdown {
    if ((Get-SandboxBackend) -eq 'file' -and
        (Get-Process -Name 'WindowsSandbox*' -ErrorAction SilentlyContinue)) {
        Info ('the sandbox has not shut itself down yet (it schedules its ' +
            'own shutdown after writing the exit code); if it is still up ' +
            'in a minute, close the window by hand -- taskkill is ' +
            'indiscriminate and could hit the agent sandbox')
    }
}
