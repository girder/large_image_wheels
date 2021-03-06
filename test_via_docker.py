#!/usr/bin/env python

import multiprocessing.pool
import os
import sys
import subprocess
import threading

containers = [
    'python:3.6',
    'python:3.7',
    'python:3.8',
    'python:3.9',
    # The latest pyproj needs a newer version of python 3.5 than included in
    # the centos/python-35-centos7 docker image.
    # 'centos/python-35-centos7',
    'centos/python-36-centos7',
    'centos/python-38-centos7',
]


# Without parallelism, this is much simpler:
# for container in containers:
#     print('---- Testing in %s ----' % container)
#     cmd = [
#         'docker', 'run',
#         '-v', '%s/wheels:/wheels' % os.path.dirname(os.path.realpath(__file__)),
#         '-v', '%s/test:/test' % os.path.dirname(os.path.realpath(__file__)),
#         '--rm', container, 'bash', '-e', '/test/test_script.sh']
#     cmd += sys.argv[1:]
#     try:
#         subprocess.check_call(cmd)
#     except Exception:
#         print('---- Failed in %s ----' % container)
#         raise
# print('Passed')


def test_container(container, entry):
    lock = entry['lock']
    result = entry['out']
    with lock:
        entry['status'] = 'started'
    cmd = [
        'docker', 'run',
        '-v', '%s/wheels:/wheels' % os.path.dirname(os.path.realpath(__file__)),
        '-v', '%s/test:/test' % os.path.dirname(os.path.realpath(__file__)),
        '--rm', container, 'bash', '-e', '/test/test_script.sh']
    cmd += sys.argv[1:]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    while True:
        line = proc.stdout.readline()
        if not line:
            break
        with lock:
            result.append(line.decode())
    returncode = proc.wait()
    with lock:
        entry['status'] = 'passed' if not returncode else 'failed'
        if returncode:
            entry['exception'] = subprocess.CalledProcessError(returncode, cmd, ''.join(result))


if __name__ == '__main__':
    count = multiprocessing.cpu_count()
    pool = multiprocessing.pool.ThreadPool(processes=count)
    results = []
    for container in containers:
        entry = {'out': [], 'lock': threading.Lock(), 'status': 'queued', 'container': container}
        result = pool.apply_async(test_container, (container, entry))
        entry['result'] = result
        results.append(entry)
    pool.close()
    for entry in results:
        container = entry['container']
        print('---- Starting in %s ----' % container)
        while True:
            with entry['lock']:
                while len(entry['out']):
                    sys.stdout.write(entry['out'].pop(0))
                if entry['result'].ready():
                    break
            entry['result'].wait(0.1)
        if entry['status'] == 'failed':
            print('---- Failed in %s ----' % container)
            raise entry['exception']
        print('---- Passed in %s ----' % container)
    print('Passed')

# To test manually, run a container such as
#  docker run -v `pwd`/wheels:/wheels --rm -it python:3.7 bash
# and then enter the script commands directly, typically starting with
#  pip install pyvips large_image[sources,memcached] -f ${1:-/wheels}
