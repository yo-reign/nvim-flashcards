# Bug Fix Review — 2026-03-01

After completing the v1 ground-up rewrite (16 tasks, 195 tests), two review agents analyzed the codebase for correctness and security issues. This document records every bug found, why it was a problem, and how it was fixed.

Commit: `b2086e0`

---

## 1. FSRS `.state` vs `.status` naming mismatch

**Files:** `lua/flashcards/fsrs.lua`, `tests/flashcards/fsrs_spec.lua`

**Problem:** The FSRS scheduler wrote output state as `new_state.state = "review"` etc., but the storage layer and scheduler both read `.status`. Cards scheduled by FSRS would have their state silently ignored — the storage would see `nil` for `.status` and treat every card as new.

**Fix:** Changed all 8 occurrences of `new_state.state` to `new_state.status` in fsrs.lua. Added a fallback `card_state.status or card_state.state` when reading input so old data still works. Updated all test assertions from `.state` to `.status`.

---

## 2. Template variable expansion silently failing

**Files:** `lua/flashcards/utils.lua`

**Problem:** `expand_template_vars` used nested `gsub` calls:

```lua
text = text:gsub("{{file%.name}}", name:gsub("%%", "%%%%"))
```

Lua's `gsub` returns two values: `(result_string, replacement_count)`. When `name` is `"algebra"` (no `%` chars), the inner gsub returns `("algebra", 0)`. The `0` leaks through as the 4th argument to the outer `gsub`, which interprets it as "maximum number of replacements." Result: zero replacements, template vars never expanded.

This is a well-known Lua gotcha but extremely hard to debug — the function silently returns the input unchanged with no error.

**Fix:** Wrap each inner gsub in parentheses to discard the count:

```lua
text = text:gsub("{{file%.name}}", (name:gsub("%%", "%%%%")))
```

**Note:** The original code (before the security fix) used plain `name` without the inner gsub, which worked fine. The bug was introduced by the `%`-escaping fix itself.

---

## 3. Non-atomic file writes

**Files:** `lua/flashcards/utils.lua`

**Problem:** `write_file` opened the target path with `io.open(path, "w")`, which truncates the file immediately. If the process crashes mid-write (or the disk fills up), the file is left empty or partially written, losing all card data.

**Fix:** Write to a temporary file (`path .. ".tmp"`), then `os.rename` atomically. If rename fails, clean up the temp file and return the error.

```lua
local tmp_path = path .. ".tmp"
local f, err = io.open(tmp_path, "w")
-- ...write and close...
local ok, rename_err = os.rename(tmp_path, path)
if not ok then
  os.remove(tmp_path)
  return false, rename_err
end
```

---

## 4. Scanner `config:should_ignore()` colon-call crash

**Files:** `lua/flashcards/scanner.lua`, `tests/flashcards/scanner_spec.lua`

**Problem:** The scanner called `config:should_ignore(file)` (colon syntax), which passes `config` as the first argument (`self`). But `config.should_ignore` is a plain module function `M.should_ignore(filepath)` — it doesn't expect a `self` parameter. The config table was passed as the filepath, and the actual filepath was passed as a second (ignored) argument.

In practice this meant ignore patterns never matched, so no files were ever filtered out.

**Fix:** Changed to dot-call `config.should_ignore(file)`. Updated the test mock to match (removed the `_` self parameter).

---

## 5. Scanner `find_files` Lua pattern alternation

**Files:** `lua/flashcards/scanner.lua`

**Problem:** The original code joined file patterns with `|` for alternation:

```lua
local combined = table.concat(search_patterns, "|")
```

Lua patterns don't support `|` alternation — this is a regex feature. The combined pattern would fail to match anything or match incorrectly.

**Fix:** Scan once per pattern and merge results using a deduplication set:

```lua
local files_set = {}
for _, pattern in ipairs(search_patterns) do
  local found = scan.scan_dir(dir, { search_pattern = pattern })
  for _, f in ipairs(found) do
    if not files_set[f] then
      files_set[f] = true
      files[#files + 1] = f
    end
  end
end
```

---

## 6. CRLF handling in `utils.lines()`

**Files:** `lua/flashcards/utils.lua`

**Problem:** The `lines()` function split on `\n` only:

```lua
for line in s:gmatch("([^\n]*)\n?") do
```

On files with Windows-style `\r\n` line endings, each line would retain a trailing `\r`. When the scanner writes IDs back and re-parses, the `\r` characters corrupt card content and break pattern matching.

**Fix:** Updated pattern to handle both:

```lua
for line in s:gmatch("([^\r\n]*)\r?\n?") do
```

---

## 7. Scheduler undo accessing internal store field

**Files:** `lua/flashcards/scheduler.lua`, `lua/flashcards/storage/json.lua`, `tests/flashcards/scheduler_spec.lua`

**Problem:** The `undo()` method accessed `self.store._reviews` directly to remove the last review record. This breaks encapsulation and fails with any storage backend that doesn't expose `_reviews` as a public field.

**Fix:** Added a proper `remove_last_review()` method to the storage interface (json.lua) and updated the scheduler to call it through a guard:

```lua
if self.store.remove_last_review then
  self.store:remove_last_review()
end
```

Added the same method to the test mock store.

---

## 8. Scheduler summary total drift

**Files:** `lua/flashcards/scheduler.lua`

**Problem:** `summary()` used `#self.queue` as the total card count. But the queue grows during the session when learning cards are re-queued after wrong answers. This made the progress display (e.g., "3/7") show increasing totals, confusing the user.

**Fix:** Track `initial_count` when `load_cards()` completes, and use it in `summary()`:

```lua
self.initial_count = #self.queue  -- set after load_cards
-- in summary():
local total = self.initial_count > 0 and self.initial_count or #self.queue
```

---

## 9. Review UI BufLeave double-unmount

**Files:** `lua/flashcards/ui/review.lua`

**Problem:** The popup registers a `BufLeave` autocmd that calls `M.close()`. But `close()` calls `popup:unmount()`, which triggers `BufLeave` again, causing a recursive close. This could crash or produce duplicate notifications.

**Fix:** Nil the popup reference before unmounting:

```lua
function M.close()
  local popup = state.popup
  state.popup = nil  -- prevent re-entrant close from BufLeave
  if popup then
    popup:unmount()
  end
  -- ...rest of cleanup
end
```

---

## 10. Relative file paths in edit actions

**Files:** `lua/flashcards/ui/review.lua`, `lua/flashcards/telescope/init.lua`

**Problem:** Cards store relative file paths (e.g., `"math/algebra.md"`). The "edit card" action in both the review UI and all Telescope pickers passed this relative path directly to `vim.cmd("edit ...")`, which would fail to open the file unless Neovim's CWD happened to be the scan root.

**Fix:** Added path resolution against configured directories:

```lua
-- In review.lua:
for _, dir in ipairs(config.options.directories) do
  local abs = dir .. "/" .. file_path
  if vim.fn.filereadable(abs) == 1 then
    file_path = abs
    break
  end
end

-- In telescope/init.lua:
local function resolve_path(file_path)
  for _, dir in ipairs(config.options.directories) do
    local abs = dir .. "/" .. file_path
    if vim.fn.filereadable(abs) == 1 then return abs end
  end
  return file_path
end
```

Applied `resolve_path()` to all 5 `vim.cmd("edit ...")` calls across the telescope pickers (browse, due x2, tags sub-picker, search).

---

## 11. Tag parsing doesn't support hyphens

**Files:** `lua/flashcards/utils.lua`

**Problem:** `parse_tags` and `strip_tags` used `[%w_/]+` to match tag characters. Tags like `#my-tag` would only capture `#my`, silently dropping the `-tag` portion.

**Fix:** Added `%-` to both patterns:

```lua
-- parse_tags
for tag in text:gmatch("#([%w_/%-]+)") do

-- strip_tags
local result = text:gsub("%s*#[%w_/%-]+", "")
```

---

## 12. Storage `save()` silent failure

**Files:** `lua/flashcards/storage/json.lua`

**Problem:** `save()` called `utils.write_file()` but discarded the return value. If the write failed (disk full, permissions), the user would never know their review data wasn't persisted.

**Fix:** Check the return value and notify on failure:

```lua
local ok, err = utils.write_file(self.path, encoded)
if not ok then
  vim.notify("nvim-flashcards: failed to save data: " .. tostring(err), vim.log.levels.ERROR)
end
```

---

## 13. Missing `remove_last_review()` in storage

**Files:** `lua/flashcards/storage/json.lua`

**Problem:** The scheduler's undo feature needs to remove the last review record from storage, but the JSON backend had no method for this.

**Fix:** Added the method:

```lua
function JsonStore:remove_last_review()
  if #self.data.reviews > 0 then
    table.remove(self.data.reviews)
    return true
  end
  return false
end
```

---

## Test Results

All 195 tests pass after fixes:

| Suite | Tests |
|-------|-------|
| utils | 19 |
| parser | 61 |
| fsrs | 31 |
| storage | 44 |
| scanner | 23 |
| scheduler | 17 |
| **Total** | **195** |
