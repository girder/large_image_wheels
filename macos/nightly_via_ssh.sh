#!/usr/bin/env bash
# nightly_via_ssh.sh - the crontab entry for the nightly build, wrapped so
# that the work runs inside an ssh login session.
#
# The tart pipeline works from an ssh login (a background launchd session
# spawned under the user's launchd domain) but has never worked directly
# from a cron job, whose session differs in ancestry, environment
# sanitization, and permission attribution in ways macOS does not
# document.  Rather than chase session internals, this wrapper makes cron
# behave like the proven case: cron only triggers, and the nightly body
# (macos/nightly.sh) runs over ssh to localhost -- the same host, in the
# session type every hand run has used.  Authentication uses the dedicated
# passphrase-less wheel-VM key (the one macos/tart_build.sh generates), so
# no ssh-agent is needed in cron's session.
#
# One-time setup:
#   cat ~/.large_image_wheels_tart/ssh/liw_wheels_ed25519.pub \
#       >> ~/.ssh/authorized_keys
#   chmod 600 ~/.ssh/authorized_keys
# Remote Login must be enabled (System Settings > General > Sharing), as
# it already is for anyone who sshes into this machine.
#
# Crontab entry (replaces the old inlined command):
#   30 3 * * * /Users/<you>/<path>/large_image_wheels/macos/nightly_via_ssh.sh \
#       >>/tmp/liw_cron_build.txt 2>&1
#
# The inner body writes its own log to /tmp/liw_cron_build.txt; the outer
# append captures ssh-level failures (e.g. sshd disabled) that would
# otherwise be silent.

set -u

LIW_SSH_DIR="$HOME/.large_image_wheels_tart/ssh"
KEY="$LIW_SSH_DIR/liw_wheels_ed25519"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Fail loudly, before cron nights are silently lost, if the one-time setup
# has not been done: the key must exist (tart_build.sh creates it on first
# run -- do one interactive build first if it is missing) and its public
# half must be trusted for localhost logins.
if [ ! -f "$KEY" ]; then
    echo "error: $KEY does not exist; run macos/tart_build.sh once to create it" >&2
    exit 1
fi
if ! grep -qs -f "$KEY.pub" "$HOME/.ssh/authorized_keys"; then
    echo "error: $KEY.pub is not in ~/.ssh/authorized_keys; see the setup" \
        "steps in this script's header" >&2
    exit 1
fi

exec ssh \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile="$LIW_SSH_DIR/known_hosts" \
    -o ConnectTimeout=30 \
    -i "$KEY" \
    localhost "bash -l '$REPO_DIR/macos/nightly.sh'"
