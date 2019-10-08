#!/usr/bin/env python

import os

path = 'docs'
indexName = 'index.html'
template = """<html>
<head><title>large_image_wheels</title></head>
<body>
<h1>large_image_wheels</h1>
<pre>
%LINKS%
</pre>
</body>
"""
link = '<a href="%s" download="%s">%s</a>'

wheels = [(name, name) for name in os.listdir(path) if name.endswith('whl')]

wheels = sorted(wheels)
index = template.replace('%LINKS%', '\n'.join([
    link % (url, name, name) for name, url in wheels]))
open(os.path.join(path, indexName), 'w').write(index)
