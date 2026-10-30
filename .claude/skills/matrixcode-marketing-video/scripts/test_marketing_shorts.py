"""The short social cuts stay separate from the 36-second tours."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from PIL import Image, ImageDraw

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
            looks.append((scene.settings["preset"], scene.settings["glyphs"], scene.settings.get("color")))
        self.assertEqual(len(set(parents)), 60)
        self.assertEqual(len(set(looks)), 60)

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

    def test_labels_are_burned_in_on_the_first_frame_and_clear_the_player(self):
        self.assertEqual(video.PLATFORM_LABELS, ("browser", "screensaver", "both monitors"))
        draw = ImageDraw.Draw(Image.new("RGB", video.SIZE))
        url_box = draw.textbbox(video.CORNER_SITE_POSITION, video.SITE, font=video.SITE_FONT, anchor="ra")
        plates = []
        for label, _origin, plate in video.iter_platform_labels():
            self.assertIn(label, video.PLATFORM_LABELS)
            self.assertGreaterEqual(plate[0], 48)
            self.assertGreaterEqual(plate[1], 48)
            self.assertLess(plate[2], url_box[0] - 24)
            self.assertLessEqual(plate[3], video.SIZE[1] - video.TITLE_BOTTOM_MARGIN)
            plates.append(plate)
        self.assertEqual(len(plates), 3)
        for earlier, later in zip(plates, plates[1:]):
            self.assertGreaterEqual(later[1], earlier[3] + 8)

        short = SHORT_CLIPS[0].scenes[0]
        blank = Image.new("RGBA", video.SIZE, (0, 0, 0, 0))
        burn = ImageDraw.Draw(blank)
        video.burn_platform_labels(burn)
        sample = ((plates[0][0] + plates[0][2]) // 2, (plates[0][1] + plates[0][3]) // 2)
        self.assertGreater(blank.getpixel(sample)[3], 150)
        self.assertEqual(blank.getpixel((plates[0][2] + 12, plates[0][1] + 4))[3], 0)

        plate_corner = (plates[0][0] + 3, plates[0][1] + 3)
        opened = video.finish_frame(Image.new("RGB", video.SIZE, "black"), short, 0)
        tour = video.FILMS["first"].scenes[0]
        self.assertFalse(tour.platform_labels)
        untouched = video.finish_frame(Image.new("RGB", video.SIZE, "black"), tour, 0)
        # Labels are present on the opening frame. The long tour does not paint that plate.
        self.assertGreater(max(opened.getpixel(plate_corner)), max(untouched.getpixel(plate_corner)) + 6)

    def test_short_score_matches_six_and_ten_second_cuts(self):
        for seconds in (6, 10):
            film = next(item for item in SHORT_CLIPS if item.duration == seconds)
            with tempfile.TemporaryDirectory() as directory:
                audio = Path(directory) / "score.wav"
                write_soundtrack(audio, film.duration, film.transitions)
                video.verify_soundtrack(audio, film)


if __name__ == "__main__":
    unittest.main()
