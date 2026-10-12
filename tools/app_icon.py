"""Draw Portal's app icon: a bold white doorway on a blue-violet gradient.

    uv run --with pillow python tools/app_icon.py

Writes ios/Portal/Assets.xcassets/AppIcon.appiconset/AppIcon.png (1024 px,
opaque, as iOS wants). The doorway is pure white and carries the whole
shape, so the icon still reads when iOS renders it tinted (which drops
colour).
"""
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SIZE = 1024
SCALE = 4  # drawn large and scaled down, for smooth edges
OUT = Path(__file__).resolve().parent.parent / "ios/Portal/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

TOP_LEFT = (74, 64, 214)  # violet
BOTTOM_RIGHT = (38, 170, 226)  # the wrist's sky blue, deeper


def solid(colour, size: int) -> Image.Image:
    return Image.new("RGBA", (size, size), colour)


def gradient(size: int) -> Image.Image:
    """A diagonal gradient from top left to bottom right"""
    down = Image.linear_gradient("L").resize((size, size))
    across = down.transpose(Image.Transpose.TRANSPOSE)
    mask = ImageChops.add(down, across, scale=2.0)
    return Image.composite(solid(BOTTOM_RIGHT, size), solid(TOP_LEFT, size), mask)


def arch(size: int, box: tuple[float, float, float, float], foot: float) -> Image.Image:
    """A doorway: fully rounded at the top, nearly square at the foot"""
    left, top, right, bottom = box
    radius = (right - left) / 2
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.ellipse((left, top, right, top + 2 * radius), fill=255)
    draw.rounded_rectangle((left, top + radius, right, bottom), radius=foot, fill=255)
    draw.rectangle((left, top + radius, right, bottom - foot), fill=255)
    return mask


def main() -> None:
    big = SIZE * SCALE
    icon = gradient(big)
    width, height, thickness = 500 * SCALE, 640 * SCALE, 92 * SCALE
    left, top = (big - width) / 2, (big - height) / 2
    outer = arch(big, (left, top, left + width, top + height), 48 * SCALE)
    inner = arch(big, (left + thickness, top + thickness, left + width - thickness, top + height - thickness), 8 * SCALE)
    frame = ImageChops.subtract(outer, inner)

    # The light coming through, brightest at the foot
    light = ImageChops.multiply(inner, Image.linear_gradient("L").resize((big, big)))
    light = ImageChops.multiply(light.filter(ImageFilter.GaussianBlur(40 * SCALE)), Image.new("L", (big, big), 150))
    icon = Image.composite(solid((255, 255, 255, 255), big), icon, light)

    # A soft shadow under the frame, for depth
    shadow = Image.new("L", (big, big), 0)
    shadow.paste(frame.filter(ImageFilter.GaussianBlur(26 * SCALE)), (0, 18 * SCALE))
    shadow = ImageChops.multiply(shadow, Image.new("L", (big, big), 80))
    icon = Image.composite(solid((16, 20, 60, 255), big), icon, shadow)

    icon = Image.composite(solid((255, 255, 255, 255), big), icon, frame)
    icon = icon.resize((SIZE, SIZE), Image.LANCZOS).convert("RGB")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    icon.save(OUT)
    print(f"Wrote {OUT}")


if __name__ == "__main__":
    main()
