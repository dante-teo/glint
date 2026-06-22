"""Generate Devin's pixel-monster status icon family.

Generates:
  - seven 128px transparent APNGs in DevinPixel*.dataset folders
  - static 24px and 48px DevinPixelMark PNGs
  - design/devin-pixel-monster-icons/contact-sheet.png for visual review

The monster is hand-authored pixel art inspired by Devin's blue/green
connected-block mark. Motion comes from body, face, limb, and silhouette
changes, not from animating decorative doodles on a static logo.

Usage:
  python3 scripts/generate_devin_pixel_monster_icons.py
"""

from __future__ import annotations

import math
from pathlib import Path
from typing import Callable, Iterable

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
ASSET_ROOT = ROOT / "Glint" / "Resources" / "Assets.xcassets"
OUT = ROOT / "design" / "devin-pixel-monster-icons"

SIZE = 128
PIXEL_SIZE = 64
SCALE = SIZE // PIXEL_SIZE
FPS_MS = 70
LOOP = 32

INK = (19, 35, 54)
INK_SOFT = (28, 57, 78)
BLUE = (54, 122, 224)
CYAN = (56, 169, 228)
TEAL = (70, 206, 175)
GREEN = (85, 202, 154)
MINT = (117, 230, 187)
WHITE = (237, 252, 255)
AMBER = (255, 195, 76)
RED = (232, 82, 92)


def ease_sine(t: float) -> float:
    return 0.5 - 0.5 * math.cos(t * math.tau)


def clamp01(v: float) -> float:
    return min(1.0, max(0.0, v))


def px_rect(
    draw: ImageDraw.ImageDraw,
    xy: tuple[int, int, int, int],
    fill: tuple[int, int, int],
    *,
    outline: tuple[int, int, int] = INK,
) -> None:
    x0, y0, x1, y1 = xy
    draw.rectangle((x0, y0, x1, y1), fill=outline)
    draw.rectangle((x0 + 1, y0 + 1, x1 - 1, y1 - 1), fill=fill)
    if x1 - x0 > 8 and y1 - y0 > 8:
        draw.line((x0 + 2, y0 + 2, x1 - 3, y0 + 2), fill=WHITE, width=1)


def px_poly(
    draw: ImageDraw.ImageDraw,
    points: list[tuple[int, int]],
    fill: tuple[int, int, int],
    *,
    outline: tuple[int, int, int] = INK,
) -> None:
    draw.polygon(points, fill=outline)
    if len(points) == 6:
        inset = [(x + (1 if x < 32 else -1), y + (1 if y < 32 else -1)) for x, y in points]
        draw.polygon(inset, fill=fill)
    else:
        draw.polygon(points, fill=fill)


def eye(draw: ImageDraw.ImageDraw, x: int, y: int, *, mood: str, blink: float = 0.0) -> None:
    if blink > 0.55:
        draw.rectangle((x - 2, y, x + 3, y + 1), fill=INK)
        return
    if mood == "happy":
        draw.line((x - 2, y + 1, x, y - 1, x + 3, y + 1), fill=INK, width=1)
    elif mood == "sad":
        draw.line((x - 2, y - 1, x, y + 1, x + 3, y - 1), fill=INK, width=1)
    elif mood == "focus":
        draw.rectangle((x - 2, y - 1, x + 3, y + 2), fill=INK)
        draw.rectangle((x + 1, y - 1, x + 3, y), fill=MINT)
    else:
        draw.rectangle((x - 2, y - 2, x + 3, y + 3), fill=INK)
        draw.rectangle((x + 1, y - 1, x + 2, y), fill=WHITE)


def mouth(draw: ImageDraw.ImageDraw, x: int, y: int, *, mood: str) -> None:
    if mood == "happy":
        draw.line((x - 4, y, x - 2, y + 2, x + 2, y + 2, x + 4, y), fill=INK, width=1)
    elif mood == "sad":
        draw.line((x - 4, y + 2, x - 2, y, x + 2, y, x + 4, y + 2), fill=INK, width=1)
    elif mood == "ask":
        draw.rectangle((x - 1, y, x + 1, y + 2), fill=INK)
    elif mood == "focus":
        draw.rectangle((x - 3, y, x + 3, y + 1), fill=INK)
    else:
        draw.rectangle((x - 2, y, x + 2, y + 1), fill=INK)


def draw_monster(
    *,
    bob: int = 0,
    squash: int = 0,
    lean: int = 0,
    arm_lift: int = 0,
    arm_spread: int = 0,
    foot_shift: int = 0,
    mood: str = "calm",
    blink: float = 0.0,
    body_phase: float = 0.0,
) -> Image.Image:
    img = Image.new("RGBA", (PIXEL_SIZE, PIXEL_SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img, "RGBA")
    y = 4 + bob
    sx = squash

    # Legs move independently so even tiny tab icons read as character motion.
    px_rect(d, (23 + foot_shift, 43 - sx + y, 30 + foot_shift, 53 + y), CYAN)
    px_rect(d, (35 - foot_shift, 43 - sx + y, 42 - foot_shift, 53 + y), GREEN)
    px_rect(d, (20 + foot_shift, 51 + y, 31 + foot_shift, 56 + y), BLUE)
    px_rect(d, (34 - foot_shift, 51 + y, 45 - foot_shift, 56 + y), TEAL)

    # Modular arms echo the Devin logo's linked blocks, but they are limbs.
    left_y = 27 + y - arm_lift
    right_y = 27 + y - max(0, arm_lift // 2)
    px_rect(d, (10 - arm_spread, left_y, 22 - arm_spread, left_y + 12), CYAN)
    px_rect(d, (43 + arm_spread, right_y, 55 + arm_spread, right_y + 12), GREEN)
    d.rectangle((22 - arm_spread, left_y + 5, 27, left_y + 8), fill=INK_SOFT)
    d.rectangle((38, right_y + 5, 43 + arm_spread, right_y + 8), fill=INK_SOFT)

    # Body and head change shape with squash/lean, not as a single static logo.
    px_poly(
        d,
        [
            (23 + lean, 23 + y + sx),
            (41 + lean, 23 + y + sx),
            (47 + lean, 30 + y),
            (42 + lean, 43 + y - sx),
            (22 + lean, 43 + y - sx),
            (17 + lean, 31 + y),
        ],
        TEAL if body_phase < 0.5 else GREEN,
    )
    px_rect(d, (24 + lean, 10 + y + sx, 42 + lean, 27 + y), BLUE)
    px_rect(d, (19 + lean, 14 + y + sx, 26 + lean, 22 + y + sx), CYAN)
    px_rect(d, (40 + lean, 14 + y + sx, 47 + lean, 22 + y + sx), GREEN)
    px_rect(d, (27 + lean, 6 + y + sx, 33 + lean, 11 + y + sx), BLUE)
    px_rect(d, (36 + lean, 6 + y + sx, 42 + lean, 11 + y + sx), TEAL)

    eye(d, 29 + lean, 18 + y + sx, mood=mood, blink=blink)
    eye(d, 38 + lean, 18 + y + sx, mood=mood, blink=blink)
    mouth(d, 34 + lean, 23 + y + sx, mood=mood)

    # Chest pixels are attached to the monster and move with its body.
    d.rectangle((30 + lean, 32 + y, 33 + lean, 35 + y), fill=BLUE)
    d.rectangle((36 + lean, 32 + y, 39 + lean, 35 + y), fill=MINT)
    return img.resize((SIZE, SIZE), Image.Resampling.NEAREST)


def idle_frame(i: int, n: int) -> Image.Image:
    t = i / n
    blink = clamp01(1 - abs(((t * 2.0) % 1) - 0.10) / 0.035)
    return draw_monster(
        bob=round(math.sin(t * math.tau) * 1),
        squash=round(ease_sine(t) * 1),
        arm_lift=round(ease_sine(t) * 1),
        mood="calm",
        blink=blink,
        body_phase=t,
    )


def thinking_frame(i: int, n: int) -> Image.Image:
    t = i / n
    return draw_monster(
        bob=round(math.sin(t * math.tau * 2) * 1),
        lean=round(math.sin(t * math.tau) * 2),
        arm_lift=2 + round(ease_sine(t) * 4),
        arm_spread=-1,
        mood="focus",
        body_phase=(t * 2) % 1,
    )


def tool_frame(i: int, n: int) -> Image.Image:
    t = i / n
    return draw_monster(
        bob=round(math.sin(t * math.tau * 3) * 1),
        lean=round(math.sin(t * math.tau * 2) * 1),
        arm_lift=round((0.5 + 0.5 * math.sin(t * math.tau * 4)) * 9),
        arm_spread=round(math.sin(t * math.tau * 2) * 3),
        foot_shift=round(math.sin(t * math.tau * 2) * 2),
        mood="focus",
        body_phase=t,
    )


def compressing_frame(i: int, n: int) -> Image.Image:
    t = i / n
    pulse = ease_sine((t * 2) % 1)
    return draw_monster(
        bob=round(pulse * 3),
        squash=round(pulse * 5),
        arm_lift=round(pulse * -2),
        arm_spread=round(pulse * -4),
        mood="focus",
        body_phase=pulse,
    )


def permission_frame(i: int, n: int) -> Image.Image:
    t = i / n
    pulse = ease_sine(t)
    return draw_monster(
        bob=round(math.sin(t * math.tau) * 1),
        lean=round(1 + pulse * 2),
        arm_lift=5 + round(pulse * 5),
        arm_spread=round(pulse * 2),
        mood="ask",
        body_phase=t,
    )


def done_frame(i: int, n: int) -> Image.Image:
    t = i / n
    pop = math.sin(min(1.0, t * 2.2) * math.pi)
    return draw_monster(
        bob=round(-3 * pop + math.sin(t * math.tau * 2) * 1),
        squash=round((1 - pop) * 1),
        arm_lift=8 + round(pop * 5),
        arm_spread=round(pop * 4),
        foot_shift=round(math.sin(t * math.tau * 2) * 2),
        mood="happy",
        body_phase=t,
    )


def failed_frame(i: int, n: int) -> Image.Image:
    t = i / n
    shake = round(math.sin(t * math.tau * 5) * 2)
    return draw_monster(
        bob=2,
        squash=2,
        lean=shake,
        arm_lift=-2,
        arm_spread=-2,
        foot_shift=shake // 2,
        mood="sad",
        body_phase=t,
    )


def save_apng(path: Path, frames: Iterable[Image.Image], duration: int = FPS_MS) -> None:
    rendered = [frame.convert("RGBA") for frame in frames]
    path.parent.mkdir(parents=True, exist_ok=True)
    rendered[0].save(
        path,
        save_all=True,
        append_images=rendered[1:],
        duration=duration,
        loop=0,
        format="PNG",
        disposal=1,
        blend=0,
    )


def write_dataset(asset_name: str, filename: str, factory: Callable[[int, int], Image.Image]) -> None:
    ds = ASSET_ROOT / f"{asset_name}.dataset"
    save_apng(ds / filename, (factory(i, LOOP) for i in range(LOOP)))
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
    iset = ASSET_ROOT / "DevinPixelMark.imageset"
    iset.mkdir(exist_ok=True)
    mark = idle_frame(7, LOOP)
    mark.resize((24, 24), Image.Resampling.NEAREST).save(iset / "devin-pixel24.png")
    mark.resize((48, 48), Image.Resampling.NEAREST).save(iset / "devin-pixel48.png")
    (iset / "Contents.json").write_text(
        '{\n'
        '  "images": [\n'
        "    {\n"
        '      "filename": "devin-pixel24.png",\n'
        '      "idiom": "universal",\n'
        '      "scale": "1x"\n'
        "    },\n"
        "    {\n"
        '      "filename": "devin-pixel48.png",\n'
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
    sheet = Image.new("RGBA", (cell * 4, cell * 2), (18, 20, 24, 255))
    d = ImageDraw.Draw(sheet, "RGBA")
    for idx, (name, img) in enumerate(samples.items()):
        x = (idx % 4) * cell
        y = (idx // 4) * cell
        d.rounded_rectangle((x + 12, y + 12, x + cell - 12, y + cell - 28), radius=8, fill=(255, 255, 255, 12))
        sheet.alpha_composite(img, (x + 16, y + 6))
        d.text((x + 16, y + cell - 24), name, fill=(230, 236, 240, 255))
    sheet.save(OUT / "contact-sheet.png")


def main() -> None:
    states: dict[str, tuple[str, str, Callable[[int, int], Image.Image]]] = {
        "idle": ("DevinPixelIdle", "devin-pixel-idle.png", idle_frame),
        "thinking": ("DevinPixelThinking", "devin-pixel-thinking.png", thinking_frame),
        "tool": ("DevinPixelToolCall", "devin-pixel-tool-call.png", tool_frame),
        "compressing": ("DevinPixelCompressing", "devin-pixel-compressing.png", compressing_frame),
        "permission": ("DevinPixelNeedsPermission", "devin-pixel-needs-permission.png", permission_frame),
        "done": ("DevinPixelDone", "devin-pixel-done.png", done_frame),
        "failed": ("DevinPixelFailed", "devin-pixel-failed.png", failed_frame),
    }
    for _, (asset, filename, factory) in states.items():
        write_dataset(asset, filename, factory)
    write_mark()
    write_contact_sheet({name: factory(8, LOOP) for name, (_, _, factory) in states.items()})
    print("Wrote Devin pixel monster assets")
    print(f"Preview: {OUT / 'contact-sheet.png'}")


if __name__ == "__main__":
    main()
