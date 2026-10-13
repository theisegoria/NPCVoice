"""Kokoro-82M and misaki for NPCVoice's maintainer tools (Core ML conversion, parity fixtures).

Needs the packages in tools/requirements-dev.txt and a local snapshot of the model:
  huggingface-cli download hexgrad/Kokoro-82M --revision f3ff3571791e39611d31c381e3a41a3af07b4987 \
      --local-dir <snapshot>     # config.json, kokoro-v1_0.pth, voices/*.pt

Import setup_imports() before misaki or kokoro: misaki.ja imports pyopenjtalk at load time
although the cutlet path (fugashi + UniDic-lite) never calls it, and kokoro/__init__.py pulls
in the pipeline and espeak. Neither is needed or installed.
"""
from __future__ import annotations

import hashlib
import importlib
import importlib.util
import sys
import types
from pathlib import Path


def setup_imports() -> None:
    if "pyopenjtalk" not in sys.modules:
        stub = types.ModuleType("pyopenjtalk")

        def refuse(*_a, **_k):
            raise RuntimeError("pyopenjtalk isn't used: NPCVoice's Japanese G2P follows misaki's cutlet path")

        def attr(name):
            if name.startswith("__"):
                raise AttributeError(name)
            return refuse

        stub.__getattr__ = attr
        sys.modules["pyopenjtalk"] = stub
    if "kokoro" not in sys.modules:
        spec = importlib.util.find_spec("kokoro")
        if spec is None or not spec.submodule_search_locations:
            raise RuntimeError("kokoro is not installed (pip install -r tools/requirements-dev.txt)")
        pkg = types.ModuleType("kokoro")
        pkg.__path__ = list(spec.submodule_search_locations)   # load kokoro.model etc. without __init__
        sys.modules["kokoro"] = pkg


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


class KokoroEngine:
    """The model (strict load), its vocab, the voice packs and misaki G2P, as Kokoro uses them."""

    def __init__(self, snapshot: Path, device: str = "cpu"):
        setup_imports()
        import torch
        if device == "cpu":
            torch.use_deterministic_algorithms(True)
        from loguru import logger      # kokoro logs its (expected) non-strict load at DEBUG
        logger.remove()
        logger.add(sys.stderr, level="WARNING")
        import warnings
        warnings.filterwarnings("ignore", category=UserWarning, module="torch.nn.modules.rnn")
        warnings.filterwarnings("ignore", category=FutureWarning, module="torch.nn.utils.weight_norm")
        self.snapshot = Path(snapshot)
        config = self.snapshot / "config.json"
        weights = self.snapshot / "kokoro-v1_0.pth"
        self.model_sha256 = sha256_file(weights)
        model = importlib.import_module("kokoro.model").KModel(
            repo_id="hexgrad/Kokoro-82M", config=str(config), model=str(weights))
        # KModel quietly falls back to a non-strict load. Reload each component and accept only
        # the known gap: the AdaIN norms' affine parameters are absent from the checkpoint and
        # stay at identity (weight 1, bias 0). Any other missing or unexpected key is an error.
        for key, state in torch.load(weights, map_location="cpu", weights_only=True).items():
            state = {(k[7:] if k.startswith("module.") else k): v for k, v in state.items()}
            component = getattr(model, key)
            result = component.load_state_dict(state, strict=False)
            params = dict(component.named_parameters())
            for name in result.missing_keys:
                identity = 1.0 if name.endswith(".norm.weight") else 0.0
                if not name.endswith((".norm.weight", ".norm.bias")) or not bool((params[name] == identity).all()):
                    raise RuntimeError(f"checkpoint is missing a non-identity parameter: {key}.{name}")
            if result.unexpected_keys:
                raise RuntimeError(f"checkpoint has unexpected keys in {key}: {', '.join(result.unexpected_keys[:5])}")
        self.model = model.eval().to(device)
        self.vocab = model.vocab
        self._g2p: dict = {}
        self._voices: dict = {}

    def g2p(self, text: str, language: str) -> str:
        if language not in self._g2p:
            if language == "en":
                from misaki import en
                self._g2p[language] = en.G2P(trf=False, british=False, fallback=None)
            elif language == "ja":
                from misaki import ja
                self._g2p[language] = ja.JAG2P()
            else:
                raise ValueError("unsupported language: " + language)
        phonemes, _ = self._g2p[language](text)
        if "❓" in phonemes:
            raise ValueError("misaki has no pronunciation for part of the line: " + phonemes)
        return phonemes

    def voice(self, name: str):
        """The voice pack tensor and its file's SHA-256."""
        if name not in self._voices:
            import torch
            path = self.snapshot / "voices" / (name + ".pt")
            if not path.is_file():
                raise ValueError("no voice file " + str(path))
            self._voices[name] = (torch.load(path, map_location="cpu", weights_only=True), sha256_file(path))
        return self._voices[name]
