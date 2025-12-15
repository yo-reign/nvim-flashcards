-- SQLite database layer for nvim-flashcards
-- Stores card states, review history, and tags

local M = {}

local config = require("flashcards.config")
local utils = require("flashcards.utils")

-- Database connection (lazy-loaded)
local db = nil
local db_path_cached = nil
local initialized = false

--- Create tables using raw SQL
local function create_tables(database)
    database:execute([[
        CREATE TABLE IF NOT EXISTS cards (
            id TEXT PRIMARY KEY,
            file_path TEXT NOT NULL,
            line_number INTEGER,
            front TEXT NOT NULL,
            back TEXT NOT NULL,
            created_at INTEGER,
            updated_at INTEGER
        )
    ]])

    database:execute([[
        CREATE TABLE IF NOT EXISTS card_states (
            card_id TEXT PRIMARY KEY,
            state TEXT DEFAULT 'new',
            stability REAL DEFAULT 0,
            difficulty REAL DEFAULT 0,
            elapsed_days INTEGER DEFAULT 0,
            scheduled_days INTEGER DEFAULT 0,
            due_date INTEGER,
            last_review INTEGER,
            reps INTEGER DEFAULT 0,
            lapses INTEGER DEFAULT 0,
            learning_step INTEGER DEFAULT 0
        )
    ]])

    database:execute([[
        CREATE TABLE IF NOT EXISTS reviews (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            card_id TEXT,
            rating INTEGER,
            reviewed_at INTEGER,
            elapsed_ms INTEGER,
            stability_before REAL,
            stability_after REAL,
            difficulty_before REAL,
            difficulty_after REAL,
            state_before TEXT,
            state_after TEXT
        )
    ]])

    database:execute([[
        CREATE TABLE IF NOT EXISTS card_tags (
            card_id TEXT,
            tag TEXT
        )
    ]])

    database:execute([[
        CREATE TABLE IF NOT EXISTS daily_stats (
            date TEXT PRIMARY KEY,
            new_count INTEGER DEFAULT 0,
            review_count INTEGER DEFAULT 0,
            wrong_count INTEGER DEFAULT 0,
            correct_count INTEGER DEFAULT 0,
            total_time_ms INTEGER DEFAULT 0
        )
    ]])

    -- Create indexes
    pcall(function() database:execute("CREATE INDEX IF NOT EXISTS idx_cards_file ON cards(file_path)") end)
    pcall(function() database:execute("CREATE INDEX IF NOT EXISTS idx_states_due ON card_states(due_date)") end)
    pcall(function() database:execute("CREATE INDEX IF NOT EXISTS idx_states_state ON card_states(state)") end)
    pcall(function() database:execute("CREATE INDEX IF NOT EXISTS idx_tags_tag ON card_tags(tag)") end)
    pcall(function() database:execute("CREATE INDEX IF NOT EXISTS idx_tags_card ON card_tags(card_id)") end)
    pcall(function() database:execute("CREATE INDEX IF NOT EXISTS idx_reviews_card ON reviews(card_id)") end)
end

--- Initialize database connection
---@param dir string|nil Directory for database file
---@return table Database instance
function M.init(dir)
    -- Close existing connection if any
    if db then
        pcall(function() db:close() end)
        db = nil
        initialized = false
    end

    db_path_cached = config.get_db_path(dir)

    -- Create directory if it doesn't exist
    local dir_path = vim.fn.fnamemodify(db_path_cached, ":h")
    vim.fn.mkdir(dir_path, "p")

    -- Open database using the main sqlite module with minimal config
    local sqlite = require("sqlite")
    db = sqlite({
        uri = db_path_cached,
        opts = { keep_open = true },
    })

    -- Create tables
    create_tables(db)
    initialized = true

    return db
end

--- Get database connection (initializes if needed)
---@return table
function M.get()
    if not db or not initialized then
        M.init()
    end
    return db
end

--- Close database connection
function M.close()
    if db then
        pcall(function() db:close() end)
        db = nil
        initialized = false
    end
end

--- Safe eval that always returns a table
--- sqlite.lua's eval returns true for successful queries with no results
---@param query string SQL query
---@return table Results table (empty if no results)
local function safe_eval(query)
    local d = M.get()
    local result = d:eval(query)
    -- eval returns true for success with no results, or a table of results
    if type(result) == "table" then
        return result
    end
    return {}
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

    -- Check if card exists using raw SQL (more reliable)
    local card_id_escaped = card.id:gsub("'", "''")
    local existing = safe_eval(string.format(
        "SELECT id FROM cards WHERE id = '%s' LIMIT 1",
        card_id_escaped
    ))

    if #existing > 0 then
        -- Update existing card
        d:execute(string.format(
            "UPDATE cards SET file_path = '%s', line_number = %d, front = '%s', back = '%s', updated_at = %d WHERE id = '%s'",
            card.file_path:gsub("'", "''"),
            card.line_number or 0,
            card.front:gsub("'", "''"),
            card.back:gsub("'", "''"),
            now,
            card_id_escaped
        ))
    else
        -- Insert new card
        d:execute(string.format(
            "INSERT INTO cards (id, file_path, line_number, front, back, created_at, updated_at) VALUES ('%s', '%s', %d, '%s', '%s', %d, %d)",
            card_id_escaped,
            card.file_path:gsub("'", "''"),
            card.line_number or 0,
            card.front:gsub("'", "''"),
            card.back:gsub("'", "''"),
            now,
            now
        ))

        -- Create initial state
        d:execute(string.format(
            "INSERT INTO card_states (card_id, state, stability, difficulty, elapsed_days, scheduled_days, due_date, reps, lapses, learning_step) VALUES ('%s', 'new', 0, 0, 0, 0, %d, 0, 0, 0)",
            card_id_escaped,
            now
        ))
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
    local card_id_escaped = card_id:gsub("'", "''")

    d:execute(string.format("DELETE FROM card_tags WHERE card_id = '%s'", card_id_escaped))
    d:execute(string.format("DELETE FROM reviews WHERE card_id = '%s'", card_id_escaped))
    d:execute(string.format("DELETE FROM card_states WHERE card_id = '%s'", card_id_escaped))
    d:execute(string.format("DELETE FROM cards WHERE id = '%s'", card_id_escaped))

    return true
end

--- Get a card by ID
---@param card_id string Card ID
---@return table|nil Card with state
function M.get_card(card_id)
    local card_id_escaped = card_id:gsub("'", "''")

    local cards = safe_eval(string.format(
        "SELECT * FROM cards WHERE id = '%s' LIMIT 1",
        card_id_escaped
    ))

    if #cards == 0 then
        return nil
    end

    local card = cards[1]

    -- Get state
    local states = safe_eval(string.format(
        "SELECT * FROM card_states WHERE card_id = '%s' LIMIT 1",
        card_id_escaped
    ))

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
    return safe_eval("SELECT * FROM cards")
end

--- Get cards from a specific file
---@param file_path string File path
---@return table List of cards
function M.get_cards_by_file(file_path)
    local file_path_escaped = file_path:gsub("'", "''")
    return safe_eval(string.format(
        "SELECT * FROM cards WHERE file_path = '%s'",
        file_path_escaped
    ))
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
    local card_id_escaped = card_id:gsub("'", "''")

    local states = safe_eval(string.format(
        "SELECT * FROM card_states WHERE card_id = '%s' LIMIT 1",
        card_id_escaped
    ))

    if #states > 0 then
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
    local card_id_escaped = card_id:gsub("'", "''")

    d:execute(string.format(
        "UPDATE card_states SET state = '%s', stability = %f, difficulty = %f, "
        .. "elapsed_days = %d, scheduled_days = %d, due_date = %d, "
        .. "last_review = %s, reps = %d, lapses = %d, learning_step = %d "
        .. "WHERE card_id = '%s'",
        state.state,
        state.stability or 0,
        state.difficulty or 0,
        state.elapsed_days or 0,
        state.scheduled_days or 0,
        state.due_date or 0,
        state.last_review and tostring(state.last_review) or "NULL",
        state.reps or 0,
        state.lapses or 0,
        state.learning_step or 0,
        card_id_escaped
    ))

    return true
end

--- Get due cards (for review)
---@param opts table|nil Options {limit, tag, state}
---@return table List of due cards with states
function M.get_due_cards(opts)
    opts = opts or {}
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

    return safe_eval(query)
end

--- Get new cards for today
---@param limit integer|nil Maximum cards to return
---@return table List of new cards
function M.get_new_cards(limit)
    local query = "SELECT c.*, cs.state, cs.stability, cs.difficulty, cs.due_date "
        .. "FROM cards c "
        .. "JOIN card_states cs ON c.id = cs.card_id "
        .. "WHERE cs.state = 'new' "
        .. "ORDER BY c.created_at ASC"

    if limit then
        query = query .. string.format(" LIMIT %d", limit)
    end

    return safe_eval(query)
end

--- Count cards by state
---@return table Counts {new, learning, review, relearning, total}
function M.count_by_state()
    local results = safe_eval("SELECT state, COUNT(*) as count FROM card_states GROUP BY state")

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
    local now = utils.now()

    local query = "SELECT "
        .. "SUM(CASE WHEN state = 'new' THEN 1 ELSE 0 END) as new, "
        .. "SUM(CASE WHEN state = 'learning' OR state = 'relearning' THEN 1 ELSE 0 END) as learning, "
        .. "SUM(CASE WHEN state = 'review' THEN 1 ELSE 0 END) as review, "
        .. "COUNT(*) as total "
        .. "FROM card_states "
        .. string.format("WHERE due_date <= %d", now)

    local results = safe_eval(query)

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
    local card_id_escaped = card_id:gsub("'", "''")

    -- Remove existing tags
    d:execute(string.format("DELETE FROM card_tags WHERE card_id = '%s'", card_id_escaped))

    -- Insert new tags
    for _, tag in ipairs(tags) do
        local tag_escaped = tag:gsub("'", "''")
        d:execute(string.format(
            "INSERT INTO card_tags (card_id, tag) VALUES ('%s', '%s')",
            card_id_escaped,
            tag_escaped
        ))
    end
end

--- Get tags for a card
---@param card_id string Card ID
---@return table List of tags
function M.get_card_tags(card_id)
    local card_id_escaped = card_id:gsub("'", "''")

    local rows = safe_eval(string.format(
        "SELECT tag FROM card_tags WHERE card_id = '%s'",
        card_id_escaped
    ))

    local tags = {}
    for _, row in ipairs(rows) do
        table.insert(tags, row.tag)
    end
    return tags
end

--- Get all unique tags
---@return table List of unique tags
function M.get_all_tags()
    local results = safe_eval("SELECT DISTINCT tag FROM card_tags ORDER BY tag")

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
    local tag_escaped = tag:gsub("'", "''")

    local query = "SELECT DISTINCT c.*, cs.state, cs.stability, cs.difficulty, cs.due_date "
        .. "FROM cards c "
        .. "JOIN card_states cs ON c.id = cs.card_id "
        .. "JOIN card_tags ct ON c.id = ct.card_id "
        .. string.format("WHERE ct.tag = '%s' OR ct.tag LIKE '%s/%%' ", tag_escaped, tag_escaped)
        .. "ORDER BY c.file_path, c.line_number"

    return safe_eval(query)
end

--- Count cards per tag
---@return table Map of tag -> count
function M.count_by_tag()
    local query = "SELECT tag, COUNT(*) as count "
        .. "FROM card_tags "
        .. "GROUP BY tag "
        .. "ORDER BY count DESC"

    local results = safe_eval(query)

    local counts = {}
    for _, row in ipairs(results) do
        counts[row.tag] = row.count
    end
    return counts
end

--- Count due cards per tag
---@return table Map of tag -> due_count
function M.count_due_by_tag()
    local now = utils.now()

    local query = "SELECT ct.tag, COUNT(*) as count "
        .. "FROM card_tags ct "
        .. "JOIN card_states cs ON ct.card_id = cs.card_id "
        .. string.format("WHERE cs.due_date <= %d ", now)
        .. "GROUP BY ct.tag "
        .. "ORDER BY count DESC"

    local results = safe_eval(query)

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
    local card_id_escaped = review.card_id:gsub("'", "''")
    local reviewed_at = review.reviewed_at or utils.now()

    d:execute(string.format(
        "INSERT INTO reviews (card_id, rating, reviewed_at, elapsed_ms, "
        .. "stability_before, stability_after, difficulty_before, difficulty_after, "
        .. "state_before, state_after) VALUES ('%s', %d, %d, %s, %s, %s, %s, %s, '%s', '%s')",
        card_id_escaped,
        review.rating or 0,
        reviewed_at,
        review.elapsed_ms and tostring(review.elapsed_ms) or "NULL",
        review.stability_before and tostring(review.stability_before) or "NULL",
        review.stability_after and tostring(review.stability_after) or "NULL",
        review.difficulty_before and tostring(review.difficulty_before) or "NULL",
        review.difficulty_after and tostring(review.difficulty_after) or "NULL",
        review.state_before or "new",
        review.state_after or "new"
    ))

    -- Update daily stats
    M.update_daily_stats(review)

    return true
end

--- Get review history for a card
---@param card_id string Card ID
---@param limit integer|nil Maximum reviews to return
---@return table List of reviews
function M.get_reviews(card_id, limit)
    local query = "SELECT * FROM reviews "
        .. string.format("WHERE card_id = '%s' ", card_id:gsub("'", "''"))
        .. "ORDER BY reviewed_at DESC"

    if limit then
        query = query .. string.format(" LIMIT %d", limit)
    end

    return safe_eval(query)
end

--- Update daily statistics
---@param review table Review data
function M.update_daily_stats(review)
    local d = M.get()
    local date = os.date("%Y-%m-%d", review.reviewed_at or utils.now())

    -- Check if entry exists
    local existing = safe_eval(string.format(
        "SELECT * FROM daily_stats WHERE date = '%s' LIMIT 1",
        date
    ))

    local is_new = review.state_before == "new"

    if #existing > 0 then
        local stats = existing[1]
        local new_count = (stats.new_count or 0) + (is_new and 1 or 0)
        local review_count = (stats.review_count or 0) + (is_new and 0 or 1)
        local wrong_count = (stats.wrong_count or 0) + (review.rating == 1 and 1 or 0)
        local correct_count = (stats.correct_count or 0) + (review.rating == 2 and 1 or 0)
        local total_time_ms = (stats.total_time_ms or 0) + (review.elapsed_ms or 0)

        d:execute(string.format(
            "UPDATE daily_stats SET new_count = %d, review_count = %d, "
            .. "wrong_count = %d, correct_count = %d, total_time_ms = %d "
            .. "WHERE date = '%s'",
            new_count, review_count, wrong_count, correct_count, total_time_ms, date
        ))
    else
        d:execute(string.format(
            "INSERT INTO daily_stats (date, new_count, review_count, wrong_count, correct_count, total_time_ms) "
            .. "VALUES ('%s', %d, %d, %d, %d, %d)",
            date,
            is_new and 1 or 0,
            is_new and 0 or 1,
            review.rating == 1 and 1 or 0,
            review.rating == 2 and 1 or 0,
            review.elapsed_ms or 0
        ))
    end
end

--- Get daily stats for a date range
---@param from_date string Start date (YYYY-MM-DD)
---@param to_date string End date (YYYY-MM-DD)
---@return table List of daily stats
function M.get_daily_stats(from_date, to_date)
    local query = "SELECT * FROM daily_stats "
        .. string.format("WHERE date >= '%s' AND date <= '%s' ", from_date, to_date)
        .. "ORDER BY date ASC"

    return safe_eval(query)
end

--- Get overall statistics
---@return table Statistics summary
function M.get_stats()
    local card_counts = M.count_by_state()
    local due_counts = M.count_due()

    -- Get total reviews (binary: rating 2 = correct, rating 1 = wrong)
    local review_query = "SELECT "
        .. "COUNT(*) as total_reviews, "
        .. "AVG(elapsed_ms) as avg_time_ms, "
        .. "SUM(CASE WHEN rating = 2 THEN 1 ELSE 0 END) as correct, "
        .. "SUM(CASE WHEN rating = 1 THEN 1 ELSE 0 END) as wrong "
        .. "FROM reviews"
    local review_results = safe_eval(review_query)
    local review_stats = review_results[1] or { total_reviews = 0, avg_time_ms = 0, correct = 0, wrong = 0 }

    -- Get streak (consecutive days with reviews)
    local streak_query = "SELECT date FROM daily_stats "
        .. "WHERE review_count > 0 OR new_count > 0 "
        .. "ORDER BY date DESC"
    local dates = safe_eval(streak_query)

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
    local cards = safe_eval("SELECT id, file_path FROM cards")
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
