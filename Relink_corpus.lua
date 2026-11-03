--[[
Relink_corpus.lua

Moved, renamed or reorganised your sound folder? Point this script at the
folder where the sounds are NOW. It scans it (with all its subfolders),
then repairs every checked corpus CSV in corpus_data/ by matching each
missing source file by its file name.

  - No need to know or type the old folder.
  - Subfolders may have been renamed or reorganised: files are found
    wherever they are under the new folder.
  - If the same file name exists in several places, the one whose
    path looks most like the old path wins (counted as "ambiguous").
  - Files that still exist where the CSV says are left untouched.
  - Corpora with missing files are flagged in red and pre-checked.
  - Each CSV is backed up as .bak before being rewritten.
  - The last folder you chose is remembered.

No Python needed. Works on macOS and Windows.
--]]

local IS_WIN = package.config:sub(1, 1) == "\\"
local SEP = IS_WIN and "\\" or "/"
local EXT_SECTION = "Relink_corpus"

local AUDIO_EXT = { wav = 1, wave = 1, aif = 1, aiff = 1, aifc = 1, flac = 1,
  mp3 = 1, ogg = 1, opus = 1, m4a = 1, w64 = 1, caf = 1, bwf = 1 }

-- ---------------------------------------------------------------------
-- Paths and files
-- ---------------------------------------------------------------------
local function script_dir()
  local p = debug.getinfo(1, "S").source:sub(2)
  return p:match("(.*[/\\])") or ""
end

local DIR = script_dir()
local CORPUS_DIR = DIR .. "corpus_data" .. SEP

local function strip_sep(p) return (p:gsub("[/\\]+$", "")) end
local function basename(p) return p:match("([^/\\]+)$") end

local function file_exists(p)
  local f = io.open(p, "rb")
  if f then f:close() return true end
  return false
end

local function read_file(p)
  local f = io.open(p, "rb"); if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end

local function write_file(p, s)
  local f = io.open(p, "wb"); if not f then return false end
  f:write(s); f:close(); return true
end

-- ---------------------------------------------------------------------
-- CSV (quoted fields with commas / quotes are handled)
-- ---------------------------------------------------------------------
local function parse_line(line)
  local res, i, n = {}, 1, #line
  while true do
    if line:sub(i, i) == '"' then
      local buf, j = {}, i + 1
      while j <= n do
        local c = line:sub(j, j)
        if c == '"' then
          if line:sub(j + 1, j + 1) == '"' then buf[#buf + 1] = '"'; j = j + 2
          else j = j + 1; break end
        else buf[#buf + 1] = c; j = j + 1 end
      end
      res[#res + 1] = table.concat(buf); i = j
    else
      local j = line:find(",", i, true) or (n + 1)
      res[#res + 1] = line:sub(i, j - 1); i = j
    end
    if line:sub(i, i) == "," then i = i + 1 else break end
  end
  return res
end

local function to_field(s)
  if s:find('[,"\r\n]') then return '"' .. (s:gsub('"', '""')) .. '"' end
  return s
end

-- returns { header = {...}, rows = {{...}}, col = index of file_path or nil }
local function read_csv(path)
  local txt = read_file(path); if not txt then return nil end
  local lines = {}
  for line in (txt .. "\n"):gmatch("(.-)\r?\n") do
    if line ~= "" then lines[#lines + 1] = line end
  end
  if #lines == 0 then return { header = {}, rows = {} } end
  local header = parse_line(lines[1])
  local col
  for k, h in ipairs(header) do
    if h:gsub("^\239\187\191", "") == "file_path" then col = k end
  end
  local rows = {}
  for k = 2, #lines do rows[#rows + 1] = parse_line(lines[k]) end
  return { header = header, rows = rows, col = col, raw = txt }
end

local function write_csv(path, t)
  local out = {}
  local function line(fields)
    local f = {}
    for k, v in ipairs(fields) do f[k] = to_field(v) end
    return table.concat(f, ",")
  end
  out[1] = line(t.header)
  for _, r in ipairs(t.rows) do out[#out + 1] = line(r) end
  write_file(path .. ".bak", t.raw)
  return write_file(path, table.concat(out, "\n") .. "\n")
end

-- ---------------------------------------------------------------------
-- Scan new folder: lower-case file name -> list of full paths
-- ---------------------------------------------------------------------
local function scan(dir, idx, depth)
  depth = depth or 0
  if depth > 30 then return idx end
  pcall(reaper.EnumerateFiles, dir, -1)            -- force fresh listing
  local i = 0
  while true do
    local f = reaper.EnumerateFiles(dir, i); if not f then break end
    local ext = f:match("%.([^.]+)$")
    if ext and AUDIO_EXT[ext:lower()] then
      local key = f:lower()
      idx[key] = idx[key] or {}
      table.insert(idx[key], dir .. SEP .. f)
    end
    i = i + 1
  end
  i = 0
  while true do
    local d = reaper.EnumerateSubdirectories(dir, i); if not d then break end
    if d:sub(1, 1) ~= "." then scan(dir .. SEP .. d, idx, depth + 1) end
    i = i + 1
  end
  return idx
end

local function split_lower(p)
  local t = {}
  for c in p:gmatch("[^/\\]+") do t[#t + 1] = c:lower() end
  return t
end

-- number of trailing path components two paths share
local function suffix_score(a, b)
  local A, B = split_lower(a), split_lower(b)
  local k = 0
  while k < #A and k < #B and A[#A - k] == B[#B - k] do k = k + 1 end
  return k
end

local function find_new(old, idx)
  local base = basename(old); if not base then return nil end
  local c = idx[base:lower()]; if not c then return nil end
  if #c == 1 then return c[1], false end
  local best, bs, tie = nil, -1, false
  for _, p in ipairs(c) do
    local s = suffix_score(old, p)
    if s > bs then best, bs, tie = p, s, false
    elseif s == bs then tie = true end
  end
  return best, tie
end

-- ---------------------------------------------------------------------
-- Corpus status and relinking
-- ---------------------------------------------------------------------
local function corpus_status(path)
  local t = read_csv(path)
  if not t then return { err = "can't read" } end
  if not t.col then return { err = "no file_path column" } end
  local seen, files, missing = {}, 0, 0
  for _, r in ipairs(t.rows) do
    local p = r[t.col]
    if p and not seen[p] then
      seen[p] = true; files = files + 1
      if not file_exists(p) then missing = missing + 1 end
    end
  end
  return { files = files, missing = missing }
end

local function relink_csv(path, idx)
  local t = read_csv(path)
  if not t or not t.col then return nil end
  local cache, st = {}, { fixed = 0, missing = 0, ambiguous = 0, ok = 0 }
  local changed = false
  for _, r in ipairs(t.rows) do
    local p = r[t.col]
    if p then
      local c = cache[p]
      if not c then
        if file_exists(p) then c = { p = p, kind = "ok" }
        else
          local np, tie = find_new(p, idx)
          if np then c = { p = np, kind = tie and "ambiguous" or "fixed" }
          else c = { p = p, kind = "missing" } end
        end
        cache[p] = c
        st[c.kind] = st[c.kind] + 1
        if c.kind == "ambiguous" then st.fixed = st.fixed + 1 end
      end
      if c.p ~= p then r[t.col] = c.p; changed = true end
    end
  end
  if changed then write_csv(path, t) end
  return st
end

-- ---------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------
local new_dir = reaper.GetExtState(EXT_SECTION, "last_dir") or ""
local corpora = {}       -- { path, name, status, checked }
local result = {}        -- lines of text
local result_err = false
local scroll = 0

local function refresh_corpora()
  local keep = {}
  for _, c in ipairs(corpora) do keep[c.path] = c.checked end
  corpora = {}
  pcall(reaper.EnumerateFiles, CORPUS_DIR, -1)
  local i = 0
  while true do
    local f = reaper.EnumerateFiles(CORPUS_DIR, i); if not f then break end
    if f:lower():match("%.csv$") then
      local p = CORPUS_DIR .. f
      local st = corpus_status(p)
      local broken = (st.missing or 0) > 0
      local checked = keep[p]
      if checked == nil then checked = broken end
      corpora[#corpora + 1] = { path = p, name = f, status = st, checked = checked }
    end
    i = i + 1
  end
  table.sort(corpora, function(a, b) return a.name:lower() < b.name:lower() end)
end

local function do_relink()
  result, result_err = {}, false
  if new_dir == "" then result = { "Choose the folder where the sounds are now." }; result_err = true; return end
  local idx = scan(strip_sep(new_dir), {})
  local n = 0
  for _ in pairs(idx) do n = n + 1 end
  if n == 0 then result = { "No audio files found in that folder." }; result_err = true; return end
  result[#result + 1] = n .. " audio file names found in the new folder."
  local total_missing = 0
  for _, c in ipairs(corpora) do
    if c.checked then
      local st = relink_csv(c.path, idx)
      if not st then
        result[#result + 1] = c.name .. ": skipped (no file_path column)"
      else
        local s = string.format("%s: %d relinked", c.name, st.fixed)
        if st.ambiguous > 0 then s = s .. string.format(" (%d ambiguous)", st.ambiguous) end
        if st.missing > 0 then s = s .. string.format(", %d still missing", st.missing) end
        result[#result + 1] = s
        total_missing = total_missing + st.missing
      end
    end
  end
  if #result == 1 then result[#result + 1] = "No corpus checked." end
  result_err = total_missing > 0
  refresh_corpora()
end

-- ---------------------------------------------------------------------
-- Folder picker
-- ---------------------------------------------------------------------
local function browse_for_folder(title, start)
  if reaper.JS_Dialog_BrowseForFolder then
    local rv, f = reaper.JS_Dialog_BrowseForFolder(title, start ~= "" and start or DIR)
    if rv == 1 and f and f ~= "" then return strip_sep(f) end
    return nil
  end
  local ok, file = reaper.GetUserFileNameForRead(start, title .. " (pick any file inside it)", "")
  if ok and file ~= "" then return file:match("(.*)[/\\]") end
  return nil
end

-- ---------------------------------------------------------------------
-- GUI
-- ---------------------------------------------------------------------
local BASE_W, BASE_H = 640, 600
local ROW_H = 26
gfx.ext_retina = 1
gfx.init("Relink corpus", BASE_W, BASE_H)
local SC = math.max(1, gfx.ext_retina or 1)
local function S(v) return math.floor(v * SC + 0.5) end
local function slog(v) return v / SC end
gfx.setfont(1, "Arial", S(14))

local buttons = {}

local function rect(x, y, w, h, fill) gfx.rect(S(x), S(y), S(w), S(h), fill and 1 or 0) end
local function text(x, y, s, r, g, b)
  gfx.set(r or 0.9, g or 0.9, b or 0.9, 1)
  gfx.x, gfx.y = S(x), S(y); gfx.drawstr(s)
end

local function fit(s, w)
  if gfx.measurestr(s) <= S(w) then return s end
  while #s > 4 and gfx.measurestr("..." .. s) > S(w) do s = s:sub(2) end
  return "..." .. s
end

local function button(x, y, w, h, label, active, disabled, action)
  if active then gfx.set(0.25, 0.45, 0.7, 1) else gfx.set(0.22, 0.22, 0.24, 1) end
  rect(x, y, w, h, true)
  gfx.set(0.4, 0.4, 0.45, 1); rect(x, y, w, h, false)
  local s = fit(label, w - 12)
  local tw, th = gfx.measurestr(s)
  local c = disabled and 0.45 or 0.92
  gfx.set(c, c, c, 1)
  gfx.x = S(x) + math.floor((S(w) - tw) / 2); gfx.y = S(y) + math.floor((S(h) - th) / 2)
  gfx.drawstr(s)
  local b = { x = x, y = y, w = w, h = h, action = action, disabled = disabled }
  buttons[#buttons + 1] = b
  return b
end

local list_top, list_h = 0, 0

local function draw()
  buttons = {}
  gfx.set(0.13, 0.13, 0.14, 1); gfx.rect(0, 0, gfx.w, gfx.h, 1)
  local H = slog(gfx.h)
  local W = slog(gfx.w) - 32
  local x, y = 16, 14

  text(x, y, "1. Folder where the sounds are now (subfolders included):"); y = y + 22
  button(x, y, W - 110, ROW_H, new_dir ~= "" and new_dir or "(not set)", false, false, "noop")
  button(x + W - 100, y, 100, ROW_H, "Browse...", false, false, "browse")
  y = y + ROW_H + 18

  text(x, y, "2. Corpora to repair (red = files missing):")
  button(x + W - 250, y - 4, 80, 22, "Broken", false, false, "sel_broken")
  button(x + W - 165, y - 4, 50, 22, "All", false, false, "sel_all")
  button(x + W - 110, y - 4, 50, 22, "None", false, false, "sel_none")
  button(x + W - 55, y - 4, 55, 22, "Rescan", false, false, "rescan")
  y = y + 24

  local bottom_reserved = 70 + math.max(1, #result) * 18 + 20
  list_top = y
  list_h = math.max(ROW_H * 2, H - y - bottom_reserved)
  local visible = math.floor(list_h / (ROW_H + 2))
  scroll = math.max(0, math.min(scroll, #corpora - visible))

  if #corpora == 0 then
    text(x, y + 4, "No CSV found in " .. CORPUS_DIR, 0.7, 0.7, 0.7)
  end
  for k = 1, math.min(visible, #corpora - scroll) do
    local c = corpora[k + scroll]
    local st = c.status
    local status, r, g, b
    if st.err then status, r, g, b = st.err, 0.6, 0.6, 0.6
    elseif st.missing > 0 then status, r, g, b = string.format("%d / %d files missing", st.missing, st.files), 1.0, 0.45, 0.45
    else status, r, g, b = string.format("OK (%d files)", st.files), 0.55, 0.9, 0.55 end
    button(x, y, 26, ROW_H, c.checked and "x" or "", c.checked, false, "toggle").corpus = c
    local sw = math.min(220, gfx.measurestr(status) / SC + 10)
    gfx.set(0.92, 0.92, 0.92, 1)
    gfx.x, gfx.y = S(x + 34), S(y + 5); gfx.drawstr(fit(c.name, W - 34 - sw - 10))
    gfx.set(r, g, b, 1)
    gfx.x, gfx.y = S(x + W - sw), S(y + 5); gfx.drawstr(status)
    y = y + ROW_H + 2
  end
  if #corpora > visible then
    text(x, list_top + list_h - 2, string.format("(%d-%d of %d, scroll with mouse wheel)",
      scroll + 1, scroll + visible, #corpora), 0.6, 0.6, 0.6)
  end

  y = list_top + list_h + 16
  local n = 0
  for _, c in ipairs(corpora) do if c.checked then n = n + 1 end end
  button(x, y, W, 38, string.format("RELINK %d corpus CSV%s", n, n == 1 and "" or "s"),
    false, n == 0 or new_dir == "", "run")
  y = y + 50
  for _, l in ipairs(result) do
    if result_err then text(x, y, l, 1.0, 0.6, 0.5) else text(x, y, l, 0.6, 0.95, 0.6) end
    y = y + 18
  end
end

local prev_cap = 0
local function loop()
  local mx, my = slog(gfx.mouse_x), slog(gfx.mouse_y)
  local cap = gfx.mouse_cap
  local click = (cap & 1) == 1 and (prev_cap & 1) == 0
  prev_cap = cap

  if gfx.mouse_wheel ~= 0 then
    scroll = scroll - (gfx.mouse_wheel > 0 and 1 or -1)
    gfx.mouse_wheel = 0
  end

  if click then
    for _, b in ipairs(buttons) do
      if not b.disabled and mx >= b.x and mx <= b.x + b.w and my >= b.y and my <= b.y + b.h then
        local a = b.action
        if a == "browse" then
          local f = browse_for_folder("Folder where the sounds are now", new_dir)
          if f then
            new_dir = f
            reaper.SetExtState(EXT_SECTION, "last_dir", f, true)
            result = {}
          end
        elseif a == "toggle" then b.corpus.checked = not b.corpus.checked
        elseif a == "sel_broken" then for _, c in ipairs(corpora) do c.checked = (c.status.missing or 0) > 0 end
        elseif a == "sel_all" then for _, c in ipairs(corpora) do c.checked = not c.status.err end
        elseif a == "sel_none" then for _, c in ipairs(corpora) do c.checked = false end
        elseif a == "rescan" then refresh_corpora(); result = {}
        elseif a == "run" then do_relink()
        end
        break
      end
    end
  end

  draw()
  gfx.update()
  local ch = gfx.getchar()
  if ch >= 0 and ch ~= 27 then reaper.defer(loop) else gfx.quit() end
end

refresh_corpora()
reaper.defer(loop)
