#!/usr/bin/env python

import json
import os
import requests
import sys

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

if sys.argv[1:] == ['--data']:
    GirderUrl = 'https://data.kitware.com/api/v1'
    items = requests.get(GirderUrl + '/resource/search', params={
        'mode': 'text',
        'types': json.dumps(['item']),
        'q': '"Large Image Wheels 2018-11-13"'
    }).json()['item']
    itemId = items[0]['_id']
    files = requests.get(GirderUrl + '/item/%s/files' % itemId).json()
    wheels = [(file['name'], GirderUrl + '/file/%s/download' % file['_id'])
              for file in files if 'whl' in file['exts']]
else:
    wheels = [(name, name) for name in os.listdir(path) if name.endswith('whl')]

wheels = sorted(wheels)
index = template.replace('%LINKS%', '\n'.join([
    link % (url, name, name) for name, url in wheels]))
open(os.path.join(path, indexName), 'w').write(index)
