#!/usr/bin/env bash
set -e

export CPL_DEBUG=ON
export OGR_CT_DEBUG=ON

. /etc/profile || true

if curl --version 2>/dev/null >/dev/null; then true; else
  if apt-get --help 2>/dev/null >/dev/null; then
    apt-get update -q -q
    apt-get install -y -q -q curl
  elif yum --help 2>/dev/null >/dev/null; then
    yum install -y curl
  elif zypper --help 2>/dev/null >/dev/null; then
    zypper install -y curl
  fi
fi

# # We need to have scikit-image for some of our tests, and if there aren't
# # wheels published for it, we need to have the tools to build it locally.
# if python3 -c 'import sys;sys.exit(not (sys.version_info >= (3, 11)))'; then
#   apt-get update
#   apt-get install -y gcc build-essential
# fi

python3 -m venv venv
. venv/bin/activate

python --version
pip install --upgrade pip
pip install --upgrade setuptools
pip uninstall -y numpy scipy
pip cache purge || true

# Any packages where we aren't building for older python, just install previous
# wheels to keep the testing consistent
pip install 'glymur ; python_version < "3.10"' --find-links https://girder.github.io/large_image_wheels

echo 'Test installing pyvips and other dependencies from wheels via large_image'
if [ $(arch) != "aarch64" ] || python3 -c 'import sys;sys.exit(not (sys.version_info >= (3, 9)))'; then
pip install 'large-image[openslide,gdal,mapnik,bioformats,memcached,tiff,openjpeg,vips,converter]' -f ${1:-/wheels}
else
pip install 'large-image[openslide,gdal,mapnik,memcached,tiff,openjpeg,vips,converter]' -f ${1:-/wheels}
fi

echo 'Test basic import of openslide'
python -c 'import openslide'
echo 'Test basic import of gdal'
python -c 'from osgeo import gdal'
echo 'Test basic import of mapnik'
python -c 'import mapnik'
echo 'Test basic import of pyvips'
python -c 'import pyvips'
if [ $(arch) != "aarch64" ] || python3 -c 'import sys;sys.exit(not (sys.version_info >= (3, 9)))'; then
echo 'Test basic import of javabridge'
python -c 'import javabridge'
fi
echo 'Test basic import of pylibmc'
python -c 'import pylibmc'
echo 'Test basic imports of all wheels'
echo 'Test basic import of libtiff'
python -c 'import libtiff'
echo 'Test basic import of glymur'
python -c 'import glymur'
if [ $(arch) != "aarch64" ] || python3 -c 'import sys;sys.exit(not (sys.version_info >= (3, 9)))'; then
python -c 'import libtiff, openslide, pyvips, osgeo, mapnik, glymur, javabridge'
else
python -c 'import libtiff, openslide, pyvips, osgeo, mapnik, glymur'
fi
echo 'Time import of gdal'
python -c 'import sys,time;s = time.time();from osgeo import gdal;sys.exit(0 if time.time()-s < 1 else ("Slow GDAL import %5.3fs" % (time.time() - s)))'

echo 'Test import of pyproj after mapnik'
python <<EOF
import mapnik
import pyproj
print(pyproj.Proj('+init=epsg:4326 +type=crs'))
EOF

echo 'Download an openslide file'
curl --silent --retry 5 -L -o sample.svs https://data.kitware.com/api/v1/file/5be43d9c8d777f217991e1c2/download
echo 'Use large_image to read an openslide file'
python <<EOF
import large_image, pprint
ts = large_image.getTileSource('sample.svs')
pprint.pprint(ts.getMetadata())
ti = ts.getSingleTile(tile_size=dict(width=1000, height=1000),
                      scale=dict(magnification=20), tile_position=1000)
pprint.pprint(ti)
print(ti['tile'].size)
pprint.pprint(ti['tile'][:4,:4].tolist())
EOF
echo 'Download a tiff file'
curl --silent --retry 5 -L -o sample.tif https://data.kitware.com/api/v1/file/5be43e398d777f217991e21f/download
echo 'Use large_image to read a tiff file'
python <<EOF
import large_image, pprint
ts = large_image.getTileSource('sample.tif')
pprint.pprint(ts.getMetadata())
ti = ts.getSingleTile(tile_size=dict(width=1000, height=1000),
                      scale=dict(magnification=20), tile_position=100)
pprint.pprint(ti)
print(ti['tile'].size)
pprint.pprint(ti['tile'][:4,:4].tolist())
EOF
echo 'Download a tiff file that requires a newer openjpeg'
curl --silent --retry 5 -L -o sample_jp2.tif https://data.kitware.com/api/v1/file/5be348568d777f21798fa1d1/download
echo 'Use large_image to read a tiff file that requires a newer openjpeg'
python <<EOF
import pyvips
pyvips.Image.new_from_file('sample_jp2.tif').write_to_file(
  'sample_jp2_out.tif', compression='jpeg', Q=90, tile=True,
  tile_width=256, tile_height=256, pyramid=True, bigtiff=True)
import large_image, pprint
ts = large_image.getTileSource('sample_jp2_out.tif')
pprint.pprint(ts.getMetadata())
ti = ts.getSingleTile(tile_size=dict(width=1000, height=1000), tile_position=100)
pprint.pprint(ti)
print(ti['tile'].size)
pprint.pprint(ti['tile'][:4,:4].tolist())
EOF
echo 'Download a png file'
curl --silent --retry 5 -OJL https://github.com/girder/large_image/raw/master/test/test_files/yb10kx5ktrans.png
echo 'Open a png with pyvips'
python <<EOF
import pyvips
pyvips.Image.new_from_file('yb10kx5ktrans.png')
EOF
echo 'Download a geotiff file'
curl --silent --retry 5 -L -o landcover.tif https://data.kitware.com/api/v1/file/5be43e848d777f217991e270/download
echo 'Use gdal to open a geotiff file'
python <<EOF
from osgeo import gdal
gdal.UseExceptions()
import pprint
d = gdal.Open('landcover.tif')
pprint.pprint({
  'RasterXSize': d.RasterXSize,
  'RasterYSize': d.RasterYSize,
  'GetProjection': d.GetProjection(),
  'GetGeoTransform': d.GetGeoTransform(),
  'RasterCount': d.RasterCount,
  'band.GetStatistics': d.GetRasterBand(1).GetStatistics(True, True),
  'band.GetNoDataValue': d.GetRasterBand(1).GetNoDataValue(),
  'band.GetScale': d.GetRasterBand(1).GetScale(),
  'band.GetOffset': d.GetRasterBand(1).GetOffset(),
  'band.GetUnitType': d.GetRasterBand(1).GetUnitType(),
  'band.GetCategoryNames': d.GetRasterBand(1).GetCategoryNames(),
  'band.GetColorInterpretation': d.GetRasterBand(1).GetColorInterpretation(),
  'band.GetColorTable().GetCount': d.GetRasterBand(1).GetColorTable().GetCount(),
  'band.GetColorTable().GetColorEntry(0)': d.GetRasterBand(1).GetColorTable().GetColorEntry(0),
  'band.GetColorTable().GetColorEntry(1)': d.GetRasterBand(1).GetColorTable().GetColorEntry(1),
})
EOF
echo 'Use large_image to read a geotiff file'
python <<EOF
import large_image, pprint
ts = large_image.getTileSource('landcover.tif')
pprint.pprint({k: v if k != 'bands' else '<trimmed>' for k, v in ts.getMetadata().items()})
ti = ts.getSingleTile(tile_size=dict(width=1000, height=1000), tile_position=200)
pprint.pprint(ti)
print(ti['tile'].size)
pprint.pprint(ti['tile'][:4,:4].tolist())
EOF
echo 'Use large_image to read a geotiff file with a projection'
python <<EOF
import large_image, pprint
ts = large_image.getTileSource('landcover.tif', projection='EPSG:3857')
pprint.pprint({k: v if k != 'bands' else '<trimmed>' for k, v in ts.getMetadata().items()})
ti = ts.getSingleTile(tile_size=dict(width=1000, height=1000), tile_position=100)
pprint.pprint(ti)
print(ti['tile'].size)
pprint.pprint(ti['tile'][:4,:4].tolist())
tile = ts.getTile(1178, 1507, 12)
pprint.pprint(repr(tile[1400:1440]))
EOF
echo 'Use large_image to read a geotiff file with a projection via gdal'
python <<EOF
import large_image_source_gdal, pprint
ts = large_image_source_gdal.GDALFileTileSource('landcover.tif', projection='EPSG:3857')
pprint.pprint({k: v if k != 'bands' else '<trimmed>' for k, v in ts.getMetadata().items()})
ti = ts.getSingleTile(tile_size=dict(width=1000, height=1000), tile_position=100)
pprint.pprint(ti)
print(ti['tile'].size)
pprint.pprint(ti['tile'][:4,:4].tolist())
tile = ts.getTile(1178, 1507, 12)
pprint.pprint(repr(tile[1400:1440]))
EOF
echo 'Use large_image to read a geotiff file with a projection via mapnik'
python <<EOF
import large_image_source_mapnik, pprint
ts = large_image_source_mapnik.MapnikFileTileSource('landcover.tif', projection='EPSG:3857')
pprint.pprint({k: v if k != 'bands' else '<trimmed>' for k, v in ts.getMetadata().items()})
ti = ts.getSingleTile(tile_size=dict(width=1000, height=1000), tile_position=100)
pprint.pprint(ti)
print(ti['tile'].size)
pprint.pprint(ti['tile'][:4,:4].tolist())
tile = ts.getTile(1178, 1507, 12)
pprint.pprint(repr(tile[1400:1440]))
EOF
echo 'Use large_image to read a geotiff file with a projection and style via mapnik'
python <<EOF
import large_image_source_mapnik, pprint
ts = large_image_source_mapnik.MapnikFileTileSource('landcover.tif', projection='EPSG:3857', style={'band': 1, 'min': 0, 'max': 100,
                    'scheme': 'discrete',
                    'palette': 'matplotlib.Plasma_6'})
pprint.pprint({k: v if k != 'bands' else '<trimmed>' for k, v in ts.getMetadata().items()})
ti = ts.getSingleTile(tile_size=dict(width=1000, height=1000), tile_position=100)
pprint.pprint(ti)
print(ti['tile'].size)
pprint.pprint(ti['tile'][:4,:4].tolist())
tile = ts.getTile(1178, 1507, 12)
pprint.pprint(repr(tile[1400:1440]))
EOF
echo 'Test that pyvips and openslide can both be imported, pyvips first'
python <<EOF
import pyvips, openslide
pyvips.Image.new_from_file('sample_jp2.tif').write_to_file(
  'sample_jp2_out.tif', compression='jpeg', Q=90, tile=True,
  tile_width=256, tile_height=256, pyramid=True, bigtiff=True)
EOF
echo 'Test that pyvips and openslide can both be imported, openslide first'
python <<EOF
import openslide, pyvips
pyvips.Image.new_from_file('sample_jp2.tif').write_to_file(
  'sample_jp2_out.tif', compression='jpeg', Q=90, tile=True,
  tile_width=256, tile_height=256, pyramid=True, bigtiff=True)
EOF
echo 'Test that pyvips and mapnik can both be imported, pyvips first'
python <<EOF
import pyvips, mapnik
pyvips.Image.new_from_file('sample_jp2.tif').write_to_file(
  'sample_jp2_out.tif', compression='jpeg', Q=90, tile=True,
  tile_width=256, tile_height=256, pyramid=True, bigtiff=True)
EOF
echo 'Test that pyvips and mapnik can both be imported, mapnik first'
python <<EOF
import mapnik, pyvips
pyvips.Image.new_from_file('sample_jp2.tif').write_to_file(
  'sample_jp2_out.tif', compression='jpeg', Q=90, tile=True,
  tile_width=256, tile_height=256, pyramid=True, bigtiff=True)
EOF
echo 'Download a somewhat bad nitf file'
curl --silent --retry 5 -L -o sample.ntf https://data.kitware.com/api/v1/file/5cee913e8d777f072bf1c47a/download
echo 'Use gdal to open a nitf file'
python <<EOF
from osgeo import gdal
gdal.UseExceptions()
import pprint
d = gdal.Open('sample.ntf')
pprint.pprint({
  'RasterXSize': d.RasterXSize,
  'RasterYSize': d.RasterYSize,
  'GetProjection': d.GetProjection(),
  'GetGeoTransform': d.GetGeoTransform(),
  'RasterCount': d.RasterCount,
  })
pprint.pprint(d.GetMetadata()['NITF_BLOCKA_FRFC_LOC_01'])
EOF
echo 'Download an rgba geotiff'
curl --silent --retry 5 -L -o rgba_geotiff.tiff https://data.kitware.com/api/v1/file/6862d7564263e86bc81ba30d/download
echo 'Use large_image and gdal to open an rgba geotiff'
python <<EOF
import large_image
print(large_image.open('rgba_geotiff.tiff'))
EOF

echo 'Test import order with shapely, mapnik, and pyproj'
if pip install shapely; then (
python -c 'import shapely;import mapnik;import pyproj;print(pyproj.Proj("epsg:4326"))'
python -c 'import pyproj;import shapely;import mapnik;print(pyproj.Proj("epsg:4326"))'
python -c 'import mapnik;import pyproj;import shapely;print(pyproj.Proj("epsg:4326"))'
python -c 'import shapely;import pyproj;import mapnik;print(pyproj.Proj("epsg:4326"))'
python -c 'import mapnik;import shapely;import pyproj;print(pyproj.Proj("epsg:4326"))'
python -c 'import pyproj;import mapnik;import shapely;print(pyproj.Proj("epsg:4326"))'
); else echo 'no shapely available'; fi

echo 'Test running executables'
`python -c 'import os,sys,libtiff;sys.stdout.write(os.path.dirname(libtiff.__file__))'`/bin/tiffinfo landcover.tif
tiffinfo landcover.tif
`python -c 'import os,sys,glymur;sys.stdout.write(os.path.dirname(glymur.__file__))'`/bin/opj_dump -h | grep -q 'opj_dump utility from the OpenJPEG project'
opj_dump -h | grep -q 'opj_dump utility from the OpenJPEG project'

if slidetool --version; then
`python -c 'import os,sys,openslide;sys.stdout.write(os.path.dirname(openslide.__file__))'`/bin/slidetool --version
slidetool --version
else
`python -c 'import os,sys,openslide;sys.stdout.write(os.path.dirname(openslide.__file__))'`/bin/openslide-show-properties --version
openslide-show-properties --version
fi

`python -c 'import os,sys,osgeo;sys.stdout.write(os.path.dirname(osgeo.__file__))'`/bin/gdalinfo --version
gdalinfo --version
gdalinfo --formats
# wc yielded "159 1055 8030" on 2021-11-12
gdalinfo --formats | wc
gdal-config --formats
# wc yielded "1 104 605" on 2021-11-12
gdal-config --formats | wc
python <<EOF
import os
known = set('JPEG raw GTIFF MEM vrt Derived GTI HFA NITF GXF AAIGrid CEOS SAR_CEOS DTED JDEM Envisat L1B RS2 ILWIS RMF Leveller SRTMHGT IDRISI GSG ERS PALSARJaxa DIMAP GFF COSAR PDS ADRG COASP TSX Terragen MSGN TIL northwood SAGA XYZ HEIF ESRIC HF2 KMLSUPEROVERLAY CTG ZMap NGSGEOID IRIS MAP CALS SAFE SENTINEL2 PRF MRF WMTS GRIB BMP TGA STACTA SNAP_TIFF BSB AIGrid USGSDEM AirSAR PCIDSK SIGDEM RIK STACIT PDF PNG GIF WCS HTTP netCDF Zarr DAAS EEDA FITS HDF5 PLMOSAIC WMS OGCAPI GTA WEBP HDF4 MBTiles PostGISRaster KEA JP2OpenJPEG EXR PCRaster JPEGXL MEM GeoJSON TAB Shape KML VRT AVC GML CSV DGN GMT S57 GeoRSS DXF PGDump GPSBabel EDIGEO SXF OpenFileGDB WAsP Selafin JML VDV FlatGeobuf MapML MiraMon JSONFG GPX GMLAS CSW NAS PLSCENES SOSI WFS OAPIF NGW Elastic XODR Idrisi PDS SQLite GeoPackage OSM VFK MVT PMTiles AmigoCloud Carto ILI MySQL PG XLSX XLS CAD GTFS ODS LVBAG'.lower().split())
current = set(os.popen('gdal-config --formats').read().lower().split())
print('New formats: %s' % ' '.join(sorted(current - known)))
print('Missing formats: %s' % ' '.join(sorted(known - current)))
if len(known-current):
    raise Exception('Missing previously known format')
EOF
# Fail if we end up with fewer formats in GDAL than we once had.
if (( $(gdal-config --formats | wc -w) < 98 )); then false; fi
`python -c 'import os,sys,mapnik;sys.stdout.write(os.path.dirname(mapnik.__file__))'`/bin/mapnik-render --version 2>&1 | grep version
mapnik-render --version 2>&1 | grep version
`python -c 'import os,sys,pyvips;sys.stdout.write(os.path.dirname(pyvips.__file__))'`/bin/vips --version
vips --version
echo 'test GDAL transform'
python <<EOF
from osgeo import ogr, osr
import sys
poly = ogr.CreateGeometryFromWkt('POLYGON ((1319547.040429464 2658548.125730889, 2005547.040429464 2658548.125730889, 2005547.040429464 2148548.125730889, 1319547.040429464 2148548.125730889, 1319547.040429464 2658548.125730889))')
source = osr.SpatialReference()
source.ImportFromWkt('PROJCS["Albers Conical Equal Area",GEOGCS["NAD83",DATUM["North_American_Datum_1983",SPHEROID["GRS 1980",6378137,298.2572221010042,AUTHORITY["EPSG","7019"]],TOWGS84[0,0,0,0,0,0,0],AUTHORITY["EPSG","6269"]],PRIMEM["Greenwich",0],UNIT["degree",0.0174532925199433],AUTHORITY["EPSG","4269"]],PROJECTION["Albers_Conic_Equal_Area"],PARAMETER["standard_parallel_1",29.5],PARAMETER["standard_parallel_2",45.5],PARAMETER["latitude_of_center",23],PARAMETER["longitude_of_center",-96],PARAMETER["false_easting",0],PARAMETER["false_northing",0],UNIT["metre",1,AUTHORITY["EPSG","9001"]]]')
target = osr.SpatialReference()
target.ImportFromEPSG(4326)
transform = osr.CoordinateTransformation(source, target)
s = poly.ExportToWkt()
print(s)
poly.Transform(transform)
d = poly.ExportToWkt()
print(d)
sys.exit(s == d)
EOF

if [ $(arch) != "aarch64" ] || python3 -c 'import sys;sys.exit(not (sys.version_info >= (3, 9)))'; then

echo 'test javabridge'
java -version
python -c 'import javabridge, bioformats;javabridge.start_vm(class_path=bioformats.JARS, run_headless=True);javabridge.kill_vm()'

echo 'Check bioformats version'
python -c 'import large_image_source_bioformats;print(large_image_source_bioformats._getBioformatsVersion())'

if [ $(arch) != "aarch64" ]; then
curl --silent --retry 5 -L -o sample.czi https://data.kitware.com/api/v1/file/5f048d599014a6d84e005dfc/download
echo 'Use large_image to read a czi file'
python <<EOF
import large_image, pprint
ts = large_image.getTileSource('sample.czi')
pprint.pprint(ts.getMetadata())
ti = ts.getSingleTile(tile_size=dict(width=1000, height=1000),
                      scale=dict(magnification=20), tile_position=100)
pprint.pprint(ti)
print(ti['tile'].size)
pprint.pprint(ti['tile'][:4,:4].tolist())
EOF
fi

echo 'test javabridge with different encoding'
java -version
python -c 'import javabridge, bioformats;javabridge.start_vm(class_path=bioformats.JARS, run_headless=True);javabridge.kill_vm()'
python <<EOF
import large_image_source_bioformats, pprint
ts = large_image_source_bioformats.open('sample.svs')
pprint.pprint(ts.getMetadata())
ti = ts.getSingleTile(tile_size=dict(width=1000, height=1000),
                      scale=dict(magnification=20), tile_position=100)
pprint.pprint(ti)
print(ti['tile'].size)
pprint.pprint(ti['tile'][:4,:4].tolist())
EOF

fi

if [ $(arch) != "aarch64" ] || python3 -c 'import sys;sys.exit(not (sys.version_info >= (3, 9)))'; then
echo 'test with Django gis'
pip install django
python <<EOF
import sys, osgeo, django.conf
django.conf.settings.configure()
django.conf.settings.GDAL_LIBRARY_PATH=osgeo.GDAL_LIBRARY_PATH
django.conf.settings.GEOS_LIBRARY_PATH=osgeo.GEOS_LIBRARY_PATH
from django.contrib.gis.gdal import CoordTransform, SpatialReference
from django.contrib.gis.geos import Polygon
spatial_ref = SpatialReference('PROJCS["Albers Conical Equal Area",GEOGCS["NAD83",DATUM["North_American_Datum_1983",SPHEROID["GRS 1980",6378137,298.2572221010042,AUTHORITY["EPSG","7019"]],TOWGS84[0,0,0,0,0,0,0],AUTHORITY["EPSG","6269"]],PRIMEM["Greenwich",0],UNIT["degree",0.0174532925199433],AUTHORITY["EPSG","4269"]],PROJECTION["Albers_Conic_Equal_Area"],PARAMETER["standard_parallel_1",29.5],PARAMETER["standard_parallel_2",45.5],PARAMETER["latitude_of_center",23],PARAMETER["longitude_of_center",-96],PARAMETER["false_easting",0],PARAMETER["false_northing",0],UNIT["metre",1,AUTHORITY["EPSG","9001"]],AUTHORITY["EPSG","4269"]]')
trans = CoordTransform(spatial_ref, SpatialReference(spatial_ref.srid))
poly = Polygon([[1319547.040429464, 2658548.125730889], [2005547.040429464, 2658548.125730889], [2005547.040429464, 2148548.125730889], [1319547.040429464, 2148548.125730889], [1319547.040429464, 2658548.125730889]])
# These will be different if everything is correct
print(poly)
poly2 = poly.transform(trans, clone=True)
print(poly2)
sys.exit(str(poly)[10:]==str(poly2)[10:])
EOF
fi

echo 'test openslide and pyvips rejecting a fluorescent leica image'
# Ideally we would eventually support these here
curl --silent --retry 5 -L -o leica.scn https://data.kitware.com/api/v1/file/5cb8ba728d777f072b4b2663/download
python <<EOF
import openslide
import pyvips

try:
  openslide.OpenSlide('leica.scn')
  raise Exception('Surprise success')
except openslide.lowlevel.OpenSlideError:
  pass

try:
  pyvips.Image.new_from_file('leica.scn')
  raise Exception('Surprise success')
except pyvips.error.Error:
  pass
EOF

echo 'test an ome.tiff file'
curl --silent --retry 5 -L -o sample.ome.tif https://data.kitware.com/api/v1/file/5cb9c6288d777f072b4e85f0/download
python <<EOF
import large_image_source_vips

large_image_source_vips.open('sample.ome.tif')
EOF

echo 'test vips conversion'
vips tiffsave sample.ome.tif sample.lzw.tif --tile --tile-width 256 --tile-height 256 --pyramid --bigtiff --compression lzw --predictor horizontal
tifftools dump sample.lzw.tif,1 | grep -q 'Predictor'
vips tiffsave sample.ome.tif sample.jpeg.tif --tile --tile-width 256 --tile-height 256 --pyramid --bigtiff --compression jpeg --Q 90

echo 'test libvips and webp'
curl --silent --retry 5 -L  -o d042-353.crop.small.float32.tif https://data.kitware.com/api/v1/file/hashsum/sha512/8b640e9adcd0b8aba794666027b80215964d075e76ca2ebebefc7e17c3cd79af7da40a40151e2a2ba0ae48969e54275cf69a3cfc1a2a6b87fbb0d186013e5489/download
python <<EOF
import large_image_converter.__main__ as main

main.main(['d042-353.crop.small.float32.tif', '/tmp/outfloat.tiff', '--compression', 'webp'])
EOF

echo 'test libvips and jpeg'
python <<EOF
import large_image_converter.__main__ as main

main.main(['d042-353.crop.small.float32.tif', '/tmp/outfloatjpeg.tiff', '--compression', 'jpeg'])
EOF

echo 'test GDAL vsicurl'
python <<EOF
import large_image_source_gdal
ts = large_image_source_gdal.open('https://data.kitware.com/api/v1/file/hashsum/sha512/5e56cdb8fb1a02615698a153862c10d5292b1ad42836a6e8bce5627e93a387dc0d3c9b6cfbd539796500bc2d3e23eafd07550f8c214e9348880bbbc6b3b0ea0c/download')
print(ts.getMetadata())
EOF

# echo 'test pyvips and large svg'
# python <<EOF
# import pyvips
# svgImage = pyvips.Image.svgload_buffer('<svg viewBox="0 0 57578 56112" xmlns="http://www.w3.org/2000/svg"><path fill-rule="evenodd" fill="black" d="M 58815,54197 L 58252,54478 L 57689.,54760 L 58346,55510 L 58815,54197 z"/></svg>'.encode())
# svgImage.tiffsave("/tmp/junk.tiff", compression="lzw")
# EOF

set +e
