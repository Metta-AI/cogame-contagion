#!/usr/bin/env python3
"""Author Contagion's painted props in the Ink & Print palette.

Everything the map scene draws that is not a governor portrait is generated
here and committed as PNG: the parchment map plate the six regions sit on, the
painted region tile, the wooden shutter slat, the barrier arm and the gold aid
packet. Nothing in the viewer is a solid-colour rectangle standing in for art,
and nothing here is a one-off run on somebody's laptop — this script is the
recipe.

    python3 scripts/art/make_props.py data

Palette (shared with client/chrome.css): paper #f2e8d8, ink #2a1f16,
amber #e8a33d.
"""

from __future__ import annotations

import math
import os
import random
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

PAPER = (242, 232, 216)
PAPER_DEEP = (222, 206, 180)
INK = (42, 31, 22)
AMBER = (232, 163, 61)
WOOD = (138, 97, 54)
WOOD_DARK = (93, 63, 34)
GOLD = (232, 193, 90)
PLAGUE = (196, 55, 42)

FONT_PATH = os.path.join(os.path.dirname(__file__), "..", "..", "data",
                         "font.ttf")


def font(size: int):
    try:
        return ImageFont.truetype(FONT_PATH, size)
    except OSError:
        return ImageFont.load_default()


def parchment(width: int, height: int, seed: int) -> Image.Image:
    """A painted parchment field: fibre noise, warm blotches, aged edges."""
    rng = np.random.default_rng(seed)
    base = np.zeros((height, width, 3), dtype=np.float32)
    base[:, :] = PAPER

    # Long fibres: low-frequency noise smeared horizontally, then a fine grain.
    coarse = rng.normal(0.0, 1.0, (height // 8 + 2, width // 8 + 2))
    coarse = np.array(
        Image.fromarray(((coarse - coarse.min()) /
                         (np.ptp(coarse) + 1e-6) * 255).astype(np.uint8))
        .resize((width, height), Image.BICUBIC), dtype=np.float32) / 255.0
    grain = rng.normal(0.0, 1.0, (height, width))

    shade = (coarse - 0.5) * 22.0 + grain * 4.0
    for channel, weight in enumerate((1.0, 0.94, 0.82)):
        base[:, :, channel] += shade * weight

    # Warm blotches, as if the sheet had been damp once.
    blotch = Image.new("L", (width, height), 0)
    pen = ImageDraw.Draw(blotch)
    local = random.Random(seed)
    for _ in range(max(8, width // 90)):
        cx = local.uniform(0, width)
        cy = local.uniform(0, height)
        rx = local.uniform(width * 0.04, width * 0.18)
        ry = rx * local.uniform(0.5, 1.4)
        pen.ellipse([cx - rx, cy - ry, cx + rx, cy + ry],
                    fill=local.randint(30, 80))
    blotch = blotch.filter(ImageFilter.GaussianBlur(width / 34.0))
    mask = np.array(blotch, dtype=np.float32) / 255.0
    for channel, target in enumerate(PAPER_DEEP):
        base[:, :, channel] = (base[:, :, channel] * (1 - mask * 0.55) +
                               target * mask * 0.55)

    # Aged edges: the sheet is darker where it has been handled.
    ys, xs = np.mgrid[0:height, 0:width]
    edge = np.maximum.reduce([
        1.0 - xs / (width * 0.22),
        1.0 - ys / (height * 0.22),
        1.0 - (width - 1 - xs) / (width * 0.22),
        1.0 - (height - 1 - ys) / (height * 0.22),
    ])
    edge = np.clip(edge, 0.0, 1.0) ** 1.7
    for channel, target in enumerate((196, 174, 140)):
        base[:, :, channel] = (base[:, :, channel] * (1 - edge * 0.5) +
                               target * edge * 0.5)

    return Image.fromarray(np.clip(base, 0, 255).astype(np.uint8), "RGB")


def wobbly_ring(pen, cx, cy, rx, ry, rng, jitter, colour, width=1):
    """A closed hand-drawn ring: a few low-frequency harmonics, not per-point
    noise, so it reads as an inked contour rather than a saw blade."""
    harmonics = [(rng.randint(2, 6), rng.uniform(0, math.tau),
                  rng.uniform(0.35, 1.0)) for _ in range(3)]
    total = sum(h[2] for h in harmonics)
    points = []
    for step in range(145):
        angle = step / 144 * math.tau
        wobble = 1.0 + jitter * sum(
            amp * math.sin(freq * angle + phase) for freq, phase, amp
            in harmonics) / total
        points.append((cx + math.cos(angle) * rx * wobble,
                       cy + math.sin(angle) * ry * wobble))
    pen.line(points, fill=colour, width=width, joint="curve")


def make_map_board(path: str) -> None:
    width, height = 1600, 1000
    image = parchment(width, height, seed=91237).convert("RGBA")
    pen = ImageDraw.Draw(image, "RGBA")
    rng = random.Random(5)

    # Terrain: contour rings around each of the six region seats, so the plate
    # has geography under the hexagon the renderer lays on top of it.
    cx, cy = width / 2, height / 2
    rx, ry = width * 0.33, height * 0.33
    for pos in range(6):
        angle = -math.pi / 2 + pos * math.pi / 3
        px = cx + rx * math.cos(angle)
        py = cy + ry * math.sin(angle)
        for ring in range(5):
            radius = 42 + ring * 34
            wobbly_ring(pen, px, py, radius, radius * 0.82, rng, 0.09,
                        (42, 31, 22, 26 - ring * 3), 2)

    # A coastline running around the whole territory.
    wobbly_ring(pen, cx, cy, width * 0.455, height * 0.44, rng, 0.035,
                (42, 31, 22, 70), 4)
    wobbly_ring(pen, cx, cy, width * 0.475, height * 0.46, rng, 0.045,
                (42, 31, 22, 34), 2)

    # Hatched sea outside the coastline.
    sea = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    seapen = ImageDraw.Draw(sea)
    for y in range(0, height, 14):
        seapen.line([(0, y), (width, y)], fill=(63, 124, 196, 26), width=2)
    coast = Image.new("L", (width, height), 255)
    coastpen = ImageDraw.Draw(coast)
    coastpen.ellipse([cx - width * 0.455, cy - height * 0.44,
                      cx + width * 0.455, cy + height * 0.44], fill=0)
    coast = coast.filter(ImageFilter.GaussianBlur(9))
    image.alpha_composite(Image.composite(
        sea, Image.new("RGBA", (width, height), (0, 0, 0, 0)), coast))

    # Frame rules.
    pen.rectangle([16, 16, width - 17, height - 17], outline=(42, 31, 22, 120),
                  width=3)
    pen.rectangle([26, 26, width - 27, height - 27], outline=(42, 31, 22, 60),
                  width=1)

    # Compass rose, bottom right.
    rose_x, rose_y, rose_r = width - 118, height - 118, 52
    for spoke in range(8):
        angle = spoke * math.pi / 4
        length = rose_r if spoke % 2 == 0 else rose_r * 0.55
        pen.polygon([
            (rose_x + math.cos(angle) * length,
             rose_y + math.sin(angle) * length),
            (rose_x + math.cos(angle + 0.30) * length * 0.18,
             rose_y + math.sin(angle + 0.30) * length * 0.18),
            (rose_x + math.cos(angle - 0.30) * length * 0.18,
             rose_y + math.sin(angle - 0.30) * length * 0.18),
        ], fill=(42, 31, 22, 150) if spoke % 2 == 0 else (42, 31, 22, 80))
    pen.ellipse([rose_x - 9, rose_y - 9, rose_x + 9, rose_y + 9],
                outline=(42, 31, 22, 170), width=3)
    pen.text((rose_x - 6, rose_y - rose_r - 30), "N", font=font(30),
             fill=(42, 31, 22, 190))

    # Cartouche, top left.
    title = font(44)
    pen.text((54, 44), "CONTAGION", font=title, fill=(42, 31, 22, 205))
    pen.text((56, 96), "six regions · nine roads · one virus",
             font=font(24), fill=(42, 31, 22, 130))
    pen.line([(54, 92), (430, 92)], fill=(232, 163, 61, 170), width=3)

    # Scale bar, bottom left.
    bar_y = height - 62
    for step in range(6):
        x0 = 54 + step * 34
        pen.rectangle([x0, bar_y, x0 + 34, bar_y + 11],
                      fill=(42, 31, 22, 150) if step % 2 == 0 else
                      (42, 31, 22, 40), outline=(42, 31, 22, 150))
    pen.text((54, bar_y + 16), "100 miles", font=font(20),
             fill=(42, 31, 22, 130))

    # Vignette so the plate sinks into the stage.
    ys, xs = np.mgrid[0:height, 0:width]
    radial = np.sqrt(((xs - cx) / (width / 2)) ** 2 +
                     ((ys - cy) / (height / 2)) ** 2)
    dark = np.clip((radial - 0.66) / 0.80, 0, 1) ** 1.5 * 110
    shade = Image.fromarray(
        np.dstack([np.full((height, width), 18, np.uint8),
                   np.full((height, width), 13, np.uint8),
                   np.full((height, width), 9, np.uint8),
                   dark.astype(np.uint8)]), "RGBA")
    image.alpha_composite(shade)
    image.convert("RGB").save(path)


def make_region_tile(path: str) -> None:
    width, height = 320, 252
    plate = parchment(width, height, seed=4242).convert("RGBA")
    pen = ImageDraw.Draw(plate, "RGBA")
    # A torn, hand-inked border.
    rng = random.Random(11)
    points = []
    inset = 9
    for step in range(120):
        t = step / 120
        if t < 0.25:
            x, y = inset + (width - 2 * inset) * (t / 0.25), inset
        elif t < 0.5:
            x, y = width - inset, inset + (height - 2 * inset) * ((t - .25) / .25)
        elif t < 0.75:
            x, y = width - inset - (width - 2 * inset) * ((t - .5) / .25), height - inset
        else:
            x, y = inset, height - inset - (height - 2 * inset) * ((t - .75) / .25)
        points.append((x + rng.uniform(-2.2, 2.2), y + rng.uniform(-2.2, 2.2)))
    points.append(points[0])
    pen.line(points, fill=(42, 31, 22, 205), width=4, joint="curve")
    pen.line(points, fill=(42, 31, 22, 70), width=9, joint="curve")
    # Corner nails.
    for nx, ny in ((20, 20), (width - 20, 20), (20, height - 20),
                   (width - 20, height - 20)):
        pen.ellipse([nx - 5, ny - 5, nx + 5, ny + 5], fill=(93, 63, 34, 220),
                    outline=(42, 31, 22, 220))
        pen.ellipse([nx - 2, ny - 3, nx + 1, ny], fill=(242, 232, 216, 150))

    # Round the outside off so the tile does not read as a rectangle.
    mask = Image.new("L", (width, height), 0)
    ImageDraw.Draw(mask).rounded_rectangle([2, 2, width - 3, height - 3],
                                           radius=14, fill=255)
    plate.putalpha(mask)
    plate.save(path)


def make_shutter(path: str) -> None:
    width, height = 320, 72
    image = Image.new("RGBA", (width, height), WOOD + (255,))
    pen = ImageDraw.Draw(image, "RGBA")
    rng = random.Random(7)
    # Grain.
    for _ in range(150):
        y = rng.uniform(4, height - 4)
        x0 = rng.uniform(0, width * 0.7)
        length = rng.uniform(width * 0.15, width * 0.5)
        shade = rng.randint(-26, 18)
        colour = tuple(max(0, min(255, c + shade)) for c in WOOD)
        pen.line([(x0, y), (x0 + length, y + rng.uniform(-1.5, 1.5))],
                 fill=colour + (190,), width=rng.choice([1, 1, 2]))
    # Bevels.
    pen.rectangle([0, 0, width - 1, 3], fill=(214, 178, 126, 190))
    pen.rectangle([0, height - 5, width - 1, height - 1],
                  fill=WOOD_DARK + (230,))
    pen.rectangle([0, 0, width - 1, height - 1], outline=(42, 31, 22, 200),
                  width=2)
    # Bolts.
    for bx in (18, width // 2, width - 18):
        pen.ellipse([bx - 5, height / 2 - 5, bx + 5, height / 2 + 5],
                    fill=(70, 58, 46, 255), outline=(30, 22, 16, 255))
        pen.ellipse([bx - 2, height / 2 - 3, bx + 1, height / 2],
                    fill=(200, 190, 170, 180))
    image.save(path)


def make_gate_arm(path: str) -> None:
    width, height = 200, 36
    image = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    pen = ImageDraw.Draw(image, "RGBA")
    pen.rounded_rectangle([0, 8, width - 1, height - 9], radius=8,
                          fill=(242, 232, 216, 255),
                          outline=(42, 31, 22, 255), width=3)
    stripe = 26
    x = 6
    flip = False
    while x < width - 6:
        if flip:
            pen.polygon([(x, 11), (min(x + stripe, width - 7), 11),
                         (min(x + stripe - 8, width - 7), height - 12),
                         (max(x - 8, 6), height - 12)],
                        fill=PLAGUE + (255,))
        x += stripe
        flip = not flip
    pen.rounded_rectangle([0, 8, width - 1, height - 9], radius=8,
                          outline=(42, 31, 22, 255), width=3)
    # Counterweight at the hinge.
    pen.ellipse([1, 4, 27, height - 5], fill=(70, 58, 46, 255),
                outline=(42, 31, 22, 255), width=3)
    image.save(path)


def make_aid_packet(path: str) -> None:
    size = 128
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    pen = ImageDraw.Draw(image, "RGBA")
    # A tied purse.
    pen.polygon([(30, 44), (98, 44), (110, 96), (64, 120), (18, 96)],
                fill=GOLD + (255,), outline=(42, 31, 22, 255))
    pen.line([(30, 44), (98, 44), (110, 96), (64, 120), (18, 96), (30, 44)],
             fill=(42, 31, 22, 255), width=4, joint="curve")
    # Highlight and shade.
    pen.polygon([(36, 50), (64, 50), (64, 112), (26, 92)],
                fill=(248, 220, 140, 120))
    pen.polygon([(64, 50), (94, 50), (104, 92), (64, 112)],
                fill=(178, 138, 46, 120))
    # Neck and tie.
    pen.rectangle([44, 24, 84, 48], fill=(214, 174, 74, 255),
                  outline=(42, 31, 22, 255), width=3)
    pen.line([(40, 40), (88, 40)], fill=(42, 31, 22, 255), width=6)
    # Wax seal.
    pen.ellipse([52, 66, 88, 102], fill=PLAGUE + (235,),
                outline=(42, 31, 22, 255), width=3)
    pen.ellipse([61, 75, 79, 93], outline=(242, 232, 216, 200), width=3)
    image.save(path)


def main(out_dir: str) -> None:
    make_map_board(os.path.join(out_dir, "map_board.png"))
    make_region_tile(os.path.join(out_dir, "region_tile.png"))
    make_shutter(os.path.join(out_dir, "shutter.png"))
    make_gate_arm(os.path.join(out_dir, "gate_arm.png"))
    make_aid_packet(os.path.join(out_dir, "aid_packet.png"))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "data")
