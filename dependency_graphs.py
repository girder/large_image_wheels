#!/usr/bin/env python3
"""
Generate mermaid dependency graphs of the native libraries bundled in each
wheel.

The graphs come from the binaries in the wheels themselves: ELF DT_NEEDED
entries for Linux wheels, Mach-O load commands for macOS wheels, and PE
imports for Windows wheels (all parsed here in pure python, so this runs on
any host).  Libraries are grouped by the source project that builds them
(named as in versions.txt where possible), and every platform and python
version of a wheel is merged into one graph, with the parts that are not
common to all of them marked.

Example:

    python3 dependency_graphs.py /path/to/wheelhouse -o dependency_graphs.md
    python3 dependency_graphs.py /path/to/wheelhouse --list-only

Any number of directories can be given; the platform of each wheel comes
from its file name, so wheels of every platform can share a directory.
Only currently published wheels are graphed, and only those for the newest
CPython (see select_wheels): the bundled libraries don't differ between
python versions.  Projects that are no longer built (such as pyproj) are
skipped.
"""

import argparse
import collections
import os
import re
import struct
import zipfile

# Library stem (file name without lib prefix, auditwheel hash, and version)
# to the source project that provides it.  Stems not listed here map to
# themselves, or to lib<stem> when that is a versions.txt name.
PROJECTS = {
    'asound': 'alsa-lib',
    'awt': 'zulu8 JVM',
    'awt_xawt': 'zulu8 JVM',
    'blas': 'lapack',
    'blkid': 'util-linux',
    'boost_container': 'boost',
    'boost_context': 'boost',
    'boost_json': 'boost',
    'boost_program_options': 'boost',
    'boost_url': 'boost',
    'brotlicommon': 'libbrotli',
    'brotlidec': 'libbrotli',
    'brotlienc': 'libbrotli',
    'bz2': 'bzip2',
    'cairo-gobject': 'cairo',
    'cfitsio': 'fitsio',
    'charset': 'libiconv',
    'com_err': 'krb5',
    'crypt': 'libxcrypt',
    'crypto': 'openssl',
    'df': 'hdf4',
    'dicom': 'libdicom',
    'event_core': 'libevent',
    'event_pthreads': 'libevent',
    'fygm': 'fyba',
    'fyut': 'fyba',
    'geos_c': 'libgeos',
    'gfortran': 'gcc runtime',
    'gif': 'giflib',
    'gio': 'glib',
    'gmodule': 'glib',
    'gobject': 'glib',
    'gomp': 'gcc runtime',
    'gssapi_krb5': 'krb5',
    'harfbuzz-subset': 'harfbuzz',
    'hdf': 'hdf4',
    'hdf5_cpp': 'hdf5',
    'hdf5_hl': 'hdf5',
    'ICE': 'X11',
    'icudata': 'icu4c',
    'icudt': 'icu4c',
    'icuin': 'icu4c',
    'icui18n': 'icu4c',
    'icuuc': 'icu4c',
    'Iex': 'openexr',
    'IlmThread': 'openexr',
    'Imath': 'imath',
    'intl': 'gettext',
    'java': 'zulu8 JVM',
    'jli': 'zulu8 JVM',
    'jpeg': 'libjpeg-turbo',
    'jpegxr': 'jxrlib',
    'jvm': 'zulu8 JVM',
    'jxl': 'jpeg-xl',
    'jxl_cms': 'jpeg-xl',
    'jxl_threads': 'jpeg-xl',
    'jxrglue': 'jxrlib',
    'k5crypto': 'krb5',
    'kea': 'kealib',
    'krb5support': 'krb5',
    'lapack': 'lapack',
    'lber': 'openldap',
    'ldap': 'openldap',
    'Lerc': 'lerc',
    'ltdl': 'libtool',
    'lti_dsdk': 'MrSID SDK',
    'ltidsdk': 'MrSID SDK',
    'lzma': 'xz',
    'MagickCore': 'imagemagick',
    'MagickWand': 'imagemagick',
    'mapnik': 'mapnik',
    'memcached': 'libmemcached',
    'mfhdf': 'hdf4',
    'mount': 'util-linux',
    'mpi': 'openmpi',
    'mysql': 'mysql',
    'mysqlclient': 'mysql',
    'niftiio': 'nifti',
    'open-pal': 'openmpi',
    'OpenEXR': 'openexr',
    'OpenEXRCore': 'openexr',
    'OpenEXRUtil': 'openexr',
    'openjp2': 'openjpeg',
    'pangocairo': 'pango',
    'pangoft2': 'pango',
    'pangowin32': 'pango',
    'pixman': 'pixman',
    'png16': 'libpng',
    'pnetcdf': 'parallel-netcdf',
    'poppler-glib': 'poppler',
    'pq': 'postgresql',
    'proj': 'proj4',
    'quadmath': 'gcc runtime',
    'raw_r': 'libraw',
    'rsvg': 'librsvg',
    'sasl2': 'cyrus-sasl',
    'sharpyuv': 'libwebp',
    'SM': 'X11',
    'sqlite3': 'sqlite',
    'ssl': 'openssl',
    'tbb': 'tbb',
    'uuid': 'util-linux',
    'verify': 'zulu8 JVM',
    'vips': 'libvips',
    'webpdemux': 'libwebp',
    'webpmux': 'libwebp',
    'X11': 'X11',
    'Xau': 'X11',
    'xcb': 'X11',
    'xdr': 'hdf4',
    'Xext': 'X11',
    'Xi': 'X11',
    'Xrender': 'X11',
    'Xtst': 'X11',
    'Xxf86vm': 'X11',
    'z': 'zlib',
    'znz': 'nifti',
}

# Runtime libraries that a repaired Windows wheel bundles but that are
# treated as part of the system, like libstdc++ on Linux.
SYSTEM_STEMS = {'concrt140', 'msvcp140', 'msvcp140_1', 'msvcp140_2',
                'vcomp140', 'vcruntime140', 'vcruntime140_1'}

# Files under these wheel directories belong to a vendored tree that is
# drawn as a single node.
VENDORED_TREES = {
    'javabridge/jvm/': 'zulu8 JVM',
}

PLATFORM_NAMES = {
    'linux': 'Linux', 'macos': 'macOS', 'windows': 'Windows', 'any': 'Any'}


def read_versions_names(path):
    names = set()
    try:
        with open(path) as fptr:
            for line in fptr:
                if line.strip() and not line.startswith('#'):
                    names.add(line.split()[0])
    except OSError:
        pass
    return names


def strip_hash(name):
    """
    Remove a repair-tool hash from a library file name: auditwheel uses
    -0123abcd, delvewheel a longer hex string.
    """
    return re.sub(r'-[0-9a-f]{8,32}(?=\.|$)', '', name)


def library_project(path, known):
    for prefix, project in VENDORED_TREES.items():
        if path.startswith(prefix):
            return project
    name = strip_hash(os.path.basename(path))
    if name.startswith('lib'):
        name = name[3:]
    match = re.match(r'[A-Za-z][A-Za-z0-9_+]*(?:-[A-Za-z][A-Za-z0-9_]*)*', name)
    stem = match.group(0) if match else name
    # Windows DLLs often carry the major version in the stem (zlib1,
    # jpeg62, proj_9, xerces-c_3_3).
    for candidate in (stem, re.sub(r'([-_]?\d+)+$', '', stem)):
        if candidate in PROJECTS:
            return PROJECTS[candidate]
        if 'lib' + candidate in known:
            return 'lib' + candidate
        if candidate in known:
            return candidate
    return 'lib' + stem


def elf_needed(data):
    """Return the DT_NEEDED entries of a 64-bit little-endian ELF file."""
    if data[4] != 2 or data[5] != 1:
        return []
    phoff, = struct.unpack_from('<Q', data, 0x20)
    phentsize, phnum = struct.unpack_from('<HH', data, 0x36)
    loads = []
    dynamic = None
    for idx in range(phnum):
        ptype, _flags, offset, vaddr, _paddr, filesz = struct.unpack_from(
            '<IIQQQQ', data, phoff + idx * phentsize)
        if ptype == 1:
            loads.append((vaddr, offset, filesz))
        elif ptype == 2:
            dynamic = (offset, filesz)
    if dynamic is None:
        return []
    needed = []
    strtab = None
    for pos in range(dynamic[0], dynamic[0] + dynamic[1], 16):
        tag, val = struct.unpack_from('<qQ', data, pos)
        if tag == 0:
            break
        if tag == 1:
            needed.append(val)
        elif tag == 5:
            strtab = val
    if strtab is None:
        return []
    for vaddr, offset, filesz in loads:
        if vaddr <= strtab < vaddr + filesz:
            strtab = strtab - vaddr + offset
            break
    result = []
    for val in needed:
        end = data.index(b'\0', strtab + val)
        result.append(data[strtab + val:end].decode())
    return result


def macho_needed(data):
    """Return the dylib load commands of a (possibly fat) Mach-O file."""
    if data[:4] == b'\xca\xfe\xba\xbe':
        nfat, = struct.unpack_from('>I', data, 4)
        if not 0 < nfat < 20:
            return []
        arches = [struct.unpack_from('>IIIII', data, 8 + 20 * idx)
                  for idx in range(nfat)]
        arch = next((a for a in arches if a[0] == 0x0100000c), arches[0])
        data = data[arch[2]:arch[2] + arch[3]]
    if data[:4] != b'\xcf\xfa\xed\xfe':
        return []
    ncmds, = struct.unpack_from('<I', data, 16)
    pos = 32
    result = []
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', data, pos)
        # LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB,
        # LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB
        if cmd in {0xc, 0x80000018, 0x8000001f, 0x20, 0x80000023}:
            nameoff, = struct.unpack_from('<I', data, pos + 8)
            end = data.index(b'\0', pos + nameoff)
            result.append(data[pos + nameoff:end].decode())
        pos += size
    return result


def pe_needed(data):
    """Return the imported and delay-loaded DLLs of a PE file."""
    peoff, = struct.unpack_from('<I', data, 0x3c)
    if data[peoff:peoff + 4] != b'PE\0\0':
        return None
    coff = peoff + 4
    nsections, = struct.unpack_from('<H', data, coff + 2)
    optsize, = struct.unpack_from('<H', data, coff + 16)
    opt = coff + 20
    magic, = struct.unpack_from('<H', data, opt)
    dirs = opt + (112 if magic == 0x20b else 96)
    sections = []
    for idx in range(nsections):
        _vsize, vaddr, rawsize, rawptr = struct.unpack_from(
            '<IIII', data, opt + optsize + 40 * idx + 8)
        sections.append((vaddr, rawsize, rawptr))

    def offset(rva):
        for vaddr, rawsize, rawptr in sections:
            if vaddr <= rva < vaddr + rawsize:
                return rva - vaddr + rawptr
        return None

    def cstring(rva):
        pos = offset(rva)
        if pos is None:
            return None
        return data[pos:data.index(b'\0', pos)].decode('ascii', 'replace')

    result = []
    # Import directory (index 1, 20-byte descriptors, name RVA at +12) and
    # delay import directory (index 13, 32-byte descriptors, name at +4).
    for index, size, nameoff in ((1, 20, 12), (13, 32, 4)):
        rva, _dirsize = struct.unpack_from('<II', data, dirs + 8 * index)
        pos = offset(rva) if rva else None
        while pos is not None and pos + size <= len(data):
            if not any(data[pos:pos + size]):
                break
            name = cstring(struct.unpack_from('<I', data, pos + nameoff)[0])
            if name:
                result.append(name)
            pos += size
    return result


MAGICS = (b'\x7fELF', b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'MZ')


def binary_needed(data):
    if data[:4] == b'\x7fELF':
        return elf_needed(data)
    if data[:4] in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe'):
        return macho_needed(data)
    if data[:2] == b'MZ' and len(data) > 0x40:
        return pe_needed(data)
    return None


def wheel_info(filename):
    """
    Return (project, version, python tag label, platform, arch, policy)
    from a wheel file name.  policy orders rebuilds of the same wheel under
    different platform tags (manylinux2014 < manylinux_2_28).
    """
    parts = os.path.basename(filename)[:-4].split('-')
    project = re.sub(r'[-_.]+', '-', parts[0]).lower()
    pytag, abi, plat = parts[-3], parts[-2], parts[-1]
    if abi == 'none':
        tag = pytag
    elif abi.startswith('abi3'):
        tag = pytag + '-' + abi
    else:
        tag = abi
    if plat == 'any':
        platform = 'any'
    elif plat.startswith('macosx'):
        platform = 'macos'
    elif plat.startswith('win'):
        platform = 'windows'
    else:
        platform = 'linux'
    arch = '' if plat == 'any' else plat.split('.')[0].split('_', 3 if (
        plat.startswith('manylinux_') or plat.startswith('musllinux_')) else (
        3 if plat.startswith('macosx') else 1))[-1]
    policy = (2, 5)
    match = re.search(r'(?:many|musl)linux_(\d+)_(\d+)', plat)
    if match:
        policy = (int(match.group(1)), int(match.group(2)))
    else:
        policy = {'manylinux2014': (2, 17), 'manylinux2010': (2, 12)}.get(
            plat.split('_')[0], policy)
    return project, parts[1], tag, platform, arch, policy


def version_key(version):
    """Sort key for versions such as 3.13.3.2 and 2.6.1.post1."""
    return [(int(p), '') if p.isdigit() else (-1, p)
            for p in re.split(r'[.]', version)]


def tag_key(label):
    """Sort key for python tag labels such as cp39, cp315t, cp311-abi3 x86_64."""
    match = re.match(r'([a-z]+)(\d)(\d*)(.*)', label)
    if not match:
        return ('', 0, 0, label)
    return (match.group(1), int(match.group(2)), int(match.group(3) or 0),
            match.group(4))


def cpython_minor(tag):
    """Return the CPython minor version of a tag (cp315t -> 15), or None."""
    match = re.match(r'cp3(\d+)', tag)
    return int(match.group(1)) if match else None


def covers(general, tag):
    """
    Return True if a wheel with the general tag (py3, cp311-abi3,
    cp315-abi3.abi3t) also installs on the python of a version-specific tag
    (cp313, cp314t).
    """
    minor = cpython_minor(tag)
    if general == tag or minor is None or '-' in tag or tag.startswith('py'):
        return False
    if general.startswith('py3'):
        return True
    match = re.match(r'cp3(\d+)-(abi3[.a-z0-9]*)$', general)
    if not match or int(match.group(1)) > minor:
        return False
    return not tag.endswith('t') or 'abi3t' in match.group(2)


def select_wheels(paths, exclude=()):
    """
    Pick the wheels to graph from directories that may hold every version
    ever published (such as the wheelhouse branch).

    The libraries a wheel bundles don't differ between python versions, so
    only the wheels that the newest CPython in the listing (and its
    free-threaded build) would install are used: for each project,
    platform, and architecture, the newest wheel tagged for it (cp315,
    cp315t) or covering it (abi3, py3).  A project without such a wheel is
    no longer published and is skipped, as are projects in exclude.

    Return ({project: [(platform, arch, tag, version, path)]}, report),
    where report lists what was skipped and why.
    """
    newest = {}
    for path in paths:
        project, version, tag, platform, arch, policy = wheel_info(path)
        key = (project, platform, arch, tag)
        rank = (version_key(version), policy)
        if key not in newest or rank > newest[key][0]:
            newest[key] = (rank, version, path)
    latest_minor = max((cpython_minor(key[3]) or 0 for key in newest), default=0)
    targets = [f'cp3{latest_minor}', f'cp3{latest_minor}t']
    exclude = {re.sub(r'[-_.]+', '-', name).lower() for name in exclude}
    selected = collections.defaultdict(list)
    report = []
    for project in sorted({key[0] for key in newest}):
        if project in exclude:
            report.append(f'{project}: excluded on the command line')
            continue
        groups = sorted({key[1:3] for key in newest if key[0] == project})
        for platform, arch in groups:
            tags = {key[3]: value for key, value in newest.items()
                    if key[:3] == (project, platform, arch)}
            chosen = set()
            for target in targets:
                serving = [tag for tag in tags
                           if tag == target or covers(tag, target)]
                if serving:
                    # Newest first, then the most specific tag.
                    chosen.add(max(serving, key=lambda tag: (
                        tags[tag][0], tag == target, tag_key(tag))))
            for tag in sorted(chosen, key=tag_key):
                _rank, version, path = tags[tag]
                selected[project].append((platform, arch, tag, version, path))
        if project not in selected:
            newest_version = max((value[1] for key, value in newest.items()
                                  if key[0] == project), key=version_key)
            report.append(f'{project}: skipped, no longer published (newest '
                          f'{newest_version} has no wheel for cp3{latest_minor})')
    return selected, report


def file_kind(name):
    """Classify a binary that the wheel ships as its own (not a library)."""
    base = os.path.basename(name)
    if '/bin/' in '/' + name or base.endswith('.exe') or (
            '.' not in base and not base.startswith('lib')):
        return 'tools'
    if base.endswith('.pyd') or re.search(
            r'\.(cpython-|abi3|cp3\d|pypy)[^/]*\.so$', base):
        return 'extension'
    return 'plugins'


WHEEL_KINDS = {
    'python': 'python package',
    'extension': 'python extension',
    'tools': 'command line tools',
    'plugins': 'plugins and helper libraries',
}


def analyze_wheel(path, known):
    """
    Return (nodes, edges, runtime, requires) for one wheel.  nodes are the
    bundled projects, edges (src, dst) project pairs where src links dst
    (the wheel's own files are the WHEEL_KINDS nodes, named ':<kind>'), and
    runtime the projects that nothing in the wheel links (loaded with
    dlopen, ctypes, or cffi's ABI mode).
    """
    binaries = {}
    requires = []
    with zipfile.ZipFile(path) as zf:
        for info in zf.infolist():
            if info.is_dir():
                continue
            if info.filename.endswith('.dist-info/METADATA'):
                for line in zf.read(info).decode('utf8', 'replace').splitlines():
                    if line.startswith('Requires-Dist:') and 'extra ==' not in line:
                        requires.append(line.split(':', 1)[1].strip())
                continue
            with zf.open(info) as fptr:
                magic = fptr.read(4)
            if not magic.startswith(MAGICS):
                continue
            needed = binary_needed(zf.read(info))
            if needed is not None:
                binaries[info.filename] = needed
    bybase = collections.defaultdict(list)
    for name in binaries:
        bybase[os.path.basename(name).lower()].append(name)

    def owner(name):
        parts = name.split('/')
        for prefix, project in VENDORED_TREES.items():
            if name.startswith(prefix):
                return project
        if name.lower().endswith('.exe'):
            return ':tools'
        if os.path.splitext(strip_hash(parts[-1]))[0].lower() in SYSTEM_STEMS:
            return None
        # delvewheel puts the libraries of top-level extension modules in
        # <name>.data/platlib rather than <name>.libs.
        if any(p.endswith(('.libs', '.dylibs')) for p in parts[:-1]) or \
                re.search(r'-[0-9a-f]{32}\.dll$', parts[-1]):
            return library_project(name, known)
        return ':' + file_kind(name)

    owners = {name: owner(name) for name in binaries}
    binaries = {name: needed for name, needed in binaries.items() if owners[name]}
    nodes = set(owners[name] for name in binaries)
    edges = set()
    for name, needed in binaries.items():
        src = owners[name]
        for dep in needed:
            # Windows import names may have a different case than the file.
            targets = bybase.get(re.split(r'[/\\]', dep)[-1].lower())
            if not targets:
                continue  # provided by the system
            dst = owners[targets[0]]
            if dst and dst != src:
                edges.add((src, dst))
    reached = {n for n in nodes if n.startswith(':')}
    stack = list(reached)
    while stack:
        cur = stack.pop()
        for src, dst in edges:
            if src == cur and dst not in reached:
                reached.add(dst)
                stack.append(dst)
    runtime = set()
    unreached = nodes - reached
    while unreached:
        tops = {n for n in unreached
                if not any(s in unreached and d == n for s, d in edges)}
        tops = tops or {min(unreached)}
        runtime |= tops
        stack = list(tops)
        while stack:
            cur = stack.pop()
            unreached.discard(cur)
            for src, dst in edges:
                if src == cur and dst in unreached:
                    stack.append(dst)
    if runtime:
        nodes.add(':python')
    return nodes, edges, runtime, requires


def reduce_edges(edges):
    """Return the edges not implied by a longer path (transitive reduction)."""
    adj = collections.defaultdict(set)
    for src, dst in edges:
        adj[src].add(dst)
    keep = set()
    for src, dst in edges:
        seen = set()
        stack = [n for n in adj[src] if n != dst]
        found = False
        while stack and not found:
            cur = stack.pop()
            if cur in seen:
                continue
            seen.add(cur)
            if dst in adj[cur]:
                found = True
            stack.extend(adj[cur] - seen - {src})
        if not found:
            keep.add((src, dst))
    return keep


def describe_tags(present, alltags):
    present = sorted(present, key=tag_key)
    missing = sorted(set(alltags) - set(present), key=tag_key)
    if not missing:
        return ''
    if len(present) <= len(missing):
        return 'only ' + ', '.join(present)
    return 'not ' + ', '.join(missing)


def describe_presence(present, alltags):
    """
    present is a set of (platform, tag).  Return (platforms, text) where
    text names the platforms when there are some but not all of them, and
    describes python-version restrictions.  The text always carries the
    information, so the graphs never depend on color alone.
    """
    platforms = tuple(p for p in PLATFORM_NAMES if p in {p for p, _ in present})
    notes = []
    if len(platforms) < len(alltags):
        notes.append(' and '.join(PLATFORM_NAMES[p] for p in platforms) + ' only')
    for platform in platforms:
        text = describe_tags({t for p, t in present if p == platform},
                             alltags[platform])
        if text:
            notes.append(f'{PLATFORM_NAMES[platform]}: {text}')
    return platforms, '; '.join(notes)


def mermaid_id(name):
    if name.startswith(':'):
        return 'wheel_' + name[1:]
    return 'n_' + re.sub(r'[^A-Za-z0-9]', '_', name)


# Color is only a secondary cue: every platform difference is also written
# on the node, or drawn dashed and listed under the graph.  The colors are
# from the Okabe-Ito colorblind-safe palette.
CLASSDEFS = """\
  classDef all fill:#f3f4f6,stroke:#4b5563,color:#000
  classDef some fill:#ffffff,stroke:#4b5563,color:#000
  classDef linux fill:#cfe6f5,stroke:#0072b2,color:#000
  classDef macos fill:#fbe3b8,stroke:#e69f00,color:#000
  classDef windows fill:#f9f4b8,stroke:#a59a00,color:#000
  classDef wheel fill:#dcfce7,stroke:#15803d,color:#000"""
# Each platform presence also has its own node shape (mermaid syntax); the
# wheel's own binaries are stadiums.
SHAPES = {
    'all': ('["', '"]'),          # rectangle
    'linux': ('{{"', '"}}'),      # hexagon
    'macos': ('[/"', '"/]'),      # parallelogram
    'windows': ('[/"', '"\\]'),  # trapezoid
    'some': ('[["', '"]]'),       # rectangle with double sides
}
EDGE_COLORS = {'linux': '#0072b2', 'macos': '#e69f00', 'windows': '#a59a00',
               'some': '#4b5563'}


# Mermaid spacing (pixels); the defaults are 50 and 50.
SPACING = '%%{init: {"flowchart": {"nodeSpacing": 15, "rankSpacing": 30}}}%%'


def render_wheel(project, variants):
    """
    variants maps (platform, tag) -> (nodes, edges, runtime, requires,
    version, arch).  Return markdown for the wheel.
    """
    alltags = collections.defaultdict(list)
    for platform, tag in variants:
        alltags[platform].append(tag)
    nodepresence = collections.defaultdict(set)
    edgepresence = collections.defaultdict(set)
    kept = set()
    for key, (nodes, edges, runtime, _req, _ver, _arch) in variants.items():
        for node in nodes:
            nodepresence[node].add(key)
        full = set(edges) | {(':python', n) for n in runtime}
        for edge in full:
            kind = 'runtime' if edge[0] == ':python' else 'link'
            edgepresence[edge + (kind,)].add(key)
        kept |= reduce_edges(full)
    rows = collections.defaultdict(lambda: collections.defaultdict(set))
    for (platform, label), value in variants.items():
        rows[(platform, value[5])][value[4]].add(label.split(' ')[0])
    lines = ['| Platform | Version | Python tags |', '| --- | --- | --- |']
    for platform in PLATFORM_NAMES:
        for (plat, arch), byversion in sorted(rows.items()):
            if plat != platform:
                continue
            for version, tags in sorted(byversion.items(),
                                        key=lambda item: version_key(item[0])):
                lines.append('| %s | %s | %s |' % (
                    f'{PLATFORM_NAMES[platform]} {arch}'.strip(), version,
                    ', '.join(sorted(tags, key=tag_key))))
    lines.append('')
    libraries = [n for n in nodepresence if not n.startswith(':')]
    if not libraries:
        lines.append('This wheel bundles no native libraries.')
    else:
        lines.append('```mermaid')
        # The graphs are shallow and broad, so laying them out left to right
        # makes them tall rather than wide.
        lines.append(SPACING)
        lines.append('flowchart LR')
        lines.append(CLASSDEFS)
        lines.append(f'  subgraph wheelfiles["{project} wheel"]')
        for kind, label in WHEEL_KINDS.items():
            if ':' + kind in nodepresence:
                note = describe_presence(nodepresence[':' + kind], alltags)[1]
                if note:
                    label += f'<br/><small>{note}</small>'
                lines.append(f'    {mermaid_id(":" + kind)}(["{label}"]):::wheel')
        lines.append('  end')
        for node in sorted(libraries, key=str.lower):
            platforms, note = describe_presence(nodepresence[node], alltags)
            label = node
            if note:
                label += f'<br/><small>{note}</small>'
            if len(platforms) == len(alltags):
                cls = 'all'
            elif len(platforms) == 1:
                cls = platforms[0]
            else:
                cls = 'some'
            start, end = SHAPES[cls]
            lines.append(f'  {mermaid_id(node)}{start}{label}{end}:::{cls}')
        linkstyles = collections.defaultdict(list)
        partial = []
        idx = 0
        # Arrows point from a dependency to what uses it, so everything
        # flows into the wheel.  Edge labels widen the layout a lot, so
        # edges not on every platform are dashed and listed after the graph.
        for (user, dep, kind), present in sorted(
                edgepresence.items(), key=lambda item: (item[0][1], item[0][0])):
            if (user, dep) not in kept:
                continue
            platforms, note = describe_presence(present, alltags)
            if len(platforms) < len(alltags):
                partial.append((dep, user, note))
                note = ''
                linkstyles[platforms[0] if len(platforms) == 1 else 'some'].append(str(idx))
            if kind == 'runtime':
                note = 'runtime' + ('; ' + note if note else '')
            arrow = '-.->' if kind == 'runtime' else '-->'
            if note:
                arrow += f'|"{note}"|'
            lines.append(f'  {mermaid_id(dep)} {arrow} {mermaid_id(user)}')
            idx += 1
        for platform, idxs in sorted(linkstyles.items()):
            lines.append(f'  linkStyle {",".join(idxs)} stroke:{EDGE_COLORS[platform]},'
                         'stroke-width:2px,stroke-dasharray:6 4')
        lines.append('```')
        if partial:
            lines.append('')
            lines.append('<details><summary>Dashed edges (not on every platform)'
                         '</summary>')
            lines.append('')
            for dep, user, note in partial:
                name = (WHEEL_KINDS[user[1:]] if user.startswith(':') else user)
                lines.append(f'* {dep} → {name}: {note}')
            lines.append('')
            lines.append('</details>')
    requires = collections.defaultdict(set)
    for key, value in variants.items():
        for req in value[3]:
            requires[req].add(key)
    if requires:
        reqs = []
        for req, present in sorted(requires.items()):
            note = describe_presence(present, alltags)[1]
            reqs.append(f'`{req}`' + (f' ({note})' if note else ''))
        lines.append('')
        lines.append('Python requirements: ' + ', '.join(reqs) + '.')
    lines.append('')
    return '\n'.join(lines)


LEGEND = """\
Each graph is generated by `dependency_graphs.py` from the native
binaries inside the wheels: ELF `DT_NEEDED` entries for Linux wheels,
Mach-O load commands for macOS wheels, and PE imports for Windows wheels.
Libraries are grouped by the source project that builds them, and libraries
used from the system (libc, libstdc++, Apple frameworks, Windows DLLs, ...)
are left out, as is the MSVC runtime that the Windows wheels bundle.
Arrows point from a dependency to what uses it, so everything flows into
the wheel's own binaries (the green nodes on the right): `A --> B` means a
library of `B` links a library of `A`.  Arrows implied by a longer
path are dropped to keep the graphs readable.

```mermaid
%s
flowchart LR
%s
  W(["wheel's own binaries"]):::wheel
  A["on every platform of the wheel"]:::all
  L{{"libfoo<br/><small>Linux only</small>"}}:::linux
  M[/"libbar<br/><small>macOS only</small>"/]:::macos
  X[/"libbaz<br/><small>Windows only</small>"\\]:::windows
  S[["libqux<br/><small>Linux and Windows only</small>"]]:::some
  V["libquux<br/><small>Linux: only cp311, cp312</small>"]:::all
  A -.->|"runtime"| W
  L --> A
  M --> A
  X --> A
  S --> A
  V --> A
  linkStyle 1 stroke:#0072b2,stroke-width:2px,stroke-dasharray:6 4
  linkStyle 2 stroke:#e69f00,stroke-width:2px,stroke-dasharray:6 4
  linkStyle 3 stroke:#a59a00,stroke-width:2px,stroke-dasharray:6 4
  linkStyle 4 stroke:#4b5563,stroke-width:2px,stroke-dasharray:6 4
```

* Nothing in these graphs depends on color.  A library that is not on every
  platform the wheel is built for has those platforms written on it
  ("Linux only", "macOS and Windows only") and a shape for them: rectangle
  for every platform, hexagon for Linux only, parallelogram for macOS
  only, trapezoid for Windows only, and a double-sided rectangle for more
  than one platform.  The wheel's own binaries are stadiums (rounded
  ends).  A dashed arrow exists on only some platforms; the list under
  each graph names them.  Colors repeat this as an extra cue, from a
  colorblind-safe palette: blue for Linux, orange for macOS, yellow for
  Windows, white for more than one.
* A note naming python versions means the library or arrow is limited to
  those versions within that platform.
* A dotted `runtime` arrow goes from a library that nothing in the wheel
  links to the python package, which loads it at run time (ctypes, cffi's
  ABI mode, or dlopen).
""" % (SPACING, CLASSDEFS)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument(
        'directories', nargs='+',
        help='Directories of wheels, of any platforms and versions, such as '
        'a checkout of the wheelhouse branch.')
    parser.add_argument(
        '--exclude', action='append', default=[], metavar='PROJECT',
        help='A project to leave out.  May be repeated.')
    parser.add_argument(
        '--list-only', action='store_true',
        help='Only print which wheels would be used and what is skipped.')
    parser.add_argument(
        '--versions', default=os.path.join(
            os.path.dirname(os.path.abspath(__file__)), 'versions.txt'),
        help='versions.txt, used for project names.')
    parser.add_argument('-o', '--output', default='dependency_graphs.md')
    args = parser.parse_args()

    known = read_versions_names(args.versions)
    paths = []
    for directory in args.directories:
        paths.extend(os.path.join(directory, name)
                     for name in sorted(os.listdir(directory))
                     if name.endswith('.whl'))
    selected, report = select_wheels(paths, args.exclude)
    for line in report:
        print(line)
    wheels = collections.defaultdict(dict)
    for project, entries in sorted(selected.items()):
        # Python tags carry the architecture when a platform has several.
        arches = collections.defaultdict(set)
        for platform, arch, *_ in entries:
            arches[platform].add(arch)
        for platform, arch, tag, version, path in entries:
            label = f'{tag} {arch}' if len(arches[platform]) > 1 else tag
            print(f'Reading {os.path.basename(path)}' if not args.list_only
                  else f'Using {os.path.basename(path)}')
            if not args.list_only:
                wheels[project][(platform, label)] = analyze_wheel(
                    path, known) + (version, arch)
    if args.list_only:
        return
    out = ['# Wheel dependency graphs', '', LEGEND, '## Wheels', '']
    out.extend(f'* [{project}](#{project})' for project in sorted(wheels))
    out.append('')
    for project in sorted(wheels):
        out.append(f'## {project}')
        out.append('')
        out.append(render_wheel(project, wheels[project]))
    with open(args.output, 'w') as fptr:
        fptr.write('\n'.join(out).rstrip() + '\n')


if __name__ == '__main__':
    main()
