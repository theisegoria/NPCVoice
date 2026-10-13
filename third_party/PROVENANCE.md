# Third-party provenance

Everything here is pinned. Builds use local paths only; nothing is fetched at build time.

## MLX stack (dialogue backend)

| Package | Version | Commit | License | Notes |
|---|---|---|---|---|
| mlx-swift | 0.32.3 | 19601207e9a0de51e03ee6ec0c3c5f3784275075 | MIT | submodules mlx 1f8e74e3, mlx-c ebc88f10. Patch: swift-numerics dependency → `../swift-numerics` |
| mlx-swift-lm | 3.32.3 | 3b339ad6e3b3f44c8121ecff5131c7fd55e075e6 | MIT | Patch: trimmed `Package.swift` (upstream kept as `Package.swift.upstream`). Keeps MLXLMCommon, MLXLLM, MLXCXGrammar, MLXGuidedGeneration, MLXFoundationModels. Includes vendored xgrammar (Apache-2.0, see `Libraries/MLXCXGrammar/xgrammar/NOTICE`). Patch 2: `Libraries/MLXCXGrammar/shim.cc` `xg_compile_json_schema` compiles with `any_whitespace=false` and compact separators, so JSON structure is fully fast-forwarded |
| swift-numerics | 1.1.1 | 0c0290ff6b24942dadb83a929ffaaa1481df04a2 | Apache-2.0 | unmodified |

Exact pins are also in `PINS-mlx.txt`. `.git` and `.github` were stripped. Refresh by re-cloning at a new tag, re-applying the two patches, then running the full test suite.

## Models

| Model | Source | Revision | License | Fetch |
|---|---|---|---|---|
| Qwen3.5-2B 4-bit (MLX) | huggingface.co/mlx-community/Qwen3.5-2B-4bit | 674aaa7240b91e8012fcad5d791b7dfe5ba90207 | Apache-2.0 (base: Qwen/Qwen3.5-2B) | `tools/fetch_qwen.sh` (from Hugging Face) or `tools/fetch_models.sh` (release assets); SHA-256s in `models/qwen3.5-2b-4bit/SHA256SUMS` |
| Kokoro-82M v1.0 → Core ML | converted by `tools/convert_kokoro_coreml.py` from huggingface.co/hexgrad/Kokoro-82M (revision f3ff3571791e39611d31c381e3a41a3af07b4987; model SHA-256 in `kokoro-82m-coreml/manifest.json`) with the `kokoro` 0.9.4 model code | — | Apache-2.0. Voices `jf_tebukuro`/`jm_kumo` need CC BY 3.0 Koniwa credit if shipped | Two stages (KokoroDuration, KokoroDecoder), fp32 CPU+GPU. Export-time changes, all output-preserving: identity pack/pad (batch 1), CustomSTFT, deterministic noise, exact SineGen rewrites (float `%` → x−floor(x), slice for ÷300, elementwise ×300). Parity (`tools/kokoro_parity.py`): durations identical; LSD 0.29–0.64 dB; waveform SNR 34–36 dB (EN+JA) |
| misaki English lexicons | `misaki-en/us_gold.json`, `us_silver.json` from misaki 0.9.4 on PyPI (wheel SHA `90e2eeb1…`, `misaki/data/`) | — | Apache-2.0 | Used by `EnglishG2P` (a Swift port of misaki `en.py`; parity fixtures from `tools/make_g2p_golden.py`) |
| misaki Japanese tables | `misaki-ja/hepburn.json` (cutlet kana→phoneme table) and `ja_words.txt`, exported from misaki 0.9.4 by `tools/make_ja_golden.py` | — | Apache-2.0 (misaki; cutlet is MIT) | Used by `JapaneseG2P`. Readings come from macOS CFStringTokenizer instead of MeCab/UniDic |

The model's tokenizer is handled by NPCVoice's own `NPCTokenizer`, not swift-transformers, which avoids its dependency tree (swift-huggingface, swift-crypto/BoringSSL, swift-jinja, yyjson). It is verified token-for-token against `tokenizers` 0.22.2 and against the model's `chat_template.jinja` rendered with jinja2 (`tools/make_tokenizer_golden.py`).

Maintainer tools that regenerate these (conversion, parity fixtures) need `tools/requirements-dev.txt`; see `tools/kokoro_engine.py` for the Kokoro snapshot.
