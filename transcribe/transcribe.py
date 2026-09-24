#!/usr/bin/env python3
"""Offline-transcribe a meeting recorded by Dott.

Transcribes the mic and system-audio tracks separately (so each side of the
call comes with a real timestamp from its own audio), then interleaves the
segments chronologically with "Me" / "Them" labels -- a free stand-in for
speaker diarization, since the two streams already are the two speakers.

Accepts whatever audio format Dott wrote (m4a, wav, ...) -- anything ffmpeg
can decode, since that's what both mlx_whisper and our own silence check
use under the hood.

Usage:
    transcribe.py <session_dir> [--model mlx-community/whisper-large-v3-turbo]
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

try:
    import numpy as np
except ImportError:  # Metadata helpers remain usable without transcription deps.
    np = None

try:
    import mlx_whisper
except ImportError:  # Metadata helpers remain usable without the model installed.
    mlx_whisper = None

DEFAULT_MODEL = "mlx-community/whisper-large-v3-turbo"

# Whisper confidently hallucinates short stock phrases ("Thank you.", "Thanks
# for watching!") on digitally-silent audio -- common on the system-audio
# track when nothing's actually playing. Whisper's own confidence signals
# (no_speech_prob, avg_logprob) do NOT catch this: in testing it reported
# no_speech_prob≈0 and a good avg_logprob for a "Thank you." hallucinated
# over 30s of pure silence -- it genuinely "believes" it heard that. So we
# gate on measured audio energy instead, independent of what Whisper thinks.
SILENCE_DBFS_THRESHOLD = -50.0
ENERGY_SAMPLE_RATE = 16_000  # plenty for an RMS silence check, decodes fast


def load_pcm(path: Path, sample_rate: int = ENERGY_SAMPLE_RATE) -> "np.ndarray":
    """Decode any audio file to mono float32 PCM via ffmpeg."""
    if np is None:
        sys.exit("numpy is required to transcribe audio")
    cmd = [
        "ffmpeg", "-nostdin", "-v", "error", "-i", str(path),
        "-f", "f32le", "-ac", "1", "-ar", str(sample_rate), "-",
    ]
    try:
        result = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
            timeout=300,
        )
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"ffmpeg timed out decoding {path}") from error
    except subprocess.CalledProcessError as error:
        detail = error.stderr.decode(errors="replace").strip()
        raise RuntimeError(f"ffmpeg could not decode {path}: {detail}") from error
    return np.frombuffer(result.stdout, dtype=np.float32)


def segment_dbfs(samples: np.ndarray, sample_rate: int, start: float, end: float) -> float:
    lo, hi = int(start * sample_rate), int(end * sample_rate)
    chunk = samples[lo:hi]
    if chunk.size == 0:
        return -240.0
    rms = np.sqrt(np.mean(chunk.astype(np.float64) ** 2))
    return 20 * np.log10(rms + 1e-12)


def transcribe_file(path: Path, model: str) -> list[dict]:
    if mlx_whisper is None:
        sys.exit("mlx-whisper is required to transcribe audio")
    print(f"Transcribing {path.name} with {model} ...", file=sys.stderr)
    result = mlx_whisper.transcribe(str(path), path_or_hf_repo=model)
    segments = result["segments"]

    samples = load_pcm(path)

    kept = [
        s
        for s in segments
        if segment_dbfs(samples, ENERGY_SAMPLE_RATE, s["start"], s["end"])
        > SILENCE_DBFS_THRESHOLD
    ]
    dropped = len(segments) - len(kept)
    if dropped:
        print(f"  dropped {dropped} silent segment(s)", file=sys.stderr)
    return kept


def find_track(session_dir: Path, stem: str) -> Path:
    matches = sorted(session_dir.glob(f"{stem}.*"))
    if not matches:
        sys.exit(f"No {stem}.* file found in {session_dir}")
    return matches[0]


def meeting_title(session_dir: Path) -> str:
    fallback = session_dir.name
    metadata_path = session_dir / "metadata.json"
    try:
        data = json.loads(metadata_path.read_text())
        title = data.get("meeting_title") if isinstance(data, dict) else None
        if not isinstance(title, str):
            return fallback
        title = re.sub(r"[\r\n\t]+", " ", title)
        title = re.sub(r"\s+", " ", title).strip()
        return title or fallback
    except FileNotFoundError:
        return fallback
    except (OSError, json.JSONDecodeError) as error:
        print(f"Warning: ignoring {metadata_path}: {error}", file=sys.stderr)
        return fallback


LOCAL_ATTENDEE_NAME = "Eric Xu"


def is_confident_1on1(metadata: dict) -> str | None:
    """Return the sole remote attendee for a matched 1:1, if known."""
    if not isinstance(metadata, dict):
        return None
    calendar = metadata.get("calendar")
    if not isinstance(calendar, dict) or calendar.get("status") != "matched":
        return None
    attendees = calendar.get("attendees", [])
    if not isinstance(attendees, list):
        return None
    names = [
        re.sub(r"\s+", " ", item.get("display_name", "")).strip()
        for item in attendees
        if isinstance(item, dict) and isinstance(item.get("display_name"), str)
    ]
    names = [name for name in names if name and name.casefold() != LOCAL_ATTENDEE_NAME.casefold()]
    return names[0] if len(names) == 1 else None


def speaker_labels(session_dir: Path) -> tuple[str, str]:
    metadata_path = session_dir / "metadata.json"
    try:
        data = json.loads(metadata_path.read_text())
        remote_name = is_confident_1on1(data)
        if remote_name:
            return "Me", remote_name
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        pass
    return "Me", "Them"


def label_system_segments(segments: list[dict], system_path: Path, remote_label: str) -> list[tuple[dict, str]]:
    """Diarize the system track and label each Whisper segment by voice."""
    try:
        from speaker_embed import diarize, match_speaker
        spans = diarize(system_path)
    except Exception as error:
        print(f"Warning: speaker diarization unavailable; using {remote_label}: {error}", file=sys.stderr)
        return [(segment, remote_label) for segment in segments]
    clusters = {span["cluster"] for span in spans}
    if len(clusters) <= 1:
        return [(segment, remote_label) for segment in segments]

    profiles_dir = Path(__file__).resolve().parent / "speaker_profiles"
    cluster_vectors = {}
    for cluster in clusters:
        vectors = [span["vector"] for span in spans if span["cluster"] == cluster]
        if vectors:
            try:
                import numpy as np
                vector = np.mean(np.stack(vectors), axis=0)
                name, _score = match_speaker(vector, profiles_dir)
            except Exception:
                name = None
        else:
            name = None
        cluster_vectors[cluster] = name

    ordered_clusters = []
    for span in sorted(spans, key=lambda item: item["start"]):
        if span["cluster"] not in ordered_clusters:
            ordered_clusters.append(span["cluster"])
    cluster_labels = {}
    next_unknown = 1
    for cluster in ordered_clusters:
        name = cluster_vectors.get(cluster)
        if name:
            cluster_labels[cluster] = name
        else:
            cluster_labels[cluster] = f"Speaker {next_unknown}"
            next_unknown += 1

    labeled = []
    for segment in segments:
        midpoint = (segment["start"] + segment["end"]) / 2
        span = next((item for item in spans if item["start"] <= midpoint < item["end"]), None)
        if span is None and spans:
            span = min(spans, key=lambda item: min(abs(midpoint - item["start"]), abs(midpoint - item["end"])))
        label = cluster_labels.get(span["cluster"], remote_label) if span else remote_label
        labeled.append((segment, label))
    return labeled


def format_timestamp(seconds: float) -> str:
    minutes, secs = divmod(int(seconds), 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours:d}:{minutes:02d}:{secs:02d}"
    return f"{minutes:02d}:{secs:02d}"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("session_dir", type=Path)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    args = parser.parse_args()

    session_dir = args.session_dir
    mic_path = find_track(session_dir, "mic")
    system_path = find_track(session_dir, "system")

    me_label, remote_label = speaker_labels(session_dir)
    entries = []
    for segment in transcribe_file(mic_path, args.model):
        text = segment["text"].strip()
        if text:
            entries.append((segment["start"], me_label, text))

    system_segments = transcribe_file(system_path, args.model)
    for segment, speaker in label_system_segments(system_segments, system_path, remote_label):
        text = segment["text"].strip()
        if text:
            entries.append((segment["start"], speaker, text))

    entries.sort(key=lambda e: e[0])

    out_path = session_dir / "transcript.md"
    with out_path.open("w") as f:
        f.write(f"# Transcript — {meeting_title(session_dir)}\n\n")
        for start, speaker, text in entries:
            f.write(f"**[{format_timestamp(start)}] {speaker}:** {text}\n\n")

    print(f"Wrote {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
