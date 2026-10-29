"""Regression checks for film selection and portable showcase recipes.

Run with the capture environment's Python:
python -m unittest discover -s .claude/skills/matrixcode-marketing-video/scripts -p test_marketing_video.py
"""

from __future__ import annotations

import base64
import contextlib
import io
import json
import subprocess
import unittest
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import capture_marketing_video as video


class FilmSelectionTests(unittest.TestCase):
    def test_existing_command_still_selects_first_film(self):
        arguments = video.parse_args([])
        self.assertEqual(arguments.video, "first")
        self.assertIsNone(arguments.out)
        self.assertEqual(arguments.output_dir, video.ROOT / "output/marketing")
        self.assertFalse(arguments.preview_only)

    def test_both_selection_keeps_previews_separate(self):
        destination = Path("/Volumes/DATA/Temp/video-selection-test")
        arguments = video.parse_args([
            "--video", "both", "--output-dir", str(destination), "--preview-only",
        ])
        outputs = video.resolve_outputs(arguments.video, arguments.output_dir, arguments.out)
        self.assertEqual([film.key for film, _ in outputs], ["first", "second"])
        self.assertEqual(outputs[0][1], destination / "matrixcode-styles.mp4")
        self.assertEqual(outputs[1][1], destination / "features/matrixcode-features.mp4")
        self.assertNotEqual(outputs[0][1].parent, outputs[1][1].parent)
        self.assertTrue(arguments.preview_only)

    def test_single_film_accepts_custom_output(self):
        custom_output = Path("/Volumes/DATA/Temp/custom-film/showcase.mp4")
        for selection in ("first", "second"):
            with self.subTest(selection=selection):
                outputs = video.resolve_outputs(selection, Path("unused"), custom_output)
                self.assertEqual(outputs, [(video.FILMS[selection], custom_output)])

    def test_both_rejects_ambiguous_single_output(self):
        with self.assertRaises(ValueError):
            video.resolve_outputs("both", Path("output"), Path("single.mp4"))

    def test_invalid_film_is_a_cli_error(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
            video.parse_args(["--video", "third"])
        self.assertEqual(error.exception.code, 2)

    def test_invalid_output_options_fail_before_rendering(self):
        for arguments in (
            ["--video", "both", "--out", "single.mp4"],
            ["--video", "second", "--out", "image.jpg"],
        ):
            with self.subTest(arguments=arguments), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    video.parse_args(arguments)
                self.assertEqual(error.exception.code, 2)


class RecipeTests(unittest.TestCase):
    def test_first_film_retains_original_timeline(self):
        film = video.FILMS["first"]
        self.assertEqual(film.duration, 36)
        self.assertEqual(film.transitions, [5, 9, 13, 17, 21, 27])
        self.assertEqual([scene.name for scene in film.scenes], [
            "classic", "blue", "amber", "purple", "columns", "non-overlapping", "invitation",
        ])

    def test_timing_is_derived_from_the_selected_recipe(self):
        for film in video.FILMS.values():
            with self.subTest(film=film.key):
                self.assertEqual(film.duration, 36)
                self.assertEqual(len(film.transitions), len(film.scenes) - 1)
                self.assertTrue(all(scene.seconds > video.TRANSITION for scene in film.scenes))
                longer = replace(film, scenes=(
                    replace(film.scenes[0], seconds=film.scenes[0].seconds + 1),
                    *film.scenes[1:],
                ))
                self.assertEqual(longer.duration, film.duration + 1)
                self.assertEqual(longer.transitions, [time + 1 for time in film.transitions])

    def test_both_films_share_the_original_closing_scene(self):
        closing = video.FILMS["first"].scenes[-1]
        self.assertIs(video.FILMS["second"].scenes[-1], closing)
        self.assertEqual(video.CTA, "Try it now!")
        self.assertEqual(closing.title, "Your Matrix Code. Your style.")
        self.assertEqual(closing.seconds, 9)
        self.assertEqual(closing.warmup, 3)
        self.assertEqual(closing.settings, {
            "preset": "classic", "density": 12, "size": 4.4,
            "glow": 1.3, "speed": 1.5, "trail": 0.24,
        })
        for film in video.FILMS.values():
            self.assertEqual([scene for scene in film.scenes if scene.message], [closing])

    def test_second_film_showcase_is_distinct_from_first(self):
        first_names = {scene.name for scene in video.FILMS["first"].scenes[:-1]}
        second_names = {scene.name for scene in video.FILMS["second"].scenes[:-1]}
        self.assertFalse(first_names & second_names)
        self.assertIn("images", second_names)
        self.assertIn("countdown", second_names)

    def test_overlap_comparison_changes_only_overlap_controls(self):
        comparison = next(scene for scene in video.FILMS["first"].scenes if scene.overlap_comparison)
        original, overlapping = video.scene_versions(comparison)
        self.assertIs(original, comparison)
        self.assertEqual(overlapping.settings, {**original.settings, "overlap": "true"})
        self.assertEqual(overlapping.seconds, original.seconds)
        self.assertEqual(overlapping.warmup, original.warmup)
        self.assertEqual(overlapping.documents, original.documents)

    def test_image_feature_uses_a_valid_portable_mask(self):
        scene = next(scene for scene in video.FILMS["second"].scenes if scene.name == "images")
        documents = video.scene_documents(scene)
        images = documents["mx-images"]
        self.assertTrue(images["enabled"])
        self.assertTrue(images["images"])
        self.assertFalse(scene.message)
        for mask in images["images"]:
            with self.subTest(mask=mask["name"]):
                self.assertGreater(mask["width"], 0)
                self.assertLessEqual(mask["width"], 96)
                self.assertGreater(mask["height"], 0)
                self.assertLessEqual(mask["height"], 96)
                pixels = base64.b64decode(mask["data"], validate=True)
                self.assertEqual(len(pixels), mask["width"] * mask["height"])
                self.assertGreater(max(pixels), min(pixels))

    def test_countdown_uses_real_tokens_without_invitation_finishing(self):
        scene = next(scene for scene in video.FILMS["second"].scenes if scene.name == "countdown")
        documents = video.scene_documents(scene)
        messages = documents["mx-messages"]
        self.assertFalse(scene.message)
        self.assertTrue(messages["enabled"])
        self.assertTrue(any("{countdown:" in message for message in messages["messages"]))
        self.assertNotIn(video.CTA, messages["messages"])
        moments = documents["mx-countdown"]["moments"]
        self.assertTrue(moments)
        for moment in moments:
            self.assertIsInstance(moment["targetMs"], (int, float))
            self.assertTrue(any(
                "{countdown:" + moment["name"] + "}" in message
                for message in messages["messages"]
            ))


class RenderSafetyTests(unittest.TestCase):
    def test_countdown_holds_through_preroll_and_recording(self):
        scene = next(scene for scene in video.SECOND_FILM.scenes if scene.name == "countdown")
        messages = video.scene_documents(scene)["mx-messages"]
        self.assertGreaterEqual(messages["persistenceMs"], (scene.warmup + scene.seconds) * 1000)

    def test_cli_reports_empty_message_failures_without_crashing(self):
        args = SimpleNamespace(
            video="second", output_dir=Path("/Volumes/DATA/Temp/test-films"), out=None,
            temp_dir=Path("/Volumes/DATA/Temp"), dist=Path("dist"), preview_only=False,
        )
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.ExitStack() as stack:
            stack.enter_context(contextlib.redirect_stdout(stdout))
            stack.enter_context(contextlib.redirect_stderr(stderr))
            stack.enter_context(mock.patch.object(video, "parse_args", return_value=args))
            stack.enter_context(mock.patch.object(Path, "mkdir"))
            stack.enter_context(mock.patch.object(Path, "open", mock.mock_open()))
            stack.enter_context(mock.patch.object(Path, "is_file", return_value=True))
            stack.enter_context(mock.patch.object(video.shutil, "which", return_value="available"))
            stack.enter_context(mock.patch.object(video, "sync_playwright", side_effect=StopIteration()))
            self.assertEqual(video.main(), 1)
        self.assertIn("fail [capture]", stderr.getvalue())
        self.assertNotIn("pass:", stdout.getvalue())

    def test_failed_encoded_verification_publishes_no_artifacts(self):
        film = video.FILMS["second"]
        output = Path("/Volumes/DATA/Temp/finished-film/matrixcode-features.mp4")
        args = SimpleNamespace(
            temp_dir=Path("/Volumes/DATA/Temp"), dist=Path("dist"), preview_only=False,
        )
        with contextlib.ExitStack() as stack:
            temporary = stack.enter_context(mock.patch.object(video.tempfile, "TemporaryDirectory"))
            temporary.return_value.__enter__.return_value = "/Volumes/DATA/Temp/fake-render"
            capture = stack.enter_context(mock.patch.object(video, "capture"))
            stack.enter_context(mock.patch.object(video, "contact_sheet"))
            copyfile = stack.enter_context(mock.patch.object(video.shutil, "copyfile"))
            soundtrack = stack.enter_context(mock.patch.object(video, "write_soundtrack"))
            stack.enter_context(mock.patch.object(video, "verify_soundtrack"))
            assemble = stack.enter_context(mock.patch.object(video, "assemble"))
            stack.enter_context(mock.patch.object(
                video, "verify_video", side_effect=RuntimeError("broken encoded stream"),
            ))
            mkdir = stack.enter_context(mock.patch.object(Path, "mkdir"))
            replace_file = stack.enter_context(mock.patch.object(Path, "replace"))
            with self.assertRaisesRegex(RuntimeError, "broken encoded stream"):
                video.render_film(object(), args, film, output)
            self.assertEqual(capture.call_count, len(film.scenes))
            soundtrack.assert_called_once_with(
                Path("/Volumes/DATA/Temp/fake-render/soundtrack.wav"), film.duration, film.transitions,
            )
            self.assertIs(assemble.call_args.args[-1], film)
            self.assertEqual(copyfile.call_count, 1)  # poster is copied within scratch space
            self.assertEqual(copyfile.call_args.args[-1].parent, Path("/Volumes/DATA/Temp/fake-render"))
            mkdir.assert_not_called()
            replace_file.assert_not_called()

    def test_wrong_frame_count_is_rejected_before_decode(self):
        film = video.FILMS["second"]
        probe = {"streams": [
            {"codec_type": "video", "codec_name": "h264", "width": video.SIZE[0],
             "height": video.SIZE[1], "r_frame_rate": f"{video.FPS}/1", "pix_fmt": "yuv420p",
             "duration": str(film.duration), "nb_frames": str(round(film.duration * video.FPS) - 1)},
            {"codec_type": "audio", "codec_name": "aac", "sample_rate": "48000", "channels": 2},
        ]}
        completed = subprocess.CompletedProcess([], 0, stdout=json.dumps(probe))
        with mock.patch.object(video.subprocess, "run", return_value=completed) as run:
            with self.assertRaisesRegex(RuntimeError, "Unexpected frame count"):
                video.verify_video(Path("film.mp4"), film, Path("last-frame.jpg"))
        run.assert_called_once()


if __name__ == "__main__":
    unittest.main()
