"""Synthetic test images for the EmbeddingGemma 2 vision reference (#836).

Twelve small, flat drawings made with Pillow: no photographs, nobody's likeness, nothing
that is not ours to commit. Deterministic (no randomness), so re-running reproduces the
same pixels on the same Pillow. Run:

    uv run --with pillow python -I make_embeddinggemma2_images.py \\
        macos/Tests/M1K3MLXTests/Fixtures/eg2-images

`IMAGES` is the single list the reference generator reads too (id, file name, size, the caption
a Photo memory would hold, and a search query that should find the picture by what is in it).
The sizes are deliberately not multiples of 48 (the vision tower's cell: 16 px patches pooled
3x3), so every image goes through the processor's aspect-preserving resize.

Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.75. Prior: none (new file).
"""

import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

# (id, file, size, caption, query). The caption is what Lil would write under the photo; the
# query is how a person would ask for it. Neither is a copy of the other's words on purpose.
IMAGES = [
    ("whiteboard", "whiteboard.png", (640, 480),
     "A whiteboard with the pricing tiers written in marker: Free 0 euro, Pro 8 euro a month, Team 20 euro per seat.",
     "the whiteboard photo about pricing"),
    ("barchart", "barchart.png", (600, 450),
     "A bar chart of monthly revenue with four bars, the tallest on the right.",
     "chart showing revenue growing month by month"),
    ("sunset", "sunset.png", (640, 400),
     "A sunset over the sea, the sun low and orange above dark water and a strip of sand.",
     "sunset at the beach"),
    ("tree", "tree.png", (480, 640),
     "A green tree with a brown trunk on a lawn under a blue sky.",
     "a tree in a field"),
    ("house", "house.png", (560, 420),
     "A small house with a red roof, a door and two windows under a yellow sun.",
     "picture of a house with a red roof"),
    ("night", "night.png", (520, 390),
     "A night sky with a crescent moon and many stars over dark blue.",
     "the moon and stars at night"),
    ("apple", "apple.png", (400, 400),
     "A single red apple with a short stem and a green leaf on a white table.",
     "a red apple"),
    ("stopsign", "stopsign.png", (360, 480),
     "A red octagonal STOP sign on a grey pole beside the road.",
     "road sign telling drivers to stop"),
    ("clock", "clock.png", (450, 450),
     "A round wall clock with twelve numbers showing three o'clock.",
     "what time does the wall clock show"),
    ("piechart", "piechart.png", (520, 400),
     "A pie chart split into four coloured slices, the largest in blue.",
     "pie chart with slices"),
    ("mountain", "mountain.png", (700, 500),
     "Snow-capped mountain peaks against a clear blue sky with green foothills.",
     "snowy mountains"),
    ("cat", "cat.png", (320, 240),
     "A cartoon cat face: orange fur, pointed ears, green eyes and long whiskers.",
     "a drawing of a cat"),
]


def font(size: int):
    return ImageFont.load_default(size=size)


def whiteboard(d, w, h):
    d.rectangle([0, 0, w, h], fill=(214, 217, 222))
    d.rectangle([30, 30, w - 30, h - 30], fill=(250, 250, 248), outline=(120, 124, 130), width=8)
    d.text((70, 55), "PRICING", fill=(20, 40, 150), font=font(54))
    rows = [("Free", "EUR 0"), ("Pro", "EUR 8 / month"), ("Team", "EUR 20 / seat")]
    for i, (a, b) in enumerate(rows):
        y = 150 + i * 80
        d.text((80, y), a, fill=(30, 30, 30), font=font(40))
        d.text((250, y), b, fill=(180, 30, 30), font=font(40))
        d.line([80, y + 52, w - 80, y + 52], fill=(120, 150, 220), width=3)


def barchart(d, w, h):
    d.rectangle([0, 0, w, h], fill=(255, 255, 255))
    d.text((150, 20), "Monthly revenue", fill=(20, 20, 20), font=font(34))
    d.line([70, 80, 70, h - 60, w - 40, h - 60], fill=(0, 0, 0), width=4)
    for i, (height, color) in enumerate([(80, (66, 133, 244)), (150, (52, 168, 83)),
                                         (210, (251, 188, 5)), (290, (234, 67, 53))]):
        x = 110 + i * 120
        d.rectangle([x, h - 60 - height, x + 80, h - 60], fill=color)


def sunset(d, w, h):
    horizon = int(h * 0.6)
    for y in range(horizon):
        t = y / horizon
        d.line([0, y, w, y], fill=(int(40 + 215 * t), int(30 + 110 * t), int(90 - 40 * t)))
    d.ellipse([w // 2 - 60, horizon - 70, w // 2 + 60, horizon + 50], fill=(255, 190, 60))
    d.rectangle([0, horizon, w, int(h * 0.88)], fill=(20, 50, 90))
    d.rectangle([0, int(h * 0.88), w, h], fill=(214, 190, 140))


def tree(d, w, h):
    d.rectangle([0, 0, w, int(h * 0.72)], fill=(135, 190, 235))
    d.rectangle([0, int(h * 0.72), w, h], fill=(80, 160, 70))
    d.rectangle([w // 2 - 25, int(h * 0.4), w // 2 + 25, int(h * 0.8)], fill=(110, 72, 40))
    for cx, cy, r in [(w // 2, int(h * 0.28), 110), (w // 2 - 80, int(h * 0.38), 80), (w // 2 + 80, int(h * 0.38), 80)]:
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(40, 130, 50))


def house(d, w, h):
    d.rectangle([0, 0, w, int(h * 0.8)], fill=(150, 205, 245))
    d.rectangle([0, int(h * 0.8), w, h], fill=(90, 170, 80))
    d.ellipse([w - 120, 30, w - 50, 100], fill=(255, 220, 60))
    d.rectangle([130, 190, 430, 340], fill=(240, 225, 190))
    d.polygon([(110, 190), (280, 80), (450, 190)], fill=(190, 40, 40))
    d.rectangle([255, 250, 305, 340], fill=(110, 70, 40))
    for x in (160, 340):
        d.rectangle([x, 220, x + 55, 275], fill=(120, 180, 230), outline=(90, 90, 90), width=3)


def night(d, w, h):
    d.rectangle([0, 0, w, h], fill=(8, 12, 44))
    d.ellipse([340, 50, 440, 150], fill=(250, 245, 210))
    d.ellipse([365, 40, 465, 140], fill=(8, 12, 44))
    for i in range(40):
        x = (i * 97 + 31) % (w - 20) + 10
        y = (i * 53 + 17) % (h - 20) + 10
        r = 2 + (i % 3)
        d.ellipse([x - r, y - r, x + r, y + r], fill=(255, 255, 235))


def apple(d, w, h):
    d.rectangle([0, 0, w, h], fill=(245, 245, 245))
    d.rectangle([0, int(h * 0.75), w, h], fill=(190, 150, 100))
    d.ellipse([90, 110, 310, 330], fill=(200, 25, 30))
    d.line([200, 130, 215, 70], fill=(90, 60, 30), width=10)
    d.ellipse([215, 60, 290, 110], fill=(60, 150, 50))


def stopsign(d, w, h):
    d.rectangle([0, 0, w, h], fill=(160, 200, 235))
    d.rectangle([0, int(h * 0.85), w, h], fill=(70, 70, 75))
    d.rectangle([w // 2 - 12, 230, w // 2 + 12, int(h * 0.88)], fill=(120, 120, 125))
    cx, cy, r = w // 2, 140, 110
    pts = [(cx + r * math.cos(math.radians(22.5 + 45 * i)), cy + r * math.sin(math.radians(22.5 + 45 * i)))
           for i in range(8)]
    d.polygon(pts, fill=(200, 20, 30), outline=(255, 255, 255))
    d.text((cx - 75, cy - 32), "STOP", fill=(255, 255, 255), font=font(68))


def clock(d, w, h):
    d.rectangle([0, 0, w, h], fill=(235, 230, 220))
    c = w // 2
    d.ellipse([c - 190, c - 190, c + 190, c + 190], fill=(255, 255, 255), outline=(30, 30, 30), width=8)
    for n in range(1, 13):
        a = math.radians(n * 30 - 90)
        d.text((c + 150 * math.cos(a) - 12, c + 150 * math.sin(a) - 16), str(n), fill=(20, 20, 20), font=font(32))
    d.line([c, c, c + 110, c], fill=(20, 20, 20), width=10)
    d.line([c, c, c, c - 150], fill=(20, 20, 20), width=6)


def piechart(d, w, h):
    d.rectangle([0, 0, w, h], fill=(255, 255, 255))
    box = [110, 40, 410, 340]
    start = -90.0
    for share, color in [(0.45, (66, 133, 244)), (0.25, (234, 67, 53)), (0.18, (251, 188, 5)), (0.12, (52, 168, 83))]:
        d.pieslice(box, start, start + 360 * share, fill=color, outline=(255, 255, 255), width=3)
        start += 360 * share


def mountain(d, w, h):
    d.rectangle([0, 0, w, h], fill=(120, 185, 240))
    d.rectangle([0, int(h * 0.78), w, h], fill=(70, 140, 70))
    for x0, x1, peak, color in [(40, 400, 110, (110, 110, 120)), (300, 680, 160, (95, 95, 108))]:
        mid = (x0 + x1) // 2
        d.polygon([(x0, int(h * 0.8)), (mid, peak), (x1, int(h * 0.8))], fill=color)
        d.polygon([(mid - 55, peak + 85), (mid, peak), (mid + 55, peak + 85), (mid + 20, peak + 70),
                   (mid, peak + 95), (mid - 20, peak + 70)], fill=(250, 250, 255))


def cat(d, w, h):
    d.rectangle([0, 0, w, h], fill=(200, 225, 200))
    d.polygon([(70, 110), (95, 20), (150, 80)], fill=(232, 140, 50))
    d.polygon([(250, 110), (225, 20), (170, 80)], fill=(232, 140, 50))
    d.ellipse([60, 60, 260, 220], fill=(240, 150, 55))
    for x in (115, 205):
        d.ellipse([x - 18, 110, x + 18, 140], fill=(60, 170, 80))
        d.ellipse([x - 5, 113, x + 5, 137], fill=(10, 10, 10))
    d.polygon([(160, 150), (148, 166), (172, 166)], fill=(230, 100, 120))
    for dy in (-8, 8):
        d.line([60, 160 + dy, 10, 160 + dy * 2], fill=(40, 40, 40), width=2)
        d.line([260, 160 + dy, 310, 160 + dy * 2], fill=(40, 40, 40), width=2)


DRAW = {
    "whiteboard": whiteboard, "barchart": barchart, "sunset": sunset, "tree": tree, "house": house,
    "night": night, "apple": apple, "stopsign": stopsign, "clock": clock, "piechart": piechart,
    "mountain": mountain, "cat": cat,
}


def main(out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    for image_id, name, (w, h), _caption, _query in IMAGES:
        image = Image.new("RGB", (w, h), (255, 255, 255))
        DRAW[image_id](ImageDraw.Draw(image), w, h)
        image.save(out / name, optimize=True)
        print(name, (w, h), (out / name).stat().st_size, "bytes")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
