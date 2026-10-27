# CLAUDE.md

Guidance for Claude Code when working in this repository.

# What this is

Mike, a Mac app that lives in the MacBook notch. On its own it makes plain GPT-Live voice calls (`gpt-live-1`, user's own OpenAI key), records lectures with on-device transcription (Parakeet Ultra via FluidAudio), keeps a Library of both, and dictates into any app on the right ⌘ key. It is also the notch for a coding-agent workflow: `bridge.py` runs agent-mode calls (client delegation, answered by an agent session on a notes folder) and the `Listen` command records for the `/listen` skill. `README.md` is the human overview, `SETUP.md` is the agent-mode install procedure for a coding agent.

# Layout

```
app/Package.swift                    one SwiftPM package; FluidAudio is its only dependency
app/Sources/MikeKit/            the library everything else is built on
  Recorder.swift                       mic (or a file played in real time) -> Parakeet Ultra -> per-minute transcript; state file; cues
  Dictation.swift                      the right-⌘ hold/tap/Esc rules (DictationKey), and mic-into-memory -> Parakeet in one pass, model kept loaded
  LiveCall.swift, LiveProtocol.swift   the solo GPT-Live call: WebSocket protocol codec, mic/speaker audio, state file, transcript file
  StateFile.swift, Paths.swift         ~/.mike paths, the state file and its 20 Hz ticker, os.Logger categories
  Sessions.swift, Transcript.swift     Library parsing of saved sessions; the per-minute transcript builder
  Cues.swift, Keychain.swift           cue sounds (Resources/sounds, played with afplay); the OpenAI key in the Keychain
app/Sources/Mike/               the app: notch panel and drawing (the dictation aura too), in-app sessions (Launch.swift), dictation's key tap and paste (Dictate.swift), Library and Settings windows
app/Sources/Listen/main.swift        the recorder as a command for the /listen skill; launches the notch if no resident app is up
app/Tests/MikeKitTests/         swift-testing unit tests for the library
app/Resources/                       Info.plist template, entitlements, AppIcon.icns
app/scripts/                         build-app.sh (bundle, sign, notarize, zip), install.sh (safe replace in /Applications), make-icon.swift, make-sounds.py (needs earshot), drive.py
bridge.py                            agent-mode call: Live session, audio, inbox/outbox, state file, notch launch (single file, uv inline deps)
prompt.txt                           the agent-mode voice prompt, generic, read once at bridge start; `~/.mike/prompt.txt` overrides it when present
skill/SKILL.md, skill/listen/SKILL.md  generic copies of the agent-side /call and /listen procedures, installed into a notes folder
.github/workflows/ci.yml             tests and an app build on pull requests and pushes to main; a v* tag (app/scripts/release.sh) publishes the zip and DMG as a release with commit-list notes
```

Runtime state lives outside the repo in `~/.mike/`: `state.json`, `app.pid`, `transcript-<stamp>.json` per call (`{"seconds", "transcript"}`), `listen-<stamp>.txt` per recording (paragraphs starting `HH:MM `) with the agent's `listen-<stamp>.md` notes beside it, and for agent mode `prompt.txt` (personal voice prompt), `context.txt`, `inbox.jsonl`, `outbox.jsonl` and `board/`. Settings (sound volume, onboarded) are in the app's UserDefaults; the OpenAI key is in the login Keychain (`com.takeachangs.mike`).

# Commands

```bash
cd app && swift build && swift test                 # build everything and run the unit tests
cd app && scripts/build-app.sh                      # dist/Mike.app + zip; SIGN_IDENTITY / NOTARY_PROFILE for a release
cd app && scripts/install.sh --open                 # quit the running app, replace /Applications/Mike.app, open it (never cp -R over it)
app/.build/debug/Mike                          # the resident app from a dev build (notch click: Call / Listen / Library / Settings / Quit)
python3 app/scripts/drive.py                        # the notch against a fake session, no call (needs a release build; Ctrl-C stops both)
app/.build/release/Listen out.txt --file x.wav      # play a recording through the recorder in real time, notch included, no mic
uv run bridge.py selftest                           # bridge offline checks, no API call, prints ok
uv run bridge.py                                    # an agent-mode call (bills per second; see Rules)
uv run bridge.py say  ID "text" / note ID "text"    # spoken result / quiet progress for delegation ID
```

# How sessions run

- **App, solo call**: Settings' key (or `OPENAI_API_KEY`) -> `LiveCall` in the app process. Hang-up is the card's button, the voice saying the sign-off, or silence (Settings: Never / 15-90 s, default 30): silence means no transcribed user words and no voice audio, never mic loudness, with the `wait` cue 10 s before, and a muted call never times out. The transcript is saved like bridge.py's.
- **App, recording**: `Recorder` in the app process, into `~/.mike/listen-<stamp>.txt`. The model downloads on first use with progress in the card (or ahead of time from Settings).
- **Agent-mode call**: `bridge.py` opens the Live session (seeding `context.txt`, capped at 4000 characters), writes delegations `{"id", "offset_ms", "transcript"}` to the inbox, forwards the agent's `say` / `note` from the outbox, and on hang-up (Ctrl-C, the notch's button, the sign-off, 60 s idle after a nudge at 30 s) writes `{"event": "closed", "seconds", "transcript"}` to the inbox and saves the transcript file.
- **App, dictation**: a CGEventTap (needs Accessibility) watches right ⌘ alone; hold to talk, tap to latch and tap to stop, Esc cancels a latched one (swallowed), a chord is a shortcut and discards the capture. The notch's dots cycle while the model loads or the clip transcribes and open into the breathing circle, with the `start` cue, once you can speak (that cue's audio is cut from the clip); `stop` after an insert, `pause` on a cancel or nothing heard. On stop the clip is transcribed in one pass and pasted with a synthesized ⌘V, the pasteboard restored 0.5 s later. Ignored while a call or recording runs; never writes the state file. Settings toggles it (`dictation`, default on).
- **Skill recording**: `Listen <path>` (the binary inside Mike.app, or `app/.build/release/Listen`), stopped by Ctrl-C or the notch's stop button.

# Contracts that must not drift

Changing any of these means changing every side in the same commit.

- **`Hanging up now`**: `SIGN_OFF` in `bridge.py`, the "Ending the call" section of `prompt.txt`, `SOLO_INSTRUCTIONS` in bridge.py and `LiveCall.soloInstructions` (identical text), and both skill files. Hearing it in the output transcript closes the session.
- **`Dates you may answer directly`** and **`Board open:`**: between `prompt.txt` and the /call skill.
- **`Calling about:`**: `CALLING_ABOUT` in `bridge.py` and the /call skill. First line of `context.txt` when the agent placed the call; the bridge then has the voice open with the reason.
- **State file**: `{"state": "listening" | "thinking" | "speaking" | "off", "level": 0..1, "muted": bool, "pid": int, "mode": "call" | "listen"}`, written atomically every 50 ms even when unchanged, and `off` last. Writers: `bridge.py`, `Recorder` and `LiveCall` (`SessionState`/`StateTicker`). The notch treats a file older than 3 s as a dead session. `muted` means paused for a recording; `thinking` means a delegation has no `say` yet.
- **Session -> notch launch and signals**: a session launches `Mike` with `CALL_BRIDGE_PID` (and `CALL_NOTCH_MODE=listen` for a recording) only when `app.pid` names no live process; that notch quits with the session. The card's mute/pause sends SIGUSR1 and hang-up/stop sends SIGINT to the state file's `pid` (or `CALL_BRIDGE_PID`); for a session inside the resident app it calls the session directly.
- **Resident app**: `Mike` without `CALL_BRIDGE_PID` stays at the notch, writes `app.pid` (removed whenever it quits: every quit goes through the app delegate, which first stops and saves its own session; a second copy exits) and shows any session from the state file.
- **Cue sounds**: `start` (also resume/unmute), `pause`, `stop`, `wait`, `ready` in `app/Sources/MikeKit/Resources/sounds/`, played with `afplay -v <volume>` (default 0.25, `0` = off) by bridge.py, the app, Listen, and the listen skill through `Listen --cue ready` (never a path inside the bundle: its layout depends on the SwiftPM version). The app takes the volume from Settings; bridge.py and Listen from `CALL_SOUND_VOLUME`. bridge.py's `selftest` and the Swift tests check the files exist.
- **Transcript files**: calls `{"seconds": number|null, "transcript": [[role, text], ...]}` (older ones are a bare list); recordings `HH:MM text` paragraphs. `Session.parse` reads both; keep it in step with the writers.
- **Inbox and outbox line shapes**, as above. The bridge truncates outbox content at 1500 characters and empties both files at call start, so an agent can count lines from zero.
- **Audio**: 24 kHz mono int16 PCM both ways for GPT-Live.

# Rules

- **Never start a real call unless asked**: `uv run bridge.py` and the app's Call open a billed session and the microphone. Test with `selftest`, the Swift tests, `drive.py`, or hand-written inbox lines.
- **Never start a recording on the mic unless asked.** Test with `Listen --file`.
- **The key stays out of files.** It lives in the Keychain or the environment. Never write it into the repo or anywhere else.
- **Keep the repo out of iCloud-synced folders** (`~/Documents`, `~/Desktop`): the Swift build directory churns.
- **Keep it small.** One package, FluidAudio as the only Swift dependency, `bridge.py` one file with three. No abstractions with one user, no config files. A deliberate shortcut gets a `ponytail:` comment naming its ceiling.
- **`prompt.txt` stays generic**, like `skill/`: personal details go in `~/.mike/prompt.txt`.
- **`skill/` stays generic.** No names, courses, or paths from any one person's notes folder; the installed copy is where personal details go.
- **Test what can be tested offline**: extend the Swift tests for library logic (parsing, transcript, protocol, state) and `selftest` for bridge logic.
- **Bundle resources** are found through `Cue.resources` (Contents/Resources first), not `Bundle.module`, which only looks at the .app's top level, where code signing forbids files.
- Voice sessions bill for every second they are open, including silence and time spent waiting on the agent.

# Known gaps

- No echo cancellation in either call path: on laptop speakers the voice can hear itself and the cue sounds. Headphones avoid it.
- Audio already queued keeps playing after the user interrupts the voice.
- A recording and a call both own `state.json`; run one at a time (the app enforces this for its own sessions).
- Recording minute stamps count audio samples: a gap (an input device switch, the Mac sleeping) shifts later stamps earlier by its length.
- Signing is ad-hoc unless `SIGN_IDENTITY` is set; an ad-hoc app runs only on the Mac that built it, and after each rebuild macOS may ask again for microphone and Keychain access, and Accessibility (dictation) has to be re-granted: the old grant stays pinned to the previous build's cdhash (tccd logs "Failed to match existing code requirement"), so run `tccutil reset Accessibility com.takeachangs.mike` and allow it again. The app logs that it skipped the key tap at `.error`.
- Dictation starts the mic on right-⌘ down, so a right-⌘ shortcut briefly lights the mic indicator. Its ⌘V is key code 9, V on ANSI layouts only.
- `drive.py` ignores a running resident app, so with one up you see two notches during the drive.
- `seconds` is null when `session.closed` never arrives within 5 s and no usage update came before.
