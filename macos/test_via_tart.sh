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
#      actually loaded, and the bundled tiffinfo/gdalinfo executables run.
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
#   --cpus N        vCPUs for the test VM (default: one fewer than the
#                   host's processor count; also the phase-0 python-build
#                   concurrency)
#   --mem MB        memory for the test VM in MB (default: the larger of
#                   4096 and one third of the host's memory)
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
# Defaults sized from the host, overridable with --cpus/--mem (or the
# LIW_CPUS/LIW_MEM_MB variables): one fewer vCPU than the host has
# processors, and max(4096 MB, one third of the host's memory) for the
# guest.  The smaller guest keeps the host (which shares its memory with
# the agent sandbox) out of swap when the guest fills its own memory.
liw_host_cpus="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"
liw_host_mem_mb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 4294967296) / 1048576 ))
LIW_DEFAULT_CPUS=$(( liw_host_cpus > 1 ? liw_host_cpus - 1 : 1 ))
LIW_DEFAULT_MEM_MB=$(( liw_host_mem_mb / 3 ))
[ "$LIW_DEFAULT_MEM_MB" -ge 4096 ] || LIW_DEFAULT_MEM_MB=4096
LIW_CPUS="${LIW_CPUS:-$LIW_DEFAULT_CPUS}"
LIW_MEM_MB="${LIW_MEM_MB:-$LIW_DEFAULT_MEM_MB}"
LIW_TEST_TIMEOUT="${LIW_TEST_TIMEOUT:-14400}"

usage() {
    # Print the comment header (everything up to the first `set -u` line,
    # which ends the header) with the leading comment marks stripped.  A
    # fixed line range overran the header into the script's own code.
    awk 'NR >= 2 && /^set -u$/ { exit }
         NR >= 2 { sub(/^# ?/, ""); print }' "$0"
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
    --cpus) LIW_CPUS="$2"; shift 2 ;;
    --mem) LIW_MEM_MB="$2"; shift 2 ;;
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

# If this script dies unexpectedly (e.g. an unbound variable under set -u),
# record a failure immediately: the host-side loop waits for the failures
# file, and a silently dead script would otherwise look like a hang until
# the full timeout expires.  The normal exit paths write the real result
# first, which this trap leaves alone.  The Homebrew restore lives in the
# same EXIT trap (bash keeps only one), defined below once
# restore_homebrew exists.
trap restore_homebrew_and_record_failure EXIT

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
    basename "$1" | sed -E 's/^(pylibtiff|Glymur|openslide_python|pylibmc|pyvips|GDAL|mapnik|python_javabridge|python_bioformats)-([0-9.]+)-.*/\2/'
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

restore_homebrew_and_record_failure() {
    restore_homebrew
    # Normal exit paths have already written the real result; only an
    # unexpected death (unbound variable, killed interpreter) lands here.
    if [ ! -f "$TESTROOT/failures" ]; then
        echo 1 >"$TESTROOT/failures"
        echo "=== the in-VM test script died unexpectedly ==="
    fi
}

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

# The per-python suite runs fill the guest's file cache, and tart has no
# balloon driver: guest memory the host has backed once stays backed for
# the rest of the run, so the cache each python leaves behind is memory
# the next python cannot reuse -- seven pythons of installs and sample
# files touch tens of GB of cache, which is how the test exhausted the
# host's memory.  Purge the cache before each python's checks (falling
# back through sudo where purge needs root) and log the guest's free
# memory percentage so the trend is visible in the report.
purge_guest_cache() {
    purge >/dev/null 2>&1 || sudo -n purge >/dev/null 2>&1 || true
    log "guest memory after purge: $(memory_pressure 2>/dev/null | tail -1)"
}

# Report every Mach-O file under each given path whose dependencies or
# RPATHs point outside the allowed system locations.  Missing paths are
# skipped (the wheelhouse's package set varies between runs).
audit_macho() {
    local bad=0 f dep rp root
    for root in "$@"; do
        [ -e "$root" ] || continue
        while IFS= read -r -d '' f; do
            file "$f" 2>/dev/null | grep -q Mach-O || continue
            while IFS= read -r dep; do
                case "$dep" in
                @loader_path/* | @rpath/* | @executable_path/*) ;;
                /usr/lib/* | /System/*) ;;
                # /DLC/... is delocate's install-id marker for copied
                # dylibs; it is never used to resolve a load.
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
    done
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
CONCURRENCY="${4:-$(($(sysctl -n hw.ncpu 2>/dev/null || echo 2) - 1))}"
case "$CONCURRENCY" in '' | *[!0-9]*) CONCURRENCY=1 ;; esac
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
    # python; 3.14t gets its own cp314t wheel, and 3.15t gets the
    # cp315-abi3.abi3t Stable-ABI wheel that upstream 1.4.7 (129f2f6)
    # builds for both GIL states.
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
    # If a pylibmc wheel is present, verify its identity the same way.
    mwhl="$(ls "$WHEELDIR"/pylibmc-*.whl 2>/dev/null | head -1)"
    if [ -n "$mwhl" ]; then
        mver="$(wheel_version "$mwhl")"
        if ! "$venv/bin/pip" install --quiet --find-links "$WHEELDIR" \
            "pylibmc==$mver" >>"$REPORT" 2>&1; then
            log "FAIL python $req: pip install of pylibmc failed"
            FAILURES=$((FAILURES + 1))
            rm -rf "$venv"
            continue
        fi
        minstalled="$($venv/bin/pip show pylibmc 2>/dev/null | sed -n 's/^Version: //p')"
        if [ "$minstalled" != "$mver" ]; then
            log "FAIL python $req: installed pylibmc $minstalled but expected $mver (pip may have used pypi)"
            FAILURES=$((FAILURES + 1))
            rm -rf "$venv"
            continue
        fi
        log "OK python $req: installed pylibmc $minstalled"
    fi
    # If a pyvips wheel is present, verify its identity the same way.
    pvwhl="$(ls "$WHEELDIR"/pyvips-*.whl 2>/dev/null | head -1)"
    if [ -n "$pvwhl" ]; then
        pvver="$(wheel_version "$pvwhl")"
        if ! "$venv/bin/pip" install --quiet --find-links "$WHEELDIR" \
            "pyvips==$pvver" >>"$REPORT" 2>&1; then
            log "FAIL python $req: pip install of pyvips failed"
            FAILURES=$((FAILURES + 1))
            rm -rf "$venv"
            continue
        fi
        pvinstalled="$($venv/bin/pip show pyvips 2>/dev/null | sed -n 's/^Version: //p')"
        if [ "$pvinstalled" != "$pvver" ]; then
            log "FAIL python $req: installed pyvips $pvinstalled but expected $pvver (pip may have used pypi)"
            FAILURES=$((FAILURES + 1))
            rm -rf "$venv"
            continue
        fi
        log "OK python $req: installed pyvips $pvinstalled"
    fi
    # If a GDAL wheel is present, verify its identity the same way.  pypi
    # publishes gdal sdists (and its version numbering can come close to
    # ours), so the installed-version check is what detects a pypi
    # fallback.
    gdwhl="$(ls "$WHEELDIR"/GDAL-*.whl 2>/dev/null | head -1)"
    if [ -n "$gdwhl" ]; then
        gdver="$(wheel_version "$gdwhl")"
        if ! "$venv/bin/pip" install --quiet --find-links "$WHEELDIR" \
            "gdal==$gdver" >>"$REPORT" 2>&1; then
            log "FAIL python $req: pip install of gdal failed"
            FAILURES=$((FAILURES + 1))
            rm -rf "$venv"
            continue
        fi
        gdinstalled="$($venv/bin/pip show gdal 2>/dev/null | sed -n 's/^Version: //p')"
        if [ "$gdinstalled" != "$gdver" ]; then
            log "FAIL python $req: installed gdal $gdinstalled but expected $gdver (pip may have used pypi)"
            FAILURES=$((FAILURES + 1))
            rm -rf "$venv"
            continue
        fi
        log "OK python $req: installed gdal $gdinstalled"
    fi
    # If a mapnik wheel is present, verify its identity the same way.
    mawhl="$(ls "$WHEELDIR"/mapnik-*.whl 2>/dev/null | head -1)"
    if [ -n "$mawhl" ]; then
        maver="$(wheel_version "$mawhl")"
        if ! "$venv/bin/pip" install --quiet --find-links "$WHEELDIR" \
            "mapnik==$maver" >>"$REPORT" 2>&1; then
            log "FAIL python $req: pip install of mapnik failed"
            FAILURES=$((FAILURES + 1))
            rm -rf "$venv"
            continue
        fi
        mainstalled="$($venv/bin/pip show mapnik 2>/dev/null | sed -n 's/^Version: //p')"
        if [ "$mainstalled" != "$maver" ]; then
            log "FAIL python $req: installed mapnik $mainstalled but expected $maver (pip may have used pypi)"
            FAILURES=$((FAILURES + 1))
            rm -rf "$venv"
            continue
        fi
        log "OK python $req: installed mapnik $mainstalled"
    fi
    # If a python_javabridge wheel is present, verify its identity the same
    # way.  pypi publishes python-javabridge with the same version number,
    # so the installed-version check is what detects a pypi fallback.
    jbwhl="$(ls "$WHEELDIR"/python_javabridge-*.whl 2>/dev/null | head -1)"
    if [ -n "$jbwhl" ]; then
        jbver="$(wheel_version "$jbwhl")"
        if ! "$venv/bin/pip" install --quiet --find-links "$WHEELDIR" \
            "python-javabridge==$jbver" >>"$REPORT" 2>&1; then
            log "FAIL python $req: pip install of python-javabridge failed"
            FAILURES=$((FAILURES + 1))
            rm -rf "$venv"
            continue
        fi
        jbinstalled="$($venv/bin/pip show python-javabridge 2>/dev/null | sed -n 's/^Version: //p')"
        if [ "$jbinstalled" != "$jbver" ]; then
            log "FAIL python $req: installed python-javabridge $jbinstalled but expected $jbver (pip may have used pypi)"
            FAILURES=$((FAILURES + 1))
            rm -rf "$venv"
            continue
        fi
        log "OK python $req: installed python-javabridge $jbinstalled"
    fi
    # If a python_bioformats wheel is present, verify its identity the same
    # way (our version carries the bioformats jar-version suffix, so pypi's
    # plain 4.1.0 can never match it).
    bfwhl="$(ls "$WHEELDIR"/python_bioformats-*.whl 2>/dev/null | head -1)"
    if [ -n "$bfwhl" ]; then
        bfver="$(wheel_version "$bfwhl")"
        if ! "$venv/bin/pip" install --quiet --find-links "$WHEELDIR" \
            "python-bioformats==$bfver" >>"$REPORT" 2>&1; then
            log "FAIL python $req: pip install of python-bioformats failed"
            FAILURES=$((FAILURES + 1))
            rm -rf "$venv"
            continue
        fi
        bfinstalled="$($venv/bin/pip show python-bioformats 2>/dev/null | sed -n 's/^Version: //p')"
        if [ "$bfinstalled" != "$bfver" ]; then
            log "FAIL python $req: installed python-bioformats $bfinstalled but expected $bfver (pip may have used pypi)"
            FAILURES=$((FAILURES + 1))
            rm -rf "$venv"
            continue
        fi
        log "OK python $req: installed python-bioformats $bfinstalled"
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

cat >"$TESTROOT/test_pylibmc.py" <<'PYEOF'
import os
import subprocess
import sys

import pylibmc
import _pylibmc

print("pylibmc version:", pylibmc.__version__)

# The patched __init__.py points SASL_PATH at the bundled plugin copy
# before _pylibmc (and thus libsasl2) is imported.
sasl_path = os.environ.get("SASL_PATH", "")
print("SASL_PATH:", sasl_path)
if "/pylibmc/sasl2" not in sasl_path:
    sys.exit("SASL_PATH does not point into the installed pylibmc package")
if not os.path.isdir(sasl_path) or not os.listdir(sasl_path):
    sys.exit("the bundled sasl2 plugin directory is missing or empty")

# The extension is a top-level module; it must load the bundled
# libmemcached from the wheel's .dylibs directory (delocate rewrites the
# load command to an @loader_path-relative path; a system or Homebrew
# libmemcached would mean the bundled library was bypassed).
out = subprocess.run(
    ["otool", "-L", _pylibmc.__file__],
    capture_output=True, text=True, check=True).stdout
line = next(
    (line for line in out.splitlines() if "libmemcached" in line), "")
print(line.strip() or "no libmemcached load command found")
if "@loader_path" not in line or ".dylibs/" not in line:
    sys.exit("libmemcached was not loaded from the bundled .dylibs directory")
print("pylibmc bundled-library check OK")
PYEOF

cat >"$TESTROOT/test_pyvips.py" <<'PYEOF'
import glob
import os
import subprocess
import sys

import pyvips

print("pyvips version:", pyvips.__version__)

# The patched __init__.py preloads the bundled libvips dylib from
# pyvips/.dylibs before importing the cffi extension; API_mode is only
# True when that extension loaded and matched the libvips version (an ABI
# fallback would silently skip it).
if not pyvips.API_mode:
    sys.exit("pyvips is not in API mode: the cffi extension did not import")
print("pyvips API mode OK")

package_dir = os.path.dirname(pyvips.__file__)
if not glob.glob(os.path.join(package_dir, ".dylibs", "libvips*.dylib")):
    sys.exit("the installed pyvips package has no bundled libvips dylib")

# The cffi extension is linked with -undefined dynamic_lookup (the macOS
# default for python extensions), so otool -L shows no libvips load
# command at all -- its symbols bind to whatever libvips the preload put
# in the process.  Run a fresh interpreter with dyld's library printing
# enabled and check that the preloaded libvips is the bundled one.
env = dict(os.environ)
env["DYLD_PRINT_LIBRARIES"] = "1"
out = subprocess.run(
    [sys.executable, "-c", "import pyvips"],
    capture_output=True, text=True, env=env)
bundled = [line for line in (out.stderr or "").splitlines()
           if "/pyvips/.dylibs/libvips" in line]
if not bundled:
    sys.exit(
        "the process did not load the bundled libvips dylib; loaded "
        "libvips images:\n" + "\n".join(
            line for line in (out.stderr or "").splitlines()
            if "libvips" in line))
print(bundled[0].strip())
print("pyvips bundled-library check OK")
PYEOF

cat >"$TESTROOT/test_gdal.py" <<'PYEOF'
import os
import subprocess
import sys

import osgeo
import osgeo.gdal
import osgeo.osr

print("gdal version:", osgeo.gdal.__version__)

# The patched osgeo/__init__.py exports the paths of the bundled libgdal
# and libgeos_c dylibs (delocate puts them in osgeo/.dylibs inside the
# wheel; the linux auditwheel-style GDAL.libs location is the fallback).
gdal_path = getattr(osgeo, "GDAL_LIBRARY_PATH", "")
geos_path = getattr(osgeo, "GEOS_LIBRARY_PATH", "")
print("GDAL_LIBRARY_PATH:", gdal_path)
print("GEOS_LIBRARY_PATH:", geos_path)
if ".dylibs/" not in gdal_path:
    sys.exit("GDAL_LIBRARY_PATH does not point into the bundled .dylibs directory")
if ".dylibs/" not in geos_path:
    sys.exit("GEOS_LIBRARY_PATH does not point into the bundled .dylibs directory")
for path in (gdal_path, geos_path):
    if not os.path.exists(path):
        sys.exit("bundled library does not exist: " + path)

# The proj and gdal data directories are bundled inside the package; the
# patched __init__ points PROJ and GDAL at them.  A coordinate transform
# from EPSG:4326 exercises proj.db through the bundled data.
srs = osgeo.osr.SpatialReference()
srs.ImportFromEPSG(4326)
if srs.GetName() != "WGS 84":
    sys.exit("EPSG:4326 did not resolve through the bundled proj data: " + srs.GetName())
print("proj data lookup OK:", srs.GetName())

# The extension links libgdal through an absolute install name that
# delocate rewrote to an @loader_path-relative one; verify with dyld's
# library printing that the loaded libgdal is the bundled one (a system or
# Homebrew copy winning the load would mean the bundled library was
# bypassed).
env = dict(os.environ)
env["DYLD_PRINT_LIBRARIES"] = "1"
out = subprocess.run(
    [sys.executable, "-c", "import osgeo.gdal"],
    capture_output=True, text=True, env=env)
bundled = [line for line in (out.stderr or "").splitlines()
           if "/osgeo/.dylibs/libgdal" in line]
if not bundled:
    sys.exit(
        "the process did not load the bundled libgdal dylib; loaded "
        "libgdal images:\n" + "\n".join(
            line for line in (out.stderr or "").splitlines()
            if "libgdal" in line))
print(bundled[0].strip())
print("gdal bundled-library check OK")
PYEOF

cat >"$TESTROOT/test_mapnik.py" <<'PYEOF'
import os
import subprocess
import sys

import mapnik

# The patched paths.py points the input plugins and fonts at the copies
# bundled inside the installed mapnik package.
from mapnik import paths

package_dir = os.path.dirname(mapnik.__file__)
print("mapnik package:", package_dir)
plugins_dir = getattr(paths, "inputpluginspath", "")
fonts_dir = getattr(paths, "fontscollectionpath", "")
print("inputpluginspath:", plugins_dir)
print("fontscollectionpath:", fonts_dir)
for label, p in (("input plugins", plugins_dir), ("fonts", fonts_dir)):
    if not p or package_dir not in os.path.abspath(p):
        sys.exit(label + " path does not point inside the installed mapnik package: " + str(p))
    if not os.path.isdir(p) or not os.listdir(p):
        sys.exit("the bundled " + label + " directory is missing or empty")
inputs = [f for f in os.listdir(plugins_dir) if f.endswith(".input")]
print("bundled input plugins:", ", ".join(sorted(inputs)))
if not any(f.startswith("gdal") for f in inputs):
    sys.exit("the gdal+ogr input plugin is missing from the bundled set")

# The extension links libmapnik through an absolute install name that
# delocate rewrote to an @loader_path-relative one; a system or Homebrew
# libmapnik winning the load would mean the bundled library was bypassed.
exts = [f for f in os.listdir(package_dir)
        if f.startswith("_mapnik") and f.endswith(".so")]
if not exts:
    sys.exit("the installed mapnik package has no _mapnik extension")
out = subprocess.run(
    ["otool", "-L", os.path.join(package_dir, exts[0])],
    capture_output=True, text=True)
line = next(
    (line for line in (out.stdout or "").splitlines() if "libmapnik" in line), "")
print(line.strip() or "no libmapnik load command found")
if "@loader_path" not in line or ".dylibs/" not in line:
    sys.exit("the _mapnik extension does not load the bundled libmapnik from .dylibs")

# The data_path patch exports set_data_paths; it must point at the bundled
# proj and gdal trees inside the package (the bundled proj.db is what the
# projection below must resolve through).
proj_dir = mapnik.proj_data_dir()
gdal_dir = mapnik.gdal_data_dir()
print("proj_data_dir:", proj_dir)
print("gdal_data_dir:", gdal_dir)
for label, p in (("proj", proj_dir), ("gdal", gdal_dir)):
    if not p or package_dir not in os.path.abspath(p) or not os.path.isdir(p):
        sys.exit(label + " data path does not point inside the installed mapnik package: " + str(p))
if not os.path.exists(os.path.join(proj_dir, "proj.db")):
    sys.exit("the bundled proj data tree has no proj.db")

# A projection built from the bundled proj data exercises libmapnik and
# the bundled proj.db in one call: the constructor resolves the EPSG code
# through proj.db and raises a proj_init_error if it cannot.  python-mapnik
# 4.3.2 exposes the resolved definition through definition()/params(); the
# old proj4 property no longer exists at this pin.
p = mapnik.Projection("EPSG:3857")
definition = p.definition()
print("EPSG:3857 resolves:", definition)
if not definition:
    sys.exit("EPSG:3857 did not resolve through the bundled proj data")
if p.geographic:
    sys.exit("EPSG:3857 was not recognized as a projected CRS")
print("mapnik bundled-library check OK")
PYEOF

cat >"$TESTROOT/test_javabridge.py" <<'PYEOF'
import os
import sys

import javabridge
import javabridge.locate

# The patched locate.py must resolve the JVM to the copy bundled inside the
# installed javabridge package (site-packages/javabridge/jvm), not to a
# system or Homebrew Java.
jvm_dir = javabridge.locate.find_javahome()
print("jvm dir:", jvm_dir)
if not jvm_dir or not jvm_dir.endswith(os.path.join("javabridge", "jvm")):
    sys.exit("javabridge did not resolve the bundled jvm tree: " + str(jvm_dir))
libjvm = os.path.join(jvm_dir, "jre", "lib", "server", "libjvm.dylib")
if not os.path.exists(libjvm):
    sys.exit("the bundled jvm tree has no jre/lib/server/libjvm.dylib")

# start_vm loads libjvm.dylib from the resolved tree on darwin (the mac
# extension dlopens it instead of linking it); java.home then proves that
# the JVM that is actually running IS the bundled one.
javabridge.start_vm(run_headless=True)
java_home = javabridge.static_call(
    "java/lang/System", "getProperty",
    "(Ljava/lang/String;)Ljava/lang/String;", "java.home")
print("java.home:", java_home)
if os.path.realpath(java_home) != os.path.realpath(os.path.join(jvm_dir, "jre")):
    sys.exit("the running JVM is not the bundled one (java.home mismatch)")
print("java.version:", javabridge.static_call(
    "java/lang/System", "getProperty",
    "(Ljava/lang/String;)Ljava/lang/String;", "java.version"))
print("java.vm.vendor:", javabridge.static_call(
    "java/lang/System", "getProperty",
    "(Ljava/lang/String;)Ljava/lang/String;", "java.vm.vendor"))
javabridge.kill_vm()
print("javabridge bundled-JVM check OK")
PYEOF

for venv in $VENVDIRS; do
    req="$(basename "$venv" | sed 's/^venv-//')"
    # The per-python run directory is named here (it is wiped and
    # recreated before the shared suite below); the openslide check
    # references its future sample.svs path.
    rundir="$TESTROOT/run-$req"
    # Release the previous pythons' file cache before this one's runs.
    purge_guest_cache
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
    # pylibmc's C extension is a top-level module (installed outside the
    # pylibmc package directory), so it is audited alongside the packages.
    audit_macho "$site/libtiff" "$site/glymur" "$site/openslide" \
        "$site/pylibmc" "$site/pyvips" "$site/osgeo" "$site/mapnik" \
        "$site/javabridge" "$site/bioformats" \
        "$site"/_pylibmc*.so >>"$REPORT" 2>&1 || audit_fail=1
    if [ "$audit_fail" != 0 ]; then
        log "FAIL python $req: otool audit found forbidden library references"
        FAILURES=$((FAILURES + 1))
    else
        log "OK python $req: otool audit clean (libtiff, glymur, openslide, pylibmc, pyvips, gdal, mapnik, javabridge)"
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
    if [ -n "$(ls "$WHEELDIR"/pylibmc-*.whl 2>/dev/null)" ]; then
        if "$venv/bin/python" "$TESTROOT/test_pylibmc.py" >>"$REPORT" 2>&1; then
            log "OK python $req: pylibmc bundled-library check passed"
        else
            log "FAIL python $req: pylibmc bundled-library check failed"
            FAILURES=$((FAILURES + 1))
        fi
    fi
    if [ -n "$(ls "$WHEELDIR"/pyvips-*.whl 2>/dev/null)" ]; then
        if "$venv/bin/python" "$TESTROOT/test_pyvips.py" >>"$REPORT" 2>&1; then
            log "OK python $req: pyvips bundled-library check passed"
        else
            log "FAIL python $req: pyvips bundled-library check failed"
            FAILURES=$((FAILURES + 1))
        fi
        # The bundled vips tool (exposed as a console script) exercises the
        # bundled dylibs the way the linux wheel's vips does.
        if "$venv/bin/vips" --version >>"$REPORT" 2>&1; then
            log "OK python $req: bundled vips tool ran"
        else
            log "FAIL python $req: bundled vips tool failed"
            FAILURES=$((FAILURES + 1))
        fi
    fi
    if [ -n "$(ls "$WHEELDIR"/GDAL-*.whl 2>/dev/null)" ]; then
        if "$venv/bin/python" "$TESTROOT/test_gdal.py" >>"$REPORT" 2>&1; then
            log "OK python $req: gdal bundled-library check passed"
        else
            log "FAIL python $req: gdal bundled-library check failed"
            FAILURES=$((FAILURES + 1))
        fi
        # The bundled gdal tool (exposed as a console script) exercises the
        # bundled dylibs and data the way the linux wheel's gdalinfo does.
        if "$venv/bin/gdalinfo" --version >>"$REPORT" 2>&1; then
            log "OK python $req: bundled gdalinfo tool ran"
        else
            log "FAIL python $req: bundled gdalinfo tool failed"
            FAILURES=$((FAILURES + 1))
        fi
    fi
    if [ -n "$(ls "$WHEELDIR"/mapnik-*.whl 2>/dev/null)" ]; then
        if "$venv/bin/python" "$TESTROOT/test_mapnik.py" >>"$REPORT" 2>&1; then
            log "OK python $req: mapnik bundled-library check passed"
        else
            log "FAIL python $req: mapnik bundled-library check failed"
            FAILURES=$((FAILURES + 1))
        fi
        # The bundled mapnik tool (exposed as a console script) exercises
        # the bundled dylibs, fonts, and data the way the shared suite's
        # mapnik-render check does.  Upstream's --version branch prints
        # "version <x>" to std::clog and returns 1 (like --help), which is
        # why the shared suite judges the output through a grep instead of
        # the exit status; match that semantics here.  Capture the output
        # rather than piping: the in-VM script's pipefail would turn the
        # mapnik-render status back into a failure.
        mr_version="$($venv/bin/mapnik-render --version 2>&1 || true)"
        if echo "$mr_version" | grep -q version; then
            log "OK python $req: bundled mapnik-render tool ran ($mr_version)"
        else
            log "FAIL python $req: bundled mapnik-render tool failed"
            FAILURES=$((FAILURES + 1))
        fi
    fi
    if [ -n "$(ls "$WHEELDIR"/python_javabridge-*.whl 2>/dev/null)" ]; then
        if "$venv/bin/python" "$TESTROOT/test_javabridge.py" >>"$REPORT" 2>&1; then
            log "OK python $req: javabridge bundled-JVM check passed"
        else
            log "FAIL python $req: javabridge bundled-JVM check failed"
            FAILURES=$((FAILURES + 1))
        fi
        # The bundled java launcher (exposed as a console script) exercises
        # the bundled JDK binaries and dylibs the way the bundled tiffinfo
        # and gdalinfo do; the shared suite runs the same command inside
        # its venvs.
        if "$venv/bin/java" -version 2>>"$REPORT"; then
            log "OK python $req: bundled java launcher ran"
        else
            log "FAIL python $req: bundled java launcher failed"
            FAILURES=$((FAILURES + 1))
        fi
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
        audit_macho "$venvsite/libtiff" "$venvsite/glymur" "$venvsite/openslide" \
            "$venvsite/pylibmc" "$venvsite/pyvips" "$venvsite/osgeo" "$venvsite/mapnik" \
            "$venvsite/javabridge" "$venvsite/bioformats" \
            "$venvsite"/_pylibmc*.so >>"$REPORT" 2>&1 || audit_fail=1
        if [ "$audit_fail" != 0 ]; then
            log "FAIL python $req: otool audit of the test_script.sh venv found forbidden library references"
            FAILURES=$((FAILURES + 1))
        else
            log "OK python $req: otool audit of the test_script.sh venv clean (libtiff, glymur, openslide, pylibmc, pyvips, gdal, mapnik, javabridge)"
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
        # Save whatever the in-VM script produced before it died; without
        # this the only copy of the partial report lives inside the stopped
        # VM.
        run_ssh "cat $LIW_GUEST_HOME/liw_test/report.txt" >/tmp/macos_test_report.txt 2>/dev/null || true
        run_ssh "cat $LIW_GUEST_HOME/liw_test.log" >/tmp/macos_test_log.txt 2>/dev/null || true
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
