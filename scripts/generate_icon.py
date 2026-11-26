#!/usr/bin/env python3
"""Generates the Imagine app icon (1024x1024, opaque)."""
import math, os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Imagine", "Assets.xcassets", "AppIcon.appiconset", "AppIcon-1024.png")
S = 1024
img = Image.new("RGB", (S, S))
px = img.load()
a, b = (17, 24, 39), (124, 58, 237)
for y in range(S):
    for x in range(S):
        t = (x * 0.4 + y * 0.6) / S
        px[x, y] = tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
g = ImageDraw.Draw(glow)
g.ellipse([S*0.2, S*0.2, S*0.8, S*0.8], fill=(236, 72, 153, 120))
glow = glow.filter(ImageFilter.GaussianBlur(90))
img.paste(glow, (0, 0), glow)
d = ImageDraw.Draw(img)
# picture frame
d.rounded_rectangle([S*0.22, S*0.28, S*0.78, S*0.76], radius=S*0.06, outline=(255, 255, 255), width=int(S*0.035))
# mountains
d.polygon([(S*0.27, S*0.70), (S*0.43, S*0.48), (S*0.55, S*0.62), (S*0.62, S*0.54), (S*0.73, S*0.70)], fill=(255, 255, 255))
d.ellipse([S*0.58, S*0.35, S*0.68, S*0.45], fill=(253, 224, 71))
def sparkle(x, y, r):
    pts = []
    for i in range(8):
        ang = math.pi / 4 * i - math.pi / 2
        rr = r if i % 2 == 0 else r * 0.28
        pts.append((x + rr*math.cos(ang), y + rr*math.sin(ang)))
    d.polygon(pts, fill=(255, 255, 255))
sparkle(S*0.78, S*0.24, S*0.09)
sparkle(S*0.66, S*0.17, S*0.04)
img.save(OUT)
print("wrote", OUT)
