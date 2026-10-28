# build_wheels.ps1 - build Windows x64 wheels inside a Windows Sandbox.
#
# This is the Windows counterpart of the repository's monolithic Dockerfile:
# a single self-contained script that installs the toolchain, builds every
# library a wheel needs from source into a private prefix with the pinned
# versions from the shared versions.txt, then builds and repairs the python
# wheels.  It is meant to run inside a fresh Windows Sandbox (started on
# the host through the .wsb LogonCommand) so that nothing from the host's
# installed software can influence the built wheels.
#
# Mapped folders (from build.wsb / sandbox_build.ps1):
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
# are installed into the build directory by windows\install_msvc.py (from
# Microsoft's VS manifest, at the versions pinned in versions.txt; the
# payloads are cached), PortableGit, cmake, ninja, nasm and the python.org
# NuGet pythons are expanded from cached downloads.
#
# Parameters / environment (parameters win, then the environment, then
# C:\mnt\run\args.json, then the defaults):
#   -Packages     packages to build (no default: the launcher names them)
#   -Pythons      python versions to build for (default 3.11-3.15 plus
#                 3.14t and 3.15t; a trailing t selects the free-threaded
#                 NuGet build)
#   -WarmCache    only download/install the toolchain and pythons, then stop
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
    [switch]$WarmCache
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
if ($WarmCache) { $script:Command = 'cache' }
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

# Log, Die, Assert-Exit, V, Fetch, Expand-Zip, Get-Json, Run-Logged,
# Ensure-Pythons, Ensure-PortableGit (shared with test_wheels.ps1).
. (Join-Path $PSScriptRoot 'liw_common.ps1')

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
    & cmake -S $Src -B $build -G Ninja `
        '-DCMAKE_BUILD_TYPE=MinSizeRel' `
        "-DCMAKE_PREFIX_PATH=$script:CmakePrefix" `
        "-DCMAKE_INSTALL_PREFIX=$script:CmakePrefix" `
        '-DCMAKE_INSTALL_LIBDIR=lib' `
        '-DCMAKE_DISABLE_FIND_PACKAGE_Tiff=ON' `
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

# Build the launcher (windows\launcher.c) for a wheel's library directory:
# the stand-in installed as <package>/bin/<tool>.exe that runs the real
# tool from <dist>.libs with that directory first on PATH (launcher.c
# explains why: no rpath on Windows).  Compiled once per library directory
# name, without the C runtime.
function Build-Launcher([string]$LibsName) {
    $exe = Join-Path $LIW_LAUNCHERS "$LibsName.exe"
    if (Test-Path $exe) { return $exe }
    $work = Join-Path $LIW_LAUNCHERS "$LibsName.build"
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    Push-Location $work
    try {
        # kernel32 only, static buffers, no optimizer (it would introduce
        # memset/memcpy calls), no security cookie.  (Run-Logged: cl prints
        # the source file name, which would otherwise become part of this
        # function's return value.)
        Run-Logged 'cl' @('/nologo', '/Od', '/GS-', '/W4', "/DLIW_LIBS_NAME=$LibsName",
            '/c', (Join-Path $RepoDir 'windows\launcher.c')) 'launcher compile'
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

# Every tool is pinned through versions.txt and fetched from a URL derived
# from the pin: the GitHub releases API is deliberately not used (it rate
# limits unauthenticated callers, and a NAT'd sandbox shares its address),
# and nothing is "latest".
function Ensure-Toolchain {
    $bin = Join-Path $LIW_TOOLS 'bin'
    New-Item -ItemType Directory -Force -Path $bin | Out-Null

    # --- git (PortableGit; the test sandbox uses the same package for bash)
    $gitDir = Ensure-PortableGit
    $script:ToolPaths += (Join-Path $gitDir 'cmd')
    $script:ToolPaths += (Join-Path $gitDir 'bin')

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
    # without elevation by windows\install_msvc.py at the pinned versions.
    # The manifest payloads live in the cache (so a sandbox run only
    # extracts); the install itself is sandbox-local.
    $msvcVersion = V 'msvc'
    $sdkVersion = V 'winsdk'
    $msvcDir = Join-Path $LIW_TOOLS 'msvc'
    $envJson = Join-Path $LIW_TOOLS 'msvc_env.json'
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
            '-I', (Join-Path $RepoDir 'windows\install_msvc.py'),
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
    Log "using MSVC $($info.msvc) and Windows SDK $($info.sdk) at $msvcDir (redist $script:VcRedist)"
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

# --------------------------------------------------------------------------
# Packages.
# --------------------------------------------------------------------------

# Expose each tool in <package>/bin as a console script that runs the
# launcher of the same name (after the repair, <package>/bin/<tool>.exe is
# windows\launcher.c, which finds the real tool in <dist>.libs).
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
    # libtiff/bin/<tool>.exe is the launcher (windows\launcher.c), which
    # finds the real tool and its DLLs in pylibtiff.libs itself.
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
    # mangled names.  vcruntime140.dll is forced in too (unmangled, as
    # delvewheel copies it): python ships one for its own extensions, but
    # the bundled tools run as separate processes in a directory where
    # nothing else provides it (a fresh Windows has no VC++ redistributable).
    # Mangling stays on: the Windows loader reuses an already-loaded module
    # by base name, so unmangled tiff.dll copies in two wheels would
    # silently share one (the hazard the linux BUILD_ID salt exists for).
    Log 'delvewheel repair of the pylibtiff wheels'
    foreach ($whl in (Get-ChildItem -Path $LIW_WHEELHOUSE `
            -Filter 'pylibtiff-*.whl' -File)) {
        Run-Logged $pp @(
            '-m', 'delvewheel', 'repair', '-w', $WheelsDir,
            '--add-path', "$(Join-Path $LIW_PREFIX 'bin');$script:VcRedist",
            '--analyze-existing-exes', '--include', 'tiff.dll;vcruntime140.dll',
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
        '--include', 'openjp2.dll;tiff.dll;vcruntime140.dll',
        '--no-mangle', 'vcruntime140.dll',
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

# --------------------------------------------------------------------------
# Main.
# --------------------------------------------------------------------------

function Main {
    Log "=== build_wheels.ps1 started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Log "mode: $(if ($script:DevMode) { 'dev (' + $RepoDir + ')' } else { 'build sandbox' })"
    Log "parameters from: $($script:ArgsSource)"
    Log "pythons: $($script:Pythons -join ' ')"
    Log "packages: $($script:Packages -join ' ')"

    # Pythons first: V() runs getver.py with the patch python, and the
    # toolchain pins come from versions.txt.
    Ensure-Pythons
    Ensure-Toolchain
    Set-BuildPath
    Enter-Msvc

    if ($script:Command -eq 'cache') {
        Log '=== cache warm-up complete (toolchain and pythons installed)'
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
# running.  The short delay lets the last log writes flush.  Dev mode
# (a checkout, not a disposable sandbox) is left alone.
if (-not $script:DevMode) {
    & shutdown.exe /s /t 5
}
exit $exitCode
