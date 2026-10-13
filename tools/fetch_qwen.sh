#!/bin/zsh
# Downloads mlx-community/Qwen3.5-2B-4bit at a pinned revision into
# third_party/models/qwen3.5-2b-4bit and records SHA-256s (approved by Ben 2026-10-12).
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=mlx-community/Qwen3.5-2B-4bit
REV=674aaa7240b91e8012fcad5d791b7dfe5ba90207
OUT=third_party/models/qwen3.5-2b-4bit
mkdir -p $OUT
for f in config.json chat_template.jinja model.safetensors model.safetensors.index.json tokenizer.json tokenizer_config.json vocab.json README.md; do
  [[ -s $OUT/$f ]] || curl -fL --retry 3 -o $OUT/$f.part "https://huggingface.co/$REPO/resolve/$REV/$f" && mv $OUT/$f.part $OUT/$f
done
( cd $OUT && shasum -a 256 config.json chat_template.jinja model.safetensors model.safetensors.index.json tokenizer.json tokenizer_config.json vocab.json > SHA256SUMS )
echo "done: $(du -sh $OUT | cut -f1)"
