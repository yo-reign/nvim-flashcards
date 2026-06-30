--- Review floating window UI for nvim-flashcards.
--- Manages the interactive review session: rendering cards, handling keybindings,
--- showing answers, and displaying session summary on completion.
--- @module flashcards.ui.review
local M = {}

local Popup = require("nui.popup")

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
  completed = false,
  card_shown_at = nil,
  treesitter_seq = 0,
  scratchpad_card_id = nil,
  scratchpad_bufnr = nil,
  scratchpad_winid = nil,
  scratchpad_visible_on_answer = true,
  scratchpad_footer_lines = 0,
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
      filetype = "text",
    },
    win_options = {
      conceallevel = ui_config.conceallevel,
      concealcursor = ui_config.concealcursor,
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

local function stop_markdown_highlighting(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  state.treesitter_seq = state.treesitter_seq + 1
  if vim.treesitter and vim.treesitter.stop then
    pcall(vim.treesitter.stop, bufnr)
  end
  if vim.bo[bufnr].filetype ~= "text" then
    vim.bo[bufnr].filetype = "text"
  end
end

local function refresh_markdown_highlighting(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local seq = state.treesitter_seq
  vim.schedule(function()
    if seq ~= state.treesitter_seq then
      return
    end
    if not state.popup or state.popup.bufnr ~= bufnr then
      return
    end
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    if vim.bo[bufnr].filetype ~= "markdown" then
      vim.bo[bufnr].filetype = "markdown"
    end
    if vim.treesitter and vim.treesitter.start then
      pcall(vim.treesitter.start, bufnr, "markdown")
    end
  end)
end

-- ============================================================================
-- Scratchpad Helpers
-- ============================================================================

local function get_scratchpad_config()
  local ui_config = config.options and config.options.ui or {}
  local scratchpad = ui_config.scratchpad or {}
  if type(scratchpad) == "boolean" then
    scratchpad = { enabled = scratchpad }
  end
  return scratchpad
end

local function scratchpad_enabled()
  return get_scratchpad_config().enabled == true
end

local function scratchpad_min_height()
  local height = tonumber(get_scratchpad_config().height) or 6
  return math.max(1, math.floor(height))
end

local function scratchpad_total_height()
  -- Floating window content height plus border rows.
  return scratchpad_min_height() + 2
end

local function rendered_row_count(lines, winid)
  local width = math.max(1, vim.api.nvim_win_get_width(winid))
  local rows = 0
  for _, line in ipairs(lines) do
    local display_width = vim.fn.strdisplaywidth(line)
    rows = rows + math.max(1, math.ceil(display_width / width))
  end
  return rows
end

local function append_bottom_spacer(lines, reserved_lines)
  local winid = state.popup and state.popup.winid
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end

  -- Use display rows instead of raw line count so long/wrapped front text does
  -- not cause us to add spacer lines that would push the prompt off screen.
  local available = vim.api.nvim_win_get_height(winid)
  local used_rows = rendered_row_count(lines, winid)
  local spacer = available - used_rows - reserved_lines
  for _ = 1, math.max(0, spacer) do
    table.insert(lines, "")
  end
end

local function scratchpad_key(name, fallback)
  local keymaps = config.options.ui.keymaps or {}
  return keymaps[name] or fallback
end

local function close_scratchpad_window(wipe_buffer)
  if state.scratchpad_winid and vim.api.nvim_win_is_valid(state.scratchpad_winid) then
    pcall(vim.api.nvim_win_close, state.scratchpad_winid, true)
  end
  state.scratchpad_winid = nil

  if wipe_buffer and state.scratchpad_bufnr and vim.api.nvim_buf_is_valid(state.scratchpad_bufnr) then
    pcall(vim.api.nvim_buf_delete, state.scratchpad_bufnr, { force = true })
    state.scratchpad_bufnr = nil
  end
end

local function reset_scratchpad()
  close_scratchpad_window(true)
  state.scratchpad_card_id = nil
  state.scratchpad_visible_on_answer = true
  state.scratchpad_footer_lines = 0
end

local function ensure_scratchpad_buffer()
  if state.scratchpad_bufnr and vim.api.nvim_buf_is_valid(state.scratchpad_bufnr) then
    return state.scratchpad_bufnr
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  state.scratchpad_bufnr = bufnr
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "text"
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })
  pcall(vim.api.nvim_buf_set_name, bufnr, "flashcards://scratchpad")
  return bufnr
end

local function ensure_scratchpad_for_card(card_id)
  if state.scratchpad_card_id == card_id then
    ensure_scratchpad_buffer()
    return
  end

  close_scratchpad_window(true)
  local scratchpad = get_scratchpad_config()
  state.scratchpad_card_id = card_id
  state.scratchpad_visible_on_answer = scratchpad.show_on_answer ~= false
  state.scratchpad_footer_lines = 0
  ensure_scratchpad_buffer()
end

local function render_scratchpad_placeholder(lines, footer_lines)
  state.scratchpad_footer_lines = footer_lines or 0

  for _ = 1, scratchpad_total_height() do
    table.insert(lines, "")
  end
end

local function scratchpad_should_show()
  if not scratchpad_enabled() or not state.session or state.completed then
    return false
  end
  if state.showing_answer and not state.scratchpad_visible_on_answer then
    return false
  end
  return state.scratchpad_card_id ~= nil
end

local function scratchpad_float_config()
  if not state.popup or not state.popup.winid or not vim.api.nvim_win_is_valid(state.popup.winid) then
    return nil
  end

  local review_row, review_col = unpack(vim.api.nvim_win_get_position(state.popup.winid))
  local review_height = vim.api.nvim_win_get_height(state.popup.winid)
  local review_width = vim.api.nvim_win_get_width(state.popup.winid)
  local height = scratchpad_min_height()
  local total_height = scratchpad_total_height()
  local footer = state.scratchpad_footer_lines or 0
  local row = review_row + review_height - total_height - footer
  row = math.max(review_row, math.min(row, review_row + math.max(0, review_height - total_height)))

  local width = math.max(20, review_width - 4)
  width = math.min(width, math.max(1, review_width - 2))
  local col = review_col + math.max(0, math.floor((review_width - width) / 2))

  local focus_key = scratchpad_key("focus_scratchpad", "i")
  local clear_key = scratchpad_key("clear_scratchpad", "C")
  local title = string.format(" Scratchpad (%s focus, %s clear) ", focus_key, clear_key)
  if state.showing_answer then
    title = title .. string.format("[%s hide] ", scratchpad_key("toggle_scratchpad", "S"))
  end

  return {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = config.options.ui.border,
    title = title,
    title_pos = "center",
    zindex = 70,
  }
end

local function update_scratchpad_window()
  if not scratchpad_should_show() then
    close_scratchpad_window(false)
    return
  end

  local bufnr = ensure_scratchpad_buffer()
  local win_config = scratchpad_float_config()
  if not win_config then
    close_scratchpad_window(false)
    return
  end

  if state.scratchpad_winid and vim.api.nvim_win_is_valid(state.scratchpad_winid) then
    vim.api.nvim_win_set_config(state.scratchpad_winid, win_config)
  else
    state.scratchpad_winid = vim.api.nvim_open_win(bufnr, false, win_config)
    vim.wo[state.scratchpad_winid].wrap = true
    vim.wo[state.scratchpad_winid].linebreak = true
    vim.wo[state.scratchpad_winid].cursorline = false
    vim.wo[state.scratchpad_winid].winhl = "FloatBorder:FlashcardScratchpad"
  end
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

    -- Scratchpad header/status
    if line:match("^%s*Scratchpad") then
      vim.api.nvim_buf_add_highlight(bufnr, ns, "FlashcardScratchpad", i - 1, 0, -1)
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

  -- Button box highlights
  if state.button_hl then
    local bh = state.button_hl
    local byte_keys = { "top", "mid", "bot", "bottom" }
    for row = 0, 3 do
      local ln = bh.line_start + row
      local bk = byte_keys[row + 1]
      local col = bh.pad
      -- Wrong button
      vim.api.nvim_buf_add_highlight(bufnr, ns, "FlashcardWrong", ln, col, col + bh.wrong_bytes[bk])
      col = col + bh.wrong_bytes[bk] + bh.gap
      -- Correct button
      vim.api.nvim_buf_add_highlight(bufnr, ns, "FlashcardCorrect", ln, col, col + bh.correct_bytes[bk])
      col = col + bh.correct_bytes[bk] + bh.gap
      -- Quit button
      vim.api.nvim_buf_add_highlight(bufnr, ns, "Comment", ln, col, col + bh.quit_bytes[bk])
    end
    state.button_hl = nil
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

  state.completed = true
  state.showing_answer = false
  state.card_shown_at = nil
  reset_scratchpad()

  local bufnr = state.popup.bufnr
  stop_markdown_highlighting(bufnr)
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
  refresh_markdown_highlighting(bufnr)

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
  state.completed = false
  if scratchpad_enabled() then
    ensure_scratchpad_for_card(card.id)
  end

  local bufnr = state.popup.bufnr
  stop_markdown_highlighting(bufnr)
  vim.bo[bufnr].modifiable = true

  local lines = {}
  local icons = config.options.ui.icons
  local keymaps = config.options.ui.keymaps

  -- Determine display content based on reversed state. Trim display-only
  -- separator whitespace from older stored inline cards.
  local display_front = utils.trim_display_text(is_reversed and card.back or card.front)
  local display_back = utils.trim_display_text(is_reversed and card.front or card.back)

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

  -- Track when question is first shown for elapsed_ms timing. Do not reset on
  -- scratchpad re-renders while the user is still working on the same front.
  if not state.showing_answer and not state.card_shown_at then
    state.card_shown_at = vim.loop.hrtime()
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

    if scratchpad_enabled() then
      if state.scratchpad_visible_on_answer then
        local rating_footer_lines = 7
        append_bottom_spacer(lines, scratchpad_total_height() + rating_footer_lines)
        render_scratchpad_placeholder(lines, rating_footer_lines)
      else
        table.insert(lines, "")
        table.insert(lines, string.format(
          "  Scratchpad hidden (%s to show)",
          scratchpad_key("toggle_scratchpad", "S")
        ))
      end
    end

    -- Rating buttons with interval previews
    table.insert(lines, "")

    local intervals = state.session:preview_intervals()

    -- Format interval with due date for intervals >= 1 day
    local function fmt_interval(info)
      if not info then return "?" end
      if info.days >= 1 then
        local due_ts = utils.add_days(utils.now(), info.days)
        return info.formatted .. " (" .. os.date("%b %d", due_ts) .. ")"
      end
      return info.formatted
    end

    -- Build box buttons for each rating option
    local function make_button(key, label, interval_str)
      local title = key .. " " .. label
      local width = math.max(#title, #interval_str) + 2  -- 1 padding each side
      local top    = "\u{256d}" .. string.rep("\u{2500}", width) .. "\u{256e}"
      local mid    = "\u{2502}" .. " " .. title   .. string.rep(" ", width - 1 - #title)   .. "\u{2502}"
      local bot_ln = "\u{2502}" .. " " .. interval_str .. string.rep(" ", width - 1 - #interval_str) .. "\u{2502}"
      local bottom = "\u{2570}" .. string.rep("\u{2500}", width) .. "\u{256f}"
      return { top = top, mid = mid, bot_ln = bot_ln, bottom = bottom, width = width }
    end

    local wrong_interval = fmt_interval(intervals and intervals[fsrs.Rating.Wrong])
    local correct_interval = fmt_interval(intervals and intervals[fsrs.Rating.Correct])

    local btn_wrong   = make_button(keymaps.wrong, "Wrong", wrong_interval)
    local btn_correct = make_button(keymaps.correct, "Correct", correct_interval)
    local btn_quit    = make_button(keymaps.quit, "Quit", "")

    local gap = "  "
    local pad = "  "
    local btn_line_start = #lines  -- 0-indexed line of first button row
    table.insert(lines, pad .. btn_wrong.top    .. gap .. btn_correct.top    .. gap .. btn_quit.top)
    table.insert(lines, pad .. btn_wrong.mid    .. gap .. btn_correct.mid    .. gap .. btn_quit.mid)
    table.insert(lines, pad .. btn_wrong.bot_ln .. gap .. btn_correct.bot_ln .. gap .. btn_quit.bot_ln)
    table.insert(lines, pad .. btn_wrong.bottom .. gap .. btn_correct.bottom .. gap .. btn_quit.bottom)

    -- Store button layout for highlighting
    state.button_hl = {
      line_start = btn_line_start,
      pad = #pad,
      gap = #gap,
      wrong_bytes  = { top = #btn_wrong.top, mid = #btn_wrong.mid, bot = #btn_wrong.bot_ln, bottom = #btn_wrong.bottom },
      correct_bytes = { top = #btn_correct.top, mid = #btn_correct.mid, bot = #btn_correct.bot_ln, bottom = #btn_correct.bottom },
      quit_bytes = { top = #btn_quit.top, mid = #btn_quit.mid, bot = #btn_quit.bot_ln, bottom = #btn_quit.bottom },
    }

    table.insert(lines, "")
    local hints = {
      "n=Wrong",
      "y=Correct",
      string.format("%s=Skip", keymaps.skip),
      string.format("%s=Undo", keymaps.undo),
      string.format("%s=Edit", keymaps.edit),
    }
    if scratchpad_enabled() then
      table.insert(hints, string.format("%s=Scratchpad", scratchpad_key("focus_scratchpad", "i")))
      table.insert(hints, string.format("%s=Toggle pad", scratchpad_key("toggle_scratchpad", "S")))
    end
    table.insert(lines, "  (Also: " .. table.concat(hints, ", ") .. ")")
  else
    -- Keep the scratchpad near the bottom of the question view, directly above
    -- the reveal prompt. If a long front consumes the window, skip the spacer so
    -- no content is hidden just to force bottom alignment.
    local show_key = keymaps.show_answer or "<Space>"
    local prompt_lines = {
      "",
      "",
      string.format("  Press %s to show answer", show_key),
    }

    if scratchpad_enabled() then
      append_bottom_spacer(lines, scratchpad_total_height() + #prompt_lines)
      render_scratchpad_placeholder(lines, #prompt_lines)
      for _, line in ipairs(prompt_lines) do
        table.insert(lines, line)
      end
    else
      for _, line in ipairs(prompt_lines) do
        table.insert(lines, line)
      end
    end
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  apply_highlights(bufnr, lines)
  refresh_markdown_highlighting(bufnr)
  update_scratchpad_window()
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

  if scratchpad_enabled() then
    map(scratchpad_key("focus_scratchpad", "i"), function()
      M.focus_scratchpad()
    end, "Focus scratchpad")
    map(scratchpad_key("toggle_scratchpad", "S"), function()
      M.toggle_scratchpad()
    end, "Toggle scratchpad on answer")
    map(scratchpad_key("clear_scratchpad", "C"), function()
      M.clear_scratchpad()
    end, "Clear scratchpad")
  end
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Move the cursor into the scratchpad and enter insert mode.
function M.focus_scratchpad()
  if not scratchpad_enabled() then
    return
  end
  if state.completed or not state.session or not state.popup then
    return
  end

  local card = state.session:current_card()
  if not card then
    return
  end

  ensure_scratchpad_for_card(card.id)
  if state.showing_answer and not state.scratchpad_visible_on_answer then
    state.scratchpad_visible_on_answer = true
  end

  render_card()
  update_scratchpad_window()

  local winid = state.scratchpad_winid
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end

  vim.api.nvim_set_current_win(winid)
  vim.cmd("startinsert")
end

--- Toggle whether the scratchpad is shown while the answer/back is visible.
function M.toggle_scratchpad()
  if not scratchpad_enabled() or not state.session or state.completed then
    return
  end

  if not state.showing_answer then
    vim.notify("Scratchpad is always shown before revealing the answer", vim.log.levels.INFO)
    return
  end

  state.scratchpad_visible_on_answer = not state.scratchpad_visible_on_answer
  render_card()
end

--- Clear the current card's scratchpad contents.
function M.clear_scratchpad()
  if not scratchpad_enabled() or not state.session or state.completed then
    return
  end

  ensure_scratchpad_buffer()
  if state.scratchpad_bufnr and vim.api.nvim_buf_is_valid(state.scratchpad_bufnr) then
    vim.api.nvim_buf_set_lines(state.scratchpad_bufnr, 0, -1, false, { "" })
  end
  update_scratchpad_window()
end

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

  reset_scratchpad()
  state.showing_answer = false
  state.completed = false
  state.card_shown_at = nil
  state.session:next_card()
  render_card()
end

--- Reveal the answer for the current card.
function M.show_answer()
  if state.completed then
    return
  end

  if not state.showing_answer then
    state.showing_answer = true
    render_card()
  end
end

--- Answer the current card with a rating.
--- If the answer is not yet showing, reveals it instead.
--- @param rating number 0 (Wrong/false) or 1 (Correct/true)
function M.answer(rating)
  if not state.session or state.completed then
    return
  end

  if not state.showing_answer then
    M.show_answer()
    return
  end

  local elapsed_ms = 0
  if state.card_shown_at then
    elapsed_ms = math.floor((vim.loop.hrtime() - state.card_shown_at) / 1e6)
  end
  state.session:answer(rating, elapsed_ms)
  reset_scratchpad()
  state.card_shown_at = nil

  if state.session:next_card() then
    state.showing_answer = false
    render_card()
  else
    render_complete()
  end
end

--- Skip the current card, moving it to the end of the queue.
function M.skip()
  if not state.session or state.completed then
    return
  end

  reset_scratchpad()
  state.card_shown_at = nil
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
  if not state.session or state.completed then
    return
  end

  if state.session:undo() then
    reset_scratchpad()
    state.card_shown_at = nil
    state.showing_answer = true
    render_card()
  else
    vim.notify("Nothing to undo", vim.log.levels.INFO)
  end
end

--- Jump to the current card's source file for editing.
--- Closes the review session first.
function M.edit_card()
  if state.completed then
    return
  end

  local card = state.session and state.session:current_card()
  if not card then
    return
  end

  -- Resolve to absolute path from configured directories (with path traversal guard)
  local file_path = card.file_path
  local line_nr = card.line or 1
  local resolved = false
  for _, dir in ipairs(config.options.directories) do
    local abs = vim.fn.resolve(dir .. "/" .. file_path)
    if vim.fn.filereadable(abs) == 1 and utils.is_subpath(abs, dir) then
      file_path = abs
      resolved = true
      break
    end
  end

  if not resolved then
    vim.notify("Cannot resolve card file path: " .. file_path, vim.log.levels.ERROR)
    return
  end

  M.close()
  vim.cmd(string.format("edit +%d %s", line_nr, vim.fn.fnameescape(file_path)))
end

--- Close the review session and unmount the popup.
--- Shows a summary notification if any cards were reviewed.
function M.close()
  state.treesitter_seq = state.treesitter_seq + 1

  local popup = state.popup
  state.popup = nil
  if popup then
    popup:unmount()
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
  state.completed = false
  state.card_shown_at = nil
  reset_scratchpad()
end

--- Check whether a review session is currently active.
--- @return boolean
function M.is_active()
  return state.session ~= nil
end

return M
