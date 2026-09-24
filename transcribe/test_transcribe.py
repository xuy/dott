import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

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

    def test_uses_single_calendar_attendee_for_remote_label(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root)
            (path / "metadata.json").write_text(json.dumps({"calendar": {"status": "matched", "attendees": [{"display_name": "Sam"}]}}))
            from transcribe import speaker_labels
            self.assertEqual(speaker_labels(path), ("Me", "Sam"))

    def test_excludes_local_attendee_from_realistic_matched_metadata(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root)
            metadata = {"calendar": {"status": "matched", "attendees": [
                {"display_name": "  Eric   Xu "}, {"display_name": "Abby  Douglas"},
            ]}}
            (path / "metadata.json").write_text(json.dumps(metadata))
            from transcribe import is_confident_1on1, speaker_labels
            self.assertEqual(is_confident_1on1(metadata), "Abby Douglas")
            self.assertEqual(speaker_labels(path), ("Me", "Abby Douglas"))

    def test_multiple_remote_attendees_are_not_a_confident_one_on_one(self):
        from transcribe import is_confident_1on1
        metadata = {"calendar": {"status": "matched", "attendees": [
            {"display_name": "Eric Xu"}, {"display_name": "Abby"}, {"display_name": "Sam"},
        ]}}
        self.assertIsNone(is_confident_1on1(metadata))

    def test_unmatched_calendar_is_not_a_confident_one_on_one(self):
        from transcribe import is_confident_1on1
        self.assertIsNone(is_confident_1on1({"calendar": {"status": "unmatched", "attendees": [{"display_name": "Sam"}]}}))

    def test_one_cluster_keeps_existing_remote_label(self):
        from transcribe import label_system_segments
        segment = {"start": 1.0, "end": 2.0, "text": "hello"}
        with patch("speaker_embed.diarize", return_value=[{"start": 0.0, "end": 3.0, "cluster": 0, "vector": [1.0, 0.0]}]):
            self.assertEqual(label_system_segments([segment], Path("system.m4a"), "Sam"), [(segment, "Sam")])

    def test_unknown_clusters_receive_first_appearance_labels(self):
        from transcribe import label_system_segments
        segments = [
            {"start": 0.1, "end": 0.5, "text": "a"},
            {"start": 1.1, "end": 1.5, "text": "b"},
        ]
        spans = [
            {"start": 0.0, "end": 1.0, "cluster": 8, "vector": [1.0, 0.0]},
            {"start": 1.0, "end": 2.0, "cluster": 3, "vector": [0.0, 1.0]},
        ]
        with patch("speaker_embed.diarize", return_value=spans), patch("speaker_embed.match_speaker", return_value=(None, 0.2)):
            labeled = label_system_segments(segments, Path("system.m4a"), "Them")
        self.assertEqual([label for _, label in labeled], ["Speaker 1", "Speaker 2"])

    def test_diarization_errors_preserve_existing_label(self):
        from transcribe import label_system_segments
        segment = {"start": 0.0, "end": 1.0, "text": "hello"}
        with patch("speaker_embed.diarize", side_effect=RuntimeError("model unavailable")):
            self.assertEqual(label_system_segments([segment], Path("system.m4a"), "Sam"), [(segment, "Sam")])

    def test_normalizes_multiline_title(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root)
            (path / "metadata.json").write_text(json.dumps({"meeting_title": "Weekly\nplanning"}))
            self.assertEqual(meeting_title(path), "Weekly planning")


if __name__ == "__main__":
    unittest.main()
