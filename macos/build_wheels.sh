#!/usr/bin/env bash
# build_wheels.sh - build macOS arm64 wheels inside a tart macOS VM.
#
# This is the macOS counterpart of the repository's monolithic Dockerfile:
# a single self-contained script that builds every library a wheel needs
# from source into a private prefix, then builds and repairs the python
# wheels.  It is meant to be run inside a fresh tart VM (created by
# tart_build.sh on the host) so that the VM's system libraries and
# Homebrew packages cannot influence the built wheels.
#
# Environment notes:
#   LIW_PYTHONS   python versions to build for
#                 (default "3.11 3.12 3.13 3.14 3.15 3.14t 3.15t")
#   LIW_FORCE     set to 1 to ignore completed-step stamps and rebuild all
#   LIW_BUILD     working directory (default ~/liw_macos_build)
#
# Completed steps are stamped, so re-running this script only redoes what
# has not finished.  Wheels are collected in $LIW_BUILD/wheelhouse.

set -euo pipefail

LIW_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --------------------------------------------------------------------------
# Environment.  Mirror the Dockerfile's isolation: nothing from Homebrew or
# the macOS system may supply headers or link targets.  The base VM's shell
# profile exports CFLAGS containing -march=native, which is fine for
# development but must never leak into release wheels, so compiler flags are
# always set fresh here.
# --------------------------------------------------------------------------

unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
unset PYTHONPATH PYTHONHOME PYTHONUSERBASE PYTHONSTARTUP
unset SDKROOT
unset DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH DYLD_FRAMEWORK_PATH
unset DYLD_INSERT_LIBRARIES
while IFS='=' read -r var _; do
    case "$var" in
    HOMEBREW_*) unset "$var" ;;
    esac
done < <(env | sed 's/=.*//')

LIW_BUILD="${LIW_BUILD:-$HOME/liw_macos_build}"
LIW_PREFIX="$LIW_BUILD/prefix"
LIW_SRC="$LIW_BUILD/src"
LIW_STAMPS="$LIW_BUILD/stamps"
LIW_PATCHES="$LIW_BUILD/patches"
LIW_WHEELHOUSE="$LIW_BUILD/wheelhouse"
LIW_LOG="$LIW_BUILD/log.txt"
LIW_EXIT_CODE="$LIW_BUILD/exit_code"
PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"
export LIW_BUILD LIW_PREFIX LIW_SRC LIW_STAMPS LIW_PATCHES LIW_WHEELHOUSE

LIW_PYTHONS="${LIW_PYTHONS:-3.11 3.12 3.13 3.14 3.15 3.14t 3.15t}"
# Python used for patching sources, generating the tiff header, and running
# delocate (in order of preference).
LIW_PATCH_PYTHON_PREFERRED="3.13"
LIW_PATCH_PYTHON_FALLBACKS="3.14 3.12 3.11 3.15 3.14t 3.15t"

# macosx_11_0_arm64 wheels run on every Apple Silicon Mac (M1 and later).
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
# Match the reproducibility epoch used by the linux builds.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1667497300}"

export CFLAGS="-g0 -O2 -DNDEBUG"
export CXXFLAGS="-g0 -O2 -DNDEBUG"
# CPPFLAGS/LDFLAGS put the private prefix first so configure scripts and
# CMake find our libraries rather than macOS system or Homebrew ones.
# -headerpad_max_install_names leaves room for delocate to rewrite dylib
# load commands.
export CPPFLAGS="-I$LIW_PREFIX/include"
export LDFLAGS="-L$LIW_PREFIX/lib -Wl,-headerpad_max_install_names"
# Only system tools (Apple clang, git, curl, make, python3 -- all in
# /usr/bin via the Command Line Tools) and the private prefix are on PATH.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$LIW_PREFIX/bin"
# pkgconf is pointed at the private prefix only; Homebrew's pkg-config data
# is excluded.
export PKG_CONFIG="$LIW_PREFIX/bin/pkgconf"
export PKG_CONFIG_PATH="$LIW_PREFIX/lib/pkgconfig:$LIW_PREFIX/share/pkgconfig"
export PKG_CONFIG_ALLOW_SYSTEM_FLAGS=0
export PKG_CONFIG_ALLOW_SYSTEM_LIBS=0
export PYTHONDONTWRITEBYTECODE=1

LIW_JOBS="$(sysctl -n hw.ncpu)"

# --------------------------------------------------------------------------
# Helpers.
# --------------------------------------------------------------------------

step() {
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LIW_LOG"
}

die() {
    echo "error: $*" >&2
    exit 1
}

# Version pins come from the shared versions.txt, exactly like the linux
# build uses through getver.py.  getver.py resolves versions.txt relative
# to the current directory (the Dockerfile always runs from /build), so
# run it from the repository root in a subshell.
v() {
    (cd "$LIW_REPO" && python3 getver.py "$1")
}

# Stamp-based skipping so an interrupted build only redoes unfinished steps.
skip_if_done() {
    [ -z "${LIW_FORCE:-}" ] && [ -f "$LIW_STAMPS/$1" ]
}

done_stamp() {
    mkdir -p "$LIW_STAMPS"
    touch "$LIW_STAMPS/$1"
}

git_retry() { # git_retry <url> <tag> <dest dir>
    local n=0
    until git clone --depth=1 --single-branch -b "$2" \
        -c advice.detachedHead=false "$1" "$3"; do
        n=$((n + 1))
        [ "$n" -ge 10 ] && die "git clone failed after $n attempts: $1 ($2)"
        echo "retrying git clone: $1 ($2)"
        sleep 5
    done
}

fetch() { # fetch <url> <outfile>
    curl --retry 5 --silent --location --fail "$1" -o "$2" ||
        die "download failed: $1"
}

# Build and install a cmake project into the private prefix.  Homebrew and
# /usr/local are explicitly excluded from every search.
cmake_build() { # cmake_build <source dir> [extra cmake args...]
    local src="$1"
    shift
    (
        cd "$src" || exit 1
        rm -rf _build
        mkdir _build
        cd _build || exit 1
        # CMake's default install name on macOS is @rpath, which makes
        # bundling fragile; absolute install names are rewritten by
        # delocate to @loader_path-relative paths instead.
        cmake .. \
            -DCMAKE_BUILD_TYPE=MinSizeRel \
            -DCMAKE_PREFIX_PATH="$LIW_PREFIX" \
            -DCMAKE_INSTALL_PREFIX="$LIW_PREFIX" \
            -DCMAKE_INSTALL_LIBDIR=lib \
            -DCMAKE_INSTALL_NAME_DIR="$LIW_PREFIX/lib" \
            -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
            -DCMAKE_IGNORE_PATH="/opt/homebrew/include;/opt/homebrew/lib;/opt/homebrew/opt;/usr/local/include;/usr/local/lib" \
            "$@" || exit 1
        make -j "$LIW_JOBS" || exit 1
        make install
    ) || die "cmake build failed in $src"
}

# Resolve a requested python ("3.13" or "3.14t") to its pyenv version dir.
# Free-threaded installs land in dirs like "3.14.8t" (version + t suffix).
find_version_dir() {
    local req="$1" dir=""
    case "$req" in
    *t)
        dir="$PYENV_ROOT/versions/$req"
        [ -d "$dir" ] ||
            dir="$(ls -d "$PYENV_ROOT/versions/${req%t}".*t 2>/dev/null | sort -V | tail -1)"
        ;;
    *)
        dir="$(ls -d "$PYENV_ROOT/versions/$req".* 2>/dev/null | grep -v 't$' | sort -V | tail -1)"
        ;;
    esac
    [ -n "$dir" ] && printf '%s' "$dir"
    return 0
}

# Install any requested python versions that are missing from the base VM.
# python-build provides its own OpenSSL for the ssl module; do not inject
# Homebrew paths here (mixing Homebrew's OpenSSL with python-build's
# headers breaks the ssl module).
ensure_pythons() {
    local req pyenv="$PYENV_ROOT/bin/pyenv"
    [ -x "$pyenv" ] || die "pyenv not found at $pyenv"
    step "checking pythons: $LIW_PYTHONS"
    for req in $LIW_PYTHONS; do
        if [ -z "$(find_version_dir "$req")" ]; then
            step "pyenv install $req (several minutes)"
            "$pyenv" install -s "$req" || die "pyenv install $req failed"
        fi
    done
}

# The base VM's pyenv pythons were configured with Homebrew linker flags
# (-L/-Wl,-rpath /opt/homebrew...) and -march=native baked into their
# sysconfig data.  Every extension build inherits those values, which would
# both contaminate the wheels with Homebrew libraries and embed host CPU
# features.  Rewrite each python's sysconfigdata to remove tokens that
# reference Homebrew or /usr/local and any -march=native flag.
scrub_python_sysconfig() {
    local req dir
    step "scrubbing python sysconfig data"
    cat >"$LIW_PATCHES/scrub_sysconfig.py" <<'EOF'
import glob
import os
import sys

ver_dir = sys.argv[1]
for path in glob.glob(os.path.join(ver_dir, "lib", "python3.*", "*sysconfigdata*.py")):
    ns = {}
    exec(compile(open(path).read(), path, "exec"), ns)
    build_time_vars = ns["build_time_vars"]

    def scrub(value):
        if "/opt/homebrew" not in value and "/usr/local" not in value \
                and "-march=native" not in value \
                and "/.pyenv/" not in value:
            return value
        if " " not in value.strip():
            # Single-token values are plain paths or program names (e.g.
            # LIBDIR, LIBPL, prefix).  Removing the whole value would leave
            # empty strings that break consumers (a bare "-L" in link
            # commands comes from an emptied LIBDIR); path-only values are
            # inert at build time and are not recorded into the wheels.
            return value
        return " ".join(
            token
            for token in value.split()
            if "/opt/homebrew" not in token and "/usr/local" not in token
            and "/.pyenv/" not in token
            and token != "-march=native")

    cleaned = {}
    for key, value in build_time_vars.items():
        if isinstance(value, str):
            value = scrub(value)
        cleaned[key] = value
    with open(path, "w") as handle:
        handle.write("# sysconfigdata scrubbed for isolated wheel building\n")
        handle.write("build_time_vars = " + repr(cleaned) + "\n")
    cache = os.path.join(os.path.dirname(path), "__pycache__")
    stem = os.path.splitext(os.path.basename(path))[0]
    for cached in glob.glob(os.path.join(cache, stem + "*.pyc")):
        os.remove(cached)
    print("scrubbed", path)
EOF
    for req in $LIW_PYTHONS; do
        dir="$(find_version_dir "$req")"
        [ -n "$dir" ] || continue
        "$LIW_PATCH_DIR/bin/python" "$LIW_PATCHES/scrub_sysconfig.py" "$dir"
    done
}

# Collect the bin directories of all requested pythons into PYBINS.
collect_pybins() {
    local req dir
    PYBINS=()
    for req in $LIW_PYTHONS; do
        dir="$(find_version_dir "$req")"
        if [ -z "$dir" ]; then
            echo "warning: python $req not available; skipping" >&2
            continue
        fi
        PYBINS+=("$dir/bin")
    done
    [ "${#PYBINS[@]}" -gt 0 ] || die "no python versions available"
}

# Symlink the build *tools* we need from Homebrew into the private prefix so
# that the scrubbed PATH provides them without ever exposing Homebrew's
# libraries, headers, or pkg-config data.
ensure_tools() {
    local brew_prefix tool
    step "build tools"
    mkdir -p "$LIW_PREFIX/bin"
    if [ -x /opt/homebrew/bin/brew ]; then
        brew_prefix=/opt/homebrew
    elif [ -x /usr/local/bin/brew ]; then
        brew_prefix=/usr/local
    else
        die "Homebrew not found; the base VM should provide cmake, ninja, autoconf, automake, libtool, m4, and pkgconf"
    fi
    for tool in cmake ninja pkgconf m4 autoconf autoheader autom4te \
        autoreconf autoscan autoupdate ifnames automake aclocal \
        glibtool glibtoolize ccache; do
        if [ -x "$brew_prefix/bin/$tool" ]; then
            ln -sf "$brew_prefix/bin/$tool" "$LIW_PREFIX/bin/$tool"
        fi
    done
    # libtiff's autogen.sh wants libtoolize/libtool; Homebrew installs the
    # GNU variants as glibtoolize/glibtool, so provide the standard names.
    if [ -x "$brew_prefix/bin/glibtoolize" ]; then
        ln -sf "$brew_prefix/bin/glibtoolize" "$LIW_PREFIX/bin/libtoolize"
        ln -sf "$brew_prefix/bin/glibtool" "$LIW_PREFIX/bin/libtool"
    fi
    ln -sf pkgconf "$LIW_PREFIX/bin/pkg-config"
    for tool in cmake ninja pkgconf autoconf automake libtoolize; do
        command -v "$tool" >/dev/null 2>&1 || die "$tool unavailable after tool setup"
    done
}

# Choose the python used for patching, header generation, and delocate.
set_patch_python() {
    local req
    for req in $LIW_PATCH_PYTHON_PREFERRED $LIW_PATCH_PYTHON_FALLBACKS; do
        LIW_PATCH_DIR="$(find_version_dir "$req")"
        if [ -n "$LIW_PATCH_DIR" ]; then
            LIW_PATCH_PYBIN="$LIW_PATCH_DIR/bin/python"
            LIW_PATCH_PIPBIN="$LIW_PATCH_DIR/bin/pip"
            return 0
        fi
    done
    die "no python found for patching"
}

# Some CMake projects (libjpeg-turbo) install dylibs with a build-tree
# RPATH.  delocate only sanitizes rpaths on files that require other
# libraries, so dependency-free dylibs would keep those rpaths into the
# wheel.  None of the prefix dylibs need an rpath (their dependencies use
# absolute install names that delocate rewrites), so strip them all and
# re-sign (arm64 requires a valid signature after install_name_tool).
sanitize_prefix_dylibs() {
    step "stripping build rpaths from prefix dylibs"
    local f rp
    while IFS= read -r -d '' f; do
        while IFS= read -r rp; do
            case "$rp" in
            @loader_path/* | @executable_path/* | @rpath/*) ;;
            *) install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null || true ;;
            esac
        done < <(otool -l "$f" |
            awk '/LC_RPATH/{inr=1; next} inr && $1=="path" {print $2; inr=0}')
    done < <(find "$LIW_PREFIX/lib" -name '*.dylib' -type f -print0)
    while IFS= read -r -d '' f; do
        codesign -f -s - "$f" 2>/dev/null || true
    done < <(find "$LIW_PREFIX/lib" -name '*.dylib' -type f -print0)
}

# --------------------------------------------------------------------------
# Dependencies (mirroring the Dockerfile's build order and flags).
# --------------------------------------------------------------------------

build_zlib() {
    skip_if_done zlib && return 0
    step "zlib"
    cd "$LIW_SRC"
    rm -rf zlib
    git_retry https://github.com/madler/zlib.git "v$(v zlib)" zlib
    cmake_build "$LIW_SRC/zlib" -DZLIB_BUILD_TESTING=OFF
    done_stamp zlib
}

build_zstd() {
    skip_if_done zstd && return 0
    step "zstd"
    cd "$LIW_SRC"
    rm -rf zstd
    git_retry https://github.com/facebook/zstd "v$(v zstd)" zstd
    cmake_build "$LIW_SRC/zstd/build/cmake" \
        -DBUILD_SHARED_LIBS=ON -DZSTD_BUILD_STATIC=OFF \
        -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_TESTS=OFF
    done_stamp zstd
}

# jbig is only needed as a static library (libtiff links it in; there is
# then no dylib to bundle).
build_jbigkit() {
    skip_if_done jbigkit && return 0
    step "jbigkit"
    cd "$LIW_SRC"
    rm -rf jbigkit
    fetch "https://www.cl.cam.ac.uk/~mgk25/jbigkit/download/jbigkit-$(v jbigkit).tar.gz" \
        jbigkit.tar.gz
    mkdir jbigkit
    tar -zxf jbigkit.tar.gz -C jbigkit --strip-components 1
    cd jbigkit
    make lib CFLAGS="$CFLAGS -O2"
    mkdir -p "$LIW_PREFIX/lib" "$LIW_PREFIX/include"
    cp libjbig/libjbig.a "$LIW_PREFIX/lib/"
    cp libjbig/jbig.h libjbig/jbig_ar.h "$LIW_PREFIX/include/"
    done_stamp jbigkit
}

build_libwebp() {
    skip_if_done libwebp && return 0
    step "libwebp"
    cd "$LIW_SRC"
    rm -rf libwebp
    fetch "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$(v libwebp).tar.gz" \
        libwebp.tar.gz
    mkdir libwebp
    tar -zxf libwebp.tar.gz -C libwebp --strip-components 1
    cd libwebp
    ./configure --prefix="$LIW_PREFIX" \
        --enable-libwebpmux --enable-libwebpdecoder --enable-libwebpextras \
        --disable-static
    make -j "$LIW_JOBS"
    make install
    done_stamp libwebp
}

build_libjpeg_turbo() {
    skip_if_done libjpeg-turbo && return 0
    step "libjpeg-turbo"
    cd "$LIW_SRC"
    rm -rf libjpeg-turbo
    git_retry https://github.com/libjpeg-turbo/libjpeg-turbo.git \
        "$(v libjpeg-turbo)" libjpeg-turbo
    # arm64 SIMD uses NEON assembly compiled by clang; nasm is not needed.
    cmake_build "$LIW_SRC/libjpeg-turbo" \
        -DCMAKE_C_FLAGS="$CFLAGS -O3 -fPIC" \
        -DENABLE_STATIC=OFF
    done_stamp libjpeg-turbo
}

build_libdeflate() {
    skip_if_done libdeflate && return 0
    step "libdeflate"
    cd "$LIW_SRC"
    rm -rf libdeflate
    git_retry https://github.com/ebiggers/libdeflate.git "v$(v libdeflate)" libdeflate
    cmake_build "$LIW_SRC/libdeflate"
    done_stamp libdeflate
}

build_xz() {
    skip_if_done xz && return 0
    step "xz"
    cd "$LIW_SRC"
    rm -rf xz
    git_retry https://github.com/tukaani-project/xz.git "v$(v xz)" xz
    cmake_build "$LIW_SRC/xz" \
        -DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF -DENABLE_NLS=OFF
    done_stamp xz
}

build_libtiff() {
    skip_if_done libtiff && return 0
    step "libtiff"
    cd "$LIW_SRC"
    rm -rf libtiff
    git_retry https://gitlab.com/libtiff/libtiff.git "v$(v libtiff)" libtiff
    (
        cd libtiff || exit 1
        ./autogen.sh
        ./configure --prefix="$LIW_PREFIX" --disable-static
        make -j "$LIW_JOBS"
        make install
    ) || die "libtiff build failed"
    done_stamp libtiff
}

# lcms2 is an optional dependency of openjpeg (and later of gdal, mapnik,
# openslide).  The linux build produces one final state where every library
# was built before anything that could optionally use it; the macos build
# must reach the same state on a fresh VM, since configure-time feature
# detection silently drops optional libraries that are not yet installed.
build_lcms2() {
    skip_if_done lcms2 && return 0
    step "lcms2"
    cd "$LIW_SRC"
    rm -rf lcms2
    git_retry https://github.com/mm2/Little-CMS.git "lcms$(v lcms2)" lcms2
    (
        cd lcms2 || exit 1
        ./configure --prefix="$LIW_PREFIX" --disable-static
        make -j "$LIW_JOBS"
        make install
    ) || die "lcms2 build failed"
    done_stamp lcms2
}

build_libpng() {
    skip_if_done libpng && return 0
    step "libpng"
    cd "$LIW_SRC"
    rm -rf libpng
    git_retry https://github.com/glennrp/libpng.git "v$(v libpng)" libpng
    # On macOS libpng's cmake defaults to building a framework
    # (png.framework/png) instead of libpng16.dylib.  The framework's
    # install name would complicate delocate bundling, and no linux wheel
    # links a framework, so build the plain dylib like the linux build
    # does.
    cmake_build "$LIW_SRC/libpng" -DPNG_FRAMEWORK=OFF
    done_stamp libpng
}

# openjpeg is needed by glymur (its opj_* tools are bundled into the wheel)
# and later by gdal/openslide/mapnik.  The linux Dockerfile builds openjpeg
# twice (once before libtiff, once after); building it once *after* lcms2,
# libpng, zlib, and libtiff here yields the same final state: the opj tools
# get tiff, png, and lcms support from our libraries and MinSizeRel matches
# the linux rebuild.  Everything it can optionally use must exist before
# this runs, or cmake silently disables the feature.
build_openjpeg() {
    skip_if_done openjpeg && return 0
    step "openjpeg"
    cd "$LIW_SRC"
    rm -rf openjpeg
    fetch "https://github.com/uclouvain/openjpeg/archive/v$(v openjpeg).tar.gz" \
        openjpeg.tar.gz
    mkdir openjpeg
    tar -zxf openjpeg.tar.gz -C openjpeg --strip-components 1
    cmake_build "$LIW_SRC/openjpeg" -DBUILD_SHARED=ON -DBUILD_STATIC=OFF
    # Feature assertions: the linux wheels' opj tools link lcms2, libpng,
    # and libtiff.  A missing optional dependency at configure time would
    # otherwise silently reduce the tools' feature set, and no functional
    # test exercises every input path.
    local linked lib
    linked="$(otool -L "$LIW_PREFIX/bin"/opj_* \
        "$LIW_PREFIX/lib"/libopenjp2*.dylib 2>/dev/null || true)"
    [ -n "$linked" ] || die "openjpeg produced no binaries to check"
    for lib in lcms2 libpng libtiff; do
        printf '%s\n' "$linked" | grep -q "$lib" ||
            die "openjpeg was not linked against $lib; an optional dependency was missed (check the build order)"
    done
    done_stamp openjpeg
}

# The codec set matches the linux wheels: zlib, jpeg, jbig, lzma, zstd,
# webp, deflate.
build_libtiff_deps() {
    build_zlib
    build_zstd
    build_jbigkit
    build_libwebp
    build_libjpeg_turbo
    build_libdeflate
    build_xz
    build_libtiff
}

# --------------------------------------------------------------------------
# Packages.
# --------------------------------------------------------------------------

build_pylibtiff() {
    skip_if_done pylibtiff && return 0
    step "pylibtiff"
    local pp="$LIW_PATCH_PYBIN"

    # Dependencies may have just been built (fresh VM); strip any build-tree
    # RPATHs they installed before the wheels bundle them.
    sanitize_prefix_dylibs

    "$LIW_PATCH_PIPBIN" install -q -U setuptools-scm

    cd "$LIW_SRC"
    rm -rf pylibtiff
    git_retry https://github.com/pearu/pylibtiff.git "v$(v pylibtiff)" pylibtiff
    cd pylibtiff

    # Bundle the libtiff tools with the wheel, like the linux build does:
    # for each tool in libtiff's source tools directory, take the matching
    # executable our libtiff install produced.
    mkdir -p libtiff/bin
    local f base
    while IFS= read -r f; do
        base="$(basename "$f")"
        if [ -f "$LIW_PREFIX/bin/$base" ]; then
            cp -L "$LIW_PREFIX/bin/$base" libtiff/bin/
        fi
    done < <(find "$LIW_SRC/libtiff/tools" -type f -perm -111)
    [ -n "$(ls libtiff/bin)" ] || die "no libtiff tools found to bundle"
    strip -x libtiff/bin/* 2>/dev/null || true

    # Wrapper module so each bundled tool is exposed as a console script.
    cat >libtiff/bin/__init__.py <<'EOF'
import os
import sys

def program():
    path = os.path.join(os.path.dirname(__file__), os.path.basename(sys.argv[0]))
    os.execv(path, sys.argv)
EOF

    # Patch setup.py: expose the bundled tools as console scripts, include
    # them as package data, and link _tif_lzw against libtiff.
    cat >"$LIW_PATCHES/pylibtiff_setup.py" <<EOF
import os
path = "setup.py"
s = open(path).read()
s = s.replace(
    "'console_scripts': [",
    "'console_scripts': \n"
    "        ['%s=libtiff.bin:program' % name for name in os.listdir('libtiff/bin')\n"
    "         if not name.endswith('.py')] + [")
s = s.replace('name="libtiff.tif_lzw",',
    "name=\"libtiff.tif_lzw\", libraries=['tiff'], "
    "library_dirs=['%s']," % os.path.join(os.environ["LIW_PREFIX"], "lib"))
s = s.replace(
    "packages=find_packages(),",
    "packages=find_packages(), package_data={'libtiff': ['bin/*']},")
open(path, "w").write(s)
EOF
    cat >"$LIW_PATCHES/pylibtiff_libtiff_ctypes.py" <<'EOF'
# Make libtiff_ctypes find the bundled dylib.  delocate puts bundled dylibs
# in libtiff/.dylibs inside the wheel; keep the auditwheel-style locations
# from the linux build as fallbacks.
path = "libtiff/libtiff_ctypes.py"
s = open(path).read()
s = s.replace(
    "    libtiff = None if lib is None else ctypes.cdll.LoadLibrary(lib)",
    """    try:
        libtiff = None if lib is None else ctypes.cdll.LoadLibrary(lib)
    except Exception:
        lib = None
    if lib is None or True:
        libpath = os.path.abspath(os.path.join(os.path.dirname(os.path.realpath(
            __file__)), ".dylibs"))
        if not os.path.exists(libpath):
            libpath = os.path.abspath(os.path.join(os.path.dirname(os.path.realpath(
                __file__)), ".libs"))
        if not os.path.exists(libpath):
            libpath = os.path.abspath(os.path.join(os.path.dirname(os.path.dirname(
                os.path.realpath(__file__))), "libtiff.libs"))
        if not os.path.exists(libpath):
            libpath = os.path.abspath(os.path.join(os.path.dirname(os.path.dirname(
                os.path.realpath(__file__))), "pylibtiff.libs"))
        try:
            libs = os.listdir(libpath)
            # auditwheel names bundled libraries like libtiff-<hash>.so.6;
            # delocate keeps the original name, libtiff.6.dylib.
            pospath = os.path.join(libpath, [flib for flib in libs
                if flib.startswith("libtiff-") or flib.startswith("libtiff.")][0])
            if os.path.exists(pospath):
                lib = pospath
        except Exception:
            pass
        libtiff = None if lib is None else ctypes.cdll.LoadLibrary(lib)""")
s = s.replace('print("Not trying"', '# print("Not trying"')
open(path, "w").write(s)
EOF
    cat >"$LIW_PATCHES/pylibtiff_pyproject.py" <<'EOF'
path = "pyproject.toml"
s = open(path).read()
s = s.replace(
    "'oldest-supported-numpy'",
    "'oldest-supported-numpy; python_version < \"3.9\"', 'numpy; python_version >= \"3.9\"'")
open(path, "w").write(s)
EOF
    "$pp" "$LIW_PATCHES/pylibtiff_setup.py"
    "$pp" "$LIW_PATCHES/pylibtiff_libtiff_ctypes.py"
    cat >"$LIW_PATCHES/pylibtiff_libtiff_ctypes_getfield.py" <<'EOF'
# Wrap the TIFFGetField ctypes function so that its argument types are
# always explicit on the actual call.  large_image clears
# libtiff.TIFFGetField.argtypes; with no argtypes, ctypes passes the
# arguments of variadic functions differently on darwin/arm64 and the
# call segfaults inside libtiff for any tag present in the file (the
# linux builds are unaffected).  The wrapper still accepts argtypes and
# restype assignments (large_image sets argtypes to None) so external
# code keeps working.  Note: argtypes are mutated around the call;
# large_image serializes pylibtiff access per directory.
path = "libtiff/libtiff_ctypes.py"
s = open(path).read()
s += '''
_TIFFGetField_ptr = libtiff.TIFFGetField

class _TIFFGetFieldWrapper(object):
    def __init__(self, ptr):
        object.__setattr__(self, '_ptr', ptr)
        self.argtypes = None
        self.restype = ptr.restype

    def __getattr__(self, name):
        return getattr(self._ptr, name)

    def __setattr__(self, name, value):
        if name in ('argtypes', 'restype'):
            object.__setattr__(self, name, value)
        else:
            setattr(self._ptr, name, value)

    def __call__(self, *args):
        ptr = self._ptr
        saved = ptr.argtypes
        ptr.argtypes = [TIFF, c_ttag_t]
        try:
            return ptr(*args)
        finally:
            ptr.argtypes = saved

libtiff.TIFFGetField = _TIFFGetFieldWrapper(_TIFFGetField_ptr)
'''
open(path, "w").write(s)
EOF
    "$pp" "$LIW_PATCHES/pylibtiff_libtiff_ctypes_getfield.py"
    "$pp" "$LIW_PATCHES/pylibtiff_pyproject.py"

    # Generate the tiff header companion file (needs numpy present, and
    # DYLD_LIBRARY_PATH so that find_library('tiff') locates our libtiff;
    # the wheel itself never relies on DYLD_* paths).
    "$LIW_PATCH_PIPBIN" install -q numpy
    (
        cd "$LIW_SRC/pylibtiff"
        DYLD_LIBRARY_PATH="$LIW_PREFIX/lib" \
            TIFF_HEADER_PATH="$PWD/libtiff/tiff.h" \
            "$pp" libtiff/libtiff_ctypes.py || true
    )
    "$LIW_PATCH_PIPBIN" uninstall -q -y numpy

    # Commit the patches and tag with the combined version (package version
    # + bundled libtiff version), matching the linux wheel versioning.
    git config user.email "wheels@example.com"
    git config user.name "Wheel Builder"
    git add -A
    git commit -q -m "patch for wheel building"
    git tag "$(v pylibtiff).$(v libtiff)"

    # Build one wheel per python, then bundle the dylibs with delocate
    # (the auditwheel equivalent on macOS).
    collect_pybins
    local pybin
    for pybin in "${PYBINS[@]}"; do
        step "pylibtiff wheel: $(basename "$(dirname "$pybin")")"
        (
            cd "$LIW_SRC/pylibtiff"
            rm -rf build
            # The extension's include path comes through CFLAGS (the sysconfig
            # data was scrubbed of Homebrew entries, so ours is authoritative).
            CFLAGS="$CFLAGS -I$LIW_PREFIX/include" \
                "$pybin/python" -m pip wheel --no-deps -w "$LIW_WHEELHOUSE" .
        ) || die "pylibtiff wheel build failed for $pybin"
    done

    step "delocate pylibtiff wheels"
    "$LIW_PATCH_PIPBIN" install -q -U delocate
    local whl
    for whl in "$LIW_WHEELHOUSE"/pylibtiff-*.whl; do
        [ -f "$whl" ] || continue
        case "$(basename "$whl")" in
        *macosx*) "$LIW_PATCH_DIR/bin/delocate-wheel" "$whl" ||
            die "delocate failed for $whl" ;;
        esac
    done
    ls -l "$LIW_WHEELHOUSE"
    [ -n "$(ls "$LIW_WHEELHOUSE"/pylibtiff-*macosx*.whl 2>/dev/null)" ] ||
        die "no pylibtiff macosx wheels were built"
    done_stamp pylibtiff
}

build_glymur() {
    skip_if_done glymur && return 0
    step "glymur"
    local pp="$LIW_PATCH_PYBIN"

    # Dependencies may have just been built (fresh VM); strip any build-tree
    # RPATHs they installed before the wheels bundle them.
    sanitize_prefix_dylibs

    cd "$LIW_SRC"
    rm -rf glymur
    git_retry https://github.com/quintusdias/glymur.git "v$(v glymur)" glymur
    cd glymur

    # Bundle the openjpeg and libjpeg command line tools with the wheel,
    # like the linux build does; glymur.bin exposes each as a console
    # script that os.execv's the binary.
    mkdir -p glymur/bin
    local tool
    for tool in "$LIW_PREFIX"/bin/opj_*; do
        if [ -f "$tool" ]; then
            cp -L "$tool" glymur/bin/
        fi
    done
    for tool in jpegtran cjpeg djpeg rdjpgcom wrjpgcom; do
        if [ -f "$LIW_PREFIX/bin/$tool" ]; then
            cp -L "$LIW_PREFIX/bin/$tool" glymur/bin/
        fi
    done
    [ -n "$(ls glymur/bin)" ] || die "no openjpeg/libjpeg tools found to bundle"
    strip -x glymur/bin/* 2>/dev/null || true
    # cmake-installed executables keep build-tree RPATHs (e.g. to
    # $LIW_PREFIX/lib).  delocate's rpath sanitizer only processes files
    # that require other libraries, so the dependency-free tools (rdjpgcom,
    # wrjpgcom) would carry the build prefix's RPATH into the wheel and
    # fail the test VM's otool audit.  Strip every non-@ RPATH and re-sign
    # (arm64 requires a valid signature after install_name_tool).
    local f rp
    while IFS= read -r -d '' f; do
        while IFS= read -r rp; do
            case "$rp" in
            @loader_path/* | @executable_path/* | @rpath/*) ;;
            *) install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null || true ;;
            esac
        done < <(otool -l "$f" |
            awk '/LC_RPATH/{inr=1; next} inr && $1=="path" {print $2; inr=0}')
        codesign -f -s - "$f" 2>/dev/null || true
    done < <(find glymur/bin -type f -perm -111 -print0)

    # Wrapper module so each bundled tool is exposed as a console script.
    cat >glymur/bin/__init__.py <<'EOF'
import os
import sys

def program():
    path = os.path.join(os.path.dirname(__file__), os.path.basename(sys.argv[0]))
    os.execv(path, sys.argv)
EOF

    # Patch config.py so glymur finds the bundled openjpeg dylib.  delocate
    # puts bundled dylibs in glymur/.dylibs inside the wheel; keep the
    # auditwheel-style Glymur.libs location from the linux build as a
    # fallback so the patch stays comparable across platforms.
    cat >"$LIW_PATCHES/glymur_config.py" <<'EOF'
path = "glymur/config.py"
s = open(path).read()
s = s.replace("    path = find_library(libname)",
"""    path = find_library(libname)
    libpath = os.path.abspath(os.path.join(os.path.dirname(os.path.realpath(
        __file__)), ".dylibs"))
    if not os.path.exists(libpath):
        libpath = os.path.abspath(os.path.join(os.path.dirname(os.path.dirname(
            os.path.realpath(__file__))), "Glymur.libs"))
    if os.path.exists(libpath):
        libs = os.listdir(libpath)
        try:
            pospath = os.path.join(libpath, [lib for lib in libs if
                "lib" + libname in lib][0])
            if os.path.exists(pospath):
                path = pospath
        except Exception:
            pass""")
open(path, "w").write(s)
EOF
    # Patch pyproject.toml: expose the bundled tools as console scripts,
    # include them (and the test data) as package data, allow python 3.10,
    # and add the local build suffix to the version, matching the linux
    # wheel versioning (Glymur-0.14.8.1).
    cat >"$LIW_PATCHES/glymur_pyproject.py" <<'EOF'
import os
import re
path = "pyproject.toml"
s = open(path).read()
s = s.replace("jpeg2jp2 = 'glymur.command_line:jpeg2jp2'",
    "jpeg2jp2 = 'glymur.command_line:jpeg2jp2'" +
    "".join(["\n%s = 'glymur.bin:program'" % name for name in os.listdir("glymur/bin")
        if not name.endswith(".py")]))
# glymur 0.14.8 imports packaging in version.py without declaring it
# (upstream bug); declare it so 'import glymur' works on a clean install.
s = s.replace("dependencies = [\n    'numpy',",
    "dependencies = [\n    'packaging',\n    'numpy',")
s = s.replace("requires-python = '>=3.11'", "requires-python = '>=3.10'")
s += """
[tool.setuptools]
include-package-data = true

[tool.setuptools.package-data]
glymur = [
    "data/*.jp2",
    "data/*.jpx",
    "data/*.j2k",
    "bin/*",
]
"""
s = re.sub(r"(version = ')(\d+\.\d+\.\d+)((?:post\d+)?)(')", r"\1\2.1\3\4", s)
open(path, "w").write(s)
EOF
    "$pp" "$LIW_PATCHES/glymur_config.py"
    "$pp" "$LIW_PATCHES/glymur_pyproject.py"

    # Commit the patches and tag with the combined version (the patched
    # package version), matching the linux wheel versioning.
    git config user.email "wheels@example.com"
    git config user.name "Wheel Builder"
    git add -A
    git commit -q -m "patch for wheel building"
    git tag "$(v glymur).1"

    # Build one wheel per python.  glymur is pure python, so pip tags the
    # wheels py3-none-any; they are retagged before delocate below.
    collect_pybins
    local pybin
    for pybin in "${PYBINS[@]}"; do
        step "glymur wheel: $(basename "$(dirname "$pybin")")"
        (
            cd "$LIW_SRC/glymur"
            rm -rf build
            "$pybin/python" -m pip wheel --no-deps -w "$LIW_WHEELHOUSE" .
        ) || die "glymur wheel build failed for $pybin"
    done

    step "delocate glymur wheels"
    "${LIW_PATCH_PIPBIN}" install -q -U delocate
    # pip may write the wheel filename in lowercase (glymur-...) even though
    # the distribution is named Glymur; the linux build renames it to the
    # capitalized name before repair, and the loop below globs for Glymur-*.
    local whl newname
    for whl in "$LIW_WHEELHOUSE"/glymur-*.whl; do
        [ -f "$whl" ] || continue
        mv "$whl" "$(dirname "$whl")/$(basename "$whl" | sed 's/^glymur-/Glymur-/')"
    done
    for whl in "$LIW_WHEELHOUSE"/Glymur-*.whl; do
        [ -f "$whl" ] || continue
        case "$(basename "$whl")" in
        *-any.whl)
            # delocate never retags an "any" wheel, but it rewrites the WHEEL
            # file's tags to match the wheel filename, so rename first; the
            # bundled executables make this a macosx_11_0_arm64 wheel.
            newname="$(basename "$whl" | sed 's/-any\.whl/-macosx_11_0_arm64.whl/')"
            mv "$whl" "$(dirname "$whl")/$newname"
            whl="$(dirname "$whl")/$newname"
            ;;
        esac
        "$LIW_PATCH_DIR/bin/delocate-wheel" "$whl" || die "delocate failed for $whl"
    done
    ls -l "$LIW_WHEELHOUSE"
    [ -n "$(ls "$LIW_WHEELHOUSE"/Glymur-*macosx*.whl 2>/dev/null)" ] ||
        die "no Glymur macosx wheels were built"
    done_stamp glymur
}

# --------------------------------------------------------------------------
# Main.
# --------------------------------------------------------------------------

finish() {
    local code=$?
    echo "$code" >"$LIW_EXIT_CODE"
    echo "$code" >"$LIW_BUILD/status"
}

mkdir -p "$LIW_BUILD" "$LIW_SRC" "$LIW_STAMPS" "$LIW_PATCHES" "$LIW_WHEELHOUSE"
rm -f "$LIW_EXIT_CODE"
echo running >"$LIW_BUILD/status"
trap finish EXIT

step "environment"
echo "prefix:      $LIW_PREFIX" | tee -a "$LIW_LOG"
echo "pythons:     $LIW_PYTHONS" | tee -a "$LIW_LOG"
echo "deploy target: $MACOSX_DEPLOYMENT_TARGET" | tee -a "$LIW_LOG"

ensure_tools
if [ -z "${LIW_DRYRUN:-}" ]; then
    ensure_pythons
fi
set_patch_python
scrub_python_sysconfig
step "patch python: $LIW_PATCH_PYBIN"

if [ -n "${LIW_DRYRUN:-}" ]; then
    collect_pybins
    step "dry run: environment and tools verified; stopping before builds"
    exit 0
fi

PACKAGES=("$@")
# Keep in sync with tart_build.sh's LIW_PACKAGES default: the expected-wheel
# validation there assumes this same set when no packages are named.
[ "${#PACKAGES[@]}" -eq 0 ] && PACKAGES=(pylibtiff glymur)

# The "${var[@]+...}" guard keeps bash 3.2 (the VM's default bash) happy
# about empty arrays under `set -u`.
for pkg in ${PACKAGES[@]+"${PACKAGES[@]}"}; do
    case "$pkg" in
    pylibtiff)
        build_libtiff_deps
        build_pylibtiff
        ;;
    glymur)
        # Order matters: everything openjpeg can optionally use (zlib, jpeg,
        # tiff via libtiff_deps, lcms2, libpng) must be installed before
        # build_openjpeg runs, or its cmake silently disables the feature.
        build_libtiff_deps
        build_lcms2
        build_libpng
        build_openjpeg
        build_glymur
        ;;
    # "dep:<name>" builds a single dependency; useful for debugging.
    dep:*)
        "build_${pkg#dep:}" || die "building $pkg failed"
        ;;
    *)
        die "unknown package: $pkg"
        ;;
    esac
done

step "all done; wheels in $LIW_WHEELHOUSE"
