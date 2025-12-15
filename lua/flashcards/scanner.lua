-- File scanner for nvim-flashcards
-- Recursively scans directories for markdown files and extracts cards

local M = {}

local config = require("flashcards.config")
local db = require("flashcards.db")
local parser = require("flashcards.parser")
local utils = require("flashcards.utils")

--- Scan all configured directories for cards
---@param opts table|nil Options {silent}
---@return table Scan results {files, cards_found, cards_added, cards_updated, cards_removed}
function M.scan(opts)
    opts = opts or {}

    local valid, err = config.validate()
    if not valid then
        if not opts.silent then
            vim.notify("Flashcards: " .. err, vim.log.levels.ERROR)
        end
        return { error = err }
    end

    -- Initialize database
    db.init()

    local results = {
        files = 0,
        cards_found = 0,
        cards_added = 0,
        cards_updated = 0,
        cards_removed = 0,
        errors = {},
    }

    -- Track all found card IDs
    local found_ids = {}

    -- Scan each directory
    for _, dir in ipairs(config.options.directories) do
        local dir_results = M.scan_directory(dir)

        results.files = results.files + dir_results.files
        results.cards_found = results.cards_found + dir_results.cards_found
        results.cards_added = results.cards_added + dir_results.cards_added
        results.cards_updated = results.cards_updated + dir_results.cards_updated

        for _, id in ipairs(dir_results.found_ids) do
            found_ids[id] = true
        end

        for _, err_item in ipairs(dir_results.errors) do
            table.insert(results.errors, err_item)
        end
    end

    -- Find orphaned cards (cards whose source no longer exists)
    local orphaned = db.find_orphaned_cards()
    for _, card_id in ipairs(orphaned) do
        if not found_ids[card_id] then
            db.delete_card(card_id)
            results.cards_removed = results.cards_removed + 1
        end
    end

    -- Show notification
    if not opts.silent then
        local msg = string.format(
            "Scanned %d files: %d cards (%d new, %d updated, %d removed)",
            results.files,
            results.cards_found,
            results.cards_added,
            results.cards_updated,
            results.cards_removed
        )
        vim.notify(msg, vim.log.levels.INFO)
    end

    return results
end

--- Scan a single directory
---@param dir string Directory path
---@return table Scan results
function M.scan_directory(dir)
    local results = {
        files = 0,
        cards_found = 0,
        cards_added = 0,
        cards_updated = 0,
        found_ids = {},
        errors = {},
    }

    -- Find all markdown files
    local files = utils.find_files(
        dir,
        config.options.file_patterns,
        config.options.ignore_patterns
    )

    for _, file_path in ipairs(files) do
        local file_results = M.scan_file(file_path, { silent = true })

        if file_results.error then
            table.insert(results.errors, {
                file = file_path,
                error = file_results.error,
            })
        else
            results.files = results.files + 1
            results.cards_found = results.cards_found + file_results.cards_found
            results.cards_added = results.cards_added + file_results.cards_added
            results.cards_updated = results.cards_updated + file_results.cards_updated

            for _, id in ipairs(file_results.found_ids) do
                table.insert(results.found_ids, id)
            end
        end
    end

    return results
end

--- Write card IDs back to source file
---@param file_path string File path
---@param cards table Cards that need IDs written
---@return boolean Success
local function write_card_ids(file_path, cards)
    if #cards == 0 then
        return true
    end

    local content = utils.read_file(file_path)
    if not content then
        return false
    end

    local lines = utils.lines(content)

    -- Sort cards by line number descending (so we can modify from bottom up)
    table.sort(cards, function(a, b)
        return a.line_number > b.line_number
    end)

    for _, card in ipairs(cards) do
        local line_num = card.line_number
        if line_num <= #lines then
            local line = lines[line_num]
            local id_comment = utils.format_card_id(card.id)

            -- Check if it's a fenced card (:::card line) or inline
            if line:match("^%s*:::%s*%w+") then
                -- Fenced card - append ID to :::card line
                lines[line_num] = line .. " " .. id_comment
            else
                -- Inline card - append ID at end of line
                lines[line_num] = line .. " " .. id_comment
            end
        end
    end

    -- Write back to file
    local file = io.open(file_path, "w")
    if not file then
        return false
    end
    file:write(table.concat(lines, "\n"))
    file:close()

    return true
end

--- Scan a single file for cards
---@param file_path string File path
---@param opts table|nil Options {silent}
---@return table Scan results
function M.scan_file(file_path, opts)
    opts = opts or {}

    local results = {
        cards_found = 0,
        cards_added = 0,
        cards_updated = 0,
        found_ids = {},
    }

    -- Read and parse file
    local content = utils.read_file(file_path)
    if not content then
        results.error = "Could not read file"
        return results
    end

    -- Parse cards
    local cards = parser.parse_file(file_path, content)
    results.cards_found = #cards

    -- Collect cards that need IDs written
    local cards_need_ids = {}
    for _, card in ipairs(cards) do
        if card.needs_id_write then
            table.insert(cards_need_ids, card)
        end
    end

    -- Write IDs to source file if needed
    if #cards_need_ids > 0 then
        local write_ok = write_card_ids(file_path, cards_need_ids)
        if not write_ok and not opts.silent then
            vim.notify(
                string.format("Could not write card IDs to %s", file_path),
                vim.log.levels.WARN
            )
        end
    end

    -- Get existing cards for this file
    local existing = db.get_cards_by_file(file_path)
    local existing_map = {}
    for _, card in ipairs(existing) do
        existing_map[card.id] = card
    end

    -- Process each card
    for _, card in ipairs(cards) do
        -- Validate card
        local valid, err = parser.validate_card(card)
        if not valid then
            if not opts.silent then
                vim.notify(
                    string.format("Invalid card at %s:%d: %s", file_path, card.line_number, err),
                    vim.log.levels.WARN
                )
            end
            goto continue
        end

        -- Track found ID
        table.insert(results.found_ids, card.id)

        -- Check if card exists
        if existing_map[card.id] then
            -- Check if content changed
            local ex = existing_map[card.id]
            if ex.front ~= card.front or ex.back ~= card.back then
                db.upsert_card(card)
                results.cards_updated = results.cards_updated + 1
            end
            existing_map[card.id] = nil -- Mark as processed
        else
            -- New card
            db.upsert_card(card)
            results.cards_added = results.cards_added + 1
        end

        ::continue::
    end

    -- Remove cards that are no longer in the file
    for id, _ in pairs(existing_map) do
        db.delete_card(id)
    end

    return results
end

--- Async scan with progress reporting
---@param opts table|nil Options
---@param callback function|nil Callback when done
function M.scan_async(opts, callback)
    opts = opts or {}

    vim.schedule(function()
        local results = M.scan(opts)
        if callback then
            callback(results)
        end
    end)
end

--- Watch directories for changes
---@return table Watcher handles
function M.watch()
    local handles = {}

    for _, dir in ipairs(config.options.directories) do
        local handle = vim.loop.new_fs_event()

        handle:start(dir, { recursive = true }, function(err, filename, events)
            if err then
                return
            end

            -- Only process markdown files
            if not filename:match("%.md$") and not filename:match("%.markdown$") then
                return
            end

            -- Debounce file changes
            vim.schedule(function()
                local full_path = vim.fs.joinpath(dir, filename)
                if vim.fn.filereadable(full_path) == 1 then
                    M.scan_file(full_path)
                end
            end)
        end)

        table.insert(handles, handle)
    end

    return handles
end

--- Stop watching directories
---@param handles table Watcher handles
function M.unwatch(handles)
    for _, handle in ipairs(handles) do
        handle:stop()
        handle:close()
    end
end

--- Get list of all markdown files in configured directories
---@return table List of file paths
function M.list_files()
    local all_files = {}

    for _, dir in ipairs(config.options.directories) do
        local files = utils.find_files(
            dir,
            config.options.file_patterns,
            config.options.ignore_patterns
        )
        vim.list_extend(all_files, files)
    end

    return all_files
end

--- Count cards without scanning (from database)
---@return table Counts
function M.count_cards()
    return db.count_by_state()
end

return M
