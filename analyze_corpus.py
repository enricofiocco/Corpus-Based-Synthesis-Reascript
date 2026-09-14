#!/usr/bin/env python3
"""
analyze_corpus.py

Corpus builder for a REAPER/ReaScript concatenative synthesis engine.

Walks a folder of audio files, segments each file (fixed-length grains
or onset/transient-based fragments), extracts a feature vector per
fragment, and writes everything to a CSV that ReaScript can load
directly (one row per fragment, with the source file path and the
start/end time in seconds so ReaScript just points a take at an
offset into the original file -- no need to render individual
fragment files).

Usage:
    python analyze_corpus.py /path/to/folder --mode onset --out corpus.csv
    python analyze_corpus.py /path/to/folder --mode fixed --grain-ms 250 --out corpus.csv

Requires: librosa, soundfile, numpy
    pip install librosa soundfile numpy
"""

import argparse
import csv
import os
import sys

import numpy as np
import librosa

AUDIO_EXTS = {".wav", ".aif", ".aiff", ".flac", ".mp3", ".ogg", ".m4a"}


# ---------------------------------------------------------------------------
# Segmentation
# ---------------------------------------------------------------------------

def segment_fixed(y, sr, grain_ms, hop_ms=None):
    """Fixed-length grains. hop_ms defaults to grain_ms (no overlap)."""
    grain_len = int(sr * grain_ms / 1000.0)
    hop_len = int(sr * (hop_ms or grain_ms) / 1000.0)
    total = len(y)
    bounds = []
    pos = 0
    while pos + grain_len <= total:
        bounds.append((pos, pos + grain_len))
        pos += hop_len
    # trailing partial grain, if long enough to bother with
    if total - pos > grain_len * 0.25:
        bounds.append((pos, total))
    return bounds


def segment_onset(y, sr, min_len_ms=60.0, backtrack=True):
    """Onset-based segmentation. Splits at detected onsets, discards
    fragments shorter than min_len_ms (usually just noise/false positives)."""
    onset_frames = librosa.onset.onset_detect(
        y=y, sr=sr, backtrack=backtrack, units="samples"
    )
    total = len(y)
    starts = [0] + list(onset_frames)
    starts = sorted(set(s for s in starts if 0 <= s < total))
    bounds = []
    for i, s in enumerate(starts):
        e = starts[i + 1] if i + 1 < len(starts) else total
        if (e - s) / sr * 1000.0 >= min_len_ms:
            bounds.append((s, e))
    return bounds


# ---------------------------------------------------------------------------
# Feature extraction
# ---------------------------------------------------------------------------

def extract_features(y, sr):
    """Extract one feature vector for a mono audio fragment."""
    if len(y) < 512:
        # pad very short fragments so STFT-based features don't choke
        y = np.pad(y, (0, 512 - len(y)))

    feats = {}
    feats["duration"] = len(y) / sr

    # --- dynamics ---
    rms = librosa.feature.rms(y=y)[0]
    feats["rms_mean"] = float(np.mean(rms))
    feats["rms_max"] = float(np.max(rms))
    peak = float(np.max(np.abs(y))) + 1e-9
    feats["peak"] = peak
    feats["crest_factor"] = peak / (feats["rms_mean"] + 1e-9)

    # --- spectral ---
    S = np.abs(librosa.stft(y)) + 1e-9
    centroid = librosa.feature.spectral_centroid(S=S, sr=sr)[0]
    flatness = librosa.feature.spectral_flatness(S=S)[0]
    rolloff = librosa.feature.spectral_rolloff(S=S, sr=sr)[0]
    bandwidth = librosa.feature.spectral_bandwidth(S=S, sr=sr)[0]
    zcr = librosa.feature.zero_crossing_rate(y)[0]

    feats["spectral_centroid"] = float(np.mean(centroid))
    feats["spectral_flatness"] = float(np.mean(flatness))
    feats["spectral_rolloff"] = float(np.mean(rolloff))
    feats["spectral_bandwidth"] = float(np.mean(bandwidth))
    feats["zcr"] = float(np.mean(zcr))

    # --- timbre (MFCCs) ---
    mfcc = librosa.feature.mfcc(y=y, sr=sr, n_mfcc=13)
    for i in range(13):
        feats[f"mfcc{i+1}"] = float(np.mean(mfcc[i]))

    # --- pitch (monophonic-oriented, pyin) ---
    try:
        f0, voiced_flag, voiced_prob = librosa.pyin(
            y, fmin=librosa.note_to_hz("C2"), fmax=librosa.note_to_hz("C7"), sr=sr
        )
        f0_voiced = f0[~np.isnan(f0)]
        feats["pitch_hz"] = float(np.median(f0_voiced)) if len(f0_voiced) else 0.0
        feats["pitch_confidence"] = float(np.nanmean(voiced_prob))
    except Exception:
        feats["pitch_hz"] = 0.0
        feats["pitch_confidence"] = 0.0

    return feats


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def find_audio_files(folder):
    for root, _, files in os.walk(folder):
        for f in files:
            if os.path.splitext(f)[1].lower() in AUDIO_EXTS:
                yield os.path.join(root, f)


def main():
    ap = argparse.ArgumentParser(description="Build a concatenative synthesis corpus CSV from a folder of audio files.")
    ap.add_argument("folder", help="Folder to scan recursively for audio files")
    ap.add_argument("--out", default="corpus.csv", help="Output CSV path")
    ap.add_argument("--mode", choices=["fixed", "onset"], default="onset")
    ap.add_argument("--grain-ms", type=float, default=250.0, help="Grain length in ms (fixed mode)")
    ap.add_argument("--hop-ms", type=float, default=None, help="Hop length in ms (fixed mode, defaults to grain-ms)")
    ap.add_argument("--min-len-ms", type=float, default=60.0, help="Minimum fragment length (onset mode)")
    ap.add_argument("--sr", type=int, default=None, help="Resample to this rate (default: native)")
    args = ap.parse_args()

    files = list(find_audio_files(args.folder))
    if not files:
        print(f"No audio files found in {args.folder}", file=sys.stderr)
        sys.exit(1)

    print(f"Found {len(files)} audio files. Mode: {args.mode}")

    rows = []
    fieldnames = None

    for fi, path in enumerate(files, 1):
        print(f"[{fi}/{len(files)}] {path}")
        try:
            y, sr = librosa.load(path, sr=args.sr, mono=True)
        except Exception as e:
            print(f"  skipped (load error: {e})", file=sys.stderr)
            continue

        if args.mode == "fixed":
            bounds = segment_fixed(y, sr, args.grain_ms, args.hop_ms)
        else:
            bounds = segment_onset(y, sr, args.min_len_ms)

        for (s, e) in bounds:
            frag = y[s:e]
            if len(frag) < 32:
                continue
            feats = extract_features(frag, sr)
            row = {
                "file_path": os.path.abspath(path),
                "start_sec": s / sr,
                "end_sec": e / sr,
            }
            row.update(feats)
            rows.append(row)
            if fieldnames is None:
                fieldnames = list(row.keys())

    if not rows:
        print("No fragments extracted.", file=sys.stderr)
        sys.exit(1)

    with open(args.out, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    print(f"\nWrote {len(rows)} fragments to {args.out}")


if __name__ == "__main__":
    main()
