# call-notch

A voice front end for my course-notes bundle. OpenAI GPT-Live handles the
mic and speaker; a Claude Code session answers from the notes; a small
macOS app extends the MacBook notch to the left while the call runs, in
the style of boring.notch.

```
bridge.py     GPT-Live session (client delegation). Delegations go to
              ~/.claude-call/inbox.jsonl; replies come back via
              `bridge.py say ID "text"` / `bridge.py note ID "text"`.
prompt.txt    the voice model's instructions
notch/        the notch indicator (SwiftUI), driven by ~/.claude-call/state.json
```

The Claude Code side is a skill in the notes bundle (`.claude/skills/call/`)
that watches the inbox and answers each delegation.

## Set up

Tell your coding agent to "set this up" and point it at [SETUP.md](SETUP.md).
It checks the prerequisites, builds the app, tests the key, personalises
the prompt and installs the agent-side skill from `skill/` into your notes
folder.

## Run

```bash
cd notch && swift build -c release && cd ..   # once, and after editing Sources/
uv run bridge.py                              # start a call; Ctrl-C hangs up
```

Needs `OPENAI_API_KEY` in the environment. To try the notch app without a
call: `cd notch && python3 drive.py & .build/release/CallNotch`.

## State file

```json
{"state": "listening" | "thinking" | "speaking" | "off", "level": 0.0}
```

`thinking` while a delegation is pending, `speaking` while audio is playing,
`level` is the mic or speaker RMS in 0–1. The app quits on `off` or when the
file goes stale for 3 s. Saying "Hanging up now." (the prompt's fixed
sign-off) closes the session.

## /listen

`listen/` is a second, separate feature: it transcribes a lecture live on
the Mac (Parakeet Ultra on the Neural Engine, no audio saved, nothing
uploaded) into `~/.claude-call/listen-<stamp>.txt`, one paragraph per
clock minute, and shows it in the notch (its pause and stop buttons). The
agent-side skill (`skill/listen/`) starts it and writes a summary, key
points and to-dos next to the transcript when it stops.

```bash
cd listen && swift build -c release        # once, and after editing Sources/
```

## Sounds

Both the call and `/listen` play short, quiet cues from `sounds/` (start,
pause, stop, waiting, answer ready). `CALL_SOUND_VOLUME` sets the level
(`afplay -v`, default 0.25) and `0` turns them off. `sounds/make.py`
renders them with [earshot](https://github.com/Leonxlnx/earshot)'s DSP.

## The notch app on its own

Start the notch app by itself and it stays at the notch: click the notch
for Call (a plain GPT-Live conversation, `bridge.py solo`, no agent),
Listen (a recording) or Library (every past call and recording as a card
you can open and search). Sessions a skill starts show up in it too.

```bash
cd notch && swift build -c release && .build/release/CallNotch
```
