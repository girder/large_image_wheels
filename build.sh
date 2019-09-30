#!/usr/bin/env bash

set -e

docker pull quay.io/pypa/manylinux2010_x86_64:latest
# Use the author date (not the commit date) for SOURCE_DATE_EPOCH.  This 
# allows adding the generated wheels to an existing commit without changing the
# epoch used in the build.
docker build --force-rm -t manthey/large_image_wheels --build-arg SOURCE_DATE_EPOCH=$(git log -1 --pretty="format:%at" Dockerfile) .
mkdir -p docs
ls -al docs
# echo run -v `pwd`/docs:/opt/mount --rm --entrypoint bash manthey/large_image_wheels -c 'cp /io/wheelhouse/{GDAL,libtiff,mapnik,openslide_python,pyvips,psutil,ujson,pyproj}*many* /opt/mount/. && chown '`id -u`':'`id -g`' /opt/mount/*.whl'
docker run -v `pwd`/docs:/opt/mount --rm --entrypoint bash manthey/large_image_wheels -c 'cp /io/wheelhouse/{GDAL,libtiff,mapnik,openslide_python,pyvips,psutil,ujson,pyproj,Glymur}*many* /opt/mount/. && chown '`id -u`':'`id -g`' /opt/mount/*.whl'
python make_index.py
ls -al docs
python check_versions.py > docs/versions.txt
git diff docs/versions.txt | cat

