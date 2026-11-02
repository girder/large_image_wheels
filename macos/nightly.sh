#!/usr/bin/env bash

. ~/.bash_profile

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR" || exit 1

(
    (./rebuild.sh && ./test_via_docker.py --jobs=4 && ./duration_summary.py girder/large_image_wheels && macos/test_via_tart.sh && (echo "large_image_wheels good: `date`" | cat - <(git diff -U0 versions.txt | grep '^[+-][^+-]')) | wall && docker image prune -f) || echo "large_image_wheels ERROR: `date`" | wall
) >/tmp/liw_cron_build.txt 2>&1
