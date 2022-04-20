FROM quay.io/pypa/manylinux2014_x86_64

RUN mkdir /build
WORKDIR /build

RUN \
    echo "`date` yum install" >> /build/log.txt && \
    yum install -y \
    # for strip-nondeterminism \
    cpanminus \
    # for curl \
    libidn2-devel \
    # needed for libtiff \
    freeglut-devel \
    libXi-devel \
    mesa-libGL-devel \
    mesa-libGLU-devel \
    SDL-devel \
    # for javabridge \
    java-1.8.0-openjdk-devel \
    zip \
    # for glib2 \
    libtool \
    libxml2-devel \
    # for gobject-introspection \
    flex \
    # for several packages \
    ninja-build \
    help2man \
    texinfo \
    # for boost \
    gettext-devel \
    libcroco-devel \
    # for expat \
    docbook2X \
    gperf \
    # for libdap \
    libuuid-devel \
    # more support for GDAL \
    json-c12-devel \
    # for mysql \
    ncurses-devel \
    # for postrges \
    readline-devel \
    # for epsilon \
    bzip2-devel \
    popt-devel \
    # for MrSID \
    tbb-devel \
    # for netcdf \
    hdf-devel \
    # for easier development \
    man \
    gtk-doc \
    vim-enhanced && \
    yum clean all && \
    echo "`date` yum install" >> /build/log.txt

ARG PYPY
# Don't build some versions of python.
RUN \
    echo "`date` rm python versions" >> /build/log.txt && \
    mkdir /opt/py && \
    ln -s /opt/python/* /opt/py/. && \
    # Enable all versions in boost as well \
    # rm -rf /opt/py/cp35* && \
    if [ "$PYPY" = true ]; then \
    echo "Only building pypy versions" && \
    rm -rf /opt/py/cp* && \
    true; \
    elif [ "$PYPY" = false ]; then \
    echo "Only building cpython versions" && \
    # rm -rf /opt/py/pp39* && \
    rm -rf /opt/py/pp* && \
    true; \
    else \
    echo "Building cpython and pypy versions" && \
    true; \
    fi && \
    echo "`date` rm python versions" >> /build/log.txt

ARG SOURCE_DATE_EPOCH
ENV SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1567045200} \
    HOSTNAME=large_image_wheels \
    CFLAGS="-g0 -O2 -DNDEBUG" \
    LDFLAGS="-Wl,--strip-debug,--strip-discarded,--discard-locals" \
    PYTHONDONTWRITEBYTECODE=1
#   PIP_USE_FEATURE="in-tree-build" \

# The manylinux environment uses a combination of LD_LIBRARY_PATH and
# ld.so.conf.d to specify library paths.  Values in ld.so.conf.d are added
# first, but by default only /usr/local/lib is before some system-ish paths,
# which causes issues in some builds.  This increases the priority of
# /usr/local/lib64
RUN echo "/usr/local/lib64" > /etc/ld.so.conf.d/01-manylinux.conf && \
    ldconfig

# Several build steps need to be in a python 3 environment; set up a virtualenv
# with a specific version.  This venv is added to the path so that it is
# available by default.
RUN \
    echo "`date` virtualenv" >> /build/log.txt && \
    export PATH="/opt/python/cp38-cp38/bin:$PATH" && \
    pip3 install --no-cache-dir virtualenv && \
    virtualenv -p python3.8 /venv && \
    echo "`date` virtualenv" >> /build/log.txt

COPY getver.py fix_record.py /usr/local/bin/

# The openslide-vendor-mirax.c.patch allows girder's file layout to work with
# mirax files and does no harm otherwise.
# The openslide-init.patch allows building vips from GitHub source
# (see https://github.com/libvips/libvips/issues/874)
COPY versions.txt mapnik_proj_transform.cpp.patch mapnik_setup.py.patch openslide-init.patch openslide-vendor-mirax.c.patch glymur.setup.py ./

# Newer version of pkg-config than available in manylinux2014
RUN \
    echo "`date` pkg-config" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    until timeout 60 git clone --depth=1 --single-branch -b pkg-config-`getver.py pkg-config` -c advice.detachedHead=false https://gitlab.freedesktop.org/pkg-config/pkg-config.git; do sleep 5; echo "retrying"; done && \
    cd pkg-config && \
    ./autogen.sh && \
    ./configure --silent --prefix=/usr/local --with-internal-glib --disable-host-tool --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    echo "`date` pkg-config" >> /build/log.txt

# Some of these paths are added later
ENV PKG_CONFIG=/usr/local/bin/pkg-config \
    PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/local/lib64/pkgconfig:/usr/share/pkgconfig \
    PATH="/venv/bin:$PATH"
# We had been doing:
#     PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/local/lib64/pkgconfig:/usr/lib64/pkgconfig:/usr/share/pkgconfig \
# but we don't want to find the built-in libraries, as if we bind to them, we
# are probably not be portable.

# CMake - use a precompiled binary
RUN \
    echo "`date` cmake" >> /build/log.txt && \
    curl --retry 5 --silent https://github.com/Kitware/CMake/releases/download/v`getver.py cmake`/cmake-`getver.py cmake`-Linux-x86_64.tar.gz -L -o cmake.tar.gz && \
    tar -zxf cmake.tar.gz -C /usr/local --strip-components 1 && \
    rm -f cmake.tar.gz && \
    echo "`date` cmake" >> /build/log.txt

# Make our own zlib so we don't depend on system libraries \
RUN \
    echo "`date` zlib" >> /build/log.txt && \
    export JOBS=`nproc` && \
    curl --retry 5 --silent https://zlib.net/zlib-`getver.py zlib`.tar.gz -L -o zlib.tar.gz && \
    mkdir zlib && \
    tar -zxf zlib.tar.gz -C zlib --strip-components 1 && \
    rm -f zlib.tar.gz && \
    cd zlib && \
    ./configure --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` zlib" >> /build/log.txt && \
cd /build && \
# \
# RUN \
    echo "`date` krb5" >> /build/log.txt && \
    export JOBS=`nproc` && \
    curl --retry 5 --silent https://kerberos.org/dist/krb5/`getver.py krb5 2`/krb5-`getver.py krb5`.tar.gz -L -o krb5.tar.gz && \
    mkdir krb5 && \
    tar -zxf krb5.tar.gz -C krb5 --strip-components 1 && \
    rm -f krb5.tar.gz && \
    cd krb5/src && \
    ./configure --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` krb5" >> /build/log.txt && \
cd /build && \
# \
# # Make our own openssl so we don't depend on system libraries. \
# RUN \
    echo "`date` openssl 1.1" >> /build/log.txt && \
    git clone --depth=1 --single-branch -b OpenSSL_`getver.py openssl-1.x` -c advice.detachedHead=false https://github.com/openssl/openssl.git openssl_1_1 && \
    cd openssl_1_1 && \
    ./config --prefix=/usr/local --openssldir=/usr/local/ssl shared zlib && \
    make --silent -j ${JOBS} && \
    # using "all install_sw" rather than "install" to avoid installing docs \
    make --silent -j ${JOBS} all install_sw && \
    ldconfig && \
    echo "`date` openssl 1.1" >> /build/log.txt && \
cd /build && \
# \
# RUN \
    echo "`date` openldap" >> /build/log.txt && \
    until timeout 60 git clone --depth=1 --single-branch -b OPENLDAP_REL_ENG_`getver.py openldap` -c advice.detachedHead=false https://git.openldap.org/openldap/openldap.git; do sleep 5; echo "retrying"; done && \
    cd openldap && \
    # Don't build tests or docs \
    sed -i 's/ tests doc//g' Makefile.in && \
    ./configure --silent --prefix=/usr/local --disable-slapd && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` openldap" >> /build/log.txt && \
cd /build && \
# \
# RUN \
    echo "`date` libssh2" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b libssh2-`getver.py libssh2` -c advice.detachedHead=false https://github.com/libssh2/libssh2.git && \
    cd libssh2 && \
    ./buildconf || (sed -i 's/m4_undefine/# m4_undefine/g' configure.ac && ./buildconf) && \
    ./configure --silent --prefix=/usr/local --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libssh2" >> /build/log.txt && \
cd /build && \
# \
# # Make our own curl so we don't depend on system libraries. \
# RUN \
    echo "`date` curl" >> /build/log.txt && \
    export JOBS=`nproc` && \
    curl --retry 5 --silent https://github.com/curl/curl/releases/download/curl-`getver.py curl`/curl-`getver.py curl 3 _ .`.tar.gz -L -o curl.tar.gz && \
    mkdir curl && \
    tar -zxf curl.tar.gz -C curl --strip-components 1 && \
    rm -f curl.tar.gz && \
    cd  curl && \
    ./configure --prefix=/usr/local --disable-static --with-openssl --with-ldap-lib=/usr/local/lib/libldap.so && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` curl" >> /build/log.txt

RUN \
    echo "`date` strip-nondeterminism" >> /build/log.txt && \
    cpanm Archive::Cpio && \
    git clone --depth=1 --single-branch -b `getver.py strip-nondeterminism` -c advice.detachedHead=false https://github.com/esoule/strip-nondeterminism.git && \
    cd strip-nondeterminism && \
    perl Makefile.PL && \
    make && \
    make install && \
    echo "`date` strip-nondeterminism" >> /build/log.txt

# Install a utility to recompress wheel (zip) files to make them smaller
RUN \
    echo "`date` advancecomp" >> /build/log.txt && \
    export JOBS=`nproc` && \
    curl --retry 5 --silent https://github.com/amadvance/advancecomp/releases/download/v`getver.py advancecomp`/advancecomp-`getver.py advancecomp`.tar.gz -L -o advancecomp.tar.gz && \
    mkdir advancecomp && \
    tar -zxf advancecomp.tar.gz -C advancecomp --strip-components 1 && \
    rm -f advancecomp.tar.gz && \
    cd advancecomp && \
    export CFLAGS="$CFLAGS -O3" && \
    export CXXFLAGS="$CXXFLAGS -O3" && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    # Because we will recompress all wheels, we can create them with no \
    # compression to save some time \
    sed -i 's/ZIP_DEFLATED/ZIP_STORED/g' /opt/_internal/pipx/venvs/auditwheel/lib/python3.9/site-packages/auditwheel/tools.py && \
    echo "`date` advancecomp" >> /build/log.txt

RUN \
    echo "`date` auditwheel" >> /build/log.txt && \
    # vips doesn't work with auditwheel 3.2 since the copylib doesn't adjust \
    # rpaths the same as 3.1.1.  Revert that aspect of the behavior. \
    sed -i 's/patcher.set_rpath(dest_path, dest_dir)/new_rpath = os.path.relpath(dest_dir, os.path.dirname(dest_path))\n        new_rpath = os.path.join('\''$ORIGIN'\'', new_rpath)\n        patcher.set_rpath(dest_path, new_rpath)/g' /opt/_internal/pipx/venvs/auditwheel/lib/python3.9/site-packages/auditwheel/repair.py && \
    # Tell auditwheel not to whitelist libz.so, libiXext.so, etc. \
    # Do whitelist libjvm.so \
    python -c $'# \n\
import os \n\
path = os.popen("find /opt/_internal -name manylinux-policy.json").read().strip() \n\
data = open(path).read().replace( \n\
    "libz.so.1", "Xlibz.so.1").replace( \n\
    "ZLIB", "XXZLIB").replace( \n\
    "libXext.so.6", "XlibXext.so.6").replace( \n\
    "libXrender.so.1", "XlibXrender.so.1").replace( \n\
    "libX11.so.6", "XlibX11.so.6").replace( \n\
    "libSM.so.6", "XlibSM.so.6").replace( \n\
    "libICE.so.6", "XlibICE.so.6").replace( \n\
    "libexpat.so.1", "Xlibexpat.so.1").replace( \n\
    "XlibXext.so.6", "libjvm.so") \n\
open(path, "w").write(data)' && \
    echo "`date` auditwheel" >> /build/log.txt

# Use an older version of numpy -- we can work with newer versions, but have to
# have at least this version to use our wheels.
RUN \
    echo "`date` numpy" >> /build/log.txt && \
    for PYBIN in /opt/py/*/bin/; do \
      echo "${PYBIN}" && \
      # earliest numpy wheel for 3.10 is 1.21.2 \
      if [[ "${PYBIN}" =~ "cp310" ]]; then \
        export NUMPY_VERSION="1.21"; \
      # earliest numpy wheel for 3.9 is 1.19.3 \
      elif [[ "${PYBIN}" =~ "cp39" ]]; then \
        export NUMPY_VERSION="1.19"; \
      # 3.8 can work with numpy 1.15, but numpy only started publishing 3.8 \
      # wheels at 1.17.1 \
      elif [[ "${PYBIN}" =~ "cp38" ]]; then \
        export NUMPY_VERSION="1.17"; \
      elif [[ "${PYBIN}" =~ "cp37" ]]; then \
        export NUMPY_VERSION="1.14"; \
      elif [[ "${PYBIN}" =~ "cp36" ]]; then \
        export NUMPY_VERSION="1.11"; \
      # earliest numpy wheel for pypy 3.7 is 1.20.0 \
      elif [[ "${PYBIN}" =~ "pp37" ]]; then \
        export NUMPY_VERSION="1.20"; \
      # earliest numpy wheel for pypy 3.8 is 1.22.0 \
      elif [[ "${PYBIN}" =~ "pp38" ]]; then \
        export NUMPY_VERSION="1.22"; \
      # fallback for anything else \
      else \
        export NUMPY_VERSION="1"; \
      fi && \
      "${PYBIN}/pip" install --no-cache-dir "numpy==${NUMPY_VERSION}.*"; \
    done && \
    echo "`date` numpy" >> /build/log.txt

# Build psutils for Python versions not published on pypi
RUN \
    echo "`date` psutil" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b release-`getver.py psutil` -c advice.detachedHead=false https://github.com/giampaolo/psutil.git && \
    cd psutil && \
    # Strip libraries before building any wheels \
    # strip --strip-unneeded -p -D /usr/local/lib{,64}/*.{so,a} && \
    find /usr/local \( -name '*.so' -o -name '*.a' \) -exec bash -c "strip -p -D --strip-unneeded {} -o /tmp/striped; if ! cmp {} /tmp/striped; then cp /tmp/striped {}; fi; rm -f /tmp/striped" \; && \
    if [ "$PYPY" = true ]; then \
    # If only building for pypy, we don't need to do anything, since we don't \
    # have pypy 3.6 \
    true; \
    else \
    # only build for python 3.6 \
    find /opt/py -mindepth 1 -name '*p36-*' -print0 | xargs -n 1 -0 -P 1 bash -c '"${0}/bin/pip" wheel . --no-deps -w /io/wheelhouse && rm -rf build' && \
    find /io/wheelhouse/ -name 'psutil*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} auditwheel repair --only-plat --plat manylinux2014_x86_64 -w /io/wheelhouse && \
    find /io/wheelhouse/ -name 'psutil*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v && \
    find /io/wheelhouse/ -name 'psutil*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} advzip -k -z && \
    ls -l /io/wheelhouse && \
    true; \
    fi && \
    rm -rf ~/.cache && \
    echo "`date` psutil" >> /build/log.txt

RUN \
    echo "`date` libzip" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py libzip` -c advice.detachedHead=false https://github.com/nih-at/libzip.git && \
    cd libzip && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_EXAMPLES=OFF && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libzip" >> /build/log.txt

RUN \
    echo "`date` lcms2" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b lcms`getver.py lcms2` -c advice.detachedHead=false https://github.com/mm2/Little-CMS.git && \
    cd Little-CMS && \
    ./configure --silent --prefix=/usr/local --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` lcms2" >> /build/log.txt

RUN \
    echo "`date` openjpeg" >> /build/log.txt && \
    export JOBS=`nproc` && \
    curl --retry 5 --silent https://github.com/uclouvain/openjpeg/archive/v`getver.py openjpeg`.tar.gz -L -o openjpeg.tar.gz && \
    mkdir openjpeg && \
    tar -zxf openjpeg.tar.gz -C openjpeg --strip-components 1 && \
    rm -f openjpeg.tar.gz && \
    cd openjpeg && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` openjpeg" >> /build/log.txt

RUN \
    echo "`date` libpng" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    curl --retry 5 --silent https://downloads.sourceforge.net/libpng/libpng-`getver.py libpng`.tar.xz -L -o libpng.tar.xz && \
    unxz libpng.tar.xz && \
    mkdir libpng && \
    tar -xf libpng.tar -C libpng --strip-components 1 && \
    rm -f libpng.tar && \
    cd libpng && \
    autoreconf -ifv && \
    ./configure --silent --prefix=/usr/local LIBS="`pkg-config --libs zlib`" --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libpng" >> /build/log.txt && \
cd /build && \
# \
# RUN \
    echo "`date` giflib" >> /build/log.txt && \
    export JOBS=`nproc` && \
    curl --retry 5 --silent https://sourceforge.net/projects/giflib/files/giflib-`getver.py giflib`.tar.gz/download -L -o giflib.tar.gz && \
    mkdir giflib && \
    tar -zxf giflib.tar.gz -C giflib --strip-components 1 && \
    rm -f giflib.tar.gz && \
    cd giflib && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` giflib" >> /build/log.txt && \
cd /build && \
# \
# RUN \
    echo "`date` zstd" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py zstd` -c advice.detachedHead=false https://github.com/facebook/zstd && \
    cd zstd && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` zstd" >> /build/log.txt && \
cd /build && \
# \
# RUN \
    echo "`date` jbigkit" >> /build/log.txt && \
    export JOBS=`nproc` && \
    curl --retry 5 --silent https://www.cl.cam.ac.uk/~mgk25/jbigkit/download/jbigkit-`getver.py jbigkit`.tar.gz -L -o jbigkit.tar.gz && \
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
    ldconfig && \
    echo "`date` jbigkit" >> /build/log.txt && \
cd /build && \
# \
# RUN \
    echo "`date` libwebp" >> /build/log.txt && \
    export JOBS=`nproc` && \
    curl --retry 5 --silent http://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-`getver.py libwebp`.tar.gz -L -o libwebp.tar.gz && \
    mkdir libwebp && \
    tar -zxf libwebp.tar.gz -C libwebp --strip-components 1 && \
    rm -f libwebp.tar.gz && \
    cd libwebp && \
    ./configure --silent --prefix=/usr/local --enable-libwebpmux --enable-libwebpdecoder --enable-libwebpextras --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libwebp" >> /build/log.txt && \
cd /build && \
# \
# # For 8 and 12-bit jpeg \
# RUN \
    echo "`date` libjpeg-turbo" >> /build/log.txt && \
    export JOBS=`nproc` && \
    curl --retry 5 --silent https://github.com/libjpeg-turbo/libjpeg-turbo/archive/`getver.py libjpeg-turbo`.tar.gz -L -o libjpeg-turbo.tar.gz && \
    mkdir libjpeg-turbo && \
    tar -zxf libjpeg-turbo.tar.gz -C libjpeg-turbo --strip-components 1 && \
    rm -f libjpeg-turbo.tar.gz && \
    cd libjpeg-turbo && \
    # build 8-bit \
    mkdir _build8 && \
    cd _build8 && \
    cmake -DWITH_12BIT=0 -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local .. && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    cd .. && \
    # build 12-bit in place \
    cmake -DWITH_12BIT=1 -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local . && \
    make clean && \
    make --silent -j ${JOBS} && \
    # don't install this; we reference it explicitly \
    echo "`date` libjpeg-turbo" >> /build/log.txt && \
cd /build && \
# \
# # libdeflate is faster than libzip \
# RUN \
    echo "`date` libdeflate" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py libdeflate` -c advice.detachedHead=false https://github.com/ebiggers/libdeflate.git && \
    cd libdeflate && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libdeflate" >> /build/log.txt

RUN \
    echo "`date` lerc" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py lerc` -c advice.detachedHead=false https://github.com/Esri/lerc.git && \
    cd lerc && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` lerc" >> /build/log.txt && \
cd /build && \
# \
# RUN \
    echo "`date` libhwy" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b `getver.py libhwy` -c advice.detachedHead=false https://github.com/google/highway.git && \
    cd highway && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF -DCMAKE_CXX_FLAGS='-DVQSORT_SECURE_SEED=0' && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libhwy" >> /build/log.txt && \
cd /build && \
# \
# RUN \
    echo "`date` openexr" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py openexr` -c advice.detachedHead=false https://github.com/AcademySoftwareFoundation/openexr.git && \
    cd openexr && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF -DOPENEXR_INSTALL_EXAMPLES=OFF && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` openexr" >> /build/log.txt && \
cd /build && \
# \
# RUN \
    echo "`date` libbrotli" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py libbrotli` -c advice.detachedHead=false https://github.com/google/brotli.git && \
    cd brotli && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libbrotli" >> /build/log.txt && \
cd /build && \
# \
# RUN \
    echo "`date` jpeg-xl" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py jpeg-xl` -c advice.detachedHead=false --recurse-submodules -j ${JOBS} https://gitlab.com/wg1/jpeg-xl.git && \
    cd jpeg-xl && \
    find . -name '.git' -exec rm -rf {} \+ && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF -DCMAKE_CXX_FLAGS='-fpermissive' -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_MANPAGES=OFF -DJPEGXL_ENABLE_BENCHMARK=OFF && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` jpeg-xl" >> /build/log.txt

RUN \
    echo "`date` xz" >> /build/log.txt && \
    export JOBS=`nproc` && \
    curl --retry 5 --silent https://downloads.sourceforge.net/project/lzmautils/xz-`getver.py xz`.tar.gz -L -o xz.tar.gz && \
    mkdir xz && \
    tar -zxf xz.tar.gz -C xz --strip-components 1 && \
    rm -f xz.tar.gz && \
    cd xz && \
    ./configure --silent --prefix=/usr/local --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` xz" >> /build/log.txt

RUN \
    echo "`date` libtiff" >> /build/log.txt && \
    export JOBS=`nproc` && \
    curl --retry 5 --silent https://download.osgeo.org/libtiff/tiff-`getver.py libtiff`.tar.gz -L -o tiff.tar.gz && \
    mkdir tiff && \
    tar -zxf tiff.tar.gz -C tiff --strip-components 1 && \
    rm -f tiff.tar.gz && \
    cd tiff && \
    ./configure --prefix=/usr/local \
    --disable-static \
    --enable-jpeg12 \
    --with-jpeg12-include-dir=/build/libjpeg-turbo \
    --with-jpeg12-lib=/build/libjpeg-turbo/libjpeg.so \
    | tee configure.output && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libtiff" >> /build/log.txt

# Rebuild openjpeg with our libtiff
RUN \
    echo "`date` openjpeg again" >> /build/log.txt && \
    export JOBS=`nproc` && \
    cd openjpeg/_build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED=ON -DBUILD_STATIC=OFF && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` openjpeg again" >> /build/log.txt

RUN \
    echo "`date` pylibtiff" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b  wheel-support-`getver.py pylibtiff` -c advice.detachedHead=false https://github.com/manthey/pylibtiff.git && \
    cd pylibtiff && \
    mkdir libtiff/bin && \
    find /build/tiff/tools/.libs/ -executable -type f -exec cp {} libtiff/bin/. \; && \
    strip libtiff/bin/* --strip-unneeded -p -D && \
    python -c $'# \n\
path = "libtiff/bin/__init__.py" \n\
s = """import os \n\
import sys \n\
\n\
def program(): \n\
    path = os.path.join(os.path.dirname(__file__), os.path.basename(sys.argv[0])) \n\
    os.execv(path, sys.argv) \n\
""" \n\
open(path, "w").write(s)' && \
    python -c $'# \n\
path = "setup.py" \n\
s = open(path).read().replace( \n\
"""        configuration=configuration,""", \n\
"""        configuration=configuration, \n\
        include_package_data=True, \n\
        package_data={\'libtiff\': [\'bin/*\']}, \n\
        entry_points={\'console_scripts\': [\'%s=libtiff.bin:program\' % name for name in os.listdir(\'libtiff/bin\') if not name.endswith(\'.py\')]},""") \n\
s = s.replace("name=\'libtiff\'", "name=\'pylibtiff\'") \n\
open(path, "w").write(s)' && \
    # Strip libraries before building any wheels \
    # strip --strip-unneeded -p -D /usr/local/lib{,64}/*.{so,a} && \
    find /usr/local \( -name '*.so' -o -name '*.a' \) -exec bash -c "strip -p -D --strip-unneeded {} -o /tmp/striped; if ! cmp {} /tmp/striped; then cp /tmp/striped {}; fi; rm -f /tmp/striped" \; && \
    for PYBIN in /opt/py/*/bin/; do \
      python -c $'# \n\
import numpy \n\
import re \n\
numpyver = ".".join(numpy.__version__.split(".")[:2]) \n\
path = "setup.py" \n\
s = open(path).read() \n\
s = re.sub(\n\
  r"install_requires=.*,", "install_requires=[\'numpy>='" + numpyver + r"$'\'],", s) \n\
open(path, "w").write(s)' && \
      "${PYBIN}/python" -c 'import libtiff' || true && \
      "${PYBIN}/pip" wheel --no-deps . -w /io/wheelhouse; \
    done && \
    find /io/wheelhouse/ -name '*libtiff*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} auditwheel repair --only-plat --plat manylinux2014_x86_64 -w /io/wheelhouse && \
    find /io/wheelhouse/ -name '*libtiff*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v && \
    find /io/wheelhouse/ -name '*libtiff*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} advzip -k -z && \
    ls -l /io/wheelhouse && \
    rm -rf ~/.cache && \
    echo "`date` pylibtiff" >> /build/log.txt

RUN \
    echo "`date` glymur" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py glymur` -c advice.detachedHead=false https://github.com/quintusdias/glymur.git && \
    # git clone https://github.com/quintusdias/glymur.git && \
    cd glymur && \
    # version 0.9.3's commit \
    # git checkout f4399d4e5e4fcb9e110e2af34515bcb08ff77053 && \
    mkdir glymur/bin && \
    # Copy some jpeg tools \
    find /usr/local/bin -executable -type f -name 'opj_*' -exec cp {} glymur/bin/. \; && \
    cp /build/libjpeg-turbo/_build8/{jpegtran,cjpeg,djpeg,rdjpgcom,wrjpgcom} glymur/bin/. && \
    strip glymur/bin/* --strip-unneeded -p -D && \
    python -c $'# \n\
path = "glymur/bin/__init__.py" \n\
s = """import os \n\
import sys \n\
\n\
def program(): \n\
    path = os.path.join(os.path.dirname(__file__), os.path.basename(sys.argv[0])) \n\
    os.execv(path, sys.argv) \n\
""" \n\
open(path, "w").write(s)' && \
    python -c $'# \n\
path = "glymur/config.py" \n\
s = open(path).read() \n\
s = s.replace("    path = find_library(libname)", \n\
"""    path = find_library(libname) \n\
    libpath = os.path.abspath(os.path.join(os.path.dirname(os.path.dirname(os.path.realpath( \n\
        __file__))), \'Glymur.libs\')) \n\
    if path is None and os.path.exists(libpath): \n\
        libs = os.listdir(libpath) \n\
        path = [lib for lib in libs if libname in lib][0] \n\
        path = os.path.join(libpath, path)""") \n\
open(path, "w").write(s)' && \
    # Import a premade setup.py \
    cp ../glymur.setup.py ./setup.py && rm -f setup.cfg && rm -f pyproject.toml && \
    # Don't convert the old one; it no longer exists \
#     python -c $'# \n\
# path = "setup.py" \n\
# s = open(path).read() \n\
# s = s.replace("\'numpy>=1.7.1\', ", "") \n\
# s = s.replace("from setuptools import setup", \n\
# """from setuptools import setup \n\
# import os \n\
# from distutils.core import Extension""") \n\
# s = s.replace(", \'tests\'", "") \n\
# s = s.replace("\'test_suite\': \'glymur.test\'", \n\
# """\'test_suite\': \'glymur.test\', \n\
# \'ext_modules\': [Extension(\'glymur.openjpeg\', [], libraries=[\'openjp2\'])]""") \n\
# s = s.replace("\'data/*.jpx\'", "\'data/*.jpx\', \'bin/*\'") \n\
# s = s.replace("\'console_scripts\': [", \n\
# """\'console_scripts\': [\'%s=glymur.bin:program\' % name for name in os.listdir(\'glymur/bin\') if not name.endswith(\'.py\')] + [""") \n\
# open(path, "w").write(s)' && \
    # It would be better to use the setup.cfg, but the extensions seem to be an issue \
#     python -c $'# \n\
# import os \n\
# path = "setup.cfg" \n\
# s = open(path).read() \n\
# s = s.replace("data/*.j2k", \n\
# """data/*.j2k \n\
#     bin/*""") \n\
# s = s.replace("console_scripts =", \n\
# "console_scripts =" + "".join("\\n\\t%s=glymur.bin:program" % name for name in os.listdir(\'glymur/bin\') if not name.endswith(\'.py\'))) \n\
# open(path, "w").write(s)' && \
    # Strip libraries before building any wheels \
    # strip --strip-unneeded -p -D /usr/local/lib{,64}/*.{so,a} && \
    find /usr/local \( -name '*.so' -o -name '*.a' \) -exec bash -c "strip -p -D --strip-unneeded {} -o /tmp/striped; if ! cmp {} /tmp/striped; then cp /tmp/striped {}; fi; rm -f /tmp/striped" \; && \
    find /opt/py -mindepth 1 -not -name '*p36-*' -print0 | xargs -n 1 -0 -P 1 bash -c '"${0}/bin/pip" wheel . --no-deps -w /io/wheelhouse && rm -rf build' && \
    find /io/wheelhouse/ -name 'Glymur*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} auditwheel repair --only-plat --plat manylinux2014_x86_64 -w /io/wheelhouse && \
    find /io/wheelhouse/ -name 'Glymur*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v && \
    find /io/wheelhouse/ -name 'Glymur*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} advzip -k -z && \
    ls -l /io/wheelhouse && \
    rm -rf ~/.cache && \
    echo "`date` glymur" >> /build/log.txt

# PINNED VERSION - last of its line
RUN \
    echo "`date` pcre" >> /build/log.txt && \
    export JOBS=`nproc` && \
    curl --retry 5 --silent https://downloads.sourceforge.net/project/pcre/pcre/8.45/pcre-8.45.tar.gz -L -o pcre.tar.gz && \
    mkdir pcre && \
    tar -zxf pcre.tar.gz -C pcre --strip-components 1 && \
    rm -f pcre.tar.gz && \
    cd pcre && \
    ./configure --silent --prefix=/usr/local --enable-unicode-properties --enable-pcre16 --enable-pcre32 --enable-jit --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` pcre" >> /build/log.txt

RUN \
    echo "`date` meson" >> /build/log.txt && \
    pip install --no-cache-dir meson && \
    echo "`date` meson" >> /build/log.txt

RUN \
    echo "`date` libffi" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py libffi` -c advice.detachedHead=false https://github.com/libffi/libffi.git && \
    cd libffi && \
    python -c $'# \n\
path = "Makefile.am" \n\
s = open(path).read().replace("info_TEXINFOS", "# info_TEXINFOS") \n\
open(path, "w").write(s)' && \
    ./autogen.sh && \
    ./configure --silent --prefix=/usr/local --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libffi" >> /build/log.txt

RUN \
    echo "`date` util-linux" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py util-linux` -c advice.detachedHead=false https://github.com/karelzak/util-linux.git && \
    cd util-linux && \
    sed -i 's/#ifndef UMOUNT_UNUSED/#ifndef O_PATH\n# define O_PATH 010000000\n#endif\n\n#ifndef UMOUNT_UNUSED/g' libmount/src/context_umount.c && \
    ./autogen.sh && \
    ./configure --disable-all-programs --enable-libblkid --enable-libmount --silent --prefix=/usr/local --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` util-linux" >> /build/log.txt

RUN \
    echo "`date` glib" >> /build/log.txt && \
    export JOBS=`nproc` && \
    curl --retry 5 --silent https://download.gnome.org/sources/glib/`getver.py glib 2`/glib-`getver.py glib`.tar.xz -L -o glib-2.tar.xz && \
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
    meson --prefix=/usr/local --buildtype=release -Dtests=False -Dglib_debug=disabled _build && \
    cd _build && \
    ninja -j ${JOBS} && \
    ninja -j ${JOBS} install && \
    ldconfig && \
    echo "`date` glib" >> /build/log.txt

RUN \
    echo "`date` gobject-introspection" >> /build/log.txt && \
    export JOBS=`nproc` && \
    curl --retry 5 --silent https://download.gnome.org/sources/gobject-introspection/`getver.py gobject-introspection 2`/gobject-introspection-`getver.py gobject-introspection`.tar.xz -L -o gobject-introspection.tar.xz && \
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
    python -c $'# \n\
path = "giscanner/meson.build" \n\
s = open(path).read() \n\
s = s[:s.index("install_subdir")] + s[s.index("flex"):] \n\
open(path, "w").write(s)' && \
    meson --prefix=/usr/local --buildtype=release _build && \
    cd _build && \
    ninja -j ${JOBS} && \
    ninja -j ${JOBS} install && \
    ldconfig && \
    echo "`date` gobject-introspection" >> /build/log.txt

RUN \
    echo "`date` gdk-pixbuf" >> /build/log.txt && \
    export JOBS=`nproc` && \
    curl --retry 5 --silent https://download.gnome.org/sources/gdk-pixbuf/`getver.py gdk-pixbuf 2`/gdk-pixbuf-`getver.py gdk-pixbuf`.tar.xz -L -o gdk-pixbuf.tar.xz && \
    unxz gdk-pixbuf.tar.xz && \
    mkdir gdk-pixbuf && \
    tar -xf gdk-pixbuf.tar -C gdk-pixbuf --strip-components 1 && \
    rm -f gdk-pixbuf.tar && \
    cd gdk-pixbuf && \
    meson --prefix=/usr/local --buildtype=release -Dbuiltin_loaders=all -Dman=False -Dinstalled_tests=False _build && \
    cd _build && \
    ninja -j ${JOBS} && \
    ninja -j ${JOBS} install && \
    ldconfig && \
    echo "`date` gdk-pixbuf" >> /build/log.txt

# Boost

RUN \
    echo "`date` libiconv" >> /build/log.txt && \
    export JOBS=`nproc` && \
    curl --retry 5 --silent https://ftp.gnu.org/pub/gnu/libiconv/libiconv-`getver.py libiconv`.tar.gz -L -o libiconv.tar.gz && \
    mkdir libiconv && \
    tar -zxf libiconv.tar.gz -C libiconv --strip-components 1 && \
    rm -f libiconv.tar.gz && \
    cd libiconv && \
    ./configure --silent --prefix=/usr/local --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libiconv" >> /build/log.txt

RUN \
    echo "`date` icu4c" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b release-`getver.py icu4c` -c advice.detachedHead=false https://github.com/unicode-org/icu.git && \
    cd icu/icu4c/source && \
    CFLAGS="$CFLAGS -DUNISTR_FROM_CHAR_EXPLICIT=explicit -DUNISTR_FROM_STRING_EXPLICIT=explicit -DU_CHARSET_IS_UTF8=1 -DU_NO_DEFAULT_INCLUDE_UTF_HEADERS=1 -DU_HIDE_OBSOLETE_UTF_OLD_H=1" ./configure --silent --prefix=/usr/local --disable-tests --disable-samples --with-data-packaging=library --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    # reduce docker size \
    rm -rf data/out/tmp && \
    ldconfig && \
    echo "`date` icu4c" >> /build/log.txt

RUN \
    echo "`date` fftw3" >> /build/log.txt && \
    export JOBS=`nproc` && \
    curl --retry 5 --silent https://fftw.org/pub/fftw/fftw-`getver.py fftw3`.tar.gz -L -o fftw3.tar.gz && \
    mkdir fftw3 && \
    tar -zxf fftw3.tar.gz -C fftw3 --strip-components 1 && \
    rm -f fftw3.tar.gz && \
    cd fftw3 && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=OFF -DENABLE_AVX=ON -DENABLE_AVX2=ON -DENABLE_SSE=ON -DENABLE_SSE2=ON -DENABLE_THREADS=ON && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` fftw3" >> /build/log.txt

# We can't add --disable-mpi-fortran, or parallel-netcdf doesn't build
RUN \
    echo "`date` openmpi" >> /build/log.txt && \
    export JOBS=`nproc` && \
    curl --retry 5 --silent https://download.open-mpi.org/release/open-mpi/v`getver.py openmpi 2`/openmpi-`getver.py openmpi`.tar.gz -L -o openmpi.tar.gz && \
    mkdir openmpi && \
    tar -zxf openmpi.tar.gz -C openmpi --strip-components 1 && \
    rm -f openmpi.tar.gz && \
    cd openmpi && \
    ./configure --silent --prefix=/usr/local --disable-dependency-tracking --enable-silent-rules --disable-dlopen --disable-libompitrace --disable-opal-btl-usnic-unit-tests --disable-picky --disable-debug --disable-mem-profile --disable-mem-debug --disable-static --disable-mpi-java -disable-oshmem-profile && \
    # make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    find . -name '*.a' -delete && \
    echo "`date` openmpi" >> /build/log.txt

# This works with boost 1.69.0 and with 1.70 and above with an update to spirit
# It probably won't work for 1.66.0 and before, as those versions didn't handle
# multiple python versions properly.
# Revisit the change to mpi when https://github.com/boostorg/mpi/issues/112 is
# resolved.
RUN \
    echo "`date` boost" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b boost-`getver.py boost` -c advice.detachedHead=false --quiet --recurse-submodules -j ${JOBS} https://github.com/boostorg/boost.git && \
    cd boost && \
    # pushd libs/spirit && \
    # # switch to a version of spirit that fixes a bug in 1.70 and 1.71 \
    # git fetch --depth=1000 && \
    # git checkout 10d027f && \
    # popd && \
    # work-around for https://github.com/boostorg/mpi/issues/112 /
    # sed -i 's/boost_mpi_python mpi/boost_mpi_python/g' libs/mpi/build/Jamfile.v2 && \
    find . -name '.git' -exec rm -rf {} \+ && \
    echo "" > tools/build/src/user-config.jam && \
    echo "using mpi : /usr/local/lib ;" >> tools/build/src/user-config.jam && \
    # echo "using mpi ;" >> tools/build/src/user-config.jam && \
    if [ "$PYPY" = true ]; then \
    echo "using python : 3.7 : /opt/py/pp37-pypy37_pp73/bin/python : /opt/py/pp37-pypy37_pp73/include : /opt/py/pp37-pypy37_pp73/lib ;" >> tools/build/src/user-config.jam && \
    echo "using python : 3.8 : /opt/py/pp38-pypy38_pp73/bin/python : /opt/py/pp38-pypy38_pp73/include/pypy3.8 : /opt/py/pp38-pypy38_pp73/lib/pypy3.8 ;" >> tools/build/src/user-config.jam && \
    echo "using python : 3.9 : /opt/py/pp39-pypy39_pp73/bin/python : /opt/py/pp39-pypy39_pp73/include/pypy3.9 : /opt/py/pp39-pypy39_pp73/lib/pypy3.9 ;" >> tools/build/src/user-config.jam && \
    export PYTHON_LIST="3.7,3.8,3.9" && \
    true; \
    else \
    echo "using python : 3.6 : /opt/py/cp36-cp36m/bin/python : /opt/py/cp36-cp36m/include/python3.6m : /opt/py/cp36-cp36m/lib ;" >> tools/build/src/user-config.jam && \
    echo "using python : 3.7 : /opt/py/cp37-cp37m/bin/python : /opt/py/cp37-cp37m/include/python3.7m : /opt/py/cp37-cp37m/lib ;" >> tools/build/src/user-config.jam && \
    echo "using python : 3.8 : /opt/py/cp38-cp38/bin/python : /opt/py/cp38-cp38/include/python3.8 : /opt/py/cp38-cp38/lib ;" >> tools/build/src/user-config.jam && \
    echo "using python : 3.9 : /opt/py/cp39-cp39/bin/python : /opt/py/cp39-cp39/include/python3.9 : /opt/py/cp39-cp39/lib ;" >> tools/build/src/user-config.jam && \
    echo "using python : 3.10 : /opt/py/cp310-cp310/bin/python : /opt/py/cp310-cp310/include/python3.10 : /opt/py/cp310-cp310/lib ;" >> tools/build/src/user-config.jam && \
    export PYTHON_LIST="3.6,3.7,3.8,3.9,3.10" && \
    true; \
    fi && \
    ./bootstrap.sh --prefix=/usr/local --with-toolset=gcc variant=release && \
    # Only build the libraries we need; building boost is slow \
    ./b2 -d1 -j ${JOBS} toolset=gcc variant=release link=shared --build-type=minimal \
    --with-filesystem \
    --with-thread \
    --with-regex \
    --with-atomic \
    --with-system \
    --with-python \
    --with-program_options \
    python="$PYTHON_LIST" \
    cxxflags="-std=c++14 -Wno-parentheses -Wno-deprecated-declarations -Wno-unused-variable -Wno-parentheses -Wno-maybe-uninitialized -Wno-attributes" \
    install && \
    # pypy \
    # This conflicts with the non-pypy version \
    # echo "" > tools/build/src/user-config.jam && \
    # echo "using mpi ;" >> tools/build/src/user-config.jam && \
    # echo "using python : 3.7 : /opt/py/pp37-pypy37_pp73/bin/python : /opt/py/pp37-pypy37_pp73/include : /opt/py/pp37-pypy37_pp73/lib ;" >> tools/build/src/user-config.jam && \
    # ./bootstrap.sh --prefix=/usr/local --with-toolset=gcc variant=release && \
    # ./b2 -d1 -j ${JOBS} toolset=gcc variant=release link=shared --build-type=minimal python=3.7 cxxflags="-std=c++14 -Wno-parentheses -Wno-deprecated-declarations -Wno-unused-variable -Wno-parentheses -Wno-maybe-uninitialized" install && \
    # common \
    ldconfig && \
    echo "`date` boost" >> /build/log.txt

RUN \
    echo "`date` fossil" >> /build/log.txt && \
    # fossil executable \
    curl --retry 5 --silent -L https://fossil-scm.org/home/uv/fossil-linux-x64-`getver.py fossil`.tar.gz -o fossil.tar.gz && \
    tar -zxf fossil.tar.gz && \
    mv fossil /usr/local/bin/. && \
    rm -f fossil.tar.gz && \
    # # fossil from source \
    # # Previously, we had to build fossil to allow it to work in our
    # # environment.  The prebuilt binaries fail because they can't find any of
    # # a list of versions of GLIBC.
    # curl --retry 5 --silent -L https://fossil-scm.org/home/tarball/f48180f2ff3169651a725396d4f7d667c99a92873b9c3df7eee2f144be7a0721/fossil-src-2.17.tar.gz -o fossil.tar.gz && \
    # mkdir fossil && \
    # tar -zxf fossil.tar.gz -C fossil --strip-components 1 && \
    # rm -f fossil.tar.gz && \
    # cd fossil && \
    # ./configure --prefix=/usr/local --disable-static && \
    # make --silent -j ${JOBS} && \
    # make --silent -j ${JOBS} install && \
    # ldconfig && \
    echo "`date` fossil" >> /build/log.txt

RUN \
    echo "`date` sqlite" >> /build/log.txt && \
    export JOBS=`nproc` && \
    curl --retry 5 --silent https://sqlite.org/`getver.py sqlite 1`/sqlite-autoconf-`getver.py sqlite 2 . . 1`.tar.gz -L -o sqlite.tar.gz && \
    mkdir sqlite && \
    tar -zxf sqlite.tar.gz -C sqlite --strip-components 1 && \
    rm -f sqlite.tar.gz && \
    cd sqlite && \
    ./configure --silent --prefix=/usr/local --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` sqlite" >> /build/log.txt

RUN \
    echo "`date` proj4" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b `getver.py proj4` -c advice.detachedHead=false https://github.com/OSGeo/proj.4.git && \
    cd proj.4 && \
    curl --retry 5 --silent http://download.osgeo.org/proj/proj-datumgrid-`getver.py proj-datumgrid`.zip -L -o proj-datumgrid.zip && \
    cd data && \
    unzip -o ../proj-datumgrid.zip && \
    cd .. && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF && \
    # these cmake commands appear to be identical to just running make, but \
    # are the recommended build process \
    cmake --build . -j ${JOBS} && \
    cmake --build . -j ${JOBS} --target install && \
    # make --silent -j ${JOBS} && \
    # make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` proj4" >> /build/log.txt

RUN \
    echo "`date` pyproj4" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --single-branch -b `getver.py pyproj4` -c advice.detachedHead=false https://github.com/pyproj4/pyproj.git && \
    cd pyproj && \
    mkdir pyproj/bin && \
    find /build/proj.4/_build/bin/ -executable -not -type d -exec bash -c 'cp --dereference /usr/local/bin/"$(basename {})" pyproj/bin/.' \; && \
    strip pyproj/bin/* --strip-unneeded -p -D && \
    python -c $'# \n\
path = "pyproj/bin/__init__.py" \n\
s = """import os \n\
import sys \n\
\n\
def program(): \n\
    environ = os.environ.copy() \n\
    localpath = os.path.dirname(os.path.abspath( __file__ )) \n\
    environ.setdefault("PROJ_LIB", os.path.join(localpath, "..", "proj")) \n\
\n\
    path = os.path.join(os.path.dirname(__file__), os.path.basename(sys.argv[0])) \n\
    os.execve(path, sys.argv, environ) \n\
""" \n\
open(path, "w").write(s)' && \
    cp -r /usr/local/share/proj pyproj/. && \
    # Strip libraries before building any wheels \
    # strip --strip-unneeded -p -D /usr/local/lib{,64}/*.{so,a} && \
    find /usr/local \( -name '*.so' -o -name '*.a' \) -exec bash -c "strip -p -D --strip-unneeded {} -o /tmp/striped; if ! cmp {} /tmp/striped; then cp /tmp/striped {}; fi; rm -f /tmp/striped" \; && \
    python -c $'# \n\
import re \n\
path = "pyproj/__init__.py" \n\
s = open(path).read() \n\
# append .1 to version to make sure pip prefers this \n\
s = re.sub(r"(__version__ = \\"[^\\"]*)\\"", "\\\\1.1\\"", s) \n\
s = s.replace("2.4.rc0", "2.4") \n\
s = s.replace("import warnings", \n\
"""import warnings \n\
import os \n\
localpath = os.path.dirname(os.path.abspath( __file__ )) \n\
os.environ.setdefault("PROJ_LIB", os.path.join(localpath, "proj")) \n\
""") \n\
open(path, "w").write(s)' && \
    python -c $'# \n\
import os \n\
path = "setup.py" \n\
data = open(path).read() \n\
data = data.replace( \n\
    "    return package_data", \n\
"""    package_data["pyproj"].extend(["bin/*", "proj/*"]) \n\
    return package_data""") \n\
data = data.replace("""version=get_version(),""", \n\
"""version=get_version(), \n\
    entry_points={\'console_scripts\': [\'%s=pyproj.bin:program\' % name for name in os.listdir(\'pyproj/bin\') if not name.endswith(\'.py\')]},""") \n\
open(path, "w").write(data)' && \
    # now rebuild anything that can work with master \
    find /opt/py -mindepth 1 -not -name '*p36-*' -a -not -name '*p37-*' -print0 | xargs -n 1 -0 -P 1 bash -c '"${0}/bin/pip" wheel . --no-deps -w /io/wheelhouse && rm -rf build' && \
    # Make sure all binaries have the execute flag \
    find /io/wheelhouse/ -name 'pyproj*.whl' -print0 | xargs -n 1 -0 bash -c 'mkdir /tmp/ptmp; pushd /tmp/ptmp; unzip ${0}; chmod a+x pyproj/bin/*; chmod a-x pyproj/bin/*.py; zip -r ${0} *; popd; rm -rf /tmp/ptmp' && \
    find /io/wheelhouse/ -name 'pyproj*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} auditwheel repair --only-plat --plat manylinux2014_x86_64 -w /io/wheelhouse && \
    find /io/wheelhouse/ -name 'pyproj*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v && \
    find /io/wheelhouse/ -name 'pyproj*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} advzip -k -z && \
    ls -l /io/wheelhouse && \
    rm -rf ~/.cache && \
    echo "`date` pyproj4" >> /build/log.txt

RUN \
    echo "`date` minizip" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b `getver.py minizip` -c advice.detachedHead=false https://github.com/nmoinvaz/minizip.git && \
    cd minizip && \
    mkdir _build && \
    cd _build && \
    cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=yes -DINSTALL_INC_DIR=/usr/local/include/minizip -DMZ_OPENSSL=yes .. && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` minizip" >> /build/log.txt

RUN \
    echo "`date` libexpat" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    curl --retry 5 --silent https://github.com/libexpat/libexpat/archive/R_`getver.py libexpat`.tar.gz -L -o libexpat.tar.gz && \
    mkdir libexpat && \
    tar -zxf libexpat.tar.gz -C libexpat --strip-components 1 && \
    rm -f libexpat.tar.gz && \
    cd libexpat/expat && \
    autoreconf -ifv && \
    ./configure --silent --prefix=/usr/local --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libexpat" >> /build/log.txt

RUN \
    echo "`date` freexl" >> /build/log.txt && \
    export JOBS=`nproc` && \
    printf 'yes\nyes\n' | fossil --user=root clone https://www.gaia-gis.it/fossil/freexl freexl.fossil && \
    mkdir freexl && \
    cd freexl && \
    fossil open ../freexl.fossil && \
    rm -f ../freexl.fossil && \
    LIBS=-liconv ./configure --silent --prefix=/usr/local --disable-static && \
    LIBS=-liconv make -j ${JOBS} && \
    LIBS=-liconv make -j ${JOBS} install && \
    ldconfig && \
    echo "`date` freexl" >> /build/log.txt

RUN \
    echo "`date` libgeos" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b `getver.py libgeos` -c advice.detachedHead=false https://github.com/libgeos/geos.git && \
    cd geos && \
    mkdir _build && \
    cd _build && \
    cmake -DGEOS_BUILD_DEVELOPER=NO -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF .. && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libgeos" >> /build/log.txt

RUN \
    echo "`date` libxml" >> /build/log.txt && \
    export JOBS=`nproc` && \
    rm -rf libxml2* && \
    curl --retry 5 --silent http://xmlsoft.org/sources/libxml2-`getver.py libxml2`.tar.gz -L -o libxml2.tar.gz && \
    mkdir libxml2 && \
    tar -zxf libxml2.tar.gz -C libxml2 --strip-components 1 && \
    rm -f libxml2.tar.gz && \
    cd libxml2 && \
    ./configure --prefix=/usr/local --disable-static --without-python && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libxml" >> /build/log.txt

RUN \
    echo "`date` libspatialite" >> /build/log.txt && \
    export JOBS=`nproc` && \
    fossil --user=root clone https://www.gaia-gis.it/fossil/libspatialite libspatialite.fossil && \
    mkdir libspatialite && \
    cd libspatialite && \
    fossil open ../libspatialite.fossil && \
    # fossil checkout -f 5808354e84 && \
    rm -f ../libspatialite.fossil && \
    ./configure --silent --prefix=/usr/local --disable-examples --disable-static --disable-rttopo --disable-gcp && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    find . -name '*.a' -delete && \
    echo "`date` libspatialite" >> /build/log.txt

RUN \
    echo "`date` libgeotiff" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b `getver.py libgeotiff` -c advice.detachedHead=false https://github.com/OSGeo/libgeotiff.git && \
    cd libgeotiff/libgeotiff && \
    autoreconf -ifv && \
    ./configure --silent --prefix=/usr/local --with-zlib=yes --with-jpeg=yes --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libgeotiff" >> /build/log.txt

RUN \
    echo "`date` pixman" >> /build/log.txt && \
    export JOBS=`nproc` && \
    until timeout 60 git clone --depth=1 --single-branch -b pixman-`getver.py pixman` -c advice.detachedHead=false https://gitlab.freedesktop.org/pixman/pixman.git; do sleep 5; echo "retrying"; done && \
    cd pixman && \
    meson --prefix=/usr/local --buildtype=release _build && \
    cd _build && \
    ninja -j ${JOBS} && \
    ninja -j ${JOBS} install && \
    ldconfig && \
    echo "`date` pixman" >> /build/log.txt

RUN \
    echo "`date` freetype" >> /build/log.txt && \
    export JOBS=`nproc` && \
    curl --retry 5 --silent https://download.savannah.gnu.org/releases/freetype/freetype-`getver.py freetype`.tar.gz -L -o freetype.tar.gz && \
    mkdir freetype && \
    tar -zxf freetype.tar.gz -C freetype --strip-components 1 && \
    rm -f freetype.tar.gz && \
    cd freetype && \
    ./configure --silent --prefix=/usr/local --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` freetype" >> /build/log.txt

RUN \
    echo "`date` fontconfig" >> /build/log.txt && \
    export JOBS=`nproc` && \
    until timeout 60 git clone --depth=1 --single-branch -b `getver.py fontconfig` -c advice.detachedHead=false https://gitlab.freedesktop.org/fontconfig/fontconfig.git; do sleep 5; echo "retrying"; done && \
    cd fontconfig && \
    meson --prefix=/usr/local --buildtype=release -Ddoc=disabled -Dtests=disabled _build && \
    cd _build && \
    ninja -j ${JOBS} && \
    ninja -j ${JOBS} install && \
    ldconfig && \
    echo "`date` fontconfig" >> /build/log.txt

RUN \
    echo "`date` cairo" >> /build/log.txt && \
    export JOBS=`nproc` && \
    until timeout 60 git clone --depth=1 --single-branch -b `getver.py cairo` -c advice.detachedHead=false https://gitlab.freedesktop.org/cairo/cairo.git; do sleep 5; echo "retrying"; done && \
    cd cairo && \
    meson --prefix=/usr/local --buildtype=release -Dtests=disabled _build && \
    cd _build && \
    ninja -j ${JOBS} && \
    ninja -j ${JOBS} install && \
    ldconfig && \
    echo "`date` cairo" >> /build/log.txt

# PINNED VERSION - GDAL fails on 2.2.0
RUN \
    echo "`date` charls" >> /build/log.txt && \
    export JOBS=`nproc` && \
    # git clone --depth=1 --single-branch -b `getver.py charls` -c advice.detachedHead=false https://github.com/team-charls/charls.git && \
    git clone --depth=1 --single-branch -b 2.1.0 -c advice.detachedHead=false https://github.com/team-charls/charls.git && \
    cd charls && \
    mkdir _build && \
    cd _build && \
    cmake -DBUILD_SHARED_LIBS=ON -DCMAKE_BUILD_TYPE=Release -DCHARLS_BUILD_SAMPLES=OFF -DCHARLS_BUILD_TESTS=OFF .. && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` charls" >> /build/log.txt

RUN \
    echo "`date` lz4" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py lz4` -c advice.detachedHead=false https://github.com/lz4/lz4.git && \
    cd lz4 && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` lz4" >> /build/log.txt

RUN \
    echo "`date` libdap" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b version-`getver.py libdap` -c advice.detachedHead=false https://github.com/OPENDAP/libdap4.git && \
    cd libdap4 && \
    autoreconf -ifv && \
    ./configure --silent --prefix=/usr/local --enable-threads=posix --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libdap" >> /build/log.txt

RUN \
    echo "`date` librasterlite2" >> /build/log.txt && \
    export JOBS=`nproc` && \
    fossil --user=root clone https://www.gaia-gis.it/fossil/librasterlite2 librasterlite2.fossil && \
    mkdir librasterlite2 && \
    cd librasterlite2 && \
    fossil open ../librasterlite2.fossil && \
    rm -f ../librasterlite2.fossil && \
    ./configure --silent --prefix=/usr/local --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` librasterlite2" >> /build/log.txt

# PINNED VERSION - use master
# fyba won't compile with GCC 8.2.x, so apply fix in issue #21
RUN \
    echo "`date` fyba" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    git clone --depth=1 --single-branch -c advice.detachedHead=false https://github.com/kartverket/fyba.git && \
    cd fyba && \
    python -c $'# \n\
import os \n\
path = "src/FYBA/FYLU.cpp" \n\
data = open(path, "rb").read() \n\
data = data.replace( \n\
    b"#include \\"stdafx.h\\"", b"") \n\
data = data.replace( \n\
    b"#include <locale>", \n\
    b"#include <locale>\\n" + \n\
    b"#include \\"stdafx.h\\"") \n\
open(path, "wb").write(data)' && \
    autoreconf -ifv && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` fyba" >> /build/log.txt

# Build items necessary for netcdf support
RUN \
    echo "`date` hdf4" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b hdf-`getver.py hdf4` -c advice.detachedHead=false https://github.com/HDFGroup/hdf4.git && \
    cd hdf4 && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release -DHDF4_BUILD_FORTRAN=OFF -DHDF4_ENABLE_NETCDF=OFF -DHDF4_ENABLE_Z_LIB_SUPPORT=ON -DHDF4_DISABLE_COMPILER_WARNINGS=ON -DCMAKE_INSTALL_PREFIX=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` hdf4" >> /build/log.txt

# PINNED VERSION - netcdf-c doesn't build with 1_13_0
RUN \
    echo "`date` hdf5" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    # git clone --depth=1 --single-branch -b hdf5-`getver.py hdf5` -c advice.detachedHead=false https://github.com/HDFGroup/hdf5.git && \
    git clone --depth=1 --single-branch -b hdf5-1_12_1 -c advice.detachedHead=false https://github.com/HDFGroup/hdf5.git && \
    cd hdf5 && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release -DDEFAULT_API_VERSION=v18 -DHDF5_BUILD_EXAMPLES=OFF -DHDF5_BUILD_FORTRAN=OFF -DHDF5_ENABLE_PARALLEL=ON -DHDF5_ENABLE_Z_LIB_SUPPORT=ON -DHDF5_BUILD_GENERATORS=ON -DHDF5_ENABLE_DIRECT_VFD=ON -DHDF5_BUILD_CPP_LIB=OFF -DHDF5_DISABLE_COMPILER_WARNINGS=ON -DBUILD_TESTING=OFF -DZLIB_DIR=/usr/local/lib -DMPI_C_COMPILER=/usr/local/bin/mpicc -DMPI_C_HEADER_DIR=/usr/local/include -DMPI_mpi_LIBRARY=/usr/local/lib/libmpi.so -DMPI_C_LIB_NAMES=mpi -DHDF5_BUILD_DOC=OFF -DCMAKE_INSTALL_PREFIX=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    # Delete binaries used for testing to keep the docker image smaller \
    find bin -type f ! -name 'lib*' -delete && \
    echo "`date` hdf5" >> /build/log.txt

RUN \
    echo "`date` parallel-netcdf" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b checkpoint.`getver.py parallel-netcdf` -c advice.detachedHead=false https://github.com/Parallel-NetCDF/PnetCDF && \
    cd PnetCDF && \
    autoreconf -ifv && \
    ./configure --silent --prefix=/usr/local --enable-shared --disable-fortran --enable-thread-safe --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` parallel-netcdf" >> /build/log.txt

RUN \
    echo "`date` netcdf" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py netcdf` -c advice.detachedHead=false https://github.com/Unidata/netcdf-c && \
    cd netcdf-c && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release -DENABLE_EXAMPLES=OFF -DENABLE_PARALLEL4=ON -DUSE_PARALLEL=ON -DUSE_PARALLEL4=ON -DENABLE_HDF4=ON -DENABLE_PNETCDF=ON -DENABLE_BYTERANGE=ON -DENABLE_JNA=ON -DCMAKE_SHARED_LINKER_FLAGS=-ljpeg -DENABLE_TESTS=OFF -DENABLE_HDF4_FILE_TESTS=OFF && \
    # for hdf5 1_13, we might need to add -DHDF5_DIR=/usr/local/share/cmake \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` netcdf" >> /build/log.txt

RUN \
    echo "`date` mysql" >> /build/log.txt && \
    export JOBS=`nproc` && \
    curl --retry 5 --silent https://cdn.mysql.com/Downloads/MySQL-8.0/mysql-boost-`getver.py mysql`.tar.gz -L -o mysql.tar.gz && \
    mkdir mysql && \
    tar -zxf mysql.tar.gz -C mysql --strip-components 1 && \
    rm -f mysql.tar.gz && \
    cd mysql && \
    # reduce docker size \
    rm -rf mysql-test && \
    # See https://bugs.mysql.com/bug.php?id=87348 \
    mkdir -p storage/ndb && \
    touch storage/ndb/CMakeLists.txt && \
    mkdir _build && \
    cd _build && \
    CFLAGS="$CFLAGS -ftls-model=global-dynamic" \
    CXXFLAGS="$CXXFLAGS -Wno-deprecated-declarations -ftls-model=global-dynamic" \
    cmake -DBUILD_CONFIG=mysql_release -DBUILD_SHARED_LIBS=ON -DWITH_BOOST=../boost/boost_1_73_0 -DWITH_ZLIB=system -DCMAKE_INSTALL_PREFIX=/usr/local -DWITH_UNIT_TESTS=OFF -DCMAKE_BUILD_TYPE=Release -DWITHOUT_SERVER=ON -DREPRODUCIBLE_BUILD=ON -DINSTALL_MYSQLTESTDIR="" .. && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    # reduce docker size \
    make clean && \
    ldconfig && \
    echo "`date` mysql" >> /build/log.txt

# ogdi doesn't build with parallelism
RUN \
    echo "`date` ogdi" >> /build/log.txt && \
    git clone --depth=1 --single-branch -b ogdi_`getver.py ogdi` -c advice.detachedHead=false https://github.com/libogdi/ogdi.git && \
    cd ogdi && \
    export TOPDIR=`pwd` && \
    ./configure --silent --prefix=/usr/local --with-zlib --with-expat && \
    make --silent && \
    make --silent install && \
    cp bin/Linux/*.so /usr/local/lib/. && \
    ldconfig && \
    echo "`date` ogdi" >> /build/log.txt

RUN \
    echo "`date` postgresql" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    curl --retry 5 --silent https://ftp.postgresql.org/pub/source/v`getver.py postgresql`/postgresql-`getver.py postgresql`.tar.gz -L -o postgresql.tar.gz && \
    mkdir postgresql && \
    tar -zxf postgresql.tar.gz -C postgresql --strip-components 1 && \
    rm -f postgresql.tar.gz && \
    cd postgresql && \
    # sed -i 's/2\.69/2.71/g' configure.in && \
    # autoreconf -ifv && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` postgresql" >> /build/log.txt

RUN \
    echo "`date` poppler" >> /build/log.txt && \
    export JOBS=`nproc` && \
    until timeout 60 git clone --depth=1 --single-branch -b poppler-`getver.py poppler` -c advice.detachedHead=false https://gitlab.freedesktop.org/poppler/poppler.git; do sleep 5; echo "retrying"; done && \
    cd poppler && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local -DCMAKE_BUILD_TYPE=Release -DENABLE_UNSTABLE_API_ABI_HEADERS=on -DBUILD_CPP_TESTS=OFF -DBUILD_GTK_TESTS=OFF -DBUILD_MANUAL_TESTS=OFF -DBUILD_QT5_TESTS=OFF -DBUILD_QT6_TESTS=OFF && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` poppler" >> /build/log.txt

RUN \
    echo "`date` fitsio" >> /build/log.txt && \
    export JOBS=`nproc` && \
    curl --retry 5 --silent -k https://heasarc.gsfc.nasa.gov/FTP/software/fitsio/c/cfitsio`getver.py fitsio`.tar.gz -L -o cfitsio.tar.gz && \
    mkdir cfitsio && \
    tar -zxf cfitsio.tar.gz -C cfitsio --strip-components 1 && \
    rm -f cfitsio.tar.gz && \
    cd cfitsio && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` fitsio" >> /build/log.txt

# We want the "obsolete-api" to be available for some packages (GDAL), but the
# base docker image has the newer api version installed.  When we install the
# older one, the install command complains about the extant version, but still
# works, so eat its errors.
RUN \
    echo "`date` libxcrypt" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py libxcrypt` -c advice.detachedHead=false https://github.com/besser82/libxcrypt.git && \
    cd libxcrypt && \
    # autoreconf -ifv && \
    ./autogen.sh && \
    CFLAGS="$CFLAGS -w" ./configure --silent --prefix=/usr/local --enable-obsolete-api --enable-hashes=all --disable-static && \
    make --silent -j ${JOBS} && \
    rm -f /usr/local/lib/pkgconfig/libcrypt.pc && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libxcrypt" >> /build/log.txt

# If we use gettext installed via yum, autoreconf and configure fail.  We can
# build with cmake instead.  The failure message is
# possibly undefined macro: AC_LIB_HAVE_LINKFLAGS
RUN \
    echo "`date` libgta" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b libgta-`getver.py libgta` -c advice.detachedHead=false https://github.com/marlam/gta-mirror.git && \
    cd gta-mirror/libgta && \
    # autoreconf -ifv && \
    # ./configure --silent --prefix=/usr/local --disable-static && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local -DCMAKE_BUILD_TYPE=Release -DGTA_BUILD_DOCUMENTATION=OFF -DGTA_BUILD_STATIC_LIB=OFF && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libgta" >> /build/log.txt

# This is an old version of libecw.  I am uncertain that the licensing allows
# for this to be used, and therefore is disabled for now.
# RUN \
#     echo "`date` libecw" >> /build/log.txt && \
#     export JOBS=`nproc` && \
#     curl --retry 5 --silent https://sourceforge.net/projects/libecw-legacy/files/libecwj2-3.3-2006-09-06.zip -L -o libecwj.zip && \
#     unzip libecwj.zip && \
#     rm -f libecwj.zip && \
#     cd libecwj2-3.3 && \
#     CXXFLAGS='-w' ./configure --silent --prefix=/usr/local && \
#     make --silent -j ${JOBS} && \
#     make --silent -j ${JOBS} install && \
#     ldconfig && \
#     echo "`date` libecw" >> /build/log.txt

RUN \
    echo "`date` xerces-c" >> /build/log.txt && \
    export JOBS=`nproc` && \
    curl --retry 5 --silent https://www.apache.org/dist/xerces/c/3/sources/xerces-c-`getver.py xerces-c`.tar.gz -L -o xerces-c.tar.gz && \
    mkdir xerces-c && \
    tar -zxf xerces-c.tar.gz -C xerces-c --strip-components 1 && \
    rm -f xerces-c.tar.gz && \
    cd xerces-c && \
    mkdir _build && \
    cd _build && \
    cmake -DCMAKE_BUILD_TYPE=Release .. && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` xerces-c" >> /build/log.txt

# OpenBLAS and SuperLu make GDAL start very slowly

# RUN \
#     echo "`date` openblas" >> /build/log.txt && \
#     export JOBS=`nproc` && \
#     git clone --depth=1 --single-branch -b v`getver.py openblas` -c advice.detachedHead=false https://github.com/xianyi/OpenBLAS.git && \
#     cd OpenBLAS && \
#     mkdir _build && \
#     cd _build && \
#     cmake -DUSE_OPENMP=True -DBUILD_SHARED_LIBS=True -DCMAKE_BUILD_TYPE=Release .. && \
#     make --silent -j ${JOBS} && \
#     make --silent -j ${JOBS} install && \
#     ldconfig && \
#     echo "`date` openblas" >> /build/log.txt

# RUN \
#     echo "`date` superlu" >> /build/log.txt && \
#     export JOBS=`nproc` && \
#     git clone --depth=1 --single-branch -b v`getver.py superlu` -c advice.detachedHead=false https://github.com/xiaoyeli/superlu.git && \
#     cd superlu && \
#     mkdir _build && \
#     cd _build && \
#     cmake -DBUILD_SHARED_LIBS=True -DCMAKE_BUILD_TYPE=Release -Denable_internal_blaslib=OFF -Denable_tests=OFF -DTPL_BLAS_LIBRARIES=/usr/local/lib64/libopenblas.so .. && \
#     make --silent -j ${JOBS} && \
#     make --silent -j ${JOBS} install && \
#     ldconfig && \
#     echo "`date` superlu" >> /build/log.txt

RUN \
    echo "`date` lapack" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py lapack` -c advice.detachedHead=false https://github.com/Reference-LAPACK/lapack && \
    cd lapack && \
    mkdir _build && \
    cd _build && \
    cmake -DBUILD_SHARED_LIBS=True -DCMAKE_BUILD_TYPE=Release .. && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` lapack" >> /build/log.txt

RUN \
    echo "`date` armadillo" >> /build/log.txt && \
    export JOBS=`nproc` && \
    curl --retry 5 --silent https://sourceforge.net/projects/arma/files/armadillo-`getver.py armadillo`.tar.xz -L -o armadillo.tar.xz && \
    unxz armadillo.tar.xz && \
    mkdir armadillo && \
    tar -xf armadillo.tar -C armadillo --strip-components 1 && \
    rm -f armadillo.tar && \
    cd armadillo && \
    mkdir _build && \
    cd _build && \
    cmake -DBUILD_SHARED_LIBS=True -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local -DCMAKE_INSTALL_LIBDIR=lib .. && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` armadillo" >> /build/log.txt

# PINNED VERSION - can't easily check the version
# MrSID only works with gcc 4 or 5 unless we change it.
RUN \
    echo "`date` mrsid" >> /build/log.txt && \
    curl --retry 5 --silent http://bin.extensis.com/download/developer/MrSID_DSDK-9.5.4.4709-rhel6.x86-64.gcc531.tar.gz -L -o mrsid.tar.gz && \
    mkdir mrsid && \
    tar -zxf mrsid.tar.gz -C mrsid --strip-components 1 && \
    rm -f mrsid.tar.gz && \
    sed -i 's/ && __GNUC__ <= 5//g' /build/mrsid/Raster_DSDK/include/lt_platform.h && \
    cp -n mrsid/Raster_DSDK/lib/* /usr/local/lib/. && \
    cp -n mrsid/Lidar_DSDK/lib/* /usr/local/lib/. && \
    echo "`date` mrsid" >> /build/log.txt

RUN \
    echo "`date` blosc" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py blosc` -c advice.detachedHead=false https://github.com/Blosc/c-blosc.git && \
    cd c-blosc && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED=ON -DBUILD_STATIC=OFF -DBUILD_BENCHMARKS=OFF -DBUILD_FUZZERS=OFF -DBUILD_TESTS=OFF -DPREFER_EXTERNAL_LZ4=ON -DPREFER_EXTERNAL_ZLIB=ON -DPREFER_EXTERNAL_ZSTD=ON -DDEACTIVATE_SNAPPY=OFF && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` blosc" >> /build/log.txt

RUN \
    echo "`date` libheif" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py libheif` -c advice.detachedHead=false https://github.com/strukturag/libheif.git && \
    cd libheif && \
    ./autogen.sh && \
    ./configure --silent --prefix=/usr/local --disable-static --disable-examples --disable-go && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libheif" >> /build/log.txt

# PINNED VERSION - use master
# This build doesn't support everything.
# Unsupported without more work or investigation:
#  GRASS Kea Google-libkml ODBC FGDB MDB OCI GEORASTER SDE Rasdaman
#  SFCGAL OpenCL MongoDB MongoCXX HDFS TileDB
# -- GRASS should be straightforward (see github.com/OSGeo/grass), but gdal
#  has to be installed first, then grass, then spatialite and gdal recompiled
#  with GRASS support.
# Unused because there is a working alternative:
#  cryptopp (crypto/openssl)
#  podofo PDFium (poppler)
# Unsupported due to licensing that requires agreements/fees:
#  INFORMIX-DataBlade JP2Lura Kakadu MSG RDB Teigha
# Unsupported due to licensing that might be allowed:
#  ECW
# Unused for other reasons:
#  DDS - uses crunch library which is for Windows
#  JPEG-in-TIFF 12 bit - we use our built libtiff not the internal, so this
#    reports as no.
# --with-dods-root is where libdap is installed
RUN \
    echo "`date` gdal" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    # Specific branch \
    # git clone --depth=1 --single-branch -b v`getver.py gdal` -c advice.detachedHead=false https://github.com/OSGeo/gdal.git && \
    # Master -- also adjust version \
    git clone --depth=1 --single-branch -c advice.detachedHead=false https://github.com/OSGeo/gdal.git && \
    # sed -i 's/define GDAL_VERSION_MINOR    4/define GDAL_VERSION_MINOR    5/g' gdal/gcore/gdal_version.h.in && \
    # Common \
    cd gdal/gdal || cd gdal && \
    export PATH="$PATH:/build/mysql/build/scripts" && \
    # cmake will soon work fully \
    # cmake .. -DMRSID_LIBRARY=/build/mrsid/Raster_DSDK/lib/libltidsdk.so -DMRSID_INCLUDE_DIR=/build/mrsid/Raster_DSDK/include -DGDAL_USE_LERC=ON && \
    # export CFLAGS="$CFLAGS -DDEBUG_VERBOSE=ON" && \
    ./autogen.sh && \
    ./configure --prefix=/usr/local --disable-static --disable-rpath --with-cpp14 --without-libtool \
    --with-armadillo \
    --with-cfitsio=/usr/local \
    --with-dods-root=/usr/local \
    --with-exr \
    --with-hdf5 \
    --with-jpeg12 \
    --with-liblzma \
    --with-mrsid=/build/mrsid/Raster_DSDK \
    --with-mysql \
    --with-pg \
    --with-poppler \
    --with-rasterlite2 \
    --with-sosi \
    --with-spatialite \
    --with-webp \
    # --with-debug \
    | tee configure.output && \
    make -j ${JOBS} USER_DEFS="-Werror -Wno-missing-field-initializers -Wno-write-strings -Wno-stringop-overflow -Wno-ignored-qualifiers" && \
    make -j ${JOBS} install && \
    ldconfig && \
    # This takes a lot of space in the Docker file, and we don't use it \
    rm libgdal.a && \
    # reduce docker size \
    rm -rf ogr/ogrsf_frmts/o/*.o frmts/o/*.o && \
    echo "`date` gdal" >> /build/log.txt

RUN \
    echo "`date` gdal python" >> /build/log.txt && \
    export JOBS=`nproc` && \
    cd gdal/gdal/swig/python || cd gdal/swig/python && \
    cp -r /usr/local/share/{proj,gdal} osgeo/. && \
    mkdir osgeo/bin && \
    find ../../apps/ -executable -type f ! -name '*.cpp' -exec cp {} osgeo/bin/. \; && \
    find /build/libgeotiff/libgeotiff/bin/.libs -executable -type f -exec cp {} osgeo/bin/. \; && \
    (strip osgeo/bin/* --strip-unneeded || true) && \
    python -c $'# \n\
path = "osgeo/bin/__init__.py" \n\
s = """import os \n\
import sys \n\
\n\
def program(): \n\
    environ = os.environ.copy() \n\
    localpath = os.path.dirname(os.path.abspath( __file__ )) \n\
    environ.setdefault("PROJ_LIB", os.path.join(localpath, "proj")) \n\
    environ.setdefault("GDAL_DATA", os.path.join(localpath, "gdal")) \n\
    caPath = "/etc/ssl/certs/ca-certificates.crt" \n\
    if os.path.exists(caPath): \n\
        environ.setdefault("CURL_CA_BUNDLE", caPath) \n\
\n\
    path = os.path.join(os.path.dirname(__file__), os.path.basename(sys.argv[0])) \n\
    os.execve(path, sys.argv, environ) \n\
""" \n\
open(path, "w").write(s)' && \
    python -c $'# \n\
import re \n\
import os \n\
path = "setup.py" \n\
data = open(path).read() \n\
data = data.replace( \n\
    "        self.gdaldir = self.get_gdal_config(\'prefix\')", \n\
    "        try:\\n" + \n\
    "            self.gdaldir = self.get_gdal_config(\'prefix\')\\n" + \n\
    "        except Exception:\\n" + \n\
    "            return True") \n\
data = re.sub( \n\
    r"gdal_version = \'\\d+.\\d+.\\d+(dev|)\'", \n\
    "gdal_version = \'" + os.popen("gdal-config --version").read().strip().split(\'.dev\')[0] + "\'", \n\
    data) \n\
data = data.replace( \n\
    "scripts/*.py\'),", \n\
"""scripts/*.py\'), \n\
    package_data={\'osgeo\': [\'proj/*\', \'gdal/*\', \'bin/*\']}, \n\
    entry_points={\'console_scripts\': [\'%s=osgeo.bin:program\' % name for name in os.listdir(\'osgeo/bin\') if not name.endswith(\'.py\')]},""") \n\
data = data.replace("    python_requires=\'>=3.6.0\',", "") \n\
open(path, "w").write(data)' && \
    python -c $'# \n\
path = "osgeo/__init__.py" \n\
s = open(path).read().replace( \n\
    "osgeo package.", \n\
"""osgeo package. \n\
\n\
import os \n\
import re \n\
\n\
_localpath = os.path.dirname(os.path.abspath( __file__ )) \n\
os.environ.setdefault("PROJ_LIB", os.path.join(_localpath, "proj")) \n\
os.environ.setdefault("GDAL_DATA", os.path.join(_localpath, "gdal")) \n\
_caPath = "/etc/ssl/certs/ca-certificates.crt" \n\
if os.path.exists(_caPath): \n\
    os.environ.setdefault("CURL_CA_BUNDLE", _caPath) \n\
\n\
_libsdir = os.path.join(os.path.dirname(_localpath), "GDAL.libs") \n\
_libs = { \n\
    re.split(r"-|\\.", name)[0]: os.path.join(_libsdir, name) \n\
    for name in os.listdir(_libsdir) \n\
} \n\
GDAL_LIBRARY_PATH = _libs["libgdal"] \n\
GEOS_LIBRARY_PATH = _libs["libgeos_c"] \n\
""") \n\
open(path, "w").write(s)' && \
    # Copy python ports of c utilities to scripts so they get bundled.
    mkdir scripts && \
    cp gdal-utils/osgeo_utils/samples/gdalinfo.py scripts/gdalinfo.py && \
    cp gdal-utils/osgeo_utils/samples/ogrinfo.py scripts/ogrinfo.py && \
    cp gdal-utils/osgeo_utils/samples/ogr2ogr.py scripts/ogr2ogr.py && \
    # Strip libraries before building any wheels \
    # strip --strip-unneeded -p -D /usr/local/lib{,64}/*.{so,a} && \
    find /usr/local \( -name '*.so' -o -name '*.a' \) -exec bash -c "strip -p -D --strip-unneeded {} -o /tmp/striped; if ! cmp {} /tmp/striped; then cp /tmp/striped {}; fi; rm -f /tmp/striped" \; && \
    find /opt/py -mindepth 1 -print0 | xargs -n 1 -0 -P 1 bash -c '"${0}/bin/pip" wheel . --no-deps -w /io/wheelhouse; git clean -fxd build GDAL.egg-info' && \
    find /io/wheelhouse/ -name 'GDAL*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} auditwheel repair --only-plat --plat manylinux2014_x86_64 -w /io/wheelhouse && \
    find /io/wheelhouse/ -name 'GDAL*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v && \
    find /io/wheelhouse/ -name 'GDAL*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} advzip -k -z && \
    ls -l /io/wheelhouse && \
    rm -rf ~/.cache && \
    echo "`date` gdal python" >> /build/log.txt

# Mapnik

RUN \
    echo "`date` harfbuzz" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b `getver.py harfbuzz` -c advice.detachedHead=false https://github.com/harfbuzz/harfbuzz.git && \
    cd harfbuzz && \
    meson --prefix=/usr/local --buildtype=release -Dtests=disabled _build && \
    cd _build && \
    ninja -j ${JOBS} && \
    ninja -j ${JOBS} install && \
    ldconfig && \
    echo "`date` harfbuzz" >> /build/log.txt

# PINNED VERSION - use master since last version is stale
RUN \
    echo "`date` mapnik" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export HEAVY_JOBS=`nproc` && \
    # Master \
    git clone --depth=1 --single-branch -c advice.detachedHead=false --quiet --recurse-submodules -j ${JOBS} https://github.com/mapnik/mapnik.git && \
    cd mapnik && \
    # Specific checkout \
    # git clone --depth=1000 --single-branch -c advice.detachedHead=false --quiet --recurse-submodules -j ${JOBS} https://github.com/mapnik/mapnik.git && \
    # cd mapnik && \
    # # Apr 28 2021 \
    # git checkout fb2e45c57981f8a3b071f37a0b27f211bf233081 && \
    # Common \
    find . -name '.git' -exec rm -rf {} \+ && \
    # Scons build process \
    # # Keeps the docker smaller \
    # rm -rf demo test && mkdir test && mkdir demo && touch test/build.py && touch demo/build.py && \
    # python scons/scons.py configure JOBS=`nproc` \
    # BOOST_INCLUDES=/usr/local/include BOOST_LIBS=/usr/local/lib \
    # ICU_INCLUDES=/usr/local/include ICU_LIBS=/usr/local/lib \
    # HB_INCLUDES=/usr/local/include HB_LIBS=/usr/local/lib \
    # PNG_INCLUDES=/usr/local/include PNG_LIBS=/usr/local/lib \
    # JPEG_INCLUDES=/usr/local/include JPEG_LIBS=/usr/local/lib \
    # TIFF_INCLUDES=/usr/local/include TIFF_LIBS=/usr/local/lib \
    # WEBP_INCLUDES=/usr/local/include WEBP_LIBS=/usr/local/lib \
    # PROJ_INCLUDES=/usr/local/include PROJ_LIBS=/usr/local/lib \
    # SQLITE_INCLUDES=/usr/local/include SQLITE_LIBS=/usr/local/lib \
    # RASTERLITE_INCLUDES=/usr/local/include RASTERLITE_LIBS=/usr/local/lib \
    # WARNING_CXXFLAGS="-Wno-unused-variable -Wno-unused-but-set-variable -Wno-attributes -Wno-unknown-pragmas -Wno-maybe-uninitialized -Wno-parentheses" \
    # QUIET=true \
    # CPP_TESTS=false \
    # DEBUG=false \
    # DEMO=false \
    # && \
    # CMake build process -- doesn't build mapnik-config as of 9/6/21 \
    # Keeps the docker smaller \
    rm -rf demo test && mkdir test && mkdir demo && touch test/CMakeLists.txt && touch demo/CMakeLists.txt && \
    mkdir _build && \
    cd _build && \
    CXXFLAGS="-Wno-unused-variable -Wno-unused-but-set-variable -Wno-attributes -Wno-unknown-pragmas -Wno-maybe-uninitialized -Wno-parentheses" \
    cmake -DBUILD_SHARED_LIBS=ON -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_BENCHMARK=OFF \
    -DBUILD_DEMO_CPP=OFF \
    -DBUILD_DEMO_VIEWER=OFF \
    -DBUILD_TESTING=OFF \
    -DJPEG_INCLUDE_DIR=/usr/local/include \
    -DJPEG_LIBRARY_RELEASE=/usr/local/lib/libopenjp2.so \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DFONTS_INSTALL_DIR=/usr/local/lib/mapnik/fonts \
    .. && \
    # Common build process \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` mapnik" >> /build/log.txt

RUN \
    echo "`date` python-mapnik" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -c advice.detachedHead=false --quiet --recurse-submodules -j ${JOBS} https://github.com/mapnik/python-mapnik.git && \
    cd python-mapnik && \
    find . -name '.git' -exec rm -rf {} \+ && \
    # Copy the mapnik input sources and fonts to the python path and add them \
    # via setup.py.  Modify the paths.py file that gets created to refer to \
    # the relative location of these files. \
    cp -r /usr/local/lib/mapnik/* mapnik/. && \
    cp -r /usr/local/share/{proj,gdal} mapnik/. && \
    mkdir mapnik/bin && \
    cp /usr/local/bin/{mapnik-render,mapnik-index,shapeindex} mapnik/bin/. && \
    strip mapnik/bin/* --strip-unneeded -p -D && \
    python -c $'# \n\
path = "mapnik/bin/__init__.py" \n\
s = """import os \n\
import sys \n\
\n\
def program(): \n\
    environ = os.environ.copy() \n\
    localpath = os.path.dirname(os.path.abspath( __file__ )) \n\
    environ.setdefault("PROJ_LIB", os.path.join(localpath, "proj")) \n\
    environ.setdefault("GDAL_DATA", os.path.join(localpath, "gdal")) \n\
\n\
    path = os.path.join(os.path.dirname(__file__), os.path.basename(sys.argv[0])) \n\
    os.execve(path, sys.argv, environ) \n\
""" \n\
open(path, "w").write(s)' && \
    #     python -c $'# \n\
    # path = "setup.py" \n\
    # s = open(path).read().replace( \n\
    #     "\'share/*/*\'", \n\
    #     """\'share/*/*\', \'input/*\', \'fonts/*\', \'proj/*\', \'gdal/*\', \'bin/*\'""").replace( \n\
    #     "path=font_path))", """path=font_path)) \n\
    #     f_paths.write("localpath = os.path.dirname(os.path.abspath( __file__ ))\\\\n") \n\
    #     f_paths.write("mapniklibpath = os.path.join(localpath, \'mapnik.libs\')\\\\n") \n\
    #     f_paths.write("mapniklibpath = os.path.normpath(mapniklibpath)\\\\n") \n\
    #     f_paths.write("inputpluginspath = os.path.join(localpath, \'input\')\\\\n") \n\
    #     f_paths.write("fontscollectionpath = os.path.join(localpath, \'fonts\')\\\\n") \n\
    # """) \n\
    # s = s.replace("test_suite=\'nose.collector\',", \n\
    # """test_suite=\'nose.collector\', \n\
    #     entry_points={\'console_scripts\': [\'%s=mapnik.bin:program\' % name for name in os.listdir(\'mapnik/bin\') if not name.endswith(\'.py\')]},""") \n\
    # p1 = s.index("cflags =") \n\
    # p2 = s.index("os.environ", p1) \n\
    # s = s[:p1] + "try:\\n    " + s[p1:p2].replace("\\n", "\\n    ") + "\\nexcept Exception:\\n    pass\\n" + s[p2:] \n\
    # open(path, "w").write(s)' && \
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
    git apply ../mapnik_proj_transform.cpp.patch && \
    # Apply a patch and set variables to work with the cmake build of mapnik \
    git apply ../mapnik_setup.py.patch && \
    export CC=c++ && \
    export CXX=c++ && \
    # Strip libraries before building any wheels \
    # strip --strip-unneeded -p -D /usr/local/lib{,64}/*.{so,a} && \
    find /usr/local \( -name '*.so' -o -name '*.a' \) -exec bash -c "strip -p -D --strip-unneeded {} -o /tmp/striped; if ! cmp {} /tmp/striped; then cp /tmp/striped {}; fi; rm -f /tmp/striped" \; && \
    if [ "$PYPY" = true ]; then \
    find /opt/py -mindepth 1 -print0 | xargs -n 1 -0 -P ${JOBS} bash -c 'export WORKDIR=/tmp/python-mapnik-`basename ${0}`; mkdir -p $WORKDIR; cp -r . $WORKDIR/.; pushd $WORKDIR; BOOST_PYTHON_LIB=`"${0}/bin/python" -c "import sys;sys.stdout.write('\''boost_python'\''+str(sys.version_info.major)+str(sys.version_info.minor))"` "${0}/bin/pip" wheel . --no-deps -w /io/wheelhouse && popd && rm -rf $WORKDIR' && \
    true; \
    else \
    # Exclude pypy, since boost-python isn't using it \
    find /opt/py -mindepth 1 -not -name '*pp*' -print0 | xargs -n 1 -0 -P ${JOBS} bash -c 'export WORKDIR=/tmp/python-mapnik-`basename ${0}`; mkdir -p $WORKDIR; cp -r . $WORKDIR/.; pushd $WORKDIR; BOOST_PYTHON_LIB=`"${0}/bin/python" -c "import sys;sys.stdout.write('\''boost_python'\''+str(sys.version_info.major)+str(sys.version_info.minor))"` "${0}/bin/pip" wheel . --no-deps -w /io/wheelhouse && popd && rm -rf $WORKDIR' && \
    true; \
    fi && \
    find /io/wheelhouse/ -name 'mapnik*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} auditwheel repair --only-plat --plat manylinux2014_x86_64 -w /io/wheelhouse && \
    find /io/wheelhouse/ -name 'mapnik*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v && \
    find /io/wheelhouse/ -name 'mapnik*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} advzip -k -z && \
    ls -l /io/wheelhouse && \
    rm -rf ~/.cache && \
    echo "`date` python-mapnik" >> /build/log.txt

RUN \
    echo "`date` openslide" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    curl --retry 5 --silent https://github.com/openslide/openslide/archive/v`getver.py openslide`.tar.gz -L -o openslide.tar.gz && \
    mkdir openslide && \
    tar -zxf openslide.tar.gz -C openslide --strip-components 1 && \
    rm -f openslide.tar.gz && \
    cd openslide && \
    patch src/openslide-vendor-mirax.c ../openslide-vendor-mirax.c.patch && \
    patch src/openslide.c ../openslide-init.patch && \
    autoreconf -ifv && \
    ./configure --prefix=/usr/local --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` openslide" >> /build/log.txt

RUN \
    echo "`date` openslide-python" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py openslide-python` -c advice.detachedHead=false https://github.com/openslide/openslide-python.git && \
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
        libpath = os.path.abspath(os.path.join(os.path.dirname(os.path.dirname(os.path.realpath( \n\
            __file__))), \'openslide_python.libs\')) \n\
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
    strip openslide/bin/* --strip-unneeded -p -D && \
    python -c $'# \n\
path = "openslide/bin/__init__.py" \n\
s = """import os \n\
import sys \n\
\n\
def program(): \n\
    path = os.path.join(os.path.dirname(__file__), os.path.basename(sys.argv[0])) \n\
    os.execv(path, sys.argv) \n\
""" \n\
open(path, "w").write(s)' && \
    python -c $'# \n\
path = "setup.py" \n\
s = open(path).read().replace( \n\
"""    zip_safe=True,""", \n\
"""    zip_safe=True, \n\
    include_package_data=True, \n\
    package_data={\'openslide\': [\'bin/*\']}, \n\
    entry_points={\'console_scripts\': [\'%s=openslide.bin:program\' % name for name in os.listdir(\'openslide/bin\') if not name.endswith(\'.py\')]},""") \n\
open(path, "w").write(s)' && \
    # Strip libraries before building any wheels \
    # strip --strip-unneeded -p -D /usr/local/lib{,64}/*.{so,a} && \
    find /usr/local \( -name '*.so' -o -name '*.a' \) -exec bash -c "strip -p -D --strip-unneeded {} -o /tmp/striped; if ! cmp {} /tmp/striped; then cp /tmp/striped {}; fi; rm -f /tmp/striped" \; && \
    find /opt/py -mindepth 1 -print0 | xargs -n 1 -0 -P 1 bash -c '"${0}/bin/pip" wheel . --no-deps -w /io/wheelhouse && rm -rf build' && \
    find /io/wheelhouse/ -name 'openslide*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} auditwheel repair --only-plat --plat manylinux2014_x86_64 -w /io/wheelhouse && \
    find /io/wheelhouse/ -name 'openslide*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v && \
    find /io/wheelhouse/ -name 'openslide*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} advzip -k -z && \
    ls -l /io/wheelhouse && \
    rm -rf ~/.cache && \
    echo "`date` openslide-python" >> /build/log.txt

# VIPS

RUN \
    echo "`date` orc" >> /build/log.txt && \
    export JOBS=`nproc` && \
    curl --retry 5 --silent https://github.com/GStreamer/orc/archive/`getver.py orc`.tar.gz -L -o orc.tar.gz && \
    mkdir orc && \
    tar -zxf orc.tar.gz -C orc --strip-components 1 && \
    rm -f orc.tar.gz && \
    cd orc && \
    meson --prefix=/usr/local --buildtype=release -Dgtk_doc=disabled -Dtests=disabled -Dexamples=disabled -Dbenchmarks=disabled _build && \
    cd _build && \
    ninja -j ${JOBS} && \
    ninja -j ${JOBS} install && \
    ldconfig && \
    echo "`date` orc" >> /build/log.txt

RUN \
    echo "`date` nifti" >> /build/log.txt && \
    export JOBS=`nproc` && \
    curl --retry 5 --silent https://downloads.sourceforge.net/project/niftilib/nifticlib/nifticlib_`getver.py nifti`/nifticlib-`getver.py nifti 3 _ .`.tar.gz -L -o nifti.tar.gz && \
    mkdir nifti && \
    tar -zxf nifti.tar.gz -C nifti --strip-components 1 && \
    rm -f nifti.tar.gz && \
    cd nifti && \
    mkdir _build && \
    cd _build && \
    cmake -DBUILD_SHARED_LIBS=ON -DCMAKE_BUILD_TYPE=Release .. && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` nifti" >> /build/log.txt

RUN \
    echo "`date` rust" >> /build/log.txt && \
    curl --retry 5 --silent https://sh.rustup.rs -sSf | sh -s -- -y --profile minimal && \
    echo "`date` rust" >> /build/log.txt

RUN \
    echo "`date` libimagequant" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export PATH="$HOME/.cargo/bin:$PATH" && \
    git clone --depth=1 --single-branch -b `getver.py libimagequant` -c advice.detachedHead=false https://github.com/ImageOptim/libimagequant.git && \
    cd libimagequant/imagequant-sys && \
    cargo install cargo-c && \
    cargo cinstall && \
    ldconfig && \
    echo "`date` libimagequant" >> /build/log.txt

RUN \
    echo "`date` pango" >> /build/log.txt && \
    export JOBS=`nproc` && \
    curl --retry 5 --silent http://ftp.gnome.org/pub/GNOME/sources/pango/`getver.py pango 2`/pango-`getver.py pango`.tar.xz -L -o pango.tar.xz && \
    unxz pango.tar.xz && \
    mkdir pango && \
    tar -xf pango.tar -C pango --strip-components 1 && \
    rm -f pango.tar && \
    cd pango && \
    meson --prefix=/usr/local --buildtype=release -Dintrospection=disabled _build && \
    cd _build && \
    ninja -j ${JOBS} && \
    ninja -j ${JOBS} install && \
    ldconfig && \
    echo "`date` pango" >> /build/log.txt

RUN \
    echo "`date` libde265" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py libde265` -c advice.detachedHead=false https://github.com/strukturag/libde265.git && \
    cd libde265 && \
    ./autogen.sh && \
    ./configure --silent --prefix=/usr/local --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    find . -name '*.a' -delete && \
    echo "`date` libde265" >> /build/log.txt

RUN \
    echo "`date` librsvg" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export PATH="$HOME/.cargo/bin:$PATH" && \
    curl --retry 5 --silent https://download.gnome.org/sources/librsvg/`getver.py librsvg 2`/librsvg-`getver.py librsvg`.tar.xz -L -o librsvg.tar.xz && \
    unxz librsvg.tar.xz && \
    mkdir librsvg && \
    tar -xf librsvg.tar -C librsvg --strip-components 1 && \
    rm -f librsvg.tar && \
    cd librsvg && \
    sed -i 's/ tests doc win32//g' Makefile.in && \
    sed -i 's/install-man install/install/g' Makefile.in && \
    export RUSTFLAGS="$RUSTFLAGS -O -C link_args=-Wl,--strip-debug,--strip-discarded,--discard-local" && \
    GI_DOCGEN=`which true` \
    RST2MAN=`which true` \
    ./configure --silent --prefix=/usr/local --disable-introspection --disable-debug --disable-static && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig && \
    # rust leaves huge build artifacts that aren't useful to us \
    rm -rf target/release/deps && \
    find . -name '*.a' -delete && \
    echo "`date` librsvg" >> /build/log.txt

RUN \
    echo "`date` libgsf" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export PATH="$HOME/.cargo/bin:$PATH" && \
    curl --retry 5 --silent https://download.gnome.org/sources/libgsf/`getver.py libgsf 2`/libgsf-`getver.py libgsf`.tar.xz -L -o libgsf.tar.xz && \
    unxz libgsf.tar.xz && \
    mkdir libgsf && \
    tar -xf libgsf.tar -C libgsf --strip-components 1 && \
    rm -f libgsf.tar && \
    cd libgsf && \
    ./configure --silent --prefix=/usr/local --disable-introspection --disable-static && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libgsf" >> /build/log.txt

RUN \
    echo "`date` libraw" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b `getver.py libraw` -c advice.detachedHead=false https://github.com/LibRaw/LibRaw.git && \
    cd LibRaw && \
    autoreconf -ifv && \
    ./configure --silent --prefix=/usr/local --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libraw" >> /build/log.txt

# We could install more packages for better ImageMagick support:
#  Autotrace DJVU DPS FLIF FlashPIX Ghostscript Graphviz LQR RAQM WMF
RUN \
    echo "`date` imagemagick" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b `getver.py imagemagick` -c advice.detachedHead=false https://github.com/ImageMagick/ImageMagick.git && \
    cd ImageMagick && \
    # Needed since 7.0.9-7 or so for manylinux2010 \
    # sed -i 's/__STDC_VERSION__ > 201112L/0/g' MagickCore/magick-config.h && \
    ./configure --prefix=/usr/local --with-modules --with-rsvg --with-fftw --with-jxl LIBS="-lrt `pkg-config --libs zlib`" --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` imagemagick" >> /build/log.txt

RUN \
    echo "`date` matio" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py matio` -c advice.detachedHead=false https://github.com/tbeu/matio.git && \
    cd matio && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    python -c $'# \n\
import os \n\
path = "/usr/local/lib64/pkgconfig/matio.pc" \n\
s = """Name: matio \n\
Description: matio library \n\
Version: """ + os.popen("getver.py matio").read() + """ \n\
Cflags: -I/usr/local/include \n\
Libs: -L/usr/local/lib64 -lmatio""" \n\
open(path, "w").write(s)' && \
    ldconfig && \
    echo "`date` matio" >> /build/log.txt

RUN \
    echo "`date` libexif" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py libexif` -c advice.detachedHead=false https://github.com/libexif/libexif.git && \
    cd libexif && \
    autoreconf -ifv && \
    ./configure --silent --prefix=/usr/local --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libexif" >> /build/log.txt

# vips doesn't have PDFium (it uses poppler instead)
RUN \
    echo "`date` libvips" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    # Something about library path resolution breaks if the local library \
    # paths are before the systemish paths.  Rearrange things to work around \
    # this until it can be figured out properly \
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH}:/usr/local/lib" && \
    mv /etc/ld.so.conf.d/00-manylinux.conf /tmp/00-manylinux.conf && \
    mv /etc/ld.so.conf.d/01-manylinux.conf /tmp/01-manylinux.conf && \
    # Use these lines for a release \
    curl --retry 5 --silent https://github.com/libvips/libvips/releases/download/v`getver.py libvips`/vips-`getver.py libvips`.tar.gz -L -o vips.tar.gz && \
    mkdir vips && \
    tar -zxf vips.tar.gz -C vips --strip-components 1 && \
    rm -f vips.tar.gz && \
    cd vips && \
    # Allow using VIPS_TMPDIR for the temp directory \
    sed -i 's/tmpd;/tmpd;if ((tmpd=g_getenv("VIPS_TMPDIR"))) return(tmpd);/g' libvips/iofuncs/util.c && \
    # Use these lines for master \
    # git clone --depth=1 https://github.com/libvips/libvips.git -c advice.detachedHead=false vips && \
    # cd vips && \
    # ./autogen.sh && \
    # Common \
    ./configure --prefix=/usr/local CFLAGS="$CFLAGS `pkg-config --cflags glib-2.0`" LIBS="`pkg-config --libs glib-2.0`" --disable-static --disable-modules && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    # Undo the library path workaround \
    mv /tmp/00-manylinux.conf /etc/ld.so.conf.d/00-manylinux.conf && \
    mv /tmp/01-manylinux.conf /etc/ld.so.conf.d/01-manylinux.conf && \
    ldconfig && \
    echo "`date` libvips" >> /build/log.txt

RUN \
    echo "`date` pyvips" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py pyvips` -c advice.detachedHead=false https://github.com/libvips/pyvips.git && \
    cd pyvips && \
    python -c $'# \n\
path = "pyvips/__init__.py" \n\
s = open(path).read().replace( \n\
"""    import _libvips""", \n\
"""    import ctypes \n\
    import os \n\
    libpath = os.path.abspath(os.path.join(os.path.dirname(os.path.dirname(os.path.realpath( \n\
        __file__))), \'pyvips.libs\')) \n\
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
    cp /usr/local/bin/magick pyvips/bin/. && \
    strip pyvips/bin/* --strip-unneeded -p -D && \
    python -c $'# \n\
path = "pyvips/bin/__init__.py" \n\
s = """import os \n\
import sys \n\
\n\
def program(): \n\
    path = os.path.join(os.path.dirname(__file__), os.path.basename(sys.argv[0])) \n\
    os.execv(path, sys.argv) \n\
""" \n\
open(path, "w").write(s)' && \
    python -c $'# \n\
path = "setup.py" \n\
s = open(path).read().replace("from os import path", \n\
"""from os import path \n\
import os""").replace( \n\
"""packages=pyvips_packages,""", \n\
"""packages=pyvips_packages, \n\
        include_package_data=True, \n\
        package_data={\'pyvips\': [\'bin/*\']}, \n\
        entry_points={\'console_scripts\': [\'%s=pyvips.bin:program\' % name for name in os.listdir(\'pyvips/bin\') if not name.endswith(\'.py\')]},""") \n\
open(path, "w").write(s)' && \
    # Strip libraries before building any wheels \
    # strip --strip-unneeded -p -D /usr/local/lib{,64}/*.{so,a} && \
    find /usr/local \( -name '*.so' -o -name '*.a' \) -exec bash -c "strip -p -D --strip-unneeded {} -o /tmp/striped; if ! cmp {} /tmp/striped; then cp /tmp/striped {}; fi; rm -f /tmp/striped" \; && \
    find /opt/py -mindepth 1 -print0 | xargs -n 1 -0 -P 1 bash -c '"${0}/bin/pip" wheel . --no-deps -w /io/wheelhouse; git clean -fxd -e pyvips/bin' && \
    find /io/wheelhouse/ -name 'pyvips*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} auditwheel repair --only-plat --plat manylinux2014_x86_64 -w /io/wheelhouse && \
    find /io/wheelhouse/ -name 'pyvips*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v && \
    find /io/wheelhouse/ -name 'pyvips*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} advzip -k -z && \
    ls -l /io/wheelhouse && \
    rm -rf ~/.cache && \
    echo "`date` pyvips" >> /build/log.txt

RUN \
    echo "`date` cyrus-sasl" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b cyrus-sasl-`getver.py cyrus-sasl` -c advice.detachedHead=false https://github.com/cyrusimap/cyrus-sasl.git && \
    cd cyrus-sasl && \
    ./autogen.sh && \
    ./configure --prefix=/usr/local --disable-static --disable-sample --enable-obsolete_cram_attr --enable-obsolete_digest_attr --enable-alwaystrue --enable-checkapop --enable-cram --enable-digest --enable-scram --enable-otp --enable-srp --enable-srp-setpass --enable-krb4 --enable-auth-sasldb --enable-httpform --enable-plain --enable-anon --enable-login --enable-ntlm --enable-passdss --enable-sql --enable-ldapdb --with-ldap && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` cyrus-sasl" >> /build/log.txt

RUN \
    echo "`date` libmemcached" >> /build/log.txt && \
    export JOBS=`nproc` && \
    # curl --retry 5 --silent https://launchpad.net/libmemcached/`getver.py libmemcached 2`/`getver.py libmemcached`/+download/libmemcached-`getver.py libmemcached`.tar.gz -L -o libmemcached.tar.gz && \
    # mkdir libmemcached && \
    # tar -zxf libmemcached.tar.gz -C libmemcached --strip-components 1 && \
    # rm -f libmemcached.tar.gz && \
    git clone --single-branch -b `getver.py libmemcached` -c advice.detachedHead=false https://github.com/memcachier/libmemcached.git && \
    cd libmemcached && \
    autoreconf -ifv && \
    sed -i 's/install-man install/install/g' Makefile.in && \
    CXXFLAGS='-fpermissive' ./configure --prefix=/usr/local --disable-static && \
    # For some reason, this doesn't run jobs in parallel, with or without -j \
    # make --silent -j ${JOBS} && \
    # make --silent -j ${JOBS} install && \
    # Don't build docs; they are what takes the most time \
    make --silent -j ${JOBS} install-exec install-data install-includeHEADERS install-libLTLIBRARIES install-binPROGRAMS && \
    ldconfig && \
    echo "`date` libmemcached" >> /build/log.txt

# PINNED VERSION - use master to get fixes for some bugs.  If a new release is
# made, we can go back to the latest release.
RUN \
    echo "`date` pylibmc" >> /build/log.txt && \
    export JOBS=`nproc` && \
    # Use master branch \
    git clone --depth=1 --single-branch -c advice.detachedHead=false https://github.com/lericson/pylibmc.git && \
    # Use latest release branch \
    # git clone --depth=1 --single-branch -b `getver.py pylibmc` -c advice.detachedHead=false https://github.com/lericson/pylibmc.git && \
    # Common \
    cd pylibmc && \
    sed -i 's/-dev//g' src/pylibmc-version.h && \
    # Strip libraries before building any wheels \
    # strip --strip-unneeded -p -D /usr/local/lib{,64}/*.{so,a} && \
    find /usr/local \( -name '*.so' -o -name '*.a' \) -exec bash -c "strip -p -D --strip-unneeded {} -o /tmp/striped; if ! cmp {} /tmp/striped; then cp /tmp/striped {}; fi; rm -f /tmp/striped" \; && \
    # Copy sasl2 plugins to a local directory so they can be deployed with \
    # the wheel \
    mkdir src/pylibmc/sasl2 && \
    find /usr/local/lib/sasl2 -name '*.so' -exec cp {} src/pylibmc/sasl2/. \; && \
    sed -i 's/"memcached"/"memcached","sasl2"/g' setup.py && \
    sed -i 's/packages=/package_data={"pylibmc":["sasl2\/*"]},include_package_data=True,packages=/g' setup.py && \
    python -c $'# \n\
path = "src/pylibmc/__init__.py" \n\
s = open(path).read().replace( \n\
    "import _pylibmc", \n\
""" \n\
import os \n\
_localpath = os.path.dirname(os.path.abspath( __file__ )) \n\
os.environ.setdefault("SASL_PATH", os.path.join(_localpath, "sasl2")) \n\
\n\
import _pylibmc \n\
""") \n\
open(path, "w").write(s)' && \
    find /opt/py -mindepth 1 -print0 | xargs -n 1 -0 -P 1 bash -c '"${0}/bin/pip" wheel . --no-deps -w /io/wheelhouse && rm -rf build' && \
    find /io/wheelhouse/ -name 'pylibmc*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} auditwheel repair --only-plat --plat manylinux2014_x86_64 -w /io/wheelhouse && \
    find /io/wheelhouse/ -name 'pylibmc*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v && \
    find /io/wheelhouse/ -name 'pylibmc*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} advzip -k -z && \
    ls -l /io/wheelhouse && \
    rm -rf ~/.cache && \
    echo "`date` pylibmc" >> /build/log.txt

RUN \
    echo "`date` python-javabridge" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py python-javabridge` -c advice.detachedHead=false https://github.com/CellProfiler/python-javabridge.git && \
    cd python-javabridge && \
    # Include java libraries \
    mkdir javabridge/jvm && \
    cp -r -L /usr/lib/jvm/java/* javabridge/jvm/. && \
    # use a placeholder for the jar files to reduce the docker file size; \
    # they'll be restored later && \
    find javabridge/jvm -name '*.jar' -exec bash -c "echo placeholder > {}" \; && \
    # libsaproc.so is only used for debugging \
    rm -f javabridge/jvm/jre/lib/amd64/libsaproc.so && \
    # allow installing binaries \
    python -c $'# \n\
path = "javabridge/jvm/bin/__init__.py" \n\
s = """import os \n\
import sys \n\
\n\
def program(): \n\
    path = os.path.join(os.path.dirname(__file__), os.path.basename(sys.argv[0])) \n\
    os.execv(path, sys.argv) \n\
""" \n\
open(path, "w").write(s)' && \
    python -c $'# \n\
import re \n\
path = "setup.py" \n\
s = open(path).read() \n\
s = s.replace("""packages=[\'javabridge\',""", """packages=[\'javabridge\', \'javabridge.jvm.bin\',""") \n\
s = s.replace("entry_points={", \n\
"""entry_points={\'console_scripts\': [\'%s=javabridge.jvm.bin:program\' % name for name in os.listdir(\'javabridge/jvm/bin\') if not name.endswith(\'.py\')], """) \n\
s = s.replace("""package_data={"javabridge": [""", \n\
"""package_data={"javabridge": [\'jvm/*\', \'jvm/*/*\', \'jvm/*/*/*\', \'jvm/*/*/*/*\', \'jvm/*/*/*/*/*\', """) \n\
s = re.sub(r"(numpy)[>=.0-9]*", "numpy", s) \n\
open(path, "w").write(s)' && \
    python -c $'# \n\
path = "javabridge/__init__.py" \n\
s = open(path).read() \n\
s = s.replace("if sys.platform.startswith(\'linux\'):", \n\
"""if os.path.split(sys.argv[0])[-1] == \'java\': \n\
    pass \n\
elif sys.platform.startswith(\'linux\'):""") \n\
open(path, "w").write(s)' && \
    # use the java libraries we included \
    python -c $'# \n\
path = "javabridge/jutil.py" \n\
s = open(path).read() \n\
s = s.replace("import javabridge._javabridge as _javabridge", \n\
"""libjvm_path = os.path.join(os.path.dirname(__file__), "jvm", "jre", "lib", "amd64", "server", "libjvm.so") \n\
if os.path.exists(libjvm_path): \n\
    import ctypes \n\
    ctypes.CDLL(libjvm_path) \n\
import javabridge._javabridge as _javabridge""") \n\
open(path, "w").write(s)' && \
    python -c $'# \n\
path = "javabridge/locate.py" \n\
s = open(path).read() \n\
s = s.replace("jdk_dir = os.path.abspath(jdk_dir)", \n\
"""jvm_path = os.path.join(os.path.dirname(__file__), "jvm") \n\
        if os.path.exists(jvm_path): \n\
            jdk_dir = jvm_path \n\
        jdk_dir = os.path.abspath(jdk_dir)""") \n\
open(path, "w").write(s)' && \
    # export library paths so that auditwheel doesn't complain \
    export LD_LIBRARY_PATH="/usr/lib/jvm/jre/lib/amd64/:/usr/lib/jvm/jre/lib/amd64/jli:/usr/lib/jvm/jre/lib/amd64/client:/usr/lib/jvm/jre/lib/amd64/server:$LD_LIBRARY_PATH" && \
    # Strip libraries before building any wheels \
    # strip --strip-unneeded -p -D /usr/local/lib{,64}/*.{so,a} && \
    find /usr/local \( -name '*.so' -o -name '*.a' \) -exec bash -c "strip -p -D --strip-unneeded {} -o /tmp/striped; if ! cmp {} /tmp/striped; then cp /tmp/striped {}; fi; rm -f /tmp/striped" \; && \
    find /opt/py -mindepth 1 -print0 | xargs -n 1 -0 -P 1 bash -c '"${0}/bin/pip" wheel . --no-deps -w /io/wheelhouse && rm -rf .eggs build' && \
    find /io/wheelhouse/ -name 'python_javabridge*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} auditwheel repair --only-plat --plat manylinux2014_x86_64 -w /io/wheelhouse && \
    # auditwheel modifies the java libraries, but some of those have \
    # hard-coded relative paths, which doesn't work.  Replace them with the \
    # unmodified versions.  See https://stackoverflow.com/questions/55904261 \
    find /io/wheelhouse/ -name 'python_javabridge*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} bash -c 'mkdir /tmp/ptmp$(basename ${0}) && pushd /tmp/ptmp$(basename ${0}) && unzip ${0} && cp -f -r -L /usr/lib/jvm/java/* javabridge/jvm/. && fix_record.py && zip -r ${0} * && popd && rm -rf /tmp/ptmp$(basename ${0})' && \
    find /io/wheelhouse/ -name 'python_javabridge*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v && \
    find /io/wheelhouse/ -name 'python_javabridge*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} advzip -k -z && \
    ls -l /io/wheelhouse && \
    rm -rf ~/.cache && \
    echo "`date` python-javabridge" >> /build/log.txt
