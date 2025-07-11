ARG baseimage
FROM ${baseimage:-quay.io/pypa/manylinux2014_x86_64}
# FROM quay.io/pypa/manylinux2014_x86_64
# With docker build-kit, to debug a specific build step, use
#   FROM quay.io/pypa/manylinux2014_x86_64 as working
# and add just before the build step to debug
#   FROM working
# Then do
#   docker build --force-rm --target=working .

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
    chrpath \
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
    # for mysql \
    ncurses-devel \
    # for postrges \
    readline-devel \
    # for epsilon \
    bzip2-devel \
    popt-devel \
    # for MrSID \
    tbb-devel \
    # for easier development \
    man \
    gtk-doc \
    vim-enhanced \
    && \
    if [ "$AUDITWHEEL_ARCH" == "x86_64" ]; then \
    yum install -y \
    # for librasterlite2 \
    fcgi-devel \
    # more support for GDAL \
    json-c12-devel \
    # for netcdf \
    hdf-devel \
    # needed for mysql to use newer versions of xz with mysql \
    devtoolset-11-gcc \
    devtoolset-11-gcc-c++ \
    devtoolset-11-binutils \
    && true; \
    elif [ "$AUDITWHEEL_ARCH" == "aarch64" ]; then \
    yum install -y \
    perl-LWP-Protocol-https \
    # more support for GDAL \
    json-c-devel.aarch64 \
    # needed for mysql to use newer versions of xz with mysql \
    gcc-toolset-13-gcc \
    gcc-toolset-13-gcc-c++ \
    gcc-toolset-13-binutils \
    gcc-toolset-13-annobin-annocheck \
    gcc-toolset-13-annobin-plugin-gcc \
    && true; \
    fi && \
    yum clean all && \
    echo "`date` yum install" >> /build/log.txt

ARG PYPY
# Don't build some versions of python.
RUN \
    echo "`date` rm python versions" >> /build/log.txt && \
    mkdir /opt/py && \
    ln -s /opt/python/* /opt/py/. && \
    # Enable all versions in boost as well \
    rm -rf /opt/py/cp36* && \
    rm -rf /opt/py/cp37* && \
    # We can't handle the no-gil variant yet (pyproj and lxml don't work yet) \
    rm -rf /opt/py/cp313-cp313t && \
    rm -rf /opt/py/cp314* && \
    if [ "$PYPY" = true ]; then \
    echo "Only building pypy versions" && \
    rm -rf /opt/py/cp* && \
    true; \
    elif [ "$PYPY" = false ]; then \
    echo "Only building cpython versions" && \
    rm -rf /opt/py/pp* && \
    true; \
    else \
    echo "Building cpython and pypy versions" && \
    true; \
    fi && \
    echo "`date` rm python versions" >> /build/log.txt

ARG SOURCE_DATE_EPOCH
ENV SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1667497300} \
    HOSTNAME=large_image_wheels \
    CFLAGS="-g0 -O2 -DNDEBUG" \
    LDFLAGS="-Wl,--strip-debug,--strip-discarded,--discard-locals" \
    PATH="/venv/bin:$PATH" \
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
    export PATH="/opt/python/cp39-cp39/bin:$PATH" && \
    pip3 install --no-cache-dir virtualenv && \
    virtualenv -p python3.9 /venv && \
    echo "`date` virtualenv" >> /build/log.txt

COPY getver.py fix_record.py /usr/local/bin/

# The openslide-vendor-mirax.c.patch allows girder's file layout to work with
# mirax files and does no harm otherwise.
COPY versions.txt \
    mapnik_projection.cpp.patch \
    mapnik_setup.py.patch \
    openslide-vendor-mirax.c.patch \
    python-javabridge.pyx.patch \
    ./

# Newer version of pkg-config than available in manylinux
RUN \
    echo "`date` pkg-config" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    until timeout 60 git clone --depth=1 --single-branch -b pkg-config-`getver.py pkg-config` -c advice.detachedHead=false https://gitlab.freedesktop.org/pkg-config/pkg-config.git; do sleep 5; echo "retrying"; done && \
    cd pkg-config && \
    sed -i 's/m4_copy/m4_copy_force/g' glib/m4macros/glib-gettext.m4 && \
    ./autogen.sh && \
    ./configure --silent --prefix=/usr/local --with-internal-glib --disable-host-tool --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    echo "`date` pkg-config" >> /build/log.txt

# Some of these paths are added later
ENV PKG_CONFIG=/usr/local/bin/pkg-config \
    PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/local/lib64/pkgconfig:/usr/share/pkgconfig
# We had been doing:
#     PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/local/lib64/pkgconfig:/usr/lib64/pkgconfig:/usr/share/pkgconfig \
# but we don't want to find the built-in libraries, as if we bind to them, we
# probably are not portable.

# CMake - use a precompiled binary
RUN \
    echo "`date` cmake" >> /build/log.txt && \
    curl --retry 5 --silent https://github.com/Kitware/CMake/releases/download/v`getver.py cmake`/cmake-`getver.py cmake`-Linux-${AUDITWHEEL_ARCH}.tar.gz -L -o cmake.tar.gz && \
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
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel -DZLIB_BUILD_EXAMPLES=OFF && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` zlib" >> /build/log.txt && \
cd /build && \
# \
# RUN \
    echo "`date` krb5" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b krb5-`getver.py krb5`-final -c advice.detachedHead=false https://github.com/krb5/krb5.git && \
    cd krb5/src && \
    autoreconf -ifv && \
    ./configure --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` krb5" >> /build/log.txt && \
cd /build && \
# \
# # Make our own openssl so we don't depend on system libraries. \
# RUN \
    echo "`date` openssl" >> /build/log.txt && \
    git clone --depth=1 --single-branch -b openssl-`getver.py openssl` -c advice.detachedHead=false https://github.com/openssl/openssl.git openssl && \
    cd openssl && \
    ./config --prefix=/usr/local --openssldir=/usr/local/ssl shared zlib no-tests && \
    make --silent -j ${JOBS} && \
    # using "all install_sw" rather than "install" to avoid installing docs \
    make --silent -j ${JOBS} all install_sw && \
    ldconfig && \
    echo "`date` openssl" >> /build/log.txt && \
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
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel -DENABLE_ZLIB_COMPRESSION=ON -DBUILD_EXAMPLES=OFF -DBUILD_SHARED_LIBS=ON && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libssh2" >> /build/log.txt && \
cd /build && \
# \
# RUN \
    echo "`date` libpsl" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b `getver.py libpsl` -c advice.detachedHead=false https://github.com/rockdaboot/libpsl.git && \
    cd libpsl && \
    ./autogen.sh && \
    ./configure --silent --prefix=/usr/local --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libpsl" >> /build/log.txt && \
# \
# RUN \
cd /build && \
    echo "`date` libidn2" >> /build/log.txt && \
    export JOBS=`nproc` && \
    curl --retry 5 --silent https://ftp.gnu.org/gnu/libidn/libidn2-`getver.py libidn2`.tar.gz -L -o libidn2.tar.gz && \
    mkdir libidn2 && \
    tar -zxf libidn2.tar.gz -C libidn2 --strip-components 1 && \
    rm -f libidn2.tar.gz && \
    cd libidn2 && \
    ./configure --silent --prefix=/usr/local --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libidn2" >> /build/log.txt && \
cd /build && \
# \
# # Make our own curl so we don't depend on system libraries. \
# RUN \
    echo "`date` curl" >> /build/log.txt && \
    export JOBS=`nproc` && \
    # The github releases have slightly different headers and are prefered \
    # git clone --depth=1 --single-branch -b curl-`getver.py curl` -c advice.detachedHead=false https://github.com/curl/curl.git && \
    curl --retry 5 --silent https://github.com/curl/curl/releases/download/curl-`getver.py curl`/curl-`getver.py curl 3 _ .`.tar.gz -L -o curl.tar.gz && \
    mkdir curl && \
    tar -zxf curl.tar.gz -C curl --strip-components 1 && \
    rm -f curl.tar.gz && \
    cd curl && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel -DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF -DBUILD_STATIC=OFF -DCURL_CA_FALLBACK=ON -DBUILD_LIBCURL_DOCS=OFF -DBUILD_MISC_DOCS=OFF && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    # Installing our own curl breaks the python 2.7 pycurl used by yum.  This \
    # is annoying, so patch the yum script in case we want to use it later \
    python -c $'# \n\
path = "/usr/bin/yum" \n\
s = open(path).read().replace( \n\
    "import sys", \n\
"""import ctypes \n\
ctypes.cdll.LoadLibrary("/usr/lib64/libcurl.so.4") \n\
ctypes.cdll.LoadLibrary("/usr/lib64/liblzma.so.5") \n\
import os \n\
os.environ["LD_LIBRARY_PATH"] = "/usr/lib64:" + os.environ["LD_LIBRARY_PATH"] \n\
import sys""") \n\
open(path, "w").write(s)' && \
    echo "`date` curl" >> /build/log.txt && \
cd /build && \
# \
# RUN \
    echo "`date` zlib-ng" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b `getver.py zlib-ng` -c advice.detachedHead=false https://github.com/zlib-ng/zlib-ng.git zlib-ng && \
    cd zlib-ng && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel -DZLIB_COMPAT=ON -DZLIB_ENABLE_TESTS=OFF -DINSTALL_GTEST=OFF -DBUILD_GMOCK=OFF && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    /usr/bin/cp -f ./libz* /usr/local/lib/. && \
    echo "`date` zlib-ng" >> /build/log.txt

RUN \
    echo "`date` strip-nondeterminism" >> /build/log.txt && \
    cpanm Archive::Cpio && \
    git clone --depth=1 --single-branch -b `getver.py strip-nondeterminism` -c advice.detachedHead=false https://github.com/esoule/strip-nondeterminism.git && \
    cd strip-nondeterminism && \
    perl Makefile.PL && \
    make && \
    make install && \
    echo "`date` strip-nondeterminism" >> /build/log.txt

# PINNED - patchelf 0.17.0 (specifically
# https://github.com/NixOS/patchelf/pull/430) breaks some of our output - see
# https://github.com/pypa/manylinux/issues/1421
RUN \
    echo "`date` patchelf" >> /build/log.txt && \
    export JOBS=`nproc` && \
    # git clone --depth=1 --single-branch -b `getver.py patchelf` -c advice.detachedHead=false https://github.com/NixOS/patchelf && \
    git clone --depth=1 --single-branch -b 0.16.1 -c advice.detachedHead=false https://github.com/NixOS/patchelf && \
    cd patchelf && \
    ./bootstrap.sh && \
    ./configure --silent --prefix=/usr/local && \
    make -j `nproc` && \
    make -j `nproc` install && \
    ldconfig && \
    echo "`date` patchelf" >> /build/log.txt

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
    sed -i 's/ZIP_DEFLATED/ZIP_STORED/g' /opt/_internal/pipx/venvs/auditwheel/lib/python3.12/site-packages/auditwheel/tools.py && \
    echo "`date` advancecomp" >> /build/log.txt

RUN \
    echo "`date` auditwheel" >> /build/log.txt && \
    # vips doesn't work with auditwheel 3.2 since the copylib doesn't adjust \
    # rpaths the same as 3.1.1.  Revert that aspect of the behavior. \
    sed -i 's/patcher.set_rpath(dest_path, dest_dir)/new_rpath = os.path.relpath(dest_dir, os.path.dirname(dest_path))\n        new_rpath = os.path.join('\''$ORIGIN'\'', new_rpath)\n        patcher.set_rpath(dest_path, new_rpath)/g' /opt/_internal/pipx/venvs/auditwheel/lib/python3.12/site-packages/auditwheel/repair.py && \
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
    "libgobject-2.0.so.0", "Xlibgobject-2.0.so.0").replace( \n\
    "libgthread-2.0.so.0", "Xlibgthread-2.0.so.0").replace( \n\
    "libglib-2.0.so.0", "Xlibglib-2.0.so.0").replace( \n\
    "XlibXext.so.6", "libjvm.so") \n\
open(path, "w").write(data)' && \
    echo "`date` auditwheel" >> /build/log.txt

# Use an older version of numpy -- we can work with newer versions, but have to
# have at least this version to use our wheels.
RUN \
    echo "`date` numpy" >> /build/log.txt && \
    export JOBS=`nproc` && \
    find /opt/py -mindepth 1 -print0 | xargs -n 1 -0 -P 1 bash -c '"${0}/bin/pip" install --no-cache-dir --root-user-action=ignore '\''oldest-supported-numpy; python_version < "3.9"'\'' '\''numpy; python_version >= "3.9"'\''' && \
    echo "`date` numpy" >> /build/log.txt

# # Build psutil for Python versions not published on pypi
# RUN \
#     echo "`date` psutil" >> /build/log.txt && \
#     export JOBS=`nproc` && \
#     git clone --depth=1 --single-branch -b release-`getver.py psutil` -c advice.detachedHead=false https://github.com/giampaolo/psutil.git && \
#     cd psutil && \
#     # Strip libraries before building any wheels \
#     # strip --strip-unneeded -p -D /usr/local/lib{,64}/*.{so,a} && \
#     find /usr/local \( -name '*.so' -o -name '*.a' \) -exec bash -c "strip -p -D --strip-unneeded {} -o /tmp/striped; if ! cmp {} /tmp/striped; then cp /tmp/striped {}; fi; rm -f /tmp/striped" \; && \
#     if [ "$PYPY" = true ]; then \
#     find /opt/py -mindepth 1 -print0 | xargs -n 1 -0 -P 1 bash -c '"${0}/bin/pip" wheel . --no-deps -w /io/wheelhouse && rm -rf build' && \
#     true; \
#     else \
#     # only build for python 3.6 \
#     # find /opt/py -mindepth 1 -name '*p36-*' -print0 | xargs -n 1 -0 -P 1 bash -c '"${0}/bin/pip" wheel . --no-deps -w /io/wheelhouse && rm -rf build' && \
#     true; \
#     fi && \
#     if find /io/wheelhouse/ -name 'psutil*.whl' | grep .; then \
#     find /io/wheelhouse/ -name 'psutil*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} auditwheel repair --only-plat --plat ${AUDITWHEEL_PLAT} -w /io/wheelhouse && \
#     find /io/wheelhouse/ -name 'psutil*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v && \
#     find /io/wheelhouse/ -name 'psutil*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} advzip -k -z && \
#     ls -l /io/wheelhouse && \
#     true; \
#     fi && \
#     rm -rf ~/.cache && \
#     echo "`date` psutil" >> /build/log.txt

RUN \
    echo "`date` libzip" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py libzip` -c advice.detachedHead=false https://github.com/nih-at/libzip.git && \
    cd libzip && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel -DBUILD_EXAMPLES=OFF && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libzip" >> /build/log.txt && \
cd /build && \
# \
# RUN \
    echo "`date` lcms2" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b lcms`getver.py lcms2` -c advice.detachedHead=false https://github.com/mm2/Little-CMS.git && \
    cd Little-CMS && \
    ./configure --silent --prefix=/usr/local --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` lcms2" >> /build/log.txt && \
cd /build && \
# \
# Used by libtiff, gdal, mapnik, openslide, glymur \
# RUN \
    echo "`date` openjpeg" >> /build/log.txt && \
    export JOBS=`nproc` && \
    curl --retry 5 --silent https://github.com/uclouvain/openjpeg/archive/v`getver.py openjpeg`.tar.gz -L -o openjpeg.tar.gz && \
    mkdir openjpeg && \
    tar -zxf openjpeg.tar.gz -C openjpeg --strip-components 1 && \
    rm -f openjpeg.tar.gz && \
    cd openjpeg && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel -DBUILD_SHARED=ON -DBUILD_STATIC=OFF && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` openjpeg" >> /build/log.txt

RUN \
    echo "`date` libpng" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py libpng` -c advice.detachedHead=false https://github.com/glennrp/libpng.git && \
    cd libpng && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel && \
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
    sed -i 's/\$(MAKE) -C doc/echo/g' Makefile && \
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
    mkdir _build && \
    cd _build && \
    cmake ../build/cmake -DCMAKE_BUILD_TYPE=MinSizeRel -DZSTD_BUILD_STATIC=OFF -DZSTD_LZ4_SUPPORT=ON -DZSTD_LZMA_SUPPORT=ON -DZSTD_ZLIB_SUPPORT=ON -DZSTD_BUILD_PROGRAMS=OFF && \
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
    # If we build with cmake, libvips throws an exception when we try to use \
    # webp encoding. \
    # mkdir _build && \
    # cd _build && \
    # cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel && \
    ./configure --silent --prefix=/usr/local --enable-libwebpmux --enable-libwebpdecoder --enable-libwebpextras --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libwebp" >> /build/log.txt

# Used in gdal, mapnik, libvips, openslide, glymur, python-javabridge
RUN \
    echo "`date` libjpeg-turbo" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export CFLAGS="$CFLAGS -O3" && \
    export CXXFLAGS="$CXXFLAGS -O3" && \
    git clone --depth=1 --single-branch -b `getver.py libjpeg-turbo` -c advice.detachedHead=false https://github.com/libjpeg-turbo/libjpeg-turbo.git && \
    cd libjpeg-turbo && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel -DCMAKE_INSTALL_PREFIX=/usr/local -DBUILD=${SOURCE_DATE_EPOCH} && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    echo "`date` libjpeg-turbo" >> /build/log.txt

# Used in gdal, mapnik, libvips, openslide, glymur
RUN \
    echo "`date` libdeflate" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py libdeflate` -c advice.detachedHead=false https://github.com/ebiggers/libdeflate.git && \
    cd libdeflate && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libdeflate" >> /build/log.txt

# Used in gdal, mapnik, libvips, openslide, glymur.  Image compression format
RUN \
    echo "`date` lerc" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py lerc` -c advice.detachedHead=false https://github.com/Esri/lerc.git && \
    cd lerc && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` lerc" >> /build/log.txt && \
cd /build && \
# \
# Used by libvips.  SIMD/Vector functions \
# RUN \
    echo "`date` libhwy" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b `getver.py libhwy` -c advice.detachedHead=false https://github.com/google/highway.git && \
    cd highway && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel -DBUILD_TESTING=OFF -DHWY_ENABLE_EXAMPLES=OFF -DBUILD_SHARED_LIBS=ON -DCMAKE_CXX_FLAGS='-DVQSORT_SECURE_SEED=0' && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libhwy" >> /build/log.txt && \
cd /build && \
# \
# Used by gdal, mapnik, libvips.  High dynamic range images \
# RUN \
    echo "`date` openexr" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py openexr` -c advice.detachedHead=false https://github.com/AcademySoftwareFoundation/openexr.git && \
    cd openexr && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel -DBUILD_TESTING=OFF -DOPENEXR_BUILD_EXAMPLES=OFF && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` openexr" >> /build/log.txt && \
cd /build && \
# \
# Used by gdal, mapnik, libvips, openslide, javabridge.  Lossless compression \
# RUN \
    echo "`date` libbrotli" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py libbrotli` -c advice.detachedHead=false https://github.com/google/brotli.git && \
    cd brotli && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel -DBUILD_TESTING=OFF && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libbrotli" >> /build/log.txt && \
cd /build && \
# \
# Used by gdal, mapnik, vips \
# RUN \
    echo "`date` jpeg-xl" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py jpeg-xl` -c advice.detachedHead=false --recurse-submodules -j ${JOBS} https://github.com/libjxl/libjxl.git && \
    cd libjxl && \
    find . -name '.git' -exec rm -rf {} \+ && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel -DBUILD_TESTING=OFF -DCMAKE_CXX_FLAGS='-fpermissive' -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_MANPAGES=OFF -DJPEGXL_ENABLE_BENCHMARK=OFF -DHWY_ENABLE_INSTALL=OFF -DHWY_ENABLE_TESTS=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` jpeg-xl" >> /build/log.txt

# Used by mysql, gdal, mapnik, openslide, libtiff, glymur
# PINNED to work with MySQL and with libvips
RUN \
    echo "`date` xz" >> /build/log.txt && \
    export JOBS=`nproc` && \
    ## It'd be better to use the most recent \
    if false; then \
    git clone --depth=1 --single-branch -b v`getver.py xz` -c advice.detachedHead=false https://github.com/tukaani-project/xz.git && \
    cd xz && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel -DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF && \
    true; else \
    ## But that breaks a bunch of packages \
    # curl --retry 5 --silent https://downloads.sourceforge.net/project/lzmautils/xz-`getver.py xz`.tar.gz -L -o xz.tar.gz && \
    curl --retry 5 --silent https://downloads.sourceforge.net/project/lzmautils/xz-5.2.6.tar.gz -L -o xz.tar.gz && \
    mkdir xz && \
    tar -zxf xz.tar.gz -C xz --strip-components 1 && \
    rm -f xz.tar.gz && \
    cd xz && \
    ./configure --silent --prefix=/usr/local --disable-static && \
    true; fi && \
    ## This is in common \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` xz" >> /build/log.txt

RUN \
    echo "`date` libtiff" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export CFLAGS="$CFLAGS -O3" && \
    export CXXFLAGS="$CXXFLAGS -O3" && \
    git clone --depth=1 --single-branch -b v`getver.py libtiff` -c advice.detachedHead=false https://gitlab.com/libtiff/libtiff.git && \
    cd libtiff && \
    # We could use cmake here, but it seems to have a harder time sorting the \
    # two libjpeg versions \
    # mkdir _build && \
    # cd _build && \
    # cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel && \
    # # -DJPEG_INCLUDE_DIR=/build/libjpeg-turbo -DJPEG_LIBRARY_RELEASE=/build/libjpeg-turbo/libjpeg.so && \
    ./autogen.sh || true && \
    # for reasons I don't understand, configure changes $ORIGIN to RIGIN (or, \
    # more generally, elides $O.  Use a placeholder values and chrpath to fix \
    # it afterwards \
    export LDFLAGS="$LDFLAGS"',-rpath,OORIGIN' && \
    ./configure --prefix=/usr/local \
    --disable-static \
    | tee configure.output && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    chrpath -r '$ORIGIN' /usr/local/lib/libtiff.so && \
    ldconfig && \
    chrpath -l /usr/local/lib/libtiff.so && \
    echo "`date` libtiff" >> /build/log.txt

# Rebuild openjpeg with our libtiff
RUN \
    echo "`date` openjpeg again" >> /build/log.txt && \
    export JOBS=`nproc` && \
    cd openjpeg/_build && \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel -DBUILD_SHARED=ON -DBUILD_STATIC=OFF && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` openjpeg again" >> /build/log.txt

RUN \
    echo "`date` pylibtiff" >> /build/log.txt && \
    export JOBS=`nproc` && \
    pip install -U setuptools-scm && \
    git clone --depth=1 --single-branch -b v`getver.py pylibtiff` -c advice.detachedHead=false https://github.com/pearu/pylibtiff.git && \
    cd pylibtiff && \
    mkdir libtiff/bin && \
    find /build/libtiff/tools/ -executable -not -type d -exec bash -c 'cp --dereference /usr/local/bin/"$(basename {})" libtiff/bin/.' \; && \
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
"""\'console_scripts\': [""", \n\
"""\'console_scripts\': \n\
        [\'%s=libtiff.bin:program\' % name for name in os.listdir(\'libtiff/bin\') if not name.endswith(\'.py\')] + [""") \n\
s = s.replace("name=\\"libtiff.tif_lzw\\",", \n\
"name=\\"libtiff.tif_lzw\\", libraries=[\'tiff\'],") \n\
# s = s.replace("python_requires=\'>=3.8\',", "") \n\
s = s.replace("packages=find_packages(),", \n\
    "packages=find_packages(), package_data={\'libtiff\': [\'bin/*\']},") \n\
open(path, "w").write(s)' && \
    python -c $'# \n\
path = "libtiff/libtiff_ctypes.py" \n\
s = open(path).read() \n\
s = s.replace( \n\
"""    libtiff = None if lib is None else ctypes.cdll.LoadLibrary(lib)""", \n\
"""    try: \n\
        libtiff = None if lib is None else ctypes.cdll.LoadLibrary(lib) \n\
    except Exception: \n\
        lib = None \n\
    if lib is None or True: \n\
        libpath = os.path.abspath(os.path.join(os.path.dirname(os.path.realpath( \n\
            __file__)), ".libs")) \n\
        if not os.path.exists(libpath): \n\
            libpath = os.path.abspath(os.path.join(os.path.dirname(os.path.dirname(os.path.realpath( \n\
                __file__))), "libtiff.libs")) \n\
        if not os.path.exists(libpath): \n\
            libpath = os.path.abspath(os.path.join(os.path.dirname(os.path.dirname(os.path.realpath( \n\
                __file__))), "pylibtiff.libs")) \n\
        try: \n\
            libs = os.listdir(libpath) \n\
            pospath = os.path.join(libpath, [flib for flib in libs if flib.startswith("libtiff-")][0]) \n\
            if os.path.exists(pospath): \n\
                lib = pospath \n\
        except Exception: \n\
            pass \n\
        libtiff = None if lib is None else ctypes.cdll.LoadLibrary(lib)""") \n\
s = s.replace("""print("Not trying""", """# print("Not trying""") \n\
open(path, "w").write(s)' && \
    sed -i 's/'\''oldest-supported-numpy'\''/'\''oldest-supported-numpy; python_version < "3.9"'\'', '\''numpy; python_version >= "3.9"'\''/g' pyproject.toml && \
    # We need numpy present in the default python to check the header. \
    # Ensure the correct header records.  This will generate a missing header \
    # companion file \
    pip install numpy && \
    (TIFF_HEADER_PATH=/build/libtiff/libtiff/tiff.h python libtiff/libtiff_ctypes.py || true) && \
    pip uninstall -y numpy && \
    # Increment version slightly \
    git config --global user.email "you@example.com" && \
    git config --global user.name "Your Name" && \
    git commit -a --amend -m x && \
    git tag `getver.py pylibtiff`.1 && \
    # Strip libraries before building any wheels \
    # strip --strip-unneeded -p -D /usr/local/lib{,64}/*.{so,a} && \
    find /usr/local \( -name '*.so' -o -name '*.a' \) -exec bash -c "strip -p -D --strip-unneeded {} -o /tmp/striped; if ! cmp {} /tmp/striped; then cp /tmp/striped {}; fi; rm -f /tmp/striped" \; && \
    for PYBIN in /opt/py/*/bin/; do \
      rm -rf build || true && \
      "${PYBIN}/python" -c 'import libtiff' || true && \
      "${PYBIN}/pip" wheel --no-deps . -w /io/wheelhouse; \
    done && \
    find /io/wheelhouse/ -name '*libtiff*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} auditwheel repair --only-plat --plat ${AUDITWHEEL_PLAT} -w /io/wheelhouse && \
    find /io/wheelhouse/ -name '*libtiff*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v && \
    find /io/wheelhouse/ -name '*libtiff*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} advzip -k -z && \
    ls -l /io/wheelhouse && \
    rm -rf ~/.cache && \
    echo "`date` pylibtiff" >> /build/log.txt

RUN \
    echo "`date` glymur" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py glymur` -c advice.detachedHead=false https://github.com/quintusdias/glymur.git && \
    cd glymur && \
    mkdir glymur/bin && \
    # Copy some jpeg tools \
    find /usr/local/bin -executable -type f -name 'opj_*' -exec cp {} glymur/bin/. \; && \
    cp /build/libjpeg-turbo/_build/{jpegtran,cjpeg,djpeg,rdjpgcom,wrjpgcom} glymur/bin/. && \
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
    if os.path.exists(libpath): \n\
        libs = os.listdir(libpath) \n\
        try: \n\
            pospath = os.path.join(libpath, [lib for lib in libs if "lib" + libname in lib][0]) \n\
            if os.path.exists(pospath): \n\
                path = pospath \n\
        except Exception: \n\
            pass""") \n\
open(path, "w").write(s)' && \
    python -c $'# \n\
import os \n\
import re \n\
path = "pyproject.toml" \n\
s = open(path).read() \n\
s = s.replace("jpeg2jp2 = \'glymur.command_line:jpeg2jp2\'", "jpeg2jp2 = \'glymur.command_line:jpeg2jp2\'" + "".join(["\\n%s = \'glymur.bin:program\'" % name for name in os.listdir("glymur/bin") if not name.endswith(".py")])) \n\
s = s.replace("requires-python = \'>=3.11\'", "requires-python = \'>=3.10\'") \n\
s += """ \n\
[tool.setuptools] \n\
include-package-data = true \n\
 \n\
[tool.setuptools.package-data] \n\
glymur = [ \n\
    "data/*.jp2", \n\
    "data/*.jpx", \n\
    "data/*.j2k", \n\
    "bin/*", \n\
] \n\
""" \n\
s = re.sub(r"(version = \')(\\d+\\.\\d+\\.\\d+)((?:post\\d+)?)(\')", r"\\1\\2.1\\3\\4", s) \n\
open(path, "w").write(s)' && \
    # Strip libraries before building any wheels \
    # strip --strip-unneeded -p -D /usr/local/lib{,64}/*.{so,a} && \
    find /usr/local \( -name '*.so' -o -name '*.a' \) -exec bash -c "strip -p -D --strip-unneeded {} -o /tmp/striped; if ! cmp {} /tmp/striped; then cp /tmp/striped {}; fi; rm -f /tmp/striped" \; && \
    find /opt/py -mindepth 1 -not -name '*p38-*' -a -not -name '*p39-*' -print0 | xargs -n 1 -0 -P 1 bash -c '"${0}/bin/pip" wheel . --no-deps -w /io/wheelhouse && rm -rf build' && \
    find /io/wheelhouse/ -name 'glymur*.whl' | while read file; do new_file=$(echo "$file" | sed 's|/glymur|/Glymur|'); mv "$file" "$new_file"; done && \
    find /io/wheelhouse/ -name 'Glymur*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} auditwheel repair --only-plat --plat ${AUDITWHEEL_PLAT} -w /io/wheelhouse && \
    find /io/wheelhouse/ -name 'Glymur*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v && \
    find /io/wheelhouse/ -name 'Glymur*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} advzip -k -z && \
    ls -l /io/wheelhouse && \
    rm -rf ~/.cache && \
    echo "`date` glymur" >> /build/log.txt

# Used by openslide and libvips
RUN \
    echo "`date` libffi" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py libffi` -c advice.detachedHead=false https://github.com/libffi/libffi.git && \
    cd libffi && \
    ./autogen.sh && \
    ./configure --silent --prefix=/usr/local --disable-static --disable-docs && \
    # make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libffi" >> /build/log.txt

# Used by openslide and libvips
RUN \
    echo "`date` util-linux" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py util-linux` -c advice.detachedHead=false https://github.com/util-linux/util-linux.git && \
    cd util-linux && \
    sed -i 's/#ifndef UMOUNT_UNUSED/#ifndef O_PATH\n# define O_PATH 010000000\n#endif\n\n#ifndef UMOUNT_UNUSED/g' libmount/src/context_umount.c && \
    ./autogen.sh && \
    ./configure --disable-all-programs --enable-libblkid --enable-libmount --silent --prefix=/usr/local --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` util-linux" >> /build/log.txt

# Build tool
RUN \
    echo "`date` meson" >> /build/log.txt && \
    pip install --no-cache-dir meson && \
    echo "`date` meson" >> /build/log.txt

# Used by openslide, libvips, and mapnik
RUN \
    echo "`date` glib" >> /build/log.txt && \
    export JOBS=`nproc` && \
    pip install --no-cache-dir packaging && \
    git clone --depth=1 --single-branch -b `getver.py glib` -c advice.detachedHead=false https://github.com/GNOME/glib.git && \
    cd glib && \
    meson setup --prefix=/usr/local --buildtype=release --optimization=3 -Dtests=False -Dglib_debug=disabled _build && \
    cd _build && \
    ninja -j ${JOBS} && \
    ninja -j ${JOBS} install && \
    ldconfig && \
    echo "`date` glib" >> /build/log.txt

# Used by GDAL
RUN \
    echo "`date` libtirpc" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b libtirpc-`getver.py libtirpc` -c advice.detachedHead=false https://github.com/alisw/libtirpc.git && \
    cd libtirpc && \
    . ./autogen.sh && \
    ./configure --prefix=/usr/local --disable-static && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libtirpc" >> /build/log.txt && \
cd /build && \
# \
# RUN \
    echo "`date` libnsl" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py libnsl` -c advice.detachedHead=false https://github.com/thkukuk/libnsl.git && \
    cd libnsl && \
    ./autogen.sh && \
    ./configure --prefix=/usr/local --disable-static && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libnsl" >> /build/log.txt

# Used by openslide and libvips
RUN \
    echo "`date` gobject-introspection" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b `getver.py gobject-introspection` -c advice.detachedHead=false https://github.com/GNOME/gobject-introspection.git && \
    cd gobject-introspection && \
    python -c $'# \n\
path = "giscanner/meson.build" \n\
s = open(path).read() \n\
s = s[:s.index("install_subdir")] + s[s.index("flex"):] \n\
open(path, "w").write(s)' && \
    sed -i 's/subdir('\''tests'\'')/#/g' meson.build && \
    meson setup --prefix=/usr/local --buildtype=release --optimization=3 -Ddoctool=disabled -Dcairo=disabled _build && \
    cd _build && \
    ninja -j ${JOBS} && \
    ninja -j ${JOBS} install && \
    ldconfig && \
    cd ../../glib && \
    rm -rf _build && \
    meson setup --prefix=/usr/local --buildtype=release --optimization=3 -Dtests=False -Dglib_debug=disabled -Dintrospection=enabled _build && \
    cd _build && \
    ninja -j ${JOBS} && \
    ninja -j ${JOBS} install && \
    ldconfig && \
    echo "`date` gobject-introspection" >> /build/log.txt

# Boost

# Used by mapnik.  Unicode support
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

# Used by mapnik.  Unicode support
RUN \
    echo "`date` icu4c" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b release-`getver.py icu4c` -c advice.detachedHead=false https://github.com/unicode-org/icu.git && \
    cd icu/icu4c/source && \
    LDFLAGS="$LDFLAGS -Wl,--gc-sections" CFLAGS="$CFLAGS -Os -fdata-sections -ffunction-sections -DUNISTR_FROM_CHAR_EXPLICIT=explicit -DUNISTR_FROM_STRING_EXPLICIT=explicit -DU_CHARSET_IS_UTF8=1 -DU_NO_DEFAULT_INCLUDE_UTF_HEADERS=1 -DU_HIDE_OBSOLETE_UTF_OLD_H=1" ./configure --silent --prefix=/usr/local --disable-tests --disable-samples --with-data-packaging=library --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    # reduce docker size \
    rm -rf data/out/tmp && \
    ldconfig && \
    echo "`date` icu4c" >> /build/log.txt

# Used in libvips
# Also seems to be used in boost, armadillo, ImageMagick, others
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
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel -DBUILD_TESTS=OFF -DENABLE_AVX=ON -DENABLE_AVX2=ON -DENABLE_SSE=ON -DENABLE_SSE2=ON -DENABLE_THREADS=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5 && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` fftw3" >> /build/log.txt

# Used by gdal, mapnik, libvips, netcdf
# We can't add --disable-mpi-fortran, or parallel-netcdf doesn't build
RUN \
    echo "`date` openmpi" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    if true; then \
    # building from git is super slow, though deleting the .git files speed it \
    # up some.  The repo is more reliable, though \
    git clone --depth=1 --single-branch -b v`getver.py openmpi` -c advice.detachedHead=false --recurse-submodules  https://github.com/open-mpi/ompi.git openmpi && \
    cd openmpi && \
    find . -name '.git' -exec rm -rf {} \+ && \
    ./autogen.pl && \
    true; else \
    # building from tar files is faster \
    curl --retry 5 --silent https://download.open-mpi.org/release/open-mpi/v`getver.py openmpi 2`/openmpi-`getver.py openmpi`.tar.gz -L -o openmpi.tar.gz && \
    mkdir openmpi && \
    tar -zxf openmpi.tar.gz -C openmpi --strip-components 1 && \
    rm -f openmpi.tar.gz && \
    cd openmpi && \
    true; fi && \
    ./configure --silent --prefix=/usr/local --disable-picky --disable-dependency-tracking --enable-silent-rules --disable-dlopen --disable-libompitrace --disable-opal-btl-usnic-unit-tests --disable-picky --disable-debug --disable-mem-profile --disable-mem-debug --disable-static --disable-mpi-java -disable-oshmem-profile && \
    # make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    find . -name '*.a' -delete && \
    echo "`date` openmpi" >> /build/log.txt

# Used by mapnik.  The headers may be used by other libraries
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
    find . -name '.git' -exec rm -rf {} \+ && \
    echo "" > tools/build/src/user-config.jam && \
    echo "using mpi : /usr/local/lib ;" >> tools/build/src/user-config.jam && \
    # echo "using mpi ;" >> tools/build/src/user-config.jam && \
    ./bootstrap.sh --prefix=/usr/local --with-toolset=gcc variant=release && \
    # Only build the libraries we need; building boost is slow \
    ./b2 -d1 -j ${JOBS} toolset=gcc variant=release link=shared --build-type=minimal \
    --with-filesystem \
    --with-thread \
    --with-regex \
    --with-atomic \
    --with-system \
    --with-program_options \
    cxxflags="-std=c++14 -Wno-parentheses -Wno-deprecated-declarations -Wno-unused-variable -Wno-parentheses -Wno-maybe-uninitialized -Wno-attributes" \
    install && \
    ldconfig && \
    echo "`date` boost" >> /build/log.txt

# Used by gdal, mapnik, openslide, libvips
RUN \
    echo "`date` sqlite" >> /build/log.txt && \
    export JOBS=`nproc` && \
    curl --retry 5 --silent https://sqlite.org/`getver.py sqlite 1`/sqlite-autoconf-`getver.py sqlite 2 . . 1`.tar.gz -L -o sqlite.tar.gz && \
    mkdir sqlite && \
    tar -zxf sqlite.tar.gz -C sqlite --strip-components 1 && \
    rm -f sqlite.tar.gz && \
    cd sqlite && \
    ./configure --prefix=/usr/local --disable-static --all && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` sqlite" >> /build/log.txt

# This used to be used by proj4
# RUN \
#     echo "`date` proj-data" >> /build/log.txt && \
#     export JOBS=`nproc` && \
#     git clone --depth=1 --single-branch -b `getver.py proj-data` -c advice.detachedHead=false https://github.com/OSGeo/PROJ-data.git && \
#     cd PROJ-data && \
#     mkdir _build && \
#     cd _build && \
#     cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel && \
#     make dist && \
#     echo "`date` proj-data" >> /build/log.txt

# Used by gdal and mapnik
RUN \
    echo "`date` proj4" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b `getver.py proj4` -c advice.detachedHead=false https://github.com/OSGeo/proj.4.git && \
    cd proj.4 && \
    # cd data && \
    # unzip -o /build/PROJ-data/_build/proj-data-*.zip && \
    # cd .. && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel -DBUILD_TESTING=OFF && \
    # these cmake commands appear to be identical to just running make, but \
    # are the recommended build process \
    cmake --build . -j ${JOBS} && \
    cmake --build . -j ${JOBS} --target install && \
    # make --silent -j ${JOBS} && \
    # make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` proj4" >> /build/log.txt

# Only build for versions that aren't published
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
    environ.setdefault("PROJ_DATA", os.path.join(localpath, "..", "proj")) \n\
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
# This import foolishness is because is some environments, even after \n\
# importing importlib.metadata, somehow importlib.metadata is not present. \n\
from importlib import metadata as _importlib_metadata \n\
import importlib \n\
importlib.metadata = _importlib_metadata \n\
import os \n\
localpath = os.path.dirname(os.path.abspath( __file__ )) \n\
os.environ.setdefault("PROJ_DATA", os.path.join(localpath, "proj")) \n\
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
data = data.replace("""package_data=get_package_data(),""", \n\
"""package_data=get_package_data(), \n\
    entry_points={\'console_scripts\': [\'%s=pyproj.bin:program\' % name for name in os.listdir(\'pyproj/bin\') if not name.endswith(\'.py\')]},""") \n\
open(path, "w").write(data)' && \
    # now rebuild anything that can work with master \
    if [ "$PYPY" = true ]; then \
    # find /opt/py -mindepth 1 -not -name '*p36-*' -a -not -name '*p37-*' -print0 | xargs -n 1 -0 -P 1 bash -c '"${0}/bin/pip" wheel . --no-deps -w /io/wheelhouse && rm -rf build' && \
    true; \
    else \
    # find /opt/py -mindepth 1 -not -name '*p36-*' -a -not -name '*p37-*' -print0 | xargs -n 1 -0 -P 1 bash -c '"${0}/bin/pip" wheel . --no-deps -w /io/wheelhouse && rm -rf build' && \
    true; \
    fi && \
    if find /io/wheelhouse/ -name 'pyproj*.whl' | grep .; then \
    # Make sure all binaries have the execute flag \
    find /io/wheelhouse/ -name 'pyproj*.whl' -print0 | xargs -n 1 -0 bash -c 'mkdir /tmp/ptmp; pushd /tmp/ptmp; unzip ${0}; chmod a+x pyproj/bin/*; chmod a-x pyproj/bin/*.py; zip -r ${0} *; popd; rm -rf /tmp/ptmp' && \
    find /io/wheelhouse/ -name 'pyproj*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} auditwheel repair --only-plat --plat ${AUDITWHEEL_PLAT} -w /io/wheelhouse && \
    find /io/wheelhouse/ -name 'pyproj*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v && \
    find /io/wheelhouse/ -name 'pyproj*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} advzip -k -z && \
    ls -l /io/wheelhouse && \
    true; \
    fi && \
    rm -rf ~/.cache && \
    echo "`date` pyproj4" >> /build/log.txt

RUN \
    echo "`date` minizip" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b `getver.py minizip` -c advice.detachedHead=false https://github.com/zlib-ng/minizip-ng.git && \
    cd minizip-ng && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel -DBUILD_SHARED_LIBS=yes -DINSTALL_INC_DIR=/usr/local/include/minizip -DMZ_OPENSSL=yes && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` minizip" >> /build/log.txt

# Used by gdal, mapnik, openslide, libvips.  XML parsing
RUN \
    echo "`date` libexpat" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    curl --retry 5 --silent https://github.com/libexpat/libexpat/archive/R_`getver.py libexpat`.tar.gz -L -o libexpat.tar.gz && \
    mkdir libexpat && \
    tar -zxf libexpat.tar.gz -C libexpat --strip-components 1 && \
    rm -f libexpat.tar.gz && \
    cd libexpat/expat && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel -DEXPAT_BUILD_EXAMPLES=OFF -DEXPAT_BUILD_TESTS=OFF && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libexpat" >> /build/log.txt

# CVS tool used by several libraries
RUN \
    echo "`date` fossil" >> /build/log.txt && \
    if [ "$AUDITWHEEL_ARCH" == "x86_64" ]; then \
    # fossil executable \
    curl --retry 5 --silent -L https://fossil-scm.org/home/uv/fossil-linux-x64-`getver.py fossil`.tar.gz -o fossil.tar.gz && \
    tar -zxf fossil.tar.gz && \
    mv fossil /usr/local/bin/. && \
    rm -f fossil.tar.gz && \
    true; else \
    # fossil from source \
    # Previously, we had to build fossil to allow it to work in our
    # environment.  The prebuilt binaries fail because they can't find any of
    # a list of versions of GLIBC.
    curl --retry 5 --silent -L https://fossil-scm.org/home/tarball/8be0372c1051043761320c8ea8669c3cf320c406e5fe18ad36b7be5f844ca73b/fossil-src-2.24.tar.gz -o fossil.tar.gz && \
    mkdir fossil && \
    tar -zxf fossil.tar.gz -C fossil --strip-components 1 && \
    rm -f fossil.tar.gz && \
    cd fossil && \
    ./configure --prefix=/usr/local --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    true; fi && \
    echo "`date` fossil" >> /build/log.txt

# Used by gdal and mapnik.  Reads from xls, xlsx, and ods files
RUN \
    echo "`date` freexl" >> /build/log.txt && \
    export JOBS=`nproc` && \
    printf 'yes\nyes\n' | fossil --user=root clone https://www.gaia-gis.it/fossil/freexl freexl.fossil && \
    mkdir freexl && \
    cd freexl && \
    fossil open ../freexl.fossil && \
    rm -f ../freexl.fossil && \
    LIBS=-liconv ./configure --silent --prefix=/usr/local --disable-static --build=${AUDITWHEEL_ARCH}-unknown-linux-gnu && \
    LIBS=-liconv make -j ${JOBS} && \
    LIBS=-liconv make -j ${JOBS} install && \
    ldconfig && \
    echo "`date` freexl" >> /build/log.txt

# Used by libspatialite
RUN \
    echo "`date` libgeos" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b `getver.py libgeos` -c advice.detachedHead=false https://github.com/libgeos/geos.git && \
    cd geos && \
    mkdir _build && \
    cd _build && \
    cmake .. -DGEOS_BUILD_DEVELOPER=NO -DCMAKE_BUILD_TYPE=MinSizeRel -DBUILD_TESTING=OFF && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libgeos" >> /build/log.txt

# Used by gdal, mapnik, openslide, libvips
RUN \
    echo "`date` libxml" >> /build/log.txt && \
    export JOBS=`nproc` && \
    rm -rf libxml2* && \
    git clone --depth=1 --single-branch -b v`getver.py libxml2` -c advice.detachedHead=false https://github.com/GNOME/libxml2.git && \
    cd libxml2 && \
    mkdir _build && \
    cd _build && \
    # Add legacy APIs so rasterlite will still work \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel -DLIBXML2_WITH_TESTS=OFF -DLIBXML2_WITH_PYTHON=OFF -DLIBXML2_WITH_ICU=OFF -DLIBXML2_WITH_ICONV=ON -DLIBXML2_WITH_LEGACY=ON -DLIBXML2_WITH_HTTP=ON -DLIBXML2_WITH_DEBUG=OFF -DLIBXML2_WITH_PROGRAMS=OFF && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libxml" >> /build/log.txt

# Used by libspatialite
RUN \
    echo "`date` librttopo" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b librttopo-`getver.py librttopo` -c advice.detachedHead=false https://gitlab.com/rttopo/rttopo.git && \
    cd rttopo && \
    ./autogen.sh && \
    ./configure --prefix=/usr/local --disable-static && \
    make -j ${JOBS} && \
    make -j ${JOBS} install && \
    ldconfig && \
    echo "`date` librttopo" >> /build/log.txt

# Used by gdal and mapnik
RUN \
    echo "`date` libspatialite" >> /build/log.txt && \
    export JOBS=`nproc` && \
    fossil --user=root clone https://www.gaia-gis.it/fossil/libspatialite libspatialite.fossil && \
    mkdir libspatialite && \
    cd libspatialite && \
    fossil open ../libspatialite.fossil && \
    # fossil checkout -f d3aee83d3cbdd296 && \
    rm -f ../libspatialite.fossil && \
    export CFLAGS="$CFLAGS -Os" && \
    export CXXFLAGS="$CXXFLAGS -Os" && \
    ./configure --silent --prefix=/usr/local --disable-examples --disable-static --build=${AUDITWHEEL_ARCH}-unknown-linux-gnu && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    find . -name '*.a' -delete && \
    echo "`date` libspatialite" >> /build/log.txt

# Used by gdal and mapnik
RUN \
    echo "`date` libgeotiff" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b `getver.py libgeotiff` -c advice.detachedHead=false https://github.com/OSGeo/libgeotiff.git && \
    cd libgeotiff/libgeotiff && \
    # This could be done with cmake, but then librasterlite2 doesn't find it
    # mkdir _build && \
    # cd _build && \
    # cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel -DWITH_JPEG=ON -DWITH_ZLIB=ON && \
    autoreconf -ifv && \
    ./configure --silent --prefix=/usr/local --with-zlib=yes --with-jpeg=yes --disable-static && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libgeotiff" >> /build/log.txt

# Used by rasterlite
RUN \
    echo "`date` pixman" >> /build/log.txt && \
    export JOBS=`nproc` && \
    until timeout 60 git clone --depth=1 --single-branch -b pixman-`getver.py pixman` -c advice.detachedHead=false https://gitlab.freedesktop.org/pixman/pixman.git; do sleep 5; echo "retrying"; done && \
    cd pixman && \
    meson setup --prefix=/usr/local --buildtype=release --optimization=3 _build && \
    cd _build && \
    ninja -j ${JOBS} && \
    ninja -j ${JOBS} install && \
    ldconfig && \
    echo "`date` pixman" >> /build/log.txt

# Used by cairo, python_javabridge
RUN \
    echo "`date` freetype" >> /build/log.txt && \
    export JOBS=`nproc` && \
    until timeout 60 git clone --depth=1 --single-branch -b VER-`getver.py freetype` -c advice.detachedHead=false --recurse-submodules -j ${JOBS} https://github.com/freetype/freetype.git; do sleep 5; echo "retrying"; done && \
    cd freetype && \
    meson setup --prefix=/usr/local --buildtype=release --optimization=3 _build && \
    cd _build && \
    ninja -j ${JOBS} && \
    ninja -j ${JOBS} install && \
    ldconfig && \
    echo "`date` freetype" >> /build/log.txt

# Used by cairo
RUN \
    echo "`date` fontconfig" >> /build/log.txt && \
    export JOBS=`nproc` && \
    until timeout 60 git clone --depth=1 --single-branch -b `getver.py fontconfig` -c advice.detachedHead=false https://gitlab.freedesktop.org/fontconfig/fontconfig.git; do sleep 5; echo "retrying"; done && \
    cd fontconfig && \
    meson setup --prefix=/usr/local --buildtype=release --optimization=3 -Ddoc=disabled -Dtests=disabled _build && \
    cd _build && \
    ninja -j ${JOBS} && \
    ninja -j ${JOBS} install && \
    ldconfig && \
    echo "`date` fontconfig" >> /build/log.txt

# Used by openslide, GDAL, mapnik, libvips.  2D graphics library
RUN \
    echo "`date` cairo" >> /build/log.txt && \
    export JOBS=`nproc` && \
    until timeout 60 git clone --depth=1 --single-branch -b `getver.py cairo` -c advice.detachedHead=false https://gitlab.freedesktop.org/cairo/cairo.git; do sleep 5; echo "retrying"; done && \
    cd cairo && \
    meson setup --prefix=/usr/local --buildtype=release --optimization=3 -Dtests=disabled _build && \
    cd _build && \
    ninja -j ${JOBS} && \
    ninja -j ${JOBS} install && \
    ldconfig && \
    echo "`date` cairo" >> /build/log.txt

# Used by GDAL, mapnik, libvips.  Lossless compression
RUN \
    echo "`date` lz4" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py lz4` -c advice.detachedHead=false https://github.com/lz4/lz4.git && \
    cd lz4 && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` lz4" >> /build/log.txt

# Used by GDAL and mapnik.  Raster coverage via SpatiaLite
RUN \
    echo "`date` librasterlite2" >> /build/log.txt && \
    export JOBS=`nproc` && \
    fossil --user=root clone https://www.gaia-gis.it/fossil/librasterlite2 librasterlite2.fossil && \
    mkdir librasterlite2 && \
    cd librasterlite2 && \
    fossil open ../librasterlite2.fossil && \
    fossil checkout -f 9dd8217cb9 && \
    rm -f ../librasterlite2.fossil && \
    # ./configure --silent --prefix=/usr/local --disable-static --disable-leptonica --build=${AUDITWHEEL_ARCH}-unknown-linux-gnu && \
    ./configure --silent --prefix=/usr/local --disable-static --build=${AUDITWHEEL_ARCH}-unknown-linux-gnu && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` librasterlite2" >> /build/log.txt

# Used by gdal and mapnik.  Handle the National Mapping Authority of Norway
# geodata standard format SOSI.
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
    # If we use cmake here, GDAL doesn't find the results properly \
    # mkdir _build && \
    # cd _build && \
    # cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel && \
    export CXXFLAGS="$CXXFLAGS -std=c++11" && \
    autoreconf -ifv && \
    ./configure --silent --prefix=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` fyba" >> /build/log.txt

# Used by netcdf, GDAL
# Build items necessary for netcdf support
RUN \
    echo "`date` hdf4" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b hdf-`getver.py hdf4` -c advice.detachedHead=false https://github.com/HDFGroup/hdf4.git && \
    cd hdf4 && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel -DHDF4_BUILD_FORTRAN=OFF -DHDF4_ENABLE_NETCDF=OFF -DHDF4_ENABLE_Z_LIB_SUPPORT=ON -DHDF4_DISABLE_COMPILER_WARNINGS=ON -DBUILD_TESTING=OFF -DCMAKE_INSTALL_PREFIX=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` hdf4" >> /build/log.txt

# Used by gdal, mapnik, pyvips
RUN \
    echo "`date` hdf5" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b hdf5-`getver.py hdf5` -c advice.detachedHead=false https://github.com/HDFGroup/hdf5.git && \
    cd hdf5 && \
    mkdir _build && \
    cd _build && \
    # We need HDF5_ENABLE_PARALLEL=ON for parallel netcdf and \
    # HDF5_BUILD_CPP_LIB=ON for gdal, so we have to add ALLOW_UNSUPPORTED=ON \
    # to get both \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel -DDEFAULT_API_VERSION=v18 -DHDF5_BUILD_EXAMPLES=OFF -DHDF5_BUILD_FORTRAN=OFF -DHDF5_ENABLE_PARALLEL=ON -DHDF5_ENABLE_Z_LIB_SUPPORT=ON -DHDF5_BUILD_GENERATORS=ON -DHDF5_ENABLE_DIRECT_VFD=ON -DHDF5_BUILD_CPP_LIB=ON -DHDF5_DISABLE_COMPILER_WARNINGS=ON -DBUILD_TESTING=OFF -DZLIB_DIR=/usr/local/lib -DMPI_C_COMPILER=/usr/local/bin/mpicc -DMPI_C_HEADER_DIR=/usr/local/include -DMPI_mpi_LIBRARY=/usr/local/lib/libmpi.so -DMPI_C_LIB_NAMES=mpi -DHDF5_BUILD_DOC=OFF -DALLOW_UNSUPPORTED=ON -DCMAKE_INSTALL_PREFIX=/usr/local && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    # Delete binaries used for testing to keep the docker image smaller \
    find bin -type f ! -name 'lib*' -delete && \
    echo "`date` hdf5" >> /build/log.txt

# Used by gdal, mapnik
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

# Used by gdal, mapnik
RUN \
    echo "`date` netcdf" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py netcdf` -c advice.detachedHead=false https://github.com/Unidata/netcdf-c && \
    cd netcdf-c && \
    # The compiler throws an erroneous error because strlen is used as a \
    # function variable.  Avoid this. \
    sed -i 's/int strlen,/int strlenn,/g' libnczarr/zutil.c && \
    sed -i 's/format,strlen)/format,strlenn)/g' libnczarr/zutil.c && \
    mkdir _build && \
    cd _build && \
    CFLAGS="$CFLAGS -Wno-incompatible-pointer-types" \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel -DENABLE_EXAMPLES=OFF -DENABLE_PARALLEL4=ON -DUSE_PARALLEL=ON -DUSE_PARALLEL4=ON -DENABLE_HDF4=ON -DENABLE_PNETCDF=ON -DENABLE_BYTERANGE=ON -DENABLE_JNA=ON -DCMAKE_SHARED_LINKER_FLAGS=-ljpeg -DENABLE_TESTS=OFF -DENABLE_HDF4_FILE_TESTS=OFF -DENABLE_DAP=ON -DENABLE_HDF5=ON -DENABLE_NCZARR=ON && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` netcdf" >> /build/log.txt

# Used by mysql.  Linux async i/o library
# We can't use the version number here, because the source isn't properly
# tagged
RUN \
    echo "`date` libaio" >> /build/log.txt && \
    export JOBS=`nproc` && \
    # git clone --depth=1 --single-branch -b libaio.`getver.py libaio` -c advice.detachedHead=false https://pagure.io/libaio.git && \
    git clone --depth=1 --single-branch -c advice.detachedHead=false https://pagure.io/libaio.git && \
    cd libaio && \
    make prefix=/usr/local --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libaio" >> /build/log.txt

# Used by GDAL, mapnik, pylibmc
RUN \
    echo "`date` mysql" >> /build/log.txt && \
    export JOBS=`nproc` && \
    # curl --retry 5 --silent https://cdn.mysql.com/Downloads/MySQL-`getver.py mysql 2`/mysql-boost-`getver.py mysql`.tar.gz -L -o mysql.tar.gz && \
    curl --retry 5 --silent https://cdn.mysql.com/Downloads/MySQL-`getver.py mysql 2`/mysql-`getver.py mysql`.tar.gz -L -o mysql.tar.gz && \
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
    if [ -e "/opt/rh/devtoolset-11/enable" ]; then \
    . /opt/rh/devtoolset-11/enable; \
    fi && \
    CFLAGS="$CFLAGS -ftls-model=global-dynamic" \
    CXXFLAGS="$CXXFLAGS -Wno-deprecated-declarations -ftls-model=global-dynamic" \
    cmake .. -DBUILD_CONFIG=mysql_release -DBUILD_SHARED_LIBS=ON -DWITH_BOOST=`find ../../boost/ -maxdepth 1 -name 'boost_*'` -DWITH_ZLIB=bundled -DCMAKE_INSTALL_PREFIX=/usr/local -DWITH_UNIT_TESTS=OFF -DCMAKE_BUILD_TYPE=MinSizeRel -DWITHOUT_SERVER=ON -DREPRODUCIBLE_BUILD=ON -DINSTALL_MYSQLTESTDIR="" && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    # reduce docker size \
    make clean && \
    ldconfig && \
    echo "`date` mysql" >> /build/log.txt

# Used by GDAL.  Open Geographic Datastore Interface
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

# Used by GDAL's postgis raster driver; used by pylibmc
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

# Used by GDAL, mapnik, libvips.  PDF reader
RUN \
    echo "`date` poppler" >> /build/log.txt && \
    export JOBS=`nproc` && \
    until timeout 60 git clone --depth=1 --single-branch -b poppler-`getver.py poppler` -c advice.detachedHead=false https://gitlab.freedesktop.org/poppler/poppler.git; do sleep 5; echo "retrying"; done && \
    cd poppler && \
    mkdir _build && \
    cd _build && \
    if [ -e "/opt/rh/devtoolset-11/enable" ]; then \
    . /opt/rh/devtoolset-11/enable; \
    fi && \
    cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local -DCMAKE_BUILD_TYPE=Release -DENABLE_UNSTABLE_API_ABI_HEADERS=on -DBUILD_CPP_TESTS=OFF -DBUILD_GTK_TESTS=OFF -DBUILD_MANUAL_TESTS=OFF -DBUILD_QT5_TESTS=OFF -DBUILD_QT6_TESTS=OFF -DENABLE_NSS3=OFF -DENABLE_GPGME=OFF -DENABLE_QT5=OFF -DENABLE_QT6=OFF && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` poppler" >> /build/log.txt

# Used by GDAL, mapnik, libvips.  Flexible Image Transport System reader
RUN \
    echo "`date` fitsio" >> /build/log.txt && \
    export JOBS=`nproc` && \
    # curl --retry 5 --silent -k https://heasarc.gsfc.nasa.gov/FTP/software/fitsio/c/cfitsio-`getver.py fitsio`.tar.gz -L -o cfitsio.tar.gz && \
    # mkdir cfitsio && \
    # tar -zxf cfitsio.tar.gz -C cfitsio --strip-components 1 && \
    # rm -f cfitsio.tar.gz && \
    git clone --depth=1 --single-branch -b cfitsio-`getver.py fitsio` -c advice.detachedHead=false https://github.com/HEASARC/cfitsio.git && \
    cd cfitsio && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel -DCMAKE_POLICY_VERSION_MINIMUM=3.5 && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` fitsio" >> /build/log.txt

# Used by GDAL, pylibmc.  Hashing library
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

# Used by GDAL.  Generic Tagged Arrays
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
    cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local -DCMAKE_BUILD_TYPE=MinSizeRel -DGTA_BUILD_DOCUMENTATION=OFF -DGTA_BUILD_STATIC_LIB=OFF && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libgta" >> /build/log.txt

# This is an old version of libecw.  I am uncertain that the licensing allows
# for this to be used, and therefore is disabled for now.  Also, it appears to
# be much slower than openjpeg.
# RUN \
#     echo "`date` libecw" >> /build/log.txt && \
#     export JOBS=`nproc` && \
#     curl --retry 5 --silent https://sourceforge.net/projects/libecw-legacy/files/libecwj2-3.3-2006-09-06.zip -L -o libecwj.zip && \
#     unzip libecwj.zip && \
#     rm -f libecwj.zip && \
#     cd libecwj2-3.3 && \
#     curl -OLJ https://raw.githubusercontent.com/rouault/libecwj2-3.3-builds/main/libecwj2-3.3.patch && \
#     patch -p 1 -u -i libecwj2-3.3.patch && \
#     CXXFLAGS='-w' ./configure --silent --prefix=/usr/local && \
#     make --silent -j ${JOBS} && \
#     make --silent -j ${JOBS} install && \
#     ldconfig && \
#     echo "`date` libecw" >> /build/log.txt

# Used by GDAL.  XML parser
RUN \
    echo "`date` xerces-c" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py xerces-c` -c advice.detachedHead=false https://github.com/apache/xerces-c.git && \
    cd xerces-c && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel -Dtranscoder=iconv && \
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
#     cmake .. -DUSE_OPENMP=True -DBUILD_SHARED_LIBS=True -DCMAKE_BUILD_TYPE=MinSizeRel && \
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
#     cmake .. -DBUILD_SHARED_LIBS=True -DCMAKE_BUILD_TYPE=MinSizeRel -Denable_internal_blaslib=OFF -Denable_tests=OFF -DTPL_BLAS_LIBRARIES=/usr/local/lib64/libopenblas.so && \
#     make --silent -j ${JOBS} && \
#     make --silent -j ${JOBS} install && \
#     ldconfig && \
#     echo "`date` superlu" >> /build/log.txt

# Used by GDAL.  Linear algebra library
RUN \
    echo "`date` lapack" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py lapack` -c advice.detachedHead=false https://github.com/Reference-LAPACK/lapack && \
    cd lapack && \
    mkdir _build && \
    cd _build && \
    cmake .. -DBUILD_SHARED_LIBS=True -DCMAKE_BUILD_TYPE=MinSizeRel -DTEST_FORTRAN_COMPILER=OFF -DCBLAS=ON && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` lapack" >> /build/log.txt

# Used by GDAL.  Linear algebra library
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
    cmake .. -DBUILD_SHARED_LIBS=True -DCMAKE_BUILD_TYPE=MinSizeRel -DCMAKE_INSTALL_PREFIX=/usr/local -DCMAKE_INSTALL_LIBDIR=lib && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` armadillo" >> /build/log.txt

# Used by GDAL
# PINNED VERSION - can't easily check the version
# MrSID only works with gcc 4 or 5 unless we change it.
# Not available on architectures other than x86_64 without more work
RUN \
    echo "`date` mrsid" >> /build/log.txt && \
    if [ "$AUDITWHEEL_ARCH" == "x86_64" ]; then \
    curl --retry 5 --silent http://bin.extensis.com/download/developer/MrSID_DSDK-9.5.4.4709-rhel6.x86-64.gcc531.tar.gz -L -o mrsid.tar.gz && \
    mkdir mrsid && \
    tar -zxf mrsid.tar.gz -C mrsid --strip-components 1 && \
    rm -f mrsid.tar.gz && \
    sed -i 's/ && __GNUC__ <= 5//g' /build/mrsid/Raster_DSDK/include/lt_platform.h && \
    cp -n mrsid/Raster_DSDK/lib/* /usr/local/lib/. && \
    cp -n mrsid/Lidar_DSDK/lib/* /usr/local/lib/. && \
    true; fi && \
    echo "`date` mrsid" >> /build/log.txt

# Used by GDAL.  Block compression library
RUN \
    echo "`date` blosc" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py blosc` -c advice.detachedHead=false https://github.com/Blosc/c-blosc.git && \
    cd c-blosc && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel -DBUILD_SHARED=ON -DBUILD_STATIC=OFF -DBUILD_BENCHMARKS=OFF -DBUILD_FUZZERS=OFF -DBUILD_TESTS=OFF -DPREFER_EXTERNAL_LZ4=ON -DPREFER_EXTERNAL_ZLIB=ON -DPREFER_EXTERNAL_ZSTD=ON -DDEACTIVATE_SNAPPY=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` blosc" >> /build/log.txt

# Needed for libheif
RUN \
    echo "`date` libde265" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py libde265` -c advice.detachedHead=false https://github.com/strukturag/libde265.git && \
    cd libde265 && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel -DBUILD_SHARED=ON -DBUILD_STATIC=OFF -DWITH_EXAMPLES=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    find . -name '*.a' -delete && \
    echo "`date` libde265" >> /build/log.txt

# Used by GDAL, mapnik, and libvips; decoder for HEIC, AVIF, JPEG-in-HEIF,
# JPEG2000
RUN \
    echo "`date` libheif" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py libheif` -c advice.detachedHead=false https://github.com/strukturag/libheif.git && \
    cd libheif && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libheif" >> /build/log.txt

# Used by GDAL
RUN \
    echo "`date` kealib" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b kealib-`getver.py kealib` -c advice.detachedHead=false https://github.com/ubarsc/kealib.git && \
    cd kealib && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` kealib" >> /build/log.txt

# Used by GDAL
RUN \
    echo "`date` libopendrive" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b `getver.py libopendrive`-gdal -c advice.detachedHead=false https://github.com/DLR-TS/libOpenDRIVE.git && \
    cd libOpenDRIVE && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel -DCMAKE_POSITION_INDEPENDENT_CODE=ON && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libopendrive" >> /build/log.txt

# PINNED VERSION - use master
# This build doesn't support everything.
# Unsupported without more work or investigation:
#  GRASS Google-libkml ODBC FGDB MDB OCI GEORASTER SDE Rasdaman SFCGAL OpenCL
#  MongoDB MongoCXX HDFS TileDB
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
RUN \
    echo "`date` gdal" >> /build/log.txt && \
    export JOBS=`nproc` && \
    # We need numpy present in the default python to build all extensions \
    pip install numpy && \
    # - Specific version \
    if true; then \
    git clone --depth=1 --single-branch -b v`getver.py gdal` -c advice.detachedHead=false https://github.com/OSGeo/gdal.git && \
    true; else \
    # - Master -- also adjust version \
    git clone --depth=1000 --single-branch -c advice.detachedHead=false https://github.com/OSGeo/gdal.git && \
    # checkout out the recorded sha and prune to a depth of 1 \
    git -C gdal checkout `getver.py gdal-sha` && \
    git -C gdal gc --prune=all && \
    true; fi && \
    # - Common \
    cd gdal && \
    sed -i 's/define GDAL_VERSION_BUILD    0/define GDAL_VERSION_BUILD    1/g' gcore/gdal_version.h.in && \
    sed -i 's/dev/.1dev/g' gcore/gdal_version.h.in && \
    sed -i 's/\([0-9]\)$/\1.1/g' VERSION && \
    sed -i 's/if library_version_num < gdal_python_version/if False/g' swig/python/setup.py.in && \
    # sed -i 's/set(GDAL_PYTHON_VERSION "${GDAL_VERSION_NO_DEV_SUFFIX}")/set(GDAL_PYTHON_VERSION "${GDAL_VERSION_NO_DEV_SUFFIX}.1")/g' swig/python/CMakeLists.txt && \
    export PATH="$PATH:/build/mysql/build/scripts" && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel \
    $(if [ "$AUDITWHEEL_ARCH" == "x86_64" ]; then echo -n "-DMRSID_LIBRARY=/usr/local/lib/libltidsdk.so -DMRSID_INCLUDE_DIR=/build/mrsid/Raster_DSDK/include"; fi) \
    -DGDAL_USE_LERC=ON \
    -DENABLE_DEFLATE64=OFF \
    2>&1 >../cmakelog.txt \
    && \
    make -j ${JOBS} USER_DEFS="-Werror -Wno-missing-field-initializers -Wno-write-strings -Wno-stringop-overflow -Wno-ignored-qualifiers" && \
    make -j ${JOBS} install && \
    ldconfig && \
    # This takes a lot of space in the Docker file, and we don't use it \
    rm -f libgdal.a && \
    # reduce docker size \
    rm -rf ogr/ogrsf_frmts/o/*.o frmts/o/*.o && \
    echo "`date` gdal" >> /build/log.txt

RUN \
    echo "`date` gdal python" >> /build/log.txt && \
    export JOBS=`nproc` && \
    cd gdal/_build/swig/python && \
    cp -r /usr/local/share/{proj,gdal} osgeo/. && \
    mkdir osgeo/bin && \
    find /build/gdal/_build/apps -executable -type f -exec bash -c 'cp --dereference /usr/local/bin/"$(basename {})" osgeo/bin/.' \; && \
    rm -f osgeo/bin/gdal-config || true && \
    cp --dereference /usr/local/bin/gdal-config osgeo/bin/. && \
    find /build/libgeotiff/libgeotiff/bin/.libs -executable -type f -exec cp {} osgeo/bin/. \; && \
    # Copy proj executables, as we aren't necessarily building proj ourselves \
    find /build/proj.4/_build/bin/ -executable -not -type d -exec bash -c 'cp --dereference /usr/local/bin/"$(basename {})" osgeo/bin/.' \; && \
    (strip osgeo/bin/* --strip-unneeded || true) && \
    python -c $'# \n\
path = "osgeo/bin/__init__.py" \n\
s = """import os \n\
import sys \n\
\n\
def program(): \n\
    environ = os.environ.copy() \n\
    localpath = os.path.dirname(os.path.abspath( __file__ )) \n\
    environ.setdefault("PROJ_DATA", os.path.join(localpath, "proj")) \n\
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
data = re.sub( \n\
    r"gdal_version = \'\\d+.\\d+.\\d+(dev|)\'", \n\
    "gdal_version = \'" + os.popen("gdal-config --version").read().strip().split(\'.dev\')[0].split(\'dev\')[0] + "\'", \n\
    data) \n\
data = data.replace( \n\
    "scripts/*.py\'),", \n\
"""scripts/*.py\'), \n\
    package_data={\'osgeo\': [\'proj/*\', \'gdal/*\', \'bin/*\']},""") \n\
data = data.replace("console_scripts = []", """console_scripts = [\'%s=osgeo.bin:program\' % name for name in os.listdir(\'osgeo/bin\') if not name.endswith(\'.py\')]""") \n\
if "console_scripts" not in data: data = data.replace( \n\
    "scripts/*.py\'),", \n\
"""scripts/*.py\'), \n\
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
os.environ.setdefault("PROJ_DATA", os.path.join(_localpath, "proj")) \n\
os.environ.setdefault("GDAL_DATA", os.path.join(_localpath, "gdal")) \n\
os.environ.setdefault("CPL_LOG", os.devnull) \n\
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
    # Strip libraries before building any wheels \
    # strip --strip-unneeded -p -D /usr/local/lib{,64}/*.{so,a} && \
    find /usr/local \( -name '*.so' -o -name '*.a' \) -exec bash -c "strip -p -D --strip-unneeded {} -o /tmp/striped; if ! cmp {} /tmp/striped; then cp /tmp/striped {}; fi; rm -f /tmp/striped" \; && \
    find /opt/py -mindepth 1 -not -name '*p38-*' -print0 | xargs -n 1 -0 -P 1 bash -c '"${0}/bin/pip" wheel . --no-deps -w /io/wheelhouse; git clean -fxd build GDAL.egg-info' && \
    find /io/wheelhouse/ -name 'gdal*.whl' | while read file; do new_file=$(echo "$file" | sed 's|/gdal|/GDAL|'); mv "$file" "$new_file"; done && \
    find /io/wheelhouse/ -name 'GDAL*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} auditwheel repair --only-plat --plat ${AUDITWHEEL_PLAT} -w /io/wheelhouse && \
    find /io/wheelhouse/ -name 'GDAL*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v && \
    find /io/wheelhouse/ -name 'GDAL*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} advzip -k -z && \
    ls -l /io/wheelhouse && \
    rm -rf ~/.cache && \
    echo "`date` gdal python" >> /build/log.txt

# Used by mapnik and libtiff
RUN \
    echo "`date` harfbuzz" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b `getver.py harfbuzz` -c advice.detachedHead=false https://github.com/harfbuzz/harfbuzz.git && \
    cd harfbuzz && \
    sed -i 's!/usr/bin/python3!/usr/bin/env python3!g' src/relative_to.py && \
    meson setup --prefix=/usr/local --buildtype=release --optimization=3 -Dtests=disabled -Ddocs=disabled _build && \
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
    # git checkout 34bb44e49050196fbf5a37426b0e0b7c9fd4fdda && \
    # Common \
    git apply --stat --numstat --apply ../mapnik_projection.cpp.patch && \
    sed -i 's/PJ_LOG_ERROR/PJ_LOG_NONE/g' src/*.cpp && \
    find include -name '*.hpp' -exec sed -i 's:boost/spirit/include/phoenix_operator.hpp:boost/phoenix/operator.hpp:g' {} \; && \
    find include -name '*.hpp' -exec sed -i 's:boost/spirit/include/phoenix_function.hpp:boost/phoenix/function.hpp:g' {} \; && \
    find include -name '*.hpp' -exec sed -i 's:boost/spirit/include/phoenix.hpp:boost/phoenix.hpp:g' {} \; && \
    find plugins -name '*.cpp' -exec sed -i 's/boost::trim_if/boost::algorithm::trim_if/g' {} \; && \
    sed -i 's:#include <algorithm>:#include <algorithm>\n#include <boost/algorithm/string.hpp>:g' plugins/input/csv/csv_utils.cpp && \
    sed -i 's/  xmlError\*/  const xmlError \*/g' src/libxml2_loader.cpp && \
    sed -i 's:#include <mapnik/image_util.hpp>:#define PSTL_USE_PARALLEL_POLICIES 0\n#define _GLIBCXX_USE_TBB_PAR_BACKEND 0\n#include <mapnik/image_util.hpp>:g' src/image_util.cpp && \
    find . -name '.git' -exec rm -rf {} \+ && \
    # Keeps the docker smaller \
    rm -rf demo test && mkdir test && mkdir demo && touch test/CMakeLists.txt && touch demo/CMakeLists.txt && \
    mkdir _build && \
    cd _build && \
    CXXFLAGS="-Wno-unused-variable -Wno-unused-but-set-variable -Wno-attributes -Wno-unknown-pragmas -Wno-maybe-uninitialized -Wno-parentheses -std=c++17" \
    cmake .. \
    -DBUILD_SHARED_LIBS=ON -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DBUILD_BENCHMARK=OFF \
    -DBUILD_DEMO_CPP=OFF \
    -DBUILD_DEMO_VIEWER=OFF \
    -DBUILD_TESTING=OFF \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DFONTS_INSTALL_DIR=/usr/local/lib/mapnik/fonts \
    && \
    # Common build process \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` mapnik" >> /build/log.txt

RUN \
    echo "`date` python-mapnik" >> /build/log.txt && \
    export JOBS=`nproc` && \
    # master \
    git clone --depth=1 --single-branch -c advice.detachedHead=false --quiet --recurse-submodules -j ${JOBS} https://github.com/mapnik/python-mapnik.git && \
    cd python-mapnik && \
    # specific checkout \
    # git clone --depth=100 --single-branch -c advice.detachedHead=false --quiet -j ${JOBS} https://github.com/mapnik/python-mapnik.git && \
    # cd python-mapnik && \
    # git checkout a2c2a86eec954b42d7f00093da03807d0834b1b4 && \
    # common \
    find . -name '.git' -exec rm -rf {} \+ && \
    # Copy the mapnik input sources and fonts to the python path and add them \
    # via setup.py.  Modify the paths.py file that gets created to refer to \
    # the relative location of these files. \
    cp -r /usr/local/lib/mapnik/* packaging/mapnik/. && \
    cp -r /usr/local/share/{proj,gdal} packaging/mapnik/. && \
    mkdir packaging/mapnik/bin && \
    cp /usr/local/bin/{mapnik-render,mapnik-index,shapeindex} packaging/mapnik/bin/. && \
    strip packaging/mapnik/bin/* --strip-unneeded -p -D && \
    python -c $'# \n\
path = "packaging/mapnik/bin/__init__.py" \n\
s = """import os \n\
import sys \n\
\n\
def program(): \n\
    environ = os.environ.copy() \n\
    localpath = os.path.dirname(os.path.abspath( __file__ )) \n\
    environ.setdefault("PROJ_DATA", os.path.join(localpath, "proj")) \n\
    environ.setdefault("GDAL_DATA", os.path.join(localpath, "gdal")) \n\
\n\
    path = os.path.join(os.path.dirname(__file__), os.path.basename(sys.argv[0])) \n\
    os.execve(path, sys.argv, environ) \n\
""" \n\
open(path, "w").write(s)' && \
    python -c $'# \n\
path = "packaging/mapnik/__init__.py" \n\
s = open(path).read().replace( \n\
    "def bootstrap_env():", \n\
""" \n\
localpath = os.path.dirname(os.path.abspath( __file__ )) \n\
os.environ.setdefault("PROJ_DATA", os.path.join(localpath, "proj")) \n\
os.environ.setdefault("GDAL_DATA", os.path.join(localpath, "gdal")) \n\
\n\
def bootstrap_env():""") \n\
open(path, "w").write(s)' && \
    python -c $'# \n\
import re \n\
path = "pyproject.toml" \n\
s = open(path).read() \n\
s = s.replace(".beta", "") \n\
s = re.sub("version = \\".*\\"", "version = \\"'`pkg-config --modversion libmapnik`.1$'\\"", s) \n\
s = s.replace("authors", "dynamic = [\\"scripts\\"]\\nauthors") \n\
s = s.replace("license = \\"LGPL-2.1-or-later\\"", "license = { text = \\"LGPL-2.1-or-later\\"}") \n\
open(path, "w").write(s)' && \
    sed -i 's/AsLongLong/AsLong/g' src/mapnik_value_converter.hpp && \
    sed -i 's/\.def(py::self == py::self)/\/\/ .def(py::self == py::self)/g' src/mapnik_datasource.cpp && \
    sed -i 's/\.def_property_readonly("symbolizers", \&rule::get_symbolizers)/.def_property_readonly("symbolizers", \&rule::get_symbolizers).def_property_readonly("symbols", \&rule::get_symbolizers)/g' src/mapnik_rule.cpp && \
    sed -i 's/handle.cast<mapnik::value_integer>();/handle.cast<mapnik::value_integer>();}else if (py::isinstance<py::none>(handle)) {/g' src/create_datasource.hpp && \
    sed -i 's/to_string3)/to_string3).def("tostring",\&to_string1).def("tostring",\&to_string2).def("tostring",\&to_string3)/g' src/mapnik_image.cpp && \
    if [ "$AUDITWHEEL_ARCH" != "x86_64" ]; then sed -i 's/.def_static("face_names", &freetype_engine::face_names)/\/\/ .def_static("face_names", \&freetype_engine::face_names)/g' src/mapnik_font_engine.cpp; fi && \
    # Apply a patch and set variables to work with the cmake build of mapnik \
    git apply --stat --numstat --apply ../mapnik_setup.py.patch && \
    # Strip libraries before building any wheels \
    # strip --strip-unneeded -p -D /usr/local/lib{,64}/*.{so,a} && \
    find /usr/local \( -name '*.so' -o -name '*.a' \) -exec bash -c "strip -p -D --strip-unneeded {} -o /tmp/striped; if ! cmp {} /tmp/striped; then cp /tmp/striped {}; fi; rm -f /tmp/striped" \; && \
    find /opt/py -mindepth 1 -not -name '*p38-*' -print0 | xargs -n 1 -0 -P ${JOBS} bash -c 'export WORKDIR=/tmp/python-mapnik-`basename ${0}`; mkdir -p $WORKDIR; cp -r . $WORKDIR/.; pushd $WORKDIR; "${0}/bin/pip" wheel . --no-deps -w /io/wheelhouse && popd && rm -rf $WORKDIR' && \
    find /io/wheelhouse/ -name 'mapnik*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} auditwheel repair --only-plat --plat ${AUDITWHEEL_PLAT} -w /io/wheelhouse && \
    find /io/wheelhouse/ -name 'mapnik*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v && \
    find /io/wheelhouse/ -name 'mapnik*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} advzip -k -z && \
    ls -l /io/wheelhouse && \
    rm -rf ~/.cache && \
    echo "`date` python-mapnik" >> /build/log.txt

# used by openslide, though maybe not until PR #605 is merged
RUN \
    echo "`date` jxrlib" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py jxrlib` -c advice.detachedHead=false https://github.com/4creators/jxrlib.git && \
    cd jxrlib && \
    sed -i "s/CFLAGS=/CFLAGS=-Wno-implicit-function-declaration -Wno-incompatible-pointer-types /g" Makefile && \
    DIR_INSTALL=/usr/local SHARED=1 make install && \
    ldconfig && \
    echo "`date` jxrlib" >> /build/log.txt

# PINNED VERSION - use master since last version is stale
RUN \
    echo "`date` openslide" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    git clone https://github.com/openslide/openslide && \
    cd openslide && \
    git pull --rebase https://github.com/iewchen/openslide zeiss-czi-jxr && \
    patch src/openslide-vendor-mirax.c ../openslide-vendor-mirax.c.patch && \
    meson setup --prefix=/usr/local --buildtype=release --optimization=3 _build && \
    cd _build && \
    ninja -j ${JOBS} && \
    ninja -j ${JOBS} install && \
    ldconfig && \
    echo "`date` openslide" >> /build/log.txt

RUN \
    echo "`date` openslide-python" >> /build/log.txt && \
    export JOBS=`nproc` && \
    # Last version \
    # git clone --depth=1 --single-branch -b v`getver.py openslide-python` -c advice.detachedHead=false https://github.com/openslide/openslide-python.git && \
    # Master \
    git clone --depth=1 --single-branch -c advice.detachedHead=false https://github.com/openslide/openslide-python.git && \
    # Common \
    cd openslide-python && \
    python -c $'# \n\
path = "openslide/lowlevel.py" \n\
s = open(path).read().replace( \n\
"""            return try_load([\'libopenslide.so.1\', \'libopenslide.so.0\'])""", \n\
"""            try: \n\
                import os \n\
                libpath = os.path.abspath(os.path.join(os.path.dirname(os.path.dirname(os.path.realpath( \n\
                    __file__))), \'openslide_python.libs\')) \n\
                libs = os.listdir(libpath) \n\
                lib = [lib for lib in libs if lib.startswith(\'libopenslide\')][0] \n\
                return try_load([lib]) \n\
            except Exception: \n\
                return try_load([\'libopenslide.so.1\', \'libopenslide.so.0\'])""") \n\
s = s.replace("return openslide_bin", "# return openslide_bin") \n\
open(path, "w").write(s)' && \
    mkdir openslide/bin && \
    find /build/openslide/_build/tools/ -executable -not -type d -exec bash -c 'cp --dereference /usr/local/bin/"$(basename {})" openslide/bin/.' \; && \
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
    "_convert.c\'", "_convert.c\'], libraries=[\'openslide\'") \n\
s = s.replace("_abi3 = sys.version_info >= (3, 11)", "_abi3 = sys.version_info >= (3, 11) and getattr(sys.flags, \'gil\', 1)") \n\
open(path, "w").write(s)' && \
    # Adding .2 to version to indicate we are adding jpxl czi support \
    python -c $'# \n\
import re \n\
path = "openslide/_version.py" \n\
s = open(path).read() \n\
s = re.sub(r"(__version__ = \'[^\']*)\'", "\\\\1.2\'", s) \n\
open(path, "w").write(s)' && \
    python -c $'# \n\
path = "pyproject.toml" \n\
s = open(path).read() \n\
s = s.replace(\'pyi"\', \'pyi", "bin/*"\') \n\
s += """ \n\
[project.scripts] \n\
""" \n\
import os \n\
for name in os.listdir(\'openslide/bin\'): \n\
  if not name.endswith(\'.py\'): \n\
    s += "%s = \'openslide.bin:program\'\\n" % name \n\
open(path, "w").write(s)' && \
    # Strip libraries before building any wheels \
    # strip --strip-unneeded -p -D /usr/local/lib{,64}/*.{so,a} && \
    find /usr/local \( -name '*.so' -o -name '*.a' \) -exec bash -c "strip -p -D --strip-unneeded {} -o /tmp/striped; if ! cmp {} /tmp/striped; then cp /tmp/striped {}; fi; rm -f /tmp/striped" \; && \
    find /opt/py -mindepth 1 -not -name '*p38-*' -print0 | xargs -n 1 -0 -P 1 bash -c '"${0}/bin/pip" wheel . --no-deps -w /io/wheelhouse && rm -rf build' && \
    find /io/wheelhouse/ -name 'openslide*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} auditwheel repair --only-plat --plat ${AUDITWHEEL_PLAT} -w /io/wheelhouse && \
    find /io/wheelhouse/ -name 'openslide*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v && \
    find /io/wheelhouse/ -name 'openslide*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} advzip -k -z && \
    ls -l /io/wheelhouse && \
    rm -rf ~/.cache && \
    echo "`date` openslide-python" >> /build/log.txt

# VIPS

# Optimizing loop compiler.  Used by libvips for speed improvements
RUN \
    echo "`date` orc" >> /build/log.txt && \
    export JOBS=`nproc` && \
    curl --retry 5 --silent https://github.com/GStreamer/orc/archive/`getver.py orc`.tar.gz -L -o orc.tar.gz && \
    mkdir orc && \
    tar -zxf orc.tar.gz -C orc --strip-components 1 && \
    rm -f orc.tar.gz && \
    cd orc && \
    meson setup --prefix=/usr/local --buildtype=release --optimization=3 -Dgtk_doc=disabled -Dtests=disabled -Dexamples=disabled -Dbenchmarks=disabled _build && \
    cd _build && \
    ninja -j ${JOBS} && \
    ninja -j ${JOBS} install && \
    ldconfig && \
    echo "`date` orc" >> /build/log.txt

# Used by libvips
RUN \
    echo "`date` nifti" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py nifti` -c advice.detachedHead=false https://github.com/NIFTI-Imaging/nifti_clib.git && \
    cd nifti_clib && \
    mkdir _build && \
    cd _build && \
    cmake .. -DBUILD_SHARED_LIBS=ON -DCMAKE_BUILD_TYPE=MinSizeRel && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` nifti" >> /build/log.txt

# General build tool
RUN \
    echo "`date` rust" >> /build/log.txt && \
    curl --retry 5 --silent https://sh.rustup.rs -sSf | sh -s -- -y --profile minimal && \
    echo "`date` rust" >> /build/log.txt

# Used by libvips and ImageMagick
RUN \
    echo "`date` libimagequant" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export PATH="$HOME/.cargo/bin:$PATH" && \
    git clone --depth=1 --single-branch -b `getver.py libimagequant` -c advice.detachedHead=false https://github.com/ImageOptim/libimagequant.git && \
    cd libimagequant/imagequant-sys && \
    cargo install cargo-c --locked && \
    cargo cinstall && \
    ldconfig && \
    # rust leaves huge build artifacts that aren't useful to us \
    rm -rf target/release/deps && \
    find . -name '*.a' -delete && \
    rm -rf /root/.cargo/registry && \
    echo "`date` libimagequant" >> /build/log.txt

# Used by libvips and ImageMagick
RUN \
    echo "`date` pango" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b `getver.py pango` -c advice.detachedHead=false https://github.com/GNOME/pango.git && \
    cd pango && \
    meson setup --prefix=/usr/local --buildtype=release --optimization=3 -Dintrospection=disabled _build && \
    cd _build && \
    ninja -j ${JOBS} && \
    ninja -j ${JOBS} install && \
    ldconfig && \
    echo "`date` pango" >> /build/log.txt

# Used by libvips and ImageMagick
RUN \
    echo "`date` librsvg" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export PATH="$HOME/.cargo/bin:$PATH" && \
    git clone --depth=1 --single-branch -b `getver.py librsvg` -c advice.detachedHead=false https://github.com/GNOME/librsvg.git && \
    cd librsvg && \
    export LDFLAGS="$LDFLAGS,--no-as-needed,-ldl" && \
    sed -i "s/'-U', //g" meson/makedef.py && \
    # Make the output library much smaller && \
    printf "[profile.release]\nlto = true" >> Cargo.toml && \
    meson setup --prefix=/usr/local --buildtype=release --optimization=3 -Dintrospection=disabled -Ddocs=disabled -Dtests=false _build && \
    meson compile -C _build -j ${JOBS} && \
    meson install -C _build && \
    ldconfig && \
    # rust leaves huge build artifacts that aren't useful to us \
    rm -rf _build/target/release/deps && \
    find . -name '*.a' -delete && \
    rm -rf /root/.cargo/registry && \
    echo "`date` librsvg" >> /build/log.txt

# Used by libvips
RUN \
    echo "`date` libarchive" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py libarchive` -c advice.detachedHead=false https://github.com/libarchive/libarchive.git && \
    cd libarchive && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel -DBUILD_TESTING=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 && \
    make --silent -j ${JOBS} && \
    make --silent -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libarchive" >> /build/log.txt

# Used by ImageMagick, though I don't see the library being bundled by libvips
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
# Used by libvips
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

# MatLAB I/O.  Used by libvips
RUN \
    echo "`date` matio" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py matio` -c advice.detachedHead=false https://github.com/tbeu/matio.git && \
    cd matio && \
    mkdir _build && \
    cd _build && \
    cmake .. -DCMAKE_BUILD_TYPE=MinSizeRel && \
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

# Used by libvips
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

# https://github.com/libvips/libvips/issues/3808), so using master.  This
# should be fixed in 8.15.2
RUN \
    echo "`date` libvips" >> /build/log.txt && \
    export JOBS=`nproc` && \
    # version \
    # git clone --depth=1 --single-branch -b v8.15.0 -c advice.detachedHead=false https://github.com/libvips/libvips.git && \
    git clone --depth=1 --single-branch -b v`getver.py libvips` -c advice.detachedHead=false https://github.com/libvips/libvips.git && \
    # master \
    # git clone -c advice.detachedHead=false https://github.com/libvips/libvips.git && \
    cd libvips && \
    # Allow using VIPS_TMPDIR for the temp directory \
    sed -i 's/tmpd;/tmpd;if ((tmpd=g_getenv("VIPS_TMPDIR"))) return(tmpd);/g' libvips/iofuncs/util.c && \
    sed -i 's/cfg_var.set('\''HAVE_TARGET_CLONES'\''/# cfg_var.set('\''HAVE_TARGET_CLONES'\''/g' meson.build && \
    export LDFLAGS="$LDFLAGS"',-rpath,$ORIGIN -lstdc++' && \
    sed -i 's/g_logv("tiff2vips", G_LOG_LEVEL_WARNING, fmt, ap);/\/\/g_logv("tiff2vips", G_LOG_LEVEL_WARNING, fmt, ap);/g' libvips/foreign/tiff2vips.c && \
    meson setup --prefix=/usr/local --buildtype=release _build -Dmodules=disabled -Dexamples=false -Dnifti-prefix-dir=/usr/local 2>&1 >meson_config.txt && \
    cd _build && \
    ninja -j ${JOBS} && \
    ninja -j ${JOBS} install && \
    ldconfig && \
    echo "`date` libvips" >> /build/log.txt

# Our version of pyvips contains libvips and all dependencies
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
    if [ -d /build/vips/tools/.libs/ ]; then \
    find /build/vips/tools/.libs/ -executable -type f -exec cp {} pyvips/bin/. \; ; \
    else \
    find /build/libvips/_build/tools -executable -type f -exec cp {} pyvips/bin/. \; ; \
    fi && \
    cp /usr/local/bin/magick pyvips/bin/. && \
    strip pyvips/bin/* --strip-unneeded -p -D && \
    python -c $'# \n\
import re \n\
path = "pyvips/version.py" \n\
s = open(path).read() \n\
s = re.sub(r"__version__ = \'(.+?)\'", lambda match: f"__version__ = \'{match.group(1)}.1\'", s) \n\
open(path, "w").write(s)' && \
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
    python -c $'# \n\
path = "pyproject.toml" \n\
s = open(path).read() \n\
s = s.replace("include-package-data = false", "include-package-data = true") \n\
s += """ \n\
[tool.setuptools.package-data] \n\
pyvips = ["bin/*"] \n\
\n\
[project.scripts] \n\
""" \n\
import os \n\
for name in os.listdir(\'pyvips/bin\'): \n\
  if not name.endswith(\'.py\'): \n\
    s += "%s = \'pyvips.bin:program\'\\n" % name \n\
open(path, "w").write(s)' && \
    # Strip libraries before building any wheels \
    # strip --strip-unneeded -p -D /usr/local/lib{,64}/*.{so,a} && \
    find /usr/local \( -name '*.so' -o -name '*.a' \) -exec bash -c "strip -p -D --strip-unneeded {} -o /tmp/striped; if ! cmp {} /tmp/striped; then cp /tmp/striped {}; fi; rm -f /tmp/striped" \; && \
    find /opt/py -mindepth 1 -print0 | xargs -n 1 -0 -P 1 bash -c '"${0}/bin/pip" wheel . --no-deps -w /io/wheelhouse; git clean -fxd -e pyvips/bin' && \
    find /io/wheelhouse/ -name 'pyvips*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} auditwheel repair --only-plat --plat ${AUDITWHEEL_PLAT} -w /io/wheelhouse && \
    find /io/wheelhouse/ -name 'pyvips*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v && \
    find /io/wheelhouse/ -name 'pyvips*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} advzip -k -z && \
    ls -l /io/wheelhouse && \
    rm -rf ~/.cache && \
    echo "`date` pyvips" >> /build/log.txt

# sasl is required for libmemcached
RUN \
    echo "`date` cyrus-sasl" >> /build/log.txt && \
    export JOBS=`nproc` && \
    export AUTOMAKE_JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b cyrus-sasl-`getver.py cyrus-sasl` -c advice.detachedHead=false https://github.com/cyrusimap/cyrus-sasl.git && \
    cd cyrus-sasl && \
    ./autogen.sh && \
    CFLAGS="$CFLAGS -Wno-implicit-function-declaration" \
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

# pylibmc requires more libraries than are bundled in the official wheels
RUN \
    echo "`date` pylibmc" >> /build/log.txt && \
    export JOBS=`nproc` && \
    # Use master branch \
    # git clone --depth=1 --single-branch -c advice.detachedHead=false https://github.com/lericson/pylibmc.git && \
    # Use latest release branch \
    git clone --depth=1 --single-branch -b `getver.py pylibmc` -c advice.detachedHead=false https://github.com/lericson/pylibmc.git && \
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
    sed -i 's/version=version/version=version + ".1"/g' setup.py && \
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
    find /io/wheelhouse/ -name 'pylibmc*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} auditwheel repair --only-plat --plat ${AUDITWHEEL_PLAT} -w /io/wheelhouse && \
    find /io/wheelhouse/ -name 'pylibmc*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v && \
    find /io/wheelhouse/ -name 'pylibmc*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} advzip -k -z && \
    ls -l /io/wheelhouse && \
    rm -rf ~/.cache && \
    echo "`date` pylibmc" >> /build/log.txt

# python-javabridge needs a jvm to work; this bundles the jvm with the python
# package.
RUN \
    echo "`date` python-javabridge" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py python-javabridge` -c advice.detachedHead=false https://github.com/CellProfiler/python-javabridge.git && \
    cd python-javabridge && \
    patch _javabridge.pyx ../python-javabridge.pyx.patch && \
    sed -i 's/        return env.get_string_utf(result)/        try:\n            return env.get_string_utf(result)\n        except Exception:\n            return env.get_string(result)/g' javabridge/jutil.py && \
    # Include java libraries \
    mkdir javabridge/jvm && \
    # remove debug symbols.  Keep parallelism <= 4 because it can spike memory \
    find /usr/lib/jvm/java/* -name '*.jar' -size +10240c -print0 | xargs -n 1 -0 -P $(( $JOBS < 4 ? $JOBS : 4 )) pack200 -G --repack && \
    # make jars deterministic \
    find /usr/lib/jvm/java/* -name '*.jar' -print0 | xargs -n 1 -0 -P ${JOBS} strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v && \
    cp -r -L /usr/lib/jvm/java/* javabridge/jvm/. && \
    find javabridge -name classes.jsa -delete && \
    # use a placeholder for the jar files to reduce the docker file size; \
    # they'll be restored later && \
    find javabridge/jvm -name '*.jar' -exec bash -c "echo placeholder > {}" \; && \
    if [ -e javabridge/jvm/jre/lib/amd64 ]; then \
    export ARCH="amd64"; \
    elif [ -e javabridge/jvm/jre/lib/aarch64 ]; then \
    export ARCH="aarch64"; \
    fi && \
    # libsaproc.so is only used for debugging \
    rm -f javabridge/jvm/jre/lib/"${ARCH}"/libsaproc.so && \
    sed -i 's/env.exception_describe()/pass/g' javabridge/jutil.py && \
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
s = re.sub(r"(\'Cython)[^\']*", "\'Cython", s) \n\
s = re.sub(r"(\'numpy)[^\']*", "\'numpy", s) \n\
s = re.sub(r\'(version="[^"]*)"\', "\\\\1.1\\"", s) \n\
open(path, "w").write(s)' && \
    python -c $'# \n\
import re \n\
path = "pyproject.toml" \n\
s = open(path).read() \n\
s = re.sub(r"(cython)<3", "cython", s) \n\
s = re.sub(r"(numpy)[^\\"]*", "numpy", s) \n\
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
import os \n\
path = "javabridge/jutil.py" \n\
s = open(path).read() \n\
s = s.replace("import javabridge._javabridge as _javabridge", \n\
"""libjvm_path = os.path.join(os.path.dirname(__file__), "jvm", "jre", "lib", \\"""" + os.environ["ARCH"] + """\\" , "server", "libjvm.so") \n\
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
s = s.replace("arches = (", """arches = ("aarch64", """) \n\
open(path, "w").write(s)' && \
    # export library paths so that auditwheel doesn't complain \
    export LD_LIBRARY_PATH="/usr/lib/jvm/jre/lib/${ARCH}/:/usr/lib/jvm/jre/lib/${ARCH}/jli:/usr/lib/jvm/jre/lib/${ARCH}/client:/usr/lib/jvm/jre/lib/${ARCH}/server:$LD_LIBRARY_PATH" && \
    # Strip libraries before building any wheels \
    # strip --strip-unneeded -p -D /usr/local/lib{,64}/*.{so,a} && \
    find /usr/local \( -name '*.so' -o -name '*.a' \) -exec bash -c "strip -p -D --strip-unneeded {} -o /tmp/striped; if ! cmp {} /tmp/striped; then cp /tmp/striped {}; fi; rm -f /tmp/striped" \; && \
    if [ -e javabridge/jvm/jre/lib/amd64 ]; then \
    find /opt/py -mindepth 1 -print0 | xargs -n 1 -0 -P 1 bash -c '"${0}/bin/pip" wheel . --no-deps -w /io/wheelhouse && rm -rf .eggs build' && \
    true; elif [ -e javabridge/jvm/jre/lib/aarch64 ]; then \
    find /opt/py -mindepth 1 -not -name '*p38-*' -print0 | xargs -n 1 -0 -P 1 bash -c '"${0}/bin/pip" wheel . --no-deps -w /io/wheelhouse && rm -rf .eggs build' && \
    true; fi && \
    find /io/wheelhouse/ -name 'python_javabridge*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} auditwheel repair --only-plat --plat ${AUDITWHEEL_PLAT} -w /io/wheelhouse && \
    # auditwheel modifies the java libraries, but some of those have \
    # hard-coded relative paths, which doesn't work.  Replace them with the \
    # unmodified versions.  See https://stackoverflow.com/questions/55904261 \
    find /io/wheelhouse/ -name 'python_javabridge*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} bash -c 'mkdir /tmp/ptmp$(basename ${0}) && pushd /tmp/ptmp$(basename ${0}) && unzip ${0} && mkdir so && cp -f -r -L javabridge/jvm/jre/lib/${ARCH}/*.so so/. && cp -f -r -L /usr/lib/jvm/java/* javabridge/jvm/. && cp -f -r -L so/* javabridge/jvm/jre/lib/${ARCH}/. && rm -rf so && find javabridge/jars -name '\''*.jar'\'' -exec strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v {} \; && rm javabridge/jvm/jre/lib/${ARCH}/server/classes.jsa && fix_record.py && zip -r ${0} * && popd && rm -rf /tmp/ptmp$(basename ${0})' && \
    find /io/wheelhouse/ -name 'python_javabridge*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v && \
    find /io/wheelhouse/ -name 'python_javabridge*many*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} advzip -k -z && \
    ls -l /io/wheelhouse && \
    rm -rf ~/.cache && \
    echo "`date` python-javabridge" >> /build/log.txt

# bioformats is a java reader/writer for images.  python-bioformats bundles the
# jar and provides some interface to the java # python-javabridge.  We build it because we want a newer jar than is provided
# by the public package
RUN \
    echo "`date` python-bioformats" >> /build/log.txt && \
    export JOBS=`nproc` && \
    git clone --depth=1 --single-branch -b v`getver.py python-bioformats` -c advice.detachedHead=false https://github.com/CellProfiler/python-bioformats.git && \
    cd python-bioformats && \
    curl -LJ https://github.com/ome/bioformats/releases/download/v`getver.py bioformats`/bioformats_package.jar -o bioformats/jars/bioformats_package.jar && \
    # Recompress; saves 2.5% or so \
    advzip -k -z bioformats/jars/bioformats_package.jar && \
    python -c $'# \n\
import re \n\
path = "setup.py" \n\
s = open(path).read() \n\
# append .1 to version to make sure pip prefers this \n\
s = re.sub(r"(version=\\"[^\\"]*)\\"", "\\\\1.'`getver.py bioformats`$'\\"", s) \n\
open(path, "w").write(s)' && \
    pip wheel . --no-deps -w /io/wheelhouse && \
    find /io/wheelhouse/ -name 'python_bioformats*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} strip-nondeterminism -T "$SOURCE_DATE_EPOCH" -t zip -v && \
    find /io/wheelhouse/ -name 'python_bioformats*.whl' -print0 | xargs -n 1 -0 -P ${JOBS} advzip -k -z && \
    echo "`date` python-bioformats" >> /build/log.txt
