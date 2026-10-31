"""Generates the Cutline app icon (1024x1024 opaque PNG)."""
import sys
from PIL import Image, ImageDraw

S = 4
N = 1024 * S

def main(path):
    img = Image.new("RGB", (N, N), (14, 14, 18))
    d = ImageDraw.Draw(img)
    # Timeline tracks
    tracks = [(300, (255, 82, 92), [(120, 520), (560, 900)]),
              (470, (110, 90, 255), [(200, 700)]),
              (640, (40, 200, 140), [(120, 380), (420, 800)])]
    for y, color, segments in tracks:
        for x0, x1 in segments:
            d.rounded_rectangle([x0 * S, y * S, x1 * S, (y + 110) * S], radius=26 * S, fill=color)
    # Playhead
    d.rounded_rectangle([500 * S, 200 * S, 524 * S, 830 * S], radius=12 * S, fill=(255, 255, 255))
    d.polygon([(462 * S, 170 * S), (562 * S, 170 * S), (512 * S, 232 * S)], fill=(255, 255, 255))
    img.resize((1024, 1024), Image.LANCZOS).save(path, "PNG")

if __name__ == "__main__":
    main(sys.argv[1])
