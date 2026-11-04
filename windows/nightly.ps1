# nightly.ps1 - the nightly build body on the Windows host, the counterpart
# of macos/nightly.sh (and of the linux crontab's rebuild.sh,
# test_via_docker.py, wall): update versions.txt with check_versions.py,
# build the wheels in a fresh sandbox, test them in another, and tell the
# logged-in user the result.  No git activity beyond what check_versions.py
# does to look up versions (git ls-remote); versions.txt is left modified in
# the checkout, as rebuild.sh leaves it.
#
# Run by Task Scheduler as the logged-in user (Windows Sandbox is a per-user
# feature and needs that session), at normal priority: a task's default
# priority is 7, below normal for CPU and lowered for I/O and memory, the
# same throttling cron gave the macos build.  Register it once, from a
# PowerShell prompt in the repository:
#
#   $a = New-ScheduledTaskAction -Execute powershell.exe -WorkingDirectory $PWD `
#        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PWD\windows\nightly.ps1`""
#   $t = New-ScheduledTaskTrigger -Daily -At 3:30am
#   $s = New-ScheduledTaskSettingsSet -Priority 4 -StartWhenAvailable `
#        -ExecutionTimeLimit (New-TimeSpan -Hours 12) -MultipleInstances IgnoreNew
#   $p = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
#   Register-ScheduledTask -TaskName large_image_wheels_nightly -Action $a -Trigger $t -Settings $s -Principal $p
#
# Everything the run prints, the native tools' output included, goes to
# windows\nightly.log (overwritten each night; the run folders hold the
# build and test logs).  The script runs itself again with -Body under cmd's
# redirection for that, then sends the result with msg.exe -- the wall of
# this platform: a dialog in the user's session that waits on a locked
# screen until it is dismissed.  msg messages are kept under 256 characters;
# the details are in the log.  The exit code is the run's, so the task's
# "Last Run Result" shows it too.

param([switch]$Body)

$ErrorActionPreference = 'Stop'
$repo = (Get-Item (Join-Path $PSScriptRoot '..')).FullName
Set-Location $repo
$log = Join-Path $repo 'windows\nightly.log'

if (-not $Body) {
    $start = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    # cmd expands the %variables% itself, which sidesteps PowerShell 5.1's
    # quoting of native arguments.
    $env:LIW_NIGHTLY_SCRIPT = $PSCommandPath
    $env:LIW_NIGHTLY_LOG = $log
    cmd.exe /d /c --% powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%LIW_NIGHTLY_SCRIPT%" -Body > "%LIW_NIGHTLY_LOG%" 2>&1
    $code = $LASTEXITCODE
    if ($code -eq 0) {
        $head = "large_image_wheels good: $start"
        $detail = @(git --no-pager diff -U0 versions.txt | Where-Object { $_ -match '^[+-][^+-]' })
    } else {
        $head = "large_image_wheels ERROR: $start (exit $code)`r`nlog: $log`r`nlast lines:"
        $detail = @(Get-Content $log -Tail 20 | Where-Object { $_.Trim() })
    }
    Add-Content -Path $log -Value (@('', $head) + $detail)
    # The newest lines are the useful ones when the message must be cut.
    $text = $head
    for ($i = 0; $i -lt $detail.Count; $i++) {
        $rest = ($detail[$i..($detail.Count - 1)] -join "`r`n")
        if (($head.Length + 2 + $rest.Length) -le 255) {
            $text = "$head`r`n$rest"
            break
        }
    }
    if ($text.Length -gt 255) { $text = $text.Substring(0, 255) }
    $text | msg.exe $env:USERNAME
    if ($LASTEXITCODE -ne 0) {
        Add-Content -Path $log -Value "msg.exe failed with exit code $LASTEXITCODE"
    }
    exit $code
}

# --- the body: its output is the log ---------------------------------------

function Step([string]$Name) {
    Write-Host "=== $Name $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
}

function Run-Step([string]$Name, [string[]]$Arguments) {
    Step $Name
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File @Arguments
    if ($LASTEXITCODE -ne 0) {
        Write-Host "nightly: $Name failed with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }
}

# rebuild.sh: python3 -u check_versions.py > versions.txt || (git diff
# versions.txt && false).  The output is written by hand, LF and no BOM,
# since PowerShell 5.1's redirection would write UTF-16.  check_versions.py
# carries PEP 723 metadata, so uv runs it with its dependencies; without uv,
# a python with requests and packaging.
Step 'check_versions'
$env:PYTHONIOENCODING = 'utf-8'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
if (Get-Command uv.exe -ErrorAction SilentlyContinue) {
    $versions = @(& uv.exe run --quiet check_versions.py)
} else {
    $versions = @(& python.exe -u check_versions.py)
}
$code = $LASTEXITCODE
[IO.File]::WriteAllText((Join-Path $repo 'versions.txt'),
    (($versions -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
git --no-pager diff versions.txt
if ($code -ne 0) {
    Write-Host "nightly: check_versions.py failed with exit code $code"
    exit $code
}

Run-Step 'build' @('windows\sandbox_run.ps1', 'build')
Run-Step 'test' @('windows\sandbox_run.ps1', 'test')
Step 'done'
exit 0
