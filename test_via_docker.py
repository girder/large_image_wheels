#!/usr/bin/env python

import os
import sys
import subprocess

containers = [
    "python:2.7",
    "python:3.5",
    "python:3.6",
    "python:3.7",
    "python:3.8",
    "centos/python-27-centos7",
    # The latest pyproj needs a newer version of python 3.5 than included in
    # the centos/python-35-centos7 docker image.
    # "centos/python-35-centos7",
    "centos/python-36-centos7",
    "centos/python-38-centos7",
]

for container in containers:
    print('---- Testing in %s ----' % container)
    cmd = [
        'docker', 'run',
        '-v', '%s/wheels:/wheels' % os.path.dirname(os.path.realpath(__file__)),
        '-v', '%s/test:/test' % os.path.dirname(os.path.realpath(__file__)),
        '--rm', container, 'bash', '-e', '/test/test_script.sh']
    cmd += sys.argv[1:]
    try:
        subprocess.check_call(cmd)
    except Exception:
        print('---- Failed in %s ----' % container)
        raise
print('Passed')

# To test manually, run a container such as
#  docker run -v `pwd`/wheels:/wheels --rm -it python:3.7 bash
# and then enter the script commands directly, typically starting with
#  pip install pyvips large_image[sources,memcached] javabridge -f ${1:-/wheels}
