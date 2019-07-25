#!/usr/bin/env python

import os
import subprocess

containers = [
    "python:2.7",
    # "python:3.4",
    "python:3.5",
    "python:3.6",
    "python:3.7",
    "centos/python-27-centos7",
    # "centos/python-34-centos7",
    "centos/python-35-centos7",
    "centos/python-36-centos7",
]

for container in containers:
    print('---- Testing in %s ----' % container)
    subprocess.check_call([
        'docker', 'run',
        '-v', '%s/docs:/wheels' % os.path.dirname(os.path.realpath(__file__)),
        '-v', '%s/test:/test' % os.path.dirname(os.path.realpath(__file__)),
        '--rm', container, 'bash', '-e', '/test/test_script.sh'])

# To test manually, run a container such as
#  docker run -v `pwd`/docs:/wheels --rm -it python:2.7 bash
# and then enter the script commands directly
