"""Generate Devin's real animated portrait icon family from frame strips.

Source strips:
  scripts/assets/devin-real-animated/strips/<state>.png

See:
  scripts/assets/devin-real-animated/README.md

Generates:
  - seven 128px transparent APNGs in Devin*.dataset folders
  - static 24px and 48px DevinMark PNGs
  - design/devin-real-animated/qa/contact-sheet.png for visual review

The source strips are AI-generated, hand-animation-style frame rows: the face,
eyes, brows, and mouth are redrawn per frame. This script only performs
deterministic production work: crop the green strip band, split frames, remove
the chroma background, normalize the portrait into the app canvas, and package
the existing asset names Glint already uses.

Usage:
  python3 scripts/generate_devin_portrait_icons.py

After regenerating, run:
  xcodebuild test -project Glint.xcodeproj -scheme Glint \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:GlintTests/MascotAssetTests
"""

from __future__ import annotations

from pathlib import Path
from typing import Iterable

from PIL import Image, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
ASSET_ROOT = ROOT / "Glint" / "Resources" / "Assets.xcassets"
RUN_ROOT = ROOT / "design" / "devin-real-animated"
STRIP_ROOT = ROOT / "scripts" / "assets" / "devin-real-animated" / "strips"
FRAME_ROOT = RUN_ROOT / "frames"
QA_ROOT = RUN_ROOT / "qa"

SIZE = 128
FPS_MS = 85
FRAMES = 8

STATES: dict[str, tuple[str, str]] = {
    "idle": ("DevinIdle", "devin-idle.png"),
    "thinking": ("DevinThinking", "devin-thinking.png"),
    "tool": ("DevinToolCall", "devin-tool-call.png"),
    "compressing": ("DevinCompressing", "devin-compressing.png"),
    "permission": ("DevinNeedsPermission", "devin-needs-permission.png"),
    "done": ("DevinDone", "devin-done.png"),
    "failed": ("DevinFailed", "devin-failed.png"),
}


def is_green_pixel(r: int, g: int, b: int) -> bool:
    return g > 140 and g > r * 1.45 and g > b * 1.45


def green_band_bbox(strip: Image.Image) -> tuple[int, int, int, int]:
    rgb = strip.convert("RGB")
    rows: list[int] = []
    cols: list[int] = []

    pixels = rgb.load()
    for y in range(rgb.height):
        green_count = 0
        for x in range(rgb.width):
            if is_green_pixel(*pixels[x, y]):
                green_count += 1
        if green_count >= rgb.width * 0.28:
            rows.append(y)

    if not rows:
        raise ValueError("Could not find the chroma-green animation band")

    y0, y1 = min(rows), max(rows) + 1
    for x in range(rgb.width):
        green_count = 0
        for y in range(y0, y1):
            if is_green_pixel(*pixels[x, y]):
                green_count += 1
        if green_count >= (y1 - y0) * 0.20:
            cols.append(x)

    if not cols:
        return (0, y0, rgb.width, y1)
    return (min(cols), y0, max(cols) + 1, y1)


def remove_green(frame: Image.Image) -> Image.Image:
    rgba = frame.convert("RGBA")
    px = rgba.load()

    for y in range(rgba.height):
        for x in range(rgba.width):
            r, g, b, a = px[x, y]
            if a == 0:
                continue

            if is_green_pixel(r, g, b):
                px[x, y] = (0, 0, 0, 0)
                continue

            # Despill pixels close to the matte edge without dulling skin.
            if g > max(r, b) + 18:
                g = max(r, b) + 8
            px[x, y] = (r, g, b, a)

    alpha = rgba.getchannel("A").filter(ImageFilter.GaussianBlur(0.25))
    rgba.putalpha(alpha)
    return rgba


def matte_frame(frame: Image.Image) -> Image.Image:
    frame = remove_green(frame)
    bbox = frame.getchannel("A").getbbox()
    if bbox is None:
        raise ValueError("Frame is empty after chroma removal")
    return frame


def normalize_frame(frame: Image.Image, bbox: tuple[int, int, int, int]) -> Image.Image:
    subject = frame.crop(bbox)
    subject.thumbnail((SIZE - 4, SIZE - 4), Image.Resampling.LANCZOS)

    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    x = (SIZE - subject.width) // 2
    y = max(0, (SIZE - subject.height) // 2 - 1)
    canvas.alpha_composite(subject, (x, y))
    return remove_small_alpha_components(canvas)


def remove_small_alpha_components(frame: Image.Image, min_pixels: int = 32) -> Image.Image:
    frame = frame.copy()
    alpha = frame.getchannel("A")
    width, height = alpha.size
    data = alpha.load()
    visited = [[False for _ in range(width)] for _ in range(height)]
    remove: list[tuple[int, int]] = []

    for y in range(height):
        for x in range(width):
            if visited[y][x] or data[x, y] <= 8:
                visited[y][x] = True
                continue

            stack = [(x, y)]
            component: list[tuple[int, int]] = []
            visited[y][x] = True

            while stack:
                cx, cy = stack.pop()
                component.append((cx, cy))
                for nx, ny in ((cx - 1, cy), (cx + 1, cy), (cx, cy - 1), (cx, cy + 1)):
                    if nx < 0 or ny < 0 or nx >= width or ny >= height:
                        continue
                    if visited[ny][nx]:
                        continue
                    visited[ny][nx] = True
                    if data[nx, ny] > 8:
                        stack.append((nx, ny))

            xs = [point[0] for point in component]
            ys = [point[1] for point in component]
            touches_side = min(xs) <= 1 or max(xs) >= width - 2
            bottom_seam = max(ys) >= height - 2 and (max(ys) - min(ys)) <= 3
            small_artifact = len(component) < min_pixels

            if small_artifact or (touches_side and len(component) < 2_000) or bottom_seam:
                remove.extend(component)

    px = frame.load()
    for x, y in remove:
        px[x, y] = (0, 0, 0, 0)
    return frame


def split_strip(path: Path) -> list[Image.Image]:
    strip = Image.open(path).convert("RGBA")
    band = strip.crop(green_band_bbox(strip))
    matted: list[Image.Image] = []
    rgb = band.convert("RGB")
    pixels = rgb.load()
    projection: list[int] = []

    for x in range(rgb.width):
        count = 0
        for y in range(rgb.height):
            r, g, b = pixels[x, y]
            if is_green_pixel(r, g, b):
                continue
            if r + g + b <= 36:
                continue
            count += 1
        projection.append(count)

    boundaries = [0]
    nominal_cell = band.width / FRAMES
    for index in range(1, FRAMES):
        expected = index * nominal_cell
        radius = nominal_cell * 0.32
        left = max(boundaries[-1] + 8, round(expected - radius))
        right = min(band.width - 8, round(expected + radius))
        if left >= right:
            boundary = round(expected)
        else:
            # Prefer a small green valley, but avoid single-column noise by
            # scoring a narrow neighborhood around each candidate boundary.
            def score(x: int) -> int:
                lo = max(0, x - 2)
                hi = min(len(projection), x + 3)
                return sum(projection[lo:hi])

            boundary = min(range(left, right), key=score)
        boundaries.append(boundary)
    boundaries.append(band.width)

    for index in range(FRAMES):
        left = boundaries[index]
        right = boundaries[index + 1]
        raw = band.crop((left, 0, right, band.height))
        matted.append(matte_frame(raw))

    boxes = [frame.getchannel("A").getbbox() for frame in matted]
    boxes = [box for box in boxes if box is not None]
    if not boxes:
        raise ValueError(f"No visible frames in strip: {path}")

    union = (
        min(box[0] for box in boxes),
        min(box[1] for box in boxes),
        max(box[2] for box in boxes),
        max(box[3] for box in boxes),
    )
    return [normalize_frame(frame, union) for frame in matted]


def shift_frame(frame: Image.Image, dx: int, dy: int) -> Image.Image:
    shifted = Image.new("RGBA", frame.size, (0, 0, 0, 0))
    shifted.alpha_composite(frame, (dx, dy))
    return shifted


def stabilize_frames(frames: list[Image.Image]) -> list[Image.Image]:
    boxes = [frame.getchannel("A").getbbox() for frame in frames]
    boxes = [box for box in boxes if box is not None]
    if not boxes:
        return frames

    centers_x = sorted((box[0] + box[2]) / 2 for box in boxes)
    centers_y = sorted((box[1] + box[3]) / 2 for box in boxes)
    target_x = centers_x[len(centers_x) // 2]
    target_y = centers_y[len(centers_y) // 2]

    stabilized: list[Image.Image] = []
    for frame in frames:
        box = frame.getchannel("A").getbbox()
        if box is None:
            stabilized.append(frame)
            continue
        cx = (box[0] + box[2]) / 2
        cy = (box[1] + box[3]) / 2
        stabilized.append(shift_frame(frame, round(target_x - cx), round(target_y - cy)))
    return stabilized


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


def write_dataset(asset_name: str, filename: str, frames: list[Image.Image]) -> None:
    ds = ASSET_ROOT / f"{asset_name}.dataset"
    save_apng(ds / filename, frames)
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


def write_frames(state: str, frames: list[Image.Image]) -> None:
    out = FRAME_ROOT / state
    out.mkdir(parents=True, exist_ok=True)
    for index, frame in enumerate(frames):
        frame.save(out / f"{index:02d}.png")


def write_mark(frames_by_state: dict[str, list[Image.Image]]) -> None:
    iset = ASSET_ROOT / "DevinMark.imageset"
    iset.mkdir(exist_ok=True)
    mark = frames_by_state["idle"][0]
    mark.resize((24, 24), Image.Resampling.LANCZOS).save(iset / "devin24.png")
    mark.resize((48, 48), Image.Resampling.LANCZOS).save(iset / "devin48.png")
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


def write_contact_sheet(frames_by_state: dict[str, list[Image.Image]]) -> None:
    QA_ROOT.mkdir(parents=True, exist_ok=True)
    cell = 160
    sheet = Image.new("RGBA", (cell * 4, cell * 2), (18, 18, 22, 255))
    d = ImageDraw.Draw(sheet, "RGBA")

    for idx, (name, frames) in enumerate(frames_by_state.items()):
        x = (idx % 4) * cell
        y = (idx // 4) * cell
        d.rounded_rectangle(
            (x + 12, y + 12, x + cell - 12, y + cell - 28),
            radius=10,
            fill=(255, 255, 255, 12),
        )
        sheet.alpha_composite(frames[len(frames) // 2], (x + 16, y + 8))
        d.text((x + 16, y + cell - 24), name, fill=(225, 225, 230, 255))

    sheet.save(QA_ROOT / "contact-sheet.png")


def write_previews(frames_by_state: dict[str, list[Image.Image]]) -> None:
    preview_dir = QA_ROOT / "previews"
    preview_dir.mkdir(parents=True, exist_ok=True)
    for state, frames in frames_by_state.items():
        frames[0].save(
            preview_dir / f"{state}.gif",
            save_all=True,
            append_images=frames[1:],
            duration=FPS_MS,
            loop=0,
            disposal=2,
            transparency=0,
        )


def main() -> None:
    frames_by_state: dict[str, list[Image.Image]] = {}

    for state, (asset, filename) in STATES.items():
        strip = STRIP_ROOT / f"{state}.png"
        if not strip.exists():
            raise FileNotFoundError(f"Missing generated strip: {strip}")
        frames = split_strip(strip)
        if state == "idle":
            frames = stabilize_frames(frames)
        frames_by_state[state] = frames
        write_frames(state, frames)
        write_dataset(asset, filename, frames)

    write_mark(frames_by_state)
    write_contact_sheet(frames_by_state)
    write_previews(frames_by_state)

    print(f"Wrote Devin real animated portrait assets from {STRIP_ROOT}")
    print(f"Contact sheet: {QA_ROOT / 'contact-sheet.png'}")
    print(f"Frame previews: {QA_ROOT / 'previews'}")


if __name__ == "__main__":
    main()
