--[[
generate_chain.lua

Free (non-target-driven) concatenative synthesis generator. Builds a
chain of fragments directly from corpus_clustered.csv -- no target
audio needed. Two selection modes:

  "random"       -- pick each unit uniformly at random from the
                     (optionally cluster-filtered) corpus.

  "walk"         -- start from a random fragment, then at each step
                     move to one of its K nearest timbral neighbors
                     (in the same normalized feature space used for
                     clustering), chosen randomly among those K. This
                     produces smoother, more "natural" wandering
                     through timbre space instead of jumping randomly,
                     while still varying -- closer to how the original
                     recordings' sounds might plausibly evolve.

Usage:
  1. Actions > Show action list > New action... > Load ReaScript...
     and select this file. Run it.
  2. It prompts you to choose corpus_clustered.csv.
  3. A new track "Generated Chain" is created and populated.

Configuration (edit the CONFIG block below).
--]]

-- ===================== CONFIG =====================
local NUM_UNITS       = 40          -- how many fragments to generate
local SELECTION_MODE  = "walk"      -- "random" or "walk"
local WALK_NEIGHBORS  = 6           -- for "walk" mode: pick randomly among K nearest neighbors
local CLUSTER_FILTER  = nil         -- nil = any cluster, or a number e.g. 3, or a table e.g. {3, 7, 9}
local MIN_DURATION    = nil         -- nil = no filter, or a number in seconds
local MAX_DURATION    = nil         -- nil = no filter, or a number in seconds
local CROSSFADE_SEC   = 0.015
local RANDOM_SEED     = nil         -- nil = different result every run, or an integer for repeatability
-- ===================================================


-- ---------------------------------------------------------------------
-- CSV parsing (same approach as place_matches.lua)
-- ---------------------------------------------------------------------
local function parse_csv_line(line)
  local fields = {}
  local field = ""
  local in_quotes = false
  local i = 1
  local n = #line
  while i <= n do
    local c = line:sub(i, i)
    if in_quotes then
      if c == '"' then
        if line:sub(i + 1, i + 1) == '"' then
          field = field .. '"'
          i = i + 1
        else
          in_quotes = false
        end
      else
        field = field .. c
      end
    else
      if c == '"' then
        in_quotes = true
      elseif c == "," then
        table.insert(fields, field)
        field = ""
      else
        field = field .. c
      end
    end
    i = i + 1
  end
  table.insert(fields, field)
  return fields
end

local function read_csv(path)
  local f = io.open(path, "r")
  if not f then
    return nil, "Could not open file: " .. path
  end
  local header = nil
  local rows = {}
  for line in f:lines() do
    if line ~= "" then
      local fields = parse_csv_line(line)
      if not header then
        header = fields
      else
        local row = {}
        for idx, key in ipairs(header) do
          row[key] = fields[idx]
        end
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
local function cluster_matches_filter(cluster_id)
  if CLUSTER_FILTER == nil then
    return true
  end
  if type(CLUSTER_FILTER) == "number" then
    return cluster_id == CLUSTER_FILTER
  end
  if type(CLUSTER_FILTER) == "table" then
    for _, c in ipairs(CLUSTER_FILTER) do
      if c == cluster_id then
        return true
      end
    end
    return false
  end
  return true
end

local function passes_filters(row)
  local cluster_id = tonumber(row.cluster_id)
  if not cluster_matches_filter(cluster_id) then
    return false
  end
  local dur = tonumber(row.duration)
  if MIN_DURATION and dur < MIN_DURATION then
    return false
  end
  if MAX_DURATION and dur > MAX_DURATION then
    return false
  end
  return true
end

-- Extract the z_* feature vector for a row, given the ordered list of
-- z-column names discovered from the CSV header.
local function get_z_vector(row, z_cols)
  local v = {}
  for i, col in ipairs(z_cols) do
    v[i] = tonumber(row[col]) or 0.0
  end
  return v
end

local function euclidean_dist(a, b)
  local sum = 0.0
  for i = 1, #a do
    local d = a[i] - b[i]
    sum = sum + d * d
  end
  return math.sqrt(sum)
end


-- ---------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------
local function main()
  if RANDOM_SEED then
    math.randomseed(RANDOM_SEED)
  else
    math.randomseed(os.time())
  end

  local retval, csv_path = reaper.GetUserFileNameForRead("", "Select corpus_clustered.csv", "csv")
  if not retval then
    return
  end

  local rows, header = read_csv(csv_path)
  if not rows then
    reaper.ShowMessageBox("Could not read CSV: " .. csv_path, "Error", 0)
    return
  end

  -- discover z_* columns from header, in a stable order
  local z_cols = {}
  for _, col in ipairs(header) do
    if col:sub(1, 2) == "z_" then
      table.insert(z_cols, col)
    end
  end
  if #z_cols == 0 then
    reaper.ShowMessageBox(
      "No z_* columns found in this CSV. Make sure you selected corpus_clustered.csv (from cluster_corpus.py), not the raw analyze_corpus.py output.",
      "Error", 0
    )
    return
  end

  -- filter candidate pool
  local pool = {}
  for _, row in ipairs(rows) do
    if passes_filters(row) then
      table.insert(pool, row)
    end
  end

  if #pool == 0 then
    reaper.ShowMessageBox("No fragments pass the current CLUSTER_FILTER / duration filters.", "Nothing to generate", 0)
    return
  end

  -- precompute z-vectors for the pool (used in "walk" mode)
  local pool_vectors = {}
  if SELECTION_MODE == "walk" then
    for i, row in ipairs(pool) do
      pool_vectors[i] = get_z_vector(row, z_cols)
    end
  end

  -- build the sequence of chosen pool-indices
  local sequence = {}
  if SELECTION_MODE == "random" then
    for i = 1, NUM_UNITS do
      sequence[i] = math.random(1, #pool)
    end
  else -- "walk"
    local current = math.random(1, #pool)
    sequence[1] = current
    for i = 2, NUM_UNITS do
      local cur_vec = pool_vectors[current]
      -- compute distances to all pool members, take K nearest (excluding self)
      local dists = {}
      for j = 1, #pool do
        if j ~= current then
          table.insert(dists, { idx = j, d = euclidean_dist(cur_vec, pool_vectors[j]) })
        end
      end
      table.sort(dists, function(a, b) return a.d < b.d end)
      local k = math.min(WALK_NEIGHBORS, #dists)
      local pick = dists[math.random(1, k)].idx
      sequence[i] = pick
      current = pick
    end
  end

  -- place items sequentially on a new track
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local track_idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(track_idx, true)
  local track = reaper.GetTrack(0, track_idx)
  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "Generated Chain", true)

  local cursor_pos = 0.0
  local placed = 0
  local skipped = 0

  for _, pool_idx in ipairs(sequence) do
    local row = pool[pool_idx]
    local file_path = row.file_path
    local src_start = tonumber(row.start_sec)
    local src_end = tonumber(row.end_sec)
    local frag_len = src_end and src_start and (src_end - src_start) or nil

    if not file_path or not frag_len or frag_len <= 0 then
      skipped = skipped + 1
    else
      local source = reaper.PCM_Source_CreateFromFile(file_path)
      if not source then
        skipped = skipped + 1
      else
        local item = reaper.AddMediaItemToTrack(track)
        local take = reaper.AddTakeToMediaItem(item)
        reaper.SetMediaItemTake_Source(take, source)

        reaper.SetMediaItemInfo_Value(item, "D_POSITION", cursor_pos)
        reaper.SetMediaItemInfo_Value(item, "D_LENGTH", frag_len)
        reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", src_start)

        reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", CROSSFADE_SEC)
        reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", CROSSFADE_SEC)

        local short_name = file_path:match("([^/\\]+)$") or file_path
        local cluster_label = row.cluster_id and (" [c" .. row.cluster_id .. "]") or ""
        reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", short_name .. cluster_label, true)

        cursor_pos = cursor_pos + frag_len
        placed = placed + 1
      end
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Generate concatenative chain", -1)

  reaper.ShowMessageBox(
    string.format("Placed %d fragments (%d skipped) on track 'Generated Chain'.\nMode: %s   Pool size: %d",
      placed, skipped, SELECTION_MODE, #pool),
    "Done",
    0
  )
end

main()
