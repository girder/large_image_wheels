#!/usr/bin/env bash

set -e

python3 -u check_versions.py > versions.txt || (git diff versions.txt && false)
git diff versions.txt | cat || true
. build.sh

