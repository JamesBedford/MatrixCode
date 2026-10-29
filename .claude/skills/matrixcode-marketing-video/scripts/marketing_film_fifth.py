"""Image-driven showcase captured through Matrix Code's ordinary reveal scheduler."""

from __future__ import annotations

import base64
import math
from pathlib import Path

from PIL import Image, ImageDraw

from marketing_model import Film, INVITATION, Scene

# A nonblack floor lets the image shader darken rain around each bright subject.
MASK_BACKGROUND = 60
MASK_RESOLUTION = 96
ART_SCALE = 4
IMAGE_RAIN = {
    "glyphs": "latin", "font": "mono", "mirror": "false", "density": 25,
    "size": 0.65, "trail": 0.4, "lead": 0, "glow": 0.3, "speed": 1.1,
}


def portable_mask(name: str, artwork: Image.Image, height: int = MASK_RESOLUTION) -> dict:
    mask = artwork.convert("L").resize((MASK_RESOLUTION, height), Image.Resampling.LANCZOS)
    return {"name": name, "width": mask.width, "height": mask.height,
            "data": base64.b64encode(mask.tobytes()).decode("ascii")}


def moon_mask() -> dict:
    """An illuminated sphere with broad craters and a restrained greyscale ramp."""
    side = MASK_RESOLUTION * ART_SCALE
    artwork = Image.new("L", (side, side), MASK_BACKGROUND)
    pixels = artwork.load()
    radius = side * 0.41
    center = side / 2
    for y in range(side):
        for x in range(side):
            nx, ny = (x - center) / radius, (y - center) / radius
            distance = nx * nx + ny * ny
            if distance <= 1:
                normal = math.sqrt(1 - distance)
                light = max(0, min(1, 0.48 * nx - 0.3 * ny + 0.82 * normal))
                pixels[x, y] = round(205 + 50 * light)
    draw = ImageDraw.Draw(artwork)
    for box, shade in (((110, 116, 171, 166), 132), ((225, 195, 273, 239), 155),
                       ((155, 249, 190, 279), 165), ((241, 103, 271, 130), 175)):
        draw.ellipse(box, fill=shade)
        draw.arc(box, 190, 300, fill=245, width=6)
    return portable_mask("Crater moon", artwork)


def skyline_mask() -> dict:
    """A wide, original skyline with large shapes that survive a small player."""
    artwork = Image.new("L", (384, 192), MASK_BACKGROUND)
    draw = ImageDraw.Draw(artwork)
    buildings = ((12, 111, 45, 177), (50, 82, 85, 177), (91, 115, 119, 177),
                 (126, 54, 163, 177), (169, 90, 203, 177), (211, 34, 246, 177),
                 (253, 74, 287, 177), (294, 103, 325, 177), (332, 64, 371, 177))
    draw.rectangle((8, 176, 376, 182), fill=245)
    for index, box in enumerate(buildings):
        draw.rectangle(box, fill=225 + index % 3 * 15)
        left, top, right, bottom = box
        for y in range(top + 13, bottom - 7, 21):
            for x in range(left + 8, right - 4, 15):
                draw.rectangle((x, y, x + 5, y + 8), fill=80)
    draw.line((144, 25, 144, 54), fill=245, width=6)
    draw.line((228, 13, 228, 35), fill=255, width=6)
    return portable_mask("Night skyline", artwork, 48)


def orbit_mask() -> dict:
    """A ringed planet whose wide silhouette makes image scale and drift legible."""
    artwork = Image.new("L", (384, 256), MASK_BACKGROUND)
    draw = ImageDraw.Draw(artwork)
    ring = (20, 76, 364, 184)
    draw.ellipse(ring, outline=230, width=14)
    draw.ellipse((113, 43, 271, 201), fill=245)
    draw.arc((128, 55, 249, 182), 95, 255, fill=170, width=17)
    draw.arc(ring, 0, 180, fill=255, width=17)
    return portable_mask("Ringed planet", artwork, 64)


MOON = moon_mask()
SKYLINE = skyline_mask()
ORBIT = orbit_mask()


def image_scene(name: str, title: str, seconds: float, images: tuple[dict, ...],
                *, settings: dict | None = None, preview: float = 3,
                **image_settings) -> Scene:
    document = {
        "images": list(images), "enabled": True, "frequencyMs": 500,
        "persistenceMs": 10000, "appearMs": 1200, "disappearMs": 0,
        "flickerOut": True, "brightnessFade": False,
        "imageScale": 0.72, "imagePlacementJitter": 0,
        **image_settings,
    }
    return Scene(name, title, seconds, {**IMAGE_RAIN, **(settings or {})},
                 documents={"mx-images": document}, preview_seconds=preview,
                 start_images_after_warmup=True)


FIFTH_FILM = Film("fifth", "Matrix Code — Images in motion", (
    image_scene("moon", "Shades become code", 5.5, (MOON,),
                settings={"preset": "white", "size": 1}, preview=4),
    image_scene("panorama", "Bring a panorama", 4.5, (SKYLINE,),
                settings={"preset": "gold", "speed": 0.9, "size": 0.9}, imageScale=0.88),
    image_scene("image-scale", "Choose the scale", 4.5, (ORBIT,),
                settings={"preset": "blue", "glyphs": "digits", "size": 0.9},
                imageScale=0.34, appearMs=700),
    image_scene("image-drift", "Let images drift", 4.5, (ORBIT,),
                settings={"preset": "custom", "color": "#B9FF37", "speed": 1.4, "size": 0.9},
                imageScale=0.34, imagePlacementJitter=1, appearMs=300,
                persistenceMs=650, disappearMs=300, preview=3),
    image_scene("image-fade", "Soft brightness fades", 5.5, (MOON,),
                settings={"preset": "purple", "glow": 0.65, "size": 1},
                appearMs=1000, persistenceMs=800, disappearMs=1000,
                flickerOut=False, brightnessFade=True, preview=1.8),
    image_scene("image-playlist", "Build an image playlist", 5.5, (MOON, SKYLINE, ORBIT),
                settings={"preset": "classic", "density": 30, "glow": 0.45, "size": 0.9},
                imageScale=0.6, appearMs=400, persistenceMs=650,
                disappearMs=400, preview=3),
    INVITATION,
), Path("images/matrixcode-images.mp4"))
