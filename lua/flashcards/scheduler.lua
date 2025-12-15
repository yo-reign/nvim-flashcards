-- Review scheduler for nvim-flashcards
-- Coordinates card selection and review sessions

local M = {}

local config = require("flashcards.config")
local db = require("flashcards.db")
local fsrs = require("flashcards.fsrs")
local utils = require("flashcards.utils")

--- Session state
---@class Session
---@field cards table Queue of cards to review
---@field current_index integer Current position in queue
---@field start_time integer Session start timestamp
---@field card_start_time integer Current card start time
---@field reviews table Completed reviews this session
---@field stats table Session statistics
local Session = {}
Session.__index = Session

--- Create a new review session
---@param opts table|nil Options {tag, limit, include_new}
---@return Session
function M.new_session(opts)
    opts = opts or {}

    local self = setmetatable({}, Session)
    self.cards = {}
    self.current_index = 0
    self.start_time = utils.now()
    self.card_start_time = nil
    self.reviews = {}
    self.stats = {
        total = 0,
        new = 0,
        learning = 0,
        review = 0,
        wrong = 0,
        correct = 0,
    }
    self.undo_stack = {}
    self.tag_filter = opts.tag

    -- Load cards
    self:load_cards(opts)

    return self
end

--- Load cards for the session
---@param opts table Options
function Session:load_cards(opts)
    local session_config = config.options.session
    local now = utils.now()

    -- Get due cards
    local due_cards = db.get_due_cards({
        tag = opts.tag,
        limit = opts.limit or session_config.max_cards,
    })

    -- Separate by state for ordering
    local new_cards = {}
    local learning_cards = {}
    local review_cards = {}

    for _, card in ipairs(due_cards) do
        if card.state == fsrs.State.New then
            table.insert(new_cards, card)
        elseif card.state == fsrs.State.Learning or card.state == fsrs.State.Relearning then
            table.insert(learning_cards, card)
        else
            table.insert(review_cards, card)
        end
    end

    -- Apply new card limit
    local new_limit = session_config.new_cards_per_day
    if new_limit and #new_cards > new_limit then
        -- Check how many new cards we've already done today
        local today = os.date("%Y-%m-%d")
        local daily_stats = db.get_daily_stats(today, today)
        local done_today = daily_stats[1] and daily_stats[1].new_count or 0
        local remaining = math.max(0, new_limit - done_today)

        -- Trim new cards to remaining limit
        local trimmed_new = {}
        for i = 1, math.min(remaining, #new_cards) do
            table.insert(trimmed_new, new_cards[i])
        end
        new_cards = trimmed_new
    end

    -- Build queue: learning first (need frequent review), then interleave new and review
    self.cards = {}

    -- Add all learning cards first
    for _, card in ipairs(learning_cards) do
        table.insert(self.cards, card)
    end

    -- Interleave new and review cards
    local new_idx, review_idx = 1, 1
    local new_ratio = 0.3 -- Show 1 new card for every ~3 review cards

    while new_idx <= #new_cards or review_idx <= #review_cards do
        -- Add review cards
        local add_review = review_idx <= #review_cards and
            (new_idx > #new_cards or math.random() > new_ratio)

        if add_review then
            table.insert(self.cards, review_cards[review_idx])
            review_idx = review_idx + 1
        elseif new_idx <= #new_cards then
            table.insert(self.cards, new_cards[new_idx])
            new_idx = new_idx + 1
        end
    end

    -- Update stats
    self.stats.total = #self.cards
    self.stats.new = #new_cards
    self.stats.learning = #learning_cards
    self.stats.review = #review_cards
end

--- Get current card
---@return table|nil Current card
function Session:current_card()
    if self.current_index < 1 or self.current_index > #self.cards then
        return nil
    end
    return self.cards[self.current_index]
end

--- Move to next card
---@return table|nil Next card
function Session:next_card()
    self.current_index = self.current_index + 1
    self.card_start_time = utils.now()

    return self:current_card()
end

--- Check if session has more cards
---@return boolean True if more cards available
function Session:has_more()
    return self.current_index < #self.cards
end

--- Get remaining count
---@return integer Remaining cards
function Session:remaining()
    return math.max(0, #self.cards - self.current_index)
end

--- Get progress fraction
---@return number Progress (0-1)
function Session:progress()
    if #self.cards == 0 then
        return 1
    end
    return self.current_index / #self.cards
end

--- Get elapsed time in seconds
---@return integer Seconds
function Session:elapsed_time()
    return utils.now() - self.start_time
end

--- Format elapsed time as string
---@return string Formatted time
function Session:elapsed_time_str()
    local elapsed = self:elapsed_time()
    local minutes = math.floor(elapsed / 60)
    local seconds = elapsed % 60
    return string.format("%d:%02d", minutes, seconds)
end

--- Answer the current card
---@param rating integer Rating (1-4)
---@return table|nil Updated state, or nil if no current card
function Session:answer(rating)
    local card = self:current_card()
    if not card then
        return nil
    end

    -- Calculate elapsed time for this card
    local elapsed_ms = 0
    if self.card_start_time then
        elapsed_ms = (utils.now() - self.card_start_time) * 1000
    end

    -- Get current state
    local current_state = {
        state = card.state,
        stability = card.stability,
        difficulty = card.difficulty,
        elapsed_days = card.elapsed_days,
        scheduled_days = card.scheduled_days,
        due_date = card.due_date,
        last_review = card.last_review,
        reps = card.reps,
        lapses = card.lapses,
    }

    -- Calculate new state
    local new_state, intervals = fsrs.schedule(current_state, rating)

    -- Save to undo stack
    table.insert(self.undo_stack, {
        card_id = card.id,
        old_state = current_state,
        rating = rating,
    })

    -- Update database
    db.update_card_state(card.id, new_state)

    -- Record review
    local review = {
        card_id = card.id,
        rating = rating,
        reviewed_at = utils.now(),
        elapsed_ms = elapsed_ms,
        stability_before = current_state.stability,
        stability_after = new_state.stability,
        difficulty_before = current_state.difficulty,
        difficulty_after = new_state.difficulty,
        state_before = current_state.state,
        state_after = new_state.state,
    }
    db.add_review(review)
    table.insert(self.reviews, review)

    -- Update session stats (binary: wrong/correct)
    local rating_names = { "wrong", "correct" }
    self.stats[rating_names[rating]] = self.stats[rating_names[rating]] + 1

    -- If card goes to learning/relearning, add it back to queue
    if new_state.state == fsrs.State.Learning or new_state.state == fsrs.State.Relearning then
        -- Update card in queue with new state
        card.state = new_state.state
        card.stability = new_state.stability
        card.difficulty = new_state.difficulty
        card.due_date = new_state.due_date

        -- Add to end of queue if due soon
        local minutes_until_due = (new_state.due_date - utils.now()) / 60
        if minutes_until_due < 30 then
            table.insert(self.cards, card)
        end
    end

    return new_state, intervals
end

--- Undo last answer
---@return boolean Success
function Session:undo()
    if #self.undo_stack == 0 then
        return false
    end

    local last = table.remove(self.undo_stack)

    -- Restore previous state
    db.update_card_state(last.card_id, last.old_state)

    -- Remove last review from session
    if #self.reviews > 0 then
        table.remove(self.reviews)
    end

    -- Update stats (binary: wrong/correct)
    local rating_names = { "wrong", "correct" }
    local stat_name = rating_names[last.rating]
    if stat_name and self.stats[stat_name] and self.stats[stat_name] > 0 then
        self.stats[stat_name] = self.stats[stat_name] - 1
    end

    -- Move back in queue
    self.current_index = math.max(0, self.current_index - 1)

    return true
end

--- Skip current card
function Session:skip()
    -- Move card to end of queue
    local card = self:current_card()
    if card then
        table.remove(self.cards, self.current_index)
        table.insert(self.cards, card)
        -- Don't increment index since we removed current
        self.current_index = self.current_index - 1
    end
end

--- Get session summary
---@return table Summary statistics
function Session:summary()
    local elapsed = self:elapsed_time()
    local total_reviews = #self.reviews

    return {
        total_cards = self.stats.total,
        reviewed = total_reviews,
        remaining = self:remaining(),
        wrong = self.stats.wrong,
        correct = self.stats.correct,
        elapsed_seconds = elapsed,
        elapsed_formatted = self:elapsed_time_str(),
        avg_seconds = total_reviews > 0 and (elapsed / total_reviews) or 0,
        retention_rate = total_reviews > 0
            and (self.stats.correct / total_reviews * 100)
            or 0,
    }
end

--- Preview intervals for current card
---@return table Map of rating -> interval info
function Session:preview_intervals()
    local card = self:current_card()
    if not card then
        return {}
    end

    local current_state = {
        state = card.state,
        stability = card.stability,
        difficulty = card.difficulty,
        elapsed_days = card.elapsed_days,
        scheduled_days = card.scheduled_days,
        due_date = card.due_date,
        last_review = card.last_review,
        reps = card.reps,
        lapses = card.lapses,
    }

    return fsrs.preview_intervals(current_state)
end

-- Export session constructor
M.Session = Session

--- Get quick stats for status line
---@return table Stats {due, new, learning, review}
function M.get_quick_stats()
    return db.count_due()
end

--- Check if any cards are due
---@return boolean True if cards are due
function M.has_due_cards()
    local stats = db.count_due()
    return (stats.total or 0) > 0
end

return M
