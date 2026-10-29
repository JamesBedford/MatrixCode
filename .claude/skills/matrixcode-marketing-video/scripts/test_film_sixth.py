"""Checks that Neon Nights stays a varied style showcase with the shared ending."""

import unittest

from marketing_film_sixth import SIXTH_FILM
from marketing_model import INVITATION


class SixthFilmTests(unittest.TestCase):
    def test_body_contains_only_ordinary_rain_styles(self):
        for scene in SIXTH_FILM.scenes[:-1]:
            with self.subTest(scene=scene.name):
                self.assertIsNone(scene.documents)
                self.assertIsNone(scene.focus_text)
                self.assertFalse(scene.message)
                self.assertFalse(scene.play_intro)
                self.assertFalse(scene.start_images_after_warmup)
                self.assertFalse(scene.actions)
                self.assertFalse(scene.overlap_comparison)
                self.assertIsNone(scene.comparison_settings)

    def test_styles_vary_palette_glyphs_scale_and_motion(self):
        styles = [scene.settings for scene in SIXTH_FILM.scenes[:-1]]
        self.assertEqual(len({style["color"] for style in styles}), 6)
        self.assertGreaterEqual(len({style["glyphs"] for style in styles}), 5)
        self.assertGreaterEqual(len({style["font"] for style in styles}), 4)
        self.assertLess(min(style["size"] for style in styles), 1)
        self.assertGreater(max(style["size"] for style in styles), 2)
        self.assertGreater(max(style["speed"] for style in styles), 2)
        self.assertLess(min(style["speed"] for style in styles), 1)

    def test_shared_ending_and_standard_duration(self):
        self.assertIs(SIXTH_FILM.scenes[-1], INVITATION)
        self.assertEqual(SIXTH_FILM.duration, 36)
        self.assertEqual(SIXTH_FILM.transitions[-1], 27)
        self.assertEqual(str(SIXTH_FILM.relative_output), "styles/neon/matrixcode-neon.mp4")


if __name__ == "__main__":
    unittest.main()
