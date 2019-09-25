FROM quay.io/pypa/manylinux2010_x86_64

RUN mkdir /build
WORKDIR /build

ARG SOURCE_DATE_EPOCH
ENV SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1567045200} \
    CFLAGS=-g0

# Don't build python 3.4 wheels.
RUN rm -r /opt/python/cp34*

RUN yum install -y \
    zip \
    # for curl \
    openldap-devel \
    libidn2-devel \
    # for pylibmc \
    libmemcached-devel \
    # for openjpeg \
    lcms2-devel \
    # needed for libtiff \
    giflib-devel \
    freeglut-devel \
    libjpeg-devel \
    libXi-devel \
    libzstd-devel \
    mesa-libGL-devel \
    mesa-libGLU-devel \
    SDL-devel \
    xz-devel \
    # For glib2 \
    libtool \
    libxml2-devel \
    # For older glib2 \
    cairo-devel \
    # For util-linux \
    gettext \
    # We need flex to build a newer version of flex \
    flex \
    help2man \
    texinfo \
    # For expat \
    docbook2X \
    gperf \
    # for libdap \
    libuuid-devel \
    # more support for GDAL \
    hdf-devel \
    json-c12-devel \
    # for mysql \
    ncurses-devel \
    # for postrges \
    readline-devel \
    # for epsilon \
    bzip2-devel \
    popt-devel \
    # For ImageMagick \
    fftw3-devel \
    libexif-devel \
    matio-devel \
    OpenEXR-devel \
    # for easier development \
    man \
    vim-enhanced

# Patch autoreconf to better use GETTEXT
# See https://lists.gnu.org/archive/html/autoconf-patches/2015-10/msg00001.html
# for the patch logic
RUN sed -i 's/\^AM_GNU_GETTEXT_VERSION/\^AM_GNU_GETTEXT_\(REQUIRE_\)\?VERSION/g' /usr/local/bin/autoreconf

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

# Some of these paths are added later
ENV PKG_CONFIG=/usr/local/bin/pkg-config \
    PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/local/lib64/pkgconfig:/usr/lib64/pkgconfig:/usr/share/pkgconfig

# 1.4.17
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://ftp.gnu.org/gnu/m4/m4-latest.tar.gz -L -o m4.tar.gz && \
    mkdir m4 && \
    tar -zxf m4.tar.gz -C m4 --strip-components 1 && \
    rm -f m4.tar.gz && \
    cd m4 && \
    export CFLAGS="$CFLAGS -O2" && \
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
# There are newer versions of this, but version 1.1.1 doesn't work with some
# other libraries
# We can't use make parallelism here
RUN curl --retry 5 --silent https://www.openssl.org/source/openssl-1.0.2t.tar.gz -L -o openssl.tar.gz && \
    mkdir openssl && \
    tar -zxf openssl.tar.gz -C openssl --strip-components 1 && \
    rm -f openssl.tar.gz && \
    cd openssl && \
    ./config --prefix=/usr/local --openssldir=/usr/local/ssl shared zlib && \
    make --silent && \
    # using "all install_sw" rather than "install" to avoid installing docs
    make --silent all install_sw && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch -b libssh2-1.9.0 https://github.com/libssh2/libssh2.git && \
    cd libssh2 && \
    ./buildconf && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://github.com/curl/curl/releases/download/curl-7_66_0/curl-7.66.0.tar.gz -L -o curl.tar.gz && \
    mkdir curl && \
    tar -zxf curl.tar.gz -C curl --strip-components 1 && \
    rm -f curl.tar.gz && \
    cd curl && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# Perl - building from source seems to have less issues
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://www.cpan.org/src/5.0/perl-5.30.0.tar.xz -L -o perl.tar.xz && \
    unxz perl.tar.xz && \
    mkdir perl && \
    tar -xf perl.tar -C perl --strip-components 1 && \
    rm -f perl.tar && \
    cd perl && \
    ./Configure -des -Dprefix=/usr/localperl && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install-silent

RUN export PERL_MM_USE_DEFAULT=1 && \
    export PERL_EXTUTILS_AUTOINSTALL="--defaultdeps" && \
    /usr/localperl/bin/cpan -T ExtUtils::MakeMaker Archive::Cpio Archive::Zip && \
    git clone --single-branch --depth 1 -b 0.042 https://github.com/esoule/strip-nondeterminism.git && \
    cd strip-nondeterminism && \
    /usr/localperl/bin/perl Makefile.PL && \
    make && \
    make install

# CMake - use a precompiled binary
RUN curl --retry 5 --silent https://github.com/Kitware/CMake/releases/download/v3.15.3/cmake-3.15.3-Linux-x86_64.tar.gz -L -o cmake.tar.gz && \
    mkdir cmake && \
    tar -zxf cmake.tar.gz -C /usr/local --strip-components 1 && \
    rm -f cmake.tar.gz

# Packages used by large_image that don't have published wheels for all the
# versions of Python we are using.

RUN git clone --depth=1 --single-branch -b release-5.6.3 https://github.com/giampaolo/psutil.git && \
    cd psutil && \
    # Strip libraries before building any wheels \
    strip --strip-unneeded /usr/local/lib{,64}/*.{so,a} && \
    for PYBIN in /opt/python/*/bin/; do \
      echo "${PYBIN}" && \
      "${PYBIN}/pip" wheel . -w /io/wheelhouse; \
    done && \
    for WHL in /io/wheelhouse/psutil*.whl; do \
      auditwheel repair --plat manylinux2010_x86_64 "${WHL}" -w /io/wheelhouse/; \
    done && \
    /usr/localperl/bin/strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v /io/wheelhouse/*.whl && \
    ls -l /io/wheelhouse

RUN git clone --depth=1 --single-branch https://github.com/esnme/ultrajson.git && \
    cd ultrajson && \
    # Strip libraries before building any wheels \
    strip --strip-unneeded /usr/local/lib{,64}/*.{so,a} && \
    for PYBIN in /opt/python/*/bin/; do \
      echo "${PYBIN}" && \
      "${PYBIN}/pip" wheel . -w /io/wheelhouse; \
    done && \
    for WHL in /io/wheelhouse/ujson*.whl; do \
      auditwheel repair --plat manylinux1_x86_64 "${WHL}" -w /io/wheelhouse/; \
    done && \
    /usr/localperl/bin/strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v /io/wheelhouse/*.whl && \
    ls -l /io/wheelhouse

RUN git clone --depth=1 --single-branch -b 1.6.1 https://github.com/lericson/pylibmc.git && \
    cd pylibmc && \
    # Strip libraries before building any wheels \
    strip --strip-unneeded /usr/local/lib{,64}/*.{so,a} && \
    for PYBIN in /opt/python/*/bin/; do \
      echo "${PYBIN}" && \
      "${PYBIN}/pip" wheel . -w /io/wheelhouse; \
    done && \
    for WHL in /io/wheelhouse/ujson*.whl; do \
      auditwheel repair --plat manylinux1_x86_64 "${WHL}" -w /io/wheelhouse/; \
    done && \
    /usr/localperl/bin/strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v /io/wheelhouse/*.whl && \
    ls -l /io/wheelhouse

# As of 2019-05-21, there were bugs fixed in master that seem important, so use
# master rather than the last released version.
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

# OpenJPEG

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://downloads.sourceforge.net/libpng/libpng-1.6.37.tar.xz -L -o libpng.tar.xz && \
    unxz libpng.tar.xz && \
    mkdir libpng && \
    tar -xf libpng.tar -C libpng --strip-components 1 && \
    rm -f libpng.tar && \
    cd libpng && \
    autoreconf -ifv && \
    ./configure --silent --prefix=/usr/local LIBS="`pkg-config --libs zlib`" && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://github.com/uclouvain/openjpeg/archive/v2.3.1.tar.gz -L -o openjpeg.tar.gz && \
    mkdir openjpeg && \
    tar -zxf openjpeg.tar.gz -C openjpeg --strip-components 1 && \
    rm -f openjpeg.tar.gz && \
    cd openjpeg && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# libtiff

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
    curl --retry 5 --silent http://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.0.3.tar.gz -L -o libwebp.tar.gz && \
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
    curl --retry 5 --silent https://github.com/libjpeg-turbo/libjpeg-turbo/archive/2.0.3.tar.gz -L -o libjpeg-turbo.tar.gz && \
    mkdir libjpeg-turbo && \
    tar -zxf libjpeg-turbo.tar.gz -C libjpeg-turbo --strip-components 1 && \
    rm -f libjpeg-turbo.tar.gz && \
    cd libjpeg-turbo && \
    cmake -DWITH_12BIT=1 -DCMAKE_BUILD_TYPE=Release . && \
    make --silent -j ${JOBS}

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://download.osgeo.org/libtiff/tiff-4.0.10.tar.gz -L -o tiff.tar.gz && \
    mkdir tiff && \
    tar -zxf tiff.tar.gz -C tiff --strip-components 1 && \
    rm -f tiff.tar.gz && \
    cd tiff && \
    ./configure --prefix=/usr/local --enable-jpeg12 --with-jpeg12-include-dir=/build/libjpeg-turbo --with-jpeg12-lib=/build/libjpeg-turbo/libjpeg.so && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# Rebuild openjpeg with our libtiff
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    cd openjpeg/_build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# Use an older version of numpy -- we can work with newer versions, but have to
# have at least this version to use our wheel.
RUN git clone --depth=1 --single-branch -b wheel-support https://github.com/manthey/pylibtiff.git && \
    cd pylibtiff && \
    mkdir libtiff/bin && \
    find /build/tiff/tools/.libs/ -executable -type f -exec cp {} libtiff/bin/. \; && \
    python -c $'# \n\
path = "setup.py" \n\
s = open(path).read().replace( \n\
"""        configuration=configuration,""", \n\
"""        configuration=configuration, \n\
        include_package_data=True, \n\
        package_data={\'libtiff\': [\'bin/*\']},""") \n\
open(path, "w").write(s)' && \
    # Strip libraries before building any wheels \
    strip --strip-unneeded /usr/local/lib{,64}/*.{so,a} && \
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
    /usr/localperl/bin/strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v /io/wheelhouse/*.whl && \
    ls -l /io/wheelhouse

# Install newer versions of glib2, gdk-pixbuf2

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

RUN export PATH="/opt/python/cp36-cp36m/bin:$PATH" && \
    pip3 install meson

# Ninja 1.9.0 doesn't work with glib-2.61.2
RUN curl --retry 5 --silent https://github.com/ninja-build/ninja/releases/download/v1.8.2/ninja-linux.zip -L -o ninja.zip && \
    unzip ninja.zip && \
    rm -f ninja.zip && \
    mv ninja /usr/local/bin/.

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch -b v3.2.1 https://github.com/libffi/libffi.git && \
    cd libffi && \
    python -c $'# \n\
path = "Makefile.am" \n\
s = open(path).read().replace("info_TEXINFOS", "# info_TEXINFOS") \n\
open(path, "w").write(s)' && \
    ./autogen.sh && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch -b v2.34 https://github.com/karelzak/util-linux.git && \
    cd util-linux && \
    ./autogen.sh && \
    export CFLAGS="$CFLAGS -O2" && \
    ./configure --disable-all-programs --enable-libblkid --enable-libmount --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN python -c $'# \n\
import os \n\
path = os.popen("find /opt/_internal -name policy.json").read().strip() \n\
data = open(path).read().replace( \n\
    "libXext.so.6", "XlibXext.so.6").replace( \n\
    "libSM.so.6", "XlibSM.so.6").replace( \n\
    "libICE.so.6", "XlibICE.so.6") \n\
open(path, "w").write(data)'

# Build openslide with older glib2, gdk-pixbuf2, cairo

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://download.gnome.org/sources/glib/2.58/glib-2.58.3.tar.xz -L -o glib-2.tar.xz && \
    unxz glib-2.tar.xz && \
    mkdir glib-2 && \
    tar -xf glib-2.tar -C glib-2 --strip-components 1 && \
    rm -f glib-2.tar && \
    cd glib-2 && \
    egrep -lrZ -- '-version-info \$\(LT_CURRENT\):\$\(LT_REVISION\):\$\(LT_AGE\)' * | xargs -0 -l sed -i -e 's/-version-info \$(LT_CURRENT):\$(LT_REVISION):\$(LT_AGE)/-release liw-older/g' && \
    ./autogen.sh && \
    ./configure --prefix=/usr/local --libdir=/usr/local/lib64 --with-python=/opt/python/cp27-cp27mu/bin/python && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://ftp.acc.umu.se/pub/gnome/sources/gdk-pixbuf/2.36/gdk-pixbuf-2.36.12.tar.xz -L -o gdk-pixbuf-2.tar.xz && \
    unxz gdk-pixbuf-2.tar.xz && \
    mkdir gdk-pixbuf-2 && \
    tar -xf gdk-pixbuf-2.tar -C gdk-pixbuf-2 --strip-components 1 && \
    rm -f gdk-pixbuf-2.tar && \
    cd gdk-pixbuf-2 && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# This patch allows girder's file layout to work with mirax files and does no
# harm otherwise.
COPY openslide-vendor-mirax.c.patch .

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://github.com/openslide/openslide/archive/v3.4.1.tar.gz -L -o openslide.tar.gz && \
    mkdir openslide && \
    tar -zxf openslide.tar.gz -C openslide --strip-components 1 && \
    rm -f openslide.tar.gz && \
    cd openslide && \
    patch src/openslide-vendor-mirax.c ../openslide-vendor-mirax.c.patch && \
    autoreconf -ifv && \
    export CFLAGS="$CFLAGS -O2" && \
    ./configure --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# Tell auditwheel to use our updated files.
RUN python -c $'# \n\
import os \n\
path = os.popen("find /opt/_internal -name policy.json").read().strip() \n\
data = open(path).read().replace( \n\
    "libXrender.so.1", "XlibXrender.so.1").replace( \n\
    "libX11.so.6", "XlibX11.so.6") \n\
open(path, "w").write(data)'

RUN git clone --depth=1 --single-branch https://github.com/openslide/openslide-python.git && \
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
    mkdir openslide/bin && \
    find /build/openslide/tools/.libs/ -executable -type f -exec cp {} openslide/bin/. \; && \
    python -c $'# \n\
path = "setup.py" \n\
s = open(path).read().replace( \n\
"""    zip_safe=True,""", \n\
"""    zip_safe=True, \n\
    include_package_data=True, \n\
    package_data={\'openslide\': [\'bin/*\']},""") \n\
open(path, "w").write(s)' && \
    # Strip libraries before building any wheels \
    strip --strip-unneeded /usr/local/lib{,64}/*.{so,a} && \
    for PYBIN in /opt/python/*/bin/; do \
      echo "${PYBIN}" && \
      "${PYBIN}/pip" wheel . -w /io/wheelhouse; \
    done && \
    for WHL in /io/wheelhouse/openslide*.whl; do \
      auditwheel repair --plat manylinux2010_x86_64 "${WHL}" -w /io/wheelhouse/ || exit 1; \
    done && \
    /usr/localperl/bin/strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v /io/wheelhouse/*.whl && \
    ls -l /io/wheelhouse

RUN rm -rf glib-2 gdk-pixbuf2

# 2.59.x and above doesn't work with openslide on centos
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    export PATH="/opt/python/cp36-cp36m/bin:$PATH" && \
    curl --retry 5 --silent https://download.gnome.org/sources/glib/2.62/glib-2.62.0.tar.xz -L -o glib-2.tar.xz && \
    unxz glib-2.tar.xz && \
    mkdir glib-2 && \
    tar -xf glib-2.tar -C glib-2 --strip-components 1 && \
    rm -f glib-2.tar && \
    cd glib-2 && \
    python -c $'# \n\
path = "gio/meson.build" \n\
s = open(path).read().replace("library(\'gio-2.0\',", "library(\'gio-2.0-liw\',") \n\
open(path, "w").write(s)' && \
    python -c $'# \n\
path = "glib/meson.build" \n\
s = open(path).read().replace("library(\'glib-2.0\',", "library(\'glib-2.0-liw\',") \n\
open(path, "w").write(s)' && \
    python -c $'# \n\
path = "gmodule/meson.build" \n\
s = open(path).read().replace("library(\'gmodule-2.0\',", "library(\'gmodule-2.0-liw\',") \n\
open(path, "w").write(s)' && \
    python -c $'# \n\
path = "gobject/meson.build" \n\
s = open(path).read().replace("library(\'gobject-2.0\',", "library(\'gobject-2.0-liw\',") \n\
open(path, "w").write(s)' && \
    python -c $'# \n\
path = "gthread/meson.build" \n\
s = open(path).read().replace("library(\'gthread-2.0\',", "library(\'gthread-2.0-liw\',") \n\
open(path, "w").write(s)' && \
    meson --prefix=/usr/local --buildtype=release _build && \
    cd _build && \
    ninja -j ${JOBS} && \
    ninja -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://ftp.gnu.org/pub/gnu/gettext/gettext-0.20.1.tar.gz -L -o gettext.tar.gz && \
    mkdir gettext && \
    tar -zxf gettext.tar.gz -C gettext --strip-components 1 && \
    rm -f gettext.tar.gz && \
    cd gettext && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch -b v2.6.4 https://github.com/westes/flex.git && \
    cd flex && \
    autoreconf -ifv && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    export PATH="/opt/python/cp36-cp36m/bin:$PATH" && \
    curl --retry 5 --silent https://download.gnome.org/sources/gobject-introspection/1.62/gobject-introspection-1.62.0.tar.xz -L -o gobject-introspection.tar.xz && \
    unxz gobject-introspection.tar.xz && \
    mkdir gobject-introspection && \
    tar -xf gobject-introspection.tar -C gobject-introspection --strip-components 1 && \
    rm -f gobject-introspection.tar && \
    cd gobject-introspection && \
    python -c $'# \n\
path = "giscanner/shlibs.py" \n\
s = open(path).read().replace( \n\
"""    lib%s""", \n\
"""    lib%s(-liw|)""") \n\
open(path, "w").write(s)' && \
    meson --prefix=/usr/local --buildtype=release _build && \
    cd _build && \
    ninja -j ${JOBS} && \
    ninja -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    export PATH="/opt/python/cp36-cp36m/bin:$PATH" && \
    curl --retry 5 --silent https://download.gnome.org/sources/gdk-pixbuf/2.39/gdk-pixbuf-2.39.2.tar.xz -L -o gdk-pixbuf.tar.xz && \
    unxz gdk-pixbuf.tar.xz && \
    mkdir gdk-pixbuf && \
    tar -xf gdk-pixbuf.tar -C gdk-pixbuf --strip-components 1 && \
    rm -f gdk-pixbuf.tar && \
    cd gdk-pixbuf && \
    meson --prefix=/usr/local --buildtype=release -D gir=False -D x11=False -D builtin_loaders=all -D man=False _build && \
    cd _build && \
    ninja -j ${JOBS} && \
    ninja -j ${JOBS} install && \
    ldconfig

# Boost

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://ftp.gnu.org/pub/gnu/libiconv/libiconv-1.16.tar.gz -L -o libiconv.tar.gz && \
    mkdir libiconv && \
    tar -zxf libiconv.tar.gz -C libiconv --strip-components 1 && \
    rm -f libiconv.tar.gz && \
    cd libiconv && \
    export CFLAGS="$CFLAGS -O2" && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    export PATH="/opt/python/cp36-cp36m/bin:$PATH" && \
    curl --retry 5 --silent http://download.icu-project.org/files/icu4c/64.2/icu4c-64_2-src.tgz -L -o icu4c.tar.gz && \
    mkdir icu4c && \
    tar -zxf icu4c.tar.gz -C icu4c --strip-components 1 && \
    rm -f icu4c.tar.gz && \
    cd icu4c/source && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://download.open-mpi.org/release/open-mpi/v3.1/openmpi-3.1.4.tar.gz -L -o openmpi.tar.gz && \
    mkdir openmpi && \
    tar -zxf openmpi.tar.gz -C openmpi --strip-components 1 && \
    rm -f openmpi.tar.gz && \
    cd openmpi && \
    ./configure --silent --prefix=/usr/local --disable-dependency-tracking --enable-silent-rules --disable-dlopen && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# This works with boost 1.69.0.
# It probably won't work for 1.66.0 and before, as those versions didn't handle
# multiple python versions properly.
# 1.70.0 and 1.71.0 don't work with mapnik
#   (https://github.com/mapnik/mapnik/issues/4041)
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch -b boost-1.69.0 --quiet --recurse-submodules -j ${JOBS} https://github.com/boostorg/boost.git && \
    # curl --retry 5 --silent https://downloads.sourceforge.net/project/boost/boost/1.69.0/boost_1_69_0.tar.gz -L -o boost.tar.gz && \
    # mkdir boost && \
    # tar -zxf boost.tar.gz -C boost --strip-components 1 && \
    # rm -f boost.tar.gz && \
    cd boost && \
    rm -rf .git && \
    echo "" > tools/build/src/user-config.jam && \
    # echo "using mpi ;" >> tools/build/src/user-config.jam && \
    echo "using python : 2.7 : /opt/python/cp27-cp27mu/bin/python : /opt/python/cp27-cp27mu/include/python2.7 : /opt/python/cp27-cp27mu/lib ; " >> tools/build/src/user-config.jam && \
    echo "using python : 3.5 : /opt/python/cp35-cp35m/bin/python : /opt/python/cp35-cp35m/include/python3.5m : /opt/python/cp35-cp35m/lib ; " >> tools/build/src/user-config.jam && \
    echo "using python : 3.6 : /opt/python/cp36-cp36m/bin/python : /opt/python/cp36-cp36m/include/python3.6m : /opt/python/cp36-cp36m/lib ; " >> tools/build/src/user-config.jam && \
    echo "using python : 3.7 : /opt/python/cp37-cp37m/bin/python : /opt/python/cp37-cp37m/include/python3.7m : /opt/python/cp37-cp37m/lib ; " >> tools/build/src/user-config.jam && \
    ./bootstrap.sh --prefix=/usr/local --with-toolset=gcc variant=release && \
    ./b2 -d1 -j ${JOBS} toolset=gcc variant=release python=2.7,3.5,3.6,3.7 cxxflags="-std=c++14 -Wno-parentheses -Wno-deprecated-declarations -Wno-unused-variable -Wno-parentheses -Wno-maybe-uninitialized" install && \
    ldconfig

RUN curl --retry 5 --silent -L https://www.fossil-scm.org/index.html/uv/fossil-linux-x64-2.9.tar.gz -o fossil.tar.gz && \
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
    git clone --depth=1 --single-branch -b 3.7.2 https://github.com/libgeos/geos.git && \
    cd geos && \
    mkdir build && \
    cd build && \
    cmake -DGEOS_BUILD_DEVELOPER=NO -DCMAKE_BUILD_TYPE=Release .. && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    fossil --user=root clone https://www.gaia-gis.it/fossil/libspatialite libspatialite.fossil && \
    mkdir libspatialite && \
    cd libspatialite && \
    fossil open ../libspatialite.fossil && \
    # fossil checkout 7dcf78e2d0 && \
    rm -f ../libspatialite.fossil && \
    CFLAGS="$CFLAGS -O2 -DACCEPT_USE_OF_DEPRECATED_PROJ_API_H=true" ./configure --silent --prefix=/usr/local --disable-examples && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch -b 1.5.1 https://github.com/OSGeo/libgeotiff.git && \
    cd libgeotiff/libgeotiff && \
    autoreconf -ifv && \
    CFLAGS="$CFLAGS -DACCEPT_USE_OF_DEPRECATED_PROJ_API_H=true" ./configure --silent --prefix=/usr/local --with-zlib=yes --with-jpeg=yes && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://www.cairographics.org/releases/pixman-0.38.4.tar.gz -L -o pixman.tar.gz && \
    mkdir pixman && \
    tar -zxf pixman.tar.gz -C pixman --strip-components 1 && \
    rm -f pixman.tar.gz && \
    cd pixman && \
    export CFLAGS="$CFLAGS -O2" && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://download.savannah.gnu.org/releases/freetype/freetype-2.10.1.tar.gz -L -o freetype.tar.gz && \
    mkdir freetype && \
    tar -zxf freetype.tar.gz -C freetype --strip-components 1 && \
    rm -f freetype.tar.gz && \
    cd freetype && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://github.com/libexpat/libexpat/archive/R_2_2_8.tar.gz -L -o libexpat.tar.gz && \
    mkdir libexpat && \
    tar -zxf libexpat.tar.gz -C libexpat --strip-components 1 && \
    rm -f libexpat.tar.gz && \
    cd libexpat/expat && \
    autoreconf -ifv && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://www.freedesktop.org/software/fontconfig/release/fontconfig-2.13.92.tar.gz -L -o fontconfig.tar.gz && \
    mkdir fontconfig && \
    tar -zxf fontconfig.tar.gz -C fontconfig --strip-components 1 && \
    rm -f fontconfig.tar.gz && \
    cd fontconfig && \
    autoreconf -ifv && \
    export CFLAGS="$CFLAGS -O2" && \
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
    CXXFLAGS='-Wno-implicit-fallthrough -Wno-cast-function-type' CFLAGS="$CFLAGS -O2 -Wl,--allow-multiple-definition" ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch -b 1.x-master https://github.com/team-charls/charls.git && \
    cd charls && \
    mkdir build && \
    cd build && \
    cmake -DBUILD_SHARED_LIBS=ON -DCMAKE_BUILD_TYPE=Release .. && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    cp ../src/interface.h /usr/local/include/CharLS/. && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch -b v1.9.2 https://github.com/lz4/lz4.git && \
    cd lz4 && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://ftp.gnu.org/gnu/bison/bison-3.4.2.tar.xz -L -o bison.tar.xz && \
    unxz bison.tar.xz && \
    mkdir bison && \
    tar -xf bison.tar -C bison --strip-components 1 && \
    rm -f bison.tar && \
    cd bison && \
    export CFLAGS="$CFLAGS -O2" && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://www.opendap.org/pub/source/libdap-3.20.4.tar.gz -L -o libdap.tar.gz && \
    mkdir libdap && \
    tar -zxf libdap.tar.gz -C libdap --strip-components 1 && \
    rm -f libdap.tar.gz && \
    cd libdap && \
    ./configure --silent --prefix=/usr/local --enable-threads=posix && \
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
    git clone --depth=1 --single-branch https://github.com/kartverket/fyba.git && \
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

# Build items necessary for netcdf support
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://support.hdfgroup.org/ftp/HDF5/releases/hdf5-1.10/hdf5-1.10.5/src/hdf5-1.10.5.tar.gz -L -o hdf5.tar.gz && \
    mkdir hdf5 && \
    tar -zxf hdf5.tar.gz -C hdf5 --strip-components 1 && \
    rm -f hdf5.tar.gz && \
    cd hdf5 && \
    autoreconf -ifv && \
    # This library produces a lot of warnings; since we don't do anything \
    # about them, suppress them. \
    CFLAGS="$CFLAGS -w" ./configure --silent --prefix=/usr/local --enable-cxx --enable-optimization=high --enable-fortran && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://www.unidata.ucar.edu/downloads/netcdf/ftp/netcdf-c-4.7.1.tar.gz -L -o netcdf.tar.gz && \
    mkdir netcdf && \
    tar -zxf netcdf.tar.gz -C netcdf --strip-components 1 && \
    rm -f netcdf.tar.gz && \
    cd netcdf && \
    autoreconf -ifv && \
    export CFLAGS="$CFLAGS -O2" && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://dev.mysql.com/get/Downloads/MySQL-5.7/mysql-boost-5.7.27.tar.gz -L -o mysql.tar.gz && \
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
    rm -f ogdi.tar.gz && \
    cd ogdi && \
    export TOPDIR=`pwd` && \
    export CFLAGS="$CFLAGS -O2" && \
    ./configure --silent --prefix=/usr/local --with-zlib --with-expat && \
    make --silent && \
    make --silent install && \
    cp bin/Linux/*.so /usr/local/lib/. && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://ftp.postgresql.org/pub/source/v11.5/postgresql-11.5.tar.gz -L -o postgresql.tar.gz && \
    mkdir postgresql && \
    tar -zxf postgresql.tar.gz -C postgresql --strip-components 1 && \
    rm -f postgresql.tar.gz && \
    cd postgresql && \
    autoreconf -ifv && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    export PATH="/opt/python/cp36-cp36m/bin:$PATH" && \
    curl --retry 5 --silent https://poppler.freedesktop.org/poppler-0.81.0.tar.xz -L -o poppler.tar.xz && \
    unxz poppler.tar.xz && \
    mkdir poppler && \
    tar -xf poppler.tar -C poppler --strip-components 1 && \
    rm -f poppler.tar && \
    cd poppler && \
    mkdir build && \
    cd build && \
    cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local -DCMAKE_BUILD_TYPE=Release -DENABLE_UNSTABLE_API_ABI_HEADERS=on && \
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
    curl --retry 5 --silent https://sourceforge.net/projects/epsilon-project/files/epsilon/0.9.2/epsilon-0.9.2.tar.gz/download -L -o epsilon.tar.gz && \
    mkdir epsilon && \
    tar -zxf epsilon.tar.gz -C epsilon --strip-components 1 && \
    rm -f epsilon.tar.gz && \
    cd epsilon && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://download.osgeo.org/gdal/jasper-1.900.1.uuid.tar.gz -L -o jasper.tar.gz && \
    mkdir jasper && \
    tar -zxf jasper.tar.gz -C jasper --strip-components 1 && \
    rm -f jasper.tar.gz && \
    cd jasper && \
    export CFLAGS="$CFLAGS -O2 -fPIC" && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# We want the "obsolete-api" to be available for some packages (GDAL), but the
# base docker image has the newer api version installed.  When we install the
# older one, the install command complains about the extant version, but still
# works, so eat its errors.
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch -b v4.4.10 https://github.com/besser82/libxcrypt.git && \
    cd libxcrypt && \
    autoreconf -ifv && \
    CFLAGS="$CFLAGS -O2 -w" ./configure --silent --prefix=/usr/local --enable-obsolete-api --enable-hashes=all && \
    make --silent -j ${JOBS} && \
    (make --silent -j ${JOBS} install || true) && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch -b libgta-1.2.1 https://github.com/marlam/gta-mirror.git && \
    cd gta-mirror/libgta && \
    autoreconf -ifv && \
    export CFLAGS="$CFLAGS -O2" && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# This is an old version of libecw.  I am uncertain that the licensing allows
# for this to be used, and therefore is disabled for now.
# RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
#     curl --retry 5 --silent https://sourceforge.net/projects/libecw-legacy/files/libecwj2-3.3-2006-09-06.zip -L -o libecwj.zip && \
#     unzip libecwj.zip && \
#     rm -f libecwj.zip && \
#     cd libecwj2-3.3 && \
#     CXXFLAGS='-w' ./configure --silent --prefix=/usr/local && \
#     make --silent -j ${JOBS} && \
#     make --silent -j ${JOBS} install && \
#     ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://www-us.apache.org/dist/xerces/c/3/sources/xerces-c-3.2.2.tar.gz -L -o xerces-c.tar.gz && \
    mkdir xerces-c && \
    tar -zxf xerces-c.tar.gz -C xerces-c --strip-components 1 && \
    rm -f xerces-c.tar.gz && \
    cd xerces-c && \
    cmake -DCMAKE_BUILD_TYPE=Release . && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch -b v0.3.7 https://github.com/xianyi/OpenBLAS.git && \
    cd OpenBLAS && \
    mkdir build && \
    cd build && \
    cmake -DBUILD_SHARED_LIBS=True -DCMAKE_BUILD_TYPE=Release .. && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch -b v5.2.1 https://github.com/xiaoyeli/superlu.git && \
    cd superlu && \
    mkdir build && \
    cd build && \
    cmake -DBUILD_SHARED_LIBS=True -DCMAKE_BUILD_TYPE=Release -Denable_blaslib=OFF -Denable_tests=OFF -DTPL_BLAS_LIBRARIES=/usr/local/lib64/libopenblas.so .. && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent http://sourceforge.net/projects/arma/files/armadillo-9.700.2.tar.xz -L -o armadillo.tar.xz && \
    unxz armadillo.tar.xz && \
    mkdir armadillo && \
    tar -xf armadillo.tar -C armadillo --strip-components 1 && \
    rm -f armadillo.tar && \
    cd armadillo && \
    mkdir build && \
    cd build && \
    cmake -DBUILD_SHARED_LIBS=True -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local -DCMAKE_INSTALL_LIBDIR=lib .. && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# This build doesn't support everything.
# Unsupported without more work or investigation:
#  GRASS Kea Ingres Google-libkml ODBC FGDB MDB OCI GEORASTER SDE Rasdaman
#  SFCGAL OpenCL MongoDB MongoCXX HDFS TileDB
# Unused because there is a working alternative:
#  cryptopp (crypto/openssl)
#  podofo PDFium (poppler)
# Unsupported due to licensing that requires agreements/fees:
#  INFORMIX-DataBlade JP2Lura Kakadu MrSID MrSID/MG4-Lidar MSG RDB Teigha
# Unsupported due to licensing that might be allowed:
#  ECW
# Unused for other reasons:
#  DDS - uses crunch library which is for Windows
#  userfaultfd - linux support for this dates from 2015, so it probably can't
#    be added using manylinux2010.
# --with-dods-root is where libdap is installed
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    # git clone --depth=1 --single-branch -b v3.0.0 https://github.com/OSGeo/gdal.git && \
    git clone --depth=1 --single-branch https://github.com/OSGeo/gdal.git && \
    cd gdal/gdal && \
    export PATH="$PATH:/build/mysql/build/scripts" && \
    ./configure --prefix=/usr/local --with-cpp14 --without-libtool --with-jpeg12 --with-spatialite --with-liblzma --with-webp --with-epsilon --with-poppler --with-hdf5 --with-dods-root=/usr/local --with-sosi --with-mysql --with-rasterlite2 --with-pg --with-cfitsio=/usr/local --with-armadillo && \
    make -j ${JOBS} USER_DEFS="-Werror -Wno-missing-field-initializers -Wno-write-strings" && \
    cd apps && \
    make -j ${JOBS} USER_DEFS="-Werror -Wno-missing-field-initializers -Wno-write-strings" test_ogrsf && \
    cd .. && \
    make -j ${JOBS} install && \
    ldconfig

RUN cd gdal/gdal/swig/python && \
    cp -r /usr/local/share/{proj,gdal} osgeo/. && \
    mkdir osgeo/bin && \
    find /build/gdal/gdal/apps/ -executable -type f ! -name '*.cpp' -exec cp {} osgeo/bin/. \; && \
    find /build/libgeotiff/libgeotiff/bin/.libs -executable -type f -exec cp {} osgeo/bin/. \; && \
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
    "    package_data={\'osgeo\': [\'proj/*\', \'gdal/*\', \'bin/*\']},") \n\
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
caPath = "/etc/ssl/certs/ca-certificates.crt" \n\
if os.path.exists(caPath): \n\
    os.environ.setdefault("CURL_CA_BUNDLE", caPath) \n\
""") \n\
open(path, "w").write(s)' && \
    # Copy python ports of c utilities to scripts so they get bundled.
    cp samples/gdalinfo.py scripts/gdalinfo.py && \
    cp samples/ogrinfo.py scripts/ogrinfo.py && \
    cp samples/ogr2ogr.py scripts/ogr2ogr.py && \
    # Strip libraries before building any wheels \
    strip --strip-unneeded /usr/local/lib{,64}/*.{so,a} && \
    for PYBIN in /opt/python/*/bin/; do \
      echo "${PYBIN}" && \
      "${PYBIN}/pip" wheel . -w /io/wheelhouse; \
    done && \
    for WHL in /io/wheelhouse/GDAL*.whl; do \
      auditwheel repair --plat manylinux2010_x86_64 "${WHL}" -w /io/wheelhouse/; \
    done && \
    /usr/localperl/bin/strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v /io/wheelhouse/*.whl && \
    ls -l /io/wheelhouse

# Mapnik

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://www.freedesktop.org/software/harfbuzz/release/harfbuzz-2.6.1.tar.xz -L -o harfbuzz.tar.xz && \
    unxz harfbuzz.tar.xz && \
    mkdir harfbuzz && \
    tar -xf harfbuzz.tar -C harfbuzz --strip-components 1 && \
    rm -f harfbuzz.tar && \
    cd harfbuzz && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# scons needs to have a modern python in the path, but scons in the included
# python 3.7 doesn't support parallel builds, so use python 3.6.
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch --quiet --recurse-submodules -j ${JOBS} https://github.com/mapnik/mapnik.git && \
    cd mapnik && \
    rm -rf .git && \
    export PATH="/opt/python/cp36-cp36m/bin:$PATH" && \
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
    DEBUG=false \
    && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --quiet --recurse-submodules -j ${JOBS} https://github.com/mapnik/python-mapnik.git && \
    cd python-mapnik && \
    rm -rf .git && \
    # Copy the mapnik input sources and fonts to the python path and add them \
    # via setup.py.  Modify the paths.py file that gets created to refer to \
    # the relative location of these files. \
    cp -r /usr/local/lib/mapnik/* mapnik/. && \
    cp -r /usr/local/share/{proj,gdal} mapnik/. && \
    mkdir mapnik/bin && \
    cp /build/mapnik/utils/mapnik-render/mapnik-render mapnik/bin/. && \
    cp /build/mapnik/utils/mapnik-index/mapnik-index mapnik/bin/. && \
    cp /build/mapnik/utils/shapeindex/shapeindex mapnik/bin/. && \
    python -c $'# \n\
path = "setup.py" \n\
s = open(path).read().replace( \n\
    "\'share/*/*\'", \n\
    """\'share/*/*\', \'input/*\', \'fonts/*\', \'proj/*\', \'gdal/*\', \'bin/*\'""").replace( \n\
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
\n\
def bootstrap_env():""") \n\
open(path, "w").write(s)' && \
    # Strip libraries before building any wheels \
    strip --strip-unneeded /usr/local/lib{,64}/*.{so,a} && \
    for PYBIN in /opt/python/*/bin/; do \
      echo "${PYBIN}" && \
      export BOOST_PYTHON_LIB=`"${PYBIN}/python" -c "import sys;sys.stdout.write('boost_python'+str(sys.version_info.major)+str(sys.version_info.minor))"` && \
      echo "${BOOST_PYTHON_LIB}" && \
      "${PYBIN}/pip" wheel . -w /io/wheelhouse; \
    done && \
    for WHL in /io/wheelhouse/mapnik*.whl; do \
      auditwheel repair --plat manylinux2010_x86_64 "${WHL}" -w /io/wheelhouse/ || exit 1; \
    done && \
    /usr/localperl/bin/strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v /io/wheelhouse/*.whl && \
    ls -l /io/wheelhouse

# VIPS

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    export PATH="/opt/python/cp36-cp36m/bin:$PATH" && \
    curl --retry 5 --silent https://github.com/GStreamer/orc/archive/0.4.29.tar.gz -L -o orc.tar.gz && \
    mkdir orc && \
    tar -zxf orc.tar.gz -C orc --strip-components 1 && \
    rm -f orc.tar.gz && \
    cd orc && \
    meson --prefix=/usr/local --buildtype=release _build && \
    cd _build && \
    ninja -j ${JOBS} && \
    ninja -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://downloads.sourceforge.net/project/niftilib/nifticlib/nifticlib_2_0_0/nifticlib-2.0.0.tar.gz -L -o nifti.tar.gz && \
    mkdir nifti && \
    tar -zxf nifti.tar.gz -C nifti --strip-components 1 && \
    rm -f nifti.tar.gz && \
    cd nifti && \
    cmake -DBUILD_SHARED_LIBS=ON -DCMAKE_BUILD_TYPE=Release . && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://github.com/ImageOptim/libimagequant/archive/2.12.5.tar.gz -L -o imagequant.tar.gz && \
    mkdir imagequant && \
    tar -zxf imagequant.tar.gz -C imagequant --strip-components 1 && \
    rm -f imagequant.tar.gz && \
    cd imagequant && \
    ./configure --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    export PATH="/opt/python/cp36-cp36m/bin:$PATH" && \
    curl --retry 5 --silent http://ftp.gnome.org/pub/GNOME/sources/pango/1.44/pango-1.44.6.tar.xz -L -o pango.tar.xz && \
    unxz pango.tar.xz && \
    mkdir pango && \
    tar -xf pango.tar -C pango --strip-components 1 && \
    rm -f pango.tar && \
    cd pango && \
    meson --prefix=/usr/local --buildtype=release -D gir=False _build && \
    cd _build && \
    ninja -j ${JOBS} && \
    ninja -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    rm -rf libxml2* && \
    curl --retry 5 --silent http://xmlsoft.org/sources/libxml2-2.9.9.tar.gz -L -o libxml2.tar.gz && \
    mkdir libxml2 && \
    tar -zxf libxml2.tar.gz -C libxml2 --strip-components 1 && \
    rm -f libxml2.tar.gz && \
    cd libxml2 && \
    ./configure --prefix=/usr/local --with-python=/opt/python/cp36-cp36m && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl --retry 5 --silent https://ftp.gnome.org/pub/GNOME/sources/libcroco/0.6/libcroco-0.6.13.tar.xz -L -o libcroco.tar.xz && \
    unxz libcroco.tar.xz && \
    mkdir libcroco && \
    tar -xf libcroco.tar -C libcroco --strip-components 1 && \
    rm -f libcroco.tar && \
    cd libcroco && \
    export CFLAGS="$CFLAGS -O2" && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

RUN curl --retry 5 --silent https://sh.rustup.rs -sSf | sh -s -- -y

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    export PATH="$HOME/.cargo/bin:$PATH" && \
    curl --retry 5 --silent https://download.gnome.org/sources/librsvg/2.46/librsvg-2.46.0.tar.xz -L -o librsvg.tar.xz && \
    unxz librsvg.tar.xz && \
    mkdir librsvg && \
    tar -xf librsvg.tar -C librsvg --strip-components 1 && \
    rm -f librsvg.tar && \
    cd librsvg && \
    export CFLAGS="$CFLAGS -O2" && \
    ./configure --silent --prefix=/usr/local --disable-rpath --disable-introspection && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    export PATH="$HOME/.cargo/bin:$PATH" && \
    curl --retry 5 --silent https://download.gnome.org/sources/libgsf/1.14/libgsf-1.14.46.tar.xz -L -o libgsf.tar.xz && \
    unxz libgsf.tar.xz && \
    mkdir libgsf && \
    tar -xf libgsf.tar -C libgsf --strip-components 1 && \
    rm -f libgsf.tar && \
    cd libgsf && \
    export CFLAGS="$CFLAGS -O2" && \
    ./configure --silent --prefix=/usr/local --disable-introspection && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

# We could install more packages for better ImageMagick support:
#  Autotrace DJVU DPS FLIF FlashPIX Ghostscript Graphviz HEIC LQR RAQM RAW WMF
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch -b 7.0.8-66 https://github.com/ImageMagick/ImageMagick.git && \
    cd ImageMagick && \
    ./configure --prefix=/usr/local --with-modules --with-rsvg LIBS="-lrt `pkg-config --libs zlib`" && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

# vips does't currently have PDFium, libheif
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    export PATH="/opt/python/cp36-cp36m/bin:$PATH" && \
    curl --retry 5 --silent https://github.com/libvips/libvips/releases/download/v8.8.3/vips-8.8.3.tar.gz -L -o vips.tar.gz && \
    mkdir vips && \
    tar -zxf vips.tar.gz -C vips --strip-components 1 && \
    rm -f vips.tar.gz && \
    cd vips && \
    ./configure --prefix=/usr/local CFLAGS="$CFLAGS `pkg-config --cflags glib-2.0`" LIBS="`pkg-config --libs glib-2.0`" && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig

RUN git clone --depth=1 --single-branch https://github.com/libvips/pyvips.git && \
    cd pyvips && \
    python -c $'# \n\
path = "pyvips/__init__.py" \n\
s = open(path).read().replace( \n\
"""    import _libvips""", \n\
"""    import ctypes \n\
    import os \n\
    libpath = os.path.abspath(os.path.join(os.path.dirname(os.path.realpath( \n\
        __file__)), \'.libs\')) \n\
    if os.path.exists(libpath): \n\
        libs = os.listdir(libpath) \n\
        libvipspath = [lib for lib in libs if lib.startswith(\'libvips\')][0] \n\
        ctypes.cdll.LoadLibrary(os.path.join(libpath, libvipspath)) \n\
    from . import _libvips""") \n\
open(path, "w").write(s)' && \
    python -c $'# \n\
path = "pyvips/pyvips_build.py" \n\
s = open(path).read().replace( \n\
"""ffibuilder.set_source("_libvips",""", \n\
"""ffibuilder.set_source("pyvips._libvips",""") \n\
open(path, "w").write(s)' && \
    mkdir pyvips/bin && \
    find /build/vips/tools/.libs/ -executable -type f -exec cp {} pyvips/bin/. \; && \
    python -c $'# \n\
path = "setup.py" \n\
s = open(path).read().replace( \n\
"""        packages=pyvips_packages,""", \n\
"""        packages=pyvips_packages, \n\
        include_package_data=True, \n\
        package_data={\'pyvips\': [\'bin/*\']},""") \n\
open(path, "w").write(s)' && \
    # Strip libraries before building any wheels \
    strip --strip-unneeded /usr/local/lib{,64}/*.{so,a} && \
    for PYBIN in /opt/python/*/bin/; do \
      echo "${PYBIN}" && \
      "${PYBIN}/pip" wheel . -w /io/wheelhouse; \
    done && \
    for WHL in /io/wheelhouse/pyvips*.whl; do \
      auditwheel repair --plat manylinux2010_x86_64 "${WHL}" -w /io/wheelhouse/; \
    done && \
    /usr/localperl/bin/strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v /io/wheelhouse/*.whl && \
    ls -l /io/wheelhouse

# 3db99248c8155a0170d7b2696b397dab7e37fb9d (7/12/2019) is the last pyproj
# commit that supports Python 2.7.  As this ages, eventually more work may be
# needed.
RUN git clone --single-branch https://github.com/pyproj4/pyproj.git && \
    cd pyproj && \
    python -c $'# \n\
path = "pyproj/__init__.py" \n\
s = open(path).read() \n\
s = s.replace(\n\
    "import sys", \n\
"""import sys \n\
import os \n\
localpath = os.path.dirname(os.path.abspath( __file__ )) \n\
os.environ.setdefault("PROJ_LIB", os.path.join(localpath, "proj"))""") \n\
open(path, "w").write(s)' && \
    mkdir pyproj/bin && \
    find /build/proj.4/src/.libs/ -executable -type f ! -name '*.so.*' -exec cp {} pyproj/bin/. \; && \
    mkdir pyproj/bin/share && \
    cp -r /usr/local/share/proj pyproj/. && \
    python -c $'# \n\
import os \n\
path = "setup.py" \n\
data = open(path).read() \n\
data = data.replace( \n\
    "    return package_data", \n\
"""    package_data["pyproj"].extend(["bin/*", "proj/*"]) \n\
    return package_data""") \n\
open(path, "w").write(data)' && \
    # Strip libraries before building any wheels \
    strip --strip-unneeded /usr/local/lib{,64}/*.{so,a} && \
    # First build with the last 2.7 version \
    git stash && \
    git checkout 3db99248c8155a0170d7b2696b397dab7e37fb9d && \
    git stash pop && \
    for PYBIN in /opt/python/cp2*/bin/; do \
      echo "${PYBIN}" && \
      "${PYBIN}/pip" install --no-cache-dir cython && \
      "${PYBIN}/pip" wheel . -w /io/wheelhouse; \
    done && \
    git stash && \
    git checkout master && \
    python -c $'# \n\
path = "pyproj/__init__.py" \n\
s = open(path).read() \n\
s = s.replace("2.4.rc0", "2.4") \n\
open(path, "w").write(s)' && \
    git stash pop && \
    # now rebuild anything that can work with master \
    for PYBIN in /opt/python/cp3*/bin/; do \
      echo "${PYBIN}" && \
      "${PYBIN}/pip" install --no-cache-dir cython && \
      "${PYBIN}/pip" wheel . -w /io/wheelhouse; \
    done && \
    for WHL in /io/wheelhouse/pyproj*.whl; do \
      auditwheel repair --plat manylinux2010_x86_64 "${WHL}" -w /io/wheelhouse/; \
    done && \
    /usr/localperl/bin/strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v /io/wheelhouse/*.whl && \
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

RUN advzip /io/wheelhouse/*many*.whl -k -z && \
    md5sum /io/wheelhouse/*many*.whl
