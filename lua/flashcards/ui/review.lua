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
local media = require("flashcards.media")
local components = require("flashcards.ui.components")

-- ============================================================================
-- Module State
-- ============================================================================

local state = {
  session = nil,
  popup = nil,
  showing_answer = false,
  completed = false,
  waiting_for_repeat = false,
  repeat_timer = nil,
  repeat_timer_seq = 0,
  card_shown_at = nil,
  treesitter_seq = 0,
  media_seq = 0,
  audio_seq = 0,
  image_handles = {},
  audio_job = nil,
  visible_media = {},
  visible_images = {},
  current_audio = nil,
  media_augroup = nil,
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
-- Review media lifecycle
-- ============================================================================

local function clear_media_autocmds()
  local group = state.media_augroup
  state.media_augroup = nil
  if group then
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end
end

local function stop_audio()
  state.audio_seq = state.audio_seq + 1
  local job_id = state.audio_job
  state.audio_job = nil
  media.stop_audio(job_id)
end

local function clear_media()
  state.media_seq = state.media_seq + 1
  stop_audio()
  media.clear_images(state.image_handles)
  state.image_handles = {}
  state.visible_media = {}
  state.visible_images = {}
  state.current_audio = nil
end

local function append_media_content(lines, content, card)
  local plan = media.extract(
    content,
    card.file_path,
    config.options.directories,
    config.options.media
  )
  local first_row = #lines
  for _, line in ipairs(plan.lines) do
    lines[#lines + 1] = "  " .. line
  end
  for _, item in ipairs(plan.items) do
    item.row = first_row + item.line - 1
    state.visible_media[#state.visible_media + 1] = item
  end
  for _, image in ipairs(plan.images) do
    image.row = first_row + image.line - 1
    state.visible_images[#state.visible_images + 1] = image
  end
  return plan
end

local function schedule_visible_images()
  if #state.visible_images == 0 or not state.popup then
    return
  end
  local sequence = state.media_seq
  local popup = state.popup
  local images = vim.deepcopy(state.visible_images)
  vim.schedule(function()
    if sequence ~= state.media_seq or state.popup ~= popup then
      return
    end
    if not popup.winid or not vim.api.nvim_win_is_valid(popup.winid)
      or not vim.api.nvim_buf_is_valid(popup.bufnr) then
      return
    end

    local handles = media.render_images(images, {
      window = popup.winid,
      buffer = popup.bufnr,
    }, config.options.media.images)
    if sequence ~= state.media_seq or state.popup ~= popup then
      media.clear_images(handles)
      return
    end
    for _, handle in ipairs(handles) do
      state.image_handles[#state.image_handles + 1] = handle
    end
  end)
end

-- ============================================================================
-- Card Rendering
-- ============================================================================

--- Render the session completion summary screen.
local function render_complete()
  if not state.popup or not state.session then
    return
  end

  clear_media()
  state.completed = true
  state.showing_answer = false
  state.card_shown_at = nil

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
  table.insert(lines, string.format("  Answer accuracy:  %s", components.percentage(summary.answer_accuracy)))
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

--- Render the waiting screen while future learning repeats remain pending.
local function render_waiting()
  if not state.popup or not state.session then
    return
  end

  local due_at = state.session:next_pending_due()
  if not due_at then
    return
  end

  clear_media()
  state.completed = false
  state.waiting_for_repeat = true
  state.showing_answer = false
  state.card_shown_at = nil

  local remaining_days = math.max(0, due_at - utils.now()) / 86400
  local lines = {
    "",
    "  Waiting for Learning Card",
    "",
    "  " .. string.rep("─", 40),
    "",
    "  Next card due in: " .. utils.format_interval(remaining_days),
    "  Due at:           " .. utils.format_datetime(due_at),
    "",
    "  This review session will resume automatically.",
    "",
    "  Press u to undo the last answer, or q/<Esc> to quit.",
  }

  local bufnr = state.popup.bufnr
  stop_markdown_highlighting(bufnr)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  apply_highlights(bufnr, lines)
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
  clear_media()
  state.completed = false
  state.waiting_for_repeat = false

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

  -- Front media is available with the question. Answer-side content is not
  -- extracted or resolved until the user explicitly reveals the answer.
  local front_plan = append_media_content(lines, add_language_labels(display_front), card)
  state.current_audio = front_plan.audio[1]

  -- Track when question is shown for elapsed_ms timing
  if not state.showing_answer then
    state.card_shown_at = vim.loop.hrtime()
  end

  if state.showing_answer then
    -- Divider
    table.insert(lines, "")
    table.insert(lines, "  " .. string.rep("\u{2500}", 50))
    table.insert(lines, "")

    -- Back media is resolved only after answer reveal, preventing image/audio
    -- filenames, filesystem probes, and playback from leaking the answer.
    local back_plan = append_media_content(lines, add_language_labels(display_back), card)
    state.current_audio = back_plan.audio[1] or state.current_audio

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
    table.insert(lines, string.format(
      "  (Also: n=Wrong, y=Correct, %s=Skip, %s=Undo, %s=Edit, %s=Audio, %s=Open media)",
      keymaps.skip,
      keymaps.undo,
      keymaps.edit,
      keymaps.play_audio,
      keymaps.open_media
    ))
  else
    -- Prompt to reveal answer
    table.insert(lines, "")
    table.insert(lines, "")
    local show_key = keymaps.show_answer or "<Space>"
    table.insert(lines, string.format("  Press %s to show answer", show_key))
    if state.current_audio then
      table.insert(lines, string.format("  Press %s to play audio", keymaps.play_audio))
    end
    if #state.visible_media > 0 then
      table.insert(lines, string.format("  Press %s to open media externally", keymaps.open_media))
    end
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  apply_highlights(bufnr, lines)
  refresh_markdown_highlighting(bufnr)
  schedule_visible_images()
end

-- ============================================================================
-- Due-aware repeat timer
-- ============================================================================

local function close_timer(timer)
  if not timer then
    return
  end
  pcall(function() timer:stop() end)
  local closing = false
  pcall(function() closing = timer:is_closing() end)
  if not closing then
    pcall(function() timer:close() end)
  end
end

local function cancel_repeat_timer()
  state.repeat_timer_seq = state.repeat_timer_seq + 1
  local timer = state.repeat_timer
  state.repeat_timer = nil
  close_timer(timer)
end

local sync_repeat_timer
local advance_or_wait_or_complete

sync_repeat_timer = function()
  cancel_repeat_timer()
  if not state.session or not state.popup then
    return
  end

  local due_at = state.session:next_pending_due()
  if not due_at then
    return
  end

  local uv = vim.uv or vim.loop
  local timer = uv and uv.new_timer and uv.new_timer() or nil
  if not timer then
    vim.notify("Unable to schedule the next learning-card repeat", vim.log.levels.ERROR)
    return
  end

  local sequence = state.repeat_timer_seq
  local session = state.session
  local delay_ms = math.max(0, math.ceil((due_at - utils.now()) * 1000))
  state.repeat_timer = timer

  local callback = vim.schedule_wrap(function()
    if state.repeat_timer_seq ~= sequence or state.session ~= session or not state.popup then
      close_timer(timer)
      return
    end

    state.repeat_timer = nil
    close_timer(timer)
    local released = session:release_due_repeats(utils.now())
    if #released > 0 and state.waiting_for_repeat then
      advance_or_wait_or_complete()
    else
      -- If the clock moved backward, this re-arms once for the corrected due
      -- time. Otherwise it arms the next pending 10m/1h learning step.
      sync_repeat_timer()
    end
  end)

  local ok, err = pcall(function()
    timer:start(delay_ms, 0, callback)
  end)
  if not ok then
    state.repeat_timer = nil
    close_timer(timer)
    vim.notify("Unable to schedule learning-card repeat: " .. tostring(err), vim.log.levels.ERROR)
  end
end

advance_or_wait_or_complete = function()
  if not state.session then
    return
  end

  if state.session:next_card() then
    state.waiting_for_repeat = false
    state.completed = false
    state.showing_answer = false
    state.card_shown_at = nil
    render_card()
    sync_repeat_timer()
  elseif state.session:has_pending_repeats() then
    render_waiting()
    sync_repeat_timer()
  else
    state.waiting_for_repeat = false
    cancel_repeat_timer()
    render_complete()
  end
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
  map(keymaps.play_audio, function()
    M.play_audio()
  end, "Play card audio")
  map(keymaps.open_media, function()
    M.open_media()
  end, "Open card media externally")
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Start a review session.
--- Creates a scheduler session, builds the review queue, and opens the floating window.
--- @param store table storage backend instance
--- @param tag string|nil optional tag filter
--- @param start_opts table|nil options: { priority_card_id }
function M.start(store, tag, start_opts)
  -- Prevent opening multiple review sessions
  if state.session then
    vim.notify("A review session is already active", vim.log.levels.WARN)
    return
  end

  cancel_repeat_timer()
  clear_media()
  state.waiting_for_repeat = false
  start_opts = start_opts or {}
  local fsrs_instance = fsrs.new(config.options.fsrs)
  local opts = {
    tag = tag,
    new_cards_per_day = config.options.session.new_cards_per_day,
    priority_card_id = start_opts.priority_card_id,
  }
  state.session = scheduler.new_session(store, fsrs_instance, opts)
  state.session:load_cards()

  if #state.session.queue == 0 then
    if state.session.deferred_new_count > 0 then
      vim.notify(string.format(
        "Daily new-card limit reached; %d new cards are deferred.",
        state.session.deferred_new_count
      ), vim.log.levels.INFO)
    else
      vim.notify("No cards available for review!", vim.log.levels.INFO)
    end
    state.session = nil
    return
  end

  state.popup = create_popup()
  state.popup:mount()
  setup_keymaps(state.popup)

  local popup = state.popup
  clear_media_autocmds()
  state.media_augroup = vim.api.nvim_create_augroup("FlashcardsReviewMedia", { clear = true })
  if popup.winid then
    vim.api.nvim_create_autocmd("WinClosed", {
      group = state.media_augroup,
      pattern = tostring(popup.winid),
      once = true,
      callback = function()
        if state.popup == popup then
          M.close()
        end
      end,
    })
  end
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = state.media_augroup,
    once = true,
    callback = function()
      if state.popup == popup then
        clear_media()
      end
    end,
  })

  state.showing_answer = false
  state.completed = false
  state.session:next_card()
  render_card()
end

--- Reveal the answer for the current card.
function M.show_answer()
  if state.completed or state.waiting_for_repeat then
    return
  end

  if not state.showing_answer then
    state.showing_answer = true
    render_card()
  end
end

--- Play the preferred audio reference on the currently visible card side.
function M.play_audio()
  if not state.session or state.completed or state.waiting_for_repeat then
    return
  end
  if not state.current_audio then
    vim.notify("No audio is available on the visible card side", vim.log.levels.INFO)
    return
  end

  stop_audio()
  local sequence = state.audio_seq
  local job_id, err = media.play_audio(state.current_audio, config.options.media.audio, function(id, exit_code)
    if sequence == state.audio_seq and state.audio_job == id then
      state.audio_job = nil
      if exit_code ~= 0 then
        vim.notify("Card audio player exited with code " .. tostring(exit_code), vim.log.levels.WARN)
      end
    end
  end)
  if not job_id then
    vim.notify("Unable to play card audio: " .. tostring(err), vim.log.levels.WARN)
    return
  end
  state.audio_job = job_id
end

--- Open the media item under the cursor, or the preferred visible item.
function M.open_media()
  if not state.session or state.completed or state.waiting_for_repeat then
    return
  end

  local selected = nil
  if state.popup and state.popup.winid and vim.api.nvim_win_is_valid(state.popup.winid) then
    local cursor_row = vim.api.nvim_win_get_cursor(state.popup.winid)[1] - 1
    for _, item in ipairs(state.visible_media) do
      if item.row == cursor_row then
        selected = item
        break
      end
    end
  end
  if not selected and state.current_audio and state.current_audio.path then
    selected = state.current_audio
  end
  if not selected then
    for _, item in ipairs(state.visible_media) do
      if item.path then
        selected = item
        break
      end
    end
  end
  selected = selected or state.visible_media[1]
  if not selected then
    vim.notify("No media is available on the visible card", vim.log.levels.INFO)
    return
  end

  local ok, err = media.open_external(selected)
  if not ok then
    vim.notify("Unable to open card media: " .. tostring(err), vim.log.levels.WARN)
  end
end

--- Format the informational message for a future learning/relearning step.
--- @param result table|nil scheduling result returned by Session:answer
--- @return string|nil message
function M.deferred_step_message(result)
  if not result or not result.deferred or not result.state or not result.intervals then
    return nil
  end
  local status = result.state.status
  local formatted = result.intervals.formatted
  if not status or not formatted then
    return nil
  end
  return string.format(
    "Next %s step is due in %s; this session will resume automatically.",
    fsrs.state_name(status),
    formatted
  )
end

--- Answer the current card with a rating.
--- If the answer is not yet showing, reveals it instead.
--- @param rating number 0 (Wrong/false) or 1 (Correct/true)
function M.answer(rating)
  if not state.session or state.completed or state.waiting_for_repeat then
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
  local result = state.session:answer(rating, elapsed_ms)
  local deferred_message = M.deferred_step_message(result)
  if deferred_message then
    vim.notify(deferred_message, vim.log.levels.INFO)
  end

  advance_or_wait_or_complete()
end

--- Skip the current card, moving it to the end of the queue.
function M.skip()
  if not state.session or state.completed or state.waiting_for_repeat then
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
  if not state.session or state.completed then
    return
  end

  local was_waiting = state.waiting_for_repeat
  cancel_repeat_timer()
  if state.session:undo() then
    state.waiting_for_repeat = false
    -- The restored card is shown with its answer already visible; do not reuse
    -- the next card's question timer as this card's review duration.
    state.card_shown_at = nil
    state.showing_answer = true
    render_card()
    sync_repeat_timer()
  else
    vim.notify("Nothing to undo", vim.log.levels.INFO)
    if was_waiting then
      render_waiting()
    end
    sync_repeat_timer()
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

  -- Resolve canonical source paths and legacy root-relative paths inside the
  -- configured directories before opening an editor buffer.
  local stored_path = card.file_path
  local file_path = utils.resolve_card_path(stored_path, config.options.directories)
  local line_nr = card.line or 1
  if not file_path then
    vim.notify("Cannot resolve card file path: " .. stored_path, vim.log.levels.ERROR)
    return
  end

  M.close()
  vim.cmd(string.format("edit +%d %s", line_nr, vim.fn.fnameescape(file_path)))
end

--- Close the review session and unmount the popup.
--- Shows a summary notification if any cards were reviewed.
function M.close()
  state.treesitter_seq = state.treesitter_seq + 1
  cancel_repeat_timer()
  clear_media()
  clear_media_autocmds()

  local popup = state.popup
  state.popup = nil
  if popup then
    pcall(function() popup:unmount() end)
  end

  if state.session then
    state.session:clear_pending_repeats()
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
          components.percentage(summary.answer_accuracy)
        ),
        vim.log.levels.INFO
      )
    end
    state.session = nil
  end

  state.showing_answer = false
  state.completed = false
  state.waiting_for_repeat = false
  state.card_shown_at = nil
end

--- Check whether a review session is currently active.
--- @return boolean
function M.is_active()
  return state.session ~= nil
end

return M
