-- FSRS (Free Spaced Repetition Scheduler) Implementation
-- Simplified to binary rating (Wrong/Correct) with adjustable target correctness
-- Based on the open-source FSRS algorithm

local M = {}

local config = require("flashcards.config")
local utils = require("flashcards.utils")

-- Binary rating enum
M.Rating = {
    Wrong = 1,   -- Failed to recall
    Correct = 2, -- Successfully recalled
}

-- Card state enum
M.State = {
    New = "new",
    Learning = "learning",
    Review = "review",
    Relearning = "relearning",
}

--- Default FSRS parameters optimized for binary rating
M.DEFAULT_WEIGHTS = {
    -- Initial stability (days) for Wrong/Correct on new cards
    initial_stability_wrong = 0.5,
    initial_stability_correct = 3.0,

    -- Difficulty parameters
    initial_difficulty = 5.0,  -- Starting difficulty (1-10 scale)
    difficulty_decay = 0.3,    -- How much difficulty decreases on correct
    difficulty_growth = 0.5,   -- How much difficulty increases on wrong

    -- Stability growth factors
    stability_factor = 2.5,    -- Base growth multiplier for correct recalls
    difficulty_weight = 0.1,   -- How much difficulty affects stability growth

    -- Forgetting parameters
    forget_stability_factor = 0.3,  -- Stability retained after forgetting

    -- Learning steps (in minutes)
    learning_steps = { 1, 10, 60 },  -- 1min, 10min, 1hour
}

--- FSRS scheduler class
---@class FSRS
---@field weights table Algorithm weights
---@field target_correctness number Target correctness rate (e.g., 0.85 for 85%)
---@field maximum_interval number Maximum interval in days
---@field enable_fuzz boolean Whether to fuzz intervals
local FSRS = {}
FSRS.__index = FSRS

--- Create a new FSRS scheduler instance
---@param opts table|nil Options
---@return FSRS
function M.new(opts)
    opts = opts or {}
    local cfg = config.options.fsrs or {}

    local self = setmetatable({}, FSRS)
    self.weights = vim.tbl_deep_extend("force", M.DEFAULT_WEIGHTS, opts.weights or cfg.weights or {})
    self.target_correctness = opts.target_correctness or cfg.target_correctness or 0.85
    self.maximum_interval = opts.maximum_interval or cfg.maximum_interval or 365
    self.enable_fuzz = opts.enable_fuzz ~= false and cfg.enable_fuzz ~= false

    return self
end

--- Calculate initial stability based on rating
---@param rating integer Rating (1=Wrong, 2=Correct)
---@return number Initial stability in days
function FSRS:init_stability(rating)
    local w = self.weights
    if rating == M.Rating.Correct then
        return w.initial_stability_correct
    else
        return w.initial_stability_wrong
    end
end

--- Calculate initial difficulty
---@return number Initial difficulty (1-10)
function FSRS:init_difficulty()
    return self.weights.initial_difficulty
end

--- Calculate next difficulty after review
---@param d number Current difficulty
---@param rating integer Rating (1=Wrong, 2=Correct)
---@return number New difficulty (clamped 1-10)
function FSRS:next_difficulty(d, rating)
    local w = self.weights
    local new_d

    if rating == M.Rating.Correct then
        -- Decrease difficulty on correct answer
        new_d = d - w.difficulty_decay
    else
        -- Increase difficulty on wrong answer
        new_d = d + w.difficulty_growth
    end

    return math.min(10, math.max(1, new_d))
end

--- Calculate stability after successful recall
---@param d number Difficulty
---@param s number Current stability
---@param r number Retrievability
---@return number New stability
function FSRS:next_recall_stability(d, s, r)
    local w = self.weights

    -- Stability grows more when:
    -- - Current stability is lower (harder to remember items grow faster)
    -- - Difficulty is lower (easier items grow faster)
    -- - Retrievability was lower (successful recall at harder time = bigger boost)
    local difficulty_factor = 1 - (d - 1) * w.difficulty_weight / 9
    local retrievability_boost = 1 + (1 - r) * 0.5

    local new_stability = s * w.stability_factor * difficulty_factor * retrievability_boost

    return math.max(s + 1, new_stability)  -- Always grow by at least 1 day
end

--- Calculate stability after forgetting
---@param d number Difficulty
---@param s number Current stability
---@return number New stability
function FSRS:next_forget_stability(d, s)
    local w = self.weights
    -- Retain some stability based on previous performance
    local new_stability = s * w.forget_stability_factor
    return math.max(w.initial_stability_wrong, new_stability)
end

--- Calculate retrievability (probability of recall)
---@param elapsed_days number Days since last review
---@param stability number Card stability
---@return number Retrievability (0-1)
function FSRS:retrievability(elapsed_days, stability)
    if stability <= 0 then
        return 0
    end
    -- Exponential forgetting curve
    return math.exp(-elapsed_days / stability * math.log(2))
end

--- Calculate interval from stability and target correctness
---@param stability number Card stability
---@return number Interval in days
function FSRS:next_interval(stability)
    -- Interval where retrievability equals target_correctness
    -- R = exp(-t/S * ln(2))
    -- target = exp(-interval/S * ln(2))
    -- ln(target) = -interval/S * ln(2)
    -- interval = -S * ln(target) / ln(2)
    local interval = -stability * math.log(self.target_correctness) / math.log(2)
    return math.min(self.maximum_interval, math.max(1, math.floor(interval + 0.5)))
end

--- Add fuzz to interval to spread reviews
---@param interval number Base interval
---@return number Fuzzed interval
function FSRS:fuzz_interval(interval)
    if not self.enable_fuzz or interval < 2.5 then
        return interval
    end

    local fuzz_factor
    if interval < 7 then
        fuzz_factor = 0.15
    elseif interval < 30 then
        fuzz_factor = 0.1
    else
        fuzz_factor = 0.05
    end

    local min_ivl = math.max(2, math.floor(interval * (1 - fuzz_factor)))
    local max_ivl = math.floor(interval * (1 + fuzz_factor))

    return math.random(min_ivl, max_ivl)
end

--- Get learning step interval
---@param step integer Current learning step (0-indexed)
---@return number Interval in days (fraction)
function FSRS:learning_interval(step)
    local steps = self.weights.learning_steps
    local step_idx = math.min(step + 1, #steps)
    return steps[step_idx] / (24 * 60)  -- Convert minutes to days
end

--- Schedule next review for a card
---@param card_state table Current card state
---@param rating integer Rating (1=Wrong, 2=Correct)
---@param now integer|nil Current timestamp
---@return table New card state, table Scheduling info
function FSRS:schedule(card_state, rating, now)
    now = now or utils.now()

    local state = card_state.state or M.State.New
    local stability = card_state.stability or 0
    local difficulty = card_state.difficulty or self:init_difficulty()
    local last_review = card_state.last_review
    local reps = card_state.reps or 0
    local lapses = card_state.lapses or 0
    local learning_step = card_state.learning_step or 0

    -- Calculate elapsed days since last review
    local elapsed_days = 0
    if last_review then
        elapsed_days = utils.days_between(last_review, now)
    end

    -- Calculate retrievability
    local r = stability > 0 and self:retrievability(elapsed_days, stability) or 0

    -- New state calculation
    local new_state = {}
    local intervals = {}

    if state == M.State.New then
        -- First review of a new card
        new_state.reps = 1

        if rating == M.Rating.Correct then
            -- Correct on first try - start with good stability
            new_state.state = M.State.Learning
            new_state.stability = self:init_stability(rating)
            new_state.difficulty = self:init_difficulty()
            new_state.learning_step = 1
            new_state.lapses = 0
            intervals.days = self:learning_interval(1)
        else
            -- Wrong on first try
            new_state.state = M.State.Learning
            new_state.stability = self:init_stability(rating)
            new_state.difficulty = self:init_difficulty()
            new_state.learning_step = 0
            new_state.lapses = 1
            intervals.days = self:learning_interval(0)
        end

    elseif state == M.State.Learning or state == M.State.Relearning then
        new_state.reps = reps + 1

        if rating == M.Rating.Correct then
            -- Progress through learning steps
            local next_step = learning_step + 1
            local max_steps = #self.weights.learning_steps

            if next_step >= max_steps then
                -- Graduated to review
                new_state.state = M.State.Review
                new_state.stability = self:next_recall_stability(difficulty, stability, r)
                new_state.difficulty = self:next_difficulty(difficulty, rating)
                new_state.learning_step = 0
                new_state.lapses = lapses
                intervals.days = self:next_interval(new_state.stability)
            else
                -- Continue learning
                new_state.state = state
                new_state.stability = stability
                new_state.difficulty = difficulty
                new_state.learning_step = next_step
                new_state.lapses = lapses
                intervals.days = self:learning_interval(next_step)
            end
        else
            -- Wrong - reset learning progress
            new_state.state = state
            new_state.stability = self:init_stability(rating)
            new_state.difficulty = self:next_difficulty(difficulty, rating)
            new_state.learning_step = 0
            new_state.lapses = state == M.State.Relearning and lapses or lapses + 1
            intervals.days = self:learning_interval(0)
        end

    else -- Review state
        new_state.reps = reps + 1

        if rating == M.Rating.Correct then
            -- Successful review - increase stability
            new_state.state = M.State.Review
            new_state.stability = self:next_recall_stability(difficulty, stability, r)
            new_state.difficulty = self:next_difficulty(difficulty, rating)
            new_state.learning_step = 0
            new_state.lapses = lapses
            intervals.days = self:next_interval(new_state.stability)
        else
            -- Failed review - go to relearning
            new_state.state = M.State.Relearning
            new_state.stability = self:next_forget_stability(difficulty, stability)
            new_state.difficulty = self:next_difficulty(difficulty, rating)
            new_state.learning_step = 0
            new_state.lapses = lapses + 1
            intervals.days = self:learning_interval(0)
        end
    end

    -- Apply fuzz if in review state with interval >= 1 day
    if new_state.state == M.State.Review and intervals.days >= 1 then
        intervals.days = self:fuzz_interval(intervals.days)
    end

    -- Calculate due date
    new_state.elapsed_days = elapsed_days
    new_state.scheduled_days = intervals.days
    new_state.due_date = utils.add_days(now, intervals.days)
    new_state.last_review = now

    -- Format interval for display
    intervals.formatted = utils.format_interval(intervals.days)

    return new_state, intervals
end

--- Preview intervals for both ratings without updating state
---@param card_state table Current card state
---@param now integer|nil Current timestamp
---@return table Map of rating -> {days, formatted}
function FSRS:preview_intervals(card_state, now)
    local previews = {}

    for rating = 1, 2 do
        local _, intervals = self:schedule(card_state, rating, now)
        previews[rating] = intervals
    end

    return previews
end

--- Get rating name
---@param rating integer Rating (1-2)
---@return string Rating name
function M.rating_name(rating)
    local names = { "Wrong", "Correct" }
    return names[rating] or "Unknown"
end

--- Get state display name
---@param state string State
---@return string Display name
function M.state_name(state)
    local names = {
        new = "New",
        learning = "Learning",
        review = "Review",
        relearning = "Relearning",
    }
    return names[state] or state
end

-- Export scheduler constructor
M.FSRS = FSRS

-- Default instance (lazy-loaded)
local default_instance = nil

--- Get or create default scheduler instance
---@return FSRS
function M.get_default()
    if not default_instance then
        default_instance = M.new()
    end
    return default_instance
end

--- Reset default instance (call after config changes)
function M.reset_default()
    default_instance = nil
end

--- Schedule with default scheduler
---@param card_state table Card state
---@param rating integer Rating (1=Wrong, 2=Correct)
---@param now integer|nil Timestamp
---@return table, table New state, intervals
function M.schedule(card_state, rating, now)
    return M.get_default():schedule(card_state, rating, now)
end

--- Preview intervals with default scheduler
---@param card_state table Card state
---@param now integer|nil Timestamp
---@return table Previews
function M.preview_intervals(card_state, now)
    return M.get_default():preview_intervals(card_state, now)
end

return M
