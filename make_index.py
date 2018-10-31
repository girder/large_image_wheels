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
link = '<a href="%s">%s</a>'

wheels = sorted([name for name in os.listdir(path) if name.endswith('whl')])
index = template.replace('%LINKS%', '\n'.join([link % (name, name) for name in wheels]))
open(os.path.join(path, indexName), 'w').write(index)
