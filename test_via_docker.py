#!/usr/bin/env python3

import multiprocessing.pool
import os
import platform
import subprocess
import sys
import threading

containers = {
    'python:3.8-slim': [],
    'python:3.9-slim': [],
    'python:3.10-slim': [],
    'python:3.11-slim': [],
    'python:3.12-slim': [],
    'python:3.13-slim': [],
    # -- pypy
    # 'pypy:3.9': [],
    # 'pypy:3.10': [],
    # -- manylinux_2_28
    'almalinux:8 3.8': ['yum install -y python38-pip'],
    'almalinux:8 3.9': ['yum install -y python39-pip'],
    'almalinux:8 3.11': ['yum install -y python3.11-pip'],
    # 'almalinux:8 3.12': ['yum install -y python3.12-pip'],
}
if platform.machine() not in {'aarch64', 'arm64'}:
    containers.update({
        # -- centos
        # See https://github.com/molinav/docker-pyenv for some additional images
        # 'centos/python-38-centos7 3.8': [],
        # 'molinav/pyenv:3.9-centos-7': [],
        # -- opensuse
        # 'molinav/pyenv:3.8-opensuse-15.3': [],
        # 'molinav/pyenv:3.9-opensuse-15.3': [],
    })

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


def test_container(container, entry, full, subcmds=None):
    lock = entry['lock']
    result = entry['out']
    with lock:
        entry['status'] = 'started'
    if subcmds is None:
        subcmds = []
    subcmds.append('bash /test/test_script.sh')
    if full:
        subcmds.append('bash /test/li_script.sh')
    cmd = [
        'docker', 'run',
        '-v', '%s/wheels:/wheels' % os.path.dirname(os.path.realpath(__file__)),
        '-v', '%s/test:/test' % os.path.dirname(os.path.realpath(__file__)),
        '--rm', container, 'bash', '-e', '-c',
        ' && '.join(subcmds),
    ]
    # cmd += sys.argv[1:]
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
    full = len(sys.argv) > 2 and sys.argv[2] == 'full'
    if full:
        count = min(4, count)
    pool = multiprocessing.pool.ThreadPool(processes=count)
    results = []
    for container in containers:
        if len(sys.argv) > 1 and sys.argv[1] not in container:
            continue
        entry = {'out': [], 'lock': threading.Lock(), 'status': 'queued', 'container': container}
        result = pool.apply_async(
            test_container, (container.split()[0], entry, full, containers[container]))
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
#  docker run -v `pwd`/wheels:/wheels -v `pwd`/test:/test --rm -it python:3.11-slim bash
# and then enter the script commands directly, typically starting with
#  pip install pyvips large_image[sources,memcached] -f ${1:-/wheels}
