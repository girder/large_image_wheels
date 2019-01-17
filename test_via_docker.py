#!/usr/bin/env python

import os
import subprocess

noscript = """
python --version && \\
pip install --upgrade pip && \\
pip install pyvips \\
  -f /wheels && \\
python -c 'import pyvips;print(pyvips)' && \\
true"""
script = """
python --version && \\
pip install --upgrade pip && \\
# echo 'Test installing all libraries from wheels' && \\
# pip install libtiff openslide_python pyvips GDAL mapnik -f /wheels && \\
echo 'Test installing pyvips and other dependencies from wheels via large_image' && \\
pip install pyvips \\
  git+git://github.com/girder/large_image.git@master#egg=large_image[openslide,mapnik] \\
  -f /wheels && \\
echo 'Test basic import of libtiff' && \\
python -c 'import libtiff' && \\
echo 'Test basic import of openslide' && \\
python -c 'import openslide' && \\
echo 'Test basic import of pyvips' && \\
python -c 'import pyvips' && \\
echo 'Test basic import of gdal' && \\
python -c 'import gdal' && \\
echo 'Test basic import of mapnik' && \\
python -c 'import mapnik' && \\
echo 'Test basic imports of all wheels' && \\
python -c 'import libtiff, openslide, pyvips, gdal, mapnik' && \\
echo 'Download an openslide file' && \\
curl -L -o sample.svs \\
  https://data.kitware.com/api/v1/file/5be43d9c8d777f217991e1c2/download && \\
echo 'Use large_image to read an openslide file' && \\
python -c 'import large_image,pprint;ts = large_image.getTileSource( \\
  "sample.svs");pprint.pprint(ts.getMetadata());ti = ts.getSingleTile( \\
  tile_size=dict(width=1000,height=1000), \\
  scale=dict(magnification=20),tile_position=1000);pprint.pprint(ti);print( \\
  ti["tile"].size);print(ti["tile"][:4,:4])' && \\
echo 'Download a tiff file' && \\
curl -L -o sample.tif \\
  https://data.kitware.com/api/v1/file/5be43e398d777f217991e21f/download && \\
echo 'Use large_image to read a tiff file' && \\
python -c 'import large_image,pprint;ts = large_image.getTileSource( \\
  "sample.tif");pprint.pprint(ts.getMetadata());ti = ts.getSingleTile( \\
  tile_size=dict(width=1000,height=1000), \\
  scale=dict(magnification=20),tile_position=100);pprint.pprint(ti);print( \\
  ti["tile"].size);print(ti["tile"][:4,:4])' && \\
echo 'Download a tiff file that requires a newer openjpeg' && \\
curl -L -o sample_jp2.tif \\
  https://data.kitware.com/api/v1/file/5be348568d777f21798fa1d1/download && \\
echo 'Use large_image to read a tiff file that requires a newer openjpeg' && \\
python -c 'import pyvips;pyvips.Image.new_from_file( \\
  "sample_jp2.tif").write_to_file("sample_jp2_out.tif",compression="jpeg", \\
  Q=90,tile=True,tile_width=256,tile_height=256,pyramid=True, \\
  bigtiff=True);import large_image,pprint;ts = large_image.getTileSource( \\
  "sample_jp2_out.tif");pprint.pprint(ts.getMetadata() \\
  );ti = ts.getSingleTile(tile_size=dict(width=1000, \\
  height=1000),tile_position=100);pprint.pprint(ti);print( \\
  ti["tile"].size);print(ti["tile"][:4,:4])' && \\
echo 'Download a geotiff file' && \\
curl -L -o landcover.tif \\
  https://data.kitware.com/api/v1/file/5be43e848d777f217991e270/download && \\
echo 'Use gdal to open a geotiff file' && \\
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
echo 'Use large_image to read a geotiff file' && \\
python -c 'import large_image,pprint;ts = large_image.getTileSource( \\
  "landcover.tif");pprint.pprint(ts.getMetadata() \\
  );ti = ts.getSingleTile(tile_size=dict(width=1000, \\
  height=1000),tile_position=200);pprint.pprint(ti);print( \\
  ti["tile"].size);print(ti["tile"][:4,:4])' && \\
echo 'Use large_image to read a geotiff file with a projection' && \\
python -c 'import large_image,pprint;ts = large_image.getTileSource( \\
  "landcover.tif", projection="EPSG:3857");pprint.pprint(ts.getMetadata() \\
  );ti = ts.getSingleTile(tile_size=dict(width=1000, \\
  height=1000),tile_position=100);pprint.pprint(ti);print( \\
  ti["tile"].size);print(ti["tile"][:4,:4]);tile = ts.getTile(1178,1507,12 \\
  );pprint.pprint(repr(tile[1400:1440]))' && \\
echo 'Test that pyvips and openslide can both be imported, pyvips first' && \\
python -c 'import pyvips,openslide;pyvips.Image.new_from_file( \\
  "sample_jp2.tif").write_to_file("sample_jp2_out.tif",compression="jpeg", \\
  Q=90,tile=True,tile_width=256,tile_height=256,pyramid=True, \\
  bigtiff=True);' && \\
echo 'Test that pyvips and openslide can both be imported, openslide first' && \\
python -c 'import openslide,pyvips;pyvips.Image.new_from_file( \\
  "sample_jp2.tif").write_to_file("sample_jp2_out.tif",compression="jpeg", \\
  Q=90,tile=True,tile_width=256,tile_height=256,pyramid=True, \\
  bigtiff=True);' && \\
echo 'Test that pyvips and mapnik can both be imported, pyvips first' && \\
python -c 'import pyvips,mapnik;pyvips.Image.new_from_file( \\
  "sample_jp2.tif").write_to_file("sample_jp2_out.tif",compression="jpeg", \\
  Q=90,tile=True,tile_width=256,tile_height=256,pyramid=True, \\
  bigtiff=True);' && \\
# echo 'Test that pyvips and mapnik can both be imported, mapnik first' && \\
# python -c 'import mapnik,pyvips;pyvips.Image.new_from_file( \\
#  "sample_jp2.tif").write_to_file("sample_jp2_out.tif",compression="jpeg", \\
#  Q=90,tile=True,tile_width=256,tile_height=256,pyramid=True, \\
#  bigtiff=True);' && \\
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
