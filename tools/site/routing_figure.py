#!/usr/bin/env python3
"""Turn the routing prototype's WAVs into envelope data for the landing page figure.

    engine/build/sbe_routing_demo out && python3 tools/site/routing_figure.py out

Writes tools/site/data/routing-session.json: peak envelopes of the master and headphone buses
(120 points each over the session) and the session's event times. The site generator draws it.
Run by `make figure`; the output is committed so the site builds without compiling the engine.
"""
import json
import os
import struct
import sys

POINTS = 120
EVENTS = [
    (0.0, "Track A on master"),
    (1.0, "Preview B in headphones"),
    (4.5, "B cued and synced"),
    (8.0, "Bass-swap A to B on the phrase"),
]


def read_wav(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError(f"{path}: not a WAV file")
    pos, fmt, samples = 12, None, None
    while pos + 8 <= len(data):
        cid, size = data[pos:pos + 4], struct.unpack("<I", data[pos + 4:pos + 8])[0]
        body = data[pos + 8:pos + 8 + size]
        if cid == b"fmt ":
            fmt = struct.unpack("<HHIIHH", body[:16])
        elif cid == b"data":
            samples = body
        pos += 8 + size + (size & 1)
    tag, channels, rate, _, _, bits = fmt
    if tag == 3 and bits == 32:
        values = struct.unpack(f"<{len(samples) // 4}f", samples)
    elif tag == 1 and bits == 16:
        values = [v / 32768 for v in struct.unpack(f"<{len(samples) // 2}h", samples)]
    else:
        raise ValueError(f"{path}: unsupported WAV format {tag}/{bits}")
    return values, channels, rate


def envelope(path):
    values, channels, rate = read_wav(path)
    frames = len(values) // channels
    step = frames / POINTS
    out = []
    for i in range(POINTS):
        a, b = int(i * step) * channels, int((i + 1) * step) * channels
        out.append(round(max((abs(v) for v in values[a:b]), default=0.0), 3))
    return out, frames / rate


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "out"
    master, seconds = envelope(os.path.join(src, "master.wav"))
    phones, _ = envelope(os.path.join(src, "headphones.wav"))
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    dest = os.path.join(root, "tools", "site", "data", "routing-session.json")
    json.dump({"$source": "engine/tools/routing_demo.cpp via tools/site/routing_figure.py",
               "seconds": round(seconds, 2), "events": [{"t": t, "label": l} for t, l in EVENTS],
               "master": master, "headphones": phones}, open(dest, "w"), indent=1)
    print(f"wrote {os.path.relpath(dest, root)}")


if __name__ == "__main__":
    main()
