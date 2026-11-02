#!/usr/bin/env bash
# nightly.sh - the nightly build body: the same steps the original crontab
# line ran, verbatim, with the repo path derived from this script's
# location.  Run by macos/nightly_via_ssh.sh (which is what crontab calls),
# or by hand for testing.

. ~/.bash_profile

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR" || exit 1

(
    (./rebuild.sh && ./test_via_docker.py --jobs=4 && ./duration_summary.py girder/large_image_wheels && macos/test_via_tart.sh && (echo "large_image_wheels good: `date`" | cat - <(git diff -U0 versions.txt | grep '^[+-][^+-]')) | wall && docker image prune -f) || wall large_image_wheels ERROR: `date`
) >/tmp/liw_cron_build.txt 2>&1
