#!/usr/bin/env python3
"""Recolour a coworld-ctf soldier sprite into a new seat colour.

Contagion needs six governor portraits and the starter ships four (red, blue,
green, yellow, MIT-licensed with the rest of the ctf art). Rather than draw two
placeholder rectangles, the violet and orange governors are produced from the
red sprite by rotating its hue and re-tinting only the coloured pixels: the ink
outlines and the paper highlights (which are near-grey) are left alone, so the
result sits in exactly the same Ink & Print palette as the other four.

    python3 scripts/art/recolor_sprite.py \
        data/governor_red_front.png data/governor_violet_front.png "#a86fd6"

Committed because the art it produces is committed: the recipe has to be
reproducible, not a one-off run on somebody's laptop.
"""

from __future__ import annotations

import colorsys
import sys

from PIL import Image


def hex_to_rgb(value: str) -> tuple[int, int, int]:
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))  # type: ignore


def recolor(src: str, dst: str, target_hex: str) -> None:
    target = hex_to_rgb(target_hex)
    th, ts, _tv = colorsys.rgb_to_hsv(*(c / 255 for c in target))
    image = Image.open(src).convert("RGBA")
    pixels = image.load()
    width, height = image.size
    for y in range(height):
        for x in range(width):
            r, g, b, a = pixels[x, y]
            if a == 0:
                continue
            h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            if s < 0.18:
                # Ink outline / paper highlight: part of the drawing, not the
                # uniform. Leave it exactly as the artist made it.
                continue
            nr, ng, nb = colorsys.hsv_to_rgb(th, min(1.0, s * (ts / max(s, 1e-6)) ** 0.0 * 1.0), v)
            pixels[x, y] = (int(nr * 255), int(ng * 255), int(nb * 255), a)
    image.save(dst)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    recolor(sys.argv[1], sys.argv[2], sys.argv[3])
