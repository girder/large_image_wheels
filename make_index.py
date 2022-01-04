#!/usr/bin/env python

import hashlib
import os
import sys
import time

path = 'gh-pages' if len(sys.argv) == 1 else sys.argv[1]
indexName = 'index.html'
template = """<!DOCTYPE html>
<html>
<head><title>large_image_wheels</title></head>
<body>
<h1>large_image_wheels</h1>
<pre>
%LINKS%
</pre>
</body>
"""
link = '<a href="%s#sha256=%s" download="%s">%s</a>%s%s%11d'


def get_sha256(name):
    sha256 = hashlib.sha256()
    with open(os.path.join(path, name), 'rb') as fptr:
        while True:
            data = fptr.read(1024 ** 2)
            if not len(data):
                break
            sha256.update(data)
    return sha256.hexdigest()


wheels = [(name, name) for name in os.listdir(path) if name.endswith('whl')]

wheels = sorted(wheels)
maxnamelen = max(len(name) for name, url in wheels)
index = template.replace('%LINKS%', '\n'.join([
    link % (
        url, get_sha256(url), name, name, ' ' * (maxnamelen + 3 - len(name)),
        time.strftime('%Y-%m-%d %H:%M:%S', time.gmtime(os.path.getmtime(
            os.path.join(path, name)))),
        os.path.getsize(os.path.join(path, name)),
    ) for name, url in wheels]))
open(os.path.join(path, indexName), 'w').write(index)
