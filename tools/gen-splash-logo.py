# -*- coding: utf-8 -*-
"""生成启动页 logo

用法：
  python gen-splash-logo.py                  # 只重建浅色（从 foreground.png 裁圆形徽标）
  python gen-splash-logo.py <深色源图.png>    # 额外用它生成 deep 模式的 startIcon

深色源图要求：正方形或近似正方形，纯黑背景会被抠成透明。
"""
import os
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "entry", "src", "main", "resources")


def build_light():
    src = os.path.join(RES, "base", "media", "foreground.png")
    im = Image.open(src).convert("RGBA").resize((512, 512), Image.LANCZOS)
    w, h = im.size
    px = im.load()

    def is_white(p):
        r, g, b, a = p
        return a > 10 and r > 235 and g > 235 and b > 235

    xs, ys = [], []
    for y in range(h):
        for x in range(w):
            if px[x, y][3] > 10 and not is_white(px[x, y]):
                xs.append(x)
                ys.append(y)
    cx = (min(xs) + max(xs)) / 2.0
    cy = (min(ys) + max(ys)) / 2.0
    rad = max(max(xs) - min(xs), max(ys) - min(ys)) / 2.0

    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    op = out.load()
    r2 = (rad * 1.005) ** 2
    for y in range(h):
        for x in range(w):
            if (x - cx) ** 2 + (y - cy) ** 2 > r2:
                continue
            op[x, y] = px[x, y]
    out.save(os.path.join(RES, "base", "media", "startIcon.png"))
    print("light -> base/media/startIcon.png")


def build_dark(src_path):
    im = Image.open(src_path).convert("RGBA")
    w, h = im.size
    px = im.load()
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    op = out.load()
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            m = max(r, g, b)
            if m <= 12:
                continue                      # 纯黑背景
            alpha = 255 if m >= 36 else int((m - 12) / 24.0 * 255)
            op[x, y] = (r, g, b, alpha)

    out = out.crop(out.getbbox())
    cw, ch = out.size
    side = max(cw, ch)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.alpha_composite(out, ((side - cw) // 2, (side - ch) // 2))
    final = square.resize((512, 512), Image.LANCZOS)

    dark_dir = os.path.join(RES, "dark", "media")
    os.makedirs(dark_dir, exist_ok=True)
    final.save(os.path.join(dark_dir, "startIcon.png"))
    print("dark  -> dark/media/startIcon.png")


if __name__ == "__main__":
    build_light()
    if len(sys.argv) > 1:
        build_dark(sys.argv[1])
