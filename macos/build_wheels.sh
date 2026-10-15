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
# PKG_CONFIG_ALLOW_SYSTEM_LIBS only strips system -L/-I flags from the
# output; pc *discovery* still scans pkgconf's built-in default dirs, which
# for Homebrew's pkgconf include /opt/homebrew.  Any meson "auto" feature
# whose library is installed in Homebrew but not here would silently leak
# in (observed with X11 and lzo on the build host).  PKG_CONFIG_LIBDIR
# replaces the default search entirely, so discovery is prefix-scoped.
export PKG_CONFIG_LIBDIR="$LIW_PREFIX/lib/pkgconfig:$LIW_PREFIX/share/pkgconfig"
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
# run it from the repository root in a subshell.  Extra arguments are
# passed through, matching getver.py's field-selection calls (the Dockerfile
# uses e.g. `getver.py sqlite 2 . . 1` for the sqlite release number).
v() {
    (cd "$LIW_REPO" && python3 getver.py "$@")
}

# Stamp-based skipping so an interrupted build only redoes unfinished steps.
skip_if_done() {
    [ -z "${LIW_FORCE:-}" ] && [ -f "$LIW_STAMPS/$1" ]
}

done_stamp() {
    mkdir -p "$LIW_STAMPS"
    touch "$LIW_STAMPS/$1"
}

# An empty tag means a full clone of the default branch: the caller checks
# out a pinned commit sha afterwards, which a --depth=1 clone of the branch
# tip cannot contain (openslide is pinned by sha, like the linux build).
git_retry() { # git_retry <url> <tag> <dest dir>
    local n=0 shallow=(--depth=1 --single-branch -b "$2")
    if [ -z "$2" ]; then
        shallow=()
    fi
    until git clone ${shallow[@]+"${shallow[@]}"} \
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

# The base VM's Homebrew set does not include meson (glib, pixman,
# freetype, fontconfig, cairo, and openslide are meson builds).  Install
# it into the patch python instead -- it is a build tool only and never
# enters a wheel.
ensure_meson() {
    LIW_MESON="$LIW_PATCH_DIR/bin/meson"
    if [ ! -x "$LIW_MESON" ]; then
        "$LIW_PATCH_PIPBIN" install -q -U meson || die "pip install meson failed"
    fi
    [ -x "$LIW_MESON" ] || die "meson unavailable after tool setup"
}

# Build and install a meson project into the private prefix.  The flags
# mirror the Dockerfile's meson invocations (buildtype=release,
# optimization=3); the private prefix's pkg-config setup applies as
# everywhere else.
meson_build() { # meson_build <source dir> [extra meson setup args...]
    local src="$1"
    shift
    (
        cd "$src" || exit 1
        rm -rf _build
        "$LIW_MESON" setup _build \
            --prefix="$LIW_PREFIX" \
            --buildtype=release \
            -Doptimization=3 \
            "$@" || exit 1
        ninja -C _build -j "$LIW_JOBS" || exit 1
        ninja -C _build install
    ) || die "meson build failed in $src"
}

# The Dockerfile installs rust (rustup, minimal profile) into the linux
# image and prepends ~/.cargo/bin to PATH for the builds that need it
# (libimagequant; librsvg later).  The base VM provisioning installs the
# same toolchain; this helper bootstraps it on a base VM that was
# provisioned before rust was added.  Like meson, rust is a build tool
# only: the wheels never contain the toolchain, only the dylibs it
# produces (which are installed into the private prefix and audited like
# every other bundled library).
ensure_rust() {
    if [ ! -x "$HOME/.cargo/bin/cargo" ]; then
        step "installing rust (rustup, minimal profile)"
        if ! curl --retry 5 --silent -sSf https://sh.rustup.rs |
            sh -s -- -y --profile minimal; then
            die "rustup installation failed"
        fi
    fi
    [ -x "$HOME/.cargo/bin/cargo" ] || die "cargo unavailable after tool setup"
    if [ ! -x "$HOME/.cargo/bin/cargo-cinstall" ]; then
        step "installing cargo-c (several minutes)"
        PATH="$HOME/.cargo/bin:$PATH" cargo install cargo-c --locked ||
            die "cargo-c installation failed"
    fi
    [ -x "$HOME/.cargo/bin/cargo-cinstall" ] ||
        die "cargo-c unavailable after tool setup"
    case ":$PATH:" in
    *":$HOME/.cargo/bin:"*) ;;
    *) export PATH="$HOME/.cargo/bin:$PATH" ;;
    esac
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

# libbrotli is a freetype dependency (WOFF2 font support).  The linux
# Dockerfile builds it before freetype, so the macos freetype sees the
# same feature set.
build_libbrotli() {
    skip_if_done libbrotli && return 0
    step "libbrotli"
    cd "$LIW_SRC"
    rm -rf brotli
    git_retry https://github.com/google/brotli.git "v$(v libbrotli)" brotli
    cmake_build "$LIW_SRC/brotli" -DBUILD_TESTING=OFF
    done_stamp libbrotli
}

build_libexpat() {
    skip_if_done libexpat && return 0
    step "libexpat"
    cd "$LIW_SRC"
    rm -rf libexpat
    fetch "https://github.com/libexpat/libexpat/archive/R_$(v libexpat).tar.gz" \
        libexpat.tar.gz
    mkdir libexpat
    tar -zxf libexpat.tar.gz -C libexpat --strip-components 1
    cmake_build "$LIW_SRC/libexpat/expat" \
        -DEXPAT_BUILD_EXAMPLES=OFF -DEXPAT_BUILD_TESTS=OFF
    done_stamp libexpat
}

build_libffi() {
    skip_if_done libffi && return 0
    step "libffi"
    cd "$LIW_SRC"
    rm -rf libffi
    git_retry https://github.com/libffi/libffi.git "v$(v libffi)" libffi
    (
        cd libffi || exit 1
        ./autogen.sh
        ./configure --prefix="$LIW_PREFIX" --disable-static --disable-docs
        make -j "$LIW_JOBS"
        make install
    ) || die "libffi build failed"
    done_stamp libffi
}

# The Dockerfile also builds util-linux (libmount/libblkid) before glib;
# those libraries are Linux-only and glib's meson does not use them on
# darwin, so there is no macos counterpart.
build_glib() {
    skip_if_done glib && return 0
    step "glib"
    cd "$LIW_SRC"
    rm -rf glib
    git_retry https://github.com/GNOME/glib.git "$(v glib)" glib
    # glib's meson needs the packaging module (like the Dockerfile's
    # pip install before glib); run it with the patch python's meson.
    "$LIW_PATCH_PIPBIN" install -q packaging
    # force-fallback-for=libpcre2-8 keeps glib from picking up a foreign
    # pcre2 through meson's cc.find_library fallback (pkg-config is scoped
    # to the prefix, but find_library is not); the pcre2 subproject wrap is
    # built statically into libglib instead.
    meson_build "$LIW_SRC/glib" -Dtests=False -Dglib_debug=disabled \
        --force-fallback-for=libpcre2-8
    done_stamp glib
}

build_sqlite() {
    skip_if_done sqlite && return 0
    step "sqlite"
    cd "$LIW_SRC"
    rm -rf sqlite
    fetch "https://sqlite.org/$(v sqlite 1)/sqlite-autoconf-$(v sqlite 2 . . 1).tar.gz" \
        sqlite.tar.gz
    mkdir sqlite
    tar -zxf sqlite.tar.gz -C sqlite --strip-components 1
    (
        cd sqlite || exit 1
        ./configure --prefix="$LIW_PREFIX" --disable-static --all
        make -j "$LIW_JOBS"
        make install
    ) || die "sqlite build failed"
    done_stamp sqlite
}

build_libxml2() {
    skip_if_done libxml2 && return 0
    step "libxml2"
    cd "$LIW_SRC"
    rm -rf libxml2
    git_retry https://github.com/GNOME/libxml2.git "v$(v libxml2)" libxml2
    # Legacy APIs are kept so rasterlite will still work (as on linux);
    # iconv resolves to the macOS system libiconv in /usr/lib, which the
    # wheel audits allow.
    cmake_build "$LIW_SRC/libxml2" \
        -DLIBXML2_WITH_TESTS=OFF -DLIBXML2_WITH_PYTHON=OFF \
        -DLIBXML2_WITH_ICU=OFF -DLIBXML2_WITH_ICONV=ON \
        -DLIBXML2_WITH_LEGACY=ON -DLIBXML2_WITH_HTTP=ON \
        -DLIBXML2_WITH_DEBUG=OFF -DLIBXML2_WITH_PROGRAMS=OFF
    done_stamp libxml2
}

build_pixman() {
    skip_if_done pixman && return 0
    step "pixman"
    cd "$LIW_SRC"
    rm -rf pixman
    git_retry https://gitlab.freedesktop.org/pixman/pixman.git \
        "pixman-$(v pixman)" pixman
    meson_build "$LIW_SRC/pixman"
    done_stamp pixman
}

build_freetype() {
    skip_if_done freetype && return 0
    step "freetype"
    cd "$LIW_SRC"
    rm -rf freetype
    git_retry https://github.com/freetype/freetype.git \
        "VER-$(v freetype)" freetype
    meson_build "$LIW_SRC/freetype"
    done_stamp freetype
}

build_fontconfig() {
    skip_if_done fontconfig && return 0
    step "fontconfig"
    cd "$LIW_SRC"
    rm -rf fontconfig
    git_retry https://gitlab.freedesktop.org/fontconfig/fontconfig.git \
        "$(v fontconfig)" fontconfig
    # nls disabled: it only adds translated messages (no library feature);
    # without it fontconfig would otherwise pull a foreign libintl through
    # meson's non-pkg-config intl lookup on hosts that have one.
    meson_build "$LIW_SRC/fontconfig" -Ddoc=disabled -Dtests=disabled \
        -Dnls=disabled
    done_stamp fontconfig
}

build_cairo() {
    skip_if_done cairo && return 0
    step "cairo"
    cd "$LIW_SRC"
    rm -rf cairo
    git_retry https://gitlab.freedesktop.org/cairo/cairo.git \
        "$(v cairo)" cairo
    # cairo's meson disables freetype and fontconfig by default on darwin
    # (it prefers CoreText); the linux build has both compiled in, so
    # require them explicitly for feature parity.  The X11 backends are
    # left at auto: with the prefix-scoped pkg-config they are off (the
    # linux build has no X11 either).
    meson_build "$LIW_SRC/cairo" -Dtests=disabled \
        -Dfreetype=enabled -Dfontconfig=enabled
    # Feature assertions: the linux wheel's cairo links freetype,
    # fontconfig, pixman, libpng, and zlib.
    local linked lib
    linked="$(otool -L "$LIW_PREFIX/lib"/libcairo*.dylib 2>/dev/null || true)"
    [ -n "$linked" ] || die "cairo produced no dylib to check"
    for lib in libfreetype libfontconfig libpixman libpng; do
        printf '%s\n' "$linked" | grep -q "$lib" ||
            die "cairo was not linked against $lib; an optional dependency was missed (check the build order)"
    done
    done_stamp cairo
}

# jxrlib is optional in openslide (CZI JXR compression, from the
# iewchen-zeiss-czi-jxr patch).  It is a plain Makefile build; a few
# substitutions are needed on macOS:
#   - newer clang makes this old code's implicit declarations errors by
#     default; the Dockerfile applies the same quieting flags,
#   - the .pc generation step invokes bare `python`, which does not exist
#     in the VM,
#   - the shared-library link rules have no CFLAGS and rely on the Linux
#     behavior of allowing undefined symbols in a .so; the macOS linker
#     rejects that, so -undefined dynamic_lookup restores the Linux
#     semantics (the symbols live in the sibling libjpegxr.so and resolve
#     when both are loaded),
#   - clang's -shared sets the dylib's install name to the output path;
#     give the installed dylibs absolute install names so delocate can
#     rewrite them when bundling.
build_jxrlib() {
    skip_if_done jxrlib && return 0
    step "jxrlib"
    cd "$LIW_SRC"
    rm -rf jxrlib
    git_retry https://github.com/4creators/jxrlib.git "v$(v jxrlib)" jxrlib
    cd jxrlib
    # The VM's sed is BSD sed: -i takes the backup suffix as a separate
    # argument (an empty string here).
    sed -i '' \
        's/CFLAGS=/CFLAGS=-Wno-implicit-function-declaration -Wno-incompatible-pointer-types /g' \
        Makefile
    # The .pc generation rule invokes bare `python` after a leading tab;
    # the VM only has python3.
    sed -i '' 's/@python -c/@python3 -c/' Makefile
    sed -i '' \
        's|$(CC) -shared $? -o $@|$(CC) -shared -Wl,-undefined,dynamic_lookup $? -o $@ -Wl,-install_name,$(DIR_INSTALL)/lib/$(notdir $@)|g' \
        Makefile
    DIR_INSTALL="$LIW_PREFIX" SHARED=1 make -j "$LIW_JOBS" install
    [ -f "$LIW_PREFIX/lib/pkgconfig/libjxr.pc" ] ||
        die "jxrlib did not install its pkg-config file"
    done_stamp jxrlib
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

# bison is a build tool for libmemcached: its configure hardcodes
# YACC='bison --warnings=all', and the CSL parser/scanner it generates are
# compiled into libmemcached itself (options.cc), so a modern bison is
# required -- the CLT's bison is 2.3, which predates --warnings=all.  The
# base VM's Homebrew set has no bison, so build one from source into the
# prefix (no Homebrew re-provision needed).  The version is pinned here
# rather than in versions.txt: versions.txt is shared with the linux
# build and maintained by the version-cron, and the linux container's
# distro bison never needed an entry.  The bison tarball ships a
# pre-generated configure, so no autotools bootstrap is involved.
build_bison() {
    skip_if_done bison && return 0
    step "bison"
    local bison_version=3.8.2
    cd "$LIW_SRC"
    rm -rf bison
    fetch "https://ftp.gnu.org/gnu/bison/bison-$bison_version.tar.gz" \
        bison.tar.gz
    mkdir bison
    tar -zxf bison.tar.gz -C bison --strip-components 1
    (
        cd bison || exit 1
        ./configure --prefix="$LIW_PREFIX" --disable-static || exit 1
        make -j "$LIW_JOBS" || exit 1
        make install || exit 1
    ) || die "bison build failed"
    # bison --version prints "bison (GNU Bison) 3.8.2"; match the version
    # substring rather than the whole line.
    "$LIW_PREFIX/bin/bison" --version | grep -q "$bison_version" ||
        die "bison did not install the expected version"
    done_stamp bison
}

# sasl is required for libmemcached (the Dockerfile's comment): its
# configure only compiles the SASL support in (and defines
# LIBMEMCACHED_WITH_SASL_SUPPORT, which pylibmc's C module keys off) when
# libsasl2 is found.  The linux build enables every mechanism the base
# image supports, including the openssl-backed ones (otp, srp, scram,
# ntlm, passdss) and the openldap-backed ldapdb; the macos VM has neither
# openssl nor openldap inside the isolated prefix, and system copies must
# not be used, so those mechanisms drop out (the last five are explicitly
# disabled).  What survives is the set memcached SASL actually negotiates
# (PLAIN, CRAM-MD5, DIGEST-MD5) plus the self-contained login/anonymous
# pair, sasldb (ndbm via libSystem), and gssapiv2 against the macOS
# system Kerberos framework -- all audit-allowed.
build_cyrus_sasl() {
    skip_if_done cyrus-sasl && return 0
    step "cyrus-sasl"
    cd "$LIW_SRC"
    rm -rf cyrus-sasl
    git_retry https://github.com/cyrusimap/cyrus-sasl.git \
        "cyrus-sasl-$(v cyrus-sasl)" cyrus-sasl
    (
        cd cyrus-sasl || exit 1
        ./autogen.sh
        # Note on the option and flag set:
        #   -std=gnu17 is required: the VM's autoconf (2.72+) probes for the
        #   newest supported C standard and bakes -std=gnu23 into $CC, and
        #   C23 removed K&R function definitions, which cyrus-sasl's md5.c
        #   still uses ("unknown type name 'context'").  Our CFLAGS land
        #   after $CC's flag in every compile command, so the later -std
        #   wins; the flag also makes the C23 probe itself fail, so $CC
        #   stays clean (verified: configure then reports C23 unsupported
        #   and falls through to C11 "none needed").
        #   cyrus-sasl 2.1.28's configure has no --enable-plain (the plain
        #   plugin is always built), so it is not passed.  gssapi
        #   auto-detects and finds the macOS system Kerberos framework (a
        #   /System path the otool audit allows; the linux wheel ships the
        #   gssapiv2 plugin too), so it is left alone.  --disable-macos-
        #   framework is required on darwin -- the macos-framework feature
        #   is enabled by default and its install hook creates
        #   /Library/Frameworks/SASL2.framework symlinks outside the
        #   prefix.  NTLM stays enabled like the Dockerfile: it silently
        #   drops out without an OpenSSL in the prefix (like scram, otp,
        #   srp, and passdss, which are explicitly disabled), and would
        #   light up automatically if one is ever added.
        CFLAGS="$CFLAGS -std=gnu17 -Wno-implicit-function-declaration" \
            ./configure --prefix="$LIW_PREFIX" --disable-static \
            --disable-sample --disable-macos-framework \
            --enable-obsolete_cram_attr --enable-obsolete_digest_attr \
            --enable-alwaystrue --enable-checkapop \
            --enable-cram --enable-digest --enable-anon \
            --enable-login --enable-ntlm \
            --disable-otp --disable-srp --disable-scram --disable-passdss \
            --disable-ldapdb --disable-sql --disable-auth-sasldb
        make -j "$LIW_JOBS"
        make install
    ) || die "cyrus-sasl build failed"
    # Feature assertions: the self-contained mechanisms memcached SASL
    # negotiates must be present as plugins (build_pylibmc bundles them as
    # package data).  libtool names the darwin modules lib<mech>.3.so with
    # an unversioned .so symlink alongside.
    local mech
    for mech in libplain libcrammd5 libdigestmd5 liblogin libanonymous; do
        [ -e "$LIW_PREFIX/lib/sasl2/$mech.so" ] ||
            die "cyrus-sasl did not install the $mech plugin"
    done
    done_stamp cyrus-sasl
}

# libmemcached must be built after cyrus-sasl (see above).  The linux
# build avoids the doc build with a target list instead of plain `make
# install` (docs dominate its build time); the sed before configure keeps
# the install rules from failing on the man pages.
build_libmemcached() {
    skip_if_done libmemcached && return 0
    step "libmemcached"
    cd "$LIW_SRC"
    rm -rf libmemcached
    git_retry https://github.com/memcachier/libmemcached.git \
        "$(v libmemcached)" libmemcached
    (
        cd libmemcached || exit 1
        # memflush.cc compares a char* against false; gcc's -fpermissive
        # downgrades that to a warning on linux, but clang rejects it
        # outright.  NULL is what the comparison means.
        sed -i '' 's/opt_servers == false/opt_servers == NULL/g' \
            clients/memflush.cc
        autoreconf -ifv
        sed -i '' 's/install-man install/install/g' Makefile.in
        # -std=gnu17: autoreconf with the VM's autoconf 2.73 bakes
        # -std=gnu23 into $CC (see build_cyrus_sasl); libmemcached is
        # 2014-era code that has not been audited against C23.
        # ac_cv_have_htonll=no: on macOS the htonll conftest passes (the
        # system headers declare it through the netinet/in.h chain), but
        # byteorder.cc -- which is always compiled and includes no system
        # header that declares it -- would then reference an undeclared
        # ntohll.  On linux the conftest fails and the code takes its
        # swap64 fallback; force the same detection result here (the
        # BUILD_BYTEORDER conditional this feeds is referenced by no
        # build rule).
        # YACC is passed explicitly: configure hardcodes
        # YACC='bison --warnings=all', but the scrubbed PATH has /usr/bin
        # (the CLT's bison 2.3, which predates --warnings=all) ahead of
        # the prefix, so the prefix's bison must be named by absolute
        # path.  flex comes from the CLT and is new enough as-is.
        ac_cv_have_htonll=no \
        CFLAGS="$CFLAGS -std=gnu17" \
        YACC="$LIW_PREFIX/bin/bison --warnings=all" \
        CXXFLAGS="$CXXFLAGS -fpermissive" \
            ./configure --prefix="$LIW_PREFIX" --disable-static
        # This target list does not parallelize reliably; no -j (like the
        # linux build).
        make install-exec install-data install-includeHEADERS \
            install-libLTLIBRARIES install-binPROGRAMS
    ) || die "libmemcached build failed"
    # Feature assertion: without libsasl2 linked in, pylibmc compiles its
    # SASL paths out silently and the wheel would be feature-reduced
    # compared to the linux wheel.
    local linked
    linked="$(otool -L "$LIW_PREFIX/lib"/libmemcached*.dylib 2>/dev/null || true)"
    [ -n "$linked" ] || die "libmemcached produced no dylib to check"
    printf '%s\n' "$linked" | grep -q libsasl2 ||
        die "libmemcached was not linked against libsasl2; SASL support was missed (check the cyrus-sasl build)"
    done_stamp libmemcached
}

# --------------------------------------------------------------------------
# Dependencies for pyvips (libvips and its tree), mirroring the Dockerfile's
# VIPS section and everything else the linux build installs before libvips.
# These were added in stages; each one is also reachable as dep:<name> for
# incremental verification inside a VM.
# --------------------------------------------------------------------------

# lz4 is used by libarchive (and later by gdal/mapnik).
build_lz4() {
    skip_if_done lz4 && return 0
    step "lz4"
    cd "$LIW_SRC"
    rm -rf lz4
    git_retry https://github.com/lz4/lz4.git "v$(v lz4)" lz4
    (
        cd lz4 || exit 1
        # PREFIX must be set at build time, not just install time: lz4's
        # darwin rules bake the install-time libdir into the dylib's
        # install name when it is built (verified on the host: installing
        # with a different PREFIX than the build leaves /usr/local in the
        # install name, which delocate cannot rewrite).
        make PREFIX="$LIW_PREFIX" -j "$LIW_JOBS" || exit 1
        make install PREFIX="$LIW_PREFIX" || exit 1
    ) || die "lz4 build failed"
    # The install name must be absolute so delocate can rewrite bundled
    # copies (sanitize_prefix_dylibs handles rpaths and re-signing later).
    local name
    name="$(otool -D "$LIW_PREFIX/lib/liblz4.1.dylib" 2>/dev/null | sed -n 2p)"
    case "$name" in
    "$LIW_PREFIX"/*) ;;
    *) die "liblz4's install name is not absolute ('$name')" ;;
    esac
    done_stamp lz4
}

build_orc() {
    skip_if_done orc && return 0
    step "orc"
    cd "$LIW_SRC"
    rm -rf orc
    fetch "https://github.com/GStreamer/orc/archive/$(v orc).tar.gz" orc.tar.gz
    mkdir orc
    tar -zxf orc.tar.gz -C orc --strip-components 1
    meson_build "$LIW_SRC/orc" -Dtests=disabled -Dexamples=disabled \
        -Dbenchmarks=disabled
    [ -e "$LIW_PREFIX/lib/liborc-0.4.dylib" ] ||
        die "orc did not install liborc-0.4"
    done_stamp orc
}

build_nifti() {
    skip_if_done nifti && return 0
    step "nifti"
    cd "$LIW_SRC"
    rm -rf nifti
    git_retry https://github.com/NIFTI-Imaging/nifti_clib.git \
        "v$(v nifti)" nifti
    cmake_build "$LIW_SRC/nifti" -DBUILD_SHARED_LIBS=ON
    [ -n "$(ls "$LIW_PREFIX/lib"/libnifti*.dylib 2>/dev/null)" ] ||
        die "nifti did not install its libraries"
    done_stamp nifti
}

# The arm64 branch of the Dockerfile's fftw configure: the x86 SIMD options
# are accepted but inert on aarch64, where fftw's cmake picks its NEON
# support by itself.
build_fftw3() {
    skip_if_done fftw3 && return 0
    step "fftw3"
    cd "$LIW_SRC"
    rm -rf fftw3
    fetch "https://fftw.org/pub/fftw/fftw-$(v fftw3).tar.gz" fftw3.tar.gz
    mkdir fftw3
    tar -zxf fftw3.tar.gz -C fftw3 --strip-components 1
    cmake_build "$LIW_SRC/fftw3" -DBUILD_TESTS=OFF -DENABLE_AVX=ON \
        -DENABLE_AVX2=ON -DENABLE_SSE=ON -DENABLE_SSE2=ON -DENABLE_THREADS=ON \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    [ -n "$(ls "$LIW_PREFIX/lib"/libfftw3*.dylib 2>/dev/null)" ] ||
        die "fftw3 did not install its libraries"
    done_stamp fftw3
}

build_libhwy() {
    skip_if_done libhwy && return 0
    step "libhwy"
    cd "$LIW_SRC"
    rm -rf highway
    git_retry https://github.com/google/highway.git "$(v libhwy)" highway
    # The CXX_FLAGS value overrides the cache variable that cmake derives
    # from the environment, so keep our flags in front of the seed pin.
    cmake_build "$LIW_SRC/highway" -DBUILD_TESTING=OFF \
        -DHWY_ENABLE_EXAMPLES=OFF -DBUILD_SHARED_LIBS=ON \
        -DCMAKE_CXX_FLAGS="$CXXFLAGS -DVQSORT_SECURE_SEED=0"
    [ -n "$(ls "$LIW_PREFIX/lib"/libhwy*.dylib 2>/dev/null)" ] ||
        die "libhwy did not install its library"
    done_stamp libhwy
}

build_jpegxl() {
    skip_if_done jpeg-xl && return 0
    step "jpeg-xl (libjxl)"
    cd "$LIW_SRC"
    rm -rf libjxl
    # libjxl's third_party libraries (highway, brotli, ...) are git
    # submodules, so the clone needs --recurse-submodules like the
    # Dockerfile's.  git_retry has no provision for extra clone options,
    # so the retry loop is inline here.
    local n=0
    until git clone --depth=1 --single-branch -b "v$(v jpeg-xl)" \
        -c advice.detachedHead=false --recurse-submodules -j "$LIW_JOBS" \
        https://github.com/libjxl/libjxl.git libjxl; do
        n=$((n + 1))
        [ "$n" -ge 10 ] &&
            die "git clone failed after $n attempts: libjxl (v$(v jpeg-xl))"
        echo "retrying git clone: https://github.com/libjxl/libjxl.git"
        sleep 5
    done
    # Remove the .git directories (as the Dockerfile does) so libjxl's
    # version detection uses its fallback version instead of a git
    # describe of the shallow clone.
    (cd libjxl && find . -name '.git' -exec rm -rf {} +) 2>/dev/null || true
    # libhwy is installed into the prefix before this runs; with it found,
    # -DHWY_ENABLE_INSTALL=OFF keeps libjxl from installing its vendored
    # copy over ours (same as the linux build).  brotli comes from the
    # libbrotli builder.
    cmake_build "$LIW_SRC/libjxl" \
        -DBUILD_TESTING=OFF \
        -DCMAKE_CXX_FLAGS="$CXXFLAGS -fpermissive" \
        -DJPEGXL_ENABLE_EXAMPLES=OFF \
        -DJPEGXL_ENABLE_MANPAGES=OFF \
        -DJPEGXL_ENABLE_BENCHMARK=OFF \
        -DHWY_ENABLE_INSTALL=OFF \
        -DHWY_ENABLE_TESTS=OFF \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    # Feature assertion: libjxl links brotli dynamically.  Highway is NOT
    # asserted: libjxl's third_party/CMakeLists.txt sets
    # HWY_FORCE_STATIC_LIBS and, because the --recurse-submodules clone
    # (same as the Dockerfile) provides the vendored highway, libjxl
    # builds and statically embeds it instead of linking the prefix's
    # libhwy -- the linux build behaves identically, so the prefix's
    # libhwy is only there to mirror the Dockerfile's final state.
    local linked lib
    linked="$(otool -L "$LIW_PREFIX/lib"/libjxl*.dylib 2>/dev/null || true)"
    [ -n "$linked" ] || die "jpeg-xl produced no dylib to check"
    for lib in libbrotli; do
        printf '%s\n' "$linked" | grep -q "$lib" ||
            die "libjxl was not linked against $lib; an optional dependency was missed (check the build order)"
    done
    done_stamp jpeg-xl
}

# libimagequant 4.x builds through cargo-c (the Dockerfile installs cargo-c
# and runs `cargo cinstall` in this directory; the macos variant points the
# install at the private prefix).  Rust is provisioned by ensure_rust.
build_libimagequant() {
    skip_if_done libimagequant && return 0
    step "libimagequant"
    ensure_rust
    cd "$LIW_SRC"
    rm -rf libimagequant
    git_retry https://github.com/ImageOptim/libimagequant.git \
        "$(v libimagequant)" libimagequant
    (
        cd libimagequant/imagequant-sys || exit 1
        cargo cinstall --prefix="$LIW_PREFIX" --libdir="$LIW_PREFIX/lib" || exit 1
        # rust leaves huge build artifacts that are not useful to us (the
        # Dockerfile does the same cleanup).
        rm -rf target/release/deps || true
        find . -name '*.a' -delete || true
    ) || die "libimagequant build failed"
    [ -n "$(ls "$LIW_PREFIX/lib"/libimagequant*.dylib 2>/dev/null)" ] ||
        die "libimagequant did not install its library"
    done_stamp libimagequant
}

build_libexif() {
    skip_if_done libexif && return 0
    step "libexif"
    cd "$LIW_SRC"
    rm -rf libexif
    # Use the release tarball, not a git clone: the tarball ships a
    # pre-generated configure, and libexif's configure.ac cannot be
    # re-generated in the VM -- its NLS machinery (AM_PO_SUBDIRS,
    # AM_GNU_GETTEXT, AM_ICONV) needs gettext's m4 macros and autopoint,
    # which the VM deliberately does not have (the linux build gets them
    # from its gettext-devel package).  NLS only adds translated
    # messages, so it is disabled -- the same reasoning as fontconfig's
    # -Dnls=disabled; the linux dylib gets NLS from glibc's gettext, not
    # a bundled library.  Verified on the host: configure/build/install
    # with --disable-nls produce a dylib linked only against libSystem.
    fetch "https://github.com/libexif/libexif/releases/download/v$(v libexif)/libexif-$(v libexif).tar.gz" \
        libexif.tar.gz
    mkdir libexif
    tar -zxf libexif.tar.gz -C libexif --strip-components 1
    (
        cd libexif || exit 1
        ./configure --prefix="$LIW_PREFIX" --disable-static \
            --disable-nls || exit 1
        make -j "$LIW_JOBS" || exit 1
        make install || exit 1
    ) || die "libexif build failed"
    [ -e "$LIW_PREFIX/lib/libexif.dylib" ] ||
        die "libexif did not install its library"
    done_stamp libexif
}

build_libarchive() {
    skip_if_done libarchive && return 0
    step "libarchive"
    cd "$LIW_SRC"
    rm -rf libarchive
    git_retry https://github.com/libarchive/libarchive.git \
        "v$(v libarchive)" libarchive
    # zlib, zstd, lzma (xz), and lz4 are found in the prefix; bzip2
    # resolves to the macOS system libbz2 in /usr/lib, which the otool
    # audits allow.
    cmake_build "$LIW_SRC/libarchive" -DBUILD_TESTING=OFF \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    # Feature assertions: the formats the linux wheel's libarchive carries
    # through our prefix libraries (gzip, zstd, xz, lz4).
    local linked lib
    linked="$(otool -L "$LIW_PREFIX/lib"/libarchive*.dylib 2>/dev/null || true)"
    [ -n "$linked" ] || die "libarchive produced no dylib to check"
    for lib in "libz." libzstd liblzma liblz4; do
        printf '%s\n' "$linked" | grep -q "$lib" ||
            die "libarchive was not linked against $lib; an optional dependency was missed (check the build order)"
    done
    done_stamp libarchive
}

build_libraw() {
    skip_if_done libraw && return 0
    step "libraw"
    cd "$LIW_SRC"
    rm -rf LibRaw
    git_retry https://github.com/LibRaw/LibRaw.git "$(v libraw)" LibRaw
    (
        cd LibRaw || exit 1
        autoreconf -ifv || exit 1
        ./configure --prefix="$LIW_PREFIX" --disable-static || exit 1
        make -j "$LIW_JOBS" || exit 1
        make install || exit 1
    ) || die "libraw build failed"
    [ -n "$(ls "$LIW_PREFIX/lib"/libraw*.dylib 2>/dev/null)" ] ||
        die "libraw did not install its library"
    done_stamp libraw
}

# --------------------------------------------------------------------------
# Dependencies for pyvips, stage 2 (harfbuzz through imagemagick), mirroring
# the Dockerfile's remaining VIPS-tree sections.  Like stage 1, each one is
# also reachable as dep:<name> for staged verification inside a VM; the
# pyvips case is not wired until the whole tree has been verified.
# --------------------------------------------------------------------------

build_harfbuzz() {
    skip_if_done harfbuzz && return 0
    step "harfbuzz"
    cd "$LIW_SRC"
    rm -rf harfbuzz
    git_retry https://github.com/harfbuzz/harfbuzz.git "$(v harfbuzz)" harfbuzz
    (
        cd harfbuzz || exit 1
        # Mirrors the Dockerfile's sed; at 14.6.0 the script already uses
        # /usr/bin/env python3, so this is a no-op kept for parity.
        sed -i '' 's!/usr/bin/python3!/usr/bin/env python3!g' \
            src/relative_to.py || exit 1
    ) || die "harfbuzz patch failed"
    meson_build "$LIW_SRC/harfbuzz" -Dtests=disabled -Ddocs=disabled
    # Feature assertions: glib and freetype are installed before this runs
    # (the openslide chain), so harfbuzz's auto features must light up the
    # same way they do on linux.  cairo is only linked by the separate
    # harfbuzz-cairo library, not by libharfbuzz itself.
    local linked lib
    linked="$(otool -L "$LIW_PREFIX/lib"/libharfbuzz*.dylib 2>/dev/null || true)"
    [ -n "$linked" ] || die "harfbuzz produced no dylib to check"
    for lib in libfreetype libglib; do
        printf '%s\n' "$linked" | grep -q "$lib" ||
            die "harfbuzz was not linked against $lib; an optional dependency was missed (check the build order)"
    done
    done_stamp harfbuzz
}

build_pango() {
    skip_if_done pango && return 0
    step "pango"
    cd "$LIW_SRC"
    rm -rf pango
    git_retry https://github.com/GNOME/pango.git "$(v pango)" pango
    # fribidi is a hard dependency that nothing in the prefix provides:
    # force pango's own subproject wrap (meson's default wrap mode allows
    # the fallback, like glib's pcre2) so it is built statically into
    # libpango rather than risking a Homebrew leak through meson's cmake
    # fallback method.
    meson_build "$LIW_SRC/pango" -Dintrospection=disabled \
        --force-fallback-for=fribidi
    # Feature assertions: freetype, fontconfig, cairo, glib, and harfbuzz
    # are all installed before this runs, so the pangoft2 and pangocairo
    # variants (what librsvg and libvips consume) must exist and link the
    # prefix libraries.
    for lib in pango pangocairo pangoft2; do
        [ -e "$LIW_PREFIX/lib/lib$lib-1.0.0.dylib" ] ||
            die "pango did not install lib$lib-1.0.0.dylib"
    done
    local linked lib
    linked="$(otool -L "$LIW_PREFIX/lib"/libpangoft2-1.0.0.dylib \
        "$LIW_PREFIX/lib"/libpangocairo-1.0.0.dylib 2>/dev/null || true)"
    [ -n "$linked" ] || die "pango produced no dylibs to check"
    for lib in libharfbuzz libfreetype libcairo; do
        printf '%s\n' "$linked" | grep -q "$lib" ||
            die "pango was not linked against $lib; an optional dependency was missed (check the build order)"
    done
    done_stamp pango
}

build_librsvg() {
    skip_if_done librsvg && return 0
    step "librsvg"
    ensure_rust
    cd "$LIW_SRC"
    rm -rf librsvg
    git_retry https://github.com/GNOME/librsvg.git "$(v librsvg)" librsvg
    (
        cd librsvg || exit 1
        # Make the output dylib much smaller (mirrors the Dockerfile).
        printf '\n[profile.release]\nlto = true\n' >> Cargo.toml || exit 1
    ) || die "librsvg patch failed"
    # The Dockerfile's LDFLAGS addition (--no-as-needed,-ldl) and the
    # makedef.py sed are linux/PE specifics and are not applied here.
    # gdk-pixbuf is not built in either pipeline; its auto feature must
    # drop out rather than pulling the subproject wrap, so it is disabled
    # explicitly.
    meson_build "$LIW_SRC/librsvg" -Dintrospection=disabled -Ddocs=disabled \
        -Dtests=false -Dpixbuf=disabled
    [ -n "$(ls "$LIW_PREFIX/lib"/librsvg-2*.dylib 2>/dev/null)" ] ||
        die "librsvg did not install its library"
    local linked lib
    linked="$(otool -L "$LIW_PREFIX/lib"/librsvg-2*.dylib 2>/dev/null || true)"
    [ -n "$linked" ] || die "librsvg produced no dylib to check"
    for lib in libcairo libpango libglib libxml2; do
        printf '%s\n' "$linked" | grep -q "$lib" ||
            die "librsvg was not linked against $lib; an optional dependency was missed (check the build order)"
    done
    done_stamp librsvg
}

build_libde265() {
    skip_if_done libde265 && return 0
    step "libde265"
    cd "$LIW_SRC"
    rm -rf libde265
    git_retry https://github.com/strukturag/libde265.git \
        "v$(v libde265)" libde265
    # The Dockerfile's -DBUILD_SHARED/-DBUILD_STATIC do not exist as
    # options at this version (its CMakeLists only has BUILD_SHARED_LIBS,
    # which defaults to ON), so the shared library is left to the default
    # and the inert flags are not passed here.
    cmake_build "$LIW_SRC/libde265" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_CXX_FLAGS="$CXXFLAGS -pthread" \
        -DCMAKE_EXE_LINKER_FLAGS=-pthread \
        -DENABLE_SDL=OFF
    [ -n "$(ls "$LIW_PREFIX/lib"/libde265*.dylib 2>/dev/null)" ] ||
        die "libde265 did not install its library"
    done_stamp libde265
}

build_libheif() {
    skip_if_done libheif && return 0
    step "libheif"
    cd "$LIW_SRC"
    rm -rf libheif
    git_retry https://github.com/strukturag/libheif.git "v$(v libheif)" libheif
    cmake_build "$LIW_SRC/libheif" -DCMAKE_BUILD_TYPE=Release
    # Feature assertion: libde265 is the HEVC decoder the linux wheel
    # carries (the other codec plugins are absent on linux too).
    local linked lib
    linked="$(otool -L "$LIW_PREFIX/lib"/libheif*.dylib 2>/dev/null || true)"
    [ -n "$linked" ] || die "libheif produced no dylib to check"
    for lib in libde265; do
        printf '%s\n' "$linked" | grep -q "$lib" ||
            die "libheif was not linked against $lib; an optional dependency was missed (check the build order)"
    done
    done_stamp libheif
}

build_poppler() {
    skip_if_done poppler && return 0
    step "poppler"
    cd "$LIW_SRC"
    rm -rf poppler
    git_retry https://gitlab.freedesktop.org/poppler/poppler.git \
        "poppler-$(v poppler)" poppler
    # The Dockerfile's devtoolset block is linux-only.  NSS and GPGME are
    # disabled like on linux.  Boost is disabled: nothing in the macos
    # prefix provides it yet (it is a splash-performance option and links
    # nothing into the dylibs; revisit when boost is built for
    # mapnik/GDAL).  libcurl resolves to the macOS system libcurl in
    # /usr/lib, which the otool audits allow, matching the linux build
    # where poppler links the image's own curl.
    cmake_build "$LIW_SRC/poppler" \
        -DCMAKE_BUILD_TYPE=Release \
        -DENABLE_UNSTABLE_API_ABI_HEADERS=on \
        -DBUILD_CPP_TESTS=OFF -DBUILD_GTK_TESTS=OFF \
        -DBUILD_MANUAL_TESTS=OFF -DBUILD_QT5_TESTS=OFF -DBUILD_QT6_TESTS=OFF \
        -DENABLE_NSS3=OFF -DENABLE_GPGME=OFF -DENABLE_QT5=OFF -DENABLE_QT6=OFF \
        -DENABLE_BOOST=OFF
    [ -n "$(ls "$LIW_PREFIX/lib"/libpoppler*.dylib 2>/dev/null)" ] ||
        die "poppler did not install its libraries"
    # Feature assertions over the union of the poppler libraries: freetype,
    # jpeg, png, and openjpeg are the prefix-provided format features the
    # linux wheel carries (tiff is linked by the tiff-writing utils).
    local linked lib
    linked="$(otool -L "$LIW_PREFIX/lib"/libpoppler*.dylib 2>/dev/null || true)"
    [ -n "$linked" ] || die "poppler produced no dylib to check"
    for lib in libfreetype libjpeg libpng libopenjp; do
        printf '%s\n' "$linked" | grep -q "$lib" ||
            die "poppler was not linked against $lib; an optional dependency was missed (check the build order)"
    done
    done_stamp poppler
}

build_fitsio() {
    skip_if_done fitsio && return 0
    step "cfitsio"
    cd "$LIW_SRC"
    rm -rf cfitsio
    git_retry https://github.com/HEASARC/cfitsio.git \
        "cfitsio-$(v fitsio)" cfitsio
    cmake_build "$LIW_SRC/cfitsio" -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    [ -n "$(ls "$LIW_PREFIX/lib"/libcfitsio*.dylib 2>/dev/null)" ] ||
        die "cfitsio did not install its library"
    done_stamp fitsio
}

build_hdf5() {
    skip_if_done hdf5 && return 0
    step "hdf5"
    cd "$LIW_SRC"
    rm -rf hdf5
    git_retry https://github.com/HDFGroup/hdf5.git "hdf5-$(v hdf5)" hdf5
    # The Dockerfile's MPI-dependent options (HDF5_ENABLE_PARALLEL and the
    # MPI_* variables) are dropped: the macos prefix has no MPI (parallel
    # netcdf is a GDAL-stage concern and will need an MPI built into the
    # prefix).  HDF5_ENABLE_DIRECT_VFD is linux-only (O_DIRECT).
    cmake_build "$LIW_SRC/hdf5" \
        -DDEFAULT_API_VERSION=v18 \
        -DHDF5_BUILD_EXAMPLES=OFF \
        -DHDF5_BUILD_FORTRAN=OFF \
        -DHDF5_ENABLE_Z_LIB_SUPPORT=ON \
        -DHDF5_BUILD_GENERATORS=ON \
        -DHDF5_BUILD_CPP_LIB=ON \
        -DHDF5_DISABLE_COMPILER_WARNINGS=ON \
        -DBUILD_TESTING=OFF \
        -DZLIB_DIR="$LIW_PREFIX/lib" \
        -DHDF5_BUILD_DOC=OFF \
        -DALLOW_UNSUPPORTED=ON \
        -DHDF5_ENABLE_THREADSAFE=ON
    [ -n "$(ls "$LIW_PREFIX/lib"/libhdf5*.dylib 2>/dev/null)" ] ||
        die "hdf5 did not install its library"
    local linked lib
    linked="$(otool -L "$LIW_PREFIX/lib"/libhdf5*.dylib 2>/dev/null || true)"
    [ -n "$linked" ] || die "hdf5 produced no dylib to check"
    for lib in "libz." ; do
        printf '%s\n' "$linked" | grep -q "$lib" ||
            die "hdf5 was not linked against $lib; Z_LIB_SUPPORT was not enabled"
    done
    done_stamp hdf5
}

build_matio() {
    skip_if_done matio && return 0
    step "matio"
    cd "$LIW_SRC"
    rm -rf matio
    git_retry https://github.com/tbeu/matio.git "v$(v matio)" matio
    cmake_build "$LIW_SRC/matio" -DCMAKE_BUILD_TYPE=MinSizeRel
    # matio's own matio.pc does not carry the version or the correct libdir
    # (the Dockerfile overwrites it as well), so write one that points at
    # the private prefix; libvips resolves matio through pkg-config.
    cat > "$LIW_PREFIX/lib/pkgconfig/matio.pc" <<EOF
Name: matio
Description: matio library
Version: $(v matio)
Cflags: -I$LIW_PREFIX/include
Libs: -L$LIW_PREFIX/lib -lmatio
EOF
    [ -n "$(ls "$LIW_PREFIX/lib"/libmatio*.dylib 2>/dev/null)" ] ||
        die "matio did not install its library"
    local linked lib
    linked="$(otool -L "$LIW_PREFIX/lib"/libmatio*.dylib 2>/dev/null || true)"
    [ -n "$linked" ] || die "matio produced no dylib to check"
    for lib in libhdf5; do
        printf '%s\n' "$linked" | grep -q "$lib" ||
            die "matio was not linked against $lib; hdf5 was not found (check the build order)"
    done
    done_stamp matio
}

build_openexr() {
    skip_if_done openexr && return 0
    step "openexr"
    cd "$LIW_SRC"
    rm -rf openexr
    git_retry https://github.com/AcademySoftwareFoundation/openexr.git \
        "v$(v openexr)" openexr
    # The Imath submodule is not cloned (the Dockerfile's plain clone does
    # not recurse either); openexr's cmake fetches Imath at configure time
    # using OPENEXR_IMATH_TAG.
    cmake_build "$LIW_SRC/openexr" \
        -DBUILD_TESTING=OFF \
        -DOPENEXR_BUILD_EXAMPLES=OFF \
        -DOPENEXR_IMATH_TAG=v3.2.1
    [ -n "$(ls "$LIW_PREFIX/lib"/libOpenEXR*.dylib 2>/dev/null)" ] ||
        die "openexr did not install its libraries"
    local linked lib
    linked="$(otool -L "$LIW_PREFIX/lib"/libOpenEXR*.dylib 2>/dev/null || true)"
    [ -n "$linked" ] || die "openexr produced no dylib to check"
    for lib in "libz." ; do
        printf '%s\n' "$linked" | grep -q "$lib" ||
            die "openexr was not linked against $lib; zlib was not found"
    done
    done_stamp openexr
}

build_imagemagick() {
    skip_if_done imagemagick && return 0
    step "imagemagick"
    cd "$LIW_SRC"
    rm -rf ImageMagick
    git_retry https://github.com/ImageMagick/ImageMagick.git \
        "$(v imagemagick)" ImageMagick
    (
        cd ImageMagick || exit 1
        # The linux LIBS adds -lrt, which does not exist on darwin; zlib is
        # resolved through the prefix's pkgconf like on linux.  Built after
        # librsvg so --with-rsvg finds it (and after the whole dependency
        # tree so every delegate configure can detect lights up).
        ./configure --prefix="$LIW_PREFIX" --with-modules --with-rsvg \
            --with-fftw --with-jxl \
            LIBS="$("$PKG_CONFIG" --libs zlib)" \
            --disable-static || exit 1
        make -j "$LIW_JOBS" || exit 1
        make install || exit 1
    ) || die "imagemagick build failed"
    [ -n "$(ls "$LIW_PREFIX/lib"/libMagickCore*.dylib 2>/dev/null)" ] ||
        die "imagemagick did not install libMagickCore"
    [ -n "$(ls "$LIW_PREFIX/lib"/libMagickWand*.dylib 2>/dev/null)" ] ||
        die "imagemagick did not install libMagickWand"
    # --with-modules builds the coders as loadable modules (like on
    # linux); the prefix's modules directory must be populated.  The wheel
    # itself ships only the libraries, exactly like the linux wheel.
    [ -n "$(ls "$LIW_PREFIX/lib"/ImageMagick-*/modules-MagickCore/coders/ 2>/dev/null)" ] ||
        die "imagemagick built no coder modules"
    # Feature assertions on the core library: the delegates compiled into
    # MagickCore itself (annotate's freetype/fontconfig, lcms color
    # management, xml2).  The coder delegates (png, jpeg, heif, jxl, ...)
    # live in the module dylibs, not the core.
    local linked lib
    linked="$(otool -L "$LIW_PREFIX/lib"/libMagickCore*.dylib 2>/dev/null || true)"
    [ -n "$linked" ] || die "imagemagick produced no dylib to check"
    for lib in libfreetype libfontconfig libxml2 "libz."; do
        printf '%s\n' "$linked" | grep -q "$lib" ||
            die "libMagickCore was not linked against $lib; an optional dependency was missed (check the build order)"
    done
    done_stamp imagemagick
}

# libvips is a meson build with all loaders compiled in (-Dmodules=disabled,
# like the Dockerfile); every optional loader the linux wheel carries must
# resolve through the prefix's pkg-config, which the feature assertions
# below check rather than trusting configure's silence.
build_libvips() {
    skip_if_done libvips && return 0
    step "libvips"
    cd "$LIW_SRC"
    rm -rf libvips
    git_retry https://github.com/libvips/libvips.git "v$(v libvips)" libvips
    (
        cd libvips || exit 1
        # Mirrors the Dockerfile's seds: allow using VIPS_TMPDIR for the
        # temp directory, disable HAVE_TARGET_CLONES (ifunc, linux-only;
        # clang would otherwise accept the attribute but produce no
        # dispatching), and silence the tiff2vips g_logv warnings the
        # linux build silences.
        sed -i '' \
            's/tmpd;/tmpd;if ((tmpd=g_getenv("VIPS_TMPDIR"))) return(tmpd);/g' \
            libvips/iofuncs/util.c || exit 1
        sed -i '' \
            "s|cfg_var.set('HAVE_TARGET_CLONES',|# cfg_var.set('HAVE_TARGET_CLONES',|g" \
            meson.build || exit 1
        sed -i '' \
            's/g_logv("tiff2vips", G_LOG_LEVEL_WARNING, fmt, ap);/\/\/g_logv("tiff2vips", G_LOG_LEVEL_WARNING, fmt, ap);/g' \
            libvips/foreign/tiff2vips.c || exit 1
        sed -i '' \
            's/g_logv(G_LOG_DOMAIN, G_LOG_LEVEL_WARNING, fmt, ap);/\/\/g_logv(G_LOG_DOMAIN, G_LOG_LEVEL_WARNING, fmt, ap);/g' \
            libvips/foreign/tiff2vips.c || exit 1
    ) || die "libvips patch failed"
    # The Dockerfile's LDFLAGS addition (,-rpath,$ORIGIN -lstdc++) is
    # linux-specific (the rpath is what auditwheel rewrites; the C++
    # runtime is implicit on darwin) and is not applied here.
    meson_build "$LIW_SRC/libvips" -Dmodules=disabled -Dexamples=false \
        -Dnifti-prefix-dir="$LIW_PREFIX"
    [ -n "$(ls "$LIW_PREFIX/lib"/libvips*.dylib 2>/dev/null)" ] ||
        die "libvips did not install its library"
    # Feature assertions over the union of the installed libvips dylibs:
    # every loader library the linux wheel links must have resolved from
    # the prefix.  (libhwy enters through libjxl and hdf5 through matio;
    # only direct linkage is asserted here.)
    local linked lib
    linked="$(otool -L "$LIW_PREFIX/lib"/libvips*.dylib 2>/dev/null || true)"
    [ -n "$linked" ] || die "libvips produced no dylib to check"
    for lib in libgobject openslide MagickCore libheif libjxl libjpeg \
        libtiff libpng libwebp librsvg libpoppler libcfitsio libmatio \
        nifti libarchive libraw libopenjp libexif liborc fftw lcms \
        imagequant pangocairo; do
        printf '%s\n' "$linked" | grep -q "$lib" ||
            die "libvips was not linked against $lib; an optional dependency was missed (check the build order)"
    done
    done_stamp libvips
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

build_openslide() {
    skip_if_done openslide && return 0
    step "openslide"
    cd "$LIW_SRC"
    rm -rf openslide
    # Full clone: the pinned version is a commit sha (versions.txt
    # openslide-sha), which a --depth=1 clone cannot contain.
    git_retry https://github.com/openslide/openslide.git "" openslide
    (
        cd openslide || exit 1
        git checkout -q "$(v openslide-sha)"
        # The same two patches the linux build applies; they live at the
        # repository root and are copied into the VM with it.
        git am "$LIW_REPO/openslide-iewchen-zeiss-czi-jxr.patch" || exit 1
        git am "$LIW_REPO/openslide-vendor-mirax.c.patch" || exit 1
    ) || die "openslide patches failed"
    meson_build "$LIW_SRC/openslide" -Dtest=disabled -Ddoc=disabled
    # Feature assertions: everything below is either a required dependency
    # (a missing one fails the configure step anyway) or an optional one the
    # linux wheel links and whose absence would otherwise be silent (jxr is
    # optional in the zeiss-czi-jxr patch; sqlite, cairo, xml, glib, jpeg,
    # png, tiff, and openjpeg are hard requirements).  libdicom arrives via
    # openslide's own meson subproject wrap (like the linux build) and is
    # linked statically, so it has no otool entry.
    local linked lib
    linked="$(otool -L "$LIW_PREFIX/lib"/libopenslide*.dylib 2>/dev/null || true)"
    [ -n "$linked" ] || die "openslide produced no dylib to check"
    for lib in libcairo libglib libgobject libsqlite3 libxml2 libjxrglue \
        libjpegxr libpng libtiff libopenjp2 libjpeg; do
        printf '%s\n' "$linked" | grep -q "$lib" ||
            die "openslide was not linked against $lib; an optional dependency was missed (check the build order)"
    done
    done_stamp openslide
}

build_openslide_python() {
    skip_if_done openslide_python && return 0
    step "openslide_python"
    local pp="$LIW_PATCH_PYBIN"

    # Dependencies may have just been built (fresh VM); strip any build-tree
    # RPATHs they installed before the wheels bundle them.
    sanitize_prefix_dylibs

    cd "$LIW_SRC"
    rm -rf openslide-python
    # Master, like the linux build (the last release tag is stale).
    git_retry https://github.com/openslide/openslide-python.git "" openslide-python
    cd openslide-python

    # Bundle the openslide command line tools with the wheel, like the
    # linux build does: slidetool plus its symlinked entry points, copied
    # dereferenced from the prefix.
    mkdir -p openslide/bin
    local f base
    while IFS= read -r f; do
        base="$(basename "$f")"
        if [ -f "$LIW_PREFIX/bin/$base" ]; then
            cp -L "$LIW_PREFIX/bin/$base" openslide/bin/
        fi
    done < <(find "$LIW_SRC/openslide/_build/tools" -perm -111 \! -type d)
    [ -n "$(ls openslide/bin)" ] || die "no openslide tools found to bundle"
    strip -x openslide/bin/* 2>/dev/null || true
    # cmake/meson-installed executables keep build-tree RPATHs (e.g. to
    # $LIW_PREFIX/lib).  delocate's rpath sanitizer only processes files
    # that require other libraries, so strip every non-@ RPATH and re-sign
    # (arm64 requires a valid signature after install_name_tool).
    local rp
    while IFS= read -r -d '' f; do
        while IFS= read -r rp; do
            case "$rp" in
            @loader_path/* | @executable_path/* | @rpath/*) ;;
            *) install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null || true ;;
            esac
        done < <(otool -l "$f" |
            awk '/LC_RPATH/{inr=1; next} inr && $1=="path" {print $2; inr=0}')
        codesign -f -s - "$f" 2>/dev/null || true
    done < <(find openslide/bin -type f -perm -111 -print0)

    # Wrapper module so each bundled tool is exposed as a console script.
    cat >openslide/bin/__init__.py <<'EOF'
import os
import sys

def program():
    path = os.path.join(os.path.dirname(__file__), os.path.basename(sys.argv[0]))
    os.execv(path, sys.argv)
EOF

    # Patch lowlevel.py so it finds the bundled libopenslide dylib.
    # delocate puts bundled dylibs in openslide/.dylibs inside the wheel;
    # keep the auditwheel-style openslide_python.libs location from the
    # linux build as a fallback so the patch stays comparable across
    # platforms.  The bundled lookup must run before the openslide-bin
    # import: on macos pypi publishes openslide-bin wheels, and
    # large-image[openslide] installs one into every test venv -- its
    # libopenslide is unpatched upstream (no flattened-MIRAX support), so
    # letting it win silently replaced our library in the shared test
    # suite's venvs (on linux there is no aarch64 openslide-bin wheel, so
    # the linux build never hit this).
    cat >"$LIW_PATCHES/openslide_python_lowlevel.py" <<'EOF'
path = "openslide/lowlevel.py"
s = open(path).read()
s = s.replace(
    """def _load_library() -> CDLL:
    try:
        import openslide_bin

        return openslide_bin.libopenslide1
    except (AttributeError, ModuleNotFoundError):
        pass
""",
    """def _load_library() -> CDLL:
    # A wheel built by the large_image wheels pipeline bundles
    # libopenslide (delocate puts it in openslide/.dylibs); look there
    # before the openslide-bin wheel or any system-installed copy.  This
    # must come first: on macos pypi publishes openslide-bin wheels and
    # large-image[openslide] installs one, but its library is unpatched
    # upstream (no flattened-MIRAX support), so letting it win would
    # silently replace our library.  Keep the auditwheel-style
    # openslide_python.libs location from the linux build as a fallback.
    libpath = os.path.abspath(os.path.join(os.path.dirname(os.path.realpath(
        __file__)), ".dylibs"))
    if not os.path.exists(libpath):
        libpath = os.path.abspath(os.path.join(os.path.dirname(os.path.dirname(
            os.path.realpath(__file__))), "openslide_python.libs"))
    if os.path.exists(libpath):
        try:
            lib = [lib for lib in os.listdir(libpath)
                if lib.startswith('libopenslide')][0]
            return cdll.LoadLibrary(os.path.join(libpath, lib))
        except (IndexError, OSError):
            pass

    try:
        import openslide_bin

        return openslide_bin.libopenslide1
    except (AttributeError, ModuleNotFoundError):
        pass
""")
open(path, "w").write(s)
EOF
    # Patch setup.py: link _convert against libopenslide in the private
    # prefix (the include path comes through CFLAGS at wheel-build time).
    cat >"$LIW_PATCHES/openslide_python_setup.py" <<'EOF'
import os
path = "setup.py"
s = open(path).read()
s = s.replace(
    "            ['openslide/_convert.c'],",
    "            ['openslide/_convert.c'],\n"
    "            libraries=['openslide'],\n"
    "            library_dirs=['%s']," % os.path.join(os.environ["LIW_PREFIX"], "lib"))
open(path, "w").write(s)
EOF
    # Add the local build suffix to the version, matching the linux wheel
    # versioning (openslide-python 1.4.6.1).
    cat >"$LIW_PATCHES/openslide_python_version.py" <<'EOF'
import re
path = "openslide/_version.py"
s = open(path).read()
s = re.sub(r"(__version__ = '[^']*)'", r"\1.1'", s)
open(path, "w").write(s)
EOF
    # Patch pyproject.toml: include the bundled tools as package data and
    # expose them as console scripts.
    cat >"$LIW_PATCHES/openslide_python_pyproject.py" <<'EOF'
import os
path = "pyproject.toml"
s = open(path).read()
s = s.replace('openslide = ["py.typed", "*.pyi"]',
    'openslide = ["py.typed", "*.pyi", "bin/*"]')
s += "\n[project.scripts]\n" + "".join(
    "%s = 'openslide.bin:program'\n" % name for name in os.listdir("openslide/bin")
    if not name.endswith(".py"))
open(path, "w").write(s)
EOF
    "$pp" "$LIW_PATCHES/openslide_python_lowlevel.py"
    "$pp" "$LIW_PATCHES/openslide_python_setup.py"
    "$pp" "$LIW_PATCHES/openslide_python_version.py"
    "$pp" "$LIW_PATCHES/openslide_python_pyproject.py"

    # Commit the patches and tag with the combined version (the patched
    # package version), matching the linux wheel versioning.
    git config user.email "wheels@example.com"
    git config user.name "Wheel Builder"
    git add -A
    git commit -q -m "patch for wheel building"
    git tag "$(v openslide-python).1"

    # Build one wheel for 3.11 (abi3, covering 3.11-3.15) and for each
    # requested free-threaded python (their own tags); this mirrors the
    # linux build, which excludes non-abi3 duplicate pythons above 3.11.
    # The gil check for _abi3 is already in upstream setup.py.
    collect_pybins
    local pybin kept=() ver
    for pybin in ${PYBINS[@]+"${PYBINS[@]}"}; do
        ver="$(basename "$(dirname "$pybin")")"
        case "$ver" in
        3.11* | *t) kept+=("$pybin") ;;
        esac
    done
    [ "${#kept[@]}" -gt 0 ] || die "no pythons selected for the openslide-python wheels"
    for pybin in ${kept[@]+"${kept[@]}"}; do
        step "openslide_python wheel: $(basename "$(dirname "$pybin")")"
        (
            cd "$LIW_SRC/openslide-python"
            rm -rf build
            # The extension's include path comes through CFLAGS (the sysconfig
            # data was scrubbed of Homebrew entries, so ours is authoritative).
            CFLAGS="$CFLAGS -I$LIW_PREFIX/include" \
                "$pybin/python" -m pip wheel --no-deps -w "$LIW_WHEELHOUSE" .
        ) || die "openslide_python wheel build failed for $pybin"
    done

    step "delocate openslide_python wheels"
    "$LIW_PATCH_PIPBIN" install -q -U delocate
    local whl
    for whl in "$LIW_WHEELHOUSE"/openslide_python-*.whl; do
        [ -f "$whl" ] || continue
        case "$(basename "$whl")" in
        *macosx*) "$LIW_PATCH_DIR/bin/delocate-wheel" "$whl" ||
            die "delocate failed for $whl" ;;
        esac
    done
    ls -l "$LIW_WHEELHOUSE"
    [ -n "$(ls "$LIW_WHEELHOUSE"/openslide_python-*macosx*.whl 2>/dev/null)" ] ||
        die "no openslide_python macosx wheels were built"
    done_stamp openslide_python
}

build_pylibmc() {
    skip_if_done pylibmc && return 0
    step "pylibmc"
    local pp="$LIW_PATCH_PYBIN"

    # Dependencies may have just been built (fresh VM); strip any build-tree
    # RPATHs they installed before the wheels bundle them.
    sanitize_prefix_dylibs

    cd "$LIW_SRC"
    rm -rf pylibmc
    git_retry https://github.com/lericson/pylibmc.git "$(v pylibmc)" pylibmc
    cd pylibmc

    # Some tags carry a -dev suffix in the version header; strip it (the
    # Dockerfile's same edit).
    sed -i '' 's/-dev//g' src/pylibmc-version.h

    # Bundle the sasl2 client-side plugins with the wheel, like the linux
    # build does: libsasl2 dlopens every file in the directory named by
    # the SASL_PATH environment variable, which the patched __init__.py
    # points at this copy inside the package.  Versioned module names
    # (linux libplain.so.2.0.25, darwin libplain.3.so) are normalized to
    # the unversioned plugin names the linux wheel ships, so the
    # unversioned symlink and the versioned real file collapse into one
    # file per mechanism.
    mkdir -p src/pylibmc/sasl2
    local f base rp
    while IFS= read -r f; do
        base="$(basename "$f" | sed -E 's/\.(dylib|so)\..*//; s/\.[0-9]+\.(so|dylib)$/.so/')"
        case "$base" in
        *.so) ;;
        *) base="$base.so" ;;
        esac
        cp -L "$f" "src/pylibmc/sasl2/$base"
    done < <(find "$LIW_PREFIX/lib/sasl2" \
        \( -name '*.so' -o -name '*.so.*' -o -name '*.dylib' \) 2>/dev/null)
    [ -n "$(ls src/pylibmc/sasl2)" ] || die "no sasl2 plugins found to bundle"
    strip -x src/pylibmc/sasl2/* 2>/dev/null || true
    # libtool-installed modules can carry build-tree RPATHs (e.g. to
    # $LIW_PREFIX/lib); delocate's rpath sanitizer only processes files
    # that require other libraries, so strip every non-@ RPATH and re-sign
    # (arm64 requires a valid signature after install_name_tool).
    while IFS= read -r -d '' f; do
        while IFS= read -r rp; do
            case "$rp" in
            @loader_path/* | @executable_path/* | @rpath/*) ;;
            *) install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null || true ;;
            esac
        done < <(otool -l "$f" |
            awk '/LC_RPATH/{inr=1; next} inr && $1=="path" {print $2; inr=0}')
        codesign -f -s - "$f" 2>/dev/null || true
    done < <(find src/pylibmc/sasl2 -type f -print0)

    # Patch setup.py: link sasl2 (the Dockerfile's --with-sasl2
    # equivalent), include the bundled plugins as package data, link
    # against the private prefix's lib dir (the linux build relies on
    # /usr/local being the default search path; the scrubbed sysconfig
    # data makes ours authoritative), and add the local build suffix to
    # the version, matching the linux wheel versioning (pylibmc-1.6.3.1).
    cat >"$LIW_PATCHES/pylibmc_setup.py" <<'EOF'
import os
path = "setup.py"
s = open(path).read()
s = s.replace('libs = ["memcached"]', 'libs = ["memcached", "sasl2"]')
s = s.replace("packages=['pylibmc'],",
    "packages=['pylibmc'], "
    "package_data={'pylibmc': ['sasl2/*']}, include_package_data=True,")
s = s.replace("library_dirs=libdirs,",
    "library_dirs=libdirs + [os.path.join(os.environ['LIW_PREFIX'], 'lib')],")
s = s.replace("version=version,", 'version=version + ".1",')
open(path, "w").write(s)
EOF
    cat >"$LIW_PATCHES/pylibmc_init.py" <<'EOF'
# Point SASL_PATH at the bundled plugin copy before _pylibmc (and thus
# libsasl2) is imported, so a clean install finds the plugins without a
# system sasl2 directory.  The linux wheels do the same.
path = "src/pylibmc/__init__.py"
s = open(path).read()
s = s.replace(
    "import _pylibmc",
    """import os
_localpath = os.path.dirname(os.path.abspath(__file__))
os.environ.setdefault("SASL_PATH", os.path.join(_localpath, "sasl2"))

import _pylibmc""")
open(path, "w").write(s)
EOF
    "$pp" "$LIW_PATCHES/pylibmc_setup.py"
    "$pp" "$LIW_PATCHES/pylibmc_init.py"

    # Commit the patches and tag with the combined version (the patched
    # package version), matching the linux wheel versioning.
    git config user.email "wheels@example.com"
    git config user.name "Wheel Builder"
    git add -A
    git commit -q -m "patch for wheel building"
    git tag "$(v pylibmc).1"

    # Build one wheel per python (a plain C extension, no stable ABI), then
    # bundle the dylibs with delocate (the auditwheel equivalent on macOS).
    collect_pybins
    local pybin
    for pybin in "${PYBINS[@]}"; do
        step "pylibmc wheel: $(basename "$(dirname "$pybin")")"
        (
            cd "$LIW_SRC/pylibmc"
            rm -rf build
            # The extension's include path comes through CFLAGS (the sysconfig
            # data was scrubbed of Homebrew entries, so ours is authoritative).
            CFLAGS="$CFLAGS -I$LIW_PREFIX/include" \
                "$pybin/python" -m pip wheel --no-deps -w "$LIW_WHEELHOUSE" .
        ) || die "pylibmc wheel build failed for $pybin"
    done

    step "delocate pylibmc wheels"
    "$LIW_PATCH_PIPBIN" install -q -U delocate
    local whl
    for whl in "$LIW_WHEELHOUSE"/pylibmc-*.whl; do
        [ -f "$whl" ] || continue
        case "$(basename "$whl")" in
        *macosx*) "$LIW_PATCH_DIR/bin/delocate-wheel" "$whl" ||
            die "delocate failed for $whl" ;;
        esac
    done
    ls -l "$LIW_WHEELHOUSE"
    [ -n "$(ls "$LIW_WHEELHOUSE"/pylibmc-*macosx*.whl 2>/dev/null)" ] ||
        die "no pylibmc macosx wheels were built"
    # Feature assertions on the wheel: the extension must have pulled in
    # libmemcached and libsasl2 (delocate puts the dylibs in
    # pylibmc/.dylibs -- the pylibmc package is the wheel's only directory),
    # and the sasl2 plugins must be bundled as package data.
    local contents
    contents="$(unzip -l "$(ls "$LIW_WHEELHOUSE"/pylibmc-*macosx*.whl | head -1)")"
    printf '%s\n' "$contents" | grep -q 'pylibmc/.dylibs/libmemcached' ||
        die "the pylibmc wheel does not bundle libmemcached"
    printf '%s\n' "$contents" | grep -q 'pylibmc/.dylibs/libsasl2' ||
        die "the pylibmc wheel does not bundle libsasl2"
    printf '%s\n' "$contents" | grep -q 'pylibmc/sasl2/.*\.so' ||
        die "the pylibmc wheel does not bundle the sasl2 plugins"
    done_stamp pylibmc
}

# The pyvips wheel bundles libvips and its whole dependency tree, plus the
# bundled vips tools and magick in pyvips/bin, exactly like the linux wheel.
build_pyvips() {
    skip_if_done pyvips && return 0
    step "pyvips"
    local pp="$LIW_PATCH_PYBIN"

    # Dependencies may have just been built (fresh VM); strip any build-tree
    # RPATHs they installed before the wheels bundle them.
    sanitize_prefix_dylibs

    cd "$LIW_SRC"
    rm -rf pyvips
    git_retry https://github.com/libvips/pyvips.git "v$(v pyvips)" pyvips
    cd pyvips

    # Bundle the vips command-line tools and magick with the wheel, like
    # the linux build does (meson puts the tools in the build directory;
    # magick comes from the prefix install).
    mkdir -p pyvips/bin
    find "$LIW_SRC/libvips/_build/tools" -type f -perm -111 \
        -exec cp {} pyvips/bin/ \;
    cp -L "$LIW_PREFIX/bin/magick" pyvips/bin/
    [ -e pyvips/bin/vips ] || die "no vips tool found to bundle"
    [ -e pyvips/bin/magick ] || die "no magick tool found to bundle"
    strip -x pyvips/bin/* 2>/dev/null || true

    # Wrapper module so each bundled tool is exposed as a console script
    # (same wrapper the linux wheel ships).
    cat >pyvips/bin/__init__.py <<'EOF'
import os
import sys

def program():
    path = os.path.join(os.path.dirname(__file__), os.path.basename(sys.argv[0]))
    os.execv(path, sys.argv)
EOF

    # Patch __init__.py: preload the bundled libvips dylib before the
    # extension is imported (delocate puts the bundled dylibs in
    # pyvips/.dylibs inside the wheel; keep the auditwheel-style locations
    # from the linux build as fallbacks).
    cat >"$LIW_PATCHES/pyvips_init.py" <<EOF
path = "pyvips/__init__.py"
s = open(path).read().replace(
"""    import _libvips""",
"""    import ctypes
    import os
    # delocate puts the bundled dylibs in pyvips/.dylibs inside the wheel;
    # keep the auditwheel-style locations from the linux build as fallbacks.
    libpath = os.path.join(os.path.dirname(os.path.realpath(__file__)), ".dylibs")
    if not os.path.exists(libpath):
        libpath = os.path.abspath(os.path.join(os.path.dirname(os.path.dirname(
            os.path.realpath(__file__))), "pyvips.libs"))
    if os.path.exists(libpath):
        libs = os.listdir(libpath)
        libvipspath = [lib for lib in libs if lib.startswith('libvips')]
        if libvipspath:
            ctypes.cdll.LoadLibrary(os.path.join(libpath, libvipspath[0]))
    from . import _libvips""")
open(path, "w").write(s)
EOF
    # Patch pyvips_build.py: name the cffi extension pyvips._libvips so the
    # patched `from . import _libvips` resolves to it.
    cat >"$LIW_PATCHES/pyvips_build.py" <<EOF
path = "pyvips/pyvips_build.py"
s = open(path).read().replace(
"""ffibuilder.set_source("_libvips",""",
"""ffibuilder.set_source("pyvips._libvips",""")
open(path, "w").write(s)
EOF
    # Patch version.py with the combined version (package version + bundled
    # libvips version), matching the linux wheel versioning.
    cat >"$LIW_PATCHES/pyvips_version.py" <<EOF
import re
path = "pyvips/version.py"
s = open(path).read()
s = re.sub(r'__version__ = "(.+?)"',
           lambda match: '__version__ = "%s.$(v libvips)"' % match.group(1), s)
open(path, "w").write(s)
EOF
    # Patch setup.py and pyproject.toml: expose the bundled tools as console
    # scripts and include them as package data.  On pyvips 3.2.0 the
    # setup.py replaces are no-ops (its setup.py has no packages= line; the
    # linux build carries the same inert patches), so the effective changes
    # come from the pyproject.toml patch.
    cat >"$LIW_PATCHES/pyvips_setup.py" <<EOF
path = "setup.py"
s = open(path).read().replace("from os import path",
"""from os import path
import os""").replace(
"""packages=pyvips_packages,""",
"""packages=pyvips_packages,
        include_package_data=True,
        package_data={'pyvips': ['bin/*']},
        entry_points={'console_scripts': ['%s=pyvips.bin:program' % name for name in os.listdir('pyvips/bin') if not name.endswith('.py')]},""")
open(path, "w").write(s)
EOF
    cat >"$LIW_PATCHES/pyvips_pyproject.py" <<EOF
path = "pyproject.toml"
s = open(path).read()
s = s.replace("include-package-data = false", "include-package-data = true")
s += """
[tool.setuptools.package-data]
pyvips = ["bin/*"]

[project.scripts]
"""
import os
for name in os.listdir('pyvips/bin'):
    if not name.endswith('.py'):
        s += "%s = 'pyvips.bin:program'\\n" % name
open(path, "w").write(s)
EOF
    "$pp" "$LIW_PATCHES/pyvips_init.py"
    "$pp" "$LIW_PATCHES/pyvips_build.py"
    "$pp" "$LIW_PATCHES/pyvips_version.py"
    "$pp" "$LIW_PATCHES/pyvips_setup.py"
    "$pp" "$LIW_PATCHES/pyvips_pyproject.py"

    # Commit the patches and tag with the combined version (package version
    # + bundled libvips version), matching the linux wheel versioning.
    git config user.email "wheels@example.com"
    git config user.name "Wheel Builder"
    git add -A
    git commit -q -m "patch for wheel building"
    git tag "$(v pyvips).$(v libvips)"

    # Build one wheel per python, then bundle the dylibs with delocate
    # (the auditwheel equivalent on macOS).  The cffi build resolves
    # libvips through the prefix's pkg-config (the pkgconfig python
    # package honors PKG_CONFIG and PKG_CONFIG_LIBDIR).
    collect_pybins
    local pybin
    for pybin in "${PYBINS[@]}"; do
        step "pyvips wheel: $(basename "$(dirname "$pybin")")"
        (
            cd "$LIW_SRC/pyvips"
            rm -rf build
            "${pybin}/python" -m pip wheel --no-deps -w "$LIW_WHEELHOUSE" .
        ) || die "pyvips wheel build failed for $pybin"
    done

    step "delocate pyvips wheels"
    "$LIW_PATCH_PIPBIN" install -q -U delocate
    local whl
    for whl in "$LIW_WHEELHOUSE"/pyvips-*.whl; do
        [ -f "$whl" ] || continue
        case "$(basename "$whl")" in
        *macosx*) "$LIW_PATCH_DIR/bin/delocate-wheel" "$whl" ||
            die "delocate failed for $whl" ;;
        esac
    done
    ls -l "$LIW_WHEELHOUSE"
    [ -n "$(ls "$LIW_WHEELHOUSE"/pyvips-*macosx*.whl 2>/dev/null)" ] ||
        die "no pyvips macosx wheels were built"
    # Feature assertions on the wheel: the bundled libvips dylib, the cffi
    # extension, and the tools must be present (delocate puts the dylibs in
    # pyvips/.dylibs -- the pyvips package is the wheel's only directory).
    local contents
    contents="$(unzip -l "$(ls "$LIW_WHEELHOUSE"/pyvips-*macosx*.whl | head -1)")"
    printf '%s\n' "$contents" | grep -q 'pyvips/.dylibs/libvips' ||
        die "the pyvips wheel does not bundle libvips"
    printf '%s\n' "$contents" | grep -q 'pyvips/_libvips' ||
        die "the pyvips wheel does not contain the cffi extension"
    printf '%s\n' "$contents" | grep -q 'pyvips/bin/vips' ||
        die "the pyvips wheel does not bundle the vips tool"
    printf '%s\n' "$contents" | grep -q 'pyvips/bin/magick' ||
        die "the pyvips wheel does not bundle the magick tool"
    done_stamp pyvips
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
ensure_meson
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
[ "${#PACKAGES[@]}" -eq 0 ] && PACKAGES=(pylibtiff glymur openslide_python pylibmc pyvips)

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
    openslide_python)
        # Order mirrors the Dockerfile's final state: openjpeg must see
        # lcms2/libpng/libtiff (same as glymur); libbrotli must exist before
        # freetype; expat before fontconfig; pixman/freetype/fontconfig
        # before cairo; jxrlib before openslide.  openslide's meson silently
        # drops what is missing, and build_openslide asserts the linked set.
        build_libtiff_deps
        build_lcms2
        build_libpng
        build_openjpeg
        build_libbrotli
        build_libexpat
        build_libffi
        build_glib
        build_sqlite
        build_libxml2
        build_pixman
        build_freetype
        build_fontconfig
        build_cairo
        build_jxrlib
        build_openslide
        build_openslide_python
        ;;
    pylibmc)
        # Order mirrors the Dockerfile: cyrus-sasl must exist before
        # libmemcached's configure detects it ("sasl is required for
        # libmemcached"), and zlib is built first so that the extension's
        # -lz and libmemcached's optional compression resolve to our
        # library rather than the system copy.  bison is a libmemcached
        # build tool only (see build_bison).
        build_zlib
        build_bison
        build_cyrus_sasl
        build_libmemcached
        build_pylibmc
        ;;
    pyvips)
        # Order mirrors the Dockerfile's final state: the openslide chain
        # first (libvips links openslide like any other loader, and its
        # glib/cairo/freetype/fontconfig/xml2 are shared with harfbuzz,
        # pango, and librsvg), then the leaf dependencies, then the pango
        # stack (harfbuzz before pango before librsvg), heif after
        # libde265, matio after hdf5, and imagemagick after librsvg so
        # --with-rsvg finds it.  libvips's meson silently drops what is
        # missing; build_libvips asserts the linked feature set.
        build_libtiff_deps
        build_lcms2
        build_libpng
        build_openjpeg
        build_libbrotli
        build_libexpat
        build_libffi
        build_glib
        build_sqlite
        build_libxml2
        build_pixman
        build_freetype
        build_fontconfig
        build_cairo
        build_jxrlib
        build_openslide
        build_orc
        build_nifti
        build_lz4
        build_fftw3
        build_libhwy
        build_jpegxl
        build_libimagequant
        build_libexif
        build_libarchive
        build_libraw
        build_harfbuzz
        build_libde265
        build_libheif
        build_poppler
        build_fitsio
        build_hdf5
        build_matio
        build_openexr
        build_pango
        build_librsvg
        build_imagemagick
        build_libvips
        build_pyvips
        ;;
    # "dep:<name>" builds a single dependency; useful for debugging.
    # Hyphenated names map to their underscored builders (the stamps keep
    # the hyphenated versions.txt names).
    dep:jpeg-xl)
        build_jpegxl || die "building jpeg-xl failed"
        ;;
    dep:libjpeg-turbo)
        build_libjpeg_turbo || die "building libjpeg-turbo failed"
        ;;
    dep:*)
        "build_${pkg#dep:}" || die "building $pkg failed"
        ;;
    *)
        die "unknown package: $pkg"
        ;;
    esac
done

step "all done; wheels in $LIW_WHEELHOUSE"
