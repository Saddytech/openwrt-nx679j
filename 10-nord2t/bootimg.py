#!/usr/bin/env python3
"""
bootimg.py — sostituzione del SOLO ramdisk in un boot image Android (header v0..v4).

E' la generalizzazione del builder NX679J (02-sorgenti/wifi-luci/build-v90.py), che
aveva offset fissi per quel telefono (ramdisk a 49115136, ramdisk_size a offset 12,
header v4). La lezione della Fase 1 resta la regola di questo strumento:

  * NON si ricostruisce l'header con mkbootimg: si patcha il contenitore esistente
    (quello che il bootloader ha gia' accettato, es. il boot Magisk), cambiando solo
    il ramdisk e il campo ramdisk_size; le sezioni successive vengono spostate
    byte-identiche.
  * Il file d'uscita ha la STESSA lunghezza del file d'ingresso (immagine di
    partizione intera), altrimenti errore.
  * Il ramdisk nuovo deve avere la stessa compressione dell'originale (lz4 legacy,
    gzip, ...): lo strumento la rileva e rifiuta un formato diverso (--force per forzare).

Supporta anche l'header MediaTek legacy da 512 byte (magic 0x58881688) davanti al
ramdisk: se presente nell'originale viene conservato e aggiornato il campo size.

Sottocomandi:
  info    IMG                       header, sezioni, compressione del ramdisk
  extract IMG OUTDIR                estrae kernel/ramdisk/second/dtb/... grezzi
  mkcpio  DIR OUT.cpio [--root]     cpio newc in Python puro (--root: uid/gid 0)
  swap    IMG RAMDISK OUT [--keep-id] [--force]
  selftest                          prove sintetiche v2 e v4 (+ header MTK)

Nessuna dipendenza esterna. La compressione si fa fuori, con lo stesso formato
dell'originale, ad es.:  lz4 -l -9 -c new.cpio > new.lz4   oppure   gzip -9 -n -c.
"""
import hashlib
import os
import stat
import struct
import sys

MAGIC = b'ANDROID!'
MTK_MAGIC = 0x58881688


def ru(x, p):
    return (x + p - 1) // p * p


def compression(blob):
    b = blob[:4]
    if b == b'\x02\x21\x4c\x18':
        return 'lz4-legacy'
    if b == b'\x04\x22\x4d\x18':
        return 'lz4-frame'
    if b[:2] == b'\x1f\x8b':
        return 'gzip'
    if blob[:6] == b'\xfd7zXZ\x00':
        return 'xz'
    if b[:3] == b'BZh':
        return 'bzip2'
    if blob[:6] in (b'070701', b'070702'):
        return 'cpio-raw'
    if len(blob) >= 4 and struct.unpack_from('<I', blob, 0)[0] == MTK_MAGIC:
        return 'mtk-header'
    return 'sconosciuta(%s)' % blob[:4].hex()


class BootImg:
    """Mappa delle sezioni di un boot image. Ogni sezione = (nome, offset, size)."""

    def __init__(self, data):
        if data[:8] != MAGIC:
            raise SystemExit('magic ANDROID! assente: non e\' un boot image (vendor_boot usa VNDRBOOT)')
        self.data = data
        self.version = struct.unpack_from('<I', data, 40)[0]
        if self.version > 4:
            raise SystemExit('header_version %d non supportato' % self.version)
        self.sections = []
        if self.version >= 3:
            self.page = 4096
            ks, rs = struct.unpack_from('<II', data, 8)
            self.rs_off = 12
            sizes = [('kernel', ks), ('ramdisk', rs)]
            if self.version == 4:
                sizes.append(('signature', struct.unpack_from('<I', data, 1580)[0]))
            hdr_size = struct.unpack_from('<I', data, 20)[0]
            off = ru(hdr_size, self.page)
        else:
            ks, = struct.unpack_from('<I', data, 8)
            rs, = struct.unpack_from('<I', data, 16)
            ss, = struct.unpack_from('<I', data, 24)
            self.page = struct.unpack_from('<I', data, 36)[0]
            if self.page not in (2048, 4096, 8192, 16384):
                raise SystemExit('page_size %d anomalo' % self.page)
            self.rs_off = 16
            sizes = [('kernel', ks), ('ramdisk', rs), ('second', ss)]
            if self.version >= 1:
                sizes.append(('recovery_dtbo', struct.unpack_from('<I', data, 1632)[0]))
            if self.version == 2:
                sizes.append(('dtb', struct.unpack_from('<I', data, 1648)[0]))
            off = self.page  # l'header occupa una pagina
        for name, sz in sizes:
            self.sections.append((name, off, sz))
            off += ru(sz, self.page)
        self.end = off
        if self.end > len(data):
            raise SystemExit('sezioni oltre la fine del file (%d > %d): immagine troncata?' % (self.end, len(data)))

    def get(self, name):
        for n, o, s in self.sections:
            if n == name:
                return self.data[o:o + s]
        return b''

    def describe(self):
        d = self.data
        out = ['header_version=%d page_size=%d file=%d B, sezioni fino a %d B'
               % (self.version, self.page, len(d), self.end)]
        if self.version < 3:
            name = d[48:64].split(b'\0')[0].decode('latin1')
            cmd = (d[64:576].split(b'\0')[0] + d[608:1632].split(b'\0')[0]).decode('latin1')
            out.append('name=%r os_version=0x%08x' % (name, struct.unpack_from('<I', d, 44)[0]))
            out.append('id(sha1)=%s' % d[576:596].hex())
        else:
            cmd = d[44:44 + 1536].split(b'\0')[0].decode('latin1')
            out.append('os_version=0x%08x' % struct.unpack_from('<I', d, 16)[0])
        out.append('cmdline=%r' % cmd)
        for n, o, s in self.sections:
            extra = ''
            if n == 'ramdisk' and s:
                rd = d[o:o + s]
                c = compression(rd)
                if c == 'mtk-header':
                    c = 'mtk-header + ' + compression(rd[512:])
                extra = ' compressione=' + c
            out.append('  %-14s offset=%-10d size=%-10d%s' % (n, o, s, extra))
        return '\n'.join(out)


def mkbootimg_id(sections):
    """SHA1 'id' come lo calcola mkbootimg per v0..v2 (dati + size a 4 byte LE)."""
    h = hashlib.sha1()
    for blob in sections:
        h.update(blob)
        h.update(struct.pack('<I', len(blob)))
    return h.digest()


def swap(img_path, rd_path, out_path, keep_id=False, force=False):
    data = open(img_path, 'rb').read()
    b = BootImg(data)
    newrd = open(rd_path, 'rb').read()
    old = b.get('ramdisk')
    oldc, newc = compression(old), compression(newrd)
    if oldc == 'mtk-header':
        hdr = bytearray(old[:512])
        struct.pack_into('<I', hdr, 4, len(newrd))
        print('header MTK conservato (nome=%r), size aggiornato a %d'
              % (bytes(hdr[8:40]).split(b'\0')[0].decode('latin1'), len(newrd)))
        oldc = compression(old[512:])
        newrd = bytes(hdr) + newrd
    if oldc != newc and not force:
        raise SystemExit('compressione diversa: originale=%s nuovo=%s (usa lo stesso formato o --force)'
                         % (oldc, newc))
    hdr = bytearray(data[:b.sections[0][1]])
    struct.pack_into('<I', hdr, b.rs_off, len(newrd))
    body = bytearray(hdr)
    blobs = []
    for n, o, s in b.sections:
        blob = newrd if n == 'ramdisk' else data[o:o + s]
        blobs.append(blob)
        body += blob + b'\0' * (ru(len(blob), b.page) - len(blob))
    if b.version < 3 and not keep_id:
        body[576:576 + 32] = mkbootimg_id(blobs).ljust(32, b'\0')
    if len(body) > len(data):
        raise SystemExit('immagine nuova (%d B) piu\' grande dell\'originale/partizione (%d B)'
                         % (len(body), len(data)))
    # Coda: i byte oltre le sezioni (padding o footer AVB a fine partizione) restano allo
    # stesso offset; gli avanzi del vecchio ramdisk fra la nuova e la vecchia fine si azzerano.
    if data[-64:-60] == b'AVBf' and len(body) > len(data) - 64:
        raise SystemExit('il ramdisk nuovo invaderebbe il footer AVB a fine partizione')
    out = bytes(body) + b'\0' * max(0, b.end - len(body)) + data[max(len(body), b.end):]
    assert len(out) == len(data)
    nb = BootImg(out)  # rilettura: deve essere coerente
    assert nb.get('ramdisk') == newrd
    for n, _, _ in b.sections:
        if n != 'ramdisk':
            assert nb.get(n) == b.get(n), 'sezione %s alterata' % n
    open(out_path, 'wb').write(out)
    print(nb.describe())
    print('OK %s  md5=%s' % (out_path, hashlib.md5(out).hexdigest()))


def mkcpio(src, out_path, root=False):
    """cpio newc deterministico (ordine LC_ALL=C, mtime 0), come 'find . | sort | cpio -o -H newc'."""
    entries = []
    for dp, dns, fns in os.walk(src):
        for n in dns + fns:
            entries.append(os.path.relpath(os.path.join(dp, n), src))
    entries.sort(key=lambda s: s.encode())
    out = bytearray()
    ino = 300000

    def rec(name, st_mode, uid, gid, nlink, payload, rdev=0):
        nonlocal ino
        ino += 1
        nm = name.encode() + b'\0'
        maj, mnr = (os.major(rdev), os.minor(rdev)) if rdev else (0, 0)
        h = '070701' + ''.join('%08x' % v for v in (
            ino, st_mode, uid, gid, nlink, 0, len(payload), 0, 0, maj, mnr, len(nm), 0))
        out.extend(h.encode() + nm)
        out.extend(b'\0' * ((4 - len(out) % 4) % 4))
        out.extend(payload)
        out.extend(b'\0' * ((4 - len(out) % 4) % 4))

    for e in entries:
        p = os.path.join(src, e)
        st = os.lstat(p)
        uid, gid = (0, 0) if root else (st.st_uid, st.st_gid)
        if stat.S_ISLNK(st.st_mode):
            payload = os.readlink(p).encode()
        elif stat.S_ISREG(st.st_mode):
            payload = open(p, 'rb').read()
        else:
            payload = b''
        rdev = st.st_rdev if (stat.S_ISCHR(st.st_mode) or stat.S_ISBLK(st.st_mode)) else 0
        rec(e, st.st_mode, uid, gid, 2 if stat.S_ISDIR(st.st_mode) else 1, payload, rdev)
    rec('TRAILER!!!', 0, 0, 0, 1, b'')
    out.extend(b'\0' * ((512 - len(out) % 512) % 512))
    open(out_path, 'wb').write(out)
    print('cpio: %d voci, %d B -> %s' % (len(entries), len(out), out_path))


def _make_v2(kernel, ramdisk, dtb, page=2048, total=1 << 20, mtk=False):
    if mtk:
        h = bytearray(b'\xff' * 512)
        struct.pack_into('<II', h, 0, MTK_MAGIC, len(ramdisk))
        h[8:40] = b'ROOTFS'.ljust(32, b'\0')
        ramdisk = bytes(h) + ramdisk
    hdr = bytearray(page)
    hdr[:8] = MAGIC
    struct.pack_into('<IIIIIIII', hdr, 8, len(kernel), 0x40080000, len(ramdisk), 0x41000000,
                     0, 0, 0x40000100, page)
    struct.pack_into('<II', hdr, 40, 2, 0x18000162)
    hdr[64:80] = b'console=ttyS0\0\0\0'
    struct.pack_into('<IQI', hdr, 1632, 0, 0, 1660)
    struct.pack_into('<IQ', hdr, 1648, len(dtb), 0x47c80000)
    blobs = [kernel, ramdisk, b'', b'', dtb]
    hdr[576:608] = mkbootimg_id(blobs).ljust(32, b'\0')
    body = bytes(hdr)
    for blob in (kernel, ramdisk, dtb):
        body += blob + b'\0' * (ru(len(blob), page) - len(blob))
    return body + b'\0' * (total - len(body))


def _make_v4(kernel, ramdisk, sig, total=1 << 20):
    hdr = bytearray(4096)
    hdr[:8] = MAGIC
    struct.pack_into('<IIII', hdr, 8, len(kernel), len(ramdisk), 0x18000162, 1584)
    struct.pack_into('<I', hdr, 40, 4)
    struct.pack_into('<I', hdr, 1580, len(sig))
    body = bytes(hdr)
    for blob in (kernel, ramdisk, sig):
        body += blob + b'\0' * (ru(len(blob), 4096) - len(blob))
    return body + b'\0' * (total - len(body))


def selftest():
    import tempfile
    td = tempfile.mkdtemp()
    k = os.urandom(70001)
    lz = b'\x02\x21\x4c\x18'
    cases = [
        ('v2', _make_v2(k, lz + os.urandom(30000), os.urandom(5000)), lz + os.urandom(52345)),
        ('v2-mtk', _make_v2(k, lz + os.urandom(30000), os.urandom(5000), mtk=True), lz + os.urandom(12000)),
        ('v4', _make_v4(k, lz + os.urandom(30000), os.urandom(4096)), lz + os.urandom(99999)),
    ]
    for name, img, rd in cases:
        ip, rp, op = (os.path.join(td, name + s) for s in ('.img', '.rd', '.out'))
        open(ip, 'wb').write(img)
        open(rp, 'wb').write(rd)
        swap(ip, rp, op)
        out = open(op, 'rb').read()
        nb = BootImg(out)
        got = nb.get('ramdisk')
        if name.endswith('mtk'):
            assert struct.unpack_from('<II', got, 0) == (MTK_MAGIC, len(rd)) and got[512:] == rd
        else:
            assert got == rd
        if nb.version < 3:
            blobs = [nb.get(n) for n, _, _ in nb.sections]
            assert out[576:596] == mkbootimg_id(blobs), 'id sha1 non aggiornato'
        print('selftest %s: PASS' % name)
    # rifiuto di formato diverso e di immagine troppo grande
    open(os.path.join(td, 'gz'), 'wb').write(b'\x1f\x8b' + os.urandom(100))
    for bad, why in ((os.path.join(td, 'gz'), 'compressione'),):
        try:
            swap(os.path.join(td, 'v4.img'), bad, os.path.join(td, 'x'))
            raise AssertionError('doveva rifiutare: ' + why)
        except SystemExit as e:
            assert why in str(e)
    open(os.path.join(td, 'big'), 'wb').write(lz + os.urandom(2 << 20))
    try:
        swap(os.path.join(td, 'v4.img'), os.path.join(td, 'big'), os.path.join(td, 'x'))
        raise AssertionError('doveva rifiutare immagine troppo grande')
    except SystemExit as e:
        assert 'grande' in str(e)
    d = os.path.join(td, 'tree')
    os.makedirs(os.path.join(d, 'etc'))
    open(os.path.join(d, 'etc', 'x'), 'w').write('ciao')
    os.symlink('etc/x', os.path.join(d, 'l'))
    mkcpio(d, os.path.join(td, 't.cpio'), root=True)
    assert open(os.path.join(td, 't.cpio'), 'rb').read().count(b'070701') == 4
    print('selftest: TUTTO PASS')


def main(a):
    if not a or a[0] in ('-h', '--help'):
        print(__doc__)
        return
    cmd = a[0]
    if cmd == 'info':
        print(BootImg(open(a[1], 'rb').read()).describe())
    elif cmd == 'extract':
        b = BootImg(open(a[1], 'rb').read())
        os.makedirs(a[2], exist_ok=True)
        for n, o, s in b.sections:
            if s:
                open(os.path.join(a[2], n), 'wb').write(b.data[o:o + s])
                print('%s: %d B' % (n, s))
        open(os.path.join(a[2], 'header'), 'wb').write(b.data[:b.sections[0][1]])
    elif cmd == 'mkcpio':
        mkcpio(a[1], a[2], root='--root' in a)
    elif cmd == 'swap':
        pos = [x for x in a[1:] if not x.startswith('--')]
        swap(pos[0], pos[1], pos[2], keep_id='--keep-id' in a, force='--force' in a)
    elif cmd == 'selftest':
        selftest()
    else:
        raise SystemExit('comando sconosciuto: %s' % cmd)


if __name__ == '__main__':
    main(sys.argv[1:])
