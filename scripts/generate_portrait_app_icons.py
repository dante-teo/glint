#!/usr/bin/env python3
"""Generate Glint's portrait-based app icon family.

The foreground is derived from the tracked source photo so the face keeps the
original geometry. Palette application, icon framing, and resizing are kept
deterministic because these files feed both the bundle icon and runtime Dock
icon presets.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from functools import lru_cache

from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFilter, ImageOps


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "AppIconSource/portrait/source-photo.png"
LINEART_MASTER = ROOT / "AppIconSource/portrait/lineart-master.png"
BUN_SOURCE = ROOT / "AppIconSource/portrait-bun/source-photo.png"
BUN_LINEART_MASTER = ROOT / "AppIconSource/portrait-bun/lineart-master.png"
LONGHAIR_SOURCE = ROOT / "AppIconSource/portrait-longhair/source-photo.png"
LONGHAIR_LINEART_MASTER = ROOT / "AppIconSource/portrait-longhair/lineart-master.png"
POUT_SOURCE = ROOT / "AppIconSource/portrait-pout/source-photo.png"
POUT_LINEART_MASTER = ROOT / "AppIconSource/portrait-pout/lineart-master.png"
BREEZE_SOURCE = ROOT / "AppIconSource/portrait-breeze/source-photo.png"
BREEZE_LINEART_MASTER = ROOT / "AppIconSource/portrait-breeze/lineart-master.png"
OUT_DESIGN = ROOT / "design/app-icon-portrait"
ASSETS = ROOT / "Glint/Resources/Assets.xcassets"
LIQUID = ROOT / "AppIconSource/liquid-glass/AppIcon.icon/Assets"

CANVAS = 1024
LOGO = 256


@dataclass(frozen=True)
class Palette:
    top: str
    middle: str
    bottom: str
    ink: str
    skin: str
    glow: str


THEME_PALETTES: dict[str, Palette] = {
    "sunrise": Palette("#ffc56d", "#ff4e8d", "#4e43f5", "#211827", "#fff8f2", "#ffffff"),
    "classic": Palette("#ff4d93", "#8e54ff", "#2447ff", "#1f1830", "#fff8f7", "#ffffff"),
    "aurora": Palette("#58f4d5", "#7b69ff", "#ff5da2", "#171b34", "#f8fffb", "#ffffff"),
    "arctic": Palette("#effcff", "#74d7ff", "#4f6cff", "#10213a", "#fbffff", "#ffffff"),
    "steel": Palette("#dbe5ee", "#8397b0", "#34445e", "#111820", "#f8fbff", "#ffffff"),
    "ultraviolet": Palette("#fa65ff", "#8d55ff", "#2c32ff", "#1b1231", "#fff7ff", "#ffffff"),
    "jade": Palette("#95ffd6", "#22c890", "#167577", "#102821", "#f7fff9", "#ffffff"),
    "ember": Palette("#ffd36f", "#ff744d", "#b42b57", "#2a1414", "#fff8ef", "#ffffff"),
    "graphite": Palette("#f3f4f6", "#8a909c", "#272c36", "#111318", "#ffffff", "#ffffff"),
}

THEME_NAMES: tuple[str, ...] = tuple(THEME_PALETTES)
PORTRAIT_NAMES: tuple[str, ...] = ("bun", "longhair", "pout", "breeze")

DEFAULT_PORTRAIT_LAYOUT: tuple[float, float, float] = (0.90, 0.03, 0.05)

PORTRAIT_LAYOUTS: dict[str, tuple[float, float, float]] = {
    "bun": (0.82, 0.02, -0.02),
    "longhair": (0.88, 0.02, -0.01),
    "pout": (0.96, -0.01, 0.02),
    "breeze": (0.86, 0.02, 0.05),
}

APPICON_SIZES: tuple[tuple[str, int], ...] = (
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
)


def hex_rgba(value: str, alpha: int = 255) -> tuple[int, int, int, int]:
    value = value.removeprefix("#")
    return (int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16), alpha)


def hex_rgb(value: str) -> tuple[int, int, int]:
    return hex_rgba(value)[:3]


def lerp_channel(a: int, b: int, t: float) -> int:
    return round(a * (1 - t) + b * t)


def lerp_rgb(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(lerp_channel(a[i], b[i], t) for i in range(3))


def srgb_channel_to_linear(value: int) -> float:
    c = value / 255
    if c <= 0.03928:
        return c / 12.92
    return ((c + 0.055) / 1.055) ** 2.4


def relative_luminance(rgb: tuple[int, int, int]) -> float:
    r, g, b = (srgb_channel_to_linear(channel) for channel in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast_ratio(a: tuple[int, int, int], b: tuple[int, int, int]) -> float:
    l1 = relative_luminance(a)
    l2 = relative_luminance(b)
    light, dark = max(l1, l2), min(l1, l2)
    return (light + 0.05) / (dark + 0.05)


def ensure_ink_contrast(
    rgb: tuple[int, int, int],
    background: tuple[int, int, int] = (248, 248, 246),
    minimum: float = 4.8,
) -> tuple[int, int, int]:
    """Darken bright theme colors until line art reads on the pale tile."""
    if contrast_ratio(rgb, background) >= minimum:
        return rgb

    anchor = (18, 24, 34)
    adjusted = rgb
    for step in range(1, 13):
        adjusted = lerp_rgb(rgb, anchor, step / 12)
        if contrast_ratio(adjusted, background) >= minimum:
            return adjusted
    return adjusted


def rounded_mask(size: int, inset: int = 88) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle(
        (inset, inset, size - inset, size - inset),
        radius=int(size * 0.21),
        fill=255,
    )
    return mask


def theme_ink_stops(palette: Palette) -> tuple[tuple[int, int, int], tuple[int, int, int], tuple[int, int, int]]:
    upper = ensure_ink_contrast(hex_rgb(palette.middle))
    middle = ensure_ink_contrast(lerp_rgb(hex_rgb(palette.middle), hex_rgb(palette.bottom), 0.42))
    lower = ensure_ink_contrast(hex_rgb(palette.bottom))
    return upper, middle, lower


def ink_gradient(size: int, palette: Palette, alpha: int = 255) -> Image.Image:
    upper, middle, lower = theme_ink_stops(palette)
    img = Image.new("RGBA", (size, size))
    draw = ImageDraw.Draw(img)
    for y in range(size):
        v = y / (size - 1)
        if v < 0.54:
            color = lerp_rgb(upper, middle, v / 0.54)
        else:
            color = lerp_rgb(middle, lower, (v - 0.54) / 0.46)
        draw.line((0, y, size, y), fill=(*color, alpha))

    # A very slight diagonal polish keeps the ink from looking flat without
    # returning to the previous translucent color-wash treatment.
    diagonal = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    diag_draw = ImageDraw.Draw(diagonal)
    highlight = lerp_rgb(upper, (255, 255, 255), 0.18)
    shadow = lerp_rgb(lower, (0, 0, 0), 0.18)
    diag_draw.polygon(
        [(0, 0), (int(size * 0.64), 0), (0, int(size * 0.46))],
        fill=(*highlight, 32),
    )
    diag_draw.polygon(
        [(size, size), (int(size * 0.32), size), (size, int(size * 0.44))],
        fill=(*shadow, 36),
    )
    return Image.alpha_composite(img, diagonal.filter(ImageFilter.GaussianBlur(size * 0.09)))


def gradient(size: int, palette: Palette) -> Image.Image:
    top = hex_rgba(palette.top)
    mid = hex_rgba(palette.middle)
    bottom = hex_rgba(palette.bottom)
    img = Image.new("RGBA", (size, size))
    draw = ImageDraw.Draw(img)
    for y in range(size):
        v = y / (size - 1)
        t = min(1.0, max(0.0, (v * 0.82) + 0.09))
        if t < 0.48:
            k = t / 0.48
            c0, c1 = top, mid
        else:
            k = (t - 0.48) / 0.52
            c0, c1 = mid, bottom
        color = tuple(round(c0[i] * (1 - k) + c1[i] * k) for i in range(4))
        draw.line((0, y, size, y), fill=color)
    diagonal = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    diag_draw = ImageDraw.Draw(diagonal)
    diag_draw.polygon([(0, size), (0, int(size * 0.45)), (int(size * 0.55), size)], fill=(*bottom[:3], 72))
    diag_draw.polygon([(size, 0), (int(size * 0.52), 0), (size, int(size * 0.42))], fill=(*top[:3], 64))
    img = Image.alpha_composite(img, diagonal.filter(ImageFilter.GaussianBlur(size * 0.16)))
    return img


def make_tile_background(size: int, palette: Palette) -> Image.Image:
    mask = rounded_mask(size)
    bg = Image.new("RGBA", (size, size), (248, 248, 246, 255))

    # Keep the tile mostly neutral. The theme belongs to the ink, with only a
    # whisper of color in the edge lighting.
    overlay = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    upper, _, lower = theme_ink_stops(palette)
    draw.ellipse(
        (int(size * 0.03), int(size * -0.10), int(size * 0.86), int(size * 0.58)),
        fill=(255, 255, 255, 82),
    )
    draw.ellipse(
        (int(size * -0.22), int(size * 0.46), int(size * 0.70), int(size * 1.12)),
        fill=(*upper, 14),
    )
    draw.ellipse(
        (int(size * 0.38), int(size * 0.54), int(size * 1.22), int(size * 1.16)),
        fill=(*lower, 12),
    )
    bg = Image.alpha_composite(bg, overlay.filter(ImageFilter.GaussianBlur(size * 0.07)))

    tile = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow = mask.filter(ImageFilter.GaussianBlur(size * 0.035))
    shadow_layer = Image.new("RGBA", (size, size), (20, 24, 34, 58))
    shadow_tile = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow_tile.alpha_composite(shadow_layer, (0, int(size * 0.035)))
    shadow_tile.putalpha(shadow)
    tile.alpha_composite(shadow_tile)

    clipped = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    clipped.alpha_composite(bg)
    clipped.putalpha(mask)
    tile.alpha_composite(clipped)

    rim = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    rim_draw = ImageDraw.Draw(rim)
    inset = int(size * 0.086)
    rim_draw.rounded_rectangle(
        (inset, inset, size - inset, size - inset),
        radius=int(size * 0.21),
        outline=(255, 255, 255, 112),
        width=max(1, size // 96),
    )
    inner = int(size * 0.096)
    rim_draw.rounded_rectangle(
        (inner, inner, size - inner, size - inner),
        radius=int(size * 0.20),
        outline=(*lower, 26),
        width=max(1, size // 180),
    )
    tile.alpha_composite(rim)
    return tile


def lineart_master_for(name: str) -> Path:
    portrait_name = portrait_name_for(name)
    lineart_masters = {
        "bun": BUN_LINEART_MASTER,
        "longhair": LONGHAIR_LINEART_MASTER,
        "pout": POUT_LINEART_MASTER,
        "breeze": BREEZE_LINEART_MASTER,
    }
    return lineart_masters.get(portrait_name, LINEART_MASTER)


def portrait_name_for(name: str) -> str:
    prefix = name.split("-", maxsplit=1)[0]
    return prefix if prefix in PORTRAIT_NAMES else "portrait"


def theme_name_for(name: str) -> str:
    if name in THEME_PALETTES:
        return name
    if name in PORTRAIT_NAMES:
        return "sunrise"
    _, _, theme_name = name.partition("-")
    if theme_name in THEME_PALETTES:
        return theme_name
    raise ValueError(f"Unknown app icon preset theme for {name!r}")


def preset_names() -> list[str]:
    names = list(THEME_NAMES)
    for portrait_name in PORTRAIT_NAMES:
        names.append(portrait_name)
        names.extend(f"{portrait_name}-{theme_name}" for theme_name in THEME_NAMES if theme_name != "sunrise")
    return names


def ensure_imageset(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    contents = path / "Contents.json"
    if not contents.exists():
        contents.write_text(
            '{\n'
            '  "images": [\n'
            '    {\n'
            '      "idiom": "universal",\n'
            '      "filename": "icon.png"\n'
            '    }\n'
            '  ],\n'
            '  "info": {\n'
            '    "author": "xcode",\n'
            '    "version": 1\n'
            '  }\n'
            '}',
            encoding="utf-8",
        )


@lru_cache(maxsize=1)
def source_photo() -> Image.Image:
    return ImageOps.fit(
        Image.open(SOURCE).convert("RGB"),
        (CANVAS, CANVAS),
        method=Image.Resampling.LANCZOS,
        centering=(0.5, 0.5),
    )


@lru_cache(maxsize=1)
def subject_region() -> Image.Image:
    # Fixed to the tracked source photo. Keeps the hair/face/neck/collar and
    # excludes most of the pale room background that would otherwise edge-noise.
    mask = Image.new("L", (CANVAS, CANVAS), 0)
    draw = ImageDraw.Draw(mask)
    draw.polygon(
        [
            (0, 1024), (0, 505), (38, 318), (120, 152), (292, 64),
            (540, 20), (760, 60), (900, 170), (1000, 365), (1024, 545),
            (940, 660), (835, 760), (828, 1024),
        ],
        fill=255,
    )
    draw.polygon(
        [(360, 1024), (482, 740), (760, 706), (910, 1024)],
        fill=255,
    )
    return mask.filter(ImageFilter.GaussianBlur(1.0))


def draw_smooth_line(
    draw: ImageDraw.ImageDraw,
    points: list[tuple[int, int]],
    fill: int,
    width: int,
    joint: str = "curve",
) -> None:
    draw.line(points, fill=fill, width=width, joint=joint)


def draw_lashes(draw: ImageDraw.ImageDraw, anchors: list[tuple[int, int]], length: int, fill: int, width: int) -> None:
    for x, y in anchors:
        draw.line((x, y, x + length, y - length * 2), fill=fill, width=width)


@lru_cache(maxsize=1)
def portrait_layers() -> tuple[Image.Image, Image.Image, Image.Image]:
    if LINEART_MASTER.exists():
        master = ImageOps.fit(
            Image.open(LINEART_MASTER).convert("RGB"),
            (CANVAS, CANVAS),
            method=Image.Resampling.LANCZOS,
            centering=(0.5, 0.5),
        )
        gray = ImageOps.grayscale(master)
        ink = gray.point(lambda p: 255 if p < 232 else (120 if p < 246 else 0))
        ink = ImageEnhance.Contrast(ink).enhance(1.2)
        ink = ink.filter(ImageFilter.GaussianBlur(0.18))

        # Remove any accidental model-created frame/corner marks. The portrait
        # itself is re-framed by compose_icon below.
        clean = Image.new("L", (CANVAS, CANVAS), 255)
        clean_draw = ImageDraw.Draw(clean)
        clean_draw.rectangle((0, 0, CANVAS, 42), fill=0)
        clean_draw.rectangle((0, CANVAS - 42, CANVAS, CANVAS), fill=0)
        clean_draw.rectangle((0, 0, 42, CANVAS), fill=0)
        clean_draw.rectangle((CANVAS - 42, 0, CANVAS, CANVAS), fill=0)
        ink = ImageChops.multiply(ink, clean.filter(ImageFilter.GaussianBlur(6)))

        # Keep the generated art as line art. A tiny white lift goes under the
        # portrait only for contrast on saturated presets, never as a filled
        # painted face shape.
        bust = ink.filter(ImageFilter.GaussianBlur(3)).point(lambda p: min(46, p // 8))
        return bust, ink, Image.new("L", (CANVAS, CANVAS), 0)

    # Hand-traced from design/app-icon-portrait/source-photo.png. This keeps
    # the original facial landmarks while avoiding the noise of bitmap edge
    # extraction. Draw at 2x and downsample for antialiasing.
    scale = 2
    s = CANVAS * scale
    bust = Image.new("L", (s, s), 0)
    ink = Image.new("L", (s, s), 0)
    cut = Image.new("L", (s, s), 0)
    bd = ImageDraw.Draw(bust)
    idr = ImageDraw.Draw(ink)
    cd = ImageDraw.Draw(cut)

    def pts(values: list[tuple[int, int]]) -> list[tuple[int, int]]:
        return [(x * scale, y * scale) for x, y in values]

    def line(values: list[tuple[int, int]], width: int, fill: int = 255) -> None:
        draw_smooth_line(idr, pts(values), fill, width * scale)

    # Skin/bust silhouette, kept pale in composition.
    bd.polygon(
        pts([
            (500, 120), (690, 76), (820, 118), (910, 230), (972, 392),
            (945, 508), (912, 570), (938, 604), (884, 684), (792, 746),
            (666, 746), (610, 716), (584, 812), (584, 1024), (964, 1024),
            (855, 824), (788, 744), (688, 735), (518, 690), (424, 610),
            (360, 520), (330, 420), (350, 288), (416, 178),
        ]),
        fill=255,
    )
    bd.polygon(pts([(0, 1024), (238, 910), (420, 898), (585, 1024)]), fill=255)

    # Hermes-like dark hair mass, following the real slicked-back hairline and ponytail.
    idr.polygon(
        pts([
            (0, 1024), (0, 468), (48, 292), (128, 160), (270, 78),
            (438, 38), (614, 38), (760, 82), (856, 152), (880, 218),
            (786, 158), (650, 126), (526, 166), (444, 250), (386, 362),
            (356, 500), (328, 676), (300, 860), (292, 1024),
        ]),
        fill=255,
    )
    idr.polygon(
        pts([(0, 1024), (0, 336), (96, 212), (214, 188), (304, 312), (298, 1024)]),
        fill=255,
    )

    # Remove a clean face/ear bite from the hair mass.
    cd.polygon(
        pts([
            (388, 276), (480, 214), (600, 170), (736, 166), (840, 224),
            (910, 342), (930, 486), (882, 618), (790, 704), (674, 724),
            (548, 668), (466, 566), (410, 440),
        ]),
        fill=255,
    )
    cd.ellipse(tuple(v * scale for v in (305, 394, 470, 570)), fill=255)
    ink.paste(0, mask=cut)

    # Hair strand highlights cut through the filled hair.
    for strand in [
        [(94, 190), (238, 112), (428, 74), (666, 92), (800, 154)],
        [(54, 292), (210, 178), (404, 116), (626, 118), (812, 190)],
        [(120, 430), (238, 292), (382, 190), (596, 158), (796, 212)],
        [(42, 650), (150, 430), (278, 268), (470, 178), (692, 170)],
        [(188, 990), (210, 710), (264, 500), (372, 310), (542, 204)],
    ]:
        draw_smooth_line(cd, pts(strand), 255, 5 * scale)
    ink.paste(0, mask=cut.filter(ImageFilter.GaussianBlur(0.3 * scale)))

    # Face contour: forehead, exact nose projection, lips, chin, and jaw.
    line([(784, 126), (842, 188), (900, 296), (918, 374), (965, 430), (925, 470)], 5)
    line([(925, 470), (890, 482), (918, 512), (900, 546)], 4)
    line([(898, 566), (938, 594), (884, 646), (816, 700), (728, 728), (640, 718)], 5)
    line([(640, 718), (560, 690), (496, 636), (448, 560)], 4)
    line([(608, 724), (596, 832), (596, 1024)], 5)
    line([(742, 734), (804, 846), (902, 1024)], 4)

    # Eye, lashes, brow, and under-eye plane.
    line([(586, 332), (642, 300), (724, 298), (786, 334), (730, 360), (640, 354), (586, 332)], 5)
    idr.ellipse(tuple(v * scale for v in (698, 306, 742, 356)), fill=255)
    draw_lashes(idr, pts([(752, 318), (768, 326), (782, 336)]), 10 * scale, 255, 3 * scale)
    draw_lashes(idr, pts([(618, 326), (604, 330)]), -7 * scale, 255, 2 * scale)
    line([(564, 268), (640, 238), (742, 242), (820, 276)], 7)
    line([(606, 390), (688, 404), (778, 392)], 2, fill=170)

    # Nose bridge, nostril, and cheek line.
    line([(828, 252), (874, 332), (894, 408)], 3)
    idr.ellipse(tuple(v * scale for v in (880, 450, 934, 484)), fill=255)
    line([(820, 500), (874, 492), (920, 506)], 3)
    line([(720, 512), (808, 504), (878, 532)], 2, fill=140)

    # Lips, preserving the resting slightly parted expression.
    line([(822, 560), (882, 548), (936, 570), (888, 586), (826, 578)], 5)
    line([(822, 604), (884, 620), (936, 598)], 4)
    line([(838, 588), (904, 590), (944, 580)], 2)

    # Ear and earring.
    line([(332, 412), (392, 382), (452, 420), (438, 510), (382, 558), (326, 520), (314, 460), (332, 412)], 5)
    line([(370, 430), (404, 458), (378, 498), (424, 504)], 3)
    line([(404, 544), (464, 544), (472, 618), (414, 624), (404, 544)], 6)
    line([(424, 564), (456, 566), (458, 604), (426, 604), (424, 564)], 3, fill=150)

    # Collar/shoulder hint.
    line([(0, 1006), (170, 944), (358, 902), (506, 904)], 4)
    line([(724, 934), (810, 874), (956, 1024)], 4)

    bust = bust.filter(ImageFilter.GaussianBlur(0.45 * scale)).resize((CANVAS, CANVAS), Image.Resampling.LANCZOS)
    ink = ink.filter(ImageFilter.GaussianBlur(0.20 * scale)).resize((CANVAS, CANVAS), Image.Resampling.LANCZOS)
    return bust, ink, cut.resize((CANVAS, CANVAS), Image.Resampling.LANCZOS)


def lineart_alpha(master: Image.Image, strengthen: float = 1.0) -> Image.Image:
    gray = ImageOps.grayscale(master.convert("RGB"))
    alpha = gray.point(lambda p: 0 if p >= 248 else min(255, round((248 - p) * 3.6 * strengthen)))
    alpha = ImageEnhance.Contrast(alpha).enhance(1.24)

    # Several generated masters include faint frame/corner artifacts. The app
    # icon supplies its own tile, so remove accidental edge marks here.
    clean = Image.new("L", alpha.size, 255)
    draw = ImageDraw.Draw(clean)
    inset = max(14, round(min(alpha.size) * 0.034))
    draw.rectangle((0, 0, alpha.width, inset), fill=0)
    draw.rectangle((0, alpha.height - inset, alpha.width, alpha.height), fill=0)
    draw.rectangle((0, 0, inset, alpha.height), fill=0)
    draw.rectangle((alpha.width - inset, 0, alpha.width, alpha.height), fill=0)
    alpha = ImageChops.multiply(alpha, clean.filter(ImageFilter.GaussianBlur(inset * 0.18)))
    return alpha.filter(ImageFilter.GaussianBlur(0.12))


def colored_lineart(mask: Image.Image, palette: Palette, strength: float = 1.0) -> Image.Image:
    alpha = mask
    if strength > 1.0:
        alpha = ImageEnhance.Contrast(alpha).enhance(strength)

    ink = ink_gradient(alpha.width, palette, alpha=255)
    ink.putalpha(alpha)

    support_alpha = alpha.filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.GaussianBlur(0.28))
    support_alpha = support_alpha.point(lambda p: min(78, round(p * 0.28)))
    _, _, lower = theme_ink_stops(palette)
    support = Image.new("RGBA", alpha.size, (*lerp_rgb(lower, (0, 0, 0), 0.12), 0))
    support.putalpha(support_alpha)

    return Image.alpha_composite(support, ink)


@lru_cache(maxsize=None)
def compose_icon(name: str, size: int = CANVAS, portrait_scale: float = 1.01) -> Image.Image:
    palette = THEME_PALETTES[theme_name_for(name)]
    base = make_tile_background(CANVAS, palette)
    master = ImageOps.fit(
        Image.open(lineart_master_for(name)).convert("RGB"),
        (CANVAS, CANVAS),
        method=Image.Resampling.LANCZOS,
        centering=(0.5, 0.5),
    )

    scale, x_offset, y_offset = PORTRAIT_LAYOUTS.get(portrait_name_for(name), DEFAULT_PORTRAIT_LAYOUT)
    portrait_size = int(CANVAS * scale)
    mask = lineart_alpha(master).resize((portrait_size, portrait_size), Image.Resampling.LANCZOS)
    portrait = colored_lineart(mask, palette, strength=1.12 if size <= LOGO else 1.0)
    offset = (
        (CANVAS - portrait_size) // 2 + int(CANVAS * x_offset),
        (CANVAS - portrait_size) // 2 + int(CANVAS * y_offset),
    )

    portrait_shell = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    portrait_shell.alpha_composite(portrait, offset)
    inner_mask = rounded_mask(CANVAS, inset=88)
    portrait_shell.putalpha(ImageChops.multiply(portrait_shell.getchannel("A"), inner_mask))
    base.alpha_composite(portrait_shell)

    clipped = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    clipped.alpha_composite(base)
    clipped.putalpha(base.getchannel("A"))
    if size != CANVAS:
        return clipped.resize((size, size), Image.Resampling.LANCZOS)
    return clipped


def compose_foreground_source() -> Image.Image:
    palette = THEME_PALETTES["sunrise"]
    master = ImageOps.fit(
        Image.open(lineart_master_for("sunrise")).convert("RGB"),
        (CANVAS, CANVAS),
        method=Image.Resampling.LANCZOS,
        centering=(0.5, 0.5),
    )
    return colored_lineart(lineart_alpha(master), palette, strength=1.08)


def write_assets() -> None:
    OUT_DESIGN.mkdir(parents=True, exist_ok=True)
    (OUT_DESIGN / "lineart-source-derived.png").parent.mkdir(parents=True, exist_ok=True)
    preview = compose_icon("sunrise")
    preview.save(OUT_DESIGN / "lineart-source-derived.png")

    for name in preset_names():
        icon = compose_icon(name)
        preset_dir = ASSETS / f"AppIconPreset-{name}.imageset"
        logo_dir = ASSETS / f"GlintLogo-{name}.imageset"
        ensure_imageset(preset_dir)
        ensure_imageset(logo_dir)
        icon.save(preset_dir / "icon.png")
        compose_icon(name, LOGO, portrait_scale=1.03).save(logo_dir / "icon.png")

    appicon_dir = ASSETS / "AppIcon.appiconset"
    default_icon = compose_icon("sunrise")
    for filename, pixels in APPICON_SIZES:
        default_icon.resize((pixels, pixels), Image.Resampling.LANCZOS).save(appicon_dir / filename)

    make_tile_background(CANVAS, THEME_PALETTES["sunrise"]).save(LIQUID / "background.png")
    compose_foreground_source().save(LIQUID / "foreground.png")


def contact_sheet() -> None:
    sizes = [1024, 512, 256, 128, 64, 32, 16]
    labels = preset_names()
    cell_w, cell_h = 170, 210
    sheet = Image.new("RGBA", (cell_w * len(labels), cell_h * len(sizes)), (246, 246, 246, 255))
    draw = ImageDraw.Draw(sheet)
    for row, size in enumerate(sizes):
        for col, name in enumerate(labels):
            icon = compose_icon(name, size=min(128, size))
            x = col * cell_w + (cell_w - icon.width) // 2
            y = row * cell_h + 38 + (128 - icon.height) // 2
            sheet.alpha_composite(icon, (x, y))
            draw.text((col * cell_w + 10, row * cell_h + 10), f"{name} {size}px", fill=(24, 24, 24, 255))
    sheet.save(OUT_DESIGN / "contact-sheet.png")


def main() -> None:
    write_assets()
    contact_sheet()
    print(f"Wrote portrait app icons from {SOURCE}")
    print(f"Wrote bun portrait app icon from {BUN_SOURCE}")
    print(f"Wrote longhair portrait app icon from {LONGHAIR_SOURCE}")
    print(f"Wrote pout portrait app icon from {POUT_SOURCE}")
    print(f"Wrote breeze portrait app icon from {BREEZE_SOURCE}")
    print(f"Wrote QA contact sheet to {OUT_DESIGN / 'contact-sheet.png'}")


if __name__ == "__main__":
    main()
