# meeting-recorder

Minimal Granola-style meeting recorder + offline transcription for macOS.
The app itself is called **Dott** (arbitrary name, matches its single-dot
menu-bar glyph — no deeper meaning).

Two independent pieces:

- **`Dott/`** — a Swift menu-bar app. One `ScreenCaptureKit` stream
  captures system audio (the other participants, whatever's coming out of
  your speakers/AirPods) *and* the microphone (you) on a shared clock, and
  writes them to two separate AAC (`.m4a`) files per session. No virtual
  audio device, no BlackHole, no manual routing. The menu-bar icon is a
  plain glyph (`○` idle, `●` recording, `⊙` transcribing), no text, so it
  stays unremarkable during screen sharing.
- **`transcribe/`** — a Python script using `mlx-whisper` (Apple Silicon,
  fully offline) to transcribe both tracks and merge them into one
  chronological, speaker-labeled transcript. Dott runs this automatically
  in the background the moment a recording stops — no manual step needed
  in normal use.

Recordings land in `~/MeetingRecordings/<timestamp>/{mic.m4a,system.m4a,transcript.md}`.

## Features

- **Auto-transcription**: fires automatically when a recording stops.
  Recording and transcribing are independent states — starting a new
  recording never waits on a previous one still transcribing in the
  background (verified: `activeTranscriptions` is a `Set<URL>`, and
  `start()`/`stop()` never check it).
- **Auto-record Zoom calls**: `ZoomWatcher` polls the window list for a
  window whose name ends in `"Zoom Meeting"` with `onscreen == true` —
  confirmed empirically to exist only while a call is actually live (Zoom's
  idle/lobby window, `"Zoom Workplace"`, stays onscreen always, so it's not
  a usable signal by itself). Auto-starts/stops recording on that signal's
  edges. Toggle via the menu ("Auto-record Zoom calls", on by default).
  This is what makes back-to-back meetings safe by default: leaving one
  call and joining the next produces two separate sessions instead of one
  recording bleeding into the next.
- **Back-to-back safety**: session folders are named to millisecond
  precision (not just seconds) so two rapid sessions can never collide on
  the same folder, and transcription tracks *which* sessions are in flight
  rather than a single global flag.
- **Silence-hallucination filtering**: Whisper confidently hallucinates
  short phrases ("Thank you.") on near-silent audio (common on the
  system-audio track when no one's talking). `transcribe.py` measures
  actual per-segment audio energy (dBFS) via `ffmpeg` and drops anything
  under -50dBFS, independent of Whisper's own (unreliable, in this case)
  confidence scores.

## Install

```bash
cd Dott
./build_app.sh            # builds, generates Dott.icns, assembles Dott.app
cp -R Dott.app /Applications/
open /Applications/Dott.app
```

Now it's a normal installed app — findable via Spotlight/Launchpad. To have
it start automatically at login: System Settings > General > Login Items &
Extensions > add `/Applications/Dott.app`.

On first "Start Recording", macOS will prompt for **Screen Recording** and
**Microphone** access (System Settings > Privacy & Security) — Screen
Recording specifically requires a full quit + relaunch after granting to
take effect, not just clicking Start again. Grant both, relaunch, then
start recording.

**Signing**: `build_app.sh` signs with a local self-signed certificate
(`Dott Local Signing`), not ad-hoc. Ad-hoc signing (`--sign -`) produces a
new code identity on every rebuild, which makes macOS forget your Screen
Recording/Microphone grants each time you rebuild — the certificate's
stable key pair avoids that entirely. One-time setup if starting fresh on
a new machine: Keychain Access → Certificate Assistant → Create a
Certificate… → Identity Type: Self Signed Root, Certificate Type: Code
Signing, name it exactly `Dott Local Signing` (or update `SIGNING_IDENTITY`
in `build_app.sh` to match whatever you name it).

Click the menu-bar glyph to Start/Stop manually, or just join a Zoom call
and let it happen automatically. Files show up under
`~/MeetingRecordings/`. To rebuild after editing source, re-run
`./build_app.sh` and re-copy to `/Applications/`.

## Transcribing manually

Normally you don't need this — Dott runs it automatically on stop. To
run it by hand (e.g. on an old WAV-era recording, or to retranscribe with
a different model):

```bash
cd transcribe
python3 -m venv .venv && ./.venv/bin/pip install -r requirements.txt
./.venv/bin/python transcribe.py ~/MeetingRecordings/<session>
```

Writes `transcript.md` in that session's folder. First run downloads the
Whisper model (`mlx-community/whisper-large-v3-turbo` by default) from
Hugging Face — after that it's fully offline. Requires `ffmpeg`
(`brew install ffmpeg`).

## Known limitations (MVP)

- Requires macOS 15+ (uses `SCStreamConfiguration.captureMicrophone`).
- No live transcription — record now, transcribe after (automatically, but
  not in real time).
- Speaker labels are just "Me" (mic) vs "Them" (system audio) — good enough
  for 1:1 or small calls, doesn't distinguish multiple other participants.
- Zoom auto-record is a window-title heuristic, not an official API — a
  Zoom client update could change its window titling and silently break
  it. Google Meet/Teams aren't wired up (same technique would apply, just
  need their actual window signatures).
- `MeetingCapture`'s paths to the `transcribe/` venv are hardcoded to
  `~/src/meeting-recorder` — this is a personal single-machine tool, not
  built to be relocatable.
