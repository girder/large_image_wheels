#!/usr/bin/env python3

import argparse
import multiprocessing.pool
import os
import platform
import subprocess
import sys
import threading

containers = {
    'python:3.8-slim': {},
    'python:3.9-slim': {},
    'python:3.10-slim': {},
    'python:3.11-slim': {},
    'python:3.12-slim': {},
    'python:3.13-slim': {},
    'liw/python:3.13': {
        'skip': True,
        'build': {'base': 'debian:stable-slim', 'python': '3.13',
                  'packages': 'build-essential libffi-dev'}},
    # Currently, we can't run our expected tests in freethreaded python because
    # pyproj and lxml don't build without more work
    'liw/python:3.13t': {
        'skip': True,
        'build': {'base': 'debian:stable-slim', 'python': '3.13t',
                  'packages': 'build-essential libffi-dev libproj-dev '
                  'proj-bin libxml2-dev libxmlsec1-dev'},
    },
    # -- pypy
    'pypy:3.9': {'skip': True},
    'pypy:3.10': {'skip': True},
    # -- manylinux_2_28
    'almalinux:8 3.8': {'subcmds': ['yum install -y python38-pip']},
    'almalinux:8 3.9': {'subcmds': ['yum install -y python39-pip']},
    'liw/almapython:3.10': {'build': {'base': 'almalinux:8', 'python': '3.10'}},
    'almalinux:8 3.11': {'subcmds': ['yum install -y python3.11-pip']},
    # 'almalinux:8 3.12': {'subcmds': ['yum install -y python3.12-pip']},
    'liw/almapython:3.12': {'build': {'base': 'almalinux:8', 'python': '3.12'}},
    'liw/almapython:3.13': {'build': {'base': 'almalinux:8', 'python': '3.13'}},
}
if platform.machine() not in {'aarch64', 'arm64'}:
    containers.update({
        # -- centos
        # See https://github.com/molinav/docker-pyenv for some additional images
        # 'centos/python-38-centos7 3.8': {},
        # 'molinav/pyenv:3.9-centos-7': {},
        # -- opensuse
        # 'molinav/pyenv:3.8-opensuse-15.3': {},
        # 'molinav/pyenv:3.9-opensuse-15.3': {},
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


def test_container(container, entry, full, options=None):
    if options is None:
        options = {}
    subcmds = options.get('subcmds')
    lock = entry['lock']
    result = entry['out']
    with lock:
        entry['status'] = 'started'
    cmds = []
    if 'build' in options:
        buildcmd = [
            'docker', 'build',
            '--build-arg', f'baseimage={options["build"]["base"]}',
            '--build-arg', f'PYTHON_VERSION={options["build"]["python"]}',
            '--build-arg', f'packages={options["build"].get("packages", "")}',
            '-f', 'test/python.Dockerfile', '-t', entry['container'], 'test']
        cmds.append(buildcmd)
    if subcmds is None:
        subcmds = []
    subcmds.append('bash /test/test_script.sh')
    if full:
        subcmds.append('bash /test/li_script.sh')
    maincmd = [
        'docker', 'run',
        '-v', '%s/wheels:/wheels' % os.path.dirname(os.path.realpath(__file__)),
        '-v', '%s/test:/test' % os.path.dirname(os.path.realpath(__file__)),
        '--rm', container, 'bash', '-e', '-c',
        ' && '.join(subcmds),
    ]
    # maincmd += sys.argv[1:]
    cmds.append(maincmd)
    for cmd in cmds:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        while True:
            line = proc.stdout.readline()
            if not line:
                break
            with lock:
                result.append(line.decode())
        returncode = proc.wait()
        if returncode:
            break
    with lock:
        entry['status'] = 'passed' if not returncode else 'failed'
        if returncode:
            entry['exception'] = subprocess.CalledProcessError(returncode, cmd, ''.join(result))


if __name__ == '__main__':  # noqa
    parser = argparse.ArgumentParser(
        description='Test large image wheels in various combinations of '
        'python versions and operating systems via docker.')
    parser.add_argument(
        'spec', nargs='?',
        help='Only run versions that include this substring')
    parser.add_argument(
        '--jobs', '-j', type=int, help='Number of concurrent jobs to run.  '
        'The maximum number of jobs will always be limited to smaller of this '
        'and the number of cpus.')
    parser.add_argument(
        '--full', action='store_true',
        help='Run the large_image tox tests as well.')
    parser.add_argument(
        '--dry-run', '-n', action='store_true',
        help='Just report which tests will be run.')
    parser.add_argument(
        '--only', action='store_true',
        help='Only run tests that exactly match the spec.')
    opts = parser.parse_args()
    count = multiprocessing.cpu_count()
    if opts.jobs:
        count = max(1, min(opts.jobs if opts.jobs > 1 else count + opts.jobs, count))
    pool = multiprocessing.pool.ThreadPool(processes=count)
    results = []
    for container in containers:
        if opts.spec and opts.spec not in container:
            continue
        if opts.only and opts.spec and opts.spec != container:
            continue
        if containers[container].get('skip') and (not opts.spec or not opts.only):
            continue
        entry = {'out': [], 'lock': threading.Lock(), 'status': 'queued', 'container': container}
        if opts.dry_run:
            result = 'test'
        else:
            result = pool.apply_async(
                test_container, (container.split()[0], entry, opts.full, containers[container]))
        entry['result'] = result
        results.append(entry)
    pool.close()
    for entry in results:
        container = entry['container']
        if opts.dry_run:
            print(container)
            continue
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
    if not opts.dry_run:
        print('Passed')

# To test manually, run a container such as
#  docker run -v `pwd`/wheels:/wheels -v `pwd`/test:/test --rm -it python:3.11-slim bash
# and then enter the script commands directly, typically starting with
#  pip install pyvips large_image[sources,memcached] -f ${1:-/wheels}
