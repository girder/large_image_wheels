#!/usr/bin/env python3

import functools
import packaging.version
import pkg_resources
import re
import requests
import subprocess
import sys

verbose = len([arg for arg in sys.argv[1:] if arg == '-v'])

Packages = {
    'advancecomp': {
        'git': 'https://github.com/amadvance/advancecomp.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'armadillo': {
        'filelist': 'http://arma.sourceforge.net/download.html',
        're': r'armadillo-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$',
    },
    'bison': {
        'filelist': 'https://ftp.gnu.org/pub/gnu/bison/',
        're': r'bison-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$'
    },
    'boost': {
        'git': 'https://github.com/boostorg/boost.git',
        're': r'boost-([0-9]+\.[0-9]+(|\.[0-9]+))$'
        # 'filelist': 'https://sourceforge.net/projects/boost/files/boost/',
        # 're': r'([0-9]+\.[0-9]+(|\.[0-9]+))\/$'
    },
    'cairo': {
        'filelist': 'https://www.cairographics.org/releases/',
        're': r'^cairo-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$'
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
    'epsilon': {
        'filelist': 'https://sourceforge.net/projects/epsilon-project/files/epsilon/',
        're': r'\/([0-9]+\.[0-9]+(|\.[0-9]+))\/$'
    },
    'fitsio': {
        'filelist': 'http://heasarc.gsfc.nasa.gov/FTP/software/fitsio/c/',
        're': r'^cfitsio([0-9]+).tar.(gz|xz)$'
    },
    'flex': {
        'git': 'https://github.com/westes/flex.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'fontconfig': {
        'filelist': 'https://www.freedesktop.org/software/fontconfig/release/',
        're': r'fontconfig-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$'
    },
    'freetype': {
        'filelist': 'https://download.savannah.gnu.org/releases/freetype',
        're': r'freetype-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$'
    },
    'freexl': {
        'fossil': 'https://www.gaia-gis.it/fossil/freexl/timeline?n=10&r=trunk',
        # 'filelist': 'https://www.gaia-gis.it/fossil/freexl/',
        # 're': r'freexl-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$'
    },
    'fossil': {
        'json': 'https://www.fossil-scm.org/index.html/juvlist',
        'keys': lambda data: [entry['name'] for entry in data],
        're': r'fossil-src-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$'
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
    'gettext': {
        'filelist': 'https://ftp.gnu.org/pub/gnu/gettext/',
        're': r'gettext-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$'
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
        'filelist': 'https://www.freedesktop.org/software/harfbuzz/release/',
        're': r'harfbuzz-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$'
    },
    'hdf4': {
        'filelist': 'https://support.hdfgroup.org/ftp/HDF/releases/',
        're': r'HDF([0-9]+\.[0-9]+(|\.[0-9]+))\/$',
        'sub': lambda v: 'HDF' + v + '/src',
        'subre': r'hdf-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$'
    },
    'hdf5': {
        'filelist': 'https://support.hdfgroup.org/ftp/HDF5/releases/',
        're': r'hdf5-([0-9]+\.[0-9]+(|\.[0-9]+))\/$',
        'sub': lambda v: 'hdf5-' + v,
        'subre': r'hdf5-([0-9]+\.[0-9]+(|\.[0-9]+))\/'
    },
    'icu4c': {
        'git': 'https://github.com/unicode-org/icu.git',
        're': r'release-([0-9]+-[0-9]+(|-[0-9]+))$',
        # 'filelist': 'http://download.icu-project.org/files/icu4c/',
        # 're': r'([0-9]+\.[0-9]+(|\.[0-9]+))\/$'
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
        'pypi': 'javabridge',
    },
    'jbigkit': {
        'filelist': 'https://www.cl.cam.ac.uk/~mgk25/jbigkit/download/',
        're': r'jbigkit-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$'
    },
    'libcroco': {
        'json': 'https://download.gnome.org/sources/libcroco/cache.json',
        'keys': lambda data: list(data[1]['libcroco']),
        're': r'^([0-9]+\.[0-9]+(|\.[0-9]+)(|\.[0-9]+))$'
    },
    'libdap': {
        'git': 'https://github.com/OPENDAP/libdap4.git',
        're': r'version-([0-9]+\.[0-9]+(|\.[0-9]+))$',
        # 'filelist': 'https://www.opendap.org/pub/source/',
        # 're': r'libdap-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$'
    },
    'libde265': {
        'git': 'https://github.com/strukturag/libde265.git',
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
    'librsvg': {
        'json': 'https://download.gnome.org/sources/librsvg/cache.json',
        'keys': lambda data: list(data[1]['librsvg']),
        're': r'^([0-9]+\.[0-9]+(|\.[0-9]+)(|\.[0-9]+))$'
    },
    'libspatialite': {
        'fossil': 'https://www.gaia-gis.it/fossil/libspatialite/timeline?n=10&r=trunk',
        # 'filelist': 'https://www.gaia-gis.it/fossil/libspatialite/',
        # 're': r'libspatialite-([0-9]+\.[0-9]+(|\.[0-9]+)(|[a-z])).tar.(gz|xz)$'
    },
    'librasterlite2': {
        'fossil': 'https://www.gaia-gis.it/fossil/librasterlite2/timeline?n=10&r=trunk',
        # 'filelist': 'https://www.gaia-gis.it/fossil/librasterlite2/',
        # 're': r'librasterlite2-([0-9]+\.[0-9]+(|\.[0-9]+)(|-beta[0-9]+)).tar.(gz|xz)$'
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
    'lz4': {
        'git': 'https://github.com/lz4/lz4.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'm4': {
        'filelist': 'https://ftp.gnu.org/gnu/m4/',
        're': r'm4-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$'
    },
    'manylinux2010': {
        # See also https://github.com/pypa/manylinux
        'json': 'https://quay.io/api/v1/repository/pypa/manylinux2010_x86_64?includeTags=true',
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
        'filelist': 'https://dev.mysql.com/downloads/mysql/5.7.html?tpl=version&os=src',
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
    'ninja': {
        'git': 'https://github.com/ninja-build/ninja.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'ogdi': {
        'filelist': 'https://sourceforge.net/projects/ogdi/files/ogdi/',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))\/$'
    },
    'openblas': {
        'git': 'https://github.com/xianyi/OpenBLAS.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'openjpeg': {
        'git': 'https://github.com/uclouvain/openjpeg.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'openmpi': {
        'filelist': 'https://www.open-mpi.org/software/ompi/v4.0/',
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
    'openssh2': {
        'git': 'https://github.com/libssh2/libssh2.git',
        're': r'libssh2-([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    # other libraries don't work with openssl 1.1.1
    'openssl': {
        # 'filelist': 'https://www.openssl.org/source/',
        # 're': r'openssl-(1\.0(|\.[0-9]+)(|[a-z])).tar.(gz|xz)$'
        # 'filelist': 'https://www.openssl.org/source/old/1.1.1/',
        'filelist': 'https://www.openssl.org/source/old/1.0.2/',
        # The packaging.version parser does poor things with 1.0.2r and other
        # values, so include the ".tar" as part of the version
        're': r'openssl-([0-9]+\.[0-9]+(|\.[0-9]+)(|[a-z])\.tar)\.(gz|xz)$'
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
    'perl': {
        'filelist': 'https://www.cpan.org/src/5.0/',
        're': r'perl-([0-9]+\.[0-9]*[02468](|\.[0-9]+)).tar.(gz|xz)$'
    },
    'pixman': {
        'filelist': 'https://www.cairographics.org/releases/',
        're': r'pixman-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$'
    },
    'pkgconfig': {
        'filelist': 'https://pkg-config.freedesktop.org/releases/',
        're': r'pkg-config-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$'
    },
    'pnetcdf': {
        'git': 'https://github.com/Parallel-NetCDF/PnetCDF.git',
        're': r'checkpoint\.([0-9]+\.[0-9]+(|\.[0-9]+))$'
    },
    'poppler': {
        'filelist': 'https://poppler.freedesktop.org/',
        're': r'poppler-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$'
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
    'tcl': {
        'filelist': 'https://sourceforge.net/projects/tcl/files/Tcl/',
        're': r'\/Tcl\/([0-9]+\.[0-9]+(|\.[0-9]+))\/$',
        'sub': lambda v: v,
        'subre': r'tcl([0-9]+\.[0-9]+(|\.[0-9]+)(|\.[0-9]+))-src.tar.(gz|xz)'
    },
    'tk': {
        'filelist': 'https://sourceforge.net/projects/tcl/files/Tcl/',
        're': r'\/Tcl\/([0-9]+\.[0-9]+(|\.[0-9]+))\/$',
        'sub': lambda v: v,
        'subre': r'tk([0-9]+\.[0-9]+(|\.[0-9]+)(|\.[0-9]+))-src.tar.(gz|xz)'
    },
    'ultrajson': {
        'gitsha': 'https://github.com/esnme/ultrajson.git',
    },
    'ultrajson-release': {
        'git': 'https://github.com/esnme/ultrajson.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$'
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
    'xz': {
        'filelist': 'https://sourceforge.net/projects/lzmautils/files/',
        're': r'xz-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.gz\/download'
    },
    'zlib': {
        'filelist': 'https://zlib.net/',
        're': r'zlib-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$'
    },
}


def compareVersions(a, b):
    if packaging.version.parse(a) < packaging.version.parse(b):
        return -1
    if packaging.version.parse(a) > packaging.version.parse(b):
        return 1
    return 0


for pkg in sorted(Packages):
    pkginfo = Packages[pkg]
    entries = None
    versions = None
    if 'filelist' in pkginfo:
        data = requests.get(pkginfo['filelist']).text
        if verbose >= 2:
            print(pkg, 'filelist data', data)
        data = data.replace('<A ', '<a ').replace('HREF="', 'href="')
        entries = [entry.split('href="', 1)[-1].split('"')[0] for entry in data.split('<a ')[1:]]
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
        data = requests.get(pkginfo['json']).json()
        if verbose >= 2:
            print(pkg, 'json data', data)
        entries = pkginfo['keys'](data)
        if verbose >= 1:
            print(pkg, 'json entries', entries)
    elif 'pypi' in pkginfo:
        url = 'https://pypi.python.org/pypi/%s/json' % pkginfo['pypi']
        releases = requests.get(url).json()['releases']
        if verbose >= 2:
            print(pkg, 'pypi releases', entries)
        versions = sorted(releases, key=pkg_resources.parse_version)
        if verbose >= 1:
            print(pkg, 'pypi versions', versions)
    elif 'text' in pkginfo:
        data = requests.get(pkginfo['text']).content.decode('utf8')
        if verbose >= 2:
            print(pkg, 'text data', data)
        entries = pkginfo['keys'](data)
        if verbose >= 1:
            print(pkg, 'text entries', entries)
    elif 'fossil' in pkginfo:
        data = requests.get(pkginfo['fossil']).text
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
            data = requests.get(pkginfo['filelist'] + pkginfo['sub'](pversions[pos])).text
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
    if not len(versions):
        print('%s -- failed to get versions' % pkg)
    else:
        print('%s %s' % (pkg, versions[-1]))
