--- Session scheduler for nvim-flashcards.
--- Manages review sessions: queue building, card ordering, undo, skip,
--- and reversible card state tracking.
--- @module flashcards.scheduler
local M = {}

local utils = require("flashcards.utils")

-- ============================================================================
-- Session Class
-- ============================================================================

--- @class Session
--- @field store table storage backend instance
--- @field fsrs table FSRS scheduler instance
--- @field queue table[] ordered list of cards to review
--- @field current_idx number current position in queue (0 = not started)
--- @field reviews table[] review records for this session
--- @field reversed_map table<string, boolean> persisted reversed state per card_id
--- @field start_time number session start timestamp
--- @field tag string|nil optional tag filter
--- @field new_cards_limit number max new cards per session
local Session = {}
Session.__index = Session

-- ============================================================================
-- Constructor
-- ============================================================================

--- Create a new review session.
--- @param store table storage backend instance
--- @param fsrs table FSRS scheduler instance
--- @param opts table|nil options: { tag, new_cards_per_day }
--- @return Session
function M.new_session(store, fsrs, opts)
  opts = opts or {}
  local self = setmetatable({}, Session)
  self.store = store
  self.fsrs = fsrs
  self.queue = {}
  self.current_idx = 0
  self.reviews = {}
  self.reversed_map = {}
  self.start_time = utils.now()
  self.tag = opts.tag or nil
  self.new_cards_limit = opts.new_cards_per_day or 20
  return self
end

-- ============================================================================
-- Queue Building
-- ============================================================================

--- Build the review queue from due + new cards.
--- Queue order: learning/relearning cards first (sorted by due_date),
--- then interleaved new + review cards. New cards limited to new_cards_per_day.
function Session:load_cards()
  local due = self.store:get_due_cards(self.tag)

  -- Separate by state type
  local learning = {} -- learning + relearning (short intervals)
  local review = {}   -- review cards
  local new = {}      -- new cards

  for _, card in ipairs(due) do
    local state = card.state or self.store:get_card_state(card.id)
    local status = state.status or "new"

    if status == "learning" or status == "relearning" then
      table.insert(learning, card)
    elseif status == "new" then
      table.insert(new, card)
    else
      table.insert(review, card)
    end
  end

  -- Limit new cards
  if #new > self.new_cards_limit then
    local limited = {}
    for i = 1, self.new_cards_limit do
      limited[i] = new[i]
    end
    new = limited
  end

  -- Build queue
  self.queue = {}

  -- Learning cards sorted by due_date (earliest first)
  table.sort(learning, function(a, b)
    local a_due = (a.state and a.state.due_date) or 0
    local b_due = (b.state and b.state.due_date) or 0
    return a_due < b_due
  end)
  for _, card in ipairs(learning) do
    table.insert(self.queue, card)
  end

  -- Interleave new and review: alternate review, new
  local ni, ri = 1, 1
  while ni <= #new or ri <= #review do
    if ri <= #review then
      table.insert(self.queue, review[ri])
      ri = ri + 1
    end
    if ni <= #new then
      table.insert(self.queue, new[ni])
      ni = ni + 1
    end
  end
end

-- ============================================================================
-- Navigation
-- ============================================================================

--- Advance to the next card in the queue.
--- @return boolean true if there is a card to review, false if session is done
function Session:next_card()
  if self.current_idx < #self.queue then
    self.current_idx = self.current_idx + 1
    return true
  end
  return false
end

--- Get the current card and its reversed state.
--- For reversible cards, generates a random reversed state on first encounter.
--- @return table|nil card the current card, or nil if no current card
--- @return boolean is_reversed whether the card is shown reversed
function Session:current_card()
  if self.current_idx < 1 or self.current_idx > #self.queue then
    return nil, false
  end

  local card = self.queue[self.current_idx]
  if not card then
    return nil, false
  end

  -- Determine reversed state
  local is_reversed = false
  if card.reversible then
    if self.reversed_map[card.id] == nil then
      -- Generate randomly: 50% chance
      self.reversed_map[card.id] = math.random() < 0.5
    end
    is_reversed = self.reversed_map[card.id]
  else
    -- Non-reversible cards are never reversed
    self.reversed_map[card.id] = false
  end

  return card, is_reversed
end

-- ============================================================================
-- Answering
-- ============================================================================

--- Maximum interval (in days) for re-queuing learning cards.
local REQUEUE_THRESHOLD_DAYS = 30 / (24 * 60) -- 30 minutes in days

--- Answer the current card with a rating.
--- Schedules via FSRS, records review in session and store, updates card state,
--- and re-queues if the card is still in learning/relearning with a short interval.
--- @param rating number 1 (Wrong) or 2 (Correct)
function Session:answer(rating)
  if self.current_idx < 1 or self.current_idx > #self.queue then
    return
  end

  local card = self.queue[self.current_idx]
  if not card then
    return
  end

  local now = utils.now()

  -- Get current state from store
  local state_before = self.store:get_card_state(card.id)
  local status_before = state_before.status

  -- Schedule via FSRS
  local new_state, intervals = self.fsrs:schedule(state_before, rating, now)
  local status_after = new_state.status or new_state.state

  -- Normalize: FSRS may use .state or .status
  if new_state.state and not new_state.status then
    new_state.status = new_state.state
  end
  if new_state.status and not new_state.state then
    new_state.state = new_state.status
  end

  -- Determine if card was reversed
  local is_reversed = self.reversed_map[card.id] or false

  -- Record review in session
  local review_record = {
    card = card,
    state_before = utils.deep_copy(state_before),
    state_after = utils.deep_copy(new_state),
    rating = rating,
    elapsed_ms = 0, -- UI layer should set this; default to 0
    is_reversed = is_reversed,
    queue_position = self.current_idx,
  }
  table.insert(self.reviews, review_record)

  -- Record review in store
  self.store:add_review({
    card_id = card.id,
    rating = rating,
    reviewed_at = now,
    elapsed_ms = 0,
    state_before = status_before,
    state_after = status_after,
  })

  -- Update card state in store
  self.store:update_card_state(card.id, new_state)

  -- Re-queue if card is still in learning/relearning with short interval
  local final_status = new_state.status or new_state.state
  if (final_status == "learning" or final_status == "relearning")
    and intervals.days <= REQUEUE_THRESHOLD_DAYS then
    -- Insert after current position (not at the very end)
    local insert_pos = math.min(self.current_idx + 2, #self.queue + 1)
    table.insert(self.queue, insert_pos, card)
  end
end

-- ============================================================================
-- Undo
-- ============================================================================

--- Undo the last review. Restores card state in store and session.
--- @return boolean true if undo was successful, false if nothing to undo
function Session:undo()
  if #self.reviews == 0 then
    return false
  end

  -- Pop last review
  local last_review = table.remove(self.reviews)

  -- Restore card state in store
  self.store:update_card_state(last_review.card.id, last_review.state_before)

  -- Remove the last review from store
  -- (pop the last entry from the store's review log)
  if self.store._reviews and #self.store._reviews > 0 then
    table.remove(self.store._reviews)
  end

  -- Restore queue position: put the card back at the position it was answered from
  -- First, remove any re-queued copies of this card that were added by the answer
  local card_id = last_review.card.id
  local i = self.current_idx + 1
  while i <= #self.queue do
    if self.queue[i].id == card_id then
      table.remove(self.queue, i)
    else
      i = i + 1
    end
  end

  -- Move current_idx back to the card's original position
  self.current_idx = last_review.queue_position

  -- Ensure the card is at the current position
  if self.queue[self.current_idx] == nil or self.queue[self.current_idx].id ~= card_id then
    table.insert(self.queue, self.current_idx, last_review.card)
  end

  return true
end

-- ============================================================================
-- Skip
-- ============================================================================

--- Skip the current card, moving it to the end of the queue.
--- The reversed_map entry is preserved.
function Session:skip()
  if self.current_idx < 1 or self.current_idx > #self.queue then
    return
  end

  local card = table.remove(self.queue, self.current_idx)
  table.insert(self.queue, card)

  -- current_idx now points to the next card (because we removed from current position)
  -- Don't advance; the next card slid into the current position.
  -- But we need to stay at the same index since the queue shifted.
  -- Actually after removal, current_idx already points to the next card.
end

-- ============================================================================
-- Preview Intervals
-- ============================================================================

--- Preview the scheduling intervals for both rating options on the current card.
--- @return table|nil map of rating -> { days, formatted }
function Session:preview_intervals()
  if self.current_idx < 1 or self.current_idx > #self.queue then
    return nil
  end

  local card = self.queue[self.current_idx]
  if not card then
    return nil
  end

  local state = self.store:get_card_state(card.id)
  return self.fsrs:preview_intervals(state, utils.now())
end

-- ============================================================================
-- Summary
-- ============================================================================

--- Get a summary of the current session.
--- @return table summary { total, reviewed, correct, wrong, new_seen, elapsed, elapsed_formatted, retention_rate }
function Session:summary()
  local total = #self.queue
  local reviewed = #self.reviews
  local correct = 0
  local wrong = 0
  local new_seen = 0

  for _, rev in ipairs(self.reviews) do
    if rev.rating == 2 then
      correct = correct + 1
    else
      wrong = wrong + 1
    end
    if rev.state_before and rev.state_before.status == "new" then
      new_seen = new_seen + 1
    end
  end

  local elapsed = utils.now() - self.start_time
  local elapsed_minutes = math.floor(elapsed / 60)
  local elapsed_seconds = elapsed % 60
  local elapsed_formatted = string.format("%dm %ds", elapsed_minutes, elapsed_seconds)

  local retention_rate = 0
  if reviewed > 0 then
    retention_rate = correct / reviewed
  end

  return {
    total = total,
    reviewed = reviewed,
    correct = correct,
    wrong = wrong,
    new_seen = new_seen,
    elapsed = elapsed,
    elapsed_formatted = elapsed_formatted,
    retention_rate = retention_rate,
  }
end

return M
