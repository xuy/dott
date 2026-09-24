#!/usr/bin/env python3
"""Speaker embeddings, profile matching, and lightweight diarization."""
from __future__ import annotations

import functools
import json
import re
import subprocess
import sys
from pathlib import Path

try:
    import numpy as np
except ImportError:  # Profile metadata helpers can still be imported without numpy.
    np = None

MATCH_THRESHOLD = 0.72  # Starting guess; tune against real match scores.
DIARIZATION_DISTANCE_THRESHOLD = 0.70  # Cosine distance; tune against annotated group-call turns.
DIARIZATION_WINDOW_S = 8.0
DIARIZATION_STEP_S = 4.0
SAMPLE_RATE = 16_000
MODEL_SOURCE = "speechbrain/spkrec-ecapa-voxceleb"

_model = None


def normalize_profile_name(name: str) -> str:
    """Return the stable filename slug for a normalized display name."""
    name = re.sub(r"\s+", " ", name).strip()
    return re.sub(r"\s+", "-", name.casefold())


def _require_numpy():
    if np is None:
        raise RuntimeError("numpy is required for speaker identification")


def _unit_vector(vector):
    _require_numpy()
    values = np.asarray(vector, dtype=np.float32).reshape(-1)
    if values.size == 0 or not np.all(np.isfinite(values)):
        raise ValueError("speaker embedding must contain finite values")
    norm = float(np.linalg.norm(values))
    if norm <= 1e-12:
        raise ValueError("speaker embedding must have non-zero magnitude")
    return values / norm


def _load_model():
    global _model
    if _model is not None:
        return _model
    try:
        import torch
        import torchaudio
        # SpeechBrain 1.0.x still probes this API, removed in torchaudio 2.11.
        # Our model path only consumes PCM decoded by ffmpeg, so the backend
        # list is informational and no torchaudio file backend is required.
        if not hasattr(torchaudio, "list_audio_backends"):
            torchaudio.list_audio_backends = lambda: []
        from speechbrain.inference.speaker import EncoderClassifier
    except ImportError as error:
        raise RuntimeError(
            "speaker identification requires speechbrain and torch; install "
            "transcribe/requirements.txt"
        ) from error

    _model = EncoderClassifier.from_hparams(
        source=MODEL_SOURCE,
        savedir=str(Path.home() / ".cache" / "meeting-recorder" / "speaker-model"),
        run_opts={"device": "cpu"},
    )
    return _model


def embed_window(samples, sample_rate: int = SAMPLE_RATE):
    """Return an L2-normalized ECAPA embedding for mono float32 PCM."""
    _require_numpy()
    if sample_rate != SAMPLE_RATE:
        raise ValueError(f"speaker audio must be resampled to {SAMPLE_RATE} Hz")
    audio = np.asarray(samples, dtype=np.float32).reshape(-1)
    if audio.size == 0:
        raise ValueError("cannot embed empty audio")
    # ECAPA needs enough frames for stable statistics pooling. Pad short edges
    # rather than fail on the last diarization window.
    min_samples = int(0.5 * SAMPLE_RATE)
    if audio.size < min_samples:
        audio = np.pad(audio, (0, min_samples - audio.size))

    try:
        import torch
    except ImportError as error:
        raise RuntimeError("speaker identification requires torch") from error
    model = _load_model()
    waveform = torch.from_numpy(np.array(audio, dtype=np.float32, copy=True, order="C")).unsqueeze(0)
    with torch.inference_mode():
        result = model.encode_batch(waveform)
    return _unit_vector(result.detach().cpu().numpy())


def _embed_windows(windows):
    """Embed a batch of mono PCM windows with one model call."""
    _require_numpy()
    if not windows:
        return []
    normalized = []
    min_samples = int(0.5 * SAMPLE_RATE)
    for window in windows:
        audio = np.asarray(window, dtype=np.float32).reshape(-1)
        if audio.size == 0:
            raise ValueError("cannot embed empty audio")
        if audio.size < min_samples:
            audio = np.pad(audio, (0, min_samples - audio.size))
        normalized.append(audio)
    lengths = {audio.size for audio in normalized}
    if len(lengths) != 1:
        raise ValueError("batched speaker windows must have equal lengths")
    try:
        import torch
    except ImportError as error:
        raise RuntimeError("speaker identification requires torch") from error
    model = _load_model()
    vectors = []
    batch_size = 32
    with torch.inference_mode():
        for offset in range(0, len(normalized), batch_size):
            batch = np.stack(normalized[offset:offset + batch_size]).astype(np.float32, copy=False)
            result = model.encode_batch(torch.from_numpy(batch))
            if hasattr(result, "detach"):
                result = result.detach().cpu().numpy()
            else:
                result = np.asarray(result)
            vectors.extend(_unit_vector(vector) for vector in result.reshape(len(batch), -1))
    return vectors


def embed_audio(path: Path):
    """Decode any ffmpeg-readable audio path and embed the whole file."""
    cmd = [
        "ffmpeg", "-nostdin", "-v", "error", "-i", str(path),
        "-f", "f32le", "-ac", "1", "-ar", str(SAMPLE_RATE), "-",
    ]
    try:
        result = subprocess.run(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            check=True, timeout=300,
        )
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"ffmpeg timed out decoding {path}") from error
    except subprocess.CalledProcessError as error:
        detail = error.stderr.decode(errors="replace").strip()
        raise RuntimeError(f"ffmpeg could not decode {path}: {detail}") from error
    samples = np.frombuffer(result.stdout, dtype=np.float32)
    if samples.size == 0:
        raise ValueError(f"no audio samples decoded from {path}")
    return embed_window(samples, SAMPLE_RATE)


def _read_profile_file(path: Path) -> dict | None:
    try:
        profile = json.loads(path.read_text())
        name = profile["name"]
        embeddings = profile["embeddings"]
        if not isinstance(name, str) or not name or not isinstance(embeddings, list):
            return None
        if any(not isinstance(item, dict) or "vector" not in item for item in embeddings):
            return None
        vectors = [_unit_vector(item["vector"]) for item in embeddings]
        if not vectors:
            return None
        return {"name": name, "vectors": vectors}
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError):
        print(f"Warning: ignoring invalid speaker profile {path}", file=sys.stderr)
        return None


@functools.lru_cache(maxsize=8)
def load_profiles(profiles_dir: Path) -> dict[str, dict]:
    """Load usable profile vectors once per process and directory."""
    profiles_dir = Path(profiles_dir).resolve()
    profiles = {}
    if not profiles_dir.is_dir():
        return profiles
    for path in sorted(profiles_dir.glob("*.json")):
        profile = _read_profile_file(path)
        if profile is not None:
            profiles[path.stem] = profile
    return profiles


def clear_profiles_cache() -> None:
    load_profiles.cache_clear()


def match_speaker(vector, profiles_dir: Path, threshold: float = MATCH_THRESHOLD) -> tuple[str | None, float]:
    """Match an embedding to the closest enrolled profile centroid."""
    _require_numpy()
    query = _unit_vector(vector)
    best_name, best_score = None, -1.0
    for profile in load_profiles(Path(profiles_dir)).values():
        matrix = np.stack(profile["vectors"])
        if matrix.shape[1] != query.size:
            continue
        centroid = _unit_vector(matrix.mean(axis=0))
        score = float(np.dot(query, centroid))
        if score > best_score:
            best_name, best_score = profile["name"], score
    if best_name is None:
        return None, 0.0
    return (best_name if best_score >= threshold else None), best_score


def cluster_embeddings(vectors, distance_threshold: float = DIARIZATION_DISTANCE_THRESHOLD) -> list[int]:
    """Cluster normalized window embeddings by cosine distance."""
    _require_numpy()
    matrix = np.asarray(vectors, dtype=np.float32)
    if matrix.ndim != 2:
        raise ValueError("vectors must be a two-dimensional matrix")
    if matrix.shape[0] == 0:
        return []
    if matrix.shape[0] == 1:
        return [0]
    try:
        from sklearn.cluster import AgglomerativeClustering
    except ImportError as error:
        raise RuntimeError("speaker diarization requires scikit-learn") from error

    normalized = np.stack([_unit_vector(vector) for vector in matrix])
    model = AgglomerativeClustering(
        n_clusters=None,
        metric="cosine",
        linkage="average",
        distance_threshold=distance_threshold,
    )
    return model.fit_predict(normalized).astype(int).tolist()


def merge_windows(assignments: list[int], vectors, window_s: float, step_s: float, duration: float, starts_s=None) -> list[dict]:
    """Merge same-speaker window labels into non-overlapping time spans."""
    _require_numpy()
    if not assignments:
        return []
    if window_s <= 0 or step_s <= 0 or duration < 0:
        raise ValueError("window_s and step_s must be positive and duration non-negative")
    if len(vectors) != len(assignments):
        raise ValueError("assignments and vectors must have the same length")
    if starts_s is None:
        starts_s = [i * step_s for i in range(len(assignments))]
    if len(starts_s) != len(assignments):
        raise ValueError("starts_s and assignments must have the same length")
    centers = [min(start + window_s / 2, max(0.0, duration)) for start in starts_s]
    boundaries = [0.0]
    boundaries.extend((left + right) / 2 for left, right in zip(centers, centers[1:]))
    boundaries.append(duration)

    spans = []
    begin = 0
    for index in range(1, len(assignments) + 1):
        if index < len(assignments) and assignments[index] == assignments[begin]:
            continue
        end_index = index
        mean_vector = np.mean(np.asarray(vectors[begin:end_index]), axis=0)
        spans.append({
            "start": max(0.0, boundaries[begin]),
            "end": max(boundaries[begin], boundaries[end_index]),
            "cluster": int(assignments[begin]),
            "vector": _unit_vector(mean_vector),
        })
        begin = index
    return spans


def diarize(
    path: Path,
    window_s: float = DIARIZATION_WINDOW_S,
    step_s: float = DIARIZATION_STEP_S,
) -> list[dict]:
    """Embed sliding windows and return merged, clustered speaker spans."""
    if window_s <= 0 or step_s <= 0:
        raise ValueError("window_s and step_s must be positive")
    _require_numpy()
    # Import the established ffmpeg decoder lazily to keep profile operations
    # independent of the transcription module's optional ML dependencies.
    from transcribe import load_pcm

    samples = load_pcm(Path(path), SAMPLE_RATE)
    if samples.size == 0:
        return []
    duration = samples.size / SAMPLE_RATE
    window = max(1, int(window_s * SAMPLE_RATE))
    step = max(1, int(step_s * SAMPLE_RATE))
    if samples.size <= window:
        starts = [0]
    else:
        starts = list(range(0, samples.size - window + 1, step))
        final_start = samples.size - window
        if starts[-1] != final_start:
            starts.append(final_start)

    chunks = [samples[start:min(start + window, samples.size)] for start in starts]
    padded_chunks = [
        np.pad(chunk, (0, window - chunk.size)) if chunk.size < window else chunk
        for chunk in chunks
    ]
    vectors = _embed_windows(padded_chunks)
    assignments = cluster_embeddings(np.stack(vectors))

    # Pass actual starts so the final appended window has correct boundaries.
    start_times = [start / SAMPLE_RATE for start in starts]
    return merge_windows(assignments, vectors, window_s, step_s, duration, start_times)
