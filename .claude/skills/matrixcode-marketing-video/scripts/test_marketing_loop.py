"""Contract and encoded seam checks for the silent, uncaptioned rain loop."""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from PIL import Image

import capture_marketing_video as video
from marketing_film_loop import CLASSIC_LOOP_FILM
from marketing_model import Film, Scene


class ClassicLoopTests(unittest.TestCase):
    def test_recipe_is_thirty_seconds_of_green_rain_without_text_or_sound(self):
        film = CLASSIC_LOOP_FILM
        self.assertIs(video.CATALOG["classic-loop"], film)
        self.assertNotIn(film.key, video.FILMS)
        self.assertNotIn(film.key, video.FILM_GROUPS["all"])
        self.assertEqual(film.duration, 30)
        self.assertEqual(film.loop_overlap, 2)
        self.assertIsNone(film.score)
        self.assertEqual(len(film.scenes), 1)
        scene = film.scenes[0]
        self.assertEqual(scene.seconds, 32)
        self.assertEqual(scene.settings["preset"], "classic")
        self.assertFalse(scene.overlays)
        self.assertFalse(scene.message)
        self.assertFalse(scene.play_intro)
        self.assertFalse(scene.actions)
        for key in ("mx-intro", "mx-messages", "mx-images"):
            self.assertFalse(video.scene_documents(scene)[key]["enabled"])
        self.assertEqual(video.resolve_outputs("classic-loop", Path("output"), None),
                         [(film, Path("output") / film.relative_output)])

    def test_clean_frames_preserve_all_original_pixels(self):
        frame = Image.new("RGBA", video.SIZE, (9, 83, 24, 255))
        frame.putpixel((23, 17), (255, 1, 123, 255))
        result = video.finish_frame(frame, CLASSIC_LOOP_FILM.scenes[0], 1.5)
        self.assertEqual(result.mode, "RGB")
        self.assertEqual(result.tobytes(), frame.convert("RGB").tobytes())

    def test_silent_video_verification_rejects_an_audio_stream(self):
        streams = [
            {"codec_type": "video", "codec_name": "h264", "width": video.SIZE[0],
             "height": video.SIZE[1], "r_frame_rate": "30/1", "pix_fmt": "yuv420p",
             "duration": "30", "nb_frames": "900"},
            {"codec_type": "audio", "codec_name": "aac", "sample_rate": "48000",
             "channels": 2},
        ]
        probe = SimpleNamespace(returncode=0, stdout=json.dumps({"streams": streams}))
        with mock.patch.object(video.subprocess, "run", return_value=probe) as run:
            with self.assertRaisesRegex(RuntimeError, "(?i)audio|silent"):
                video.verify_video(Path("silent.mp4"), CLASSIC_LOOP_FILM, Path("last.jpg"))
        self.assertEqual(run.call_count, 1)

    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"),
                         "FFmpeg and FFprobe are required for the encoded seam check")
    def test_encoded_loop_has_exact_count_no_audio_and_consecutive_wrap_frames(self):
        size = (32, 18)
        frame_bytes = size[0] * size[1] * 3
        values = [20 + index * 8 for index in range(24)]
        film = Film("test-loop", "Loop test", (
            Scene("rain", "", 0.8, {"preset": "classic"}, overlays=False),
        ), Path("loop.mp4"), score=None, loop_overlap=0.2)
        with tempfile.TemporaryDirectory(prefix="matrixcode-loop-test-", dir=video.TEMP_ROOT) as temporary:
            directory = Path(temporary)
            source = directory / "source.mp4"
            output = directory / "loop.mp4"
            subprocess.run([
                "ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pixel_format", "rgb24",
                "-video_size", "32x18", "-framerate", "30", "-i", "pipe:0", "-an",
                "-c:v", "libx264", "-crf", "0", "-pix_fmt", "yuv420p", str(source),
            ], input=b"".join(bytes([value]) * frame_bytes for value in values), check=True)
            with mock.patch.object(video, "SIZE", size):
                video.assemble([source], None, output, film)
                video.verify_video(output, film, directory / "last.jpg")
            streams = json.loads(subprocess.run([
                "ffprobe", "-v", "error", "-show_streams", "-of", "json", str(output),
            ], capture_output=True, text=True, check=True).stdout)["streams"]
            self.assertEqual([stream["codec_type"] for stream in streams], ["video"])
            self.assertEqual(int(streams[0]["nb_frames"]), 18)
            self.assertAlmostEqual(float(streams[0]["duration"]), 0.6, places=5)
            decoded = subprocess.run([
                "ffmpeg", "-v", "error", "-i", str(output), "-f", "rawvideo",
                "-pix_fmt", "rgb24", "pipe:1",
            ], capture_output=True, check=True).stdout
            self.assertEqual(len(decoded), 18 * frame_bytes)
            levels = [sum(decoded[start:start + frame_bytes]) / frame_bytes
                      for start in range(0, len(decoded), frame_bytes)]
            # The wrap is source frame 5 -> 6; the blend starts at source frame 18.
            self.assertAlmostEqual(levels[0], values[6], delta=4)
            self.assertAlmostEqual(levels[11], values[17], delta=4)
            self.assertAlmostEqual(levels[12], values[18], delta=4)
            self.assertAlmostEqual(levels[-1], values[5], delta=4)
            self.assertAlmostEqual(levels[0] - levels[-1], 8, delta=4)
            # Check an interior sample too: the transition really blends both clocks.
            position = 3 / 5
            weight = position * position * (3 - 2 * position)
            expected = values[21] * (1 - weight) + values[3] * weight
            self.assertAlmostEqual(levels[15], expected, delta=4)
            report = directory / "loop-check.json"
            storyboard = directory / "storyboard.jpg"
            video.verify_loop(output, film, report, storyboard)
            self.assertEqual(json.loads(report.read_text())["frames"], 18)
            with Image.open(storyboard) as image:
                self.assertEqual(image.size, (1440, 540))


if __name__ == "__main__":
    unittest.main()
