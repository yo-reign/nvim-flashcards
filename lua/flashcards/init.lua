--- Plugin entry point for nvim-flashcards.
--- Manages setup, commands, autocommands, and lazy storage initialization.
--- @module flashcards
local M = {}

local config = require("flashcards.config")
local storage_factory = require("flashcards.storage")

-- Lazy-loaded storage instance
local _store = nil

--- Get or create the storage backend.
--- Initializes on first call, then returns the cached instance.
--- @return table storage backend instance
local function get_store()
  if not _store then
    local path = config.get_storage_path()
    _store = storage_factory.new(config.options.storage, path)
    _store:init()
  end
  return _store
end

-- ============================================================================
-- Setup
-- ============================================================================

--- Plugin setup. Merges user options, validates, registers commands and
--- autocommands, and optionally registers the telescope extension.
--- @param opts table|nil user configuration overrides
function M.setup(opts)
  config.setup(opts or {})

  -- Validate config
  local valid, err = config.validate()
  if not valid then
    vim.notify("nvim-flashcards: " .. err, vim.log.levels.ERROR)
    return
  end

  M._register_commands()

  if config.options.auto_sync then
    M._setup_autocommands()
  end

  -- Register telescope extension if telescope is available
  local ok, telescope_mod = pcall(require, "flashcards.telescope")
  if ok and telescope_mod.register then
    telescope_mod.register()
  end
end

-- ============================================================================
-- Commands
-- ============================================================================

--- Register all user commands.
function M._register_commands()
  vim.api.nvim_create_user_command("FlashcardsReview", function(cmd_opts)
    local tag = cmd_opts.args ~= "" and cmd_opts.args or nil
    if tag then
      tag = tag:gsub("^#", "")
    end
    require("flashcards.ui.review").start(get_store(), tag)
  end, { nargs = "?", desc = "Start flashcard review session" })

  vim.api.nvim_create_user_command("FlashcardsScan", function()
    local scanner = require("flashcards.scanner")
    local store = get_store()
    local report = scanner.scan(config.options.directories, store, config)
    store:save()
    vim.notify(string.format(
      "Scan complete: %d files, %d cards (%d new, %d updated), %d orphans, %d errors",
      report.files_scanned,
      report.cards_found,
      report.cards_new,
      report.cards_updated,
      report.orphans_found,
      #report.errors
    ), vim.log.levels.INFO)
    if #report.errors > 0 then
      for _, e in ipairs(report.errors) do
        local msg = e.file or ""
        if e.line then
          msg = msg .. ":" .. e.line
        end
        if e.message then
          msg = msg .. " " .. e.message
        end
        vim.notify("  " .. msg, vim.log.levels.WARN)
      end
    end
  end, { desc = "Rescan flashcard directories" })

  vim.api.nvim_create_user_command("FlashcardsStats", function()
    require("flashcards.ui.stats").show(get_store())
  end, { desc = "Show flashcard statistics" })

  vim.api.nvim_create_user_command("FlashcardsBrowse", function()
    require("flashcards.telescope").browse(get_store())
  end, { desc = "Browse all flashcards" })

  vim.api.nvim_create_user_command("FlashcardsDue", function()
    require("flashcards.telescope").due(get_store())
  end, { desc = "Browse due flashcards" })

  vim.api.nvim_create_user_command("FlashcardsTags", function()
    require("flashcards.telescope").tags(get_store())
  end, { desc = "Browse flashcard tags" })

  vim.api.nvim_create_user_command("FlashcardsOrphans", function()
    require("flashcards.telescope").orphans(get_store())
  end, { desc = "Manage orphaned flashcards" })
end

-- ============================================================================
-- Autocommands
-- ============================================================================

--- Set up autocommands for auto-sync on markdown file save.
--- Only triggers for files inside configured directories.
function M._setup_autocommands()
  local group = vim.api.nvim_create_augroup("FlashcardsAutoSync", { clear = true })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = { "*.md", "*.markdown" },
    callback = function(ev)
      local file_path = ev.file or vim.api.nvim_buf_get_name(ev.buf)
      local utils = require("flashcards.utils")

      -- Find which configured directory this file belongs to
      local scan_root = nil
      for _, dir in ipairs(config.options.directories) do
        if utils.is_subpath(file_path, dir) then
          scan_root = dir
          break
        end
      end

      if not scan_root then
        return
      end

      if config.should_ignore(file_path) then
        return
      end

      -- Scan just this file
      local scanner = require("flashcards.scanner")
      local store = get_store()
      scanner.scan_file(file_path, store, scan_root)
      store:save()
    end,
  })
end

-- ============================================================================
-- Health Check
-- ============================================================================

--- Health check for :checkhealth flashcards.
function M.health()
  local health = vim.health or require("health")
  local start = health.start or health.report_start
  local ok = health.ok or health.report_ok
  local warn = health.warn or health.report_warn
  local error_fn = health.error or health.report_error

  start("nvim-flashcards")

  -- Check required dependencies
  local deps = {
    { "plenary.nvim", "plenary" },
    { "nui.nvim", "nui.popup" },
    { "telescope.nvim", "telescope" },
  }

  for _, dep in ipairs(deps) do
    local dep_ok = pcall(require, dep[2])
    if dep_ok then
      ok(dep[1] .. " installed")
    else
      error_fn(dep[1] .. " not found")
    end
  end

  -- Check optional dependencies
  local sqlite_ok = pcall(require, "sqlite")
  if sqlite_ok then
    ok("sqlite.lua installed (optional)")
  else
    warn("sqlite.lua not installed (needed for SQLite storage backend)")
  end

  -- Check configuration state
  if config.options then
    ok("Configuration loaded")
    ok("Storage: " .. config.options.storage)
    ok("Directories: " .. table.concat(config.options.directories, ", "))
  else
    warn("Configuration not loaded (call setup() first)")
  end
end

-- ============================================================================
-- Public Accessors
-- ============================================================================

--- Get the storage backend instance for external use (e.g., statusline).
--- @return table storage backend instance
function M.get_store()
  return get_store()
end

return M
