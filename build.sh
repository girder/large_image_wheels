#!/usr/bin/env bash

set -e

docker pull quay.io/pypa/manylinux2014_x86_64:latest
# Use the author date (not the commit date) for SOURCE_DATE_EPOCH.  This
# allows adding the generated wheels to an existing commit without changing the
# epoch used in the build.
docker build --force-rm -t girder/large_image_wheels --build-arg SOURCE_DATE_EPOCH=$(git log -1 --pretty="format:%at" Dockerfile) --build-arg PYPY=false .
# docker build --force-rm -t girder/large_image_wheels --build-arg SOURCE_DATE_EPOCH=$(git log -1 --pretty="format:%at" Dockerfile) .
mkdir -p wheels
ls -al wheels
rm -f wheels/*many*.whl
docker run -v `pwd`/wheels:/opt/mount --rm --entrypoint bash girder/large_image_wheels -c 'cp --preserve=timestamps /io/wheelhouse/{pylibtiff,Glymur,pyproj,GDAL,mapnik,openslide_python,pyvips,pylibmc,python_javabridge}*-cp*many* /opt/mount/. && chown '`id -u`':'`id -g`' /opt/mount/*.whl'
rm -f wheels/*none*.whl
cp --preserve=timestamps wheels/*.whl wheelhouse/.
python3 make_index.py
python3 make_index.py wheels
ls -al wheels
# python3 check_versions.py > versions.txt
git diff versions.txt | cat

