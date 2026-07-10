describe("scanner", function()
  local scanner = require("flashcards.scanner")
  local Storage = require("flashcards.storage")
  local utils = require("flashcards.utils")

  local store
  local store_path

  --- Helper: create a temp file with content, return its path.
  --- @param content string
  --- @param suffix string|nil file extension (default ".md")
  --- @return string path
  local function tmpfile(content, suffix)
    suffix = suffix or ".md"
    local path = os.tmpname() .. suffix
    utils.write_file(path, content)
    return path
  end

  --- Helper: create a temp directory (uses os.tmpname trick).
  --- @return string dir_path
  local function tmpdir()
    local path = os.tmpname()
    os.remove(path)
    vim.fn.mkdir(path, "p")
    return path
  end

  local function remove_db_files(path)
    os.remove(path)
    os.remove(path .. "-wal")
    os.remove(path .. "-shm")
  end

  before_each(function()
    store_path = os.tmpname() .. ".db"
    store = Storage.new("sqlite", store_path)
    store:init()
  end)

  after_each(function()
    if store then
      pcall(function() store:close() end)
    end
    remove_db_files(store_path)
  end)

  -- ==========================================================================
  -- scan_file: basic card extraction and upsert
  -- ==========================================================================

  describe("scan_file", function()
    it("scans a file and upserts cards to the store", function()
      local content = "What is 2+2? ::: 4 #math <!-- fc:test0001 -->"
      local path = tmpfile(content)

      local result = scanner.scan_file(path, store, "/tmp")
      os.remove(path)

      assert.equals(1, result.cards_found)
      assert.equals(1, result.cards_new) -- new to store (even though ID already existed in file)
      assert.equals(0, #result.errors)

      local card = store:get_card("test0001")
      assert.is_not_nil(card)
      assert.equals("What is 2+2?", card.front)
      assert.equals("4", card.back)
    end)

    it("handles files with multiple cards", function()
      local content = table.concat({
        "Q1 ::: A1 <!-- fc:card0001 -->",
        "Q2 ::: A2 <!-- fc:card0002 -->",
        "Q3 ::: A3 <!-- fc:card0003 -->",
      }, "\n")
      local path = tmpfile(content)

      local result = scanner.scan_file(path, store, "/tmp")
      os.remove(path)

      assert.equals(3, result.cards_found)
      assert.is_not_nil(store:get_card("card0001"))
      assert.is_not_nil(store:get_card("card0002"))
      assert.is_not_nil(store:get_card("card0003"))
    end)

    it("stores leading section refs as notes and strips them from front text", function()
      local content = "(1.1.2:6) Can a number be both rational and irrational? ::: No <!-- fc:sect001 -->"
      local path = tmpfile(content)

      local result = scanner.scan_file(path, store, "/tmp")
      os.remove(path)

      assert.equals(1, result.cards_found)
      local card = store:get_card("sect001")
      assert.is_not_nil(card)
      assert.equals("Can a number be both rational and irrational?", card.front)
      assert.equals("No", card.back)
      assert.equals("1.1.2:6", card.note)
    end)

    it("handles empty files without error", function()
      local path = tmpfile("")

      local result = scanner.scan_file(path, store, "/tmp")
      os.remove(path)

      assert.equals(0, result.cards_found)
      assert.equals(0, #result.errors)
    end)

    it("handles files with no cards", function()
      local content = "# Just a heading\n\nSome text here.\n"
      local path = tmpfile(content)

      local result = scanner.scan_file(path, store, "/tmp")
      os.remove(path)

      assert.equals(0, result.cards_found)
      assert.equals(0, #result.errors)
    end)
  end)

  -- ==========================================================================
  -- ID write-back: cards without IDs get IDs written to the file
  -- ==========================================================================

  describe("ID write-back", function()
    it("writes IDs back to file for inline cards without them", function()
      local content = "What is Lua? ::: A scripting language"
      local path = tmpfile(content)

      local result = scanner.scan_file(path, store, "/tmp")

      -- File should now have an ID comment
      local updated = utils.read_file(path)
      os.remove(path)

      assert.is_not_nil(updated:match("<!%-%- fc:%w+ %-%->"))
      assert.equals(1, result.cards_found)
      assert.equals(1, result.cards_new)
    end)

    it("writes IDs back to file for fenced cards without them", function()
      local content = table.concat({
        ":::card",
        "What is recursion?",
        ":-:",
        "A function that calls itself.",
        ":::end",
      }, "\n")
      local path = tmpfile(content)

      scanner.scan_file(path, store, "/tmp")

      local updated = utils.read_file(path)
      os.remove(path)

      -- ID should be on the :::card opener line
      local first_line = utils.lines(updated)[1]
      assert.is_not_nil(first_line:match("^:::card <!%-%- fc:%w+ %-%->$"))
    end)

    it("writes IDs back for reversible fenced cards on opener line", function()
      local content = table.concat({
        ":?:card",
        "Term",
        ":-:",
        "Definition",
        ":?:end",
      }, "\n")
      local path = tmpfile(content)

      scanner.scan_file(path, store, "/tmp")

      local updated = utils.read_file(path)
      os.remove(path)

      local first_line = utils.lines(updated)[1]
      assert.is_not_nil(first_line:match("^:%?:card <!%-%- fc:%w+ %-%->$"))
    end)

    it("writes multiple IDs bottom-up so line numbers stay correct", function()
      local content = table.concat({
        "Q1 ::: A1",
        "Q2 ::: A2",
        "Q3 ::: A3",
      }, "\n")
      local path = tmpfile(content)

      scanner.scan_file(path, store, "/tmp")

      local updated = utils.read_file(path)
      local lines = utils.lines(updated)
      os.remove(path)

      -- All three lines should have IDs
      assert.equals(3, #lines)
      for i = 1, 3 do
        assert.is_not_nil(lines[i]:match("<!%-%- fc:%w+ %-%->"),
          "Line " .. i .. " missing ID: " .. lines[i])
      end

      -- All three IDs should be different
      local ids = {}
      for i = 1, 3 do
        local id = lines[i]:match("<!%-%- fc:(%w+) %-%->")
        assert.is_not_nil(id, "No ID on line " .. i)
        assert.is_nil(ids[id], "Duplicate ID: " .. id)
        ids[id] = true
      end
    end)

    it("does not modify file when all cards already have IDs", function()
      local content = table.concat({
        "Q1 ::: A1 <!-- fc:exist001 -->",
        "Q2 ::: A2 <!-- fc:exist002 -->",
      }, "\n")
      local path = tmpfile(content)

      scanner.scan_file(path, store, "/tmp")

      local updated = utils.read_file(path)
      os.remove(path)

      assert.equals(content, updated)
    end)
  end)

  -- ==========================================================================
  -- Preserve existing IDs
  -- ==========================================================================

  describe("preserve existing IDs", function()
    it("keeps existing IDs and only generates for new cards", function()
      local content = table.concat({
        "Q1 ::: A1 <!-- fc:keepme01 -->",
        "Q2 ::: A2",
      }, "\n")
      local path = tmpfile(content)

      scanner.scan_file(path, store, "/tmp")

      local updated = utils.read_file(path)
      local lines = utils.lines(updated)
      os.remove(path)

      -- First line keeps its ID
      assert.is_not_nil(lines[1]:match("fc:keepme01"))
      -- Second line gets a new ID
      local new_id = lines[2]:match("fc:(%w+)")
      assert.is_not_nil(new_id)
      assert.not_equals("keepme01", new_id)
    end)

    it("preserves review state for existing card IDs", function()
      -- First: upsert a card and give it some state
      store:upsert_card({
        id = "state001",
        file_path = "test.md",
        line = 1,
        front = "Old Q",
        back = "Old A",
        tags = {},
      })
      store:update_card_state("state001", {
        status = "review",
        stability = 5.0,
        reps = 10,
      })

      -- Now scan a file with the same card ID but updated content
      local content = "New Q ::: New A <!-- fc:state001 -->"
      local path = tmpfile(content)

      scanner.scan_file(path, store, "/tmp")
      os.remove(path)

      local card = store:get_card("state001")
      assert.is_not_nil(card)
      -- Content should be updated
      assert.equals("New Q", card.front)
      assert.equals("New A", card.back)
      -- State should be preserved
      assert.equals("review", card.state.status)
      assert.equals(5.0, card.state.stability)
      assert.equals(10, card.state.reps)
    end)
  end)

  -- ==========================================================================
  -- Orphan detection (per-file)
  -- ==========================================================================

  describe("orphan detection (per-file)", function()
    it("marks cards as lost when they disappear from a file", function()
      local path = os.tmpname() .. ".md"

      -- First scan: file has two cards
      local content1 = table.concat({
        "Q1 ::: A1 <!-- fc:orphan01 -->",
        "Q2 ::: A2 <!-- fc:orphan02 -->",
      }, "\n")
      utils.write_file(path, content1)
      scanner.scan_file(path, store, "/tmp")

      -- Verify both cards exist and are active
      assert.is_true(store:get_card("orphan01").active)
      assert.is_true(store:get_card("orphan02").active)

      -- Second scan: file now only has one card
      local content2 = "Q1 ::: A1 <!-- fc:orphan01 -->"
      utils.write_file(path, content2)
      scanner.scan_file(path, store, "/tmp")

      os.remove(path)

      -- orphan01 should still be active
      assert.is_true(store:get_card("orphan01").active)
      -- orphan02 should be marked as lost
      assert.is_false(store:get_card("orphan02").active)
    end)

    it("does not mark cards from other files as lost", function()
      -- Create a card in the store from a different file
      store:upsert_card({
        id = "other001",
        file_path = "other.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
      })

      -- Scan a different file
      local content = "Q1 ::: A1 <!-- fc:mycard01 -->"
      local path = tmpfile(content)
      scanner.scan_file(path, store, "/tmp")
      os.remove(path)

      -- Card from other file should still be active
      assert.is_true(store:get_card("other001").active)
    end)
  end)

  -- ==========================================================================
  -- Global orphan detection (mark_orphans)
  -- ==========================================================================

  describe("mark_orphans", function()
    it("marks cards not in found set as lost", function()
      -- Add some cards to the store
      store:upsert_card({
        id = "found001",
        file_path = "test.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = {},
      })
      store:upsert_card({
        id = "lost0001",
        file_path = "test.md",
        line = 2,
        front = "Q2",
        back = "A2",
        tags = {},
      })
      store:upsert_card({
        id = "found002",
        file_path = "test.md",
        line = 3,
        front = "Q3",
        back = "A3",
        tags = {},
      })

      -- Only found001 and found002 were found during scan
      local found_ids = { found001 = true, found002 = true }
      local count = scanner.mark_orphans(store, found_ids)

      assert.equals(1, count)
      assert.is_true(store:get_card("found001").active)
      assert.is_false(store:get_card("lost0001").active)
      assert.is_true(store:get_card("found002").active)
    end)

    it("does not re-mark already-lost cards", function()
      store:upsert_card({
        id = "alreadylost",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
      })
      store:mark_lost("alreadylost")

      -- Now mark_orphans with empty found set
      local count = scanner.mark_orphans(store, {})

      -- Should report 0 because the card was already lost
      assert.equals(0, count)
    end)
  end)

  -- ==========================================================================
  -- Fenced card ID placement
  -- ==========================================================================

  describe("fenced card ID placement", function()
    it("places ID on the :::card opener line, not the closer", function()
      local content = table.concat({
        "Some text before",
        ":::card",
        "What is Lua?",
        ":-:",
        "A language",
        ":::end #programming",
        "Some text after",
      }, "\n")
      local path = tmpfile(content)

      scanner.scan_file(path, store, "/tmp")

      local updated = utils.read_file(path)
      local lines = utils.lines(updated)
      os.remove(path)

      -- Line 1: "Some text before" (unchanged)
      assert.equals("Some text before", lines[1])
      -- Line 2: ":::card <!-- fc:ID -->"
      assert.is_not_nil(lines[2]:match("^:::card <!%-%- fc:%w+ %-%->$"))
      -- Line 6: ":::end #programming" (unchanged)
      assert.equals(":::end #programming", lines[6])
      -- Line 7: "Some text after" (unchanged)
      assert.equals("Some text after", lines[7])
    end)

    it("handles mixed inline and fenced cards needing IDs", function()
      local content = table.concat({
        "Q1 ::: A1",
        ":::card",
        "Fenced front",
        ":-:",
        "Fenced back",
        ":::end",
        "Q2 ::: A2",
      }, "\n")
      local path = tmpfile(content)

      scanner.scan_file(path, store, "/tmp")

      local updated = utils.read_file(path)
      local lines = utils.lines(updated)
      os.remove(path)

      -- All three cards should have IDs
      assert.is_not_nil(lines[1]:match("<!%-%- fc:%w+ %-%->"), "Inline card 1 missing ID")
      assert.is_not_nil(lines[2]:match("<!%-%- fc:%w+ %-%->"), "Fenced card missing ID")
      assert.is_not_nil(lines[7]:match("<!%-%- fc:%w+ %-%->"), "Inline card 2 missing ID")

      -- Should be 7 lines total (no extra lines added)
      assert.equals(7, #lines)
    end)
  end)

  -- ==========================================================================
  -- Safe orphan handling and source-path migration
  -- ==========================================================================

  describe("safe orphan handling and source paths", function()
    it("does not orphan existing cards when parsing a file fails", function()
      local path = tmpfile("Q ::: A <!-- fc:safe0001 -->")
      scanner.scan_file(path, store, "/tmp")
      assert.is_true(store:get_card("safe0001").active)

      assert.is_true(utils.write_file(path, table.concat({
        ":::card <!-- fc:safe0001 -->",
        "Front",
        ":-:",
        "Back",
      }, "\n")))
      local result = scanner.scan_file(path, store, "/tmp")
      os.remove(path)

      assert.is_false(result.can_mark_orphans)
      assert.truthy(#result.errors > 0)
      assert.is_true(store:get_card("safe0001").active)
    end)

    it("skips global orphaning when an ID write fails", function()
      store:upsert_card({ id = "keepwrite", file_path = "missing.md", line = 1, front = "Q", back = "A", tags = {} })
      local dir = tmpdir()
      assert.is_true(utils.write_file(dir .. "/new.md", "New Q ::: New A"))
      local config = {
        options = { file_patterns = { "*.md" }, ignore_patterns = {} },
        should_ignore = function() return false end,
      }
      local original_write_file = utils.write_file
      utils.write_file = function() return false, "permission denied" end
      local report = scanner.scan({ dir }, store, config)
      utils.write_file = original_write_file
      vim.fn.delete(dir, "rf")

      assert.truthy(#report.errors > 0)
      assert.equals(0, report.orphans_found)
      assert.is_true(store:get_card("keepwrite").active)
    end)

    it("skips global orphaning when any scanned file has an error", function()
      store:upsert_card({ id = "keep0001", file_path = "missing.md", line = 1, front = "Q", back = "A", tags = {} })
      local dir = tmpdir()
      assert.is_true(utils.write_file(dir .. "/broken.md", table.concat({
        ":::card <!-- fc:broken01 -->",
        "Front",
        ":-:",
        "Back",
      }, "\n")))
      local config = {
        options = { file_patterns = { "*.md" }, ignore_patterns = {} },
        should_ignore = function() return false end,
      }

      local report = scanner.scan({ dir }, store, config)
      vim.fn.delete(dir, "rf")

      assert.truthy(#report.errors > 0)
      assert.equals(0, report.orphans_found)
      assert.is_true(store:get_card("keep0001").active)
    end)

    it("keeps identically named files in separate roots distinct", function()
      local root_a, root_b = tmpdir(), tmpdir()
      assert.is_true(utils.write_file(root_a .. "/deck.md", "A ::: One <!-- fc:roota001 -->"))
      assert.is_true(utils.write_file(root_b .. "/deck.md", "B ::: Two <!-- fc:rootb001 -->"))
      -- Simulate a pre-upgrade database row whose relative path is ambiguous.
      -- It must be migrated by matching its card ID in root B, never by a
      -- blanket root-prefix rewrite.
      store:upsert_card({ id = "rootb001", file_path = "deck.md", line = 1, front = "Old B", back = "Old", tags = {} })
      store:update_card_state("rootb001", { status = "review", stability = 6, reps = 4 })
      local config = {
        options = { file_patterns = { "*.md" }, ignore_patterns = {} },
        should_ignore = function() return false end,
      }

      scanner.scan({ root_a, root_b }, store, config)
      local card_a = store:get_card("roota001")
      local card_b = store:get_card("rootb001")
      vim.fn.delete(root_a, "rf")
      vim.fn.delete(root_b, "rf")

      assert.is_true(card_a.active)
      assert.is_true(card_b.active)
      assert.not_equals(card_a.file_path, card_b.file_path)
      assert.equals(utils.canonical_path(root_a .. "/deck.md"), card_a.file_path)
      assert.equals(utils.canonical_path(root_b .. "/deck.md"), card_b.file_path)
      assert.equals("review", card_b.state.status)
      assert.equals(6, card_b.state.stability)
      assert.equals(4, card_b.state.reps)
    end)

    it("does not orphan ambiguous legacy paths during a one-file scan", function()
      local root_a, root_b = tmpdir(), tmpdir()
      local path_a = root_a .. "/deck.md"
      assert.is_true(utils.write_file(path_a, "A ::: One <!-- fc:roota002 -->"))
      assert.is_true(utils.write_file(root_b .. "/deck.md", "B ::: Two <!-- fc:rootb002 -->"))
      store:upsert_card({ id = "rootb002", file_path = "deck.md", line = 1, front = "B", back = "Two", tags = {} })

      scanner.scan_file(path_a, store, root_a, { directories = { root_a, root_b } })
      local legacy_card = store:get_card("rootb002")
      vim.fn.delete(root_a, "rf")
      vim.fn.delete(root_b, "rf")

      assert.is_true(legacy_card.active)
      assert.equals("deck.md", legacy_card.file_path)
    end)

    it("upgrades legacy relative paths by ID without losing state or reviews", function()
      local root = tmpdir()
      vim.fn.mkdir(root .. "/topic", "p")
      local path = root .. "/topic/a.md"
      assert.is_true(utils.write_file(path, "Updated Q ::: Updated A <!-- fc:legacy01 -->"))
      store:upsert_card({ id = "legacy01", file_path = "topic/a.md", line = 1, front = "Old Q", back = "Old A", tags = {} })
      store:update_card_state("legacy01", {
        status = "review", stability = 8.5, difficulty = 4.2, due_date = utils.now() + 86400,
        last_review = utils.now(), reps = 7, lapses = 2,
      })
      store:add_review({ card_id = "legacy01", rating = 1, reviewed_at = utils.now(), elapsed_ms = 1000, state_before = "review", state_after = "review" })
      local config = {
        options = { file_patterns = { "*.md" }, ignore_patterns = {} },
        should_ignore = function() return false end,
      }

      scanner.scan({ root }, store, config)
      -- Verify the ID-driven path upgrade, state, and history survive a real
      -- close/reopen cycle rather than merely the in-memory SQLite handle.
      store:close()
      store = Storage.new("sqlite", store_path)
      store:init()
      local card = store:get_card("legacy01")
      local state = store:get_card_state("legacy01")
      local reviews = store:get_reviews("legacy01")
      vim.fn.delete(root, "rf")

      assert.equals(utils.canonical_path(path), card.file_path)
      assert.equals("Updated Q", card.front)
      assert.equals("Updated A", card.back)
      assert.equals("review", state.status)
      assert.equals(8.5, state.stability)
      assert.equals(7, state.reps)
      assert.equals(2, state.lapses)
      assert.equals(1, #reviews)
    end)

    it("keeps existing free-form source refs compatible during rescan", function()
      local path = tmpfile("(exercise 4a) Define a group ::: An algebraic structure <!-- fc:legacyref -->")
      store:upsert_card({
        id = "legacyref", file_path = "old.md", line = 1,
        front = "Define a group", back = "An algebraic structure", note = "exercise 4a", tags = {},
      })

      scanner.scan_file(path, store, "/tmp")
      local card = store:get_card("legacyref")
      os.remove(path)

      assert.equals("Define a group", card.front)
      assert.equals("exercise 4a", card.note)
    end)
  end)

  -- ==========================================================================
  -- find_files
  -- ==========================================================================

  describe("find_files", function()
    it("lists markdown files in a directory", function()
      local dir = tmpdir()
      utils.write_file(dir .. "/one.md", "content")
      utils.write_file(dir .. "/two.md", "content")
      utils.write_file(dir .. "/three.txt", "content")

      local config = {
        options = {
          file_patterns = { "*.md" },
          ignore_patterns = {},
        },
        should_ignore = function() return false end,
      }
      local files = scanner.find_files(dir, config)

      -- Clean up
      os.remove(dir .. "/one.md")
      os.remove(dir .. "/two.md")
      os.remove(dir .. "/three.txt")
      os.remove(dir)

      assert.equals(2, #files)
      -- Both should be .md files
      for _, f in ipairs(files) do
        assert.is_not_nil(f:match("%.md$"))
      end
    end)

    it("respects ignore patterns", function()
      local dir = tmpdir()
      vim.fn.mkdir(dir .. "/node_modules", "p")
      utils.write_file(dir .. "/good.md", "content")
      utils.write_file(dir .. "/node_modules/bad.md", "content")

      local config = {
        options = {
          file_patterns = { "*.md" },
          ignore_patterns = { "node_modules" },
        },
        should_ignore = function(filepath)
          return filepath:find("node_modules", 1, true) ~= nil
        end,
      }
      local files = scanner.find_files(dir, config)

      -- Clean up
      os.remove(dir .. "/good.md")
      os.remove(dir .. "/node_modules/bad.md")
      os.remove(dir .. "/node_modules")
      os.remove(dir)

      assert.equals(1, #files)
      assert.is_not_nil(files[1]:match("good%.md$"))
    end)

    it("finds files in nested subdirectories", function()
      local dir = tmpdir()
      vim.fn.mkdir(dir .. "/sub/deep", "p")
      utils.write_file(dir .. "/top.md", "content")
      utils.write_file(dir .. "/sub/mid.md", "content")
      utils.write_file(dir .. "/sub/deep/bottom.md", "content")

      local config = {
        options = {
          file_patterns = { "*.md" },
          ignore_patterns = {},
        },
        should_ignore = function() return false end,
      }
      local files = scanner.find_files(dir, config)

      -- Clean up
      os.remove(dir .. "/top.md")
      os.remove(dir .. "/sub/mid.md")
      os.remove(dir .. "/sub/deep/bottom.md")
      os.remove(dir .. "/sub/deep")
      os.remove(dir .. "/sub")
      os.remove(dir)

      assert.equals(3, #files)
    end)
  end)

  -- ==========================================================================
  -- Full scan
  -- ==========================================================================

  describe("scan", function()
    it("scans directories and returns a report", function()
      local dir = tmpdir()
      utils.write_file(dir .. "/file1.md", "Q1 ::: A1 <!-- fc:scan0001 -->")
      utils.write_file(dir .. "/file2.md", "Q2 ::: A2")

      local config = {
        options = {
          file_patterns = { "*.md" },
          ignore_patterns = {},
        },
        should_ignore = function() return false end,
      }

      local report = scanner.scan({ dir }, store, config)

      -- Clean up
      os.remove(dir .. "/file1.md")
      os.remove(dir .. "/file2.md")
      os.remove(dir)

      assert.equals(2, report.files_scanned)
      assert.equals(2, report.cards_found)
      assert.equals(2, report.cards_new) -- both cards new to store
      assert.equals(0, #report.errors)
    end)

    it("detects global orphans across all scanned dirs", function()
      -- Pre-populate store with a card
      store:upsert_card({
        id = "willlose1",
        file_path = "old.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
      })

      local dir = tmpdir()
      utils.write_file(dir .. "/current.md", "Q1 ::: A1 <!-- fc:current1 -->")

      local config = {
        options = {
          file_patterns = { "*.md" },
          ignore_patterns = {},
        },
        should_ignore = function() return false end,
      }

      local report = scanner.scan({ dir }, store, config)

      -- Clean up
      os.remove(dir .. "/current.md")
      os.remove(dir)

      assert.equals(1, report.orphans_found)
      assert.is_false(store:get_card("willlose1").active)
      assert.is_true(store:get_card("current1").active)
    end)

    it("accumulates errors from parse failures", function()
      local dir = tmpdir()
      -- Unclosed fenced card produces a parse error
      local content = table.concat({
        ":::card <!-- fc:errcard1 -->",
        "Front",
        ":-:",
        "Back",
        -- Missing :::end
      }, "\n")
      utils.write_file(dir .. "/broken.md", content)

      local config = {
        options = {
          file_patterns = { "*.md" },
          ignore_patterns = {},
        },
        should_ignore = function() return false end,
      }

      local report = scanner.scan({ dir }, store, config)

      -- Clean up
      os.remove(dir .. "/broken.md")
      os.remove(dir)

      assert.truthy(#report.errors > 0)
    end)
  end)
end)
