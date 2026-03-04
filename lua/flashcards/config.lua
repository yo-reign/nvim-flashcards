--- Configuration management for nvim-flashcards.
--- @module flashcards.config
local M = {}

local utils = require("flashcards.utils")

-- ============================================================================
-- Defaults
-- ============================================================================

M.defaults = {
  directories = {},
  storage = "json", -- "json" or "sqlite"
  db_path = nil, -- directory or file path; nil = first directory
  file_patterns = { "*.md", "*.markdown" },
  ignore_patterns = { "node_modules", ".git", ".obsidian", ".trash" },
  fsrs = {
    target_correctness = 0.85,
    maximum_interval = 365,
    enable_fuzz = true,
    weights = {
      initial_stability_correct = 3.0,
      initial_stability_wrong = 0.5,
      learning_steps = { 1, 10, 60 },
    },
  },
  session = {
    new_cards_per_day = 20,
  },
  ui = {
    width = 0.7,
    height = 0.6,
    border = "rounded",
    show_note = true,
    keymaps = {
      show_answer = "<Space>",
      wrong = "1",
      correct = "0",
      quit = "q",
      skip = "s",
      undo = "u",
      edit = "e",
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

  -- Normalize directory paths
  for i, dir in ipairs(M.options.directories) do
    M.options.directories[i] = utils.normalize_path(dir)
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
---     appropriate filename (`flashcards.json` or `flashcards.db`)
---   - Otherwise use db_path as-is
---   - Always normalizes the result via utils.normalize_path
---
--- @return string resolved file path
function M.get_storage_path()
  local opts = M.options
  local storage_type = opts.storage
  local filename = storage_type == "sqlite" and "flashcards.db" or "flashcards.json"

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

  return base
end

-- ============================================================================
-- Validation
-- ============================================================================

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

  -- storage must be "json" or "sqlite"
  if opts.storage ~= "json" and opts.storage ~= "sqlite" then
    return false, "storage must be \"json\" or \"sqlite\", got: " .. tostring(opts.storage)
  end

  -- target_correctness must be in [0.7, 0.97]
  local tc = opts.fsrs and opts.fsrs.target_correctness
  if tc then
    if type(tc) ~= "number" or tc < 0.7 or tc > 0.97 then
      return false, "fsrs.target_correctness must be a number between 0.7 and 0.97, got: " .. tostring(tc)
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
