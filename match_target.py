#!/usr/bin/env python3
"""
match_target.py

Concatenative synthesis matching step. Takes a target sound, segments it
the same way analyze_corpus.py segments a corpus (onset-based, fixed-length
grains, or one unit per target), measures every segment with the same
descriptors, normalizes them with the scaler saved by cluster_corpus.py, and
for each segment finds the k nearest fragments of a corpus.

Normally launched by Match_target.lua (select item(s) in REAPER -> resynthesize
with another corpus). It can also be run from a terminal.

Usage (terminal, one target file):
    python3 match_target.py target.wav corpus_clustered.csv corpus_scaler.json \\
        --mode onset --k 3 --out matches.csv

Usage (several targets / item portions, as Match_target.lua does):
    python3 match_target.py - corpus_clustered.csv corpus_scaler.json \\
        --jobs targets.tsv --mode items --k 5 --out matches.csv

  targets.tsv: one target per line, tab-separated:
      audio_path <TAB> start_sec <TAB> length_sec
  (start/length are in source-file seconds; length <= 0 = until the end)

Modes:
  onset  -- split at detected onsets (good for a glued sequence of sounds)
  fixed  -- fixed-length grains (--grain-ms, optional --hop-ms)
  items  -- each target (each line of --jobs, or the whole file) is one unit

Output CSV: one row per (segment, rank) with the segment position (seconds
from the start of its target portion), its level and pitch, and the matched
corpus fragment (file, start, end, level, pitch, distance).
"""

import argparse
import json
import os
import sys

import numpy as np
import pandas as pd
import librosa

# same segmentation + descriptors as the corpus (must match exactly: the
# scaler was fit on these definitions)
from analyze_corpus import extract_features, segment_fixed, segment_onset


def read_jobs(args):
    if args.jobs:
        jobs = []
        with open(args.jobs, encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\r\n")
                if not line.strip():
                    continue
                parts = line.split("\t")
                path = parts[0]
                start = float(parts[1]) if len(parts) > 1 and parts[1] else 0.0
                length = float(parts[2]) if len(parts) > 2 and parts[2] else 0.0
                jobs.append((path, max(start, 0.0), length if length > 0 else None))
        return jobs
    return [(args.target_audio, 0.0, None)]


def main():
    ap = argparse.ArgumentParser(description="Match target audio against a clustered concatenative corpus.")
    ap.add_argument("target_audio", help="Target audio file ('-' when --jobs is used)")
    ap.add_argument("corpus_csv", help="Clustered corpus CSV from cluster_corpus.py")
    ap.add_argument("scaler_json", help="Scaler JSON from cluster_corpus.py")
    ap.add_argument("--jobs", default=None, help="TSV of targets: path, start_sec, length_sec (one per line)")
    ap.add_argument("--out", default="matches.csv", help="Output CSV path")
    ap.add_argument("--mode", choices=["fixed", "onset", "items"], default="onset")
    ap.add_argument("--grain-ms", type=float, default=250.0)
    ap.add_argument("--hop-ms", type=float, default=None)
    ap.add_argument("--min-len-ms", type=float, default=60.0)
    ap.add_argument("--k", type=int, default=3, help="Number of nearest corpus matches per target segment")
    ap.add_argument("--sr", type=int, default=None, help="Resample target to this rate (default: native)")
    ap.add_argument("--ignore", default="",
                    help="Comma-separated descriptors left out of the distance, e.g. duration,pitch_hz,pitch_confidence")
    ap.add_argument("--same-file-penalty", type=float, default=0.0,
                    help="Distance added to corpus fragments from a file with the same name as the target "
                         "(avoids matching a sound to itself). 0 disables.")
    args = ap.parse_args()

    # --- scaler ---
    with open(args.scaler_json) as f:
        scaler_info = json.load(f)
    feature_columns = list(scaler_info["feature_columns"])
    mean = np.array(scaler_info["mean"], dtype=float)
    scale = np.array(scaler_info["scale"], dtype=float)
    scale[scale == 0] = 1.0

    ignore = {c.strip() for c in args.ignore.split(",") if c.strip()}
    keep = [i for i, c in enumerate(feature_columns) if c not in ignore]
    if not keep:
        print("ERROR: every descriptor is ignored.", file=sys.stderr)
        sys.exit(1)

    # --- corpus (normalized z_ columns) ---
    corpus = pd.read_csv(args.corpus_csv)
    z_cols = [f"z_{c}" for c in feature_columns]
    missing = [c for c in z_cols if c not in corpus.columns]
    if missing:
        print(f"ERROR: corpus CSV is missing expected columns: {missing}", file=sys.stderr)
        print("Use the *_clustered.csv produced by cluster_corpus.py, not the raw analyze_corpus.py output.",
              file=sys.stderr)
        sys.exit(1)
    corpus_matrix = corpus[z_cols].values[:, keep]
    corpus_matrix = np.nan_to_num(corpus_matrix)
    files = corpus["file_path"].astype(str).values
    c_start = corpus["start_sec"].values
    c_end = corpus["end_sec"].values
    c_dur = corpus["duration"].values if "duration" in corpus.columns else c_end - c_start
    c_rms = corpus["rms_mean"].values if "rms_mean" in corpus.columns else np.zeros(len(corpus))
    c_pitch = corpus["pitch_hz"].values if "pitch_hz" in corpus.columns else np.zeros(len(corpus))
    c_cluster = corpus["cluster_id"].values if "cluster_id" in corpus.columns else -np.ones(len(corpus))
    basenames = np.array([os.path.basename(p) for p in files])

    jobs = read_jobs(args)
    rows = []
    n_segments = 0
    k = max(1, min(args.k, len(corpus)))

    for job_idx, (path, start, length) in enumerate(jobs):
        print(f"Target {job_idx + 1}/{len(jobs)}: {os.path.basename(path)}", flush=True)
        try:
            y, sr = librosa.load(path, sr=args.sr, mono=True, offset=start, duration=length)
        except Exception as e:
            print(f"  could not load ({e}), skipped", file=sys.stderr)
            continue
        if len(y) < 32:
            print("  too short, skipped", file=sys.stderr)
            continue

        if args.mode == "fixed":
            bounds = segment_fixed(y, sr, args.grain_ms, args.hop_ms)
        elif args.mode == "onset":
            bounds = segment_onset(y, sr, args.min_len_ms)
        else:
            bounds = [(0, len(y))]
        if not bounds:
            bounds = [(0, len(y))]
        print(f"  {len(bounds)} segment(s)", flush=True)

        same_mask = None
        if args.same_file_penalty > 0:
            same_mask = (basenames == os.path.basename(path)).astype(float)

        for seg_idx, (s, e) in enumerate(bounds):
            frag = y[s:e]
            if len(frag) < 32:
                continue
            feats = extract_features(frag, sr)
            raw_vec = np.array([feats.get(c, 0.0) for c in feature_columns], dtype=float)
            norm_vec = ((raw_vec - mean) / scale)[keep]
            dists = np.linalg.norm(corpus_matrix - norm_vec, axis=1)
            if same_mask is not None:
                dists = dists + same_mask * args.same_file_penalty
            nearest = np.argpartition(dists, k - 1)[:k] if k < len(dists) else np.arange(len(dists))
            nearest = nearest[np.argsort(dists[nearest])]
            n_segments += 1
            for rank, idx in enumerate(nearest):
                rows.append({
                    "job_index": job_idx,
                    "target_index": seg_idx,
                    "target_start_sec": s / sr,
                    "target_end_sec": e / sr,
                    "target_duration": (e - s) / sr,
                    "target_rms_mean": feats["rms_mean"],
                    "target_pitch_hz": feats.get("pitch_hz", 0.0),
                    "rank": rank,
                    "distance": float(dists[idx]),
                    "match_file_path": files[idx],
                    "match_start_sec": c_start[idx],
                    "match_end_sec": c_end[idx],
                    "match_duration": c_dur[idx],
                    "match_rms_mean": c_rms[idx],
                    "match_pitch_hz": c_pitch[idx],
                    "match_cluster_id": c_cluster[idx],
                })

    if not rows:
        print("No matches produced (no usable target segments).", file=sys.stderr)
        sys.exit(1)

    pd.DataFrame(rows).to_csv(args.out, index=False)
    print(f"Wrote {len(rows)} match rows ({n_segments} target segments x up to {k} matches) to {args.out}")


if __name__ == "__main__":
    main()
