# large_image_wheels

manylinux wheel files for girder/large_image dependencies.

## Use

You can install from the wheels in this repository using a command like:
```
pip install libtiff openslide_python pyvips gdal mapnik -f https://manthey.github.io/large_image_wheels
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

This also makes some wheels which aren't published in pypi (pyproj isn't published for Python 3.7):
- psutil
- pyproj
- ujson

It remakes wheels that are published (these are not included in this repo):
- cffi
- Pillow

## Issues

In order to find the built libraries, this modifies how libtiff, openslide_python, and pyvips load those libraries.  The modification for libtiff is taken from a form of pylibtiff.  The other libraries are patched in place.  There is probably a better way to do this.

It could be useful to bundle executables with the Python packages so that commands like gdalinfo would be available.

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
