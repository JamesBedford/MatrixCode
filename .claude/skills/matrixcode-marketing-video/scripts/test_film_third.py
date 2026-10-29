"""Checks for the third film's real message and token demonstration inputs."""

import unittest

from marketing_film_third import THIRD_FILM
from marketing_model import CAPTURE_EPOCH_MS, INVITATION


class ThirdFilmTests(unittest.TestCase):
    def test_personalisation_and_live_tokens_have_real_inputs(self):
        scenes = {scene.name: scene for scene in THIRD_FILM.scenes}
        self.assertEqual(scenes["your-name"].settings["name"], "ALEX")
        self.assertEqual(scenes["your-name"].documents["mx-messages"]["messages"], ["HELLO {name}"])
        self.assertIn("{time:%H:%M:%S}", scenes["live-clock"].documents["mx-messages"]["messages"])
        counter = scenes["count-up"]
        self.assertIn("{countup:Session}", counter.documents["mx-messages"]["messages"][0])
        moment = counter.documents["mx-countdown"]["moments"][0]
        self.assertEqual(moment["name"], "Session")
        self.assertLess(moment["targetMs"], CAPTURE_EPOCH_MS)

    def test_feature_messages_are_readable_through_the_entire_shot(self):
        for scene in THIRD_FILM.scenes[:-1]:
            with self.subTest(scene=scene.name):
                document = scene.documents["mx-messages"]
                self.assertTrue(document["enabled"])
                self.assertFalse(scene.message)
                self.assertTrue(scene.focus_text)
                self.assertGreaterEqual(document["persistenceMs"], (scene.warmup + scene.seconds) * 1000)
                self.assertEqual(document["horizontalJitter"], 0)
                self.assertEqual(document["verticalJitter"], 0)

    def test_vertical_and_noncentral_placements_are_demonstrated(self):
        messages = [scene.documents["mx-messages"] for scene in THIRD_FILM.scenes[:-1]]
        self.assertTrue(any(document["messageLayout"] == "drop" for document in messages))
        self.assertTrue(any(
            document["horizontalPosition"] < 0.5 and document["verticalPosition"] < 0.5
            for document in messages
        ))

    def test_original_ending_and_export_length_are_preserved(self):
        self.assertIs(THIRD_FILM.scenes[-1], INVITATION)
        self.assertEqual(THIRD_FILM.duration, 36)
        self.assertEqual(THIRD_FILM.transitions[-1], 27)


if __name__ == "__main__":
    unittest.main()
