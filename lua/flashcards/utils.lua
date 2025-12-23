-- Utility functions for nvim-flashcards

local M = {}

--- Generate a new unique card ID
---@return string 8-character alphanumeric ID
function M.generate_new_id()
    local chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    local id = ""
    math.randomseed(os.time() + math.floor(vim.loop.hrtime() / 1000))
    for _ = 1, 8 do
        local idx = math.random(1, #chars)
        id = id .. chars:sub(idx, idx)
    end
    return id
end

--- Extract card ID from comment (<!-- fc:abc123 -->)
---@param text string Text that may contain ID comment
---@return string|nil ID if found
function M.extract_card_id(text)
    return text:match("<!%-%-%s*fc:([%w]+)%s*%-%->")
end

--- Format card ID as comment
---@param id string Card ID
---@return string Formatted comment
function M.format_card_id(id)
    return "<!-- fc:" .. id .. " -->"
end

--- Strip card ID comment from text
---@param text string Text containing ID comment
---@return string Text without ID comment
function M.strip_card_id(text)
    return text:gsub("%s*<!%-%-%s*fc:[%w]+%s*%-%->%s*", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

--- Normalize file path to absolute form for consistent storage/lookup
---@param path string File path
---@return string Normalized absolute path
function M.normalize_path(path)
    return vim.fn.fnamemodify(path, ":p")
end

--- Legacy: Generate a stable card ID from content (for migration)
---@param file_path string Source file path
---@param front string Card front content
---@param back string Card back content
---@return string 16-character hex ID
function M.generate_card_id(file_path, front, back)
    local content = file_path .. "|" .. front .. "|" .. back
    local hash = vim.fn.sha256(content)
    return hash:sub(1, 16)
end

--- Check if a path is a subpath of another
---@param child string Potential child path
---@param parent string Potential parent path
---@return boolean True if child is under parent
function M.is_subpath(child, parent)
    child = vim.fn.fnamemodify(child, ":p")
    parent = vim.fn.fnamemodify(parent, ":p")

    -- Ensure parent ends with separator
    if not parent:match("/$") then
        parent = parent .. "/"
    end

    return child:sub(1, #parent) == parent
end

--- Get relative path from base
---@param filepath string Full file path
---@param base string Base directory
---@return string Relative path
function M.relative_path(filepath, base)
    filepath = vim.fn.fnamemodify(filepath, ":p")
    base = vim.fn.fnamemodify(base, ":p")

    if not base:match("/$") then
        base = base .. "/"
    end

    if filepath:sub(1, #base) == base then
        return filepath:sub(#base + 1)
    end

    return filepath
end

--- Extract tags from file path
---@param filepath string File path relative to base
---@return table List of hierarchical tags
function M.tags_from_path(filepath)
    -- Remove file extension
    local path_no_ext = filepath:gsub("%.[^%.]+$", "")

    -- Normalize path separators and remove leading/trailing slashes
    local tag = path_no_ext:gsub("\\", "/"):gsub("^/+", ""):gsub("/+$", "")

    -- Generate hierarchical tags
    local tags = {}
    local parts = vim.split(tag, "/", { plain = true, trimempty = true })

    local current = ""
    for i, part in ipairs(parts) do
        if part ~= "" then
            if current == "" then
                current = part
            else
                current = current .. "/" .. part
            end
            -- Don't add the filename itself as a separate tag if it matches parent
            if i < #parts or (i > 1 and parts[i] ~= parts[i - 1]) or i == 1 then
                table.insert(tags, current)
            end
        end
    end

    return tags
end

--- Parse tags from a string (e.g., "#math #physics/quantum")
---@param text string Text containing hashtag tags
---@return table List of tags (without #)
function M.parse_tags(text)
    local tags = {}
    for tag in text:gmatch("#([%w_/%-]+)") do
        table.insert(tags, tag)
    end
    return tags
end

--- Remove tags from text
---@param text string Text containing hashtag tags
---@return string Text with tags removed
function M.strip_tags(text)
    return text:gsub("%s*#[%w_/%-]+", ""):gsub("^%s+", ""):gsub("%s+$", "")
end

--- Trim whitespace from string
---@param s string Input string
---@return string Trimmed string
function M.trim(s)
    return s:match("^%s*(.-)%s*$")
end

--- Get current Unix timestamp
---@return integer Unix timestamp
function M.now()
    return os.time()
end

--- Format Unix timestamp as human-readable date
---@param timestamp integer Unix timestamp
---@return string Formatted date
function M.format_date(timestamp)
    return os.date("%Y-%m-%d", timestamp)
end

--- Format Unix timestamp as human-readable datetime
---@param timestamp integer Unix timestamp
---@return string Formatted datetime
function M.format_datetime(timestamp)
    return os.date("%Y-%m-%d %H:%M", timestamp)
end

--- Format interval in days as human-readable string
---@param days number Interval in days
---@return string Formatted interval
function M.format_interval(days)
    if days < 1 then
        local minutes = math.floor(days * 24 * 60)
        if minutes < 60 then
            return minutes .. "m"
        else
            return math.floor(minutes / 60) .. "h"
        end
    elseif days < 30 then
        return math.floor(days) .. "d"
    elseif days < 365 then
        return string.format("%.1fmo", days / 30)
    else
        return string.format("%.1fy", days / 365)
    end
end

--- Calculate days between two timestamps
---@param from integer Start timestamp
---@param to integer End timestamp
---@return number Days between timestamps
function M.days_between(from, to)
    return (to - from) / 86400
end

--- Add days to a timestamp
---@param timestamp integer Unix timestamp
---@param days number Days to add
---@return integer New timestamp
function M.add_days(timestamp, days)
    return timestamp + math.floor(days * 86400)
end

--- Get start of day for a timestamp
---@param timestamp integer Unix timestamp
---@return integer Start of day timestamp
function M.start_of_day(timestamp)
    local date = os.date("*t", timestamp)
    date.hour = 0
    date.min = 0
    date.sec = 0
    return os.time(date)
end

--- Check if a card is due for review
---@param due_date integer|nil Due date timestamp
---@return boolean True if due
function M.is_due(due_date)
    if not due_date then
        return true -- New cards are always "due"
    end
    return due_date <= M.now()
end

--- Deep copy a table
---@param t table Table to copy
---@return table Copied table
function M.deep_copy(t)
    if type(t) ~= "table" then
        return t
    end
    local copy = {}
    for k, v in pairs(t) do
        copy[k] = M.deep_copy(v)
    end
    return copy
end

--- Debounce a function
---@param fn function Function to debounce
---@param ms integer Debounce time in milliseconds
---@return function Debounced function
function M.debounce(fn, ms)
    local timer = nil
    return function(...)
        local args = { ... }
        if timer then
            timer:stop()
        end
        timer = vim.loop.new_timer()
        timer:start(ms, 0, vim.schedule_wrap(function()
            fn(unpack(args))
            timer = nil
        end))
    end
end

--- Async wrapper using plenary
---@param fn function Async function
function M.async(fn)
    local async = require("plenary.async")
    async.run(fn)
end

--- Read file contents
---@param filepath string Path to file
---@return string|nil Content or nil on error
function M.read_file(filepath)
    local file = io.open(filepath, "r")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    return content
end

--- Get all files matching patterns in a directory (recursive)
---@param dir string Directory to scan
---@param patterns table List of glob patterns
---@param ignore table List of ignore patterns
---@return table List of file paths
function M.find_files(dir, patterns, ignore)
    local files = {}
    local scan = require("plenary.scandir")

    for _, pattern in ipairs(patterns) do
        local ext = pattern:match("%.(%w+)$")
        if ext then
            local found = scan.scan_dir(dir, {
                hidden = false,
                depth = 50,
                search_pattern = "%." .. ext .. "$",
            })

            for _, file in ipairs(found) do
                local should_ignore = false
                for _, ig in ipairs(ignore or {}) do
                    if file:match(ig) then
                        should_ignore = true
                        break
                    end
                end
                if not should_ignore then
                    table.insert(files, file)
                end
            end
        end
    end

    return files
end

--- Truncate string to max length
---@param s string Input string
---@param max_len integer Maximum length
---@param suffix string|nil Suffix to add if truncated (default "...")
---@return string Truncated string
function M.truncate(s, max_len, suffix)
    suffix = suffix or "..."
    if #s <= max_len then
        return s
    end
    return s:sub(1, max_len - #suffix) .. suffix
end

--- Escape string for use in Lua pattern
---@param s string Input string
---@return string Escaped string
function M.escape_pattern(s)
    return s:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1")
end

--- Get lines from string
---@param s string Multi-line string
---@return table List of lines
function M.lines(s)
    local result = {}
    for line in s:gmatch("([^\n]*)\n?") do
        table.insert(result, line)
    end
    -- Remove trailing empty line if exists
    if result[#result] == "" then
        table.remove(result)
    end
    return result
end

--- Join lines into string
---@param lines table List of lines
---@return string Joined string
function M.join_lines(lines)
    return table.concat(lines, "\n")
end

return M
