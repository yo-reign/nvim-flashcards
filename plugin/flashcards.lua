-- Plugin entry point for nvim-flashcards
-- This file triggers lazy-loading

if vim.g.loaded_flashcards then
    return
end
vim.g.loaded_flashcards = true

-- Create user commands that trigger lazy loading
local function lazy_load()
    return require("flashcards")
end

-- Main commands
vim.api.nvim_create_user_command("FlashcardsSetup", function()
    lazy_load().setup()
end, { desc = "Setup flashcards plugin" })

vim.api.nvim_create_user_command("FlashcardsInit", function()
    lazy_load().setup()
    lazy_load().init_directory()
end, { desc = "Initialize flashcards in current directory" })

-- Register telescope extension if available
vim.api.nvim_create_autocmd("User", {
    pattern = "TelescopeReady",
    callback = function()
        pcall(function()
            require("flashcards.telescope").register()
        end)
    end,
})

-- Also try to register immediately if telescope is already loaded
pcall(function()
    require("flashcards.telescope").register()
end)
