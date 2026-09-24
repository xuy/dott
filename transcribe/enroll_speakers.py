#!/usr/bin/env python3
"""Enroll speaker embeddings from matched 1:1 recordings."""
from __future__ import annotations

import argparse
import json
import os
import re
import tempfile
from pathlib import Path

from speaker_embed import embed_audio, normalize_profile_name
from transcribe import (
    ENERGY_SAMPLE_RATE,
    SILENCE_DBFS_THRESHOLD,
    is_confident_1on1,
    load_pcm,
    segment_dbfs,
)


def _safe_profile_slug(name: str) -> str:
    slug = normalize_profile_name(name)
    slug = re.sub(r"[^a-z0-9._-]+", "-", slug).strip(".-_")
    if not slug or slug in {".", ".."}:
        raise ValueError(f"attendee name cannot form a profile filename: {name!r}")
    return slug


def atomic_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
        Path(tmp).replace(path)
    finally:
        Path(tmp).unlink(missing_ok=True)


def enroll_recordings(recordings_root: Path, profiles_dir: Path) -> dict[str, tuple[str, int, int]]:
    """Enroll eligible recordings and return per-profile (name, total, added)."""
    summary = {}
    if not recordings_root.is_dir():
        raise ValueError(f"recordings root is not a directory: {recordings_root}")
    for folder in sorted(path for path in recordings_root.iterdir() if path.is_dir() and not path.name.startswith(".")):
        try:
            metadata = json.loads((folder / "metadata.json").read_text())
        except (OSError, json.JSONDecodeError):
            continue
        name = is_confident_1on1(metadata)
        if not name or not (folder / "transcript.md").is_file():
            continue
        system_path = next(iter(sorted(folder.glob("system.*"))), None)
        if system_path is None:
            continue
        try:
            audio = load_pcm(system_path, ENERGY_SAMPLE_RATE)
            if audio.size == 0 or segment_dbfs(audio, ENERGY_SAMPLE_RATE, 0, audio.size / ENERGY_SAMPLE_RATE) <= SILENCE_DBFS_THRESHOLD:
                continue
            slug = _safe_profile_slug(name)
        except (OSError, RuntimeError, ValueError):
            continue

        profile_path = profiles_dir / f"{slug}.json"
        try:
            profile = json.loads(profile_path.read_text()) if profile_path.exists() else {"name": name, "embeddings": []}
            if not isinstance(profile, dict) or not isinstance(profile.get("embeddings", []), list):
                raise ValueError("invalid profile shape")
            profile.setdefault("name", name)
            profile.setdefault("embeddings", [])
        except (OSError, json.JSONDecodeError, ValueError):
            print(f"Warning: skipping invalid profile {profile_path}")
            continue

        session = folder.name
        if not any(item.get("session") == session for item in profile["embeddings"] if isinstance(item, dict)):
            try:
                vector = embed_audio(system_path)
            except (RuntimeError, ValueError, OSError) as error:
                print(f"Warning: could not embed {system_path}: {error}")
                continue
            profile["embeddings"].append({"session": session, "vector": vector.astype(float).tolist()})
            atomic_json(profile_path, profile)
            added = 1
        else:
            added = 0
        key = slug
        previous = summary.get(key, (profile["name"], len(profile["embeddings"]), 0))
        summary[key] = (profile["name"], len(profile["embeddings"]), previous[2] + added)

    return summary


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("recordings_root", type=Path)
    parser.add_argument("--profiles-dir", type=Path, default=Path(__file__).resolve().parent / "speaker_profiles")
    args = parser.parse_args()
    summary = enroll_recordings(args.recordings_root, args.profiles_dir)
    for _slug, (name, total, added) in sorted(summary.items()):
        print(f"{name}: {total} session(s), {added} added")


if __name__ == "__main__":
    main()
