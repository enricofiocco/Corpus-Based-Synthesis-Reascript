#!/usr/bin/env python3
"""
cluster_corpus.py

Takes the CSV produced by analyze_corpus.py, z-score normalizes the
feature columns, runs k-means to assign each fragment a timbre
cluster, and writes an augmented CSV.

Also saves a small JSON "scaler" file (feature means/stds + which
columns were used) so that a later target-matching script can
normalize a target's features the exact same way before doing
nearest-neighbor search against this corpus.

Usage:
    python cluster_corpus.py corpus.csv --k 12 --out corpus_clustered.csv
    python cluster_corpus.py corpus.csv --auto-k --out corpus_clustered.csv

If --k is omitted and --auto-k is not passed, defaults to k=10.
--auto-k scans k=4..20 and picks the best silhouette score (slower,
but recommended once when you don't know how many timbre classes
your corpus naturally splits into).
"""

import argparse
import json
import sys

import numpy as np
import pandas as pd
from sklearn.preprocessing import StandardScaler
from sklearn.cluster import KMeans
from sklearn.metrics import silhouette_score

# Structural/identifier columns -- never used as clustering features.
NON_FEATURE_COLS = {"file_path", "start_sec", "end_sec"}


def pick_feature_columns(df, exclude_pitch, exclude_duration):
    cols = [c for c in df.columns if c not in NON_FEATURE_COLS]
    if exclude_pitch:
        cols = [c for c in cols if c not in ("pitch_hz", "pitch_confidence")]
    if exclude_duration:
        cols = [c for c in cols if c != "duration"]
    return cols


def auto_select_k(X, k_min=4, k_max=20, random_state=42):
    best_k, best_score = k_min, -1.0
    n_samples = X.shape[0]
    k_max = min(k_max, n_samples - 1)
    print(f"Scanning k={k_min}..{k_max} for best silhouette score...")
    for k in range(k_min, k_max + 1):
        km = KMeans(n_clusters=k, n_init=10, random_state=random_state)
        labels = km.fit_predict(X)
        if len(set(labels)) < 2:
            continue
        score = silhouette_score(X, labels)
        print(f"  k={k:2d}  silhouette={score:.4f}")
        if score > best_score:
            best_k, best_score = k, score
    print(f"Best k = {best_k} (silhouette={best_score:.4f})")
    return best_k


def main():
    ap = argparse.ArgumentParser(description="Normalize and cluster a concatenative synthesis corpus CSV.")
    ap.add_argument("csv_path", help="Path to corpus CSV from analyze_corpus.py")
    ap.add_argument("--out", default="corpus_clustered.csv", help="Output CSV path")
    ap.add_argument("--scaler-out", default="corpus_scaler.json", help="Output path for the normalization scaler")
    ap.add_argument("--k", type=int, default=None, help="Number of clusters (default 10 if --auto-k not given)")
    ap.add_argument("--auto-k", action="store_true", help="Automatically pick k via silhouette score scan (k=4..20)")
    ap.add_argument("--exclude-pitch", action="store_true", help="Exclude pitch_hz/pitch_confidence from clustering features")
    ap.add_argument("--exclude-duration", action="store_true", help="Exclude duration from clustering features")
    args = ap.parse_args()

    df = pd.read_csv(args.csv_path)
    print(f"Loaded {len(df)} fragments from {args.csv_path}")

    feature_cols = pick_feature_columns(df, args.exclude_pitch, args.exclude_duration)
    print(f"Using {len(feature_cols)} feature columns for clustering:")
    print("  " + ", ".join(feature_cols))

    # Drop rows with any NaN/inf in the feature set (shouldn't normally happen,
    # but a corrupt/silent fragment could produce one).
    feat_df = df[feature_cols].replace([np.inf, -np.inf], np.nan)
    valid_mask = feat_df.notna().all(axis=1)
    n_dropped = (~valid_mask).sum()
    if n_dropped:
        print(f"Dropping {n_dropped} fragments with invalid feature values.")
    df = df[valid_mask].reset_index(drop=True)
    feat_df = feat_df[valid_mask].reset_index(drop=True)

    scaler = StandardScaler()
    X = scaler.fit_transform(feat_df.values)

    if args.auto_k:
        k = auto_select_k(X)
    else:
        k = args.k if args.k is not None else 10

    print(f"Running k-means with k={k}...")
    km = KMeans(n_clusters=k, n_init=10, random_state=42)
    labels = km.fit_predict(X)
    distances = km.transform(X)  # distance to every centroid
    dist_to_own_centroid = distances[np.arange(len(labels)), labels]

    df["cluster_id"] = labels
    df["cluster_distance"] = dist_to_own_centroid

    # Also store the z-scored feature values themselves, prefixed with z_,
    # so downstream matching scripts can reuse them without re-normalizing.
    z_cols = {f"z_{c}": X[:, i] for i, c in enumerate(feature_cols)}
    for name, values in z_cols.items():
        df[name] = values

    df.to_csv(args.out, index=False)
    print(f"\nWrote {len(df)} fragments with cluster assignments to {args.out}")

    cluster_counts = df["cluster_id"].value_counts().sort_index()
    print("\nCluster sizes:")
    for cid, count in cluster_counts.items():
        print(f"  cluster {cid:2d}: {count:4d} fragments")

    scaler_info = {
        "feature_columns": feature_cols,
        "mean": scaler.mean_.tolist(),
        "scale": scaler.scale_.tolist(),
        "n_clusters": int(k),
        "cluster_centers": km.cluster_centers_.tolist(),
    }
    with open(args.scaler_out, "w") as f:
        json.dump(scaler_info, f, indent=2)
    print(f"Saved normalization scaler + cluster centers to {args.scaler_out}")


if __name__ == "__main__":
    main()
