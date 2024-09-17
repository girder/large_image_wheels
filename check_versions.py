#!/usr/bin/env python3

import functools
import re
import subprocess
import sys
import time

import packaging.version
import requests
import urllib3

urllib3.disable_warnings()

verbose = len([arg for arg in sys.argv[1:] if arg == '-v'])

Packages = {
    'advancecomp': {
        'git': 'https://github.com/amadvance/advancecomp.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'armadillo': {
        'filelist': 'https://sourceforge.net/projects/arma/files/',
        're': r'armadillo-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)/download$',
    },
    'bioformats': {
        'git': 'https://github.com/ome/bioformats.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'blosc': {
        'git': 'https://github.com/Blosc/c-blosc.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'boost': {
        'git': 'https://github.com/boostorg/boost.git',
        're': r'boost-([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'cairo': {
        'git': 'https://gitlab.freedesktop.org/cairo/cairo.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'cmake': {
        'git': 'https://github.com/Kitware/CMake.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'curl': {
        'git': 'https://github.com/curl/curl.git',
        're': r'curl-([0-9]+_[0-9]+(|_[0-9]+))$',
    },
    'cyrus-sasl': {
        'git': 'https://github.com/cyrusimap/cyrus-sasl.git',
        're': r'cyrus-sasl-([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'fftw3': {
        'filelist': 'https://fftw.org/pub/fftw/',
        're': r'fftw-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$',
    },
    'fitsio': {
        'filelist': 'https://heasarc.gsfc.nasa.gov/FTP/software/fitsio/c/',
        're': r'^cfitsio-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$',
        # 'insecure': True,
    },
    'fontconfig': {
        'git': 'https://gitlab.freedesktop.org/fontconfig/fontconfig.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'fossil': {
        'json': 'https://www.fossil-scm.org/index.html/juvlist',
        'keys': lambda data: [entry['name'] for entry in data],
        're': r'fossil-linux-x64-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$',
    },
    'freetype': {
        'git': 'https://gitlab.freedesktop.org/freetype/freetype.git',
        're': r'VER-([0-9]+\-[0-9]+(|\-[0-9]+))$',
    },
    'freexl': {
        'fossil': 'https://www.gaia-gis.it/fossil/freexl/timeline?n=10&r=trunk&ss=x',
        # 'filelist': 'https://www.gaia-gis.it/fossil/freexl/',
        # 're': r'freexl-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$',
    },
    'fyba': {
        'gitsha': 'https://github.com/kartverket/fyba.git',
    },
    'fyba-release': {
        'git': 'https://github.com/kartverket/fyba.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'gdal': {
        'git': 'https://github.com/OSGeo/gdal.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'gdal-pypi': {
        'pypi': 'GDAL',
    },
    'gdal-sha': {
        'gitsha': 'https://github.com/OSGeo/gdal.git',
    },
    'gdal-source': {
        'text': 'https://raw.githubusercontent.com/OSGeo/gdal/master/gcore/gdal_version.h.in',
        'keys': lambda data: [
            re.search(r'define GDAL_VERSION_MAJOR[ ]+([0-9]+)', data)[1] + '.' +
            re.search(r'define GDAL_VERSION_MINOR[ ]+([0-9]+)', data)[1] + '.' +
            re.search(r'define GDAL_VERSION_REV[ ]+([0-9]+)', data)[1]
        ],
    },
    'gdk-pixbuf': {
        'git': 'https://github.com/GNOME/gdk-pixbuf.git',
        're': r'\/([0-9]+\.[0-8][0-9]*(|\.[0-9]+)(|\.[0-9]+))$',
    },
    'giflib': {
        'filelist': 'https://sourceforge.net/projects/giflib/files/',
        're': r'giflib-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.gz\/download',
    },
    'glib': {
        'git': 'https://github.com/GNOME/glib.git',
        're': r'/([0-9]+\.[0-9]+(|\.[0-9]+)(|\.[0-9]+))$',
    },
    'glymur': {
        'git': 'https://github.com/quintusdias/glymur.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+)(|-[0-9]+)(|\.?post[0-9]+))$',
        # 're': r'v([0-9]+\.[0-9]+(|\.[0-9]+)(|-[0-9]+))$',
    },
    'glymur-pypi': {
        'pypi': 'glymur',
    },
    'gobject-introspection': {
        'git': 'https://github.com/GNOME/gobject-introspection.git',
        're': r'/([0-9]+\.[0-9]+(|\.[0-9]+)(|\.[0-9]+))$',
    },
    'harfbuzz': {
        'git': 'https://github.com/harfbuzz/harfbuzz.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$',
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
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+)(|-[0-9]+))$',
    },
    'jbigkit': {
        'filelist': 'https://www.cl.cam.ac.uk/~mgk25/jbigkit/download/',
        're': r'jbigkit-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$',
    },
    'jpeg-xl': {
        'git': 'https://github.com/libjxl/libjxl.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'kealib': {
        'git': 'https://github.com/ubarsc/kealib.git',
        're': r'kealib-([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'krb5': {
        'git': 'https://github.com/krb5/krb5.git',
        're': r'krb5-([0-9]+\.[0-9]+(|\.[0-9]+))-final$',
    },
    'lapack': {
        'git': 'https://github.com/Reference-LAPACK/lapack.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'lcms2': {
        'git': 'https://github.com/mm2/Little-CMS.git',
        're': r'lcms([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'lerc': {
        'git': 'https://github.com/Esri/lerc.git',
        're': r'\/v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'libaio': {
        'git': 'https://pagure.io/libaio.git',
        're': r'libaio\.([0-9]+-[0-9]+-[0-9]+(|\.[0-9]+))$',
    },
    'libarchive': {
        'git': 'https://github.com/libarchive/libarchive.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'libbrotli': {
        'git': 'https://github.com/google/brotli.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'libde265': {
        'git': 'https://github.com/strukturag/libde265.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'libdeflate': {
        'git': 'https://github.com/ebiggers/libdeflate.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'libexif': {
        'git': 'https://github.com/libexif/libexif.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'libexpat': {
        'git': 'https://github.com/libexpat/libexpat.git',
        're': r'R_([0-9]+_[0-9]+(|_[0-9]+))$',
    },
    'libffi': {
        'git': 'https://github.com/libffi/libffi.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'libgeos': {
        'git': 'https://github.com/libgeos/geos.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'libgeotiff': {
        'git': 'https://github.com/OSGeo/libgeotiff.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'libgta': {
        'git': 'https://github.com/marlam/gta-mirror.git',
        're': r'libgta-([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'libheif': {
        'git': 'https://github.com/strukturag/libheif.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'libhwy': {
        'git': 'https://github.com/google/highway.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'libiconv': {
        'filelist': 'https://ftp.gnu.org/pub/gnu/libiconv/',
        're': r'libiconv-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$',
    },
    'libidn2': {
        'filelist': 'https://ftp.gnu.org/gnu/libidn/',
        're': r'libidn2-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$',
    },
    'libimagequant': {
        'git': 'https://github.com/ImageOptim/libimagequant.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+)(|\.[0-9]+))$',
    },
    'libjpeg-turbo': {
        'git': 'https://github.com/libjpeg-turbo/libjpeg-turbo.git',
        # 're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$',
        # Don't allow 2.1.90
        're': r'\/([0-9]+\.[0-9]+(|\.[0-9]|\.[0-8][0-9]+))$',
    },
    'libmemcached': {
        # 'filelist': 'https://launchpad.net/libmemcached/+download',
        # 're': r'libmemcached-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$',
        'git': 'https://github.com/memcachier/libmemcached.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'libnsl': {
        'git': 'https://github.com/thkukuk/libnsl.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'libopendrive': {
        'git': 'https://github.com/DLR-TS/libOpenDRIVE.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))-gdal$',
    },
    'libpng': {
        'git': 'https://github.com/glennrp/libpng.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'libpsl': {
        'git': 'https://github.com/rockdaboot/libpsl.git',
        're': r'\/([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'librasterlite2': {
        'fossil': 'https://www.gaia-gis.it/fossil/librasterlite2/timeline?n=10&r=trunk&ss=x',
        # 'filelist': 'https://www.gaia-gis.it/fossil/librasterlite2/',
        # 're': r'librasterlite2-([0-9]+\.[0-9]+(|\.[0-9]+)(|-beta[0-9]+)).tar.(gz|xz)$',
    },
    'libraw': {
        'git': 'https://github.com/LibRaw/LibRaw.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'librsvg': {
        'git': 'https://github.com/GNOME/librsvg.git',
        're': r'/([0-9]+\.[0-9]+(|\.[0-9]+)(|\.[0-9]+))$',
    },
    'librttopo': {
        'git': 'https://git.osgeo.org/gitea/rttopo/librttopo.git',
        're': r'librttopo-([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'libspatialite': {
        'fossil': 'https://www.gaia-gis.it/fossil/libspatialite/timeline?n=10&r=trunk&ss=x',
        # 'filelist': 'https://www.gaia-gis.it/fossil/libspatialite/',
        # 're': r'libspatialite-([0-9]+\.[0-9]+(|\.[0-9]+)(|[a-z])).tar.(gz|xz)$',
    },
    'libssh2': {
        'git': 'https://github.com/libssh2/libssh2.git',
        're': r'libssh2-([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'libtiff': {
        'git': 'https://gitlab.com/libtiff/libtiff.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'libtirpc': {
        'git': 'https://github.com/alisw/libtirpc.git',
        're': r'libtirpc-([0-9]+-[0-9]+(|-[0-9]+(|-rc[0-9]+)))$',
    },
    'libvips': {
        'git': 'https://github.com/libvips/libvips.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'libwebp': {
        'git': 'https://github.com/webmproject/libwebp.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'libxcrypt': {
        'git': 'https://github.com/besser82/libxcrypt.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'libxml2': {
        'git': 'https://github.com/GNOME/libxml2.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'libzip': {
        'git': 'https://github.com/nih-at/libzip.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'lz4': {
        'git': 'https://github.com/lz4/lz4.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'manylinux2014': {
        # See also https://github.com/pypa/manylinux
        'json': 'https://quay.io/api/v1/repository/pypa/manylinux2014_x86_64?includeTags=true',
        'keys': lambda data: [data['tags']['latest']['manifest_digest']],
        're': r':([0-9a-fA-F]+)$',
    },
    'mapnik': {
        'gitsha': 'https://github.com/mapnik/mapnik.git',
    },
    'mapnik-release': {
        'git': 'https://github.com/mapnik/mapnik.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'matio': {
        'git': 'https://github.com/tbeu/matio.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'meson': {
        'pypi': 'meson',
    },
    'minizip': {
        'git': 'https://github.com/zlib-ng/minizip-ng.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    # MrSID's listing of versions is behind an agreement page, which prevents
    # easily checking the version.
    # 'mrsid': {
    #     'filelist': 'https://www.extensis.com/support/developers',
    #     're': r'MrSID_DSDK-([0-9]+\.[0-9]+(|\.[0-9]+(|\.[0-9]+)))-rhel6.x86-64.gcc531.tar.gz$',
    # },
    'mysql': {
        'filelist': 'https://dev.mysql.com/downloads/mysql/?tpl=version&os=src',
        # 're': r'mysql-boost-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)(&|$)',
        're': r'mysql-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)(&|$)',
    },
    'netcdf': {
        'git': 'https://github.com/Unidata/netcdf-c.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'nifti': {
        'git': 'https://github.com/NIFTI-Imaging/nifti_clib.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'ogdi': {
        'git': 'https://github.com/libogdi/ogdi.git',
        're': r'ogdi_([0-9]+_[0-9]+(|_[0-9]+))$',
    },
    'openblas': {
        'git': 'https://github.com/xianyi/OpenBLAS.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'openexr': {
        'git': 'https://github.com/AcademySoftwareFoundation/openexr.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'openjpeg': {
        'git': 'https://github.com/uclouvain/openjpeg.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'openldap': {
        'git': 'https://git.openldap.org/openldap/openldap.git',
        're': r'OPENLDAP_REL_ENG_([0-9]+_[0-9]+(|_[0-9]+))$',
    },
    'openmpi': {
        # building from git is too slow
        # 'git': 'https://github.com/open-mpi/ompi.git',
        # 're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
        'filelist': 'https://www.open-mpi.org/software/ompi/v4.1/',
        're': r'openmpi-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$',
    },
    'openslide': {
        'git': 'https://github.com/openslide/openslide.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'openslide-python': {
        'git': 'https://github.com/openslide/openslide-python.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'openslide-python-sha': {
        'gitsha': 'https://github.com/openslide/openslide-python.git',
    },
    'openslide-python-pypi': {
        'pypi': 'openslide-python',
    },
    'openslide-sha': {
        'gitsha': 'https://github.com/openslide/openslide.git',
    },
    'openssl': {
        'git': 'https://github.com/openssl/openssl.git',
        're': r'openssl-([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'orc': {
        'git': 'https://github.com/GStreamer/orc.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'pango': {
        'git': 'https://github.com/GNOME/pango.git',
        're': r'/([0-9]+\.[0-8][0-9]*(|\.[0-9]+)(|\.[0-9]+))$',
    },
    'parallel-netcdf': {
        'git': 'https://github.com/Parallel-NetCDF/PnetCDF.git',
        're': r'checkpoint\.([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'patchelf': {
        'git': 'https://github.com/NixOS/patchelf.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'pixman': {
        'git': 'https://gitlab.freedesktop.org/pixman/pixman.git',
        're': r'pixman-([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'pkg-config': {
        'git': 'https://gitlab.freedesktop.org/pkg-config/pkg-config.git',
        're': r'pkg-config-([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'poppler': {
        'git': 'https://gitlab.freedesktop.org/poppler/poppler.git',
        're': r'poppler-([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'postgresql': {
        'filelist': 'https://ftp.postgresql.org/pub/source/',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))\/$',
    },
    'proj4': {
        'git': 'https://github.com/OSGeo/proj.4.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    # 'proj-data': {
    #     'git': 'https://github.com/OSGeo/PROJ-data.git',
    #     're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$',
    # },
    # 'psutil': {
    #     'git': 'https://github.com/giampaolo/psutil.git',
    #     're': r'release-([0-9]+\.[0-9]+(|\.[0-9]+))$',
    # },
    'pylibmc': {
        'git': 'https://github.com/lericson/pylibmc.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'pylibtiff': {
        'git': 'https://github.com/pearu/pylibtiff.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'pylibtiff-sha': {
        'gitsha': 'https://github.com/pearu/pylibtiff.git',
    },
    'pylibtiff-pypi': {
        'pypi': 'libtiff',
    },
    'pyproj4': {
        'git': 'https://github.com/pyproj4/pyproj.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'pyproj4-pypi': {
        'pypi': 'pyproj',
    },
    'python-bioformats': {
        'git': 'https://github.com/CellProfiler/python-bioformats.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'python-mapnik': {
        'gitsha': 'https://github.com/mapnik/python-mapnik.git',
    },
    'python-mapnik-pypi': {
        'pypi': 'mapnik',
    },
    'python-javabridge': {
        'git': 'https://github.com/CellProfiler/python-javabridge.git',
        're': r'([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'python-javabridge-pypi': {
        'pypi': 'python-javabridge',
    },
    'pyvips': {
        'git': 'https://github.com/libvips/pyvips.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    # 'pyvips-sha': {
    #     'gitsha': 'https://github.com/libvips/pyvips.git',
    # },
    'pyvips-pypi': {
        'pypi': 'pyvips',
    },
    'sqlite': {
        'text': 'https://www.sqlite.org/download.html',
        'keys': lambda data: ['.'.join(re.search(
            r'([0-9]{4})\/sqlite-autoconf-([0-9]+).tar.(gz|xz)', data).groups()[:2])],
    },
    'strip-nondeterminism': {
        'git': 'https://github.com/esoule/strip-nondeterminism.git',
        're': r'(0\.[0-9]+(|\.[0-9]+))$',
    },
    'superlu': {
        'git': 'https://github.com/xiaoyeli/superlu.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'util-linux': {
        'git': 'https://github.com/util-linux/util-linux.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'xerces-c': {
        'git': 'https://github.com/apache/xerces-c.git',
        're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'xz': {
        # 'git': 'https://github.com/tukaani-project/xz.git',
        # 're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
        'filelist': 'https://sourceforge.net/projects/lzmautils/files/',
        're': r'xz-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.gz\/download',
    },
    'zlib': {
        'filelist': 'https://zlib.net/',
        're': r'zlib-([0-9]+\.[0-9]+(|\.[0-9]+)).tar.(gz|xz)$',
    },
    'zlib-ng': {
        'git': 'https://github.com/zlib-ng/zlib-ng.git',
        're': r'\/([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
    'zstd': {
        'git': 'https://github.com/facebook/zstd.git',
        're': r'v([0-4]+\.[0-9]+(|\.[0-9]+))$',
        # 're': r'v([0-9]+\.[0-9]+(|\.[0-9]+))$',
    },
}


def compareVersions(a, b):  # noqa
    try:
        av = packaging.version.parse(a)
    except Exception:
        try:
            av = packaging.version.parse(a.replace('_', '.').replace('-', '.'))
        except Exception:
            av = a
    try:
        bv = packaging.version.parse(b)
    except Exception:
        try:
            bv = packaging.version.parse(b.replace('_', '.').replace('-', '.'))
        except Exception:
            bv = b
    if isinstance(av, str) and not isinstance(bv, str):
        return -1
    if not isinstance(av, str) and isinstance(bv, str):
        return 1
    try:
        if av.is_prerelease != bv.is_prerelease:
            return -1 if av.is_prerelease else 1
    except Exception:
        pass
    if av < bv:
        return -1
    if av > bv:
        return 1
    return 0


session = None


def getSession(new=False):
    global session

    if new or not session:
        session = requests.Session()
        retries = urllib3.util.retry.Retry(
            total=10, backoff_factor=0.1, status_forcelist=[104, 500, 502, 503, 504])
        session.mount('http://', requests.adapters.HTTPAdapter(max_retries=retries))
        session.mount('https://', requests.adapters.HTTPAdapter(max_retries=retries))
    return session


def getUrl(url, pkginfo):
    """
    Use a session to get a url.  If it fails, retry with a new session.  If
    that fails, retry without a session.
    """
    param = {'verify': False} if pkginfo.get('insecure') else {}
    try:
        return getSession().get(url, **param)
    except Exception:
        pass
    try:
        return getSession(True).get(url, **param)
    except Exception:
        pass
    return requests.get(url, **param)


# This can be imported into Chrome
if len(sys.argv) >= 2 and sys.argv[1] == 'bookmarks':
    print("""<!DOCTYPE NETSCAPE-Bookmark-file-1>
  <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
  <TITLE>Bookmarks</TITLE>
  <H1>Bookmarks</H1>
  <DL><p>
    <DT><H3>LIW Sources</H3>
    <DL><p>""")
    for key, value in Packages.items():
        url = ([v for v in value.values() if isinstance(v, str) and 'http' in v] + [''])[0]
        if url:
            print('      <DT><A HREF="%s">%s</A>' % (url, key))
    print("""      </DL><p>
      </DL><p>""")
    sys.exit(0)

failures = False
for pkg in sorted(Packages):  # noqa
    if any(val for val in sys.argv[1:] if not val.startswith('-')):
        check = any(val in pkg for val in sys.argv[1:] if not val.startswith('-'))
        if not check:
            continue
    try:
        pkginfo = Packages[pkg]
        entries = None
        versions = None
        if 'filelist' in pkginfo:
            data = getUrl(pkginfo['filelist'], pkginfo).text
            if verbose >= 2:
                print(pkg, 'filelist data', data)
            data = data.replace('<A ', '<a ').replace('HREF="', 'href="')
            entries = [
                entry.split('href="', 1)[-1].split('"')[0] for entry in data.split('<a ')[1:]]
            if verbose >= 1:
                print(pkg, 'filelist entries', entries)
        elif 'fossil' in pkginfo:
            data = getUrl(pkginfo['fossil'], pkginfo).text
            if verbose >= 2:
                print(pkg, 'fossil data', data)
            entries = [entry.split(']<')[0]
                       for entry in data.split('<span class="timelineHistDsp">[')[1:]]
            if verbose >= 1:
                print(pkg, 'fossil entries', entries)
        elif 'git' in pkginfo:
            cmd = ['timeout', '15', 'git', 'ls-remote', '--refs', '--tags', pkginfo['git']]
            for retries in range(10, -1, -1):
                try:
                    entries = [entry for entry in
                               subprocess.check_output(cmd).decode('utf8').split('\n')
                               if '/' in entry]
                    break
                except Exception:
                    if retries:
                        time.sleep(1)
                    else:
                        raise
            if verbose >= 1:
                print(pkg, 'git entries', entries)
        elif 'gitsha' in pkginfo:
            cmd = ['timeout', '15', 'git', 'ls-remote', pkginfo['gitsha'],
                   pkginfo.get('branch', 'HEAD')]
            for retries in range(10, -1, -1):
                try:
                    versions = [subprocess.check_output(cmd).decode('utf8').split()[0]]
                    break
                except Exception:
                    if retries:
                        time.sleep(1)
                    else:
                        raise
            if verbose >= 1:
                print(pkg, 'gitsha versions', versions)
        elif 'json' in pkginfo:
            data = getUrl(pkginfo['json'], pkginfo).json()
            if verbose >= 2:
                print(pkg, 'json data', data)
            entries = pkginfo['keys'](data)
            if verbose >= 1:
                print(pkg, 'json entries', entries)
        elif 'pypi' in pkginfo:
            url = 'https://pypi.python.org/pypi/%s/json' % pkginfo['pypi']
            releases = getUrl(url, pkginfo).json()['releases']
            if verbose >= 2:
                print(pkg, 'pypi releases', releases)
            versions = sorted(releases, key=functools.cmp_to_key(compareVersions))
            if verbose >= 1:
                print(pkg, 'pypi versions', versions)
        elif 'text' in pkginfo:
            data = getUrl(pkginfo['text'], pkginfo).content.decode('utf8')
            if verbose >= 2:
                print(pkg, 'text data', data)
            entries = pkginfo['keys'](data)
            if verbose >= 1:
                print(pkg, 'text entries', entries)
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
                data = getUrl(pkginfo['filelist'] + pkginfo['sub'](pversions[pos]), pkginfo).text
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
        failures = True
if failures:
    sys.exit(1)
