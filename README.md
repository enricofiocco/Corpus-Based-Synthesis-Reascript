# Corpus-based Synthesis Engine for REAPER

Corpus-based / concatenative synthesis for REAPER (ReaScript/Lua) + Python. Analyzes a folder of
audio, segments and describes every fragment (spectral, dynamic, timbral, pitch), clusters it by
timbre, and lets you resynthesize new material by matching a target sound, generating a free
chain, or playing the corpus live as a CataRT-style instrument.

## Pipeline

```
audio folder → analyze_corpus.py → corpus.csv → cluster_corpus.py → corpus_clustered.csv + scaler
                                                                            │
                          ┌─────────────────────┬──────────────────────────┼───────────────────┐
                   match_target.py        generate_chain.lua    navigate_descriptor_    Browse_corpus.lua
                   + place_matches.lua                           space_ui.lua            (live instrument)
```

`Create_corpus.lua` runs the analysis + clustering steps from inside REAPER, in the background.
`add_to_corpus.py` adds new audio to an existing corpus instead of rebuilding it from scratch.

## Requirements

- REAPER
- [SWS Extension](https://www.sws-extension.org/) — **required**, powers audio prelisten in the browser (free)
- [js_ReaScriptAPI](https://forum.cockos.com/showthread.php?t=212174) — optional, gives a native folder picker
- Python 3.9+ with `librosa`, `soundfile`, `numpy`, `pandas`, `scikit-learn`

## Install

### 1. Python + libraries

<details>
<summary><strong>macOS</strong></summary>

```bash
brew install python          # get Homebrew first if needed: https://brew.sh
python3 --version
pip3 install --user --break-system-packages librosa soundfile numpy pandas scikit-learn
which python3                # copy this full path — you'll need it in REAPER, see note below
```
</details>

<details>
<summary><strong>Windows</strong></summary>

1. Install Python from [python.org/downloads](https://www.python.org/downloads/windows/) — check **"Add python.exe to PATH"**
2. `python --version`
3. `python -m pip install --user librosa soundfile numpy pandas scikit-learn`
4. `where python` — copy this full path — you'll need it in REAPER, see note below
</details>

<details>
<summary><strong>Linux (Debian/Ubuntu)</strong></summary>

```bash
sudo apt install python3 python3-pip
python3 --version
pip3 install --user --break-system-packages librosa soundfile numpy pandas scikit-learn
which python3                # copy this full path — you'll need it in REAPER, see note below
```
</details>

> **Important:** paste the **full path** you copied above (not just `python3`/`python`) into the
> "Python executable" field in `Create_corpus.lua`. REAPER doesn't load your shell's PATH, so the
> bare command usually resolves to the wrong, package-less interpreter.
>
> **`--break-system-packages` fails or unavailable?** Use a virtual environment instead:
> ```bash
> python3 -m venv ~/corpus-venv && source ~/corpus-venv/bin/activate
> pip install librosa soundfile numpy pandas scikit-learn
> ```
> Then use the venv's `python3` path (e.g. `~/corpus-venv/bin/python3`) in REAPER.

### 2. REAPER extensions

- **SWS** — download the installer for your OS from [sws-extension.org](https://www.sws-extension.org/), run it, restart REAPER.
- **js_ReaScriptAPI** (optional) — install [ReaPack](https://reapack.com/) first, then in REAPER:
  `Extensions > ReaPack > Browse packages...` → search **js_ReaScriptAPI** → Install → `Extensions > ReaPack > Apply changes` → restart REAPER.

### 3. Project setup

1. Download this repo, keeping all `.py` and `.lua` files **in one folder** (scripts auto-detect their own folder to find each other).
2. In REAPER, for each `.lua` file: `Actions > Show action list > New action... > Load ReaScript...`

> **Windows note:** `Create_corpus.lua`'s background execution uses POSIX shell syntax and won't
> run Python jobs asynchronously. Run `analyze_corpus.py` / `cluster_corpus.py` directly from
> PowerShell instead.

## Scripts

| Script | What it does |
|---|---|
| `analyze_corpus.py` | Segments a folder of audio and extracts descriptors → `corpus.csv` |
| `add_to_corpus.py` | Adds new audio to an existing `corpus.csv`, skipping already-analyzed files |
| `cluster_corpus.py` | Normalizes features and k-means clusters by timbre → `corpus_clustered.csv` + scaler |
| `Browse_corpus.lua` | Live CataRT-style instrument: XY plot, prelisten, trigger modes, record-to-timeline |
| `Create_corpus.lua` | GUI to run analysis + clustering from inside REAPER, in the background |


Pipeline outputs (CSV/JSON) default to a `corpus_data/` subfolder next to the scripts.
`Browse_corpus.lua` shows an in-window picker listing any CSVs found there.

## Quick start

1. Run `Create_corpus.lua` → pick your audio folder → **RUN PIPELINE**.
2. Run `Browse_corpus.lua` → pick a corpus → move the mouse to prelisten, click to place, toggle **Record** to capture a performance to the timeline.
3. For target-driven resynthesis: run `match_target.py` against a target file, then `place_matches.lua`.

## Troubleshooting

<details>
<summary><code>ModuleNotFoundError</code> when run from REAPER but not from Terminal</summary>

Use the full Python path (see the install steps above), not just `python3`/`python`.
</details>

<details>
<summary>"This script needs the SWS extension"</summary>

Install SWS (see above), then restart REAPER.
</details>

<details>
<summary>Window looks wrong on a retina/HiDPI display</summary>

Display scaling should be auto-detected. If it still looks off, open an issue with your OS and display details.
</details>

<details>
<summary>Only a file picker shows up, not a folder picker</summary>

Install js_ReaScriptAPI (optional, see above), or use the built-in fallback: pick any file inside the target folder.
</details>

## License

MIT License
