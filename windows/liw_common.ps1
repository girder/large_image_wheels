# liw_common.ps1 - functions shared by the in-sandbox scripts
# (build_wheels.ps1 and test_wheels.ps1).  Dot-source it after defining:
#
#   $LogPath        the log file (every Log line goes there and to the host)
#   $RepoDir        the repository (getver.py and versions.txt)
#   $CacheDir       the download cache (downloads\ underneath it)
#   $LIW_PY         where the NuGet pythons are expanded (one dir per version)
#   $LIW_DL         scratch directory for archive expansion
#   $LIW_TOOLS      where PortableGit is expanded
#   $script:Pythons the requested python versions ('3.13', '3.14t', ...)
#
# It sets $script:PatchPython (Ensure-Pythons) and returns the PortableGit
# directory from Ensure-PortableGit.  Everything is pinned through the
# shared versions.txt; nothing is fetched as "latest".

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

# Version pins come from the shared versions.txt, exactly like the linux
# build uses through getver.py.  getver.py resolves versions.txt relative
# to the current directory, so run it from the repository root.
function V([string]$Name) {
    if (-not $script:PatchPython) {
        Die 'V() called before the pythons were installed'
    }
    Push-Location $RepoDir
    # Relaxed ErrorActionPreference: a getver.py failure must be reported by
    # the check below, not turned into a terminating NativeCommandError by
    # the stderr redirection.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = (& $script:PatchPython (Join-Path $RepoDir 'getver.py') $Name |
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

# Downloads always land in the persistent cache (mapped read-write); the
# cache holds upstream artifacts only and is never a source of build
# outputs.  Expansion happens on the sandbox-local disk.
function Fetch([string]$Url, [string]$Name) {
    $downloads = Join-Path $CacheDir 'downloads'
    New-Item -ItemType Directory -Force -Path $downloads | Out-Null
    $dest = Join-Path $downloads $Name
    if (Test-Path $dest) {
        Log "cached: $Name"
        return $dest
    }
    Log "downloading $Url"
    # --retry-all-errors: by itself --retry covers only timeouts and some
    # server errors; the first host run died on a TLS connection error
    # (curl exit 35) on the seventh download in a row.  The file is
    # downloaded under a temporary name so a failed or interrupted
    # download never looks like a cached file.
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
        # A truncated or corrupt download would otherwise stay in the cache
        # and fail every later run the same way.
        Remove-Item -Path $Zip, $zipPath -Force -ErrorAction SilentlyContinue
        Die "cannot expand $Zip (removed from the cache; rerun to download it again): $($_.Exception.Message)"
    }
}

function Get-Json([string]$Url) {
    return Invoke-RestMethod -Uri $Url -Headers @{
        'User-Agent' = 'large_image_wheels'
    }
}

# Run a native command with its output streamed into the log.  Native
# stderr must not be redirected while $ErrorActionPreference is Stop (the
# redirection turns stderr lines into terminating error records in
# Windows PowerShell 5.1), so it is relaxed for the duration.  Returns the
# exit code when -NoDie is given instead of dying on a nonzero one.
function Run-Logged([string]$Exe, [string[]]$CmdArgs, [string]$What, [switch]$NoDie) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Exe @CmdArgs 2>&1 | ForEach-Object {
            # A stderr line arrives as an ErrorRecord; "$_" of one renders
            # as its exception type, not its text.
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

function Ensure-Pythons {
    # python.org builds via their NuGet packages (no installer, no machine
    # state beyond the expanded directory), one directory per requested
    # version under $LIW_PY.  A trailing t (3.14t) selects the
    # free-threaded build, which NuGet publishes as a separate
    # python-freethreaded package with the same version strings.  The
    # newest patch release of each minor is taken (the linux build likewise
    # takes whatever patch release the manylinux image ships).
    $indexes = @{}
    foreach ($minor in $script:Pythons) {
        $dest = Join-Path $LIW_PY $minor
        if (Test-Path (Join-Path $dest 'python.exe')) { continue }
        $package = if ($minor.EndsWith('t')) { 'python-freethreaded' } else { 'python' }
        $base = $minor.TrimEnd('t')
        if (-not $indexes.ContainsKey($package)) {
            $indexes[$package] = Get-Json "https://api.nuget.org/v3-flatcontainer/$package/index.json"
        }
        # Prereleases carry a -rc/-a/-b suffix; exclude them.
        $candidates = @($indexes[$package].versions |
            Where-Object { $_ -like "$base.*" -and $_ -notmatch '[a-z-]' })
        if ($candidates.Count -eq 0) {
            Die "no stable python $minor ($package) on nuget.org"
        }
        $full = $candidates | Sort-Object { [version]$_ } | Select-Object -Last 1
        Log "installing python $minor ($package $full)"
        # (Cached as .zip: a .nupkg is a zip, and Expand-Archive insists on
        # the extension; the cache need not hold every package twice.)
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
    # The patch python (newest requested stable python) runs getver.py and
    # install_msvc.py, writes the source patches, and drives delvewheel.
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

# PortableGit: git for the source clones, bash for the shared test script.
# The pin is the release tag without its v (2.56.0.windows.4); the asset is
# named after the version with the windows build number appended when it is
# not the first (PortableGit-2.56.0.4-64-bit.7z.exe,
# PortableGit-2.56.0-64-bit.7z.exe for 2.56.0.windows.1).  Returns the
# directory it was expanded into.
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
