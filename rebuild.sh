#!/usr/bin/env bash

set -e

python3 check_versions.py > versions.txt
git diff versions.txt | cat
. build.sh

