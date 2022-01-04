#!/usr/bin/env python
# getver.py <package> [<last component:all> [<seperator:.>
#   [<output seperator:seperator> [<first component:0>]]]]

import os
import sys

path = 'versions.txt'
if not os.path.exists(path):
    path = '/build/versions.txt'
versions = {
    line.split(' ', 1)[0]: line.split(' ', 1)[1].strip()
    for line in open(path).readlines()}
ver = versions[sys.argv[1]]
if len(sys.argv) > 2:
    sep = sys.argv[3] if len(sys.argv) > 3 else '.'
    sep2 = sys.argv[4] if len(sys.argv) > 4 else sep
    ver = sep2.join(ver.split(sep)[
        int(sys.argv[5]) if len(sys.argv) > 5 else 0:int(sys.argv[2])])
sys.stdout.write(ver)
