--- Session scheduler for nvim-flashcards.
--- Manages review sessions: queue building, card ordering, undo, skip,
--- and reversible card state tracking.
--- @module flashcards.scheduler
local M = {}

local fsrs = require("flashcards.fsrs")
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
--- @field new_cards_limit number|false|nil max new cards per day; false/nil is unlimited
--- @field priority_card_id string|nil card to move to the front when it is available
--- @field deferred_new_count number new cards excluded by today's configured cap
--- @field pending_repeats table<string, table> future learning/relearning repeats keyed by card ID
--- @field next_pending_token number monotonically increasing pending-repeat generation
local Session = {}
Session.__index = Session

local function default_card_state()
  return {
    status = "new",
    stability = 0,
    difficulty = 0,
    reps = 0,
    lapses = 0,
    learning_step = 0,
    elapsed_days = 0,
    scheduled_days = 0,
  }
end

local function compare_cards(a, b)
  local a_due = (a.state and a.state.due_date) or 0
  local b_due = (b.state and b.state.due_date) or 0
  if a_due ~= b_due then
    return a_due < b_due
  end

  local a_file = a.file_path or ""
  local b_file = b.file_path or ""
  if a_file ~= b_file then
    return a_file < b_file
  end

  local a_line = a.line or 0
  local b_line = b.line or 0
  if a_line ~= b_line then
    return a_line < b_line
  end

  return (a.id or "") < (b.id or "")
end

-- ============================================================================
-- Constructor
-- ============================================================================

--- Create a new review session.
--- @param store table storage backend instance
--- @param fsrs table FSRS scheduler instance
--- @param opts table|nil options: { tag, new_cards_per_day, priority_card_id }
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
  self.new_cards_limit = opts.new_cards_per_day
  self.priority_card_id = opts.priority_card_id
  self.deferred_new_count = 0
  self.pending_repeats = {}
  self.next_pending_token = 0
  self.initial_count = 0
  return self
end

-- ============================================================================
-- Queue Building
-- ============================================================================

--- Build the review queue from due + new cards.
--- Queue order: learning/relearning cards first (sorted by due_date),
--- then interleaved new + review cards. New cards limited to new_cards_per_day.
function Session:load_cards()
  self.pending_repeats = {}
  local due, availability = self.store:get_due_cards(self.tag, self.new_cards_limit)
  availability = availability or {}
  self.deferred_new_count = availability.deferred_new or 0

  -- Separate by state type
  local learning = {} -- learning + relearning (short intervals)
  local review = {}   -- review cards
  local new = {}      -- new cards

  for _, card in ipairs(due) do
    local state = card.state or self.store:get_card_state(card.id) or {}
    local status = state.status or "new"

    if status == "learning" or status == "relearning" then
      table.insert(learning, card)
    elseif status == "new" then
      table.insert(new, card)
    else
      table.insert(review, card)
    end
  end

  -- The storage query applies the configured daily new-card policy so every
  -- caller (session, stats, and Telescope) shares the same availability rules.

  -- Build queue
  self.queue = {}

  -- Stable ordering within each bucket
  table.sort(learning, compare_cards)
  table.sort(review, compare_cards)
  table.sort(new, compare_cards)

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

  -- Telescope's Due picker can request that its selected, already-available
  -- card is shown first. Never inject a card excluded by due/tag/cap policy.
  if self.priority_card_id then
    for index, card in ipairs(self.queue) do
      if card.id == self.priority_card_id then
        table.remove(self.queue, index)
        table.insert(self.queue, 1, card)
        break
      end
    end
  end

  self.initial_count = #self.queue
end

-- ============================================================================
-- Due-aware learning repeats
-- ============================================================================

local REPEAT_SPACING_CARDS = 2

local function has_unprocessed_card(session, card_id)
  for index = session.current_idx + 1, #session.queue do
    if session.queue[index].id == card_id then
      return true
    end
  end
  return false
end

--- Release pending learning/relearning cards whose real due time has arrived.
--- Released cards are placed a couple of positions ahead when possible and
--- never duplicate an existing unprocessed occurrence.
--- @param now number|nil unix timestamp, defaults to utils.now()
--- @return table[] released pending entries
function Session:release_due_repeats(now)
  now = now or utils.now()
  local due = {}
  for card_id, entry in pairs(self.pending_repeats) do
    if entry.due_at <= now then
      due[#due + 1] = {
        card_id = card_id,
        card = entry.card,
        due_at = entry.due_at,
        token = entry.token,
      }
    end
  end
  table.sort(due, function(a, b)
    if a.due_at ~= b.due_at then
      return a.due_at < b.due_at
    end
    return a.card_id < b.card_id
  end)

  if #due == 0 then
    return {}
  end

  local old_queue_len = #self.queue
  if self.current_idx > old_queue_len then
    -- next_card() moved past the exhausted queue while waiting. Restore the
    -- insertion anchor so its next call selects the first released repeat.
    self.current_idx = old_queue_len
  end

  local base_insert_pos = math.min(
    self.current_idx + REPEAT_SPACING_CARDS + 1,
    #self.queue + 1
  )
  local last_insert_pos = base_insert_pos - 1
  local released = {}

  for _, entry in ipairs(due) do
    local current = self.pending_repeats[entry.card_id]
    if current and current.token == entry.token then
      if not has_unprocessed_card(self, entry.card_id) then
        local insert_pos = math.min(
          #self.queue + 1,
          math.max(base_insert_pos, last_insert_pos + 1)
        )
        table.insert(self.queue, insert_pos, entry.card)
        last_insert_pos = insert_pos
      end
      self.pending_repeats[entry.card_id] = nil
      released[#released + 1] = entry
    end
  end

  return released
end

--- Return the earliest future pending-repeat timestamp.
--- @return number|nil
function Session:next_pending_due()
  local earliest = nil
  for _, entry in pairs(self.pending_repeats) do
    if earliest == nil or entry.due_at < earliest then
      earliest = entry.due_at
    end
  end
  return earliest
end

--- Return whether the session is waiting on any learning/relearning repeats.
--- @return boolean
function Session:has_pending_repeats()
  return next(self.pending_repeats) ~= nil
end

--- Return the number of pending learning/relearning repeats.
--- @return number
function Session:pending_repeat_count()
  local count = 0
  for _ in pairs(self.pending_repeats) do
    count = count + 1
  end
  return count
end

--- Clear non-persisted session repeat tracking. Persisted due dates remain.
function Session:clear_pending_repeats()
  self.pending_repeats = {}
end

-- ============================================================================
-- Navigation
-- ============================================================================

--- Advance to the next card in the queue, releasing repeats that are now due.
--- @return boolean true if there is a card to review, false if none is currently due
function Session:next_card()
  self:release_due_repeats(utils.now())
  if self.current_idx < #self.queue then
    self.current_idx = self.current_idx + 1
    return true
  end

  -- Move past the queue end so current_card()/answer()/skip() cannot keep
  -- operating on the final card while the session completes or waits.
  self.current_idx = #self.queue + 1
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

--- Answer the current card with a rating.
--- Schedules via FSRS, records review in session and store, updates card state,
--- and tracks learning/relearning repeats until their real due time arrives.
--- @param rating number 0 (Wrong/false) or 1 (Correct/true)
--- @param elapsed_ms number|nil time spent on this card in milliseconds
function Session:answer(rating, elapsed_ms)
  if self.current_idx < 1 or self.current_idx > #self.queue then
    return
  end

  local card = self.queue[self.current_idx]
  if not card then
    return
  end

  local now = utils.now()

  -- Get current state from store (with fallback for deleted cards)
  local state_before = self.store:get_card_state(card.id)
  if not state_before then
    state_before = default_card_state()
  end
  local status_before = state_before.status

  -- Schedule via FSRS
  local new_state, intervals = self.fsrs:schedule(state_before, rating, now)
  local status_after = new_state.status

  -- Determine if card was reversed
  local is_reversed = self.reversed_map[card.id] or false

  -- Prepare the in-memory session review, but only append it after durable
  -- persistence succeeds so a failed database write cannot desync the session.
  local review_record = {
    card = card,
    state_before = utils.deep_copy(state_before),
    state_after = utils.deep_copy(new_state),
    rating = rating,
    elapsed_ms = elapsed_ms or 0,
    is_reversed = is_reversed,
    queue_position = self.current_idx,
  }

  -- Record review and update card state atomically when the backend supports it.
  local persisted_review = {
    card_id = card.id,
    rating = rating,
    reviewed_at = now,
    elapsed_ms = elapsed_ms or 0,
    state_before = status_before,
    state_after = status_after,
  }
  local review_id
  if self.store.add_review_and_update_state then
    review_id = self.store:add_review_and_update_state(persisted_review, card.id, new_state)
  elseif self.store.with_transaction then
    self.store:with_transaction(function()
      review_id = self.store:add_review(persisted_review)
      self.store:update_card_state(card.id, new_state)
    end)
  else
    review_id = self.store:add_review(persisted_review)
    self.store:update_card_state(card.id, new_state)
  end

  review_record.review_id = review_id

  local final_status = new_state.status
  local due_at = new_state.due_date or utils.add_days(now, intervals.days)
  self.pending_repeats[card.id] = nil
  if final_status == "learning" or final_status == "relearning" then
    self.next_pending_token = self.next_pending_token + 1
    local token = self.next_pending_token
    self.pending_repeats[card.id] = {
      card = card,
      due_at = due_at,
      token = token,
    }
    review_record.pending_token = token
  end

  table.insert(self.reviews, review_record)
  local released = self:release_due_repeats(now)
  local requeued = false
  for _, entry in ipairs(released) do
    if entry.card_id == card.id and entry.token == review_record.pending_token then
      requeued = true
      break
    end
  end
  local pending = self.pending_repeats[card.id]
  local deferred = pending ~= nil and pending.token == review_record.pending_token

  return {
    state = new_state,
    intervals = intervals,
    due_at = due_at,
    deferred = deferred,
    requeued = requeued,
  }
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

  local last_review = self.reviews[#self.reviews]

  -- Restore card state and remove the persisted review atomically when possible.
  local function undo_persisted_review()
    if self.store.remove_review and last_review.review_id then
      local removed = self.store:remove_review(last_review.review_id, last_review.card.id)
      if not removed then
        error("flashcards: persisted review for undo was not found")
      end
    elseif self.store.remove_last_review then
      self.store:remove_last_review()
    end
    self.store:update_card_state(last_review.card.id, last_review.state_before)
  end

  if self.store.with_transaction then
    self.store:with_transaction(undo_persisted_review)
  else
    undo_persisted_review()
  end

  table.remove(self.reviews)

  local pending = self.pending_repeats[last_review.card.id]
  if pending and pending.token == last_review.pending_token then
    self.pending_repeats[last_review.card.id] = nil
  end

  -- Restore queue position: put the card back at the position it was answered from
  -- First, remove any re-queued copies of this card that were added by the answer
  -- Search from queue_position + 1 (not current_idx + 1) to catch copies inserted
  -- between the answered position and the current position after next_card()
  local card_id = last_review.card.id
  local i = last_review.queue_position + 1
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

  if #self.queue <= 1 then
    return
  end

  local removed_idx = self.current_idx
  local card = table.remove(self.queue, removed_idx)
  local wrapped = removed_idx > #self.queue
  table.insert(self.queue, card)

  -- After removal, current_idx points to next card in shifted queue.
  -- If we skipped last card, wrap to first remaining card instead of showing
  -- skipped card again immediately.
  if wrapped then
    self.current_idx = 1
  else
    self.current_idx = removed_idx
  end
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
  if not state then
    state = default_card_state()
  end
  return self.fsrs:preview_intervals(state, utils.now())
end

-- ============================================================================
-- Summary
-- ============================================================================

--- Get a summary of the current session.
--- @return table summary { total, reviewed, correct, wrong, new_seen, elapsed, elapsed_formatted, answer_accuracy }
function Session:summary()
  local total = self.initial_count > 0 and self.initial_count or #self.queue
  local reviewed = #self.reviews
  local correct = 0
  local wrong = 0
  local new_seen = 0

  for _, rev in ipairs(self.reviews) do
    if rev.rating == fsrs.Rating.Correct then
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

  local answer_accuracy = 0
  if reviewed > 0 then
    answer_accuracy = correct / reviewed
  end

  return {
    total = total,
    reviewed = reviewed,
    correct = correct,
    wrong = wrong,
    new_seen = new_seen,
    elapsed = elapsed,
    elapsed_formatted = elapsed_formatted,
    answer_accuracy = answer_accuracy,
    retention_rate = answer_accuracy, -- Deprecated compatibility alias.
  }
end

return M
