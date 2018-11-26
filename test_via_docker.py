#!/usr/bin/env python

import os
import subprocess

script = """
python --version && \\
pip install --upgrade pip && \\
# pip install libtiff openslide_python pyvips GDAL mapnik -f /wheels && \\
pip install pyvips \\
  git+git://github.com/girder/large_image.git@master#egg=large_image[openslide,mapnik] \\
  -f /wheels && \\
python -c 'import libtiff, openslide, pyvips, gdal, mapnik' && \\
curl -L -o sample.svs \\
  https://data.kitware.com/api/v1/file/5be43d9c8d777f217991e1c2/download && \\
python -c 'import large_image,pprint;ts = large_image.getTileSource( \\
  "sample.svs");pprint.pprint(ts.getMetadata());ti = ts.getSingleTile( \\
  tile_size=dict(width=1000,height=1000), \\
  scale=dict(magnification=20),tile_position=1000);pprint.pprint(ti);print( \\
  ti["tile"].size);print(ti["tile"][:4,:4])' && \\
curl -L -o sample.tif \\
  https://data.kitware.com/api/v1/file/5be43e398d777f217991e21f/download && \\
python -c 'import large_image,pprint;ts = large_image.getTileSource( \\
  "sample.tif");pprint.pprint(ts.getMetadata());ti = ts.getSingleTile( \\
  tile_size=dict(width=1000,height=1000), \\
  scale=dict(magnification=20),tile_position=100);pprint.pprint(ti);print( \\
  ti["tile"].size);print(ti["tile"][:4,:4])' && \\
curl -L -o sample_jp2.tif \\
  https://data.kitware.com/api/v1/file/5be348568d777f21798fa1d1/download && \\
python -c 'import pyvips;pyvips.Image.new_from_file( \\
  "sample_jp2.tif").write_to_file("sample_jp2_out.tif",compression="jpeg", \\
  Q=90,tile=True,tile_width=256,tile_height=256,pyramid=True, \\
  bigtiff=True);import large_image,pprint;ts = large_image.getTileSource( \\
  "sample_jp2_out.tif");pprint.pprint(ts.getMetadata() \\
  );ti = ts.getSingleTile(tile_size=dict(width=1000, \\
  height=1000),tile_position=100);pprint.pprint(ti);print( \\
  ti["tile"].size);print(ti["tile"][:4,:4])' && \\
curl -L -o landcover.tif \\
  https://data.kitware.com/api/v1/file/5be43e848d777f217991e270/download && \\
python -c 'import gdal,pprint;d = gdal.Open("landcover.tif");pprint.pprint({ \\
  "RasterXSize": d.RasterXSize, \\
  "RasterYSize": d.RasterYSize, \\
  "GetProjection": d.GetProjection(), \\
  "GetGeoTransform": d.GetGeoTransform(), \\
  "RasterCount": d.RasterCount, \\
  "band.GetStatistics": d.GetRasterBand(1).GetStatistics(True, True), \\
  "band.GetNoDataValue": d.GetRasterBand(1).GetNoDataValue(), \\
  "band.GetScale": d.GetRasterBand(1).GetScale(), \\
  "band.GetOffset": d.GetRasterBand(1).GetOffset(), \\
  "band.GetUnitType": d.GetRasterBand(1).GetUnitType(), \\
  "band.GetCategoryNames": d.GetRasterBand(1).GetCategoryNames(), \\
  "band.GetColorInterpretation": d.GetRasterBand(1).GetColorInterpretation(), \\
  "band.GetColorTable().GetCount": d.GetRasterBand(1).GetColorTable().GetCount(), \\
  "band.GetColorTable().GetColorEntry(0)": d.GetRasterBand(1).GetColorTable().GetColorEntry(0), \\
  "band.GetColorTable().GetColorEntry(1)": d.GetRasterBand(1).GetColorTable().GetColorEntry(1), \\
  })' && \\
python -c 'import large_image,pprint;ts = large_image.getTileSource( \\
  "landcover.tif");pprint.pprint(ts.getMetadata() \\
  );ti = ts.getSingleTile(tile_size=dict(width=1000, \\
  height=1000),tile_position=200);pprint.pprint(ti);print( \\
  ti["tile"].size);print(ti["tile"][:4,:4])' && \\
python -c 'import large_image,pprint;ts = large_image.getTileSource( \\
  "landcover.tif", projection="EPSG:3857");pprint.pprint(ts.getMetadata() \\
  );ti = ts.getSingleTile(tile_size=dict(width=1000, \\
  height=1000),tile_position=100);pprint.pprint(ti);print( \\
  ti["tile"].size);print(ti["tile"][:4,:4]);tile = ts.getTile(1178,1507,12 \\
  );pprint.pprint(repr(tile[1400:1440]))' && \\
true"""

containers = [
    "python:2.7",
    "python:3.4",
    "python:3.5",
    "python:3.6",
    "python:3.7",
    "centos/python-27-centos7",
    "centos/python-34-centos7",
    "centos/python-35-centos7",
    "centos/python-36-centos7",
]

for container in containers:
    print('---- Testing in %s ----' % container)
    subprocess.check_call([
        'docker', 'run', '-v',
        '%s/docs:/wheels' % os.path.dirname(os.path.realpath(__file__)),
        '--rm', container, 'sh', '-c', script])

# To test manually, run a container such as
#  docker run -v `pwd`/docs:/wheels --rm -it python:2.7 bash
# and then enter the script commands directly
