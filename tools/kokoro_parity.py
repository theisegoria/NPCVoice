#!/usr/bin/env python3
"""Core ML vs PyTorch parity for the converted Kokoro stages, in perceptual terms.

Waveform SNR is phase-sensitive and says little about how a vocoder sounds; this
reports log-spectral distance (dB) and per-frame envelope correlation instead.
Run with the same isolated venv as convert_kokoro_coreml.py.
"""
import json, sys
from pathlib import Path
import numpy as np
import coremltools as ct

out = Path(sys.argv[1])
man = json.load(open(out / "manifest.json"))
A = ct.models.MLModel(str(out / "KokoroDuration.mlpackage"), compute_units=getattr(ct.ComputeUnit, __import__("os").environ.get("UNITS", "CPU_AND_GPU")))
B = ct.models.MLModel(str(out / "KokoroDecoder.mlpackage"), compute_units=getattr(ct.ComputeUnit, __import__("os").environ.get("UNITS", "CPU_AND_GPU")))

def stft_mag(x, n=1024, hop=256):
    w = np.hanning(n)
    frames = [np.abs(np.fft.rfft(w * x[i:i + n])) for i in range(0, len(x) - n, hop)]
    return np.array(frames) + 1e-5

for fx in man["fixtures"]:
    v = man["voices"][fx["voice"]]
    pack = np.fromfile(out / "voices" / f"{fx['voice']}.f32", dtype="<f4").reshape(v["rows"], v["dim"])
    ref = pack[len(fx["input_ids"]) - 3][None, :].astype(np.float32)
    ra = A.predict({"input_ids": np.array([fx["input_ids"]], dtype=np.int32), "ref_s": ref})
    pred = np.maximum(np.round(ra["duration"][0]), 1).astype(np.int64)
    idx = np.repeat(np.arange(len(pred)), pred)
    en = np.ascontiguousarray(np.transpose(ra["d"], (0, 2, 1))[:, :, idx]).astype(np.float32)
    asr = np.ascontiguousarray(ra["t_en"][:, :, idx]).astype(np.float32)
    got = B.predict({"en": en, "asr": asr, "ref_s": ref})["audio"].reshape(-1)
    want = np.fromfile(out / fx["audio"], dtype="<f4")
    G, W = stft_mag(got), stft_mag(want)
    lsd = float(np.mean(np.sqrt(np.mean((20 * np.log10(G) - 20 * np.log10(W)) ** 2, axis=1))))
    eg, ew = np.log(G.sum(1)), np.log(W.sum(1))
    corr = float(np.corrcoef(eg, ew)[0, 1])
    rms = lambda a: float(np.sqrt(np.mean(a ** 2)))
    print(f"{fx['voice']}: durations {'match' if pred.tolist() == fx['pred_dur'] else 'DIFFER'}, "
          f"LSD {lsd:.2f} dB, envelope r={corr:.4f}, rms {rms(got):.4f} vs {rms(want):.4f}")
