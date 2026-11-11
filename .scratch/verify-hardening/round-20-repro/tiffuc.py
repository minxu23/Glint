"""探针：在 TIFF 块里找 ExifIFD 的 UserComment(0x9286) 条目，改指到追加在块尾的新值。"""
import struct, sys
sys.path.insert(0, '../round-18-repro')
import exifswap

def find_uc(t):
    le = t[:2] == b'II'; o = '<' if le else '>'
    u16 = lambda a: struct.unpack(o+'H', t[a:a+2])[0]; u32 = lambda a: struct.unpack(o+'I', t[a:a+4])[0]
    ifd0 = u32(4); n = u16(ifd0); exif = None
    for i in range(n):
        e = ifd0+2+12*i
        if u16(e) == 0x8769: exif = u32(e+8)
    if exif is None: return None
    n = u16(exif)
    for i in range(n):
        e = exif+2+12*i
        if u16(e) == 0x9286:
            typ, cnt = u16(e+2), u32(e+4)
            val = t[e+8:e+8+cnt] if cnt <= 4 else t[u32(e+8):u32(e+8)+cnt]
            return dict(entry=e, type=typ, count=cnt, value=val, le=le)
    return None

def repoint(t, new_value, typ=7):
    """返回新 TIFF：原字节不动，只改 0x9286 条目的类型/个数/偏移，新值接在块尾（偶数偏移）。"""
    uc = find_uc(t); o = '<' if uc['le'] else '>'
    t = bytearray(t)
    if len(t) % 2: t += b'\0'
    off = len(t); t += new_value
    e = uc['entry']
    t[e+2:e+4] = struct.pack(o+'H', typ); t[e+4:e+8] = struct.pack(o+'I', len(new_value)); t[e+8:e+12] = struct.pack(o+'I', off)
    return bytes(t)

def jpeg_with_tiff(jpeg, tiff):
    """把 JPEG 里唯一的 EXIF 段换成新的 TIFF。"""
    b = open(jpeg, 'rb').read(); at = 2
    while b[at] == 0xFF:
        m = b[at+1]; ln = struct.unpack('>H', b[at+2:at+4])[0]
        if m == 0xE1 and b[at+4:at+10] == b'Exif\0\0':
            seg = b'\xff\xe1' + struct.pack('>H', 2+6+len(tiff)) + b'Exif\0\0' + tiff
            return b[:at] + seg + b[at+2+ln:]
        at += 2+ln
    raise SystemExit('no exif')

def heic_with_tiff(heic, tiff, out):
    b = bytearray(open(heic, 'rb').read()); info = exifswap.parse(b)
    eid = [i for i, t in info['items'] if t == 'Exif'][0]; loc = info['iloc']['locs'][eid]; e = loc['exts'][0]; il = info['iloc']
    old = loc['base']+e['off']; b[old:old+e['len']] = bytes(e['len'])
    payload = struct.pack('>I', 6)+b'Exif\0\0'+tiff; new = len(b); b += payload
    top = info['top'][-1]; ms, mc = top[1], top[2]
    if mc-ms == 8: b[ms:ms+4] = struct.pack('>I', len(b)-ms)
    else: b[ms+8:ms+16] = struct.pack('>Q', len(b)-ms)
    b[e['off_at']:e['off_at']+il['osz']] = (new-loc['base']).to_bytes(il['osz'], 'big'); b[e['len_at']:e['len_at']+il['lsz']] = len(payload).to_bytes(il['lsz'], 'big')
    open(out, 'wb').write(b)
