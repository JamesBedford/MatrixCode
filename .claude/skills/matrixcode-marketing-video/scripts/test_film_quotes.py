"""The looping quote reel stays out of the eight long tours."""

from __future__ import annotations

import unittest
from pathlib import Path

from PIL import Image, ImageDraw

import capture_marketing_video as video
from marketing_audio import write_soundtrack
from marketing_film_quotes import QUOTES_FILM
from marketing_model import CTA


class QuoteReelTests(unittest.TestCase):
    def test_reel_loops_on_the_shared_invitation_and_stays_out_of_the_long_tours(self):
        film = QUOTES_FILM
        self.assertEqual(film.key, "quotes")
        self.assertEqual(film.score, "matrix")
        self.assertEqual(film.duration, 36)
        self.assertEqual(film.relative_output, Path("quotes/matrixcode-quotes.mp4"))
        self.assertNotIn(film.key, video.FILMS)
        self.assertNotIn(film.key, video.FILM_GROUPS["all"])
        self.assertIs(video.CATALOG["quotes"], film)
        self.assertIs(film.scenes[-1], video.INVITATION)
        opening = film.scenes[0]
        self.assertTrue(opening.loop_open)
        self.assertFalse(opening.message)
        self.assertEqual(opening.documents["mx-messages"]["messages"], [CTA])
        self.assertEqual(opening.title, video.INVITATION.title)
        layout = video.message_layout(opening.settings["size"], CTA, opening.documents["mx-messages"])
        self.assertEqual(layout, video.MESSAGE_LAYOUT)
        # The opening also clears the rain cell above and below each word space.
        # The shared ending still clears only the spaces themselves.
        cols = layout["cols"]
        spaces = video.invitation_gap_cells()
        self.assertEqual(video.INVITATION_GAPS, spaces)
        self.assertEqual(video.scene_invitation_gaps(video.INVITATION), spaces)
        self.assertEqual(
            set(video.scene_invitation_gaps(opening)),
            {cell + delta * cols for cell in spaces for delta in (-1, 0, 1)},
        )
        # 120 BPM across 36 seconds lands on a downbeat, which is what the loop joins.
        self.assertEqual(film.duration * 120 / 60, 72)

    def test_each_quote_is_large_and_the_handle_sits_on_the_next_row(self):
        handles = []
        for scene in QUOTES_FILM.scenes[1:-1]:
            with self.subTest(scene=scene.name):
                self.assertFalse(scene.message)
                self.assertIsNotNone(scene.focus_text)
                quote = scene.focus_text
                for character in quote:
                    self.assertTrue(character == " " or video.message_glyph(character) is not None, character)
                document = video.scene_documents(scene)["mx-messages"]
                self.assertEqual(document["messages"], [quote])
                self.assertGreaterEqual(document["persistenceMs"], (scene.warmup + scene.seconds) * 1000)
                self.assertEqual(document["verticalJitter"], 0)
                self.assertEqual(document["horizontalJitter"], 0)
                stamp = video.credit_stamp(scene)
                self.assertIsNotNone(stamp)
                quote_layout = video.message_layout(scene.settings["size"], quote, document)
                quote_row = min(quote_layout["cells"]) // quote_layout["cols"]
                credit_rows = {cell // stamp["cols"] for cell, _glyph in stamp["cells"]}
                self.assertEqual(credit_rows, {quote_row + 2})
                hold_rows = {cell // stamp["cols"] for cell, _glyph in stamp["hold"]}
                self.assertEqual(hold_rows, {quote_row})
                self.assertGreaterEqual(quote_layout["cols"] - len(quote), 4)
                rendered = "".join(
                    video._MESSAGE_CHARS[glyph - video._MESSAGE_START]
                    for _cell, glyph in stamp["cells"]
                )
                self.assertEqual(rendered, scene.credit_line.replace(" ", ""))
                self.assertTrue(scene.credit_line.startswith("X: "))
                gap_rows = {cell // stamp["cols"] for cell in stamp["gaps"]}
                self.assertEqual(gap_rows, {quote_row, quote_row + 1, quote_row + 2})
                handles.append(scene.credit_line.removeprefix("X: "))
                mask = video.scene_focus_mask(scene)
                self.assertIsNotNone(mask.getbbox())
        self.assertEqual(handles, ["gdb", "davidvgilmore", "dhh", "brivael", "itsolelehmann"])

    def test_opening_title_is_fully_drawn_on_the_first_frame(self):
        scene = QUOTES_FILM.scenes[0]
        opened = video.finish_frame(Image.new("RGB", video.SIZE, "black"), scene, 0)
        probe = ImageDraw.Draw(Image.new("RGB", video.SIZE))
        title = tuple(int(value) for value in probe.textbbox(
            video.ENDING_TITLE_POSITION, scene.title, font=video.ENDING_TITLE_FONT, anchor="mm"))
        url = tuple(int(value) for value in probe.textbbox(
            video.ENDING_SITE_POSITION, video.SITE, font=video.ENDING_SITE_FONT, anchor="mm"))
        title_ink = max(opened.getpixel((x, y))[0]
                        for y in range(title[1], title[3]) for x in range(title[0], title[2]))
        url_ink = max(opened.getpixel((x, y))[0]
                      for y in range(url[1], url[3]) for x in range(url[0], url[2]))
        self.assertGreater(title_ink, 180)
        self.assertGreater(url_ink, 180)

    def test_style_titles_stay_in_the_player_safe_area(self):
        draw = ImageDraw.Draw(Image.new("RGB", video.SIZE))
        for scene in QUOTES_FILM.scenes:
            if scene.message or scene.loop_open:
                continue
            box = draw.textbbox((video.TITLE_LEFT, video.SIZE[1] - video.TITLE_BOTTOM_MARGIN),
                                scene.title, font=video.TITLE_FONT, anchor="lb")
            self.assertGreaterEqual(box[0], 60)
            self.assertLessEqual(box[2], video.SIZE[0] - 60)
            self.assertLessEqual(box[3], video.SIZE[1] - 180)

    def test_matrix_score_loops_without_clipping_and_is_not_the_shared_score(self):
        film = QUOTES_FILM
        directory = Path("/Volumes/DATA/Temp/matrixcode-quote-score")
        directory.mkdir(parents=True, exist_ok=True)
        first = directory / "matrix-a.wav"
        second = directory / "matrix-b.wav"
        write_soundtrack(first, film.duration, film.transitions, score="matrix")
        write_soundtrack(second, film.duration, film.transitions, score="matrix")
        self.assertEqual(first.read_bytes(), second.read_bytes())
        import wave
        import numpy as np
        with wave.open(str(first), "rb") as source:
            self.assertEqual(
                (source.getnchannels(), source.getsampwidth(), source.getframerate(), source.getnframes()),
                (2, 2, 48000, round(film.duration * 48000)),
            )
            pcm = np.frombuffer(source.readframes(source.getnframes()), dtype="<i2").astype(np.float64)
        peak = float(np.max(np.abs(pcm)))
        self.assertGreater(peak, 0.5 * 32767)
        self.assertLessEqual(peak, round(0.87 * 32767))
        # The join is quiet enough to avoid a click, and the body stays loud.
        self.assertLess(abs(float(pcm[0])), 800)
        self.assertLess(abs(float(pcm[-1])), 800)
        midpoint = pcm[len(pcm) // 2: len(pcm) // 2 + 48000]
        self.assertGreater(float(np.sqrt(np.mean(midpoint ** 2))), 2000)
        shared = directory / "industrial.wav"
        write_soundtrack(shared, film.duration, film.transitions)
        self.assertNotEqual(shared.read_bytes(), first.read_bytes())
