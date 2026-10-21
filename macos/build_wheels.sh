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

# Normalize the install names (ids) of a set of prefix dylibs to absolute
# $LIW_PREFIX/lib paths and rewrite load commands inside the group that
# referenced an old id.  Some build systems install dylibs whose install
# name is not an absolute prefix path (OpenSSL's makefile records a
# relative "lib/libcrypto.*", boost's b2 records the bare file name); a
# consumer linking such a dylib records an unresolvable reference, and
# after sanitize_prefix_dylibs strips the prefix rpaths nothing can resolve
# it -- delocate then fails long after the offending build (the hdf5
# @rpath lesson).  Call this right after a build whose install names are
# suspect and BEFORE any consumer links the dylibs.  Re-signs afterwards
# (arm64 requires a valid signature after install_name_tool).
fix_dylib_ids() { # fix_dylib_ids <dylib>...
    local f id base i
    local -a files=() oldids=() newpaths=()
    for f in "$@"; do
        [ -f "$f" ] || continue
        [ -L "$f" ] && continue
        id="$(otool -D "$f" 2>/dev/null | sed -n 2p)"
        [ -n "$id" ] || continue
        files+=("$f")
        case "$id" in
        "$LIW_PREFIX"/*) continue ;;
        esac
        base="${id##*/}"
        install_name_tool -id "$LIW_PREFIX/lib/$base" "$f" ||
            die "install_name_tool -id failed for $f"
        oldids+=("$id")
        newpaths+=("$LIW_PREFIX/lib/$base")
    done
    [ "${#oldids[@]}" -gt 0 ] || return 0
    for f in ${files[@]+"${files[@]}"}; do
        for i in ${!oldids[@]}; do
            # A failed -change only means the load command is not present
            # (a dylib does not resolve itself through its own old id, and
            # files whose id was already absolute may still reference a
            # sibling by that sibling's old id).
            install_name_tool -change "${oldids[$i]}" "${newpaths[$i]}" "$f" 2>/dev/null || true
        done
        codesign -f -s - "$f" 2>/dev/null || true
    done
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
        # The install step's output is filtered through grep to drop
        # fontconfig's known install-time noise: its cache-build script
        # runs `fc-cache -s -f -v`, which floods the log with ~25k
        # "invalid cache file" lines plus thousands of 0-font "caching"
        # and "skipping, looped directory" lines (see the README's
        # fontconfig note).  The patterns are exclusive to that output;
        # nothing else in the tree emits them.  grep exits 1 when every
        # line is filtered out, which is not an error, so ninja's real
        # status is taken from PIPESTATUS[0] (bash 3.2-compatible).
        ninja -C _build install 2>&1 |
            grep -v -e ': invalid cache file: ' \
                -e ': skipping, looped directory detected' \
                -e ': caching, new cache contents: 0 fonts,'
        [ "${PIPESTATUS[0]}" -eq 0 ] || exit 1
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

# git-lfs is a build tool: GDAL's PublicDecompWT external project clones
# a GitLab repository whose .gitattributes LFS-marks test-data/**, so
# git requires the lfs filter process for the clone (the linux base
# image supplies git-lfs the same way).  Provisioned with the brew
# tools; ensure_git_lfs bootstraps it on base VMs provisioned before
# that change (the ensure_rust precedent).  The scrubbed PATH must be
# able to resolve the filter command, so the binary is symlinked into
# the private prefix like the other Homebrew build tools.
ensure_git_lfs() {
    local brew_prefix
    if [ -x /opt/homebrew/bin/brew ]; then
        brew_prefix=/opt/homebrew
    elif [ -x /usr/local/bin/brew ]; then
        brew_prefix=/usr/local
    else
        die "Homebrew not found; cannot install git-lfs"
    fi
    if [ ! -x "$brew_prefix/bin/git-lfs" ]; then
        step "installing git-lfs (build tool for GDAL's PublicDecompWT clone)"
        "$brew_prefix/bin/brew" install -q git-lfs ||
            die "git-lfs installation failed"
    fi
    [ -x "$brew_prefix/bin/git-lfs" ] ||
        die "git-lfs unavailable after tool setup"
    ln -sf "$brew_prefix/bin/git-lfs" "$LIW_PREFIX/bin/git-lfs"
    # The VM's git already carries filter.lfs.* config (the clone failure
    # proves git tried to run the filter); make sure it stays configured
    # for fresh bases, and confirm the binary actually runs.
    if ! /usr/bin/git config --global filter.lfs.process >/dev/null 2>&1; then
        "$LIW_PREFIX/bin/git-lfs" install --skip-repo >/dev/null 2>&1 || true
    fi
    "$LIW_PREFIX/bin/git-lfs" version >/dev/null 2>&1 ||
        die "git-lfs does not run (PATH/config problem)"
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
    meson_build "$LIW_SRC/harfbuzz" -Dtests=disabled -Ddocs=disabled \
        -Dcoretext=enabled
    # -Dcoretext=enabled: harfbuzz's coretext feature defaults to disabled
    # even on darwin, but pango's macOS build requires it -- its
    # HAVE_CORE_TEXT probe (a CoreText link test) always succeeds on
    # darwin, there is no pango option to skip the resulting
    # pangocoretext.c sources, and they include <hb-coretext.h> from
    # harfbuzz.  The linux wheel has no CoreText shaper; this is a
    # darwin-only addition.  The linkage lands as the CoreText (plus
    # CoreFoundation/CoreGraphics) system frameworks, not the
    # ApplicationServices umbrella harfbuzz's meson requests: the modern
    # linker resolves the umbrella's symbols from its sub-frameworks and
    # records those instead (verified on the host).  All are /System
    # frameworks, which the otool audits allow.
    # Feature assertions: glib and freetype are installed before this runs
    # (the openslide chain), so harfbuzz's auto features must light up the
    # same way they do on linux; CoreText must be linked because pango
    # needs the coretext API it provides.  cairo is only linked by the
    # separate harfbuzz-cairo library, not by libharfbuzz itself.
    local linked lib
    linked="$(otool -L "$LIW_PREFIX/lib"/libharfbuzz*.dylib 2>/dev/null || true)"
    [ -n "$linked" ] || die "harfbuzz produced no dylib to check"
    for lib in libfreetype libglib CoreText; do
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
    # fallback method.  -Dfontconfig=enabled mirrors build_cairo: pango
    # disables fontconfig by default on darwin (it prefers CoreText,
    # like cairo does), but the linux wheel's pango builds pangoft2
    # (fontconfig is required on linux), and pangocairo's cairo-freetype
    # font backend needs it -- without the flag this build silently
    # produced no libpangoft2 at all.
    meson_build "$LIW_SRC/pango" -Dintrospection=disabled \
        -Dfontconfig=enabled \
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
    for lib in libharfbuzz libfreetype libfontconfig libcairo; do
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

# Used by ImageMagick's zip coder/archive support (the linux build has
# libzip installed long before imagemagick configures).
build_libzip() {
    skip_if_done libzip && return 0
    step "libzip"
    cd "$LIW_SRC"
    rm -rf libzip
    git_retry https://github.com/nih-at/libzip.git "v$(v libzip)" libzip
    cmake_build "$LIW_SRC/libzip" -DBUILD_EXAMPLES=OFF
    [ -n "$(ls "$LIW_PREFIX/lib"/libzip*.dylib 2>/dev/null)" ] ||
        die "libzip did not install its library"
    done_stamp libzip
}

# The Dockerfile builds its own curl so that libcurl.pc exists for other
# packages' pkg-config lookups -- on macOS poppler-glib.pc's
# "Requires.private: libcurl" cannot resolve the system libcurl (it ships
# no .pc file), which made meson treat the whole poppler-glib dependency
# as missing and silently dropped libvips's pdf loader.
build_curl() {
    skip_if_done curl && return 0
    step "curl"
    cd "$LIW_SRC"
    rm -rf curl
    # The Dockerfile uses the github release tarball (its headers are
    # slightly different from the git tag); the tag carries underscores
    # while the tarball name carries dots (the Dockerfile's getver.py
    # field trick).
    ver="$(v curl)"
    fetch "https://github.com/curl/curl/releases/download/curl-${ver}/curl-$(printf '%s' "$ver" | tr _ .).tar.gz" \
        curl.tar.gz
    mkdir curl
    tar -zxf curl.tar.gz -C curl --strip-components 1
    # The one remaining deviation from the Dockerfile: the linux base image
    # has libpsl, the isolated prefix does not, so psl support is disabled
    # (whether a prefix libpsl is worth building is an open question).
    # TLS is enabled through the prefix's OpenSSL, which build_openssl
    # installs before this in the cases that build curl.  The first curl
    # build passed -DCURL_ENABLE_SSL=OFF because the VM had no OpenSSL at
    # all (curl's cmake hard-requires a TLS backend); that deviation is
    # gone now that OpenSSL is part of the prefix -- the linux final state
    # is a TLS curl.  CURL_CA_FALLBACK mirrors the Dockerfile; LDAP
    # resolves to the system LDAP.framework, which the audits allow.
    cmake_build "$LIW_SRC/curl" \
        -DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF -DBUILD_STATIC=OFF \
        -DCURL_CA_FALLBACK=ON \
        -DBUILD_LIBCURL_DOCS=OFF -DBUILD_MISC_DOCS=OFF \
        -DCURL_USE_LIBPSL=OFF
    [ -e "$LIW_PREFIX/lib/pkgconfig/libcurl.pc" ] ||
        die "curl did not install its libcurl.pc"
    [ -n "$(ls "$LIW_PREFIX/lib"/libcurl*.dylib 2>/dev/null)" ] ||
        die "curl did not install its library"
    # Feature assertion: with OpenSSL in the prefix, curl must have picked
    # it up; a silently TLS-less curl would only show up as failures in
    # https-dependent tests (the shared suite's vsicurl step).
    local linked
    linked="$(otool -L "$LIW_PREFIX/lib"/libcurl*.dylib 2>/dev/null || true)"
    printf '%s\n' "$linked" | grep -q libssl ||
        die "libcurl was not linked against libssl; TLS was not enabled (build_openssl must run before build_curl)"
    done_stamp curl
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
    # mapnik/GDAL).  libcurl comes from the prefix's own curl build (see
    # build_curl): poppler-glib.pc's "Requires.private: libcurl" cannot
    # resolve the system libcurl, which made pkg-config fail the whole
    # poppler-glib lookup.
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
    for lib in libfreetype libjpeg libpng libopenjp libcurl; do
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
    # -DHDF5_BUILD_WITH_INSTALL_NAME=ON: hdf5's HDFMacros.cmake hardcodes
    # CMAKE_INSTALL_NAME_DIR to @rpath on Apple, overriding the
    # -DCMAKE_INSTALL_NAME_DIR that cmake_build passes, so its dylibs
    # would install with an @rpath install name; consumers (matio) then
    # record "@rpath/libhdf5.310.dylib" with nothing to resolve it
    # against once sanitize_prefix_dylibs strips the prefix rpaths before
    # wheel building -- delocate failed the first pyvips wheel with
    # "Could not find all dependencies" on exactly that
    # (@rpath/libhdf5.310.dylib, requested by libmatio).  hdf5's own
    # option sets each library's INSTALL_NAME_DIR to
    # ${CMAKE_INSTALL_PREFIX}/lib, so hdf5 behaves like every other
    # cmake project here and the exported HDF5Config.cmake records an
    # absolute soname for its consumers.
    # HDF5_ENABLE_PARALLEL mirrors the Dockerfile (parallel netcdf needs a
    # parallel hdf5; the Dockerfile runs with parallel and threadsafe both
    # on, ALLOW_UNSUPPORTED already covers the combination): build_openmpi
    # runs first in every case that builds hdf5.  The linux build's
    # MPI_C_HEADER_DIR hint is not passed: FindMPI resolves everything it
    # needs from the prefix's mpicc on macOS.
    # HDF5_ENABLE_DIRECT_VFD is linux-only (O_DIRECT).
    #
    # ZLIB_LIBRARIES/ZLIB_INCLUDE_DIR must be preset: hdf5's
    # CMakeFilters.cmake first runs a CONFIG-mode
    # find_package(ZLIB ... COMPONENTS static shared), which silently
    # succeeds against the cmake-built zlib's ZLIBConfig.cmake in the
    # prefix -- but that config only defines imported targets, not the
    # ZLIB_LIBRARIES/ZLIB_INCLUDE_DIR variables hdf5's filter code
    # consumes (it assumes module-mode FindZLIB).  The deflate filter is
    # then compiled with H5_HAVE_FILTER_DEFLATE while nothing links zlib,
    # and the macOS linker rejects the undefined inflate/compress2
    # symbols (the linux linker tolerates them, which is why the
    # Dockerfile gets away with it).  Presetting the module variables is
    # harmless when the config find is skipped and repairs it when it is
    # not (verified on the host: the shared-library link line then
    # carries the prefix's libz.dylib).
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
        -DZLIB_LIBRARIES="$LIW_PREFIX/lib/libz.dylib" \
        -DZLIB_INCLUDE_DIR="$LIW_PREFIX/include" \
        -DHDF5_BUILD_DOC=OFF \
        -DALLOW_UNSUPPORTED=ON \
        -DHDF5_ENABLE_THREADSAFE=ON \
        -DHDF5_BUILD_WITH_INSTALL_NAME=ON \
        -DHDF5_ENABLE_PARALLEL=ON \
        -DMPI_C_COMPILER="$LIW_PREFIX/bin/mpicc" \
        -DMPI_mpi_LIBRARY="$LIW_PREFIX/lib/libmpi.dylib" \
        -DMPI_C_LIB_NAMES=mpi
    # The install name must be absolute so delocate can rewrite the
    # bundled copies and consumers record an absolute dependency name
    # (the same check build_lz4 makes for the same reason).
    local name
    name="$(otool -D "$LIW_PREFIX/lib/libhdf5.310.dylib" 2>/dev/null | sed -n 2p)"
    case "$name" in
    "$LIW_PREFIX"/*) ;;
    *) die "libhdf5's install name is not absolute ('$name')" ;;
    esac
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
    # CMAKE_BUILD_WITH_INSTALL_NAME_DIR must be ON (the hdf4/geos lesson:
    # with modern cmake the build-tree install names are @rpath regardless
    # of CMAKE_INSTALL_NAME_DIR, and openexr builds several sibling dylibs
    # in one tree -- libOpenEXR links Iex/IlmThread/Imath in-tree, and the
    # gdal wheel bundles all of them; without this, libOpenEXR records
    # @rpath references that stop resolving once the prefix RPATHs are
    # stripped and delocate fails.  OpenEXR sets no INSTALL_NAME_DIR of
    # its own, so the property comes from cmake_build's variable.
    # Verified on the host against 3.5.2: without the flag libOpenEXR's
    # Iex/IlmThread/Imath references are @rpath; with it the id and all
    # three references are absolute.
    cmake_build "$LIW_SRC/openexr" \
        -DBUILD_TESTING=OFF \
        -DOPENEXR_BUILD_EXAMPLES=OFF \
        -DOPENEXR_IMATH_TAG=v3.2.1 \
        -DCMAKE_BUILD_WITH_INSTALL_NAME_DIR=ON
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
        # tree so every delegate configure check lights up).
        #
        # --without-modules is a deliberate deviation: --with-modules needs
        # libltdl (present in the linux base image, absent here), and the
        # dlopened coder modules are never bundled into a wheel by either
        # delocate or auditwheel -- the linux wheel ships a MagickCore whose
        # coders cannot load at runtime.  With --without-modules every
        # coder is compiled into libMagickCore, so the bundled dylib is
        # fully functional and the whole delegate feature set becomes
        # assertable on the core library's own linkage.
        ./configure --prefix="$LIW_PREFIX" --without-modules --with-rsvg \
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
    # Feature assertions on the core library: the delegates compiled into
    # MagickCore itself (annotate's freetype/fontconfig, lcms color
    # management, xml2, and the coder delegates, which are internal
    # because of --without-modules: png, jpeg, tiff, webp, heif, jxl,
    # raw, rsvg, openjpeg, zip, fftw, lzma, zstd, bzip2).  A missing
    # optional delegate here means configure silently dropped it.
    local linked lib
    linked="$(otool -L "$LIW_PREFIX/lib"/libMagickCore*.dylib 2>/dev/null || true)"
    [ -n "$linked" ] || die "imagemagick produced no dylib to check"
    for lib in libfreetype libfontconfig libxml2 "libz." libpng libjpeg \
        libtiff libwebp libheif libjxl libraw librsvg libopenjp lcms \
        fftw libzip liblzma libzstd libbz2.; do
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
    # only direct linkage is asserted here.  orc is NOT asserted: it is
    # libvips's fallback SIMD package, used only when libhwy is missing,
    # and the prefix always has libhwy because jpeg-xl needs it -- the
    # linux build behaves identically and the Dockerfile's orc is dead
    # weight there too.  Verified from meson's output: with libhwy found,
    # the orc dependency is never even looked up.)
    local linked lib
    linked="$(otool -L "$LIW_PREFIX/lib"/libvips*.dylib 2>/dev/null || true)"
    [ -n "$linked" ] || die "libvips produced no dylib to check"
    for lib in libgobject openslide MagickCore libheif libjxl libjpeg \
        libtiff libpng libwebp librsvg libpoppler libcfitsio libmatio \
        nifti libarchive libraw libopenjp libexif fftw lcms \
        imagequant pangocairo libhwy; do
        printf '%s\n' "$linked" | grep -q "$lib" ||
            die "libvips was not linked against $lib; an optional dependency was missed (check the build order)"
    done
    done_stamp libvips
}

# --------------------------------------------------------------------------
# Dependencies for GDAL and mapnik (the Dockerfile's GDAL tree), mirroring
# the Dockerfile's build order and flags.  The gdal case below builds the
# full tree on a fresh VM; each builder is also reachable as dep:<name>.
#
# The Dockerfile sections that have no macos counterpart are skipped with a
# reason:
#   - libtirpc / libnsl ("Used by GDAL"): GDAL's cmake has no tirpc or
#     nsl check at all (verified against the pinned gdal source) -- the
#     comment is stale from the autotools era; the linux build installs
#     both and nothing links them.
#   - krb5: the macOS system Kerberos framework plays the same role for
#     everything here (the pylibmc cyrus-sasl precedent); the linux prefix
#     krb5 feeds curl's and libpq's optional GSS support, which no test
#     exercises.
#   - libaio: "Linux async i/o library" for mysql.
#   - libxcrypt: provides libcrypt (GDAL and postgresql on linux); macOS
#     libSystem provides crypt.
#   - lapack: there is no Fortran compiler in the VM (the linux build uses
#     the base image's gcc-gfortran), and a Homebrew gfortran would drag
#     Homebrew's libgfortran into the wheels.  Armadillo instead links the
#     macOS Accelerate framework (its cmake does this by default on APPLE
#     when no BLAS/LAPACK is found), which provides BLAS and LAPACK as
#     system frameworks the otool audits allow.  build_armadillo asserts
#     the Accelerate linkage.
#   - ogdi: GDAL 3.13's cmake has no OGDI check at all, and the shared
#     suite's known-formats list (which mirrors the linux wheel) has no
#     OGDI entry -- the linux wheel has no OGDI driver either, so building
#     it cannot light up a tested feature while its linux-tuned makefiles
#     are a pure build risk.
#   - mrsid: the DSDK is x86_64-only (the linux build gates it on
#     AUDITWHEEL_ARCH too); the shared suite subtracts mrsid on arm64.
# --------------------------------------------------------------------------

# GDAL's GIF driver links the external giflib when it is installed (the
# cmake-era default is external-when-found), so the linux wheel's libgif
# must have a macos counterpart.  giflib's Makefile already has a darwin
# branch (-dynamiclib), but its installed dylibs carry bare install names
# (fixed with fix_dylib_ids), and its install rules descend into a doc
# directory that cannot build here (the Dockerfile seds that rule out).
build_giflib() {
    skip_if_done giflib && return 0
    step "giflib"
    cd "$LIW_SRC"
    rm -rf giflib
    fetch "https://downloads.sourceforge.net/project/giflib/giflib-6.x/giflib-$(v giflib).tar.gz" \
        giflib.tar.gz
    mkdir giflib
    tar -zxf giflib.tar.gz -C giflib --strip-components 1
    (
        cd giflib || exit 1
        sed -i '' 's/\$(MAKE) -C doc/echo/g' Makefile || exit 1
        # Upstream's Makefile has a Darwin branch, and its Darwin
        # libutil.dylib rule links only qprintf.o/getarg.o --
        # GifErrorString (which lives in libgif) stays undefined.  The
        # Linux linker allows undefined symbols in shared libraries, so
        # the Dockerfile's libutil.so builds as-is there; the macOS
        # linker rejects them.  Restore the Linux semantics with
        # -undefined dynamic_lookup (the jxrlib lesson).  libutil is not
        # installed by the Darwin install target (only libgif is); it
        # only has to build so 'all' succeeds.
        sed -i '' 's|-o \$(LIBUTILSO)$|& -Wl,-undefined,dynamic_lookup|' Makefile ||
            exit 1
        make -j "$LIW_JOBS" PREFIX="$LIW_PREFIX" || exit 1
        make install PREFIX="$LIW_PREFIX" || exit 1
    ) || die "giflib build failed"
    [ -e "$LIW_PREFIX/lib/libgif.dylib" ] ||
        die "giflib did not install libgif"
    fix_dylib_ids "$LIW_PREFIX/lib"/libgif*.dylib "$LIW_PREFIX/lib"/libutil*.dylib
    done_stamp giflib
}

# The Dockerfile's openssl section is deliberately pinned: versions.txt
# says 4.0.3, and the linux build ignores it ("PINNED - openldap doesn't
# handle version 4.x yet") and builds the 3.6.2 tag.  The macos build pins
# the same literal (not $(v openssl)) so a future versions.txt change
# cannot silently move it either; check_versions.py may flag the mismatch.
# This is what gives the prefix's curl TLS (build_curl's assertion), and
# GDAL links libcrypto directly for its CPL crypto.
build_openssl() {
    skip_if_done openssl && return 0
    step "openssl (pinned 3.6.2; versions.txt's 4.x is deliberately ignored, like the linux build)"
    cd "$LIW_SRC"
    rm -rf openssl
    git_retry https://github.com/openssl/openssl.git "openssl-3.6.2" openssl
    (
        cd openssl || exit 1
        ./config --prefix="$LIW_PREFIX" --openssldir="$LIW_PREFIX/ssl" \
            shared zlib no-tests || exit 1
        make -j "$LIW_JOBS" || exit 1
        # "all install_sw" installs without the docs, like the linux build.
        make -j "$LIW_JOBS" all install_sw || exit 1
    ) || die "openssl build failed"
    # OpenSSL's makefile records relative install names on macOS; fix them
    # BEFORE any consumer (curl, mysql, postgresql, gdal) links the
    # libraries, so the consumers record absolute names (the hdf5 lesson).
    fix_dylib_ids "$LIW_PREFIX/lib"/libcrypto*.dylib "$LIW_PREFIX/lib"/libssl*.dylib
    [ -e "$LIW_PREFIX/lib/libcrypto.dylib" ] ||
        die "openssl did not install libcrypto"
    [ -e "$LIW_PREFIX/lib/libssl.dylib" ] ||
        die "openssl did not install libssl"
    local linked
    linked="$(otool -L "$LIW_PREFIX/lib"/libssl*.dylib 2>/dev/null || true)"
    printf '%s\n' "$linked" | grep -q libcrypto ||
        die "libssl was not linked against libcrypto"
    done_stamp openssl
}

# Used by GDAL (its cmake prefers external json-c when found; the linux
# wheel links libjson-c).
build_json_c() {
    skip_if_done json-c && return 0
    step "json-c"
    cd "$LIW_SRC"
    rm -rf json-c
    git_retry https://github.com/json-c/json-c.git "json-c-$(v json-c)" json-c
    cmake_build "$LIW_SRC/json-c" -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    [ -n "$(ls "$LIW_PREFIX/lib"/libjson-c*.dylib 2>/dev/null)" ] ||
        die "json-c did not install its library"
    done_stamp json-c
}

# Used by GDAL (GDAL_USE_LERC=ON; the linux wheel links the external
# liblerc).
build_lerc() {
    skip_if_done lerc && return 0
    step "lerc"
    cd "$LIW_SRC"
    rm -rf lerc
    git_retry https://github.com/Esri/lerc.git "v$(v lerc)" lerc
    cmake_build "$LIW_SRC/lerc"
    [ -n "$(ls "$LIW_PREFIX/lib"/lib*erc*.dylib 2>/dev/null)" ] ||
        die "lerc did not install its library"
    done_stamp lerc
}

# SWIG generates the GDAL python bindings' wrapper sources; the linux base
# image ships it and the VM's Homebrew set does not, so build it into the
# prefix as a build tool only (like bison).  The sourceforge release
# tarball carries a pre-generated configure (the git tarball would need
# autogen.sh and bison); PCRE2 comes from swig's own Tools/pcre-build.sh,
# which builds a downloaded PCRE2 tarball as a static library into the
# swig source tree where swig's configure finds it automatically -- it is
# never installed into the prefix.
build_swig() {
    skip_if_done swig && return 0
    step "swig (pinned 4.3.1; a build tool for the GDAL python bindings)"
    local swig_version=4.3.1 pcre2_version=10.45
    cd "$LIW_SRC"
    rm -rf swig
    fetch "https://downloads.sourceforge.net/project/swig/swig/swig-$swig_version/swig-$swig_version.tar.gz" \
        swig.tar.gz
    mkdir swig
    tar -zxf swig.tar.gz -C swig --strip-components 1
    (
        cd swig || exit 1
        fetch "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$pcre2_version/pcre2-$pcre2_version.tar.gz" \
            "pcre2-$pcre2_version.tar.gz" || exit 1
        Tools/pcre-build.sh || exit 1
        ./configure --prefix="$LIW_PREFIX" || exit 1
        make -j "$LIW_JOBS" || exit 1
        make install || exit 1
    ) || die "swig build failed"
    "$LIW_PREFIX/bin/swig" -version 2>/dev/null | grep -q "$swig_version" ||
        die "swig did not install the expected version"
    done_stamp swig
}

# openmpi: the MPI implementation hdf5's parallel build (HDF5_ENABLE_PARALLEL,
# needed by parallel netcdf) requires.  The Dockerfile prefers the release
# tarball over the git branch (the git branch runs autogen.pl and is slow).
# The Dockerfile's '-disable-oshmem-profile' has a single dash (configure
# parses it as a run of short options); it is spelled correctly here.
build_openmpi() {
    skip_if_done openmpi && return 0
    step "openmpi"
    cd "$LIW_SRC"
    rm -rf openmpi
    fetch "https://download.open-mpi.org/release/open-mpi/v$(v openmpi 2)/openmpi-$(v openmpi).tar.gz" \
        openmpi.tar.gz
    mkdir openmpi
    tar -zxf openmpi.tar.gz -C openmpi --strip-components 1
    (
        cd openmpi || exit 1
        ./configure --prefix="$LIW_PREFIX" \
            --disable-picky --disable-dependency-tracking \
            --enable-silent-rules --disable-dlopen --disable-libompitrace \
            --disable-opal-btl-usnic-unit-tests --disable-debug \
            --disable-mem-profile --disable-mem-debug --disable-static \
            --disable-mpi-java --disable-oshmem-profile || exit 1
        make -j "$LIW_JOBS" || exit 1
        make install || exit 1
    ) || die "openmpi build failed"
    [ -x "$LIW_PREFIX/bin/mpicc" ] || die "openmpi did not install mpicc"
    [ -e "$LIW_PREFIX/lib/libmpi.dylib" ] ||
        die "openmpi did not install libmpi"
    done_stamp openmpi
}

# Boost: mysql needs its headers (WITH_BOOST; like the linux build, the
# WITH_BOOST value the Dockerfile computes from the superproject matches
# nothing and mysql fetches its own copy), and mapnik -- the package after
# GDAL -- needs the libraries, so build them here exactly like the
# Dockerfile does.  The superproject's submodules (the libs/* trees) are
# required for the build; git_retry has no provision for extra clone
# options, so the retry loop is inline (like jpeg-xl's).
build_boost() {
    skip_if_done boost && return 0
    step "boost (the submodule clone is large)"
    cd "$LIW_SRC"
    rm -rf boost
    local n=0
    until git clone --depth=1 --single-branch -b "boost-$(v boost)" \
        -c advice.detachedHead=false --quiet --recurse-submodules \
        -j "$LIW_JOBS" https://github.com/boostorg/boost.git boost; do
        n=$((n + 1))
        [ "$n" -ge 10 ] &&
            die "git clone failed after $n attempts: boost (boost-$(v boost))"
        echo "retrying git clone: https://github.com/boostorg/boost.git"
        sleep 5
    done
    (
        cd boost || exit 1
        # The same flags as the linux build: an empty user-config jam and
        # the mpi line (harmless -- no --with-mpi is built), the clang
        # toolset in place of gcc, and the same --with list.  gcc-only
        # warning flags (-Wno-maybe-uninitialized) stay: they only produce
        # clang warnings here, like on the linux gcc build.
        echo "" >tools/build/src/user-config.jam || exit 1
        echo "using mpi : $LIW_PREFIX/lib ;" >>tools/build/src/user-config.jam || exit 1
        ./bootstrap.sh --prefix="$LIW_PREFIX" --with-toolset=clang \
            variant=release || exit 1
        ./b2 -d1 -j "$LIW_JOBS" toolset=clang variant=release link=shared \
            --build-type=minimal \
            --with-filesystem \
            --with-thread \
            --with-regex \
            --with-atomic \
            --with-program_options \
            --with-url \
            --with-context \
            cxxflags="-std=c++14 -Wno-parentheses -Wno-deprecated-declarations -Wno-unused-variable -Wno-parentheses -Wno-maybe-uninitialized -Wno-attributes" \
            install || exit 1
    ) || die "boost build failed"
    [ -n "$(ls "$LIW_PREFIX/lib"/libboost_*.dylib 2>/dev/null)" ] ||
        die "boost did not install its libraries"
    # b2 records bare install names for its darwin dylibs; fix them before
    # mysql (or mapnik) links anything.
    fix_dylib_ids "$LIW_PREFIX/lib"/libboost_*.dylib
    done_stamp boost
}

# Used by gdal, mapnik, libgeotiff, libspatialite, and rasterlite2.  PROJ
# is built from its cmake build (like the linux build); the sqlite3 binary
# from build_sqlite generates proj.db.
build_proj4() {
    skip_if_done proj4 && return 0
    step "proj4"
    cd "$LIW_SRC"
    rm -rf proj4
    git_retry https://github.com/OSGeo/proj.4.git "$(v proj4)" proj4
    cmake_build "$LIW_SRC/proj4" -DBUILD_TESTING=OFF
    [ -e "$LIW_PREFIX/lib/libproj.dylib" ] ||
        die "proj4 did not install libproj"
    [ -x "$LIW_PREFIX/bin/proj" ] ||
        die "proj4 did not install its tools"
    [ -e "$LIW_PREFIX/share/proj/proj.db" ] ||
        die "proj4 did not install its proj.db data"
    local linked lib
    linked="$(otool -L "$LIW_PREFIX/lib"/libproj*.dylib 2>/dev/null || true)"
    [ -n "$linked" ] || die "proj4 produced no dylib to check"
    for lib in libtiff libsqlite3 libcurl; do
        printf '%s\n' "$linked" | grep -q "$lib" ||
            die "libproj was not linked against $lib; an optional dependency was missed (check the build order)"
    done
    done_stamp proj4
}

# Used by libOpenDRIVE (zipped XODR bundles) and mapnik.  MZ_OPENSSL=yes
# mirrors the linux build (the prefix's openssl is built before this in
# the gdal case).
build_minizip() {
    skip_if_done minizip && return 0
    step "minizip"
    cd "$LIW_SRC"
    rm -rf minizip
    git_retry https://github.com/zlib-ng/minizip-ng.git "$(v minizip)" minizip
    # The Dockerfile seds an add_compile_options(-fPIC) after the PPMD
    # status message to keep those objects position-independent; it is not
    # mirrored here: on arm64 every object is PIC anyway, and the BSD
    # sed's replacement does not interpret GNU's \n escape, so the same
    # substitution would corrupt the CMakeLists line.
    cmake_build "$LIW_SRC/minizip" -DBUILD_SHARED_LIBS=ON -DMZ_OPENSSL=yes
    [ -n "$(ls "$LIW_PREFIX/lib"/libminizip*.dylib 2>/dev/null)" ] ||
        die "minizip did not install its library"
    done_stamp minizip
}

# The gaia-gis sources (freexl, libspatialite, librasterlite2) live in
# fossil repositories, so the fossil executable is a build tool like
# bison and swig: it is built into the prefix and never bundled.  The
# prefix's OpenSSL feeds its https support.
build_fossil() {
    skip_if_done fossil && return 0
    step "fossil (build tool; clones the gaia-gis fossil repositories)"
    cd "$LIW_SRC"
    rm -rf fossil
    fetch "https://github.com/drhsqlite/fossil-mirror/archive/refs/tags/version-$(v fossil).tar.gz" \
        fossil.tar.gz
    mkdir fossil
    tar -zxf fossil.tar.gz -C fossil --strip-components 1
    (
        cd fossil || exit 1
        ./configure --prefix="$LIW_PREFIX" --with-openssl="$LIW_PREFIX" || exit 1
        make -j "$LIW_JOBS" || exit 1
        make install || exit 1
    ) || die "fossil build failed"
    "$LIW_PREFIX/bin/fossil" version 2>/dev/null | grep -q "$(v fossil)" ||
        die "fossil did not install the expected version"
    done_stamp fossil
}

# Used by GDAL's XLS driver.  The gaia-gis fossil repository is the only
# upstream source (the versions.txt pin is a fossil hash the linux build
# does not use either -- it clones the trunk tip).  The macOS iconv lives
# in libSystem, so the linux build's LIBS=-liconv is not needed here; the
# linux --build triplet is linux-specific and is dropped.
build_freexl() {
    skip_if_done freexl && return 0
    step "freexl"
    cd "$LIW_SRC"
    rm -rf freexl freexl.fossil
    # The Dockerfile's global --user=root works in the container only
    # because $USER is root there: clone seeds the fresh repository's
    # user table from --admin-user, or from $USER when it is absent,
    # and user_select() then dies with "no such user" when the global
    # --user names a user the fresh repository does not have.  The VM's
    # $USER is not root, so create the root user with --admin-user;
    # user_select() still prefers the global --user, which now exists.
    printf 'yes\nyes\n' | fossil --user=root clone --admin-user root \
        https://www.gaia-gis.it/fossil/freexl freexl.fossil ||
        die "fossil clone of freexl failed"
    mkdir freexl
    (
        cd freexl || exit 1
        fossil open ../freexl.fossil || exit 1
        rm -f ../freexl.fossil
        ./configure --prefix="$LIW_PREFIX" --disable-static || exit 1
        make -j "$LIW_JOBS" || exit 1
        make install || exit 1
    ) || die "freexl build failed"
    [ -e "$LIW_PREFIX/lib/libfreexl.dylib" ] ||
        die "freexl did not install its library"
    done_stamp freexl
}

# Used by GDAL (GEOS_LIBRARY_PATH in the python bindings' osgeo patch) and
# by librttopo/libspatialite below.
build_libgeos() {
    skip_if_done libgeos && return 0
    step "libgeos"
    cd "$LIW_SRC"
    rm -rf geos
    git_retry https://github.com/libgeos/geos.git "$(v libgeos)" geos
    # CMAKE_BUILD_WITH_INSTALL_NAME_DIR must be ON (the hdf4 lesson:
    # with modern cmake the build-tree install names are @rpath
    # regardless of CMAKE_INSTALL_NAME_DIR).  libgeos_c links libgeos
    # inside this same build tree, and the gdal wheel bundles both --
    # without this, libgeos_c records an @rpath/libgeos reference that
    # stops resolving once the prefix RPATHs are stripped and delocate
    # fails (geos's own INSTALL_NAME_DIR lines are commented out
    # upstream, so no target property would fix it).  Verified on the
    # host against the pinned 3.15.0: without the flag libgeos_c's
    # libgeos reference is @rpath; with it both ids and the reference
    # are absolute.
    cmake_build "$LIW_SRC/geos" -DGEOS_BUILD_DEVELOPER=NO -DBUILD_TESTING=OFF \
        -DCMAKE_BUILD_WITH_INSTALL_NAME_DIR=ON
    [ -e "$LIW_PREFIX/lib/libgeos_c.dylib" ] ||
        die "libgeos did not install libgeos_c"
    [ -e "$LIW_PREFIX/lib/libgeos.dylib" ] ||
        die "libgeos did not install libgeos"
    done_stamp libgeos
}

# Used by libspatialite.
build_librttopo() {
    skip_if_done librttopo && return 0
    step "librttopo"
    cd "$LIW_SRC"
    rm -rf rttopo
    git_retry https://gitlab.com/rttopo/rttopo.git \
        "librttopo-$(v librttopo)" rttopo
    (
        cd rttopo || exit 1
        ./autogen.sh || exit 1
        ./configure --prefix="$LIW_PREFIX" --disable-static || exit 1
        make -j "$LIW_JOBS" || exit 1
        make install || exit 1
    ) || die "librttopo build failed"
    [ -e "$LIW_PREFIX/lib/librttopo.dylib" ] ||
        die "librttopo did not install its library"
    done_stamp librttopo
}

# Used by GDAL and mapnik.  The gaia-gis fossil trunk tip (like the linux
# build; the commented-out fossil checkout pin is disabled there too).
build_libspatialite() {
    skip_if_done libspatialite && return 0
    step "libspatialite"
    cd "$LIW_SRC"
    rm -rf libspatialite libspatialite.fossil
    # See build_freexl for why --admin-user is needed here.
    fossil --user=root clone --admin-user root \
        https://www.gaia-gis.it/fossil/libspatialite \
        libspatialite.fossil || die "fossil clone of libspatialite failed"
    mkdir libspatialite
    (
        cd libspatialite || exit 1
        fossil open ../libspatialite.fossil || exit 1
        rm -f ../libspatialite.fossil
        # The linux build's --build triplet is linux-specific.
        CFLAGS="$CFLAGS -Os" CXXFLAGS="$CXXFLAGS -Os" \
            ./configure --prefix="$LIW_PREFIX" --disable-examples \
            --disable-static || exit 1
        make -j "$LIW_JOBS" || exit 1
        make install || exit 1
    ) || die "libspatialite build failed"
    [ -e "$LIW_PREFIX/lib/libspatialite.dylib" ] ||
        die "libspatialite did not install its library"
    local linked lib
    linked="$(otool -L "$LIW_PREFIX/lib"/libspatialite*.dylib 2>/dev/null || true)"
    [ -n "$linked" ] || die "libspatialite produced no dylib to check"
    for lib in libgeos_c libproj libfreexl; do
        printf '%s\n' "$linked" | grep -q "$lib" ||
            die "libspatialite was not linked against $lib; an optional dependency was missed (check the build order)"
    done
    done_stamp libspatialite
}

# Used by gdal and mapnik; the gdal python wheel also bundles libgeotiff's
# command line tools (listgeo and friends), like the linux build does.
# Autotools build like the linux build (its comment: cmake here breaks
# librasterlite2's detection).
build_libgeotiff() {
    skip_if_done libgeotiff && return 0
    step "libgeotiff"
    cd "$LIW_SRC"
    rm -rf libgeotiff
    git_retry https://github.com/OSGeo/libgeotiff.git "$(v libgeotiff)" libgeotiff
    (
        cd libgeotiff/libgeotiff || exit 1
        autoreconf -ifv || exit 1
        ./configure --prefix="$LIW_PREFIX" --with-zlib=yes --with-jpeg=yes \
            --disable-static || exit 1
        make -j "$LIW_JOBS" || exit 1
        make install || exit 1
    ) || die "libgeotiff build failed"
    [ -e "$LIW_PREFIX/lib/libgeotiff.dylib" ] ||
        die "libgeotiff did not install its library"
    [ -n "$(find "$LIW_SRC/libgeotiff/libgeotiff/bin/.libs" -type f -perm -111 2>/dev/null)" ] ||
        die "libgeotiff produced no tools to bundle"
    local linked lib
    linked="$(otool -L "$LIW_PREFIX/lib"/libgeotiff*.dylib 2>/dev/null || true)"
    [ -n "$linked" ] || die "libgeotiff produced no dylib to check"
    for lib in libproj libtiff libjpeg "libz."; do
        printf '%s\n' "$linked" | grep -q "$lib" ||
            die "libgeotiff was not linked against $lib; an optional dependency was missed (check the build order)"
    done
    done_stamp libgeotiff
}

# Used by GDAL and mapnik (raster coverage via SpatiaLite).  The checkout
# pin mirrors the linux build's fossil checkout (a commit hash the
# versions.txt has no entry for).
build_librasterlite2() {
    skip_if_done librasterlite2 && return 0
    step "librasterlite2"
    cd "$LIW_SRC"
    rm -rf librasterlite2 librasterlite2.fossil
    # See build_freexl for why --admin-user is needed here.
    fossil --user=root clone --admin-user root \
        https://www.gaia-gis.it/fossil/librasterlite2 \
        librasterlite2.fossil ||
        die "fossil clone of librasterlite2 failed"
    mkdir librasterlite2
    (
        cd librasterlite2 || exit 1
        fossil open ../librasterlite2.fossil || exit 1
        fossil checkout -f 9dd8217cb9 || exit 1
        # rasterlite2_private.h uses time_t (struct rl2_cached_raster's
        # last_used) without including <time.h>.  glibc's headers define
        # time_t transitively, so the linux build never notices; the
        # darwin headers do not, and the library's TUs die with "unknown
        # type name 'time_t'".  Include it explicitly.
        sed -i '' 's|#include "config.h"|#include "config.h"\
#include <time.h>|' headers/rasterlite2_private.h || exit 1
        rm -f ../librasterlite2.fossil
        # The linux build's --build triplet is linux-specific.
        # configure.ac header-checks sqlite3.h but never adds -lsqlite3
        # (only jpeg/gif/tiff/geotiff get AC_CHECK_LIB), so librasterlite2
        # links with undefined sqlite3 symbols: the linux linker permits
        # that in a .so and they resolve at load time from libgdal's
        # libsqlite3; the macOS linker rejects them.  Both the
        # librasterlite2.la and mod_rasterlite2.la link rules append
        # $(LIBS), so supply -lsqlite3 through the environment -- an
        # explicit load command rather than -undefined dynamic_lookup,
        # since the dependency is real and one-way (no jxrlib-style
        # circularity) and delocate follows it (libgdal bundles
        # libsqlite3 regardless).
        LIBS="-lsqlite3" ./configure --prefix="$LIW_PREFIX" --disable-static || exit 1
        make -j "$LIW_JOBS" || exit 1
        make install || exit 1
    ) || die "librasterlite2 build failed"
    [ -e "$LIW_PREFIX/lib/librasterlite2.dylib" ] ||
        die "librasterlite2 did not install its library"
    done_stamp librasterlite2
}

# Used by gdal (the SOSI driver).  Clones the master tip like the linux
# build ("PINNED VERSION - use master"; the fyba sha in versions.txt is
# not used there either).  The patch moves the stdafx.h include below
# <locale>, exactly like the linux build's inline patch.
build_fyba() {
    skip_if_done fyba && return 0
    step "fyba"
    cd "$LIW_SRC"
    rm -rf fyba
    git_retry https://github.com/kartverket/fyba.git "" fyba
    cat >"$LIW_PATCHES/fyba_fylu.py" <<'EOF'
path = "src/FYBA/FYLU.cpp"
data = open(path, "rb").read()
data = data.replace(
    b"#include \"stdafx.h\"", b"")
data = data.replace(
    b"#include <locale>",
    b"#include <locale>\n" +
    b"#include \"stdafx.h\"")
open(path, "wb").write(data)
EOF
    (
        cd fyba || exit 1
        "$LIW_PATCH_PYBIN" "$LIW_PATCHES/fyba_fylu.py" || exit 1
        autoreconf -ifv || exit 1
        CXXFLAGS="$CXXFLAGS -std=c++11" \
            ./configure --prefix="$LIW_PREFIX" || exit 1
        make -j "$LIW_JOBS" || exit 1
        make install || exit 1
    ) || die "fyba build failed"
    for lib in fyba fygm fyut; do
        [ -n "$(ls "$LIW_PREFIX/lib"/lib$lib*.dylib 2>/dev/null)" ] ||
            die "fyba did not install lib$lib"
    done
    done_stamp fyba
}

# Used by GDAL (the HDF4 driver links hdf4 directly; netcdf's own HDF4
# option is not passed -- the linux build's ENABLE_HDF4 spelling is inert
# at netcdf 4.10.x, so its netcdf has no HDF4 either).
build_hdf4() {
    skip_if_done hdf4 && return 0
    step "hdf4"
    cd "$LIW_SRC"
    rm -rf hdf4
    git_retry https://github.com/HDFGroup/hdf4.git "hdf-$(v hdf4)" hdf4
    # ZLIB_LIBRARIES/ZLIB_INCLUDE_DIR must be preset (the hdf5 lesson:
    # hdf4's CMakeFilters.cmake first runs a CONFIG-mode
    # find_package(ZLIB ... COMPONENTS static shared), which silently
    # succeeds against the prefix zlib's ZLIBConfig.cmake without
    # defining the module variables hdf4's filter code appends to
    # LINK_COMP_LIBS -- the shared libhdf then links with undefined
    # inflate/deflate symbols, which the macOS linker rejects).  Note
    # the link then records /usr/lib/libz.1.dylib, not the prefix zlib:
    # Apple's linker maps libz to the OS copy, which is fine (it is
    # always present and delocate treats /usr/lib as system).  JPEG is
    # fine as-is: its config-mode find misses and a second find resolves
    # the prefix libjpeg (verified in the failing run's log: no jpeg
    # symbols in the undefined list).
    #
    # hdf4's HDFMacros.cmake sets CMAKE_INSTALL_NAME_DIR to @rpath on
    # Apple, and a macro's normal-variable set shadows cmake_build's
    # cache value, so every hdf4 target's INSTALL_NAME_DIR property is
    # initialized to @rpath.  With modern cmake the build-tree install
    # names are @rpath regardless of CMAKE_INSTALL_NAME_DIR (the
    # property only rewrites ids at install), and libmfhdf -- which
    # netcdf and gdal link, so it ships in the wheel -- links libdf and
    # libxdr inside this same build tree and would record @rpath
    # references that stop resolving once the prefix RPATHs are stripped
    # (the hdf5 @rpath lesson; hdf5 escaped it only because no
    # wheel-shipped dylib links its dylibs within its own build, and
    # HDF4_BUILD_WITH_INSTALL_NAME only rewrites installed ids).  Two
    # changes together, both required (verified on the host): sed the
    # macro to the absolute prefix libdir so the property is absolute,
    # and pass -DCMAKE_BUILD_WITH_INSTALL_NAME_DIR=ON so the build tree
    # actually uses the property.
    sed -i '' \
        's|set (CMAKE_INSTALL_NAME_DIR "@rpath")|set (CMAKE_INSTALL_NAME_DIR "${CMAKE_INSTALL_PREFIX}/lib")|' \
        "$LIW_SRC/hdf4/config/cmake/HDFMacros.cmake" || exit 1
    cmake_build "$LIW_SRC/hdf4" \
        -DHDF4_BUILD_FORTRAN=OFF \
        -DHDF4_ENABLE_NETCDF=OFF \
        -DHDF4_ENABLE_Z_LIB_SUPPORT=ON \
        -DHDF4_DISABLE_COMPILER_WARNINGS=ON \
        -DBUILD_TESTING=OFF \
        -DZLIB_DIR="$LIW_PREFIX/lib" \
        -DZLIB_LIBRARIES="$LIW_PREFIX/lib/libz.dylib" \
        -DZLIB_INCLUDE_DIR="$LIW_PREFIX/include" \
        -DCMAKE_BUILD_WITH_INSTALL_NAME_DIR=ON
    [ -n "$(ls "$LIW_PREFIX/lib"/libdf* "$LIW_PREFIX/lib"/libmfhdf* 2>/dev/null)" ] ||
        die "hdf4 did not install libdf/libmfhdf"
    local f id links
    for f in "$LIW_PREFIX/lib"/libdf*.dylib "$LIW_PREFIX/lib"/libxdr*.dylib \
        "$LIW_PREFIX/lib"/libmfhdf*.dylib; do
        [ -f "$f" ] || continue
        [ -L "$f" ] && continue
        id="$(otool -D "$f" 2>/dev/null | sed -n 2p)"
        case "$id" in
        "$LIW_PREFIX"/*) ;;
        *) die "hdf4 installed a dylib without an absolute install id ('$f': '$id')" ;;
        esac
        links="$(otool -L "$f" 2>/dev/null || true)"
        if printf '%s\n' "$links" | grep -q "@rpath"; then
            die "hdf4 installed $f with an @rpath load command:\n$links"
        fi
    done
    done_stamp hdf4
}

# parallel-netcdf, built from the checkpoint branch like the linux build
# (with its LT_PREREQ downgrade -- the VM's libtool is older than the
# branch's 2.5.4 requirement).  Needs build_openmpi's mpicc.
build_parallel_netcdf() {
    skip_if_done parallel-netcdf && return 0
    step "parallel-netcdf"
    cd "$LIW_SRC"
    rm -rf PnetCDF
    git_retry https://github.com/Parallel-NetCDF/PnetCDF \
        "checkpoint.$(v parallel-netcdf)" PnetCDF
    (
        cd PnetCDF || exit 1
        sed -i '' 's/LT_PREREQ(\[2.5.4\])/LT_PREREQ([2.4.6])/g' configure.ac || exit 1
        autoreconf -ifv || exit 1
        ./configure --prefix="$LIW_PREFIX" --enable-shared \
            --disable-fortran --enable-thread-safe --disable-static || exit 1
        make -j "$LIW_JOBS" || exit 1
        make install || exit 1
    ) || die "parallel-netcdf build failed"
    [ -n "$(ls "$LIW_PREFIX/lib"/libpnetcdf*.dylib 2>/dev/null)" ] ||
        die "parallel-netcdf did not install its library"
    local linked
    linked="$(otool -L "$LIW_PREFIX/lib"/libpnetcdf*.dylib 2>/dev/null || true)"
    printf '%s\n' "$linked" | grep -q libmpi ||
        die "libpnetcdf was not linked against libmpi; the MPI build was missed (check the build order)"
    done_stamp parallel-netcdf
}

# The netcdf driver's library.  The Dockerfile's flag set is passed
# verbatim even though netcdf 4.10.x renamed its options (the unprefixed
# ENABLE_* spellings are inert there too, so this converges on the linux
# final state: hdf5 found and parallel4 auto-enabled by hdf5's parallel
# build, DAP and NCZARR on by default, no HDF4).  The linux
# CMAKE_SHARED_LINKER_FLAGS=-ljpeg is kept: hdf4 is a static library and
# consumers must carry its jpeg dependency (the macOS linker rejects the
# resulting undefined symbols the linux linker tolerates).
build_netcdf() {
    skip_if_done netcdf && return 0
    step "netcdf"
    cd "$LIW_SRC"
    rm -rf netcdf-c
    git_retry https://github.com/Unidata/netcdf-c "v$(v netcdf)" netcdf-c
    (
        cd netcdf-c || exit 1
        # The compiler throws an erroneous error because strlen is used as
        # a function variable.  Avoid this (the linux seds).
        sed -i '' 's/int strlen,/int strlenn,/g' libnczarr/zutil.c || exit 1
        sed -i '' 's/format,strlen)/format,strlenn)/g' libnczarr/zutil.c || exit 1
    ) || die "netcdf patch failed"
    cmake_build "$LIW_SRC/netcdf-c" \
        -DCMAKE_C_FLAGS="$CFLAGS -Wno-incompatible-pointer-types" \
        -DENABLE_EXAMPLES=OFF -DENABLE_PARALLEL4=ON -DUSE_PARALLEL=ON \
        -DUSE_PARALLEL4=ON -DENABLE_HDF4=ON -DENABLE_PNETCDF=ON \
        -DENABLE_BYTERANGE=ON -DENABLE_JNA=ON \
        -DCMAKE_SHARED_LINKER_FLAGS="-L$LIW_PREFIX/lib -ljpeg" \
        -DENABLE_TESTS=OFF -DENABLE_HDF4_FILE_TESTS=OFF -DENABLE_DAP=ON \
        -DENABLE_HDF5=ON -DENABLE_NCZARR=ON
    [ -n "$(ls "$LIW_PREFIX/lib"/libnetcdf*.dylib 2>/dev/null)" ] ||
        die "netcdf did not install its library"
    local linked lib
    linked="$(otool -L "$LIW_PREFIX/lib"/libnetcdf*.dylib 2>/dev/null || true)"
    [ -n "$linked" ] || die "netcdf produced no dylib to check"
    for lib in libhdf5 libcurl; do
        printf '%s\n' "$linked" | grep -q "$lib" ||
            die "libnetcdf was not linked against $lib; an optional dependency was missed (check the build order)"
    done
    done_stamp netcdf
}

# The MySQL client library for GDAL's MySQL driver.  Mirrors the
# Dockerfile: the ndb CMakeLists.txt stub (bugs.mysql.com/87348),
# WITHOUT_SERVER, bundled zlib, the ftls-model flags (clang accepts
# -ftls-model), and the same WITH_BOOST expression.  The find matches
# nothing in the boost superproject (its headers are generated at build
# time), so mysql fetches its own boost -- the same thing that happens in
# the linux build.  This is a long build even without the server.
build_mysql() {
    skip_if_done mysql && return 0
    step "mysql (long)"
    cd "$LIW_SRC"
    rm -rf mysql
    fetch "https://cdn.mysql.com/Downloads/MySQL-$(v mysql 2)/mysql-$(v mysql).tar.gz" \
        mysql.tar.gz
    mkdir mysql
    tar -zxf mysql.tar.gz -C mysql --strip-components 1
    (
        cd mysql || exit 1
        rm -rf mysql-test || exit 1
        mkdir -p storage/ndb || exit 1
        touch storage/ndb/CMakeLists.txt || exit 1
    ) || die "mysql source preparation failed"
    # The Dockerfile does not pass WITH_SSL: on linux, mysql's
    # WITH_SSL=system finds the distribution's OpenSSL.  On the VM,
    # mysql's cmake/ssl.cmake explicitly hints ${HOMEBREW_HOME}/openssl
    # for APPLE and finds Homebrew's OpenSSL 4.0.3, whose opensslv.h
    # yields an empty version string -- "Not a supported openssl
    # version" -- and it would be a Homebrew leak anyway.  WITH_SSL=
    # <path> is mysql's supported custom-installation mode: it finds
    # the prefix's pinned 3.6.2 headers/libs (MIN is 1.0.0), requires
    # $LIW_PREFIX/bin/openssl (installed by build_openssl), and its
    # APPLE_WITH_CUSTOM_SSL machinery copies libssl/libcrypto into the
    # build's library_output_directory, patching the copy's libcrypto
    # dependency to @loader_path.  libmysqlclient records the copies'
    # ids, which fix_dylib_ids made absolute prefix paths (delocate
    # friendly), and mysql's install step then copies those dylibs
    # into the prefix's lib dir -- libcrypto.3.dylib is overwritten
    # byte-identically and the patched libssl.3.dylib still resolves
    # its @loader_path/libcrypto.3.dylib from the prefix, so the
    # prefix stays consistent for later consumers (gdal).
    cmake_build "$LIW_SRC/mysql" \
        -DBUILD_CONFIG=mysql_release \
        -DBUILD_SHARED_LIBS=ON \
        -DWITH_BOOST="$(find "$LIW_SRC/boost" -maxdepth 1 -name 'boost_*')" \
        -DWITH_ZLIB=bundled \
        -DWITH_SSL="$LIW_PREFIX" \
        -DCMAKE_BUILD_TYPE=MinSizeRel \
        -DWITH_UNIT_TESTS=OFF \
        -DWITHOUT_SERVER=ON \
        -DREPRODUCIBLE_BUILD=ON \
        -DINSTALL_MYSQLTESTDIR= \
        -DCMAKE_C_FLAGS="$CFLAGS -ftls-model=global-dynamic" \
        -DCMAKE_CXX_FLAGS="$CXXFLAGS -ftls-model=global-dynamic"
    [ -n "$(ls "$LIW_PREFIX/lib"/libmysqlclient*.dylib 2>/dev/null)" ] ||
        die "mysql did not install libmysqlclient"
    [ -x "$LIW_PREFIX/bin/mysql_config" ] ||
        die "mysql did not install mysql_config"
    local linked
    linked="$(otool -L "$LIW_PREFIX/lib"/libmysqlclient*.dylib 2>/dev/null || true)"
    [ -n "$linked" ] || die "mysql produced no dylib to check"
    printf '%s\n' "$linked" | grep -q libssl ||
        die "libmysqlclient was not linked against libssl; the prefix OpenSSL was missed (check the build order)"
    done_stamp mysql
}

# The postgresql client library for GDAL's PG/PGDump/PostGISRaster
# drivers.  Two deviations from the bare linux configure, both forced by
# the isolated prefix: --without-icu (the linux base image has ICU; the
# prefix does not, and postgresql 16+ fails configure without the flag --
# ICU only affects collation variants) and --without-readline (the prefix
# has none, and the base VM's Homebrew readline must not be linked).
# --with-ssl=openssl mirrors the linux final state (libpq links the
# prefix's OpenSSL).
build_postgresql() {
    skip_if_done postgresql && return 0
    step "postgresql"
    cd "$LIW_SRC"
    rm -rf postgresql
    fetch "https://ftp.postgresql.org/pub/source/v$(v postgresql)/postgresql-$(v postgresql).tar.gz" \
        postgresql.tar.gz
    mkdir postgresql
    tar -zxf postgresql.tar.gz -C postgresql --strip-components 1
    (
        cd postgresql || exit 1
        ./configure --prefix="$LIW_PREFIX" --without-icu --without-readline \
            --with-ssl=openssl || exit 1
        make -j "$LIW_JOBS" || exit 1
        make install || exit 1
    ) || die "postgresql build failed"
    [ -e "$LIW_PREFIX/lib/libpq.dylib" ] ||
        die "postgresql did not install libpq"
    [ -x "$LIW_PREFIX/bin/pg_config" ] ||
        die "postgresql did not install pg_config"
    local linked
    linked="$(otool -L "$LIW_PREFIX/lib"/libpq*.dylib 2>/dev/null || true)"
    [ -n "$linked" ] || die "postgresql produced no dylib to check"
    printf '%s\n' "$linked" | grep -q libssl ||
        die "libpq was not linked against libssl; --with-ssl=openssl was missed"
    done_stamp postgresql
}

# Used by GDAL.  Generic Tagged Arrays.  Built with cmake (the linux
# build's comment: its autotools path needs gettext's m4 macros, which the
# isolated environments do not have).
build_libgta() {
    skip_if_done libgta && return 0
    step "libgta"
    cd "$LIW_SRC"
    rm -rf gta-mirror
    git_retry https://github.com/marlam/gta-mirror.git \
        "libgta-$(v libgta)" gta-mirror
    cmake_build "$LIW_SRC/gta-mirror/libgta" \
        -DGTA_BUILD_DOCUMENTATION=OFF -DGTA_BUILD_STATIC_LIB=OFF
    [ -n "$(ls "$LIW_PREFIX/lib"/libgta*.dylib 2>/dev/null)" ] ||
        die "libgta did not install its library"
    done_stamp libgta
}

# Used by GDAL (the GMLAS and ILI drivers).  The iconv transcoder mirrors
# the linux build; on macOS iconv resolves to the system iconv in /usr/lib,
# which the audits allow.
build_xerces_c() {
    skip_if_done xerces-c && return 0
    step "xerces-c"
    cd "$LIW_SRC"
    rm -rf xerces-c
    git_retry https://github.com/apache/xerces-c.git "v$(v xerces-c)" xerces-c
    cmake_build "$LIW_SRC/xerces-c" -Dtranscoder=iconv
    [ -n "$(ls "$LIW_PREFIX/lib"/libxerces-c*.dylib 2>/dev/null)" ] ||
        die "xerces-c did not install its library"
    done_stamp xerces-c
}

# Used by GDAL (TPS transformation).  No lapack is built (no Fortran in
# the VM -- see the section comment): on APPLE armadillo's cmake defaults
# to the Accelerate framework when no BLAS/LAPACK is found, which provides
# both as system frameworks, and GDAL's armadillo test program links.
build_armadillo() {
    skip_if_done armadillo && return 0
    step "armadillo"
    cd "$LIW_SRC"
    rm -rf armadillo
    fetch "https://sourceforge.net/projects/arma/files/armadillo-$(v armadillo).tar.xz" \
        armadillo.tar.xz
    unxz -f armadillo.tar.xz
    mkdir armadillo
    tar -xf armadillo.tar -C armadillo --strip-components 1
    rm -f armadillo.tar
    cmake_build "$LIW_SRC/armadillo" -DBUILD_SHARED_LIBS=ON
    [ -n "$(ls "$LIW_PREFIX/lib"/libarmadillo*.dylib 2>/dev/null)" ] ||
        die "armadillo did not install its library"
    local linked
    linked="$(otool -L "$LIW_PREFIX/lib"/libarmadillo*.dylib 2>/dev/null || true)"
    [ -n "$linked" ] || die "armadillo produced no dylib to check"
    printf '%s\n' "$linked" | grep -q Accelerate ||
        die "libarmadillo was not linked against the Accelerate framework; no BLAS/LAPACK backend was found (there is no Fortran compiler to build lapack)"
    done_stamp armadillo
}

# Used by GDAL (block compression).  The external lz4/zstd/zlib from the
# prefix mirror the Dockerfile's PREFER_EXTERNAL flags.
build_blosc() {
    skip_if_done blosc && return 0
    step "blosc"
    cd "$LIW_SRC"
    rm -rf c-blosc
    git_retry https://github.com/Blosc/c-blosc.git "v$(v blosc)" c-blosc
    cmake_build "$LIW_SRC/c-blosc" \
        -DBUILD_SHARED=ON -DBUILD_STATIC=OFF -DBUILD_BENCHMARKS=OFF \
        -DBUILD_FUZZERS=OFF -DBUILD_TESTS=OFF -DPREFER_EXTERNAL_LZ4=ON \
        -DPREFER_EXTERNAL_ZLIB=ON -DPREFER_EXTERNAL_ZSTD=ON \
        -DDEACTIVATE_SNAPPY=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    [ -n "$(ls "$LIW_PREFIX/lib"/libblosc*.dylib 2>/dev/null)" ] ||
        die "blosc did not install its library"
    local linked lib
    linked="$(otool -L "$LIW_PREFIX/lib"/libblosc*.dylib 2>/dev/null || true)"
    [ -n "$linked" ] || die "blosc produced no dylib to check"
    for lib in liblz4 libzstd "libz."; do
        printf '%s\n' "$linked" | grep -q "$lib" ||
            die "libblosc was not linked against $lib; an optional dependency was missed (check the build order)"
    done
    done_stamp blosc
}

# Used by kealib (header-only).
build_highfive() {
    skip_if_done highfive && return 0
    step "highfive"
    cd "$LIW_SRC"
    rm -rf highfive
    # The submodules are required (its thirdparty headers); like boost and
    # jpeg-xl, the retry loop is inline because git_retry has no provision
    # for extra clone options.
    local n=0
    until git clone --depth=1 --single-branch -b "v$(v highfive)" \
        -c advice.detachedHead=false --recurse-submodules -j "$LIW_JOBS" \
        https://github.com/highfive-devs/highfive.git highfive; do
        n=$((n + 1))
        [ "$n" -ge 10 ] &&
            die "git clone failed after $n attempts: highfive (v$(v highfive))"
        echo "retrying git clone: https://github.com/highfive-devs/highfive.git"
        sleep 5
    done
    cmake_build "$LIW_SRC/highfive" \
        -DHIGHFIVE_UNIT_TESTS=OFF -DHIGHFIVE_BUILD_DOCS=OFF \
        -DHIGHFIVE_EXAMPLES=OFF
    [ -d "$LIW_PREFIX/include/highfive" ] ||
        die "highfive did not install its headers"
    done_stamp highfive
}

# Used by GDAL (the KEA driver); needs hdf5's C++ library (built with
# HDF5_BUILD_CPP_LIB=ON).
build_kealib() {
    skip_if_done kealib && return 0
    step "kealib"
    cd "$LIW_SRC"
    rm -rf kealib
    git_retry https://github.com/ubarsc/kealib.git "kealib-$(v kealib)" kealib
    cmake_build "$LIW_SRC/kealib"
    [ -n "$(ls "$LIW_PREFIX/lib"/libkea*.dylib 2>/dev/null)" ] ||
        die "kealib did not install libkea"
    local linked
    linked="$(otool -L "$LIW_PREFIX/lib"/libkea*.dylib 2>/dev/null || true)"
    [ -n "$linked" ] || die "kealib produced no dylib to check"
    printf '%s\n' "$linked" | grep -q libhdf5 ||
        die "libkea was not linked against libhdf5 (check the build order)"
    done_stamp kealib
}

# Used by GDAL (the XODR driver).  The 0.6.0-gdal tag is pinned by the
# Dockerfile comment (0.6.1-gdal requires external pugixml and more).
build_libopendrive() {
    skip_if_done libopendrive && return 0
    step "libopendrive"
    cd "$LIW_SRC"
    rm -rf libOpenDRIVE
    git_retry https://github.com/DLR-TS/libOpenDRIVE.git "0.6.0-gdal" libOpenDRIVE
    # AppleClang 21's libc++ specializes __make_transparent<_Tp, less<_Tp>>
    # to less<>, so std::set<T>'s insert/emplace compare the VALUES with
    # less<void> -- requiring operator< on T itself -- and never call a
    # std::less<T> specialization; libstdc++ (the linux build) does use
    # the specialization, which is why this is macos-only.  libOpenDRIVE
    # orders its key types through std::less specializations only
    # (RoadMarksLine, RoadMarkGroup, JunctionLaneLink, JunctionPriority;
    # LaneKey is hash/equal_to only, for unordered containers), so give
    # each type an inline operator< that delegates to its existing
    # std::less specialization -- one source of comparison truth, found
    # via ADL wherever less<void> evaluates "a < b".  Verified on the
    # host: without the patch the library dies with "no matching function
    # for call to object of type 'const std::less<void>'"; with it, the
    # full build (including test-xodr) passes.
    cat >> "$LIW_SRC/libOpenDRIVE/include/RoadMark.h" <<'EOF'

// Added by macos/build_wheels.sh build_libopendrive: AppleClang 21's
// libc++ makes std::set<T>'s insert/emplace compare values with
// less<void> (needing operator< on T itself) and never calls a
// std::less<T> specialization; libstdc++ does.  Delegate to the
// existing specializations.
namespace odr
{
inline bool operator<(const RoadMarksLine& lhs, const RoadMarksLine& rhs)
{
    return std::less<RoadMarksLine>()(lhs, rhs);
}
inline bool operator<(const RoadMarkGroup& lhs, const RoadMarkGroup& rhs)
{
    return std::less<RoadMarkGroup>()(lhs, rhs);
}
} // namespace odr
EOF
    cat >> "$LIW_SRC/libOpenDRIVE/include/Junction.h" <<'EOF'

// Added by macos/build_wheels.sh build_libopendrive: see RoadMark.h.
namespace odr
{
inline bool operator<(const JunctionLaneLink& lhs, const JunctionLaneLink& rhs)
{
    return std::less<JunctionLaneLink>()(lhs, rhs);
}
inline bool operator<(const JunctionPriority& lhs, const JunctionPriority& rhs)
{
    return std::less<JunctionPriority>()(lhs, rhs);
}
} // namespace odr
EOF
    cmake_build "$LIW_SRC/libOpenDRIVE" -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    # The project builds a static libOpenDrive.a by default and the
    # Dockerfile does not change that -- gdal absorbs it, like on linux
    # (nothing ships a libOpenDRIVE dylib, so there is nothing to
    # delocate).
    [ -e "$LIW_PREFIX/lib/libOpenDrive.a" ] ||
        die "libopendrive did not install its static library"
    done_stamp libopendrive
}

# Used by GDAL and mapnik (the AVIF driver).  The libyuv URL sed mirrors
# the linux build (the default googlesource URL serves a captcha).
build_libavif() {
    skip_if_done libavif && return 0
    step "libavif"
    cd "$LIW_SRC"
    rm -rf libavif
    git_retry https://github.com/AOMediaCodec/libavif.git "v$(v libavif)" libavif
    (
        cd libavif || exit 1
        sed -i '' \
            's#https://chromium.googlesource.com/libyuv/libyuv#https://github.com/lemenkov/libyuv#g' \
            cmake/Modules/LocalLibyuv.cmake || exit 1
    ) || die "libavif patch failed"
    cmake_build "$LIW_SRC/libavif" \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DAVIF_LIBYUV=LOCAL
    [ -n "$(ls "$LIW_PREFIX/lib"/libavif*.dylib 2>/dev/null)" ] ||
        die "libavif did not install its library"
    done_stamp libavif
}

# GDAL itself.  Mirrors the Dockerfile: master at the recorded sha (the
# release clone branch is disabled there), the .2 local build suffix in
# three places, and the same explicit cmake options (GDAL_USE_LERC,
# ENABLE_DEFLATE64=OFF, GDAL_USE_PUBLICDECOMPWT=ON -- the last fetches
# EUMETSAT's PublicDecompWT for the MSG driver at build time).  The
# Dockerfile's make USER_DEFS (-Werror plus gcc-only -Wno-* flags) is not
# passed: clang warns about unknown -Wno-* options and the build must not
# turn compiler diagnostics into errors on a different compiler.  The
# MRSID cmake variables are not passed (the SDK is x86_64-only, like the
# linux build's arch gate).  cmake_build's MinSizeRel matches.
#
# The python bindings are part of the cmake build (swig from the prefix;
# -DPython_EXECUTABLE pins the interpreter): the bindings need numpy at
# configure and build time (the Dockerfile pip-installs numpy before
# cmake for the same reason), so numpy is installed into the patch python
# here and left installed -- it is a build VM, and no other wheel build
# picks it up (each wheel build runs in pip's isolated environment).
build_gdal() {
    skip_if_done gdal && return 0
    step "gdal (long)"
    cd "$LIW_SRC"
    rm -rf gdal
    git clone --depth=1000 --single-branch -c advice.detachedHead=false \
        https://github.com/OSGeo/gdal.git gdal || die "git clone failed: gdal"
    (
        cd gdal || exit 1
        git checkout -q "$(v gdal-sha)" || exit 1
        git gc --prune=all || exit 1
        # use .2 as a suffix (three spots), like the linux build
        sed -i '' 's/define GDAL_VERSION_BUILD    0/define GDAL_VERSION_BUILD    2/g' \
            gcore/gdal_version.h.in || exit 1
        sed -i '' 's/dev/.2dev/g' gcore/gdal_version.h.in || exit 1
        sed -i '' 's/\([0-9]\)$/\1.2/g' VERSION || exit 1
        sed -i '' 's/if library_version_num < gdal_python_version/if False/g' \
            swig/python/setup.py.in || exit 1
    ) || die "gdal source preparation failed"
    "$LIW_PATCH_PIPBIN" install -q numpy
    # The PublicDecompWT external project (MSG HRIT driver) clones
    # https://gitlab.eumetsat.int/open-source/PublicDecompWT.git, whose
    # .gitattributes LFS-marks test-data/** only; git requires the lfs
    # filter process for the clone even though the build consumes just
    # the plain DISE/COMP sources.  GIT_LFS_SKIP_SMUDGE=1 keeps git-lfs
    # from pulling the test-data objects (nothing in the build reads
    # them) while the filter still runs, mirroring the linux build
    # (whose base image supplies git-lfs).
    ensure_git_lfs
    # The exr driver needs three include dirs for OpenEXR 3.x's layout:
    # prefix/include/OpenEXR (gdal's openexr_headers.h includes
    # "ImfChannelList.h" etc. directly), prefix/include/Imath (it also
    # includes "ImathMatrix.h" directly -- that header only exists in
    # the Imath dir), and the PARENT prefix/include (OpenEXR's own
    # headers say #include <Imath/half.h>).  GDAL's FindOpenEXR only
    # puts the first two in OpenEXR_INCLUDE_DIRS, and on linux the
    # parent is implicit anyway: the prefix there is /usr/local, which
    # the compiler searches by default.  A private prefix is not an
    # implicit system path, so restore linux parity with standard
    # include directories (cmake emits them as -isystem, i.e. searched
    # after the user paths, so nothing is shadowed).  Verified on the
    # host: the two subdirs alone fail with "fatal error:
    # 'Imath/half.h' file not found" (the VM failure), and the same
    # compile passes with the parent added last.
    GIT_LFS_SKIP_SMUDGE=1 cmake_build "$LIW_SRC/gdal" \
        -DGDAL_USE_LERC=ON \
        -DENABLE_DEFLATE64=OFF \
        -DGDAL_USE_PUBLICDECOMPWT=ON \
        -DCMAKE_C_STANDARD_INCLUDE_DIRECTORIES="$LIW_PREFIX/include" \
        -DCMAKE_CXX_STANDARD_INCLUDE_DIRECTORIES="$LIW_PREFIX/include" \
        -DPython_EXECUTABLE="$LIW_PATCH_PYBIN"
    # An assignment prefixing a function call persists after it in bash;
    # restore the environment for the remaining steps.
    unset GIT_LFS_SKIP_SMUDGE
    [ -e "$LIW_PREFIX/lib/libgdal.dylib" ] ||
        die "gdal did not install libgdal"
    [ -x "$LIW_PREFIX/bin/gdalinfo" ] ||
        die "gdal did not install its tools"
    [ -x "$LIW_PREFIX/bin/gdal-config" ] ||
        die "gdal did not install gdal-config"
    [ -e "$LIW_PREFIX/share/gdal" ] ||
        die "gdal did not install its data files"
    # Feature assertions over libgdal's own linkage: every optional
    # library the linux wheel links must have resolved from the prefix.  A
    # missing one would otherwise only surface as a reduced-capability
    # wheel (or a missing format in the shared suite's known-formats
    # check).  hdf4 is NOT asserted: it is a static library, absorbed into
    # its consumers, so it has no load command of its own (the shared
    # suite's HDF4 format entry covers it).  librttopo is also not here:
    # GDAL never links it directly -- the linux wheel's ldd shows it only
    # transitively through libspatialite (see the check after the loop).
    local linked lib
    linked="$(otool -L "$LIW_PREFIX/lib"/libgdal*.dylib 2>/dev/null || true)"
    [ -n "$linked" ] || die "gdal produced no dylib to check"
    for lib in libgeos_c libproj libcurl libtiff libpng libjpeg libopenjp2 \
        libwebp libheif libavif libjxl libpoppler libcfitsio libhdf5 \
        libnetcdf libmysqlclient libpq libfreexl libspatialite \
        librasterlite2 libgeotiff fyba libxerces-c libexpat \
        libxml2 libjson-c liblerc libgta libkea libblosc libarchive \
        libgif libdeflate libzstd liblzma "libz." libsqlite3 libcrypto \
        libssl OpenEXR Lerc; do
        printf '%s\n' "$linked" | grep -q "$lib" ||
            die "libgdal was not linked against $lib; an optional dependency was missed (check the build order)"
    done
    # librttopo is deliberately NOT in the direct-linkage list: GDAL has
    # no rttopo check at all, and on linux librttopo.so shows up in ldd
    # only as a transitive dependency of libspatialite (ldd prints the
    # whole closure; otool -L only direct load commands).  Assert the
    # transitive path instead (build_libspatialite links the prefix's
    # librttopo).
    printf '%s\n' "$(otool -L "$LIW_PREFIX/lib"/libspatialite*.dylib 2>/dev/null || true)" |
        grep -q librttopo ||
        die "libspatialite was not linked against librttopo (libgdal reaches it only through spatialite)"
    done_stamp gdal
}

# The GDAL python wheel: bundles libgdal and its whole dependency tree,
# the proj and gdal data files, and the gdal/proj/libgeotiff command line
# tools, exactly like the linux wheel.  The osgeo patch exports
# GDAL_LIBRARY_PATH and GEOS_LIBRARY_PATH pointing at the bundled dylibs
# (delocate puts them in osgeo/.dylibs inside the wheel; the linux
# auditwheel-style GDAL.libs location stays as a fallback) and the data
# directories, so a clean install needs nothing from the system.
build_gdal_python() {
    skip_if_done gdal_python && return 0
    step "gdal python"

    # Dependencies may have just been built (fresh VM); strip any build-tree
    # RPATHs they installed before the wheels bundle them.
    sanitize_prefix_dylibs

    # Belt-and-braces check before delocate: every prefix dylib must have
    # an absolute install name (the same audit build_pyvips runs; this
    # catches cmake projects that override CMAKE_INSTALL_NAME_DIR).
    local d name
    while IFS= read -r -d '' d; do
        name="$(otool -D "$d" 2>/dev/null | sed -n 2p)"
        case "$name" in
        "$LIW_PREFIX"/*) ;;
        *) die "install name of $d is not absolute ('$name')" ;;
        esac
    done < <(find "$LIW_PREFIX/lib" -maxdepth 1 -name '*.dylib' -print0)

    # Strip the prefix dylibs before the wheel build (the linux build
    # strips everything before building wheels; libgdal alone is hundreds
    # of MB unstripped).  strip -x keeps the exported symbols; the arm64
    # signature is renewed after the strip.
    step "stripping prefix dylibs for the gdal wheels"
    while IFS= read -r -d '' f; do
        strip -x "$f" 2>/dev/null || true
    done < <(find "$LIW_PREFIX/lib" -name '*.dylib' -type f -print0)
    while IFS= read -r -d '' f; do
        codesign -f -s - "$f" 2>/dev/null || true
    done < <(find "$LIW_PREFIX/lib" -name '*.dylib' -type f -print0)

    cd "$LIW_SRC/gdal/_build/swig/python" ||
        die "the gdal python bindings were not configured under _build/swig/python"

    # Bundle the proj and gdal data files with the wheel, like the linux
    # build does (osgeo/proj and osgeo/gdal, wired up by the __init__
    # patch below).
    cp -R "$LIW_PREFIX/share/proj" osgeo/proj
    cp -R "$LIW_PREFIX/share/gdal" osgeo/gdal

    # Bundle the gdal, proj, and libgeotiff command line tools: for each
    # tool in gdal's apps build directory, the matching installed
    # executable; then gdal-config, libgeotiff's tools, and proj's tools.
    mkdir -p osgeo/bin
    local f base
    while IFS= read -r f; do
        base="$(basename "$f")"
        if [ -f "$LIW_PREFIX/bin/$base" ]; then
            cp -L "$LIW_PREFIX/bin/$base" osgeo/bin/
        fi
    done < <(find "$LIW_SRC/gdal/_build/apps" -type f -perm -111)
    rm -f osgeo/bin/gdal-config
    cp -L "$LIW_PREFIX/bin/gdal-config" osgeo/bin/
    while IFS= read -r f; do
        cp -L "$f" "osgeo/bin/$(basename "$f")"
    done < <(find "$LIW_SRC/libgeotiff/libgeotiff/bin/.libs" -type f -perm -111)
    while IFS= read -r f; do
        base="$(basename "$f")"
        if [ -f "$LIW_PREFIX/bin/$base" ]; then
            cp -L "$LIW_PREFIX/bin/$base" osgeo/bin/
        fi
    done < <(find "$LIW_SRC/proj4/_build/bin" -type f -perm -111)
    [ -e osgeo/bin/gdalinfo ] || die "no gdal tools found to bundle"
    [ -e osgeo/bin/gdal-config ] || die "gdal-config was not bundled"
    # Strip only the Mach-O tools (gdal-config is a shell script).
    while IFS= read -r -d '' f; do
        if file "$f" 2>/dev/null | grep -q Mach-O; then
            strip -x "$f" 2>/dev/null || true
        fi
    done < <(find osgeo/bin -type f -perm -111 -print0)
    # cmake-installed executables keep build-tree RPATHs; delocate's rpath
    # sanitizer only processes files that require other libraries, so
    # strip every non-@ RPATH and re-sign (arm64 requires a valid
    # signature after install_name_tool).
    local rp
    while IFS= read -r -d '' f; do
        file "$f" 2>/dev/null | grep -q Mach-O || continue
        while IFS= read -r rp; do
            case "$rp" in
            @loader_path/* | @executable_path/* | @rpath/*) ;;
            *) install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null || true ;;
            esac
        done < <(otool -l "$f" |
            awk '/LC_RPATH/{inr=1; next} inr && $1=="path" {print $2; inr=0}')
        codesign -f -s - "$f" 2>/dev/null || true
    done < <(find osgeo/bin -type f -perm -111 -print0)

    # Wrapper module so each bundled tool is exposed as a console script
    # (same wrapper the linux wheel ships, with the macOS CA bundle added).
    cat >osgeo/bin/__init__.py <<'EOF'
import os
import sys

def program():
    environ = os.environ.copy()
    localpath = os.path.dirname(os.path.abspath( __file__ ))
    environ.setdefault("PROJ_DATA", os.path.join(localpath, "proj"))
    environ.setdefault("GDAL_DATA", os.path.join(localpath, "gdal"))
    caPath = "/etc/ssl/certs/ca-certificates.crt"
    if not os.path.exists(caPath):
        caPath = "/etc/ssl/cert.pem"
    if os.path.exists(caPath):
        environ.setdefault("CURL_CA_BUNDLE", caPath)

    path = os.path.join(os.path.dirname(__file__), os.path.basename(sys.argv[0]))
    os.execve(path, sys.argv, environ)
EOF

    # Patch setup.py: name the bundled tools as console scripts, include
    # the bundled data and tools as package data, and (for parity with the
    # linux patch) recompute the version from gdal-config -- a no-op at
    # this source revision, whose version already comes out right -- and
    # drop a python_requires line that no longer matches upstream's text.
    cat >"$LIW_PATCHES/gdal_setup.py" <<'EOF'
import os
import re
path = "setup.py"
data = open(path).read()
data = re.sub(
    r"gdal_version = '\d+.\d+.\d+(dev|)'",
    "gdal_version = '" + os.popen("gdal-config --version").read().strip().split('.dev')[0].split('dev')[0] + "'",
    data)
data = data.replace(
    "scripts/*.py'),",
"""scripts/*.py'), 
    package_data={'osgeo': ['proj/*', 'gdal/*', 'bin/*']},""")
data = data.replace("console_scripts = []", """console_scripts = ['%s=osgeo.bin:program' % name for name in os.listdir('osgeo/bin') if not name.endswith('.py')]""")
if "console_scripts" not in data: data = data.replace(
    "scripts/*.py'),",
"""scripts/*.py'), 
    entry_points={'console_scripts': ['%s=osgeo.bin:program' % name for name in os.listdir('osgeo/bin') if not name.endswith('.py')]}""")
data = data.replace("    python_requires='>=3.6.0',", "")
open(path, "w").write(data)
EOF
    # Patch osgeo/__init__.py: set the bundled data paths and export
    # GDAL_LIBRARY_PATH / GEOS_LIBRARY_PATH from the bundled dylibs.  The
    # linux patch's TLS workaround (importing stdc++ first) is carried
    # over unchanged (it is a no-op on macOS, where find_library finds no
    # libstdc++).  delocate puts the bundled dylibs in osgeo/.dylibs; the
    # linux auditwheel-style GDAL.libs location stays as a fallback.
    cat >"$LIW_PATCHES/gdal_init.py" <<'EOF'
path = "osgeo/__init__.py"
s = open(path).read().replace(
    "osgeo package.",
"""osgeo package. 

import os 
import re 
from . import osr 
from . import gdal 

_localpath = os.path.dirname(os.path.abspath( __file__ )) 
# os.environ.setdefault("PROJ_DATA", os.path.join(_localpath, "proj")) 
osr.SetPROJSearchPaths([os.path.join(_localpath, "proj")]) 
# os.environ.setdefault("GDAL_DATA", os.path.join(_localpath, "gdal")) 
gdal.SetConfigOption("GDAL_DATA", os.path.join(_localpath, "gdal")) 
os.environ.setdefault("CPL_LOG", os.devnull) 
_caPath = "/etc/ssl/certs/ca-certificates.crt" 
if not os.path.exists(_caPath): 
    _caPath = "/etc/ssl/cert.pem" 
if os.path.exists(_caPath): 
    os.environ.setdefault("CURL_CA_BUNDLE", _caPath) 

_libsdir = os.path.join(_localpath, ".dylibs") 
if not os.path.exists(_libsdir): 
    _libsdir = os.path.join(os.path.dirname(_localpath), "GDAL.libs") 
_libs = {} 
if os.path.exists(_libsdir): 
    _libs = { 
        re.split(r"-|\.", name)[0]: os.path.join(_libsdir, name) 
        for name in os.listdir(_libsdir) 
    } 
GDAL_LIBRARY_PATH = _libs.get("libgdal", "") 
GEOS_LIBRARY_PATH = _libs.get("libgeos_c", "") 
import ctypes.util 

try: 
    ctypes.CDLL(ctypes.util.find_library("stdc++"), mode=ctypes.RTLD_GLOBAL) 
except Exception: 
    pass 
""")
open(path, "w").write(s)
EOF
    "$LIW_PATCH_PYBIN" "$LIW_PATCHES/gdal_setup.py"
    "$LIW_PATCH_PYBIN" "$LIW_PATCHES/gdal_init.py"
    # The patch must actually have replaced something: verify the inserted
    # markers exist (the verify-the-edit lesson).
    grep -q "GDAL_LIBRARY_PATH" osgeo/__init__.py ||
        die "the osgeo/__init__.py patch did not apply"
    grep -q "osgeo.bin:program" setup.py ||
        die "the setup.py patch did not apply"
    grep -q "package_data={'osgeo'" setup.py ||
        die "the setup.py package_data patch did not apply"

    # Copy python ports of c utilities to scripts so they get bundled
    # (mirrors the linux build; the setup.py glob these land in is
    # inert at this revision, like on linux).
    mkdir scripts
    cp gdal-utils/osgeo_utils/samples/gdalinfo.py scripts/gdalinfo.py
    cp gdal-utils/osgeo_utils/samples/ogrinfo.py scripts/ogrinfo.py

    # Commit the patches and tag with the combined version (the master
    # source version plus the .2 suffix the seds bake in).
    git config user.email "wheels@example.com"
    git config user.name "Wheel Builder"
    git add -A
    git commit -q -m "patch for wheel building"
    git tag "$(v gdal-source).2"

    # Build one wheel per python (the extensions link the build-tree
    # libgdal, whose install name is the absolute prefix path thanks to
    # BUILD_WITH_INSTALL_NAME_DIR), then bundle the dylibs with delocate
    # (the auditwheel equivalent on macOS).  pip's isolated build
    # environment installs numpy from the pyproject build requires, so the
    # _gdal_array extension is built for every python.
    collect_pybins
    local pybin
    for pybin in "${PYBINS[@]}"; do
        step "gdal wheel: $(basename "$(dirname "$pybin")")"
        (
            cd "$LIW_SRC/gdal/_build/swig/python"
            rm -rf build
            "$pybin/python" -m pip wheel --no-deps -w "$LIW_WHEELHOUSE" .
        ) || die "gdal wheel build failed for $pybin"
    done

    # pip writes the wheel filename in lowercase; the linux build renames
    # it to the capitalized distribution name before repair.
    local whl
    for whl in "$LIW_WHEELHOUSE"/gdal-*.whl; do
        [ -f "$whl" ] || continue
        mv "$whl" "$(dirname "$whl")/$(basename "$whl" | sed 's/^gdal-/GDAL-/')"
    done

    step "delocate gdal wheels"
    "$LIW_PATCH_PIPBIN" install -q -U delocate
    for whl in "$LIW_WHEELHOUSE"/GDAL-*.whl; do
        [ -f "$whl" ] || continue
        case "$(basename "$whl")" in
        *macosx*) "$LIW_PATCH_DIR/bin/delocate-wheel" "$whl" ||
            die "delocate failed for $whl" ;;
        esac
    done
    ls -l "$LIW_WHEELHOUSE"
    [ -n "$(ls "$LIW_WHEELHOUSE"/GDAL-*macosx*.whl 2>/dev/null)" ] ||
        die "no GDAL macosx wheels were built"
    # Feature assertions on the wheel: the bundled libgdal dylib, the
    # extensions (including the numpy-backed _gdal_array), the data
    # directories, and the tools must all be present.
    local contents
    contents="$(unzip -l "$(ls "$LIW_WHEELHOUSE"/GDAL-*macosx*.whl | head -1)")"
    printf '%s\n' "$contents" | grep -q 'osgeo/.dylibs/libgdal' ||
        die "the gdal wheel does not bundle libgdal"
    printf '%s\n' "$contents" | grep -q 'osgeo/_gdal_array' ||
        die "the gdal wheel does not contain the _gdal_array extension"
    printf '%s\n' "$contents" | grep -q 'osgeo/proj/proj.db' ||
        die "the gdal wheel does not bundle the proj data"
    printf '%s\n' "$contents" | grep -q 'osgeo/bin/gdalinfo' ||
        die "the gdal wheel does not bundle the gdalinfo tool"
    printf '%s\n' "$contents" | grep -q 'osgeo/bin/listgeo' ||
        die "the gdal wheel does not bundle the listgeo tool"
    done_stamp gdal_python
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

    # Belt-and-braces check before delocate: every prefix dylib must have
    # an absolute install name.  A consumer records the dependency name
    # from the dylib's install ID at its own build time, so a dylib that
    # installs with an @rpath install name leaves its consumers with a
    # reference nothing can resolve once the prefix rpaths are stripped
    # -- delocate then fails with "Could not find all dependencies"
    # (hdf5's @rpath override was found exactly this way).  Autotools and
    # meson installs are absolute already; this catches cmake projects
    # that override CMAKE_INSTALL_NAME_DIR.  Symlinked names double-check
    # their targets, which is harmless.
    local d name
    while IFS= read -r -d '' d; do
        name="$(otool -D "$d" 2>/dev/null | sed -n 2p)"
        case "$name" in
        "$LIW_PREFIX"/*) ;;
        *) die "install name of $d is not absolute ('$name')" ;;
        esac
    done < <(find "$LIW_PREFIX/lib" -maxdepth 1 -name '*.dylib' -print0)

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
[ "${#PACKAGES[@]}" -eq 0 ] && PACKAGES=(pylibtiff glymur openslide_python pylibmc pyvips gdal)

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
        # Order mirrors the Dockerfile's final state: openssl and curl are
        # built first (a TLS curl like the linux final state, so poppler
        # and everything else links the prefix curl), then the openslide
        # chain (libvips links openslide like any other loader, and its
        # glib/cairo/freetype/fontconfig/xml2 are shared with harfbuzz,
        # pango, and librsvg), then the leaf dependencies, then the pango
        # stack (harfbuzz before pango before librsvg), heif after
        # libde265, openmpi before hdf5 (hdf5 builds with parallel
        # support), matio after hdf5, and imagemagick after librsvg so
        # --with-rsvg finds it.  libvips's meson silently drops what is
        # missing; build_libvips asserts the linked feature set.
        build_libtiff_deps
        build_openssl
        build_curl
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
        build_openmpi
        build_hdf5
        build_matio
        build_openexr
        build_libzip
        build_pango
        build_librsvg
        build_imagemagick
        build_libvips
        build_pyvips
        ;;
    gdal)
        # Order mirrors the Dockerfile's final state for everything GDAL's
        # cmake can detect: the base format libraries (libtiff chain,
        # giflib), openssl and curl (TLS, early like the linux order, so
        # netcdf's DAP, spatialite, rasterlite2, and poppler all link the
        # same prefix curl), json-c, lerc, and jpeg-xl, the openjpeg
        # feature set (lcms2/libpng must exist before build_openjpeg), the
        # XML and compression helpers (expat, xml2, lz4, libarchive),
        # sqlite and proj, the freetype/fontconfig pair poppler needs,
        # swig (the python bindings' code generator), the MPI stack (hdf5's
        # parallel build), boost and minizip (mysql and libOpenDRIVE), the
        # geos/spatialite/rasterlite2 tree, the netcdf stack, the database
        # clients, the remaining format libraries (gta, xerces-c,
        # armadillo, blosc, highfive+kea, heif, poppler, cfitsio, openexr,
        # libOpenDRIVE, libavif), and finally gdal and its python
        # bindings.  Drivers whose absence would be silent are asserted on
        # libgdal's linkage by build_gdal.  The vips-only tree (orc,
        # nifti, fftw3, libhwy, libimagequant, libexif, harfbuzz, pango,
        # librsvg, imagemagick, libvips, jxrlib, openslide, matio, libzip)
        # is not built here: GDAL's cmake checks none of them, and the
        # shared suite's known-formats check is what polices the resulting
        # driver set.
        build_libtiff_deps
        build_giflib
        build_openssl
        build_curl
        build_json_c
        build_lerc
        build_lcms2
        build_libpng
        build_openjpeg
        build_libbrotli
        build_jpegxl
        build_libexpat
        build_sqlite
        build_libxml2
        build_lz4
        build_libarchive
        build_proj4
        build_freetype
        build_fontconfig
        build_swig
        build_openmpi
        build_boost
        build_minizip
        build_fossil
        build_freexl
        build_libgeos
        build_librttopo
        build_libspatialite
        build_libgeotiff
        build_librasterlite2
        build_fyba
        build_hdf4
        build_hdf5
        build_parallel_netcdf
        build_netcdf
        build_mysql
        build_postgresql
        build_libgta
        build_xerces_c
        build_armadillo
        build_blosc
        build_highfive
        build_kealib
        build_libde265
        build_libheif
        build_poppler
        build_fitsio
        build_openexr
        build_libopendrive
        build_libavif
        build_gdal
        build_gdal_python
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
    dep:json-c)
        build_json_c || die "building json-c failed"
        ;;
    dep:parallel-netcdf)
        build_parallel_netcdf || die "building parallel-netcdf failed"
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
