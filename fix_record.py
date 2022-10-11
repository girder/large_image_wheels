#!/usr/bin/env python

# Open a wheel .dist-info RECORD file, recompute the hashes, and save it.
# Run this in the root directory of the unzipped wheel.

import base64
import hashlib
import os
import time

record_path = os.path.join(next(
    dir for dir in os.listdir('.') if dir.endswith('.dist-info')), 'RECORD')
newrecord = []
for line in open(record_path):
    parts = line.rsplit(',', 2)
    if len(parts) == 3 and os.path.exists(parts[0]) and parts[1]:
        hashval = base64.urlsafe_b64encode(hashlib.sha256(open(
            parts[0], 'rb').read()).digest()).decode('latin1').rstrip('=')
        filelen = os.path.getsize(parts[0])
        line = ','.join([parts[0], 'sha256=' + hashval, str(filelen)]) + '\n'
    newrecord.append(line)
open(record_path, 'w').write(''.join(newrecord))
epoch = int(os.environ.get('SOURCE_DATE_EPOCH', time.time()))
os.utime(record_path, (epoch, epoch))
