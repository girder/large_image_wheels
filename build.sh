#!/usr/bin/env bash
# This attempts to detect the local architecture and build for it.  Otherwise,
# override by passing an architecture values (x86_64, aarch64, arm64). 
# aarch64 and arm64 are synonyms.

set -e

export makeindex=true
case "$1" in
    x86_64)
        export baseimage=quay.io/pypa/manylinux2014_x86_64:sha256:`getver.py manylinux2014_x86_64`
        ;;
    aarch64 | arm64)
        export baseimage=quay.io/pypa/manylinux_2_28_aarch64:sha256:`getver.py manylinux_2_28_aarch64`
        export makeindex=false
        ;;
    *)
        if [ $(arch) == "arm64" ] || [ $(arch) == "aarch64" ]; then
            export baseimage=quay.io/pypa/manylinux_2_28_aarch64
            export makeindex=false
        else
            export baseimage=quay.io/pypa/manylinux2014_x86_64
        fi
        ;;
esac
# docker pull "${baseimage}":latest
## for testing, build locally via
# docker build --force-rm --build-arg PYPY=false --build-arg baseimage=quay.io/pypa/manylinux2014_x86_64 .
docker build --force-rm -t girder/large_image_wheels --build-arg PYPY=false --build-arg baseimage=${baseimage} .

mkdir -p wheels
ls -al wheels
rm -f wheels/*.whl
docker run -v `pwd`/wheels:/opt/mount --rm --entrypoint bash girder/large_image_wheels -c 'cp --preserve=timestamps /io/wheelhouse/{pylibtiff,Glymur,GDAL,mapnik,openslide_python,pyvips,pylibmc,python_javabridge}*many* /opt/mount/. && cp --preserve=timestamps /io/wheelhouse/*bioformats*.whl /opt/mount/. && chown '`id -u`':'`id -g`' /opt/mount/*.whl'
# rm -f wheels/*none*.whl
# cp --preserve=timestamps wheels/*.whl wheelhouse/.
if [ "$makeindex" == "true" ]; then
  python3 copy_changed.py
  pushd gh-pages
  python3 -m simple503 -B https://github.com/girder/large_image_wheels/raw/wheelhouse ../wheelhouse .
  mv *.whl* ../wheelhouse/.
  sed -i 's!https://github.com/girder/large_image_wheels/raw/wheelhouse/!!g' index.html
  popd
  python3 make_index.py --append
fi
python3 make_index.py wheels
ls -al wheels
# python3 check_versions.py > versions.txt
git diff versions.txt | cat

