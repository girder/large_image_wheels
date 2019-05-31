#!/usr/bin/env bash

set -e

docker build --force-rm -t manthey/large_image_wheels .
mkdir -p docs
ls -al docs
# echo run -v `pwd`/docs:/opt/mount --rm --entrypoint bash manthey/large_image_wheels -c 'cp /io/wheelhouse/{GDAL,libtiff,mapnik,openslide_python,pyvips,psutil,ujson,pyproj}*many* /opt/mount/. && chown '`id -u`':'`id -g`' /opt/mount/*.whl'
docker run -v `pwd`/docs:/opt/mount --rm --entrypoint bash manthey/large_image_wheels -c 'cp /io/wheelhouse/{GDAL,libtiff,mapnik,openslide_python,pyvips,psutil,ujson,pyproj}*many* /opt/mount/. && chown '`id -u`':'`id -g`' /opt/mount/*.whl'
python make_index.py
ls -al docs

