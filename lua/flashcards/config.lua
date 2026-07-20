--- Configuration management for nvim-flashcards.
--- @module flashcards.config
local M = {}

local utils = require("flashcards.utils")

-- ============================================================================
-- Defaults
-- ============================================================================

M.defaults = {
  directories = {},
  storage = "sqlite", -- SQLite is the only supported backend
  db_path = nil, -- directory or file path; nil = first directory
  file_patterns = { "*.md", "*.markdown" },
  ignore_patterns = { "node_modules", ".git", ".obsidian", ".trash" },
  fsrs = {
    target_correctness = 0.85,
    maximum_interval = 365,
    enable_fuzz = true,
    -- Cap first review interval after learning; false disables.
    graduating_interval_days = 3,
    weights = {
      initial_stability_correct = 3.0,
      initial_stability_wrong = 0.5,
      learning_steps = { 1, 10, 60 },
    },
  },
  session = {
    -- false means unlimited. Set a non-negative integer to enforce a daily cap.
    new_cards_per_day = false,
  },
  media = {
    enabled = true,
    -- Extra local roots permitted in addition to configured scan directories.
    roots = {},
    images = {
      enabled = true,
      extensions = { "png", "jpg", "jpeg", "gif", "webp", "avif", "bmp", "svg" },
      max_width = 50,
      max_height = 18,
    },
    audio = {
      enabled = true,
      extensions = { "mp3", "wav", "ogg", "flac", "m4a", "aac", "opus" },
      -- false auto-detects mpv/ffplay/afplay/paplay; otherwise use an argv prefix list.
      player = false,
    },
  },
  ui = {
    width = 0.7,
    height = 0.6,
    border = "rounded",
    show_note = true,
    conceallevel = 0,
    concealcursor = "",
    keymaps = {
      show_answer = "<Space>",
      wrong = "0",
      correct = "1",
      quit = "q",
      skip = "s",
      undo = "u",
      edit = "e",
      play_audio = "p",
      open_media = "o",
    },
    icons = {
      correct = "v",
      wrong = "x",
      new = "*",
      learning = "o",
      review = "O",
      relearning = "o",
      suspended = "||",
      lost = "?",
    },
  },
  highlights = {
    FlashcardProgress = { link = "Comment" },
    FlashcardDivider = { link = "NonText" },
    FlashcardTag = { link = "Special" },
    FlashcardCorrect = { link = "DiagnosticOk" },
    FlashcardWrong = { link = "DiagnosticError" },
    FlashcardNew = { link = "DiagnosticInfo" },
    FlashcardLearning = { link = "DiagnosticWarn" },
    FlashcardReview = { link = "DiagnosticOk" },
    FlashcardLanguage = { link = "Comment" },
    FlashcardGood = { link = "DiagnosticOk" },
  },
  auto_sync = true,
}

--- The active merged config table. Set during setup().
--- @type table|nil
M.options = nil

-- ============================================================================
-- Setup
-- ============================================================================

--- Deep merge user options with defaults, normalize paths, and set highlights.
--- @param opts table|nil user configuration overrides
function M.setup(opts)
  opts = opts or {}
  M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts)

  -- Lists are configuration values, not maps. Replace defaults rather than
  -- retaining trailing default entries through tbl_deep_extend's table merge.
  if type(opts.media) == "table" then
    if type(opts.media.roots) == "table" then
      M.options.media.roots = vim.deepcopy(opts.media.roots)
    end
    if type(opts.media.images) == "table" and type(opts.media.images.extensions) == "table" then
      M.options.media.images.extensions = vim.deepcopy(opts.media.images.extensions)
    end
    if type(opts.media.audio) == "table" then
      if type(opts.media.audio.extensions) == "table" then
        M.options.media.audio.extensions = vim.deepcopy(opts.media.audio.extensions)
      end
      if type(opts.media.audio.player) == "table" then
        M.options.media.audio.player = vim.deepcopy(opts.media.audio.player)
      end
    end
  end

  -- Normalize directory paths
  for i, dir in ipairs(M.options.directories) do
    M.options.directories[i] = utils.normalize_path(dir)
  end
  if type(M.options.media) == "table" and type(M.options.media.roots) == "table" then
    for i, root in ipairs(M.options.media.roots) do
      if type(root) == "string" then
        M.options.media.roots[i] = utils.normalize_path(root)
      end
    end
  end

  -- Preserve raw db_path for directory detection, then normalize
  M._raw_db_path = M.options.db_path
  if M.options.db_path then
    M.options.db_path = utils.normalize_path(M.options.db_path)
  end

  -- Set up highlight groups
  for name, value in pairs(M.options.highlights) do
    vim.api.nvim_set_hl(0, name, value)
  end
end

-- ============================================================================
-- Storage Path Resolution
-- ============================================================================

--- Resolve db_path to a full file path for storage.
---
--- Logic:
---   - If db_path is nil, use the first directory from `directories`
---   - If db_path ends with "/" or is an existing directory, append the
---     database filename (`flashcards.db`)
---   - If db_path is an old `.json` file path, transparently use the same
---     path with `.db` so a sibling legacy JSON file can be migrated once
---   - Otherwise use db_path as-is
---   - Always normalizes the result via utils.normalize_path
---
--- @return string resolved file path
function M.get_storage_path()
  local opts = M.options
  local filename = "flashcards.db"

  local normalized_path = opts.db_path
  local from_directory = normalized_path == nil

  if from_directory then
    -- Use first configured directory; this is always a directory
    normalized_path = opts.directories[1]
  end

  if normalized_path == nil then
    error("flashcards: no db_path or directories configured")
  end

  local base = utils.normalize_path(normalized_path)

  -- Determine if the path refers to a directory:
  -- 1. It came from `directories` (always a directory)
  -- 2. Original (pre-normalized) db_path ended with "/" or "\"
  -- 3. Path exists as a directory on disk
  local raw_db = M._raw_db_path or ""
  local is_dir = from_directory
    or raw_db:sub(-1) == "/"
    or raw_db:sub(-1) == "\\"
    or vim.fn.isdirectory(base) == 1

  if is_dir then
    return utils.normalize_path(base .. "/" .. filename)
  end

  if base:sub(-5) == ".json" then
    return utils.normalize_path(base:sub(1, -6) .. ".db")
  end

  return base
end

-- ============================================================================
-- Validation
-- ============================================================================

local function is_finite_number(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
end

--- Validate the current configuration.
--- @return boolean ok
--- @return string|nil error_message (only when ok is false)
function M.validate()
  local opts = M.options
  if not opts then
    return false, "config.setup() has not been called"
  end

  -- directories must not be empty
  if not opts.directories or #opts.directories == 0 then
    return false, "directories must not be empty"
  end

  -- SQLite is the only supported storage backend. JSON was removed because
  -- whole-file persistence is too easy to corrupt and lose review history.
  if opts.storage ~= "sqlite" then
    return false, "storage must be \"sqlite\"; JSON storage is no longer supported, got: " .. tostring(opts.storage)
  end

  local media = opts.media
  if type(media) ~= "table" then
    return false, "media must be a table, got: " .. type(media)
  end
  if type(media.enabled) ~= "boolean" then
    return false, "media.enabled must be a boolean"
  end
  local is_list = vim.islist or vim.tbl_islist
  local function validate_string_list(value, name, allow_empty)
    if type(value) ~= "table" or not is_list(value) or (not allow_empty and #value == 0) then
      return false, name .. " must be " .. (allow_empty and "a list" or "a non-empty list") .. " of strings"
    end
    for index, entry in ipairs(value) do
      if type(entry) ~= "string" or entry == "" then
        return false, string.format("%s[%d] must be a non-empty string", name, index)
      end
    end
    return true
  end

  local roots_ok, roots_err = validate_string_list(media.roots, "media.roots", true)
  if not roots_ok then return false, roots_err end
  for _, section_name in ipairs({ "images", "audio" }) do
    local section = media[section_name]
    if type(section) ~= "table" then
      return false, "media." .. section_name .. " must be a table"
    end
    if type(section.enabled) ~= "boolean" then
      return false, "media." .. section_name .. ".enabled must be a boolean"
    end
    local extensions_ok, extensions_err = validate_string_list(
      section.extensions,
      "media." .. section_name .. ".extensions",
      false
    )
    if not extensions_ok then return false, extensions_err end
    for index, extension in ipairs(section.extensions) do
      if not extension:gsub("^%.", ""):match("^[%w]+$") then
        return false, string.format(
          "media.%s.extensions[%d] must be a simple file extension, got: %s",
          section_name,
          index,
          extension
        )
      end
    end
  end
  for _, field in ipairs({ "max_width", "max_height" }) do
    local value = media.images[field]
    if not is_finite_number(value) or value <= 0 or value % 1 ~= 0 then
      return false, "media.images." .. field .. " must be a positive integer"
    end
  end
  local player = media.audio.player
  if player ~= false then
    local player_ok, player_err = validate_string_list(player, "media.audio.player", false)
    if not player_ok then return false, player_err end
  end

  if type(opts.ui) ~= "table" or type(opts.ui.keymaps) ~= "table" then
    return false, "ui.keymaps must be a table"
  end
  for _, name in ipairs({ "play_audio", "open_media" }) do
    local key = opts.ui.keymaps[name]
    if type(key) ~= "string" or key == "" then
      return false, "ui.keymaps." .. name .. " must be a non-empty string"
    end
  end

  local session = opts.session
  if type(session) ~= "table" then
    return false, "session must be a table, got: " .. type(session)
  end
  local new_limit = session.new_cards_per_day
  if new_limit ~= false then
    if not is_finite_number(new_limit) or new_limit < 0 or new_limit % 1 ~= 0 then
      return false,
        "session.new_cards_per_day must be false (unlimited) or a non-negative integer, got: "
          .. tostring(new_limit)
    end
  end

  if type(opts.fsrs) ~= "table" then
    return false, "fsrs must be a table, got: " .. type(opts.fsrs)
  end

  -- target_correctness must be a finite number in [0.7, 0.97].
  local tc = opts.fsrs.target_correctness
  if not is_finite_number(tc) or tc < 0.7 or tc > 0.97 then
    return false, "fsrs.target_correctness must be a number between 0.7 and 0.97, got: " .. tostring(tc)
  end

  local weights = opts.fsrs.weights
  local steps = type(weights) == "table" and weights.learning_steps or nil
  if type(steps) ~= "table" or not is_list(steps) or #steps == 0 then
    return false, "fsrs.weights.learning_steps must be a non-empty list of positive numbers"
  end
  for index, step in ipairs(steps) do
    if not is_finite_number(step) or step <= 0 then
      return false, string.format(
        "fsrs.weights.learning_steps[%d] must be a positive finite number, got: %s",
        index,
        tostring(step)
      )
    end
  end

  -- graduating_interval_days caps the first review interval after learning.
  -- Use false to disable the cap for users who want the old behavior.
  local grad = opts.fsrs.graduating_interval_days
  if grad ~= nil and grad ~= false then
    if not is_finite_number(grad) or grad <= 0 then
      return false,
        "fsrs.graduating_interval_days must be a positive number or false, got: " .. tostring(grad)
    end
  end

  return true
end

-- ============================================================================
-- Ignore Patterns
-- ============================================================================

--- Check if a file path matches any of the configured ignore patterns.
--- Uses simple `string.find` substring matching.
--- @param filepath string the file path to check
--- @return boolean true if the path should be ignored
function M.should_ignore(filepath)
  local opts = M.options
  if not opts or not opts.ignore_patterns then
    return false
  end

  for _, pattern in ipairs(opts.ignore_patterns) do
    if filepath:find(pattern, 1, true) then
      return true
    end
  end

  return false
end

return M
