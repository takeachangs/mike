---
name: listen
description: Transcribe a lecture or meeting live on this Mac (on-device, nothing uploaded while it listens) with the notch showing it, then write a summary, key points and to-dos from the transcript. Use when the person types /listen or asks to record, transcribe or take notes on a lecture or meeting.
---

# /listen — live on-device transcript, this session writes the notes

The recorder is the `Listen` command inside Mike.app (built from `~/projects/mike/app`). It transcribes the microphone with Parakeet Ultra on the Neural Engine and keeps a transcript with one paragraph per clock minute (`14:05 Alright, so today…`). No audio is saved, and nothing leaves the Mac while it listens. If the notch app is built, it shows the recording like a call: clicking the dots opens a card that reads Recording or Paused, with a timer, a pause button and a stop button.

## Steps

1. Make sure Mike.app is installed (`ls /Applications/Mike.app/Contents/MacOS/Listen`). If not, build and install it once, and again after pulling changes:

   ```bash
   cd ~/projects/mike/app && scripts/build-app.sh && scripts/install.sh
   ```

   The first run downloads the model (about 600 MB) and takes a minute or two to load.

2. Check whether a session is already running. A live session rewrites `~/.mike/state.json` every 50 ms, so this prints `listen`, `call` or nothing:

   ```bash
   python3 -c 'import json,os,time; p=os.path.expanduser("~/.mike/state.json"); s=json.load(open(p)); print(s["mode"] if s["state"]!="off" and time.time()-os.path.getmtime(p)<3 else "")' 2>/dev/null
   ```

   - `listen`: the person is already recording, usually from the notch. Do not start a second recorder. The transcript is the newest `~/.mike/listen-*.txt` (`ls -t ~/.mike/listen-*.txt | head -1`). Tell them you are following it and will write the notes when it stops, then go to step 3.
   - `call`: a call is running. Tell them to start /listen after it ends, and stop here.
   - nothing: pick the transcript path, `~/.mike/listen-<stamp>.txt` with the stamp from `date +%Y%m%dT%H%M`, and start the recorder in a terminal tab the person can see and stop with Ctrl-C:

     ```bash
     /Applications/Mike.app/Contents/MacOS/Listen ~/.mike/listen-<stamp>.txt
     ```

     Use the tool's "run in a terminal tab" action, not a blocking shell call. Wait for it to print `listening started`. The first time, macOS asks to let the terminal app use the microphone. Tell the person it is listening and how to stop it.

3. Wait for the recording to stop (Ctrl-C in the tab, or the notch's stop button) in the background, so this session stays free while it runs. Run this with the tool's background option, which notifies you when it exits; it ends when the state file goes off or stops updating:

   ```bash
   while python3 -c 'import json,os,sys,time; p=os.path.expanduser("~/.mike/state.json"); s=json.load(open(p)); sys.exit(0 if s["state"]!="off" and s["mode"]=="listen" and time.time()-os.path.getmtime(p)<3 else 1)' 2>/dev/null; do sleep 5; done
   ```

   Meanwhile, answer the person's questions from the transcript as it stands ("what did they just say about…", "any deadlines so far?"). The file is rewritten every few seconds, so read it fresh for each question: the last few paragraphs for "just now", all of it otherwise, citing the `HH:MM` stamps. The newest few seconds are not in it yet.

4. Read the transcript and write the notes next to it, as `~/.mike/listen-<stamp>.md`:
   - `## Summary`: one short paragraph on what was covered.
   - `## Key points`: bullets of the main ideas, definitions and facts, with the clock time where it helps find them in the transcript.
   - `## To-dos`: a `- [ ]` checklist of assignments, deadlines, readings and exam tips the speaker mentioned, with dates as stated. Write "None mentioned." if there are none. Never invent one.

   The transcript is automatic speech recognition: fix obviously misheard words from context, and leave anything you are unsure of as it is. Write nowhere else unless the person asks.

5. Play the ready cue so the person knows the notes are there, then tell them, in a few lines: how long it ran, the to-dos, and the paths of both files.

   ```bash
   /Applications/Mike.app/Contents/MacOS/Listen --cue ready
   ```

## Notes

- The recorder plays its own quiet cues when it starts, pauses, resumes and stops. `CALL_SOUND_VOLUME` sets the level (default 0.25) and `0` turns them off.
- `/listen` and `/call` both drive the notch through `~/.mike/state.json`, so run one at a time; step 2 follows a recording that is already running instead of starting another.
- While paused, the audio is replaced by silence, so the minute stamps stay on the clock; the paused stretch is simply missing from the transcript.
- To test without the microphone: `Listen <out.txt> --file recording.wav` plays a recording through the same path in real time.
