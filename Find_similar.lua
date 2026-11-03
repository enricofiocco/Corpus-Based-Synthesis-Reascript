--[[
Find_similar.lua

Select ONE media item in REAPER, run this script: it measures the item with
the same descriptors as the corpus (via analyze_item.py), then searches a
corpus ("sound library" built with Create_corpus) for the fragments closest
to it.

 * Choose the criteria and their weight: centroid (brightness), spread
   (bandwidth), level (RMS), flatness, rolloff, zero-crossings, crest,
   duration, pitch, timbre (MFCC). Weight 0 = ignored.
 * RADIUS = how far from the reference a fragment may be to be a candidate.
   Larger radius = more candidates.
 * Click a candidate to prelisten it (SWS CF_Preview). Space = replay,
   Up/Down = move in the list, Enter or double-click = insert, A = re-analyze.
 * Insert next to the item, replace the item, or at the edit cursor.

Needs: SWS extension (prelisten), Python with librosa (analysis),
analyze_item.py + analyze_corpus.py in the same folder as this script,
and at least one corpus CSV in corpus_data/.
--]]

if not reaper.CF_CreatePreview then
  reaper.ShowMessageBox(
    "This script needs the SWS extension for audio prelisten (CF_Preview_* functions).\n\n" ..
    "Free -- install from https://www.sws-extension.org/ and restart REAPER.",
    "SWS extension required", 0)
  return
end

local IS_WIN = package.config:sub(1, 1) == "\\"

-- ---------------------------------------------------------------------
-- CSV
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
    line = line:gsub("\r$", "")
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
-- Helpers
-- ---------------------------------------------------------------------
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi else return v end end

local function script_dir()
  local info = debug.getinfo(1, "S")
  local path = info.source:sub(2)
  return path:match("(.*[/\\])") or "./"
end
local SCRIPT_DIR = script_dir()
local CORPUS_DIR = SCRIPT_DIR .. "corpus_data/"

local function list_csv_files(dir_path)
  local files = {}
  local cmd = IS_WIN and ('dir /b "' .. dir_path:gsub("/", "\\") .. '" 2>nul')
                      or ('ls "' .. dir_path .. '" 2>/dev/null')
  local p = io.popen(cmd)
  if p then
    for line in p:lines() do
      line = line:gsub("\r$", "")
      if line:match("%.csv$") then table.insert(files, line) end
    end
    p:close()
  end
  table.sort(files)
  return files
end

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

local EXT = "Find_similar"
local function get_ext(key, default)
  local v = reaper.GetExtState(EXT, key)
  if v == nil or v == "" then return default end
  return v
end

-- ---------------------------------------------------------------------
-- Background job (POSIX: truly non-blocking; Windows: blocking fallback)
-- ---------------------------------------------------------------------
local job = nil
local tmp_counter = 0
local TMP_DIR = IS_WIN and ((os.getenv("TEMP") or ".") .. "\\") or "/tmp/"

local function tmp_path(suffix)
  tmp_counter = tmp_counter + 1
  return string.format("%sreascript_find_similar_%d_%d%s", TMP_DIR,
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

-- ---------------------------------------------------------------------
-- Search criteria
-- ---------------------------------------------------------------------
-- kind: "log" (compared in log domain), "lin", "pitch" (semitones, unvoiced
-- handled specially), "mfcc" (13 coefficients, z-scored)
local CRITERIA = {
  { key = "spectral_centroid",  label = "Centroid (brightness)", kind = "log",  w = 1.0,
    info = "Brightness: centre of mass of the spectrum." },
  { key = "spectral_bandwidth", label = "Spread (bandwidth)",    kind = "log",  w = 1.0,
    info = "Spread of the spectrum around the centroid." },
  { key = "rms_mean",           label = "Level (RMS)",           kind = "log",  w = 1.0,
    info = "Average loudness." },
  { key = "spectral_flatness",  label = "Flatness (noisiness)",  kind = "log",  w = 0.0,
    info = "Tonal (low) vs noisy (high)." },
  { key = "spectral_rolloff",   label = "Rolloff",               kind = "log",  w = 0.0,
    info = "Frequency under which most energy lies." },
  { key = "zcr",                label = "Zero crossings",        kind = "log",  w = 0.0,
    info = "Zero-crossing rate: noisiness / high-frequency content." },
  { key = "crest_factor",       label = "Crest (spikiness)",     kind = "log",  w = 0.0,
    info = "Peak / RMS: percussive vs sustained." },
  { key = "duration",           label = "Duration",              kind = "log",  w = 0.0,
    info = "Length of the fragment." },
  { key = "pitch_hz",           label = "Pitch",                 kind = "pitch", w = 0.0,
    info = "Estimated pitch; unpitched sounds only match unpitched." },
  { key = "mfcc",               label = "Timbre (MFCC 1-13)",    kind = "mfcc", w = 0.0,
    info = "Overall timbral fingerprint." },
}
local MFCC_N = 13
local NO_SEARCH_KEYS = { gap = true, rand_len = true, rand_pan = true, rand_dist = true, pick_n = true, max_ins = true }
local RADIUS_MAX = 4.0     -- distance (in corpus std-devs) at radius = 100%
local LEN_SLIDER_MAX = 10.0 -- seconds, max of the length min/max sliders

-- ---------------------------------------------------------------------
-- Window (logical-pixel layout, auto display scale)
-- ---------------------------------------------------------------------
local BASE_W, BASE_H = 1120, 820
local COL_A_X, COL_A_W = 20, 450
local COL_B_X, COL_B_W = 490, 290
local COL_C_X, COL_C_W = 800, 300

gfx.ext_retina = 1
gfx.init("Find similar", 100, 100, 0)
local SCALE = (gfx.ext_retina and gfx.ext_retina > 0) and gfx.ext_retina or 1
gfx.quit()
gfx.ext_retina = 1
gfx.init("Find similar", BASE_W, BASE_H, 0)
gfx.setfont(1, "sans-serif", math.floor(15 * SCALE))

local function sx(v) return v * SCALE end
local function slog(v) return v / SCALE end
local function gset_xy(x, y) gfx.x, gfx.y = sx(x), sx(y) end
local function grect(x, y, w, h, fill) gfx.rect(sx(x), sx(y), sx(w), sx(h), fill) end
local function gcircle(x, y, r, fill, aa) gfx.circle(sx(x), sx(y), sx(r), fill, aa) end
local function gmeasure(text) return slog((gfx.measurestr(text))) end
local TEXT_H = slog(gfx.texth)

-- ---------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------
local S = {
  hover_prelisten = (reaper.GetExtState(EXT, "hover_prelisten") == "1"),
  radius = 0.25,            -- 0..1 (100% = RADIUS_MAX standard deviations)
  len_filter = false,       -- target length filter on/off
  len_min = 0.0,            -- seconds
  len_max = 2.0,            -- seconds
  exclude_self = true,
  auto_prelisten = true,
  match_level = false,
  match_ref_len = false,
  insert_mode = 1,
  multi_stacked = false,
  rand_len = 0.0,    -- 0..1  random length variation (+/- this fraction of the length)
  rand_pan = 0.0,    -- 0..1  random pan spread (0 = centre, 1 = full left/right)
  rand_dist = 0.0,   -- 0..1  0 = the N closest candidates, 1 = N random ones within the radius
  pick_n = 4,        -- number of candidates for "Insert random pick"
  gap = 0.0,
  python = get_ext("python", "/opt/homebrew/bin/python3"),
}
for _, c in ipairs(CRITERIA) do S["w_" .. c.key] = c.w end

S.max_ins = 0.0   -- max length of inserted items (s), 0 = off; applied before random length

local INSERT_MODES = {
  "Insert: 'Candidates' track @ item",
  "Insert: replace selected item",
  "Insert: 'Candidates' track @ edit cursor",
  "Insert: selected track @ edit cursor",
}

local status, status_err = "", false
local function set_status(msg, is_err) status, status_err = msg, is_err or false end

-- corpus
local rows_t, stats, current_csv_path = {}, {}, nil

-- reference
local ref_feat, ref_t = nil, nil
local ref_name, ref_item, ref_track, ref_pos, ref_len_item = "", nil, nil, 0, 0
local ref_path, ref_src_start, ref_src_len = nil, 0, 0
local analyzed_ptr = nil
local last_replace_items = {}

-- candidates
local cands = {}
local sel = nil           -- index into cands
local msel, anchor = {}, nil  -- marked candidates (multi-selection), keyed by row
local scroll = 0
local search_dirty = false

-- ---------------------------------------------------------------------
-- Corpus loading
-- ---------------------------------------------------------------------
local function transform_scalar(kind, v)
  if v == nil then return nil end
  if kind == "log" then return math.log(math.max(v, 1e-9)) end
  return v
end

local function transform_row(get)
  local t = {}
  for _, c in ipairs(CRITERIA) do
    if c.kind == "mfcc" then
      local arr, ok = {}, true
      for k = 1, MFCC_N do
        local v = get("mfcc" .. k)
        if v == nil then ok = false; break end
        arr[k] = v
      end
      t[c.key] = ok and arr or nil
    elseif c.kind == "pitch" then
      local v = get("pitch_hz")
      if v == nil then t[c.key] = nil
      elseif v > 0 then t[c.key] = 12 * math.log(v, 2)
      else t[c.key] = false end
    else
      t[c.key] = transform_scalar(c.kind, get(c.key))
    end
  end
  return t
end

local function std_of(list)
  local n = #list
  if n < 2 then return nil end
  local m = 0
  for _, v in ipairs(list) do m = m + v end
  m = m / n
  local s = 0
  for _, v in ipairs(list) do s = s + (v - m) ^ 2 end
  s = math.sqrt(s / n)
  if s < 1e-9 then return nil end
  return s
end

-- ---------------------------------------------------------------------
-- Subfolder filter: only fragments whose source file lies in one of the
-- checked subfolders (or below) can be candidates. Nothing checked = all.
-- Folders are relative to the common parent folder of all corpus files.
-- ---------------------------------------------------------------------
local folders = {}        -- sorted list of { key = "a/b", depth, name, n }
local folder_on = {}      -- key -> true when checked
local folder_allow = nil  -- rel dir -> true; nil = no filter
local folder_root = ""    -- name of the common parent folder

local function split_dir(p)
  local t = {}
  for c in p:gmatch("[^/\\]+") do t[#t + 1] = c end
  return t
end

local function dir_of(p) return p:match("^(.*)[/\\]") or "" end

local function folder_in(rel, key)
  if key == "" then return rel == "" end
  return rel == key or rel:sub(1, #key + 1) == key .. "/"
end

local function n_folders_on()
  local n = 0
  for _, f in ipairs(folders) do if folder_on[f.key] then n = n + 1 end end
  return n
end

local folder_rels = {}    -- set of distinct rel dirs in the corpus

local function update_folder_allow()
  if n_folders_on() == 0 then
    folder_allow = nil
  else
    folder_allow = {}
    for rel in pairs(folder_rels) do
      for key in pairs(folder_on) do
        if folder_in(rel, key) then folder_allow[rel] = true; break end
      end
    end
  end
  local keys = {}
  for k in pairs(folder_on) do keys[#keys + 1] = k end
  reaper.SetExtState(EXT, "folders_corpus", current_csv_path or "", true)
  reaper.SetExtState(EXT, "folders", table.concat(keys, "\t"), true)
end

local function build_folders()
  folders, folder_on, folder_allow, folder_rels = {}, {}, nil, {}
  local dirs, common = {}, nil
  for _, r in ipairs(rows_t) do
    local d = dir_of(r.file)
    if not dirs[d] then
      local comps = split_dir(d)
      dirs[d] = comps
      if not common then
        common = {}
        for k, c in ipairs(comps) do common[k] = c end
      else
        local k = 0
        while k < #common and k < #comps and common[k + 1] == comps[k + 1] do k = k + 1 end
        for j = #common, k + 1, -1 do common[j] = nil end
      end
    end
  end
  common = common or {}
  folder_root = common[#common] or ""

  local rel_of, rel_count = {}, {}
  for d, comps in pairs(dirs) do rel_of[d] = table.concat(comps, "/", #common + 1) end
  for _, r in ipairs(rows_t) do
    r.rel = rel_of[dir_of(r.file)]
    rel_count[r.rel] = (rel_count[r.rel] or 0) + 1
    folder_rels[r.rel] = true
  end

  -- every subfolder and its parents, with fragment counts
  local count = {}
  for rel, n in pairs(rel_count) do
    if rel == "" then
      count[""] = (count[""] or 0) + n
    else
      local parts = {}
      for _, c in ipairs(split_dir(rel)) do
        parts[#parts + 1] = c
        local k = table.concat(parts, "/")
        count[k] = (count[k] or 0) + n
      end
    end
  end
  local n_keys = 0
  for _ in pairs(count) do n_keys = n_keys + 1 end
  if n_keys <= 1 then return end      -- a single folder: nothing to filter

  for k, n in pairs(count) do
    local comps = split_dir(k)
    folders[#folders + 1] = { key = k, comps = comps, depth = math.max(#comps - 1, 0),
                              name = (k == "") and "(files directly in " .. folder_root .. ")" or comps[#comps],
                              n = n }
  end
  table.sort(folders, function(a, b)
    if a.key == "" then return b.key ~= "" end
    if b.key == "" then return false end
    for i = 1, math.min(#a.comps, #b.comps) do
      local x, y = a.comps[i]:lower(), b.comps[i]:lower()
      if x ~= y then return x < y end
    end
    return #a.comps < #b.comps
  end)

  -- restore the last selection if it was made on this corpus
  local saved = reaper.GetExtState(EXT, "folders")
  if saved ~= "" and reaper.GetExtState(EXT, "folders_corpus") == current_csv_path then
    for k in (saved .. "\t"):gmatch("(.-)\t") do
      if count[k] then folder_on[k] = true end
    end
  end
  update_folder_allow()
end

-- Corpus loading is incremental: the CSV is read and parsed in small time
-- slices spread over several UI frames (progress bar, window stays alive),
-- and only the columns actually needed are converted -- so big corpora open
-- much faster than a naive full parse.
local loader = nil   -- active load state, nil when idle

local NEEDED = { "file_path", "start_sec", "end_sec", "rms_mean", "spectral_centroid" }
NEEDED[#NEEDED + 1] = "cluster_id"
for _, c in ipairs(CRITERIA) do
  if c.kind == "mfcc" then
    for k = 1, MFCC_N do NEEDED[#NEEDED + 1] = "mfcc" .. k end
  else
    NEEDED[#NEEDED + 1] = c.key
  end
end

local function split_fast(line)
  local t, n = {}, 0
  for f in (line .. ","):gmatch("([^,]*),") do n = n + 1; t[n] = f end
  return t
end

local function compute_stats(out)
  local st = {}
  for _, c in ipairs(CRITERIA) do
    if c.kind == "mfcc" then
      local arr = {}
      for k = 1, MFCC_N do
        local vals = {}
        for _, r in ipairs(out) do if r.t.mfcc then vals[#vals + 1] = r.t.mfcc[k] end end
        arr[k] = std_of(vals)
      end
      st[c.key] = arr
    else
      local vals = {}
      for _, r in ipairs(out) do
        local v = r.t[c.key]
        if v ~= nil and v ~= false then vals[#vals + 1] = v end
      end
      st[c.key] = std_of(vals)
    end
  end
  return st
end

local app_mode = "picking_corpus"

local function load_corpus(path)
  local f = io.open(path, "rb")
  if not f then set_status("Could not open corpus: " .. path, true); return false end
  local text = f:read("*a"); f:close()
  local _, nl = text:gsub("\n", "")
  loader = {
    path = path, iter = text:gmatch("[^\n]+"), total = math.max(nl - 1, 1), n = 0,
    out = {}, idx = nil,
  }
  app_mode = "loading"
  return true
end

-- processes lines for ~25 ms; returns true when finished
local function load_step()
  local L = loader
  local deadline = reaper.time_precise() + 0.025
  local cur
  local function get(col)
    local i = L.idx[col]
    return i and tonumber(cur[i]) or nil
  end
  while true do
    local line = L.iter()
    if not line then
      -- finished
      if #L.out == 0 then
        set_status("No usable fragments (file_path/start_sec/end_sec) in: " .. L.path, true)
        loader = nil
        app_mode = "picking_corpus"
        return true
      end
      rows_t, stats, current_csv_path = L.out, compute_stats(L.out), L.path
      reaper.SetExtState(EXT, "corpus", L.path, true)
      build_folders()
      cands, sel, scroll = {}, nil, 0
      search_dirty = true
      loader = nil
      app_mode = "main"
      set_status("")
      return true
    end
    line = line:gsub("\r$", "")
    if not L.idx then
      local hdr = parse_csv_line(line)
      L.idx = {}
      for i, name in ipairs(hdr) do L.idx[name] = i end
      if not (L.idx.file_path and L.idx.start_sec and L.idx.end_sec) then
        set_status("This CSV has no file_path/start_sec/end_sec columns: " .. L.path, true)
        loader = nil
        app_mode = "picking_corpus"
        return true
      end
    else
      cur = line:find('"', 1, true) and parse_csv_line(line) or split_fast(line)
      local fp = cur[L.idx.file_path]
      local s_, e_ = get("start_sec"), get("end_sec")
      if fp and s_ and e_ and e_ > s_ then
        L.out[#L.out + 1] = { file = fp, s = s_, e = e_, t = transform_row(get),
                              rms = get("rms_mean") or 0, centroid = get("spectral_centroid") or 0,
                              cluster = get("cluster_id") }
      end
      L.n = L.n + 1
      if L.n % 64 == 0 and reaper.time_precise() > deadline then return false end
    end
  end
end

-- ---------------------------------------------------------------------
-- Search
-- ---------------------------------------------------------------------
local function criterion_diff(c, a, b)
  -- a: corpus value, b: reference value (both already transformed)
  if c.kind == "mfcc" then
    if not a or not b then return 0 end
    local acc, n = 0, 0
    for k = 1, MFCC_N do
      local s = stats.mfcc and stats.mfcc[k]
      if s then acc = acc + ((a[k] - b[k]) / s) ^ 2; n = n + 1 end
    end
    if n == 0 then return 0 end
    return math.sqrt(acc / n)
  end
  local s = stats[c.key]
  if not s or a == nil or b == nil then return 0 end
  if c.kind == "pitch" then
    if a == false and b == false then return 0 end
    if a == false or b == false then return 3 end
  end
  return (a - b) / s
end

local function is_self(r)
  return ref_path and r.file == ref_path and r.s < (ref_src_start + ref_src_len) and r.e > ref_src_start
end

local cands_version = 0
local function compute_candidates()
  cands_version = cands_version + 1
  search_dirty = false
  local prev = sel and cands[sel] or nil
  cands = {}
  sel = nil
  if not ref_t then return end

  local active, wsum = {}, 0
  for _, c in ipairs(CRITERIA) do
    local w = S["w_" .. c.key]
    local bv = ref_t[c.key]
    if w > 0.001 and bv ~= nil then
      active[#active + 1] = { c = c, w = w, b = bv }
      wsum = wsum + w
    end
  end
  if wsum == 0 then return end

  for _, r in ipairs(rows_t) do
    local dur = r.e - r.s
    local len_ok = (not S.len_filter) or (dur >= S.len_min and dur <= S.len_max)
    local folder_ok = (not folder_allow) or folder_allow[r.rel]
    if len_ok and folder_ok and not (S.exclude_self and is_self(r)) then
      local acc = 0
      for _, a in ipairs(active) do
        local d = criterion_diff(a.c, r.t[a.c.key], a.b)
        acc = acc + a.w * d * d
      end
      local dist = math.sqrt(acc / wsum)
      if dist <= S.radius * RADIUS_MAX then
        cands[#cands + 1] = { r = r, dist = dist }
      end
    end
  end
  table.sort(cands, function(x, y) return x.dist < y.dist end)

  if prev then
    for i, cd in ipairs(cands) do if cd.r == prev.r then sel = i; break end end
  end
  scroll = 0
  if sel then scroll = math.max(0, sel - 5) end
end

-- Menu of subfolders with check marks. It reopens after each click so
-- several folders can be toggled in a row; click outside it to close.
local function folder_menu(px, py)
  if #folders == 0 then return end
  while true do
    local items = {}
    local non = n_folders_on()
    local head = (non == 0) and "No filter: all folders" or string.format("%d folder%s checked", non, non == 1 and "" or "s")
    if ref_t then head = head .. string.format(" - %d candidates", #cands) end
    items[1] = "#" .. head
    items[2] = "Show all folders (clear checks)"
    items[3] = "Invert checks"
    for _, f in ipairs(folders) do
      local inherited = false
      if not folder_on[f.key] then
        for key in pairs(folder_on) do
          if key ~= "" and f.key ~= "" and folder_in(f.key, key) then inherited = true; break end
        end
      end
      local label = string.rep("      ", f.depth) .. f.name:gsub("|", "/") ..
                    string.format("  (%d)", f.n) .. (inherited and "  - in checked parent" or "")
      if label:match("^[!#<>]") then label = " " .. label end
      items[#items + 1] = (folder_on[f.key] and "!" or "") .. label
    end
    gfx.x, gfx.y = px, py
    local choice = gfx.showmenu(table.concat(items, "|"))
    if choice <= 1 then break end
    if choice == 2 then folder_on = {}
    elseif choice == 3 then
      local inv = {}
      for _, f in ipairs(folders) do if not folder_on[f.key] then inv[f.key] = true end end
      folder_on = inv
    else
      local f = folders[choice - 3]
      if f then folder_on[f.key] = (not folder_on[f.key]) or nil end
    end
    update_folder_allow()
    compute_candidates()
  end
end

-- ---------------------------------------------------------------------
-- Preview
-- ---------------------------------------------------------------------
local current_preview, preview_stop_time = nil, nil

local function stop_preview()
  if current_preview then
    reaper.CF_Preview_Stop(current_preview)
    current_preview, preview_stop_time = nil, nil
  end
end

local function play_source(path, start, len, gain)
  stop_preview()
  local source = reaper.PCM_Source_CreateFromFile(path)
  if not source then set_status("Cannot open source: " .. path, true); return end
  local pv = reaper.CF_CreatePreview(source)
  reaper.CF_Preview_SetValue(pv, "D_POSITION", start)
  reaper.CF_Preview_SetValue(pv, "D_VOLUME", gain or 1.0)
  reaper.CF_Preview_SetValue(pv, "D_LENGTH", len)
  reaper.CF_Preview_Play(pv)
  current_preview = pv
  preview_stop_time = reaper.time_precise() + len
end

-- start / length of a candidate according to the length settings
local function cand_span(r, factor)
  local len = r.e - r.s
  if S.match_ref_len and ref_src_len > 0 then len = ref_src_len end
  local capped = false
  if S.max_ins > 0 and len > S.max_ins then len = S.max_ins; capped = true end
  if factor then len = len * factor end
  local source = reaper.PCM_Source_CreateFromFile(r.file)
  if source then
    local slen = reaper.GetMediaSourceLength(source)
    if slen and slen > 0 then len = math.min(len, math.max(slen - r.s, 0.01)) end
  end
  return r.s, math.max(len, 0.01), capped
end

local function cand_gain(r)
  if S.match_level and ref_feat and ref_feat.rms_mean and r.rms > 0 then
    return clamp(ref_feat.rms_mean / r.rms, 0.063, 15.8)
  end
  return 1.0
end

local function prelisten_candidate(i)
  local cd = cands[i]
  if not cd then return end
  local s, len = cand_span(cd.r)
  play_source(cd.r.file, s, len, cand_gain(cd.r))
end

local function prelisten_reference()
  if ref_path then play_source(ref_path, ref_src_start, ref_src_len, 1.0) end
end

-- ---------------------------------------------------------------------
-- Insert
-- ---------------------------------------------------------------------
local function find_or_create_track(name)
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, n = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if n == name then return tr end
  end
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, true)
  local tr = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
  return tr
end

-- ---------------------------------------------------------------------
-- Random FX parameters: each inserted candidate gets a random value for
-- chosen parameters of FX already on the target track, written as a
-- square automation point at the item start (it holds until the next item).
-- Each parameter has its own range, typed in the plugin's own units
-- (degrees, Hz, dB...), converted to the plugin's internal 0..1 by
-- searching its display (so log-scaled parameters work too). Parameters
-- that show no number take the range as a percentage of their travel.
-- ---------------------------------------------------------------------
local RFX, rfx_save, rfx_menu, rfx_copy_chain, rfx_apply, rfx_report, rfx_summary
do
RFX = { on = false, list = {} }
-- list entry: { fx = FX name, fxi = index hint, p = param name, pi = index hint,
--               lo, hi = normalized 0..1, lo_s, hi_s = range as shown }

function rfx_save()
  local t = { RFX.on and "1" or "0" }
  for _, e in ipairs(RFX.list) do
    t[#t + 1] = table.concat({ e.fx, e.fxi, e.p, e.pi, e.lo, e.hi, e.lo_s, e.hi_s }, "\t")
  end
  reaper.SetExtState(EXT, "rfx2", table.concat(t, "\31"), true)
end

local function rfx_load()
  local v = reaper.GetExtState(EXT, "rfx2")
  if v == "" then return end
  local first = true
  for rec in (v .. "\31"):gmatch("(.-)\31") do
    if first then RFX.on = rec == "1"; first = false
    else
      local f = {}
      for x in (rec .. "\t"):gmatch("(.-)\t") do f[#f + 1] = x end
      if #f >= 8 then
        RFX.list[#RFX.list + 1] = { fx = f[1], fxi = tonumber(f[2]) or 0, p = f[3], pi = tonumber(f[4]) or 0,
          lo = tonumber(f[5]) or 0, hi = tonumber(f[6]) or 1, lo_s = f[7], hi_s = f[8] }
      end
    end
  end
end
rfx_load()

local function fx_name(tr, fx) local _, n = reaper.TrackFX_GetFXName(tr, fx, ""); return n or "" end
local function par_name(tr, fx, p) local _, n = reaper.TrackFX_GetParamName(tr, fx, p, ""); return n or "" end
local function par_fmt(tr, fx, p, v)
  local ok, s = reaper.TrackFX_FormatParamValueNormalized(tr, fx, p, v, "")
  if not ok or not s or s == "" then return nil end
  return s
end
local function num_of(s) return s and tonumber(s:match("%-?%d+%.?%d*")) end

-- shown value -> normalized, by bisection on the plugin's own display
local function disp_to_norm(tr, fx, p, target)
  local d0, d1 = num_of(par_fmt(tr, fx, p, 0)), num_of(par_fmt(tr, fx, p, 1))
  if not d0 or not d1 or d0 == d1 then return nil end
  local up = d1 > d0
  if (up and target <= d0) or (not up and target >= d0) then return 0 end
  if (up and target >= d1) or (not up and target <= d1) then return 1 end
  local lo, hi = 0, 1
  for _ = 1, 40 do
    local mid = (lo + hi) / 2
    local d = num_of(par_fmt(tr, fx, p, mid))
    if not d then return nil end
    if (d < target) == up then lo = mid else hi = mid end
  end
  local dl, dh = num_of(par_fmt(tr, fx, p, lo)), num_of(par_fmt(tr, fx, p, hi))
  if dl and dh and math.abs(dl - target) < math.abs(dh - target) then return lo end
  return hi
end

-- the track the next insert goes to (where the FX should be)
local function rfx_target_track()
  if S.insert_mode == 4 then return reaper.GetSelectedTrack(0, 0) end
  if S.insert_mode == 2 then
    local it = reaper.GetSelectedMediaItem(0, 0)
    if it then return reaper.GetMediaItem_Track(it) end
    return reaper.GetSelectedTrack(0, 0)
  end
  return find_or_create_track("Candidates")
end

local function rfx_find(e)
  for i, x in ipairs(RFX.list) do if x.fx == e.fx and x.p == e.p then return i end end
end

-- ask the range for an entry; returns false on cancel
local function rfx_range_dialog(tr, fx, e)
  local numeric = num_of(par_fmt(tr, fx, e.pi, 0)) and num_of(par_fmt(tr, fx, e.pi, 1))
  local unit = numeric and ((par_fmt(tr, fx, e.pi, 1) or ""):gsub("[%-%d%.%s]", "")) or "%"
  local cur_lo = numeric and num_of(par_fmt(tr, fx, e.pi, e.lo)) or e.lo * 100
  local cur_hi = numeric and num_of(par_fmt(tr, fx, e.pi, e.hi)) or e.hi * 100
  local d0 = numeric and par_fmt(tr, fx, e.pi, 0) or "0"
  local d1 = numeric and par_fmt(tr, fx, e.pi, 1) or "100"
  local u = unit ~= "" and (" (" .. unit .. ")") or ""
  local ok, csv = reaper.GetUserInputs(string.format("Random range: %s  [%s .. %s]", e.p, d0, d1), 2,
    "Min" .. u .. ",Max" .. u .. ",extrawidth=60", string.format("%g,%g", cur_lo, cur_hi))
  if not ok then return false end
  local a, b = csv:match("^%s*([^,]-)%s*,%s*([^,]-)%s*$")
  a, b = tonumber(a), tonumber(b)
  if not a or not b then return false end
  if numeric then
    e.lo = disp_to_norm(tr, fx, e.pi, a) or 0
    e.hi = disp_to_norm(tr, fx, e.pi, b) or 1
  else
    e.lo, e.hi = clamp(a / 100, 0, 1), clamp(b / 100, 0, 1)
  end
  e.lo_s = numeric and (par_fmt(tr, fx, e.pi, e.lo) or tostring(a)) or (string.format("%g%%", a))
  e.hi_s = numeric and (par_fmt(tr, fx, e.pi, e.hi) or tostring(b)) or (string.format("%g%%", b))
  return true
end

local function rfx_add(tr, fx, p)
  local e = { fx = fx_name(tr, fx), fxi = fx, p = par_name(tr, fx, p), pi = p, lo = 0, hi = 1 }
  if not rfx_range_dialog(tr, fx, e) then return end
  local i = rfx_find(e)
  if i then RFX.list[i] = e else RFX.list[#RFX.list + 1] = e end
  RFX.on = true
end

-- locate an entry's FX / param on a track: by name, then by index hint
local function rfx_locate(tr, e)
  local fx = -1
  local n = reaper.TrackFX_GetCount(tr)
  if e.fxi < n and fx_name(tr, e.fxi) == e.fx then fx = e.fxi
  else for i = 0, n - 1 do if fx_name(tr, i) == e.fx then fx = i; break end end end
  if fx < 0 then return nil end
  if par_name(tr, fx, e.pi) == e.p then return fx, e.pi end
  for p = 0, reaper.TrackFX_GetNumParams(tr, fx) - 1 do
    if par_name(tr, fx, p) == e.p then return fx, p end
  end
  return nil
end

local function menu_label(s)
  s = s:gsub("|", "/")
  if s:match("^[!#<>]") then s = " " .. s end
  return s
end

local MAX_MENU_PARAMS = 400

-- param list of one FX; reopens after each click so several can be set in a row
local function rfx_param_menu(tr, fx, px, py)
  while true do
    local np = reaper.TrackFX_GetNumParams(tr, fx)
    local items = { "#" .. menu_label(fx_name(tr, fx)) .. "  -  click a parameter to randomize it / remove it" }
    local shown = math.min(np, MAX_MENU_PARAMS)
    for p = 0, shown - 1 do
      local e = { fx = fx_name(tr, fx), p = par_name(tr, fx, p) }
      local i = rfx_find(e)
      local lab = menu_label(e.p)
      if i then lab = "!" .. lab .. string.format("   [%s .. %s]", RFX.list[i].lo_s, RFX.list[i].hi_s):gsub("|", "/") end
      items[#items + 1] = lab
    end
    if np > shown then items[#items + 1] = string.format("#... %d more: use 'Add last touched parameter'", np - shown) end
    gfx.x, gfx.y = px, py
    local c = gfx.showmenu(table.concat(items, "|"))
    if c <= 1 or c > shown + 1 then return end
    local p = c - 2
    local i = rfx_find({ fx = fx_name(tr, fx), p = par_name(tr, fx, p) })
    if i then
      local r = reaper.ShowMessageBox("Change the range of '" .. RFX.list[i].p .. "'?\n\nYes = new range, No = stop randomizing it",
        "Random FX", 3)
      if r == 6 then rfx_range_dialog(tr, fx, RFX.list[i])
      elseif r == 7 then table.remove(RFX.list, i) end
    else
      rfx_add(tr, fx, p)
    end
    rfx_save()
  end
end

function rfx_menu(px, py)
  local tr = rfx_target_track()
  if not tr then set_status("Random FX: no target track (select a track, or an item in replace mode).", true); return end
  while true do
    local _, tname = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    local n = reaper.TrackFX_GetCount(tr)
    local items = { "#Target track: " .. menu_label(tname ~= "" and tname or "(unnamed)") }
    if n == 0 then items[#items + 1] = "#No FX on this track: add the FX there first" end
    for fx = 0, n - 1 do
      local k = 0
      for _, e in ipairs(RFX.list) do if e.fx == fx_name(tr, fx) then k = k + 1 end end
      items[#items + 1] = menu_label(fx_name(tr, fx)) .. (k > 0 and string.format("   (%d randomized)", k) or "") .. "  >"
    end
    local base = #items
    items[#items + 1] = "Add last touched parameter"
    items[#items + 1] = (#RFX.list > 0 and "" or "#") .. "Remove all random parameters"
    gfx.x, gfx.y = px, py
    local c = gfx.showmenu(table.concat(items, "|"))
    if c <= 0 then return end
    if c == base + 1 then
      local ok, tnum, fx, p = reaper.GetLastTouchedFX()
      local ltr = ok and ((tnum == 0) and reaper.GetMasterTrack(0) or reaper.GetTrack(0, (tnum & 0xFFFF) - 1))
      if not ok or (tnum >> 16) ~= 0 or fx >= 0x1000000 then
        set_status("Random FX: touch a parameter of a track FX first.", true)
      elseif ltr ~= tr then
        set_status("Random FX: the last touched parameter is not on the target track.", true)
      else
        rfx_add(tr, fx, p); rfx_save()
      end
    elseif c == base + 2 then
      RFX.list = {}; rfx_save()
    elseif c > base - n and c <= base then
      rfx_param_menu(tr, c - (base - n) - 1, px, py)
    end
  end
end

-- stacked layout: new tracks get a copy of the main track's FX chain
function rfx_copy_chain(src, dst)
  if not RFX.on or #RFX.list == 0 then return end
  reaper.SetMediaTrackInfo_Value(dst, "I_NCHAN", reaper.GetMediaTrackInfo_Value(src, "I_NCHAN"))
  for i = 0, reaper.TrackFX_GetCount(src) - 1 do reaper.TrackFX_CopyToTrack(src, i, dst, i, false) end
end

local rfx_missing = {}

-- called from place_item() for every inserted candidate
function rfx_apply(item, take)
  if not RFX.on or #RFX.list == 0 then return end
  local tr = reaper.GetMediaItem_Track(item)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  for _, e in ipairs(RFX.list) do
    local fx, p = rfx_locate(tr, e)
    local env = fx and reaper.GetFXEnvelope(tr, fx, p, true)
    if env then
      local _, mn, mx = reaper.TrackFX_GetParam(tr, fx, p)
      local nv = e.lo + math.random() * (e.hi - e.lo)
      reaper.DeleteEnvelopePointRange(env, pos - 1e-6, pos + len - 1e-6)
      reaper.InsertEnvelopePoint(env, pos, mn + nv * (mx - mn), 1, 0, false, true)   -- shape 1 = square
      reaper.Envelope_SortPoints(env)
    else
      rfx_missing[e.fx .. ": " .. e.p] = true
    end
  end
end

function rfx_report()
  local t = {}
  for k in pairs(rfx_missing) do t[#t + 1] = k end
  rfx_missing = {}
  if #t > 0 then set_status("Random FX: not found on the track: " .. table.concat(t, ", "), true) end
end

function rfx_summary()
  local t = {}
  for _, e in ipairs(RFX.list) do t[#t + 1] = e.p end
  return #t == 0 and "no parameter chosen" or table.concat(t, ", ")
end
end   -- random FX

local function valid_item(it) return it and reaper.ValidatePtr(it, "MediaItem*") end

local function place_item(track, pos, r, src_start, len, source, capped)
  local item = reaper.AddMediaItemToTrack(track)
  local take = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(take, source)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", pos)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", len)
  reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", src_start)
  local fade = math.min(0.005, len / 2)   -- tiny anti-click fades
  reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", fade)
  -- an item cut short by the max length gets a real fade-out (no click on the cut)
  reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", capped and math.min(0.03, len / 3) or fade)
  reaper.SetMediaItemInfo_Value(item, "C_FADEINSHAPE", 0)
  reaper.SetMediaItemInfo_Value(item, "C_FADEOUTSHAPE", 0)
  reaper.SetMediaItemTakeInfo_Value(take, "D_VOL", cand_gain(r))
  if S.rand_pan > 0 then
    reaper.SetMediaItemTakeInfo_Value(take, "D_PAN", clamp((math.random() * 2 - 1) * S.rand_pan, -1, 1))
  end
  reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", short_name(r.file), true)
  rfx_apply(item, take)
  reaper.UpdateItemInProject(item)
  return item
end

-- Inserts one or several candidate rows. Sequential layout = end to end
-- (plus gap) on the same track; stacked = same start, one new track each
-- ("Candidates 2", "Candidates 3"...). Replace mode always lays out
-- sequentially from the position of the replaced item(s).
local function insert_items(rows)
  if #rows == 0 then return end
  if #rows > 50 then
    local ok = reaper.ShowMessageBox(string.format("Insert %d items into the project?", #rows), "Find similar", 1)
    if ok ~= 1 then return end
  end

  reaper.Undo_BeginBlock()
  local track, pos
  if S.insert_mode == 2 then
    local occupants = {}
    for _, it in ipairs(last_replace_items) do if valid_item(it) then occupants[#occupants + 1] = it end end
    if #occupants == 0 and valid_item(ref_item) then occupants[1] = ref_item end
    if #occupants > 0 then
      pos = math.huge
      for _, it in ipairs(occupants) do
        local ip = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
        if ip < pos then pos = ip; track = reaper.GetMediaItem_Track(it) end
      end
      for _, it in ipairs(occupants) do reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(it), it) end
    else
      track = (ref_track and reaper.ValidatePtr(ref_track, "MediaTrack*")) and ref_track or nil
      pos = ref_pos
    end
    if not track then
      reaper.Undo_EndBlock("Find similar: insert", -1)
      set_status("Nothing to replace: select an item and analyze it first.", true)
      return
    end
    last_replace_items = {}
  elseif S.insert_mode == 4 then
    track = reaper.GetSelectedTrack(0, 0)
    if not track then
      reaper.Undo_EndBlock("Find similar: insert", -1)
      set_status("No track selected: select a track in the arrange view first.", true)
      return
    end
    pos = reaper.GetCursorPosition()
  elseif S.insert_mode == 1 then
    track = find_or_create_track("Candidates")
    pos = ref_item and ref_pos or reaper.GetCursorPosition()
  else
    track = find_or_create_track("Candidates")
    pos = reaper.GetCursorPosition()
  end

  local stacked = S.multi_stacked and S.insert_mode ~= 2
  local cur, end_max, done = pos, pos, 0
  for k, r in ipairs(rows) do
    local source = reaper.PCM_Source_CreateFromFile(r.file)
    if source then
      local factor = (S.rand_len > 0) and (1 + (math.random() * 2 - 1) * S.rand_len) or nil
      local src_start, len, capped = cand_span(r, factor)
      local tr, ipos = track, cur
      if stacked then
        ipos = pos
        if k > 1 then
          local idx = reaper.CountTracks(0)
          reaper.InsertTrackAtIndex(idx, true)
          tr = reaper.GetTrack(0, idx)
          reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "Candidates " .. k, true)
          rfx_copy_chain(track, tr)
        end
      end
      local item = place_item(tr, ipos, r, src_start, len, source, capped)
      if S.insert_mode == 2 then last_replace_items[#last_replace_items + 1] = item end
      if not stacked then cur = ipos + len + S.gap end
      if ipos + len > end_max then end_max = ipos + len end
      done = done + 1
    end
  end

  -- cursor just after the last inserted item (plus the gap when laid out one after another)
  reaper.SetEditCurPos(end_max + ((not stacked) and S.gap or 0), true, false)
  reaper.Main_OnCommand(40047, 0)              -- Peaks: build any missing peaks (waveforms)
  reaper.UpdateArrange()
  reaper.TrackList_AdjustWindows(false)        -- show new automation lanes
  reaper.Undo_EndBlock("Find similar: insert candidate(s)", -1)
  if done == 1 then
    set_status("Inserted: " .. short_name(rows[1].file))
  else
    set_status(string.format("Inserted %d items.", done))
  end
  rfx_report()
end

-- Random pick: N candidates out of the current list. rand_dist = 0 takes the
-- N closest; 1 samples N at random from the whole radius; in between, the
-- sample is drawn from the closest N + rand_dist * (rest) candidates.
local function random_pick_and_insert()
  if #cands == 0 then set_status("No candidates to pick from.", true); return end
  local n = math.min(math.floor(S.pick_n + 0.5), #cands)
  local pool_size = n + math.floor(S.rand_dist * (#cands - n) + 0.5)
  local pool = {}
  for i = 1, pool_size do pool[i] = i end
  for i = 1, n do                       -- partial Fisher-Yates shuffle
    local j = math.random(i, pool_size)
    pool[i], pool[j] = pool[j], pool[i]
  end
  local picked = {}
  for i = 1, n do picked[i] = pool[i] end
  table.sort(picked)                    -- keep distance order
  msel = {}
  local rows = {}
  for _, idx in ipairs(picked) do rows[#rows + 1] = cands[idx].r; msel[cands[idx].r] = true end
  insert_items(rows)
end

-- the N closest candidates, in distance order
local function insert_closest()
  if #cands == 0 then set_status("No candidates to insert.", true); return end
  local n = math.min(math.floor(S.pick_n + 0.5), #cands)
  msel = {}
  local rows = {}
  for i = 1, n do rows[i] = cands[i].r; msel[cands[i].r] = true end
  insert_items(rows)
end

-- marked candidates in list order (falls back to the single selected one)
local function marked_rows()
  local rows = {}
  for _, cd in ipairs(cands) do if msel[cd.r] then rows[#rows + 1] = cd.r end end
  if #rows == 0 and sel and cands[sel] then rows[1] = cands[sel].r end
  return rows
end

-- ---------------------------------------------------------------------
-- Analysis of the selected item
-- ---------------------------------------------------------------------
local function parse_features(path)
  local feats = {}
  local f = io.open(path, "r")
  if not f then return nil end
  for line in f:lines() do
    local k, v = line:match("^(%S+)%s+(%S+)")
    if k and tonumber(v) then feats[k] = tonumber(v) end
  end
  f:close()
  return feats
end

local function selected_item()
  if reaper.CountSelectedMediaItems(0) == 1 then return reaper.GetSelectedMediaItem(0, 0) end
  return nil
end

local analyzing = false

local function analyze_selected()
  if analyzing then return end
  local item = selected_item()
  if not item then
    set_status("Select exactly ONE media item, then click Analyze.", true)
    return
  end
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then
    set_status("The selected item has no audio take.", true)
    return
  end
  local source = reaper.GetMediaItemTake_Source(take)
  local path = source and reaper.GetMediaSourceFileName(source, "") or ""
  if path == "" then
    set_status("Cannot find the source file of this item.", true)
    return
  end
  local rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  if rate <= 0 then rate = 1 end
  local start = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local ilen = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local src_len = ilen * rate

  local out_path = tmp_path(".txt")
  local script = SCRIPT_DIR .. "analyze_item.py"
  if not file_exists(script) then
    set_status("analyze_item.py not found next to this script.", true)
    return
  end
  local cmd = string.format('"%s" "%s" "%s" --start %.6f --length %.6f --out "%s"',
    S.python, script, path, start, src_len, out_path)

  analyzing = true
  set_status("Analyzing selected item...")
  local _, nm = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
  local item_name = (nm and nm ~= "") and nm or short_name(path)

  start_job(cmd, function(ok, log)
    analyzing = false
    if ok then
      local feats = parse_features(out_path)
      os.remove(out_path)
      if feats and feats.rms_mean then
        ref_feat = feats
        ref_t = transform_row(function(col) return feats[col] end)
        ref_name, ref_item = item_name, item
        ref_track = reaper.GetMediaItem_Track(item)
        ref_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        ref_len_item = ilen
        ref_path, ref_src_start, ref_src_len = path, start, src_len
        analyzed_ptr = item
        last_replace_items = {}
        search_dirty = true
        set_status("")
        return
      end
    end
    os.remove(out_path)
    local tail = (log or ""):gsub("%s+$", "")
    tail = tail:sub(-260)
    set_status("Analysis failed. Check the Python path and that librosa is installed. " .. tail, true)
  end)
end

-- ---------------------------------------------------------------------
-- Widgets
-- ---------------------------------------------------------------------
local buttons, row_hits = {}, {}
local dragging_slider = nil
local sliders = {}

local function draw_button(x, y, w, h, label, active)
  if active then gfx.set(0.3, 0.7, 1.0, 1) else gfx.set(0.28, 0.28, 0.28, 1) end
  grect(x, y, w, h, 1)
  gfx.set(1, 1, 1, 1)
  gset_xy(x + 6, y + (h - TEXT_H) / 2)
  gfx.drawstr(label)
  local b = { x = x, y = y, w = w, h = h, label = label }
  buttons[#buttons + 1] = b
  return b
end

local function point_in(mx, my, x, y, w, h)
  return mx >= x and mx <= x + w and my >= y and my <= y + h
end

local function draw_slider(key, label, fmt, vmin, vmax, x, y, w)
  local val = S[key]
  local t = (val - vmin) / (vmax - vmin)
  gfx.set(1, 1, 1, 1)
  gset_xy(x, y)
  -- fmt "pct" = show a 0..1 value as 0-100%
  local txt
  if fmt == "pct" then txt = string.format("%s: %.0f%%", label, val * 100)
  elseif fmt == "off_s" then txt = (val <= 0) and (label .. ": off") or string.format("%s: %.2f s", label, val)
  else txt = string.format("%s: " .. fmt, label, val) end
  gfx.drawstr(txt)
  local ty = y + 16
  gfx.set(0.22, 0.22, 0.22, 1); grect(x, ty, w, 12, 1)
  gfx.set(0.3, 0.7, 1.0, 1); grect(x, ty, w * clamp(t, 0, 1), 12, 1)
  sliders[#sliders + 1] = { key = key, min = vmin, max = vmax, x = x, y = ty, w = w, h = 12 }
end

local function wrap_text(text, maxw)
  local lines, line = {}, ""
  for word in text:gmatch("%S+") do
    local test = (line == "" and word or (line .. " " .. word))
    if gmeasure(test) > maxw and line ~= "" then
      lines[#lines + 1] = line; line = word
    else
      line = test
    end
  end
  if line ~= "" then lines[#lines + 1] = line end
  return lines
end

local function draw_wrapped(text, x, y, maxw, r, g, b, max_lines)
  gfx.set(r or 0.75, g or 0.75, b or 0.75, 1)
  local n = 0
  for _, l in ipairs(wrap_text(text, maxw)) do
    n = n + 1
    if max_lines and n > max_lines then break end
    gset_xy(x, y)
    gfx.drawstr(l)
    y = y + 15
  end
  return y
end

local function fit_text(text, maxw)
  if gmeasure(text) <= maxw then return text end
  while #text > 1 and gmeasure(text .. "...") > maxw do text = text:sub(1, -2) end
  return text .. "..."
end

-- ---------------------------------------------------------------------
-- Corpus picker (in-window)
-- ---------------------------------------------------------------------
local corpus_pick_items = {}

local function refresh_corpus_pick_items()
  corpus_pick_items = {}
  for _, f in ipairs(list_csv_files(CORPUS_DIR)) do
    corpus_pick_items[#corpus_pick_items + 1] = { label = f, path = CORPUS_DIR .. f }
  end
end

local function draw_corpus_picker()
  buttons = {}
  gfx.clear = 3355443
  local x, y = 40, 20
  gfx.set(1, 1, 1, 1)
  gset_xy(x, y); gfx.drawstr("Select the corpus (sound library) to search in")
  y = y + 34
  local list_w = 460
  if #corpus_pick_items == 0 then
    gfx.set(0.75, 0.75, 0.75, 1)
    gset_xy(x, y); gfx.drawstr("No CSV files found in corpus_data/.")
    y = y + 30
  else
    for _, item in ipairs(corpus_pick_items) do
      local b = draw_button(x, y, list_w, 28, item.label, false)
      b.action = "pick_corpus_item"; b.corpus_path = item.path
      y = y + 34
    end
  end
  y = y + 10
  draw_button(x, y, list_w, 30, "Browse for a different file...", false).action = "pick_browse"
  if status ~= "" then
    draw_wrapped(status, x, y + 44, 700, 1.0, 0.5, 0.5)
  end
end

local function draw_loading()
  buttons = {}
  gfx.clear = 3355443
  local x, y, w = 40, 40, 520
  gfx.set(1, 1, 1, 1); gset_xy(x, y)
  gfx.drawstr("Loading corpus: " .. short_name(loader and loader.path or ""))
  y = y + 30
  local frac = loader and clamp(loader.n / loader.total, 0, 1) or 1
  gfx.set(0.22, 0.22, 0.22, 1); grect(x, y, w, 22, 1)
  gfx.set(0.3, 0.7, 1.0, 1); grect(x, y, w * frac, 22, 1)
  y = y + 32
  gfx.set(0.75, 0.75, 0.75, 1); gset_xy(x, y)
  gfx.drawstr(string.format("%d%%  (%d fragments)", math.floor(frac * 100), loader and #loader.out or 0))
  if analyzing then
    gset_xy(x, y + 22); gfx.drawstr("Analyzing the selected item in parallel...")
  end
end

-- ---------------------------------------------------------------------
-- Main drawing
-- ---------------------------------------------------------------------
local ROW_H = 22
local LIST_TOP = 150
local LIST_BOTTOM = BASE_H - 30
local VISIBLE_ROWS = math.floor((LIST_BOTTOM - LIST_TOP) / ROW_H)

-- ---------------------------------------------------------------------
-- Map view: candidates as nodes on a 2D plane. X / Y / node size / node
-- colour are each one descriptor of your choice (size & colour can be off).
-- ---------------------------------------------------------------------
local MAP_MAX = 6000          -- nodes drawn at most; beyond that they are thinned evenly

-- appends about `budget` evenly spaced entries of src to out (all when fewer)
local function stride_pick(src, budget, out)
  local n = #src
  if budget <= 0 then return end
  if n <= budget then for i = 1, n do out[#out + 1] = src[i] end return end
  local step, acc = n / budget, 0
  for i = 1, n do
    acc = acc + 1
    if acc >= step then acc = acc - step; out[#out + 1] = src[i] end
  end
end
local MAP_DESCS = {}

local function add_desc(name, label, get, kind)
  MAP_DESCS[#MAP_DESCS + 1] = { name = name, label = label, get = get, kind = kind }
end
add_desc("distance", "Distance to target", function(cd) return cd.dist end, "lin")
for _, c in ipairs(CRITERIA) do
  if c.kind == "mfcc" then
    for k = 1, MFCC_N do
      add_desc("mfcc" .. k, "MFCC " .. k, function(cd) local m = cd.r.t.mfcc; return m and m[k] end, "lin")
    end
  elseif c.kind == "pitch" then
    add_desc(c.key, c.label, function(cd) local v = cd.r.t.pitch_hz; if v == false then return nil end return v end, "semi")
  else
    add_desc(c.key, c.label, function(cd) return cd.r.t[c.key] end, c.kind)
  end
end
add_desc("cluster_id", "Cluster", function(cd) return cd.r.cluster end, "lin")

local function find_desc(name)
  for i, d in ipairs(MAP_DESCS) do if d.name == name then return i end end
  return 1
end
S.map_view = false
S.map_x = find_desc("spectral_centroid")
S.map_y = find_desc("rms_mean")
S.map_size = find_desc("duration")     -- 0 = none
S.map_color = 1                        -- distance; 0 = none

local function fmt_desc(d, v)
  if v == nil then return "-" end
  if d.kind == "log" then return string.format("%.3g", math.exp(v)) end
  if d.kind == "semi" then return string.format("%.0f Hz", 2 ^ (v / 12)) end
  return string.format("%.3g", v)
end

local MAP_X, MAP_Y, MAP_W = COL_A_X, LIST_TOP, COL_A_W
local MAP_H = (LIST_BOTTOM - LIST_TOP) - 62
local MAP_PAD = 16
local map_cache = { key = nil, nodes = {}, order = {} }

-- Zoom / pan of the map. Positions are kept normalised (0..1 on each axis);
-- VIEW says which part is visible: centre (cx, cy) and zoom factor z.
local VIEW = { z = 1, cx = 0.5, cy = 0.5 }
local ZOOM_MAX = 64
local function view_x(u) return MAP_X + MAP_PAD + ((u - VIEW.cx) * VIEW.z + 0.5) * (MAP_W - 2 * MAP_PAD) end
local function view_y(u) return MAP_Y + MAP_H - MAP_PAD - ((u - VIEW.cy) * VIEW.z + 0.5) * (MAP_H - 2 * MAP_PAD) end
local function unview_x(x) return ((x - MAP_X - MAP_PAD) / (MAP_W - 2 * MAP_PAD) - 0.5) / VIEW.z + VIEW.cx end
local function unview_y(y) return ((MAP_Y + MAP_H - MAP_PAD - y) / (MAP_H - 2 * MAP_PAD) - 0.5) / VIEW.z + VIEW.cy end
local function clamp_view()
  local h = 0.5 / VIEW.z
  VIEW.cx = clamp(VIEW.cx, math.min(h, 0.5), math.max(1 - h, 0.5))
  VIEW.cy = clamp(VIEW.cy, math.min(h, 0.5), math.max(1 - h, 0.5))
end
-- zoom by `factor`, keeping the point under (mx, my) where it is
local function zoom_at(mx, my, factor)
  local ux, uy = unview_x(mx), unview_y(my)
  VIEW.z = clamp(VIEW.z * factor, 1, ZOOM_MAX)
  VIEW.cx = ux - ((mx - MAP_X - MAP_PAD) / (MAP_W - 2 * MAP_PAD) - 0.5) / VIEW.z
  VIEW.cy = uy - ((MAP_Y + MAP_H - MAP_PAD - my) / (MAP_H - 2 * MAP_PAD) - 0.5) / VIEW.z
  clamp_view()
end
local function reset_view() VIEW.z, VIEW.cx, VIEW.cy = 1, 0.5, 0.5 end
local function view_visible(x, y) return x >= MAP_X and x <= MAP_X + MAP_W and y >= MAP_Y and y <= MAP_Y + MAP_H end
local ZOOM_BTN = { w = 74, h = 20 }
local map_hover = nil

local function col_ramp(t)
  local function lerp(a, b, u) return a + (b - a) * u end
  local r, g, b
  if t < 0.5 then
    local u = t * 2
    r, g, b = lerp(0.25, 0.2, u), lerp(0.4, 0.85, u), lerp(1.0, 0.55, u)
  else
    local u = (t - 0.5) * 2
    r, g, b = lerp(0.2, 1.0, u), lerp(0.85, 0.85, u), lerp(0.55, 0.2, u)
  end
  return r, g, b
end

local function norm_list(vals, n)
  local lo, hi = math.huge, -math.huge
  for i = 1, n do
    local v = vals[i]
    if v ~= nil then
      if v < lo then lo = v end
      if v > hi then hi = v end
    end
  end
  if lo == math.huge then lo, hi = 0, 1 end
  if hi == lo then hi = lo + 1 end
  local out = {}
  for i = 1, n do
    local v = vals[i]
    out[i] = (v ~= nil) and (v - lo) / (hi - lo) or 0
  end
  return out, lo, hi
end

local function build_map()
  local key = table.concat({ cands_version, S.map_x, S.map_y, S.map_size, S.map_color, VIEW.z, VIEW.cx, VIEW.cy }, ":")
  if map_cache.key == key then return map_cache end
  local all = {}
  for i = 1, #cands do all[i] = i end
  local ids = {}
  stride_pick(all, MAP_MAX, ids)
  if #ids < #cands then
    local inlist = {}
    for _, i in ipairs(ids) do inlist[i] = true end
    for i, cd in ipairs(cands) do
      if (i == sel or msel[cd.r]) and not inlist[i] then ids[#ids + 1] = i end
    end
  end
  local n = #ids
  local dx, dy = MAP_DESCS[S.map_x], MAP_DESCS[S.map_y]
  local ds = S.map_size > 0 and MAP_DESCS[S.map_size] or nil
  local dc = S.map_color > 0 and MAP_DESCS[S.map_color] or nil
  local vx, vy, vs, vc = {}, {}, {}, {}
  for i = 1, n do
    local cd = cands[ids[i]]
    vx[i], vy[i] = dx.get(cd), dy.get(cd)
    if ds then vs[i] = ds.get(cd) end
    if dc then vc[i] = dc.get(cd) end
  end
  local nx, xlo, xhi = norm_list(vx, n)
  local ny, ylo, yhi = norm_list(vy, n)
  local ns = ds and norm_list(vs, n) or nil
  local nc = dc and norm_list(vc, n) or nil
  local nodes, order = {}, {}
  for i = 1, n do
    local px, py = view_x(nx[i]), view_y(ny[i])
    local node = view_visible(px, py) and {
      idx = ids[i],
      x = px,
      y = py,
      r = ns and (3 + ns[i] * 11) or 5,
      t = nc and nc[i] or nil,
    }
    if node then
      nodes[#nodes + 1] = node
      order[#order + 1] = node
    end
  end
  table.sort(order, function(a, b) return a.r > b.r end)   -- big nodes first, small ones stay visible
  map_cache = { key = key, nodes = nodes, order = order, n = n, thinned = n < #cands,
                xlo = xlo, xhi = xhi, ylo = ylo, yhi = yhi, dx = dx, dy = dy }
  return map_cache
end

local function update_map_hover(mx, my)
  map_hover = nil
  if not S.map_view then return end
  local c = build_map()
  if not point_in(mx, my, MAP_X, MAP_Y, MAP_W, MAP_H) then return end
  local best, best_d = nil, math.huge
  for _, node in ipairs(c.nodes) do
    local ddx, ddy = node.x - mx, node.y - my
    local d = ddx * ddx + ddy * ddy
    local reach = node.r + 4
    if d <= reach * reach and d < best_d then best, best_d = node, d end
  end
  map_hover = best and best.idx or nil
end

local function draw_map()
  local c = build_map()
  gfx.set(0.22, 0.22, 0.22, 1); grect(MAP_X, MAP_Y, MAP_W, MAP_H, 1)
  gfx.set(0.5, 0.5, 0.5, 1); grect(MAP_X, MAP_Y, MAP_W, MAP_H, 0)

  for _, node in ipairs(c.order) do
    if node.t then gfx.set(col_ramp(node.t)) else gfx.set(0.3, 0.7, 1.0) end
    gfx.a = 0.75
    gcircle(node.x, node.y, node.r, 1, 1)
  end
  for _, node in ipairs(c.nodes) do
    local cd = cands[node.idx]
    if node.idx == sel then
      gfx.set(1.0, 0.85, 0.1, 1)
      gcircle(node.x, node.y, node.r + 3, 0, 1); gcircle(node.x, node.y, node.r + 4, 0, 1)
    elseif cd and msel[cd.r] then
      gfx.set(1, 1, 1, 1)
      gcircle(node.x, node.y, node.r + 2, 0, 1)
    end
  end
  if map_hover then
    for _, node in ipairs(c.nodes) do
      if node.idx == map_hover then
        gfx.set(1, 1, 1, 0.9); gcircle(node.x, node.y, node.r + 2, 0, 1)
        break
      end
    end
  end

  -- zoom indicator / reset
  if VIEW.z > 1.001 then
    local bx = MAP_X + MAP_W - ZOOM_BTN.w - 4
    gfx.set(0.15, 0.15, 0.15, 0.85); grect(bx, MAP_Y + 4, ZOOM_BTN.w, ZOOM_BTN.h, 1)
    gfx.set(0.9, 0.9, 0.9, 1)
    gset_xy(bx + 6, MAP_Y + 4 + (ZOOM_BTN.h - TEXT_H) / 2)
    gfx.drawstr(string.format("x%.1f  1:1", VIEW.z))
  end

  -- axis ranges
  gfx.set(0.7, 0.7, 0.7, 1)
  local function vx_at(u) return c.xlo + u * (c.xhi - c.xlo) end
  local function vy_at(u) return c.ylo + u * (c.yhi - c.ylo) end
  gset_xy(MAP_X + 4, MAP_Y + MAP_H + 2); gfx.drawstr(fmt_desc(c.dx, vx_at(unview_x(MAP_X + MAP_PAD))))
  local xs = fmt_desc(c.dx, vx_at(unview_x(MAP_X + MAP_W - MAP_PAD)))
  gset_xy(MAP_X + MAP_W - gmeasure(xs) - 4, MAP_Y + MAP_H + 2); gfx.drawstr(xs)
  gset_xy(MAP_X + 4, MAP_Y + 3); gfx.drawstr(fmt_desc(c.dy, vy_at(unview_y(MAP_Y + MAP_PAD))))
  gset_xy(MAP_X + 4, MAP_Y + MAP_H - TEXT_H - 3); gfx.drawstr(fmt_desc(c.dy, vy_at(unview_y(MAP_Y + MAP_H - MAP_PAD))))

  -- selectors (click = next descriptor, Shift-click = previous, right-click = list)
  local by = MAP_Y + MAP_H + 22
  local bw = (MAP_W - 6) / 2
  local function dname(i) return i > 0 and MAP_DESCS[i].label or "(none)" end
  draw_button(MAP_X, by, bw, 26, "X: " .. dname(S.map_x), false).action = "map_x"
  draw_button(MAP_X + bw + 6, by, bw, 26, "Y: " .. dname(S.map_y), false).action = "map_y"
  draw_button(MAP_X, by + 30, bw, 26, "Size: " .. dname(S.map_size), S.map_size > 0).action = "map_size"
  draw_button(MAP_X + bw + 6, by + 30, bw, 26, "Color: " .. dname(S.map_color), S.map_color > 0).action = "map_color"

  -- info line
  gfx.set(0.75, 0.75, 0.75, 1)
  gset_xy(MAP_X, LIST_BOTTOM + 4)
  if map_hover and cands[map_hover] then
    local cd = cands[map_hover]
    gfx.drawstr(fit_text(string.format("%s  d=%.2f  %.2fs", short_name(cd.r.file), cd.dist, cd.r.e - cd.r.s), MAP_W))
  elseif c.thinned then
    gfx.drawstr(string.format("Showing %d of %d candidates (evenly thinned)", c.n, #cands))
  else
    gfx.drawstr("Click a node to prelisten. Ctrl/Cmd-click: add. Double-click: insert.")
  end
end

local function db_str(v)
  if not v or v <= 0 then return "-inf" end
  return string.format("%.1f dB", 20 * math.log(v, 10))
end

local function draw_main()
  buttons, row_hits, sliders = {}, {}, {}
  gfx.clear = 3355443

  -- ===== column A: reference + candidates =====
  local x, y = COL_A_X, 20
  draw_button(COL_A_X + COL_A_W - 120, 14, 120, 24, S.map_view and "List view" or "Map view", S.map_view).action = "toggle_map"
  gfx.set(1, 1, 1, 1)
  gset_xy(x, y); gfx.drawstr("Reference item")
  y = y + 20
  if ref_feat then
    gfx.set(0.3, 0.7, 1.0, 1)
    gset_xy(x, y); gfx.drawstr(fit_text(ref_name, COL_A_W))
    y = y + 18
    gfx.set(0.8, 0.8, 0.8, 1)
    local pitch = (ref_feat.pitch_hz and ref_feat.pitch_hz > 0) and string.format("%.0f Hz", ref_feat.pitch_hz) or "unpitched"
    gset_xy(x, y)
    gfx.drawstr(fit_text(string.format("%.2fs | centroid %.0f Hz | spread %.0f Hz",
      ref_feat.duration or 0, ref_feat.spectral_centroid or 0, ref_feat.spectral_bandwidth or 0), COL_A_W))
    y = y + 16
    gset_xy(x, y)
    gfx.drawstr(fit_text(string.format("level %s | flatness %.3f | %s",
      db_str(ref_feat.rms_mean), ref_feat.spectral_flatness or 0, pitch), COL_A_W))
    y = y + 16
  else
    gfx.set(0.75, 0.75, 0.75, 1)
    gset_xy(x, y); gfx.drawstr("(none analyzed yet)")
    y = y + 18
  end

  -- status / hints
  local cur = selected_item()
  if status ~= "" then
    if status_err then draw_wrapped(status, x, y, COL_A_W, 1.0, 0.5, 0.5, 3)
    else draw_wrapped(status, x, y, COL_A_W, 0.8, 0.9, 0.8, 3) end
  elseif analyzing then
    draw_wrapped("Analyzing...", x, y, COL_A_W, 0.9, 0.9, 0.5, 1)
  elseif cur and cur ~= analyzed_ptr then
    draw_wrapped("Selection changed - click Analyze (or press A).", x, y, COL_A_W, 0.9, 0.9, 0.5, 1)
  end

  gfx.set(1, 1, 1, 1)
  gset_xy(x, LIST_TOP - 24)
  if ref_feat then
    local nm = 0
    for _, cd in ipairs(cands) do if msel[cd.r] then nm = nm + 1 end end
    gfx.drawstr(string.format("Candidates: %d  (selected: %d)", #cands, nm))
    draw_button(COL_A_X + COL_A_W - 170, LIST_TOP - 30, 80, 24, "All", false).action = "sel_all"
    draw_button(COL_A_X + COL_A_W - 84, LIST_TOP - 30, 84, 24, "Clear", false).action = "sel_clear"
  else
    gfx.drawstr("Candidates")
  end

  if S.map_view then draw_map() end
  if not S.map_view then
  gfx.set(0.22, 0.22, 0.22, 1); grect(x, LIST_TOP, COL_A_W, VISIBLE_ROWS * ROW_H, 1)
  end
  for i = 1, (S.map_view and 0 or VISIBLE_ROWS) do
    local idx = scroll + i
    local cd = cands[idx]
    if not cd then break end
    local ry = LIST_TOP + (i - 1) * ROW_H
    if idx == sel then
      gfx.set(0.3, 0.7, 1.0, 0.9); grect(x, ry, COL_A_W, ROW_H, 1)
    elseif msel[cd.r] then
      gfx.set(0.3, 0.7, 1.0, 0.45); grect(x, ry, COL_A_W, ROW_H, 1)
    elseif i % 2 == 0 then
      gfx.set(0.26, 0.26, 0.26, 1); grect(x, ry, COL_A_W, ROW_H, 1)
    end
    gfx.set(1, 1, 1, 1)
    local right = string.format("%.2f  %.2fs  %.0fHz", cd.dist, cd.r.e - cd.r.s,
      cd.r.centroid or 0)
    gset_xy(x + 4, ry + (ROW_H - TEXT_H) / 2)
    gfx.drawstr(fit_text(string.format("%d. %s", idx, short_name(cd.r.file)), COL_A_W - 200))
    gset_xy(x + COL_A_W - 190, ry + (ROW_H - TEXT_H) / 2)
    gfx.drawstr(right)
    row_hits[#row_hits + 1] = { x = x, y = ry, w = COL_A_W, h = ROW_H, idx = idx }
  end
  if #cands > VISIBLE_ROWS and not S.map_view then
    gfx.set(0.7, 0.7, 0.7, 1)
    gset_xy(x, LIST_BOTTOM + 4)
    gfx.drawstr(string.format("%d-%d of %d (mouse wheel to scroll)",
      scroll + 1, math.min(scroll + VISIBLE_ROWS, #cands), #cands))
  end

  -- ===== column B: radius + criteria =====
  x, y = COL_B_X, 20
  draw_slider("radius", "Radius", "pct", 0.0, 1.0, x, y, COL_B_W)
  y = y + 36
  y = draw_wrapped("Radius = how far from the reference a fragment may be (0-100%). " ..
                   "Larger radius = more candidates.", x, y, COL_B_W, 0.7, 0.7, 0.7) + 8
  gfx.set(1, 1, 1, 1)
  gset_xy(x, y); gfx.drawstr("Criteria weights (0 = ignore)")
  y = y + 22
  for _, c in ipairs(CRITERIA) do
    draw_slider("w_" .. c.key, c.label, "pct", 0.0, 1.0, x, y, COL_B_W)
    y = y + 34
  end
  draw_button(x, y + 2, COL_B_W, 24,
    S.exclude_self and "Exclude the reference's own segment: ON" or "Exclude the reference's own segment: OFF",
    S.exclude_self).action = "toggle_exclude_self"
  y = y + 38
  gfx.set(1, 1, 1, 1)
  gset_xy(x, y); gfx.drawstr("Randomness (applied when inserting)")
  y = y + 22
  draw_slider("max_ins", "Max length (before random length)", "off_s", 0.0, 4.0, x, y, COL_B_W); y = y + 34
  draw_slider("rand_len", "Random length", "pct", 0.0, 1.0, x, y, COL_B_W); y = y + 34
  draw_slider("rand_pan", "Random pan", "pct", 0.0, 1.0, x, y, COL_B_W); y = y + 34
  draw_slider("rand_dist", "Random distance from target", "pct", 0.0, 1.0, x, y, COL_B_W); y = y + 34
  draw_slider("pick_n", "Number of items (closest / random)", "%.0f", 1, 32, x, y, COL_B_W); y = y + 38
  local npk = math.floor(S.pick_n + 0.5)
  local hw = (COL_B_W - 6) / 2
  draw_button(x, y, hw, 28, string.format("INSERT %d CLOSEST", npk), true).action = "insert_closest"
  draw_button(x + hw + 6, y, hw, 28, string.format("INSERT %d RANDOM", npk), true).action = "random_pick"
  y = y + 34
  draw_button(x, y, hw, 24, RFX.on and string.format("Random FX: ON (%d)", #RFX.list) or "Random FX: OFF",
    RFX.on).action = "toggle_rfx"
  draw_button(x + hw + 6, y, hw, 24, "Random FX params...", false).action = "rfx_setup"
  y = y + 28
  gfx.set(0.7, 0.7, 0.7, 1); gset_xy(x, y)
  gfx.drawstr(fit_text(rfx_summary(), COL_B_W))

  -- ===== column C: actions =====
  x, y = COL_C_X, 20
  local w = COL_C_W
  local bh = 26
  local cname = current_csv_path and short_name(current_csv_path) or "(none)"
  draw_button(x, y, w, bh, "Corpus: " .. cname, false).action = "switch_corpus"
  y = y + bh + 10
  draw_button(x, y, w, bh + 4, analyzing and "Analyzing..." or "Analyze selected item  (A)", analyzing).action = "analyze"
  y = y + bh + 14

  draw_button(x, y, w, bh, "Prelisten reference", false).action = "play_ref"
  y = y + bh + 4
  draw_button(x, y, w, bh, "Prelisten candidate  (Space)", false).action = "play_cand"
  y = y + bh + 4
  draw_button(x, y, w, bh, "Stop", false).action = "stop"
  y = y + bh + 14

  local nmk = #marked_rows()
  local ilabel = (nmk > 1) and string.format("INSERT %d selected candidates  (Enter)", nmk)
                            or "INSERT selected candidate  (Enter)"
  local ib = draw_button(x, y, w, bh + 8, ilabel, true)
  ib.action = "insert"
  y = y + bh + 8 + 6
  draw_button(x, y, w, bh, INSERT_MODES[S.insert_mode], false).action = "cycle_insert"
  y = y + bh + 4
  draw_button(x, y, w, bh, S.multi_stacked and "Several items: stacked (one track each)"
                                              or "Several items: one after another",
    false).action = "toggle_stacked"
  y = y + bh + 6
  draw_slider("gap", "Gap between items (s)", "%.2f", 0.0, 1.0, x, y, w)
  y = y + 40

  draw_button(x, y, w, bh, S.auto_prelisten and "Auto-prelisten on click: ON" or "Auto-prelisten on click: OFF",
    S.auto_prelisten).action = "toggle_auto"
  y = y + bh + 4
  draw_button(x, y, w, bh, S.hover_prelisten and "Prelisten on hover (map, H): ON" or "Prelisten on hover (map, H): OFF",
    S.hover_prelisten).action = "toggle_hover"
  y = y + bh + 4
  draw_button(x, y, w, bh, S.match_level and "Match level to reference: ON" or "Match level to reference: OFF",
    S.match_level).action = "toggle_level"
  y = y + bh + 4
  draw_button(x, y, w, bh, S.match_ref_len and "Match reference length: ON" or "Match reference length: OFF",
    S.match_ref_len).action = "toggle_len"
  y = y + bh + 12
  draw_button(x, y, w, bh, S.len_filter and "Target length filter: ON" or "Target length filter: OFF",
    S.len_filter).action = "toggle_len_filter"
  y = y + bh + 4
  draw_slider("len_min", "Length min (s)", "%.2f", 0.0, LEN_SLIDER_MAX, x, y, w)
  y = y + 34
  draw_slider("len_max", "Length max (s)", "%.2f", 0.0, LEN_SLIDER_MAX, x, y, w)
  y = y + 38

  local nf = n_folders_on()
  local flabel
  if #folders == 0 then flabel = "Subfolders: (corpus has only one folder)"
  elseif nf == 0 then flabel = string.format("Subfolders: all %d  (click to choose)", #folders)
  else flabel = string.format("Subfolders: %d of %d checked", nf, #folders) end
  draw_button(x, y, w, bh, fit_text(flabel, w - 12), nf > 0).action = "folder_menu"
  y = y + bh + 12

  draw_button(x, y, w, bh, "Python: " .. S.python, false).action = "set_python"
  y = y + bh + 10
  draw_wrapped("Ctrl/Cmd-click: add or remove; Shift-click: range. Double-click inserts one candidate.",
               x, y, w, 0.7, 0.7, 0.7)

  gfx.set(0.7, 0.7, 0.7, 1)
  gset_xy(COL_C_X, BASE_H - 24)
  gfx.drawstr("Esc / close window to quit")
end

-- ---------------------------------------------------------------------
-- Main loop
-- ---------------------------------------------------------------------
local prev_mouse_cap = 0
local pan_drag = nil
local hover_played = nil      -- fragment last played by hover-prelisten
local last_click_time, last_click_idx = 0, nil
local KEY_UP, KEY_DOWN = 30064, 1685026670

local function select_candidate(idx, play)
  if idx < 1 or idx > #cands then return end
  sel = idx
  if idx <= scroll then scroll = idx - 1 end
  if idx > scroll + VISIBLE_ROWS then scroll = idx - VISIBLE_ROWS end
  if play then prelisten_candidate(idx) end
end

-- shared by the list and the map: plain click = select (+prelisten),
-- Ctrl/Cmd-click = toggle, Shift-click = range, double-click = insert
-- t = time of the mouse press (defaults to now): double-clicks are timed
-- press to press, even when the click is handled on release
local DOUBLE_CLICK = 0.45
local function handle_candidate_click(idx, cap, t)
  local now = t or reaper.time_precise()
  local r = cands[idx].r
  local toggle = (cap & (4 | 32)) ~= 0
  local shift = (cap & 8) ~= 0
  if last_click_idx == idx and (now - last_click_time) < DOUBLE_CLICK and not toggle and not shift then
    select_candidate(idx, false)
    msel = { [r] = true }; anchor = idx
    insert_items({ r })
    last_click_idx = nil
    return
  end
  if toggle then
    msel[r] = (not msel[r]) or nil
    anchor = idx
    select_candidate(idx, S.auto_prelisten and msel[r] ~= nil)
    if not sel then sel = idx end
  elseif shift and anchor then
    msel = {}
    local a, b = math.min(anchor, idx), math.max(anchor, idx)
    for i = a, b do msel[cands[i].r] = true end
    select_candidate(idx, false)
  else
    msel = { [r] = true }; anchor = idx
    select_candidate(idx, S.auto_prelisten)
  end
  last_click_idx, last_click_time = idx, now
end

local function quit()
  stop_preview()
  gfx.quit()
end

local function loop()
  local char = gfx.getchar()
  if char < 0 or char == 27 then quit(); return end

  poll_job()

  local mx, my = slog(gfx.mouse_x), slog(gfx.mouse_y)
  local cap = gfx.mouse_cap
  local down_now = (cap & 1) == 1
  local down_prev = (prev_mouse_cap & 1) == 1
  local click = down_now and not down_prev
  local release = (not down_now) and down_prev

  -- ---------- corpus loading ----------
  if app_mode == "loading" then
    if loader then load_step() end
    prev_mouse_cap = cap
    if app_mode == "loading" then draw_loading() end
    gfx.update()
    reaper.defer(loop)
    return
  end

  -- ---------- corpus picker ----------
  if app_mode == "picking_corpus" then
    if click then
      for _, b in ipairs(buttons) do
        if point_in(mx, my, b.x, b.y, b.w, b.h) then
          if b.action == "pick_corpus_item" then
            load_corpus(b.corpus_path)
          elseif b.action == "pick_browse" then
            local ok, picked = reaper.GetUserFileNameForRead(CORPUS_DIR, "Select corpus CSV", "csv")
            if ok then load_corpus(picked) end
          end
          break
        end
      end
    end
    prev_mouse_cap = cap
    draw_corpus_picker()
    gfx.update()
    reaper.defer(loop)
    return
  end

  -- ---------- keyboard ----------
  if char == 32 then prelisten_candidate(sel or 1)
  elseif char == 13 then insert_items(marked_rows())
  elseif char == 122 or char == 90 then reset_view()
  elseif char == 104 or char == 72 then
    S.hover_prelisten = not S.hover_prelisten
    reaper.SetExtState(EXT, "hover_prelisten", S.hover_prelisten and "1" or "0", true)
  elseif char == 97 or char == 65 then analyze_selected()
  elseif char == KEY_UP and sel then
    select_candidate(sel - 1, S.auto_prelisten)
    if cands[sel] then msel = { [cands[sel].r] = true }; anchor = sel end
  elseif char == KEY_DOWN then
    select_candidate((sel or 0) + 1, S.auto_prelisten)
    if cands[sel] then msel = { [cands[sel].r] = true }; anchor = sel end
  end

  -- ---------- mouse wheel over the list ----------
  local wheel = gfx.mouse_wheel
  if wheel ~= 0 then
    gfx.mouse_wheel = 0
    if not S.map_view and point_in(mx, my, COL_A_X, LIST_TOP, COL_A_W, VISIBLE_ROWS * ROW_H) then
      scroll = clamp(scroll - (wheel > 0 and 3 or -3), 0, math.max(0, #cands - VISIBLE_ROWS))
    end
  end

  -- ---------- sliders ----------
  if click then
    for _, s in ipairs(sliders) do
      if point_in(mx, my, s.x, s.y - 2, s.w, s.h + 4) then dragging_slider = s; break end
    end
  end
  if dragging_slider then
    if down_now then
      local t = clamp((mx - dragging_slider.x) / dragging_slider.w, 0, 1)
      local v = dragging_slider.min + t * (dragging_slider.max - dragging_slider.min)
      local k = dragging_slider.key
      if k == "pick_n" then v = math.floor(v + 0.5) end
      if k == "max_ins" then v = (v < 0.02) and 0 or math.floor(v * 100 + 0.5) / 100 end
      if k == "len_min" or k == "len_max" then
        v = math.floor(v * 100 + 0.5) / 100
        if k == "len_min" and v > S.len_max then S.len_max = v end
        if k == "len_max" and v < S.len_min then S.len_min = v end
        S.len_filter = true   -- moving a length slider switches the filter on
      end
      if S[k] ~= v then
        S[k] = v
        if not NO_SEARCH_KEYS[k] then search_dirty = true end
      end
    end
    if release then dragging_slider = nil end
  end

  -- ---------- map zoom / pan (scroll = zoom, horizontal scroll / Alt+scroll / right- or Alt-drag = pan) ----------
  local rdown_now, rdown_prev = (cap & 2) == 2, (prev_mouse_cap & 2) == 2
  if S.map_view and point_in(mx, my, MAP_X, MAP_Y, MAP_W, MAP_H) then
    if wheel ~= 0 then
      if (cap & 16) ~= 0 then
        VIEW.cy = VIEW.cy + wheel * 0.0012 / VIEW.z
      else
        zoom_at(mx, my, math.exp(wheel * 0.0015))
      end
      clamp_view()
    end
    local hw = gfx.mouse_hwheel or 0
    if hw ~= 0 then VIEW.cx = VIEW.cx + hw * 0.0012 / VIEW.z; clamp_view() end
    if (click and (cap & 16) ~= 0) or (rdown_now and not rdown_prev) then
      pan_drag = { mx = mx, my = my, cx = VIEW.cx, cy = VIEW.cy }
    end
    if click and VIEW.z > 1.001 and point_in(mx, my, MAP_X + MAP_W - ZOOM_BTN.w - 4, MAP_Y + 4, ZOOM_BTN.w, ZOOM_BTN.h) then
      reset_view(); pan_drag = nil; click = false
    end
  end
  gfx.mouse_hwheel = 0
  if pan_drag then
    if down_now or rdown_now then
      VIEW.cx = pan_drag.cx - (mx - pan_drag.mx) / ((MAP_W - 2 * MAP_PAD) * VIEW.z)
      VIEW.cy = pan_drag.cy + (my - pan_drag.my) / ((MAP_H - 2 * MAP_PAD) * VIEW.z)
      clamp_view()
    else pan_drag = nil end
  end

  -- ---------- list / map click ----------
  local handled = false
  if click and not dragging_slider and not pan_drag then
    if S.map_view then
      update_map_hover(mx, my)
      if map_hover then handled = true; handle_candidate_click(map_hover, cap) end
    else
      for _, h in ipairs(row_hits) do
        if point_in(mx, my, h.x, h.y, h.w, h.h) then
          handled = true
          handle_candidate_click(h.idx, cap)
          break
        end
      end
    end
  end

  -- ---------- buttons ----------
  if click and not dragging_slider and not handled then
    for _, b in ipairs(buttons) do
      if point_in(mx, my, b.x, b.y, b.w, b.h) then
        local a = b.action
        if a == "switch_corpus" then
          stop_preview(); refresh_corpus_pick_items(); app_mode = "picking_corpus"
        elseif a == "analyze" then analyze_selected()
        elseif a == "play_ref" then prelisten_reference()
        elseif a == "play_cand" then prelisten_candidate(sel or 1)
        elseif a == "stop" then stop_preview()
        elseif a == "insert" then
          local rows = marked_rows()
          if #rows > 0 then insert_items(rows) else set_status("Click a candidate first.", true) end
        elseif a == "sel_all" then
          msel = {}
          for _, cd in ipairs(cands) do msel[cd.r] = true end
        elseif a == "sel_clear" then
          msel = {}
        elseif a == "toggle_stacked" then S.multi_stacked = not S.multi_stacked
        elseif a == "toggle_rfx" then RFX.on = not RFX.on; rfx_save()
        elseif a == "rfx_setup" then rfx_menu(sx(b.x), sx(b.y + b.h))
        elseif a == "random_pick" then random_pick_and_insert()
        elseif a == "insert_closest" then insert_closest()
        elseif a == "toggle_map" then S.map_view = not S.map_view
        elseif a == "map_x" or a == "map_y" or a == "map_size" or a == "map_color" then
          local k = "map_" .. a:sub(5)
          local lo = (a == "map_size" or a == "map_color") and 0 or 1
          local n = #MAP_DESCS
          local step = ((cap & 8) ~= 0) and -1 or 1
          S[k] = lo + ((S[k] - lo + step) % (n - lo + 1))
          if a == "map_x" or a == "map_y" then reset_view() end
        elseif a == "cycle_insert" then S.insert_mode = (S.insert_mode % #INSERT_MODES) + 1
        elseif a == "toggle_auto" then S.auto_prelisten = not S.auto_prelisten
        elseif a == "toggle_hover" then
          S.hover_prelisten = not S.hover_prelisten
          reaper.SetExtState(EXT, "hover_prelisten", S.hover_prelisten and "1" or "0", true)
        elseif a == "toggle_level" then S.match_level = not S.match_level
        elseif a == "toggle_len" then S.match_ref_len = not S.match_ref_len
        elseif a == "toggle_len_filter" then S.len_filter = not S.len_filter; search_dirty = true
        elseif a == "toggle_exclude_self" then S.exclude_self = not S.exclude_self; search_dirty = true
        elseif a == "folder_menu" then folder_menu(sx(b.x), sx(b.y + b.h))
        elseif a == "set_python" then
          local ok, res = reaper.GetUserInputs("Python executable", 1, "Full path,extrawidth=300", S.python)
          if ok and res ~= "" then
            S.python = res
            reaper.SetExtState(EXT, "python", res, true)
          end
        end
        break
      end
    end
  end

  -- ---------- right-click on a map selector: pick the descriptor from a list ----------
  if rdown_now and not rdown_prev then
    for _, b in ipairs(buttons) do
      local a = b.action
      if (a == "map_x" or a == "map_y" or a == "map_size" or a == "map_color") and point_in(mx, my, b.x, b.y, b.w, b.h) then
        local k = "map_" .. a:sub(5)
        local optional = (a == "map_size" or a == "map_color")
        local items = {}
        if optional then items[#items + 1] = (S[k] == 0 and "!" or "") .. "(none)" end
        for i, d in ipairs(MAP_DESCS) do items[#items + 1] = (S[k] == i and "!" or "") .. d.label end
        gfx.x, gfx.y = gfx.mouse_x, gfx.mouse_y
        local choice = gfx.showmenu(table.concat(items, "|"))
        if choice > 0 then
          S[k] = optional and (choice - 1) or choice
          if a == "map_x" or a == "map_y" then reset_view() end
        end
        break
      end
    end
  end

  if preview_stop_time and reaper.time_precise() >= preview_stop_time then stop_preview() end
  if search_dirty then compute_candidates() end
  if S.map_view then
    update_map_hover(mx, my)
    -- prelisten on hover: play a node when the mouse enters it (no button held)
    local hr = map_hover and cands[map_hover] and cands[map_hover].r or nil
    if S.hover_prelisten and hr and hr ~= hover_played and not down_now then
      prelisten_candidate(map_hover)
    end
    hover_played = hr
  end

  prev_mouse_cap = cap
  draw_main()
  gfx.update()
  reaper.defer(loop)
end

-- ---------------------------------------------------------------------
-- Start: reload the last corpus if there is one, else show the picker;
-- analyze the selected item right away if exactly one is selected.
-- ---------------------------------------------------------------------
math.randomseed(os.time())
refresh_corpus_pick_items()
local last = get_ext("corpus", "")
if last ~= "" and file_exists(last) and load_corpus(last) then
  -- corpus loads in the background of the UI; analyze the selected item in
  -- parallel (Python startup overlaps with CSV loading)
  if selected_item() then analyze_selected() end
end

reaper.defer(loop)
