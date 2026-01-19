#!/usr/bin/env python3
import os
import shutil
import subprocess
import sys
import zipfile

# Copy any wheels in the ./wheels directory to the ./wheelhouse directory IF
# - the file doesn't exist in the destintation
# For GDAL only IF
# - the zip files contain a different number of internal file entries
# - the internal file entries differ in name
# - any of the CRC checksums of the internal file entries differ EXCEPT for
#   the records for RECORD and WHEEL.  These can change when only the version
#   of setuptools changes, which isn't a significant change.
for name in sorted(os.listdir('wheels')):  # noqa
    if not name.endswith('.whl'):
        continue
    committed = set(subprocess.check_output(
        ['git', '-C', 'wheelhouse', 'ls-tree', '-r', 'HEAD', '--name-only']
    ).decode().strip().split('\n'))
    if 'GDAL' in name:
        current_ver = [line.strip().split()[1] for line in open(
            'versions.txt').readlines() if line.startswith('gdal ')][0]
        if f'-{current_ver}.' not in name:
            continue
    if 'mapnik' in name:
        current_ver = [line.strip().split()[1] for line in open(
            'versions.txt').readlines() if line.startswith('mapnik-release')][0]
        if f'-{current_ver}.' not in name:
            continue
    if name in os.listdir('wheelhouse'):
        if name in committed:
            continue
        z1 = zipfile.ZipFile(os.path.join('wheels', name))
        z2 = zipfile.ZipFile(os.path.join('wheelhouse', name))
        if len(z1.infolist()) == len(z2.infolist()):
            for entry in z1.infolist():
                try:
                    if entry.CRC != z2.getinfo(entry.filename).CRC:
                        if entry.filename.rsplit('/')[-1] not in {'WHEEL', 'RECORD'}:
                            print('differ', entry.filename)
                            break
                except Exception:
                    print('new file', entry.filename)
                    break
            else:
                continue
        else:
            print('file count')
    else:
        print('new wheel')
    print('Copy', name)
    if len(sys.argv) <= 1:
        shutil.copy2(os.path.join('wheels', name), os.path.join('wheelhouse', name))
