#!/usr/bin/env python3
"""Review and apply Calendar names to historical Dott recordings.

The tool is deliberately two-phase:
  migrate_calendar.py --events events.json --root ~/MeetingRecordings
  migrate_calendar.py --events events.json --root ~/MeetingRecordings --apply --approve report.json

The events file is a JSON array of objects with id, summary, start, end, and
optional attendees [{"display_name": "..."}]. It can be exported from the
Google Calendar integration without putting credentials in this repository.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import tempfile
import unicodedata
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

LOCAL_TZ = ZoneInfo("America/Chicago")

FOLDER_RE = re.compile(r"^(?P<stamp>\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}(?:-\d{3})?)")


def parse_stamp(name: str) -> datetime | None:
    match = FOLDER_RE.match(name)
    if not match:
        return None
    value = match.group("stamp")
    has_millis = len(value.rsplit("-", 1)[-1]) == 3 and value.count("-") >= 5
    fmt = "%Y-%m-%d_%H-%M-%S-%f" if has_millis else "%Y-%m-%d_%H-%M-%S"
    if has_millis:
        value += "000"
    try:
        return datetime.strptime(value, fmt).replace(tzinfo=LOCAL_TZ).astimezone(timezone.utc)
    except ValueError:
        return None


def parse_date(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


def slug(value: str, fallback: str) -> str:
    value = unicodedata.normalize("NFKC", value)
    value = re.sub(r"[\r\n\t\x00-\x1f\x7f]+", " ", value)
    value = value.replace("/", "-").replace("\\", "-")
    value = re.sub(r"[<>:\"|?*]+", "-", value)
    value = re.sub(r"\s+", "-", value).strip(" .-_")
    value = re.sub(r"-+", "-", value)
    return (value or fallback)[:100].rstrip("- .") or fallback


def read_duration(folder: Path) -> float:
    # Avoid a media dependency in the migration tool; metadata is preferred.
    # A conservative 30-minute window is used when no ended_at exists.
    try:
        data = json.loads((folder / "metadata.json").read_text())
        started = parse_date(data["started_at"])
        ended = parse_date(data["ended_at"])
        return max(0.0, (ended - started).total_seconds())
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError):
        return 30 * 60


def score(folder_start: datetime, duration: float, event: dict, transcript: str = "") -> tuple[float, dict]:
    start = parse_date(event["start"])
    end = parse_date(event["end"])
    folder_end = folder_start + timedelta(seconds=duration)
    overlap = max(0.0, (min(folder_end, end) - max(folder_start, start)).total_seconds())
    proximity = abs((start - folder_start).total_seconds())
    time_score = overlap / 60.0 * 10.0 - proximity / 60.0
    haystack = transcript.casefold()
    evidence = []
    for attendee in event.get("attendees", []):
        name = attendee.get("display_name", "")
        tokens = [t for t in re.findall(r"[a-z]{3,}", name.casefold()) if t not in {"eric"}]
        if tokens and any(re.search(rf"\b{re.escape(token)}\b", haystack) for token in tokens):
            time_score += 120
            evidence.append(name)
    return time_score, {"overlap_minutes": round(overlap / 60, 1), "start_distance_minutes": round(proximity / 60, 1), "transcript_participant_evidence": evidence}


def rank(folder: Path, events: list[dict]) -> dict:
    started = parse_stamp(folder.name)
    if started is None:
        return {"folder": folder.name, "status": "unparseable"}
    duration = read_duration(folder)
    transcript_path = folder / "transcript.md"
    transcript = transcript_path.read_text(errors="replace") if transcript_path.exists() else ""
    ranked = []
    for event in events:
        value, details = score(started, duration, event, transcript)
        ranked.append({"score": round(value, 2), "event": event, "details": details})
    ranked.sort(key=lambda item: item["score"], reverse=True)
    if not ranked or ranked[0]["score"] < 5:
        status = "no_match"
    elif len(ranked) > 1 and ranked[0]["score"] - ranked[1]["score"] < 15:
        status = "ambiguous"
    else:
        status = "matched"
    best = ranked[0] if ranked else None
    return {
        "folder": folder.name,
        "status": status,
        "started_at": started.isoformat(),
        "duration_seconds": round(duration, 1),
        "match": best,
        "alternatives": ranked[1:4],
    }


def atomic_json(path: Path, value: dict) -> None:
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with open(fd, "w") as handle:
            json.dump(value, handle, indent=2)
            handle.write("\n")
        Path(tmp).replace(path)
    finally:
        Path(tmp).unlink(missing_ok=True)


def apply_match(root: Path, result: dict) -> str:
    source = root / result["folder"]
    event = result["match"]["event"]
    data = {}
    metadata = source / "metadata.json"
    if metadata.exists():
        try:
            data = json.loads(metadata.read_text())
        except json.JSONDecodeError:
            data = {}
    data.setdefault("schema", 2)
    data["migration"] = {"original_folder": source.name, "tool": "migrate_calendar.py"}
    data["meeting_title"] = event["summary"]
    data["calendar"] = {
        "status": "matched", "provider": "google", "calendar_id": event.get("calendar_id", "primary"),
        "event_id": event["id"], "summary": event["summary"], "start": event["start"], "end": event["end"],
        "confidence": "historical_fuzzy", "match": result["match"]["details"],
        "attendees": event.get("attendees", []),
    }
    atomic_json(metadata, data)
    desired = f"{source.name}_{slug(event['summary'], 'meeting')}"
    target = root / desired
    suffix = 2
    while target.exists() and target != source:
        target = root / f"{desired}-{suffix}"
        suffix += 1
    source.rename(target)
    return target.name


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.home() / "MeetingRecordings")
    parser.add_argument("--events", type=Path, required=True)
    parser.add_argument("--report", type=Path, default=Path("calendar-migration-report.json"))
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--approve", type=Path)
    args = parser.parse_args()
    events = json.loads(args.events.read_text())
    folders = sorted(p for p in args.root.iterdir() if p.is_dir() and not p.name.startswith("."))
    results = [rank(folder, events) for folder in folders]
    args.report.write_text(json.dumps(results, indent=2) + "\n")
    for result in results:
        event = result.get("match", {}).get("event", {})
        print(f"{result['status']:11} {result['folder']} -> {event.get('summary', '-')} ({result.get('match', {}).get('score', '-')})")
    if args.apply:
        if not args.approve or args.approve.resolve() != args.report.resolve():
            raise SystemExit("Apply requires --approve pointing at the reviewed --report file")
        for result in results:
            if result["status"] == "matched":
                print(f"APPLIED {result['folder']} -> {apply_match(args.root, result)}")


if __name__ == "__main__":
    main()
