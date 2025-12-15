-- Configuration management for nvim-flashcards

local M = {}

--- Default configuration
M.defaults = {
    -- Directories to scan for cards (user must set at least one)
    directories = {},

    -- Database filename (stored in each configured directory)
    db_filename = ".flashcards.db",

    -- Card detection patterns
    patterns = {
        -- Inline pattern: "front :: back"
        inline = {
            enabled = true,
            separator = "::",
        },
        -- Fenced block pattern: :::card ... --- ... ::: #tags
        fenced = {
            enabled = true,
            fence = "card",  -- Used with ::: (e.g., :::card)
        },
        -- Custom delimiter pattern: ??? ... --- ... ???
        custom = {
            enabled = true,
            delimiter = "???",
            separator = "---",
        },
    },

    -- Tag settings
    tags = {
        -- Inherit tags from file path (e.g., math/calc.md -> #math/calc)
        inherit_from_path = true,
        -- Base path to strip when inheriting (relative to directory)
        path_base = "",
    },

    -- FSRS algorithm parameters
    fsrs = {
        -- Target correctness rate (0.7 - 0.95, e.g., 0.85 = 85% target)
        target_correctness = 0.85,
        -- Maximum interval in days
        maximum_interval = 365,
        -- Algorithm weights (advanced users only)
        weights = {
            initial_stability_wrong = 0.5,
            initial_stability_correct = 3.0,
            initial_difficulty = 5.0,
            difficulty_decay = 0.3,
            difficulty_growth = 0.5,
            stability_factor = 2.5,
            difficulty_weight = 0.1,
            forget_stability_factor = 0.3,
            learning_steps = { 1, 10, 60 },  -- minutes
        },
        -- Enable fuzzing to spread reviews
        enable_fuzz = true,
    },

    -- UI settings
    ui = {
        -- Window size (fraction of screen or absolute)
        width = 0.7,
        height = 0.6,
        -- Border style: "none", "single", "double", "rounded", "solid", "shadow"
        border = "rounded",
        -- Key to reveal answer
        show_answer_key = "<Space>",
        -- Keymaps for rating (binary: correct/wrong)
        keymaps = {
            correct = "1",
            wrong = "2",
            quit = "q",
            edit = "e",
            skip = "s",
            undo = "u",
        },
        -- Show time estimates for each rating
        show_intervals = true,
        -- Icons (set to nil to disable)
        icons = {
            new = "★",
            learning = "◐",
            review = "●",
            relearning = "◑",
            due = "!",
            correct = "✓",
            wrong = "✗",
        },
    },

    -- Auto-sync cards when saving markdown files
    auto_sync = true,

    -- File patterns to scan
    file_patterns = { "*.md", "*.markdown" },

    -- Files/directories to ignore
    ignore_patterns = {
        "node_modules",
        ".git",
        ".obsidian",
        "__pycache__",
    },

    -- Highlight groups
    highlights = {
        FlashcardFront = { link = "Title" },
        FlashcardBack = { link = "Normal" },
        FlashcardTag = { link = "Identifier" },
        FlashcardDivider = { link = "Comment" },
        FlashcardProgress = { link = "Number" },
        FlashcardWrong = { fg = "#f38ba8" },   -- Red for wrong
        FlashcardCorrect = { fg = "#a6e3a1" }, -- Green for correct
    },

    -- Session settings
    session = {
        -- Maximum cards per session (nil for unlimited)
        max_cards = nil,
        -- New cards per day limit
        new_cards_per_day = 20,
        -- Review cards per day limit (nil for unlimited)
        review_cards_per_day = nil,
    },
}

--- Current configuration (populated by setup)
M.options = {}

--- Deep merge two tables
---@param t1 table Base table
---@param t2 table Override table
---@return table Merged table
local function deep_merge(t1, t2)
    local result = vim.deepcopy(t1)
    for k, v in pairs(t2) do
        if type(v) == "table" and type(result[k]) == "table" then
            result[k] = deep_merge(result[k], v)
        else
            result[k] = v
        end
    end
    return result
end

--- Setup configuration
---@param opts table|nil User options
function M.setup(opts)
    opts = opts or {}
    M.options = deep_merge(M.defaults, opts)

    -- Expand directory paths
    for i, dir in ipairs(M.options.directories) do
        M.options.directories[i] = vim.fn.expand(dir)
    end

    -- Setup highlight groups
    M._setup_highlights()
end

--- Setup highlight groups
function M._setup_highlights()
    for name, def in pairs(M.options.highlights) do
        vim.api.nvim_set_hl(0, name, def)
    end
end

--- Get database path for a directory
---@param dir string|nil Directory (uses first configured if nil)
---@return string Database file path
function M.get_db_path(dir)
    if dir then
        return vim.fs.joinpath(dir, M.options.db_filename)
    end

    if #M.options.directories > 0 then
        return vim.fs.joinpath(M.options.directories[1], M.options.db_filename)
    end

    -- Fallback to current working directory
    return vim.fs.joinpath(vim.fn.getcwd(), M.options.db_filename)
end

--- Get all database paths (one per directory)
---@return table List of database paths
function M.get_all_db_paths()
    local paths = {}
    for _, dir in ipairs(M.options.directories) do
        table.insert(paths, vim.fs.joinpath(dir, M.options.db_filename))
    end
    return paths
end

--- Check if a file should be ignored
---@param filepath string File path to check
---@return boolean True if should be ignored
function M.should_ignore(filepath)
    for _, pattern in ipairs(M.options.ignore_patterns) do
        if filepath:match(pattern) then
            return true
        end
    end
    return false
end

--- Validate configuration
---@return boolean, string|nil Valid, error message
function M.validate()
    if #M.options.directories == 0 then
        return false, "No directories configured. Use :FlashcardsInit or configure directories in setup()"
    end

    for _, dir in ipairs(M.options.directories) do
        if vim.fn.isdirectory(dir) ~= 1 then
            return false, "Directory does not exist: " .. dir
        end
    end

    if M.options.fsrs.target_correctness < 0.7 or M.options.fsrs.target_correctness > 0.95 then
        return false, "target_correctness must be between 0.7 and 0.95"
    end

    return true, nil
end

return M
