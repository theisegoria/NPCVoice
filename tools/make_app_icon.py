#!/usr/bin/env python3
"""Builds the full-bleed macOS AppIcon set from Codex's icon art.

macOS 26+ masks app icons itself; artwork with transparent margins gets placed on a
grey squircle. So we lift the blue glass face (bubbles included) off its rim,
extend its colours smoothly to the canvas edges, and frame the bubbles so the
blue fills the whole icon.

Usage: python3 -I tools/make_app_icon.py [source.png]
"""
import json
import pathlib
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "assets/icons/dialogue-app-icon-v1.png"
OUT = ROOT / "App/Resources/Assets.xcassets/AppIcon.appiconset"

# Geometry of v1 art (1254 px): inner face inside the glass rim, and the bubbles.
FACE = (160, 155, 1100, 1078)       # left, top, right, bottom (inside the rim)
FACE_RADIUS = 170
BUBBLES = (187, 247, 1064, 986)
BUBBLE_FRACTION = 0.72              # bubbles' width as a share of the icon


def push_pull_fill(rgb: np.ndarray, weight: np.ndarray) -> np.ndarray:
    """Fills pixels with zero weight from their neighbourhood (smooth extrapolation)."""
    if min(rgb.shape[:2]) <= 2 or weight.min() > 0.999:
        return rgb
    h, w = weight.shape
    h2, w2 = (h + 1) // 2, (w + 1) // 2
    pad = ((0, h2 * 2 - h), (0, w2 * 2 - w))
    wp = np.pad(weight, pad)
    cp = np.pad(rgb * weight[..., None], pad + ((0, 0),))
    ws = wp.reshape(h2, 2, w2, 2).sum((1, 3))
    cs = cp.reshape(h2, 2, w2, 2, 3).sum((1, 3))
    small = np.where(ws[..., None] > 0, cs / np.maximum(ws, 1e-6)[..., None], 0)
    small = push_pull_fill(small, np.minimum(ws, 1.0))
    up = np.asarray(Image.fromarray(small.astype(np.float32).transpose(2, 0, 1)[0]).resize((w, h), Image.BILINEAR))
    ups = [np.asarray(Image.fromarray(small[..., i].astype(np.float32)).resize((w, h), Image.BILINEAR)) for i in range(3)]
    up = np.stack(ups, -1)
    return rgb * weight[..., None] + up * (1 - weight[..., None])


def bubble_mask(rgb: np.ndarray) -> np.ndarray:
    """Silhouette of the two speech bubbles (light glass on a mid-blue face)."""
    from scipy import ndimage
    lum = rgb.max(-1) * 0.5 + rgb.min(-1) * 0.5           # HLS lightness
    bl, bt, br, bb = BUBBLES
    region = np.zeros(lum.shape, bool)
    region[bt - 12:bb + 12, bl - 12:br + 12] = True
    m = (lum > 0.6) & region
    m = ndimage.binary_closing(m, structure=disc(6), iterations=2)
    m = ndimage.binary_fill_holes(m)
    labels, n = ndimage.label(m)
    if n > 1:                                               # keep the bubbles, drop specks
        sizes = ndimage.sum(m, labels, range(1, n + 1))
        keep = [i + 1 for i, s in enumerate(sizes) if s > sizes.max() * 0.05]
        m = np.isin(labels, keep)
    m = ndimage.binary_opening(m, structure=disc(2))
    soft = Image.fromarray((m * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(1.6))
    return np.asarray(soft, dtype=np.float32) / 255.0


def disc(r: int) -> np.ndarray:
    y, x = np.ogrid[-r:r + 1, -r:r + 1]
    return x * x + y * y <= r * r


def main() -> None:
    art = Image.open(SRC).convert("RGBA")
    rgb = np.asarray(art, dtype=np.float32)[..., :3] / 255.0
    bubbles = bubble_mask(rgb)

    # Background lighting: the glass face with the bubbles and rim removed, extended
    # to the canvas and blurred to low frequency only (no rim, no ghost edges).
    face = Image.new("L", art.size, 0)
    ImageDraw.Draw(face).rounded_rectangle(FACE, radius=FACE_RADIUS, fill=255)
    known = (np.asarray(face) > 0) & (bubbles < 0.01)
    from scipy import ndimage
    known = ndimage.binary_erosion(known, structure=disc(14))   # stay clear of glows
    background = push_pull_fill(rgb.copy(), known.astype(np.float32))
    bg = Image.fromarray((background * 255).clip(0, 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(90))
    background = np.asarray(bg, dtype=np.float32) / 255.0

    # Soft glow under the bubbles keeps the glassy depth of the original.
    glow = np.asarray(Image.fromarray((bubbles * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(26)), dtype=np.float32) / 255.0
    background = background + (np.array([0.55, 0.85, 1.0]) - background) * (glow[..., None] * 0.35)

    composite = rgb * bubbles[..., None] + background * (1 - bubbles[..., None])

    # Frame: bubbles centred, filling BUBBLE_FRACTION of the icon width.
    bl, bt, br, bb = BUBBLES
    cx, cy = (bl + br) / 2, (bt + bb) / 2
    half = (br - bl) / BUBBLE_FRACTION / 2
    big = Image.fromarray((composite * 255).clip(0, 255).astype(np.uint8))
    pad = int(max(0, half - min(cx, cy, art.width - cx, art.height - cy))) + 8
    if pad:
        big = Image.fromarray(np.pad(np.asarray(big), ((pad, pad), (pad, pad), (0, 0)), mode="edge"))
        cx += pad; cy += pad
    icon = big.crop((round(cx - half), round(cy - half), round(cx + half), round(cy + half))).resize((1024, 1024), Image.LANCZOS)

    OUT.mkdir(parents=True, exist_ok=True)
    images = []
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
            icon.resize((px, px), Image.LANCZOS).convert("RGB").save(OUT / name)
            images.append({"idiom": "mac", "scale": f"{scale}x", "size": f"{pt}x{pt}", "filename": name})
    (OUT / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    icon.convert("RGB").save(ROOT / "build/app-icon-1024.png")
    print("wrote", OUT)


if __name__ == "__main__":
    main()
