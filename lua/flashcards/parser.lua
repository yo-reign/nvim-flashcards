-- Markdown parser for extracting flashcards
-- Supports multiple card formats:
-- 1. Inline: "front :: back #tags"
-- 2. Fenced: :::card ... --- ... ::: #tags
-- 3. Custom delimiters: ??? ... --- ... ???

local M = {}

local config = require("flashcards.config")
local utils = require("flashcards.utils")

--- Card structure
---@class Card
---@field id string Unique identifier
---@field file_path string Source file path
---@field line_number integer Line number in source
---@field front string Front content (question)
---@field back string Back content (answer)
---@field tags table List of tags

--- Parse a single markdown file for cards
---@param file_path string Path to markdown file
---@param content string|nil File content (reads file if nil)
---@return Card[] List of extracted cards
function M.parse_file(file_path, content)
    content = content or utils.read_file(file_path)
    if not content then
        return {}
    end

    local cards = {}
    local opts = config.options.patterns

    -- Parse inline cards
    if opts.inline.enabled then
        local inline_cards = M.parse_inline(file_path, content, opts.inline)
        vim.list_extend(cards, inline_cards)
    end

    -- Parse fenced cards
    if opts.fenced.enabled then
        local fenced_cards = M.parse_fenced(file_path, content, opts.fenced)
        vim.list_extend(cards, fenced_cards)
    end

    -- Parse custom delimiter cards
    if opts.custom.enabled then
        local custom_cards = M.parse_custom(file_path, content, opts.custom)
        vim.list_extend(cards, custom_cards)
    end

    -- Add implicit tags from file path
    if config.options.tags.inherit_from_path then
        local base_dir = M.find_base_directory(file_path)
        if base_dir then
            local relative = utils.relative_path(file_path, base_dir)
            local path_tags = utils.tags_from_path(relative)

            for _, card in ipairs(cards) do
                for _, tag in ipairs(path_tags) do
                    if not vim.tbl_contains(card.tags, tag) then
                        table.insert(card.tags, tag)
                    end
                end
            end
        end
    end

    return cards
end

--- Find the base directory for a file (first matching configured directory)
---@param file_path string File path
---@return string|nil Base directory
function M.find_base_directory(file_path)
    for _, dir in ipairs(config.options.directories) do
        if utils.is_subpath(file_path, dir) then
            return dir
        end
    end
    return nil
end

--- Parse inline cards (single line: "front :: back #tags")
---@param file_path string File path
---@param content string File content
---@param opts table Pattern options
---@return Card[] Cards
function M.parse_inline(file_path, content, opts)
    local cards = {}
    local separator = opts.separator or "::"
    local sep_escaped = utils.escape_pattern(separator)

    local lines = utils.lines(content)

    for line_num, line in ipairs(lines) do
        -- Skip lines that are in code blocks
        if M.is_in_code_block(lines, line_num) then
            goto continue
        end

        -- Skip lines that start with code block markers
        if line:match("^%s*```") or line:match("^%s*~~~") then
            goto continue
        end

        -- Look for separator
        local front, back = line:match("^(.-)%s*" .. sep_escaped .. "%s*(.+)$")

        if front and back and #utils.trim(front) > 0 then
            front = utils.trim(front)

            -- Extract tags from back
            local tags = utils.parse_tags(back)
            back = utils.strip_tags(back)
            back = utils.trim(back)

            if #back > 0 then
                local card = {
                    id = utils.generate_card_id(file_path, front, back),
                    file_path = file_path,
                    line_number = line_num,
                    front = front,
                    back = back,
                    tags = tags,
                }
                table.insert(cards, card)
            end
        end

        ::continue::
    end

    return cards
end

--- Parse fenced cards (:::card ... --- ... ::: #tags)
--- Uses ::: fence which doesn't conflict with code blocks inside cards
---@param file_path string File path
---@param content string File content
---@param opts table Pattern options
---@return Card[] Cards
function M.parse_fenced(file_path, content, opts)
    local cards = {}
    local fence_type = opts.fence or "card"

    -- Parse line by line to handle ::: fences properly
    local lines_arr = utils.lines(content)
    local i = 1

    while i <= #lines_arr do
        local line = lines_arr[i]

        -- Look for opening :::card
        local opener = line:match("^%s*:::%s*" .. fence_type .. "%s*$")
        if opener then
            local start_line = i
            local block_lines = {}
            local closing_tags = {}
            i = i + 1

            -- Collect lines until closing :::
            while i <= #lines_arr do
                local current = lines_arr[i]

                -- Check for closing ::: with optional tags
                local close_match, tags_str = current:match("^%s*:::%s*(.*)$")
                if close_match ~= nil then
                    -- Extract tags from closing line
                    if tags_str and #tags_str > 0 then
                        closing_tags = utils.parse_tags(tags_str)
                    end
                    break
                end

                table.insert(block_lines, current)
                i = i + 1
            end

            -- Process the block if we found content
            if #block_lines > 0 then
                local block = table.concat(block_lines, "\n")

                -- Split on separator (---)
                local front, back = block:match("^(.-)%s*\n%-%-%-%s*\n(.*)$")

                if front and back then
                    front = utils.trim(front)
                    back = utils.trim(back)

                    -- Use tags from closing line, or extract from back content as fallback
                    local tags = closing_tags
                    if #tags == 0 then
                        tags = utils.parse_tags(back)
                        back = utils.strip_tags(back)
                        back = utils.trim(back)
                    end

                    if #front > 0 and #back > 0 then
                        local card = {
                            id = utils.generate_card_id(file_path, front, back),
                            file_path = file_path,
                            line_number = start_line,
                            front = front,
                            back = back,
                            tags = tags,
                        }
                        table.insert(cards, card)
                    end
                end
            end
        end

        i = i + 1
    end

    return cards
end

--- Parse custom delimiter cards (??? ... --- ... ???)
---@param file_path string File path
---@param content string File content
---@param opts table Pattern options
---@return Card[] Cards
function M.parse_custom(file_path, content, opts)
    local cards = {}
    local delimiter = opts.delimiter or "???"
    local separator = opts.separator or "---"

    local delim_escaped = utils.escape_pattern(delimiter)
    local sep_escaped = utils.escape_pattern(separator)

    -- Pattern: delimiter\n...\nseparator\n...\ndelimiter
    local pattern = delim_escaped .. "\n(.-)\n" .. sep_escaped .. "\n(.-)\n" .. delim_escaped

    local lines = utils.lines(content)
    local current_pos = 1

    for front, back in content:gmatch(pattern) do
        -- Find line number for this block
        local block_start = content:find(delimiter .. "\n" .. utils.escape_pattern(front:sub(1, math.min(30, #front))), current_pos, true)
        local line_num = 1
        if block_start then
            line_num = select(2, content:sub(1, block_start):gsub("\n", "\n")) + 1
            current_pos = block_start + 1
        end

        front = utils.trim(front)

        -- Extract tags from back
        local tags = utils.parse_tags(back)
        back = utils.strip_tags(back)
        back = utils.trim(back)

        if #front > 0 and #back > 0 then
            local card = {
                id = utils.generate_card_id(file_path, front, back),
                file_path = file_path,
                line_number = line_num,
                front = front,
                back = back,
                tags = tags,
            }
            table.insert(cards, card)
        end
    end

    return cards
end

--- Check if a line is inside a code block
---@param lines table All lines
---@param line_num integer Line number to check
---@return boolean True if inside code block
function M.is_in_code_block(lines, line_num)
    local in_block = false
    local block_marker = nil

    for i = 1, line_num - 1 do
        local line = lines[i]
        local marker = line:match("^%s*(```%w*)")
            or line:match("^%s*(~~~%w*)")

        if marker then
            if not in_block then
                in_block = true
                block_marker = marker:sub(1, 3) -- Just ``` or ~~~
            elseif line:match("^%s*" .. utils.escape_pattern(block_marker)) then
                in_block = false
                block_marker = nil
            end
        end
    end

    return in_block
end

--- Extract all tags from content (useful for UI)
---@param content string Content to parse
---@return table Unique tags
function M.extract_all_tags(content)
    local tags = {}
    local seen = {}

    for tag in content:gmatch("#([%w_/%-]+)") do
        if not seen[tag] then
            seen[tag] = true
            table.insert(tags, tag)
        end
    end

    return tags
end

--- Parse tag hierarchy from a list of tags
---@param tags table List of tags
---@return table Hierarchical structure
function M.build_tag_hierarchy(tags)
    local hierarchy = {}

    for _, tag in ipairs(tags) do
        local parts = vim.split(tag, "/", { plain = true })
        local current = hierarchy

        for i, part in ipairs(parts) do
            if not current[part] then
                current[part] = {
                    _count = 0,
                    _full_path = table.concat(vim.list_slice(parts, 1, i), "/"),
                }
            end
            current[part]._count = current[part]._count + 1
            current = current[part]
        end
    end

    return hierarchy
end

--- Validate card content
---@param card Card Card to validate
---@return boolean, string|nil Valid, error message
function M.validate_card(card)
    if not card.front or #utils.trim(card.front) == 0 then
        return false, "Card front is empty"
    end

    if not card.back or #utils.trim(card.back) == 0 then
        return false, "Card back is empty"
    end

    if #card.front > 10000 then
        return false, "Card front is too long (max 10000 chars)"
    end

    if #card.back > 50000 then
        return false, "Card back is too long (max 50000 chars)"
    end

    return true, nil
end

--- Format card for display
---@param card Card Card to format
---@param show_answer boolean Whether to show the answer
---@return table Lines to display
function M.format_card(card, show_answer)
    local lines = {}

    -- Front
    for _, line in ipairs(utils.lines(card.front)) do
        table.insert(lines, line)
    end

    if show_answer then
        -- Divider
        table.insert(lines, "")
        table.insert(lines, string.rep("─", 40))
        table.insert(lines, "")

        -- Back
        for _, line in ipairs(utils.lines(card.back)) do
            table.insert(lines, line)
        end

        -- Tags
        if card.tags and #card.tags > 0 then
            table.insert(lines, "")
            local tag_line = ""
            for _, tag in ipairs(card.tags) do
                tag_line = tag_line .. "#" .. tag .. " "
            end
            table.insert(lines, utils.trim(tag_line))
        end
    end

    return lines
end

return M
