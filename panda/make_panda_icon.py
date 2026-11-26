"""Build the Panda Engine application icon (panda.ico).

Draws at 4x resolution and downsamples so the small ICO sizes stay clean.
Run: python panda/make_panda_icon.py
"""

import os
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(HERE), "panda.ico")
SCALE = 4
BASE = 256
SIZE = BASE * SCALE


def box(values):
    return [int(v * SCALE) for v in values]


def make():
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    dark = (24, 32, 52, 255)
    black = (17, 24, 39, 255)
    white = (255, 255, 255, 255)

    d.rounded_rectangle(box((8, 8, 248, 248)), radius=48 * SCALE, fill=dark)

    d.ellipse(box((46, 26, 98, 82)), fill=black)
    d.ellipse(box((158, 26, 210, 82)), fill=black)
    d.ellipse(box((38, 52, 218, 226)), fill=white)

    d.ellipse(box((68, 104, 114, 152)), fill=black)
    d.ellipse(box((142, 104, 188, 152)), fill=black)

    d.ellipse(box((82, 117, 100, 138)), fill=white)
    d.ellipse(box((156, 117, 174, 138)), fill=white)
    d.ellipse(box((89, 123, 98, 134)), fill=black)
    d.ellipse(box((163, 123, 172, 134)), fill=black)

    d.ellipse(box((118, 158, 138, 174)), fill=black)
    d.arc(box((110, 168, 146, 196)), 20, 160, fill=black, width=4 * SCALE)

    img = img.resize((BASE, BASE), Image.Resampling.LANCZOS)
    img.save(
        OUT,
        format="ICO",
        sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )
    png = os.path.join(os.path.dirname(HERE), "panda.png")
    img.save(png, format="PNG")
    print("wrote", OUT, os.path.getsize(OUT), "bytes")
    print("wrote", png, os.path.getsize(png), "bytes")


if __name__ == "__main__":
    make()
