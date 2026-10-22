# Setting up call-notch

Instructions for a coding agent (Claude Code, Codex, Gemini CLI, Cursor, or
similar). The person has asked you to "set this up". Read this whole file,
then do the steps in order. Ask the person only where a step says so.

What you are setting up: a voice call where OpenAI GPT-Live handles the
mic and speaker, and **you** (the coding agent, in a session open on the
person's notes folder) answer the questions. A small macOS app shows the
call state in the MacBook notch. Nothing here reads or writes the person's
notes on its own; the agent session does that, under the notes folder's
own rules.

## 0. What has to exist already

Check each of these and tell the person what is missing before you build
anything.

| Needs | How to check | If missing |
| --- | --- | --- |
| macOS 14 or newer on Apple Silicon | `sw_vers -productVersion`, `uname -m` prints `arm64` | the app needs Apple Silicon (the speech model runs on the Neural Engine); the bridge alone also runs elsewhere, with no notch |
| Xcode 16 or its command line tools (Swift 6) | `xcrun swift --version` | `xcode-select --install` (needs the person's password; ask them to run it) |
| `uv` | `uv --version` | https://docs.astral.sh/uv/ , `brew install uv` |
| an OpenAI API key with GPT-Live access | `echo ${OPENAI_API_KEY:+set}` prints `set` | the person creates one at platform.openai.com and puts `export OPENAI_API_KEY=...` in their shell profile. Never write the key into any file in this repo or the notes folder. |
| a notes folder with an agent rules file (`CLAUDE.md`, `AGENTS.md`, …) | ask the person for the path | the call answers from this folder; without it there is nothing to answer from |

A MacBook with a notch is optional. Without one the app draws a tab at the
top centre of the screen instead.

## 1. Get the code

```bash
git clone https://github.com/takeachangs/call-notch ~/projects/call-notch
```

Any location works as long as it is **not** inside a folder that syncs to
iCloud Drive (on macOS, `~/Documents` and `~/Desktop` usually do). The
Swift build directory churns and would upload on every compile.

## 2. Build and install the app

```bash
cd ~/projects/call-notch/app && scripts/build-app.sh && scripts/install.sh
```

The first build fetches FluidAudio and takes a few minutes. Expect
`built dist/CallNotch.app`. The bridge and the skills use the installed
copy in `/Applications` (the notch, and the `Listen` command inside it).
Then prove the notch draws, without any API call:

```bash
cd ~/projects/call-notch/app && swift build -c release && python3 scripts/drive.py
```

For about eleven seconds a black tab grows to the left of the notch: one
amber ball, then two balls orbiting it, then one ball pulsing, then the tab
collapses and the app quits. If the app does not appear, see
Troubleshooting.

## 3. Check the bridge can reach GPT-Live

This opens a session and closes it immediately. It costs nothing
noticeable and confirms the key has GPT-Live access:

```bash
cd ~/projects/call-notch && uv run bridge.py selftest
```

prints `ok` (local checks only). Then:

```bash
cd ~/projects/call-notch && uv run --with 'openai>=3.27' --with websockets python - <<'PY'
import asyncio
from openai import AsyncOpenAI
async def main():
    async with AsyncOpenAI().live.connect() as conn:
        await conn.session.start(session={"model": "gpt-live-1", "delegation": {"type": "client"},
            "instructions": "test", "audio": {"format": {"type": "audio/pcm", "rate": 24000}}})
        async for ev in conn:
            print(ev.type)
            if ev.type == "session.started": await conn.session.close()
            if ev.type in ("session.closed", "error"): break
asyncio.run(asyncio.wait_for(main(), 40))
PY
```

Expect `session.started` then `session.closed`. An `error` event means
the key lacks access or the model name has changed; show the person the
error text.

## 4. Personalise the voice prompt

Open `prompt.txt`. It is written for its original owner. Change, with the
person's answers:

- **Role and Objective**: the person's name, and the name of the agent
  that answers ("Claude Code" → whatever they use).
- **Language**: the default language, and the course codes or jargon the
  voice should spell out letter by letter, plus any pronunciations.
- Leave the **Delegation**, **Board**, **Verbosity**, **Unclear Audio**,
  **Corrections** and **Ending the call** sections as they are. The bridge
  depends on two exact strings in them: results that begin `Board open:`
  and the sign-off `Hanging up now.`

Ask the person: their name, their courses or subjects, and whether they
want a second language.

## 5. Install the skill into the notes folder

The agent side of the call is a procedure the agent follows: start the
bridge, watch an inbox file, answer each delegation, hand the text back.
`skill/SKILL.md` in this repo is that procedure, written generically.

- **Claude Code**: copy it to `<notes>/.claude/skills/call/SKILL.md`. It
  becomes the `/call` command at the next session start.
- **Codex, Gemini CLI, Cursor and others**: copy it to
  `<notes>/.agents/skills/call/SKILL.md` if the tool reads that folder, or
  paste its body under a `## /call` heading in the notes folder's
  `AGENTS.md`. The person then types "start a call" instead of `/call`.

Edit the copied file's paths if the repo is not at `~/projects/call-notch`.

The procedure needs two things from the agent's tool set: a way to run a
long-lived command the person can see and stop (a terminal tab), and a way
to be woken when a line is appended to a file (a file watcher or a
`tail -F` the agent can wait on). If the tool has neither, the fallback is
in `skill/SKILL.md` under "Without a watcher".

## 5b. Optional: /listen

Live lecture transcription on the Mac, shown in the same notch. The
recorder is the `Listen` command inside the app installed in step 2.

Copy `skill/listen/SKILL.md` to `<notes>/.claude/skills/listen/SKILL.md`
(or the tool's equivalent, as in step 5). To check it without the
microphone, play any speech recording through it in real time:

```bash
/Applications/CallNotch.app/Contents/MacOS/Listen /tmp/listen-test.txt --file speech.wav
```

The first run downloads the model (about 600 MB). Expect the notch tab
while it plays and `/tmp/listen-test.txt` with paragraphs starting
`HH:MM`.

## 6. First call

With the agent session open on the notes folder, the person says "start a
call" (or `/call`). Check off:

1. The terminal tab prints `call started`, and the notch tab appears.
2. They say hello; the voice answers without delegating.
3. They ask something about their notes. The voice says it will check, the
   notch shows the twin orbit, a line lands in
   `~/.claude-call/inbox.jsonl`, the agent answers with
   `uv run ~/projects/call-notch/bridge.py say <id> "…"`, and the voice
   speaks it.
4. They say "that's all". The voice says goodbye ending in "Hanging up
   now.", the session closes, the notch tab collapses, and the agent sees
   `{"event": "closed"}`.

Calls bill per minute on the OpenAI account. The agent must never start
one without being asked.

## Troubleshooting

- **The shell hangs when the agent sources `.zshrc`**: some plugins block
  non-interactive shells. Read the key from the file instead of sourcing,
  or run the bridge from the person's own terminal tab, which has the key.
- **No sound in or out**: macOS needs microphone permission for the
  terminal app the bridge runs in. System Settings, Privacy & Security,
  Microphone. The first run prompts; if it was denied, the person turns it
  on there.
- **The notch tab draws in the wrong place**: the app reads the notch from
  `NSScreen.main`. With an external display as main, it falls back to a
  centred tab. Make the built-in display the main one, or accept the
  fallback.
- **The notch never folds away**: a session's notch quits on `off` in
  `~/.claude-call/state.json` or when that file is older than three
  seconds; the resident app (started on its own) stays by design and quits
  from its card. If something died hard, `pkill CallNotch`.
- **The voice answers notes questions itself instead of delegating**: the
  Delegation section in `prompt.txt` is the knob. Add the kind of question
  it answered to the list.
- **`-R x,y,w,h` to screencapture fails**: write it without the space,
  `-Rx,y,w,h`.
