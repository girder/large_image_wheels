#!/usr/bin/env python

import argparse
import hashlib
import os
import sys
import time

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
link = '<a href="%s%s#sha256=%s" download="%s">%s</a>%s%s%11d'
linknosha = '<a href="%s%s" download="%s">%s</a>%s%s%11d'


def get_sha256(path, name, verbose):
    sha256 = hashlib.sha256()
    if args.verbose >= 2:
        print(f'Getting sha256 for {name}')
    elif args.verbose >= 1:
        sys.stdout.write(f'sha256: {name[:71]}\r')
        sys.stdout.flush()
    with open(os.path.join(path, name), 'rb') as fptr:
        while True:
            data = fptr.read(1024 ** 2)
            if not len(data):
                break
            sha256.update(data)
    return sha256.hexdigest()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(
        description='Create an index.html page for wheels')
    parser.add_argument(
        'path', help='The path where index.html will be created', nargs='?',
        default='gh-pages')
    parser.add_argument(
        '-b', '--branch', '--wheel-branch',
        help='A branch to reference if a prefix is used.',
        default='wheelhouse')
    parser.add_argument(
        '-p', '--prefix',
        help='A prefix to add to links.  This defaults to None if path is '
        'anything other than gh-pages.  Otherwise, this defaults to '
        '"https://github.com/girder/large_image_wheels/raw/".')
    parser.add_argument(
        '-a', '--append', action='store_true',
        help='Modify an existing file.')
    parser.add_argument(
        '--no-sha', action='store_true',
        help='Do not include sha256 in links.')
    parser.add_argument(
        '--verbose', '-v', action='count', default=0, help='Increase verbosity')
    args = parser.parse_args()

    path = args.path or 'gh-pages'
    wpath = path
    prefix = args.prefix or ''
    if args.prefix is None and path == 'gh-pages':
        prefix = 'https://github.com/girder/large_image_wheels/raw/'
    if prefix and args.branch:
        prefix = prefix.rstrip('/') + '/' + args.branch
    if prefix:
        prefix = prefix.rstrip('/') + '/'

    wheels = [(name, name) for name in os.listdir(wpath) if name.endswith('whl')]
    if not len(wheels) and args.branch:
        wpath = args.branch
        wheels = [(name, name) for name in os.listdir(wpath) if name.endswith('whl')]

    wheels = sorted(wheels)
    maxnamelen = max(len(name) for name, url in wheels)
    if args.append:
        if args.verbose >= 2:
            print(f'Appending to {indexName}')
        existing = open(os.path.join(path, indexName)).read()
        if 'large_image_wheels' in existing:
            raise Exception('index.html has already been modified')
        existing = existing.replace('Simple Package Repository', 'large_image_wheels')
        existing = existing.replace('<body>', '<body>\n<h1>large_image_wheels</h1>')
        template = existing.replace('</body>', '<pre>\n%LINKS%\n</pre>\n</body>')
    if not args.no_sha:
        index = template.replace('%LINKS%', '\n'.join([
            link % (
                prefix, url, get_sha256(wpath, url, args.verbose), name, name,
                ' ' * (maxnamelen + 3 - len(name)),
                time.strftime('%Y-%m-%d %H:%M:%S', time.gmtime(os.path.getmtime(
                    os.path.join(wpath, name)))),
                os.path.getsize(os.path.join(wpath, name)),
            ) for name, url in wheels]))
        if args.verbose == 1:
            sys.stdout.write((' ' * 79) + '\r')
    else:
        index = template.replace('%LINKS%', '\n'.join([
            linknosha % (
                prefix, url, name, name,
                ' ' * (maxnamelen + 3 - len(name)),
                time.strftime('%Y-%m-%d %H:%M:%S', time.gmtime(os.path.getmtime(
                    os.path.join(wpath, name)))),
                os.path.getsize(os.path.join(wpath, name)),
            ) for name, url in wheels]))
    if args.verbose >= 1:
        print(f'Writing {indexName}')
    open(os.path.join(path, indexName), 'w').write(index)
