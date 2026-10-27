# dev_setup.ps1 - set up a development environment for the windows wheel
# pipeline in a checkout that is not the build sandbox (the agent sandbox,
# or any Windows machine without administrator rights).
#
# The agent sandbox is disposable, so after a reset this one command gets
# back to a working state: it runs build_wheels.ps1 in its dev mode with
# -WarmCache, which installs the same pinned toolchain the build sandbox
# uses (PortableGit, cmake, ninja, nasm, MSVC + Windows SDK via
# install_msvc.py, the NuGet pythons) under C:\liw_build, with the
# downloads cached in C:\liw_build\cache; then it installs the few extras
# development needs that the build itself does not (requests and packaging
# for check_versions.py).
#
# Usage:
#   powershell -File windows\dev_setup.ps1 [-Pythons 3.13,3.14t]
#
# Afterwards, builds run with for example:
#   powershell -File windows\build_wheels.ps1 -Packages pylibtiff -Pythons 3.13
#
# Nothing here is needed for the build sandbox, where build_wheels.ps1 does
# the toolchain setup itself on every run.

param(
    [string[]]$Pythons = @('3.11', '3.12', '3.13', '3.14', '3.15', '3.14t', '3.15t')
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

if (Test-Path 'C:\mnt\repo\windows\build_wheels.ps1') {
    throw 'dev_setup.ps1: this is the build sandbox; build_wheels.ps1 sets up its own toolchain there'
}

# check_versions.py dependencies, into whatever python the checkout's
# shell uses (the agent sandbox's C:\tools python; --user keeps it out of
# the tools tree, which is not writable there).
$py = Get-Command python -ErrorAction SilentlyContinue
if ($py) {
    Write-Host "dev_setup: installing requests and packaging for check_versions.py into $($py.Source)"
    & $py.Source -m pip install --quiet --user requests packaging
    if ($LASTEXITCODE -ne 0) { throw 'dev_setup: pip install of requests/packaging failed' }
} else {
    Write-Host 'dev_setup: no python on PATH; check_versions.py will need requests and packaging'
}

Write-Host 'dev_setup: installing the pinned toolchain and pythons under C:\liw_build (build_wheels.ps1 -WarmCache)'
& (Join-Path $here 'build_wheels.ps1') -WarmCache -Pythons $Pythons
if ($LASTEXITCODE -ne 0) {
    throw "dev_setup: build_wheels.ps1 -WarmCache failed (exit code $LASTEXITCODE); see C:\liw_build\run\build.log"
}
Write-Host 'dev_setup: done; build with: powershell -File windows\build_wheels.ps1 -Packages <pkg> -Pythons <ver>'
