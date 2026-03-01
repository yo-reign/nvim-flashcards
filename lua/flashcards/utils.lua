--- Utility functions for nvim-flashcards
--- @module flashcards.utils
local M = {}

-- Seed random number generator once on load
do
  math.randomseed(vim.loop.hrtime())
  for _ = 1, 5 do
    math.random()
  end
end

-- ============================================================================
-- ID Generation
-- ============================================================================

local ID_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789"
local ID_LEN = 8

--- Generate a unique 8-character alphanumeric ID.
--- @return string
function M.generate_id()
  local id = {}
  for i = 1, ID_LEN do
    local idx = math.random(1, #ID_CHARS)
    id[i] = ID_CHARS:sub(idx, idx)
  end
  return table.concat(id)
end

--- Extract a card ID and flags from a flashcard comment.
--- Matches `<!-- fc:ID [!suspended] -->`.
--- @param text string
--- @return string|nil id
--- @return table flags
function M.extract_card_id(text)
  local id, rest = text:match("<!%-%-% *fc:([%w]+)(.-) *%-%->")
  if not id then
    return nil, {}
  end
  local flags = {}
  if rest:match("!suspended") then
    flags.suspended = true
  end
  return id, flags
end

--- Format a card ID as an HTML comment.
--- @param id string
--- @param flags table|nil optional flags (e.g., { suspended = true })
--- @return string
function M.format_card_id(id, flags)
  local parts = { "<!-- fc:" .. id }
  if flags and flags.suspended then
    parts[#parts + 1] = " !suspended"
  end
  parts[#parts + 1] = " -->"
  return table.concat(parts)
end

-- ============================================================================
-- Note Annotations
-- ============================================================================

--- Extract note content from a `<!-- note: ... -->` comment.
--- @param text string
--- @return string|nil
function M.extract_note(text)
  return text:match("<!%-%-% *note:% *(.-)% *%-%->")
end

-- ============================================================================
-- Template Variables
-- ============================================================================

--- Expand template variables in text.
--- Supported variables:
---   {{file.name}} - filename without extension
---   {{file.dir}}  - parent directory (relative to scan_root)
---   {{file.path}} - full relative path without extension
--- @param text string the text containing template variables
--- @param rel_path string relative file path (e.g., "math/algebra.md")
--- @param scan_root string the scan root directory (unused but kept for API)
--- @return string
function M.expand_template_vars(text, rel_path, scan_root)
  if not text:match("{{") then
    return text
  end

  -- Remove extension
  local path_no_ext = rel_path:match("^(.+)%..+$") or rel_path

  -- file.name: just the filename without extension
  local name = path_no_ext:match("([^/]+)$") or path_no_ext

  -- file.dir: parent directory path
  local dir = path_no_ext:match("^(.+)/[^/]+$") or ""

  -- file.path: full relative path without extension
  local path = path_no_ext

  text = text:gsub("{{file%.name}}", name)
  text = text:gsub("{{file%.dir}}", dir)
  text = text:gsub("{{file%.path}}", path)

  return text
end

-- ============================================================================
-- Tag Handling
-- ============================================================================

--- Parse tags from text. Tags are `#word` patterns where word can include `/`.
--- @param text string
--- @return string[] tags without the `#` prefix
function M.parse_tags(text)
  local tags = {}
  for tag in text:gmatch("#([%w_/]+)") do
    tags[#tags + 1] = tag
  end
  return tags
end

--- Remove all `#tag` patterns from text and trim trailing whitespace.
--- @param text string
--- @return string
function M.strip_tags(text)
  local result = text:gsub("%s*#[%w_/]+", "")
  return M.trim(result)
end

-- ============================================================================
-- String Utilities
-- ============================================================================

--- Trim leading and trailing whitespace.
--- @param s string
--- @return string
function M.trim(s)
  return s:match("^%s*(.-)%s*$")
end

--- Truncate a string to max length, appending "..." if truncated.
--- @param s string
--- @param max number
--- @return string
function M.truncate(s, max)
  if #s <= max then
    return s
  end
  return s:sub(1, max - 3) .. "..."
end

--- Escape Lua pattern special characters.
--- @param s string
--- @return string
function M.escape_pattern(s)
  return s:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
end

--- Split a string into lines.
--- @param s string
--- @return string[]
function M.lines(s)
  local result = {}
  for line in s:gmatch("([^\n]*)\n?") do
    result[#result + 1] = line
  end
  -- Remove trailing empty string from final newline
  if #result > 0 and result[#result] == "" then
    result[#result] = nil
  end
  return result
end

--- Join lines into a string with newlines.
--- @param line_list string[]
--- @return string
function M.join_lines(line_list)
  return table.concat(line_list, "\n")
end

-- ============================================================================
-- Path Utilities
-- ============================================================================

--- Normalize a file path: expand `~`, remove trailing `/`.
--- @param path string
--- @return string
function M.normalize_path(path)
  -- Expand tilde using vim.fn.expand (available in plenary test env)
  if path:sub(1, 1) == "~" then
    path = vim.fn.expand(path)
  end
  -- Remove trailing slash (but don't reduce "/" to "")
  if #path > 1 and path:sub(-1) == "/" then
    path = path:sub(1, -2)
  end
  return path
end

--- Check if path is under parent directory.
--- @param path string
--- @param parent string
--- @return boolean
function M.is_subpath(path, parent)
  local norm_path = M.normalize_path(path)
  local norm_parent = M.normalize_path(parent)
  if norm_path == norm_parent then return true end
  return norm_path:sub(1, #norm_parent + 1) == norm_parent .. "/"
end

--- Get relative path from base.
--- @param path string absolute path
--- @param base string base directory
--- @return string relative path
function M.relative_path(path, base)
  local norm_path = M.normalize_path(path)
  local norm_base = M.normalize_path(base)
  if norm_path:sub(1, #norm_base) == norm_base then
    local rel = norm_path:sub(#norm_base + 1)
    -- Remove leading slash
    if rel:sub(1, 1) == "/" then
      rel = rel:sub(2)
    end
    return rel
  end
  return norm_path
end

-- ============================================================================
-- File I/O
-- ============================================================================

--- Read entire file contents.
--- @param path string
--- @return string|nil content
--- @return string|nil error
function M.read_file(path)
  local f, err = io.open(path, "r")
  if not f then
    return nil, err
  end
  local content = f:read("*a")
  f:close()
  return content
end

--- Write content to file (creates/overwrites).
--- @param path string
--- @param content string
--- @return boolean success
--- @return string|nil error
function M.write_file(path, content)
  local f, err = io.open(path, "w")
  if not f then
    return false, err
  end
  f:write(content)
  f:close()
  return true
end

-- ============================================================================
-- Table Utilities
-- ============================================================================

--- Deep copy a table.
--- @param t table
--- @return table
function M.deep_copy(t)
  if type(t) ~= "table" then
    return t
  end
  local copy = {}
  for k, v in pairs(t) do
    copy[M.deep_copy(k)] = M.deep_copy(v)
  end
  return setmetatable(copy, getmetatable(t))
end

-- ============================================================================
-- Time Utilities
-- ============================================================================

local SECONDS_PER_DAY = 86400

--- Get current unix timestamp.
--- @return number
function M.now()
  return os.time()
end

--- Format a unix timestamp as a date string (YYYY-MM-DD).
--- @param ts number unix timestamp
--- @return string
function M.format_date(ts)
  return os.date("%Y-%m-%d", ts)
end

--- Format a unix timestamp as a datetime string (YYYY-MM-DD HH:MM).
--- @param ts number unix timestamp
--- @return string
function M.format_datetime(ts)
  return os.date("%Y-%m-%d %H:%M", ts)
end

--- Format an interval in days as a human-readable string.
--- @param days number interval in fractional days
--- @return string
function M.format_interval(days)
  local minutes = days * 24 * 60
  local hours = days * 24

  if minutes < 1 then
    return "< 1m"
  end

  -- Show hours if rounded hours >= 1
  local rounded_hours = math.floor(hours + 0.5)
  if rounded_hours < 1 then
    return string.format("%dm", math.floor(minutes + 0.5))
  end

  if rounded_hours < 24 then
    return string.format("%dh", rounded_hours)
  end

  if days < 30 then
    return string.format("%dd", math.floor(days + 0.5))
  end

  local months = days / 30
  if months < 12 then
    return string.format("%.1fmo", months)
  end

  local years = days / 365
  return string.format("%.1fy", years)
end

--- Calculate days between two unix timestamps.
--- @param ts1 number
--- @param ts2 number
--- @return number fractional days
function M.days_between(ts1, ts2)
  return math.abs(ts2 - ts1) / SECONDS_PER_DAY
end

--- Add days to a unix timestamp.
--- @param ts number unix timestamp
--- @param days number fractional days to add
--- @return number new timestamp
function M.add_days(ts, days)
  return ts + (days * SECONDS_PER_DAY)
end

--- Get the start of day (midnight) for a unix timestamp.
--- @param ts number unix timestamp
--- @return number timestamp at midnight
function M.start_of_day(ts)
  local date = os.date("*t", ts)
  date.hour = 0
  date.min = 0
  date.sec = 0
  return os.time(date)
end

-- ============================================================================
-- Debounce
-- ============================================================================

--- Create a debounced version of a function.
--- @param fn function the function to debounce
--- @param ms number delay in milliseconds
--- @return function debounced function
function M.debounce(fn, ms)
  local timer = nil
  return function(...)
    local args = { ... }
    if timer then
      timer:stop()
      timer:close()
    end
    timer = vim.loop.new_timer()
    timer:start(ms, 0, vim.schedule_wrap(function()
      timer:stop()
      timer:close()
      timer = nil
      fn(unpack(args))
    end))
  end
end

return M
