--- Scanner module for nvim-flashcards.
--- Walks directories, parses markdown files for cards, writes IDs back to
--- source files for cards that lack them, upserts cards to storage, and
--- detects orphaned cards (soft-delete).
--- @module flashcards.scanner
local M = {}

local parser = require("flashcards.parser")
local utils = require("flashcards.utils")

-- ============================================================================
-- Internal Helpers
-- ============================================================================

--- Determine the line in the raw file where an ID comment should be appended.
--- For inline cards this is the card's line number.
--- For fenced cards this is also the card's line number (the :::card opener).
--- @param card table parsed card (with .line field)
--- @return number line_number (1-based)
local function id_write_line(card)
  return card.line
end

--- Write card IDs back into raw file lines for cards that lack them.
--- Works bottom-up to avoid shifting line numbers.
---
--- @param file_lines string[] the raw file lines (mutable)
--- @param cards table[] parsed cards (some may have id=nil)
--- @param store table|nil storage backend for collision checking
--- @return string[] ids list of newly generated IDs
local function write_ids_back(file_lines, cards, store)
  -- Collect cards that need IDs, sorted by line number descending
  local needs_id = {}
  for _, card in ipairs(cards) do
    if card.id == nil then
      needs_id[#needs_id + 1] = card
    end
  end

  if #needs_id == 0 then
    return {}
  end

  -- Sort descending by line number (bottom-up write)
  table.sort(needs_id, function(a, b) return a.line > b.line end)

  local new_ids = {}
  for _, card in ipairs(needs_id) do
    local id = utils.generate_id()
    -- Check for collision with existing store IDs
    if store then
      for _ = 1, 10 do
        if not store:get_card(id) then break end
        id = utils.generate_id()
      end
    end
    local line_num = id_write_line(card)
    local comment = utils.format_card_id(id)

    if line_num >= 1 and line_num <= #file_lines then
      -- Append the ID comment to the end of the line
      file_lines[line_num] = file_lines[line_num] .. " " .. comment
    end

    new_ids[#new_ids + 1] = id
  end

  return new_ids
end

--- Trigger buffer reload for any open buffers showing this file.
--- Guarded: only runs when vim.api is available (inside Neovim).
--- @param file_path string absolute path to the file
local function reload_buffers(file_path)
  -- Guard: only call when inside Neovim
  if not vim or not vim.api or not vim.api.nvim_list_bufs then
    return
  end

  -- Schedule to avoid issues with event loops
  vim.schedule(function()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) then
        local buf_name = vim.api.nvim_buf_get_name(bufnr)
        if buf_name == file_path then
          vim.api.nvim_buf_call(bufnr, function()
            vim.cmd("checktime")
          end)
        end
      end
    end
  end)
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Scan a single file: parse cards, write IDs back for cards without them,
--- upsert all cards to storage, and detect per-file orphans.
---
--- @param file_path string absolute path to the markdown file
--- @param store table storage backend instance
--- @param scan_root string the scan root directory (for relative path computation)
--- @return table result { cards_found, cards_new, ids_written, errors, card_ids }
function M.scan_file(file_path, store, scan_root)
  local result = {
    cards_found = 0,
    cards_new = 0,
    cards_updated = 0,
    ids_written = 0,
    errors = {},
    card_ids = {},
  }

  -- Read file content
  local content, read_err = utils.read_file(file_path)
  if not content then
    result.errors[#result.errors + 1] = {
      file = file_path,
      message = "Failed to read file: " .. (read_err or "unknown error"),
    }
    return result
  end

  -- Compute relative path for the parser
  local rel_path = utils.relative_path(file_path, scan_root)

  -- First parse: identify cards and which need IDs
  local cards, parse_errors = parser.parse(rel_path, content, scan_root)

  -- Collect parse errors into result
  for _, err in ipairs(parse_errors) do
    result.errors[#result.errors + 1] = {
      file = file_path,
      line = err.line,
      message = err.message,
    }
  end

  -- Write IDs back for cards without them
  local file_lines = utils.lines(content)
  local new_ids = write_ids_back(file_lines, cards, store)

  if #new_ids > 0 then
    -- Write modified content back to file, preserving trailing newline
    local new_content = utils.join_lines(file_lines)
    if content:sub(-1) == "\n" then
      new_content = new_content .. "\n"
    end
    local ok, write_err = utils.write_file(file_path, new_content)
    if not ok then
      result.errors[#result.errors + 1] = {
        file = file_path,
        message = "Failed to write IDs: " .. (write_err or "unknown error"),
      }
      return result
    end

    result.ids_written = #new_ids

    -- Re-parse the updated file so all cards now have IDs
    content = new_content
    rel_path = utils.relative_path(file_path, scan_root)
    cards, parse_errors = parser.parse(rel_path, content, scan_root)

    -- Collect any new parse errors (shouldn't happen, but be safe)
    for _, err in ipairs(parse_errors) do
      result.errors[#result.errors + 1] = {
        file = file_path,
        line = err.line,
        message = err.message,
      }
    end

    -- Reload open buffers
    reload_buffers(file_path)
  end

  result.cards_found = #cards

  -- Build set of found card IDs for this file
  local found_ids = {}
  for _, card in ipairs(cards) do
    if card.id then
      found_ids[card.id] = true
      result.card_ids[#result.card_ids + 1] = card.id
    end
  end

  -- Upsert all cards to storage, tracking new vs updated
  for _, card in ipairs(cards) do
    if card.id then
      local existing = store:get_card(card.id)
      store:upsert_card({
        id = card.id,
        file_path = rel_path,
        line = card.line,
        front = card.front,
        back = card.back,
        reversible = card.reversible,
        suspended = card.suspended,
        tags = card.tags,
        note = card.note,
      })
      if existing then
        result.cards_updated = result.cards_updated + 1
      else
        result.cards_new = result.cards_new + 1
      end
    end
  end

  -- Per-file orphan detection: check stored cards for this file_path
  local stored_cards = store:get_cards_by_file(rel_path)
  for _, stored in ipairs(stored_cards) do
    if stored.active and not found_ids[stored.id] then
      store:mark_lost(stored.id)
    end
  end

  return result
end

--- Mark all active cards whose IDs are NOT in the found set as lost.
--- This is for global orphan detection after scanning all directories.
---
--- @param store table storage backend instance
--- @param found_ids table set of card IDs found during scan { [id]=true }
--- @return number count number of cards newly marked as lost
function M.mark_orphans(store, found_ids)
  local count = 0
  local all_cards = store:get_all_cards()
  for _, card in ipairs(all_cards) do
    if card.active and not found_ids[card.id] then
      store:mark_lost(card.id)
      count = count + 1
    end
  end
  return count
end

--- List markdown files in a directory, respecting file_patterns and ignore_patterns.
--- Uses plenary.scandir for recursive directory walking.
---
--- @param dir string directory to scan
--- @param config table config module (or mock with options.file_patterns, should_ignore)
--- @return string[] list of absolute file paths
function M.find_files(dir, config)
  local scan = require("plenary.scandir")

  -- Build search pattern from file_patterns
  -- Convert glob patterns like "*.md" to lua patterns like "%.md$"
  local search_patterns = {}
  local file_patterns = config.options and config.options.file_patterns or { "*.md" }
  for _, pat in ipairs(file_patterns) do
    -- Convert simple glob to regex-ish pattern for scandir
    -- "*.md" -> "%.md$", "*.markdown" -> "%.markdown$"
    local ext = pat:match("^%*(.+)$")
    if ext then
      search_patterns[#search_patterns + 1] = ext:gsub("%.", "%%.") .. "$"
    end
  end

  -- Scan once per pattern and merge results (Lua patterns don't support |)
  local files_set = {}
  local files = {}
  for _, pattern in ipairs(search_patterns) do
    local found = scan.scan_dir(dir, {
      hidden = false,
      depth = 50,
      search_pattern = pattern,
    })
    for _, f in ipairs(found) do
      if not files_set[f] then
        files_set[f] = true
        files[#files + 1] = f
      end
    end
  end

  -- Filter out ignored files
  local result = {}
  for _, file in ipairs(files) do
    if not config.should_ignore or not config.should_ignore(file) then
      result[#result + 1] = file
    end
  end

  return result
end

--- Scan all configured directories for flashcards.
--- Writes IDs back, upserts cards, and detects orphans globally.
---
--- @param dirs string[] list of directory paths to scan
--- @param store table storage backend instance
--- @param config table config module (or mock)
--- @return table report { files_scanned, cards_found, cards_new, cards_updated, orphans_found, errors }
function M.scan(dirs, store, config)
  local report = {
    files_scanned = 0,
    cards_found = 0,
    cards_new = 0,
    cards_updated = 0,
    orphans_found = 0,
    errors = {},
  }

  -- Collect all found card IDs across all files
  local all_found_ids = {}

  for _, dir in ipairs(dirs) do
    local files = M.find_files(dir, config)

    for _, file_path in ipairs(files) do
      report.files_scanned = report.files_scanned + 1

      local file_result = M.scan_file(file_path, store, dir)

      report.cards_found = report.cards_found + file_result.cards_found
      report.cards_new = report.cards_new + (file_result.cards_new or 0)
      report.cards_updated = report.cards_updated + (file_result.cards_updated or 0)

      -- Collect found IDs for global orphan detection
      for _, id in ipairs(file_result.card_ids) do
        all_found_ids[id] = true
      end

      -- Accumulate errors
      for _, err in ipairs(file_result.errors) do
        report.errors[#report.errors + 1] = err
      end
    end
  end

  -- Global orphan detection
  report.orphans_found = M.mark_orphans(store, all_found_ids)

  -- Save storage after full scan
  store:save()

  return report
end

return M
