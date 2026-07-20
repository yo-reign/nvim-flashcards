describe("storage", function()
  local Storage = require("flashcards.storage")
  local utils = require("flashcards.utils")
  local store
  local tmp_path

  local function remove_db_files(path)
    os.remove(path)
    os.remove(path .. "-wal")
    os.remove(path .. "-shm")
    if path:sub(-3) == ".db" then
      os.remove(path:sub(1, -4) .. ".json")
    end
  end

  local function copy_file(src, dst)
    local input = assert(io.open(src, "rb"))
    local data = input:read("*a")
    input:close()
    local output = assert(io.open(dst, "wb"))
    output:write(data)
    output:close()
  end

  before_each(function()
    -- Create a unique temp file for each test
    tmp_path = os.tmpname() .. ".db"
    store = Storage.new("sqlite", tmp_path)
    store:init()
  end)

  after_each(function()
    if store then
      pcall(function() store:close() end)
    end
    remove_db_files(tmp_path)
  end)

  -- ==========================================================================
  -- Factory
  -- ==========================================================================

  describe("factory", function()
    it("creates sqlite backend", function()
      local s = Storage.new("sqlite", tmp_path)
      assert.is_not_nil(s)
      assert.is_function(s.init)
    end)

    it("errors on json type", function()
      assert.has_error(function()
        Storage.new("json", tmp_path)
      end)
    end)

    it("errors on unknown type", function()
      assert.has_error(function()
        Storage.new("unknown", tmp_path)
      end)
    end)
  end)

  -- ==========================================================================
  -- Card Operations
  -- ==========================================================================

  describe("card operations", function()
    it("upserts and retrieves a card", function()
      store:upsert_card({
        id = "abc12345",
        file_path = "math/algebra.md",
        line = 5,
        front = "What is x?",
        back = "A variable",
        reversible = false,
        suspended = false,
        tags = { "math" },
        note = "Ch.1",
      })

      local card = store:get_card("abc12345")
      assert.is_not_nil(card)
      assert.equals("abc12345", card.id)
      assert.equals("math/algebra.md", card.file_path)
      assert.equals(5, card.line)
      assert.equals("What is x?", card.front)
      assert.equals("A variable", card.back)
      assert.is_false(card.reversible)
      assert.is_false(card.suspended)
      assert.same({ "math" }, card.tags)
      assert.equals("Ch.1", card.note)
      assert.is_true(card.active)
    end)

    it("stores media Markdown in existing text columns without changing the schema", function()
      local tables_before = store:_query_all(
        "SELECT name, sql FROM sqlite_master WHERE type = 'table' ORDER BY name"
      )
      local version_before = store:_query_one("PRAGMA user_version").user_version

      store:upsert_card({
        id = "media001",
        file_path = "biology/cells.md",
        line = 8,
        front = "![Cell](assets/cell.png)",
        back = "[Pronunciation](audio/cell.mp3)",
        tags = { "biology" },
      })

      local card = store:get_card("media001")
      assert.equals("![Cell](assets/cell.png)", card.front)
      assert.equals("[Pronunciation](audio/cell.mp3)", card.back)
      assert.same(tables_before, store:_query_all(
        "SELECT name, sql FROM sqlite_master WHERE type = 'table' ORDER BY name"
      ))
      assert.equals(version_before, store:_query_one("PRAGMA user_version").user_version)
      assert.is_nil(store:_query_one(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'media%'"
      ))
    end)

    it("normalizes leading source refs on upsert", function()
      store:upsert_card({
        id = "3kuxvz1f",
        file_path = "math/sets.md",
        line = 12,
        front = "(1.1.2:1) How do you write natural numbers in set notation?",
        back = "As `{ 1, 2, 3,... }` where the ellipsis (...) indicates that the numbers continue to infinity.",
        tags = { "math" },
      })

      local card = store:get_card("3kuxvz1f")
      assert.equals("How do you write natural numbers in set notation?", card.front)
      assert.equals("1.1.2:1", card.note)
      assert.equals(
        "As `{ 1, 2, 3,... }` where the ellipsis (...) indicates that the numbers continue to infinity.",
        card.back
      )
    end)

    it("normalizes stale stored source refs on read", function()
      store:upsert_card({
        id = "stale123",
        file_path = "math/sets.md",
        line = 13,
        front = "Clean front",
        back = "Back",
        tags = {},
      })
      store:_execute("UPDATE cards SET front = ?, note = NULL WHERE id = ?", {
        "(1.1.2:1) How do you write natural numbers in set notation?",
        "stale123",
      })

      local card = store:get_card("stale123")
      assert.equals("How do you write natural numbers in set notation?", card.front)
      assert.equals("1.1.2:1", card.note)
    end)

    it("prefers stale stored source refs over legacy notes on read", function()
      store:upsert_card({
        id = "stalenote",
        file_path = "math/sets.md",
        line = 14,
        front = "Clean front",
        back = "Back",
        note = "legacy note",
        tags = {},
      })
      store:_execute("UPDATE cards SET front = ? WHERE id = ?", {
        "(1.1.2:1) How do you write natural numbers in set notation?",
        "stalenote",
      })

      local card = store:get_card("stalenote")
      assert.equals("How do you write natural numbers in set notation?", card.front)
      assert.equals("1.1.2:1", card.note)
    end)

    it("returns nil for missing card", function()
      assert.is_nil(store:get_card("nonexistent"))
    end)

    it("updates content on re-upsert", function()
      store:upsert_card({
        id = "abc12345",
        file_path = "math/algebra.md",
        line = 5,
        front = "Old front",
        back = "Old back",
        tags = { "math" },
      })

      store:upsert_card({
        id = "abc12345",
        file_path = "math/algebra.md",
        line = 10,
        front = "New front",
        back = "New back",
        tags = { "math", "algebra" },
      })

      local card = store:get_card("abc12345")
      assert.equals("New front", card.front)
      assert.equals("New back", card.back)
      assert.equals(10, card.line)
      assert.same({ "math", "algebra" }, card.tags)
    end)

    it("reactivates lost card on re-upsert", function()
      store:upsert_card({
        id = "abc12345",
        file_path = "math/algebra.md",
        line = 5,
        front = "Q",
        back = "A",
        tags = {},
      })

      store:mark_lost("abc12345")
      local card = store:get_card("abc12345")
      assert.is_false(card.active)

      -- Re-upsert with new file path
      store:upsert_card({
        id = "abc12345",
        file_path = "math/new_file.md",
        line = 3,
        front = "Q updated",
        back = "A updated",
        tags = { "math" },
      })

      card = store:get_card("abc12345")
      assert.is_true(card.active)
      assert.equals("math/new_file.md", card.file_path)
      assert.equals("Q updated", card.front)
    end)

    it("preserves FSRS state on re-upsert", function()
      store:upsert_card({
        id = "abc12345",
        file_path = "math/algebra.md",
        line = 5,
        front = "Q",
        back = "A",
        tags = {},
      })

      store:update_card_state("abc12345", {
        status = "review",
        stability = 10.5,
        difficulty = 5.2,
        reps = 3,
      })

      -- Re-upsert with updated content
      store:upsert_card({
        id = "abc12345",
        file_path = "math/algebra.md",
        line = 5,
        front = "Q updated",
        back = "A updated",
        tags = {},
      })

      local state = store:get_card_state("abc12345")
      assert.equals("review", state.status)
      assert.equals(10.5, state.stability)
      assert.equals(5.2, state.difficulty)
      assert.equals(3, state.reps)
    end)

    it("gets all active cards (excludes inactive)", function()
      store:upsert_card({
        id = "card1",
        file_path = "a.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = {},
      })
      store:upsert_card({
        id = "card2",
        file_path = "b.md",
        line = 1,
        front = "Q2",
        back = "A2",
        tags = {},
      })
      store:upsert_card({
        id = "card3",
        file_path = "c.md",
        line = 1,
        front = "Q3",
        back = "A3",
        tags = {},
      })

      store:mark_lost("card2")

      local cards = store:get_all_cards()
      assert.equals(2, #cards)
      local ids = {}
      for _, c in ipairs(cards) do
        ids[c.id] = true
      end
      assert.is_true(ids["card1"])
      assert.is_true(ids["card3"])
      assert.is_nil(ids["card2"])
    end)

    it("gets cards by file path", function()
      store:upsert_card({
        id = "card1",
        file_path = "math/algebra.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = {},
      })
      store:upsert_card({
        id = "card2",
        file_path = "math/algebra.md",
        line = 5,
        front = "Q2",
        back = "A2",
        tags = {},
      })
      store:upsert_card({
        id = "card3",
        file_path = "cs/algo.md",
        line = 1,
        front = "Q3",
        back = "A3",
        tags = {},
      })

      local cards = store:get_cards_by_file("math/algebra.md")
      assert.equals(2, #cards)
    end)

    it("get_cards_by_file excludes inactive", function()
      store:upsert_card({
        id = "card1",
        file_path = "math/algebra.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = {},
      })
      store:upsert_card({
        id = "card2",
        file_path = "math/algebra.md",
        line = 5,
        front = "Q2",
        back = "A2",
        tags = {},
      })

      store:mark_lost("card1")

      local cards = store:get_cards_by_file("math/algebra.md")
      assert.equals(1, #cards)
      assert.equals("card2", cards[1].id)
    end)
  end)

  -- ==========================================================================
  -- State Operations
  -- ==========================================================================

  describe("state operations", function()
    it("provides default state for new card", function()
      store:upsert_card({
        id = "abc12345",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
      })

      local state = store:get_card_state("abc12345")
      assert.is_not_nil(state)
      assert.equals("new", state.status)
      assert.equals(0, state.stability)
      assert.equals(0, state.difficulty)
      assert.is_nil(state.due_date)
      assert.is_nil(state.last_review)
      assert.equals(0, state.reps)
      assert.equals(0, state.lapses)
      assert.equals(0, state.learning_step)
      assert.equals(0, state.elapsed_days)
      assert.equals(0, state.scheduled_days)
    end)

    it("returns nil state for missing card", function()
      assert.is_nil(store:get_card_state("nonexistent"))
    end)

    it("updates state fields", function()
      store:upsert_card({
        id = "abc12345",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
      })

      local now = utils.now()
      store:update_card_state("abc12345", {
        status = "learning",
        stability = 3.5,
        difficulty = 4.2,
        due_date = now + 600,
        last_review = now,
        reps = 1,
        learning_step = 1,
      })

      local state = store:get_card_state("abc12345")
      assert.equals("learning", state.status)
      assert.equals(3.5, state.stability)
      assert.equals(4.2, state.difficulty)
      assert.equals(now + 600, state.due_date)
      assert.equals(now, state.last_review)
      assert.equals(1, state.reps)
      assert.equals(1, state.learning_step)
      -- Unchanged fields preserved
      assert.equals(0, state.lapses)
      assert.equals(0, state.elapsed_days)
    end)

    it("merges partial state updates", function()
      store:upsert_card({
        id = "abc12345",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
      })

      store:update_card_state("abc12345", { status = "learning", reps = 1 })
      store:update_card_state("abc12345", { stability = 5.0 })

      local state = store:get_card_state("abc12345")
      assert.equals("learning", state.status)
      assert.equals(1, state.reps)
      assert.equals(5.0, state.stability)
    end)
  end)

  -- ==========================================================================
  -- Due Cards
  -- ==========================================================================

  describe("due cards", function()
    it("returns new cards as due", function()
      store:upsert_card({
        id = "new1",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
      })

      local due = store:get_due_cards()
      assert.equals(1, #due)
      assert.equals("new1", due[1].id)
    end)

    it("applies the remaining daily new-card allowance without excluding due reviews", function()
      local now = utils.now()
      for i = 1, 3 do
        store:upsert_card({
          id = "new" .. i,
          file_path = "test.md",
          line = i,
          front = "Q" .. i,
          back = "A" .. i,
          tags = {},
        })
      end
      store:upsert_card({ id = "rev1", file_path = "test.md", line = 4, front = "R", back = "A", tags = {} })
      store:update_card_state("rev1", { status = "review", due_date = now - 1 })
      store:add_review({
        card_id = "new1",
        rating = 1,
        reviewed_at = now,
        state_before = "new",
        state_after = "learning",
      })

      local due, availability = store:get_due_cards(nil, 2)
      assert.equals(2, #due)
      assert.equals(3, availability.total_new)
      assert.equals(1, availability.available_new)
      assert.equals(2, availability.deferred_new)
      local ids = {}
      for _, card in ipairs(due) do ids[card.id] = true end
      assert.is_true(ids.rev1)

      local unlimited = store:get_due_cards(nil, false)
      assert.equals(4, #unlimited)
    end)

    it("returns cards with due_date in the past", function()
      store:upsert_card({
        id = "due1",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
      })

      local past = utils.now() - 3600
      store:update_card_state("due1", {
        status = "review",
        due_date = past,
      })

      local due = store:get_due_cards()
      assert.equals(1, #due)
      assert.equals("due1", due[1].id)
    end)

    it("excludes cards with future due_date", function()
      store:upsert_card({
        id = "future1",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
      })

      local future = utils.now() + 86400
      store:update_card_state("future1", {
        status = "review",
        due_date = future,
      })

      local due = store:get_due_cards()
      assert.equals(0, #due)
    end)

    it("excludes suspended cards", function()
      store:upsert_card({
        id = "susp1",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
        suspended = true,
      })

      local due = store:get_due_cards()
      assert.equals(0, #due)
    end)

    it("excludes inactive cards", function()
      store:upsert_card({
        id = "lost1",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
      })

      store:mark_lost("lost1")

      local due = store:get_due_cards()
      assert.equals(0, #due)
    end)

    it("filters by tag", function()
      store:upsert_card({
        id = "math1",
        file_path = "test.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = { "math" },
      })
      store:upsert_card({
        id = "py1",
        file_path = "test.md",
        line = 2,
        front = "Q2",
        back = "A2",
        tags = { "python" },
      })

      local due = store:get_due_cards("math")
      assert.equals(1, #due)
      assert.equals("math1", due[1].id)
    end)

    it("filters by hierarchical tag", function()
      store:upsert_card({
        id = "alg1",
        file_path = "test.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = { "math/algebra" },
      })
      store:upsert_card({
        id = "calc1",
        file_path = "test.md",
        line = 2,
        front = "Q2",
        back = "A2",
        tags = { "math/calc" },
      })
      store:upsert_card({
        id = "py1",
        file_path = "test.md",
        line = 3,
        front = "Q3",
        back = "A3",
        tags = { "python" },
      })

      local due = store:get_due_cards("math")
      assert.equals(2, #due)
    end)

    it("get_new_cards returns only new status", function()
      store:upsert_card({
        id = "new1",
        file_path = "test.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = {},
      })
      store:upsert_card({
        id = "rev1",
        file_path = "test.md",
        line = 2,
        front = "Q2",
        back = "A2",
        tags = {},
      })

      store:update_card_state("rev1", { status = "review", due_date = utils.now() - 3600 })

      local new = store:get_new_cards()
      assert.equals(1, #new)
      assert.equals("new1", new[1].id)
    end)

    it("get_new_cards excludes suspended", function()
      store:upsert_card({
        id = "new1",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
        suspended = true,
      })

      local new = store:get_new_cards()
      assert.equals(0, #new)
    end)

    it("get_new_cards filters by tag", function()
      store:upsert_card({
        id = "m1",
        file_path = "test.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = { "math" },
      })
      store:upsert_card({
        id = "p1",
        file_path = "test.md",
        line = 2,
        front = "Q2",
        back = "A2",
        tags = { "python" },
      })

      local new = store:get_new_cards("math")
      assert.equals(1, #new)
      assert.equals("m1", new[1].id)
    end)
  end)

  -- ==========================================================================
  -- Tags
  -- ==========================================================================

  describe("tags", function()
    it("gets all tags with counts", function()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = { "math", "algebra" },
      })
      store:upsert_card({
        id = "c2",
        file_path = "test.md",
        line = 2,
        front = "Q2",
        back = "A2",
        tags = { "math", "calc" },
      })
      store:upsert_card({
        id = "c3",
        file_path = "test.md",
        line = 3,
        front = "Q3",
        back = "A3",
        tags = { "python" },
      })

      local tags = store:get_all_tags()
      local tag_map = {}
      for _, t in ipairs(tags) do
        tag_map[t.tag] = t.count
      end

      assert.equals(2, tag_map["math"])
      assert.equals(1, tag_map["algebra"])
      assert.equals(1, tag_map["calc"])
      assert.equals(1, tag_map["python"])
    end)

    it("excludes inactive cards from tag counts", function()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = { "math" },
      })
      store:upsert_card({
        id = "c2",
        file_path = "test.md",
        line = 2,
        front = "Q2",
        back = "A2",
        tags = { "math" },
      })

      store:mark_lost("c2")

      local tags = store:get_all_tags()
      assert.equals(1, #tags)
      assert.equals("math", tags[1].tag)
      assert.equals(1, tags[1].count)
    end)

    it("excludes suspended cards from tag counts", function()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = { "math" },
      })
      store:upsert_card({
        id = "c2",
        file_path = "test.md",
        line = 2,
        front = "Q2",
        back = "A2",
        tags = { "math" },
        suspended = true,
      })

      local tags = store:get_all_tags()
      assert.equals(1, #tags)
      assert.equals(1, tags[1].count)
    end)

    it("includes due_count for new cards", function()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = { "math" },
      })
      store:upsert_card({
        id = "c2",
        file_path = "test.md",
        line = 2,
        front = "Q2",
        back = "A2",
        tags = { "math" },
      })

      local tags = store:get_all_tags()
      assert.equals(1, #tags)
      assert.equals("math", tags[1].tag)
      assert.equals(2, tags[1].count)
      -- New cards are always due
      assert.equals(2, tags[1].due_count)
    end)

    it("includes due_count for past-due reviewed cards", function()
      local now = os.time()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = { "math" },
      })
      store:upsert_card({
        id = "c2",
        file_path = "test.md",
        line = 2,
        front = "Q2",
        back = "A2",
        tags = { "math" },
      })

      -- c1: reviewed, due in the past (due)
      store:update_card_state("c1", {
        status = "review",
        due_date = now - 3600,
      })
      -- c2: reviewed, due in the future (not due)
      store:update_card_state("c2", {
        status = "review",
        due_date = now + 86400,
      })

      local tags = store:get_all_tags()
      assert.equals(1, #tags)
      assert.equals(2, tags[1].count)
      assert.equals(1, tags[1].due_count)
    end)

    it("caps tag due counts using today's remaining new-card allowance", function()
      local now = utils.now()
      for i = 1, 3 do
        store:upsert_card({
          id = "new" .. i,
          file_path = "test.md",
          line = i,
          front = "Q" .. i,
          back = "A" .. i,
          tags = { "math" },
        })
      end
      store:upsert_card({
        id = "rev1", file_path = "test.md", line = 4, front = "R", back = "A", tags = { "math" },
      })
      store:update_card_state("rev1", { status = "review", due_date = now - 1 })
      store:add_review({
        card_id = "new1", rating = 1, reviewed_at = now, state_before = "new", state_after = "learning",
      })

      local tags = store:get_all_tags(2)
      assert.equals(2, tags[1].due_count)
      assert.equals(2, tags[1].deferred_new_count)
      assert.equals(4, store:get_all_tags(false)[1].due_count)
    end)

    it("aggregates child-only tags into parent availability", function()
      local now = utils.now()
      store:upsert_card({
        id = "child_new", file_path = "test.md", line = 1, front = "N", back = "A", tags = { "math/calc" },
      })
      store:upsert_card({
        id = "child_review", file_path = "test.md", line = 2, front = "R", back = "A", tags = { "math/algebra" },
      })
      store:upsert_card({
        id = "parent_and_child",
        file_path = "test.md",
        line = 3,
        front = "D",
        back = "A",
        tags = { "math", "math/calc" },
      })
      store:update_card_state("child_review", { status = "review", due_date = now - 1 })

      local tags = store:get_all_tags(0)
      local by_tag = {}
      for _, item in ipairs(tags) do by_tag[item.tag] = item end

      assert.is_not_nil(by_tag.math)
      assert.equals(3, by_tag.math.count)
      assert.equals(1, by_tag.math.due_count)
      assert.equals(2, by_tag.math.deferred_new_count)
      assert.equals(2, by_tag["math/calc"].count)
      assert.equals(#store:get_due_cards("math", 0), by_tag.math.due_count)
      assert.equals(3, store:get_all_tags(false)[1].due_count)
    end)

    it("returns due_count of 0 when no cards are due", function()
      local now = os.time()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = { "python" },
      })

      -- Set card as reviewed with future due date
      store:update_card_state("c1", {
        status = "review",
        due_date = now + 86400,
      })

      local tags = store:get_all_tags()
      assert.equals(1, #tags)
      assert.equals(1, tags[1].count)
      assert.equals(0, tags[1].due_count)
    end)

    it("counts due cards per tag correctly across multiple tags", function()
      local now = os.time()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = { "math", "algebra" },
      })
      store:upsert_card({
        id = "c2",
        file_path = "test.md",
        line = 2,
        front = "Q2",
        back = "A2",
        tags = { "math" },
      })

      -- c1: past due
      store:update_card_state("c1", {
        status = "review",
        due_date = now - 3600,
      })
      -- c2: future due
      store:update_card_state("c2", {
        status = "review",
        due_date = now + 86400,
      })

      local tags = store:get_all_tags()
      local tag_map = {}
      for _, t in ipairs(tags) do
        tag_map[t.tag] = t
      end

      assert.equals(2, tag_map["math"].count)
      assert.equals(1, tag_map["math"].due_count)
      assert.equals(1, tag_map["algebra"].count)
      assert.equals(1, tag_map["algebra"].due_count)
    end)

    it("filters by exact tag", function()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = { "math" },
      })
      store:upsert_card({
        id = "c2",
        file_path = "test.md",
        line = 2,
        front = "Q2",
        back = "A2",
        tags = { "python" },
      })

      local cards = store:get_cards_by_tag("math")
      assert.equals(1, #cards)
      assert.equals("c1", cards[1].id)
    end)

    it("matches hierarchical tags", function()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = { "math" },
      })
      store:upsert_card({
        id = "c2",
        file_path = "test.md",
        line = 2,
        front = "Q2",
        back = "A2",
        tags = { "math/algebra" },
      })
      store:upsert_card({
        id = "c3",
        file_path = "test.md",
        line = 3,
        front = "Q3",
        back = "A3",
        tags = { "math/algebra/linear" },
      })
      store:upsert_card({
        id = "c4",
        file_path = "test.md",
        line = 4,
        front = "Q4",
        back = "A4",
        tags = { "mathematics" },
      })

      local cards = store:get_cards_by_tag("math")
      assert.equals(3, #cards)
      -- "mathematics" should NOT match "math" (not a child)

      local cards2 = store:get_cards_by_tag("math/algebra")
      assert.equals(2, #cards2)
    end)
  end)

  -- ==========================================================================
  -- Orphan Management
  -- ==========================================================================

  describe("orphan management", function()
    it("mark_lost sets active to false", function()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
      })

      store:mark_lost("c1")
      local card = store:get_card("c1")
      assert.is_false(card.active)
      assert.is_not_nil(card.lost_at)
    end)

    it("get_orphaned_cards returns inactive cards", function()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = {},
      })
      store:upsert_card({
        id = "c2",
        file_path = "test.md",
        line = 2,
        front = "Q2",
        back = "A2",
        tags = {},
      })

      store:mark_lost("c1")

      local orphans = store:get_orphaned_cards()
      assert.equals(1, #orphans)
      assert.equals("c1", orphans[1].id)
    end)

    it("delete_card permanently removes", function()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
      })

      store:delete_card("c1")
      assert.is_nil(store:get_card("c1"))
    end)

    it("deletes a card's review contribution from daily stats", function()
      local now = utils.now()
      store:upsert_card({ id = "c1", file_path = "test.md", line = 1, front = "Q", back = "A", tags = {} })
      store:add_review({ card_id = "c1", rating = 1, reviewed_at = now, elapsed_ms = 1000, state_before = "new", state_after = "learning" })
      store:add_review({ card_id = "c1", rating = 1, reviewed_at = now, elapsed_ms = 1000, state_before = "learning", state_after = "review" })

      store:delete_card("c1")

      local today = store:get_daily_stats(1)[1]
      assert.equals(0, today.new_count)
      assert.equals(0, today.review_count)
      assert.equals(0, store:get_stats().total_reviews)
    end)

    it("delete_all_orphans removes all inactive", function()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = {},
      })
      store:upsert_card({
        id = "c2",
        file_path = "test.md",
        line = 2,
        front = "Q2",
        back = "A2",
        tags = {},
      })
      store:upsert_card({
        id = "c3",
        file_path = "test.md",
        line = 3,
        front = "Q3",
        back = "A3",
        tags = {},
      })

      store:mark_lost("c1")
      store:mark_lost("c2")

      store:delete_all_orphans()

      assert.is_nil(store:get_card("c1"))
      assert.is_nil(store:get_card("c2"))
      assert.is_not_nil(store:get_card("c3"))
    end)

    it("deletes all orphan review contributions from daily stats", function()
      local now = utils.now()
      store:upsert_card({ id = "c1", file_path = "test.md", line = 1, front = "Q1", back = "A1", tags = {} })
      store:upsert_card({ id = "c2", file_path = "test.md", line = 2, front = "Q2", back = "A2", tags = {} })
      store:add_review({ card_id = "c1", rating = 1, reviewed_at = now, elapsed_ms = 1000, state_before = "new", state_after = "learning" })
      store:add_review({ card_id = "c2", rating = 1, reviewed_at = now, elapsed_ms = 1000, state_before = "review", state_after = "review" })
      store:mark_lost("c1")
      store:mark_lost("c2")

      store:delete_all_orphans()

      local today = store:get_daily_stats(1)[1]
      assert.equals(0, today.new_count)
      assert.equals(0, today.review_count)
    end)
  end)

  -- ==========================================================================
  -- Reviews
  -- ==========================================================================

  describe("reviews", function()
    it("records and retrieves reviews", function()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
      })

      local now = utils.now()
      local first_id = store:add_review({
        card_id = "c1",
        rating = 1,
        reviewed_at = now,
        elapsed_ms = 3500,
        state_before = "new",
        state_after = "learning",
      })
      local second_id = store:add_review({
        card_id = "c1",
        rating = 1,
        reviewed_at = now + 60,
        elapsed_ms = 2100,
        state_before = "learning",
        state_after = "review",
      })
      assert.is_number(first_id)
      assert.is_number(second_id)
      assert.truthy(second_id > first_id)

      local reviews = store:get_reviews("c1")
      assert.equals(2, #reviews)
      assert.equals(1, reviews[1].rating)
      assert.equals(3500, reviews[1].elapsed_ms)
      assert.equals("new", reviews[1].state_before)
      assert.equals("learning", reviews[1].state_after)
    end)

    it("returns empty list for card with no reviews", function()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
      })

      local reviews = store:get_reviews("c1")
      assert.same({}, reviews)
    end)

    it("remove_last_review rolls back daily stats", function()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
      })

      local now = utils.now()
      local today = utils.format_date(now)
      store:add_review({
        card_id = "c1",
        rating = 1,
        reviewed_at = now,
        elapsed_ms = 1000,
        state_before = "new",
        state_after = "learning",
      })

      assert.is_true(store:remove_last_review())
      assert.same({}, store:get_reviews("c1"))

      local daily = store:get_daily_stats(7)
      local found = false
      for _, day in ipairs(daily) do
        if day.date == today then
          found = true
          assert.equals(0, day.new_count)
          assert.equals(0, day.review_count)
        end
      end
      assert.is_true(found)
    end)

    it("remove_review deletes the exact review id only", function()
      store:upsert_card({ id = "c1", file_path = "a.md", line = 1, front = "Q1", back = "A1", tags = {} })
      store:upsert_card({ id = "c2", file_path = "a.md", line = 2, front = "Q2", back = "A2", tags = {} })

      local now = utils.now()
      local first_id = store:add_review({
        card_id = "c1",
        rating = 1,
        reviewed_at = now,
        elapsed_ms = 1000,
        state_before = "new",
        state_after = "learning",
      })
      store:add_review({
        card_id = "c2",
        rating = 0,
        reviewed_at = now + 60,
        elapsed_ms = 2000,
        state_before = "new",
        state_after = "learning",
      })

      assert.is_false(store:remove_review(first_id, "c2"))
      assert.is_true(store:remove_review(first_id, "c1"))
      assert.same({}, store:get_reviews("c1"))
      assert.equals(1, #store:get_reviews("c2"))

      local today_stats = store:get_daily_stats(1)[1]
      assert.equals(1, today_stats.new_count)
      assert.equals(0, today_stats.review_count)
    end)
  end)

  -- ==========================================================================
  -- Statistics
  -- ==========================================================================

  describe("statistics", function()
    it("counts by state", function()
      store:upsert_card({ id = "c1", file_path = "a.md", line = 1, front = "Q1", back = "A1", tags = {} })
      store:upsert_card({ id = "c2", file_path = "a.md", line = 2, front = "Q2", back = "A2", tags = {} })
      store:upsert_card({ id = "c3", file_path = "a.md", line = 3, front = "Q3", back = "A3", tags = {} })
      store:upsert_card({ id = "c4", file_path = "a.md", line = 4, front = "Q4", back = "A4", tags = {} })

      store:update_card_state("c2", { status = "learning" })
      store:update_card_state("c3", { status = "review" })
      store:update_card_state("c4", { status = "relearning" })

      local counts = store:count_by_state()
      assert.equals(1, counts.new)
      assert.equals(1, counts.learning)
      assert.equals(1, counts.review)
      assert.equals(1, counts.relearning)
    end)

    it("count_by_state excludes inactive", function()
      store:upsert_card({ id = "c1", file_path = "a.md", line = 1, front = "Q1", back = "A1", tags = {} })
      store:upsert_card({ id = "c2", file_path = "a.md", line = 2, front = "Q2", back = "A2", tags = {} })

      store:mark_lost("c2")

      local counts = store:count_by_state()
      assert.equals(1, counts.new)
      assert.equals(0, counts.learning)
      assert.equals(0, counts.review)
      assert.equals(0, counts.relearning)
    end)

    it("count_due returns due breakdown", function()
      local now = utils.now()

      store:upsert_card({ id = "new1", file_path = "a.md", line = 1, front = "Q1", back = "A1", tags = {} })
      store:upsert_card({ id = "rev1", file_path = "a.md", line = 2, front = "Q2", back = "A2", tags = {} })
      store:upsert_card({ id = "lrn1", file_path = "a.md", line = 3, front = "Q3", back = "A3", tags = {} })
      store:upsert_card({ id = "rln1", file_path = "a.md", line = 4, front = "Q4", back = "A4", tags = {} })
      store:upsert_card({ id = "fut1", file_path = "a.md", line = 5, front = "Q5", back = "A5", tags = {} })

      store:update_card_state("rev1", { status = "review", due_date = now - 3600 })
      store:update_card_state("lrn1", { status = "learning", due_date = now - 60 })
      store:update_card_state("rln1", { status = "relearning", due_date = now - 30 })
      store:update_card_state("fut1", { status = "review", due_date = now + 86400 })

      local counts = store:count_due()
      assert.equals(4, counts.total)
      assert.equals(1, counts.new)
      assert.equals(1, counts.review)
      assert.equals(1, counts.learning)
      assert.equals(1, counts.relearning)

      local capped = store:count_due(0)
      assert.equals(3, capped.total)
      assert.equals(0, capped.new)
      assert.equals(1, capped.deferred_new)
      assert.equals(1, capped.review)
      assert.equals(1, capped.learning)
      assert.equals(1, capped.relearning)
    end)

    it("get_stats returns full statistics", function()
      local now = utils.now()

      store:upsert_card({ id = "c1", file_path = "a.md", line = 1, front = "Q1", back = "A1", tags = {} })
      store:upsert_card({ id = "c2", file_path = "a.md", line = 2, front = "Q2", back = "A2", tags = {} })

      store:update_card_state("c2", { status = "review", due_date = now - 100 })

      store:add_review({ card_id = "c1", rating = 1, reviewed_at = now, elapsed_ms = 3000, state_before = "new", state_after = "learning" })
      store:add_review({ card_id = "c2", rating = 0, reviewed_at = now, elapsed_ms = 5000, state_before = "review", state_after = "relearning" })

      local stats = store:get_stats()
      assert.equals(2, stats.total_cards)
      assert.equals(2, stats.total_reviews)
      assert.equals(0.5, stats.answer_accuracy)
      assert.equals(stats.answer_accuracy, stats.retention_rate)
      assert.equals(4000, stats.avg_time_ms)
    end)

    it("gets today's new-card count", function()
      local now = utils.now()
      store:upsert_card({ id = "c1", file_path = "a.md", line = 1, front = "Q1", back = "A1", tags = {} })
      store:add_review({ card_id = "c1", rating = 1, reviewed_at = now, elapsed_ms = 1000, state_before = "new", state_after = "learning" })
      assert.equals(1, store:get_daily_new_count(now))
    end)

    it("get_daily_stats returns per-day data", function()
      local now = utils.now()
      local today = utils.format_date(now)

      store:upsert_card({ id = "c1", file_path = "a.md", line = 1, front = "Q1", back = "A1", tags = {} })

      store:add_review({ card_id = "c1", rating = 1, reviewed_at = now, elapsed_ms = 3000, state_before = "new", state_after = "learning" })
      store:add_review({ card_id = "c1", rating = 1, reviewed_at = now + 60, elapsed_ms = 2000, state_before = "learning", state_after = "review" })

      local daily = store:get_daily_stats(7)
      assert.is_table(daily)
      -- Find today's entry
      local found = false
      for _, d in ipairs(daily) do
        if d.date == today then
          found = true
          assert.equals(1, d.new_count)
          assert.equals(1, d.review_count)
        end
      end
      assert.is_true(found)
    end)
  end)

  -- ==========================================================================
  -- Persistence
  -- ==========================================================================

  describe("persistence", function()
    it("saves to disk and reloads", function()
      store:upsert_card({
        id = "persist1",
        file_path = "test.md",
        line = 1,
        front = "Persistent Q",
        back = "Persistent A",
        tags = { "test" },
      })

      store:update_card_state("persist1", {
        status = "review",
        stability = 7.5,
        reps = 5,
      })

      store:add_review({
        card_id = "persist1",
        rating = 1,
        reviewed_at = utils.now(),
        elapsed_ms = 2000,
        state_before = "new",
        state_after = "review",
      })

      store:save()

      -- Create a brand new store from the same path
      local store2 = Storage.new("sqlite", tmp_path)
      store2:init()

      local card = store2:get_card("persist1")
      assert.is_not_nil(card)
      assert.equals("Persistent Q", card.front)
      assert.equals("Persistent A", card.back)
      assert.same({ "test" }, card.tags)

      local state = store2:get_card_state("persist1")
      assert.equals("review", state.status)
      assert.equals(7.5, state.stability)
      assert.equals(5, state.reps)

      local reviews = store2:get_reviews("persist1")
      assert.equals(1, #reviews)

      store2:close()
    end)

    it("rejects non-binary review ratings", function()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
      })

      assert.has_error(function()
        store:add_review({
          card_id = "c1",
          rating = 2,
          reviewed_at = utils.now(),
          elapsed_ms = 1000,
          state_before = "new",
          state_after = "learning",
        })
      end)
      assert.same({}, store:get_reviews("c1"))
    end)

    it("rolls back review insert when atomic state update fails", function()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
      })

      assert.has_error(function()
        store:add_review_and_update_state({
          card_id = "c1",
          rating = 1,
          reviewed_at = utils.now(),
          elapsed_ms = 1000,
          state_before = "new",
          state_after = "learning",
        }, "c1", { status = "not-a-valid-state" })
      end)

      assert.same({}, store:get_reviews("c1"))
      local today_stats = store:get_daily_stats(1)[1]
      assert.equals(0, today_stats.new_count)
      assert.equals(0, today_stats.review_count)
      assert.equals("new", store:get_card_state("c1").status)
    end)

    it("close saves and clears data", function()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
      })

      store:close()

      -- Verify file was written
      local content = utils.read_file(tmp_path)
      assert.is_not_nil(content)
      assert.truthy(#content > 10)

      -- Reload works
      local store2 = Storage.new("sqlite", tmp_path)
      store2:init()
      local card = store2:get_card("c1")
      assert.is_not_nil(card)
      store2:close()
    end)

    it("init creates empty store if file does not exist", function()
      local new_path = os.tmpname() .. "_new.db"
      remove_db_files(new_path)

      local s = Storage.new("sqlite", new_path)
      s:init()

      local cards = s:get_all_cards()
      assert.same({}, cards)

      s:close()
      remove_db_files(new_path)
    end)

    it("refuses to overwrite a non-sqlite database file", function()
      store:close()
      store = nil
      local ok = utils.write_file(tmp_path, "this is not sqlite")
      assert.is_true(ok)

      local s = Storage.new("sqlite", tmp_path)
      assert.has_error(function()
        s:init()
      end)
      pcall(function() s:close() end)
    end)

    it("migrates a sibling legacy json store once", function()
      store:close()
      store = nil
      remove_db_files(tmp_path)

      local json_path = tmp_path:sub(1, -4) .. ".json"
      local now = utils.now()
      local ok = utils.write_file(json_path, vim.fn.json_encode({
        schema_version = 1,
        cards = {
          legacy1 = {
            file_path = "deck.md",
            line = 7,
            front = "Legacy Q",
            back = "Legacy A",
            reversible = true,
            suspended = false,
            active = true,
            tags = { "legacy", "legacy/import" },
            state = { status = "review", stability = 4.5, reps = 2 },
            created_at = now - 100,
            updated_at = now - 50,
          },
        },
        reviews = {
          { card_id = "legacy1", rating = 1, reviewed_at = now - 10, elapsed_ms = 1000, state_before = "new", state_after = "learning" },
          { card_id = "legacy1", rating = 2, reviewed_at = now, elapsed_ms = 2000, state_before = "learning", state_after = "review" },
        },
      }))
      assert.is_true(ok)

      store = Storage.new("sqlite", tmp_path)
      store:init()

      local card = store:get_card("legacy1")
      assert.is_not_nil(card)
      assert.equals("Legacy Q", card.front)
      assert.is_true(card.reversible)
      assert.same({ "legacy", "legacy/import" }, card.tags)
      assert.equals("review", card.state.status)
      assert.equals(4.5, card.state.stability)
      assert.equals(2, card.state.reps)

      local reviews = store:get_reviews("legacy1")
      assert.equals(2, #reviews)
      assert.equals(0, reviews[1].rating)
      assert.equals(1, reviews[2].rating)
    end)

    it("refuses empty db creation when legacy json is malformed", function()
      store:close()
      store = nil
      remove_db_files(tmp_path)

      local json_path = tmp_path:sub(1, -4) .. ".json"
      local ok = utils.write_file(json_path, "{ definitely not json")
      assert.is_true(ok)

      store = Storage.new("sqlite", tmp_path)
      assert.has_error(function()
        store:init()
      end)
      pcall(function() store:close() end)
      store = nil
    end)

    it("reconnects when the database file is replaced while open", function()
      store:upsert_card({
        id = "before1",
        file_path = "test.md",
        line = 1,
        front = "Before Q",
        back = "Before A",
        tags = {},
      })

      local backup = tmp_path .. ".backup"
      copy_file(tmp_path, backup)
      os.remove(tmp_path)
      copy_file(backup, tmp_path)

      store:upsert_card({
        id = "after1",
        file_path = "test.md",
        line = 2,
        front = "After Q",
        back = "After A",
        tags = {},
      })

      assert.is_not_nil(store:get_card("before1"))
      assert.is_not_nil(store:get_card("after1"))
      os.remove(backup)
    end)

    it("data survives close and reopen cycle", function()
      -- Add data
      store:upsert_card({
        id = "surv1",
        file_path = "test.md",
        line = 1,
        front = "Survive Q",
        back = "Survive A",
        tags = { "persist" },
        note = "test note",
      })
      store:update_card_state("surv1", { status = "learning", stability = 2.0 })
      store:add_review({
        card_id = "surv1",
        rating = 1,
        reviewed_at = utils.now(),
        elapsed_ms = 1200,
        state_before = "new",
        state_after = "learning",
      })

      -- Close
      store:close()

      -- Reopen
      store = Storage.new("sqlite", tmp_path)
      store:init()

      -- Verify data survived
      local card = store:get_card("surv1")
      assert.equals("Survive Q", card.front)
      assert.equals("test note", card.note)

      local state = store:get_card_state("surv1")
      assert.equals("learning", state.status)
      assert.equals(2.0, state.stability)
      assert.equals(1, #store:get_reviews("surv1"))
      local today = store:get_daily_stats(1)[1]
      assert.equals(1, today.new_count)
      assert.equals(0, today.review_count)
    end)
  end)
end)
