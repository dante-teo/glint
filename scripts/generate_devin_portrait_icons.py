"""Generate Devin's portrait-based status icon family.

Source:
  scripts/assets/devin-portrait-source.png

Generates:
  - seven 128px transparent APNGs in Devin*.dataset folders
  - static 24px and 48px DevinMark PNGs
  - design/devin-portrait-icons/contact-sheet.png for visual review

The app stores APNGs as `.png` data assets. `AnimatedGIFView` decodes them
through ImageIO, which preserves full alpha better than GIF for this portrait.

Usage:
  python3 scripts/generate_devin_portrait_icons.py

After regenerating, run:
  xcodebuild test -project Glint.xcodeproj -scheme Glint \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:GlintTests/MascotAssetTests
"""

from __future__ import annotations

import math
from pathlib import Path
from typing import Callable, Iterable

from PIL import Image, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
ASSET_ROOT = ROOT / "Glint" / "Resources" / "Assets.xcassets"
OUT = ROOT / "design" / "devin-portrait-icons"
SOURCE = ROOT / "scripts" / "assets" / "devin-portrait-source.png"

SIZE = 128
SCALE = 4
FPS_MS = 60
LOOP = 40

CREAM = (238, 214, 176)
INK = (47, 31, 23)
TEAL = (54, 166, 169)
CYAN = (90, 206, 255)
AMBER = (255, 188, 86)
GREEN = (63, 209, 116)
RED = (244, 91, 101)
WHITE = (255, 255, 255)
SKIN = (222, 160, 123)


def ease_sine(t: float) -> float:
    return 0.5 - 0.5 * math.cos(t * math.tau)


def clamp01(v: float) -> float:
    return min(1.0, max(0.0, v))


def load_portrait() -> Image.Image:
    if not SOURCE.exists():
        raise FileNotFoundError(
            f"Missing source portrait: {SOURCE}. Restore this tracked asset before regenerating Devin icons."
        )
    src = Image.open(SOURCE).convert("RGBA")
    w, h = src.size
    side = min(w, h)
    # Slightly tighter and higher than a center crop so the face stays legible
    # in 24-40pt chrome while retaining the white blazer cue.
    crop_side = int(side * 0.86)
    left = (w - crop_side) // 2
    top = int(side * 0.02)
    return src.crop((left, top, left + crop_side, top + crop_side))


def avatar_base(size: int = SIZE) -> Image.Image:
    canvas = size * SCALE
    badge = int(canvas * 0.91)
    pad = (canvas - badge) // 2

    img = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow, "RGBA")
    sd.ellipse((pad + 4, pad + 10, pad + badge - 4, pad + badge + 6), fill=(0, 0, 0, 42))
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=5 * SCALE))
    img.alpha_composite(shadow)

    mask = Image.new("L", (badge, badge), 0)
    md = ImageDraw.Draw(mask)
    md.ellipse((0, 0, badge - 1, badge - 1), fill=255)

    portrait = load_portrait().resize((badge, badge), Image.Resampling.LANCZOS)
    img.paste(portrait, (pad, pad), mask)

    ring = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    rd = ImageDraw.Draw(ring, "RGBA")
    rd.ellipse((pad + 1, pad + 1, pad + badge - 1, pad + badge - 1), outline=(*WHITE, 180), width=2 * SCALE)
    rd.ellipse((pad + 4, pad + 4, pad + badge - 4, pad + badge - 4), outline=(*CREAM, 115), width=SCALE)
    img.alpha_composite(ring)
    return img.resize((size, size), Image.Resampling.LANCZOS)


BASE = avatar_base()


def transform_avatar(
    *,
    scale: float = 1.0,
    bob: float = 0.0,
    tilt: float = 0.0,
    x_scale: float = 1.0,
    y_scale: float = 1.0,
) -> Image.Image:
    canvas = SIZE * SCALE
    src = BASE.resize((canvas, canvas), Image.Resampling.LANCZOS)

    if abs(x_scale - 1.0) > 0.001 or abs(y_scale - 1.0) > 0.001:
        resized = src.resize((round(canvas * x_scale), round(canvas * y_scale)), Image.Resampling.BICUBIC)
        src = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
        src.alpha_composite(resized, ((canvas - resized.width) // 2, (canvas - resized.height) // 2))

    if abs(tilt) > 0.01:
        src = src.rotate(tilt, resample=Image.Resampling.BICUBIC, center=(canvas / 2, canvas / 2))

    if abs(scale - 1.0) > 0.001:
        resized = src.resize((round(canvas * scale), round(canvas * scale)), Image.Resampling.LANCZOS)
        src = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
        src.alpha_composite(resized, ((canvas - resized.width) // 2, (canvas - resized.height) // 2))

    if abs(bob) > 0.01:
        shifted = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
        shifted.alpha_composite(src, (0, round(bob * SCALE)))
        src = shifted

    return src.resize((SIZE, SIZE), Image.Resampling.LANCZOS)


def draw_plus(draw: ImageDraw.ImageDraw, cx: float, cy: float, r: float, color: tuple[int, int, int], alpha: int) -> None:
    width = max(1, round(r / 4))
    draw.line((cx - r, cy, cx + r, cy), fill=(*color, alpha), width=width)
    draw.line((cx, cy - r, cx, cy + r), fill=(*color, alpha), width=width)


def draw_blink(frame: Image.Image, amount: float) -> None:
    if amount <= 0.01:
        return
    d = ImageDraw.Draw(frame, "RGBA")
    alpha = round(180 * clamp01(amount))
    for cx in (50, 78):
        d.ellipse((cx - 11, 52 - 2 * amount, cx + 11, 61 + 3 * amount), fill=(*SKIN, alpha))
        d.arc((cx - 10, 53, cx + 10, 62), start=190, end=350, fill=(*INK, round(150 * amount)), width=1)


def idle_frame(i: int, n: int) -> Image.Image:
    t = i / n
    breathe = ease_sine(t)
    blink_phase = (t * 2.0) % 1
    blink = clamp01(1 - abs(blink_phase - 0.08) / 0.035) if blink_phase < 0.16 else 0
    frame = transform_avatar(scale=0.99 + 0.012 * breathe, bob=math.sin(t * math.tau) * 0.7)
    draw_blink(frame, blink)
    return frame


def thinking_frame(i: int, n: int) -> Image.Image:
    t = i / n
    frame = transform_avatar(
        scale=1.0 + 0.006 * math.sin(t * math.tau * 2),
        bob=math.sin(t * math.tau * 2) * 0.6,
        tilt=math.sin(t * math.tau) * 2.2,
    )
    d = ImageDraw.Draw(frame, "RGBA")
    for k in range(3):
        phase = (t + k / 3) % 1
        lift = math.sin(phase * math.tau) * 3
        r = 2.2 + 1.3 * ease_sine(phase)
        x = 44 + k * 13
        y = 18 - lift
        d.ellipse((x - r, y - r, x + r, y + r), fill=(*AMBER, 235))
    return frame


def tool_frame(i: int, n: int) -> Image.Image:
    t = i / n
    frame = transform_avatar(scale=1.0, bob=math.sin(t * math.tau * 2) * 0.35)
    d = ImageDraw.Draw(frame, "RGBA")
    sweep = 25 + 78 * t
    d.rounded_rectangle((sweep - 15, 33, sweep + 15, 36), radius=2, fill=(*CYAN, 210))
    d.rounded_rectangle((28, 92, 52, 96), radius=2, fill=(*CYAN, 205))
    d.rounded_rectangle((56, 99, 78, 103), radius=2, fill=(*TEAL, 205))
    d.rounded_rectangle((82, 92, 102, 96), radius=2, fill=(*CYAN, 205))
    for k in range(3):
        phase = (t * 1.4 + k / 3) % 1
        draw_plus(d, 28 + 74 * phase, 82 + math.sin(phase * math.tau) * 4, 3.4, CYAN, round(210 * (1 - phase)))
    return frame


def compressing_frame(i: int, n: int) -> Image.Image:
    t = i / n
    squeeze = ease_sine((t * 2) % 1)
    frame = transform_avatar(
        scale=1.0,
        bob=1.2 * squeeze,
        x_scale=1.0 + 0.035 * squeeze,
        y_scale=1.0 - 0.055 * squeeze,
    )
    d = ImageDraw.Draw(frame, "RGBA")
    top_y = 17 + 8 * squeeze
    bottom_y = 108 - 8 * squeeze
    d.rounded_rectangle((36, top_y, 92, top_y + 4), radius=2, fill=(*CYAN, 230))
    d.rounded_rectangle((36, bottom_y, 92, bottom_y + 4), radius=2, fill=(*CYAN, 230))
    for k in range(3):
        w = 23 - k * 4
        x = 64 - w / 2
        y = 84 + k * 6 + math.sin(t * math.tau + k) * 1.2
        d.rounded_rectangle((x, y, x + w, y + 3), radius=1.5, fill=(*AMBER, 220))
    return frame


def permission_frame(i: int, n: int) -> Image.Image:
    t = i / n
    pulse = ease_sine((t * 2) % 1)
    frame = transform_avatar(scale=0.995 + 0.008 * pulse, bob=math.sin(t * math.tau) * 0.4)
    d = ImageDraw.Draw(frame, "RGBA")
    r = 13 + 6 * pulse
    alpha = round(190 * (1 - pulse))
    d.ellipse((94 - r, 30 - r, 94 + r, 30 + r), outline=(*AMBER, alpha), width=2)
    d.ellipse((88, 24, 100, 36), fill=(*AMBER, 245))
    d.text((91, 22), "!", fill=(*INK, 230))
    return frame


def done_frame(i: int, n: int) -> Image.Image:
    t = i / n
    pop = min(1.0, t * 3.2)
    settle = 1.0 + 0.025 * math.sin(pop * math.pi) * (1 - clamp01((t - 0.35) / 0.65))
    frame = transform_avatar(scale=settle, bob=-1.0 * math.sin(min(1, t * 2) * math.pi))
    d = ImageDraw.Draw(frame, "RGBA")
    if 0.05 < t < 0.65:
        phase = (t - 0.05) / 0.60
        alpha = round(230 * math.sin(phase * math.pi))
        d.arc((21, 20, 107, 106), start=210, end=210 + 245 * phase, fill=(*GREEN, alpha), width=3)
        draw_plus(d, 35, 34, 6 + 8 * phase, AMBER, alpha)
    if t > 0.18:
        p = clamp01((t - 0.18) / 0.32)
        d.line((88, 33, 94, 39), fill=(*GREEN, 250), width=4)
        d.line((94, 39, 106 - 8 * (1 - p), 25 + 14 * (1 - p)), fill=(*GREEN, 250), width=4)
    return frame


def failed_frame(i: int, n: int) -> Image.Image:
    t = i / n
    shake = math.sin(t * math.tau * 4) * 1.7 * (0.35 + 0.65 * ease_sine(t))
    frame = transform_avatar(scale=1.0, bob=0, tilt=shake)
    d = ImageDraw.Draw(frame, "RGBA")
    pulse = ease_sine((t * 2) % 1)
    r = 11 + 5 * pulse
    d.ellipse((94 - r, 31 - r, 94 + r, 31 + r), outline=(*RED, round(180 * (1 - pulse))), width=2)
    d.line((88, 25, 100, 37), fill=(*RED, 240), width=3)
    d.line((100, 25, 88, 37), fill=(*RED, 240), width=3)
    return frame


def save_apng(path: Path, frames: Iterable[Image.Image], duration: int = FPS_MS) -> None:
    frames = [frame.convert("RGBA") for frame in frames]
    path.parent.mkdir(parents=True, exist_ok=True)
    frames[0].save(
        path,
        save_all=True,
        append_images=frames[1:],
        duration=duration,
        loop=0,
        format="PNG",
        disposal=1,
        blend=0,
    )


def write_dataset(asset_name: str, filename: str, factory: Callable[[int, int], Image.Image], frames: int = LOOP) -> None:
    ds = ASSET_ROOT / f"{asset_name}.dataset"
    save_apng(ds / filename, (factory(i, frames) for i in range(frames)))
    (ds / "Contents.json").write_text(
        '{\n'
        '  "data": [\n'
        "    {\n"
        f'      "filename": "{filename}",\n'
        '      "idiom": "universal"\n'
        "    }\n"
        "  ],\n"
        '  "info": {\n'
        '    "author": "xcode",\n'
        '    "version": 1\n'
        "  }\n"
        "}\n",
        encoding="utf-8",
    )


def write_mark() -> None:
    iset = ASSET_ROOT / "DevinMark.imageset"
    iset.mkdir(exist_ok=True)
    BASE.resize((24, 24), Image.Resampling.LANCZOS).save(iset / "devin24.png")
    BASE.resize((48, 48), Image.Resampling.LANCZOS).save(iset / "devin48.png")
    (iset / "Contents.json").write_text(
        '{\n'
        '  "images": [\n'
        "    {\n"
        '      "filename": "devin24.png",\n'
        '      "idiom": "universal",\n'
        '      "scale": "1x"\n'
        "    },\n"
        "    {\n"
        '      "filename": "devin48.png",\n'
        '      "idiom": "universal",\n'
        '      "scale": "2x"\n'
        "    }\n"
        "  ],\n"
        '  "info": {\n'
        '    "author": "xcode",\n'
        '    "version": 1\n'
        "  }\n"
        "}\n",
        encoding="utf-8",
    )


def write_contact_sheet(samples: dict[str, Image.Image]) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    cell = 160
    sheet = Image.new("RGBA", (cell * 4, cell * 2), (18, 18, 22, 255))
    d = ImageDraw.Draw(sheet, "RGBA")
    for idx, (name, img) in enumerate(samples.items()):
        x = (idx % 4) * cell
        y = (idx // 4) * cell
        d.rounded_rectangle((x + 12, y + 12, x + cell - 12, y + cell - 28), radius=10, fill=(255, 255, 255, 12))
        sheet.alpha_composite(img, (x + 16, y + 8))
        d.text((x + 16, y + cell - 24), name, fill=(225, 225, 230, 255))
    sheet.save(OUT / "contact-sheet.png")


def main() -> None:
    states: dict[str, tuple[str, str, Callable[[int, int], Image.Image]]] = {
        "idle": ("DevinIdle", "devin-idle.png", idle_frame),
        "thinking": ("DevinThinking", "devin-thinking.png", thinking_frame),
        "tool": ("DevinToolCall", "devin-tool-call.png", tool_frame),
        "compressing": ("DevinCompressing", "devin-compressing.png", compressing_frame),
        "permission": ("DevinNeedsPermission", "devin-needs-permission.png", permission_frame),
        "done": ("DevinDone", "devin-done.png", done_frame),
        "failed": ("DevinFailed", "devin-failed.png", failed_frame),
    }
    for _, (asset, filename, factory) in states.items():
        write_dataset(asset, filename, factory)
    write_mark()
    write_contact_sheet({name: factory(18, LOOP) for name, (_, _, factory) in states.items()})
    print(f"Wrote Devin portrait assets from {SOURCE}")
    print(f"Preview: {OUT / 'contact-sheet.png'}")


if __name__ == "__main__":
    main()
