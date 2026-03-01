--- Storage factory for nvim-flashcards.
--- Creates the appropriate storage backend based on configuration.
--- @module flashcards.storage
local M = {}

--- Create a new storage backend instance.
--- @param storage_type string "json" or "sqlite"
--- @param path string file path for the storage file
--- @return table storage backend instance
function M.new(storage_type, path)
  if storage_type == "json" then
    return require("flashcards.storage.json").new(path)
  elseif storage_type == "sqlite" then
    return require("flashcards.storage.sqlite").new(path)
  else
    error("Unknown storage type: " .. tostring(storage_type))
  end
end

return M
