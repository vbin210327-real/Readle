#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/readle-tests.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
import sys, zipfile
from pathlib import Path
root = Path(sys.argv[1])
(root/'sample.txt').write_text('天刚亮，我推开窗。昨夜的雨停了！你要出门吗？\n我们沿着河岸走。', encoding='utf-8')
(root/'utf16.txt').write_bytes('中文内容。'.encode('utf-16'))
(root/'gb.txt').write_bytes('中文内容。'.encode('gb18030'))
with zipfile.ZipFile(root/'sample.epub', 'w', compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr('mimetype', 'application/epub+zip', compress_type=zipfile.ZIP_STORED)
    z.writestr('META-INF/container.xml', '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>')
    z.writestr('OPS/book.opf', '<package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>测试电子书</dc:title><dc:creator>测试作者</dc:creator></metadata><manifest><item id="b" href="Text/second%20chapter.xhtml" media-type="application/xhtml+xml"/><item id="a" href="Text/first.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="a"/><itemref idref="b"/></spine></package>')
    z.writestr('OPS/Text/first.xhtml', '<html><head><title>ignored</title></head><body><nav>跳过的导航</nav><h1>第一章</h1><p>昨夜的<em>雨</em>停了。今天出门。</p></body></html>')
    z.writestr('OPS/Text/second chapter.xhtml', '<html><body><h1>第二章</h1><p>&ldquo;故事&rdquo;继续了。我们&nbsp;坐下来。</p></body></html>')
(root/'corrupt.epub').write_bytes(b'not a zip')
PY
python3 scripts/mobi-fixtures.py "$test_dir"
for source in Readle/Vendor/libmobi/*.c Readle/Core/MOBIBridge.c; do
    xcrun clang -c -O2 -I "$(xcrun --show-sdk-path)/usr/include/libxml2" "$source" -o "$test_dir/$(basename "${source%.c}").o"
done
swiftc -parse-as-library -module-cache-path "$test_dir/modules" -import-objc-header Readle/Readle-Bridging-Header.h Readle/Core/Book.swift Readle/Core/ZIPArchive.swift Readle/Core/MOBIImporter.swift Readle/Core/BookImporter.swift Readle/Core/BookRepository.swift Readle/Core/SharedImportInbox.swift Readle/Core/TranslationService.swift Readle/Core/TranslationAllowance.swift Tests/CoreTests.swift "$test_dir"/*.o -lz -lxml2 -o "$test_dir/core-tests"
"$test_dir/core-tests" "$test_dir" "$@"
