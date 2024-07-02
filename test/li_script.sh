#!/usr/bin/env bash
# set -e

export CPL_DEBUG=ON
export OGR_CT_DEBUG=ON

. /etc/profile || true

if git --version; then true; else
  if apt-get --help; then
    apt-get update
    apt-get install -y git
  elif yum --help; then
    yum install -y git
  elif zypper --help; then
    zypper install -y git
  fi
fi

pip install tox

git clone https://github.com/girder/large_image.git

cd large_image

sed -i 's/https:\/\/girder.github.io\/large_image_wheels/\/wheels/g' tox.ini

tox -e docs,flake8
tox -e core-py38,core-py39,core-py310,core-py311,core-py312 -- -k 'not memcached'

set +e
