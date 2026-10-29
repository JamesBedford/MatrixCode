"""Keep the phosphor showcase focused on rain styles before its shared ending."""

import unittest

from marketing_film_seventh import SEVENTH_FILM


class PhosphorRecipeTests(unittest.TestCase):
    def test_body_scenes_have_no_functionality_demonstrations(self):
        for scene in SEVENTH_FILM.scenes[:-1]:
            with self.subTest(style=scene.name):
                self.assertIsNone(scene.documents)
                self.assertFalse(scene.play_intro)
                self.assertFalse(scene.message)
                self.assertFalse(scene.actions)
                self.assertFalse(scene.overlap_comparison)
                self.assertIsNone(scene.comparison_settings)
                self.assertIsNone(scene.comparison_title)
                self.assertIsNone(scene.focus_text)
                self.assertFalse(scene.start_images_after_warmup)
                self.assertEqual(scene.settings.get("ramp", 0), 0)
                self.assertGreater(scene.warmup, 0)


if __name__ == "__main__":
    unittest.main()
