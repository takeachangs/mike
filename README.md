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
