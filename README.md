# meeting-recorder

Minimal Granola-style meeting recorder + offline transcription for macOS.
The app itself is called **Dott** (arbitrary name, matches its single-dot
menu-bar glyph — no deeper meaning).

Two independent pieces:

- **`Dott/`** — a Swift menu-bar app. One `ScreenCaptureKit` stream
  captures system audio (the other participants, whatever's coming out of
  your speakers/AirPods) *and* the microphone (you) on a shared clock, and
  writes them to two separate WAV files per session. No virtual audio device,
  no BlackHole, no manual routing. The menu-bar icon is a plain `○`/`●`
  glyph, no text, so it stays unremarkable during screen sharing.
- **`transcribe/`** — a Python script using `mlx-whisper` (Apple Silicon,
  fully offline) to transcribe both files and merge them into one
  chronological, speaker-labeled transcript.

Recordings land in `~/MeetingRecordings/<timestamp>/{mic.wav,system.wav}`.

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
**Microphone** access (System Settings > Privacy & Security). Grant both,
then click Start Recording again. Because the app is ad-hoc signed with a
fixed bundle identifier, these grants persist across rebuilds (but changing
the bundle id or moving the app to a new location, as we just did, counts
as a new app to macOS and needs a fresh grant once).

Click the menu-bar `○` icon to Start/Stop. Files show up under
`~/MeetingRecordings/`. To rebuild after editing source, re-run
`./build_app.sh` and re-copy to `/Applications/`.

## Transcribing

```bash
cd transcribe
python3 -m venv .venv && ./.venv/bin/pip install -r requirements.txt
./.venv/bin/python transcribe.py ~/MeetingRecordings/<session>
```

Writes `transcript.md` in that session's folder. First run downloads the
Whisper model (`mlx-community/whisper-large-v3-turbo` by default) from
Hugging Face — after that it's fully offline.

## Known limitations (MVP)

- Requires macOS 15+ (uses `SCStreamConfiguration.captureMicrophone`).
- No live transcription — record now, transcribe after.
- Speaker labels are just "Me" (mic) vs "Them" (system audio) — good enough
  for 1:1 or small calls, doesn't distinguish multiple other participants.
- No app icon / signing beyond ad-hoc — fine for local use, not for sharing.
