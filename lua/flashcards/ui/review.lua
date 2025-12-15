-- Review UI for nvim-flashcards
-- Floating window for reviewing flashcards with binary rating (Wrong/Correct)

local M = {}

local Popup = require("nui.popup")
local event = require("nui.utils.autocmd").event

local config = require("flashcards.config")
local scheduler = require("flashcards.scheduler")
local fsrs = require("flashcards.fsrs")
local utils = require("flashcards.utils")

-- Current session state
local state = {
    session = nil,
    popup = nil,
    showing_answer = false,
}

--- Create the review popup
---@return table Popup instance
local function create_popup()
    local ui_config = config.options.ui

    local popup = Popup({
        enter = true,
        focusable = true,
        border = {
            style = ui_config.border,
            text = {
                top = " nvim-flashcards ",
                top_align = "center",
            },
        },
        position = "50%",
        size = {
            width = ui_config.width < 1 and (ui_config.width * 100 .. "%") or ui_config.width,
            height = ui_config.height < 1 and (ui_config.height * 100 .. "%") or ui_config.height,
        },
        buf_options = {
            modifiable = true,
            filetype = "markdown",
        },
        win_options = {
            conceallevel = 2,
            concealcursor = "nvic",
            wrap = true,
            linebreak = true,
            cursorline = false,
        },
    })

    return popup
end

--- Setup keymaps for the review window
---@param popup table Popup instance
local function setup_keymaps(popup)
    local keymaps = config.options.ui.keymaps
    local bufnr = popup.bufnr

    -- Show answer
    vim.keymap.set("n", config.options.ui.show_answer_key, function()
        M.show_answer()
    end, { buffer = bufnr, nowait = true })

    -- Also space for show answer if not already set
    if config.options.ui.show_answer_key ~= "<Space>" then
        vim.keymap.set("n", "<Space>", function()
            M.show_answer()
        end, { buffer = bufnr, nowait = true })
    end

    -- Binary rating keymaps
    vim.keymap.set("n", keymaps.wrong, function()
        M.answer(fsrs.Rating.Wrong)
    end, { buffer = bufnr, nowait = true })

    vim.keymap.set("n", keymaps.correct, function()
        M.answer(fsrs.Rating.Correct)
    end, { buffer = bufnr, nowait = true })

    -- Alternative keymaps for convenience
    vim.keymap.set("n", "n", function()
        M.answer(fsrs.Rating.Wrong)
    end, { buffer = bufnr, nowait = true, desc = "Wrong (n = no)" })

    vim.keymap.set("n", "y", function()
        M.answer(fsrs.Rating.Correct)
    end, { buffer = bufnr, nowait = true, desc = "Correct (y = yes)" })

    -- Other actions
    vim.keymap.set("n", keymaps.quit, function()
        M.close()
    end, { buffer = bufnr, nowait = true })

    vim.keymap.set("n", keymaps.skip, function()
        M.skip()
    end, { buffer = bufnr, nowait = true })

    vim.keymap.set("n", keymaps.undo, function()
        M.undo()
    end, { buffer = bufnr, nowait = true })

    vim.keymap.set("n", keymaps.edit, function()
        M.edit_card()
    end, { buffer = bufnr, nowait = true })

    -- Escape to close
    vim.keymap.set("n", "<Esc>", function()
        M.close()
    end, { buffer = bufnr, nowait = true })
end

--- Transform content to show language labels for code blocks
---@param content string Card content
---@return string Transformed content with language labels
local function add_language_labels(content)
    local lines = utils.lines(content)
    local result = {}

    for _, line in ipairs(lines) do
        -- Check for code block opening with language
        local lang = line:match("^```(%w+)%s*$")
        if lang then
            -- Add language label before the code block
            table.insert(result, "── " .. lang .. " ──")
            table.insert(result, line)
        else
            table.insert(result, line)
        end
    end

    return table.concat(result, "\n")
end

--- Apply syntax highlighting to the buffer
---@param bufnr integer Buffer number
---@param lines table Lines content
local function apply_highlights(bufnr, lines)
    local ns = vim.api.nvim_create_namespace("flashcards_review")
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

    for i, line in ipairs(lines) do
        -- Highlight header
        if i == 1 then
            vim.api.nvim_buf_add_highlight(bufnr, ns, "FlashcardProgress", i - 1, 0, -1)
        end

        -- Highlight divider
        if line:match("^%s*─+%s*$") then
            vim.api.nvim_buf_add_highlight(bufnr, ns, "FlashcardDivider", i - 1, 0, -1)
        end

        -- Highlight language labels (── lang ──)
        if line:match("^%s*── %w+ ──$") then
            vim.api.nvim_buf_add_highlight(bufnr, ns, "FlashcardLanguage", i - 1, 0, -1)
        end

        -- Highlight tags
        local tag_start, tag_end = line:find("#[%w_/%-]+")
        while tag_start do
            vim.api.nvim_buf_add_highlight(bufnr, ns, "FlashcardTag", i - 1, tag_start - 1, tag_end)
            tag_start, tag_end = line:find("#[%w_/%-]+", tag_end + 1)
        end

        -- Highlight rating buttons
        if line:match("%[1%]") then
            local s, e = line:find("%[1%] Correct")
            if s then
                vim.api.nvim_buf_add_highlight(bufnr, ns, "FlashcardCorrect", i - 1, s - 1, e)
            end
        end
        if line:match("%[2%]") then
            local s, e = line:find("%[2%] Wrong")
            if s then
                vim.api.nvim_buf_add_highlight(bufnr, ns, "FlashcardWrong", i - 1, s - 1, e)
            end
        end
    end
end

--- Render the current card
local function render_card()
    if not state.popup or not state.session then
        return
    end

    local card = state.session:current_card()
    if not card then
        render_complete()
        return
    end

    local bufnr = state.popup.bufnr
    vim.bo[bufnr].modifiable = true

    local lines = {}
    local icons = config.options.ui.icons

    -- Header line
    local progress = string.format(
        "%d/%d",
        state.session.current_index,
        #state.session.cards
    )
    local time = state.session:elapsed_time_str()
    local state_icon = icons and icons[card.state] or ""
    local header = string.format("  %s %s    %s  %s", state_icon, fsrs.state_name(card.state), progress, time)
    table.insert(lines, header)
    table.insert(lines, "")

    -- Card front (question) - add language labels for code blocks
    local front_with_labels = add_language_labels(card.front)
    local front_lines = utils.lines(front_with_labels)
    for _, line in ipairs(front_lines) do
        table.insert(lines, "  " .. line)
    end

    if state.showing_answer then
        -- Divider
        table.insert(lines, "")
        table.insert(lines, "  " .. string.rep("─", 50))
        table.insert(lines, "")

        -- Card back (answer) - add language labels for code blocks
        local back_with_labels = add_language_labels(card.back)
        local back_lines = utils.lines(back_with_labels)
        for _, line in ipairs(back_lines) do
            table.insert(lines, "  " .. line)
        end

        -- Tags
        local tags = card.tags
        if not tags then
            -- Try to get tags from db
            local db = require("flashcards.db")
            tags = db.get_card_tags(card.id)
        end
        if tags and #tags > 0 then
            table.insert(lines, "")
            local tag_line = "  "
            for _, tag in ipairs(tags) do
                tag_line = tag_line .. "#" .. tag .. " "
            end
            table.insert(lines, tag_line)
        end

        -- Rating options (binary: Correct/Wrong)
        table.insert(lines, "")
        table.insert(lines, "")

        local intervals = state.session:preview_intervals()
        local keymaps = config.options.ui.keymaps

        local rating_line = string.format(
            "  [%s] Correct    [%s] Wrong      [%s] Quit",
            keymaps.correct, keymaps.wrong, keymaps.quit
        )
        table.insert(lines, rating_line)

        if config.options.ui.show_intervals then
            local interval_line = string.format(
                "   <%s            <%s",
                intervals[2] and intervals[2].formatted or "?",  -- Correct interval
                intervals[1] and intervals[1].formatted or "?"   -- Wrong interval
            )
            table.insert(lines, interval_line)
        end

        -- Additional hints
        table.insert(lines, "")
        table.insert(lines, "  (Also: y=Correct, n=Wrong, s=Skip, u=Undo, e=Edit)")
    else
        -- Show answer prompt
        table.insert(lines, "")
        table.insert(lines, "")
        table.insert(lines, string.format("  Press %s to show answer", config.options.ui.show_answer_key))
    end

    -- Set buffer content
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false

    -- Apply highlighting
    apply_highlights(bufnr, lines)
end

--- Render completion screen
local function render_complete()
    if not state.popup or not state.session then
        return
    end

    local bufnr = state.popup.bufnr
    vim.bo[bufnr].modifiable = true

    local summary = state.session:summary()
    local lines = {}

    table.insert(lines, "")
    table.insert(lines, "  Session Complete!")
    table.insert(lines, "")
    table.insert(lines, string.format("  Cards reviewed: %d", summary.reviewed))
    table.insert(lines, string.format("  Time: %s", summary.elapsed_formatted))
    table.insert(lines, "")
    table.insert(lines, "  Results:")
    table.insert(lines, string.format("    Wrong:   %d", summary.wrong or 0))
    table.insert(lines, string.format("    Correct: %d", summary.correct or 0))
    table.insert(lines, "")

    if summary.reviewed > 0 then
        table.insert(lines, string.format("  Accuracy: %.1f%%", summary.retention_rate))
        table.insert(lines, "")
    end

    table.insert(lines, "  Press any key to close")

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false

    -- Any key to close
    vim.keymap.set("n", "<CR>", function()
        M.close()
    end, { buffer = bufnr, nowait = true })
end

--- Start a review session
---@param tag string|nil Optional tag filter
function M.start(tag)
    -- Validate configuration
    local valid, err = config.validate()
    if not valid then
        vim.notify("Flashcards: " .. err, vim.log.levels.ERROR)
        return
    end

    -- Create session
    local opts = {}
    if tag and #tag > 0 then
        -- Remove leading # if present
        opts.tag = tag:gsub("^#", "")
    end

    state.session = scheduler.new_session(opts)

    -- Check if there are cards to review
    if #state.session.cards == 0 then
        vim.notify("No cards due for review!", vim.log.levels.INFO)
        return
    end

    -- Create popup
    state.popup = create_popup()
    state.popup:mount()

    -- Setup keymaps
    setup_keymaps(state.popup)

    -- Handle close
    state.popup:on(event.BufLeave, function()
        M.close()
    end)

    -- Start with first card
    state.showing_answer = false
    state.session:next_card()
    render_card()
end

--- Show the answer
function M.show_answer()
    if not state.showing_answer then
        state.showing_answer = true
        render_card()
    end
end

--- Answer the current card
---@param rating integer Rating (1=Wrong, 2=Correct)
function M.answer(rating)
    if not state.session or not state.showing_answer then
        -- Must show answer first
        M.show_answer()
        return
    end

    -- Record answer
    state.session:answer(rating)

    -- Move to next card
    if state.session:has_more() then
        state.showing_answer = false
        state.session:next_card()
        render_card()
    else
        render_complete()
    end
end

--- Skip current card
function M.skip()
    if not state.session then
        return
    end

    state.session:skip()
    state.showing_answer = false
    state.session:next_card()
    render_card()
end

--- Undo last answer
function M.undo()
    if not state.session then
        return
    end

    if state.session:undo() then
        state.showing_answer = true
        render_card()
    else
        vim.notify("Nothing to undo", vim.log.levels.INFO)
    end
end

--- Edit current card's source file
function M.edit_card()
    if not state.session then
        return
    end

    local card = state.session:current_card()
    if not card then
        return
    end

    -- Close review window
    M.close()

    -- Open source file at line
    vim.cmd(string.format("edit +%d %s", card.line_number, card.file_path))
end

--- Close the review session
function M.close()
    if state.popup then
        state.popup:unmount()
        state.popup = nil
    end

    if state.session then
        local summary = state.session:summary()
        if summary.reviewed > 0 then
            vim.notify(
                string.format("Session: %d cards reviewed in %s (%.0f%% correct)",
                    summary.reviewed, summary.elapsed_formatted, summary.retention_rate),
                vim.log.levels.INFO
            )
        end
        state.session = nil
    end

    state.showing_answer = false
end

--- Check if review is active
---@return boolean
function M.is_active()
    return state.session ~= nil
end

return M
