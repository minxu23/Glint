"""造样本：把 `Tests/fixture --rich-xmp` 的输出里某个命名空间的 URI 等长换掉（前缀不变）。
用法: variants.py rich.jpg
得到 rich_v1/v2.jpg（标准前缀 photoshop 配非标准 URI）和 rich_j2.jpg（自定义前缀 jt 配另一个 URI）。"""
import sys
b = open(sys.argv[1], 'rb').read()
std = b'xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"'
assert b.count(std) == 1
for name, u in [('v1', b'http://ns.adobe.com/photoshop/1.1/'), ('v2', b'http://ns.adobe.com/photoshop/1.2/')]:
    open('rich_' + name + '.jpg', 'wb').write(b.replace(std, b'xmlns:photoshop="' + u + b'"'))
jt = b'xmlns:jt="http://example.com/jpeg2heif/test/1.0/"'
assert b.count(jt) == 1
open('rich_j2.jpg', 'wb').write(b.replace(jt, b'xmlns:jt="http://example.com/jpeg2heif/test/2.0/"'))
