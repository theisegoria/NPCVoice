#!/usr/bin/env python3
"""Converts Kokoro-82M v1.0 to two Core ML models for NPCVoice's native TTS.

Maintainers only. Needs tools/requirements-dev.txt and a Kokoro-82M snapshot (see
tools/kokoro_engine.py):

  python3 -I tools/convert_kokoro_coreml.py --kokoro <snapshot> --out third_party/models/kokoro-82m-coreml

Split:
  KokoroDuration  input_ids[1,N] + ref_s[1,256] -> duration[1,N], d[1,N,640], t_en[1,512,N]
  (host)          pred_dur = clamp(round(duration / speed), 1); expand d and t_en by repetition
  KokoroDecoder   en[1,640,T] + asr[1,512,T] + ref_s[1,256] -> audio[1, T*600]

Export-time changes, all behaviour-preserving for batch 1:
  * pack_padded_sequence / pad_packed_sequence are identities (no padding at batch 1).
  * The decoder's random phase/noise is replaced by a deterministic low-discrepancy
    noise (same distribution family), so Core ML output can be checked against PyTorch.
  * SineGen: float `% 1` becomes x - floor(x) (coremltools mistranslates float remainder),
    the 1/300 downsample becomes an exact slice, and the x300 linear upsample is written
    with elementwise ops.
Also writes voices as raw float32, the vocab, and parity fixtures.
"""
from __future__ import annotations
import argparse, hashlib, json, math, struct, sys
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("--kokoro", required=True, type=Path, help="Kokoro-82M snapshot (config.json, kokoro-v1_0.pth, voices/)")
ap.add_argument("--out", required=True, type=Path)
ap.add_argument("--skip-convert", action="store_true", help="only write voices, vocab and fixtures")
ap.add_argument("--inspect-decoder", action="store_true", help="list TorchScript nodes coremltools cannot read")
ap.add_argument("--bisect-decoder", action="store_true", help="compare eager/traced/Core ML for decoder halves")
args = ap.parse_args()
sys.path.insert(0, str(Path(__file__).resolve().parent))   # -I leaves the script's folder off sys.path
import kokoro_engine  # noqa: E402
kokoro_engine.setup_imports()

import numpy as np  # noqa: E402
import torch  # noqa: E402
import torch.nn as nn  # noqa: E402

# ---------------------------------------------------------------- export-time patches

def _identity_pack(x, lengths, batch_first=False, enforce_sorted=True):
    return x
def _identity_unpack(x, batch_first=False, padding_value=0.0, total_length=None):
    return x, None
nn.utils.rnn.pack_padded_sequence = _identity_pack
nn.utils.rnn.pad_packed_sequence = _identity_unpack

def _det_uniform(shape, salt: float, like: torch.Tensor):
    n = 1
    for s in shape: n *= s
    idx = torch.arange(n, dtype=torch.float32, device=like.device).reshape(shape)
    # R2 low-discrepancy sequence: frac(i * alpha + salt), traceable and exact in fp32 for i < 2^24.
    v = idx * 0.7548776662466927 + salt
    return v - torch.floor(v)

def _det_randn_like(t: torch.Tensor, *a, **k):
    u1 = torch.clamp(_det_uniform(t.shape, 0.5, t), min=1e-6)
    v2 = torch.arange(u1.numel(), dtype=torch.float32, device=t.device).reshape(t.shape) * 0.5698402909980532 + 0.25
    u2 = v2 - torch.floor(v2)
    return torch.sqrt(-2.0 * torch.log(u1)) * torch.cos(2.0 * math.pi * u2)

def _zeros_rand(*size, device=None, **k):
    return torch.zeros(*size, device=device)

torch.randn_like = _det_randn_like
_orig_rsqrt = torch.rsqrt
def _float_rsqrt(x, *a, **k):   # Kokoro calls torch.rsqrt(torch.tensor(2)) on an int tensor
    return _orig_rsqrt(x if x.is_floating_point() else x.to(torch.float32), *a, **k)
torch.rsqrt = _float_rsqrt
torch.multiply = torch.mul        # alias coremltools does not map (SineGen harmonics)
torch.rand = _zeros_rand          # SineGen's initial harmonic phases: start in phase

from kokoro import istftnet  # noqa: E402
import torch.nn.functional as F  # noqa: E402

def _f02sine_exact(self, f0_values):
    """SineGen._f02sine (non-pulse branch) without the 1/upsample_scale interpolate.

    The F0 track reaching SineGen was nearest-upsampled by `upsample_scale`, so it is
    constant within each block, and linear downsampling (align_corners=False) samples
    each block's midpoint: exactly the block's value. Slicing gives the same numbers
    and converts to Core ML. Random initial phases are zero (see _zeros_rand).
    """
    rad = f0_values / self.sampling_rate
    rad = rad - torch.floor(rad)          # == % 1; coremltools mistranslates float remainder
    b, length, dim = rad.shape
    rad_frames = rad.reshape(b, -1, self.upsample_scale, dim)[:, :, 0, :]
    phase = torch.cumsum(rad_frames, dim=1) * 2 * torch.pi
    phase = _upsample_linear(phase.transpose(1, 2) * self.upsample_scale, self.upsample_scale).transpose(1, 2)
    return torch.sin(phase)

def _upsample_linear(x, scale: int):
    """F.interpolate(x, scale_factor=scale, mode="linear", align_corners=False) for an
    integer scale, written with elementwise ops so Core ML cannot reinterpret the
    sampling convention. Output sample k of block i reads source position
    i + (k + 0.5) / scale - 0.5, clamped at the edges like PyTorch."""
    prev = torch.cat([x[:, :, :1], x[:, :, :-1]], dim=2)
    nxt = torch.cat([x[:, :, 1:], x[:, :, -1:]], dim=2)
    t = (torch.arange(scale, dtype=torch.float32) + 0.5) / scale - 0.5
    a = torch.clamp(-t, min=0.0)          # weight on the previous frame
    c = torch.clamp(t, min=0.0)           # weight on the next frame
    b_ = 1.0 - a - c
    y = prev.unsqueeze(-1) * a + x.unsqueeze(-1) * b_ + nxt.unsqueeze(-1) * c
    return y.reshape(x.shape[0], x.shape[1], -1)

istftnet.SineGen._f02sine = _f02sine_exact

# ---------------------------------------------------------------- stages

engine = kokoro_engine.KokoroEngine(args.kokoro, device="cpu")
model = engine.model.eval()
# Real-valued, conv-based STFT (Kokoro's own disable_complex=True path, used for ONNX);
# the complex torch.stft graph is not convertible. No learned weights change.
from kokoro.custom_stft import CustomSTFT  # noqa: E402
_g = model.decoder.generator
_g.stft = CustomSTFT(filter_length=_g.post_n_fft, hop_length=_g.stft.hop_length, win_length=_g.post_n_fft)

class DurationStage(nn.Module):
    def __init__(self, m):
        super().__init__(); self.m = m
    def forward(self, input_ids, ref_s):
        n = input_ids.shape[1]
        lengths = torch.full((1,), n, dtype=torch.long)
        text_mask = torch.zeros((1, n), dtype=torch.bool)
        bert = self.m.bert(input_ids, attention_mask=torch.ones_like(input_ids))
        d_en = self.m.bert_encoder(bert).transpose(-1, -2)
        s = ref_s[:, 128:]
        d = self.m.predictor.text_encoder(d_en, s, lengths, text_mask)
        x, _ = self.m.predictor.lstm(d)
        duration = torch.sigmoid(self.m.predictor.duration_proj(x)).sum(dim=-1)
        t_en = self.m.text_encoder(input_ids, lengths, text_mask)
        return duration, d, t_en

class DecoderStage(nn.Module):
    def __init__(self, m):
        super().__init__(); self.m = m
    def forward(self, en, asr, ref_s):
        f0, n = self.m.predictor.F0Ntrain(en, ref_s[:, 128:])
        return self.m.decoder(asr, f0, n, ref_s[:, :128]).reshape(1, -1)

duration_stage = DurationStage(model).eval()
decoder_stage = DecoderStage(model).eval()

def expand(pred_dur: torch.Tensor, d: torch.Tensor, t_en: torch.Tensor):
    idx = torch.repeat_interleave(torch.arange(pred_dur.shape[0]), pred_dur)
    return d.transpose(-1, -2)[:, :, idx], t_en[:, :, idx]

@torch.no_grad()
def reference(phonemes: str, voice: str, speed: float = 1.0):
    ids = [0] + [engine.vocab[p] for p in phonemes if p in engine.vocab] + [0]
    pack, _ = engine.voice(voice)
    ref = pack[len(ids) - 3]  # KPipeline: ref_s = pack[len(phonemes) - 1]
    input_ids = torch.tensor([ids], dtype=torch.int32)
    duration, d, t_en = duration_stage(input_ids.long(), ref)
    pred = torch.clamp(torch.round(duration[0] / speed), min=1).long()
    en, asr = expand(pred, d, t_en)
    audio = decoder_stage(en, asr, ref)
    return ids, ref, duration, pred, en, asr, audio

# ---------------------------------------------------------------- outputs

out = args.out
out.mkdir(parents=True, exist_ok=True)
(out / "voices").mkdir(exist_ok=True)
(out / "fixtures").mkdir(exist_ok=True)
json.dump(engine.vocab, open(out / "vocab.json", "w"), ensure_ascii=False, indent=0, sort_keys=True)
voice_files = {}
for name in ["af_heart", "af_bella", "am_michael", "am_fenrir", "jf_alpha", "jf_tebukuro", "jm_kumo"]:
    pack, sha = engine.voice(name)
    arr = pack.squeeze(1).to(torch.float32).numpy()        # [510, 256]
    (out / "voices" / f"{name}.f32").write_bytes(arr.astype("<f4").tobytes())
    voice_files[name] = {"rows": int(arr.shape[0]), "dim": int(arr.shape[1]), "source_sha256": sha}

lines = [
    ("en", "af_heart", "A room at the Gull and Lantern costs three silver marks a night."),
    ("en", "am_michael", "Move along. The watch is busy."),
    ("ja", "jf_alpha", "ようこそ、旅の方。嵐の前の晩に、鈴が鳴ります。"),
]
fixtures = []
for lang, voice, text in lines:
    phonemes = engine.g2p(text, lang)
    ids, ref, duration, pred, en, asr, audio = reference(phonemes, voice)
    stem = f"{voice}"
    np.asarray(audio[0].numpy(), dtype="<f4").tofile(out / "fixtures" / f"{stem}.audio.f32")
    fixtures.append({"language": lang, "voice": voice, "text": text, "phonemes": phonemes, "input_ids": ids,
                     "duration": [round(float(x), 6) for x in duration[0]], "pred_dur": pred.tolist(),
                     "samples": int(audio.shape[1]), "audio": f"fixtures/{stem}.audio.f32"})
    print(f"{voice}: {len(ids)} ids, {int(pred.sum())} frames, {audio.shape[1] / 24000:.2f} s")
json.dump({"model": "kokoro-82m-v1.0", "model_sha256": engine.model_sha256, "sample_rate": 24000,
           "samples_per_frame": 600, "voices": voice_files, "fixtures": fixtures},
          open(out / "manifest.json", "w"), ensure_ascii=False, indent=1)

if args.skip_convert:
    sys.exit(0)

if args.bisect_decoder:
    import coremltools as ct
    _, ref_i, _, _, en_i, asr_i, _ = reference(engine.g2p(lines[0][2], "en"), "af_heart")
    def report(name, eager, traced, coreml):
        def cmp(a, b):
            a, b = np.asarray(a, dtype=np.float64).reshape(-1), np.asarray(b, dtype=np.float64).reshape(-1)
            m = min(len(a), len(b))
            return f"max|d| {np.abs(a[:m]-b[:m]).max():.2e} (|ref| max {np.abs(b[:m]).max():.2e}, n {len(a)} vs {len(b)})"
        print(f"{name}: traced vs eager {cmp(traced, eager)} | coreml vs eager {cmp(coreml, eager)}")
    class F0N(nn.Module):
        def __init__(s, m): super().__init__(); s.m = m
        def forward(s, en, ref): 
            f0, n = s.m.predictor.F0Ntrain(en, ref[:, 128:]); return f0, n
    class Gen(nn.Module):
        def __init__(s, m): super().__init__(); s.m = m
        def forward(s, asr, f0, n, ref): return s.m.decoder(asr, f0, n, ref[:, :128])
    with torch.no_grad():
        f0n = F0N(model).eval(); f0_e, n_e = f0n(en_i, ref_i)
        tr = torch.jit.trace(f0n, (en_i, ref_i), check_trace=False); f0_t, n_t = tr(en_i, ref_i)
        mm = ct.convert(tr, inputs=[ct.TensorType("en", shape=en_i.shape), ct.TensorType("ref", shape=ref_i.shape)],
                        minimum_deployment_target=ct.target.macOS15, compute_precision=ct.precision.FLOAT32)
        o = mm.predict({"en": en_i.numpy(), "ref": ref_i.numpy()})
        names = [x.name for x in mm.get_spec().description.output]
        report("F0Ntrain f0", f0_e, f0_t, o[names[0]]); report("F0Ntrain n", n_e, n_t, o[names[1]])
        gen = Gen(model).eval(); a_e = gen(asr_i, f0_e, n_e, ref_i)
        tg = torch.jit.trace(gen, (asr_i, f0_e, n_e, ref_i), check_trace=False); a_t = tg(asr_i, f0_e, n_e, ref_i)
        mg = ct.convert(tg, inputs=[ct.TensorType("asr", shape=asr_i.shape), ct.TensorType("f0", shape=f0_e.shape),
                                    ct.TensorType("n", shape=n_e.shape), ct.TensorType("ref", shape=ref_i.shape)],
                        minimum_deployment_target=ct.target.macOS15, compute_precision=ct.precision.FLOAT32)
        og = list(mg.predict({"asr": asr_i.numpy(), "f0": f0_e.numpy(), "n": n_e.numpy(), "ref": ref_i.numpy()}).values())[0]
        report("generator audio", a_e, a_t, og)
        sg = model.decoder.generator.m_source
        up = model.decoder.generator.f0_upsamp(f0_e[:, None]).transpose(1, 2)
        class Src(nn.Module):
            def __init__(s, m): super().__init__(); s.m = m
            def forward(s, x): h, _, _ = s.m(x); return h
        src = Src(sg).eval(); h_e = src(up); ts = torch.jit.trace(src, (up,), check_trace=False)
        ms = ct.convert(ts, inputs=[ct.TensorType("x", shape=up.shape)], minimum_deployment_target=ct.target.macOS15,
                        compute_precision=ct.precision.FLOAT32)
        report("harmonic source", h_e, ts(up), list(ms.predict({"x": up.numpy()}).values())[0])
    sys.exit(0)

if args.inspect_decoder:
    _, ref_i, _, _, en_i, asr_i, _ = reference(engine.g2p(lines[0][2], "en"), "af_heart")
    with torch.no_grad():
        tb = torch.jit.trace(decoder_stage, (en_i, asr_i, ref_i), check_trace=False)
    torch._C._jit_pass_inline(tb.graph)
    for node in tb.graph.nodes():
        kinds = {a: node.kindOf(a) for a in node.attributeNames()}
        if any(k not in ("i", "f", "s", "t", "is", "fs", "g", "ival") for k in kinds.values()):
            print(node.kind(), kinds, str(node.sourceRange())[:200].replace("\n", " | "))
    sys.exit(0)

import coremltools as ct  # noqa: E402

ids0, ref0, _, pred0, en0, asr0, _ = reference(lines[0][2] and engine.g2p(lines[0][2], "en"), "af_heart")
with torch.no_grad():
    traced_a = torch.jit.trace(duration_stage, (torch.tensor([ids0], dtype=torch.long), ref0), check_trace=False)

n = ct.RangeDim(lower_bound=3, upper_bound=512, default=len(ids0))
mlA = ct.convert(traced_a,
                 inputs=[ct.TensorType("input_ids", shape=(1, n), dtype=np.int32),
                         ct.TensorType("ref_s", shape=(1, 256), dtype=np.float32)],
                 outputs=[ct.TensorType("duration"), ct.TensorType("d"), ct.TensorType("t_en")],
                 minimum_deployment_target=ct.target.macOS15, compute_precision=ct.precision.FLOAT32,
                 compute_units=ct.ComputeUnit.CPU_AND_GPU)
mlA.short_description = "Kokoro-82M v1.0 stage 1: ALBERT + duration predictor + text encoder"
mlA.save(str(out / "KokoroDuration.mlpackage"))
print("saved KokoroDuration")

with torch.no_grad():
    traced_b = torch.jit.trace(decoder_stage, (en0, asr0, ref0), check_trace=False)
t = ct.RangeDim(lower_bound=2, upper_bound=3000, default=int(en0.shape[2]))
mlB = ct.convert(traced_b,
                 inputs=[ct.TensorType("en", shape=(1, 640, t), dtype=np.float32),
                         ct.TensorType("asr", shape=(1, 512, t), dtype=np.float32),
                         ct.TensorType("ref_s", shape=(1, 256), dtype=np.float32)],
                 outputs=[ct.TensorType("audio")],
                 minimum_deployment_target=ct.target.macOS15, compute_precision=ct.precision.FLOAT32,
                 compute_units=ct.ComputeUnit.CPU_AND_GPU)
mlB.short_description = "Kokoro-82M v1.0 stage 2: F0/energy predictor + iSTFTNet decoder (24 kHz)"
mlB.save(str(out / "KokoroDecoder.mlpackage"))
print("saved KokoroDecoder")

# Parity on the fixtures, through Core ML itself.
for fx in fixtures:
    ids = np.array([fx["input_ids"]], dtype=np.int32)
    pack, _ = engine.voice(fx["voice"])
    ref = pack[len(fx["input_ids"]) - 3].numpy().astype(np.float32)
    ra = mlA.predict({"input_ids": ids, "ref_s": ref})
    pred = np.maximum(np.round(ra["duration"][0]), 1).astype(np.int64)
    idx = np.repeat(np.arange(len(pred)), pred)
    en = np.ascontiguousarray(np.transpose(ra["d"], (0, 2, 1))[:, :, idx]).astype(np.float32)
    asr = np.ascontiguousarray(ra["t_en"][:, :, idx]).astype(np.float32)
    rb = mlB.predict({"en": en, "asr": asr, "ref_s": ref})
    audio = rb["audio"].reshape(-1)
    want = np.fromfile(out / fx["audio"], dtype="<f4")
    dur_ok = pred.tolist() == fx["pred_dur"]
    m = min(len(audio), len(want))
    err = float(np.abs(audio[:m] - want[:m]).max()) if m else float("nan")
    snr = 10 * math.log10(float(np.sum(want[:m] ** 2)) / max(1e-12, float(np.sum((audio[:m] - want[:m]) ** 2))))
    print(f"parity {fx['voice']}: durations {'match' if dur_ok else 'DIFFER'}, samples {len(audio)} vs {len(want)}, max |err| {err:.2e}, SNR {snr:.1f} dB")
