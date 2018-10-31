# large_image_wheels

manylinux wheel files for girder/large_image dependencies.

## Use

You can install from the wheels in this repository using a command like:
```
    pip install libtiff openslide_python pyvips -f https://manthey.github.io/large_image_wheels
```

## Building

The wheels are all generated with the accompanying Dockerfile.

Building the wheels:
```
    docker build --force-rm -t manthey/large_image_wheels .
```

To extract the wheel files from the docker image:
```
    mkdir -p wheels
    docker run -v wheels:/opt/mount --rm --entrypoint bash manthey/large_image_wheels -c 'cp /io/wheelhouse/*many* /opt/mount/.'
```

## Results

This makes wheels for the main libraries:
- libtiff
- openslide_python
- pyvips

This also makes some wheels which aren't published in pypi:
- psutil
- ujson

It remakes wheels that are published:
- cffi
- numpy
- Pillow

## Issues

In order to find the built libraries, this modifies how libtiff, openslide_python, and pyvips load those libraries.  The modification for libtiff is taken from a form of pylibtiff.  The other libraries are patched in place.  There is probably a better way to do this.

## Future Work

It would be nice to extend this to build GDAL and Mapnik.
