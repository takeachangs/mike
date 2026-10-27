# Mike — design spec and progress

What the app is meant to look and feel like, the decisions behind it, and where the work stands. `README.md` is the user-facing overview; `CLAUDE.md` is the working guide for a coding agent; this file is the design record. Update it when a decision changes, not for every commit.

## Product

A Mac app that lives in the MacBook notch. One click away: **Call** (a GPT-Live voice call on the user's own OpenAI key), **Listen** (live on-device lecture transcription with Parakeet Ultra), a **Library** of both, and **Settings**. It is also the notch for a coding-agent workflow (`bridge.py`, the `/call` and `/listen` skills).

Principles:
- The notch is the app. No Dock icon, no menu bar icon; a small black tab beside the hardware notch is the whole presence.
- Quiet. Monochrome white dots, no colour except the amber of an alert label, no borders or glows. Motion only where it tells the user something (a state) or keeps a change from jarring.
- Nothing leaves the Mac from Listen; audio is never written to disk anywhere.
- One small repo: one SwiftPM package, one Python file for agent mode, no config files.

## The notch

Geometry (`app/Sources/Mike/Geometry.swift`): the panel sits over the hardware cutout (`NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`; a centred 180 × 24 pt stand-in when there is no cutout). A 42 pt **tab** hangs to the left of the notch with a 12 pt rounded bottom-left corner, square at the top like the cutout itself (the "ears" of Dynamic-Island clones were tried and removed: against a bright menu bar their first points are sub-pixel and read as a kink). 10 pt of panel margin on each side.

The tab is out from launch while the resident app runs, and folds into the notch on quit (0.3 s). A session-launched notch (bridge.py, Listen CLI) shows the tab only while the session runs.

### The dots

Seven white 3 pt dots in a 24 pt box centred 20 pt left of the notch, on a 28-unit stage like the reference. Their resting shape is a lowercase **m**: two arches on flat feet. Coordinates (y down, in `Notch.mShape`): left foot (−7, 4), left shoulder (−7, −1.5), left top (−3.5, −5.5), valley (0, −1), right top (3.5, −5.5), right shoulder (7, −1.5), right foot (7, 4). The letter sits 0.75 units above centre in the notch (two feet make an exactly centred letter look low); the icon centres it exactly.

Reference: the morph family of aicss.dev's "orbs" (8 dots that glide between arrangements on a 4.8 s timeline: 5 % holds, 20 % glides, `cubic-bezier(0.4, 0, 0.2, 1)`). Mike's indicator is written from scratch in SwiftUI Canvas with those timings and its own shapes; nothing of theirs is copied.

| State | Dots |
| --- | --- |
| Idle, card closed | the m, still (the timeline is paused: an idle app costs no frames) |
| Card open | the m glides into a circle of radius 7 (0.3 s spring) and back on close |
| Waiting: model loading, connecting, the voice thinking | the morph cycle: m → circle → quarter turn → quarter turn → gather through the centre → m, 4.8 s |
| Call, listening | the circle, breathing: a 3 s swell at rest, growing (+20 %) and brightening with the mic level |
| Call, voice speaking | the circle unfolding by quarter turns (the reference's M3) |
| Recording | the m, with a soft glow walking foot to foot every 2.8 s; dots swell with the level |
| Paused / muted | the m dimmed to 0.35, the valley dot lit |

Each m dot pairs with the circle slot nearest its own angle (the valley takes the top), so every glide expands outward rather than crossing. One spring (`morph`) blends the resting shape with the cycle on state changes; another (`round`) blends m ↔ circle. Reduce Motion holds the m and keeps only the level-driven brightness. Hover grows the dots 10 %, press shrinks them to 90 %.

### The card

Opening grows the card out of the closed shape (tab + notch) rather than sliding a sheet down: width and height on two critically damped springs, width leading on open (0.26 / 0.30 s), height leading on close (0.26 / 0.34 s), so a close ends as a notch-tall pill narrowing into the cutout. Corner radius 12 → 20 pt. Content is clipped to the live shape, fades in 180 ms after a short stagger (80 / 120 ms, skipped when reopening a mostly open card), out in 90 ms, and is not clickable until the height spring passes 0.8. The idle card is 80 pt and holds only the five actions (Call, Listen, Library, Settings, Quit); a session card is 116 pt with the status, a timer and the pause/mute and stop/hang-up buttons. A notice ("Recording saved to Library", an error) grows the idle card to 116 pt on a spring. Leaving the card for 100 ms closes it. Reduce Motion cross-fades the full card instead.

Everything is drawn in one `Canvas` inside a `TimelineView` that runs at the display rate while anything moves and pauses when nothing does. The spring step runs inside the Canvas closure on purpose: a closure that captures only the model compares equal frame to frame and SwiftUI skips the redraw.

### Cue sounds

Five short, quiet cues (earshot "tight bloom" set): `start` (also resume/unmute), `pause`, `stop`, `wait` (10 s before a silent call hangs up), `ready` (notes written). Default volume 0.25; 0 turns them off.

## Icon

The seven dots at rest as the m, white, on Apple's squircle grid (824/1024, superellipse exponent 5) with the dark top-to-bottom gradient of the system's dark icons (0.16 → 0.04). Dot diameter 9.5 % of the icon, 7 units = 21 %. Generated by `app/scripts/make-icon.swift`, which must stay in step with `Notch.mShape`.

## Sessions

- Call: GPT-Live (`gpt-live-1`) over WebSocket, 24 kHz mono PCM both ways. Hang-up by the button, the voice's sign-off ("Hanging up now"), or silence (no transcribed user words and no voice audio; default 30 s, Settings offers Never / 15 / 30 / 60 / 90). Playback is tracked by the clock, never by audio callbacks.
- Listen: Parakeet Ultra on the Neural Engine via FluidAudio's sliding-window streaming; one paragraph per clock minute (`HH:MM text`); the model (~600 MB) downloads on first use with progress in the card. The session timer starts when the recorder is live, not while the model loads.
- The state file contract and the signals are in `CLAUDE.md`.

## Settings

Microphone access, speech model download, OpenAI key (Keychain), hang-up-after-silence, sound volume, open at login, data folder, version. First launch shows the same view as a welcome window with a Done button. **Planned:** split into toolbar tabs per feature — General, Listen, Call — so the Call tab can later sit behind a paywall with a single gate.

## Distribution

- `app/scripts/build-app.sh`: bundle, Info.plist, ad-hoc or Developer ID signing, notarization and stapling when `NOTARY_PROFILE` is set, a zip and a DMG (app beside an Applications link).
- `app/scripts/release.sh <version>`: writes `app/VERSION`, commits, tags `v<version>`, pushes. CI (`.github/workflows/ci.yml`, macos-15) tests and builds on every push and PR; on a `v*` tag it publishes the zip and DMG with release notes listing every commit since the previous tag, followed by GitHub's generated section.
- Unsigned for now: the README tells users to run `xattr -dr com.apple.quarantine /Applications/Mike.app` once. Developer ID signing and notarization need a paid Apple Developer account; the scripts already support it.
- Homebrew: a personal tap cask (with a quarantine-stripping postflight while unsigned) is the next channel; the official homebrew-cask needs a signed app and some stars.

## Workflow

Every change goes through a branch and a pull request, made by a subagent in its own worktree where possible; `main` is never pushed to directly. The user merges and tags releases. Real calls and mic recordings are only ever started by the user (calls bill per second).

## Progress

- 2026-10-09 — First notch indicator for the agent-mode voice call (`bridge.py`).
- 2026-10 (mid) — `/listen`: live on-device transcription with per-minute stamps; cue sounds; the resident app with Call / Listen / Library / Settings; the app made production-grade (signing, CI, install script, tests, onboarding, silence hang-up, clock-based playback).
- 2026-10-22 — The card morphs out of the notch instead of sliding; rim and ears tried and removed; Canvas repaint bug fixed; renamed CallNotch → Mike (app, bundle id, repo, `~/.mike`); DMG + commit-list release notes + `release.sh`; icon explorations (orbit, m-trail, dot families) settled on the seven-dot m; indicator rebuilt on the dot vocabulary with per-state motion; idle card shortened; tab always out; hold-right-⌘ dictation built and reverted the same day; PR workflow adopted.

## Backlog

- Settings tabs per feature (General / Listen / Call) — in progress.
- Paywall for Call (gate the Call tab and the Call action; Listen stays free).
- Developer ID signing + notarization once an account exists; then the Homebrew tap, then in-app updates (Sparkle).
- Hide the tab on displays without a hardware notch (it currently draws a notch body in the menu bar there).
- Retest the silent-call hang-up on the current build (user-run).
- Echo cancellation on laptop speakers; the voice can hear itself.
- bridge.py's idle guard still uses mic loudness; the app's uses transcribed speech.
- Dictation (hold right ⌘, speak, release, paste): built once, reverted; the Recorder exposes `transcript` for it if it returns.
