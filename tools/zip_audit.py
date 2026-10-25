#!/usr/bin/env python3
"""Byte-level ZIP/APK audit, stricter than apksigner/zipalign.

Checks what Android's parsers (libziparchive in the installer, java.util.zip.ZipFile in apps)
reject: bad entry names ('..', leading '/', backslash, empty, NUL, non-UTF8), duplicate names,
local-header vs central-directory mismatches, data descriptors, ZIP64, archive comment,
extra EOCD/central-directory records, gaps/overlaps between entries, and that
AndroidManifest.xml / resources.arsc are present (arsc STORED + 4-byte aligned).
Usage: zip_audit.py app.apk   -> exit 1 on any hard failure.
"""
import struct, sys, zlib, collections

p = sys.argv[1]
b = open(p, 'rb').read()
n = len(b)
fail = []
warn = []
print(f"zip_audit {p} size={n}")

# --- EOCD
eocd_offs = []
i = b.rfind(b'PK\x05\x06')
k = 0
while True:
    k = b.find(b'PK\x05\x06', k)
    if k < 0: break
    eocd_offs.append(k); k += 4
print("EOCD signatures at:", eocd_offs[-5:], "count", len(eocd_offs))
e = i
(_, disk, cddisk, ndisk, ntot, cdsize, cdoff, clen) = struct.unpack('<IHHHHIIH', b[e:e+22])
comment = b[e+22:e+22+clen]
print(f"EOCD@{e} entries={ntot} cdsize={cdsize} cdoff={cdoff} commentlen={clen} trailing={n-(e+22+clen)}")
if clen: warn.append(f"archive comment {clen} bytes: {comment[:60]!r}")
if n - (e+22+clen) != 0: fail.append(f"{n-(e+22+clen)} bytes after EOCD")
if disk or cddisk or ndisk != ntot: fail.append("multi-disk EOCD")
if b.find(b'PK\x06\x06') >= 0 or b.find(b'PK\x06\x07') >= 0:
    z = b.find(b'PK\x06\x07')
    warn.append(f"ZIP64 locator/EOCD signature present at {z} (may be inside data)")
if cdoff + cdsize != e: fail.append(f"central dir end {cdoff+cdsize} != EOCD offset {e} (gap {e-cdoff-cdsize})")

# APK Signing Block sits between last entry and CD
# --- central directory
off = cdoff
ents = []
for idx in range(ntot):
    if b[off:off+4] != b'PK\x01\x02':
        fail.append(f"bad CD signature at {off} (entry {idx})"); break
    (sig, vmade, vneed, flag, meth, mt, md, crc, csz, usz, fnl, exl, cml, dsk, iattr, eattr, lho) = struct.unpack('<IHHHHHHIIIHHHHHII', b[off:off+46])
    name_b = b[off+46:off+46+fnl]
    extra = b[off+46+fnl:off+46+fnl+exl]
    cmt = b[off+46+fnl+exl:off+46+fnl+exl+cml]
    ents.append(dict(idx=idx, name_b=name_b, flag=flag, meth=meth, crc=crc, csz=csz, usz=usz, extra=extra, cmt=cmt, lho=lho, vmade=vmade, vneed=vneed, eattr=eattr))
    off += 46 + fnl + exl + cml
if off != cdoff + cdsize: fail.append(f"CD parse ended at {off}, expected {cdoff+cdsize}")
print(f"central directory entries parsed: {len(ents)}")

names = collections.Counter()
spans = []
first_lho = min((x['lho'] for x in ents), default=0)
if first_lho != 0: warn.append(f"first local header at {first_lho} (prefix data)")
for x in ents:
    nb = x['name_b']
    try:
        name = nb.decode('utf-8')
    except UnicodeDecodeError:
        name = nb.decode('latin-1'); fail.append(f"non-UTF8 name {nb!r}")
    x['name'] = name
    names[name] += 1
    bad = []
    if name == '': bad.append('empty name')
    if name.startswith('/'): bad.append('leading /')
    if '\\' in name: bad.append('backslash')
    if '\x00' in name: bad.append('NUL')
    if any(seg == '..' for seg in name.split('/')) or '..' in name: bad.append("'..'")
    if name.startswith('./') or '/./' in name or '//' in name: bad.append('./ or //')
    if name.endswith('/'): warn.append(f"directory entry {name!r}")
    if any(ord(c) > 126 or ord(c) < 32 for c in name): bad.append('non-ASCII/control')
    if bad: fail.append(f"bad name {name!r}: {', '.join(bad)}")
    if x['flag'] & 0x1: fail.append(f"{name}: encrypted flag")
    if x['flag'] & 0x8: warn.append(f"{name}: data-descriptor flag (bit 3)")
    if x['flag'] & ~0x0808 & 0xffff: warn.append(f"{name}: unusual flags 0x{x['flag']:04x}")
    if x['meth'] not in (0, 8): fail.append(f"{name}: compression method {x['meth']}")
    if 0xffffffff in (x['csz'], x['usz'], x['lho']): fail.append(f"{name}: ZIP64 sizes")
    if x['meth'] == 0 and x['csz'] != x['usz']: fail.append(f"{name}: STORED but csz {x['csz']} != usz {x['usz']}")
    if x['cmt']: warn.append(f"{name}: entry comment")
    # local header
    L = x['lho']
    if b[L:L+4] != b'PK\x03\x04':
        fail.append(f"{name}: no local header at {L}"); continue
    (_, lvn, lflag, lmeth, lmt, lmd, lcrc, lcsz, lusz, lfnl, lexl) = struct.unpack('<IHHHHHIIIHH', b[L:L+30])
    lname = b[L+30:L+30+lfnl]
    data_off = L + 30 + lfnl + lexl
    x['data_off'] = data_off
    if lname != nb: fail.append(f"{name}: local name {lname!r} != central name")
    if lmeth != x['meth']: fail.append(f"{name}: local method {lmeth} != central {x['meth']}")
    if (lflag & 0x8) != (x['flag'] & 0x8): fail.append(f"{name}: data-descriptor flag differs local/central")
    if not (lflag & 0x8):
        if (lcrc, lcsz, lusz) != (x['crc'], x['csz'], x['usz']):
            fail.append(f"{name}: local crc/sizes {(lcrc,lcsz,lusz)} != central {(x['crc'],x['csz'],x['usz'])}")
    end = data_off + x['csz']
    if x['flag'] & 0x8:
        if b[end:end+4] == b'PK\x07\x08': end += 16
        else: end += 12
    spans.append((L, end, name))
    # data integrity
    raw = b[data_off:data_off+x['csz']]
    try:
        data = raw if x['meth'] == 0 else zlib.decompressobj(-15).decompress(raw)
        if len(data) != x['usz']: fail.append(f"{name}: inflated {len(data)} != usz {x['usz']}")
        elif zlib.crc32(data) & 0xffffffff != x['crc']: fail.append(f"{name}: CRC mismatch")
    except Exception as ex:
        fail.append(f"{name}: inflate error {ex}")

for nm, c in names.items():
    if c > 1: fail.append(f"duplicate entry name {nm!r} x{c}")

spans.sort()
prev_end = 0; prev_name = None
for s, e2, nm in spans:
    if s < prev_end: fail.append(f"overlap: {nm} starts {s} < end of {prev_name} {prev_end}")
    elif s > prev_end and prev_name is not None: warn.append(f"gap {s-prev_end}B before {nm}")
    prev_end, prev_name = e2, nm
# what lies between last entry and CD = APK signing block
gapcd = cdoff - prev_end
blk = b[prev_end:cdoff]
print(f"bytes between last entry and CD: {gapcd}  signing-block-magic={'APK Sig Block 42' in blk.decode('latin-1')}")
if gapcd and b'APK Sig Block 42' not in blk: fail.append(f"{gapcd} unknown bytes before central directory")
# stray local headers not referenced by CD
known = set(x['lho'] for x in ents)
k = 0; stray = 0
while True:
    k = b.find(b'PK\x03\x04', k)
    if k < 0 or k >= cdoff: break
    if k not in known:
        inside = any(s <= k < e2 for s, e2, _ in spans)
        if not inside: stray += 1; fail.append(f"unreferenced local header at {k}")
    k += 4
print(f"stray local headers (outside entries): {stray}")

byname = {x['name']: x for x in ents}
for must in ('AndroidManifest.xml', 'classes.dex', 'resources.arsc'):
    if must not in byname: fail.append(f"missing {must}")
if 'resources.arsc' in byname:
    a = byname['resources.arsc']
    print(f"resources.arsc method={a['meth']} data_off={a.get('data_off')} mod4={a.get('data_off',0)%4}")
    if a['meth'] != 0: fail.append("resources.arsc is compressed (targetSdk>=30 rejects)")
    if a.get('data_off', 0) % 4: fail.append("resources.arsc not 4-byte aligned")
if 'AndroidManifest.xml' in byname:
    m = byname['AndroidManifest.xml']
    print(f"AndroidManifest.xml method={m['meth']} size={m['usz']} idx={m['idx']}")
meths = collections.Counter((x['name'].split('/')[0] if '/' in x['name'] else '(root)', x['meth']) for x in ents)
print("method by top dir:", dict(meths))
vm = collections.Counter(x['vmade'] >> 8 for x in ents)
print("version-made-by host OS:", dict(vm))
ex = collections.Counter(len(x['extra']) for x in ents)
print("central extra-field lengths:", dict(ex))

for w in warn[:40]: print("WARN", w)
if len(warn) > 40: print(f"WARN ... {len(warn)-40} more")
for f in fail[:80]: print("!! FAIL", f)
print(f"ZIP_AUDIT {'FAIL' if fail else 'OK'} entries={len(ents)} fails={len(fail)} warns={len(warn)}")
sys.exit(1 if fail else 0)
