import unittest
from datetime import timezone
from pathlib import Path
from tempfile import TemporaryDirectory

from migrate_calendar import parse_stamp, slug, rank


class MigrationTests(unittest.TestCase):
    def test_parse_stamp_uses_local_recording_timezone(self):
        parsed = parse_stamp("2026-09-21_13-00-28-963")
        self.assertEqual(parsed.hour, 18)
        self.assertEqual(parsed.tzinfo, timezone.utc)

    def test_slug_never_creates_nested_paths(self):
        value = slug("Client / Planning: Q&A?", "meeting")
        self.assertNotIn("/", value)
        self.assertNotIn("\\", value)
        self.assertEqual(value, "Client-Planning-Q&A")

    def test_rank_uses_transcript_participant_evidence(self):
        with TemporaryDirectory() as root:
            folder = Path(root) / "2026-09-21_13-00-28-963"
            folder.mkdir()
            (folder / "transcript.md").write_text("Hey Tommy how are you")
            result = rank(folder, [{
                "id": "1", "summary": "Tommy intro",
                "start": "2026-09-21T13:00:00-05:00",
                "end": "2026-09-21T13:30:00-05:00",
                "attendees": [{"display_name": "Tommy Scalf"}],
            }])
            self.assertEqual(result["status"], "matched")
            self.assertEqual(result["match"]["details"]["transcript_participant_evidence"], ["Tommy Scalf"])


if __name__ == "__main__":
    unittest.main()
