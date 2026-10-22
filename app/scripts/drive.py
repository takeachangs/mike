"""Fake bridge for CallNotch, no call: launches the app's CallNotch (app/.build/release) with CALL_BRIDGE_PID set to
this process, then writes ~/.claude-call/state.json at 20 Hz cycling listening 3 s -> speaking 4 s ->
thinking 3 s until stopped. SIGUSR1 (the card's mute) toggles "muted"; SIGINT (Ctrl-C, or the card's
hang-up) writes off, sends the app SIGTERM like bridge.py, and exits.

  python3 app/scripts/drive.py     # after `cd app && swift build -c release`
"""
import json, math, os, random, signal, subprocess, time
from pathlib import Path

STATE = Path.home() / ".claude-call" / "state.json"
CYCLE = [("listening", 3), ("speaking", 4), ("thinking", 3)]
muted = False


def write(state, level):
    STATE.parent.mkdir(exist_ok=True)
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps({"state": state, "level": round(level, 3), "muted": muted}))
    os.replace(tmp, STATE)


def toggle(*_):
    global muted
    muted = not muted
    print("muted" if muted else "unmuted", flush=True)


def speech():
    """Syllable bursts about 4 per second with short pauses, so it looks like talking, not a sine."""
    burst, t, nxt, pause = 0.0, 0.0, 0.0, 0.0
    while True:
        t += 0.05
        if t >= pause and t >= nxt:
            burst = 0.45 + random.random() * 0.55
            nxt = t + 0.16 + random.random() * 0.14
            if random.random() < 0.08:
                pause = t + 0.35 + random.random() * 0.5
        burst *= math.exp(-0.05 * 9)
        yield 0.0 if t < pause else burst


if __name__ == "__main__":
    signal.signal(signal.SIGUSR1, toggle)
    signal.signal(signal.SIGINT, signal.default_int_handler)  # a shell's `&` starts us with SIGINT ignored
    write("listening", 0.0)
    app = subprocess.Popen([Path(__file__).resolve().parent.parent / ".build/release/CallNotch"],
                           env={**os.environ, "CALL_BRIDGE_PID": str(os.getpid())},
                           start_new_session=True)  # Ctrl-C reaches only us; the app gets SIGTERM below
    env = speech()
    try:
        while True:
            for state, secs in CYCLE:
                print(state, flush=True)
                end = time.monotonic() + secs
                while time.monotonic() < end:
                    v = next(env)
                    write(state, v if state == "speaking" else 0.15 * v if state == "listening" else 0.0)
                    time.sleep(0.05)
    except KeyboardInterrupt:
        write("off", 0.0)
        app.terminate()
        print("off", flush=True)
