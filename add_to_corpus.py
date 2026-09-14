#!/usr/bin/env python3
"""
add_to_corpus.py

Incrementally adds sound files to an existing corpus CSV (as produced
by analyze_corpus.py), analyzing only files not already present, and
appending the new fragments to the existing corpus.

Acts as a drop-in superset of analyze_corpus.py:
    - If the output CSV doesn't exist yet, this behaves identically to
      a fresh analysis (same as running analyze_corpus.py).
    - If it already exists, only NEW files (by absolute path) found in
      the given folder are analyzed and appended. Files already
      represented in the corpus are skipped, so re-running on the same
      folder (or a folder with overlapping files) is safe/idempotent.

IMPORTANT: after adding sounds, re-run cluster_corpus.py on the
updated CSV to regenerate corpus_clustered.csv + corpus_scaler.json.
Clustering is NOT updated incrementally here -- a proper re-fit needs
the full, combined corpus, so just re-run the clustering step (or the
REAPER pipeline UI, which does both steps back to back).

Must live in the same folder as analyze_corpus.py (imports shared
segmentation/feature-extraction code from it).

Usage:
    # Append new files from a folder into an existing corpus:
    python add_to_corpus.py /path/to/new/folder --out corpus.csv

    # Ignore any existing corpus.csv and start completely fresh:
    python add_to_corpus.py /path/to/folder --out corpus.csv --overwrite
"""

import argparse
import os
import sys

import pandas as pd
import librosa

from analyze_corpus import find_audio_files, segment_fixed, segment_onset, extract_features


def main():
    ap = argparse.ArgumentParser(description="Add new sound files to an existing corpus CSV (or create one if it doesn't exist).")
    ap.add_argument("folder", help="Folder to scan recursively for audio files")
    ap.add_argument("--out", default="corpus.csv", help="Corpus CSV to append to (created fresh if it doesn't exist)")
    ap.add_argument("--mode", choices=["fixed", "onset"], default="onset")
    ap.add_argument("--grain-ms", type=float, default=250.0, help="Grain length in ms (fixed mode)")
    ap.add_argument("--hop-ms", type=float, default=None, help="Hop length in ms (fixed mode)")
    ap.add_argument("--min-len-ms", type=float, default=60.0, help="Minimum fragment length (onset mode)")
    ap.add_argument("--sr", type=int, default=None, help="Resample to this rate (default: native)")
    ap.add_argument("--overwrite", action="store_true", help="Ignore any existing corpus at --out and start fresh instead of appending")
    args = ap.parse_args()

    existing_df = None
    already_seen = set()

    if os.path.exists(args.out) and not args.overwrite:
        existing_df = pd.read_csv(args.out)
        if "cluster_id" in existing_df.columns:
            print(
                "NOTE: the existing CSV already contains cluster assignments (cluster_id). "
                "After this run, re-run cluster_corpus.py to refresh clustering across the "
                "full, combined corpus -- new fragments won't have a valid cluster_id until then."
            )
        if "file_path" in existing_df.columns:
            already_seen = set(os.path.abspath(p) for p in existing_df["file_path"].dropna().unique())
        print(f"Existing corpus loaded: {len(existing_df)} fragments from {len(already_seen)} file(s).")
    else:
        print("No existing corpus found (or --overwrite set) -- starting fresh.")

    all_files = list(find_audio_files(args.folder))
    new_files = [f for f in all_files if os.path.abspath(f) not in already_seen]
    skipped = len(all_files) - len(new_files)
    if skipped:
        print(f"Skipping {skipped} file(s) already present in the corpus.")
    if not new_files:
        print("No new files to analyze. Corpus unchanged.")
        sys.exit(0)

    print(f"Analyzing {len(new_files)} new file(s)...")
    new_rows = []
    for fi, path in enumerate(new_files, 1):
        print(f"[{fi}/{len(new_files)}] {path}")
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
            new_rows.append(row)

    if not new_rows:
        print("No fragments extracted from the new files.", file=sys.stderr)
        sys.exit(1)

    new_df = pd.DataFrame(new_rows)
    combined_df = pd.concat([existing_df, new_df], ignore_index=True, sort=False) if existing_df is not None else new_df

    combined_df.to_csv(args.out, index=False)
    print(f"\nAdded {len(new_df)} new fragments from {len(new_files)} file(s).")
    print(f"Corpus now has {len(combined_df)} fragments total -> {args.out}")


if __name__ == "__main__":
    main()
