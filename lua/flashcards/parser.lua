--- State machine parser for extracting flashcards from markdown files.
--- @module flashcards.parser
local M = {}

local utils = require("flashcards.utils")

-- ============================================================================
-- State Constants
-- ============================================================================

local STATE_NORMAL = "NORMAL"
local STATE_FENCED_FRONT = "FENCED_FRONT"
local STATE_FENCED_BACK = "FENCED_BACK"

-- ============================================================================
-- Pattern Helpers
-- ============================================================================

--- Extract the number of backticks in a code fence line, or nil if not a fence.
--- Matches lines starting with 3 or more backticks.
--- @param line string
--- @return number|nil backtick_count
local function code_fence_backticks(line)
  local ticks = line:match("^%s*(```+)")
  if ticks then
    return #ticks
  end
  return nil
end

--- Check if a line is a fenced card opener (:::card or :?:card).
--- Returns the reversible flag and the rest of the line (for ID extraction).
--- @param line string
--- @return boolean|nil is_fenced, boolean reversible, string rest
local function match_fenced_open(line)
  -- :::card or :::card <!-- fc:id -->
  local rest = line:match("^:::card(.*)$")
  if rest then
    return true, false, rest
  end
  -- :?:card or :?:card <!-- fc:id -->
  rest = line:match("^:%?:card(.*)$")
  if rest then
    return true, true, rest
  end
  return nil, false, ""
end

--- Check if a line is a fenced card closer (:::end or :?:end).
--- Returns the match flag, whether it was a reversible closer, and the rest of
--- the line (for tag extraction).
--- @param line string
--- @return boolean matched, boolean reversible, string rest
local function match_fenced_close(line)
  -- :::end or :::end #tags
  local rest = line:match("^:::end(.*)$")
  if rest then
    return true, false, rest
  end
  -- :?:end or :?:end #tags
  rest = line:match("^:%?:end(.*)$")
  if rest then
    return true, true, rest
  end
  return false, false, ""
end

--- Check if a line is a front/back separator (:-:) on its own.
--- @param line string
--- @return boolean
local function is_separator(line)
  return utils.trim(line) == ":-:"
end

--- Check if a line opens a tag scope (:#tagname:).
--- Returns the tag name or nil.
--- @param line string
--- @param file_path string
--- @param scan_root string
--- @return string|nil tag_name
local function match_scope_open(line, file_path, scan_root)
  local tag = line:match("^:#([^/][^:]*):$")
  if tag then
    return utils.expand_template_vars(tag, file_path, scan_root)
  end
  return nil
end

--- Check if a line closes a tag scope (:#/tagname:).
--- Returns the tag name or nil.
--- @param line string
--- @param file_path string
--- @param scan_root string
--- @return string|nil tag_name
local function match_scope_close(line, file_path, scan_root)
  local tag = line:match("^:#/([^:]+):$")
  if tag then
    return utils.expand_template_vars(tag, file_path, scan_root)
  end
  return nil
end

--- Merge multiple tag lists, deduplicating while preserving order.
--- @vararg string[] tag lists to merge
--- @return string[]
local function merge_tags(...)
  local result = {}
  local seen = {}
  for i = 1, select("#", ...) do
    local tag_list = select(i, ...)
    for _, t in ipairs(tag_list) do
      if not seen[t] then
        seen[t] = true
        result[#result + 1] = t
      end
    end
  end
  return result
end

--- Decompose a potentially compound tag into all parent prefixes.
--- Given "a/b/c", returns {"a", "a/b", "a/b/c"}.
--- Given "a", returns {"a"}.
--- @param tag string
--- @return string[]
local function decompose_tag_parents(tag)
  local parts = {}
  for segment in tag:gmatch("[^/]+") do
    if #parts == 0 then
      parts[1] = segment
    else
      parts[#parts + 1] = parts[#parts] .. "/" .. segment
    end
  end
  return parts
end

--- Collect the current scope tags from the scope stack.
--- Builds hierarchical paths: :#a: + :#b: → ["a", "a/b"]
--- Compound scope tags (e.g., :#c/networking:) are decomposed so that
--- parent segments are also emitted: :#c/networking: → ["c", "c/networking"]
--- @param scope_stack table[]
--- @return string[]
local function collect_scope_tags(scope_stack)
  local tags = {}
  local seen = {}
  local prefix = ""
  for _, scope in ipairs(scope_stack) do
    local full_tag
    if prefix == "" then
      full_tag = scope.tag
    else
      full_tag = prefix .. "/" .. scope.tag
    end
    -- Decompose to emit parent segments (handles compound tags with "/")
    for _, parent in ipairs(decompose_tag_parents(full_tag)) do
      if not seen[parent] then
        seen[parent] = true
        tags[#tags + 1] = parent
      end
    end
    prefix = full_tag
  end
  return tags
end

--- Nest inline/close-line tags under the current scope prefix.
--- Tags matching any scope segment, parent prefix, or full path are dropped.
--- @param scope_stack table[] the current scope stack
--- @param tags string[] inline or close-line tags
--- @return string[]
local function nest_tags_in_scope(scope_stack, tags)
  if #scope_stack == 0 or #tags == 0 then
    return tags
  end
  -- Build the full prefix and collect all names/paths to treat as redundant,
  -- including parent segments of compound scope tags.
  local prefix = ""
  local redundant = {}
  for _, scope in ipairs(scope_stack) do
    if prefix == "" then
      prefix = scope.tag
    else
      prefix = prefix .. "/" .. scope.tag
    end
    -- Add raw segment names (e.g., "c" and "networking" from "c/networking")
    for segment in scope.tag:gmatch("[^/]+") do
      redundant[segment] = true
    end
    -- Add all parent prefixes of the accumulated path
    for _, parent in ipairs(decompose_tag_parents(prefix)) do
      redundant[parent] = true
    end
  end
  -- Prefix non-redundant tags, drop tags that match a scope name or path
  local result = {}
  for _, tag in ipairs(tags) do
    if not redundant[tag] then
      result[#result + 1] = prefix .. "/" .. tag
    end
  end
  return result
end

--- Try to parse a line as an inline card (front ::: back or front :?: back).
--- Returns card data or nil.
--- @param line string
--- @param line_num number
--- @param file_path string
--- @param scope_stack table[]
--- @return table|nil card
local function try_parse_inline(line, line_num, file_path, scope_stack)
  -- Try :?: first (reversible), then ::: (normal)
  local front, back, reversible

  local f, b = line:match("^(.-)%s*:%?:%s*(.+)$")
  if f and b then
    front, back, reversible = f, b, true
  else
    f, b = line:match("^(.-)%s*:::%s*(.+)$")
    if f and b then
      front, back, reversible = f, b, false
    end
  end

  if not front or utils.trim(front) == "" then
    return nil
  end

  -- Extract card ID and flags from the back portion
  local id, flags = utils.extract_card_id(back)
  local suspended = flags and flags.suspended or false

  -- Strip the <!-- fc:... --> comment from back
  back = back:gsub("%s*<!%-%-% *fc:[%w]+.-% *%-%->", "")

  -- Extract tags from back
  local inline_tags = utils.parse_tags(back)

  -- Strip tags from back
  back = utils.strip_tags(back)

  -- Nest inline tags under scope prefix, then merge with scope tags
  local scope_tags = collect_scope_tags(scope_stack)
  local nested_inline = nest_tags_in_scope(scope_stack, inline_tags)
  local all_tags = merge_tags(scope_tags, nested_inline)

  return {
    front = utils.trim(front),
    back = utils.trim(back),
    reversible = reversible,
    id = id,
    suspended = suspended,
    tags = all_tags,
    note = nil,
    line = line_num,
    file_path = file_path,
  }
end

--- Trim leading and trailing blank lines from a list of lines and join.
--- @param line_list string[]
--- @return string
local function trim_multiline(line_list)
  -- Find first non-blank line
  local first = nil
  for i = 1, #line_list do
    if line_list[i]:match("%S") then
      first = i
      break
    end
  end
  if not first then
    return ""
  end
  -- Find last non-blank line
  local last = #line_list
  for i = #line_list, 1, -1 do
    if line_list[i]:match("%S") then
      last = i
      break
    end
  end
  local trimmed = {}
  for i = first, last do
    trimmed[#trimmed + 1] = line_list[i]
  end
  return table.concat(trimmed, "\n")
end

-- ============================================================================
-- Main Parser
-- ============================================================================

--- Parse markdown content and extract flashcards.
---
--- Uses a three-state machine:
---   NORMAL -> FENCED_FRONT (on :::card or :?:card)
---   FENCED_FRONT -> FENCED_BACK (on :-:)
---   FENCED_BACK -> NORMAL (on :::end or :?:end)
---
--- @param file_path string relative path to the file
--- @param content string file content
--- @param scan_root string the scan root directory
--- @return table[] cards list of card tables
--- @return table[] errors list of error tables { line, message }
function M.parse(file_path, content, scan_root)
  local cards = {}
  local errors = {}

  if content == "" then
    return cards, errors
  end

  local file_lines = utils.lines(content)
  local state = STATE_NORMAL
  local code_fence_ticks = 0 -- backtick count of opening fence in NORMAL state (0 = not in code block)
  local fenced_code_ticks = 0 -- backtick count of opening fence inside fenced cards (0 = not in code block)

  -- Scope tracking
  local scope_stack = {} -- { { tag = "python", line = 5 }, ... }

  -- Fenced card accumulator
  local fenced = {
    reversible = false,
    id = nil,
    suspended = false,
    front_lines = {},
    back_lines = {},
    open_line = 0,
    has_separator = false,
  }

  -- Track last card index for note annotation attachment
  local last_card_idx = nil
  local last_card_end_line = nil

  for line_num, line in ipairs(file_lines) do
    if state == STATE_NORMAL then
      -- Check for code fences in normal state
      local ticks = code_fence_backticks(line)
      if ticks then
        if code_fence_ticks == 0 then
          -- Opening a code block
          code_fence_ticks = ticks
        elseif ticks >= code_fence_ticks then
          -- Closing the code block (needs same or more backticks)
          code_fence_ticks = 0
        end
        -- Either way, skip this line
        goto continue
      end

      -- If inside a code block, skip everything
      if code_fence_ticks > 0 then
        goto continue
      end

      -- Check for note annotation (must be line immediately after a card)
      local note = utils.extract_note(line)
      if note and last_card_idx and last_card_end_line == line_num - 1 then
        -- Expand template variables in note
        note = utils.expand_template_vars(note, file_path, scan_root)
        cards[last_card_idx].note = note
        goto continue
      end

      -- Check for scope open: :#tagname:
      local scope_tag = match_scope_open(line, file_path, scan_root)
      if scope_tag then
        scope_stack[#scope_stack + 1] = { tag = scope_tag, line = line_num }
        goto continue
      end

      -- Check for scope close: :#/tagname:
      local close_tag = match_scope_close(line, file_path, scan_root)
      if close_tag then
        if #scope_stack == 0 then
          errors[#errors + 1] = {
            line = line_num,
            message = "Scope close :#/" .. close_tag .. ": without matching open",
          }
        else
          local top = scope_stack[#scope_stack]
          if top.tag ~= close_tag then
            errors[#errors + 1] = {
              line = line_num,
              message = "Scope close mismatch: expected :#/" .. top.tag .. ": but got :#/" .. close_tag .. ":",
            }
          else
            scope_stack[#scope_stack] = nil
          end
        end
        goto continue
      end

      -- Check for fenced card open
      local is_fenced, reversible, rest = match_fenced_open(line)
      if is_fenced then
        local id, flags = utils.extract_card_id(rest)
        fenced = {
          reversible = reversible,
          id = id,
          suspended = flags and flags.suspended or false,
          front_lines = {},
          back_lines = {},
          open_line = line_num,
          has_separator = false,
        }
        fenced_code_ticks = 0
        state = STATE_FENCED_FRONT
        goto continue
      end

      -- Try inline card
      local card = try_parse_inline(line, line_num, file_path, scope_stack)
      if card then
        cards[#cards + 1] = card
        last_card_idx = #cards
        last_card_end_line = line_num
      end

    elseif state == STATE_FENCED_FRONT then
      -- Track code fences inside fenced card
      local ticks = code_fence_backticks(line)
      if ticks then
        if fenced_code_ticks == 0 then
          fenced_code_ticks = ticks
        elseif ticks >= fenced_code_ticks then
          fenced_code_ticks = 0
        end
        fenced.front_lines[#fenced.front_lines + 1] = line
        goto continue
      end

      -- If inside a code block within the fenced card, just accumulate
      if fenced_code_ticks > 0 then
        fenced.front_lines[#fenced.front_lines + 1] = line
        goto continue
      end

      -- Check for separator
      if is_separator(line) then
        fenced.has_separator = true
        state = STATE_FENCED_BACK
        fenced_code_ticks = 0
        goto continue
      end

      -- Check for premature close (no separator)
      local matched = match_fenced_close(line)
      if matched then
        errors[#errors + 1] = {
          line = fenced.open_line,
          message = "Fenced card missing :-: separator",
        }
        state = STATE_NORMAL
        fenced_code_ticks = 0
        goto continue
      end

      -- Accumulate front content
      fenced.front_lines[#fenced.front_lines + 1] = line

    elseif state == STATE_FENCED_BACK then
      -- Track code fences inside fenced card
      local ticks = code_fence_backticks(line)
      if ticks then
        if fenced_code_ticks == 0 then
          fenced_code_ticks = ticks
        elseif ticks >= fenced_code_ticks then
          fenced_code_ticks = 0
        end
        fenced.back_lines[#fenced.back_lines + 1] = line
        goto continue
      end

      -- If inside a code block within the fenced card, just accumulate
      if fenced_code_ticks > 0 then
        fenced.back_lines[#fenced.back_lines + 1] = line
        goto continue
      end

      -- Check for fenced close
      local matched, _, close_rest = match_fenced_close(line)
      if matched then
        -- Extract tags from close line and nest under scope prefix
        local close_tags = utils.parse_tags(close_rest)
        local scope_tags = collect_scope_tags(scope_stack)
        local nested_close = nest_tags_in_scope(scope_stack, close_tags)
        local all_tags = merge_tags(scope_tags, nested_close)

        local card = {
          front = trim_multiline(fenced.front_lines),
          back = trim_multiline(fenced.back_lines),
          reversible = fenced.reversible,
          id = fenced.id,
          suspended = fenced.suspended,
          tags = all_tags,
          note = nil,
          line = fenced.open_line,
          file_path = file_path,
        }
        cards[#cards + 1] = card
        last_card_idx = #cards
        last_card_end_line = line_num

        state = STATE_NORMAL
        fenced_code_ticks = 0
        goto continue
      end

      -- Accumulate back content
      fenced.back_lines[#fenced.back_lines + 1] = line
    end

    ::continue::
  end

  -- Check for unclosed fenced card at EOF
  if state ~= STATE_NORMAL then
    errors[#errors + 1] = {
      line = fenced.open_line,
      message = "Unclosed fenced card (started at line " .. fenced.open_line .. ")",
    }
  end

  -- Check for unclosed scopes at EOF
  for i = #scope_stack, 1, -1 do
    local scope = scope_stack[i]
    errors[#errors + 1] = {
      line = scope.line,
      message = "Unclosed tag scope :#" .. scope.tag .. ": (opened at line " .. scope.line .. ")",
    }
  end

  return cards, errors
end

return M
