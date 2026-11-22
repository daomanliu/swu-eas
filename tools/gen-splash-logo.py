
import os
from PIL import Image

root = r"D:\DeepSeek\eas"
src = os.path.join(root, "entry", "src", "main", "resources", "base", "media", "foreground.png")
im = Image.open(src).convert("RGBA").resize((512, 512), Image.LANCZOS)
w, h = im.size
px = im.load()

def is_white(p):
    r, g, b, a = p
    return a > 10 and r > 235 and g > 235 and b > 235

def is_ink(p):
    r, g, b, a = p
    return a > 10 and not is_white(p)

xs, ys = [], []
for y in range(h):
    for x in range(w):
        if is_ink(px[x, y]):
            xs.append(x); ys.append(y)
cx = (min(xs) + max(xs)) / 2.0
cy = (min(ys) + max(ys)) / 2.0
rad = max(max(xs) - min(xs), max(ys) - min(ys)) / 2.0

def build(paper, ink):
    """paper=None 表示保留原白底；否则用指定纸色，ink 为蓝色重映射"""
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    op = out.load()
    r2 = (rad * 1.005) ** 2
    for y in range(h):
        for x in range(w):
            dx = x - cx; dy = y - cy
            if dx * dx + dy * dy > r2:
                continue
            p = px[x, y]
            r, g, b, a = p
            if b > 90 and r < 120:
                c = ink if ink else (r, g, b)
                op[x, y] = (c[0], c[1], c[2], a)
            else:
                if paper is None:
                    op[x, y] = (r, g, b, a)
                else:
                    op[x, y] = (paper[0], paper[1], paper[2], a)
    return out

light = build(None, None)                       # 浅色：原样圆形徽标
dark = build((226, 234, 246), (34, 84, 150))    # 深色：柔白圆底 + 略亮的蓝

base_dir = os.path.join(root, "entry", "src", "main", "resources", "base", "media")
dark_dir = os.path.join(root, "entry", "src", "main", "resources", "dark", "media")
os.makedirs(dark_dir, exist_ok=True)
light.save(os.path.join(base_dir, "startIcon.png"))
dark.save(os.path.join(dark_dir, "startIcon.png"))

shots = os.path.join(root, "screenshot")
for img, bg, name in [(light, (255,255,255,255), "p_light_big.png"), (dark, (15,17,20,255), "p_dark_big.png")]:
    c = Image.new("RGBA", (w, h), bg)
    c.alpha_composite(img)
    c.resize((360, 360), Image.LANCZOS).save(os.path.join(shots, name))
print("done r=", round(rad))