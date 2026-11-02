#!/usr/bin/env python3
"""Command-line tools for opencode's shell on the phone (owner, 2026-11-02: "just add, so the agent will be complete").

Android lets an app execute only files in its nativeLibraryDir, and has no musl loader at /lib. So the tools come from
Alpine's arm64 packages (the same musl the opencode engine runs on) and are split in two:
  - every ELF (programs and shared libraries) -> jniLibs/arm64-v8a/libsmx_<n>.so (Android extracts it to
    nativeLibraryDir, where it may run),
  - everything else (Python's library, git's templates, CA certificates, scripts) -> one zip, shipped as
    jniLibs/arm64-v8a/libsmx_data.so.
The zip carries manifest.tsv (the root path of each ELF and its libsmx name, plus the package's symlinks) and bin.tsv
(each command name, the file in the root that runs it, and a busybox applet when it is one). android_native/OpenCode.kt
unpacks the zip into files/oc/root, links each ELF back into place and puts one launcher link per command in
files/oc/bin (tools/oc_tools/launch.c, shipped as libsmx_launch.so).

Usage: bundle.py <jniLibs dir> <launcher binary>
"""
import hashlib
import io
import os
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.request
import zipfile

ALPINE = os.environ.get('OC_ALPINE', 'v3.22')
ARCH = 'aarch64'
REPOS = ['main', 'community']
WANT = ['busybox', 'ssl_client', 'curl', 'git', 'git-init-template', 'python3', 'py3-pip', 'ripgrep', 'jq', 'ca-certificates-bundle']
# Already on the phone with the engine (musl's loader is libocld.so and stands in for libc.musl).
SKIP = {'musl', 'musl-utils', 'scanelf', 'apk-tools', 'alpine-baselayout', 'alpine-baselayout-data', 'alpine-keys',
        'busybox-binsh', 'libc-utils', 'tzdata', 'perl', 'perl-error', 'perl-git', 'git-perl'}
# busybox commands put on the shell's PATH (Android's toybox lacks these or has weaker ones).
APPLETS = ['wget', 'nc', 'nslookup', 'ping', 'traceroute', 'telnet', 'whois', 'ftpget', 'ftpput', 'ifconfig', 'ip',
           'netstat', 'route', 'arp', 'unzip', 'tar', 'gzip', 'gunzip', 'zcat', 'xz', 'unxz', 'xzcat', 'bzip2',
           'bunzip2', 'vi', 'less', 'awk', 'diff', 'patch', 'xxd', 'hexdump', 'strings', 'bc', 'dc', 'httpd']
# Left out of the zip: big and never needed on a phone.
DROP = re.compile(r'(^|/)(__pycache__|test|tests|idlelib|tkinter|turtledemo|lib2to3|ensurepip)(/|$)|'
                  r'^usr/share/(man|doc|info|locale|gitweb|bash-completion|zsh)/|\.a$|\.pyc$|^usr/include/')


def fetch(url):
    with urllib.request.urlopen(url, timeout=120) as r:
        return r.read()


def index():
    pkgs = {}
    provides = {}
    for repo in REPOS:
        base = f'https://dl-cdn.alpinelinux.org/alpine/{ALPINE}/{repo}/{ARCH}'
        raw = fetch(f'{base}/APKINDEX.tar.gz')
        with tarfile.open(fileobj=io.BytesIO(raw)) as t:
            text = t.extractfile('APKINDEX').read().decode()
        for block in text.split('\n\n'):
            f = {}
            for line in block.splitlines():
                if len(line) > 2 and line[1] == ':':
                    f[line[0]] = line[2:]
            if 'P' not in f:
                continue
            f['base'] = base
            pkgs.setdefault(f['P'], f)
            for p in f.get('p', '').split():
                provides.setdefault(re.split(r'[=<>~]', p)[0], f['P'])
    return pkgs, provides


def closure(pkgs, provides):
    out, todo = [], list(WANT)
    while todo:
        name = todo.pop()
        if name in SKIP or name in out:
            continue
        if name not in pkgs:
            real = provides.get(name)
            if not real:
                print(f'warning: nothing provides {name}', file=sys.stderr)
                continue
            name = real
            if name in SKIP or name in out:
                continue
        out.append(name)
        for d in pkgs[name].get('D', '').split():
            if d.startswith('!'):
                continue
            todo.append(re.split(r'[=<>~]', d)[0])
    return sorted(out)


def main():
    jni, launcher = sys.argv[1], sys.argv[2]
    os.makedirs(jni, exist_ok=True)
    pkgs, provides = index()
    names = closure(pkgs, provides)
    root = '/tmp/smx-root'
    shutil.rmtree(root, ignore_errors=True)
    os.makedirs(root)
    for n in names:
        p = pkgs[n]
        url = f"{p['base']}/{n}-{p['V']}.apk".replace('+', '%2B')
        print(f'package {n}-{p["V"]}')
        open('/tmp/smx.apk', 'wb').write(fetch(url))
        # An .apk is concatenated gzip streams; GNU tar reads the data part and warns about the rest.
        subprocess.run(['tar', 'xzf', '/tmp/smx.apk', '-C', root, '--warning=no-unknown-keyword'],
                       stderr=subprocess.DEVNULL)
    for junk in ('.PKGINFO', '.pre-install', '.post-install', '.trigger', '.post-upgrade', '.pre-upgrade', '.post-deinstall'):
        p = os.path.join(root, junk)
        if os.path.exists(p):
            os.remove(p)
    for f in os.listdir(root):
        if f.startswith('.SIGN'):
            os.remove(os.path.join(root, f))

    manifest, k, seen = [], 0, {}
    zbuf = io.BytesIO()
    z = zipfile.ZipFile(zbuf, 'w', zipfile.ZIP_DEFLATED, compresslevel=9)
    for dirpath, dirs, files in os.walk(root):
        dirs.sort()
        for f in sorted(files):
            full = os.path.join(dirpath, f)
            rel = os.path.relpath(full, root)
            if DROP.search(rel):
                continue
            if os.path.islink(full):
                t = os.readlink(full)
                if t.startswith('/'):
                    t = os.path.relpath(os.path.join(root, t.lstrip('/')), os.path.dirname(full))
                manifest.append(f'link\t{rel}\t{t}')
                continue
            with open(full, 'rb') as fh:
                elf = fh.read(4) == b'\x7fELF'
            if elf:
                # git's helpers are hard links of one binary: ship each distinct file once.
                h = hashlib.sha1(open(full, 'rb').read()).hexdigest()
                jn = seen.get(h)
                if jn is None:
                    k += 1
                    jn = seen[h] = f'libsmx_{k}.so'
                    shutil.copyfile(full, os.path.join(jni, jn))
                    os.chmod(os.path.join(jni, jn), 0o755)
                manifest.append(f'elf\t{rel}\t{jn}')
            else:
                z.write(full, rel)

    # Commands: every program in the usual bin dirs and git's helpers, plus the busybox applets.
    cmds = {}
    for d in ('bin', 'sbin', 'usr/sbin', 'usr/bin', 'usr/libexec/git-core'):
        p = os.path.join(root, d)
        if not os.path.isdir(p):
            continue
        for f in sorted(os.listdir(p)):
            full = os.path.join(p, f)
            if os.path.isdir(full) or DROP.search(f'{d}/{f}'):
                continue
            if os.path.islink(full):
                t = os.path.realpath(full)
                if not t.startswith(root) or not os.path.exists(t):
                    continue
                rel = os.path.relpath(t, root)
            else:
                rel = f'{d}/{f}'
            # Sourced helpers (git-sh-setup...) are not commands: only executables are.
            if not os.access(os.path.join(root, rel), os.X_OK):
                continue
            cmds.setdefault(f, (rel, ''))
    bb = next((r for r in ('bin/busybox', 'usr/bin/busybox') if os.path.exists(os.path.join(root, r))), None)
    if bb:
        for a in APPLETS:
            cmds.setdefault(a, (bb, a))
    cmds.pop('busybox', None)
    if bb:
        cmds['busybox'] = (bb, '')
    if 'python3' in cmds:
        cmds.setdefault('python', cmds['python3'])
    if 'pip3' in cmds:
        cmds.setdefault('pip', cmds['pip3'])
    tsv = ''.join(f'{n}\t{r}\t{a}\n' for n, (r, a) in sorted(cmds.items()))
    z.writestr('bin.tsv', tsv)
    z.writestr('manifest.tsv', '\n'.join(manifest) + '\n')
    z.writestr('packages.txt', '\n'.join(f'{n}-{pkgs[n]["V"]}' for n in names) + '\n')
    z.close()
    open(os.path.join(jni, 'libsmx_data.so'), 'wb').write(zbuf.getvalue())
    shutil.copyfile(launcher, os.path.join(jni, 'libsmx_launch.so'))
    os.chmod(os.path.join(jni, 'libsmx_launch.so'), 0o755)
    for must in ('git', 'curl', 'python3', 'rg', 'wget', 'jq'):
        if must not in cmds:
            sys.exit(f'missing command {must}')
    print(f'{len(names)} packages, {k} ELF files, {len(cmds)} commands, data zip {len(zbuf.getvalue()) // 1024} KB')


if __name__ == '__main__':
    main()
