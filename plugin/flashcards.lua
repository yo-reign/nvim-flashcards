-- Lazy-load entry point for nvim-flashcards.
-- Commands are registered in setup() (called from user config).
-- This file sets the loaded guard so the plugin is discoverable by
-- lazy.nvim / packer via the plugin/ directory convention.

if vim.g.loaded_flashcards then
  return
end
vim.g.loaded_flashcards = true
