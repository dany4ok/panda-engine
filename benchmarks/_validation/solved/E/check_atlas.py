#!/usr/bin/env python3
"""Deterministic atlas integrity check. Usage: python check_atlas.py [atlas.png]."""
import json
import pathlib
import sys
from PIL import Image

p = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "assets/atlas.png")
res = {"file": str(p), "checks": {}, "ok": False}
try:
    im = Image.open(p).convert("RGBA")
    res["checks"]["size_64x16"] = im.size == (64, 16)
    frames = [im.crop((i * 16, 0, i * 16 + 16, 16)) for i in range(4)]
    res["checks"]["four_frames"] = len(frames) == 4
    boxes = [f.getbbox() for f in frames]
    res["checks"]["no_empty_frame"] = all(b is not None for b in boxes)
    px = [list(f.getdata()) for f in frames]
    res["checks"]["distinct_idle_run"] = px[0] != px[1]
    res["checks"]["distinct_idle_hurt"] = px[0] != px[3]
    res["checks"]["run_frames_differ"] = px[1] != px[2]
    res["ok"] = all(res["checks"].values())
except Exception as ex:
    res["error"] = str(ex)
print(json.dumps(res, indent=2))
sys.exit(0 if res["ok"] else 1)
