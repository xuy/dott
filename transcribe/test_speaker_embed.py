import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np

from speaker_embed import (
    _embed_windows,
    clear_profiles_cache,
    cluster_embeddings,
    match_speaker,
    merge_windows,
    normalize_profile_name,
)


class SpeakerEmbeddingTests(unittest.TestCase):
    def tearDown(self):
        clear_profiles_cache()

    def test_normalizes_profile_names(self):
        self.assertEqual(normalize_profile_name("  Abby   Douglas "), "abby-douglas")

    def test_matches_profile_centroid_and_threshold(self):
        with tempfile.TemporaryDirectory() as root:
            profiles = Path(root)
            (profiles / "abby.json").write_text(json.dumps({
                "name": "Abby Douglas",
                "embeddings": [{"session": "one", "vector": [1, 0, 0]}, {"session": "two", "vector": [0.98, 0.2, 0]}],
            }))
            name, score = match_speaker(np.array([1, 0, 0]), profiles, threshold=0.8)
            self.assertEqual(name, "Abby Douglas")
            self.assertGreater(score, 0.99)
            name, score = match_speaker(np.array([0, 1, 0]), profiles, threshold=0.8)
            self.assertIsNone(name)
            self.assertLess(score, 0.8)

    def test_no_profiles_returns_no_match(self):
        with tempfile.TemporaryDirectory() as root:
            self.assertEqual(match_speaker([1, 0], Path(root)), (None, 0.0))

    def test_clustering_empty_single_and_separated_vectors(self):
        self.assertEqual(cluster_embeddings(np.empty((0, 3))), [])
        self.assertEqual(cluster_embeddings(np.array([[1, 0, 0]])), [0])
        labels = cluster_embeddings(np.array([[1, 0, 0], [0.99, 0.01, 0], [0, 1, 0], [0.01, 0.99, 0]]), 0.2)
        self.assertEqual(labels[0], labels[1])
        self.assertEqual(labels[2], labels[3])
        self.assertNotEqual(labels[0], labels[2])

    def test_merge_windows_produces_contiguous_non_overlapping_spans(self):
        spans = merge_windows([0, 0, 1, 1], np.array([[1, 0], [1, 0], [0, 1], [0, 1]]), 1.5, 0.75, 3.75)
        self.assertEqual(len(spans), 2)
        self.assertEqual((spans[0]["start"], spans[0]["end"]), (0.0, 1.875))
        self.assertEqual((spans[1]["start"], spans[1]["end"]), (1.875, 3.75))
        self.assertEqual(spans[0]["cluster"], 0)
        self.assertTrue(np.isclose(np.linalg.norm(spans[0]["vector"]), 1.0))

    def test_merge_windows_empty_and_rejects_mismatched_vectors(self):
        self.assertEqual(merge_windows([], [], 1.5, 0.75, 2.0), [])
        with self.assertRaises(ValueError):
            merge_windows([0, 1], [[1.0, 0.0]], 1.5, 0.75, 2.0)

    def test_diarization_defaults_use_longer_stable_windows(self):
        from speaker_embed import DIARIZATION_DISTANCE_THRESHOLD, DIARIZATION_STEP_S, DIARIZATION_WINDOW_S
        self.assertEqual(DIARIZATION_WINDOW_S, 8.0)
        self.assertEqual(DIARIZATION_STEP_S, 4.0)
        self.assertEqual(DIARIZATION_DISTANCE_THRESHOLD, 0.70)

    def test_batched_embedding_keeps_model_call_window_batch(self):
        class FakeModel:
            def encode_batch(self, waveform):
                self.assert_shape = tuple(waveform.shape)
                return np.array([[[1.0, 0.0]], [[0.0, 2.0]]], dtype=np.float32)
        model = FakeModel()
        with patch("speaker_embed._load_model", return_value=model):
            vectors = _embed_windows([np.ones(9000, dtype=np.float32), np.ones(9000, dtype=np.float32)])
        self.assertEqual(model.assert_shape, (2, 9000))
        self.assertTrue(np.allclose(vectors, [[1, 0], [0, 1]]))


if __name__ == "__main__":
    unittest.main()
