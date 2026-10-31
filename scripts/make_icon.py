"""Generates the Slate app icon (1024x1024, opaque PNG)."""
import sys
from PIL import Image, ImageDraw

SIZE = 1024
SS = 4  # supersampling for smooth edges

def main(out_path):
    big = SIZE * SS
    img = Image.new("RGB", (big, big), (18, 18, 20))
    d = ImageDraw.Draw(img)
    # subtle dot grid
    step = 64 * SS
    r = 5 * SS
    for y in range(step // 2, big, step):
        for x in range(step // 2, big, step):
            d.ellipse([x - r, y - r, x + r, y + r], fill=(48, 48, 54))
    # sticky note
    d.rounded_rectangle([590 * SS, 170 * SS, 850 * SS, 430 * SS], radius=24 * SS, fill=(255, 224, 102))
    # rounded rectangle outline
    d.rounded_rectangle([170 * SS, 560 * SS, 520 * SS, 840 * SS], radius=48 * SS, outline=(10, 132, 255), width=26 * SS)
    # scribble
    pts = []
    import math
    for i in range(0, 2401):
        t = i / 2400
        x = 170 + 640 * t
        y = 470 - 150 * math.sin(t * math.pi * 2.2) * (1 - 0.3 * t)
        pts.append((x * SS, y * SS))
    for p in pts:
        d.ellipse([p[0] - 17 * SS, p[1] - 17 * SS, p[0] + 17 * SS, p[1] + 17 * SS], fill=(242, 242, 247))
    img = img.resize((SIZE, SIZE), Image.LANCZOS)
    img.save(out_path, "PNG")

if __name__ == "__main__":
    main(sys.argv[1])
