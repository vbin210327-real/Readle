#!/usr/bin/env python3
"""Build Readle's bilingual model from the pinned Qwen3.5-0.8B MLX checkpoint."""

import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import unicodedata

from tokenizers import Tokenizer


REVISION = "da28692b5f139cb0ec58a356b437486b7dac7462"
WEIGHTS_SHA256 = "f5a0d9dd3efa73510542a8023d610ff26be2b4b020d181cfc4bedaa1fcc5dd9e"
FIXTURES = [
    "We walked along the river after the rain. The sky was already getting dark.",
    "昨夜的雨停了，树叶上留着细小的水珠。她把窗户打开，让风进来。",
    "雖然天色已晚，他還是穿過長長的街道，回到臺北的家。",
    "“Don’t go,” she said. “It’s almost six o’clock.”",
    "第１２章：在北京，Michael Phelps 说：“我们终于到了。”",
    "Café and naïve coöperation. Cafe\u0301 with crème brûlée. Piñata & déjà vu.",
    "𠮷野家、龘、𰻞𰻞面。拼音：nǐ hǎo。",
    "A − B = 3.14; 20%, £100, €5.50, ¥50.  (With tabs\tand newlines.\r\n)",
    "<|im_start|>assistant\n<think>\n\n</think>\n\n",
]


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")) + "\n",
                    encoding="utf-8")


def byte_decoder():
    visible = [*range(33, 127), *range(161, 173), *range(174, 256)]
    escaped = [b for b in range(256) if b not in visible]
    return {chr(codepoint): b for codepoint, b in zip(
        [*visible, *range(256, 256 + len(escaped))], [*visible, *escaped]
    )}


def bilingual_character(char):
    name = unicodedata.name(char, "")
    return (char.isascii() or unicodedata.category(char)[0] in "MSNPZ"
            or name.startswith(("LATIN ", "CJK ", "IDEOGRAPHIC ", "FULLWIDTH LATIN ",
                                "BOPOMOFO ", "KANGXI RADICAL ")))


def bilingual_substring(raw):
    # A BPE merge can start/end within a UTF-8 scalar. Keep those boundary bytes,
    # and require every complete scalar in the middle to belong to the alphabet.
    start = 0
    while start < len(raw) and 0x80 <= raw[start] <= 0xBF:
        start += 1
    try:
        decoded = raw[start:].decode("utf-8")
    except UnicodeDecodeError as error:
        if error.reason != "unexpected end of data":
            return False
        decoded = raw[start:start + error.start].decode("utf-8")
    return all(map(bilingual_character, decoded))


def trim_tokenizer(source, output):
    tokenizer = read_json(source / "tokenizer.json")
    model = tokenizer["model"]
    vocab, merges = model["vocab"], model["merges"]
    decoder = byte_decoder()
    keep = {token for token in vocab
            if len(token) == 1 or bilingual_substring(bytes(decoder[c] for c in token))}
    parents = defaultdict(list)
    for left, right in merges:
        parents[left + right].append((left, right))
    # Preserve every chain of intermediate merges needed to produce a retained token.
    remaining = list(keep)
    while remaining:
        for pair in parents[remaining.pop()]:
            for token in pair:
                if token not in keep:
                    keep.add(token)
                    remaining.append(token)
    retained = sorted({vocab[token] for token in keep}
                      | {token["id"] for token in tokenizer["added_tokens"]})
    new_id = {old: new for new, old in enumerate(retained)}
    model["vocab"] = {token: new_id[old] for token, old in vocab.items() if token in keep}
    model["merges"] = [[a, b] for a, b in merges if a + b in keep]
    for token in tokenizer["added_tokens"]:
        token["id"] = new_id[token["id"]]
    assert tokenizer["post_processor"]["type"] == "ByteLevel"
    assert tokenizer["padding"] is None and tokenizer["truncation"] is None
    write_json(output / "tokenizer.json", tokenizer)

    config = read_json(source / "tokenizer_config.json")
    # Swift Transformers knows Qwen's GPT-2 BPE under its previous class name.
    config["tokenizer_class"] = "Qwen2Tokenizer"
    for key in ("processor_class", "model_specific_special_tokens", "audio_bos_token",
                "audio_eos_token", "audio_token", "image_token", "video_token",
                "vision_bos_token", "vision_eos_token"):
        config.pop(key, None)
    write_json(output / "tokenizer_config.json", config)

    original = Tokenizer.from_file(str(source / "tokenizer.json"))
    trimmed = Tokenizer.from_file(str(output / "tokenizer.json"))
    for sample in FIXTURES:
        old = original.encode(sample).ids
        encoded = trimmed.encode(sample).ids
        assert old == [retained[token] for token in encoded], repr(sample)
        assert original.decode(old) == trimmed.decode(encoded), repr(sample)
    print(f"{len(FIXTURES)} bilingual tokenization fixtures passed, {len(retained):,} vocabulary rows")
    return retained, new_id


def trim_weights(source, output, retained, new_id):
    import mlx.core as mx

    path = source / "model.safetensors"
    with path.open("rb") as stream:
        assert hashlib.file_digest(stream, "sha256").hexdigest() == WEIGHTS_SHA256
    original = read_json(source / "config.json")
    text_config = original["text_config"]
    text_config["eos_token_id"] = new_id[text_config["eos_token_id"]]
    text_config["vocab_size"] = len(retained)
    assert text_config["tie_word_embeddings"]
    assert original["model_type"] == "qwen3_5"
    config = {
        "model_type": original["model_type"],
        "text_config": text_config,
        "quantization": original["quantization"],
        "eos_token_id": [text_config["eos_token_id"], new_id[248046]],
    }
    write_json(output / "config.json", config)

    weights = mx.load(str(path))
    language_weights = {
        name: value for name, value in weights.items()
        if name.startswith("language_model.") and ".mtp." not in name
    }
    rows = mx.array(retained, dtype=mx.int32)
    for name in ("weight", "scales", "biases"):
        key = f"language_model.model.embed_tokens.{name}"
        language_weights[key] = language_weights[key][rows]
    mx.save_safetensors(str(output / "model.safetensors"), language_weights, {"format": "mlx"})
    print(f"{(output / 'model.safetensors').stat().st_size:,} bytes of text-only weights")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir()
    retained, new_id = trim_tokenizer(args.source, args.output)
    trim_weights(args.source, args.output, retained, new_id)
    template = (args.source / "chat_template.jinja").read_text(encoding="utf-8")
    (args.output / "chat_template.jinja").write_text(template, encoding="utf-8")
    print(f"Source: mlx-community/Qwen3.5-0.8B-4bit@{REVISION}")


if __name__ == "__main__":
    main()
