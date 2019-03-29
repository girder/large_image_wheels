FROM quay.io/pypa/manylinux1_x86_64
# When I try to use dockcross/manylinux-x64, some of the references to certain
# libraries, like sqlite3, seem to be broken
# FROM dockcross/manylinux-x64

RUN mkdir /build
WORKDIR /build

RUN yum install -y \
    xz \
    # for easier development
    man \
    vim-enhanced

# Update autotools, perl, m4, pkg-config

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl http://pkgconfig.freedesktop.org/releases/pkg-config-0.29.2.tar.gz -L -o pkg-config.tar.gz && \
    mkdir pkg-config && \
    tar -zxf pkg-config.tar.gz -C pkg-config --strip-components 1 && \
    cd pkg-config && \
    ./configure --prefix=/usr/local --with-internal-glib --disable-host-tool && \
    make -j ${JOBS} && \
    make -j ${JOBS} install

# 1.4.17
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl ftp://ftp.gnu.org/gnu/m4/m4-latest.tar.gz -L -o m4.tar.gz && \
    mkdir m4 && \
    tar -zxf m4.tar.gz -C m4 --strip-components 1 && \
    cd m4 && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install

# RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
#     curl -L http://install.perlbrew.pl | bash && \
#     . ~/perl5/perlbrew/etc/bashrc && \
#     echo '. /root/perl5/perlbrew/etc/bashrc' >> /etc/bashrc && \
#     perlbrew install perl-5.29.0 -j ${JOBS} -n && \
#     perlbrew switch perl-5.29.0

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl https://www.cpan.org/src/5.0/perl-5.28.1.tar.gz -L -o perl.tar.gz && \
    mkdir perl && \
    tar -zxf perl.tar.gz -C perl --strip-components 1 && \
    cd perl && \
    ./Configure -des -Dprefix=/usr/localperl && \
    make -j ${JOBS} && \
    make -j ${JOBS} install

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
   curl http://ftp.gnu.org/gnu/automake/automake-1.16.1.tar.gz -L -o automake.tar.gz && \
    mkdir automake && \
    tar -zxf automake.tar.gz -C automake --strip-components 1 && \
    cd automake && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install

# 2.69 ?
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl http://ftp.gnu.org/gnu/autoconf/autoconf-latest.tar.gz -L -o autoconf.tar.gz && \
    mkdir autoconf && \
    tar -zxf autoconf.tar.gz -C autoconf --strip-components 1 && \
    cd autoconf && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl http://ftp.gnu.org/gnu/libtool/libtool-2.4.6.tar.gz -L -o libtool.tar.gz && \
    mkdir libtool && \
    tar -zxf libtool.tar.gz -C libtool --strip-components 1 && \
    cd libtool && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install

# CMake

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl https://cmake.org/files/v3.11/cmake-3.11.4.tar.gz -L -o cmake.tar.gz && \
    mkdir cmake && \
    tar -zxf cmake.tar.gz -C cmake --strip-components 1 && \
    cd cmake && \
    ./bootstrap && \
    make -j ${JOBS} && \
    make -j ${JOBS} install

# Strip libraries before building any wheels
RUN strip --strip-unneeded /usr/local/lib/*.{so,a}

# Packages used by large_image that don't have published wheels for all the
# versions of Python we are using.

# Don't build python 3.4 wheels.
RUN rm -r /opt/python/cp34*

RUN git clone --depth=1 --single-branch -b release-5.6.0 https://github.com/giampaolo/psutil.git && \
    cd psutil && \
    for PYBIN in /opt/python/*/bin/; do \
      echo "${PYBIN}" && \
      "${PYBIN}/pip" wheel . -w /io/wheelhouse; \
    done && \
    for WHL in /io/wheelhouse/psutil*.whl; do \
      auditwheel repair "${WHL}" -w /io/wheelhouse/; \
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

RUN yum install -y \
    zlib-devel

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl https://github.com/OSGeo/proj.4/releases/download/6.0.0/proj-6.0.0.tar.gz -L -o proj.tar.gz && \
    mkdir proj && \
    tar -zxf proj.tar.gz -C proj --strip-components 1 && \
    cd proj && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

# As of 3/8/2019, pyproj 2.0.0 is published as wheels for all versions of
# python we care about.
# # pyproj isn't currently published for Python 3.7.
# RUN git clone --depth=1 --single-branch https://github.com/jswhit/pyproj && \
#     cd pyproj && \
#     for PYBIN in /opt/python/*/bin/; do \
#       echo "${PYBIN}" && \
#       "${PYBIN}/pip" install cython && \
#       "${PYBIN}/pip" wheel . -w /io/wheelhouse; \
#     done && \
#     for WHL in /io/wheelhouse/pyproj*.whl; do \
#       auditwheel repair "${WHL}" -w /io/wheelhouse/; \
#     done && \
#     ls -l /io/wheelhouse

# OpenJPEG

RUN yum install -y \
    # needed for openjpeg
    lcms2-devel \
    libpng-devel \
    zlib-devel

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl https://github.com/uclouvain/openjpeg/archive/v2.3.0.tar.gz -L -o openjpeg.tar.gz && \
    mkdir openjpeg && \
    tar -zxf openjpeg.tar.gz -C openjpeg --strip-components 1 && \
    cd openjpeg && \
    cmake . && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

# libtiff

# Note: This doesn't support GL

RUN yum install -y \
    # needed for libtiff
    giflib-devel \
    freeglut-devel \
    libjpeg-devel \
    libXi-devel \
    mesa-libGL-devel \
    mesa-libGLU-devel \
    SDL-devel \
    xz-devel

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl https://www.cl.cam.ac.uk/~mgk25/jbigkit/download/jbigkit-2.1.tar.gz -L -o jbigkit.tar.gz && \
    mkdir jbigkit && \
    tar -zxf jbigkit.tar.gz -C jbigkit --strip-components 1 && \
    cd jbigkit && \
    python -c $'# \n\
path = "Makefile" \n\
s = open(path).read().replace("-O2 ", "-O2 -fPIC ") \n\
open(path, "w").write(s)' && \
    make -j ${JOBS} && \
    cp {libjbig,pbmtools}/*.{o,so,a} /usr/local/lib/. || true && \
    cp libjbig/*.h /usr/local/include/. && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl http://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.0.0.tar.gz -L -o libwebp.tar.gz && \
    mkdir libwebp && \
    tar -zxf libwebp.tar.gz -C libwebp --strip-components 1 && \
    cd libwebp && \
    ./configure --prefix=/usr/local --enable-libwebpmux --enable-libwebpdecoder --enable-libwebpextras && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl https://github.com/facebook/zstd/releases/download/v1.3.7/zstd-1.3.7.tar.gz -L -o zstd.tar.gz && \
    mkdir zstd && \
    tar -zxf zstd.tar.gz -C zstd --strip-components 1 && \
    cd zstd && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

# For 12-bit jpeg
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl https://github.com/libjpeg-turbo/libjpeg-turbo/archive/2.0.1.tar.gz -L -o libjpeg-turbo.tar.gz && \
    mkdir libjpeg-turbo && \
    tar -zxf libjpeg-turbo.tar.gz -C libjpeg-turbo --strip-components 1 && \
    cd libjpeg-turbo && \
    cmake -DWITH_12BIT=1 . && \
    make -j ${JOBS}

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl https://download.osgeo.org/libtiff/tiff-4.0.10.tar.gz -L -o tiff.tar.gz && \
    mkdir tiff && \
    tar -zxf tiff.tar.gz -C tiff --strip-components 1 && \
    cd tiff && \
    ./configure --prefix=/usr/local --enable-jpeg12 --with-jpeg12-include-dir=/build/libjpeg-turbo --with-jpeg12-lib=/build/libjpeg-turbo/libjpeg.so && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

# Rebuild openjpeg with our libtiff
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    cd openjpeg && \
    cmake . && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
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
      "${PYBIN}/pip" install "numpy==${NUMPY_VERSION}.*" && \
      "${PYBIN}/pip" wheel --no-deps . -w /io/wheelhouse; \
    done && \
    for WHL in /io/wheelhouse/libtiff*.whl; do \
      auditwheel repair "${WHL}" -w /io/wheelhouse/; \
    done && \
    ls -l /io/wheelhouse

# OpenSlide

ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/local/lib64/pkgconfig:/usr/lib64/pkgconfig

RUN yum install -y \
    # needed for openslide
    cairo-devel \
    libtool

# Install newer versions of glib2, gdk-pixbuf2, libxml2.
# In our setup.py, we may want to confirm glib2 >= 2.25.9

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl http://ftp.gnome.org/pub/gnome/sources/glib/2.25/glib-2.25.9.tar.gz -L -o glib-2.tar.gz && \
    mkdir glib-2 && \
    tar -zxf glib-2.tar.gz -C glib-2 --strip-components 1 && \
    cd glib-2 && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl https://ftp.gnome.org/pub/gnome/sources/gdk-pixbuf/2.21/gdk-pixbuf-2.21.7.tar.gz -L -o gdk-pixbuf-2.tar.gz && \
    mkdir gdk-pixbuf-2 && \
    tar -zxf gdk-pixbuf-2.tar.gz -C gdk-pixbuf-2 --strip-components 1 && \
    cd gdk-pixbuf-2 && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl http://xmlsoft.org/sources/libxml2-2.7.8.tar.gz -L -o libxml2.tar.gz && \
    mkdir libxml2 && \
    tar -zxf libxml2.tar.gz -C libxml2 --strip-components 1 && \
    cd libxml2 && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
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
    curl https://github.com/openslide/openslide/archive/v3.4.1.tar.gz -L -o openslide.tar.gz && \
    mkdir openslide && \
    tar -zxf openslide.tar.gz -C openslide --strip-components 1 && \
    cd openslide && \
    autoreconf -ifv && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

COPY openslide-vendor-mirax.c.patch .

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    cd openslide && \
    patch src/openslide-vendor-mirax.c ../openslide-vendor-mirax.c.patch && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
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
      auditwheel repair "${WHL}" -w /io/wheelhouse/ || exit 1; \
    done && \
    ls -l /io/wheelhouse

# GDAL

# Install newer GCC

RUN yum install -y \
    zip

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl https://ftp.gnu.org/gnu/make/make-4.2.tar.bz2 -L -o gnumake.tar.bz2 && \
    mkdir gnumake && \
    tar -jxf gnumake.tar.bz2 -C gnumake --strip-components 1 && \
    cd gnumake && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl ftp://gcc.gnu.org/pub/gcc/infrastructure/gmp-6.1.0.tar.bz2 -L -o gmp.tar.bz2 && \
    mkdir gmp && \
    tar -jxf gmp.tar.bz2 -C gmp --strip-components 1 && \
    cd gmp && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl ftp://gcc.gnu.org/pub/gcc/infrastructure/mpfr-3.1.4.tar.bz2 -L -o mpfr.tar.bz2 && \
    mkdir mpfr && \
    tar -jxf mpfr.tar.bz2 -C mpfr --strip-components 1 && \
    cd mpfr && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl ftp://gcc.gnu.org/pub/gcc/infrastructure/mpc-1.0.3.tar.gz -L -o mpc.tar.gz && \
    mkdir mpc && \
    tar -zxf mpc.tar.gz -C mpc --strip-components 1 && \
    cd mpc && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig
# Can also try 4.9.4, 5.5.0, 6.5.0, 7.3.0, 8.2.0
# gdal needs at least 5.x
# This took 48 minutes on machine P
ENV GCC_VERSION=8.2
ENV GCC_FULL_VERSION=8.2.0
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl ftp://gcc.gnu.org/pub/gcc/releases/gcc-${GCC_FULL_VERSION}/gcc-${GCC_FULL_VERSION}.tar.gz -L -o gcc.tar.gz && \
    mkdir gcc && \
    tar -zxf gcc.tar.gz -C gcc --strip-components 1 && \
    mkdir gcc_build && \
    cd gcc_build && \
    ../gcc/configure --prefix=/usr/local --disable-multilib --enable-checking=release && \
    make --quiet -j ${JOBS} && \
    make --quiet -j ${JOBS} install && \
    ldconfig
ENV CC=/usr/local/bin/gcc
ENV CPP=/usr/local/bin/cpp
# We could use the following for the preprocessor
# ENV CPP="/usr/local/bin/gcc -E"
ENV CXX=/usr/local/bin/g++

# Boost

RUN yum install -y \
    openssl-devel

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl https://ftp.gnu.org/pub/gnu/libiconv/libiconv-1.15.tar.gz -L -o libiconv.tar.gz && \
    mkdir libiconv && \
    tar -zxf libiconv.tar.gz -C libiconv --strip-components 1 && \
    cd libiconv && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl http://download.icu-project.org/files/icu4c/63.1/icu4c-63_1-src.tgz -L -o icu4c.tar.gz && \
    mkdir icu4c && \
    tar -zxf icu4c.tar.gz -C icu4c --strip-components 1 && \
    cd icu4c/source && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl https://download.open-mpi.org/release/open-mpi/v3.1/openmpi-3.1.3.tar.gz -L -o openmpi.tar.gz && \
    mkdir openmpi && \
    tar -zxf openmpi.tar.gz -C openmpi --strip-components 1 && \
    cd openmpi && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

# This works with 1.62.0, 1.66.0
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch -b boost-1.66.0 https://github.com/boostorg/boost.git && cd boost && git submodule update --init -j ${JOBS} && \
    echo "using gcc : ${GCC_VERSION} : /usr/local/bin/g++ ; " > tools/build/src/user-config.jam && \
    echo "using python : 3.6 : /opt/python/cp36-cp36m/bin/python : /opt/python/cp36-cp36m/include/python3.6m : /opt/python/cp36-cp36m/lib ; " >> tools/build/src/user-config.jam && \
    ./bootstrap.sh --prefix=/usr/local --with-toolset=gcc && \
    ./b2 -j ${JOBS} toolset=gcc variant=release cxxflags="-std=c++14" headers && \
    ./b2 -j ${JOBS} toolset=gcc variant=release cxxflags="-std=c++14 -Wno-parentheses -Wno-deprecated-declarations -Wno-unused-variable" && \
    ./b2 -j ${JOBS} toolset=gcc variant=release cxxflags="-std=c++14" install && \
    ldconfig
# Boost won't compile against python 2 and 3 properly at the same time, so
# after compiling with python 3, go back and do python 2.
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    cd boost && \
    echo "using gcc : ${GCC_VERSION} : /usr/local/bin/g++ ; " > tools/build/src/user-config.jam && \
    echo "using python : 2.7 : /opt/python/cp27-cp27mu/bin/python : /opt/python/cp27-cp27mu/include/python2.7 : /opt/python/cp27-cp27mu/lib ; " >> tools/build/src/user-config.jam && \
    ./bootstrap.sh --prefix=/usr/local --with-toolset=gcc variant=release --with-python=/opt/python/cp27-cp27mu/bin/python && \
    ./b2 -j ${JOBS} toolset=gcc variant=release cxxflags="-std=c++14" clean && \
    ./b2 -j ${JOBS} toolset=gcc variant=release cxxflags="-std=c++14" install && \
    ldconfig

RUN curl -L https://www.fossil-scm.org/index.html/uv/fossil-linux-x64-2.7.tar.gz -o fossil.tar.gz && \
    tar -zxf fossil.tar.gz && \
    mv fossil /usr/local/bin

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch https://github.com/svn2github/libproj && \
    cd libproj && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    fossil --user=root clone https://www.gaia-gis.it/fossil/freexl freexl.fossil && \
    mkdir freexl && \
    cd freexl && \
    fossil open ../freexl.fossil && \
    LIBS=-liconv ./configure --prefix=/usr/local && \
    LIBS=-liconv make -j ${JOBS} && \
    LIBS=-liconv make -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch https://github.com/libgeos/geos.git && \
    cd geos && \
    mkdir build && \
    cd build && \
    cmake .. && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    fossil --user=root clone https://www.gaia-gis.it/fossil/libspatialite libspatialite.fossil && \
    mkdir spatialite && \
    cd spatialite && \
    fossil open ../libspatialite.fossil && \
    ./configure --prefix=/usr/local --disable-geos370 && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch https://github.com/pierriko/libgeotiff && \
    cd libgeotiff && \
    AUTOHEADER=true autoreconf -ifv && \
    ./configure --prefix=/usr/local --with-zlib=yes --with-jpeg=yes --enable-incode-epsg && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl https://www.cairographics.org/releases/pixman-0.34.0.tar.gz -L -o pixman.tar.gz && \
    mkdir pixman && \
    tar -zxf pixman.tar.gz -C pixman --strip-components 1 && \
    cd pixman && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

# 1.6.35 works for rasterlite but not for gdal
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl https://downloads.sourceforge.net/libpng/libpng-1.2.59.tar.xz -L -o libpng.tar.xz && \
    unxz libpng.tar.xz && \
    mkdir libpng && \
    tar -xf libpng.tar -C libpng --strip-components 1 && \
    cd libpng && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl https://download.savannah.gnu.org/releases/freetype/freetype-2.9.tar.gz -L -o freetype.tar.gz && \
    mkdir freetype && \
    tar -zxf freetype.tar.gz -C freetype --strip-components 1 && \
    cd freetype && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

RUN curl https://www.cairographics.org/releases/cairo-1.16.0.tar.xz -L -o cairo.tar.xz && \
    unxz cairo.tar.xz && \
    mkdir cairo && \
    tar -xf cairo.tar -C cairo --strip-components 1 && \
    cd cairo && \
    CXXFLAGS='-Wno-implicit-fallthrough -Wno-cast-function-type' CFLAGS="$CFLAGS -Wl,--allow-multiple-definition" ./configure --prefix=/usr/local --disable-dependency-tracking && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch -b 1.x-master https://github.com/team-charls/charls && \
    cd charls && \
    mkdir build && \
    cd build && \
    cmake -DBUILD_SHARED_LIBS=ON .. && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    cp ../src/interface.h /usr/local/include/CharLS/. && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch -b v1.8.3 https://github.com/lz4/lz4.git && \
    cd lz4 && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    fossil --user=root clone https://www.gaia-gis.it/fossil/librasterlite2 librasterlite2.fossil && \
    mkdir rasterlite2 && \
    cd rasterlite2 && \
    fossil open ../librasterlite2.fossil && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

# fyba won't compile with GCC 8.2.0 (see issue #21 -- requires GCC < 6)
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch https://github.com/kartverket/fyba && \
    cd fyba && \
    autoreconf -ifv && \
    CC= CPP= CXX= ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl https://ftp.gnu.org/gnu/bison/bison-3.1.tar.xz -L -o bison.tar.xz && \
    unxz bison.tar.xz && \
    mkdir bison && \
    tar -xf bison.tar -C bison --strip-components 1 && \
    cd bison && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

# We need flex to build flex, but we have to build flex to get a newer version
RUN yum install -y \
    flex \
    help2man \
    texinfo

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl https://ftp.gnu.org/pub/gnu/gettext/gettext-0.19.8.tar.gz -L -o gettext.tar.gz && \
    mkdir gettext && \
    tar -zxf gettext.tar.gz -C gettext --strip-components 1 && \
    cd gettext && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch -b v2.6.4 https://github.com/westes/flex && \
    cd flex && \
    autoreconf -ifv && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

RUN yum install -y \
    curl-devel

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl https://www.opendap.org/pub/source/libdap-3.20.0.tar.gz -L -o libdap.tar.gz && \
    mkdir libdap && \
    tar -zxf libdap.tar.gz -C libdap --strip-components 1 && \
    cd libdap && \
    ./configure --prefix=/usr/local --enable-threads=posix && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

RUN yum install -y \
    docbook2X

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl https://github.com/libexpat/libexpat/archive/R_2_2_6.tar.gz -L -o libexpat.tar.gz && \
    mkdir libexpat && \
    tar -zxf libexpat.tar.gz -C libexpat --strip-components 1 && \
    cd libexpat/expat && \
    autoreconf -ifv && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

RUN yum install -y \
    gperf

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl https://www.freedesktop.org/software/fontconfig/release/fontconfig-2.13.1.tar.gz -L -o fontconfig.tar.gz && \
    mkdir fontconfig && \
    tar -zxf fontconfig.tar.gz -C fontconfig --strip-components 1 && \
    cd fontconfig && \
    autoreconf -ifv && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

# Build items necessary for netcdf support
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl https://support.hdfgroup.org/ftp/HDF5/releases/hdf5-1.10/hdf5-1.10.4/src/hdf5-1.10.4.tar.gz -L -o hdf5.tar.gz && \
    mkdir hdf5 && \
    tar -zxf hdf5.tar.gz -C hdf5 --strip-components 1 && \
    cd hdf5 && \
    autoreconf -ifv && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl https://www.unidata.ucar.edu/downloads/netcdf/ftp/netcdf-c-4.6.2.tar.gz -L -o netcdf.tar.gz && \
    mkdir netcdf && \
    tar -zxf netcdf.tar.gz -C netcdf --strip-components 1 && \
    cd netcdf && \
    autoreconf -ifv && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl https://github.com/json-c/json-c/archive/json-c-0.12.1-20160607.tar.gz -L -o json-c.tar.gz && \
    mkdir json-c && \
    tar -zxf json-c.tar.gz -C json-c --strip-components 1 && \
    cd json-c && \
    autoreconf -ifv && \
    CFLAGS='-Wno-implicit-fallthrough' ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

# These add more support to GDAL
RUN yum install -y \
    cfitsio-devel \
    hdf-devel \
    jasper-devel \
    libpqxx-devel \
    mysql-devel \
    ogdi-devel \
    pcre-devel

# --with-dods-root is where libdap is installed
# This works with master, v2.3.2, v2.4.0
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch -b v2.4.1 https://github.com/OSGeo/gdal.git && \
    cd gdal/gdal && \
    ./configure --prefix=/usr/local --with-cpp14 --without-libtool --with-jpeg12 --without-poppler --with-podofo --with-spatialite --with-mysql --with-liblzma --with-webp --with-epsilon --with-proj --with-podofo --with-hdf5 --with-dods-root=/usr/local --with-sosi --with-mysql --with-rasterlite2 --with-libjson-c=/usr/local && \
    make -j ${JOBS} USER_DEFS=-Werror && \
    cd apps && \
    make -j ${JOBS} USER_DEFS=-Werror test_ogrsf && \
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
    "gdal_version = \'2.3.0\'", \n\
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
      auditwheel repair "${WHL}" -w /io/wheelhouse/; \
    done && \
    ls -l /io/wheelhouse

# Mapnik

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl https://www.freedesktop.org/software/harfbuzz/release/harfbuzz-2.1.1.tar.bz2 -L -o harfbuzz.tar.bz2 && \
    mkdir harfbuzz && \
    tar -jxf harfbuzz.tar.bz2 -C harfbuzz --strip-components 1 && \
    cd harfbuzz && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

# scons needs to have a modern python in the path, but scons in the included
# python 3.7 doesn't support parallel builds, so use python 3.6.
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch https://github.com/mapnik/mapnik.git && \
    cd mapnik && \
    git submodule update --init -j ${JOBS} && \
    export PATH="/opt/python/cp36-cp36m/bin:$PATH" && \
    python scons/scons.py configure JOBS=${JOBS} CXX=${CXX} CC=${CC} BOOST_INCLUDES=/usr/local/include BOOST_LIBS=/usr/local/lib && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
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
      "${PYBIN}/pip" wheel . -w /io/wheelhouse; \
    done && \
    for WHL in /io/wheelhouse/mapnik*.whl; do \
      auditwheel repair "${WHL}" -w /io/wheelhouse/ || exit 1; \
    done && \
    ls -l /io/wheelhouse

# ImageMagick
RUN yum install -y \
    bzip2-devel \
    fftw3-devel

# ImageMagick references the wrong libgomp (probably because there is no
# pkgconfig file for it).
RUN rm -f /usr/lib64/libgomp.*

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    git clone --depth=1 --single-branch https://github.com/ImageMagick/ImageMagick.git ImageMagick && \
    cd ImageMagick && \
    ./configure --prefix=/usr/local --with-modules --without-fontconfig && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

# VIPS

RUN yum install -y \
    libexif-devel \
    matio-devel \
    OpenEXR-devel

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl https://github.com/GStreamer/orc/archive/orc-0.4.28.tar.gz -L -o orc.tar.gz && \
    mkdir orc && \
    tar -zxf orc.tar.gz -C orc --strip-components 1 && \
    cd orc && \
    autoreconf -ifv && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl https://downloads.sourceforge.net/project/niftilib/nifticlib/nifticlib_2_0_0/nifticlib-2.0.0.tar.gz -L -o nifti.tar.gz && \
    mkdir nifti && \
    tar -zxf nifti.tar.gz -C nifti --strip-components 1 && \
    cd nifti && \
    cmake -DBUILD_SHARED_LIBS=ON . && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl http://heasarc.gsfc.nasa.gov/FTP/software/fitsio/c/cfitsio3450.tar.gz -L -o cfitsio.tar.gz && \
    mkdir cfitsio && \
    tar -zxf cfitsio.tar.gz -C cfitsio --strip-components 1 && \
    cd cfitsio && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl https://github.com/ImageOptim/libimagequant/archive/2.12.2.tar.gz -L -o imagequant.tar.gz && \
    mkdir imagequant && \
    tar -zxf imagequant.tar.gz -C imagequant --strip-components 1 && \
    cd imagequant && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

# vips does't currently have PDFium, poppler, librsvg, pango, libgsf.  Many of
# thsoe require a newer gcc

RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl https://github.com/libvips/libvips/releases/download/v8.7.4/vips-8.7.4.tar.gz -L -o vips.tar.gz && \
    mkdir vips && \
    tar -zxf vips.tar.gz -C vips --strip-components 1 && \
    cd vips && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
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
      auditwheel repair "${WHL}" -w /io/wheelhouse/; \
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

# Install a utility to recompress wheel (zip) files to make them smaller
RUN export JOBS=`/opt/python/cp37-cp37m/bin/python -c "import multiprocessing; print(multiprocessing.cpu_count())"` && \
    curl https://github.com/amadvance/advancecomp/releases/download/v2.1/advancecomp-2.1.tar.gz -L -o advancecomp.tar.gz && \
    mkdir advancecomp && \
    tar -zxf advancecomp.tar.gz -C advancecomp --strip-components 1 && \
    cd advancecomp && \
    ./configure --prefix=/usr/local && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig

RUN advzip /io/wheelhouse/*many*.whl -k -z
