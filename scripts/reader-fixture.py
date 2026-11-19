"""Install/remove a long book fixture only in an existing Readle simulator container."""
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', sys.argv[1], 'com.linfanbin.readle', 'data'], text=True).strip())
assert '/CoreSimulator/Devices/' in str(container), 'Simulator container required'
inline = '--inline' in sys.argv
bilingual = '--bilingual' in sys.argv
title = 'Readle译文验证' if inline else 'Readle定位验证'
fixture_id = 'C52FB6E5-1731-4B45-B9F4-F794B2B7B090' if inline else 'AA108744-1E23-4C64-A701-81CA1E074A04'
if bilingual:
    title = 'Readle双向验证'
    fixture_id = '9A76D1C3-492B-416A-9BCA-323746262876'
root = container / 'Library/Application Support/Readle' / fixture_id
if '--remove' in sys.argv:
    if root.exists():
        assert json.loads((root/'summary.json').read_text())['title'] == title
        shutil.rmtree(root)
else:
    if (root/'summary.json').exists():
        assert json.loads((root/'summary.json').read_text())['title'] == title
    root.mkdir(parents=True, exist_ok=True)
    chapters = []
    for c in range(2):
        paragraphs = []
        for i in range(100):
            text = f'第{c+1}节，第{i+1}段。' + '河边的小路很安静，我们慢慢向前走，看见树叶上还留着昨夜的雨珠。' * 4
            paragraphs.append({'id': i*2, 'sentences': [{'id': i*2, 'text': text}, {'id': i*2+1, 'text': '翻过这一页，还会看到更多的故事。'}]})
        chapters.append({'id': c, 'title': ['第一节 · 定位测试', '第二节 · 定位测试'][c], 'paragraphs': paragraphs})
    if inline:
        sentences = ['窗外的雨停了。', '院子里的树叶还挂着水珠。', '我们准备沿着河岸慢慢走。', '远处的小桥在晨光中亮起来。']
        chapters[0]['paragraphs'][0] = {'id': 0, 'sentences': [{'id': i, 'text': text} for i, text in enumerate(sentences)]}
        # Retain enough content to scroll through the split paragraph's continuation.
        chapters[0]['paragraphs'] = [chapters[0]['paragraphs'][0]] + [
            {'id': p['id'] + 2, 'sentences': [{'id': s['id'] + 2, 'text': s['text']} for s in p['sentences']]}
            for p in chapters[0]['paragraphs'][1:]
        ]
    if bilingual:
        chapters = [{'id': 0, 'title': 'A morning walk', 'paragraphs': [{'id': 0, 'sentences': [{'id': 0, 'text': 'Raindrops covered the leaves. '}, {'id': 1, 'text': 'We walked along the river.'}]}]}]
    book = {'id': root.name, 'title': title, 'author': '仅模拟器测试', 'format': 'TXT', 'chapters': chapters}
    summary = {k: book[k] for k in ['id', 'title', 'author', 'format']}
    summary.update(chapterCount=len(chapters), sentenceCount=sum(len(p['sentences']) for c in chapters for p in c['paragraphs']), addedAt=time.time()-978307200)
    (root/'content.json').write_text(json.dumps(book, ensure_ascii=False))
    (root/'summary.json').write_text(json.dumps(summary, ensure_ascii=False))
    (root/'reading.json').unlink(missing_ok=True)
    if inline:
        translations = ['The rain outside the window has stopped.', 'Raindrops still cling to the leaves in the courtyard.', 'We are getting ready to walk slowly along the riverbank.', 'The little bridge in the distance glows in the morning light.']
        (root/'reading.json').write_text(json.dumps({'chapterIndex': 0, 'translations': {f'english:0:{i}': text for i, text in enumerate(translations)}}))
    if bilingual:
        (root/'reading.json').write_text(json.dumps({'chapterIndex': 0, 'direction': 'chinese', 'translations': {'chinese:0:0': '雨珠覆盖了树叶。', 'english:0:0': 'Raindrops covered the leaves.', 'word:chinese:0:0:Raindrops': '雨滴；此处指停留在树叶上的雨珠。'}}))
