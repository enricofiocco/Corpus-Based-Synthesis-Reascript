--[[
Match_target.lua

Resynthesize the selected item(s) with a corpus: the target is cut into
segments, each segment is measured with the corpus descriptors, and the
closest corpus fragment is placed at the same moment on a new track.

Typical use: glue a sequence of candidates (or any sound), select it, pick
ANOTHER corpus, click RESYNTHESIZE -> the same gesture, rebuilt from other
material.

 * Target = every selected audio item (glued or not), with its position,
   take offset and play rate taken into account.
 * Segmentation:
     onset -- split at detected onsets (finds the joins of a glued sequence)
     fixed -- fixed-length grains (Grain ms)
     items -- each selected item is one unit (no glue needed)
 * Matching: the K closest fragments are kept per segment; PLACE picks the
   closest or a random one among them (no immediate repeat optional).
   Duration and pitch can be left out of the distance.
 * Placement: on the selected track (default; a new track under the target if
   no track is selected, or always a new track), at the segment's position.
   Length = target segment (trimmed or extended into the source) or the whole
   corpus fragment. Optional: match level and/or pitch to each segment.
 * Analysis is cached: change only placement options (or re-roll random
   picks) and click PLACE AGAIN -- no re-analysis.

Needs: match_target.py + analyze_corpus.py next to this script, Python with
librosa / pandas / numpy (same as Create_corpus), and a *_clustered.csv +
*_scaler.json corpus (made by Create_corpus) in corpus_data/.
Analysis runs in the background on macOS / Linux (blocking on Windows).
--]]

local IS_WIN = package.config:sub(1, 1) == "\\"

-- ---------------------------------------------------------------------
-- Helpers
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
      elseif c == "," then fields[#fields + 1] = field; field = ""
      else field = field .. c end
    end
    i = i + 1
  end
  fields[#fields + 1] = field
  return fields
end

local function read_csv(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local header, rows = nil, {}
  for line in f:lines() do
    line = line:gsub("\r$", "")
    if line ~= "" then
      local fields = parse_csv_line(line)
      if not header then header = fields
      else
        local row = {}
        for idx, key in ipairs(header) do row[key] = fields[idx] end
        rows[#rows + 1] = row
      end
    end
  end
  f:close()
  return rows
end

local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi else return v end end

local function file_exists(path)
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return "" end
  local c = f:read("*a"); f:close()
  return c
end

local function short_name(path) return (path or ""):match("([^/\\]+)$") or (path or "") end

local function script_dir()
  local info = debug.getinfo(1, "S")
  local path = info.source:sub(2)
  return path:match("(.*[/\\])") or "./"
end
local SCRIPT_DIR = script_dir()
local CORPUS_DIR = SCRIPT_DIR .. "corpus_data/"

local function list_files(dir_path)
  local files = {}
  local cmd = IS_WIN and ('dir /b "' .. dir_path:gsub("/", "\\") .. '" 2>nul')
                      or ('ls "' .. dir_path .. '" 2>/dev/null')
  local p = io.popen(cmd)
  if p then
    for line in p:lines() do files[#files + 1] = line:gsub("\r$", "") end
    p:close()
  end
  table.sort(files)
  return files
end

-- X_clustered.csv -> X_scaler.json
local function scaler_for(csv)
  local base = csv:gsub("_clustered%.csv$", "")
  if base ~= csv and file_exists(base .. "_scaler.json") then return base .. "_scaler.json" end
  local dir = csv:match("(.*[/\\])") or ""
  if file_exists(dir .. "corpus_scaler.json") then return dir .. "corpus_scaler.json" end
  return nil
end

local EXT = "Match_target"
local function get_ext(key, default)
  local v = reaper.GetExtState(EXT, key)
  if v == nil or v == "" then return default end
  return v
end

-- ---------------------------------------------------------------------
-- Background job (POSIX: non-blocking; Windows: blocking fallback)
-- ---------------------------------------------------------------------
local job = nil
local tmp_counter = 0
local TMP_DIR = IS_WIN and ((os.getenv("TEMP") or ".") .. "\\") or "/tmp/"

local function tmp_path(suffix)
  tmp_counter = tmp_counter + 1
  return string.format("%sreascript_match_target_%d_%d%s", TMP_DIR,
    math.floor(reaper.time_precise() * 1000), tmp_counter, suffix)
end

local function start_job(cmd, on_complete)
  local log_path, status_path, done_path = tmp_path(".log"), tmp_path(".status"), tmp_path(".done")
  if IS_WIN then
    local ok = os.execute('"' .. cmd .. ' > "' .. log_path .. '" 2>&1"')
    local log = read_file(log_path); os.remove(log_path)
    on_complete(ok == true or ok == 0, log)
    return
  end
  os.execute(string.format('( %s > "%s" 2>&1 ; echo $? > "%s" ; touch "%s" ) &',
    cmd, log_path, status_path, done_path))
  job = { log_path = log_path, status_path = status_path, done_path = done_path,
          on_complete = on_complete, start_time = reaper.time_precise() }
end

local function poll_job()
  if not job then return end
  if file_exists(job.done_path) then
    local log = read_file(job.log_path)
    local code = tonumber(read_file(job.status_path)) or 1
    os.remove(job.log_path); os.remove(job.status_path); os.remove(job.done_path)
    local cb = job.on_complete
    job = nil
    cb(code == 0, log)
  end
end

local function job_progress()
  if not job then return "" end
  local log = read_file(job.log_path)
  local last = ""
  for l in log:gmatch("[^\r\n]+") do if not l:match("Warning") then last = l end end
  return last
end

-- ---------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------
local MODES = { "onset", "fixed", "items" }
local MODE_INFO = {
  onset = "Split at detected onsets: finds the joins of a glued sequence, or the attacks of any sound.",
  fixed = "Fixed-length grains (Grain): a regular grid, good for textures.",
  items = "Each selected item is one unit: select the candidates themselves, no glue needed.",
}
local LEN_MODES = {
  "Length: target segment (trim, gaps stay)",
  "Length: target segment (extend into source)",
  "Length: whole corpus fragment",
}

local S = {
  corpus = get_ext("corpus", ""),
  mode = get_ext("mode", "onset"),
  grain_ms = tonumber(get_ext("grain_ms", "250")) or 250,
  min_len_ms = tonumber(get_ext("min_len_ms", "60")) or 60,
  k = tonumber(get_ext("k", "5")) or 5,
  random_pick = get_ext("random_pick", "0") == "1",
  no_repeat = get_ext("no_repeat", "1") == "1",
  ignore_dur = get_ext("ignore_dur", "0") == "1",
  ignore_pitch = get_ext("ignore_pitch", "0") == "1",
  len_mode = tonumber(get_ext("len_mode", "1")) or 1,
  match_level = get_ext("match_level", "1") == "1",
  match_pitch = get_ext("match_pitch", "0") == "1",
  fade_ms = tonumber(get_ext("fade_ms", "10")) or 10,
  new_track = get_ext("new_track", "0") == "1",   -- false = selected track (default)
  python = get_ext("python", (function()
    local v = reaper.GetExtState("Find_similar", "python")
    return (v ~= "") and v or (IS_WIN and "python" or "/opt/homebrew/bin/python3")
  end)()),
}
if S.corpus ~= "" and not file_exists(S.corpus) then S.corpus = "" end

local function save_settings()
  for _, k in ipairs({ "corpus", "mode", "grain_ms", "min_len_ms", "k", "len_mode", "fade_ms", "python" }) do
    reaper.SetExtState(EXT, k, tostring(S[k]), true)
  end
  for _, k in ipairs({ "random_pick", "no_repeat", "ignore_dur", "ignore_pitch", "match_level", "match_pitch", "new_track" }) do
    reaper.SetExtState(EXT, k, S[k] and "1" or "0", true)
  end
end

local status, status_err = "", false
local function set_status(msg, is_err) status, status_err = msg, is_err or false end

local cache = nil       -- { key, segs, jobs, corpus }

-- ---------------------------------------------------------------------
-- Target: the selected audio items
-- ---------------------------------------------------------------------
local function get_targets()
  local list = {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take = reaper.GetActiveTake(item)
    if take and not reaper.TakeIsMIDI(take) then
      local src = reaper.GetMediaItemTake_Source(take)
      local path = src and reaper.GetMediaSourceFileName(src, "") or ""
      if path ~= "" then
        local rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
        if rate <= 0 then rate = 1 end
        local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        list[#list + 1] = {
          item = item, track = reaper.GetMediaItem_Track(item), path = path,
          pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION"), len = len,
          offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"), rate = rate,
        }
      end
    end
  end
  table.sort(list, function(a, b) return a.pos < b.pos end)
  return list
end

local function analysis_key(targets)
  local t = { S.corpus, S.mode, S.mode == "fixed" and S.grain_ms or "", S.mode == "onset" and S.min_len_ms or "",
              math.floor(S.k + 0.5), S.ignore_dur and "d" or "", S.ignore_pitch and "p" or "" }
  for _, g in ipairs(targets) do
    t[#t + 1] = string.format("%s@%.4f:%.4f:%.4f:%.4f", g.path, g.pos, g.offs, g.len, g.rate)
  end
  return table.concat(t, "|")
end

-- ---------------------------------------------------------------------
-- Placement
-- ---------------------------------------------------------------------
local function frag_key(m) return m.file .. "@" .. m.s end

local function place(c)
  if not c or #c.segs == 0 then set_status("Nothing to place.", true); return end
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local cname = short_name(c.corpus):gsub("_clustered%.csv$", ""):gsub("%.csv$", "")
  -- the selected track (default), else a new track just under the last target track
  local track = (not S.new_track) and reaper.GetSelectedTrack(0, 0) or nil
  local track_label
  if track then
    local _, tn = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    track_label = (tn ~= "" and tn) or ("track " .. math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")))
  else
    local last_tr = 0
    for _, g in ipairs(c.jobs) do
      if reaper.ValidatePtr(g.track, "MediaTrack*") then
        last_tr = math.max(last_tr, reaper.GetMediaTrackInfo_Value(g.track, "IP_TRACKNUMBER"))
      end
    end
    if last_tr <= 0 then last_tr = reaper.CountTracks(0) end
    reaper.InsertTrackAtIndex(math.floor(last_tr), true)
    track = reaper.GetTrack(0, math.floor(last_tr))
    track_label = "Resynth: " .. cname .. " (" .. c.mode .. ")"
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", track_label, true)
  end

  local prev, placed, skipped = nil, 0, 0
  local end_max = 0
  for _, seg in ipairs(c.segs) do
    local list = seg.matches
    local idx = 1
    if S.random_pick and #list > 1 then idx = math.random(#list) end
    if S.no_repeat and prev and #list > 1 and frag_key(list[idx]) == prev then idx = (idx % #list) + 1 end
    local m = list[idx]
    local g = c.jobs[seg.job]
    local source = m and reaper.PCM_Source_CreateFromFile(m.file)
    if not source or not g then
      skipped = skipped + 1
    else
      local pos = g.pos + seg.t_start / g.rate
      local tlen = seg.t_dur / g.rate
      local mdur = m.e - m.s
      local len
      if S.len_mode == 1 then len = math.min(tlen, mdur)
      elseif S.len_mode == 2 then len = tlen
      else len = mdur end
      local slen = reaper.GetMediaSourceLength(source)
      if slen and slen > 0 then len = math.min(len, math.max(slen - m.s, 0.01)) end
      len = math.max(len, 0.005)

      local item = reaper.AddMediaItemToTrack(track)
      local take = reaper.AddTakeToMediaItem(item)
      reaper.SetMediaItemTake_Source(take, source)
      reaper.SetMediaItemInfo_Value(item, "D_POSITION", pos)
      reaper.SetMediaItemInfo_Value(item, "D_LENGTH", len)
      reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", m.s)
      local fade = math.min(S.fade_ms / 1000, len / 2)
      reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", fade)
      reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", fade)
      if S.match_level and seg.t_rms > 0 and m.rms > 0 then
        reaper.SetMediaItemTakeInfo_Value(take, "D_VOL", clamp(seg.t_rms / m.rms, 0.063, 15.8))
      end
      if S.match_pitch and seg.t_pitch > 0 and m.pitch > 0 then
        reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", 1)
        reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", clamp(12 * math.log(seg.t_pitch / m.pitch, 2), -24, 24))
      end
      reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", short_name(m.file), true)
      prev = frag_key(m)
      placed = placed + 1
      if pos + len > end_max then end_max = pos + len end
    end
  end

  reaper.Main_OnCommand(40047, 0)   -- build missing peaks
  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Match target: resynthesize with " .. cname, -1)
  set_status(string.format("Placed %d fragment%s on '%s'%s.", placed, placed == 1 and "" or "s", track_label,
    skipped > 0 and string.format(" (%d skipped: source file not found)", skipped) or ""), skipped > 0)
end

-- ---------------------------------------------------------------------
-- Analysis
-- ---------------------------------------------------------------------
local function parse_matches(path, jobs)
  local rows = read_csv(path)
  if not rows or #rows == 0 then return nil end
  local by_key, segs = {}, {}
  for _, r in ipairs(rows) do
    local j = (tonumber(r.job_index) or 0) + 1
    local ti = tonumber(r.target_index) or 0
    local key = j .. ":" .. ti
    local seg = by_key[key]
    if not seg then
      seg = { job = j, ti = ti, t_start = tonumber(r.target_start_sec) or 0, t_dur = tonumber(r.target_duration) or 0,
              t_rms = tonumber(r.target_rms_mean) or 0, t_pitch = tonumber(r.target_pitch_hz) or 0, matches = {} }
      by_key[key] = seg
      segs[#segs + 1] = seg
    end
    local s_, e_ = tonumber(r.match_start_sec), tonumber(r.match_end_sec)
    if r.match_file_path and s_ and e_ and e_ > s_ then
      seg.matches[#seg.matches + 1] = { rank = tonumber(r.rank) or 0, file = r.match_file_path, s = s_, e = e_,
        rms = tonumber(r.match_rms_mean) or 0, pitch = tonumber(r.match_pitch_hz) or 0,
        dist = tonumber(r.distance) or 0 }
    end
  end
  local out = {}
  for _, seg in ipairs(segs) do
    if #seg.matches > 0 and jobs[seg.job] then
      table.sort(seg.matches, function(a, b) return a.rank < b.rank end)
      out[#out + 1] = seg
    end
  end
  table.sort(out, function(a, b) if a.job ~= b.job then return a.job < b.job end return a.ti < b.ti end)
  return out
end

local function q(s) return '"' .. s .. '"' end

local function analyze_and_place(targets, key)
  local script = SCRIPT_DIR .. "match_target.py"
  if not file_exists(script) then set_status("match_target.py not found next to this script.", true); return end
  if not file_exists(SCRIPT_DIR .. "analyze_corpus.py") then
    set_status("analyze_corpus.py not found next to this script.", true); return
  end
  local scaler = scaler_for(S.corpus)
  if not scaler then
    set_status("No scaler JSON found for this corpus (expected " .. short_name(S.corpus:gsub("_clustered%.csv$", "")) ..
      "_scaler.json next to it). Re-run Create_corpus on it.", true)
    return
  end

  local jobs_path, out_path = tmp_path(".tsv"), tmp_path(".csv")
  local f = io.open(jobs_path, "w")
  if not f then set_status("Cannot write a temporary file in " .. TMP_DIR, true); return end
  local jobs = {}
  for i, g in ipairs(targets) do
    f:write(string.format("%s\t%.6f\t%.6f\n", g.path, g.offs, g.len * g.rate))
    jobs[i] = { pos = g.pos, rate = g.rate, track = g.track }
  end
  f:close()

  local ignore = {}
  if S.ignore_dur then ignore[#ignore + 1] = "duration" end
  if S.ignore_pitch then ignore[#ignore + 1] = "pitch_hz"; ignore[#ignore + 1] = "pitch_confidence" end
  local cmd = string.format('%s %s - %s %s --jobs %s --mode %s --grain-ms %.0f --min-len-ms %.0f --k %d%s --out %s',
    q(S.python), q(script), q(S.corpus), q(scaler), q(jobs_path), S.mode, S.grain_ms, S.min_len_ms,
    math.floor(S.k + 0.5), (#ignore > 0) and (" --ignore " .. table.concat(ignore, ",")) or "", q(out_path))

  set_status("Analyzing the target...")
  local corpus, mode = S.corpus, S.mode
  start_job(cmd, function(ok, log)
    os.remove(jobs_path)
    local segs = ok and parse_matches(out_path, jobs) or nil
    os.remove(out_path)
    if not segs or #segs == 0 then
      local tail = (log or ""):gsub("%s+$", ""):sub(-300)
      set_status("Analysis failed. Check the Python path (librosa, pandas installed?). " .. tail, true)
      return
    end
    cache = { key = key, segs = segs, jobs = jobs, corpus = corpus, mode = mode }
    place(cache)
  end)
end

local function resynthesize(force)
  if job then return end
  local targets = get_targets()
  if #targets == 0 then set_status("Select one or more audio items first.", true); return end
  if S.corpus == "" or not file_exists(S.corpus) then set_status("Choose a corpus first.", true); return end
  save_settings()
  local key = analysis_key(targets)
  if not force and cache and cache.key == key then
    place(cache)
  else
    analyze_and_place(targets, key)
  end
end

-- ---------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------
local BASE_W, BASE_H = 640, 752
gfx.ext_retina = 1
gfx.init("Match target", 100, 100, 0)
local SCALE = (gfx.ext_retina and gfx.ext_retina > 0) and gfx.ext_retina or 1
gfx.quit()
gfx.ext_retina = 1
gfx.init("Match target", BASE_W, BASE_H, 0)
gfx.setfont(1, "sans-serif", math.floor(15 * SCALE))

local function sx(v) return v * SCALE end
local function slog(v) return v / SCALE end
local function gset_xy(x, y) gfx.x, gfx.y = sx(x), sx(y) end
local function grect(x, y, w, h, fill) gfx.rect(sx(x), sx(y), sx(w), sx(h), fill) end
local function gmeasure(text) return slog((gfx.measurestr(text))) end
local TEXT_H = slog(gfx.texth)

local buttons, sliders = {}, {}
local dragging = nil

local function draw_button(x, y, w, h, label, active)
  if active then gfx.set(0.3, 0.7, 1.0, 1) else gfx.set(0.28, 0.28, 0.28, 1) end
  grect(x, y, w, h, 1)
  gfx.set(1, 1, 1, 1)
  gset_xy(x + 6, y + (h - TEXT_H) / 2)
  gfx.drawstr(label)
  local b = { x = x, y = y, w = w, h = h }
  buttons[#buttons + 1] = b
  return b
end

local function draw_slider(key, label, fmt, vmin, vmax, x, y, w)
  local val = S[key]
  gfx.set(1, 1, 1, 1); gset_xy(x, y)
  gfx.drawstr(string.format("%s: " .. fmt, label, val))
  local ty = y + 16
  gfx.set(0.22, 0.22, 0.22, 1); grect(x, ty, w, 12, 1)
  gfx.set(0.3, 0.7, 1.0, 1); grect(x, ty, w * clamp((val - vmin) / (vmax - vmin), 0, 1), 12, 1)
  sliders[#sliders + 1] = { key = key, min = vmin, max = vmax, x = x, y = ty, w = w, h = 12,
                            int = (fmt:find("%.0f") ~= nil or fmt:find("%d") ~= nil) }
end

local function wrap_text(text, maxw)
  local lines, line = {}, ""
  for word in text:gmatch("%S+") do
    local test = (line == "" and word or (line .. " " .. word))
    if gmeasure(test) > maxw and line ~= "" then lines[#lines + 1] = line; line = word
    else line = test end
  end
  if line ~= "" then lines[#lines + 1] = line end
  return lines
end

local function draw_wrapped(text, x, y, maxw, r, g, b, max_lines)
  gfx.set(r or 0.75, g or 0.75, b or 0.75, 1)
  for i, l in ipairs(wrap_text(text, maxw)) do
    if max_lines and i > max_lines then break end
    gset_xy(x, y); gfx.drawstr(l); y = y + 16
  end
  return y
end

local function section(title, x, y)
  gfx.set(1, 1, 1, 1); gset_xy(x, y); gfx.drawstr(title)
  gfx.set(0.4, 0.4, 0.4, 1); grect(x, y + TEXT_H + 2, BASE_W - 2 * x, 1, 1)
  return y + TEXT_H + 10
end

local function corpus_menu(px, py)
  local items, paths = {}, {}
  for _, f in ipairs(list_files(CORPUS_DIR)) do
    if f:match("_clustered%.csv$") then
      items[#items + 1] = ((CORPUS_DIR .. f) == S.corpus and "!" or "") .. f:gsub("|", "/")
      paths[#paths + 1] = CORPUS_DIR .. f
    end
  end
  if #items == 0 then items[#items + 1] = "#No *_clustered.csv in corpus_data/" end
  items[#items + 1] = "Browse for a different file..."
  gfx.x, gfx.y = px, py
  local c = gfx.showmenu(table.concat(items, "|"))
  if c <= 0 then return end
  if paths[c] then S.corpus = paths[c]
  elseif c == #items then
    local ok, picked = reaper.GetUserFileNameForRead(CORPUS_DIR, "Select a clustered corpus CSV", "csv")
    if ok then S.corpus = picked end
  end
  save_settings()
end

local function draw()
  buttons, sliders = {}, {}
  gfx.clear = 3355443
  local x, w = 20, BASE_W - 40
  local hw = (w - 8) / 2
  local y = 16

  -- target
  y = section("Target (selected items)", x, y)
  local targets = get_targets()
  if #targets == 0 then
    y = draw_wrapped("Select one or more audio items in the arrange view (e.g. a glued sequence of candidates).",
      x, y, w, 1.0, 0.55, 0.45)
  else
    local total = 0
    for _, g in ipairs(targets) do total = total + g.len end
    local names = {}
    for i = 1, math.min(#targets, 3) do names[i] = short_name(targets[i].path) end
    y = draw_wrapped(string.format("%d item%s, %.2f s:  %s%s", #targets, #targets == 1 and "" or "s", total,
      table.concat(names, ", "), #targets > 3 and ", ..." or ""), x, y, w, 0.85, 0.95, 0.85, 2)
  end
  y = y + 8

  -- corpus
  y = section("Corpus to rebuild it with", x, y)
  local cl = (S.corpus ~= "") and short_name(S.corpus) or "(click to choose)"
  draw_button(x, y, w, 26, "Corpus: " .. cl, false).action = "corpus"
  y = y + 26 + 14

  -- segmentation
  y = section("Segmentation", x, y)
  local mw = (w - 16) / 3
  for i, m in ipairs(MODES) do
    draw_button(x + (i - 1) * (mw + 8), y, mw, 26, m, S.mode == m).action = "mode_" .. m
  end
  y = y + 32
  y = draw_wrapped(MODE_INFO[S.mode], x, y, w, 0.7, 0.7, 0.7, 2) + 4
  if S.mode == "fixed" then draw_slider("grain_ms", "Grain", "%.0f ms", 20, 2000, x, y, w)
  elseif S.mode == "onset" then draw_slider("min_len_ms", "Minimum segment", "%.0f ms", 10, 1000, x, y, w)
  else gfx.set(0.55, 0.55, 0.55, 1); gset_xy(x, y); gfx.drawstr("(no setting)") end
  y = y + 40

  -- matching
  y = section("Matching", x, y)
  draw_slider("k", "Matches kept per segment", "%.0f", 1, 20, x, y, w)
  y = y + 38
  draw_button(x, y, hw, 24, S.random_pick and "Pick: random among them" or "Pick: closest", S.random_pick).action = "pick"
  draw_button(x + hw + 8, y, hw, 24, S.no_repeat and "No immediate repeat: ON" or "No immediate repeat: OFF",
    S.no_repeat).action = "norepeat"
  y = y + 28
  draw_button(x, y, hw, 24, S.ignore_dur and "Ignore duration: ON" or "Ignore duration: OFF", S.ignore_dur).action = "igdur"
  draw_button(x + hw + 8, y, hw, 24, S.ignore_pitch and "Ignore pitch: ON" or "Ignore pitch: OFF", S.ignore_pitch).action = "igpitch"
  y = y + 36

  -- placement
  y = section("Placement", x, y)
  local seltr = reaper.GetSelectedTrack(0, 0)
  local tlabel
  if S.new_track then tlabel = "Output: new track under the target"
  elseif seltr then
    local _, tn = reaper.GetSetMediaTrackInfo_String(seltr, "P_NAME", "", false)
    tlabel = "Output: selected track (" .. ((tn ~= "" and tn) or ("track " ..
      math.floor(reaper.GetMediaTrackInfo_Value(seltr, "IP_TRACKNUMBER")))) .. ")"
  else tlabel = "Output: selected track (none selected: new track)" end
  draw_button(x, y, w, 24, tlabel, false).action = "output"
  y = y + 28
  draw_button(x, y, w, 24, LEN_MODES[S.len_mode], false).action = "lenmode"
  y = y + 28
  draw_button(x, y, hw, 24, S.match_level and "Match level: ON" or "Match level: OFF", S.match_level).action = "level"
  draw_button(x + hw + 8, y, hw, 24, S.match_pitch and "Match pitch: ON" or "Match pitch: OFF", S.match_pitch).action = "pitch"
  y = y + 30
  draw_slider("fade_ms", "Fades", "%.0f ms", 0, 100, x, y, w)
  y = y + 42

  -- action
  local cached = cache and #targets > 0 and cache.key == analysis_key(targets)
  local label
  if job then label = string.format("Analyzing...  %.0f s", reaper.time_precise() - job.start_time)
  elseif cached then label = S.random_pick and "PLACE AGAIN  (new random picks, Enter)" or "PLACE AGAIN  (no re-analysis, Enter)"
  else label = "RESYNTHESIZE  (Enter)" end
  draw_button(x, y, w - 128, 36, label, not job).action = "go"
  draw_button(x + w - 120, y, 120, 36, "Re-analyze", false).action = "reanalyze"
  y = y + 46

  if job then
    local p = job_progress()
    if p ~= "" then y = draw_wrapped(p, x, y, w, 0.7, 0.7, 0.7, 1) end
  end
  if status ~= "" then
    if status_err then draw_wrapped(status, x, y, w, 1.0, 0.5, 0.5, 4)
    else draw_wrapped(status, x, y, w, 0.8, 0.9, 0.8, 3) end
  end

  draw_button(x, BASE_H - 34, w, 22, "Python: " .. S.python, false).action = "python"
end

-- ---------------------------------------------------------------------
-- Main loop
-- ---------------------------------------------------------------------
local prev_cap = 0
local function point_in(mx, my, b) return mx >= b.x and mx <= b.x + b.w and my >= b.y and my <= b.y + b.h end

local function loop()
  local char = gfx.getchar()
  if char < 0 or char == 27 then save_settings(); gfx.quit(); return end
  poll_job()

  local mx, my = slog(gfx.mouse_x), slog(gfx.mouse_y)
  local cap = gfx.mouse_cap
  local down, was = (cap & 1) == 1, (prev_cap & 1) == 1
  local click, release = down and not was, was and not down

  if char == 13 then resynthesize(false) end

  if click then
    for _, s in ipairs(sliders) do
      if mx >= s.x and mx <= s.x + s.w and my >= s.y - 3 and my <= s.y + s.h + 3 then dragging = s; break end
    end
  end
  if dragging then
    if down then
      local v = dragging.min + clamp((mx - dragging.x) / dragging.w, 0, 1) * (dragging.max - dragging.min)
      if dragging.int then v = math.floor(v + 0.5) end
      S[dragging.key] = v
    end
    if release then dragging = nil; save_settings() end
  elseif click then
    for _, b in ipairs(buttons) do
      if point_in(mx, my, b) then
        local a = b.action
        if a == "corpus" then corpus_menu(sx(b.x), sx(b.y + b.h))
        elseif a:sub(1, 5) == "mode_" then S.mode = a:sub(6)
        elseif a == "pick" then S.random_pick = not S.random_pick
        elseif a == "norepeat" then S.no_repeat = not S.no_repeat
        elseif a == "igdur" then S.ignore_dur = not S.ignore_dur
        elseif a == "igpitch" then S.ignore_pitch = not S.ignore_pitch
        elseif a == "output" then S.new_track = not S.new_track
        elseif a == "lenmode" then S.len_mode = (S.len_mode % #LEN_MODES) + 1
        elseif a == "level" then S.match_level = not S.match_level
        elseif a == "pitch" then S.match_pitch = not S.match_pitch
        elseif a == "go" then resynthesize(false)
        elseif a == "reanalyze" then resynthesize(true)
        elseif a == "python" then
          local ok, res = reaper.GetUserInputs("Python executable", 1, "Full path,extrawidth=300", S.python)
          if ok and res ~= "" then S.python = res end
        end
        save_settings()
        break
      end
    end
  end

  prev_cap = cap
  draw()
  gfx.update()
  reaper.defer(loop)
end

math.randomseed(os.time())
reaper.defer(loop)
