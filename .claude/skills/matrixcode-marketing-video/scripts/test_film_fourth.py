"""Protect the time needed to see each choreography control work on screen."""

import unittest

from marketing_film_fourth import FOURTH_FILM


def intro_duration_ms(scene):
    intro = scene.documents["mx-intro"]
    return (intro["startDelayMs"] + intro["fadeOutMs"]
            + sum(len(line["text"]) * intro["charMs"] + line["holdMs"]
                  for line in intro["lines"])
            + sum(line["pauseMs"] for line in intro["lines"][:-1]))


class ChoreographyTimingTests(unittest.TestCase):
    def scene(self, name):
        return next(scene for scene in FOURTH_FILM.scenes if scene.name == name)

    def test_after_intro_leaves_time_for_the_rain(self):
        scene = self.scene("opening-before-rain")
        end_ms = intro_duration_ms(scene) + scene.documents["mx-intro"]["postIntroDelayMs"]
        self.assertLessEqual(end_ms, (scene.seconds - 1) * 1000)
        self.assertLessEqual(end_ms + scene.settings["ramp"], scene.seconds * 1000)

    def test_pause_has_visible_movement_on_both_sides(self):
        scene = self.scene("pause-and-resume")
        pause, resume = scene.actions
        self.assertEqual((pause[1], resume[1]), ("P", "P"))
        self.assertGreaterEqual(pause[0], 1)
        self.assertGreaterEqual(resume[0] - pause[0], 1)
        self.assertLessEqual(resume[0], scene.seconds - 1)

    def test_skip_key_interrupts_a_still_playing_intro(self):
        scene = self.scene("skip-opening")
        skip_at, key = scene.actions[0]
        self.assertEqual(key, "Escape")
        self.assertGreater(intro_duration_ms(scene), scene.seconds * 1000)
        self.assertLess(skip_at, scene.seconds - 2)


if __name__ == "__main__":
    unittest.main()
