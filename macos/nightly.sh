#!/usr/bin/env bash
# nightly.sh - the nightly wheel build, as cron runs it.
#
# The tart pipeline works from an ssh login session but has never worked
# directly from a cron job, whose launchd session differs in undocumented
# ways (ancestry, environment sanitization, permission attribution).  So
# this script -- the one the crontab line invokes -- only triggers: it
# re-runs its body over ssh to localhost, so the build executes in an ssh
# login session, the session type every hand run uses.  Authentication is
# the dedicated passphrase-less wheel-VM key (the one
# macos/tart_build.sh generates), so no ssh-agent is needed at night.
# Hand runs should also go through this script, so that cron and hand
# runs are the same code path.
#
# One-time setup:
#   cat ~/.large_image_wheels_tart/ssh/liw_wheels_ed25519.pub \
#       >> ~/.ssh/authorized_keys
#   chmod 600 ~/.ssh/authorized_keys
# Remote Login must be enabled (it already is on any machine that accepts
# ssh).
#
# Crontab entry:
#   30 3 * * * /path/to/large_image_wheels/macos/nightly.sh \
#       >>/tmp/liw_cron_build.txt 2>&1
#
# The body writes its own log to /tmp/liw_cron_build.txt; the outer
# append captures ssh-level failures (e.g. sshd disabled) that would
# otherwise be silent.  The heredoc delimiter is quoted, so the body
# below is exactly what the remote bash executes, with nothing expanded
# locally.

set -u

LIW_SSH_DIR="$HOME/.large_image_wheels_tart/ssh"
KEY="$LIW_SSH_DIR/liw_wheels_ed25519"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Fail loudly, before cron nights are silently lost, if the one-time
# setup has not been done: the key must exist (tart_build.sh creates it
# on first run -- do one interactive build first if it is missing) and
# its public half must be trusted for localhost logins.
if [ ! -f "$KEY" ]; then
    echo "error: $KEY does not exist; run macos/tart_build.sh once to create it" >&2
    exit 1
fi
if ! grep -qFs -f "$KEY.pub" "$HOME/.ssh/authorized_keys"; then
    echo "error: $KEY.pub is not in ~/.ssh/authorized_keys; see the" \
        "setup steps in this script's header" >&2
    exit 1
fi

exec ssh \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile="$LIW_SSH_DIR/known_hosts" \
    -o ConnectTimeout=30 \
    -i "$KEY" \
    localhost "cd '$REPO_DIR' && exec bash -s" <<'NIGHTLY'
# The old crontab body, verbatim except that it runs over ssh and the
# repo directory is cd'd into by the ssh command above.
. ~/.bash_profile
(
    (./rebuild.sh && ./test_via_docker.py --jobs=4 && ./duration_summary.py girder/large_image_wheels && macos/test_via_tart.sh && (echo "large_image_wheels good: `date`" | cat - <(git diff -U0 versions.txt | grep '^[+-][^+-]')) | wall && docker image prune -f) || wall large_image_wheels ERROR: `date`
) >/tmp/liw_cron_build.txt 2>&1
NIGHTLY
