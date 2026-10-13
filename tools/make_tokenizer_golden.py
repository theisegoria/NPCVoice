#!/usr/bin/env python3
"""Golden token ids for the native Qwen tokenizer, from Hugging Face's own code.

Needs `tokenizers` and `jinja2` (tools/requirements-dev.txt):
  python3 -I tools/make_tokenizer_golden.py <model_dir> <out.json>
"""
import json, sys
from tokenizers import Tokenizer
from jinja2.sandbox import ImmutableSandboxedEnvironment
from jinja2.exceptions import TemplateError

model_dir, out = sys.argv[1], sys.argv[2]
tok = Tokenizer.from_file(f"{model_dir}/tokenizer.json")
# Render chat_template.jinja the way transformers does (sandboxed, trim/lstrip blocks).
def _raise(msg): raise TemplateError(msg)
env = ImmutableSandboxedEnvironment(trim_blocks=True, lstrip_blocks=True, extensions=["jinja2.ext.loopcontrols"])
env.filters["tojson"] = lambda x, **kw: json.dumps(x, ensure_ascii=False)
env.globals["raise_exception"] = _raise
template = env.from_string(open(f"{model_dir}/chat_template.jinja").read())

corpus = [
    "Hello, world!",
    "A room at the Gull & Lantern costs three silver marks a night.",
    "  leading spaces, trailing spaces   ",
    "Multiple\n\nnewlines\r\nand\ttabs\t\there",
    "Numbers: 3, 42, 1999, 3.14159, 1,000,000 and -7e10.",
    "Contractions: don't, I'm, you're, we've, she'll, it'd, Rhys's, DON'T",
    "Punctuation!!! ?!? ... --- *stage directions* (parens) [brackets] {braces} \"quotes\" 'single'",
    "Unicode: café, naïve, résumé, Zoë, façade, Ångström",
    "Combining: café vs café",
    "Emoji: 🙂🔥👩‍💻🏳️‍🌈 end",
    "海辺の祠の鈴は、嵐の前の晩にひとりでに鳴る。",
    "「ようこそ、旅の方。」と彼女は言った。",
    "Mixed 日本語 and English, ｶﾀｶﾅ and ﻿zero‑width​joins",
    "<|im_start|>system\nYou are Marta.<|im_end|>\n<|im_start|>user\nHi<|im_end|>\n",
    "A literal <think> tag and </think> and <|endoftext|> inline.",
    '{"text":"Three marks, love.","emotion":"happy","intent":"inform","commands":[{"kind":"give_item","target":"room_key"}]}',
    "",
    " ",
    "\n",
    "x" * 300,
    "The quick brown fox jumps over the lazy dog. " * 20,
]
encodings = []
for text in corpus:
    ids = tok.encode(text, add_special_tokens=False).ids
    encodings.append({"text": text, "ids": ids, "decoded": tok.decode(ids, skip_special_tokens=False)})

chats = [
    [{"role": "system", "content": "You are Marta Venn, an innkeeper."}, {"role": "user", "content": "Evening. Got a room?"}],
    [{"role": "user", "content": "この祠について教えてください。"}],
    [{"role": "system", "content": "  padded system  \n"}, {"role": "user", "content": "First"},
     {"role": "assistant", "content": "Reply one."}, {"role": "user", "content": "Second"}],
]
templates = []
for messages in chats:
    text = template.render(messages=messages, add_generation_prompt=True, enable_thinking=False)
    ids = tok.encode(text, add_special_tokens=False).ids
    templates.append({"messages": messages, "text": text, "ids": ids})

json.dump({"source": "tokenizers " + __import__("tokenizers").__version__ + ", jinja2 " + __import__("jinja2").__version__ + " rendering chat_template.jinja",
           "encodings": encodings, "chat": templates}, open(out, "w"), ensure_ascii=False, indent=1)
print(f"wrote {out}: {len(encodings)} encodings, {len(templates)} chats")
