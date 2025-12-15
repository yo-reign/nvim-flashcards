-- nvim-flashcards: A markdown-based spaced repetition plugin using FSRS
-- Main entry point

local M = {}

M._initialized = false

--- Setup the flashcards plugin
---@param opts table|nil User configuration
function M.setup(opts)
    if M._initialized then
        return
    end

    local config = require("flashcards.config")
    config.setup(opts)

    -- Register commands
    M._register_commands()

    -- Setup autocommands if auto_sync is enabled
    if config.options.auto_sync then
        M._setup_autocommands()
    end

    M._initialized = true
end

--- Get available tags for completion
---@return table List of tags
local function get_tags_for_completion()
    local ok, db = pcall(require, "flashcards.db")
    if not ok then
        return {}
    end
    local tags = db.get_all_tags()
    -- Add # prefix for display
    local result = {}
    for _, tag in ipairs(tags) do
        table.insert(result, "#" .. tag)
    end
    return result
end

--- Register all user commands
function M._register_commands()
    local commands = {
        {
            name = "FlashcardsReview",
            fn = function(opts)
                local tag = opts.args
                if not tag or #tag == 0 then
                    -- No tag specified - show tag picker
                    M._show_tag_picker()
                else
                    require("flashcards.ui.review").start(tag)
                end
            end,
            opts = {
                nargs = "?",
                desc = "Start flashcard review session",
                complete = function(arg_lead)
                    local tags = get_tags_for_completion()
                    if not arg_lead or #arg_lead == 0 then
                        return tags
                    end
                    -- Filter tags that match the prefix
                    local filtered = {}
                    for _, tag in ipairs(tags) do
                        if tag:lower():find(arg_lead:lower(), 1, true) then
                            table.insert(filtered, tag)
                        end
                    end
                    return filtered
                end,
            },
        },
        {
            name = "FlashcardsScan",
            fn = function()
                require("flashcards.scanner").scan()
            end,
            opts = { desc = "Scan directories for flashcards" },
        },
        {
            name = "FlashcardsStats",
            fn = function()
                require("flashcards.ui.stats").show()
            end,
            opts = { desc = "Show flashcard statistics" },
        },
        {
            name = "FlashcardsBrowse",
            fn = function()
                require("flashcards.telescope").browse()
            end,
            opts = { desc = "Browse flashcards with Telescope" },
        },
        {
            name = "FlashcardsDue",
            fn = function()
                require("flashcards.telescope").due()
            end,
            opts = { desc = "Show due flashcards with Telescope" },
        },
        {
            name = "FlashcardsTags",
            fn = function()
                require("flashcards.telescope").tags()
            end,
            opts = { desc = "Browse flashcards by tags" },
        },
        {
            name = "FlashcardsInit",
            fn = function()
                M.init_directory()
            end,
            opts = { desc = "Initialize flashcards in current directory" },
        },
    }

    for _, cmd in ipairs(commands) do
        vim.api.nvim_create_user_command(cmd.name, cmd.fn, cmd.opts)
    end
end

--- Show tag picker for review
function M._show_tag_picker()
    local db = require("flashcards.db")
    local config = require("flashcards.config")

    -- Validate config first
    local valid, err = config.validate()
    if not valid then
        vim.notify("Flashcards: " .. err, vim.log.levels.ERROR)
        return
    end

    db.init()

    -- Get total counts and due counts
    local tag_counts = db.count_by_tag()
    local due_counts = db.count_due()
    local due_by_tag = db.count_due_by_tag()

    -- Build options list
    local options = {}

    -- Add "All cards" option first
    table.insert(options, {
        label = "All cards",
        tag = nil,
        total = due_counts.total or 0,
        due = due_counts.total or 0,
    })

    -- Add tags sorted by due count (most urgent first)
    local sorted_tags = {}
    for tag, total in pairs(tag_counts) do
        local due = due_by_tag[tag] or 0
        table.insert(sorted_tags, { tag = tag, total = total, due = due })
    end
    table.sort(sorted_tags, function(a, b)
        -- Sort by due count first, then by total
        if a.due ~= b.due then
            return a.due > b.due
        end
        return a.total > b.total
    end)

    for _, item in ipairs(sorted_tags) do
        table.insert(options, {
            label = "#" .. item.tag,
            tag = item.tag,
            total = item.total,
            due = item.due,
        })
    end

    if #options <= 1 then
        -- No tags found, just start review with all cards
        require("flashcards.ui.review").start()
        return
    end

    -- Format options for vim.ui.select - emphasize due count
    local formatted = {}
    for _, opt in ipairs(options) do
        if opt.due > 0 then
            table.insert(formatted, string.format("%s - %d due (%d total)", opt.label, opt.due, opt.total))
        else
            table.insert(formatted, string.format("%s - 0 due (%d total)", opt.label, opt.total))
        end
    end

    vim.ui.select(formatted, {
        prompt = "Select tag to review:",
    }, function(choice, idx)
        if choice and idx then
            local selected = options[idx]
            if selected.due == 0 then
                vim.notify("No cards due for this tag!", vim.log.levels.INFO)
                return
            end
            require("flashcards.ui.review").start(selected.tag)
        end
    end)
end

--- Setup autocommands for auto-sync
function M._setup_autocommands()
    local group = vim.api.nvim_create_augroup("FlashcardsAutoSync", { clear = true })

    vim.api.nvim_create_autocmd("BufWritePost", {
        group = group,
        pattern = "*.md",
        callback = function(ev)
            local config = require("flashcards.config")
            local utils = require("flashcards.utils")

            -- Check if file is in a configured directory
            for _, dir in ipairs(config.options.directories) do
                local expanded = vim.fn.expand(dir)
                if utils.is_subpath(ev.file, expanded) then
                    require("flashcards.scanner").scan_file(ev.file)
                    break
                end
            end
        end,
    })
end

--- Initialize flashcards in a directory
---@param dir string|nil Directory to initialize (defaults to cwd)
function M.init_directory(dir)
    dir = dir or vim.fn.getcwd()
    local config = require("flashcards.config")
    local db = require("flashcards.db")

    -- Add directory to config if not present
    local found = false
    for _, d in ipairs(config.options.directories) do
        if vim.fn.expand(d) == dir then
            found = true
            break
        end
    end

    if not found then
        table.insert(config.options.directories, dir)
    end

    -- Initialize database in this directory
    db.init(dir)

    vim.notify("Flashcards initialized in: " .. dir, vim.log.levels.INFO)

    -- Run initial scan
    require("flashcards.scanner").scan()
end

--- Get plugin health status
function M.health()
    local health = vim.health or require("health")
    local start = health.start or health.report_start
    local ok = health.ok or health.report_ok
    local warn = health.warn or health.report_warn
    local error_fn = health.error or health.report_error

    start("nvim-flashcards")

    -- Check dependencies
    local deps = {
        { name = "plenary.nvim", module = "plenary" },
        { name = "nui.nvim", module = "nui.popup" },
        { name = "telescope.nvim", module = "telescope" },
        { name = "sqlite.lua", module = "sqlite" },
    }

    for _, dep in ipairs(deps) do
        local has_dep = pcall(require, dep.module)
        if has_dep then
            ok(dep.name .. " installed")
        else
            error_fn(dep.name .. " not found (required)")
        end
    end

    -- Check optional dependencies
    local has_ts = pcall(require, "nvim-treesitter")
    if has_ts then
        ok("nvim-treesitter installed (syntax highlighting enabled)")
    else
        warn("nvim-treesitter not found (syntax highlighting disabled)")
    end

    -- Check if initialized
    if M._initialized then
        ok("Plugin initialized")
        local config = require("flashcards.config")
        ok("Configured directories: " .. #config.options.directories)
    else
        warn("Plugin not yet initialized (call setup())")
    end
end

return M
