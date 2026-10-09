"""Drive CallNotch without a call: writes ~/.claude-call/state.json at 20 Hz through
listening 2 s -> thinking 3 s -> speaking 4 s -> listening 2 s -> off.

  python3 drive.py & .build/release/CallNotch
"""
import json, math, os, random, time
from pathlib import Path

STATE = Path.home() / ".claude-call" / "state.json"
SCRIPT = [("listening", 2), ("thinking", 3), ("speaking", 4), ("listening", 2), ("off", 0.5)]


def write(state, level):
    STATE.parent.mkdir(exist_ok=True)
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps({"state": state, "level": round(level, 3)}))
    os.replace(tmp, STATE)


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
    env = speech()
    for state, secs in SCRIPT:
        print(state, flush=True)
        end = time.monotonic() + secs
        while time.monotonic() < end:
            v = next(env)
            write(state, v if state == "speaking" else 0.15 * v if state == "listening" else 0.0)
            time.sleep(0.05)
    write("off", 0.0)
