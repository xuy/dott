import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np

from enroll_speakers import enroll_recordings
from speaker_embed import clear_profiles_cache


class EnrollmentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "recordings"
        self.profiles = Path(self.tmp.name) / "profiles"
        self.root.mkdir()
        self.profiles.mkdir()
        folder = self.root / "session-a"
        folder.mkdir()
        (folder / "metadata.json").write_text(json.dumps({"calendar": {"status": "matched", "attendees": [
            {"display_name": "Eric Xu"}, {"display_name": "Sam Example"},
        ]}}))
        (folder / "transcript.md").write_text("hello")
        (folder / "system.m4a").touch()

    def tearDown(self):
        clear_profiles_cache()
        self.tmp.cleanup()

    @patch("enroll_speakers.embed_audio", return_value=np.array([0.6, 0.8], dtype=np.float32))
    @patch("enroll_speakers.segment_dbfs", return_value=-20.0)
    @patch("enroll_speakers.load_pcm", return_value=np.ones(100, dtype=np.float32))
    def test_enrollment_is_idempotent(self, _pcm, _energy, embed):
        first = enroll_recordings(self.root, self.profiles)
        content = (self.profiles / "sam-example.json").read_bytes()
        second = enroll_recordings(self.root, self.profiles)
        self.assertEqual(first["sam-example"], ("Sam Example", 1, 1))
        self.assertEqual(second["sam-example"], ("Sam Example", 1, 0))
        self.assertEqual((self.profiles / "sam-example.json").read_bytes(), content)
        self.assertEqual(embed.call_count, 1)

    @patch("enroll_speakers.embed_audio")
    @patch("enroll_speakers.segment_dbfs", return_value=-80.0)
    @patch("enroll_speakers.load_pcm", return_value=np.ones(100, dtype=np.float32))
    def test_silent_recordings_are_skipped(self, _pcm, _energy, embed):
        self.assertEqual(enroll_recordings(self.root, self.profiles), {})
        embed.assert_not_called()

    @patch("enroll_speakers.embed_audio")
    def test_sessions_without_transcripts_are_skipped(self, embed):
        (self.root / "session-a" / "transcript.md").unlink()
        self.assertEqual(enroll_recordings(self.root, self.profiles), {})
        embed.assert_not_called()


if __name__ == "__main__":
    unittest.main()
