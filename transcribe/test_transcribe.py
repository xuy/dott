import json
import tempfile
import unittest
from pathlib import Path

from transcribe import meeting_title


class MeetingTitleTests(unittest.TestCase):
    def test_reads_title(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root)
            (path / "metadata.json").write_text(json.dumps({"meeting_title": "Weekly planning"}))
            self.assertEqual(meeting_title(path), "Weekly planning")

    def test_falls_back_for_missing_or_malformed_metadata(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root)
            self.assertEqual(meeting_title(path), path.name)
            (path / "metadata.json").write_text("not json")
            self.assertEqual(meeting_title(path), path.name)

    def test_normalizes_multiline_title(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root)
            (path / "metadata.json").write_text(json.dumps({"meeting_title": "Weekly\nplanning"}))
            self.assertEqual(meeting_title(path), "Weekly planning")


if __name__ == "__main__":
    unittest.main()
