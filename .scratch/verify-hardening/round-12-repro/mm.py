import sys
src=open('fx.jpg','rb').read()
def rep(d,a,b,n=None):
    a=a.encode(); b=b.encode(); assert len(a)==len(b); c=d.count(a); assert c>=1,(a,c)
    return d.replace(a,b)
variants={
 'E': lambda d: rep(d,'2024:09:15 18:42:07','2024:09:15 01:01:01'),
 'X': lambda d: rep(rep(d,'photoshop:DateCreated="2024-09-15T18:42:07+08:00"','photoshop:DateCreated="2024-09-15T02:02:02+08:00"'),'xmp:CreateDate="2024-09-15T18:42:07"','xmp:CreateDate="2024-09-15T03:03:03"'),
 'I': lambda d: rep(d,'184207+0800','040404+0800'),
 'Iutc': lambda d: rep(d,'184207+0800','104207+0000'),
 'Idate': lambda d: rep(d,'20240915','20200101'),
}
for name in sys.argv[1:]:
    d=src
    for part in name.split('+'): d=variants[part](d)
    open('mm-'+name+'.jpg','wb').write(d)
