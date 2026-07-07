--- SQLite storage backend for nvim-flashcards.
---
--- This is the only supported persistence backend.  It talks directly to the
--- SQLite C API through LuaJIT FFI so review history is committed through real
--- ACID transactions instead of a fragile whole-file JSON rewrite.
--- @module flashcards.storage.sqlite
local utils = require("flashcards.utils")

local M = {}
local SQLiteStore = {}
SQLiteStore.__index = SQLiteStore

-- ============================================================================
-- SQLite FFI bindings
-- ============================================================================

local ok_ffi, ffi = pcall(require, "ffi")

if ok_ffi and not rawget(_G, "__flashcards_sqlite_cdef") then
  ffi.cdef([[
    typedef struct sqlite3 sqlite3;
    typedef struct sqlite3_stmt sqlite3_stmt;

    int sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs);
    int sqlite3_close(sqlite3*);
    int sqlite3_exec(sqlite3*, const char *sql, int (*callback)(void*,int,char**,char**), void *, char **errmsg);
    void sqlite3_free(void*);
    const char *sqlite3_errmsg(sqlite3*);
    int sqlite3_errcode(sqlite3*);
    int sqlite3_extended_errcode(sqlite3*);
    int sqlite3_busy_timeout(sqlite3*, int ms);
    int sqlite3_prepare_v2(sqlite3*, const char *zSql, int nByte, sqlite3_stmt **ppStmt, const char **pzTail);
    int sqlite3_step(sqlite3_stmt*);
    int sqlite3_finalize(sqlite3_stmt*);
    int sqlite3_bind_parameter_count(sqlite3_stmt*);
    int sqlite3_bind_null(sqlite3_stmt*, int);
    int sqlite3_bind_int(sqlite3_stmt*, int, int);
    int sqlite3_bind_int64(sqlite3_stmt*, int, long long);
    int sqlite3_bind_double(sqlite3_stmt*, int, double);
    int sqlite3_bind_text(sqlite3_stmt*, int, const char*, int, void(*)(void*));
    int sqlite3_column_count(sqlite3_stmt*);
    const char *sqlite3_column_name(sqlite3_stmt*, int N);
    int sqlite3_column_type(sqlite3_stmt*, int iCol);
    const unsigned char *sqlite3_column_text(sqlite3_stmt*, int iCol);
    int sqlite3_column_bytes(sqlite3_stmt*, int iCol);
    long long sqlite3_column_int64(sqlite3_stmt*, int iCol);
    double sqlite3_column_double(sqlite3_stmt*, int iCol);
    int sqlite3_changes(sqlite3*);
  ]])
  _G.__flashcards_sqlite_cdef = true
elseif ok_ffi and not rawget(_G, "__flashcards_sqlite_cdef_bind_count") then
  ffi.cdef([[ int sqlite3_bind_parameter_count(sqlite3_stmt*); ]])
end
if ok_ffi then
  _G.__flashcards_sqlite_cdef_bind_count = true
end

local SQLITE_OK = 0
local SQLITE_ROW = 100
local SQLITE_DONE = 101

local SQLITE_OPEN_READWRITE = 0x00000002
local SQLITE_OPEN_CREATE = 0x00000004
local SQLITE_OPEN_FULLMUTEX = 0x00010000

local SQLITE_INTEGER = 1
local SQLITE_FLOAT = 2
local SQLITE_TEXT = 3
local SQLITE_NULL = 5

local SQLITE_TRANSIENT = ok_ffi and ffi.cast("void(*)(void*)", -1) or nil

local sqlite_lib = nil
local sqlite_load_error = nil

local function load_sqlite()
  if sqlite_lib then
    return sqlite_lib
  end
  if not ok_ffi then
    sqlite_load_error = "LuaJIT FFI is not available"
    return nil, sqlite_load_error
  end

  local names = { "sqlite3", "libsqlite3.dylib", "libsqlite3.so", "sqlite3.dll" }
  local errors = {}
  for _, name in ipairs(names) do
    local ok, lib = pcall(ffi.load, name)
    if ok then
      sqlite_lib = lib
      return sqlite_lib
    end
    errors[#errors + 1] = tostring(lib)
  end

  sqlite_load_error = table.concat(errors, "\n")
  return nil, sqlite_load_error
end

--- Check whether the SQLite backend can load on this machine.
--- @return boolean ok
--- @return string|nil error_message
function M.is_available()
  local lib, err = load_sqlite()
  return lib ~= nil, err
end

-- ============================================================================
-- Default State / Helpers
-- ============================================================================

local DEFAULT_STATE = {
  status = "new",
  stability = 0,
  difficulty = 0,
  due_date = nil,
  last_review = nil,
  reps = 0,
  lapses = 0,
  learning_step = 0,
  elapsed_days = 0,
  scheduled_days = 0,
}

local STATE_COLUMNS = {
  status = true,
  stability = true,
  difficulty = true,
  due_date = true,
  last_review = true,
  reps = true,
  lapses = true,
  learning_step = true,
  elapsed_days = true,
  scheduled_days = true,
}

local function as_bool(value)
  return value == true or value == 1
end

local function as_int_bool(value)
  return as_bool(value) and 1 or 0
end

local function deepcopy_state(row)
  if not row then
    return nil
  end
  return {
    status = row.status or DEFAULT_STATE.status,
    stability = row.stability or DEFAULT_STATE.stability,
    difficulty = row.difficulty or DEFAULT_STATE.difficulty,
    due_date = row.due_date,
    last_review = row.last_review,
    reps = row.reps or DEFAULT_STATE.reps,
    lapses = row.lapses or DEFAULT_STATE.lapses,
    learning_step = row.learning_step or DEFAULT_STATE.learning_step,
    elapsed_days = row.elapsed_days or DEFAULT_STATE.elapsed_days,
    scheduled_days = row.scheduled_days or DEFAULT_STATE.scheduled_days,
  }
end

local function parent_dir(path)
  return path:match("^(.*)[/\\][^/\\]+$")
end

local function ensure_parent_dir(path)
  local dir = parent_dir(path)
  if dir and dir ~= "" and dir ~= "." and vim.fn.isdirectory(dir) == 0 then
    local ok = vim.fn.mkdir(dir, "p")
    if ok == 0 and vim.fn.isdirectory(dir) == 0 then
      error("flashcards sqlite: failed to create database directory: " .. dir)
    end
  end
end

local function clean_json_value(value)
  if value == vim.NIL or type(value) == "userdata" then
    return nil
  end
  return value
end

local function clean_json_number(value, default)
  value = clean_json_value(value)
  if type(value) ~= "number" then
    return default
  end
  return value
end

local function clean_json_bool(value, default)
  value = clean_json_value(value)
  if value == nil then
    return default
  end
  return as_int_bool(value)
end

local function clean_legacy_rating(rating, schema_version)
  rating = clean_json_value(rating)
  if schema_version < 2 then
    if rating == 2 then
      return 1
    elseif rating == 1 then
      return 0
    end
  end
  return rating
end

-- ============================================================================
-- Constructor
-- ============================================================================

--- Create a new SQLite storage backend.
--- @param path string file path for the SQLite database
--- @return table storage instance
function M.new(path)
  local self = setmetatable({}, SQLiteStore)
  self.path = path
  self.db = nil
  self.sqlite = nil
  self.in_transaction = false
  return self
end

--- Return true when this store currently has an open SQLite handle.
--- @return boolean
function SQLiteStore:is_open()
  return self.db ~= nil
end

-- ============================================================================
-- Low-level SQLite helpers
-- ============================================================================

function SQLiteStore:_assert_open()
  if not self.db then
    error("flashcards sqlite: database is not open; call init() first")
  end
end

function SQLiteStore:_errmsg()
  if not self.db then
    return "database is not open"
  end
  local msg = self.sqlite.sqlite3_errmsg(self.db)
  return msg ~= nil and ffi.string(msg) or "unknown sqlite error"
end

function SQLiteStore:_error(context, sql, rc)
  local parts = {
    "flashcards sqlite: " .. context,
    "path=" .. tostring(self.path),
    "code=" .. tostring(rc),
  }
  if self.db then
    parts[#parts + 1] = "extended_code=" .. tostring(self.sqlite.sqlite3_extended_errcode(self.db))
    parts[#parts + 1] = "message=" .. self:_errmsg()
  end
  if sql then
    parts[#parts + 1] = "sql=" .. sql
  end
  return table.concat(parts, " | ")
end

function SQLiteStore:_should_reopen_after_error(err)
  local msg = tostring(err)
  -- SQLITE_READONLY_DBMOVED means the DB file was replaced/moved while this
  -- connection was open. This happens easily in git/LFS/sync workflows.
  if msg:find("extended_code=1032", 1, true) then
    return true
  end
  -- SQLITE_IOERR_VNODE is the macOS VFS flavor of the stale-file/sidecar I/O
  -- error users hit before reconnecting. Retry once on a fresh handle.
  if msg:find("extended_code=6922", 1, true) then
    return true
  end
  return false
end

function SQLiteStore:_reopen_after_external_change(err)
  if self.db and self.sqlite then
    pcall(function()
      self.sqlite.sqlite3_close(self.db)
    end)
  end
  self.db = nil
  self.sqlite = nil
  self.in_transaction = false

  vim.notify(
    "nvim-flashcards: database file changed or returned a transient I/O error; reconnecting SQLite handle",
    vim.log.levels.WARN
  )
  self:init()
end

function SQLiteStore:_exec(sql)
  self:_assert_open()
  local errmsg = ffi.new("char *[1]")
  local rc = self.sqlite.sqlite3_exec(self.db, sql, nil, nil, errmsg)
  if rc ~= SQLITE_OK then
    local msg = nil
    if errmsg[0] ~= nil then
      msg = ffi.string(errmsg[0])
      self.sqlite.sqlite3_free(errmsg[0])
    else
      msg = self:_errmsg()
    end
    error(self:_error("exec failed: " .. msg, sql, rc))
  end
end

function SQLiteStore:_prepare(sql)
  self:_assert_open()
  local stmtp = ffi.new("sqlite3_stmt*[1]")
  local rc = self.sqlite.sqlite3_prepare_v2(self.db, sql, -1, stmtp, nil)
  if rc ~= SQLITE_OK then
    error(self:_error("prepare failed", sql, rc))
  end
  return stmtp[0]
end

function SQLiteStore:_bind(stmt, idx, value)
  local rc
  if value == nil then
    rc = self.sqlite.sqlite3_bind_null(stmt, idx)
  elseif type(value) == "boolean" then
    rc = self.sqlite.sqlite3_bind_int(stmt, idx, value and 1 or 0)
  elseif type(value) == "number" then
    if value == math.floor(value) then
      rc = self.sqlite.sqlite3_bind_int64(stmt, idx, value)
    else
      rc = self.sqlite.sqlite3_bind_double(stmt, idx, value)
    end
  else
    local text = tostring(value)
    rc = self.sqlite.sqlite3_bind_text(stmt, idx, text, #text, SQLITE_TRANSIENT)
  end

  if rc ~= SQLITE_OK then
    error(self:_error("bind failed", nil, rc))
  end
end

function SQLiteStore:_bind_all(stmt, params)
  params = params or {}
  local count = self.sqlite.sqlite3_bind_parameter_count(stmt)
  for i = 1, count do
    self:_bind(stmt, i, params[i])
  end
end

function SQLiteStore:_execute_once(sql, params)
  local stmt = self:_prepare(sql)
  local ok, err = pcall(function()
    self:_bind_all(stmt, params)
    local rc = self.sqlite.sqlite3_step(stmt)
    if rc ~= SQLITE_DONE then
      error(self:_error("execute failed", sql, rc))
    end
  end)
  self.sqlite.sqlite3_finalize(stmt)
  if not ok then
    error(err)
  end
end

function SQLiteStore:_execute(sql, params)
  local ok, err = pcall(function()
    self:_execute_once(sql, params)
  end)
  if ok then
    return
  end

  if not self.in_transaction and self:_should_reopen_after_error(err) then
    self:_reopen_after_external_change(err)
    self:_execute_once(sql, params)
    return
  end

  error(err)
end

function SQLiteStore:_column_value(stmt, col)
  local col_type = self.sqlite.sqlite3_column_type(stmt, col)
  if col_type == SQLITE_NULL then
    return nil
  elseif col_type == SQLITE_INTEGER then
    return tonumber(self.sqlite.sqlite3_column_int64(stmt, col))
  elseif col_type == SQLITE_FLOAT then
    return self.sqlite.sqlite3_column_double(stmt, col)
  elseif col_type == SQLITE_TEXT then
    local ptr = self.sqlite.sqlite3_column_text(stmt, col)
    if ptr == nil then
      return ""
    end
    local len = self.sqlite.sqlite3_column_bytes(stmt, col)
    return ffi.string(ptr, len)
  end
  return nil
end

function SQLiteStore:_query_all_once(sql, params)
  local stmt = self:_prepare(sql)
  local rows = {}
  local ok, err = pcall(function()
    self:_bind_all(stmt, params)
    while true do
      local rc = self.sqlite.sqlite3_step(stmt)
      if rc == SQLITE_ROW then
        local row = {}
        local count = self.sqlite.sqlite3_column_count(stmt)
        for col = 0, count - 1 do
          local name = ffi.string(self.sqlite.sqlite3_column_name(stmt, col))
          row[name] = self:_column_value(stmt, col)
        end
        rows[#rows + 1] = row
      elseif rc == SQLITE_DONE then
        break
      else
        error(self:_error("query failed", sql, rc))
      end
    end
  end)
  self.sqlite.sqlite3_finalize(stmt)
  if not ok then
    error(err)
  end
  return rows
end

function SQLiteStore:_query_all(sql, params)
  local ok, rows_or_err = pcall(function()
    return self:_query_all_once(sql, params)
  end)
  if ok then
    return rows_or_err
  end

  if not self.in_transaction and self:_should_reopen_after_error(rows_or_err) then
    self:_reopen_after_external_change(rows_or_err)
    return self:_query_all_once(sql, params)
  end

  error(rows_or_err)
end

function SQLiteStore:_query_one(sql, params)
  local rows = self:_query_all(sql, params)
  return rows[1]
end

function SQLiteStore:_changes()
  self:_assert_open()
  return self.sqlite.sqlite3_changes(self.db)
end

--- Run a function in an IMMEDIATE transaction.
--- Nested calls reuse the outer transaction so callers can compose multiple
--- storage operations into one atomic unit.
--- @param fn function
--- @return any result returned by fn
function SQLiteStore:_transaction_once(fn)
  self:_assert_open()
  self:_exec("BEGIN IMMEDIATE")
  self.in_transaction = true

  local ok, result = xpcall(fn, debug.traceback)
  if ok then
    local committed, commit_err = pcall(function()
      self:_exec("COMMIT")
    end)
    self.in_transaction = false
    if not committed then
      pcall(function() self:_exec("ROLLBACK") end)
      error(commit_err)
    end
    return result
  end

  self.in_transaction = false
  pcall(function() self:_exec("ROLLBACK") end)
  error(result)
end

function SQLiteStore:with_transaction(fn)
  if self.in_transaction then
    return fn()
  end

  local ok, result = xpcall(function()
    return self:_transaction_once(fn)
  end, debug.traceback)
  if ok then
    return result
  end

  if self:_should_reopen_after_error(result) then
    self:_reopen_after_external_change(result)
    return self:_transaction_once(fn)
  end

  error(result)
end

-- ============================================================================
-- Schema / Initialization
-- ============================================================================

local SCHEMA_SQL = [[
CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS cards (
  id TEXT PRIMARY KEY,
  file_path TEXT NOT NULL,
  line INTEGER NOT NULL DEFAULT 0,
  front TEXT NOT NULL,
  back TEXT NOT NULL,
  reversible INTEGER NOT NULL DEFAULT 0 CHECK (reversible IN (0, 1)),
  suspended INTEGER NOT NULL DEFAULT 0 CHECK (suspended IN (0, 1)),
  active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
  note TEXT,
  created_at REAL NOT NULL,
  updated_at REAL NOT NULL,
  lost_at REAL
);

CREATE TABLE IF NOT EXISTS card_states (
  card_id TEXT PRIMARY KEY REFERENCES cards(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'new' CHECK (status IN ('new', 'learning', 'review', 'relearning')),
  stability REAL NOT NULL DEFAULT 0,
  difficulty REAL NOT NULL DEFAULT 0,
  due_date REAL,
  last_review REAL,
  reps INTEGER NOT NULL DEFAULT 0,
  lapses INTEGER NOT NULL DEFAULT 0,
  learning_step INTEGER NOT NULL DEFAULT 0,
  elapsed_days REAL NOT NULL DEFAULT 0,
  scheduled_days REAL NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS card_tags (
  card_id TEXT NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
  tag TEXT NOT NULL CHECK (tag <> ''),
  position INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (card_id, tag)
);

CREATE TABLE IF NOT EXISTS reviews (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  card_id TEXT NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
  rating INTEGER NOT NULL CHECK (rating IN (0, 1)),
  reviewed_at REAL NOT NULL,
  elapsed_ms INTEGER NOT NULL DEFAULT 0,
  state_before TEXT,
  state_after TEXT
);

CREATE TABLE IF NOT EXISTS daily_stats (
  date TEXT PRIMARY KEY,
  new_count INTEGER NOT NULL DEFAULT 0 CHECK (new_count >= 0),
  review_count INTEGER NOT NULL DEFAULT 0 CHECK (review_count >= 0)
);

CREATE INDEX IF NOT EXISTS idx_cards_file_path ON cards(file_path);
CREATE INDEX IF NOT EXISTS idx_cards_active ON cards(active);
CREATE INDEX IF NOT EXISTS idx_cards_suspended ON cards(suspended);
CREATE INDEX IF NOT EXISTS idx_card_states_due ON card_states(status, due_date);
CREATE INDEX IF NOT EXISTS idx_card_tags_tag ON card_tags(tag);
CREATE INDEX IF NOT EXISTS idx_reviews_card_id ON reviews(card_id);
CREATE INDEX IF NOT EXISTS idx_reviews_reviewed_at ON reviews(reviewed_at);

INSERT OR IGNORE INTO meta(key, value) VALUES('schema_version', '1');
PRAGMA user_version = 1;
]]

function SQLiteStore:_verify_database()
  local quick = self:_query_one("PRAGMA quick_check")
  local status = quick and (quick.quick_check or quick[1])
  if status ~= "ok" then
    error("flashcards sqlite: database integrity check failed for " .. self.path .. ": " .. tostring(status))
  end

  local fk_rows = self:_query_all("PRAGMA foreign_key_check")
  if #fk_rows > 0 then
    error("flashcards sqlite: database foreign key check failed for " .. self.path)
  end
end

function SQLiteStore:_database_is_empty()
  local row = self:_query_one([[
SELECT
  (SELECT COUNT(*) FROM cards) AS card_count,
  (SELECT COUNT(*) FROM reviews) AS review_count
]])
  return (row.card_count or 0) == 0 and (row.review_count or 0) == 0
end

function SQLiteStore:_legacy_json_path()
  if self.path:sub(-3) == ".db" then
    return self.path:sub(1, -4) .. ".json"
  end
  return nil
end

function SQLiteStore:_import_legacy_json_if_present()
  local json_path = self:_legacy_json_path()
  if not json_path or vim.fn.filereadable(json_path) ~= 1 or not self:_database_is_empty() then
    return
  end

  local content, read_err = utils.read_file(json_path)
  if not content or content == "" then
    error("flashcards sqlite: found legacy JSON store at " .. json_path
      .. " but could not read it (" .. tostring(read_err or "empty file") .. "); refusing to create an empty database")
  end

  local ok, decoded = pcall(vim.fn.json_decode, content)
  if not ok or type(decoded) ~= "table" then
    error("flashcards sqlite: found legacy JSON store at " .. json_path
      .. " but it is not valid JSON; refusing to create an empty database")
  end

  local schema_version = clean_json_number(decoded.schema_version, 1)
  local imported_cards = 0
  local imported_reviews = 0
  local skipped_reviews = 0
  local now = utils.now()
  local imported_card_ids = {}

  self:with_transaction(function()
    for id, entry in pairs(decoded.cards or {}) do
      if type(id) == "string" and type(entry) == "table" then
        local state = type(entry.state) == "table" and entry.state or {}
        self:_execute([[
INSERT INTO cards(id, file_path, line, front, back, reversible, suspended, active, note, created_at, updated_at, lost_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
]], {
          id,
          clean_json_value(entry.file_path) or "",
          clean_json_number(entry.line, 0),
          clean_json_value(entry.front) or "",
          clean_json_value(entry.back) or "",
          clean_json_bool(entry.reversible, 0),
          clean_json_bool(entry.suspended, 0),
          clean_json_bool(entry.active, 1),
          clean_json_value(entry.note),
          clean_json_number(entry.created_at, now),
          clean_json_number(entry.updated_at, now),
          clean_json_value(entry.lost_at),
        })
        self:_execute([[
INSERT INTO card_states(card_id, status, stability, difficulty, due_date, last_review,
                        reps, lapses, learning_step, elapsed_days, scheduled_days)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
]], {
          id,
          clean_json_value(state.status) or DEFAULT_STATE.status,
          clean_json_number(state.stability, DEFAULT_STATE.stability),
          clean_json_number(state.difficulty, DEFAULT_STATE.difficulty),
          clean_json_value(state.due_date),
          clean_json_value(state.last_review),
          clean_json_number(state.reps, DEFAULT_STATE.reps),
          clean_json_number(state.lapses, DEFAULT_STATE.lapses),
          clean_json_number(state.learning_step, DEFAULT_STATE.learning_step),
          clean_json_number(state.elapsed_days, DEFAULT_STATE.elapsed_days),
          clean_json_number(state.scheduled_days, DEFAULT_STATE.scheduled_days),
        })
        if type(entry.tags) == "table" then
          self:_insert_tags(id, entry.tags)
        end
        imported_cards = imported_cards + 1
        imported_card_ids[id] = true
      end
    end

    for _, review in ipairs(decoded.reviews or {}) do
      if type(review) == "table" and imported_card_ids[clean_json_value(review.card_id)] then
        local rating = clean_legacy_rating(review.rating, schema_version)
        if rating == 0 or rating == 1 then
          self:add_review({
            card_id = clean_json_value(review.card_id),
            rating = rating,
            reviewed_at = clean_json_number(review.reviewed_at, now),
            elapsed_ms = clean_json_number(review.elapsed_ms, 0),
            state_before = clean_json_value(review.state_before),
            state_after = clean_json_value(review.state_after),
          })
          imported_reviews = imported_reviews + 1
        else
          skipped_reviews = skipped_reviews + 1
        end
      else
        skipped_reviews = skipped_reviews + 1
      end
    end

    self:_execute("INSERT OR REPLACE INTO meta(key, value) VALUES('legacy_json_path', ?)", { json_path })
    self:_execute("INSERT OR REPLACE INTO meta(key, value) VALUES('legacy_json_imported_at', ?)", { tostring(now) })
  end)

  local message = string.format(
    "nvim-flashcards: migrated %d cards and %d reviews from %s",
    imported_cards,
    imported_reviews,
    json_path
  )
  if skipped_reviews > 0 then
    message = message .. string.format(" (%d invalid/orphan reviews skipped)", skipped_reviews)
  end
  vim.notify(message, vim.log.levels.INFO)
end

--- Open the database and initialize the schema.
function SQLiteStore:init()
  if self.db then
    return
  end

  ensure_parent_dir(self.path)

  local lib, err = load_sqlite()
  if not lib then
    error("flashcards sqlite: unable to load SQLite library: " .. tostring(err))
  end
  self.sqlite = lib

  local dbp = ffi.new("sqlite3*[1]")
  local flags = SQLITE_OPEN_READWRITE + SQLITE_OPEN_CREATE + SQLITE_OPEN_FULLMUTEX
  local rc = self.sqlite.sqlite3_open_v2(self.path, dbp, flags, nil)
  self.db = dbp[0]

  if rc ~= SQLITE_OK then
    local msg = self.db and self:_errmsg() or "unknown sqlite open error"
    if self.db then
      self.sqlite.sqlite3_close(self.db)
    end
    self.db = nil
    error("flashcards sqlite: failed to open database " .. tostring(self.path) .. ": " .. msg)
  end

  local ok, init_err = pcall(function()
    self.sqlite.sqlite3_busy_timeout(self.db, 5000)

    -- Durability-first pragmas. Use SQLite's rollback journal instead of WAL
    -- so the database stays a single durable file in notes/git workflows and
    -- does not depend on long-lived -wal/-shm sidecars.
    self:_exec("PRAGMA busy_timeout = 5000")
    self:_exec("PRAGMA foreign_keys = ON")
    self:_exec("PRAGMA journal_mode = DELETE")
    self:_exec("PRAGMA synchronous = FULL")
    self:_exec(SCHEMA_SQL)
    self:_import_legacy_json_if_present()
    self:_verify_database()
  end)

  if not ok then
    self.sqlite.sqlite3_close(self.db)
    self.db = nil
    self.sqlite = nil
    self.in_transaction = false
    error(init_err)
  end
end

--- SQLite commits every mutating operation immediately. save() exists to keep
--- the storage interface stable for callers.
function SQLiteStore:save()
  return true
end

--- Close the database connection.
function SQLiteStore:close()
  if not self.db then
    return
  end

  local rc = self.sqlite.sqlite3_close(self.db)
  if rc ~= SQLITE_OK then
    local msg = self:_error("close failed", nil, rc)
    self.db = nil
    error(msg)
  end

  self.db = nil
  self.sqlite = nil
  self.in_transaction = false
end

-- ============================================================================
-- Row Builders
-- ============================================================================

function SQLiteStore:_get_card_tags(id)
  local rows = self:_query_all(
    "SELECT tag FROM card_tags WHERE card_id = ? ORDER BY position ASC, tag ASC",
    { id }
  )
  local tags = {}
  for _, row in ipairs(rows) do
    tags[#tags + 1] = row.tag
  end
  return tags
end

local function normalize_source_ref_fields(front, note)
  front = front or ""
  local source_ref, clean_front = utils.extract_source_ref(front)
  if source_ref then
    front = clean_front
    -- Match parser precedence: a leading source ref is the review note even if
    -- a stale DB row also has an older legacy note value.
    note = source_ref
  end
  return front, note
end

function SQLiteStore:_build_card(row)
  if not row then
    return nil
  end
  local front, note = normalize_source_ref_fields(row.front, row.note)
  return {
    id = row.id,
    file_path = row.file_path,
    line = row.line,
    front = front,
    back = row.back,
    reversible = as_bool(row.reversible),
    suspended = as_bool(row.suspended),
    active = as_bool(row.active),
    tags = self:_get_card_tags(row.id),
    note = note,
    state = deepcopy_state(row),
    created_at = row.created_at,
    updated_at = row.updated_at,
    lost_at = row.lost_at,
  }
end

function SQLiteStore:_card_select(where_sql)
  return [[
SELECT
  c.id, c.file_path, c.line, c.front, c.back, c.reversible, c.suspended,
  c.active, c.note, c.created_at, c.updated_at, c.lost_at,
  s.status, s.stability, s.difficulty, s.due_date, s.last_review,
  s.reps, s.lapses, s.learning_step, s.elapsed_days, s.scheduled_days
FROM cards c
JOIN card_states s ON s.card_id = c.id
]] .. where_sql
end

function SQLiteStore:_insert_tags(card_id, tags)
  local seen = {}
  local position = 0
  for _, tag in ipairs(tags or {}) do
    if tag and tag ~= "" and not seen[tag] then
      position = position + 1
      self:_execute(
        "INSERT INTO card_tags(card_id, tag, position) VALUES (?, ?, ?)",
        { card_id, tag, position }
      )
      seen[tag] = true
    end
  end
end

-- ============================================================================
-- Card Operations
-- ============================================================================

--- Insert or update a card. On re-upsert, content fields are updated and the
--- existing FSRS state/review history are preserved.
--- @param card table { id, file_path, line, front, back, reversible, suspended, tags, note }
function SQLiteStore:upsert_card(card)
  local front, note = normalize_source_ref_fields(card.front, card.note)

  self:with_transaction(function()
    local now = utils.now()
    local existing = self:_query_one("SELECT id FROM cards WHERE id = ?", { card.id })

    if existing then
      self:_execute([[
UPDATE cards
SET file_path = ?, line = ?, front = ?, back = ?, reversible = ?, suspended = ?,
    active = 1, note = ?, updated_at = ?, lost_at = NULL
WHERE id = ?
]], {
        card.file_path or "",
        card.line or 0,
        front,
        card.back or "",
        as_int_bool(card.reversible),
        as_int_bool(card.suspended),
        note,
        now,
        card.id,
      })
      self:_execute("DELETE FROM card_tags WHERE card_id = ?", { card.id })
      self:_insert_tags(card.id, card.tags or {})
    else
      self:_execute([[
INSERT INTO cards(id, file_path, line, front, back, reversible, suspended, active, note, created_at, updated_at, lost_at)
VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, NULL)
]], {
        card.id,
        card.file_path or "",
        card.line or 0,
        front,
        card.back or "",
        as_int_bool(card.reversible),
        as_int_bool(card.suspended),
        note,
        now,
        now,
      })
      self:_execute([[
INSERT INTO card_states(card_id, status, stability, difficulty, due_date, last_review,
                        reps, lapses, learning_step, elapsed_days, scheduled_days)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
]], {
        card.id,
        DEFAULT_STATE.status,
        DEFAULT_STATE.stability,
        DEFAULT_STATE.difficulty,
        DEFAULT_STATE.due_date,
        DEFAULT_STATE.last_review,
        DEFAULT_STATE.reps,
        DEFAULT_STATE.lapses,
        DEFAULT_STATE.learning_step,
        DEFAULT_STATE.elapsed_days,
        DEFAULT_STATE.scheduled_days,
      })
      self:_insert_tags(card.id, card.tags or {})
    end
  end)
end

--- Get a single card by ID. Returns nil if not found.
--- @param id string card ID
--- @return table|nil card
function SQLiteStore:get_card(id)
  local row = self:_query_one(self:_card_select("WHERE c.id = ?"), { id })
  return self:_build_card(row)
end

--- Get all active cards.
--- @return table[] list of card tables
function SQLiteStore:get_all_cards()
  local rows = self:_query_all(self:_card_select("WHERE c.active = 1 ORDER BY c.file_path, c.line, c.id"))
  local result = {}
  for _, row in ipairs(rows) do
    result[#result + 1] = self:_build_card(row)
  end
  return result
end

--- Get active cards for a specific file path.
--- @param path string file path to filter by
--- @return table[] list of card tables
function SQLiteStore:get_cards_by_file(path)
  local rows = self:_query_all(
    self:_card_select("WHERE c.active = 1 AND c.file_path = ? ORDER BY c.line, c.id"),
    { path }
  )
  local result = {}
  for _, row in ipairs(rows) do
    result[#result + 1] = self:_build_card(row)
  end
  return result
end

-- ============================================================================
-- Orphan Management
-- ============================================================================

--- Mark a card as lost (inactive). Sets active=false and records lost_at.
--- @param id string card ID
function SQLiteStore:mark_lost(id)
  self:with_transaction(function()
    self:_execute(
      "UPDATE cards SET active = 0, lost_at = ?, updated_at = ? WHERE id = ?",
      { utils.now(), utils.now(), id }
    )
  end)
end

--- Get all inactive (orphaned) cards.
--- @return table[] list of card tables
function SQLiteStore:get_orphaned_cards()
  local rows = self:_query_all(self:_card_select("WHERE c.active = 0 ORDER BY c.lost_at DESC, c.file_path, c.line, c.id"))
  local result = {}
  for _, row in ipairs(rows) do
    result[#result + 1] = self:_build_card(row)
  end
  return result
end

--- Permanently delete a card and all its reviews.
--- @param id string card ID
function SQLiteStore:delete_card(id)
  self:with_transaction(function()
    self:_execute("DELETE FROM cards WHERE id = ?", { id })
  end)
end

--- Permanently remove all inactive cards.
function SQLiteStore:delete_all_orphans()
  self:with_transaction(function()
    self:_execute("DELETE FROM cards WHERE active = 0")
  end)
end

-- ============================================================================
-- State Operations
-- ============================================================================

--- Get the FSRS state for a card. Returns nil if card does not exist.
--- @param id string card ID
--- @return table|nil state
function SQLiteStore:get_card_state(id)
  local row = self:_query_one("SELECT * FROM card_states WHERE card_id = ?", { id })
  return deepcopy_state(row)
end

--- Merge updates into a card's FSRS state.
--- @param id string card ID
--- @param updates table partial state fields to merge
function SQLiteStore:update_card_state(id, updates)
  updates = updates or {}
  self:with_transaction(function()
    local sets = {}
    local params = {}
    for key, value in pairs(updates) do
      if STATE_COLUMNS[key] then
        sets[#sets + 1] = key .. " = ?"
        params[#params + 1] = value
      end
    end

    if #sets == 0 then
      return
    end

    params[#params + 1] = id
    self:_execute("UPDATE card_states SET " .. table.concat(sets, ", ") .. " WHERE card_id = ?", params)
    if self:_changes() > 0 then
      self:_execute("UPDATE cards SET updated_at = ? WHERE id = ?", { utils.now(), id })
    end
  end)
end

-- ============================================================================
-- Due Cards
-- ============================================================================

function SQLiteStore:_tag_filter_sql(tag)
  if not tag then
    return "", {}
  end
  return [[
AND EXISTS (
  SELECT 1 FROM card_tags t
  WHERE t.card_id = c.id AND (t.tag = ? OR t.tag LIKE ?)
)
]], { tag, tag .. "/%" }
end

--- Get cards that are due for review.
--- A card is due if: status="new" OR (due_date <= now).
--- Excludes suspended and inactive cards.
--- @param tag string|nil optional tag filter (hierarchical matching)
--- @return table[] list of card tables
function SQLiteStore:get_due_cards(tag)
  local tag_sql, tag_params = self:_tag_filter_sql(tag)
  local params = { utils.now() }
  for _, param in ipairs(tag_params) do
    params[#params + 1] = param
  end

  local rows = self:_query_all(self:_card_select([[
WHERE c.active = 1
  AND c.suspended = 0
  AND (s.status = 'new' OR (s.due_date IS NOT NULL AND s.due_date <= ?))
]] .. tag_sql .. " ORDER BY COALESCE(s.due_date, 0), c.file_path, c.line, c.id"), params)

  local result = {}
  for _, row in ipairs(rows) do
    result[#result + 1] = self:_build_card(row)
  end
  return result
end

--- Get cards with status="new", active, not suspended.
--- @param tag string|nil optional tag filter (hierarchical matching)
--- @return table[] list of card tables
function SQLiteStore:get_new_cards(tag)
  local tag_sql, tag_params = self:_tag_filter_sql(tag)
  local rows = self:_query_all(self:_card_select([[
WHERE c.active = 1
  AND c.suspended = 0
  AND s.status = 'new'
]] .. tag_sql .. " ORDER BY c.file_path, c.line, c.id"), tag_params)

  local result = {}
  for _, row in ipairs(rows) do
    result[#result + 1] = self:_build_card(row)
  end
  return result
end

-- ============================================================================
-- Tags
-- ============================================================================

--- Get all tags with their card counts and due counts. Only counts active, non-suspended cards.
--- @return table[] list of { tag=string, count=number, due_count=number }
function SQLiteStore:get_all_tags()
  local rows = self:_query_all([[
SELECT
  t.tag AS tag,
  COUNT(*) AS count,
  COALESCE(SUM(CASE
    WHEN s.status = 'new' OR (s.due_date IS NOT NULL AND s.due_date <= ?) THEN 1
    ELSE 0
  END), 0) AS due_count
FROM card_tags t
JOIN cards c ON c.id = t.card_id
JOIN card_states s ON s.card_id = c.id
WHERE c.active = 1 AND c.suspended = 0
GROUP BY t.tag
ORDER BY t.tag
]], { utils.now() })

  local result = {}
  for _, row in ipairs(rows) do
    result[#result + 1] = { tag = row.tag, count = row.count or 0, due_count = row.due_count or 0 }
  end
  return result
end

--- Get active cards matching a tag (hierarchical: "math" matches "math" and "math/*").
--- @param tag string tag to filter by
--- @return table[] list of card tables
function SQLiteStore:get_cards_by_tag(tag)
  local rows = self:_query_all(self:_card_select([[
WHERE c.active = 1
  AND EXISTS (
    SELECT 1 FROM card_tags t
    WHERE t.card_id = c.id AND (t.tag = ? OR t.tag LIKE ?)
  )
ORDER BY c.file_path, c.line, c.id
]]), { tag, tag .. "/%" })

  local result = {}
  for _, row in ipairs(rows) do
    result[#result + 1] = self:_build_card(row)
  end
  return result
end

-- ============================================================================
-- Reviews
-- ============================================================================

--- Record a review and update daily stats.
--- @param review table { card_id, rating, reviewed_at, elapsed_ms, state_before, state_after }
function SQLiteStore:add_review(review)
  return self:with_transaction(function()
    self:_execute([[
INSERT INTO reviews(card_id, rating, reviewed_at, elapsed_ms, state_before, state_after)
VALUES (?, ?, ?, ?, ?, ?)
]], {
      review.card_id,
      review.rating,
      review.reviewed_at,
      review.elapsed_ms or 0,
      review.state_before,
      review.state_after,
    })

    local row = self:_query_one("SELECT last_insert_rowid() AS id")
    local review_id = row and row.id or nil

    local date = utils.format_date(review.reviewed_at)
    local new_count = review.state_before == "new" and 1 or 0
    local review_count = review.state_before == "new" and 0 or 1
    self:_execute([[
INSERT INTO daily_stats(date, new_count, review_count)
VALUES (?, ?, ?)
ON CONFLICT(date) DO UPDATE SET
  new_count = daily_stats.new_count + excluded.new_count,
  review_count = daily_stats.review_count + excluded.review_count
]], { date, new_count, review_count })

    return review_id
  end)
end

--- Atomically record a review and update the reviewed card's FSRS state.
--- @param review table review record accepted by add_review
--- @param card_id string card ID
--- @param new_state table new FSRS state
--- @return number|nil review_id persisted review row id
function SQLiteStore:add_review_and_update_state(review, card_id, new_state)
  return self:with_transaction(function()
    local review_id = self:add_review(review)
    self:update_card_state(card_id, new_state)
    return review_id
  end)
end

--- Get all reviews for a card.
--- @param card_id string card ID
--- @return table[] list of review tables
function SQLiteStore:get_reviews(card_id)
  local rows = self:_query_all([[
SELECT card_id, rating, reviewed_at, elapsed_ms, state_before, state_after
FROM reviews
WHERE card_id = ?
ORDER BY id ASC
]], { card_id })

  local result = {}
  for _, row in ipairs(rows) do
    result[#result + 1] = {
      card_id = row.card_id,
      rating = row.rating,
      reviewed_at = row.reviewed_at,
      elapsed_ms = row.elapsed_ms,
      state_before = row.state_before,
      state_after = row.state_after,
    }
  end
  return result
end

--- Remove one specific persisted review from the review log.
--- @param review_id number review row id returned by add_review
--- @param card_id string|nil optional guard; when supplied the row must belong to this card
--- @return boolean true if a review was removed
function SQLiteStore:remove_review(review_id, card_id)
  return self:with_transaction(function()
    local review
    if card_id then
      review = self:_query_one(
        "SELECT id, reviewed_at, state_before FROM reviews WHERE id = ? AND card_id = ?",
        { review_id, card_id }
      )
    else
      review = self:_query_one(
        "SELECT id, reviewed_at, state_before FROM reviews WHERE id = ?",
        { review_id }
      )
    end

    if not review then
      return false
    end

    self:_execute("DELETE FROM reviews WHERE id = ?", { review.id })

    local date = review.reviewed_at and utils.format_date(review.reviewed_at)
    if date then
      if review.state_before == "new" then
        self:_execute([[
UPDATE daily_stats
SET new_count = CASE WHEN new_count > 0 THEN new_count - 1 ELSE 0 END
WHERE date = ?
]], { date })
      else
        self:_execute([[
UPDATE daily_stats
SET review_count = CASE WHEN review_count > 0 THEN review_count - 1 ELSE 0 END
WHERE date = ?
]], { date })
      end
      self:_execute("DELETE FROM daily_stats WHERE date = ? AND new_count = 0 AND review_count = 0", { date })
    end

    return true
  end)
end

--- Remove the most recent review from the review log (legacy undo support).
--- Prefer remove_review(review_id, card_id) when the caller has a persisted id.
--- @return boolean true if a review was removed
function SQLiteStore:remove_last_review()
  return self:with_transaction(function()
    local review = self:_query_one("SELECT id FROM reviews ORDER BY id DESC LIMIT 1")
    if not review then
      return false
    end
    return self:remove_review(review.id)
  end)
end

-- ============================================================================
-- Statistics
-- ============================================================================

--- Count active cards by FSRS state.
--- @return table { new=N, learning=N, review=N, relearning=N }
function SQLiteStore:count_by_state()
  local counts = { new = 0, learning = 0, review = 0, relearning = 0 }
  local rows = self:_query_all([[
SELECT s.status AS status, COUNT(*) AS count
FROM card_states s
JOIN cards c ON c.id = s.card_id
WHERE c.active = 1
GROUP BY s.status
]])
  for _, row in ipairs(rows) do
    if counts[row.status] ~= nil then
      counts[row.status] = row.count or 0
    end
  end
  return counts
end

--- Count cards currently due for review.
--- @return table { total=N, new=N, review=N, learning=N }
function SQLiteStore:count_due()
  local counts = { total = 0, new = 0, review = 0, learning = 0 }
  local rows = self:_query_all([[
SELECT s.status AS status, COUNT(*) AS count
FROM card_states s
JOIN cards c ON c.id = s.card_id
WHERE c.active = 1
  AND c.suspended = 0
  AND (s.status = 'new' OR (s.due_date IS NOT NULL AND s.due_date <= ?))
GROUP BY s.status
]], { utils.now() })

  for _, row in ipairs(rows) do
    local n = row.count or 0
    counts.total = counts.total + n
    if row.status == "new" then
      counts.new = counts.new + n
    elseif row.status == "learning" then
      counts.learning = counts.learning + n
    elseif row.status == "review" or row.status == "relearning" then
      counts.review = counts.review + n
    end
  end
  return counts
end

--- Get full statistics.
--- @return table stats
function SQLiteStore:get_stats()
  local state_counts = self:count_by_state()
  local due_counts = self:count_due()
  local total = self:_query_one("SELECT COUNT(*) AS count FROM cards WHERE active = 1")
  local reviews = self:_query_one([[
SELECT
  COUNT(*) AS total_reviews,
  COALESCE(SUM(CASE WHEN rating = 1 THEN 1 ELSE 0 END), 0) AS correct_count,
  COALESCE(SUM(elapsed_ms), 0) AS total_time_ms
FROM reviews
]])

  local total_cards = total and total.count or 0
  local total_reviews = reviews and reviews.total_reviews or 0
  local correct_count = reviews and reviews.correct_count or 0
  local total_time_ms = reviews and reviews.total_time_ms or 0

  local retention_rate = 0
  if total_reviews > 0 then
    retention_rate = correct_count / total_reviews
  end

  local avg_time_ms = 0
  if total_reviews > 0 then
    avg_time_ms = math.floor(total_time_ms / total_reviews)
  end

  local streak = 0
  local day_ts = utils.start_of_day(utils.now())
  while true do
    local date = utils.format_date(day_ts)
    local day = self:_query_one("SELECT new_count, review_count FROM daily_stats WHERE date = ?", { date })
    if day and ((day.new_count or 0) + (day.review_count or 0)) > 0 then
      streak = streak + 1
      day_ts = day_ts - 86400
    else
      break
    end
  end

  return {
    total_cards = total_cards,
    by_state = state_counts,
    due = due_counts,
    total_reviews = total_reviews,
    retention_rate = retention_rate,
    streak = streak,
    avg_time_ms = avg_time_ms,
  }
end

--- Get daily statistics for the last N days.
--- @param days number number of days to look back
--- @return table[] array of { date=string, new_count=N, review_count=N }
function SQLiteStore:get_daily_stats(days)
  local result = {}
  local now = utils.now()
  for i = 0, days - 1 do
    local day_ts = utils.start_of_day(now) - (i * 86400)
    local date = utils.format_date(day_ts)
    local stats = self:_query_one("SELECT new_count, review_count FROM daily_stats WHERE date = ?", { date })
    result[#result + 1] = {
      date = date,
      new_count = stats and stats.new_count or 0,
      review_count = stats and stats.review_count or 0,
    }
  end
  return result
end

return M
