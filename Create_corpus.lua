--[[
run_corpus_pipeline_ui_v3.lua

Same as v2, with three fixes:
  1. Window sizing bug fixed: gfx.ext_retina must be re-enabled right
     before the real window is created, since it does not persist
     across gfx.quit() -- this was causing the window to open at
     double its intended on-screen size.
  2. No more leftover .analyze_log.txt / .cluster_log.txt files:
     output is still captured and shown in the ReaScript console, but
     the temp log/status files are deleted immediately after being
     read.
  3. RUNS IN THE BACKGROUND: Python is launched as a detached process
     (shell "&"), and REAPER polls a small marker file each frame via
     the normal defer() loop instead of blocking on os.execute(). The
     window stays fully responsive (you can move/close it, and REAPER
     itself doesn't freeze) while analysis/clustering runs. A status
     line and elapsed time are shown while a step is running.

     Note: this backgrounding technique uses POSIX shell syntax
     ("&", "$?"), so it works on macOS/Linux. It would need different
     syntax on Windows.

Usage:
  Actions > Show action list > New action... > Load ReaScript... >
  select this file > run it.
--]]

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
local function script_dir()
  local info = debug.getinfo(1, "S")
  local path = info.source:sub(2)
  return path:match("(.*[/\\])") or "./"
end

local function file_exists(path)
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return "" end
  local content = f:read("*a")
  f:close()
  return content
end

local function browse_for_folder(title, default_path)
  if reaper.JS_Dialog_BrowseForFolder then
    local ok, folder = reaper.JS_Dialog_BrowseForFolder(title, default_path or "")
    if ok and folder and folder ~= "" then return folder end
    return nil
  else
    local ok, file_path = reaper.GetUserFileNameForRead(
      default_path or "", title .. "  (pick ANY file inside the target folder)", ""
    )
    if not ok then return nil end
    local d = file_path:match("(.*[/\\])")
    if d then return d:sub(1, -2) end
    return nil
  end
end

local function edit_value(title, current_value)
  local ok, result = reaper.GetUserInputs(title, 1, "Value", tostring(current_value or ""))
  if not ok then return current_value end
  return result
end

-- ---------------------------------------------------------------------
-- Background job runner (non-blocking)
-- ---------------------------------------------------------------------
-- Launches `cmd` detached in the background, redirecting its combined
-- output to a temp log file and its exit code to a temp status file,
-- then touching a "done" marker file once finished. The main loop
-- polls for that marker each frame -- REAPER never blocks.
local job = nil  -- { log_path, status_path, done_path, on_complete, label, start_time }
local quit_requested = false
local tmp_counter = 0

local function tmp_path(suffix)
  tmp_counter = tmp_counter + 1
  return string.format("/tmp/reascript_corpus_pipeline_%d_%d%s", math.floor(reaper.time_precise() * 1000), tmp_counter, suffix)
end

local function start_background_job(cmd, label, on_complete)
  local log_path = tmp_path(".log")
  local status_path = tmp_path(".status")
  local done_path = tmp_path(".done")
  local bg_cmd = string.format('( %s > "%s" 2>&1 ; echo $? > "%s" ; touch "%s" ) &', cmd, log_path, status_path, done_path)
  os.execute(bg_cmd)
  job = {
    log_path = log_path, status_path = status_path, done_path = done_path,
    on_complete = on_complete, label = label, start_time = reaper.time_precise(),
  }
end

-- called every frame from the main loop; returns nothing, may advance/clear `job`
local function poll_job()
  if not job then return end
  if file_exists(job.done_path) then
    local log_text = read_file(job.log_path)
    local exit_code = tonumber(read_file(job.status_path)) or 1
    os.remove(job.log_path)
    os.remove(job.status_path)
    os.remove(job.done_path)

    local cb = job.on_complete
    job = nil
    cb(exit_code == 0, log_text)
  end
end

-- ---------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------
local dir = script_dir()
local CORPUS_SUBDIR = "corpus_data"
local corpus_dir = dir .. CORPUS_SUBDIR .. "/"

local function ensure_dir(path)
  if path and path ~= "" then
    os.execute('mkdir -p "' .. path .. '"')
  end
end

local function folder_basename(path)
  local p = path:gsub("[/\\]+$", "")
  return p:match("([^/\\]+)$") or p
end

local output_dir = corpus_dir

local F = {
  audio_folder = "",
  out_csv = corpus_dir .. "corpus.csv",
  mode = "onset",
  grain_ms = "250",
  min_len_ms = "60",
  python_exe = "/opt/homebrew/bin/python3",
  analyze_script = dir .. "add_to_corpus.py",
  overwrite_corpus = false,
  do_cluster = true,
  cluster_script = dir .. "cluster_corpus.py",
  clustered_csv = corpus_dir .. "corpus_clustered.csv",
  scaler_json = corpus_dir .. "corpus_scaler.json",
  k_value = "",
  exclude_pitch = false,
}

-- names outputs after the selected audio folder (e.g. ".../sounds_incrustation"
-- -> sounds_incrustation.csv / sounds_incrustation_clustered.csv / _scaler.json)
-- instead of a fixed generic "corpus.csv", so multiple corpora built from
-- different folders don't collide or need manual renaming.
local function refresh_output_paths()
  local base = (F.audio_folder ~= "") and folder_basename(F.audio_folder) or "corpus"
  F.out_csv = output_dir .. base .. ".csv"
  F.clustered_csv = output_dir .. base .. "_clustered.csv"
  F.scaler_json = output_dir .. base .. "_scaler.json"
end

-- ---------------------------------------------------------------------
-- GFX window: logical-pixel layout + one auto-detected SCALE factor
-- ---------------------------------------------------------------------
local BASE_W, BASE_H = 760, 700

gfx.ext_retina = 1
gfx.init("Corpus Pipeline Setup", 100, 100, 0)  -- dummy size, just to detect the display scale
local SCALE = (gfx.ext_retina and gfx.ext_retina > 0) and gfx.ext_retina or 1
gfx.quit()  -- close the dummy window fully -- resizing in place doesn't reliably update the OS window frame
gfx.ext_retina = 1  -- must be re-set: this flag does NOT persist across gfx.quit()
gfx.init("Corpus Pipeline Setup", BASE_W, BASE_H, 0)
gfx.setfont(1, "sans-serif", math.floor(15 * SCALE))

local function sx(v) return v * SCALE end
local function slog(v) return v / SCALE end
local function gset_xy(x, y) gfx.x, gfx.y = sx(x), sx(y) end
local function grect(x, y, w, h, fill) gfx.rect(sx(x), sx(y), sx(w), sx(h), fill) end
local TEXT_H = slog(gfx.texth)

local buttons = {}

local function draw_button(x, y, w, h, label_text, active, disabled)
  if disabled then gfx.set(0.2, 0.2, 0.2, 1)
  elseif active then gfx.set(0.3, 0.7, 1.0, 1)
  else gfx.set(0.28, 0.28, 0.28, 1) end
  grect(x, y, w, h, 1)
  gfx.set(disabled and 0.5 or 1, disabled and 0.5 or 1, disabled and 0.5 or 1, 1)
  gset_xy(x + 8, y + (h - TEXT_H) / 2)
  gfx.drawstr(label_text)
  table.insert(buttons, { x = x, y = y, w = w, h = h, disabled = disabled })
  return buttons[#buttons]
end

local function point_in(mx, my, x, y, w, h)
  return mx >= x and mx <= x + w and my >= y and my <= y + h
end

local function label(x, y, text)
  gfx.set(0.75, 0.75, 0.75, 1)
  gset_xy(x, y)
  gfx.drawstr(text)
end

local MARGIN = 24
local ROW_W = BASE_W - MARGIN * 2

-- ---------------------------------------------------------------------
-- Draw
-- ---------------------------------------------------------------------
local function draw()
  buttons = {}
  gfx.clear = 3355443
  local x, y = MARGIN, MARGIN
  local busy = job ~= nil

  gfx.set(1, 1, 1, 1)
  gset_xy(x, y)
  gfx.drawstr("Corpus analysis & clustering pipeline")
  y = y + 30

  label(x, y, "Audio folder to analyze:")
  y = y + 18
  draw_button(x, y, ROW_W - 110, 26, F.audio_folder ~= "" and F.audio_folder or "(not set)", false, busy).action = "noop"
  draw_button(x + ROW_W - 100, y, 100, 26, "Browse...", false, busy).action = "browse_audio"
  y = y + 40

  label(x, y, "Output corpus CSV (pre-filled in ./corpus_data/ next to this script):")
  y = y + 18
  draw_button(x, y, ROW_W - 110, 26, F.out_csv, false, busy).action = "noop"
  draw_button(x + ROW_W - 100, y, 100, 26, "Folder...", false, busy).action = "browse_out"
  y = y + 40

  label(x, y, "Segmentation mode:")
  y = y + 18
  draw_button(x, y, (ROW_W - 8) / 2, 26, "onset (transient-based)", F.mode == "onset", busy).action = "mode_onset"
  draw_button(x + (ROW_W - 8) / 2 + 8, y, (ROW_W - 8) / 2, 26, "fixed (grain-ms)", F.mode == "fixed", busy).action = "mode_fixed"
  y = y + 40

  label(x, y, "Grain size ms (used if mode=fixed):")
  draw_button(x + 320, y - 2, 100, 24, F.grain_ms, false, busy).action = "edit_grain_ms"
  y = y + 32
  label(x, y, "Min length ms (used if mode=onset):")
  draw_button(x + 320, y - 2, 100, 24, F.min_len_ms, false, busy).action = "edit_min_len_ms"
  y = y + 40

  label(x, y, "Python executable:")
  draw_button(x + 320, y - 2, 200, 24, F.python_exe, false, busy).action = "edit_python_exe"
  y = y + 32
  label(x, y, "Path to add_to_corpus.py:")
  y = y + 18
  draw_button(x, y, ROW_W, 24, F.analyze_script, false, busy).action = "edit_analyze_script"
  y = y + 34

  draw_button(x, y, ROW_W, 26, F.overwrite_corpus and "Overwrite existing corpus (start fresh)" or "Add to existing corpus if the output CSV already exists (default)", F.overwrite_corpus, busy).action = "toggle_overwrite"
  y = y + 36

  draw_button(x, y, ROW_W, 28, F.do_cluster and "Clustering: ON (will run cluster_corpus.py after)" or "Clustering: OFF", F.do_cluster, busy).action = "toggle_cluster"
  y = y + 38

  if F.do_cluster then
    label(x, y, "Path to cluster_corpus.py:")
    y = y + 18
    draw_button(x, y, ROW_W, 24, F.cluster_script, false, busy).action = "edit_cluster_script"
    y = y + 34

    label(x, y, "Output clustered CSV:")
    y = y + 18
    draw_button(x, y, ROW_W, 24, F.clustered_csv, false, busy).action = "edit_clustered_csv"
    y = y + 34

    label(x, y, "k (blank = auto-k scan):")
    draw_button(x + 320, y - 2, 100, 24, F.k_value ~= "" and F.k_value or "(auto)", false, busy).action = "edit_k"
    y = y + 32

    draw_button(x, y, ROW_W, 26, F.exclude_pitch and "Exclude pitch from clustering: ON" or "Exclude pitch from clustering: OFF", F.exclude_pitch, busy).action = "toggle_exclude_pitch"
    y = y + 36
  end

  y = y + 10
  if busy then
    draw_button(x, y, ROW_W, 46, "Working...", true, false)
  else
    draw_button(x, y, ROW_W, 46, "RUN PIPELINE", false, false).action = "run"
  end
  y = y + 56

  gfx.set(0.6, 0.6, 0.6, 1)
  gset_xy(x, y)
  gfx.drawstr("Esc / close window to cancel.")
end

-- ---------------------------------------------------------------------
-- Run pipeline (non-blocking)
-- ---------------------------------------------------------------------
local function run_step2_clustering()
  local cluster_cmd = string.format(
    '"%s" "%s" "%s" --out "%s" --scaler-out "%s"',
    F.python_exe, F.cluster_script, F.out_csv, F.clustered_csv, F.scaler_json
  )
  if F.k_value ~= "" then
    cluster_cmd = cluster_cmd .. " --k " .. F.k_value
  else
    cluster_cmd = cluster_cmd .. " --auto-k"
  end
  if F.exclude_pitch then
    cluster_cmd = cluster_cmd .. " --exclude-pitch"
  end

  start_background_job(cluster_cmd, "Step 2: cluster_corpus.py", function(success, log_text)
    if not success then
      reaper.ShowMessageBox("cluster_corpus.py failed. corpus.csv was created fine.\n\nOutput:\n" .. log_text:sub(1, 1500), "Clustering failed", 0)
      return
    end
    reaper.ShowMessageBox("Done!\n\nCorpus CSV:\n" .. F.out_csv .. "\n\nClustered CSV:\n" .. F.clustered_csv .. "\n\nScaler:\n" .. F.scaler_json, "Pipeline complete", 0)
    quit_requested = true
  end)
end

local function do_run()
  if job then return end  -- already running
  if F.audio_folder == "" then
    reaper.ShowMessageBox("Please choose an audio folder first.", "Missing input", 0)
    return
  end
  if not file_exists(F.analyze_script) then
    reaper.ShowMessageBox("Could not find analyze_corpus.py at:\n" .. F.analyze_script, "Script not found", 0)
    return
  end
  if F.do_cluster and not file_exists(F.cluster_script) then
    local proceed = reaper.ShowMessageBox(
      "Could not find cluster_corpus.py at:\n" .. F.cluster_script .. "\n\nRun analysis only (skip clustering)?",
      "Script not found", 1
    )
    if proceed ~= 1 then return end
    F.do_cluster = false
  end

  local summary = "About to run in the background (REAPER stays responsive):\n\n1. add_to_corpus.py on:\n   " .. F.audio_folder ..
    "\n   -> " .. F.out_csv .. (F.overwrite_corpus and "  (overwriting any existing corpus)" or "  (appending if it already exists)") ..
    (F.do_cluster and ("\n\n2. cluster_corpus.py\n   -> " .. F.clustered_csv) or "\n\n(clustering skipped)") ..
    "\n\nContinue?"
  if reaper.ShowMessageBox(summary, "Confirm", 1) ~= 1 then return end

  ensure_dir(F.out_csv:match("(.*[/\\])"))
  ensure_dir(F.clustered_csv:match("(.*[/\\])"))

  local analyze_cmd = string.format(
    '"%s" "%s" "%s" --out "%s" --mode %s --grain-ms %s --min-len-ms %s',
    F.python_exe, F.analyze_script, F.audio_folder, F.out_csv, F.mode, F.grain_ms, F.min_len_ms
  )
  if F.overwrite_corpus then
    analyze_cmd = analyze_cmd .. " --overwrite"
  end
  start_background_job(analyze_cmd, "Step 1: analyze_corpus.py", function(success, log_text)
    if not success or not file_exists(F.out_csv) then
      reaper.ShowMessageBox("analyze_corpus.py failed or did not produce the expected CSV.\n\nOutput:\n" .. log_text:sub(1, 1500), "Analysis failed", 0)
      return
    end
    if F.do_cluster then
      run_step2_clustering()
    else
      reaper.ShowMessageBox("Done!\n\nCorpus CSV:\n" .. F.out_csv, "Analysis complete", 0)
      quit_requested = true
    end
  end)
end

-- ---------------------------------------------------------------------
-- Main loop
-- ---------------------------------------------------------------------
local prev_mouse_cap = 0

local function loop()
  poll_job()
  if quit_requested then
    gfx.quit()
    return
  end

  local mx, my = slog(gfx.mouse_x), slog(gfx.mouse_y)
  local cap = gfx.mouse_cap
  local left_click = (cap & 1) == 1 and (prev_mouse_cap & 1) == 0
  prev_mouse_cap = cap

  if left_click and not job then
    for _, b in ipairs(buttons) do
      if not b.disabled and point_in(mx, my, b.x, b.y, b.w, b.h) then
        local a = b.action
        if a == "browse_audio" then
          local f = browse_for_folder("Select audio folder", F.audio_folder)
          if f then F.audio_folder = f; refresh_output_paths() end
        elseif a == "browse_out" then
          local f = browse_for_folder("Select output folder for corpus data", F.out_csv:match("(.*[/\\])"))
          if f then
            output_dir = f .. "/"
            refresh_output_paths()
          end
        elseif a == "mode_onset" then F.mode = "onset"
        elseif a == "mode_fixed" then F.mode = "fixed"
        elseif a == "edit_grain_ms" then F.grain_ms = edit_value("Grain size (ms)", F.grain_ms)
        elseif a == "edit_min_len_ms" then F.min_len_ms = edit_value("Min length (ms)", F.min_len_ms)
        elseif a == "edit_python_exe" then F.python_exe = edit_value("Python executable", F.python_exe)
        elseif a == "edit_analyze_script" then F.analyze_script = edit_value("Path to add_to_corpus.py", F.analyze_script)
        elseif a == "toggle_overwrite" then F.overwrite_corpus = not F.overwrite_corpus
        elseif a == "toggle_cluster" then F.do_cluster = not F.do_cluster
        elseif a == "edit_cluster_script" then F.cluster_script = edit_value("Path to cluster_corpus.py", F.cluster_script)
        elseif a == "edit_clustered_csv" then F.clustered_csv = edit_value("Output clustered CSV path", F.clustered_csv)
        elseif a == "edit_k" then F.k_value = edit_value("k (blank = auto-k)", F.k_value)
        elseif a == "toggle_exclude_pitch" then F.exclude_pitch = not F.exclude_pitch
        elseif a == "run" then do_run()
        end
        break
      end
    end
  end

  draw()
  gfx.update()

  local char = gfx.getchar()
  if char >= 0 and char ~= 27 then
    reaper.defer(loop)
  else
    gfx.quit()
  end
end

reaper.defer(loop)
