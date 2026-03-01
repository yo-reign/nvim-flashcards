--- JSON file storage backend for nvim-flashcards.
--- Stores all card data, review history, and statistics in a single JSON file.
--- @module flashcards.storage.json
local utils = require("flashcards.utils")

local M = {}
local JsonStore = {}
JsonStore.__index = JsonStore

-- ============================================================================
-- Default State
-- ============================================================================

local DEFAULT_STATE = {
  status = "new",
  stability = 0,
  difficulty = 0,
  due_date = nil,
  last_review = nil,
  reps = 0,
  lapses = 0,
  learning_step = 0,
  elapsed_days = 0,
  scheduled_days = 0,
}

-- ============================================================================
-- Constructor
-- ============================================================================

--- Create a new JSON storage backend.
--- @param path string file path for the JSON storage file
--- @return table storage instance
function M.new(path)
  local self = setmetatable({}, JsonStore)
  self.path = path
  self.data = nil
  return self
end

-- ============================================================================
-- Internal Helpers
-- ============================================================================

--- Create empty data structure.
--- @return table
local function empty_data()
  return {
    cards = {},
    reviews = {},
    daily_stats = {},
  }
end

--- Check if a card's tag list matches a query tag (with hierarchical matching).
--- Tag "math" matches tags "math" and "math/algebra" and "math/algebra/linear".
--- Tag "math/algebra" matches "math/algebra" and "math/algebra/linear".
--- Does NOT match "mathematics" (must be exact or have "/" after).
--- @param card_tags string[] the card's tags
--- @param query_tag string the tag to match against
--- @return boolean
local function matches_tag(card_tags, query_tag)
  local prefix = query_tag .. "/"
  for _, tag in ipairs(card_tags) do
    if tag == query_tag or tag:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

--- Build a card table suitable for external consumption (includes id from key).
--- @param id string card id
--- @param entry table internal card data
--- @return table
local function build_card(id, entry)
  return {
    id = id,
    file_path = entry.file_path,
    line = entry.line,
    front = entry.front,
    back = entry.back,
    reversible = entry.reversible or false,
    suspended = entry.suspended or false,
    active = entry.active,
    tags = entry.tags or {},
    note = entry.note,
    state = utils.deep_copy(entry.state),
    created_at = entry.created_at,
    updated_at = entry.updated_at,
    lost_at = entry.lost_at,
  }
end

-- ============================================================================
-- Initialization / Persistence
-- ============================================================================

--- Load data from disk, or create empty store if file does not exist.
function JsonStore:init()
  local content = utils.read_file(self.path)
  if content and #content > 0 then
    local ok, decoded = pcall(vim.fn.json_decode, content)
    if ok and type(decoded) == "table" then
      self.data = decoded
      -- Ensure required top-level keys exist
      self.data.cards = self.data.cards or {}
      self.data.reviews = self.data.reviews or {}
      self.data.daily_stats = self.data.daily_stats or {}
    else
      self.data = empty_data()
    end
  else
    self.data = empty_data()
  end
end

--- Write current data to the JSON file on disk.
function JsonStore:save()
  if not self.data then
    return
  end
  local encoded = vim.fn.json_encode(self.data)
  utils.write_file(self.path, encoded)
end

--- Save data and clear in-memory store.
function JsonStore:close()
  self:save()
  self.data = nil
end

-- ============================================================================
-- Card Operations
-- ============================================================================

--- Insert or update a card. On re-upsert: update content fields, set active=true,
--- preserve existing FSRS state.
--- @param card table { id, file_path, line, front, back, reversible, suspended, tags, note }
function JsonStore:upsert_card(card)
  local now = utils.now()
  local existing = self.data.cards[card.id]

  if existing then
    -- Update content fields
    existing.file_path = card.file_path
    existing.line = card.line
    existing.front = card.front
    existing.back = card.back
    existing.reversible = card.reversible or false
    existing.suspended = card.suspended or false
    existing.tags = card.tags or {}
    existing.note = card.note
    existing.active = true
    existing.lost_at = nil
    existing.updated_at = now
  else
    -- New card
    self.data.cards[card.id] = {
      file_path = card.file_path,
      line = card.line,
      front = card.front,
      back = card.back,
      reversible = card.reversible or false,
      suspended = card.suspended or false,
      active = true,
      tags = card.tags or {},
      note = card.note,
      state = utils.deep_copy(DEFAULT_STATE),
      created_at = now,
      updated_at = now,
    }
  end
end

--- Get a single card by ID. Returns nil if not found.
--- @param id string card ID
--- @return table|nil card
function JsonStore:get_card(id)
  local entry = self.data.cards[id]
  if not entry then
    return nil
  end
  return build_card(id, entry)
end

--- Get all active cards.
--- @return table[] list of card tables
function JsonStore:get_all_cards()
  local result = {}
  for id, entry in pairs(self.data.cards) do
    if entry.active then
      result[#result + 1] = build_card(id, entry)
    end
  end
  return result
end

--- Get active cards for a specific file path.
--- @param path string file path to filter by
--- @return table[] list of card tables
function JsonStore:get_cards_by_file(path)
  local result = {}
  for id, entry in pairs(self.data.cards) do
    if entry.active and entry.file_path == path then
      result[#result + 1] = build_card(id, entry)
    end
  end
  return result
end

-- ============================================================================
-- Orphan Management
-- ============================================================================

--- Mark a card as lost (inactive). Sets active=false and records lost_at timestamp.
--- @param id string card ID
function JsonStore:mark_lost(id)
  local entry = self.data.cards[id]
  if entry then
    entry.active = false
    entry.lost_at = utils.now()
  end
end

--- Get all inactive (orphaned) cards.
--- @return table[] list of card tables
function JsonStore:get_orphaned_cards()
  local result = {}
  for id, entry in pairs(self.data.cards) do
    if not entry.active then
      result[#result + 1] = build_card(id, entry)
    end
  end
  return result
end

--- Permanently delete a card and all its reviews.
--- @param id string card ID
function JsonStore:delete_card(id)
  self.data.cards[id] = nil
  -- Remove associated reviews
  local kept = {}
  for _, review in ipairs(self.data.reviews) do
    if review.card_id ~= id then
      kept[#kept + 1] = review
    end
  end
  self.data.reviews = kept
end

--- Permanently remove all inactive cards.
function JsonStore:delete_all_orphans()
  local to_delete = {}
  for id, entry in pairs(self.data.cards) do
    if not entry.active then
      to_delete[#to_delete + 1] = id
    end
  end
  for _, id in ipairs(to_delete) do
    self:delete_card(id)
  end
end

-- ============================================================================
-- State Operations
-- ============================================================================

--- Get the FSRS state for a card. Returns nil if card does not exist.
--- @param id string card ID
--- @return table|nil state
function JsonStore:get_card_state(id)
  local entry = self.data.cards[id]
  if not entry then
    return nil
  end
  return utils.deep_copy(entry.state)
end

--- Merge updates into a card's FSRS state.
--- @param id string card ID
--- @param updates table partial state fields to merge
function JsonStore:update_card_state(id, updates)
  local entry = self.data.cards[id]
  if not entry or not entry.state then
    return
  end
  for k, v in pairs(updates) do
    entry.state[k] = v
  end
  entry.updated_at = utils.now()
end

-- ============================================================================
-- Due Cards
-- ============================================================================

--- Get cards that are due for review.
--- A card is due if: status="new" OR (due_date <= now).
--- Excludes suspended and inactive cards.
--- @param tag string|nil optional tag filter (hierarchical matching)
--- @return table[] list of card tables
function JsonStore:get_due_cards(tag)
  local now = utils.now()
  local result = {}
  for id, entry in pairs(self.data.cards) do
    if entry.active and not entry.suspended then
      local state = entry.state
      local is_due = state.status == "new"
        or (state.due_date and state.due_date <= now)
      if is_due then
        if not tag or matches_tag(entry.tags, tag) then
          result[#result + 1] = build_card(id, entry)
        end
      end
    end
  end
  return result
end

--- Get cards with status="new", active, not suspended.
--- @param tag string|nil optional tag filter (hierarchical matching)
--- @return table[] list of card tables
function JsonStore:get_new_cards(tag)
  local result = {}
  for id, entry in pairs(self.data.cards) do
    if entry.active and not entry.suspended and entry.state.status == "new" then
      if not tag or matches_tag(entry.tags, tag) then
        result[#result + 1] = build_card(id, entry)
      end
    end
  end
  return result
end

-- ============================================================================
-- Tags
-- ============================================================================

--- Get all tags with their card counts. Only counts active, non-suspended cards.
--- @return table[] list of { tag=string, count=number }
function JsonStore:get_all_tags()
  local counts = {}
  for _, entry in pairs(self.data.cards) do
    if entry.active and not entry.suspended then
      for _, tag in ipairs(entry.tags or {}) do
        counts[tag] = (counts[tag] or 0) + 1
      end
    end
  end
  local result = {}
  for tag, count in pairs(counts) do
    result[#result + 1] = { tag = tag, count = count }
  end
  table.sort(result, function(a, b) return a.tag < b.tag end)
  return result
end

--- Get active cards matching a tag (hierarchical: "math" matches "math" and "math/*").
--- @param tag string tag to filter by
--- @return table[] list of card tables
function JsonStore:get_cards_by_tag(tag)
  local result = {}
  for id, entry in pairs(self.data.cards) do
    if entry.active and matches_tag(entry.tags or {}, tag) then
      result[#result + 1] = build_card(id, entry)
    end
  end
  return result
end

-- ============================================================================
-- Reviews
-- ============================================================================

--- Record a review.
--- @param review table { card_id, rating, reviewed_at, elapsed_ms, state_before, state_after }
function JsonStore:add_review(review)
  self.data.reviews[#self.data.reviews + 1] = {
    card_id = review.card_id,
    rating = review.rating,
    reviewed_at = review.reviewed_at,
    elapsed_ms = review.elapsed_ms,
    state_before = review.state_before,
    state_after = review.state_after,
  }

  -- Update daily_stats
  local date = utils.format_date(review.reviewed_at)
  if not self.data.daily_stats[date] then
    self.data.daily_stats[date] = { new_count = 0, review_count = 0 }
  end
  local day = self.data.daily_stats[date]
  if review.state_before == "new" then
    day.new_count = day.new_count + 1
  else
    day.review_count = day.review_count + 1
  end
end

--- Get all reviews for a card.
--- @param card_id string card ID
--- @return table[] list of review tables
function JsonStore:get_reviews(card_id)
  local result = {}
  for _, review in ipairs(self.data.reviews) do
    if review.card_id == card_id then
      result[#result + 1] = utils.deep_copy(review)
    end
  end
  return result
end

-- ============================================================================
-- Statistics
-- ============================================================================

--- Count active cards by FSRS state.
--- @return table { new=N, learning=N, review=N, relearning=N }
function JsonStore:count_by_state()
  local counts = { new = 0, learning = 0, review = 0, relearning = 0 }
  for _, entry in pairs(self.data.cards) do
    if entry.active then
      local status = entry.state.status
      if counts[status] ~= nil then
        counts[status] = counts[status] + 1
      end
    end
  end
  return counts
end

--- Count cards currently due for review.
--- @return table { total=N, new=N, review=N, learning=N }
function JsonStore:count_due()
  local now = utils.now()
  local counts = { total = 0, new = 0, review = 0, learning = 0 }
  for _, entry in pairs(self.data.cards) do
    if entry.active and not entry.suspended then
      local state = entry.state
      local is_due = state.status == "new"
        or (state.due_date and state.due_date <= now)
      if is_due then
        counts.total = counts.total + 1
        if state.status == "new" then
          counts.new = counts.new + 1
        elseif state.status == "review" or state.status == "relearning" then
          counts.review = counts.review + 1
        elseif state.status == "learning" then
          counts.learning = counts.learning + 1
        end
      end
    end
  end
  return counts
end

--- Get full statistics.
--- @return table stats
function JsonStore:get_stats()
  local state_counts = self:count_by_state()
  local due_counts = self:count_due()
  local total_cards = 0
  for _, entry in pairs(self.data.cards) do
    if entry.active then
      total_cards = total_cards + 1
    end
  end

  local total_reviews = #self.data.reviews
  local correct_count = 0
  local total_time_ms = 0
  for _, review in ipairs(self.data.reviews) do
    if review.rating == 2 then
      correct_count = correct_count + 1
    end
    total_time_ms = total_time_ms + (review.elapsed_ms or 0)
  end

  local retention_rate = 0
  if total_reviews > 0 then
    retention_rate = correct_count / total_reviews
  end

  local avg_time_ms = 0
  if total_reviews > 0 then
    avg_time_ms = math.floor(total_time_ms / total_reviews)
  end

  -- Streak: count consecutive days with reviews going back from today
  local streak = 0
  local today = utils.now()
  local day_ts = utils.start_of_day(today)
  while true do
    local date = utils.format_date(day_ts)
    if self.data.daily_stats[date] then
      local day_data = self.data.daily_stats[date]
      if (day_data.new_count or 0) + (day_data.review_count or 0) > 0 then
        streak = streak + 1
        day_ts = day_ts - 86400
      else
        break
      end
    else
      break
    end
  end

  return {
    total_cards = total_cards,
    by_state = state_counts,
    due = due_counts,
    total_reviews = total_reviews,
    retention_rate = retention_rate,
    streak = streak,
    avg_time_ms = avg_time_ms,
  }
end

--- Get daily statistics for the last N days.
--- @param days number number of days to look back
--- @return table[] array of { date=string, new_count=N, review_count=N }
function JsonStore:get_daily_stats(days)
  local result = {}
  local now = utils.now()
  for i = 0, days - 1 do
    local day_ts = utils.start_of_day(now) - (i * 86400)
    local date = utils.format_date(day_ts)
    local stats = self.data.daily_stats[date]
    result[#result + 1] = {
      date = date,
      new_count = stats and stats.new_count or 0,
      review_count = stats and stats.review_count or 0,
    }
  end
  return result
end

return M
