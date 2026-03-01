--- Review floating window UI for nvim-flashcards.
--- Manages the interactive review session: rendering cards, handling keybindings,
--- showing answers, and displaying session summary on completion.
--- @module flashcards.ui.review
local M = {}

local Popup = require("nui.popup")
local event = require("nui.utils.autocmd").event

local config = require("flashcards.config")
local scheduler = require("flashcards.scheduler")
local fsrs = require("flashcards.fsrs")
local utils = require("flashcards.utils")
local components = require("flashcards.ui.components")

-- ============================================================================
-- Module State
-- ============================================================================

local state = {
  session = nil,
  popup = nil,
  showing_answer = false,
}

-- ============================================================================
-- Popup Creation
-- ============================================================================

--- Create the review floating window popup.
--- @return table nui.popup instance
local function create_popup()
  local ui_config = config.options.ui

  -- Convert fractional sizes to percentage strings for nui
  local width = ui_config.width
  if type(width) == "number" and width < 1 then
    width = math.floor(width * 100) .. "%"
  end
  local height = ui_config.height
  if type(height) == "number" and height < 1 then
    height = math.floor(height * 100) .. "%"
  end

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
      width = width,
      height = height,
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

-- ============================================================================
-- Rendering Helpers
-- ============================================================================

--- Add language label lines above code fences for visual clarity.
--- Inserts "-- lang --" above ```lang lines.
--- @param content string text content possibly containing code fences
--- @return string content with language labels inserted
local function add_language_labels(content)
  local lines = utils.lines(content)
  local result = {}
  for _, line in ipairs(lines) do
    local lang = line:match("^```(%w+)%s*$")
    if lang then
      table.insert(result, string.rep("\u{2500}", 2) .. " " .. lang .. " " .. string.rep("\u{2500}", 2))
      table.insert(result, line)
    else
      table.insert(result, line)
    end
  end
  return table.concat(result, "\n")
end

--- Apply highlight groups to rendered buffer lines.
--- @param bufnr number buffer number
--- @param lines string[] the rendered lines
local function apply_highlights(bufnr, lines)
  local ns = vim.api.nvim_create_namespace("flashcards_review")
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  for i, line in ipairs(lines) do
    -- Header line (first line)
    if i == 1 then
      vim.api.nvim_buf_add_highlight(bufnr, ns, "FlashcardProgress", i - 1, 0, -1)
    end

    -- Divider lines (solid horizontal rules)
    if line:match("^%s*\u{2500}+%s*$") then
      vim.api.nvim_buf_add_highlight(bufnr, ns, "FlashcardDivider", i - 1, 0, -1)
    end

    -- Language labels (e.g., "-- python --")
    if line:match("^%s*\u{2500}+ %w+ \u{2500}+$") then
      vim.api.nvim_buf_add_highlight(bufnr, ns, "FlashcardLanguage", i - 1, 0, -1)
    end

    -- Tags
    local search_start = 1
    local tag_start, tag_end = line:find("#[%w_/%-]+", search_start)
    while tag_start do
      vim.api.nvim_buf_add_highlight(bufnr, ns, "FlashcardTag", i - 1, tag_start - 1, tag_end)
      search_start = tag_end + 1
      tag_start, tag_end = line:find("#[%w_/%-]+", search_start)
    end
  end
end

-- ============================================================================
-- Card Rendering
-- ============================================================================

--- Render the session completion summary screen.
local function render_complete()
  if not state.popup or not state.session then
    return
  end

  local bufnr = state.popup.bufnr
  vim.bo[bufnr].modifiable = true

  local summary = state.session:summary()
  local lines = {}

  table.insert(lines, "")
  table.insert(lines, "  Session Complete")
  table.insert(lines, "")
  table.insert(lines, "  " .. string.rep("\u{2500}", 40))
  table.insert(lines, "")
  table.insert(lines, string.format("  Cards reviewed:   %d", summary.reviewed))
  table.insert(lines, string.format("  Correct:          %d", summary.correct))
  table.insert(lines, string.format("  Wrong:            %d", summary.wrong))
  table.insert(lines, string.format("  New cards seen:   %d", summary.new_seen))
  table.insert(lines, string.format("  Retention rate:   %s", components.percentage(summary.retention_rate)))
  table.insert(lines, string.format("  Time elapsed:     %s", summary.elapsed_formatted))
  table.insert(lines, "")
  table.insert(lines, "  " .. string.rep("\u{2500}", 40))
  table.insert(lines, "")
  table.insert(lines, "  Press q or <Esc> to close")

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  -- Apply highlights to summary
  local ns = vim.api.nvim_create_namespace("flashcards_review")
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  -- "Session Complete" header
  vim.api.nvim_buf_add_highlight(bufnr, ns, "FlashcardProgress", 1, 0, -1)
  -- Dividers
  for i, line in ipairs(lines) do
    if line:match("^%s*\u{2500}+%s*$") then
      vim.api.nvim_buf_add_highlight(bufnr, ns, "FlashcardDivider", i - 1, 0, -1)
    end
  end
end

--- Render the current card in the review buffer.
--- Shows question only, or question + answer depending on state.showing_answer.
local function render_card()
  if not state.popup or not state.session then
    return
  end

  local card, is_reversed = state.session:current_card()
  if not card then
    render_complete()
    return
  end

  local bufnr = state.popup.bufnr
  vim.bo[bufnr].modifiable = true

  local lines = {}
  local icons = config.options.ui.icons
  local keymaps = config.options.ui.keymaps

  -- Determine display content based on reversed state
  local display_front = is_reversed and card.back or card.front
  local display_back = is_reversed and card.front or card.back

  -- Header: state icon, card state name, reversed indicator, progress, timer
  local card_state = state.session.store:get_card_state(card.id) or {}
  local status = card_state.status or "new"
  local reversed_indicator = is_reversed and " \u{2194}" or ""
  local progress = string.format("%d/%d", state.session.current_idx, #state.session.queue)
  local elapsed = utils.now() - state.session.start_time
  local time_str = components.format_duration(elapsed)
  local state_icon = icons[status] or ""
  local header = string.format(
    "  %s %s%s    %s  %s",
    state_icon,
    fsrs.state_name(status),
    reversed_indicator,
    progress,
    time_str
  )
  table.insert(lines, header)
  table.insert(lines, "")

  -- Front content with language labels
  local front_with_labels = add_language_labels(display_front)
  for _, line in ipairs(utils.lines(front_with_labels)) do
    table.insert(lines, "  " .. line)
  end

  if state.showing_answer then
    -- Divider
    table.insert(lines, "")
    table.insert(lines, "  " .. string.rep("\u{2500}", 50))
    table.insert(lines, "")

    -- Back content with language labels
    local back_with_labels = add_language_labels(display_back)
    for _, line in ipairs(utils.lines(back_with_labels)) do
      table.insert(lines, "  " .. line)
    end

    -- Tags
    if card.tags and #card.tags > 0 then
      table.insert(lines, "")
      local tag_line = "  "
      for _, tag in ipairs(card.tags) do
        tag_line = tag_line .. "#" .. tag .. " "
      end
      table.insert(lines, tag_line)
    end

    -- Note annotation
    if config.options.ui.show_note and card.note then
      table.insert(lines, "")
      table.insert(lines, "  [" .. card.note .. "]")
    end

    -- Rating buttons with interval previews
    table.insert(lines, "")
    table.insert(lines, "")

    local intervals = state.session:preview_intervals()

    local rating_line = string.format(
      "  [%s] Wrong    [%s] Correct      [%s] Quit",
      keymaps.wrong,
      keymaps.correct,
      keymaps.quit
    )
    table.insert(lines, rating_line)

    local interval_line = string.format(
      "   <%s          <%s",
      intervals and intervals[1] and intervals[1].formatted or "?",
      intervals and intervals[2] and intervals[2].formatted or "?"
    )
    table.insert(lines, interval_line)

    table.insert(lines, "")
    table.insert(lines, "  (Also: n=Wrong, y=Correct, s=Skip, u=Undo, e=Edit)")
  else
    -- Prompt to reveal answer
    table.insert(lines, "")
    table.insert(lines, "")
    local show_key = keymaps.show_answer or "<Space>"
    table.insert(lines, string.format("  Press %s to show answer", show_key))
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  apply_highlights(bufnr, lines)
end

-- ============================================================================
-- Keybindings
-- ============================================================================

--- Set up all keybindings on the review buffer.
--- @param popup table nui.popup instance
local function setup_keymaps(popup)
  local keymaps = config.options.ui.keymaps
  local bufnr = popup.bufnr

  local map = function(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = bufnr, nowait = true, desc = desc })
  end

  -- Show answer: configured key + always Space
  local show_key = keymaps.show_answer or "<Space>"
  map(show_key, function()
    M.show_answer()
  end, "Show answer")
  if show_key ~= "<Space>" then
    map("<Space>", function()
      M.show_answer()
    end, "Show answer")
  end

  -- Rating: configured keys
  map(keymaps.wrong, function()
    M.answer(fsrs.Rating.Wrong)
  end, "Wrong")
  map(keymaps.correct, function()
    M.answer(fsrs.Rating.Correct)
  end, "Correct")

  -- Rating: convenience aliases
  map("n", function()
    M.answer(fsrs.Rating.Wrong)
  end, "Wrong (n)")
  map("y", function()
    M.answer(fsrs.Rating.Correct)
  end, "Correct (y)")

  -- Navigation
  map(keymaps.quit, function()
    M.close()
  end, "Quit")
  map("<Esc>", function()
    M.close()
  end, "Quit")
  map(keymaps.skip, function()
    M.skip()
  end, "Skip")
  map(keymaps.undo, function()
    M.undo()
  end, "Undo")
  map(keymaps.edit, function()
    M.edit_card()
  end, "Edit card source")
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Start a review session.
--- Creates a scheduler session, builds the review queue, and opens the floating window.
--- @param store table storage backend instance
--- @param tag string|nil optional tag filter
function M.start(store, tag)
  -- Prevent opening multiple review sessions
  if state.session then
    vim.notify("A review session is already active", vim.log.levels.WARN)
    return
  end

  local fsrs_instance = fsrs.new(config.options.fsrs)
  local opts = {
    tag = tag,
    new_cards_per_day = config.options.session.new_cards_per_day,
  }
  state.session = scheduler.new_session(store, fsrs_instance, opts)
  state.session:load_cards()

  if #state.session.queue == 0 then
    vim.notify("No cards due for review!", vim.log.levels.INFO)
    state.session = nil
    return
  end

  state.popup = create_popup()
  state.popup:mount()
  setup_keymaps(state.popup)

  -- Close on buffer leave
  state.popup:on(event.BufLeave, function()
    M.close()
  end)

  state.showing_answer = false
  state.session:next_card()
  render_card()
end

--- Reveal the answer for the current card.
function M.show_answer()
  if not state.showing_answer then
    state.showing_answer = true
    render_card()
  end
end

--- Answer the current card with a rating.
--- If the answer is not yet showing, reveals it instead.
--- @param rating number 1 (Wrong) or 2 (Correct)
function M.answer(rating)
  if not state.session then
    return
  end

  if not state.showing_answer then
    M.show_answer()
    return
  end

  state.session:answer(rating)

  if state.session:next_card() then
    state.showing_answer = false
    render_card()
  else
    render_complete()
  end
end

--- Skip the current card, moving it to the end of the queue.
function M.skip()
  if not state.session then
    return
  end

  state.session:skip()

  -- After skip, current_idx already points to next card (queue shifted)
  -- But we need to check if there's still a valid card
  local card = state.session:current_card()
  if card then
    state.showing_answer = false
    render_card()
  else
    -- All remaining cards were skipped; try next_card to wrap around
    if state.session:next_card() then
      state.showing_answer = false
      render_card()
    else
      render_complete()
    end
  end
end

--- Undo the last review, restoring the previous card and its state.
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

--- Jump to the current card's source file for editing.
--- Closes the review session first.
function M.edit_card()
  local card = state.session and state.session:current_card()
  if not card then
    return
  end

  -- Capture file info before closing
  local file_path = card.file_path
  local line_nr = card.line or 1

  M.close()
  vim.cmd(string.format("edit +%d %s", line_nr, vim.fn.fnameescape(file_path)))
end

--- Close the review session and unmount the popup.
--- Shows a summary notification if any cards were reviewed.
function M.close()
  if state.popup then
    state.popup:unmount()
    state.popup = nil
  end

  if state.session then
    local summary = state.session:summary()
    if summary.reviewed > 0 then
      -- Save the store after the session
      if state.session.store.save then
        state.session.store:save()
      end

      vim.notify(
        string.format(
          "Session: %d cards reviewed in %s (%s correct)",
          summary.reviewed,
          summary.elapsed_formatted,
          components.percentage(summary.retention_rate)
        ),
        vim.log.levels.INFO
      )
    end
    state.session = nil
  end

  state.showing_answer = false
end

--- Check whether a review session is currently active.
--- @return boolean
function M.is_active()
  return state.session ~= nil
end

return M
