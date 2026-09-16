#!/usr/bin/env python3
"""Offline-transcribe a meeting recorded by Recorder.app.

Transcribes mic.wav and system.wav separately (so each side of the call
comes with a real timestamp from its own audio), then interleaves the
segments chronologically with "Me" / "Them" labels -- a free stand-in for
speaker diarization, since the two streams already are the two speakers.

Usage:
    transcribe.py <session_dir> [--model mlx-community/whisper-large-v3-turbo]
"""
import argparse
import sys
import warnings
from pathlib import Path

import mlx_whisper
import numpy as np
from scipy.io import wavfile

DEFAULT_MODEL = "mlx-community/whisper-large-v3-turbo"

# Whisper confidently hallucinates short stock phrases ("Thank you.", "Thanks
# for watching!") on digitally-silent audio -- common on the system-audio
# track when nothing's actually playing. Whisper's own confidence signals
# (no_speech_prob, avg_logprob) do NOT catch this: in testing it reported
# no_speech_prob≈0 and a good avg_logprob for a "Thank you." hallucinated
# over 30s of pure silence -- it genuinely "believes" it heard that. So we
# gate on measured audio energy instead, independent of what Whisper thinks.
SILENCE_DBFS_THRESHOLD = -50.0


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

    with warnings.catch_warnings():
        warnings.simplefilter("ignore", wavfile.WavFileWarning)
        sample_rate, samples = wavfile.read(path)

    kept = [
        s
        for s in segments
        if segment_dbfs(samples, sample_rate, s["start"], s["end"]) > SILENCE_DBFS_THRESHOLD
    ]
    dropped = len(segments) - len(kept)
    if dropped:
        print(f"  dropped {dropped} silent segment(s)", file=sys.stderr)
    return kept


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
    mic_path = session_dir / "mic.wav"
    system_path = session_dir / "system.wav"
    if not mic_path.exists() or not system_path.exists():
        sys.exit(f"Expected mic.wav and system.wav in {session_dir}")

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
