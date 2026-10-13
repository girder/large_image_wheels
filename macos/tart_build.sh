#!/usr/bin/env bash
# tart_build.sh - run on the HOST (outside the tart VM) to do a complete,
# isolated macOS arm64 wheel build.
#
# This is standalone: it manages its own tart VM lifecycle, the way
# `docker build` manages images.  A pristine macOS base VM
# (liw_wheels_base) is provisioned once from a published macOS image
# (Xcode Command Line Tools, Homebrew with the build tools, pyenv with
# the pythons); every build then clones a fresh VM from that base, runs
# macos/build_wheels.sh inside it, retrieves the wheels into ./wheels/,
# and deletes the clone.  Because every run starts from a fresh clone of
# the pristine base, nothing from previous builds (or from the host) can
# influence the wheels.  On failure the clone is stopped and kept for
# debugging.
#
# Usage:
#   macos/tart_build.sh provision [options]   provision the base VM
#   macos/tart_build.sh [options] [packages]  build wheels (default)
#
# The build command provisions the base automatically if it does not
# exist yet (delete the base to force a re-provision, like a docker
# image rebuild).
#
# Options:
#   --base NAME     base tart VM (default: $LIW_TART_BASE, else
#                   liw_wheels_base)
#   --image REF     OS image to provision the base from (default:
#                   $LIW_TART_BASE_IMAGE, else
#                   ghcr.io/cirruslabs/macos-golden-gate-base:latest)
#   --name NAME     name for the build VM (default: liw_wheels_build)
#   --cpus N        vCPUs for the build VM (default: 4)
#   --mem MB        memory for the build VM in MB (default: 8192)
#   --disk GB       disk size when provisioning the base (default: 150)
#   --packages LIST packages to build, space separated (default: all)
#   --pythons LIST  python versions for the build (default: 3.11-3.15,
#                   3.14t, 3.15t)
#   --keep          do not delete the build VM after a successful build
#   -h | --help     show this help

set -u
set -o pipefail

LIW_TART_USER="${LIW_TART_USER:-admin}"
LIW_TART_PASS="${LIW_TART_PASS:-admin}"
LIW_GUEST_HOME="/Users/$LIW_TART_USER"
LIW_LOG_DIR="${LIW_TART_LOG_DIR:-$HOME/.large_image_wheels_tart/logs}"
LIW_SSH_DIR="${LIW_TART_SSH_DIR:-$HOME/.large_image_wheels_tart/ssh}"

LIW_TART_BASE="${LIW_TART_BASE:-liw_wheels_base}"
LIW_TART_BASE_IMAGE="${LIW_TART_BASE_IMAGE:-ghcr.io/cirruslabs/macos-golden-gate-base:latest}"
LIW_VM_NAME="liw_wheels_build"
LIW_PACKAGES=""
LIW_PYTHONS="${LIW_PYTHONS:-3.11 3.12 3.13 3.14 3.15 3.14t 3.15t}"
LIW_KEEP=0
LIW_CPUS="${LIW_CPUS:-4}"
LIW_MEM_MB="${LIW_MEM_MB:-8192}"
LIW_DISK_GB="${LIW_DISK_GB:-150}"
# Overall build/provision timeout in seconds (default 6 / 3 hours).
LIW_TIMEOUT="${LIW_TIMEOUT:-21600}"
LIW_PROVISION_TIMEOUT="${LIW_PROVISION_TIMEOUT:-10800}"

usage() {
    sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

die() {
    echo "error: $*" >&2
    exit 1
}

info() {
    echo ">>> $*" >&2
}

# The provisioning command, if given, must be the first argument.
COMMAND="build"
if [ "${1:-}" = "provision" ]; then
    COMMAND="provision"
    shift
fi

while [ $# -gt 0 ]; do
    case "$1" in
    --base) LIW_TART_BASE="$2"; shift 2 ;;
    --image) LIW_TART_BASE_IMAGE="$2"; shift 2 ;;
    --name) LIW_VM_NAME="$2"; shift 2 ;;
    --cpus) LIW_CPUS="$2"; shift 2 ;;
    --mem) LIW_MEM_MB="$2"; shift 2 ;;
    --disk) LIW_DISK_GB="$2"; shift 2 ;;
    --packages) LIW_PACKAGES="$2"; shift 2 ;;
    --pythons) LIW_PYTHONS="$2"; shift 2 ;;
    --keep) LIW_KEEP=1; shift ;;
    -h | --help) usage ;;
    --) shift; break ;;
    -*) usage ;;
    *) break ;;
    esac
done
LIW_PACKAGES="${LIW_PACKAGES:+$LIW_PACKAGES }$*"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_NAME="$(basename "$REPO_DIR")"
# All of the helpers and main flow below use VM_NAME.
VM_NAME="$LIW_VM_NAME"

command -v tart >/dev/null 2>&1 || die "tart not found on the host"
command -v ssh >/dev/null 2>&1 || die "ssh not found on the host"
mkdir -p "$LIW_LOG_DIR" "$LIW_SSH_DIR"

# --- ssh key handling (same conventions as manthey/utils agent_tart.sh) ----
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

start_vm() {
    mkdir -p "$LIW_LOG_DIR"
    if vm_running "$VM_NAME"; then
        return 0
    fi
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
    wait_ssh_ready || {
        stop_vm
        die "$VM_NAME did not become reachable over ssh"
    }
    if ! run_ssh true 2>/dev/null; then
        info "bootstrapping the ssh key into $VM_NAME (password bootstrap)"
        if command -v sshpass >/dev/null 2>&1; then
            sshpass -p "$LIW_TART_PASS" ssh-copy-id \
                -i "$LIW_SSH_KEY.pub" $(ssh_opts | sed 's/ -o BatchMode=yes//') \
                "$LIW_TART_USER@$(vm_ip "$VM_NAME")" ||
                die "could not install the ssh key"
        else
            die "ssh key not accepted and sshpass is not installed"
        fi
    fi
    run_ssh true || die "ssh into $VM_NAME still fails after the key bootstrap"
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

# The in-VM provisioning script: everything the base VM needs for wheel
# building, and nothing else.  This is the macOS equivalent of the
# manylinux base image contents.  It is deliberately standalone (no
# dependency on manthey/utils provisioning).
IN_VM_PROVISION="$LIW_SSH_DIR/base_provision.sh"
cat >"$IN_VM_PROVISION" <<'IN_VM_EOF'
#!/usr/bin/env bash
# base_provision.sh - runs INSIDE the base VM to provision it for wheel
# building.  Completed steps are stamped, so re-running is safe.
set -uo pipefail

finish() { echo "$?" >"$HOME/.liw_provision_exit"; }
trap finish EXIT
LIW_TART_PASS="${LIW_TART_PASS:-admin}"
STAMPS="$HOME/.liw_provision_stamps"
mkdir -p "$STAMPS"
step() { echo "=== $(date '+%Y-%m-%d %H:%M:%S') $*"; }
skip_if_done() { [ -f "$STAMPS/$1" ]; }
done_stamp() { touch "$STAMPS/$1"; }

# --- passwordless sudo ------------------------------------------------------
if ! skip_if_done sudo; then
    step "passwordless sudo"
    if ! sudo -n true 2>/dev/null; then
        printf '%s\n' "$LIW_TART_PASS" | sudo -S true 2>/dev/null ||
            echo "WARNING: sudo needed a password; it was entered non-interactively" >&2
    fi
    echo "$USER ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/liw-nopasswd >/dev/null
    sudo chmod 440 /etc/sudoers.d/liw-nopasswd
    done_stamp sudo
fi

# --- disk space -------------------------------------------------------------
avail_gb="$(df -g / | awk 'NR == 2 {print $4}')"
if [ "${avail_gb:-0}" -lt 60 ]; then
    echo "WARNING: only ${avail_gb} GB free; provisioning wants roughly 60 GB" >&2
fi

# --- Xcode Command Line Tools (compilers; required for pyenv and brew) ------
if ! skip_if_done clt; then
    if ! xcode-select -p >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
        step "installing Xcode Command Line Tools (several minutes)"
        touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
        label="$(softwareupdate -l 2>/dev/null |
            sed -n 's/^[^L]*Label: "\(.*\)"/\1/p' |
            grep 'Command Line Tools' | head -1)"
        rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
        if [ -z "$label" ]; then
            echo "ERROR: no Command Line Tools label found via softwareupdate" >&2
            exit 1
        fi
        sudo softwareupdate --install "$label" --agree-license
        sudo xcode-select --switch /Library/Developer/CommandLineTools 2>/dev/null || true
    fi
    done_stamp clt
fi

# --- Homebrew (build tools only; wheel libraries are built from source) -----
if ! skip_if_done brew; then
    if ! command -v brew >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/brew ]; then
        step "installing Homebrew"
        NONINTERACTIVE=1 /bin/bash -c "$(
            curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh
        )"
    fi
    eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
    command -v brew >/dev/null 2>&1 || {
        echo "ERROR: Homebrew installation failed" >&2
        exit 1
    }
    step "brew packages (build tools and python-build prerequisites)"
    brew install cmake ninja pkgconf m4 autoconf automake libtool ccache \
        readline sqlite3 xz zlib tcl-tk openssl@3 || {
        echo "ERROR: brew install failed" >&2
        exit 1
    }
    brew cleanup --prune=all >/dev/null 2>&1 || true
    done_stamp brew
fi

# --- pyenv pythons ----------------------------------------------------------
# Built with a clean environment: no -march=native (it must not leak into
# the pythons that build the wheels), no Homebrew linker flags, and the
# 11.0 deployment target so the wheel platform tag stays macosx_11_0_arm64.
if ! skip_if_done pyenv; then
    step "pyenv"
    if [ ! -x "$HOME/.pyenv/bin/pyenv" ]; then
        curl -L https://github.com/pyenv/pyenv-installer/raw/master/bin/pyenv-installer | bash
    fi
    done_stamp pyenv
fi
export PYENV_ROOT="$HOME/.pyenv"
export MACOSX_DEPLOYMENT_TARGET=11.0
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS SDKROOT
PYTHONS="${LIW_PYTHONS:-3.11 3.12 3.13 3.14 3.15 3.14t 3.15t}"
for version in $PYTHONS; do
    skip_if_done "python-$version" && continue
    step "pyenv install $version (several minutes)"
    "$PYENV_ROOT/bin/pyenv" install -s "$version" || {
        echo "ERROR: pyenv install $version failed" >&2
        exit 1
    }
    dir="$PYENV_ROOT/versions/$version"
    [ -d "$dir" ] || dir="$(ls -d "$PYENV_ROOT/versions/${version%t}".*t 2>/dev/null | sort -V | tail -1)"
    [ -n "$dir" ] || dir="$(ls -d "$PYENV_ROOT/versions/$version".* 2>/dev/null | grep -v 't$' | sort -V | tail -1)"
    if ! "$dir/bin/python" -c 'import ssl' 2>/dev/null; then
        echo "ERROR: python $version was built without a working ssl module; pip will not work" >&2
        exit 1
    fi
    "$dir/bin/python" -m pip install -q -U pip setuptools wheel || {
        echo "ERROR: pip upgrade failed for $version" >&2
        exit 1
    }
    done_stamp "python-$version"
done

# --- git identity -----------------------------------------------------------
git config --global user.name "Wheel Builder" 2>/dev/null || true
git config --global user.email "wheels@example.com" 2>/dev/null || true

step "provisioning complete"
IN_VM_EOF

# Provision the base VM: clone the pristine OS image, boot, and run the
# provisioning script inside.  Like a docker image build, provisioning
# always starts from the pristine image; there is no in-place update.
provision_base() {
    if vm_exists_retry "$LIW_TART_BASE"; then
        info "$LIW_TART_BASE exists; deleting it for a fresh provisioning"
        VM_NAME="$LIW_TART_BASE"
        delete_vm
    fi
    VM_NAME="$LIW_TART_BASE"
    info "cloning $LIW_TART_BASE_IMAGE into $LIW_TART_BASE (large download on first run)"
    tart clone "$LIW_TART_BASE_IMAGE" "$LIW_TART_BASE" ||
        die "cloning $LIW_TART_BASE_IMAGE failed"
    tart set "$LIW_TART_BASE" --cpu "$LIW_CPUS" --memory "$LIW_MEM_MB" \
        --disk-size "$LIW_DISK_GB" || die "configuring $LIW_TART_BASE failed"
    start_vm
    run_ssh "cat > $LIW_GUEST_HOME/.liw_base_provision.sh" <"$IN_VM_PROVISION" ||
        die "could not copy the provisioning script"
    info "provisioning $LIW_TART_BASE (this installs Xcode CLT, Homebrew, and"
    info "several pythons; it can take 30-60 minutes)"
    run_ssh "nohup bash $LIW_GUEST_HOME/.liw_base_provision.sh > $LIW_GUEST_HOME/liw_provision.log 2>&1 < /dev/null &"

    elapsed=0
    while true; do
        sleep 30
        elapsed=$((elapsed + 30))
        code="$(run_ssh "cat $LIW_GUEST_HOME/.liw_provision_exit 2>/dev/null" 2>/dev/null || true)"
        if [ -n "$code" ]; then
            break
        fi
        if ! vm_running "$VM_NAME"; then
            echo "error: provisioning VM died; check $LIW_LOG_DIR/$VM_NAME.log" >&2
            stop_vm
            exit 1
        fi
        if [ "$elapsed" -ge "$LIW_PROVISION_TIMEOUT" ]; then
            echo "error: provisioning timed out after $LIW_PROVISION_TIMEOUT seconds" >&2
            stop_vm
            exit 1
        fi
        info "still provisioning (${elapsed}s elapsed); last log line:"
        run_ssh "tail -1 $LIW_GUEST_HOME/liw_provision.log" 2>/dev/null || true
    done
    if [ "$code" != "0" ]; then
        echo "error: provisioning failed; tail of the in-VM log:" >&2
        run_ssh "tail -50 $LIW_GUEST_HOME/liw_provision.log" 2>/dev/null || true
        stop_vm
        echo "VM $VM_NAME was stopped and kept for debugging." >&2
        exit 1
    fi
    info "shutting down the provisioned $LIW_TART_BASE"
    stop_vm
    info "base VM ready; builds will clone it with: tart clone $LIW_TART_BASE <name>"
}

# --- main -------------------------------------------------------------------

if [ "$COMMAND" = "provision" ]; then
    provision_base
    exit 0
fi

if ! vm_exists_retry "$LIW_TART_BASE"; then
    info "base VM $LIW_TART_BASE does not exist; provisioning it (docker-like)"
    provision_base
fi

if vm_running "$LIW_TART_BASE"; then
    info "base VM $LIW_TART_BASE is running; stopping it so it can be cloned"
    tart stop --timeout 60 "$LIW_TART_BASE" >/dev/null 2>&1 || true
fi
vm_exists_retry "$VM_NAME" && delete_vm

info "cloning $LIW_TART_BASE into $VM_NAME"
tart clone "$LIW_TART_BASE" "$VM_NAME" || die "cloning failed"
tart set "$VM_NAME" --cpu "$LIW_CPUS" --memory "$LIW_MEM_MB" || die "tart set failed"
start_vm

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
