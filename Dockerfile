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
 
RUN curl http://pkgconfig.freedesktop.org/releases/pkg-config-0.29.2.tar.gz -L -o pkg-config.tar.gz && \
    mkdir pkg-config && \
    tar -zxf pkg-config.tar.gz -C pkg-config --strip-components 1 && \
    cd pkg-config && \
    ./configure --prefix=/usr/local --with-internal-glib --disable-host-tool && \
    make -j && \
    make -j install 
    
# 1.4.17
RUN curl ftp://ftp.gnu.org/gnu/m4/m4-latest.tar.gz -L -o m4.tar.gz && \
    mkdir m4 && \
    tar -zxf m4.tar.gz -C m4 --strip-components 1 && \
    cd m4 && \
    ./configure --prefix=/usr/local && \
    make -j && \
    make -j install 
 
RUN curl -L http://install.perlbrew.pl | bash && \
    . ~/perl5/perlbrew/etc/bashrc && \
    echo '. /root/perl5/perlbrew/etc/bashrc' >> /etc/bashrc && \
    perlbrew install perl-5.29.0 -j -n && \
    perlbrew switch perl-5.29.0 
 
RUN curl http://ftp.gnu.org/gnu/automake/automake-1.16.1.tar.gz -L -o automake.tar.gz && \
    mkdir automake && \
    tar -zxf automake.tar.gz -C automake --strip-components 1 && \
    cd automake && \
    ./configure --prefix=/usr/local && \
    make -j && \
    make -j install
 
# 2.69 ?
RUN curl http://ftp.gnu.org/gnu/autoconf/autoconf-latest.tar.gz -L -o autoconf.tar.gz && \
    mkdir autoconf && \
    tar -zxf autoconf.tar.gz -C autoconf --strip-components 1 && \
    cd autoconf && \
    ./configure --prefix=/usr/local && \
    make -j && \
    make -j install

RUN curl http://ftp.gnu.org/gnu/libtool/libtool-2.4.6.tar.gz -L -o libtool.tar.gz && \
    mkdir libtool && \
    tar -zxf libtool.tar.gz -C libtool --strip-components 1 && \
    cd libtool && \
    ./configure --prefix=/usr/local && \
    make -j && \
    make -j install

# CMake

RUN curl https://cmake.org/files/v3.11/cmake-3.11.4.tar.gz -L -o cmake.tar.gz && \
    mkdir cmake && \
    tar -zxf cmake.tar.gz -C cmake --strip-components 1 && \
    cd cmake && \
    ./bootstrap && \
    make -j && \
    make -j install

# Packages used by large_image that don't have published wheels

RUN git clone --depth=1 --single-branch https://github.com/giampaolo/psutil.git && \
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

# OpenJPEG

RUN yum install -y \
    # needed for openjpeg
    lcms2-devel \
    libpng-devel \
    zlib-devel

RUN curl https://github.com/uclouvain/openjpeg/archive/v2.3.0.tar.gz -L -o openjpeg.tar.gz && \
    mkdir openjpeg && \
    tar -zxf openjpeg.tar.gz -C openjpeg --strip-components 1 && \
    cd openjpeg && \
    cmake . && \
    make -j && \
    make -j install && \
    ldconfig

# libtiff

# Note: This doesn't support GL or jpeg 8/12

RUN yum install -y \
    # needed for libtiff
    freeglut-devel \
    libjpeg-devel \
    mesa-libGL-devel \
    mesa-libGLU-devel \
    xz-devel

RUN curl https://www.cl.cam.ac.uk/~mgk25/jbigkit/download/jbigkit-2.1.tar.gz -L -o jbigkit.tar.gz && \
    mkdir jbigkit && \
    tar -zxf jbigkit.tar.gz -C jbigkit --strip-components 1 && \
    cd jbigkit/libjbig && \
    make -j && \
    cp *.o /usr/local/lib/. && \
    cp *.h /usr/local/include/. && \
    ldconfig

RUN curl https://download.osgeo.org/libtiff/tiff-4.0.9.tar.gz -L -o tiff.tar.gz && \
    mkdir tiff && \
    tar -zxf tiff.tar.gz -C tiff --strip-components 1 && \
    cd tiff && \
    ./configure --prefix=/usr/local && \
    make -j && \
    make -j install && \
    ldconfig

# Rebuild openjpeg with our libtiff 
RUN cd openjpeg && \
    cmake . && \
    make -j && \
    make -j install && \
    ldconfig

RUN git clone --depth=1 --single-branch -b wheel-support https://github.com/manthey/pylibtiff.git && \
    cd pylibtiff && \
    for PYBIN in /opt/python/*/bin/; do \
      echo "${PYBIN}" && \
      "${PYBIN}/pip" install numpy && \
      "${PYBIN}/pip" wheel . -w /io/wheelhouse; \
    done && \
    for WHL in /io/wheelhouse/libtiff*.whl; do \
      auditwheel repair "${WHL}" -w /io/wheelhouse/; \
    done && \ 
    ls -l /io/wheelhouse

# OpenSlide

ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/lib64/pkgconfig

RUN yum install -y \
    # needed for openslide
    cairo-devel \
    libtool 

# Install newer versions of glib2, gdk-pixbuf2, libxml2.  
# In our setup.py, we may want to confirm glib2 >= 2.25.9

RUN curl http://ftp.gnome.org/pub/gnome/sources/glib/2.25/glib-2.25.9.tar.gz -L -o glib-2.tar.gz && \
    mkdir glib-2 && \
    tar -zxf glib-2.tar.gz -C glib-2 --strip-components 1 && \
    cd glib-2 && \
    ./configure --prefix=/usr/local && \ 
    make -j && \
    make -j install && \
    ldconfig

RUN curl https://ftp.gnome.org/pub/gnome/sources/gdk-pixbuf/2.21/gdk-pixbuf-2.21.7.tar.gz -L -o gdk-pixbuf-2.tar.gz && \
    mkdir gdk-pixbuf-2 && \
    tar -zxf gdk-pixbuf-2.tar.gz -C gdk-pixbuf-2 --strip-components 1 && \
    cd gdk-pixbuf-2 && \
    ./configure --prefix=/usr/local && \
    make -j && \
    make -j install && \
    ldconfig

RUN curl http://xmlsoft.org/sources/libxml2-2.7.8.tar.gz -L -o libxml2.tar.gz && \
    mkdir libxml2 && \
    tar -zxf libxml2.tar.gz -C libxml2 --strip-components 1 && \
    cd libxml2 && \
    ./configure --prefix=/usr/local && \
    make -j && \
    make -j install && \
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

RUN curl https://github.com/openslide/openslide/archive/v3.4.1.tar.gz -L -o openslide.tar.gz && \
    mkdir openslide && \
    tar -zxf openslide.tar.gz -C openslide --strip-components 1 && \
    cd openslide && \
    autoreconf -ifv && \
    ./configure --prefix=/usr/local && \
    make -j && \
    make -j install && \
    ldconfig

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
        _lib = cdll.LoadLibrary(\'libopenslide.so.0\') \n\
    except Exception: \n\
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
        _lib = cdll.LoadLibrary(lib)""") \n\
open(path, "w").write(s)' && \
    for PYBIN in /opt/python/*/bin/; do \
      echo "${PYBIN}" && \
      "${PYBIN}/pip" wheel . -w /io/wheelhouse; \
    done && \
    for WHL in /io/wheelhouse/openslide*.whl; do \
      auditwheel repair "${WHL}" -w /io/wheelhouse/ ||  exit 1; \
    done && \ 
    ls -l /io/wheelhouse

# ImageMagick

RUN git clone --depth=1 --single-branch https://github.com/ImageMagick/ImageMagick.git ImageMagick && \
    cd ImageMagick && \
    ./configure --prefix=/usr/local --with-modules --without-fontconfig && \
    make -j && \
    make -j install && \
    ldconfig 

# VIPS

RUN yum install -y \
    fftw3-devel \
    giflib-devel \
    matio-devel

RUN curl https://github.com/libvips/libvips/releases/download/v8.7.0/vips-8.7.0.tar.gz -L -o vips.tar.gz && \
    mkdir vips && \
    tar -zxf vips.tar.gz -C vips --strip-components 1 && \
    cd vips && \
    CXXFLAGS=-D_GLIBCXX_USE_CXX11_ABI=0 ./configure --prefix=/usr/local && \
    make -j && \
    make -j install && \
    ldconfig

RUN python -c $'# \n\
import os \n\
path = os.popen("find /opt/_internal -name policy.json").read().strip() \n\
data = open(path).read().replace( \n\
    "libXext.so.6", "XlibXext.so.6").replace( \n\
    "libSM.so.6", "XlibSM.so.6").replace( \n\
    "libICE.so.6", "XlibICE.so.6") \n\
open(path, "w").write(data)'

RUN git clone --depth=1 --single-branch https://github.com/libvips/pyvips && \
    cd pyvips && \
    python -c $'# \n\
path = "pyvips/__init__.py" \n\
s = open(path).read().replace( \n\
"""        _gobject_libname = \'libgobject-2.0.so.0\'""",  \n\
"""        _gobject_libname = \'libgobject-2.0.so.0\' \n\
        try: \n\
            import os \n\
            libpath = os.path.abspath(os.path.join(os.path.dirname(os.path.realpath( \n\
                __file__)), \'..\', \'.libs_libvips\')) \n\
            libs = os.listdir(libpath) \n\
            loadCount = 0 \n\
            while True: \n\
                numLoaded = 0 \n\
                for name in libs: \n\
                    try: \n\
                        somelib = os.path.join(libpath, name) \n\
                        if name.startswith(\'libvips\'): \n\
                            _vips_libname = somelib \n\
                        if name.startswith(\'libgobject-\'): \n\
                            _gobject_libname = somelib \n\
                        ffi.dlopen(somelib) \n\
                        numLoaded += 1 \n\
                    except Exception as exc: \n\
                        pass \n\
                if numLoaded - loadCount <= 0: \n\
                    break \n\
                loadCount = numLoaded \n\
        except Exception: \n\
            pass\n""") \n\
open(path, "w").write(s)' && \
    for PYBIN in /opt/python/*/bin/; do \
      echo "${PYBIN}" && \
      "${PYBIN}/pip" wheel . -w /io/wheelhouse; \
    done && \
    for WHL in /io/wheelhouse/pyvips*.whl; do \
      auditwheel repair "${WHL}" -w /io/wheelhouse/; \
    done && \ 
    ls -l /io/wheelhouse
    

