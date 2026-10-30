"""The short social cuts stay separate from the 36-second tours."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from PIL import Image

import capture_marketing_video as video
from marketing_audio import write_soundtrack
from marketing_shorts import SHORT_CLIPS


class ShortCatalogTests(unittest.TestCase):
    def test_sixty_distinct_folders_between_six_and_ten_seconds(self):
        self.assertEqual(len(SHORT_CLIPS), 60)
        self.assertEqual(len({film.key for film in SHORT_CLIPS}), 60)
        parents = []
        looks = []
        for film in SHORT_CLIPS:
            self.assertEqual(len(film.scenes), 1)
            scene = film.scenes[0]
            self.assertGreaterEqual(scene.seconds, 6)
            self.assertLessEqual(scene.seconds, 10)
            self.assertEqual(scene.seconds, round(scene.seconds))
            self.assertTrue(scene.platform_labels)
            self.assertFalse(scene.message)
            self.assertFalse(scene.play_intro)
            self.assertGreaterEqual(scene.warmup, 22)
            self.assertGreaterEqual(scene.warmup * scene.settings["speed"], 22)
            self.assertEqual(film.transitions, [])
            self.assertEqual(film.relative_output.name, "matrixcode.mp4")
            self.assertEqual(film.relative_output.parts[0], "shorts")
            parents.append(film.relative_output.parent)
            looks.append((
                scene.settings.get("preset"), scene.settings.get("glyphs"), scene.settings.get("color"),
                scene.settings.get("density"), scene.settings.get("size"), scene.settings.get("overlap"),
            ))
            if scene.focus_text:
                self.assertIsNotNone(video.scene_focus_mask(scene).getbbox())
        self.assertEqual(len(set(parents)), 60)
        self.assertEqual(len(set(looks)), 60)
        signatures = {
            tuple(scene.settings.get(key) for key in ("density", "size", "speed", "trail", "glow"))
            for film in video.FILMS.values() for scene in film.scenes if not scene.message
        }
        for film in SHORT_CLIPS:
            signature = tuple(film.scenes[0].settings.get(key)
                              for key in ("density", "size", "speed", "trail", "glow"))
            self.assertIn(signature, signatures)
        self.assertGreaterEqual(sum(scene.documents is not None
                                    for film in SHORT_CLIPS for scene in film.scenes), 6)

    def test_paired_cuts_keep_the_long_film_controls(self):
        pairs = {
            "01-classic-green": ("first", "classic"),
            "02-blue-binary": ("first", "blue"),
            "03-amber-terminal": ("first", "amber"),
            "04-neon-purple": ("first", "purple"),
            "05-fine-columns": ("first", "columns"),
            "06-packed-columns": ("first", "non-overlapping"),
            "08-red-storm": ("second", "red"),
            "09-golden-slow": ("second", "gold"),
            "10-monochrome": ("second", "white"),
            "11-custom-teal": ("second", "teal"),
            "13-hello-alex": ("third", "your-name"),
            "21-moon": ("fifth", "moon"),
            "25-fuchsia": ("sixth", "fuchsia-circuit"),
            "31-olive": ("seventh", "olive-phosphor"),
            "37-jade": ("eighth", "atmosphere-jade"),
        }
        shorts = {film.key: film for film in SHORT_CLIPS}
        for key, (film_key, scene_name) in pairs.items():
            short = shorts[key].scenes[0].settings
            long = next(scene for scene in video.FILMS[film_key].scenes if scene.name == scene_name)
            for name, value in long.settings.items():
                if name == "ramp":
                    self.assertNotIn(name, short)
                else:
                    self.assertEqual(short[name], value, f"{key} {name}")

    def test_long_tours_stay_out_of_the_short_group(self):
        self.assertEqual(tuple(video.FILMS), (
            "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth",
        ))
        self.assertEqual(video.FILM_GROUPS["all"], tuple(video.FILMS))
        self.assertEqual(video.FILM_GROUPS["shorts"], tuple(film.key for film in SHORT_CLIPS))
        shorts = video.resolve_outputs("shorts", Path("output/marketing"), None)
        self.assertEqual(len(shorts), 60)
        self.assertEqual(len({path.parent for _, path in shorts}), 60)
        with self.assertRaises(ValueError):
            video.resolve_outputs("shorts", Path("output/marketing"), Path("one.mp4"))
        one = video.resolve_outputs(SHORT_CLIPS[0].key, Path("output/marketing"), None)
        self.assertEqual(one[0][1], Path("output/marketing/shorts") / SHORT_CLIPS[0].key / "matrixcode.mp4")

    def test_labels_use_the_long_film_title_face_and_baseline(self):
        self.assertEqual(video.PLATFORM_LABELS, ("browser", "screensaver", "both monitors"))
        labels = list(video.iter_platform_labels())
        self.assertEqual([label for label, _origin, _bounds in labels], list(video.PLATFORM_LABELS))
        _label, origin, bounds = labels[-1]
        self.assertEqual(origin, (video.TITLE_LEFT, video.SIZE[1] - video.TITLE_BOTTOM_MARGIN))
        for label, item_origin, box in labels:
            self.assertEqual(item_origin[0], video.TITLE_LEFT)
            self.assertGreater(box[1], video.SIZE[1] / 2)
            self.assertLessEqual(box[2], video.SIZE[0] - 60)
            self.assertLessEqual(box[3], video.SIZE[1] - 180)
            self.assertEqual(label, label.lower())
        for earlier, later in zip(labels, labels[1:]):
            self.assertLessEqual(earlier[2][3] + 4, later[2][1] + 4)

        short = SHORT_CLIPS[0].scenes[0]
        opened = video.finish_frame(Image.new("RGB", video.SIZE, "black"), short, 0)
        tour = video.FILMS["first"].scenes[0]
        self.assertFalse(tour.platform_labels)
        untouched = video.finish_frame(Image.new("RGB", video.SIZE, "black"), tour, 0)
        ink = max(max(pixel) for pixel in opened.crop(bounds).getdata())
        quiet = max(max(pixel) for pixel in untouched.crop(bounds).getdata())
        self.assertGreater(ink, quiet + 6)
        self.assertGreater(ink, 200)
        # No plate: the pixel just left of the title block stays black.
        self.assertEqual(opened.getpixel((bounds[0] - 8, (bounds[1] + bounds[3]) // 2)), (0, 0, 0))

    def test_short_score_matches_six_and_ten_second_cuts(self):
        for seconds in (6, 10):
            film = next(item for item in SHORT_CLIPS if item.duration == seconds)
            with tempfile.TemporaryDirectory() as directory:
                audio = Path(directory) / "score.wav"
                write_soundtrack(audio, film.duration, film.transitions)
                video.verify_soundtrack(audio, film)


if __name__ == "__main__":
    unittest.main()
