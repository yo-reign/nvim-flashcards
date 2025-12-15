-- Telescope integration for nvim-flashcards

local M = {}

local has_telescope, telescope = pcall(require, "telescope")
if not has_telescope then
    return M
end

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local previewers = require("telescope.previewers")

local config = require("flashcards.config")
local db = require("flashcards.db")
local fsrs = require("flashcards.fsrs")
local utils = require("flashcards.utils")

--- Create a card previewer
---@return table Previewer
local function card_previewer()
    return previewers.new_buffer_previewer({
        title = "Card Preview",
        define_preview = function(self, entry)
            local card = entry.value
            local lines = {}

            -- Front
            table.insert(lines, "# Question")
            table.insert(lines, "")
            for _, line in ipairs(utils.lines(card.front)) do
                table.insert(lines, line)
            end

            -- Divider
            table.insert(lines, "")
            table.insert(lines, string.rep("─", 40))
            table.insert(lines, "")

            -- Back
            table.insert(lines, "# Answer")
            table.insert(lines, "")
            for _, line in ipairs(utils.lines(card.back)) do
                table.insert(lines, line)
            end

            -- Tags
            local tags = card.tags
            if not tags and card.id then
                tags = db.get_card_tags(card.id)
            end
            if tags and #tags > 0 then
                table.insert(lines, "")
                local tag_line = ""
                for _, tag in ipairs(tags) do
                    tag_line = tag_line .. "#" .. tag .. " "
                end
                table.insert(lines, tag_line)
            end

            -- State info
            if card.state then
                table.insert(lines, "")
                table.insert(lines, string.rep("─", 40))
                table.insert(lines, "")
                table.insert(lines, string.format("State: %s", fsrs.state_name(card.state)))
                if card.due_date then
                    local due = os.date("%Y-%m-%d", card.due_date)
                    table.insert(lines, string.format("Due: %s", due))
                end
                if card.stability then
                    table.insert(lines, string.format("Stability: %.1f days", card.stability))
                end
                if card.reps then
                    table.insert(lines, string.format("Reviews: %d", card.reps))
                end
            end

            vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
            vim.bo[self.state.bufnr].filetype = "markdown"
        end,
    })
end

--- Create entry maker for cards
---@return function Entry maker
local function card_entry_maker()
    return function(card)
        local icons = config.options.ui.icons or {}
        local state_icon = icons[card.state] or ""

        -- Truncate front for display
        local front_preview = card.front:gsub("\n", " "):sub(1, 60)
        if #card.front > 60 then
            front_preview = front_preview .. "..."
        end

        return {
            value = card,
            display = string.format("%s %s", state_icon, front_preview),
            ordinal = card.front .. " " .. card.back,
            path = card.file_path,
            lnum = card.line_number,
        }
    end
end

--- Browse all cards
---@param opts table|nil Telescope options
function M.browse(opts)
    opts = opts or {}

    local valid, err = config.validate()
    if not valid then
        vim.notify("Flashcards: " .. err, vim.log.levels.ERROR)
        return
    end

    db.init()
    local cards = db.get_all_cards()

    -- Enrich with state info
    for i, card in ipairs(cards) do
        local state = db.get_card_state(card.id)
        if state then
            cards[i] = vim.tbl_extend("force", card, state)
        end
        cards[i].tags = db.get_card_tags(card.id)
    end

    pickers.new(opts, {
        prompt_title = "Browse Flashcards",
        finder = finders.new_table({
            results = cards,
            entry_maker = card_entry_maker(),
        }),
        sorter = conf.generic_sorter(opts),
        previewer = card_previewer(),
        attach_mappings = function(prompt_bufnr, map)
            actions.select_default:replace(function()
                actions.close(prompt_bufnr)
                local selection = action_state.get_selected_entry()
                if selection then
                    vim.cmd(string.format("edit +%d %s", selection.lnum, selection.path))
                end
            end)

            -- Start review with selected card's tag
            map("i", "<C-r>", function()
                local selection = action_state.get_selected_entry()
                actions.close(prompt_bufnr)
                if selection and selection.value.tags and #selection.value.tags > 0 then
                    require("flashcards.ui.review").start(selection.value.tags[1])
                else
                    require("flashcards.ui.review").start()
                end
            end)

            return true
        end,
    }):find()
end

--- Show due cards
---@param opts table|nil Telescope options
function M.due(opts)
    opts = opts or {}

    local valid, err = config.validate()
    if not valid then
        vim.notify("Flashcards: " .. err, vim.log.levels.ERROR)
        return
    end

    db.init()
    local cards = db.get_due_cards({ limit = 100 })

    if #cards == 0 then
        vim.notify("No cards due for review!", vim.log.levels.INFO)
        return
    end

    -- Add tags
    for i, card in ipairs(cards) do
        cards[i].tags = db.get_card_tags(card.id)
    end

    pickers.new(opts, {
        prompt_title = string.format("Due Cards (%d)", #cards),
        finder = finders.new_table({
            results = cards,
            entry_maker = card_entry_maker(),
        }),
        sorter = conf.generic_sorter(opts),
        previewer = card_previewer(),
        attach_mappings = function(prompt_bufnr, map)
            actions.select_default:replace(function()
                actions.close(prompt_bufnr)
                -- Start review session
                require("flashcards.ui.review").start()
            end)

            map("i", "<C-e>", function()
                local selection = action_state.get_selected_entry()
                actions.close(prompt_bufnr)
                if selection then
                    vim.cmd(string.format("edit +%d %s", selection.lnum, selection.path))
                end
            end)

            return true
        end,
    }):find()
end

--- Browse by tags
---@param opts table|nil Telescope options
function M.tags(opts)
    opts = opts or {}

    local valid, err = config.validate()
    if not valid then
        vim.notify("Flashcards: " .. err, vim.log.levels.ERROR)
        return
    end

    db.init()
    local tag_counts = db.count_by_tag()

    -- Convert to list
    local tags = {}
    for tag, count in pairs(tag_counts) do
        table.insert(tags, { tag = tag, count = count })
    end

    -- Sort by count
    table.sort(tags, function(a, b)
        return a.count > b.count
    end)

    if #tags == 0 then
        vim.notify("No tags found!", vim.log.levels.INFO)
        return
    end

    pickers.new(opts, {
        prompt_title = "Flashcard Tags",
        finder = finders.new_table({
            results = tags,
            entry_maker = function(entry)
                return {
                    value = entry,
                    display = string.format("#%s (%d cards)", entry.tag, entry.count),
                    ordinal = entry.tag,
                }
            end,
        }),
        sorter = conf.generic_sorter(opts),
        attach_mappings = function(prompt_bufnr, map)
            actions.select_default:replace(function()
                actions.close(prompt_bufnr)
                local selection = action_state.get_selected_entry()
                if selection then
                    -- Start review with this tag
                    require("flashcards.ui.review").start(selection.value.tag)
                end
            end)

            -- Browse cards with tag
            map("i", "<C-b>", function()
                local selection = action_state.get_selected_entry()
                actions.close(prompt_bufnr)
                if selection then
                    M.browse_tag(selection.value.tag)
                end
            end)

            return true
        end,
    }):find()
end

--- Browse cards with a specific tag
---@param tag string Tag to filter by
---@param opts table|nil Telescope options
function M.browse_tag(tag, opts)
    opts = opts or {}

    local cards = db.get_cards_by_tag(tag)

    -- Add tags
    for i, card in ipairs(cards) do
        cards[i].tags = db.get_card_tags(card.id)
    end

    pickers.new(opts, {
        prompt_title = string.format("Cards: #%s (%d)", tag, #cards),
        finder = finders.new_table({
            results = cards,
            entry_maker = card_entry_maker(),
        }),
        sorter = conf.generic_sorter(opts),
        previewer = card_previewer(),
        attach_mappings = function(prompt_bufnr, map)
            actions.select_default:replace(function()
                actions.close(prompt_bufnr)
                local selection = action_state.get_selected_entry()
                if selection then
                    vim.cmd(string.format("edit +%d %s", selection.lnum, selection.path))
                end
            end)

            -- Start review with tag
            map("i", "<C-r>", function()
                actions.close(prompt_bufnr)
                require("flashcards.ui.review").start(tag)
            end)

            return true
        end,
    }):find()
end

--- Search cards by content
---@param opts table|nil Telescope options
function M.search(opts)
    opts = opts or {}

    local valid, err = config.validate()
    if not valid then
        vim.notify("Flashcards: " .. err, vim.log.levels.ERROR)
        return
    end

    db.init()
    local cards = db.get_all_cards()

    -- Enrich with state and tags
    for i, card in ipairs(cards) do
        local state = db.get_card_state(card.id)
        if state then
            cards[i] = vim.tbl_extend("force", card, state)
        end
        cards[i].tags = db.get_card_tags(card.id)
    end

    pickers.new(opts, {
        prompt_title = "Search Flashcards",
        finder = finders.new_table({
            results = cards,
            entry_maker = function(card)
                local front_preview = card.front:gsub("\n", " "):sub(1, 40)
                local back_preview = card.back:gsub("\n", " "):sub(1, 40)

                return {
                    value = card,
                    display = front_preview .. " | " .. back_preview,
                    ordinal = card.front .. " " .. card.back .. " " .. table.concat(card.tags or {}, " "),
                    path = card.file_path,
                    lnum = card.line_number,
                }
            end,
        }),
        sorter = conf.generic_sorter(opts),
        previewer = card_previewer(),
        attach_mappings = function(prompt_bufnr, map)
            actions.select_default:replace(function()
                actions.close(prompt_bufnr)
                local selection = action_state.get_selected_entry()
                if selection then
                    vim.cmd(string.format("edit +%d %s", selection.lnum, selection.path))
                end
            end)

            return true
        end,
    }):find()
end

--- Register telescope extension
function M.register()
    if not has_telescope then
        return
    end

    return telescope.register_extension({
        exports = {
            flashcards = M.browse,
            browse = M.browse,
            due = M.due,
            tags = M.tags,
            search = M.search,
        },
    })
end

return M
