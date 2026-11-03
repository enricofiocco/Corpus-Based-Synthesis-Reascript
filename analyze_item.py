#!/usr/bin/env python3
"""
analyze_item.py

Measures ONE audio segment (e.g. the media item selected in REAPER) with the
exact same descriptors used for the corpus (analyze_corpus.extract_features),
so Find_similar.lua can compare it with the fragments of a corpus.

Output is a plain text file, one "key value" pair per line (easy to parse
from Lua, no JSON needed).

Must live in the same folder as analyze_corpus.py.

Usage:
    python3 analyze_item.py /path/to/source.wav --start 1.25 --length 0.8 --out features.txt
"""

import argparse
import sys

import librosa

from analyze_corpus import extract_features


def main():
    ap = argparse.ArgumentParser(description="Extract corpus-compatible descriptors from one audio segment.")
    ap.add_argument("audio", help="Audio file")
    ap.add_argument("--start", type=float, default=0.0, help="Segment start in the file (seconds)")
    ap.add_argument("--length", type=float, default=None, help="Segment length (seconds); default: until the end")
    ap.add_argument("--out", required=True, help="Output text file (key value per line)")
    args = ap.parse_args()

    y, sr = librosa.load(args.audio, sr=None, mono=True, offset=max(args.start, 0.0), duration=args.length)
    if len(y) < 32:
        print(f"Segment too short or empty (start={args.start}, length={args.length}).", file=sys.stderr)
        sys.exit(2)

    feats = extract_features(y, sr)

    with open(args.out, "w") as f:
        for key, value in feats.items():
            f.write(f"{key} {value!r}\n")

    print(f"OK: {len(y) / sr:.3f}s analysed -> {args.out}")


if __name__ == "__main__":
    main()
