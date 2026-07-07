"""Generate Oh My Pi's pixel-art pi mascot status icon family.

Generates:
  - seven 128px transparent APNGs in OhMyPi*.dataset folders
  - static 24px and 48px OhMyPiMark PNGs
  - design/ohmypi-pixel-pi-icons/contact-sheet.png for visual review

The mascot is a hand-authored pixel character based on the pi symbol, with
status-specific body motion, face changes, and accent pixels.

Usage:
  python3 scripts/generate_ohmypi_pixel_pi_icons.py
"""

from __future__ import annotations

import math
from pathlib import Path
from typing import Callable, Iterable

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
ASSET_ROOT = ROOT / "Glint" / "Resources" / "Assets.xcassets"
OUT = ROOT / "design" / "ohmypi-pixel-pi-icons"

SIZE = 128
PIXEL_SIZE = 64
FPS_MS = 70
LOOP = 32

INK = (21, 26, 45)
INK_SOFT = (43, 53, 83)
PI_PURPLE = (117, 92, 232)
PI_LILAC = (162, 132, 255)
PI_BLUE = (71, 167, 240)
PI_CYAN = (84, 217, 227)
PI_PINK = (248, 124, 191)
PI_AMBER = (255, 202, 96)
PI_GREEN = (78, 218, 139)
PI_RED = (238, 82, 98)
WHITE = (241, 249, 255)


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
    highlight: bool = True,
) -> None:
    x0, y0, x1, y1 = xy
    draw.rectangle((x0, y0, x1, y1), fill=outline)
    draw.rectangle((x0 + 1, y0 + 1, x1 - 1, y1 - 1), fill=fill)
    if highlight and x1 - x0 > 7 and y1 - y0 > 7:
        draw.line((x0 + 2, y0 + 2, x1 - 3, y0 + 2), fill=WHITE, width=1)


def eye(draw: ImageDraw.ImageDraw, x: int, y: int, *, mood: str, blink: float) -> None:
    if blink > 0.55:
        draw.rectangle((x - 2, y, x + 3, y + 1), fill=INK)
        return
    if mood == "happy":
        draw.line((x - 2, y + 1, x, y - 1, x + 3, y + 1), fill=INK, width=1)
    elif mood == "sad":
        draw.line((x - 2, y - 1, x, y + 1, x + 3, y - 1), fill=INK, width=1)
    elif mood == "ask":
        draw.rectangle((x - 1, y - 2, x + 2, y + 3), fill=INK)
        draw.rectangle((x + 1, y - 1, x + 2, y), fill=PI_AMBER)
    elif mood == "focus":
        draw.rectangle((x - 2, y - 1, x + 3, y + 2), fill=INK)
        draw.rectangle((x + 1, y - 1, x + 3, y), fill=PI_CYAN)
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
        draw.rectangle((x - 4, y, x + 4, y + 1), fill=INK)
    else:
        draw.rectangle((x - 2, y, x + 2, y + 1), fill=INK)


def spark(draw: ImageDraw.ImageDraw, cx: int, cy: int, color: tuple[int, int, int], alpha: int = 255) -> None:
    draw.line((cx - 3, cy, cx + 3, cy), fill=(*color, alpha), width=1)
    draw.line((cx, cy - 3, cx, cy + 3), fill=(*color, alpha), width=1)
    draw.point((cx, cy), fill=(*WHITE, alpha))


def draw_pi_mascot(
    *,
    bob: int = 0,
    squash: int = 0,
    lean: int = 0,
    arm_lift: int = 0,
    arm_spread: int = 0,
    foot_shift: int = 0,
    mood: str = "calm",
    blink: float = 0.0,
    phase: float = 0.0,
    accent: tuple[int, int, int] = PI_CYAN,
) -> Image.Image:
    img = Image.new("RGBA", (PIXEL_SIZE, PIXEL_SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img, "RGBA")
    y = 4 + bob
    sx = squash

    # The feet and arms are tiny status-readable body parts, while the torso
    # remains unmistakably the pi mark.
    px_rect(d, (19 + foot_shift, 48 + y, 29 + foot_shift, 54 + y), PI_BLUE)
    px_rect(d, (36 - foot_shift, 48 + y, 46 - foot_shift, 54 + y), PI_PINK)

    left_y = 31 + y - arm_lift
    right_y = 31 + y - max(0, arm_lift // 2)
    px_rect(d, (9 - arm_spread, left_y, 20 - arm_spread, left_y + 8), accent, highlight=False)
    px_rect(d, (45 + arm_spread, right_y, 56 + arm_spread, right_y + 8), PI_AMBER, highlight=False)
    d.rectangle((20 - arm_spread, left_y + 3, 24 + lean, left_y + 5), fill=INK_SOFT)
    d.rectangle((41 + lean, right_y + 3, 45 + arm_spread, right_y + 5), fill=INK_SOFT)

    top = PI_LILAC if phase < 0.5 else PI_PURPLE
    px_rect(d, (15 + lean, 12 + y + sx, 50 + lean, 23 + y + sx), top)
    px_rect(d, (19 + lean, 21 + y, 29 + lean, 47 + y - sx), PI_BLUE)
    px_rect(d, (37 + lean, 21 + y, 47 + lean, 47 + y - sx), PI_PINK)
    px_rect(d, (28 + lean, 22 + y, 38 + lean, 32 + y), PI_PURPLE)

    # A few diagonal pixels make the symbol feel less like a blocky table.
    d.rectangle((14 + lean, 21 + y + sx, 17 + lean, 24 + y + sx), fill=INK)
    d.rectangle((48 + lean, 21 + y + sx, 51 + lean, 24 + y + sx), fill=INK)
    d.rectangle((18 + lean, 24 + y, 21 + lean, 27 + y), fill=PI_LILAC)
    d.rectangle((44 + lean, 24 + y, 47 + lean, 27 + y), fill=PI_AMBER)

    eye(d, 27 + lean, 18 + y + sx, mood=mood, blink=blink)
    eye(d, 39 + lean, 18 + y + sx, mood=mood, blink=blink)
    mouth(d, 33 + lean, 27 + y, mood=mood)

    # Chest pixels move with the mark and echo math/terminal status lights.
    d.rectangle((28 + lean, 36 + y, 31 + lean, 39 + y), fill=PI_CYAN)
    d.rectangle((34 + lean, 36 + y, 37 + lean, 39 + y), fill=PI_GREEN)
    spark(d, 51 + lean, 15 + y, PI_AMBER, int(180 + 55 * ease_sine(phase)))
    return img.resize((SIZE, SIZE), Image.Resampling.NEAREST)


def idle_frame(i: int, n: int) -> Image.Image:
    t = i / n
    blink = clamp01(1 - abs(((t * 2.0) % 1) - 0.12) / 0.035)
    return draw_pi_mascot(
        bob=round(math.sin(t * math.tau) * 1),
        squash=round(ease_sine(t) * 1),
        arm_lift=round(ease_sine(t) * 1),
        mood="calm",
        blink=blink,
        phase=t,
    )


def thinking_frame(i: int, n: int) -> Image.Image:
    t = i / n
    return draw_pi_mascot(
        bob=round(math.sin(t * math.tau * 2) * 1),
        lean=round(math.sin(t * math.tau) * 2),
        arm_lift=2 + round(ease_sine(t) * 4),
        arm_spread=-1,
        mood="focus",
        phase=(t * 2) % 1,
        accent=PI_GREEN,
    )


def tool_frame(i: int, n: int) -> Image.Image:
    t = i / n
    return draw_pi_mascot(
        bob=round(math.sin(t * math.tau * 3) * 1),
        lean=round(math.sin(t * math.tau * 2) * 1),
        arm_lift=round((0.5 + 0.5 * math.sin(t * math.tau * 4)) * 9),
        arm_spread=round(math.sin(t * math.tau * 2) * 3),
        foot_shift=round(math.sin(t * math.tau * 2) * 2),
        mood="focus",
        phase=t,
        accent=PI_CYAN,
    )


def compressing_frame(i: int, n: int) -> Image.Image:
    t = i / n
    pulse = ease_sine((t * 2) % 1)
    return draw_pi_mascot(
        bob=round(pulse * 3),
        squash=round(pulse * 5),
        arm_lift=round(pulse * -2),
        arm_spread=round(pulse * -4),
        mood="focus",
        phase=pulse,
        accent=PI_BLUE,
    )


def permission_frame(i: int, n: int) -> Image.Image:
    t = i / n
    pulse = ease_sine(t)
    return draw_pi_mascot(
        bob=round(math.sin(t * math.tau) * 1),
        lean=round(1 + pulse * 2),
        arm_lift=5 + round(pulse * 5),
        arm_spread=round(pulse * 2),
        mood="ask",
        phase=t,
        accent=PI_AMBER,
    )


def done_frame(i: int, n: int) -> Image.Image:
    t = i / n
    pop = math.sin(min(1.0, t * 2.2) * math.pi)
    return draw_pi_mascot(
        bob=round(-3 * pop + math.sin(t * math.tau * 2) * 1),
        squash=round((1 - pop) * 1),
        arm_lift=8 + round(pop * 5),
        arm_spread=round(pop * 4),
        foot_shift=round(math.sin(t * math.tau * 2) * 2),
        mood="happy",
        phase=t,
        accent=PI_GREEN,
    )


def failed_frame(i: int, n: int) -> Image.Image:
    t = i / n
    shake = round(math.sin(t * math.tau * 5) * 2)
    return draw_pi_mascot(
        bob=2,
        squash=2,
        lean=shake,
        arm_lift=-2,
        arm_spread=-2,
        foot_shift=shake // 2,
        mood="sad",
        phase=t,
        accent=PI_RED,
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
    iset = ASSET_ROOT / "OhMyPiMark.imageset"
    iset.mkdir(exist_ok=True)
    mark = idle_frame(7, LOOP)
    mark.resize((24, 24), Image.Resampling.NEAREST).save(iset / "ohmypi24.png")
    mark.resize((48, 48), Image.Resampling.NEAREST).save(iset / "ohmypi48.png")
    (iset / "Contents.json").write_text(
        '{\n'
        '  "images": [\n'
        "    {\n"
        '      "filename": "ohmypi24.png",\n'
        '      "idiom": "universal",\n'
        '      "scale": "1x"\n'
        "    },\n"
        "    {\n"
        '      "filename": "ohmypi48.png",\n'
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
        "idle": ("OhMyPiIdle", "ohmypi-idle.png", idle_frame),
        "thinking": ("OhMyPiThinking", "ohmypi-thinking.png", thinking_frame),
        "tool": ("OhMyPiToolCall", "ohmypi-tool-call.png", tool_frame),
        "compressing": ("OhMyPiCompressing", "ohmypi-compressing.png", compressing_frame),
        "permission": ("OhMyPiNeedsPermission", "ohmypi-needs-permission.png", permission_frame),
        "done": ("OhMyPiDone", "ohmypi-done.png", done_frame),
        "failed": ("OhMyPiFailed", "ohmypi-failed.png", failed_frame),
    }
    for _, (asset, filename, factory) in states.items():
        write_dataset(asset, filename, factory)
    write_mark()
    write_contact_sheet({name: factory(8, LOOP) for name, (_, _, factory) in states.items()})
    print("Wrote Oh My Pi pixel pi assets")
    print(f"Preview: {OUT / 'contact-sheet.png'}")


if __name__ == "__main__":
    main()
