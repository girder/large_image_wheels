#!/usr/bin/env python3

import functools
import re
import subprocess
import sys

import packaging.version
import pkg_resources
import requests
import urllib3

urllib3.disable_warnings()

verbose = len([arg for arg in sys.argv[1:] if arg == '-v'])

Packages = {
    'advancecomp': {
        'git': 'https://github.com/amadvance/advancecomp.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'armadillo': {
        'filelist': 'https://sourceforge.net/projects/arma/files/',
        're': r'armadillo-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)/download$',
        'session': False,
    },
    'blosc': {
        'git': 'https://github.com/Blosc/c-blosc.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'boost': {
        'git': 'https://github.com/boostorg/boost.git',
        're': r'boost-([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'cairo': {
        'git': 'https://gitlab.freedesktop.org/cairo/cairo.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'charls': {
        'gitsha': 'https://github.com/team-charls/charls.git',
        'branch': '1.x-master'
    },
    'charls-release': {
        'git': 'https://github.com/team-charls/charls.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'cmake': {
        'git': 'https://github.com/Kitware/CMake.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'curl': {
        'git': 'https://github.com/curl/curl.git',
        're': r'curl-([0-9]+_[0-9]+(|_[0-9]+))$'
    },
    'fitsio': {
        'filelist': 'https://heasarc.gsfc.nasa.gov/FTP/software/fitsio/c/',
        're': r'^cfitsio([0-9]+).tar.(gz|xz)$',
        'session': False,
        'insecure': True,
    },
    'fontconfig': {
        'git': 'https://gitlab.freedesktop.org/fontconfig/fontconfig.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'fossil': {
        'json': 'https://www.fossil-scm.org/index.html/juvlist',
        'keys': lambda data: [entry['name'] for entry in data],
        're': r'fossil-linux-x64-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$'
    },
    'freetype': {
        'filelist': 'https://download.savannah.gnu.org/releases/freetype',
        're': r'freetype-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$'
    },
    'freexl': {
        'fossil': 'https://www.gaia-gis.it/fossil/freexl/timeline?n=10&r=trunk&ss=x',
        # 'filelist': 'https://www.gaia-gis.it/fossil/freexl/',
        # 're': r'freexl-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$'
    },
    'fyba': {
        'gitsha': 'https://github.com/kartverket/fyba.git',
    },
    'fyba-release': {
        'git': 'https://github.com/kartverket/fyba.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'gdal': {
        'gitsha': 'https://github.com/OSGeo/gdal.git',
    },
    'gdal-pypi': {
        'pypi': 'GDAL',
    },
    'gdal-release': {
        'git': 'https://github.com/OSGeo/gdal.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'gdk-pixbuf': {
        'json': 'https://download.gnome.org/sources/gdk-pixbuf/cache.json',
        'keys': lambda data: list(data[1]['gdk-pixbuf']),
        're': r'^([0-9]+\.[0-9]+(|\.[0-9]+)(|\.[0-9]+))$'
    },
    'geos': {
        'git': 'https://github.com/libgeos/geos.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'gettext': {
        'filelist': 'https://ftp.gnu.org/pub/gnu/gettext/',
        're': r'gettext-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$'
    },
    'giflib': {
        'filelist': 'https://sourceforge.net/projects/giflib/files/',
        're': r'giflib-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.gz\/download'
    },
    'glib': {
        'json': 'https://download.gnome.org/sources/glib/cache.json',
        'keys': lambda data: list(data[1]['glib']),
        're': r'^([0-9]+\.[0-9]+(|\.[0-9]+)(|\.[0-9]+))$'
    },
    'glymur': {
        'git': 'https://github.com/quintusdias/glymur.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+)(|-[0-9]+))$'
    },
    'glymur-pypi': {
        'pypi': 'glymur'
    },
    'gobject-introspection': {
        'json': 'https://download.gnome.org/sources/gobject-introspection/cache.json',
        'keys': lambda data: list(data[1]['gobject-introspection']),
        're': r'^([0-9]+\.[0-9]+(|\.[0-9]+)(|\.[0-9]+))$'
    },
    'harfbuzz': {
        'git': 'https://github.com/harfbuzz/harfbuzz.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'hdf4': {
        'git': 'https://github.com/HDFGroup/hdf4.git',
        're': r'hdf-([0-9]+_[0-9]+(|_[0-9]+))$',
    },
    'hdf5': {
        'git': 'https://github.com/HDFGroup/hdf5.git',
        're': r'hdf5-([0-9]+_[0-9]+(|_[0-9]+))$',
    },
    'icu4c': {
        'git': 'https://github.com/unicode-org/icu.git',
        're': r'release-([0-9]+-[0-9]+(|-[0-9]+))$',
    },
    'imagemagick': {
        'git': 'https://github.com/ImageMagick/ImageMagick.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+)(|-[0-9]+))$'
    },
    'jasper': {
        'git': 'https://github.com/mdadams/jasper.git',
        're': r'version-([0-9]+\.[0-9]+(|\.[0-9]+)(|-[0-9]+))$'
    },
    'javabridge': {
        'git': 'https://github.com/CellProfiler/python-javabridge.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'javabridge-pypi': {
        'pypi': 'python-javabridge',
    },
    'jbigkit': {
        'filelist': 'https://www.cl.cam.ac.uk/~mgk25/jbigkit/download/',
        're': r'jbigkit-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$'
    },
    'jpeg-xl': {
        'git': 'https://gitlab.com/wg1/jpeg-xl.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'krb5': {
        'filelist': 'https://kerberos.org/dist/',
        're': r'krb5-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$'
    },
    'lapack': {
        'git': 'https://github.com/Reference-LAPACK/lapack.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'lerc': {
        'git': 'https://github.com/Esri/lerc.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'libbrotli': {
        'git': 'https://github.com/google/brotli.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'libcroco': {
        'json': 'https://download.gnome.org/sources/libcroco/cache.json',
        'keys': lambda data: list(data[1]['libcroco']),
        're': r'^([0-9]+\.[0-9]+(|\.[0-9]+)(|\.[0-9]+))$'
    },
    'libdap': {
        'git': 'https://github.com/OPENDAP/libdap4.git',
        're': r'version-([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'libde265': {
        'git': 'https://github.com/strukturag/libde265.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'libdeflate': {
        'git': 'https://github.com/ebiggers/libdeflate.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'libexpat': {
        'git': 'https://github.com/libexpat/libexpat.git',
        're': r'R_([0-9]+_[0-9]+(|_[0-9]+))$'
    },
    'libffi': {
        'git': 'https://github.com/libffi/libffi.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'libgeotiff': {
        'git': 'https://github.com/OSGeo/libgeotiff.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'libgsf': {
        'json': 'https://download.gnome.org/sources/libgsf/cache.json',
        'keys': lambda data: list(data[1]['libgsf']),
        're': r'^([0-9]+\.[0-9]+(|\.[0-9]+)(|\.[0-9]+))$'
    },
    'libgta': {
        'git': 'https://github.com/marlam/gta-mirror.git',
        're': r'libgta-([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'libheif': {
        'git': 'https://github.com/strukturag/libheif.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'libhwy': {
        'git': 'https://github.com/google/highway.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'libiconv': {
        'filelist': 'https://ftp.gnu.org/pub/gnu/libiconv/',
        're': r'libiconv-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$'
    },
    'libimagequant': {
        'git': 'https://github.com/ImageOptim/libimagequant.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+)(|\.[0-9]+))$'
    },
    'libjpeg-turbo': {
        'git': 'https://github.com/libjpeg-turbo/libjpeg-turbo.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'libmemcached': {
        'filelist': 'https://launchpad.net/libmemcached/+download',
        're': r'libmemcached-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$'
    },
    'libpng': {
        'filelist': 'https://sourceforge.net/projects/libpng/files/libpng16/',
        're': r'libpng16\/([0-9]+\.[0-9]+(|\.[0-9]+))\/$'
    },
    'librasterlite2': {
        'fossil': 'https://www.gaia-gis.it/fossil/librasterlite2/timeline?n=10&r=trunk&ss=x',
        # 'filelist': 'https://www.gaia-gis.it/fossil/librasterlite2/',
        # 're': r'librasterlite2-([0-9]+\.[0-9]+(|\.[0-9]+)(|-beta[0-9]+)).tar.(gz|xz)$'
    },
    'librsvg': {
        'json': 'https://download.gnome.org/sources/librsvg/cache.json',
        'keys': lambda data: list(data[1]['librsvg']),
        're': r'^([0-9]+\.[0-9]+(|\.[0-9]+)(|\.[0-9]+))$'
    },
    'libspatialite': {
        'fossil': 'https://www.gaia-gis.it/fossil/libspatialite/timeline?n=10&r=trunk&ss=x',
        # 'filelist': 'https://www.gaia-gis.it/fossil/libspatialite/',
        # 're': r'libspatialite-([0-9]+\.[0-9]+(|\.[0-9]+)(|[a-z])).tar.(gz|xz)$'
    },
    'libssh2': {
        'git': 'https://github.com/libssh2/libssh2.git',
        're': r'libssh2-([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'libtiff': {
        'filelist': 'https://download.osgeo.org/libtiff/',
        're': r'tiff-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$'
    },
    'libvips': {
        'git': 'https://github.com/libvips/libvips.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'libwebp': {
        'git': 'https://github.com/webmproject/libwebp.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'libxcrypt': {
        'git': 'https://github.com/besser82/libxcrypt.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'libxml2': {
        'filelist': 'http://xmlsoft.org/sources/',
        're': r'libxml2-([0-9]+\.[0-9]+(|\.[0-9]+)(|[a-z])).tar.(gz|xz)$'
    },
    'libzip': {
        'git': 'https://github.com/nih-at/libzip.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'lz4': {
        'git': 'https://github.com/lz4/lz4.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'm4': {
        'filelist': 'https://ftp.gnu.org/gnu/m4/',
        're': r'm4-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$'
    },
    'manylinux2014': {
        # See also https://github.com/pypa/manylinux
        'json': 'https://quay.io/api/v1/repository/pypa/manylinux2014_x86_64?includeTags=true',
        'keys': lambda data: [data['tags']['latest']['manifest_digest']],
        're': r':([0-9a-fA-F]+)$'
    },
    'mapnik': {
        'gitsha': 'https://github.com/mapnik/mapnik.git',
    },
    'mapnik-release': {
        'git': 'https://github.com/mapnik/mapnik.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'minizip': {
        'git': 'https://github.com/nmoinvaz/minizip.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    # MrSID's listing of versions is behind an agreement page, which prevents
    # easily checking the version.
    # 'mrsid': {
    #     'filelist': 'https://www.extensis.com/support/developers',
    #     're': r'MrSID_DSDK-([0-9]+\.[0-9]+(|\.[0-9]+(|\.[0-9]+)))-rhel6.x86-64.gcc531.tar.gz$'
    # },
    'mysql': {
        'filelist': 'https://dev.mysql.com/downloads/mysql/?tpl=version&os=src',
        're': r'mysql-boost-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)(&|$)'
    },
    'netcdf': {
        'git': 'https://github.com/Unidata/netcdf-c.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'nifti': {
        'filelist': 'https://sourceforge.net/projects/niftilib/files/nifticlib/',
        're': r'nifticlib_([0-9]+_[0-9]+(|_[0-9]+))\/$'
    },
    'ogdi': {
        'git': 'https://github.com/libogdi/ogdi.git',
        're': r'ogdi_([0-9]+_[0-9]+(|_[0-9]+))$'
    },
    'openblas': {
        'git': 'https://github.com/xianyi/OpenBLAS.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'openexr': {
        'git': 'https://github.com/AcademySoftwareFoundation/openexr.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'openjpeg': {
        'git': 'https://github.com/uclouvain/openjpeg.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'openldap': {
        'git': 'https://git.openldap.org/openldap/openldap.git',
        're': r'OPENLDAP_REL_ENG_([0-9]+_[0-9]+(|_[0-9]+))$'
    },
    'openmpi': {
        'filelist': 'https://www.open-mpi.org/software/ompi/v4.1/',
        're': r'openmpi-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$'
    },
    'openslide': {
        'gitsha': 'https://github.com/openslide/openslide.git',
    },
    'openslide-release': {
        'git': 'https://github.com/openslide/openslide.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'openslide-python': {
        'gitsha': 'https://github.com/openslide/openslide-python.git',
    },
    'openslide-python-pypi': {
        'pypi': 'openslide-python',
    },
    'openssl-1.0': {
        'git': 'https://github.com/openssl/openssl.git',
        're': r'OpenSSL_(1_0_[0-9]+[a-z])$',
    },
    'openssl-1.x': {
        'git': 'https://github.com/openssl/openssl.git',
        're': r'OpenSSL_(1_[0-9]+_[0-9]+[a-z])$',
    },
    'orc': {
        'git': 'https://github.com/GStreamer/orc.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'pango': {
        'json': 'https://download.gnome.org/sources/pango/cache.json',
        'keys': lambda data: list(data[1]['pango']),
        're': r'^([0-9]+\.[0-9]+(|\.[0-9]+)(|\.[0-9]+))$'
    },
    'patchelf': {
        'git': 'https://github.com/NixOS/patchelf.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'pcre': {
        'filelist': 'https://ftp.pcre.org/pub/pcre/',
        're': r'pcre-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$'
    },
    'pixman': {
        'git': 'https://gitlab.freedesktop.org/pixman/pixman.git',
        're': r'pixman-([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'pkgconfig': {
        'git': 'https://gitlab.freedesktop.org/pkg-config/pkg-config.git',
        're': r'pkg-config-([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'pnetcdf': {
        'git': 'https://github.com/Parallel-NetCDF/PnetCDF.git',
        're': r'checkpoint\.([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'poppler': {
        'git': 'https://gitlab.freedesktop.org/poppler/poppler.git',
        're': r'poppler-([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'postgresql': {
        'filelist': 'https://ftp.postgresql.org/pub/source/',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))\/$'
    },
    'proj.4': {
        'gitsha': 'https://github.com/OSGeo/proj.4.git',
    },
    'proj.4-release': {
        'git': 'https://github.com/OSGeo/proj.4.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'proj-datumgrid': {
        'filelist': 'http://download.osgeo.org/proj/',
        're': r'proj-datumgrid-([0-9]+\.[0-9]+(|\.[0-9]+)).(tgz|zip)$'
    },
    'psutil': {
        'git': 'https://github.com/giampaolo/psutil.git',
        're': r'release-([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'pylibmc': {
        'git': 'https://github.com/lericson/pylibmc.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'pylibtiff': {
        'gitsha': 'https://github.com/pearu/pylibtiff.git',
    },
    'pylibtiff-pypi': {
        'pypi': 'libtiff',
    },
    # 'pyproj4': {
    #     'gitsha': 'https://github.com/pyproj4/pyproj.git',
    # },
    'pyproj4-release': {
        'git': 'https://github.com/pyproj4/pyproj.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))rel$'
    },
    'pyproj4-pypi': {
        'pypi': 'pyproj',
    },
    'python-mapnik': {
        'gitsha': 'https://github.com/mapnik/python-mapnik.git',
    },
    'python-mapnik-pypi': {
        'pypi': 'mapnik',
    },
    'pyvips': {
        'gitsha': 'https://github.com/libvips/pyvips.git',
    },
    'pyvips-pypi': {
        'pypi': 'pyvips',
    },
    'sqlite': {
        'text': 'https://www.sqlite.org/download.html',
        'keys': lambda data: [re.search(r'sqlite-autoconf-([0-9]+).tar.(gz|xz)', data).group(1)]
    },
    'superlu': {
        'git': 'https://github.com/xiaoyeli/superlu.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'ultrajson': {
        'gitsha': 'https://github.com/esnme/ultrajson.git',
    },
    'ultrajson-release': {
        'git': 'https://github.com/esnme/ultrajson.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'ultrajson-pypi': {
        'pypi': 'ujson',
    },
    'util-linux': {
        'git': 'https://github.com/karelzak/util-linux.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'xerces-c': {
        'filelist': 'http://xerces.apache.org/xerces-c/download.cgi',
        're': r'xerces-c-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$'
    },
    # 'xz': {
    #     'filelist': 'https://sourceforge.net/projects/lzmautils/files/',
    #     're': r'xz-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.gz\/download'
    # },
    'zlib': {
        'filelist': 'https://zlib.net/',
        're': r'zlib-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$'
    },
    'zstd': {
        'git': 'https://github.com/facebook/zstd.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
}


def compareVersions(a, b):
    if packaging.version.parse(a) < packaging.version.parse(b):
        return -1
    if packaging.version.parse(a) > packaging.version.parse(b):
        return 1
    return 0


session = requests.Session()
retries = urllib3.util.retry.Retry(
    total=10, backoff_factor=0.1, status_forcelist=[104, 500, 502, 503, 504])
session.mount('http://', requests.adapters.HTTPAdapter(max_retries=retries))
session.mount('https://', requests.adapters.HTTPAdapter(max_retries=retries))

for pkg in sorted(Packages):  # noqa
    try:
        pkginfo = Packages[pkg]
        entries = None
        versions = None
        if 'filelist' in pkginfo:
            data = (session if pkginfo.get('session') is not False else requests).get(
                pkginfo['filelist'],
                **({'verify': False} if pkginfo.get('insecure') else {})).text
            if verbose >= 2:
                print(pkg, 'filelist data', data)
            data = data.replace('<A ', '<a ').replace('HREF="', 'href="')
            entries = [
                entry.split('href="', 1)[-1].split('"')[0] for entry in data.split('<a ')[1:]]
            if verbose >= 1:
                print(pkg, 'filelist entries', entries)
        elif 'git' in pkginfo:
            cmd = ['git', 'ls-remote', '--refs', '--tags', pkginfo['git']]
            entries = [entry for entry in
                       subprocess.check_output(cmd).decode('utf8').split('\n')
                       if '/' in entry]
            if verbose >= 1:
                print(pkg, 'git entries', entries)
        elif 'gitsha' in pkginfo:
            cmd = ['git', 'ls-remote', pkginfo['gitsha'], pkginfo.get('branch', 'HEAD')]
            versions = [subprocess.check_output(cmd).decode('utf8').split()[0]]
            if verbose >= 1:
                print(pkg, 'gitsha versions', versions)
        elif 'json' in pkginfo:
            data = session.get(pkginfo['json']).json()
            if verbose >= 2:
                print(pkg, 'json data', data)
            entries = pkginfo['keys'](data)
            if verbose >= 1:
                print(pkg, 'json entries', entries)
        elif 'pypi' in pkginfo:
            url = 'https://pypi.python.org/pypi/%s/json' % pkginfo['pypi']
            releases = session.get(url).json()['releases']
            if verbose >= 2:
                print(pkg, 'pypi releases', entries)
            versions = sorted(releases, key=pkg_resources.parse_version)
            if verbose >= 1:
                print(pkg, 'pypi versions', versions)
        elif 'text' in pkginfo:
            data = session.get(pkginfo['text']).content.decode('utf8')
            if verbose >= 2:
                print(pkg, 'text data', data)
            entries = pkginfo['keys'](data)
            if verbose >= 1:
                print(pkg, 'text entries', entries)
        elif 'fossil' in pkginfo:
            data = session.get(pkginfo['fossil']).text
            if verbose >= 2:
                print(pkg, 'fossil data', data)
            entries = [entry.split(']<')[0]
                       for entry in data.split('<span class="timelineHistDsp">[')[1:]]
            if verbose >= 1:
                print(pkg, 'fossil entries', entries)
        if 're' in pkginfo:
            entries = [entry for entry in entries if re.search(pkginfo['re'], entry)]
            if verbose >= 2:
                print(pkg, 're entries', entries)
            versions = [re.search(pkginfo['re'], entry).group(1) for entry in entries]
            if verbose >= 2:
                print(pkg, 're versions', versions)
            versions.sort(key=functools.cmp_to_key(compareVersions))
        if 'subre' in pkginfo:
            pversions = versions
            for pos in range(-1, -len(pversions) - 1, -1):
                data = session.get(pkginfo['filelist'] + pkginfo['sub'](pversions[pos])).text
                if verbose >= 2:
                    print(pkg, 'subre data', data)
                data = data.replace('<A ', '<a ').replace('HREF="', 'href="')
                entries = [entry.split('href="', 1)[-1].split('"')[0]
                           for entry in data.split('<a ')[1:]]
                if verbose >= 2:
                    print(pkg, 'subre entries', entries)
                entries = [entry for entry in entries if re.search(pkginfo['subre'], entry)]
                versions = [re.search(pkginfo['subre'], entry).group(1) for entry in entries]
                if verbose >= 2:
                    print(pkg, 'subre versions', versions)
                versions.sort(key=functools.cmp_to_key(compareVersions))
                if len(versions):
                    break
        if versions is None and entries:
            versions = entries
            if verbose >= 2:
                print(pkg, 'entries versions', versions)
        if versions is None or not len(versions):
            print('%s -- failed to get versions' % pkg)
        else:
            print('%s %s' % (pkg, versions[-1]))
    except Exception:
        import traceback

        print('Exception getting %s\n%s' % (pkg, traceback.format_exc()))
