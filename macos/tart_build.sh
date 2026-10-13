#!/usr/bin/env bash
# tart_build.sh - run on the HOST (outside the tart VM) to do a complete,
# isolated macOS arm64 wheel build.
#
# This creates a fresh tart VM by cloning the base VM, copies this
# repository into it, runs macos/build_wheels.sh inside the VM, retrieves
# the built wheels into ./wheels/, and deletes the VM.  Because every run
# starts from a fresh clone of the pristine base VM, nothing from previous
# builds (or from the host) can influence the wheels.  On failure the VM is
# left in place for debugging.
#
# Usage:
#   macos/tart_build.sh [options] [packages...]
#
# Options:
#   --base NAME     base tart VM to clone (default: $LIW_TART_BASE, else
#                   agent_base, matching manthey/utils agent_tart.sh)
#   --name NAME     name for the build VM (default: liw_wheels_build)
#   --cpus N        vCPUs for the build VM (default: 4)
#   --mem MB        memory for the build VM in MB (default: 8192)
#   --packages LIST packages to build, space separated (default: all)
#   --pythons LIST  python versions for the build (default: 3.11-3.15,
#                   3.14t, 3.15t)
#   --keep          do not delete the VM after a successful build
#   -h | --help     show this help
#
# The base VM must already exist and be provisioned (it is the VM from
# which this sandbox was made; see manthey/utils agent_tart.sh provision).

set -u
set -o pipefail

LIW_TART_USER="${LIW_TART_USER:-admin}"
LIW_GUEST_HOME="/Users/$LIW_TART_USER"
LIW_LOG_DIR="${LIW_TART_LOG_DIR:-$HOME/.large_image_wheels_tart/logs}"
LIW_SSH_DIR="${LIW_TART_SSH_DIR:-$HOME/.large_image_wheels_tart/ssh}"

LIW_TART_BASE="${LIW_TART_BASE:-liw_wheels_base}"
LIW_VM_NAME="liw_wheels_build"
LIW_PACKAGES=""
LIW_PYTHONS="${LIW_PYTHONS:-3.11 3.12 3.13 3.14 3.15 3.14t 3.15t}"
LIW_KEEP=0
LIW_CPUS="${LIW_CPUS:-4}"
LIW_MEM_MB="${LIW_MEM_MB:-8192}"
# Overall build timeout in seconds (default 6 hours).
LIW_TIMEOUT="${LIW_TIMEOUT:-21600}"

usage() {
    sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
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
    --cpus) LIW_CPUS="$2"; shift 2 ;;
    --mem) LIW_MEM_MB="$2"; shift 2 ;;
    --packages) LIW_PACKAGES="$2"; shift 2 ;;
    --pythons) LIW_PYTHONS="$2"; shift 2 ;;
    --keep) LIW_KEEP=1; shift ;;
    -h | --help) usage ;;
    --) shift; break ;;
    -*) usage ;;
    *) break ;;
    esac
done
[ -n "$LIW_PACKAGES" ] && LIW_PACKAGES="$*"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_NAME="$(basename "$REPO_DIR")"
# All of the helpers and main flow below use VM_NAME.
VM_NAME="$LIW_VM_NAME"

command -v tart >/dev/null 2>&1 || die "tart not found on the host"
command -v ssh >/dev/null 2>&1 || die "ssh not found on the host"
mkdir -p "$LIW_LOG_DIR" "$LIW_SSH_DIR"

# --- ssh key handling (same conventions as agent_tart.sh) ------------------
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
    info "generating a new ssh keypair at $HOME/.ssh/id_ed25519"
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

fail() {
    echo "BUILD FAILED; tail of the in-VM log:" >&2
    run_ssh "tail -50 ~/$REPO_NAME/macos_build.log" 2>/dev/null || true
    # Release the VM's memory but keep it for debugging; inspect it with:
    #   tart run --no-graphics $VM_NAME
    #   ssh admin@$(tart ip $VM_NAME)
    stop_vm
    echo "VM $VM_NAME was stopped and kept for debugging." >&2
    exit 1
}

# --- main ------------------------------------------------------------------

# The wheel build VMs use their own namespace (liw_wheels_*); agent_*
# names belong to the manthey/utils agent sandboxes.  Until a dedicated
# liw_wheels_base has been provisioned, fall back to the agent_base that
# agent_tart.sh creates, with a notice.
if ! vm_exists_retry "$LIW_TART_BASE"; then
    if [ "$LIW_TART_BASE" = "liw_wheels_base" ] && vm_exists_retry agent_base; then
        info "$LIW_TART_BASE does not exist; using agent_base for now"
        info "provision a dedicated base to stop this notice:"
        info "  agent_tart.sh provision --base liw_wheels_base"
        LIW_TART_BASE=agent_base
    else
        die "base VM $LIW_TART_BASE does not exist; pass --base NAME (the base is provisioned by manthey/utils agent_tart.sh)"
    fi
fi

if vm_running "$LIW_TART_BASE"; then
    info "base VM $LIW_TART_BASE is running; stopping it so it can be cloned"
    tart stop --timeout 60 "$LIW_TART_BASE" >/dev/null 2>&1 || true
fi
vm_exists_retry "$VM_NAME" && delete_vm

info "cloning $LIW_TART_BASE into $VM_NAME"
tart clone "$LIW_TART_BASE" "$VM_NAME" || die "cloning failed"
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
    die "$VM_NAME did not acquire an IP (see log above; check 'tart list' for VMs holding memory)"
}
wait_ssh_ready || die "$VM_NAME did not become reachable over ssh"

if ! run_ssh true 2>/dev/null; then
    info "bootstrapping the ssh key into $VM_NAME (password bootstrap)"
    if command -v sshpass >/dev/null 2>&1; then
        sshpass -p "${LIW_TART_PASS:-admin}" ssh-copy-id \
            -i "$LIW_SSH_KEY.pub" $(ssh_opts | sed 's/ -o BatchMode=yes//') \
            "$LIW_TART_USER@$(vm_ip "$VM_NAME")" || die "could not install the ssh key"
    else
        die "ssh key not accepted and sshpass is not installed"
    fi
fi
run_ssh true || die "ssh into $VM_NAME still fails after the key bootstrap"

info "copying $REPO_NAME into the VM"
run_ssh "mkdir -p ~/$REPO_NAME"
tar -C "$(dirname "$REPO_DIR")" \
    --exclude "$REPO_NAME/.git" \
    --exclude "$REPO_NAME/wheels" \
    --exclude "$REPO_NAME/osx_build" \
    --exclude "$REPO_NAME/.tart_build" \
    -cf - "$REPO_NAME" | run_ssh "tar -xf - -C ~/" ||
    die "could not copy the repository into the VM"

info "starting the wheel build in the VM"
run_ssh "rm -rf ~/$REPO_NAME/liw_macos_build" || true
run_ssh "cd ~/$REPO_NAME && LIW_PYTHONS='$LIW_PYTHONS' nohup bash macos/build_wheels.sh $LIW_PACKAGES > $LIW_GUEST_HOME/macos_build.log 2>&1 < /dev/null &"

info "waiting for the build to finish (progress: tail of ~/macos_build.log)"
elapsed=0
while true; do
    sleep 30
    elapsed=$((elapsed + 30))
    code="$(run_ssh "cat $LIW_GUEST_HOME/liw_macos_build/exit_code 2>/dev/null" 2>/dev/null || true)"
    if [ -n "$code" ]; then
        break
    fi
    if ! vm_running "$VM_NAME" || [ -z "$(vm_ip "$VM_NAME" 5)" ]; then
        fail
    fi
    if [ "$elapsed" -ge "$LIW_TIMEOUT" ]; then
        echo "error: build timed out after $LIW_TIMEOUT seconds" >&2
        fail
    fi
    info "still building (${elapsed}s elapsed); last log line:"
    run_ssh "tail -1 $LIW_GUEST_HOME/macos_build.log" 2>/dev/null || true
done
if [ "$code" != "0" ]; then
    echo "error: in-VM build exited with status $code" >&2
    fail
fi

info "build succeeded; retrieving wheels"
mkdir -p "$REPO_DIR/wheels"
run_ssh "cd $LIW_GUEST_HOME/liw_macos_build/wheelhouse && tar -cf - *macosx*.whl" |
    tar -xf - -C "$REPO_DIR/wheels/" ||
    die "could not retrieve the wheels (VM $VM_NAME left running for debugging)"
ls "$REPO_DIR/wheels/"*macosx*.whl >/dev/null 2>&1 ||
    die "no macosx wheels were retrieved (VM $VM_NAME left running for debugging)"
ls -l "$REPO_DIR/wheels/"*macosx*.whl

if [ "$LIW_KEEP" = 1 ]; then
    info "keeping $VM_NAME (--keep); stop it with: tart stop $VM_NAME"
else
    delete_vm
fi
info "done"
