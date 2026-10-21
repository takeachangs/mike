---
name: listen
description: Transcribe a lecture or meeting live on this Mac (on-device, nothing uploaded while it listens) with the notch showing it, then write a summary, key points and to-dos from the transcript. Use when the person types /listen or asks to record, transcribe or take notes on a lecture or meeting.
---

# /listen — live on-device transcript, this session writes the notes

The recorder lives in `~/projects/call-notch/listen`. It transcribes the microphone with Parakeet Ultra on the Neural Engine and keeps a transcript with one paragraph per clock minute (`14:05 Alright, so today…`). No audio is saved, and nothing leaves the Mac while it listens. If the notch app is built, it shows the recording like a call: clicking the orb opens a card with a timer, a mute button that pauses listening, and a hang-up button that stops it.

## Steps

1. Build once, and after any edit under `listen/Sources/`:

   ```bash
   cd ~/projects/call-notch/listen && swift build -c release
   ```

   The first run downloads the model (about 600 MB) and takes a minute or two to load.

2. Pick the transcript path, `~/.claude-call/listen-<stamp>.txt` with the stamp from `date +%Y%m%dT%H%M`, and start the recorder in a terminal tab the person can see and stop with Ctrl-C:

   ```bash
   ~/projects/call-notch/listen/.build/release/Listen ~/.claude-call/listen-<stamp>.txt
   ```

   Use the tool's "run in a terminal tab" action, not a blocking shell call. Wait for it to print `listening started`. The first time, macOS asks to let the terminal app use the microphone. Tell the person it is listening and how to stop it.

3. Wait for the recorder to exit, which happens when the person presses Ctrl-C in the tab or the notch's hang-up button:

   ```bash
   while pgrep -x Listen >/dev/null; do sleep 5; done
   ```

   Lectures run for hours, so give the wait a long timeout and start it again if it times out. The transcript file is rewritten as it grows, so it is safe to read at any point.

4. Read the transcript and write the notes next to it, as `~/.claude-call/listen-<stamp>.md`:
   - `## Summary`: one short paragraph on what was covered.
   - `## Key points`: bullets of the main ideas, definitions and facts, with the clock time where it helps find them in the transcript.
   - `## To-dos`: a `- [ ]` checklist of assignments, deadlines, readings and exam tips the speaker mentioned, with dates as stated. Write "None mentioned." if there are none. Never invent one.

   The transcript is automatic speech recognition: fix obviously misheard words from context, and leave anything you are unsure of as it is. Write nowhere else unless the person asks.

5. Play the ready cue so the person knows the notes are there, then tell them, in a few lines: how long it ran, the to-dos, and the paths of both files.

   ```bash
   afplay -v "${CALL_SOUND_VOLUME:-0.25}" ~/projects/call-notch/sounds/ready.wav
   ```

## Notes

- The recorder plays its own quiet cues from `sounds/` when it starts, pauses, resumes and stops. `CALL_SOUND_VOLUME` sets the level (default 0.25) and `0` turns them off.
- `/listen` and `/call` both drive the notch through `~/.claude-call/state.json`, so run one at a time.
- While paused, the audio is replaced by silence, so the minute stamps stay on the clock; the paused stretch is simply missing from the transcript.
- To test without the microphone: `Listen <out.txt> --file recording.wav` plays a recording through the same path in real time.
