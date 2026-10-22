---
name: call
description: Start a voice call where GPT-Live handles the mic and speaker and this agent session answers from the notes folder. Use when the person types /call or asks to start a call or talk to their notes by voice.
---

# /call — voice front end, this session as the brain

The tool lives in `~/projects/mike`: `bridge.py` runs the OpenAI Live session on the mic and speaker with the voice prompt from `prompt.txt`, and Mike.app (from `app/`) is the notch. Every question the voice cannot answer itself becomes a delegation line in `~/.mike/inbox.jsonl`. You answer each one from the notes folder and hand the text back with `bridge.py say`.

## Steps

1. Write `~/.mike/context.txt` so the voice knows what this chat is working on. A few plain sentences on the current task (what is open, which step you reached), then any short dated facts the voice may answer without asking you, under this exact heading:

   ```
   Dates you may answer directly:
   - Assignment 3 due Friday 14 November, 11:59 pm
   ```

   Keep the whole file under 4000 characters; the bridge cuts it there. Leave the heading out if there are no dates. Anything else the voice is asked still comes to you as a delegation.

2. Start the bridge in a terminal tab the person can see and stop with Ctrl-C:

   ```bash
   uv run ~/projects/mike/bridge.py
   ```

   Use the tool's "run in a terminal tab" action, not a blocking shell call, so the tab stays open. Wait for it to print `call started`. If the notch app is built, the bridge starts it with the call and closes it on hang-up.

3. Watch the inbox with a file watcher that wakes you on each new line:

   ```bash
   tail -n0 -F ~/.mike/inbox.jsonl
   ```

4. For each line with an `id`:
   - Read the `transcript` (last turns, user and assistant). The last user turn is usually the question; earlier turns carry corrections. The assistant's last line tells you the mode: a plain "I'll check…" wants a spoken answer; "I'll put it up" / "on screen" wants a board (step 5).
   - If it will take more than a few seconds, send a quiet note first: `uv run ~/projects/mike/bridge.py note <id> "Checking the week 4 notes."`
   - Answer from the notes folder, read-only. The folder's own rules file still applies.
   - Reply with `uv run ~/projects/mike/bridge.py say <id> "<answer>"`. Spoken answer: at most four sentences, plain words, no markdown, no file paths, numbers and dates said in full. Lists: three items, then "there are N more". The bridge truncates at 1500 characters.
   - If the question needs a decision or a write (a calendar event, a log row), say what you would do and ask; write only after the person says yes on the call.

5. Board mode, for a derivation, proof, formula or plot:
   - Write a page to `~/.mike/board/<slug>.html`: one `<h1>`, numbered steps each in `<section id="step-N">`, MathJax tex-svg from cdnjs, large type, nothing else. Open it with `open ~/.mike/board/<slug>.html` (default browser).
   - Reply with a `say` that begins `Board open: <title>.` followed by one short line per step, at most four, and `Ask about any step by number.` The voice asks whether the person can see it before starting.
   - Follow-ups about a step come back as new delegations. Edit the same page (add a `class="now"` highlight on that section, append the explanation under it), re-open it, and `say` the explanation in plain words. Never send the page content to the voice; it only gets the outline.
   - If the delegation says the board is not showing, run `open` again and `say` "Board open:" again.

6. Hanging up: when the person says they are done, the voice says goodbye ending in "Hanging up now." and the bridge closes the session on its own. The bridge also hangs up by itself after about 90 seconds with no speech and nothing pending. The line `{"event": "closed", "seconds": ..., ...}` then ends the call: stop the watcher and write a short log entry wherever the notes folder keeps session logs: call length (`seconds`, the billed duration), what was asked, any boards, anything written.

## Without a watcher

If the tool cannot wait on a file, poll instead: after step 2, loop on `tail -n +<last line> ~/.mike/inbox.jsonl` every two seconds, handling new lines as in step 4, until the closed line arrives. Slower, but the same protocol.

## The notch app

Mike.app (built and installed by SETUP.md step 2) is the notch. If it is already running on its own, it shows the call; otherwise the bridge starts it for the length of the call. After pulling changes, rebuild and reinstall:

```bash
cd ~/projects/mike/app && scripts/build-app.sh && scripts/install.sh
```

To try it without a call: `python3 ~/projects/mike/app/scripts/drive.py` (after `swift build -c release` in `app/`), which launches the notch against a fake bridge.

## Notes

- `~/.mike/` holds runtime state: `context.txt`, inbox, outbox, `state.json`, each call's transcript, and `board/`.
- `prompt.txt` in the repo is the voice prompt. Edit it there; the bridge reads it at start.
- The OpenAI key comes from `OPENAI_API_KEY` in the shell. Never copy it anywhere.
- Each call costs OpenAI credits per minute. Do not start one without being asked.
