"""Generate tiny deterministic MOBI fixtures without an external converter."""
import struct
import sys
from pathlib import Path


def mobi(title, html, compression=2, encrypted=False, encoding=65001):
    codec = 'utf-8' if encoding == 65001 else 'cp1252'
    raw = html.encode(codec)
    title_bytes = title.encode(codec)
    author = '测试作者'.encode(codec) if encoding == 65001 else b'Test Author'
    exth = b'EXTH' + struct.pack('>II', 20 + len(author), 1) + struct.pack('>II', 100, 8 + len(author)) + author
    header = bytearray(b'\xff' * 232)
    header[:4] = b'MOBI'
    for offset, value in {4:232, 8:2, 12:encoding, 16:12345, 20:6, 64:2,
                          68:16 + 232 + len(exth), 72:len(title_bytes), 76:0x0804,
                          80:0, 84:0, 88:6, 96:0, 100:0, 104:0, 108:0,
                          112:0x40, 156:0, 160:0, 164:0, 176:0x00010001,
                          180:0, 188:0, 196:0, 212:0, 220:0}.items():
        struct.pack_into('>I', header, offset, value)
    struct.pack_into('>H', header, 226, 0)  # No trailing-record extra data.
    # PalmDOC literal runs preserve UTF-8 bytes that are otherwise control codes.
    text = raw if compression == 1 else b''.join(bytes([len(raw[i:i+8])]) + raw[i:i+8] for i in range(0, len(raw), 8))
    record0 = struct.pack('>HHIHHHH', compression, 0, len(raw), 1, 4096, 2 if encrypted else 0, 0) + header + exth + title_bytes
    pdb = bytearray(78)
    pdb[:11] = b'Readle test'
    pdb[60:68] = b'BOOKMOBI'
    struct.pack_into('>I', pdb, 68, 3)
    struct.pack_into('>H', pdb, 76, 2)
    return bytes(pdb) + struct.pack('>II', 96, 1) + struct.pack('>II', 96 + len(record0), 2) + b'\0\0' + record0 + text


def generate(root):
    root.mkdir(parents=True, exist_ok=True)
    html = '<html><head><title>隐藏标题</title><style>隐藏样式</style></head><body><h1>第一章</h1><p>我们沿着<em>河岸</em>慢慢向前走。雨已经停了。<p>&ldquo;故事&rdquo;继续了。<br>明天再见。<script>隐藏脚本</script></body></html>'
    for name, compression in [('sample.mobi', 2), ('uncompressed.mobi', 1)]:
        (root/name).write_bytes(mobi('MOBI测试电子书', html, compression))
    (root/'encrypted.mobi').write_bytes(mobi('加密书', html, encrypted=True))
    (root/'cp1252.mobi').write_bytes(mobi('Café', '<html><body><p>Café &amp; tea. It’s lovely.</body></html>', encoding=1252))
    (root/'corrupt.mobi').write_bytes(b'not a mobi')
    (root/'ReadleMOBI分享验证.mobi').write_bytes(mobi('ReadleMOBI分享验证', '<html><body><p>我们沿着河岸慢慢向前走。雨已经停了。</body></html>'))
    (root/'ReadleMOBI选择验证.mobi').write_bytes(mobi('ReadleMOBI选择验证', '<html><body><p>中文电子书也可以直接导入。点击一句就能翻译。</body></html>'))


if __name__ == '__main__':
    generate(Path(sys.argv[1]))
