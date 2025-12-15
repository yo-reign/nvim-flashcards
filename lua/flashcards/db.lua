-- SQLite database layer for nvim-flashcards
-- Stores card states, review history, and tags

local M = {}

local sqlite = require("sqlite")
local config = require("flashcards.config")
local utils = require("flashcards.utils")

-- Database connection (lazy-loaded)
local db = nil

--- Database schema
local schema = {
    cards = {
        id = { "text", primary = true },
        file_path = { "text", required = true },
        line_number = "integer",
        front = { "text", required = true },
        back = { "text", required = true },
        created_at = "integer",
        updated_at = "integer",
    },
    card_states = {
        card_id = { "text", primary = true, reference = "cards.id" },
        state = { "text", default = "new" }, -- new, learning, review, relearning
        stability = { "real", default = 0 },
        difficulty = { "real", default = 0 },
        elapsed_days = { "integer", default = 0 },
        scheduled_days = { "integer", default = 0 },
        due_date = "integer",
        last_review = "integer",
        reps = { "integer", default = 0 },
        lapses = { "integer", default = 0 },
        learning_step = { "integer", default = 0 }, -- Current step in learning phase
    },
    reviews = {
        id = true, -- Auto-increment primary key
        card_id = { "text", reference = "cards.id" },
        rating = "integer",
        reviewed_at = "integer",
        elapsed_ms = "integer",
        stability_before = "real",
        stability_after = "real",
        difficulty_before = "real",
        difficulty_after = "real",
        state_before = "text",
        state_after = "text",
    },
    card_tags = {
        card_id = { "text", reference = "cards.id" },
        tag = "text",
    },
    daily_stats = {
        date = { "text", primary = true }, -- YYYY-MM-DD
        new_count = { "integer", default = 0 },
        review_count = { "integer", default = 0 },
        wrong_count = { "integer", default = 0 },
        correct_count = { "integer", default = 0 },
        total_time_ms = { "integer", default = 0 },
    },
}

--- Initialize database connection
---@param dir string|nil Directory for database file
---@return sqlite.Database Database instance
function M.init(dir)
    local db_path = config.get_db_path(dir)

    -- Create directory if it doesn't exist
    local dir_path = vim.fn.fnamemodify(db_path, ":h")
    vim.fn.mkdir(dir_path, "p")

    db = sqlite({
        uri = db_path,
        cards = schema.cards,
        card_states = schema.card_states,
        reviews = schema.reviews,
        card_tags = schema.card_tags,
        daily_stats = schema.daily_stats,
    })

    -- Create indexes for performance (must be separate statements)
    pcall(function() db:execute("CREATE INDEX IF NOT EXISTS idx_cards_file ON cards(file_path)") end)
    pcall(function() db:execute("CREATE INDEX IF NOT EXISTS idx_states_due ON card_states(due_date)") end)
    pcall(function() db:execute("CREATE INDEX IF NOT EXISTS idx_states_state ON card_states(state)") end)
    pcall(function() db:execute("CREATE INDEX IF NOT EXISTS idx_tags_tag ON card_tags(tag)") end)
    pcall(function() db:execute("CREATE INDEX IF NOT EXISTS idx_tags_card ON card_tags(card_id)") end)
    pcall(function() db:execute("CREATE INDEX IF NOT EXISTS idx_reviews_card ON reviews(card_id)") end)

    return db
end

--- Get database connection (initializes if needed)
---@return sqlite.Database
function M.get()
    if not db then
        M.init()
    end
    return db
end

--- Close database connection
function M.close()
    if db then
        db:close()
        db = nil
    end
end

-- =============================================================================
-- Card Operations
-- =============================================================================

--- Insert or update a card
---@param card table Card data {id, file_path, line_number, front, back, tags}
---@return boolean Success
function M.upsert_card(card)
    local now = utils.now()
    local d = M.get()

    -- Check if card exists
    local existing = d.cards:where({ id = card.id }) or {}

    if #existing > 0 then
        -- Update existing card
        d.cards:update({
            where = { id = card.id },
            set = {
                file_path = card.file_path,
                line_number = card.line_number,
                front = card.front,
                back = card.back,
                updated_at = now,
            },
        })
    else
        -- Insert new card
        d.cards:insert({
            id = card.id,
            file_path = card.file_path,
            line_number = card.line_number,
            front = card.front,
            back = card.back,
            created_at = now,
            updated_at = now,
        })

        -- Create initial state
        d.card_states:insert({
            card_id = card.id,
            state = "new",
            stability = 0,
            difficulty = 0,
            elapsed_days = 0,
            scheduled_days = 0,
            due_date = now, -- Due immediately
            last_review = nil,
            reps = 0,
            lapses = 0,
        })
    end

    -- Update tags
    M.set_card_tags(card.id, card.tags or {})

    return true
end

--- Delete a card and all related data
---@param card_id string Card ID
---@return boolean Success
function M.delete_card(card_id)
    local d = M.get()

    d.card_tags:remove({ card_id = card_id })
    d.reviews:remove({ card_id = card_id })
    d.card_states:remove({ card_id = card_id })
    d.cards:remove({ id = card_id })

    return true
end

--- Get a card by ID
---@param card_id string Card ID
---@return table|nil Card with state
function M.get_card(card_id)
    local d = M.get()

    local cards = d.cards:where({ id = card_id }) or {}
    if #cards == 0 then
        return nil
    end

    local card = cards[1]

    -- Get state
    local states = d.card_states:where({ card_id = card_id }) or {}
    if #states > 0 then
        card.state = states[1]
    end

    -- Get tags
    card.tags = M.get_card_tags(card_id)

    return card
end

--- Get all cards
---@return table List of cards
function M.get_all_cards()
    local d = M.get()
    local result = d.cards:get()
    return result or {}
end

--- Get cards from a specific file
---@param file_path string File path
---@return table List of cards
function M.get_cards_by_file(file_path)
    local d = M.get()
    local result = d.cards:where({ file_path = file_path })
    return result or {}
end

--- Delete all cards from a specific file
---@param file_path string File path
---@return integer Number of deleted cards
function M.delete_cards_by_file(file_path)
    local d = M.get()
    local cards = M.get_cards_by_file(file_path)

    for _, card in ipairs(cards) do
        M.delete_card(card.id)
    end

    return #cards
end

-- =============================================================================
-- Card State Operations
-- =============================================================================

--- Get card state
---@param card_id string Card ID
---@return table|nil Card state
function M.get_card_state(card_id)
    local d = M.get()
    local states = d.card_states:where({ card_id = card_id })
    if states and #states > 0 then
        return states[1]
    end
    return nil
end

--- Update card state after review
---@param card_id string Card ID
---@param state table Updated state data
---@return boolean Success
function M.update_card_state(card_id, state)
    local d = M.get()

    d.card_states:update({
        where = { card_id = card_id },
        set = {
            state = state.state,
            stability = state.stability,
            difficulty = state.difficulty,
            elapsed_days = state.elapsed_days,
            scheduled_days = state.scheduled_days,
            due_date = state.due_date,
            last_review = state.last_review,
            reps = state.reps,
            lapses = state.lapses,
            learning_step = state.learning_step or 0,
        },
    })

    return true
end

--- Get due cards (for review)
---@param opts table|nil Options {limit, tag, state}
---@return table List of due cards with states
function M.get_due_cards(opts)
    opts = opts or {}
    local d = M.get()
    local now = utils.now()

    -- Build query parts
    local query = "SELECT c.*, cs.state, cs.stability, cs.difficulty, cs.elapsed_days, "
        .. "cs.scheduled_days, cs.due_date, cs.last_review, cs.reps, cs.lapses "
        .. "FROM cards c "
        .. "JOIN card_states cs ON c.id = cs.card_id "
        .. string.format("WHERE cs.due_date <= %d", now)

    -- Filter by tag if specified
    if opts.tag then
        local tag_pattern = opts.tag:gsub("'", "''")
        query = query .. string.format(
            " AND c.id IN (SELECT card_id FROM card_tags WHERE tag = '%s' OR tag LIKE '%s/%%')",
            tag_pattern, tag_pattern
        )
    end

    -- Filter by state if specified
    if opts.state then
        query = query .. string.format(" AND cs.state = '%s'", opts.state)
    end

    -- Order: learning cards first, then by due date
    query = query .. " ORDER BY CASE cs.state "
        .. "WHEN 'learning' THEN 0 "
        .. "WHEN 'relearning' THEN 1 "
        .. "WHEN 'new' THEN 2 "
        .. "ELSE 3 END, cs.due_date ASC"

    -- Apply limit
    if opts.limit then
        query = query .. string.format(" LIMIT %d", opts.limit)
    end

    local result = d:eval(query)
    return result or {}
end

--- Get new cards for today
---@param limit integer|nil Maximum cards to return
---@return table List of new cards
function M.get_new_cards(limit)
    local d = M.get()

    local query = "SELECT c.*, cs.state, cs.stability, cs.difficulty, cs.due_date "
        .. "FROM cards c "
        .. "JOIN card_states cs ON c.id = cs.card_id "
        .. "WHERE cs.state = 'new' "
        .. "ORDER BY c.created_at ASC"

    if limit then
        query = query .. string.format(" LIMIT %d", limit)
    end

    local result = d:eval(query)
    return result or {}
end

--- Count cards by state
---@return table Counts {new, learning, review, relearning, total}
function M.count_by_state()
    local d = M.get()

    local results = d:eval("SELECT state, COUNT(*) as count FROM card_states GROUP BY state") or {}

    local counts = { new = 0, learning = 0, review = 0, relearning = 0, total = 0 }
    for _, row in ipairs(results) do
        if row.state then
            counts[row.state] = row.count
            counts.total = counts.total + row.count
        end
    end

    return counts
end

--- Count due cards
---@return table Counts {new, learning, review, total}
function M.count_due()
    local d = M.get()
    local now = utils.now()

    local query = "SELECT "
        .. "SUM(CASE WHEN state = 'new' THEN 1 ELSE 0 END) as new, "
        .. "SUM(CASE WHEN state = 'learning' OR state = 'relearning' THEN 1 ELSE 0 END) as learning, "
        .. "SUM(CASE WHEN state = 'review' THEN 1 ELSE 0 END) as review, "
        .. "COUNT(*) as total "
        .. "FROM card_states "
        .. string.format("WHERE due_date <= %d", now)

    local results = d:eval(query) or {}

    return results[1] or { new = 0, learning = 0, review = 0, total = 0 }
end

-- =============================================================================
-- Tag Operations
-- =============================================================================

--- Set tags for a card (replaces existing)
---@param card_id string Card ID
---@param tags table List of tags
function M.set_card_tags(card_id, tags)
    local d = M.get()

    -- Remove existing tags
    d.card_tags:remove({ card_id = card_id })

    -- Insert new tags
    for _, tag in ipairs(tags) do
        d.card_tags:insert({
            card_id = card_id,
            tag = tag,
        })
    end
end

--- Get tags for a card
---@param card_id string Card ID
---@return table List of tags
function M.get_card_tags(card_id)
    local d = M.get()
    local rows = d.card_tags:where({ card_id = card_id }) or {}

    local tags = {}
    for _, row in ipairs(rows) do
        table.insert(tags, row.tag)
    end
    return tags
end

--- Get all unique tags
---@return table List of unique tags
function M.get_all_tags()
    local d = M.get()

    local results = d:eval("SELECT DISTINCT tag FROM card_tags ORDER BY tag") or {}

    local tags = {}
    for _, row in ipairs(results) do
        table.insert(tags, row.tag)
    end
    return tags
end

--- Get cards by tag (including subtags)
---@param tag string Tag to filter by
---@return table List of cards
function M.get_cards_by_tag(tag)
    local d = M.get()
    local tag_escaped = tag:gsub("'", "''")

    local query = "SELECT DISTINCT c.*, cs.state, cs.stability, cs.difficulty, cs.due_date "
        .. "FROM cards c "
        .. "JOIN card_states cs ON c.id = cs.card_id "
        .. "JOIN card_tags ct ON c.id = ct.card_id "
        .. string.format("WHERE ct.tag = '%s' OR ct.tag LIKE '%s/%%' ", tag_escaped, tag_escaped)
        .. "ORDER BY c.file_path, c.line_number"

    local result = d:eval(query)
    return result or {}
end

--- Count cards per tag
---@return table Map of tag -> count
function M.count_by_tag()
    local d = M.get()

    local query = "SELECT tag, COUNT(*) as count "
        .. "FROM card_tags "
        .. "GROUP BY tag "
        .. "ORDER BY count DESC"

    local results = d:eval(query) or {}

    local counts = {}
    for _, row in ipairs(results) do
        counts[row.tag] = row.count
    end
    return counts
end

-- =============================================================================
-- Review History
-- =============================================================================

--- Record a review
---@param review table Review data
---@return boolean Success
function M.add_review(review)
    local d = M.get()

    d.reviews:insert({
        card_id = review.card_id,
        rating = review.rating,
        reviewed_at = review.reviewed_at or utils.now(),
        elapsed_ms = review.elapsed_ms,
        stability_before = review.stability_before,
        stability_after = review.stability_after,
        difficulty_before = review.difficulty_before,
        difficulty_after = review.difficulty_after,
        state_before = review.state_before,
        state_after = review.state_after,
    })

    -- Update daily stats
    M.update_daily_stats(review)

    return true
end

--- Get review history for a card
---@param card_id string Card ID
---@param limit integer|nil Maximum reviews to return
---@return table List of reviews
function M.get_reviews(card_id, limit)
    local d = M.get()

    local query = "SELECT * FROM reviews "
        .. string.format("WHERE card_id = '%s' ", card_id:gsub("'", "''"))
        .. "ORDER BY reviewed_at DESC"

    if limit then
        query = query .. string.format(" LIMIT %d", limit)
    end

    local result = d:eval(query)
    return result or {}
end

--- Update daily statistics
---@param review table Review data
function M.update_daily_stats(review)
    local d = M.get()
    local date = os.date("%Y-%m-%d", review.reviewed_at or utils.now())

    -- Check if entry exists
    local existing = d.daily_stats:where({ date = date }) or {}

    -- Binary rating: 1=Wrong, 2=Correct
    local rating_field = review.rating == 2 and "correct_count" or "wrong_count"

    if #existing > 0 then
        local stats = existing[1]
        local is_new = review.state_before == "new"

        d.daily_stats:update({
            where = { date = date },
            set = {
                new_count = stats.new_count + (is_new and 1 or 0),
                review_count = stats.review_count + (is_new and 0 or 1),
                [rating_field] = (stats[rating_field] or 0) + 1,
                total_time_ms = stats.total_time_ms + (review.elapsed_ms or 0),
            },
        })
    else
        local is_new = review.state_before == "new"
        local new_entry = {
            date = date,
            new_count = is_new and 1 or 0,
            review_count = is_new and 0 or 1,
            wrong_count = review.rating == 1 and 1 or 0,
            correct_count = review.rating == 2 and 1 or 0,
            total_time_ms = review.elapsed_ms or 0,
        }
        d.daily_stats:insert(new_entry)
    end
end

--- Get daily stats for a date range
---@param from_date string Start date (YYYY-MM-DD)
---@param to_date string End date (YYYY-MM-DD)
---@return table List of daily stats
function M.get_daily_stats(from_date, to_date)
    local d = M.get()

    local query = "SELECT * FROM daily_stats "
        .. string.format("WHERE date >= '%s' AND date <= '%s' ", from_date, to_date)
        .. "ORDER BY date ASC"

    local result = d:eval(query)
    return result or {}
end

--- Get overall statistics
---@return table Statistics summary
function M.get_stats()
    local d = M.get()

    local card_counts = M.count_by_state()
    local due_counts = M.count_due()

    -- Get total reviews (binary: rating 2 = correct, rating 1 = wrong)
    local review_query = "SELECT "
        .. "COUNT(*) as total_reviews, "
        .. "AVG(elapsed_ms) as avg_time_ms, "
        .. "SUM(CASE WHEN rating = 2 THEN 1 ELSE 0 END) as correct, "
        .. "SUM(CASE WHEN rating = 1 THEN 1 ELSE 0 END) as wrong "
        .. "FROM reviews"
    local review_results = d:eval(review_query) or {}
    local review_stats = review_results[1] or { total_reviews = 0, avg_time_ms = 0, correct = 0, wrong = 0 }

    -- Get streak (consecutive days with reviews)
    local streak_query = "SELECT date FROM daily_stats "
        .. "WHERE review_count > 0 OR new_count > 0 "
        .. "ORDER BY date DESC"
    local dates = d:eval(streak_query) or {}

    local streak = 0
    local today = os.date("%Y-%m-%d")
    local check_date = today

    for _, row in ipairs(dates) do
        if row.date == check_date then
            streak = streak + 1
            -- Calculate previous day
            local y, m, day = check_date:match("(%d+)-(%d+)-(%d+)")
            local timestamp = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(day) }) - 86400
            check_date = os.date("%Y-%m-%d", timestamp)
        else
            break
        end
    end

    local total_reviews = review_stats.total_reviews or 0
    local correct = review_stats.correct or 0

    return {
        total_cards = card_counts.total,
        new_cards = card_counts.new,
        learning_cards = card_counts.learning + (card_counts.relearning or 0),
        review_cards = card_counts.review,
        due_new = due_counts.new or 0,
        due_learning = due_counts.learning or 0,
        due_review = due_counts.review or 0,
        due_total = due_counts.total or 0,
        total_reviews = total_reviews,
        avg_time_ms = review_stats.avg_time_ms or 0,
        retention_rate = total_reviews > 0
            and (correct / total_reviews * 100)
            or 0,
        streak = streak,
    }
end

-- =============================================================================
-- Maintenance
-- =============================================================================

--- Mark orphaned cards (cards whose files no longer exist)
---@return table List of orphaned card IDs
function M.find_orphaned_cards()
    local d = M.get()
    local cards = d.cards:get() or {}
    local orphaned = {}

    for _, card in ipairs(cards) do
        if vim.fn.filereadable(card.file_path) ~= 1 then
            table.insert(orphaned, card.id)
        end
    end

    return orphaned
end

--- Delete orphaned cards
---@return integer Number of deleted cards
function M.cleanup_orphaned()
    local orphaned = M.find_orphaned_cards()

    for _, card_id in ipairs(orphaned) do
        M.delete_card(card_id)
    end

    return #orphaned
end

--- Vacuum database (optimize storage)
function M.vacuum()
    local d = M.get()
    d:execute("VACUUM")
end

return M
