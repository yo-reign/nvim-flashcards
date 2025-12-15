-- Reusable UI components for nvim-flashcards

local M = {}

local NuiText = require("nui.text")
local NuiLine = require("nui.line")

--- Create a styled header line
---@param text string Header text
---@param width integer|nil Width to center in
---@return NuiLine
function M.header(text, width)
    local line = NuiLine()
    if width then
        local padding = math.floor((width - #text) / 2)
        line:append(string.rep(" ", padding))
    end
    line:append(text, "Title")
    return line
end

--- Create a divider line
---@param width integer Width of divider
---@param char string|nil Character to use (default "─")
---@return string
function M.divider(width, char)
    char = char or "─"
    return string.rep(char, width)
end

--- Create a progress bar
---@param current integer Current value
---@param total integer Total value
---@param width integer Bar width in characters
---@return string Progress bar string
function M.progress_bar(current, total, width)
    if total == 0 then
        return string.rep("░", width)
    end

    local filled = math.floor((current / total) * width)
    local empty = width - filled

    return string.rep("█", filled) .. string.rep("░", empty)
end

--- Format a percentage
---@param value number Value (0-1 or 0-100)
---@param decimals integer|nil Decimal places (default 1)
---@return string Formatted percentage
function M.percentage(value, decimals)
    decimals = decimals or 1
    -- Normalize to 0-100 if needed
    if value <= 1 then
        value = value * 100
    end
    return string.format("%." .. decimals .. "f%%", value)
end

--- Create a key hint display
---@param key string Key to display
---@param action string Action description
---@return string Formatted hint
function M.key_hint(key, action)
    return string.format("[%s] %s", key, action)
end

--- Create a rating button
---@param key string Key binding
---@param label string Button label
---@param interval string|nil Interval preview
---@param highlight string|nil Highlight group
---@return NuiLine
function M.rating_button(key, label, interval, highlight)
    local line = NuiLine()
    line:append("[", "Comment")
    line:append(key, highlight or "Normal")
    line:append("] ", "Comment")
    line:append(label, highlight or "Normal")

    if interval then
        line:append(" ")
        line:append("<" .. interval, "Comment")
    end

    return line
end

--- Create a stat line
---@param label string Stat label
---@param value string|number Value
---@param highlight string|nil Highlight group for value
---@return NuiLine
function M.stat_line(label, value, highlight)
    local line = NuiLine()
    line:append(label .. ": ", "Comment")
    line:append(tostring(value), highlight or "Number")
    return line
end

--- Create a tag display
---@param tags table List of tags
---@return NuiLine
function M.tags_display(tags)
    local line = NuiLine()

    for i, tag in ipairs(tags) do
        if i > 1 then
            line:append(" ")
        end
        line:append("#" .. tag, "FlashcardTag")
    end

    return line
end

--- Wrap text to fit within width
---@param text string Text to wrap
---@param width integer Maximum width
---@return table List of lines
function M.wrap_text(text, width)
    local lines = {}
    local current_line = ""

    for word in text:gmatch("%S+") do
        if #current_line + #word + 1 <= width then
            if #current_line > 0 then
                current_line = current_line .. " " .. word
            else
                current_line = word
            end
        else
            if #current_line > 0 then
                table.insert(lines, current_line)
            end
            current_line = word
        end
    end

    if #current_line > 0 then
        table.insert(lines, current_line)
    end

    return lines
end

--- Create a box around content
---@param lines table Lines of content
---@param opts table|nil Options {width, title, border_style}
---@return table Box lines
function M.box(lines, opts)
    opts = opts or {}
    local width = opts.width or 40
    local title = opts.title
    local style = opts.border_style or "rounded"

    local borders = {
        rounded = { "╭", "╮", "╰", "╯", "─", "│" },
        single = { "┌", "┐", "└", "┘", "─", "│" },
        double = { "╔", "╗", "╚", "╝", "═", "║" },
    }

    local b = borders[style] or borders.rounded
    local result = {}

    -- Top border
    local top = b[1]
    if title then
        local title_text = " " .. title .. " "
        local remaining = width - 2 - #title_text
        local left_pad = math.floor(remaining / 2)
        local right_pad = remaining - left_pad
        top = top .. string.rep(b[5], left_pad) .. title_text .. string.rep(b[5], right_pad) .. b[2]
    else
        top = top .. string.rep(b[5], width - 2) .. b[2]
    end
    table.insert(result, top)

    -- Content
    for _, line in ipairs(lines) do
        local content = line
        local padding = width - 2 - #content
        if padding < 0 then
            content = content:sub(1, width - 5) .. "..."
            padding = 0
        end
        table.insert(result, b[6] .. content .. string.rep(" ", padding) .. b[6])
    end

    -- Bottom border
    table.insert(result, b[3] .. string.rep(b[5], width - 2) .. b[4])

    return result
end

--- Create notification text
---@param message string Message text
---@param level string|nil Level: "info", "warn", "error"
---@return NuiLine
function M.notification(message, level)
    local line = NuiLine()
    local icons = {
        info = " ",
        warn = " ",
        error = " ",
    }
    local highlights = {
        info = "DiagnosticInfo",
        warn = "DiagnosticWarn",
        error = "DiagnosticError",
    }

    level = level or "info"
    local icon = icons[level] or icons.info
    local hl = highlights[level] or highlights.info

    line:append(icon, hl)
    line:append(message, hl)

    return line
end

--- Truncate text with ellipsis
---@param text string Text to truncate
---@param max_len integer Maximum length
---@return string Truncated text
function M.truncate(text, max_len)
    if #text <= max_len then
        return text
    end
    return text:sub(1, max_len - 3) .. "..."
end

--- Format time duration
---@param seconds integer Duration in seconds
---@return string Formatted duration
function M.format_duration(seconds)
    if seconds < 60 then
        return string.format("%ds", seconds)
    elseif seconds < 3600 then
        return string.format("%dm %ds", math.floor(seconds / 60), seconds % 60)
    else
        local hours = math.floor(seconds / 3600)
        local mins = math.floor((seconds % 3600) / 60)
        return string.format("%dh %dm", hours, mins)
    end
end

return M
