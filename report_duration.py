#!/usr/bin/env python3

# Pass the large_image_wheels build log.txt to stdin:
# docker run --rm girder/large_image_wheels:latest cat log.txt | ./build_duration.py

import subprocess
import sys

import dateutil.parser

if len(sys.argv) == 1:
    record = sys.stdin.readlines()
else:
    id = sys.argv[1]
    if id == 'recent':
        id = subprocess.check_output(
            ['docker', 'images', '-q'], encoding='utf8').split('\n')[0].strip()
    record = subprocess.check_output(
        ['docker', 'run', '--rm', id, 'cat', 'log.txt'], encoding='utf8').split('\n')

starts = {}
totals = {}
for line in record:
    key = line[28:].strip()
    if not len(key):
        continue
    date = dateutil.parser.parse(line[:28])
    if key not in starts:
        starts[key] = date
    else:
        totals[key] = totals.get(key, 0) + (date - starts[key]).total_seconds()
        del starts[key]
durations = [(val, key) for key, val in totals.items()]
durations.sort()
for _, key in durations:
    print('%4.0f %s' % (totals[key], key))
print('%4.0f %s' % (sum(totals.values()), 'total'))
