# call-notch

A small macOS menu-bar app that extends the MacBook notch to the left while a
voice call is running, in the style of boring.notch. One amber ball listens
and pulses with the voice; while a question is delegated to Claude Code it
splits into a twin-orbit loader, then merges back like liquid when the
answer is spoken.

It is driven by `~/.claude-call/state.json`, written by the voice bridge in
the `/call` skill of my course notes bundle:

```json
{"state": "listening" | "thinking" | "speaking" | "off", "level": 0.0}
```

The app quits on `off` or when the file goes stale for 3 s.

## Build and try

```bash
swift build -c release
python3 drive.py & .build/release/CallNotch
```

`drive.py` plays a scripted call (listening → thinking → speaking → off) so
the app can be run without a real session.
