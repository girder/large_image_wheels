FROM quay.io/pypa/manylinux2010_x86_64
# When I try to use dockcross/manylinux-x64, some of the references to certain
# libraries, like sqlite3, seem to be broken
# FROM dockcross/manylinux-x64

RUN mkdir /build
WORKDIR /build

RUN yum install -y \
    gettext \
    libcurl-devel \
    xz \
    # for easier development
    man \
    vim-enhanced

# Patch autoreconf to better use GETTEXT
# See https://lists.gnu.org/archive/html/autoconf-patches/2015-10/msg00001.html
# for the patch logic
RUN sed -i 's/\^AM_GNU_GETTEXT_VERSION/\^AM_GNU_GETTEXT_\(REQUIRE_\)\?VERSION/g' /usr/bin/autoreconf

# Update autotools, perl, m4, pkg-config

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent http://pkgconfig.freedesktop.org/releases/pkg-config-0.29.2.tar.gz -L -o pkg-config.tar.gz && \
    mkdir pkg-config && \
    tar -zxf pkg-config.tar.gz -C pkg-config --strip-components 1 && \
    rm -f pkg-config.tar.gz && \
    cd pkg-config && \
    ./configure --silent --prefix=/usr/local --with-internal-glib --disable-host-tool && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install

ENV PKG_CONFIG=/usr/local/bin/pkg-config
# Some of these paths are added later
ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/local/lib64/pkgconfig:/usr/lib64/pkgconfig:/usr/share/pkgconfig

# 1.4.17
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent ftp://ftp.gnu.org/gnu/m4/m4-latest.tar.gz -L -o m4.tar.gz && \
    mkdir m4 && \
    tar -zxf m4.tar.gz -C m4 --strip-components 1 && \
    rm -f m4.tar.gz && \
    cd m4 && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install

# Make our own zlib so we don't depend on system libraries
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://zlib.net/zlib-1.2.11.tar.gz -L -o zlib.tar.gz && \
    mkdir zlib && \
    tar -zxf zlib.tar.gz -C zlib --strip-components 1 && \
    rm -f zlib.tar.gz && \
    cd zlib && \
    ./configure --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# Make our own openssl so we don't depend on system libraries
RUN curl --retry 5 --silent https://www.openssl.org/source/openssl-1.0.2o.tar.gz -L -o openssl.tar.gz && \
    mkdir openssl && \
    tar -zxf openssl.tar.gz -C openssl --strip-components 1 && \
    rm -f openssl.tar.gz && \
    cd openssl && \
    ./config --prefix=/usr/local --openssldir=/usr/local/ssl shared zlib && \
    make --silent && \
    # using "all install_sw" rather than "install" to avoid installing docs
    make --silent all install_sw && \
    ldconfig

RUN git clone --depth=1 --single-branch -b libssh2-1.8.2 https://github.com/libssh2/libssh2.git && \
    cd libssh2 && \
    ./buildconf && \
    ./configure --silent --prefix=/usr/local && \
    make --silent && \
    make --silent install && \
    ldconfig

# Perl - building from source seems to have less issues

# RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
#     curl --retry 5 --silent -L http://install.perlbrew.pl | bash && \
#     . ~/perl5/perlbrew/etc/bashrc && \
#     echo '. /root/perl5/perlbrew/etc/bashrc' >> /etc/bashrc && \
#     perlbrew install perl-5.29.0 -j ${JOBS} -n && \
#     perlbrew switch perl-5.29.0

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://www.cpan.org/src/5.0/perl-5.28.1.tar.gz -L -o perl.tar.gz && \
    mkdir perl && \
    tar -zxf perl.tar.gz -C perl --strip-components 1 && \
    rm -f perl.tar.gz && \
    cd perl && \
    ./Configure -des -Dprefix=/usr/localperl && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install-silent

# CMake - we can build from source or just use a precompiled binary

# RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
#     curl --retry 5 --silent https://cmake.org/files/v3.11/cmake-3.11.4.tar.gz -L -o cmake.tar.gz && \
#     mkdir cmake && \
#     tar -zxf cmake.tar.gz -C cmake --strip-components 1 && \
#     rm -f cmake.tar.gz && \
#     cd cmake && \
#     ./bootstrap && \
#     make --silent -j ${JOBS} && \
#     make --silent -j ${JOBS} install

RUN curl --retry 5 --silent https://github.com/Kitware/CMake/releases/download/v3.14.4/cmake-3.14.4-Linux-x86_64.tar.gz -L -o cmake.tar.gz && \
    mkdir cmake && \
    tar -zxf cmake.tar.gz -C /usr/local --strip-components 1 && \
    rm -f cmake.tar.gz

# Strip libraries before building any wheels
RUN strip --strip-unneeded /usr/local/lib/*.{so,a}

# Packages used by large_image that don't have published wheels for all the
# versions of Python we are using.

# Don't build python 3.4 wheels.
RUN rm -r /opt/python/cp34*

RUN git clone --depth=1 --single-branch -b release-5.6.2 https://github.com/giampaolo/psutil.git && \
    cd psutil && \
    for PYBIN in /opt/python/*/bin/; do \
      echo "${PYBIN}" && \
      "${PYBIN}/pip" wheel . -w /io/wheelhouse; \
    done && \
    for WHL in /io/wheelhouse/psutil*.whl; do \
      auditwheel repair --plat manylinux2010_x86_64 "${WHL}" -w /io/wheelhouse/; \
    done && \
    ls -l /io/wheelhouse

RUN git clone --depth=1 --single-branch https://github.com/esnme/ultrajson.git && \
    cd ultrajson && \
    for PYBIN in /opt/python/*/bin/; do \
      echo "${PYBIN}" && \
      "${PYBIN}/pip" wheel . -w /io/wheelhouse; \
    done && \
    for WHL in /io/wheelhouse/ujson*.whl; do \
      auditwheel repair "${WHL}" -w /io/wheelhouse/; \
    done && \
    ls -l /io/wheelhouse

# Upgrade to the latest version of proj.4.
# As of 2019-05-21, there were bugs fixed in master that seem important, so use
# master rather than the last released version.

# RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
#     curl --retry 5 --silent https://github.com/OSGeo/proj.4/releases/download/6.1.0/proj-6.1.0.tar.gz -L -o proj.tar.gz && \
#     mkdir proj && \
#     tar -zxf proj.tar.gz -C proj --strip-components 1 && \
#     rm -f proj.tar.gz && \
#     cd proj && \
#     ./configure --silent --prefix=/usr/local && \
#     make --silent -j ${JOBS} && \
#     make --silent -j ${JOBS} install && \
#     ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch https://github.com/OSGeo/proj.4.git && \
    cd proj.4 && \
    curl --retry 5 --silent http://download.osgeo.org/proj/proj-datumgrid-1.8.zip -L -o proj-datumgrid.zip && \
    cd data && \
    unzip -o ../proj-datumgrid.zip && \
    cd .. && \
    ./autogen.sh && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# Strip libraries before building any wheels
RUN strip --strip-unneeded /usr/local/lib/*.{so,a}

# As of 3/8/2019, pyproj 2.0.0 is published as wheels for all versions of
# python we care about, but we want the latest version of proj.4.
RUN git clone --depth=1 --single-branch https://github.com/jswhit/pyproj && \
    cd pyproj && \
    python -c $'# \n\
import re \n\
path = "pyproj/__init__.py" \n\
s = open(path).read() \n\
s = s.replace(\n\
  "__version__ = \\"2.2.0\\"", "__version__ = \\"2.2.1\\"") \n\
open(path, "w").write(s)' && \
    for PYBIN in /opt/python/*/bin/; do \
      echo "${PYBIN}" && \
      "${PYBIN}/pip" install --no-cache-dir cython && \
      "${PYBIN}/pip" wheel . -w /io/wheelhouse; \
    done && \
    for WHL in /io/wheelhouse/pyproj*.whl; do \
      auditwheel repair "${WHL}" -w /io/wheelhouse/; \
    done && \
    ls -l /io/wheelhouse

# OpenJPEG

RUN yum install -y \
    # needed for openjpeg
    lcms2-devel

# 1.2.59 works
# 1.6.37 doesn't work with gdk-pixbuf2
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://downloads.sourceforge.net/libpng/libpng-1.2.59.tar.xz -L -o libpng.tar.xz && \
    unxz libpng.tar.xz && \
    mkdir libpng && \
    tar -xf libpng.tar -C libpng --strip-components 1 && \
    rm -f libpng.tar && \
    cd libpng && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://github.com/uclouvain/openjpeg/archive/v2.3.0.tar.gz -L -o openjpeg.tar.gz && \
    mkdir openjpeg && \
    tar -zxf openjpeg.tar.gz -C openjpeg --strip-components 1 && \
    rm -f openjpeg.tar.gz && \
    cd openjpeg && \
    cmake . && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# libtiff

# Note: This doesn't support GL

RUN yum install -y \
    # needed for libtiff
    giflib-devel \
    freeglut-devel \
    libjpeg-devel \
    libXi-devel \
    libzstd-devel \
    mesa-libGL-devel \
    mesa-libGLU-devel \
    SDL-devel \
    xz-devel

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://www.cl.cam.ac.uk/~mgk25/jbigkit/download/jbigkit-2.1.tar.gz -L -o jbigkit.tar.gz && \
    mkdir jbigkit && \
    tar -zxf jbigkit.tar.gz -C jbigkit --strip-components 1 && \
    rm -f jbigkit.tar.gz && \
    cd jbigkit && \
    python -c $'# \n\
path = "Makefile" \n\
s = open(path).read().replace("-O2 ", "-O2 -fPIC ") \n\
open(path, "w").write(s)' && \
    make --silent -j ${JOBS} && \
    cp {libjbig,pbmtools}/*.{o,so,a} /usr/local/lib/. || true && \
    cp libjbig/*.h /usr/local/include/. && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent http://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.0.0.tar.gz -L -o libwebp.tar.gz && \
    mkdir libwebp && \
    tar -zxf libwebp.tar.gz -C libwebp --strip-components 1 && \
    rm -f libwebp.tar.gz && \
    cd libwebp && \
    ./configure --silent --prefix=/usr/local --enable-libwebpmux --enable-libwebpdecoder --enable-libwebpextras && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# For 12-bit jpeg
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://github.com/libjpeg-turbo/libjpeg-turbo/archive/2.0.1.tar.gz -L -o libjpeg-turbo.tar.gz && \
    mkdir libjpeg-turbo && \
    tar -zxf libjpeg-turbo.tar.gz -C libjpeg-turbo --strip-components 1 && \
    rm -f libjpeg-turbo.tar.gz && \
    cd libjpeg-turbo && \
    cmake -DWITH_12BIT=1 . && \
    make --silent -j ${JOBS}

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://download.osgeo.org/libtiff/tiff-4.0.10.tar.gz -L -o tiff.tar.gz && \
    mkdir tiff && \
    tar -zxf tiff.tar.gz -C tiff --strip-components 1 && \
    rm -f tiff.tar.gz && \
    cd tiff && \
    ./configure --silent --prefix=/usr/local --enable-jpeg12 --with-jpeg12-include-dir=/build/libjpeg-turbo --with-jpeg12-lib=/build/libjpeg-turbo/libjpeg.so && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# Rebuild openjpeg with our libtiff
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    cd openjpeg && \
    cmake . && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# Strip libraries before building any wheels
RUN strip --strip-unneeded /usr/local/lib/*.{so,a}

# Use an older version of numpy -- we can work with newer versions, but have to
# have at least this version to use our wheel.
RUN git clone --depth=1 --single-branch -b wheel-support https://github.com/manthey/pylibtiff.git && \
    cd pylibtiff && \
    for PYBIN in /opt/python/*/bin/; do \
      echo "${PYBIN}" && \
      if [[ "${PYBIN}" =~ "37" ]]; then \
        export NUMPY_VERSION="1.14"; \
      else \
        export NUMPY_VERSION="1.11"; \
      fi && \
      python -c $'# \n\
import re \n\
path = "setup.py" \n\
s = open(path).read() \n\
s = re.sub(\n\
  r"install_requires=.*,", "install_requires=[\'numpy>='"${NUMPY_VERSION}"$'\'],", s) \n\
open(path, "w").write(s)' && \
      "${PYBIN}/pip" install --no-cache-dir "numpy==${NUMPY_VERSION}.*" && \
      "${PYBIN}/pip" wheel --no-deps . -w /io/wheelhouse; \
    done && \
    for WHL in /io/wheelhouse/libtiff*.whl; do \
      auditwheel repair --plat manylinux2010_x86_64 "${WHL}" -w /io/wheelhouse/; \
    done && \
    ls -l /io/wheelhouse

# OpenSlide

RUN yum install -y \
    # needed for openslide
    cairo-devel \
    libtool

# Install newer versions of glib2, gdk-pixbuf2, libxml2.
# In our setup.py, we may want to confirm glib2 >= 2.25.9

RUN yum install -y \
    libffi-devel \
    libxml2-devel

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://ftp.pcre.org/pub/pcre/pcre-8.43.tar.gz -L -o pcre.tar.gz && \
    mkdir pcre && \
    tar -zxf pcre.tar.gz -C pcre --strip-components 1 && \
    rm -f pcre.tar.gz && \
    cd pcre && \
    ./configure --silent --prefix=/usr/local --enable-unicode-properties --enable-pcre16 --enable-pcre32 --enable-jit && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# 2.25.9 okay
# 2.46.2 will install with libffi-devel
# 2.47.92 needs libffi-devel and a newer version of pcre-devel
# 2.48.2 needs libffi-devel and a newer version of pcre-devel
# 2.49.7 fails on mkostemp
# 2.50.3 needs libmount
# 2.58.3 is the last package that supports autoconf, but needs libmount
# 2.61 requires meson and libmount
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://download.gnome.org/sources/glib/2.48/glib-2.48.2.tar.xz -L -o glib-2.tar.xz && \
    unxz glib-2.tar.xz && \
    mkdir glib-2 && \
    tar -xf glib-2.tar -C glib-2 --strip-components 1 && \
    rm -f glib-2.tar && \
    cd glib-2 && \
    ./autogen.sh && \
    ./configure --silent --prefix=/usr/local --with-python=/opt/python/cp27-cp27mu/bin/python && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://ftp.gnome.org/pub/gnome/sources/gdk-pixbuf/2.21/gdk-pixbuf-2.21.7.tar.gz -L -o gdk-pixbuf-2.tar.gz && \
    mkdir gdk-pixbuf-2 && \
    tar -zxf gdk-pixbuf-2.tar.gz -C gdk-pixbuf-2 --strip-components 1 && \
    rm -f gdk-pixbuf-2.tar.gz && \
    cd gdk-pixbuf-2 && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# Tell auditwheel to use our updated files.
RUN python -c $'# \n\
import os \n\
path = os.popen("find /opt/_internal -name policy.json").read().strip() \n\
data = open(path).read().replace( \n\
    "libglib-2.0.so.0", "Xlibglib-2.0.so.0").replace( \n\
    "libXrender.so.1", "XlibXrender.so.1").replace( \n\
    "libX11.so.6", "XlibX11.so.6").replace( \n\
    "libgobject-2.0.so.0", "Xlibgobject-2.0.so.0").replace( \n\
    "libgthread-2.0.so.0", "Xlibgthread-2.0.so.0") \n\
open(path, "w").write(data)'

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://github.com/openslide/openslide/archive/v3.4.1.tar.gz -L -o openslide.tar.gz && \
    mkdir openslide && \
    tar -zxf openslide.tar.gz -C openslide --strip-components 1 && \
    rm -f openslide.tar.gz && \
    cd openslide && \
    autoreconf -ifv && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# This patch allows girder's file layout to work with mirax files and does no
# harm otherwise.
COPY openslide-vendor-mirax.c.patch .

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    cd openslide && \
    patch src/openslide-vendor-mirax.c ../openslide-vendor-mirax.c.patch && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# Strip libraries before building any wheels
RUN strip --strip-unneeded /usr/local/lib/*.{so,a}

RUN git clone https://github.com/openslide/openslide-python && \
    cd openslide-python && \
    python -c $'# \n\
path = "setup.py" \n\
s = open(path).read().replace( \n\
    "_convert.c\'", "_convert.c\'], libraries=[\'openslide\'") \n\
open(path, "w").write(s)' && \
    python -c $'# \n\
path = "openslide/lowlevel.py" \n\
s = open(path).read().replace( \n\
"""    _lib = cdll.LoadLibrary(\'libopenslide.so.0\')""", \n\
"""    try: \n\
        import os \n\
        libpath = os.path.abspath(os.path.join(os.path.dirname(os.path.realpath( \n\
            __file__)), \'.libs\')) \n\
        libs = os.listdir(libpath) \n\
        loadCount = 0 \n\
        while True: \n\
            numLoaded = 0 \n\
            for name in libs: \n\
                try: \n\
                    somelib = os.path.join(libpath, name) \n\
                    if name.startswith(\'libopenslide\'): \n\
                        lib = somelib \n\
                    cdll.LoadLibrary(somelib) \n\
                    numLoaded += 1 \n\
                except Exception: \n\
                    pass \n\
            if numLoaded - loadCount <= 0: \n\
                break \n\
            loadCount = numLoaded \n\
        _lib = cdll.LoadLibrary(lib) \n\
    except Exception: \n\
        _lib = cdll.LoadLibrary(\'libopenslide.so.0\')""") \n\
open(path, "w").write(s)' && \
    for PYBIN in /opt/python/*/bin/; do \
      echo "${PYBIN}" && \
      "${PYBIN}/pip" wheel . -w /io/wheelhouse; \
    done && \
    for WHL in /io/wheelhouse/openslide*.whl; do \
      auditwheel repair --plat manylinux2010_x86_64 "${WHL}" -w /io/wheelhouse/ || exit 1; \
    done && \
    ls -l /io/wheelhouse

# GDAL

RUN yum install -y \
    zip

# Boost

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://ftp.gnu.org/pub/gnu/libiconv/libiconv-1.15.tar.gz -L -o libiconv.tar.gz && \
    mkdir libiconv && \
    tar -zxf libiconv.tar.gz -C libiconv --strip-components 1 && \
    rm -f libiconv.tar.gz && \
    cd libiconv && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent http://download.icu-project.org/files/icu4c/63.1/icu4c-63_1-src.tgz -L -o icu4c.tar.gz && \
    mkdir icu4c && \
    tar -zxf icu4c.tar.gz -C icu4c --strip-components 1 && \
    rm -f icu4c.tar.gz && \
    cd icu4c/source && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://download.open-mpi.org/release/open-mpi/v3.1/openmpi-3.1.3.tar.gz -L -o openmpi.tar.gz && \
    mkdir openmpi && \
    tar -zxf openmpi.tar.gz -C openmpi --strip-components 1 && \
    rm -f openmpi.tar.gz && \
    cd openmpi && \
    ./configure --silent --prefix=/usr/local --disable-dependency-tracking --enable-silent-rules && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# This works with boost 1.69.0.
# It probably won't work for 1.66.0 and before, as those versions didn't handle
# multiple python versions properly.
# 1.70.0 doesn't work with current mapnik (https://github.com/mapnik/mapnik/issues/4041)
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    # git clone --depth=1 --single-branch -b boost-1.69.0 https://github.com/boostorg/boost.git && cd boost && git submodule update --init -j ${JOBS} && \
    curl --retry 5 --silent https://downloads.sourceforge.net/project/boost/boost/1.69.0/boost_1_69_0.tar.gz -L -o boost.tar.gz && \
    mkdir boost && \
    tar -zxf boost.tar.gz -C boost --strip-components 1 && \
    rm -f boost.tar.gz && \
    cd boost && \
    echo "" > tools/build/src/user-config.jam && \
    echo "using python : 2.7 : /opt/python/cp27-cp27mu/bin/python : /opt/python/cp27-cp27mu/include/python2.7 : /opt/python/cp27-cp27mu/lib ; " >> tools/build/src/user-config.jam && \
    echo "using python : 3.5 : /opt/python/cp35-cp35m/bin/python : /opt/python/cp35-cp35m/include/python3.5m : /opt/python/cp35-cp35m/lib ; " >> tools/build/src/user-config.jam && \
    echo "using python : 3.6 : /opt/python/cp36-cp36m/bin/python : /opt/python/cp36-cp36m/include/python3.6m : /opt/python/cp36-cp36m/lib ; " >> tools/build/src/user-config.jam && \
    echo "using python : 3.7 : /opt/python/cp37-cp37m/bin/python : /opt/python/cp37-cp37m/include/python3.7m : /opt/python/cp37-cp37m/lib ; " >> tools/build/src/user-config.jam && \
    ./bootstrap.sh --prefix=/usr/local --with-toolset=gcc variant=release && \
    ./b2 -d1 -j ${JOBS} toolset=gcc variant=release python=2.7,3.5,3.6,3.7 cxxflags="-std=c++14 -Wno-parentheses -Wno-deprecated-declarations -Wno-unused-variable -Wno-parentheses -Wno-maybe-uninitialized" install && \
    ldconfig

RUN curl --retry 5 --silent -L https://www.fossil-scm.org/index.html/uv/fossil-linux-x64-2.7.tar.gz -o fossil.tar.gz && \
    tar -zxf fossil.tar.gz && \
    rm -f fossil.tar.gz && \
    mv fossil /usr/local/bin

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://prdownloads.sourceforge.net/tcl/tcl8.6.9-src.tar.gz -L -o tcl.tar.gz && \
    mkdir tcl && \
    tar -zxf tcl.tar.gz -C tcl --strip-components 1 && \
    rm -f tcl.tar.gz && \
    cd tcl/unix && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://prdownloads.sourceforge.net/tcl/tk8.6.9.1-src.tar.gz -L -o tk.tar.gz && \
    mkdir tk && \
    tar -zxf tk.tar.gz -C tk --strip-components 1 && \
    rm -f tk.tar.gz && \
    cd tk/unix && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://sqlite.org/2019/sqlite-autoconf-3280000.tar.gz -L -o sqlite.tar.gz && \
    mkdir sqlite && \
    tar -zxf sqlite.tar.gz -C sqlite --strip-components 1 && \
    rm -f sqlite.tar.gz && \
    cd sqlite && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    fossil --user=root clone https://www.gaia-gis.it/fossil/freexl freexl.fossil && \
    mkdir freexl && \
    cd freexl && \
    fossil open ../freexl.fossil && \
    rm -f ../freexl.fossil && \
    LIBS=-liconv ./configure --silent --prefix=/usr/local && \
    LIBS=-liconv make -j ${JOBS} && \
    LIBS=-liconv make -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch https://github.com/libgeos/geos.git && \
    cd geos && \
    mkdir build && \
    cd build && \
    cmake -DGEOS_BUILD_DEVELOPER=NO .. && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    fossil --user=root clone https://www.gaia-gis.it/fossil/libspatialite libspatialite.fossil && \
    mkdir libspatialite && \
    cd libspatialite && \
    fossil open ../libspatialite.fossil && \
    rm -f ../libspatialite.fossil && \
    CFLAGS='-DACCEPT_USE_OF_DEPRECATED_PROJ_API_H=true' ./configure --silent --prefix=/usr/local --disable-examples && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch https://github.com/pierriko/libgeotiff && \
    cd libgeotiff && \
    AUTOHEADER=true autoreconf -ifv && \
    CFLAGS='-DACCEPT_USE_OF_DEPRECATED_PROJ_API_H=true' ./configure --silent --prefix=/usr/local --with-zlib=yes --with-jpeg=yes --enable-incode-epsg && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://www.cairographics.org/releases/pixman-0.34.0.tar.gz -L -o pixman.tar.gz && \
    mkdir pixman && \
    tar -zxf pixman.tar.gz -C pixman --strip-components 1 && \
    rm -f pixman.tar.gz && \
    cd pixman && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://download.savannah.gnu.org/releases/freetype/freetype-2.9.tar.gz -L -o freetype.tar.gz && \
    mkdir freetype && \
    tar -zxf freetype.tar.gz -C freetype --strip-components 1 && \
    rm -f freetype.tar.gz && \
    cd freetype && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN curl --retry 5 --silent https://www.cairographics.org/releases/cairo-1.16.0.tar.xz -L -o cairo.tar.xz && \
    unxz cairo.tar.xz && \
    mkdir cairo && \
    tar -xf cairo.tar -C cairo --strip-components 1 && \
    rm -f cairo.tar && \
    cd cairo && \
    CXXFLAGS='-Wno-implicit-fallthrough -Wno-cast-function-type' CFLAGS="$CFLAGS -Wl,--allow-multiple-definition" ./configure --silent --prefix=/usr/local --disable-dependency-tracking && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch -b 1.x-master https://github.com/team-charls/charls && \
    cd charls && \
    mkdir build && \
    cd build && \
    cmake -DBUILD_SHARED_LIBS=ON .. && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    cp ../src/interface.h /usr/local/include/CharLS/. && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch -b v1.9.1 https://github.com/lz4/lz4.git && \
    cd lz4 && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    fossil --user=root clone https://www.gaia-gis.it/fossil/librasterlite2 librasterlite2.fossil && \
    mkdir librasterlite2 && \
    cd librasterlite2 && \
    fossil open ../librasterlite2.fossil && \
    rm -f ../librasterlite2.fossil && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# fyba won't compile with GCC 8.2.x, so apply fix in issue #21
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch https://github.com/kartverket/fyba && \
    cd fyba && \
    python -c $'# \n\
import os \n\
path = "src/FYBA/FYLU.cpp" \n\
data = open(path).read() \n\
data = data.replace( \n\
    "#include \\"stdafx.h\\"", "") \n\
data = data.replace( \n\
    "#include <locale>", \n\
    "#include <locale>\\n" + \n\
    "#include \\"stdafx.h\\"") \n\
open(path, "w").write(data)' && \
    autoreconf -ifv && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://ftp.gnu.org/gnu/bison/bison-3.1.tar.xz -L -o bison.tar.xz && \
    unxz bison.tar.xz && \
    mkdir bison && \
    tar -xf bison.tar -C bison --strip-components 1 && \
    rm -f bison.tar && \
    cd bison && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# We need flex to build flex, but we have to build flex to get a newer version
RUN yum install -y \
    flex \
    help2man \
    texinfo

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://ftp.gnu.org/pub/gnu/gettext/gettext-0.19.8.tar.gz -L -o gettext.tar.gz && \
    mkdir gettext && \
    tar -zxf gettext.tar.gz -C gettext --strip-components 1 && \
    rm -f gettext.tar.gz && \
    cd gettext && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch -b v2.6.4 https://github.com/westes/flex && \
    cd flex && \
    autoreconf -ifv && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN yum install -y \
    curl-devel \
    libuuid-devel

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://www.opendap.org/pub/source/libdap-3.20.0.tar.gz -L -o libdap.tar.gz && \
    mkdir libdap && \
    tar -zxf libdap.tar.gz -C libdap --strip-components 1 && \
    rm -f libdap.tar.gz && \
    cd libdap && \
    ./configure --silent --prefix=/usr/local --enable-threads=posix && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN yum install -y \
    docbook2X

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://github.com/libexpat/libexpat/archive/R_2_2_6.tar.gz -L -o libexpat.tar.gz && \
    mkdir libexpat && \
    tar -zxf libexpat.tar.gz -C libexpat --strip-components 1 && \
    rm -f libexpat.tar.gz && \
    cd libexpat/expat && \
    autoreconf -ifv && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN yum install -y \
    gperf

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://www.freedesktop.org/software/fontconfig/release/fontconfig-2.13.1.tar.gz -L -o fontconfig.tar.gz && \
    mkdir fontconfig && \
    tar -zxf fontconfig.tar.gz -C fontconfig --strip-components 1 && \
    rm -f fontconfig.tar.gz && \
    cd fontconfig && \
    autoreconf -ifv && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# Build items necessary for netcdf support
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://support.hdfgroup.org/ftp/HDF5/releases/hdf5-1.10/hdf5-1.10.5/src/hdf5-1.10.5.tar.gz -L -o hdf5.tar.gz && \
    mkdir hdf5 && \
    tar -zxf hdf5.tar.gz -C hdf5 --strip-components 1 && \
    rm -f hdf5.tar.gz && \
    cd hdf5 && \
    autoreconf -ifv && \
    # This libraries produces a lot of warnings; since we don't do anything
    # about them, suppress them.
    CFLAGS='-w' ./configure --silent --prefix=/usr/local --disable-dependency-tracking && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://www.unidata.ucar.edu/downloads/netcdf/ftp/netcdf-c-4.6.2.tar.gz -L -o netcdf.tar.gz && \
    mkdir netcdf && \
    tar -zxf netcdf.tar.gz -C netcdf --strip-components 1 && \
    rm -f netcdf.tar.gz && \
    cd netcdf && \
    autoreconf -ifv && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# These add more support to GDAL
RUN yum install -y \
    cfitsio-devel \
    hdf-devel \
    jasper-devel \
    json-c12-devel \
    # ncurses is needed for mysql
    ncurses-devel

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://dev.mysql.com/get/Downloads/MySQL-5.7/mysql-boost-5.7.25.tar.gz -L -o mysql.tar.gz && \
    mkdir mysql && \
    tar -zxf mysql.tar.gz -C mysql --strip-components 1 && \
    rm -f mysql.tar.gz && \
    mkdir mysql/build && \
    cd mysql/build && \
    CXXFLAGS="-Wno-deprecated-declarations" cmake -DBUILD_CONFIG=mysql_release -DIGNORE_AIO_CHECK=ON -DBUILD_SHARED_LIBS=ON -DWITH_BOOST=../boost/boost_1_59_0 -DWITH_SSL=/usr/local -DWITH_ZLIB=system -DCMAKE_INSTALL_PREFIX=/usr/local -DWITH_UNIT_TESTS=OFF -DWITH_RAPID=OFF -DCMAKE_BUILD_TYPE=Release -DWITH_EMBEDDED_SERVER=OFF -DINSTALL_MYSQLTESTDIR="" .. && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# ogdi doesn't build with parallelism
RUN curl --retry 5 --silent https://downloads.sourceforge.net/project/ogdi/ogdi/4.1.0/ogdi-4.1.0.tar.gz -L -o ogdi.tar.gz && \
    mkdir ogdi && \
    tar -zxf ogdi.tar.gz -C ogdi --strip-components 1 && \
    rm -f ogdi.tar.gzz && \
    cd ogdi && \
    export TOPDIR=`pwd` && \
    ./configure --silent --prefix=/usr/local --with-zlib --with-expat && \
    make --silent && \
    make --silent install && \
    cp bin/Linux/*.so /usr/local/lib/. && \
    ldconfig

RUN yum install -y \
    readline-devel

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://ftp.postgresql.org/pub/source/v9.6.13/postgresql-9.6.13.tar.gz -L -o postgresql.tar.gz && \
    mkdir postgresql && \
    tar -zxf postgresql.tar.gz -C postgresql --strip-components 1 && \
    rm -f postgresql.tar.gz && \
    cd postgresql && \
    autoreconf -ifv && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# --with-dods-root is where libdap is installed
# This works with master, v2.3.2, v2.4.0
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    # git clone --depth=1 --single-branch -b v3.0.0 https://github.com/OSGeo/gdal.git && \
    git clone --depth=1 --single-branch https://github.com/OSGeo/gdal.git && \
    cd gdal/gdal && \
    export PATH="$PATH:/build/mysql/build/scripts" && \
    ./configure --prefix=/usr/local --with-cpp14 --without-libtool --with-jpeg12 --without-poppler --with-podofo --with-spatialite --with-liblzma --with-webp --with-epsilon --with-podofo --with-hdf5 --with-dods-root=/usr/local --with-sosi --with-mysql --with-rasterlite2 --with-pg && \
    make -j ${JOBS} USER_DEFS="-Werror -Wno-missing-field-initializers -Wno-write-strings" && \
    cd apps && \
    make -j ${JOBS} USER_DEFS="-Werror -Wno-missing-field-initializers -Wno-write-strings" test_ogrsf && \
    cd .. && \
    make -j ${JOBS} install && \
    ldconfig

RUN python -c $'# \n\
import os \n\
path = os.popen("find /opt/_internal -name policy.json").read().strip() \n\
data = open(path).read().replace( \n\
    "libXext.so.6", "XlibXext.so.6").replace( \n\
    "libSM.so.6", "XlibSM.so.6").replace( \n\
    "libICE.so.6", "XlibICE.so.6").replace( \n\
    "CXXABI", "XCXXABI").replace( \n\
    "libstdc++.so.6", "Xlibstdc++.so.6") \n\
open(path, "w").write(data)'

# Strip libraries before building any wheels
RUN strip --strip-unneeded /usr/local/lib/*.{so,a}

RUN cd gdal/gdal/swig/python && \
    cp -r /usr/local/share/{proj,gdal,epsg_csv} osgeo/. && \
    python -c $'# \n\
import os \n\
path = "setup.py" \n\
data = open(path).read() \n\
data = data.replace( \n\
    "        self.gdaldir = self.get_gdal_config(\'prefix\')", \n\
    "        try:\\n" + \n\
    "            self.gdaldir = self.get_gdal_config(\'prefix\')\\n" + \n\
    "        except Exception:\\n" + \n\
    "            return True") \n\
data = data.replace( \n\
    "gdal_version = \'3.0.0\'", \n\
    "gdal_version = \'" + os.popen("gdal-config --version").read().strip() + "\'") \n\
data = data.replace( \n\
    "    scripts=glob(\'scripts/*.py\'),", \n\
    "    scripts=glob(\'scripts/*.py\'),\\n" + \n\
    "    package_data={\'osgeo\': [\'proj/*\', \'gdal/*\', \'epsg_csv\']},") \n\
open(path, "w").write(data)' && \
    python -c $'# \n\
path = "osgeo/__init__.py" \n\
s = open(path).read().replace( \n\
    "osgeo package.", \n\
"""osgeo package. \n\
\n\
import os \n\
\n\
localpath = os.path.dirname(os.path.abspath( __file__ )) \n\
os.environ.setdefault("PROJ_LIB", os.path.join(localpath, "proj")) \n\
os.environ.setdefault("GDAL_DATA", os.path.join(localpath, "gdal")) \n\
os.environ.setdefault("GEOTIFF_CSV", os.path.join(localpath, "epsg_csv")) \n\
caPath = "/etc/ssl/certs/ca-certificates.crt" \n\
if os.path.exists(caPath): \n\
    os.environ.setdefault("CURL_CA_BUNDLE", caPath) \n\
""") \n\
open(path, "w").write(s)'

# Copy python ports of c utilities to scripts so they get bundled.
RUN cp gdal/gdal/swig/python/samples/gdalinfo.py gdal/gdal/swig/python/scripts/gdalinfo.py && \
    cp gdal/gdal/swig/python/samples/ogrinfo.py gdal/gdal/swig/python/scripts/ogrinfo.py && \
    cp gdal/gdal/swig/python/samples/ogr2ogr.py gdal/gdal/swig/python/scripts/ogr2ogr.py

RUN cd gdal/gdal/swig/python && \
    for PYBIN in /opt/python/*/bin/; do \
      echo "${PYBIN}" && \
      "${PYBIN}/pip" wheel . -w /io/wheelhouse; \
    done && \
    for WHL in /io/wheelhouse/GDAL*.whl; do \
      auditwheel repair --plat manylinux2010_x86_64 "${WHL}" -w /io/wheelhouse/; \
    done && \
    ls -l /io/wheelhouse

# Mapnik

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://www.freedesktop.org/software/harfbuzz/release/harfbuzz-2.1.1.tar.bz2 -L -o harfbuzz.tar.bz2 && \
    mkdir harfbuzz && \
    tar -jxf harfbuzz.tar.bz2 -C harfbuzz --strip-components 1 && \
    rm -f harfbuzz.tar.bz2 && \
    cd harfbuzz && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# scons needs to have a modern python in the path, but scons in the included
# python 3.7 doesn't support parallel builds, so use python 3.6.
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch https://github.com/mapnik/mapnik.git && \
    cd mapnik && \
    git submodule update --init -j ${JOBS} && \
    export PATH="/opt/python/cp36-cp36m/bin:$PATH" && \
    # python scons/scons.py configure JOBS=${JOBS} CXX=${CXX} CC=${CC} \
    python scons/scons.py configure JOBS=${JOBS} \
    BOOST_INCLUDES=/usr/local/include BOOST_LIBS=/usr/local/lib \
    ICU_INCLUDES=/usr/local/include ICU_LIBS=/usr/local/lib \
    HB_INCLUDES=/usr/local/include HB_LIBS=/usr/local/lib \
    PNG_INCLUDES=/usr/local/include PNG_LIBS=/usr/local/lib \
    JPEG_INCLUDES=/usr/local/include JPEG_LIBS=/usr/local/lib \
    TIFF_INCLUDES=/usr/local/include TIFF_LIBS=/usr/local/lib \
    WEBP_INCLUDES=/usr/local/include WEBP_LIBS=/usr/local/lib \
    PROJ_INCLUDES=/usr/local/include PROJ_LIBS=/usr/local/lib \
    SQLITE_INCLUDES=/usr/local/include SQLITE_LIBS=/usr/local/lib \
    RASTERLITE_INCLUDES=/usr/local/include RASTERLITE_LIBS=/usr/local/lib \
    CUSTOM_DEFINES="-DACCEPT_USE_OF_DEPRECATED_PROJ_API_H=1" \
    WARNING_CXXFLAGS="-Wno-unused-variable -Wno-unused-but-set-variable -Wno-attributes -Wno-unknown-pragmas -Wno-maybe-uninitialized" \
    QUIET=true \
    CPP_TESTS=false \
    && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN python -c $'# \n\
import os \n\
path = os.popen("find /opt/_internal -name policy.json").read().strip() \n\
data = open(path).read().replace( \n\
    "GLIBCXX", "XGLIBCXX") \n\
open(path, "w").write(data)'

# Strip libraries before building any wheels
RUN strip --strip-unneeded /usr/local/lib/*.{so,a}

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone https://github.com/mapnik/python-mapnik.git && \
    cd python-mapnik && \
    git submodule update --init -j ${JOBS}
# Copy the mapnik input sources and fonts to the python path and add them via
# setup.py.  Modify the paths.py file that gets created to refer to the
# relative location of these files.
# Merge with above
RUN cd python-mapnik && \
    cp -r /usr/local/lib/mapnik/* mapnik/. && \
    cp -r /usr/local/share/{proj,gdal,epsg_csv} mapnik/. && \
    python -c $'# \n\
path = "setup.py" \n\
s = open(path).read().replace( \n\
    "\'share/*/*\'", \n\
    """\'share/*/*\', \'input/*\', \'fonts/*\', \'proj/*\', \'gdal/*\', \n\
    \'epsg_csv\'""").replace( \n\
    "path=font_path))", """path=font_path)) \n\
    f_paths.write("localpath = os.path.dirname(os.path.abspath( __file__ ))\\\\n") \n\
    f_paths.write("mapniklibpath = os.path.join(localpath, \'.libs\')\\\\n") \n\
    f_paths.write("mapniklibpath = os.path.normpath(mapniklibpath)\\\\n") \n\
    f_paths.write("inputpluginspath = os.path.join(localpath, \'input\')\\\\n") \n\
    f_paths.write("fontscollectionpath = os.path.join(localpath, \'fonts\')\\\\n") \n\
""") \n\
open(path, "w").write(s)' && \
    python -c $'# \n\
path = "mapnik/__init__.py" \n\
s = open(path).read().replace( \n\
    "def bootstrap_env():", \n\
""" \n\
localpath = os.path.dirname(os.path.abspath( __file__ )) \n\
os.environ.setdefault("PROJ_LIB", os.path.join(localpath, "proj")) \n\
os.environ.setdefault("GDAL_DATA", os.path.join(localpath, "gdal")) \n\
os.environ.setdefault("GEOTIFF_CSV", os.path.join(localpath, "epsg_csv")) \n\
\n\
def bootstrap_env():""") \n\
open(path, "w").write(s)'
# Build the wheels
RUN cd python-mapnik && \
    for PYBIN in /opt/python/*/bin/; do \
      echo "${PYBIN}" && \
      export BOOST_PYTHON_LIB=`"${PYBIN}/python" -c "import sys;sys.stdout.write('boost_python'+str(sys.version_info.major)+str(sys.version_info.minor))"` && \
      echo "${BOOST_PYTHON_LIB}" && \
      "${PYBIN}/pip" wheel . -w /io/wheelhouse; \
    done && \
    for WHL in /io/wheelhouse/mapnik*.whl; do \
      auditwheel repair --plat manylinux2010_x86_64 "${WHL}" -w /io/wheelhouse/ || exit 1; \
    done && \
    ls -l /io/wheelhouse

# VIPS

# ImageMagick
RUN yum install -y \
    bzip2-devel \
    fftw3-devel

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch https://github.com/ImageMagick/ImageMagick.git ImageMagick && \
    cd ImageMagick && \
    ./configure --silent --prefix=/usr/local --with-modules LIBS=-lrt && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN yum install -y \
    libexif-devel \
    matio-devel \
    OpenEXR-devel

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://github.com/GStreamer/orc/archive/orc-0.4.28.tar.gz -L -o orc.tar.gz && \
    mkdir orc && \
    tar -zxf orc.tar.gz -C orc --strip-components 1 && \
    rm -f orc.tar.gz && \
    cd orc && \
    autoreconf -ifv && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://downloads.sourceforge.net/project/niftilib/nifticlib/nifticlib_2_0_0/nifticlib-2.0.0.tar.gz -L -o nifti.tar.gz && \
    mkdir nifti && \
    tar -zxf nifti.tar.gz -C nifti --strip-components 1 && \
    rm -f nifti.tar.gz && \
    cd nifti && \
    cmake -DBUILD_SHARED_LIBS=ON . && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent http://heasarc.gsfc.nasa.gov/FTP/software/fitsio/c/cfitsio3450.tar.gz -L -o cfitsio.tar.gz && \
    mkdir cfitsio && \
    tar -zxf cfitsio.tar.gz -C cfitsio --strip-components 1 && \
    rm -f cfitsio.tar.gz && \
    cd cfitsio && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://github.com/ImageOptim/libimagequant/archive/2.12.2.tar.gz -L -o imagequant.tar.gz && \
    mkdir imagequant && \
    tar -zxf imagequant.tar.gz -C imagequant --strip-components 1 && \
    rm -f imagequant.tar.gz && \
    cd imagequant && \
    ./configure --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# vips does't currently have PDFium, poppler, librsvg, pango, libgsf.  Many of
# those would need to be compiled with newer subdependencies

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://github.com/libvips/libvips/releases/download/v8.8.0/vips-8.8.0.tar.gz -L -o vips.tar.gz && \
    mkdir vips && \
    tar -zxf vips.tar.gz -C vips --strip-components 1 && \
    rm -f vips.tar.gz && \
    cd vips && \
    ./configure --silent --prefix=/usr/local CFLAGS="`pkg-config --cflags glib-2.0`" LIBS="`pkg-config --libs glib-2.0`" && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# Strip libraries before building any wheels
RUN strip --strip-unneeded /usr/local/lib/*.{so,a}

RUN git clone --depth=1 --single-branch https://github.com/libvips/pyvips && \
    cd pyvips && \
    python -c $'# \n\
path = "pyvips/__init__.py" \n\
s = open(path).read().replace( \n\
"""    import _libvips""",  \n\
"""    import ctypes \n\
    import os \n\
    libpath = os.path.abspath(os.path.join(os.path.dirname(os.path.realpath( \n\
        __file__)), \'..\', \'.libs_libvips\')) \n\
    if os.path.exists(libpath): \n\
        libs = os.listdir(libpath) \n\
        libvipspath = [lib for lib in libs if lib.startswith(\'libvips\')][0] \n\
        ctypes.cdll.LoadLibrary(os.path.join(libpath, libvipspath)) \n\
    import _libvips""") \n\
open(path, "w").write(s)' && \
    for PYBIN in /opt/python/*/bin/; do \
      echo "${PYBIN}" && \
      "${PYBIN}/pip" wheel . -w /io/wheelhouse; \
    done && \
    for WHL in /io/wheelhouse/pyvips*.whl; do \
      auditwheel repair --plat manylinux2010_x86_64 "${WHL}" -w /io/wheelhouse/; \
    done && \
    ls -l /io/wheelhouse

# It might be nice to package executables for different packages with the
# wheel.  For vips, the executables are build in /build/vips/tools/.libs .
# Including these in the setup.py scripts key prevents bundling the libraries
# properly (at least as done below).
#
#     python -c $'# \n\
# path = "setup.py" \n\
# data = open(path).read() \n\
# data = data.replace( \n\
#     "from os import path", \n\
#     "from os import path\\n" + \n\
#     "import glob") \n\
# data = data.replace( \n\
#     "zip_safe=False,", \n\
#     "zip_safe=False,\\n" + \n\
#     "        scripts=glob.glob(\'../vips/tools/.libs/*\'),") \n\
# open(path, "w").write(data)'

# Remake pyproj -- something is changing libproj
RUN cd pyproj && \
    rm -f /io/wheelhouse/pyproj* && \
    for PYBIN in /opt/python/*/bin/; do \
      echo "${PYBIN}" && \
      "${PYBIN}/pip" install cython && \
      "${PYBIN}/pip" wheel . -w /io/wheelhouse; \
    done && \
    for WHL in /io/wheelhouse/pyproj*.whl; do \
      auditwheel repair "${WHL}" -w /io/wheelhouse/; \
    done && \
    ls -l /io/wheelhouse

# Install a utility to recompress wheel (zip) files to make them smaller
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://github.com/amadvance/advancecomp/releases/download/v2.1/advancecomp-2.1.tar.gz -L -o advancecomp.tar.gz && \
    mkdir advancecomp && \
    tar -zxf advancecomp.tar.gz -C advancecomp --strip-components 1 && \
    rm -f advancecomp.tar.gz && \
    cd advancecomp && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN advzip /io/wheelhouse/*many*.whl -k -z
