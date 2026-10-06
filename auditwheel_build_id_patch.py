"""Salt auditwheel's grafted-library hash with a per-build id.

auditwheel renames each library it grafts into a wheel by appending a hash of
the library to its name (e.g. libgeotiff.so.5.2.3 becomes
libgeotiff-687ecd1a.so.5.2.3).  That hash is computed from the pristine
library in /usr/local/lib BEFORE auditwheel rewrites the grafted copy
(soname, rpath, and the DT_NEEDED entries for the other grafted libraries).
Those rewrites change the shipped bytes, so if the pristine library is
bit-identical across two builds but any of its dependencies changed, the two
builds ship files with the same name (same suffix) but different content.
Installing wheels from both builds then mixes them, since the dynamic linker
deduplicates libraries by soname.

This script patches auditwheel to salt the hash with a per-build id
(BUILD_ID, or a timestamp if BUILD_ID is not set): wheels built together
still share grafted libraries, while wheels from different builds never
share a suffix.
"""

import glob
import os
import sys
import time

raw = os.environ.get('BUILD_ID') or 'b%d' % int(time.time())
salt = ''.join(ch for ch in raw if ch.isalnum() or ch in '-._')

paths = glob.glob(
    '/opt/_internal/pipx/venvs/auditwheel/lib/python*/site-packages/auditwheel/repair.py'
)
if len(paths) != 1:
    sys.exit('Could not find auditwheel repair.py: %r' % (paths,))
path = paths[0]

with open(path) as f:
    s = f.read()

old = 'shorthash = hashfile(f)[:8]'
new = f'shorthash = hashlib.sha256((hashfile(f) + "{salt}").encode()).hexdigest()[:8]'
if old not in s or new in s:
    sys.exit('auditwheel repair.py is not in the expected state')
s = s.replace(old, new)
s = s.replace('import itertools', 'import hashlib, itertools', 1)

with open(path, 'w') as f:
    f.write(s)

print('auditwheel library-hash salt:', salt)
