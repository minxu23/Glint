import sys, struct
def segs(d):
    assert d[:2]==b'\xff\xd8'
    i=2; out=[]
    while i+4<=len(d):
        assert d[i]==0xFF, hex(i)
        m=d[i+1]
        if m==0xDA: out.append((m,i,len(d)-i)); break
        L=struct.unpack('>H',d[i+2:i+4])[0]
        out.append((m,i,2+L)); i+=2+L
    return out
def seg(marker, payload): return bytes([0xFF,marker])+struct.pack('>H',len(payload)+2)+payload
cmd=sys.argv[1]; src=open(sys.argv[2],'rb').read()
if cmd=='list':
    for m,i,l in segs(src): print(hex(m), i, l, src[i+4:i+24])
    e=src.rfind(b'\xff\xd9'); print('EOI at',e,'len',len(src))
elif cmd=='com':   # insert COM after SOI
    out=src[:2]+seg(0xFE, sys.argv[4].encode())+src[2:]; open(sys.argv[3],'wb').write(out)
elif cmd=='trailer':
    open(sys.argv[3],'wb').write(src+b'\x00\x00\x00\x18ftypmp42'+b'MOTIONPHOTOVIDEO'*4096)
elif cmd=='app11':
    out=src[:2]+seg(0xEB, b'JP\x00\x00'+b'C2PA-manifest-placeholder'*10)+src[2:]; open(sys.argv[3],'wb').write(out)
elif cmd=='patch':  # same-length byte replace, must occur exactly n times
    a=sys.argv[4].encode(); b=sys.argv[5].encode(); assert len(a)==len(b)
    n=src.count(a); print('occurrences',n); assert n>=1
    open(sys.argv[3],'wb').write(src.replace(a,b))
elif cmd=='xp':   # replace/insert an EXIF APP1 with IFD0 containing Make, XPComment, XPKeywords, Rating
    def u16s(s): return s.encode('utf-16le')+b'\x00\x00'
    entries=[]  # (tag,type,count,valuebytes)
    make=b'TestCam\x00'
    entries.append((0x010F,2,len(make),make))
    entries.append((0x4746,3,1,struct.pack('<H',4)+b'\x00\x00'))
    xc=u16s('Windows 备注 comment'); entries.append((0x9C9C,1,len(xc),xc))
    xk=u16s('家庭;旅行'); entries.append((0x9C9E,1,len(xk),xk))
    xt=u16s('标题 XPTitle'); entries.append((0x9C9B,1,len(xt),xt))
    entries.sort()
    n=len(entries); base=8+2+n*12+4; data=b''; ifd=struct.pack('<H',n)
    for tag,typ,cnt,val in entries:
        if len(val)<=4: ifd+=struct.pack('<HHI',tag,typ,cnt)+val.ljust(4,b'\x00')
        else:
            ifd+=struct.pack('<HHII',tag,typ,cnt,base+len(data)); data+=val+(b'\x00' if len(val)%2 else b'')
    ifd+=struct.pack('<I',0)
    tiff=b'II*\x00'+struct.pack('<I',8)+ifd+data
    app1=seg(0xE1,b'Exif\x00\x00'+tiff)
    # strip existing Exif APP1 and APP13
    out=src[:2]+app1
    for m,i,l in segs(src):
        chunk=src[i:i+l]
        if m==0xE1 and chunk[4:10]==b'Exif\x00\x00': continue
        out+=chunk
    open(sys.argv[3],'wb').write(out)
