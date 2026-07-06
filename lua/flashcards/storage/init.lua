--- Storage factory for nvim-flashcards.
--- SQLite is the only supported persistence backend.
--- @module flashcards.storage
local M = {}

--- Create a new storage backend instance.
--- @param storage_type string|nil must be "sqlite" (nil defaults to sqlite)
--- @param path string file path for the storage database
--- @return table storage backend instance
function M.new(storage_type, path)
  storage_type = storage_type or "sqlite"
  if storage_type ~= "sqlite" then
    error("Unsupported storage type: " .. tostring(storage_type) .. ". JSON storage has been removed; use storage = \"sqlite\".")
  end
  return require("flashcards.storage.sqlite").new(path)
end

return M
