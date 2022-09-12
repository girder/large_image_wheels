#!/usr/bin/env bash
set -e

export CPL_DEBUG=ON
export OGR_CT_DEBUG=ON

. /etc/profile || true

if curl --version; then true; else
  if apt-get --help; then
    apt-get update
    apt-get install -y curl
  elif yum --help; then
    yum install -y curl
  elif zypper --help; then
    zypper install -y curl
  fi
fi

# python -m venv venv
# . venv/bin/activate

python --version
pip install --upgrade pip
pip install --upgrade setuptools
# which pip2 && pip2 install virtualenv==20.0.5 || true
# echo 'Test installing all libraries from wheels'
# pip install libtiff openslide_python pyvips GDAL mapnik -f /wheels
echo 'Test installing pyvips and other dependencies from wheels via large_image'
pip install large_image[all] -f ${1:-/wheels}

echo 'Test basic import of libtiff'
python -c 'import libtiff'
echo 'Test basic import of openslide'
python -c 'import openslide'
echo 'Test basic import of gdal'
python -c 'from osgeo import gdal'
echo 'Test basic import of mapnik'
python -c 'import mapnik'
echo 'Test basic import of pyvips'
python -c 'import pyvips'
echo 'Test basic import of javabridge'
python -c 'import javabridge'
echo 'Test basic import of pylibmc'
python -c 'import pylibmc'
echo 'Test basic imports of all wheels'
if python -c 'import sys;sys.exit(not (sys.version_info >= (3, 8)))'; then
  echo 'Test basic import of pyproj'
  python -c 'import pyproj'
  echo 'Test basic import of glymur'
  python -c 'import glymur'
  python -c 'import libtiff, openslide, pyproj, pyvips, osgeo, mapnik, glymur, javabridge'
elif python -c 'import sys;sys.exit(not (sys.version_info >= (3, 7)))'; then
  echo 'Test basic import of glymur'
  python -c 'import glymur'
  python -c 'import libtiff, openslide, pyproj, pyvips, osgeo, mapnik, glymur, javabridge'
else
  python -c 'import libtiff, openslide, pyvips, osgeo, mapnik, javabridge'
fi
echo 'Time import of gdal'
python -c 'import sys,time;s = time.time();from osgeo import gdal;sys.exit(0 if time.time()-s < 1 else ("Slow GDAL import %5.3fs" % (time.time() - s)))'

if python -c 'import sys;sys.exit(not (sys.version_info >= (3, 8)))'; then
echo 'Test import of pyproj after mapnik'
python <<EOF
import mapnik
import pyproj
print(pyproj.Proj('+init=epsg:4326 +type=crs'))
EOF
fi

echo 'Download an openslide file'
curl --retry 5 -L -o sample.svs https://data.kitware.com/api/v1/file/5be43d9c8d777f217991e1c2/download
echo 'Use large_image to read an openslide file'
python <<EOF
import large_image, pprint
ts = large_image.getTileSource('sample.svs')
pprint.pprint(ts.getMetadata())
ti = ts.getSingleTile(tile_size=dict(width=1000, height=1000),
                      scale=dict(magnification=20), tile_position=1000)
pprint.pprint(ti)
print(ti['tile'].size)
print(ti['tile'][:4,:4])
EOF
echo 'Download a tiff file'
curl --retry 5 -L -o sample.tif https://data.kitware.com/api/v1/file/5be43e398d777f217991e21f/download
echo 'Use large_image to read a tiff file'
python <<EOF
import large_image, pprint
ts = large_image.getTileSource('sample.tif')
pprint.pprint(ts.getMetadata())
ti = ts.getSingleTile(tile_size=dict(width=1000, height=1000),
                      scale=dict(magnification=20), tile_position=100)
pprint.pprint(ti)
print(ti['tile'].size)
print(ti['tile'][:4,:4])
EOF
echo 'Download a tiff file that requires a newer openjpeg'
curl --retry 5 -L -o sample_jp2.tif https://data.kitware.com/api/v1/file/5be348568d777f21798fa1d1/download
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
print(ti['tile'][:4,:4])
EOF
echo 'Download a png file'
curl --retry 5 -OJL https://github.com/girder/large_image/raw/master/test/test_files/yb10kx5ktrans.png
echo 'Open a png with pyvips'
python <<EOF
import pyvips
pyvips.Image.new_from_file('yb10kx5ktrans.png')
EOF
echo 'Download a geotiff file'
curl --retry 5 -L -o landcover.tif https://data.kitware.com/api/v1/file/5be43e848d777f217991e270/download
echo 'Use gdal to open a geotiff file'
python <<EOF
from osgeo import gdal
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
pprint.pprint(ts.getMetadata())
ti = ts.getSingleTile(tile_size=dict(width=1000, height=1000), tile_position=200)
pprint.pprint(ti)
print(ti['tile'].size)
print(ti['tile'][:4,:4])
EOF
echo 'Use large_image to read a geotiff file with a projection'
python <<EOF
import large_image, pprint
ts = large_image.getTileSource('landcover.tif', projection='EPSG:3857')
pprint.pprint(ts.getMetadata())
ti = ts.getSingleTile(tile_size=dict(width=1000, height=1000), tile_position=100)
pprint.pprint(ti)
print(ti['tile'].size)
print(ti['tile'][:4,:4])
tile = ts.getTile(1178, 1507, 12)
pprint.pprint(repr(tile[1400:1440]))
EOF
echo 'Use large_image to read a geotiff file with a projection via gdal'
python <<EOF
import large_image_source_gdal, pprint
ts = large_image_source_gdal.GDALFileTileSource('landcover.tif', projection='EPSG:3857')
pprint.pprint(ts.getMetadata())
ti = ts.getSingleTile(tile_size=dict(width=1000, height=1000), tile_position=100)
pprint.pprint(ti)
print(ti['tile'].size)
print(ti['tile'][:4,:4])
tile = ts.getTile(1178, 1507, 12)
pprint.pprint(repr(tile[1400:1440]))
EOF
echo 'Use large_image to read a geotiff file with a projection via mapnik'
python <<EOF
import large_image_source_mapnik, pprint
ts = large_image_source_mapnik.MapnikFileTileSource('landcover.tif', projection='EPSG:3857')
pprint.pprint(ts.getMetadata())
ti = ts.getSingleTile(tile_size=dict(width=1000, height=1000), tile_position=100)
pprint.pprint(ti)
print(ti['tile'].size)
print(ti['tile'][:4,:4])
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
curl --retry 5 -L -o sample.ntf https://data.kitware.com/api/v1/file/5cee913e8d777f072bf1c47a/download
echo 'Use gdal to open a nitf file'
python <<EOF
from osgeo import gdal
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

if python -c 'import sys;sys.exit(not (sys.version_info >= (3, 8)))'; then
echo 'Test import order with shapely, mapnik, and pyproj'
if pip install shapely; then (
python -c 'import shapely;import mapnik;import pyproj;print(pyproj.Proj("epsg:4326"))'
python -c 'import pyproj;import shapely;import mapnik;print(pyproj.Proj("epsg:4326"))'
python -c 'import mapnik;import pyproj;import shapely;print(pyproj.Proj("epsg:4326"))'
python -c 'import shapely;import pyproj;import mapnik;print(pyproj.Proj("epsg:4326"))'
python -c 'import mapnik;import shapely;import pyproj;print(pyproj.Proj("epsg:4326"))'
python -c 'import pyproj;import mapnik;import shapely;print(pyproj.Proj("epsg:4326"))'
); else echo 'no shapely available'; fi
fi

# pytorch 1.10 has issues with import order.  Specifically, if torch_cuda.so is
# imported before gdal, gdal fails with the error:
#   ImportError: /usr/lib/x86_64-linux-gnu/libstdc++.so.6: cannot allocate
#   memory in static TLS block
if python -c 'import sys;sys.exit(not (sys.version_info >= (3, 8)))'; then
echo 'Test import order with pytorch, gdal, and pyproj'
if pip install torch; then (
python -c 'import osgeo.gdal;import torch;import pyproj;print(pyproj.Proj("epsg:4326"))'
python -c 'import pyproj;import osgeo.gdal;import torch;print(pyproj.Proj("epsg:4326"))'
python -c 'import torch;import osgeo.gdal;import pyproj;print(pyproj.Proj("epsg:4326"))'
python -c 'import pyproj;import torch;import osgeo.gdal;print(pyproj.Proj("epsg:4326"))'
python -c 'import osgeo.gdal;import pyproj;import torch;print(pyproj.Proj("epsg:4326"))'
python -c 'import torch;import pyproj;import osgeo.gdal;print(pyproj.Proj("epsg:4326"))'
); else echo 'no pytorch available'; fi
fi

echo 'Test running executables'
`python -c 'import os,sys,libtiff;sys.stdout.write(os.path.dirname(libtiff.__file__))'`/bin/tiffinfo landcover.tif
tiffinfo landcover.tif
if python -c 'import sys;sys.exit(not (sys.version_info >= (3, 7)))'; then
`python -c 'import os,sys,glymur;sys.stdout.write(os.path.dirname(glymur.__file__))'`/bin/opj_dump -h | grep -q 'opj_dump utility from the OpenJPEG project'
opj_dump -h | grep -q 'opj_dump utility from the OpenJPEG project'
fi
`python -c 'import os,sys,openslide;sys.stdout.write(os.path.dirname(openslide.__file__))'`/bin/openslide-show-properties --version
openslide-show-properties --version
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
# from autoconf gdal
known = set('derived gtiff hfa mem vrt aaigrid adrg aigrid airsar arg blx bmp bsb cals ceos ceos2 coasp cosar ctg dimap dted elas envisat ers esric fit gff gsg gxf hf2 idrisi ilwis iris iso8211 jaxapalsar jdem kmlsuperoverlay l1b leveller map mrf msgn ngsgeoid nitf northwood pds prf r raw rmf rs2 safe saga sdts sentinel2 sgi sigdem srtmhgt stacit stacta terragen tga til tsx usgsdem xpm xyz zarr zmap rik ozi eeda plmosaic wcs wms wmts daas ogcapi rasterlite mbtiles grib pdf heif exr webp mrsid openjpeg netcdf hdf5 hdf4 gif gta png pcraster fits jpeg pcidsk postgisraster'.lower().split())
# from cmake gdal
known2 = set('JPEG raw GTIFF MEM vrt Derived HFA SDTS NITF GXF AAIGrid CEOS SAR_CEOS XPM DTED JDEM Envisat ELAS FIT L1B RS2 ILWIS RMF Leveller SGI SRTMHGT IDRISI GSG ERS PALSARJaxa DIMAP GFF COSAR PDS ADRG COASP TSX Terragen BLX MSGN TIL R northwood SAGA XYZ HEIF ESRIC HF2 KMLSUPEROVERLAY CTG ZMap NGSGEOID IRIS MAP CALS SAFE SENTINEL2 PRF MRF WMTS GRIB BMP DAAS TGA STACTA OGCAPI BSB AIGrid ARG USGSDEM AirSAR OZI PCIDSK SIGDEM RIK STACIT PDF PNG GIF WCS HTTP netCDF Zarr EEDA FITS HDF5 PLMOSAIC WMS GTA WEBP HDF4 Rasterlite MBTiles PostGISRaster JP2OpenJPEG EXR PCRaster JPEGXL MrSID MEM geojson TAB Shape KML VRT AVC SDTS GML CSV DGN GMT NTF S57 Tiger Geoconcept GeoRSS DXF PGDump GPSBabel EDIGEO SXF OpenFileGDB WAsP Selafin JML VDV FlatGeobuf MapML GPX GMLAS SVG CSW NAS PLSCENES SOSI WFS NGW Elastic Idrisi PDS SQLite GeoPackage OSM VFK MVT AmigoCloud Carto ILI MySQL PG XLSX XLS CAD ODS LVBAG'.lower().split())
current = set(os.popen('gdal-config --formats').read().lower().split())
if len(known2 - current) < len(known - current):
    known = known2
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
if python -c 'import sys;sys.exit(not (sys.version_info >= (3, 8)))'; then
PROJ_LIB=`python -c 'import os,sys,pyproj;sys.stdout.write(os.path.dirname(pyproj.__file__))'`/proj `python -c 'import os,sys,pyproj;sys.stdout.write(os.path.dirname(pyproj.__file__))'`/bin/projinfo EPSG:4326
projinfo EPSG:4326
projinfo ESRI:102654
fi
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

echo 'test javabridge'
java -version
# Disable this line if we need a specific version
pip install python-bioformats
python -c 'import javabridge, bioformats;javabridge.start_vm(class_path=bioformats.JARS, run_headless=True);javabridge.kill_vm()'
curl --retry 5 -L -o sample.czi https://data.kitware.com/api/v1/file/5f048d599014a6d84e005dfc/download
echo 'Use large_image to read a czi file'
python <<EOF
import large_image, pprint
ts = large_image.getTileSource('sample.czi')
pprint.pprint(ts.getMetadata())
ti = ts.getSingleTile(tile_size=dict(width=1000, height=1000),
                      scale=dict(magnification=20), tile_position=100)
pprint.pprint(ti)
print(ti['tile'].size)
print(ti['tile'][:4,:4])
EOF

echo 'test with Django gis'
pip install django
python <<EOF
import sys, osgeo, django.conf
django.conf.settings.configure()
django.conf.settings.GDAL_LIBRARY_PATH=osgeo.GDAL_LIBRARY_PATH
django.conf.settings.GEOS_LIBRARY_PATH=osgeo.GEOS_LIBRARY_PATH
from django.contrib.gis.gdal import CoordTransform, SpatialReference
from django.contrib.gis.geos import Polygon
spatial_ref = SpatialReference('PROJCS["Albers Conical Equal Area",GEOGCS["NAD83",DATUM["North_American_Datum_1983",SPHEROID["GRS 1980",6378137,298.2572221010042,AUTHORITY["EPSG","7019"]],TOWGS84[0,0,0,0,0,0,0],AUTHORITY["EPSG","6269"]],PRIMEM["Greenwich",0],UNIT["degree",0.0174532925199433],AUTHORITY["EPSG","4269"]],PROJECTION["Albers_Conic_Equal_Area"],PARAMETER["standard_parallel_1",29.5],PARAMETER["standard_parallel_2",45.5],PARAMETER["latitude_of_center",23],PARAMETER["longitude_of_center",-96],PARAMETER["false_easting",0],PARAMETER["false_northing",0],UNIT["metre",1,AUTHORITY["EPSG","9001"]]]')
trans = CoordTransform(spatial_ref, SpatialReference(spatial_ref.srid))
poly = Polygon([[1319547.040429464, 2658548.125730889], [2005547.040429464, 2658548.125730889], [2005547.040429464, 2148548.125730889], [1319547.040429464, 2148548.125730889], [1319547.040429464, 2658548.125730889]])
# These will be different if everything is correct
print(poly)
poly2 = poly.transform(trans, clone=True)
print(poly2)
sys.exit(str(poly)[10:]==str(poly2)[10:])
EOF

echo 'test openslide and pyvips rejecting a fluorescent leica image'
# Ideally we would eventually support these here
curl --retry 5 -L -o leica.scn https://data.kitware.com/api/v1/file/5cb8ba728d777f072b4b2663/download
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

# echo 'test pyvips and large svg'
# python <<EOF
# import pyvips
# svgImage = pyvips.Image.svgload_buffer('<svg viewBox="0 0 57578 56112" xmlns="http://www.w3.org/2000/svg"><path fill-rule="evenodd" fill="black" d="M 58815,54197 L 58252,54478 L 57689.,54760 L 58346,55510 L 58815,54197 z"/></svg>'.encode())
# svgImage.tiffsave("/tmp/junk.tiff", compression="lzw")
# EOF

set +e
