"""Feature showcases stay separate from the colour shorts and the long tours."""

from __future__ import annotations

import unittest
from pathlib import Path

from PIL import Image, ImageDraw

import capture_marketing_video as video
from marketing_film_showcase import SHOWCASE_CLIPS


class ShowcaseCatalogTests(unittest.TestCase):
    def test_four_feature_films_between_eight_and_twelve_seconds(self):
        self.assertEqual([film.key for film in SHOWCASE_CLIPS], [
            "showcase-story", "showcase-picture", "showcase-countdown", "showcase-light",
        ])
        self.assertEqual(video.FILM_GROUPS["showcase"], tuple(film.key for film in SHOWCASE_CLIPS))
        self.assertTrue(set(video.SHOWCASE_FILMS).isdisjoint(video.FILMS))
        for film in SHOWCASE_CLIPS:
            self.assertGreaterEqual(film.duration, 8)
            self.assertLessEqual(film.duration, 12)
            self.assertEqual(film.relative_output.parts[0], "showcase")
            self.assertNotIn(film.scenes[-1], (video.INVITATION,))
            for scene in film.scenes:
                self.assertTrue(scene.caption_top)
                self.assertFalse(scene.platform_labels)
                self.assertFalse(scene.message)
                self.assertGreaterEqual(scene.warmup, 12)
                video.message_layout(scene.settings["size"], scene.focus_text or "OK")

    def test_story_becomes_a_name_and_the_countdown_spans_the_clip(self):
        story, picture, countdown, light = SHOWCASE_CLIPS
        self.assertEqual(story.duration, 12)
        self.assertEqual([scene.name for scene in story.scenes], ["screensaver", "your-name"])
        self.assertEqual(story.scenes[1].documents["mx-messages"]["messages"], ["YOUR NAME"])
        self.assertEqual(picture.duration, 10)
        self.assertTrue(picture.scenes[0].documents["mx-images"]["enabled"])
        self.assertFalse(picture.scenes[0].documents["mx-images"]["brightnessFade"])
        self.assertEqual(countdown.duration, 10)
        self.assertEqual(light.duration, 8)
        moment = countdown.scenes[0].documents["mx-countdown"]["moments"][0]
        self.assertEqual(moment["targetMs"], video.CAPTURE_EPOCH_MS + 22_000)

    def test_caption_and_url_are_readable_on_the_first_frame(self):
        scene = SHOWCASE_CLIPS[0].scenes[0]
        opened = video.finish_frame(Image.new("RGB", video.SIZE, "black"), scene, 0)
        title = video.burn_top_caption(ImageDraw.Draw(Image.new("RGB", video.SIZE)), scene.title)
        url = video.burn_lower_url(ImageDraw.Draw(Image.new("RGB", video.SIZE)))
        self.assertGreaterEqual(title[0], 48)
        self.assertGreaterEqual(title[1], 48)
        self.assertLess(title[2], video.SIZE[0] - 48)
        self.assertLessEqual(url[3], video.SIZE[1] - video.TITLE_BOTTOM_MARGIN)
        self.assertGreaterEqual(url[1], title[3] + 24)
        title_ink = max(opened.getpixel((x, y))[0]
                        for y in range(title[1], title[3]) for x in range(title[0], title[2]))
        url_ink = max(opened.getpixel((x, y))[0]
                      for y in range(url[1], url[3]) for x in range(url[0], url[2]))
        self.assertGreater(title_ink, 180)
        self.assertGreater(url_ink, 180)
        outputs = video.resolve_outputs("showcase", Path("output/marketing"), None)
        self.assertEqual(len(outputs), 4)
        with self.assertRaises(ValueError):
            video.resolve_outputs("showcase", Path("output/marketing"), Path("one.mp4"))
