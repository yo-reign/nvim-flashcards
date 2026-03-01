--- Telescope pickers for nvim-flashcards.
--- Provides browse, due, tags, search, and orphans pickers.
--- @module flashcards.telescope
local has_telescope, telescope = pcall(require, "telescope")
if not has_telescope then
  return {}
end

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local previewers = require("telescope.previewers")

local config = require("flashcards.config")
local fsrs = require("flashcards.fsrs")
local utils = require("flashcards.utils")

local M = {}

-- ============================================================================
-- Shared Helpers
-- ============================================================================

--- Resolve a relative card file_path to an absolute path.
--- @param file_path string relative path from card
--- @return string absolute path (or original if not resolved)
--- Resolve a relative card file_path to an absolute path.
--- Uses vim.fn.resolve() to canonicalize and validates the result
--- stays within configured directories (path traversal guard).
--- @param file_path string relative path from card
--- @return string|nil absolute path, or nil if path escapes configured directories
local function resolve_path(file_path)
  if not config.options or not config.options.directories then
    return nil
  end
  for _, dir in ipairs(config.options.directories) do
    local abs = vim.fn.resolve(dir .. "/" .. file_path)
    if vim.fn.filereadable(abs) == 1 and utils.is_subpath(abs, dir) then
      return abs
    end
  end
  return nil
end

--- Get the state icon for a card status from config.
--- @param status string card state ("new", "learning", "review", "relearning")
--- @return string icon
local function state_icon(status)
  local icons = config.options and config.options.ui and config.options.ui.icons or {}
  return icons[status] or ""
end

--- Get the lost icon from config.
--- @return string icon
local function lost_icon()
  local icons = config.options and config.options.ui and config.options.ui.icons or {}
  return icons.lost or "?"
end

--- Flatten multiline text to a single line for display.
--- Replaces newlines and collapses whitespace.
--- @param text string
--- @return string
local function flatten(text)
  if not text then
    return ""
  end
  return text:gsub("\n", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
end

-- ============================================================================
-- Card Previewer (shared)
-- ============================================================================

--- Create a buffer previewer that shows card details.
--- Shows: front, divider, back, tags, note (if present), state info.
--- @param store table storage backend instance
--- @return table telescope previewer
local function card_previewer(store)
  return previewers.new_buffer_previewer({
    title = "Card Preview",
    define_preview = function(self, entry)
      local card = entry.value
      if not card then
        return
      end

      local lines = {}
      local bufnr = self.state.bufnr

      -- Front
      table.insert(lines, "## Front")
      table.insert(lines, "")
      for _, line in ipairs(utils.lines(card.front)) do
        table.insert(lines, line)
      end

      -- Divider
      table.insert(lines, "")
      table.insert(lines, string.rep("\u{2500}", 40))
      table.insert(lines, "")

      -- Back
      table.insert(lines, "## Back")
      table.insert(lines, "")
      for _, line in ipairs(utils.lines(card.back)) do
        table.insert(lines, line)
      end

      -- Tags
      if card.tags and #card.tags > 0 then
        table.insert(lines, "")
        local tag_parts = {}
        for _, tag in ipairs(card.tags) do
          table.insert(tag_parts, "#" .. tag)
        end
        table.insert(lines, table.concat(tag_parts, " "))
      end

      -- Note
      if card.note then
        table.insert(lines, "")
        table.insert(lines, "[" .. card.note .. "]")
      end

      -- State info
      local card_state = store:get_card_state(card.id)
      if card_state then
        table.insert(lines, "")
        table.insert(lines, string.rep("\u{2500}", 40))
        table.insert(lines, "")
        table.insert(lines, "Status:    " .. fsrs.state_name(card_state.status or "new"))
        if card_state.due_date then
          table.insert(lines, "Due:       " .. utils.format_datetime(card_state.due_date))
        end
        if card_state.stability and card_state.stability > 0 then
          table.insert(lines, string.format("Stability: %.1f days", card_state.stability))
        end
        if card_state.reps and card_state.reps > 0 then
          table.insert(lines, string.format("Reviews:   %d", card_state.reps))
        end
        if card_state.lapses and card_state.lapses > 0 then
          table.insert(lines, string.format("Lapses:    %d", card_state.lapses))
        end
      end

      -- Reversible indicator
      if card.reversible then
        table.insert(lines, "")
        table.insert(lines, "\u{2194} Reversible")
      end

      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.bo[bufnr].filetype = "markdown"
    end,
  })
end

-- ============================================================================
-- Card Entry Maker (shared)
-- ============================================================================

--- Create an entry maker for card results.
--- Display: {state_icon} {front_preview_truncated_to_60}
--- Ordinal: front .. " " .. back (for search)
--- @param store table storage backend instance
--- @return function entry maker
local function card_entry_maker(store)
  return function(card)
    local card_state = store:get_card_state(card.id)
    local status = (card_state and card_state.status) or "new"
    local icon = state_icon(status)
    local front_flat = flatten(card.front)
    local display = icon .. " " .. utils.truncate(front_flat, 60)
    local ordinal = flatten(card.front) .. " " .. flatten(card.back)

    return {
      value = card,
      display = display,
      ordinal = ordinal,
      path = card.file_path,
      lnum = card.line or 1,
    }
  end
end

-- ============================================================================
-- Browse Picker
-- ============================================================================

--- Browse all active cards with preview.
--- Default action: open source file at line.
--- <C-r>: start review with card's first tag.
--- @param store table storage backend instance
--- @param opts table|nil telescope picker options
function M.browse(store, opts)
  opts = opts or {}

  local cards = store:get_all_cards()
  if #cards == 0 then
    vim.notify("No cards found", vim.log.levels.INFO)
    return
  end

  pickers.new(opts, {
    prompt_title = "Browse Cards",
    finder = finders.new_table({
      results = cards,
      entry_maker = card_entry_maker(store),
    }),
    sorter = conf.generic_sorter(opts),
    previewer = card_previewer(store),
    attach_mappings = function(prompt_bufnr, map)
      -- Default action: open source file at line
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local entry = action_state.get_selected_entry()
        if entry and entry.value then
          local card = entry.value
          local abs = resolve_path(card.file_path)
          if abs then
            vim.cmd(string.format("edit +%d %s", card.line or 1, vim.fn.fnameescape(abs)))
          else
            vim.notify("Cannot resolve card file path: " .. card.file_path, vim.log.levels.ERROR)
          end
        end
      end)

      -- <C-r>: start review with card's first tag
      map("i", "<C-r>", function()
        actions.close(prompt_bufnr)
        local entry = action_state.get_selected_entry()
        if entry and entry.value then
          local card = entry.value
          local tag = card.tags and card.tags[1] or nil
          require("flashcards.ui.review").start(store, tag)
        end
      end)
      map("n", "<C-r>", function()
        actions.close(prompt_bufnr)
        local entry = action_state.get_selected_entry()
        if entry and entry.value then
          local card = entry.value
          local tag = card.tags and card.tags[1] or nil
          require("flashcards.ui.review").start(store, tag)
        end
      end)

      return true
    end,
  }):find()
end

-- ============================================================================
-- Due Picker
-- ============================================================================

--- Browse cards due for review.
--- Default action: start review session.
--- <C-e>: edit card source.
--- @param store table storage backend instance
--- @param opts table|nil telescope picker options
function M.due(store, opts)
  opts = opts or {}

  local cards = store:get_due_cards()
  if #cards == 0 then
    vim.notify("No cards due for review", vim.log.levels.INFO)
    return
  end

  pickers.new(opts, {
    prompt_title = "Due Cards",
    finder = finders.new_table({
      results = cards,
      entry_maker = card_entry_maker(store),
    }),
    sorter = conf.generic_sorter(opts),
    previewer = card_previewer(store),
    attach_mappings = function(prompt_bufnr, map)
      -- Default action: start review session
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        require("flashcards.ui.review").start(store)
      end)

      -- <C-e>: edit card source
      local edit_card = function()
        actions.close(prompt_bufnr)
        local entry = action_state.get_selected_entry()
        if entry and entry.value then
          local card = entry.value
          local abs = resolve_path(card.file_path)
          if abs then
            vim.cmd(string.format("edit +%d %s", card.line or 1, vim.fn.fnameescape(abs)))
          else
            vim.notify("Cannot resolve card file path: " .. card.file_path, vim.log.levels.ERROR)
          end
        end
      end
      map("i", "<C-e>", edit_card)
      map("n", "<C-e>", edit_card)

      return true
    end,
  }):find()
end

-- ============================================================================
-- Tags Picker
-- ============================================================================

--- Browse tags with card counts.
--- Display: #tag (N cards)
--- Default action: start review with that tag.
--- <C-b>: browse cards filtered by tag.
--- @param store table storage backend instance
--- @param opts table|nil telescope picker options
function M.tags(store, opts)
  opts = opts or {}

  local all_tags = store:get_all_tags()
  if #all_tags == 0 then
    vim.notify("No tags found", vim.log.levels.INFO)
    return
  end

  pickers.new(opts, {
    prompt_title = "Tags",
    finder = finders.new_table({
      results = all_tags,
      entry_maker = function(tag_entry)
        local display = string.format("#%s (%d cards)", tag_entry.tag, tag_entry.count)
        return {
          value = tag_entry,
          display = display,
          ordinal = tag_entry.tag,
        }
      end,
    }),
    sorter = conf.generic_sorter(opts),
    attach_mappings = function(prompt_bufnr, map)
      -- Default action: start review with that tag
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local entry = action_state.get_selected_entry()
        if entry and entry.value then
          require("flashcards.ui.review").start(store, entry.value.tag)
        end
      end)

      -- <C-b>: browse cards with that tag
      local browse_by_tag = function()
        actions.close(prompt_bufnr)
        local entry = action_state.get_selected_entry()
        if entry and entry.value then
          local tag = entry.value.tag
          local cards = store:get_cards_by_tag(tag)
          if #cards == 0 then
            vim.notify("No cards with tag #" .. tag, vim.log.levels.INFO)
            return
          end
          -- Open a browse picker filtered to these cards
          pickers.new(opts, {
            prompt_title = "Cards: #" .. tag,
            finder = finders.new_table({
              results = cards,
              entry_maker = card_entry_maker(store),
            }),
            sorter = conf.generic_sorter(opts),
            previewer = card_previewer(store),
            attach_mappings = function(inner_bufnr)
              actions.select_default:replace(function()
                actions.close(inner_bufnr)
                local inner_entry = action_state.get_selected_entry()
                if inner_entry and inner_entry.value then
                  local card = inner_entry.value
                  local abs = resolve_path(card.file_path)
                  if abs then
                    vim.cmd(string.format("edit +%d %s", card.line or 1, vim.fn.fnameescape(abs)))
                  else
                    vim.notify("Cannot resolve card file path: " .. card.file_path, vim.log.levels.ERROR)
                  end
                end
              end)
              return true
            end,
          }):find()
        end
      end
      map("i", "<C-b>", browse_by_tag)
      map("n", "<C-b>", browse_by_tag)

      return true
    end,
  }):find()
end

-- ============================================================================
-- Search Picker
-- ============================================================================

--- Full-text search across front, back, and tags.
--- Display: front_preview | back_preview
--- Default action: open source file.
--- @param store table storage backend instance
--- @param opts table|nil telescope picker options
function M.search(store, opts)
  opts = opts or {}

  local cards = store:get_all_cards()
  if #cards == 0 then
    vim.notify("No cards found", vim.log.levels.INFO)
    return
  end

  pickers.new(opts, {
    prompt_title = "Search Cards",
    finder = finders.new_table({
      results = cards,
      entry_maker = function(card)
        local front_flat = flatten(card.front)
        local back_flat = flatten(card.back)
        local front_preview = utils.truncate(front_flat, 35)
        local back_preview = utils.truncate(back_flat, 35)
        local display = front_preview .. " | " .. back_preview

        -- Include tags in ordinal for full-text search
        local tag_str = ""
        if card.tags and #card.tags > 0 then
          tag_str = " " .. table.concat(card.tags, " ")
        end
        local ordinal = front_flat .. " " .. back_flat .. tag_str

        return {
          value = card,
          display = display,
          ordinal = ordinal,
          path = card.file_path,
          lnum = card.line or 1,
        }
      end,
    }),
    sorter = conf.generic_sorter(opts),
    previewer = card_previewer(store),
    attach_mappings = function(prompt_bufnr)
      -- Default action: open source file
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local entry = action_state.get_selected_entry()
        if entry and entry.value then
          local card = entry.value
          local abs = resolve_path(card.file_path)
          if abs then
            vim.cmd(string.format("edit +%d %s", card.line or 1, vim.fn.fnameescape(abs)))
          else
            vim.notify("Cannot resolve card file path: " .. card.file_path, vim.log.levels.ERROR)
          end
        end
      end)
      return true
    end,
  }):find()
end

-- ============================================================================
-- Orphans Picker
-- ============================================================================

--- Manage orphaned (inactive/lost) cards.
--- Display: {lost_icon} {front_preview} (lost: {date})
--- Default action: permanently delete card (with confirmation).
--- <C-r>: reactivate card.
--- <C-d>: delete all orphans.
--- @param store table storage backend instance
--- @param opts table|nil telescope picker options
function M.orphans(store, opts)
  opts = opts or {}

  local orphaned = store:get_orphaned_cards()
  if #orphaned == 0 then
    vim.notify("No orphaned cards", vim.log.levels.INFO)
    return
  end

  pickers.new(opts, {
    prompt_title = "Orphaned Cards",
    finder = finders.new_table({
      results = orphaned,
      entry_maker = function(card)
        local icon = lost_icon()
        local front_flat = flatten(card.front)
        local front_preview = utils.truncate(front_flat, 50)
        local lost_date = card.lost_at and utils.format_date(card.lost_at) or "unknown"
        local display = icon .. " " .. front_preview .. " (lost: " .. lost_date .. ")"

        return {
          value = card,
          display = display,
          ordinal = flatten(card.front) .. " " .. flatten(card.back),
        }
      end,
    }),
    sorter = conf.generic_sorter(opts),
    previewer = card_previewer(store),
    attach_mappings = function(prompt_bufnr, map)
      -- Default action: permanently delete card (with confirmation)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        if not entry or not entry.value then
          return
        end
        local card = entry.value
        local front_preview = utils.truncate(flatten(card.front), 40)
        vim.ui.select({ "Yes", "No" }, {
          prompt = "Delete card: " .. front_preview .. "?",
        }, function(choice)
          if choice == "Yes" then
            store:delete_card(card.id)
            store:save()
            vim.notify("Card deleted", vim.log.levels.INFO)
            actions.close(prompt_bufnr)
            -- Reopen orphans picker with updated list
            vim.schedule(function()
              M.orphans(store, opts)
            end)
          end
        end)
      end)

      -- <C-r>: reactivate card
      local reactivate = function()
        local entry = action_state.get_selected_entry()
        if not entry or not entry.value then
          return
        end
        local card = entry.value
        -- Reactivate by upserting with active=true
        store:upsert_card(card)
        store:save()
        vim.notify("Card reactivated: " .. utils.truncate(flatten(card.front), 40), vim.log.levels.INFO)
        actions.close(prompt_bufnr)
        -- Reopen orphans picker with updated list
        vim.schedule(function()
          M.orphans(store, opts)
        end)
      end
      map("i", "<C-r>", reactivate)
      map("n", "<C-r>", reactivate)

      -- <C-d>: delete all orphans
      local delete_all = function()
        vim.ui.select({ "Yes", "No" }, {
          prompt = string.format("Delete ALL %d orphaned cards?", #orphaned),
        }, function(choice)
          if choice == "Yes" then
            store:delete_all_orphans()
            store:save()
            vim.notify(string.format("%d orphaned cards deleted", #orphaned), vim.log.levels.INFO)
            actions.close(prompt_bufnr)
          end
        end)
      end
      map("i", "<C-d>", delete_all)
      map("n", "<C-d>", delete_all)

      return true
    end,
  }):find()
end

-- ============================================================================
-- Telescope Extension Registration
-- ============================================================================

--- Register as a telescope extension.
--- Call this during plugin setup to make pickers available via :Telescope flashcards.
--- @return table|nil telescope extension, or nil if telescope is not available
function M.register()
  if not has_telescope then
    return nil
  end

  return telescope.register_extension({
    exports = {
      flashcards = M.browse,
      browse = M.browse,
      due = M.due,
      tags = M.tags,
      search = M.search,
      orphans = M.orphans,
    },
  })
end

return M
