#!/usr/bin/env python3
"""Build macos/AppIcon.icns from the two source logos in macos/icon-src/.

The icon is a light squircle holding the Planning Center Services tile
(top left) and the ProPresenter tile (bottom right), joined by a pair of
sync arrows, one in each app's colour. Needs Pillow:  pip install pillow
Run from anywhere:  python3 scripts/make-icon.py
"""
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "macos" / "icon-src"
SS = 4                      # supersampling factor
N = 1024 * SS               # working canvas


def superellipse(cx, cy, r, n=5.0, steps=720):
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        x = abs(c) ** (2 / n) * r * (1 if c >= 0 else -1)
        y = abs(s) ** (2 / n) * r * (1 if s >= 0 else -1)
        pts.append((cx + x, cy + y))
    return pts


def squircle_mask(size):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).polygon(superellipse(size / 2, size / 2, size / 2), fill=255)
    return m


def tile(path, size):
    im = Image.open(path).convert("RGBA").resize((size, size), Image.LANCZOS)
    # Re-mask both logos with the same squircle so they match exactly
    # (the ProPresenter source is a full-bleed square).
    mask = squircle_mask(size)
    alpha = Image.composite(im.getchannel("A"), Image.new("L", im.size, 0), mask)
    im.putalpha(alpha)
    return im


def shadow(img, offset, blur, opacity):
    a = img.getchannel("A").point(lambda v: int(v * opacity))
    sh = Image.new("RGBA", img.size, (0, 0, 0, 0))
    sh.putalpha(a)
    return sh.filter(ImageFilter.GaussianBlur(blur)), offset


def arrow_arc(draw, cx, cy, r, start, end, width, color):
    """Clockwise arc from start to end (degrees, PIL convention) with a head at end."""
    draw.arc([cx - r, cy - r, cx + r, cy + r], start, end, fill=color, width=width)
    # round the tail
    ts = math.radians(start)
    rm = r - width / 2
    tx, ty = cx + rm * math.cos(ts), cy + rm * math.sin(ts)
    draw.ellipse([tx - width / 2, ty - width / 2, tx + width / 2, ty + width / 2], fill=color)
    # arrow head at end, pointing along the clockwise tangent
    te = math.radians(end)
    hx, hy = cx + rm * math.cos(te), cy + rm * math.sin(te)
    tan = (-math.sin(te), math.cos(te))          # clockwise direction (y down)
    nrm = (math.cos(te), math.sin(te))
    L, W = width * 1.9, width * 1.55
    tip = (hx + tan[0] * L, hy + tan[1] * L)
    b1 = (hx + nrm[0] * W, hy + nrm[1] * W)
    b2 = (hx - nrm[0] * W, hy - nrm[1] * W)
    draw.polygon([tip, b1, b2], fill=color)


def main():
    canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))

    # Background squircle on the macOS icon grid (824 of 1024), soft light gradient.
    bg_size = 824 * SS
    bg_off = (N - bg_size) // 2
    grad = Image.new("RGBA", (bg_size, bg_size))
    gd = ImageDraw.Draw(grad)
    top, bot = (252, 252, 253), (226, 229, 234)
    for y in range(bg_size):
        t = y / (bg_size - 1)
        gd.line([(0, y), (bg_size, y)], fill=tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)) + (255,))
    grad.putalpha(squircle_mask(bg_size))
    sh, _ = shadow(grad, 0, 14 * SS, 0.35)
    canvas.alpha_composite(sh, (bg_off, bg_off + 10 * SS))
    canvas.alpha_composite(grad, (bg_off, bg_off))

    # The two app tiles.
    ts = 372 * SS
    inset = 62 * SS
    pco = tile(SRC / "planning-center-services.png", ts)
    pro = tile(SRC / "propresenter.png", ts)
    p1 = (bg_off + inset, bg_off + inset)
    p2 = (bg_off + bg_size - inset - ts, bg_off + bg_size - inset - ts)
    for im, p in ((pco, p1), (pro, p2)):
        s, _ = shadow(im, 0, 10 * SS, 0.30)
        canvas.alpha_composite(s, (p[0], p[1] + 8 * SS))
        canvas.alpha_composite(im, p)

    # Sync badge in the middle: white disc with two arrows chasing each other.
    c = N // 2
    br = 148 * SS
    disc = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(disc).ellipse([c - br, c - br, c + br, c + br], fill=(255, 255, 255, 255))
    s, _ = shadow(disc, 0, 12 * SS, 0.30)
    canvas.alpha_composite(s, (0, 6 * SS))
    canvas.alpha_composite(disc)

    d = ImageDraw.Draw(canvas)
    ar = 100 * SS
    w = 30 * SS
    green = (98, 166, 58, 255)     # Services
    orange = (255, 110, 64, 255)   # ProPresenter
    arrow_arc(d, c, c, ar, 200, 330, w, green)    # top: left → right
    arrow_arc(d, c, c, ar, 20, 150, w, orange)    # bottom: right → left

    icon = canvas.resize((1024, 1024), Image.LANCZOS)
    icon.save(ROOT / "macos" / "AppIcon.png")
    icon.save(ROOT / "macos" / "AppIcon.icns")
    print("wrote macos/AppIcon.icns and macos/AppIcon.png")


if __name__ == "__main__":
    main()
