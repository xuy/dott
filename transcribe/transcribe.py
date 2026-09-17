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
import subprocess
import sys
from pathlib import Path

import mlx_whisper
import numpy as np

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


def load_pcm(path: Path, sample_rate: int = ENERGY_SAMPLE_RATE) -> np.ndarray:
    """Decode any audio file to mono float32 PCM via ffmpeg."""
    cmd = [
        "ffmpeg", "-nostdin", "-v", "quiet", "-i", str(path),
        "-f", "f32le", "-ac", "1", "-ar", str(sample_rate), "-",
    ]
    out = subprocess.run(cmd, stdout=subprocess.PIPE, check=True).stdout
    return np.frombuffer(out, dtype=np.float32)


def segment_dbfs(samples: np.ndarray, sample_rate: int, start: float, end: float) -> float:
    lo, hi = int(start * sample_rate), int(end * sample_rate)
    chunk = samples[lo:hi]
    if chunk.size == 0:
        return -240.0
    rms = np.sqrt(np.mean(chunk.astype(np.float64) ** 2))
    return 20 * np.log10(rms + 1e-12)


def transcribe_file(path: Path, model: str) -> list[dict]:
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

    entries = []
    for path, speaker in [(mic_path, "Me"), (system_path, "Them")]:
        for segment in transcribe_file(path, args.model):
            text = segment["text"].strip()
            if text:
                entries.append((segment["start"], speaker, text))

    entries.sort(key=lambda e: e[0])

    out_path = session_dir / "transcript.md"
    with out_path.open("w") as f:
        f.write(f"# Transcript — {session_dir.name}\n\n")
        for start, speaker, text in entries:
            f.write(f"**[{format_timestamp(start)}] {speaker}:** {text}\n\n")

    print(f"Wrote {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
