"""Independent reality re-check for task A. Outside the workspace; asserts nothing silently."""
import hashlib
import pathlib
import random
import sys

WORK = pathlib.Path(r"C:\Users\x1p\AppData\Local\Temp\opencode\gyro-mini-bench\results\batch1\panda_gyro-gyro-s\A\work")
SEED = pathlib.Path(r"C:\Users\x1p\AppData\Local\Temp\opencode\gyro-mini-bench\tasks\A_simple\seed\string_utils.py")
sys.path.insert(0, str(WORK))
from string_utils import slugify, truncate

shipped_bytes = (WORK / "string_utils.py").read_bytes()
print("shipped size:", len(shipped_bytes), "sha256:", hashlib.sha256(shipped_bytes).hexdigest())
print("workspace files:", sorted(p.name for p in WORK.iterdir()))
print("import statements in shipped:", [ln for ln in shipped_bytes.decode("utf-8").splitlines() if "import" in ln])

# --- rule: existing functions untouched -------------------------------------
seed_src = SEED.read_text(encoding="utf-8")
ship_src = shipped_bytes.decode("utf-8")
seed_lines, ship_lines = seed_src.splitlines(), ship_src.splitlines()
print("truncate block byte-identical to pristine seed:",
      seed_lines[:8] == ship_lines[:8])
import inspect
print("truncate source:", repr(inspect.getsource(truncate)))

# --- bullet 1: every kept output char is lowercase --------------------------
def is_lower(c):
    return c.lower() == c

print("unlowerable alnum chars (any impl, incl. reference):",
      [chr(cp) for cp in range(0x110000) if chr(cp).isalnum() and chr(cp).isupper() and chr(cp).lower() == chr(cp)][:12])

# --- the per-char lowering design's two risk classes ------------------------
classA = [chr(cp) for cp in range(0x110000) if chr(cp).isalnum() and not [c for c in chr(cp).lower() if c.isalnum()]]
classB = [chr(cp) for cp in range(0x110000) if not chr(cp).isalnum() and [c for c in chr(cp).lower() if c.isalnum()]]
classC = [chr(cp) for cp in range(0x110000) if chr(cp).isalnum() and len(chr(cp).lower()) != 1]
print("A (alnum char whose lowering has no alnum -> spurious dash):", len(classA), classA[:8])
print("B (non-alnum char whose lowering IS alnum -> dash swallowed):", len(classB), classB[:8])
print("C (alnum char whose lowering expands):", len(classC), [(c, repr(c.lower())) for c in classC[:8]])
print("C behaviour in shipped:", [(c, slugify("x" + c + "y"), slugify(c)) for c in classC[:8]])

# --- spec-literal sequential reference (bullet1 then bullet2 then bullet3) --
def spec_literal(text):
    t = text.lower()
    out, dash = [], False
    for c in t:
        if c.isalnum():
            out.append(c)
            dash = False
        elif out and not dash:
            out.append("-")
            dash = True
    s = "".join(out)
    return s.strip("-")

ALPHABET = list("abcXYZ0129") + list("\u0106\u0102\u00ee\u0219\u0218\u00dc\u00e9") + list("\u65e5\u672c\u7d2d") + ["\u0130", "\u00df", "\u01c5", "\u00b2", "i\u0307", "\t", "\n", " ", "-", "_", "/", "\\", "!", "&", "+", "#", ".", "\u00a0", "\u200b", "\u0301", ""]
random.seed(1234)
inputs = ["".join(random.choice(ALPHABET) for _ in range(random.randint(0, 12))) for _ in range(20000)]

bad = dict.fromkeys(["leading_or_trailing_dash", "double_dash", "non_alnum_other_than_dash",
                     "empty_or_whitespace_only", "spurious_dash_without_input_run",
                     "missing_dash_for_input_run", "uppercase_kept"], 0)
for s in inputs:
    out = slugify(s)
    runs = 0
    seen = False
    for c in s:
        if c.isalnum():
            seen = False
        elif not seen:
            seen = True
            runs += 1
    if out.startswith("-") or out.endswith("-"):
        bad["leading_or_trailing_dash"] += 1
    if "--" in out:
        bad["double_dash"] += 1
    if any(c for c in out if c != "-" and not c.isalnum()):
        bad["non_alnum_other_than_dash"] += 1
    if not s.strip() and out != "":
        bad["empty_or_whitespace_only"] += 1
    if out.count("-") > runs:
        bad["spurious_dash_without_input_run"] += 1
    if out.count("-") < runs:
        bad["missing_dash_for_input_run"] += 1
    if any(c.isupper() for c in out):
        bad["uppercase_kept"] += 1
print("shipped invariant violations:", bad)
print("idempotency violations:", sum(1 for s in inputs if slugify(slugify(s)) != slugify(s)))

diffs = [(s, slugify(s), spec_literal(s)) for s in inputs if slugify(s) != spec_literal(s)]
print("mismatches vs spec-literal sequential reading:", len(diffs), diffs[:4])
print("mismatch chars involved:", sorted({c for s, _, _ in diffs if not c.isalnum() or len(c.lower()) > 1})[:10])
print("diffs contain U+0130:", all("\u0130" in s for s, _, _ in diffs))

# --- targeted edge cases ----------------------------------------------------
EDGE = ["", " ", "   ", "\t\n", "-", "--", "-.-", "a", "\u00a0a\u00a0b", "a\u200bb",
        "\u0301abc", "\u00b2\u00b2", "\u01c5 x", "\u0130", "\u0130\u0130\u0130", "\u0130 a \u0130",
        "\u00dcber \u00e9", "\u0219\u0218\u00ee\u00e2\u0106", "123 456", "C++ & C#", "a_b/c\\d",
        "\u65e5\u672c\u7d2d\u8a9e test", "\u0130".casefold().join(["a", "b"]), "HELLO\u2019WORLD"]
for s in EDGE:
    print("edge", repr(s), "->", repr(slugify(s)))

print("spec examples:", [(s, slugify(s), e) for s, e in [
    ("Hello, World!", "hello-world"), ("  Multe   spatii!!  ", "multe-spatii"),
    ("\u0106\u0102\u00ee\u0219\u0218 GPS", "\u0106\u0102\u00ee\u0219\u0218-gps"),
    ("---trim---", "trim")] if slugify(s) != e])
print("truncate regression:", truncate("abcdef", 3), truncate("ab", 3), truncate("", 0))
