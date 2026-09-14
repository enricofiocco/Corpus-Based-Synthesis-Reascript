--[[
Browse_corpus.lua

Interactive CataRT-style browser/instrument for a concatenative synthesis
corpus. Every fragment is plotted on a 2D grid positioned by two
descriptors you choose. Move the mouse to prelisten units (per one of
five trigger modes -- bow/fence/chain/beat/cont), click to place the
current unit, and toggle Record to capture a live performance straight
onto the timeline. All controls (axes, radius, trigger mode, grain
playback variation, min/max grain length) live in the same window.

Layout is done in logical pixels with an auto-detected display-scale
factor applied only at the point of drawing/measuring/reading the
mouse, so it looks correct on retina and non-retina displays, macOS
and Windows, without any manual per-display tuning.

REQUIRES THE SWS EXTENSION (for audio prelisten via CF_Preview_*).
Free: https://www.sws-extension.org/
--]]

if not reaper.CF_CreatePreview then
  reaper.ShowMessageBox(
    "This script needs the SWS extension for audio prelisten (CF_Preview_* functions).\n\n" ..
    "Free, widely used -- install from https://www.sws-extension.org/ and restart REAPER.",
    "SWS extension required", 0
  )
  return
end

-- ---------------------------------------------------------------------
-- CSV parsing
-- ---------------------------------------------------------------------
local function parse_csv_line(line)
  local fields, field, in_quotes = {}, "", false
  local i, n = 1, #line
  while i <= n do
    local c = line:sub(i, i)
    if in_quotes then
      if c == '"' then
        if line:sub(i + 1, i + 1) == '"' then field = field .. '"'; i = i + 1
        else in_quotes = false end
      else field = field .. c end
    else
      if c == '"' then in_quotes = true
      elseif c == "," then table.insert(fields, field); field = ""
      else field = field .. c end
    end
    i = i + 1
  end
  table.insert(fields, field)
  return fields
end

local function read_csv(path)
  local f = io.open(path, "r")
  if not f then return nil, "Could not open file: " .. path end
  local header, rows = nil, {}
  for line in f:lines() do
    if line ~= "" then
      local fields = parse_csv_line(line)
      if not header then header = fields
      else
        local row = {}
        for idx, key in ipairs(header) do row[key] = fields[idx] end
        table.insert(rows, row)
      end
    end
  end
  f:close()
  return rows, header
end

-- ---------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------
local function gauss(mean, std)
  if std == 0 then return mean end
  local u1, u2 = math.random(), math.random()
  return mean + math.sqrt(-2.0 * math.log(u1)) * math.cos(2.0 * math.pi * u2) * std
end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi else return v end end
local function db_to_amp(db) return 10 ^ (db / 20) end

-- ---------------------------------------------------------------------
-- Descriptor / cluster / mode descriptions
-- ---------------------------------------------------------------------
local DESCRIPTOR_INFO = {
  duration = "Length of the fragment, in seconds.",
  rms_mean = "Average loudness (RMS energy) of the fragment.",
  rms_max = "Peak loudness (RMS) within the fragment.",
  peak = "Highest sample amplitude (absolute peak) in the fragment.",
  crest_factor = "Peak-to-RMS ratio: how spiky/percussive vs. sustained the sound is.",
  spectral_centroid = "Brightness: 'center of mass' of the spectrum in Hz. Higher = brighter/sharper.",
  spectral_flatness = "Tonal vs. noisy: near 0 = tonal/pitched, near 1 = noise-like.",
  spectral_rolloff = "Frequency below which most spectral energy sits (Hz). Related to brightness.",
  spectral_bandwidth = "Spread of the spectrum: narrow = focused tone, wide = noisy/rich.",
  zcr = "Zero-crossing rate: how often the waveform crosses zero. Higher = noisier material.",
  pitch_hz = "Estimated fundamental pitch in Hz (0 if no clear pitch detected).",
  pitch_confidence = "Confidence (0-1) of the pitch estimate; low = likely unpitched/noisy.",
}
local function descriptor_description(name)
  if DESCRIPTOR_INFO[name] then return DESCRIPTOR_INFO[name] end
  if name:match("^mfcc%d+$") then
    return "MFCC coefficient: part of the timbral 'fingerprint' describing spectral envelope shape."
  end
  return "No description available for this column."
end

local CLUSTER_DESCRIPTION =
  "Clusters group fragments with similar overall timbre, found automatically (k-means over all " ..
  "descriptors together, from cluster_corpus.py). 'ALL' ignores clustering and browses everything."

local MODE_DESCRIPTIONS = {
  bow   = "Retriggers a new (randomized) unit every time you move the mouse.",
  fence = "Retriggers only when the nearest unit changes -- calmer than bow.",
  chain = "Auto-repeats: triggers a new unit as soon as the previous one finishes, following the mouse.",
  beat  = "Auto-triggers on a steady pulse (Beat rate), following the mouse.",
  cont  = "Ignores the mouse; steps sequentially through the whole pool.",
}

-- ---------------------------------------------------------------------
-- Find CSVs in <script folder>/corpus_data/ (where the pipeline scripts
-- save output by default)
-- ---------------------------------------------------------------------
local function script_dir()
  local info = debug.getinfo(1, "S")
  local path = info.source:sub(2)
  return path:match("(.*[/\\])") or "./"
end

local function list_csv_files(dir_path)
  local files = {}
  local p = io.popen('ls "' .. dir_path .. '" 2>/dev/null')
  if p then
    for line in p:lines() do
      if line:match("%.csv$") then table.insert(files, line) end
    end
    p:close()
  end
  table.sort(files)
  return files
end

local CORPUS_DIR = script_dir() .. "corpus_data/"

-- ---------------------------------------------------------------------
-- GFX window: logical-pixel layout + one auto-detected SCALE factor
-- ---------------------------------------------------------------------
-- Everything below (margins, button sizes, font size 15, etc.) is
-- expressed in LOGICAL pixels -- the same numbers, regardless of
-- display. SCALE (1.0 on a normal display, 2.0 on a typical retina
-- display, etc.) is detected once, then a thin wrapper layer converts
-- logical -> physical pixels only at the point of drawing/measuring/
-- reading the mouse, so layout never has to be hand-tuned per display.
local BASE_W, BASE_H = 1180, 840
local MARGIN_L, MARGIN_T, MARGIN_B = 60, 20, 50
local SIDEBAR_W = 270
local PLOT_RIGHT = BASE_W - SIDEBAR_W
local PLOT_W = PLOT_RIGHT - MARGIN_L - 10
local PLOT_H = BASE_H - MARGIN_T - MARGIN_B
local SIDEBAR_X = PLOT_RIGHT + 10

gfx.ext_retina = 1
gfx.init("CataRT-style browser", 100, 100, 0)  -- dummy size, just to detect the display scale
local SCALE = (gfx.ext_retina and gfx.ext_retina > 0) and gfx.ext_retina or 1
gfx.quit()  -- close the dummy window fully -- resizing in place doesn't reliably update the OS window frame
gfx.ext_retina = 1  -- must be re-set: this flag does NOT persist across gfx.quit()
gfx.init("CataRT-style browser", BASE_W, BASE_H, 0)
gfx.setfont(1, "sans-serif", math.floor(15 * SCALE))

local function sx(v) return v * SCALE end
local function slog(v) return v / SCALE end
local function gset_xy(x, y) gfx.x, gfx.y = sx(x), sx(y) end
local function grect(x, y, w, h, fill) gfx.rect(sx(x), sx(y), sx(w), sx(h), fill) end
local function gcircle(x, y, r, fill, aa) gfx.circle(sx(x), sx(y), sx(r), fill, aa) end
local function gmeasure(text) return slog((gfx.measurestr(text))) end
local TEXT_H = slog(gfx.texth)

local function plot_to_screen(nx, ny)
  return MARGIN_L + nx * PLOT_W, MARGIN_T + (1 - ny) * PLOT_H
end

-- ---------------------------------------------------------------------
-- Corpus loading (reusable -- called at startup and again from the
-- in-window "Corpus" button, so you can switch corpora without
-- restarting the script)
-- ---------------------------------------------------------------------
local BLACKLIST = { cluster_id = true, cluster_distance = true, start_sec = true, end_sec = true }

local function find_idx(list, name)
  for i, v in ipairs(list) do if v == name then return i end end
  return nil
end

local rows_all, header, CANDIDATE_DESCRIPTORS, CLUSTER_OPTIONS, current_csv_path
local last_triggered_idx = nil

local S = {
  x_idx = 1,
  y_idx = 1,
  cluster_idx = 1,
  mode = "fence",
  rec_on = false,
  allow_overlap = true,
  radius = 0.08,
  transposition_std = 0.0,
  gain_std_db = 2.0,
  pan_std = 0.1,
  xfade_sec = 0,
  max_grain_ms = 300,
  min_grain_ms = 0,
  beat_rate_bpm = 240,
  retrigger_pct = 60,
}

local MODES = { "bow", "fence", "chain", "beat", "cont" }
local MIN_ITEM_LEN = 0.02
local pool = {}

local function rebuild_pool()
  pool = {}
  local xcol = CANDIDATE_DESCRIPTORS[S.x_idx]
  local ycol = CANDIDATE_DESCRIPTORS[S.y_idx]
  local cluster_val = CLUSTER_OPTIONS[S.cluster_idx].value
  local xmin, xmax = math.huge, -math.huge
  local ymin, ymax = math.huge, -math.huge
  for _, row in ipairs(rows_all) do
    local ok = true
    if cluster_val ~= nil then ok = (tonumber(row.cluster_id) == cluster_val) end
    local dur = tonumber(row.duration)
    if ok and dur and dur > 0 then
      local x = tonumber(row[xcol])
      local y = tonumber(row[ycol])
      if x and y then
        table.insert(pool, { row = row, x = x, y = y })
        if x < xmin then xmin = x end
        if x > xmax then xmax = x end
        if y < ymin then ymin = y end
        if y > ymax then ymax = y end
      end
    end
  end
  if xmax == xmin then xmax = xmin + 1 end
  if ymax == ymin then ymax = ymin + 1 end
  for i, p in ipairs(pool) do
    p.i = i
    p.nx = (p.x - xmin) / (xmax - xmin)
    p.ny = (p.y - ymin) / (ymax - ymin)
  end
end

-- Loads a corpus CSV: (re)computes descriptor/cluster options, tries to
-- keep the current X/Y axis choice if the new CSV still has those columns
-- (falls back to spectral_centroid/rms_mean, then to the first column),
-- resets the cluster filter, and rebuilds the pool. Returns true on success.
local function load_corpus(path)
  local new_rows, new_header = read_csv(path)
  if not new_rows or #new_rows == 0 then
    reaper.ShowMessageBox("Could not read CSV or it's empty: " .. path, "Error", 0)
    return false
  end

  local candidates = {}
  for _, col in ipairs(new_header) do
    if not BLACKLIST[col] and col:sub(1, 2) ~= "z_" and col ~= "file_path" then
      if tonumber(new_rows[1][col]) ~= nil then
        table.insert(candidates, col)
      end
    end
  end
  table.sort(candidates)
  if #candidates == 0 then
    reaper.ShowMessageBox("No numeric descriptor columns found in this CSV.", "Error", 0)
    return false
  end

  local cluster_set, has_clusters = {}, false
  for _, row in ipairs(new_rows) do
    local c = tonumber(row.cluster_id)
    if c then has_clusters = true; cluster_set[c] = true end
  end
  local cluster_opts = { { label = "Cluster: ALL", value = nil } }
  if has_clusters then
    local ids = {}
    for c, _ in pairs(cluster_set) do table.insert(ids, c) end
    table.sort(ids)
    for _, c in ipairs(ids) do table.insert(cluster_opts, { label = "Cluster: " .. c, value = c }) end
  end

  local old_x_name = CANDIDATE_DESCRIPTORS and CANDIDATE_DESCRIPTORS[S.x_idx]
  local old_y_name = CANDIDATE_DESCRIPTORS and CANDIDATE_DESCRIPTORS[S.y_idx]

  rows_all, header = new_rows, new_header
  CANDIDATE_DESCRIPTORS = candidates
  CLUSTER_OPTIONS = cluster_opts
  current_csv_path = path

  S.x_idx = (old_x_name and find_idx(candidates, old_x_name)) or find_idx(candidates, "spectral_centroid") or 1
  S.y_idx = (old_y_name and find_idx(candidates, old_y_name)) or find_idx(candidates, "rms_mean") or 1
  S.cluster_idx = 1

  rebuild_pool()
  last_triggered_idx = nil
  return true
end

-- ---------------------------------------------------------------------
-- Corpus picker state (the drawing function itself is defined after the
-- widget helpers below, since it uses draw_button)
-- ---------------------------------------------------------------------
local app_mode = "picking_corpus"  -- "picking_corpus" or "browsing"
local corpus_pick_items = {}

local function refresh_corpus_pick_items()
  corpus_pick_items = {}
  for _, f in ipairs(list_csv_files(CORPUS_DIR)) do
    table.insert(corpus_pick_items, { label = f, path = CORPUS_DIR .. f })
  end
end

math.randomseed(os.time())
refresh_corpus_pick_items()

-- (GFX window init happens earlier now, right after scanning corpus_data/,
-- so a quick-pick CSV menu can be shown before the rest of the UI is built)

-- ---------------------------------------------------------------------
-- Widgets (all logical-pixel coordinates)
-- ---------------------------------------------------------------------
local buttons = {}
local sliders = {
  { key = "radius", label = "Radius", min = 0.0, max = 0.5, fmt = "%.3f" },
  { key = "transposition_std", label = "Transpose std (st)", min = 0.0, max = 12.0, fmt = "%.1f" },
  { key = "gain_std_db", label = "Gain std (dB)", min = 0.0, max = 12.0, fmt = "%.1f" },
  { key = "pan_std", label = "Pan std", min = 0.0, max = 0.5, fmt = "%.2f" },
  { key = "xfade_sec", label = "Crossfade (s)", min = 0.0, max = 0.1, fmt = "%.3f" },
  { key = "max_grain_ms", label = "Max grain (ms, 0=off)", min = 0, max = 2000, fmt = "%.0f" },
  { key = "min_grain_ms", label = "Min grain (ms, 0=off)", min = 0, max = 1000, fmt = "%.0f" },
  { key = "beat_rate_bpm", label = "Beat rate (BPM)", min = 20, max = 600, fmt = "%.0f" },
  { key = "retrigger_pct", label = "Min playthrough before retrigger", min = 0, max = 100, fmt = "%.0f%%" },
}
local dragging_slider = nil

local function draw_button(x, y, w, h, label_text, active)
  if active then gfx.set(0.3, 0.7, 1.0, 1) else gfx.set(0.28, 0.28, 0.28, 1) end
  grect(x, y, w, h, 1)
  gfx.set(1, 1, 1, 1)
  gset_xy(x + 6, y + (h - TEXT_H) / 2)
  gfx.drawstr(label_text)
  table.insert(buttons, { x = x, y = y, w = w, h = h, label = label_text })
  return buttons[#buttons]
end

local function point_in(mx, my, x, y, w, h)
  return mx >= x and mx <= x + w and my >= y and my <= y + h
end

local function draw_slider(s, x, y, w)
  local val = S[s.key]
  local t = (val - s.min) / (s.max - s.min)
  gfx.set(1, 1, 1, 1)
  gset_xy(x, y)
  gfx.drawstr(string.format(s.label .. ": " .. s.fmt, val))
  local ty = y + 16
  gfx.set(0.22, 0.22, 0.22, 1); grect(x, ty, w, 12, 1)
  gfx.set(0.3, 0.7, 1.0, 1); grect(x, ty, w * clamp(t, 0, 1), 12, 1)
  s._x, s._y, s._w, s._h = x, ty, w, 12
end

local function wrap_text(text, maxw)
  local lines, line = {}, ""
  for word in text:gmatch("%S+") do
    local test = (line == "" and word or (line .. " " .. word))
    if gmeasure(test) > maxw and line ~= "" then
      table.insert(lines, line); line = word
    else
      line = test
    end
  end
  if line ~= "" then table.insert(lines, line) end
  return lines
end

local function draw_wrapped(text, x, y, maxw, r, g, b)
  gfx.set(r or 0.75, g or 0.75, b or 0.75, 1)
  for _, l in ipairs(wrap_text(text, maxw)) do
    gset_xy(x, y)
    gfx.drawstr(l)
    y = y + 15
  end
  return y
end

-- ---------------------------------------------------------------------
-- Corpus picker screen: in-window, styled like the rest of the UI --
-- shown before the XY browser, and again whenever "Corpus" is clicked,
-- instead of a native OS popup menu.
-- ---------------------------------------------------------------------
local function draw_corpus_picker()
  buttons = {}
  gfx.clear = 3355443
  local x, y = MARGIN_L, MARGIN_T

  gfx.set(1, 1, 1, 1)
  gset_xy(x, y)
  gfx.drawstr("Select a corpus to browse")
  y = y + 34

  local list_w = 460
  if #corpus_pick_items == 0 then
    gfx.set(0.75, 0.75, 0.75, 1)
    gset_xy(x, y)
    gfx.drawstr("No CSV files found in corpus_data/.")
    y = y + 30
  else
    for _, item in ipairs(corpus_pick_items) do
      local b = draw_button(x, y, list_w, 28, item.label, false)
      b.action = "pick_corpus_item"
      b.corpus_path = item.path
      y = y + 28 + 6
    end
  end

  y = y + 10
  draw_button(x, y, list_w, 30, "Browse for a different file...", false).action = "pick_browse"
end

-- ---------------------------------------------------------------------
-- Preview / trigger / record logic
-- ---------------------------------------------------------------------
local current_preview, preview_stop_time = nil, nil
local live_track = nil
local rec_start_time, rec_start_pos = nil, nil
local last_written_item, last_written_pos, last_written_len, last_written_fadeout = nil, nil, nil, nil

local function stop_preview()
  if current_preview then
    reaper.CF_Preview_Stop(current_preview)
    current_preview, preview_stop_time = nil, nil
  end
end

local function get_grain_len(row)
  local s = tonumber(row.start_sec)
  local e = tonumber(row.end_sec)
  local len = e - s
  local max_sec = (S.max_grain_ms and S.max_grain_ms > 0) and (S.max_grain_ms / 1000.0) or nil
  if max_sec and max_sec < len then len = max_sec end
  local min_sec = (S.min_grain_ms and S.min_grain_ms > 0) and (S.min_grain_ms / 1000.0) or nil
  if min_sec and len < min_sec then len = min_sec end  -- extends slightly past the fragment's detected end into adjacent source audio, if needed
  return s, len
end

local function ensure_live_track()
  if live_track and reaper.ValidatePtr(live_track, "MediaTrack*") then return end
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, true)
  live_track = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(live_track, "P_NAME", "Live Play", true)
end

local function move_cursor_to_recording_end()
  if last_written_pos and last_written_len then
    reaper.SetEditCurPos(last_written_pos + last_written_len, true, false)
  end
end

local function write_to_timeline(p)
  ensure_live_track()
  local row = p.row
  local src_start, frag_len = get_grain_len(row)
  local source = reaper.PCM_Source_CreateFromFile(row.file_path)
  if not source then return end

  local pos = rec_start_pos + (reaper.time_precise() - rec_start_time)

  if S.allow_overlap then
    -- Overlap ON: don't touch the previous item at all. Each item keeps its
    -- own natural length and its own small independent fade (set once at
    -- creation, just to avoid clicks). If the next grain's trigger happens
    -- to fall within the previous grain's span, the items simply overlap in
    -- time as a natural side effect of real trigger timing -- no artificial
    -- extension, no cap, no coupling between overlap amount and fade length.
  elseif last_written_item and reaper.ValidatePtr(last_written_item, "MediaItem*") then
    -- Overlap OFF: only ever trim DOWN (never extend) so items stay
    -- strictly sequential -- touching or gapped, never overlapping.
    local gap = pos - last_written_pos
    local prev_fadeout = last_written_fadeout or S.xfade_sec
    if gap < last_written_len then
      local new_len = math.max(gap, MIN_ITEM_LEN)
      reaper.SetMediaItemInfo_Value(last_written_item, "D_LENGTH", new_len)
      reaper.SetMediaItemInfo_Value(last_written_item, "D_FADEOUTLEN", math.min(prev_fadeout, new_len))
    end
  end

  local item = reaper.AddMediaItemToTrack(live_track)
  local take = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(take, source)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", pos)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", frag_len)
  reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", src_start)
  -- clamp fades to the grain's own length, exactly like the live preview does --
  -- previously this used the raw crossfade value unclamped, so short grains
  -- (especially with Min/Max grain length in use) could have most or all of
  -- their length eaten by fade-in+fade-out, sounding much shorter/weaker on
  -- the timeline than what was actually heard live
  local item_fade = math.min(S.xfade_sec, frag_len / 2)
  reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", item_fade)
  reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", item_fade)
  reaper.SetMediaItemInfo_Value(item, "C_FADEINSHAPE", 0)   -- linear, explicit -- don't depend on REAPER's global default fade shape
  reaper.SetMediaItemInfo_Value(item, "C_FADEOUTSHAPE", 0)

  reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", gauss(0, S.transposition_std))
  reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", 1)
  reaper.SetMediaItemTakeInfo_Value(take, "D_VOL", db_to_amp(gauss(0, S.gain_std_db)))
  reaper.SetMediaItemTakeInfo_Value(take, "D_PAN", (clamp(gauss(0.5, S.pan_std), 0, 1) - 0.5) * 2)

  local short_name = row.file_path:match("([^/\\]+)$") or row.file_path
  reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", short_name, true)
  reaper.UpdateArrange()

  last_written_item = item
  last_written_pos = pos
  last_written_len = frag_len
  last_written_fadeout = item_fade
end

local last_trigger_time = 0
local last_trigger_len = 0

-- gate before firing a new trigger: don't allow a new grain to interrupt the
-- previous one until it's played at least S.retrigger_pct% of its own nominal
-- length. This is the actual fix for grains being cut much shorter than their
-- configured length (and shorter than what's heard) when triggers fire faster
-- than a grain's duration, e.g. in bow/fence mode with a dense corpus where
-- the nearest point can change on every pixel of mouse movement.
local function can_trigger_now()
  if last_trigger_time == 0 then return true end
  local min_gap = last_trigger_len * (S.retrigger_pct / 100.0)
  return (reaper.time_precise() - last_trigger_time) >= min_gap
end

local function fire_trigger(p)
  stop_preview()
  local row = p.row
  local src_start, len = get_grain_len(row)
  local source = reaper.PCM_Source_CreateFromFile(row.file_path)
  if source then
    local preview = reaper.CF_CreatePreview(source)
    reaper.CF_Preview_SetValue(preview, "D_POSITION", src_start)
    reaper.CF_Preview_SetValue(preview, "D_VOLUME", 1.0)
    -- let CF_Preview stop itself at exactly `len` seconds (sample-accurate,
    -- enforced by the audio engine) instead of relying solely on our
    -- UI-frame polling loop to notice preview_stop_time has passed and call
    -- stop_preview() -- that polling has real latency (bound to defer/UI
    -- frame rate, easily 16-30ms+), so the preview could audibly play PAST
    -- its nominal length while the written item's D_LENGTH was always exact
    -- -- this asymmetry is what made preview sound longer than the
    -- recorded item, most noticeably on short grains. The manual polling
    -- stop below is kept as a fallback/safety net, not the primary stop
    -- mechanism anymore.
    reaper.CF_Preview_SetValue(preview, "D_LENGTH", len)
    -- NOTE: CF_Preview_SetValue("D_FADEINLEN"/"D_FADEOUTLEN", ...) used to be
    -- called here on the assumption those were real, supported CF_Preview
    -- parameter names (matching MediaItem property naming). The evidence
    -- (items sounding noticeably softer/shorter than preview at any non-zero
    -- crossfade, and the mismatch disappearing entirely at crossfade=0)
    -- strongly suggests SWS silently ignores unrecognized parameter names
    -- there, so those calls were likely doing nothing -- the preview has
    -- been playing at full, unshaped volume the whole time, while the
    -- WRITTEN ITEM's fades are real MediaItem properties and DO work,
    -- audibly softening it relative to an unfaded preview. Removed rather
    -- than left in place implying functionality that isn't there. Default
    -- crossfade is now 0 so there's nothing to disagree about out of the
    -- box; if you turn it up, expect the preview to stay click-prone (no
    -- fade) while written items will genuinely fade -- a real asymmetry
    -- until a working preview-side click-prevention method is found.
    reaper.CF_Preview_Play(preview)
    current_preview = preview
    preview_stop_time = reaper.time_precise() + len
  end
  last_triggered_idx = p.i
  last_trigger_time = reaper.time_precise()
  last_trigger_len = len

  if S.rec_on then
    reaper.Undo_BeginBlock()
    write_to_timeline(p)
    reaper.Undo_EndBlock("CataRT browser: write grain", -1)
  end
end

local function pick_near(nx, ny)
  if #pool == 0 then return nil end
  local radius = S.radius
  local candidates = {}
  local attempts = 0
  while #candidates == 0 and attempts < 12 do
    for _, p in ipairs(pool) do
      local dx, dy = p.nx - nx, p.ny - ny
      if math.sqrt(dx * dx + dy * dy) <= radius then table.insert(candidates, p) end
    end
    if #candidates == 0 then radius = radius * 1.6 + 0.01; attempts = attempts + 1 end
  end
  if #candidates == 0 then return nil end
  return candidates[math.random(1, #candidates)]
end

local function strict_nearest(nx, ny)
  local best_p, best_d = nil, math.huge
  for _, p in ipairs(pool) do
    local dx, dy = p.nx - nx, p.ny - ny
    local d = dx * dx + dy * dy
    if d < best_d then best_d, best_p = d, p end
  end
  return best_p
end

-- ---------------------------------------------------------------------
-- Draw
-- ---------------------------------------------------------------------
local function draw()
  buttons = {}
  gfx.clear = 3355443

  gfx.set(0.5, 0.5, 0.5, 1)
  grect(MARGIN_L, MARGIN_T, PLOT_W, PLOT_H, 0)

  for _, p in ipairs(pool) do
    local px, py = plot_to_screen(p.nx, p.ny)
    if p.i == last_triggered_idx then
      gfx.set(1.0, 0.85, 0.1, 1)
      gcircle(px, py, 5, 1, 1)
    else
      gfx.set(0.3, 0.7, 1.0, 0.55)
      gcircle(px, py, 2, 1, 1)
    end
  end

  gfx.set(1, 1, 1, 1)
  gset_xy(MARGIN_L, BASE_H - MARGIN_B + 24)
  local shown = false
  if last_triggered_idx then
    for _, p in ipairs(pool) do
      if p.i == last_triggered_idx then
        local short_name = p.row.file_path:match("([^/\\]+)$") or p.row.file_path
        gfx.drawstr(string.format("%s  (%.2fs)  cluster %s  |  mode: %s  |  pool: %d units",
          short_name, tonumber(p.row.duration) or 0, p.row.cluster_id or "-", S.mode, #pool))
        shown = true
        break
      end
    end
  end
  if not shown then
    gfx.drawstr(string.format("Move mouse to browse. Mode: %s. Pool: %d units.", S.mode, #pool))
  end

  -- ===================== SIDEBAR =====================
  local x, y = SIDEBAR_X, MARGIN_T
  local w = SIDEBAR_W - 20
  local bh = 24

  local current_csv_name = current_csv_path and (current_csv_path:match("([^/\\]+)$") or current_csv_path) or "(none)"
  draw_button(x, y, w, bh, "Corpus: " .. current_csv_name, false).action = "switch_corpus"
  y = y + bh + 10

  draw_button(x, y, w, bh, "X: " .. CANDIDATE_DESCRIPTORS[S.x_idx], false).action = "x_axis"
  y = y + bh + 4
  draw_button(x, y, w, bh, "Y: " .. CANDIDATE_DESCRIPTORS[S.y_idx], false).action = "y_axis"
  y = y + bh + 4
  draw_button(x, y, w, bh, CLUSTER_OPTIONS[S.cluster_idx].label, false).action = "cluster"
  y = y + bh + 4
  y = draw_wrapped(CLUSTER_DESCRIPTION, x, y, w) + 8

  gfx.set(1, 1, 1, 1); gset_xy(x, y); gfx.drawstr("Trigger mode:")
  y = y + 18
  local mw = (w - 4 * 4) / 5
  for i, m in ipairs(MODES) do
    local bx = x + (i - 1) * (mw + 4)
    draw_button(bx, y, mw, bh, m, S.mode == m).action = "mode_" .. m
  end
  y = y + bh + 4
  y = draw_wrapped(MODE_DESCRIPTIONS[S.mode] or "", x, y, w) + 8

  local rec_btn = draw_button(x, y, w, bh + 4, S.rec_on and "REC (on)" or "Record to timeline", S.rec_on)
  rec_btn.action = "rec"
  y = y + bh + 4 + 4

  draw_button(x, y, w, bh,
    S.allow_overlap and "Allow items to overlap: ON" or "Allow items to overlap: OFF",
    S.allow_overlap).action = "toggle_overlap"
  y = y + bh + 12

  for _, s in ipairs(sliders) do
    draw_slider(s, x, y, w)
    y = y + 34
  end

  y = y + 6
  gfx.set(1, 1, 1, 1); gset_xy(x, y); gfx.drawstr("Axis descriptors:")
  y = y + 18
  local xcol = CANDIDATE_DESCRIPTORS[S.x_idx]
  local ycol = CANDIDATE_DESCRIPTORS[S.y_idx]
  y = draw_wrapped("X - " .. xcol .. ": " .. descriptor_description(xcol), x, y, w) + 6
  y = draw_wrapped("Y - " .. ycol .. ": " .. descriptor_description(ycol), x, y, w) + 6

  gfx.set(0.7, 0.7, 0.7, 1)
  gset_xy(x, BASE_H - 24)
  gfx.drawstr("Esc / close window to quit")
end

-- ---------------------------------------------------------------------
-- Main loop
-- ---------------------------------------------------------------------
local prev_mouse_cap = 0
local last_mouse_nx, last_mouse_ny = 0.5, 0.5
local prev_plot_nx, prev_plot_ny = nil, nil
local prev_closest_i = nil
local beat_last_time = 0
local cont_index = 0

local function loop()
  local mx, my = slog(gfx.mouse_x), slog(gfx.mouse_y)  -- convert to logical pixels
  local cap = gfx.mouse_cap
  local left_down_now = (cap & 1) == 1
  local left_down_prev = (prev_mouse_cap & 1) == 1
  local left_click = left_down_now and not left_down_prev
  local left_release = (not left_down_now) and left_down_prev

  if app_mode == "picking_corpus" then
    if left_click then
      for _, b in ipairs(buttons) do
        if point_in(mx, my, b.x, b.y, b.w, b.h) then
          if b.action == "pick_corpus_item" then
            if load_corpus(b.corpus_path) then app_mode = "browsing" end
          elseif b.action == "pick_browse" then
            local ok, picked = reaper.GetUserFileNameForRead(CORPUS_DIR, "Select corpus CSV", "csv")
            if ok and load_corpus(picked) then app_mode = "browsing" end
          end
          break
        end
      end
    end
    prev_mouse_cap = cap
    draw_corpus_picker()
    gfx.update()
    local char = gfx.getchar()
    if char >= 0 and char ~= 27 then
      reaper.defer(loop)
    else
      gfx.quit()
    end
    return
  end

  if left_click then
    for _, s in ipairs(sliders) do
      if s._x and point_in(mx, my, s._x, s._y, s._w, s._h) then dragging_slider = s; break end
    end
  end
  if dragging_slider then
    if left_down_now then
      local t = clamp((mx - dragging_slider._x) / dragging_slider._w, 0, 1)
      S[dragging_slider.key] = dragging_slider.min + t * (dragging_slider.max - dragging_slider.min)
    end
    if left_release then dragging_slider = nil end
  end

  local clicked_button = false
  if left_click and not dragging_slider then
    for _, b in ipairs(buttons) do
      if point_in(mx, my, b.x, b.y, b.w, b.h) then
        clicked_button = true
        if b.action == "switch_corpus" then
          refresh_corpus_pick_items()
          app_mode = "picking_corpus"
        elseif b.action == "x_axis" then
          S.x_idx = (S.x_idx % #CANDIDATE_DESCRIPTORS) + 1; rebuild_pool(); last_triggered_idx = nil
        elseif b.action == "y_axis" then
          S.y_idx = (S.y_idx % #CANDIDATE_DESCRIPTORS) + 1; rebuild_pool(); last_triggered_idx = nil
        elseif b.action == "cluster" then
          S.cluster_idx = (S.cluster_idx % #CLUSTER_OPTIONS) + 1; rebuild_pool(); last_triggered_idx = nil
        elseif b.action == "rec" then
          if S.rec_on then
            move_cursor_to_recording_end()
          else
            rec_start_time = reaper.time_precise()
            rec_start_pos = reaper.GetCursorPosition()
            last_written_item, last_written_pos, last_written_len, last_written_fadeout = nil, nil, nil, nil
          end
          S.rec_on = not S.rec_on
        elseif b.action == "toggle_overlap" then
          S.allow_overlap = not S.allow_overlap
        elseif b.action:sub(1, 5) == "mode_" then
          S.mode = b.action:sub(6)
        end
        break
      end
    end
  end

  local in_plot = mx >= MARGIN_L and mx <= MARGIN_L + PLOT_W and my >= MARGIN_T and my <= MARGIN_T + PLOT_H
  local nx, ny
  if in_plot then
    nx = (mx - MARGIN_L) / PLOT_W
    ny = 1 - ((my - MARGIN_T) / PLOT_H)
    last_mouse_nx, last_mouse_ny = nx, ny
  else
    nx, ny = last_mouse_nx, last_mouse_ny
  end

  if preview_stop_time ~= nil and reaper.time_precise() >= preview_stop_time then
    stop_preview()
  end
  local preview_active = current_preview ~= nil

  if left_click and not clicked_button and in_plot and #pool > 0 and can_trigger_now() then
    local cand = pick_near(nx, ny)
    if cand then fire_trigger(cand) end
  end

  if #pool > 0 then
    if S.mode == "bow" and in_plot then
      local moved = (prev_plot_nx == nil) or (nx ~= prev_plot_nx) or (ny ~= prev_plot_ny)
      if moved and can_trigger_now() then
        local cand = pick_near(nx, ny)
        if cand then fire_trigger(cand) end
      end
    elseif S.mode == "fence" and in_plot then
      local nearest = strict_nearest(nx, ny)
      if nearest and nearest.i ~= prev_closest_i then
        prev_closest_i = nearest.i
        if can_trigger_now() then
          local cand = pick_near(nx, ny)
          if cand then fire_trigger(cand) end
        end
      end
    elseif S.mode == "chain" then
      if not preview_active and can_trigger_now() then
        local cand = pick_near(nx, ny)
        if cand then fire_trigger(cand) end
      end
    elseif S.mode == "beat" then
      local now = reaper.time_precise()
      local rate_sec = 60.0 / math.max(S.beat_rate_bpm, 1)
      if now - beat_last_time >= rate_sec and can_trigger_now() then
        beat_last_time = now
        local cand = pick_near(nx, ny)
        if cand then fire_trigger(cand) end
      end
    elseif S.mode == "cont" then
      if not preview_active and can_trigger_now() then
        cont_index = (cont_index % #pool) + 1
        fire_trigger(pool[cont_index])
      end
    end
  end

  if in_plot then prev_plot_nx, prev_plot_ny = nx, ny end
  prev_mouse_cap = cap

  draw()
  gfx.update()

  local char = gfx.getchar()
  if char >= 0 and char ~= 27 then
    reaper.defer(loop)
  else
    stop_preview()
    if S.rec_on then move_cursor_to_recording_end() end
    gfx.quit()
  end
end

reaper.defer(loop)
