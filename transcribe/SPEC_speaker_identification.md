# Spec: Speaker identification for group calls, bootstrapped from past 1:1s

## Problem

`transcribe.py` labels speakers by *audio stream*, not by voice: `mic.m4a` is
always "Me", `system.m4a` is always one other label (see `speaker_labels()`
in `transcribe.py:125`). That's free and correct for 1:1s, because the
system-audio stream really does contain exactly one other person.

It breaks down for group calls: `system.m4a` mixes every remote participant
into one track, so today they all get lumped under a single label (usually
"Them", or the meeting's sole matched attendee name if there happens to be
one). Example group sessions already in `~/MeetingRecordings`:
`2026-09-21_15-00-06-468_Eng-LT-Meeting`, `..._Project-Star-Wars-{Weekly}`.

## Idea

We already have clean, single-speaker, *labeled* audio for some people: any
past 1:1 session where `calendar.status == "matched"` and there's exactly one
remote attendee. `speaker_labels()` already identifies these sessions and
already resolves the person's name — that's the enrollment data. Use it to
build a small voice-embedding profile per known person, then for group calls,
diarize `system.m4a` into per-speaker turns and match each turn's embedding
against the enrolled profiles.

## Non-goals

- No real-time / live identification — this stays an offline, post-recording
  step, run as part of (or alongside) the existing `transcribe.py` pass.
- No attempt to identify "Me" (mic track) — already solved.
- No UI. Command-line / files only, consistent with the rest of `transcribe/`.
- Don't try to solve calendar-attendee matching for group calls (empty
  `attendees: []` on unmatched group events, as seen in `Eng-LT-Meeting`'s
  metadata.json) — that's a separate, already-known problem. This spec only
  covers turning "some voice spoke in the system track" into "Austin spoke",
  given that we already have Austin enrolled from a prior 1:1.

## Dependencies

Add to `transcribe/requirements.txt`. Use `speechbrain`'s
`spkrec-ecapa-voxceleb` embedding model (pulled from Hugging Face Hub, no
gated-model approval needed, unlike `pyannote`'s pretrained pipelines). `torch`
is already a dependency. Also need `scikit-learn` for clustering
(`AgglomerativeClustering`) — small, pure-Python-wheel dependency, fine to add.

Do NOT depend on `pyannote.audio`'s pretrained diarization pipeline (gated
model, requires accepting terms + HF token). We build a much smaller,
DIY diarization step in Phase 3 instead — see below for why that's enough for
our case (2–8 participants, generally-clean per-person turns, no need for
state-of-the-art diarization accuracy).

## Data model

New directory: `transcribe/speaker_profiles/`. One JSON file per enrolled
person, filename = normalized name (lowercase, spaces → `-`, e.g.
`austin.json`):

```json
{
  "name": "Austin",
  "embeddings": [
    {"session": "2026-09-18_14-32-51-215_Eric-Austin", "vector": [0.0123, ...]},
    {"session": "2026-09-21_12-52-00-464_Eric-Austin-Part-2", "vector": [...]}
  ]
}
```

- `vector` is the L2-normalized embedding (list of floats — 192-dim for
  ECAPA-TDNN). Store one entry per enrolling session, not just a running
  average — keeps enrollment idempotent/re-runnable and lets later phases
  drop bad sessions without recomputing everything.
- Matching uses the centroid of all vectors for that person (compute at
  match time — cheap for this data size, don't bother caching it).
- Name normalization must reuse whatever logic identifies the person from
  `metadata.json` today (see `speaker_labels()`) — same whitespace collapsing
  the existing code already does, so "Austin" from two different sessions
  collapses to the same profile file.

This directory holds voice-derived biometric data. Keep it out of git — add
`transcribe/speaker_profiles/` to `.gitignore` alongside whatever pattern
already excludes `~/MeetingRecordings` (check `.gitignore` first; it was
recently touched per git status — don't duplicate an existing rule).

## Phase 1 — embedding helper + enrollment script

New file: `transcribe/speaker_embed.py`

```python
def embed_audio(path: Path) -> np.ndarray:
    """Decode `path` (any ffmpeg-readable format) and return a single
    L2-normalized speaker embedding vector for the whole file."""

def embed_window(samples: np.ndarray, sample_rate: int) -> np.ndarray:
    """Same, but takes already-decoded mono float32 PCM (for reuse in
    Phase 3, which needs to embed many short windows without re-decoding
    the file each time)."""
```

Load the ECAPA-TDNN model once at module import (lazy singleton — mirror the
existing `try: import mlx_whisper / except ImportError: mlx_whisper = None`
pattern from `transcribe.py:23` so profile-store code can still be imported
and unit-tested without the heavy ML deps installed).

New file: `transcribe/enroll_speakers.py`

```
Usage: enroll_speakers.py <recordings_root> [--profiles-dir transcribe/speaker_profiles]
```

Algorithm:
1. For each subdirectory of `<recordings_root>`: load `metadata.json`, reuse
   `speaker_labels()` from `transcribe.py` (import it — don't reimplement).
2. Skip if it returns the `("Me", "Them")` fallback (i.e. not a
   confidently-matched 1:1) — check `calendar.status == "matched"` and
   `len(attendees) == 2` directly, same condition `speaker_labels()` already
   checks internally. (Consider exporting that condition from
   `transcribe.py` as a small helper, e.g. `is_confident_1on1(metadata) ->
   str | None` returning the remote person's name or `None`, so both scripts
   share one source of truth instead of duplicating the check.)
3. Skip if `transcript.md` doesn't exist yet or if `system.m4a`'s measured
   energy is below `SILENCE_DBFS_THRESHOLD` for the whole file (reuse
   `load_pcm` / `segment_dbfs` from `transcribe.py` — a 1:1 where the other
   person never unmuted is useless enrollment data, not just useless
   transcript).
4. Otherwise: `embed_audio(system_path)`, write/update
   `speaker_profiles/<normalized-name>.json`, appending this session's vector
   (skip if that session is already recorded in the file — re-runs are
   idempotent).
5. Print a one-line summary per person: name, session count, session count
   added this run.

Acceptance check: running it twice in a row against the same
`~/MeetingRecordings` produces identical profile files (no duplicate
entries).

## Phase 2 — matching

New function in `speaker_embed.py`:

```python
def match_speaker(
    vector: np.ndarray, profiles_dir: Path, threshold: float = 0.72
) -> tuple[str | None, float]:
    """Cosine-similarity match against every enrolled profile's centroid.
    Returns (name, score) for the best match if score >= threshold,
    else (None, score) with score being the best score found (possibly
    still useful for logging/tuning)."""
```

Load all profiles from `profiles_dir` once per process (not once per call —
Phase 3 will call this per diarized turn, could be dozens of times per
session).

The `0.72` starting threshold is a guess — leave it a named constant at the
top of the file with a comment saying so, and plan to tune it empirically
once Phase 3 produces real match scores on actual recordings (Austin,
Abby, Tommy, KC all have enrollment-eligible 1:1s already in
`~/MeetingRecordings`, per current `ls`).

Write a unit test using two synthetic profiles with hand-built vectors
(e.g. `[1,0,0,...]` vs `[0,1,0,...]`) to check the threshold logic and the
"no match" path, without needing real audio or the ML deps installed.

## Phase 3 — group-call diarization + integration into transcribe.py

This is the part that actually changes transcription output, so land it
last and only after Phase 1/2 are working against real enrolled profiles.

**3a. Cheap diarization**, new function in `speaker_embed.py`:

```python
def diarize(path: Path, window_s: float = 8.0, step_s: float = 4.0) -> list[dict]:
    """Return [{"start": float, "end": float, "cluster": int}, ...] — sliding
    windows over the whole file, each embedded, then clustered with
    AgglomerativeClustering (cosine distance, distance_threshold tuned like
    the match threshold above, n_clusters=None so it picks cluster count
    automatically). Merge consecutive windows assigned to the same cluster
    into single spans before returning."""
```

This is deliberately not state-of-the-art diarization — no VAD pass, no
overlap handling. The current defaults use 8-second windows and 4-second
steps because a safe 75-second group-call excerpt formed fewer clusters than
with 3-second windows. This is only an exploratory result, not a quality
benchmark: speaker identity and attribution still require validation against
manually annotated turns. Mixed group-call audio and overlap can make short
turns particularly unreliable; unmatched voices stay `Speaker N` rather than
being assigned a low-confidence profile name.

**3b. Wire into `transcribe.py`:**

- Add a helper `is_group_call(metadata) -> bool` (e.g. `len(attendees) > 2`,
  or lacking better calendar data, just "more than one plausible remote
  attendee" — needs a decision once you see how often group calls actually
  have usable attendee data; `Eng-LT-Meeting`'s sample metadata.json has
  `attendees: []`, so don't gate solely on attendee count — falling back to
  "always try diarization+ID on `system.m4a`, and if diarization finds only
  one cluster, behave exactly like today" is simpler and more robust than
  trying to pre-detect group calls from calendar metadata).
- When processing the system track: instead of assigning every segment the
  single `remote_label`, run `diarize()` on `system.m4a`, then for each
  Whisper segment find the diarized span it falls inside and look up that
  span's speaker via `match_speaker()`. Label format: matched name if above
  threshold, else `"Speaker 1"`, `"Speaker 2"`, ... (stable per-session
  numbering by first-appearance order) for unmatched clusters.
- Keep the existing 1:1 fast path unchanged when diarization finds exactly
  one cluster in `system.m4a` — no behavior change for the common case,
  and it avoids paying the diarization+embedding cost on every 1:1 ever
  transcribed.

**3c. Tests:** extend `test_transcribe.py` (or a new
`test_speaker_embed.py`) with the synthetic-vector matching test from Phase
2, plus a test that a single-cluster diarization result on a session
produces the same transcript as today's code path (mock `diarize()` to
return one big span, assert the label matches `speaker_labels()`'s existing
output).

## Suggested delivery order

1. `speaker_embed.py`: `embed_audio` / `embed_window` only, no tests needing
   real ML deps beyond "does it run on one real file and produce a
   192-length vector."
2. `enroll_speakers.py` + run it against real `~/MeetingRecordings` data,
   eyeball the resulting profile files (names, session counts) before
   trusting them.
3. `match_speaker()` + unit tests (synthetic vectors, no audio needed).
4. `diarize()` alone, run against one real group-call `system.m4a`, print
   the spans, sanity-check span count/duration against what you know about
   that meeting (how many people talked, roughly how long each).
5. Wire steps 3+4 into `transcribe.py`, re-transcribe one known group
   session, read the output.

Each step is independently testable without the next one existing yet —
don't build 3–5 before confirming 1–2 produce sane profiles on your actual
recordings.
