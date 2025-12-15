-- Statistics UI for nvim-flashcards
-- Shows overview of flashcard progress and history

local M = {}

local Popup = require("nui.popup")
local event = require("nui.utils.autocmd").event

local config = require("flashcards.config")
local db = require("flashcards.db")
local utils = require("flashcards.utils")

--- Show statistics popup
function M.show()
    -- Validate configuration
    local valid, err = config.validate()
    if not valid then
        vim.notify("Flashcards: " .. err, vim.log.levels.ERROR)
        return
    end

    local ui_config = config.options.ui

    local popup = Popup({
        enter = true,
        focusable = true,
        border = {
            style = ui_config.border,
            text = {
                top = " Flashcard Statistics ",
                top_align = "center",
            },
        },
        position = "50%",
        size = {
            width = "60%",
            height = "70%",
        },
        buf_options = {
            modifiable = false,
            filetype = "markdown",
        },
        win_options = {
            wrap = true,
        },
    })

    popup:mount()

    -- Close on escape or q
    vim.keymap.set("n", "<Esc>", function()
        popup:unmount()
    end, { buffer = popup.bufnr, nowait = true })

    vim.keymap.set("n", "q", function()
        popup:unmount()
    end, { buffer = popup.bufnr, nowait = true })

    popup:on(event.BufLeave, function()
        popup:unmount()
    end)

    -- Render stats
    local lines = M.render_stats()
    vim.bo[popup.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, lines)
    vim.bo[popup.bufnr].modifiable = false

    -- Apply highlighting
    M.apply_highlights(popup.bufnr, lines)
end

--- Render statistics as lines
---@return table Lines
function M.render_stats()
    local stats = db.get_stats()
    local tag_counts = db.count_by_tag()
    local lines = {}

    -- Overview section
    table.insert(lines, "# Overview")
    table.insert(lines, "")
    table.insert(lines, string.format("Total Cards: %d", stats.total_cards))
    table.insert(lines, string.format("  - New: %d", stats.new_cards))
    table.insert(lines, string.format("  - Learning: %d", stats.learning_cards))
    table.insert(lines, string.format("  - Review: %d", stats.review_cards))
    table.insert(lines, "")

    -- Due today
    table.insert(lines, "# Due Today")
    table.insert(lines, "")
    table.insert(lines, string.format("Total Due: %d", stats.due_total))
    table.insert(lines, string.format("  - New: %d", stats.due_new))
    table.insert(lines, string.format("  - Learning: %d", stats.due_learning))
    table.insert(lines, string.format("  - Review: %d", stats.due_review))
    table.insert(lines, "")

    -- Performance
    table.insert(lines, "# Performance")
    table.insert(lines, "")
    table.insert(lines, string.format("Total Reviews: %d", stats.total_reviews))
    table.insert(lines, string.format("Retention Rate: %.1f%%", stats.retention_rate))
    table.insert(lines, string.format("Current Streak: %d days", stats.streak))
    if stats.avg_time_ms > 0 then
        table.insert(lines, string.format("Avg. Time/Card: %.1fs", stats.avg_time_ms / 1000))
    end
    table.insert(lines, "")

    -- Tags
    if next(tag_counts) then
        table.insert(lines, "# Cards by Tag")
        table.insert(lines, "")

        -- Sort tags by count
        local sorted_tags = {}
        for tag, count in pairs(tag_counts) do
            table.insert(sorted_tags, { tag = tag, count = count })
        end
        table.sort(sorted_tags, function(a, b)
            return a.count > b.count
        end)

        for _, item in ipairs(sorted_tags) do
            table.insert(lines, string.format("  #%s: %d", item.tag, item.count))
        end
        table.insert(lines, "")
    end

    -- Recent activity
    local today = os.date("%Y-%m-%d")
    local week_ago = os.date("%Y-%m-%d", os.time() - 7 * 86400)
    local daily_stats = db.get_daily_stats(week_ago, today)

    if #daily_stats > 0 then
        table.insert(lines, "# Last 7 Days")
        table.insert(lines, "")

        for _, day in ipairs(daily_stats) do
            local total = day.new_count + day.review_count
            local bar = string.rep("█", math.min(20, math.floor(total / 2)))
            table.insert(lines, string.format("  %s: %3d %s", day.date, total, bar))
        end
        table.insert(lines, "")
    end

    -- Keybindings
    table.insert(lines, "")
    table.insert(lines, "Press q or <Esc> to close")

    return lines
end

--- Apply highlights to stats buffer
---@param bufnr integer Buffer number
---@param lines table Lines content
function M.apply_highlights(bufnr, lines)
    local ns = vim.api.nvim_create_namespace("flashcards_stats")
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

    for i, line in ipairs(lines) do
        -- Headers
        if line:match("^#") then
            vim.api.nvim_buf_add_highlight(bufnr, ns, "Title", i - 1, 0, -1)
        end

        -- Tags
        local tag_start, tag_end = line:find("#[%w_/%-]+")
        while tag_start do
            vim.api.nvim_buf_add_highlight(bufnr, ns, "FlashcardTag", i - 1, tag_start - 1, tag_end)
            tag_start, tag_end = line:find("#[%w_/%-]+", tag_end + 1)
        end

        -- Bar charts
        if line:match("█") then
            local bar_start = line:find("█")
            if bar_start then
                vim.api.nvim_buf_add_highlight(bufnr, ns, "FlashcardGood", i - 1, bar_start - 1, -1)
            end
        end
    end
end

--- Get stats summary for statusline
---@return string Summary string
function M.statusline()
    local stats = db.count_due()
    if stats.total > 0 then
        return string.format(" %d", stats.total)
    end
    return ""
end

return M
