# build_wheels.ps1 - build Windows x64 wheels inside a Windows Sandbox.
#
# This is the Windows counterpart of the repository's monolithic Dockerfile:
# a single self-contained script that installs the toolchain, builds every
# library a wheel needs from source into a private prefix with the pinned
# versions from the shared versions.txt, then builds and repairs the python
# wheels.  It is meant to run inside a fresh Windows Sandbox (started on
# the host by windows\sandbox_run.ps1) so that nothing from the host's
# installed software can influence the built wheels.
#
# As on linux and macos, everything a component needs is embedded here
# (the launcher's C source, jxrlib's CMakeLists.txt, the MSVC installer,
# the python patch scripts) and written out at build time; the windows
# directory holds no per-component files.
#
# Mapped folders (from sandbox_run.ps1):
#   C:\mnt\repo    the repository (read-only)
#   C:\mnt\cache   the download cache (read-write; holds upstream artifacts
#                  only -- toolchains, pythons, source tarballs.  Nothing
#                  built and no stamps are ever read from or written to it)
#   C:\mnt\wheels  wheel output (read-write; repaired wheels land here)
#   C:\mnt\run     per-run exchange (read-write; log, args.json, exit_code)
#
# Dev mode: when C:\mnt\repo is not mapped (the agent sandbox, or any
# checkout), the repository is this script's parent directory and the run,
# cache and wheels folders live under the build directory.  Nothing else
# differs: the same portable toolchain is installed the same way, so a
# build that passes here is a faithful rehearsal -- but never the
# verification, which is always a fresh sandbox run from the host.
#
# Everything is built in C:\liw_build (sandbox-local disk; mapped folders
# are slow).  The sandbox is disposable: no state outside the mapped
# folders survives the run.
#
# Toolchain: no administrator rights are needed.  MSVC and the Windows SDK
# are installed into the build directory by the install_msvc.py embedded
# below (from Microsoft's VS manifest, at the versions pinned in
# versions.txt; the payloads are cached), PortableGit, cmake, ninja, nasm
# and the python.org NuGet pythons are expanded from cached downloads.
#
# Parameters / environment (parameters win, then the environment, then
# C:\mnt\run\args.json, then the defaults):
#   -Packages     packages to build (no default: the launcher names them)
#   -Pythons      python versions to build for (default 3.11-3.15 plus
#                 3.14t and 3.15t; a trailing t selects the free-threaded
#                 NuGet build)
#   -WarmCache    only download/install the toolchain and pythons, then stop
#   -DevSetup     dev mode only: -WarmCache plus the extras development
#                 needs that the build does not (requests and packaging for
#                 check_versions.py, into the checkout's own python).  The
#                 one command that rebuilds a development environment after
#                 an agent sandbox reset.
#   LIW_PYTHONS   like -Pythons, space separated
#   LIW_FORCE     set to 1 to ignore completed-step stamps and rebuild all
#   LIW_BUILD     working directory (default C:\liw_build)
#
# Completed steps are stamped, so re-running this script only redoes what
# has not finished.  Stamps are for debugging; verification is always a
# full fresh sandbox run.

param(
    [string[]]$Packages = @(),
    [string[]]$Pythons = @(),
    [switch]$WarmCache,
    [switch]$DevSetup
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 (the sandbox's default) may not negotiate TLS 1.2
# on its own; the GitHub and NuGet APIs require it.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --------------------------------------------------------------------------
# Run exchange.
# --------------------------------------------------------------------------

$LIW_BUILD = if ($env:LIW_BUILD) { $env:LIW_BUILD } else { 'C:\liw_build' }
# The build sandbox has the repository mapped at C:\mnt\repo; anything
# else is dev mode (see the header).
$script:DevMode = -not (Test-Path 'C:\mnt\repo\windows\build_wheels.ps1')
if ($script:DevMode) {
    $RepoDir = Split-Path -Parent $PSScriptRoot
    $RunDir = Join-Path $LIW_BUILD 'run'
    $CacheDir = Join-Path $LIW_BUILD 'cache'
    $WheelsDir = Join-Path $LIW_BUILD 'wheels'
} else {
    $RepoDir = 'C:\mnt\repo'
    $RunDir = 'C:\mnt\run'
    $CacheDir = 'C:\mnt\cache'
    $WheelsDir = 'C:\mnt\wheels'
}
foreach ($dir in @($RunDir, $CacheDir, $WheelsDir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}
$LogPath = Join-Path $RunDir 'build.log'
$ExitCodePath = Join-Path $RunDir 'exit_code'

# --------------------------------------------------------------------------
# Build layout and environment.
# --------------------------------------------------------------------------

$LIW_PREFIX = Join-Path $LIW_BUILD 'prefix'
$LIW_SRC = Join-Path $LIW_BUILD 'src'
$LIW_STAMPS = Join-Path $LIW_BUILD 'stamps'
$LIW_PATCHES = Join-Path $LIW_BUILD 'patches'
$LIW_WHEELHOUSE = Join-Path $LIW_BUILD 'wheelhouse'
$LIW_TOOLS = Join-Path $LIW_BUILD 'tools'
$LIW_PY = Join-Path $LIW_BUILD 'python'
$LIW_DL = Join-Path $LIW_BUILD 'dl'
$LIW_LAUNCHERS = Join-Path $LIW_BUILD 'launchers'
$LIW_RELOCATE = Join-Path $LIW_BUILD 'relocate'
$LIW_JOBS = $env:NUMBER_OF_PROCESSORS
# The prefix with forward slashes, for paths passed to cmake (backslashes
# are escape characters once a path lands in a generated CMakeLists).
$script:CmakePrefix = $LIW_PREFIX -replace '\\', '/'
# The source patches take the prefix from the environment, as on macos.
$env:LIW_PREFIX = $LIW_PREFIX

foreach ($dir in @($LIW_BUILD, $LIW_PREFIX, $LIW_SRC, $LIW_STAMPS,
                   $LIW_PATCHES, $LIW_WHEELHOUSE, $LIW_TOOLS, $LIW_PY,
                   $LIW_DL, $LIW_LAUNCHERS)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

# Mirror the Dockerfile's isolation: no compiler or python environment
# variables may leak in.  The sandbox starts with a clean environment, so
# this matters mainly for direct in-sandbox reruns.
foreach ($name in @(
        'CFLAGS', 'CXXFLAGS', 'CPPFLAGS', 'LDFLAGS', 'INCLUDE', 'LIB',
        'LIBPATH', 'PYTHONPATH', 'PYTHONHOME', 'PYTHONUSERBASE',
        'PYTHONSTARTUP', 'PYTHONUTF8', 'DISTUTILS_USE_SDK',
        'VSINSTALLDIR', 'VCINSTALLDIR', 'VCToolsInstallDir',
        'WindowsSdkDir', 'WindowsSDKVersion', 'UCRTVersion',
        'CONDA_PREFIX', 'VIRTUAL_ENV')) {
    Remove-Item -Path "env:$name" -ErrorAction SilentlyContinue
}

# The repository is mapped read-only, so everything mutable lives under
# C:\liw_build.  Version pins always come from the shared versions.txt.
# At the top level of a script the parameters ARE script-scope variables,
# so the defaults below would overwrite -Pythons/-Packages; keep the
# parameter values first.
# (Split on commas: from powershell -File, "-Pythons 3.12,3.13" arrives
# as one string.)
$paramPythons = @($Pythons | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$paramPackages = @($Packages | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
# The same set as macos: the stable pythons plus the free-threaded ones
# that NuGet publishes (python-freethreaded 3.14 and 3.15).
$script:Pythons = @('3.11', '3.12', '3.13', '3.14', '3.15', '3.14t', '3.15t')
$script:Packages = @()
$script:Command = 'build'
$script:ArgsSource = 'defaults'
$argsFile = Join-Path $RunDir 'args.json'
if (Test-Path $argsFile) {
    $runArgs = Get-Content $argsFile -Raw | ConvertFrom-Json
    if ($runArgs.pythons) { $script:Pythons = @($runArgs.pythons) }
    if ($runArgs.packages) { $script:Packages = @($runArgs.packages) }
    if ($runArgs.command) { $script:Command = [string]$runArgs.command }
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
if ($paramPackages.Count -gt 0) {
    $script:Packages = $paramPackages
    $script:ArgsSource = 'parameters'
}
if ($WarmCache -or $DevSetup) { $script:Command = 'cache' }
# (-DevSetup installs into the checkout's python, which must be found
# before Main scrubs PATH.)
$script:CheckoutPython = (Get-Command python -ErrorAction SilentlyContinue).Source
# The run exchange persists between runs in dev mode (C:\liw_build\run),
# so clear the last run's markers; the log is recreated by the first Log
# call.  The parameter source is logged so a run that picks up a stale
# args.json is visible at once.
Remove-Item -Path (Join-Path $RunDir 'exit_code') -Force `
    -ErrorAction SilentlyContinue
Remove-Item -Path $LogPath -Force -ErrorAction SilentlyContinue

# The tool paths are filled in by Ensure-Toolchain; the sandbox PATH is
# scrubbed to system dirs plus these, so no other installed software can
# supply headers, link targets, or DLLs.
$script:ToolPaths = @()

# --------------------------------------------------------------------------
# Logging, downloads, pythons, PortableGit (test_wheels.ps1 carries its own
# copies of the ones it needs; the two in-sandbox scripts are
# self-contained, as the macos scripts are).
# --------------------------------------------------------------------------

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
function V([string]$Name, [string[]]$Extra = @()) {
    if (-not $script:PatchPython) {
        Die 'V() called before the pythons were installed'
    }
    Push-Location $RepoDir
    # Relaxed ErrorActionPreference: a getver.py failure must be reported by
    # the check below, not turned into a terminating NativeCommandError by
    # the stderr redirection.  Extra arguments are getver.py's component
    # selection (e.g. sqlite's year and release number).
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = (& $script:PatchPython (Join-Path $RepoDir 'getver.py') $Name @Extra |
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

# Output of a native command as one string, without stderr redirection
# turning into a terminating error.
function Capture-Native([string]$Exe, [string[]]$CmdArgs) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        return (& $Exe @CmdArgs 2>&1 | Out-String)
    } finally {
        $ErrorActionPreference = $prev
    }
}

# Write one of the sources embedded in this script (here-strings below)
# with LF endings and no BOM, whatever line endings the checkout has.
function Write-Embedded([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path,
        (($Text -replace "`r`n", "`n").TrimEnd() + "`n"),
        [System.Text.UTF8Encoding]::new($false))
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

# --------------------------------------------------------------------------
# Helpers.
# --------------------------------------------------------------------------

function Skip-If-Done([string]$Name) {
    $stamp = Join-Path $LIW_STAMPS "$Name.done"
    if ($env:LIW_FORCE -ne '1' -and (Test-Path $stamp)) { return $true }
    # The step is about to run: drop its old stamp now, so a step that
    # fails part way (or a forced rebuild that fails) can never be skipped
    # by a stale stamp on the next run.
    Remove-Item -Path $stamp -Force -ErrorAction SilentlyContinue
    return $false
}

function Done-Stamp([string]$Name) {
    New-Item -ItemType File -Force -Path (Join-Path $LIW_STAMPS "$Name.done") | Out-Null
}

function Git-Clone([string]$Url, [string]$Tag, [string]$Dest) {
    if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
    for ($n = 1; $n -le 10; $n++) {
        $cloneArgs = @('clone', '--depth=1', '--single-branch', '-c',
                       'advice.detachedHead=false')
        if ($Tag) { $cloneArgs += @('-b', $Tag) }
        $cloneArgs += @($Url, $Dest)
        & git @cloneArgs
        if ($LASTEXITCODE -eq 0) { return $Dest }
        Log "retrying git clone: $Url ($Tag)"
        Start-Sleep -Seconds 5
    }
    Die "git clone failed after 10 attempts: $Url ($Tag)"
}

# PortableGit's (msys) tar, not the system bsdtar: an archive with a
# symlink (libexpat's README.md -> expat/README.md) makes bsdtar fail,
# since creating a symlink needs a privilege the sandbox accounts lack.
# msys tar with MSYS=winsymlinks:lnk writes a .lnk shortcut instead (its
# default copies the target, which fails when the target comes later in
# the archive).  It wants POSIX paths and gzip beside it (usr\bin).
function Fetch-Tarball([string]$Url, [string]$Name, [string]$Dest) {
    $tarball = Fetch $Url $Name
    if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    $savedPath = $env:PATH
    $env:PATH = "$(Join-Path $script:GitDir 'usr\bin');$env:PATH"
    $env:MSYS = 'winsymlinks:lnk'
    try {
        & (Join-Path $script:GitDir 'usr\bin\tar.exe') -zxf (To-PosixPath $tarball) `
            -C (To-PosixPath $Dest) --strip-components 1
        $code = $LASTEXITCODE
    } finally {
        $env:PATH = $savedPath
        Remove-Item -Path 'env:MSYS' -ErrorAction SilentlyContinue
    }
    if ($code -ne 0) { Die "tar extraction failed: $Name (exit code $code)" }
    return $Dest
}

# Build and install a cmake project into the private prefix with Ninja and
# the MSVC toolset (entered through the VS Dev Shell; INCLUDE/LIB point at
# the MSVC and Windows SDK directories, with the private prefix first).
function Cmake-Build([string]$Src, [string[]]$CmakeArgs = @(), [switch]$NoInstall) {
    $build = Join-Path $Src '_build'
    if (Test-Path $build) { Remove-Item -Recurse -Force $build }
    # (Quoted: PowerShell does not expand a variable inside a bare
    # -DNAME=$var token, which configured zlib into a literal
    # "$LIW_PREFIX" directory on the first dev run.)
    # CMAKE_DISABLE_FIND_PACKAGE_Tiff: CMake's FindTIFF first tries the
    # tiff-config.cmake our libtiff installs, and takes the import library
    # from its IMPORTED_IMPLIB / _RELEASE / _DEBUG properties only; a
    # MinSizeRel libtiff exports _MINSIZEREL, so the module fell back to
    # the DLL's location and openjpeg's tools were handed tiff.dll to link
    # (LNK1107).  With the config lookup disabled the module finds tiff.lib
    # like any other library.
    # (Run-Logged: cmake's "Could NOT find" diagnostics go to stderr, which
    # must reach the log for a host run to be diagnosable.)
    # CMAKE_TRY_COMPILE_CONFIGURATION: cmake builds try_run probes as
    # Debug by default, against the debug CRT (-MDd), whose DLLs no
    # redistributable ships and this installer-free toolchain lacks -- the
    # probes compile and then fail to run (hdf5's InitOnceExecuteOnce
    # probe was the first whose failure was fatal).  The release
    # configuration's runtime is on PATH (the redist directory).
    Run-Logged 'cmake' (@('-S', $Src, '-B', $build, '-G', 'Ninja',
        '-DCMAKE_BUILD_TYPE=MinSizeRel',
        '-DCMAKE_TRY_COMPILE_CONFIGURATION=MinSizeRel',
        "-DCMAKE_PREFIX_PATH=$script:CmakePrefix",
        "-DCMAKE_INSTALL_PREFIX=$script:CmakePrefix",
        '-DCMAKE_INSTALL_LIBDIR=lib',
        '-DCMAKE_DISABLE_FIND_PACKAGE_Tiff=ON') + $CmakeArgs) "cmake configure in $Src"
    Run-Logged 'cmake' @('--build', $build, '--parallel', "$LIW_JOBS") "cmake build in $Src"
    if (-not $NoInstall) {
        Run-Logged 'cmake' @('--install', $build) "cmake install in $Src"
    }
}

function Assert-Files([string]$Dir, [string[]]$Patterns, [string]$What) {
    foreach ($pattern in $Patterns) {
        $found = @(Get-ChildItem -Path $Dir -Filter $pattern -File `
            -ErrorAction SilentlyContinue)
        if ($found.Count -eq 0) {
            Die ("${What}: no file matching $pattern in $Dir (a cmake feature " +
                'was silently disabled, or the DLL name assumption is wrong)')
        }
    }
}

# Every pattern must match a member of the wheel (the post-repair content
# assertion: a missing bundled DLL would otherwise only surface as an
# import failure in the tests, or worse, as a silent fall-through to a
# system DLL).
function Assert-WheelContains([string]$Wheel, [string[]]$Patterns, [string]$What) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Wheel)
    try {
        $names = @($zip.Entries | ForEach-Object { $_.FullName })
    } finally {
        $zip.Dispose()
    }
    foreach ($pattern in $Patterns) {
        if (-not ($names | Where-Object { $_ -match $pattern })) {
            Die "${What}: $Wheel has no member matching $pattern"
        }
    }
}

# dumpbin /DEPENDENTS listing for one image, as a flat set of names.
function Get-Dependents([string]$Image) {
    # Only the indented one-name-per-line entries of the "has the
    # following dependencies" block, not the "Dump of file ...dll" header.
    $out = (& dumpbin /DEPENDENTS $Image | Out-String)
    $names = @()
    foreach ($line in ($out -split "`n")) {
        if ($line -match '^\s+(\S+\.dll)\s*$') {
            $names += $Matches[1]
        }
    }
    return $names
}

function Assert-Dependents([string]$Image, [string[]]$Names, [string]$What) {
    $dependents = Get-Dependents $Image
    foreach ($name in $Names) {
        if (@($dependents) -notcontains $name) {
            Die ("${What}: $Image does not depend on $name (found: " +
                "$($dependents -join ', '))")
        }
    }
}

# Like Assert-Dependents, by name prefix: the meson-built DLLs carry
# versions in their names (freetype-6.dll, pango-1.0-0.dll), which the
# consumer's import table records as such.
function Assert-DependentStems([string]$Image, [string[]]$Stems, [string]$What) {
    $dependents = @(Get-Dependents $Image)
    Log "$(Split-Path -Leaf $Image) depends on: $($dependents -join ', ')"
    foreach ($stem in $Stems) {
        if (-not ($dependents | Where-Object { $_ -like "$stem*" })) {
            Die ("${What}: $Image does not depend on $stem* (found: " +
                "$($dependents -join ', ')); an optional dependency was missed " +
                '(check the build order)')
        }
    }
}

# The launcher: the stand-in for a command line tool bundled in a wheel.
#
# The linux and macos wheels ship their bundled tools (tiffinfo, gdalinfo,
# vips, ...) as <package>/bin/<tool> with an rpath to the wheel's library
# directory, so the tool runs when invoked by path.  Windows has no rpath:
# an .exe finds its DLLs in its own directory, the system directories and
# PATH, and delvewheel keeps the bundled (name-mangled) DLLs in the
# wheel's top-level <dist>.libs directory, two levels up from
# <package>/bin.  The build therefore moves each real tool into
# <dist>.libs, next to its DLLs (and next to the vcruntime140.dll the tools
# need and python's own directory would otherwise have to supply), and
# installs this launcher under the tool's name in <package>/bin.  The
# launcher finds <dist>.libs relative to its own location, puts it first on
# PATH, runs the tool there with the unchanged command line and the
# inherited console, and exits with the tool's exit status.  Nothing is
# duplicated; the real tool is a normal executable in a directory that is
# self-sufficient.
#
# It is built without the C runtime (kernel32 only, static buffers, no
# optimizer so no memset/memcpy intrinsics are introduced); see
# Build-Launcher for the command lines.  LIW_LIBS_NAME is the name of the
# wheel's library directory (a bare token, stringified in the source,
# because quotes do not survive a PowerShell native command line);
# LIW_LIBS_UP (default 2) is how many directories above the launcher's own
# directory that directory's parent is (<site-packages>/<package>/bin ->
# 2).
$script:LauncherSource = @'
#include <windows.h>

#ifndef LIW_LIBS_NAME
#error LIW_LIBS_NAME must be defined (the wheel's library directory name)
#endif
#ifndef LIW_LIBS_UP
#define LIW_LIBS_UP 2
#endif
#define LIW_STR2(x) #x
#define LIW_STR(x) LIW_STR2(x)
#define LIW_WIDE2(s) L ## s
#define LIW_WIDE(s) LIW_WIDE2(s)
#define LIW_LIBS_DIR LIW_WIDE(LIW_STR(LIW_LIBS_NAME))

#define BUF 32768

static wchar_t self[BUF];
static wchar_t target[BUF];
static wchar_t libs[BUF];
static wchar_t oldpath[BUF];
static wchar_t newpath[2 * BUF];
static char narrow[BUF];
static STARTUPINFOW si;
static PROCESS_INFORMATION pi;

static DWORD wlen(const wchar_t *s)
{
    DWORD n = 0;
    while (s[n]) {
        n++;
    }
    return n;
}

static void wcat(wchar_t *dest, DWORD *pos, const wchar_t *src)
{
    while (*src) {
        dest[(*pos)++] = *src++;
    }
    dest[*pos] = 0;
}

static void say(const wchar_t *text)
{
    HANDLE err = GetStdHandle(STD_ERROR_HANDLE);
    DWORD written = 0;
    int n;
    if (err == INVALID_HANDLE_VALUE || err == NULL) {
        return;
    }
    if (WriteConsoleW(err, text, wlen(text), &written, NULL)) {
        return;
    }
    /* Redirected stderr: write the text as bytes in the ANSI code page. */
    n = WideCharToMultiByte(CP_ACP, 0, text, -1, narrow, BUF, NULL, NULL);
    if (n > 1) {
        WriteFile(err, narrow, (DWORD)(n - 1), &written, NULL);
    }
}

static void fail(const wchar_t *what, const wchar_t *detail)
{
    say(L"launcher: ");
    say(what);
    if (detail) {
        say(L": ");
        say(detail);
    }
    say(L"\r\n");
    ExitProcess(127);
}

void entry(void)
{
    DWORD n, pos, code = 127, up;
    const wchar_t *name;
    BYTE *p;
    DWORD i;

    n = GetModuleFileNameW(NULL, self, BUF);
    if (n == 0 || n >= BUF - 1) {
        fail(L"cannot determine my own path", NULL);
    }
    /* name = the launcher's own file name; cut LIW_LIBS_UP + 1 path
     * components off to reach the directory that holds LIW_LIBS_DIR. */
    while (n > 0 && self[n - 1] != L'\\' && self[n - 1] != L'/') {
        n--;
    }
    name = self + n;
    for (up = 0; up <= LIW_LIBS_UP; up++) {
        while (n > 0 && (self[n - 1] == L'\\' || self[n - 1] == L'/')) {
            n--;
        }
        if (up == LIW_LIBS_UP) {
            break;
        }
        while (n > 0 && self[n - 1] != L'\\' && self[n - 1] != L'/') {
            n--;
        }
    }
    if (n == 0) {
        fail(L"my path is too shallow to locate the library directory", self);
    }
    pos = 0;
    for (i = 0; i < n; i++) {
        libs[pos++] = self[i];
    }
    libs[pos] = 0;
    wcat(libs, &pos, L"\\");
    wcat(libs, &pos, LIW_LIBS_DIR);
    pos = 0;
    wcat(target, &pos, libs);
    wcat(target, &pos, L"\\");
    wcat(target, &pos, name);
    if (GetFileAttributesW(target) == INVALID_FILE_ATTRIBUTES) {
        fail(L"bundled tool not found", target);
    }

    pos = 0;
    wcat(newpath, &pos, libs);
    n = GetEnvironmentVariableW(L"PATH", oldpath, BUF);
    if (n > 0 && n < BUF) {
        wcat(newpath, &pos, L";");
        wcat(newpath, &pos, oldpath);
    }
    if (!SetEnvironmentVariableW(L"PATH", newpath)) {
        fail(L"cannot set PATH", NULL);
    }

    /* Ctrl-C goes to the tool (same console); the launcher ignores it and
     * reports the tool's exit status. */
    SetConsoleCtrlHandler(NULL, TRUE);

    p = (BYTE *)&si;
    for (i = 0; i < sizeof(si); i++) {
        p[i] = 0;
    }
    si.cb = sizeof(si);
    if (!CreateProcessW(target, GetCommandLineW(), NULL, NULL, TRUE, 0,
                        NULL, NULL, &si, &pi)) {
        fail(L"cannot start bundled tool", target);
    }
    CloseHandle(pi.hThread);
    WaitForSingleObject(pi.hProcess, INFINITE);
    if (!GetExitCodeProcess(pi.hProcess, &code)) {
        code = 127;
    }
    CloseHandle(pi.hProcess);
    ExitProcess(code);
}
'@

# Build the launcher (above) for a wheel's library directory: the stand-in
# installed as <package>/bin/<tool>.exe that runs the real tool from
# <dist>.libs with that directory first on PATH.  Compiled once per
# library directory name, without the C runtime.
function Build-Launcher([string]$LibsName) {
    $exe = Join-Path $LIW_LAUNCHERS "$LibsName.exe"
    if (Test-Path $exe) { return $exe }
    $work = Join-Path $LIW_LAUNCHERS "$LibsName.build"
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $source = Join-Path $work 'launcher.c'
    Write-Embedded $source $script:LauncherSource
    Push-Location $work
    try {
        # kernel32 only, static buffers, no optimizer (it would introduce
        # memset/memcpy calls), no security cookie.  (Run-Logged: cl prints
        # the source file name, which would otherwise become part of this
        # function's return value.)
        Run-Logged 'cl' @('/nologo', '/Od', '/GS-', '/W4', "/DLIW_LIBS_NAME=$LibsName",
            '/c', $source) 'launcher compile'
        Run-Logged 'link' @('/nologo', '/NODEFAULTLIB', '/ENTRY:entry',
            '/SUBSYSTEM:CONSOLE', "/OUT:$exe", 'launcher.obj', 'kernel32.lib') 'launcher link'
    } finally {
        Pop-Location
    }
    $deps = @(Get-Dependents $exe)
    if ($deps.Count -ne 1 -or $deps[0] -ne 'KERNEL32.dll') {
        Die "launcher: unexpected dependencies: $($deps -join ', ')"
    }
    return $exe
}

# After delvewheel: move the bundled tools from <package>/bin into the
# wheel's <dist>.libs directory, next to the (mangled) DLLs they import and
# the vcruntime140.dll bundled for them, and put the launcher in their
# place so <package>/bin/<tool> still runs by path (as on linux and
# macos, where an rpath does this).  The wheel is unpacked and repacked
# with the wheel tool, which regenerates RECORD.
function Relocate-Tools([string]$Wheel, [string]$Package, [string]$LibsName) {
    $pp = $script:PatchPython
    $launcher = Build-Launcher $LibsName
    if (Test-Path $LIW_RELOCATE) { Remove-Item -Recurse -Force $LIW_RELOCATE }
    New-Item -ItemType Directory -Force -Path $LIW_RELOCATE | Out-Null
    Run-Logged $pp @('-m', 'wheel', 'unpack', '--dest', $LIW_RELOCATE, $Wheel) `
        "unpack of $Wheel"
    $root = Get-ChildItem -Path $LIW_RELOCATE -Directory | Select-Object -First 1
    if (-not $root) { Die "relocate: nothing unpacked from $Wheel" }
    $bin = Join-Path $root.FullName "$Package\bin"
    $libs = Join-Path $root.FullName $LibsName
    if (-not (Test-Path $libs)) { Die "relocate: $Wheel has no $LibsName directory" }
    $tools = @(Get-ChildItem -Path $bin -Filter '*.exe' -File -ErrorAction SilentlyContinue)
    if ($tools.Count -eq 0) { Die "relocate: no tools in $Package/bin of $Wheel" }
    foreach ($tool in $tools) {
        Move-Item $tool.FullName (Join-Path $libs $tool.Name) -Force
        Copy-Item $launcher (Join-Path $bin $tool.Name) -Force
    }
    Run-Logged $pp @('-m', 'wheel', 'pack', '--dest-dir', (Split-Path -Parent $Wheel),
        $root.FullName) "repack of $Wheel"
    if (-not (Test-Path $Wheel)) {
        Die "relocate: the repacked wheel is not at $Wheel (name changed?)"
    }
    Log "relocated $($tools.Count) tools of $(Split-Path -Leaf $Wheel) into $LibsName"
}

# --------------------------------------------------------------------------
# Toolchain.
# --------------------------------------------------------------------------

function Add-ToolPath([string]$Root, [string]$ExeName) {
    # Find <exe> under <root> (the zip layouts nest the binaries one level
    # deep) and record its directory for the build PATH.
    $found = Get-ChildItem -Path $Root -Recurse -Depth 3 -Filter $ExeName `
        -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $found) {
        Die "could not find $ExeName under $Root"
    }
    $dir = $found.DirectoryName
    if ($script:ToolPaths -notcontains $dir) {
        $script:ToolPaths += $dir
    }
    return $found.FullName
}

# install_msvc.py: install MSVC (with ATL) and the Windows SDK into a
# directory without administrator rights or the Visual Studio installer.
#
# Adapted from manthey/utils install_msvc.py for the wheel pipeline: the
# destination, the download cache, and the versions are parameters, and
# the compiler environment is written to a JSON file (read by Enter-Msvc)
# instead of the user's registry.  This is what lets the toolchain live in
# the download cache (unlike a VS Build Tools install, which lands in
# Program Files, needs elevation, and would be paid on every sandbox run)
# and lets the agent sandbox, where nobody is an administrator, build the
# same way the build sandbox does.
#
# The packages come straight from Microsoft's Visual Studio manifest: the
# compiler's .vsix packages are zip files, and the SDK's .msi packages are
# unpacked like an administrative install (msiexec /a) but by reading the
# MSI tables with msi.dll and exploding the cabinets with expand.exe, so
# the Windows Installer service is not needed.  Payload hashes from the
# manifest are checked.  vctip.exe, the compiler's usage reporter, is
# removed.
#
#   install_msvc.py --dest DIR --downloads DIR --env-json FILE
#                   [--msvc-version 14.44.17.14] [--sdk-version 26100]
#                   [--env-only]
#
# --env-only writes the environment for an existing --dest without
# downloading anything.  Without version pins the newest in the manifest
# is installed and the versions used are printed, so a pin can be
# recorded.  Using these tools is subject to the Visual Studio Build Tools
# license:
# https://visualstudio.microsoft.com/license-terms/vs2022-ga-diagnosticbuildtools/
$script:InstallMsvcSource = @'
import argparse
import concurrent.futures
import ctypes
import ctypes.wintypes
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

CHANNEL = 'https://aka.ms/vs/17/release/channel'
# Packages (Microsoft.VC.<version>.<suffix>) for x64 host and target.  MFC
# is deliberately not included (nothing in the dependency tree uses it);
# ATL headers are small and some cmake projects probe for them.
MSVC_PACKAGES = (
    'Tools.HostX64.TargetX64.base',
    'Tools.HostX64.TargetX64.Res.base',
    'CRT.Headers.base',
    'CRT.x64.Desktop.base',
    'CRT.x64.Store.base',
    'CRT.Redist.X64.base',
    'ATL.Headers.base',
    'ATL.X64.base',
)
SDK_MSIS = (
    'Windows SDK Desktop Headers x64-x86_en-us.msi',
    # The x64-named header MSIs only carry x64-specific files; the
    # architecture-neutral headers (most of um and shared) ship in the
    # x86-named packages, which an x64 install needs as well.
    'Windows SDK Desktop Headers x86-x86_en-us.msi',
    'Windows SDK Desktop Libs x64-x86_en-us.msi',
    'Windows SDK Desktop Tools x64-x86_en-us.msi',
    'Windows SDK OnecoreUap Headers x64-x86_en-us.msi',
    'Windows SDK OnecoreUap Headers x86-x86_en-us.msi',
    'Windows SDK for Windows Store Apps Headers-x86_en-us.msi',
    'Windows SDK for Windows Store Apps Headers OnecoreUap-x86_en-us.msi',
    'Windows SDK for Windows Store Apps Libs-x86_en-us.msi',
    'Windows SDK for Windows Store Apps Tools-x86_en-us.msi',
    'Universal CRT Headers Libraries and Sources-x86_en-us.msi',
)


def log(msg):
    print(f'install_msvc: {msg}', flush=True)


def get_json(url):
    with urllib.request.urlopen(url) as resp:
        return json.load(resp)


def version_key(text):
    return tuple(int(part) for part in text.split('.'))


def load_manifest():
    channel = get_json(CHANNEL)
    item = next(entry for entry in channel['channelItems']
                if entry['id'] == 'Microsoft.VisualStudio.Manifests.VisualStudio')
    return get_json(item['payloads'][0]['url'])['packages']


def pick_versions(packages, msvc_version, sdk_version):
    """Resolve the MSVC tools version and the SDK package id.

    With pins, the pinned versions must exist in the manifest (the
    manifest keeps every released toolset of the VS 2022 line, so a pin
    stays installable); without, the newest of each.
    """
    tools = re.compile(r'microsoft\.vc\.([\d.]+)\.tools\.hostx64\.targetx64\.base$')
    available = sorted({match.group(1) for match in
                        (tools.match(pkg['id'].lower()) for pkg in packages) if match},
                       key=version_key)
    if msvc_version:
        if msvc_version not in available:
            sys.exit(f'install_msvc: MSVC {msvc_version} is not in the manifest '
                     f'(available: {", ".join(available)})')
        msvc = msvc_version
    else:
        msvc = available[-1]
    sdk_component = re.compile(r'microsoft\.visualstudio\.component\.windows1[01]sdk\.(\d+)$')
    components = [(int(match.group(1)), pkg) for pkg in packages
                  for match in [sdk_component.match(pkg['id'].lower())] if match]
    if sdk_version:
        # Either the full 10.0.<build>.0 or the bare build number (which is
        # what versions.txt records).
        parts = sdk_version.split('.')
        build = int(parts[2] if len(parts) >= 3 else parts[0])
        chosen = [pkg for number, pkg in components if number == build]
        if not chosen:
            sys.exit(f'install_msvc: Windows SDK {sdk_version} is not in the manifest '
                     f'(available builds: {sorted(number for number, _ in components)})')
        sdk_package = next(iter(chosen[0]['dependencies']))
    else:
        sdk_package = next(iter(max(components, key=lambda entry: entry[0])[1]['dependencies']))
    return msvc, sdk_package


def msvc_payloads(packages, version):
    wanted = {f'microsoft.vc.{version}.{suffix}'.lower() for suffix in MSVC_PACKAGES}
    payloads = []
    for pkg in packages:
        if pkg['id'].lower() in wanted and pkg.get('language') in (None, 'neutral', 'en-US'):
            payloads.extend(pkg.get('payloads', []))
    found = {pkg['id'].lower() for pkg in packages if pkg['id'].lower() in wanted}
    if found != wanted:
        sys.exit(f'install_msvc: missing packages: {sorted(wanted - found)}')
    return payloads


def download(payload, folder):
    path = folder / Path(payload['fileName'].replace('\\', '/')).name
    digest = payload['sha256'].lower()
    if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == digest:
        return path
    partial = path.with_name(path.name + '.partial')
    # Retried like the curl downloads (--retry-all-errors): a sandbox's
    # NAT'd connection drops a TLS handshake now and then, and one failed
    # payload out of fifty must not end the run.
    for attempt in range(8):
        sha = hashlib.sha256()
        try:
            with urllib.request.urlopen(payload['url']) as resp, open(partial, 'wb') as fp:
                while chunk := resp.read(1 << 20):
                    sha.update(chunk)
                    fp.write(chunk)
        except OSError as exc:
            log(f'retrying {path.name} ({exc})')
            time.sleep(5)
            continue
        if sha.hexdigest() != digest:
            partial.unlink()
            msg = f'sha256 mismatch for {payload["fileName"]}'
            raise RuntimeError(msg)
        partial.replace(path)
        return path
    msg = f'download of {payload["fileName"]} failed after 8 attempts'
    raise RuntimeError(msg)


def download_all(payloads, folder):
    folder.mkdir(parents=True, exist_ok=True)
    total = sum(payload.get('size', 0) for payload in payloads)
    log(f'downloading {len(payloads)} files ({total / 2 ** 20:.0f} MB; cached files are kept)')
    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        return list(pool.map(lambda payload: download(payload, folder), payloads))


def long_name(name):
    """The long form of an MSI 'short|long' name."""
    return name.split('|')[-1]


def msi_string(record, field):
    """A field of an MSI record as a string."""
    msi = ctypes.windll.msi
    buffer = ctypes.create_unicode_buffer(256)
    size = ctypes.wintypes.DWORD(len(buffer))
    error = msi.MsiRecordGetStringW(record, field, buffer, ctypes.byref(size))
    while error == 234:  # ERROR_MORE_DATA
        buffer = ctypes.create_unicode_buffer(size.value + 1)
        size.value = len(buffer)
        error = msi.MsiRecordGetStringW(record, field, buffer, ctypes.byref(size))
    if error != 0:
        sys.exit(f'install_msvc: MsiRecordGetStringW failed: {error}')
    return buffer.value


def msi_rows(database, query):
    """All rows of a query against an open MSI database, as string lists."""
    msi = ctypes.windll.msi
    view = ctypes.wintypes.HANDLE()
    if msi.MsiDatabaseOpenViewW(database, query, ctypes.byref(view)) != 0:
        sys.exit(f'install_msvc: MsiDatabaseOpenViewW failed: {query}')
    if msi.MsiViewExecute(view, None) != 0:
        msi.MsiCloseHandle(view)
        sys.exit(f'install_msvc: MsiViewExecute failed: {query}')
    rows = []
    while True:
        record = ctypes.wintypes.HANDLE()
        error = msi.MsiViewFetch(view, ctypes.byref(record))
        if error == 259:  # ERROR_NO_MORE_ITEMS
            break
        if error != 0:
            msi.MsiCloseHandle(view)
            sys.exit(f'install_msvc: MsiViewFetch failed: {error}')
        rows.append([msi_string(record, field) for field in
                     range(1, msi.MsiRecordGetFieldCount(record) + 1)])
        msi.MsiCloseHandle(record)
    msi.MsiCloseHandle(view)
    return rows


def msi_file_plan(msi_path, root):
    """Map each cabinet of an MSI to its [(member name, target path), ...].

    This replicates how an administrative install (msiexec /a) unpacks a
    package: the directories are resolved through the Directory table
    relative to TARGETDIR (directory properties set by AppSearch are not
    part of the admin sequence), and the cabinet members, which are named
    after the File table keys, are renamed to their FileName column value.
    """
    msi = ctypes.windll.msi
    database = ctypes.wintypes.HANDLE()
    if msi.MsiOpenDatabaseW(str(msi_path), 0, ctypes.byref(database)) != 0:
        sys.exit(f'install_msvc: cannot open {msi_path}')
    media = sorted((int(sequence), cabinet) for sequence, cabinet in
                   msi_rows(database, 'SELECT `LastSequence`,`Cabinet` FROM `Media`')
                   if cabinet)
    files = [row for row in msi_rows(
        database, 'SELECT `File`,`Component_`,`FileName`,`Sequence` FROM `File`') if row[3]]
    component_dir = {row[0]: row[1] for row in msi_rows(
        database, 'SELECT `Component`,`Directory_` FROM `Component`')}
    parents = {row[0]: (row[1], row[2]) for row in msi_rows(
        database, 'SELECT `Directory`,`Directory_Parent`,`DefaultDir` FROM `Directory`')}
    msi.MsiCloseHandle(database)

    def resolve(directory, seen=()):
        if directory == 'TARGETDIR':
            return root
        if directory in seen:
            sys.exit(f'install_msvc: directory loop at {directory} in {msi_path}')
        parent, default = parents[directory]
        base = resolve(parent, seen + (directory,))
        # An administrative image uses the source part of a
        # "target:source" default directory.
        name = default.split(':')[-1]
        if name in ('', '.'):
            return base
        return base / long_name(name)

    plan = {}
    for file_key, component, file_name, sequence in files:
        cabinet = next((cab for last, cab in media if last >= int(sequence)), None)
        if cabinet is None:
            sys.exit(f'install_msvc: no cabinet covers {file_name} in {msi_path}')
        target = resolve(component_dir[component]) / long_name(file_name)
        plan.setdefault(cabinet, []).append((file_key, target))
    return plan


def extract_vsix(path, dest):
    with zipfile.ZipFile(path) as zf:
        for info in zf.infolist():
            name = urllib.parse.unquote(info.filename)
            if not name.startswith('Contents/') or name.endswith('/'):
                continue
            target = dest / name[len('Contents/'):]
            target.parent.mkdir(parents=True, exist_ok=True)
            with zf.open(info) as src, open(target, 'wb') as dst:
                shutil.copyfileobj(src, dst)


def install_sdk(packages, sdk_package, dest, downloads):
    pkg = next(pkg for pkg in packages if pkg['id'] == sdk_package)
    by_name = {payload['fileName'].replace('\\', '/').split('/')[-1]: payload
               for payload in pkg['payloads']}
    missing = [name for name in SDK_MSIS if name not in by_name]
    if missing:
        sys.exit(f'install_msvc: {sdk_package} lacks {missing}')
    folder = downloads / 'sdk'
    msis = download_all([by_name[name] for name in SDK_MSIS], folder)
    cabs = set()
    for msi in msis:
        cabs.update(name.decode() for name in re.findall(rb'[0-9a-f]{32}\.cab', msi.read_bytes()))
    download_all([by_name[name] for name in sorted(cabs) if name in by_name], folder)
    expand = Path(os.environ['SYSTEMROOT']) / 'System32' / 'expand.exe'
    for msi in msis:
        log(f'unpacking {msi.name}')
        for cabinet, entries in msi_file_plan(msi, dest).items():
            staging = dest / '_extract' / f'{msi.stem}-{Path(cabinet).stem}'
            staging.mkdir(parents=True, exist_ok=True)
            subprocess.run([str(expand), '-F:*', str(folder / cabinet), str(staging)],
                           check=True, stdout=subprocess.DEVNULL)
            for member, target in entries:
                source = staging / member
                if not source.exists():
                    sys.exit(f'install_msvc: {cabinet} lacks {member}')
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(source), target)
            shutil.rmtree(staging)
    shutil.rmtree(dest / '_extract', ignore_errors=True)


def latest_dir(parent, required=None):
    dirs = [path for path in parent.iterdir()
            if path.is_dir() and re.fullmatch(r'[\d.]+', path.name)]
    if required:
        dirs = [path for path in dirs if (path / required).exists()]
    if not dirs:
        sys.exit(f'install_msvc: nothing found in {parent}')
    return max(dirs, key=lambda path: version_key(path.name))


def build_environment(dest):
    vc = latest_dir(dest / 'VC' / 'Tools' / 'MSVC')
    kits = dest / 'Windows Kits' / '10'
    sdkv = latest_dir(kits / 'Include', 'um').name
    paths = [vc / 'bin' / 'Hostx64' / 'x64', kits / 'bin' / sdkv / 'x64']
    # Runtime DLLs (CRT) so that dynamically linked programs run during
    # the build (the wheels bundle their own vcruntime through delvewheel).
    redist = dest / 'VC' / 'Redist' / 'MSVC'
    if redist.exists():
        paths += sorted(path for path in redist.glob('*/x64/*') if path.is_dir())
    include = [vc / 'include', vc / 'atlmfc' / 'include'] + [
        kits / 'Include' / sdkv / sub for sub in ('ucrt', 'shared', 'um', 'winrt', 'cppwinrt')]
    lib = [vc / 'lib' / 'x64', vc / 'atlmfc' / 'lib' / 'x64',
           kits / 'Lib' / sdkv / 'ucrt' / 'x64', kits / 'Lib' / sdkv / 'um' / 'x64']
    env = {
        'INCLUDE': ';'.join(str(path) for path in include),
        'LIB': ';'.join(str(path) for path in lib),
        'LIBPATH': ';'.join(str(path) for path in lib[:2]),
        'VCToolsInstallDir': f'{vc}\\',
        'VCToolsVersion': vc.name,
        'WindowsSdkDir': f'{kits}\\',
        'WindowsSDKVersion': f'{sdkv}\\',
        'Platform': 'x64',
        # setuptools then uses this compiler from the environment instead of
        # looking for a Visual Studio installation.
        'DISTUTILS_USE_SDK': '1',
        'MSSdk': '1',
        'VSCMD_SKIP_SENDTELEMETRY': '1',
    }
    return env, [str(path) for path in paths], vc.name, sdkv


def main():
    parser = argparse.ArgumentParser(
        description='install MSVC and the Windows SDK without the VS installer')
    parser.add_argument('--dest', required=True, help='install directory')
    parser.add_argument('--downloads', required=True,
                        help='download cache (manifest payloads, kept for later runs)')
    parser.add_argument('--env-json', required=True,
                        help='where to write {"env": {...}, "paths": [...], '
                             '"msvc": ..., "sdk": ...}')
    parser.add_argument('--msvc-version', default='',
                        help='MSVC tools version to install (default: newest)')
    parser.add_argument('--sdk-version', default='',
                        help='Windows SDK version to install, e.g. 10.0.26100.0 '
                             '(default: newest)')
    parser.add_argument('--env-only', action='store_true',
                        help='only write the environment for an existing --dest')
    args = parser.parse_args()
    if sys.platform != 'win32':
        sys.exit('install_msvc: this installs the Windows compiler and must run on Windows')
    dest = Path(args.dest)
    downloads = Path(args.downloads)
    if not args.env_only:
        log('reading the Visual Studio manifest')
        packages = load_manifest()
        msvc, sdk_package = pick_versions(packages, args.msvc_version, args.sdk_version)
        log(f'MSVC {msvc} with ATL, and {sdk_package}, into {dest}')
        log('use is subject to the Visual Studio Build Tools license')
        if dest.exists():
            shutil.rmtree(dest)
        dest.mkdir(parents=True)
        for vsix in download_all(msvc_payloads(packages, msvc), downloads / 'msvc'):
            log(f'extracting {vsix.name}')
            extract_vsix(vsix, dest)
        install_sdk(packages, sdk_package, dest, downloads)
        for vctip in dest.rglob('vctip.exe'):
            vctip.unlink()
    env, paths, vc_version, sdk_version = build_environment(dest)
    # The pins are recorded as given so a caller can tell whether an
    # existing install is the one versions.txt asks for (the manifest's
    # package version, 14.44.17.14, differs from the toolset's own build
    # number, 14.44.35207, which is what the install directory is named).
    with open(args.env_json, 'w') as fp:
        json.dump({'env': env, 'paths': paths, 'msvc': vc_version, 'sdk': sdk_version,
                   'pins': {'msvc': args.msvc_version, 'sdk': args.sdk_version}},
                  fp, indent=2)
    log(f'MSVC {vc_version} and Windows SDK {sdk_version} at {dest}; '
        f'environment written to {args.env_json}')


if __name__ == '__main__':
    main()
'@

# Every tool is pinned through versions.txt and fetched from a URL derived
# from the pin: the GitHub releases API is deliberately not used (it rate
# limits unauthenticated callers, and a NAT'd sandbox shares its address),
# and nothing is "latest".
function Ensure-Toolchain {
    $bin = Join-Path $LIW_TOOLS 'bin'
    New-Item -ItemType Directory -Force -Path $bin | Out-Null

    # --- git (PortableGit; the test sandbox uses the same package for bash)
    $gitDir = Ensure-PortableGit
    $script:GitDir = $gitDir
    $script:ToolPaths += (Join-Path $gitDir 'cmd')
    $script:ToolPaths += (Join-Path $gitDir 'bin')
    # TLS trust for the python downloaders (meson's subproject wraps,
    # install_msvc.py): python verifies with OpenSSL against the Windows
    # certificate store, and a fresh sandbox's store has about sixteen
    # roots -- github.com's is not among them.  Windows fetches a missing
    # root on demand only for Schannel clients (curl.exe, Invoke-WebRequest),
    # which is why the first runs got through: a curl download from
    # github.com (cmake, ninja, the LLVM tarball) had installed the root
    # before meson needed it, and the first run with everything cached
    # failed glib's pcre2 wrap with CERTIFICATE_VERIFY_FAILED.  PortableGit
    # ships the curl CA bundle git itself uses; OpenSSL honors SSL_CERT_FILE
    # (python's load_default_certs loads it in addition to the store), so
    # every python download verifies against the same pinned bundle.
    $bundle = Get-ChildItem -Path $gitDir -Recurse -Depth 4 -Filter 'ca-bundle.crt' -File |
        Where-Object { $_.FullName -match '\\ssl\\certs\\' } |
        Sort-Object FullName | Select-Object -First 1
    if (-not $bundle) { Die "no ca-bundle.crt under $gitDir (PortableGit layout changed?)" }
    $env:SSL_CERT_FILE = $bundle.FullName
    Log "python TLS trust: SSL_CERT_FILE=$($bundle.FullName)"

    # --- cmake and ninja
    $cmakeVersion = V 'cmake'
    $cmakeDir = Join-Path $LIW_TOOLS 'cmake'
    if (-not (Test-Path (Join-Path $cmakeDir ".installed-$cmakeVersion"))) {
        Log "fetching cmake $cmakeVersion"
        $name = "cmake-$cmakeVersion-windows-x86_64.zip"
        Expand-Zip (Fetch "https://github.com/Kitware/CMake/releases/download/v$cmakeVersion/$name" $name) $cmakeDir
        New-Item -ItemType File -Force -Path (Join-Path $cmakeDir ".installed-$cmakeVersion") | Out-Null
    }
    Add-ToolPath $cmakeDir 'cmake.exe' | Out-Null
    $ninjaVersion = V 'ninja'
    $ninjaFile = Join-Path $bin 'ninja.exe'
    if (-not (Test-Path (Join-Path $bin ".ninja-$ninjaVersion"))) {
        Log "fetching ninja $ninjaVersion"
        $zip = Fetch "https://github.com/ninja-build/ninja/releases/download/v$ninjaVersion/ninja-win.zip" "ninja-$ninjaVersion-win.zip"
        Expand-Zip $zip (Join-Path $LIW_DL 'ninja')
        Copy-Item (Join-Path $LIW_DL 'ninja\ninja.exe') $ninjaFile -Force
        New-Item -ItemType File -Force -Path (Join-Path $bin ".ninja-$ninjaVersion") | Out-Null
    }
    if ($script:ToolPaths -notcontains $bin) { $script:ToolPaths += $bin }

    # --- nasm (libjpeg-turbo SIMD; x86-only upstream, fine while win_amd64
    # is the only target)
    $nasmVersion = V 'nasm'
    $nasmDir = Join-Path $LIW_TOOLS 'nasm'
    if (-not (Test-Path (Join-Path $nasmDir ".installed-$nasmVersion"))) {
        Log "fetching nasm $nasmVersion"
        $name = "nasm-$nasmVersion-win64.zip"
        Expand-Zip (Fetch "https://www.nasm.us/pub/nasm/releasebuilds/$nasmVersion/win64/$name" $name) $nasmDir
        New-Item -ItemType File -Force -Path (Join-Path $nasmDir ".installed-$nasmVersion") | Out-Null
    }
    Add-ToolPath $nasmDir 'nasm.exe' | Out-Null

    # --- MSVC and the Windows SDK, installed without the VS installer and
    # without elevation by install_msvc.py (embedded above) at the pinned
    # versions.  The manifest payloads live in the cache (so a sandbox run
    # only extracts); the install itself is sandbox-local.
    $msvcVersion = V 'msvc'
    $sdkVersion = V 'winsdk'
    $msvcDir = Join-Path $LIW_TOOLS 'msvc'
    $envJson = Join-Path $LIW_TOOLS 'msvc_env.json'
    $installer = Join-Path $LIW_TOOLS 'install_msvc.py'
    Write-Embedded $installer $script:InstallMsvcSource
    # The pin is the manifest's package version (14.44.17.14); the
    # installer records the pins it was given next to the toolset build
    # number it found (14.44.35207), and an install is reused only when its
    # recorded pins are the current ones.
    $installed = $false
    if (Test-Path $envJson) {
        $info = Get-Content $envJson -Raw | ConvertFrom-Json
        $installed = ($info.pins.msvc -eq $msvcVersion) -and
            ($info.pins.sdk -eq $sdkVersion) -and
            (Test-Path (Join-Path $info.env.VCToolsInstallDir 'bin\Hostx64\x64\cl.exe'))
    }
    if (-not $installed) {
        Log "installing MSVC $msvcVersion and Windows SDK $sdkVersion (cached payloads are reused)"
        Run-Logged $script:PatchPython @(
            '-I', $installer,
            '--dest', $msvcDir,
            '--downloads', (Join-Path $CacheDir 'downloads\vs'),
            '--env-json', $envJson,
            '--msvc-version', $msvcVersion,
            '--sdk-version', $sdkVersion) 'install_msvc.py'
        $info = Get-Content $envJson -Raw | ConvertFrom-Json
        if ($info.sdk -ne "10.0.$sdkVersion.0") {
            Die "install_msvc.py installed SDK $($info.sdk), not the pinned 10.0.$sdkVersion.0"
        }
    }
    $script:MsvcEnvJson = $envJson
    # The VC++ redistributable DLLs that match the toolset (vcruntime140,
    # msvcp140, ...): delvewheel bundles the ones our DLLs import from here.
    $script:VcRedist = (Get-ChildItem -Path (Join-Path $msvcDir 'VC\Redist\MSVC') `
        -Recurse -Depth 3 -Directory -Filter 'Microsoft.VC14*.CRT' |
        Where-Object { $_.FullName -match '\\x64\\' } | Select-Object -First 1).FullName
    if (-not $script:VcRedist -or
        -not (Test-Path (Join-Path $script:VcRedist 'vcruntime140.dll'))) {
        Die "no x64 VC++ redistributable directory under $msvcDir\VC\Redist\MSVC"
    }
    # The OpenMP runtime next to it (vcomp140.dll): ImageMagick is built
    # with /openmp like the linux build's -fopenmp, and delvewheel bundles
    # the DLL from here.
    $script:VcOpenMP = (Get-ChildItem -Path (Split-Path -Parent $script:VcRedist) `
        -Directory -Filter 'Microsoft.VC14*.OpenMP' | Select-Object -First 1).FullName
    Log "using MSVC $($info.msvc) and Windows SDK $($info.sdk) at $msvcDir (redist $script:VcRedist)"
}

# meson and pkgconf, pinned through versions.txt and installed into the
# patch python (both are pure build tools; nothing of them reaches a
# wheel).  pkg-config is how meson projects (glib, cairo, openslide, ...)
# find our libraries: every cmake and meson install in the prefix leaves a
# .pc file, and the lookup is scoped to the prefix (PKG_CONFIG_LIBDIR), so
# nothing else on the machine can satisfy a dependency.  meson maps the
# .pc files' -l flags to .lib files for MSVC.
function Ensure-Meson {
    if ($script:MesonReady) { return }
    $script:MesonReady = $true
    $pp = $script:PatchPython
    # (pkgconf-pypi: the pypi wheels trail pkgconf's own releases, which
    # the linux build's pkgconf pin follows.)
    & $pp -m pip install --quiet --no-warn-script-location `
        "meson==$(V meson)" "pkgconf==$(V pkgconf-pypi)" packaging | Out-Null
    Assert-Exit 'pip install of meson/pkgconf'
    $scripts = Join-Path (Split-Path -Parent $pp) 'Scripts'
    foreach ($exe in @('meson.exe', 'pkgconf.exe')) {
        if (-not (Test-Path (Join-Path $scripts $exe))) { Die "$exe is missing after the pip install" }
    }
    $env:PATH = "$scripts;$env:PATH"
    # PKG_CONFIG is the real pkgconf binary the pypi package embeds
    # (pkgconf\.bin\pkgconf.exe), not the Scripts\pkgconf.exe launcher,
    # which runs `python -m pkgconf` with the launching python's module
    # path: inside pip's build isolation that import fails (no pkgconf
    # module there), and pyvips's pkg-config probe for vips came back
    # empty.  A plain executable serves meson, cmake and pip alike.
    $embedded = (Capture-Native $pp @('-c', 'import pkgconf; print(pkgconf.get_executable())')).Trim()
    if (-not $embedded -or -not (Test-Path $embedded)) { Die "the pkgconf package reports no embedded binary ($embedded)" }
    # (Forward slashes: the pkgconfig python package splits its command
    # line with shlex in POSIX mode, which eats backslashes.)
    $env:PKG_CONFIG = $embedded -replace '\\', '/'
    $env:PKG_CONFIG_PATH = "$LIW_PREFIX\lib\pkgconfig;$LIW_PREFIX\share\pkgconfig"
    $env:PKG_CONFIG_LIBDIR = $env:PKG_CONFIG_PATH
    Log "meson $(V meson) from $scripts, pkgconf $env:PKG_CONFIG; pkg-config scoped to $LIW_PREFIX"
}

# A pkg-config file for a library whose cmake build installs none on MSVC
# (libpng, expat) or that has no build system (sqlite), so meson projects
# find it like every other library.  Libs/Cflags are pkg-config syntax
# relative to ${libdir}/${includedir}; meson maps -l to .lib for MSVC.
function Write-PkgConfig([string]$Name, [string]$Description, [string]$Version,
                         [string]$Libs, [string]$Cflags = '-I${includedir}',
                         [string]$IncludeDir = '${prefix}/include', [string]$Requires = '') {
    $pcDir = Join-Path $LIW_PREFIX 'lib\pkgconfig'
    New-Item -ItemType Directory -Force -Path $pcDir | Out-Null
    $lines = @(
        "prefix=$script:CmakePrefix", 'exec_prefix=${prefix}', 'libdir=${exec_prefix}/lib',
        "includedir=$IncludeDir", '', "Name: $Name", "Description: $Description",
        "Version: $Version")
    if ($Requires) { $lines += "Requires.private: $Requires" }
    $lines += @("Libs: -L`${libdir} $Libs", "Cflags: $Cflags", '')
    [System.IO.File]::WriteAllText((Join-Path $pcDir "$Name.pc"), ($lines -join "`n"))
    Log "wrote $Name.pc"
}

# clang-cl from the pinned LLVM release, for the one project that needs a
# GNU C extension MSVC lacks: openslide requires __attribute__((cleanup))
# (its g_autoptr use).  clang-cl is MSVC-ABI compatible -- it compiles
# against the same headers and import libraries and links with link.exe --
# so an openslide built with it is one more MSVC-ABI DLL in the prefix.
# Only the compiler driver and its resource headers are extracted from the
# 900 MB release tarball (the download is cached); the rest of LLVM stays
# out of the build.
function Ensure-Clang {
    $version = V 'llvm'
    $dir = Join-Path $LIW_TOOLS 'llvm'
    $stamp = Join-Path $dir ".installed-$version"
    if (-not (Test-Path $stamp)) {
        Log "fetching LLVM $version (clang-cl)"
        $name = "clang+llvm-$version-x86_64-pc-windows-msvc.tar.xz"
        $tarball = Fetch "https://github.com/llvm/llvm-project/releases/download/llvmorg-$version/$name" $name
        if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        # The system bsdtar reads .tar.xz and takes member patterns; the
        # archive has one top-level directory.
        & tar.exe -xf $tarball -C $dir --strip-components 1 `
            '*/bin/clang-cl.exe' '*/bin/clang.exe' '*/lib/clang/*'
        Assert-Exit 'LLVM extraction'
        if (-not (Test-Path (Join-Path $dir 'bin\clang-cl.exe'))) { Die 'clang-cl.exe missing after the LLVM extraction' }
        New-Item -ItemType File -Force -Path $stamp | Out-Null
    }
    $script:ClangBin = Join-Path $dir 'bin'
    $out = Capture-Native (Join-Path $script:ClangBin 'clang-cl.exe') @('--version')
    if ($out -notmatch [regex]::Escape($version)) { Die "clang-cl does not report version ${version}: $out" }
    Log "clang-cl $version at $script:ClangBin"
}

# The rust toolchain, for the two rust libraries in the libvips tree
# (libimagequant, librsvg).  The linux and macos builds take rustup's
# current stable; here the pinned release's standalone component
# tarballs (rustc, cargo, rust-std for the MSVC target; each is
# <tarball>/<component>/{bin,lib,...}) are merged into one directory,
# which is all rustup's install does, and cargo-c -- the cargo cinstall
# both libraries build through -- is the prebuilt MSVC binary of its
# pinned release (linux and macos `cargo install` it).  rustc links with
# the MSVC link.exe that Enter-Msvc put on PATH; the crates.io cache lives
# under the build directory.  Like meson, rust is a build tool only: the
# wheels carry the DLLs it produces, audited like every other one.
function Ensure-Rust {
    $version = V 'rust'
    $cargoc = V 'cargo-c'
    $dir = Join-Path $LIW_TOOLS 'rust'
    $stamp = Join-Path $dir ".installed-$version-$cargoc"
    if (-not (Test-Path $stamp)) {
        Log "installing rust $version and cargo-c $cargoc"
        if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        foreach ($component in @('rustc', 'cargo', 'rust-std')) {
            $name = "$component-$version-x86_64-pc-windows-msvc.tar.xz"
            $tarball = Fetch "https://static.rust-lang.org/dist/$name" $name
            # (The system bsdtar reads .tar.xz; two leading components are
            # the tarball's and the component's directories.)
            & tar.exe -xf $tarball -C $dir --strip-components 2 --exclude 'manifest.in'
            Assert-Exit "extraction of $name"
        }
        $zip = Fetch "https://github.com/lu-zero/cargo-c/releases/download/v$cargoc/cargo-c-windows-msvc.zip" `
            "cargo-c-$cargoc-windows-msvc.zip"
        Expand-Zip $zip (Join-Path $LIW_DL 'cargo-c')
        Copy-Item (Join-Path $LIW_DL 'cargo-c\*.exe') (Join-Path $dir 'bin') -Force
        foreach ($exe in @('rustc.exe', 'cargo.exe', 'cargo-cinstall.exe', 'cargo-cbuild.exe')) {
            if (-not (Test-Path (Join-Path $dir "bin\$exe"))) { Die "$exe missing after the rust install" }
        }
        if (-not (Test-Path (Join-Path $dir 'lib\rustlib\x86_64-pc-windows-msvc\lib'))) {
            Die 'the rust standard library is missing after the rust install'
        }
        New-Item -ItemType File -Force -Path $stamp | Out-Null
    }
    $script:RustBin = Join-Path $dir 'bin'
    if (($env:PATH -split ';') -notcontains $script:RustBin) {
        $env:PATH = "$script:RustBin;$env:PATH"
    }
    $env:CARGO_HOME = Join-Path $LIW_BUILD 'cargo'
    $out = Capture-Native (Join-Path $script:RustBin 'rustc.exe') @('--version')
    if ($out -notmatch [regex]::Escape($version)) { Die "rustc does not report version ${version}: $out" }
    Log "rust $version and cargo-c $cargoc at $script:RustBin (CARGO_HOME $env:CARGO_HOME)"
}

# Build and install a meson project into the private prefix with the
# Dockerfile's flags (buildtype=release, optimization=3; MSVC: /O2, /MD).
# meson picks cl from the MSVC environment.  --wrap-mode=nofallback: a
# dependency that pkg-config cannot satisfy fails the configure step
# instead of being replaced by the project's own subproject wrap -- cairo
# built and installed its own libpng over ours that way when our libpng
# had no .pc file.  The wraps the linux and macos builds also rely on
# (glib's pcre2/libffi/intl, openslide's libdicom) are forced explicitly
# with --force-fallback-for by their builders.
function Meson-Build([string]$Src, [string[]]$MesonArgs = @()) {
    $build = Join-Path $Src '_build'
    if (Test-Path $build) { Remove-Item -Recurse -Force $build }
    Run-Logged 'meson' (@('setup', $build, $Src, "--prefix=$script:CmakePrefix",
        '--buildtype=release', '-Doptimization=3', '--libdir=lib',
        '--wrap-mode=nofallback') + $MesonArgs) "meson setup in $Src"
    Run-Logged 'meson' @('compile', '-C', $build, '-j', "$LIW_JOBS") "meson compile in $Src"
    Run-Logged 'meson' @('install', '-C', $build, '--no-rebuild') "meson install in $Src"
}

function Set-BuildPath {
    # Only system dirs, the private prefix, and the recorded tool paths are
    # on PATH.  Nothing else in the sandbox can supply headers, link
    # targets, or DLLs.  This is the windows analog of the macos PATH scrub.
    $base = @(
        'C:\Windows\System32',
        'C:\Windows',
        'C:\Windows\System32\Wbem',
        'C:\Windows\System32\WindowsPowerShell\v1.0'
    )
    $env:PATH = (@($base) + $script:ToolPaths + @("$LIW_PREFIX\bin")) -join ';'
}

function Enter-Msvc {
    # Bring the MSVC toolset into this session (INCLUDE, LIB, PATH for cl,
    # link, dumpbin, rc, mt) for the x64 target, from the environment
    # install_msvc.py wrote (the equivalent of vcvars64 / Enter-VsDevShell).
    $info = Get-Content $script:MsvcEnvJson -Raw | ConvertFrom-Json
    foreach ($prop in $info.env.PSObject.Properties) {
        Set-Item -Path "env:$($prop.Name)" -Value $prop.Value
    }
    $env:PATH = (@($env:PATH -split ';') + @($info.paths)) -join ';'
    # The private prefix supplies our libraries; put it ahead of the SDK in
    # the search path for both the compiler and the linker.
    $env:INCLUDE = "$LIW_PREFIX\include;$env:INCLUDE"
    $env:LIB = "$LIW_PREFIX\lib;$env:LIB"
    # (No `cl 2>&1` probe here: cl prints its banner to stderr, and a
    # redirected native stderr is a terminating error under
    # ErrorActionPreference Stop in Windows PowerShell 5.1.)
    if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
        Die 'cl.exe is not on PATH after Enter-Msvc'
    }
}

# --------------------------------------------------------------------------
# Dependencies (mirroring the Dockerfile's build order and flags).
# --------------------------------------------------------------------------

# zlib.  The linux build uses zlib-ng; macos uses vanilla zlib because of a
# macos-specific issue, and windows follows macos here (recorded in the
# README as a decision to confirm once the linux reason is rechecked).
function Build-Zlib {
    if (Skip-If-Done 'zlib') { return }
    Log '=== zlib'
    $src = Git-Clone 'https://github.com/madler/zlib.git' "v$(V zlib)" `
        (Join-Path $LIW_SRC 'zlib')
    # zlib 1.3.2's cmake names the Windows DLL z.dll (OUTPUT_NAME z; the
    # zlib1.dll name of the old win32/Makefile.msc days is gone) and the
    # static library zs.lib; the static build is turned off so no consumer
    # can pick the static library over the DLL.
    Cmake-Build $src @('-DZLIB_BUILD_TESTING=OFF', '-DZLIB_BUILD_STATIC=OFF')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('z.dll') 'zlib'
    Done-Stamp 'zlib'
}

# bzip2: the linux base image and macos have a system one, which
# ImageMagick, libarchive and freetype pick up there; Windows has none, so
# it is built from the release tarball (seven source files; its own
# makefile.msc builds only a static library).  The DLL's exports come from
# the tarball's libbz2.def minus its LIBRARY line, which would otherwise
# record LIBBZ2.dll as the DLL name in the import library.  The import
# library is bz2.lib, the name cmake's FindBZip2 (freetype, libarchive)
# looks for.
$script:Bzip2CMakeLists = @'
cmake_minimum_required(VERSION 3.16)
project(bzip2 C)
if(NOT BZIP2_VERSION)
  message(FATAL_ERROR "pass -DBZIP2_VERSION=<version>")
endif()
file(STRINGS ${CMAKE_SOURCE_DIR}/libbz2.def DEF_LINES)
set(DEF "EXPORTS\n")
foreach(line ${DEF_LINES})
  string(STRIP "${line}" sym)
  if(sym MATCHES "^BZ2_")
    string(APPEND DEF "${sym}\n")
  endif()
endforeach()
file(WRITE ${CMAKE_BINARY_DIR}/bz2.def "${DEF}")
add_library(bz2 SHARED blocksort.c huffman.c crctable.c randtable.c
  compress.c decompress.c bzlib.c ${CMAKE_BINARY_DIR}/bz2.def)
target_compile_definitions(bz2 PRIVATE _CRT_SECURE_NO_WARNINGS)
install(TARGETS bz2
  RUNTIME DESTINATION bin LIBRARY DESTINATION lib ARCHIVE DESTINATION lib)
install(FILES bzlib.h DESTINATION include)
file(WRITE ${CMAKE_BINARY_DIR}/bzip2.pc
"prefix=${CMAKE_INSTALL_PREFIX}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: bzip2
Description: bzip2 compression library
Version: ${BZIP2_VERSION}
Libs: -L\${libdir} -lbz2
Cflags: -I\${includedir}
")
install(FILES ${CMAKE_BINARY_DIR}/bzip2.pc DESTINATION lib/pkgconfig)
'@

function Build-Bzip2 {
    if (Skip-If-Done 'bzip2') { return }
    Log '=== bzip2'
    $src = Fetch-Tarball "https://sourceware.org/pub/bzip2/bzip2-$(V bzip2).tar.gz" `
        'bzip2.tar.gz' (Join-Path $LIW_SRC 'bzip2')
    Write-Embedded (Join-Path $src 'CMakeLists.txt') $script:Bzip2CMakeLists
    Cmake-Build $src @("-DBZIP2_VERSION=$(V bzip2)")
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('bz2.dll') 'bzip2'
    Assert-Files (Join-Path $LIW_PREFIX 'lib') @('bz2.lib') 'bzip2'
    Assert-Files (Join-Path $LIW_PREFIX 'lib\pkgconfig') @('bzip2.pc') 'bzip2'
    Done-Stamp 'bzip2'
}

# libzip, for ImageMagick's ora coder (the linux image installs it early;
# nothing else in the tree uses it).  Its cmake finds zlib, bzip2, lzma and
# zstd in the prefix; encryption through Windows' own crypto API, as its
# Windows default.  No tools, tests or docs.
function Build-Libzip {
    if (Skip-If-Done 'libzip') { return }
    Log '=== libzip'
    $src = Git-Clone 'https://github.com/nih-at/libzip.git' "v$(V libzip)" (Join-Path $LIW_SRC 'libzip')
    Cmake-Build $src @('-DBUILD_TOOLS=OFF', '-DBUILD_REGRESS=OFF', '-DBUILD_EXAMPLES=OFF',
        '-DBUILD_DOC=OFF', '-DBUILD_OSSFUZZ=OFF', '-DENABLE_OPENSSL=OFF', '-DENABLE_GNUTLS=OFF',
        '-DENABLE_MBEDTLS=OFF', '-DENABLE_WINDOWS_CRYPTO=ON', '-DENABLE_BZIP2=ON', '-DENABLE_LZMA=ON',
        '-DENABLE_ZSTD=ON')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('zip.dll') 'libzip'
    Assert-Files (Join-Path $LIW_PREFIX 'lib\pkgconfig') @('libzip.pc') 'libzip'
    Assert-DependentStems (Join-Path $LIW_PREFIX 'bin\zip.dll') @('z.dll', 'bz2', 'liblzma', 'zstd') 'libzip'
    Done-Stamp 'libzip'
}

function Build-Zstd {
    if (Skip-If-Done 'zstd') { return }
    Log '=== zstd'
    $src = Git-Clone 'https://github.com/facebook/zstd' "v$(V zstd)" `
        (Join-Path $LIW_SRC 'zstd')
    Cmake-Build (Join-Path $src 'build\cmake') @(
        '-DBUILD_SHARED_LIBS=ON', '-DZSTD_BUILD_STATIC=OFF',
        '-DZSTD_BUILD_PROGRAMS=OFF', '-DZSTD_BUILD_TESTS=OFF')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('zstd.dll') 'zstd'
    Done-Stamp 'zstd'
}

# jbig is only needed as a static library (libtiff links it in; there is
# then no DLL to bundle).  jbigkit has no build system that works with
# MSVC, so compile its two translation units directly.
function Build-Jbigkit {
    if (Skip-If-Done 'jbigkit') { return }
    Log '=== jbigkit'
    $src = Fetch-Tarball `
        "https://www.cl.cam.ac.uk/~mgk25/jbigkit/download/jbigkit-$(V jbigkit).tar.gz" `
        'jbigkit.tar.gz' (Join-Path $LIW_SRC 'jbigkit')
    $libjbig = Join-Path $src 'libjbig'
    Push-Location $libjbig
    try {
        & cl /nologo /c /O2 /MD jbig.c jbig_ar.c
        Assert-Exit 'jbigkit compile failed'
        & lib /nologo /OUT:libjbig.lib jbig.obj jbig_ar.obj
        Assert-Exit 'jbigkit archive failed'
    } finally {
        Pop-Location
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $LIW_PREFIX 'lib'),
                                              (Join-Path $LIW_PREFIX 'include') | Out-Null
    Copy-Item (Join-Path $libjbig 'libjbig.lib') (Join-Path $LIW_PREFIX 'lib') -Force
    Copy-Item (Join-Path $libjbig 'jbig.h') (Join-Path $LIW_PREFIX 'include') -Force
    Copy-Item (Join-Path $libjbig 'jbig_ar.h') (Join-Path $LIW_PREFIX 'include') -Force
    Done-Stamp 'jbigkit'
}

# The linux build configures libwebp with --enable-libwebpmux
# --enable-libwebpdecoder --enable-libwebpextras; the cmake equivalent
# builds the mux and decoder DLLs.  Extras are off: they only affect the
# webp command-line tools and the extras API, neither of which any wheel
# bundles (same reasoning as the macos note on libwebp built before
# libpng).
function Build-Libwebp {
    if (Skip-If-Done 'libwebp') { return }
    Log '=== libwebp'
    $src = Fetch-Tarball `
        "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$(V libwebp).tar.gz" `
        'libwebp.tar.gz' (Join-Path $LIW_SRC 'libwebp')
    # libwebp's cmake builds static libraries unless BUILD_SHARED_LIBS is
    # on (the first dev run installed only libwebp.lib archives).
    Cmake-Build $src @(
        '-DBUILD_SHARED_LIBS=ON',
        '-DWEBP_BUILD_CWEBP=OFF', '-DWEBP_BUILD_DWEBP=OFF',
        '-DWEBP_BUILD_GIF2WEBP=OFF', '-DWEBP_BUILD_IMG2WEBP=OFF',
        '-DWEBP_BUILD_VWEBP=OFF', '-DWEBP_BUILD_WEBPINFO=OFF',
        '-DWEBP_BUILD_WEBPMUX=OFF', '-DWEBP_BUILD_ANIM_UTILS=OFF',
        '-DWEBP_BUILD_EXTRAS=OFF',
        '-DWEBP_BUILD_LIBWEBPMUX=ON', '-DWEBP_BUILD_LIBWEBPDECODER=ON')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @(
        'libwebp.dll', 'libwebpmux.dll', 'libwebpdecoder.dll',
        'libsharpyuv.dll') 'libwebp'
    Done-Stamp 'libwebp'
}

function Build-Libjpeg-Turbo {
    if (Skip-If-Done 'libjpeg-turbo') { return }
    Log '=== libjpeg-turbo'
    $src = Git-Clone 'https://github.com/libjpeg-turbo/libjpeg-turbo.git' `
        "$(V libjpeg-turbo)" (Join-Path $LIW_SRC 'libjpeg-turbo')
    Cmake-Build $src @('-DENABLE_STATIC=OFF')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @(
        'jpeg*.dll', 'cjpeg.exe', 'djpeg.exe', 'jpegtran.exe',
        'rdjpgcom.exe', 'wrjpgcom.exe') 'libjpeg-turbo'
    Done-Stamp 'libjpeg-turbo'
}

function Build-Libdeflate {
    if (Skip-If-Done 'libdeflate') { return }
    Log '=== libdeflate'
    $src = Git-Clone 'https://github.com/ebiggers/libdeflate.git' `
        "v$(V libdeflate)" (Join-Path $LIW_SRC 'libdeflate')
    Cmake-Build $src @('-DLIBDEFLATE_BUILD_STATIC_LIB=OFF')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('deflate.dll') 'libdeflate'
    Done-Stamp 'libdeflate'
}

function Build-Xz {
    if (Skip-If-Done 'xz') { return }
    Log '=== xz'
    $src = Git-Clone 'https://github.com/tukaani-project/xz.git' "v$(V xz)" `
        (Join-Path $LIW_SRC 'xz')
    Cmake-Build $src @(
        '-DBUILD_SHARED_LIBS=ON', '-DBUILD_TESTING=OFF', '-DENABLE_NLS=OFF')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('liblzma.dll') 'xz'
    Done-Stamp 'xz'
}

function Build-Libtiff {
    if (Skip-If-Done 'libtiff') { return }
    Log '=== libtiff'
    $src = Git-Clone 'https://gitlab.com/libtiff/libtiff.git' "v$(V libtiff)" `
        (Join-Path $LIW_SRC 'libtiff')
    # jbig has no cmake find module that understands libjbig.lib's layout,
    # so hand it the paths explicitly; the option spellings for deflate are
    # not certain, so pass both plausible names and let the tiffconf.h
    # assertion (below) catch a silent feature drop.
    # Paths handed to cmake as cache variables must use forward slashes:
    # a backslashed JBIG_LIBRARY reached libtiff's check_symbol_exists
    # try_compile as a string with escape sequences and broke configure.
    Cmake-Build $src @(
        '-Dzlib=ON', '-Djpeg=ON', '-Djbig=ON', '-Dzstd=ON', '-Dwebp=ON',
        '-Ddeflate=ON', '-Dlibdeflate=ON',
        "-DJBIG_LIBRARY=$script:CmakePrefix/lib/libjbig.lib",
        "-DJBIG_INCLUDE_DIR=$script:CmakePrefix/include")
    # Feature assertions: the linux wheels' libtiff links zlib, jpeg, zstd,
    # webp, and libdeflate, and statically embeds jbig.  A missing optional
    # dependency at configure time would otherwise silently reduce the
    # feature set.
    $tiffconf = Join-Path $LIW_PREFIX 'include\tiffconf.h'
    if (-not (Test-Path $tiffconf)) {
        Die "libtiff: tiffconf.h not found at $tiffconf"
    }
    # tiffconf.h records some features as "#define X 1" and others as a
    # bare "#define X" (JBIG); ZSTD/WEBP are only in the internal
    # tif_config.h, so those two are asserted through the DLL imports
    # below instead.
    $conf = Get-Content $tiffconf -Raw
    foreach ($feature in @('ZIP_SUPPORT', 'JPEG_SUPPORT', 'JBIG_SUPPORT',
                           'LIBDEFLATE_SUPPORT')) {
        if ($conf -notmatch "(?m)^#define\s+$feature\b") {
            Die ("libtiff: $feature is not enabled in tiffconf.h (an " +
                'optional dependency was not found at configure time)')
        }
    }
    $tiffDll = Get-ChildItem -Path (Join-Path $LIW_PREFIX 'bin') `
        -Filter '*tiff*.dll' -File | Select-Object -First 1
    if (-not $tiffDll) { Die 'libtiff: no tiff DLL in the prefix' }
    Log "libtiff DLL $($tiffDll.Name) depends on: $((Get-Dependents $tiffDll.FullName) -join ', ')"
    Log "prefix DLLs: $((Get-ChildItem -Path (Join-Path $LIW_PREFIX 'bin') -Filter '*.dll' | ForEach-Object { $_.Name }) -join ', ')"
    # DLL names as the chain's cmake builds produce them on Windows
    # (observed, not assumed): z.dll, zstd.dll, jpeg62.dll, libwebp.dll,
    # deflate.dll, liblzma.dll.
    Assert-Dependents $tiffDll.FullName @(
        'jpeg62.dll', 'z.dll', 'zstd.dll', 'libwebp.dll',
        'deflate.dll') 'libtiff'
    Done-Stamp 'libtiff'
}

# lcms2 (openjpeg's opj tools link it).  The linux build uses autotools;
# lcms2 ships a cmake build since 2.17 that produces the same DLL.  The
# tools (jpgicc, tificc) are not bundled by any wheel, so they are off.
function Build-Lcms2 {
    if (Skip-If-Done 'lcms2') { return }
    Log '=== lcms2'
    $src = Git-Clone 'https://github.com/mm2/Little-CMS.git' "lcms$(V lcms2)" `
        (Join-Path $LIW_SRC 'lcms2')
    Cmake-Build $src @(
        '-DLCMS2_BUILD_SHARED=ON', '-DLCMS2_BUILD_STATIC=OFF',
        '-DLCMS2_BUILD_TOOLS=OFF', '-DLCMS2_BUILD_TESTS=OFF',
        '-DLCMS2_BUILD_JPGICC=OFF', '-DLCMS2_BUILD_TIFICC=OFF',
        '-DLCMS2_BUILD_TIFDIFF=OFF')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('lcms2.dll') 'lcms2'
    Done-Stamp 'lcms2'
}

function Build-Libpng {
    if (Skip-If-Done 'libpng') { return }
    Log '=== libpng'
    $src = Git-Clone 'https://github.com/glennrp/libpng.git' "v$(V libpng)" `
        (Join-Path $LIW_SRC 'libpng')
    Cmake-Build $src @(
        '-DPNG_SHARED=ON', '-DPNG_STATIC=OFF', '-DPNG_TESTS=OFF',
        '-DPNG_TOOLS=OFF')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('libpng16.dll') 'libpng'
    # libpng's cmake installs its pkg-config files only off Windows.
    foreach ($name in @('libpng16', 'libpng')) {
        Write-PkgConfig $name 'Loads and saves PNG files' (V libpng) '-lpng16' `
            '-I${includedir}' '${prefix}/include/libpng16' 'zlib'
    }
    # The .pc's -lpng16 names png16.lib under MSVC; cmake installed
    # libpng16.lib.  meson looks for both spellings, rustc (librsvg's
    # rsvg-convert, through the system-deps crate) only for the literal
    # one, so the second name is provided.
    Copy-Item (Join-Path $LIW_PREFIX 'lib\libpng16.lib') (Join-Path $LIW_PREFIX 'lib\png16.lib') -Force
    Done-Stamp 'libpng'
}

# openjpeg is needed by glymur (its opj_* tools are bundled into the wheel)
# and later by gdal/openslide/mapnik.  The linux Dockerfile builds it twice
# (before and after libtiff); building it once after zlib, libpng, lcms2,
# and libtiff gives the same final state (as the macos build does).  2.5.x
# names its options BUILD_SHARED_LIBS/BUILD_STATIC_LIBS; BUILD_THIRDPARTY
# stays off so the tools link our libraries, not vendored copies.
function Build-Openjpeg {
    if (Skip-If-Done 'openjpeg') { return }
    Log '=== openjpeg'
    $src = Fetch-Tarball `
        "https://github.com/uclouvain/openjpeg/archive/v$(V openjpeg).tar.gz" `
        'openjpeg.tar.gz' (Join-Path $LIW_SRC 'openjpeg')
    Cmake-Build $src @(
        '-DBUILD_SHARED_LIBS=ON', '-DBUILD_STATIC_LIBS=OFF', '-DBUILD_CODEC=ON',
        '-DBUILD_THIRDPARTY=OFF', '-DBUILD_TESTING=OFF', '-DBUILD_DOC=OFF')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @(
        'openjp2.dll', 'opj_compress.exe', 'opj_decompress.exe', 'opj_dump.exe') 'openjpeg'
    # Feature assertions: the linux wheels' opj tools link lcms2, libpng,
    # and libtiff; a missing optional dependency at configure time would
    # silently reduce the tools' feature set.
    $decompress = Join-Path $LIW_PREFIX 'bin\opj_decompress.exe'
    Log "opj_decompress depends on: $((Get-Dependents $decompress) -join ', ')"
    Assert-Dependents $decompress @('tiff.dll', 'libpng16.dll', 'lcms2.dll') 'openjpeg'
    Done-Stamp 'openjpeg'
}

# --- the openslide chain (glib, cairo and their dependencies; also used by
# libvips, gdal and mapnik later) ---

function Build-Libbrotli {
    if (Skip-If-Done 'libbrotli') { return }
    Log '=== libbrotli'
    $src = Git-Clone 'https://github.com/google/brotli.git' "v$(V libbrotli)" `
        (Join-Path $LIW_SRC 'brotli')
    Cmake-Build $src @('-DBUILD_TESTING=OFF', '-DBUILD_SHARED_LIBS=ON')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('brotlidec.dll', 'brotlienc.dll') 'libbrotli'
    Done-Stamp 'libbrotli'
}

function Build-Libexpat {
    if (Skip-If-Done 'libexpat') { return }
    Log '=== libexpat'
    $src = Fetch-Tarball "https://github.com/libexpat/libexpat/archive/R_$(V libexpat).tar.gz" `
        'libexpat.tar.gz' (Join-Path $LIW_SRC 'libexpat')
    Cmake-Build (Join-Path $src 'expat') @(
        '-DEXPAT_BUILD_EXAMPLES=OFF', '-DEXPAT_BUILD_TESTS=OFF',
        '-DEXPAT_BUILD_TOOLS=OFF', '-DEXPAT_SHARED_LIBS=ON')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('libexpat.dll') 'libexpat'
    # expat's cmake installs its pkg-config file only off Windows.
    if (-not (Test-Path (Join-Path $LIW_PREFIX 'lib\pkgconfig\expat.pc'))) {
        Write-PkgConfig 'expat' 'expat XML parser' ((V libexpat) -replace '_', '.') '-llibexpat'
    }
    Done-Stamp 'libexpat'
}

# glib builds pcre2 and libffi from its own subproject wraps, statically
# into its DLLs (the macos build does the same for pcre2); the linux
# build's util-linux (libmount) and gettext have no Windows counterpart,
# and nls is off like on macos.
function Build-Glib {
    if (Skip-If-Done 'glib') { return }
    Log '=== glib'
    $src = Git-Clone 'https://github.com/GNOME/glib.git' "$(V glib)" (Join-Path $LIW_SRC 'glib')
    Meson-Build $src @(
        '-Dtests=false', '-Dglib_debug=disabled', '-Dintrospection=disabled',
        '-Dnls=disabled', '-Dlibmount=disabled', '-Dselinux=disabled',
        '-Dxattr=false', '-Dman-pages=disabled', '-Ddocumentation=false',
        '-Dsysprof=disabled',
        '--force-fallback-for=libpcre2-8,libffi,proxy-libintl')
    # The pcre2 wrap is glib's private static copy, but its install step
    # also drops pcre2.h, static archives and .pc files into the prefix,
    # which a later consumer then finds (GDAL's sqlite REGEXP support
    # did, and failed to link: the header declares dllimport without
    # PCRE2_STATIC).  Nothing else may link it, so the leak is removed.
    foreach ($leak in @('bin\pcre2grep.exe', 'bin\pcre2test.exe', 'include\pcre2.h', 'include\pcre2posix.h')) {
        Remove-Item -Path (Join-Path $LIW_PREFIX $leak) -Force -ErrorAction SilentlyContinue
    }
    Get-ChildItem -Path (Join-Path $LIW_PREFIX 'lib') -Filter 'libpcre2-*' -File | Remove-Item -Force
    Get-ChildItem -Path (Join-Path $LIW_PREFIX 'lib\pkgconfig') -Filter 'libpcre2-*.pc' -File | Remove-Item -Force
    Log "prefix DLLs: $((Get-ChildItem -Path (Join-Path $LIW_PREFIX 'bin') -Filter '*.dll' | ForEach-Object { $_.Name }) -join ', ')"
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @(
        'glib-2.0*.dll', 'gobject-2.0*.dll', 'gio-2.0*.dll', 'gmodule-2.0*.dll') 'glib'
    Done-Stamp 'glib'
}

# sqlite: the amalgamation compiled with cl into sqlite3.dll (the linux
# and macos builds run its configure --all; the feature defines below are
# that set).  sqlite installs no pkg-config file on Windows, so one is
# written for the consumers that look for sqlite3 through pkg-config.
function Build-Sqlite {
    if (Skip-If-Done 'sqlite') { return }
    Log '=== sqlite'
    $year = V 'sqlite' @('1')
    $release = V 'sqlite' @('2', '.', '.', '1')
    $src = Fetch-Tarball "https://sqlite.org/$year/sqlite-autoconf-$release.tar.gz" `
        'sqlite.tar.gz' (Join-Path $LIW_SRC 'sqlite')
    Push-Location $src
    try {
        Run-Logged 'cl' @('/nologo', '/O2', '/MD', '/DSQLITE_API=__declspec(dllexport)',
            '/DSQLITE_THREADSAFE=1', '/DSQLITE_ENABLE_FTS3', '/DSQLITE_ENABLE_FTS4',
            '/DSQLITE_ENABLE_FTS5', '/DSQLITE_ENABLE_RTREE', '/DSQLITE_ENABLE_GEOPOLY',
            '/DSQLITE_ENABLE_JSON1', '/DSQLITE_ENABLE_COLUMN_METADATA',
            '/DSQLITE_ENABLE_SESSION', '/DSQLITE_ENABLE_PREUPDATE_HOOK',
            '/DSQLITE_ENABLE_MATH_FUNCTIONS', '/DSQLITE_ENABLE_DBSTAT_VTAB',
            '/DSQLITE_ENABLE_STMTVTAB', 'sqlite3.c',
            '/link', '/DLL', '/OUT:sqlite3.dll', '/IMPLIB:sqlite3.lib') 'sqlite compile'
    } finally {
        Pop-Location
    }
    # The shell too (PROJ's cmake runs sqlite3.exe to generate proj.db;
    # the linux autoconf build installs it alongside).
    Push-Location $src
    try {
        Run-Logged 'cl' @('/nologo', '/O2', '/MD', 'shell.c', 'sqlite3.lib',
            '/Fe:sqlite3.exe') 'sqlite shell compile'
    } finally {
        Pop-Location
    }
    # (The directories first: on a fresh prefix a Copy-Item to a missing
    # "lib" writes a file of that name.)
    foreach ($sub in @('bin', 'lib', 'include')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $LIW_PREFIX $sub) | Out-Null
    }
    Copy-Item (Join-Path $src 'sqlite3.dll') (Join-Path $LIW_PREFIX 'bin') -Force
    Copy-Item (Join-Path $src 'sqlite3.exe') (Join-Path $LIW_PREFIX 'bin') -Force
    Copy-Item (Join-Path $src 'sqlite3.lib') (Join-Path $LIW_PREFIX 'lib') -Force
    Copy-Item (Join-Path $src 'sqlite3.h'), (Join-Path $src 'sqlite3ext.h') `
        (Join-Path $LIW_PREFIX 'include') -Force
    # 3540100 -> 3.54.1
    $digits = $release
    $version = "$([int]$digits.Substring(0, 1)).$([int]$digits.Substring(1, 2)).$([int]$digits.Substring(3, 2))"
    Write-PkgConfig 'sqlite3' 'SQL database engine' $version '-lsqlite3'
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('sqlite3.dll') 'sqlite'
    Done-Stamp 'sqlite'
}

# libxml2 without iconv: Windows has no system iconv (the linux and macos
# builds use theirs), and libxml2 handles UTF-8/16 and ISO-8859-x itself.
# Legacy APIs stay on like on linux (rasterlite).
function Build-Libxml2 {
    if (Skip-If-Done 'libxml2') { return }
    Log '=== libxml2'
    $src = Git-Clone 'https://github.com/GNOME/libxml2.git' "v$(V libxml2)" (Join-Path $LIW_SRC 'libxml2')
    Cmake-Build $src @(
        '-DLIBXML2_WITH_TESTS=OFF', '-DLIBXML2_WITH_PYTHON=OFF', '-DLIBXML2_WITH_ICU=OFF',
        '-DLIBXML2_WITH_ICONV=OFF', '-DLIBXML2_WITH_ISO8859X=ON', '-DLIBXML2_WITH_LEGACY=ON',
        '-DLIBXML2_WITH_HTTP=ON', '-DLIBXML2_WITH_DEBUG=OFF', '-DLIBXML2_WITH_PROGRAMS=OFF',
        '-DLIBXML2_WITH_ZLIB=ON', '-DLIBXML2_WITH_LZMA=ON')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('libxml2*.dll') 'libxml2'
    # libxml-2.0.pc says -lxml2; the import library installs as libxml2.lib.
    # rustc takes the .pc's spelling literally (see Build-Libpng).
    Copy-Item (Join-Path $LIW_PREFIX 'lib\libxml2.lib') (Join-Path $LIW_PREFIX 'lib\xml2.lib') -Force
    Done-Stamp 'libxml2'
}

function Build-Pixman {
    if (Skip-If-Done 'pixman') { return }
    Log '=== pixman'
    $src = Git-Clone 'https://gitlab.freedesktop.org/pixman/pixman.git' "pixman-$(V pixman)" `
        (Join-Path $LIW_SRC 'pixman')
    Meson-Build $src @('-Dtests=disabled', '-Ddemos=disabled', '-Dgtk=disabled')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('pixman-1*.dll') 'pixman'
    Done-Stamp 'pixman'
}

function Build-Freetype {
    if (Skip-If-Done 'freetype') { return }
    Log '=== freetype'
    $src = Git-Clone 'https://github.com/freetype/freetype.git' "VER-$(V freetype)" `
        (Join-Path $LIW_SRC 'freetype')
    # The linux wheel's freetype has zlib, png and brotli (WOFF2); harfbuzz
    # is off here as there (it would be a circular dependency).
    Meson-Build $src @('-Dzlib=enabled', '-Dpng=enabled', '-Dbrotli=enabled',
        '-Dbzip2=disabled', '-Dharfbuzz=disabled', '-Dtests=disabled')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('freetype*.dll') 'freetype'
    Done-Stamp 'freetype'
}

function Build-Fontconfig {
    if (Skip-If-Done 'fontconfig') { return }
    Log '=== fontconfig'
    $src = Git-Clone 'https://gitlab.freedesktop.org/fontconfig/fontconfig.git' "$(V fontconfig)" `
        (Join-Path $LIW_SRC 'fontconfig')
    # nls and the install-time cache build are off (as on macos: the cache
    # build floods the log and depends on the build machine's fonts).
    Meson-Build $src @('-Ddoc=disabled', '-Dtests=disabled', '-Dnls=disabled',
        '-Dcache-build=disabled', '-Dtools=disabled')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('fontconfig*.dll') 'fontconfig'
    Done-Stamp 'fontconfig'
}

function Build-Cairo {
    if (Skip-If-Done 'cairo') { return }
    Log '=== cairo'
    $src = Git-Clone 'https://gitlab.freedesktop.org/cairo/cairo.git' "$(V cairo)" `
        (Join-Path $LIW_SRC 'cairo')
    # freetype and fontconfig are required explicitly for parity with the
    # linux wheel's cairo (as on macos); the win32 backends are extra.
    Meson-Build $src @('-Dtests=disabled', '-Dfreetype=enabled', '-Dfontconfig=enabled')
    $cairoDll = Get-ChildItem -Path (Join-Path $LIW_PREFIX 'bin') -Filter 'cairo*.dll' -File |
        Where-Object { $_.Name -notmatch 'gobject|script' } | Select-Object -First 1
    if (-not $cairoDll) { Die 'cairo: no cairo DLL in the prefix' }
    Log "cairo DLL $($cairoDll.Name) depends on: $((Get-Dependents $cairoDll.FullName) -join ', ')"
    $deps = Get-Dependents $cairoDll.FullName
    foreach ($stem in @('freetype', 'fontconfig', 'pixman', 'libpng16', 'z.dll')) {
        if (-not ($deps | Where-Object { $_ -like "$stem*" })) {
            Die "cairo was not linked against $stem; an optional dependency was missed (check the build order)"
        }
    }
    Done-Stamp 'cairo'
}

# A cmake build for jxrlib (JPEG XR; the 4creators fork the linux and
# macos builds use), written into the source tree as CMakeLists.txt.
# jxrlib's own build is a GNU Makefile (the linux build runs it; macos
# patches it), and the Visual Studio project files it ships predate the
# toolset in use; this builds the same two shared libraries from the same
# source lists as the Makefile (SRC_SYS/SRC_DEC/SRC_ENC -> jpegxr,
# SRC_GLUE -> jxrglue), with the Makefile's defines, installs the headers
# in the Makefile's layout, and writes the same libjxr.pc, so openslide's
# zeiss-czi-jxr patch finds the library through pkg-config exactly as on
# linux.
#
# The sources carry no export declarations; WINDOWS_EXPORT_ALL_SYMBOLS
# gives the DLLs the export table the ELF/Mach-O builds have implicitly.
$script:JxrlibCMakeLists = @'
cmake_minimum_required(VERSION 3.16)
project(jxrlib C)

set(JXR_VERSION 1.1)
add_compile_definitions(__ANSI__ DISABLE_PERF_MEASUREMENT _CRT_SECURE_NO_WARNINGS)
# image/sys/ansi.h sizes its pointer-width integers by __LP64__, which
# MSVC never defines; without it the 64-bit build fails its own
# compile-time assertion (strcodec.h: sizeof(UINTPTR_T) == sizeof(void*)).
# Consumers compile the same headers, so the define goes into libjxr.pc
# as well.
set(JXR_EXTRA_CFLAGS "")
if(CMAKE_SIZEOF_VOID_P EQUAL 8)
  add_compile_definitions(__LP64__=1)
  set(JXR_EXTRA_CFLAGS " -D__LP64__=1")
endif()
# The Makefile compiles with -w; the code is old and noisy.
if(MSVC)
  string(APPEND CMAKE_C_FLAGS " /w")
endif()
include_directories(common/include image/sys jxrgluelib jxrtestlib)

# JXRMeta.h uses __in_win/__out_win, which it knows only through its own
# wmsal.h -- and wmspecstring.h skips wmsal.h once MSVC's specstrings.h
# (via windows.h) has been included, as it is in openslide's sources.
# Define them from sal.h's __in/__out when they are missing (the header
# does that already under WIN32, which would also select the non-ANSI
# platform code).  Patched in the source so the installed header carries
# it; the file may have either line ending.
# JXRGlue.h declares the two IID_PKImageWmp* constants as plain extern
# data.  WINDOWS_EXPORT_ALL_SYMBOLS skips read-only data, so the library
# build exports them explicitly (JXR_DLL_EXPORT, defined for jxrglue
# below; the declaration's dllexport carries over to the definition in
# JXRGlue.c), and a consumer of jxrglue.dll can only link data through a
# dllimport declaration (MSVC thunks functions, not data), which
# JXR_DLL_IMPORT adds -- only libjxr.pc's Cflags define that.
file(READ "${CMAKE_SOURCE_DIR}/jxrgluelib/JXRGlue.h" _jxr_glue)
string(REPLACE "EXTERN_C const PKIID IID_PKImageWmpEncode;"
  "#if defined(_WIN32) && defined(JXR_DLL_EXPORT)
#define JXR_DATA __declspec(dllexport)
#elif defined(_WIN32) && defined(JXR_DLL_IMPORT)
#define JXR_DATA __declspec(dllimport)
#else
#define JXR_DATA
#endif
EXTERN_C JXR_DATA const PKIID IID_PKImageWmpEncode;" _jxr_glue "${_jxr_glue}")
string(REPLACE "EXTERN_C const PKIID IID_PKImageWmpDecode;"
  "EXTERN_C JXR_DATA const PKIID IID_PKImageWmpDecode;" _jxr_glue "${_jxr_glue}")
file(WRITE "${CMAKE_SOURCE_DIR}/jxrgluelib/JXRGlue.h" "${_jxr_glue}")

file(READ "${CMAKE_SOURCE_DIR}/jxrgluelib/JXRMeta.h" _jxr_meta)
string(REGEX REPLACE "#ifdef WIN32(\r?\n)#define __in_win"
  "#if defined(WIN32) || !defined(__in_win)\\1#define __in_win" _jxr_meta "${_jxr_meta}")
file(WRITE "${CMAKE_SOURCE_DIR}/jxrgluelib/JXRMeta.h" "${_jxr_meta}")

set(SRC_SYS adapthuff.c image.c strcodec.c strPredQuant.c strTransform.c perfTimerANSI.c)
list(TRANSFORM SRC_SYS PREPEND image/sys/)
set(SRC_DEC decode.c postprocess.c segdec.c strdec.c strInvTransform.c strPredQuantDec.c JXRTranscode.c)
list(TRANSFORM SRC_DEC PREPEND image/decode/)
set(SRC_ENC encode.c segenc.c strenc.c strFwdTransform.c strPredQuantEnc.c)
list(TRANSFORM SRC_ENC PREPEND image/encode/)
set(SRC_GLUE JXRGlue.c JXRMeta.c JXRGluePFC.c JXRGlueJxr.c)
list(TRANSFORM SRC_GLUE PREPEND jxrgluelib/)

add_library(jpegxr SHARED ${SRC_SYS} ${SRC_DEC} ${SRC_ENC})
set_target_properties(jpegxr PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)
add_library(jxrglue SHARED ${SRC_GLUE})
set_target_properties(jxrglue PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)
target_compile_definitions(jxrglue PRIVATE JXR_DLL_EXPORT)
target_link_libraries(jxrglue PRIVATE jpegxr)

install(TARGETS jpegxr jxrglue
  RUNTIME DESTINATION bin LIBRARY DESTINATION lib ARCHIVE DESTINATION lib)
install(DIRECTORY common/include/ DESTINATION include/libjxr/common FILES_MATCHING PATTERN "*.h")
install(DIRECTORY image/x86/ DESTINATION include/libjxr/image/x86 FILES_MATCHING PATTERN "*.h")
install(DIRECTORY image/sys/ image/encode/ image/decode/ DESTINATION include/libjxr/image FILES_MATCHING PATTERN "*.h")
install(DIRECTORY jxrgluelib/ DESTINATION include/libjxr/glue FILES_MATCHING PATTERN "*.h")
install(DIRECTORY jxrtestlib/ DESTINATION include/libjxr/test FILES_MATCHING PATTERN "*.h")

# The Makefile's libjxr.pc (its template uses python %-formatting).
file(WRITE "${CMAKE_BINARY_DIR}/libjxr.pc"
"prefix=${CMAKE_INSTALL_PREFIX}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: libjxr
Description: A library for reading JPEG XR images.

Version: ${JXR_VERSION}
Libs: -L\${libdir} -ljpegxr -ljxrglue
Libs.private: -lm
Cflags: -I\${includedir}/libjxr/common -I\${includedir}/libjxr/image/x86 -I\${includedir}/libjxr/image -I\${includedir}/libjxr/glue -I\${includedir}/libjxr/test -D__ANSI__ -DDISABLE_PERF_MEASUREMENT -DJXR_DLL_IMPORT${JXR_EXTRA_CFLAGS}
")
install(FILES "${CMAKE_BINARY_DIR}/libjxr.pc" DESTINATION lib/pkgconfig)
'@

# jxrlib (JPEG XR, optional in openslide through the zeiss-czi-jxr patch):
# built with the CMakeLists.txt above.
function Build-Jxrlib {
    if (Skip-If-Done 'jxrlib') { return }
    Log '=== jxrlib'
    $src = Git-Clone 'https://github.com/4creators/jxrlib.git' "v$(V jxrlib)" (Join-Path $LIW_SRC 'jxrlib')
    Write-Embedded (Join-Path $src 'CMakeLists.txt') $script:JxrlibCMakeLists
    Cmake-Build $src
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('jpegxr.dll', 'jxrglue.dll') 'jxrlib'
    Assert-Files (Join-Path $LIW_PREFIX 'lib\pkgconfig') @('libjxr.pc') 'jxrlib'
    Done-Stamp 'jxrlib'
}

# openslide at the pinned commit with the repository's two patches (the
# same ones the linux and macos builds apply); libdicom comes from
# openslide's own subproject wrap, statically.
function Build-Openslide {
    if (Skip-If-Done 'openslide') { return }
    Log '=== openslide'
    Ensure-Clang
    $src = Join-Path $LIW_SRC 'openslide'
    if (Test-Path $src) { Remove-Item -Recurse -Force $src }
    # A full clone: the pin is a commit, which a shallow clone cannot hold.
    for ($n = 1; $n -le 10; $n++) {
        & git clone -q https://github.com/openslide/openslide.git $src
        if ($LASTEXITCODE -eq 0) { break }
        Log 'retrying git clone of openslide'
        Start-Sleep -Seconds 5
    }
    if ($LASTEXITCODE -ne 0) { Die 'git clone of openslide failed' }
    & git -C $src checkout -q "$(V openslide-sha)"
    Assert-Exit 'git checkout of the openslide commit'
    & git -C $src config user.email 'wheels@example.com'
    & git -C $src config user.name 'Wheel Builder'
    foreach ($patch in @('openslide-iewchen-zeiss-czi-jxr.patch', 'openslide-vendor-mirax.c.patch')) {
        Run-Logged 'git' @('-C', $src, 'am', (Join-Path $RepoDir $patch)) "git am $patch"
    }
    # Windows only: the jxrlib GUIDs the jxr decoder compares against
    # (DEFINE_GUID in JXRGlue.h) are data symbols of jxrglue.dll, which
    # MSVC's linker cannot import without dllimport declarations the
    # jxrlib headers do not have (LNK2019 on IID_PKImageWmpDecode and the
    # GUID_PKPixelFormat* constants).  INITGUID before the include defines
    # local copies in this translation unit, the usual Windows idiom.
    Invoke-Patch $src 'openslide_decode_jxr_initguid' @'
path = "src/openslide-decode-jxr.c"
s = open(path).read()
s = s.replace("#include <JXRGlue.h>",
    "#ifdef _WIN32\n"
    "// The jxrlib GUIDs are data symbols of jxrglue.dll; define local copies.\n"
    "#define INITGUID\n"
    "#endif\n"
    "#include <JXRGlue.h>", 1)
open(path, "w").write(s)
'@
    # Compiled with clang-cl (see Ensure-Clang): openslide requires the
    # GNU C cleanup attribute.  CC is how meson picks the compiler, CC_LD
    # the linker it links targets with: MSVC's link.exe links clang-cl's
    # objects (lld-link is not extracted).  CC_LD does not reach the
    # checks meson links through the compiler driver itself (the sanity
    # check, has_function probes), and clang-cl 23 runs lld-link by
    # default where 21 ran link.exe, so the driver is told the same
    # through CFLAGS (-fuse-ld is a link-time flag; the -Wno- keeps
    # clang-cl from warning about it on every compile).
    $savedPath = $env:PATH
    $env:PATH = "$script:ClangBin;$env:PATH"
    $env:CC = 'clang-cl'
    $env:CC_LD = 'link'
    $env:CFLAGS = '-fuse-ld=link -Wno-unused-command-line-argument'
    try {
        Meson-Build $src @('-Dtest=disabled', '-Ddoc=disabled',
            '--force-fallback-for=libdicom,uthash')
    } finally {
        $env:PATH = $savedPath
        Remove-Item -Path 'env:CC', 'env:CC_LD', 'env:CFLAGS' -ErrorAction SilentlyContinue
    }
    Log "prefix DLLs: $((Get-ChildItem -Path (Join-Path $LIW_PREFIX 'bin') -Filter '*.dll' | ForEach-Object { $_.Name }) -join ', ')"
    Log "prefix EXEs: $((Get-ChildItem -Path (Join-Path $LIW_PREFIX 'bin') -Filter '*.exe' | ForEach-Object { $_.Name }) -join ', ')"
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('libopenslide-1.dll', 'slidetool.exe') 'openslide'
    $dll = Join-Path $LIW_PREFIX 'bin\libopenslide-1.dll'
    $deps = Get-Dependents $dll
    Log "libopenslide-1.dll depends on: $($deps -join ', ')"
    # Feature assertions, as on macos: the hard requirements plus the
    # optional jxr (the patch) -- a missing one would be silent.
    foreach ($stem in @('cairo', 'glib-2.0', 'gobject-2.0', 'gio-2.0', 'sqlite3', 'libxml2',
                        'jxrglue', 'jpegxr', 'libpng16', 'tiff.dll', 'openjp2', 'jpeg62')) {
        if (-not ($deps | Where-Object { $_ -like "$stem*" })) {
            Die "openslide was not linked against $stem; a dependency was missed (check the build order)"
        }
    }
    # The extension links the import library as 'openslide'; meson may
    # name it after the DLL's lib prefix.
    $lib = Join-Path $LIW_PREFIX 'lib'
    if ((Test-Path (Join-Path $lib 'libopenslide.lib')) -and -not (Test-Path (Join-Path $lib 'openslide.lib'))) {
        Copy-Item (Join-Path $lib 'libopenslide.lib') (Join-Path $lib 'openslide.lib')
    }
    Assert-Files $lib @('openslide.lib') 'openslide'
    Done-Stamp 'openslide'
}

# --- the libvips tree (lz4 through ImageMagick, then libvips itself): the
# counterpart of the Dockerfile's VIPS section and of the two pyvips
# stages of macos/build_wheels.sh.  Windows deviations, each called out
# where it happens: ImageMagick through an embedded cmake file (see
# Build-Imagemagick); curl on Schannel instead of OpenSSL; hdf5 without
# MPI; orc absent as on macos (libvips uses highway; orc is only its
# fallback). ---

function Build-Lz4 {
    if (Skip-If-Done 'lz4') { return }
    Log '=== lz4'
    $src = Git-Clone 'https://github.com/lz4/lz4.git' "v$(V lz4)" (Join-Path $LIW_SRC 'lz4')
    Cmake-Build (Join-Path $src 'build\cmake') @(
        '-DBUILD_SHARED_LIBS=ON', '-DBUILD_STATIC_LIBS=OFF',
        '-DLZ4_BUILD_CLI=OFF', '-DLZ4_BUILD_LEGACY_LZ4C=OFF')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('lz4.dll') 'lz4'
    Assert-Files (Join-Path $LIW_PREFIX 'lib\pkgconfig') @('liblz4.pc') 'lz4'
    Done-Stamp 'lz4'
}

# nifti installs only a cmake config package; libvips's meson.build spells
# out the niftiio.pc it would rather find, so that file is written here
# (which also makes -Dnifti-prefix-dir moot).
function Build-Nifti {
    if (Skip-If-Done 'nifti') { return }
    Log '=== nifti'
    $src = Git-Clone 'https://github.com/NIFTI-Imaging/nifti_clib.git' "v$(V nifti)" (Join-Path $LIW_SRC 'nifti')
    Cmake-Build $src @('-DBUILD_SHARED_LIBS=ON', '-DNIFTI_BUILD_TESTING=OFF',
        '-DNIFTI_BUILD_APPLICATIONS=OFF', '-DNIFTI_INSTALL_NO_DOCS=ON',
        '-DCMAKE_WINDOWS_EXPORT_ALL_SYMBOLS=ON')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('niftiio.dll', 'znz.dll') 'nifti'
    Write-PkgConfig 'niftiio' 'Core i/o routines for reading and writing nifti-1 format files' `
        (V nifti) '-lniftiio -lznz' '-I${includedir}' '${prefix}/include/nifti'
    Done-Stamp 'nifti'
}

# The Dockerfile's x86_64 branch adds -mavx2 -mfma; fftw's cmake derives
# the MSVC /arch switches from the ENABLE_* options itself.
# WITH_COMBINED_THREADS: one fftw3.dll with the threads API inside (the
# separate fftw3_threads library is a unix convention).
function Build-Fftw3 {
    if (Skip-If-Done 'fftw3') { return }
    Log '=== fftw3'
    $src = Fetch-Tarball "https://fftw.org/pub/fftw/fftw-$(V fftw3).tar.gz" 'fftw3.tar.gz' (Join-Path $LIW_SRC 'fftw3')
    Cmake-Build $src @('-DBUILD_SHARED_LIBS=ON', '-DBUILD_TESTS=OFF',
        '-DENABLE_AVX=ON', '-DENABLE_AVX2=ON', '-DENABLE_SSE=ON', '-DENABLE_SSE2=ON',
        '-DENABLE_THREADS=ON', '-DWITH_COMBINED_THREADS=ON',
        '-DCMAKE_POLICY_VERSION_MINIMUM=3.5')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('fftw3.dll') 'fftw3'
    Assert-Files (Join-Path $LIW_PREFIX 'lib\pkgconfig') @('fftw3.pc') 'fftw3'
    Done-Stamp 'fftw3'
}

function Build-Libhwy {
    if (Skip-If-Done 'libhwy') { return }
    Log '=== libhwy'
    $src = Git-Clone 'https://github.com/google/highway.git' "$(V libhwy)" (Join-Path $LIW_SRC 'highway')
    Cmake-Build $src @('-DBUILD_TESTING=OFF', '-DHWY_ENABLE_EXAMPLES=OFF', '-DHWY_ENABLE_TESTS=OFF',
        '-DBUILD_SHARED_LIBS=ON', '-DCMAKE_CXX_FLAGS=/DVQSORT_SECURE_SEED=0')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('hwy.dll') 'libhwy'
    Assert-Files (Join-Path $LIW_PREFIX 'lib\pkgconfig') @('libhwy.pc') 'libhwy'
    Done-Stamp 'libhwy'
}

# openexr before jpeg-xl, as on linux (libjxl's OpenEXR support is an auto
# feature).  Imath is fetched by openexr's cmake at configure time (the
# linux build's plain clone does not recurse either), at OPENEXR_IMATH_TAG.
function Build-Openexr {
    if (Skip-If-Done 'openexr') { return }
    Log '=== openexr'
    $src = Git-Clone 'https://github.com/AcademySoftwareFoundation/openexr.git' "v$(V openexr)" (Join-Path $LIW_SRC 'openexr')
    Cmake-Build $src @('-DBUILD_TESTING=OFF', '-DOPENEXR_BUILD_EXAMPLES=OFF',
        '-DOPENEXR_IMATH_TAG=v3.2.1', '-DOPENEXR_INSTALL_PKG_CONFIG=ON')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('OpenEXR-*.dll', 'Imath-*.dll') 'openexr'
    Assert-Files (Join-Path $LIW_PREFIX 'lib\pkgconfig') @('OpenEXR.pc') 'openexr'
    Done-Stamp 'openexr'
}

# libjxl's third_party libraries are git submodules (--recurse-submodules,
# like the Dockerfile; Git-Clone has no provision for it).  Highway is
# embedded statically from the vendored copy, as on linux and macos;
# brotli is forced to the prefix's (libjxl would otherwise build and
# install the vendored brotli over ours).  No tools: nothing bundles cjxl.
function Build-Jpeg-Xl {
    if (Skip-If-Done 'jpeg-xl') { return }
    Log '=== jpeg-xl (libjxl)'
    $src = Join-Path $LIW_SRC 'libjxl'
    for ($n = 1; $n -le 10; $n++) {
        if (Test-Path $src) { Remove-Item -Recurse -Force $src }
        & git clone --depth=1 --single-branch -b "v$(V jpeg-xl)" -c advice.detachedHead=false `
            --recurse-submodules --shallow-submodules -j $LIW_JOBS https://github.com/libjxl/libjxl.git $src
        if ($LASTEXITCODE -eq 0) { break }
        Log 'retrying git clone of libjxl'
        Start-Sleep -Seconds 5
    }
    if ($LASTEXITCODE -ne 0) { Die 'git clone of libjxl failed' }
    # Without the .git entries libjxl's version detection uses its fallback
    # version instead of a git describe of the shallow clone (the
    # Dockerfile does the same).
    foreach ($entry in @(Get-ChildItem -Path $src -Recurse -Force -Filter '.git')) {
        Remove-Item -Recurse -Force $entry.FullName -ErrorAction SilentlyContinue
    }
    # (-fpermissive is gcc-only.)
    Cmake-Build $src @('-DBUILD_TESTING=OFF', '-DBUILD_SHARED_LIBS=ON',
        '-DJPEGXL_ENABLE_EXAMPLES=OFF', '-DJPEGXL_ENABLE_MANPAGES=OFF',
        '-DJPEGXL_ENABLE_BENCHMARK=OFF', '-DJPEGXL_ENABLE_TOOLS=OFF',
        '-DJPEGXL_ENABLE_DOXYGEN=OFF', '-DJPEGXL_ENABLE_JNI=OFF',
        '-DJPEGXL_ENABLE_SJPEG=OFF', '-DJPEGXL_ENABLE_FUZZERS=OFF',
        '-DJPEGXL_FORCE_SYSTEM_BROTLI=ON',
        '-DHWY_ENABLE_INSTALL=OFF', '-DHWY_ENABLE_TESTS=OFF',
        '-DCMAKE_POLICY_VERSION_MINIMUM=3.5')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('jxl.dll', 'jxl_threads.dll') 'jpeg-xl'
    Assert-Files (Join-Path $LIW_PREFIX 'lib\pkgconfig') @('libjxl.pc') 'jpeg-xl'
    Assert-DependentStems (Join-Path $LIW_PREFIX 'bin\jxl.dll') @('brotlidec', 'brotlienc') 'jpeg-xl'
    Done-Stamp 'jpeg-xl'
}

# libimagequant 4.x is a rust crate with a C API built through cargo-c
# (cargo cinstall, as on linux and macos).  --library-type cdylib: by
# default the DLL and a static library both install, and under MSVC
# pkg-config's -limagequant would then resolve to the static
# imagequant.lib, whose rust runtime dependencies nothing hands the
# linker.
function Build-Libimagequant {
    if (Skip-If-Done 'libimagequant') { return }
    Log '=== libimagequant'
    Ensure-Rust
    $src = Git-Clone 'https://github.com/ImageOptim/libimagequant.git' "$(V libimagequant)" (Join-Path $LIW_SRC 'libimagequant')
    Push-Location (Join-Path $src 'imagequant-sys')
    try {
        Run-Logged 'cargo' @('cinstall', '--release', '--library-type', 'cdylib',
            '--prefix', $script:CmakePrefix, '--libdir', "$script:CmakePrefix/lib") 'cargo cinstall of libimagequant'
    } finally {
        Pop-Location
    }
    # cargo-c names the MSVC import library after the DLL
    # (imagequant.dll.lib); pkg-config's -limagequant needs imagequant.lib.
    $lib = Join-Path $LIW_PREFIX 'lib'
    Log "libimagequant installed: $((Get-ChildItem $lib -Filter '*imagequant*' | ForEach-Object { $_.Name }) -join ', ')"
    if ((Test-Path (Join-Path $lib 'imagequant.dll.lib')) -and -not (Test-Path (Join-Path $lib 'imagequant.lib'))) {
        Copy-Item (Join-Path $lib 'imagequant.dll.lib') (Join-Path $lib 'imagequant.lib')
    }
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('imagequant.dll') 'libimagequant'
    Assert-Files $lib @('imagequant.lib') 'libimagequant'
    Assert-Files (Join-Path $LIW_PREFIX 'lib\pkgconfig') @('imagequant.pc') 'libimagequant'
    Done-Stamp 'libimagequant'
}

# A cmake build for libexif, whose own build is autotools (its README-Win32
# suggests "hack yourself a build system somehow").  The same sources as
# libexif/Makefile.am (the apple makernote is left out there too), the
# API exported from libexif.sym as the autotools build exports it,
# configure's two generated headers (config.h without NLS, as on macos;
# localtime_s is MSVC's; _stdint.h, which exif-utils.h includes), the
# installed header set, and libexif.pc.  LIBEXIF_VERSION is passed in.
$script:LibexifCMakeLists = @'
cmake_minimum_required(VERSION 3.16)
project(libexif C)
if(NOT LIBEXIF_VERSION)
  message(FATAL_ERROR "pass -DLIBEXIF_VERSION=<version>")
endif()
set(SRC
  libexif/exif-byte-order.c libexif/exif-content.c libexif/exif-data.c
  libexif/exif-entry.c libexif/exif-format.c libexif/exif-ifd.c
  libexif/exif-loader.c libexif/exif-log.c libexif/exif-mem.c
  libexif/exif-mnote-data.c libexif/exif-tag.c libexif/exif-utils.c
  libexif/exif-gps-ifd.c
  libexif/canon/exif-mnote-data-canon.c libexif/canon/mnote-canon-entry.c
  libexif/canon/mnote-canon-tag.c
  libexif/fuji/exif-mnote-data-fuji.c libexif/fuji/mnote-fuji-entry.c
  libexif/fuji/mnote-fuji-tag.c
  libexif/olympus/exif-mnote-data-olympus.c libexif/olympus/mnote-olympus-entry.c
  libexif/olympus/mnote-olympus-tag.c
  libexif/pentax/exif-mnote-data-pentax.c libexif/pentax/mnote-pentax-entry.c
  libexif/pentax/mnote-pentax-tag.c)
set(GEN ${CMAKE_BINARY_DIR}/generated)
file(WRITE ${GEN}/config.h
"#define HAVE_LOCALTIME_S 1
#define GETTEXT_PACKAGE \"libexif-12\"
#define PACKAGE_VERSION \"${LIBEXIF_VERSION}\"
/* exif-loader.c uses ssize_t, which MSVC does not have. */
#include <BaseTsd.h>
typedef SSIZE_T ssize_t;
")
file(WRITE ${GEN}/libexif/_stdint.h "#include <stdint.h>\n")
file(STRINGS ${CMAKE_SOURCE_DIR}/libexif/libexif.sym SYMS)
set(DEF "EXPORTS\n")
foreach(sym ${SYMS})
  string(APPEND DEF "${sym}\n")
endforeach()
file(WRITE ${GEN}/libexif.def "${DEF}")
add_library(exif SHARED ${SRC} ${GEN}/libexif.def)
target_include_directories(exif PRIVATE ${CMAKE_SOURCE_DIR} ${GEN})
target_compile_definitions(exif PRIVATE _CRT_SECURE_NO_WARNINGS)
install(TARGETS exif
  RUNTIME DESTINATION bin LIBRARY DESTINATION lib ARCHIVE DESTINATION lib)
install(FILES
  libexif/exif-byte-order.h libexif/exif-content.h libexif/exif-data.h
  libexif/exif-data-type.h libexif/exif-entry.h libexif/exif-format.h
  libexif/exif-ifd.h libexif/exif-loader.h libexif/exif-log.h
  libexif/exif-mem.h libexif/exif-mnote-data.h libexif/exif-tag.h
  libexif/exif-utils.h ${GEN}/libexif/_stdint.h
  DESTINATION include/libexif)
file(WRITE ${CMAKE_BINARY_DIR}/libexif.pc
"prefix=${CMAKE_INSTALL_PREFIX}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: libexif
Description: EXIF tag parsing library
Version: ${LIBEXIF_VERSION}
Libs: -L\${libdir} -lexif
Cflags: -I\${includedir}
")
install(FILES ${CMAKE_BINARY_DIR}/libexif.pc DESTINATION lib/pkgconfig)
'@

function Build-Libexif {
    if (Skip-If-Done 'libexif') { return }
    Log '=== libexif'
    $src = Git-Clone 'https://github.com/libexif/libexif.git' "v$(V libexif)" (Join-Path $LIW_SRC 'libexif')
    Write-Embedded (Join-Path $src 'CMakeLists.txt') $script:LibexifCMakeLists
    Cmake-Build $src @("-DLIBEXIF_VERSION=$(V libexif)")
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('exif.dll') 'libexif'
    Assert-Files (Join-Path $LIW_PREFIX 'lib\pkgconfig') @('libexif.pc') 'libexif'
    Done-Stamp 'libexif'
}

# libarchive: zlib, bzip2, zstd, lzma and lz4 from the prefix (the formats
# the linux wheel's libarchive carries through them are asserted).  No
# OpenSSL (Windows' CNG supplies the hashes), no tools (bsdtar and friends
# are not bundled).
function Build-Libarchive {
    if (Skip-If-Done 'libarchive') { return }
    Log '=== libarchive'
    $src = Git-Clone 'https://github.com/libarchive/libarchive.git' "v$(V libarchive)" (Join-Path $LIW_SRC 'libarchive')
    Cmake-Build $src @('-DBUILD_TESTING=OFF', '-DENABLE_TEST=OFF', '-DBUILD_SHARED_LIBS=ON',
        '-DENABLE_TAR=OFF', '-DENABLE_CPIO=OFF', '-DENABLE_CAT=OFF', '-DENABLE_UNZIP=OFF',
        '-DENABLE_BZip2=ON', '-DENABLE_OPENSSL=OFF', '-DENABLE_LIBB2=OFF', '-DENABLE_LZO=OFF',
        '-DENABLE_ICONV=OFF', '-DENABLE_CNG=ON',
        '-DCMAKE_POLICY_VERSION_MINIMUM=3.5')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('archive.dll') 'libarchive'
    Assert-Files (Join-Path $LIW_PREFIX 'lib\pkgconfig') @('libarchive.pc') 'libarchive'
    Assert-DependentStems (Join-Path $LIW_PREFIX 'bin\archive.dll') @('z.dll', 'bz2', 'zstd', 'liblzma', 'lz4') 'libarchive'
    Done-Stamp 'libarchive'
}

# LibRaw's own tree has no cmake build (README.cmake points at a separate
# repository) but ships Makefile.msvc, which builds libraw.dll with
# cl /MD; lcms2 and libjpeg (DNG) are handed to it through the macros its
# commented-out examples show, which is the set the linux configure
# auto-detects.  The makefile installs nothing, so the DLL, the import
# library, the headers and a libraw.pc are placed by hand.
function Build-Libraw {
    if (Skip-If-Done 'libraw') { return }
    Log '=== libraw'
    $src = Git-Clone 'https://github.com/LibRaw/LibRaw.git' "$(V libraw)" (Join-Path $LIW_SRC 'LibRaw')
    foreach ($lib in @('lcms2.lib', 'jpeg.lib')) {
        if (-not (Test-Path (Join-Path $LIW_PREFIX "lib\$lib"))) { Die "libraw: $lib is not in the prefix" }
    }
    Push-Location $src
    try {
        Run-Logged 'nmake' @('/nologo', '/f', 'Makefile.msvc',
            "LCMS_DEF=/DUSE_LCMS2 /DCMS_DLL /I$LIW_PREFIX\include",
            "LCMS_LIB=$LIW_PREFIX\lib\lcms2.lib",
            "JPEG_DEF=/DUSE_JPEG /I$LIW_PREFIX\include",
            "JPEG_LIB=$LIW_PREFIX\lib\jpeg.lib",
            'bin\libraw.dll') 'nmake of libraw'
    } finally {
        Pop-Location
    }
    Copy-Item (Join-Path $src 'bin\libraw.dll') (Join-Path $LIW_PREFIX 'bin') -Force
    Copy-Item (Join-Path $src 'lib\libraw.lib') (Join-Path $LIW_PREFIX 'lib') -Force
    $inc = Join-Path $LIW_PREFIX 'include\libraw'
    New-Item -ItemType Directory -Force -Path $inc | Out-Null
    Copy-Item (Join-Path $src 'libraw\*.h') $inc -Force
    # (-llibraw: the import library is libraw.lib; the linux .pc says -lraw.)
    # libvips asks for libraw_r, the thread-safe flavor; the MSVC makefile
    # compiles without LIBRAW_NOTHREADS, so the one DLL is that flavor and
    # both names describe it.  Cflags as LibRaw's own .pc: the headers are
    # in include/libraw, and ImageMagick's dng coder includes <libraw.h>.
    Write-PkgConfig 'libraw' 'Raw image decoder library' (V libraw) '-llibraw' '-I${includedir}/libraw'
    Write-PkgConfig 'libraw_r' 'Raw image decoder library (thread-safe)' (V libraw) '-llibraw' '-I${includedir}/libraw'
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('libraw.dll') 'libraw'
    Assert-DependentStems (Join-Path $LIW_PREFIX 'bin\libraw.dll') @('lcms2', 'jpeg62') 'libraw'
    Done-Stamp 'libraw'
}

# glib and freetype are required explicitly so a lookup failure is a
# configure error rather than a silently smaller harfbuzz (the linux
# build's auto features light up the same way).  The Windows shapers
# (gdi, directwrite, uniscribe) are system libraries.
function Build-Harfbuzz {
    if (Skip-If-Done 'harfbuzz') { return }
    Log '=== harfbuzz'
    $src = Git-Clone 'https://github.com/harfbuzz/harfbuzz.git' "$(V harfbuzz)" (Join-Path $LIW_SRC 'harfbuzz')
    Meson-Build $src @('-Dtests=disabled', '-Ddocs=disabled', '-Dintrospection=disabled',
        '-Dglib=enabled', '-Dfreetype=enabled', '-Dcairo=enabled')
    # (harfbuzz.dll itself; 15.x also installs harfbuzz-subset, -cairo,
    # -gobject, -gpu, -raster and -vector DLLs beside it.)
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('harfbuzz.dll') 'harfbuzz'
    Assert-DependentStems (Join-Path $LIW_PREFIX 'bin\harfbuzz.dll') @('freetype', 'glib-2.0') 'harfbuzz'
    Done-Stamp 'harfbuzz'
}

# fribidi comes from pango's own wrap (nothing in the prefix provides it;
# the macos build forces the same wrap).  fontconfig, freetype and cairo
# are required explicitly: pangoft2 and pangocairo are what librsvg and
# libvips consume (pango's Windows build would otherwise lean on its
# win32 backend).
function Build-Pango {
    if (Skip-If-Done 'pango') { return }
    Log '=== pango'
    $src = Git-Clone 'https://github.com/GNOME/pango.git' "$(V pango)" (Join-Path $LIW_SRC 'pango')
    Meson-Build $src @('-Dintrospection=disabled', '-Dfontconfig=enabled', '-Dfreetype=enabled',
        '-Dcairo=enabled', '-Dbuild-testsuite=false', '-Dbuild-examples=false',
        '--force-fallback-for=fribidi')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('pango-1.0*.dll', 'pangocairo-1.0*.dll', 'pangoft2-1.0*.dll') 'pango'
    $ft2 = Get-ChildItem (Join-Path $LIW_PREFIX 'bin') -Filter 'pangoft2-1.0*.dll' | Select-Object -First 1
    Assert-DependentStems $ft2.FullName @('freetype', 'fontconfig', 'harfbuzz') 'pango'
    $pc = Get-ChildItem (Join-Path $LIW_PREFIX 'bin') -Filter 'pangocairo-1.0*.dll' | Select-Object -First 1
    Assert-DependentStems $pc.FullName @('cairo') 'pango'
    Done-Stamp 'pango'
}

# librsvg is rust with a meson build around cargo (and cargo-c for the C
# library).  gdk-pixbuf is built in neither pipeline, so its auto feature
# is disabled rather than left to pull the wrap (as on macos).  The
# Dockerfile's LDFLAGS and makedef.py changes are linux/ELF specifics.
function Build-Librsvg {
    if (Skip-If-Done 'librsvg') { return }
    Log '=== librsvg'
    Ensure-Rust
    $src = Git-Clone 'https://github.com/GNOME/librsvg.git' "$(V librsvg)" (Join-Path $LIW_SRC 'librsvg')
    # Make the output library much smaller (the Dockerfile's addition).
    Add-Content -Path (Join-Path $src 'Cargo.toml') -Value "`n[profile.release]`nlto = true`n" -Encoding ascii
    # Windows only: meson wraps the rust static library in a DLL with
    # link_whole, and under MSVC /WHOLEARCHIVE forces in every member of
    # that library -- including the raw-dylib import stubs the windows
    # crates embed, of which two crates carry kernel32's, so link.exe
    # fails with LNK2005 on __IMPORT_DESCRIPTOR_kernel32.  The exports
    # come from a generated .def (vs_module_defs), and a .def makes the
    # linker pull each exported symbol's object by itself, so plain
    # link_with gives the same DLL without the forced members.
    Invoke-Patch $src 'librsvg_link_with' @'
path = "rsvg/meson.build"
s = open(path).read()
old = "link_whole: librsvg_c_lib,"
# The first occurrence is the installed shared library's; the second is
# the introspection build's (disabled here).
assert s.index(old) < s.index("vs_module_defs: librsvg_def,"), "librsvg's shared_library block changed"
s = s.replace(old, "link_with: librsvg_c_lib,", 1)
open(path, "w").write(s)
'@
    Meson-Build $src @('-Dintrospection=disabled', '-Ddocs=disabled', '-Dtests=false',
        '-Dpixbuf=disabled', '-Dpixbuf-loader=disabled', '-Dvala=disabled')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('rsvg-2*.dll') 'librsvg'
    Assert-Files (Join-Path $LIW_PREFIX 'lib\pkgconfig') @('librsvg-2.0.pc') 'librsvg'
    $dll = Get-ChildItem (Join-Path $LIW_PREFIX 'bin') -Filter 'rsvg-2*.dll' | Select-Object -First 1
    Assert-DependentStems $dll.FullName @('cairo', 'pango', 'glib-2.0', 'libxml2') 'librsvg'
    Done-Stamp 'librsvg'
}

# (The Dockerfile's -pthread flags are gcc's; BUILD_SHARED/BUILD_STATIC are
# not options at this version, as the macos build found.)  No dec265/
# enc265 tools: nothing bundles them.
function Build-Libde265 {
    if (Skip-If-Done 'libde265') { return }
    Log '=== libde265'
    $src = Git-Clone 'https://github.com/strukturag/libde265.git' "v$(V libde265)" (Join-Path $LIW_SRC 'libde265')
    Cmake-Build $src @('-DBUILD_SHARED_LIBS=ON', '-DENABLE_SDL=OFF',
        '-DENABLE_DECODER=OFF', '-DENABLE_ENCODER=OFF',
        '-DCMAKE_POLICY_VERSION_MINIMUM=3.5')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('*de265*.dll') 'libde265'
    Assert-Files (Join-Path $LIW_PREFIX 'lib\pkgconfig') @('libde265.pc') 'libde265'
    Done-Stamp 'libde265'
}

# libde265 is the HEVC decoder the linux wheel carries (asserted); the
# other codecs are absent there too.  Codecs are built in, not as plugins
# (nothing would bundle plugin DLLs).
function Build-Libheif {
    if (Skip-If-Done 'libheif') { return }
    Log '=== libheif'
    $src = Git-Clone 'https://github.com/strukturag/libheif.git' "v$(V libheif)" (Join-Path $LIW_SRC 'libheif')
    Cmake-Build $src @('-DBUILD_TESTING=OFF', '-DWITH_EXAMPLES=OFF', '-DBUILD_SHARED_LIBS=ON',
        '-DWITH_LIBDE265=ON', '-DWITH_LIBDE265_PLUGIN=OFF', '-DENABLE_PLUGIN_LOADING=OFF',
        '-DWITH_X265=OFF', '-DWITH_AOM_DECODER=OFF', '-DWITH_AOM_ENCODER=OFF', '-DWITH_DAV1D=OFF',
        '-DWITH_RAV1E=OFF', '-DWITH_SvtEnc=OFF', '-DWITH_GDK_PIXBUF=OFF')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('heif.dll') 'libheif'
    Assert-Files (Join-Path $LIW_PREFIX 'lib\pkgconfig') @('libheif.pc') 'libheif'
    Assert-DependentStems (Join-Path $LIW_PREFIX 'bin\heif.dll') @('libde265') 'libheif'
    Done-Stamp 'libheif'
}

# curl, for libcurl.pc (poppler-glib.pc's "Requires.private: libcurl" must
# resolve, or meson drops poppler-glib and with it libvips's pdf loader;
# the macos build found this) and later for GDAL.  TLS is Windows' own
# Schannel, so no OpenSSL is built: the linux and macos builds use
# OpenSSL, but the machine's TLS stack and certificate store are what a
# Windows user expects, and it keeps one large library out of the tree.
function Build-Curl {
    if (Skip-If-Done 'curl') { return }
    Log '=== curl'
    $ver = V 'curl'
    # (The release tarball, as on linux: the tag carries underscores, the
    # tarball dots.)
    $src = Fetch-Tarball "https://github.com/curl/curl/releases/download/curl-$ver/curl-$($ver -replace '_', '.').tar.gz" `
        'curl.tar.gz' (Join-Path $LIW_SRC 'curl')
    Cmake-Build $src @('-DBUILD_SHARED_LIBS=ON', '-DBUILD_STATIC_LIBS=OFF', '-DBUILD_TESTING=OFF',
        '-DBUILD_CURL_EXE=OFF', '-DCURL_USE_SCHANNEL=ON', '-DCURL_USE_LIBPSL=OFF', '-DUSE_LIBIDN2=OFF',
        '-DCURL_USE_LIBSSH2=OFF', '-DCURL_ZLIB=ON', '-DCURL_ZSTD=ON', '-DCURL_BROTLI=ON',
        '-DBUILD_LIBCURL_DOCS=OFF', '-DBUILD_MISC_DOCS=OFF', '-DENABLE_CURL_MANUAL=OFF',
        '-DIMPORT_LIB_SUFFIX=')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('libcurl.dll') 'curl'
    Assert-Files (Join-Path $LIW_PREFIX 'lib\pkgconfig') @('libcurl.pc') 'curl'
    # The .pc's -lcurl resolves to curl.lib under MSVC; the import library
    # installs as libcurl.lib.
    $lib = Join-Path $LIW_PREFIX 'lib'
    if ((Test-Path (Join-Path $lib 'libcurl.lib')) -and -not (Test-Path (Join-Path $lib 'curl.lib'))) {
        Copy-Item (Join-Path $lib 'libcurl.lib') (Join-Path $lib 'curl.lib')
    }
    Assert-DependentStems (Join-Path $LIW_PREFIX 'bin\libcurl.dll') @('z.dll', 'zstd', 'brotlidec') 'curl'
    Done-Stamp 'curl'
}

# FONT_CONFIGURATION=fontconfig: poppler's Windows default is its win32
# font lookup; the linux and macos wheels' poppler uses fontconfig, which
# the prefix has.  Boost, NSS, GPGME and Qt off as on linux and macos.
function Build-Poppler {
    if (Skip-If-Done 'poppler') { return }
    Log '=== poppler'
    $src = Git-Clone 'https://gitlab.freedesktop.org/poppler/poppler.git' "poppler-$(V poppler)" (Join-Path $LIW_SRC 'poppler')
    # (Release, as on linux: poppler rejects MinSizeRel; the later -D wins.)
    # ENABLE_CPP=OFF: poppler-cpp, the C++ wrapper, is the one part that
    # hard-requires iconv, which a Windows prefix has no provider of
    # (versions.txt pins a libiconv for the day something that matters
    # needs it); libvips uses poppler-glib, and the linux wheel bundles no
    # poppler-cpp consumer either.
    # GLIB2_MKENUMS_PYTHON: glib-mkenums is a python script (glib's own
    # install), which poppler runs through this interpreter; nothing on
    # the scrubbed PATH answers to python3.
    Cmake-Build $src @('-DCMAKE_BUILD_TYPE=Release', '-DENABLE_UNSTABLE_API_ABI_HEADERS=ON', '-DBUILD_SHARED_LIBS=ON',
        '-DENABLE_CPP=OFF', "-DGLIB2_MKENUMS_PYTHON=$($script:PatchPython -replace '\\', '/')",
        '-DBUILD_CPP_TESTS=OFF', '-DBUILD_GTK_TESTS=OFF', '-DBUILD_MANUAL_TESTS=OFF',
        '-DBUILD_QT5_TESTS=OFF', '-DBUILD_QT6_TESTS=OFF',
        '-DENABLE_NSS3=OFF', '-DENABLE_GPGME=OFF', '-DENABLE_QT5=OFF', '-DENABLE_QT6=OFF', '-DENABLE_BOOST=OFF',
        '-DENABLE_GLIB=ON', '-DENABLE_LIBCURL=ON', '-DENABLE_LCMS=ON', '-DENABLE_LIBTIFF=ON',
        '-DENABLE_LIBOPENJPEG=openjpeg2', '-DENABLE_DCTDECODER=libjpeg',
        '-DFONT_CONFIGURATION=fontconfig', '-DRUN_GPERF_IF_PRESENT=OFF')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('poppler.dll', 'poppler-glib.dll') 'poppler'
    Assert-Files (Join-Path $LIW_PREFIX 'lib\pkgconfig') @('poppler-glib.pc') 'poppler'
    Assert-DependentStems (Join-Path $LIW_PREFIX 'bin\poppler.dll') @(
        'freetype', 'jpeg62', 'libpng16', 'openjp2', 'libcurl', 'fontconfig', 'lcms2', 'tiff') 'poppler'
    Assert-DependentStems (Join-Path $LIW_PREFIX 'bin\poppler-glib.dll') @('cairo') 'poppler'
    Done-Stamp 'poppler'
}

function Build-Fitsio {
    if (Skip-If-Done 'fitsio') { return }
    Log '=== cfitsio'
    $src = Git-Clone 'https://github.com/HEASARC/cfitsio.git' "cfitsio-$(V fitsio)" (Join-Path $LIW_SRC 'cfitsio')
    Cmake-Build $src @('-DBUILD_SHARED_LIBS=ON', '-DTESTS=OFF', '-DUTILS=OFF',
        '-DCMAKE_POLICY_VERSION_MINIMUM=3.5')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('cfitsio.dll') 'cfitsio'
    Assert-Files (Join-Path $LIW_PREFIX 'lib\pkgconfig') @('cfitsio.pc') 'cfitsio'
    Done-Stamp 'fitsio'
}

# hdf5 without MPI: there is no OpenMPI on Windows (MS-MPI needs an
# installer), and parallel hdf5 only matters for the parallel netcdf of
# the GDAL tree.  The threadsafe + C++ combination needs ALLOW_UNSUPPORTED
# as on linux; the tools are off (not bundled; the linux build deletes its
# test binaries for size too).  ZLIB_LIBRARY/ZLIB_INCLUDE_DIR are preset
# for the reason the macos build records: hdf5's config-mode zlib find
# yields imported targets but not the module variables its filter code
# consumes.
function Build-Hdf5 {
    if (Skip-If-Done 'hdf5') { return }
    Log '=== hdf5'
    $zlib = Join-Path $LIW_PREFIX 'lib\z.lib'
    if (-not (Test-Path $zlib)) { Die "hdf5: zlib's import library is not at $zlib" }
    $src = Git-Clone 'https://github.com/HDFGroup/hdf5.git' "hdf5-$(V hdf5)" (Join-Path $LIW_SRC 'hdf5')
    Cmake-Build $src @('-DDEFAULT_API_VERSION=v18', '-DHDF5_BUILD_EXAMPLES=OFF', '-DHDF5_BUILD_FORTRAN=OFF',
        '-DHDF5_ENABLE_PARALLEL=OFF', '-DHDF5_ENABLE_Z_LIB_SUPPORT=ON', '-DHDF5_BUILD_GENERATORS=ON',
        '-DHDF5_BUILD_CPP_LIB=ON', '-DHDF5_DISABLE_COMPILER_WARNINGS=ON', '-DBUILD_TESTING=OFF',
        '-DHDF5_BUILD_DOC=OFF', '-DALLOW_UNSUPPORTED=ON', '-DHDF5_ENABLE_THREADSAFE=ON',
        '-DHDF5_BUILD_TOOLS=OFF', '-DBUILD_SHARED_LIBS=ON', '-DBUILD_STATIC_LIBS=OFF',
        # The config-mode find (NAMES ${ZLIB_PACKAGE_NAME}, COMPONENTS
        # static shared) finds our ZLIBConfig.cmake and then dies on the
        # static component this shared-only zlib never installed; a
        # package name nothing matches makes it fall through to the
        # module find and the presets below.
        '-DZLIB_PACKAGE_NAME=zlib-no-config',
        "-DZLIB_LIBRARY=$script:CmakePrefix/lib/z.lib", "-DZLIB_LIBRARIES=$script:CmakePrefix/lib/z.lib",
        "-DZLIB_INCLUDE_DIR=$script:CmakePrefix/include")
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('hdf5.dll', 'hdf5_cpp.dll', 'hdf5_hl.dll') 'hdf5'
    Assert-DependentStems (Join-Path $LIW_PREFIX 'bin\hdf5.dll') @('z.dll') 'hdf5'
    Done-Stamp 'hdf5'
}

# matio's own matio.pc carries neither the version nor the right libdir
# (the Dockerfile overwrites it too), so one is written; the import
# library's name follows the DLL's (libmatio.lib on Windows), so the -l
# flag is taken from what was installed.
function Build-Matio {
    if (Skip-If-Done 'matio') { return }
    Log '=== matio'
    $src = Git-Clone 'https://github.com/tbeu/matio.git' "v$(V matio)" (Join-Path $LIW_SRC 'matio')
    Cmake-Build $src @('-DMATIO_SHARED=ON', '-DMATIO_WITH_HDF5=ON', '-DMATIO_WITH_ZLIB=ON',
        '-DMATIO_MAT73=ON', '-DMATIO_USE_CONAN=OFF')
    $dll = Get-ChildItem (Join-Path $LIW_PREFIX 'bin') -Filter '*matio*.dll' | Select-Object -First 1
    if (-not $dll) { Die 'matio: no matio DLL in the prefix' }
    $implib = Get-ChildItem (Join-Path $LIW_PREFIX 'lib') -Filter '*matio*.lib' | Select-Object -First 1
    if (-not $implib) { Die 'matio: no import library in the prefix' }
    Write-PkgConfig 'matio' 'matio library' (V matio) "-l$($implib.BaseName)"
    Assert-DependentStems $dll.FullName @('hdf5') 'matio'
    Done-Stamp 'matio'
}

# ImageMagick.  Upstream's Windows build is a project generator
# (Configure.exe) that writes MSBuild projects for ImageMagick and for
# ImageMagick's own forks of every delegate library, all built from source
# inside one Visual Studio solution.  That route needs MSBuild (not in the
# installer-free toolchain) and would put a second copy of libpng,
# libtiff, libjpeg and the rest into the wheel next to the ones libvips
# links.  What the generated projects do is small, though: compile
# MagickCore/*.c with the coders, MagickWand/*.c and utilities/magick.c
# with _MAGICKLIB_ and _WIN32_WINNT, a generated magick-baseconfig.h (the
# Configure release's template with the option block and one
# MAGICKCORE_<X>_DELEGATE define per delegate filled in) and version.h
# from m4/version.m4.  The embedded cmake file below does exactly that
# against this prefix's libraries, resolved through pkg-config, so every
# delegate the linux and macos builds link is required here (a missing
# one is a configure error) and checked on the DLL's import table.  Like
# the macos build, every coder is compiled into MagickCore (no modules;
# the linux wheel's dlopened coder modules are never bundled anyway).
# Q16, HDRI, 32-bit channel masks and OpenMP, as the linux configure
# defaults (the 64-bit masks of upstream's x64 projects need C++).
# Delegates the linux image also lacks stay off: lqr, raqm, djvu, gs,
# gvc, wmf, flif, fpx, uhdr, dps, X11.  No Magick++ (nothing in the
# wheel consumes the C++ API).
$script:ImageMagickCMakeLists = @'
cmake_minimum_required(VERSION 3.16)
project(ImageMagick C CXX)
foreach(var IM_BASECONFIG_TEMPLATE IM_RELEASE_DATE IM_GIT_REVISION)
  if(NOT ${var})
    message(FATAL_ERROR "pass -D${var}=...")
  endif()
endforeach()
find_package(PkgConfig REQUIRED)

# Delegates: the pkg-config modules of each, and the define the coders
# test (upstream's .ImageMagick/Config.txt of each dependency names it).
set(CONFIG_DEFINES "")
set(DELEGATE_TARGETS "")
function(delegate name)
  pkg_check_modules(DEP_${name} REQUIRED IMPORTED_TARGET ${ARGN})
  set(CONFIG_DEFINES "${CONFIG_DEFINES}#define MAGICKCORE_${name}_DELEGATE 1\n" PARENT_SCOPE)
  set(DELEGATE_TARGETS ${DELEGATE_TARGETS} PkgConfig::DEP_${name} PARENT_SCOPE)
endfunction()
delegate(ZLIB zlib)
delegate(BZLIB bzip2)
delegate(LZMA liblzma)
delegate(ZSTD libzstd)
delegate(ZIP libzip)
delegate(PNG libpng)
delegate(JPEG libjpeg)
delegate(TIFF libtiff-4)
delegate(WEBP libwebp)
delegate(WEBPMUX libwebpmux libwebpdemux)
delegate(LIBOPENJP2 libopenjp2)
delegate(JXL libjxl libjxl_threads)
delegate(HEIC libheif)
delegate(RAW_R libraw_r)
delegate(OPENEXR OpenEXR)
delegate(FFTW fftw3)
delegate(LCMS lcms2)
delegate(XML libxml-2.0)
delegate(FREETYPE freetype2)
delegate(FONTCONFIG fontconfig)
delegate(CAIRO cairo)
delegate(PANGOCAIRO pangocairo)
delegate(RSVG librsvg-2.0)
# jbigkit has no .pc file (a static library in the prefix).
find_library(JBIG_LIBRARY NAMES libjbig jbig REQUIRED)
find_path(JBIG_INCLUDE_DIR jbig.h REQUIRED)
string(APPEND CONFIG_DEFINES "#define MAGICKCORE_JBIG_DELEGATE 1\n")
# What the delegate probes of configure.ac would add for these versions.
string(APPEND CONFIG_DEFINES "#define MAGICKCORE_HAVE_LCMS2_H 1\n")
foreach(def JPEG_ENABLE_LOSSLESS JPEG12_READ_SCANLINES JPEG12_WRITE_SCANLINES
            JPEG16_READ_SCANLINES JPEG16_WRITE_SCANLINES)
  string(APPEND CONFIG_DEFINES "#define MAGICKCORE_HAVE_${def} 1\n")
endforeach()

# magick-baseconfig.h: the Configure release's Windows template, its
# $$CONFIG$$ marker replaced by the option block Configure.exe writes
# (MagickBaseConfig.cpp) with the linux configure's defaults.
file(READ ${IM_BASECONFIG_TEMPLATE} TEMPLATE)
set(CONFIG "#undef MAGICKCORE_INSTALLED_SUPPORT
#define MAGICKCORE_QUANTUM_DEPTH 16
#define MAGICKCORE_CHANNEL_MASK_DEPTH 32
#define MAGICKCORE_HDRI_ENABLE 1
#undef MAGICKCORE_HAVE_CL_CL_H
#define MAGICKCORE_DPC_SUPPORT
#define MAGICKCORE_EXCLUDE_DEPRECATED
#define MAGICKCORE_ZERO_CONFIGURATION_SUPPORT 0
${CONFIG_DEFINES}")
string(FIND "${TEMPLATE}" "$$CONFIG$$" marker)
if(marker EQUAL -1)
  message(FATAL_ERROR "no $$CONFIG$$ marker in ${IM_BASECONFIG_TEMPLATE}")
endif()
string(REPLACE "$$CONFIG$$" "${CONFIG}" BASECONFIG "${TEMPLATE}")
file(WRITE ${CMAKE_SOURCE_DIR}/MagickCore/magick-baseconfig.h "${BASECONFIG}")

# version.h from version.h.in, with the values configure.ac derives from
# m4/version.m4.
file(READ ${CMAKE_SOURCE_DIR}/m4/version.m4 VERSION_M4)
function(m4value key out)
  string(REGEX MATCH "m4_define\\(\\[magick${key}\\], \\[([0-9a-zA-Z.]+)\\]" _m "${VERSION_M4}")
  if("${CMAKE_MATCH_1}" STREQUAL "")
    message(FATAL_ERROR "no magick${key} in m4/version.m4")
  endif()
  set(${out} "${CMAKE_MATCH_1}" PARENT_SCOPE)
endfunction()
m4value(_major_version MAJOR)
m4value(_minor_version MINOR)
m4value(_micro_version MICRO)
m4value(_patchlevel_version PATCHLEVEL)
m4value(_lib_version PACKAGE_LIB_VERSION)
m4value(_library_current LIB_CURRENT)
m4value(_library_revision LIB_REVISION)
m4value(_library_age LIB_AGE)
m4value(pp_library_current PP_CURRENT)
m4value(pp_library_revision PP_REVISION)
m4value(pp_library_age PP_AGE)
set(PACKAGE_NAME "ImageMagick")
set(PACKAGE_BASE_VERSION "${MAJOR}.${MINOR}.${MICRO}")
set(MAGICK_LIB_VERSION_TEXT "${PACKAGE_BASE_VERSION}")
set(MAGICK_LIB_VERSION_NUMBER "${LIB_CURRENT},${LIB_AGE},${LIB_REVISION}")
set(PACKAGE_VERSION_ADDENDUM "-${PATCHLEVEL}")
set(MAGICK_LIBRARY_CURRENT "${LIB_CURRENT}")
math(EXPR MAGICK_LIBRARY_CURRENT_MIN "${LIB_CURRENT} - ${LIB_AGE}")
set(MAGICK_TARGET_CPU "x86_64")
set(MAGICKPP_LIB_VERSION_TEXT "${PACKAGE_BASE_VERSION}")
set(MAGICKPP_LIBRARY_VERSION_INFO "${PP_CURRENT}:${PP_REVISION}:${PP_AGE}")
set(MAGICKPP_LIBRARY_CURRENT "${PP_CURRENT}")
math(EXPR MAGICKPP_LIBRARY_CURRENT_MIN "${PP_CURRENT} - ${PP_AGE}")
set(MAGICK_GIT_REVISION "${IM_GIT_REVISION}")
set(PACKAGE_RELEASE_DATE "${IM_RELEASE_DATE}")
set(DOCUMENTATION_PATH "unavailable")
configure_file(${CMAKE_SOURCE_DIR}/MagickCore/version.h.in
               ${CMAKE_SOURCE_DIR}/MagickCore/version.h @ONLY)

set(ABI "Q16HDRI")
set(LIBNAME_CORE "MagickCore-${MAJOR}.${ABI}")
set(LIBNAME_WAND "MagickWand-${MAJOR}.${ABI}")
file(GLOB CORE_SRC ${CMAKE_SOURCE_DIR}/MagickCore/*.c)
file(GLOB CODER_SRC ${CMAKE_SOURCE_DIR}/coders/*.c)
# The X11 and WMF coders, as upstream's coders/Config.txt excludes them.
list(FILTER CODER_SRC EXCLUDE REGEX "/(wmf|x|xwd)\\.c$")
file(GLOB WAND_SRC ${CMAKE_SOURCE_DIR}/MagickWand/*.c)

# As upstream's projects compile under MSVC: every .c as C++20 (the
# headers use [[fallthrough]] under _MSC_VER); the ABI stays C through
# the headers' extern "C" blocks.
set(IM_OPTIONS /TP /std:c++20 /EHsc /openmp /W1)
set(IM_DEFINES _WIN32_WINNT=_WIN32_WINNT_WIN10 _CRT_SECURE_NO_WARNINGS _CRT_NONSTDC_NO_DEPRECATE)

add_library(MagickCore SHARED ${CORE_SRC} ${CODER_SRC})
set_target_properties(MagickCore PROPERTIES OUTPUT_NAME ${LIBNAME_CORE})
target_include_directories(MagickCore PUBLIC ${CMAKE_SOURCE_DIR} PRIVATE ${JBIG_INCLUDE_DIR})
target_compile_definitions(MagickCore PRIVATE _MAGICKLIB_ ${IM_DEFINES})
target_compile_options(MagickCore PRIVATE ${IM_OPTIONS})
target_link_libraries(MagickCore PRIVATE ${DELEGATE_TARGETS} ${JBIG_LIBRARY}
  ws2_32 user32 gdi32 advapi32 shell32 ole32 oleaut32 urlmon bcrypt winmm)

add_library(MagickWand SHARED ${WAND_SRC})
set_target_properties(MagickWand PROPERTIES OUTPUT_NAME ${LIBNAME_WAND})
target_compile_definitions(MagickWand PRIVATE _MAGICKLIB_ ${IM_DEFINES})
target_compile_options(MagickWand PRIVATE ${IM_OPTIONS})
target_link_libraries(MagickWand PRIVATE MagickCore)

add_executable(magick ${CMAKE_SOURCE_DIR}/utilities/magick.c)
target_compile_definitions(magick PRIVATE ${IM_DEFINES})
target_compile_options(magick PRIVATE ${IM_OPTIONS})
target_link_libraries(magick PRIVATE MagickWand MagickCore)

install(TARGETS MagickCore MagickWand magick
  RUNTIME DESTINATION bin LIBRARY DESTINATION lib ARCHIVE DESTINATION lib)
file(GLOB CORE_HEADERS ${CMAKE_SOURCE_DIR}/MagickCore/*.h)
file(GLOB WAND_HEADERS ${CMAKE_SOURCE_DIR}/MagickWand/*.h)
install(FILES ${CORE_HEADERS} DESTINATION include/ImageMagick-${MAJOR}/MagickCore)
install(FILES ${WAND_HEADERS} DESTINATION include/ImageMagick-${MAJOR}/MagickWand)

# The .pc files autotools would install (both the plain and the ABI-suffixed
# names); the Cflags carry the same three defines as on linux.
set(PCFLAGS "-DMAGICKCORE_HDRI_ENABLE=1 -DMAGICKCORE_QUANTUM_DEPTH=16 -DMAGICKCORE_CHANNEL_MASK_DEPTH=32")
function(write_pc name libname description requires)
  set(REQ "")
  if(requires)
    set(REQ "Requires: ${requires}\n")
  endif()
  file(WRITE ${CMAKE_BINARY_DIR}/${name}.pc
"prefix=${CMAKE_INSTALL_PREFIX}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include/ImageMagick-${MAJOR}
includearchdir=\${prefix}/include/ImageMagick-${MAJOR}
libname=${libname}

Name: ${name}
Description: ${description} (ABI ${ABI})
URL: https://github.com/ImageMagick
Version: ${PACKAGE_BASE_VERSION}
${REQ}Cflags: -I\${includearchdir} -I\${includedir} ${PCFLAGS}
Libs: -L\${libdir} -l\${libname}
")
  install(FILES ${CMAKE_BINARY_DIR}/${name}.pc DESTINATION lib/pkgconfig)
endfunction()
write_pc(MagickCore ${LIBNAME_CORE} "MagickCore - C API for ImageMagick" "")
write_pc(MagickCore-${MAJOR}.${ABI} ${LIBNAME_CORE} "MagickCore - C API for ImageMagick" "")
write_pc(ImageMagick ${LIBNAME_CORE} "ImageMagick - convert, edit, and compose images" "")
write_pc(ImageMagick-${MAJOR}.${ABI} ${LIBNAME_CORE} "ImageMagick - convert, edit, and compose images" "")
write_pc(MagickWand ${LIBNAME_WAND} "MagickWand - C API for ImageMagick" "MagickCore")
write_pc(MagickWand-${MAJOR}.${ABI} ${LIBNAME_WAND} "MagickWand - C API for ImageMagick" "MagickCore")
'@

function Build-Imagemagick {
    if (Skip-If-Done 'imagemagick') { return }
    Log '=== imagemagick'
    $src = Git-Clone 'https://github.com/ImageMagick/ImageMagick.git' "$(V imagemagick)" (Join-Path $LIW_SRC 'ImageMagick')
    # The base config template comes from the Configure release the source
    # itself pins (its Windows CI downloads the same one).
    $pinScript = Join-Path $src '.github\build\windows\download-configure.sh'
    $pin = Get-Content $pinScript -Raw
    if ($pin -notmatch 'download_configure "([^"]+)"') {
        Die "imagemagick: no Configure release pin in $pinScript"
    }
    $configureRelease = $Matches[1]
    $zip = Fetch "https://github.com/ImageMagick/Configure/releases/download/$configureRelease/files.zip" `
        "ImageMagick-Configure-$configureRelease.zip"
    $cfg = Join-Path $LIW_SRC 'ImageMagick-Configure'
    Expand-Zip $zip $cfg
    $template = Join-Path $cfg 'Configs\MagickCore\magick-baseconfig.h.in'
    if (-not (Test-Path $template)) { Die "imagemagick: $template is not in the Configure release" }
    $releaseDate = (& git -C $src log -1 --format=%cd --date=format:%Y-%m-%d).Trim()
    Assert-Exit 'git log in the ImageMagick checkout'
    if (-not $script:VcOpenMP -or -not (Test-Path (Join-Path $script:VcOpenMP 'vcomp140.dll'))) {
        Die 'imagemagick: no OpenMP redistributable directory next to the CRT one (vcomp140.dll)'
    }
    # nt-base-private.h defines read/write/tell as function-like macros,
    # which break LibRaw's C++ classes (a method named read); upstream's
    # own LibRaw fork undefines the three in libraw_datastream.h for MSVC,
    # and this does the same in the one coder that includes libraw.h.
    Invoke-Patch $src 'imagemagick_dng' @'
path = "coders/dng.c"
s = open(path).read()
old = "#if defined(MAGICKCORE_RAW_R_DELEGATE)\n#include <libraw.h>\n#endif\n"
assert old in s, "dng.c's libraw include changed"
s = s.replace(old, "#if defined(MAGICKCORE_RAW_R_DELEGATE)\n#if defined(_MSC_VER)\n"
              "#undef read\n#undef write\n#undef tell\n#endif\n#include <libraw.h>\n#endif\n")
open(path, "w").write(s)
'@
    Write-Embedded (Join-Path $src 'CMakeLists.txt') $script:ImageMagickCMakeLists
    Cmake-Build $src @("-DIM_BASECONFIG_TEMPLATE=$($template -replace '\\', '/')",
        "-DIM_RELEASE_DATE=$releaseDate", "-DIM_GIT_REVISION=$(V imagemagick)",
        "-DPKG_CONFIG_EXECUTABLE=$env:PKG_CONFIG")
    $core = 'MagickCore-7.Q16HDRI'
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @("$core.dll", 'MagickWand-7.Q16HDRI.dll', 'magick.exe') 'imagemagick'
    Assert-Files (Join-Path $LIW_PREFIX 'lib') @("$core.lib") 'imagemagick'
    Assert-Files (Join-Path $LIW_PREFIX 'lib\pkgconfig') @('MagickCore.pc', 'MagickWand.pc', 'ImageMagick.pc') 'imagemagick'
    Assert-Files (Join-Path $LIW_PREFIX 'include\ImageMagick-7\MagickCore') @('magick-baseconfig.h', 'version.h') 'imagemagick'
    # The macos build's assertion list: every delegate compiled into
    # MagickCore (annotate's freetype/fontconfig, lcms, xml2, and the
    # coder delegates), plus the OpenMP runtime.  Not zstd: the delegate
    # only names it in the version string (libtiff does the zstd work),
    # so link.exe records no import for it, where the autotools builds
    # carry a -lzstd whether used or not.
    Assert-DependentStems (Join-Path $LIW_PREFIX "bin\$core.dll") @(
        'freetype', 'fontconfig', 'libxml2', 'z.dll', 'libpng16', 'jpeg62', 'tiff', 'libwebp', 'heif', 'jxl',
        'libraw', 'rsvg-2', 'openjp2', 'lcms2', 'fftw3', 'zip', 'liblzma', 'bz2', 'OpenEXR',
        'pangocairo', 'cairo', 'vcomp140') 'imagemagick'
    Done-Stamp 'imagemagick'
}

# libvips: a meson build with every loader compiled in (-Dmodules=disabled,
# like the Dockerfile).  Every loader the linux wheel carries is required
# explicitly, so a dependency pkg-config cannot satisfy fails the
# configure step instead of silently shrinking the feature set, and the
# DLL's import table is checked afterwards all the same.  Windows
# deviation: orc absent as on macos.
function Build-Libvips {
    if (Skip-If-Done 'libvips') { return }
    Log '=== libvips'
    $src = Git-Clone 'https://github.com/libvips/libvips.git' "v$(V libvips)" (Join-Path $LIW_SRC 'libvips')
    # The Dockerfile's seds: VIPS_TMPDIR for the temp directory, no
    # target_clones (MSVC has no such attribute; kept for parity), and the
    # tiff2vips warnings silenced.
    Invoke-Patch $src 'libvips_seds' @'
path = "libvips/iofuncs/util.c"
s = open(path).read()
s = s.replace('tmpd;', 'tmpd;if ((tmpd=g_getenv("VIPS_TMPDIR"))) return(tmpd);')
open(path, "w").write(s)
path = "meson.build"
s = open(path).read()
s = s.replace("cfg_var.set('HAVE_TARGET_CLONES',", "# cfg_var.set('HAVE_TARGET_CLONES',")
open(path, "w").write(s)
path = "libvips/foreign/tiff2vips.c"
s = open(path).read()
s = s.replace('g_logv("tiff2vips", G_LOG_LEVEL_WARNING, fmt, ap);',
              '//g_logv("tiff2vips", G_LOG_LEVEL_WARNING, fmt, ap);')
s = s.replace('g_logv(G_LOG_DOMAIN, G_LOG_LEVEL_WARNING, fmt, ap);',
              '//g_logv(G_LOG_DOMAIN, G_LOG_LEVEL_WARNING, fmt, ap);')
open(path, "w").write(s)
# Windows only: the fuzz targets (test executables, built unconditionally
# with a standalone main) do not compile under MSVC; nothing ships them.
path = "meson.build"
s = open(path).read()
assert "subdir('fuzz')" in s
s = s.replace("subdir('fuzz')", "# subdir('fuzz')  # not under MSVC (wheel build)")
open(path, "w").write(s)
'@
    Meson-Build $src @('-Dmodules=disabled', '-Dexamples=false', '-Dintrospection=disabled', '-Dvapi=false',
        '-Dmagick=enabled', '-Dorc=disabled', '-Dcgif=disabled', '-Dspng=disabled', '-Dpdfium=disabled',
        '-Dquantizr=disabled', '-Duhdr=disabled',
        '-Dcfitsio=enabled', '-Dexif=enabled', '-Dfftw=enabled', '-Dfontconfig=enabled', '-Darchive=enabled',
        '-Dheif=enabled', '-Dimagequant=enabled', '-Djpeg=enabled', '-Djpeg-xl=enabled', '-Dlcms=enabled',
        '-Dmatio=enabled', '-Dnifti=enabled', '-Dopenexr=enabled', '-Dopenjpeg=enabled', '-Dopenslide=enabled',
        '-Dhighway=enabled', '-Dpangocairo=enabled', '-Dpng=enabled', '-Dpoppler=enabled', '-Draw=enabled',
        '-Drsvg=enabled', '-Dtiff=enabled', '-Dwebp=enabled', '-Dzlib=enabled',
        "-Dnifti-prefix-dir=$script:CmakePrefix")
    Log "prefix DLLs: $((Get-ChildItem -Path (Join-Path $LIW_PREFIX 'bin') -Filter '*.dll' | ForEach-Object { $_.Name }) -join ', ')"
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('*vips-42*.dll', 'vips.exe', 'vipsheader.exe', 'vipsthumbnail.exe', 'vipsedit.exe') 'libvips'
    Assert-Files (Join-Path $LIW_PREFIX 'lib') @('vips.lib') 'libvips'
    Assert-Files (Join-Path $LIW_PREFIX 'lib\pkgconfig') @('vips.pc') 'libvips'
    $dll = Get-ChildItem (Join-Path $LIW_PREFIX 'bin') -Filter '*vips-42*.dll' |
        Where-Object { $_.Name -notmatch 'cpp' } | Select-Object -First 1
    $script:VipsDll = $dll.Name
    Assert-DependentStems $dll.FullName @(
        'cfitsio', 'exif', 'fftw3', 'archive', 'heif', 'imagequant', 'jpeg62', 'jxl', 'lcms2', 'libmatio',
        'MagickCore', 'niftiio', 'OpenEXR', 'openjp2', 'libopenslide', 'hwy', 'pangocairo', 'libpng16',
        'poppler-glib', 'libraw', 'rsvg-2', 'tiff', 'libwebp', 'z.dll', 'glib-2.0', 'gobject-2.0') 'libvips'
    Done-Stamp 'libvips'
}

# --------------------------------------------------------------------------
# Packages.
# --------------------------------------------------------------------------

# --- the GDAL tree (giflib through libavif, then GDAL itself): the
# counterpart of the Dockerfile's sections from giflib to libavif and of
# the gdal case of macos/build_wheels.sh.  Windows deviations, each called
# out where it happens: no OpenMPI/parallel-netcdf (hdf5 and netcdf are
# serial), no armadillo (no Fortran for its LAPACK), xerces-c on the
# Windows transcoder, xerces/libxml2 without iconv while win-iconv serves
# the gaia-gis libraries and GDAL's CPLRecode, libpq without ICU and
# readline (as on macos), MySQL's client only; the Windows-only build
# tools are swigwin, fossil's prebuilt binary, Strawberry Perl (OpenSSL's
# Configure and PostgreSQL's meson are perl) and winflexbison (mysql,
# postgresql). ---

# Build tools, pinned through versions.txt like meson, rust and clang-cl;
# none of them reaches a wheel.
function Ensure-Swig {
    $version = V 'swig'
    $dir = Join-Path $LIW_TOOLS 'swig'
    $stamp = Join-Path $dir ".installed-$version"
    if (-not (Test-Path $stamp)) {
        Log "installing swig $version (swigwin)"
        $zip = Fetch "https://downloads.sourceforge.net/project/swig/swigwin/swigwin-$version/swigwin-$version.zip" `
            "swigwin-$version.zip"
        Expand-Zip $zip (Join-Path $LIW_DL 'swigwin')
        if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
        $inner = Get-ChildItem (Join-Path $LIW_DL 'swigwin') -Directory | Select-Object -First 1
        if (-not $inner) { Die 'the swigwin zip has no top-level directory' }
        Move-Item $inner.FullName $dir
        if (-not (Test-Path (Join-Path $dir 'swig.exe'))) { Die 'swig.exe missing after the swigwin extraction' }
        New-Item -ItemType File -Force -Path $stamp | Out-Null
    }
    $script:SwigExe = Join-Path $dir 'swig.exe'
    $out = Capture-Native $script:SwigExe @('-version')
    if ($out -notmatch [regex]::Escape($version)) { Die "swig does not report version ${version}: $out" }
    Log "swig $version at $script:SwigExe"
}

# fossil, for the gaia-gis repositories (freexl, libspatialite,
# librasterlite2); the prebuilt Windows binary of the pinned release.
function Ensure-Fossil {
    $version = V 'fossil'
    $dir = Join-Path $LIW_TOOLS 'fossil'
    $stamp = Join-Path $dir ".installed-$version"
    if (-not (Test-Path $stamp)) {
        Log "installing fossil $version"
        $zip = Fetch "https://fossil-scm.org/home/uv/fossil-w64-$version.zip" "fossil-w64-$version.zip"
        Expand-Zip $zip $dir
        if (-not (Test-Path (Join-Path $dir 'fossil.exe'))) { Die 'fossil.exe missing after the extraction' }
        New-Item -ItemType File -Force -Path $stamp | Out-Null
    }
    $script:FossilExe = Join-Path $dir 'fossil.exe'
    $out = Capture-Native $script:FossilExe @('version')
    if ($out -notmatch [regex]::Escape($version)) { Die "fossil does not report version ${version}: $out" }
    Log "fossil $version at $script:FossilExe"
}

# Strawberry Perl's portable distribution: OpenSSL's Configure and
# PostgreSQL's meson build are perl, and both refuse PortableGit's msys
# perl (POSIX paths).  Only its perl/ tree is extracted (the zip also
# carries a mingw toolchain, which must not be on anyone's PATH).  The
# pin is the release tag's digit string (5.42.3.1 is tagged
# SP_54231_64bit); the dots are restored here.
function Ensure-Perl {
    $digits = V 'strawberry-perl'
    if ($digits -notmatch '^(\d)(\d\d)(\d)(\d)$') { Die "strawberry-perl pin '$digits' is not a 5-digit tag" }
    $version = "$($Matches[1]).$($Matches[2]).$($Matches[3]).$($Matches[4])"
    $dir = Join-Path $LIW_TOOLS 'perl'
    $stamp = Join-Path $dir ".installed-$version"
    if (-not (Test-Path $stamp)) {
        Log "installing Strawberry Perl $version (portable)"
        $zip = Fetch "https://github.com/StrawberryPerl/Perl-Dist-Strawberry/releases/download/SP_$($digits)_64bit/strawberry-perl-$version-64bit-portable.zip" `
            "strawberry-perl-$version-64bit-portable.zip"
        if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        # (The system bsdtar reads zip archives and takes member patterns.)
        & tar.exe -xf $zip -C $dir 'perl/*'
        Assert-Exit 'Strawberry Perl extraction'
        if (-not (Test-Path (Join-Path $dir 'perl\bin\perl.exe'))) { Die 'perl.exe missing after the Strawberry Perl extraction' }
        New-Item -ItemType File -Force -Path $stamp | Out-Null
    }
    $script:PerlBin = Join-Path $dir 'perl\bin'
    # (perl reports the three-part version; the fourth digit is the
    # distribution's.)
    $perlVersion = $version.Substring(0, $version.LastIndexOf('.'))
    $out = Capture-Native (Join-Path $script:PerlBin 'perl.exe') @('-e', 'print $^V')
    if ($out -notmatch [regex]::Escape("v$perlVersion")) { Die "perl does not report version ${perlVersion}: $out" }
    Log "perl $version at $script:PerlBin"
}

# bison and flex for mysql and postgresql, as the winflexbison binaries.
function Ensure-WinFlexBison {
    $version = V 'winflexbison'
    $dir = Join-Path $LIW_TOOLS 'winflexbison'
    $stamp = Join-Path $dir ".installed-$version"
    if (-not (Test-Path $stamp)) {
        Log "installing winflexbison $version"
        $zip = Fetch "https://github.com/lexxmark/winflexbison/releases/download/v$version/win_flex_bison-$version.zip" `
            "win_flex_bison-$version.zip"
        Expand-Zip $zip $dir
        foreach ($exe in @('win_bison.exe', 'win_flex.exe')) {
            if (-not (Test-Path (Join-Path $dir $exe))) { Die "$exe missing after the winflexbison extraction" }
        }
        New-Item -ItemType File -Force -Path $stamp | Out-Null
    }
    $script:WinFlexBisonDir = $dir
    Log "winflexbison $version at $dir"
}

# giflib has only a Makefile (the Dockerfile seds its doc target out);
# the library is eight C files, built here through an embedded cmake file
# with every symbol exported (gif_lib.h has no export decorations).
$script:GiflibCMakeLists = @'
cmake_minimum_required(VERSION 3.16)
project(giflib C)
add_library(gif SHARED dgif_lib.c egif_lib.c gifalloc.c gif_err.c gif_font.c
  gif_hash.c openbsd-reallocarray.c quantize.c)
set_target_properties(gif PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)
target_compile_definitions(gif PRIVATE _CRT_SECURE_NO_WARNINGS _CRT_NONSTDC_NO_DEPRECATE)
install(TARGETS gif RUNTIME DESTINATION bin LIBRARY DESTINATION lib ARCHIVE DESTINATION lib)
install(FILES gif_lib.h DESTINATION include)
'@

function Build-Giflib {
    if (Skip-If-Done 'giflib') { return }
    Log '=== giflib'
    $src = Fetch-Tarball "https://sourceforge.net/projects/giflib/files/giflib-6.x/giflib-$(V giflib).tar.gz/download" `
        'giflib.tar.gz' (Join-Path $LIW_SRC 'giflib')
    Write-Embedded (Join-Path $src 'CMakeLists.txt') $script:GiflibCMakeLists
    Cmake-Build $src
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('gif.dll') 'giflib'
    Assert-Files (Join-Path $LIW_PREFIX 'lib') @('gif.lib') 'giflib'
    Done-Stamp 'giflib'
}

# OpenSSL, pinned at the 3.6.2 tag like the linux and macos builds (the
# Dockerfile ignores versions.txt's 4.x: "openldap doesn't handle version
# 4.x yet").  mysql requires it, libpq and GDAL link it (CPL's crypto);
# curl stays on Schannel (see Build-Curl).  Its Configure is perl
# (Strawberry's; see Ensure-Perl), the assembler is the pinned nasm, and
# nmake builds it single-threaded.  install_sw: no docs, as on linux.
function Build-Openssl {
    if (Skip-If-Done 'openssl') { return }
    Log '=== openssl (pinned 3.6.2; versions.txt''s 4.x is deliberately ignored, like the linux build)'
    Ensure-Perl
    $src = Git-Clone 'https://github.com/openssl/openssl.git' 'openssl-3.6.2' (Join-Path $LIW_SRC 'openssl')
    $savedPath = $env:PATH
    $env:PATH = "$script:PerlBin;$env:PATH"
    Push-Location $src
    try {
        Run-Logged 'perl' @('Configure', 'VC-WIN64A', "--prefix=$LIW_PREFIX", "--openssldir=$LIW_PREFIX\ssl",
            'shared', 'zlib', "--with-zlib-include=$LIW_PREFIX\include", "--with-zlib-lib=$LIW_PREFIX\lib\z.lib",
            'no-tests') 'openssl Configure'
        Run-Logged 'nmake' @('/nologo') 'nmake of openssl'
        Run-Logged 'nmake' @('/nologo', 'install_sw') 'nmake install_sw of openssl'
    } finally {
        Pop-Location
        $env:PATH = $savedPath
    }
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('libcrypto-3-x64.dll', 'libssl-3-x64.dll', 'openssl.exe') 'openssl'
    Assert-Files (Join-Path $LIW_PREFIX 'lib') @('libcrypto.lib', 'libssl.lib') 'openssl'
    # The Windows install writes no pkg-config files; postgresql's meson
    # looks for them (cmake consumers use FindOpenSSL).
    # (Each names its libraries in Libs: Write-PkgConfig's Requires is the
    # private kind, which a dynamic link does not follow.)
    Write-PkgConfig 'libcrypto' 'OpenSSL cryptography library' '3.6.2' '-llibcrypto'
    Write-PkgConfig 'libssl' 'Secure Sockets Layer and cryptography libraries' '3.6.2' '-llibssl -llibcrypto'
    Write-PkgConfig 'openssl' 'Secure Sockets Layer and cryptography libraries and tools' '3.6.2' '-llibssl -llibcrypto'
    Assert-DependentStems (Join-Path $LIW_PREFIX 'bin\libcrypto-3-x64.dll') @('z.dll') 'openssl'
    Done-Stamp 'openssl'
}

function Build-Json-C {
    if (Skip-If-Done 'json-c') { return }
    Log '=== json-c'
    $src = Git-Clone 'https://github.com/json-c/json-c.git' "json-c-$(V json-c)" (Join-Path $LIW_SRC 'json-c')
    Cmake-Build $src @('-DBUILD_TESTING=OFF', '-DBUILD_STATIC_LIBS=OFF', '-DCMAKE_POLICY_VERSION_MINIMUM=3.5')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('json-c.dll') 'json-c'
    Assert-Files (Join-Path $LIW_PREFIX 'lib\pkgconfig') @('json-c.pc') 'json-c'
    Done-Stamp 'json-c'
}

function Build-Lerc {
    if (Skip-If-Done 'lerc') { return }
    Log '=== lerc'
    $src = Git-Clone 'https://github.com/Esri/lerc.git' "v$(V lerc)" (Join-Path $LIW_SRC 'lerc')
    Cmake-Build $src @('-DBUILD_SHARED_LIBS=ON')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('Lerc.dll') 'lerc'
    Assert-Files (Join-Path $LIW_PREFIX 'lib') @('Lerc.lib') 'lerc'
    Done-Stamp 'lerc'
}

# win-iconv: the iconv API over Windows' own code pages (the linux build
# has glibc's iconv, macos the system's).  freexl and libspatialite link
# it (their MSVC makefiles say so), and GDAL's CPLRecode uses it.
function Build-Win-Iconv {
    if (Skip-If-Done 'win-iconv') { return }
    Log '=== win-iconv'
    $src = Git-Clone 'https://github.com/win-iconv/win-iconv.git' "v$(V win-iconv)" (Join-Path $LIW_SRC 'win-iconv')
    Cmake-Build $src @('-DBUILD_SHARED=ON', '-DBUILD_STATIC=OFF', '-DBUILD_EXECUTABLE=OFF', '-DBUILD_TEST=OFF',
        '-DCMAKE_POLICY_VERSION_MINIMUM=3.5')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('iconv.dll') 'win-iconv'
    Assert-Files (Join-Path $LIW_PREFIX 'lib') @('iconv.lib') 'win-iconv'
    Assert-Files (Join-Path $LIW_PREFIX 'include') @('iconv.h') 'win-iconv'
    # GDAL's FindIconv also requires a charset library (GNU libiconv's
    # libcharset) whenever iconv is not the C library's; win-iconv has no
    # such library, so the name resolves to the same import library.
    Copy-Item (Join-Path $LIW_PREFIX 'lib\iconv.lib') (Join-Path $LIW_PREFIX 'lib\charset.lib') -Force
    Done-Stamp 'win-iconv'
}

function Build-Libgeos {
    if (Skip-If-Done 'libgeos') { return }
    Log '=== libgeos'
    $src = Git-Clone 'https://github.com/libgeos/geos.git' "$(V libgeos)" (Join-Path $LIW_SRC 'geos')
    Cmake-Build $src @('-DGEOS_BUILD_DEVELOPER=NO', '-DBUILD_TESTING=OFF', '-DBUILD_SHARED_LIBS=ON')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('geos.dll', 'geos_c.dll') 'libgeos'
    Assert-Files (Join-Path $LIW_PREFIX 'lib') @('geos_c.lib') 'libgeos'
    # geos installs its cmake config only on Windows (geos.pc comes from
    # its geos-config script elsewhere); librttopo and libspatialite look
    # it up through pkg-config.
    if (-not (Test-Path (Join-Path $LIW_PREFIX 'lib\pkgconfig\geos.pc'))) {
        Write-PkgConfig 'geos' 'Geometry Engine - Open Source (C API)' (V libgeos) '-lgeos_c'
    }
    Done-Stamp 'libgeos'
}

# PROJ from its cmake build, like the linux build; the sqlite3 shell from
# Build-Sqlite generates proj.db.  The tools (proj, cs2cs, ...) are
# bundled by the GDAL wheel.
function Build-Proj4 {
    if (Skip-If-Done 'proj4') { return }
    Log '=== proj4'
    $src = Git-Clone 'https://github.com/OSGeo/proj.4.git' "$(V proj4)" (Join-Path $LIW_SRC 'proj4')
    Cmake-Build $src @('-DBUILD_TESTING=OFF', '-DBUILD_SHARED_LIBS=ON', '-DBUILD_APPS=ON')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('proj*.dll', 'proj.exe', 'cs2cs.exe', 'projinfo.exe') 'proj4'
    Assert-Files (Join-Path $LIW_PREFIX 'lib') @('proj.lib') 'proj4'
    Assert-Files (Join-Path $LIW_PREFIX 'share\proj') @('proj.db') 'proj4'
    Assert-Files (Join-Path $LIW_PREFIX 'lib\pkgconfig') @('proj.pc') 'proj4'
    # proj.pc says -lproj_9 (the DLL's name, proj_9.dll) while the import
    # library installs as proj.lib; the pkg-config consumers (spatialite,
    # rasterlite2) need the .pc's spelling.
    $pc = Get-Content (Join-Path $LIW_PREFIX 'lib\pkgconfig\proj.pc') -Raw
    if ($pc -match '(?m)^Libs:.*-l(proj\S*)') {
        $spelling = Join-Path $LIW_PREFIX "lib\$($Matches[1]).lib"
        if (-not (Test-Path $spelling)) { Copy-Item (Join-Path $LIW_PREFIX 'lib\proj.lib') $spelling }
    }
    $dll = (Get-ChildItem (Join-Path $LIW_PREFIX 'bin') -Filter 'proj*.dll' | Select-Object -First 1).FullName
    Assert-DependentStems $dll @('tiff', 'sqlite3', 'libcurl') 'proj4'
    Done-Stamp 'proj4'
}

# libgeotiff from its cmake build (the linux build's autotools reason --
# librasterlite2's configure not finding a cmake-built libgeotiff -- does
# not apply: librasterlite2 is built from an embedded cmake file here).
# The utilities (listgeo and friends) are bundled by the GDAL wheel.
function Build-Libgeotiff {
    if (Skip-If-Done 'libgeotiff') { return }
    Log '=== libgeotiff'
    $src = Git-Clone 'https://github.com/OSGeo/libgeotiff.git' "$(V libgeotiff)" (Join-Path $LIW_SRC 'libgeotiff')
    Cmake-Build (Join-Path $src 'libgeotiff') @('-DWITH_JPEG=ON', '-DWITH_ZLIB=ON', '-DWITH_UTILITIES=ON',
        '-DBUILD_SHARED_LIBS=ON')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('geotiff.dll', 'listgeo.exe', 'geotifcp.exe') 'libgeotiff'
    # The import library installs as geotiff_i.lib (GDAL's FindGeoTIFF
    # knows that name); rasterlite2's lookup and pkg-config consumers
    # want geotiff.lib.
    Assert-Files (Join-Path $LIW_PREFIX 'lib') @('geotiff_i.lib') 'libgeotiff'
    Copy-Item (Join-Path $LIW_PREFIX 'lib\geotiff_i.lib') (Join-Path $LIW_PREFIX 'lib\geotiff.lib') -Force
    Assert-Files (Join-Path $LIW_PREFIX 'include') @('geotiff.h') 'libgeotiff'
    # (The autotools library links jpeg and zlib too; the cmake one links
    # them into the utilities only, libtiff carrying both for the library.)
    Assert-DependentStems (Join-Path $LIW_PREFIX 'bin\geotiff.dll') @('proj', 'tiff') 'libgeotiff'
    Done-Stamp 'libgeotiff'
}

# minizip-ng, for freexl (its MSVC makefile links it) and libOpenDRIVE;
# MZ_OPENSSL mirrors the linux build.  MZ_FETCH_LIBS (on by default on
# Windows) is off so the prefix's zlib, bzip2, lzma and zstd are used.
function Build-Minizip {
    if (Skip-If-Done 'minizip') { return }
    Log '=== minizip'
    $src = Git-Clone 'https://github.com/zlib-ng/minizip-ng.git' "$(V minizip)" (Join-Path $LIW_SRC 'minizip')
    # (Export-all: the sources carry no dllexport decorations, so an MSVC
    # DLL build would otherwise export nothing and install no import
    # library.)
    Cmake-Build $src @('-DBUILD_SHARED_LIBS=ON', '-DMZ_OPENSSL=ON', '-DMZ_FETCH_LIBS=OFF', '-DMZ_BUILD_TESTS=OFF',
        '-DMZ_BUILD_UNIT_TESTS=OFF', '-DMZ_ZLIB=ON', '-DMZ_BZIP2=ON', '-DMZ_LZMA=ON', '-DMZ_ZSTD=ON',
        '-DCMAKE_WINDOWS_EXPORT_ALL_SYMBOLS=ON')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('minizip.dll') 'minizip'
    Assert-Files (Join-Path $LIW_PREFIX 'lib') @('minizip.lib') 'minizip'
    Assert-Files (Join-Path $LIW_PREFIX 'lib\pkgconfig') @('minizip.pc') 'minizip'
    Done-Stamp 'minizip'
}

function Build-Libgta {
    if (Skip-If-Done 'libgta') { return }
    Log '=== libgta'
    $src = Git-Clone 'https://github.com/marlam/gta-mirror.git' "libgta-$(V libgta)" (Join-Path $LIW_SRC 'gta-mirror')
    Cmake-Build (Join-Path $src 'libgta') @('-DGTA_BUILD_DOCUMENTATION=OFF', '-DGTA_BUILD_STATIC_LIB=OFF')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('*gta*.dll') 'libgta'
    Assert-Files (Join-Path $LIW_PREFIX 'lib\pkgconfig') @('gta.pc') 'libgta'
    Done-Stamp 'libgta'
}

# xerces-c on its Windows transcoder (the linux build passes
# -Dtranscoder=iconv, glibc's; win-iconv is not the GNU iconv its
# transcoder expects).
function Build-Xerces-C {
    if (Skip-If-Done 'xerces-c') { return }
    Log '=== xerces-c'
    $src = Git-Clone 'https://github.com/apache/xerces-c.git' "v$(V xerces-c)" (Join-Path $LIW_SRC 'xerces-c')
    Cmake-Build $src @('-Dtranscoder=windows', '-DBUILD_SHARED_LIBS=ON')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('xerces-c*.dll') 'xerces-c'
    Done-Stamp 'xerces-c'
}

function Build-Blosc {
    if (Skip-If-Done 'blosc') { return }
    Log '=== blosc'
    $src = Git-Clone 'https://github.com/Blosc/c-blosc.git' "v$(V blosc)" (Join-Path $LIW_SRC 'c-blosc')
    Cmake-Build $src @('-DBUILD_SHARED=ON', '-DBUILD_STATIC=OFF', '-DBUILD_BENCHMARKS=OFF', '-DBUILD_FUZZERS=OFF',
        '-DBUILD_TESTS=OFF', '-DPREFER_EXTERNAL_LZ4=ON', '-DPREFER_EXTERNAL_ZLIB=ON', '-DPREFER_EXTERNAL_ZSTD=ON',
        '-DDEACTIVATE_SNAPPY=OFF', '-DCMAKE_POLICY_VERSION_MINIMUM=3.5')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('blosc.dll') 'blosc'
    Assert-DependentStems (Join-Path $LIW_PREFIX 'bin\blosc.dll') @('lz4', 'zstd', 'z.dll') 'blosc'
    Done-Stamp 'blosc'
}

# highfive (header-only; kealib's).  Its submodules carry its third-party
# headers, so the clone recurses (an inline retry loop, like libjxl's).
function Build-Highfive {
    if (Skip-If-Done 'highfive') { return }
    Log '=== highfive'
    $src = Join-Path $LIW_SRC 'highfive'
    for ($n = 1; $n -le 10; $n++) {
        if (Test-Path $src) { Remove-Item -Recurse -Force $src }
        & git clone --depth=1 --single-branch -b "v$(V highfive)" -c advice.detachedHead=false `
            --recurse-submodules --shallow-submodules -j $LIW_JOBS https://github.com/highfive-devs/highfive.git $src
        if ($LASTEXITCODE -eq 0) { break }
        Log 'retrying git clone: highfive'
        Start-Sleep -Seconds 5
    }
    if (-not (Test-Path (Join-Path $src 'CMakeLists.txt'))) { Die 'git clone failed after 10 attempts: highfive' }
    Cmake-Build $src @('-DHIGHFIVE_UNIT_TESTS=OFF', '-DHIGHFIVE_BUILD_DOCS=OFF', '-DHIGHFIVE_EXAMPLES=OFF',
        '-DHIGHFIVE_USE_BOOST=OFF')
    if (-not (Test-Path (Join-Path $LIW_PREFIX 'include\highfive'))) { Die 'highfive did not install its headers' }
    Done-Stamp 'highfive'
}

# kealib (the KEA driver); needs hdf5's C++ library (HDF5_BUILD_CPP_LIB).
function Build-Kealib {
    if (Skip-If-Done 'kealib') { return }
    Log '=== kealib'
    $src = Git-Clone 'https://github.com/ubarsc/kealib.git' "kealib-$(V kealib)" (Join-Path $LIW_SRC 'kealib')
    Cmake-Build $src @('-DBUILD_SHARED_LIBS=ON', '-DLIBKEA_WITH_GDAL=OFF')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('*kea*.dll') 'kealib'
    $dll = (Get-ChildItem (Join-Path $LIW_PREFIX 'bin') -Filter '*kea*.dll' | Select-Object -First 1).FullName
    Assert-DependentStems $dll @('hdf5') 'kealib'
    Done-Stamp 'kealib'
}

# hdf4 (the HDF4 driver), static like the linux build (its default), so
# GDAL absorbs it.  The zlib and jpeg finds get the hdf5 treatment: the
# config-mode find (COMPONENTS static shared) is steered past our
# shared-only packages and the module variables are preset.
function Build-Hdf4 {
    if (Skip-If-Done 'hdf4') { return }
    Log '=== hdf4'
    $src = Git-Clone 'https://github.com/HDFGroup/hdf4.git' "hdf-$(V hdf4)" (Join-Path $LIW_SRC 'hdf4')
    Cmake-Build $src @('-DHDF4_BUILD_FORTRAN=OFF', '-DHDF4_ENABLE_NETCDF=OFF', '-DHDF4_ENABLE_Z_LIB_SUPPORT=ON',
        '-DHDF4_ENABLE_JPEG_SUPPORT=ON', '-DHDF4_DISABLE_COMPILER_WARNINGS=ON', '-DBUILD_TESTING=OFF',
        '-DHDF4_BUILD_TOOLS=OFF', '-DHDF4_BUILD_UTILS=OFF', '-DHDF4_BUILD_EXAMPLES=OFF',
        '-DZLIB_PACKAGE_NAME=zlib-no-config', '-DJPEG_PACKAGE_NAME=jpeg-no-config',
        "-DZLIB_LIBRARY=$script:CmakePrefix/lib/z.lib", "-DZLIB_LIBRARIES=$script:CmakePrefix/lib/z.lib",
        "-DZLIB_INCLUDE_DIR=$script:CmakePrefix/include",
        "-DJPEG_LIBRARY=$script:CmakePrefix/lib/jpeg.lib", "-DJPEG_LIBRARIES=$script:CmakePrefix/lib/jpeg.lib",
        "-DJPEG_INCLUDE_DIR=$script:CmakePrefix/include")
    Assert-Files (Join-Path $LIW_PREFIX 'lib') @('*hdf*.lib', '*mfhdf*.lib') 'hdf4'
    Assert-Files (Join-Path $LIW_PREFIX 'include') @('hdf.h', 'mfhdf.h') 'hdf4'
    Done-Stamp 'hdf4'
}

# netcdf (the netCDF driver), serial: no OpenMPI on Windows, so no
# parallel hdf5 and no parallel-netcdf (the one deviation from the linux
# final state; HDF4 in netcdf is inert there too).  DAP, byte-range and
# NCZarr on, as on linux; no utilities, tests, examples or plugins.
function Build-Netcdf {
    if (Skip-If-Done 'netcdf') { return }
    Log '=== netcdf'
    $src = Git-Clone 'https://github.com/Unidata/netcdf-c' "v$(V netcdf)" (Join-Path $LIW_SRC 'netcdf-c')
    # The linux seds: strlen used as a variable name.
    Invoke-Patch $src 'netcdf_zutil' @'
path = "libnczarr/zutil.c"
s = open(path).read()
s = s.replace("int strlen,", "int strlenn,").replace("format,strlen)", "format,strlenn)")
open(path, "w").write(s)
'@
    Cmake-Build $src @('-DBUILD_SHARED_LIBS=ON', '-DNETCDF_ENABLE_TESTS=OFF', '-DNETCDF_ENABLE_EXAMPLES=OFF',
        '-DNETCDF_BUILD_UTILITIES=OFF', '-DNETCDF_ENABLE_DAP=ON', '-DNETCDF_ENABLE_BYTERANGE=ON',
        '-DNETCDF_ENABLE_HDF5=ON', '-DNETCDF_ENABLE_NCZARR=ON', '-DNETCDF_ENABLE_HDF4=OFF',
        '-DNETCDF_ENABLE_PNETCDF=OFF', '-DNETCDF_ENABLE_PARALLEL4=OFF', '-DNETCDF_ENABLE_PLUGINS=OFF',
        '-DNETCDF_ENABLE_FILTER_TESTING=OFF', '-DNETCDF_ENABLE_UNIT_TESTS=OFF', '-DNETCDF_ENABLE_DAP_REMOTE_TESTS=OFF')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('netcdf.dll') 'netcdf'
    Assert-Files (Join-Path $LIW_PREFIX 'lib\pkgconfig') @('netcdf.pc') 'netcdf'
    Assert-DependentStems (Join-Path $LIW_PREFIX 'bin\netcdf.dll') @('hdf5', 'libcurl') 'netcdf'
    Done-Stamp 'netcdf'
}

# libOpenDRIVE (the XODR driver), at the same 0.6.0-gdal tag both other
# builds pin ("version 0.6.1-gdal requires external pugixml and some
# other work"; versions.txt tracks the newer tag).  A static library GDAL
# absorbs, as on linux.
function Build-Libopendrive {
    if (Skip-If-Done 'libopendrive') { return }
    Log '=== libopendrive (pinned 0.6.0-gdal, like the linux and macos builds)'
    $src = Git-Clone 'https://github.com/DLR-TS/libOpenDRIVE.git' '0.6.0-gdal' (Join-Path $LIW_SRC 'libOpenDRIVE')
    # Windows only: its CMakeLists replaces CMAKE_CXX_FLAGS for MSVC, so
    # the M_PI define (_USE_MATH_DEFINES) goes into that line (and /Wall
    # becomes /W1: the former floods the log with STL warnings).
    Invoke-Patch $src 'libopendrive_msvc_flags' @'
path = "CMakeLists.txt"
s = open(path).read()
old = 'set(CMAKE_CXX_FLAGS "/EHsc /Wall")'
assert old in s, "libOpenDRIVE's MSVC flags line changed"
s = s.replace(old, 'set(CMAKE_CXX_FLAGS "/EHsc /W1 /D_USE_MATH_DEFINES")')
open(path, "w").write(s)
'@
    Cmake-Build $src @('-DCMAKE_POSITION_INDEPENDENT_CODE=ON')
    Assert-Files (Join-Path $LIW_PREFIX 'lib') @('OpenDrive.lib') 'libopendrive'
    Done-Stamp 'libopendrive'
}

# libavif (the AVIF driver), with its local libyuv (the googlesource URL
# the Dockerfile seds away serves a captcha) and, like the linux build, no
# AV1 codec library.
function Build-Libavif {
    if (Skip-If-Done 'libavif') { return }
    Log '=== libavif'
    $src = Git-Clone 'https://github.com/AOMediaCodec/libavif.git' "v$(V libavif)" (Join-Path $LIW_SRC 'libavif')
    Invoke-Patch $src 'libavif_libyuv' @'
path = "cmake/Modules/LocalLibyuv.cmake"
s = open(path).read()
assert "https://chromium.googlesource.com/libyuv/libyuv" in s
s = s.replace("https://chromium.googlesource.com/libyuv/libyuv", "https://github.com/lemenkov/libyuv")
open(path, "w").write(s)
'@
    Cmake-Build $src @('-DBUILD_SHARED_LIBS=ON', '-DCMAKE_POSITION_INDEPENDENT_CODE=ON', '-DAVIF_LIBYUV=LOCAL',
        '-DAVIF_BUILD_APPS=OFF', '-DAVIF_BUILD_TESTS=OFF', '-DAVIF_BUILD_EXAMPLES=OFF')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('avif.dll') 'libavif'
    Assert-Files (Join-Path $LIW_PREFIX 'lib\pkgconfig') @('libavif.pc') 'libavif'
    Done-Stamp 'libavif'
}

# fyba (the SOSI driver), from its own cmake files -- static libraries,
# which GDAL absorbs (the linux build's autotools makes shared ones).
# The code is Windows-born (stdafx.h, WIN32 ifdefs); its cmake files only
# add flags for UNIX, so the Windows ones go in through CMAKE_CXX_FLAGS.
# GDAL's FindFYBA wants fyba, fygm and fyut; the cmake targets are fyba,
# gm and ut, so two copies are made.  The FYLU.cpp patch (stdafx.h after
# <locale>) mirrors the linux build.  Master tip, like both other builds.
function Build-Fyba {
    if (Skip-If-Done 'fyba') { return }
    Log '=== fyba'
    $src = Git-Clone 'https://github.com/kartverket/fyba.git' '' (Join-Path $LIW_SRC 'fyba')
    Invoke-Patch $src 'fyba_fylu' @'
path = "src/FYBA/FYLU.cpp"
data = open(path, "rb").read()
data = data.replace(b"#include \"stdafx.h\"", b"")
data = data.replace(b"#include <locale>", b"#include <locale>\n#include \"stdafx.h\"")
open(path, "wb").write(data)
# Windows only: the cmake files predate cmake_minimum_required, which
# cmake 4 refuses to configure without.
path = "CMakeLists.txt"
s = open(path).read()
if "cmake_minimum_required" not in s:
    open(path, "w").write("cmake_minimum_required(VERSION 3.16)\n" + s)
'@
    Cmake-Build $src @('-DCMAKE_CXX_FLAGS=/DWIN32 /D_CRT_SECURE_NO_WARNINGS /D_CRT_NONSTDC_NO_DEPRECATE /EHsc /W1')
    $lib = Join-Path $LIW_PREFIX 'lib'
    Assert-Files $lib @('fyba.lib', 'gm.lib', 'ut.lib') 'fyba'
    Copy-Item (Join-Path $lib 'gm.lib') (Join-Path $lib 'fygm.lib') -Force
    Copy-Item (Join-Path $lib 'ut.lib') (Join-Path $lib 'fyut.lib') -Force
    Assert-Files (Join-Path $LIW_PREFIX 'include\fyba') @('fyba.h', 'fygm.h', 'fyut.h') 'fyba'
    Done-Stamp 'fyba'
}

# The gaia-gis libraries (freexl, librttopo, libspatialite, librasterlite2)
# are autotools projects whose Windows support is a hand-maintained
# makefile.vc (freexl, rttopo, spatialite; OSGeo4W paths and library
# names hard-coded into it) or nothing (rasterlite2).  Each is built here
# through an embedded cmake file that takes the source list from the
# makefile.vc where there is one, the MSVC config headers the projects
# ship (config-msvc.h, gaiaconfig-msvc.h), and the prefix's libraries
# through pkg-config.  The sources come from the gaia-gis fossil
# repositories, as on linux and macos.
function Fossil-Clone([string]$Url, [string]$Dest, [string]$Checkout = '') {
    Ensure-Fossil
    if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
    $repo = "$Dest.fossil"
    Remove-Item -Path $repo -Force -ErrorAction SilentlyContinue
    # (--admin-user root: the clone seeds the repository's user table from
    # --admin-user, or $USER when absent, and user_select() dies on a
    # global --user the repository does not have -- the macos finding.)
    # (Run-Logged: fossil reports its progress on stderr, which a bare call
    # turns into a terminating error under Windows PowerShell.)
    $code = 1
    for ($n = 1; $n -le 5; $n++) {
        $code = Run-Logged $script:FossilExe @('--user=root', 'clone', '--admin-user', 'root', $Url, $repo) `
            "fossil clone of $Url" -NoDie
        if ($code -eq 0) { break }
        Remove-Item -Path $repo -Force -ErrorAction SilentlyContinue
        Log "retrying fossil clone: $Url"
        Start-Sleep -Seconds 5
    }
    if ($code -ne 0 -or -not (Test-Path $repo)) { Die "fossil clone failed after 5 attempts: $Url" }
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    Push-Location $Dest
    try {
        Run-Logged $script:FossilExe @('open', $repo) "fossil open of $repo"
        if ($Checkout) {
            Run-Logged $script:FossilExe @('checkout', '-f', $Checkout) "fossil checkout of $Checkout"
        }
    } finally {
        Pop-Location
    }
    return $Dest
}

# The source list of a gaia-gis makefile.vc (LIBOBJ = a\b.obj \ ...), as
# C paths; shared by the spatialite and rttopo cmake files.
$script:GaiaCMakeSources = @'
function(gaia_sources_from_makefile out)
  file(READ ${CMAKE_SOURCE_DIR}/makefile.vc MK)
  string(REPLACE "\\\n" " " MK "${MK}")
  string(REGEX MATCH "LIBOBJ[ \t]*=[ \t]*([^\n]*)" _m "${MK}")
  string(REGEX REPLACE "[ \t]+" ";" OBJS "${CMAKE_MATCH_1}")
  set(SRC "")
  foreach(o ${OBJS})
    if(o MATCHES "\\.obj$")
      string(REGEX REPLACE "\\.obj$" ".c" c "${o}")
      string(REPLACE "\\" "/" c "${c}")
      list(APPEND SRC ${CMAKE_SOURCE_DIR}/${c})
    endif()
  endforeach()
  list(LENGTH SRC n)
  if(n LESS 1)
    message(FATAL_ERROR "no LIBOBJ sources found in makefile.vc")
  endif()
  set(${out} ${SRC} PARENT_SCOPE)
endfunction()
function(gaia_pc name description version libs requires)
  file(WRITE ${CMAKE_BINARY_DIR}/${name}.pc
"prefix=${CMAKE_INSTALL_PREFIX}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: ${name}
Description: ${description}
Version: ${version}
Requires: ${requires}
Libs: -L\${libdir} ${libs}
Cflags: -I\${includedir}
")
  install(FILES ${CMAKE_BINARY_DIR}/${name}.pc DESTINATION lib/pkgconfig)
endfunction()
'@

$script:FreexlCMakeLists = @'
cmake_minimum_required(VERSION 3.16)
project(freexl C)
include(gaia.cmake)
find_package(PkgConfig REQUIRED)
pkg_check_modules(DEPS REQUIRED IMPORTED_TARGET expat minizip zlib)
find_library(ICONV_LIBRARY NAMES iconv REQUIRED)
file(STRINGS ${CMAKE_SOURCE_DIR}/config-msvc.h VERSION_LINE REGEX "^#define VERSION ")
string(REGEX MATCH "\"([^\"]+)\"" _ "${VERSION_LINE}")
set(VERSION "${CMAKE_MATCH_1}")
add_library(freexl SHARED src/freexl.c src/freexl_xlsx.c src/freexl_ods.c)
target_include_directories(freexl PRIVATE ${CMAKE_SOURCE_DIR} ${CMAKE_SOURCE_DIR}/headers)
target_compile_definitions(freexl PRIVATE DLL_EXPORT _CRT_SECURE_NO_WARNINGS _CRT_NONSTDC_NO_DEPRECATE)
target_link_libraries(freexl PRIVATE PkgConfig::DEPS ${ICONV_LIBRARY})
install(TARGETS freexl RUNTIME DESTINATION bin ARCHIVE DESTINATION lib)
install(FILES headers/freexl.h DESTINATION include)
gaia_pc(freexl "a library for direct reading of Excel files" "${VERSION}" "-lfreexl" "")
'@

# Used by GDAL's XLS driver.  The fossil trunk tip, like both other builds.
function Build-Freexl {
    if (Skip-If-Done 'freexl') { return }
    Log '=== freexl'
    $src = Fossil-Clone 'https://www.gaia-gis.it/fossil/freexl' (Join-Path $LIW_SRC 'freexl')
    Write-Embedded (Join-Path $src 'gaia.cmake') $script:GaiaCMakeSources
    Write-Embedded (Join-Path $src 'CMakeLists.txt') $script:FreexlCMakeLists
    Cmake-Build $src
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('freexl.dll') 'freexl'
    Assert-Files (Join-Path $LIW_PREFIX 'lib\pkgconfig') @('freexl.pc') 'freexl'
    Assert-DependentStems (Join-Path $LIW_PREFIX 'bin\freexl.dll') @('iconv', 'libexpat', 'minizip') 'freexl'
    Done-Stamp 'freexl'
}

$script:RttopoCMakeLists = @'
cmake_minimum_required(VERSION 3.16)
project(librttopo C)
include(gaia.cmake)
find_package(PkgConfig REQUIRED)
pkg_check_modules(GEOS REQUIRED IMPORTED_TARGET geos)
file(READ ${CMAKE_SOURCE_DIR}/configure.ac AC)
string(REGEX MATCH "AC_INIT\\(librttopo, ([0-9.]+)," _ "${AC}")
set(VERSION "${CMAKE_MATCH_1}")
# What configure generates: rttopo_config.h (the GEOS version as
# major+minor, e.g. 315) and librttopo_geom.h from its .in.
string(REGEX MATCH "^([0-9]+)\\.([0-9]+)" _ "${GEOS_VERSION}")
set(GEN ${CMAKE_BINARY_DIR}/generated)
file(WRITE ${GEN}/rttopo_config.h
"#define LIBRTGEOM_VERSION \"${VERSION}\"
#define RTGEOM_GEOS_VERSION ${CMAKE_MATCH_1}${CMAKE_MATCH_2}
#define RTGEOM_DEBUG_LEVEL 0
#define NDEBUG 1
#define HAVE_ISFINITE 1
")
set(SRID_MAX 999999)
set(SRID_USR_MAX 998999)
configure_file(${CMAKE_SOURCE_DIR}/headers/librttopo_geom.h.in ${GEN}/librttopo_geom.h @ONLY)
gaia_sources_from_makefile(SRC)
add_library(librttopo SHARED ${SRC})
# (No export decorations anywhere in rttopo; without this the DLL would
# export nothing and the linker would drop its whole body.)
set_target_properties(librttopo PROPERTIES PREFIX "" WINDOWS_EXPORT_ALL_SYMBOLS ON)
target_include_directories(librttopo PRIVATE ${GEN} ${CMAKE_SOURCE_DIR}/headers ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR})
target_compile_definitions(librttopo PRIVATE DLL_EXPORT _CRT_SECURE_NO_WARNINGS _CRT_NONSTDC_NO_DEPRECATE _USE_MATH_DEFINES)
target_link_libraries(librttopo PRIVATE PkgConfig::GEOS)
install(TARGETS librttopo RUNTIME DESTINATION bin ARCHIVE DESTINATION lib)
file(GLOB HEADERS ${CMAKE_SOURCE_DIR}/headers/*.h)
install(FILES ${HEADERS} ${GEN}/librttopo_geom.h DESTINATION include)
gaia_pc(rttopo "RT Topology Library" "${VERSION}" "-llibrttopo" "geos")
'@

# Used by libspatialite.  Master at the commit versions.txt's librttopo-sha
# names, not the librttopo release tag the other builds use: spatialite's
# trunk calls rtt_tpsnap, which exists only after the 1.1.0 tag.  The
# linux link tolerates the undefined symbol in a shared library (and
# would fail at the first call), MSVC's link does not.
function Build-Librttopo {
    if (Skip-If-Done 'librttopo') { return }
    Log '=== librttopo'
    $src = Git-Clone 'https://gitlab.com/rttopo/rttopo.git' '' (Join-Path $LIW_SRC 'rttopo')
    & git -C $src fetch -q --depth=1000 origin
    & git -C $src checkout -q "$(V librttopo-sha)"
    Assert-Exit "git checkout of rttopo $(V librttopo-sha)"
    Write-Embedded (Join-Path $src 'gaia.cmake') $script:GaiaCMakeSources
    Write-Embedded (Join-Path $src 'CMakeLists.txt') $script:RttopoCMakeLists
    Cmake-Build $src
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('librttopo.dll') 'librttopo'
    Assert-Files (Join-Path $LIW_PREFIX 'lib\pkgconfig') @('rttopo.pc') 'librttopo'
    Assert-DependentStems (Join-Path $LIW_PREFIX 'bin\librttopo.dll') @('geos_c') 'librttopo'
    Done-Stamp 'librttopo'
}

$script:SpatialiteCMakeLists = @'
cmake_minimum_required(VERSION 3.16)
project(spatialite C)
include(gaia.cmake)
find_package(PkgConfig REQUIRED)
pkg_check_modules(DEPS REQUIRED IMPORTED_TARGET proj geos freexl sqlite3 zlib libxml-2.0 rttopo)
find_library(ICONV_LIBRARY NAMES iconv REQUIRED)
file(STRINGS ${CMAKE_SOURCE_DIR}/src/headers/spatialite/gaiaconfig-msvc.h VERSION_LINE REGEX "^#define SPATIALITE_VERSION ")
string(REGEX MATCH "\"([^\"]+)\"" _ "${VERSION_LINE}")
set(VERSION "${CMAKE_MATCH_1}")
gaia_sources_from_makefile(SRC)
# Two libraries the makefile.vc predates (src/Makefile.am's LIBADD has
# both): the bulk R*Tree loader and the connection cache.
list(APPEND SRC
  ${CMAKE_SOURCE_DIR}/src/sqlite_bulk_rtree/sqlite_rtree_bulk_load.c
  ${CMAKE_SOURCE_DIR}/src/sqlite_bulk_rtree/RTreeBulkLoad.c
  ${CMAKE_SOURCE_DIR}/src/connection_cache/alloc_cache.c
  ${CMAKE_SOURCE_DIR}/src/connection_cache/gg_sequence.c)
add_library(spatialite SHARED ${SRC})
target_include_directories(spatialite PRIVATE ${CMAKE_SOURCE_DIR} ${CMAKE_SOURCE_DIR}/src/headers ${CMAKE_SOURCE_DIR}/src/topology)
target_compile_definitions(spatialite PRIVATE DLL_EXPORT YY_NO_UNISTD_H _CRT_SECURE_NO_WARNINGS _CRT_NONSTDC_NO_DEPRECATE _USE_MATH_DEFINES)
target_link_libraries(spatialite PRIVATE PkgConfig::DEPS ${ICONV_LIBRARY})
install(TARGETS spatialite RUNTIME DESTINATION bin ARCHIVE DESTINATION lib)
install(FILES src/headers/spatialite.h DESTINATION include)
file(GLOB HEADERS ${CMAKE_SOURCE_DIR}/src/headers/spatialite/*.h)
install(FILES ${HEADERS} DESTINATION include/spatialite)
gaia_pc(spatialite "Spatial SQL on top of SQLite" "${VERSION}" "-lspatialite" "sqlite3")
'@

# Used by GDAL and mapnik.  The fossil trunk tip (like the linux build;
# its fossil checkout pin is commented out there too).
function Build-Libspatialite {
    if (Skip-If-Done 'libspatialite') { return }
    Log '=== libspatialite'
    $src = Fossil-Clone 'https://www.gaia-gis.it/fossil/libspatialite' (Join-Path $LIW_SRC 'libspatialite')
    Write-Embedded (Join-Path $src 'gaia.cmake') $script:GaiaCMakeSources
    Write-Embedded (Join-Path $src 'CMakeLists.txt') $script:SpatialiteCMakeLists
    Cmake-Build $src
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('spatialite.dll') 'libspatialite'
    Assert-Files (Join-Path $LIW_PREFIX 'lib\pkgconfig') @('spatialite.pc') 'libspatialite'
    Assert-DependentStems (Join-Path $LIW_PREFIX 'bin\spatialite.dll') @('geos_c', 'proj', 'freexl', 'librttopo', 'libxml2', 'sqlite3') 'libspatialite'
    Done-Stamp 'libspatialite'
}

$script:Rasterlite2CMakeLists = @'
cmake_minimum_required(VERSION 3.16)
project(rasterlite2 C)
include(gaia.cmake)
find_package(PkgConfig REQUIRED)
pkg_check_modules(DEPS REQUIRED IMPORTED_TARGET sqlite3 spatialite libpng libjpeg libtiff-4 libwebp
  libopenjp2 liblzma liblz4 libzstd libcurl libxml-2.0 freetype2 fontconfig cairo zlib)
find_library(GIF_LIBRARY NAMES gif REQUIRED)
find_library(GEOTIFF_LIBRARY NAMES geotiff REQUIRED)
file(READ ${CMAKE_SOURCE_DIR}/configure.ac AC)
string(REGEX MATCH "AC_INIT\\(librasterlite2, ([^,]+)," _ "${AC}")
set(VERSION "${CMAKE_MATCH_1}")
set(GEN ${CMAKE_BINARY_DIR}/generated)
# config.h as configure would write it for this prefix (no leptonica, no
# fcgi: those are the tools' dependencies, not the library's), and
# rl2config.h from its template with every codec on.
file(WRITE ${GEN}/config.h
"#define VERSION \"${VERSION}\"
#define PACKAGE_VERSION \"${VERSION}\"
#define PACKAGE_NAME \"librasterlite2\"
#define PACKAGE_STRING \"librasterlite2 ${VERSION}\"
#define HAVE_FLOAT_H 1
#define HAVE_GIF_LIB_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_JERROR_H 1
#define HAVE_JPEGLIB_H 1
#define HAVE_LIBGEOTIFF 1
#define HAVE_LIBGIF 1
#define HAVE_LIBJPEG 1
#define HAVE_LIBTIFF 1
#define HAVE_MATH_H 1
#define HAVE_MEMORY_H 1
#define HAVE_PNG_H 1
#define HAVE_SQLITE3EXT_H 1
#define HAVE_SQLITE3_H 1
#define HAVE_SQRT 1
#define HAVE_STDINT_H 1
#define HAVE_STDIO_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRERROR 1
#define HAVE_STRFTIME 1
#define HAVE_STRING_H 1
#define HAVE_STRSTR 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_ZLIB_H 1
#define STDC_HEADERS 1
#define OMIT_LEPTONICA 1
")
file(READ ${CMAKE_SOURCE_DIR}/headers/rasterlite2/rl2config.h.in RL2CFG)
string(REPLACE "#undef RL2_VERSION" "#define RL2_VERSION \"${VERSION}\"" RL2CFG "${RL2CFG}")
string(REPLACE "#undef RL2_TARGET_CPU" "#define RL2_TARGET_CPU \"x86_64-pc-windows\"" RL2CFG "${RL2CFG}")
string(REGEX REPLACE "#undef (OMIT_[A-Z0-9]+)" "/* #undef \\1 */" RL2CFG "${RL2CFG}")
file(WRITE ${GEN}/rasterlite2/rl2config.h "${RL2CFG}")
# rl2import.c includes <unistd.h> outside its _WIN32 guards; everything it
# takes from there is in io.h/direct.h, which it includes as well.
file(WRITE ${GEN}/unistd.h "#include <io.h>\n#include <direct.h>\n")
# The sources as src/Makefile.am lists them (the tree also holds files
# the library does not compile: rl2legend.c refers to types no header
# declares at this commit).
file(READ ${CMAKE_SOURCE_DIR}/src/Makefile.am AM)
string(REPLACE "\\\n" " " AM "${AM}")
string(REGEX MATCH "librasterlite2_la_SOURCES[ \t]*=[ \t]*([^\n]*)" _ "${AM}")
string(REGEX REPLACE "[ \t]+" ";" NAMES "${CMAKE_MATCH_1}")
set(SRC "")
foreach(n ${NAMES})
  if(n MATCHES "\\.c$")
    list(APPEND SRC ${CMAKE_SOURCE_DIR}/src/${n})
  endif()
endforeach()
list(LENGTH SRC n)
if(n LESS 1)
  message(FATAL_ERROR "no librasterlite2_la_SOURCES found in src/Makefile.am")
endif()
add_library(rasterlite2 SHARED ${SRC})
target_include_directories(rasterlite2 PRIVATE ${GEN} ${CMAKE_SOURCE_DIR}/headers ${CMAKE_SOURCE_DIR})
target_compile_definitions(rasterlite2 PRIVATE DLL_EXPORT _CRT_SECURE_NO_WARNINGS _CRT_NONSTDC_NO_DEPRECATE _USE_MATH_DEFINES
  strcasecmp=_stricmp strncasecmp=_strnicmp)
target_link_libraries(rasterlite2 PRIVATE PkgConfig::DEPS ${GIF_LIBRARY} ${GEOTIFF_LIBRARY} ws2_32)
install(TARGETS rasterlite2 RUNTIME DESTINATION bin ARCHIVE DESTINATION lib)
file(GLOB HEADERS ${CMAKE_SOURCE_DIR}/headers/rasterlite2/*.h)
list(FILTER HEADERS EXCLUDE REGEX "rl2config\\.h$")
install(FILES ${HEADERS} ${GEN}/rasterlite2/rl2config.h DESTINATION include/rasterlite2)
gaia_pc(rasterlite2 "a library supporting Rasters on DBMS" "${VERSION}" "-lrasterlite2" "spatialite")
'@

# Used by GDAL and mapnik (raster coverage via SpatiaLite); the fossil
# checkout pin mirrors the linux build's.  The time.h include is the macos
# finding (rasterlite2_private.h uses time_t without including it).
function Build-Librasterlite2 {
    if (Skip-If-Done 'librasterlite2') { return }
    Log '=== librasterlite2'
    $src = Fossil-Clone 'https://www.gaia-gis.it/fossil/librasterlite2' (Join-Path $LIW_SRC 'librasterlite2') '9dd8217cb9'
    Invoke-Patch $src 'rasterlite2_time' @'
path = "headers/rasterlite2_private.h"
s = open(path).read()
assert '#include "config.h"' in s
s = s.replace('#include "config.h"', '#include "config.h"\n#include <time.h>', 1)
open(path, "w").write(s)
# Windows only: the Visual Studio branch of do_import_dir (the _findfirst
# directory scan nobody else compiles) never closes its outer else block
# at this commit, so every function after it fails to parse.
path = "src/rl2import.c"
s = open(path).read()
old = "\t  sqlite3_free (search);\n\t  return cnt;\n#else\n"
assert s.count(old) == 1, "rl2import.c's _findfirst branch changed"
s = s.replace(old, "      }\n    sqlite3_free (search);\n    return cnt;\n#else\n")
open(path, "w").write(s)
'@
    Write-Embedded (Join-Path $src 'gaia.cmake') $script:GaiaCMakeSources
    Write-Embedded (Join-Path $src 'CMakeLists.txt') $script:Rasterlite2CMakeLists
    Cmake-Build $src
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('rasterlite2.dll') 'librasterlite2'
    Assert-Files (Join-Path $LIW_PREFIX 'lib\pkgconfig') @('rasterlite2.pc') 'librasterlite2'
    # (No spatialite import: rasterlite2 uses its headers over SQLite's
    # extension API and links nothing of it.)
    Assert-DependentStems (Join-Path $LIW_PREFIX 'bin\rasterlite2.dll') @(
        'sqlite3', 'geotiff', 'tiff', 'libpng16', 'jpeg62', 'gif', 'libwebp', 'openjp2', 'cairo', 'libcurl') 'librasterlite2'
    Done-Stamp 'librasterlite2'
}

# The MySQL client library for GDAL's MySQL driver.  Mirrors the
# Dockerfile (the ndb CMakeLists.txt stub, WITHOUT_SERVER, bundled zlib);
# WITH_SSL names the prefix's OpenSSL (the linux build's "system"
# OpenSSL is the base image's).  Not REPRODUCIBLE_BUILD: on Windows it
# wraps every compiler call in a perl script as the launcher, which
# CreateProcess cannot run.  The DLL is libmysql.dll (installed into lib,
# like mysql does on Windows), copied beside the other DLLs; the import
# library gets the mysqlclient.lib name GDAL's FindMySQL looks for.
function Build-Mysql {
    if (Skip-If-Done 'mysql') { return }
    Log '=== mysql (long)'
    $src = Fetch-Tarball "https://cdn.mysql.com/Downloads/MySQL-$(V mysql @('2'))/mysql-$(V mysql).tar.gz" `
        'mysql.tar.gz' (Join-Path $LIW_SRC 'mysql')
    Remove-Item -Recurse -Force (Join-Path $src 'mysql-test') -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path (Join-Path $src 'storage\ndb') | Out-Null
    Set-Content -Path (Join-Path $src 'storage\ndb\CMakeLists.txt') -Value '' -Encoding ascii
    Cmake-Build $src @('-DBUILD_CONFIG=mysql_release', '-DBUILD_SHARED_LIBS=ON', '-DWITH_ZLIB=bundled',
        "-DWITH_SSL=$script:CmakePrefix", '-DWITH_UNIT_TESTS=OFF', '-DWITHOUT_SERVER=ON',
        '-DINSTALL_MYSQLTESTDIR=', '-DWITH_AUTHENTICATION_WEBAUTHN=OFF') -NoInstall
    # The full install dies on its Debuginfo component (no .pdb in a
    # MinSizeRel build); the headers and the shared library are the two
    # components GDAL needs.
    foreach ($component in @('Development', 'SharedLibraries')) {
        Run-Logged 'cmake' @('--install', (Join-Path $src '_build'), '--component', $component) "cmake install of mysql's $component"
    }
    # mysql installs both the DLL and its import library into lib; the DLL
    # goes beside the others, and the import library takes the
    # mysqlclient.lib name as well -- over the static mysqlclient.lib the
    # Development component installs, which GDAL's FindMySQL (NAMES
    # mysqlclient first) would otherwise link.
    $lib = Join-Path $LIW_PREFIX 'lib'
    Assert-Files $lib @('libmysql.dll', 'libmysql.lib') 'mysql'
    Copy-Item (Join-Path $lib 'libmysql.dll') (Join-Path $LIW_PREFIX 'bin') -Force
    Copy-Item (Join-Path $lib 'libmysql.lib') (Join-Path $lib 'mysqlclient.lib') -Force
    Assert-Files (Join-Path $LIW_PREFIX 'include') @('mysql.h') 'mysql'
    Assert-DependentStems (Join-Path $LIW_PREFIX 'bin\libmysql.dll') @('libssl', 'libcrypto') 'mysql'
    Done-Stamp 'mysql'
}

# The postgresql client library for GDAL's PG/PGDump/PostGISRaster
# drivers, from PostgreSQL's meson build (its Windows build system).  As
# on macos: without ICU and readline (neither is in the prefix) and with
# OpenSSL; the whole tree is built and installed as on linux (libpq is
# what GDAL links; the server headers are what cmake's FindPostgreSQL
# requires).  perl, bison and flex are the Windows-only tools.
function Build-Postgresql {
    if (Skip-If-Done 'postgresql') { return }
    Log '=== postgresql'
    Ensure-Meson
    Ensure-Perl
    Ensure-WinFlexBison
    $src = Fetch-Tarball "https://ftp.postgresql.org/pub/source/v$(V postgresql)/postgresql-$(V postgresql).tar.gz" `
        'postgresql.tar.gz' (Join-Path $LIW_SRC 'postgresql')
    $savedPath = $env:PATH
    $env:PATH = "$script:PerlBin;$script:WinFlexBisonDir;$env:PATH"
    try {
        Meson-Build $src @('-Dssl=openssl', '-Dicu=disabled', '-Dreadline=disabled', '-Dzlib=enabled',
            '-Dnls=disabled', '-Dplperl=disabled', '-Dplpython=disabled', '-Dpltcl=disabled',
            '-Dlibxml=disabled', '-Dlibxslt=disabled', '-Dlz4=disabled', '-Dzstd=disabled', '-Ddocs=disabled')
    } finally {
        $env:PATH = $savedPath
    }
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('libpq.dll') 'postgresql'
    Assert-Files (Join-Path $LIW_PREFIX 'lib') @('libpq.lib') 'postgresql'
    Assert-Files (Join-Path $LIW_PREFIX 'include') @('libpq-fe.h') 'postgresql'
    Assert-DependentStems (Join-Path $LIW_PREFIX 'bin\libpq.dll') @('libssl', 'libcrypto') 'postgresql'
    Done-Stamp 'postgresql'
}

# The MrSID decoding SDK (the MrSID driver), Extensis' Windows x64 build
# of the version versions.txt pins (the linux build takes its rhel
# tarball, pinned there for compiler reasons; the SDK has no listing
# check_versions.py could track).  The DLLs go beside the prefix's so the
# wheel repair bundles them; the import library and headers are handed to
# GDAL's cmake explicitly (no stamp: the paths are needed on every run).
function Get-Mrsid {
    $version = V 'mrsid'
    $dir = Join-Path $LIW_SRC 'mrsid'
    $marker = Join-Path $dir ".extracted-$version"
    if (-not (Test-Path $marker)) {
        Log "=== mrsid $version"
        $zip = Fetch "https://bin.extensis.com/download/developer/MrSID_DSDK-$version-win64-vc17.zip" `
            "MrSID_DSDK-$version-win64-vc17.zip"
        Expand-Zip $zip $dir
        New-Item -ItemType File -Force -Path $marker | Out-Null
    }
    $lib = Get-ChildItem $dir -Recurse -Filter 'lti_dsdk*.lib' | Where-Object { $_.FullName -match 'Raster_DSDK' } |
        Select-Object -First 1
    if (-not $lib) { Die "mrsid: no lti_dsdk*.lib under $dir\*\Raster_DSDK" }
    $sdk = Split-Path -Parent (Split-Path -Parent $lib.FullName)
    $include = Join-Path $sdk 'include'
    if (-not (Test-Path (Join-Path $include 'lt_base.h'))) { Die "mrsid: lt_base.h is not in $include" }
    Get-ChildItem (Split-Path -Parent $lib.FullName) -Filter '*.dll' | ForEach-Object {
        Copy-Item $_.FullName (Join-Path $LIW_PREFIX 'bin') -Force
    }
    $script:MrsidLibrary = $lib.FullName
    $script:MrsidInclude = $include
    Log "mrsid $version at $sdk"
}

# GDAL itself.  The Dockerfile has two branches, toggled by hand: the
# release tag versions.txt's gdal names, or master at the commit
# versions.txt's gdal-sha names (the nightly builds follow master so they
# keep working; a release pin is for publication).  $script:GdalFromRelease
# is that toggle, with the Dockerfile's current setting (master).  Both
# other builds clone master 1000 deep and check the commit out; here the
# commit is fetched directly (GitHub serves a fetch by sha), with
# core.longpaths on, since the autotest tree has paths over 260
# characters.  The .2 local build suffix (three places), the setup.py
# version check, and the explicit cmake options mirror the Dockerfile.
# Windows deviations, all marked: no armadillo; no USER_DEFS (gcc's
# -Werror set; the MSVC build must not turn warnings into errors); the
# MrSID SDK is Extensis' win64 build.
$script:GdalFromRelease = $false

function Build-Gdal {
    if (Skip-If-Done 'gdal') { return }
    Log '=== gdal (long)'
    Ensure-Swig
    $pp = $script:PatchPython
    $src = Join-Path $LIW_SRC 'gdal'
    if (Test-Path $src) { Remove-Item -Recurse -Force $src }
    if ($script:GdalFromRelease) {
        Log "gdal source: release tag v$(V gdal)"
        for ($n = 1; $n -le 10; $n++) {
            & git -c core.longpaths=true clone --depth=1 --single-branch -b "v$(V gdal)" `
                -c advice.detachedHead=false https://github.com/OSGeo/gdal.git $src
            if ($LASTEXITCODE -eq 0) { break }
            if (Test-Path $src) { Remove-Item -Recurse -Force $src }
            Log 'retrying git clone: gdal'
            Start-Sleep -Seconds 5
        }
    } else {
        $sha = V 'gdal-sha'
        Log "gdal source: master at $sha"
        New-Item -ItemType Directory -Force -Path $src | Out-Null
        & git -C $src init -q
        Assert-Exit 'git init for gdal'
        & git -C $src remote add origin https://github.com/OSGeo/gdal.git
        Assert-Exit 'git remote add for gdal'
        for ($n = 1; $n -le 10; $n++) {
            & git -C $src -c core.longpaths=true fetch --depth=1 origin $sha
            if ($LASTEXITCODE -eq 0) { break }
            Log "retrying git fetch: gdal $sha"
            Start-Sleep -Seconds 5
        }
        & git -C $src -c core.longpaths=true checkout -q -f FETCH_HEAD
        Assert-Exit "git checkout of gdal $sha"
    }
    if (-not (Test-Path (Join-Path $src 'CMakeLists.txt'))) { Die 'the gdal checkout has no CMakeLists.txt' }
    Invoke-Patch $src 'gdal_version' @'
import re
path = "gcore/gdal_version.h.in"
s = open(path).read()
assert "define GDAL_VERSION_BUILD    0" in s
s = s.replace("define GDAL_VERSION_BUILD    0", "define GDAL_VERSION_BUILD    2").replace("dev", ".2dev")
open(path, "w").write(s)
path = "VERSION"
s = open(path).read()
s = re.sub(r"([0-9])(\r?\n?)$", r"\1.2\2", s)
open(path, "w").write(s)
path = "swig/python/setup.py.in"
s = open(path).read()
assert "if library_version_num < gdal_python_version" in s
s = s.replace("if library_version_num < gdal_python_version", "if False")
open(path, "w").write(s)
'@
    # numpy in the configuring python: the bindings' _gdal_array extension
    # is generated only when cmake finds it (the Dockerfile pip-installs
    # numpy before cmake for the same reason).
    & $pp -m pip install --quiet --no-warn-script-location numpy | Out-Null
    Assert-Exit 'pip install of numpy'
    Get-Mrsid
    # GDAL's FindOpenEXR looks for OpenEXR, OpenEXRUtil, Imath and Iex by
    # their bare names; OpenEXR 3's import libraries carry version
    # suffixes (OpenEXR-3_5.lib, Imath-3_2.lib), so the four are handed
    # over explicitly (the EXR driver silently disappears otherwise).
    $lib = Join-Path $LIW_PREFIX 'lib'
    $exr = @{}
    foreach ($pair in @(@('OpenEXR_LIBRARY', 'OpenEXR-*.lib'), @('OpenEXR_UTIL_LIBRARY', 'OpenEXRUtil-*.lib'),
                        @('OpenEXR_HALF_LIBRARY', 'Imath-*.lib'), @('OpenEXR_IEX_LIBRARY', 'Iex-*.lib'))) {
        $found = Get-ChildItem $lib -Filter $pair[1] -File | Where-Object { $_.Name -notmatch '^OpenEXR(Core|Util)' -or $pair[1] -match 'Util' } |
            Select-Object -First 1
        if (-not $found) { Die "gdal: no $($pair[1]) in $lib (openexr missing?)" }
        $exr[$pair[0]] = $found.FullName -replace '\\', '/'
    }
    # (GIT_LFS_SKIP_SMUDGE: PublicDecompWT's repository LFS-marks its test
    # data, which the build never reads; harmless when git-lfs is absent.)
    $env:GIT_LFS_SKIP_SMUDGE = '1'
    try {
        Cmake-Build $src @('-DGDAL_USE_LERC=ON', '-DENABLE_DEFLATE64=OFF', '-DGDAL_USE_PUBLICDECOMPWT=ON',
            '-DGDAL_USE_ARMADILLO=OFF', '-DBUILD_TESTING=OFF', '-DBUILD_JAVA_BINDINGS=OFF',
            '-DBUILD_CSHARP_BINDINGS=OFF', '-DBUILD_PYTHON_BINDINGS=ON',
            "-DPython_EXECUTABLE=$($pp -replace '\\', '/')",
            "-DSWIG_EXECUTABLE=$($script:SwigExe -replace '\\', '/')",
            "-DMRSID_LIBRARY=$($script:MrsidLibrary -replace '\\', '/')",
            "-DMRSID_INCLUDE_DIR=$($script:MrsidInclude -replace '\\', '/')",
            "-DOpenEXR_LIBRARY=$($exr['OpenEXR_LIBRARY'])",
            "-DOpenEXR_UTIL_LIBRARY=$($exr['OpenEXR_UTIL_LIBRARY'])",
            "-DOpenEXR_HALF_LIBRARY=$($exr['OpenEXR_HALF_LIBRARY'])",
            "-DOpenEXR_IEX_LIBRARY=$($exr['OpenEXR_IEX_LIBRARY'])",
            # (The raw-library find skips the cmake targets' consumer
            # defines: without IMATH_DLL, Imath's half.h references its
            # conversion table without dllimport and the link fails.
            # The first four flags are cmake's own MSVC defaults, which a
            # CMAKE_CXX_FLAGS on the command line replaces -- fyba's
            # headers test WIN32.)
            '-DCMAKE_CXX_FLAGS=/DWIN32 /D_WINDOWS /GR /EHsc /DIMATH_DLL /DOPENEXR_DLL')
    } finally {
        Remove-Item -Path 'env:GIT_LFS_SKIP_SMUDGE' -ErrorAction SilentlyContinue
    }
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('gdal.dll', 'gdalinfo.exe', 'ogrinfo.exe', 'gdal.exe') 'gdal'
    Assert-Files (Join-Path $LIW_PREFIX 'lib') @('gdal.lib') 'gdal'
    if (-not (Test-Path (Join-Path $LIW_PREFIX 'share\gdal'))) { Die 'gdal did not install its data files' }
    if (-not (Test-Path (Join-Path $src '_build\apps\gdal-config'))) { Die 'gdal did not generate apps/gdal-config' }
    if (-not (Test-Path (Join-Path $src '_build\swig\python\setup.py'))) { Die 'gdal did not configure its python bindings (swig or python missing?)' }
    # The macos build's assertion list, by DLL stem: every optional
    # library the linux wheel links must have resolved from the prefix.
    # Static ones (hdf4, fyba, libOpenDRIVE) are absorbed and have no
    # import; librttopo reaches libgdal through spatialite only.
    Assert-DependentStems (Join-Path $LIW_PREFIX 'bin\gdal.dll') @(
        'geos_c', 'proj', 'libcurl', 'tiff', 'libpng16', 'jpeg62', 'openjp2', 'libwebp', 'heif', 'avif', 'jxl',
        'poppler', 'cfitsio', 'hdf5', 'netcdf', 'libmysql', 'libpq', 'freexl', 'spatialite', 'rasterlite2',
        'geotiff', 'xerces-c', 'libexpat', 'libxml2', 'json-c', 'gta', 'libkea', 'blosc', 'archive', 'gif',
        'deflate', 'zstd', 'liblzma', 'z.dll', 'sqlite3', 'libcrypto', 'libssl', 'OpenEXR', 'Lerc', 'lti_dsdk',
        'iconv', 'vcomp140') 'gdal'
    Done-Stamp 'gdal'
}

# The GDAL python wheel: libgdal and its whole dependency tree, the proj
# and gdal data files, and the gdal, proj and libgeotiff command line
# tools, like the linux wheel.  Two Windows differences in the bundled
# python: the tool wrapper runs the real tool as a child (os.execve on
# Windows returns the console before the child is done), and answers
# gdal-config itself from the configured script's variables (it is a sh
# script, and Windows has no sh); and the osgeo patch finds the bundled
# DLLs by their Windows names (gdal.dll, geos_c.dll) under GDAL.libs.
$script:GdalBinWrapper = @'
import os
import subprocess
import sys


def _config(path, args):
    # gdal-config is a sh script; answer each option from its variables.
    values = {}
    for line in open(path):
        if line.startswith("CONFIG_") and "=" in line:
            key, _, value = line.rstrip("\r\n").partition("=")
            values[key] = value.strip('"')
    options = {
        "--libs": "CONFIG_LIBS", "--dep-libs": "CONFIG_DEP_LIBS", "--cflags": "CONFIG_CFLAGS",
        "--datadir": "CONFIG_DATA", "--prefix": "CONFIG_PREFIX", "--version": "CONFIG_VERSION",
        "--gnm-enabled": "CONFIG_GNM_ENABLED", "--formats": "CONFIG_FORMATS",
        "--plugindir": "CONFIG_PLUGINDIR",
    }
    if len(args) != 1 or (args[0] not in options and args[0] != "--ogr-enabled"):
        sys.stderr.write("Usage: gdal-config [%s]\n" % "|".join(["--ogr-enabled"] + sorted(options)))
        return 1
    print("yes" if args[0] == "--ogr-enabled" else values.get(options[args[0]], ""))
    return 0


def program():
    environ = os.environ.copy()
    localpath = os.path.dirname(os.path.abspath(__file__))
    datapath = os.path.dirname(localpath)
    environ.setdefault("PROJ_DATA", os.path.join(datapath, "proj"))
    environ.setdefault("GDAL_DATA", os.path.join(datapath, "gdal"))
    name = os.path.splitext(os.path.basename(sys.argv[0]))[0]
    if name == "gdal-config":
        sys.exit(_config(os.path.join(localpath, "gdal-config"), sys.argv[1:]))
    sys.exit(subprocess.call([os.path.join(localpath, name + ".exe")] + sys.argv[1:], env=environ))
'@

function Build-GdalPython {
    if (Skip-If-Done 'gdal_python') { return }
    Log '=== gdal python'
    $pp = $script:PatchPython
    & $pp -m pip install --quiet --no-warn-script-location -U "delvewheel==$(V delvewheel)" | Out-Null
    Assert-Exit 'pip install of delvewheel failed'
    if (-not $script:VcOpenMP -or -not (Test-Path (Join-Path $script:VcOpenMP 'vcomp140.dll'))) {
        Die 'gdal python: no OpenMP redistributable directory next to the CRT one (vcomp140.dll)'
    }
    Get-Mrsid
    $gdalSrc = Join-Path $LIW_SRC 'gdal'
    $src = Join-Path $gdalSrc '_build\swig\python'
    if (-not (Test-Path (Join-Path $src 'setup.py'))) { Die 'the gdal python bindings were not configured under _build/swig/python' }

    # The proj and gdal data files, and the tools: every gdal app that was
    # installed, gdal-config (the configured sh script, read by the
    # wrapper), libgeotiff's and proj's tools.
    foreach ($data in @('proj', 'gdal')) {
        $dest = Join-Path $src "osgeo\$data"
        if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
        Copy-Item (Join-Path $LIW_PREFIX "share\$data") $dest -Recurse
    }
    $binDir = Join-Path $src 'osgeo\bin'
    if (Test-Path $binDir) { Remove-Item -Recurse -Force $binDir }
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    $prefixBin = Join-Path $LIW_PREFIX 'bin'
    foreach ($appsDir in @((Join-Path $gdalSrc '_build\apps'), (Join-Path $LIW_SRC 'libgeotiff\libgeotiff\_build\bin'),
                           (Join-Path $LIW_SRC 'proj4\_build\bin'))) {
        if (-not (Test-Path $appsDir)) { Die "gdal python: no tools directory $appsDir" }
        foreach ($exe in (Get-ChildItem $appsDir -Filter '*.exe' -File)) {
            if (Test-Path (Join-Path $prefixBin $exe.Name)) {
                Copy-Item (Join-Path $prefixBin $exe.Name) $binDir -Force
            }
        }
    }
    Copy-Item (Join-Path $gdalSrc '_build\apps\gdal-config') (Join-Path $binDir 'gdal-config') -Force
    foreach ($tool in @('gdalinfo.exe', 'ogrinfo.exe', 'gdal.exe', 'listgeo.exe', 'proj.exe', 'cs2cs.exe')) {
        if (-not (Test-Path (Join-Path $binDir $tool))) { Die "gdal python: $tool was not bundled" }
    }
    Set-Content -Path (Join-Path $binDir '__init__.py') -Value $script:GdalBinWrapper -Encoding ascii

    # setup.py: the bundled tools as console scripts (named without .exe,
    # like the pyvips ones), the data and tools as package data, the
    # version from gdal-config's variables (the linux patch runs
    # gdal-config; here the wrapper reads the same file), and the
    # python_requires line the linux patch drops.
    Invoke-Patch $src 'gdal_setup' @'
import os
import re
path = "setup.py"
data = open(path).read()
if "osgeo.bin:program" in data:
    raise SystemExit(0)  # already patched (the source tree persists between runs)
config = open("../../apps/gdal-config").read()
version = re.search(r'CONFIG_VERSION="([^"]+)"', config).group(1).split(".dev")[0].split("dev")[0]
data = re.sub(r"gdal_version = '\d+.\d+.\d+(dev|)'", "gdal_version = '" + version + "'", data)
data = data.replace(
    "scripts/*.py'),",
    """scripts/*.py'),
    package_data={'osgeo': ['proj/*', 'gdal/*', 'bin/*']},""")
scripts = "['%s=osgeo.bin:program' % os.path.splitext(name)[0] for name in os.listdir('osgeo/bin') if not name.endswith('.py')]"
data = data.replace("console_scripts = []", "console_scripts = " + scripts)
if "console_scripts" not in data:
    data = data.replace(
        "scripts/*.py'),",
        """scripts/*.py'),
    entry_points={'console_scripts': """ + scripts + "},")
data = data.replace("    python_requires='>=3.6.0',", "")
open(path, "w").write(data)
'@
    # osgeo/__init__.py: the bundled data paths, GDAL_LIBRARY_PATH and
    # GEOS_LIBRARY_PATH from the bundled DLLs (delvewheel's gdal.libs,
    # with the Windows DLL names; the linux GDAL.libs and names stay as
    # fallbacks), and the linux patch's CPL_LOG default.  No
    # CURL_CA_BUNDLE: curl is on Schannel here and uses the Windows
    # certificate store.
    # (From the source tree's copy each time: the configured one persists
    # between runs, already patched.)
    Copy-Item (Join-Path $gdalSrc 'swig\python\osgeo\__init__.py') (Join-Path $src 'osgeo\__init__.py') -Force
    Invoke-Patch $src 'gdal_init' @'
path = "osgeo/__init__.py"
s = open(path).read()
assert "osgeo package." in s
s = s.replace(
    "osgeo package.",
"""osgeo package.

import os
import re
from . import osr
from . import gdal

_localpath = os.path.dirname(os.path.abspath(__file__))
osr.SetPROJSearchPaths([os.path.join(_localpath, "proj")])
gdal.SetConfigOption("GDAL_DATA", os.path.join(_localpath, "gdal"))
os.environ.setdefault("CPL_LOG", os.devnull)

_libsdir = os.path.join(os.path.dirname(_localpath), "gdal.libs")
if not os.path.exists(_libsdir):
    _libsdir = os.path.join(os.path.dirname(_localpath), "GDAL.libs")
_libs = {}
if os.path.exists(_libsdir):
    # (DLLs only: the bundled tools live here too, and gdal.exe would
    # otherwise take the "gdal" key from gdal-<hash>.dll.)
    _libs = {
        re.split(r"-|\\.", name)[0]: os.path.join(_libsdir, name)
        for name in os.listdir(_libsdir) if name.lower().endswith(".dll")
    }
GDAL_LIBRARY_PATH = _libs.get("libgdal") or _libs.get("gdal", "")
GEOS_LIBRARY_PATH = _libs.get("libgeos_c") or _libs.get("geos_c", "")

# On Windows gdal.dll tears itself down when it is unloaded, after the
# interpreter is gone, and with CPL_DEBUG set it reports through whatever
# error handler is installed; a Python callback (django's) is a dead
# pointer by then and the process dies on exit.  Restore the built-in
# handler first.
import atexit
atexit.register(gdal.SetErrorHandler, "CPLDefaultErrorHandler")
""")
open(path, "w").write(s)
'@
    foreach ($check in @(@('osgeo\__init__.py', 'GDAL_LIBRARY_PATH'), @('setup.py', 'osgeo.bin:program'),
                         @('setup.py', "package_data={'osgeo'"))) {
        if (-not (Select-String -Path (Join-Path $src $check[0]) -Pattern ([regex]::Escape($check[1])) -Quiet)) {
            Die "gdal python: the $($check[0]) patch did not apply ($($check[1]) missing)"
        }
    }
    # Python ports of two C utilities into scripts, as the linux build
    # bundles them.
    New-Item -ItemType Directory -Force -Path (Join-Path $src 'scripts') | Out-Null
    Copy-Item (Join-Path $src 'gdal-utils\osgeo_utils\samples\gdalinfo.py') (Join-Path $src 'scripts\gdalinfo.py') -Force
    Copy-Item (Join-Path $src 'gdal-utils\osgeo_utils\samples\ogrinfo.py') (Join-Path $src 'scripts\ogrinfo.py') -Force

    # One wheel per python; pip's isolated build environment installs
    # numpy from the bindings' pyproject build requires, so _gdal_array
    # is built for every python; the extensions link the build tree's
    # gdal.lib (setup.py is configured with its directory).
    Remove-Item -Path (Join-Path $LIW_WHEELHOUSE 'gdal-*.whl'), (Join-Path $LIW_WHEELHOUSE 'GDAL-*.whl') -Force -ErrorAction SilentlyContinue
    foreach ($minor in $script:Pythons) {
        $pybin = Join-Path $LIW_PY $minor
        Log "gdal wheel: python $minor"
        if (Test-Path (Join-Path $src 'build')) { Remove-Item -Recurse -Force (Join-Path $src 'build') }
        Run-Logged (Join-Path $pybin 'python.exe') @(
            '-m', 'pip', 'wheel', '--no-deps', '--progress-bar', 'off',
            '-w', $LIW_WHEELHOUSE, $src) "gdal wheel build for python $minor"
    }
    # The repair and the relocation run under the lowercase name pip wrote
    # (the Glymur lesson: delvewheel finds the dist-info through the
    # wheel's file name, and setuptools writes it in lowercase), so the
    # library directory is gdal.libs; the finished wheel is renamed to
    # GDAL- last, as the linux build's rename does.
    Log 'delvewheel repair of the gdal wheels'
    Remove-Item -Path (Join-Path $WheelsDir 'gdal-*.whl'), (Join-Path $WheelsDir 'GDAL-*.whl') -Force -ErrorAction SilentlyContinue
    foreach ($whl in (Get-ChildItem -Path $LIW_WHEELHOUSE -Filter 'gdal-*.whl' -File)) {
        Run-Logged $pp @(
            '-m', 'delvewheel', 'repair', '-w', $WheelsDir,
            '--add-path', "$prefixBin;$script:VcRedist;$script:VcOpenMP",
            '--analyze-existing-exes',
            '--include', 'vcruntime140.dll;vcruntime140_1.dll',
            '--exclude', 'gdiplus.dll',
            '--no-mangle', 'vcruntime140.dll;vcruntime140_1.dll',
            $whl.FullName) "delvewheel repair of $($whl.Name)"
        $out = Join-Path $WheelsDir $whl.Name
        Relocate-Tools $out 'osgeo' 'gdal.libs'
        Assert-WheelContains $out @(
            '^gdal\.libs/gdal-[0-9a-f]+\.dll$',
            '^gdal\.libs/geos_c-[0-9a-f]+\.dll$',
            '^gdal\.libs/proj[0-9_]*-[0-9a-f]+\.dll$',
            '^gdal\.libs/spatialite-[0-9a-f]+\.dll$',
            '^gdal\.libs/netcdf-[0-9a-f]+\.dll$',
            '^gdal\.libs/hdf5-[0-9a-f]+\.dll$',
            '^gdal\.libs/libmysql-[0-9a-f]+\.dll$',
            '^gdal\.libs/libpq-[0-9a-f]+\.dll$',
            '^gdal\.libs/poppler-[0-9a-f]+\.dll$',
            '^gdal\.libs/lti_dsdk[^/]*\.dll$',
            '^gdal\.libs/OpenEXR-[0-9a-f_-]+\.dll$',
            '^gdal\.libs/vcomp140-[0-9a-f]+\.dll$',
            '^gdal\.libs/msvcp140-[0-9a-f]+\.dll$',
            '^gdal\.libs/vcruntime140\.dll$',
            '^gdal\.libs/gdalinfo\.exe$',
            '^gdal\.libs/listgeo\.exe$',
            '^gdal\.libs/proj\.exe$',
            '^osgeo/bin/gdalinfo\.exe$',
            '^osgeo/bin/gdal-config$',
            '^osgeo/proj/proj\.db$',
            '^osgeo/gdal/gdalvrt\.xsd$',
            '^osgeo/_gdal_array.*\.pyd$',
            '^osgeo/_gdal.*\.pyd$') 'gdal'
        Move-Item $out (Join-Path $WheelsDir ($whl.Name -replace '^gdal-', 'GDAL-')) -Force
    }
    $repaired = @(Get-ChildItem -Path $WheelsDir -Filter 'GDAL-*win_amd64*.whl' -File)
    if ($repaired.Count -lt $script:Pythons.Count) {
        Die "gdal: only $($repaired.Count) wheels, expected $($script:Pythons.Count)"
    }
    Done-Stamp 'gdal_python'
}

# Expose each tool in <package>/bin as a console script that runs the
# launcher of the same name (after the repair, <package>/bin/<tool>.exe is
# the launcher, which finds the real tool in <dist>.libs).
$script:ToolWrapper = @'
import os
import subprocess
import sys

def program():
    here = os.path.dirname(os.path.abspath(__file__))
    name = os.path.splitext(os.path.basename(sys.argv[0]))[0]
    sys.exit(subprocess.call([os.path.join(here, name + '.exe')] + sys.argv[1:]))
'@

# Run a python patch script (written to the patches directory) from the
# source tree.
function Invoke-Patch([string]$Src, [string]$Name, [string]$Code) {
    $path = Join-Path $LIW_PATCHES "$Name.py"
    Set-Content -Path $path -Value $Code -Encoding ascii
    Push-Location $Src
    try {
        & $script:PatchPython $path
        Assert-Exit "the $Name patch"
    } finally {
        Pop-Location
    }
}

function Commit-Patches([string]$Src, [string]$Tag) {
    & git -C $Src config user.email 'wheels@example.com'
    & git -C $Src config user.name 'Wheel Builder'
    & git -C $Src add -A
    Assert-Exit "git add in $Src"
    & git -C $Src commit -q -m 'patch for wheel building'
    Assert-Exit "git commit in $Src"
    & git -C $Src tag $Tag
    Assert-Exit "git tag in $Src"
}

function Build-Pylibtiff {
    if (Skip-If-Done 'pylibtiff') { return }
    Log '=== pylibtiff'
    $pp = $script:PatchPython

    & $pp -m pip install --quiet --no-warn-script-location -U setuptools-scm `
        "delvewheel==$(V delvewheel)" | Out-Null
    Assert-Exit 'pip install of setuptools-scm/delvewheel failed'

    $src = Git-Clone 'https://github.com/pearu/pylibtiff.git' "v$(V pylibtiff)" `
        (Join-Path $LIW_SRC 'pylibtiff')
    # The patch scripts use paths relative to the source tree, like the
    # Dockerfile's and macos's (which cd into the clone first).
    Push-Location $src

    # Bundle the libtiff tools with the wheel, like the linux build does:
    # for each tool in libtiff's source tools directory, take the matching
    # executable our libtiff install produced.
    $binDir = Join-Path $src 'libtiff\bin'
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    foreach ($tool in (Get-ChildItem -Path (Join-Path $LIW_SRC 'libtiff\tools') `
            -File)) {
        $exe = Join-Path $LIW_PREFIX "bin\$($tool.BaseName).exe"
        if (Test-Path $exe) { Copy-Item $exe $binDir -Force }
    }
    if (@(Get-ChildItem $binDir -File).Count -eq 0) {
        Die 'no libtiff tools found to bundle'
    }

    # Wrapper module so each bundled tool is exposed as a console script.
    # Windows has no os.execv replacement semantics to rely on, so the
    # wrapper runs the tool as a child and exits with its code (the
    # macos/linux wrappers use os.execv).  After the repair,
    # libtiff/bin/<tool>.exe is the launcher, which finds the real tool
    # and its DLLs in pylibtiff.libs itself.
    $wrapper = @'
import os
import subprocess
import sys

def program():
    here = os.path.dirname(os.path.abspath(__file__))
    name = os.path.splitext(os.path.basename(sys.argv[0]))[0]
    sys.exit(subprocess.call([os.path.join(here, name + '.exe')] + sys.argv[1:]))
'@
    Set-Content -Path (Join-Path $binDir '__init__.py') -Value $wrapper -Encoding ascii

    # Patch setup.py: expose the bundled tools as console scripts, include
    # them as package data, and link _tif_lzw against libtiff.
    $setupPatch = @'
import os
path = "setup.py"
s = open(path).read()
s = s.replace(
    "'console_scripts': [",
    "'console_scripts': \n"
    "        ['%s=libtiff.bin:program' % os.path.splitext(name)[0]\n"
    "         for name in os.listdir('libtiff/bin') if name.endswith('.exe')] + [")
s = s.replace('name="libtiff.tif_lzw",',
    "name=\"libtiff.tif_lzw\", libraries=['tiff'], "
    "library_dirs=['%s']," % os.path.join(os.environ["LIW_PREFIX"], "lib"))
s = s.replace(
    "packages=find_packages(),",
    "packages=find_packages(), package_data={'libtiff': ['bin/*']},")
open(path, "w").write(s)
'@
    Set-Content -Path (Join-Path $LIW_PATCHES 'pylibtiff_setup.py') `
        -Value $setupPatch -Encoding ascii
    & $pp (Join-Path $LIW_PATCHES 'pylibtiff_setup.py')
    Assert-Exit 'the pylibtiff setup.py patch failed'

    # Patch libtiff_ctypes.py so it finds the bundled DLL.  delvewheel puts
    # bundled DLLs in a <name>.libs directory and adds a _delvewheel_patch
    # shim to each top-level package's __init__.py that puts that directory
    # on the DLL search path; this fallback loads the DLL directly, which
    # also covers find_library() failing.  Windows cmake names the library
    # tiff.dll or libtiff.dll (not libtiff.so.N), so match both prefixes.
    $ctypesPatch = @'
path = "libtiff/libtiff_ctypes.py"
s = open(path).read()
s = s.replace(
    "    libtiff = None if lib is None else ctypes.cdll.LoadLibrary(lib)",
    """    try:
        libtiff = None if lib is None else ctypes.cdll.LoadLibrary(lib)
    except Exception:
        lib = None
    if lib is None or True:
        libpath = os.path.abspath(os.path.join(os.path.dirname(os.path.realpath(
            __file__)), ".libs"))
        if not os.path.exists(libpath):
            libpath = os.path.abspath(os.path.join(os.path.dirname(os.path.dirname(
                os.path.realpath(__file__))), "libtiff.libs"))
        if not os.path.exists(libpath):
            libpath = os.path.abspath(os.path.join(os.path.dirname(os.path.dirname(
                os.path.realpath(__file__))), "pylibtiff.libs"))
        try:
            libs = os.listdir(libpath)
            # auditwheel names bundled libraries like libtiff-<hash>.so.6;
            # delvewheel keeps the original name, tiff.dll or libtiff.dll.
            candidates = [flib for flib in libs
                          if flib.startswith("libtiff") or flib.startswith("tiff")]
            pospath = os.path.join(libpath, candidates[0])
            if os.path.exists(pospath):
                lib = pospath
        except Exception:
            pass
        libtiff = None if lib is None else ctypes.cdll.LoadLibrary(lib)""")
s = s.replace('print("Not trying"', '# print("Not trying"')
open(path, "w").write(s)
'@
    Set-Content -Path (Join-Path $LIW_PATCHES 'pylibtiff_libtiff_ctypes.py') `
        -Value $ctypesPatch -Encoding ascii
    & $pp (Join-Path $LIW_PATCHES 'pylibtiff_libtiff_ctypes.py')
    Assert-Exit 'the pylibtiff libtiff_ctypes.py patch failed'

    $pyprojectPatch = @'
path = "pyproject.toml"
s = open(path).read()
s = s.replace(
    "'oldest-supported-numpy'",
    "'oldest-supported-numpy; python_version < \"3.9\"', 'numpy; python_version >= \"3.9\"'")
open(path, "w").write(s)
'@
    Set-Content -Path (Join-Path $LIW_PATCHES 'pylibtiff_pyproject.py') `
        -Value $pyprojectPatch -Encoding ascii
    & $pp (Join-Path $LIW_PATCHES 'pylibtiff_pyproject.py')
    Assert-Exit 'the pylibtiff pyproject.toml patch failed'
    Pop-Location

    # Note (windows watch item): large_image clears
    # libtiff.TIFFGetField.argtypes; with no argtypes ctypes passes the
    # arguments of variadic functions in an ABI-specific way and the call
    # segfaulted inside libtiff on darwin/arm64 (the linux builds are
    # unaffected and do not wrap it, and neither does this build).  If
    # large_image tiff reads crash on windows, port the
    # _TIFFGetFieldWrapper from the macos build into this patch set.

    # Generate the tiff header companion file (needs numpy present; the
    # prefix bin dir is on PATH so the generation run finds our libtiff;
    # wheels never rely on that PATH).
    & $pp -m pip install --quiet --no-warn-script-location numpy | Out-Null
    Assert-Exit 'pip install of numpy failed'
    Push-Location $src
    try {
        $env:TIFF_HEADER_PATH = Join-Path $src 'libtiff\libtiff\tiff.h'
        & $pp libtiff\libtiff_ctypes.py
        Log "tiff header generation exit code: $LASTEXITCODE (nonzero is tolerated)"
    } finally {
        Pop-Location
        Remove-Item -Path 'env:TIFF_HEADER_PATH' -ErrorAction SilentlyContinue
    }
    & $pp -m pip uninstall -q -y numpy | Out-Null

    # Commit the patches and tag with the combined version (package version
    # + bundled libtiff version), matching the linux wheel versioning.
    & git -C $src config user.email 'wheels@example.com'
    & git -C $src config user.name 'Wheel Builder'
    & git -C $src add -A
    Assert-Exit 'git add failed in the pylibtiff source'
    & git -C $src commit -q -m 'patch for wheel building'
    Assert-Exit 'git commit failed in the pylibtiff source'
    & git -C $src tag "$(V pylibtiff).$(V libtiff)"
    Assert-Exit 'git tag failed in the pylibtiff source'

    # Build one wheel per python, then bundle the DLLs with delvewheel (the
    # auditwheel/delocate equivalent on Windows).  Unrepaired wheels stay
    # in the wheelhouse for debugging; repaired wheels land in the mapped
    # output folder directly.
    foreach ($minor in $script:Pythons) {
        $pybin = Join-Path $LIW_PY $minor
        Log "pylibtiff wheel: python $minor"
        if (Test-Path (Join-Path $src 'build')) {
            Remove-Item -Recurse -Force (Join-Path $src 'build')
        }
        Run-Logged (Join-Path $pybin 'python.exe') @(
            '-m', 'pip', 'wheel', '--no-deps', '--progress-bar', 'off',
            '-w', $LIW_WHEELHOUSE, $src) "pylibtiff wheel build for python $minor"
    }

    # delvewheel only follows the import tables of the wheel's .pyd files,
    # and MSVC's linker records no import for a DLL whose symbols are
    # unused: tif_lzw links tiff.lib but imports nothing from it (on linux
    # the -ltiff DT_NEEDED entry survives and auditwheel bundles libtiff
    # through it).  The library pylibtiff loads with ctypes is therefore
    # forced in with --include, and --analyze-existing-exes vendors the
    # bundled tools' dependencies and rewrites their import tables to the
    # mangled names.  The VC runtime DLLs (vcruntime140, vcruntime140_1)
    # are forced in too, unmangled: python ships them for its own
    # extensions, but the bundled tools run as separate processes in a
    # directory where nothing else provides them (a fresh Windows has no
    # VC++ redistributable), and delvewheel leaves them out otherwise.
    # Mangling stays on: the Windows loader reuses an already-loaded module
    # by base name, so unmangled tiff.dll copies in two wheels would
    # silently share one (the hazard the linux BUILD_ID salt exists for).
    Log 'delvewheel repair of the pylibtiff wheels'
    foreach ($whl in (Get-ChildItem -Path $LIW_WHEELHOUSE `
            -Filter 'pylibtiff-*.whl' -File)) {
        Run-Logged $pp @(
            '-m', 'delvewheel', 'repair', '-w', $WheelsDir,
            '--add-path', "$(Join-Path $LIW_PREFIX 'bin');$script:VcRedist",
            '--analyze-existing-exes',
            '--include', 'tiff.dll;vcruntime140.dll;vcruntime140_1.dll',
            '--no-mangle', 'vcruntime140.dll;vcruntime140_1.dll',
            $whl.FullName) "delvewheel repair of $($whl.Name)"
        Relocate-Tools (Join-Path $WheelsDir $whl.Name) 'libtiff' 'pylibtiff.libs'
    }

    $expected = $script:Pythons.Count
    $repaired = @(Get-ChildItem -Path $WheelsDir `
        -Filter 'pylibtiff-*win_amd64*.whl' -File)
    if ($repaired.Count -lt $expected) {
        Die "pylibtiff: only $($repaired.Count) win_amd64 wheels, expected $expected"
    }
    foreach ($whl in $repaired) {
        Assert-WheelContains $whl.FullName @(
            '^pylibtiff\.libs/tiff-[0-9a-f]+\.dll$',
            '^pylibtiff\.libs/jpeg62-[0-9a-f]+\.dll$',
            '^pylibtiff\.libs/zstd-[0-9a-f]+\.dll$',
            '^pylibtiff\.libs/libwebp-[0-9a-f]+\.dll$',
            '^pylibtiff\.libs/deflate-[0-9a-f]+\.dll$',
            '^pylibtiff\.libs/z-[0-9a-f]+\.dll$',
            '^pylibtiff\.libs/vcruntime140\.dll$',
            '^pylibtiff\.libs/tiffinfo\.exe$',
            '^libtiff/bin/tiffinfo\.exe$') 'pylibtiff'
    }
    Done-Stamp 'pylibtiff'
}

# Glymur is pure python plus the bundled openjp2 library (loaded with
# ctypes) and the openjpeg/libjpeg command line tools.  One wheel serves
# every python: pip tags it py3-none-any, and it is retagged
# py3-none-win_amd64 (the wheel tool rewrites the filename and the WHEEL
# metadata) before delvewheel bundles the DLLs, as the macos build retags
# to macosx before delocate.  The patches are the macos ones with the
# Windows library directory (Glymur.libs, mangled names without a lib
# prefix) and .exe tool names.
function Build-Glymur {
    if (Skip-If-Done 'glymur') { return }
    Log '=== glymur'
    $pp = $script:PatchPython

    & $pp -m pip install --quiet --no-warn-script-location -U `
        "delvewheel==$(V delvewheel)" | Out-Null
    Assert-Exit 'pip install of delvewheel failed'

    $src = Git-Clone 'https://github.com/quintusdias/glymur.git' "v$(V glymur)" `
        (Join-Path $LIW_SRC 'glymur')

    # Bundle the openjpeg and libjpeg tools, like the linux build does.
    $binDir = Join-Path $src 'glymur\bin'
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    foreach ($tool in (Get-ChildItem -Path (Join-Path $LIW_PREFIX 'bin') -Filter 'opj_*.exe' -File)) {
        Copy-Item $tool.FullName $binDir -Force
    }
    foreach ($name in @('jpegtran', 'cjpeg', 'djpeg', 'rdjpgcom', 'wrjpgcom')) {
        $exe = Join-Path $LIW_PREFIX "bin\$name.exe"
        if (Test-Path $exe) { Copy-Item $exe $binDir -Force }
    }
    if (@(Get-ChildItem $binDir -Filter '*.exe' -File).Count -lt 4) {
        Die 'glymur: the openjpeg/libjpeg tools to bundle are missing'
    }
    Set-Content -Path (Join-Path $binDir '__init__.py') -Value $script:ToolWrapper -Encoding ascii

    # config.py: find the bundled openjp2 (and tiff) DLL in the wheel's
    # library directory (glymur.libs here, after the lowercase dist-info
    # setuptools writes; Glymur.libs on linux).  delvewheel mangles names
    # to <stem>-<hash>.dll, so match by prefix; the linux patch's "lib" +
    # libname does not apply (openjp2.dll).
    Invoke-Patch $src 'glymur_config' @'
path = "glymur/config.py"
s = open(path).read()
s = s.replace("    path = find_library(libname)",
"""    path = find_library(libname)
    libpath = os.path.abspath(os.path.join(os.path.dirname(os.path.dirname(
        os.path.realpath(__file__))), "glymur.libs"))
    if not os.path.exists(libpath):
        libpath = os.path.abspath(os.path.join(os.path.dirname(os.path.dirname(
            os.path.realpath(__file__))), "Glymur.libs"))
    if os.path.exists(libpath):
        libs = os.listdir(libpath)
        try:
            pospath = os.path.join(libpath, [lib for lib in libs if
                lib.lower().startswith(libname.lower() + "-") or
                lib.lower() == libname.lower() + ".dll"][0])
            if os.path.exists(pospath):
                path = pospath
        except Exception:
            pass""")
open(path, "w").write(s)
'@
    # pyproject.toml: expose the bundled tools as console scripts (names
    # without .exe), include them and the test data as package data, allow
    # python 3.10, declare packaging (glymur 0.14.8 imports it without
    # declaring it), and add the local build suffix to the version
    # (Glymur-0.14.8.1, matching the linux and macos wheels).
    Invoke-Patch $src 'glymur_pyproject' @'
import os
import re
path = "pyproject.toml"
s = open(path).read()
s = s.replace("jpeg2jp2 = 'glymur.command_line:jpeg2jp2'",
    "jpeg2jp2 = 'glymur.command_line:jpeg2jp2'" +
    "".join(["\n%s = 'glymur.bin:program'" % os.path.splitext(name)[0]
        for name in os.listdir("glymur/bin") if name.endswith(".exe")]))
s = s.replace("dependencies = [\n    'numpy',",
    "dependencies = [\n    'packaging',\n    'numpy',")
s = s.replace("requires-python = '>=3.11'", "requires-python = '>=3.10'")
s += """
[tool.setuptools]
include-package-data = true

[tool.setuptools.package-data]
glymur = [
    "data/*.jp2",
    "data/*.jpx",
    "data/*.j2k",
    "bin/*",
]
"""
s = re.sub(r"(version = ')(\d+\.\d+\.\d+)((?:post\d+)?)(')", r"\1\2.1\3\4", s)
open(path, "w").write(s)
'@
    Commit-Patches $src "$(V glymur).1"

    Log 'glymur wheel (pure python; one wheel for every python)'
    if (Test-Path (Join-Path $src 'build')) { Remove-Item -Recurse -Force (Join-Path $src 'build') }
    Remove-Item -Path (Join-Path $LIW_WHEELHOUSE 'glymur-*.whl'), `
        (Join-Path $LIW_WHEELHOUSE 'Glymur-*.whl') -Force -ErrorAction SilentlyContinue
    Run-Logged $pp @('-m', 'pip', 'wheel', '--no-deps', '--progress-bar', 'off',
        '-w', $LIW_WHEELHOUSE, $src) 'glymur wheel build'
    # setuptools writes the wheel and its dist-info in lowercase (glymur);
    # delvewheel and the wheel tool locate the dist-info through the file
    # name, so the repair and the relocation run under that name (library
    # directory glymur.libs) and only the finished wheel is renamed to the
    # distribution's Glymur-, as the linux and macos builds name theirs
    # (the shared test script looks for Glymur*.whl).  With the first
    # attempt's capitalized name delvewheel took the lowercase dist-info
    # for a package and left RECORD unreadable.
    $whl = Get-ChildItem -Path $LIW_WHEELHOUSE -Filter 'glymur-*-py3-none-any.whl' -File |
        Select-Object -First 1
    if (-not $whl) { Die 'glymur: no py3-none-any wheel was built' }
    Run-Logged $pp @('-m', 'wheel', 'tags', '--platform-tag', 'win_amd64', '--remove', $whl.FullName) `
        'glymur wheel retag'
    $tagged = Join-Path $LIW_WHEELHOUSE ($whl.Name -replace '-any\.whl$', '-win_amd64.whl')
    if (-not (Test-Path $tagged)) { Die "glymur: the retagged wheel is not at $tagged" }

    # openjp2.dll is loaded with ctypes (no import table leads to it);
    # tiff.dll likewise for glymur's tiff2jp2; the tools bring the rest.
    # With the none ABI tag delvewheel does not know the python's VC
    # runtime, so vcruntime140.dll is a plain dependency: bundled, and
    # kept unmangled like in the pylibtiff wheel.
    Log 'delvewheel repair of the glymur wheel'
    Remove-Item -Path (Join-Path $WheelsDir 'glymur-*.whl'), (Join-Path $WheelsDir 'Glymur-*.whl') `
        -Force -ErrorAction SilentlyContinue
    Run-Logged $pp @(
        '-m', 'delvewheel', 'repair', '-w', $WheelsDir,
        '--add-path', "$(Join-Path $LIW_PREFIX 'bin');$script:VcRedist",
        '--analyze-existing-exes',
        '--include', 'openjp2.dll;tiff.dll;vcruntime140.dll;vcruntime140_1.dll',
        '--no-mangle', 'vcruntime140.dll;vcruntime140_1.dll',
        $tagged) 'delvewheel repair of glymur'
    $out = Join-Path $WheelsDir (Split-Path -Leaf $tagged)
    Relocate-Tools $out 'glymur' 'glymur.libs'
    Assert-WheelContains $out @(
        '^glymur\.libs/openjp2-[0-9a-f]+\.dll$',
        '^glymur\.libs/tiff-[0-9a-f]+\.dll$',
        '^glymur\.libs/libpng16-[0-9a-f]+\.dll$',
        '^glymur\.libs/lcms2-[0-9a-f]+\.dll$',
        '^glymur\.libs/jpeg62-[0-9a-f]+\.dll$',
        '^glymur\.libs/vcruntime140\.dll$',
        '^glymur\.libs/opj_dump\.exe$',
        '^glymur\.libs/opj_decompress\.exe$',
        '^glymur\.libs/djpeg\.exe$',
        '^glymur/bin/opj_dump\.exe$',
        '^glymur/data/nemo\.jp2$') 'glymur'
    $final = Join-Path $WheelsDir ((Split-Path -Leaf $out) -replace '^glymur-', 'Glymur-')
    Move-Item $out $final -Force
    Log "glymur wheel: $final"
    Done-Stamp 'glymur'
}

# openslide-python from master (the last release tag is stale, as on linux
# and macos): the _convert extension links libopenslide, slidetool is
# bundled, and lowlevel.py loads the bundled DLL before anything else --
# pypi publishes openslide-bin wheels for Windows, and large-image
# [openslide] installs one, but its library is unpatched upstream (no
# flattened-MIRAX support).  One abi3 wheel from python 3.11 covers the
# stable pythons; each free-threaded python gets its own wheel (3.15t's is
# the cp315-abi3.abi3t one upstream builds), mirroring the linux and macos
# builds.
function Build-OpenslidePython {
    if (Skip-If-Done 'openslide_python') { return }
    Log '=== openslide_python'
    $pp = $script:PatchPython

    & $pp -m pip install --quiet --no-warn-script-location -U "delvewheel==$(V delvewheel)" | Out-Null
    Assert-Exit 'pip install of delvewheel failed'

    $src = Git-Clone 'https://github.com/openslide/openslide-python.git' '' `
        (Join-Path $LIW_SRC 'openslide-python')

    # Bundle the openslide tools: whatever openslide's own tools directory
    # built (slidetool in 4.x), taken from the prefix.
    $binDir = Join-Path $src 'openslide\bin'
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    foreach ($tool in (Get-ChildItem -Path (Join-Path $LIW_SRC 'openslide\_build\tools') -Filter '*.exe' -File)) {
        $exe = Join-Path $LIW_PREFIX "bin\$($tool.Name)"
        if (Test-Path $exe) { Copy-Item $exe $binDir -Force }
    }
    if (@(Get-ChildItem $binDir -Filter '*.exe' -File).Count -eq 0) {
        Die 'openslide_python: no openslide tools found to bundle'
    }
    Set-Content -Path (Join-Path $binDir '__init__.py') -Value $script:ToolWrapper -Encoding ascii

    Invoke-Patch $src 'openslide_python_lowlevel' @'
path = "openslide/lowlevel.py"
s = open(path).read()
if "\nimport os\n" not in s:
    s = s.replace("import platform\n", "import os\nimport platform\n", 1)
s = s.replace(
    """def _load_library() -> CDLL:
    try:
        import openslide_bin

        return openslide_bin.libopenslide1
    except (AttributeError, ModuleNotFoundError):
        pass
""",
    """def _load_library() -> CDLL:
    # A wheel built by the large_image wheels pipeline bundles libopenslide
    # (delvewheel puts it in openslide_python.libs, name-mangled to
    # libopenslide-1-<hash>.dll); look there before the openslide-bin
    # wheel or any copy on PATH.  This must come first: pypi publishes
    # openslide-bin wheels for Windows and large-image[openslide] installs
    # one, but its library is unpatched upstream (no flattened-MIRAX
    # support), so letting it win would silently replace our library.
    libpath = os.path.abspath(os.path.join(os.path.dirname(os.path.dirname(
        os.path.realpath(__file__))), "openslide_python.libs"))
    if os.path.exists(libpath):
        try:
            lib = [lib for lib in os.listdir(libpath)
                if lib.startswith('libopenslide')][0]
            return cdll.LoadLibrary(os.path.join(libpath, lib))
        except (IndexError, OSError):
            pass

    try:
        import openslide_bin

        return openslide_bin.libopenslide1
    except (AttributeError, ModuleNotFoundError):
        pass
""")
open(path, "w").write(s)
'@
    Invoke-Patch $src 'openslide_python_setup' @'
import os
path = "setup.py"
s = open(path).read()
s = s.replace(
    "            ['openslide/_convert.c'],",
    "            ['openslide/_convert.c'],\n"
    "            libraries=['openslide'],\n"
    "            library_dirs=['%s'],\n"
    "            include_dirs=['%s']," % (
        os.path.join(os.environ["LIW_PREFIX"], "lib"),
        os.path.join(os.environ["LIW_PREFIX"], "include")))
open(path, "w").write(s)
'@
    Invoke-Patch $src 'openslide_python_version' @'
import re
path = "openslide/_version.py"
s = open(path).read()
s = re.sub(r"(__version__ = '[^']*)'", r"\1.1'", s)
open(path, "w").write(s)
'@
    Invoke-Patch $src 'openslide_python_pyproject' @'
import os
path = "pyproject.toml"
s = open(path).read()
s = s.replace('openslide = ["py.typed", "*.pyi"]',
    'openslide = ["py.typed", "*.pyi", "bin/*"]')
s += "\n[project.scripts]\n" + "".join(
    "%s = 'openslide.bin:program'\n" % os.path.splitext(name)[0]
    for name in os.listdir("openslide/bin") if name.endswith(".exe"))
open(path, "w").write(s)
'@
    Commit-Patches $src "$(V openslide-python).1"

    # One abi3 wheel from the oldest stable python requested (3.11 when it
    # is), plus every free-threaded python.
    $stable = @($script:Pythons | Where-Object { -not $_.EndsWith('t') } |
        Sort-Object { [version]$_ })
    $kept = @()
    if ($stable.Count -gt 0) { $kept += $stable[0] }
    $kept += @($script:Pythons | Where-Object { $_.EndsWith('t') })
    if ($kept.Count -eq 0) { Die 'no pythons selected for the openslide-python wheels' }
    Remove-Item -Path (Join-Path $LIW_WHEELHOUSE 'openslide_python-*.whl') -Force -ErrorAction SilentlyContinue
    foreach ($minor in $kept) {
        $pybin = Join-Path $LIW_PY $minor
        Log "openslide_python wheel: python $minor"
        if (Test-Path (Join-Path $src 'build')) { Remove-Item -Recurse -Force (Join-Path $src 'build') }
        Run-Logged (Join-Path $pybin 'python.exe') @(
            '-m', 'pip', 'wheel', '--no-deps', '--progress-bar', 'off',
            '-w', $LIW_WHEELHOUSE, $src) "openslide_python wheel build for python $minor"
    }

    Log 'delvewheel repair of the openslide_python wheels'
    Remove-Item -Path (Join-Path $WheelsDir 'openslide_python-*.whl') -Force -ErrorAction SilentlyContinue
    foreach ($whl in (Get-ChildItem -Path $LIW_WHEELHOUSE -Filter 'openslide_python-*.whl' -File)) {
        Run-Logged $pp @(
            '-m', 'delvewheel', 'repair', '-w', $WheelsDir,
            '--add-path', "$(Join-Path $LIW_PREFIX 'bin');$script:VcRedist",
            '--analyze-existing-exes',
            '--include', 'libopenslide-1.dll;vcruntime140.dll;vcruntime140_1.dll',
            '--no-mangle', 'vcruntime140.dll;vcruntime140_1.dll',
            $whl.FullName) "delvewheel repair of $($whl.Name)"
        $out = Join-Path $WheelsDir $whl.Name
        Relocate-Tools $out 'openslide' 'openslide_python.libs'
        Assert-WheelContains $out @(
            '^openslide_python\.libs/libopenslide-1-[0-9a-f]+\.dll$',
            '^openslide_python\.libs/cairo-[0-9a-f-]+\.dll$',
            '^openslide_python\.libs/glib-2\.0-[0-9a-f-]+\.dll$',
            '^openslide_python\.libs/sqlite3-[0-9a-f]+\.dll$',
            '^openslide_python\.libs/libxml2-[0-9a-f-]+\.dll$',
            '^openslide_python\.libs/jxrglue-[0-9a-f]+\.dll$',
            '^openslide_python\.libs/jpegxr-[0-9a-f]+\.dll$',
            '^openslide_python\.libs/openjp2-[0-9a-f]+\.dll$',
            '^openslide_python\.libs/tiff-[0-9a-f]+\.dll$',
            '^openslide_python\.libs/vcruntime140\.dll$',
            '^openslide_python\.libs/vcruntime140_1\.dll$',
            '^openslide_python\.libs/slidetool\.exe$',
            '^openslide/bin/slidetool\.exe$',
            '^openslide/_convert.*\.pyd$') 'openslide_python'
    }
    $repaired = @(Get-ChildItem -Path $WheelsDir -Filter 'openslide_python-*win_amd64*.whl' -File)
    if ($repaired.Count -lt $kept.Count) {
        Die "openslide_python: only $($repaired.Count) wheels, expected $($kept.Count)"
    }
    Done-Stamp 'openslide_python'
}

# The pyvips wheel bundles libvips and its whole dependency tree plus the
# vips tools and magick in pyvips/bin, like the linux and macos wheels.
# The cffi extension is API mode, so
# there is one wheel per python; it is compiled against the prefix's
# libvips through pkg-config (the pkgconfig python package honors
# PKG_CONFIG and PKG_CONFIG_LIBDIR), and delvewheel follows its import
# of the vips DLL into the whole tree.
function Build-Pyvips {
    if (Skip-If-Done 'pyvips') { return }
    Log '=== pyvips'
    $pp = $script:PatchPython

    & $pp -m pip install --quiet --no-warn-script-location -U "delvewheel==$(V delvewheel)" | Out-Null
    Assert-Exit 'pip install of delvewheel failed'

    $src = Git-Clone 'https://github.com/libvips/pyvips.git' "v$(V pyvips)" (Join-Path $LIW_SRC 'pyvips')

    # The vips tools from the prefix (meson installs what the linux build
    # copies out of its tools directory; vipsprofile is a python script
    # and is not a tool here) and magick, as the linux build copies it
    # from its prefix.
    $binDir = Join-Path $src 'pyvips\bin'
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    foreach ($tool in @('vips', 'vipsedit', 'vipsheader', 'vipsthumbnail', 'magick')) {
        $exe = Join-Path $LIW_PREFIX "bin\$tool.exe"
        if (-not (Test-Path $exe)) { Die "pyvips: no $tool.exe in the prefix to bundle" }
        Copy-Item $exe $binDir -Force
    }
    Set-Content -Path (Join-Path $binDir '__init__.py') -Value $script:ToolWrapper -Encoding ascii

    # Preload the bundled libvips before the extension is imported, as the
    # linux and macos wheels do (delvewheel's own patch puts pyvips.libs on
    # the DLL search path first; this is belt and braces, and it is what
    # the ABI-mode fallback would need).  vips-42-<hash>.dll sorts before
    # vips-cpp-42-<hash>.dll.
    Invoke-Patch $src 'pyvips_init' @'
path = "pyvips/__init__.py"
s = open(path).read().replace(
"""    import _libvips""",
"""    import ctypes
    import os
    libpath = os.path.abspath(os.path.join(os.path.dirname(os.path.dirname(
        os.path.realpath(__file__))), 'pyvips.libs'))
    if os.path.exists(libpath):
        libs = sorted(os.listdir(libpath))
        libvipspath = [lib for lib in libs
                       if lib.startswith('vips-') or lib.startswith('libvips-')]
        if libvipspath:
            ctypes.cdll.LoadLibrary(os.path.join(libpath, libvipspath[0]))
    from . import _libvips""")
open(path, "w").write(s)
'@
    # Name the cffi extension pyvips._libvips so the patched import
    # resolves to it.
    Invoke-Patch $src 'pyvips_build' @'
path = "pyvips/pyvips_build.py"
s = open(path).read().replace(
"""ffibuilder.set_source("_libvips",""",
"""ffibuilder.set_source("pyvips._libvips",""")
open(path, "w").write(s)
'@
    # The combined version (package version + bundled libvips version),
    # matching the linux wheel versioning.
    Invoke-Patch $src 'pyvips_version' @"
import re
path = "pyvips/version.py"
s = open(path).read()
s = re.sub(r'__version__ = "(.+?)"',
           lambda match: '__version__ = "%s.$(V libvips)"' % match.group(1), s)
open(path, "w").write(s)
"@
    # setup.py falls back to an ABI-mode (pure python, no bundled libvips)
    # wheel when the cffi extension fails to build, silently -- the wheel
    # would then install and import while using whatever libvips it finds
    # at run time, which is the isolation failure this pipeline exists to
    # prevent.  API mode or nothing.
    Invoke-Patch $src 'pyvips_setup' @'
path = "setup.py"
s = open(path).read()
old = """try:
    setup(cffi_modules=['pyvips/pyvips_build.py:ffibuilder'])
except Exception as e:
    print(f'Falling back to ABI mode. Details: {e}')
    setup()
"""
assert old in s, "pyvips's setup.py fallback changed"
s = s.replace(old, "setup(cffi_modules=['pyvips/pyvips_build.py:ffibuilder'])\n")
open(path, "w").write(s)
'@
    # Expose the bundled tools as console scripts (named without .exe: a
    # script named vips.exe would be installed as vips.exe.exe) and include
    # them as package data.  (The linux build also patches setup.py for
    # package data, which is a no-op on pyvips 3.2.0.)
    Invoke-Patch $src 'pyvips_pyproject' @'
import os
path = "pyproject.toml"
s = open(path).read()
s = s.replace("include-package-data = false", "include-package-data = true")
s += "\n[tool.setuptools.package-data]\npyvips = [\"bin/*\"]\n\n[project.scripts]\n"
for name in sorted(os.listdir("pyvips/bin")):
    if name.endswith(".exe"):
        s += "%s = 'pyvips.bin:program'\n" % os.path.splitext(name)[0]
open(path, "w").write(s)
'@
    Commit-Patches $src "$(V pyvips).$(V libvips)"

    Remove-Item -Path (Join-Path $LIW_WHEELHOUSE 'pyvips-*.whl') -Force -ErrorAction SilentlyContinue
    foreach ($minor in $script:Pythons) {
        $pybin = Join-Path $LIW_PY $minor
        Log "pyvips wheel: python $minor"
        if (Test-Path (Join-Path $src 'build')) { Remove-Item -Recurse -Force (Join-Path $src 'build') }
        Run-Logged (Join-Path $pybin 'python.exe') @(
            '-m', 'pip', 'wheel', '--no-deps', '--progress-bar', 'off',
            '-w', $LIW_WHEELHOUSE, $src) "pyvips wheel build for python $minor"
    }

    Log 'delvewheel repair of the pyvips wheels'
    Remove-Item -Path (Join-Path $WheelsDir 'pyvips-*.whl') -Force -ErrorAction SilentlyContinue
    foreach ($whl in (Get-ChildItem -Path $LIW_WHEELHOUSE -Filter 'pyvips-*.whl' -File)) {
        # (vcomp140.dll: MagickCore's OpenMP runtime, from the redist's
        # OpenMP directory; delvewheel treats it like msvcp140.dll.
        # gdiplus.dll: a Windows component MagickCore's emf coder imports;
        # it lives in WinSxS rather than System32, so delvewheel does not
        # know it as a system DLL and would copy the sandbox's into the
        # wheel.)
        Run-Logged $pp @(
            '-m', 'delvewheel', 'repair', '-w', $WheelsDir,
            '--add-path', "$(Join-Path $LIW_PREFIX 'bin');$script:VcRedist;$script:VcOpenMP",
            '--analyze-existing-exes',
            '--include', "$script:VipsDll;vcruntime140.dll;vcruntime140_1.dll",
            '--exclude', 'gdiplus.dll',
            '--no-mangle', 'vcruntime140.dll;vcruntime140_1.dll',
            $whl.FullName) "delvewheel repair of $($whl.Name)"
        $out = Join-Path $WheelsDir $whl.Name
        Relocate-Tools $out 'pyvips' 'pyvips.libs'
        Assert-WheelContains $out @(
            '^pyvips\.libs/(lib)?vips-42[0-9a-f-]*\.dll$',
            '^pyvips\.libs/MagickCore-7\.Q16HDRI-[0-9a-f]+\.dll$',
            '^pyvips\.libs/MagickWand-7\.Q16HDRI-[0-9a-f]+\.dll$',
            '^pyvips\.libs/vcomp140-[0-9a-f]+\.dll$',
            '^pyvips\.libs/zip-[0-9a-f]+\.dll$',
            '^pyvips\.libs/bz2-[0-9a-f]+\.dll$',
            '^pyvips\.libs/poppler-glib-[0-9a-f]+\.dll$',
            '^pyvips\.libs/rsvg-2[0-9a-f.-]*\.dll$',
            '^pyvips\.libs/heif-[0-9a-f]+\.dll$',
            '^pyvips\.libs/jxl-[0-9a-f]+\.dll$',
            '^pyvips\.libs/imagequant-[0-9a-f]+\.dll$',
            '^pyvips\.libs/libopenslide-1-[0-9a-f]+\.dll$',
            '^pyvips\.libs/pangocairo-1\.0-[0-9a-f-]+\.dll$',
            '^pyvips\.libs/tiff-[0-9a-f]+\.dll$',
            '^pyvips\.libs/msvcp140-[0-9a-f]+\.dll$',
            '^pyvips\.libs/vcruntime140\.dll$',
            '^pyvips\.libs/vcruntime140_1\.dll$',
            '^pyvips\.libs/vips\.exe$',
            '^pyvips\.libs/magick\.exe$',
            '^pyvips/bin/vips\.exe$',
            '^pyvips/bin/magick\.exe$',
            '^pyvips/_libvips.*\.pyd$') 'pyvips'
    }
    $repaired = @(Get-ChildItem -Path $WheelsDir -Filter 'pyvips-*win_amd64*.whl' -File)
    if ($repaired.Count -lt $script:Pythons.Count) {
        Die "pyvips: only $($repaired.Count) wheels, expected $($script:Pythons.Count)"
    }
    Done-Stamp 'pyvips'
}

# --------------------------------------------------------------------------
# Main.
# --------------------------------------------------------------------------

# -DevSetup, after the toolchain: the extras development needs that the
# build does not (requests and packaging for check_versions.py), into the
# checkout's own python (--user: the agent sandbox's tools tree is not
# writable).
function Install-DevExtras {
    if (-not $script:CheckoutPython) {
        Log 'dev setup: no python on PATH; check_versions.py will need requests and packaging'
        return
    }
    Log "dev setup: installing requests and packaging for check_versions.py into $script:CheckoutPython"
    Run-Logged $script:CheckoutPython @('-m', 'pip', 'install', '--quiet', '--user',
        'requests', 'packaging') 'pip install of requests/packaging'
    Log 'dev setup: done; build with: powershell -File windows\build_wheels.ps1 -Packages <pkg> -Pythons <ver>'
}

function Main {
    Log "=== build_wheels.ps1 started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Log "mode: $(if ($script:DevMode) { 'dev (' + $RepoDir + ')' } else { 'build sandbox' })"
    Log "parameters from: $($script:ArgsSource)"
    Log "pythons: $($script:Pythons -join ' ')"
    Log "packages: $($script:Packages -join ' ')"
    if ($DevSetup -and -not $script:DevMode) {
        Die '-DevSetup is for a checkout; the build sandbox sets up its own toolchain on every run'
    }

    # Pythons first: V() runs getver.py with the patch python, and the
    # toolchain pins come from versions.txt.
    Ensure-Pythons
    Ensure-Toolchain
    Set-BuildPath
    Enter-Msvc

    if ($script:Command -eq 'cache') {
        Log '=== cache warm-up complete (toolchain and pythons installed)'
        if ($DevSetup) { Install-DevExtras }
        return
    }
    if ($script:Packages.Count -eq 0) {
        Die 'no packages requested (-Packages, LIW_PYTHONS/args.json, or the launcher)'
    }

    foreach ($pkg in $script:Packages) {
        switch ($pkg) {
            'pylibtiff' {
                Build-Zlib
                Build-Zstd
                Build-Jbigkit
                Build-Libwebp
                Build-Libjpeg-Turbo
                Build-Libdeflate
                Build-Xz
                Build-Libtiff
                Build-Pylibtiff
            }
            'glymur' {
                Build-Zlib
                Build-Zstd
                Build-Jbigkit
                Build-Libwebp
                Build-Libjpeg-Turbo
                Build-Libdeflate
                Build-Xz
                Build-Libtiff
                Build-Lcms2
                Build-Libpng
                Build-Openjpeg
                Build-Glymur
            }
            'openslide_python' {
                Ensure-Meson
                Ensure-Clang
                Build-Zlib
                Build-Bzip2
                Build-Zstd
                Build-Jbigkit
                Build-Libwebp
                Build-Libjpeg-Turbo
                Build-Libdeflate
                Build-Xz
                Build-Libtiff
                Build-Lcms2
                Build-Libpng
                Build-Openjpeg
                Build-Libbrotli
                Build-Libexpat
                Build-Glib
                Build-Sqlite
                Build-Libxml2
                Build-Pixman
                Build-Freetype
                Build-Fontconfig
                Build-Cairo
                Build-Jxrlib
                Build-Openslide
                Build-OpenslidePython
            }
            'pyvips' {
                Ensure-Meson
                Build-Zlib
                Build-Bzip2
                Build-Zstd
                Build-Jbigkit
                Build-Libwebp
                Build-Libjpeg-Turbo
                Build-Libdeflate
                Build-Xz
                Build-Libzip
                Build-Libtiff
                Build-Lcms2
                Build-Libpng
                Build-Openjpeg
                Build-Libbrotli
                Build-Libexpat
                Build-Glib
                Build-Sqlite
                Build-Libxml2
                Build-Pixman
                Build-Freetype
                Build-Fontconfig
                Build-Cairo
                Build-Jxrlib
                Build-Openslide
                Build-Lz4
                Build-Nifti
                Build-Fftw3
                Build-Libhwy
                Build-Openexr
                Build-Jpeg-Xl
                Build-Libimagequant
                Build-Libexif
                Build-Libarchive
                Build-Libraw
                Build-Harfbuzz
                Build-Pango
                Build-Librsvg
                Build-Libde265
                Build-Libheif
                Build-Curl
                Build-Poppler
                Build-Fitsio
                Build-Hdf5
                Build-Matio
                Build-Imagemagick
                Build-Libvips
                Build-Pyvips
            }
            'gdal' {
                # The macos gdal case's order (the Dockerfile's final state
                # for everything GDAL's cmake can detect), minus the MPI
                # stack, plus the Windows-only tools and win-iconv; the
                # glib/cairo chain and harfbuzz are here because poppler
                # (built with its glib wrapper, shared with the pyvips
                # tree) needs them and librasterlite2 needs cairo.
                Ensure-Meson
                Build-Zlib
                Build-Bzip2
                Build-Zstd
                Build-Jbigkit
                Build-Libwebp
                Build-Libjpeg-Turbo
                Build-Libdeflate
                Build-Xz
                Build-Libtiff
                Build-Giflib
                Build-Openssl
                Build-Libbrotli
                Build-Curl
                Build-Json-C
                Build-Lerc
                Build-Lcms2
                Build-Libpng
                Build-Openjpeg
                Build-Libhwy
                Build-Jpeg-Xl
                Build-Libexpat
                Build-Sqlite
                Build-Libxml2
                Build-Lz4
                Build-Libarchive
                Build-Win-Iconv
                Build-Proj4
                Build-Pixman
                Build-Freetype
                Build-Fontconfig
                Build-Glib
                Build-Cairo
                Build-Minizip
                Build-Freexl
                Build-Libgeos
                Build-Librttopo
                Build-Libspatialite
                Build-Libgeotiff
                Build-Librasterlite2
                Build-Fyba
                Build-Hdf4
                Build-Hdf5
                Build-Netcdf
                Build-Mysql
                Build-Postgresql
                Build-Libgta
                Build-Xerces-C
                Build-Blosc
                Build-Highfive
                Build-Kealib
                Build-Libde265
                Build-Libheif
                Build-Harfbuzz
                Build-Poppler
                Build-Fitsio
                Build-Openexr
                Build-Libopendrive
                Build-Libavif
                Build-Gdal
                Build-GdalPython
            }
            default {
                if ($pkg.StartsWith('dep:')) {
                    # One library on its own, for staged verification (the
                    # macos build offers the same); its dependencies must
                    # already be in the prefix, so list them first:
                    # -Packages dep:zlib,dep:zstd,...  The wheel validation
                    # of sandbox_run.ps1 skips dep: entries.
                    $builder = Get-Command "Build-$($pkg.Substring(4))" -CommandType Function `
                        -ErrorAction SilentlyContinue
                    if (-not $builder) { Die "no builder for $pkg" }
                    Ensure-Meson
                    & $builder
                } else {
                    Die "no builder for package $pkg"
                }
            }
        }
    }
    Log "=== build_wheels.ps1 finished $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
}

New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
$exitCode = 0
try {
    Main
} catch {
    Log "error: $($_.Exception.Message)"
    if ($_.InvocationInfo) {
        Log "error: at $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)"
    }
    $exitCode = 1
}
Set-Content -Path $ExitCodePath -Value $exitCode -Encoding ascii
Log "=== exit code $exitCode"
# As on macos: the log is out (streamed to the host and saved in the
# mapped run folder), so shut the build environment down; the sandbox
# holds the single-instance slot, so there is no virtue in leaving it
# running.  The short delay lets the last log writes flush.  Dev mode
# (a checkout, not a disposable sandbox) is left alone.
if (-not $script:DevMode) {
    & shutdown.exe /s /t 5
}
exit $exitCode
