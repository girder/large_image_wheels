#!/usr/bin/env python
"""install_msvc.py - install MSVC (with ATL) and the Windows SDK into a
directory without administrator rights or the Visual Studio installer.

Adapted from manthey/utils install_msvc.py for the wheel pipeline: the
destination, the download cache, and the versions are parameters, and the
compiler environment is written to a JSON file (read by build_wheels.ps1)
instead of the user's registry.  This is what lets the toolchain live in
the download cache (unlike a VS Build Tools install, which lands in
Program Files, needs elevation, and would be paid on every sandbox run)
and lets the agent sandbox, where nobody is an administrator, build the
same way the build sandbox does.

The packages come straight from Microsoft's Visual Studio manifest: the
compiler's .vsix packages are zip files, and the SDK's .msi packages are
unpacked like an administrative install (msiexec /a) but by reading the
MSI tables with msi.dll and exploding the cabinets with expand.exe, so
the Windows Installer service is not needed.  Payload hashes from the
manifest are checked.  vctip.exe, the compiler's usage reporter, is
removed.

Usage:
  install_msvc.py --dest DIR --downloads DIR --env-json FILE
                  [--msvc-version 14.44.35207] [--sdk-version 10.0.26100.0]
                  [--env-only]

--env-only writes the environment for an existing --dest without
downloading anything.  Without version pins the newest in the manifest is
installed and the versions used are printed, so a pin can be recorded.

Using these tools is subject to the Visual Studio Build Tools license:
https://visualstudio.microsoft.com/license-terms/vs2022-ga-diagnosticbuildtools/
"""

import argparse
import concurrent.futures
import ctypes
import ctypes.wintypes
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

CHANNEL = 'https://aka.ms/vs/17/release/channel'
# Packages (Microsoft.VC.<version>.<suffix>) for x64 host and target.  MFC
# is deliberately not included (nothing in the dependency tree uses it);
# ATL headers are small and some cmake projects probe for them.
MSVC_PACKAGES = (
    'Tools.HostX64.TargetX64.base',
    'Tools.HostX64.TargetX64.Res.base',
    'CRT.Headers.base',
    'CRT.x64.Desktop.base',
    'CRT.x64.Store.base',
    'CRT.Redist.X64.base',
    'ATL.Headers.base',
    'ATL.X64.base',
)
SDK_MSIS = (
    'Windows SDK Desktop Headers x64-x86_en-us.msi',
    # The x64-named header MSIs only carry x64-specific files; the
    # architecture-neutral headers (most of um and shared) ship in the
    # x86-named packages, which an x64 install needs as well.
    'Windows SDK Desktop Headers x86-x86_en-us.msi',
    'Windows SDK Desktop Libs x64-x86_en-us.msi',
    'Windows SDK Desktop Tools x64-x86_en-us.msi',
    'Windows SDK OnecoreUap Headers x64-x86_en-us.msi',
    'Windows SDK OnecoreUap Headers x86-x86_en-us.msi',
    'Windows SDK for Windows Store Apps Headers-x86_en-us.msi',
    'Windows SDK for Windows Store Apps Headers OnecoreUap-x86_en-us.msi',
    'Windows SDK for Windows Store Apps Libs-x86_en-us.msi',
    'Windows SDK for Windows Store Apps Tools-x86_en-us.msi',
    'Universal CRT Headers Libraries and Sources-x86_en-us.msi',
)


def log(msg):
    print(f'install_msvc: {msg}', flush=True)


def get_json(url):
    with urllib.request.urlopen(url) as resp:
        return json.load(resp)


def version_key(text):
    return tuple(int(part) for part in text.split('.'))


def load_manifest():
    channel = get_json(CHANNEL)
    item = next(entry for entry in channel['channelItems']
                if entry['id'] == 'Microsoft.VisualStudio.Manifests.VisualStudio')
    return get_json(item['payloads'][0]['url'])['packages']


def pick_versions(packages, msvc_version, sdk_version):
    """Resolve the MSVC tools version and the SDK package id.

    With pins, the pinned versions must exist in the manifest (the
    manifest keeps every released toolset of the VS 2022 line, so a pin
    stays installable); without, the newest of each.
    """
    tools = re.compile(r'microsoft\.vc\.([\d.]+)\.tools\.hostx64\.targetx64\.base$')
    available = sorted({match.group(1) for match in
                        (tools.match(pkg['id'].lower()) for pkg in packages) if match},
                       key=version_key)
    if msvc_version:
        if msvc_version not in available:
            sys.exit(f'install_msvc: MSVC {msvc_version} is not in the manifest '
                     f'(available: {", ".join(available)})')
        msvc = msvc_version
    else:
        msvc = available[-1]
    sdk_component = re.compile(r'microsoft\.visualstudio\.component\.windows1[01]sdk\.(\d+)$')
    components = [(int(match.group(1)), pkg) for pkg in packages
                  for match in [sdk_component.match(pkg['id'].lower())] if match]
    if sdk_version:
        # Either the full 10.0.<build>.0 or the bare build number (which is
        # what versions.txt records).
        parts = sdk_version.split('.')
        build = int(parts[2] if len(parts) >= 3 else parts[0])
        chosen = [pkg for number, pkg in components if number == build]
        if not chosen:
            sys.exit(f'install_msvc: Windows SDK {sdk_version} is not in the manifest '
                     f'(available builds: {sorted(number for number, _ in components)})')
        sdk_package = next(iter(chosen[0]['dependencies']))
    else:
        sdk_package = next(iter(max(components, key=lambda entry: entry[0])[1]['dependencies']))
    return msvc, sdk_package


def msvc_payloads(packages, version):
    wanted = {f'microsoft.vc.{version}.{suffix}'.lower() for suffix in MSVC_PACKAGES}
    payloads = []
    for pkg in packages:
        if pkg['id'].lower() in wanted and pkg.get('language') in (None, 'neutral', 'en-US'):
            payloads.extend(pkg.get('payloads', []))
    found = {pkg['id'].lower() for pkg in packages if pkg['id'].lower() in wanted}
    if found != wanted:
        sys.exit(f'install_msvc: missing packages: {sorted(wanted - found)}')
    return payloads


def download(payload, folder):
    path = folder / Path(payload['fileName'].replace('\\', '/')).name
    digest = payload['sha256'].lower()
    if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == digest:
        return path
    partial = path.with_name(path.name + '.partial')
    sha = hashlib.sha256()
    with urllib.request.urlopen(payload['url']) as resp, open(partial, 'wb') as fp:
        while chunk := resp.read(1 << 20):
            sha.update(chunk)
            fp.write(chunk)
    if sha.hexdigest() != digest:
        partial.unlink()
        msg = f'sha256 mismatch for {payload["fileName"]}'
        raise RuntimeError(msg)
    partial.replace(path)
    return path


def download_all(payloads, folder):
    folder.mkdir(parents=True, exist_ok=True)
    total = sum(payload.get('size', 0) for payload in payloads)
    log(f'downloading {len(payloads)} files ({total / 2 ** 20:.0f} MB; cached files are kept)')
    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        return list(pool.map(lambda payload: download(payload, folder), payloads))


def long_name(name):
    """The long form of an MSI 'short|long' name."""
    return name.split('|')[-1]


def msi_string(record, field):
    """A field of an MSI record as a string."""
    msi = ctypes.windll.msi
    buffer = ctypes.create_unicode_buffer(256)
    size = ctypes.wintypes.DWORD(len(buffer))
    error = msi.MsiRecordGetStringW(record, field, buffer, ctypes.byref(size))
    while error == 234:  # ERROR_MORE_DATA
        buffer = ctypes.create_unicode_buffer(size.value + 1)
        size.value = len(buffer)
        error = msi.MsiRecordGetStringW(record, field, buffer, ctypes.byref(size))
    if error != 0:
        sys.exit(f'install_msvc: MsiRecordGetStringW failed: {error}')
    return buffer.value


def msi_rows(database, query):
    """All rows of a query against an open MSI database, as string lists."""
    msi = ctypes.windll.msi
    view = ctypes.wintypes.HANDLE()
    if msi.MsiDatabaseOpenViewW(database, query, ctypes.byref(view)) != 0:
        sys.exit(f'install_msvc: MsiDatabaseOpenViewW failed: {query}')
    if msi.MsiViewExecute(view, None) != 0:
        msi.MsiCloseHandle(view)
        sys.exit(f'install_msvc: MsiViewExecute failed: {query}')
    rows = []
    while True:
        record = ctypes.wintypes.HANDLE()
        error = msi.MsiViewFetch(view, ctypes.byref(record))
        if error == 259:  # ERROR_NO_MORE_ITEMS
            break
        if error != 0:
            msi.MsiCloseHandle(view)
            sys.exit(f'install_msvc: MsiViewFetch failed: {error}')
        rows.append([msi_string(record, field) for field in
                     range(1, msi.MsiRecordGetFieldCount(record) + 1)])
        msi.MsiCloseHandle(record)
    msi.MsiCloseHandle(view)
    return rows


def msi_file_plan(msi_path, root):
    """Map each cabinet of an MSI to its [(member name, target path), ...].

    This replicates how an administrative install (msiexec /a) unpacks a
    package: the directories are resolved through the Directory table
    relative to TARGETDIR (directory properties set by AppSearch are not
    part of the admin sequence), and the cabinet members, which are named
    after the File table keys, are renamed to their FileName column value.
    """
    msi = ctypes.windll.msi
    database = ctypes.wintypes.HANDLE()
    if msi.MsiOpenDatabaseW(str(msi_path), 0, ctypes.byref(database)) != 0:
        sys.exit(f'install_msvc: cannot open {msi_path}')
    media = sorted((int(sequence), cabinet) for sequence, cabinet in
                   msi_rows(database, 'SELECT `LastSequence`,`Cabinet` FROM `Media`')
                   if cabinet)
    files = [row for row in msi_rows(
        database, 'SELECT `File`,`Component_`,`FileName`,`Sequence` FROM `File`') if row[3]]
    component_dir = {row[0]: row[1] for row in msi_rows(
        database, 'SELECT `Component`,`Directory_` FROM `Component`')}
    parents = {row[0]: (row[1], row[2]) for row in msi_rows(
        database, 'SELECT `Directory`,`Directory_Parent`,`DefaultDir` FROM `Directory`')}
    msi.MsiCloseHandle(database)

    def resolve(directory, seen=()):
        if directory == 'TARGETDIR':
            return root
        if directory in seen:
            sys.exit(f'install_msvc: directory loop at {directory} in {msi_path}')
        parent, default = parents[directory]
        base = resolve(parent, seen + (directory,))
        # An administrative image uses the source part of a
        # "target:source" default directory.
        name = default.split(':')[-1]
        if name in ('', '.'):
            return base
        return base / long_name(name)

    plan = {}
    for file_key, component, file_name, sequence in files:
        cabinet = next((cab for last, cab in media if last >= int(sequence)), None)
        if cabinet is None:
            sys.exit(f'install_msvc: no cabinet covers {file_name} in {msi_path}')
        target = resolve(component_dir[component]) / long_name(file_name)
        plan.setdefault(cabinet, []).append((file_key, target))
    return plan


def extract_vsix(path, dest):
    with zipfile.ZipFile(path) as zf:
        for info in zf.infolist():
            name = urllib.parse.unquote(info.filename)
            if not name.startswith('Contents/') or name.endswith('/'):
                continue
            target = dest / name[len('Contents/'):]
            target.parent.mkdir(parents=True, exist_ok=True)
            with zf.open(info) as src, open(target, 'wb') as dst:
                shutil.copyfileobj(src, dst)


def install_sdk(packages, sdk_package, dest, downloads):
    pkg = next(pkg for pkg in packages if pkg['id'] == sdk_package)
    by_name = {payload['fileName'].replace('\\', '/').split('/')[-1]: payload
               for payload in pkg['payloads']}
    missing = [name for name in SDK_MSIS if name not in by_name]
    if missing:
        sys.exit(f'install_msvc: {sdk_package} lacks {missing}')
    folder = downloads / 'sdk'
    msis = download_all([by_name[name] for name in SDK_MSIS], folder)
    cabs = set()
    for msi in msis:
        cabs.update(name.decode() for name in re.findall(rb'[0-9a-f]{32}\.cab', msi.read_bytes()))
    download_all([by_name[name] for name in sorted(cabs) if name in by_name], folder)
    expand = Path(os.environ['SYSTEMROOT']) / 'System32' / 'expand.exe'
    for msi in msis:
        log(f'unpacking {msi.name}')
        for cabinet, entries in msi_file_plan(msi, dest).items():
            staging = dest / '_extract' / f'{msi.stem}-{Path(cabinet).stem}'
            staging.mkdir(parents=True, exist_ok=True)
            subprocess.run([str(expand), '-F:*', str(folder / cabinet), str(staging)],
                           check=True, stdout=subprocess.DEVNULL)
            for member, target in entries:
                source = staging / member
                if not source.exists():
                    sys.exit(f'install_msvc: {cabinet} lacks {member}')
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(source), target)
            shutil.rmtree(staging)
    shutil.rmtree(dest / '_extract', ignore_errors=True)


def latest_dir(parent, required=None):
    dirs = [path for path in parent.iterdir()
            if path.is_dir() and re.fullmatch(r'[\d.]+', path.name)]
    if required:
        dirs = [path for path in dirs if (path / required).exists()]
    if not dirs:
        sys.exit(f'install_msvc: nothing found in {parent}')
    return max(dirs, key=lambda path: version_key(path.name))


def build_environment(dest):
    vc = latest_dir(dest / 'VC' / 'Tools' / 'MSVC')
    kits = dest / 'Windows Kits' / '10'
    sdkv = latest_dir(kits / 'Include', 'um').name
    paths = [vc / 'bin' / 'Hostx64' / 'x64', kits / 'bin' / sdkv / 'x64']
    # Runtime DLLs (CRT) so that dynamically linked programs run during
    # the build (the wheels bundle their own vcruntime through delvewheel).
    redist = dest / 'VC' / 'Redist' / 'MSVC'
    if redist.exists():
        paths += sorted(path for path in redist.glob('*/x64/*') if path.is_dir())
    include = [vc / 'include', vc / 'atlmfc' / 'include'] + [
        kits / 'Include' / sdkv / sub for sub in ('ucrt', 'shared', 'um', 'winrt', 'cppwinrt')]
    lib = [vc / 'lib' / 'x64', vc / 'atlmfc' / 'lib' / 'x64',
           kits / 'Lib' / sdkv / 'ucrt' / 'x64', kits / 'Lib' / sdkv / 'um' / 'x64']
    env = {
        'INCLUDE': ';'.join(str(path) for path in include),
        'LIB': ';'.join(str(path) for path in lib),
        'LIBPATH': ';'.join(str(path) for path in lib[:2]),
        'VCToolsInstallDir': f'{vc}\\',
        'VCToolsVersion': vc.name,
        'WindowsSdkDir': f'{kits}\\',
        'WindowsSDKVersion': f'{sdkv}\\',
        'Platform': 'x64',
        # setuptools then uses this compiler from the environment instead of
        # looking for a Visual Studio installation.
        'DISTUTILS_USE_SDK': '1',
        'MSSdk': '1',
        'VSCMD_SKIP_SENDTELEMETRY': '1',
    }
    return env, [str(path) for path in paths], vc.name, sdkv


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--dest', required=True, help='install directory')
    parser.add_argument('--downloads', required=True,
                        help='download cache (manifest payloads, kept for later runs)')
    parser.add_argument('--env-json', required=True,
                        help='where to write {"env": {...}, "paths": [...], '
                             '"msvc": ..., "sdk": ...}')
    parser.add_argument('--msvc-version', default='',
                        help='MSVC tools version to install (default: newest)')
    parser.add_argument('--sdk-version', default='',
                        help='Windows SDK version to install, e.g. 10.0.26100.0 '
                             '(default: newest)')
    parser.add_argument('--env-only', action='store_true',
                        help='only write the environment for an existing --dest')
    args = parser.parse_args()
    if sys.platform != 'win32':
        sys.exit('install_msvc: this installs the Windows compiler and must run on Windows')
    dest = Path(args.dest)
    downloads = Path(args.downloads)
    if not args.env_only:
        log('reading the Visual Studio manifest')
        packages = load_manifest()
        msvc, sdk_package = pick_versions(packages, args.msvc_version, args.sdk_version)
        log(f'MSVC {msvc} with ATL, and {sdk_package}, into {dest}')
        log('use is subject to the Visual Studio Build Tools license')
        if dest.exists():
            shutil.rmtree(dest)
        dest.mkdir(parents=True)
        for vsix in download_all(msvc_payloads(packages, msvc), downloads / 'msvc'):
            log(f'extracting {vsix.name}')
            extract_vsix(vsix, dest)
        install_sdk(packages, sdk_package, dest, downloads)
        for vctip in dest.rglob('vctip.exe'):
            vctip.unlink()
    env, paths, vc_version, sdk_version = build_environment(dest)
    # The pins are recorded as given so a caller can tell whether an
    # existing install is the one versions.txt asks for (the manifest's
    # package version, 14.44.17.14, differs from the toolset's own build
    # number, 14.44.35207, which is what the install directory is named).
    with open(args.env_json, 'w') as fp:
        json.dump({'env': env, 'paths': paths, 'msvc': vc_version, 'sdk': sdk_version,
                   'pins': {'msvc': args.msvc_version, 'sdk': args.sdk_version}},
                  fp, indent=2)
    log(f'MSVC {vc_version} and Windows SDK {sdk_version} at {dest}; '
        f'environment written to {args.env_json}')


if __name__ == '__main__':
    main()
