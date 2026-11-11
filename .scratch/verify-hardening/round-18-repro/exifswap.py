#!/usr/bin/env python3
"""探针：把 HEIC 里 Exif 项的内容换成源 JPEG 的原始 EXIF 字节。
用法:
  exifswap.py dump <heic>
  exifswap.py swap <src.jpg> <in.heic> <out.heic> [--keep-thumb|--strip-ifd1]
只支持 ImageIO 写出来的结构：Exif 项一段、构造方式 0。别的结构直接报错退出。
"""
import struct
import sys


def be(b, at, n):
    return int.from_bytes(b[at:at + n], "big")


def boxes(b, start, end):
    at = start
    out = []
    while at < end:
        size = be(b, at, 4)
        typ = b[at + 4:at + 8].decode("latin1")
        hdr = 8
        if size == 1:
            size = be(b, at + 8, 8)
            hdr = 16
        elif size == 0:
            size = end - at
        if size < hdr or at + size > end:
            raise SystemExit(f"盒子越界 @{at} {typ}")
        out.append((typ, at, at + hdr, at + size))
        at += size
    return out


def parse(b):
    top = boxes(b, 0, len(b))
    meta = next(x for x in top if x[0] == "meta")
    kids = boxes(b, meta[2] + 4, meta[3])
    info = {"top": top, "meta": meta, "kids": kids}
    iinf = next(x for x in kids if x[0] == "iinf")
    v = b[iinf[2]]
    cw = 2 if v == 0 else 4
    items = []
    for infe in boxes(b, iinf[2] + 4 + cw, iinf[3]):
        iv = b[infe[2]]
        idw = 2 if iv == 2 else 4
        iid = be(b, infe[2] + 4, idw)
        typ = b[infe[2] + 4 + idw + 2: infe[2] + 4 + idw + 6].decode("latin1")
        items.append((iid, typ))
    info["items"] = items
    iloc = next(x for x in kids if x[0] == "iloc")
    at = iloc[2]
    ver = b[at]
    at += 4
    s1, s2 = b[at], b[at + 1]
    at += 2
    osz, lsz, bsz = s1 >> 4, s1 & 15, s2 >> 4
    isz = s2 & 15 if ver else 0
    n = be(b, at, 2 if ver < 2 else 4)
    at += 2 if ver < 2 else 4
    locs = {}
    for _ in range(n):
        iid = be(b, at, 2 if ver < 2 else 4)
        at += 2 if ver < 2 else 4
        method = 0
        if ver >= 1:
            method = be(b, at, 2) & 15
            at += 2
        at += 2
        base_at = at
        base = be(b, at, bsz)
        at += bsz
        ec = be(b, at, 2)
        at += 2
        exts = []
        for _ in range(ec):
            at += isz
            off_at = at
            off = be(b, at, osz)
            at += osz
            len_at = at
            ln = be(b, at, lsz)
            at += lsz
            exts.append({"off_at": off_at, "off": off, "len_at": len_at, "len": ln})
        locs[iid] = {"method": method, "base": base, "base_at": base_at, "bsz": bsz, "exts": exts}
    info["iloc"] = {"ver": ver, "osz": osz, "lsz": lsz, "bsz": bsz, "isz": isz, "locs": locs}
    return info


def where(info, off):
    for typ, s, c, e in info["top"]:
        if s <= off < e:
            return typ
    return "?"


def dump(path):
    b = open(path, "rb").read()
    info = parse(b)
    il = info["iloc"]
    print(f"{path}: size={len(b)} top={[t[0] for t in info['top']]} meta_kids={[k[0] for k in info['kids']]}")
    print(f"  iloc v{il['ver']} offset_size={il['osz']} length_size={il['lsz']} base_size={il['bsz']} items={len(il['locs'])}")
    types = {}
    for iid, typ in info["items"]:
        types[typ] = types.get(typ, 0) + 1
    print(f"  items: {types}")
    for iid, typ in info["items"]:
        if typ in ("Exif", "mime"):
            loc = il["locs"].get(iid)
            if not loc:
                print(f"  {typ} id={iid}: 不在 iloc 里")
                continue
            for e in loc["exts"]:
                off = loc["base"] + e["off"]
                head = b[off:off + 14].hex() if loc["method"] == 0 else ""
                print(f"  {typ} id={iid} method={loc['method']} base={loc['base']} off={off} len={e['len']} in={where(info, off)} head={head}")


def jpeg_exif(path):
    b = open(path, "rb").read()
    at = 2
    found = []
    while at + 4 <= len(b) and b[at] == 0xFF:
        m = b[at + 1]
        if m == 0xDA or m == 0xD9:
            break
        ln = be(b, at + 2, 2)
        if m == 0xE1 and b[at + 4:at + 10] == b"Exif\0\0":
            found.append(b[at + 10:at + 2 + ln])
        at += 2 + ln
    return found


def strip_ifd1(t):
    """把 IFD0 的「下一个 IFD」指针清零（缩略图字节留在原处成为死字节）。"""
    le = t[:2] == b"II"
    u = lambda at, n: int.from_bytes(t[at:at + n], "little" if le else "big")
    ifd0 = u(4, 4)
    n = u(ifd0, 2)
    nxt = ifd0 + 2 + 12 * n
    t = bytearray(t)
    t[nxt:nxt + 4] = b"\0\0\0\0"
    return bytes(t)


def swap(src, heic, out, mode):
    exifs = jpeg_exif(src)
    if len(exifs) != 1:
        raise SystemExit(f"源里 EXIF 段有 {len(exifs)} 个，不换")
    tiff = exifs[0]
    if mode == "--strip-ifd1":
        tiff = strip_ifd1(tiff)
    b = bytearray(open(heic, "rb").read())
    info = parse(b)
    ids = [i for i, t in info["items"] if t == "Exif"]
    if len(ids) != 1:
        raise SystemExit(f"产物里 Exif 项有 {len(ids)} 个，不换")
    loc = info["iloc"]["locs"][ids[0]]
    il = info["iloc"]
    if loc["method"] != 0 or len(loc["exts"]) != 1:
        raise SystemExit("Exif 项不是单段文件偏移，不换")
    e = loc["exts"][0]
    old_off = loc["base"] + e["off"]
    old = bytes(b[old_off:old_off + e["len"]])
    skip = be(old, 0, 4)
    prefix = old[4:4 + skip]
    payload = struct.pack(">I", len(prefix)) + prefix + tiff
    # 追加一个新的 mdat，Exif 项指过去；旧内容留在原处成为死字节。
    new_off = len(b) + 8
    b += struct.pack(">I", 8 + len(payload)) + b"mdat" + payload
    if new_off - loc["base"] >= 1 << (8 * il["osz"]) or len(payload) >= 1 << (8 * il["lsz"]):
        raise SystemExit("iloc 字段宽度放不下新偏移")
    b[e["off_at"]:e["off_at"] + il["osz"]] = (new_off - loc["base"]).to_bytes(il["osz"], "big")
    b[e["len_at"]:e["len_at"] + il["lsz"]] = len(payload).to_bytes(il["lsz"], "big")
    open(out, "wb").write(b)
    print(f"{out}: Exif 项 {e['len']} → {len(payload)} 字节，文件 {len(b) - 8 - len(payload)} → {len(b)}")


if __name__ == "__main__":
    if sys.argv[1] == "dump":
        for p in sys.argv[2:]:
            dump(p)
    elif sys.argv[1] == "swap":
        swap(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] if len(sys.argv) > 5 else "")


def swapx(src, heic, out):
    """定稿布局：新内容接在最后一个 mdat 末尾，旧内容清零。"""
    exifs = jpeg_exif(src)
    if len(exifs) != 1:
        raise SystemExit(f"SKIP 源里 EXIF 段有 {len(exifs)} 个")
    b = bytearray(open(heic, "rb").read())
    info = parse(b)
    ids = [i for i, t in info["items"] if t == "Exif"]
    if len(ids) != 1:
        raise SystemExit(f"SKIP 产物里 Exif 项有 {len(ids)} 个")
    il = info["iloc"]
    loc = il["locs"][ids[0]]
    top = info["top"]
    if loc["method"] != 0 or len(loc["exts"]) != 1 or top[-1][0] != "mdat":
        raise SystemExit("SKIP 结构不是预期的")
    e = loc["exts"][0]
    old_off = loc["base"] + e["off"]
    payload = struct.pack(">I", 6) + b"Exif\0\0" + exifs[0]
    b[old_off:old_off + e["len"]] = bytes(e["len"])
    new_off = len(b)
    b += payload
    ms, mc = top[-1][1], top[-1][2]
    if mc - ms == 8:
        b[ms:ms + 4] = struct.pack(">I", len(b) - ms)
    else:
        b[ms + 8:ms + 16] = struct.pack(">Q", len(b) - ms)
    b[e["off_at"]:e["off_at"] + il["osz"]] = (new_off - loc["base"]).to_bytes(il["osz"], "big")
    b[e["len_at"]:e["len_at"] + il["lsz"]] = len(payload).to_bytes(il["lsz"], "big")
    open(out, "wb").write(b)


if __name__ == "__main__" and sys.argv[1] == "swapx":
    swapx(sys.argv[2], sys.argv[3], sys.argv[4])
