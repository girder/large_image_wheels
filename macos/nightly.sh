#!/usr/bin/env bash
# Nightly build body.  Run directly by crontab (or by hand):
#   30 3 * * * /path/to/large_image_wheels/macos/nightly.sh >>/tmp/liw_cron_build.txt 2>&1
#
# notify(): macOS wall accepts only `wall [-g group] [file]`.  It has no
# message argument (the linux form `wall <message>`), and the piped form
# (`echo msg | wall`) just printed "usage: wall [-g group] [file]" on the
# nightly host without sending anything.  Always write the message to a temp
# file and hand wall the file: that form works on every macOS wall and on
# linux.  wall writes to every terminal of this user, including ssh sessions,
# so the result surfaces wherever the user is attached.  The message is also
# echoed to stdout, which the redirect below lands in the log.

. ~/.bash_profile

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR" || exit 1

notify() {
    local tmp status
    tmp="$(mktemp /tmp/liw_wall.XXXXXX)" || return 1
    cat >"$tmp"
    wall "$tmp"
    status=$?
    cat "$tmp"
    rm -f "$tmp"
    return $status
}

(
    (./rebuild.sh && ./test_via_docker.py --jobs=4 && ./duration_summary.py girder/large_image_wheels && macos/test_via_tart.sh && (echo "large_image_wheels good: `date`" | cat - <(git diff -U0 versions.txt | grep '^[+-][^+-]')) | notify && docker image prune -f) || { { echo "large_image_wheels ERROR: `date`"; echo; echo "last 20 lines of /tmp/liw_cron_build.txt:"; tail -20 /tmp/liw_cron_build.txt; } | notify; }
) >/tmp/liw_cron_build.txt 2>&1
