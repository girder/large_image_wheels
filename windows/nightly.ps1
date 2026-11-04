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
# The task opens a console window for the length of the run (an
# Interactive task's powershell.exe gets a visible one).  To hide it, put
# -WindowStyle Hidden at the start of the action's -Argument string,
# before -File (the window still flashes for a moment when the task
# starts):
#
#        -Argument "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$PWD\windows\nightly.ps1`""
#
# then register the task again, adding -Force to Register-ScheduledTask
# to replace the existing one.
#
# Everything the run prints, the native tools' output included, goes to
# windows\nightly.log (overwritten each night; the run folders hold the
# build and test logs).  The script runs itself again with -Body under cmd's
# redirection for that, then writes the result -- good with the changed
# versions, or ERROR with the last 20 lines of the log -- as text into
# every console the user has open, as wall does (Send-ToConsoles).  The exit
# code is the run's, so the task's "Last Run Result" shows it too.

param([switch]$Body)

$ErrorActionPreference = 'Stop'
$repo = (Get-Item (Join-Path $PSScriptRoot '..')).FullName
Set-Location $repo
$log = Join-Path $repo 'windows\nightly.log'

# wall for Windows: write the text into every console this user can attach
# to (AttachConsole succeeds only for the user's own processes), once per
# console.  A console is the window of a cmd, powershell or Windows Terminal
# tab and everything running in it; consoles without a window (headless
# ones) are skipped, since nobody reads them.  This process gives up its own
# console to do it, so this is the last thing the script does.  Returns the
# number of consoles written to.
function Send-ToConsoles([string]$Text) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class LiwWall {
    [DllImport("kernel32.dll")] static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll")] static extern bool FreeConsole();
    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern bool WriteConsoleW(IntPtr handle, string text, uint count, out uint written, IntPtr reserved);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    public static int Send(int[] pids, string text) {
        var seen = new HashSet<IntPtr>();
        int sent = 0;
        FreeConsole();
        foreach (int pid in pids) {
            if (!AttachConsole((uint)pid)) continue;
            IntPtr window = GetConsoleWindow();
            if (window != IntPtr.Zero && seen.Add(window)) {
                // CONOUT$, GENERIC_READ | GENERIC_WRITE, shared, OPEN_EXISTING
                IntPtr handle = CreateFileW("CONOUT$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
                if (handle != new IntPtr(-1)) {
                    uint written;
                    if (WriteConsoleW(handle, text, (uint)text.Length, out written, IntPtr.Zero)) sent++;
                    CloseHandle(handle);
                }
            }
            FreeConsole();
        }
        return sent;
    }
}
'@
    $pids = @([Diagnostics.Process]::GetProcesses() | ForEach-Object { $_.Id } | Where-Object { $_ -ne $PID })
    return [LiwWall]::Send($pids, $Text)
}

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
    $lines = @($head) + $detail
    Add-Content -Path $log -Value (@('') + $lines)
    $sent = Send-ToConsoles ("`r`n" + ($lines -join "`r`n") + "`r`n")
    Add-Content -Path $log -Value "(sent to $sent consoles)"
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
