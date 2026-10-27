#!/usr/bin/env python
"""check_wheels.py - windows-specific wheel checks, run inside a venv that
has the wheels installed (the counterpart of the macos harness's
per-package checks in test_via_tart.sh; the shared test/test_script.sh is
the functional suite and runs separately).

For each package that is installed, this verifies the isolation
properties the pipeline exists for:

- the library the package loads is the copy bundled in the wheel's
  <dist>.libs directory (resolved through the running process's module
  list, not through what the package claims), and
- the bundled command line tools run through their console-script
  wrappers and find their bundled DLLs.

Usage: python check_wheels.py [package ...]   (default: every known
package that is importable).  Exit status is nonzero on any failure; every
check prints one line, "ok: ..." or "FAIL: ...".

The caller is responsible for the environment: run it with a scrubbed
PATH (system directories plus the venv only) so a stray directory on PATH
cannot shadow a bundled DLL -- there is no rpath on Windows, and a
same-named DLL earlier on PATH is the one way a system library could win.
"""

import ctypes
import ctypes.wintypes
import os
import subprocess
import sys
import tempfile

failures = 0


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
    """The loaded module whose basename starts with <stem>, if it is in a
    <libs_dir_name> directory (delvewheel mangles names to
    <stem>-<hash>.dll, so a prefix match is the lookup)."""
    hits = [path for path in loaded_modules()
            if os.path.basename(path).lower().startswith(stem.lower())]
    bundled = [path for path in hits
               if os.path.basename(os.path.dirname(path)).lower() == libs_dir_name.lower()]
    return hits, bundled


def run_tool(name, args):
    exe = os.path.join(os.path.dirname(sys.executable), name + '.exe')
    proc = subprocess.run([exe] + args, capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


def check_pylibtiff():
    import libtiff  # noqa: F401
    from libtiff import TIFF

    hits, bundled = loaded_from_libs('tiff', 'pylibtiff.libs')
    report(bool(bundled) and len(hits) == len(bundled),
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
               f'bundled tiffinfo runs (exit {code}): {out.strip().splitlines()[:1]}')
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


CHECKS = {
    'pylibtiff': check_pylibtiff,
}


def main():
    wanted = sys.argv[1:] or list(CHECKS)
    for name in wanted:
        if name not in CHECKS:
            report(False, f'no checks for {name}')
            continue
        try:
            CHECKS[name]()
        except Exception as exc:
            report(False, f'{name}: {type(exc).__name__}: {exc}')
    print(f'{failures} failure(s)', flush=True)
    sys.exit(1 if failures else 0)


if __name__ == '__main__':
    main()
