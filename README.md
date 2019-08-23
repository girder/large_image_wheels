# large_image_wheels

manylinux2010 wheel files for girder/large_image dependencies.

## Use

You can install from the wheels in this repository using a command like:
```
pip install libtiff openslide_python pyvips gdal mapnik pyproj -f https://manthey.github.io/large_image_wheels
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
- GDAL
- libtiff
- mapnik
- openslide_python
- pyvips

Some wheels are built from master and therefore possibly newer than what is on pypi:
- pyproj

This also makes some wheels which aren't published in pypi:
- psutil
- ujson

## Extras

Various related executables are bundled with the Python packages.  These are added as package data in a `bin` directory within the main package.  They are not added to the system path.  For instance, `gdalinfo` from the `GDAL` package, is located in the Python site-packages `osgeo/bin` directory.  The appropriate directory can be gleaned from Python as part of a bash command, e.g., `` `python -c 'import os,sys,osgeo;sys.stdout.write(os.path.dirname(osgeo.__file__))'`/bin/gdalinfo --version``.

## Issues

In order to find the built libraries, this modifies how libtiff, openslide_python, and pyvips load those libraries.  The modification for libtiff is taken from a form of pylibtiff.  The other libraries are patched in place.  There is probably a better way to do this.

## Example Use

This makes is more convenient to use large_image.  For instance, you can create a Jupyter Notebook with large_image.

```
docker run --rm -p 8888:8888 jupyter/minimal-notebook bash -c 'pip install git+git://github.com/girder/large_image.git#egg=large_image[openslide,mapnik] -f https://manthey.github.io/large_image_wheels matplotlib && start.sh jupyter notebook --NotebookApp.token="" --ip=0.0.0.0'
```

In the Jupyter interface, create a new notebook.  In the first cell run:
```
import large_image
import requests
import matplotlib.pyplot as plt
wsi_url = 'https://data.kitware.com/api/v1/file/5899dd6d8d777f07219fcb23/download'
wsi_path = 'TCGA-02-0010-01Z-00-DX4.07de2e55-a8fe-40ee-9e98-bcb78050b9f7.svs'
open(wsi_path, 'wb').write(requests.get(wsi_url, allow_redirects=True).content)
ts = large_image.getTileSource(wsi_path)
tile_info = ts.getSingleTile(
    tile_size=dict(width=1000, height=1000),
    scale=dict(magnification=20),
    tile_position=1000
)
```
And in the second cell run:
```
plt.imshow(tile_info['tile'])
```

## Rationale

It is an inconvenience to have to add `--find-links https://manthey.github.io/large_image_wheels` to pip install commands to use these wheels.  There are alternatives: (a) convince upstream repositories to publish wheels, or (b) publish these under unique names (e.g., large_image_dependency_gdal).  None of these are perfect solutions.  

Using `--find-links` requires modifying pip install commands.  Further, if a newer non-wheel version of a package is published on pypi, it will be used in favor of the wheel unless the explicit version is used.  Since this repository won't maintain old versions, this means that the wheels must be rebuilt as soon as new versions are released.

It isn't practical to produce wheels for some upstream packages.  For instance, GDAL can be compiled with optional components that require licensing.  A publicly published wheel can't contain such components, and, therefore, it makes sense for the package on pypi to expect that the library has been installed separately from the python module.

If these wheels were published under alternate names, they could be published to pypi.  However, this would require a wheel for every supported OS or have conditionals in downstream packages' setup.py install_requires.  Further, it would preclude using custom-built libraries (such as GDAL with licensed additions).

Using `--find-links` seems like the best choice of these options.  Downstream packages can list the expected modules in `install_requires`.  Installation doesn't become any harder for platforms without wheels, and custom-built libraries are supported.

## Future Work

- More optional libraries

  Several packages (GDAL, ImageMagick, vips, and probably others) could have additional libraries added to the built wheels.  As time permits, those libraries that are appropriately licensed may be gradually added.  See the Dockerfile for comments on what else could be built.  If there is a specific need for a library that hasn't yet been included, please create an issue for it.

- More executables

  A variety of executables are bundled with the wheels in appropriate `bin` directories.  There are additional tools that could be added (for instance, OpenJPEG has some executables that could be added to the OpenSlide or the vips wheel).  If there is a specific need for an executable that hasn't been included, please create an issue for it.

- Automate version checks

  When any dependent library changes, the wheels could be rebuilt.  Some of this could be more automated.  Some versions don't work together (Boost 1.70/1.71 with mapnik, for instance), so it can't be fully automatic.

- Automate releases

  The wheels should be published from a successful CI run rather than from a user commit.
