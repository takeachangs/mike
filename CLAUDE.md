# CLAUDE.md

Guidance for Claude Code when working in this repository.

# What this is

A voice front end for a coding-agent session. OpenAI GPT-Live (`gpt-live-1`, client delegation) handles the mic and speaker; an agent session open on some notes folder answers the questions; a small macOS app shows the call state in the MacBook notch. A second, separate feature, `/listen`, transcribes a lecture on-device (Parakeet Ultra via FluidAudio) and shows it in the same notch; the agent session writes notes from the transcript afterwards. `README.md` is the human overview, `SETUP.md` is the install procedure for a coding agent.

# Layout

```
bridge.py                         the whole bridge: Live session, audio, inbox/outbox, state file, notch launch (single file, uv inline deps)
prompt.txt                        the voice model's instructions, read once at bridge start; personalised for its owner
notch/Sources/CallNotch/main.swift  the notch indicator (SwiftUI in an NSPanel), one file
notch/drive.py                    fake bridge: launches the app, cycles states into state.json, answers its mute/hang-up signals; test without a call
listen/Sources/Listen/main.swift  the /listen recorder: mic -> Parakeet Ultra on the Neural Engine -> per-minute timestamped transcript; drives the notch like the bridge (one file, FluidAudio its only dependency)
sounds/*.wav, sounds/make.py      the cues both sides play (start, pause, stop, wait, ready) and the script that renders them (needs an earshot install; not a runtime dependency)
skill/SKILL.md                    generic copy of the agent-side /call procedure, installed into a notes folder by SETUP.md
skill/listen/SKILL.md             generic copy of the agent-side /listen procedure
```

Runtime state lives outside the repo in `~/.claude-call/`: `context.txt` (written by the skill, optional), `inbox.jsonl`, `outbox.jsonl`, `state.json`, `transcript-<stamp>.json` per call (`{"seconds", "transcript"}`), `board/`, and per `/listen` a `listen-<stamp>.txt` transcript (paragraphs starting `HH:MM `) with the agent's `listen-<stamp>.md` notes beside it.

# Commands

```bash
uv run bridge.py selftest                      # local checks only, no API call, prints ok
uv run bridge.py                               # start a real call (bills per second; see Rules)
uv run bridge.py say  ID "text"                # spoken result for delegation ID
uv run bridge.py note ID "text"                # quiet progress for delegation ID
cd notch && swift build -c release             # build the app; needed after any edit under notch/Sources/
cd notch && python3 drive.py                   # run the app against a fake bridge, no call (Ctrl-C stops both)
cd listen && swift build -c release            # build the recorder; needed after any edit under listen/Sources/ (first build ~3 min)
listen/.build/release/Listen out.txt --file x.wav   # play a recording through the recorder in real time, notch included, no mic
```

# How a call flows

1. `bridge.py` opens the Live session (seeding `context.txt`, capped at 4000 characters, as a developer message if it exists), starts the mic and speaker streams, and launches `notch/.build/release/CallNotch` if it has been built.
2. When the voice model delegates, the bridge appends `{"id", "offset_ms", "transcript"}` to the inbox. `transcript` is the last 12 `[role, text]` turns.
3. The agent answers with `bridge.py say ID "..."`, which appends to the outbox. The bridge tails the outbox and forwards `say` as commentary and `note` as thinking on the Live session.
4. Hang-up is Ctrl-C (also what the notch app's hang-up button sends), the voice saying the sign-off, or 90 s idle (no mic speech above `SPEECH_LEVEL`, no audio out, no pending delegation). All three send `session.close` and wait up to `CLOSE_WAIT` for `session.closed` and its final `usage.seconds`. The bridge then writes `{"event": "closed", "seconds": ..., "transcript": [...]}` to the inbox and saves the transcript file.

# Contracts that must not drift

Changing any of these means changing every side in the same commit.

- **`Hanging up now`**: `SIGN_OFF` in `bridge.py`, the "Ending the call" section of `prompt.txt`, and both skill files. Hearing it in the output transcript closes the session.
- **`Dates you may answer directly`**: the heading `prompt.txt` lets the voice answer from, and the heading the skill writes into `context.txt`.
- **`Board open:`**: the prefix `prompt.txt` tells the voice to expect on a board result, and the prefix the skill tells the agent to send.
- **State file**: `{"state": "listening" | "thinking" | "speaking" | "off", "level": 0..1, "muted": bool}`, written atomically (temp file + `os.replace`, or `Data.write(options: .atomic)` in `Listen`) every 50 ms even when unchanged. `Listen` only ever writes `listening` and `off`, with `muted` meaning paused. The app treats a file older than 3 s as a dead bridge and quits, and also quits on `off` or SIGTERM. `thinking` means a delegation has had no `say` yet. `muted` is the server-side mic mute, so the app shows what the bridge actually did.
- **App → bridge signals**: the bridge launches the app with `CALL_BRIDGE_PID` in its environment. The app's mute button sends SIGUSR1 (bridge toggles `session.input_audio.mute`/`unmute`), its hang-up button sends SIGINT (the Ctrl-C path). Without the variable the buttons only print. `Listen` launches the app the same way, plus `CALL_NOTCH_MODE=listen` so the card reads Recording/Paused with pause/play and stop icons, and answers the same signals: SIGUSR1 pauses (audio replaced by silence so the minute stamps stay on the clock), SIGINT stops (on the mic; a `--file` test run has no stop handler, so Ctrl-C just kills it). Without `CALL_NOTCH_MODE` the card looks like a call.
- **Cue sounds**: `start` (also resume), `pause`, `stop`, `wait`, `ready` in `sounds/`, played with `afplay -v $CALL_SOUND_VOLUME` (default 0.25, `0` = off) by `bridge.py` (call start, mute/unmute, each delegation, its first `say`, hang-up), `Listen` (start, pause/resume, stop) and the listen skill (`ready` once the notes are written). A renamed file means changing all three; `selftest` checks the files exist.
- **Inbox and outbox line shapes**, as above. The bridge truncates outbox content at 1500 characters and empties both files at call start, so an agent can count lines from zero.
- **Audio**: 24 kHz mono int16 PCM both ways.

# Rules

- **Never start a real call unless asked.** `uv run bridge.py` with no arguments opens a billed session and the microphone. Use `selftest`, `drive.py`, or hand-written inbox lines to test.
- **Never start `Listen` on the mic unless asked**: it opens the microphone. Test with `--file`.
- **The key stays in the environment.** `OPENAI_API_KEY` is read by the SDK. Never write it into a file here or anywhere else.
- **Keep the repo out of iCloud-synced folders** (`~/Documents`, `~/Desktop`): the Swift build directory churns.
- **Keep it small.** `bridge.py` is one file with three dependencies, the notch's `main.swift` is one file with none, and the recorder is one file with FluidAudio only. Do not add a dependency, a config file, or a module split for something a few lines can do. A deliberate shortcut gets a `# ponytail:` comment naming its ceiling.
- **`skill/` stays generic** (both skill files). No names, courses, or paths from any one person's notes folder. The installed copy in a notes folder is where personal details and local rules go; the two are allowed to differ.
- **Extend `selftest` when adding bridge logic** that can be checked without the API (file shapes, truncation, level maths).
- Voice sessions bill for every second they are open, including silence and time spent waiting on the agent. Changes that add wait time before a `say` cost money on every call.

# Known gaps

- `SPEECH_LEVEL` (idle guard mic threshold) is a guess; tune it in a real room so typing stays below it and quiet speech stays above.
- A delegation that never gets a `say` keeps the call from idling out; Ctrl-C still ends it.
- Audio already queued keeps playing after the user interrupts (marked `ponytail:` in `speaker()`).
- `/listen` and a call both own `state.json`; run one at a time.
- On laptop speakers without headphones, the `wait`/`ready` cues play into the open mic during a call; whether GPT-Live hears them as barge-in is untested.
- Listen's minute stamps count audio samples: a gap in the audio (an input device switch, the Mac sleeping) shifts later stamps earlier by its length.
- `seconds` is null when `session.closed` never arrives within `CLOSE_WAIT` and no usage update came before.
