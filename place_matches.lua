--[[
place_matches.lua

Reads the matches.csv produced by match_target.py and builds a
concatenative resynthesis on a new REAPER track: for each target
segment, places the best-matching (rank 0) corpus fragment as a
media item, pointing directly at an offset into the original source
file -- no audio is rendered or copied.

Usage:
  1. In REAPER: Actions > Show action list > New action... > Load ReaScript...
     and select this file. Then run it (or bind it to a key).
  2. It will prompt you to choose matches.csv.
  3. A new track "Concatenative Resynthesis" is created and populated.

Configuration (edit the CONFIG block below):
  PLACEMENT_MODE:
    "original_timing" -- places each fragment at the target segment's
                          original position in the target audio (gaps/
                          overlaps between fragments are normal and
                          expected -- this mirrors the target's rhythm).
    "sequential"       -- places fragments back-to-back with no gaps,
                          in target_index order (denser, less faithful
                          to original timing, good for granular textures).

  CROSSFADE_SEC        -- fade in/out length applied to each item, to
                          avoid clicks at fragment boundaries.

  USE_RANK             -- which match rank to use (0 = closest match).
                          Only rows with this rank are placed.
--]]

-- ===================== CONFIG =====================
local PLACEMENT_MODE = "original_timing"   -- "original_timing" or "sequential"
local CROSSFADE_SEC   = 0.015
local USE_RANK        = 0
-- ===================================================


-- ---------------------------------------------------------------------
-- Minimal CSV parser (handles simple quoted fields, which is enough for
-- pandas-generated CSVs where only file paths might theoretically need
-- quoting; plain comma-split covers the common case of unquoted paths).
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
  return rows
end


-- ---------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------
local function main()
  local retval, csv_path = reaper.GetUserFileNameForRead("", "Select matches.csv", "csv")
  if not retval then
    return
  end

  local rows, err = read_csv(csv_path)
  if not rows then
    reaper.ShowMessageBox(err, "Error", 0)
    return
  end

  -- keep only the requested rank, sorted by target_index
  local filtered = {}
  for _, row in ipairs(rows) do
    if tonumber(row.rank) == USE_RANK then
      table.insert(filtered, row)
    end
  end
  table.sort(filtered, function(a, b)
    return tonumber(a.target_index) < tonumber(b.target_index)
  end)

  if #filtered == 0 then
    reaper.ShowMessageBox("No rows found with rank == " .. USE_RANK, "Nothing to place", 0)
    return
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- create a new track at the end
  local track_idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(track_idx, true)
  local track = reaper.GetTrack(0, track_idx)
  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "Concatenative Resynthesis", true)

  local cursor_pos = 0.0
  local placed = 0
  local skipped = 0

  for _, row in ipairs(filtered) do
    local file_path = row.match_file_path
    local src_start = tonumber(row.match_start_sec)
    local src_end = tonumber(row.match_end_sec)
    local frag_len = src_end - src_start

    if not file_path or frag_len == nil or frag_len <= 0 then
      skipped = skipped + 1
    else
      local source = reaper.PCM_Source_CreateFromFile(file_path)
      if not source then
        skipped = skipped + 1
      else
        local item = reaper.AddMediaItemToTrack(track)
        local take = reaper.AddTakeToMediaItem(item)
        reaper.SetMediaItemTake_Source(take, source)

        local position
        if PLACEMENT_MODE == "original_timing" then
          position = tonumber(row.target_start_sec)
        else
          position = cursor_pos
        end

        reaper.SetMediaItemInfo_Value(item, "D_POSITION", position)
        reaper.SetMediaItemInfo_Value(item, "D_LENGTH", frag_len)
        reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", src_start)

        reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", CROSSFADE_SEC)
        reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", CROSSFADE_SEC)

        -- label the take with the source filename for quick visual reference
        local short_name = file_path:match("([^/\\]+)$") or file_path
        reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", short_name, true)

        if PLACEMENT_MODE == "sequential" then
          cursor_pos = cursor_pos + frag_len
        end

        placed = placed + 1
      end
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Place concatenative synthesis matches", -1)

  reaper.ShowMessageBox(
    string.format("Placed %d fragments (%d skipped) on track '%s'.", placed, skipped, "Concatenative Resynthesis"),
    "Done",
    0
  )
end

main()
