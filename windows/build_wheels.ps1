# build_wheels.ps1 - build Windows x64 wheels inside a Windows Sandbox.
#
# This is the Windows counterpart of the repository's monolithic Dockerfile:
# a single self-contained script that installs the toolchain, builds every
# library a wheel needs from source into a private prefix with the pinned
# versions from the shared versions.txt, then builds and repairs the python
# wheels.  It is meant to run inside a fresh Windows Sandbox (started by
# sandbox_build.ps1 on the host through the .wsb LogonCommand, which runs as
# the elevated sandbox account) so that nothing from the host's installed
# software can influence the built wheels.  It can also be run directly
# inside an open sandbox for quick iteration.
#
# Mapped folders (created by sandbox_build.ps1):
#   C:\mnt\repo    the repository (read-only)
#   C:\mnt\cache   the download cache (read-write; holds upstream artifacts
#                  only -- toolchains, pythons, source tarballs.  Nothing
#                  built and no stamps are ever read from or written to it)
#   C:\mnt\wheels  wheel output (read-write; repaired wheels land here)
#   C:\mnt\run     per-run exchange (read-write; log, args.json, exit_code)
#
# Everything is built in C:\liw_build (sandbox-local disk; mapped folders
# are slow).  The sandbox is disposable: no state outside the mapped
# folders survives the run.
#
# Environment notes:
#   LIW_PYTHONS   python versions to build for (default "3.11 3.12 3.13
#                 3.14 3.15"; free-threaded variants are not verified on
#                 Windows yet)
#   LIW_FORCE     set to 1 to ignore completed-step stamps and rebuild all
#   LIW_BUILD     working directory (default C:\liw_build)
#
# Completed steps are stamped, so re-running this script only redoes what
# has not finished.  Stamps are for debugging; verification is always a
# full fresh sandbox run.

param(
    [switch]$WarmCache
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 (the sandbox's default) may not negotiate TLS 1.2
# on its own; the GitHub and NuGet APIs require it.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --------------------------------------------------------------------------
# Run exchange.
# --------------------------------------------------------------------------

$RunDir = 'C:\mnt\run'
$RepoDir = 'C:\mnt\repo'
$CacheDir = 'C:\mnt\cache'
$WheelsDir = 'C:\mnt\wheels'
$LogPath = Join-Path $RunDir 'build.log'
$ExitCodePath = Join-Path $RunDir 'exit_code'

function Log([string]$Message) {
    Write-Host $Message
    Add-Content -Path $LogPath -Value $Message -Encoding utf8
}

function Die([string]$Message) {
    Log "error: $Message"
    throw "build_wheels: $Message"
}

function Assert-Exit([string]$What) {
    if ($LASTEXITCODE -ne 0) {
        Die "$What failed (exit code $LASTEXITCODE)"
    }
}

# --------------------------------------------------------------------------
# Build layout and environment.
# --------------------------------------------------------------------------

$LIW_BUILD = 'C:\liw_build'
$LIW_PREFIX = Join-Path $LIW_BUILD 'prefix'
$LIW_SRC = Join-Path $LIW_BUILD 'src'
$LIW_STAMPS = Join-Path $LIW_BUILD 'stamps'
$LIW_PATCHES = Join-Path $LIW_BUILD 'patches'
$LIW_WHEELHOUSE = Join-Path $LIW_BUILD 'wheelhouse'
$LIW_TOOLS = Join-Path $LIW_BUILD 'tools'
$LIW_PY = Join-Path $LIW_BUILD 'python'
$LIW_DL = Join-Path $LIW_BUILD 'dl'
$LIW_JOBS = $env:NUMBER_OF_PROCESSORS

foreach ($dir in @($LIW_BUILD, $LIW_PREFIX, $LIW_SRC, $LIW_STAMPS,
                   $LIW_PATCHES, $LIW_WHEELHOUSE, $LIW_TOOLS, $LIW_DL)) {
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
$script:Pythons = @('3.11', '3.12', '3.13', '3.14', '3.15')
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
# The run exchange persists between runs now that the launcher may be the
# static .wsb (which does not reset it), so clear the last run's markers;
# the log is recreated by the first Log call.  A stale args.json from an
# earlier launcher run is possible; the parameter source is logged so a
# static-.wsb run that picks one up is visible at once.
Remove-Item -Path (Join-Path $RunDir 'exit_code') -Force `
    -ErrorAction SilentlyContinue
Remove-Item -Path $LogPath -Force -ErrorAction SilentlyContinue

# The tool paths are filled in by Ensure-Toolchain; the sandbox PATH is
# scrubbed to system dirs plus these, so no other installed software can
# supply headers, link targets, or DLLs.
$script:ToolPaths = @()

# --------------------------------------------------------------------------
# Helpers.
# --------------------------------------------------------------------------

function Skip-If-Done([string]$Name) {
    if ($env:LIW_FORCE -eq '1') { return $false }
    return (Test-Path (Join-Path $LIW_STAMPS "$Name.done"))
}

function Done-Stamp([string]$Name) {
    New-Item -ItemType File -Force -Path (Join-Path $LIW_STAMPS "$Name.done") | Out-Null
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
# outputs.  Expansion happens in the sandbox-local C:\liw_build.
function Fetch([string]$Url, [string]$Name) {
    $downloads = Join-Path $CacheDir 'downloads'
    New-Item -ItemType Directory -Force -Path $downloads | Out-Null
    $dest = Join-Path $downloads $Name
    if (Test-Path $dest) {
        Log "cached: $Name"
        return $dest
    }
    Log "downloading $Url"
    & curl.exe --retry 5 --silent --location --fail $Url -o $dest
    Assert-Exit "download failed: $Url"
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
    Expand-Archive -Path $zipPath -DestinationPath $Dest
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

function Fetch-Tarball([string]$Url, [string]$Name, [string]$Dest) {
    $tarball = Fetch $Url $Name
    if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    & tar -zxf $tarball -C $Dest --strip-components 1
    Assert-Exit "tar extraction failed: $Name"
    return $Dest
}

# Build and install a cmake project into the private prefix with Ninja and
# the MSVC toolset (entered through the VS Dev Shell; INCLUDE/LIB point at
# the MSVC and Windows SDK directories, with the private prefix first).
function Cmake-Build([string]$Src, [string[]]$CmakeArgs = @()) {
    $build = Join-Path $Src '_build'
    if (Test-Path $build) { Remove-Item -Recurse -Force $build }
    & cmake -S $Src -B $build -G Ninja `
        -DCMAKE_BUILD_TYPE=MinSizeRel `
        -DCMAKE_PREFIX_PATH=$LIW_PREFIX `
        -DCMAKE_INSTALL_PREFIX=$LIW_PREFIX `
        -DCMAKE_INSTALL_LIBDIR=lib `
        @CmakeArgs
    Assert-Exit "cmake configure failed in $Src"
    & cmake --build $build --parallel $LIW_JOBS
    Assert-Exit "cmake build failed in $Src"
    & cmake --install $build
    Assert-Exit "cmake install failed in $Src"
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

# dumpbin /DEPENDENTS listing for one image, as a flat set of names.
function Get-Dependents([string]$Image) {
    $out = (& dumpbin /DEPENDENTS $Image | Out-String)
    $names = @()
    foreach ($line in ($out -split "`n")) {
        if ($line -match '\.dll') {
            $names += ($line.Trim() -split '\s+')
        }
    }
    return $names | Where-Object { $_ }
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

# Get-GitHubAsset / Get-Json: ported from the agent sandbox payload's
# well-tested helpers (browser download url of the newest release asset
# matching a regex; pre-releases considered when no stable release has one).
function Get-Json([string]$Url) {
    return Invoke-RestMethod -Uri $Url -Headers @{
        'User-Agent' = 'large_image_wheels'
    }
}

function Get-GitHubAsset([string]$Repo, [string]$Pattern) {
    foreach ($release in (Get-Json "https://api.github.com/repos/$Repo/releases?per_page=15")) {
        $asset = $release.assets |
            Where-Object { $_.name -match $Pattern } |
            Select-Object -First 1
        if ($asset) {
            return @{ Url = $asset.browser_download_url; Tag = $release.tag_name }
        }
    }
    throw "no asset matching $Pattern in $Repo releases"
}

# Run a native command with its output streamed into the log.  Native
# stderr must not be redirected while $ErrorActionPreference is Stop (the
# redirection turns stderr lines into terminating error records in
# Windows PowerShell 5.1), so it is relaxed for the duration.
function Run-Logged([string]$Exe, [string[]]$CmdArgs, [string]$What) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Exe @CmdArgs 2>&1 | ForEach-Object { Log "$_" }
    } finally {
        $ErrorActionPreference = $prev
    }
    Assert-Exit "$What failed"
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

function Ensure-Toolchain {
    $bin = Join-Path $LIW_TOOLS 'bin'
    New-Item -ItemType Directory -Force -Path $bin | Out-Null

    # --- git (PortableGit; bash comes with it for the shared test script)
    $gitDir = Join-Path $LIW_TOOLS 'git'
    if (-not (Test-Path (Join-Path $gitDir 'bin\bash.exe'))) {
        Log 'fetching PortableGit'
        $asset = Get-GitHubAsset 'git-for-windows/git' '^PortableGit-.*-64-bit\.7z\.exe$'
        $file = Fetch $asset.Url 'PortableGit.7z.exe'
        if (Test-Path $gitDir) { Remove-Item -Recurse -Force $gitDir }
        $proc = Start-Process -FilePath $file `
            -ArgumentList "-o `"$gitDir`" -y" -Wait -PassThru
        if ($proc.ExitCode -ne 0) { Die 'PortableGit extraction failed' }
        if (-not (Test-Path (Join-Path $gitDir 'bin\bash.exe'))) {
            Die 'bash.exe missing after PortableGit extraction'
        }
    }
    $script:ToolPaths += (Join-Path $gitDir 'cmd')
    $script:ToolPaths += (Join-Path $gitDir 'bin')

    # --- cmake and ninja
    $cmakeDir = Join-Path $LIW_TOOLS 'cmake'
    if (-not (Test-Path (Join-Path $cmakeDir '.installed'))) {
        Log 'fetching cmake'
        $asset = Get-GitHubAsset 'Kitware/CMake' '^cmake-.*-windows-x86_64\.zip$'
        Expand-Zip (Fetch $asset.Url 'cmake.zip') $cmakeDir
        New-Item -ItemType File -Force -Path (Join-Path $cmakeDir '.installed') | Out-Null
    }
    Add-ToolPath $cmakeDir 'cmake.exe' | Out-Null
    $ninjaFile = Join-Path $bin 'ninja.exe'
    if (-not (Test-Path $ninjaFile)) {
        Log 'fetching ninja'
        Copy-Item (Fetch 'https://github.com/ninja-build/ninja/releases/latest/download/ninja-win.zip' 'ninja-win.zip') "$ninjaFile.zip"
        Expand-Zip "$ninjaFile.zip" (Join-Path $LIW_DL 'ninja')
        Copy-Item (Add-ToolPath (Join-Path $LIW_DL 'ninja') 'ninja.exe') $ninjaFile -Force
    }
    if ($script:ToolPaths -notcontains $bin) { $script:ToolPaths += $bin }

    # --- nasm (libjpeg-turbo SIMD; x86-only upstream, fine while win_amd64
    # is the only target)
    $nasmDir = Join-Path $LIW_TOOLS 'nasm'
    if (-not (Test-Path (Join-Path $nasmDir '.installed'))) {
        Log 'fetching nasm'
        $nasmVersion = '2.16.03'
        $url = "https://www.nasm.us/pub/nasm/releasebuilds/$nasmVersion/win64/nasm-$nasmVersion-win64.zip"
        Expand-Zip (Fetch $url "nasm-$nasmVersion-win64.zip") $nasmDir
        New-Item -ItemType File -Force -Path (Join-Path $nasmDir '.installed') | Out-Null
    }
    Add-ToolPath $nasmDir 'nasm.exe' | Out-Null

    # --- VS Build Tools (MSVC x64 + Windows SDK).  Cannot live in the
    # cache (it installs into Program Files), so every run pays the
    # install.  The payload itself can live in the cache as an offline
    # --layout (built once by the cache warm-up), which avoids the
    # per-run download and pins the VS version; runs without a cached
    # layout fall back to the bootstrapper-from-net.
    if ($WarmCache) {
        $vsLayout = Join-Path (Join-Path $CacheDir 'downloads') 'vs_layout'
        if (-not (Test-Path (Join-Path $vsLayout 'vs_buildtools.exe'))) {
            Log 'fetching the VS Build Tools offline layout (once; several GB)'
            $boot = Fetch 'https://aka.ms/vs/17/release/vs_buildtools.exe' 'vs_buildtools.exe'
            $proc = Start-Process -FilePath $boot -Wait -PassThru `
                -ArgumentList @('--quiet', '--layout', $vsLayout,
                                '--lang', 'en-US',
                                '--add',
                                'Microsoft.VisualStudio.Workload.VCTools',
                                '--includeRecommended')
            if ($proc.ExitCode -ne 0) {
                Die "VS layout fetch failed (exit code $($proc.ExitCode))"
            }
            if (-not (Test-Path (Join-Path $vsLayout 'vs_buildtools.exe'))) {
                Die 'the VS layout fetch produced no bootstrapper'
            }
        } else {
            Log 'the VS Build Tools offline layout is already cached'
        }
        return
    }
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $vsPath = $null
    if (Test-Path $vswhere) {
        $vsPath = & $vswhere -latest -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath
    }
    if (-not $vsPath) {
        $vsAdd = @('--add', 'Microsoft.VisualStudio.Workload.VCTools',
                   '--includeRecommended')
        $vsLayout = Join-Path (Join-Path $CacheDir 'downloads') 'vs_layout'
        $layoutBoot = Join-Path $vsLayout 'vs_buildtools.exe'
        if (Test-Path $layoutBoot) {
            Log ('installing VS Build Tools from the cached offline ' +
                'layout (several minutes, no download)')
            $proc = Start-Process -FilePath $layoutBoot -Wait -PassThru `
                -ArgumentList (@('--quiet', '--wait', '--norestart',
                                 '--nocache', '--noWeb') + $vsAdd)
            if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
                Die ('VS Build Tools install from the layout failed ' +
                    "(exit code $($proc.ExitCode))")
            }
        } else {
            Log ('installing VS Build Tools (C++ x64 workload; several ' +
                'minutes); pre-warm an offline layout with -Command ' +
                'cache to skip the per-run download and pin the VS ' +
                'version')
            $boot = Fetch 'https://aka.ms/vs/17/release/vs_buildtools.exe' 'vs_buildtools.exe'
            $proc = Start-Process -FilePath $boot -Wait -PassThru `
                -ArgumentList (@('--quiet', '--wait', '--norestart',
                                 '--nocache') + $vsAdd)
            if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
                Die "VS Build Tools install failed (exit code $($proc.ExitCode))"
            }
        }
        $vsPath = & $vswhere -latest -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath
        if (-not $vsPath) { Die 'VS Build Tools installed but not found by vswhere' }
    }
    $script:VsPath = $vsPath
    Log "using VS Build Tools at $vsPath"
}

function Ensure-Pythons {
    # python.org builds via their NuGet packages (no installer, no machine
    # state beyond the expanded directory), one directory per minor under
    # C:\liw_build\python.
    $index = Get-Json 'https://api.nuget.org/v3-flatcontainer/python/index.json'
    foreach ($minor in $script:Pythons) {
        $dest = Join-Path $LIW_PY $minor
        if (Test-Path (Join-Path $dest 'python.exe')) { continue }
        # Free-threaded builds must not be picked for the normal pythons;
        # exclude both prerelease and free-threaded version strings.
        $candidates = @($index.versions |
            Where-Object { $_ -like "$minor.*" -and $_ -notmatch '[t-]' })
        if ($candidates.Count -eq 0) {
            Die "no stable python $minor on nuget.org"
        }
        $full = $candidates | Sort-Object { [version]$_ } | Select-Object -Last 1
        Log "installing python $full"
        $file = Fetch "https://api.nuget.org/v3-flatcontainer/python/$full/python.$full.nupkg" "python-$full.nupkg"
        Expand-Zip $file (Join-Path $LIW_DL "python-$full")
        if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
        Move-Item (Join-Path $LIW_DL "python-$full\tools") $dest
        & (Join-Path $dest 'python.exe') -m ensurepip --upgrade | Out-Null
        Assert-Exit "ensurepip failed for python $full"
        & (Join-Path $dest 'python.exe') -m pip install --quiet `
            --no-warn-script-location --upgrade pip setuptools wheel | Out-Null
        Assert-Exit "pip bootstrap failed for python $full"
    }
    # The patch python (newest requested) runs getver.py, writes the source
    # patches, and drives delvewheel.
    $best = $null
    foreach ($minor in $script:Pythons) {
        $candidate = Join-Path $LIW_PY "$minor\python.exe"
        if (Test-Path $candidate) {
            if (-not $best -or
                ([version]($minor) -gt [version]($best))) {
                $best = $minor
            }
        }
    }
    if (-not $best) { Die 'no python was installed' }
    $script:PatchPython = Join-Path $LIW_PY "$best\python.exe"
    Log "patch python: $script:PatchPython"
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

function Enter-DevShell {
    # Bring the MSVC toolset into this session (INCLUDE, LIB, PATH for cl,
    # link, dumpbin) for the x64 target.
    $module = Join-Path $script:VsPath 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll'
    if (-not (Test-Path $module)) {
        Die "VS Dev Shell module not found at $module"
    }
    Import-Module $module
    Enter-VsDevShell -VsInstallPath $script:VsPath -SkipAutomaticLocation `
        -DevCmdArguments '-arch=x64 -host_arch=x64'
    # The private prefix supplies our libraries; put it ahead of the SDK in
    # the search path for both the compiler and the linker.
    $env:INCLUDE = "$LIW_PREFIX\include;$env:INCLUDE"
    $env:LIB = "$LIW_PREFIX\lib;$env:LIB"
    # Re-assert the scrubbed PATH (the dev shell prepends its own entries).
    $env:PATH = ($env:PATH -split ';' |
        Where-Object { $_ -match '^[A-Za-z]:\\' }) -join ';'
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
    Cmake-Build $src @('-DZLIB_BUILD_TESTING=OFF')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('zlib*.dll') 'zlib'
    Done-Stamp 'zlib'
}

function Build-Zstd {
    if (Skip-If-Done 'zstd') { return }
    Log '=== zstd'
    $src = Git-Clone 'https://github.com/facebook/zstd' "v$(V zstd)" `
        (Join-Path $LIW_SRC 'zstd')
    Cmake-Build (Join-Path $src 'build\cmake') @(
        '-DBUILD_SHARED_LIBS=ON', '-DZSTD_BUILD_STATIC=OFF',
        '-DZSTD_BUILD_PROGRAMS=OFF', '-DZSTD_BUILD_TESTS=OFF')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('libzstd*.dll') 'zstd'
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
    Cmake-Build $src @(
        '-DWEBP_BUILD_CWEBP=OFF', '-DWEBP_BUILD_DWEBP=OFF',
        '-DWEBP_BUILD_GIF2WEBP=OFF', '-DWEBP_BUILD_IMG2WEBP=OFF',
        '-DWEBP_BUILD_VWEBP=OFF', '-DWEBP_BUILD_WEBPINFO=OFF',
        '-DWEBP_BUILD_WEBPQUALITY=OFF', '-DWEBP_BUILD_EXTRAS=OFF',
        '-DWEBP_BUILD_LIBWEBPMUX=ON', '-DWEBP_BUILD_LIBWEBPDECODER=ON')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @(
        'libwebp*.dll', 'libwebpmux*.dll', 'libwebpdecoder*.dll') 'libwebp'
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
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('libdeflate*.dll') 'libdeflate'
    Done-Stamp 'libdeflate'
}

function Build-Xz {
    if (Skip-If-Done 'xz') { return }
    Log '=== xz'
    $src = Git-Clone 'https://github.com/tukaani-project/xz.git' "v$(V xz)" `
        (Join-Path $LIW_SRC 'xz')
    Cmake-Build $src @(
        '-DBUILD_SHARED_LIBS=ON', '-DBUILD_TESTING=OFF', '-DENABLE_NLS=OFF')
    Assert-Files (Join-Path $LIW_PREFIX 'bin') @('liblzma*.dll') 'xz'
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
    Cmake-Build $src @(
        '-Dzlib=ON', '-Djpeg=ON', '-Djbig=ON', '-Dzstd=ON', '-Dwebp=ON',
        '-Ddeflate=ON', '-Dlibdeflate=ON',
        "-DJBIG_LIBRARY=$(Join-Path $LIW_PREFIX 'lib\libjbig.lib')",
        "-DJBIG_INCLUDE_DIR=$(Join-Path $LIW_PREFIX 'include')")
    # Feature assertions: the linux wheels' libtiff links zlib, jpeg, zstd,
    # webp, and libdeflate, and statically embeds jbig.  A missing optional
    # dependency at configure time would otherwise silently reduce the
    # feature set.
    $tiffconf = Join-Path $LIW_PREFIX 'include\tiffconf.h'
    if (-not (Test-Path $tiffconf)) {
        Die "libtiff: tiffconf.h not found at $tiffconf"
    }
    $conf = Get-Content $tiffconf -Raw
    foreach ($feature in @('ZIP_SUPPORT', 'JPEG_SUPPORT', 'JBIG_SUPPORT',
                           'ZSTD_SUPPORT', 'WEBP_SUPPORT',
                           'LIBDEFLATE_SUPPORT')) {
        if ($conf -notmatch "#define\s+$feature\s+1") {
            Die ("libtiff: $feature is not enabled in tiffconf.h (an " +
                'optional dependency was not found at configure time)')
        }
    }
    $tiffDll = Get-ChildItem -Path (Join-Path $LIW_PREFIX 'bin') `
        -Filter '*tiff*.dll' -File | Select-Object -First 1
    if (-not $tiffDll) { Die 'libtiff: no tiff DLL in the prefix' }
    Assert-Dependents $tiffDll.FullName @(
        'jpeg62.dll', 'zlib1.dll', 'libzstd.dll', 'libwebp.dll',
        'libdeflate.dll') 'libtiff'
    Done-Stamp 'libtiff'
}

# --------------------------------------------------------------------------
# Packages.
# --------------------------------------------------------------------------

function Build-Pylibtiff {
    if (Skip-If-Done 'pylibtiff') { return }
    Log '=== pylibtiff'
    $pp = $script:PatchPython

    & $pp -m pip install --quiet -U setuptools-scm delvewheel | Out-Null
    Assert-Exit 'pip install of setuptools-scm/delvewheel failed'

    $src = Git-Clone 'https://github.com/pearu/pylibtiff.git' "v$(V pylibtiff)" `
        (Join-Path $LIW_SRC 'pylibtiff')

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
    # macos/linux wrappers use os.execv).
    $wrapper = @'
import os
import subprocess
import sys

def program():
    path = os.path.join(os.path.dirname(__file__), os.path.basename(sys.argv[0]))
    sys.exit(subprocess.call([path] + sys.argv[1:]))
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
    "        ['%s=libtiff.bin:program' % name for name in os.listdir('libtiff/bin')\n"
    "         if not name.endswith('.py')] + [")
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
    & $pp -m pip install --quiet numpy | Out-Null
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

    Log 'delvewheel repair of the pylibtiff wheels'
    foreach ($whl in (Get-ChildItem -Path $LIW_WHEELHOUSE `
            -Filter 'pylibtiff-*.whl' -File)) {
        Run-Logged $pp @(
            '-m', 'delvewheel', 'repair', '-w', $WheelsDir, $whl.FullName) 
            "delvewheel repair of $($whl.Name)"
    }

    $expected = $script:Pythons.Count
    $found = @(Get-ChildItem -Path $WheelsDir `
        -Filter 'pylibtiff-*win_amd64*.whl' -File).Count
    if ($found -lt $expected) {
        Die "pylibtiff: only $found win_amd64 wheels, expected $expected"
    }
    Done-Stamp 'pylibtiff'
}

# --------------------------------------------------------------------------
# Main.
# --------------------------------------------------------------------------

function Main {
    Log "=== build_wheels.ps1 started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Log "parameters from: $($script:ArgsSource)"
    Log "pythons: $($script:Pythons -join ' ')"
    Log "packages: $($script:Packages -join ' ')"

    Ensure-Toolchain
    Ensure-Pythons
    Set-BuildPath
    Enter-DevShell

    if ($WarmCache -or $script:Command -eq 'cache') {
        Log '=== cache warm-up complete'
        return
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
            default {
                Die "no builder for package $pkg"
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
# running.  The short delay lets the last log writes flush.
& shutdown.exe /s /t 5
exit $exitCode
