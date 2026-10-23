# /// script
# requires-python = ">=3.11"
# dependencies = ["openai>=3.27", "sounddevice", "websockets"]
# ///
"""Voice bridge: GPT-Live on the mic/speaker, Claude Code as the backend.

  uv run bridge.py                 start a call (Ctrl-C hangs up)
  uv run bridge.py solo            a plain GPT-Live call: no delegation, no agent (the app's Call does the same in Swift)
  uv run bridge.py say  ID "text"  spoken result for delegation ID
  uv run bridge.py note ID "text"  quiet progress for delegation ID
  uv run bridge.py selftest

Delegations land in ~/.mike/inbox.jsonl as one JSON line each:
  {"id": ..., "offset_ms": ..., "transcript": [["user"|"assistant", text], ...]}
A final {"event": "closed", "seconds": ..., "transcript": [...]} line ends the
call; `seconds` is the API's final billed audio duration (null if the close was
never confirmed). Replies go through the outbox (written by `say` / `note`) and
are forwarded to the Live session. During a call ~/.mike/state.json
carries {"state", "level", "muted", "pid", "mode"} at 20 Hz for the notch (Mike.app), which
is launched here if it has been built; its buttons signal this process
(SIGUSR1 toggles mute, SIGINT hangs up). ~/.mike/context.txt, if present,
seeds the session as a developer message. The call closes itself after
IDLE_AFTER seconds with no transcribed speech, no audio out and no delegation pending (never while muted); one spoken nudge at NUDGE_AT.
Short cues (the app's cue files, SOUNDS) play quietly at call start, mute and unmute, each
delegation, its first answer and hang-up; CALL_SOUND_VOLUME (afplay -v,
default 0.25) sets the level and 0 turns them off.
"""
import asyncio, base64, json, math, os, queue, signal, subprocess, sys, threading, time
from array import array
from pathlib import Path

STATE = Path.home() / ".mike"
INBOX, OUTBOX, STATE_FILE = STATE / "inbox.jsonl", STATE / "outbox.jsonl", STATE / "state.json"
REPO = Path(__file__).resolve().parent
# The notch: an installed Mike.app first, then this checkout's build (scripts/build-app.sh, or a plain swift build).
NOTCH_APP = next((p for p in (Path("/Applications/Mike.app/Contents/MacOS/Mike"),
                              Path.home() / "Applications/Mike.app/Contents/MacOS/Mike",
                              REPO / "app/dist/Mike.app/Contents/MacOS/Mike",
                              REPO / "app/.build/release/Mike") if p.exists()), REPO / "app/.build/release/Mike")
SOUNDS = REPO / "app/Sources/MikeKit/Resources/sounds"
CUES = ("start", "pause", "stop", "wait", "ready")  # <name>.wav in SOUNDS, rendered by app/scripts/make-sounds.py; the app plays the same files


def volume(raw: str) -> float:
    """CALL_SOUND_VOLUME as afplay -v takes it; anything unreadable ("off", empty) means off, as in Listen."""
    try:
        return max(0.0, float(raw))
    except ValueError:
        return 0.0


VOLUME = volume(os.environ.get("CALL_SOUND_VOLUME", "0.25"))  # quiet by default, 0 turns the cues off
RATE = 24000
INSTRUCTIONS = (Path(__file__).resolve().parent / "prompt.txt").read_text()
SOLO_INSTRUCTIONS = (  # the solo call's whole prompt: no agent behind it, so it must not promise to look things up
    "You are a friendly, concise voice assistant on the user's Mac. Answer from your own knowledge in short spoken "
    "sentences. You have no tools, no internet and no access to the user's files, so say so plainly when asked for "
    "something current or personal. When the user says goodbye, say goodbye and end with exactly: Hanging up now."
)
SIGN_OFF = "Hanging up now"  # prompt.txt makes the voice end every goodbye with this; hearing it closes the session
IDLE_AFTER = 60  # seconds with no transcribed speech, no audio out and no pending delegation before the bridge hangs up
NUDGE_AT = 30  # seconds of that quiet before the voice is asked, once, if the user is still there
WARN_BEFORE = 10  # the `wait` cue plays this long before the hang-up
NUDGE = "The user has been quiet for a while. Ask them once, in a few words, whether they are still there."
CALLING_ABOUT = "Calling about:"  # first line of context.txt when the agent placed the call; the /call skill writes it
CLOSE_WAIT = 5  # seconds to wait for session.closed after closing, so a dead socket cannot hang the exit
CONTEXT_CAP = 4000  # characters of context.txt sent at start; the server caps the seed at 8,192 tokens


def append_outbox(kind: str, delegation_id: str, content: str) -> None:
    STATE.mkdir(exist_ok=True)
    with OUTBOX.open("a") as f:
        f.write(json.dumps({"kind": kind, "delegation_id": delegation_id, "content": content[:1500]}) + "\n")


def cue(name: str) -> None:
    """Play SOUNDS/<name>.wav without waiting. A missing file or player is skipped: a cue never breaks the call."""
    if VOLUME > 0 and (f := SOUNDS / f"{name}.wav").exists():
        try:
            subprocess.Popen(["afplay", "-v", str(VOLUME), str(f)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError:
            pass


def app_running() -> bool:
    """True when the resident notch app (Mike started on its own) is up; it then shows this call itself."""
    try:
        os.kill(int((STATE / "app.pid").read_text()), 0)
        return True
    except (OSError, ValueError):
        return False


def write_inbox(obj: dict) -> None:
    with INBOX.open("a") as f:
        f.write(json.dumps(obj) + "\n")


def context() -> str:
    f = STATE / "context.txt"
    return f.read_text()[:CONTEXT_CAP].strip() if f.exists() else ""


def opener(text: str) -> str | None:
    """What the voice is told to open with when the agent placed the call (context's first line `Calling about: <reason>`), else None."""
    first = text.split("\n", 1)[0]
    reason = first[len(CALLING_ABOUT):].strip() if first.startswith(CALLING_ABOUT) else ""
    return f"You placed this call. Open by saying in a few words why you are calling: {reason}." if reason else None


def seed() -> dict:
    """session.start fields seeding context.txt as a developer message; {} when there is no file."""
    text = context()
    return {"input": [{"type": "message", "role": "developer", "content": [{"type": "input_text", "text": text}]}]} if text else {}


def idle_action(now: float, active_at: float, spk_at: float, pending: bool, muted: bool, done: dict) -> str | None:
    """"nudge", "warn" or "hangup" once per silence, else None. A pending delegation or a mute never counts as quiet;
    `done` maps what already fired to when and is cleared when the quiet ends.
    The nudge's own reply (voice audio after it) does not end the quiet; only a user word, a `say` or a mute does."""
    quiet = 0 if pending or muted else now - max(active_at, spk_at if spk_at <= done.get("nudge", spk_at) else done["nudge"] - NUDGE_AT)
    if quiet < NUDGE_AT:
        done.clear()
    action = "hangup" if quiet >= IDLE_AFTER else "warn" if quiet >= IDLE_AFTER - WARN_BEFORE else "nudge" if quiet >= NUDGE_AT else None
    if action is None or action in done:
        return None
    done[action] = now
    return action


def write_closed(transcript: list, seconds: float | None) -> None:
    write_inbox({"event": "closed", "seconds": seconds, "transcript": transcript})
    (STATE / f"transcript-{time.strftime('%Y%m%dT%H%M')}.json").write_text(json.dumps({"seconds": seconds, "transcript": transcript}, indent=1))


def rms(chunk: bytes) -> float:
    """RMS of int16 PCM, scaled so normal speech lands around 0.5-0.8."""
    a = array("h", chunk)
    return min(1.0, math.sqrt(sum(x * x for x in a) / max(len(a), 1)) / 6000)


def write_state(state: str, level: float, muted: bool = False) -> None:
    tmp = STATE_FILE.with_suffix(".tmp")  # pid and mode let a resident notch app (one we did not launch) signal and label us
    tmp.write_text(json.dumps({"state": state, "level": round(level, 3), "muted": muted, "pid": os.getpid(), "mode": "call"}))
    os.replace(tmp, STATE_FILE)  # atomic: the notch app never reads half a file


async def call(solo: bool = False) -> None:
    import sounddevice as sd
    from openai import AsyncOpenAI

    STATE.mkdir(exist_ok=True)
    INBOX.write_text("")
    OUTBOX.write_text("")
    loop = asyncio.get_running_loop()
    mic: asyncio.Queue[bytes] = asyncio.Queue()
    spk: queue.Queue[bytes | None] = queue.Queue()
    transcript: list[list[str]] = []  # [role, text]
    live = {"mic": 0.0, "spk": 0.0, "spk_at": 0.0, "active_at": time.monotonic(), "muted": False}  # levels for the notch, written from the audio threads
    pending: set[str] = set()  # delegations still waiting for their first `say`
    notch, seconds, reason, main = None, None, None, asyncio.current_task()

    def on_mic(indata, frames, t, status):
        live["mic"] = rms(bytes(indata))
        loop.call_soon_threadsafe(mic.put_nowait, bytes(indata))

    def speaker():
        # ponytail: leftover audio still plays after an interruption; flush the queue on input_transcript if it bothers you
        with sd.RawOutputStream(samplerate=RATE, channels=1, dtype="int16") as out:
            while (chunk := spk.get()) is not None:
                # 100 ms slices, timed at playback: deltas arrive faster than real time, so arrival would end "speaking" early
                for i in range(0, len(chunk), RATE // 5):
                    live["spk"], live["spk_at"] = rms(chunk[i:i + RATE // 5]), time.monotonic()
                    out.write(chunk[i:i + RATE // 5])

    def add(role: str, delta: str) -> None:
        if transcript and transcript[-1][0] == role:
            transcript[-1][1] += delta
        else:
            transcript.append([role, delta])
            del transcript[:-40]

    async def pump_mic(conn):
        while True:
            await conn.session.input_audio.append(audio=base64.b64encode(await mic.get()).decode())

    async def pump_outbox(conn):
        with OUTBOX.open() as f:
            while True:
                line = f.readline()
                if not line:
                    await asyncio.sleep(0.2)
                    continue
                msg = json.loads(line)
                res = {"say": conn.session.commentary, "note": conn.session.thinking}[msg["kind"]]
                await res.append(content=msg["content"], delegation_id=msg["delegation_id"])
                if msg["kind"] == "say":
                    if msg["delegation_id"] in pending:
                        cue("ready")  # first answer to a delegation
                    pending.discard(msg["delegation_id"])
                    live["active_at"] = time.monotonic()  # restart the idle clock: the answer is about to play
                print(f"→ live [{msg['kind']}] {msg['content'][:80]}")

    async def hang_up(conn):
        while not spk.empty() or time.monotonic() - live["spk_at"] < 0.8:  # let the goodbye finish playing
            await asyncio.sleep(0.1)
        print("sign-off heard, closing")
        main.cancel()  # same exit as Ctrl-C: close, then wait for session.closed

    async def guard_idle(conn):
        # ponytail: a delegation that never gets a `say` keeps the call open; Ctrl-C still ends it
        done: dict[str, float] = {}
        while True:
            await asyncio.sleep(1)
            action = idle_action(time.monotonic(), live["active_at"], live["spk_at"], bool(pending), live["muted"], done)
            if action == "nudge":
                print(f"quiet for {NUDGE_AT} s, nudging")
                await conn.session.commentary.append(content=NUDGE, delegation_id=None)
            elif action == "warn":
                cue("wait")
            elif action == "hangup":
                print(f"idle for {IDLE_AFTER} s (no speech, no audio, nothing pending), closing")
                main.cancel()
                return

    async def toggle_mute(conn):  # SIGUSR1 from the notch app's mute button; SIGINT from its hang-up button is plain Ctrl-C
        await (conn.session.input_audio.unmute() if live["muted"] else conn.session.input_audio.mute())
        live["muted"] = not live["muted"]
        live["active_at"] = time.monotonic()  # the quiet clock restarts on unmute
        cue("pause" if live["muted"] else "start")
        print("mic muted" if live["muted"] else "mic live")

    async def pump_state():
        while True:  # rewritten every tick even when unchanged: the app treats a 3 s old file as a dead bridge
            speaking = time.monotonic() - live["spk_at"] < 0.3
            s = "thinking" if pending else "speaking" if speaking else "listening"
            write_state(s, 0.0 if pending else live["spk"] if speaking else live["mic"], live["muted"])
            await asyncio.sleep(0.05)

    client = AsyncOpenAI()
    threading.Thread(target=speaker, daemon=True).start()
    async with client.live.connect() as conn:
        await conn.session.start(session={
            "model": "gpt-live-1",
            **({"instructions": SOLO_INSTRUCTIONS} if solo else {"delegation": {"type": "client"}, "instructions": INSTRUCTIONS, **seed()}),
            "audio": {"format": {"type": "audio/pcm", "rate": RATE}},
        })
        tasks = []
        try:
            with sd.RawInputStream(samplerate=RATE, channels=1, dtype="int16", blocksize=RATE // 10, callback=on_mic):
                async for ev in conn:
                    t = ev.type
                    if t == "session.started":
                        print("call started, talk. Ctrl-C hangs up.")
                        cue("start")
                        write_state("listening", 0.0)
                        if NOTCH_APP.exists() and not app_running():
                            notch = subprocess.Popen([NOTCH_APP], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                                     env={**os.environ, "CALL_BRIDGE_PID": str(os.getpid())})  # its buttons signal us
                        loop.add_signal_handler(signal.SIGUSR1, lambda: asyncio.create_task(toggle_mute(conn)))
                        if not solo and (line := opener(context())):
                            await conn.session.commentary.append(content=line, delegation_id=None)  # the voice speaks first
                        tasks = [asyncio.create_task(f(conn)) for f in (pump_mic, pump_outbox, guard_idle)] + [asyncio.create_task(pump_state())]
                    elif t == "session.output_audio.delta":
                        spk.put(base64.b64decode(ev.delta))
                    elif t == "session.input_transcript.delta":
                        add("user", ev.delta)
                        live["active_at"] = time.monotonic()  # the server heard words: real speech, not noise
                    elif t == "session.output_transcript.delta":
                        add("assistant", ev.delta)
                        if SIGN_OFF in transcript[-1][1] and not any(x.get_name() == "hangup" for x in tasks):
                            tasks.append(asyncio.create_task(hang_up(conn), name="hangup"))
                    elif t == "session.delegation.created":
                        print(f"← delegation {ev.delegation.id}: {transcript[-1][1][:80] if transcript else ''}")
                        write_inbox({"id": ev.delegation.id, "offset_ms": ev.offset_ms, "transcript": transcript[-12:]})
                        pending.add(ev.delegation.id)
                        cue("wait")
                    elif t == "session.usage.updated":
                        seconds = ev.usage.seconds  # cumulative: replace, never sum
                    elif t == "error":
                        print("error:", ev.error)
                    elif t == "session.closed":
                        seconds, reason = ev.usage.seconds, ev.reason
                        break
        except (KeyboardInterrupt, asyncio.CancelledError):
            await conn.session.close()
        finally:
            for task in tasks:
                task.cancel()
            spk.put(None)
            cue("stop")
            write_state("off", 0.0)
            if notch:
                notch.terminate()  # the app collapses its tab on SIGTERM, then exits
            if not reason:  # close sent but not confirmed: read on until session.closed brings the final usage
                try:
                    async with asyncio.timeout(CLOSE_WAIT):
                        while (ev := await conn.recv()).type != "session.closed":
                            if ev.type == "session.usage.updated":
                                seconds = ev.usage.seconds
                    seconds, reason = ev.usage.seconds, ev.reason
                except Exception as e:  # timeout or dead socket: keep the last usage update
                    reason = f"no session.closed ({type(e).__name__})"
            print(f"closed: {reason}, {seconds} s billed")
            write_closed(transcript, seconds)


def selftest() -> None:
    import tempfile
    global STATE, INBOX, OUTBOX, STATE_FILE
    STATE = Path(tempfile.mkdtemp()); INBOX, OUTBOX, STATE_FILE = STATE / "inbox.jsonl", STATE / "outbox.jsonl", STATE / "state.json"
    append_outbox("say", "item_1", "x" * 2000)
    write_inbox({"id": "item_1", "transcript": [["user", "hi"]]})
    out = json.loads(OUTBOX.read_text())
    assert out == {"kind": "say", "delegation_id": "item_1", "content": "x" * 1500}, out
    assert json.loads(INBOX.read_text())["id"] == "item_1"
    assert rms(b"") == 0 and rms(array("h", [3000, -3000]).tobytes()) == 0.5 and rms(array("h", [32767]).tobytes()) == 1
    write_state("thinking", 0.0)
    assert json.loads(STATE_FILE.read_text()) == {"state": "thinking", "level": 0.0, "muted": False, "pid": os.getpid(), "mode": "call"}
    assert not app_running()
    (STATE / "app.pid").write_text(str(os.getpid()))
    assert app_running()
    (STATE / "app.pid").write_text("x")
    assert not app_running()
    assert seed() == {}
    (STATE / "context.txt").write_text("y" * 5000)
    assert seed()["input"] == [{"type": "message", "role": "developer", "content": [{"type": "input_text", "text": "y" * CONTEXT_CAP}]}]
    assert opener("") is None and opener("Working on step 3.\nCalling about: x") is None  # no line, empty, not first
    assert opener("Calling about: the proof in step three\nmore") == "You placed this call. Open by saying in a few words why you are calling: the proof in step three."
    assert opener("Calling about:  \nmore") is None
    done: dict[str, float] = {}  # idle_action on a fake clock; speech at t=100
    acts = [idle_action(t, 100, 0, False, False, done) for t in (110, 129, 130, 131, 149, 150, 151, 159, 160, 161)]
    assert acts == [None, None, "nudge", None, None, "warn", None, None, "hangup", None], acts
    assert idle_action(200, 190, 0, False, False, done) is None and not done  # speech resets: the next silence nudges again
    assert idle_action(220, 190, 0, False, False, done) == "nudge"
    assert idle_action(250, 190, 215, False, False, done) is None  # voice audio at 215 resets the clock too
    done.clear()  # the nudge's own reply (voice audio at 131-133) must not reset the clocks
    nudges = [idle_action(t, 100, spk, False, False, done) for t, spk in ((130, 0), (132, 131), (133, 132), (140, 133), (149, 133), (150, 133), (159, 133), (160, 133))]
    assert nudges == ["nudge", None, None, None, None, "warn", None, "hangup"], nudges
    done.clear()
    done = {}  # voice reply ran to 120 before the quiet: the nudge at 150 still gives a full 30 s to answer
    late = [idle_action(t, 100, spk, False, False, done) for t, spk in ((150, 120), (152, 151), (159, 151), (170, 151), (180, 151))]
    assert late == ["nudge", None, None, "warn", "hangup"], late
    assert idle_action(1000, 0, 0, True, False, done) is None and idle_action(1000, 0, 0, False, True, done) is None  # pending or muted
    write_closed([["user", "bye"]], 42.5)
    assert json.loads(INBOX.read_text().splitlines()[-1]) == {"event": "closed", "seconds": 42.5, "transcript": [["user", "bye"]]}
    assert json.loads(next(STATE.glob("transcript-*.json")).read_text())["seconds"] == 42.5
    assert all((SOUNDS / f"{n}.wav").exists() for n in CUES), "a cue file is missing; run app/scripts/make-sounds.py"
    assert SIGN_OFF in SOLO_INSTRUCTIONS  # the solo voice can hang up too
    assert volume("0.5") == 0.5 and volume("off") == volume("") == volume("-1") == 0.0
    print("ok")


if __name__ == "__main__":
    a = sys.argv[1:]
    if not a:
        try:
            asyncio.run(call())
        except KeyboardInterrupt:
            pass
    elif a == ["solo"]:
        try:
            asyncio.run(call(solo=True))
        except KeyboardInterrupt:
            pass
    elif a[0] in ("say", "note") and len(a) == 3:
        append_outbox(a[0], a[1], a[2])
    elif a[0] == "selftest":
        selftest()
    else:
        sys.exit(__doc__)
