--- Statistics dashboard for nvim-flashcards.
--- Displays card counts, due cards, performance metrics, tags, and recent activity.
--- @module flashcards.ui.stats
local M = {}

local Popup = require("nui.popup")
local event = require("nui.utils.autocmd").event
local config = require("flashcards.config")

-- ============================================================================
-- Stats Popup
-- ============================================================================

--- Open the statistics dashboard in a floating popup.
--- @param store table storage backend instance
function M.show(store)
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
    size = { width = "60%", height = "70%" },
    buf_options = { modifiable = false, filetype = "markdown" },
    win_options = { wrap = true },
  })

  popup:mount()

  vim.keymap.set("n", "<Esc>", function() popup:unmount() end, { buffer = popup.bufnr, nowait = true })
  vim.keymap.set("n", "q", function() popup:unmount() end, { buffer = popup.bufnr, nowait = true })
  popup:on(event.BufLeave, function() popup:unmount() end)

  local lines = M.render_stats(store)
  vim.bo[popup.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, lines)
  vim.bo[popup.bufnr].modifiable = false

  M.apply_highlights(popup.bufnr, lines)
end

-- ============================================================================
-- Rendering
-- ============================================================================

--- Build the lines of text for the stats display.
--- @param store table storage backend instance
--- @return string[] lines
function M.render_stats(store)
  local stats = store:get_stats()
  local tag_list = store:get_all_tags()
  local lines = {}

  -- Overview section
  table.insert(lines, "# Overview")
  table.insert(lines, "")
  table.insert(lines, string.format("Total Cards: %d", stats.total_cards or 0))
  table.insert(lines, string.format("  - New: %d", stats.by_state.new or 0))
  table.insert(lines, string.format("  - Learning: %d", stats.by_state.learning or 0))
  table.insert(lines, string.format("  - Review: %d", stats.by_state.review or 0))
  table.insert(lines, string.format("  - Relearning: %d", stats.by_state.relearning or 0))
  table.insert(lines, "")

  -- Due today
  table.insert(lines, "# Due Today")
  table.insert(lines, "")
  table.insert(lines, string.format("Total Due: %d", stats.due.total or 0))
  table.insert(lines, string.format("  - New: %d", stats.due.new or 0))
  table.insert(lines, string.format("  - Learning: %d", stats.due.learning or 0))
  table.insert(lines, string.format("  - Review: %d", stats.due.review or 0))
  table.insert(lines, "")

  -- Performance
  table.insert(lines, "# Performance")
  table.insert(lines, "")
  table.insert(lines, string.format("Total Reviews: %d", stats.total_reviews or 0))
  table.insert(lines, string.format("Retention Rate: %.1f%%", (stats.retention_rate or 0) * 100))
  table.insert(lines, string.format("Current Streak: %d days", stats.streak or 0))
  if (stats.avg_time_ms or 0) > 0 then
    table.insert(lines, string.format("Avg. Time/Card: %.1fs", stats.avg_time_ms / 1000))
  end
  table.insert(lines, "")

  -- Tags
  if tag_list and #tag_list > 0 then
    table.insert(lines, "# Cards by Tag")
    table.insert(lines, "")
    for _, item in ipairs(tag_list) do
      local due = item.due_count or 0
      if due > 0 then
        table.insert(lines, string.format("  #%s: %d (%d due)", item.tag, item.count, due))
      else
        table.insert(lines, string.format("  #%s: %d", item.tag, item.count))
      end
    end
    table.insert(lines, "")
  end

  -- Recent activity (last 7 days)
  local daily_stats = store:get_daily_stats(7)
  if daily_stats and #daily_stats > 0 then
    table.insert(lines, "# Last 7 Days")
    table.insert(lines, "")
    for _, day in ipairs(daily_stats) do
      local total = (day.new_count or 0) + (day.review_count or 0)
      local bar = string.rep("█", math.min(20, math.floor(total / 2)))
      table.insert(lines, string.format("  %s: %3d %s", day.date, total, bar))
    end
    table.insert(lines, "")
  end

  table.insert(lines, "")
  table.insert(lines, "Press q or <Esc> to close")

  return lines
end

-- ============================================================================
-- Highlighting
-- ============================================================================

--- Apply highlight groups to the stats buffer.
--- @param bufnr number buffer handle
--- @param lines string[] the rendered lines
function M.apply_highlights(bufnr, lines)
  local ns = vim.api.nvim_create_namespace("flashcards_stats")
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  for i, line in ipairs(lines) do
    -- Section headers (lines starting with #)
    if line:match("^#") then
      vim.api.nvim_buf_add_highlight(bufnr, ns, "Title", i - 1, 0, -1)
    end

    -- Tags in the "Cards by Tag" section (# followed by word chars)
    local search_start = 1
    local tag_start, tag_end = line:find("#[%w_/%-]+", search_start)
    while tag_start do
      -- Only highlight tags that are not section headers (line does not start with "# ")
      if not line:match("^# ") then
        vim.api.nvim_buf_add_highlight(bufnr, ns, "FlashcardTag", i - 1, tag_start - 1, tag_end)
      end
      search_start = tag_end + 1
      tag_start, tag_end = line:find("#[%w_/%-]+", search_start)
    end

    -- Bar chart blocks
    if line:match("█") then
      local bar_start = line:find("█")
      if bar_start then
        vim.api.nvim_buf_add_highlight(bufnr, ns, "FlashcardGood", i - 1, bar_start - 1, -1)
      end
    end
  end
end

-- ============================================================================
-- Statusline
-- ============================================================================

--- Return a short string for statusline integration showing due card count.
--- @param store table storage backend instance
--- @return string statusline text (empty if nothing is due)
function M.statusline(store)
  local counts = store:count_due()
  if counts.total > 0 then
    return string.format(" %d", counts.total)
  end
  return ""
end

return M
