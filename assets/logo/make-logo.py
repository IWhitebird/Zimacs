"""Zimacs logo: risograph/screen-print look, built as pixel art.

Two ink layers (electric blue and warm yellow) deliberately misregistered,
halftone dot shading instead of gradients, hard blocky edges.
"""
from PIL import Image

GRID = 64          # logical pixels; everything is drawn on this grid
SCALE = 8          # each logical pixel becomes an 8x8 block -> 512px
BLACK = (14, 14, 18)
BLUE = (34, 108, 255)
CYAN = (120, 200, 255)
YELLOW = (255, 186, 32)
PAPER = (245, 240, 228)

def blank(colour):
    return [[colour for _ in range(GRID)] for _ in range(GRID)]

def in_z(x, y, ox=0, oy=0):
    """The Z glyph, as a set of logical pixels."""
    x -= ox
    y -= oy
    top, bottom = 16, 47
    left, right = 14, 49
    bar = 6
    if not (left <= x <= right):
        return False
    if top <= y < top + bar:                      # top bar
        return True
    if bottom - bar < y <= bottom:                # bottom bar
        return True
    # diagonal: walks from the right of the top bar to the left of the bottom
    span = bottom - bar - (top + bar)
    if top + bar <= y <= bottom - bar and span > 0:
        t = (y - (top + bar)) / span
        centre = right - t * (right - left)
        return abs(x - centre) <= bar * 0.62
    return False

def halftone(x, y, level):
    """A 4x4 ordered-dither cell: bigger dots where `level` is higher."""
    matrix = [
        [0, 8, 2, 10],
        [12, 4, 14, 6],
        [3, 11, 1, 9],
        [15, 7, 13, 5],
    ]
    return matrix[y % 4][x % 4] < level

px = blank(BLACK)

# Paper grain: sparse warm dots, so the black never reads as flat digital black.
for y in range(GRID):
    for x in range(GRID):
        if halftone(x, y, 1) and (x * 7 + y * 13) % 11 == 0:
            px[y][x] = (28, 26, 30)

# Yellow ink, offset down-right: the misregistration that makes it feel printed.
for y in range(GRID):
    for x in range(GRID):
        if in_z(x, y, ox=2, oy=2):
            px[y][x] = YELLOW

# Blue ink on top, with a halftone edge so the two inks interleave.
for y in range(GRID):
    for x in range(GRID):
        if in_z(x, y):
            px[y][x] = BLUE
        elif in_z(x, y, ox=1, oy=1) and halftone(x, y, 9):
            px[y][x] = BLUE

# Halftone shading inside the glyph: solid at the top, breaking into dots
# further down, so it reads as a printed gradient rather than a texture.
TOP, BOTTOM = 16, 47
for y in range(GRID):
    for x in range(GRID):
        if px[y][x] == BLUE:
            t = max(0.0, min(1.0, (y - TOP) / (BOTTOM - TOP)))
            if halftone(x, y, int(16 * t)):
                px[y][x] = CYAN

# Caret, in paper white, standing at the end of the bottom bar.
for y in range(34, 48):
    for x in range(52, 56):
        px[y][x] = PAPER
# Its yellow shadow, offset like the other ink.
for y in range(36, 50):
    for x in range(54, 58):
        if px[y][x] not in (PAPER, BLUE, CYAN):
            px[y][x] = YELLOW

image = Image.new("RGBA", (GRID, GRID))
image.putdata([tuple(px[y][x]) + (255,) for y in range(GRID) for x in range(GRID)])
image = image.resize((GRID * SCALE, GRID * SCALE), Image.NEAREST)

# Rounded square mask, so it sits well as an app icon.
mask = Image.new("L", image.size, 0)
from PIL import ImageDraw
ImageDraw.Draw(mask).rounded_rectangle([0, 0, image.size[0] - 1, image.size[1] - 1],
                                        radius=image.size[0] // 6, fill=255)
image.putalpha(mask)

image.resize((256, 256), Image.LANCZOS).save("assets/logo/zimacs-256.png")
image.resize((64, 64), Image.LANCZOS).save("assets/logo/zimacs-64.png")
image.save("assets/logo/zimacs-512.png")
print("written")
