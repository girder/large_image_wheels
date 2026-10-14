#!/usr/bin/env bash
# test_via_tart.sh - run on the HOST (outside the tart VM) to verify that
# the macOS arm64 wheels were built with proper isolation.
#
# This creates a fresh tart VM by cloning the base VM, copies the macosx
# wheels into it, and runs an in-VM test that:
#
#   1. installs the wheels into a fresh venv for each requested python
#      (verifying that pip picks OUR wheel, not one from pypi),
#   2. hides /opt/homebrew entirely, then verifies that the wheels still
#      work -- so nothing in them can depend on Homebrew libraries,
#   3. audits every Mach-O file in the packages our wheels provide with
#      otool, rejecting any reference to /opt/homebrew, /usr/local, /Users,
#      or other absolute paths outside /usr/lib and /System, and rejecting
#      forbidden RPATH entries,
#   4. functionally exercises the wheels by running the shared
#      test/test_script.sh (the same functional suite the linux containers
#      run), plus macos-specific checks: the bundled dylib is the one
#      actually loaded, and the bundled tiffinfo executable runs.
#
# A test report is written to /tmp/macos_test_report.txt and printed.  On
# failure the VM is left in place for debugging.
#
# Usage:
#   macos/test_via_tart.sh [options]
#
# Options:
#   --base NAME     base tart VM to clone (default: $LIW_TART_BASE, else
#                   agent_base)
#   --name NAME     name for the test VM (default: liw_wheels_test)
#   --wheels DIR    directory with the macosx wheels (default: ./wheels)
#   --pythons LIST  python versions to test (default: 3.11-3.15, 3.14t,
#                   3.15t)
#   --keep-homebrew do not hide Homebrew during the functional tests
#   --keep          do not delete the VM afterwards
#   -h | --help     show this help
#
# Environment: LIW_TEST_TIMEOUT overrides the in-VM test timeout in seconds
# (default 14400).

set -u
set -o pipefail

LIW_TART_USER="${LIW_TART_USER:-admin}"
LIW_TART_PASS="${LIW_TART_PASS:-admin}"
LIW_GUEST_HOME="/Users/$LIW_TART_USER"
LIW_LOG_DIR="${LIW_TART_LOG_DIR:-$HOME/.large_image_wheels_tart/logs}"
LIW_SSH_DIR="${LIW_TART_SSH_DIR:-$HOME/.large_image_wheels_tart/ssh}"

LIW_TART_BASE="${LIW_TART_BASE:-liw_wheels_base}"
LIW_VM_NAME="liw_wheels_test"
LIW_WHEELS_DIR=""
LIW_PYTHONS="${LIW_PYTHONS:-3.11 3.12 3.13 3.14 3.15 3.14t 3.15t}"
LIW_HIDE_HOMEBREW=1
LIW_KEEP=0
LIW_CPUS="${LIW_CPUS:-4}"
LIW_MEM_MB="${LIW_MEM_MB:-8192}"
LIW_TEST_TIMEOUT="${LIW_TEST_TIMEOUT:-14400}"

usage() {
    sed -n '2,41p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

die() {
    echo "error: $*" >&2
    exit 1
}

info() {
    echo ">>> $*" >&2
}

while [ $# -gt 0 ]; do
    case "$1" in
    --base) LIW_TART_BASE="$2"; shift 2 ;;
    --name) LIW_VM_NAME="$2"; shift 2 ;;
    --wheels) LIW_WHEELS_DIR="$2"; shift 2 ;;
    --pythons) LIW_PYTHONS="$2"; shift 2 ;;
    --keep-homebrew) LIW_HIDE_HOMEBREW=0; shift ;;
    --keep) LIW_KEEP=1; shift ;;
    -h | --help) usage ;;
    *) die "unknown argument: $1" ;;
    esac
done

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "$LIW_WHEELS_DIR" ] || LIW_WHEELS_DIR="$REPO_DIR/wheels"
# All of the helpers and main flow below use VM_NAME.
VM_NAME="$LIW_VM_NAME"

# Collect the macosx wheels to test.
WHEEL_LIST="$(cd "$LIW_WHEELS_DIR" && ls *macosx*.whl 2>/dev/null || true)"
[ -n "$WHEEL_LIST" ] || die "no macosx wheels found in $LIW_WHEELS_DIR; run macos/tart_build.sh first"

command -v tart >/dev/null 2>&1 || die "tart not found on the host"
command -v ssh >/dev/null 2>&1 || die "ssh not found on the host"
mkdir -p "$LIW_LOG_DIR" "$LIW_SSH_DIR"

# --- ssh handling (same conventions as tart_build.sh) -----------------------
LIW_SSH_KEY=""
for candidate in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_ecdsa.pub" \
    "$HOME/.ssh/id_rsa.pub"; do
    if [ -f "$candidate" ]; then
        LIW_SSH_KEY="${candidate%.pub}"
        break
    fi
done
if [ -z "$LIW_SSH_KEY" ]; then
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -q
    LIW_SSH_KEY="$HOME/.ssh/id_ed25519"
fi

ssh_opts() {
    printf '%s' "-i $LIW_SSH_KEY -o UserKnownHostsFile=$LIW_SSH_DIR/known_hosts -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
}

vm_exists() {
    tart list --quiet 2>/dev/null | grep -Fxq "$1"
}

# `tart list` can fail transiently (for instance while another tart
# command is still cleaning up), so retry before concluding that a VM
# does not exist.
vm_exists_retry() {
    local vm="$1" n=0
    until vm_exists "$vm"; do
        n=$((n + 1))
        [ "$n" -ge 5 ] && return 1
        sleep 2
    done
    return 0
}

vm_running() {
    if command -v jq >/dev/null 2>&1; then
        if tart list --json 2>/dev/null |
            jq -e --arg n "$1" '.[] | select(.Name == $n and .Running)' >/dev/null 2>&1; then
            return 0
        fi
    fi
    tart ip "$1" >/dev/null 2>&1
}

vm_ip() {
    tart ip "$1" --wait "${2:-120}" 2>/dev/null
}

wait_ssh_ready() {
    local waited=0 ip
    while [ "$waited" -lt 300 ]; do
        if ip="$(vm_ip "$VM_NAME")" && [ -n "$ip" ]; then
            if (exec 3<>"/dev/tcp/$ip/22") 2>/dev/null; then
                return 0
            fi
        fi
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}

run_ssh() {
    local ip
    ip="$(vm_ip "$VM_NAME" 10)" || die "no IP for VM $VM_NAME (is it running?)"
    # shellcheck disable=SC2086
    ssh $(ssh_opts) "$LIW_TART_USER@$ip" "$@"
}

stop_vm() { # stop_vm [name]  (default: $VM_NAME)
    local vm="${1:-$VM_NAME}" waited=0
    vm_exists_retry "$vm" || return 0
    info "stopping $vm"
    tart stop --timeout 60 "$vm" >/dev/null 2>&1 || true
    if vm_running "$vm"; then
        pkill -f "tart run.* $vm\$" >/dev/null 2>&1 || true
        sleep 2
    fi
    # Verify the VM actually stopped; a guest that ignores ACPI for the
    # full stop timeout can leave the process lingering, which then holds
    # memory and blocks the next VM from starting.
    while vm_running "$vm" && [ "$waited" -lt 20 ]; do
        sleep 2
        waited=$((waited + 2))
        pkill -f "tart run.* $vm\$" >/dev/null 2>&1 || true
    done
    if vm_running "$vm"; then
        echo "warning: $vm is still running after stop; it may hold memory" >&2
    fi
}

# Leftovers from interrupted runs hold memory that the next VM may need;
# tart refuses to start a VM once the system limit is reached.  Stop our
# own leftover wheel VMs (never the agent_* VMs) before starting one.
stop_leftover_vms() {
    local vm
    while IFS= read -r vm; do
        [ -n "$vm" ] || continue
        [ "$vm" = "$VM_NAME" ] && continue
        if vm_running "$vm"; then
            info "stopping leftover VM $vm (from an earlier interrupted run)"
            stop_vm "$vm"
        fi
    done < <(tart list --quiet 2>/dev/null | grep '^liw_wheels_')
}

# The in-VM test output is streamed with a background `tail -F`; stop that
# stream on every exit path so no ssh process outlives the run.
LIW_STREAM_PID=""
stop_stream() {
    [ -n "$LIW_STREAM_PID" ] || return 0
    kill "$LIW_STREAM_PID" 2>/dev/null || true
    wait "$LIW_STREAM_PID" 2>/dev/null || true
    LIW_STREAM_PID=""
}

# Interrupted runs (Ctrl-C) must not leave their VM running.
trap 'stop_stream; stop_vm; exit 130' INT TERM

delete_vm() {
    stop_vm
    vm_exists_retry "$VM_NAME" || return 0
    info "deleting $VM_NAME"
    tart delete "$VM_NAME" 2>/dev/null || {
        pkill -f "tart run.* $VM_NAME\$" >/dev/null 2>&1 || true
        sleep 2
        tart delete "$VM_NAME" || die "could not delete $VM_NAME"
    }
}

# --- the in-VM test script --------------------------------------------------
# Written into the test VM and run there.

IN_VM_TEST="$LIW_SSH_DIR/wheel_test.sh"
cat >"$IN_VM_TEST" <<'IN_VM_EOF'
#!/usr/bin/env bash
# wheel_test.sh - runs INSIDE the test VM: install the wheels on a clean
# system, hide Homebrew, and verify isolation and function.
set -u
set -o pipefail

WHEELDIR="$1"
PYTHONS="${2:-3.11 3.12 3.13 3.14 3.15 3.14t 3.15t}"
HIDE_HOMEBREW="${3:-1}"
LIW_TART_PASS="${LIW_TART_PASS:-admin}"
PYENV_ROOT="$HOME/.pyenv"
TESTROOT="$HOME/liw_test"
REPORT="$TESTROOT/report.txt"
FAILURES=0

mkdir -p "$TESTROOT"
: >"$REPORT"

log() { echo "$*" | tee -a "$REPORT"; }

wheel_for_python() { # wheel_for_python <version req> -> wheel file or empty
    # The venv's primary install is pylibtiff; anchor the search to it so
    # other packages' wheels that happen to match the interpreter tag
    # (e.g. openslide_python's abi3/free-threaded wheels sorting first)
    # cannot be picked instead.  The other packages are verified separately
    # by name below.
    local req="$1" tag whl
    tag="cp${req//./}"
    case "$req" in
    *t) whl="$(ls "$WHEELDIR" | grep -E -e "^pylibtiff-.*-${tag}-.*macosx" | head -1)" ;;
    *) whl="$(ls "$WHEELDIR" | grep -E -e "^pylibtiff-.*-${tag}-${tag}-.*macosx" | head -1)" ;;
    esac
    [ -n "$whl" ] && printf '%s' "$WHEELDIR/$whl"
    return 0
}

wheel_version() { # version embedded in the wheel file name
    basename "$1" | sed -E 's/^(pylibtiff|Glymur|openslide_python)-([0-9.]+)-.*/\2/'
}

find_version_dir() {
    local req="$1" dir=""
    case "$req" in
    *t)
        dir="$PYENV_ROOT/versions/$req"
        [ -d "$dir" ] ||
            dir="$(ls -d "$PYENV_ROOT/versions/${req%t}".*t 2>/dev/null | sort -V | tail -1)"
        ;;
    *)
        dir="$(ls -d "$PYENV_ROOT/versions/$req".* 2>/dev/null | grep -v 't$' | sort -V | tail -1)"
        ;;
    esac
    [ -n "$dir" ] && printf '%s' "$dir"
    return 0
}

# Return 0 if the python interpreter in $1 carries Homebrew (or
# /usr/local) library dependencies, which the base VM's pyenv pythons do.
python_links_homebrew() {
    local dir="$1" bin
    for bin in "$dir"/bin/python3*; do
        [ -f "$bin" ] || continue
        if otool -L "$bin" 2>/dev/null |
            grep -qE "/opt/homebrew/|/usr/local/lib"; then
            return 0
        fi
    done
    return 1
}

# Locate the Homebrew prefix to hide (only if it is actually Homebrew).
find_homebrew() {
    for d in /opt/homebrew /usr/local; do
        if [ -x "$d/bin/brew" ]; then
            printf '%s' "$d"
            return 0
        fi
    done
    printf '%s' ""
}

HOMEBREW_DIR="$(find_homebrew)"
trap restore_homebrew EXIT

hide_homebrew() {
    [ -n "$HOMEBREW_DIR" ] || return 0
    log "hiding $HOMEBREW_DIR for the isolation checks"
    if sudo -n mv "$HOMEBREW_DIR" "$HOMEBREW_DIR.hidden" 2>/dev/null; then
        return 0
    fi
    if printf '%s\n' "$LIW_TART_PASS" | sudo -S -p '' \
        mv "$HOMEBREW_DIR" "$HOMEBREW_DIR.hidden" 2>/dev/null; then
        return 0
    fi
    log "WARNING: could not hide $HOMEBREW_DIR (no passwordless sudo); isolation is only verified by the otool audit"
    HOMEBREW_DIR=""
}

restore_homebrew() {
    [ -n "$HOMEBREW_DIR" ] || return 0
    if sudo -n mv "$HOMEBREW_DIR.hidden" "$HOMEBREW_DIR" 2>/dev/null; then
        return 0
    fi
    printf '%s\n' "$LIW_TART_PASS" | sudo -S -p '' \
        mv "$HOMEBREW_DIR.hidden" "$HOMEBREW_DIR" 2>/dev/null || true
}

# Report every Mach-O file under $1 whose dependencies or RPATHs point
# outside the allowed system locations.
audit_macho() {
    local root="$1" bad=0 f dep rp
    while IFS= read -r -d '' f; do
        file "$f" 2>/dev/null | grep -q Mach-O || continue
        while IFS= read -r dep; do
            case "$dep" in
            @loader_path/* | @rpath/* | @executable_path/*) ;;
            /usr/lib/* | /System/*) ;;
            # /DLC/... is delocate's install-id marker for copied dylibs;
            # it is never used to resolve a load.
            /DLC/*) ;;
            *)
                log "  FORBIDDEN dependency: $f -> $dep"
                bad=1
                ;;
            esac
        done < <(otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}')
        while IFS= read -r rp; do
            case "$rp" in
            @loader_path/* | @executable_path/*) ;;
            /opt/homebrew/* | /usr/local/* | /Users/*)
                log "  FORBIDDEN RPATH: $f -> $rp"
                bad=1
                ;;
            esac
        done < <(otool -l "$f" 2>/dev/null |
            awk '/LC_RPATH/{inr=1; next} inr && $1=="path" {print $2; inr=0}')
    done < <(find "$root" -type f -print0)
    return $bad
}

log "=== wheel isolation test ==="
log "wheels: $WHEELDIR"
log "pythons: $PYTHONS"
log "wheels present:"
ls "$WHEELDIR" 2>&1 | sed 's/^/  /' | while IFS= read -r line; do log "$line"; done

# The build VM installs any requested pythons it is missing; do the same
# here so that every requested python gets tested.
log ""
log "=== phase 0: check pythons ==="
# The base VM's pyenv pythons link Homebrew libraries (libintl for
# 3.11-3.13; other libraries for the newer ones), so with Homebrew hidden
# the interpreters themselves could not be trusted.  Those pythons are
# rebuilt here with a scrubbed environment so that the test measures the
# wheels, not the interpreter's dependencies.  The builds are independent
# and each is a single-threaded make taking several minutes, so run up to
# CONCURRENCY of them at a time (bash 3.2 has no `wait -n`, so throttle by
# counting background jobs).
CONCURRENCY="${4:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
case "$CONCURRENCY" in '' | *[!0-9]*) CONCURRENCY=4 ;; esac
[ "$CONCURRENCY" -ge 1 ] || CONCURRENCY=1
build_status="$TESTROOT/pybuild_status"
: >"$build_status"
for req in $PYTHONS; do
    dir="$(find_version_dir "$req")"
    if [ -z "$dir" ]; then
        mode="installing"
        flag="-s"
    elif python_links_homebrew "$dir"; then
        mode="rebuilding"
        flag="-f"
    else
        continue
    fi
    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$CONCURRENCY" ]; do
        sleep 5
    done
    log "python $req: $mode (build log pybuild-$req.log; up to $CONCURRENCY builds at a time)"
    (
        unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS SDKROOT
        "$PYENV_ROOT/bin/pyenv" install "$flag" "$req"
    ) >"$TESTROOT/pybuild-$req.log" 2>&1 &&
        echo "$req ok" >>"$build_status" ||
        echo "$req failed" >>"$build_status" &
done
wait
while IFS= read -r line; do
    case "$line" in
    *" failed")
        breq="${line% failed}"
        log "FAIL: pyenv build failed for $breq; last lines of the build log:"
        tail -40 "$TESTROOT/pybuild-$breq.log" >>"$REPORT" 2>&1
        FAILURES=$((FAILURES + 1))
        ;;
    esac
done <"$build_status"

# --- phase 1: create venvs and install (Homebrew still present; pip needs
# its ssl libraries, which live in Homebrew in the base VM) ---
log ""
log "=== phase 1: install wheels ==="
VENVDIRS=""
for req in $PYTHONS; do
    whl="$(wheel_for_python "$req")"
    dir="$(find_version_dir "$req")"
    if [ -z "$dir" ]; then
        log "SKIP python $req: not installed"
        continue
    fi
    if [ -z "$whl" ]; then
        log "FAIL python $req: no matching wheel in $WHEELDIR"
        FAILURES=$((FAILURES + 1))
        continue
    fi
    ver="$(wheel_version "$whl")"
    venv="$TESTROOT/venv-$req"
    log "python $req: wheel $(basename "$whl")"
    if ! "$dir/bin/python" -m venv "$venv" 2>>"$REPORT"; then
        log "FAIL python $req: venv creation failed"
        FAILURES=$((FAILURES + 1))
        continue
    fi
    if ! "$venv/bin/pip" install --quiet --find-links "$WHEELDIR" \
        "pylibtiff==$ver" >>"$REPORT" 2>&1; then
        log "FAIL python $req: pip install failed"
        FAILURES=$((FAILURES + 1))
        rm -rf "$venv"
        continue
    fi
    installed="$("$venv/bin/pip" show pylibtiff 2>/dev/null | sed -n 's/^Version: //p')"
    if [ "$installed" != "$ver" ]; then
        log "FAIL python $req: installed pylibtiff $installed but expected $ver (pip may have used pypi)"
        FAILURES=$((FAILURES + 1))
        rm -rf "$venv"
        continue
    fi
    log "OK python $req: installed pylibtiff $installed"
    # If a Glymur wheel is present, verify its identity the same way.
    gwhl="$(ls "$WHEELDIR"/Glymur-*.whl 2>/dev/null | head -1)"
    if [ -n "$gwhl" ]; then
        gver="$(wheel_version "$gwhl")"
        if ! "$venv/bin/pip" install --quiet --find-links "$WHEELDIR" \
            "Glymur==$gver" >>"$REPORT" 2>&1; then
            log "FAIL python $req: pip install of Glymur failed"
            FAILURES=$((FAILURES + 1))
            rm -rf "$venv"
            continue
        fi
        ginstalled="$($venv/bin/pip show Glymur 2>/dev/null | sed -n 's/^Version: //p')"
        if [ "$ginstalled" != "$gver" ]; then
            log "FAIL python $req: installed Glymur $ginstalled but expected $gver (pip may have used pypi)"
            FAILURES=$((FAILURES + 1))
            rm -rf "$venv"
            continue
        fi
        log "OK python $req: installed Glymur $ginstalled"
    fi
    # If an openslide_python wheel is present, verify its identity the same
    # way.  The abi3 wheel built from python 3.11 covers every stable
    # python; the free-threaded pythons get their own wheels.
    owhl="$(ls "$WHEELDIR"/openslide_python-*.whl 2>/dev/null | head -1)"
    if [ -n "$owhl" ]; then
        over="$(wheel_version "$owhl")"
        if ! "$venv/bin/pip" install --quiet --find-links "$WHEELDIR" \
            "openslide-python==$over" >>"$REPORT" 2>&1; then
            log "FAIL python $req: pip install of openslide-python failed"
            FAILURES=$((FAILURES + 1))
            rm -rf "$venv"
            continue
        fi
        oinstalled="$($venv/bin/pip show openslide-python 2>/dev/null | sed -n 's/^Version: //p')"
        if [ "$oinstalled" != "$over" ]; then
            log "FAIL python $req: installed openslide-python $oinstalled but expected $over (pip may have used pypi)"
            FAILURES=$((FAILURES + 1))
            rm -rf "$venv"
            continue
        fi
        log "OK python $req: installed openslide-python $oinstalled"
    fi
    VENVDIRS="$VENVDIRS $venv"
done

# --- phase 2: hide Homebrew so nothing can resolve through it ---
if [ "$HIDE_HOMEBREW" = 1 ]; then
    hide_homebrew
fi

# --- phase 3: functional and isolation checks without Homebrew ---
log ""
log "=== phase 2: functional tests (Homebrew hidden) ==="

cat >"$TESTROOT/test_libtiff.py" <<'PYEOF'
import os
import sys

import numpy as np

import libtiff
import libtiff.libtiff_ctypes as lc

loaded = getattr(lc, "libtiff", None)
if loaded is None:
    sys.exit("no libtiff handle; the bundled dylib was not loaded")
name = getattr(loaded, "_name", "")
print("libtiff dylib loaded from:", name)
if ".dylibs/" not in name:
    sys.exit("libtiff dylib was not loaded from the bundled .dylibs directory")

from libtiff import TIFF

path = "/tmp/liw_test_image.tif"
data = (np.arange(256, dtype=np.uint8) % 251).reshape(16, 16)
tif = TIFF.open(path, "w")
tif.write_image(data)
tif.close()
tif = TIFF.open(path, "r")
img = tif.read_image()
tif.close()
assert img.shape == (16, 16), img.shape
assert (img == data).all(), "round trip image differs"
print("tiff round trip OK")
PYEOF

cat >"$TESTROOT/test_openslide.py" <<'PYEOF'
import os
import sys

import openslide
import openslide.lowlevel as ll

loaded = getattr(ll, "_lib", None)
name = getattr(loaded, "_name", "") if loaded is not None else ""
print("openslide dylib loaded from:", name)
if ".dylibs/" not in name:
    # A pypi openslide-bin wheel (installed by large-image[openslide]) or
    # a system copy winning the load means our bundled library was
    # bypassed; its libopenslide is unpatched upstream.
    sys.exit("libopenslide was not loaded from the bundled .dylibs directory")

path = os.environ.get("LIW_OPENSLIDE_TEST_FILE")
if path and os.path.exists(path):
    slide = openslide.OpenSlide(path)
    print("vendor:", slide.properties[openslide.PROPERTY_NAME_VENDOR])
    region = slide.read_region((0, 0), 0, (64, 64))
    assert region.size == (64, 64), region.size
    slide.close()
    print("openslide read OK")
PYEOF

for venv in $VENVDIRS; do
    req="$(basename "$venv" | sed 's/^venv-//')"
    log ""
    log "python $req:"
    site="$($venv/bin/python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])' 2>/dev/null)"
    if [ -z "$site" ] || [ ! -d "$site" ]; then
        log "FAIL python $req: could not determine site-packages (interpreter failed to start?)"
        FAILURES=$((FAILURES + 1))
        continue
    fi
    # Audit only the packages our wheels provide.  The venvs also contain
    # pypi wheels pulled in as dependencies (numpy, lxml, pillow), whose
    # own build artifacts (e.g. Pillow's RPATH to its build machine, lxml's
    # self-referencing load commands) are not ours to police.
    audit_fail=0
    for pkg in libtiff glymur openslide; do
        if [ -d "$site/$pkg" ]; then
            audit_macho "$site/$pkg" >>"$REPORT" 2>&1 || audit_fail=1
        fi
    done
    if [ "$audit_fail" != 0 ]; then
        log "FAIL python $req: otool audit found forbidden library references"
        FAILURES=$((FAILURES + 1))
    else
        log "OK python $req: otool audit clean (libtiff, glymur, openslide)"
    fi
    if "$venv/bin/python" "$TESTROOT/test_libtiff.py" >>"$REPORT" 2>&1; then
        log "OK python $req: python functional test passed"
    else
        log "FAIL python $req: python functional test failed"
        FAILURES=$((FAILURES + 1))
    fi
    if LIW_OPENSLIDE_TEST_FILE="$rundir/sample.svs" \
        "$venv/bin/python" "$TESTROOT/test_openslide.py" >>"$REPORT" 2>&1; then
        log "OK python $req: openslide bundled-dylib check passed"
    else
        log "FAIL python $req: openslide bundled-dylib check failed"
        FAILURES=$((FAILURES + 1))
    fi
    if "$venv/bin/tiffinfo" /tmp/liw_test_image.tif >>"$REPORT" 2>&1; then
        log "OK python $req: bundled tiffinfo ran"
    else
        log "FAIL python $req: bundled tiffinfo failed"
        FAILURES=$((FAILURES + 1))
    fi
    # Run the shared functional test suite: the same test/test_script.sh the
    # linux containers run, with the wheelhouse as the wheel source and
    # LIW_PYTHON_BIN_DIR pinning the interpreter under test.  Sample file
    # downloads are cached so later pythons do not re-download them.  The
    # venv the script creates is audited with otool as well.
    rundir="$TESTROOT/run-$req"
    rm -rf "$rundir"
    mkdir -p "$rundir"
    pydir="$(find_version_dir "$req")"
    if (
        cd "$rundir" || exit 1
        LIW_TEST_CACHE="$TESTROOT/downloads"
        export LIW_TEST_CACHE
        mkdir -p "$LIW_TEST_CACHE"
        if [ -n "$pydir" ]; then
            export LIW_PYTHON_BIN_DIR="$pydir/bin"
        fi
        bash "$TESTROOT/test_script.sh" "$WHEELDIR"
    ) >>"$REPORT" 2>&1; then
        log "OK python $req: shared test_script.sh passed"
        venvsite="$(ls -d "$rundir/venv/lib/python3."*/site-packages 2>/dev/null | head -1)"
        audit_fail=0
        for pkg in libtiff glymur openslide; do
            if [ -n "$venvsite" ] && [ -d "$venvsite/$pkg" ]; then
                audit_macho "$venvsite/$pkg" >>"$REPORT" 2>&1 || audit_fail=1
            fi
        done
        if [ "$audit_fail" != 0 ]; then
            log "FAIL python $req: otool audit of the test_script.sh venv found forbidden library references"
            FAILURES=$((FAILURES + 1))
        else
            log "OK python $req: otool audit of the test_script.sh venv clean (libtiff, glymur, openslide)"
        fi
        # The bundled openslide command line tool (slidetool, the only one
        # the linux wheels bundle too) is exposed as a console script; run
        # it against the slide file the shared test suite downloaded (if it
        # got that far).
        if [ -f "$rundir/sample.svs" ]; then
            if "$venv/bin/slidetool" slide quickhash1 "$rundir/sample.svs" >>"$REPORT" 2>&1; then
                log "OK python $req: bundled slidetool quickhash ran"
            else
                log "FAIL python $req: bundled slidetool quickhash failed"
                FAILURES=$((FAILURES + 1))
            fi
        fi
    else
        log "FAIL python $req: shared test_script.sh failed"
        FAILURES=$((FAILURES + 1))
    fi
done

rm -f /tmp/liw_test_image.tif
restore_homebrew

log ""
if [ "$FAILURES" -eq 0 ]; then
    log "=== RESULT: all checks passed ==="
else
    log "=== RESULT: $FAILURES check(s) failed ==="
fi
echo "$FAILURES" >"$TESTROOT/failures"
exit 0
IN_VM_EOF

# --- main -------------------------------------------------------------------

# The test VM needs the same provisioned base as the build VM; it never
# provisions one itself (that is tart_build.sh's job).
if ! vm_exists_retry "$LIW_TART_BASE"; then
    die "base VM $LIW_TART_BASE does not exist; provision it with: macos/tart_build.sh provision"
fi

if vm_running "$LIW_TART_BASE"; then
    info "base VM $LIW_TART_BASE is running; stopping it so it can be cloned"
    tart stop --timeout 60 "$LIW_TART_BASE" >/dev/null 2>&1 || true
fi
if vm_running "$VM_NAME"; then
    stop_vm
fi

info "cloning $LIW_TART_BASE into $VM_NAME"
# --overwrite replaces a previous test VM without relying on tart list
# bookkeeping (which can fail transiently).
tart clone --overwrite "$LIW_TART_BASE" "$VM_NAME" || die "cloning failed"
tart set "$VM_NAME" --cpu "$LIW_CPUS" --memory "$LIW_MEM_MB" || die "tart set failed"

info "starting $VM_NAME (log $LIW_LOG_DIR/$VM_NAME.log)"
nohup tart run --no-graphics "$VM_NAME" >>"$LIW_LOG_DIR/$VM_NAME.log" 2>&1 &
sleep 5
if ! pgrep -f "tart run.* $VM_NAME\$" >/dev/null 2>&1; then
    echo "--- tail of $LIW_LOG_DIR/$VM_NAME.log:" >&2
    tail -20 "$LIW_LOG_DIR/$VM_NAME.log" >&2
    die "$VM_NAME exited immediately after starting (see log above; another tart VM may be holding memory -- check 'tart list')"
fi
vm_ip "$VM_NAME" 600 >/dev/null || {
    echo "--- tail of $LIW_LOG_DIR/$VM_NAME.log:" >&2
    tail -30 "$LIW_LOG_DIR/$VM_NAME.log" >&2
    stop_vm
    die "$VM_NAME did not acquire an IP (see log above; check 'tart list' for VMs holding memory)"
}
wait_ssh_ready || { stop_vm; die "$VM_NAME did not become reachable over ssh"; }

if ! run_ssh true 2>/dev/null; then
    info "bootstrapping the ssh key into $VM_NAME"
    if command -v sshpass >/dev/null 2>&1; then
        sshpass -p "$LIW_TART_PASS" ssh-copy-id \
            -o UserKnownHostsFile="$LIW_SSH_DIR/known_hosts" \
            -o StrictHostKeyChecking=no \
            -i "$LIW_SSH_KEY.pub" \
            "$LIW_TART_USER@$(vm_ip "$VM_NAME")" || {
            stop_vm
            die "could not install the ssh key"
        }
    else
        stop_vm
        die "ssh key not accepted and sshpass is not installed"
    fi
fi
run_ssh true || die "ssh into $VM_NAME still fails after the key bootstrap"

info "copying wheels and the shared test script into the VM"
run_ssh "rm -rf $LIW_GUEST_HOME/liw_test" || true
run_ssh "mkdir -p ~/$VM_NAME-wheels $LIW_GUEST_HOME/liw_test"
tar -C "$LIW_WHEELS_DIR" -cf - $WHEEL_LIST |
    run_ssh "tar -xf - -C ~/$VM_NAME-wheels/" || die "could not copy wheels into the VM"
tar -C "$REPO_DIR/test" -cf - test_script.sh |
    run_ssh "tar -xf - -C $LIW_GUEST_HOME/liw_test/" ||
    die "could not copy the shared test script into the VM"
run_ssh "cat > $LIW_GUEST_HOME/.liw_wheel_test.sh" <"$IN_VM_TEST" ||
    die "could not copy the test script"

info "running the isolation test in the VM"
run_ssh "chmod +x ~/.liw_wheel_test.sh && nohup bash ~/.liw_wheel_test.sh ~/$VM_NAME-wheels '$LIW_PYTHONS' '$LIW_HIDE_HOMEBREW' '$LIW_CPUS' > $LIW_GUEST_HOME/liw_test.log 2>&1 < /dev/null &"

# Stream the in-VM test output continuously.  report.txt holds the full
# detail (pip installs, the shared test_script.sh output, otool audits);
# the log() progress lines tee into it as well.  -F retries until the file
# appears (the in-VM script creates it a moment after launching).  On
# completion both report.txt and liw_test.log are retrieved to /tmp.
info "streaming the in-VM test output"
run_ssh "tail -F -n +1 $LIW_GUEST_HOME/liw_test/report.txt" &
LIW_STREAM_PID=$!

elapsed=0
while true; do
    sleep 15
    elapsed=$((elapsed + 15))
    code="$(run_ssh "cat $LIW_GUEST_HOME/liw_test/failures 2>/dev/null" 2>/dev/null || true)"
    if [ -n "$code" ]; then
        break
    fi
    if ! vm_running "$VM_NAME"; then
        echo "error: test VM died; check $LIW_LOG_DIR/$VM_NAME.log" >&2
        stop_stream
        stop_vm
        exit 1
    fi
    if [ "$elapsed" -ge "$LIW_TEST_TIMEOUT" ]; then
        echo "error: test timed out after $LIW_TEST_TIMEOUT seconds" >&2
        stop_stream
        run_ssh "cat $LIW_GUEST_HOME/liw_test/report.txt" >/tmp/macos_test_report.txt 2>/dev/null || true
        run_ssh "cat $LIW_GUEST_HOME/liw_test.log" >/tmp/macos_test_log.txt 2>/dev/null || true
        stop_vm
        exit 1
    fi
    if [ $((elapsed % 60)) -eq 0 ]; then
        info "still testing (${elapsed}s elapsed)"
    fi
done
stop_stream

info "retrieving the test report and in-VM log"
run_ssh "cat $LIW_GUEST_HOME/liw_test/report.txt" >/tmp/macos_test_report.txt 2>/dev/null ||
    echo "warning: could not retrieve the test report" >&2
run_ssh "cat $LIW_GUEST_HOME/liw_test.log" >/tmp/macos_test_log.txt 2>/dev/null || true
cat /tmp/macos_test_report.txt 2>/dev/null

if [ ! -s /tmp/macos_test_report.txt ] || [ "$code" != "0" ]; then
    echo "error: the isolation test failed (see /tmp/macos_test_report.txt and" >&2
    echo "/tmp/macos_test_log.txt)" >&2
    # Release the VM's memory but keep it for debugging; inspect it with:
    #   tart run --no-graphics $VM_NAME
    #   ssh admin@$(tart ip $VM_NAME)
    stop_vm
    echo "VM $VM_NAME was stopped and kept for debugging." >&2
    exit 1
fi

if [ "$LIW_KEEP" = 1 ]; then
    info "keeping $VM_NAME (--keep)"
else
    delete_vm
fi
info "isolation test passed"
