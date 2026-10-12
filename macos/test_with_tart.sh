#!/usr/bin/env bash
# test_with_tart.sh - run on the HOST (outside the tart VM) to verify that
# the macOS arm64 wheels were built with proper isolation.
#
# This creates a fresh tart VM by cloning the base VM, copies the macosx
# wheels into it, and runs an in-VM test that:
#
#   1. installs the wheels into a fresh venv for each requested python
#      (verifying that pip picks OUR wheel, not one from pypi),
#   2. hides /opt/homebrew entirely, then verifies that the wheels still
#      work -- so nothing in them can depend on Homebrew libraries,
#   3. audits every Mach-O file in the installed packages with otool,
#      rejecting any reference to /opt/homebrew, /usr/local, /Users, or
#      other absolute paths outside /usr/lib and /System, and rejecting
#      forbidden RPATH entries,
#   4. functionally exercises the wheels (load the bundled libtiff dylib,
#      write and read a tiff image, run the bundled tiffinfo executable).
#
# A test report is written to ./macos_test_report.txt and printed.  On
# failure the VM is left in place for debugging.
#
# Usage:
#   macos/test_with_tart.sh [options]
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

set -u

LIW_TART_USER="${LIW_TART_USER:-admin}"
LIW_TART_PASS="${LIW_TART_PASS:-admin}"
LIW_GUEST_HOME="/Users/$LIW_TART_USER"
LIW_LOG_DIR="${LIW_TART_LOG_DIR:-$HOME/.large_image_wheels_tart/logs}"
LIW_SSH_DIR="${LIW_TART_SSH_DIR:-$HOME/.large_image_wheels_tart/ssh}"

LIW_TART_BASE="${LIW_TART_BASE:-agent_base}"
LIW_VM_NAME="liw_wheels_test"
LIW_WHEELS_DIR=""
LIW_PYTHONS="${LIW_PYTHONS:-3.11 3.12 3.13 3.14 3.15 3.14t 3.15t}"
LIW_HIDE_HOMEBREW=1
LIW_KEEP=0
LIW_CPUS="${LIW_CPUS:-4}"
LIW_MEM_MB="${LIW_MEM_MB:-8192}"

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

stop_vm() {
    vm_exists "$VM_NAME" || return 0
    info "stopping $VM_NAME"
    tart stop --timeout 60 "$VM_NAME" >/dev/null 2>&1 || true
    if vm_running "$VM_NAME"; then
        pkill -f "tart run.* $VM_NAME\$" >/dev/null 2>&1 || true
        sleep 2
    fi
}

delete_vm() {
    stop_vm
    vm_exists "$VM_NAME" || return 0
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
    # Wheel tags: stable is "cp313-cp313"; free-threaded is "cp314-cp314t"
    # (the interpreter tag keeps cp314, the ABI tag gets the t suffix).
    local req="$1" tag whl
    tag="cp${req//./}"
    case "$req" in
    *t) whl="$(ls "$WHEELDIR" | grep -E "-${tag}-.*macosx" | head -1)" ;;
    *) whl="$(ls "$WHEELDIR" | grep -E "-${tag}-${tag}-.*macosx" | head -1)" ;;
    esac
    [ -n "$whl" ] && printf '%s' "$WHEELDIR/$whl"
    return 0
}

wheel_version() { # version embedded in the wheel file name
    basename "$1" | sed -E 's/^pylibtiff-([0-9.]+)-.*/\1/'
}

find_version_dir() {
    local req="$1" dir=""
    case "$req" in
    *t)
        dir="$PYENV_ROOT/versions/$req"
        [ -d "$dir" ] || dir=""
        ;;
    *)
        dir="$(ls -d "$PYENV_ROOT/versions/$req".* 2>/dev/null | sort -V | tail -1)"
        ;;
    esac
    [ -n "$dir" ] && printf '%s' "$dir"
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

for venv in $VENVDIRS; do
    req="$(basename "$venv" | sed 's/^venv-//')"
    log ""
    log "python $req:"
    site="$("$venv/bin/python" -c 'import site; print(site.getsitepackages()[0])')"
    if ! audit_macho "$site" >>"$REPORT" 2>&1; then
        log "FAIL python $req: otool audit found forbidden library references"
        FAILURES=$((FAILURES + 1))
    else
        log "OK python $req: otool audit clean"
    fi
    if "$venv/bin/python" "$TESTROOT/test_libtiff.py" >>"$REPORT" 2>&1; then
        log "OK python $req: python functional test passed"
    else
        log "FAIL python $req: python functional test failed"
        FAILURES=$((FAILURES + 1))
    fi
    if "$venv/bin/tiffinfo" /tmp/liw_test_image.tif >>"$REPORT" 2>&1; then
        log "OK python $req: bundled tiffinfo ran"
    else
        log "FAIL python $req: bundled tiffinfo failed"
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

vm_exists "$LIW_TART_BASE" || die "base VM $LIW_TART_BASE does not exist; pass --base NAME"

if vm_running "$LIW_TART_BASE"; then
    info "base VM $LIW_TART_BASE is running; stopping it so it can be cloned"
    tart stop --timeout 60 "$LIW_TART_BASE" >/dev/null 2>&1 || true
fi
vm_exists "$VM_NAME" && delete_vm

info "cloning $LIW_TART_BASE into $VM_NAME"
tart clone "$LIW_TART_BASE" "$VM_NAME" || die "cloning failed"
tart set "$VM_NAME" --cpu "$LIW_CPUS" --memory "$LIW_MEM_MB" || die "tart set failed"

info "starting $VM_NAME (log $LIW_LOG_DIR/$VM_NAME.log)"
nohup tart run --no-graphics "$VM_NAME" >>"$LIW_LOG_DIR/$VM_NAME.log" 2>&1 &
vm_ip "$VM_NAME" 600 >/dev/null || die "$VM_NAME did not acquire an IP"
wait_ssh_ready || die "$VM_NAME did not become reachable over ssh"

if ! run_ssh true 2>/dev/null; then
    info "bootstrapping the ssh key into $VM_NAME"
    if command -v sshpass >/dev/null 2>&1; then
        sshpass -p "$LIW_TART_PASS" ssh-copy-id \
            -i "$LIW_SSH_KEY.pub" $(ssh_opts | sed 's/ -o BatchMode=yes//') \
            "$LIW_TART_USER@$(vm_ip "$VM_NAME")" || die "could not install the ssh key"
    else
        die "ssh key not accepted and sshpass is not installed"
    fi
fi
run_ssh true || die "ssh into $VM_NAME still fails after the key bootstrap"

info "copying wheels and the test script into the VM"
run_ssh "mkdir -p ~/$VM_NAME-wheels"
tar -C "$LIW_WHEELS_DIR" -cf - $WHEEL_LIST |
    run_ssh "tar -xf - -C ~/$VM_NAME-wheels/" || die "could not copy wheels into the VM"
run_scp "$IN_VM_TEST" ".liw_wheel_test.sh" || die "could not copy the test script"

info "running the isolation test in the VM"
run_ssh "rm -rf $LIW_GUEST_HOME/liw_test" || true
run_ssh "chmod +x ~/.liw_wheel_test.sh && nohup bash ~/.liw_wheel_test.sh ~/$VM_NAME-wheels '$LIW_PYTHONS' '$LIW_HIDE_HOMEBREW' > $LIW_GUEST_HOME/liw_test.log 2>&1 < /dev/null &"

elapsed=0
while true; do
    sleep 15
    elapsed=$((elapsed + 15))
    code="$(run_ssh "cat $LIW_GUEST_HOME/liw_test/failures 2>/dev/null" 2>/dev/null || true)"
    if [ -n "$code" ]; then
        break
    fi
    if ! vm_running "$VM_NAME"; then
        die "test VM died; check $LIW_LOG_DIR/$VM_NAME.log"
    fi
    if [ "$elapsed" -ge 3600 ]; then
        die "test timed out after 1 hour"
    fi
    info "still testing (${elapsed}s elapsed)"
done

info "retrieving the test report"
run_ssh "cat $LIW_GUEST_HOME/liw_test/report.txt" >"$REPO_DIR/macos_test_report.txt" 2>/dev/null ||
    die "could not retrieve the report"
cat "$REPO_DIR/macos_test_report.txt"

if [ "$code" != "0" ]; then
    echo "error: $code check(s) failed (VM $VM_NAME kept for debugging)" >&2
    exit 1
fi

if [ "$LIW_KEEP" = 1 ]; then
    info "keeping $VM_NAME (--keep)"
else
    delete_vm
fi
info "isolation test passed"
