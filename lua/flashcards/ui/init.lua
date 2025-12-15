-- UI module entry point for nvim-flashcards

local M = {}

M.review = require("flashcards.ui.review")
M.stats = require("flashcards.ui.stats")
M.components = require("flashcards.ui.components")

return M
