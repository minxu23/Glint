import struct, sys
d = open(sys.argv[1], 'rb').read()
i = d.find(b'Exif\0\0') + 6
t = d[i:]
bo = '>' if t[:2] == b'MM' else '<'
names = {0x8769: 'Exif', 0x8825: 'GPS', 0xa005: 'Interop'}
def walk(off, path, seen=set()):
    if off in seen or off + 2 > len(t): return
    seen.add(off)
    n = struct.unpack(bo + 'H', t[off:off+2])[0]
    for k in range(n):
        e = off + 2 + 12 * k
        tag, typ, cnt = struct.unpack(bo + 'HHI', t[e:e+8])
        if typ == 0 or typ > 13: print(f'{path}/{tag:x} type={typ} count={cnt} raw={t[e+8:e+12].hex()}')
        if tag in names and typ in (4, 13):
            walk(struct.unpack(bo + 'I', t[e+8:e+12])[0], path + '/' + f'{tag:x}')
walk(struct.unpack(bo + 'I', t[4:8])[0], 'IFD0')
