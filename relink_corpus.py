#!/usr/bin/env python3
"""
relink_corpus.py -- re-point a corpus CSV to a moved/renamed sound folder.

The corpus stores the absolute path of every source file (column file_path).
If you move the audio folder, run this once on each CSV
(corpus.csv AND corpus_clustered.csv) -- no re-analysis needed.

Usage:
    # old folder auto-detected (common parent of all paths in the CSV)
    python3 relink_corpus.py corpus_data/mysounds.csv corpus_data/mysounds_clustered.csv --new /Volumes/Disk/mysounds

    # or give the old folder explicitly
    python3 relink_corpus.py corpus_data/mysounds.csv --old /Users/me/old --new /Users/me/new

A backup (.bak) of each CSV is written first. Sub-folders are preserved.
"""
import argparse, csv, os, shutil, sys


def common_dir(paths):
    return os.path.dirname(os.path.commonprefix(paths)) if len(set(paths)) > 1 else os.path.dirname(paths[0])


def main():
    ap = argparse.ArgumentParser(description="Re-point corpus CSVs to a moved audio folder.")
    ap.add_argument("csv", nargs="+", help="Corpus CSV file(s) to update")
    ap.add_argument("--new", required=True, help="New audio folder")
    ap.add_argument("--old", default=None, help="Old audio folder (default: auto-detect)")
    args = ap.parse_args()
    new = args.new.rstrip("/\\")

    for path in args.csv:
        with open(path, newline="") as f:
            rows = list(csv.DictReader(f))
            fields = rows and list(rows[0].keys())
        if not rows or "file_path" not in rows[0]:
            print(f"{path}: no file_path column, skipped"); continue
        old = (args.old or common_dir([r["file_path"] for r in rows])).rstrip("/\\")
        changed = missing = 0
        for r in rows:
            p = r["file_path"]
            if p.startswith(old):
                r["file_path"] = new + p[len(old):]
                changed += 1
            if not os.path.exists(r["file_path"]):
                missing += 1
        shutil.copy2(path, path + ".bak")
        with open(path, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=fields)
            w.writeheader(); w.writerows(rows)
        print(f"{path}: {old} -> {new}  ({changed}/{len(rows)} rows updated, {missing} files still not found)")


if __name__ == "__main__":
    main()
