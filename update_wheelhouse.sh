#!/usr/bin/env bash

set -e

pushd gh-pages
echo 'simple503'
python3 -m simple503 -B https://github.com/girder/large_image_wheels/raw/wheelhouse ../wheelhouse .
mv *.whl* ../wheelhouse/.
sed -i 's!https://github.com/girder/large_image_wheels/raw/wheelhouse/!!g' index.html
popd
python3 make_index.py --append -v

