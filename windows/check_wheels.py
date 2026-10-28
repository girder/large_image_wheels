#!/usr/bin/env python
"""check_wheels.py - windows-specific wheel checks, run inside a venv that
has the wheels installed (the counterpart of the macos harness's
per-package checks in test_via_tart.sh; the shared test/test_script.sh is
the functional suite and runs separately).

For each package that is installed, this verifies the isolation
properties the pipeline exists for:

- every executable file our wheel provides (.pyd, .dll, .exe in the
  package and in its <dist>.libs directory) imports only DLLs that are in
  the wheel, python's own DLL, Windows API sets, or DLLs present in the
  system directory -- the counterpart of the macos otool audit, read from
  the PE import tables, so even a tool nobody runs is checked;
- the library the package loads is the copy bundled in the wheel's
  <dist>.libs directory (resolved through the running process's module
  list, not through what the package claims);
- the bundled command line tools run through their console-script
  wrappers, and run by path (<package>/bin/<tool>.exe, the launcher) with
  nothing but the system directories on PATH -- so neither python's
  directory nor anything else installed supplies a DLL to them.

Usage: python check_wheels.py [package ...]   (default: every known
package that is importable).  Exit status is nonzero on any failure; every
check prints one line, "ok: ..." or "FAIL: ...".

The caller is responsible for the environment: run it with a scrubbed
PATH (system directories plus the venv only) so a stray directory on PATH
cannot shadow a bundled DLL -- there is no rpath on Windows, and a
same-named DLL earlier on PATH is the one way a system library could win.
The system-directory allowance in the import audit is what the machine
running the check has in System32; in a fresh Windows Sandbox that is the
baseline every Windows has.
"""

import ctypes
import ctypes.wintypes
import os
import re
import struct
import subprocess
import sys
import tempfile

failures = 0

SYSTEM_DIRS = [os.path.join(os.environ.get('SystemRoot', r'C:\Windows'), 'System32')]


def report(ok, message):
    global failures
    print(('ok: ' if ok else 'FAIL: ') + message, flush=True)
    if not ok:
        failures += 1


def loaded_modules():
    """Paths of every module loaded in this process (EnumProcessModules)."""
    psapi = ctypes.windll.psapi
    kernel32 = ctypes.windll.kernel32
    # Explicit signatures: without them ctypes passes the 64-bit
    # pseudo-handle and module handles as 32-bit ints.
    kernel32.GetCurrentProcess.restype = ctypes.wintypes.HANDLE
    psapi.EnumProcessModules.argtypes = [
        ctypes.wintypes.HANDLE, ctypes.POINTER(ctypes.wintypes.HMODULE),
        ctypes.wintypes.DWORD, ctypes.POINTER(ctypes.wintypes.DWORD)]
    psapi.EnumProcessModules.restype = ctypes.wintypes.BOOL
    psapi.GetModuleFileNameExW.argtypes = [
        ctypes.wintypes.HANDLE, ctypes.wintypes.HMODULE, ctypes.wintypes.LPWSTR,
        ctypes.wintypes.DWORD]
    psapi.GetModuleFileNameExW.restype = ctypes.wintypes.DWORD
    process = kernel32.GetCurrentProcess()
    count = 4096
    while True:
        handles = (ctypes.wintypes.HMODULE * count)()
        needed = ctypes.wintypes.DWORD()
        if not psapi.EnumProcessModules(process, handles, ctypes.sizeof(handles),
                                        ctypes.byref(needed)):
            raise OSError(f'EnumProcessModules failed: {ctypes.GetLastError()}')
        found = needed.value // ctypes.sizeof(ctypes.wintypes.HMODULE)
        if found <= count:
            break
        count = found
    paths = []
    for handle in handles[:found]:
        buffer = ctypes.create_unicode_buffer(32768)
        psapi.GetModuleFileNameExW(process, ctypes.wintypes.HMODULE(handle), buffer,
                                   len(buffer))
        paths.append(buffer.value)
    return paths


def loaded_from_libs(stem, libs_dir_name):
    """The loaded modules whose basename starts with <stem> (delvewheel
    mangles names to <stem>-<hash>.dll, so a prefix match is the lookup):
    all of them, the ones in the <libs_dir_name> directory, and the ones
    outside any wheel's .libs directory.  Several of our wheels may bundle
    the same library (identical content gets the same mangled name), and
    a full-path load of each is a separate module, so a copy in another
    wheel's .libs directory is legitimate; a copy anywhere else means a
    system or third-party library won the load."""
    hits = [path for path in loaded_modules()
            if os.path.basename(path).lower().startswith(stem.lower())]
    bundled = [path for path in hits
               if os.path.basename(os.path.dirname(path)).lower() == libs_dir_name.lower()]
    foreign = [path for path in hits
               if not os.path.basename(os.path.dirname(path)).lower().endswith('.libs')]
    return hits, bundled, foreign


def pe_imports(path):
    """The DLL names in a PE file's import directory (None if the file is
    not a PE image).  Delay-load imports are not included: delvewheel
    leaves msvcp140's delay-load of concrt140 alone on purpose."""
    with open(path, 'rb') as fptr:
        data = fptr.read()
    if data[:2] != b'MZ':
        return None
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    if data[pe:pe + 4] != b'PE\0\0':
        return None
    coff = pe + 4
    nsections, opt_size = struct.unpack_from('<H', data, coff + 2)[0], \
        struct.unpack_from('<H', data, coff + 16)[0]
    opt = coff + 20
    magic = struct.unpack_from('<H', data, opt)[0]
    if magic == 0x20b:
        datadir = opt + 112
    elif magic == 0x10b:
        datadir = opt + 96
    else:
        raise ValueError('unknown optional header magic 0x%x' % magic)
    import_rva = struct.unpack_from('<I', data, datadir + 8)[0]
    sections = []
    table = opt + opt_size
    for index in range(nsections):
        vsize, vaddr, rawsize, rawptr = struct.unpack_from('<IIII', data, table + 40 * index + 8)
        sections.append((vaddr, max(vsize, rawsize), rawptr))

    def offset(rva):
        for vaddr, size, raw in sections:
            if vaddr <= rva < vaddr + size:
                return rva - vaddr + raw
        raise ValueError('rva 0x%x is in no section' % rva)

    names = []
    if import_rva:
        pos = offset(import_rva)
        while True:
            descriptor = struct.unpack_from('<IIIII', data, pos)
            if not any(descriptor):
                break
            start = offset(descriptor[3])
            names.append(data[start:data.index(b'\0', start)].decode('ascii', 'replace'))
            pos += 20
    return names


def audit_imports(roots, libs_dir):
    """Every PE file under the given roots may import only: a file in its
    own directory, a file in libs_dir, python's own DLL, a Windows API set,
    or a DLL in the system directory.  Anything else would resolve through
    PATH at best -- a system or third-party library winning the load -- and
    fail at worst."""
    bad = 0
    files = 0
    for root in roots:
        for dirpath, _, filenames in os.walk(root):
            for filename in filenames:
                if not filename.lower().endswith(('.pyd', '.dll', '.exe')):
                    continue
                path = os.path.join(dirpath, filename)
                try:
                    imports = pe_imports(path)
                except Exception as exc:
                    report(False, f'cannot read the imports of {path}: {exc}')
                    bad += 1
                    continue
                if imports is None:
                    continue
                files += 1
                for name in imports:
                    low = name.lower()
                    if low.startswith(('api-ms-win-', 'ext-ms-')):
                        continue
                    if re.match(r'python3\d*t?\.dll$', low):
                        continue
                    if os.path.exists(os.path.join(dirpath, name)):
                        continue
                    if os.path.exists(os.path.join(libs_dir, name)):
                        continue
                    if any(os.path.exists(os.path.join(sysdir, name)) for sysdir in SYSTEM_DIRS):
                        continue
                    report(False, f'FORBIDDEN import: {path} -> {name}')
                    bad += 1
    report(bad == 0 and files > 0,
           f'import audit of {files} PE files under {", ".join(roots)}')


def scrubbed_env():
    """An environment whose PATH holds only the system directories: a tool
    run with it can find DLLs only beside itself (or where the launcher
    puts them)."""
    env = dict(os.environ)
    env['PATH'] = os.pathsep.join([SYSTEM_DIRS[0], os.path.dirname(SYSTEM_DIRS[0])])
    return env


def run_tool(name, args, env=None):
    """Run the console script <name> of the venv.  The file must exist
    under exactly that name: CreateProcess would also find a misnamed
    <name>.exe.exe (which a console script named "<tool>.exe" produces)."""
    exe = os.path.join(os.path.dirname(sys.executable), name + '.exe')
    if not os.path.exists(exe):
        return 127, f'no console script {exe}'
    proc = subprocess.run([exe] + args, capture_output=True, text=True, env=env)
    return proc.returncode, proc.stdout + proc.stderr


def run_path(exe, args, env=None):
    proc = subprocess.run([exe] + args, capture_output=True, text=True, env=env)
    return proc.returncode, proc.stdout + proc.stderr


def check_pylibtiff(package_dir, libs_dir):
    from libtiff import TIFF

    hits, bundled, foreign = loaded_from_libs('tiff', os.path.basename(libs_dir))
    report(bool(bundled) and not foreign,
           f'pylibtiff loads its bundled libtiff: {hits}')
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, 'check.tif')
        import numpy
        data = (numpy.arange(64 * 48, dtype=numpy.uint16).reshape(48, 64) * 7) % 65535
        tif = TIFF.open(path, mode='w')
        tif.write_image(data, compression='lzw')
        tif.close()
        tif = TIFF.open(path, mode='r')
        back = tif.read_image()
        tif.close()
        report(numpy.array_equal(data, back), 'pylibtiff lzw round trip')
        code, out = run_tool('tiffinfo', [path])
        report(code == 0 and 'Image Width: 64' in out,
               f'bundled tiffinfo runs as a console script (exit {code}): {out.strip().splitlines()[:1]}')
        # By path, with only the system directories on PATH: the launcher
        # in libtiff/bin must find the real tool and every DLL it needs
        # (libtiff's and the VC runtime) in pylibtiff.libs by itself.
        launcher = os.path.join(package_dir, 'bin', 'tiffinfo.exe')
        code, out = run_path(launcher, [path], env=scrubbed_env())
        report(code == 0 and 'Image Width: 64' in out,
               f'bundled tiffinfo runs by path with a bare PATH (exit {code}): {out.strip().splitlines()[:1]}')
        # Compression support that the feature assertions promised (webp
        # only encodes RGB/RGBA).
        rgb = numpy.dstack([data.astype(numpy.uint8)] * 3)
        for compression in ('zstd', 'webp', 'jpeg', 'deflate'):
            try:
                tif = TIFF.open(os.path.join(tmp, compression + '.tif'), mode='w')
                tif.write_image(rgb, compression=compression, write_rgb=True)
                tif.close()
                report(True, f'pylibtiff writes {compression}')
            except Exception as exc:
                report(False, f'pylibtiff writes {compression}: {exc}')


def check_glymur(package_dir, libs_dir):
    import glymur
    import numpy

    hits, bundled, foreign = loaded_from_libs('openjp2', os.path.basename(libs_dir))
    report(bool(bundled) and not foreign,
           f'glymur loads its bundled openjp2: {hits}')
    version = glymur.version.openjpeg_version
    report(bool(version) and version.startswith('2.'), f'openjpeg version {version}')
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, 'check.jp2')
        data = (numpy.arange(64 * 48 * 3, dtype=numpy.uint32).reshape(48, 64, 3) % 251
                ).astype(numpy.uint8)
        glymur.Jp2k(path, data=data)
        back = glymur.Jp2k(path)[:]
        report(numpy.array_equal(data, back), 'glymur jp2 write/read round trip (lossless)')
        nemo = glymur.Jp2k(glymur.data.nemo())
        report(nemo.shape == (1456, 2592, 3), f'bundled nemo.jp2 reads: shape {nemo.shape}')
        code, out = run_tool('opj_dump', ['-i', path])
        report(code == 0 and 'x1=64' in out.replace(' ', ''),
               f'bundled opj_dump runs as a console script (exit {code})')
        launcher = os.path.join(package_dir, 'bin', 'opj_dump.exe')
        code, out = run_path(launcher, ['-i', path], env=scrubbed_env())
        report(code == 0 and 'x1=64' in out.replace(' ', ''),
               f'bundled opj_dump runs by path with a bare PATH (exit {code})')
        code, out = run_tool('djpeg', ['-version'])
        report(code == 0 and 'libjpeg-turbo' in out,
               f'bundled djpeg runs as a console script (exit {code}): {out.strip().splitlines()[:1]}')


# package -> (import name, <dist>.libs directory name, package check)
PACKAGES = {
    'pylibtiff': ('libtiff', 'pylibtiff.libs', check_pylibtiff),
    'glymur': ('glymur', 'glymur.libs', check_glymur),
}


def check_package(name):
    module_name, libs_name, check = PACKAGES[name]
    try:
        module = __import__(module_name)
    except ImportError as exc:
        report(False, f'{name}: import {module_name} failed: {exc}')
        return
    package_dir = os.path.dirname(os.path.abspath(module.__file__))
    libs_dir = os.path.join(os.path.dirname(package_dir), libs_name)
    report(os.path.isdir(libs_dir), f'{name}: bundled library directory {libs_dir}')
    audit_imports([package_dir, libs_dir], libs_dir)
    check(package_dir, libs_dir)


def main():
    wanted = sys.argv[1:]
    if not wanted:
        # Every known package that is installed.
        for name, (module_name, _, _) in PACKAGES.items():
            try:
                __import__(module_name)
            except ImportError:
                continue
            wanted.append(name)
        if not wanted:
            report(False, 'no known package is installed')
    for name in wanted:
        if name not in PACKAGES:
            report(False, f'no checks for {name}')
            continue
        try:
            check_package(name)
        except Exception as exc:
            report(False, f'{name}: {type(exc).__name__}: {exc}')
    print(f'{failures} failure(s)', flush=True)
    sys.exit(1 if failures else 0)


if __name__ == '__main__':
    main()
